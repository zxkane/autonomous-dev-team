#!/bin/bash
# test-chp-pr-lifecycle.sh — #282: CHP PR-lifecycle leaf migration.
#
# Proves the Code-Host-Provider (CHP) PR-lifecycle contract
# (provider-spec.md §3.2/§4.2, [INV-87]/[INV-88]; design [M1]/[M2]/[M4]/[M8]) is
# a zero-behavior-change GitHub refactor:
#
#   1. Golden-trace argv — each migrated CHP leaf (find_pr_for_issue, ci_status,
#      mergeable, create_pr, approve, request_changes, merge) emits BYTE-IDENTICAL
#      `gh` argv after routing through the verb, and the resolve-threads GraphQL
#      list + resolveReviewThread mutation carry their query verbatim.
#   2. M8 review-thread shape — {thread_id, resolved, comments:[{id,path,line,…}]}.
#   3. chp_close_keyword — `Closes #<N>` for GitHub; empty for merge_closes_issue=0.
#   4. Capability-branch via the named degraded fake provider (rest_request_changes=0
#      / review_bots=0 / merge_closes_issue=0) — each caps=0 branch reachable NOW.
#   5. Function-mock shim audit (§7.3 m3) — fetch_pr_for_issue keeps its name and
#      delegates to the verb; the 5 function-mock test files pass UNEDITED.
#   6. Conformance fixture rule (INV-75) — cp -r providers/.
#
# (Dispatch routing chp_<verb>→chp_github_<verb> + the .caps parse are covered by
# test-provider-dispatch.sh #280; this file adds the byte-identical-argv proof.)
#
# Run: bash tests/unit/test-chp-pr-lifecycle.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
COMMON_SCRIPTS="$PROJECT_ROOT/skills/autonomous-common/scripts"
CHP_LIB="$SCRIPTS/lib-code-host.sh"
PROVIDERS="$SCRIPTS/providers"
FAKE_PROVIDER="$SCRIPT_DIR/fixtures/provider-degraded"

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

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane

# ===========================================================================
# 1. GOLDEN-TRACE — record the exact `gh` argv each CHP leaf emits, assert it
#    byte-identical to the pre-refactor call (the no-behavior-change proof).
# ===========================================================================
echo "=== GOLDEN-TRACE: byte-identical gh argv per migrated CHP leaf ==="
# A recording `gh` stub: writes the full argv (one arg per line) to a file and
# serves a benign payload so the verb's own jq (if any) still runs.
_GH_ARGV_FILE="$(mktemp)"
run_trace() {
  # run_trace <verb> <args...> — source the lib with a recording gh, invoke the
  # verb, echo the recorded argv (newline-joined into one space-separated line).
  local verb="$1"; shift
  env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
      REPO="$REPO" _GH_ARGV_FILE="$_GH_ARGV_FILE" \
  bash -c '
    set -uo pipefail
    gh() { printf "%s\n" "$@" > "$_GH_ARGV_FILE"; return 0; }
    source "'"$CHP_LIB"'" 2>/dev/null
    "$@" >/dev/null 2>&1
  ' _ "$verb" "$@"
  tr "\n" " " < "$_GH_ARGV_FILE"
}

# TC-CHP-CI — ci_is_green's `gh pr checks … --json state -q '[.[].state]'`.
argv=$(run_trace chp_ci_status 42 --json state -q '[.[].state]')
assert_eq "TC-CHP-CI chp_ci_status byte-identical gh pr checks argv" \
  "pr checks 42 --repo $REPO --json state -q [.[].state] " "$argv"

# TC-CHP-FINDPR — resolve_pr_for_issue's `gh pr list --json $FIELDS -q $q`. FIELDS
# forwarded byte-identically (#148: `body` must survive in FIELDS; #274).
argv=$(run_trace chp_find_pr_for_issue 282 "number,headRefOid,body" -q '.[0]')
assert_eq "TC-CHP-FINDPR chp_find_pr_for_issue byte-identical gh pr list argv (FIELDS forwarded, M1)" \
  "pr list --repo $REPO --state open --json number,headRefOid,body -q .[0] " "$argv"

# TC-CHP-FINDPR-FIELDS-REQUIRED — calling without FIELDS is an error (M1).
rc=0
env REPO="$REPO" bash -c 'gh(){ :; }; source "'"$CHP_LIB"'" 2>/dev/null; chp_find_pr_for_issue 282' >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && { echo -e "  ${GREEN}PASS${NC}: TC-CHP-FINDPR-FIELDS-REQUIRED missing FIELDS errors (rc=$rc)"; PASS=$((PASS+1)); } \
                  || { echo -e "  ${RED}FAIL${NC}: TC-CHP-FINDPR-FIELDS-REQUIRED missing FIELDS did NOT error"; FAIL=$((FAIL+1)); }

# TC-CHP-MERGEABLE — autonomous-review.sh's `gh pr view … --json mergeable -q .mergeable` (M2).
argv=$(run_trace chp_mergeable 42 -q '.mergeable')
assert_eq "TC-CHP-MERGEABLE chp_mergeable byte-identical gh pr view --json mergeable argv (M2)" \
  "pr view 42 --repo $REPO --json mergeable -q .mergeable " "$argv"

# TC-CHP-CREATE — drain_agent_pr_create's `gh pr create --head … --title … --body …`.
argv=$(run_trace chp_create_pr --head feat/x --title T --body B)
assert_eq "TC-CHP-CREATE chp_create_pr byte-identical gh pr create argv" \
  "pr create --repo $REPO --head feat/x --title T --body B " "$argv"

# TC-CHP-APPROVE — autonomous-review.sh's `gh pr review … --approve --body …`.
argv=$(run_trace chp_approve 42 --approve --body OK)
assert_eq "TC-CHP-APPROVE chp_approve byte-identical gh pr review --approve argv" \
  "pr review 42 --repo $REPO --approve --body OK " "$argv"

# TC-CHP-REQCHANGES — lib-review-request-changes.sh's `gh pr review … --request-changes --body …`.
argv=$(run_trace chp_request_changes 42 "blocking finding")
assert_eq "TC-CHP-REQCHANGES chp_request_changes byte-identical gh pr review --request-changes argv" \
  "pr review 42 --repo $REPO --request-changes --body blocking finding " "$argv"

# TC-CHP-MERGE — autonomous-review.sh's `gh pr merge … --squash --delete-branch`.
argv=$(run_trace chp_merge 42 --squash --delete-branch)
assert_eq "TC-CHP-MERGE chp_merge byte-identical gh pr merge --squash --delete-branch argv" \
  "pr merge 42 --repo $REPO --squash --delete-branch " "$argv"

# TC-CHP-THREADS — resolve-threads.sh reviewThreads list GraphQL argv carries the query.
argv=$(run_trace chp_review_threads 42)
assert_contains "TC-CHP-THREADS chp_review_threads emits gh api graphql" "api graphql" "$argv"
assert_contains "TC-CHP-THREADS reviewThreads(first: 100) query verbatim" "reviewThreads(first: 100)" "$argv"
assert_contains "TC-CHP-THREADS -F prNumber forwards the PR" "prNumber=42" "$argv"
assert_contains "TC-CHP-THREADS -F owner derived from REPO" "owner=zxkane" "$argv"
assert_contains "TC-CHP-THREADS -F repo derived from REPO" "repo=autonomous-dev-team" "$argv"

# TC-CHP-RESOLVE — resolveReviewThread mutation argv carries threadId + the mutation.
argv=$(run_trace chp_resolve_thread "PRRT_kwABC")
assert_contains "TC-CHP-RESOLVE chp_resolve_thread emits resolveReviewThread mutation" "resolveReviewThread(input: {threadId: \$threadId})" "$argv"
assert_contains "TC-CHP-RESOLVE -F threadId forwards the thread id" "threadId=PRRT_kwABC" "$argv"

# ===========================================================================
# 2. M8 review-thread shape — {thread_id, resolved, comments:[{id,path,line,…}]}.
# ===========================================================================
echo "=== M8 review-thread shape (distinct from the ITP issue-comment shape) ==="
_GRAPHQL_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
  {"id":"T1","isResolved":false,"comments":{"nodes":[
    {"databaseId":501,"path":"src/a.sh","line":12,"originalLine":10,"author":{"login":"kane-review-agent"},"body":"fix this","createdAt":"2026-06-27T10:00:00Z"}
  ]}},
  {"id":"T2","isResolved":true,"comments":{"nodes":[
    {"databaseId":502,"path":"src/b.sh","line":null,"originalLine":7,"author":{"login":"alice"},"body":"ok","createdAt":"2026-06-27T11:00:00Z"}
  ]}}
]}}}}}'
shape=$(
  env REPO="$REPO" _GRAPHQL_THREADS="$_GRAPHQL_THREADS" bash -c '
    # gh stub that applies the verb'\''s --jq to the canned GraphQL payload.
    gh() {
      local jq_filter="" i
      for ((i=1;i<=$#;i++)); do if [[ "${!i}" == "--jq" ]]; then local j=$((i+1)); jq_filter="${!j}"; break; fi; done
      jq -c "$jq_filter" <<<"$_GRAPHQL_THREADS"
    }
    source "'"$CHP_LIB"'" 2>/dev/null
    chp_review_threads 42
  '
)
keys=$(jq -r '.[0] | keys_unsorted | join(",")' <<<"$shape")
assert_eq "TC-CHP-THREAD-SHAPE thread element has thread_id,resolved,comments" "thread_id,resolved,comments" "$keys"
ckeys=$(jq -r '.[0].comments[0] | keys_unsorted | join(",")' <<<"$shape")
assert_eq "TC-CHP-THREAD-SHAPE comment carries CHP-owned path/line (M8)" "id,path,line,author,body,createdAt" "$ckeys"
tid=$(jq -r '.[0].thread_id' <<<"$shape")
assert_eq "TC-CHP-THREAD-SHAPE thread_id from GraphQL node id" "T1" "$tid"
resolved=$(jq -r '.[0].resolved' <<<"$shape")
assert_eq "TC-CHP-THREAD-SHAPE resolved flag preserved" "false" "$resolved"
# select-unresolved (resolve-threads.sh's byte-equivalent of select(.isResolved==false).id)
unres=$(jq -r '.[] | select(.resolved==false) | .thread_id' <<<"$shape" | tr '\n' ' ')
assert_eq "TC-CHP-THREAD-SHAPE select-unresolved → only T1 (byte-equivalent to old select(.isResolved==false))" "T1 " "$unres"
# line falls back to originalLine when line is null
line2=$(jq -r '.[1].comments[0].line' <<<"$shape")
assert_eq "TC-CHP-THREAD-SHAPE line falls back to originalLine when null" "7" "$line2"

# ===========================================================================
# 3. chp_close_keyword — GitHub `Closes #<N>`; empty for merge_closes_issue=0.
# ===========================================================================
echo "=== chp_close_keyword (M4) ==="
kw=$(env REPO="$REPO" bash -c 'source "'"$CHP_LIB"'" 2>/dev/null; chp_close_keyword 282')
assert_eq "TC-CHP-CLOSEKW-GH chp_close_keyword 282 → Closes #282 (GitHub)" "Closes #282" "$kw"

# ===========================================================================
# 4. CAPABILITY-BRANCH via the named degraded fake provider (§7.4).
#    rest_request_changes=0 / review_bots=0 / merge_closes_issue=0 each ship now.
# ===========================================================================
echo "=== CAPABILITY-BRANCH: degraded fake CHP provider caps=0 (public seam) ==="
if [[ -d "$FAKE_PROVIDER" ]]; then
  fake=$(
    env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
        CODE_HOST=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
    bash -c '
      source "'"$CHP_LIB"'" 2>/dev/null
      echo "RRC=$(chp_caps rest_request_changes)"
      echo "RB=$(chp_caps review_bots)"
      echo "MCI=$(chp_caps merge_closes_issue)"
    '
  )
  assert_contains "TC-CHP-CAP-REQCHG0 degraded: rest_request_changes=0 (request-changes emulation branch)" "RRC=0" "$fake"
  assert_contains "TC-CHP-CAP-BOTS0 degraded: review_bots=0 (chp_trigger_bot no-op branch)" "RB=0" "$fake"
  assert_contains "TC-CHP-CAP-MCI0 degraded: merge_closes_issue=0 (caller transitions post-merge; close_keyword empty)" "MCI=0" "$fake"

  # The request-changes caps=0 branch: submit_request_changes must SKIP the native
  # REST submit (no `gh pr review` leaf) when rest_request_changes=0 — the live
  # caps=0 branch that ships now. Drive it through the real helper.
  rc_skip=$(
    env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
        REPO="$REPO" CODE_HOST=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
    bash -c '
      log() { :; }
      gh() { echo "GH_CALLED:$*"; }   # MUST NOT be reached on the caps=0 branch
      source "'"$CHP_LIB"'" 2>/dev/null
      source "'"$SCRIPTS"'/lib-review-request-changes.sh" 2>/dev/null
      submit_request_changes 42 "blocking" 2>&1
      echo "RC=$?"
    '
  )
  if [[ "$rc_skip" != *"GH_CALLED"* && "$rc_skip" == *"RC=0"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-CHP-CAP-REQCHG0-LIVE submit_request_changes skips native submit when rest_request_changes=0"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-CHP-CAP-REQCHG0-LIVE submit_request_changes did NOT skip"; echo "      out: $rc_skip"; FAIL=$((FAIL+1))
  fi
else
  echo -e "  ${RED}FAIL${NC}: degraded fake provider fixture missing at $FAKE_PROVIDER (expected from #280)"
  FAIL=$((FAIL+1))
fi

# ===========================================================================
# 5. FUNCTION-MOCK SHIM AUDIT (§7.3 m3) — fetch_pr_for_issue keeps its name and
#    delegates to chp_find_pr_for_issue; resolve_pr_for_issue routes through it.
# ===========================================================================
echo "=== FUNCTION-MOCK SHIM AUDIT (§7.3 m3) ==="
# fetch_pr_for_issue still defined (same name → the 5 function-mock test files bind).
audit=$(
  env -u PROJECT_DIR REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID=test-chp-$$ MAX_RETRIES=3 MAX_CONCURRENT=5 \
  bash -c '
    source "'"$SCRIPTS"'/lib-dispatch.sh" 2>/dev/null
    declare -F fetch_pr_for_issue >/dev/null 2>&1 && echo "FETCH_SHIM_PRESENT"
    declare -F resolve_pr_for_issue >/dev/null 2>&1 && echo "RESOLVE_PRESENT"
    declare -F chp_find_pr_for_issue >/dev/null 2>&1 && echo "CHP_VERB_PRESENT"
  '
)
assert_contains "TC-CHP-SHIM-NORENAME fetch_pr_for_issue keeps its exact name (function-mock binds)" "FETCH_SHIM_PRESENT" "$audit"
assert_contains "TC-CHP-SHIM resolve_pr_for_issue still defined" "RESOLVE_PRESENT" "$audit"
assert_contains "TC-CHP-SHIM chp_find_pr_for_issue verb reachable from lib-dispatch.sh" "CHP_VERB_PRESENT" "$audit"

# resolve_pr_for_issue reaches chp_find_pr_for_issue (stub the verb, observe the hit).
delegated=$(
  env -u PROJECT_DIR REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID=test-chp-$$ MAX_RETRIES=3 MAX_CONCURRENT=5 \
  bash -c '
    source "'"$SCRIPTS"'/lib-dispatch.sh" 2>/dev/null
    chp_find_pr_for_issue() { echo "VERB_HIT:$2"; }   # override the github leaf
    resolve_pr_for_issue 282 "number,body"
  '
)
assert_contains "TC-CHP-SHIM-DELEGATES resolve_pr_for_issue routes the leaf through chp_find_pr_for_issue" "VERB_HIT:number,body" "$delegated"

# ===========================================================================
# 6. CONFORMANCE FIXTURE RULE (INV-75) — cp -r providers/.
# ===========================================================================
echo "=== CONFORMANCE FIXTURE RULE (INV-75) ==="
e2e_fixture="$SCRIPT_DIR/test-entry-point-startup-e2e.sh"
if grep -qE 'cp -r .*/providers' "$e2e_fixture"; then
  echo -e "  ${GREEN}PASS${NC}: TC-CHP-FIXTURE-CPR fake-skill-tree fixture carries cp -r providers/ (INV-75)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CHP-FIXTURE-CPR fixture missing cp -r providers/ (INV-75)"; FAIL=$((FAIL+1))
fi

# resolve-threads.sh routes through the CHP verbs — no EXECUTABLE inline
# `gh api graphql` leaf (the `resolveReviewThread` token only survives in the
# header comment, which is fine). Strip comments before grepping for the leaf.
rt_code=$(grep -vE '^\s*#' "$COMMON_SCRIPTS/resolve-threads.sh")
if grep -qE 'chp_review_threads|chp_resolve_thread' <<<"$rt_code" \
   && ! grep -qE 'gh api graphql' <<<"$rt_code"; then
  echo -e "  ${GREEN}PASS${NC}: TC-CHP-RESOLVE-THREADS resolve-threads.sh routes through the CHP verbs (no inline gh api graphql leaf)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CHP-RESOLVE-THREADS resolve-threads.sh still has an inline gh api graphql leaf"; FAIL=$((FAIL+1))
fi

rm -f "$_GH_ARGV_FILE"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
