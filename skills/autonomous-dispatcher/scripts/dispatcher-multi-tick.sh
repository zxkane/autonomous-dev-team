#!/bin/bash
# dispatcher-multi-tick.sh — outer loop for multi-project dispatching (#62).
#
# One cron invocation runs one tick per project listed in dispatcher.conf.
# Each project's `autonomous.conf` is sourced in a subshell via the
# AUTONOMOUS_CONF env override (lib-config.sh priority 1) so settings
# cannot leak between projects.
#
# Backwards compat: `dispatcher-tick.sh` itself is unchanged. Single-project
# deployments continue to work by invoking `dispatcher-tick.sh` directly.
#
# Usage:
#   DISPATCHER_CONF=/path/to/dispatcher.conf bash dispatcher-multi-tick.sh
# or with default lookup:
#   bash dispatcher-multi-tick.sh   # tries $HOME/.autonomous/dispatcher.conf
#                                   #  then $XDG_CONFIG_HOME/autonomous/dispatcher.conf
#
# Exit codes:
#   0 — at least one project ticked (per-project failures logged but tolerated)
#   1 — dispatcher.conf cannot be located, is unreadable, or PROJECTS unset

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

log() { echo "[dispatcher-multi-tick] $(date -u +%H:%M:%S) $*"; }
warn() { echo "[dispatcher-multi-tick] $(date -u +%H:%M:%S) $*" >&2; }

# ---------------------------------------------------------------------------
# Locate dispatcher.conf
# ---------------------------------------------------------------------------
resolve_dispatcher_conf() {
  if [[ -n "${DISPATCHER_CONF:-}" ]]; then
    echo "$DISPATCHER_CONF"
    return 0
  fi
  if [[ -n "${HOME:-}" ]] && [[ -f "${HOME}/.autonomous/dispatcher.conf" ]]; then
    echo "${HOME}/.autonomous/dispatcher.conf"
    return 0
  fi
  if [[ -n "${XDG_CONFIG_HOME:-}" ]] && [[ -f "${XDG_CONFIG_HOME}/autonomous/dispatcher.conf" ]]; then
    echo "${XDG_CONFIG_HOME}/autonomous/dispatcher.conf"
    return 0
  fi
  return 1
}

CONF=$(resolve_dispatcher_conf) || {
  echo "ERROR: dispatcher.conf not found. Set DISPATCHER_CONF or place the file at:" >&2
  echo "  \$HOME/.autonomous/dispatcher.conf" >&2
  echo "  \$XDG_CONFIG_HOME/autonomous/dispatcher.conf" >&2
  echo "See dispatcher.conf.example for the schema." >&2
  exit 1
}

if [[ ! -r "$CONF" ]]; then
  echo "ERROR: dispatcher.conf at '$CONF' is missing or unreadable" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Load PROJECTS array
# ---------------------------------------------------------------------------
# Source in the current shell (we need the array to drive the loop).
# Any leftover env from this source is fine because each per-project tick
# runs in its own subshell with AUTONOMOUS_CONF set, which lib-config.sh
# treats as priority-1 and re-sources the chosen autonomous.conf fresh.
# shellcheck disable=SC1090
source "$CONF"

if ! declare -p PROJECTS &>/dev/null; then
  echo "ERROR: dispatcher.conf at '$CONF' does not define PROJECTS array" >&2
  echo "See dispatcher.conf.example for the schema." >&2
  exit 1
fi

if [[ "${#PROJECTS[@]}" -eq 0 ]]; then
  log "no projects configured in $CONF — exiting 0"
  exit 0
fi

# ---------------------------------------------------------------------------
# Per-project tick loop
# ---------------------------------------------------------------------------
# Each iteration runs dispatcher-tick.sh in a subshell (parentheses) with
# AUTONOMOUS_CONF set to the project's conf path. The subshell's exit code
# is captured but does NOT short-circuit the loop — one bad project must
# not block ticks for the others.
log "scanning ${#PROJECTS[@]} project(s) from $CONF"

OK=0
FAIL=0
for proj_conf in "${PROJECTS[@]}"; do
  if [[ ! -r "$proj_conf" ]]; then
    warn "  WARN: skipping unreadable project conf: $proj_conf"
    FAIL=$((FAIL + 1))
    continue
  fi

  log "  ticking project: $proj_conf"
  if ( AUTONOMOUS_CONF="$proj_conf" bash "$SCRIPT_DIR/dispatcher-tick.sh" ); then
    OK=$((OK + 1))
  else
    rc=$?
    warn "  WARN: tick failed for $proj_conf (rc=$rc)"
    FAIL=$((FAIL + 1))
  fi
done

log "tick complete: $OK ok, $FAIL failed (out of ${#PROJECTS[@]} projects)"
exit 0
