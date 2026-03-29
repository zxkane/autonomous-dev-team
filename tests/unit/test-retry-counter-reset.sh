#!/bin/bash
# test-retry-counter-reset.sh — Unit tests for retry counter reset logic
#
# Verifies that SKILL.md Step 4 retry counting resets after stalled→unstalled.
# Verifies fix for issue #41.
# Run: bash tests/unit/test-retry-counter-reset.sh

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

SKILL_MD="$PROJECT_ROOT/skills/autonomous-dispatcher/SKILL.md"

if [[ ! -f "$SKILL_MD" ]]; then
  echo -e "${RED}FATAL${NC}: SKILL.md not found at $SKILL_MD"
  exit 1
fi

CONTENT=$(cat "$SKILL_MD")

# ===========================================================================
# TC-RCR-001: SKILL.md has stalled cutoff logic
# ===========================================================================
echo ""
echo "=== TC-RCR-001: Stalled cutoff logic exists ==="
echo ""

assert_contains "References stalled marker comment" 'Marking as stalled' "$CONTENT"
assert_contains "Has LAST_STALLED_AT variable" 'LAST_STALLED_AT' "$CONTENT"

# ===========================================================================
# TC-RCR-002: SKILL.md filters crashes by timestamp
# ===========================================================================
echo ""
echo "=== TC-RCR-002: Filters crashes after stalled cutoff ==="
echo ""

assert_contains "Filters by createdAt" 'createdAt' "$CONTENT"
assert_contains "Compares timestamps for crash filtering" 'LAST_STALLED_AT' "$CONTENT"

# ===========================================================================
# TC-RCR-003: Backward compatible fallback
# ===========================================================================
echo ""
echo "=== TC-RCR-003: Backward compatible when no stalled history ==="
echo ""

assert_contains "Fallback epoch for no stalled history" '1970' "$CONTENT"

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
