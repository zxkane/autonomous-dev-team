#!/bin/bash
# test-review-e2e-command-poll-budget.sh — issue #172 / INV-43.
#
# Multi-agent review must NOT drop the agent that actually runs the
# command-mode E2E. The drop had two timing mechanisms:
#   1. the verdict-poll budget was a fixed 30 s (seq 1 6), far below
#      E2E_COMMAND_TIMEOUT_SECONDS (default 3600 s);
#   2. the dispatcher-side stall window (REVIEW_NEAR_SUCCESS_WINDOW_SECONDS,
#      300 s) is smaller than the E2E, so the still-working review wrapper is
#      declared crashed and SIGTERMed mid-E2E (config/doc fix).
#
# This suite is three-pronged (the wrapper is too heavy to run end-to-end):
#   1. pure-logic harness for _resolve_verdict_poll_attempts (sourced from
#      lib-review-poll.sh in isolation, mirrors lib-review-aggregate.sh);
#   2. source-of-truth greps against autonomous-review.sh for the structural
#      pieces (resolver wired in, seq uses the var, reap step, prompt signal);
#   3. doc-presence assertions for the Fix-D documentation (AC 4).
#
# Run: bash tests/unit/test-review-e2e-command-poll-budget.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
POLL_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-poll.sh"
REF="$PROJECT_ROOT/skills/autonomous-review/references/e2e-command-mode.md"
CONF="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous.conf.example"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"
FLOW="$PROJECT_ROOT/docs/pipeline/review-agent-flow.md"

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

# ---------------------------------------------------------------------------
echo "=== TC-RPB-RES: _resolve_verdict_poll_attempts pure logic ==="
# ---------------------------------------------------------------------------
[[ -f "$POLL_LIB" ]] || {
  echo -e "  ${RED}FAIL${NC}: $POLL_LIB not found — implementation step required first"
  FAIL=$((FAIL + 1))
}

if [[ -f "$POLL_LIB" ]]; then
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-poll.sh
  source "$POLL_LIB"

  # Helper: run the resolver in a clean env so leaked parent E2E_* don't pollute.
  _resolve() {
    env -u E2E_MODE -u E2E_COMMAND_TIMEOUT_SECONDS \
      bash -c "source '$POLL_LIB'; $1; _resolve_verdict_poll_attempts"
  }

  assert_eq "TC-RPB-RES-01 E2E_MODE unset → 6 (legacy 30s)" \
    "6" "$(_resolve ':')"
  assert_eq "TC-RPB-RES-02 E2E_MODE=none → 6" \
    "6" "$(_resolve 'export E2E_MODE=none')"
  assert_eq "TC-RPB-RES-03 E2E_MODE=browser → 6" \
    "6" "$(_resolve 'export E2E_MODE=browser')"
  assert_ge "TC-RPB-RES-04 command + 3600s → >= ceil(3600/5)=720" \
    "$(_resolve 'export E2E_MODE=command E2E_COMMAND_TIMEOUT_SECONDS=3600')" 720
  assert_ge "TC-RPB-RES-05 command + 2700s → >= ceil(2700/5)=540" \
    "$(_resolve 'export E2E_MODE=command E2E_COMMAND_TIMEOUT_SECONDS=2700')" 540
  assert_ge "TC-RPB-RES-06 command + default timeout (3600) → >= 720" \
    "$(_resolve 'export E2E_MODE=command')" 720
  assert_ge "TC-RPB-RES-07 command + tiny timeout (10) → never below floor 6" \
    "$(_resolve 'export E2E_MODE=command E2E_COMMAND_TIMEOUT_SECONDS=10')" 6
  assert_eq "TC-RPB-RES-08 command + non-numeric timeout → 6 (defensive)" \
    "6" "$(_resolve 'export E2E_MODE=command E2E_COMMAND_TIMEOUT_SECONDS=abc')"
  assert_eq "TC-RPB-RES-09 command + 0 timeout → 6 (floor)" \
    "6" "$(_resolve 'export E2E_MODE=command E2E_COMMAND_TIMEOUT_SECONDS=0')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RPB-SRC: wrapper structure (source-of-truth greps) ==="
# ---------------------------------------------------------------------------
assert_grep "TC-RPB-SRC-01 wrapper sources lib-review-poll.sh" \
  'lib-review-poll\.sh' "$WRAPPER"
# The poll loop body moved into lib-review-poll.sh (_run_verdict_poll_loop, #180)
# so it is unit-testable round-by-round; the wrapper resolves the budget and
# calls the loop. Assert both halves: the wrapper wires the resolved var, and the
# loop (now in the lib) drives `seq 1 "$_VERDICT_POLL_ATTEMPTS"` (not hardcoded 6).
assert_grep "TC-RPB-SRC-02 wrapper wires the resolved attempts var (_VERDICT_POLL_ATTEMPTS=resolver)" \
  '_VERDICT_POLL_ATTEMPTS=\$\(_resolve_verdict_poll_attempts' "$WRAPPER"
assert_grep "TC-RPB-SRC-02b poll loop uses the resolved attempts var (not hardcoded 6)" \
  'seq 1 "\$_?VERDICT_POLL_ATTEMPTS"|seq 1 "\$\{_?VERDICT_POLL_ATTEMPTS\}"' "$POLL_LIB"
assert_grep "TC-RPB-SRC-03 resolver references E2E_COMMAND_TIMEOUT_SECONDS" \
  'E2E_COMMAND_TIMEOUT_SECONDS' "$POLL_LIB"
# The reaper lives in the lib (unit-testable in isolation against real setsid
# groups). It group-kills the AGENT'S setsid PGID, NOT the fan-out subshell PID.
assert_grep "TC-RPB-SRC-04 lib defines the fan-out reap helper" \
  '_reap_fanout_processes\(\)' "$POLL_LIB"
assert_grep "TC-RPB-SRC-05 reap helper is invoked at the wrapper call site (with PGID args)" \
  '_reap_fanout_processes "\$\{_AGENT_PGIDS\[@\]:-\}"' "$WRAPPER"
assert_grep "TC-RPB-SRC-06 reap uses negative-PID group kill (INV-23 semantics)" \
  'kill -[A-Z]+ -- "-\$_pgid"' "$POLL_LIB"
# C1 regression: the reaper must NOT group-kill the fan-out SUBSHELL PIDs
# (_fanout_pids) — those are NOT process-group leaders without job control, so
# `kill -- -<subshell_pid>` is inert and misses the real orphan. It must use the
# per-agent setsid PGIDs (_AGENT_PGIDS), captured from a per-agent PGID sidecar.
assert_grep "TC-RPB-SRC-06b wrapper captures per-agent setsid PGIDs into _AGENT_PGIDS" \
  '_AGENT_PGIDS\+=\("\$_pgid_val"\)' "$WRAPPER"
assert_grep "TC-RPB-SRC-06c subshell points AGENT_PID_FILE at a private per-agent PGID sidecar" \
  'AGENT_PID_FILE="\$\{_FANOUT_DIR\}/\$\{?_agent_session_id\}?\.pgid"' "$WRAPPER"
assert_not_grep "TC-RPB-SRC-06d reaper call does NOT pass the subshell PIDs (_fanout_pids)" \
  '_reap_fanout_processes "\$\{_fanout_pids' "$WRAPPER"
# INV-46 (#182) SUPERSEDED the per-agent E2E entirely: the E2E now runs ONCE in
# a wrapper lane before the fan-out, so build_review_prompt no longer receives a
# multi-agent E2E signal arg (it is 2-arg now) and the prompt no longer carries
# the sibling-evidence re-check (the single lane is the strong guarantee). These
# two assertions flip to the post-#182 contract.
assert_grep "TC-RPB-SRC-07 build_review_prompt is 2-arg (INV-46 dropped the multi-agent E2E signal)" \
  'build_review_prompt "\$_agent" "\$_agent_session_id"\)' "$WRAPPER"
assert_not_grep "TC-RPB-SRC-08 prompt no longer carries the per-agent sibling-evidence re-check (INV-46 single lane)" \
  'MULTI-AGENT NOTE \(INV-43\)|re-check .* sibling review agent has already posted' "$WRAPPER"
assert_grep "TC-RPB-SRC-09 wrapper references INV-43" \
  'INV-43' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RPB-REAP: _reap_fanout_processes behavioral (real setsid groups) ==="
# ---------------------------------------------------------------------------
# These spawn REAL setsid process groups and assert the reaper actually
# terminates them (the C1 review finding: structural greps alone let an inert
# reaper slip through green). Requires setsid (util-linux); skip cleanly if absent.
if [[ -f "$POLL_LIB" ]] && command -v setsid >/dev/null 2>&1; then
  # Spawn a setsid group leader running a long sleep; its PID == its PGID.
  setsid bash -c 'sleep 120' >/dev/null 2>&1 &
  _reap_test_pid=$!
  # Give setsid a beat to establish the new group.
  sleep 0.5
  if kill -0 -- "-$_reap_test_pid" 2>/dev/null; then
    # TC-RPB-REAP-01: reaper terminates a live setsid group passed by PGID.
    _reap_fanout_processes "$_reap_test_pid" >/dev/null 2>&1
    sleep 0.5
    if kill -0 -- "-$_reap_test_pid" 2>/dev/null; then
      echo -e "  ${RED}FAIL${NC}: TC-RPB-REAP-01 reaper did NOT terminate the live setsid group"
      kill -KILL -- "-$_reap_test_pid" 2>/dev/null || true
      FAIL=$((FAIL + 1))
    else
      echo -e "  ${GREEN}PASS${NC}: TC-RPB-REAP-01 reaper terminated the live setsid group"
      PASS=$((PASS + 1))
    fi
  else
    echo -e "  ${RED}FAIL${NC}: TC-RPB-REAP-01 could not establish a test setsid group (setup error)"
    kill -KILL -- "-$_reap_test_pid" 2>/dev/null || true
    FAIL=$((FAIL + 1))
  fi

  # TC-RPB-REAP-02: empty args → no-op, returns success (set -e safe).
  if _reap_fanout_processes >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC}: TC-RPB-REAP-02 empty args is a clean no-op"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-RPB-REAP-02 empty args returned non-zero"
    FAIL=$((FAIL + 1))
  fi

  # TC-RPB-REAP-03: non-numeric / already-dead PGID args are skipped, no error.
  if _reap_fanout_processes "abc" "0" "999999999" >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC}: TC-RPB-REAP-03 non-numeric / dead PGIDs skipped cleanly"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-RPB-REAP-03 non-numeric / dead PGIDs caused an error"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  SKIP: setsid not available — behavioral reap tests skipped"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RPB-REG: regression / back-compat ==="
# ---------------------------------------------------------------------------
assert_not_grep "TC-RPB-REG-01 no hardcoded seq 1 6 poll loop remains" \
  'for _poll_attempt in \$\(seq 1 6\)' "$WRAPPER"
assert_grep "TC-RPB-REG-02 _VERDICT_POLL_ATTEMPTS resolved via the resolver" \
  '_VERDICT_POLL_ATTEMPTS=\$\(_resolve_verdict_poll_attempts' "$WRAPPER"
assert_grep "TC-RPB-REG-03 _aggregate_review_verdicts call unchanged (no INV-40 regression)" \
  'AGGREGATE=\$\(_aggregate_review_verdicts' "$WRAPPER"
# 10 = the historical six call sites + the two INV-44 mergeable-gate block
# paths (#176) + the two INV-46 E2E-gate block paths (#182). INV-43 itself adds
# none; this pin guards against an accidental trailer added by the poll-budget
# change.
EMIT_COUNT=$(grep -cE '^\s*emit_verdict_trailer ' "$WRAPPER")
assert_eq "TC-RPB-REG-04 emit_verdict_trailer call count is 10 (6 legacy + 2 INV-44 gate + 2 INV-46 E2E gate)" \
  "10" "$EMIT_COUNT"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RPB-DOC: documentation (Fix D — AC 4) ==="
# ---------------------------------------------------------------------------
# DOC-01: the ref doc must name BOTH windows in the SAME multi-agent section.
assert_grep "TC-RPB-DOC-01 ref doc relates REVIEW_NEAR_SUCCESS_WINDOW_SECONDS to E2E_COMMAND_TIMEOUT_SECONDS" \
  'REVIEW_NEAR_SUCCESS_WINDOW_SECONDS' "$REF"
assert_grep "TC-RPB-DOC-02 ref doc documents the auto-scaled verdict-poll budget" \
  'verdict.poll|poll budget|poll window' "$REF"
# DOC-03: must be the NEW multi-agent caveat (INV-43), not just any pre-hook mention.
assert_grep "TC-RPB-DOC-03 ref doc documents the multi-agent duplicated-pre-hook caveat (INV-43)" \
  'INV-43' "$REF"
assert_grep "TC-RPB-DOC-04 invariants.md has an INV-43 entry" \
  '## INV-43' "$INVARIANTS"
assert_grep "TC-RPB-DOC-05 review-agent-flow.md references INV-43" \
  'INV-43|inv-43' "$FLOW"
# DOC-06: the conf cross-ref must mention BOTH window names together (the new note),
# not merely the pre-existing E2E_COMMAND_TIMEOUT_SECONDS field doc.
assert_grep "TC-RPB-DOC-06 autonomous.conf.example cross-references the two windows (#172/INV-43)" \
  '172|INV-43' "$CONF"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RPB-SRC-10: wrapper passes bash -n ==="
# ---------------------------------------------------------------------------
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: wrapper passes bash -n"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: wrapper has syntax errors"
  FAIL=$((FAIL + 1))
fi

if [[ -f "$POLL_LIB" ]] && bash -n "$POLL_LIB" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: lib-review-poll.sh passes bash -n"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: lib-review-poll.sh missing or has syntax errors"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
