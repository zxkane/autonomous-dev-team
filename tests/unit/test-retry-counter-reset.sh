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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected NOT to contain '$needle')"
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

# ===========================================================================
# TC-RCR-004: PR-found handoff uses non-crash wording
# ===========================================================================
# Rationale: when the dev process exits after producing a PR, that is forward
# progress (handed to review), not a retry. The Step 5 comment must not contain
# "crashed", so the Step 4 retry-counter regex cannot match it and trigger a
# premature `stalled` label.
echo ""
echo "=== TC-RCR-004: Step 5 'PR found' comment uses non-crash wording ==="
echo ""

assert_contains "Uses 'Dev process exited (PR found)' wording" 'Dev process exited (PR found)' "$CONTENT"
assert_not_contains "Drops old 'crashed. PR found' wording" 'Task appears to have crashed. PR found' "$CONTENT"

# ===========================================================================
# TC-RCR-005: Retry-counter regex is anchored on explicit Step 5 preambles
# ===========================================================================
# Guards against future edits re-adding a broad `crashed` alternative that
# would substring-match the forward-progress "Dev process exited (PR found)"
# comment and reintroduce the premature-stalled bug.
echo ""
echo "=== TC-RCR-005: Retry-counter regex anchored on explicit preambles ==="
echo ""

# Extract the exact jq test(...) regex argument on the DISPATCHER_CRASHES line
# and assert its full content. This catches ANY broadening — bare `crashed`,
# `crashed. PR found`, `crashed[^(]`, etc. — regardless of shape.
DISPATCHER_CRASH_REGEX=$(grep -A1 '^DISPATCHER_CRASHES=' "$SKILL_MD" \
  | grep -oE 'test\(\\"[^"]*\\"\)' | head -1)

assert_contains "Regex is exactly the two explicit Step 5 preambles" \
  'test(\"Task appears to have crashed \\\\(no PR found\\\\)|process not found\")' \
  "$DISPATCHER_CRASH_REGEX"
assert_not_contains "Regex does not re-add 'crashed. PR found' alternative" \
  'crashed\\\\. PR found' "$DISPATCHER_CRASH_REGEX"

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
