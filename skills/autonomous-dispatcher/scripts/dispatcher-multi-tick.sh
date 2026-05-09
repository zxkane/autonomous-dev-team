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

# Trust gate before sourcing (CWE-94 mitigation, Q PR-78 finding):
# `source` of an attacker-writable file executes arbitrary code as the
# dispatcher user. Refuse to source if the file is owned by someone else
# or is group/other-writable. Same trust model sudo/ssh-config use.
#
# Refuses also if the parent dir is g+w / o+w, since an attacker who can
# rename a sibling file into the parent could swap the sentinel.
#
# Disabled when AUTONOMOUS_TRUST_CONF=1 (escape hatch for shared-dev
# scenarios like dev VMs where the operator owns the conf via a different
# uid; documented in dispatcher.conf.example).
trust_check() {
  local path="$1" label="$2"
  if [[ -n "${AUTONOMOUS_TRUST_CONF:-}" ]]; then
    return 0
  fi
  local owner perms parent_perms
  owner=$(stat -c '%u' "$path" 2>/dev/null || stat -f '%u' "$path" 2>/dev/null)
  perms=$(stat -c '%a' "$path" 2>/dev/null || stat -f '%Lp' "$path" 2>/dev/null)
  if [[ "$owner" != "$(id -u)" && "$owner" != "0" ]]; then
    echo "ERROR: $label at '$path' is not owned by current user or root (uid=$owner). Refusing to source. Set AUTONOMOUS_TRUST_CONF=1 to override." >&2
    return 1
  fi
  # Group or other write bit set — anyone in the group (or anyone, period)
  # can edit the file and inject code that we'd execute on the next tick.
  if [[ -n "$perms" ]] && (( (10#$perms & 0022) != 0 )); then
    echo "ERROR: $label at '$path' has insecure permissions ($perms). Refusing to source — chmod go-w. Set AUTONOMOUS_TRUST_CONF=1 to override." >&2
    return 1
  fi
  parent_perms=$(stat -c '%a' "$(dirname "$path")" 2>/dev/null || stat -f '%Lp' "$(dirname "$path")" 2>/dev/null)
  if [[ -n "$parent_perms" ]] && (( (10#$parent_perms & 0022) != 0 )); then
    echo "ERROR: parent directory of '$path' is g+w or o+w ($parent_perms). Refusing to source — chmod go-w on the parent." >&2
    return 1
  fi
}

trust_check "$CONF" "dispatcher.conf" || exit 1

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
