#!/bin/bash
# liveness-check-remote-aws-ssm.sh — Synchronous SSM-driven liveness
# probe for the dispatcher's pid_alive under EXECUTION_BACKEND=remote-aws-ssm
# (#137, INV-30).
#
# Closes the structural false-DEAD bug where lib-dispatch.sh::pid_alive
# runs on the dispatcher box but the wrapper writes its PID file +
# heartbeat sibling on a different box. Reproduced on a downstream
# consumer's #182 (2026-05-16 02:15–04:10 UTC).
#
# Usage:
#   bash liveness-check-remote-aws-ssm.sh <kind> <issue_num>
#     kind: issue | review
#
# Stdout (exactly one line):
#   ALIVE / DEAD / empty
#
# Exit codes:
#   0 — definitive verdict (printed ALIVE or DEAD)
#   1 — input/env validation failure
#   2 — indeterminate: SSM transport fault, timeout, parse error, or
#       remote shell returned anything other than ALIVE/DEAD.
#       Caller (pid_alive) biases this toward ALIVE (INV-30) so a
#       flaky transport never produces a false crash declaration.
#
# Required env (mirrors dispatch-remote-aws-ssm.sh):
#   SSM_INSTANCE_ID         — EC2 instance ID running the wrapper
#   SSM_REMOTE_PROJECT_DIR  — absolute project root on the remote box
#   SSM_REMOTE_PROJECT_ID   — project_id used in remote PID/log paths
#
# Optional env (with defaults):
#   SSM_REGION         (default: ap-southeast-1)
#   SSM_REMOTE_USER    (default: ubuntu)
#   SSM_REMOTE_SHELL   (default: bash)
#   SSM_REMOTE_PROFILE (default: empty, no source)
#   HEARTBEAT_INTERVAL_SECONDS (default: 120; sized for INV-29)
#   SSM_COMMAND_TIMEOUT_SECONDS — SSM-side cap (default 10, lib-ssm.sh)
#   REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS — dispatcher-side poll cap
#                                            (default 8, lib-ssm.sh)
#
# See docs/pipeline/remote-backend.md for the full backend contract.

set -uo pipefail

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
KIND="${1:-}"
ISSUE_NUM="${2:-}"

if [[ -z "$KIND" || -z "$ISSUE_NUM" ]]; then
  echo "ERROR: usage: liveness-check-remote-aws-ssm.sh <issue|review> <issue_num>" >&2
  exit 1
fi

if ! [[ "$KIND" =~ ^(issue|review)$ ]]; then
  echo "ERROR: kind must be 'issue' or 'review', got: '$KIND'" >&2
  exit 1
fi

if ! [[ "$ISSUE_NUM" =~ ^[0-9]+$ ]]; then
  echo "ERROR: issue_num must be a positive integer, got: '$ISSUE_NUM'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Required env validation (no aws calls until past these gates)
# ---------------------------------------------------------------------------
: "${SSM_INSTANCE_ID:?SSM_INSTANCE_ID required for remote-aws-ssm liveness check}"
: "${SSM_REMOTE_PROJECT_DIR:?SSM_REMOTE_PROJECT_DIR required (absolute path on remote box)}"
: "${SSM_REMOTE_PROJECT_ID:?SSM_REMOTE_PROJECT_ID required (project_id on remote box)}"

# ---------------------------------------------------------------------------
# Source shared helpers
# ---------------------------------------------------------------------------
# Use parameter expansion `${path%/*}` instead of `dirname` so PATH-scrubbed
# test invocations keep working (parity with dispatch-remote-aws-ssm.sh).
# [INV-65] This entry sources lib-ssm.sh from its OWN unresolved dir
# (${BASH_SOURCE[0]%/*}, readlink-free — TC-EB-008 runs it under a scrubbed
# PATH). It is reached via lib-dispatch.sh::_remote_pid_alive_query, which
# invokes `${BASH_SOURCE[0]%/*}/liveness-check-remote-aws-ssm.sh` — and
# lib-dispatch.sh is itself sourced from the skill tree (the dispatcher's
# LIB_DIR), so that path lands in the skill tree where lib-ssm.sh is a real
# adjacent file. The installer no longer symlinks lib-*.sh project-side, so a
# project-side invocation would NOT resolve lib-ssm.sh — but no caller does
# that. Same rationale as dispatch-remote-aws-ssm.sh.
_THIS_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="${_THIS_SCRIPT_PATH%/*}"
# shellcheck source=lib-ssm.sh
source "${SCRIPT_DIR}/lib-ssm.sh"

# ---------------------------------------------------------------------------
# Operator-controlled value validation (CWE-78)
# ---------------------------------------------------------------------------
# Project ID: alphanumeric + dashes only; reaches the remote shell
# inside the inner-cmd as $PROJECT_ID.
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

HBI="${HEARTBEAT_INTERVAL_SECONDS:-120}"
[[ "$HBI" =~ ^[0-9]+$ ]] || HBI=120

# ---------------------------------------------------------------------------
# Build the remote snippet
# ---------------------------------------------------------------------------
# `set -u` forces an explicit failure on undefined-var typos so a partial
# probe failure produces `DEAD` only when ALL tiers genuinely missed.
# Each I/O call (cat, stat, pgrep, kill -0) keeps `2>/dev/null || true`
# so a transient OS error during one probe doesn't synthesize a false
# DEAD verdict.
#
# Tier order: kill -0 → process-group walk → PID-file mtime → heartbeat
# sibling mtime. PGID = setsid leader = PID file content (INV-23).
profile_prefix=""
if [[ -n "$SSM_REMOTE_PROFILE" ]]; then
  profile_prefix="source ${SSM_REMOTE_PROFILE}; "
fi

INNER_CMD=$(cat <<EOF
${profile_prefix}set -u
PROJECT_ID="${SSM_REMOTE_PROJECT_ID}"
KIND="${KIND}"
N="${ISSUE_NUM}"
HBI="${HBI}"
DIR="\${XDG_RUNTIME_DIR:-\$HOME/.local/state}/autonomous-\${PROJECT_ID}"
PIDFILE="\${DIR}/\${KIND}-\${N}.pid"
HBFILE="\${DIR}/\${KIND}-\${N}.heartbeat"
PID=\$(cat "\$PIDFILE" 2>/dev/null || true)

if [ -n "\$PID" ] && kill -0 "\$PID" 2>/dev/null; then echo ALIVE; exit 0; fi

if [ -n "\$PID" ] && command -v pgrep >/dev/null 2>&1 && pgrep -g "\$PID" >/dev/null 2>&1; then
  echo ALIVE; exit 0
fi

NOW=\$(date -u +%s)
THR=\$((HBI * 3))
for f in "\$PIDFILE" "\$HBFILE"; do
  [ -f "\$f" ] && [ ! -L "\$f" ] || continue
  M=\$(stat -c %Y "\$f" 2>/dev/null || echo "")
  [ -n "\$M" ] && [ \$((NOW - M)) -lt "\$THR" ] && { echo ALIVE; exit 0; }
done
echo DEAD
EOF
)

# Wrap in sudo + login shell so the remote profile (when set) is loaded.
FULL_CMD="sudo -u ${SSM_REMOTE_USER} ${SSM_REMOTE_SHELL} -l -c '${INNER_CMD}'"

# ---------------------------------------------------------------------------
# Execute via shared helper, parse verdict
# ---------------------------------------------------------------------------
remote_stdout=$(_ssm_run_remote_command "$SSM_INSTANCE_ID" "$SSM_REGION" "$FULL_CMD")
helper_rc=$?

if [[ "$helper_rc" -ne 0 ]]; then
  exit 2
fi

# Trim whitespace; accept exactly ALIVE or DEAD on its own line.
verdict=$(printf '%s' "$remote_stdout" | tr -d '[:space:]')
case "$verdict" in
  ALIVE) printf 'ALIVE\n'; exit 0 ;;
  DEAD)  printf 'DEAD\n';  exit 0 ;;
  *)
    # Anything else — including empty stdout — is indeterminate. Per
    # INV-30, the caller will bias this toward ALIVE. The driver itself
    # MUST NOT print DEAD on any uncertainty path.
    echo "[liveness-check] WARN: remote returned unexpected stdout: '${remote_stdout}'" >&2
    exit 2
    ;;
esac
