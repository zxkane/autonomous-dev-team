#!/bin/bash
# Hermetic token-budget lifecycle E2E for issue #506 / INV-141.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ACCOUNTING="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-accounting.sh"
TERMINAL="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-terminal-control.sh"
BUDGET="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-token-budget.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected=$2 actual=$3)"; fi
}
assert_contains() {
  if [[ "$3" == *"$2"* ]]; then pass "$1"; else fail "$1 (missing=$2)"; fi
}

if [[ ! -r "$BUDGET" ]]; then
  fail "TC-TOKENBUDGET-071 token budget library exists"
  echo "TOKEN-BUDGET-E2E-SUMMARY pass=$PASS fail=$FAIL"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export AUTONOMOUS_ACCOUNTING_DIR="$WORK/accounting"
export PROJECT_ID=token-e2e
COMMENTS="$WORK/comments.json"
LABELS="$WORK/labels.json"
CALLS="$WORK/calls"
SEQ=0
printf '[]\n' > "$COMMENTS"
printf '["autonomous","pending-dev"]\n' > "$LABELS"
: > "$CALLS"

itp_list_comments() { cat "$COMMENTS"; }
itp_post_comment() {
  local issue="$1" body="$2" tmp="$WORK/comments.tmp"
  SEQ=$((SEQ + 1))
  jq -c --argjson id "$SEQ" --arg body "$body" \
    '. + [{id:$id,author:"pipeline",authorKind:"self",body:$body,createdAt:"2026-07-18T00:00:00Z"}]' \
    "$COMMENTS" > "$tmp" && mv "$tmp" "$COMMENTS"
}
itp_read_task() { jq -c '{labels:.}' "$LABELS"; }
itp_transition_state() {
  local issue="$1" remove="$2" add="$3" tmp="$WORK/labels.tmp"
  printf 'transition|%s|%s|%s\n' "$issue" "$remove" "$add" >> "$CALLS"
  jq -c --arg remove "$remove" --arg add "$add" '
    ($remove | split(",") | map(select(length > 0))) as $r
    | map(select(. as $label | ($r | index($label) | not)))
    | if $add == "" or index($add) != null then . else . + [$add] end
  ' "$LABELS" > "$tmp" && mv "$tmp" "$LABELS"
}
release_dispatch_marker() { printf 'release|%s|%s\n' "$1" "$2" >> "$CALLS"; }

# shellcheck source=/dev/null
source "$ACCOUNTING"
source "$TERMINAL"
source "$BUDGET"
set +e

ISSUE=506
DEV_ID="$(accounting_invocation_id RUN-DEV dev dev 1)"
REV_A="$(accounting_invocation_id RUN-REVIEW review UUID-A 1)"
REV_B="$(accounting_invocation_id RUN-REVIEW review UUID-B 1)"
accounting_start "$ISSUE" "$DEV_ID" dev RUN-DEV dev 1 >/dev/null
accounting_commit_usage "$ISSUE" "$DEV_ID" 60 >/dev/null
accounting_start "$ISSUE" "$REV_A" review RUN-REVIEW UUID-A 1 >/dev/null
accounting_commit_usage "$ISSUE" "$REV_A" 25 >/dev/null
accounting_start "$ISSUE" "$REV_B" review RUN-REVIEW UUID-B 1 >/dev/null
accounting_commit_usage "$ISSUE" "$REV_B" 15 >/dev/null

projection="$(token_issue_projection "$ISSUE")"
assert_eq "TC-TOKENBUDGET-037 dev/review totals aggregate exactly once" 100 \
  "$(jq -r .total_tokens <<<"$projection")"
if [[ "$REV_A" != "$REV_B" ]]; then
  pass "TC-TOKENBUDGET-073 fan-out members remain distinct"
else
  fail "TC-TOKENBUDGET-073 fan-out members remain distinct"
fi

export ISSUE_TOKEN_BUDGET=100 TOKEN_BUDGET_MODE=warn
token_admission_gate "$ISSUE" pending-dev dev-resume
assert_eq "TC-TOKENBUDGET-072 warn equality continues dispatch" 0 "$?"
assert_eq "TC-TOKENBUDGET-040 warn mode leaves labels unchanged" \
  '["autonomous","pending-dev"]' "$(cat "$LABELS")"
assert_contains "TC-TOKENBUDGET-041 warn marker posted" token-budget-warn-v1 \
  "$(jq -r '.[].body' "$COMMENTS")"

export TOKEN_BUDGET_MODE=hard
token_admission_gate "$ISSUE" pending-dev dev-resume
assert_eq "TC-TOKENBUDGET-072 hard equality blocks next dispatch" 10 "$?"
assert_eq "TC-TOKENBUDGET-062 hard admission converges to stalled" \
  '["autonomous","stalled"]' "$(cat "$LABELS")"
assert_contains "TC-TOKENBUDGET-060 marker released after transition" \
  'release|506|dev-resume' "$(cat "$CALLS")"

# Simulate a crashed review member in another issue. Dispatcher projection has
# no current run, so the remaining started record is swept to sticky unknown.
ISSUE2=507
ORPHAN="$(accounting_invocation_id RUN-CRASH review UUID-CRASH 1)"
accounting_start "$ISSUE2" "$ORPHAN" review RUN-CRASH UUID-CRASH 1 >/dev/null
projection="$(token_issue_projection "$ISSUE2")"
assert_eq "TC-TOKENBUDGET-074 crashed review record becomes usage-unknown" usage-unknown \
  "$(jq -r .status <<<"$projection")"
assert_contains "TC-TOKENBUDGET-074 orphan is present in unknown list" "$ORPHAN" \
  "$(jq -c .unknown_invocations <<<"$projection")"

# A dispatcher sweep can race a still-live wrapper. The strict store rejects
# that wrapper's later usage commit rather than silently replacing unknown.
if accounting_commit_usage "$ISSUE2" "$ORPHAN" 9 2>"$WORK/raced-commit.err"; then
  fail "TC-TOKENBUDGET-036 raced live commit is rejected"
else
  pass "TC-TOKENBUDGET-036 raced live commit is rejected"
fi
assert_contains "TC-TOKENBUDGET-036 raced live commit is loud" \
  "already terminal usage-unknown" "$(cat "$WORK/raced-commit.err")"

# Exercise the wrapper's post-run helper and the real INV-140 cleanup routing.
# Warn mode preserves the wrapper's normal pending-review transition.
unset ISSUE_TOKEN_BUDGET
export AGENT_TOKEN_BUDGET=50 TOKEN_BUDGET_MODE=warn
printf '[]\n' > "$COMMENTS"
printf '["autonomous","in-progress"]\n' > "$LABELS"
: > "$CALLS"
DEV_WARN_ID="$(accounting_invocation_id RUN-WARN dev dev 1)"
dev_warn_ids=("$DEV_WARN_ID")
dev_warn_results=('{"state":"usage-committed","total_tokens":60,"commit_failed":false}')
token_budget_evaluate_dev_run 508 RUN-WARN dev_warn_ids dev_warn_results
assert_eq "TC-TOKENBUDGET-071 warn dev overshoot preserves routing" 0 "$?"
terminal_intent_cleanup_transition 508 in-progress in-progress pending-review
assert_eq "TC-TOKENBUDGET-071 warn dev cleanup reaches pending-review" \
  '["autonomous","pending-review"]' "$(cat "$LABELS")"

# Hard mode writes the invocation-keyed intent and the existing cleanup helper
# redirects to stalled. Re-invoking cleanup after consume must not resurrect a
# pending label.
export TOKEN_BUDGET_MODE=hard
printf '[]\n' > "$COMMENTS"
printf '["autonomous","in-progress"]\n' > "$LABELS"
: > "$CALLS"
DEV_HARD_ID="$(accounting_invocation_id RUN-HARD dev dev 1)"
dev_hard_ids=("$DEV_HARD_ID")
dev_hard_results=('{"state":"usage-committed","total_tokens":60,"commit_failed":false}')
token_budget_evaluate_dev_run 509 RUN-HARD dev_hard_ids dev_hard_results
assert_eq "TC-TOKENBUDGET-071 hard dev overshoot requests terminal routing" 10 "$?"
terminal_intent_cleanup_transition 509 in-progress in-progress pending-review
assert_eq "TC-TOKENBUDGET-062 hard dev cleanup stalls" \
  '["autonomous","stalled"]' "$(cat "$LABELS")"
terminal_intent_cleanup_transition 509 in-progress in-progress pending-review
assert_eq "TC-TOKENBUDGET-062 wrapper cleanup re-entry cannot resurrect pending" \
  '["autonomous","stalled"]' "$(cat "$LABELS")"
assert_eq "TC-TOKENBUDGET-062 wrapper cleanup re-entry performs one transition" 1 \
  "$(grep -c '^transition|' "$CALLS")"

# Two separate shell processes model dispatcher restarts. Durable parsed-key
# marker lookup suppresses the second warning even though side/measured differ.
printf '[]\n' > "$COMMENTS"
for restart_case in 'dispatch 100' 'review 125'; do
  read -r restart_side restart_measured <<<"$restart_case"
  BUDGET="$BUDGET" COMMENTS="$COMMENTS" RESTART_SIDE="$restart_side" \
    RESTART_MEASURED="$restart_measured" bash -c '
      source "$BUDGET"
      itp_list_comments() { cat "$COMMENTS"; }
      itp_post_comment() {
        local issue="$1" body="$2" tmp="${COMMENTS}.$$"
        jq -c --arg body "$body" \
          ". + [{id:(length+1),author:\"pipeline\",authorKind:\"self\",body:\$body,createdAt:\"2026-07-18T00:00:00Z\"}]" \
          "$COMMENTS" > "$tmp" && mv "$tmp" "$COMMENTS"
      }
      token_budget_warn 510 issue "$RESTART_SIDE" 100 "$RESTART_MEASURED" restart
    '
done
assert_eq "TC-TOKENBUDGET-046/075 dispatcher restart suppresses duplicate warning" 1 \
  "$(jq '[.[] | select(.body | contains("token-budget-warn-v1: issue=510 scope=issue"))] | length' "$COMMENTS")"

# The structured stop report has its own stable intent identity and remains
# one-shot across retries.
_token_budget_stop_report 511 token-cap-issue-restart complete 100 100
_token_budget_stop_report 511 token-cap-issue-restart complete 125 100
assert_eq "TC-TOKENBUDGET-061 unchanged issue intent posts one stop report" 1 \
  "$(jq '[.[] | select(.body | contains("token-budget-stop-v1: issue=511 intent=token-cap-issue-restart"))] | length' "$COMMENTS")"

echo "TOKEN-BUDGET-E2E-SUMMARY pass=$PASS fail=$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
