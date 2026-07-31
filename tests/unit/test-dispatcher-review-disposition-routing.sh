#!/bin/bash
# Dispatcher routing for pre-fan-out disposition evidence (issue #540).

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
LIVENESS_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-liveness.sh"
TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; FAIL=$((FAIL + 1))
    echo "      expected=[$expected]"; echo "      actual=  [$actual]"
  fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; FAIL=$((FAIL + 1))
    echo "      missing=[$needle]"
  fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; FAIL=$((FAIL + 1))
    echo "      unexpected=[$needle]"
  fi
}

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID="test-disposition-routing-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5
export REVIEW_RETRY_LIMIT=2

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIVENESS_LIB"
source "$LIB"
set +e
eval "$(declare -f classify_recent_review_verdict \
  | sed '1s/classify_recent_review_verdict/_real_classify_recent_review_verdict/')"

HEAD_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
COMMENTS="[]"
TRACE=""
CURRENT_HEAD="$HEAD_A"
ROUTER_HEAD=""
VERDICT="failed-substantive"
CAUSE=""
DEV_ACTIONABLE="true"
USE_REAL_CLASSIFIER=0
SESSION_END="2026-07-30T00:00:00Z"
SESSION_ID="sid-540"
SESSION_COMPLETED=1
FLIP_COUNT=0
ATTEMPT_PRESENT=0
LEGACY_LAST_HEAD=""
STRICT_READ_FAIL=0
CAPTURE_POSTS=0

_append_comment() {
  local body="$1" kind="${2:-self}"
  COMMENTS=$(jq -c --arg body "$body" --arg kind "$kind" '
    . + [{
      id: (length + 1),
      author: (if $kind == "self" then "review-app[bot]" else "human" end),
      authorKind: $kind,
      body: $body,
      createdAt: ("2026-07-30T00:00:" + ((length + 1) | tostring | if length == 1 then "0" + . else . end) + "Z")
    }]
  ' <<<"$COMMENTS")
}

_set_disposition() {
  local head="$1" result="$2"
  _append_comment "<!-- review-disposition: issue=540 head=${head} phase=pre-fanout result=${result} -->"
}

_reset() {
  COMMENTS="[]"
  TRACE=""
  CURRENT_HEAD="$HEAD_A"
  ROUTER_HEAD=""
  VERDICT="failed-substantive"
  CAUSE=""
  DEV_ACTIONABLE="true"
  USE_REAL_CLASSIFIER=0
  SESSION_END="2026-07-30T00:00:00Z"
  SESSION_ID="sid-540"
  SESSION_COMPLETED=1
  FLIP_COUNT=0
  ATTEMPT_PRESENT=0
  LEGACY_LAST_HEAD=""
  STRICT_READ_FAIL=0
  CAPTURE_POSTS=0
}

fetch_pr_for_issue() {
  local head="$CURRENT_HEAD"
  if [[ "${2:-}" == *body* && -n "$ROUTER_HEAD" ]]; then
    head="$ROUTER_HEAD"
  fi
  jq -cn --arg h "$head" '{number:42,headRefOid:$h,body:"Closes #540"}'
}
itp_list_comments() {
  if [[ "$STRICT_READ_FAIL" == "1" && "${ITP_REQUIRE_SELF_AUTHOR:-0}" == "1" ]]; then
    return 1
  fi
  local comments="$COMMENTS"
  if [[ "$ATTEMPT_PRESENT" == "1" ]]; then
    comments=$(jq -c --arg h "$CURRENT_HEAD" '
      . + [{
        id:(length+1), author:"dispatcher-app[bot]", authorKind:"self",
        body:("<!-- no-progress-substantive-attempt:" + $h + " -->"),
        createdAt:"2026-07-30T00:01:00Z"
      }]
    ' <<<"$comments")
  fi
  printf '%s\n' "$comments"
}
itp_post_comment() {
  TRACE+="post:$2"$'\n'
  if [[ "$CAPTURE_POSTS" == "1" ]]; then
    _append_comment "$2"
  fi
}
itp_transition_state() {
  TRACE+="transition:$2>$3"$'\n'
}
last_reviewed_head() {
  if [[ -n "$LEGACY_LAST_HEAD" ]]; then
    printf '%s' "$LEGACY_LAST_HEAD"
    return
  fi
  jq -r '
    [.[] | .body
      | capture("Reviewed HEAD: `(?<sha>[0-9a-fA-F]{7,40})`")
      | .sha]
    | last // empty
  ' <<<"$COMMENTS"
}
extract_dev_session_id() { printf '%s' "$SESSION_ID"; }
is_session_completed() {
  [[ "$SESSION_COMPLETED" == "1" ]] || return 1
  [[ -n "${2:-}" ]] && printf -v "$2" '%s' "completed"
  [[ -n "${3:-}" ]] && printf -v "$3" '%s' "$SESSION_END"
  return 0
}
classify_recent_review_verdict() {
  if [[ "$USE_REAL_CLASSIFIER" == "1" ]]; then
    _real_classify_recent_review_verdict "$@"
    return
  fi
  printf -v "$3" '%s' "$VERDICT"
  printf -v "$4" '%s' "$CAUSE"
  [[ -n "${5:-}" ]] && printf -v "$5" '%s' "$DEV_ACTIONABLE"
}
count_review_aware_flips() { printf '%s' "$FLIP_COUNT"; }
dev_report_bot_unfixable() { return 1; }
count_frozen_convergence_rounds() { printf '0'; }
may_stall_now() { return 0; }
acquire_dispatch_marker() { return 0; }
release_dispatch_marker() { TRACE+="release:$1:$2"$'\n'; }
dispatch_marker_confirm_launched() { TRACE+="confirm:$1:$2"$'\n'; }
post_dispatch_token() { TRACE+="token:$2"$'\n'; }
dispatch() { TRACE+="dispatch:$1:$2"$'\n'; }
mark_stalled() { TRACE+="stalled:$1"$'\n'; }
_reset_session_log() { TRACE+="reset-log:$1"$'\n'; }
log() { :; }
is_within_grace_period() { return 1; }
_liveness_wrapper_alive() { return 1; }
itp_read_task() { printf '%s\n' '{"labels":["pending-dev"]}'; }
resolve_operator_mention() { printf '%s' '@operator'; }

echo "=== TC-E2E-REBASE-027..031: pending-dev PR-exists routing ==="
_reset
_set_disposition "$HEAD_A" "conflict-rebase"
handle_pending_dev_pr_exists 540
assert_contains "TC-E2E-REBASE-027 conflict disposition dispatches one dev-new" \
  "dispatch:dev-new:540" "$TRACE"
assert_eq "TC-E2E-REBASE-027 conflict disposition dispatch count is one" \
  "1" "$(grep -c '^dispatch:dev-new:540$' <<<"$TRACE")"
assert_not_contains "TC-E2E-REBASE-027 conflict disposition avoids first-review shortcut" \
  "transition:pending-dev>pending-review" "$TRACE"

_reset
_set_disposition "$HEAD_A" "mergeable-unknown"
VERDICT="failed-non-substantive"
CAUSE="mergeable-unknown"
handle_pending_dev_pr_exists 540
assert_contains "TC-E2E-REBASE-028 unknown disposition requeues review" \
  "transition:pending-dev>pending-review" "$TRACE"
assert_not_contains "TC-E2E-REBASE-028 unknown disposition dispatches no dev" \
  "dispatch:" "$TRACE"

_reset
_set_disposition "$HEAD_A" "mergeable-unknown"
VERDICT="failed-non-substantive"
CAUSE="mergeable-unknown"
FLIP_COUNT=2
handle_pending_dev_pr_exists 540
assert_contains "TC-E2E-REBASE-028 unknown disposition reaches retry-cap stall" \
  "stalled:540" "$TRACE"
assert_not_contains "TC-E2E-REBASE-028 capped unknown route does not requeue again" \
  "transition:pending-dev>pending-review" "$TRACE"

_reset
_set_disposition "$HEAD_A" "conflict-rebase"
ATTEMPT_PRESENT=1
handle_pending_dev_pr_exists 540
assert_contains "TC-E2E-REBASE-034 unresolved same-HEAD rebase reaches INV-85 stall" \
  "stalled:540" "$TRACE"
assert_not_contains "TC-E2E-REBASE-034 unresolved rebase gets no second dev-new" \
  "dispatch:" "$TRACE"

_reset
CURRENT_HEAD="$HEAD_B"
_set_disposition "$HEAD_A" "conflict-rebase"
handle_pending_dev_pr_exists 540
assert_contains "TC-E2E-REBASE-029 stale disposition permits first review of new HEAD" \
  "transition:pending-dev>pending-review" "$TRACE"
assert_not_contains "TC-E2E-REBASE-029 stale disposition never dispatches same-head dev" \
  "dispatch:" "$TRACE"

_reset
_set_disposition "$HEAD_A" "conflict-rebase"
ROUTER_HEAD="$HEAD_B"
handle_pending_dev_pr_exists 540
assert_contains "TC-E2E-REBASE-029 mid-route HEAD change requeues current HEAD" \
  "transition:pending-dev>pending-review" "$TRACE"
assert_not_contains "TC-E2E-REBASE-029 stale verdict does not dispatch dev against new HEAD" \
  "dispatch:" "$TRACE"
assert_not_contains "TC-E2E-REBASE-029 stale verdict does not record a new-HEAD attempt" \
  "no-progress-substantive-attempt:${HEAD_B}" "$TRACE"

for recovery_shape in self-heal crashed-session; do
  _reset
  _set_disposition "$HEAD_A" "conflict-rebase"
  SESSION_COMPLETED=0
  [[ "$recovery_shape" == "self-heal" ]] && SESSION_ID=""
  ROUTER_HEAD="$HEAD_B"
  handle_pending_dev_pr_exists 540
  assert_contains "TC-E2E-REBASE-058 ${recovery_shape} recovery requeues a changed HEAD" \
    "transition:pending-dev>pending-review" "$TRACE"
  assert_not_contains "TC-E2E-REBASE-058 ${recovery_shape} recovery never dispatches against stale HEAD" \
    "dispatch:" "$TRACE"
  assert_not_contains "TC-E2E-REBASE-058 ${recovery_shape} recovery records no stale-HEAD attempt" \
    "no-progress-substantive-attempt:${HEAD_A}" "$TRACE"
done

_reset
_append_comment "<!-- review-disposition: issue=540 head=abcdef0 phase=pre-fanout result=conflict-rebase -->"
handle_pending_dev_pr_exists 540
assert_contains "TC-E2E-REBASE-030 malformed disposition keeps first-review behavior" \
  "transition:pending-dev>pending-review" "$TRACE"

_reset
_append_comment "Reviewed HEAD: \`${HEAD_A}\` (human-authored lookalike)" "human"
handle_pending_dev_pr_exists 540
assert_contains "TC-E2E-REBASE-030 human Reviewed HEAD lookalike keeps first-review behavior" \
  "transition:pending-dev>pending-review" "$TRACE"
assert_not_contains "TC-E2E-REBASE-030 human Reviewed HEAD lookalike never dispatches dev" \
  "dispatch:" "$TRACE"

_reset
_append_comment "Reviewed HEAD: \`${HEAD_A}\` (issue #540, session \`legacy\`)"
handle_pending_dev_pr_exists 540
assert_contains "TC-E2E-REBASE-031 legacy Reviewed HEAD still reaches substantive router" \
  "dispatch:dev-new:540" "$TRACE"

_reset
ATTEMPT_PRESENT=1
ROUTING_READ_FILE=$(mktemp)
_latest_review_routing_head() {
  printf 'read\n' >>"$ROUTING_READ_FILE"
  [[ "$(wc -l <"$ROUTING_READ_FILE")" -eq 1 ]] && printf '%s' "$HEAD_A"
}
handle_pending_dev_pr_exists 540
assert_eq "TC-E2E-REBASE-034 routing evidence is read exactly once" \
  "1" "$(wc -l <"$ROUTING_READ_FILE")"
assert_contains "TC-E2E-REBASE-034 pinned routing head still reaches INV-85 stall" \
  "stalled:540" "$TRACE"
rm "$ROUTING_READ_FILE"

_reset
_set_disposition "$HEAD_A" "conflict-rebase"
_append_comment "<!-- review-verdict: failed-substantive -->"
_append_comment "<!-- no-progress-substantive-attempt:${HEAD_A} session=sid-540 -->"
_append_comment "<!-- review-verdict: failed-substantive -->"
USE_REAL_CLASSIFIER=1
SESSION_END="2026-07-30T00:00:03Z"
handle_pending_dev_pr_exists 540
assert_contains "TC-E2E-REBASE-048 fresh post-session trailer reaches INV-85 stall with real classifier" \
  "stalled:540" "$TRACE"
assert_not_contains "TC-E2E-REBASE-048 real classifier avoids INV-12 no-verdict handoff" \
  "INV-12-completed" "$TRACE"

echo
echo "=== TC-E2E-REBASE-054: strict routing-evidence read failure defers to INV-128 ==="
_reset
_set_disposition "$HEAD_A" "conflict-rebase"
STRICT_READ_FAIL=1
handle_pending_dev_pr_exists 540
route_rc=$?
assert_eq "TC-E2E-REBASE-054 strict evidence-read failure returns operational defer" \
  "3" "$route_rc"
assert_not_contains "TC-E2E-REBASE-054 failure never takes first-review shortcut" \
  "transition:pending-dev>pending-review" "$TRACE"
assert_not_contains "TC-E2E-REBASE-054 failure never dispatches dev" \
  "dispatch:" "$TRACE"
assert_not_contains "TC-E2E-REBASE-054 failure never records an INV-85 attempt" \
  "no-progress-substantive-attempt:" "$TRACE"

tick_route=$(sed -n '620,640p' "$TICK")
assert_contains "TC-E2E-REBASE-054 dispatcher handles defer without JUST_DISPATCHED" \
  '_pending_pr_route_rc" -eq 3' "$tick_route"

STRICT_READ_FAIL=0
CAPTURE_POSTS=1
JUST_DISPATCHED=""
_liveness_evaluate_issue 540 issue pending-dev 1 2
_liveness_evaluate_issue 540 issue pending-dev 1 2
assert_contains "TC-E2E-REBASE-054 unchanged operational defer reaches INV-128 bound" \
  "transition:pending-dev>stalled" "$TRACE"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
