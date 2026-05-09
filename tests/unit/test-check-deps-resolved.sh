#!/bin/bash
# test-check-deps-resolved.sh — Regression tests for #61 (MERGED PR
# dependencies) and #73 (cross-platform grep) in lib-dispatch.sh.
#
# `check_deps_resolved` makes multiple gh calls in sequence:
#   1. `gh issue view N --json body -q .body`           — get the body
#   2. for each dep #M:
#      `gh issue view M --json state -q .state`         — get the state
#
# Mocking this needs a stateful gh that branches on which JSON field is
# requested. We use a router function that inspects argv and dispatches.
#
# Run: bash tests/unit/test-check-deps-resolved.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-proj
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# State: which JSON field was requested + what to return.
# _MOCK_BODY: text the body lookup returns
# _MOCK_STATES: associative array, dep_num → state ("CLOSED" / "MERGED" / "OPEN")
_MOCK_BODY=""
declare -A _MOCK_STATES

gh() {
  local mode="" issue_num=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      view) issue_num="$2"; shift 2 ;;
      --json)
        case "$2" in
          body) mode="body" ;;
          state) mode="state" ;;
        esac
        shift 2
        ;;
      *) shift ;;
    esac
  done
  case "$mode" in
    body)  printf '%s' "$_MOCK_BODY" ;;
    state) printf '%s' "${_MOCK_STATES[$issue_num]:-OPEN}" ;;
  esac
}
export -f gh

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "=== check_deps_resolved: no deps section ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Summary
Some text without a Dependencies section."
unset _MOCK_STATES; declare -A _MOCK_STATES
check_deps_resolved 99
assert_eq "no deps section → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: single CLOSED dep ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Summary
foo

## Dependencies
- #42

## Other"
declare -A _MOCK_STATES; _MOCK_STATES[42]="CLOSED"
check_deps_resolved 99
assert_eq "one CLOSED dep → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: single MERGED dep [INV-11, #61 fix] ==="
# ---------------------------------------------------------------------------
declare -A _MOCK_STATES; _MOCK_STATES[42]="MERGED"
check_deps_resolved 99
assert_eq "one MERGED dep → resolved (rc=0) — was rc=1 before #61 fix" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: single OPEN dep blocks ==="
# ---------------------------------------------------------------------------
declare -A _MOCK_STATES; _MOCK_STATES[42]="OPEN"
check_deps_resolved 99
assert_eq "one OPEN dep → blocked (rc=1)" "1" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: multiple deps mixed states ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Dependencies
- #1 something
- #2 something
- #3 something
"
declare -A _MOCK_STATES
_MOCK_STATES[1]="CLOSED"
_MOCK_STATES[2]="MERGED"
_MOCK_STATES[3]="CLOSED"
check_deps_resolved 99
assert_eq "all CLOSED+MERGED → resolved (rc=0) [#73 grep portability + #61 MERGED]" "0" "$?"

declare -A _MOCK_STATES
_MOCK_STATES[1]="CLOSED"
_MOCK_STATES[2]="MERGED"
_MOCK_STATES[3]="OPEN"
check_deps_resolved 99
assert_eq "any one OPEN among three → blocked (rc=1)" "1" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: dep numbers extracted with portable regex (#73) ==="
# ---------------------------------------------------------------------------
# Regression guard: the new portable extraction (grep -oE '#[0-9]+' | sed)
# must extract the same dep numbers as the old GNU-only `grep -oP '#\K[0-9]+'`.
# Specifically: the # itself must be stripped from the output (the for-loop
# expects bare numbers).

_MOCK_BODY="## Dependencies
- depends on #100 and #200
- and also #300
"
declare -A _MOCK_STATES
_MOCK_STATES[100]="CLOSED"
_MOCK_STATES[200]="CLOSED"
_MOCK_STATES[300]="CLOSED"
# If # is not stripped, the gh state lookup gets called with "#100" not "100"
# and our mock returns the default "OPEN" — which would BLOCK. So a passing
# test here proves the # is correctly stripped.
check_deps_resolved 99
assert_eq "portable extraction strips '#' prefix from dep numbers (#73)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
