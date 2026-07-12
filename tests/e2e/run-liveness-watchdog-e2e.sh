#!/bin/bash
# run-liveness-watchdog-e2e.sh — E2E for the generic liveness watchdog
# (issue #467, INV-128). TC-LIVENESS-045.
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

# TC-LIVENESS-045i [operator guidance, round 6]: the trip report itself no
# longer embeds the bare marker as its first line — round 6 split the marker
# out into its own comment so `_liveness_prior_marker` can use a whole-body
# anchor. Assert the split held through the full 25-tick stub-dispatcher
# replay, not just the constructed-fixture unit tests.
trip_report_body=$(jq -r '[.[] | select(.body | contains("reason=liveness-timeout"))] | last | .body' <<<"$ISSUE_COMMENTS")
if [[ "$trip_report_body" != "<!--"* ]]; then
  ok "TC-LIVENESS-045i the trip report body does not start with the marker prefix (split into two comments)"
else
  bad "TC-LIVENESS-045i trip report body unexpectedly starts with the marker prefix: ${trip_report_body:0:80}"
fi
bare_marker_count=$(jq '[.[] | select(.body | test("^<!-- dispatcher-liveness-watchdog: .*-->[[:space:]]*$"))] | length' <<<"$ISSUE_COMMENTS")
[[ "$bare_marker_count" -ge 2 ]] \
  && ok "TC-LIVENESS-045j at least a tier-1 and a tier-2 bare marker comment exist (whole-body-anchored)" \
  || bad "TC-LIVENESS-045j expected >=2 whole-body-anchored bare marker comments, got ${bare_marker_count}"

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
# TC-LIVENESS-045h [codex review, PR #472, BLOCKING #2]: operator resume after
# the tier-2 report already fired. The trip's bare marker (posted strictly
# BEFORE the trip report, per round 6) sits right before the cutoff the trip
# report's heading sets. An operator who fixes the park and removes `stalled`
# (restoring `pending-dev`), with the fingerprint's OTHER components
# otherwise unchanged, must get a FRESH liveness episode — not an immediate
# re-trip from the old trip's high count read back.
ISSUE_LABEL="pending-dev"
run_liveness_watchdog
[[ "$ISSUE_LABEL" == "pending-dev" ]] \
  && ok "TC-LIVENESS-045h1 resume after un-stall does NOT immediately re-transition to stalled" \
  || bad "TC-LIVENESS-045h1 resume after un-stall re-tripped immediately (label='${ISSUE_LABEL}')"

fresh_marker=$(jq -r '[.[] | select(.body | test("^<!-- dispatcher-liveness-watchdog:"))] | last | .body' <<<"$ISSUE_COMMENTS")
[[ "$fresh_marker" == *"count=1 tier1=0"* ]] \
  && ok "TC-LIVENESS-045h2 resume after un-stall restarts the count at 1 (fresh episode)" \
  || bad "TC-LIVENESS-045h2 expected a fresh count=1 tier1=0 marker, got: ${fresh_marker}"

# ---------------------------------------------------------------------------
# TC-LIVENESS-045k [codex review, PR #472, round 7 BLOCKING]: a human comment
# that merely MENTIONS the tier-2 trip heading — anywhere in its body, not as
# its own opening line — must NOT act as a forged cutoff. The round-6 cutoff
# detection used an unanchored `contains("Liveness watchdog tripped")`, so
# ANY comment referencing that bare phrase (e.g. a collaborator discussing a
# past trip in prose) would register as a NEW trip and move the cutoff past
# the genuine earlier marker, permanently resetting a still-frozen issue's
# series to count=1 and letting it dodge tier 2 forever.
#
# Fresh in-memory issue #199 (not #99's history above) so this scenario's own
# `itp_post_comment` stub can stamp STRICTLY INCREASING timestamps — reusing
# #99's stub (which stamps every post with the SAME fixed timestamp) would
# make the marker's own `createdAt` collide with an earlier tier-2 trip's
# fixed-timestamp cutoff and never satisfy the real leaf's `createdAt >
# $cutoff` requirement, a stub artifact unrelated to the bug under test.
ISSUE_LABEL_K="pending-dev"
ISSUE_COMMENTS_K='[{"authorKind":"bot","createdAt":"2026-07-10T09:00:00Z","body":"Dev Session ID: `sid-round7-1`"}]'
PR_HEAD_K="sha-round7-regression"
_k_clock=0
list_pending_dev() { printf '%s' '[{"number":199,"labels":["autonomous","pending-dev"]}]'; }
fetch_pr_for_issue() { printf '%s' "{\"headRefOid\":\"${PR_HEAD_K}\"}"; }
itp_list_comments() { printf '%s' "$ISSUE_COMMENTS_K"; }
itp_read_task() { printf '%s' "{\"labels\":[\"${ISSUE_LABEL_K}\"]}"; }
itp_post_comment() {
  _k_clock=$((_k_clock + 1))
  ISSUE_COMMENTS_K=$(jq --arg b "$2" --arg t "$(printf '2026-07-10T%02d:00:00Z' $((9 + _k_clock)))" \
    '. + [{"authorKind":"bot","createdAt":$t,"body":$b}]' <<<"$ISSUE_COMMENTS_K")
}
label_swap() { ISSUE_LABEL_K="$3"; }

# Build up 10 no-op ticks on a genuine, still-in-progress episode.
for tick in $(seq 1 10); do
  run_liveness_watchdog
done
marker_before_forgery=$(jq -r '[.[] | select(.body | test("^<!-- dispatcher-liveness-watchdog:"))] | last | .body' <<<"$ISSUE_COMMENTS_K")

# Inject the forged comment: matches `_LIVENESS_IDEMPOTENT_PATTERN` via
# `reason=liveness-timeout` (so it does NOT itself change the fingerprint's
# comment-count component), but also contains the bare trip-heading phrase
# mid-sentence — the exact round-6 false-cutoff shape.
_k_clock=$((_k_clock + 1))
forged_mention="A collaborator can copy the tier-2 header (excluded via reason=liveness-timeout), quoting: ${_LIVENESS_TIER2_HEADING}"
ISSUE_COMMENTS_K=$(jq --arg b "$forged_mention" --arg t "$(printf '2026-07-10T%02d:00:00Z' $((9 + _k_clock)))" \
  '. + [{"authorKind":"human","createdAt":$t,"body":$b}]' <<<"$ISSUE_COMMENTS_K")

run_liveness_watchdog
marker_after_forgery=$(jq -r '[.[] | select(.body | test("^<!-- dispatcher-liveness-watchdog:"))] | last | .body' <<<"$ISSUE_COMMENTS_K")

[[ "$marker_before_forgery" == *"count=10"* && "$marker_after_forgery" == *"count=11"* ]] \
  && ok "TC-LIVENESS-045k a forged mid-comment mention of the trip heading does not reset the count (10 -> 11, not 10 -> 1)" \
  || bad "TC-LIVENESS-045k expected count 10 -> 11 across the forged comment; saw '${marker_before_forgery}' -> '${marker_after_forgery}'"

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
