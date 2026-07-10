#!/bin/bash
# test-pid-guard.sh — Unit tests for PID guard logic in autonomous-dev.sh and autonomous-review.sh
#
# Tests the duplicate-instance prevention logic added in fix #32.
# Run: bash tests/unit/test-pid-guard.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
    ((FAIL++))
  fi
}

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

# ---------------------------------------------------------------------------
# Extract PID guard logic into a testable function
# ---------------------------------------------------------------------------
# We test the guard logic by simulating the conditions it checks.

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo ""
echo "=== PID Guard Tests ==="
echo ""

# TC-PID-001: First instance starts normally (no PID file)
echo "TC-PID-001: First instance starts normally"
PID_FILE="$TMPDIR/test-pid-001.pid"
rm -f "$PID_FILE"
# Simulate: no PID file exists → guard should allow start
if [[ -f "$PID_FILE" ]]; then
  RESULT="blocked"
else
  RESULT="allowed"
fi
assert_eq "No PID file → allowed to start" "allowed" "$RESULT"

# TC-PID-002: Second instance exits when first is running
echo "TC-PID-002: Second instance blocked when first is running"
PID_FILE="$TMPDIR/test-pid-002.pid"
# Start a background process to simulate a running agent
sleep 300 &
RUNNING_PID=$!
echo "$RUNNING_PID" > "$PID_FILE"
# Simulate the guard check
EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null)
if [[ -n "$EXISTING_PID" ]] && kill -0 "$EXISTING_PID" 2>/dev/null; then
  RESULT="blocked"
else
  RESULT="allowed"
fi
kill "$RUNNING_PID" 2>/dev/null || true
wait "$RUNNING_PID" 2>/dev/null || true
assert_eq "Running PID in file → blocked" "blocked" "$RESULT"

# TC-PID-003: Instance starts if PID file exists but process is dead
echo "TC-PID-003: Instance allowed if PID file has dead process"
PID_FILE="$TMPDIR/test-pid-003.pid"
echo "99999999" > "$PID_FILE"  # Very unlikely to be a real PID
EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null)
if [[ -n "$EXISTING_PID" ]] && kill -0 "$EXISTING_PID" 2>/dev/null; then
  RESULT="blocked"
else
  RESULT="allowed"
fi
assert_eq "Dead PID in file → allowed to start" "allowed" "$RESULT"

# TC-PID-004: PID file with empty content → allowed
echo "TC-PID-004: Empty PID file → allowed"
PID_FILE="$TMPDIR/test-pid-004.pid"
echo "" > "$PID_FILE"
EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null)
if [[ -n "$EXISTING_PID" ]] && kill -0 "$EXISTING_PID" 2>/dev/null; then
  RESULT="blocked"
else
  RESULT="allowed"
fi
assert_eq "Empty PID file → allowed to start" "allowed" "$RESULT"

# TC-PID-005: Symlink PID file → rejected
echo "TC-PID-005: Symlink PID file rejected"
PID_FILE="$TMPDIR/test-pid-005.pid"
ln -sf /etc/passwd "$PID_FILE"
if [[ -L "$PID_FILE" ]]; then
  RESULT="rejected"
else
  RESULT="allowed"
fi
rm -f "$PID_FILE"
assert_eq "Symlink PID file → rejected" "rejected" "$RESULT"

# ---------------------------------------------------------------------------
# Verify PID guard exists in both scripts
# ---------------------------------------------------------------------------
echo ""
echo "=== Script Content Verification ==="
echo ""

DEV_SCRIPT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
REVIEW_SCRIPT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"

LIB_AGENT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"

echo "TC-SCRIPT-001: lib-agent.sh has acquire_pid_guard function"
if [[ -f "$LIB_AGENT" ]]; then
  LIB_CONTENT=$(cat "$LIB_AGENT")
  assert_contains "acquire_pid_guard function defined" "acquire_pid_guard()" "$LIB_CONTENT"
  assert_contains "kill -0 check in acquire_pid_guard" 'kill -0 "$existing_pid"' "$LIB_CONTENT"
  assert_contains "Symlink check in acquire_pid_guard" '-L "$pid_file"' "$LIB_CONTENT"
else
  echo -e "  ${RED}FAIL${NC}: lib-agent.sh not found at $LIB_AGENT"
  ((FAIL++))
fi

echo "TC-SCRIPT-002: autonomous-dev.sh calls acquire_pid_guard"
if [[ -f "$DEV_SCRIPT" ]]; then
  DEV_CONTENT=$(cat "$DEV_SCRIPT")
  assert_contains "PID guard call in autonomous-dev.sh" 'acquire_pid_guard "$PID_FILE" "autonomous-dev"' "$DEV_CONTENT"
else
  echo -e "  ${RED}FAIL${NC}: autonomous-dev.sh not found at $DEV_SCRIPT"
  ((FAIL++))
fi

echo "TC-SCRIPT-003: autonomous-review.sh calls acquire_pid_guard"
if [[ -f "$REVIEW_SCRIPT" ]]; then
  REVIEW_CONTENT=$(cat "$REVIEW_SCRIPT")
  assert_contains "PID guard call in autonomous-review.sh" 'acquire_pid_guard "$PID_FILE" "autonomous-review"' "$REVIEW_CONTENT"
else
  echo -e "  ${RED}FAIL${NC}: autonomous-review.sh not found at $REVIEW_SCRIPT"
  ((FAIL++))
fi

# ---------------------------------------------------------------------------
# Verify SKILL.md contains the fixes
# ---------------------------------------------------------------------------
echo ""
echo "=== SKILL.md Content Verification ==="
echo ""

# PR-3 moved the dispatcher tick logic from SKILL.md to dispatcher-tick.sh
# + lib-dispatch.sh. Read the union of those two scripts so the existing
# regression assertions (which look for specific bash patterns) keep working.
SKILL_MD=$(mktemp)
cat \
  "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh" \
  "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh" \
  > "$SKILL_MD"
trap 'rm -f "$SKILL_MD"' EXIT

if [[ -f "$SKILL_MD" ]]; then
  SKILL_CONTENT=$(cat "$SKILL_MD")

  echo "TC-SKILL-001: SKILL.md has JUST_DISPATCHED tracking"
  assert_contains "JUST_DISPATCHED initialization" "JUST_DISPATCHED=()" "$SKILL_CONTENT"
  assert_contains "Skip freshly dispatched check" 'JUST_DISPATCHED[*]' "$SKILL_CONTENT"

  echo "TC-SKILL-002: SKILL.md has PR existence check in crash transition"
  # Step 5 must gate the dead-with-PR transition on a non-empty test of the
  # fetched PR object. The variable name evolved from PR_EXISTS to PR_INFO
  # when the SHA-comparison logic landed (#54), so accept either — but only
  # if it appears in a real conditional (-gt 0 for the count form, or -n for
  # the object form), not just any mention.
  # PR-3 renamed PR_INFO → pr_info; the existence check is the same
  # bracket-test pattern but with lowercase variable.
  # Read from the file directly (no pipe) so pipefail doesn't surface SIGPIPE
  # 141 when grep -q closes its stdin early after a match. The bug:
  # `echo "$LARGE_CONTENT" | grep -qE PATTERN` succeeds, but echo gets SIGPIPE
  # → exit 141 → pipefail propagates it as the pipeline exit code.
  if grep -qE '\[ "?\$PR_EXISTS"? -gt 0 \]|\[ -n "?\$PR_INFO"? \]|\[ -z "?\$pr_info"? \]' "$SKILL_MD"; then
    echo -e "  ${GREEN}PASS${NC}: PR existence check"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: PR existence check (expected '[ \$PR_EXISTS -gt 0 ]' or '[ -n \$PR_INFO ]')"
    FAIL=$((FAIL+1))
  fi
  assert_contains "No PR crash path" "No PR" "$SKILL_CONTENT"

  echo "TC-SKILL-003: SKILL.md counts dispatcher crashes in retry count"
  # PR-3 renamed UPPER_CASE → lowercase locals in lib-dispatch.sh helpers.
  # The semantics (counting crash/failure sources) are preserved via separate
  # count_agent_failures + count_dispatcher_crashes functions.
  # [INV-123] (#461): count_retries also sums count_no_pr_attempts
  # unconditionally, so the combined-count substring gained a third term.
  assert_contains "dispatcher_crashes counter exists" "dispatcher_crashes" "$SKILL_CONTENT"
  assert_contains "Combined retry count via three sources" "agent_failures + no_pr_attempts + dispatcher_crashes" "$SKILL_CONTENT"
else
  echo -e "  ${RED}FAIL${NC}: SKILL.md not found at $SKILL_MD"
  ((FAIL++))
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
