#!/bin/bash
# test-autonomous-review-smoke-gate.sh — issue #224 / INV-64.
#
# Pre-fan-out agent-smoke gate (Phase A.5). Two-pronged (the wrapper is too heavy
# to run end-to-end, mirroring test-autonomous-review-sequential-e2e.sh):
#
#   1. source-of-truth greps against autonomous-review.sh: the Phase A.5 block is
#      wired AFTER the INV-46 E2E lane and BEFORE the fan-out loop, is default-off
#      gated, waits on collected PIDs (no bare wait), resolves per-agent
#      model/launcher, and the three branches (FAIL abort / all-unavailable /
#      pass-drop) do what the design requires;
#   2. a stub-mode harness that extracts and exercises the Phase A.5 decision
#      cascade (the pure gate over stubbed smoke states) to prove the mixed-fleet
#      drop, the FAIL abort, and the all-unavailable fall-through end-to-end.
#
# Run: bash tests/unit/test-autonomous-review-smoke-gate.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
SMOKE_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-smoke.sh"
CONF_EXAMPLE="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous.conf.example"
INVARIANTS="$PROJECT_ROOT/docs/pipeline/invariants.md"
FLOW="$PROJECT_ROOT/docs/pipeline/review-agent-flow.md"
DESIGN="$PROJECT_ROOT/docs/designs/review-smoke-gate.md"
TESTCASES="$PROJECT_ROOT/docs/test-cases/review-smoke-gate.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"; echo "      actual=  [$actual]"; FAIL=$((FAIL + 1))
  fi
}
assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"; FAIL=$((FAIL + 1))
  fi
}
assert_lt() {
  local desc="$1" a="$2" b="$3"
  if [[ "$a" =~ ^[0-9]+$ ]] && [[ "$b" =~ ^[0-9]+$ ]] && [[ "$a" -lt "$b" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected $a < $b)"; FAIL=$((FAIL + 1))
  fi
}

[[ -f "$WRAPPER" ]] || { echo -e "  ${RED}FAIL${NC}: $WRAPPER not found"; exit 1; }
[[ -f "$SMOKE_LIB" ]] || { echo -e "  ${RED}FAIL${NC}: $SMOKE_LIB not found"; exit 1; }

# ---------------------------------------------------------------------------
echo "=== TC-REVIEW-SMOKE wrapper wiring (source-of-truth) ==="
# ---------------------------------------------------------------------------
# TC-REVIEW-SMOKE-040: the wrapper sources lib-review-smoke.sh.
assert_grep "TC-REVIEW-SMOKE-040 wrapper sources lib-review-smoke.sh" \
  'source "\$\{LIB_DIR\}/lib-review-smoke\.sh"' "$WRAPPER"

# TC-REVIEW-SMOKE-041: Phase A.5 sits AFTER the INV-46 E2E command-lane call and
# BEFORE the fan-out `for _agent in "${REVIEW_AGENTS_LIST` loop. Anchor on the
# real Phase A.5 enable-gate line.
e2e_line=$(grep -nE '_run_command_e2e_lane "\$_E2E_RC_FILE"' "$WRAPPER" | head -1 | cut -d: -f1)
smoke_line=$(grep -nE 'PHASE A\.5: pre-fan-out agent-smoke gate' "$WRAPPER" | head -1 | cut -d: -f1)
fanout_line=$(grep -nE '^for _agent in "\$\{REVIEW_AGENTS_LIST' "$WRAPPER" | head -1 | cut -d: -f1)
if [[ -n "$e2e_line" && "$e2e_line" -gt 0 && -n "$smoke_line" && "$smoke_line" -gt 0 ]]; then
  assert_lt "TC-REVIEW-SMOKE-041a E2E lane precedes the Phase A.5 smoke block" "$e2e_line" "$smoke_line"
  assert_lt "TC-REVIEW-SMOKE-041b Phase A.5 smoke block precedes the fan-out loop" "$smoke_line" "${fanout_line:-0}"
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-SMOKE-041 could not locate the E2E lane / Phase A.5 anchors"
  FAIL=$((FAIL + 1))
fi

# TC-REVIEW-SMOKE-042: default-off gate — the block is entered only when
# REVIEW_SMOKE_ENABLED == "true".
assert_grep "TC-REVIEW-SMOKE-042 Phase A.5 gated on REVIEW_SMOKE_ENABLED==true (default-off)" \
  'if \[\[ "\$\{REVIEW_SMOKE_ENABLED:-false\}" == "true" \]\]; then' "$WRAPPER"

# TC-REVIEW-SMOKE-043 (regression pin against the #167-class hang): the smoke
# parallel loop collects each subshell PID and waits the COLLECTED PIDs — never a
# bare wait (which would also block on the gh-token-refresh-daemon + heartbeat).
assert_grep "TC-REVIEW-SMOKE-043a smoke loop collects each subshell PID (_smoke_pids+=(\$!))" \
  '_smoke_pids\+=\("?\$!"?\)' "$WRAPPER"
assert_grep "TC-REVIEW-SMOKE-043b smoke waits the COLLECTED PIDs (not bare wait)" \
  'wait "\$\{_smoke_pids\[@\]\}"' "$WRAPPER"
# The whole-wrapper no-bare-wait pin is owned by test-autonomous-review-multi-agent.sh
# (TC-MAR-SRC-09c); here we just confirm the smoke block uses the array form.

# TC-REVIEW-SMOKE-044: the smoke resolves each member's model + applies the same
# INV-38/INV-42 launcher treatment as the fan-out (the SAME launch path).
assert_grep "TC-REVIEW-SMOKE-044a smoke resolves the per-agent model (_resolve_review_agent_model)" \
  '_smoke_model=\$\(_resolve_review_agent_model "\$_smoke_agent"\)' "$WRAPPER"
assert_grep "TC-REVIEW-SMOKE-044b smoke applies the per-agent launcher resolver (INV-42)" \
  '_resolve_review_agent_launcher "\$_smoke_agent"' "$WRAPPER"
assert_grep "TC-REVIEW-SMOKE-044c smoke neutralizes the launcher for a non-claude member (INV-38)" \
  'elif \[\[ "\$_smoke_agent" != "claude" \]\]; then' "$WRAPPER"
# TC-REVIEW-SMOKE-044d (#224 review [P1]): the smoke MUST resolve THIS member's
# per-agent review EXTRA-ARGS and apply them before the smoke — exactly as the
# fan-out does — else smoke_agent's run_agent tokenizes the STALE dev args (or the
# conf-default review args), not the resolved per-agent review args the fan-out
# uses. Assert the smoke subshell calls the resolver AND assigns BOTH vars
# run_agent / the codex lane read (AGENT_DEV_EXTRA_ARGS + the AGENT_REVIEW_EXTRA_ARGS
# alias), mirroring the fan-out's extra-args handling.
assert_grep "TC-REVIEW-SMOKE-044d smoke resolves the per-agent review extra-args (_resolve_review_agent_extra_args)" \
  '_smoke_extra_args=\$\(_resolve_review_agent_extra_args "\$_smoke_agent"\)' "$WRAPPER"
assert_grep "TC-REVIEW-SMOKE-044e smoke assigns AGENT_DEV_EXTRA_ARGS from the resolved review extra-args" \
  'AGENT_DEV_EXTRA_ARGS="\$_smoke_extra_args"' "$WRAPPER"
assert_grep "TC-REVIEW-SMOKE-044f smoke assigns the AGENT_REVIEW_EXTRA_ARGS alias too (belt-and-suspenders)" \
  'AGENT_REVIEW_EXTRA_ARGS="\$_smoke_extra_args"' "$WRAPPER"
# The resolution must happen INSIDE the smoke subshell, BEFORE _classify_smoke_state
# (which invokes smoke_agent → run_agent → tokenizes AGENT_DEV_EXTRA_ARGS). Assert
# the extra-args assignment line precedes the _classify_smoke_state call.
extra_args_line=$(grep -nE 'AGENT_DEV_EXTRA_ARGS="\$_smoke_extra_args"' "$WRAPPER" | head -1 | cut -d: -f1)
classify_call_line=$(grep -nE '_classify_smoke_state "\$_smoke_agent"' "$WRAPPER" | head -1 | cut -d: -f1)
if [[ -n "$extra_args_line" && "$extra_args_line" -gt 0 && -n "$classify_call_line" && "$classify_call_line" -gt 0 ]]; then
  assert_lt "TC-REVIEW-SMOKE-044g smoke extra-args applied BEFORE _classify_smoke_state (so run_agent reads them)" \
    "$extra_args_line" "$classify_call_line"
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-SMOKE-044g could not locate the extra-args / classify anchors"
  FAIL=$((FAIL + 1))
fi

# TC-REVIEW-SMOKE-045: the FAIL-abort path posts a naming comment, emits a
# trailer, sets RESULT_PARSED=true (so the crash trap does not override the
# stay-reviewing decision), does NOT add pending-dev, and exits non-zero.
SMOKE_BLOCK=$(awk '/PHASE A\.5: pre-fan-out agent-smoke gate/,/^# Per-agent state captured for the collection step\./' "$WRAPPER")
if grep -qE 'Review aborted: pre-fan-out agent smoke FAILED' <<<"$SMOKE_BLOCK"; then
  echo -e "  ${GREEN}PASS${NC}: TC-REVIEW-SMOKE-045a FAIL path posts the naming abort comment"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-SMOKE-045a FAIL path missing the naming abort comment"; FAIL=$((FAIL + 1))
fi
if grep -qE 'emit_verdict_trailer "\$ISSUE_NUMBER" "\$REPO" "failed-non-substantive" "smoke-config-error"' <<<"$SMOKE_BLOCK"; then
  echo -e "  ${GREEN}PASS${NC}: TC-REVIEW-SMOKE-045b FAIL path emits the heartbeat-consistent trailer"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-SMOKE-045b FAIL path missing the verdict trailer"; FAIL=$((FAIL + 1))
fi
if grep -qE 'RESULT_PARSED=true' <<<"$SMOKE_BLOCK" && grep -qE '^[[:space:]]*exit 1' <<<"$SMOKE_BLOCK"; then
  echo -e "  ${GREEN}PASS${NC}: TC-REVIEW-SMOKE-045c FAIL path sets RESULT_PARSED=true + exits non-zero"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-SMOKE-045c FAIL path missing RESULT_PARSED=true / exit 1"; FAIL=$((FAIL + 1))
fi
# The FAIL branch must NOT add pending-dev (stay reviewing). The only
# `--add-label "pending-dev"` calls in the wrapper are the E2E gate + crash trap,
# NOT the smoke block.
if grep -qE 'add-label "pending-dev"' <<<"$SMOKE_BLOCK"; then
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-SMOKE-045d smoke block must NOT flip to pending-dev (stay reviewing)"; FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-REVIEW-SMOKE-045d smoke block does not flip to pending-dev (stays reviewing)"; PASS=$((PASS + 1))
fi

# TC-REVIEW-SMOKE-046: FAIL-abort happens BEFORE the fan-out — the `exit 1` in the
# smoke FAIL branch is upstream of the fan-out `for` loop.
abort_exit_line=$(grep -nE 'stays reviewing \(INV-64 smoke config-error abort\)' "$WRAPPER" | head -1 | cut -d: -f1)
if [[ -n "$abort_exit_line" && "$abort_exit_line" -gt 0 ]]; then
  assert_lt "TC-REVIEW-SMOKE-046 smoke FAIL abort precedes the fan-out loop (no fan-out on abort)" \
    "$abort_exit_line" "${fanout_line:-0}"
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-SMOKE-046 could not locate the smoke abort log line"
  FAIL=$((FAIL + 1))
fi

# TC-REVIEW-SMOKE-047: UNAVAILABLE-drop path rebuilds REVIEW_AGENTS_LIST to the
# survivors and the drop reason carries the `smoke:` prefix.
assert_grep "TC-REVIEW-SMOKE-047a pass branch rebuilds REVIEW_AGENTS_LIST to survivors" \
  'REVIEW_AGENTS_LIST=\("\$\{_smoke_survivors\[@\]\}"\)' "$WRAPPER"
assert_grep "TC-REVIEW-SMOKE-047b drop reason carries the smoke: prefix" \
  'smoke: ' "$WRAPPER"
# TC-REVIEW-SMOKE-047c (#228 INV-70): smoke-dropped members are emitted to the
# metrics stream BEFORE REVIEW_AGENTS_LIST shrinks — otherwise the post-fan-out
# metrics loop (iterating the surviving AGENT_NAMES) would never record their
# quota/auth drop. Assert the pass-branch emits both review_agent_run and
# agent_drop with phase=smoke, guarded observe-only.
# The emits are `\`-continued, so match the distinctive tokens (which land on the
# continuation line) rather than the whole statement on one line.
assert_grep "TC-REVIEW-SMOKE-047c smoke-drop emits review_agent_run" \
  'metrics_emit review_agent_run side=review "agent_name=\$\{REVIEW_AGENTS_LIST\[\$_si\]\}"' "$WRAPPER"
assert_grep "TC-REVIEW-SMOKE-047c2 smoke-drop run carries state=unavailable phase=smoke" \
  'state=unavailable phase=smoke' "$WRAPPER"
assert_grep "TC-REVIEW-SMOKE-047d smoke-drop emits agent_drop (smoke)" \
  'metrics_emit agent_drop side=review "agent_name=\$\{REVIEW_AGENTS_LIST\[\$_si\]\}"' "$WRAPPER"
assert_grep "TC-REVIEW-SMOKE-047d2 smoke-drop agent_drop carries taxonomy reason + phase=smoke" \
  'reason=\$\{_sm_class\}" phase=smoke' "$WRAPPER"
# The smoke-drop metrics emit must precede the list-shrink so it sees the dropped
# members (line order: the for-loop emit, then REVIEW_AGENTS_LIST=survivors). The
# `state=unavailable phase=smoke` token is unique to the smoke-drop run emit.
# Fixed-string greps (`-F`) so the lookup is grep-implementation-agnostic
# (ugrep chokes on the bracket/brace regex the assert_grep ERE path tolerates).
_emit_ln=$(grep -nF 'state=unavailable phase=smoke' "$WRAPPER" | head -1 | cut -d: -f1)
_shrink_ln=$(grep -nF 'REVIEW_AGENTS_LIST=("${_smoke_survivors[@]}")' "$WRAPPER" | head -1 | cut -d: -f1)
if [[ -n "$_emit_ln" && -n "$_shrink_ln" && "$_emit_ln" -lt "$_shrink_ln" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-REVIEW-SMOKE-047e smoke-drop metrics emit precedes the list-shrink"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-SMOKE-047e smoke-drop emit (${_emit_ln}) must precede list-shrink (${_shrink_ln})"; FAIL=$((FAIL + 1))
fi

# TC-REVIEW-SMOKE-048: all-unavailable falls through with the list UNCHANGED (no
# empty fan-out) so the existing all-unavailable fallback fires.
if grep -qE 'leave the list UNCHANGED and fall through' <<<"$SMOKE_BLOCK"; then
  echo -e "  ${GREEN}PASS${NC}: TC-REVIEW-SMOKE-048 all-unavailable leaves the list unchanged (no empty fan-out)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-SMOKE-048 all-unavailable handling note missing"; FAIL=$((FAIL + 1))
fi

# TC-REVIEW-SMOKE-049: bash -n + shellcheck-shape.
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-REVIEW-SMOKE-049a bash -n wrapper clean"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-SMOKE-049a bash -n wrapper FAILED"; FAIL=$((FAIL + 1))
fi
if bash -n "$SMOKE_LIB" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-REVIEW-SMOKE-049b bash -n lib clean"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-SMOKE-049b bash -n lib FAILED"; FAIL=$((FAIL + 1))
fi

# TC-REVIEW-SMOKE-050 (default-off regression): the smoke loop's smoke_agent call
# is INSIDE the REVIEW_SMOKE_ENABLED guard — assert the smoke_agent-invoking
# function (_classify_smoke_state) appears only within the guarded block, never at
# top level. Proxy: _classify_smoke_state is called inside SMOKE_BLOCK and the
# block opens with the enable-gate.
if grep -qE '_classify_smoke_state ' <<<"$SMOKE_BLOCK"; then
  echo -e "  ${GREEN}PASS${NC}: TC-REVIEW-SMOKE-050 smoke run (_classify_smoke_state) lives inside the REVIEW_SMOKE_ENABLED-gated block"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-SMOKE-050 _classify_smoke_state not found in the gated block"; FAIL=$((FAIL + 1))
fi

# TC-REVIEW-SMOKE-051: the smoke block posts NO verdict comment (post-verdict.sh)
# — the smoke must not pollute the INV-40 attribution window.
if grep -qE 'post-verdict' <<<"$SMOKE_BLOCK"; then
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-SMOKE-051 smoke block must NOT post a verdict comment"; FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-REVIEW-SMOKE-051 smoke block posts no verdict (no attribution-window pollution)"; PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo "=== TC-REVIEW-SMOKE config knobs (autonomous.conf.example) ==="
# ---------------------------------------------------------------------------
assert_grep "TC-REVIEW-SMOKE-052a conf documents REVIEW_SMOKE_ENABLED (default false)" \
  'REVIEW_SMOKE_ENABLED="false"' "$CONF_EXAMPLE"
assert_grep "TC-REVIEW-SMOKE-052b conf documents REVIEW_SMOKE_TIMEOUT_SECONDS (default 120)" \
  'REVIEW_SMOKE_TIMEOUT_SECONDS="120"' "$CONF_EXAMPLE"
assert_grep "TC-REVIEW-SMOKE-052c wrapper validates REVIEW_SMOKE_TIMEOUT_SECONDS at startup" \
  'REVIEW_SMOKE_TIMEOUT_SECONDS.*is not a positive coreutils-timeout value' "$WRAPPER"

# ---------------------------------------------------------------------------
echo "=== TC-REVIEW-SMOKE-060 stub-mode Phase A.5 decision cascade (E2E) ==="
# ---------------------------------------------------------------------------
# Exercise the real Phase A.5 decision cascade in isolation: source the smoke lib,
# stub smoke_agent per a fleet spec, run the gate + branch selection, and assert
# the surviving fan-out set / abort / fall-through. This proves the design
# end-to-end without the full wrapper's GH/auth scaffolding.
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/review-smoke-e2e-home-XXXXXX")
_cascade() {
  # $1 = stub body mapping agents→(echo line; return rc); $2.. = agent list
  local stub="$1"; shift
  env -i PATH="$PATH" HOME="$TEST_HOME" \
    REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane REPO_NAME=autonomous-dev-team \
    PROJECT_ID=test-review-smoke PROJECT_DIR="$PROJECT_ROOT" GH_AUTH_MODE=token \
    bash -c '
      set -uo pipefail
      source "'"$SMOKE_LIB"'"
      '"$stub"'
      declare -a LIST=('"$*"')
      declare -a STATES=()
      for a in "${LIST[@]}"; do
        td=$(mktemp -d)
        _classify_smoke_state "$a" sonnet 5 "$td/state" "$td/ev"
        STATES+=("$(cat "$td/state")")
        rm -rf "$td"
      done
      GATE=$(_classify_smoke_gate "${STATES[@]}")
      echo "STATES=${STATES[*]}"
      echo "GATE=$GATE"
      # Mirror the wrapper pass-branch drop to compute the surviving set.
      if [[ "$GATE" == "pass" ]]; then
        survivors=()
        for i in "${!LIST[@]}"; do
          [[ "${STATES[$i]}" == "unavailable" ]] || survivors+=("${LIST[$i]}")
        done
        echo "SURVIVORS=${survivors[*]}"
      fi
    '
}
# Stub: agy → UNAVAILABLE, kiro → PASS, codex → FAIL, claude → PASS.
STUB='smoke_agent() {
  case "$1" in
    agy)    echo "SMOKE agy UNAVAILABLE 3s reason=quota-exhausted"; return 2 ;;
    codex)  echo "SMOKE codex FAIL 1s reason=config-error:--bad"; return 1 ;;
    *)      echo "SMOKE $1 PASS 2s reason=nonce-ok"; return 0 ;;
  esac
}'

# Mixed fleet, one UNAVAILABLE + the rest PASS → gate pass, agy dropped.
out=$(_cascade "$STUB" claude kiro agy)
assert_eq "TC-REVIEW-SMOKE-060a mixed fleet (one UNAVAILABLE) → gate pass" \
  "GATE=pass" "$(printf '%s\n' "$out" | grep '^GATE=')"
assert_eq "TC-REVIEW-SMOKE-060b mixed fleet → agy dropped, survivors fan out" \
  "SURVIVORS=claude kiro" "$(printf '%s\n' "$out" | grep '^SURVIVORS=')"

# Fleet with a FAIL member → gate fail (abort, no survivors computed).
out=$(_cascade "$STUB" claude codex)
assert_eq "TC-REVIEW-SMOKE-060c fleet with a FAIL member → gate fail (abort)" \
  "GATE=fail" "$(printf '%s\n' "$out" | grep '^GATE=')"

# All-unavailable single-agent → all-unavailable fall-through.
STUB_ALL_UNAVAIL='smoke_agent() { echo "SMOKE $1 UNAVAILABLE 3s reason=quota-exhausted"; return 2; }'
out=$(_cascade "$STUB_ALL_UNAVAIL" agy)
assert_eq "TC-REVIEW-SMOKE-060d single-agent UNAVAILABLE → all-unavailable" \
  "GATE=all-unavailable" "$(printf '%s\n' "$out" | grep '^GATE=')"
rm -rf "$TEST_HOME" 2>/dev/null || true

# ---------------------------------------------------------------------------
echo "=== TC-REVIEW-SMOKE-070 #246 timeout→UNAVAILABLE propagates through the gate ==="
# ---------------------------------------------------------------------------
# The #246 win: a smoke TIMEOUT (smoke_agent rc 2, reason=timeout) is now an
# UNAVAILABLE state at the gate (NOT a FAIL), so a single slow Bedrock member is
# DROPPED and the review PROCEEDS on the survivors — instead of the pre-#246 FAIL
# that aborted the whole review. These cases stub smoke_agent to emit exactly the
# timeout-UNAVAILABLE shape lib-agent-smoke.sh now produces, and exercise the real
# `_classify_smoke_state` → `_classify_smoke_gate` propagation.
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/review-smoke-to-home-XXXXXX")
# Stub: codex → timeout-UNAVAILABLE (rc 2), every other agent → PASS. This is the
# motivating shape (a healthy codex with a one-off Bedrock slow-start in a fleet
# alongside a fast agy/claude).
STUB_TIMEOUT='smoke_agent() {
  case "$1" in
    codex) echo "SMOKE codex UNAVAILABLE 121s reason=timeout (no model response within 120s)"; return 2 ;;
    *)     echo "SMOKE $1 PASS 9s reason=nonce-ok"; return 0 ;;
  esac
}'
# TC-REVIEW-SMOKE-070: the timed-out member resolves to `unavailable` state (not
# `fail`) — the gate input is correct.
out=$(_cascade "$STUB_TIMEOUT" claude codex)
assert_eq "TC-REVIEW-SMOKE-070 codex smoke-timeout → unavailable state (not fail)" \
  "STATES=pass unavailable" "$(printf '%s\n' "$out" | grep '^STATES=')"

# TC-REVIEW-SMOKE-071: one member times out (→ unavailable) while another PASSes →
# gate PROCEEDS (pass), the timed-out member is dropped, the survivor fans out.
assert_eq "TC-REVIEW-SMOKE-071a one timed-out + one PASS → gate pass (review proceeds, no abort)" \
  "GATE=pass" "$(printf '%s\n' "$out" | grep '^GATE=')"
assert_eq "TC-REVIEW-SMOKE-071b timed-out codex dropped, survivor fans out" \
  "SURVIVORS=claude" "$(printf '%s\n' "$out" | grep '^SURVIVORS=')"

# TC-REVIEW-SMOKE-072: ALL members time out → all-unavailable terminal path (the
# INV-40 fallback), NOT an empty fan-out and NOT a FAIL abort.
STUB_ALL_TIMEOUT='smoke_agent() { echo "SMOKE $1 UNAVAILABLE 121s reason=timeout (no model response within 120s)"; return 2; }'
out=$(_cascade "$STUB_ALL_TIMEOUT" claude codex agy)
assert_eq "TC-REVIEW-SMOKE-072a all members timed out → all-unavailable (no empty fan-out)" \
  "GATE=all-unavailable" "$(printf '%s\n' "$out" | grep '^GATE=')"
assert_eq "TC-REVIEW-SMOKE-072b all-timeout states are all unavailable" \
  "STATES=unavailable unavailable unavailable" "$(printf '%s\n' "$out" | grep '^STATES=')"

# TC-REVIEW-SMOKE-073: a GENUINE config FAIL alongside a timed-out member still
# aborts — the timeout reclassification does NOT weaken the FAIL→abort path for a
# real config break (config-error wins; the bare timeout is the only thing relaxed).
STUB_FAIL_PLUS_TIMEOUT='smoke_agent() {
  case "$1" in
    codex)  echo "SMOKE codex UNAVAILABLE 121s reason=timeout (no model response within 120s)"; return 2 ;;
    kiro)   echo "SMOKE kiro FAIL 2s reason=auth-failed"; return 1 ;;
    *)      echo "SMOKE $1 PASS 9s reason=nonce-ok"; return 0 ;;
  esac
}'
out=$(_cascade "$STUB_FAIL_PLUS_TIMEOUT" claude codex kiro)
assert_eq "TC-REVIEW-SMOKE-073 genuine FAIL + timed-out member → gate fail (abort preserved)" \
  "GATE=fail" "$(printf '%s\n' "$out" | grep '^GATE=')"
rm -rf "$TEST_HOME" 2>/dev/null || true

# ---------------------------------------------------------------------------
echo "=== TC-REVIEW-SMOKE docs (INV-64 + flow + design + test-cases) ==="
# ---------------------------------------------------------------------------
assert_grep "TC-REVIEW-SMOKE-061a INV-64 entry in invariants.md" \
  '## INV-64' "$INVARIANTS"
assert_grep "TC-REVIEW-SMOKE-061b review-agent-flow.md documents Phase A.5 / INV-64" \
  'INV-64|Phase A\.5|smoke gate' "$FLOW"
assert_grep "TC-REVIEW-SMOKE-061c design doc present" \
  'INV-64' "$DESIGN"
assert_grep "TC-REVIEW-SMOKE-061d test-cases doc present" \
  'TC-REVIEW-SMOKE' "$TESTCASES"

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo -e "  ${GREEN}PASS: $PASS${NC}"
echo -e "  ${RED}FAIL: $FAIL${NC}"
[[ "$FAIL" -eq 0 ]] || exit 1
