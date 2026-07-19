#!/bin/bash
# test-token-budget-wiring.sh - production integration pins for issue #506.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEV="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
REVIEW="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"
DISPATCH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
CONF="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous.conf.example"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -Eq "$pattern" "$file"; then pass "$desc"; else fail "$desc"; fi
}
assert_count() {
  local desc="$1" expected="$2" pattern="$3" file="$4" got
  got="$(grep -Ec "$pattern" "$file" || true)"
  if [[ "$got" == "$expected" ]]; then
    pass "$desc"
  else
    fail "$desc"
    printf '      expected=%s actual=%s pattern=%s\n' "$expected" "$got" "$pattern"
  fi
}

echo "== TC-TOKENBUDGET-010..021: wrapper accounting wiring =="
assert_grep "TC-TOKENBUDGET-009 dev sources token library" \
  'source .*lib-token-budget\.sh' "$DEV"
assert_grep "TC-TOKENBUDGET-009 review sources token library" \
  'source .*lib-token-budget\.sh' "$REVIEW"
assert_grep "TC-TOKENBUDGET-010 dev starts attempt accounting" \
  'token_accounting_begin' "$DEV"
assert_grep "TC-TOKENBUDGET-010 dev identity pins side/member to dev" \
  '"\$ISSUE_NUMBER" "\${RUN_ID:-}" dev dev "\$TOKEN_DEV_ATTEMPT"' "$DEV"
assert_count "TC-TOKENBUDGET-085 dev token-budget calls tolerate missing run artifacts" \
  4 '"\$\{RUN_ID:-\}"' "$DEV"
assert_grep "TC-TOKENBUDGET-010 dev captures a launch-local log offset" \
  'token_budget_log_offset.*LOG_FILE' "$DEV"
assert_count "TC-TOKENBUDGET-010/011 all three dev launch sites start accounting" \
  3 'if ! _token_dev_launch_begin; then' "$DEV"
assert_count "TC-TOKENBUDGET-010/011 all three dev launch sites finish accounting" \
  3 '_token_dev_launch_finish \|\| true' "$DEV"
assert_grep "TC-TOKENBUDGET-050 dev evaluates before cleanup transitions" \
  'token_budget_evaluate_dev_run' "$DEV"

assert_grep "TC-TOKENBUDGET-012 review accounting keys member UUID" \
  'token_accounting_begin.*review.*_agent_session_id' "$REVIEW"
assert_count "TC-TOKENBUDGET-085 review token-budget calls tolerate missing run artifacts" \
  2 '"\$\{RUN_ID:-\}"' "$REVIEW"
assert_count "TC-TOKENBUDGET-013 codex reruns share the member accounting invocation" \
  1 'token_accounting_begin.*review.*_agent_session_id' "$REVIEW"
assert_grep "TC-TOKENBUDGET-017 review dropped member commits member-dropped" \
  '_munknown="member-dropped"' "$REVIEW"
assert_grep "TC-TOKENBUDGET-017 review universally commits started members" \
  'AGENT_ACCOUNTING_RESULTS.*token_accounting_commit' "$REVIEW"
assert_grep "TC-TOKENBUDGET-012 review generic logs include the member UUID" \
  'if token_budget_enabled' "$REVIEW"
assert_grep "TC-TOKENBUDGET-012 review controller logs retain per-member source paths" \
  'AGENT_CONTROLLER_LOGS.*_agent_log' "$REVIEW"
assert_grep "TC-TOKENBUDGET-052 review violation explicitly invokes cleanup guard" \
  'terminal_intent_cleanup_transition.*reviewing.*reviewing.*pending-dev' "$REVIEW"
assert_grep "TC-TOKENBUDGET-054 review unavailable hold returns to pending-review" \
  'token-budget.*unavailable|Token-budget.*unavailable' "$REVIEW"
assert_grep "TC-TOKENBUDGET-054 failed unavailable hold is durably recoverable" \
  'token-budget-unavailable' "$REVIEW"
assert_grep "TC-TOKENBUDGET-054 unavailable hold emits a non-substantive trailer" \
  'emit_verdict_trailer.*failed-non-substantive' "$REVIEW"
assert_grep "TC-TOKENBUDGET-052 review intent persistence failure refuses approval" \
  '_token_review_member_gate_rc.*-eq 21|_token_review_issue_gate_rc.*-eq 21' "$REVIEW"
if grep -A3 -F 'if [[ "$TOKEN_BUDGET_LAUNCH_REFUSED" == "true" ]] \' "$DEV" \
    | grep -Fq 'token_budget_launch_refusal_can_retry "$_token_budget_eval_rc"'; then
  pass "TC-TOKENBUDGET-050 dev startup refusal bypasses startup label mutation"
else
  fail "TC-TOKENBUDGET-050 dev startup refusal bypasses startup label mutation"
fi
assert_grep "TC-TOKENBUDGET-081 dev retry marker cannot mask an undurable terminal decision" \
  'token_budget_launch_refusal_can_retry "\$_token_budget_eval_rc"' "$DEV"
assert_count "TC-TOKENBUDGET-081 dev launch refusal posts a durable retry marker" \
  2 'token_budget_post_launch_refusal' "$DEV"
assert_grep "TC-TOKENBUDGET-050 SIGTERM unknown path evaluates before defer" \
  '_token_dev_evaluate_cleanup' "$DEV"

echo "== TC-TOKENBUDGET-070: all seven dispatcher admission sites =="
assert_count "TC-TOKENBUDGET-070 tick dev-new site" 1 \
  'token_admission_gate "\$issue_num" "" "dev-new"' "$TICK"
assert_count "TC-TOKENBUDGET-070 tick review site" 1 \
  'token_admission_gate "\$issue_num" "pending-review" "review"' "$TICK"
assert_count "TC-TOKENBUDGET-070 tick PTL site" 1 \
  'token_admission_gate "\$issue_num" "pending-dev" "dev-new"' "$TICK"
assert_count "TC-TOKENBUDGET-070 tick dev-resume site" 1 \
  'token_admission_gate "\$issue_num" "pending-dev" "dev-resume"' "$TICK"
assert_count "TC-TOKENBUDGET-070 lib-dispatch fresh-dev sites" 3 \
  'token_admission_gate "\$issue_num" "pending-dev" "dev-new"' "$DISPATCH"
assert_grep "TC-TOKENBUDGET-080 completed-session admission errors reach the tick" \
  '_completed_route_rc=\$\?' "$TICK"
assert_grep "TC-TOKENBUDGET-080 pending-PR router distinguishes unhandled from errors" \
  '_pending_pr_route_rc.*-ne 1' "$TICK"
assert_grep "TC-TOKENBUDGET-080 nested completed-session errors are propagated" \
  '_completed_route_rc.*return 2' "$DISPATCH"
assert_grep "TC-TOKENBUDGET-080 self-heal admission errors are propagated" \
  '_recovery_token_gate_rc.*-ne 0' "$DISPATCH"
assert_grep "TC-TOKENBUDGET-079 dev Step 5 retries pending invocation intents" \
  'token_budget_recover_pending_intent.*dev-wrapper' "$TICK"
assert_grep "TC-TOKENBUDGET-079 review Step 5 retries pending invocation intents" \
  'token_budget_recover_pending_intent.*review-wrapper' "$TICK"
assert_grep "TC-TOKENBUDGET-081 dev Step 5 distinguishes durable launch refusal" \
  'token_budget_recent_launch_refusal.*issue_num.*dev' "$TICK"

assert_grep "TC-TOKENBUDGET-004 dispatcher validates config before scans" \
  'token_budget_validate_config' "$TICK"
assert_grep "TC-TOKENBUDGET-001 dispatcher sources accounting authority" \
  'source .*lib-accounting\.sh' "$TICK"
assert_grep "TC-TOKENBUDGET-056 dispatcher sources terminal control" \
  'source .*lib-terminal-control\.sh' "$TICK"

echo "== TC-TOKENBUDGET-077: configuration documentation =="
assert_grep "TC-TOKENBUDGET-077 AGENT_TOKEN_BUDGET documented" \
  '^# AGENT_TOKEN_BUDGET=' "$CONF"
assert_grep "TC-TOKENBUDGET-077 ISSUE_TOKEN_BUDGET documented" \
  '^# ISSUE_TOKEN_BUDGET=' "$CONF"
assert_grep "TC-TOKENBUDGET-077 TOKEN_BUDGET_MODE documented" \
  '^# TOKEN_BUDGET_MODE=' "$CONF"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
