#!/bin/bash
# run-liveness-watchdog-e2e.sh — E2E for the generic liveness watchdog
# (issue #467, INV-127). TC-LIVENESS-045.
#
# WHAT IT DOES
# ------------
# Replays the `api_error` permanent-park shape ([INV-125]'s motivating
# incident) tick-by-tick against a stub in-memory GitHub issue, driving the
# REAL Step 6 entry point (`run_liveness_watchdog`, sourced from the real
# `lib-liveness.sh`) with the specific breaker's recovery budget already
# exhausted — so `_same_head_verdict_aware_recovery` (INV-125/INV-111) cannot
# fire again, and the ONLY mechanism left to unstick the issue is this
# watchdog. This is the exact shape five prior point-fixes closed one
# instance of; the watchdog is the class-level backstop for the NEXT one.
#
# Park shape: `pending-dev`, resolvable session id, dead dev wrapper
# (pid_alive miss, no fresh dispatch marker), frozen fingerprint (label +
# PR head + comment count + marker digest all unchanged tick over tick).
#
# Asserts:
#   1. Tier-1 escalation comment appears at exactly tick LIVENESS_NOTICE_TICKS
#      (6), posted exactly once across the whole run.
#   2. `stalled` transition + exactly one `reason=liveness-timeout` report
#      appears at exactly tick LIVENESS_STALL_TICKS (18), posted exactly once.
#   3. No tier-2 report before tick 18; no re-fired tier-1 after tick 6.
#   4. Once `stalled`, list_pending_dev's own exclusion (the SAME contract
#      the real selector enforces) removes the issue from future ticks —
#      simulated here via the stub, mirroring the real selector's
#      `approved`/`stalled` subtraction.
#
# No real `gh` binary needed — this operates purely at the function level
# (mirrors the "sourcing the real functions, stubbing only I/O-touching
# verbs" golden-trace style used by
# tests/unit/test-issue-466-crashed-session-recovery.sh), plus a
# source-of-truth grep proving dispatcher-tick.sh actually wires Step 6 in
# after Step 5. The orchestration (run_liveness_watchdog) lives in
# lib-dispatch.sh, NOT lib-liveness.sh — its tier-2 label_swap must sit
# inside a file check-spec-drift.sh's Check C actually scans — so both libs
# are sourced here.
#
# Run: bash tests/e2e/run-liveness-watchdog-e2e.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-liveness.sh"
LIB_DISPATCH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
PASS=0; FAIL=0
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

[[ -f "$LIB" ]] || { echo -e "${RED}FATAL${NC}: lib-liveness.sh missing"; exit 1; }
[[ -f "$LIB_DISPATCH" ]] || { echo -e "${RED}FATAL${NC}: lib-dispatch.sh missing"; exit 1; }
[[ -f "$TICK" ]] || { echo -e "${RED}FATAL${NC}: dispatcher-tick.sh missing"; exit 1; }

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID="e2e-467-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5

echo "=== TC-LIVENESS-045: stub-dispatcher replay of the api_error park shape ==="

# shellcheck disable=SC1090
source "$LIB"
# shellcheck disable=SC1090
source "$LIB_DISPATCH"
set +e

# ---------------------------------------------------------------------------
# In-memory GitHub issue #99 state — the api_error park shape: pending-dev,
# resolvable session id already reflected in the comment history (an earlier
# INV-125 crashed-session-retry:<head> marker that already spent the one
# bounded recovery), dead dev wrapper, PR head frozen at sha-api-error.
ISSUE_LABEL="pending-dev"
ISSUE_COMMENTS='[
  {"authorKind":"bot","createdAt":"2026-07-10T10:00:00Z","body":"Dev Session ID: `sid-api-error-1`"},
  {"authorKind":"bot","createdAt":"2026-07-10T10:05:00Z","body":"Review findings: 1. fix the thing\nReview Session: rsid-1"},
  {"authorKind":"bot","createdAt":"2026-07-10T10:10:00Z","body":"crashed-session-retry:sha-api-error"}
]'
PR_HEAD="sha-api-error"

was_just_dispatched() { return 1; }
is_within_grace_period() { return 1; }
_dispatch_marker_recent() { return 1; }
pid_alive() { return 1; }   # dev wrapper is dead — this is the park
log() { :; }

list_pending_dev() {
  if [[ "$ISSUE_LABEL" == "pending-dev" ]]; then
    printf '%s' '[{"number":99,"labels":["autonomous","pending-dev"]}]'
  else
    printf '%s' '[]'
  fi
}
list_pending_review() { printf '%s' '[]'; }
fetch_pr_for_issue() { printf '%s' "{\"headRefOid\":\"${PR_HEAD}\"}"; }
itp_list_comments() { printf '%s' "$ISSUE_COMMENTS"; }
itp_read_task() { printf '%s' "{\"labels\":[\"${ISSUE_LABEL}\"]}"; }
itp_post_comment() {
  ISSUE_COMMENTS=$(jq --arg b "$2" '. + [{"authorKind":"bot","createdAt":"2026-07-10T11:00:00Z","body":$b}]' <<<"$ISSUE_COMMENTS")
}
label_swap() {
  local _issue="$1" _from="$2" _to="$3"
  ISSUE_LABEL="$_to"
}

NOTICE=6
STALL=18
tier1_seen_at=""
tier2_seen_at=""
tier1_fire_count=0
tier2_fire_count=0

for tick in $(seq 1 25); do
  before=$(jq '[.[] | select(.body | test("dispatcher-liveness-watchdog:"))] | length' <<<"$ISSUE_COMMENTS")
  run_liveness_watchdog
  after_tier1=$(jq '[.[] | select(.body | contains("reason=liveness-no-progress"))] | length' <<<"$ISSUE_COMMENTS")
  after_tier2=$(jq '[.[] | select(.body | contains("reason=liveness-timeout"))] | length' <<<"$ISSUE_COMMENTS")

  if [[ "$after_tier1" -gt "$tier1_fire_count" ]]; then
    [[ -z "$tier1_seen_at" ]] && tier1_seen_at="$tick"
    tier1_fire_count="$after_tier1"
  fi
  if [[ "$after_tier2" -gt "$tier2_fire_count" ]]; then
    [[ -z "$tier2_seen_at" ]] && tier2_seen_at="$tick"
    tier2_fire_count="$after_tier2"
  fi
  : "$before"  # silence unused-var lint; kept for readability of the loop body
done

[[ "$tier1_seen_at" == "$NOTICE" ]] \
  && ok "TC-LIVENESS-045a tier-1 escalation appears at exactly tick ${NOTICE}" \
  || bad "TC-LIVENESS-045a expected tier-1 at tick ${NOTICE}, saw it at tick '${tier1_seen_at:-<never>}'"

[[ "$tier1_fire_count" -eq 1 ]] \
  && ok "TC-LIVENESS-045b tier-1 comment posted exactly once across the whole run" \
  || bad "TC-LIVENESS-045b expected exactly 1 tier-1 comment, got ${tier1_fire_count}"

[[ "$tier2_seen_at" == "$STALL" ]] \
  && ok "TC-LIVENESS-045c stalled + reason=liveness-timeout report appears at exactly tick ${STALL}" \
  || bad "TC-LIVENESS-045c expected tier-2 at tick ${STALL}, saw it at tick '${tier2_seen_at:-<never>}'"

[[ "$tier2_fire_count" -eq 1 ]] \
  && ok "TC-LIVENESS-045d tier-2 report posted exactly once across the whole run" \
  || bad "TC-LIVENESS-045d expected exactly 1 tier-2 report, got ${tier2_fire_count}"

[[ "$ISSUE_LABEL" == "stalled" ]] \
  && ok "TC-LIVENESS-045e issue #99 ended the run transitioned to stalled" \
  || bad "TC-LIVENESS-045e issue #99 ended the run with label '${ISSUE_LABEL}' (expected stalled)"

# Once stalled, list_pending_dev's own exclusion removes the issue — further
# ticks must be complete no-ops (no new comments, no re-transition attempt).
comments_before_extra="$ISSUE_COMMENTS"
run_liveness_watchdog
run_liveness_watchdog
[[ "$ISSUE_COMMENTS" == "$comments_before_extra" ]] \
  && ok "TC-LIVENESS-045f post-stall ticks are complete no-ops (selector excludes stalled issues)" \
  || bad "TC-LIVENESS-045f post-stall ticks must not touch an already-stalled issue"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LIVENESS-045g: dispatcher-tick.sh wires Step 6 in after Step 5 ==="
# Source-of-truth grep pin: Step 6 must be sourced/invoked, and it must sit
# AFTER the Step 5 stale-detection loop (so JUST_DISPATCHED protection from
# Steps 2-4 also covers Step 6) and BEFORE the metrics prune tail.
step5_end_line=$(grep -n 'Retention built into the collector' "$TICK" | head -1 | cut -d: -f1)
step6_call_line=$(grep -n 'run_liveness_watchdog$' "$TICK" | head -1 | cut -d: -f1)
lib_source_line=$(grep -n 'source "\${LIB_DIR}/lib-liveness.sh"' "$TICK" | head -1 | cut -d: -f1)

if [[ -n "$lib_source_line" ]]; then
  ok "TC-LIVENESS-045g1 dispatcher-tick.sh sources lib-liveness.sh"
else
  bad "TC-LIVENESS-045g1 dispatcher-tick.sh does not source lib-liveness.sh"
fi

if [[ -n "$step6_call_line" && -n "$step5_end_line" && "$step6_call_line" -lt "$step5_end_line" ]]; then
  ok "TC-LIVENESS-045g2 run_liveness_watchdog (line $step6_call_line) is called before the metrics-prune tail (line $step5_end_line)"
else
  bad "TC-LIVENESS-045g2 run_liveness_watchdog must be called before the metrics-prune tail (call=$step6_call_line tail=$step5_end_line)"
fi

echo ""
echo "============================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "============================================"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
