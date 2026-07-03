#!/bin/bash
# session-log-probe-remote-aws-ssm.sh — Synchronous SSM-driven terminal-state
# probe for the dispatcher's is_session_completed under
# EXECUTION_BACKEND=remote-aws-ssm (#356, INV-101).
#
# Mirrors liveness-check-remote-aws-ssm.sh's shape (INV-30): the dispatcher
# tick runs on the controller host, but the dev wrapper writes its per-issue
# log on the execution host, so a local `[ -r ... ]` + `grep` always misses
# under the remote backend. This driver runs the same read (or a truncate) ON
# the execution host via SSM and reuses lib-ssm.sh's send/poll/fetch helper.
#
# Usage:
#   bash session-log-probe-remote-aws-ssm.sh --probe <issue_num>
#   bash session-log-probe-remote-aws-ssm.sh --truncate <issue_num>
#
# --probe stdout (on rc=0):
#   line 1: the last `{"type":"result",...}` line from the remote log, or
#           empty if the log is absent/unreadable/has no such line.
#   line 2: the remote log's mtime as a Unix epoch (only when line 1 is
#           non-empty); empty/absent otherwise.
#
# --truncate stdout: empty. Success is rc=0.
#
# Exit codes:
#   0 — definitive result (including "nothing found", which is NOT an error —
#       fail-closed is the CALLER's job: is_session_completed treats an empty
#       probe result as "not completed", never fabricating a completion).
#   1 — input/env validation failure.
#   2 — indeterminate: SSM transport fault, timeout, or parse error. The
#       caller (is_session_completed / _reset_session_log) MUST treat this
#       identically to "nothing found" for --probe (fail-closed: never
#       fabricate a completed state) and as a truncate FAILURE for
#       --truncate (fail-closed: skip dispatch, same as a local write error).
#
# Required env (mirrors liveness-check-remote-aws-ssm.sh):
#   SSM_INSTANCE_ID         — EC2 instance ID running the wrapper
#   SSM_REMOTE_PROJECT_DIR  — absolute project root on the remote box
#   SSM_REMOTE_PROJECT_ID   — project_id used in remote PID/log paths (may
#                             differ from the controller's PROJECT_ID)
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
# See docs/pipeline/remote-backend.md for the full backend contract.

set -uo pipefail

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
MODE_FLAG="${1:-}"
ISSUE_NUM="${2:-}"

if [[ "$MODE_FLAG" != "--probe" && "$MODE_FLAG" != "--truncate" ]]; then
  echo "ERROR: usage: session-log-probe-remote-aws-ssm.sh <--probe|--truncate> <issue_num>" >&2
  exit 1
fi

if [[ -z "$ISSUE_NUM" ]]; then
  echo "ERROR: usage: session-log-probe-remote-aws-ssm.sh <--probe|--truncate> <issue_num>" >&2
  exit 1
fi

if ! [[ "$ISSUE_NUM" =~ ^[0-9]+$ ]]; then
  echo "ERROR: issue_num must be a positive integer, got: '$ISSUE_NUM'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Required env validation (no aws calls until past these gates)
# ---------------------------------------------------------------------------
: "${SSM_INSTANCE_ID:?SSM_INSTANCE_ID required for remote-aws-ssm session-log probe}"
: "${SSM_REMOTE_PROJECT_DIR:?SSM_REMOTE_PROJECT_DIR required (absolute path on remote box)}"
: "${SSM_REMOTE_PROJECT_ID:?SSM_REMOTE_PROJECT_ID required (project_id on remote box)}"

# ---------------------------------------------------------------------------
# Source shared helpers
# ---------------------------------------------------------------------------
# Same rationale as liveness-check-remote-aws-ssm.sh: source lib-ssm.sh from
# this script's OWN unresolved dir (readlink-free) so PATH-scrubbed test
# invocations keep working. Reached via lib-dispatch.sh's skill-tree
# BASH_SOURCE resolution, where lib-ssm.sh is a real adjacent file.
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
# keeps `2>/dev/null || true` so a transient OS error during the probe
# doesn't synthesize a false result. PROJECT_ID here is the REMOTE id
# (SSM_REMOTE_PROJECT_ID) — the log path scheme on the execution host is
# identical to dispatch-local.sh's own /tmp/agent-${PROJECT_ID}-issue-${N}.log
# convention, just evaluated on that host with ITS project id.
profile_prefix=""
if [[ -n "$SSM_REMOTE_PROFILE" ]]; then
  profile_prefix="source ${SSM_REMOTE_PROFILE}; "
fi

if [[ "$MODE_FLAG" == "--probe" ]]; then
  # NOTE: the grep pattern and printf format below MUST use double quotes,
  # not single quotes. INNER_CMD is later interpolated inside an OUTER
  # single-quoted `-c '...'` wrapper (see FULL_CMD below) — any single quote
  # in INNER_CMD's literal text would prematurely close that outer quoting
  # and corrupt the argv the remote shell receives (verified: an embedded
  # `grep '^{"type":"result"'` truncates FULL_CMD's quoting, and the remote
  # `sudo … bash -l -c '<truncated>'` mis-parses everything after it).
  INNER_CMD=$(cat <<EOF
${profile_prefix}set -u
PROJECT_ID="${SSM_REMOTE_PROJECT_ID}"
N="${ISSUE_NUM}"
LOG="/tmp/agent-\${PROJECT_ID}-issue-\${N}.log"
if [ -r "\$LOG" ]; then
  LINE=\$(grep "^{\"type\":\"result\"" "\$LOG" 2>/dev/null | tail -1)
  if [ -n "\$LINE" ]; then
    printf "%s\n" "\$LINE"
    stat -c %Y "\$LOG" 2>/dev/null || true
  fi
fi
EOF
  )
else
  INNER_CMD=$(cat <<EOF
${profile_prefix}set -u
PROJECT_ID="${SSM_REMOTE_PROJECT_ID}"
N="${ISSUE_NUM}"
LOG="/tmp/agent-\${PROJECT_ID}-issue-\${N}.log"
: > "\$LOG"
EOF
  )
fi

# Wrap in sudo + login shell so the remote profile (when set) is loaded.
FULL_CMD="sudo -u ${SSM_REMOTE_USER} ${SSM_REMOTE_SHELL} -l -c '${INNER_CMD}'"

# ---------------------------------------------------------------------------
# Execute via shared helper
# ---------------------------------------------------------------------------
remote_stdout=$(_ssm_run_remote_command "$SSM_INSTANCE_ID" "$SSM_REGION" "$FULL_CMD")
helper_rc=$?

if [[ "$helper_rc" -ne 0 ]]; then
  exit 2
fi

if [[ "$MODE_FLAG" == "--truncate" ]]; then
  # Truncate has no meaningful stdout; success is rc=0 from the helper.
  exit 0
fi

# --probe: pass the remote stdout through verbatim (result line + optional
# epoch line, or nothing). No further parsing here — is_session_completed
# owns the jq parse of the result line and the epoch→ISO-8601 conversion.
printf '%s\n' "$remote_stdout"
exit 0
