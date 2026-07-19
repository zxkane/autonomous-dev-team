#!/bin/bash
# test-autonomous-review-per-agent-launcher.sh — issue #173 / INV-42.
#
# Per-agent launcher resolution layered on the INV-40 multi-agent review fan-out
# and the INV-41 per-agent model/extra-args resolution. Three pronged (the
# wrapper is too heavy to run end-to-end; mirrors
# test-autonomous-review-per-agent-model.sh):
#
#   1. Pure resolver harness: source lib-review-resolve.sh and drive
#      _resolve_review_agent_launcher over the normalization + precedence matrix.
#      Critically, this resolver does NOT fall back to the shared
#      AGENT_REVIEW_LAUNCHER (the shared launcher is claude-only by INV-38).
#   2. Fan-out branch harness: replicate the wrapper's three-branch launcher
#      decision and drive each branch (per-agent applied / claude keeps shared /
#      non-claude cleared / malformed → naked). Includes the #173 regression
#      (codex member's argv starts with the per-agent launcher, not zeroed).
#   3. Source-of-truth greps against autonomous-review.sh + the resolver lib +
#      autonomous.conf.example.
#
# Run: bash tests/unit/test-autonomous-review-per-agent-launcher.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
RESOLVE_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-resolve.sh"
CONF_EXAMPLE="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous.conf.example"

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
echo "=== TC-PAL-RES: _resolve_review_agent_launcher precedence (per-agent → empty) ==="
# ---------------------------------------------------------------------------
[[ -f "$RESOLVE_LIB" ]] || {
  echo -e "  ${RED}FAIL${NC}: lib-review-resolve.sh not found at $RESOLVE_LIB"
  echo "=== Summary ==="; echo "  PASS: $PASS"; echo "  FAIL: $((FAIL + 1))"; exit 1
}
# shellcheck source=/dev/null
source "$RESOLVE_LIB"

# Each case runs in a clean subshell so leftover env never bleeds across cases.
assert_eq "TC-PAL-RES-01 per-agent value returned" "bridge --" \
  "$(AGENT_REVIEW_LAUNCHER_CODEX='bridge --'; unset 'AGENT_REVIEW_LAUNCHER'; _resolve_review_agent_launcher codex)"
# The defining difference from the model resolver: shared launcher does NOT
# auto-apply. Only the shared key is set → resolver returns empty.
assert_eq "TC-PAL-RES-02 only shared set → empty (no shared fallback)" "" \
  "$(AGENT_REVIEW_LAUNCHER='cc-bridge --'; unset 'AGENT_REVIEW_LAUNCHER_CODEX'; _resolve_review_agent_launcher codex)"
assert_eq "TC-PAL-RES-03 explicit-empty per-agent → empty (no shared fallback)" "" \
  "$(AGENT_REVIEW_LAUNCHER='cc-bridge --'; AGENT_REVIEW_LAUNCHER_CODEX=''; _resolve_review_agent_launcher codex)"
assert_eq "TC-PAL-RES-04 normalized suffix wires gpt-5 → GPT_5" "x --" \
  "$(unset 'AGENT_REVIEW_LAUNCHER'; AGENT_REVIEW_LAUNCHER_GPT_5='x --'; _resolve_review_agent_launcher gpt-5)"
assert_eq "TC-PAL-RES-05 sibling agent with no key → empty" "" \
  "$(unset 'AGENT_REVIEW_LAUNCHER'; AGENT_REVIEW_LAUNCHER_CODEX='bridge --'; unset 'AGENT_REVIEW_LAUNCHER_KIRO'; _resolve_review_agent_launcher kiro)"
assert_eq "TC-PAL-RES-06 multi-token quoted value preserved verbatim" \
  $'bash -c \'source ~/.bash_aliases && codex "$@"\' --' \
  "$(AGENT_REVIEW_LAUNCHER_CODEX=$'bash -c \'source ~/.bash_aliases && codex "$@"\' --'; unset 'AGENT_REVIEW_LAUNCHER'; _resolve_review_agent_launcher codex)"

# ---------------------------------------------------------------------------
echo "=== TC-PAL-BR: fan-out branch behavior (applied / keep-claude / cleared / naked) ==="
# ---------------------------------------------------------------------------
# fanout_launcher_branch <agent> — emits the resulting AGENT_LAUNCHER_ARGV
# joined by spaces. AGENT_LAUNCHER_ARGV is pre-seeded by the caller to mimic the
# wrapper's rebind of the shared review launcher onto it.
fanout_launcher_branch() {
  local _agent="$1"
  _bind_review_agent_launcher_argv "$_agent" "test fan-out"
  printf '%s' "${AGENT_LAUNCHER_ARGV[*]:-}"
}

# TC-PAL-BR-01: per-agent launcher for a non-claude member is APPLIED.
out=$(
  unset AGENT_REVIEW_LAUNCHER
  AGENT_REVIEW_LAUNCHER_CODEX='echo CODEX_LAUNCHED --'
  AGENT_LAUNCHER_ARGV=(cc --)   # shared rebind sentinel
  fanout_launcher_branch codex
)
assert_eq "TC-PAL-BR-01 per-agent launcher applied (codex)" "echo CODEX_LAUNCHED --" "$out"

# TC-PAL-BR-02: claude member with no per-agent key KEEPS the shared launcher.
out=$(
  unset AGENT_REVIEW_LAUNCHER AGENT_REVIEW_LAUNCHER_CLAUDE
  AGENT_LAUNCHER_ARGV=(cc --)
  fanout_launcher_branch claude
)
assert_eq "TC-PAL-BR-02 claude keeps shared launcher (no per-agent key)" "cc --" "$out"

# TC-PAL-BR-03: non-claude member with no per-agent key is CLEARED (INV-38).
out=$(
  unset AGENT_REVIEW_LAUNCHER AGENT_REVIEW_LAUNCHER_KIRO
  AGENT_LAUNCHER_ARGV=(cc --)
  fanout_launcher_branch kiro
)
assert_eq "TC-PAL-BR-03 non-claude cleared (INV-38 zeroing)" "" "$out"

# TC-PAL-BR-04: per-agent launcher for a non-claude member bypasses INV-38.
out=$(
  unset AGENT_REVIEW_LAUNCHER
  AGENT_REVIEW_LAUNCHER_KIRO='wrap --'
  AGENT_LAUNCHER_ARGV=(cc --)
  fanout_launcher_branch kiro
)
assert_eq "TC-PAL-BR-04 per-agent launcher applied to non-claude (INV-38 bypassed)" "wrap --" "$out"

# TC-PAL-BR-05: malformed per-agent launcher → naked (empty) + ERROR log.
err=$(
  unset AGENT_REVIEW_LAUNCHER
  AGENT_REVIEW_LAUNCHER_CODEX='"(unterminated'
  AGENT_LAUNCHER_ARGV=(cc --)
  # Discard the function's stdout (the argv echo) and capture only its stderr
  # (the `log` ERROR line) by redirecting stderr→stdout AFTER stdout→/dev/null.
  fanout_launcher_branch codex 2>&1 >/dev/null
)
# The argv must be empty after a tokenize failure.
out=$(
  unset AGENT_REVIEW_LAUNCHER
  AGENT_REVIEW_LAUNCHER_CODEX='"(unterminated'
  AGENT_LAUNCHER_ARGV=(cc --)
  fanout_launcher_branch codex
)
assert_eq "TC-PAL-BR-05a malformed launcher → naked (empty argv)" "" "$out"
if [[ "$err" == *"failed to tokenize"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-PAL-BR-05b malformed launcher emits an ERROR log line"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-PAL-BR-05b expected a 'failed to tokenize' log line"
  echo "      stderr=[$err]"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo "=== TC-PAL-REG: #173 regression — codex argv starts with the launcher ==="
# ---------------------------------------------------------------------------
# Before the fix, the fan-out unconditionally zeroed AGENT_LAUNCHER_ARGV for any
# non-claude member, so the codex member would run NAKED and this assertion
# would FAIL. After the fix it carries the per-agent launcher. The companion
# kiro member (no per-agent key) must still be zeroed.
declare -a _codex_argv=()
declare -a _kiro_argv=()
# codex member
eval "$(
  unset AGENT_REVIEW_LAUNCHER AGENT_REVIEW_LAUNCHER_KIRO
  AGENT_REVIEW_AGENTS='kiro codex'
  AGENT_REVIEW_LAUNCHER_CODEX='echo CODEX_LAUNCHED --'
  AGENT_LAUNCHER_ARGV=(cc --)
  out=$(fanout_launcher_branch codex)
  printf '_codex_argv=(%s)\n' "$out"
)"
# kiro member
eval "$(
  unset AGENT_REVIEW_LAUNCHER AGENT_REVIEW_LAUNCHER_KIRO
  AGENT_REVIEW_AGENTS='kiro codex'
  AGENT_REVIEW_LAUNCHER_CODEX='echo CODEX_LAUNCHED --'
  AGENT_LAUNCHER_ARGV=(cc --)
  out=$(fanout_launcher_branch kiro)
  printf '_kiro_argv=(%s)\n' "$out"
)"
assert_eq "TC-PAL-REG-01a codex member's argv[0] is the launcher head" \
  "echo" "${_codex_argv[0]:-}"
assert_eq "TC-PAL-REG-01b codex member's argv carries CODEX_LAUNCHED" \
  "CODEX_LAUNCHED" "${_codex_argv[1]:-}"
assert_eq "TC-PAL-REG-01c kiro member (no key) still zeroed" \
  "" "${_kiro_argv[*]:-}"

# ---------------------------------------------------------------------------
echo "=== TC-PAL-SRC: source-of-truth greps ==="
# ---------------------------------------------------------------------------
assert_grep "TC-PAL-SRC-01 fan-out resolves per-agent launcher" \
  '_bind_review_agent_launcher_argv "\$_agent"' "$WRAPPER"
assert_grep "TC-PAL-SRC-02 fan-out tokenizes resolved launcher into AGENT_LAUNCHER_ARGV via eval" \
  'eval "AGENT_LAUNCHER_ARGV=\(\$per_agent_launcher\)"' "$RESOLVE_LIB"
# The eval MUST be guarded by a `bash -n -c` parse pre-check: a syntax error
# inside `eval` is NOT caught by `if ! eval` (it aborts the subshell), so the
# wrapper validates parseability first. Without this, a malformed per-agent
# launcher would silently kill the fan-out subshell (no log, no run_agent).
assert_grep "TC-PAL-SRC-02b eval is guarded by a bash -n parse pre-check" \
  'bash -n -c "AGENT_LAUNCHER_ARGV=\(\$per_agent_launcher\)"' "$RESOLVE_LIB"
assert_grep "TC-PAL-SRC-03 INV-38 non-claude zeroing survives as the elif fallback" \
  'elif \[\[ "\$name" != "claude" \]\]; then' "$RESOLVE_LIB"
assert_grep "TC-PAL-SRC-04 tokenize-failure path falls back to AGENT_LAUNCHER_ARGV=()" \
  'failed to tokenize' "$RESOLVE_LIB"
assert_grep "TC-PAL-SRC-05 _resolve_review_agent_launcher defined in lib-review-resolve.sh" \
  '_resolve_review_agent_launcher\(\)' "$RESOLVE_LIB"

# TC-PAL-SRC-06: the resolver MUST NOT reference the shared AGENT_REVIEW_LAUNCHER
# anywhere in its function body — the no-shared-fallback rule is the whole point
# (the shared launcher is claude-only by INV-38). We extract the function body
# and assert it contains no `AGENT_REVIEW_LAUNCHER` token that is NOT immediately
# followed by `_` (the per-agent suffixed var IS allowed; the bare shared var is
# not).
_fn_body=$(awk '/^_resolve_review_agent_launcher\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$RESOLVE_LIB")
if echo "$_fn_body" | grep -qE 'AGENT_REVIEW_LAUNCHER[^_A-Z]'; then
  echo -e "  ${RED}FAIL${NC}: TC-PAL-SRC-06 resolver body references the shared AGENT_REVIEW_LAUNCHER (should only use the suffixed per-agent var)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-PAL-SRC-06 resolver does NOT fall back to shared AGENT_REVIEW_LAUNCHER"
  PASS=$((PASS + 1))
fi

echo "=== TC-PAL-SRC-07: bash -n on autonomous-review.sh ==="
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: wrapper passes bash -n"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: wrapper fails bash -n"; FAIL=$((FAIL + 1))
fi

assert_grep "TC-PAL-SRC-08 conf.example documents AGENT_REVIEW_LAUNCHER_<AGENT>" \
  'AGENT_REVIEW_LAUNCHER_<AGENT>|AGENT_REVIEW_LAUNCHER_CODEX' "$CONF_EXAMPLE"

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
