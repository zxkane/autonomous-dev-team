#!/bin/bash
# test-lib-review-smoke.sh — Unit tests for the INV-64 pre-fan-out agent-smoke
# gate's pure decision functions (issue #224): lib-review-smoke.sh
# (_classify_smoke_gate / _smoke_evidence_reason / _classify_smoke_state).
#
# These are the pure decision halves of Phase A.5 — the parallel-subshell
# orchestration lives in autonomous-review.sh and is covered by the
# source-of-truth + stub-mode harness in test-autonomous-review-smoke-gate.sh.
# Mirrors the lib-review-aggregate.sh / lib-review-e2e.sh isolation tests.
#
# Run: bash tests/unit/test-lib-review-smoke.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-smoke.sh"

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

[[ -f "$LIB" ]] || { echo -e "  ${RED}FAIL${NC}: $LIB not found"; exit 1; }

# The lib sources lib-agent-smoke.sh → lib-agent.sh → lib-config.sh, which need a
# minimal env. Provide it (mirrors test-lib-agent-smoke.sh) with a temp HOME.
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/review-smoke-test-home-XXXXXX")
export REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane REPO_NAME=autonomous-dev-team
export PROJECT_ID=test-review-smoke PROJECT_DIR="$PROJECT_ROOT" GH_AUTH_MODE=token
export HOME="$TEST_HOME"
unset XDG_RUNTIME_DIR 2>/dev/null || true
cleanup() { rm -rf "$TEST_HOME" 2>/dev/null || true; }
trap cleanup EXIT

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-smoke.sh
source "$LIB"

# ---------------------------------------------------------------------------
echo "=== TC-REVIEW-SMOKE gate decision (_classify_smoke_gate truth table) ==="
# ---------------------------------------------------------------------------
assert_eq "TC-REVIEW-SMOKE-001 pass pass → pass" \
  "pass" "$(_classify_smoke_gate pass pass)"
assert_eq "TC-REVIEW-SMOKE-002 pass unavailable → pass (drop the unavailable)" \
  "pass" "$(_classify_smoke_gate pass unavailable)"
assert_eq "TC-REVIEW-SMOKE-003 unavailable unavailable → all-unavailable" \
  "all-unavailable" "$(_classify_smoke_gate unavailable unavailable)"
assert_eq "TC-REVIEW-SMOKE-004 pass fail → fail (any FAIL aborts)" \
  "fail" "$(_classify_smoke_gate pass fail)"
assert_eq "TC-REVIEW-SMOKE-005 fail unavailable → fail (FAIL dominates UNAVAILABLE)" \
  "fail" "$(_classify_smoke_gate fail unavailable)"
assert_eq "TC-REVIEW-SMOKE-006 unavailable fail pass → fail (FAIL dominates regardless of order)" \
  "fail" "$(_classify_smoke_gate unavailable fail pass)"
assert_eq "TC-REVIEW-SMOKE-007 single pass → pass" \
  "pass" "$(_classify_smoke_gate pass)"
assert_eq "TC-REVIEW-SMOKE-008 single unavailable → all-unavailable (degenerate single-agent)" \
  "all-unavailable" "$(_classify_smoke_gate unavailable)"
assert_eq "TC-REVIEW-SMOKE-009 single fail → fail" \
  "fail" "$(_classify_smoke_gate fail)"
assert_eq "TC-REVIEW-SMOKE-010 empty arg list → pass (defensive; LIST is never empty in prod)" \
  "pass" "$(_classify_smoke_gate)"
assert_eq "TC-REVIEW-SMOKE-011 unknown state token → fail (defensive — never silently pass)" \
  "fail" "$(_classify_smoke_gate pass weird)"

# ---------------------------------------------------------------------------
echo "=== TC-REVIEW-SMOKE evidence-reason extraction (_smoke_evidence_reason) ==="
# ---------------------------------------------------------------------------
assert_eq "TC-REVIEW-SMOKE-020 UNAVAILABLE quota reason extracted" \
  "quota-exhausted (Antigravity 429; resets in 2h)" \
  "$(_smoke_evidence_reason 'SMOKE agy UNAVAILABLE 3s reason=quota-exhausted (Antigravity 429; resets in 2h)')"
assert_eq "TC-REVIEW-SMOKE-021 FAIL config-error reason with rejected flag" \
  "config-error:--bad-flag" \
  "$(_smoke_evidence_reason 'SMOKE codex FAIL 1s reason=config-error:--bad-flag')"
assert_eq "TC-REVIEW-SMOKE-022 FAIL no-response reason kept verbatim" \
  "no-response (rc=1; nonce absent from CLI output)" \
  "$(_smoke_evidence_reason 'SMOKE kiro FAIL 0s reason=no-response (rc=1; nonce absent from CLI output)')"
assert_eq "TC-REVIEW-SMOKE-023 line with no reason= tail → empty (no over-claim)" \
  "" "$(_smoke_evidence_reason 'SMOKE agy PASS 2s')"
assert_eq "TC-REVIEW-SMOKE-024 empty input → empty" \
  "" "$(_smoke_evidence_reason '')"
# Multi-line capture: the evidence line followed by trailing CLI noise; only the
# SMOKE line's reason is returned.
_multi=$'some banner noise\nSMOKE agy UNAVAILABLE 3s reason=quota-exhausted\nmore trailing noise'
assert_eq "TC-REVIEW-SMOKE-025 multi-line capture → reason from the SMOKE line, ignoring noise" \
  "quota-exhausted" "$(_smoke_evidence_reason "$_multi")"

# ---------------------------------------------------------------------------
echo "=== TC-REVIEW-SMOKE per-member run (_classify_smoke_state, stubbed smoke_agent) ==="
# ---------------------------------------------------------------------------
# Stub smoke_agent to assert the rc→state mapping + evidence capture without a
# real CLI. _classify_smoke_state writes the state + evidence to sidecar files.
_state_harness() {
  # $1 = stub body (defines smoke_agent), $2 = agent, $3 = model
  local stub="$1" agent="$2" model="$3"
  local td; td=$(mktemp -d)
  (
    set -uo pipefail
    source "$LIB"
    eval "$stub"
    _classify_smoke_state "$agent" "$model" 5 "$td/state" "$td/evidence"
    echo "STATE=$(cat "$td/state" 2>/dev/null || echo MISSING)"
    echo "EVIDENCE=$(cat "$td/evidence" 2>/dev/null || echo MISSING)"
  )
  rm -rf "$td" 2>/dev/null || true
}

out=$(_state_harness 'smoke_agent() { echo "SMOKE claude PASS 2s reason=nonce-ok"; return 0; }' claude sonnet)
assert_eq "TC-REVIEW-SMOKE-030 rc 0 → state=pass" \
  "STATE=pass" "$(printf '%s\n' "$out" | grep '^STATE=')"
assert_eq "TC-REVIEW-SMOKE-030b evidence captured verbatim" \
  "EVIDENCE=SMOKE claude PASS 2s reason=nonce-ok" "$(printf '%s\n' "$out" | grep '^EVIDENCE=')"

out=$(_state_harness 'smoke_agent() { echo "SMOKE agy UNAVAILABLE 3s reason=quota-exhausted"; return 2; }' agy "Gemini 3.5 Flash (High)")
assert_eq "TC-REVIEW-SMOKE-031 rc 2 → state=unavailable" \
  "STATE=unavailable" "$(printf '%s\n' "$out" | grep '^STATE=')"

out=$(_state_harness 'smoke_agent() { echo "SMOKE codex FAIL 1s reason=config-error:--bad"; return 1; }' codex gpt-5.4)
assert_eq "TC-REVIEW-SMOKE-032 rc 1 → state=fail" \
  "STATE=fail" "$(printf '%s\n' "$out" | grep '^STATE=')"

# set -e discipline: a non-zero smoke_agent must NOT abort _classify_smoke_state
# before the sidecar write (the subshell inherits set -e). The state file must be
# written (not MISSING) even on a FAIL rc.
out=$(_state_harness 'set -e; smoke_agent() { echo "SMOKE kiro FAIL 0s reason=no-response"; return 1; }' kiro claude-sonnet-4.6)
assert_eq "TC-REVIEW-SMOKE-033 non-zero smoke_agent under set -e still writes the state sidecar" \
  "STATE=fail" "$(printf '%s\n' "$out" | grep '^STATE=')"

# ---------------------------------------------------------------------------
echo "=== TC-REVIEW-SMOKE source-of-truth (lib bash -n + shellcheck-shape) ==="
# ---------------------------------------------------------------------------
if bash -n "$LIB" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-REVIEW-SMOKE-049 bash -n lib clean"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-REVIEW-SMOKE-049 bash -n lib FAILED"; FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo -e "  ${GREEN}PASS: $PASS${NC}"
echo -e "  ${RED}FAIL: $FAIL${NC}"
[[ "$FAIL" -eq 0 ]] || exit 1
