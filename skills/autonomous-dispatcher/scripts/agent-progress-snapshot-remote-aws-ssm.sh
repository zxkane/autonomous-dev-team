#!/bin/bash
# agent-progress-snapshot-remote-aws-ssm.sh — Synchronous SSM-driven
# agent-progress-lease probe (and compare-and-signal) for the dispatcher's
# Step 5a under EXECUTION_BACKEND=remote-aws-ssm (#485, [INV-137]).
#
# Mirrors liveness-check-remote-aws-ssm.sh's shape (INV-30): the dispatcher
# tick runs on the controller host, but #493's lease sidecars
# (issue-<N>.progress.json / issue-<N>.run-id) live on the execution host, so
# a local read always misses under the remote backend. This driver runs the
# ENTIRE validation + age computation ON the execution host — the controller
# must never compute remote age from its own clock (design constraint) — and
# prints exactly one line: the same compact JSON snapshot contract
# dev_progress_snapshot (lib-dispatch.sh) returns for the local backend.
#
# Usage:
#   bash agent-progress-snapshot-remote-aws-ssm.sh --snapshot <issue_num>
#   bash agent-progress-snapshot-remote-aws-ssm.sh --compare-and-signal <issue_num> <expected_pid> <expected_run_id>
#
# --snapshot stdout (on rc=0): exactly one line, one of:
#   {"state":"FRESH","age":N,"pid":N,"run_id":"..."}
#   {"state":"STALE","age":N,"pid":N,"run_id":"..."}
#   {"state":"UNKNOWN","reason":"<token>"}
#
# --compare-and-signal stdout (on rc=0): exactly one line, one of:
#   SIGNALED           — pid-file equality + a STALE snapshot with the SAME
#                         pid/run_id as the caller's expected values were all
#                         re-confirmed ON THIS HOST, and `kill -TERM` was sent
#                         to the confirmed pid, in that order, atomically
#                         within one remote shell invocation.
#   ABORTED:<reason>    — any mismatch/FRESH/UNKNOWN found on recheck; no
#                         signal was sent. `<reason>` is diagnostic-only.
#
# Exit codes:
#   0 — definitive result printed (including a printed UNKNOWN/ABORTED,
#       which is NOT a transport error).
#   1 — input/env validation failure.
#   2 — indeterminate: SSM transport fault, timeout, or parse error. The
#       caller MUST treat this identically to UNKNOWN for --snapshot (never
#       fabricate STALE) and as "no signal sent" for --compare-and-signal
#       (never assume the kill happened).
#
# Required env (mirrors liveness-check-remote-aws-ssm.sh):
#   SSM_INSTANCE_ID         — EC2 instance ID running the wrapper
#   SSM_REMOTE_PROJECT_DIR  — absolute project root on the remote box
#   SSM_REMOTE_PROJECT_ID   — project_id used in remote PID/lease paths
#
# Optional env (with defaults):
#   SSM_REGION         (default: ap-southeast-1)
#   SSM_REMOTE_USER    (default: ubuntu)
#   SSM_REMOTE_SHELL   (default: bash)
#   SSM_REMOTE_PROFILE (default: empty, no source)
#   SSM_COMMAND_TIMEOUT_SECONDS — SSM-side cap (default 30, lib-ssm.sh;
#                                  AWS's --timeout-seconds hard minimum)
#   REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS — dispatcher-side poll cap
#                                            (default 8, lib-ssm.sh)
#
# DEV_PROGRESS_STALE_SECONDS is NOT an env knob here: it is a fixed literal
# constant (1800, [INV-137]), matching dev_progress_snapshot's own plain
# (non-`${VAR:-...}`) assignment in lib-dispatch.sh. Reading it from the
# inherited environment would let a deployment classify the same lease
# differently by backend (round-3 review finding #2) — the whole point of
# "fixed shared threshold" is that neither backend's caller can move it.
#
# See docs/pipeline/remote-backend.md for the full backend contract.

set -uo pipefail

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
MODE_FLAG="${1:-}"
ISSUE_NUM="${2:-}"
EXPECTED_PID=""
EXPECTED_RUN_ID=""

if [[ "$MODE_FLAG" != "--snapshot" && "$MODE_FLAG" != "--compare-and-signal" ]]; then
  echo "ERROR: usage: agent-progress-snapshot-remote-aws-ssm.sh <--snapshot|--compare-and-signal> <issue_num> [expected_pid] [expected_run_id]" >&2
  exit 1
fi

if [[ -z "$ISSUE_NUM" ]] || ! [[ "$ISSUE_NUM" =~ ^[0-9]+$ ]]; then
  echo "ERROR: issue_num must be a positive integer, got: '$ISSUE_NUM'" >&2
  exit 1
fi

if [[ "$MODE_FLAG" == "--compare-and-signal" ]]; then
  EXPECTED_PID="${3:-}"
  EXPECTED_RUN_ID="${4:-}"
  if [[ -z "$EXPECTED_PID" ]] || ! [[ "$EXPECTED_PID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: --compare-and-signal requires a numeric expected_pid, got: '$EXPECTED_PID'" >&2
    exit 1
  fi
  if [[ -z "$EXPECTED_RUN_ID" ]]; then
    echo "ERROR: --compare-and-signal requires a non-empty expected_run_id" >&2
    exit 1
  fi
  # The lease schema (#493) only requires run_id to be a non-empty string —
  # a pre-set RUN_ID (operator override, mint_run_id's own ts-suffixed
  # format is always safe, but an override is not) can legitimately contain
  # spaces or other non-control characters, and the producer preserves it
  # verbatim in the lease (lib-agent.sh's `_agent_progress_refresh` only
  # strips control chars and JSON-escapes `\`/`"`). Narrowing the accepted
  # charset here (as a prior revision did) silently drops the legitimate
  # stale-handoff path for any such run_id instead of just handling it
  # safely — so we base64-encode it below for remote interpolation instead
  # of restricting what characters it may contain.
  if [[ "$EXPECTED_RUN_ID" =~ [[:cntrl:]] ]]; then
    echo "ERROR: expected_run_id contains control characters: '$EXPECTED_RUN_ID'" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Required env validation (no aws calls until past these gates)
# ---------------------------------------------------------------------------
: "${SSM_INSTANCE_ID:?SSM_INSTANCE_ID required for remote-aws-ssm progress snapshot}"
: "${SSM_REMOTE_PROJECT_DIR:?SSM_REMOTE_PROJECT_DIR required (absolute path on remote box)}"
: "${SSM_REMOTE_PROJECT_ID:?SSM_REMOTE_PROJECT_ID required (project_id on remote box)}"

# ---------------------------------------------------------------------------
# Source shared helpers
# ---------------------------------------------------------------------------
# Same rationale as liveness-check-remote-aws-ssm.sh: source lib-ssm.sh from
# this script's OWN unresolved dir (readlink-free) so PATH-scrubbed test
# invocations keep working.
_THIS_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="${_THIS_SCRIPT_PATH%/*}"
# shellcheck source=lib-ssm.sh
source "${SCRIPT_DIR}/lib-ssm.sh"

# ---------------------------------------------------------------------------
# Operator-controlled value validation (CWE-78)
# ---------------------------------------------------------------------------
if ! [[ "$SSM_REMOTE_PROJECT_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: SSM_REMOTE_PROJECT_ID contains unsafe characters: '$SSM_REMOTE_PROJECT_ID'" >&2
  exit 1
fi

if [[ "$SSM_REMOTE_PROJECT_DIR" != /* ]] || _has_shell_metachar "$SSM_REMOTE_PROJECT_DIR"; then
  echo "ERROR: SSM_REMOTE_PROJECT_DIR must be an absolute path with no shell metachars: '$SSM_REMOTE_PROJECT_DIR'" >&2
  exit 1
fi

SSM_REGION="${SSM_REGION:-ap-southeast-1}"
SSM_REMOTE_USER="${SSM_REMOTE_USER:-ubuntu}"
SSM_REMOTE_SHELL="${SSM_REMOTE_SHELL:-bash}"
SSM_REMOTE_PROFILE="${SSM_REMOTE_PROFILE:-}"
# Plain assignment, NOT `${VAR:-1800}` — same rationale as
# lib-dispatch.sh's dev_progress_snapshot: an inherited/exported
# DEV_PROGRESS_STALE_SECONDS from the caller's environment must never win
# over this fixed shared threshold ([INV-137]), or the remote backend could
# classify the same lease differently than the local one (round-3 review
# finding #2).
DEV_PROGRESS_STALE_SECONDS=1800

if ! [[ "$SSM_REMOTE_USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: SSM_REMOTE_USER contains unsafe characters: '$SSM_REMOTE_USER'" >&2
  exit 1
fi
if ! [[ "$SSM_REMOTE_SHELL" =~ ^(bash|zsh|sh)$ ]]; then
  echo "ERROR: SSM_REMOTE_SHELL must be bash, zsh, or sh; got: '$SSM_REMOTE_SHELL'" >&2
  exit 1
fi

if [[ -n "$SSM_REMOTE_PROFILE" ]]; then
  if [[ "$SSM_REMOTE_PROFILE" != /* ]] || _has_shell_metachar "$SSM_REMOTE_PROFILE"; then
    echo "ERROR: SSM_REMOTE_PROFILE must be an absolute path with no shell metachars: '$SSM_REMOTE_PROFILE'" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# Build the remote snippet
# ---------------------------------------------------------------------------
# `set -u` forces an explicit failure on undefined-var typos. Each I/O call
# keeps `2>/dev/null || true` (or an explicit UNKNOWN/ABORTED branch) so a
# transient OS error never crashes the remote shell into a bare non-zero
# exit that this driver would otherwise have to distinguish from a genuine
# transport fault.
#
# _snapshot_body is shared by BOTH modes: --snapshot echoes it directly;
# --compare-and-signal re-runs the identical logic (own remote invocation,
# own point-in-time read) as its recheck before deciding whether to sign.
profile_prefix=""
if [[ -n "$SSM_REMOTE_PROFILE" ]]; then
  profile_prefix="source ${SSM_REMOTE_PROFILE}; "
fi

# Shared snapshot logic, emitted into every remote script below. Computes
# and echoes the ONE-LINE JSON snapshot using ONLY this host's own clock and
# filesystem — the controller never sees raw file content to parse itself.
_snapshot_body=$(cat <<'SNAPEOF'
snapshot() {
  DIR="${XDG_RUNTIME_DIR:-$HOME/.local/state}/autonomous-${PROJECT_ID}"
  PROGRESS_FILE="${DIR}/issue-${N}.progress.json"
  RUNID_FILE="${DIR}/issue-${N}.run-id"
  PIDFILE="${DIR}/issue-${N}.pid"

  if [ -L "$PROGRESS_FILE" ] || [ ! -f "$PROGRESS_FILE" ]; then
    printf '{"state":"UNKNOWN","reason":"progress-file-missing-or-symlink"}\n'
    return 0
  fi
  if [ -L "$RUNID_FILE" ] || [ ! -f "$RUNID_FILE" ]; then
    printf '{"state":"UNKNOWN","reason":"runid-file-missing-or-symlink"}\n'
    return 0
  fi

  # A stat failure (GNU/BSD both missing, or the file vanished mid-check)
  # falls back to "" -> MODE != "600" fails closed to UNKNOWN below.
  MODE=$(stat -c '%a' "$PROGRESS_FILE" 2>/dev/null || stat -f '%Lp' "$PROGRESS_FILE" 2>/dev/null || echo "")
  if [ "$MODE" != "600" ]; then
    printf '{"state":"UNKNOWN","reason":"progress-file-bad-mode"}\n'
    return 0
  fi
  # Same fail-closed direction as above, for the run-id sidecar.
  MODE=$(stat -c '%a' "$RUNID_FILE" 2>/dev/null || stat -f '%Lp' "$RUNID_FILE" 2>/dev/null || echo "")
  if [ "$MODE" != "600" ]; then
    printf '{"state":"UNKNOWN","reason":"runid-file-bad-mode"}\n'
    return 0
  fi

  LEASE_JSON=$(cat "$PROGRESS_FILE" 2>/dev/null) || LEASE_JSON=""
  if [ -z "$LEASE_JSON" ]; then
    printf '{"state":"UNKNOWN","reason":"progress-file-unreadable"}\n'
    return 0
  fi

  NOW=$(date -u +%s 2>/dev/null) || NOW=""
  if [ -z "$NOW" ]; then
    printf '{"state":"UNKNOWN","reason":"clock-unavailable"}\n'
    return 0
  fi

  PARSED=$(printf '%s' "$LEASE_JSON" | jq -re --arg now "$NOW" '
      if (.schema_version == 1)
         and (.pid | type == "number" and (. == (. | floor)) and . >= 0)
         and (.updated_at_epoch | type == "number" and (. == (. | floor)) and . >= 0 and . <= ($now | tonumber))
         and (.run_id | type == "string" and length > 0)
      then "\(.pid)\t\(.updated_at_epoch)\t\(.run_id)"
      else empty
      end
    ' 2>/dev/null)
  if [ -z "$PARSED" ]; then
    printf '{"state":"UNKNOWN","reason":"progress-file-malformed"}\n'
    return 0
  fi

  LEASE_PID=$(printf '%s' "$PARSED" | cut -f1)
  LEASE_EPOCH=$(printf '%s' "$PARSED" | cut -f2)
  LEASE_RUN_ID=$(printf '%s' "$PARSED" | cut -f3)

  CURRENT_PID=$(cat "$PIDFILE" 2>/dev/null) || CURRENT_PID=""
  CURRENT_RUN_ID=$(head -n1 "$RUNID_FILE" 2>/dev/null) || CURRENT_RUN_ID=""

  if [ -z "$CURRENT_PID" ] || [ "$LEASE_PID" != "$CURRENT_PID" ]; then
    printf '{"state":"UNKNOWN","reason":"pid-mismatch"}\n'
    return 0
  fi
  if [ -z "$CURRENT_RUN_ID" ] || [ "$LEASE_RUN_ID" != "$CURRENT_RUN_ID" ]; then
    printf '{"state":"UNKNOWN","reason":"run-id-mismatch"}\n'
    return 0
  fi

  AGE=$((NOW - LEASE_EPOCH))
  STATE="FRESH"
  if [ "$AGE" -gt "$DEV_PROGRESS_STALE_SECONDS" ]; then
    STATE="STALE"
  fi
  # jq -nc (not a raw printf %s) so a run_id containing a quote/backslash is
  # properly escaped — matches dev_progress_snapshot's own jq -nc emission
  # (lib-dispatch.sh) so local and remote never diverge on this edge case.
  jq -nc --arg state "$STATE" --argjson age "$AGE" --argjson pid "$LEASE_PID" --arg run_id "$LEASE_RUN_ID" \
    '{state: $state, age: $age, pid: $pid, run_id: $run_id}' 2>/dev/null \
    || printf '{"state":"UNKNOWN","reason":"snapshot-encode-failure"}\n'
}
SNAPEOF
)

if [[ "$MODE_FLAG" == "--snapshot" ]]; then
  INNER_CMD=$(cat <<EOF
${profile_prefix}set -u
PROJECT_ID="${SSM_REMOTE_PROJECT_ID}"
N="${ISSUE_NUM}"
DEV_PROGRESS_STALE_SECONDS="${DEV_PROGRESS_STALE_SECONDS}"
${_snapshot_body}
snapshot
EOF
  )
else
  # --compare-and-signal: re-run the IDENTICAL snapshot logic, then compare
  # its pid/run_id/state against the caller's expected values (captured by
  # an EARLIER --snapshot call), and only if ALL of {pid-file equality
  # already enforced inside snapshot(), state==STALE, pid==expected,
  # run_id==expected} hold, send SIGTERM to the confirmed pid — all within
  # this ONE remote shell invocation, so there is no gap between the final
  # recheck and the signal for a race to land in.
  #
  # EXPECTED_RUN_ID is base64-encoded here and decoded remotely (same
  # technique _ssm_build_full_cmd already uses for the whole INNER_CMD)
  # because it is now only checked for control characters, not restricted
  # to a safe charset — a literal interpolation like the PID's below would
  # let a run_id containing `"` or `$(...)` break out of the assignment and
  # execute arbitrary remote shell.
  EXPECTED_RUN_ID_B64=$(printf '%s' "$EXPECTED_RUN_ID" | base64 | tr -d '\n') || {
    echo "ERROR: failed to base64-encode expected_run_id" >&2
    exit 1
  }
  INNER_CMD=$(cat <<EOF
${profile_prefix}set -u
PROJECT_ID="${SSM_REMOTE_PROJECT_ID}"
N="${ISSUE_NUM}"
DEV_PROGRESS_STALE_SECONDS="${DEV_PROGRESS_STALE_SECONDS}"
EXPECTED_PID="${EXPECTED_PID}"
EXPECTED_RUN_ID=\$(printf '%s' '${EXPECTED_RUN_ID_B64}' | base64 -d) || exit 1
${_snapshot_body}
SNAP=\$(snapshot)
RSTATE=\$(printf '%s' "\$SNAP" | jq -r '.state // "UNKNOWN"' 2>/dev/null) || RSTATE="UNKNOWN"
if [ "\$RSTATE" != "STALE" ]; then
  printf 'ABORTED:not-stale-on-recheck\n'
  exit 0
fi
RPID=\$(printf '%s' "\$SNAP" | jq -r '.pid // empty' 2>/dev/null)
RRUNID=\$(printf '%s' "\$SNAP" | jq -r '.run_id // empty' 2>/dev/null)
if [ "\$RPID" != "\$EXPECTED_PID" ]; then
  printf 'ABORTED:pid-changed\n'
  exit 0
fi
if [ "\$RRUNID" != "\$EXPECTED_RUN_ID" ]; then
  printf 'ABORTED:run-id-changed\n'
  exit 0
fi
if kill -TERM "\$RPID" 2>/dev/null; then
  printf 'SIGNALED\n'
else
  printf 'ABORTED:signal-failed\n'
fi
EOF
  )
fi

# Wrap in sudo + login shell so the remote profile (when set) is loaded.
# Built via _ssm_build_full_cmd (lib-ssm.sh) — see that function's docstring
# for why INNER_CMD is base64-encoded rather than interpolated verbatim.
FULL_CMD=$(_ssm_build_full_cmd "$SSM_REMOTE_USER" "$SSM_REMOTE_SHELL" "$INNER_CMD") || {
  echo "ERROR: failed to build FULL_CMD (base64 encoding failed)" >&2
  exit 1
}

# ---------------------------------------------------------------------------
# Execute via shared helper, parse verdict
# ---------------------------------------------------------------------------
remote_stdout=$(_ssm_run_remote_command "$SSM_INSTANCE_ID" "$SSM_REGION" "$FULL_CMD")
helper_rc=$?

if [[ "$helper_rc" -ne 0 ]]; then
  exit 2
fi

if [[ "$MODE_FLAG" == "--snapshot" ]]; then
  # Validate the remote produced exactly one line matching one of the three
  # known shapes — anything else (empty, multi-line, garbage) is
  # indeterminate, NEVER fabricated as STALE.
  _line_count=$(printf '%s\n' "$remote_stdout" | grep -c '.' || true)
  if [[ "$_line_count" -ne 1 ]]; then
    echo "[agent-progress-snapshot] WARN: remote returned unexpected line count (${_line_count}): '${remote_stdout}'" >&2
    exit 2
  fi
  if ! printf '%s' "$remote_stdout" | jq -e '
        (.state == "FRESH" and (.age|type=="number") and (.pid|type=="number") and (.run_id|type=="string"))
        or (.state == "STALE" and (.age|type=="number") and (.pid|type=="number") and (.run_id|type=="string"))
        or (.state == "UNKNOWN" and (.reason|type=="string"))
      ' >/dev/null 2>&1; then
    echo "[agent-progress-snapshot] WARN: remote snapshot did not match the expected schema: '${remote_stdout}'" >&2
    exit 2
  fi
  printf '%s\n' "$remote_stdout"
  exit 0
else
  case "$remote_stdout" in
    SIGNALED)
      printf 'SIGNALED\n'
      exit 0
      ;;
    ABORTED:*)
      printf '%s\n' "$remote_stdout"
      exit 0
      ;;
    *)
      echo "[agent-progress-snapshot] WARN: remote compare-and-signal returned unexpected stdout: '${remote_stdout}'" >&2
      exit 2
      ;;
  esac
fi
