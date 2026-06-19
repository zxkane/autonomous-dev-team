#!/bin/bash
# test-is-git-command-quote-strip.sh — Regression tests for issue #266
#
# The quote-stripping `while` loops in is_git_command() fed an ERE match into a
# bash glob-pattern substitution (`${var/${BASH_REMATCH[0]}/ }`) UNQUOTED. When
# the matched region held a glob-significant char (`\` from an escaped quote, or
# `[`, `?`, `*`), the substitution replaced nothing, `stripped` stayed unchanged,
# and the `while [[ … =~ … ]]` test re-matched the same region forever — a
# 100%-CPU busy-loop that leaked orphan processes (PPID=1). The fix quotes the
# match (`${var/"${BASH_REMATCH[0]}"/ }`) so it is substituted literally.
#
# Run: bash tests/unit/test-is-git-command-quote-strip.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-common/hooks/lib.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# shellcheck source=/dev/null
source "$LIB"

# Run is_git_command in a FRESH bash under `timeout`. A pre-fix infinite loop
# would otherwise hang this harness itself, so the call must be in a separate,
# externally-killable process. The payload is passed via argv (not interpolated
# into the -c string) so quotes/backslashes/globs reach the function verbatim.
# Returns: 124 on timeout (loop), else the function's own exit (0 match / 1 no).
run_bounded() {
  local secs="$1" operation="$2" command="$3"
  # SC2016: the single-quoted body is intentional — $1/$2/$3 must expand in the
  # bash -c CHILD (from its positional args), not in this parent shell.
  # shellcheck disable=SC2016
  timeout "$secs" bash -c '
    source "$1"
    is_git_command "$2" "$3"
  ' _ "$LIB" "$operation" "$command"
}

# Bounded-time assertion: the call MUST finish before the timeout (rc != 124).
# We do not care whether it matches or not here — only that it terminates.
assert_bounded() {
  local desc="$1" operation="$2" command="$3"
  local rc
  run_bounded 2 "$operation" "$command"
  rc=$?
  if [[ $rc -ne 124 ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc (terminated, rc=$rc)"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (TIMED OUT — infinite loop; rc=124)"
    ((FAIL++))
  fi
}

# In-process correctness assertions (only safe once termination is proven).
assert_match() {
  local desc="$1" operation="$2" command="$3"
  if is_git_command "$operation" "$command"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected is_git_command $operation '$command' to match)"
    ((FAIL++))
  fi
}

assert_no_match() {
  local desc="$1" operation="$2" command="$3"
  if ! is_git_command "$operation" "$command"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected is_git_command $operation '$command' NOT to match)"
    ((FAIL++))
  fi
}

echo ""
echo "=== TC-IGC-QS-001..009: quote-strip infinite-loop regression (#266) ==="
echo ""

# Bounded-time: glob-significant chars inside quotes must NOT spin.
# TC-IGC-QS-001 is the exact payload that produced the 212 orphans.
assert_bounded  "TC-IGC-QS-001 escaped-quote payload terminates"  push   'git commit -m "fix \"x\" y"'
assert_bounded  "TC-IGC-QS-002 glob char class [x] terminates"    push   'git commit -m "fix [x]"'
assert_bounded  "TC-IGC-QS-003 glob ? terminates"                 push   'git commit -m "fix ?"'
assert_bounded  "TC-IGC-QS-004 glob * terminates"                 push   'git commit -m "fix *"'
assert_bounded  "TC-IGC-QS-008 single-quote glob payload"         push   "git commit -m 'fix [x] ?'"

# Correctness: quote-strip still works for the normal case.
assert_no_match "TC-IGC-QS-005 git verb only inside quoted arg"   push   'git commit -m "remember to git push later"'

# Correctness: genuine invocations are still gated (no regression).
assert_match    "TC-IGC-QS-006 genuine git push still matched"    push   "git push origin main"
assert_match    "TC-IGC-QS-007 genuine git commit still matched"  commit 'git commit -m "msg"'

# Whole-hook regression: the reproduction command must exit non-124 (#266 AC).
echo ""
HOOK="$PROJECT_ROOT/skills/autonomous-common/hooks/block-commit-outside-worktree.sh"
if [[ -f "$HOOK" ]]; then
  printf '%s' '{"tool_input":{"command":"git commit -m \"fix \\\"x\\\" y\""}}' \
    | timeout 4 bash "$HOOK" >/dev/null 2>&1
  hook_rc=$?
  if [[ $hook_rc -ne 124 ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-IGC-QS-009 block-commit hook exits promptly on repro (rc=$hook_rc)"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: TC-IGC-QS-009 block-commit hook TIMED OUT on repro (rc=124)"
    ((FAIL++))
  fi
else
  echo -e "  ${RED}FAIL${NC}: TC-IGC-QS-009 hook not found at $HOOK"
  ((FAIL++))
fi

# Summary
echo ""
echo "========================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
