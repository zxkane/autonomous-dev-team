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

# General read primitives (#282 review round 8) — the incidental reads route
# through these; byte-identical argv (the caller's --json/-q ride via "$@").
argv=$(run_trace chp_pr_view 42 --json state -q '.state')
assert_eq "TC-CHP-PRVIEW chp_pr_view byte-identical gh pr view argv" \
  "pr view 42 --repo $REPO --json state -q .state " "$argv"
argv=$(run_trace chp_pr_list --state open --json body -q '.[0]')
assert_eq "TC-CHP-PRLIST chp_pr_list byte-identical gh pr list argv (--state forwarded, no hardcode)" \
  "pr list --repo $REPO --state open --json body -q .[0] " "$argv"
argv=$(run_trace chp_pr_list --state all --json createdAt,body -q 'X')
assert_eq "TC-CHP-PRLIST-ALL chp_pr_list forwards --state all byte-identically (metrics #228 anchor)" \
  "pr list --repo $REPO --state all --json createdAt,body -q X " "$argv"

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

  # review_bots=0 branch (#282 review [P1] #1): drain_agent_bot_triggers must
  # SHORT-CIRCUIT (no chp_trigger_bot call) on a review_bots=0 backend. Drive the
  # real broker with the degraded fake CHP selected through the public seam.
  bt_sentinel0=$(mktemp); btfile0=$(mktemp); printf '/q review\n' > "$btfile0"
  env -u PROJECT_DIR REPO="$REPO" AUTONOMOUS_CONF_DIR="$COMMON_SCRIPTS" \
      CODE_HOST=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
      BTFILE="$btfile0" SENTINEL="$bt_sentinel0" \
    bash -c '
      log() { :; }
      gh() { [[ "$1 $2" == "pr list" ]] && { echo 99; return 0; }; return 0; }
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
    gh() { [[ "$1 $2" == "pr list" ]] && { echo 0; return 0; }; echo "RAW_GH_PR_CREATE:$*" >> "$SENTINEL"; }  # no existing PR; raw create MUST NOT be hit
    source "'"$CHP_LIB"'" 2>/dev/null
    chp_create_pr() { echo "CHP_CREATE_PR:$*" >> "$SENTINEL"; }   # override the github leaf
    source "'"$SCRIPTS"'/lib-auth.sh" 2>/dev/null
    # Arm the scoped-token broker AFTER sourcing — lib-auth.sh resets the AGENT_*
    # state at source time, so setting these in env would be clobbered.
    AGENT_GH_TOKEN_FILE=/dev/null AGENT_PR_CREATE_FILE="$PRFILE" \
      drain_agent_pr_create 282 "'"$REPO"'" >/dev/null 2>&1
  '
broker_pr=$(cat "$pr_sentinel"); rm -f "$prfile" "$pr_sentinel"
assert_contains "TC-CHP-BROKER-CREATE drain_agent_pr_create routes through chp_create_pr (--head/--title/--body)" "CHP_CREATE_PR:--head feat/issue-282-foo --title My title --body" "$broker_pr"
if [[ "$broker_pr" != *"RAW_GH_PR_CREATE"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CHP-BROKER-CREATE no raw 'gh pr create' fallback when chp_create_pr is defined"; PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CHP-BROKER-CREATE raw gh pr create still hit"; echo "      out: $broker_pr"; FAIL=$((FAIL+1))
fi

# drain_agent_bot_triggers: stub the verb + a trigger file + an allow-listed
# phrase, assert the broker hits chp_trigger_bot (NOT a raw gh-as-user.sh).
btfile=$(mktemp); printf '/q review\n' > "$btfile"
bt_sentinel=$(mktemp)
env -u PROJECT_DIR REPO="$REPO" AUTONOMOUS_CONF_DIR="$COMMON_SCRIPTS" BTFILE="$btfile" SENTINEL="$bt_sentinel" \
  bash -c '
    log() { :; }
    gh() { [[ "$1 $2" == "pr list" ]] && { echo 99; return 0; }; return 0; }  # PR #99 exists
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
routed=$(
  env -u CODE_HOST -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR bash -c '
    source "'"$CHP_LIB"'" 2>/dev/null
    chp_github_pr_view(){ echo "VIEW-ROUTED:$*"; }
    chp_github_pr_list(){ echo "LIST-ROUTED:$*"; }
    chp_pr_view 42 --json state
    chp_pr_list --state open'
)
assert_contains "TC-CHP-PRVIEW-ROUTE chp_pr_view → chp_github_pr_view" "VIEW-ROUTED:42 --json state" "$routed"
assert_contains "TC-CHP-PRLIST-ROUTE chp_pr_list → chp_github_pr_list" "LIST-ROUTED:--state open" "$routed"

# Self-guarding dispatch (#282 review round 9 [P1]): on a backend whose provider
# omits the pr_view/pr_list leaf (the degraded fixture; any future non-GitHub
# provider) the shim must NOT `command not found`-abort the caller — it returns 1
# (clean non-zero) so the caller's `|| echo/true/return` fallback degrades the
# read to empty. Drive the EXACT needs_open_pr_only caller pattern under set -euo
# with CODE_HOST=degraded (no chp_degraded_pr_* leaf).
if [[ -d "$FAKE_PROVIDER" ]]; then
  guard_out=$(
    env -u AUTONOMOUS_CONF -u AUTONOMOUS_CONF_DIR -u PROJECT_DIR \
        REPO="$REPO" CODE_HOST=degraded AUTONOMOUS_PROVIDERS_DIR="$FAKE_PROVIDER" \
    bash -c '
      set -euo pipefail
      source "'"$CHP_LIB"'" 2>/dev/null
      # caller-pattern 1 (needs_open_pr_only): $(...) || return-equiv
      pr_count=$(chp_pr_list --state open --json body -q "X" 2>/dev/null) || pr_count=0
      # caller-pattern 2 (PR_STATE): $(... || echo UNKNOWN)
      st=$(chp_pr_view 42 --json state -q ".state" 2>/dev/null || echo "UNKNOWN")
      echo "REACHED pr_count=[$pr_count] st=[$st]"
    ' 2>/dev/null
  )
  assert_contains "TC-CHP-PRGUARD degraded (no leaf) → shim returns 1, caller fallback degrades (no set -e abort)" "REACHED pr_count=[0] st=[UNKNOWN]" "$guard_out"
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
