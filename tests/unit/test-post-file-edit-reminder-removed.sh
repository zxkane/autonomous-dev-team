#!/bin/bash
# test-post-file-edit-reminder-removed.sh — guards removal of the
# post-file-edit-reminder hook (issue #51).
#
# The hook fired on every Write|Edit|MultiEdit PostToolUse and emitted a
# ~150-word boilerplate reminder. Issue #51 documents how this caused
# premature mid-task interruption and context dilution, and why the
# reminder is redundant with SKILL.md + the blocking hooks.
#
# This test asserts the hook and its registrations stay removed.
# Run: bash tests/unit/test-post-file-edit-reminder-removed.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}PASS${NC}: $1"; ((PASS++)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; ((FAIL++)); }

assert_missing_file() {
  local desc="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    pass "$desc"
  else
    fail "$desc (unexpected file at $path)"
  fi
}

assert_not_references() {
  local desc="$1" file="$2" needle="$3"
  if [[ ! -f "$file" ]]; then
    fail "$desc (missing $file)"
    return
  fi
  if ! grep -q "$needle" "$file"; then
    pass "$desc"
  else
    fail "$desc (found '$needle' in $file)"
  fi
}

assert_valid_json() {
  local desc="$1" file="$2"
  if [[ ! -f "$file" ]]; then
    fail "$desc (missing $file)"
    return
  fi
  if python3 -m json.tool < "$file" > /dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc ($file failed to parse as JSON)"
  fi
}

echo "=== TC-PFER-001: hook script is absent ==="
assert_missing_file \
  "post-file-edit-reminder.sh does not exist" \
  "$PROJECT_ROOT/skills/autonomous-common/hooks/post-file-edit-reminder.sh"

echo ""
echo "=== TC-PFER-002: no registration in .claude/settings.json ==="
assert_not_references \
  ".claude/settings.json does not reference post-file-edit-reminder" \
  "$PROJECT_ROOT/.claude/settings.json" \
  "post-file-edit-reminder"

echo ""
echo "=== TC-PFER-003: no registration in .kiro/agents/default.json ==="
assert_not_references \
  ".kiro/agents/default.json does not reference post-file-edit-reminder" \
  "$PROJECT_ROOT/.kiro/agents/default.json" \
  "post-file-edit-reminder"

echo ""
echo "=== TC-PFER-004: SKILL.md no longer registers the hook ==="
assert_not_references \
  "skills/autonomous-dev/SKILL.md does not reference post-file-edit-reminder" \
  "$PROJECT_ROOT/skills/autonomous-dev/SKILL.md" \
  "post-file-edit-reminder"

echo ""
echo "=== TC-PFER-005: settings files remain valid JSON ==="
assert_valid_json \
  ".claude/settings.json is valid JSON" \
  "$PROJECT_ROOT/.claude/settings.json"
assert_valid_json \
  ".kiro/agents/default.json is valid JSON" \
  "$PROJECT_ROOT/.kiro/agents/default.json"

echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
