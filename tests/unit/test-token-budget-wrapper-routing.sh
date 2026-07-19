#!/bin/bash
# Behavioral extraction tests for review-wrapper token routing (INV-141).

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEV="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
REVIEW="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"
DISPATCH_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
TERMINAL_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-terminal-control.sh"
TOKEN_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-token-budget.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc (expected='$expected' actual='$actual')"
  fi
}
assert_contains() {
  local desc="$1" needle="$2" actual="$3"
  if [[ "$actual" == *"$needle"* ]]; then pass "$desc"; else fail "$desc"; fi
}
assert_not_contains() {
  local desc="$1" needle="$2" actual="$3"
  if [[ "$actual" != *"$needle"* ]]; then pass "$desc"; else fail "$desc"; fi
}

MEMBER_SNIPPET="$WORK/member.sh"
awk '
  /^# \[INV-141\] Verdict publication precedes budget routing:/ { copy=1 }
  /^# \[P1\] #2 follow-up \(#233 review round-5\):/ { copy=0 }
  copy
' "$REVIEW" > "$MEMBER_SNIPPET"

EARLY_REFUSAL_SNIPPET="$WORK/early-refusal.sh"
awk '
  /^# No member was launched, so there is no fan-out state to resolve or commit\./ { copy=1 }
  /^# Wait for the fanned-out review agents to finish/ { copy=0 }
  copy
' "$REVIEW" > "$EARLY_REFUSAL_SNIPPET"

ISSUE_SNIPPET="$WORK/issue.sh"
awk '
  /^# Token-budget cumulative hard gate/ { copy=1 }
  /^# PASSED_VERDICT was set by/ { copy=0 }
  copy
' "$REVIEW" > "$ISSUE_SNIPPET"

DEV_CLEANUP_SNIPPET="$WORK/dev-cleanup.sh"
awk '
  /^_token_dev_evaluate_cleanup\(\) \{/ { copy=1 }
  copy { print }
  copy && /^}$/ { exit }
' "$DEV" > "$DEV_CLEANUP_SNIPPET"

if [[ ! -s "$MEMBER_SNIPPET" || ! -s "$EARLY_REFUSAL_SNIPPET" \
      || ! -s "$ISSUE_SNIPPET" || ! -s "$DEV_CLEANUP_SNIPPET" ]]; then
  echo "FAIL: could not extract token-budget review routing snippets" >&2
  exit 1
fi

run_early_refusal_route() {
  local trailer_rc="${1:-0}" record="$WORK/early-refusal-record"
  local fanout_dir="$WORK/fanout"
  mkdir -p "$fanout_dir"
  : > "$record"
  TRAILER_RC="$trailer_rc" RECORD="$record" FANOUT_DIR="$fanout_dir" \
    bash -uo pipefail -c '
      TOKEN_REVIEW_LAUNCH_REFUSED=true
      AGENT_NAMES=()
      ISSUE_NUMBER=506
      REPO=zxkane/autonomous-dev-team
      PR_HEAD_SHA=head-506
      _FANOUT_DIR="$FANOUT_DIR"
      RESULT_PARSED=false
      log() { printf "log|%s\n" "$*" >> "$RECORD"; }
      emit_verdict_trailer() {
        printf "trailer|%s\n" "$*" >> "$RECORD"
        return "$TRAILER_RC"
      }
      _review_round_marker() {
        printf "review-round-counter|issue=%s|head=%s|round=%s" "$1" "$2" "$3"
      }
      itp_post_comment() { printf "comment|%s\n" "$*" >> "$RECORD"; }
      source "'"$EARLY_REFUSAL_SNIPPET"'"
    ' >/dev/null 2>&1
  return $?
}

run_member_route() {
  local evaluate_rc="$1" transition_rc="$2" launch_refused="${3:-false}"
  local trailer_rc="${4:-0}"
  local record="$WORK/member-record"
  : > "$record"
  EVALUATE_RC="$evaluate_rc" TRANSITION_RC="$transition_rc" \
    TOKEN_REVIEW_LAUNCH_REFUSED="$launch_refused" TRAILER_RC="$trailer_rc" \
    RECORD="$record" \
    bash -uo pipefail -c '
      ISSUE_NUMBER=506
      REPO=zxkane/autonomous-dev-team
      PR_HEAD_SHA=head-506
      AGENT_ACCOUNTING_IDS=(inv-a)
      AGENT_ACCOUNTING_RESULTS=("{\"state\":\"usage-committed\",\"total_tokens\":101}")
      AGENT_VERDICTS=(fail)
      RESULT_PARSED=false
      log() { printf "log|%s\n" "$*" >> "$RECORD"; }
      token_budget_evaluate_review_members() { return "$EVALUATE_RC"; }
      terminal_intent_cleanup_transition() {
        printf "terminal|%s\n" "$*" >> "$RECORD"
        return "$TRANSITION_RC"
      }
      emit_verdict_trailer() {
        printf "trailer|%s\n" "$*" >> "$RECORD"
        return "$TRAILER_RC"
      }
      _review_round_marker() {
        printf "review-round-counter|issue=%s|head=%s|round=%s" "$1" "$2" "$3"
      }
      itp_post_comment() { printf "comment|%s\n" "$*" >> "$RECORD"; }
      trap '"'"'printf "verdict|%s\n" "${AGENT_VERDICTS[0]}" >> "$RECORD"'"'"' EXIT
      source "'"$MEMBER_SNIPPET"'"
    ' >/dev/null 2>&1
  return $?
}

run_issue_route() {
  local evaluate_rc="$1" transition_rc="$2" trailer_rc="${3:-0}"
  local run_id_state="${4:-set}"
  local record="$WORK/issue-record"
  : > "$record"
  EVALUATE_RC="$evaluate_rc" TRANSITION_RC="$transition_rc" \
    TRAILER_RC="$trailer_rc" RECORD="$record" RUN_ID_STATE="$run_id_state" \
    bash -uo pipefail -c '
      PASSED_VERDICT=true
      ISSUE_NUMBER=506
      AGENT_TOKEN_BUDGET=100
      TOKEN_BUDGET_MODE=hard
      if [[ "$RUN_ID_STATE" == "set" ]]; then
        RUN_ID=review-run
      else
        unset RUN_ID
      fi
      REPO=zxkane/autonomous-dev-team
      PR_HEAD_SHA=head-506
      RESULT_PARSED=false
      log() { printf "log|%s\n" "$*" >> "$RECORD"; }
      token_budget_evaluate_issue() {
        printf "evaluate|%s\n" "$*" >> "$RECORD"
        return "$EVALUATE_RC"
      }
      terminal_intent_cleanup_transition() {
        printf "terminal|%s\n" "$*" >> "$RECORD"
        return "$TRANSITION_RC"
      }
      itp_post_comment() { printf "comment|%s\n" "$*" >> "$RECORD"; }
      _review_round_marker() {
        printf "review-round-counter|issue=%s|head=%s|round=%s" "$1" "$2" "$3"
      }
      emit_verdict_trailer() {
        printf "trailer|%s\n" "$*" >> "$RECORD"
        return "$TRAILER_RC"
      }
      itp_transition_state() {
        printf "transition|%s\n" "$*" >> "$RECORD"
        return "$TRANSITION_RC"
      }
      source "'"$ISSUE_SNIPPET"'"
    ' >/dev/null 2>&1
  return $?
}

run_dev_cleanup_without_run_id() {
  local record="$WORK/dev-cleanup-record"
  : > "$record"
  RECORD="$record" bash -uo pipefail -c '
    ISSUE_NUMBER=506
    AGENT_TOKEN_BUDGET=100
    TOKEN_BUDGET_MODE=hard
    unset RUN_ID
    TOKEN_DEV_BUDGET_EVALUATED=false
    TOKEN_DEV_BUDGET_EVAL_RC=0
    TOKEN_DEV_INVOCATION_IDS=()
    TOKEN_DEV_RESULTS=()
    log() { printf "log|%s\n" "$*" >> "$RECORD"; }
    token_budget_evaluate_dev_run() {
      printf "evaluate|%s\n" "$*" >> "$RECORD"
      return 0
    }
    source "'"$DEV_CLEANUP_SNIPPET"'"
    _token_dev_evaluate_cleanup
  ' >/dev/null 2>&1
}

echo "== Wrapper degradation without run artifacts =="
run_dev_cleanup_without_run_id
assert_eq "TC-TOKENBUDGET-085 dev cleanup tolerates unset RUN_ID" 0 "$?"
assert_contains "TC-TOKENBUDGET-085 dev cleanup projects with an empty current run" \
  "evaluate|506  TOKEN_DEV_INVOCATION_IDS TOKEN_DEV_RESULTS" \
  "$(cat "$WORK/dev-cleanup-record")"

run_issue_route 0 0 0 unset
assert_eq "TC-TOKENBUDGET-085 review issue gate tolerates unset RUN_ID" 0 "$?"
assert_contains "TC-TOKENBUDGET-085 review gate projects with an empty current run" \
  "evaluate|506 review " "$(cat "$WORK/issue-record")"

echo "== Review early launch-refusal routing =="
run_early_refusal_route 1
assert_eq "TC-TOKENBUDGET-084 no-member refusal remains retryable" 1 "$?"
early_refusal_record="$(cat "$WORK/early-refusal-record")"
assert_contains "TC-TOKENBUDGET-084 no-member refusal resets round despite trailer failure" \
  $'trailer|506 zxkane/autonomous-dev-team failed-non-substantive token-budget-launch-refused\nlog|WARNING: token-budget launch-refusal trailer failed for issue #506\ncomment|506 review-round-counter|issue=506|head=head-506|round=0' \
  "$early_refusal_record"

echo "== Review member hard-violation routing =="
run_member_route 10 0
assert_eq "TC-TOKENBUDGET-052 successful member violation exits handled" 0 "$?"
member_record="$(cat "$WORK/member-record")"
assert_contains "TC-TOKENBUDGET-052 member violation invokes explicit cleanup" \
  "terminal|506 reviewing reviewing pending-dev" "$member_record"
assert_contains "TC-TOKENBUDGET-052 member verdict remains unchanged" \
  "verdict|fail" "$member_record"
assert_not_contains "TC-TOKENBUDGET-052 member route emits no crash verdict" \
  "crash" "$member_record"

run_member_route 10 1
assert_eq "TC-TOKENBUDGET-052 terminal transition failure refuses normal exit" 1 "$?"
member_record="$(cat "$WORK/member-record")"
assert_contains "TC-TOKENBUDGET-052 failed transition is loud" "log|ERROR:" "$member_record"
assert_contains "TC-TOKENBUDGET-052 failed transition preserves verdict" \
  "verdict|fail" "$member_record"

run_member_route 10 0 true
assert_eq "TC-TOKENBUDGET-065 partial refusal still routes prior violation" 0 "$?"
member_record="$(cat "$WORK/member-record")"
assert_contains "TC-TOKENBUDGET-065 prior member is evaluated before refusal" \
  "terminal|506 reviewing reviewing pending-dev" "$member_record"
assert_not_contains "TC-TOKENBUDGET-065 violation route wins over retry trailer" \
  "token-budget-launch-refused" "$member_record"

run_member_route 0 0 true 1
assert_eq "TC-TOKENBUDGET-066 partial refusal remains retryable" 1 "$?"
member_record="$(cat "$WORK/member-record")"
assert_contains "TC-TOKENBUDGET-066 partial refusal leaves durable retry class" \
  "failed-non-substantive token-budget-launch-refused" "$member_record"
assert_contains "TC-TOKENBUDGET-084 partial refusal resets round despite trailer failure" \
  $'trailer|506 zxkane/autonomous-dev-team failed-non-substantive token-budget-launch-refused\nlog|WARNING: token-budget launch-refusal trailer failed for issue #506\ncomment|506 review-round-counter|issue=506|head=head-506|round=0' \
  "$member_record"

echo "== Review issue pre-approval routing =="
run_issue_route 20 0
assert_eq "TC-TOKENBUDGET-054 unavailable projection exits handled" 0 "$?"
issue_record="$(cat "$WORK/issue-record")"
assert_contains "TC-TOKENBUDGET-054 unavailable hold posts operator note" \
  "comment|506 Review held" "$issue_record"
assert_contains "TC-TOKENBUDGET-054 unavailable hold writes durable trailer" \
  "failed-non-substantive token-budget-unavailable" "$issue_record"
assert_contains "TC-TOKENBUDGET-084 unavailable hold resets review round after trailer" \
  $'trailer|506 zxkane/autonomous-dev-team failed-non-substantive token-budget-unavailable\ncomment|506 review-round-counter|issue=506|head=head-506|round=0' \
  "$issue_record"
assert_contains "TC-TOKENBUDGET-054 unavailable hold requeues review" \
  "transition|506 reviewing pending-review" "$issue_record"
assert_not_contains "TC-TOKENBUDGET-054 unavailable hold writes no intent" \
  "terminal|" "$issue_record"

run_issue_route 20 1
assert_eq "TC-TOKENBUDGET-054 failed hold transition refuses handled exit" 1 "$?"
issue_record="$(cat "$WORK/issue-record")"
assert_contains "TC-TOKENBUDGET-054 failed hold retains durable recovery trailer" \
  "failed-non-substantive token-budget-unavailable" "$issue_record"
assert_contains "TC-TOKENBUDGET-054 failed hold transition is loud" \
  "log|ERROR:" "$issue_record"

run_issue_route 20 1 1
assert_eq "TC-TOKENBUDGET-066 failed trailer and transition refuse approval" 1 "$?"
issue_record="$(cat "$WORK/issue-record")"
assert_contains "TC-TOKENBUDGET-066 dual hold persistence failure is loud" \
  "log|ERROR:" "$issue_record"
assert_contains "TC-TOKENBUDGET-084 round reset remains independent of trailer failure" \
  "comment|506 review-round-counter|issue=506|head=head-506|round=0" \
  "$issue_record"

echo "== Dispatcher Step 5 terminal and hold recovery =="
CLASSIFIER_SNIPPET="$WORK/classifier.sh"
awk '
  /^classify_recent_review_verdict\(\)/ { copy=1 }
  copy { print }
  copy && /^}$/ { exit }
' "$DISPATCH_LIB" > "$CLASSIFIER_SNIPPET"

STEP5_ACTIVE_SNIPPET="$WORK/step5-active.sh"
awk '
  /Dev process still alive but PR/ { found=1 }
  found && /terminal_intent_cleanup_transition/ { copy=1 }
  copy { print }
  copy && /continue; }$/ { exit }
' "$TICK" > "$STEP5_ACTIVE_SNIPPET"

STEP5_HOLD_SNIPPET="$WORK/step5-hold.sh"
awk '
  /^      _stale_review_verdict=none$/ { copy=1 }
  copy && /^      # \[INV-70\] Metrics:/ { exit }
  copy { print }
' "$TICK" > "$STEP5_HOLD_SNIPPET"

STEP5_GENERIC_SNIPPET="$WORK/step5-generic.sh"
awk '
  /Review process appears to have crashed/ { found=1 }
  found && /terminal_intent_cleanup_transition/ { copy=1 }
  copy { print }
  copy && /continue; }$/ { exit }
' "$TICK" > "$STEP5_GENERIC_SNIPPET"

STEP5_DEV_FAIL_CLOSED_SNIPPET="$WORK/step5-dev-fail-closed.sh"
awk '
  /^      # A hard per-invocation budget without a recoverable decision must distinguish/ { copy=1 }
  copy { print }
  copy && /^      fi$/ { exit }
' "$TICK" > "$STEP5_DEV_FAIL_CLOSED_SNIPPET"

STEP5_REVIEW_FAIL_CLOSED_SNIPPET="$WORK/step5-review-fail-closed.sh"
awk '
  /^      # After explicit review retry classifications, a hard per-invocation/ { copy=1 }
  copy { print }
  copy && /^      fi$/ { exit }
' "$TICK" > "$STEP5_REVIEW_FAIL_CLOSED_SNIPPET"

if [[ ! -s "$CLASSIFIER_SNIPPET" || ! -s "$STEP5_ACTIVE_SNIPPET" \
      || ! -s "$STEP5_HOLD_SNIPPET" || ! -s "$STEP5_GENERIC_SNIPPET" \
      || ! -s "$STEP5_DEV_FAIL_CLOSED_SNIPPET" \
      || ! -s "$STEP5_REVIEW_FAIL_CLOSED_SNIPPET" ]]; then
  echo "FAIL: could not extract dispatcher token-budget recovery snippets" >&2
  exit 1
fi

DISPATCH_COMMENTS="$WORK/dispatch-comments.json"
DISPATCH_LABELS="$WORK/dispatch-labels.json"
DISPATCH_CALLS="$WORK/dispatch-calls"
DISPATCH_SEQ=0

dispatch_reset() {
  printf '[]\n' > "$DISPATCH_COMMENTS"
  printf '[]\n' > "$DISPATCH_LABELS"
  : > "$DISPATCH_CALLS"
  DISPATCH_SEQ=0
}

dispatch_set_labels() {
  jq -nc '$ARGS.positional' --args "$@" > "$DISPATCH_LABELS"
}

itp_list_comments() {
  cat "$DISPATCH_COMMENTS"
}

itp_post_comment() {
  local issue="$1" body="$2" tmp="$WORK/dispatch-comments.tmp"
  if [[ "${DISPATCH_FAIL_RESOLVED:-0}" == 1 \
        && "$body" == '<!-- token-budget-intent-resolved-v1:'* ]]; then
    return 1
  fi
  DISPATCH_SEQ=$((DISPATCH_SEQ + 1))
  local created_at
  if [[ -n "${DISPATCH_FIXED_CREATED_AT:-}" ]]; then
    created_at="$DISPATCH_FIXED_CREATED_AT"
  else
    printf -v created_at '2026-07-18T18:00:%02dZ' "$DISPATCH_SEQ"
  fi
  jq -c --argjson id "$DISPATCH_SEQ" --arg body "$body" --arg created_at "$created_at" \
    '. + [{id:$id,author:"pipeline-bot",authorKind:"self",
           body:$body,createdAt:$created_at}]' \
    "$DISPATCH_COMMENTS" > "$tmp" && mv "$tmp" "$DISPATCH_COMMENTS"
  printf 'comment|%s|%s\n' "$issue" "$body" >> "$DISPATCH_CALLS"
}

dispatch_post_review_token() {
  itp_post_comment 506 \
    '<!-- dispatcher-token: review-token at 2026-07-18T18:00:00Z mode=review run=review-run -->
Dispatching autonomous review...'
}

itp_read_task() {
  jq -c '{labels:.}' "$DISPATCH_LABELS"
}

itp_transition_state() {
  local issue="$1" remove="$2" add="$3" tmp="$WORK/dispatch-labels.tmp"
  jq -c --arg remove "$remove" --arg add "$add" '
    ($remove | split(",") | map(select(length > 0))) as $removed
    | map(select(. as $label | ($removed | index($label) | not)))
    | if $add == "" or index($add) != null then . else . + [$add] end
  ' "$DISPATCH_LABELS" > "$tmp" && mv "$tmp" "$DISPATCH_LABELS"
  printf 'transition|%s|%s|%s\n' "$issue" "$remove" "$add" >> "$DISPATCH_CALLS"
}

# shellcheck disable=SC1090,SC1091
source "$TERMINAL_LIB"
# shellcheck disable=SC1090
source "$TOKEN_LIB"
# shellcheck disable=SC1090
source "$CLASSIFIER_SNIPPET"

token_budget_recovery_pointer_stage() { return 0; }
token_budget_recovery_pointer_read() { printf '[]\n'; }
token_budget_recovery_pointer_clear() { return 0; }
_token_budget_recovery_pointer_clear_local() { return 0; }
token_budget_recent_launch_refusal() {
  return "${DEV_LAUNCH_REFUSAL_RC:-1}"
}
TOKEN_BUDGET_TEST_ENABLED=0
token_budget_enabled() { return "$TOKEN_BUDGET_TEST_ENABLED"; }
token_budget_effective_mode() { printf '%s\n' "${TOKEN_BUDGET_TEST_MODE:-warn}"; }
log() { printf 'log|%s\n' "$*" >> "$DISPATCH_CALLS"; }

dispatch_reset
dispatch_set_labels autonomous in-progress
terminal_intent_write 506 inv-v1-dispatch inv-v1-dispatch token-cap dispatcher
TOKEN_BUDGET_TEST_ENABLED=1
issue_num=506
for _once in 1; do
  # shellcheck disable=SC1090
  source "$STEP5_ACTIVE_SNIPPET"
done
assert_eq "TC-TOKENBUDGET-063 Step 5 live intent converges to stalled" \
  '["autonomous","stalled"]' "$(jq -c . "$DISPATCH_LABELS")"
dispatch_calls="$(cat "$DISPATCH_CALLS")"
assert_contains "TC-TOKENBUDGET-063 Step 5 consumes only after stalled transition" \
  "resource-terminal-intent-consume-v1: issue=506 intent=inv-v1-dispatch" \
  "$dispatch_calls"
assert_not_contains "TC-TOKENBUDGET-063 Step 5 never resurrects pending-review" \
  "transition|506|in-progress|pending-review" "$dispatch_calls"
TOKEN_BUDGET_TEST_ENABLED=0

dispatch_reset
dispatch_set_labels autonomous in-progress
DISPATCH_FAIL_RESOLVED=1
token_budget_write_invocation_intent \
  506 retired-after-stall retired-after-stall token-cap dev-wrapper
# shellcheck disable=SC2218
terminal_intent_cleanup_transition 506 in-progress in-progress pending-dev
assert_eq "TC-TOKENBUDGET-079 initial unresolved generation still stalls" \
  '["autonomous","stalled"]' "$(jq -c . "$DISPATCH_LABELS")"
unset DISPATCH_FAIL_RESOLVED
dispatch_set_labels autonomous in-progress
: > "$DISPATCH_CALLS"
TOKEN_BUDGET_TEST_MODE=hard
_retired_recovery_rc=0
token_budget_recover_pending_intent 506 dev-wrapper \
  || _retired_recovery_rc=$?
assert_eq "TC-TOKENBUDGET-079 retired generation skips terminal recovery" \
  0 "$_retired_recovery_rc"
assert_eq "TC-TOKENBUDGET-079 retired recovery leaves re-armed labels untouched" \
  '["autonomous","in-progress"]' "$(jq -c . "$DISPATCH_LABELS")"
assert_not_contains "TC-TOKENBUDGET-079 retired recovery makes no transition" \
  "transition|" "$(cat "$DISPATCH_CALLS")"

dispatch_reset
dispatch_set_labels autonomous reviewing
dispatch_post_review_token
itp_post_comment 506 \
  '<!-- review-verdict: failed-non-substantive cause=token-budget-unavailable -->'
issue_num=506
for _once in 1; do
  # shellcheck disable=SC1090
  source "$STEP5_HOLD_SNIPPET"
done
assert_eq "TC-TOKENBUDGET-064 unavailable trailer recovers review ownership" \
  '["autonomous","pending-review"]' "$(jq -c . "$DISPATCH_LABELS")"
dispatch_calls="$(cat "$DISPATCH_CALLS")"
assert_contains "TC-TOKENBUDGET-064 recovery uses terminal-aware pending route" \
  "transition|506|reviewing|pending-review" "$dispatch_calls"
assert_not_contains "TC-TOKENBUDGET-064 hold recovery does not route development" \
  "pending-dev" "$dispatch_calls"
assert_not_contains "TC-TOKENBUDGET-064 hold recovery does not stall without intent" \
  "|stalled" "$dispatch_calls"

dispatch_reset
dispatch_set_labels autonomous reviewing
dispatch_post_review_token
itp_post_comment 506 \
  '<!-- review-verdict: failed-non-substantive cause=token-budget-launch-refused -->'
TOKEN_BUDGET_TEST_ENABLED=1
issue_num=506
for _once in 1; do
  # shellcheck disable=SC1090
  source "$STEP5_HOLD_SNIPPET"
done
assert_eq "TC-TOKENBUDGET-066 launch-refusal trailer survives config removal" \
  '["autonomous","pending-review"]' "$(jq -c . "$DISPATCH_LABELS")"
dispatch_calls="$(cat "$DISPATCH_CALLS")"
assert_not_contains "TC-TOKENBUDGET-066 launch-refusal recovery avoids development" \
  "pending-dev" "$dispatch_calls"

dispatch_reset
dispatch_set_labels autonomous reviewing
itp_post_comment 506 \
  '<!-- review-verdict: failed-non-substantive cause=token-budget-launch-refused -->'
dispatch_post_review_token
TOKEN_BUDGET_TEST_ENABLED=1
TOKEN_BUDGET_TEST_MODE=hard
AGENT_TOKEN_BUDGET=100
issue_num=506
terminal_intent_cleanup_transition() {
  itp_transition_state "$1" "$3" "$4"
}
for _once in 1; do
  # shellcheck disable=SC1090
  source "$STEP5_HOLD_SNIPPET"
done
assert_eq "TC-TOKENBUDGET-083 stale review retry trailer preserves current ownership" \
  '["autonomous","reviewing"]' "$(jq -c . "$DISPATCH_LABELS")"
assert_not_contains "TC-TOKENBUDGET-083 historical trailer cannot requeue current generation" \
  "transition|506|reviewing|pending-review" "$(cat "$DISPATCH_CALLS")"
unset AGENT_TOKEN_BUDGET

dispatch_reset
dispatch_set_labels autonomous reviewing
dispatch_post_review_token
itp_post_comment 506 \
  '<!-- review-verdict: failed-non-substantive cause=token-budget-launch-refused -->'
jq -c --arg body '<!-- dispatcher-token: malformed-current at 2026-07-18T18:01:00Z mode=review run=review-run-2 -->
Dispatching autonomous review...' \
  '. + [{id:3,author:"pipeline-bot",authorKind:"self",body:$body,
         createdAt:null}]' \
  "$DISPATCH_COMMENTS" > "$WORK/dispatch-comments.tmp" \
  && mv "$WORK/dispatch-comments.tmp" "$DISPATCH_COMMENTS"
TOKEN_BUDGET_TEST_ENABLED=1
TOKEN_BUDGET_TEST_MODE=hard
AGENT_TOKEN_BUDGET=100
issue_num=506
for _once in 1; do
  # shellcheck disable=SC1090
  source "$STEP5_HOLD_SNIPPET"
done
assert_eq "TC-TOKENBUDGET-083 malformed current dispatch cannot reuse historical cutoff" \
  '["autonomous","reviewing"]' "$(jq -c . "$DISPATCH_LABELS")"
assert_not_contains "TC-TOKENBUDGET-083 malformed cutoff cannot requeue current generation" \
  "transition|506|reviewing|pending-review" "$(cat "$DISPATCH_CALLS")"
unset AGENT_TOKEN_BUDGET

dispatch_reset
dispatch_set_labels autonomous reviewing
DISPATCH_FIXED_CREATED_AT=2026-07-18T18:01:00Z
dispatch_post_review_token
itp_post_comment 506 \
  '<!-- review-verdict: failed-non-substantive cause=token-budget-launch-refused -->'
jq -c \
  '. + [{id:3,author:"pipeline-bot",authorKind:"self",body:42,
         createdAt:"2026-07-18T18:01:00Z"}]' \
  "$DISPATCH_COMMENTS" > "$WORK/dispatch-comments.tmp" \
  && mv "$WORK/dispatch-comments.tmp" "$DISPATCH_COMMENTS"
TOKEN_BUDGET_TEST_ENABLED=1
TOKEN_BUDGET_TEST_MODE=hard
AGENT_TOKEN_BUDGET=100
issue_num=506
for _once in 1; do
  # shellcheck disable=SC1090
  source "$STEP5_HOLD_SNIPPET"
done
assert_eq "TC-TOKENBUDGET-083 same-second higher-id retry trailer requeues review" \
  '["autonomous","pending-review"]' "$(jq -c . "$DISPATCH_LABELS")"
assert_contains "TC-TOKENBUDGET-083 non-string body cannot abort Step 5 classification" \
  "transition|506|reviewing|pending-review" "$(cat "$DISPATCH_CALLS")"
unset AGENT_TOKEN_BUDGET DISPATCH_FIXED_CREATED_AT
# shellcheck disable=SC1090
source "$TERMINAL_LIB"

dispatch_reset
dispatch_set_labels autonomous reviewing
TOKEN_BUDGET_TEST_ENABLED=0
TOKEN_BUDGET_TEST_MODE=hard
issue_num=506
for _once in 1; do
  # shellcheck disable=SC1090
  source "$STEP5_HOLD_SNIPPET"
done
assert_eq "TC-TOKENBUDGET-066 hard-mode budget crash retries review" \
  '["autonomous","pending-review"]' "$(jq -c . "$DISPATCH_LABELS")"
dispatch_calls="$(cat "$DISPATCH_CALLS")"
assert_not_contains "TC-TOKENBUDGET-066 retry fallback does not route development" \
  "pending-dev" "$dispatch_calls"

dispatch_reset
dispatch_set_labels autonomous reviewing
TOKEN_BUDGET_TEST_ENABLED=0
TOKEN_BUDGET_TEST_MODE=warn
issue_num=506
for _once in 1; do
  # shellcheck disable=SC1090
  source "$STEP5_HOLD_SNIPPET"
  # shellcheck disable=SC1090
  source "$STEP5_GENERIC_SNIPPET"
done
assert_eq "TC-TOKENBUDGET-078 warn-mode review crash preserves legacy route" \
  '["autonomous","pending-dev"]' "$(jq -c . "$DISPATCH_LABELS")"
dispatch_calls="$(cat "$DISPATCH_CALLS")"
assert_not_contains "TC-TOKENBUDGET-078 warn mode does not use hard retry fallback" \
  "transition|506|reviewing|pending-review" "$dispatch_calls"

echo "== Triple-persistence failure remains fail-closed =="
dispatch_reset
dispatch_set_labels autonomous in-progress
TOKEN_BUDGET_TEST_ENABLED=0
TOKEN_BUDGET_TEST_MODE=hard
AGENT_TOKEN_BUDGET=100
kind=issue
issue_num=506
_token_pending_owner=in-progress
: > "$DISPATCH_CALLS"
for _once in 1; do
  # shellcheck disable=SC1090
  source "$STEP5_DEV_FAIL_CLOSED_SNIPPET"
  printf 'fell-through\n' >> "$DISPATCH_CALLS"
done
assert_eq "TC-TOKENBUDGET-081 hard invocation recovery gap preserves dev ownership" \
  '["autonomous","in-progress"]' "$(jq -c . "$DISPATCH_LABELS")"
assert_not_contains "TC-TOKENBUDGET-081 hard invocation recovery gap cannot enter crash routing" \
  "fell-through" "$(cat "$DISPATCH_CALLS")"

dispatch_set_labels autonomous in-progress
DEV_LAUNCH_REFUSAL_RC=0
: > "$DISPATCH_CALLS"
for _once in 1; do
  # shellcheck disable=SC1090
  source "$STEP5_DEV_FAIL_CLOSED_SNIPPET"
  printf 'fell-through\n' >> "$DISPATCH_CALLS"
done
assert_eq "TC-TOKENBUDGET-081 durable launch refusal self-heals to retry state" \
  '["autonomous","pending-dev"]' "$(jq -c . "$DISPATCH_LABELS")"
assert_contains "TC-TOKENBUDGET-081 launch-refusal recovery remains terminal-aware" \
  "transition|506|in-progress|pending-dev" "$(cat "$DISPATCH_CALLS")"
unset DEV_LAUNCH_REFUSAL_RC

dispatch_set_labels autonomous reviewing
kind=review
_token_pending_owner=reviewing
: > "$DISPATCH_CALLS"
for _once in 1; do
  # shellcheck disable=SC1090
  source "$STEP5_REVIEW_FAIL_CLOSED_SNIPPET"
  printf 'fell-through\n' >> "$DISPATCH_CALLS"
done
assert_eq "TC-TOKENBUDGET-081 hard invocation recovery gap preserves review ownership" \
  '["autonomous","reviewing"]' "$(jq -c . "$DISPATCH_LABELS")"
assert_not_contains "TC-TOKENBUDGET-081 review recovery gap cannot launch another member" \
  "fell-through" "$(cat "$DISPATCH_CALLS")"
unset AGENT_TOKEN_BUDGET

echo "== Nested dispatcher admission error propagation =="
completed_rc="$(
  REPO=acme/widget REPO_OWNER=acme PROJECT_ID=widget \
    bash -c '
      source "$1"
      set +e
      classify_recent_review_verdict() {
        local -n verdict_ref="$3" cause_ref="$4" actionable_ref="$5"
        verdict_ref=none
        cause_ref=""
        actionable_ref=true
      }
      fetch_pr_for_issue() { return 0; }
      acquire_dispatch_marker() { return 0; }
      token_admission_gate() { return 1; }
      handle_completed_session_routing 506 session end
      printf "%s" "$?"
    ' _ "$DISPATCH_LIB"
)"
assert_eq "TC-TOKENBUDGET-080 completed-session router propagates gate refusal" \
  1 "$completed_rc"

delegated_rc="$(
  REPO=acme/widget REPO_OWNER=acme PROJECT_ID=widget \
    bash -c '
      source "$1"
      set +e
      fetch_pr_for_issue() {
        printf "%s\n" "{\"number\":1,\"headRefOid\":\"sha\"}"
      }
      last_reviewed_head() { printf "sha\n"; }
      extract_dev_session_id() { printf "session\n"; }
      is_session_completed() {
        local -n reason_ref="$2" end_ref="$3"
        reason_ref=completed
        end_ref=end
        return 0
      }
      handle_completed_session_routing() { return 1; }
      handle_pending_dev_pr_exists 506
      printf "%s" "$?"
    ' _ "$DISPATCH_LIB"
)"
assert_eq "TC-TOKENBUDGET-080 pending-PR delegation maps nested refusal to error" \
  2 "$delegated_rc"

self_heal_rc="$(
  REPO=acme/widget REPO_OWNER=acme PROJECT_ID=widget \
    bash -c '
      source "$1"
      set +e
      itp_list_comments() {
        printf "%s\n" "[{\"body\":\"review\",\"authorKind\":\"self\"}]"
      }
      classify_recent_review_verdict() {
        local -n verdict_ref="$3" cause_ref="$4" actionable_ref="$5"
        verdict_ref=failed-substantive
        cause_ref=test
        actionable_ref=true
      }
      acquire_dispatch_marker() { return 0; }
      token_admission_gate() { return 1; }
      _same_head_verdict_aware_recovery 506 "#1" sha self-heal 1
      printf "%s" "$?"
    ' _ "$DISPATCH_LIB"
)"
assert_eq "TC-TOKENBUDGET-080 same-HEAD self-heal maps gate refusal to error" \
  2 "$self_heal_rc"

printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
