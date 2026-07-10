#!/bin/bash
# test-e2e-gate-circuit-breaker.sh — issue #453.
#
# Pins the same-HEAD E2E-gate circuit breaker's pure decision-logic helpers in
# lib-review-e2e.sh, plus a source-of-truth grep pin that autonomous-review.sh
# wires the breaker in at the correct hook point (mirrors the two-pronged style
# of test-autonomous-review-e2e-gate-open-guard.sh: pure logic + wiring greps,
# since the wrapper itself is too heavy to run end-to-end).
#
# See docs/test-cases/e2e-gate-circuit-breaker.md for the TC-CIRCUIT-* mapping.
#
# Run: bash tests/unit/test-e2e-gate-circuit-breaker.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHP_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-code-host.sh"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-e2e.sh"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
ERRORS_DOC="$PROJECT_ROOT/docs/pipeline/errors.md"

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

assert_file_exists "setup: lib-review-e2e.sh exists" "$LIB"
assert_file_exists "setup: autonomous-review.sh exists" "$WRAPPER"

# CHP seam BEFORE lib-review-e2e.sh (lib-review-e2e.sh calls chp_pr_view, etc.)
# — matches the real wrapper's own sourcing order and the seam-source-meta
# convention (test-seam-source-meta.sh) that every consumer-lib source in a
# test harness be preceded by the matching seam.
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-code-host.sh
source "$CHP_LIB"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-e2e.sh
source "$LIB"

# ===========================================================================
echo "=== TC-CIRCUIT-001..010: fingerprint / counter / threshold logic ==="
# ===========================================================================

# TC-CIRCUIT-001: marker round-trip.
m=$(_gate_breaker_marker 100 deadbeef 1 3)
assert_eq "TC-CIRCUIT-001a marker construction contains issue" "true" \
  "$([[ "$m" == *"issue=100"* ]] && echo true || echo false)"
assert_eq "TC-CIRCUIT-001b marker round-trip: parse returns the same count" \
  "3" "$(_gate_breaker_parse_count "$m" deadbeef 1)"

# TC-CIRCUIT-002: same head + same rc → next count = stored + 1.
m2=$(_gate_breaker_marker 100 deadbeef 1 1)
assert_eq "TC-CIRCUIT-002 same head+rc increments" "2" \
  "$(_gate_breaker_next_count "$m2" deadbeef 1)"

# TC-CIRCUIT-003: same head, DIFFERENT rc → resets to 1 (not accumulated).
m3=$(_gate_breaker_marker 100 deadbeef 1 5)
assert_eq "TC-CIRCUIT-003 same head, different rc resets to 1" "1" \
  "$(_gate_breaker_next_count "$m3" deadbeef 2)"

# TC-CIRCUIT-004: different head → resets to 1.
m4=$(_gate_breaker_marker 100 deadbeef 1 5)
assert_eq "TC-CIRCUIT-004 different head resets to 1" "1" \
  "$(_gate_breaker_next_count "$m4" cafebabe 1)"

# TC-CIRCUIT-005: no prior marker (empty string) → parsed as 0, next = 1.
assert_eq "TC-CIRCUIT-005a absent marker parses to count=0" "0" \
  "$(_gate_breaker_parse_count "" deadbeef 1)"
assert_eq "TC-CIRCUIT-005b absent marker → next count = 1" "1" \
  "$(_gate_breaker_next_count "" deadbeef 1)"

# TC-CIRCUIT-006: malformed/corrupted marker text → parsed as 0, does not crash.
assert_eq "TC-CIRCUIT-006a malformed marker parses to count=0" "0" \
  "$(_gate_breaker_parse_count "not a marker at all {{{" deadbeef 1)"
assert_eq "TC-CIRCUIT-006b malformed marker → next count = 1 (no crash)" "1" \
  "$(_gate_breaker_next_count "<!-- dispatcher-gate-fail-breaker: garbage -->" deadbeef 1)"

# TC-CIRCUIT-007: threshold unset → default 2.
unset GATE_FAIL_STALL_THRESHOLD
assert_eq "TC-CIRCUIT-007 threshold unset defaults to 2" "2" "$(_gate_breaker_threshold 2>/dev/null)"

# TC-CIRCUIT-008: non-numeric → fallback to 2, with a warning.
GATE_FAIL_STALL_THRESHOLD="banana"
warn_out=$(_gate_breaker_threshold 2>&1 1>/dev/null)
val_out=$(_gate_breaker_threshold 2>/dev/null)
assert_eq "TC-CIRCUIT-008a non-numeric threshold falls back to 2" "2" "$val_out"
assert_contains "TC-CIRCUIT-008b non-numeric threshold logs a warning" "$warn_out" "WARNING"

# TC-CIRCUIT-009: below the floor (1) → fallback to 2, with a warning.
GATE_FAIL_STALL_THRESHOLD="1"
warn_out=$(_gate_breaker_threshold 2>&1 1>/dev/null)
val_out=$(_gate_breaker_threshold 2>/dev/null)
assert_eq "TC-CIRCUIT-009a threshold=1 falls back to 2 (floor is >=2)" "2" "$val_out"
assert_contains "TC-CIRCUIT-009b threshold=1 logs a warning" "$warn_out" "WARNING"

# TC-CIRCUIT-010: valid >=2 value honored verbatim, no warning.
GATE_FAIL_STALL_THRESHOLD="5"
warn_out=$(_gate_breaker_threshold 2>&1 1>/dev/null)
val_out=$(_gate_breaker_threshold 2>/dev/null)
assert_eq "TC-CIRCUIT-010a threshold=5 honored verbatim" "5" "$val_out"
assert_eq "TC-CIRCUIT-010b valid threshold logs no warning" "" "$warn_out"
unset GATE_FAIL_STALL_THRESHOLD

# ===========================================================================
echo
echo "=== TC-CIRCUIT-011..016: trip / no-trip decision scenarios ==="
# ===========================================================================

# These exercise the SAME pure helpers end-to-end as the wrapper would: build
# a stored marker, compute the next count, compare against threshold.
trip_decision() {
  local stored_marker="$1" head="$2" rc="$3" threshold="$4" next
  next=$(_gate_breaker_next_count "$stored_marker" "$head" "$rc")
  if [[ "$next" -ge "$threshold" ]]; then
    echo "trip"
  else
    echo "no-trip"
  fi
}

# TC-CIRCUIT-011: 2 consecutive same-head-same-rc failures (stored count=1,
# threshold=2) → the round that would carry count=2 trips.
stored=$(_gate_breaker_marker 100 deadbeef 1 1)
assert_eq "TC-CIRCUIT-011 count reaches threshold → trip" "trip" \
  "$(trip_decision "$stored" deadbeef 1 2)"

# TC-CIRCUIT-012: below threshold (stored count=0 / no marker, threshold=2)
# → the very first failure (next=1) does not trip.
assert_eq "TC-CIRCUIT-012 count below threshold → no trip" "no-trip" \
  "$(trip_decision "" deadbeef 1 2)"

# TC-CIRCUIT-013: same head, DIFFERENT rc between rounds → resets, does not trip.
stored13=$(_gate_breaker_marker 100 deadbeef 1 3)
assert_eq "TC-CIRCUIT-013 different rc resets counter → no trip on round 2" "no-trip" \
  "$(trip_decision "$stored13" deadbeef 2 2)"

# TC-CIRCUIT-014: new commit pushed after N-1 failures → fresh marker under
# the new SHA starts at count=1, does not trip.
stored14=$(_gate_breaker_marker 100 deadbeef 1 5)
assert_eq "TC-CIRCUIT-014 new commit resets counter → no trip" "no-trip" \
  "$(trip_decision "$stored14" newcommitsha 1 2)"

# TC-CIRCUIT-015: regression pin — the breaker's helpers are pure functions
# with no global state; calling them with an unrelated (head, rc) pair (e.g.
# a normal review-findings FAIL path where head legitimately changes each
# round) never accumulates a stale count. This is inherent in the pure
# function design (no side effects, no persistence outside the caller-passed
# marker text) — asserted here as an explicit regression pin.
unrelated_marker=$(_gate_breaker_marker 100 oldhead 1 9)
assert_eq "TC-CIRCUIT-015 changing head on the normal FAIL path never trips the breaker" "no-trip" \
  "$(trip_decision "$unrelated_marker" brandnewhead 1 2)"

# TC-CIRCUIT-016: operator removes `stalled` without a new commit — the
# marker is still armed at (or past) threshold-1; the next round's failure
# (same head, same rc) re-trips immediately. Documented, intentional.
stored16=$(_gate_breaker_marker 100 deadbeef 1 1)
assert_eq "TC-CIRCUIT-016 re-arm without new commit re-trips on next failure" "trip" \
  "$(trip_decision "$stored16" deadbeef 1 2)"

# ===========================================================================
echo
echo "=== TC-CIRCUIT-017..020: report content + ordering (grep pins) ==="
# ===========================================================================

# The actual report/transition logic lives in autonomous-review.sh (the
# wrapper); the CONTENT and ORDERING requirements below are pinned as
# source-of-truth greps against the wrapper file (mirrors TC-CIRCUIT-021+).
wrapper_src=$(cat "$WRAPPER")

assert_contains "TC-CIRCUIT-018 wrapper's breaker report contains 'reason=same-head-gate-failure'" \
  "$wrapper_src" "reason=same-head-gate-failure"

assert_contains "TC-CIRCUIT-019 wrapper embeds ADT_TRANSIENT_E2E_DEPLOY_FAIL classification" \
  "$wrapper_src" "ADT_TRANSIENT_E2E_DEPLOY_FAIL"

# TC-CIRCUIT-017/020: already-stalled skip + atomicity ordering — pinned via
# line-number comparison against the wrapper source (transition call must
# precede the report call; an already-stalled check must precede both).
transition_line=$(grep -n 'itp_transition_state "\$ISSUE_NUMBER" "reviewing" "stalled"' "$WRAPPER" | head -1 | cut -d: -f1)
report_line=$(grep -n 'reason=same-head-gate-failure' "$WRAPPER" | head -1 | cut -d: -f1)
stalled_check_line=$(grep -n 'any(\. == "stalled")' "$WRAPPER" | head -1 | cut -d: -f1)

if [[ -n "$transition_line" && -n "$report_line" && "$transition_line" -lt "$report_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CIRCUIT-020 transition (line $transition_line) precedes report (line $report_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CIRCUIT-020 transition must precede report"
  echo "      transition_line=$transition_line report_line=$report_line"
  FAIL=$((FAIL + 1))
fi

if [[ -n "$stalled_check_line" && -n "$transition_line" && "$stalled_check_line" -lt "$transition_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CIRCUIT-017 already-stalled check (line $stalled_check_line) precedes the transition (line $transition_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CIRCUIT-017 already-stalled check must precede the transition"
  echo "      stalled_check_line=$stalled_check_line transition_line=$transition_line"
  FAIL=$((FAIL + 1))
fi

# ===========================================================================
echo
echo "=== TC-CIRCUIT-021..023: wrapper wiring (source-of-truth greps) ==="
# ===========================================================================

fail_block_line=$(grep -n 'if \[\[ "\$E2E_GATE" == "fail" \]\]; then' "$WRAPPER" | head -1 | cut -d: -f1)
breaker_call_line=$(grep -n '_gate_breaker_next_count\|_gate_breaker_threshold' "$WRAPPER" | head -1 | cut -d: -f1)
# Scope to the FIRST pending-dev transition AFTER the fail-block open — an
# unrelated earlier occurrence elsewhere in the file (this literal string
# recurs at several other call sites) must not be mistaken for this block's
# own routing line.
pending_dev_line=$(awk -v start="$fail_block_line" \
  'NR > start && /itp_transition_state "\$ISSUE_NUMBER" "reviewing" "pending-dev"/ { print NR; exit }' \
  "$WRAPPER")

if [[ -n "$fail_block_line" && -n "$breaker_call_line" && -n "$pending_dev_line" ]] \
   && [[ "$breaker_call_line" -gt "$fail_block_line" ]] \
   && [[ "$breaker_call_line" -lt "$pending_dev_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CIRCUIT-021 breaker check (line $breaker_call_line) sits inside E2E_GATE==fail (line $fail_block_line), before pending-dev routing (line $pending_dev_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CIRCUIT-021 breaker must be wired between the fail-block open and the pending-dev routing"
  echo "      fail_block_line=$fail_block_line breaker_call_line=$breaker_call_line pending_dev_line=$pending_dev_line"
  FAIL=$((FAIL + 1))
fi

# TC-CIRCUIT-022: the trip path's own exit must sit BEFORE the normal
# pending-dev routing (the short-circuit this whole breaker exists to
# perform) — pinned as a line-order check, not a literal-string search (the
# env var name itself lives in lib-review-e2e.sh's doc comments, not here).
trip_exit_line=$(awk -v start="$breaker_call_line" -v stop="$pending_dev_line" \
  'NR > start && NR < stop && /RESULT_PARSED=true/ { print NR; exit }' \
  "$WRAPPER")
if [[ -n "$trip_exit_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CIRCUIT-022 breaker's own exit (line $trip_exit_line) sits before the normal pending-dev routing (line $pending_dev_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CIRCUIT-022 breaker must exit before reaching the normal pending-dev routing"
  echo "      breaker_call_line=$breaker_call_line pending_dev_line=$pending_dev_line"
  FAIL=$((FAIL + 1))
fi

assert_file_exists "TC-CIRCUIT-023 setup: errors.md exists" "$ERRORS_DOC"
if [[ -f "$ERRORS_DOC" ]]; then
  assert_contains "TC-CIRCUIT-023 errors.md documents ADT_TRANSIENT_E2E_DEPLOY_FAIL (drift-guard forward-check)" \
    "$(cat "$ERRORS_DOC")" "ADT_TRANSIENT_E2E_DEPLOY_FAIL"
fi

# ===========================================================================
echo
echo "=== TC-CIRCUIT-024..027: codex review regression pins ==="
# ===========================================================================

# TC-CIRCUIT-024 (codex [P1] #1): the marker must be computed and posted on
# EVERY round, not only on the trip. Otherwise the very first failure (count=1,
# below the default threshold=2) never leaves a marker for the next round to
# find, and the counter can never advance past 1 in normal operation — the
# breaker would never trip. Pin: the normal (non-trip) "Review findings:"
# comment posted on the fall-through path must ALSO embed the marker.
normal_path_comment_line=$(grep -n 'Review findings:$' "$WRAPPER" | head -1 | cut -d: -f1)
normal_path_marker_line=$(awk -v start="$normal_path_comment_line" \
  'NR >= start && /\$\{_gf_marker\}/ { print NR; exit }' "$WRAPPER")
if [[ -n "$normal_path_comment_line" && -n "$normal_path_marker_line" ]] \
   && [[ "$normal_path_marker_line" -gt "$normal_path_comment_line" ]] \
   && [[ $((normal_path_marker_line - normal_path_comment_line)) -le 10 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CIRCUIT-024 the normal (non-trip) FAIL comment (line $normal_path_comment_line) also embeds \${_gf_marker} (line $normal_path_marker_line) — counter persists every round"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CIRCUIT-024 the normal FAIL comment must embed \${_gf_marker} so the counter persists across rounds"
  echo "      normal_path_comment_line=$normal_path_comment_line normal_path_marker_line=$normal_path_marker_line"
  FAIL=$((FAIL + 1))
fi

# TC-CIRCUIT-025 (codex [P1] #2): RESULT_PARSED=true must be set immediately
# after the transition lands and BEFORE the report post — a transient report-
# post failure under set -e must not leave RESULT_PARSED=false, which would
# make the crash-cleanup EXIT trap re-add pending-dev on top of an
# already-landed stall.
result_parsed_line=$(awk -v start="$transition_line" \
  'NR > start && /RESULT_PARSED=true/ { print NR; exit }' "$WRAPPER")
gatebreak_report_line=$(grep -n 'itp_post_comment "\$ISSUE_NUMBER" "\$(cat <<GATEBREAKREPORT' "$WRAPPER" | head -1 | cut -d: -f1)
if [[ -n "$result_parsed_line" && -n "$gatebreak_report_line" ]] \
   && [[ "$result_parsed_line" -lt "$gatebreak_report_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-CIRCUIT-025 RESULT_PARSED=true (line $result_parsed_line) is set BEFORE the report post (line $gatebreak_report_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CIRCUIT-025 RESULT_PARSED=true must be set before the report post, so a failed post can't trigger the crash-cleanup pending-dev route on top of a landed stall"
  echo "      result_parsed_line=$result_parsed_line gatebreak_report_line=$gatebreak_report_line"
  FAIL=$((FAIL + 1))
fi

# TC-CIRCUIT-026 (codex [P2] #1): the threshold-fallback warning must go to
# stderr directly, NEVER through log() — every call site captures this
# function's stdout via $(...) for the numeric result, so a log()-routed
# warning (which echoes to stdout) would corrupt the captured value.
assert_eq "TC-CIRCUIT-026a invalid threshold warning does not corrupt the captured numeric value" \
  "2" "$(GATE_FAIL_STALL_THRESHOLD="bogus" bash -c 'source "'"$LIB"'"; _gate_breaker_threshold 2>/dev/null')"
lib_src=$(cat "$LIB")
assert_contains "TC-CIRCUIT-026b _gate_breaker_threshold's fallback warning is a bare stderr echo (not log())" \
  "$(sed -n '/_gate_breaker_threshold()/,/^}/p' <<<"$lib_src")" 'echo "WARNING'

# TC-CIRCUIT-027 (codex [P2] #2): the marker read must filter to
# machine-authored comments only (authorKind != "human"), mirroring INV-105's
# own marker-authenticity filter — otherwise any collaborator able to comment
# could pre-seed a forged marker to force a premature trip.
assert_contains "TC-CIRCUIT-027 marker read filters authorKind != \"human\" (forgery guard, mirrors INV-105)" \
  "$wrapper_src" 'select(.authorKind != "human")'

# TC-CIRCUIT-028 (codex round-2 review [P1]): the trip condition must NOT call
# may_stall_now (or source lib-dispatch.sh at all) — a live function CALL
# (may_stall_now "$ISSUE_NUMBER"), not merely the identifier appearing in an
# explanatory comment (which legitimately documents WHY it is absent). That
# predicate's dispatch-marker-freshness check is designed for the DISPATCHER
# to ask whether some EXTERNAL process might be alive; called from INSIDE the
# very review wrapper the dispatcher just launched, it would always see its
# own fresh `review`-mode dispatch marker and defer for the marker's full TTL
# (default 600s) — silently defeating the breaker for any E2E failure that
# completes within that window, which is the common case.
assert_eq "TC-CIRCUIT-028a wrapper does not CALL may_stall_now (comment mentions are fine)" \
  "" "$(grep -vE '^\s*#' "$WRAPPER" | grep -o 'may_stall_now "\$ISSUE_NUMBER"')"
assert_eq "TC-CIRCUIT-028b wrapper does not source lib-dispatch.sh" \
  "" "$(grep -vE '^\s*#' "$WRAPPER" | grep -o 'source.*lib-dispatch\.sh')"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
