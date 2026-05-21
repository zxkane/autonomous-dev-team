#!/bin/bash
# test-fetch-pr-for-issue-null-body.sh — Regression for issue #148.
#
# `fetch_pr_for_issue` in skills/autonomous-dispatcher/scripts/lib-dispatch.sh
# applies `.body | test(...)` to every open PR. When ANY open PR has
# `body: null`, jq aborts the filter and the function silently returns empty
# even when a matching PR exists. This test mocks `gh pr list` output
# (jq-fixture style) to assert the helper still returns the matching PR
# when a null-body sibling exists.
#
# Test cases mirror docs/test-cases/fetch-pr-for-issue-null-body.md.
#
# Run: bash tests/unit/test-fetch-pr-for-issue-null-body.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# lib-dispatch.sh enforces these via : "${VAR:?...}"
export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-proj
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# Mock `gh pr list --repo R --state open --json F -q EXPR` by piping the
# fixture JSON through jq with the captured -q expression. Stderr is
# preserved so the pre-fix jq error ("null (null) cannot be matched") is
# visible during test runs against `main`.
_MOCK_PR_LIST_JSON=""
gh() {
  local q_expr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -q) q_expr="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -n "$q_expr" && -n "$_MOCK_PR_LIST_JSON" ]]; then
    jq -r "$q_expr" <<<"$_MOCK_PR_LIST_JSON"
  fi
}
export -f gh

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"

# lib-dispatch.sh sets -euo pipefail; turn off -e so jq abort doesn't kill
# the test runner before assertions execute.
set +e

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected='$expected'"
    echo "      actual=  '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

# fetch_pr_for_issue echoes a single-line JSON object on a hit (or empty).
# Extract a stable scalar (.number) for comparison.
extract_number() {
  local out="$1"
  if [[ -z "$out" ]]; then
    echo ""
  else
    jq -r '.number // empty' <<<"$out" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
echo "=== fetch_pr_for_issue null-body resilience (issue #148) ==="
# ---------------------------------------------------------------------------

# TC-FETCH-PR-001: regression — null-body PR + matching PR. Pre-fix this
# returns "" because jq aborts on the null body.
_MOCK_PR_LIST_JSON='[{"number":1,"body":null},{"number":2,"body":"Closes #145 in this PR"}]'
out=$(fetch_pr_for_issue 145 "number,body" 2>/dev/null)
assert_eq "TC-FETCH-PR-001 null-body sibling does not hide the matching PR" "2" "$(extract_number "$out")"

# TC-FETCH-PR-002: only PR has null body, no match — must be empty.
_MOCK_PR_LIST_JSON='[{"number":1,"body":null}]'
out=$(fetch_pr_for_issue 145 "number,body" 2>/dev/null)
assert_eq "TC-FETCH-PR-002 null-body only, no match → empty" "" "$out"

# TC-FETCH-PR-003: baseline — all bodies non-null, one matches.
_MOCK_PR_LIST_JSON='[{"number":1,"body":"unrelated"},{"number":2,"body":"Fixes #145"}]'
out=$(fetch_pr_for_issue 145 "number,body" 2>/dev/null)
assert_eq "TC-FETCH-PR-003 all bodies non-null, one matches" "2" "$(extract_number "$out")"

# TC-FETCH-PR-004: all bodies non-null, none match.
_MOCK_PR_LIST_JSON='[{"number":1,"body":"unrelated"}]'
out=$(fetch_pr_for_issue 145 "number,body" 2>/dev/null)
assert_eq "TC-FETCH-PR-004 all bodies non-null, none match → empty" "" "$out"

# TC-FETCH-PR-005: trailing-`#NNN` body match alongside null-body sibling.
_MOCK_PR_LIST_JSON='[{"number":1,"body":null},{"number":2,"body":"closes #145"}]'
out=$(fetch_pr_for_issue 145 "number,body" 2>/dev/null)
assert_eq "TC-FETCH-PR-005 trailing #NNN match, null sibling" "2" "$(extract_number "$out")"

# TC-FETCH-PR-006: substring guard — `#1450` must NOT match issue 145.
_MOCK_PR_LIST_JSON='[{"number":1,"body":null},{"number":2,"body":"see #1450 for context"}]'
out=$(fetch_pr_for_issue 145 "number,body" 2>/dev/null)
assert_eq "TC-FETCH-PR-006 #1450 must not match #145 (boundary)" "" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
