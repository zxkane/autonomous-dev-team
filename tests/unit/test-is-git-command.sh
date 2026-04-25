#!/bin/bash
# test-is-git-command.sh — Unit tests for is_git_command subcommand match
#
# Verifies fix for issue #48 (minor): is_git_command should match the
# operation as a positional subcommand, not as a substring.
# Run: bash tests/unit/test-is-git-command.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# shellcheck source=/dev/null
source "$PROJECT_ROOT/skills/autonomous-common/hooks/lib.sh"

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
echo "=== TC-IGC-001..008: is_git_command subcommand matcher ==="
echo ""

# Matches
assert_match    "TC-IGC-001 plain git push"            push   "git push"
assert_match    "TC-IGC-002 git push with args"        push   "git push origin main"
assert_match    "TC-IGC-003 global flag before subcmd" push   "git -c user.email=x@y.z push"
assert_match    "TC-IGC-007 after && chain"            commit "cd /tmp && git commit -m 'x'"
assert_match    "commit with --amend"                  commit "git commit --amend"

# Non-matches
assert_no_match "TC-IGC-004 git log is not push"       push   "git log"
assert_no_match "TC-IGC-005 quoted mention in gh body" push   'gh issue create --body "see git push docs"'
assert_no_match "TC-IGC-006 echo with git push string" push   'echo "git push"'
assert_no_match "TC-IGC-008 git push-something token"  push   "git push-something"
assert_no_match "push doesn't match commit"            commit "git push"

# Two-token global flags must be skipped together, not one-token-at-a-time.
assert_match    "--git-dir two-token form"             push   "git --git-dir /tmp/x.git push"
assert_match    "--git-dir=attached form"              push   "git --git-dir=/tmp/x.git push"
assert_match    "--work-tree two-token form"           push   "git --work-tree /tmp/w push"
# Path after --git-dir must not be mistaken for the subcommand.
assert_no_match "--git-dir path alone is not push"     push   "git --git-dir /tmp/push"

# Array bounds: trailing -c with no value must not skip past the end.
assert_no_match "trailing -c with no value"            push   "git -c"
assert_no_match "trailing --git-dir with no value"     push   "git --git-dir"

# Summary
echo ""
echo "========================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
