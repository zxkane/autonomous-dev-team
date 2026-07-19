#!/bin/bash
# Static production-integration pins for issue #507 / INV-142.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
DEV="$SCRIPTS/autonomous-dev.sh"
REVIEW="$SCRIPTS/autonomous-review.sh"
TICK="$SCRIPTS/dispatcher-tick.sh"
AGENT="$SCRIPTS/lib-agent.sh"
TURN_LIB="$SCRIPTS/lib-turn-limit.sh"
CODEX="$SCRIPTS/adapters/codex.sh"
CONF="$SCRIPTS/autonomous.conf.example"
ADAPTER_DOC="$PROJECT_ROOT/docs/pipeline/adapter-spec.md"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"
TRANSITIONS="$PROJECT_ROOT/docs/pipeline/transitions.json"

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -Eq "$pattern" "$file"; then pass "$desc"; else fail "$desc"; fi
}
assert_not_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -Eq "$pattern" "$file"; then fail "$desc"; else pass "$desc"; fi
}
assert_count() {
  local desc="$1" expected="$2" pattern="$3" file="$4" count
  count="$(grep -Ec "$pattern" "$file" 2>/dev/null || true)"
  if [[ "$count" == "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc (expected=$expected actual=$count)"
  fi
}

echo "== TC-TURNLIMIT-001..020: startup validation =="
for file in "$DEV" "$REVIEW" "$TICK"; do
  assert_grep "TC-TURNLIMIT-010 $(basename "$file") sources one turn library" \
    'source .*lib-turn-limit\.sh' "$file"
  assert_grep "TC-TURNLIMIT-004/008 $(basename "$file") validates turn config" \
    'turn_limit_validate_config' "$file"
done
assert_grep "TC-TURNLIMIT-019 dev validates execution-host capability" \
  'turn_limit_validate_launches.*AGENT_CMD.*dev' "$DEV"
assert_grep "TC-TURNLIMIT-019 review validates every configured member" \
  'turn_limit_validate_launches' "$REVIEW"
assert_not_grep "TC-TURNLIMIT-019 dispatcher has no capability/admission gate" \
  'turn_limit_validate_launch|admit_next_request' "$TICK"

echo "== TC-TURNLIMIT-021..030: observer and synthetic isolation =="
assert_grep "TC-TURNLIMIT-021 recorder invokes observer on complete records" \
  'observe_completed_turn.*line|_agent_turn_observe_record' "$AGENT"
assert_not_grep "TC-TURNLIMIT-030 observer implementation does not live in signaller" \
  '^observe_completed_turn\(\)' "$AGENT"
assert_not_grep "TC-TURNLIMIT-068 production adapter source loop excludes synthetic" \
  'for _adapter in .*synthetic' "$AGENT"
assert_not_grep "TC-TURNLIMIT-068 production dispatch cases exclude synthetic" \
  'claude\|codex\|gemini\|kiro\|opencode\|agy\|synthetic' "$AGENT"
assert_not_grep "TC-TURNLIMIT-068 example config never selects synthetic" \
  'AGENT_(CMD|DEV_CMD|REVIEW_CMD).*synthetic' "$CONF"
assert_not_grep "TC-TURNLIMIT-068 adapter docs never offer synthetic to operators" \
  'AGENT_(CMD|DEV_CMD|REVIEW_CMD).*synthetic' "$ADAPTER_DOC"

echo "== TC-TURNLIMIT-040..052: watchdog and terminal routing =="
assert_grep "TC-TURNLIMIT-040 inactive path keeps GNU timeout argv" \
  'cmd\+=\("\$_AGENT_TIMEOUT_CMD" --kill-after=30s --signal=TERM "\$AGENT_TIMEOUT"\)' "$AGENT"
assert_grep "TC-TURNLIMIT-042 controlled stop rc is distinct" \
  'TURN_CONTROL_STOP_RC.*92' "$TURN_LIB"
assert_grep "TC-TURNLIMIT-079 control-plane error rc is distinct" \
  'TURN_CONTROL_ERROR_RC.*93' "$TURN_LIB"
assert_grep "TC-TURNLIMIT-088 dev finish receives the invocation rc" \
  '_resource_dev_launch_finish "\$AGENT_EXIT"' "$DEV"
dev_finish_block="$(sed -n '/^_resource_dev_launch_finish()/,/^}/p' "$DEV")"
if grep -Eq 'TURN_DEV_MODE.*hard' <<<"$dev_finish_block" \
    && grep -Eq 'launch_rc.*TURN_CONTROL_ERROR_RC' <<<"$dev_finish_block"; then
  pass "TC-TURNLIMIT-095 dev rc 93 is control-only in hard mode"
else
  fail "TC-TURNLIMIT-095 dev rc 93 is control-only in hard mode"
fi
review_rc_block="$(sed -n \
  '/# Read each agent.s launch exit code/,/# PGID sidecar/p' "$REVIEW")"
if grep -Eq 'TURN_REVIEW_MODE.*hard' <<<"$review_rc_block" \
    && grep -Eq 'AGENT_LAUNCH_RC.*TURN_CONTROL_ERROR_RC' <<<"$review_rc_block"; then
  pass "TC-TURNLIMIT-095 review rc 93 is control-only in hard mode"
else
  fail "TC-TURNLIMIT-095 review rc 93 is control-only in hard mode"
fi
assert_grep "TC-TURNLIMIT-088 resume fallback excludes turn-control refusal" \
  'TURN_DEV_LAUNCH_REFUSED.*!=.*true' "$DEV"
assert_grep "TC-TURNLIMIT-079 prelaunch control faults return the error rc" \
  'return "\$TURN_CONTROL_ERROR_RC"' "$AGENT"
assert_grep "TC-TURNLIMIT-036 terminating persistence precedes TERM" \
  'turn_control_mark_terminating' "$AGENT"
assert_grep "TC-TURNLIMIT-051 dev maps only turn-cap to terminal intent" \
  'terminal_intent_write.*turn-cap.*dev-wrapper|turn_control_route_terminal.*dev-wrapper' "$DEV"
assert_grep "TC-TURNLIMIT-051 review delegates trigger terminal routing" \
  'turn_control_review_post_fanout' "$REVIEW"
assert_grep "TC-TURNLIMIT-051 review helper owns trigger terminal intent" \
  'turn_control_route_terminal.*issue.*review-wrapper' "$TURN_LIB"
assert_not_grep "TC-TURNLIMIT-051 dev never calls mark_stalled for turn cap" \
  'turn-cap.*mark_stalled|mark_stalled.*turn-cap' "$DEV"
assert_not_grep "TC-TURNLIMIT-060 review never calls mark_stalled for turn cap" \
  'turn-cap.*mark_stalled|mark_stalled.*turn-cap' "$REVIEW"
assert_grep "TC-TURNLIMIT-049 trigger unknown reason pinned" \
  'turn-cap' "$DEV"
assert_grep "TC-TURNLIMIT-050 sibling unknown reason pinned" \
  'fanout-cancelled' "$TURN_LIB"
assert_grep "TC-TURNLIMIT-048 normal hard review closes accounting" \
  'token_budget_enabled.*TURN_REVIEW_MODE.*hard|TURN_REVIEW_MODE.*hard.*token_budget_enabled' "$REVIEW"
assert_not_grep "TC-TURNLIMIT-031 wrappers use the accounting facade" \
  '^[[:space:]]*(if[[:space:]]+![[:space:]]+)?accounting_(invocation_id|start)([[:space:]]|$)|\$\([[:space:]]*accounting_(invocation_id|start)([[:space:]]|$)' "$DEV"
assert_not_grep "TC-TURNLIMIT-031 review uses the accounting facade" \
  '^[[:space:]]*(if[[:space:]]+![[:space:]]+)?accounting_(invocation_id|start)([[:space:]]|$)|\$\([[:space:]]*accounting_(invocation_id|start)([[:space:]]|$)' "$REVIEW"
assert_grep "TC-TURNLIMIT-031 dev initializes through turn accounting facade" \
  'turn_accounting_begin' "$DEV"
assert_grep "TC-TURNLIMIT-031 review initializes through turn accounting facade" \
  'turn_accounting_begin' "$REVIEW"
assert_grep "TC-TURNLIMIT-096 review initialization cleanup checks commit result" \
  'turn_accounting_commit_succeeded' "$REVIEW"

echo "== TC-TURNLIMIT-053..061: review fan-out ownership =="
assert_grep "TC-TURNLIMIT-054 launch loop checks trip" \
  'turn_fanout_trip_active' "$REVIEW"
assert_grep "TC-TURNLIMIT-074 final member spawn is trip-serialized" \
  '_turn_control_lock.*_turn_trip_file' "$AGENT"
assert_grep "TC-TURNLIMIT-055 codex rerun checks trip" \
  'turn_fanout_trip_active' "$CODEX"
assert_grep "TC-TURNLIMIT-056 member watchdog consumes trip" \
  'turn_control_sync_fanout_trip' "$AGENT"
assert_grep "TC-TURNLIMIT-056 hard fan-out cannot early-reap live members" \
  'TURN_REVIEW_MODE.*!=.*hard.*_all_first_verdicts_resolved' "$REVIEW"
assert_grep "TC-TURNLIMIT-059 trip route suppresses aggregation" \
  'turn_fanout_trip_active' "$REVIEW"
assert_grep "TC-TURNLIMIT-090 review wrapper delegates post-fan-out orchestration" \
  'turn_control_review_post_fanout' "$REVIEW"
assert_grep "TC-TURNLIMIT-060 trip route uses terminal cleanup helper" \
  'terminal_intent_cleanup_transition.*reviewing.*reviewing.*pending-dev' "$REVIEW"
assert_count "TC-TURNLIMIT-058 INV-43 reaper implementation remains one function" 1 \
  '^_reap_fanout_processes\(\)' "$SCRIPTS/lib-review-poll.sh"
trip_block="$(sed -n \
  '/# \[INV-142\] A hard member trip/,/# Issue #449 (R1): pre-aggregation/p' \
  "$REVIEW")"
if [[ "$(grep -Ec 'turn_control_review_post_fanout' <<<"$trip_block")" == "1" ]] \
    && [[ "$(grep -Ec 'terminal_intent_cleanup_transition' "$TURN_LIB")" == "1" ]]; then
  pass "TC-TURNLIMIT-060 hard-trip branch performs one stalled transition"
else
  fail "TC-TURNLIMIT-060 hard-trip branch performs one stalled transition"
fi
if grep -Eq '_aggregate_review_verdicts|chp_approve|chp_merge' <<<"$trip_block"; then
  fail "TC-TURNLIMIT-059 hard-trip branch skips aggregate/approve/merge"
else
  pass "TC-TURNLIMIT-059 hard-trip branch skips aggregate/approve/merge"
fi
if grep -Eq 'turn_control_review_post_fanout' <<<"$trip_block" \
    && grep -Eq '^turn_control_route_review\(\)' "$TURN_LIB"; then
  pass "TC-TURNLIMIT-080 hard-trip branch delegates trip and unpublished-cap routing"
else
  fail "TC-TURNLIMIT-080 hard-trip branch delegates trip and unpublished-cap routing"
fi
post_decision_block="$(sed -n \
  '/^_turn_review_post_fanout_decision()/,/^}/p' "$REVIEW")"
if grep -Eq 'TURN_CONTROL_REVIEW_ROUTED_RC' <<<"$post_decision_block" \
    && grep -Eq 'RESULT_PARSED=true' <<<"$post_decision_block" \
    && grep -Eq 'return 0' <<<"$post_decision_block" \
    && grep -Eq 'exit "\$_turn_review_wrapper_rc"' <<<"$trip_block"; then
  pass "TC-TURNLIMIT-059 hard-trip branch exits before aggregation"
else
  fail "TC-TURNLIMIT-059 hard-trip branch exits before aggregation"
fi
partial_init_block="$trip_block"
if grep -Eq 'TURN_CONTROL_REVIEW_REFUSED_RC' <<<"$post_decision_block" \
    && grep -Eq 'RESULT_PARSED=true' <<<"$post_decision_block" \
    && grep -Eq 'return 1' <<<"$post_decision_block" \
    && grep -Eq 'exit "\$_turn_review_wrapper_rc"' <<<"$partial_init_block"; then
  pass "TC-TURNLIMIT-059 partial initialization refuses verdict aggregation"
else
  fail "TC-TURNLIMIT-059 partial initialization refuses verdict aggregation"
fi
if grep -Eq '_aggregate_review_verdicts|chp_approve|chp_merge' <<<"$partial_init_block"; then
  fail "TC-TURNLIMIT-059 partial initialization branch skips aggregate/approve/merge"
else
  pass "TC-TURNLIMIT-059 partial initialization branch skips aggregate/approve/merge"
fi
assert_grep "TC-TURNLIMIT-109 review member budget evaluation is idempotent" \
  '_token_review_evaluate_members_once' "$REVIEW"
partial_refusal_line="$(grep -n '_turn_review_post_fanout_decision "\$_turn_review_post_rc"' "$REVIEW" | head -1 | cut -d: -f1)"
partial_budget_line="$(grep -n '_token_review_evaluate_members_once' "$REVIEW" | sed -n '2p' | cut -d: -f1)"
if [[ "$partial_budget_line" =~ ^[0-9]+$ && "$partial_refusal_line" =~ ^[0-9]+$ \
    && "$partial_budget_line" -lt "$partial_refusal_line" ]]; then
  pass "TC-TURNLIMIT-109 partial refusal evaluates budgets before terminal exit"
else
  fail "TC-TURNLIMIT-109 partial refusal evaluates budgets before terminal exit"
fi
assert_grep "TC-TURNLIMIT-113 dev stages durable turn-cap recovery" \
  'turn_control_recovery_stage.*dev-wrapper' "$DEV"
assert_grep "TC-TURNLIMIT-113 review stages durable turn-cap recovery" \
  'turn_control_recovery_stage.*review-wrapper' "$TURN_LIB"
assert_grep "TC-TURNLIMIT-113 dispatcher recovers turn caps before crash routing" \
  'turn_control_recover_pending_intent' "$TICK"
assert_grep "TC-TURNLIMIT-113 dispatcher finalizes recovered turn lifecycle" \
  'turn_control_recovery_complete' "$TICK"

echo "== TC-TURNLIMIT-069..070: docs and config =="
assert_grep "TC-TURNLIMIT-069 INV-142 exists" '^## INV-142:' "$INVARIANTS"
assert_grep "TC-TURNLIMIT-069 turn-cap stalled cause exists" \
  '"event"[[:space:]]*:[[:space:]]*"turn-cap"' "$TRANSITIONS"
for var in AGENT_TURN_LIMIT AGENT_DEV_TURN_LIMIT AGENT_REVIEW_TURN_LIMIT TURN_LIMIT_MODE; do
  assert_grep "TC-TURNLIMIT-069 $var documented" "^# ${var}=" "$CONF"
done

printf 'TURN-LIMIT-WIRING-SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
