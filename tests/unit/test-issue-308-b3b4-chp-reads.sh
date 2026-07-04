#!/bin/bash
# test-issue-308-b3b4-chp-reads.sh — #296 B3+B4 (#308).
#
# Proves the THREE byte-identical raw-`gh` read migrations are zero-behavior-
# change after routing through the already-shipped CHP read verbs:
#
#   S1  lib-auth.sh::drain_agent_pr_create  PR-existence read  → chp_pr_list
#   S2  lib-auth.sh::drain_agent_bot_triggers PR-number read   → chp_pr_list
#   S3  lib-review-e2e.sh::_fetch_sha_evidence SHA-evidence read → chp_pr_view
#
# The four proofs (AC2/AC4/AC7 of #308):
#   1. GOLDEN-TRACE, argument-boundary-preserving — a recording `gh` stub writes
#      argv NUL-delimited (one arg per record, NOT space-joined), so a word-split
#      or re-escaped selector FAILS. Asserts argc + each exact arg incl. the
#      verbatim jq/-q selector (which carries spaces + `|` pipes) for all 3 sites.
#   2. SEAM-REACHABILITY + OBSERVED-CALL — each migrated path sources the REAL
#      lib-code-host.sh (live `chp_*` shim + `chp_github_*` leaf) and asserts the
#      gh-stub OBSERVED the `gh pr list`/`gh pr view` argv THROUGH the verb —
#      proving the path was exercised, not merely reachable.
#   3. FAIL-SOFT RATIONALE — with the verb UNDEFINED the site degrades to "0
#      PRs"/empty WITHOUT crashing (the `2>/dev/null || echo/true` wrapper). This
#      is exactly why reachability-alone is the wrong-reason pass proof #2 rules
#      out (#308 AC4 rationale / plan-eng-review [P1]).
#   4. AC7 call-expression byte-identity premise — the brokers are always called
#      with "$REPO" as the repo arg, so dropping `--repo "$repo"` and letting the
#      verb supply `--repo "$REPO"` is byte-identical.
#
# Plus source guards (zero executable raw gh pr list/view in the two libs; no new
# lib-code-host self-source in lib-review-e2e.sh) and the AC6 INV-91 bullet.
#
# Run: bash tests/unit/test-issue-308-b3b4-chp-reads.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
AUTH_LIB="$SCRIPTS/lib-auth.sh"
CHP_LIB="$SCRIPTS/lib-code-host.sh"
E2E_LIB="$SCRIPTS/lib-review-e2e.sh"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"
DEV_SH="$SCRIPTS/autonomous-dev.sh"
REVIEW_SH="$SCRIPTS/autonomous-review.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected: |$expected|"
    echo "      actual:   |$actual|"
    FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      needle: |$needle|"; echo "      hay:    |$hay|"
    FAIL=$((FAIL + 1))
  fi
}
pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

export REPO=zxkane/autonomous-dev-team

# The verbatim selectors the three sites pass (must survive byte-identically as a
# SINGLE argv element). Kept here as the golden expectation; ${issue}/${sha} are
# the runtime interpolations the harness drives with.
issue=308
sha=deadbeefcafe
SEL_EXISTS="[.[] | select(.body | test(\"#${issue}[^0-9]\") or test(\"#${issue}\$\"))] | length"
SEL_PRNUM="[.[] | select(.body | test(\"#${issue}[^0-9]\") or test(\"#${issue}\$\"))] | (.[0].number // empty)"
SEL_SHA="[.comments[] | select(.body | contains(\"e2e-evidence: complete sha=\\\"${sha}\\\"\")) | .body] | last // empty"

# ===========================================================================
# Recording `gh` stub helper — captures every `gh` invocation NUL-delimited.
# Each call's argv is written to $REC_DIR/call-<N> as NUL-separated records, so
# argument boundaries are preserved EXACTLY (no space-join collapse). read_call
# reads one back into the `CALL_ARGV` array.
# ===========================================================================
# The stub body (string) injected into the harness bash -c. It also serves a
# benign payload so the caller's own `|| echo/true` path behaves like a no-PR
# read (S1/S2) and an empty-evidence read (S3).
GH_STUB_BODY='
gh() {
  local n; n=$(cat "$REC_DIR/.count" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$REC_DIR/.count"
  : > "$REC_DIR/call-$n"
  printf "%s\0" "$@" >> "$REC_DIR/call-$n"
  # Tag the verb (first two args) so the harness can find the api-graphql/
  # pr-view call.
  printf "%s %s\n" "${1:-}" "${2:-}" >> "$REC_DIR/.verbs"
  # W1c1 (#397): chp_pr_list now emits `gh api graphql` (cursor page walk).
  # Return the empty-PR envelope so the caller-side jq counts 0 (no PR).
  # pr view stays byte-identical (chp_pr_view is unchanged at W1c1).
  if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
    printf %s "{\"data\":{\"repository\":{\"pullRequests\":{\"pageInfo\":{\"endCursor\":null,\"hasNextPage\":false},\"nodes\":[]}}}}"
    return 0
  fi
  if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then printf ""; return 0; fi
  return 0
}
'

# read_call <rec_dir> <call-N> → fills global CALL_ARGV[] with the NUL-delimited args.
read_call() {
  local f="$1/$2"
  CALL_ARGV=()
  [[ -f "$f" ]] || return 1
  mapfile -d '' -t CALL_ARGV < "$f"
  return 0
}
# call_for_verb <rec_dir> <verb1> <verb2> → echoes the call-N file holding that verb.
call_for_verb() {
  local dir="$1" v1="$2" v2="$3" n=0
  while IFS= read -r line; do
    n=$((n+1))
    [[ "$line" == "$v1 $v2" ]] && { echo "call-$n"; return 0; }
  done < "$dir/.verbs"
  return 1
}

# ===========================================================================
# 1+2. GOLDEN-TRACE (argument-boundary-preserving) + SEAM-REACHABILITY.
#      Drive the REAL functions with the REAL CHP seam sourced and the recording
#      gh stub; assert the OBSERVED argv is byte-identical, boundaries intact.
# ===========================================================================

# --- S1: drain_agent_pr_create → chp_pr_list (existence read) -----------------
echo "=== S1: drain_agent_pr_create PR-existence read → chp_pr_list ==="
RUNDIR=$(mktemp -d)
PRFILE="$RUNDIR/pr-create"; printf 'branch: feat/issue-308-x\nfeat: t\nBody\nCloses #308\n' > "$PRFILE"
REC1="$RUNDIR/rec1"; mkdir -p "$REC1"
# NOTE: lib-auth.sh resets AGENT_GH_TOKEN_FILE="" at load, so the broker's
# arm-guard env MUST be set AFTER `source` (mirrors test-token-split-234.sh).
env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
    REPO="$REPO" REC_DIR="$REC1" PRFILE="$PRFILE" \
  bash -c "
    set -uo pipefail
    source '$AUTH_LIB' 2>/dev/null   # self-sources lib-code-host.sh → chp_pr_list live
    $GH_STUB_BODY
    AGENT_GH_TOKEN_FILE='/some/scoped/tok'
    AGENT_PR_CREATE_FILE=\"\$PRFILE\"
    drain_agent_pr_create $issue \"\$REPO\"
  " >/dev/null 2>&1

if [[ -f "$REC1/.verbs" ]] && grep -qx "api graphql" "$REC1/.verbs"; then
  pass "S1 seam-reachability: stub OBSERVED a 'gh api graphql' call through chp_pr_list (exercised, not just reachable)"
  cn=$(call_for_verb "$REC1" api graphql) && read_call "$REC1" "$cn"
  # W1c1 (#397) reshape: the leaf now emits `gh api graphql` with cursor
  # pagination (§3.5). No `--limit`/`--json`/`-q` cross the seam. Positional
  # STATE + FIELDS-CSV live on the CALLER side. Assert the structural argv:
  # api graphql, owner/repo binds, query carries pullRequests + states +
  # pageInfo + body selection.
  argv_joined="${CALL_ARGV[*]:-}"
  assert_eq "S1 argv[0..1]=api graphql" "api graphql" "${CALL_ARGV[0]:-} ${CALL_ARGV[1]:-}"
  assert_contains "S1 -F owner=zxkane present"            "owner=zxkane" "$argv_joined"
  assert_contains "S1 -F repo=autonomous-dev-team present" "repo=autonomous-dev-team" "$argv_joined"
  assert_contains "S1 query carries pullRequests(first:100" "pullRequests(first: 100" "$argv_joined"
  assert_contains "S1 states filter (states:[OPEN])"        "states: [OPEN]" "$argv_joined"
  assert_contains "S1 pageInfo cursor present (§3.5 exhaustion)" "pageInfo { endCursor hasNextPage" "$argv_joined"
  assert_contains "S1 query selects body"                    " body " "$argv_joined"
  if [[ "$argv_joined" != *" -q "* ]]; then
    pass "S1 no -q crosses the seam (W1c1 abstract contract)"
  else
    fail "S1 -q leaked into gh argv (W1c1 regression): $argv_joined"
  fi
else
  fail "S1 seam-reachability: stub did NOT observe a 'gh api graphql' — chp_pr_list not exercised (fail-soft hazard)"
fi
rm -rf "$RUNDIR"

# --- S2: drain_agent_bot_triggers → chp_pr_list (PR-number read) --------------
echo "=== S2: drain_agent_bot_triggers PR-number read → chp_pr_list ==="
RUNDIR=$(mktemp -d)
BTFILE="$RUNDIR/bot-triggers"; printf '/q review\n' > "$BTFILE"
REC2="$RUNDIR/rec2"; mkdir -p "$REC2"
# gh-as-user.sh must exist for the broker not to early-return; point _LIB_AUTH_DIR
# at the common scripts dir (where gh-as-user.sh lives). The PR-number read fires
# BEFORE any post, and our stub returns empty number → broker WARNs + returns, so
# no gh-as-user.sh post is attempted. We only need the pr-list call recorded.
env -u CODE_HOST -u AUTONOMOUS_CONF -u PROJECT_DIR \
    REPO="$REPO" REC_DIR="$REC2" BTFILE="$BTFILE" \
    AUTONOMOUS_CONF_DIR="$PROJECT_ROOT/skills/autonomous-common/scripts" \
  bash -c "
    set -uo pipefail
    source '$AUTH_LIB' 2>/dev/null
    $GH_STUB_BODY
    AGENT_GH_TOKEN_FILE='/some/scoped/tok'
    AGENT_BOT_TRIGGER_FILE=\"\$BTFILE\"
    drain_agent_bot_triggers $issue \"\$REPO\" '/q review'
  " >/dev/null 2>&1

if [[ -f "$REC2/.verbs" ]] && grep -qx "api graphql" "$REC2/.verbs"; then
  pass "S2 seam-reachability: stub OBSERVED a 'gh api graphql' call through chp_pr_list"
  cn=$(call_for_verb "$REC2" api graphql) && read_call "$REC2" "$cn"
  # W1c1 (#397) reshape: same rationale as S1 above — `gh api graphql` +
  # cursor page walk (§3.5). No `--limit`/`--json`/`-q` cross the seam.
  # STATE=open maps to states:[OPEN]; FIELDS-CSV=number,body selects both
  # `number` and `body` in the GraphQL query.
  argv_joined="${CALL_ARGV[*]:-}"
  assert_eq "S2 argv[0..1]=api graphql" "api graphql" "${CALL_ARGV[0]:-} ${CALL_ARGV[1]:-}"
  assert_contains "S2 -F owner=zxkane present"            "owner=zxkane" "$argv_joined"
  assert_contains "S2 -F repo=autonomous-dev-team present" "repo=autonomous-dev-team" "$argv_joined"
  assert_contains "S2 query carries pullRequests(first:100" "pullRequests(first: 100" "$argv_joined"
  assert_contains "S2 states filter (states:[OPEN])"        "states: [OPEN]" "$argv_joined"
  assert_contains "S2 pageInfo cursor present (§3.5 exhaustion)" "pageInfo { endCursor hasNextPage" "$argv_joined"
  assert_contains "S2 query selects number"                 " number " "$argv_joined"
  assert_contains "S2 query selects body"                   " body " "$argv_joined"
  if [[ "$argv_joined" != *" -q "* ]]; then
    pass "S2 no -q crosses the seam (W1c1 abstract contract)"
  else
    fail "S2 -q leaked into gh argv (W1c1 regression): $argv_joined"
  fi
else
  fail "S2 seam-reachability: stub did NOT observe a 'gh api graphql' — chp_pr_list not exercised"
fi
rm -rf "$RUNDIR"

# --- S3: _fetch_sha_evidence → chp_pr_view (SHA-evidence read) ----------------
echo "=== S3: _fetch_sha_evidence SHA-evidence read → chp_pr_view ==="
RUNDIR=$(mktemp -d)
REC3="$RUNDIR/rec3"; mkdir -p "$REC3"
env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
    REPO="$REPO" REC_DIR="$REC3" PR_NUMBER=42 PR_HEAD_SHA="$sha" \
  bash -c "
    set -uo pipefail
    source '$CHP_LIB' 2>/dev/null    # the seam the review wrapper sources BEFORE lib-review-e2e
    source '$E2E_LIB' 2>/dev/null    # NOTE: does NOT self-source lib-code-host (verified below)
    $GH_STUB_BODY
    _fetch_sha_evidence 1 0
  " >/dev/null 2>&1

if [[ -f "$REC3/.verbs" ]] && grep -qx "pr view" "$REC3/.verbs"; then
  pass "S3 seam-reachability: stub OBSERVED a 'gh pr view' call through chp_pr_view"
  cn=$(call_for_verb "$REC3" pr view) && read_call "$REC3" "$cn"
  # argc: pr view 42 --repo $REPO --json comments --jq <selector> = 9 args
  assert_eq "S3 golden-trace argc (boundaries preserved)" "9" "${#CALL_ARGV[@]}"
  assert_eq "S3 argv[0]=pr" "pr" "${CALL_ARGV[0]:-}"
  assert_eq "S3 argv[1]=view" "view" "${CALL_ARGV[1]:-}"
  assert_eq "S3 argv[2]=42 (PR_NUMBER positional)" "42" "${CALL_ARGV[2]:-}"
  assert_eq "S3 argv[3]=--repo" "--repo" "${CALL_ARGV[3]:-}"
  assert_eq "S3 argv[4]=\$REPO" "$REPO" "${CALL_ARGV[4]:-}"
  assert_eq "S3 argv[5]=--json" "--json" "${CALL_ARGV[5]:-}"
  assert_eq "S3 argv[6]=comments" "comments" "${CALL_ARGV[6]:-}"
  assert_eq "S3 argv[7]=--jq" "--jq" "${CALL_ARGV[7]:-}"
  assert_eq "S3 argv[8]=<verbatim sha-match selector, single element>" "$SEL_SHA" "${CALL_ARGV[8]:-}"
else
  fail "S3 seam-reachability: stub did NOT observe a 'gh pr view' — chp_pr_view not exercised"
fi
# TC-308-GT-SELECTOR — boundary proof: the captured selector arg is a SINGLE argv
# element carrying spaces AND a `|` pipe. A space-joined / word-split capture would
# have fractured it (and the per-arg assert above would have read a fragment), so
# this is the explicit demonstration that the NUL-delimited trace preserves
# boundaries the jq/-q selectors depend on (#308 AC2).
assert_contains "TC-308-GT-SELECTOR captured selector is one element containing a space" " " "${CALL_ARGV[8]:-}"
assert_contains "TC-308-GT-SELECTOR captured selector is one element containing a | pipe" "|" "${CALL_ARGV[8]:-}"
rm -rf "$RUNDIR"

# ===========================================================================
# 3. FAIL-SOFT RATIONALE (AC4) — with the verb UNDEFINED the migrated site
#    degrades to empty/"0 PRs" WITHOUT crashing (the `2>/dev/null || echo/true`).
#    This is the wrong-reason pass the seam tests above rule out: reachability
#    alone would pass because the read returns empty exactly like "no PR found".
# ===========================================================================
echo "=== FAIL-SOFT: undefined verb degrades to empty, does NOT crash (AC4 rationale) ==="
# S3 shape: source lib-review-e2e.sh WITHOUT the CHP seam → chp_pr_view undefined.
rc=0
out=$(env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
        REPO="$REPO" PR_NUMBER=42 PR_HEAD_SHA="$sha" \
      bash -c "
        set -uo pipefail
        # Source the lib in a way that does NOT bring chp_pr_view into scope:
        # blank the self-source target so even the ITP self-source is inert, and
        # do NOT source lib-code-host.sh. chp_pr_view is therefore command-not-found.
        source '$E2E_LIB' 2>/dev/null
        unset -f chp_pr_view 2>/dev/null   # ensure undefined regardless of source side effects
        _fetch_sha_evidence 1 0
        echo \"RC=\$?\"
      " 2>/dev/null) || rc=$?
if [[ "$out" == *"RC=0"* && "$rc" -eq 0 ]]; then
  pass "FAIL-SOFT: undefined chp_pr_view → _fetch_sha_evidence returns empty + rc=0 (no crash) — so reachability≠exercised"
else
  fail "FAIL-SOFT: undefined verb did NOT fail-soft as expected (out=[$out] rc=$rc)"
fi

# ===========================================================================
# 4. SOURCE GUARDS — zero executable raw gh in the migrated read positions; no
#    new lib-code-host self-source added to lib-review-e2e.sh.
# ===========================================================================
echo "=== SOURCE GUARDS ==="
# Executable (non-comment) `gh pr list` in lib-auth.sh must be ZERO. Strip
# leading-whitespace #-comment lines first (same classifier as the cutover guard).
n_auth=$(grep -aE '(^|[^A-Za-z_-])gh ' "$AUTH_LIB" | awk '{s=$0;sub(/^[[:space:]]+/,"",s); if(substr(s,1,1)=="#")next; print s}' | grep -c 'gh pr list' || true)
assert_eq "TC-308-SRC-AUTH lib-auth.sh has ZERO executable raw 'gh pr list'" "0" "$n_auth"
n_e2e=$(grep -aE '(^|[^A-Za-z_-])gh ' "$E2E_LIB" | awk '{s=$0;sub(/^[[:space:]]+/,"",s); if(substr(s,1,1)=="#")next; print s}' | grep -c 'gh pr view' || true)
assert_eq "TC-308-SRC-E2E lib-review-e2e.sh has ZERO executable raw 'gh pr view'" "0" "$n_e2e"
# lib-review-e2e.sh must NOT have gained a lib-code-host.sh self-source (the
# production source graph stays untouched per #308 Requirements / Out-of-Scope).
# Classify like the cutover guard: strip leading-whitespace #-comment lines first
# (a `source … lib-code-host.sh` mention inside a comment is not a self-source).
n_selfsource=$(awk '{s=$0;sub(/^[[:space:]]+/,"",s); if(substr(s,1,1)=="#")next; print s}' "$E2E_LIB" \
  | grep -cE 'source[^#]*lib-code-host\.sh' || true)
assert_eq "TC-308-SRC-NO-SELFSOURCE lib-review-e2e.sh did NOT add an executable lib-code-host.sh self-source" "0" "$n_selfsource"
# Both migrated calls invoke the verb at exactly the migrated read positions.
assert_eq "TC-308-SRC-AUTH-VERB lib-auth.sh invokes chp_pr_list at both read sites (×2)" \
  "2" "$(grep -cE 'chp_pr_list open "(body|number,body)"' "$AUTH_LIB" || true)"
assert_eq "TC-308-SRC-E2E-VERB lib-review-e2e.sh invokes chp_pr_view at the SHA-evidence read (×1)" \
  "1" "$(grep -c 'chp_pr_view "\$PR_NUMBER" --json comments' "$E2E_LIB" || true)"

# ===========================================================================
# 5. AC7 — call-expression byte-identity premise: the brokers are always called
#    with "$REPO" as the repo arg, so the verb's hardcoded `--repo "$REPO"` is
#    byte-identical to the dropped `--repo "$repo"`.
# ===========================================================================
echo "=== AC7: call-expression \$repo == \$REPO byte-identity premise ==="
if grep -qF 'drain_agent_pr_create "$ISSUE_NUMBER" "$REPO"' "$DEV_SH"; then
  pass "TC-308-AC7-DEV-CREATE autonomous-dev.sh calls drain_agent_pr_create \"\$ISSUE_NUMBER\" \"\$REPO\""
else
  fail "TC-308-AC7-DEV-CREATE drain_agent_pr_create not called with \"\$REPO\" in autonomous-dev.sh"
fi
if grep -qF 'drain_agent_bot_triggers "$ISSUE_NUMBER" "$REPO"' "$DEV_SH"; then
  pass "TC-308-AC7-DEV-BOT autonomous-dev.sh calls drain_agent_bot_triggers \"\$ISSUE_NUMBER\" \"\$REPO\""
else
  fail "TC-308-AC7-DEV-BOT drain_agent_bot_triggers not called with \"\$REPO\" in autonomous-dev.sh"
fi
if grep -qF 'drain_agent_bot_triggers "$ISSUE_NUMBER" "$REPO"' "$REVIEW_SH"; then
  pass "TC-308-AC7-REVIEW-BOT autonomous-review.sh calls drain_agent_bot_triggers \"\$ISSUE_NUMBER\" \"\$REPO\""
else
  fail "TC-308-AC7-REVIEW-BOT drain_agent_bot_triggers not called with \"\$REPO\" in autonomous-review.sh"
fi

# ===========================================================================
# 6. AC6 — the exact INV-91 Migration-log bullet is present (also pinned in
#    test-spec-drift.sh as TC-SPEC-GATE-308). Asserted here for locality too.
# ===========================================================================
echo "=== AC6: INV-91 Migration-log bullet ==="
AC6_BULLET='- #296 B3+B4 (#308): lib-auth PR-existence reads (2× chp_pr_list, lib-auth.sh), lib-review-e2e SHA-evidence read (1× chp_pr_view, lib-review-e2e.sh) — byte-identical; baseline shrank by 3 sigs.'
if grep -qF -- "$AC6_BULLET" "$INVARIANTS"; then
  pass "TC-308-AC6-BULLET exact INV-91 Migration-log bullet present in invariants.md"
else
  fail "TC-308-AC6-BULLET INV-91 Migration-log bullet missing/changed in invariants.md"
fi

# ===========================================================================
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
