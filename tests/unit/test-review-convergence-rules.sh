#!/bin/bash
# test-review-convergence-rules.sh — issue #449.
#
# Pins the pure decision-logic helpers added for the severity-aware blocking
# ratchet (R1: lib-review-severity.sh + lib-review-round.sh), the INV-127
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
echo "=== TC-REVIEW-CONV-021..027: review-round-counter marker (head-agnostic, INV-129) ==="
# ===========================================================================

assert_eq "TC-REVIEW-CONV-021 fresh issue, no prior marker → round=1" "1" \
  "$(_review_round_next_count "")"

m22=$(_review_round_marker 100 deadbeef 1)
assert_eq "TC-REVIEW-CONV-022 same-head marker increments" "2" \
  "$(_review_round_next_count "$m22")"

# TC-REVIEW-CONV-023 [INV-129]: a DIFFERENT head no longer resets the
# counter — it is now head-AGNOSTIC. Regression pin for the OLD (#449-era)
# head-scoped behavior's ABSENCE: pre-#475 this would have echoed 1.
m23=$(_review_round_marker 100 deadbeef 3)
assert_eq "TC-REVIEW-CONV-023 [INV-129] new head does NOT reset — still increments (head is forensic-only)" "4" \
  "$(_review_round_next_count "$m23")"

assert_eq "TC-REVIEW-CONV-024a malformed marker parses to round=0" "0" \
  "$(_review_round_parse_count "not a marker at all {{{")"
assert_eq "TC-REVIEW-CONV-024b malformed marker → next round=1 (no crash)" "1" \
  "$(_review_round_next_count "<!-- review-round-counter: garbage -->")"

# TC-REVIEW-CONV-025/026: authenticity filter is enforced at the WRAPPER call
# site (jq `select(.authorKind != "human")`), mirrored here as a source grep
# (the pure marker helpers themselves are author-agnostic by design — the
# filtering happens on the comment SCAN before the marker text ever reaches
# them, exactly like INV-105/INV-122).
assert_contains "TC-REVIEW-CONV-025/026 wrapper reads the round-counter via _review_round_prior_marker (authorKind filter lives inside it)" \
  "$(cat "$WRAPPER")" '_review_round_prior_marker'

m27=$(_review_round_marker 100 deadbeef 3)
assert_eq "TC-REVIEW-CONV-027a marker round-trip contains issue" "true" \
  "$([[ "$m27" == *"issue=100"* ]] && echo true || echo false)"
assert_eq "TC-REVIEW-CONV-027b marker round-trip: parse returns the same round" "3" \
  "$(_review_round_parse_count "$m27")"

# TC-REVIEW-CONV-027c/d [INV-129, issue #475]: the pre-#475 wrapper-level
# empty-PR_HEAD_SHA guard (defaulting REVIEW_ROUND=1 and skipping the marker
# post) is REMOVED — that guard existed solely to prevent head-KEY
# contamination, which no longer applies now that the head is forensic-only.
assert_eq "TC-REVIEW-CONV-027c [INV-129] wrapper no longer special-cases an empty PR_HEAD_SHA for the round counter" "" \
  "$(grep -o 'PR_HEAD_SHA is empty (chp_pr_view failure?) — defaulting review round to 1' "$WRAPPER")"

# TC-REVIEW-CONV-027e [INV-129]: a null .body (a real GitHub REST shape) must
# not crash `_review_round_prior_marker`'s jq scan — now covered by a
# BEHAVIORAL fixture test (TC-INV129-029, Group E below) rather than a wiring
# grep, since the read moved from an inline jq one-liner into a pure
# fixture-testable function.

# ===========================================================================
echo
echo "=== TC-REVIEW-CONV-028..038: INV-127 round-cap breaker ==="
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
assert_contains "TC-REVIEW-CONV-035 wrapper checks already-stalled before tripping INV-127" \
  "$(cat "$WRAPPER")" '_rc_already_stalled'

# TC-REVIEW-CONV-035b/c/d [P1 fix, review round 5]: the already-stalled check
# must short-circuit the ENTIRE substantive-FAIL routing (an `exit 0`
# immediately after the check), not merely skip the trip-report branch and
# fall through to the ordinary FAIL routing — the pre-fix shape would let an
# already-stalled issue get a COMPETING `pending-dev` transition from THIS
# breaker's own normal-FAIL fall-through, clobbering a sibling breaker's
# (INV-105/INV-122) stall.
already_stalled_block=$(awk '/_rc_already_stalled=\$\(itp_read_task/,/_rc_comments_json=\$\(itp_list_comments/' "$WRAPPER")
# The `if` guard's own executable BODY only (excludes the doc comment above
# it, which legitimately mentions pending-dev in prose while explaining the
# bug being fixed) — from the `if` line through its matching `fi`.
already_stalled_if_body=$(awk '/if \[\[ "\$_rc_already_stalled" == "true" \]\]/{f=1} f{print} f && /^      fi$/{exit}' "$WRAPPER")
assert_contains "TC-REVIEW-CONV-035b the already-stalled branch exits immediately (exit 0)" \
  "$already_stalled_if_body" 'exit 0'
assert_contains "TC-REVIEW-CONV-035c the already-stalled branch sets RESULT_PARSED=true before exiting" \
  "$already_stalled_if_body" 'RESULT_PARSED=true'
# The counter read (`_rc_comments_json=$(itp_list_comments ...)`, the first
# statement of the round-cap-counter logic) must appear STRICTLY AFTER the
# already-stalled check's own `if` guard — i.e. the short-circuit runs BEFORE
# any counter read/persist, not after. Pinned via line-number ordering
# (mirrors TC-038's own transition-precedes-report ordering pin).
already_stalled_if_line=$(grep -n 'if \[\[ "\$_rc_already_stalled" == "true" \]\]' "$WRAPPER" | head -1 | cut -d: -f1)
counter_read_line=$(grep -n '_rc_comments_json=\$(itp_list_comments' "$WRAPPER" | head -1 | cut -d: -f1)
if [[ -n "$already_stalled_if_line" && -n "$counter_read_line" && "$already_stalled_if_line" -lt "$counter_read_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-REVIEW-CONV-035d already-stalled check (line $already_stalled_if_line) precedes the round-cap counter read (line $counter_read_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-CONV-035d already-stalled check must precede the round-cap counter read"
  echo "      already_stalled_if_line=$already_stalled_if_line counter_read_line=$counter_read_line"
  FAIL=$((FAIL + 1))
fi
# The already-stalled branch's EXECUTABLE body itself must NOT contain a
# pending-dev transition call (the bug this fix closes: falling through to
# the ordinary FAIL routing's unconditional pending-dev flip, clobbering a
# sibling breaker's stall). Checked against the `if`-body-only slice above so
# a legitimate prose mention of "pending-dev" in the preceding doc comment
# (explaining the bug) doesn't produce a false failure.
assert_eq "TC-REVIEW-CONV-035e already-stalled branch's executable body contains no pending-dev transition call" "" \
  "$(grep -o 'itp_transition_state.*pending-dev' <<<"$already_stalled_if_body")"

# TC-REVIEW-CONV-036: only fires when AGGREGATE=="fail" — pinned as a wiring
# grep (the breaker must not run on the all-unavailable / crash-without-verdict
# sub-path, which has no severity floor to evaluate).
inv127_block=$(awk '/\[#449\] INV-127/,/emit_verdict_trailer "\$ISSUE_NUMBER" "\$REPO" "failed-substantive"/' "$WRAPPER")
assert_contains "TC-REVIEW-CONV-036 INV-127 block is gated on \$AGGREGATE == \"fail\"" \
  "$inv127_block" '$AGGREGATE" == "fail"'

# TC-REVIEW-CONV-037: failed-non-substantive is out of scope — pinned via the
# same gating (the crash-without-verdict branch, which emits
# failed-non-substantive, sits in the sibling `if` arm, never reaching the
# INV-127 block at all).
crash_branch=$(awk '/AGENT_EXIT -ne 0.*LATEST_COMMENT/,/failed-non-substantive.*other/' "$WRAPPER")
assert_eq "TC-REVIEW-CONV-037 crash-without-verdict (non-substantive) branch has no INV-127 reference" "" \
  "$(grep -o 'INV-127' <<<"$crash_branch")"

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

# TC-REVIEW-CONV-048e..h: _aggregate_has_substantive_fail — the narrower
# distinction R1's round counter and INV-127's cap need: did any agent
# actually SCORE a blocking finding, vs. an all-timeout `fail` with no
# findings text at all (codex review round 4 [P1] #1/#2).
assert_eq "TC-REVIEW-CONV-048e all timed-out → no substantive fail" "false" \
  "$(_aggregate_has_substantive_fail timed-out timed-out)"
assert_eq "TC-REVIEW-CONV-048f a genuine fail present → substantive" "true" \
  "$(_aggregate_has_substantive_fail timed-out fail)"
assert_eq "TC-REVIEW-CONV-048g all pass/unavailable → no substantive fail" "false" \
  "$(_aggregate_has_substantive_fail pass unavailable)"
assert_eq "TC-REVIEW-CONV-048h single genuine fail → substantive" "true" \
  "$(_aggregate_has_substantive_fail fail)"

# TC-REVIEW-CONV-048i/j: wiring pins — both the review-round-counter marker
# post and the INV-127 cap block must consult
# `_AGGREGATE_SUBSTANTIVE_FAIL`/`_aggregate_has_substantive_fail` alongside
# `$AGGREGATE == "fail"`, not the bare aggregate alone.
round_marker_gate_region=$(sed -n "${aggregate_call_line},$((aggregate_call_line + 25))p" "$WRAPPER")
assert_contains "TC-REVIEW-CONV-048i review-round-counter marker gate consults substantive-fail" \
  "$round_marker_gate_region" '_AGGREGATE_SUBSTANTIVE_FAIL'
inv127_gate_line=$(grep -n '^    if \[\[ "\$AGGREGATE" == "fail" \]\]' "$WRAPPER" | head -1 | cut -d: -f1)
assert_eq "TC-REVIEW-CONV-048j INV-127 cap gate ALSO consults substantive-fail" "true" \
  "$([[ -n "$inv127_gate_line" ]] && grep -q '_AGGREGATE_SUBSTANTIVE_FAIL' <<<"$(sed -n "${inv127_gate_line}p" "$WRAPPER")" && echo true || echo false)"

# TC-REVIEW-CONV-036b..e [P1, #449 codex review round 7]:
# _aggregate_has_p0p1_fail — the narrower distinction ONLY INV-127's cap
# needs (not R1's round-counter marker gate): did the surviving fail's
# severity actually reach the ratchet's terminal P0/P1 floor, vs. merely
# surviving at THIS round's possibly-looser floor (a P2 blocks at rounds
# 1-4). Takes alternating (verdict, severity) pairs.
assert_eq "TC-REVIEW-CONV-036b a fail+P2 pair only → false (P2 never counts as terminal-floor evidence)" "false" \
  "$(_aggregate_has_p0p1_fail fail P2)"
assert_eq "TC-REVIEW-CONV-036c a fail+P0 pair → true" "true" \
  "$(_aggregate_has_p0p1_fail fail P0)"
assert_eq "TC-REVIEW-CONV-036d a fail+P1 pair → true" "true" \
  "$(_aggregate_has_p0p1_fail fail P1)"
assert_eq "TC-REVIEW-CONV-036e a fail+none pair → true (untagged/unrecognized is fail-safe, always counts)" "true" \
  "$(_aggregate_has_p0p1_fail fail none)"
assert_eq "TC-REVIEW-CONV-036e2 a fail+P3 pair → false" "false" \
  "$(_aggregate_has_p0p1_fail fail P3)"
assert_eq "TC-REVIEW-CONV-036e3 a pass+P0 pair (non-fail verdict) → false (severity is irrelevant unless the verdict is fail)" "false" \
  "$(_aggregate_has_p0p1_fail pass P0)"
assert_eq "TC-REVIEW-CONV-036e4 multiple agents: one fail+P2, one fail+P1 → true (any qualifying pair wins)" "true" \
  "$(_aggregate_has_p0p1_fail fail P2 fail P1)"
assert_eq "TC-REVIEW-CONV-036e5 multiple agents, all fail+P2/P3 → false" "false" \
  "$(_aggregate_has_p0p1_fail fail P2 fail P3)"
assert_eq "TC-REVIEW-CONV-036e6 no pairs at all → false" "false" \
  "$(_aggregate_has_p0p1_fail)"

# TC-REVIEW-CONV-036f/g: single-round pins for the two poles of the actual
# motivating scenario — a run of new-HEAD rounds where R1's head-scoped
# review-round-counter resets to 1 every round, so each round re-enters the
# round 1-4 floor (P0-P2 all block) even though INV-127's own counter
# (head-AGNOSTIC) keeps accumulating across those rounds. Each assertion
# below is one round's `_aggregate_has_p0p1_fail` result in isolation (the
# function is pure/stateless — it does not itself simulate the multi-round
# accumulation; that is exercised separately by the existing TC-034
# progression against `_review_cap_next_count`). A P2-only round must
# contribute `false` (never terminal-floor evidence); a P1 round must
# contribute `true`.
assert_eq "TC-REVIEW-CONV-036f a single P2-only round → false (never terminal-floor evidence, regardless of how many such rounds accumulate)" "false" \
  "$(_aggregate_has_p0p1_fail fail P2)"
assert_eq "TC-REVIEW-CONV-036g a single P1 round → true (terminal-floor evidence, even amid an otherwise P2-only progression)" "true" \
  "$(_aggregate_has_p0p1_fail fail P1)"

# TC-REVIEW-CONV-036j [silent-failure-hunter finding, #449 codex review
# round 7]: drift guard between `_aggregate_has_p0p1_fail`'s hardcoded
# severity case arms and `shouldBlockFinding`'s own round>=5 case arms
# (lib-review-severity.sh). The former deliberately DUPLICATES the latter's
# logic rather than sourcing it (see this file's own doc comment), so
# nothing forces the two to stay in sync if the severity vocabulary ever
# changes (e.g. a future tier added between P1 and P2, or a currently-P2-like
# tag reclassified as always-blocking). A silent divergence here would let
# INV-127's cap gate read `_AGGREGATE_HAS_P0P1_FAIL=false` for a finding that
# `shouldBlockFinding` itself treats as terminal-floor-blocking — exactly
# the failure mode this PR's fix closes, reintroduced via maintenance drift
# rather than a runtime bug. Iterate the full known vocabulary and assert
# agreement at round 5 (the terminal floor: only P0/P1 block).
for _sev in P0 P1 P2 P3 none GARBAGE ""; do
  _sbf_blocks=$(shouldBlockFinding 5 "$_sev" && echo true || echo false)
  _p0p1_result=$(_aggregate_has_p0p1_fail fail "$_sev")
  assert_eq "TC-REVIEW-CONV-036j severity='${_sev}': _aggregate_has_p0p1_fail (${_p0p1_result}) agrees with shouldBlockFinding-at-round-5 (${_sbf_blocks})" \
    "$_sbf_blocks" "$_p0p1_result"
done

# TC-REVIEW-CONV-036h: wiring pin — the INV-127 cap gate must ALSO consult
# `_AGGREGATE_HAS_P0P1_FAIL` (the round-counter marker gate deliberately does
# NOT — it feeds "how many rounds have run", not "is the terminal floor
# failing", so `_AGGREGATE_SUBSTANTIVE_FAIL` alone remains correct there;
# TC-048i's earlier pin confirms the marker gate region only, not this one).
inv127_gate_block=$(awk '/^    if \[\[ "\$AGGREGATE" == "fail" \]\]/{f=1} f{print} f && /then$/{exit}' "$WRAPPER")
assert_contains "TC-REVIEW-CONV-036h INV-127 cap gate ALSO consults _AGGREGATE_HAS_P0P1_FAIL" \
  "$inv127_gate_block" '_AGGREGATE_HAS_P0P1_FAIL'
assert_eq "TC-REVIEW-CONV-036i the round-counter marker gate region does NOT reference _AGGREGATE_HAS_P0P1_FAIL (deliberately unchanged)" "" \
  "$(grep -o '_AGGREGATE_HAS_P0P1_FAIL' <<<"$round_marker_gate_region")"

# TC-REVIEW-CONV-048k..n [P1 fix, review round 5]: a severity-ratchet
# demotion must re-post the corrected body even on the COMMENT-ONLY path
# (`_any_deciding_artifact == false`) — previously the aggregate-verdict
# comment post was gated SOLELY on `_any_deciding_artifact`, so a demotion
# with no artifact-sourced agent computed a corrected body but never posted
# it, leaving the agent's stale, still-"[BLOCKING]" comment as the only
# visible verdict.
assert_contains "TC-REVIEW-CONV-048k wrapper tracks _any_severity_demotion" \
  "$(cat "$WRAPPER")" '_any_severity_demotion'
# The flag must be set to true exactly where a fail->pass demotion happens —
# same guard the log line already uses (`_pre_filter_verdict == fail &&
# AGENT_VERDICTS[$_i] == pass`), so the set can't be reached for a non-demoted
# agent. Terminator is the branch's own closing `fi` (2-space indent, matching
# the `if` line's own 2-space indent) — NOT `\$` (a literal backslash-dollar
# inside a single-quoted awk regex, matching nothing), which would let the
# slice run unbounded to EOF and silently stop enforcing "inside the branch."
demotion_set_region=$(awk '/"\$_pre_filter_verdict" == "fail" && "\$\{AGENT_VERDICTS\[\$_i\]\}" == "pass"/{f=1} f{print; if (/^  fi$/) exit}' "$WRAPPER")
assert_contains "TC-REVIEW-CONV-048l _any_severity_demotion is set true inside the demotion branch" \
  "$demotion_set_region" '_any_severity_demotion=true'
# Positive bound check: the slice must actually terminate at the branch's own
# `fi`, not leak to EOF (which would silently defeat the "inside the branch"
# scoping this pin claims to enforce).
assert_eq "TC-REVIEW-CONV-048l2 the demotion-branch slice is bounded (does not leak to end of file)" "true" \
  "$([[ "$(wc -l <<<"$demotion_set_region")" -lt 50 ]] && echo true || echo false)"
# The aggregate-verdict-comment post gate must OR-in `_any_severity_demotion`
# alongside `_any_deciding_artifact` (never AND-only, which would still miss
# the comment-only + demotion case this fix targets) — anchored on `==` so it
# cannot false-match the sibling `!=`-guarded skip condition below.
agg_post_gate_line=$(grep -n '_any_deciding_artifact" == "true".*||.*_any_severity_demotion" == "true"' "$WRAPPER" | head -1)
assert_contains "TC-REVIEW-CONV-048m aggregate-post gate ORs _any_deciding_artifact with _any_severity_demotion" \
  "$agg_post_gate_line" '||'
# The sibling INV-48 standalone timeout-veto post must ALSO skip when a
# demotion occurred (else a round with both a timeout veto and a demotion
# would post the timeout finding twice: once standalone, once folded into
# the now-also-firing aggregate comment). Anchored on `!=` (the skip
# condition), distinct from the `==` OR-gate pinned above.
timeout_standalone_gate_line=$(grep -n '_any_deciding_artifact" != "true".*_any_severity_demotion" != "true"' "$WRAPPER" | head -1)
assert_contains "TC-REVIEW-CONV-048n INV-48 standalone timeout post also skips on a severity demotion (no double-post)" \
  "$timeout_standalone_gate_line" '_any_severity_demotion'

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

# TC-REVIEW-CONV-054..056: [P1] #2 — the review-round-counter marker that
# ADVANCES the round (posts the live `$REVIEW_ROUND` value) must be posted
# only AFTER a decided verdict (pass/fail), not unconditionally at
# prompt-render time (pre-fix location, before the E2E gate / smoke gate /
# fan-out have even run) — a crash/no-verdict round on the same head must not
# silently advance the counter that feeds the severity ratchet's floor.
#
# [INV-129, issue #475 codex review round-1 [P3]] Several EARLIER exit paths
# (no-pr-found, smoke-config-error, …) now ALSO call `_review_round_marker`
# — but always with the literal RESET value `0`, never `$REVIEW_ROUND`. A
# `round=0` post can only ever narrow the series back to its safest state
# (next read = 1); it can never advance/inflate the round, so posting it
# early is safe and does not reintroduce the bug TC-REVIEW-CONV-054/055
# originally guarded against. These assertions were narrowed from "no
# `_review_round_marker` call at all" to "no call carrying `$REVIEW_ROUND`
# (the only value that can advance the series)" to keep pinning the actual
# invariant.
prompt_render_region=$(sed -n '1,1160p' "$WRAPPER")
assert_eq "TC-REVIEW-CONV-054 no unconditional review-round-counter ADVANCE post before the fan-out (prompt-render region)" "" \
  "$(grep -o 'itp_post_comment "\$ISSUE_NUMBER" "\$(_review_round_marker "\$ISSUE_NUMBER" "\$PR_HEAD_SHA" "\$REVIEW_ROUND"' <<<"$prompt_render_region")"

aggregate_marker_line=$(grep -n '_review_round_marker "\$ISSUE_NUMBER" "\$PR_HEAD_SHA" "\$REVIEW_ROUND"' "$WRAPPER" | head -1 | cut -d: -f1)
aggregate_compute_line=$(grep -n '^AGGREGATE=\$(_aggregate_review_verdicts' "$WRAPPER" | head -1 | cut -d: -f1)
assert_eq "TC-REVIEW-CONV-055 review-round-counter ADVANCE marker IS posted, but strictly after AGGREGATE is computed" "true" \
  "$([[ -n "$aggregate_marker_line" && -n "$aggregate_compute_line" && "$aggregate_marker_line" -gt "$aggregate_compute_line" ]] && echo true || echo false)"

marker_post_region=$(sed -n "${aggregate_compute_line},$((aggregate_marker_line + 1))p" "$WRAPPER")
assert_contains "TC-REVIEW-CONV-056 the post-aggregation ADVANCE marker post is gated on a DECIDED verdict (pass/fail)" \
  "$marker_post_region" '[[ "$AGGREGATE" == "pass" ]]'
assert_contains "TC-REVIEW-CONV-056b the marker post's fail arm also requires substantive fail (codex round 4 [P1] #1)" \
  "$marker_post_region" '[[ "$AGGREGATE" == "fail" ]] && [[ "$_AGGREGATE_SUBSTANTIVE_FAIL" == "true" ]]'

# TC-REVIEW-CONV-057..059c: [P1] #3 — the INV-127 round-cap series must be
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

# ===========================================================================
echo
echo "=== TC-INV129-001..036: head-agnostic review-round counter (issue #475) ==="
# ===========================================================================
# See docs/test-cases/inv-129-head-agnostic-review-round.md for the full
# scenario matrix. Pins the redefinition of REVIEW_ROUND from an
# (issue, head)-scoped counter reset on every push to a head-agnostic series
# of consecutive decided failed-substantive rounds.

# --- Group A: head-agnostic parse/next (no <head> param) ---

# TC-INV129-001: new-head-every-round series increments 1→2→3 — the exact
# scenario the OLD head-scoped semantics froze at 1.
_i129_marker=""
_i129_heads=(head1 head2 head3)
_i129_round=0
for _h in "${_i129_heads[@]}"; do
  _i129_round=$(_review_round_next_count "$_i129_marker")
  _i129_marker=$(_review_round_marker 200 "$_h" "$_i129_round")
done
assert_eq "TC-INV129-001 new-head-every-round series increments 1→2→3 (regression pin: old semantics froze at 1)" "3" "$_i129_round"

# TC-INV129-002: same-head consecutive fails still increment (superset of
# the old by-design behavior).
_i129_m1=$(_review_round_marker 200 samehead 1)
assert_eq "TC-INV129-002 same-head consecutive fails still increment" "2" \
  "$(_review_round_next_count "$_i129_m1")"

# TC-INV129-003/004: signatures are single-arg now (a stray second arg is
# silently ignored by bash positional-arg semantics, so this is pinned as a
# source grep on the function definitions instead of a runtime behavior
# difference).
assert_contains "TC-INV129-003 _review_round_next_count signature is single-arg" \
  "$(grep -A1 '^_review_round_next_count()' "$ROUND_LIB")" 'local marker_text="$1" stored'
assert_contains "TC-INV129-004 _review_round_parse_count signature is single-arg" \
  "$(grep -A1 '^_review_round_parse_count()' "$ROUND_LIB")" 'local marker_text="$1"'

# TC-INV129-005: a legacy head-KEYED marker (as pre-#475 code would have
# posted, with a real head value) still parses under the new permissive
# head=.* regex.
_i129_legacy=$(_review_round_marker 200 abc123def 4)
assert_eq "TC-INV129-005 legacy head-keyed marker parses head-agnostically" "4" \
  "$(_review_round_parse_count "$_i129_legacy")"

# TC-INV129-006: malformed marker → round=0, next=1, no crash (unchanged
# bias-to-MISS contract).
assert_eq "TC-INV129-006 malformed marker parses to round=0 (bias to MISS)" "0" \
  "$(_review_round_parse_count "garbage, not a marker")"

# TC-INV129-007/008: empty head renders as the "unknown" placeholder and its
# round field still parses/increments.
_i129_unknown=$(_review_round_marker 200 "" 3)
assert_contains "TC-INV129-007 empty head renders as 'unknown' placeholder" \
  "$_i129_unknown" "head=unknown"
assert_eq "TC-INV129-008 empty-head marker's round still parses and increments" "4" \
  "$(_review_round_next_count "$_i129_unknown")"

# --- Group B: reset channel 1 — passed/failed-non-substantive trailer cutoff ---

FIXTURE_I129_009=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-02-01T10:00:00Z","body":"<!-- review-round-counter: issue=200 head=aaa round=3 -->"},
  {"authorKind":"bot","createdAt":"2026-02-01T11:00:00Z","body":"<!-- review-verdict: passed -->"}
]
JSON
)
assert_eq "TC-INV129-009 a passed trailer resets the series (no qualifying prior marker)" "" \
  "$(_review_round_prior_marker "$FIXTURE_I129_009")"
assert_eq "TC-INV129-010 next_count after a passed-trailer reset restarts at 1" "1" \
  "$(_review_round_next_count "$(_review_round_prior_marker "$FIXTURE_I129_009")")"

FIXTURE_I129_011=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-02-01T10:00:00Z","body":"<!-- review-round-counter: issue=200 head=aaa round=3 -->"},
  {"authorKind":"bot","createdAt":"2026-02-01T11:00:00Z","body":"<!-- review-verdict: failed-non-substantive cause=other -->"}
]
JSON
)
assert_eq "TC-INV129-011 a failed-non-substantive trailer also resets the series" "" \
  "$(_review_round_prior_marker "$FIXTURE_I129_011")"

FIXTURE_I129_012=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-02-01T10:00:00Z","body":"<!-- review-round-counter: issue=200 head=aaa round=3 -->"},
  {"authorKind":"human","createdAt":"2026-02-01T11:00:00Z","body":"<!-- review-verdict: passed -->"}
]
JSON
)
assert_eq "TC-INV129-012 a HUMAN-forged passed trailer does NOT reset the series" \
  "<!-- review-round-counter: issue=200 head=aaa round=3 -->" \
  "$(_review_round_prior_marker "$FIXTURE_I129_012")"

FIXTURE_I129_013=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-02-01T10:00:00Z","body":"<!-- review-round-counter: issue=200 head=aaa round=3 -->"},
  {"authorKind":"bot","createdAt":"2026-02-01T11:00:00Z","body":"Review findings:\n\n1. [P1] the earlier `<!-- review-verdict: passed -->` trailer turned out to be wrong.\n\nReview Session: abc"}
]
JSON
)
assert_eq "TC-INV129-013 a bot FAIL body merely quoting a passed trailer in prose does NOT reset (full-body anchor)" \
  "<!-- review-round-counter: issue=200 head=aaa round=3 -->" \
  "$(_review_round_prior_marker "$FIXTURE_I129_013")"

FIXTURE_I129_014=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-02-01T10:00:00Z","body":"<!-- review-round-counter: issue=200 head=aaa round=3 -->"},
  {"authorKind":"bot","createdAt":"2026-02-01T11:00:00Z","body":"<!-- review-verdict: failed-substantive -->"}
]
JSON
)
assert_eq "TC-INV129-014 a failed-substantive trailer is NOT a reset boundary" \
  "<!-- review-round-counter: issue=200 head=aaa round=3 -->" \
  "$(_review_round_prior_marker "$FIXTURE_I129_014")"

# --- Group C: reset channel 2 — INV-127 trip report cutoff ---

FIXTURE_I129_015=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-02-01T10:00:00Z","body":"<!-- review-round-counter: issue=200 head=aaa round=4 -->"},
  {"authorKind":"bot","createdAt":"2026-02-01T11:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=200 head=aaa round=5 -->\n## Review-round-cap circuit-breaker tripped — halting repeated re-dispatch"}
]
JSON
)
assert_eq "TC-INV129-015 an INV-127 trip report is itself a reset cutoff" "" \
  "$(_review_round_prior_marker "$FIXTURE_I129_015")"

FIXTURE_I129_016=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-02-01T10:00:00Z","body":"<!-- review-round-counter: issue=200 head=aaa round=3 -->"},
  {"authorKind":"bot","createdAt":"2026-02-01T11:00:00Z","body":"## Non-convergence circuit-breaker tripped — dev-side zero-commit inaction"}
]
JSON
)
assert_eq "TC-INV129-016 an INV-105-style (non-convergence) trip report is NOT a reset cutoff — the marker still qualifies" \
  "<!-- review-round-counter: issue=200 head=aaa round=3 -->" \
  "$(_review_round_prior_marker "$FIXTURE_I129_016")"

FIXTURE_I129_017=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-02-01T10:00:00Z","body":"<!-- review-round-counter: issue=200 head=aaa round=3 -->"},
  {"authorKind":"bot","createdAt":"2026-02-01T11:00:00Z","body":"## Same-HEAD gate-failure circuit-breaker tripped — halting repeated re-dispatch"}
]
JSON
)
assert_eq "TC-INV129-017 an INV-122-style (same-head gate-failure) trip report is NOT a reset cutoff either" \
  "<!-- review-round-counter: issue=200 head=aaa round=3 -->" \
  "$(_review_round_prior_marker "$FIXTURE_I129_017")"

FIXTURE_I129_018=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-02-01T10:00:00Z","body":"<!-- dispatcher-review-cap-breaker: issue=200 head=aaa round=5 -->\n## Review-round-cap circuit-breaker tripped — halting repeated re-dispatch"},
  {"authorKind":"bot","createdAt":"2026-02-01T12:00:00Z","body":"<!-- review-round-counter: issue=200 head=bbb round=1 -->"}
]
JSON
)
assert_eq "TC-INV129-018 a genuine marker AFTER an INV-127 trip report qualifies" \
  "<!-- review-round-counter: issue=200 head=bbb round=1 -->" \
  "$(_review_round_prior_marker "$FIXTURE_I129_018")"

# --- Group D: reset channel 3 — explicit round=0 marker ---

assert_contains "TC-INV129-019 a pass aggregate posts round=0 (wiring grep)" \
  "$(cat "$WRAPPER")" '_review_round_marker "$ISSUE_NUMBER" "$PR_HEAD_SHA" 0'

assert_contains "TC-INV129-020 a substantive fail posts the incremented round (unchanged)" \
  "$(cat "$WRAPPER")" '_review_round_marker "$ISSUE_NUMBER" "$PR_HEAD_SHA" "$REVIEW_ROUND"'

# TC-INV129-037..043 (codex review round-1 [P3]): EVERY failed-non-substantive
# exit path must ALSO post its own round=0 marker — the trailer-cutoff channel
# (channel 1, `_review_round_prior_marker`) is not enough on its own because
# `emit_verdict_trailer`'s own itp_post_comment carries `|| true` and can
# silently fail, letting a later failed-substantive round inherit a stale
# high count. Pinned as a wiring grep: for each failed-non-substantive cause
# token's emit_verdict_trailer call site, a `_review_round_marker ... 0)`
# post must appear within the next 10 source lines.
declare -A _I129_NONSUB_CAUSES=(
  [no-pr-found]=1
  [e2e-evidence-missing]=1
  [smoke-config-error]=1
  [awaiting-bot-review]=1
  [mergeable-unknown]=1
  [merge-conflict-unresolvable]=1
  [other]=1
)
for _cause in "${!_I129_NONSUB_CAUSES[@]}"; do
  _cause_line=$(grep -n "emit_verdict_trailer \"\$ISSUE_NUMBER\" \"\$REPO\" \"failed-non-substantive\" \"${_cause}\"" "$WRAPPER" | head -1 | cut -d: -f1)
  if [[ -z "$_cause_line" ]]; then
    echo -e "  ${RED}FAIL${NC}: TC-INV129-037..043 could not locate emit_verdict_trailer call site for cause=${_cause}"
    FAIL=$((FAIL + 1))
    continue
  fi
  _cause_block=$(sed -n "${_cause_line},$((_cause_line + 10))p" "$WRAPPER")
  assert_contains "TC-INV129-037..043 cause=${_cause} also posts a round=0 reset marker within 10 lines" \
    "$_cause_block" '_review_round_marker "$ISSUE_NUMBER"'
  assert_contains "TC-INV129-037..043 cause=${_cause} round=0 marker literal" \
    "$_cause_block" ' 0)" 2>/dev/null || true'
done

_i129_round0=$(_review_round_marker 200 aaa 0)
assert_eq "TC-INV129-021 _review_round_next_count fed a round=0 marker directly returns 1" "1" \
  "$(_review_round_next_count "$_i129_round0")"

FIXTURE_I129_022=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-02-01T10:00:00Z","body":"<!-- review-round-counter: issue=200 head=aaa round=4 -->"},
  {"authorKind":"bot","createdAt":"2026-02-01T11:00:00Z","body":"<!-- review-round-counter: issue=200 head=bbb round=0 -->"}
]
JSON
)
assert_eq "TC-INV129-022 round=0 marker resets even with NO qualifying trailer present at all (dual-channel)" \
  "<!-- review-round-counter: issue=200 head=bbb round=0 -->" \
  "$(_review_round_prior_marker "$FIXTURE_I129_022")"
assert_eq "TC-INV129-022b next_count after that round=0 marker is 1" "1" \
  "$(_review_round_next_count "$(_review_round_prior_marker "$FIXTURE_I129_022")")"

FIXTURE_I129_023=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-02-01T10:00:00Z","body":"<!-- review-round-counter: issue=200 head=aaa round=0 -->"},
  {"authorKind":"bot","createdAt":"2026-02-01T11:00:00Z","body":"<!-- review-round-counter: issue=200 head=bbb round=2 -->"}
]
JSON
)
assert_eq "TC-INV129-023 a later genuine marker after a round=0 reset wins (latest-qualifying-marker semantics)" \
  "<!-- review-round-counter: issue=200 head=bbb round=2 -->" \
  "$(_review_round_prior_marker "$FIXTURE_I129_023")"

# --- Group E: read-site wiring — full-body anchor + empty-head handling ---

assert_eq "TC-INV129-024 a marker-shaped substring embedded in a larger comment is rejected" "" \
  "$(_review_round_prior_marker "$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-02-01T10:00:00Z","body":"discussing <!-- review-round-counter: issue=200 head=aaa round=9 --> in prose"}
]
JSON
)")"

assert_eq "TC-INV129-025 a genuine standalone marker comment is accepted" \
  "<!-- review-round-counter: issue=200 head=aaa round=2 -->" \
  "$(_review_round_prior_marker "$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-02-01T10:00:00Z","body":"<!-- review-round-counter: issue=200 head=aaa round=2 -->"}
]
JSON
)")"

assert_eq "TC-INV129-026 the OLD empty-PR_HEAD_SHA-forces-round=1 branch is gone (regression pin)" "" \
  "$(grep -o 'defaulting review round to 1' "$WRAPPER")"

assert_contains "TC-INV129-027 read site calls _review_round_prior_marker unconditionally (no PR_HEAD_SHA guard around it)" \
  "$(cat "$WRAPPER")" '_rr_prior_marker=$(_review_round_prior_marker "$_rr_comments_json")'

assert_contains "TC-INV129-028 marker post site passes PR_HEAD_SHA through unconditionally (head=unknown handled inside _review_round_marker)" \
  "$(cat "$WRAPPER")" 'itp_post_comment "$ISSUE_NUMBER" "$(_review_round_marker "$ISSUE_NUMBER" "$PR_HEAD_SHA" 0)"'

FIXTURE_I129_029=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-02-01T10:00:00Z","body":"<!-- review-round-counter: issue=200 head=aaa round=2 -->"},
  {"authorKind":"bot","createdAt":"2026-02-01T11:00:00Z","body":null}
]
JSON
)
assert_eq "TC-INV129-029 a null .body row does not crash the scan; genuine marker still found" \
  "<!-- review-round-counter: issue=200 head=aaa round=2 -->" \
  "$(_review_round_prior_marker "$FIXTURE_I129_029")"

# --- Group F: INV-127 gate regression pin (R5) ---

assert_eq "TC-INV129-030 _aggregate_has_p0p1_fail output is unchanged on the existing fixture set" "true" \
  "$(_aggregate_has_p0p1_fail fail P1 fail P2)"
assert_eq "TC-INV129-030b _aggregate_has_p0p1_fail P2-only still returns false (unchanged)" "false" \
  "$(_aggregate_has_p0p1_fail fail P2 fail P3)"

# TC-INV129-031: R5 requires lib-review-aggregate.sh's CODE (non-comment
# lines) be byte-identical to main. Stripping `#`-led/blank lines and diffing
# against the pre-#475 baseline is the closest we can pin without a live git
# checkout of `main` inside this test run (git availability is not
# guaranteed in the test harness) — so this is a structural pin: the
# function body (the executable lines between the `_aggregate_has_p0p1_fail()`
# signature and its closing brace) must still be exactly the documented
# while/case/printf shape.
p0p1_body=$(awk '/^_aggregate_has_p0p1_fail\(\)/{f=1} f{print} f && /^}$/{exit}' "$AGGREGATE_LIB")
assert_contains "TC-INV129-031 _aggregate_has_p0p1_fail's executable body is unchanged (while/case/printf shape)" \
  "$p0p1_body" 'case "$severity" in
        P2|P3) ;;'

# TC-INV129-032/033: the acceptance-criteria scenario — a simulated loop
# where every round pushes a new head and each round's only finding is
# [P2] — the review demotes the fail to pass at round 5. TC-INV129-033a
# (the round-4 intermediate value) is folded into this same loop rather than
# a separate 4-then-1-more progression, since a second loop would only add
# scaffolding for the one new fact (round 4).
_i129_p2_marker=""
_i129_p2_round=0
_i129_p2_iter=0
for _h in newhead1 newhead2 newhead3 newhead4 newhead5; do
  _i129_p2_iter=$((_i129_p2_iter + 1))
  _i129_p2_round=$(_review_round_next_count "$_i129_p2_marker")
  _i129_p2_marker=$(_review_round_marker 200 "$_h" "$_i129_p2_round")
  if [[ "$_i129_p2_iter" -eq 4 ]]; then
    assert_eq "TC-INV129-033a after 4 consecutive new-head fails, round is 4" "4" "$_i129_p2_round"
  fi
done
assert_eq "TC-INV129-032 new-head-every-round P2-only loop reaches round 5" "5" "$_i129_p2_round"
assert_eq "TC-INV129-032b at round 5, shouldBlockFinding demotes the P2 finding (does not block)" "false" \
  "$(shouldBlockFinding "$_i129_p2_round" P2 && echo true || echo false)"
assert_eq "TC-INV129-032c _aggregate_has_p0p1_fail on that same P2-only round is false — the round never reaches INV-127's counting branch as a fail at all" "false" \
  "$(_aggregate_has_p0p1_fail fail P2)"

# --- Group G: end-to-end round-progression simulations ---

# TC-INV129-034: an all-timeout fail (no substantive fail) posts no marker
# at all, so the round number does not advance on that round — pinned via
# a direct counter-side simulation (the wrapper's own `elif …
# _AGGREGATE_SUBSTANTIVE_FAIL == true` gate that decides whether to post is
# exercised by the pre-existing TC-REVIEW-CONV-056b wiring pin; this test
# confirms the CONSEQUENCE of that gate skipping a post — the next read must
# not see a phantom round).
_i129_before_timeout=$(_review_round_marker 300 gh2 2)
# No new marker posted for the timeout round — the next read still sees the
# round-2 marker and increments from it, not from a phantom round-3.
assert_eq "TC-INV129-034 no marker posted on an all-timeout round → next read still increments from the last REAL marker" "3" \
  "$(_review_round_next_count "$_i129_before_timeout")"

# TC-INV129-035: a genuine PASS mid-series resets to 1 on the next round —
# via BOTH channels (trailer cutoff and round=0 marker), confirmed together.
FIXTURE_I129_035=$(cat <<'JSON'
[
  {"authorKind":"bot","createdAt":"2026-02-01T10:00:00Z","body":"<!-- review-round-counter: issue=300 head=gh1 round=1 -->"},
  {"authorKind":"bot","createdAt":"2026-02-01T11:00:00Z","body":"<!-- review-round-counter: issue=300 head=gh2 round=2 -->"},
  {"authorKind":"bot","createdAt":"2026-02-01T12:00:00Z","body":"<!-- review-verdict: passed -->"},
  {"authorKind":"bot","createdAt":"2026-02-01T12:00:01Z","body":"<!-- review-round-counter: issue=300 head=gh3 round=0 -->"}
]
JSON
)
assert_eq "TC-INV129-035 round resets to 1 after a genuine PASS (both channels agree)" "1" \
  "$(_review_round_next_count "$(_review_round_prior_marker "$FIXTURE_I129_035")")"

# TC-INV129-036: mixed loop — rounds 1-2 are P1 (advance both R1's ratchet
# and INV-127's cap-relevant _aggregate_has_p0p1_fail), rounds 3-5 are
# P2-only (advance R1's ratchet only). R1's REVIEW_ROUND reaches 6; INV-127's
# own _aggregate_has_p0p1_fail is false for every P2-only round, so its
# independent counter (lib-review-cap.sh, not under test here) never
# advances past round 2 in a real run — this pin exercises the per-round
# _aggregate_has_p0p1_fail decision for each round of the mix.
_i129_mixed_marker=""
_i129_mixed_round=0
_i129_mixed_severities=(P1 P1 P2 P2 P2 P2)
for _sev in "${_i129_mixed_severities[@]}"; do
  _i129_mixed_round=$(_review_round_next_count "$_i129_mixed_marker")
  _i129_mixed_marker=$(_review_round_marker 400 "mixedhead-$_i129_mixed_round" "$_i129_mixed_round")
  _i129_mixed_p0p1=$(_aggregate_has_p0p1_fail fail "$_sev")
  if [[ "$_sev" == "P1" ]]; then
    assert_eq "TC-INV129-036 round ${_i129_mixed_round} (severity ${_sev}) counts as INV-127 terminal-floor evidence" "true" "$_i129_mixed_p0p1"
  else
    assert_eq "TC-INV129-036 round ${_i129_mixed_round} (severity ${_sev}) does NOT count as INV-127 terminal-floor evidence" "false" "$_i129_mixed_p0p1"
  fi
done
assert_eq "TC-INV129-036f R1's ratchet round reaches 6 across the mixed P1/P2 series" "6" "$_i129_mixed_round"

# ===========================================================================
echo
echo "=== TC-SEVEXT-001..013: codex severity call-site input selection (issue #481, INV-132, spec revision 2) ==="
# ===========================================================================
# The severity filter's per-agent text selection (autonomous-review.sh, right
# before _review_extract_highest_severity) branches on AGENT_VERDICT_SOURCES,
# a real per-agent array this test file simulates directly, plus a wiring pin
# confirming the wrapper's own selection order against the actual source.

CX_TURNS_P2_FIXTURE="$FIXTURES/codex-review-stdout-turns-p2-only.txt"
CX_TURNS_OVERSTRIP_FIXTURE="$FIXTURES/codex-review-stdout-turns-overstrip.txt"
assert_file_exists "TC-SEVEXT setup: codex turn-marker P2-only fixture exists" "$CX_TURNS_P2_FIXTURE"
assert_file_exists "TC-SEVEXT setup: codex turn-marker over-strip fixture exists" "$CX_TURNS_OVERSTRIP_FIXTURE"

# TC-SEVEXT-001/002: the reproduction scenario, artifact-resolved path. An
# artifact-resolved codex verdict (source=="artifact") scores
# AGENT_VERDICT_BODIES[i] — the artifact-rendered body, never the raw
# capture — and extracts P2 correctly.
_sevext_art_json='{"schema_version":1,"verdict":"FAIL","blockingFindings":[{"title":"minor nit","severity":"P2"},{"title":"another nit","severity":"P2"}],"runId":"abc","agent":"codex"}'
_sevext_art_body=$(_verdict_body_from_artifact_json "$_sevext_art_json")
assert_eq "TC-SEVEXT-001 artifact-rendered body (source==artifact) scores P2" "P2" \
  "$(_review_extract_highest_severity "$_sevext_art_body")"
assert_eq "TC-SEVEXT-002 regression pin: a direct whole-capture scan of the SAME scenario's turn-marker fixture still collapses to none (R3 — the scanner itself is unmodified, only the input selection changed)" "none" \
  "$(_review_extract_highest_severity "$(cat "$CX_TURNS_P2_FIXTURE")")"

# TC-SEVEXT-003/004: the legacy stdout-classify fallback route
# (source=="codex-stdout-fallback") strips the echo via the turn-marker
# boundary helper, THEN scores — recovering P2 instead of none.
assert_eq "TC-SEVEXT-003 stdout-fallback route: turn-marker-stripped capture scores P2" "P2" \
  "$(_review_extract_highest_severity "$(_codex_review_strip_prompt_echo "$CX_TURNS_P2_FIXTURE")")"

# TC-SEVEXT-004: a capture with no recognizable header/marker structure at
# all is scored as-is (fail-safe passthrough) — downstream severity result
# unaffected for a short clean review carrying a real tag.
TMP_SEVEXT004=$(mktemp)
printf '%s\n' 'A short clean review of the diff.' '' '[P3] tests/x.test.ts:1 — consider an edge case.' '' 'Summary: 1 non-blocking finding.' > "$TMP_SEVEXT004"
assert_eq "TC-SEVEXT-004 no-structure capture: stripped == original, still scores P3" "P3" \
  "$(_review_extract_highest_severity "$(_codex_review_strip_prompt_echo "$TMP_SEVEXT004")")"
rm -f "$TMP_SEVEXT004"

# TC-SEVEXT-005 (R3 pin): a genuinely untagged finding in the (already
# echo-free) verdict body still extracts as `none` — the scanner itself is
# unmodified by this fix.
_sevext_untagged_body=$'1. missing null check\n2. off-by-one error'
assert_eq "TC-SEVEXT-005 [R3] untagged numbered body still extracts none (scanner unmodified)" "none" \
  "$(_review_extract_highest_severity "$_sevext_untagged_body")"

# TC-SEVEXT-006: with extraction fixed, a P2-only round's (fail, severity)
# pair never counts as INV-127 terminal-floor evidence.
assert_eq "TC-SEVEXT-006 codex P2-only round: _aggregate_has_p0p1_fail is false (INV-127 does not advance)" "false" \
  "$(_aggregate_has_p0p1_fail fail P2)"

# TC-SEVEXT-007: regression pin — a non-codex agent's selection is untouched
# (it always scored AGENT_VERDICT_BODIES[i]; no source flag concept applies).
assert_eq "TC-SEVEXT-007 non-codex agent: verdict-body scoring unchanged" "P1" \
  "$(_review_extract_highest_severity '[P1] a real blocking finding')"

# TC-SEVEXT-008: over-stripping pin — a fixture whose reviewed-file/tool-trace
# content contains bare `user`/`codex` words AFTER the real response marker
# (but fenced, mirroring how a reviewed diff snippet would be quoted) must
# NOT be treated as a false boundary; the real finding survives intact.
_overstrip_stripped=$(_codex_review_strip_prompt_echo "$CX_TURNS_OVERSTRIP_FIXTURE")
assert_contains "TC-SEVEXT-008a over-strip fixture: real [P2] finding survives" \
  "$_overstrip_stripped" '[P2] src/roles.ts:12'
assert_eq "TC-SEVEXT-008b over-strip fixture: severity extraction on the stripped result is P2 (not falsely collapsed)" "P2" \
  "$(_review_extract_highest_severity "$_overstrip_stripped")"

# TC-SEVEXT-009: wiring pin — the wrapper's severity call site branches on
# AGENT_VERDICT_SOURCES[_i]=="codex-stdout-fallback", not agent identity.
sevext_wire_region=$(awk '/^_any_severity_demotion=false$/{f=1} f{print} f && /^  AGENT_HIGHEST_SEVERITY\[\$_i\]=/{exit}' "$WRAPPER")
assert_contains "TC-SEVEXT-009a wrapper's severity-source selection branches on AGENT_VERDICT_SOURCES" \
  "$sevext_wire_region" 'AGENT_VERDICT_SOURCES[$_i]:-}" == "codex-stdout-fallback"'
assert_contains "TC-SEVEXT-009b the stdout-fallback branch calls the strip helper (not a bare cat)" \
  "$sevext_wire_region" '_codex_review_strip_prompt_echo "${AGENT_CODEX_LOGS[$_i]}"'
assert_contains "TC-SEVEXT-009c the ELSE branch (every other resolution channel) scores AGENT_VERDICT_BODIES[_i]" \
  "$sevext_wire_region" '_sev_text="${AGENT_VERDICT_BODIES[$_i]:-}"'

# TC-SEVEXT-010: wiring pin — the wrapper tags AGENT_VERDICT_SOURCES as
# `codex-stdout-fallback` at the EXACT call site where
# `_codex_review_classify_stdout` supplied the verdict, as a real branchable
# assignment (not merely a log line).
assert_contains "TC-SEVEXT-010 wrapper sets AGENT_VERDICT_SOURCES[_i]=codex-stdout-fallback at the classify-stdout resolution site" \
  "$(cat "$WRAPPER")" 'AGENT_VERDICT_SOURCES[$_i]="codex-stdout-fallback"'

# ===========================================================================
echo
echo "=== TC-CXSTRIP-001..008: _codex_review_strip_prompt_echo (adapters/codex.sh, issue #481, spec revision 2) ==="
# ===========================================================================

_cxstrip_result=$(_codex_review_strip_prompt_echo "$CX_TURNS_P2_FIXTURE")
assert_eq "TC-CXSTRIP-001a stripped result contains no numbered checklist line" "" \
  "$(grep -o '1\. \[ \] Design canvas created' <<<"$_cxstrip_result")"
assert_eq "TC-CXSTRIP-001b stripped result contains no reasoning/tool-trace turn text" "" \
  "$(grep -o 'Running: git diff' <<<"$_cxstrip_result")"
assert_contains "TC-CXSTRIP-001c stripped result still contains the real [P2] finding" \
  "$_cxstrip_result" '[P2] src/handler.ts:88'
assert_contains "TC-CXSTRIP-001d stripped result still contains the second [P2] finding" \
  "$_cxstrip_result" '[P2] src/other.ts:42'

TMP_CXSTRIP002=$(mktemp)
printf '%s\n' 'A short clean review with no blocking findings.' '' 'Summary: looks good to merge.' > "$TMP_CXSTRIP002"
assert_eq "TC-CXSTRIP-002 capture with no header at all is returned UNCHANGED" \
  "$(cat "$TMP_CXSTRIP002")" "$(_codex_review_strip_prompt_echo "$TMP_CXSTRIP002")"
rm -f "$TMP_CXSTRIP002"

TMP_CXSTRIP003=$(mktemp)
assert_eq "TC-CXSTRIP-003a empty file → empty, rc 0 (fail-safe)" "" \
  "$(_codex_review_strip_prompt_echo "$TMP_CXSTRIP003")"
rm -f "$TMP_CXSTRIP003"
assert_eq "TC-CXSTRIP-003b missing file → empty, rc 0 (fail-safe)" "" \
  "$(_codex_review_strip_prompt_echo /nonexistent/path/$$)"
assert_eq "TC-CXSTRIP-003c empty arg → empty, rc 0 (fail-safe)" "" \
  "$(_codex_review_strip_prompt_echo "")"

# TC-CXSTRIP-004: a validated header present, but NO `user` marker at all
# (a legacy free-form capture) → whole text returned unchanged (fail-safe).
TMP_CXSTRIP004=$(mktemp)
printf '%s\n' 'OpenAI Codex v0.139.0' '--------' 'workdir: /tmp/x' 'model: m' 'provider: p' '--------' '' 'Direct review text, no turn markers.' '[P2] a real finding here.' > "$TMP_CXSTRIP004"
assert_eq "TC-CXSTRIP-004 header present but no user marker → whole capture unchanged (fail-safe)" \
  "$(cat "$TMP_CXSTRIP004")" "$(_codex_review_strip_prompt_echo "$TMP_CXSTRIP004")"
rm -f "$TMP_CXSTRIP004"

# TC-CXSTRIP-005: header + `user` marker present, but NO `codex` marker
# after it (codex crashed mid-turn / captured before responding) → whole
# capture unchanged (fail-safe) — never guess a boundary that isn't there.
TMP_CXSTRIP005=$(mktemp)
printf '%s\n' 'OpenAI Codex v0.139.0' '--------' 'workdir: /tmp/x' 'model: m' 'provider: p' '--------' '' 'user' 'echoed prompt text with no [P1] tag' > "$TMP_CXSTRIP005"
assert_eq "TC-CXSTRIP-005 user marker present but no codex marker after it → whole capture unchanged (fail-safe)" \
  "$(cat "$TMP_CXSTRIP005")" "$(_codex_review_strip_prompt_echo "$TMP_CXSTRIP005")"
rm -f "$TMP_CXSTRIP005"

# TC-CXSTRIP-006: the over-stripping fixture — reviewed content containing
# bare `user`/`codex` words (fenced, as a diff/code snippet would render)
# after the real response marker must not create a false LATER boundary;
# the LAST codex marker used is the genuine turn marker BEFORE the fenced
# quote, and everything after it (including the fenced quote) is kept.
_cxstrip006=$(_codex_review_strip_prompt_echo "$CX_TURNS_OVERSTRIP_FIXTURE")
assert_contains "TC-CXSTRIP-006a over-strip fixture: kept text includes the fenced user/codex/system quote" \
  "$_cxstrip006" 'system'
assert_contains "TC-CXSTRIP-006b over-strip fixture: kept text includes the real [P2] finding" \
  "$_cxstrip006" '[P2] src/roles.ts:12'

# TC-CXSTRIP-007: multiple `codex` turns (reasoning, tool call, final
# response) — the LAST one bounds the final response; earlier reasoning/tool
# turns are excluded from the scored text.
TMP_CXSTRIP007=$(mktemp)
printf '%s\n' 'OpenAI Codex v0.139.0' '--------' 'workdir: /tmp/x' 'model: m' 'provider: p' '--------' '' 'user' 'echoed prompt' '' 'codex' 'Reasoning turn text, no findings here.' '' 'codex' 'Tool call turn text, also no findings.' '' 'codex' '[P1] the real final finding.' > "$TMP_CXSTRIP007"
_cxstrip007=$(_codex_review_strip_prompt_echo "$TMP_CXSTRIP007")
assert_eq "TC-CXSTRIP-007a multi-turn capture: earlier reasoning turn text excluded" "" \
  "$(grep -o 'Reasoning turn text' <<<"$_cxstrip007")"
assert_eq "TC-CXSTRIP-007b multi-turn capture: earlier tool-call turn text excluded" "" \
  "$(grep -o 'Tool call turn text' <<<"$_cxstrip007")"
assert_contains "TC-CXSTRIP-007c multi-turn capture: final response finding included" \
  "$_cxstrip007" '[P1] the real final finding'
rm -f "$TMP_CXSTRIP007"

# TC-CXSTRIP-008: the `user`/`codex` markers must be column-0 exact-word
# matches — an indented or trailing-content variant is NOT a marker (avoids
# a tool-output line like "  user" or "codexreview" false-matching).
TMP_CXSTRIP008=$(mktemp)
printf '%s\n' 'OpenAI Codex v0.139.0' '--------' 'workdir: /tmp/x' 'model: m' 'provider: p' '--------' '' '  user' 'not a real marker (indented)' 'codexreview not a real marker either' > "$TMP_CXSTRIP008"
assert_eq "TC-CXSTRIP-008 indented/trailing-content lines are not markers → whole capture unchanged (fail-safe)" \
  "$(cat "$TMP_CXSTRIP008")" "$(_codex_review_strip_prompt_echo "$TMP_CXSTRIP008")"
rm -f "$TMP_CXSTRIP008"

# TC-CXSTRIP-009: a ~~~-fenced (not just ```-fenced) reviewed-content snippet
# quoting column-zero `user`/`codex`/`system` lines must NOT be mistaken for a
# later genuine turn marker — the fence-toggle awk must recognize BOTH fence
# styles, or the helper would discard the real findings that precede the
# tilde-fenced snippet and extract none instead of demoting (review round-1
# finding 2, PR #484).
CX_TILDE_FIXTURE="$FIXTURES/codex-review-stdout-turns-tilde-fence.txt"
assert_file_exists "TC-CXSTRIP-009 setup: tilde-fence fixture exists" "$CX_TILDE_FIXTURE"
_cxstrip009=$(_codex_review_strip_prompt_echo "$CX_TILDE_FIXTURE")
assert_contains "TC-CXSTRIP-009a tilde-fenced fixture: first real [P2] finding survives" \
  "$_cxstrip009" '[P2] src/handler.ts:88'
assert_contains "TC-CXSTRIP-009b tilde-fenced fixture: second real [P2] finding survives" \
  "$_cxstrip009" '[P2] src/other.ts:42'
assert_eq "TC-CXSTRIP-009c severity extraction on the tilde-fence fixture's stripped result is P2 (not falsely collapsed to none)" "P2" \
  "$(_review_extract_highest_severity "$_cxstrip009")"

# TC-CXSTRIP-010: the CLI's own trailing `tokens used: <N>` footer must never
# reach the scored text — a bare token count is not review findings and must
# not be able to influence severity extraction (review round-1 finding 3, PR
# #484). The p2-only fixture already carries a `tokens used: 54210` footer
# line after the final response.
_cxstrip010=$(_codex_review_strip_prompt_echo "$CX_TURNS_P2_FIXTURE")
assert_eq "TC-CXSTRIP-010a stripped result contains no 'tokens used' footer line" "" \
  "$(grep -io 'tokens used' <<<"$_cxstrip010")"
TMP_CXSTRIP010=$(mktemp)
printf '%s\n' 'OpenAI Codex v0.139.0' '--------' 'workdir: /tmp/x' 'model: m' 'provider: p' '--------' '' 'user' 'echoed prompt' '' 'codex' '[P3] a real finding, low severity only.' '' 'Tokens Used: 12345' > "$TMP_CXSTRIP010"
_cxstrip010b=$(_codex_review_strip_prompt_echo "$TMP_CXSTRIP010")
assert_eq "TC-CXSTRIP-010b mixed-case 'Tokens Used:' footer stripped" "" \
  "$(grep -io 'tokens used' <<<"$_cxstrip010b")"
assert_eq "TC-CXSTRIP-010c severity extraction on a footer-only-P3 capture is P3, not polluted by the footer" "P3" \
  "$(_review_extract_highest_severity "$_cxstrip010b")"
rm -f "$TMP_CXSTRIP010"

# TC-CXSTRIP-011: an UN-FENCED, column-0 `codex` word appearing mid-paragraph
# in quoted tool/reviewed-file output — with NO blank line before it — must
# NOT be mistaken for a later genuine turn marker (round-3 review finding
# [P2], PR #484). Pre-fix, the Step-3 scan required only column-0/exact-word/
# unfenced, so this inline word won this file's "last codex marker" search
# and everything before it (including a real [P1]) was discarded, leaving
# only the trailing [P2] — a P1 finding silently reduced to P2-only and
# demoted at round 5. Every genuine marker in a real capture is its own
# paragraph (blank line before it); this fixture's hazard line flows directly
# out of the preceding prose sentence with no blank line, so the fix's
# blank-line-before requirement must reject it as a boundary.
CX_UNFENCED_INLINE_FIXTURE="$FIXTURES/codex-review-stdout-turns-unfenced-inline-marker.txt"
assert_file_exists "TC-CXSTRIP-011 setup: unfenced-inline-marker fixture exists" "$CX_UNFENCED_INLINE_FIXTURE"
_cxstrip011=$(_codex_review_strip_prompt_echo "$CX_UNFENCED_INLINE_FIXTURE")
assert_contains "TC-CXSTRIP-011a unfenced-inline-marker fixture: the earlier [P1] finding survives" \
  "$_cxstrip011" '[P1] src/auth.ts:10'
assert_contains "TC-CXSTRIP-011b unfenced-inline-marker fixture: the later [P2] finding survives" \
  "$_cxstrip011" '[P2] src/docs.ts:20'
assert_eq "TC-CXSTRIP-011c severity extraction on the unfenced-inline-marker fixture is P1 (not demoted to P2 by over-stripping)" "P1" \
  "$(_review_extract_highest_severity "$_cxstrip011")"

# ===========================================================================
echo
echo "=== TC-SEVEXT-011..013: simulated 5-round P2-only codex loop demotes at round 5 (spec revision 2 AC procedure) ==="
# ===========================================================================
# The acceptance-criteria scenario, driven through the PRODUCTION helper
# (_codex_review_strip_prompt_echo) at each round — not a reimplementation.

_sevext5_marker=""
_sevext5_round=0
for _h in cxhead1 cxhead2 cxhead3 cxhead4 cxhead5; do
  _sevext5_round=$(_review_round_next_count "$_sevext5_marker")
  _sevext5_marker=$(_review_round_marker 481 "$_h" "$_sevext5_round")
done
assert_eq "TC-SEVEXT-011 5-round new-head-every-round progression reaches round 5" "5" "$_sevext5_round"

# Drive the production stdout-fallback route: strip via the helper, then
# extract severity, mirroring exactly what the wrapper's ELSE-branch-vs-
# stdout-fallback-branch selection does for each round of the loop.
_sevext5_stripped=$(_codex_review_strip_prompt_echo "$CX_TURNS_P2_FIXTURE")
_sevext5_sev=$(_review_extract_highest_severity "$_sevext5_stripped")
assert_eq "TC-SEVEXT-012a extraction from the helper-stripped codex capture is P2" "P2" "$_sevext5_sev"
assert_eq "TC-SEVEXT-012b at round 5, that P2 demotes fail→pass (INV-129 loop convergence, extraction now correctly fed)" "pass" \
  "$(_review_apply_severity_filter fail "$_sevext5_stripped" "$_sevext5_round")"
assert_eq "TC-SEVEXT-012c rounds 1-4 stay fail (the ratchet's own floor, unmodified)" "fail fail fail fail" \
  "$(_review_apply_severity_filter fail "$_sevext5_stripped" 1) $(_review_apply_severity_filter fail "$_sevext5_stripped" 2) $(_review_apply_severity_filter fail "$_sevext5_stripped" 3) $(_review_apply_severity_filter fail "$_sevext5_stripped" 4)"
assert_eq "TC-SEVEXT-013 INV-127's counter (via _aggregate_has_p0p1_fail) stays false across all 5 rounds" "false false false false false" \
  "$(_aggregate_has_p0p1_fail fail "$_sevext5_sev") $(_aggregate_has_p0p1_fail fail "$_sevext5_sev") $(_aggregate_has_p0p1_fail fail "$_sevext5_sev") $(_aggregate_has_p0p1_fail fail "$_sevext5_sev") $(_aggregate_has_p0p1_fail fail "$_sevext5_sev")"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
