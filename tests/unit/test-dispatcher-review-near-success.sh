#!/bin/bash
# test-dispatcher-review-near-success.sh — Unit tests for issue #111.
#
# Step 5b review branch must NOT declare a wrapper "crashed" on a bare
# `pid_alive` miss when any of these PR-state signals are positive within
# REVIEW_NEAR_SUCCESS_WINDOW_SECONDS:
#
#   1. PR.mergedAt within window
#   2. Most recent APPROVED review event within window
#   3. Most recent "Review PASSED|findings" verdict comment within window
#   4. Defensive `kill -0 <pid>` re-check now succeeds (pid_alive race)
#
# The cross-check logic is extracted into a new lib-dispatch.sh helper
# `review_near_success` so it can be unit tested in isolation.
#
# Run: bash tests/unit/test-dispatcher-review-near-success.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Required env (lib-dispatch.sh enforces these via : "${VAR:?...}")
export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-proj
export MAX_RETRIES=3
export MAX_CONCURRENT=5
export REVIEW_NEAR_SUCCESS_WINDOW_SECONDS="${REVIEW_NEAR_SUCCESS_WINDOW_SECONDS:-300}"

# ---------------------------------------------------------------------------
# Mocks — overridden per test case.
# ---------------------------------------------------------------------------
_MOCK_PR_INFO=""        # JSON returned by fetch_pr_for_issue_with_reviews
_MOCK_VERDICT_AGE=""    # seconds since most recent verdict comment ("" = none)
_MOCK_PID=""            # PID stored "in" the PID file
_MOCK_KILL0_RC="1"      # rc returned by defensive kill -0 (0 = alive)
_MOCK_PGREP_AGENT_FOUND="0"  # signal 5 (#132): 1 = pgrep -g <pgid> finds an AGENT_CMD child
_MOCK_PGREP_CALLED="0"  # observability: incremented each time the pgrep stub is consulted

# Override fetch helper used by review_near_success.
fetch_pr_for_issue() {
  printf '%s' "$_MOCK_PR_INFO"
}

# review_near_success uses this helper to read seconds since the most
# recent review-agent verdict comment.
latest_review_verdict_age_seconds() {
  printf '%s' "$_MOCK_VERDICT_AGE"
}

# get_pid is overridden to return a deterministic PID.
get_pid() {
  printf '%s' "$_MOCK_PID"
}

# Override kill so the defensive re-check is deterministic.
# kill -0 <pid> is the only invocation we care about here.
kill() {
  if [ "${1:-}" = "-0" ]; then
    return "$_MOCK_KILL0_RC"
  fi
  command kill "$@"
}

# Signal 5 helper (#132): mock the lib-dispatch.sh helper that walks the
# review wrapper's process group looking for an AGENT_CMD child. Tests
# control its return code via _MOCK_PGREP_AGENT_FOUND, and inspect
# _MOCK_PGREP_CALLED to assert ordering / defensive-guard behaviour.
_review_pgid_has_agent_process() {
  _MOCK_PGREP_CALLED=$((_MOCK_PGREP_CALLED + 1))
  [ "$_MOCK_PGREP_AGENT_FOUND" = "1" ]
}

# Source the lib AFTER the mocks so the helpers can be redefined.
# shellcheck disable=SC1090
source "$LIB"
# lib-dispatch.sh sets -e; turn it off so the assertion harness can
# capture failing return codes without aborting the test process.
set +e

# Re-export overrides (sourcing the lib re-defines fetch_pr_for_issue /
# get_pid; we need our mocks to win).
fetch_pr_for_issue() {
  printf '%s' "$_MOCK_PR_INFO"
}
get_pid() {
  printf '%s' "$_MOCK_PID"
}
latest_review_verdict_age_seconds() {
  printf '%s' "$_MOCK_VERDICT_AGE"
}
_review_pgid_has_agent_process() {
  _MOCK_PGREP_CALLED=$((_MOCK_PGREP_CALLED + 1))
  [ "$_MOCK_PGREP_AGENT_FOUND" = "1" ]
}

reset_mocks() {
  _MOCK_PR_INFO=""
  _MOCK_VERDICT_AGE=""
  _MOCK_PID=""
  _MOCK_KILL0_RC="1"
  _MOCK_PGREP_AGENT_FOUND="0"
  _MOCK_PGREP_CALLED="0"
}

assert() {
  local label="$1" rc="$2" expected_rc="$3"
  if [ "$rc" = "$expected_rc" ]; then
    echo -e "  ${GREEN}PASS${NC}: $label (rc=$rc)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $label (got rc=$rc, expected rc=$expected_rc)"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local label="$1" actual="$2" expected="$3"
  if [ "$actual" = "$expected" ]; then
    echo -e "  ${GREEN}PASS${NC}: $label ($actual)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $label (got '$actual', expected '$expected')"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------

echo
echo "=== TC-RNS-001: PR mergedAt within window → returns 0 (skip crash) ==="
reset_mocks
recent_iso=$(date -u -d "@$(( $(date -u +%s) - 60 ))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -v-60S +"%Y-%m-%dT%H:%M:%SZ")
_MOCK_PR_INFO=$(printf '{"number":42,"mergedAt":"%s","reviews":[]}' "$recent_iso")
REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=300 review_near_success 42
assert "recent merge → near-success" "$?" "0"

echo
echo "=== TC-RNS-002: most recent APPROVED review within window → 0 ==="
reset_mocks
recent_iso=$(date -u -d "@$(( $(date -u +%s) - 60 ))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -v-60S +"%Y-%m-%dT%H:%M:%SZ")
_MOCK_PR_INFO=$(printf '{"number":42,"mergedAt":null,"reviews":[{"state":"APPROVED","submittedAt":"%s"}]}' "$recent_iso")
REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=300 review_near_success 42
assert "recent APPROVED review → near-success" "$?" "0"

echo
echo "=== TC-RNS-003: recent verdict comment within window → 0 ==="
reset_mocks
_MOCK_PR_INFO='{"number":42,"mergedAt":null,"reviews":[]}'
_MOCK_VERDICT_AGE="60"
REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=300 review_near_success 42
assert "recent verdict comment → near-success" "$?" "0"

echo
echo "=== TC-RNS-004: defensive kill -0 re-check succeeds → 0 ==="
reset_mocks
_MOCK_PR_INFO='{"number":42,"mergedAt":null,"reviews":[]}'
_MOCK_PID="99999"
_MOCK_KILL0_RC="0"
REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=300 review_near_success 42
assert "defensive PID re-check alive → near-success" "$?" "0"

echo
echo "=== TC-RNS-005: all signals negative → returns 1 (caller proceeds) ==="
reset_mocks
old_iso=$(date -u -d "@$(( $(date -u +%s) - 99999 ))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -v-99999S +"%Y-%m-%dT%H:%M:%SZ")
_MOCK_PR_INFO=$(printf '{"number":42,"mergedAt":"%s","reviews":[{"state":"COMMENTED","submittedAt":"%s"}]}' "$old_iso" "$old_iso")
_MOCK_VERDICT_AGE=""
_MOCK_PID="99999"
_MOCK_KILL0_RC="1"
REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=300 review_near_success 42
assert "all negative → declare crashed" "$?" "1"

echo
echo "=== TC-RNS-006: REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=0 disables short-circuit ==="
reset_mocks
recent_iso=$(date -u -d "@$(( $(date -u +%s) - 60 ))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -v-60S +"%Y-%m-%dT%H:%M:%SZ")
_MOCK_PR_INFO=$(printf '{"number":42,"mergedAt":"%s","reviews":[]}' "$recent_iso")
REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=0 review_near_success 42
assert "window=0 → legacy strict (return 1)" "$?" "1"

echo
echo "=== TC-RNS-007: process-group signal alone short-circuits when 4 legacy signals all negative (#132) ==="
# Reproduces the podcast-curation #209 16:00:39Z window: PR not merged, no
# APPROVED, no verdict comment, defensive kill -0 misses, but a long-running
# review wrapper still has agent-CLI children alive in its PGID.
reset_mocks
old_iso=$(date -u -d "@$(( $(date -u +%s) - 99999 ))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -v-99999S +"%Y-%m-%dT%H:%M:%SZ")
_MOCK_PR_INFO=$(printf '{"number":42,"mergedAt":"%s","reviews":[{"state":"COMMENTED","submittedAt":"%s"}]}' "$old_iso" "$old_iso")
_MOCK_VERDICT_AGE=""
_MOCK_PID="12345"
_MOCK_KILL0_RC="1"
_MOCK_PGREP_AGENT_FOUND="1"
REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=300 review_near_success 42
assert "pgrep finds agent in PGID → near-success" "$?" "0"
assert_eq "pgrep helper consulted exactly once" "$_MOCK_PGREP_CALLED" "1"

echo
echo "=== TC-RNS-008: all five signals negative → declares crashed (#132) ==="
reset_mocks
_MOCK_PR_INFO=$(printf '{"number":42,"mergedAt":"%s","reviews":[{"state":"COMMENTED","submittedAt":"%s"}]}' "$old_iso" "$old_iso")
_MOCK_VERDICT_AGE=""
_MOCK_PID="12345"
_MOCK_KILL0_RC="1"
_MOCK_PGREP_AGENT_FOUND="0"
REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=300 review_near_success 42
assert "all five negative → declare crashed" "$?" "1"

echo
echo "=== TC-RNS-009: legacy positive signal short-circuits BEFORE the new signal runs (#132 ordering pin) ==="
# Cost / ordering invariant: pgrep is the most expensive signal (pings the
# kernel proc table); when an earlier signal already says ALIVE we must
# NEVER reach the pgrep helper. Without this pin a future refactor could
# reorder and silently double the per-tick cost.
reset_mocks
_MOCK_PR_INFO='{"number":42,"mergedAt":null,"reviews":[]}'
_MOCK_VERDICT_AGE="60"  # signal 3 positive
_MOCK_PGREP_AGENT_FOUND="0"
REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=300 review_near_success 42
assert "verdict-age positive → near-success" "$?" "0"
assert_eq "pgrep helper NOT consulted (legacy signal won)" "$_MOCK_PGREP_CALLED" "0"

echo
echo "=== TC-RNS-010: WINDOW=0 strict knob still wins over the new signal (#132) ==="
# Ops escape hatch: even if the new signal would have rescued, the strict
# knob disables the entire short-circuit at the early numeric guard.
reset_mocks
_MOCK_PGREP_AGENT_FOUND="1"
REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=0 review_near_success 42
assert "window=0 → strict (return 1 even with pgrep positive)" "$?" "1"
assert_eq "pgrep helper NOT consulted under strict knob" "$_MOCK_PGREP_CALLED" "0"

echo
echo "=== TC-RNS-011: empty PID file → pgrep skipped silently (#132 defensive guard) ==="
# Race with kill_stale_wrapper deletion or wrapper crash before
# acquire_pid_guard wrote anything: PID content is empty / unparseable.
# The new signal MUST skip silently rather than calling pgrep with garbage.
reset_mocks
_MOCK_PR_INFO=$(printf '{"number":42,"mergedAt":"%s","reviews":[{"state":"COMMENTED","submittedAt":"%s"}]}' "$old_iso" "$old_iso")
_MOCK_VERDICT_AGE=""
_MOCK_PID=""             # empty PID file
_MOCK_KILL0_RC="1"
_MOCK_PGREP_AGENT_FOUND="1"  # would say positive IF asked
REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=300 review_near_success 42
assert "empty PID + 4 legacy negative → declare crashed" "$?" "1"
assert_eq "pgrep helper NOT consulted with empty PID" "$_MOCK_PGREP_CALLED" "0"

echo
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[ "$FAIL" -eq 0 ]
