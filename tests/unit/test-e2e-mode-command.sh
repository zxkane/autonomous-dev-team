#!/bin/bash
# test-e2e-mode-command.sh — Coverage for issue #161 (E2E_MODE field).
#
# Strategy: hybrid of source-of-truth grep against the wrapper (for prompt
# rendering branches) and config-validation invocation (for fail-loud
# branches). The wrapper supports a hidden `--validate-config-only` flag
# added in this PR that exits after validation without dispatching.
#
# Run: bash tests/unit/test-e2e-mode-command.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

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

# Minimum config the wrapper needs to reach E2E validation. Each test
# helper unsets E2E_* first so leaked parent-env values don't pollute.
_RUN_VALIDATE() {
  unset E2E_ENABLED E2E_MODE E2E_COMMAND E2E_COMMAND_TIMEOUT_SECONDS \
    E2E_COMMAND_PRE_HOOKS E2E_COMMAND_EVIDENCE_PARSER \
    E2E_PREVIEW_URL_PATTERN E2E_TEST_USER_EMAIL E2E_TEST_USER_PASSWORD \
    E2E_SCREENSHOT_UPLOAD
  export ISSUE_NUMBER=1 REPO=zxkane/test PROJECT_ID=test \
    REPO_OWNER=zxkane REPO_NAME=test PROJECT_DIR="$PROJECT_ROOT" \
    AGENT_CMD=claude AGENT_PERMISSION_MODE=bypassPermissions
  # Apply per-test overrides — each arg is "VAR=value" (value may contain spaces)
  while [[ $# -gt 0 ]]; do
    local kv="$1"
    local k="${kv%%=*}"
    local v="${kv#*=}"
    export "$k=$v"
    shift
  done
  bash "$WRAPPER" --validate-config-only 2>&1
}

assert_validate_fails() {
  local desc="$1" expected_pattern="$2"
  shift 2
  local output exit_code
  output=$(_RUN_VALIDATE "$@")
  exit_code=$?
  if [[ $exit_code -ne 0 ]] && echo "$output" | grep -qE "$expected_pattern"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (exit=$exit_code, output did not match: $expected_pattern)"
    echo "    output was: $(echo "$output" | head -3)"
    FAIL=$((FAIL + 1))
  fi
}

assert_validate_succeeds() {
  local desc="$1"
  shift
  local output exit_code
  output=$(_RUN_VALIDATE "$@")
  exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (exit=$exit_code)"
    echo "    output was: $(echo "$output" | head -3)"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "=== TC-E2E-MODE-001: E2E_ENABLED=true with E2E_MODE unset → fail-loud ==="
# ---------------------------------------------------------------------------
assert_validate_fails "wrapper exits non-zero with helpful E2E_MODE error" \
  "E2E_MODE.*(none|browser|command).*" \
  E2E_ENABLED=true

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-002: E2E_MODE=none silences E2E section ==="
# ---------------------------------------------------------------------------
# The wrapper renders the E2E block conditionally. With E2E_MODE=none (or
# unset entirely), neither block should appear in the wrapper's heredoc.
# Verified by checking the wrapper has explicit `case` branches that gate
# the block rendering on E2E_MODE.
assert_grep "wrapper has E2E_MODE case dispatch (the gate)" \
  'case[[:space:]]+"\$\{?E2E_MODE' "$WRAPPER"
assert_grep "wrapper has explicit 'none' branch in case" \
  '[[:space:]]+none\)' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-003: E2E_MODE=browser preserves existing block ==="
# ---------------------------------------------------------------------------
# Existing block header must remain reachable when E2E_MODE=browser.
assert_grep "browser-mode prompt header present" \
  "E2E Verification via Chrome DevTools MCP" "$WRAPPER"
assert_grep "browser branch in case statement" \
  '[[:space:]]+browser\)' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-004: E2E_MODE=command injects command-mode block ==="
# ---------------------------------------------------------------------------
assert_grep "command-mode prompt header present" \
  "E2E Verification via project command" "$WRAPPER"
assert_grep "command branch in case statement" \
  '[[:space:]]+command\)' "$WRAPPER"
assert_grep "command-mode prompt references E2E_COMMAND" \
  '\$\{?E2E_COMMAND[^_]' "$WRAPPER"
assert_grep "command-mode prompt references E2E_COMMAND_EVIDENCE_PARSER" \
  'E2E_COMMAND_EVIDENCE_PARSER' "$WRAPPER"
assert_grep "SHA-bound evidence marker present in wrapper" \
  'e2e-evidence: complete sha=' "$WRAPPER"
assert_grep "command-mode declares MANDATORY" \
  "E2E Verification via project command — MANDATORY" "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-005: E2E_MODE=command without E2E_COMMAND → fail-loud ==="
# ---------------------------------------------------------------------------
assert_validate_fails "wrapper names E2E_COMMAND as missing" \
  "E2E_COMMAND" \
  E2E_ENABLED=true E2E_MODE=command \
  'E2E_COMMAND_EVIDENCE_PARSER=bash scripts/x.sh'

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-006: E2E_MODE=command without evidence parser → fail-loud ==="
# ---------------------------------------------------------------------------
assert_validate_fails "wrapper names E2E_COMMAND_EVIDENCE_PARSER as missing" \
  "E2E_COMMAND_EVIDENCE_PARSER" \
  E2E_ENABLED=true E2E_MODE=command \
  'E2E_COMMAND=bash scripts/x.sh'

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-007: invalid E2E_MODE value → fail-loud ==="
# ---------------------------------------------------------------------------
assert_validate_fails "wrapper rejects unknown mode and lists accepted values" \
  "E2E_MODE.*(none.*browser.*command|browser.*command|command)" \
  E2E_ENABLED=true E2E_MODE=foo

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-008: PR_NUMBER substitution shape ==="
# ---------------------------------------------------------------------------
# Verify the wrapper substitutes ${PR_NUMBER} in E2E_COMMAND at render time.
# Source-of-truth grep: the wrapper must have the substitution machinery.
assert_grep "wrapper substitutes PR_NUMBER in E2E_COMMAND" \
  'E2E_COMMAND.*//.*PR_NUMBER|PR_NUMBER.*E2E_COMMAND' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-009: case-sensitivity — capitalized values rejected ==="
# ---------------------------------------------------------------------------
assert_validate_fails "E2E_MODE=Browser (capitalized) hits invalid-mode branch" \
  "invalid E2E_MODE" \
  E2E_ENABLED=true E2E_MODE=Browser
assert_validate_fails "E2E_MODE=COMMAND (uppercase) hits invalid-mode branch" \
  "invalid E2E_MODE" \
  E2E_ENABLED=true E2E_MODE=COMMAND

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-010: command-mode fields without E2E_MODE=command rejected ==="
# ---------------------------------------------------------------------------
# Catches the "operator filled in E2E_COMMAND but forgot E2E_MODE=command"
# footgun. Without this guard the fields are silently ignored.
assert_validate_fails "E2E_COMMAND set with E2E_MODE=none rejected" \
  "E2E_COMMAND.*set.*E2E_MODE" \
  E2E_MODE=none 'E2E_COMMAND=bash scripts/x.sh'
assert_validate_fails "E2E_COMMAND set with E2E_MODE=browser rejected" \
  "E2E_COMMAND.*set.*E2E_MODE" \
  E2E_MODE=browser 'E2E_COMMAND=bash scripts/x.sh'

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-011: PRE_HOOKS-unset substitution does not crash ==="
# ---------------------------------------------------------------------------
# Regression for set -u + ${VAR//pat/repl} on unset E2E_COMMAND_PRE_HOOKS.
# The substitution lines around line 388-394 must use :- defaults.
assert_grep "E2E_COMMAND_PRE_HOOKS substitution uses :- default" \
  'E2E_COMMAND_PRE_HOOKS:-' "$WRAPPER"
assert_grep "E2E_COMMAND substitution uses :- default" \
  'E2E_COMMAND:-' "$WRAPPER"
assert_grep "E2E_COMMAND_EVIDENCE_PARSER substitution uses :- default" \
  'E2E_COMMAND_EVIDENCE_PARSER:-' "$WRAPPER"
assert_grep "PR_NUMBER empty-guard before substitution" \
  '\[\[ -z "\$PR_NUMBER" \]\]' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-012: F1 fix — decision block branches on E2E_MODE ==="
# ---------------------------------------------------------------------------
# Before fixup: decision-block FAIL message said "screenshot evidence" for
# both browser and command mode, which would confuse the agent in
# command mode (no browser, no screenshots).
assert_grep "decision FAIL branch differentiates browser vs command" \
  'case "\$\{?E2E_MODE.*browser\)' "$WRAPPER"
assert_grep "command-mode FAIL message references log tail (not screenshots)" \
  'log tail.*evidence|tail of /tmp/e2e-' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-013: F2 fix — evidence marker requires SHA binding ==="
# ---------------------------------------------------------------------------
# Without SHA in the marker, stale evidence from an old commit could
# satisfy a re-review of new code. The wrapper instructs agent to
# emit and check the SHA-bearing form.
assert_grep "wrapper marker spec includes sha=\"...\"" \
  'e2e-evidence: complete sha=' "$WRAPPER"
assert_grep "wrapper instructs agent to bind to PR_HEAD_SHA" \
  'PR_HEAD_SHA' "$WRAPPER"
assert_grep "stale-evidence guard step present" \
  'stale-evidence|Stale-evidence' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-014: F3 fix — parser only on EXIT_CODE ∈ {0, 124} ==="
# ---------------------------------------------------------------------------
# Running the parser on a hard-failure log produces confusing crashes
# that mask the real failure. The prompt now gates parser invocation.
assert_grep "Step 4 gates parser on EXIT_CODE 0 or 124" \
  'EXIT_CODE.*-eq 0.*-eq 124' "$WRAPPER"
assert_grep "Step 5 has log-tail fallback for non-{0,124} exits" \
  'tail -50.*e2e-' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-015: F4 fix — unbraced \$PR_NUMBER rejected ==="
# ---------------------------------------------------------------------------
# Unbraced form silently renders empty (PR_NUMBER not exported until
# command-mode block, and the wrapper substitution only handles
# braced ${PR_NUMBER}). Catches the typo at validation time.
assert_validate_fails "unbraced \$PR_NUMBER in E2E_COMMAND rejected" \
  "unbraced.*PR_NUMBER" \
  E2E_ENABLED=true E2E_MODE=command \
  'E2E_COMMAND=bash scripts/x.sh $PR_NUMBER' \
  'E2E_COMMAND_EVIDENCE_PARSER=bash scripts/p.sh ${PR_NUMBER}'
# Braced form continues to validate clean
assert_validate_succeeds "braced \${PR_NUMBER} in E2E_COMMAND validates clean" \
  E2E_ENABLED=true E2E_MODE=command \
  'E2E_COMMAND=bash scripts/x.sh ${PR_NUMBER}' \
  'E2E_COMMAND_EVIDENCE_PARSER=bash scripts/p.sh ${PR_NUMBER}'

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-016: command-mode exports PR_NUMBER + PR_HEAD_SHA ==="
# ---------------------------------------------------------------------------
# Parser scripts need PR_HEAD_SHA at runtime to embed it in the marker.
assert_grep "wrapper exports PR_HEAD_SHA in command mode" \
  'export PR_HEAD_SHA' "$WRAPPER"
assert_grep "wrapper exports PR_NUMBER in command mode" \
  'export PR_NUMBER' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-017: F7 fix — Step 4b fetches full comment body via jq ==="
# ---------------------------------------------------------------------------
# Pre-fix: `gh pr view --jq '.comments[].body' | grep -F` returned only
# the marker LINE; agent couldn't actually use prior evidence in Step 6.
# Post-fix: jq filter returns the whole matching comment body.
assert_grep "Step 4b uses jq select(.body | contains(...)) form" \
  'comments\[\].*select.*\.body.*contains' "$WRAPPER"
assert_grep "Step 4b assigns full body to EVIDENCE (not EXISTING)" \
  'EVIDENCE=\\\$\(gh pr view' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-018: marker format consistency across docs + wrapper ==="
# ---------------------------------------------------------------------------
# All references to the evidence marker MUST include the SHA binding
# (F2 fix). Pre-fixup: SKILL.md and autonomous.conf.example used the
# old non-SHA marker — would lead project owners to write parsers that
# fail the SHA-matching idempotency guard.
SKILL="$PROJECT_ROOT/skills/autonomous-review/SKILL.md"
CONF="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous.conf.example"
REF="$PROJECT_ROOT/skills/autonomous-review/references/e2e-command-mode.md"
PIPELINE="$PROJECT_ROOT/docs/pipeline/review-agent-flow.md"

# Wrapper, SKILL.md, conf.example, ref doc, pipeline doc all reference the
# SHA-bound marker form. The non-SHA form should NOT appear except as
# part of a SHA-bound longer string.
for f in "$WRAPPER" "$SKILL" "$CONF" "$REF" "$PIPELINE"; do
  if grep -qE 'e2e-evidence:[[:space:]]*complete[[:space:]]*-->' "$f"; then
    echo -e "  ${RED}FAIL${NC}: $f contains pre-SHA marker form"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC}: $(basename "$f") uses SHA-bound marker"
    PASS=$((PASS + 1))
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-019: F6 fix — pipeline doc documents Step 4b ==="
# ---------------------------------------------------------------------------
# CLAUDE.md "Pipeline Documentation Authority" requires wrapper changes
# to update docs/pipeline/*.md in same PR. Step 4b was added in fixup
# 6a5d210; this test pins that the pipeline doc references it.
assert_grep "pipeline doc documents Step 4b stale-evidence guard" \
  '(4b|[Ss]tale-evidence)' "$PIPELINE"
assert_grep "pipeline doc explains parser-skip on hard failures" \
  'skip the parser|skips the parser|parser would be malformed' "$PIPELINE"
assert_grep "pipeline doc explains mode-aware decision FAIL message" \
  'mode-aware|screenshot.*log tail|log tail.*screenshot' "$PIPELINE"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-back-compat: absent-config path validates clean ==="
# ---------------------------------------------------------------------------
# E2E_ENABLED unset, E2E_MODE unset, E2E_ENABLED=false — all must validate.
assert_validate_succeeds "no-E2E config validates clean"

assert_validate_succeeds "E2E_ENABLED=false validates clean (no MODE needed)" \
  E2E_ENABLED=false

assert_validate_succeeds "E2E_MODE=none alone validates clean (no E2E_ENABLED needed)" \
  E2E_MODE=none

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-E2E-MODE-syntax: bash -n on wrapper ==="
# ---------------------------------------------------------------------------
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: wrapper passes bash -n"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: wrapper has syntax errors"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
