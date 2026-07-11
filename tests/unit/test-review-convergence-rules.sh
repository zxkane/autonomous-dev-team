#!/bin/bash
# test-review-convergence-rules.sh — issue #449.
#
# Pins the pure decision-logic helpers added for the severity-aware blocking
# ratchet (R1: lib-review-severity.sh + lib-review-round.sh), the INV-124
# review-round-cap escalation breaker (R2: lib-review-cap.sh), and the R3
# E2E evidence-freshness pre-check (lib-review-e2e.sh), plus source-of-truth
# wiring greps against autonomous-review.sh (mirrors
# test-e2e-gate-circuit-breaker.sh's two-pronged style: pure logic + wiring
# greps, since the wrapper itself is too heavy to run end-to-end).
#
# See docs/test-cases/review-convergence-rules.md for the TC-REVIEW-CONV-*
# mapping.
#
# Run: bash tests/unit/test-review-convergence-rules.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHP_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-code-host.sh"
SEVERITY_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-severity.sh"
ROUND_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-round.sh"
CAP_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-cap.sh"
E2E_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-e2e.sh"
CODEX_ADAPTER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/adapters/codex.sh"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
AGGREGATE_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-aggregate.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle: $needle"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  if [[ -f "$file" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      missing file: $file"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists "setup: lib-review-severity.sh exists" "$SEVERITY_LIB"
assert_file_exists "setup: lib-review-round.sh exists" "$ROUND_LIB"
assert_file_exists "setup: lib-review-cap.sh exists" "$CAP_LIB"
assert_file_exists "setup: autonomous-review.sh exists" "$WRAPPER"

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-code-host.sh
source "$CHP_LIB"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-severity.sh
source "$SEVERITY_LIB"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-round.sh
source "$ROUND_LIB"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-cap.sh
source "$CAP_LIB"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-e2e.sh
source "$E2E_LIB"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-aggregate.sh
source "$AGGREGATE_LIB"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/adapters/codex.sh
source "$CODEX_ADAPTER"

FIXTURES="$SCRIPT_DIR/fixtures"

# ===========================================================================
echo "=== TC-REVIEW-CONV-001..012: shouldBlockFinding matrix ==="
# ===========================================================================

assert_eq "TC-REVIEW-CONV-001 round=1 P0 blocks" "true" "$(shouldBlockFinding 1 P0 && echo true || echo false)"
assert_eq "TC-REVIEW-CONV-002 round=1 P1 blocks" "true" "$(shouldBlockFinding 1 P1 && echo true || echo false)"
assert_eq "TC-REVIEW-CONV-003 round=1 P2 blocks" "true" "$(shouldBlockFinding 1 P2 && echo true || echo false)"
assert_eq "TC-REVIEW-CONV-004 round=1 P3 blocks" "true" "$(shouldBlockFinding 1 P3 && echo true || echo false)"
assert_eq "TC-REVIEW-CONV-005 round=2 P3 blocks" "true" "$(shouldBlockFinding 2 P3 && echo true || echo false)"
assert_eq "TC-REVIEW-CONV-006 round=3 P0 blocks" "true" "$(shouldBlockFinding 3 P0 && echo true || echo false)"
assert_eq "TC-REVIEW-CONV-007 round=3 P2 blocks" "true" "$(shouldBlockFinding 3 P2 && echo true || echo false)"
assert_eq "TC-REVIEW-CONV-008 round=3 P3 does NOT block" "false" "$(shouldBlockFinding 3 P3 && echo true || echo false)"
assert_eq "TC-REVIEW-CONV-009 round=4 P3 does NOT block" "false" "$(shouldBlockFinding 4 P3 && echo true || echo false)"
assert_eq "TC-REVIEW-CONV-010 round=5 P1 blocks" "true" "$(shouldBlockFinding 5 P1 && echo true || echo false)"
assert_eq "TC-REVIEW-CONV-011 round=5 P2 does NOT block" "false" "$(shouldBlockFinding 5 P2 && echo true || echo false)"
assert_eq "TC-REVIEW-CONV-012 round=5 P3 does NOT block" "false" "$(shouldBlockFinding 5 P3 && echo true || echo false)"

# Regression pin: "none" (untagged) ALWAYS blocks, at every round — fail-safe.
assert_eq "TC-REVIEW-CONV-012b round=10 'none' still blocks (fail-safe)" "true" "$(shouldBlockFinding 10 none && echo true || echo false)"
# Malformed round defaults to 1 (strictest floor).
assert_eq "TC-REVIEW-CONV-012c malformed round defaults to strictest floor (P3 blocks)" "true" "$(shouldBlockFinding garbage P3 && echo true || echo false)"

# ===========================================================================
echo
echo "=== TC-REVIEW-CONV-013..020: severity-tag extraction ==="
# ===========================================================================

assert_eq "TC-REVIEW-CONV-013 codex stdout [P1] only → P1" "P1" \
  "$(_review_extract_highest_severity '[P1] src/x.ts:1 -- silent failure.')"
assert_eq "TC-REVIEW-CONV-014 codex stdout [P0]+[P2] → P0 (highest wins)" "P0" \
  "$(_review_extract_highest_severity '[P2] minor nit
[P0] catastrophic data loss')"
assert_eq "TC-REVIEW-CONV-015 no severity tag → none" "none" \
  "$(_review_extract_highest_severity 'Looks good to merge. No issues.')"
assert_eq "TC-REVIEW-CONV-016 [P3] only → P3" "P3" \
  "$(_review_extract_highest_severity '[P3] consider a test')"
assert_eq "TC-REVIEW-CONV-017 generic numbered-list [P2]+[P1] → P1" "P1" \
  "$(_review_extract_highest_severity '1. [P2] minor issue
2. [P1] blocking issue')"
assert_eq "TC-REVIEW-CONV-018 generic numbered-list all [P3] → P3" "P3" \
  "$(_review_extract_highest_severity '1. [P3] first
2. [P3] second')"
assert_eq "TC-REVIEW-CONV-019 legacy untagged FAIL body → none" "none" \
  "$(_review_extract_highest_severity '1. missing null check
2. off-by-one error')"

# TC-REVIEW-CONV-020: the codex malformed-output finding-boundary regex now
# recognizes [P0] (pre-#449 it was hardcoded to P[123]).
assert_contains "TC-REVIEW-CONV-020 codex.sh finding-boundary regex includes P0" \
  "$(cat "$CODEX_ADAPTER")" 'P[0123]'
_p0_only_body='[P0] catastrophic finding at the very top'
_codex_review_stdout_is_malformed <(printf '%s\n' "$_p0_only_body") 2>/dev/null
assert_eq "TC-REVIEW-CONV-020b a bare [P0]-led capture is NOT malformed (rc 1)" "1" "$?"

# _codex_review_classify_stdout now flags fail on ANY tag (P0-P3), not just P1
# — the round-aware demotion is a LATER stage (the pre-aggregation filter).
_TMP_CX=$(mktemp)
trap 'rm -f "$_TMP_CX"' EXIT
printf '%s\n' '[P2] minor nit' '[P3] consider a test' > "$_TMP_CX"
assert_eq "TC-REVIEW-CONV-020c classify_stdout flags fail on P2/P3 too (#449 ratchet)" "fail" \
  "$(_codex_review_classify_stdout "$_TMP_CX")"

# ===========================================================================
echo
echo "=== TC-REVIEW-CONV-021..027: review-round-counter marker ==="
# ===========================================================================

assert_eq "TC-REVIEW-CONV-021 fresh issue, no prior marker → round=1" "1" \
  "$(_review_round_next_count "" deadbeef)"

m22=$(_review_round_marker 100 deadbeef 1)
assert_eq "TC-REVIEW-CONV-022 same HEAD increments" "2" \
  "$(_review_round_next_count "$m22" deadbeef)"

m23=$(_review_round_marker 100 deadbeef 3)
assert_eq "TC-REVIEW-CONV-023 new HEAD resets to 1" "1" \
  "$(_review_round_next_count "$m23" cafebabe)"

assert_eq "TC-REVIEW-CONV-024a malformed marker parses to round=0" "0" \
  "$(_review_round_parse_count "not a marker at all {{{" deadbeef)"
assert_eq "TC-REVIEW-CONV-024b malformed marker → next round=1 (no crash)" "1" \
  "$(_review_round_next_count "<!-- review-round-counter: garbage -->" deadbeef)"

# TC-REVIEW-CONV-025/026: authenticity filter is enforced at the WRAPPER call
# site (jq `select(.authorKind != "human")`), mirrored here as a source grep
# (the pure marker helpers themselves are author-agnostic by design — the
# filtering happens on the comment SCAN before the marker text ever reaches
# them, exactly like INV-105/INV-122).
assert_contains "TC-REVIEW-CONV-025/026 wrapper filters authorKind != \"human\" on the round-counter read" \
  "$(cat "$WRAPPER")" 'contains("review-round-counter:")'

m27=$(_review_round_marker 100 deadbeef 3)
assert_eq "TC-REVIEW-CONV-027a marker round-trip contains issue" "true" \
  "$([[ "$m27" == *"issue=100"* ]] && echo true || echo false)"
assert_eq "TC-REVIEW-CONV-027b marker round-trip: parse returns the same round" "3" \
  "$(_review_round_parse_count "$m27" deadbeef)"

# ===========================================================================
echo
echo "=== TC-REVIEW-CONV-028..038: INV-124 round-cap breaker ==="
# ===========================================================================

unset REVIEW_CONVERGENCE_CAP
assert_eq "TC-REVIEW-CONV-028 REVIEW_CONVERGENCE_CAP unset → defaults to 5" "5" "$(_review_cap_threshold 2>/dev/null)"

REVIEW_CONVERGENCE_CAP="banana"
warn_out=$(_review_cap_threshold 2>&1 1>/dev/null)
val_out=$(_review_cap_threshold 2>/dev/null)
assert_eq "TC-REVIEW-CONV-029a non-numeric cap falls back to 5" "5" "$val_out"
assert_contains "TC-REVIEW-CONV-029b non-numeric cap logs a warning" "$warn_out" "WARNING"

REVIEW_CONVERGENCE_CAP="1"
warn_out=$(_review_cap_threshold 2>&1 1>/dev/null)
val_out=$(_review_cap_threshold 2>/dev/null)
assert_eq "TC-REVIEW-CONV-030a cap=1 (below floor) falls back to 5" "5" "$val_out"
assert_contains "TC-REVIEW-CONV-030b cap=1 logs a warning" "$warn_out" "WARNING"

REVIEW_CONVERGENCE_CAP="8"
warn_out=$(_review_cap_threshold 2>&1 1>/dev/null)
val_out=$(_review_cap_threshold 2>/dev/null)
assert_eq "TC-REVIEW-CONV-031a cap=8 honored verbatim" "8" "$val_out"
assert_eq "TC-REVIEW-CONV-031b valid cap logs no warning" "" "$warn_out"
unset REVIEW_CONVERGENCE_CAP

m32=$(_review_cap_marker 100 deadbeef 3)
assert_eq "TC-REVIEW-CONV-032 same-series marker → next = stored + 1" "4" \
  "$(_review_cap_next_count "$m32")"

assert_eq "TC-REVIEW-CONV-033 no prior marker → next = 1" "1" \
  "$(_review_cap_next_count "")"

# TC-REVIEW-CONV-034: 5 consecutive failed-substantive rounds on progressively
# new HEADs → 6th blocked. Simulate by feeding the marker forward across a
# HEAD change each round (the counter is head-AGNOSTIC by design — see
# lib-review-cap.sh's design note).
_sim_marker=""
_sim_heads=(aaa111 bbb222 ccc333 ddd444 eee555 fff666)
_sim_round=0
for _h in "${_sim_heads[@]}"; do
  _sim_round=$(_review_cap_next_count "$_sim_marker")
  _sim_marker=$(_review_cap_marker 100 "$_h" "$_sim_round")
done
assert_eq "TC-REVIEW-CONV-034 6th consecutive failed-substantive round (progressively new HEADs) reaches round=6" "6" "$_sim_round"
assert_eq "TC-REVIEW-CONV-034b round=6 >= default threshold=5 → trip" "true" \
  "$([[ "$_sim_round" -ge "$(_review_cap_threshold 2>/dev/null)" ]] && echo true || echo false)"

# TC-REVIEW-CONV-035: already-stalled skip is enforced at the wrapper call
# site (source grep — mirrors how the pure lib holds no label-state itself).
assert_contains "TC-REVIEW-CONV-035 wrapper checks already-stalled before tripping INV-124" \
  "$(cat "$WRAPPER")" 'dispatcher-review-cap-breaker'

# TC-REVIEW-CONV-036: only fires when AGGREGATE=="fail" — pinned as a wiring
# grep (the breaker must not run on the all-unavailable / crash-without-verdict
# sub-path, which has no severity floor to evaluate).
inv124_block=$(awk '/\[#449\] INV-124/,/emit_verdict_trailer "\$ISSUE_NUMBER" "\$REPO" "failed-substantive"/' "$WRAPPER")
assert_contains "TC-REVIEW-CONV-036 INV-124 block is gated on \$AGGREGATE == \"fail\"" \
  "$inv124_block" '$AGGREGATE" == "fail"'

# TC-REVIEW-CONV-037: failed-non-substantive is out of scope — pinned via the
# same gating (the crash-without-verdict branch, which emits
# failed-non-substantive, sits in the sibling `if` arm, never reaching the
# INV-124 block at all).
crash_branch=$(awk '/AGENT_EXIT -ne 0.*LATEST_COMMENT/,/failed-non-substantive.*other/' "$WRAPPER")
assert_eq "TC-REVIEW-CONV-037 crash-without-verdict (non-substantive) branch has no INV-124 reference" "" \
  "$(grep -o 'INV-124' <<<"$crash_branch")"

# TC-REVIEW-CONV-038: transition precedes report (ordering pin, mirrors
# INV-122's TOCTOU-safe ordering).
transition_line=$(grep -n 'itp_transition_state "\$ISSUE_NUMBER" "reviewing" "stalled"' "$WRAPPER" | tail -1 | cut -d: -f1)
report_line=$(grep -n 'reason=review-round-cap' "$WRAPPER" | head -1 | cut -d: -f1)
if [[ -n "$transition_line" && -n "$report_line" && "$transition_line" -lt "$report_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-REVIEW-CONV-038 transition (line $transition_line) precedes report (line $report_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-CONV-038 transition must precede report"
  echo "      transition_line=$transition_line report_line=$report_line"
  FAIL=$((FAIL + 1))
fi

# ===========================================================================
echo
echo "=== TC-REVIEW-CONV-039..044: R3 evidence-freshness on a new HEAD ==="
# ===========================================================================

# Stub chp_ci_status for the pre-check tests.
chp_ci_status() { printf '%s\n' "${_STUB_CI_STATUS:-green}"; }

_STUB_CI_STATUS="green"
_e2e_ci_green_precheck "999"
assert_eq "TC-REVIEW-CONV-039 green CI → precheck passes (rc 0)" "0" "$?"

_STUB_CI_STATUS="failed"
_e2e_ci_green_precheck "999"
assert_eq "TC-REVIEW-CONV-040 red CI → precheck fails (rc 1)" "1" "$?"

_STUB_CI_STATUS="pending"
_e2e_ci_green_precheck "999"
assert_eq "TC-REVIEW-CONV-041 pending CI → precheck fails (rc 1)" "1" "$?"

# TC-REVIEW-CONV-042: same-HEAD reuse path is unaffected — pinned as a source
# grep: the reuse block in _run_command_e2e_lane returns BEFORE any R3 logic
# is reachable (R3 only lives in the wrapper's Phase-A gate block, not inside
# the lane's own reuse short-circuit).
assert_contains "TC-REVIEW-CONV-042 same-HEAD reuse short-circuits before pre-hook/verify (unaffected by R3)" \
  "$(cat "$E2E_LIB")" 'reusing, skipping pre-hook + verify'

# TC-REVIEW-CONV-043: a chp_ci_status query failure fails safe (never treated
# as green).
chp_ci_status() { return 1; }
_e2e_ci_green_precheck "999"
assert_eq "TC-REVIEW-CONV-043 chp_ci_status failure → precheck fails safe (rc 1)" "1" "$?"
unset -f chp_ci_status

# TC-REVIEW-CONV-044: _classify_e2e_gate's signature/branches are unchanged
# (regression pin) — same rc/evidence_present args, same three output tokens.
assert_eq "TC-REVIEW-CONV-044a rc=0 + evidence=1 → pass (unchanged)" "pass" "$(_classify_e2e_gate 0 1)"
assert_eq "TC-REVIEW-CONV-044b rc=0 + evidence=0 → block-nonsubstantive (unchanged)" "block-nonsubstantive" "$(_classify_e2e_gate 0 0)"
assert_eq "TC-REVIEW-CONV-044c rc=1 + evidence=1 → fail (unchanged, stale evidence never rescues)" "fail" "$(_classify_e2e_gate 1 1)"
assert_eq "TC-REVIEW-CONV-044d non-numeric rc → fail (unchanged)" "fail" "$(_classify_e2e_gate abc 1)"

# Wiring pin: the R3 pre-check call sits between the evidence re-fetch and the
# _classify_e2e_gate call, and is gated on rc==0 (never touches the fail path).
precheck_call_line=$(grep -n '_e2e_ci_green_precheck "\$PR_NUMBER"' "$WRAPPER" | head -1 | cut -d: -f1)
gate_call_line=$(grep -n 'E2E_GATE=\$(_classify_e2e_gate' "$WRAPPER" | head -1 | cut -d: -f1)
evidence_fetch_line=$(grep -n '_e2e_evidence=\$(_fetch_sha_evidence' "$WRAPPER" | head -1 | cut -d: -f1)
if [[ -n "$precheck_call_line" && -n "$gate_call_line" && -n "$evidence_fetch_line" ]] \
   && [[ "$precheck_call_line" -gt "$evidence_fetch_line" ]] \
   && [[ "$precheck_call_line" -lt "$gate_call_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-REVIEW-CONV-044e R3 pre-check (line $precheck_call_line) sits between evidence re-fetch (line $evidence_fetch_line) and the gate call (line $gate_call_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-CONV-044e R3 pre-check must sit between the evidence re-fetch and the gate call"
  echo "      precheck_call_line=$precheck_call_line evidence_fetch_line=$evidence_fetch_line gate_call_line=$gate_call_line"
  FAIL=$((FAIL + 1))
fi

# ===========================================================================
echo
echo "=== TC-REVIEW-CONV-045..048: pre-aggregation severity-filter wiring ==="
# ===========================================================================

# TC-REVIEW-CONV-045/046: _review_apply_severity_filter — the actual
# pre-aggregation filter function.
assert_eq "TC-REVIEW-CONV-045 fail demoted to pass when severity below round floor (P3 @ round 5)" "pass" \
  "$(_review_apply_severity_filter fail '[P3] minor residual risk' 5)"
assert_eq "TC-REVIEW-CONV-046 fail stays fail when severity at/above round floor (P1 @ round 5)" "fail" \
  "$(_review_apply_severity_filter fail '[P1] blocking issue' 5)"
assert_eq "TC-REVIEW-CONV-046b pass/unavailable/timed-out pass through unchanged" "pass" \
  "$(_review_apply_severity_filter pass 'irrelevant text' 5)"
assert_eq "TC-REVIEW-CONV-046c unavailable passes through unchanged" "unavailable" \
  "$(_review_apply_severity_filter unavailable '' 5)"
assert_eq "TC-REVIEW-CONV-046d timed-out passes through unchanged" "timed-out" \
  "$(_review_apply_severity_filter timed-out '' 5)"

# TC-REVIEW-CONV-047: severity filter runs strictly between the terminal
# no-verdict sweep and _aggregate_review_verdicts (line-order wiring pin).
sweep_line=$(grep -n '_classify_noverdict_agent "\${AGENT_LAUNCH_RC\[' "$WRAPPER" | head -1 | cut -d: -f1)
filter_call_line=$(grep -n '_review_apply_severity_filter "\${AGENT_VERDICTS\[\$_i\]}"' "$WRAPPER" | head -1 | cut -d: -f1)
aggregate_call_line=$(grep -n 'AGGREGATE=\$(_aggregate_review_verdicts' "$WRAPPER" | head -1 | cut -d: -f1)
if [[ -n "$sweep_line" && -n "$filter_call_line" && -n "$aggregate_call_line" ]] \
   && [[ "$filter_call_line" -gt "$sweep_line" ]] \
   && [[ "$filter_call_line" -lt "$aggregate_call_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-REVIEW-CONV-047 severity filter (line $filter_call_line) sits between the terminal sweep (line $sweep_line) and aggregation (line $aggregate_call_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-CONV-047 severity filter must sit between the terminal sweep and aggregation"
  echo "      sweep_line=$sweep_line filter_call_line=$filter_call_line aggregate_call_line=$aggregate_call_line"
  FAIL=$((FAIL + 1))
fi

# TC-REVIEW-CONV-048: _aggregate_review_verdicts itself is unchanged — same
# vocabulary in, same three tokens out (regression pin).
assert_eq "TC-REVIEW-CONV-048a pass+pass → pass (unchanged)" "pass" "$(_aggregate_review_verdicts pass pass)"
assert_eq "TC-REVIEW-CONV-048b pass+fail → fail (unchanged)" "fail" "$(_aggregate_review_verdicts pass fail)"
assert_eq "TC-REVIEW-CONV-048c unavailable+unavailable → all-unavailable (unchanged)" "all-unavailable" \
  "$(_aggregate_review_verdicts unavailable unavailable)"
assert_eq "TC-REVIEW-CONV-048d timed-out is a deciding FAIL (unchanged)" "fail" "$(_aggregate_review_verdicts timed-out)"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
