#!/bin/bash
# test-pr-issue-linkage-277.sh — Regression for issue #277 / INV-86.
#
# PR↔issue resolution must bind an issue to the PR that *closes* it (GitHub's
# parsed `closingIssuesReferences`), NOT to any open PR whose body merely
# mentions `#N`. A cross-referencing sibling PR (good-practice "related to #A")
# must never be selected, reviewed, or mutated under the wrong issue.
#
# Reproduced in this repo: the issue-273 review wrapper resolved PR #276 (the
# #274 fix) because #276's body contained `- #273 — …`. `closingIssuesReferences`
# returns 274 for #276, proving the close linkage is authoritative.
#
# Three-pronged (the wrapper is too heavy to run end-to-end here):
#   1. executable harness for resolve_pr_for_issue / fetch_pr_for_issue /
#      verify_pr_closes_issue (sourced from lib-dispatch.sh, jq-fixture gh stub);
#   2. source-of-truth greps against autonomous-review.sh: Method 1 uses the
#      authoritative resolver, the loose `.[0]` body-mention Methods are gone,
#      and the mutation sites are gated behind a verified-linkage predicate;
#   3. doc-presence greps (INV-86 exists + is referenced from review-agent-flow).
#
# Test cases mirror docs/test-cases/issue-277-pr-linkage.md.
#
# Run: bash tests/unit/test-pr-issue-linkage-277.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
LINKAGE_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-pr-linkage.sh"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"
FLOW="$PROJECT_ROOT/docs/pipeline/review-agent-flow.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# lib-dispatch.sh enforces these via : "${VAR:?...}"
export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-proj
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# Mock `gh pr list --repo R --state open --json F -q EXPR` by piping the fixture
# JSON through jq with the captured -q expression. The resolver issues exactly
# one `gh pr list` call (single superset fetch); the fixture is the full PR set.
# Stderr is preserved so a jq abort (e.g. null-body) is visible during runs.
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

# lib-dispatch.sh sets -euo pipefail; turn off -e so a jq abort doesn't kill the
# runner before assertions execute.
set +e

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected='$expected'"
    echo "      actual=  '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_rc() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected rc=$expected, got rc=$actual)"; FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"; FAIL=$((FAIL + 1))
  fi
}

assert_not_grep() {
  local desc="$1" pattern="$2" file="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (matched: $pattern)"; FAIL=$((FAIL + 1))
  fi
}

extract_number() {
  local out="$1"
  [[ -z "$out" ]] && { echo ""; return; }
  jq -r '.number // empty' <<<"$out" 2>/dev/null
}

# The canonical cross-wiring fixture: PR-A (10) closes issue A (273); PR-B (11)
# closes issue B (274) AND its body mentions #273 (the good-practice cross-ref
# that triggered the bug). PR-B (the mentioning sibling) is deliberately FIRST in
# the array so a buggy `.[0]` body-mention selector picks the WRONG PR (PR-B) for
# issue 273 — the close-linkage resolver must still bind PR-A. This makes both
# TC-XWIRE-001 (resolve) and TC-XWIRE-003 (fetch) genuine fail-before-fix
# regressions, not pass-by-luck-of-ordering.
FIX_CLOSES='[
  {"number":11,"headRefName":"fix/issue-274-noprog","closingIssuesReferences":[{"number":274}],"body":"Fixes #274\n- #273 — authoring-time prevention"},
  {"number":10,"headRefName":"feat/issue-273-ac","closingIssuesReferences":[{"number":273}],"body":"Closes #273"}
]'

# ---------------------------------------------------------------------------
echo "=== resolve_pr_for_issue: authoritative close linkage (INV-86) ==="
# ---------------------------------------------------------------------------

# TC-XWIRE-001: issue 273 must resolve to PR-A (closes 273), NOT PR-B (body
# mentions #273). FAILS before the fix (loose body match picks a mentioning PR).
_MOCK_PR_LIST_JSON="$FIX_CLOSES"
out=$(resolve_pr_for_issue 273 "number,closingIssuesReferences,headRefName,body" 2>/dev/null)
assert_eq "TC-XWIRE-001 issue 273 → PR-A (close-linked), not PR-B (mentions #273)" "10" "$(extract_number "$out")"

# Symmetric: issue 274 → PR-B.
_MOCK_PR_LIST_JSON="$FIX_CLOSES"
out=$(resolve_pr_for_issue 274 "number,closingIssuesReferences,headRefName,body" 2>/dev/null)
assert_eq "TC-XWIRE-001b issue 274 → PR-B (close-linked)" "11" "$(extract_number "$out")"

# TC-XWIRE-003: fetch_pr_for_issue (shared helper, the dispatcher side) exhibits
# the same correct binding — both sites fixed.
_MOCK_PR_LIST_JSON="$FIX_CLOSES"
out=$(fetch_pr_for_issue 273 "number,body" 2>/dev/null)
assert_eq "TC-XWIRE-003 fetch_pr_for_issue 273 → PR-A (both sites bind by close linkage)" "10" "$(extract_number "$out")"

# TC-XWIRE-005: a null-body PR in the candidate set does not crash discovery and
# does not hide the close-linked PR (parity with the #148 guard), across BOTH
# resolve_pr_for_issue and fetch_pr_for_issue.
NULL_BODY_FIX='[
  {"number":9,"headRefName":"chore/unrelated","closingIssuesReferences":[],"body":null},
  {"number":10,"headRefName":"feat/issue-273-ac","closingIssuesReferences":[{"number":273}],"body":"Closes #273"}
]'
_MOCK_PR_LIST_JSON="$NULL_BODY_FIX"
out=$(resolve_pr_for_issue 273 "number,body" 2>/dev/null)
assert_eq "TC-XWIRE-005a resolve: null-body sibling does not hide close-linked PR" "10" "$(extract_number "$out")"
_MOCK_PR_LIST_JSON="$NULL_BODY_FIX"
out=$(fetch_pr_for_issue 273 "number,body" 2>/dev/null)
assert_eq "TC-XWIRE-005b fetch: null-body sibling does not hide close-linked PR" "10" "$(extract_number "$out")"

# ---------------------------------------------------------------------------
echo "=== branch-name fallback (close-keyword-less PRs) ==="
# ---------------------------------------------------------------------------

# TC-XWIRE-004: NO PR has close linkage (partial-fix PRs deliberately omit
# Closes #N). PR-B (number 11, lower-than... actually higher) body mentions #273.
# Branch-name match must resolve PR-A by its `issue-273` branch — bare .[0] body
# mention must never decide. PR order is reversed (mentioning PR first) so a
# `.[0]` regression would wrongly pick PR-B.
NOCLOSE_FIX='[
  {"number":11,"headRefName":"fix/issue-274-noprog","closingIssuesReferences":[],"body":"partial fix\n- #273 — related"},
  {"number":10,"headRefName":"feat/issue-273-ac","closingIssuesReferences":[],"body":"partial fix for 273"}
]'
_MOCK_PR_LIST_JSON="$NOCLOSE_FIX"
out=$(resolve_pr_for_issue 273 "number,headRefName" 2>/dev/null)
assert_eq "TC-XWIRE-004 branch-name fallback → PR-A (issue-273 branch), never .[0] body mention" "10" "$(extract_number "$out")"

# TC-XWIRE-004b: tie — two open PRs both on an issue-273 branch, no close
# linkage → deterministic lowest PR number.
TIE_FIX='[
  {"number":22,"headRefName":"fix/issue-273-take2","closingIssuesReferences":[],"body":"x"},
  {"number":18,"headRefName":"feat/issue-273-ac","closingIssuesReferences":[],"body":"y"}
]'
_MOCK_PR_LIST_JSON="$TIE_FIX"
out=$(resolve_pr_for_issue 273 "number" 2>/dev/null)
assert_eq "TC-XWIRE-004b branch-name tie → lowest PR number (deterministic)" "18" "$(extract_number "$out")"

# TC-XWIRE-010: close linkage takes PRECEDENCE over branch name when both exist
# but point at different PRs.
PRECEDENCE_FIX='[
  {"number":30,"headRefName":"feat/issue-273-branchonly","closingIssuesReferences":[],"body":"branch matches"},
  {"number":31,"headRefName":"misc/unrelated","closingIssuesReferences":[{"number":273}],"body":"Closes #273"}
]'
_MOCK_PR_LIST_JSON="$PRECEDENCE_FIX"
out=$(resolve_pr_for_issue 273 "number" 2>/dev/null)
assert_eq "TC-XWIRE-010 close linkage beats branch-name match" "31" "$(extract_number "$out")"

# ---------------------------------------------------------------------------
echo "=== boundary + empty + happy-path ==="
# ---------------------------------------------------------------------------

# TC-XWIRE-006: single PR, legitimate close linkage → resolves (flow unaffected).
_MOCK_PR_LIST_JSON='[{"number":42,"headRefName":"fix/issue-7-x","closingIssuesReferences":[{"number":7}],"body":"Closes #7"}]'
out=$(resolve_pr_for_issue 7 "number" 2>/dev/null)
assert_eq "TC-XWIRE-006 single close-linked PR resolves" "42" "$(extract_number "$out")"

# TC-XWIRE-007: no PR closes the issue and no branch matches → empty.
_MOCK_PR_LIST_JSON='[{"number":50,"headRefName":"chore/x","closingIssuesReferences":[{"number":999}],"body":"Closes #999"}]'
out=$(resolve_pr_for_issue 7 "number" 2>/dev/null)
assert_eq "TC-XWIRE-007 no close linkage + no branch match → empty" "" "$out"

# TC-XWIRE-008: boundary — issue 27 must NOT bind a PR that closes #270 and whose
# body/branch reference 270 (substring of 27 must not match).
_MOCK_PR_LIST_JSON='[{"number":60,"headRefName":"fix/issue-270-x","closingIssuesReferences":[{"number":270}],"body":"Closes #270 mentions #27 in passing"}]'
out=$(resolve_pr_for_issue 27 "number" 2>/dev/null)
assert_eq "TC-XWIRE-008 issue 27 must not bind a #270 PR (boundary)" "" "$out"

# TC-XWIRE-009: fetch_pr_for_issue field-subset contract — the echoed object
# carries the caller's requested fields (INV-85 depends on `body`).
_MOCK_PR_LIST_JSON='[{"number":10,"headRefName":"feat/issue-273-ac","closingIssuesReferences":[{"number":273}],"body":"Closes #273","headRefOid":"abc123"}]'
out=$(fetch_pr_for_issue 273 "number,headRefOid,body" 2>/dev/null)
has_body=$(jq -r 'has("body")' <<<"$out" 2>/dev/null)
has_head=$(jq -r 'has("headRefOid")' <<<"$out" 2>/dev/null)
assert_eq "TC-XWIRE-009a echoed object carries .body (INV-85 field)" "true" "$has_body"
assert_eq "TC-XWIRE-009b echoed object carries .headRefOid" "true" "$has_head"

# ---------------------------------------------------------------------------
echo "=== verify_pr_closes_issue linkage guard (INV-86) ==="
# ---------------------------------------------------------------------------

# TC-XWIRE-002: the guard returns success when the PR closes the issue, and
# non-zero when it does not (and no branch match) — the wrapper uses this to
# refuse review/mutation of a foreign PR.
_MOCK_PR_LIST_JSON='[{"number":11,"headRefName":"fix/issue-274-noprog","closingIssuesReferences":[{"number":274}],"body":"Fixes #274\n- #273 related"}]'
verify_pr_closes_issue 11 273 2>/dev/null
assert_rc "TC-XWIRE-002a guard rejects foreign PR (closes 274, asked about 273)" "1" "$?"
verify_pr_closes_issue 11 274 2>/dev/null
assert_rc "TC-XWIRE-002b guard accepts the close-linked PR (closes 274)" "0" "$?"
# Branch-name acceptance when close linkage is absent.
_MOCK_PR_LIST_JSON='[{"number":12,"headRefName":"fix/issue-273-partial","closingIssuesReferences":[],"body":"partial"}]'
verify_pr_closes_issue 12 273 2>/dev/null
assert_rc "TC-XWIRE-002c guard accepts branch-name-matched PR (issue-273 branch)" "0" "$?"

# ---------------------------------------------------------------------------
echo "=== source-of-truth: autonomous-review.sh wiring ==="
# ---------------------------------------------------------------------------

# Method 1 must use the authoritative resolver, not a loose body-mention .[0].
assert_grep "review wrapper calls resolve_pr_for_issue for discovery" \
  "resolve_pr_for_issue \"\\\$ISSUE_NUMBER\"" "$WRAPPER"
# The loose body-mention .[0] selector must be GONE from the wrapper.
assert_not_grep "review wrapper no longer uses loose #N body .[0] selector" \
  'select\(\.body \| test\("#\$\{ISSUE_NUMBER\}' "$WRAPPER"
# Methods 2 & 3 loose fallbacks must be gone.
assert_not_grep "review wrapper no longer uses gh search 'issue N' fallback" \
  '\-\-search "issue \$\{ISSUE_NUMBER\}"' "$WRAPPER"
# A linkage guard must gate the PR before downstream use.
assert_grep "review wrapper asserts verify_pr_closes_issue before proceeding" \
  "verify_pr_closes_issue" "$WRAPPER"

# ---------------------------------------------------------------------------
echo "=== source-of-truth: lib-pr-linkage.sh + lib-dispatch.sh ==="
# ---------------------------------------------------------------------------
assert_grep "resolve_pr_for_issue is defined (lib-pr-linkage.sh)" "^resolve_pr_for_issue\(\)" "$LINKAGE_LIB"
assert_grep "verify_pr_closes_issue is defined (lib-pr-linkage.sh)" "^verify_pr_closes_issue\(\)" "$LINKAGE_LIB"
assert_grep "resolver queries closingIssuesReferences" "closingIssuesReferences" "$LINKAGE_LIB"
# The guard-map anchor (pr-exists-for-issue / no-pr-for-issue → fetch_pr_for_issue)
# MUST still resolve in lib-dispatch.sh, and it must delegate to the resolver.
assert_grep "fetch_pr_for_issue still defined in lib-dispatch.sh (guard-map anchor)" "^fetch_pr_for_issue\(\)" "$LIB"
assert_grep "fetch_pr_for_issue delegates to resolve_pr_for_issue" "resolve_pr_for_issue \"\\\$issue_num\"" "$LIB"
assert_grep "lib-dispatch.sh sources lib-pr-linkage.sh" "lib-pr-linkage.sh" "$LIB"

# ---------------------------------------------------------------------------
echo "=== docs: INV-86 present + referenced ==="
# ---------------------------------------------------------------------------
assert_grep "INV-86 heading exists in invariants.md" "^## INV-86" "$INVARIANTS"
assert_grep "INV-86 names closingIssuesReferences" "closingIssuesReferences" "$INVARIANTS"
assert_grep "review-agent-flow.md references INV-86" "INV-86" "$FLOW"

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
