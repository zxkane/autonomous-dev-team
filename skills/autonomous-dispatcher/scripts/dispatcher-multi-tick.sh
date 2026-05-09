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
# Inline-block validator (#62 axis 2)
# ---------------------------------------------------------------------------
# Remote projects describe themselves inline in dispatcher.conf because the
# dispatcher box does NOT have their autonomous.conf on disk (autonomous.conf
# lives on the remote dev box). The block contains bash KEY=VALUE lines.
#
# Before eval we sanity-check: every non-blank, non-comment line must look
# like KEY=value (allow optional `export KEY=`). Reject anything else —
# in particular, function calls or commands that would be code-executed.
# `dispatcher.conf` is already trusted (PR-8 trust gate), so this is
# defense-in-depth against accidental injection from copy-paste.
validate_inline_block() {
  local block="$1"
  local line lhs rhs
  while IFS= read -r line; do
    # Strip leading whitespace.
    line="${line#"${line%%[![:space:]]*}"}"
    # Allow blank lines and comments.
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    # The line must look like KEY=value or `export KEY=value`. Optional
    # spaces around `=` are NOT allowed — bash itself rejects that anyway.
    if ! [[ "$line" =~ ^(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*= ]]; then
      return 1
    fi
    # Q PR-80 finding (CWE-95): the LHS check above doesn't constrain the
    # RHS, so values like `REPO=$(malicious_command)` or `KEY=`cmd`` would
    # pass validation and execute on `eval`. Block code-injection metachars
    # in the value portion. `$` blocks both `$(cmd)` and `${VAR}`/`$VAR`
    # expansion (we don't have any schema field that legitimately uses
    # variable expansion). Backticks block legacy command substitution.
    # `;`/`&`/`|` block chained commands. Backslash blocks line
    # continuations and escape sequences.
    rhs="${line#*=}"
    case "$rhs" in
      *'$'*|*'`'*|*';'*|*'&'*|*'|'*|*'\'*)
        return 1 ;;
    esac
  done <<<"$block"
  return 0
}

# Run a per-project tick from an inline metadata block.
# Eval'd inside a subshell so vars cannot leak between projects.
# Auto-derives REPO_OWNER and REPO_NAME from REPO when missing.
tick_inline_project() {
  local block="$1" entry_label="$2"

  if ! validate_inline_block "$block"; then
    warn "  WARN: skipping $entry_label — inline block contains non-assignment lines (refusing to eval)"
    return 1
  fi

  (
    set +u
    # shellcheck disable=SC2294
    eval "$block"
    : "${REPO:?inline project missing REPO}"
    : "${PROJECT_ID:?inline project missing PROJECT_ID}"
    # Auto-derive owner/name from REPO=owner/name.
    : "${REPO_OWNER:=${REPO%%/*}}"
    : "${REPO_NAME:=${REPO##*/}}"
    export REPO REPO_OWNER REPO_NAME PROJECT_ID
    # Optional vars consumed by the router and dispatch-remote-aws-ssm.sh.
    [[ -n "${EXECUTION_BACKEND:-}" ]]      && export EXECUTION_BACKEND
    [[ -n "${SSM_INSTANCE_ID:-}" ]]        && export SSM_INSTANCE_ID
    [[ -n "${SSM_REGION:-}" ]]             && export SSM_REGION
    [[ -n "${SSM_REMOTE_USER:-}" ]]        && export SSM_REMOTE_USER
    [[ -n "${SSM_REMOTE_SHELL:-}" ]]       && export SSM_REMOTE_SHELL
    [[ -n "${SSM_REMOTE_PROFILE:-}" ]]     && export SSM_REMOTE_PROFILE
    [[ -n "${SSM_REMOTE_PROJECT_DIR:-}" ]] && export SSM_REMOTE_PROJECT_DIR
    [[ -n "${SSM_REMOTE_PROJECT_ID:-}" ]]  && export SSM_REMOTE_PROJECT_ID
    [[ -n "${DISPATCHER_APP_ID:-}" ]]      && export DISPATCHER_APP_ID
    [[ -n "${DISPATCHER_APP_PEM:-}" ]]     && export DISPATCHER_APP_PEM
    [[ -n "${GH_AUTH_MODE:-}" ]]           && export GH_AUTH_MODE
    [[ -n "${MAX_CONCURRENT:-}" ]]         && export MAX_CONCURRENT
    [[ -n "${MAX_RETRIES:-}" ]]            && export MAX_RETRIES
    # Inline projects don't have a dispatcher-side PROJECT_DIR (the source
    # lives on the remote box). dispatcher-tick.sh validates PROJECT_DIR is
    # non-empty; for the local backend it's the project root, for remote
    # it's only used by lib-config.sh's autonomous.conf fallback path
    # (which we don't need — AUTONOMOUS_CONF is empty for inline). Set it
    # to a placeholder that is harmless on the dispatcher side; the actual
    # remote PROJECT_DIR is in SSM_REMOTE_PROJECT_DIR.
    : "${PROJECT_DIR:=/}"
    export PROJECT_DIR
    # AUTONOMOUS_CONF must be UNSET for inline projects so lib-config.sh
    # doesn't try to source a stale path from the parent multi-tick env.
    unset AUTONOMOUS_CONF
    set -u
    bash "$SCRIPT_DIR/dispatcher-tick.sh"
  )
}

# Classify a PROJECTS[i] entry: file path (PR-8 local) vs inline metadata (#62).
# A file path is detected by: contains "/" AND exists as a regular file.
# Anything else is treated as inline metadata.
is_path_entry() {
  local entry="$1"
  [[ "$entry" == *"/"* && -f "$entry" ]]
}

# ---------------------------------------------------------------------------
# Per-project tick loop
# ---------------------------------------------------------------------------
# Each iteration runs dispatcher-tick.sh in a subshell. For path entries
# (PR-8 local), AUTONOMOUS_CONF is set so lib-config.sh sources that file.
# For inline entries (#62 remote), the metadata is eval'd in the subshell.
# Subshell exit codes are captured but do NOT short-circuit the loop —
# one bad project must not block ticks for the others.
log "scanning ${#PROJECTS[@]} project(s) from $CONF"

OK=0
FAIL=0
for entry in "${PROJECTS[@]}"; do
  if is_path_entry "$entry"; then
    if [[ ! -r "$entry" ]]; then
      warn "  WARN: skipping unreadable project conf: $entry"
      FAIL=$((FAIL + 1))
      continue
    fi
    log "  ticking local project: $entry"
    if ( AUTONOMOUS_CONF="$entry" bash "$SCRIPT_DIR/dispatcher-tick.sh" ); then
      OK=$((OK + 1))
    else
      rc=$?
      warn "  WARN: tick failed for $entry (rc=$rc)"
      FAIL=$((FAIL + 1))
    fi
  else
    # Inline metadata. Identify it by a stable label for log lines —
    # extract REPO from the block on a best-effort basis.
    label=$(grep -oE '^[[:space:]]*(export[[:space:]]+)?REPO=[^[:space:]]+' <<<"$entry" \
            | head -1 | sed 's/^[[:space:]]*\(export[[:space:]]\+\)\?REPO=//')
    [[ -z "$label" ]] && label="<inline-$((OK+FAIL+1))>"
    log "  ticking remote project: $label"
    if tick_inline_project "$entry" "$label"; then
      OK=$((OK + 1))
    else
      rc=$?
      warn "  WARN: tick failed for inline project $label (rc=$rc)"
      FAIL=$((FAIL + 1))
    fi
  fi
done

log "tick complete: $OK ok, $FAIL failed (out of ${#PROJECTS[@]} projects)"
exit 0
