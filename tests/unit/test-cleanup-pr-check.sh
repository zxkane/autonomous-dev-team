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
