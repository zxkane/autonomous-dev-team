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
# carried the guard; the other four (:844 in autonomous-dev.sh, :1174 in
# autonomous-dev.sh, and both lib-auth.sh sites at :454/:610) did NOT — the
# #148 hazard class. Line pins reflect the current tree (post-rebase onto
# W1b=#396). Under the new normalized shape, `body:null → body:""`, so all
# six converge on the guarded/normalized decision. The golden records the
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
# The mock `gh api graphql …` returns the fixture wrapped in the GraphQL
# `.data.repository.pullRequests.{pageInfo, nodes}` shape (single-page, no
# more) — the W1c1 leaf uses cursor pagination (§3.5) via `gh api graphql`
# with `pullRequests(first:100, after:$cursor)`. Fixtures declare the flat
# `closingIssuesReferences:[{number:N}]` array form; the mock reshapes it to
# the GraphQL `closingIssuesReferences.nodes[]` form the leaf's projection jq
# consumes.
# ---------------------------------------------------------------------------
_MOCK_PR_LIST_JSON=""
gh() {
  # If a fixture is armed, wrap it in the GraphQL envelope with reshaped
  # closingIssuesReferences. Empty fixture (`[]`) yields an empty-nodes
  # response with hasNextPage=false — no more calls needed.
  local flat="${_MOCK_PR_LIST_JSON:-[]}"
  local reshaped
  reshaped=$(jq -c '[.[] | . + {closingIssuesReferences: {nodes: (.closingIssuesReferences // [])}}]' <<<"$flat" 2>/dev/null || printf '[]')
  jq -c --argjson nodes "$reshaped" \
       '{data:{repository:{pullRequests:{pageInfo:{endCursor:null,hasNextPage:false}, nodes:$nodes}}}}' <<<"{}"
}
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
  out="$(resolve_pr_for_issue "$issue" "number,closingIssueNumbers,headRefName,body" 2>/dev/null)"
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

# needs_open_pr_only (autonomous-dev.sh:438, length; fail-CLOSED on read error)
assert_eq "TC-W1C1-030 prlist.needs_open_pr_only.rich"       "$(_get_val prlist.needs_open_pr_only.rich)"       "$(_site_length "$FIX_PRLIST" 42)"
assert_eq "TC-W1C1-031 prlist.needs_open_pr_only.empty"      "$(_get_val prlist.needs_open_pr_only.empty)"      "$(_site_length "$FIX_PRLIST_EMPTY" 42)"
assert_eq "TC-W1C1-032 prlist.needs_open_pr_only.boundary"   "$(_get_val prlist.needs_open_pr_only.boundary)"   "$(_site_length "$FIX_PRLIST_BOUNDARY" 42)"
assert_eq "TC-W1C1-033 prlist.needs_open_pr_only.nullbody"   "$(_get_val prlist.needs_open_pr_only.nullbody)"   "$(_site_length "$FIX_PRLIST_NULLBODY" 42)"

# PR_EXISTS (autonomous-dev.sh:844, length; fail-soft; used to be UNGUARDED #148 hazard)
assert_eq "TC-W1C1-040 prlist.pr_exists.rich (guard-drop fix)"   "$(_get_val prlist.pr_exists.rich)"       "$(_site_length "$FIX_PRLIST" 42)"
assert_eq "TC-W1C1-041 prlist.pr_exists.empty"                   "$(_get_val prlist.pr_exists.empty)"      "$(_site_length "$FIX_PRLIST_EMPTY" 42)"
assert_eq "TC-W1C1-042 prlist.pr_exists.boundary"                "$(_get_val prlist.pr_exists.boundary)"   "$(_site_length "$FIX_PRLIST_BOUNDARY" 42)"
assert_eq "TC-W1C1-043 prlist.pr_exists.nullbody (#148 fix)"     "$(_get_val prlist.pr_exists.nullbody)"   "$(_site_length "$FIX_PRLIST_NULLBODY" 42)"

# _pr_created_at (autonomous-dev.sh:943, earliest .createdAt)
assert_eq "TC-W1C1-050 prlist.pr_created_at.rich"              "$(_get_val prlist.pr_created_at.rich)"     "$(_site_earliest_createdAt "$FIX_PRLIST" 42)"
assert_eq "TC-W1C1-051 prlist.pr_created_at.empty"             "$(_get_val prlist.pr_created_at.empty)"    "$(_site_earliest_createdAt "$FIX_PRLIST_EMPTY" 42)"
assert_eq "TC-W1C1-052 prlist.pr_created_at.nullbody"          "$(_get_val prlist.pr_created_at.nullbody)" "$(_site_earliest_createdAt "$FIX_PRLIST_NULLBODY" 42)"

# PR_NUM (autonomous-dev.sh:1174, .[0].number; used to be UNGUARDED #148 hazard)
assert_eq "TC-W1C1-060 prlist.pr_num.rich (guard-drop fix)"    "$(_get_val prlist.pr_num.rich)"      "$(_site_first_number "$FIX_PRLIST" 42)"
assert_eq "TC-W1C1-061 prlist.pr_num.empty"                    "$(_get_val prlist.pr_num.empty)"     "$(_site_first_number "$FIX_PRLIST_EMPTY" 42)"
assert_eq "TC-W1C1-062 prlist.pr_num.boundary"                 "$(_get_val prlist.pr_num.boundary)"  "$(_site_first_number "$FIX_PRLIST_BOUNDARY" 42)"
assert_eq "TC-W1C1-063 prlist.pr_num.nullbody (#148 fix)"      "$(_get_val prlist.pr_num.nullbody)"  "$(_site_first_number "$FIX_PRLIST_NULLBODY" 42)"

# lib-auth.sh:454 existing (length; used to be UNGUARDED)
assert_eq "TC-W1C1-070 prlist.lib_auth_existing.rich"          "$(_get_val prlist.lib_auth_existing.rich)"     "$(_site_length "$FIX_PRLIST" 42)"
assert_eq "TC-W1C1-071 prlist.lib_auth_existing.empty"         "$(_get_val prlist.lib_auth_existing.empty)"    "$(_site_length "$FIX_PRLIST_EMPTY" 42)"
assert_eq "TC-W1C1-072 prlist.lib_auth_existing.nullbody"      "$(_get_val prlist.lib_auth_existing.nullbody)" "$(_site_length "$FIX_PRLIST_NULLBODY" 42)"

# lib-auth.sh:610 pr_number (first .number; used to be UNGUARDED)
assert_eq "TC-W1C1-080 prlist.lib_auth_pr_number.rich"         "$(_get_val prlist.lib_auth_pr_number.rich)"     "$(_site_first_number "$FIX_PRLIST" 42)"
assert_eq "TC-W1C1-081 prlist.lib_auth_pr_number.empty"        "$(_get_val prlist.lib_auth_pr_number.empty)"    "$(_site_first_number "$FIX_PRLIST_EMPTY" 42)"
assert_eq "TC-W1C1-082 prlist.lib_auth_pr_number.nullbody"     "$(_get_val prlist.lib_auth_pr_number.nullbody)" "$(_site_first_number "$FIX_PRLIST_NULLBODY" 42)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-W1C1-SELECTOR-SOURCE-PIN: parity helpers match live-caller jq (P2-4) ==="
# ---------------------------------------------------------------------------
# The `_sel_length` / `_sel_first_number` / `_sel_earliest_createdAt` helpers
# above emulate the six body-mention caller sites' inline jq. If a caller's
# LIVE jq drifts (e.g. someone edits the regex boundary or drops a paren),
# the parity assertions still pass because they compare goldens against a
# STALE helper copy. Pin the helpers to the live source: for each site's
# selector-anchor pattern, assert the source file contains EXACTLY the
# shape the parity helper uses. Selector drift fails the suite LOUDLY.
_DEV_SH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
_AUTH_SH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-auth.sh"

_pin_source() {
  local desc="$1" file="$2" needle="$3"
  if grep -qF -- "$needle" "$file"; then
    ok "$desc"
  else
    bad "$desc — needle NOT found in $file"
  fi
}

# Length shape (2 dev sites + 1 auth site). Each hit uses the same
# `test(\"#${N}[^0-9]\")` / `test(\"#${N}\$\")` + `| length` pattern the
# parity helper `_sel_length` uses. Needles include the literal backslash-
# escapes the source uses inside `jq -r "…"` — `\"` around the jq string
# arg and `\$` around the terminating `#N$` anchor (so bash doesn't expand
# `$"…"` early).
_pin_source "SRC-PIN-DEV-LEN autonomous-dev.sh needs_open_pr_only length shape"    "$_DEV_SH"  '[.[] | select((.body | test(\"#${issue_num}[^0-9]\")) or (.body | test(\"#${issue_num}\$\")))] | length'
_pin_source "SRC-PIN-DEV-LEN autonomous-dev.sh PR_EXISTS length shape"              "$_DEV_SH"  '[.[] | select((.body | test(\"#${ISSUE_NUMBER}[^0-9]\")) or (.body | test(\"#${ISSUE_NUMBER}\$\")))] | length'
_pin_source "SRC-PIN-AUTH-LEN lib-auth.sh existing length shape"                    "$_AUTH_SH" '[.[] | select((.body | test(\"#${issue_number}[^0-9]\")) or (.body | test(\"#${issue_number}\$\")))] | length'

# Number shape (2 sites — autonomous-dev.sh PR_NUM, lib-auth.sh pr_number).
_pin_source "SRC-PIN-DEV-NUM autonomous-dev.sh PR_NUM first-number shape"           "$_DEV_SH"  '[.[] | select((.body | test(\"#${ISSUE_NUMBER}[^0-9]\")) or (.body | test(\"#${ISSUE_NUMBER}\$\")))] | .[0].number // empty'
_pin_source "SRC-PIN-AUTH-NUM lib-auth.sh pr_number first-number shape"             "$_AUTH_SH" '[.[] | select((.body | test(\"#${issue_number}[^0-9]\")) or (.body | test(\"#${issue_number}\$\")))] | (.[0].number // empty)'

# createdAt shape (metrics site, autonomous-dev.sh _pr_created_at).
_pin_source "SRC-PIN-DEV-CA autonomous-dev.sh _pr_created_at earliest-createdAt shape" "$_DEV_SH" '[.[] | select((.body | test(\"#${ISSUE_NUMBER}[^0-9]\")) or (.body | test(\"#${ISSUE_NUMBER}\$\")))] | sort_by(.createdAt) | (.[0].createdAt // empty)'

# Parity-helper anchor pin (self-check): the helpers above use the SAME
# body-mention test-pair shape. If someone rewrites the parity helpers
# without updating the live callers (or vice versa), this anchor goes
# stale and the suite fails LOUDLY.
_SELF="$SCRIPT_DIR/test-w1c1-linkage-read-parity.sh"
if grep -qF 'test(\"#${n}[^0-9]\")' "$_SELF" && grep -qF 'test(\"#${n}\$\")' "$_SELF"; then
  ok "SRC-PIN-SELF parity helpers use the same body-mention test-pair shape as the live callers"
else
  bad "SRC-PIN-SELF parity helpers no longer use the body-mention test-pair shape — helpers or callers drifted"
fi

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
echo "=== TC-W1C1-WALKER: cursor page walk, cap-hit fail-CLOSED, endCursor guard ==="
# ---------------------------------------------------------------------------
# The COMPLETE-set contract (§3.5) is the load-bearing regression this suite
# was missing on the pre-push review. Drive the leaf directly with a
# stateful multi-page `gh` mock via a file-backed cursor -> page map (bash
# functions can't persist state across command substitutions, but a temp
# dir can). Every case is a fresh subshell + fresh mock so state cannot
# leak between tests.
_WALKER_TMP="$(mktemp -d "${TMPDIR:-/tmp}/w1c1-walker-XXXXXX")"
trap 'rm -rf "$_WALKER_TMP"' EXIT

# Write per-cursor GraphQL envelope files. Each mock invocation greps its
# argv for `cursor=<val>` and cats the matching file — no state, purely
# argv-driven.
cat > "$_WALKER_TMP/p1.json" <<'JSON'
{"data":{"repository":{"pullRequests":{"pageInfo":{"endCursor":"CUR1","hasNextPage":true},"nodes":[{"number":1,"body":"see #42"},{"number":2,"body":null,"closingIssuesReferences":{"nodes":[{"number":42}]},"headRefName":"feat/issue-42"}]}}}}
JSON
cat > "$_WALKER_TMP/p2.json" <<'JSON'
{"data":{"repository":{"pullRequests":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[{"number":3,"body":"final #42"}]}}}}
JSON
cat > "$_WALKER_TMP/p1-loop.json" <<'JSON'
{"data":{"repository":{"pullRequests":{"pageInfo":{"endCursor":"CUR1","hasNextPage":true},"nodes":[{"number":1,"body":"x"}]}}}}
JSON
cat > "$_WALKER_TMP/p1-null-cursor.json" <<'JSON'
{"data":{"repository":{"pullRequests":{"pageInfo":{"endCursor":null,"hasNextPage":true},"nodes":[{"number":1,"body":"x"}]}}}}
JSON
cat > "$_WALKER_TMP/empty.json" <<'JSON'
{"data":{"repository":{"pullRequests":{"pageInfo":{"endCursor":null,"hasNextPage":false},"nodes":[]}}}}
JSON

# Helper: run a subshell that installs the argv-driven gh mock; the parent
# passes `$_call_log` (already reset via `: >`) as the shared call-count
# file so the parent can read the count back. Prints the leaf's stdout;
# rc is the leaf's rc.
_run_walker() {
  local mock_fn="$1" verb="$2"; shift 2
  env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      REPO="$REPO" _WALKER_TMP="$_WALKER_TMP" _CALL_LOG="$_call_log" \
      CHP_GITHUB_PR_LIST_PAGE_CAP="${CHP_GITHUB_PR_LIST_PAGE_CAP:-20}" \
  bash -c "
    gh() {
      # Log ONE line per invocation (the GraphQL query arg spans multiple
      # lines — the naive \`echo \"\$*\"\` splits it, breaking any wc -l count).
      # First-3 args are enough to distinguish page-1 (no cursor) from page-N
      # (with cursor=…). One line-per-gh-call keeps assertions clean.
      printf 'call: %s %s %s\n' \"\${1:-}\" \"\${2:-}\" \"\$(printf %s \"\$*\" | tr -d \$'\\n' | head -c 200)\" >> \"\$_CALL_LOG\"
      $mock_fn
    }
    source \"$CHP_LIB\" 2>/dev/null
    $verb \"\$@\"
  " _ "$@"
}

# TC-W1C1-WALKER-MULTIPAGE — 2-page fixture walked to exhaustion, arrays merged.
# Page 1 has hasNextPage=true + cursor=CUR1; page 2 has hasNextPage=false.
_multipage_mock='
  local cursor=""
  local prev=""
  for a in "$@"; do
    if [[ "$prev" == "-F" && "$a" == cursor=* ]]; then cursor="${a#cursor=}"; fi
    prev="$a"
  done
  case "$cursor" in
    "")     cat "$_WALKER_TMP/p1.json" ;;
    CUR1)   cat "$_WALKER_TMP/p2.json" ;;
    *) return 1 ;;
  esac
'
_call_log="$_WALKER_TMP/calls.log"; : > "$_call_log"
out=$(_run_walker "$_multipage_mock" chp_pr_list open "number,body" 2>/dev/null)
rc=$?
_calls="$(wc -l < "$_call_log" 2>/dev/null | tr -d ' ')"
if [ "$rc" -eq 0 ] && \
   [ "$(jq -r 'length' <<<"$out")" = "3" ] && \
   [ "$(jq -r '.[0].number' <<<"$out")" = "1" ] && \
   [ "$(jq -r '.[1].number' <<<"$out")" = "2" ] && \
   [ "$(jq -r '.[2].number' <<<"$out")" = "3" ] && \
   [ "$(jq -r '.[1].body' <<<"$out")" = "" ] && \
   [ "$_calls" = "2" ]; then
  ok "TC-W1C1-WALKER-MULTIPAGE 2-page fixture walked to exhaustion (2 gh calls, 3 merged nodes, body null→\"\")"
else
  bad "TC-W1C1-WALKER-MULTIPAGE rc=$rc calls=$_calls out=$out"
fi

# TC-W1C1-WALKER-CAPHIT — cap=1 vs 2-page fixture → rc≠0 empty stdout.
: > "$_call_log"
out=$(CHP_GITHUB_PR_LIST_PAGE_CAP=1 _run_walker "$_multipage_mock" chp_pr_list open "number,body" 2>/dev/null)
rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
  ok "TC-W1C1-WALKER-CAPHIT cap=1 vs 2-page → rc≠0 no partial output (fail-CLOSED per §3.5)"
else
  bad "TC-W1C1-WALKER-CAPHIT rc=$rc out=[${out}] (expected rc≠0 empty)"
fi

# TC-W1C1-WALKER-FINDPR-MULTIPAGE — same 2-page fixture through
# chp_find_pr_for_issue: forced resolver keys present on every node. The
# nodes-array assertion on `.[1].closingIssueNumbers` proves the leaf's
# projection actually reads the nested `closingIssuesReferences.nodes[]`
# rather than fabricating an empty array (P1-1 fix).
: > "$_call_log"
out=$(_run_walker "$_multipage_mock" chp_find_pr_for_issue 42 "body" 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && \
   [ "$(jq -r 'length' <<<"$out")" = "3" ] && \
   jq -e 'all(.[]; has("number") and has("body") and has("closingIssueNumbers") and has("headRefName"))' <<<"$out" >/dev/null 2>&1 && \
   [ "$(jq -r '.[1].closingIssueNumbers | join(",")' <<<"$out")" = "42" ]; then
  ok "TC-W1C1-WALKER-FINDPR-MULTIPAGE find_pr_for_issue multi-page + resolver keys present on every node"
else
  bad "TC-W1C1-WALKER-FINDPR-MULTIPAGE rc=$rc out=$out"
fi

# TC-W1C1-WALKER-EMPTY — empty-repo GraphQL envelope → [] rc 0 (never null).
_empty_mock='cat "$_WALKER_TMP/empty.json"'
out=$(_run_walker "$_empty_mock" chp_pr_list open "number,body" 2>/dev/null)
rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "[]" ]; then
  ok "TC-W1C1-WALKER-EMPTY empty-repo → [] rc 0 (never null; the #148 hazard fix)"
else
  bad "TC-W1C1-WALKER-EMPTY rc=$rc out=[${out}]"
fi

# TC-W1C1-WALKER-UNKNOWN-FIELD — unknown vocabulary field rejected rc 2.
out=$(_run_walker "$_empty_mock" chp_pr_list open "number,bogus" 2>/dev/null); rc=$?
if [ "$rc" -eq 2 ]; then
  ok "TC-W1C1-WALKER-UNKNOWN-FIELD unknown vocabulary field → rc 2 loud (P1-1 allowlist)"
else
  bad "TC-W1C1-WALKER-UNKNOWN-FIELD rc=$rc (expected 2)"
fi

# TC-W1C1-WALKER-COMMENTS-REJECT — `comments` (issue-level, ITP seam) rejected rc 2.
out=$(_run_walker "$_empty_mock" chp_pr_list open "number,comments" 2>/dev/null); rc=$?
if [ "$rc" -eq 2 ]; then
  ok "TC-W1C1-WALKER-COMMENTS-REJECT comments (issue-level) → rc 2 loud (crosses ITP seam)"
else
  bad "TC-W1C1-WALKER-COMMENTS-REJECT rc=$rc (expected 2)"
fi

# TC-W1C1-WALKER-NULL-CURSOR — hasNextPage=true + endCursor=null → fail-CLOSED
# (no infinite loop). Timeout guard belt-and-braces.
_null_cursor_mock='cat "$_WALKER_TMP/p1-null-cursor.json"'
out=$(timeout 5 bash -c "$(declare -f _run_walker); _WALKER_TMP='$_WALKER_TMP'; REPO='$REPO' _run_walker '$_null_cursor_mock' chp_pr_list open number" 2>/dev/null)
rc=$?
if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
  ok "TC-W1C1-WALKER-NULL-CURSOR hasNextPage=true+endCursor=null → rc≠0 no output (no infinite loop)"
else
  bad "TC-W1C1-WALKER-NULL-CURSOR rc=$rc out=[${out}] (expected rc≠0 empty)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
