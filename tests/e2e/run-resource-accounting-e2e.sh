#!/bin/bash
# run-resource-accounting-e2e.sh — E2E for the crash-consistent token
# accounting store (issue #505, INV-139). Test IDs: TC-RESOURCEACCOUNT-090,
# TC-RESOURCEACCOUNT-091.
#
# Two hermetic scenarios against the REAL lib-accounting.sh (no stubs):
#   1. Multi-invocation flow: dev + 2 same-name review members (distinct
#      member UUIDs) commit usage; deleting projection.json and re-querying
#      reconstructs the identical issue total.
#   2. Crash flow: a `started` record with a dead stub PID + a superseded
#      run-id reconciles to sticky usage-unknown, surfaced by
#      accounting_admission_query.
#
# Run:  bash tests/e2e/run-resource-accounting-e2e.sh
# CI:   invoked by tests/unit/test-resource-accounting-e2e.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-accounting.sh"

PASS=0
FAIL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; echo "      $2"; FAIL=$((FAIL + 1)); }
expect_eq() {  # expect_eq <desc> <want> <got>
  [[ "$2" == "$3" ]] && ok "$1" || bad "$1" "want='$2' got='$3'"
}

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-accounting.sh
source "$LIB"

WORK="$(mktemp -d)"
export AUTONOMOUS_ACCOUNTING_DIR="$WORK/accounting"
export PROJECT_ID="e2e-accounting"

# ---------------------------------------------------------------------------
# TC-RESOURCEACCOUNT-090: multi-invocation flow.
# ---------------------------------------------------------------------------
echo "== TC-RESOURCEACCOUNT-090: multi-invocation flow =="

ISSUE=5000
DEV_ID="$(accounting_invocation_id RUNMULTI dev dev 1)"
accounting_start "$ISSUE" "$DEV_ID" dev RUNMULTI dev 1 >/dev/null
accounting_commit_usage "$ISSUE" "$DEV_ID" 100 70 30 >/dev/null

# Two review fan-out members, both named "codex", distinguished only by
# their _agent_session_id member UUID (same shape as autonomous-review.sh's
# real fan-out).
MEMBER_A_UUID="11111111-1111-1111-1111-111111111111"
MEMBER_B_UUID="22222222-2222-2222-2222-222222222222"
REVIEW_A_ID="$(accounting_invocation_id RUNMULTI review "$MEMBER_A_UUID" 1)"
REVIEW_B_ID="$(accounting_invocation_id RUNMULTI review "$MEMBER_B_UUID" 1)"
accounting_start "$ISSUE" "$REVIEW_A_ID" review RUNMULTI "$MEMBER_A_UUID" 1 >/dev/null
accounting_commit_usage "$ISSUE" "$REVIEW_A_ID" 50 30 20 >/dev/null
accounting_start "$ISSUE" "$REVIEW_B_ID" review RUNMULTI "$MEMBER_B_UUID" 1 >/dev/null
accounting_commit_usage "$ISSUE" "$REVIEW_B_ID" 30 20 10 >/dev/null

expect_eq "same-named review members got distinct invocation ids" "1" "$([[ "$REVIEW_A_ID" != "$REVIEW_B_ID" ]] && echo 1 || echo 0)"

Q_BEFORE="$(accounting_admission_query "$ISSUE")"
TOTAL_BEFORE="$(jq -r .total_tokens <<<"$Q_BEFORE")"
expect_eq "pre-delete total is dev(100)+reviewA(50)+reviewB(30)=180" "180" "$TOTAL_BEFORE"

PROJ="$(_accounting_issue_dir "$ISSUE")/projection.json"
[[ -f "$PROJ" ]] && ok "projection.json exists after the first query" || bad "projection.json exists after the first query" "missing"
rm -f "$PROJ"

Q_AFTER="$(accounting_admission_query "$ISSUE")"
TOTAL_AFTER="$(jq -r .total_tokens <<<"$Q_AFTER")"
expect_eq "post-rebuild total identical to pre-delete total" "$TOTAL_BEFORE" "$TOTAL_AFTER"

# ---------------------------------------------------------------------------
# TC-RESOURCEACCOUNT-091: crash flow.
# ---------------------------------------------------------------------------
echo "== TC-RESOURCEACCOUNT-091: crash flow =="

PID_WORK="$(mktemp -d)"
export AUTONOMOUS_PID_DIR="$PID_WORK"
CRASH_ISSUE=5001

# A genuinely dead stub PID (spawned, waited-on, exit code consumed).
sh -c 'exit 0' &
DEAD_STUB_PID=$!
wait "$DEAD_STUB_PID" 2>/dev/null

CRASH_ID="$(accounting_invocation_id RUNCRASHOLD dev dev 1)"
accounting_start "$CRASH_ISSUE" "$CRASH_ID" dev RUNCRASHOLD dev 1 >/dev/null

# The lease sidecar now shows a DIFFERENT (superseded) run-id AND the dead
# stub PID — both proof-of-death signals present at once, mirroring a wrapper
# that crashed mid-run and was later superseded by a fresh dispatch.
printf 'RUNCRASHNEW\n' > "${PID_WORK}/issue-${CRASH_ISSUE}.run-id"
jq -nc --argjson pid "$DEAD_STUB_PID" '{schema_version:1,run_id:"RUNCRASHNEW",pid:$pid,updated_at_epoch:0}' \
  > "${PID_WORK}/issue-${CRASH_ISSUE}.progress.json"

Q_PRE_RECONCILE="$(accounting_admission_query "$CRASH_ISSUE")"
expect_eq "pre-reconcile: crashed invocation is open, not yet unknown" "incomplete" "$(jq -r .status <<<"$Q_PRE_RECONCILE")"

accounting_reconcile "$CRASH_ISSUE"

Q_POST_RECONCILE="$(accounting_admission_query "$CRASH_ISSUE")"
expect_eq "post-reconcile: status reflects sticky usage-unknown" "usage-unknown" "$(jq -r .status <<<"$Q_POST_RECONCILE")"
expect_eq "post-reconcile: crashed invocation listed in unknown_invocations" "1" \
  "$(jq -r --arg id "$CRASH_ID" '[.unknown_invocations[] | select(. == $id)] | length' <<<"$Q_POST_RECONCILE")"
expect_eq "post-reconcile: no invocation remains open" "0" "$(jq -r '.open_invocations | length' <<<"$Q_POST_RECONCILE")"

rm -rf "$WORK" "$PID_WORK"

# ---------------------------------------------------------------------------
echo ""
echo "RESOURCE-ACCOUNTING-E2E Results: ${PASS} passed, ${FAIL} failed"
if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
echo "RESOURCE-ACCOUNTING-E2E-SUMMARY pass=${PASS} fail=0"
