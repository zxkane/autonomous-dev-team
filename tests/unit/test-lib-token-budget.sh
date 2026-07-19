#!/bin/bash
# test-lib-token-budget.sh - issue #506 / INV-141.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-token-budget.sh"
ACCOUNTING_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-accounting.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail "$desc"
    printf '      expected=[%s]\n      actual=  [%s]\n' "$expected" "$actual"
  fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc"
    printf '      missing=[%s]\n      actual= [%s]\n' "$needle" "$haystack"
  fi
}
assert_rc() { assert_eq "$1" "$2" "$3"; }

if [[ ! -r "$LIB" ]]; then
  fail "setup: lib-token-budget.sh exists"
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CALLS="$WORK/calls"
COMMENTS="$WORK/comments.json"
: > "$CALLS"
printf '[]\n' > "$COMMENTS"

# Complete ITP comment seam for the consumer library at source time. Warning
# tests below replace these with the persistent comment fixture.
itp_list_comments() { printf '[]\n'; }
itp_post_comment() { return 0; }
itp_read_task() { printf '{"labels":[]}\n'; }
itp_transition_state() { return 0; }

# shellcheck source=/dev/null
source "$ACCOUNTING_LIB"
source "$LIB"
set +e

run_rc() {
  "$@" >"$WORK/out" 2>"$WORK/err"
  printf '%s' "$?"
}

reset_config() {
  unset AGENT_TOKEN_BUDGET ISSUE_TOKEN_BUDGET TOKEN_BUDGET_MODE
}

echo "== TC-TOKENBUDGET-001..009: configuration and pure helpers =="
reset_config
assert_rc "TC-TOKENBUDGET-001 unset config validates" 0 \
  "$(run_rc token_budget_validate_config)"
assert_rc "TC-TOKENBUDGET-001 unset config is disabled" 1 \
  "$(run_rc token_budget_enabled)"
assert_eq "TC-TOKENBUDGET-001 disabled mode token" disabled \
  "$(token_budget_effective_mode)"

AGENT_TOKEN_BUDGET=10
assert_rc "TC-TOKENBUDGET-002 positive invocation budget validates" 0 \
  "$(run_rc token_budget_validate_config)"
assert_eq "TC-TOKENBUDGET-002 mode defaults to warn" warn \
  "$(token_budget_effective_mode)"
ISSUE_TOKEN_BUDGET=20
TOKEN_BUDGET_MODE=hard
assert_rc "TC-TOKENBUDGET-003 both budgets and hard mode validate" 0 \
  "$(run_rc token_budget_validate_config)"
assert_eq "TC-TOKENBUDGET-003 explicit hard mode preserved" hard \
  "$(token_budget_effective_mode)"

for bad in 0 -1 abc 01 '1.5'; do
  reset_config
  AGENT_TOKEN_BUDGET="$bad"
  rc="$(run_rc token_budget_validate_config)"
  assert_rc "TC-TOKENBUDGET-004 AGENT_TOKEN_BUDGET='$bad' refused" 1 "$rc"
  assert_contains "TC-TOKENBUDGET-004 diagnostic names AGENT_TOKEN_BUDGET='$bad'" \
    "AGENT_TOKEN_BUDGET" "$(cat "$WORK/err")"
  assert_contains "TC-TOKENBUDGET-004 diagnostic includes value '$bad'" "$bad" \
    "$(cat "$WORK/err")"
done

reset_config
ISSUE_TOKEN_BUDGET=oops
assert_rc "TC-TOKENBUDGET-004 invalid ISSUE_TOKEN_BUDGET refused" 1 \
  "$(run_rc token_budget_validate_config)"
assert_contains "TC-TOKENBUDGET-004 issue diagnostic names variable" \
  "ISSUE_TOKEN_BUDGET" "$(cat "$WORK/err")"

reset_config
TOKEN_BUDGET_MODE=soft
assert_rc "TC-TOKENBUDGET-005 invalid mode refused even without a budget" 1 \
  "$(run_rc token_budget_validate_config)"
assert_contains "TC-TOKENBUDGET-005 mode diagnostic names variable" \
  "TOKEN_BUDGET_MODE" "$(cat "$WORK/err")"

assert_rc "TC-TOKENBUDGET-006 completed under is allowed" 1 \
  "$(run_rc token_budget_completed_exceeded 9 10)"
assert_rc "TC-TOKENBUDGET-006 completed equality is allowed" 1 \
  "$(run_rc token_budget_completed_exceeded 10 10)"
assert_rc "TC-TOKENBUDGET-006 completed over violates" 0 \
  "$(run_rc token_budget_completed_exceeded 11 10)"
assert_rc "TC-TOKENBUDGET-007 admission under is allowed" 1 \
  "$(run_rc token_budget_admission_reached 9 10)"
assert_rc "TC-TOKENBUDGET-007 admission equality blocks" 0 \
  "$(run_rc token_budget_admission_reached 10 10)"
assert_rc "TC-TOKENBUDGET-007 admission over blocks" 0 \
  "$(run_rc token_budget_admission_reached 11 10)"
assert_rc "TC-TOKENBUDGET-081 clean evaluation permits launch-refusal retry" 0 \
  "$(run_rc token_budget_launch_refusal_can_retry 0)"
assert_rc "TC-TOKENBUDGET-081 terminal violation suppresses launch-refusal retry" 1 \
  "$(run_rc token_budget_launch_refusal_can_retry 10)"
assert_rc "TC-TOKENBUDGET-081 undurable violation suppresses launch-refusal retry" 1 \
  "$(run_rc token_budget_launch_refusal_can_retry 21)"
assert_rc "TC-TOKENBUDGET-081 malformed evaluation rc is rejected" 2 \
  "$(run_rc token_budget_launch_refusal_can_retry invalid)"
assert_rc "TC-TOKENBUDGET-006 oversized completed equality is allowed" 1 \
  "$(run_rc token_budget_completed_exceeded 999999999999999999999999 999999999999999999999999)"
assert_rc "TC-TOKENBUDGET-006 oversized completed over violates" 0 \
  "$(run_rc token_budget_completed_exceeded 1000000000000000000000000 999999999999999999999999)"
assert_rc "TC-TOKENBUDGET-007 oversized admission equality blocks" 0 \
  "$(run_rc token_budget_admission_reached 999999999999999999999999 999999999999999999999999)"
assert_rc "TC-TOKENBUDGET-007 oversized admission under is allowed" 1 \
  "$(run_rc token_budget_admission_reached 999999999999999999999998 999999999999999999999999)"

assert_rc "TC-TOKENBUDGET-008 claude accountable" 0 \
  "$(run_rc token_budget_adapter_accountable claude)"
assert_rc "TC-TOKENBUDGET-008 codex accountable" 0 \
  "$(run_rc token_budget_adapter_accountable codex)"
assert_rc "TC-TOKENBUDGET-008 kiro unavailable" 1 \
  "$(run_rc token_budget_adapter_accountable kiro)"
assert_rc "TC-TOKENBUDGET-008 agy unavailable" 1 \
  "$(run_rc token_budget_adapter_accountable agy)"
assert_rc "TC-TOKENBUDGET-008 gemini unavailable" 1 \
  "$(run_rc token_budget_adapter_accountable gemini)"
assert_rc "TC-TOKENBUDGET-008 opencode unavailable" 1 \
  "$(run_rc token_budget_adapter_accountable opencode)"
assert_rc "TC-TOKENBUDGET-008 future adapters default unavailable" 1 \
  "$(run_rc token_budget_adapter_accountable future-adapter)"

SOURCE_OUT="$(
  AUTONOMOUS_ACCOUNTING_DIR="$WORK/does-not-exist/accounting" \
    AGENT_TOKEN_BUDGET= ISSUE_TOKEN_BUDGET= TOKEN_BUDGET_MODE= \
    bash -c 'source "$1"' _ "$LIB" 2>&1
)"
assert_eq "TC-TOKENBUDGET-009 source emits no output" "" "$SOURCE_OUT"
if [[ ! -e "$WORK/does-not-exist" ]]; then
  pass "TC-TOKENBUDGET-009 source performs no filesystem I/O"
else
  fail "TC-TOKENBUDGET-009 source performs no filesystem I/O"
fi
printf 'four' > "$WORK/offset.log"
assert_eq "TC-TOKENBUDGET-014 log offset reads the current byte count" 4 \
  "$(token_budget_log_offset "$WORK/offset.log")"
assert_eq "TC-TOKENBUDGET-014 missing log starts at byte zero" 0 \
  "$(token_budget_log_offset "$WORK/missing.log")"
wc() { printf 'not-a-count\n'; }
assert_eq "TC-TOKENBUDGET-014 malformed byte count fails closed to zero" 0 \
  "$(token_budget_log_offset "$WORK/offset.log")"
unset -f wc

echo "== TC-TOKENBUDGET-010..021: accounting adapters =="
reset_config
AGENT_TOKEN_BUDGET=100
TOKEN_BUDGET_MODE=warn

accounting_invocation_id() {
  [[ "${FAIL_ID:-0}" != 1 ]] || return 1
  printf 'inv-%s-%s-%s-%s\n' "$1" "$2" "$3" "$4"
}
accounting_start() {
  printf 'start|%s\n' "$*" >> "$CALLS"
  [[ "${FAIL_START:-0}" != 1 ]]
}
accounting_commit_usage() {
  printf 'usage|%s\n' "$*" >> "$CALLS"
  [[ "${FAIL_COMMIT:-0}" != 1 ]]
}
accounting_commit_unknown() {
  printf 'unknown|%s\n' "$*" >> "$CALLS"
  [[ "${FAIL_COMMIT:-0}" != 1 ]]
}
metrics_parse_tokens() {
  printf 'parse|%s|%s\n' "$1" "${2:-0}" >> "$CALLS"
  printf '%s\n' "${PARSED_USAGE:-}"
}

: > "$CALLS"
id="$(token_accounting_begin 506 RUN-A dev dev 1 claude)"
assert_eq "TC-TOKENBUDGET-010 dev identity uses attempt 1" inv-RUN-A-dev-dev-1 "$id"
assert_contains "TC-TOKENBUDGET-010 start receives canonical tuple" \
  "start|506 inv-RUN-A-dev-dev-1 dev RUN-A dev 1" "$(cat "$CALLS")"

id2="$(token_accounting_begin 506 RUN-A dev dev 2 claude)"
assert_eq "TC-TOKENBUDGET-011 retry identity uses attempt 2" inv-RUN-A-dev-dev-2 "$id2"
ra="$(token_accounting_begin 506 REVIEW review UUID-A 1 codex)"
rb="$(token_accounting_begin 506 REVIEW review UUID-B 1 codex)"
if [[ "$ra" != "$rb" ]]; then
  pass "TC-TOKENBUDGET-012 review member UUIDs stay distinct"
else
  fail "TC-TOKENBUDGET-012 review member UUIDs stay distinct"
fi

PARSED_USAGE="input_tokens=60 output_tokens=40 total_tokens=100"
: > "$CALLS"
result="$(token_accounting_commit 506 "$id" "$WORK/dev.log" 17)"
assert_contains "TC-TOKENBUDGET-014 parser receives fresh offset" \
  "parse|$WORK/dev.log|17" "$(cat "$CALLS")"
assert_contains "TC-TOKENBUDGET-014 strict usage commit carries all fields" \
  "usage|506 $id 100 60 40" "$(cat "$CALLS")"
assert_eq "TC-TOKENBUDGET-014 normalized state is committed" usage-committed \
  "$(jq -r .state <<<"$result")"
assert_eq "TC-TOKENBUDGET-014 normalized total retained" 100 \
  "$(jq -r .total_tokens <<<"$result")"

PARSED_USAGE="total_tokens=77"
: > "$CALLS"
result="$(token_accounting_commit 506 "$id2" "$WORK/dev.log" 99)"
assert_contains "TC-TOKENBUDGET-015 missing components become dash" \
  "usage|506 $id2 77 - -" "$(cat "$CALLS")"

PARSED_USAGE=""
: > "$CALLS"
result="$(token_accounting_commit 506 "$id2" "$WORK/dev.log" 100)"
assert_contains "TC-TOKENBUDGET-016 no parser result commits unknown" \
  "unknown|506 $id2 no-usage-in-log" "$(cat "$CALLS")"
assert_eq "TC-TOKENBUDGET-016 normalized unknown state" usage-unknown \
  "$(jq -r .state <<<"$result")"

: > "$CALLS"
result="$(token_accounting_commit 506 "$ra" "$WORK/review.log" 0 member-dropped)"
assert_contains "TC-TOKENBUDGET-017 dropped member commits explicit reason" \
  "unknown|506 $ra member-dropped" "$(cat "$CALLS")"

FAIL_COMMIT=1
PARSED_USAGE="total_tokens=3"
result="$(token_accounting_commit 506 "$id" "$WORK/dev.log" 0 2>"$WORK/commit.err")"
assert_eq "TC-TOKENBUDGET-018 failed commit normalizes to unknown" usage-unknown \
  "$(jq -r .state <<<"$result")"
assert_eq "TC-TOKENBUDGET-018 failed commit flag is true" true \
  "$(jq -r .commit_failed <<<"$result")"
assert_contains "TC-TOKENBUDGET-018 failed commit is loud" "commit" \
  "$(cat "$WORK/commit.err")"
unset FAIL_COMMIT

FAIL_START=1
assert_rc "TC-TOKENBUDGET-019 warn start failure degrades to launch" 0 \
  "$(run_rc token_accounting_begin 506 RUN-B dev dev 1 claude)"
assert_contains "TC-TOKENBUDGET-019 warn start failure is loud" "accounting_start" \
  "$(cat "$WORK/err")"
TOKEN_BUDGET_MODE=hard
assert_rc "TC-TOKENBUDGET-019 hard start failure refuses launch" 1 \
  "$(run_rc token_accounting_begin 506 RUN-B dev dev 1 claude)"
unset FAIL_START

FAIL_ID=1
TOKEN_BUDGET_MODE=warn
assert_rc "TC-TOKENBUDGET-019 warn identity failure degrades to launch" 0 \
  "$(run_rc token_accounting_begin 506 RUN-B dev dev 1 claude)"
assert_contains "TC-TOKENBUDGET-019 warn identity failure is loud" \
  "accounting_invocation_id" "$(cat "$WORK/err")"
TOKEN_BUDGET_MODE=hard
assert_rc "TC-TOKENBUDGET-019 hard identity failure refuses launch" 1 \
  "$(run_rc token_accounting_begin 506 RUN-B dev dev 1 claude)"
unset FAIL_ID

assert_rc "TC-TOKENBUDGET-020 hard unaccountable adapter refuses" 1 \
  "$(run_rc token_accounting_begin 506 RUN-B dev dev 1 kiro)"
TOKEN_BUDGET_MODE=warn
assert_rc "TC-TOKENBUDGET-021 warn unaccountable adapter runs" 0 \
  "$(run_rc token_accounting_begin 506 RUN-B dev dev 1 kiro)"

echo "== TC-TOKENBUDGET-030..039: projection =="
assert_eq "TC-TOKENBUDGET-034 malformed projection normalizes unavailable" unavailable \
  "$(jq -r .status <<<"$(_token_budget_projection_normalize '{bad-json')")"
assert_eq "TC-TOKENBUDGET-034 fractional projection total normalizes unavailable" unavailable \
  "$(jq -r .status <<<"$(_token_budget_projection_normalize \
    '{"status":"complete","total_tokens":1.5,"source_digest":"bad","open_invocations":[],"unknown_invocations":[]}')")"
assert_eq "TC-TOKENBUDGET-034 negative projection total normalizes unavailable" unavailable \
  "$(jq -r .status <<<"$(_token_budget_projection_normalize \
    '{"status":"complete","total_tokens":-1,"source_digest":"bad","open_invocations":[],"unknown_invocations":[]}')")"

# Restore the real accounting functions after the adapter stubs above so this
# reader fixture uses the authoritative full record envelope.
source "$ACCOUNTING_LIB"
AUTONOMOUS_ACCOUNTING_DIR="$WORK/open-accounting"
OPEN_RECORD_ID="$(accounting_invocation_id record-run dev dev 1)"
accounting_start 506 "$OPEN_RECORD_ID" dev record-run dev 1
assert_eq "TC-TOKENBUDGET-031 open-record reader returns the owning run" record-run \
  "$(token_budget_open_run_id 506 "$OPEN_RECORD_ID")"
accounting_commit_usage 506 "$OPEN_RECORD_ID" 1 - -
assert_rc "TC-TOKENBUDGET-033 raced terminal record returns rc 3" 3 \
  "$(run_rc token_budget_open_run_id 506 "$OPEN_RECORD_ID")"
assert_rc "TC-TOKENBUDGET-034 malformed open-record arguments are refused" 1 \
  "$(run_rc token_budget_open_run_id invalid "$OPEN_RECORD_ID")"

RECOVERY_DEV_ID="$(accounting_invocation_id recovery-dev dev dev 1)"
RECOVERY_REVIEW_ID="$(accounting_invocation_id recovery-review review member-uuid 1)"
accounting_start 506 "$RECOVERY_DEV_ID" dev recovery-dev dev 1
accounting_commit_usage 506 "$RECOVERY_DEV_ID" 101 - -
accounting_start 506 "$RECOVERY_REVIEW_ID" review recovery-review member-uuid 1
# shellcheck disable=SC2218
accounting_commit_unknown 506 "$RECOVERY_REVIEW_ID" no-usage-in-log
AGENT_TOKEN_BUDGET=100
TOKEN_BUDGET_MODE=hard
assert_eq "TC-TOKENBUDGET-079 historical records without a decision pointer are inert" \
  '[]' "$(token_budget_recovery_pointer_read 506 dev-wrapper)"
# shellcheck disable=SC2218
token_budget_recovery_pointer_stage \
  506 "$RECOVERY_DEV_ID" "$RECOVERY_DEV_ID" token-cap dev-wrapper
recovery_records="$(token_budget_recovery_pointer_read 506 dev-wrapper)"
assert_eq "TC-TOKENBUDGET-079 durable dev decision pointer derives token-cap recovery" \
  "$RECOVERY_DEV_ID" "$(jq -r '.[0].invocation' <<<"$recovery_records")"
assert_eq "TC-TOKENBUDGET-079 dev recovery preserves the record side" \
  1 "$(jq 'length' <<<"$recovery_records")"
# shellcheck disable=SC2218
token_budget_recovery_pointer_clear 506 dev-wrapper "$RECOVERY_DEV_ID"
# shellcheck disable=SC2218
token_budget_recovery_pointer_stage \
  506 "$RECOVERY_REVIEW_ID" "$RECOVERY_REVIEW_ID" usage-unknown review-wrapper
recovery_records="$(token_budget_recovery_pointer_read 506 review-wrapper)"
assert_eq "TC-TOKENBUDGET-079 durable review decision pointer derives fail-closed recovery" \
  "$RECOVERY_REVIEW_ID" "$(jq -r '.[0].invocation' <<<"$recovery_records")"
assert_eq "TC-TOKENBUDGET-079 review recovery preserves the record side" \
  usage-unknown "$(jq -r '.[0].reason' <<<"$recovery_records")"
# shellcheck disable=SC2218
token_budget_recovery_pointer_clear 506 review-wrapper "$RECOVERY_REVIEW_ID"

# Pointer mutation must use the same mandatory issue lock as strict accounting.
# The stage assertion catches a future unlocked write directly. The clear
# assertion injects a newer generation while clear acquires the lock; clear
# must compare only after that point and leave the newer generation intact.
POINTER_FILE="$AUTONOMOUS_ACCOUNTING_DIR/506/.token-budget-recovery-dev-wrapper.json"
# shellcheck disable=SC2218
token_budget_recovery_pointer_stage \
  506 "$RECOVERY_DEV_ID" "$RECOVERY_DEV_ID" token-cap dev-wrapper
_REAL_POINTER_RECORD="$(cat "$POINTER_FILE")"
_accounting_lock() { return 1; }
assert_rc "TC-TOKENBUDGET-082 pointer stage requires the accounting issue lock" 1 \
  "$(run_rc token_budget_recovery_pointer_stage \
    506 "$RECOVERY_DEV_ID" "$RECOVERY_DEV_ID" token-cap dev-wrapper)"
assert_eq "TC-TOKENBUDGET-082 failed stage leaves the prior generation unchanged" \
  "$_REAL_POINTER_RECORD" "$(cat "$POINTER_FILE")"

accounting_start 506 "$(accounting_invocation_id recovery-dev-new dev dev 1)" \
  dev recovery-dev-new dev 1
RECOVERY_DEV_NEW_ID="$(accounting_invocation_id recovery-dev-new dev dev 1)"
accounting_commit_usage 506 "$RECOVERY_DEV_NEW_ID" 102 - -
_NEW_POINTER_RECORD="$(jq -nc \
  --argjson issue 506 \
  --arg id "$RECOVERY_DEV_NEW_ID" \
  '{schema_version:1,issue:$issue,intent:$id,invocation:$id,reason:"token-cap",owner:"dev-wrapper"}')"
_accounting_lock() {
  local -n _test_fd="$2"
  _test_fd=test-lock
  printf '%s\n' "$_NEW_POINTER_RECORD" > "$POINTER_FILE"
}
_accounting_unlock() {
  local -n _test_fd="$1"
  _test_fd=""
}
assert_rc "TC-TOKENBUDGET-082 stale clear refuses a newer locked generation" 1 \
  "$(run_rc _token_budget_recovery_pointer_clear_local \
    506 dev-wrapper "$RECOVERY_DEV_ID")"
assert_eq "TC-TOKENBUDGET-082 stale clear preserves the newer generation" \
  "$RECOVERY_DEV_NEW_ID" "$(jq -r .invocation "$POINTER_FILE")"
source "$ACCOUNTING_LIB"
# shellcheck disable=SC2218
token_budget_recovery_pointer_clear 506 dev-wrapper "$RECOVERY_DEV_NEW_ID"

REMOTE_POINTER_CALLS="$WORK/remote-pointer-calls"
: > "$REMOTE_POINTER_CALLS"
token_budget_remote_recovery_pointer() {
  printf '%s\n' "$*" >> "$REMOTE_POINTER_CALLS"
}
terminal_intent_write() { return 0; }
EXECUTION_BACKEND=remote-aws-ssm
token_budget_write_invocation_intent \
  506 "$RECOVERY_DEV_ID" "$RECOVERY_DEV_ID" token-cap dev-wrapper
assert_eq "TC-TOKENBUDGET-079 execution-host wrapper clears its pointer locally" \
  '[]' "$(_token_budget_recovery_pointer_read_local 506 dev-wrapper)"
assert_eq "TC-TOKENBUDGET-079 execution-host wrapper never launches nested SSM" \
  "" "$(cat "$REMOTE_POINTER_CALLS")"
unset EXECUTION_BACKEND
unset -f token_budget_remote_recovery_pointer terminal_intent_write

QUERY_COUNT=0
RECONCILE_FAIL=0
QUERY_FAIL_AT=0
SWEEP_FAIL=0
OPEN_RUN_A=prior-run
OPEN_RUN_B=current-run
CURRENT_QUERY='{"status":"complete","total_tokens":42,"source_digest":"abcdef0123456789","open_invocations":[],"unknown_invocations":[]}'

accounting_reconcile() {
  printf 'reconcile|%s\n' "$1" >> "$CALLS"
  [[ "$RECONCILE_FAIL" != 1 ]]
}
accounting_admission_query() {
  local query_count
  query_count="$(grep -c '^query|' "$CALLS" 2>/dev/null || true)"
  query_count=$((query_count + 1))
  printf 'query|%s|%s\n' "$1" "$query_count" >> "$CALLS"
  if [[ "$QUERY_FAIL_AT" -eq "$query_count" ]]; then
    return 1
  fi
  if [[ "$query_count" -eq 1 && -n "${DISCOVERY_QUERY:-}" ]]; then
    printf '%s\n' "$DISCOVERY_QUERY"
  else
    printf '%s\n' "$CURRENT_QUERY"
  fi
}
token_budget_open_run_id() {
  case "$2" in
    inv-a) printf '%s\n' "$OPEN_RUN_A" ;;
    inv-b) printf '%s\n' "$OPEN_RUN_B" ;;
    inv-raced) return 3 ;;
    *) return 1 ;;
  esac
}
accounting_commit_unknown() {
  printf 'sweep|%s\n' "$*" >> "$CALLS"
  [[ "$SWEEP_FAIL" != 1 ]]
}

: > "$CALLS"; QUERY_COUNT=0; unset DISCOVERY_QUERY
projection="$(token_issue_projection 506 RUN-A)"
assert_eq "TC-TOKENBUDGET-030 complete projection total" 42 \
  "$(jq -r .total_tokens <<<"$projection")"
assert_contains "TC-TOKENBUDGET-030 reconcile precedes query" \
  $'reconcile|506\nquery|506|1' "$(cat "$CALLS")"

DISCOVERY_QUERY='{"status":"incomplete","total_tokens":5,"source_digest":"d1","open_invocations":["inv-a","inv-b"],"unknown_invocations":[]}'
CURRENT_QUERY='{"status":"usage-unknown","total_tokens":5,"source_digest":"d2","open_invocations":[],"unknown_invocations":["inv-a"]}'
: > "$CALLS"; QUERY_COUNT=0
projection="$(token_issue_projection 506 current-run)"
assert_contains "TC-TOKENBUDGET-031 prior-run open is swept" \
  "sweep|506 inv-a orphaned-by-crash" "$(cat "$CALLS")"
if ! grep -q 'sweep|506 inv-b' "$CALLS"; then
  pass "TC-TOKENBUDGET-032 current-run open is untouched"
else
  fail "TC-TOKENBUDGET-032 current-run open is untouched"
fi
assert_eq "TC-TOKENBUDGET-035 usage-unknown remains fail-closed" usage-unknown \
  "$(jq -r .status <<<"$projection")"

: > "$CALLS"; QUERY_COUNT=0
projection="$(token_issue_projection 506)"
assert_contains "TC-TOKENBUDGET-033 dispatcher sweeps first open" \
  "sweep|506 inv-a orphaned-by-crash" "$(cat "$CALLS")"
assert_contains "TC-TOKENBUDGET-033 dispatcher sweeps second open" \
  "sweep|506 inv-b orphaned-by-crash" "$(cat "$CALLS")"

RECONCILE_FAIL=1; QUERY_COUNT=0; : > "$CALLS"
projection="$(token_issue_projection 506)"
assert_eq "TC-TOKENBUDGET-034 reconcile failure maps unavailable" unavailable \
  "$(jq -r .status <<<"$projection")"
RECONCILE_FAIL=0

QUERY_FAIL_AT=1; QUERY_COUNT=0; : > "$CALLS"
projection="$(token_issue_projection 506)"
assert_eq "TC-TOKENBUDGET-034 query failure maps unavailable" unavailable \
  "$(jq -r .status <<<"$projection")"
QUERY_FAIL_AT=0

SWEEP_FAIL=1; QUERY_COUNT=0; : > "$CALLS"
projection="$(token_issue_projection 506)"
assert_eq "TC-TOKENBUDGET-034 sweep failure maps unavailable" unavailable \
  "$(jq -r .status <<<"$projection")"
SWEEP_FAIL=0

DISCOVERY_QUERY='{"status":"incomplete","total_tokens":5,"source_digest":"d1","open_invocations":["inv-b"],"unknown_invocations":[]}'
CURRENT_QUERY="$DISCOVERY_QUERY"
QUERY_COUNT=0
projection="$(token_issue_projection 506 current-run)"
assert_eq "TC-TOKENBUDGET-032 residual incomplete maps unavailable" unavailable \
  "$(jq -r .status <<<"$projection")"

DISCOVERY_QUERY='{"status":"incomplete","total_tokens":5,"source_digest":"d1","open_invocations":["inv-raced"],"unknown_invocations":[]}'
CURRENT_QUERY='{"status":"complete","total_tokens":5,"source_digest":"d2","open_invocations":[],"unknown_invocations":[]}'
QUERY_COUNT=0; : > "$CALLS"
projection="$(token_issue_projection 506 current-run)"
assert_eq "TC-TOKENBUDGET-033 raced terminal open is ignored and re-queried" complete \
  "$(jq -r .status <<<"$projection")"
assert_eq "TC-TOKENBUDGET-033 raced terminal open is not swept" "" \
  "$(grep '^sweep|' "$CALLS" || true)"

token_budget_remote_projection() {
  printf 'remote|%s\n' "$1" >> "$CALLS"
  [[ "${REMOTE_FAIL:-0}" != 1 ]] || return 2
  printf '%s\n' '{"status":"complete","total_tokens":88,"source_digest":"remote","open_invocations":[],"unknown_invocations":[]}'
}
EXECUTION_BACKEND=remote-aws-ssm
unset TOKEN_BUDGET_FORCE_LOCAL
: > "$CALLS"
projection="$(token_issue_projection 506)"
assert_eq "TC-TOKENBUDGET-038 remote projection used" 88 \
  "$(jq -r .total_tokens <<<"$projection")"
assert_eq "TC-TOKENBUDGET-038 no controller-local reconcile" "" \
  "$(grep '^reconcile|' "$CALLS" || true)"
REMOTE_FAIL=1
projection="$(token_issue_projection 506)"
assert_eq "TC-TOKENBUDGET-039 remote failure maps unavailable" unavailable \
  "$(jq -r .status <<<"$projection")"
unset REMOTE_FAIL

token_budget_remote_recovery_pointer() {
  printf 'remote-recovery|%s\n' "$*" >> "$CALLS"
  [[ "${REMOTE_RECOVERY_FAIL:-0}" != 1 ]] || return 2
  if [[ "$1" == "read" ]]; then
    jq -nc --arg id "$RECOVERY_DEV_ID" \
      '[{intent:$id,invocation:$id,reason:"token-cap"}]'
  fi
}
_token_budget_recovery_pointer_read_local() {
  printf 'local-recovery|%s\n' "$*" >> "$CALLS"
  printf '[]\n'
}
: > "$CALLS"
recovery_records="$(token_budget_recovery_pointer_read 506 dev-wrapper)"
assert_eq "TC-TOKENBUDGET-039 remote recovery reads execution-host evidence" \
  "$RECOVERY_DEV_ID" "$(jq -r '.[0].invocation' <<<"$recovery_records")"
assert_contains "TC-TOKENBUDGET-039 remote recovery uses SSM transport" \
  "remote-recovery|read 506 dev-wrapper" "$(cat "$CALLS")"
assert_eq "TC-TOKENBUDGET-039 remote recovery never scans controller-local state" \
  "" "$(grep '^local-recovery|' "$CALLS" || true)"
# shellcheck disable=SC2218
token_budget_recovery_pointer_clear 506 dev-wrapper "$RECOVERY_DEV_ID"
assert_contains "TC-TOKENBUDGET-039 remote recovery clear also uses SSM transport" \
  "remote-recovery|clear 506 dev-wrapper ${RECOVERY_DEV_ID}" "$(cat "$CALLS")"
REMOTE_RECOVERY_FAIL=1
assert_rc "TC-TOKENBUDGET-039 remote recovery transport failure is unavailable" 2 \
  "$(run_rc token_budget_recovery_pointer_read 506 dev-wrapper)"
unset REMOTE_RECOVERY_FAIL EXECUTION_BACKEND

# Later decision tests isolate recovery orchestration from the real store scan;
# the real-pointer assertions above pin the default implementation.
RECOVERY_ACCOUNTING_DEV='[]'
RECOVERY_ACCOUNTING_REVIEW='[]'
token_budget_recovery_pointer_stage() {
  printf 'pointer-stage|%s\n' "$*" >> "$CALLS"
  [[ "${FAIL_POINTER_STAGE:-0}" != 1 ]]
}
token_budget_recovery_pointer_read() {
  printf 'accounting-recovery|%s\n' "$*" >> "$CALLS"
  case "$2" in
    dev-wrapper) printf '%s\n' "$RECOVERY_ACCOUNTING_DEV" ;;
    review-wrapper) printf '%s\n' "$RECOVERY_ACCOUNTING_REVIEW" ;;
    *) return 1 ;;
  esac
}
token_budget_recovery_pointer_clear() {
  printf 'pointer-clear|%s\n' "$*" >> "$CALLS"
  [[ "${FAIL_POINTER_CLEAR:-0}" != 1 ]]
}

echo "== TC-TOKENBUDGET-040..046: warning deduplication =="
itp_list_comments() {
  [[ "${TRACK_COMMENT_READ:-0}" != 1 ]] \
    || printf 'list-comments|%s\n' "$*" >> "$CALLS"
  cat "$COMMENTS"
}
itp_post_comment() {
  local issue="$1" body="$2" tmp="$WORK/comments.tmp"
  printf 'post|%s|%s\n' "$issue" "$body" >> "$CALLS"
  [[ "${FAIL_POST:-0}" != 1 ]] || return 1
  if [[ "${FAIL_RESOLVED_POST:-0}" == 1 \
        && "$body" == '<!-- token-budget-intent-resolved-v1:'* ]]; then
    return 1
  fi
  jq -c --arg body "$body" \
    '. + [{id:(length+1),author:"pipeline",authorKind:"self",body:$body,createdAt:"2026-07-18T00:00:00Z"}]' \
    "$COMMENTS" > "$tmp" && mv "$tmp" "$COMMENTS"
}

printf '[]\n' > "$COMMENTS"; : > "$CALLS"
token_budget_warn 506 invocation dev 100 120 "would stall" >/dev/null
assert_eq "TC-TOKENBUDGET-040 first warning posts" 1 \
  "$(grep -c '^post|' "$CALLS")"
token_budget_warn 506 invocation review 100 140 "different observer" >/dev/null
assert_eq "TC-TOKENBUDGET-042/043 growth and side do not re-post" 1 \
  "$(grep -c '^post|' "$CALLS")"
token_budget_warn 506 invocation dispatch 101 140 "new limit" >/dev/null
assert_eq "TC-TOKENBUDGET-044 changed limit re-arms" 2 \
  "$(grep -c '^post|' "$CALLS")"
assert_contains "TC-TOKENBUDGET-045 unavailable evidence is representable" \
  "measured=unavailable" \
  "$(token_budget_warning_marker 506 issue dispatch 100 unavailable)"

prior_refusal="$(token_budget_launch_refusal_marker 506 dev prior-run)"
current_refusal="$(token_budget_launch_refusal_marker 506 dev current-run)"
jq -nc \
  --arg prior "$prior_refusal" \
  --arg dispatch '<!-- dispatcher-token: abc at 2026-07-18T00:05:00Z mode=dev-new run=tick-1 -->
Dispatching autonomous development...' \
  '[
    {authorKind:"self",body:$prior},
    {authorKind:"self",body:$dispatch}
  ]' > "$COMMENTS"
assert_rc "TC-TOKENBUDGET-081 prior-attempt launch refusal does not re-arm recovery" 1 \
  "$(run_rc token_budget_recent_launch_refusal 506 dev)"
jq -c --arg body "$current_refusal" \
  '. + [{authorKind:"human",body:$body}]' "$COMMENTS" \
  > "$WORK/comments.tmp" && mv "$WORK/comments.tmp" "$COMMENTS"
assert_rc "TC-TOKENBUDGET-081 human launch-refusal marker is ignored" 1 \
  "$(run_rc token_budget_recent_launch_refusal 506 dev)"
jq -c --arg body "$current_refusal" \
  '. + [{authorKind:"self",body:$body}]' "$COMMENTS" \
  > "$WORK/comments.tmp" && mv "$WORK/comments.tmp" "$COMMENTS"
assert_rc "TC-TOKENBUDGET-081 current self-authored launch refusal re-arms recovery" 0 \
  "$(run_rc token_budget_recent_launch_refusal 506 dev)"

jq -nc \
  --arg old_dispatch '<!-- dispatcher-token: old at 2026-07-18T00:04:00Z mode=review run=tick-0 -->
Dispatching autonomous review...' \
  --arg current_dispatch '<!-- dispatcher-token: current at 2026-07-18T00:06:00Z mode=review run=tick-1 -->
Dispatching autonomous review...' '
  [
    {id:1,authorKind:"self",body:null,createdAt:"2026-07-18T00:03:00Z"},
    {id:2,authorKind:"self",body:42,createdAt:"2026-07-18T00:03:30Z"},
    {id:3,authorKind:"self",body:$old_dispatch,createdAt:"2026-07-18T00:04:00Z"},
    {id:4,authorKind:"self",body:$current_dispatch,createdAt:"2026-07-18T00:06:00Z"},
    {id:5,authorKind:"self",body:$current_dispatch,createdAt:null}
  ]' > "$COMMENTS"
assert_rc "TC-TOKENBUDGET-083 malformed newest dispatch timestamp fails closed" 2 \
  "$(run_rc token_budget_latest_dispatch_cutoff 506 review)"
jq -c 'map(select(.id != 5))' "$COMMENTS" \
  > "$WORK/comments.tmp" && mv "$WORK/comments.tmp" "$COMMENTS"
assert_eq "TC-TOKENBUDGET-083 latest valid review dispatch supplies the retry cutoff" \
  $'2026-07-18T00:06:00Z\t4' \
  "$(token_budget_latest_dispatch_cutoff 506 review)"
jq -c --arg body '<!-- dispatcher-token: bad-id at 2026-07-18T00:07:00Z mode=review run=tick-2 -->
Dispatching autonomous review...' \
  '. + [{id:"5",authorKind:"self",body:$body,
         createdAt:"2026-07-18T00:07:00Z"}]' \
  "$COMMENTS" > "$WORK/comments.tmp" && mv "$WORK/comments.tmp" "$COMMENTS"
assert_rc "TC-TOKENBUDGET-083 nonnumeric dispatch id fails closed" 2 \
  "$(run_rc token_budget_latest_dispatch_cutoff 506 review)"

echo "== TC-TOKENBUDGET-050..061: admission and terminal routing =="
reset_config
ISSUE_TOKEN_BUDGET=100
TOKEN_BUDGET_MODE=hard
ADMISSION_PROJECTION='{"status":"complete","total_tokens":100,"source_digest":"abcdef0123456789abcdef","open_invocations":[],"unknown_invocations":[]}'
token_issue_projection() {
  [[ "${TRACK_PROJECTION:-0}" != 1 ]] || printf 'projection|%s\n' "$*" >> "$CALLS"
  printf '%s\n' "$ADMISSION_PROJECTION"
}
terminal_intent_write() {
  printf 'intent|%s\n' "$*" >> "$CALLS"
  [[ "${FAIL_INTENT:-0}" != 1 ]] || return 1
  TEST_TERMINAL_ISSUE="$1"
  TEST_TERMINAL_INTENT="$2"
  TEST_TERMINAL_INVOCATION="$3"
  TEST_TERMINAL_REASON="$4"
  TEST_TERMINAL_OWNER="$5"
}
terminal_intent_read() {
  [[ "${FAIL_INTENT_READ:-0}" != 1 ]] || return 1
  [[ "${FORCE_RETIRED_INTENT:-0}" != 1 ]] || return 0
  [[ "${TEST_TERMINAL_ISSUE:-}" == "$1" ]] || return 0
  jq -nc \
    --argjson issue "$TEST_TERMINAL_ISSUE" \
    --arg intent "$TEST_TERMINAL_INTENT" \
    --arg invocation "$TEST_TERMINAL_INVOCATION" \
    --arg reason "$TEST_TERMINAL_REASON" \
    --arg owner "$TEST_TERMINAL_OWNER" \
    '{issue:$issue,intent:$intent,invocation:$invocation,reason:$reason,owner:$owner}'
}
terminal_intent_consume() {
  printf 'consume|%s\n' "$*" >> "$CALLS"
  return "${FAIL_CONSUME:-0}"
}
terminal_intent_clear() {
  printf 'clear|%s\n' "$*" >> "$CALLS"
  return "${FAIL_CLEAR:-0}"
}
stall_from_pending() {
  printf 'stall|%s\n' "$*" >> "$CALLS"
  return "${STALL_RC:-0}"
}
itp_read_task() {
  printf 'read-task|%s\n' "$*" >> "$CALLS"
  [[ "${FAIL_TASK_READ:-0}" != 1 ]] || return 1
  jq -nc --argjson labels "${AFTER_STALL_LABELS:-[]}" '{labels:$labels}'
}
itp_transition_state() {
  printf 'transition|%s\n' "$*" >> "$CALLS"
  return "${TRANSITION_RC:-0}"
}
release_dispatch_marker() { printf 'release|%s\n' "$*" >> "$CALLS"; }
retain_dispatch_marker() { printf 'retain|%s\n' "$*" >> "$CALLS"; }

: > "$CALLS"
assert_rc "TC-TOKENBUDGET-055 equality blocks admission" 10 \
  "$(run_rc token_admission_gate 506 pending-dev dev-resume)"
assert_contains "TC-TOKENBUDGET-056 issue intent uses digest identity" \
  "intent|506 token-cap-issue-abcdef012345 abcdef0123456789abcdef token-cap dispatcher" \
  "$(cat "$CALLS")"
assert_contains "TC-TOKENBUDGET-060 transition happens before marker release" \
  $'stall|506 pending-dev token-cap-issue-abcdef012345\npost|' "$(cat "$CALLS")"
assert_contains "TC-TOKENBUDGET-060 dispatcher intent is consumed after transition" \
  "consume|506 token-cap-issue-abcdef012345" "$(cat "$CALLS")"
last_call="$(tail -1 "$CALLS")"
assert_eq "TC-TOKENBUDGET-060 marker release is last" \
  "release|506 dev-resume" "$last_call"

: > "$CALLS"; STALL_RC=1; AFTER_STALL_LABELS='["autonomous","reviewing"]'
assert_rc "TC-TOKENBUDGET-057 wrong owner is handled" 10 \
  "$(run_rc token_admission_gate 506 pending-dev dev-new)"
assert_contains "TC-TOKENBUDGET-057 wrong owner clears intent" \
  "clear|506 token-cap-issue-abcdef012345 wrong-owner-abort" "$(cat "$CALLS")"
assert_eq "TC-TOKENBUDGET-057 wrong owner releases marker" \
  "release|506 dev-new" "$(tail -1 "$CALLS")"
unset STALL_RC AFTER_STALL_LABELS

: > "$CALLS"; STALL_RC=1; AFTER_STALL_LABELS='["autonomous","reviewing"]'; FAIL_CLEAR=1
assert_rc "TC-TOKENBUDGET-057 failed wrong-owner clear remains handled" 10 \
  "$(run_rc token_admission_gate 506 pending-dev dev-new)"
assert_eq "TC-TOKENBUDGET-057 failed clear retains marker ownership" "" \
  "$(grep '^release|' "$CALLS" || true)"
assert_eq "TC-TOKENBUDGET-057 retained marker survives tick cleanup ownership" \
  "retain|506 dev-new" "$(tail -1 "$CALLS")"
unset STALL_RC AFTER_STALL_LABELS FAIL_CLEAR

: > "$CALLS"; STALL_RC=1; AFTER_STALL_LABELS='["autonomous","pending-dev"]'
assert_rc "TC-TOKENBUDGET-068 transition failure remains handled" 10 \
  "$(run_rc token_admission_gate 506 pending-dev dev-new)"
assert_eq "TC-TOKENBUDGET-068 transition failure does not clear intent" "" \
  "$(grep '^clear|' "$CALLS" || true)"
assert_eq "TC-TOKENBUDGET-068 transition failure does not release marker" "" \
  "$(grep '^release|' "$CALLS" || true)"
assert_eq "TC-TOKENBUDGET-068 transition failure retains marker" \
  "retain|506 dev-new" "$(tail -1 "$CALLS")"
unset STALL_RC AFTER_STALL_LABELS

: > "$CALLS"; STALL_RC=1; FAIL_TASK_READ=1
assert_rc "TC-TOKENBUDGET-068 label-read failure remains handled" 10 \
  "$(run_rc token_admission_gate 506 pending-dev dev-new)"
assert_eq "TC-TOKENBUDGET-068 label-read failure does not clear intent" "" \
  "$(grep '^clear|' "$CALLS" || true)"
assert_eq "TC-TOKENBUDGET-068 label-read failure retains marker" \
  "retain|506 dev-new" "$(tail -1 "$CALLS")"
unset STALL_RC FAIL_TASK_READ

: > "$CALLS"
assert_rc "TC-TOKENBUDGET-058 dev-new empty state is handled" 10 \
  "$(run_rc token_admission_gate 506 '' dev-new)"
assert_contains "TC-TOKENBUDGET-058 empty state atomically adds stalled" \
  "transition|506  stalled" "$(cat "$CALLS")"

: > "$CALLS"; TRANSITION_RC=1
assert_rc "TC-TOKENBUDGET-068 dev-new transition failure remains handled" 10 \
  "$(run_rc token_admission_gate 506 '' dev-new)"
assert_eq "TC-TOKENBUDGET-068 dev-new transition failure does not clear intent" "" \
  "$(grep '^clear|' "$CALLS" || true)"
assert_eq "TC-TOKENBUDGET-068 dev-new transition failure does not release marker" "" \
  "$(grep '^release|' "$CALLS" || true)"
assert_eq "TC-TOKENBUDGET-068 dev-new transition failure retains marker" \
  "retain|506 dev-new" "$(tail -1 "$CALLS")"
unset TRANSITION_RC

ADMISSION_PROJECTION='{"status":"complete","total_tokens":100,"source_digest":"report-failure","open_invocations":[],"unknown_invocations":[]}'
printf '[]\n' > "$COMMENTS"; : > "$CALLS"; FAIL_POST=1
assert_rc "TC-TOKENBUDGET-060 stop-report failure remains handled" 10 \
  "$(run_rc token_admission_gate 506 pending-dev dev-new)"
assert_eq "TC-TOKENBUDGET-060 report failure does not consume intent" "" \
  "$(grep '^consume|' "$CALLS" || true)"
assert_eq "TC-TOKENBUDGET-060 report failure does not release marker" "" \
  "$(grep '^release|' "$CALLS" || true)"
assert_eq "TC-TOKENBUDGET-060 report failure retains marker through EXIT trap" \
  "retain|506 dev-new" "$(tail -1 "$CALLS")"
unset FAIL_POST

ADMISSION_PROJECTION='{"status":"complete","total_tokens":100,"source_digest":"consume-failure","open_invocations":[],"unknown_invocations":[]}'
printf '[]\n' > "$COMMENTS"; : > "$CALLS"; FAIL_CONSUME=1
assert_rc "TC-TOKENBUDGET-060 consume failure remains handled" 10 \
  "$(run_rc token_admission_gate 506 pending-review review)"
assert_eq "TC-TOKENBUDGET-060 consume failure does not release marker" "" \
  "$(grep '^release|' "$CALLS" || true)"
assert_eq "TC-TOKENBUDGET-060 consume failure retains marker through EXIT trap" \
  "retain|506 review" "$(tail -1 "$CALLS")"
unset FAIL_CONSUME

ADMISSION_PROJECTION='{"status":"usage-unknown","total_tokens":20,"source_digest":"1234567890abcdef","open_invocations":[],"unknown_invocations":["inv-x"]}'
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-056 unknown blocks" 10 \
  "$(run_rc token_admission_gate 506 pending-review review)"
assert_contains "TC-TOKENBUDGET-056 unknown uses usage-unknown reason" \
  "token-cap-issue-1234567890ab 1234567890abcdef usage-unknown dispatcher" \
  "$(cat "$CALLS")"

ADMISSION_PROJECTION='{"status":"corrupt","total_tokens":20,"source_digest":"fedcba9876543210","open_invocations":[],"unknown_invocations":[]}'
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-056 corrupt blocks" 10 \
  "$(run_rc token_admission_gate 506 pending-dev dev-new)"
assert_contains "TC-TOKENBUDGET-056 corrupt uses usage-unknown reason" \
  "token-cap-issue-fedcba987654 fedcba9876543210 usage-unknown dispatcher" \
  "$(cat "$CALLS")"

ADMISSION_PROJECTION='{"status":"unavailable","total_tokens":0,"source_digest":"","open_invocations":[],"unknown_invocations":[]}'
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-059 unavailable blocks this dispatch" 10 \
  "$(run_rc token_admission_gate 506 pending-dev dev-new)"
assert_eq "TC-TOKENBUDGET-059 unavailable writes no intent" "" \
  "$(grep '^intent|' "$CALLS" || true)"
assert_eq "TC-TOKENBUDGET-059 unavailable releases marker" \
  "release|506 dev-new" "$(tail -1 "$CALLS")"

ADMISSION_PROJECTION='{"status":"complete","total_tokens":99,"source_digest":"under","open_invocations":[],"unknown_invocations":[]}'
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-055 below cap proceeds" 0 \
  "$(run_rc token_admission_gate 506 pending-dev dev-new)"
assert_eq "TC-TOKENBUDGET-055 proceed retains marker for dispatch caller" "" \
  "$(cat "$CALLS")"

TOKEN_BUDGET_MODE=warn
ADMISSION_PROJECTION='{"status":"complete","total_tokens":100,"source_digest":"equal","open_invocations":[],"unknown_invocations":[]}'
printf '[]\n' > "$COMMENTS"; : > "$CALLS"
assert_rc "TC-TOKENBUDGET-041 warn equality proceeds" 0 \
  "$(run_rc token_admission_gate 506 pending-review review)"
assert_contains "TC-TOKENBUDGET-041 warn equality posts breadcrumb" \
  "token-budget-warn-v1" "$(cat "$CALLS")"
assert_eq "TC-TOKENBUDGET-041 warn does not transition" "" \
  "$(grep -E '^(intent|stall|transition|release)\|' "$CALLS" || true)"

ADMISSION_PROJECTION='{"status":"usage-unknown","total_tokens":40,"source_digest":"warn-unknown","open_invocations":[],"unknown_invocations":["inv-x"]}'
printf '[]\n' > "$COMMENTS"; : > "$CALLS"
assert_rc "TC-TOKENBUDGET-041 warn unknown projection proceeds" 0 \
  "$(run_rc token_admission_gate 506 pending-review review)"
assert_contains "TC-TOKENBUDGET-041 warn unknown includes fail-closed evidence" \
  "accounting status is fail-closed" "$(cat "$CALLS")"

reset_config
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-001 admission fast path proceeds" 0 \
  "$(run_rc token_admission_gate 506 pending-dev dev-new)"
assert_eq "TC-TOKENBUDGET-001 admission fast path performs zero seam I/O" "" \
  "$(cat "$CALLS")"

AGENT_TOKEN_BUDGET=100
TOKEN_BUDGET_MODE=hard
AGENT_DEV_CMD=kiro
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-020 hard dev adapter is refused at dispatch admission" 1 \
  "$(run_rc token_admission_gate 506 '' dev-new)"
assert_eq "TC-TOKENBUDGET-020 adapter refusal performs no store/label seam I/O" "" \
  "$(cat "$CALLS")"
unset AGENT_DEV_CMD

AGENT_REVIEW_AGENTS="claude opencode"
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-020 hard review fan-out adapter is refused at admission" 1 \
  "$(run_rc token_admission_gate 506 pending-review review)"
assert_eq "TC-TOKENBUDGET-020 review adapter refusal performs no seam I/O" "" \
  "$(cat "$CALLS")"
unset AGENT_REVIEW_AGENTS

echo "== TC-TOKENBUDGET-050..054: wrapper post-run decisions =="
reset_config
AGENT_TOKEN_BUDGET=100
TOKEN_BUDGET_MODE=hard
equal_result='{"invocation_id":"inv-equal","state":"usage-committed","total_tokens":100,"commit_failed":false}'
over_result='{"invocation_id":"inv-over","state":"usage-committed","total_tokens":101,"commit_failed":false}'
unknown_result='{"invocation_id":"inv-unknown","state":"usage-unknown","total_tokens":null,"commit_failed":false}'

: > "$CALLS"
assert_rc "TC-TOKENBUDGET-050 invocation equality is within allowance" 0 \
  "$(run_rc token_budget_evaluate_invocation 506 dev inv-equal "$equal_result")"
assert_eq "TC-TOKENBUDGET-050 equality writes no terminal intent" "" \
  "$(cat "$CALLS")"

assert_rc "TC-TOKENBUDGET-050 invocation overshoot violates post-run" 10 \
  "$(run_rc token_budget_evaluate_invocation 506 dev inv-over "$over_result")"
assert_contains "TC-TOKENBUDGET-050 invocation intent uses violating identity" \
  "intent|506 inv-over inv-over token-cap dev-wrapper" "$(cat "$CALLS")"

: > "$CALLS"; FAIL_INTENT=1
intent_fail_result='{"invocation_id":"inv-intent-fail","state":"usage-committed","total_tokens":101,"commit_failed":false}'
assert_rc "TC-TOKENBUDGET-052 hard invocation intent failure refuses normal routing" 21 \
  "$(run_rc token_budget_evaluate_invocation 506 review inv-intent-fail "$intent_fail_result")"
assert_contains "TC-TOKENBUDGET-079 failed intent leaves a durable recovery marker" \
  "token-budget-intent-pending-v1: issue=506 intent=inv-intent-fail invocation=inv-intent-fail reason=token-cap owner=review-wrapper" \
  "$(cat "$COMMENTS")"
unset FAIL_INTENT

: > "$CALLS"
assert_rc "TC-TOKENBUDGET-079 dispatcher restart recovers the missing terminal intent" 10 \
  "$(run_rc token_budget_recover_pending_intent 506 review-wrapper)"
assert_contains "TC-TOKENBUDGET-079 recovery retries the pinned invocation identity" \
  "intent|506 inv-intent-fail inv-intent-fail token-cap review-wrapper" "$(cat "$CALLS")"
assert_contains "TC-TOKENBUDGET-079 recovered marker is durably resolved" \
  "token-budget-intent-resolved-v1: issue=506 intent=inv-intent-fail invocation=inv-intent-fail" \
  "$(cat "$COMMENTS")"

: > "$CALLS"
assert_rc "TC-TOKENBUDGET-079 resolved marker suppresses duplicate recovery" 0 \
  "$(run_rc token_budget_recover_pending_intent 506 review-wrapper)"
assert_eq "TC-TOKENBUDGET-079 resolved marker prevents duplicate intent writes" "" \
  "$(grep '^intent|' "$CALLS" || true)"

printf '[]\n' > "$COMMENTS"
: > "$CALLS"; FAIL_POST=1; FAIL_INTENT=1
fallback_dev_id=inv-v1-aaaaaaaaaaaaaaaaaaaaaaaa
fallback_dev_result="{\"invocation_id\":\"${fallback_dev_id}\",\"state\":\"usage-committed\",\"total_tokens\":101,\"commit_failed\":false}"
assert_rc "TC-TOKENBUDGET-079 dev refuses routing when marker and intent both fail" 21 \
  "$(run_rc token_budget_evaluate_invocation 506 dev "$fallback_dev_id" "$fallback_dev_result")"
assert_eq "TC-TOKENBUDGET-079 double persistence failure leaves no comment marker" \
  '[]' "$(jq -c . "$COMMENTS")"
RECOVERY_ACCOUNTING_DEV="$(jq -nc --arg id "$fallback_dev_id" \
  '[{intent:$id,invocation:$id,reason:"token-cap"}]')"
unset FAIL_POST FAIL_INTENT
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-079 dev restart derives recovery from accounting" 10 \
  "$(run_rc token_budget_recover_pending_intent 506 dev-wrapper)"
assert_contains "TC-TOKENBUDGET-079 dev accounting fallback retries the pinned identity" \
  "intent|506 ${fallback_dev_id} ${fallback_dev_id} token-cap dev-wrapper" \
  "$(cat "$CALLS")"

printf '[]\n' > "$COMMENTS"
: > "$CALLS"; FAIL_POST=1; FAIL_INTENT=1
fallback_review_id=inv-v1-bbbbbbbbbbbbbbbbbbbbbbbb
fallback_review_result="{\"invocation_id\":\"${fallback_review_id}\",\"state\":\"usage-unknown\",\"total_tokens\":null,\"commit_failed\":false}"
assert_rc "TC-TOKENBUDGET-079 review refuses routing when marker and intent both fail" 21 \
  "$(run_rc token_budget_evaluate_invocation 506 review "$fallback_review_id" "$fallback_review_result")"
assert_eq "TC-TOKENBUDGET-079 review double failure leaves no comment marker" \
  '[]' "$(jq -c . "$COMMENTS")"
RECOVERY_ACCOUNTING_REVIEW="$(jq -nc --arg id "$fallback_review_id" \
  '[{intent:$id,invocation:$id,reason:"usage-unknown"}]')"
unset FAIL_POST FAIL_INTENT
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-079 review restart derives recovery from accounting" 10 \
  "$(run_rc token_budget_recover_pending_intent 506 review-wrapper)"
assert_contains "TC-TOKENBUDGET-079 review accounting fallback retries the pinned identity" \
  "intent|506 ${fallback_review_id} ${fallback_review_id} usage-unknown review-wrapper" \
  "$(cat "$CALLS")"
RECOVERY_ACCOUNTING_DEV='[]'
RECOVERY_ACCOUNTING_REVIEW='[]'

jq -c '. + [{
  id:999,
  author:"operator",
  authorKind:"human",
  body:"<!-- token-budget-intent-pending-v1: issue=506 intent=forged invocation=forged reason=token-cap owner=dev-wrapper -->",
  createdAt:"2026-07-18T00:01:00Z"
}]' "$COMMENTS" > "$WORK/comments.tmp" && mv "$WORK/comments.tmp" "$COMMENTS"
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-079 human pending marker is ignored" 0 \
  "$(run_rc token_budget_recover_pending_intent 506 dev-wrapper)"
assert_eq "TC-TOKENBUDGET-079 human marker cannot forge a terminal intent" "" \
  "$(grep '^intent|' "$CALLS" || true)"

embedded_pending="$(token_budget_pending_intent_marker \
  506 embedded-pending embedded-pending token-cap dev-wrapper)"
embedded_resolved="$(token_budget_resolved_intent_marker \
  506 embedded-pending embedded-pending)"
jq -nc --arg body "Review quote: ${embedded_pending} trailing text" \
  '[{id:1000,author:"pipeline",authorKind:"self",body:$body,createdAt:"2026-07-18T00:02:00Z"}]' \
  > "$COMMENTS"
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-079 embedded self-authored pending marker is ignored" 0 \
  "$(run_rc token_budget_recover_pending_intent 506 dev-wrapper)"
assert_eq "TC-TOKENBUDGET-079 embedded pending marker cannot forge an intent" "" \
  "$(grep '^intent|' "$CALLS" || true)"

jq -nc --arg pending "$embedded_pending" \
  --arg quoted "Review quote: ${embedded_resolved} trailing text" \
  '[
    {id:1001,author:"pipeline",authorKind:"self",body:$pending,createdAt:"2026-07-18T00:03:00Z"},
    {id:1002,author:"pipeline",authorKind:"self",body:$quoted,createdAt:"2026-07-18T00:04:00Z"}
  ]' > "$COMMENTS"
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-079 embedded resolved marker cannot suppress recovery" 10 \
  "$(run_rc token_budget_recover_pending_intent 506 dev-wrapper)"
assert_contains "TC-TOKENBUDGET-079 exact pending marker still recovers" \
  "intent|506 embedded-pending embedded-pending token-cap dev-wrapper" \
  "$(cat "$CALLS")"

printf '[]\n' > "$COMMENTS"
: > "$CALLS"; FAIL_RESOLVED_POST=1
retired_result='{"invocation_id":"retired-intent","state":"usage-committed","total_tokens":101,"commit_failed":false}'
assert_rc "TC-TOKENBUDGET-079 live intent proceeds when resolved marker post fails" 10 \
  "$(run_rc token_budget_evaluate_invocation 506 dev retired-intent "$retired_result")"
assert_contains "TC-TOKENBUDGET-079 failed resolved post leaves pending marker" \
  "token-budget-intent-pending-v1: issue=506 intent=retired-intent" \
  "$(cat "$COMMENTS")"
unset FAIL_RESOLVED_POST
: > "$CALLS"; FORCE_RETIRED_INTENT=1
assert_rc "TC-TOKENBUDGET-079 retired generation does not route terminal again" 0 \
  "$(run_rc token_budget_recover_pending_intent 506 dev-wrapper)"
assert_contains "TC-TOKENBUDGET-079 retired generation resolves stale pending marker" \
  "token-budget-intent-resolved-v1: issue=506 intent=retired-intent" \
  "$(cat "$COMMENTS")"
unset FORCE_RETIRED_INTENT

reset_config
: > "$CALLS"; TRACK_COMMENT_READ=1
assert_rc "TC-TOKENBUDGET-001 disabled pending recovery is inert" 0 \
  "$(run_rc token_budget_recover_pending_intent 506 dev-wrapper)"
assert_eq "TC-TOKENBUDGET-001 disabled pending recovery performs zero comment I/O" "" \
  "$(cat "$CALLS")"
unset TRACK_COMMENT_READ
AGENT_TOKEN_BUDGET=100
TOKEN_BUDGET_MODE=hard

: > "$CALLS"
review_ids=(inv-equal inv-unknown inv-over)
review_results=("$equal_result" "$unknown_result" "$over_result")
assert_rc "TC-TOKENBUDGET-052 review unknown member violates hard mode" 10 \
  "$(run_rc token_budget_evaluate_review_members 506 review_ids review_results)"
assert_contains "TC-TOKENBUDGET-052 review intent uses unknown member identity" \
  "intent|506 inv-unknown inv-unknown usage-unknown review-wrapper" "$(cat "$CALLS")"
assert_eq "TC-TOKENBUDGET-052 review stops after first hard violation" 1 \
  "$(grep -c '^intent|' "$CALLS" || true)"

reset_config
ISSUE_TOKEN_BUDGET=100
TOKEN_BUDGET_MODE=hard
ADMISSION_PROJECTION='{"status":"complete","total_tokens":100,"source_digest":"equal-digest","open_invocations":[],"unknown_invocations":[]}'
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-053 completed issue equality is within allowance" 0 \
  "$(run_rc token_budget_evaluate_issue 506 review RUN-REVIEW)"
assert_eq "TC-TOKENBUDGET-053 completed equality writes no issue intent" "" \
  "$(cat "$CALLS")"

ADMISSION_PROJECTION='{"status":"complete","total_tokens":101,"source_digest":"abcdef0123456789","open_invocations":[],"unknown_invocations":[]}'
assert_rc "TC-TOKENBUDGET-053 completed issue overshoot violates" 10 \
  "$(run_rc token_budget_evaluate_issue 506 review RUN-REVIEW)"
assert_contains "TC-TOKENBUDGET-053 issue intent is digest-derived" \
  "intent|506 token-cap-issue-abcdef012345 abcdef0123456789 token-cap review-wrapper" \
  "$(cat "$CALLS")"

ADMISSION_PROJECTION='{"status":"unavailable","total_tokens":0,"source_digest":"","open_invocations":[],"unknown_invocations":[]}'
assert_rc "TC-TOKENBUDGET-054 hard unavailable projection requests hold" 20 \
  "$(run_rc token_budget_evaluate_issue 506 review RUN-REVIEW)"
TOKEN_BUDGET_MODE=warn
assert_rc "TC-TOKENBUDGET-054 warn unavailable projection preserves routing" 0 \
  "$(run_rc token_budget_evaluate_issue 506 review RUN-REVIEW)"

reset_config
AGENT_TOKEN_BUDGET=100
TOKEN_BUDGET_MODE=warn
printf '[]\n' > "$COMMENTS"; : > "$CALLS"
assert_rc "TC-TOKENBUDGET-051 warn invocation overshoot preserves routing" 0 \
  "$(run_rc token_budget_evaluate_invocation 506 review inv-over "$over_result")"
assert_contains "TC-TOKENBUDGET-051 warn invocation posts evidence" \
  "invocation inv-over state=usage-committed" "$(cat "$CALLS")"

reset_config
ISSUE_TOKEN_BUDGET=100
TOKEN_BUDGET_MODE=warn
ADMISSION_PROJECTION='{"status":"corrupt","total_tokens":0,"source_digest":"warn-corrupt","open_invocations":[],"unknown_invocations":[]}'
printf '[]\n' > "$COMMENTS"; : > "$CALLS"
assert_rc "TC-TOKENBUDGET-053 warn corrupt issue preserves routing" 0 \
  "$(run_rc token_budget_evaluate_issue 506 dev RUN-DEV)"
assert_contains "TC-TOKENBUDGET-053 warn corrupt issue posts evidence" \
  "completed issue projection status=corrupt" "$(cat "$CALLS")"

TOKEN_BUDGET_MODE=hard
ADMISSION_PROJECTION='{"status":"usage-unknown","total_tokens":10,"source_digest":"unknown-digest","open_invocations":[],"unknown_invocations":["inv-x"]}'
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-053 hard unknown issue routes terminal" 10 \
  "$(run_rc token_budget_evaluate_issue 506 dev RUN-DEV)"
assert_contains "TC-TOKENBUDGET-053 hard unknown issue uses digest identity" \
  "intent|506 token-cap-issue-unknown-dige unknown-digest usage-unknown dev-wrapper" \
  "$(cat "$CALLS")"

reset_config
ISSUE_TOKEN_BUDGET=200
TOKEN_BUDGET_MODE=hard
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-018 hard commit failure is terminal with only issue budget set" 10 \
  "$(run_rc token_budget_evaluate_invocation 506 dev inv-unknown "$unknown_result")"
assert_contains "TC-TOKENBUDGET-018 commit failure uses invocation terminal identity" \
  "intent|506 inv-unknown inv-unknown usage-unknown dev-wrapper" "$(cat "$CALLS")"
assert_rc "TC-TOKENBUDGET-053 known invocation usage is not compared to issue limit" 0 \
  "$(run_rc token_budget_evaluate_invocation 506 dev inv-over "$over_result")"

reset_config
AGENT_TOKEN_BUDGET=100
ISSUE_TOKEN_BUDGET=200
TOKEN_BUDGET_MODE=hard
dev_ids=(inv-equal)
dev_results=("$equal_result")
ADMISSION_PROJECTION='{"status":"complete","total_tokens":200,"source_digest":"dev-equal","open_invocations":[],"unknown_invocations":[]}'
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-050 dev run allows both completed equalities" 0 \
  "$(run_rc token_budget_evaluate_dev_run 506 RUN-DEV dev_ids dev_results)"

dev_ids=(inv-over)
dev_results=("$over_result")
: > "$CALLS"; TRACK_PROJECTION=1
ADMISSION_PROJECTION='{"status":"complete","total_tokens":201,"source_digest":"dev-both-over","open_invocations":[],"unknown_invocations":[]}'
assert_rc "TC-TOKENBUDGET-050 dev run stops on invocation overshoot" 10 \
  "$(run_rc token_budget_evaluate_dev_run 506 RUN-DEV dev_ids dev_results)"
assert_contains "TC-TOKENBUDGET-050 dev run still evaluates cumulative projection" \
  "projection|506 RUN-DEV" "$(cat "$CALLS")"
assert_eq "TC-TOKENBUDGET-050 dev run persists only one live terminal intent" 1 \
  "$(grep -c '^intent|' "$CALLS")"
unset TRACK_PROJECTION

: > "$CALLS"; FAIL_INTENT=1
ADMISSION_PROJECTION='{"status":"complete","total_tokens":201,"source_digest":"dev-over-after-intent-failure","open_invocations":[],"unknown_invocations":[]}'
assert_rc "TC-TOKENBUDGET-052 dev intent persistence failure refuses cleanup routing" 21 \
  "$(run_rc token_budget_evaluate_dev_run 506 RUN-DEV dev_ids dev_results)"
assert_eq "TC-TOKENBUDGET-052 failed invocation intent does not fall back to a second identity" 1 \
  "$(grep -c '^intent|' "$CALLS")"
unset FAIL_INTENT

dev_ids=()
dev_results=()
ADMISSION_PROJECTION='{"status":"complete","total_tokens":201,"source_digest":"dev-over","open_invocations":[],"unknown_invocations":[]}'
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-053 dev run routes issue overshoot" 10 \
  "$(run_rc token_budget_evaluate_dev_run 506 RUN-DEV dev_ids dev_results)"

ADMISSION_PROJECTION='{"status":"unavailable","total_tokens":0,"source_digest":"","open_invocations":[],"unknown_invocations":[]}'
: > "$CALLS"
assert_rc "TC-TOKENBUDGET-054 dev unavailable projection preserves cleanup" 0 \
  "$(run_rc token_budget_evaluate_dev_run 506 RUN-DEV dev_ids dev_results)"
assert_contains "TC-TOKENBUDGET-054 dev unavailable projection is loud" \
  "normal cleanup routing is preserved" "$(cat "$WORK/err")"

echo "== TC-TOKENBUDGET-076: source-derived decision coverage =="
if [[ "${TOKEN_BUDGET_COVERAGE_CHILD:-0}" != "1" ]]; then
  COVERAGE_TRACE="$WORK/coverage.trace"
  COVERAGE_OUT="$WORK/coverage.out"
  COVERAGE_SITES="$WORK/coverage-sites"
  exec {COVERAGE_FD}>"$COVERAGE_TRACE"
  TOKEN_BUDGET_COVERAGE_CHILD=1 BASH_XTRACEFD="$COVERAGE_FD" \
    PS4='+${BASH_SOURCE}:${LINENO}:' bash -x "$0" >"$COVERAGE_OUT" 2>&1
  COVERAGE_RC=$?
  exec {COVERAGE_FD}>&-
  assert_rc "TC-TOKENBUDGET-076 traced test child succeeds" 0 "$COVERAGE_RC"

  # Derive the denominator independently from shell decision sites. Multiline
  # single-quoted jq programs are excluded because their `if` tokens are jq,
  # not shell branches.
  awk '
    BEGIN { in_single_quote = 0; previous_continued = 0 }
    {
      raw = $0
      continued = previous_continued
      previous_continued = (raw ~ /\\[[:space:]]*$/)
      lead = raw
      sub(/^[[:space:]]*/, "", lead)
      if (!in_single_quote && lead ~ /^#/) next
      if (!in_single_quote) sub(/[[:space:]]+#.*/, "", raw)

      quoted = raw
      quote_count = gsub(/\047/, "", quoted)
      if (in_single_quote) {
        if (quote_count % 2 == 1) in_single_quote = 0
        next
      }
      if (continued) {
        if (quote_count % 2 == 1) in_single_quote = 1
        next
      }

      code = raw
      sub(/\047.*/, "", code)
      trimmed = code
      sub(/^[[:space:]]*/, "", trimmed)
      if (trimmed ~ /^(if|elif|for|while)[[:space:]]/ ||
          (trimmed !~ /^(if|elif)[[:space:]]/ &&
           trimmed ~ /[[:space:]](\|\||&&)[[:space:]]/)) {
        print NR
      }
      if (quote_count % 2 == 1) in_single_quote = 1
    }
  ' "$LIB" > "$COVERAGE_SITES"

  COVERAGE_TOTAL="$(wc -l < "$COVERAGE_SITES" | tr -d ' ')"
  COVERAGE_COVERED=0
  while IFS= read -r site_line; do
    [[ -n "$site_line" ]] || continue
    if grep -Fq "${LIB}:${site_line}:" "$COVERAGE_TRACE"; then
      COVERAGE_COVERED=$((COVERAGE_COVERED + 1))
    fi
  done < "$COVERAGE_SITES"
  COVERAGE_PERCENT="$(awk -v covered="$COVERAGE_COVERED" -v total="$COVERAGE_TOTAL" \
    'BEGIN { printf "%.1f", covered * 100 / total }')"
  if [[ "$COVERAGE_TOTAL" -gt 0 \
        && "$COVERAGE_COVERED" -gt $((COVERAGE_TOTAL * 80 / 100)) ]]; then
    pass "TC-TOKENBUDGET-076 decision-site coverage ${COVERAGE_COVERED}/${COVERAGE_TOTAL} (${COVERAGE_PERCENT}%) > 80%"
  else
    fail "TC-TOKENBUDGET-076 decision-site coverage ${COVERAGE_COVERED}/${COVERAGE_TOTAL} (${COVERAGE_PERCENT}%) is not > 80%"
  fi
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] || exit 1
