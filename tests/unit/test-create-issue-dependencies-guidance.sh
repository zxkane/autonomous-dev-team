#!/bin/bash
# test-create-issue-dependencies-guidance.sh — Regression for issue #120.
#
# Pins the tightened Dependencies guidance in the create-issue skill so
# future doc rewrites must preserve the warnings the dispatcher's
# check_deps_resolved depends on. Future authors will see the test fail
# if they relax the warning language back to the pre-fix state.
#
# Static-grep test: verifies expected strings exist in three places —
# the issue template placeholder, the SKILL.md Writing Guidelines
# bullet, and the SKILL.md Multi-Issue Creation step 2.
#
# Run: bash tests/unit/test-create-issue-dependencies-guidance.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_MD="$PROJECT_ROOT/skills/create-issue/SKILL.md"
TEMPLATES_MD="$PROJECT_ROOT/skills/create-issue/references/issue-templates.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Extract the Dependencies section from the feature template.
# The section starts with `## Dependencies` and ends at the next `## ` header.
extract_section() {
  local file="$1" start_marker="$2" end_marker_re="$3"
  awk -v start="$start_marker" -v end_re="$end_marker_re" '
    $0 == start { in_block=1; next }
    in_block && $0 ~ end_re { exit }
    in_block { print }
  ' "$file"
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle: $needle"
    echo "      first 200 chars of haystack:"
    echo "      $(echo "$haystack" | head -c 200)"
    FAIL=$((FAIL + 1))
  fi
}

# ===================================================================
# issue-templates.md Dependencies section
# ===================================================================
echo "=== TC-DEPS-001..005: issue-templates.md Dependencies block ==="

deps_block=$(extract_section "$TEMPLATES_MD" "## Dependencies" "^## ")

assert_contains "TC-DEPS-001 HTML comment opens with 'IMPORTANT: List ONLY'" \
  "$deps_block" "IMPORTANT: List ONLY"

assert_contains "TC-DEPS-002 mentions 'parses this section literally'" \
  "$deps_block" "parses this section literally"

assert_contains "TC-DEPS-003 mentions 'silently skipped'" \
  "$deps_block" "silently skipped"

assert_contains "TC-DEPS-004 explicit 'Do NOT list' anti-pattern enumeration" \
  "$deps_block" "Do NOT list"

assert_contains "TC-DEPS-005 'write exactly: None' fallback instruction" \
  "$deps_block" "write exactly: None"

# ===================================================================
# SKILL.md Writing Guidelines — Dependencies bullet
# ===================================================================
echo
echo "=== TC-DEPS-006..008: SKILL.md Writing Guidelines Dependencies bullet ==="

# Extract Writing Guidelines section
wg_block=$(extract_section "$SKILL_MD" "## Writing Guidelines" "^## ")

assert_contains "TC-DEPS-006 Writing Guidelines mentions 'parses this section literally'" \
  "$wg_block" "parses this section literally"

assert_contains "TC-DEPS-007 Writing Guidelines mentions 'silently skipped'" \
  "$wg_block" "silently skipped"

assert_contains "TC-DEPS-008 Writing Guidelines has explicit 'Do NOT include' enumeration" \
  "$wg_block" "Do NOT include"

# ===================================================================
# SKILL.md Multi-Issue Creation — step 2
# ===================================================================
echo
echo "=== TC-DEPS-009..010: SKILL.md Multi-Issue Creation step 2 ==="

mi_block=$(extract_section "$SKILL_MD" "## Multi-Issue Creation" "^## ")

assert_contains "TC-DEPS-009 Multi-Issue Creation step 2 says 'directly blocking'" \
  "$mi_block" "directly blocking"

assert_contains "TC-DEPS-010 Multi-Issue Creation step 2 warns every '#NNN' is a hard blocker" \
  "$mi_block" "hard blocker"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
