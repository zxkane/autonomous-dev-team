#!/bin/bash
# test-review-cli-exit-grace.sh — issue #180 (sibling clarification of INV-43).
#
# The per-agent verdict-poll loop runs AFTER the fan-out `wait`, so every agent
# CLI has already exited and AGENT_LAUNCH_RC is fully populated before round 1.
# The pre-#180 code resolved any non-zero-rc agent to `unavailable` on round 1 —
# before its verdict comment could propagate — so a multi-agent command-mode
# review could structurally degrade to whichever agent's verdict propagated
# fastest. The fix removes that short-circuit: a no-verdict agent keeps being
# polled REGARDLESS of rc until the (INV-43-scaled) window elapses; only the
# post-window sweep resolves `unavailable`. The window IS the propagation grace.
#
# This suite is four-pronged (the wrapper is too heavy to run end-to-end):
#   1. pure-decision harness for _classify_unresolved_agent (verdict wins over
#      rc; no verdict → keep, regardless of rc);
#   2. a LOOP regression harness that drives _run_verdict_poll_loop with the
#      verdict fetch + sleep + log stubbed — the mandatory #180 proof that a
#      non-zero-rc agent whose verdict lands on a later round is counted `pass`;
#   3. lib + wrapper source-of-truth greps (loop delegated to the lib; the
#      immediate short-circuit + grace array gone; the all-unavailable
#      discriminator left untouched);
#   4. doc-presence assertions for the INV-43 amendment + flow doc.
#
# Run: bash tests/unit/test-review-cli-exit-grace.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
POLL_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-poll.sh"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"
FLOW="$PROJECT_ROOT/docs/pipeline/review-agent-flow.md"
DESIGN="$PROJECT_ROOT/docs/designs/multi-agent-cli-exit-grace.md"
TESTCASES="$PROJECT_ROOT/docs/test-cases/multi-agent-cli-exit-grace.md"

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

assert_ge() {
  local desc="$1" actual="$2" floor="$3"
  if [[ "$actual" =~ ^[0-9]+$ ]] && [[ "$actual" -ge "$floor" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (actual=$actual, expected >= $floor)"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_grep() {
  local desc="$1" pattern="$2" file="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (matched: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

[[ -f "$POLL_LIB" ]] || {
  echo -e "  ${RED}FAIL${NC}: $POLL_LIB not found"
  FAIL=$((FAIL + 1))
}

# ---------------------------------------------------------------------------
echo "=== TC-CXG-DEC: _classify_unresolved_agent pure decision ==="
# ---------------------------------------------------------------------------
# _classify_unresolved_agent <verdict_body> <rc> — echoes pass | fail | keep.
# It NEVER echoes `unavailable`: window-expiry is the caller's responsibility.
if [[ -f "$POLL_LIB" ]]; then
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-poll.sh
  source "$POLL_LIB"
fi

if declare -F _classify_unresolved_agent >/dev/null 2>&1; then
  assert_eq "TC-CXG-DEC-01 PASS body, rc 0 → pass" \
    "pass" "$(_classify_unresolved_agent 'Review PASSED — LGTM' 0)"
  assert_eq "TC-CXG-DEC-02 PASS body, rc 1 → pass (#180: verdict wins over rc)" \
    "pass" "$(_classify_unresolved_agent 'Review PASSED — LGTM' 1)"
  assert_eq "TC-CXG-DEC-03 PASS body, rc 137 (SIGKILL) → pass (posted verdict still counts)" \
    "pass" "$(_classify_unresolved_agent 'Review PASSED' 137)"
  assert_eq "TC-CXG-DEC-04 findings body, rc 1 → fail (posted FAIL still counts, INV-40)" \
    "fail" "$(_classify_unresolved_agent 'Review findings: 1. fix X' 1)"
  assert_eq "TC-CXG-DEC-05 empty body, rc 0 → keep (clean keeps polling, unchanged)" \
    "keep" "$(_classify_unresolved_agent '' 0)"
  assert_eq "TC-CXG-DEC-06 empty body, rc 1 → keep (#180: non-zero rc no longer drops)" \
    "keep" "$(_classify_unresolved_agent '' 1)"
  assert_eq "TC-CXG-DEC-07 empty body, rc 137 → keep (keep polling until window expiry)" \
    "keep" "$(_classify_unresolved_agent '' 137)"
else
  echo -e "  ${RED}FAIL${NC}: _classify_unresolved_agent not defined — implement first"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXG-LOOP: _run_verdict_poll_loop regression (the #180 proof) ==="
# ---------------------------------------------------------------------------
# Drive the actual loop with the verdict fetch + sleep + log stubbed. There is
# no real-world field sample of the bug, so this loop-level test is the proof.
#
# The loop reads the wrapper's globals (AGENT_NAMES / AGENT_SESSION_IDS /
# AGENT_LAUNCH_RC / _VERDICT_POLL_ATTEMPTS) and fills AGENT_VERDICTS /
# AGENT_VERDICT_BODIES. We stub _fetch_agent_verdict_body to inject a
# round-dependent body, then apply the wrapper's post-window sweep and assert.
# Each scenario runs in a SUBSHELL so its stubs/state never leak.

# Re-source a FRESH copy of the lib, then no-op the timing + logging so the
# scenario is instant and quiet. Called inside each scenario subshell.
run_loop_scenario() {
  source "$POLL_LIB"
  sleep() { :; }
  log() { :; }
}

# Apply the wrapper's post-window sweep (verbatim contract) so the test asserts
# the same end-state the wrapper produces.
apply_post_window_sweep() {
  local _i
  for _i in "${!AGENT_NAMES[@]}"; do
    [[ -z "${AGENT_VERDICTS[$_i]}" ]] && AGENT_VERDICTS[$_i]="unavailable"
  done
}

if declare -F _run_verdict_poll_loop >/dev/null 2>&1; then

  # NOTE: the loop calls `_body=$(_fetch_agent_verdict_body …)` — command
  # substitution runs the stub in a SUBSHELL, so a stub that mutates a shell
  # variable won't persist it to the loop's scope. Round-dependent stubs
  # therefore track state through a temp FILE (which survives the subshell).
  _CXG_TMP="$(mktemp -d)"

  # --- TC-CXG-LOOP-01: THE #180 regression -------------------------------
  # Single agent, non-zero rc, verdict appears only on round >= 2.
  (
    run_loop_scenario
    _VERDICT_POLL_ATTEMPTS=6
    declare -a AGENT_NAMES=("agy")
    declare -a AGENT_SESSION_IDS=("sid-agy")
    declare -A AGENT_LAUNCH_RC=(["sid-agy"]=1)   # CLI exited NON-ZERO
    declare -a AGENT_VERDICTS=("")
    declare -a AGENT_VERDICT_BODIES=("")
    echo 0 > "$_CXG_TMP/round"
    # Verdict propagates only on round 2+ (comment-propagation lag). Round count
    # lives in a file because this runs inside a command-substitution subshell.
    _fetch_agent_verdict_body() {
      local _r; _r=$(< "$_CXG_TMP/round"); _r=$((_r + 1)); echo "$_r" > "$_CXG_TMP/round"
      if [[ "$_r" -ge 2 ]]; then echo "Review Agent: agy — Review PASSED"; fi
    }
    _run_verdict_poll_loop
    apply_post_window_sweep
    echo "${AGENT_VERDICTS[0]}"
  ) > /tmp/cxg_loop01.out
  assert_eq "TC-CXG-LOOP-01 non-zero rc + verdict on round 2 → pass (NOT dropped)" \
    "pass" "$(cat /tmp/cxg_loop01.out)"
  assert_ge "TC-CXG-LOOP-01b loop polled at least 2 rounds" "$(cat "$_CXG_TMP/round")" 2

  # --- TC-CXG-LOOP-02: non-zero rc, NEVER posts → unavailable at expiry ---
  (
    run_loop_scenario
    _VERDICT_POLL_ATTEMPTS=3   # tiny budget for a fast test
    declare -a AGENT_NAMES=("codex")
    declare -a AGENT_SESSION_IDS=("sid-codex")
    declare -A AGENT_LAUNCH_RC=(["sid-codex"]=1)
    declare -a AGENT_VERDICTS=("")
    declare -a AGENT_VERDICT_BODIES=("")
    _fetch_agent_verdict_body() { echo ""; }   # never a verdict
    _run_verdict_poll_loop
    apply_post_window_sweep
    echo "${AGENT_VERDICTS[0]}"
  ) > /tmp/cxg_loop02.out
  assert_eq "TC-CXG-LOOP-02 non-zero rc + no verdict by window-expiry → unavailable (terminal, unchanged)" \
    "unavailable" "$(cat /tmp/cxg_loop02.out)"

  # --- TC-CXG-LOOP-03: two non-zero-rc agents, B's verdict lands late -----
  (
    run_loop_scenario
    _VERDICT_POLL_ATTEMPTS=6
    declare -a AGENT_NAMES=("a" "b")
    declare -a AGENT_SESSION_IDS=("sid-a" "sid-b")
    declare -A AGENT_LAUNCH_RC=(["sid-a"]=1 ["sid-b"]=1)   # both non-zero
    declare -a AGENT_VERDICTS=("" "")
    declare -a AGENT_VERDICT_BODIES=("" "")
    echo 0 > "$_CXG_TMP/rb"
    _fetch_agent_verdict_body() {
      local _agent="$1" _rb
      if [[ "$_agent" == "a" ]]; then
        echo "Review Agent: a — Review PASSED"   # round 1
      else
        _rb=$(< "$_CXG_TMP/rb"); _rb=$((_rb + 1)); echo "$_rb" > "$_CXG_TMP/rb"
        [[ "$_rb" -ge 3 ]] && echo "Review Agent: b — Review PASSED"  # round 3
      fi
    }
    _run_verdict_poll_loop
    apply_post_window_sweep
    echo "${AGENT_VERDICTS[0]}|${AGENT_VERDICTS[1]}"
  ) > /tmp/cxg_loop03.out
  IFS='|' read -r _va _vb < /tmp/cxg_loop03.out
  assert_eq "TC-CXG-LOOP-03 agent A (verdict round 1) → pass" "pass" "$_va"
  assert_eq "TC-CXG-LOOP-03b agent B (verdict round 3, non-zero rc) → pass (NOT dropped for being slower)" \
    "pass" "$_vb"

  # --- TC-CXG-LOOP-04: clean rc, verdict round 1 (happy path) ------------
  (
    run_loop_scenario
    _VERDICT_POLL_ATTEMPTS=6
    declare -a AGENT_NAMES=("solo")
    declare -a AGENT_SESSION_IDS=("sid-solo")
    declare -A AGENT_LAUNCH_RC=(["sid-solo"]=0)   # clean exit
    declare -a AGENT_VERDICTS=("")
    declare -a AGENT_VERDICT_BODIES=("")
    _fetch_agent_verdict_body() { echo "Review Agent: solo — Review PASSED"; }
    _run_verdict_poll_loop
    apply_post_window_sweep
    echo "${AGENT_VERDICTS[0]}"
  ) > /tmp/cxg_loop04.out
  assert_eq "TC-CXG-LOOP-04 clean rc + verdict round 1 → pass (happy path)" \
    "pass" "$(cat /tmp/cxg_loop04.out)"

  # --- TC-CXG-LOOP-05: loop short-circuits once all resolved -------------
  # Budget is 6 but verdict lands round 1 → fetch must NOT be called a 2nd
  # round (the loop breaks after _all_resolved=1).
  (
    run_loop_scenario
    _VERDICT_POLL_ATTEMPTS=6
    declare -a AGENT_NAMES=("x")
    declare -a AGENT_SESSION_IDS=("sid-x")
    declare -A AGENT_LAUNCH_RC=(["sid-x"]=0)
    declare -a AGENT_VERDICTS=("")
    declare -a AGENT_VERDICT_BODIES=("")
    echo 0 > "$_CXG_TMP/fetches"
    _fetch_agent_verdict_body() {
      local _f; _f=$(< "$_CXG_TMP/fetches"); _f=$((_f + 1)); echo "$_f" > "$_CXG_TMP/fetches"
      echo "Review Agent: x — Review PASSED"
    }
    _run_verdict_poll_loop
  )
  assert_eq "TC-CXG-LOOP-05 loop short-circuits after all resolved (1 fetch, not 6)" \
    "1" "$(cat "$_CXG_TMP/fetches")"

  rm -f /tmp/cxg_loop0{1,2,3,4}.out 2>/dev/null || true
  rm -rf "$_CXG_TMP" 2>/dev/null || true
else
  echo -e "  ${RED}FAIL${NC}: _run_verdict_poll_loop not defined — implement first"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXG-LIB: lib-review-poll.sh structure ==="
# ---------------------------------------------------------------------------
assert_grep "TC-CXG-LIB-01 _classify_unresolved_agent defined" \
  '_classify_unresolved_agent\(\)' "$POLL_LIB"
assert_grep "TC-CXG-LIB-02 _classify_verdict_body defined (moved here from wrapper)" \
  '_classify_verdict_body\(\)' "$POLL_LIB"
assert_grep "TC-CXG-LIB-03 _run_verdict_poll_loop defined" \
  '_run_verdict_poll_loop\(\)' "$POLL_LIB"
assert_grep "TC-CXG-LIB-04 _fetch_agent_verdict_body defined (test override seam)" \
  '_fetch_agent_verdict_body\(\)' "$POLL_LIB"
assert_not_grep "TC-CXG-LIB-05 grace constant/resolver GONE (no _VERDICT_POLL_EXIT_GRACE)" \
  '_VERDICT_POLL_EXIT_GRACE' "$POLL_LIB"
if bash -n "$POLL_LIB" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-CXG-LIB-06 lib-review-poll.sh parses (bash -n)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CXG-LIB-06 lib-review-poll.sh has a syntax error"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXG-SRC: wrapper loop wiring (source-of-truth greps) ==="
# ---------------------------------------------------------------------------
assert_grep "TC-CXG-SRC-01 wrapper sources lib-review-poll.sh" \
  'source "\$\{LIB_DIR\}/lib-review-poll\.sh"' "$WRAPPER"
assert_grep "TC-CXG-SRC-02 wrapper calls _run_verdict_poll_loop (loop delegated to lib)" \
  '^_run_verdict_poll_loop$' "$WRAPPER"
# Regression: the immediate `rc -ne 0 → unavailable` short-circuit inside the
# poll loop must be GONE. Pre-#180 it was a literal construct:
#     if [[ "${AGENT_LAUNCH_RC[$_sid]:-1}" -ne 0 ]]; then
#       AGENT_VERDICTS[$_i]="unavailable"
# Note the `$_sid` index — DISTINCT from the all-unavailable discriminator,
# which uses `${AGENT_SESSION_IDS[$_i]}` and must stay (TC-CXG-SRC-07).
assert_not_grep "TC-CXG-SRC-03 no immediate AGENT_LAUNCH_RC[\$_sid]!=0 → unavailable short-circuit in the loop" \
  'AGENT_LAUNCH_RC\[\$_sid\]:-1\}" -ne 0' "$WRAPPER"
assert_not_grep "TC-CXG-SRC-04 per-agent grace array AGENT_EXIT_GRACE_LEFT GONE" \
  'AGENT_EXIT_GRACE_LEFT' "$WRAPPER"
assert_grep "TC-CXG-SRC-05 wrapper references #180 / INV-43 in the verdict-poll section" \
  '#180|INV-43' "$WRAPPER"
# TC-CXG-SRC-06: the post-window sweep is still the SINGLE terminal resolution
# point for a no-verdict agent (#180 — no early drop). Since #185 (INV-48) the
# sweep no longer hard-codes `="unavailable"`; it routes the no-verdict agent
# through `_classify_noverdict_agent <rc>`, which returns `unavailable` for every
# rc EXCEPT 124/137 (those become the `timed-out` deciding-FAIL veto). The #180
# contract — resolution happens ONLY at window-expiry, never mid-loop — is
# unchanged; only the terminal label is now rc-aware. Assert the sweep delegates
# to the classifier (the per-rc behavior is covered by test-review-agent-timeout.sh).
assert_grep "TC-CXG-SRC-06 post-window sweep resolves a no-verdict agent via _classify_noverdict_agent (single terminal point, #180; rc-aware since INV-48)" \
  'AGENT_VERDICTS\[\$_i\]=\$\(_classify_noverdict_agent' "$WRAPPER"
# The all-unavailable crash-vs-no-verdict discriminator (~line 1257) must stay
# byte-for-byte: it indexes AGENT_LAUNCH_RC via AGENT_SESSION_IDS[$_i] and maps
# a crashed agent (rc != 0) to AGENT_EXIT=1. #180 explicitly says leave it.
assert_grep "TC-CXG-SRC-07 all-unavailable discriminator (AGENT_SESSION_IDS index) UNTOUCHED" \
  'AGENT_SESSION_IDS\[\$_i\]\}\]:-1\}" -ne 0' "$WRAPPER"
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-CXG-SRC-08 autonomous-review.sh parses (bash -n)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-CXG-SRC-08 autonomous-review.sh has a syntax error"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CXG-DOC: documentation presence ==="
# ---------------------------------------------------------------------------
assert_grep "TC-CXG-DOC-01 invariants.md INV-43 documents no-early-drop + references #180" \
  '#180' "$INVARIANTS"
assert_grep "TC-CXG-DOC-02 review-agent-flow.md documents rc-no-short-circuit / propagation" \
  'short-circuit|propagat|#180' "$FLOW"
[[ -f "$DESIGN" ]] && { echo -e "  ${GREEN}PASS${NC}: TC-CXG-DOC-03 design doc present"; PASS=$((PASS + 1)); } || { echo -e "  ${RED}FAIL${NC}: TC-CXG-DOC-03 design doc missing"; FAIL=$((FAIL + 1)); }
[[ -f "$TESTCASES" ]] && { echo -e "  ${GREEN}PASS${NC}: TC-CXG-DOC-04 test-case doc present"; PASS=$((PASS + 1)); } || { echo -e "  ${RED}FAIL${NC}: TC-CXG-DOC-04 test-case doc missing"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo -e "  Passed: ${GREEN}${PASS}${NC}   Failed: ${RED}${FAIL}${NC}"
echo "============================================"
[[ "$FAIL" -eq 0 ]]
