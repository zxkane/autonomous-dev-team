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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."
if [[ -f "${REPO_ROOT}/scripts/autonomous.conf" ]]; then
  source "${REPO_ROOT}/scripts/autonomous.conf"
fi

PROJECT_ID="${PROJECT_ID:-project}"
PROJECT_DIR="${PROJECT_DIR:?Set PROJECT_DIR in autonomous.conf}"

case "$TYPE" in
  dev-new)
    nohup "${PROJECT_DIR}/scripts/autonomous-dev.sh" \
      --issue "$ISSUE_NUM" --mode new \
      > "/tmp/cc-${PROJECT_ID}-issue-${ISSUE_NUM}.log" 2>&1 &
    CHILD_PID=$!
    ;;
  dev-resume)
    if [[ -z "$SESSION_ID" ]]; then
      echo "ERROR: session_id required for dev-resume" >&2
      exit 1
    fi
    nohup "${PROJECT_DIR}/scripts/autonomous-dev.sh" \
      --issue "$ISSUE_NUM" --mode resume --session "$SESSION_ID" \
      > "/tmp/cc-${PROJECT_ID}-issue-${ISSUE_NUM}.log" 2>&1 &
    CHILD_PID=$!
    ;;
  review)
    nohup "${PROJECT_DIR}/scripts/autonomous-review.sh" \
      --issue "$ISSUE_NUM" \
      > "/tmp/cc-${PROJECT_ID}-review-${ISSUE_NUM}.log" 2>&1 &
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
  echo "ERROR: ${TYPE} process for issue #${ISSUE_NUM} exited immediately. Check log: /tmp/cc-${PROJECT_ID}-*-${ISSUE_NUM}.log" >&2
  exit 1
fi
echo "Dispatched ${TYPE} for issue #${ISSUE_NUM} (PID: ${CHILD_PID})"
