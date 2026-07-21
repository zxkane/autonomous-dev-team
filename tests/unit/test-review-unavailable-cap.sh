#!/bin/bash
# test-review-unavailable-cap.sh - issue #525 / INV-144.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCHER_DIR="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB="$DISPATCHER_DIR/lib-review-unavailable-cap.sh"
WRAPPER="$DISPATCHER_DIR/autonomous-review.sh"
CONF="$DISPATCHER_DIR/autonomous.conf.example"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"
STATE_MACHINE="$PROJECT_ROOT/docs/pipeline/state-machine.md"
FLOW="$PROJECT_ROOT/docs/pipeline/review-agent-flow.md"
HANDOFFS="$PROJECT_ROOT/docs/pipeline/handoffs.md"
TRANSITIONS="$PROJECT_ROOT/docs/pipeline/transitions.json"
GUARD_MAP="$PROJECT_ROOT/docs/pipeline/spec-guard-map.json"
CI="$PROJECT_ROOT/.github/workflows/ci.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ok() {
  echo -e "  ${GREEN}PASS${NC}: $1"
  PASS=$((PASS + 1))
}

bad() {
  echo -e "  ${RED}FAIL${NC}: $1"
  FAIL=$((FAIL + 1))
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    ok "$desc"
  else
    bad "$desc (expected=[$expected], actual=[$actual])"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    ok "$desc"
  else
    bad "$desc (missing=[$needle])"
  fi
}

assert_file_contains() {
  local desc="$1" file="$2" needle="$3"
  if [[ -f "$file" ]] && grep -qF "$needle" "$file"; then
    ok "$desc"
  else
    bad "$desc ($file missing [$needle])"
  fi
}

echo "=== TC-RUC setup ==="
if [[ ! -f "$LIB" ]]; then
  bad "dedicated unavailable-cap library exists"
  echo
  echo "=== Summary ==="
  echo "Passed: $PASS"
  echo "Failed: $FAIL"
  exit 1
fi

# ITP seam must precede the ITP-consuming breaker library in this shell context.
# shellcheck source=/dev/null
source "$DISPATCHER_DIR/lib-issue-provider.sh"
# shellcheck source=/dev/null
source "$LIB"

echo
echo "=== TC-RUC-001..008 marker helpers ==="
marker=$(_review_unavailable_marker 525 deadbeef 2)
assert_eq "TC-RUC-001 marker round-trip" "2" "$(_review_unavailable_parse_count "$marker")"
assert_eq "TC-RUC-002 malformed marker parses as zero" "0" \
  "$(_review_unavailable_parse_count '<!-- broken -->')"
assert_eq "TC-RUC-002b missing marker starts at one" "1" \
  "$(_review_unavailable_next_count '')"
unknown_marker=$(_review_unavailable_marker 525 "" 4)
assert_contains "TC-RUC-003 empty head uses unknown" "$unknown_marker" "head=unknown"
reset_marker=$(_review_unavailable_reset_marker 525 "")
assert_contains "TC-RUC-004 reset marker records round zero" "$reset_marker" "round=0"
assert_contains "TC-RUC-004b reset marker preserves unknown head" "$reset_marker" "head=unknown"
assert_eq "TC-RUC-005 different head does not reset" "5" \
  "$(_review_unavailable_next_count "$unknown_marker")"
assert_eq "TC-RUC-008 reset marker makes next count one" "1" \
  "$(_review_unavailable_next_count "$reset_marker")"

trip_fixture='[
  {"authorKind":"self","createdAt":"2026-07-21T10:00:00Z","body":"<!-- dispatcher-review-unavailable-breaker: issue=525 head=aaa round=3 -->"},
  {"authorKind":"self","createdAt":"2026-07-21T10:01:00Z","body":"## Review-unavailable-cap circuit-breaker tripped - halting repeated re-dispatch (`reason=review-unavailable-cap`, INV-144)\n\n<!-- dispatcher-review-unavailable-breaker: issue=525 head=aaa round=3 -->"}
]'
assert_eq "TC-RUC-006 trip cutoff excludes pre-trip marker" "" \
  "$(_review_unavailable_prior_marker "$trip_fixture" 525 "")"

removal_cutoff_fixture='[
  {"id":62,"authorKind":"self","createdAt":"2026-07-21T10:02:00Z","body":"<!-- dispatcher-review-unavailable-breaker: issue=525 head=old round=2 -->"}
]'
assert_eq "TC-RUC-006j stalled-removal cutoff excludes pre-rearm marker" "" \
  "$(_review_unavailable_prior_marker "$removal_cutoff_fixture" 525 "2026-07-21T10:03:00Z")"

forgery_fixture='[
  {"authorKind":"human","createdAt":"2026-07-21T10:00:00Z","body":"<!-- dispatcher-review-unavailable-breaker: issue=525 head=aaa round=99 -->"},
  {"authorKind":"self","createdAt":"2026-07-21T10:01:00Z","body":"<!-- dispatcher-review-unavailable-breaker: issue=525 head=bbb round=2 -->"},
  {"authorKind":"bot","createdAt":"2026-07-21T10:02:00Z","body":"<!-- dispatcher-review-unavailable-breaker: issue=525 head=foreign-bot round=77 -->"},
  {"authorKind":"self","createdAt":"2026-07-21T10:03:00Z","body":"<!-- dispatcher-review-unavailable-breaker: issue=999 head=wrong-issue round=66 -->"},
  {"authorKind":"self","createdAt":"2026-07-21T10:04:00Z","body":"quoted <!-- dispatcher-review-unavailable-breaker: issue=525 head=aaa round=88 --> text"}
]'
assert_eq "TC-RUC-007 human, foreign-bot, wrong-issue, and quoted markers are ignored" \
  "<!-- dispatcher-review-unavailable-breaker: issue=525 head=bbb round=2 -->" \
  "$(_review_unavailable_prior_marker "$forgery_fixture" 525 "")"

quoted_trip_fixture='[
  {"id":60,"authorKind":"self","createdAt":"2026-07-21T10:02:30Z","body":"<!-- dispatcher-review-unavailable-breaker: issue=525 head=bbb round=4 -->"},
  {"id":61,"authorKind":"self","createdAt":"2026-07-21T10:02:31Z","body":"> ## Review-unavailable-cap circuit-breaker tripped - halting repeated re-dispatch (`reason=review-unavailable-cap`, INV-144)\n>\n> quoted operator context"}
]'
assert_eq "TC-RUC-007a quoted trip prose is not a cutoff" \
  "<!-- dispatcher-review-unavailable-breaker: issue=525 head=bbb round=4 -->" \
  "$(_review_unavailable_prior_marker "$quoted_trip_fixture" 525 "")"

same_second_fixture='[
  {"id":70,"authorKind":"self","createdAt":"2026-07-21T10:03:00Z","body":"<!-- dispatcher-review-unavailable-breaker: issue=525 head=ccc round=3 -->"},
  {"id":71,"authorKind":"self","createdAt":"2026-07-21T10:03:00Z","body":"<!-- dispatcher-review-unavailable-breaker: issue=525 head=ccc round=0 -->"}
]'
assert_eq "TC-RUC-007b comment id breaks same-second threshold/reset ties" \
  "<!-- dispatcher-review-unavailable-breaker: issue=525 head=ccc round=0 -->" \
  "$(_review_unavailable_prior_marker "$same_second_fixture" 525 "")"

same_second_trip_fixture='[
  {"id":70,"authorKind":"self","createdAt":"2026-07-21T10:04:00Z","body":"## Review-unavailable-cap circuit-breaker tripped - halting repeated re-dispatch (`reason=review-unavailable-cap`, INV-144)\n"},
  {"id":69,"authorKind":"self","createdAt":"2026-07-21T10:04:00Z","body":"<!-- dispatcher-review-unavailable-breaker: issue=525 head=old round=9 -->"},
  {"id":71,"authorKind":"self","createdAt":"2026-07-21T10:04:00Z","body":"<!-- dispatcher-review-unavailable-breaker: issue=525 head=new round=1 -->"}
]'
assert_eq "TC-RUC-007c trip cutoff uses id within the same second" \
  "<!-- dispatcher-review-unavailable-breaker: issue=525 head=new round=1 -->" \
  "$(_review_unavailable_prior_marker "$same_second_trip_fixture" 525 "")"

echo
echo "=== TC-RUC-010..014 configuration ==="
unset REVIEW_UNAVAILABLE_CAP
assert_eq "TC-RUC-010 unset defaults to three" "3" \
  "$(_review_unavailable_threshold 2>/dev/null)"
REVIEW_UNAVAILABLE_CAP=0
assert_eq "TC-RUC-011 zero is accepted" "0" \
  "$(_review_unavailable_threshold 2>/dev/null)"
REVIEW_UNAVAILABLE_CAP=1
assert_eq "TC-RUC-012 one is accepted" "1" \
  "$(_review_unavailable_threshold 2>/dev/null)"
REVIEW_UNAVAILABLE_CAP=banana
warn=$(_review_unavailable_threshold 2>&1 1>/dev/null)
assert_eq "TC-RUC-013 malformed falls back to three" "3" \
  "$(_review_unavailable_threshold 2>/dev/null)"
assert_contains "TC-RUC-013b malformed emits warning" "$warn" "WARNING"
REVIEW_UNAVAILABLE_CAP=7
warn=$(_review_unavailable_threshold 2>&1 1>/dev/null)
assert_eq "TC-RUC-014 positive value is honored" "7" \
  "$(_review_unavailable_threshold 2>/dev/null)"
assert_eq "TC-RUC-014b valid value emits no warning" "" "$warn"
REVIEW_UNAVAILABLE_CAP=9223372036854775807
assert_eq "TC-RUC-014c signed arithmetic ceiling is honored" \
  "9223372036854775807" "$(_review_unavailable_threshold 2>/dev/null)"
REVIEW_UNAVAILABLE_CAP=9223372036854775808
warn=$(_review_unavailable_threshold 2>&1 1>/dev/null)
assert_eq "TC-RUC-013c unrepresentable value falls back to three" \
  "3" "$(_review_unavailable_threshold 2>/dev/null)"
assert_contains "TC-RUC-013d unrepresentable value emits warning" "$warn" "WARNING"
oversized_marker=$(_review_unavailable_marker 525 aaa 9223372036854775808)
assert_eq "TC-RUC-002c oversized marker count parses as zero" \
  "0" "$(_review_unavailable_parse_count "$oversized_marker")"
max_marker=$(_review_unavailable_marker 525 aaa 9223372036854775807)
assert_eq "TC-RUC-008b max marker count saturates instead of overflowing" \
  "9223372036854775807" "$(_review_unavailable_next_count "$max_marker")"
unset REVIEW_UNAVAILABLE_CAP

echo
echo "=== TC-RUC-020..032 wrapper-route behavior ==="
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
COMMENTS="$SANDBOX/comments.jsonl"
EVENTS="$SANDBOX/events"
: > "$COMMENTS"
: > "$EVENTS"
ISSUE_STATE="reviewing"
RESULT_PARSED=false
POST_SEQ=0
FAIL_REPORT_POST=false
FAIL_POSTS_WHILE_STALLED=false
FAIL_TRANSITION=false
FAIL_TASK_READ=false
TASK_READ_OVERRIDE=""
STALLED_REMOVED_AT=""

itp_read_task() {
  [[ "$FAIL_TASK_READ" != "true" ]] || return 41
  if [[ -n "$TASK_READ_OVERRIDE" ]]; then
    printf '%s\n' "$TASK_READ_OVERRIDE"
    return 0
  fi
  jq -cn --arg state "$ISSUE_STATE" '{labels:["autonomous",$state]}'
}

itp_list_comments() {
  printf 'comment-read-strict:%s\n' "${ITP_REQUIRE_SELF_AUTHOR:-0}" >> "$EVENTS"
  if [[ -s "$COMMENTS" ]]; then
    jq -s '.' "$COMMENTS"
  else
    printf '[]\n'
  fi
}

itp_post_comment() {
  local issue="$1" body="$2"
  if [[ "$FAIL_POSTS_WHILE_STALLED" == "true" && "$ISSUE_STATE" == "stalled" ]]; then
    printf 'post-failed:%s:while-stalled\n' "$issue" >> "$EVENTS"
    return 1
  fi
  if [[ "$FAIL_REPORT_POST" == "true" && "$body" == *"Review-unavailable-cap circuit-breaker tripped"* ]]; then
    printf 'post-failed:%s:report\n' "$issue" >> "$EVENTS"
    return 1
  fi
  POST_SEQ=$((POST_SEQ + 1))
  printf 'post:%s:%s\n' "$issue" "$body" >> "$EVENTS"
  jq -cn \
    --arg createdAt "2026-07-21T10:00:$(printf '%02d' "$POST_SEQ")Z" \
    --argjson id "$POST_SEQ" \
    --arg body "$body" \
    '{id:$id,authorKind:"self",createdAt:$createdAt,body:$body}' >> "$COMMENTS"
}

itp_transition_state() {
  local issue="$1" from="$2" to="$3"
  [[ "$FAIL_TRANSITION" != "true" ]] || return 42
  printf 'transition:%s:%s:%s\n' "$issue" "$from" "$to" >> "$EVENTS"
  [[ "$ISSUE_STATE" == "$from" ]] || return 1
  ISSUE_STATE="$to"
}

itp_label_event_ts() {
  local issue="$1" label="$2" mode="${3:-first-added}"
  printf 'label-event:%s:%s:%s\n' "$issue" "$label" "$mode" >> "$EVENTS"
  [[ "$mode" == "latest-removed" ]] && printf '%s\n' "$STALLED_REMOVED_AT"
}

resolve_escalation_mention() {
  printf '@operator'
}

log() {
  :
}

reset_harness() {
  : > "$COMMENTS"
  : > "$EVENTS"
  ISSUE_STATE="reviewing"
  RESULT_PARSED=false
  POST_SEQ=0
  FAIL_REPORT_POST=false
  FAIL_POSTS_WHILE_STALLED=false
  FAIL_TRANSITION=false
  FAIL_TASK_READ=false
  TASK_READ_OVERRIDE=""
  STALLED_REMOVED_AT=""
  unset REVIEW_UNAVAILABLE_CAP
}

run_unavailable_round() {
  local head="${1:-}" drop_reasons="${2:-}" smoke_reasons="${3:-}"
  ISSUE_STATE="reviewing"
  RESULT_PARSED=false
  _review_unavailable_breaker_handle 525 "$head" 900 "$drop_reasons" "$smoke_reasons"
  case "$REVIEW_UNAVAILABLE_BREAKER_ACTION" in
    continue)
      itp_transition_state 525 reviewing pending-dev
      ;;
    stalled|already-stalled|state-unreadable)
      ;;
    *)
      return 90
      ;;
  esac
}

reset_harness
run_unavailable_round aaa
assert_eq "TC-RUC-020a first unavailable routes pending-dev" "pending-dev" "$ISSUE_STATE"
assert_file_contains "TC-RUC-020b first unavailable persists round one" "$COMMENTS" "round=1"
assert_file_contains "TC-RUC-020b2 comment read requires exact self identity" \
  "$EVENTS" "comment-read-strict:1"
run_unavailable_round bbb
assert_eq "TC-RUC-020c second unavailable routes pending-dev" "pending-dev" "$ISSUE_STATE"
assert_file_contains "TC-RUC-020d second unavailable persists round two" "$COMMENTS" "round=2"
run_unavailable_round ccc
assert_eq "TC-RUC-020e threshold round stalls" "stalled" "$ISSUE_STATE"
assert_eq "TC-RUC-020f trip is handled" "true" "$RESULT_PARSED"
assert_eq "TC-RUC-020g exactly one trip report" "1" \
  "$(grep -c 'reason=review-unavailable-cap' "$COMMENTS")"
third_transition=$(grep '^transition:' "$EVENTS" | tail -1)
assert_eq "TC-RUC-020h nth round has no pending-dev flip" \
  "transition:525:reviewing:stalled" "$third_transition"
ISSUE_STATE="reviewing"
run_unavailable_round ddd
assert_eq "TC-RUC-006a removing stalled re-arms the ordinary retry route" \
  "pending-dev" "$ISSUE_STATE"
assert_contains "TC-RUC-006b first post-rearm unavailable round restarts at one" \
  "$(tail -n 1 "$COMMENTS")" "round=1"
assert_eq "TC-RUC-006c re-arm does not duplicate the prior trip report" "1" \
  "$(grep -c 'reason=review-unavailable-cap' "$COMMENTS")"

reset_harness
FAIL_REPORT_POST=true
run_unavailable_round aaa
run_unavailable_round bbb
run_unavailable_round ccc
assert_eq "TC-RUC-006d report-post failure still leaves the issue stalled" \
  "stalled" "$ISSUE_STATE"
assert_file_contains "TC-RUC-006e trip persists the threshold marker before reporting" \
  "$COMMENTS" "head=ccc round=3"
assert_file_contains "TC-RUC-006f trip persists an independent re-arm marker" \
  "$COMMENTS" "head=ccc round=0"
assert_eq "TC-RUC-006g injected report failure posts no trip report" "0" \
  "$(grep -c 'reason=review-unavailable-cap' "$COMMENTS")"
FAIL_REPORT_POST=false
ISSUE_STATE="reviewing"
run_unavailable_round ddd
assert_eq "TC-RUC-006h report-post failure still re-arms after stalled removal" \
  "pending-dev" "$ISSUE_STATE"
assert_contains "TC-RUC-006i first post-failure round restarts at one" \
  "$(tail -n 1 "$COMMENTS")" "head=ddd round=1"

reset_harness
run_unavailable_round aaa
run_unavailable_round bbb
FAIL_POSTS_WHILE_STALLED=true
run_unavailable_round ccc
assert_eq "TC-RUC-006k all post-transition comment failures still leave issue stalled" \
  "stalled" "$ISSUE_STATE"
assert_eq "TC-RUC-006l no threshold/reset/report comment landed after transition" \
  "2" "$(wc -l < "$COMMENTS" | tr -d ' ')"
FAIL_POSTS_WHILE_STALLED=false
STALLED_REMOVED_AT="2026-07-21T10:00:30Z"
POST_SEQ=30
ISSUE_STATE="reviewing"
run_unavailable_round ddd
assert_eq "TC-RUC-006m stalled removal re-arms after every trip post failed" \
  "pending-dev" "$ISSUE_STATE"
assert_contains "TC-RUC-006n first post-removal unavailable round restarts at one" \
  "$(tail -n 1 "$COMMENTS")" "head=ddd round=1"
assert_file_contains "TC-RUC-006o breaker requests latest stalled-removal event" \
  "$EVENTS" "label-event:525:stalled:latest-removed"

reset_harness
run_unavailable_round aaa
run_unavailable_round bbb
ISSUE_STATE="reviewing"
_review_unavailable_reset_if_decided pass 525 passhead
run_unavailable_round ccc
assert_file_contains "TC-RUC-021 PASS reset posts round zero" "$COMMENTS" "head=passhead round=0"
assert_contains "TC-RUC-021b unavailable after PASS restarts at one" \
  "$(tail -n 1 "$COMMENTS")" "round=1"

reset_harness
run_unavailable_round aaa
run_unavailable_round bbb
ISSUE_STATE="reviewing"
_review_unavailable_reset_if_decided fail 525 ""
run_unavailable_round ccc
assert_file_contains "TC-RUC-022/023 FAIL reset with missing head posts durable reset" \
  "$COMMENTS" "head=unknown round=0"
assert_contains "TC-RUC-022b unavailable after FAIL restarts at one" \
  "$(tail -n 1 "$COMMENTS")" "round=1"

reset_harness
_review_unavailable_reset_if_decided all-unavailable 525 no-decision
assert_eq "TC-RUC-023b all-unavailable does not post a reset marker" "0" \
  "$(wc -l < "$COMMENTS" | tr -d ' ')"

reset_harness
run_unavailable_round aaa
run_unavailable_round bbb
REVIEW_UNAVAILABLE_CAP=0
_review_unavailable_reset_if_decided pass 525 disabled-pass
unset REVIEW_UNAVAILABLE_CAP
run_unavailable_round ccc
assert_file_contains "TC-RUC-011d disabled interval still records a decided reset" \
  "$COMMENTS" "head=disabled-pass round=0"
assert_contains "TC-RUC-011e re-enabling after a disabled decided round starts at one" \
  "$(tail -n 1 "$COMMENTS")" "round=1"

reset_harness
ISSUE_STATE="stalled"
_review_unavailable_breaker_handle 525 aaa 900 "" ""
assert_eq "TC-RUC-024 sibling stall short-circuits" "already-stalled" \
  "$REVIEW_UNAVAILABLE_BREAKER_ACTION"
assert_eq "TC-RUC-024b sibling stall is handled" "true" "$RESULT_PARSED"
assert_eq "TC-RUC-024c sibling stall emits no write" "0" "$(wc -l < "$EVENTS" | tr -d ' ')"

reset_harness
REVIEW_UNAVAILABLE_CAP=0
ISSUE_STATE="stalled"
_review_unavailable_breaker_handle 525 aaa 900 "" ""
assert_eq "TC-RUC-024d disabled cap still respects sibling stall" "already-stalled" \
  "$REVIEW_UNAVAILABLE_BREAKER_ACTION"
assert_eq "TC-RUC-024e disabled sibling stall emits no write" \
  "0" "$(wc -l < "$EVENTS" | tr -d ' ')"

reset_harness
FAIL_TASK_READ=true
run_unavailable_round aaa
assert_eq "TC-RUC-024f unreadable sibling state fails closed" \
  "state-unreadable" "$REVIEW_UNAVAILABLE_BREAKER_ACTION"
assert_eq "TC-RUC-024g unreadable sibling state is handled" "true" "$RESULT_PARSED"
assert_eq "TC-RUC-024h unreadable sibling state stays reviewing" \
  "reviewing" "$ISSUE_STATE"
assert_eq "TC-RUC-024i unreadable sibling state emits no writes" \
  "0" "$(( $(wc -l < "$EVENTS") + $(wc -l < "$COMMENTS") ))"

reset_harness
TASK_READ_OVERRIDE='{"labels":[{"name":"stalled"}]}'
run_unavailable_round aaa
assert_eq "TC-RUC-024j non-string label elements fail closed" \
  "state-unreadable" "$REVIEW_UNAVAILABLE_BREAKER_ACTION"
assert_eq "TC-RUC-024k malformed label elements emit no writes" \
  "0" "$(( $(wc -l < "$EVENTS") + $(wc -l < "$COMMENTS") ))"

reset_harness
TASK_READ_OVERRIDE='{"labels":'
run_unavailable_round aaa
assert_eq "TC-RUC-024l malformed label JSON fails closed" \
  "state-unreadable" "$REVIEW_UNAVAILABLE_BREAKER_ACTION"
assert_eq "TC-RUC-024m malformed label JSON emits no writes" \
  "0" "$(( $(wc -l < "$EVENTS") + $(wc -l < "$COMMENTS") ))"

reset_harness
REVIEW_UNAVAILABLE_CAP=0
run_unavailable_round aaa
assert_eq "TC-RUC-011b disabled keeps legacy pending-dev route" "pending-dev" "$ISSUE_STATE"
assert_eq "TC-RUC-011c disabled posts no breaker marker" "0" "$(wc -l < "$COMMENTS" | tr -d ' ')"

reset_harness
for smoke_head in aaa bbb ccc; do
  ISSUE_STATE="reviewing"
  _smoke_reasons=""
  _review_unavailable_add_smoke_reason claude quota-exhausted
  _review_unavailable_terminal_route 525 "$smoke_head" 900 "" "$_smoke_reasons"
  if [[ "$REVIEW_UNAVAILABLE_BREAKER_ACTION" == "continue" ]]; then
    itp_transition_state 525 reviewing pending-dev
  fi
done
assert_eq "TC-RUC-030a repeated smoke-driven unavailable rounds reach stalled" \
  "stalled" "$ISSUE_STATE"
report=$(grep 'reason=review-unavailable-cap' "$COMMENTS")
assert_contains "TC-RUC-030b smoke-driven trip includes smoke evidence" "$report" \
  "claude: smoke: quota-exhausted"

smoke_pass_block=$(awk '
  /case "\$_SMOKE_GATE" in/ { in_gate=1 }
  in_gate && /^    pass\)/ { capture=1 }
  capture { print }
  capture && /^      ;;/ { exit }
' "$WRAPPER")
assert_contains "TC-RUC-030c partial smoke-drop evidence survives fleet shrink" \
  "$smoke_pass_block" '_review_unavailable_add_smoke_reason'
smoke_reason_line=$(grep -nF '_review_unavailable_add_smoke_reason' "$WRAPPER" | tail -n 1 | cut -d: -f1)
smoke_shrink_line=$(grep -nF 'REVIEW_AGENTS_LIST=("${_smoke_survivors[@]}")' "$WRAPPER" | cut -d: -f1)
if [[ -n "$smoke_reason_line" && -n "$smoke_shrink_line" && "$smoke_reason_line" -lt "$smoke_shrink_line" ]]; then
  ok "TC-RUC-030d partial smoke evidence is saved before the fleet shrinks"
else
  bad "TC-RUC-030d partial smoke evidence must be saved before the fleet shrinks"
fi
smoke_all_unavailable_block=$(awk '
  /case "\$_SMOKE_GATE" in/ { in_gate=1 }
  in_gate && /^    all-unavailable\)/ { capture=1 }
  capture { print }
  capture && /^      ;;/ { exit }
' "$WRAPPER")
assert_contains "TC-RUC-030e full smoke-unavailable path uses production evidence collector" \
  "$smoke_all_unavailable_block" '_review_unavailable_add_smoke_reason'
assert_contains "TC-RUC-030f smoke advisory documents bounded retry behavior" \
  "$smoke_all_unavailable_block" 'Retries remain automatic below \`REVIEW_UNAVAILABLE_CAP\`'

reset_harness
REVIEW_UNAVAILABLE_CAP=1
run_unavailable_round aaa "claude: no reason token recorded; " \
  "claude: smoke: quota-exhausted; "
assert_eq "TC-RUC-012b minimum positive trips first round" "stalled" "$ISSUE_STATE"
report=$(grep 'reason=review-unavailable-cap' "$COMMENTS")
assert_contains "TC-RUC-026 trip includes drop reason" "$report" \
  "claude: no reason token recorded"
transition_line=$(grep -n '^transition:525:reviewing:stalled' "$EVENTS" | cut -d: -f1)
report_line=$(grep -n 'reason=review-unavailable-cap' "$EVENTS" | cut -d: -f1)
if [[ -n "$transition_line" && -n "$report_line" && "$transition_line" -lt "$report_line" ]]; then
  ok "TC-RUC-025 stalled transition precedes report"
else
  bad "TC-RUC-025 stalled transition must precede report"
fi

reset_harness
REVIEW_UNAVAILABLE_CAP=1
FAIL_TRANSITION=true
route_failure_output=$(
  set -e
  _review_unavailable_terminal_route 525 aaa 900 "" ""
  printf 'reached-after-transition-failure\n'
) 2>/dev/null
route_failure_rc=$?
assert_eq "TC-RUC-025b transition failure remains fatal through production route" \
  "42" "$route_failure_rc"
assert_eq "TC-RUC-025c transition failure never reaches post-route code" \
  "" "$route_failure_output"

reset_harness
REVIEW_UNAVAILABLE_CAP=1
run_unavailable_round aaa "" ""
_review_unavailable_breaker_handle 525 aaa 900 "" ""
assert_eq "TC-RUC-032 repeated call while stalled posts one report total" "1" \
  "$(grep -c 'reason=review-unavailable-cap' "$COMMENTS")"

reset_harness
REVIEW_UNAVAILABLE_CAP=1
run_unavailable_round aaa "" ""
report=$(grep 'reason=review-unavailable-cap' "$COMMENTS")
assert_contains "TC-RUC-027 signal-free drop degrades explicitly" "$report" \
  "no reason token recorded"

echo
echo "=== TC-RUC-033..036 production terminal route ==="
all_unavailable_block=$(awk '/^  all-unavailable\)/,/^    ;;$/' "$WRAPPER")
assert_contains "TC-RUC-033 wrapper calls the production terminal route" \
  "$all_unavailable_block" '_review_unavailable_terminal_route'
assert_contains "TC-RUC-034 handled terminal route exits before fallback" \
  "$all_unavailable_block" 'exit 0'

run_production_terminal_route() {
  local head="$1"
  ISSUE_STATE="reviewing"
  _review_unavailable_terminal_route \
    525 "$head" 900 "claude: no reason token recorded; " ""
  if [[ "$REVIEW_UNAVAILABLE_BREAKER_ACTION" == "continue" ]]; then
    printf 'downstream-pending-dev:%s\n' "$head" >> "$EVENTS"
    itp_transition_state 525 reviewing pending-dev
  fi
}

reset_harness
run_production_terminal_route guard-a
run_production_terminal_route guard-b
run_production_terminal_route guard-c
assert_eq "TC-RUC-035 production route lets only pre-threshold rounds reach fallback" \
  "2" "$(grep -c '^downstream-pending-dev:' "$EVENTS")"
assert_eq "TC-RUC-036 production route stalls the Nth round and suppresses pending-dev" \
  "transition:525:reviewing:stalled" "$(grep '^transition:' "$EVENTS" | tail -n 1)"

echo
echo "=== TC-RUC-040..043 wiring and docs ==="
assert_file_contains "TC-RUC-040 wrapper sources unavailable-cap lib" "$WRAPPER" \
  'source "${LIB_DIR}/lib-review-unavailable-cap.sh"'
assert_contains "TC-RUC-041 all-unavailable path calls breaker" "$all_unavailable_block" \
  '_review_unavailable_terminal_route'
decided_reset_block=$(awk '/post the review-round-counter marker HERE/,/^# \[INV-70\] Metrics/' "$WRAPPER")
assert_contains "TC-RUC-041b PASS decided path resets unavailable streak" \
  "$decided_reset_block" '_review_unavailable_reset_if_decided "$AGGREGATE"'
assert_contains "TC-RUC-041c FAIL decided path resets unavailable streak" \
  "$(declare -f _review_unavailable_reset_if_decided)" 'aggregate" == "fail"'
assert_file_contains "TC-RUC-010c conf documents knob" "$CONF" \
  'REVIEW_UNAVAILABLE_CAP="3"'
assert_file_contains "TC-RUC-042 transition manifest has distinct breaker" "$TRANSITIONS" \
  '"id": "review-unavailable-cap-breaker"'
assert_file_contains "TC-RUC-042b transition uses its own sibling-stall guard" \
  "$TRANSITIONS" '"review-unavailable-not-already-stalled"'
assert_file_contains "TC-RUC-042c sibling-stall guard maps to the new helper" \
  "$GUARD_MAP" '"file": "lib-review-unavailable-cap.sh", "pattern": "any(. == \"stalled\")"'
assert_file_contains "TC-RUC-043 invariant is documented" "$INVARIANTS" '## INV-144:'
assert_file_contains "TC-RUC-043b state machine documents unavailable cap" "$STATE_MACHINE" \
  'review-unavailable-cap'
assert_file_contains "TC-RUC-043c review flow documents unavailable cap" "$FLOW" \
  'REVIEW_UNAVAILABLE_CAP'
assert_file_contains "TC-RUC-043d INV-64 documents persistent smoke outage bound" \
  "$INVARIANTS" 'Smoke-driven `all-unavailable` rounds count toward INV-144'
assert_file_contains "TC-RUC-043e handoff index documents unavailable marker" \
  "$HANDOFFS" 'dispatcher-review-unavailable-breaker'
assert_file_contains "TC-RUC-043f handoff index covers all four breaker markers" \
  "$HANDOFFS" 'All four use an **unbounded** full-comment-history scan'
duplicate_inv_ids=$(sed -n 's/^## \(INV-[0-9][0-9]*\):.*/\1/p' "$INVARIANTS" \
  | LC_ALL=C sort | uniq -d)
assert_eq "TC-RUC-043g invariant IDs are globally unique" "" "$duplicate_inv_ids"
assert_file_contains "TC-RUC-045 CI shellcheck includes unavailable-cap library" \
  "$CI" 'skills/autonomous-dispatcher/scripts/lib-review-unavailable-cap.sh'

if bash -n "$LIB" "$WRAPPER"; then
  ok "TC-RUC-044 shell syntax"
else
  bad "TC-RUC-044 shell syntax"
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
