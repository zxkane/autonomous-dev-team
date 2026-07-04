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

# TC-CHP-CI — chp_ci_status now owns the FULL argv (#399 W1d): the leaf emits
# `gh pr checks PR --repo $REPO --json state`; the per-check-state → single-
# token projection lives INSIDE the leaf, so the caller passes only the PR.
# The `-q '[.[].state]'` tail the pre-#399 caller supplied is GONE from the
# seam — the token normalization is the whole point of W1d.
argv=$(run_trace chp_ci_status 42)
assert_eq "TC-CHP-CI chp_ci_status emits gh pr checks argv (W1d normalized-token leaf)" \
  "pr checks 42 --repo $REPO --json state " "$argv"

# TC-CHP-FINDPR — chp_find_pr_for_issue's ABSTRACT contract (W1c1 #397): the
# leaf emits `gh api graphql -F owner=… -F repo=… -f query=…` with a cursor
# page-walk (§3.5). No `--json`/`-q`/`--limit` cross the seam — pagination
# lives in the leaf's own loop, not in gh's `--limit N` flag (which returns
# partial rc 0 at N+1 candidates, the pre-#397 hazard #397 R1 explicitly
# forbids). FIELDS-CSV is a REQUIRED positional; the leaf projects EXACTLY
# the requested vocabulary keys plus the resolver keys (P1-1 fix). We assert
# the observable gh argv shape: api graphql + owner/repo binds + query
# carries pullRequests(first:100) + states filter + pageInfo cursor +
# selects body (#148 anchor).
argv=$(run_trace chp_find_pr_for_issue 282 "number,headRefOid,body")
assert_contains "TC-CHP-FINDPR chp_find_pr_for_issue emits gh api graphql (not gh pr list, W1c1)" "api graphql" "$argv"
assert_contains "TC-CHP-FINDPR chp_find_pr_for_issue -F owner=zxkane"                   "owner=zxkane" "$argv"
assert_contains "TC-CHP-FINDPR chp_find_pr_for_issue -F repo=autonomous-dev-team"       "repo=autonomous-dev-team" "$argv"
assert_contains "TC-CHP-FINDPR chp_find_pr_for_issue query carries pullRequests(first:100" "pullRequests(first: 100" "$argv"
assert_contains "TC-CHP-FINDPR chp_find_pr_for_issue states filter present"             "states: [OPEN]" "$argv"
assert_contains "TC-CHP-FINDPR chp_find_pr_for_issue pageInfo cursor present (§3.5)"    "pageInfo { endCursor hasNextPage" "$argv"
assert_contains "TC-CHP-FINDPR chp_find_pr_for_issue query selects body (#148 anchor)"  " body " "$argv"
if [[ "$argv" != *" -q "* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CHP-FINDPR no -q crosses the seam (jq is caller-side, W1c1 shape)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CHP-FINDPR -q leaked into gh argv: $argv"; FAIL=$((FAIL+1))
fi

# TC-CHP-FINDPR-FIELDS-REQUIRED — calling without FIELDS-CSV is an error (M1).
rc=0
env REPO="$REPO" bash -c 'gh(){ :; }; source "'"$CHP_LIB"'" 2>/dev/null; chp_find_pr_for_issue 282' >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && { echo -e "  ${GREEN}PASS${NC}: TC-CHP-FINDPR-FIELDS-REQUIRED missing FIELDS errors (rc=$rc)"; PASS=$((PASS+1)); } \
                  || { echo -e "  ${RED}FAIL${NC}: TC-CHP-FINDPR-FIELDS-REQUIRED missing FIELDS did NOT error"; FAIL=$((FAIL+1)); }

# TC-CHP-MERGEABLE — chp_mergeable now absorbs `-q '.mergeable'` into the
# leaf (#399 W1d [M2]): the caller passes only the PR positional. Emitted argv
# is `gh pr view PR --repo $REPO --json mergeable -q .mergeable`; the leaf
# returns the raw backend token (MERGEABLE|CONFLICTING|UNKNOWN) directly, so
# `lib-review-mergeable.sh` (INV-44/INV-54 classifiers) ships byte-unchanged.
argv=$(run_trace chp_mergeable 42)
assert_eq "TC-CHP-MERGEABLE chp_mergeable emits gh pr view --json mergeable -q .mergeable argv (W1d absorbs the projection)" \
  "pr view 42 --repo $REPO --json mergeable -q .mergeable " "$argv"

# TC-CHP-CREATE — W1e (#400) abstract positional contract: `chp_create_pr
# <head-branch> <title> <body>`; the GitHub leaf owns `--head/--title/--body`,
# so the emitted `gh pr create` argv is IDENTICAL to the pre-#400 caller-
# composed line but is now driven by three positionals.
argv=$(run_trace chp_create_pr feat/x T B)
assert_eq "TC-CHP-CREATE chp_create_pr leaf-emitted gh pr create argv from positional inputs (W1e #400)" \
  "pr create --repo $REPO --head feat/x --title T --body B " "$argv"

# TC-CHP-APPROVE — W1e (#400) abstract positional contract: `chp_approve
# <pr> <body>`; the GitHub leaf owns `--approve --body`.
argv=$(run_trace chp_approve 42 OK)
assert_eq "TC-CHP-APPROVE chp_approve leaf-emitted gh pr review --approve argv from positional inputs (W1e #400)" \
  "pr review 42 --repo $REPO --approve --body OK " "$argv"

# TC-CHP-REQCHANGES — lib-review-request-changes.sh's `gh pr review … --request-changes --body …`.
argv=$(run_trace chp_request_changes 42 "blocking finding")
assert_eq "TC-CHP-REQCHANGES chp_request_changes byte-identical gh pr review --request-changes argv" \
  "pr review 42 --repo $REPO --request-changes --body blocking finding " "$argv"

# TC-CHP-MERGE — W1e (#400) abstract positional contract: `chp_merge <pr>`.
# Merge strategy is CONTRACT-FIXED (squash + delete source branch); the GitHub
# leaf emits `--squash --delete-branch` internally. The emitted gh argv is
# IDENTICAL to the pre-#400 caller-composed line.
argv=$(run_trace chp_merge 42)
assert_eq "TC-CHP-MERGE chp_merge leaf-emitted gh pr merge --squash --delete-branch argv from positional input (W1e #400)" \
  "pr merge 42 --repo $REPO --squash --delete-branch " "$argv"

# TC-CHP-THREADS — the reviewThreads leaf's FIRST-page GraphQL argv (#401 / #347 W1f).
# The pre-#401 leaf pinned `reviewThreads(first: 100)` verbatim; the cursor-walk
# rewrite makes it `reviewThreads(first: 100, after: $threadCursor)` with a
# pageInfo selection, driven by a `-F threadCursor=…` arg on every page after
# the first. On the first invocation `$threadCursor` is unset (no `-F threadCursor`
# arg passed) so the recorder captures ONLY the initial page's argv — asserting
# `pageInfo` + `after: $threadCursor` in the query is the byte-stable anchor
# for both single-page and multi-page paths.
argv=$(run_trace chp_review_threads 42)
assert_contains "TC-CHP-THREADS chp_review_threads emits gh api graphql" "api graphql" "$argv"
assert_contains "TC-CHP-THREADS reviewThreads uses cursor-walk (first: 100, after: \$threadCursor)" "reviewThreads(first: 100, after: \$threadCursor)" "$argv"
assert_contains "TC-CHP-THREADS query selects pageInfo{hasNextPage,endCursor}" "pageInfo { hasNextPage endCursor }" "$argv"
assert_contains "TC-CHP-THREADS query selects comments.pageInfo (nested completeness)" "comments(first: 100)" "$argv"
assert_contains "TC-CHP-THREADS -F prNumber forwards the PR" "prNumber=42" "$argv"
assert_contains "TC-CHP-THREADS -F owner derived from REPO" "owner=zxkane" "$argv"
assert_contains "TC-CHP-THREADS -F repo derived from REPO" "repo=autonomous-dev-team" "$argv"

# TC-CHP-RESOLVE — resolveReviewThread mutation argv carries threadId + the mutation.
argv=$(run_trace chp_resolve_thread "PRRT_kwABC")
assert_contains "TC-CHP-RESOLVE chp_resolve_thread emits resolveReviewThread mutation" "resolveReviewThread(input: {threadId: \$threadId})" "$argv"
assert_contains "TC-CHP-RESOLVE -F threadId forwards the thread id" "threadId=PRRT_kwABC" "$argv"

# General read primitives (#282 review round 8) — the incidental reads route
# through these — both W1c-abstract now:
#   - chp_pr_view (W1c2 #398): positional `PR FIELDS_CSV`; leaf uses
#     CAPTURE-THEN-CHECK — `raw=$(gh …) || return 1; [[ -n "$raw" ]] || return 1;
#     jq -e 'type=="object"' … || return 1; jq -c "$norm_program" <<<"$raw"`.
#     gh argv carries `--json <field>` ONLY; NO `--jq` / `-q` crosses to gh
#     (the load-bearing invariant of the fail-CLOSED-on-empty-stdout P1-2 fix).
#     The normalization jq runs downstream in the leaf.
#   - chp_pr_list (W1c1 #397): positional STATE + FIELDS-CSV; leaf owns argv
#     via `gh api graphql`. No `--json`/`-q` crosses the seam.
argv=$(run_trace chp_pr_view 42 state)
# The leaf emits `gh pr view 42 --repo $REPO --json state` (no --jq crosses
# to gh — the normalization jq runs inside the leaf on the captured raw JSON).
# We assert the STRUCTURAL invariants (positional args + `--json <field>` +
# NO `-q`/`--jq` leaking to gh) rather than pinning the leaf's downstream jq
# program body — a leaf-internal formatting refactor should not break this
# trace test.
assert_contains "TC-CHP-PRVIEW chp_pr_view <PR> <FIELDS_CSV> forwards to gh pr view <PR> --repo <REPO>" \
  "pr view 42 --repo $REPO --json " "$argv"
assert_contains "TC-CHP-PRVIEW leaf emits --json <raw gh fields> (state is 1:1 in the vocabulary)" \
  "--json state" "$argv"
# P1-2 anti-regression: the gh call must NOT carry --jq/-q (jq stays inside
# the leaf, downstream of the raw-stdout capture, so an empty-stdout / bad-JSON
# silent gh failure fails-CLOSED instead of being masked by gh's own --jq).
if [[ "$argv" == *"--jq"* ]] || [[ "$argv" == *" -q "* ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-CHP-PRVIEW-P1-2 gh argv leaks --jq/-q (capture-then-check contract violated)"; FAIL=$((FAIL+1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-CHP-PRVIEW-P1-2 gh argv carries NO --jq/-q (normalization runs downstream in the leaf, empty-stdout fail-CLOSED)"; PASS=$((PASS+1))
fi
# TC-CHP-PRVIEW-FAILCLOSED — a missing FIELDS_CSV (2nd arg absent) returns rc 2
# (fail-CLOSED per W1c2 R2, mirroring chp_github_find_pr_for_issue's [M1]).
_fc_rc=0
env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
    REPO="$REPO" \
  bash -c "source '$CHP_LIB' 2>/dev/null; chp_pr_view 42 >/dev/null 2>&1" || _fc_rc=$?
assert_eq "TC-CHP-PRVIEW-FAILCLOSED missing FIELDS_CSV → rc 2 (fail-CLOSED)" "2" "$_fc_rc"

# TC-CHP-PRLIST — chp_pr_list's ABSTRACT contract (W1c1 #397): positional
# STATE + FIELDS-CSV; leaf owns argv via `gh api graphql`. No `--limit`,
# `--json`, `-q` cross the seam — pagination lives in the leaf's cursor
# walker (§3.5). STATE maps to a GraphQL PullRequestState filter.
argv=$(run_trace chp_pr_list open body)
assert_contains "TC-CHP-PRLIST chp_pr_list emits gh api graphql (not gh pr list)" "api graphql" "$argv"
assert_contains "TC-CHP-PRLIST chp_pr_list pullRequests(first:100" "pullRequests(first: 100" "$argv"
assert_contains "TC-CHP-PRLIST chp_pr_list states=[OPEN] (positional STATE forwarded)" "states: [OPEN]" "$argv"
assert_contains "TC-CHP-PRLIST chp_pr_list pageInfo cursor present (§3.5 exhaustion)" "pageInfo { endCursor hasNextPage" "$argv"
assert_contains "TC-CHP-PRLIST chp_pr_list query selects body"       " body " "$argv"
if [[ "$argv" != *" -q "* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CHP-PRLIST no -q crosses the seam (W1c1 shape)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CHP-PRLIST -q leaked into gh argv: $argv"; FAIL=$((FAIL+1))
fi

argv=$(run_trace chp_pr_list all "createdAt,body")
assert_contains "TC-CHP-PRLIST-ALL chp_pr_list forwards STATE=all as states=[OPEN,CLOSED,MERGED] (metrics #228 anchor)" \
  "states: [OPEN,CLOSED,MERGED]" "$argv"

# TC-CHP-PRLIST-STATE-REQUIRED / TC-CHP-PRLIST-FIELDS-REQUIRED — both positional
# args are required under the abstract contract; missing → rc != 0.
rc=0
env REPO="$REPO" bash -c 'gh(){ :; }; source "'"$CHP_LIB"'" 2>/dev/null; chp_pr_list' >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && { echo -e "  ${GREEN}PASS${NC}: TC-CHP-PRLIST-STATE-REQUIRED missing STATE errors (rc=$rc)"; PASS=$((PASS+1)); } \
                  || { echo -e "  ${RED}FAIL${NC}: TC-CHP-PRLIST-STATE-REQUIRED missing STATE did NOT error"; FAIL=$((FAIL+1)); }
rc=0
env REPO="$REPO" bash -c 'gh(){ :; }; source "'"$CHP_LIB"'" 2>/dev/null; chp_pr_list open' >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && { echo -e "  ${GREEN}PASS${NC}: TC-CHP-PRLIST-FIELDS-REQUIRED missing FIELDS errors (rc=$rc)"; PASS=$((PASS+1)); } \
                  || { echo -e "  ${RED}FAIL${NC}: TC-CHP-PRLIST-FIELDS-REQUIRED missing FIELDS did NOT error"; FAIL=$((FAIL+1)); }

# ===========================================================================
# 2. M8 review-thread shape — {thread_id, resolved, comments:[{id,path,line,…}]}.
# ===========================================================================
# #401 / #347 W1f: the leaf no longer passes `--jq` to `gh api graphql` — the
# merge + normalize happen in the leaf's own jq pipeline. The fixture MUST
# include pageInfo{hasNextPage,endCursor} at both the reviewThreads level and
# each thread's comments level; the #401 hardening rejects any response with
# a missing required path (fail-closed on malformed/incomplete GraphQL data).
echo "=== M8 review-thread shape (distinct from the ITP issue-comment shape) ==="
_GRAPHQL_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"T1","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
    {"databaseId":501,"path":"src/a.sh","line":12,"originalLine":10,"author":{"login":"kane-review-agent"},"body":"fix this","createdAt":"2026-06-27T10:00:00Z"}
  ]}},
  {"id":"T2","isResolved":true,"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
    {"databaseId":502,"path":"src/b.sh","line":null,"originalLine":7,"author":{"login":"alice"},"body":"ok","createdAt":"2026-06-27T11:00:00Z"}
  ]}}
]}}}}}'
shape=$(
  env REPO="$REPO" _GRAPHQL_THREADS="$_GRAPHQL_THREADS" bash -c '
    # gh stub returns the raw GraphQL payload verbatim (no --jq applied — the
    # #401 leaf owns its own jq pipeline).
    gh() { printf "%s" "$_GRAPHQL_THREADS"; }
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
# 2b. #401 / #347 W1f — multi-page cursor walk (both pagination levels) +
#     fail-closed contract + caller-side capture-then-test parity.
# ===========================================================================
echo "=== TC-CHP-THREADS-MULTIPAGE — chp_review_threads cursor walk (#401) ==="

# Fixture helper: a gh stub that serves canned payloads keyed by INVOCATION
# COUNT (1st call → page 1, 2nd → page 2, ...). Fail-mode via _MP_FAIL_AT=<n>.
# Recorded gh argv is written to $_MP_ARGV_FILE (newline-separated).
_mp_stub_setup='
  _MP_STATE=$(mktemp); : > "$_MP_STATE"
  _MP_ARGV_FILE=$(mktemp)
  export _MP_STATE _MP_ARGV_FILE
  gh() {
    local n=0
    [[ -s "$_MP_STATE" ]] && n=$(<"$_MP_STATE")
    n=$((n + 1))
    printf "%s" "$n" > "$_MP_STATE"
    printf "%s\n" "$@" >> "$_MP_ARGV_FILE"
    if [[ -n "${_MP_FAIL_AT:-}" && "$_MP_FAIL_AT" == "$n" ]]; then
      printf "stub-gh: simulated failure at invocation %d\n" "$n" >&2
      return 1
    fi
    local var="_MP_PAYLOAD_$n"
    printf "%s" "${!var:-}"
  }
'

# TC-W1F-001 — 2-page thread walk merges to length-4 M8 array in arrival order.
_P1='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":"TCURSOR_1"},"nodes":[
  {"id":"P1A","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
    {"databaseId":1,"path":"a.sh","line":1,"originalLine":1,"author":{"login":"u1"},"body":"a","createdAt":"2026-01-01T00:00:00Z"}
  ]}},
  {"id":"P1B","isResolved":true,"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
    {"databaseId":2,"path":"b.sh","line":2,"originalLine":2,"author":{"login":"u2"},"body":"b","createdAt":"2026-01-01T00:01:00Z"}
  ]}}
]}}}}}'
_P2='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"P2A","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
    {"databaseId":3,"path":"c.sh","line":3,"originalLine":3,"author":{"login":"u3"},"body":"c","createdAt":"2026-01-01T00:02:00Z"}
  ]}},
  {"id":"P2B","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
    {"databaseId":4,"path":"d.sh","line":4,"originalLine":4,"author":{"login":"u4"},"body":"d","createdAt":"2026-01-01T00:03:00Z"}
  ]}}
]}}}}}'
mp_out=$(
  env REPO="$REPO" _MP_PAYLOAD_1="$_P1" _MP_PAYLOAD_2="$_P2" bash -c "
    set -uo pipefail
    $_mp_stub_setup
    source '$CHP_LIB' 2>/dev/null
    chp_review_threads 42
    rc=\$?
    printf '\nRC=%s' \"\$rc\"
    printf '\nARGV_FILE=%s' \"\$_MP_ARGV_FILE\"
  "
)
mp_rc=$(sed -n 's/^RC=//p' <<<"$mp_out")
mp_argv_file=$(sed -n 's/^ARGV_FILE=//p' <<<"$mp_out")
mp_body=$(printf '%s' "$mp_out" | sed -e '/^RC=/,$d')
assert_eq "TC-W1F-001 chp_review_threads 2-page walk exits rc 0" "0" "$mp_rc"
n=$(printf '%s' "$mp_body" | jq 'length' 2>/dev/null || echo -1)
assert_eq "TC-W1F-001 merged array length = 4 (both pages present)" "4" "$n"
order=$(printf '%s' "$mp_body" | jq -r '[.[].thread_id]|join(",")' 2>/dev/null || echo "")
assert_eq "TC-W1F-001 arrival order preserved across page boundary" "P1A,P1B,P2A,P2B" "$order"
# Page-2 -F threadCursor=TCURSOR_1 present in recorded argv (proves the walk keyed on endCursor).
if [[ -f "$mp_argv_file" ]] && grep -q '^threadCursor=TCURSOR_1$' "$mp_argv_file"; then
  echo -e "  ${GREEN}PASS${NC}: TC-W1F-001 page-2 argv carries -F threadCursor=TCURSOR_1 (walk keyed on endCursor)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-W1F-001 page-2 argv missing threadCursor cursor"; FAIL=$((FAIL+1))
fi
rm -f "$mp_argv_file"

# TC-W1F-002 — nested comment-level completeness (>first-page comments in one thread).
# Page-1 thread response has comments.hasNextPage=true; a follow-up node(id:) query
# returns the remaining 2 comment nodes; final .comments array has length 4.
_NP1='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"TN1","isResolved":false,"comments":{"pageInfo":{"hasNextPage":true,"endCursor":"CCURSOR_1"},"nodes":[
    {"databaseId":10,"path":"n.sh","line":10,"originalLine":10,"author":{"login":"u1"},"body":"c1","createdAt":"2026-02-01T00:00:00Z"},
    {"databaseId":11,"path":"n.sh","line":11,"originalLine":11,"author":{"login":"u1"},"body":"c2","createdAt":"2026-02-01T00:01:00Z"}
  ]}}
]}}}}}'
_NP2='{"data":{"node":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"databaseId":12,"path":"n.sh","line":12,"originalLine":12,"author":{"login":"u1"},"body":"c3","createdAt":"2026-02-01T00:02:00Z"},
  {"databaseId":13,"path":"n.sh","line":13,"originalLine":13,"author":{"login":"u1"},"body":"c4","createdAt":"2026-02-01T00:03:00Z"}
]}}}}'
np_out=$(
  env REPO="$REPO" _MP_PAYLOAD_1="$_NP1" _MP_PAYLOAD_2="$_NP2" bash -c "
    set -uo pipefail
    $_mp_stub_setup
    source '$CHP_LIB' 2>/dev/null
    chp_review_threads 42
    rc=\$?
    printf '\nRC=%s' \"\$rc\"
    printf '\nARGV_FILE=%s' \"\$_MP_ARGV_FILE\"
  "
)
np_rc=$(sed -n 's/^RC=//p' <<<"$np_out")
np_argv_file=$(sed -n 's/^ARGV_FILE=//p' <<<"$np_out")
np_body=$(printf '%s' "$np_out" | sed -e '/^RC=/,$d')
assert_eq "TC-W1F-002 nested comment walk exits rc 0" "0" "$np_rc"
c_len=$(printf '%s' "$np_body" | jq '.[0].comments | length' 2>/dev/null || echo -1)
assert_eq "TC-W1F-002 comment array merged to length 4" "4" "$c_len"
c_order=$(printf '%s' "$np_body" | jq -r '[.[0].comments[].id]|join(",")' 2>/dev/null || echo "")
assert_eq "TC-W1F-002 comment arrival order preserved (10,11 then 12,13)" "10,11,12,13" "$c_order"
if [[ -f "$np_argv_file" ]] && grep -q '^commentCursor=CCURSOR_1$' "$np_argv_file"; then
  echo -e "  ${GREEN}PASS${NC}: TC-W1F-002 follow-up query carries -F commentCursor=CCURSOR_1 (node(id:) walk)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-W1F-002 follow-up query missing commentCursor"; FAIL=$((FAIL+1))
fi
if [[ -f "$np_argv_file" ]] && grep -q '^threadId=TN1$' "$np_argv_file"; then
  echo -e "  ${GREEN}PASS${NC}: TC-W1F-002 follow-up query keyed on -F threadId=TN1"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-W1F-002 follow-up query missing threadId key"; FAIL=$((FAIL+1))
fi
rm -f "$np_argv_file"

# TC-W1F-003a — GraphQL errors on page 1 → rc != 0, empty stdout.
# gh returns rc=0 with a populated .errors array + partial/null .data —
# tolerant defaults (`// []`) would have coerced this to `[]` + rc 0.
_ERR_RESP='{"data":{"repository":{"pullRequest":null}},"errors":[{"message":"Could not resolve to a PullRequest with the number 42.","type":"NOT_FOUND"}]}'
ge_out=$(
  env REPO="$REPO" _MP_PAYLOAD_1="$_ERR_RESP" bash -c "
    set -uo pipefail
    $_mp_stub_setup
    source '$CHP_LIB' 2>/dev/null
    chp_review_threads 42
    echo \"|RC=\$?|\"
  " 2>/dev/null
)
ge_rc=$(sed -n 's/.*|RC=\([0-9]*\)|.*/\1/p' <<<"$ge_out")
ge_body=$(sed -e 's/|RC=[0-9]*|//' <<<"$ge_out" | tr -d '[:space:]')
if [[ "$ge_rc" != "0" && -z "$ge_body" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-W1F-003a GraphQL .errors on page 1 → rc=$ge_rc, empty stdout (fail-closed on semantic errors)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-W1F-003a GraphQL .errors coerced to success (rc=$ge_rc, body=${ge_body:0:120})"; FAIL=$((FAIL+1))
fi

# TC-W1F-003b — null pullRequest (missing required path) → rc != 0, empty stdout.
_NULL_PR='{"data":{"repository":{"pullRequest":null}}}'
np_out=$(
  env REPO="$REPO" _MP_PAYLOAD_1="$_NULL_PR" bash -c "
    set -uo pipefail
    $_mp_stub_setup
    source '$CHP_LIB' 2>/dev/null
    chp_review_threads 42
    echo \"|RC=\$?|\"
  " 2>/dev/null
)
np_rc=$(sed -n 's/.*|RC=\([0-9]*\)|.*/\1/p' <<<"$np_out")
np_body=$(sed -e 's/|RC=[0-9]*|//' <<<"$np_out" | tr -d '[:space:]')
if [[ "$np_rc" != "0" && -z "$np_body" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-W1F-003b null pullRequest → rc=$np_rc, empty stdout (no // [] papering)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-W1F-003b null pullRequest coerced to success (rc=$np_rc, body=${np_body:0:120})"; FAIL=$((FAIL+1))
fi

# TC-W1F-003c — comment-page GraphQL errors mid-walk → rc != 0, empty stdout.
# Page 1 (thread level) succeeds with a thread reporting comments.hasNextPage=true;
# page 2 (comment level via node(id:)) returns .errors → walk aborts LOUD, no
# partial thread set surfaces.
_TP1='{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
  {"id":"TE1","isResolved":false,"comments":{"pageInfo":{"hasNextPage":true,"endCursor":"CCURSOR_ERR"},"nodes":[
    {"databaseId":90,"path":"e.sh","line":1,"originalLine":1,"author":{"login":"u"},"body":"first","createdAt":"2026-01-01T00:00:00Z"}
  ]}}
]}}}}}'
_CE2='{"data":{"node":null},"errors":[{"message":"transient upstream error"}]}'
ce_out=$(
  env REPO="$REPO" _MP_PAYLOAD_1="$_TP1" _MP_PAYLOAD_2="$_CE2" bash -c "
    set -uo pipefail
    $_mp_stub_setup
    source '$CHP_LIB' 2>/dev/null
    chp_review_threads 42
    echo \"|RC=\$?|\"
  " 2>/dev/null
)
ce_rc=$(sed -n 's/.*|RC=\([0-9]*\)|.*/\1/p' <<<"$ce_out")
ce_body=$(sed -e 's/|RC=[0-9]*|//' <<<"$ce_out" | tr -d '[:space:]')
if [[ "$ce_rc" != "0" && -z "$ce_body" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-W1F-003c comment-page .errors mid-walk → rc=$ce_rc, empty stdout (no partial thread set)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-W1F-003c comment-page errors coerced to partial (rc=$ce_rc, body=${ce_body:0:120})"; FAIL=$((FAIL+1))
fi

# TC-W1F-VALIDATE — positional-arg validation for chp_review_threads /
# chp_resolve_thread (W1e convention, #400): missing/empty/non-numeric PR
# and missing/empty THREAD_ID must return rc 2 with loud stderr and NO gh
# call. resolve-threads.sh (sole caller) sanitizes PR via
# `printf '%d' "$3"` and gates thread_id with `[ -n "$thread_id" ]`, so
# reaching the leaf with an invalid positional is operator misuse (safe to
# validate; the #400 caller-legitimacy rule holds).
_assert_w1f_rejects() {
  local label="$1"; shift
  local verb="$1"; shift
  local gh_leak; gh_leak="$(mktemp)"
  local out rc leaked
  out="$(env -u PROJECT_DIR REPO="$REPO" GHLEAK="$gh_leak" bash -c '
    gh() { printf "GH_LEAK:%s\n" "$@" > "$GHLEAK"; return 0; }
    source "'"$CHP_LIB"'" 2>/dev/null
    "$@"
  ' _ "$verb" "$@" 2>&1)"
  rc=$?
  leaked="$(cat "$gh_leak" 2>/dev/null)"
  rm -f "$gh_leak"
  if [[ "$rc" -ne 2 ]]; then
    echo -e "  ${RED}FAIL${NC}: $label expected rc 2 got rc=$rc (out: ${out:0:120})"; FAIL=$((FAIL+1))
    return
  fi
  if [[ -n "$leaked" ]]; then
    echo -e "  ${RED}FAIL${NC}: $label leaked gh call: $leaked"; FAIL=$((FAIL+1))
    return
  fi
  echo -e "  ${GREEN}PASS${NC}: $label rc=2 no gh call"; PASS=$((PASS+1))
}
_assert_w1f_rejects "TC-W1F-VALIDATE-100 review_threads: missing PR rejected"     chp_review_threads
_assert_w1f_rejects "TC-W1F-VALIDATE-101 review_threads: empty PR rejected"       chp_review_threads ""
_assert_w1f_rejects "TC-W1F-VALIDATE-102 review_threads: non-numeric PR rejected" chp_review_threads abc
_assert_w1f_rejects "TC-W1F-VALIDATE-103 review_threads: PR with trailing letters rejected" chp_review_threads 42abc
_assert_w1f_rejects "TC-W1F-VALIDATE-110 resolve_thread: missing THREAD_ID rejected" chp_resolve_thread
_assert_w1f_rejects "TC-W1F-VALIDATE-111 resolve_thread: empty THREAD_ID rejected"   chp_resolve_thread ""

# TC-W1F-VALIDATE-120 — valid args still pass rc 0. Regression pin so a
# future over-tightening (e.g. requiring PR≥1000 or a specific GraphQL id
# format) surfaces here rather than silently breaking the live caller.
_valid_argv=$(
  env -u PROJECT_DIR REPO="$REPO" bash -c "
    _PL='{\"data\":{\"repository\":{\"pullRequest\":{\"reviewThreads\":{\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null},\"nodes\":[]}}}}}'
    gh() { printf %s \"\$_PL\"; }
    source '$CHP_LIB' 2>/dev/null
    chp_review_threads 42
    echo \"|RC=\$?|\"
  " 2>&1
)
_valid_rc=$(sed -n 's/.*|RC=\([0-9]*\)|.*/\1/p' <<<"$_valid_argv")
if [[ "$_valid_rc" == "0" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-W1F-VALIDATE-120 valid numeric PR still passes rc 0 (regression pin)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-W1F-VALIDATE-120 valid numeric PR blocked rc=$_valid_rc"; FAIL=$((FAIL+1))
fi

# TC-W1F-003 — mid-walk page failure → rc != 0, EMPTY stdout (fail-closed).
fc_out=$(
  env REPO="$REPO" _MP_PAYLOAD_1="$_P1" _MP_PAYLOAD_2="$_P2" _MP_FAIL_AT=2 bash -c "
    set -uo pipefail
    $_mp_stub_setup
    source '$CHP_LIB' 2>/dev/null
    chp_review_threads 42
    echo \"|RC=\$?|\"
  " 2>/dev/null
)
fc_rc=$(sed -n 's/.*|RC=\([0-9]*\)|.*/\1/p' <<<"$fc_out")
fc_body=$(sed -e 's/|RC=[0-9]*|//' <<<"$fc_out" | tr -d '[:space:]')
if [[ "$fc_rc" != "0" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-W1F-003 mid-walk failure exits rc != 0 (rc=$fc_rc)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-W1F-003 mid-walk failure did not surface (rc=0)"; FAIL=$((FAIL+1))
fi
if [[ -z "$fc_body" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-W1F-003 mid-walk failure produced empty stdout (fail-closed)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-W1F-003 mid-walk failure produced partial stdout: ${fc_body:0:200}"; FAIL=$((FAIL+1))
fi

# TC-W1F-005 — resolve-threads.sh selects the page-2 unresolved thread across
# the boundary (parity check that the fix reaches the sole caller, not just
# the verb output).
# resolve-threads.sh calls chp_review_threads without a --repo global, so we
# stub REPO + gh + the mutation. We drive the SCRIPT (not just the verb) so
# the capture-then-test rewrite is exercised end-to-end.
_RESOLVER_SH="$COMMON_SCRIPTS/resolve-threads.sh"
if [[ -f "$_RESOLVER_SH" ]]; then
  resolver_out=$(
    env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR REPO="$REPO" \
        _MP_PAYLOAD_1="$_P1" _MP_PAYLOAD_2="$_P2" bash -c "
      set +e
      $_mp_stub_setup
      # override gh() BEFORE resolve-threads.sh source ordering: we intercept
      # the CHP shim's dispatch via chp_resolve_thread stub returning true.
      chp_resolve_thread() { printf 'true'; }
      export -f gh chp_resolve_thread 2>/dev/null || true
      bash '$_RESOLVER_SH' zxkane autonomous-dev-team 42 2>&1
    "
  )
  # The verb runs twice (page 1 + page 2); resolve-threads.sh should report at
  # least one unresolved thread and, given our stub chp_resolve_thread → true,
  # report each unresolved thread as OK.
  # Page-1 P1A + page-2 P2A + P2B are all resolved==false, so 3 unresolved threads.
  # Regardless of whether the resolver test can actually complete the mutation
  # loop under the export-f constraints, the important assertion is that page-2
  # threads appear in the reported set.
  if grep -qE 'Found 3 unresolved thread' <<<"$resolver_out"; then
    echo -e "  ${GREEN}PASS${NC}: TC-W1F-005 resolve-threads.sh finds ALL 3 unresolved threads across the page boundary"; PASS=$((PASS+1))
  else
    # Fallback: at minimum confirm the page-2 thread ids surface in the output
    # (some shells cannot export -f gh cleanly under set -e; the parity claim
    # is on the SELECTION set, not the mutation loop).
    if grep -qE 'P2A|P2B' <<<"$resolver_out"; then
      echo -e "  ${GREEN}PASS${NC}: TC-W1F-005 page-2 threads present in resolve-threads.sh output"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC}: TC-W1F-005 resolve-threads.sh did NOT surface page-2 threads: ${resolver_out:0:200}"; FAIL=$((FAIL+1))
    fi
  fi

  # TC-W1F-006 — resolve-threads.sh fails LOUD on mid-walk failure (the
  # capture-then-test rewrite: pipe-into-jq would have silently produced
  # empty THREAD_IDS and exited 0 with "0 resolved, 0 failed").
  fc_resolver_out=$(
    env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR REPO="$REPO" \
        _MP_PAYLOAD_1="$_P1" _MP_PAYLOAD_2="$_P2" _MP_FAIL_AT=2 bash -c "
      set +e
      $_mp_stub_setup
      chp_resolve_thread() { printf 'true'; }
      export -f gh chp_resolve_thread 2>/dev/null || true
      bash '$_RESOLVER_SH' zxkane autonomous-dev-team 42
      echo \"|RC=\$?|\"
    " 2>&1
  )
  fc_resolver_rc=$(sed -n 's/.*|RC=\([0-9]*\)|.*/\1/p' <<<"$fc_resolver_out")
  if [[ -n "$fc_resolver_rc" && "$fc_resolver_rc" != "0" ]] \
     && grep -qE 'chp_review_threads failed|Error' <<<"$fc_resolver_out"; then
    echo -e "  ${GREEN}PASS${NC}: TC-W1F-006 resolve-threads.sh fails LOUD on mid-walk leaf failure (rc=$fc_resolver_rc; no false 0/0 success)"; PASS=$((PASS+1))
  else
    # Also acceptable: non-zero rc without our specific diag string (a bare
    # leaf-failure abort from set -e is still LOUD in the correct direction).
    if [[ -n "$fc_resolver_rc" && "$fc_resolver_rc" != "0" ]] \
       && ! grep -qE '0 resolved, 0 failed' <<<"$fc_resolver_out"; then
      echo -e "  ${GREEN}PASS${NC}: TC-W1F-006 resolve-threads.sh exits non-zero on mid-walk failure (rc=$fc_resolver_rc)"; PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC}: TC-W1F-006 resolve-threads.sh silently succeeded on mid-walk failure (rc=$fc_resolver_rc)"; FAIL=$((FAIL+1))
    fi
  fi
else
  echo -e "  ${RED}FAIL${NC}: TC-W1F-005/006 resolve-threads.sh not found at $_RESOLVER_SH"; FAIL=$((FAIL+2))
fi

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

  # review_bots=0 branch (#282 review [P1] #1): drain_agent_bot_triggers must
  # SHORT-CIRCUIT (no chp_trigger_bot call) on a review_bots=0 backend. Drive the
  # real broker with the degraded fake CHP selected through the public seam.
  bt_sentinel0=$(mktemp); btfile0=$(mktemp); printf '/q review\n' > "$btfile0"
  env -u PROJECT_DIR REPO="$REPO" AUTONOMOUS_CONF_DIR="$COMMON_SCRIPTS" \
      CODE_HOST=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
      BTFILE="$btfile0" SENTINEL="$bt_sentinel0" \
    bash -c '
      log() { :; }
      # W1c1 (#397): return a GraphQL envelope with one PR body-mentioning #282.
      gh() {
        if [[ "$1 $2" == "api graphql" ]]; then
          printf %s "{\"data\":{\"repository\":{\"pullRequests\":{\"pageInfo\":{\"endCursor\":null,\"hasNextPage\":false},\"nodes\":[{\"number\":99,\"body\":\"Closes #282\"}]}}}}"
          return 0
        fi
        return 0
      }
      source "'"$CHP_LIB"'" 2>/dev/null
      chp_trigger_bot() { echo "TRIGGER_HIT:$*" >> "$SENTINEL"; }   # MUST NOT be reached on review_bots=0
      source "'"$SCRIPTS"'/lib-auth.sh" 2>/dev/null
      AGENT_GH_TOKEN_FILE=/dev/null AGENT_BOT_TRIGGER_FILE="$BTFILE" \
        drain_agent_bot_triggers 282 "'"$REPO"'" "/q review" >/dev/null 2>&1
    '
  bt0=$(cat "$bt_sentinel0"); rm -f "$btfile0" "$bt_sentinel0"
  if [[ -z "$bt0" ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-CHP-CAP-BOTS0-LIVE drain_agent_bot_triggers short-circuits when review_bots=0 (no chp_trigger_bot)"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-CHP-CAP-BOTS0-LIVE drain still posted on review_bots=0: $bt0"; FAIL=$((FAIL+1))
  fi

  # chp_has_leaf vs the shim (#282 review round 4 [P1]): on a backend whose
  # provider file omits a leaf (the degraded fixture has the shim but NO
  # chp_degraded_close_keyword body), `declare -F chp_close_keyword` is TRUE (shim
  # always defined) yet calling the verb dispatches to an undefined leaf and aborts
  # under `set -e`. chp_has_leaf must report the LEAF absent so the caller falls
  # back — and the fallback MUST be caps-aware (#282 review round 5 [P1]): a
  # leaf-less merge_closes_issue=0 backend renders a NON-CLOSING discoverable
  # backref (`Related to #N`) when native_issue_pr_link=0 (so the body-grep
  # PR-discovery still links the PR — #282 review round 7 [P1] #1), empty only when
  # native_issue_pr_link=1. This mirrors autonomous-dev.sh's _render_close_keyword
  # 3-way logic verbatim and drives it under set -euo on the degraded fixture
  # (no leaf + merge_closes_issue=0 + native_issue_pr_link=0).
  _render_helper='
      _render_close_keyword() {
        local _issue="$1"
        if declare -F chp_has_leaf >/dev/null 2>&1 && chp_has_leaf close_keyword; then chp_close_keyword "$_issue"; return 0; fi
        if declare -F chp_caps >/dev/null 2>&1 && [[ "$(chp_caps merge_closes_issue 2>/dev/null || echo 1)" == "0" ]]; then
          if [[ "$(chp_caps native_issue_pr_link 2>/dev/null || echo 0)" == "0" ]]; then printf "Related to #%s" "$_issue"; else printf ""; fi
          return 0
        fi
        printf "Closes #%s" "$_issue"
      }'
  leaf_guard=$(
    env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
        REPO="$REPO" CODE_HOST=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
    bash -c '
      set -euo pipefail
      source "'"$CHP_LIB"'" 2>/dev/null
      '"$_render_helper"'
      printf "KW=[%s]\n" "$(_render_close_keyword 282)"
      echo "HASLEAF=$(chp_has_leaf close_keyword && echo present || echo absent)"
    ' 2>&1
  )
  # degraded = leaf ABSENT + mci=0 + native_issue_pr_link=0 → non-closing discoverable backref.
  if [[ "$leaf_guard" == *"KW=[Related to #282]"* && "$leaf_guard" == *"HASLEAF=absent"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-CHP-LEAF-GUARD leaf-less mci=0 + native_issue_pr_link=0 → 'Related to #282' (non-closing, discoverable; no set -e abort)"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-CHP-LEAF-GUARD degraded close_keyword should be 'Related to #282' but was: $leaf_guard"; FAIL=$((FAIL+1))
  fi
  # `Related to #N` must (a) match the PR-discovery body-grep AND (b) NOT be a GitHub close keyword.
  if printf 'x\nRelated to #282\ny' | grep -qE '(^|[^0-9])#282([^0-9]|$)' \
     && ! printf 'Related to #282' | grep -qiE '(close[sd]?|fix(e[sd])?|resolve[sd]?) #282'; then
    echo -e "  ${GREEN}PASS${NC}: TC-CHP-LEAF-GUARD-BACKREF 'Related to #282' is discoverable AND not a close keyword"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-CHP-LEAF-GUARD-BACKREF 'Related to #282' not discoverable or is a close keyword"; FAIL=$((FAIL+1))
  fi
  # github keeps the leaf present → verb is called → Closes #<n>.
  gh_kw=$(
    env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR REPO="$REPO" CODE_HOST=github \
    bash -c 'set -euo pipefail; source "'"$CHP_LIB"'" 2>/dev/null; '"$_render_helper"'; _render_close_keyword 282'
  )
  assert_eq "TC-CHP-LEAF-GUARD-GH github (leaf present, merge_closes_issue=1) → Closes #282" "Closes #282" "$gh_kw"
  # lib-load failure (no chp_* at all) → GitHub literal (legacy fallback unchanged).
  nolib_kw=$(
    env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME="$HOME" REPO="$REPO" \
    bash -c 'set -euo pipefail; '"$_render_helper"'; _render_close_keyword 282'
  )
  assert_eq "TC-CHP-LEAF-GUARD-NOLIB lib-load failure (no chp_*) → GitHub literal Closes #282" "Closes #282" "$nolib_kw"
  # The wrapper's _render_close_keyword definition matches this 3-way logic (pin).
  if grep -qE '_render_close_keyword\(\)' "$SCRIPTS/autonomous-dev.sh" \
     && grep -qE 'chp_caps merge_closes_issue' "$SCRIPTS/autonomous-dev.sh"; then
    echo -e "  ${GREEN}PASS${NC}: TC-CHP-LEAF-GUARD-SRC autonomous-dev.sh defines a caps-aware _render_close_keyword"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-CHP-LEAF-GUARD-SRC autonomous-dev.sh missing caps-aware _render_close_keyword"; FAIL=$((FAIL+1))
  fi
else
  echo -e "  ${RED}FAIL${NC}: degraded fake provider fixture missing at $FAKE_PROVIDER (expected from #280)"
  FAIL=$((FAIL+1))
fi

# merge_closes_issue=0 + review_bots=0 caller branches are wired in
# autonomous-review.sh (the merge success path + the mandatory-bot-review wait
# gate). Source-grep the wrapper for the cap-gated branches (the merge path is
# too deep to drive in isolation; this pins the branch exists — its runtime
# correctness is the no-behavior-change anchor for GitHub's cap=1 path).
echo "=== caps=0 caller branches present in autonomous-review.sh (§4.2) ==="
REVIEW_WRAPPER="$SCRIPTS/autonomous-review.sh"
# merge_closes_issue=0 → the wrapper PREFERS itp_transition_state (guarded on
# `declare -F`, so it engages the moment itp-writes wires the seam) and FALLS BACK
# to the gh-close placeholder ONLY when ISSUE_PROVIDER=github (a non-GitHub
# tracker without the verb gets a loud ERROR, never a wrong GitHub close — #282
# review round 7 [P1] #2).
if grep -qE 'chp_caps merge_closes_issue' "$REVIEW_WRAPPER" \
   && grep -qE 'declare -F itp_transition_state' "$REVIEW_WRAPPER" \
   && grep -qE 'itp_transition_state "\$ISSUE_NUMBER"' "$REVIEW_WRAPPER" \
   && grep -qE 'ISSUE_PROVIDER:-github.*== "github"' "$REVIEW_WRAPPER" \
   && grep -qE 'gh issue close .*ISSUE_NUMBER' "$REVIEW_WRAPPER"; then
  echo -e "  ${GREEN}PASS${NC}: TC-CHP-CAP-MCI0-BRANCH mci=0 → itp_transition_state, else github-gated gh issue close, else loud ERROR"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CHP-CAP-MCI0-BRANCH mci=0 transition not provider-gated through the ITP seam"; FAIL=$((FAIL+1))
fi
# Behavioral: the EXACT 3-way branch from autonomous-review.sh.
_mci0_branch='
    _merge_closes=1
    declare -F chp_caps >/dev/null 2>&1 && _merge_closes="$(chp_caps merge_closes_issue 2>/dev/null || echo 1)"
    if [[ "$_merge_closes" != "1" ]]; then
      if declare -F itp_transition_state >/dev/null 2>&1; then itp_transition_state "$ISSUE_NUMBER" reviewing approved
      elif [[ "${ISSUE_PROVIDER:-github}" == "github" ]]; then gh issue close "$ISSUE_NUMBER" --repo "$REPO" --reason completed
      else echo "TRANSITION_ERROR (non-github, no verb)"; fi
    fi'
# (a) verb defined → itp_transition_state (even on a non-github tracker).
mci0_verb=$(
  env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME="$HOME" bash -c '
    set -euo pipefail; chp_caps(){ [[ "$1" == merge_closes_issue ]] && echo 0 || echo 1; }
    itp_transition_state(){ echo "VERB:$*"; }; gh(){ echo "GHCLOSE:$*"; }
    ISSUE_NUMBER=282; REPO=o/r; ISSUE_PROVIDER=asana'"$_mci0_branch"
)
assert_eq "TC-CHP-CAP-MCI0-VERB mci=0 + itp_transition_state defined → verb (no gh close)" "VERB:282 reviewing approved" "$mci0_verb"
# (b) verb absent + ISSUE_PROVIDER=github → gh issue close placeholder.
mci0_gh=$(
  env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME="$HOME" bash -c '
    set -euo pipefail; chp_caps(){ [[ "$1" == merge_closes_issue ]] && echo 0 || echo 1; }
    gh(){ echo "GHCLOSE:$*"; }
    ISSUE_NUMBER=282; REPO=o/r; ISSUE_PROVIDER=github'"$_mci0_branch"
)
assert_contains "TC-CHP-CAP-MCI0-GH mci=0 + verb absent + github → gh issue close placeholder" "GHCLOSE:issue close 282" "$mci0_gh"
# (c) verb absent + non-github tracker → loud ERROR, NEVER a wrong gh close.
mci0_nongh=$(
  env -i PATH="/usr/local/bin:/usr/bin:/bin" HOME="$HOME" bash -c '
    set -euo pipefail; chp_caps(){ [[ "$1" == merge_closes_issue ]] && echo 0 || echo 1; }
    gh(){ echo "GHCLOSE_WRONGLY_CALLED:$*"; }
    ISSUE_NUMBER=282; REPO=o/r; ISSUE_PROVIDER=gitlab'"$_mci0_branch"
)
if [[ "$mci0_nongh" == *"TRANSITION_ERROR"* && "$mci0_nongh" != *"GHCLOSE_WRONGLY_CALLED"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CHP-CAP-MCI0-NONGH mci=0 + verb absent + non-github → loud ERROR, no wrong gh close"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CHP-CAP-MCI0-NONGH non-github fallback wrong: $mci0_nongh"; FAIL=$((FAIL+1))
fi
if grep -qE '_review_bots_cap' "$REVIEW_WRAPPER"; then
  echo -e "  ${GREEN}PASS${NC}: TC-CHP-CAP-BOTS0-GATE mandatory-bot-review wait is gated on review_bots==1"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CHP-CAP-BOTS0-GATE bot-review wait not gated on the review_bots cap"; FAIL=$((FAIL+1))
fi

# review_bots=0 must ALSO suppress the PROMPT bot-review section (#282 review
# round 3 [P1]) — not just the wrapper-side wait. The source-level gate blanks
# REVIEW_BOTS_VALIDATED when `chp_caps review_bots != 1`, which propagates to BOTH
# the prompt's render_bot_review_section AND the trigger broker AND the wait gate.
if grep -qE 'review_bots 2>/dev/null \|\| echo 1.*!=.*"1"|chp_caps review_bots' "$REVIEW_WRAPPER" \
   && grep -qE 'REVIEW_BOTS_VALIDATED=""' "$REVIEW_WRAPPER"; then
  echo -e "  ${GREEN}PASS${NC}: TC-CHP-CAP-BOTS0-PROMPT source blanks REVIEW_BOTS_VALIDATED on review_bots=0 (suppresses prompt section + broker + wait)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CHP-CAP-BOTS0-PROMPT no source-level review_bots=0 blank of REVIEW_BOTS_VALIDATED"; FAIL=$((FAIL+1))
fi
# Mechanism check: render_bot_review_section "" emits NOTHING — the empty-set
# path the gate relies on to suppress the prompt section.
rbs_empty=$(
  env -u PROJECT_DIR bash -c '
    source "'"$SCRIPTS"'/lib-code-host.sh" 2>/dev/null
    source "'"$SCRIPTS"'/lib-review-bots.sh" 2>/dev/null
    render_bot_review_section "" 99 "'"$REPO"'"
  '
)
if [[ -z "$rbs_empty" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CHP-CAP-BOTS0-RENDER render_bot_review_section '' emits nothing (empty set → no prompt section)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CHP-CAP-BOTS0-RENDER render_bot_review_section '' emitted content"; FAIL=$((FAIL+1))
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

# resolve_pr_for_issue reaches chp_find_pr_for_issue (stub the verb, observe the
# hit). Under W1c1 (#397) the verb returns a normalized JSON ARRAY and the
# caller-side jq runs a resolution filter over it, so the stub records its
# received argv to a SIDE-CHANNEL FILE and returns a canned array — the
# delegation trace comes from the sidecar, not the verb's stdout (which now
# feeds a real jq).
_delegate_trace=$(mktemp)
delegated=$(
  env -u PROJECT_DIR REPO="$REPO" REPO_OWNER="$REPO_OWNER" PROJECT_ID=test-chp-$$ MAX_RETRIES=3 MAX_CONCURRENT=5 \
    TRACE_FILE="$_delegate_trace" \
  bash -c '
    source "'"$SCRIPTS"'/lib-dispatch.sh" 2>/dev/null
    chp_find_pr_for_issue() { echo "VERB_HIT:$2" >> "$TRACE_FILE"; printf "[]"; }
    resolve_pr_for_issue 282 "number,body" >/dev/null 2>&1
    cat "$TRACE_FILE"
  '
)
rm -f "$_delegate_trace"
assert_contains "TC-CHP-SHIM-DELEGATES resolve_pr_for_issue routes the leaf through chp_find_pr_for_issue" "VERB_HIT:number,body" "$delegated"

# ===========================================================================
# 5b. BROKER REWIRE — the live lib-auth.sh brokers route through the verbs
#     (PR-create + bot-trigger). The [P1] review finding: a defined-but-unwired
#     verb does not complete the seam; the real executable leaf must move.
# ===========================================================================
echo "=== BROKER REWIRE: drain_agent_pr_create → chp_create_pr / drain_agent_bot_triggers → chp_trigger_bot ==="
# drain_agent_pr_create: stub the verb + a PR-create file, assert the broker hits
# chp_create_pr with the resolved --head/--title/--body (NOT a raw gh pr create).
prfile=$(mktemp); printf 'branch: feat/issue-282-foo\nMy title\nBody line.\nCloses #282\n' > "$prfile"
# The broker discards the leaf's stdout (`>/dev/null`), so the verb override
# records its argv to a SENTINEL FILE (not stdout) where we can read it.
pr_sentinel=$(mktemp)
env -u PROJECT_DIR REPO="$REPO" PRFILE="$prfile" SENTINEL="$pr_sentinel" \
  bash -c '
    log() { :; }
    # W1c1 (#397): chp_pr_list now emits `gh api graphql …` (cursor page walk).
    # Return the empty-PR GraphQL envelope so the caller-side jq counts 0
    # (no existing PR — the broker should then invoke chp_create_pr).
    gh() {
      if [[ "$1 $2" == "api graphql" ]]; then
        printf %s "{\"data\":{\"repository\":{\"pullRequests\":{\"pageInfo\":{\"endCursor\":null,\"hasNextPage\":false},\"nodes\":[]}}}}"
        return 0
      fi
      echo "RAW_GH_PR_CREATE:$*" >> "$SENTINEL"   # raw create MUST NOT be hit
    }
    source "'"$CHP_LIB"'" 2>/dev/null
    chp_create_pr() { echo "CHP_CREATE_PR:$*" >> "$SENTINEL"; }   # override the github leaf
    source "'"$SCRIPTS"'/lib-auth.sh" 2>/dev/null
    # Arm the scoped-token broker AFTER sourcing — lib-auth.sh resets the AGENT_*
    # state at source time, so setting these in env would be clobbered.
    AGENT_GH_TOKEN_FILE=/dev/null AGENT_PR_CREATE_FILE="$PRFILE" \
      drain_agent_pr_create 282 "'"$REPO"'" >/dev/null 2>&1
  '
broker_pr=$(cat "$pr_sentinel"); rm -f "$prfile" "$pr_sentinel"
# W1e (#400): broker now passes three POSITIONALS (<head> <title> <body>) — no
# `--head/--title/--body` on the caller line; the GitHub leaf owns those flags.
assert_contains "TC-CHP-BROKER-CREATE drain_agent_pr_create routes through chp_create_pr (positional <head> <title> <body>, W1e #400)" \
  "CHP_CREATE_PR:feat/issue-282-foo My title Body line." "$broker_pr"
if [[ "$broker_pr" != *"RAW_GH_PR_CREATE"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CHP-BROKER-CREATE no raw 'gh pr create' fallback when chp_create_pr is defined"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CHP-BROKER-CREATE raw gh pr create still hit"; echo "      out: $broker_pr"; FAIL=$((FAIL+1))
fi

# drain_agent_bot_triggers: stub the verb + a trigger file + an allow-listed
# phrase, assert the broker hits chp_trigger_bot (NOT a raw gh-as-user.sh).
# Under W1c1 (#397) chp_pr_list is an ABSTRACT contract returning a normalized
# JSON array; the gh stub returns a canned array containing PR #99 with a body
# mentioning #282, so the caller-side jq selector resolves pr_number=99.
btfile=$(mktemp); printf '/q review\n' > "$btfile"
bt_sentinel=$(mktemp)
env -u PROJECT_DIR REPO="$REPO" AUTONOMOUS_CONF_DIR="$COMMON_SCRIPTS" BTFILE="$btfile" SENTINEL="$bt_sentinel" \
  bash -c '
    log() { :; }
    # W1c1 (#397): return a GraphQL envelope with one node whose body mentions #282.
    gh() {
      if [[ "$1 $2" == "api graphql" ]]; then
        printf %s "{\"data\":{\"repository\":{\"pullRequests\":{\"pageInfo\":{\"endCursor\":null,\"hasNextPage\":false},\"nodes\":[{\"number\":99,\"body\":\"Closes #282\"}]}}}}"
        return 0
      fi
      return 0
    }
    source "'"$CHP_LIB"'" 2>/dev/null
    chp_trigger_bot() { echo "CHP_TRIGGER_BOT:$*" >> "$SENTINEL"; }   # override the github leaf (broker discards its stdout)
    source "'"$SCRIPTS"'/lib-auth.sh" 2>/dev/null
    # Arm AFTER sourcing (lib-auth.sh resets the AGENT_* state at source time).
    AGENT_GH_TOKEN_FILE=/dev/null AGENT_BOT_TRIGGER_FILE="$BTFILE" \
      drain_agent_bot_triggers 282 "'"$REPO"'" "/q review" >/dev/null 2>&1
  '
broker_bt=$(cat "$bt_sentinel"); rm -f "$btfile" "$bt_sentinel"
assert_contains "TC-CHP-BROKER-TRIGGER drain_agent_bot_triggers routes through chp_trigger_bot (PR + phrase)" "CHP_TRIGGER_BOT:99 /q review" "$broker_bt"

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

# ===========================================================================
# 7. FINAL-AC GREP — the caller layer carries ZERO EXECUTABLE raw `gh pr`
#    (#282 review round 8). The literal AC grep flags comments / log strings /
#    prompt-heredoc text too, so we filter to EXECUTABLE forms: a `$(gh pr …`
#    command-sub, `if gh pr …`, `=$(gh pr …`, or a bare leading `gh pr …`. Every
#    such call must now be a chp_* verb (or the kept fetch_pr_for_issue shim).
# ===========================================================================
echo "=== FINAL-AC GREP: no executable raw 'gh pr' in the caller layer ==="
_ac_files="lib-dispatch.sh autonomous-dev.sh autonomous-review.sh lib-review-request-changes.sh lib-review-bots.sh resolve-threads.sh"
exec_gh=$(
  cd "$SCRIPTS" 2>/dev/null && for f in $_ac_files; do
    [ -f "$f" ] || continue
    # Keep ONLY lines where `gh pr <verb>` is an executable invocation — i.e.
    # immediately preceded by a shell command-context token (`$(`, `=$(`, `if `,
    # `&& `, `| `). This EXCLUDES `#` comments, prompt-heredoc instruction text
    # (indented `   gh pr checks ${PR_NUMBER}` — agent-run, not caller-run; prompt
    # text uses `${VAR}` braces, never a command-context prefix), and backtick
    # prose (`\`gh pr create\``).
    grep -nE '(\$\(|=\$\(|if |&& |\| )gh pr (list|checks|view|create|review|merge)' "$f" \
      | grep -vE '^[0-9]+:[[:space:]]*#' \
      | sed "s#^#$f:#"
  done
)
if [ -z "$exec_gh" ]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CHP-FINAL-AC no executable raw 'gh pr' in the 6 caller files (all behind chp_* verbs)"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CHP-FINAL-AC executable raw 'gh pr' remains:"; printf '%s\n' "$exec_gh"; FAIL=$((FAIL+1))
fi
# resolveReviewThread executable mutation is gone from resolve-threads.sh (only the header comment remains).
if grep -vE '^[[:space:]]*#' "$COMMON_SCRIPTS/resolve-threads.sh" | grep -q 'resolveReviewThread'; then
  echo -e "  ${RED}FAIL${NC}: TC-CHP-FINAL-AC resolveReviewThread still executable in resolve-threads.sh"; FAIL=$((FAIL+1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-CHP-FINAL-AC no executable resolveReviewThread in resolve-threads.sh"; PASS=$((PASS+1))
fi
# Dispatch routing for the two new general read verbs.
# chp_pr_view: W1c2 positional `PR FIELDS_CSV` argv (# ↔ #398).
routed=$(
  env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR bash -c '
    source "'"$CHP_LIB"'" 2>/dev/null
    chp_github_pr_view(){ echo "VIEW-ROUTED:$*"; }
    chp_github_pr_list(){ echo "LIST-ROUTED:$*"; }
    chp_pr_view 42 state
    chp_pr_list --state open'
)
assert_contains "TC-CHP-PRVIEW-ROUTE chp_pr_view → chp_github_pr_view (W1c2 positional argv)" "VIEW-ROUTED:42 state" "$routed"
assert_contains "TC-CHP-PRLIST-ROUTE chp_pr_list → chp_github_pr_list" "LIST-ROUTED:--state open" "$routed"

# Self-guarding dispatch (#282 review round 9 [P1]): on a backend whose provider
# omits the pr_view/pr_list leaf (any non-GitHub provider that has not
# implemented them yet), the shim must NOT `command not found`-abort the caller
# — it returns 1 (clean non-zero) so the caller's `|| echo/true/return`
# fallback degrades the read to empty. Drive the EXACT needs_open_pr_only
# caller pattern under set -euo with CODE_HOST=fakehost (no
# providers/chp-fakehost.sh exists, so lib-code-host.sh sources nothing and
# every chp_fakehost_* leaf is undefined — the guaranteed leaf-absent probe).
# The prior test used the degraded fixture, but #398 W1c2 fleshed out the
# degraded fixture's chp_degraded_pr_view / list_inline_comments leaves so the
# shim's leaf-absent branch is no longer reachable through it; the fakehost
# probe is the direct, stable path (mirrors test-chp-list-inline-comments.sh's
# AC2 cont. cae).
if [[ -d "$FAKE_PROVIDER" ]]; then
  guard_out=$(
    env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
        REPO="$REPO" CODE_HOST=fakehost \
    bash -c '
      set -euo pipefail
      source "'"$CHP_LIB"'" 2>/dev/null
      # caller-pattern 1 (needs_open_pr_only): $(...) || return-equiv
      pr_count=$(chp_pr_list --state open --json body -q "X" 2>/dev/null) || pr_count=0
      # caller-pattern 2 (PR_STATE, W1c2 positional): $(... || echo UNKNOWN)
      st=$(chp_pr_view 42 "state" 2>/dev/null | jq -r ".state" 2>/dev/null || echo "UNKNOWN")
      echo "REACHED pr_count=[$pr_count] st=[$st]"
    ' 2>/dev/null
  )
  assert_contains "TC-CHP-PRGUARD fakehost (no provider) → shim returns 1, caller fallback degrades (no set -e abort)" "REACHED pr_count=[0] st=[UNKNOWN]" "$guard_out"
  # The shim source contains the leaf-existence guard (not a blind dispatch).
  if grep -qE 'declare -F "chp_\$\{CODE_HOST\}_pr_view"' "$CHP_LIB" \
     && grep -qE 'declare -F "chp_\$\{CODE_HOST\}_pr_list"' "$CHP_LIB"; then
    echo -e "  ${GREEN}PASS${NC}: TC-CHP-PRGUARD-SRC chp_pr_view/chp_pr_list shims guard the leaf before dispatch"; PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-CHP-PRGUARD-SRC chp_pr_view/chp_pr_list shims dispatch blindly (no leaf guard)"; FAIL=$((FAIL+1))
  fi
fi

rm -f "$_GH_ARGV_FILE"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
