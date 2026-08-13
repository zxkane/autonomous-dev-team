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

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID="test-545-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5
export MERGEABLE_RETRIES=1
export MERGEABLE_RETRY_DELAY_SECONDS=0

US=$'\037'
HEAD_H="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_OTHER="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT
TRACE="$TMPDIR_T/trace"
PROVIDER_HEAD_FILE="$TMPDIR_T/provider-head"
: >"$TRACE"

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
  [[ "$_MOCK_NONSUB_PRESENT" == "1" ]] \
    && body+=" self-heal-non-substantive:${_MOCK_HEAD}"
  [[ "$_MOCK_DEV_BUDGET_PRESENT" == "1" ]] \
    && body+=" crashed-session-retry:${_MOCK_HEAD}"
  printf '[{"body":%s}]\n' "$(jq -Rn --arg body "$body" '$body')"
}
itp_post_comment() {
  _rec itp_post_comment "$@"
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
is_session_completed() { return "$_MOCK_COMPLETED_RC"; }
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
  _rec chp_mergeable "$@"
  [[ "$_MOCK_MERGEABLE_RC" == "0" ]] || return "$_MOCK_MERGEABLE_RC"
  if [[ -n "$_MOCK_PROVIDER_HEAD_AFTER_MERGEABLE" ]]; then
    printf '%s' "$_MOCK_PROVIDER_HEAD_AFTER_MERGEABLE" >"$PROVIDER_HEAD_FILE"
  fi
  printf '%s\n' "$_MOCK_MERGEABLE"
}
label_swap() {
  _rec label_swap "$@"
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
handle_completed_session_routing() { _rec handle_completed_session_routing "$@"; }

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
  _MOCK_SNAPSHOT_RC=0
  _MOCK_PROVIDER_HEAD_AFTER_MERGEABLE=""
  _MOCK_LABEL_STATE="pending-dev"
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
assert_no_match "TC-545-FRESH-003 does not spend another review flip" \
  "^label_swap${US}545${US}pending-dev${US}pending-review$"

echo
echo "=== TC-545-FRESH-004: provider-read failure defers instead of fabricating UNKNOWN ==="
_reset
_MOCK_MERGEABLE_RC=1
handle_pending_dev_pr_exists 545
route_rc=$?
assert_eq "TC-545-FRESH-004 returns the operational-defer contract" \
  "3" "$route_rc"
assert_eq "TC-545-FRESH-004 remains pending-dev for bounded operational retry" \
  "pending-dev" "$_MOCK_LABEL_STATE"
assert_no_match "TC-545-FRESH-004 does not stall on a failed read" \
  "^mark_stalled"
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
