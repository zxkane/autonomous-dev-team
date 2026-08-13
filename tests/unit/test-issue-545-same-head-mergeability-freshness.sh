#!/bin/bash
# Regression coverage for issue #545: a consumed same-HEAD non-substantive
# retry cannot turn historical mergeable-unknown evidence into a stale stall.
#
# Run: bash tests/unit/test-issue-545-same-head-mergeability-freshness.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCH_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
DISPATCH_TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID="test-545-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5
export MERGEABLE_RETRIES=3
export MERGEABLE_RETRY_DELAY_SECONDS=0
export REVIEW_RETRY_LIMIT=2

US=$'\037'
HEAD_H="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_OTHER="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT
TRACE="$TMPDIR_T/trace"
PROVIDER_HEAD_FILE="$TMPDIR_T/provider-head"
MERGEABLE_CALLS_FILE="$TMPDIR_T/mergeable-calls"
POSTED_COMMENTS_FILE="$TMPDIR_T/posted-comments"
: >"$TRACE"
: >"$POSTED_COMMENTS_FILE"
printf '0' >"$MERGEABLE_CALLS_FILE"

_rec() {
  local verb="$1"
  shift
  local line="$verb" arg
  for arg in "$@"; do line+="${US}${arg}"; done
  printf '%s\n' "${line//$'\n'/\\n}" >>"$TRACE"
}

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$DISPATCH_LIB"
set +e

log() { :; }
itp_list_comments() {
  local body="<!-- review-verdict: ${_MOCK_VERDICT} cause=${_MOCK_VERDICT_CAUSE} head=${_MOCK_HEAD} -->"
  local posted
  if [[ "${FUNCNAME[1]:-}" == "_same_head_requeue_intent_count" \
        && "$_MOCK_INTENT_COUNT_READ_RC" != "0" ]]; then
    return "$_MOCK_INTENT_COUNT_READ_RC"
  fi
  if [[ "${FUNCNAME[1]:-}" == "count_review_aware_flips" \
        && "$_MOCK_FLIP_COUNT_READ_RC" != "0" ]]; then
    return "$_MOCK_FLIP_COUNT_READ_RC"
  fi
  if [[ -n "$_MOCK_COMMENTS_JSON_OVERRIDE" ]]; then
    printf '%s\n' "$_MOCK_COMMENTS_JSON_OVERRIDE"
    return 0
  fi
  [[ "$_MOCK_NONSUB_PRESENT" == "1" ]] \
    && body+=" self-heal-non-substantive:${_MOCK_HEAD}"
  [[ "$_MOCK_DEV_BUDGET_PRESENT" == "1" ]] \
    && body+=" crashed-session-retry:${_MOCK_HEAD}"
  posted=$(jq -Rn '[inputs | select(length > 0) | @base64d | {body:.}]' \
    <"$POSTED_COMMENTS_FILE")
  jq -cn --arg body "$body" --argjson posted "$posted" \
    '[{body:$body}] + $posted'
}
itp_post_comment() {
  _rec itp_post_comment "$@"
  if [[ "$_MOCK_COMPLETION_POST_RC" != "0" \
        && "${2:-}" == *"source=same-head-refresh"* ]]; then
    return "$_MOCK_COMPLETION_POST_RC"
  fi
  jq -rn --arg body "${2:-}" '$body | @base64' >>"$POSTED_COMMENTS_FILE"
  if [[ "${2:-}" == *"self-heal-non-substantive:${_MOCK_HEAD}"* ]]; then
    _MOCK_NONSUB_PRESENT=1
  fi
}
fetch_pr_for_issue() {
  _rec fetch_pr_for_issue "$@"
  jq -cn --arg head "$_MOCK_HEAD" \
    '{number:42,headRefOid:$head,body:"Closes #545"}'
}
_latest_review_routing_head() { printf '%s' "$_MOCK_HEAD"; }
last_reviewed_head() { printf '%s' "$_MOCK_HEAD"; }
extract_dev_session_id() { printf '%s' "$_MOCK_SESSION_ID"; }
is_session_completed() {
  if [[ "$_MOCK_COMPLETED_RC" == "0" ]]; then
    printf -v "$2" '%s' "completed"
    printf -v "$3" '%s' "2026-08-13T00:00:00Z"
  fi
  return "$_MOCK_COMPLETED_RC"
}
may_stall_now() { return "$_MOCK_MAY_STALL_RC"; }
classify_recent_review_verdict() {
  local verdict_var="$3" cause_var="$4" actionable_var="${5:-}"
  printf -v "$verdict_var" '%s' "$_MOCK_VERDICT"
  printf -v "$cause_var" '%s' "$_MOCK_VERDICT_CAUSE"
  [[ -n "$actionable_var" ]] \
    && printf -v "$actionable_var" '%s' "$_MOCK_DEV_ACTIONABLE"
}
chp_pr_view() {
  local provider_head
  _rec chp_pr_view "$@"
  [[ "$_MOCK_SNAPSHOT_RC" == "0" ]] || return "$_MOCK_SNAPSHOT_RC"
  provider_head=$(cat "$PROVIDER_HEAD_FILE")
  jq -cn \
    --arg state "$_MOCK_STATE" \
    --arg head "$provider_head" \
    --arg branch "$_MOCK_BRANCH" \
    '{state:$state,headRefOid:$head,headRefName:$branch}'
}
chp_mergeable() {
  local call_index sequence rc_sequence status rc
  _rec chp_mergeable "$@"
  call_index=$(cat "$MERGEABLE_CALLS_FILE")
  call_index=$((call_index + 1))
  printf '%s' "$call_index" >"$MERGEABLE_CALLS_FILE"

  sequence="${_MOCK_MERGEABLE_SEQUENCE:-$_MOCK_MERGEABLE}"
  rc_sequence="${_MOCK_MERGEABLE_RC_SEQUENCE:-$_MOCK_MERGEABLE_RC}"
  status=$(awk -F'|' -v n="$call_index" '{
    if (n > NF) n = NF
    print $n
  }' <<<"$sequence")
  rc=$(awk -F'|' -v n="$call_index" '{
    if (n > NF) n = NF
    print $n
  }' <<<"$rc_sequence")
  [[ "$rc" == "0" ]] || return "$rc"
  if [[ -n "$_MOCK_PROVIDER_HEAD_AFTER_MERGEABLE" ]]; then
    printf '%s' "$_MOCK_PROVIDER_HEAD_AFTER_MERGEABLE" >"$PROVIDER_HEAD_FILE"
  fi
  printf '%s\n' "$status"
}
label_swap() {
  _rec label_swap "$@"
  [[ "$_MOCK_LABEL_SWAP_RC" == "0" ]] || return "$_MOCK_LABEL_SWAP_RC"
  _MOCK_LABEL_STATE="${3:-}"
}
mark_stalled() {
  _rec mark_stalled "$@"
  _MOCK_LABEL_STATE="stalled"
}
acquire_dispatch_marker() { _rec acquire_dispatch_marker "$@"; return 0; }
release_dispatch_marker() { _rec release_dispatch_marker "$@"; }
dispatch_marker_confirm_launched() { _rec dispatch_marker_confirm_launched "$@"; }
post_dispatch_token() { _rec post_dispatch_token "$@"; }
dispatch() { _rec dispatch "$@"; return 0; }
handle_dispatch_deferred() { _rec handle_dispatch_deferred "$@"; }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf '  PASS: %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    expected: [%s]\n    actual:   [%s]\n' \
      "$desc" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}
assert_match() {
  local desc="$1" pattern="$2"
  if grep -qE "$pattern" "$TRACE"; then
    printf '  PASS: %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    missing pattern: %s\n' "$desc" "$pattern"
    cat "$TRACE"
    FAIL=$((FAIL + 1))
  fi
}
assert_no_match() {
  local desc="$1" pattern="$2"
  if ! grep -qE "$pattern" "$TRACE"; then
    printf '  PASS: %s\n' "$desc"
    PASS=$((PASS + 1))
  else
    printf '  FAIL: %s\n    unexpected pattern: %s\n' "$desc" "$pattern"
    cat "$TRACE"
    FAIL=$((FAIL + 1))
  fi
}

_reset() {
  : >"$TRACE"
  : >"$POSTED_COMMENTS_FILE"
  printf '0' >"$MERGEABLE_CALLS_FILE"
  _MOCK_HEAD="$HEAD_H"
  printf '%s' "$HEAD_H" >"$PROVIDER_HEAD_FILE"
  _MOCK_STATE="OPEN"
  _MOCK_BRANCH="fix/issue-545"
  _MOCK_VERDICT="failed-non-substantive"
  _MOCK_VERDICT_CAUSE="mergeable-unknown"
  _MOCK_DEV_ACTIONABLE="true"
  _MOCK_SESSION_ID="sid-545"
  _MOCK_COMPLETED_RC=1
  _MOCK_MAY_STALL_RC=0
  _MOCK_NONSUB_PRESENT=1
  _MOCK_DEV_BUDGET_PRESENT=0
  _MOCK_MERGEABLE="MERGEABLE"
  _MOCK_MERGEABLE_RC=0
  _MOCK_MERGEABLE_SEQUENCE=""
  _MOCK_MERGEABLE_RC_SEQUENCE=""
  _MOCK_SNAPSHOT_RC=0
  _MOCK_PROVIDER_HEAD_AFTER_MERGEABLE=""
  _MOCK_LABEL_STATE="pending-dev"
  _MOCK_LABEL_SWAP_RC=0
  _MOCK_INTENT_COUNT_READ_RC=0
  _MOCK_FLIP_COUNT_READ_RC=0
  _MOCK_COMPLETION_POST_RC=0
  _MOCK_COMMENTS_JSON_OVERRIDE=""
}

echo "=== TC-545-FRESH-001: UNKNOWN -> MERGEABLE at unchanged HEAD ==="
_reset
handle_pending_dev_pr_exists 545
assert_eq "TC-545-FRESH-001 returns to normal review eligibility" \
  "pending-review" "$_MOCK_LABEL_STATE"
assert_match "TC-545-FRESH-001 reads current provider mergeability" \
  "^chp_mergeable${US}42$"
assert_match "TC-545-FRESH-001 requeues pending-dev -> pending-review" \
  "^label_swap${US}545${US}pending-dev${US}pending-review$"
assert_no_match "TC-545-FRESH-001 never stalls from historical UNKNOWN" \
  "^mark_stalled"

echo
echo "=== TC-545-FRESH-002: UNKNOWN -> CONFLICTING at unchanged HEAD ==="
_reset
_MOCK_MERGEABLE="CONFLICTING"
handle_pending_dev_pr_exists 545
assert_eq "TC-545-FRESH-002 requeues through the normal review path" \
  "pending-review" "$_MOCK_LABEL_STATE"
assert_no_match "TC-545-FRESH-002 does not stall from the older UNKNOWN" \
  "^mark_stalled"
PF_STATE="" PF_HEAD="" PF_BRANCH="" PF_STATUS="" PF_ACTION=""
review_mergeability_preflight 42 \
  PF_STATE PF_HEAD PF_BRANCH PF_STATUS PF_ACTION
assert_eq "TC-545-FRESH-002 next canonical preflight selects conflict/rebase" \
  "conflict-rebase" "$PF_ACTION"

echo
echo "=== TC-545-FRESH-003: persistent UNKNOWN stays bounded and fail closed ==="
_reset
_MOCK_MERGEABLE="UNKNOWN"
handle_pending_dev_pr_exists 545
assert_eq "TC-545-FRESH-003 persistent fresh UNKNOWN stalls" \
  "stalled" "$_MOCK_LABEL_STATE"
assert_match "TC-545-FRESH-003 consulted the provider before stalling" \
  "^chp_mergeable${US}42$"
assert_eq "TC-545-FRESH-003 requires the full bounded UNKNOWN poll" \
  "$MERGEABLE_RETRIES" "$(grep -c "^chp_mergeable${US}42$" "$TRACE")"
assert_no_match "TC-545-FRESH-003 does not spend another review flip" \
  "^label_swap${US}545${US}pending-dev${US}pending-review$"

echo
echo "=== TC-545-FRESH-004: provider-read failure defers instead of fabricating UNKNOWN ==="
_reset
_MOCK_MERGEABLE_RC_SEQUENCE="1|1|1"
handle_pending_dev_pr_exists 545
route_rc=$?
assert_eq "TC-545-FRESH-004 returns the operational-defer contract" \
  "3" "$route_rc"
assert_eq "TC-545-FRESH-004 remains pending-dev for bounded operational retry" \
  "pending-dev" "$_MOCK_LABEL_STATE"
assert_no_match "TC-545-FRESH-004 does not stall on a failed read" \
  "^mark_stalled"
assert_eq "TC-545-FRESH-004 exhausts the bounded read attempts" \
  "$MERGEABLE_RETRIES" "$(grep -c "^chp_mergeable${US}42$" "$TRACE")"
assert_match "TC-545-FRESH-004 reaches the residual park" \
  "stale-verdict:${HEAD_H}"

echo
echo "=== TC-545-FRESH-005: substantive budget exhaustion is unchanged ==="
_reset
_MOCK_VERDICT="failed-substantive"
_MOCK_VERDICT_CAUSE=""
_MOCK_DEV_BUDGET_PRESENT=1
handle_pending_dev_pr_exists 545
assert_eq "TC-545-FRESH-005 retains substantive terminal stall" \
  "stalled" "$_MOCK_LABEL_STATE"
assert_no_match "TC-545-FRESH-005 does not refresh unrelated verdict causes" \
  "^chp_mergeable"

echo
echo "=== TC-545-FRESH-006: HEAD change during refresh requeues without stale evidence ==="
_reset
printf '%s' "$HEAD_OTHER" >"$PROVIDER_HEAD_FILE"
handle_pending_dev_pr_exists 545
assert_eq "TC-545-FRESH-006 changed HEAD requeues normal review" \
  "pending-review" "$_MOCK_LABEL_STATE"
assert_no_match "TC-545-FRESH-006 never stalls the new HEAD" \
  "^mark_stalled"
assert_no_match "TC-545-FRESH-006 does not read mergeability for a mismatched HEAD" \
  "^chp_mergeable"

echo
echo "=== TC-545-FRESH-007: HEAD changes after mergeability read ==="
_reset
_MOCK_PROVIDER_HEAD_AFTER_MERGEABLE="$HEAD_OTHER"
handle_pending_dev_pr_exists 545
assert_eq "TC-545-FRESH-007 post-read HEAD race requeues normal review" \
  "pending-review" "$_MOCK_LABEL_STATE"
assert_match "TC-545-FRESH-007 reads mergeability between the two snapshots" \
  "^chp_mergeable${US}42$"
assert_eq "TC-545-FRESH-007 takes both provider snapshots" \
  "2" "$(grep -c "^chp_pr_view${US}42${US}state,headRefOid,headRefName$" "$TRACE")"
assert_match "TC-545-FRESH-007 second snapshot rejects the stale MERGEABLE token" \
  "PR HEAD changed during same-HEAD mergeability revalidation"
assert_eq "TC-545-FRESH-007 file-backed provider fixture advanced to OTHER" \
  "$HEAD_OTHER" "$(cat "$PROVIDER_HEAD_FILE")"
assert_no_match "TC-545-FRESH-007 never binds MERGEABLE to the new HEAD" \
  "^mark_stalled"

echo
echo "=== TC-545-FRESH-008: one UNKNOWN read settles to MERGEABLE in the bounded poll ==="
_reset
_MOCK_MERGEABLE_SEQUENCE="UNKNOWN|MERGEABLE"
handle_pending_dev_pr_exists 545
assert_eq "TC-545-FRESH-008 returns to normal review eligibility" \
  "pending-review" "$_MOCK_LABEL_STATE"
assert_eq "TC-545-FRESH-008 polls past the initial unsettled read" \
  "2" "$(grep -c "^chp_mergeable${US}42$" "$TRACE")"
assert_no_match "TC-545-FRESH-008 never stalls on one UNKNOWN read" \
  "^mark_stalled"

echo
echo "=== TC-545-FRESH-009: freshness requeue is capped per session and HEAD ==="
_reset
for tick in 1 2; do
  handle_pending_dev_pr_exists 545
  assert_eq "TC-545-FRESH-009 requeue ${tick} remains review-eligible" \
    "pending-review" "$_MOCK_LABEL_STATE"
  _MOCK_LABEL_STATE="pending-dev"
done
handle_pending_dev_pr_exists 545
assert_eq "TC-545-FRESH-009 stalls after REVIEW_RETRY_LIMIT successful requeues" \
  "stalled" "$_MOCK_LABEL_STATE"
assert_eq "TC-545-FRESH-009 records exactly the configured reservation budget" \
  "$REVIEW_RETRY_LIMIT" \
  "$(itp_list_comments 545 \
      | jq '[.[].body | select(startswith("<!-- same-head-mergeability-requeue:"))] | length')"
assert_eq "TC-545-FRESH-009 records completion evidence for successful requeues" \
  "$REVIEW_RETRY_LIMIT" \
  "$(itp_list_comments 545 \
      | jq '[.[].body | select(contains("review-aware-flip:non-substantive") and contains("source=same-head-refresh"))] | length')"
assert_eq "TC-545-FRESH-009 emits one terminal stall" \
  "1" "$(grep -c "^mark_stalled" "$TRACE")"

echo
echo "=== TC-545-FRESH-010: repeated label failure consumes bounded reservations ==="
_reset
_MOCK_LABEL_SWAP_RC=1
for tick in 1 2; do
  handle_pending_dev_pr_exists 545
  route_rc=$?
  assert_eq "TC-545-FRESH-010 failed label tick ${tick} returns operational defer" \
    "3" "$route_rc"
done
handle_pending_dev_pr_exists 545
assert_eq "TC-545-FRESH-010 failed transitions converge to stalled at the cap" \
  "stalled" "$_MOCK_LABEL_STATE"
comments_json=$(itp_list_comments 545)
assert_eq "TC-545-FRESH-010 posts one durable reservation per failed attempt" \
  "$REVIEW_RETRY_LIMIT" "$(jq '[.[].body | select(startswith("<!-- same-head-mergeability-requeue:"))] | length' \
    <<<"$comments_json")"
assert_eq "TC-545-FRESH-010 records no completed flip before label success" \
  "0" "$(jq '[.[].body | select(contains("source=same-head-refresh"))] | length' \
    <<<"$comments_json")"
assert_eq "TC-545-FRESH-010 never aborts but stalls exactly once" \
  "1" "$(grep -c "^mark_stalled" "$TRACE")"

echo
echo "=== TC-545-FRESH-011: reservation-count read failure cannot reset the cap ==="
_reset
itp_post_comment 545 "$(printf '%s\n%s' \
  "<!-- same-head-mergeability-requeue: issue=545 head=${HEAD_H} session=sid-545 flip=1 status=MERGEABLE -->" \
  "PR #42 HEAD \`${HEAD_H}\` now has fresh provider mergeability \`MERGEABLE\`. Re-routing to review so the normal preflight and final gates act on current evidence.")"
: >"$TRACE"
_MOCK_INTENT_COUNT_READ_RC=1
handle_pending_dev_pr_exists 545
route_rc=$?
assert_eq "TC-545-FRESH-011 failed budget read returns operational defer" \
  "3" "$route_rc"
assert_eq "TC-545-FRESH-011 failed budget read leaves pending-dev" \
  "pending-dev" "$_MOCK_LABEL_STATE"
assert_no_match "TC-545-FRESH-011 cannot requeue from a fabricated zero count" \
  "^label_swap"
assert_no_match "TC-545-FRESH-011 does not stall from unreadable accounting" \
  "^mark_stalled"

echo
echo "=== TC-545-FRESH-012: completion-write failure cannot escape the cap ==="
_reset
_MOCK_COMPLETION_POST_RC=1
for tick in 1 2; do
  handle_pending_dev_pr_exists 545
  assert_eq "TC-545-FRESH-012 requeue ${tick} succeeds from its durable intent" \
    "pending-review" "$_MOCK_LABEL_STATE"
  _MOCK_LABEL_STATE="pending-dev"
done
handle_pending_dev_pr_exists 545
assert_eq "TC-545-FRESH-012 completion-write outage still converges at the cap" \
  "stalled" "$_MOCK_LABEL_STATE"
comments_json=$(itp_list_comments 545)
assert_eq "TC-545-FRESH-012 retains the full reservation budget" \
  "$REVIEW_RETRY_LIMIT" "$(jq '[.[].body | select(startswith("<!-- same-head-mergeability-requeue:"))] | length' \
    <<<"$comments_json")"
assert_eq "TC-545-FRESH-012 has no completion markers" \
  "0" "$(jq '[.[].body | select(contains("source=same-head-refresh"))] | length' \
    <<<"$comments_json")"
assert_eq "TC-545-FRESH-012 stalls exactly once" \
  "1" "$(grep -c "^mark_stalled" "$TRACE")"

echo
echo "=== TC-545-FRESH-013: duplicate reservation races count once ==="
_reset
reservation_marker="<!-- same-head-mergeability-requeue: issue=545 head=${HEAD_H} session=sid-545 flip=1 status=MERGEABLE -->"
completion_marker="<!-- review-aware-flip:non-substantive cause=mergeable-unknown session=sid-545 head=${HEAD_H} source=same-head-refresh flip=1 -->"
ordinary_marker="<!-- review-aware-flip:non-substantive cause=bot-timeout session=sid-545 -->"
itp_post_comment 545 "$reservation_marker"
itp_post_comment 545 "$reservation_marker"
itp_post_comment 545 "$completion_marker"
itp_post_comment 545 "$completion_marker"
itp_post_comment 545 "$ordinary_marker"
assert_eq "TC-545-FRESH-013 duplicate intent ordinals consume one reservation" \
  "1" "$(_same_head_requeue_intent_count 545 sid-545 "$HEAD_H")"
assert_eq "TC-545-FRESH-013 reservation/completion pair plus ordinary flip count as two attempts" \
  "2" "$(count_review_aware_flips 545 sid-545)"

echo
echo "=== TC-545-FRESH-014: completed-session routing inherits freshness reservations ==="
_reset
itp_post_comment 545 \
  "<!-- same-head-mergeability-requeue: issue=545 head=${HEAD_H} session=sid-545 flip=1 status=MERGEABLE -->"
itp_post_comment 545 \
  "<!-- review-aware-flip:non-substantive cause=mergeable-unknown session=sid-545 head=${HEAD_H} source=same-head-refresh flip=1 -->"
itp_post_comment 545 \
  "<!-- same-head-mergeability-requeue: issue=545 head=${HEAD_H} session=sid-545 flip=2 status=MERGEABLE -->"
: >"$TRACE"
_MOCK_COMPLETED_RC=0
handle_pending_dev_pr_exists 545
assert_eq "TC-545-FRESH-014 completed session stalls at the shared cap" \
  "stalled" "$_MOCK_LABEL_STATE"
assert_no_match "TC-545-FRESH-014 cannot requeue after reservations spend the cap" \
  "^label_swap${US}545${US}pending-dev${US}pending-review$"

echo
echo "=== TC-545-FRESH-015: completed-session count read failure defers ==="
_reset
_MOCK_COMPLETED_RC=0
_MOCK_FLIP_COUNT_READ_RC=1
handle_pending_dev_pr_exists 545
route_rc=$?
assert_eq "TC-545-FRESH-015 returns operational defer" "3" "$route_rc"
assert_eq "TC-545-FRESH-015 leaves state unchanged" \
  "pending-dev" "$_MOCK_LABEL_STATE"
assert_no_match "TC-545-FRESH-015 cannot requeue from fabricated zero" \
  "^label_swap"
assert_no_match "TC-545-FRESH-015 cannot stall from unreadable accounting" \
  "^mark_stalled"

echo
echo "=== TC-545-FRESH-016: malformed comment accounting fails closed ==="
_reset
_MOCK_COMMENTS_JSON_OVERRIDE='[{"body":42}]'
count_output=$(count_review_aware_flips 545 sid-545)
count_rc=$?
assert_eq "TC-545-FRESH-016 malformed comment rows return nonzero" \
  "nonzero" "$([[ "$count_rc" -ne 0 ]] && printf 'nonzero' || printf 'zero')"
assert_eq "TC-545-FRESH-016 malformed comments never fabricate zero" \
  "" "$count_output"

echo
echo "=== TC-545-FRESH-017: direct completed-session defer does not abort the tick ==="
direct_route_snippet="$TMPDIR_T/direct-completed-route.sh"
direct_route_trace="$TMPDIR_T/direct-completed-route.trace"
awk '
  /^    _completed_route_rc=0$/ { copy=1 }
  copy { print }
  copy && /^    continue$/ { exit }
' "$DISPATCH_TICK" >"$direct_route_snippet"
: >"$direct_route_trace"
DIRECT_ROUTE_TRACE="$direct_route_trace" \
  bash -uo pipefail -c '
    handle_completed_session_routing() {
      printf "route:%s\n" "$1" >>"$DIRECT_ROUTE_TRACE"
      [[ "$1" == "545" ]] && return 3
      return 0
    }
    JUST_DISPATCHED=()
    for issue_num in 545 546; do
      session_id="sid-${issue_num}"
      _session_end_iso="2026-08-13T00:00:00Z"
      # shellcheck disable=SC1090
      source "$1"
    done
    printf "just:%s\n" "${JUST_DISPATCHED[*]}" >>"$DIRECT_ROUTE_TRACE"
  ' _ "$direct_route_snippet"
direct_route_rc=$?
assert_eq "TC-545-FRESH-017 direct caller handles operational defer" \
  "0" "$direct_route_rc"
assert_eq "TC-545-FRESH-017 later issues still run and only handled routes are exempted" \
  $'route:545\nroute:546\njust:546' "$(cat "$direct_route_trace")"

echo
echo "=== TC-545-TRACE-001: two UNKNOWN reviews then MERGEABLE on fixed HEAD ==="
_reset
_MOCK_NONSUB_PRESENT=0
_MOCK_MERGEABLE="UNKNOWN"

PF_STATE="" PF_HEAD="" PF_BRANCH="" PF_STATUS="" PF_ACTION=""
review_mergeability_preflight 42 \
  PF_STATE PF_HEAD PF_BRANCH PF_STATUS PF_ACTION
assert_eq "TC-545-TRACE-001 first review preflight observes UNKNOWN" \
  "mergeable-unknown" "$PF_ACTION"
_rec review_outcome UNKNOWN
handle_pending_dev_pr_exists 545
assert_eq "TC-545-TRACE-001 first recovery records marker and requeues" \
  "pending-review|1" "$_MOCK_LABEL_STATE|$_MOCK_NONSUB_PRESENT"

_MOCK_LABEL_STATE="pending-dev"
review_mergeability_preflight 42 \
  PF_STATE PF_HEAD PF_BRANCH PF_STATUS PF_ACTION
assert_eq "TC-545-TRACE-001 second review preflight observes UNKNOWN" \
  "mergeable-unknown" "$PF_ACTION"
_rec review_outcome UNKNOWN

_MOCK_MERGEABLE="MERGEABLE"
handle_pending_dev_pr_exists 545
assert_eq "TC-545-TRACE-001 delayed provider transition avoids terminal stall" \
  "pending-review" "$_MOCK_LABEL_STATE"
assert_no_match "TC-545-TRACE-001 trace contains no stall" "^mark_stalled"

review_mergeability_preflight 42 \
  PF_STATE PF_HEAD PF_BRANCH PF_STATUS PF_ACTION
assert_eq "TC-545-TRACE-001 unchanged HEAD reaches normal review preflight" \
  "proceed|$HEAD_H" "$PF_ACTION|$PF_HEAD"
assert_eq "TC-545-TRACE-001 records two historical UNKNOWN review outcomes" \
  "2" "$(grep -c "^review_outcome${US}UNKNOWN$" "$TRACE")"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
