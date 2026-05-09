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

# PR-3 moved the retry-counter logic from SKILL.md to lib-dispatch.sh.
SKILL_MD=$(mktemp)
cat \
  "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh" \
  "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh" \
  > "$SKILL_MD"
trap 'rm -f "$SKILL_MD"' EXIT

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
# PR-3 lowercased the local variable to last_stalled_at in lib-dispatch.sh.
assert_contains "Has last_stalled_at cutoff variable" 'last_stalled_at' "$CONTENT"

# ===========================================================================
# TC-RCR-002: SKILL.md filters crashes by timestamp
# ===========================================================================
echo ""
echo "=== TC-RCR-002: Filters crashes after stalled cutoff ==="
echo ""

assert_contains "Filters by createdAt" 'createdAt' "$CONTENT"
assert_contains "Compares timestamps for crash filtering" 'last_stalled_at' "$CONTENT"

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

# Grab the multi-line DISPATCHER_CRASHES=... statement as a blob and run
# semantic checks against it directly. This approach does NOT depend on a
# specific quoting style (\", '"', heredoc) — any future reformat that keeps
# the statement textually present will still be guarded. Uses -A3 to tolerate
# line breaks within the statement (the real block is 2 lines today).
# PR-3 moved this from inline DISPATCHER_CRASHES= into a function.
# count_dispatcher_crashes() now has TWO test() calls in its body:
#   1. test("Marking as stalled")     — locates the cutoff timestamp
#   2. test("Task appears...|process") — the actual crash-regex
# Only #2 is the one we're regression-guarding (broadening it would re-
# introduce the false-positive bug). Grab only the line with the crash regex.
DISPATCHER_CRASH_STMT=$(awk '/^count_dispatcher_crashes\(\)/,/^}$/' "$SKILL_MD" \
  | grep -E "Task appears to have crashed|process not found")

if [[ -z "$DISPATCHER_CRASH_STMT" ]]; then
  echo -e "  ${RED}FAIL${NC}: crash-regex line not found in count_dispatcher_crashes() — layout changed, guard is blind"
  ((FAIL++))
else
  # Expect exactly one test() call on this line — i.e. the crash regex itself.
  # More than one means a second alternative was chained in and the retry
  # counter was broadened.
  TEST_CALL_COUNT=$(grep -oE 'test\(' <<<"$DISPATCHER_CRASH_STMT" | wc -l | tr -d ' ')
  if [[ "$TEST_CALL_COUNT" != "1" ]]; then
    echo -e "  ${RED}FAIL${NC}: crash-regex line has $TEST_CALL_COUNT test() calls, expected 1 (a chained test() may have broadened the retry counter)"
    ((FAIL++))
  else
    echo -e "  ${GREEN}PASS${NC}: crash-regex line has exactly one test() call"
    ((PASS++))
  fi

  # Required: the two explicit Step 5 crash preambles
  assert_contains "Statement includes '(no PR found)' alternative" \
    'Task appears to have crashed \\\\(no PR found\\\\)' "$DISPATCHER_CRASH_STMT"
  assert_contains "Statement includes 'process not found' alternative" \
    'process not found' "$DISPATCHER_CRASH_STMT"

  # Forbidden: the old over-broad alternatives
  assert_not_contains "Statement does not re-add 'crashed. PR found' alternative" \
    'crashed\\\\. PR found' "$DISPATCHER_CRASH_STMT"
  assert_not_contains "Statement does not re-add bare 'Task appears to have crashed|' alternative" \
    'Task appears to have crashed|' "$DISPATCHER_CRASH_STMT"
fi

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
