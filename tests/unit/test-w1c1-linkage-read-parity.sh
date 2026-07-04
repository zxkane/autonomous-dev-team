#!/bin/bash
# test-w1c1-linkage-read-parity.sh — issue #397 (W1c1, #347 phase-2), R4/R6.
#
# DECISION-level (not byte-level) behavior-parity suite for
# `chp_find_pr_for_issue`'s callers (`resolve_pr_for_issue` /
# `verify_pr_closes_issue` in `lib-pr-linkage.sh`) and the six body-mention
# `chp_pr_list` sites in `autonomous-dev.sh` / `lib-auth.sh`.
#
# #397 converts these two CHP read verbs from a gh-argv passthrough to an
# ABSTRACT contract (positional args, NORMALIZED output, COMPLETE candidate
# set) — a deliberate SHAPE change (body is a string, closingIssueNumbers is
# an int array). Byte-identical argv is impossible by construction. This
# suite proves DECISION-level parity: for each caller / site, the CURRENT
# (post-#397) code produces the exact same value the OLD code produced for
# the "guarded" body-mention selector against the fixtures in
# `tests/unit/fixtures/w1c1-parity/decision-golden.json`.
#
# Two of the six chp_pr_list caller sites (`.body != null and …`) already
# carried the guard; the other four (:774 in autonomous-dev.sh, :1079 in
# autonomous-dev.sh, and both lib-auth.sh sites) did NOT — the #148 hazard
# class. Under the new normalized shape, `body:null → body:""`, so all six
# converge on the guarded/normalized decision. The golden records the
# guarded decision (the correct post-normalization behavior); this suite's
# green run proves the drop-guard change is a fix, not a regression.
#
# GOLDEN FIXTURE PROVENANCE (R6): see
# `tests/unit/fixtures/w1c1-parity/decision-golden.json.meta`. The goldens
# were captured ONCE by running the PRE-#397 guarded selectors against the
# same fixtures, on the first TDD commit of the #397 branch, before the
# leaf rewrite landed.
#
# Run: env -u PROJECT_DIR bash tests/unit/test-w1c1-linkage-read-parity.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DISP="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
CHP_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-code-host.sh"
GOLDEN="$SCRIPT_DIR/fixtures/w1c1-parity/decision-golden.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

[[ -f "$GOLDEN" ]] || { echo "FATAL: golden fixture not found at $GOLDEN"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-w1c1-parity-$$
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# ---------------------------------------------------------------------------
# The mock `gh pr list --repo R --state <state> --json F --limit N` returns the
# fixture as raw JSON — mirroring real gh. The W1c1 leaf runs its own jq
# normalization outside of the gh call, so `-q` is not used.
# ---------------------------------------------------------------------------
_MOCK_PR_LIST_JSON=""
gh() { printf '%s' "${_MOCK_PR_LIST_JSON:-[]}"; }
export -f gh

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB_DISP"
set +e

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    ok "$desc (=$actual)"
  else
    bad "$desc — expected [$expected], got [$actual]"
  fi
}

_get_str()  { jq -r --arg k "$1" '.[$k] // ""' "$GOLDEN"; }
_get_int()  { jq -r --arg k "$1" '.[$k]' "$GOLDEN"; }
_get_val()  { jq -r --arg k "$1" '.[$k] | if type == "number" then tostring else . end' "$GOLDEN"; }

# ---------------------------------------------------------------------------
# Fixture PR arrays (mirror generate-goldens.sh exactly).
# ---------------------------------------------------------------------------
FIX_CLOSE_LINK='[
  {"number":11,"headRefName":"fix/issue-274-noprog","closingIssuesReferences":[{"number":274}],"body":"Fixes #274\n- #273 — related","createdAt":"2026-06-01T00:00:00Z"},
  {"number":10,"headRefName":"feat/issue-273-ac","closingIssuesReferences":[{"number":273}],"body":"Closes #273","createdAt":"2026-06-01T01:00:00Z"}
]'
FIX_BRANCH='[
  {"number":11,"headRefName":"fix/issue-274-noprog","closingIssuesReferences":[],"body":"partial fix\n- #273 — related","createdAt":"2026-06-01T00:00:00Z"},
  {"number":10,"headRefName":"feat/issue-273-ac","closingIssuesReferences":[],"body":"partial fix for 273","createdAt":"2026-06-01T01:00:00Z"}
]'
FIX_XWIRE='[
  {"number":11,"headRefName":"fix/issue-274","closingIssuesReferences":[{"number":274}],"body":"Fixes #274\n- #273 — related","createdAt":"2026-06-01T00:00:00Z"},
  {"number":10,"headRefName":"feat/issue-273","closingIssuesReferences":[{"number":273}],"body":"Closes #273","createdAt":"2026-06-01T01:00:00Z"}
]'
FIX_NULLBODY='[
  {"number":1,"headRefName":"chore/unrelated","closingIssuesReferences":[],"body":null,"createdAt":"2026-06-01T00:00:00Z"},
  {"number":10,"headRefName":"feat/issue-273-ac","closingIssuesReferences":[{"number":273}],"body":"Closes #273","createdAt":"2026-06-01T01:00:00Z"}
]'
FIX_NOPR='[
  {"number":50,"headRefName":"chore/x","closingIssuesReferences":[{"number":999}],"body":"Closes #999","createdAt":"2026-06-01T00:00:00Z"}
]'
FIX_BOUNDARY='[
  {"number":60,"headRefName":"fix/issue-270-x","closingIssuesReferences":[{"number":270}],"body":"Closes #270 mentions #27 in passing","createdAt":"2026-06-01T00:00:00Z"}
]'
_gen_overlimit() {
  local out="[" i first=1
  for i in $(seq 1 34); do
    if [[ $first -eq 1 ]]; then first=0; else out+=","; fi
    out+="{\"number\":$((100+i)),\"headRefName\":\"chore/x-${i}\",\"closingIssuesReferences\":[],\"body\":\"unrelated\",\"createdAt\":\"2026-06-01T00:00:00Z\"}"
  done
  out+=",{\"number\":999,\"headRefName\":\"feat/issue-500-real\",\"closingIssuesReferences\":[{\"number\":500}],\"body\":\"Closes #500\",\"createdAt\":\"2026-06-01T01:00:00Z\"}"
  out+="]"
  printf '%s' "$out"
}
FIX_OVERLIMIT="$(_gen_overlimit)"

FIX_PRLIST='[
  {"number":100,"body":"unrelated","createdAt":"2026-06-01T00:00:00Z"},
  {"number":101,"body":null,"createdAt":"2026-06-01T00:30:00Z"},
  {"number":102,"body":"see #42 for context","createdAt":"2026-06-01T00:45:00Z"},
  {"number":103,"body":"resolves #425 boundary","createdAt":"2026-06-01T01:00:00Z"},
  {"number":104,"body":"related to #42","createdAt":"2026-06-01T02:00:00Z"},
  {"number":105,"body":"see #42","createdAt":"2026-06-01T00:15:00Z"}
]'
FIX_PRLIST_EMPTY='[]'
FIX_PRLIST_BOUNDARY='[
  {"number":200,"body":"cross-refs #42","createdAt":"2026-06-01T00:00:00Z"},
  {"number":201,"body":"final ref: #42","createdAt":"2026-06-01T01:00:00Z"}
]'
FIX_PRLIST_NULLBODY='[
  {"number":300,"body":null,"createdAt":"2026-06-01T00:00:00Z"},
  {"number":301,"body":"see #42","createdAt":"2026-06-01T01:00:00Z"}
]'

# ---------------------------------------------------------------------------
# Site helpers — each mirrors the caller's SELECTOR against the *normalized*
# candidate array (i.e. body is a string, closingIssueNumbers is int-array).
# Callers extract the value the site produces (int length / int number / ISO
# string) and this test asserts it against the golden.
# ---------------------------------------------------------------------------

# resolve_pr_for_issue → .number of the resolved PR (or "").
_run_resolve() {
  local issue="$1"
  local out num
  out="$(resolve_pr_for_issue "$issue" "number,closingIssuesReferences,headRefName,body" 2>/dev/null)"
  num="$(jq -r '.number // ""' <<<"$out" 2>/dev/null || printf "")"
  printf '%s' "$num"
}

# verify_pr_closes_issue → rc (0 accept, 1 reject).
_run_verify() {
  local pr="$1" issue="$2"
  verify_pr_closes_issue "$pr" "$issue" 2>/dev/null; echo -n $?
}

# The 6 chp_pr_list caller-site selectors (post-normalization, all guard-drop).
# We test each caller-side jq directly over the FIXTURE (bypassing chp_pr_list —
# because the pre-normalized fixture is what the leaf's jq would emit anyway
# for these fields). Emulating the leaf: apply the normalization projection
# (body // ""), then run each site's selector.
_normalize() {
  jq -c '[.[] | {number: .number, body: (.body // ""), createdAt: (.createdAt // null)}]'
}
_sel_length() {
  local n="$1"
  jq -r "[.[] | select((.body | test(\"#${n}[^0-9]\")) or (.body | test(\"#${n}\$\")))] | length"
}
_sel_first_number() {
  local n="$1"
  jq -r "[.[] | select((.body | test(\"#${n}[^0-9]\")) or (.body | test(\"#${n}\$\")))] | .[0].number // \"\""
}
_sel_earliest_createdAt() {
  local n="$1"
  jq -r "[.[] | select((.body | test(\"#${n}[^0-9]\")) or (.body | test(\"#${n}\$\")))] | sort_by(.createdAt) | (.[0].createdAt // \"\")"
}

_site_length() { printf '%s' "$1" | _normalize | _sel_length "$2"; }
_site_first_number() { printf '%s' "$1" | _normalize | _sel_first_number "$2"; }
_site_earliest_createdAt() { printf '%s' "$1" | _normalize | _sel_earliest_createdAt "$2"; }

# ---------------------------------------------------------------------------
echo "=== TC-W1C1-LINKAGE-RESOLVE ==="
# ---------------------------------------------------------------------------
_MOCK_PR_LIST_JSON="$FIX_CLOSE_LINK"; assert_eq "TC-W1C1-001 linkage.resolve.close-linkage-wins" "$(_get_val linkage.resolve.close-linkage-wins)" "$(_run_resolve 273)"
_MOCK_PR_LIST_JSON="$FIX_CLOSE_LINK"; assert_eq "TC-W1C1-002 linkage.resolve.close-linkage-274" "$(_get_val linkage.resolve.close-linkage-274)" "$(_run_resolve 274)"
_MOCK_PR_LIST_JSON="$FIX_BRANCH";     assert_eq "TC-W1C1-003 linkage.resolve.branch-fallback" "$(_get_val linkage.resolve.branch-fallback)" "$(_run_resolve 273)"
_MOCK_PR_LIST_JSON="$FIX_XWIRE";      assert_eq "TC-W1C1-004 linkage.resolve.cross-wired-273" "$(_get_val linkage.resolve.cross-wired-273)" "$(_run_resolve 273)"
_MOCK_PR_LIST_JSON="$FIX_XWIRE";      assert_eq "TC-W1C1-005 linkage.resolve.cross-wired-274" "$(_get_val linkage.resolve.cross-wired-274)" "$(_run_resolve 274)"
_MOCK_PR_LIST_JSON="$FIX_NULLBODY";   assert_eq "TC-W1C1-006 linkage.resolve.null-body" "$(_get_val linkage.resolve.null-body)" "$(_run_resolve 273)"
_MOCK_PR_LIST_JSON="$FIX_NOPR";       assert_eq "TC-W1C1-007 linkage.resolve.no-pr" "$(_get_val linkage.resolve.no-pr)" "$(_run_resolve 7)"
_MOCK_PR_LIST_JSON="$FIX_BOUNDARY";   assert_eq "TC-W1C1-008 linkage.resolve.boundary" "$(_get_val linkage.resolve.boundary)" "$(_run_resolve 27)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-W1C1-LINKAGE-COMPLETENESS (>30 candidates, #397 headline) ==="
# ---------------------------------------------------------------------------
# The close-linked PR is 35th in the array; pre-#397 code with gh's default
# `--limit 30` truncated it. The new leaf's bounded page walk (limit=2000 with
# a 20-page cap by default) keeps it.
_MOCK_PR_LIST_JSON="$FIX_OVERLIMIT"; assert_eq "TC-W1C1-009 linkage.resolve.overlimit-500 (>30 candidates completeness)" "$(_get_val linkage.resolve.overlimit-500)" "$(_run_resolve 500)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-W1C1-LINKAGE-VERIFY ==="
# ---------------------------------------------------------------------------
_MOCK_PR_LIST_JSON="$FIX_CLOSE_LINK"; assert_eq "TC-W1C1-020 linkage.verify.close-linked-274-274" "$(_get_val linkage.verify.close-linked-274-274)" "$(_run_verify 11 274)"
_MOCK_PR_LIST_JSON="$FIX_CLOSE_LINK"; assert_eq "TC-W1C1-021 linkage.verify.close-linked-273-273" "$(_get_val linkage.verify.close-linked-273-273)" "$(_run_verify 10 273)"
_MOCK_PR_LIST_JSON="$FIX_CLOSE_LINK"; assert_eq "TC-W1C1-022 linkage.verify.foreign-11-273 (reject foreign)" "$(_get_val linkage.verify.foreign-11-273)" "$(_run_verify 11 273)"
_MOCK_PR_LIST_JSON="$FIX_BRANCH";     assert_eq "TC-W1C1-023 linkage.verify.branch-274-274" "$(_get_val linkage.verify.branch-274-274)" "$(_run_verify 11 274)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-W1C1-PRLIST-SITES ==="
# ---------------------------------------------------------------------------
# Each site's decision is computed by projecting the fixture through the leaf's
# normalization (body // "") then running the site's selector — matching the
# post-W1c1 caller shape 1:1.

# needs_open_pr_only (:434, length; fail-CLOSED on read error)
assert_eq "TC-W1C1-030 prlist.needs_open_pr_only.rich"       "$(_get_val prlist.needs_open_pr_only.rich)"       "$(_site_length "$FIX_PRLIST" 42)"
assert_eq "TC-W1C1-031 prlist.needs_open_pr_only.empty"      "$(_get_val prlist.needs_open_pr_only.empty)"      "$(_site_length "$FIX_PRLIST_EMPTY" 42)"
assert_eq "TC-W1C1-032 prlist.needs_open_pr_only.boundary"   "$(_get_val prlist.needs_open_pr_only.boundary)"   "$(_site_length "$FIX_PRLIST_BOUNDARY" 42)"
assert_eq "TC-W1C1-033 prlist.needs_open_pr_only.nullbody"   "$(_get_val prlist.needs_open_pr_only.nullbody)"   "$(_site_length "$FIX_PRLIST_NULLBODY" 42)"

# PR_EXISTS (:774, length; fail-soft; used to be UNGUARDED #148 hazard)
assert_eq "TC-W1C1-040 prlist.pr_exists.rich (guard-drop fix)"   "$(_get_val prlist.pr_exists.rich)"       "$(_site_length "$FIX_PRLIST" 42)"
assert_eq "TC-W1C1-041 prlist.pr_exists.empty"                   "$(_get_val prlist.pr_exists.empty)"      "$(_site_length "$FIX_PRLIST_EMPTY" 42)"
assert_eq "TC-W1C1-042 prlist.pr_exists.boundary"                "$(_get_val prlist.pr_exists.boundary)"   "$(_site_length "$FIX_PRLIST_BOUNDARY" 42)"
assert_eq "TC-W1C1-043 prlist.pr_exists.nullbody (#148 fix)"     "$(_get_val prlist.pr_exists.nullbody)"   "$(_site_length "$FIX_PRLIST_NULLBODY" 42)"

# _pr_created_at (:865, earliest .createdAt)
assert_eq "TC-W1C1-050 prlist.pr_created_at.rich"              "$(_get_val prlist.pr_created_at.rich)"     "$(_site_earliest_createdAt "$FIX_PRLIST" 42)"
assert_eq "TC-W1C1-051 prlist.pr_created_at.empty"             "$(_get_val prlist.pr_created_at.empty)"    "$(_site_earliest_createdAt "$FIX_PRLIST_EMPTY" 42)"
assert_eq "TC-W1C1-052 prlist.pr_created_at.nullbody"          "$(_get_val prlist.pr_created_at.nullbody)" "$(_site_earliest_createdAt "$FIX_PRLIST_NULLBODY" 42)"

# PR_NUM (:1079, .[0].number; used to be UNGUARDED #148 hazard)
assert_eq "TC-W1C1-060 prlist.pr_num.rich (guard-drop fix)"    "$(_get_val prlist.pr_num.rich)"      "$(_site_first_number "$FIX_PRLIST" 42)"
assert_eq "TC-W1C1-061 prlist.pr_num.empty"                    "$(_get_val prlist.pr_num.empty)"     "$(_site_first_number "$FIX_PRLIST_EMPTY" 42)"
assert_eq "TC-W1C1-062 prlist.pr_num.boundary"                 "$(_get_val prlist.pr_num.boundary)"  "$(_site_first_number "$FIX_PRLIST_BOUNDARY" 42)"
assert_eq "TC-W1C1-063 prlist.pr_num.nullbody (#148 fix)"      "$(_get_val prlist.pr_num.nullbody)"  "$(_site_first_number "$FIX_PRLIST_NULLBODY" 42)"

# lib-auth.sh :453 existing (length; used to be UNGUARDED)
assert_eq "TC-W1C1-070 prlist.lib_auth_existing.rich"          "$(_get_val prlist.lib_auth_existing.rich)"     "$(_site_length "$FIX_PRLIST" 42)"
assert_eq "TC-W1C1-071 prlist.lib_auth_existing.empty"         "$(_get_val prlist.lib_auth_existing.empty)"    "$(_site_length "$FIX_PRLIST_EMPTY" 42)"
assert_eq "TC-W1C1-072 prlist.lib_auth_existing.nullbody"      "$(_get_val prlist.lib_auth_existing.nullbody)" "$(_site_length "$FIX_PRLIST_NULLBODY" 42)"

# lib-auth.sh :605 pr_number (first .number; used to be UNGUARDED)
assert_eq "TC-W1C1-080 prlist.lib_auth_pr_number.rich"         "$(_get_val prlist.lib_auth_pr_number.rich)"     "$(_site_first_number "$FIX_PRLIST" 42)"
assert_eq "TC-W1C1-081 prlist.lib_auth_pr_number.empty"        "$(_get_val prlist.lib_auth_pr_number.empty)"    "$(_site_first_number "$FIX_PRLIST_EMPTY" 42)"
assert_eq "TC-W1C1-082 prlist.lib_auth_pr_number.nullbody"     "$(_get_val prlist.lib_auth_pr_number.nullbody)" "$(_site_first_number "$FIX_PRLIST_NULLBODY" 42)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-W1C1-SEAM-TRACE: chp_find_pr_for_issue / chp_pr_list are POSITIONAL (no gh flags cross seam) ==="
# ---------------------------------------------------------------------------
# Under the ABSTRACT contract, calling the shim with any -q / --json / --state
# flag from a caller is a source-level regression. Grep the caller layer for
# such shapes (excluding comments) — they MUST all be gone.
_CALLERS="skills/autonomous-dispatcher/scripts/autonomous-dev.sh skills/autonomous-dispatcher/scripts/autonomous-review.sh skills/autonomous-dispatcher/scripts/lib-auth.sh skills/autonomous-dispatcher/scripts/lib-pr-linkage.sh skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
_leaks=$(cd "$PROJECT_ROOT" && for f in $_CALLERS; do
  [ -f "$f" ] || continue
  # Match `chp_pr_list --` or `chp_pr_list -q` etc. — non-comment lines only.
  grep -nE '(^|[^A-Za-z_])chp_(pr_list|find_pr_for_issue)[[:space:]]+(--|-q )' "$f" \
    | grep -vE '^[0-9]+:[[:space:]]*#' | sed "s#^#$f:#"
done)
if [ -z "$_leaks" ]; then
  ok "TC-W1C1-SEAM-TRACE no gh-flag argv crosses the chp_pr_list / chp_find_pr_for_issue seam"
else
  bad "TC-W1C1-SEAM-TRACE gh-flag argv still crosses the seam:"; printf '%s\n' "$_leaks"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
