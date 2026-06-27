#!/bin/bash
# test-fetch-pr-for-issue-null-body.sh — Regression for issue #148 (under the
# #277 / INV-86 contract).
#
# `fetch_pr_for_issue` (now delegating to lib-pr-linkage.sh::resolve_pr_for_issue)
# filters every open PR through a jq `test()`/`// ""` chain. When ANY open PR has
# `body: null`, an unguarded `.body | test(...)` would abort the jq filter and
# silently return empty even when a genuinely-linked PR exists. This test mocks
# `gh pr list` output (jq-fixture style) to assert the helper still returns the
# linked PR when a null-body sibling exists.
#
# [INV-86, #277] The BINDING signal changed from a loose `#N` body mention to
# GitHub's parsed close linkage (`closingIssuesReferences`); the fixtures here
# carry that field. The #148 null-body resilience invariant is unchanged.
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
echo "=== fetch_pr_for_issue null-body resilience (issue #148, #277/INV-86) ==="
# ---------------------------------------------------------------------------
# [INV-86, #277] CONTRACT CHANGE: fetch_pr_for_issue now binds by GitHub's parsed
# close linkage (`closingIssuesReferences`), NOT by a `#N` body mention (which
# bound an issue to a cross-referencing sibling PR). The #148 invariant under
# test here is unchanged: a `.body == null` sibling must not abort the jq filter
# and silently hide the genuinely-linked PR. The fixtures are updated to carry
# `closingIssuesReferences` (the new binding signal) while keeping the null-body
# sibling that exercises the #148 resilience.

# TC-FETCH-PR-001: regression — null-body PR + close-linked PR. The null body
# must not abort the jq filter (#148) and hide the close-linked PR.
_MOCK_PR_LIST_JSON='[{"number":1,"body":null,"closingIssuesReferences":[],"headRefName":"x"},{"number":2,"body":"Closes #145 in this PR","closingIssuesReferences":[{"number":145}],"headRefName":"fix/issue-145"}]'
out=$(fetch_pr_for_issue 145 "number,body" 2>/dev/null)
assert_eq "TC-FETCH-PR-001 null-body sibling does not hide the close-linked PR" "2" "$(extract_number "$out")"

# TC-FETCH-PR-002: only PR has null body, no close linkage / branch — empty.
_MOCK_PR_LIST_JSON='[{"number":1,"body":null,"closingIssuesReferences":[],"headRefName":"x"}]'
out=$(fetch_pr_for_issue 145 "number,body" 2>/dev/null)
assert_eq "TC-FETCH-PR-002 null-body only, no link → empty" "" "$out"

# TC-FETCH-PR-003: baseline — all bodies non-null, one close-linked.
_MOCK_PR_LIST_JSON='[{"number":1,"body":"unrelated","closingIssuesReferences":[],"headRefName":"x"},{"number":2,"body":"Fixes #145","closingIssuesReferences":[{"number":145}],"headRefName":"fix/issue-145"}]'
out=$(fetch_pr_for_issue 145 "number,body" 2>/dev/null)
assert_eq "TC-FETCH-PR-003 all bodies non-null, one close-linked" "2" "$(extract_number "$out")"

# TC-FETCH-PR-004: all bodies non-null, none link.
_MOCK_PR_LIST_JSON='[{"number":1,"body":"unrelated","closingIssuesReferences":[],"headRefName":"x"}]'
out=$(fetch_pr_for_issue 145 "number,body" 2>/dev/null)
assert_eq "TC-FETCH-PR-004 all bodies non-null, none link → empty" "" "$out"

# TC-FETCH-PR-005: close-linked match alongside a null-body sibling.
_MOCK_PR_LIST_JSON='[{"number":1,"body":null,"closingIssuesReferences":[],"headRefName":"x"},{"number":2,"body":"closes #145","closingIssuesReferences":[{"number":145}],"headRefName":"fix/issue-145"}]'
out=$(fetch_pr_for_issue 145 "number,body" 2>/dev/null)
assert_eq "TC-FETCH-PR-005 close-linked match, null sibling" "2" "$(extract_number "$out")"

# TC-FETCH-PR-006: substring guard — a PR that closes #1450 (and merely mentions
# #145) must NOT bind issue 145. Boundary protected by close linkage itself.
_MOCK_PR_LIST_JSON='[{"number":1,"body":null,"closingIssuesReferences":[],"headRefName":"x"},{"number":2,"body":"see #1450 / #145 for context","closingIssuesReferences":[{"number":1450}],"headRefName":"fix/issue-1450"}]'
out=$(fetch_pr_for_issue 145 "number,body" 2>/dev/null)
assert_eq "TC-FETCH-PR-006 #1450 close-linked PR must not bind #145 (boundary)" "" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
