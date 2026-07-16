#!/bin/bash
# test-handle-completed-session-routing.sh — INV-35 / issue #149.
#
# Unit tests for lib-dispatch.sh::handle_completed_session_routing — the
# extracted Step 4b.5.1 routing logic. Exercises every row of the routing
# table in docs/designs/inv35-review-aware-resume.md § 3.
#
# Test IDs map to docs/test-cases/inv35-review-aware-resume.md § B–G.
#
# Run: bash tests/unit/test-handle-completed-session-routing.sh

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
export PROJECT_ID="test-inv35-routing-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# Routing-side mocks.
_MOCK_VERDICT="none"
_MOCK_CAUSE=""
_MOCK_DEV_ACTIONABLE="true"   # INV-92 (#298): the dev-actionable 5th out-param
_MOCK_FLIP_COUNT=0
_MOCK_NOTICE_PRESENT="0"
_MOCK_LAST_COMMENT_BODY=""
_MOCK_FULL_COMMENT_LOG=""
_MOCK_COMMENT_COUNT=0
_MOCK_LABEL_SWAPS=""
_MOCK_DISPATCH_CALLS=""
_MOCK_POST_TOKEN_CALLS=""
_MOCK_TRUNCATE_FAIL=0
_MOCK_LOG_FILE=""
_MOCK_MARK_STALLED_CALLS=""
_MOCK_REVIEW_RETRY_LIMIT="${REVIEW_RETRY_LIMIT:-2}"

log() { :; }

classify_recent_review_verdict() {
  local _issue="$1" _ts="$2" _v="$3" _c="$4" _da="${5:-}"
  printf -v "$_v" '%s' "$_MOCK_VERDICT"
  printf -v "$_c" '%s' "$_MOCK_CAUSE"
  # INV-92 (#298): when the handler passes a 5th out-param, set it from the mock
  # (default "true"). Guarded like the real helper so a 4-arg call is a no-op.
  [ -n "$_da" ] && printf -v "$_da" '%s' "${_MOCK_DEV_ACTIONABLE:-true}"
  return 0
}

count_review_aware_flips() {
  printf '%s' "$_MOCK_FLIP_COUNT"
}

label_swap() {
  local issue_num="$1" remove="$2" add="$3"
  _MOCK_LABEL_SWAPS+="${issue_num}:${remove}:${add} "
}

mark_stalled() {
  _MOCK_MARK_STALLED_CALLS+="${1} "
}

post_dispatch_token() {
  _MOCK_POST_TOKEN_CALLS+="${1}:${2} "
}

dispatch() {
  _MOCK_DISPATCH_CALLS+="${1}:${2} "
}

# [INV-108] (#361): handle_completed_session_routing's own INV-35 fresh-dev
# branch now gates on acquire_dispatch_marker before dispatching; this suite
# exercises the routing decision itself, not controller-side dedup, so always
# acquire.
acquire_dispatch_marker() { return 0; }

gh() {
  local cmd="${1:-}"
  local sub="${2:-}"
  if [[ "$cmd" == "issue" && "$sub" == "comment" ]]; then
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--body" ]]; then
        _MOCK_LAST_COMMENT_BODY="$2"
        _MOCK_FULL_COMMENT_LOG+="$2"$'\n'
        _MOCK_COMMENT_COUNT=$((_MOCK_COMMENT_COUNT + 1))
        return 0
      fi
      shift
    done
    return 0
  fi
  if [[ "$cmd" == "issue" && "$sub" == "view" ]]; then
    printf '%s\n' "$_MOCK_NOTICE_PRESENT"
    return 0
  fi
  return 0
}

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

# Re-define mocks AFTER sourcing.
log() { :; }
classify_recent_review_verdict() {
  local _issue="$1" _ts="$2" _v="$3" _c="$4" _da="${5:-}"
  printf -v "$_v" '%s' "$_MOCK_VERDICT"
  printf -v "$_c" '%s' "$_MOCK_CAUSE"
  # INV-92 (#298): when the handler passes a 5th out-param, set it from the mock
  # (default "true"). Guarded like the real helper so a 4-arg call is a no-op.
  [ -n "$_da" ] && printf -v "$_da" '%s' "${_MOCK_DEV_ACTIONABLE:-true}"
  return 0
}
count_review_aware_flips() {
  printf '%s' "$_MOCK_FLIP_COUNT"
}
label_swap() {
  local issue_num="$1" remove="$2" add="$3"
  _MOCK_LABEL_SWAPS+="${issue_num}:${remove}:${add} "
}
mark_stalled() {
  _MOCK_MARK_STALLED_CALLS+="${1} "
}
post_dispatch_token() {
  _MOCK_POST_TOKEN_CALLS+="${1}:${2} "
}
dispatch() {
  _MOCK_DISPATCH_CALLS+="${1}:${2} "
}

# [INV-108] (#361): handle_completed_session_routing's own INV-35 fresh-dev
# branch now gates on acquire_dispatch_marker before dispatching; this suite
# exercises the routing decision itself, not controller-side dedup, so always
# acquire.
acquire_dispatch_marker() { return 0; }
gh() {
  local cmd="${1:-}"
  local sub="${2:-}"
  if [[ "$cmd" == "issue" && "$sub" == "comment" ]]; then
    local _body=""
    local _i
    for ((_i = 1; _i <= $#; _i++)); do
      if [[ "${!_i}" == "--body" ]]; then
        local _bi=$((_i + 1)); _body="${!_bi}"; break
      fi
    done
    # #274 INV-85 finding 2: simulate a GitHub rejection of the attempt-marker
    # write so the retry + loud-operator-notice path can be exercised. Counts
    # the rejected attempts (the production code retries once).
    if [[ "$_MOCK_ATTEMPT_WRITE_FAILS" == "1" && "$_body" == *"no-progress-substantive-attempt:"* ]]; then
      _MOCK_ATTEMPT_WRITE_TRIES=$((_MOCK_ATTEMPT_WRITE_TRIES + 1))
      return 1
    fi
    _MOCK_LAST_COMMENT_BODY="$_body"
    _MOCK_FULL_COMMENT_LOG+="$_body"$'\n'
    _MOCK_COMMENT_COUNT=$((_MOCK_COMMENT_COUNT + 1))
    return 0
  fi
  if [[ "$cmd" == "issue" && "$sub" == "view" ]]; then
    # #274 INV-85: distinguish marker-presence queries. The no-progress guard
    # asks `select(contains("no-progress-substantive..."))` for two distinct
    # markers; route those to per-marker presence maps so idempotency and
    # attempt-marker logic can be asserted independently of the INV-35
    # fresh-dev notice (which keeps the legacy _MOCK_NOTICE_PRESENT default).
    local _args="$*"
    if [[ "$_args" == *"no-progress-substantive-attempt:"* ]]; then
      printf '%s\n' "$_MOCK_NOPROG_ATTEMPT_PRESENT"
      return 0
    fi
    if [[ "$_args" == *"no-progress-substantive:"* ]]; then
      printf '%s\n' "$_MOCK_NOPROG_NOTICE_PRESENT"
      return 0
    fi
    printf '%s\n' "$_MOCK_NOTICE_PRESENT"
    return 0
  fi
  return 0
}

# #274 INV-85 routing-side mocks (overridable per test).
_MOCK_PR_HEAD=""
_MOCK_LAST_REVIEWED_HEAD=""
_MOCK_BOT_UNFIXABLE=1            # 1 = not unfixable (default); 0 = unfixable
_MOCK_NOPROG_ATTEMPT_PRESENT="0"
_MOCK_NOPROG_NOTICE_PRESENT="0"
_MOCK_NONACT_NOTICE_PRESENT="0"  # INV-92 (#298) Branch B′ notice already posted?
_MOCK_ATTEMPT_WRITE_FAILS="0"    # 1 = reject attempt-marker writes (finding 2)
_MOCK_ATTEMPT_WRITE_TRIES=0
_MOCK_MATCHED_PATTERNS_MARKER=""  # INV-136 (#488) D4: when non-empty, itp_list_comments
                                   # emits a comment carrying `<!-- inv92-matched-patterns: … -->`
_MOCK_MATCHED_PATTERNS_HEAD=""    # (codex review round-2, PR #498) head= field the synthesized
                                   # marker carries; defaults to _MOCK_PR_HEAD (the SAME head as
                                   # the reviewed PR) — set to a DIFFERENT sha to simulate a STALE
                                   # marker left over from an earlier, unrelated round.

fetch_pr_for_issue() {
  # [INV-123] (#461): a nonzero return simulates a resolve_pr_for_issue
  # transport/read failure — must be treated the SAME as "PR exists" by the
  # caller (fail closed), never as "no PR".
  [ "${_MOCK_PR_LOOKUP_FAILS:-0}" = "1" ] && return 1
  # Emits the same single-line JSON shape the real helper does, or empty.
  [ -n "$_MOCK_PR_HEAD" ] || { printf '%s' ""; return 0; }
  printf '{"number":777,"headRefOid":"%s"}\n' "$_MOCK_PR_HEAD"
}
last_reviewed_head() {
  printf '%s' "$_MOCK_LAST_REVIEWED_HEAD"
}
dev_report_bot_unfixable() {
  return "$_MOCK_BOT_UNFIXABLE"
}

# #281: handle_completed_session_routing's marker-presence idempotency checks
# now fetch via `itp_list_comments | jq '[.[].body|select(contains(M))]|length'`
# instead of routing the marker through the `gh issue view` argv. Override the
# READ verb directly (the seam this issue introduces) and synthesize a
# normalized array whose bodies carry exactly the markers the per-flag mocks
# declare "present". The head-scoped no-progress markers use _MOCK_PR_HEAD; the
# INV-12/INV-35 fresh-dev notices key on the legacy _MOCK_NOTICE_PRESENT flag
# (any session id → emit a body containing both literals when present).
itp_list_comments() {
  local _bodies=()
  if [[ "${_MOCK_NOPROG_ATTEMPT_PRESENT:-0}" != "0" ]]; then
    _bodies+=("<!-- no-progress-substantive-attempt:${_MOCK_PR_HEAD} -->")
  fi
  if [[ "${_MOCK_NOPROG_NOTICE_PRESENT:-0}" != "0" ]]; then
    _bodies+=("no-progress-substantive:${_MOCK_PR_HEAD} notice")
  fi
  # INV-92 (#298) Branch B′ idempotency: the non-actionable-finding notice keys on
  # `non-actionable-finding:<head>` (head defaults to `none` when no PR resolved).
  if [[ "${_MOCK_NONACT_NOTICE_PRESENT:-0}" != "0" ]]; then
    _bodies+=("non-actionable-finding:${_MOCK_PR_HEAD:-none} prior notice")
  fi
  # INV-136 (#488) D4: when the test declares a matched-patterns marker, emit a
  # review-wrapper-style comment carrying it so `_inv92_matched_patterns` (the
  # dispatcher-side reader) has something to find. (codex review round-2, PR
  # #498): the marker is head-bound — defaults to `_MOCK_PR_HEAD` (the same
  # head under review) unless the test overrides `_MOCK_MATCHED_PATTERNS_HEAD`
  # to simulate a stale marker from a different round.
  if [[ -n "${_MOCK_MATCHED_PATTERNS_MARKER:-}" ]]; then
    local _mp_head="${_MOCK_MATCHED_PATTERNS_HEAD:-${_MOCK_PR_HEAD:-unknown}}"
    _bodies+=("Non-actionable findings comment.
<!-- inv92-matched-patterns: head=${_mp_head} ${_MOCK_MATCHED_PATTERNS_MARKER} -->")
  fi
  if [[ "${_MOCK_NOTICE_PRESENT:-0}" != "0" ]]; then
    # The fresh-dev/INV-12 notices are session-scoped — the branch searches for
    # `contains("INV-12-completed:<sid>")` / `INV-35-fresh-dev:<sid>`. Emit a
    # body carrying both literals for the session id the idempotency test
    # declares via _MOCK_NOTICE_SESSION (defaults to a sentinel that matches
    # nothing, so a stray _MOCK_NOTICE_PRESENT=1 without a session never
    # accidentally suppresses).
    local _sid="${_MOCK_NOTICE_SESSION:-__no_session__}"
    _bodies+=("INV-12-completed:${_sid} INV-35-fresh-dev:${_sid} INV-12-no-pr-fresh-dev:${_sid} prior notice")
  fi
  local _json="[]" _ts=0 b
  for b in "${_bodies[@]}"; do
    _json=$(jq -c --arg b "$b" --argjson t "$_ts" \
      '. + [{id:(100+$t), author:"my-claw", authorKind:"self", body:$b, createdAt:"2026-06-12T00:00:0\($t)Z"}]' <<<"$_json")
    _ts=$((_ts + 1))
  done
  printf '%s' "$_json"
}

reset_mocks() {
  _MOCK_VERDICT="none"
  _MOCK_CAUSE=""
  _MOCK_DEV_ACTIONABLE="true"
  _MOCK_FLIP_COUNT=0
  _MOCK_NOTICE_PRESENT="0"
  _MOCK_LAST_COMMENT_BODY=""
  _MOCK_FULL_COMMENT_LOG=""
  _MOCK_COMMENT_COUNT=0
  _MOCK_LABEL_SWAPS=""
  _MOCK_DISPATCH_CALLS=""
  _MOCK_POST_TOKEN_CALLS=""
  _MOCK_TRUNCATE_FAIL=0
  _MOCK_MARK_STALLED_CALLS=""
  _MOCK_PR_HEAD=""
  _MOCK_LAST_REVIEWED_HEAD=""
  _MOCK_BOT_UNFIXABLE=1
  _MOCK_NOPROG_ATTEMPT_PRESENT="0"
  _MOCK_NOPROG_NOTICE_PRESENT="0"
  _MOCK_NONACT_NOTICE_PRESENT="0"
  _MOCK_ATTEMPT_WRITE_FAILS="0"
  _MOCK_ATTEMPT_WRITE_TRIES=0
  _MOCK_MATCHED_PATTERNS_MARKER=""
  _MOCK_MATCHED_PATTERNS_HEAD=""
  _MOCK_NOTICE_SESSION=""   # #281: session id the synthesized INV-12/INV-35 marker carries
  _MOCK_PR_LOOKUP_FAILS="0" # [INV-123] (#461): simulate fetch_pr_for_issue transport failure
  unset REVIEW_RETRY_LIMIT
  if [[ -n "$_MOCK_LOG_FILE" ]]; then
    chmod u+w "$_MOCK_LOG_FILE" 2>/dev/null || true
    rm -f "$_MOCK_LOG_FILE"
  fi
  _MOCK_LOG_FILE=""
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle=[$needle]"
    echo "      haystack=[$haystack]"
    FAIL=$((FAIL + 1))
  fi
}

assert_returns() {
  local desc="$1" expected_rc="$2"; shift 2
  "$@"
  local actual_rc=$?
  if [[ "$expected_rc" == "$actual_rc" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc rc=$actual_rc (expected $expected_rc)"
    FAIL=$((FAIL + 1))
  fi
}

prepare_log() {
  _MOCK_LOG_FILE="/tmp/agent-${PROJECT_ID}-issue-${1}.log"
  printf 'something\n' > "$_MOCK_LOG_FILE"
}
prepare_readonly_log() {
  prepare_log "$1"
  chmod 444 "$_MOCK_LOG_FILE"
}

# ---------------------------------------------------------------------------
echo "=== INV-85 source-pin: fetch_pr_for_issue call includes body (#274 [P1]) ==="
# ---------------------------------------------------------------------------
# The INV-85 call MUST keep `body` in its --json field list. Originally (#274
# review [P1] round-4 finding 1) this was because fetch_pr_for_issue filtered on
# `.body`; under [INV-86] (#277) it now binds by `closingIssuesReferences`, so
# `body` is no longer load-bearing for resolution — but the literal field list
# is pinned here for call-site stability (the routing tests MOCK
# fetch_pr_for_issue, so only this source grep catches a drifted field list).
if grep -Eq 'fetch_pr_for_issue "\$issue_num" "number,headRefOid,body"' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: INV-85 fetch_pr_for_issue call requests body"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: INV-85 fetch_pr_for_issue call is missing the body field (guards will no-op in production)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo "=== handle_completed_session_routing (INV-35) ==="
# ---------------------------------------------------------------------------

# TC-INV35-RT-001: completed + no verdict + PR EXISTS → INV-12 operator notice
# ([INV-123], #461: a PR-exists `none` still fails closed to the unchanged
# operator handoff — a review SHOULD have run against this PR and something
# prevented it).
reset_mocks
_MOCK_VERDICT="none"
_MOCK_PR_HEAD="deadbeef"
assert_returns "RT-001 returns 0 (handled, INV-12 fallthrough emit)" 0 \
  handle_completed_session_routing 100 "sid-001" "2026-05-21T03:18:00Z"
assert_eq "RT-001 emits one notice comment" "1" "$_MOCK_COMMENT_COUNT"
assert_contains "RT-001 marker is INV-12-completed" "INV-12-completed:sid-001" "$_MOCK_LAST_COMMENT_BODY"
assert_eq "RT-001 no label swap" "" "$_MOCK_LABEL_SWAPS"
assert_eq "RT-001 no dispatch" "" "$_MOCK_DISPATCH_CALLS"

# RT-001 idempotency: notice already present → no second post
reset_mocks
_MOCK_VERDICT="none"
_MOCK_PR_HEAD="deadbeef"
_MOCK_NOTICE_PRESENT="1"
_MOCK_NOTICE_SESSION="sid-001"   # #281: existing INV-12 marker carries this session id
assert_returns "RT-001-idem returns 0 even when marker present" 0 \
  handle_completed_session_routing 100 "sid-001" "2026-05-21T03:18:00Z"
assert_eq "RT-001-idem suppresses duplicate" "0" "$_MOCK_COMMENT_COUNT"

# ---------------------------------------------------------------------------
echo ""
echo "=== [INV-123] (#456/#461): completed + verdict=none + NO PR → bounded fresh dev-new ==="
# ---------------------------------------------------------------------------

# TC-461-RT-001: verdict=none, NO PR (default _MOCK_PR_HEAD="") → mirrors
# Branch C's dispatch mechanics exactly, distinct marker text, no per-HEAD
# attempt marker.
reset_mocks
_MOCK_VERDICT="none"
prepare_log 100
assert_returns "TC-461-RT-001 returns 0" 0 \
  handle_completed_session_routing 100 "sid-461-001" "2026-05-21T03:18:00Z"
assert_contains "TC-461-RT-001 INV-12-no-pr-fresh-dev marker comment" "INV-12-no-pr-fresh-dev:sid-461-001" "$_MOCK_LAST_COMMENT_BODY"
assert_eq "TC-461-RT-001 label swap pending-dev → in-progress" "100:pending-dev:in-progress " "$_MOCK_LABEL_SWAPS"
assert_eq "TC-461-RT-001 dispatch token = dev-new" "100:dev-new " "$_MOCK_POST_TOKEN_CALLS"
assert_eq "TC-461-RT-001 dispatch dev-new fired" "dev-new:100 " "$_MOCK_DISPATCH_CALLS"
log_size=$(stat -c '%s' "$_MOCK_LOG_FILE")
assert_eq "TC-461-RT-001 log truncated to 0 bytes" "0" "$log_size"
assert_eq "TC-461-RT-001 NO INV-12-completed notice" "" "$(grep -o 'INV-12-completed' <<<"$_MOCK_FULL_COMMENT_LOG")"
if [[ "$_MOCK_FULL_COMMENT_LOG" != *"no-progress-substantive-attempt:"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-461-RT-001 NO per-HEAD attempt marker (unlike Branch C — there is no HEAD)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-461-RT-001 unexpectedly posted a per-HEAD attempt marker"
  FAIL=$((FAIL + 1))
fi

# TC-461-RT-002: idempotency — marker already present, same session id → still
# dispatches (mechanics unchanged), no duplicate notice.
reset_mocks
_MOCK_VERDICT="none"
_MOCK_NOTICE_PRESENT="1"
_MOCK_NOTICE_SESSION="sid-461-001"
prepare_log 100
assert_returns "TC-461-RT-002 returns 0" 0 \
  handle_completed_session_routing 100 "sid-461-001" "2026-05-21T03:18:00Z"
assert_eq "TC-461-RT-002 no duplicate notice" "0" "$_MOCK_COMMENT_COUNT"
assert_eq "TC-461-RT-002 dispatch dev-new still fired" "dev-new:100 " "$_MOCK_DISPATCH_CALLS"

# TC-461-RT-003: truncate-fail → fail-closed, no dispatch.
reset_mocks
_MOCK_VERDICT="none"
prepare_readonly_log 100
assert_returns "TC-461-RT-003 returns 0 (handled, fail-closed)" 0 \
  handle_completed_session_routing 100 "sid-461-003" "2026-05-21T03:18:00Z"
assert_contains "TC-461-RT-003 operator-actionable comment posted" "permission" "$_MOCK_LAST_COMMENT_BODY"
assert_eq "TC-461-RT-003 NO label swap" "" "$_MOCK_LABEL_SWAPS"
assert_eq "TC-461-RT-003 NO dispatch" "" "$_MOCK_DISPATCH_CALLS"

# TC-461-RT-004: fetch_pr_for_issue transport failure (nonzero rc) → fails
# CLOSED to the PR-exists operator handoff, never the no-PR branch.
reset_mocks
_MOCK_VERDICT="none"
_MOCK_PR_LOOKUP_FAILS="1"
assert_returns "TC-461-RT-004 returns 0" 0 \
  handle_completed_session_routing 100 "sid-461-004" "2026-05-21T03:18:00Z"
assert_contains "TC-461-RT-004 fails closed to INV-12-completed handoff" "INV-12-completed:sid-461-004" "$_MOCK_LAST_COMMENT_BODY"
assert_eq "TC-461-RT-004 NO label swap" "" "$_MOCK_LABEL_SWAPS"
assert_eq "TC-461-RT-004 NO dispatch" "" "$_MOCK_DISPATCH_CALLS"
_MOCK_PR_LOOKUP_FAILS="0"

# TC-INV35-RT-010: First non-substantive failure → flip to pending-review
reset_mocks
_MOCK_VERDICT="failed-non-substantive"
_MOCK_CAUSE="bot-timeout"
_MOCK_FLIP_COUNT=0
assert_returns "RT-010 returns 0" 0 \
  handle_completed_session_routing 100 "sid-010" "2026-05-21T03:18:00Z"
assert_eq "RT-010 flip label pending-dev → pending-review" "100:pending-dev:pending-review " "$_MOCK_LABEL_SWAPS"
# Marker carries cause AND session-id (the per-session counter pivots on session=).
assert_contains "RT-010 marker comment cause" "cause=bot-timeout" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "RT-010 marker comment session-binding" "session=sid-010" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "RT-010 marker prefix" "<!-- review-aware-flip:non-substantive" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "RT-010 human-readable line" "Re-routing to review" "$_MOCK_LAST_COMMENT_BODY"
assert_eq "RT-010 no dispatch (Step 3 picks up)" "" "$_MOCK_DISPATCH_CALLS"
# Should not also post the substantive marker
if [[ "$_MOCK_LAST_COMMENT_BODY" != *"INV-35-fresh-dev"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: RT-010 no INV-35-fresh-dev marker"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: RT-010 INV-35-fresh-dev marker WAS posted"
  FAIL=$((FAIL + 1))
fi
assert_eq "RT-010 no stalled mark" "" "$_MOCK_MARK_STALLED_CALLS"

# TC-INV35-RT-011: Second flip → still under default cap (REVIEW_RETRY_LIMIT=2)
reset_mocks
_MOCK_VERDICT="failed-non-substantive"
_MOCK_CAUSE="bot-timeout"
_MOCK_FLIP_COUNT=1
assert_returns "RT-011 returns 0" 0 \
  handle_completed_session_routing 100 "sid-011" "2026-05-21T03:18:00Z"
assert_eq "RT-011 flips again" "100:pending-dev:pending-review " "$_MOCK_LABEL_SWAPS"
assert_eq "RT-011 no stall" "" "$_MOCK_MARK_STALLED_CALLS"

# TC-INV35-RT-012: Third flip blocked → mark stalled
reset_mocks
_MOCK_VERDICT="failed-non-substantive"
_MOCK_CAUSE="bot-timeout"
_MOCK_FLIP_COUNT=2
assert_returns "RT-012 returns 0" 0 \
  handle_completed_session_routing 100 "sid-012" "2026-05-21T03:18:00Z"
assert_eq "RT-012 stalled fired" "100 " "$_MOCK_MARK_STALLED_CALLS"
assert_eq "RT-012 no flip" "" "$_MOCK_LABEL_SWAPS"
assert_contains "RT-012 operator-actionable comment" "review-failure-non-substantive" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "RT-012 cause cited" "bot-timeout" "$_MOCK_LAST_COMMENT_BODY"

# TC-INV35-RT-013: per-session counter — flip count is for current session
# (handler reads count_review_aware_flips for THIS session-id only; mock
# returns 0 simulating fresh session even though prior session had flips)
reset_mocks
_MOCK_VERDICT="failed-non-substantive"
_MOCK_CAUSE="ci-transport"
_MOCK_FLIP_COUNT=0
assert_returns "RT-013 returns 0" 0 \
  handle_completed_session_routing 100 "sid-NEW-013" "2026-05-21T03:18:00Z"
assert_eq "RT-013 first flip allowed for fresh session" "100:pending-dev:pending-review " "$_MOCK_LABEL_SWAPS"

# TC-INV35-RT-014: REVIEW_RETRY_LIMIT=0 disables cap
reset_mocks
_MOCK_VERDICT="failed-non-substantive"
_MOCK_CAUSE="bot-timeout"
_MOCK_FLIP_COUNT=5
export REVIEW_RETRY_LIMIT=0
assert_returns "RT-014 returns 0" 0 \
  handle_completed_session_routing 100 "sid-014" "2026-05-21T03:18:00Z"
assert_eq "RT-014 sixth flip allowed under cap=0" "100:pending-dev:pending-review " "$_MOCK_LABEL_SWAPS"
assert_eq "RT-014 no stall" "" "$_MOCK_MARK_STALLED_CALLS"
unset REVIEW_RETRY_LIMIT

# TC-INV35-RT-020: Substantive → fresh dev-new (PTL pattern)
reset_mocks
_MOCK_VERDICT="failed-substantive"
prepare_log 100
assert_returns "RT-020 returns 0" 0 \
  handle_completed_session_routing 100 "sid-020" "2026-05-21T03:18:00Z"
assert_contains "RT-020 INV-35-fresh-dev marker comment" "INV-35-fresh-dev:sid-020" "$_MOCK_LAST_COMMENT_BODY"
assert_eq "RT-020 label swap pending-dev → in-progress" "100:pending-dev:in-progress " "$_MOCK_LABEL_SWAPS"
assert_eq "RT-020 dispatch token = dev-new" "100:dev-new " "$_MOCK_POST_TOKEN_CALLS"
assert_eq "RT-020 dispatch dev-new fired" "dev-new:100 " "$_MOCK_DISPATCH_CALLS"
log_size=$(stat -c '%s' "$_MOCK_LOG_FILE")
assert_eq "RT-020 log truncated to 0 bytes" "0" "$log_size"

# TC-INV35-RT-021: Substantive + truncate-fail → fail-closed
reset_mocks
_MOCK_VERDICT="failed-substantive"
prepare_readonly_log 100
assert_returns "RT-021 returns 0 (handled, fail-closed)" 0 \
  handle_completed_session_routing 100 "sid-021" "2026-05-21T03:18:00Z"
assert_contains "RT-021 operator-actionable comment posted" "permission" "$_MOCK_LAST_COMMENT_BODY"
assert_eq "RT-021 NO label swap" "" "$_MOCK_LABEL_SWAPS"
assert_eq "RT-021 NO dispatch" "" "$_MOCK_DISPATCH_CALLS"

# ---------------------------------------------------------------------------
# TC-RESET-REMOTE: [INV-100] (#356) Branch C truncate under
# EXECUTION_BACKEND=remote-aws-ssm. Stubs the SSM driver via
# _SESSION_LOG_PROBE_DRIVER_OVERRIDE (same pattern as
# test-is-session-completed-remote.sh) so this exercises the REAL
# _reset_session_log dispatch (not a mock), just with the network hop
# swapped for a local stub script.
# ---------------------------------------------------------------------------
RESET_REMOTE_TMPDIR=$(mktemp -d)
RESET_REMOTE_STUB="$RESET_REMOTE_TMPDIR/stub-driver.sh"
RESET_REMOTE_CALLS="$RESET_REMOTE_TMPDIR/calls.log"
cat > "$RESET_REMOTE_STUB" <<'STUB'
#!/bin/bash
echo "MODE=$1 ISSUE=$2 SSM_REMOTE_PROJECT_ID=${SSM_REMOTE_PROJECT_ID:-}" >> "$RESET_REMOTE_CALLS"
[[ "$1" = "--truncate" && "${RESET_REMOTE_TRUNCATE_FAIL:-0}" = "1" ]] && exit 2
exit 0
STUB
chmod +x "$RESET_REMOTE_STUB"
export _SESSION_LOG_PROBE_DRIVER_OVERRIDE="$RESET_REMOTE_STUB"
export RESET_REMOTE_CALLS

# TC-RESET-REMOTE-1: remote truncate succeeds → dev-new dispatched, NO local write.
reset_mocks
: > "$RESET_REMOTE_CALLS"
unset RESET_REMOTE_TRUNCATE_FAIL
_MOCK_VERDICT="failed-substantive"
_MOCK_LOG_FILE="/tmp/agent-${PROJECT_ID}-issue-100.log"
rm -f "$_MOCK_LOG_FILE"   # must NOT exist locally — this call must not touch it
EXECUTION_BACKEND=remote-aws-ssm SSM_REMOTE_PROJECT_ID=remote-proj \
  assert_returns "TC-RESET-REMOTE-1 returns 0" 0 \
  handle_completed_session_routing 100 "sid-reset-1" "2026-05-21T03:18:00Z"
assert_eq "TC-RESET-REMOTE-1 dispatch dev-new fired" "dev-new:100 " "$_MOCK_DISPATCH_CALLS"
assert_eq "TC-RESET-REMOTE-1 driver invoked with --truncate mode" "1" \
  "$(grep -c '^MODE=--truncate ISSUE=100 SSM_REMOTE_PROJECT_ID=remote-proj$' "$RESET_REMOTE_CALLS")"
if [[ -e "$_MOCK_LOG_FILE" ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-RESET-REMOTE-1 a controller-local log file was created (should route entirely through SSM)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-RESET-REMOTE-1 no controller-local log file created"
  PASS=$((PASS + 1))
fi
_MOCK_LOG_FILE=""

# TC-RESET-REMOTE-2: remote truncate fails (SSM error) → fail-closed, skip dispatch.
reset_mocks
: > "$RESET_REMOTE_CALLS"
export RESET_REMOTE_TRUNCATE_FAIL=1
_MOCK_VERDICT="failed-substantive"
EXECUTION_BACKEND=remote-aws-ssm SSM_REMOTE_PROJECT_ID=remote-proj \
  assert_returns "TC-RESET-REMOTE-2 returns 0 (handled, fail-closed)" 0 \
  handle_completed_session_routing 100 "sid-reset-2" "2026-05-21T03:18:00Z"
assert_contains "TC-RESET-REMOTE-2 operator-actionable comment posted" "permission" "$_MOCK_LAST_COMMENT_BODY"
assert_eq "TC-RESET-REMOTE-2 NO label swap" "" "$_MOCK_LABEL_SWAPS"
assert_eq "TC-RESET-REMOTE-2 NO dispatch" "" "$_MOCK_DISPATCH_CALLS"
unset RESET_REMOTE_TRUNCATE_FAIL

unset _SESSION_LOG_PROBE_DRIVER_OVERRIDE RESET_REMOTE_CALLS
rm -rf "$RESET_REMOTE_TMPDIR"

# TC-INV35-RT-022: Missing trailer treated as substantive (back-compat) —
# classifier returns failed-substantive directly, behavior identical to RT-020
reset_mocks
_MOCK_VERDICT="failed-substantive"
prepare_log 100
assert_returns "RT-022 returns 0" 0 \
  handle_completed_session_routing 100 "sid-022" "2026-05-21T03:18:00Z"
assert_eq "RT-022 dispatch dev-new fired" "dev-new:100 " "$_MOCK_DISPATCH_CALLS"

# TC-INV35-RT-030: passed verdict on pending-dev (race) → no-op
reset_mocks
_MOCK_VERDICT="passed"
assert_returns "RT-030 returns 0 (handled, WARN no-op)" 0 \
  handle_completed_session_routing 100 "sid-030" "2026-05-21T03:18:00Z"
assert_eq "RT-030 no comment posted" "0" "$_MOCK_COMMENT_COUNT"
assert_eq "RT-030 no label swap" "" "$_MOCK_LABEL_SWAPS"
assert_eq "RT-030 no dispatch" "" "$_MOCK_DISPATCH_CALLS"

# Idempotency on INV-35-fresh-dev marker
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_NOTICE_PRESENT="1"
_MOCK_NOTICE_SESSION="sid-040"   # #281: existing INV-35-fresh-dev marker carries this session id
prepare_log 100
assert_returns "INV-35-fresh-dev marker present → still dispatches but no duplicate comment" 0 \
  handle_completed_session_routing 100 "sid-040" "2026-05-21T03:18:00Z"
assert_eq "INV-35-fresh-dev idempotency: comment count = 0" "0" "$_MOCK_COMMENT_COUNT"

# ---------------------------------------------------------------------------
echo ""
echo "=== completed-session failed-substantive no-progress guard (#274 / INV-85) ==="
# ---------------------------------------------------------------------------

# TC-DISP-NOPROG-001: same HEAD + prior dev-new already ran for this HEAD →
# escalate (mark_stalled + idempotent notice), NO dev-new.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_NOPROG_ATTEMPT_PRESENT="1"   # a dev-new already ran for deadbeef
prepare_log 100
assert_returns "NOPROG-001 returns 0" 0 \
  handle_completed_session_routing 100 "sid-np001" "2026-05-21T03:18:00Z"
assert_eq "NOPROG-001 NO dispatch dev-new" "" "$_MOCK_DISPATCH_CALLS"
assert_eq "NOPROG-001 NO post_dispatch_token" "" "$_MOCK_POST_TOKEN_CALLS"
assert_eq "NOPROG-001 NO label swap to in-progress" "" "$_MOCK_LABEL_SWAPS"
assert_eq "NOPROG-001 mark_stalled fired" "100 " "$_MOCK_MARK_STALLED_CALLS"
assert_contains "NOPROG-001 idempotent notice marker" "no-progress-substantive:deadbeef" "$_MOCK_LAST_COMMENT_BODY"
assert_eq "NOPROG-001 exactly one notice posted" "1" "$_MOCK_COMMENT_COUNT"
# Log is NOT truncated on the escalation path (no fresh dispatch).
log_size=$(stat -c '%s' "$_MOCK_LOG_FILE")
if [[ "$log_size" != "0" ]]; then
  echo -e "  ${GREEN}PASS${NC}: NOPROG-001 log left intact (not truncated)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: NOPROG-001 log was truncated on escalation path"
  FAIL=$((FAIL + 1))
fi

# TC-DISP-NOPROG-002: new HEAD (dev pushed new commits) → dev-new proceeds,
# attempt marker recorded for the new HEAD, NO stall (no regression).
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_PR_HEAD="cafe1234"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"   # older — HEAD advanced
_MOCK_NOPROG_ATTEMPT_PRESENT="0"
prepare_log 100
assert_returns "NOPROG-002 returns 0" 0 \
  handle_completed_session_routing 100 "sid-np002" "2026-05-21T03:18:00Z"
assert_eq "NOPROG-002 label swap pending-dev → in-progress" "100:pending-dev:in-progress " "$_MOCK_LABEL_SWAPS"
assert_eq "NOPROG-002 dispatch token dev-new" "100:dev-new " "$_MOCK_POST_TOKEN_CALLS"
assert_eq "NOPROG-002 dispatch dev-new fired" "dev-new:100 " "$_MOCK_DISPATCH_CALLS"
assert_eq "NOPROG-002 NO stall" "" "$_MOCK_MARK_STALLED_CALLS"
log_size=$(stat -c '%s' "$_MOCK_LOG_FILE")
assert_eq "NOPROG-002 log truncated to 0 bytes" "0" "$log_size"
assert_contains "NOPROG-002 attempt marker recorded for new HEAD" "no-progress-substantive-attempt:cafe1234" "$_MOCK_FULL_COMMENT_LOG"

# TC-DISP-NOPROG-003: same HEAD + escalation notice already present → no
# duplicate notice; still no dev-new; still stalled.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_NOPROG_ATTEMPT_PRESENT="1"
_MOCK_NOPROG_NOTICE_PRESENT="1"      # escalation notice already posted
prepare_log 100
assert_returns "NOPROG-003 returns 0" 0 \
  handle_completed_session_routing 100 "sid-np003" "2026-05-21T03:18:00Z"
assert_eq "NOPROG-003 no duplicate notice" "0" "$_MOCK_COMMENT_COUNT"
assert_eq "NOPROG-003 NO dispatch dev-new" "" "$_MOCK_DISPATCH_CALLS"
assert_eq "NOPROG-003 mark_stalled still fired" "100 " "$_MOCK_MARK_STALLED_CALLS"

# TC-DISP-NOPROG-004: bot-unfixable 403 signature at the SAME (unchanged) HEAD
# → operator handoff, no dev-new. Branch A requires current_head == last_head
# (#274 review [P1] finding 1): a 403 only blocks when HEAD has not advanced.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"   # HEAD unchanged since last review — gates branch A
_MOCK_BOT_UNFIXABLE=0                 # the 403-on-PR-body-edit signature is present
prepare_log 100
assert_returns "NOPROG-004 returns 0" 0 \
  handle_completed_session_routing 100 "sid-np004" "2026-05-21T03:18:00Z"
assert_eq "NOPROG-004 NO dispatch dev-new" "" "$_MOCK_DISPATCH_CALLS"
assert_eq "NOPROG-004 NO post_dispatch_token" "" "$_MOCK_POST_TOKEN_CALLS"
assert_eq "NOPROG-004 NO label swap to in-progress" "" "$_MOCK_LABEL_SWAPS"
assert_eq "NOPROG-004 mark_stalled fired" "100 " "$_MOCK_MARK_STALLED_CALLS"
assert_contains "NOPROG-004 notice cites bot-unfixable" "no-progress-substantive:deadbeef" "$_MOCK_LAST_COMMENT_BODY"

# TC-DISP-NOPROG-006 (#274 review [P1] finding 1 regression): bot-unfixable 403
# present BUT HEAD has advanced since the last review → the 403 is stale; branch
# A must NOT fire. dev-new proceeds (the dev made progress; a new attempt against
# the new HEAD is correct). This is the bug the reviewer flagged: a single old
# 403 must not permanently stall the issue after HEAD moves.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_PR_HEAD="cafe1234"              # HEAD advanced
_MOCK_LAST_REVIEWED_HEAD="deadbeef"  # older — current != last
_MOCK_BOT_UNFIXABLE=0                # an old 403 is still on the issue, but stale
_MOCK_NOPROG_ATTEMPT_PRESENT="0"
prepare_log 100
assert_returns "NOPROG-006 returns 0" 0 \
  handle_completed_session_routing 100 "sid-np006" "2026-05-21T03:18:00Z"
assert_eq "NOPROG-006 NO stall (stale 403, HEAD advanced)" "" "$_MOCK_MARK_STALLED_CALLS"
assert_eq "NOPROG-006 dispatch dev-new fired" "dev-new:100 " "$_MOCK_DISPATCH_CALLS"
assert_eq "NOPROG-006 label swap pending-dev → in-progress" "100:pending-dev:in-progress " "$_MOCK_LABEL_SWAPS"
assert_contains "NOPROG-006 attempt marker recorded for new HEAD" "no-progress-substantive-attempt:cafe1234" "$_MOCK_FULL_COMMENT_LOG"

# TC-DISP-NOPROG-007 (#274 review [P1] finding 2 regression): when the fresh
# dispatch is aborted by a transient failure (log truncate fails → fail-closed
# return 0 WITHOUT dispatching), the attempt marker MUST NOT be written —
# otherwise the next tick would wrongly conclude a dev-new already ran and stall.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_NOPROG_ATTEMPT_PRESENT="0"      # first attempt at this HEAD
prepare_readonly_log 100              # truncate will fail (read-only log)
assert_returns "NOPROG-007 returns 0 (fail-closed)" 0 \
  handle_completed_session_routing 100 "sid-np007" "2026-05-21T03:18:00Z"
assert_eq "NOPROG-007 NO dispatch (truncate failed)" "" "$_MOCK_DISPATCH_CALLS"
assert_eq "NOPROG-007 NO label swap (truncate failed)" "" "$_MOCK_LABEL_SWAPS"
if [[ "$_MOCK_FULL_COMMENT_LOG" != *"no-progress-substantive-attempt:"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: NOPROG-007 attempt marker NOT written when dispatch aborted"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: NOPROG-007 attempt marker was written despite aborted dispatch"
  FAIL=$((FAIL + 1))
fi

# TC-DISP-NOPROG-005: first substantive attempt at a HEAD (no marker yet) →
# records attempt marker AND mints dev-new (bounded N=1).
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_NOPROG_ATTEMPT_PRESENT="0"      # no prior dev-new for this HEAD
prepare_log 100
assert_returns "NOPROG-005 returns 0" 0 \
  handle_completed_session_routing 100 "sid-np005" "2026-05-21T03:18:00Z"
assert_eq "NOPROG-005 dispatch dev-new fired" "dev-new:100 " "$_MOCK_DISPATCH_CALLS"
assert_eq "NOPROG-005 NO stall (first attempt allowed)" "" "$_MOCK_MARK_STALLED_CALLS"
assert_contains "NOPROG-005 attempt marker recorded" "no-progress-substantive-attempt:deadbeef" "$_MOCK_FULL_COMMENT_LOG"
log_size=$(stat -c '%s' "$_MOCK_LOG_FILE")
assert_eq "NOPROG-005 log truncated to 0 bytes" "0" "$log_size"

# TC-DISP-NOPROG-008 (#274 review [P1] round-3 finding 2): when the attempt-marker
# write is rejected by GitHub, the code must NOT silently swallow it — it retries
# once (2 total attempts) and posts a LOUD operator notice that the N=1 bound is
# degraded. dev-new still dispatched; MAX_RETRIES remains the backstop.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_NOPROG_ATTEMPT_PRESENT="0"
_MOCK_ATTEMPT_WRITE_FAILS="1"         # GitHub rejects the marker comment
prepare_log 100
assert_returns "NOPROG-008 returns 0" 0 \
  handle_completed_session_routing 100 "sid-np008" "2026-05-21T03:18:00Z"
assert_eq "NOPROG-008 dispatch dev-new still fired" "dev-new:100 " "$_MOCK_DISPATCH_CALLS"
assert_eq "NOPROG-008 marker write retried once (2 attempts)" "2" "$_MOCK_ATTEMPT_WRITE_TRIES"
assert_contains "NOPROG-008 loud operator notice on degraded bound" "could not record the per-HEAD no-progress attempt tracker for \`deadbeef\`" "$_MOCK_LAST_COMMENT_BODY"
# The loud notice must NOT contain the literal grep token, else it would satisfy
# branch B's marker-presence check next tick → a false stall.
if [[ "$_MOCK_LAST_COMMENT_BODY" != *"no-progress-substantive-attempt:"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: NOPROG-008 notice avoids the literal marker grep token"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: NOPROG-008 notice contains the grep token (would false-trigger branch B)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== INV-92 (#298) Branch B′: non-actionable finding → escalate, no dev-new ==="
# ---------------------------------------------------------------------------

# TC-INV92-RT-001: failed-substantive + dev-actionable=false → mark_stalled,
# idempotent escalation notice, NO dispatch dev-new, NO label swap to in-progress.
# HEAD has NOT advanced (so neither INV-85 branch A nor B fires — branch A needs
# the bot-unfixable signature (default off), branch B needs an attempt marker
# (default absent)) — Branch B′ is the one that fires on the false token.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="false"
_MOCK_PR_HEAD="cafef00d"
_MOCK_LAST_REVIEWED_HEAD="cafef00d"
prepare_log 100
assert_returns "INV92-RT-001 returns 0" 0 \
  handle_completed_session_routing 100 "sid-na001" "2026-05-21T03:18:00Z"
assert_eq "INV92-RT-001 mark_stalled fired" "100 " "$_MOCK_MARK_STALLED_CALLS"
assert_eq "INV92-RT-001 NO dispatch dev-new" "" "$_MOCK_DISPATCH_CALLS"
assert_eq "INV92-RT-001 NO post_dispatch_token" "" "$_MOCK_POST_TOKEN_CALLS"
assert_eq "INV92-RT-001 NO label swap to in-progress" "" "$_MOCK_LABEL_SWAPS"
assert_contains "INV92-RT-001 notice keyed non-actionable-finding:<head>" "non-actionable-finding:cafef00d" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "INV92-RT-001 notice carries reason=non_actionable_finding" "reason=non_actionable_finding" "$_MOCK_LAST_COMMENT_BODY"
assert_eq "INV92-RT-001 exactly one notice posted" "1" "$_MOCK_COMMENT_COUNT"
# Log NOT truncated on the escalation path.
log_size=$(stat -c '%s' "$_MOCK_LOG_FILE")
if [[ "$log_size" != "0" ]]; then
  echo -e "  ${GREEN}PASS${NC}: INV92-RT-001 log left intact (not truncated)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: INV92-RT-001 log was truncated on escalation path"
  FAIL=$((FAIL + 1))
fi

# TC-INV92-RT-002: failed-substantive + dev-actionable=true → falls through to
# Branch C dev-new (regression — the common case is unchanged).
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_PR_HEAD="cafef00d"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"   # HEAD advanced → branch C
prepare_log 100
assert_returns "INV92-RT-002 returns 0" 0 \
  handle_completed_session_routing 100 "sid-na002" "2026-05-21T03:18:00Z"
assert_eq "INV92-RT-002 dispatch dev-new fired (actionable)" "dev-new:100 " "$_MOCK_DISPATCH_CALLS"
assert_eq "INV92-RT-002 NO stall" "" "$_MOCK_MARK_STALLED_CALLS"
assert_eq "INV92-RT-002 label swap to in-progress" "100:pending-dev:in-progress " "$_MOCK_LABEL_SWAPS"

# TC-INV92-RT-003: failed-substantive + token ABSENT (legacy, mock defaults true)
# → Branch C dev-new (fail-open regression).
reset_mocks
_MOCK_VERDICT="failed-substantive"
# _MOCK_DEV_ACTIONABLE stays "true" from reset (the handler defaults absent ⇒ true)
_MOCK_PR_HEAD="cafef00d"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
prepare_log 100
assert_returns "INV92-RT-003 returns 0" 0 \
  handle_completed_session_routing 100 "sid-na003" "2026-05-21T03:18:00Z"
assert_eq "INV92-RT-003 dispatch dev-new fired (legacy fail-open)" "dev-new:100 " "$_MOCK_DISPATCH_CALLS"
assert_eq "INV92-RT-003 NO stall (legacy fail-open)" "" "$_MOCK_MARK_STALLED_CALLS"

# TC-INV92-RT-004: idempotency — second tick, same HEAD, dev-actionable=false,
# the escalation notice already present → mark_stalled still fires but NO
# duplicate notice.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="false"
_MOCK_PR_HEAD="cafef00d"
_MOCK_LAST_REVIEWED_HEAD="cafef00d"
_MOCK_NONACT_NOTICE_PRESENT="1"        # notice already posted
prepare_log 100
assert_returns "INV92-RT-004 returns 0" 0 \
  handle_completed_session_routing 100 "sid-na004" "2026-05-21T03:18:00Z"
assert_eq "INV92-RT-004 no duplicate notice" "0" "$_MOCK_COMMENT_COUNT"
assert_eq "INV92-RT-004 NO dispatch dev-new" "" "$_MOCK_DISPATCH_CALLS"
assert_eq "INV92-RT-004 mark_stalled still fired" "100 " "$_MOCK_MARK_STALLED_CALLS"

# TC-INV92-RT-005: Branch A (bot-unfixable) takes PRECEDENCE over Branch B′ when
# both could apply (the 403 signature + unchanged HEAD) — the existing INV-85
# escalation path is unchanged; dev-actionable=false does not change which branch
# wins, only that the issue escalates (both lead to mark_stalled). This pins that
# Branch B′ is inserted AFTER A and B, so an already-detected bot-unfixable 403
# still routes through Branch A's notice marker.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="false"
_MOCK_PR_HEAD="cafef00d"
_MOCK_LAST_REVIEWED_HEAD="cafef00d"
_MOCK_BOT_UNFIXABLE=0                   # branch A 403 signature present
prepare_log 100
assert_returns "INV92-RT-005 returns 0" 0 \
  handle_completed_session_routing 100 "sid-na005" "2026-05-21T03:18:00Z"
assert_eq "INV92-RT-005 mark_stalled fired" "100 " "$_MOCK_MARK_STALLED_CALLS"
assert_eq "INV92-RT-005 NO dispatch dev-new" "" "$_MOCK_DISPATCH_CALLS"
assert_contains "INV92-RT-005 Branch A notice wins (no-progress-substantive marker)" "no-progress-substantive:cafef00d" "$_MOCK_LAST_COMMENT_BODY"

# TC-INV92-RT-006: dev-actionable=false but NO PR resolved (head empty) → the
# notice keys on `non-actionable-finding:none` and still escalates.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="false"
_MOCK_PR_HEAD=""                        # no PR
_MOCK_LAST_REVIEWED_HEAD=""
prepare_log 100
assert_returns "INV92-RT-006 returns 0" 0 \
  handle_completed_session_routing 100 "sid-na006" "2026-05-21T03:18:00Z"
assert_eq "INV92-RT-006 mark_stalled fired (no PR)" "100 " "$_MOCK_MARK_STALLED_CALLS"
assert_eq "INV92-RT-006 NO dispatch dev-new" "" "$_MOCK_DISPATCH_CALLS"
assert_contains "INV92-RT-006 notice keys non-actionable-finding:none" "non-actionable-finding:none" "$_MOCK_LAST_COMMENT_BODY"

# ---------------------------------------------------------------------------
echo ""
echo "=== INV-136 (#488) D4: stall notice surfaces the matched-patterns marker ==="
# ---------------------------------------------------------------------------

# TC-INV134-D4-08: Branch B′ fires with an `inv92-matched-patterns:` marker
# already on the issue (posted by the review wrapper) — the escalation notice
# names the matched pattern(s) + the REVIEW_PROTECTED_PATHS conf lever.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="false"
_MOCK_PR_HEAD="cafef00d"
_MOCK_LAST_REVIEWED_HEAD="cafef00d"
_MOCK_MATCHED_PATTERNS_MARKER=".github/workflows/** CODEOWNERS"
prepare_log 100
assert_returns "TC-INV134-D4-08 returns 0" 0 \
  handle_completed_session_routing 100 "sid-d408" "2026-05-21T03:18:00Z"
assert_eq "TC-INV134-D4-08 mark_stalled fired" "100 " "$_MOCK_MARK_STALLED_CALLS"
assert_contains "TC-INV134-D4-08 notice names matched patterns" \
  "Matched \`REVIEW_PROTECTED_PATHS\` pattern(s): .github/workflows/** CODEOWNERS" "$_MOCK_LAST_COMMENT_BODY"

# TC-INV134-D4-09: Branch B′ fires with NO marker present — the notice is
# byte-identical to the pre-#488 generic wording (no pattern sentence at all).
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="false"
_MOCK_PR_HEAD="cafef00d"
_MOCK_LAST_REVIEWED_HEAD="cafef00d"
prepare_log 100
assert_returns "TC-INV134-D4-09 returns 0" 0 \
  handle_completed_session_routing 100 "sid-d409" "2026-05-21T03:18:00Z"
assert_eq "TC-INV134-D4-09 mark_stalled fired" "100 " "$_MOCK_MARK_STALLED_CALLS"
case "$_MOCK_LAST_COMMENT_BODY" in
  *"Matched \`REVIEW_PROTECTED_PATHS\` pattern(s)"*)
    echo -e "  ${RED}FAIL${NC}: TC-INV134-D4-09 notice should NOT mention matched patterns when no marker exists"
    FAIL=$((FAIL + 1))
    ;;
  *)
    echo -e "  ${GREEN}PASS${NC}: TC-INV134-D4-09 no marker ⇒ generic fallback wording, no pattern sentence"
    PASS=$((PASS + 1))
    ;;
esac

# TC-INV134-D4-16 (codex review round-2, PR #498): a marker EXISTS on the
# issue, but it was posted for a DIFFERENT (earlier, stale) head than the one
# this verdict was reviewed against — the notice must NOT surface it and must
# fall back to the generic wording, exactly as if no marker existed at all.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="false"
_MOCK_PR_HEAD="cafef00d"
_MOCK_LAST_REVIEWED_HEAD="cafef00d"
_MOCK_MATCHED_PATTERNS_MARKER=".github/workflows/**"
_MOCK_MATCHED_PATTERNS_HEAD="stale0ld"
prepare_log 100
assert_returns "TC-INV134-D4-16 returns 0" 0 \
  handle_completed_session_routing 100 "sid-d416" "2026-05-21T03:18:00Z"
assert_eq "TC-INV134-D4-16 mark_stalled fired" "100 " "$_MOCK_MARK_STALLED_CALLS"
case "$_MOCK_LAST_COMMENT_BODY" in
  *"Matched \`REVIEW_PROTECTED_PATHS\` pattern(s)"*)
    echo -e "  ${RED}FAIL${NC}: TC-INV134-D4-16 notice must NOT surface a stale marker from a different head"
    FAIL=$((FAIL + 1))
    ;;
  *)
    echo -e "  ${GREEN}PASS${NC}: TC-INV134-D4-16 stale (different-head) marker ignored, generic fallback wording used"
    PASS=$((PASS + 1))
    ;;
esac

# TC-INV134-D4-11: _inv92_matched_patterns directly — fail-empty on an
# itp_list_comments transport failure (never propagates the error text or a
# stale value, rc is irrelevant since every caller only checks `-n`), and
# correct extraction when the marker IS present AND its `head=` field matches
# the caller-supplied head (codex review round-2, PR #498: the reader now
# requires an exact head match). Run under this file's own `set +e` posture
# (the set -e ABORT class itself is TC-INV134-D4-12's job).
reset_mocks
_MOCK_MATCHED_PATTERNS_MARKER=".github/workflows/** CODEOWNERS"
_MOCK_MATCHED_PATTERNS_HEAD="cafef00d"
assert_eq "TC-INV134-D4-11a extracts the marker pattern list when the head matches" \
  ".github/workflows/** CODEOWNERS" "$(_inv92_matched_patterns 100 "cafef00d")"
assert_eq "TC-INV134-D4-11a2 empty when the caller's head does NOT match the marker's head" \
  "" "$(_inv92_matched_patterns 100 "some-other-head")"
_MOCK_MATCHED_PATTERNS_MARKER=""
_MOCK_COMMENT_FETCH_RC_UNUSED=1  # documents intent; real transport-failure mock below
itp_list_comments() { return 1; }
assert_eq "TC-INV134-D4-11b fail-empty on itp_list_comments transport failure" \
  "" "$(_inv92_matched_patterns 100 "cafef00d")"
# Restore the real mock this file's other tests depend on.
itp_list_comments() {
  local _bodies=()
  if [[ "${_MOCK_NOPROG_ATTEMPT_PRESENT:-0}" != "0" ]]; then
    _bodies+=("<!-- no-progress-substantive-attempt:${_MOCK_PR_HEAD} -->")
  fi
  if [[ "${_MOCK_NOPROG_NOTICE_PRESENT:-0}" != "0" ]]; then
    _bodies+=("no-progress-substantive:${_MOCK_PR_HEAD} notice")
  fi
  if [[ "${_MOCK_NONACT_NOTICE_PRESENT:-0}" != "0" ]]; then
    _bodies+=("non-actionable-finding:${_MOCK_PR_HEAD:-none} prior notice")
  fi
  if [[ -n "${_MOCK_MATCHED_PATTERNS_MARKER:-}" ]]; then
    _bodies+=("Non-actionable findings comment.
<!-- inv92-matched-patterns: ${_MOCK_MATCHED_PATTERNS_MARKER} -->")
  fi
  if [[ "${_MOCK_NOTICE_PRESENT:-0}" != "0" ]]; then
    local _sid="${_MOCK_NOTICE_SESSION:-__no_session__}"
    _bodies+=("INV-12-completed:${_sid} INV-35-fresh-dev:${_sid} INV-12-no-pr-fresh-dev:${_sid} prior notice")
  fi
  local _json="[]" _ts=0 b
  for b in "${_bodies[@]}"; do
    _json=$(jq -c --arg b "$b" --argjson t "$_ts" \
      '. + [{id:(100+$t), author:"my-claw", authorKind:"self", body:$b, createdAt:"2026-06-12T00:00:0\($t)Z"}]' <<<"$_json")
    _ts=$((_ts + 1))
  done
  printf '%s' "$_json"
}
reset_mocks

# TC-INV134-D4-12 [set -e regression, mirrors TC-LIVENESS-075..078]: this file
# and lib-dispatch.sh both run under `set -euo pipefail` in production, but
# this harness runs under `set +e` (below) so it can keep counting PASS/FAIL
# after an assertion failure — that harness posture CANNOT catch a bare
# `_inv92_matched_patterns` call that would abort the caller under REAL
# `set -e` if `itp_list_comments` (inside it) transiently fails. Spawn a
# FRESH bash subshell with real `set -euo pipefail` (mirroring production) and
# prove Branch B′ still reaches `mark_stalled` when the comment-fetch fails.
_d4_sete_probe() {
  bash -euo pipefail -c '
    export REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane PROJECT_ID=d4-sete-probe-$$ MAX_RETRIES=3 MAX_CONCURRENT=5
    source "'"$LIB"'"
    log() { :; }
    fetch_pr_for_issue() { printf "%s" "{\"number\":777,\"headRefOid\":\"cafef00d\"}"; }
    last_reviewed_head() { printf "%s" "cafef00d"; }
    dev_report_bot_unfixable() { return 1; }
    classify_recent_review_verdict() {
      local _v="$3" _c="$4" _da="${5:-}"
      printf -v "$_v" "%s" "failed-substantive"; printf -v "$_c" "%s" ""
      [ -n "$_da" ] && printf -v "$_da" "%s" "false"
    }
    # This branch makes TWO prior itp_list_comments calls before ever
    # reaching _inv92_matched_patterns: (1) the no-progress-attempt marker
    # check just above Branch B-prime, (2) Branch B-primes own idempotency
    # check. Both MUST succeed (empty [], no marker) or the surrounding ifs
    # short-circuit and never reach _inv92_matched_patterns at all - which
    # would make this probe pass vacuously without exercising the bug (a
    # miscounted threshold here is exactly the mistake that hid this bug
    # during initial development). The THIRD call (inside
    # _inv92_matched_patterns) must FAIL (the transient transport blip). A
    # FILE-based counter, not a shell var: every call site pipes
    # itp_list_comments into jq, which forks it into a SUBSHELL - a plain
    # variable increment there would never persist back to this scope.
    _d4_count_file="$(mktemp)"; echo 0 > "$_d4_count_file"
    itp_list_comments() {
      local _n; _n=$(<"$_d4_count_file"); _n=$((_n + 1)); echo "$_n" > "$_d4_count_file"
      if [ "$_n" -le 2 ]; then
        printf "%s" "[]"
        return 0
      fi
      echo "gh: rate limit exceeded" >&2
      return 1
    }
    itp_post_comment() { :; }
    mark_stalled() { echo "MARK_STALLED_CALLED"; }
    handle_completed_session_routing 100 "sid-d412" "2026-05-21T03:18:00Z"
    echo "REACHED_END"
    echo "TOTAL_ITP_CALLS=$(<"$_d4_count_file")"
  ' 2>/dev/null
}
_D4_SETE_OUT="$(_d4_sete_probe)"
assert_contains "TC-INV134-D4-12 mark_stalled reached despite itp_list_comments failure under real set -e" \
  "MARK_STALLED_CALLED" "$_D4_SETE_OUT"
assert_contains "TC-INV134-D4-12 function returns normally (does not abort the caller)" \
  "REACHED_END" "$_D4_SETE_OUT"
# Evidence the probe genuinely reached _inv92_matched_patterns's OWN failing
# call (not just the two calls before it) — >=3 total calls is only possible
# if both prior checks succeeded and control fell through into
# _inv92_matched_patterns, which made the 3rd (failing) call.
assert_contains "TC-INV134-D4-12 reached the 3rd itp_list_comments call inside _inv92_matched_patterns (not a vacuous pass)" \
  "TOTAL_ITP_CALLS=3" "$_D4_SETE_OUT"

# Cleanup
reset_mocks

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
