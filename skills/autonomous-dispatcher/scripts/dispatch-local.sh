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

# Load config.
# [INV-65] Two-dir resolution. SCRIPT_DIR (the conf dir) is the dirname of the
# UNRESOLVED ${BASH_SOURCE[0]:-$0} so a project-side symlink at
# <project>/scripts/dispatch-local.sh keeps it pointed at the project's
# scripts/, where autonomous.conf lives [INV-14]. The legacy
# `../../../scripts/autonomous.conf` fallback is preserved for callers that
# still invoke the vendored copy directly (no project-side symlink). LIB_DIR
# is the REAL path (readlink -f) used for sourcing siblings (lib-config.sh)
# from the skill tree — no per-project lib symlink needed (#227).
_SELF="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
LIB_DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"
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
source "${LIB_DIR}/lib-config.sh"

PID_DIR=$(pid_dir_for_project) || { echo "ERROR: cannot resolve PID dir" >&2; exit 1; }

# Prepare the per-issue agent log with restrictive permissions (agent output
# may contain secrets — the 0600 hardening dates to #22).
#
# [INV-68] Re-dispatch log retention. Pre-#245 this block unconditionally
# zeroed the log (`install -m 600 /dev/null …log`). The wrapper then redirects
# with `>>` (append), so the truncate was pure side effect — and on a routine
# re-dispatch of the same issue (retry / resume / operator label flip) it
# destroyed the PRIOR (often crashed) run's stdout/stderr before the new run
# started, leaving no forensic trail to triage the failure.
#
# Now we ROTATE: move the existing log to a single `…-N.log.1` generation
# before creating the fresh 0600 current log. `mv -f` overwrites any older
# `.1`, so disk is bounded to one extra generation per (issue, type) — no
# unbounded `.log.1 .log.2 …` accumulation. The rotated `.1` is forced to
# 0600 too, so the prior run's (possibly secret-bearing) output never becomes
# world-readable across rotation.
#
# This does NOT touch the deliberate INV-12 (`prompt_too_long`,
# dispatcher-tick.sh) / INV-35 (`failed-substantive`, lib-dispatch.sh)
# recovery-truncates: those `: > "$log"` the CURRENT log on purpose so the
# next tick's terminal-state gate doesn't re-read a stale `result` line and
# loop forever. Rotation here leaves a fresh empty current log per dispatch,
# which preserves that invariant; the recovery branches remain the explicit
# fail-closed guard for the mid-cycle fresh-dev mint (where no dispatch-local
# rotation has happened yet). The recovery-truncate clears `…-N.log` only — it
# never touches `…-N.log.1`, so even on that path the immediately-prior run's
# log survives.
prepare_agent_log() {
  local log="$1"
  if [[ -f "$log" ]]; then
    # Single-generation rotation; overwrite any older .1 (bounded disk).
    # `mv` moves the path entry itself (it does NOT follow a symlinked
    # current log through to its target), so a symlinked $log becomes a
    # symlinked ${log}.1.
    mv -f "$log" "${log}.1" 2>/dev/null || true
    # Force 0600 on the rotated generation — `mv` preserves the source mode,
    # so a prior log left at a looser mode (pre-#22 file / external writer)
    # would otherwise carry it over. Skip if ${log}.1 is a symlink: `chmod`
    # FOLLOWS symlinks, so a planted `…log -> /victim` would let us flip the
    # victim's perms (CWE-59). Same symlink-refusal posture as
    # kill_stale_wrapper's PID-file handling above. A symlinked log is never
    # something we wrote, so declining to chmod it is correct, not a gap.
    [[ -L "${log}.1" ]] || chmod 600 "${log}.1" 2>/dev/null || true
  fi
  install -m 600 /dev/null "$log" 2>/dev/null || true
}

LOG_PREFIX="/tmp/agent-${PROJECT_ID}"
case "$TYPE" in
  dev-new|dev-resume) prepare_agent_log "${LOG_PREFIX}-issue-${ISSUE_NUM}.log" ;;
  review)             prepare_agent_log "${LOG_PREFIX}-review-${ISSUE_NUM}.log" ;;
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

  if [[ -f "$pid_file" ]]; then
    # Distinguish empty content from "could not read". Deleting an unreadable
    # PID file would leave a possibly-still-running wrapper untracked.
    # Test readability first; only then capture content.
    if ! [[ -r "$pid_file" ]]; then
      echo "ERROR: cannot read PID file $pid_file (permission denied or removed)" >&2
      return 1
    fi
    local old_pid killed=0
    old_pid=$(cat "$pid_file" 2>/dev/null)

    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
      echo "Found existing wrapper for issue #${ISSUE_NUM} (PID ${old_pid}); sending SIGTERM..." >&2
      # Group-kill (closes #109): old_pid was written by _run_with_timeout
      # under setsid, so it's the session-leader PID == PGID. `kill -- -<pid>`
      # signals every member of that group atomically — the whole point of
      # the fix. The wrapper shell's `$$` used to land here, but `$$` is
      # NOT a process group leader, so the timeout/agent tree survived.
      #
      # `kill -- -<pid>` to a non-leader is a no-op (ESRCH), so we always
      # follow up with a leader-only TERM as a best-effort. The pgrep
      # fallback at the bottom of the function picks up any orphans that
      # neither path reached.
      kill -TERM -- "-${old_pid}" 2>/dev/null || true
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
        echo "WARNING: PID ${old_pid} ignored SIGTERM after 5s; escalating to SIGKILL (group)" >&2
        kill -9 -- "-${old_pid}" 2>/dev/null || true
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
      killed=1
    fi

    # PID-file deletion policy (INV-29, closes #129): only delete when we
    # either (a) successfully signalled an alive holder (`killed=1`) — the
    # PID we hold is now stale, leaving the file would leak into the next
    # acquire_pid_guard, OR (b) the file content is empty / non-numeric —
    # there's nothing useful to keep fresh.
    #
    # If we hit the `kill -0` miss path (PID is non-empty, numeric, but
    # `kill -0` returned failure), do NOT delete the file. The agent's
    # session-leader PID can drift out of `kill -0` reachability while the
    # underlying process group is still ticking (observed under
    # AGENT_LAUNCHER `bash -c "..."` indirection); the wrapper's
    # `install_agent_heartbeat` loop relies on the file existing so its
    # `touch` keeps the mtime fresh. Deleting it strands the dispatcher's
    # `pid_alive` mtime fallback (#111 Part B) and re-creates the
    # false-DEAD loop described in #129. The pgrep fallback below remains
    # the safety net for genuinely-orphaned trees we cannot reach via PID.
    if [[ "$killed" -eq 1 ]] || [[ -z "$old_pid" ]] || [[ ! "$old_pid" =~ ^[0-9]+$ ]]; then
      rm -f "$pid_file"
    fi
  fi

  # Defensive pgrep fallback (closes #109 — option C; INV-23, INV-28).
  #
  # Catches escaped agent trees that PID_FILE never reaches:
  #   - pre-fix wrappers whose PID_FILE held `$$` and got reparented to PID 1
  #     when the wrapper exited before the agent subtree finished
  #   - races where the wrapper died after acquire_pid_guard but before
  #     _run_with_timeout overwrote PID_FILE with the real PGID
  #   - rotational kills where a previous tick removed PID_FILE but the
  #     subtree was still unwinding
  #
  # The match must be scoped on three axes (INV-28):
  #   1. project — anchor on `${PROJECT_DIR}/scripts/`. Multiple autonomous
  #      projects can run on the same host with overlapping issue numbers
  #      (e.g. project A issue 200, project B issue 200); a global match
  #      would cross-kill across projects.
  #   2. wrapper type — `dev-*` dispatches must only target
  #      `autonomous-dev.sh` orphans, `review` only `autonomous-review.sh`
  #      (closes #126). Pre-fix the matcher was type-agnostic and a
  #      `dev-resume` for issue N would SIGTERM a live `autonomous-review.sh
  #      --issue N` wrapper, killing the review in its verdict-posting
  #      window.
  #   3. issue — `--issue <N>` with a `\b` word boundary so issue 9 doesn't
  #      match issue 99.
  #
  # Disabled via KILL_STALE_PGREP_FALLBACK=false for operators running
  # their own kill choreography.
  if [[ "${KILL_STALE_PGREP_FALLBACK:-true}" == "true" ]]; then
    local orphan_pids project_re script_re
    # `:-` defaults so unit tests sourcing this function in isolation don't
    # trip `set -u`. In production, both vars are validated at the top of
    # dispatch-local.sh.
    # Defensive *) branch: TYPE is validated up-top, so it's unreachable
    # in normal flow; keeping the project anchor in the catch-all means a
    # future refactor cannot silently widen the match across projects.
    project_re=$(printf '%s' "${PROJECT_DIR:-}/scripts/" | sed 's|[][\\.*^$+?(){}|]|\\&|g')
    case "${TYPE:-}" in
      dev-new|dev-resume) script_re="${project_re}autonomous-dev\\.sh" ;;
      review)             script_re="${project_re}autonomous-review\\.sh" ;;
      *)                  script_re="${project_re}autonomous-(dev|review)\\.sh" ;;
    esac
    # `pgrep -f` matches against the full command line (argv[0] + args).
    # The `[-]-` trick keeps the matcher itself off the result list.
    orphan_pids=$(pgrep -f "${script_re}.*[-]-issue ${ISSUE_NUM}\b" 2>/dev/null \
      | grep -vw "$$" || true)
    if [[ -n "$orphan_pids" ]]; then
      echo "Found orphan ${TYPE:-?} agent process(es) for issue #${ISSUE_NUM} (project ${PROJECT_ID:-?}): $(tr '\n' ' ' <<<"$orphan_pids")— group-killing" >&2
      local op
      while IFS= read -r op; do
        [[ -z "$op" ]] && continue
        kill -TERM -- "-${op}" 2>/dev/null || kill -TERM "$op" 2>/dev/null || true
      done <<<"$orphan_pids"
      sleep 1
      # Escalate any survivors
      while IFS= read -r op; do
        [[ -z "$op" ]] && continue
        if kill -0 "$op" 2>/dev/null; then
          kill -9 -- "-${op}" 2>/dev/null || kill -9 "$op" 2>/dev/null || true
        fi
      done <<<"$orphan_pids"
    fi
  fi

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
    # Empty SESSION_ID is tolerated: dispatcher-tick.sh Step 4 dispatches
    # dev-resume on every pending-dev pass, including first-time pickup
    # with no prior `Dev Session ID:` comment. autonomous-dev.sh:257-260
    # falls back to MODE=new when --mode resume is invoked without
    # --session, so omitting the flag here is the canonical handoff. (#107)
    resume_args=(--issue "$ISSUE_NUM" --mode resume)
    [[ -n "$SESSION_ID" ]] && resume_args+=(--session "$SESSION_ID")
    nohup "${PROJECT_DIR}/scripts/autonomous-dev.sh" "${resume_args[@]}" \
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
