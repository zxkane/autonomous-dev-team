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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    echo "      haystack='${haystack:0:300}'"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      should NOT contain='$needle'"
    echo "      haystack='${haystack:0:300}'"
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
echo "=== TC-PAML: _resolve_review_agent_model_label honesty (issue #220) ==="
# ---------------------------------------------------------------------------
# The model LABEL (verdict trailer / Reviewed-HEAD / fan-out) must reflect what
# agy ACTUALLY ran. For an agy member whose wrapper-resolved id is NOT an
# `agy models` id, INV-50 drops `--model` and agy runs its settings.json default
# — so the label must NOT assert the dropped id. We stub _agy_known_model so the
# test is deterministic (no `agy models` shell-out). Stub return codes mirror
# lib-agent.sh::_agy_known_model: 0 = known, 1 = enumerated-but-unknown, 2 =
# enumeration unavailable.

# rc-1 stub: every model id is "unknown to agy" (the INV-50-drop case).
_stub_agy_unknown() { _agy_known_model() { return 1; }; }
# rc-0 stub: a specific id is the known agy model; everything else unknown.
_stub_agy_known_only() {
  local known="$1"
  eval "_agy_known_model() { [[ \"\$1\" == \"$known\" ]] && return 0 || return 1; }"
}
# rc-2 stub: `agy models` could not be enumerated (best-effort/can't-validate).
_stub_agy_enum_failed() { _agy_known_model() { return 2; }; }

# TC-PAML-01 — agy + non-agy shared id (claude-sonnet-4.6), enumerated-but-unknown
#   → label is the honest agy default, NOT the dropped id.
paml01=$(
  source "$RESOLVE_LIB"; _stub_agy_unknown
  AGENT_REVIEW_MODEL='claude-sonnet-4.6'; unset 'AGENT_REVIEW_MODEL_AGY'
  _resolve_review_agent_model_label agy
)
assert_contains "TC-PAML-01a label is an agy-default rendering" "agy default" "$paml01"
assert_not_contains "TC-PAML-01b label does NOT assert the dropped id" "claude-sonnet-4.6" "$paml01"

# TC-PAML-02 — agy WITH a valid AGENT_REVIEW_MODEL_AGY (a known agy id)
#   → the id is shown verbatim (no regression).
paml02=$(
  source "$RESOLVE_LIB"; _stub_agy_known_only 'Gemini 3.5 Flash (High)'
  AGENT_REVIEW_MODEL='claude-sonnet-4.6'; AGENT_REVIEW_MODEL_AGY='Gemini 3.5 Flash (High)'
  _resolve_review_agent_model_label agy
)
assert_eq "TC-PAML-02 valid agy id shown verbatim" "Gemini 3.5 Flash (High)" "$paml02"

# TC-PAML-03 — kiro honors --model → resolved id shown verbatim (no agy branch).
paml03=$(
  source "$RESOLVE_LIB"; _stub_agy_unknown
  AGENT_REVIEW_MODEL='claude-sonnet-4.6'
  _resolve_review_agent_model_label kiro
)
assert_eq "TC-PAML-03 kiro resolved id verbatim" "claude-sonnet-4.6" "$paml03"

# TC-PAML-04 — codex honors --model → resolved id verbatim.
paml04=$(
  source "$RESOLVE_LIB"; _stub_agy_unknown
  AGENT_REVIEW_MODEL='sonnet'
  _resolve_review_agent_model_label codex
)
assert_eq "TC-PAML-04 codex resolved id verbatim" "sonnet" "$paml04"

# TC-PAML-05 — claude honors --model → resolved id verbatim.
paml05=$(
  source "$RESOLVE_LIB"; _stub_agy_unknown
  AGENT_REVIEW_MODEL='sonnet[1m]'
  _resolve_review_agent_model_label claude
)
assert_eq "TC-PAML-05 claude resolved id verbatim" "sonnet[1m]" "$paml05"

# TC-PAML-06 — agy + enumeration UNAVAILABLE (rc 2) → generic 'agy default'
#   fail-safe (NEVER the wrong id), no crash.
paml06=$(
  source "$RESOLVE_LIB"; _stub_agy_enum_failed
  AGENT_REVIEW_MODEL='claude-sonnet-4.6'; unset 'AGENT_REVIEW_MODEL_AGY'
  _resolve_review_agent_model_label agy
)
assert_contains "TC-PAML-06a enum-unavailable degrades to agy default" "agy default" "$paml06"
assert_not_contains "TC-PAML-06b enum-unavailable never asserts the wrong id" "claude-sonnet-4.6" "$paml06"

# TC-PAML-07 — agy with _agy_known_model UNDEFINED (lib-agent.sh not sourced;
#   the isolation context the resolve-lib unit tests run in). Conservative:
#   render the generic agy default, never the possibly-wrong id.
paml07=$(
  source "$RESOLVE_LIB"
  unset -f _agy_known_model 2>/dev/null || true
  AGENT_REVIEW_MODEL='claude-sonnet-4.6'; unset 'AGENT_REVIEW_MODEL_AGY'
  _resolve_review_agent_model_label agy
)
assert_contains "TC-PAML-07a undefined validator degrades to agy default" "agy default" "$paml07"
assert_not_contains "TC-PAML-07b undefined validator never asserts the wrong id" "claude-sonnet-4.6" "$paml07"

# TC-PAML-08 — agy, no model configured at all (resolved empty → 'sonnet'
#   launch default), and 'sonnet' is not an agy id → label is agy default,
#   the dropped 'sonnet' default is not asserted.
paml08=$(
  source "$RESOLVE_LIB"; _stub_agy_unknown
  AGENT_REVIEW_MODEL=''; unset 'AGENT_REVIEW_MODEL_AGY'
  _resolve_review_agent_model_label agy
)
assert_contains "TC-PAML-08a no-model agy → agy default" "agy default" "$paml08"
assert_not_contains "TC-PAML-08b no-model agy does NOT assert 'sonnet'" "sonnet" "$paml08"

# TC-PAML-09 — case-insensitive agy name match (AGY / Agy still take the branch).
paml09u=$(
  source "$RESOLVE_LIB"; _stub_agy_unknown
  AGENT_REVIEW_MODEL='claude-sonnet-4.6'
  _resolve_review_agent_model_label AGY
)
paml09m=$(
  source "$RESOLVE_LIB"; _stub_agy_unknown
  AGENT_REVIEW_MODEL='claude-sonnet-4.6'
  _resolve_review_agent_model_label Agy
)
assert_contains "TC-PAML-09a AGY (upper) takes agy branch" "agy default" "$paml09u"
assert_contains "TC-PAML-09b Agy (mixed) takes agy branch" "agy default" "$paml09m"

# TC-PAML-10 — runs cleanly under set -euo pipefail, both command-subst AND bare.
paml10cs=$(
  set -euo pipefail
  source "$RESOLVE_LIB"; _stub_agy_unknown
  AGENT_REVIEW_MODEL='claude-sonnet-4.6'
  out=$(_resolve_review_agent_model_label agy)
  echo "rc=$?|$out"
)
assert_contains "TC-PAML-10a no abort under set -euo (command-subst)" "rc=0|" "$paml10cs"
paml10bare=$(
  set -euo pipefail
  source "$RESOLVE_LIB"; _stub_agy_unknown
  AGENT_REVIEW_MODEL='claude-sonnet-4.6'
  _resolve_review_agent_model_label agy >/dev/null
  echo "reached-after-bare-call rc=$?"
)
assert_contains "TC-PAML-10b bare call reaches next stmt under set -euo" "reached-after-bare-call rc=0" "$paml10bare"

# ---------------------------------------------------------------------------
echo "=== TC-PAML-FAN: _review_fanout_model_label honesty (INV-58 producer) ==="
# ---------------------------------------------------------------------------
# TC-PAML-FAN-01 — agy codex fleet, shared non-agy id, no _AGY key, rc-1 stub.
#   The agy member's label must be the honest default, NOT claude-sonnet-4.6.
fan01=$(
  source "$RESOLVE_LIB"; _stub_agy_unknown
  AGENT_REVIEW_MODEL='claude-sonnet-4.6'; unset 'AGENT_REVIEW_MODEL_AGY'
  _review_fanout_model_label agy codex
)
assert_contains "TC-PAML-FAN-01a fan-out diverges (models:)" "models:" "$fan01"
assert_contains "TC-PAML-FAN-01b agy member shows the honest default" "agy=agy default" "$fan01"
assert_contains "TC-PAML-FAN-01c codex member keeps its resolved id" "codex=claude-sonnet-4.6" "$fan01"

# TC-PAML-FAN-02 — agy codex fleet, valid AGENT_REVIEW_MODEL_AGY (known id),
#   codex on shared sonnet. The valid agy id is shown verbatim (no regression).
fan02=$(
  source "$RESOLVE_LIB"; _stub_agy_known_only 'Gemini 3.5 Flash (High)'
  AGENT_REVIEW_MODEL='sonnet'; AGENT_REVIEW_MODEL_AGY='Gemini 3.5 Flash (High)'
  _review_fanout_model_label agy codex
)
assert_contains "TC-PAML-FAN-02a agy shows valid id verbatim" "agy=Gemini 3.5 Flash (High)" "$fan02"
assert_contains "TC-PAML-FAN-02b codex shows shared sonnet" "codex=sonnet" "$fan02"

# TC-PAML-FAN-03 — kiro codex fleet, both shared claude-sonnet-4.6 (uniform, no
#   agy member) → uniform 'model:' line, unchanged.
fan03=$(
  source "$RESOLVE_LIB"; _stub_agy_unknown
  AGENT_REVIEW_MODEL='claude-sonnet-4.6'
  _review_fanout_model_label kiro codex
)
assert_eq "TC-PAML-FAN-03 uniform non-agy fleet unchanged" "model: claude-sonnet-4.6" "$fan03"

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

# ---------------------------------------------------------------------------
echo "=== TC-PAML-SRC: label-honesty wiring (source-of-truth, issue #220) ==="
# ---------------------------------------------------------------------------
# All three model-label producers must route through the honesty-aware
# _resolve_review_agent_model_label (NOT the bare _resolve_review_agent_model)
# so an agy member's INV-50-dropped id is rendered as the agy default.
assert_grep "TC-PAML-SRC-00 helper defined in lib-review-resolve.sh" \
  '_resolve_review_agent_model_label\(\)' "$RESOLVE_LIB"
# build_review_prompt's verdict-trailer model (_agent_model) comes from the label helper.
assert_grep "TC-PAML-SRC-01 verdict-trailer model uses the honesty-aware label helper" \
  '_agent_model=\$\(_resolve_review_agent_model_label' "$WRAPPER"
# The Reviewed-HEAD trailer model comes from the label helper.
assert_grep "TC-PAML-SRC-02 Reviewed-HEAD trailer model uses the honesty-aware label helper" \
  '_REVIEW_HEAD_MODEL="\$\(_resolve_review_agent_model_label' "$WRAPPER"
# The fan-out label helper renders each agent through the honesty-aware helper.
assert_grep "TC-PAML-SRC-03 fan-out label helper routes through _resolve_review_agent_model_label" \
  '_resolve_review_agent_model_label' "$RESOLVE_LIB"

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
