#!/bin/bash
# test-dev-near-success.sh — Regression for issue #121 Fix B.
#
# Step 5b dev branch must NOT post "Task appears to have crashed (no PR
# found)" on a bare `pid_alive` miss when any of these in-flight signals
# are positive within DEV_NEAR_SUCCESS_WINDOW_SECONDS:
#
#   1. Most recent `Agent Session Report (Dev) ... Exit code: 0`
#      comment within window — agent already finished successfully.
#   2. Most recent `Dev Session ID:` comment within window — agent
#      confirmed startup recently; pid_alive miss is a transient race.
#   3. Defensive `kill -0 <pid>` re-check now succeeds (pid_alive race).
#
# Mirrors the test-dispatcher-review-near-success.sh shape: extract the
# decision logic into `dev_near_success`, mock the helpers it queries,
# assert on return code.
#
# Also pins the structural placement of the call site in
# dispatcher-tick.sh (Step 5b dev branch, before the crash comment).
#
# Run: bash tests/unit/test-dev-near-success.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-dns
export MAX_RETRIES=3
export MAX_CONCURRENT=5
export DEV_NEAR_SUCCESS_WINDOW_SECONDS="${DEV_NEAR_SUCCESS_WINDOW_SECONDS:-300}"

# Mocks — overridden per test case.
_MOCK_LAST_SUCCESS_AGE=""
_MOCK_LAST_STARTUP_AGE=""
_MOCK_PID=""
_MOCK_KILL0_RC="1"

latest_dev_success_age_seconds() {
  printf '%s' "$_MOCK_LAST_SUCCESS_AGE"
}
latest_dev_session_id_age_seconds() {
  printf '%s' "$_MOCK_LAST_STARTUP_AGE"
}
get_pid() {
  printf '%s' "$_MOCK_PID"
}
kill() {
  if [ "${1:-}" = "-0" ]; then
    return "$_MOCK_KILL0_RC"
  fi
  command kill "$@"
}

# shellcheck disable=SC1090
source "$LIB"
set +e

# Re-export overrides (sourcing the lib re-defines them; our mocks win).
latest_dev_success_age_seconds() {
  printf '%s' "$_MOCK_LAST_SUCCESS_AGE"
}
latest_dev_session_id_age_seconds() {
  printf '%s' "$_MOCK_LAST_STARTUP_AGE"
}
get_pid() {
  printf '%s' "$_MOCK_PID"
}
kill() {
  if [ "${1:-}" = "-0" ]; then
    return "$_MOCK_KILL0_RC"
  fi
  command kill "$@"
}

reset_mocks() {
  _MOCK_LAST_SUCCESS_AGE=""
  _MOCK_LAST_STARTUP_AGE=""
  _MOCK_PID=""
  _MOCK_KILL0_RC="1"
  export DEV_NEAR_SUCCESS_WINDOW_SECONDS=300
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected: $expected"
    echo "      actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# ===================================================================
echo "=== TC-DNS-001..009: dev_near_success helper ==="

# TC-DNS-001 — Session Report Exit code: 0 within window
reset_mocks
_MOCK_LAST_SUCCESS_AGE="60"
dev_near_success 1
assert_eq "TC-DNS-001 recent SUCCESS Session Report -> skip crash" "0" "$?"

# TC-DNS-002 — same signal but outside window
reset_mocks
_MOCK_LAST_SUCCESS_AGE="600"
dev_near_success 2
assert_eq "TC-DNS-002 stale SUCCESS Session Report -> proceed" "1" "$?"

# TC-DNS-003 — Dev Session ID within window
reset_mocks
_MOCK_LAST_STARTUP_AGE="60"
dev_near_success 3
assert_eq "TC-DNS-003 recent Dev Session ID -> skip crash" "0" "$?"

# TC-DNS-004 — Dev Session ID outside window
reset_mocks
_MOCK_LAST_STARTUP_AGE="600"
dev_near_success 4
assert_eq "TC-DNS-004 stale Dev Session ID -> proceed" "1" "$?"

# TC-DNS-005 — Defensive kill -0 succeeds
reset_mocks
_MOCK_PID="12345"
_MOCK_KILL0_RC="0"
dev_near_success 5
assert_eq "TC-DNS-005 live PID (kill -0 OK) -> skip crash" "0" "$?"

# TC-DNS-006 — All three signals negative
reset_mocks
dev_near_success 6
assert_eq "TC-DNS-006 all signals negative -> proceed" "1" "$?"

# TC-DNS-007 — DEV_NEAR_SUCCESS_WINDOW_SECONDS=0 disables short-circuit
reset_mocks
_MOCK_LAST_SUCCESS_AGE="60"
_MOCK_LAST_STARTUP_AGE="60"
_MOCK_PID="12345"
_MOCK_KILL0_RC="0"
export DEV_NEAR_SUCCESS_WINDOW_SECONDS=0
dev_near_success 7
assert_eq "TC-DNS-007 window=0 disables short-circuit -> proceed" "1" "$?"

# TC-DNS-008 — non-numeric window -> fallback to legacy strict
reset_mocks
_MOCK_LAST_SUCCESS_AGE="60"
export DEV_NEAR_SUCCESS_WINDOW_SECONDS=abc
dev_near_success 8
assert_eq "TC-DNS-008 non-numeric window -> fallback to legacy strict (proceed)" "1" "$?"

# TC-DNS-009 — Mixed: SUCCESS recent + Session ID stale + dead PID -> first signal wins
reset_mocks
_MOCK_LAST_SUCCESS_AGE="60"
_MOCK_LAST_STARTUP_AGE="600"
_MOCK_PID="12345"
_MOCK_KILL0_RC="1"
dev_near_success 9
assert_eq "TC-DNS-009 mixed bag (SUCCESS recent wins) -> skip crash" "0" "$?"

# ===================================================================
echo
echo "=== TC-DNS-INT-001..003: dispatcher-tick.sh structural placement ==="

dev_near_call_line=$(grep -nE 'dev_near_success' "$TICK" | head -1 | cut -d: -f1)
if [[ -n "$dev_near_call_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-DNS-INT-001 dev_near_success invocation present at line $dev_near_call_line"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-DNS-INT-001 dev_near_success invocation absent in dispatcher-tick.sh"
  FAIL=$((FAIL + 1))
fi

crash_line=$(grep -nE 'Task appears to have crashed \(no PR found\)' "$TICK" | head -1 | cut -d: -f1)
if [[ -n "$dev_near_call_line" && -n "$crash_line" && "$dev_near_call_line" -lt "$crash_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-DNS-INT-002 dev_near_success (line $dev_near_call_line) < crash comment (line $crash_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-DNS-INT-002 dev_near_success not before crash comment (dns=$dev_near_call_line crash=$crash_line)"
  FAIL=$((FAIL + 1))
fi

if grep -qE 'INV-27' "$TICK"; then
  echo -e "  ${GREEN}PASS${NC}: TC-DNS-INT-003 INV-27 reference in dispatcher-tick.sh"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-DNS-INT-003 No INV-27 reference in dispatcher-tick.sh"
  FAIL=$((FAIL + 1))
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
