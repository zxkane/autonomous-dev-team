#!/bin/bash
# test-pr-review-bypass.sh — Unit tests for pr-review SHA binding
#
# Verifies fix for issue #48: state-manager.sh `check pr-review` must
# fail after a new commit, not just after 30 minutes.
# Run: bash tests/unit/test-pr-review-bypass.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE_MANAGER="$PROJECT_ROOT/skills/autonomous-common/hooks/state-manager.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected exit=$expected, actual=$actual)"
    ((FAIL++))
  fi
}

# Build an isolated git repo so CLAUDE_PROJECT_DIR points at it and state
# files land in a predictable place.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

(
  cd "$TMPDIR"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test"
  mkdir -p .claude/state
  echo "a" > a.txt
  git add a.txt
  git commit -q -m "initial"
) || { echo "Failed to init tmp repo"; exit 1; }

export CLAUDE_PROJECT_DIR="$TMPDIR"
STATE_DIR="$TMPDIR/.claude/state"

run_check() {
  local action="$1"
  ( cd "$TMPDIR" && "$STATE_MANAGER" check "$action" >/dev/null 2>&1; echo $? )
}

run_mark() {
  local action="$1"
  ( cd "$TMPDIR" && "$STATE_MANAGER" mark "$action" >/dev/null 2>&1 )
}

new_commit() {
  ( cd "$TMPDIR" && echo "$RANDOM" >> a.txt && git add a.txt && git commit -q -m "next" )
}

backdate_state() {
  local action="$1" minutes="$2"
  local state_file="$STATE_DIR/${action}.json"
  # Rewrite timestamp to N minutes in the past (UTC).
  local old_ts
  old_ts=$(date -u -d "$minutes minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || date -u -v-"$minutes"M +"%Y-%m-%dT%H:%M:%SZ")
  if command -v jq &>/dev/null; then
    jq --arg ts "$old_ts" '.timestamp = $ts' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  else
    sed -i.bak "s/\"timestamp\": \"[^\"]*\"/\"timestamp\": \"$old_ts\"/" "$state_file" && rm -f "$state_file.bak"
  fi
}

# ===========================================================================
echo ""
echo "=== TC-PRB-001: check pr-review passes when HEAD matches marked SHA ==="
echo ""
run_mark pr-review
exit_code=$(run_check pr-review)
assert_exit "check returns 0 immediately after mark" "0" "$exit_code"

# ===========================================================================
echo ""
echo "=== TC-PRB-002: check pr-review fails when HEAD advances ==="
echo ""
run_mark pr-review
new_commit
exit_code=$(run_check pr-review)
assert_exit "check returns 1 after new commit" "1" "$exit_code"
# State file should be removed so user can't cherry-pick it
if [[ ! -f "$STATE_DIR/pr-review.json" ]]; then
  echo -e "  ${GREEN}PASS${NC}: stale state file removed"
  ((PASS++))
else
  echo -e "  ${RED}FAIL${NC}: stale pr-review.json still present"
  ((FAIL++))
fi

# ===========================================================================
echo ""
echo "=== TC-PRB-003: check pr-review fails when timestamp > 30m old ==="
echo ""
run_mark pr-review
backdate_state pr-review 31
exit_code=$(run_check pr-review)
assert_exit "check returns 1 when state is 31 minutes old" "1" "$exit_code"

# ===========================================================================
echo ""
echo "=== TC-PRB-004: Non-pr-review actions remain time-based only ==="
echo ""
run_mark code-simplifier
new_commit
exit_code=$(run_check code-simplifier)
assert_exit "code-simplifier check still passes after new commit" "0" "$exit_code"

# ===========================================================================
echo ""
echo "=== TC-PRB-005: check pr-review fails when no state file exists ==="
echo ""
rm -f "$STATE_DIR/pr-review.json"
exit_code=$(run_check pr-review)
assert_exit "check returns 1 with no state file" "1" "$exit_code"

# ===========================================================================
echo ""
echo "=== TC-PRB-007: SHA binding enforced even without jq installed ==="
echo ""
# Simulate a system without jq by putting a stub earlier on PATH that
# makes `command -v jq` fail. The state file is written by the current
# jq-enabled mark, then check runs with jq hidden.
run_mark pr-review
HIDDEN_PATH=$(mktemp -d)
trap 'rm -rf "$TMPDIR" "$HIDDEN_PATH"' EXIT
# Create a PATH that contains only coreutils dirs, no jq.
JQ_BIN=$(command -v jq)
ORIG_PATH="$PATH"
# Build PATH without the directory containing jq.
JQ_DIR=$(dirname "$JQ_BIN")
NEW_PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v "^${JQ_DIR}\$" | tr '\n' ':')
NEW_PATH="${NEW_PATH%:}"
new_commit
exit_code=$(cd "$TMPDIR" && PATH="$NEW_PATH" "$STATE_MANAGER" check pr-review >/dev/null 2>&1; echo $?)
assert_exit "check rejects stale state even without jq" "1" "$exit_code"
PATH="$ORIG_PATH"

# ===========================================================================
echo ""
echo "=== TC-PRB-006: check pr-review fails when git_head is 'unknown' ==="
echo ""
# Write a state file manually with git_head="unknown"
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$STATE_DIR/pr-review.json" <<EOF
{
  "action": "pr-review",
  "timestamp": "$ts",
  "files": [],
  "git_head": "unknown",
  "branch": "main"
}
EOF
exit_code=$(run_check pr-review)
assert_exit "check returns 1 when stored git_head is 'unknown'" "1" "$exit_code"

# Summary
echo ""
echo "========================================"
echo -e "Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
echo "========================================"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
