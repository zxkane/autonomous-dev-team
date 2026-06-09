#!/bin/bash
# test-autonomous-review-per-agent-model.sh — issue #168 / INV-41.
#
# Per-agent model + extra-args resolution layered on the INV-40 multi-agent
# review fan-out. Two pronged (the wrapper is too heavy to run end-to-end):
#
#   1. Pure resolver harness: source lib-review-resolve.sh and drive
#      _review_agent_key_suffix / _resolve_review_agent_model /
#      _resolve_review_agent_extra_args over the normalization + precedence
#      truth table.
#   2. Source-of-truth greps against autonomous-review.sh: assert the fan-out
#      wires the resolver in (per-agent model passed to run_agent; per-agent
#      extra-args assigned to the var run_agent reads) without executing the
#      wrapper.
#
# Run: bash tests/unit/test-autonomous-review-per-agent-model.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
RESOLVE_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-resolve.sh"

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

# ---------------------------------------------------------------------------
echo "=== TC-PAM-SUF: _review_agent_key_suffix normalization ==="
# ---------------------------------------------------------------------------
[[ -f "$RESOLVE_LIB" ]] || {
  echo -e "  ${RED}FAIL${NC}: lib-review-resolve.sh not found at $RESOLVE_LIB"
  echo "=== Summary ==="; echo "  PASS: $PASS"; echo "  FAIL: $((FAIL + 1))"; exit 1
}
# shellcheck source=/dev/null
source "$RESOLVE_LIB"

assert_eq "TC-PAM-SUF-01 agy → AGY"                 "AGY"          "$(_review_agent_key_suffix agy)"
assert_eq "TC-PAM-SUF-02 kiro → KIRO"               "KIRO"         "$(_review_agent_key_suffix kiro)"
assert_eq "TC-PAM-SUF-03 claude → CLAUDE"           "CLAUDE"       "$(_review_agent_key_suffix claude)"
assert_eq "TC-PAM-SUF-04 claude-code → CLAUDE_CODE" "CLAUDE_CODE"  "$(_review_agent_key_suffix claude-code)"
assert_eq "TC-PAM-SUF-05 gpt.4o → GPT_4O"           "GPT_4O"       "$(_review_agent_key_suffix gpt.4o)"
assert_eq "TC-PAM-SUF-06 'a b' → A_B"               "A_B"          "$(_review_agent_key_suffix 'a b')"
assert_eq "TC-PAM-SUF-07 Agy → AGY (uppercased)"    "AGY"          "$(_review_agent_key_suffix Agy)"

# ---------------------------------------------------------------------------
echo "=== TC-PAM-MOD: _resolve_review_agent_model precedence ==="
# ---------------------------------------------------------------------------
# Each case runs in a clean subshell so leftover env never bleeds across cases.
assert_eq "TC-PAM-MOD-01 shared model, no per-agent key" "sonnet[1m]" \
  "$(AGENT_REVIEW_MODEL='sonnet[1m]'; unset 'AGENT_REVIEW_MODEL_KIRO'; _resolve_review_agent_model kiro)"
assert_eq "TC-PAM-MOD-02 per-agent key wins" "claude-sonnet-4.6" \
  "$(AGENT_REVIEW_MODEL='sonnet[1m]'; AGENT_REVIEW_MODEL_KIRO='claude-sonnet-4.6'; _resolve_review_agent_model kiro)"
assert_eq "TC-PAM-MOD-03 other agent keeps shared" "sonnet[1m]" \
  "$(AGENT_REVIEW_MODEL='sonnet[1m]'; AGENT_REVIEW_MODEL_KIRO='claude-sonnet-4.6'; unset 'AGENT_REVIEW_MODEL_AGY'; _resolve_review_agent_model agy)"
assert_eq "TC-PAM-MOD-04 shared empty, no per-agent key → empty" "" \
  "$(AGENT_REVIEW_MODEL=''; unset 'AGENT_REVIEW_MODEL_KIRO'; _resolve_review_agent_model kiro)"
assert_eq "TC-PAM-MOD-05 explicit-empty per-agent key falls back to shared" "sonnet[1m]" \
  "$(AGENT_REVIEW_MODEL='sonnet[1m]'; AGENT_REVIEW_MODEL_KIRO=''; _resolve_review_agent_model kiro)"
assert_eq "TC-PAM-MOD-06 normalized suffix wires claude-code key" "x" \
  "$(AGENT_REVIEW_MODEL=''; AGENT_REVIEW_MODEL_CLAUDE_CODE='x'; _resolve_review_agent_model claude-code)"

# ---------------------------------------------------------------------------
echo "=== TC-PAM-XA: _resolve_review_agent_extra_args precedence ==="
# ---------------------------------------------------------------------------
assert_eq "TC-PAM-XA-01 shared extra-args, no per-agent key" "--shared" \
  "$(AGENT_REVIEW_EXTRA_ARGS='--shared'; unset 'AGENT_REVIEW_EXTRA_ARGS_KIRO'; _resolve_review_agent_extra_args kiro)"
assert_eq "TC-PAM-XA-02 per-agent extra-args wins" "--trust-all-tools" \
  "$(AGENT_REVIEW_EXTRA_ARGS='--shared'; AGENT_REVIEW_EXTRA_ARGS_KIRO='--trust-all-tools'; _resolve_review_agent_extra_args kiro)"
assert_eq "TC-PAM-XA-03 both empty → empty" "" \
  "$(AGENT_REVIEW_EXTRA_ARGS=''; unset 'AGENT_REVIEW_EXTRA_ARGS_KIRO'; _resolve_review_agent_extra_args kiro)"
assert_eq "TC-PAM-XA-04 per-agent multi-token preserved" "--approval-mode yolo" \
  "$(AGENT_REVIEW_EXTRA_ARGS=''; AGENT_REVIEW_EXTRA_ARGS_AGY='--approval-mode yolo'; _resolve_review_agent_extra_args agy)"
assert_eq "TC-PAM-XA-05 explicit-empty per-agent falls back to shared" "--shared" \
  "$(AGENT_REVIEW_EXTRA_ARGS='--shared'; AGENT_REVIEW_EXTRA_ARGS_KIRO=''; _resolve_review_agent_extra_args kiro)"

# ---------------------------------------------------------------------------
echo "=== TC-PAM-SRC: source-of-truth greps against autonomous-review.sh ==="
# ---------------------------------------------------------------------------
assert_grep "TC-PAM-SRC-01 wrapper sources lib-review-resolve.sh" \
  'source .*lib-review-resolve\.sh' "$WRAPPER"
assert_grep "TC-PAM-SRC-02 fan-out resolves per-agent model" \
  '_resolve_review_agent_model' "$WRAPPER"
# The fan-out run_agent model arg is the resolved per-agent var, not a bare
# ${AGENT_REVIEW_MODEL:-sonnet} literal. We assert the resolved var is passed.
assert_grep "TC-PAM-SRC-03 run_agent uses resolved per-agent model var" \
  'run_agent .*"\$\{_agent_model:-sonnet\}"' "$WRAPPER"
assert_grep "TC-PAM-SRC-04 fan-out resolves per-agent extra-args" \
  '_resolve_review_agent_extra_args' "$WRAPPER"
# #212: the fan-out resolves the per-agent review extra-args ONCE into
# _resolved_review_extra_args, then aliases it onto BOTH the var run_agent reads
# (AGENT_DEV_EXTRA_ARGS, turn 1) AND the var resume_agent reads
# (AGENT_REVIEW_EXTRA_ARGS, codex's gather-only resume path — INV-51). Aliasing
# onto AGENT_DEV alone dropped the per-agent _CODEX override on resume.
assert_grep "TC-PAM-SRC-05pre resolver result captured once into _resolved_review_extra_args" \
  '_resolved_review_extra_args=.*_resolve_review_agent_extra_args' "$WRAPPER"
assert_grep "TC-PAM-SRC-05 resolved extra-args assigned to AGENT_DEV_EXTRA_ARGS (run_agent's var)" \
  'AGENT_DEV_EXTRA_ARGS="\$_resolved_review_extra_args"' "$WRAPPER"
assert_grep "TC-PAM-SRC-05b resolved extra-args ALSO assigned to AGENT_REVIEW_EXTRA_ARGS (resume_agent's var, #212)" \
  'AGENT_REVIEW_EXTRA_ARGS="\$_resolved_review_extra_args"' "$WRAPPER"
assert_grep "TC-PAM-SRC-06 _review_agent_key_suffix defined in lib-review-resolve.sh" \
  '_review_agent_key_suffix\(\)' "$RESOLVE_LIB"

echo "=== TC-PAM-SRC-07: bash -n on autonomous-review.sh ==="
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: wrapper passes bash -n"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: wrapper fails bash -n"; FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
