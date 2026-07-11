#!/bin/bash
# test-review-convergence-rules.sh — issue #449.
#
# Pins the pure decision-logic helpers added for the severity-aware blocking
# ratchet (R1: lib-review-severity.sh + lib-review-round.sh), the INV-126
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
ARTIFACT_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-artifact.sh"

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
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-artifact.sh
source "$ARTIFACT_LIB"

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
# Boundary pin: round=4 P2 blocks (the P2 floor is "round <= 4"), mirroring
# the P3 boundary's own both-edges coverage (TC-005 round=2 blocks, TC-008
# round=3 doesn't) — this edge (round=4 blocks, round=5 doesn't) was
# previously untested on the blocking side.
assert_eq "TC-REVIEW-CONV-012d round=4 P2 blocks (boundary)" "true" "$(shouldBlockFinding 4 P2 && echo true || echo false)"

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
echo "=== TC-REVIEW-CONV-020d..020g: per-finding severity scan (untagged-masking fix) ==="
# ===========================================================================

# TC-REVIEW-CONV-020d: a numbered body with one correctly-tagged low-severity
# finding and one UNTAGGED finding must extract "none" (fail-safe) — NOT the
# lone tag found elsewhere in the body. A whole-body "highest tag anywhere"
# scan would wrongly report P3 here and let the severity filter demote the
# whole verdict, silently dropping the untagged (potentially severe) finding.
assert_eq "TC-REVIEW-CONV-020d numbered body: one [P3] + one untagged finding → none (fail-safe, not masked)" "none" \
  "$(_review_extract_highest_severity $'1. [P3] minor nit\n2. untagged severe finding')"

# TC-REVIEW-CONV-020e: every numbered finding tagged → normal highest-wins.
assert_eq "TC-REVIEW-CONV-020e numbered body: all findings tagged → highest wins" "P1" \
  "$(_review_extract_highest_severity $'1. [P2] narrow gap\n2. [P1] blocker')"

# TC-REVIEW-CONV-020f: codex free-form (no numbered lines at all) keeps the
# original whole-text scan — an unstructured capture has no per-finding
# boundary to key an "untagged finding" check on.
assert_eq "TC-REVIEW-CONV-020f free-form (no numbering) still scans whole text" "P0" \
  "$(_review_extract_highest_severity $'[P2] minor nit\n[P0] catastrophic')"

# TC-REVIEW-CONV-020g: a single numbered finding with no tag anywhere → none.
assert_eq "TC-REVIEW-CONV-020g single untagged numbered finding → none" "none" \
  "$(_review_extract_highest_severity '1. missing null check')"

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

# TC-REVIEW-CONV-027c: the wrapper-level empty-PR_HEAD_SHA guard (pinned as a
# wiring grep, since the pure lib functions themselves are head-value-agnostic
# — the guard lives at the CALL SITE, deciding whether to call them at all).
# A chp_pr_view failure must default to the strictest floor (round=1) and
# skip posting a marker, mirroring INV-122's own non-empty-PR_HEAD_SHA guard.
assert_contains "TC-REVIEW-CONV-027c wrapper guards the R1 counter on a non-empty PR_HEAD_SHA" \
  "$(cat "$WRAPPER")" 'if [[ -n "$PR_HEAD_SHA" ]]'
round1_guard_line=$(grep -n 'if \[\[ -n "\$PR_HEAD_SHA" \]\]; then' "$WRAPPER" | head -1 | cut -d: -f1)
round1_default_line=$(awk -v start="$round1_guard_line" 'NR>start && /REVIEW_ROUND=1/ { print NR; exit }' "$WRAPPER")
assert_eq "TC-REVIEW-CONV-027d empty-PR_HEAD_SHA branch defaults REVIEW_ROUND to 1 (strictest floor)" "true" \
  "$([[ -n "$round1_default_line" ]] && echo true || echo false)"

# ===========================================================================
echo
echo "=== TC-REVIEW-CONV-028..038: INV-126 round-cap breaker ==="
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

# TC-REVIEW-CONV-034c: exact-threshold boundary — the round that reaches
# EXACTLY the threshold (not one past it) must trip (the comparison is `-ge`,
# not `-gt`) — the 6-round simulation above only exercises one-past-threshold.
m34c=$(_review_cap_marker 100 deadbeef 4)
assert_eq "TC-REVIEW-CONV-034c next_count==threshold (5==5) trips" "true" \
  "$([[ "$(_review_cap_next_count "$m34c")" -ge "$(_review_cap_threshold 2>/dev/null)" ]] && echo true || echo false)"
# One below the threshold must NOT trip.
m34d=$(_review_cap_marker 100 deadbeef 3)
assert_eq "TC-REVIEW-CONV-034d next_count==threshold-1 (4<5) does not trip" "false" \
  "$([[ "$(_review_cap_next_count "$m34d")" -ge "$(_review_cap_threshold 2>/dev/null)" ]] && echo true || echo false)"

# TC-REVIEW-CONV-034e: an empty/unknown head in the marker (e.g. a transient
# PR_HEAD_SHA read failure upstream) must NOT silently reset this
# head-AGNOSTIC counter — the round field must still parse correctly.
m34e=$(_review_cap_marker 100 "" 3)
assert_contains "TC-REVIEW-CONV-034e empty head renders as 'unknown' placeholder, not an empty field" \
  "$m34e" "head=unknown"
assert_eq "TC-REVIEW-CONV-034f empty-head marker's round still parses and increments" "4" \
  "$(_review_cap_next_count "$m34e")"

# TC-REVIEW-CONV-035: already-stalled skip is enforced at the wrapper call
# site (source grep — mirrors how the pure lib holds no label-state itself).
assert_contains "TC-REVIEW-CONV-035 wrapper checks already-stalled before tripping INV-126" \
  "$(cat "$WRAPPER")" '_rc_already_stalled'

# TC-REVIEW-CONV-036: only fires when AGGREGATE=="fail" — pinned as a wiring
# grep (the breaker must not run on the all-unavailable / crash-without-verdict
# sub-path, which has no severity floor to evaluate).
inv126_block=$(awk '/\[#449\] INV-126/,/emit_verdict_trailer "\$ISSUE_NUMBER" "\$REPO" "failed-substantive"/' "$WRAPPER")
assert_contains "TC-REVIEW-CONV-036 INV-126 block is gated on \$AGGREGATE == \"fail\"" \
  "$inv126_block" '$AGGREGATE" == "fail"'

# TC-REVIEW-CONV-037: failed-non-substantive is out of scope — pinned via the
# same gating (the crash-without-verdict branch, which emits
# failed-non-substantive, sits in the sibling `if` arm, never reaching the
# INV-126 block at all).
crash_branch=$(awk '/AGENT_EXIT -ne 0.*LATEST_COMMENT/,/failed-non-substantive.*other/' "$WRAPPER")
assert_eq "TC-REVIEW-CONV-037 crash-without-verdict (non-substantive) branch has no INV-126 reference" "" \
  "$(grep -o 'INV-126' <<<"$crash_branch")"

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

# ===========================================================================
echo
echo "=== TC-REVIEW-CONV-049..052: artifact-channel severity round-trip (INV-78) ==="
# ===========================================================================

# TC-REVIEW-CONV-049: a schema-conformant artifact FAIL with a severity-tagged
# finding renders that tag inline in the body — closing the gap where the
# PRIMARY documented resolution channel (the JSON artifact, not just codex's
# free-form stdout) fed the severity filter no usable signal at all.
art_json='{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"title":"minor nit","severity":"P3"}],"runId":"abc","agent":"agy"}'
art_body=$(_verdict_body_from_artifact_json "$art_json")
assert_contains "TC-REVIEW-CONV-049a artifact-rendered body carries the [P3] tag" "$art_body" "[P3]"
assert_eq "TC-REVIEW-CONV-049b severity filter extracts P3 from the artifact-rendered body" "P3" \
  "$(_review_extract_highest_severity "$art_body")"
assert_eq "TC-REVIEW-CONV-049c that P3 finding is demoted (non-blocking) at round 5" "pass" \
  "$(_review_apply_severity_filter fail "$art_body" 5)"

# TC-REVIEW-CONV-050: an artifact FAIL with a P1 finding stays blocking at any
# round (regression pin — the artifact channel must not accidentally make
# EVERYTHING non-blocking).
art_json_p1='{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"title":"null deref","severity":"P1"}],"runId":"abc","agent":"agy"}'
art_body_p1=$(_verdict_body_from_artifact_json "$art_json_p1")
assert_eq "TC-REVIEW-CONV-050 artifact P1 finding still blocks at round 5" "fail" \
  "$(_review_apply_severity_filter fail "$art_body_p1" 5)"

# TC-REVIEW-CONV-051: an artifact finding with NO severity field (legacy /
# non-compliant agent) renders untagged and is treated as unscoreable — it
# ALWAYS blocks (fail-safe), matching the pre-#449 unconditional-block
# behavior for every artifact-sourced FAIL.
art_json_untagged='{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"title":"untagged finding"}],"runId":"abc","agent":"agy"}'
art_body_untagged=$(_verdict_body_from_artifact_json "$art_json_untagged")
assert_eq "TC-REVIEW-CONV-051a untagged artifact finding extracts as none" "none" \
  "$(_review_extract_highest_severity "$art_body_untagged")"
assert_eq "TC-REVIEW-CONV-051b untagged artifact finding still blocks at round 5 (fail-safe)" "fail" \
  "$(_review_apply_severity_filter fail "$art_body_untagged" 5)"

# TC-REVIEW-CONV-052: schema accepts the new optional severity enum and
# rejects an invalid value (drift guard — the schema and the prompt/renderer
# must agree on the P0-P3 vocabulary).
if command -v jq >/dev/null 2>&1 && [[ -f "$PROJECT_ROOT/docs/pipeline/schemas/verdict-artifact.schema.json" ]]; then
  assert_contains "TC-REVIEW-CONV-052 schema declares the P0-P3 severity enum on the finding definition" \
    "$(cat "$PROJECT_ROOT/docs/pipeline/schemas/verdict-artifact.schema.json")" '"enum": ["P0", "P1", "P2", "P3"]'
fi

# ===========================================================================
echo
echo "=== TC-REVIEW-CONV-053..059: codex-review [P1] fixes (severity artifact key, marker timing, cap-cutoff resume) ==="
# ===========================================================================

# TC-REVIEW-CONV-053: [P1] #1 — the jq structural fallback must accept the
# OPTIONAL "severity" finding key (P0-P3), not just the INV-92 classification
# fields. Pre-fix, a non-codex agent that followed the new severity prompt
# and wrote "severity" into its artifact was downgraded to malformed by
# additionalProperties:false, losing that agent's vote entirely.
TMP53="$(mktemp -d)"
mk53() { printf '%s' "$2" > "$TMP53/$1.json"; }
mk53 sev-p3 '{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"title":"x","severity":"P3"}],"runId":"r","agent":"a"}'
mk53 sev-bad '{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"title":"x","severity":"P9"}],"runId":"r","agent":"a"}'
assert_eq "TC-REVIEW-CONV-053a jq fallback accepts a finding with a valid severity tag" "valid" \
  "$(_validate_verdict_artifact_jq "$TMP53/sev-p3.json" && echo valid || echo malformed)"
assert_eq "TC-REVIEW-CONV-053b jq fallback rejects an out-of-enum severity value" "malformed" \
  "$(_validate_verdict_artifact_jq "$TMP53/sev-bad.json" && echo valid || echo malformed)"
rm -rf "$TMP53"

# TC-REVIEW-CONV-054..056: [P1] #2 — the review-round-counter marker must be
# posted only AFTER a decided verdict (pass/fail), not unconditionally at
# prompt-render time (pre-fix location, before the E2E gate / smoke gate /
# fan-out have even run) — a crash/no-verdict round on the same head must not
# silently advance the counter that feeds the severity ratchet's floor.
prompt_render_region=$(sed -n '1,1160p' "$WRAPPER")
assert_eq "TC-REVIEW-CONV-054 no unconditional review-round-counter post before the fan-out (prompt-render region)" "" \
  "$(grep -o 'itp_post_comment "\$ISSUE_NUMBER" "\$(_review_round_marker' <<<"$prompt_render_region")"

aggregate_marker_line=$(grep -n 'itp_post_comment "\$ISSUE_NUMBER" "\$(_review_round_marker' "$WRAPPER" | head -1 | cut -d: -f1)
aggregate_compute_line=$(grep -n '^AGGREGATE=\$(_aggregate_review_verdicts' "$WRAPPER" | head -1 | cut -d: -f1)
assert_eq "TC-REVIEW-CONV-055 review-round-counter marker IS posted, but strictly after AGGREGATE is computed" "true" \
  "$([[ -n "$aggregate_marker_line" && -n "$aggregate_compute_line" && "$aggregate_marker_line" -gt "$aggregate_compute_line" ]] && echo true || echo false)"

marker_post_region=$(sed -n "${aggregate_compute_line},$((aggregate_compute_line + 20))p" "$WRAPPER")
assert_contains "TC-REVIEW-CONV-056 the post-aggregation marker post is gated on a DECIDED verdict (pass/fail)" \
  "$marker_post_region" '[[ "$AGGREGATE" == "pass" ]] || [[ "$AGGREGATE" == "fail" ]]'

# TC-REVIEW-CONV-057..059c: [P1] #3 — the INV-126 round-cap series must be
# CUT OFF at the latest trip report so that after an operator removes
# `stalled` to resume, the very next failed-substantive round starts a fresh
# count instead of reading the OLD trip's own marker back and immediately
# re-tripping (mirrors [INV-05]'s "Marking as stalled" cutoff convention).
# These are BEHAVIORAL tests against `_review_cap_prior_marker` (the extracted
# pure function, lib-review-cap.sh) with constructed fixtures — not wiring
# greps — so a mutation on the cutoff comparison (e.g. `>` -> `>=`) or the
# trip-heading regex actually fails a test, not just disappears a substring.

# TC-REVIEW-CONV-057: the crux self-referential case. A trip report at T1
# EMBEDS its own dispatcher-review-cap-breaker marker (round=5) — exactly how
# autonomous-review.sh's ROUNDCAPREPORT heredoc renders it. Without the
# cutoff, the next failed-substantive round would read that T1 marker back
# and immediately re-trip (round=6). With the cutoff, no marker after T1
# qualifies yet, so _review_cap_prior_marker must resolve to "".
FIXTURE_057=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=4 -->"},
  {"authorKind":"bot","createdAt":"2026-01-01T11:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=bbb round=5 -->\n## Review-round-cap circuit-breaker tripped"}
]
JSON
)
assert_eq "TC-REVIEW-CONV-057 trip report's own embedded marker is excluded — no qualifying prior marker right after a trip" "" \
  "$(_review_cap_prior_marker "$FIXTURE_057")"

# TC-REVIEW-CONV-058: a genuinely POST-resume marker (T2 > T1, the trip
# report's timestamp) DOES qualify — resuming after removing `stalled` must
# start a fresh series, not stay permanently excluded.
FIXTURE_058=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=4 -->"},
  {"authorKind":"bot","createdAt":"2026-01-01T11:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=bbb round=5 -->\n## Review-round-cap circuit-breaker tripped"},
  {"authorKind":"bot","createdAt":"2026-01-01T12:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=ccc round=1 -->"}
]
JSON
)
assert_eq "TC-REVIEW-CONV-058a post-resume marker qualifies (strictly after the trip report)" \
  "<!-- dispatcher-review-cap-breaker: issue=1 head=ccc round=1 -->" \
  "$(_review_cap_prior_marker "$FIXTURE_058")"
assert_eq "TC-REVIEW-CONV-058b feeding that marker into _review_cap_next_count continues a FRESH series (2), not a re-trip (6)" "2" \
  "$(_review_cap_next_count "$(_review_cap_prior_marker "$FIXTURE_058")")"

# TC-REVIEW-CONV-059: no trip has ever happened — cutoff is the epoch, every
# marker counts (unchanged pre-fix behavior).
FIXTURE_059=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=3 -->"}
]
JSON
)
assert_eq "TC-REVIEW-CONV-059 no-trip case: cutoff is the epoch, the only marker still qualifies" \
  "<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=3 -->" \
  "$(_review_cap_prior_marker "$FIXTURE_059")"

# TC-REVIEW-CONV-059b: authenticity filter — a human comment quoting either
# the trip heading or the marker fence must never shift the cutoff or be
# read back as a genuine marker.
FIXTURE_059B=$(cat <<'JSON'
[
  {"authorKind":"human","createdAt":"2026-01-01T09:00:00Z","body":"just discussing: ## Review-round-cap circuit-breaker tripped"},
  {"authorKind":"human","createdAt":"2026-01-01T09:30:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=forged round=99 -->"},
  {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=2 -->"}
]
JSON
)
assert_eq "TC-REVIEW-CONV-059b human comments (forged trip-heading quote + forged marker) are ignored; the genuine bot marker wins" \
  "<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=2 -->" \
  "$(_review_cap_prior_marker "$FIXTURE_059B")"

# TC-REVIEW-CONV-059c: a null .body (a real GitHub REST shape) must not crash
# the jq scan (test()/contains() on null is a runtime error, not a
# non-match) — it must be treated as a non-matching row, fail-safe.
FIXTURE_059C=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-01-01T09:00:00Z","body":null},
  {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=1 -->"}
]
JSON
)
assert_eq "TC-REVIEW-CONV-059c a null .body row does not crash the scan and is skipped" \
  "<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=1 -->" \
  "$(_review_cap_prior_marker "$FIXTURE_059C")"

# TC-REVIEW-CONV-059d: wiring pin — the wrapper actually delegates to the
# extracted pure function rather than re-inlining the two-query block.
assert_contains "TC-REVIEW-CONV-059d wrapper calls _review_cap_prior_marker instead of inlining the cutoff-then-scan" \
  "$(cat "$WRAPPER")" '_rc_prior_marker=$(_review_cap_prior_marker "$_rc_comments_json")'

# TC-REVIEW-CONV-060..066: [P1] codex review round 3 — an intervening
# non-`failed-substantive` round (a `Review PASSED` or `failed-non-substantive`
# round) must reset the round-cap series, not merely the trip report. Without
# this, `dispatcher-review-cap-breaker` markers are posted ONLY on
# `failed-substantive` rounds, so the cutoff-then-scan would resume counting
# from the OLDER pre-intervening-round marker on the next substantive fail,
# letting the breaker trip on N total (not N CONSECUTIVE) substantive
# failures. The reset cutoff is the latest `<!-- review-verdict: … -->`
# trailer whose verdict is `passed` or `failed-non-substantive` (never
# `failed-substantive` itself).

# TC-REVIEW-CONV-060: an intervening PASS after a failed-substantive round
# resets the series — no dispatcher-review-cap-breaker marker exists yet
# after the reset (none is posted on a PASS round), so no prior marker
# qualifies.
FIXTURE_060=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=3 -->"},
  {"authorKind":"bot","createdAt":"2026-01-01T11:00:00Z","body":"<!-- review-verdict: passed -->"}
]
JSON
)
assert_eq "TC-REVIEW-CONV-060 an intervening PASS resets the series (no qualifying prior marker)" "" \
  "$(_review_cap_prior_marker "$FIXTURE_060")"
assert_eq "TC-REVIEW-CONV-060b next_count after a PASS-reset restarts at 1, not 4" "1" \
  "$(_review_cap_next_count "$(_review_cap_prior_marker "$FIXTURE_060")")"

# TC-REVIEW-CONV-061: an intervening failed-non-substantive round also resets
# the series (out-of-scope for REVIEW_CONVERGENCE_CAP, but its trailer must
# still act as a reset boundary for the NEXT substantive failure).
FIXTURE_061=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=3 -->"},
  {"authorKind":"bot","createdAt":"2026-01-01T11:00:00Z","body":"<!-- review-verdict: failed-non-substantive cause=other -->"}
]
JSON
)
assert_eq "TC-REVIEW-CONV-061 an intervening failed-non-substantive round resets the series" "" \
  "$(_review_cap_prior_marker "$FIXTURE_061")"

# TC-REVIEW-CONV-062: a failed-substantive verdict trailer must NOT be
# mistaken for a reset (regression pin against the `failed-non-substantive`
# vs `failed-substantive` substring confusion) — the prior marker still
# qualifies and the series still accumulates.
FIXTURE_062=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=3 -->"},
  {"authorKind":"bot","createdAt":"2026-01-01T11:00:00Z","body":"<!-- review-verdict: failed-substantive dev-actionable=false -->"}
]
JSON
)
assert_eq "TC-REVIEW-CONV-062 a failed-substantive trailer is NOT a reset boundary" \
  "<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=3 -->" \
  "$(_review_cap_prior_marker "$FIXTURE_062")"
assert_eq "TC-REVIEW-CONV-062b next_count still accumulates across a failed-substantive trailer" "4" \
  "$(_review_cap_next_count "$(_review_cap_prior_marker "$FIXTURE_062")")"

# TC-REVIEW-CONV-063: a HUMAN-authored `review-verdict: passed` forgery must
# NOT reset the series (mirrors the existing authenticity filter on the
# marker fence itself, TC-059b) — only a genuine bot/App trailer resets.
FIXTURE_063=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=3 -->"},
  {"authorKind":"human","createdAt":"2026-01-01T11:00:00Z","body":"<!-- review-verdict: passed -->"}
]
JSON
)
assert_eq "TC-REVIEW-CONV-063 a human-authored review-verdict:passed forgery does not reset the series" \
  "<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=3 -->" \
  "$(_review_cap_prior_marker "$FIXTURE_063")"

# TC-REVIEW-CONV-064: the reset cutoff and the trip cutoff combine via max()
# — a reset that lands AFTER the most recent trip report still excludes the
# older marker (the later of the two cutoffs governs).
FIXTURE_064=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=4 -->"},
  {"authorKind":"bot","createdAt":"2026-01-01T11:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=bbb round=5 -->\n## Review-round-cap circuit-breaker tripped"},
  {"authorKind":"bot","createdAt":"2026-01-01T12:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=ccc round=1 -->"},
  {"authorKind":"bot","createdAt":"2026-01-01T13:00:00Z","body":"<!-- review-verdict: passed -->"}
]
JSON
)
assert_eq "TC-REVIEW-CONV-064 a reset later than the last trip report also excludes the post-resume marker" "" \
  "$(_review_cap_prior_marker "$FIXTURE_064")"
assert_eq "TC-REVIEW-CONV-064b next_count after the later reset restarts at 1" "1" \
  "$(_review_cap_next_count "$(_review_cap_prior_marker "$FIXTURE_064")")"

# TC-REVIEW-CONV-065: conversely, a reset EARLIER than the last trip report
# is superseded by the trip cutoff — unchanged TC-057/058 behavior.
FIXTURE_065=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-01-01T09:00:00Z","body":"<!-- review-verdict: passed -->"},
  {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=4 -->"},
  {"authorKind":"bot","createdAt":"2026-01-01T11:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=bbb round=5 -->\n## Review-round-cap circuit-breaker tripped"},
  {"authorKind":"bot","createdAt":"2026-01-01T12:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=ccc round=1 -->"}
]
JSON
)
assert_eq "TC-REVIEW-CONV-065 a reset earlier than the last trip is superseded by the trip cutoff" \
  "<!-- dispatcher-review-cap-breaker: issue=1 head=ccc round=1 -->" \
  "$(_review_cap_prior_marker "$FIXTURE_065")"

# TC-REVIEW-CONV-066: the addressed [P1] scenario itself — 5 total
# `failed-substantive` rounds split across TWO series by an intervening PASS
# (3 then reset then 2) must NOT trip the breaker (only 2 consecutive since
# the reset, well under the default threshold of 5).
FIXTURE_066=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=3 -->"},
  {"authorKind":"bot","createdAt":"2026-01-01T11:00:00Z","body":"<!-- review-verdict: passed -->"},
  {"authorKind":"bot","createdAt":"2026-01-01T12:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=bbb round=1 -->"}
]
JSON
)
_066_next=$(_review_cap_next_count "$(_review_cap_prior_marker "$FIXTURE_066")")
assert_eq "TC-REVIEW-CONV-066 the next round after a 3-then-PASS-then-1 progression is 2, not 4 (breaker does not trip against threshold 5)" "2" \
  "$_066_next"

# TC-REVIEW-CONV-067: [CRITICAL, silent-failure-hunter finding on the reset
# fix itself] the reset-cutoff pattern must be FULL-BODY anchored, not a bare
# substring test(). A genuine review agent's own FAIL body can legitimately
# quote or discuss a prior trailer in prose (agents are prompted to read all
# issue comments) — that must NOT be mistaken for a genuine reset boundary.
# Mirrors lib-dispatch.sh's authentic_verdict() round-13/14 fix history (a
# bare startswith/substring match let a human/agent's incidental mention of
# the trailer forge the same class of false signal).
FIXTURE_067=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=3 -->"},
  {"authorKind":"bot","createdAt":"2026-01-01T11:00:00Z","body":"Review findings:\n\n1. [P1] The fix regresses. Note: the earlier <!-- review-verdict: passed --> trailer was wrong.\n\nReview Session: abc123"}
]
JSON
)
assert_eq "TC-REVIEW-CONV-067 a bot FAIL body that embeds a review-verdict trailer substring in prose does NOT reset the series" \
  "<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=3 -->" \
  "$(_review_cap_prior_marker "$FIXTURE_067")"
assert_eq "TC-REVIEW-CONV-067b next_count still accumulates (4), not falsely reset to 1" "4" \
  "$(_review_cap_next_count "$(_review_cap_prior_marker "$FIXTURE_067")")"

# TC-REVIEW-CONV-068: the same embedded-substring risk for the trip-heading
# text itself is already covered by TC-059b (human-authored); this pins the
# BOT-authored analog — a bot FAIL body merely mentioning "circuit-breaker"
# text must not be misread as a trip report if it lacks the exact heading
# AND doesn't carry the marker fence.
FIXTURE_068=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=aaa round=2 -->"},
  {"authorKind":"bot","createdAt":"2026-01-01T11:00:00Z","body":"Review findings:\n\n1. [P1] Unrelated to any circuit-breaker tripping logic.\n\nReview Session: xyz789"},
  {"authorKind":"bot","createdAt":"2026-01-01T12:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=1 head=bbb round=3 -->"}
]
JSON
)
assert_eq "TC-REVIEW-CONV-068 a bot FAIL body mentioning circuit-breaker in passing is not misread as a trip report" \
  "<!-- dispatcher-review-cap-breaker: issue=1 head=bbb round=3 -->" \
  "$(_review_cap_prior_marker "$FIXTURE_068")"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
