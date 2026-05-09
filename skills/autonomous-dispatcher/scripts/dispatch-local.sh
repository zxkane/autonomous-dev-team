#!/bin/bash
# dispatch-local.sh — Spawn autonomous dev/review agent locally.
# Called by the OpenClaw dispatcher skill to start agent processes.
#
# Usage: bash dispatch-local.sh <type> <issue_num> [session_id]
#   type: "dev-new", "dev-resume", "review"
#   issue_num: GitHub issue number
#   session_id: required for dev-resume
#
# Exit codes:
#   0 — Process spawned successfully
#   1 — Error (invalid input, missing config)

set -euo pipefail

TYPE="${1:?Usage: dispatch-local.sh <dev-new|dev-resume|review> <issue_num> [session_id]}"
ISSUE_NUM="${2:?Missing issue number}"
SESSION_ID="${3:-}"

# Input validation
if ! [[ "$ISSUE_NUM" =~ ^[0-9]+$ ]]; then
  echo "ERROR: issue_num must be a positive integer, got: '$ISSUE_NUM'" >&2
  exit 1
fi
if [[ -n "$SESSION_ID" ]] && ! [[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: session_id contains unsafe characters: '$SESSION_ID'" >&2
  exit 1
fi

# Load config
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
if [[ -f "${SCRIPT_DIR}/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/autonomous.conf"
elif [[ -f "${SCRIPT_DIR}/../../../scripts/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/../../../scripts/autonomous.conf"
fi

PROJECT_ID="${PROJECT_ID:-project}"
PROJECT_DIR="${PROJECT_DIR:?Set PROJECT_DIR in autonomous.conf}"

# Pull in pid_dir_for_project (closes #72). Must be sourced AFTER PROJECT_ID
# is in scope — the helper enforces it via : "${PROJECT_ID:?...}".
# shellcheck source=lib-config.sh
source "${SCRIPT_DIR}/lib-config.sh"

PID_DIR=$(pid_dir_for_project) || { echo "ERROR: cannot resolve PID dir" >&2; exit 1; }

# Pre-create log files with restrictive permissions (agent output may contain secrets)
LOG_PREFIX="/tmp/agent-${PROJECT_ID}"
case "$TYPE" in
  dev-new|dev-resume) install -m 600 /dev/null "${LOG_PREFIX}-issue-${ISSUE_NUM}.log" 2>/dev/null || true ;;
  review)             install -m 600 /dev/null "${LOG_PREFIX}-review-${ISSUE_NUM}.log" 2>/dev/null || true ;;
esac

# Kill any stale wrapper that still holds the PID file for this issue+type.
# Closes #55: previously a lingering wrapper (inner CLI dead, outer bash hung)
# would block `acquire_pid_guard` in the new wrapper, which silently exit 0'd
# and left the issue oscillating between labels with no real progress.
#
# Strategy: SIGTERM, give the trap up to 5 seconds to clean up, escalate to
# SIGKILL only if the process is still alive. Then remove the PID file so the
# new wrapper starts from a clean state.
#
# Refuses to follow symlinks (CWE-59) — same defense as acquire_pid_guard.
#
# Return codes:
#   0 — safe to spawn (PID file gone, no live holder)
#   1 — refuse to spawn: symlink, unreadable PID file, or process still alive
#       after SIGKILL+grace
#
# `kill ... || true` on success paths is intentional. ESRCH (process gone
# between checks) is the only "expected benign" failure of `kill`; we capture
# stderr to distinguish it from EPERM/EINVAL/etc and surface real errors.
kill_stale_wrapper() {
  local pid_file="$1"
  if [[ -L "$pid_file" ]]; then
    echo "ERROR: PID file is a symlink, refusing to operate on it: $pid_file" >&2
    return 1
  fi
  if [[ ! -f "$pid_file" ]]; then
    return 0
  fi

  # Distinguish empty content from "could not read". Deleting an unreadable
  # PID file would leave a possibly-still-running wrapper untracked.
  # Test readability first; only then capture content.
  if ! [[ -r "$pid_file" ]]; then
    echo "ERROR: cannot read PID file $pid_file (permission denied or removed)" >&2
    return 1
  fi
  local old_pid
  old_pid=$(cat "$pid_file" 2>/dev/null)

  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
    echo "Found existing wrapper for issue #${ISSUE_NUM} (PID ${old_pid}); sending SIGTERM..." >&2
    local term_err
    term_err=$(kill "$old_pid" 2>&1) || {
      # ESRCH (no such process) is benign — the process exited between the
      # liveness check and the kill. Anything else is a real problem.
      if [[ "$term_err" != *"No such process"* && -n "$term_err" ]]; then
        echo "WARNING: SIGTERM to PID ${old_pid} failed: ${term_err}" >&2
      fi
    }
    local _i
    for _i in 1 2 3 4 5; do
      kill -0 "$old_pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$old_pid" 2>/dev/null; then
      echo "WARNING: PID ${old_pid} ignored SIGTERM after 5s; escalating to SIGKILL" >&2
      local kill_err
      kill_err=$(kill -9 "$old_pid" 2>&1) || {
        if [[ "$kill_err" != *"No such process"* && -n "$kill_err" ]]; then
          echo "WARNING: SIGKILL to PID ${old_pid} failed: ${kill_err}" >&2
        fi
      }
      sleep 1
      # Final liveness check — if still alive, we cannot safely spawn.
      if kill -0 "$old_pid" 2>/dev/null; then
        echo "ERROR: PID ${old_pid} survived SIGKILL+1s grace; refusing to spawn alongside it" >&2
        return 1
      fi
    fi
  fi

  # Remove PID file regardless. If `rm -f` fails (read-only mount, perm),
  # acquire_pid_guard in the new wrapper re-validates liveness on whatever
  # PID is in the file — and we just verified that PID is no longer alive.
  rm -f "$pid_file"
  return 0
}

case "$TYPE" in
  dev-new|dev-resume) PID_FILE="${PID_DIR}/issue-${ISSUE_NUM}.pid" ;;
  review)             PID_FILE="${PID_DIR}/review-${ISSUE_NUM}.pid" ;;
  *)                  PID_FILE="" ;;
esac
if [[ -n "$PID_FILE" ]]; then
  kill_stale_wrapper "$PID_FILE" || exit 1
fi

case "$TYPE" in
  dev-new)
    nohup "${PROJECT_DIR}/scripts/autonomous-dev.sh" \
      --issue "$ISSUE_NUM" --mode new \
      >> "/tmp/agent-${PROJECT_ID}-issue-${ISSUE_NUM}.log" 2>&1 &
    CHILD_PID=$!
    ;;
  dev-resume)
    if [[ -z "$SESSION_ID" ]]; then
      echo "ERROR: session_id required for dev-resume" >&2
      exit 1
    fi
    nohup "${PROJECT_DIR}/scripts/autonomous-dev.sh" \
      --issue "$ISSUE_NUM" --mode resume --session "$SESSION_ID" \
      >> "/tmp/agent-${PROJECT_ID}-issue-${ISSUE_NUM}.log" 2>&1 &
    CHILD_PID=$!
    ;;
  review)
    nohup "${PROJECT_DIR}/scripts/autonomous-review.sh" \
      --issue "$ISSUE_NUM" \
      >> "/tmp/agent-${PROJECT_ID}-review-${ISSUE_NUM}.log" 2>&1 &
    CHILD_PID=$!
    ;;
  *)
    echo "ERROR: unknown type '$TYPE'. Use dev-new, dev-resume, or review" >&2
    exit 1
    ;;
esac

# Verify the background process started successfully
sleep 1
if ! kill -0 "$CHILD_PID" 2>/dev/null; then
  echo "ERROR: ${TYPE} process for issue #${ISSUE_NUM} exited immediately. Check log: /tmp/agent-${PROJECT_ID}-*-${ISSUE_NUM}.log" >&2
  exit 1
fi
echo "Dispatched ${TYPE} for issue #${ISSUE_NUM} (PID: ${CHILD_PID})"
