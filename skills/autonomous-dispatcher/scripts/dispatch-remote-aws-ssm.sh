#!/bin/bash
# dispatch-remote-aws-ssm.sh — Send an SSM command to a remote dev box to
# spawn the wrapper there. Closes #62 axis 2 (pluggable execution backend).
#
# This script is purely a transport layer. The actual process spawning,
# kill-stale-wrapper, and PID file management all happen on the remote box,
# inside the existing dispatch-local.sh — same code path as a local-backend
# deployment, just one machine over.
#
# Usage (called via dispatcher-tick.sh::dispatch when EXECUTION_BACKEND=remote-aws-ssm):
#   bash dispatch-remote-aws-ssm.sh <type> <issue_num> [session_id]
#     type: dev-new | dev-resume | review
#
# Required env (set by dispatcher-tick.sh after sourcing per-project conf):
#   SSM_INSTANCE_ID         — EC2 instance ID running the wrapper
#   SSM_REMOTE_PROJECT_DIR  — absolute project root on the remote box
#   SSM_REMOTE_PROJECT_ID   — project_id used in remote PID/log paths
#
# Optional env (with defaults):
#   SSM_REGION         (default: ap-southeast-1)
#   SSM_REMOTE_USER    (default: ubuntu)              — sudo -u target
#   SSM_REMOTE_SHELL   (default: bash)                — bash | zsh; runs as login shell
#   SSM_REMOTE_PROFILE (default: empty, no source)    — file to source before INNER_CMD
#                                                       e.g. /home/ubuntu/.bash_aliases
#
# Exit codes:
#   0 — SSM send-command accepted (the remote command is now in flight)
#   1 — input/env validation failure, missing dependency, or aws send-command failed

set -euo pipefail

TYPE="${1:?Usage: dispatch-remote-aws-ssm.sh <dev-new|dev-resume|review> <issue_num> [session_id]}"
ISSUE_NUM="${2:?Missing issue number}"
SESSION_ID="${3:-}"

# ---------------------------------------------------------------------------
# Input validation
# ---------------------------------------------------------------------------
if ! [[ "$ISSUE_NUM" =~ ^[0-9]+$ ]]; then
  echo "ERROR: issue_num must be a positive integer, got: '$ISSUE_NUM'" >&2
  exit 1
fi
if [[ -n "$SESSION_ID" ]] && ! [[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: session_id contains unsafe characters: '$SESSION_ID'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Required env validation
# ---------------------------------------------------------------------------
: "${SSM_INSTANCE_ID:?SSM_INSTANCE_ID required for remote-aws-ssm backend}"
: "${SSM_REMOTE_PROJECT_DIR:?SSM_REMOTE_PROJECT_DIR required (absolute path on remote box)}"
: "${SSM_REMOTE_PROJECT_ID:?SSM_REMOTE_PROJECT_ID required (project_id on remote box)}"

# Validate SSM_REMOTE_PROJECT_ID — used in remote PID/log paths and command
# strings; reject anything that could break shell parsing or path resolution.
if ! [[ "$SSM_REMOTE_PROJECT_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: SSM_REMOTE_PROJECT_ID contains unsafe characters: '$SSM_REMOTE_PROJECT_ID'" >&2
  exit 1
fi
# `_has_shell_metachar` lives in the shared `lib-ssm.sh` (extracted in
# #137 Finding 2.A). Source it before the first call. Use bash parameter
# expansion (`${path%/*}`) instead of `dirname` so that the source line
# works even on PATH-scrubbed test invocations (regression: TC-EB-008
# in test-dispatch-remote-aws-ssm.sh sets PATH= to verify the missing-
# aws code path; that test must keep passing after this refactor).
# [INV-65] This entry sources lib-ssm.sh from its OWN unresolved dir
# (${BASH_SOURCE[0]%/*}, readlink-free — TC-EB-008 runs it under a scrubbed
# PATH with no coreutil reachable). For that to resolve, the CALLER must invoke
# this script from the REAL skill tree, NOT a consumer project-side symlink —
# because the installer no longer symlinks lib-*.sh into <project>/scripts/.
# dispatcher-tick.sh's dispatch() honors this by invoking us via its LIB_DIR
# (the skill tree), where lib-ssm.sh is a real adjacent file. Same rationale as
# liveness-check-remote-aws-ssm.sh (reached via lib-dispatch.sh's skill-tree
# BASH_SOURCE).
_THIS_SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
_THIS_SCRIPT_DIR="${_THIS_SCRIPT_PATH%/*}"
# shellcheck source=lib-ssm.sh
source "${_THIS_SCRIPT_DIR}/lib-ssm.sh"

if [[ "$SSM_REMOTE_PROJECT_DIR" != /* ]] || _has_shell_metachar "$SSM_REMOTE_PROJECT_DIR"; then
  echo "ERROR: SSM_REMOTE_PROJECT_DIR must be an absolute path with no shell metachars: '$SSM_REMOTE_PROJECT_DIR'" >&2
  exit 1
fi

# Defaults
SSM_REGION="${SSM_REGION:-ap-southeast-1}"
SSM_REMOTE_USER="${SSM_REMOTE_USER:-ubuntu}"
SSM_REMOTE_SHELL="${SSM_REMOTE_SHELL:-bash}"
SSM_REMOTE_PROFILE="${SSM_REMOTE_PROFILE:-}"

# Validate user/shell — embedded into a shell command on the remote side.
if ! [[ "$SSM_REMOTE_USER" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: SSM_REMOTE_USER contains unsafe characters: '$SSM_REMOTE_USER'" >&2
  exit 1
fi
if ! [[ "$SSM_REMOTE_SHELL" =~ ^(bash|zsh|sh)$ ]]; then
  echo "ERROR: SSM_REMOTE_SHELL must be bash, zsh, or sh; got: '$SSM_REMOTE_SHELL'" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
for cmd in aws jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: required command '$cmd' not found in PATH" >&2
    exit 1
  }
done

# ---------------------------------------------------------------------------
# Build the remote command
# ---------------------------------------------------------------------------
# The remote box runs its own dispatch-local.sh, which handles PID guard,
# kill-stale-wrapper, and nohup'd wrapper spawn. SSM is just a shell over it.
#
# The remote dispatch-local.sh is at $SSM_REMOTE_PROJECT_DIR/scripts/dispatch-local.sh.
# We pass PROJECT_DIR and PROJECT_ID via env so the remote script picks
# them up — same convention dispatch-local.sh uses today.
DISPATCH_LOCAL="${SSM_REMOTE_PROJECT_DIR}/scripts/dispatch-local.sh"

# Build inner command — what runs on the remote box as $SSM_REMOTE_USER.
# Profile-source prefix is opt-in; default is no profile load (vanilla
# login shell PATH only).
prefix=""
if [[ -n "$SSM_REMOTE_PROFILE" ]]; then
  # The profile path is operator-controlled; same metachar gate as
  # SSM_REMOTE_PROJECT_DIR (PR-9 review C2: previously this only checked
  # absoluteness, leaving `'` / newlines / `$()` open to remote RCE).
  if [[ "$SSM_REMOTE_PROFILE" != /* ]] || _has_shell_metachar "$SSM_REMOTE_PROFILE"; then
    echo "ERROR: SSM_REMOTE_PROFILE must be an absolute path with no shell metachars: '$SSM_REMOTE_PROFILE'" >&2
    exit 1
  fi
  prefix="source ${SSM_REMOTE_PROFILE}; "
fi

case "$TYPE" in
  dev-new)
    INNER_CMD="${prefix}PROJECT_DIR=${SSM_REMOTE_PROJECT_DIR} PROJECT_ID=${SSM_REMOTE_PROJECT_ID} bash ${DISPATCH_LOCAL} dev-new ${ISSUE_NUM}"
    COMMENT="${SSM_REMOTE_PROJECT_ID}: new dev task for issue #${ISSUE_NUM}"
    ;;
  dev-resume)
    # Empty SESSION_ID is tolerated: dispatcher-tick.sh Step 4 dispatches
    # dev-resume on every pending-dev pass, including first-time pickup
    # with no prior `Dev Session ID:` comment. The remote dispatch-local.sh
    # handles empty session by spawning the wrapper without --session,
    # and autonomous-dev.sh:257-260 falls back to MODE=new. Mirrors the
    # local-backend tolerance so SSM users see the same Step 4 fix. (#107)
    if [[ -n "$SESSION_ID" ]]; then
      INNER_CMD="${prefix}PROJECT_DIR=${SSM_REMOTE_PROJECT_DIR} PROJECT_ID=${SSM_REMOTE_PROJECT_ID} bash ${DISPATCH_LOCAL} dev-resume ${ISSUE_NUM} ${SESSION_ID}"
    else
      INNER_CMD="${prefix}PROJECT_DIR=${SSM_REMOTE_PROJECT_DIR} PROJECT_ID=${SSM_REMOTE_PROJECT_ID} bash ${DISPATCH_LOCAL} dev-resume ${ISSUE_NUM}"
    fi
    COMMENT="${SSM_REMOTE_PROJECT_ID}: resume dev for issue #${ISSUE_NUM}"
    ;;
  review)
    INNER_CMD="${prefix}PROJECT_DIR=${SSM_REMOTE_PROJECT_DIR} PROJECT_ID=${SSM_REMOTE_PROJECT_ID} bash ${DISPATCH_LOCAL} review ${ISSUE_NUM}"
    COMMENT="${SSM_REMOTE_PROJECT_ID}: review task for issue #${ISSUE_NUM}"
    ;;
  *)
    echo "ERROR: unknown type '$TYPE'. Use dev-new, dev-resume, or review" >&2
    exit 1
    ;;
esac

# Wrap in sudo + login shell so the remote profile (when set) is loaded
# correctly. -l on bash/zsh means "act as a login shell" → reads
# /etc/profile, ~/.profile (or ~/.zprofile), making PATH and env vars
# available. The explicit `source $SSM_REMOTE_PROFILE` above is for
# files that interactive shells normally don't load (~/.bash_aliases).
FULL_CMD="sudo -u ${SSM_REMOTE_USER} ${SSM_REMOTE_SHELL} -l -c '${INNER_CMD}'"

# Build the SSM commands JSON safely. jq -n --arg quotes the value as a JSON
# string with all escaping handled — guards against shell-injection in any
# of the operator-controlled fields above (CWE-78).
COMMANDS_JSON=$(jq -n --arg cmd "$FULL_CMD" '[$cmd]')

# ---------------------------------------------------------------------------
# Send the SSM command
# ---------------------------------------------------------------------------
SSM_OUTPUT=$(aws ssm send-command \
  --instance-ids "$SSM_INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --region "$SSM_REGION" \
  --parameters "{\"commands\": $COMMANDS_JSON}" \
  --comment "$COMMENT" \
  --output json) || {
  echo "ERROR: SSM send-command failed for instance $SSM_INSTANCE_ID in region $SSM_REGION" >&2
  exit 1
}

# Surface CommandId so cron logs can tie back to the remote-side run.
echo "$SSM_OUTPUT" | jq '{CommandId: .Command.CommandId, Status: .Command.Status, InstanceId: "'"$SSM_INSTANCE_ID"'"}'
