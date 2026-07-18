#!/bin/bash
# test-cleanup-pr-check.sh — Unit tests for cleanup trap PR existence check
#
# Verifies that autonomous-dev.sh checks for PR existence before setting
# pending-review on exit code 0.
# Verifies fix for issue #40.
# Run: bash tests/unit/test-cleanup-pr-check.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected to contain '$needle')"
    ((FAIL++))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (should NOT contain '$needle')"
    ((FAIL++))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected='$expected' actual='$actual')"
    ((FAIL++))
  fi
}

DEV_SCRIPT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"

if [[ ! -f "$DEV_SCRIPT" ]]; then
  echo -e "${RED}FATAL${NC}: autonomous-dev.sh not found at $DEV_SCRIPT"
  exit 1
fi

CONTENT=$(cat "$DEV_SCRIPT")

# ===========================================================================
# TC-CPC-001: Script contains PR existence check in cleanup
# ===========================================================================
echo ""
echo "=== TC-CPC-001: Cleanup has PR existence check ==="
echo ""

assert_contains "PR_EXISTS variable in script" 'PR_EXISTS' "$CONTENT"
assert_contains "gh pr list check for issue number" 'gh pr list' "$CONTENT"

# ===========================================================================
# TC-CPC-002: Script posts warning when exit 0 but no PR
# ===========================================================================
echo ""
echo "=== TC-CPC-002: Warning message for exit 0 without PR ==="
echo ""

assert_contains "Warning about no PR created" 'no PR was created' "$CONTENT"
assert_contains "Sets pending-dev on no PR" 'pending-dev' "$CONTENT"

# ===========================================================================
# TC-CPC-003: Script still sets pending-review when PR exists
# ===========================================================================
echo ""
echo "=== TC-CPC-003: pending-review still set when PR exists ==="
echo ""

assert_contains "pending-review label transition" 'pending-review' "$CONTENT"

# ===========================================================================
# TC-CPC-004: Non-zero exit still goes to pending-dev (unchanged)
# ===========================================================================
echo ""
echo "=== TC-CPC-004: Non-zero exit → pending-dev (unchanged) ==="
echo ""

assert_contains "Failure branch exists" 'Agent failed' "$CONTENT"

# ===========================================================================
# TC-CPC-005: The PR check uses the ISSUE_NUMBER variable
# ===========================================================================
echo ""
echo "=== TC-CPC-005: PR check references ISSUE_NUMBER ==="
echo ""

assert_contains "PR check uses ISSUE_NUMBER" 'ISSUE_NUMBER' "$CONTENT"

# ===========================================================================
# TC-CPC-006: non-SIGTERM exit-0 path with a successful zero-match read stays
# byte-unchanged by #500's SIGTERM-scoped retry/defer fix — single lookup,
# "no PR was created" comment, pending-dev flip.
# ===========================================================================
echo ""
echo "=== TC-CPC-006: exit-0 + successful zero-match read (no SIGTERM) → unchanged ==="
echo ""

CLEANUP_FN=$(awk '/^cleanup\(\) \{/,/^\}/' "$DEV_SCRIPT")
if [[ -z "$CLEANUP_FN" ]]; then
  echo -e "${RED}FATAL${NC}: could not extract cleanup() from $DEV_SCRIPT"
  exit 1
fi

TMPROOT_CPC=$(mktemp -d)
trap 'rm -rf "$TMPROOT_CPC"' EXIT

GH_RECORD="$TMPROOT_CPC/gh.log"
CALL_COUNT_FILE="$TMPROOT_CPC/calls.log"
SLEEP_COUNT_FILE="$TMPROOT_CPC/sleeps.log"
: > "$GH_RECORD"; : > "$CALL_COUNT_FILE"; : > "$SLEEP_COUNT_FILE"

# Same extraction-based harness technique as test-sigterm-trap.sh's
# run_retry_cleanup and test-autonomous-dev-cleanup-startup-failure.sh:
# stub every cleanup()-called helper, seed exit_code via `(exit 0)`, and
# run the real cleanup() fragment verbatim so drift is caught.
env -u ADT_GUARD_FD -u ADT_LANE_DIR -u ADT_LANE_ID -u ADT_STATE_ROOT \
    -u RUN_DIR -u RUN_ID \
    -u AGENT_PROGRESS_FILE -u AGENT_PROGRESS_RUNID_FILE \
    -u AGENT_PID_FILE -u AGENT_PR_CREATE_FILE -u AGENT_BOT_TRIGGER_FILE \
PATH="/usr/bin:/bin" \
GH_RECORD="$GH_RECORD" \
CALL_COUNT_FILE="$CALL_COUNT_FILE" \
SLEEP_COUNT_FILE="$SLEEP_COUNT_FILE" \
AGENT_RAN="true" \
ISSUE_NUMBER="77" \
REPO="acme/widget" \
PID_FILE="/dev/null" \
SESSION_ID="test-session" \
LOG_FILE="/tmp/test-cpc.log" \
GH_AUTH_MODE="token" \
RECEIVED_SIGTERM="0" \
MODE="new" \
AGENT_CMD="claude" \
AGENT_DEV_MODEL="sonnet" \
bash -c "
  set +e
  log() { echo \"[test-log] \$*\" >&2; }
  cleanup_github_auth() { :; }
  itp_post_comment() { echo \"GH issue comment \$1 --repo \$REPO --body \$2\" >> \"\$GH_RECORD\"; }
  itp_transition_state() {
    local args=()
    [ -n \"\$2\" ] && args+=(--remove-label \"\$2\")
    [ -n \"\$3\" ] && args+=(--add-label \"\$3\")
    echo \"GH issue edit \$1 --repo \$REPO \${args[*]}\" >> \"\$GH_RECORD\"
  }
  terminal_intent_cleanup_transition() { itp_transition_state \"\$1\" \"\$3\" \"\$4\"; }
  drain_agent_pr_create() { return 0; }
  drain_agent_bot_triggers() { echo \"BOT-TRIGGER-DRAIN \$1\" >> \"\$GH_RECORD\"; return 0; }
  rearm_gh_resolution() { :; }
  sleep() { echo \"\$1\" >> \"\$SLEEP_COUNT_FILE\"; }
  chp_pr_list() {
    echo call >> \"\$CALL_COUNT_FILE\"
    echo '[{\"body\":\"unrelated text\"}]'
    return 0
  }
  $CLEANUP_FN
  (exit 0); cleanup
" 2>"$TMPROOT_CPC/stderr.log"

CPC006_GH_LOG=$(cat "$GH_RECORD")
CPC006_CALL_COUNT=$(wc -l < "$CALL_COUNT_FILE" | tr -d '[:space:]')
CPC006_SLEEP_COUNT=$(wc -l < "$SLEEP_COUNT_FILE" | tr -d '[:space:]')

assert_eq "TC-CPC-006 exactly 1 chp_pr_list call (no SIGTERM ⇒ no retry, #500 D2 pin)" \
  "1" "$CPC006_CALL_COUNT"
assert_eq "TC-CPC-006 no sleep (single-attempt fail-soft contract unchanged)" \
  "0" "$CPC006_SLEEP_COUNT"
assert_contains "TC-CPC-006 posts the 'no PR was created' comment" \
  "no PR was created" "$CPC006_GH_LOG"
assert_contains "TC-CPC-006 flips to pending-dev" \
  "--add-label pending-dev" "$CPC006_GH_LOG"
assert_not_contains "TC-CPC-006 never routes to pending-review" \
  "--add-label pending-review" "$CPC006_GH_LOG"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo -e "Total: $TOTAL  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
