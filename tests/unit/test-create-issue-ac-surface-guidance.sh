#!/bin/bash
# test-create-issue-ac-surface-guidance.sh — Regression for issue #457.
#
# Pins the agent-unwritable-surface advisory scan added to the create-issue
# skill so future doc rewrites cannot silently relax it. This extends the
# #273 advisory self-scan with a third axis: an AC can be pre-merge
# verifiable yet still stall forever if its verification surface (e.g. "in
# the PR body") is writable only by a maintainer/wrapper, not by the dev
# agent's scoped token (#234's two-token split). The scan flags that
# phrasing and suggests a scoped-token-writable rewrite ("as a PR comment").
#
# Static-grep test (mirrors the #273 harness: extract_section /
# assert_contains). Verifies anchors in two places — the SKILL.md Step 4
# region, and the new agent-writable-surface section in
# references/ac-verification.md.
#
# Run: bash tests/unit/test-create-issue-ac-surface-guidance.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_MD="$PROJECT_ROOT/skills/create-issue/SKILL.md"
ACV_MD="$PROJECT_ROOT/skills/create-issue/references/ac-verification.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Extract a section delimited by an exact start line and an end-marker regex.
# (Same contract as the #273 harness.) FIRST-match only.
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

assert_contains_ci() {
  local desc="$1" haystack="$2" needle="$3"
  local h n
  h=$(printf '%s' "$haystack" | tr '[:upper:]' '[:lower:]')
  n=$(printf '%s' "$needle"   | tr '[:upper:]' '[:lower:]')
  if [[ "$h" == *"$n"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle (ci): $needle"
    FAIL=$((FAIL + 1))
  fi
}

assert_file_exists() {
  local desc="$1" file="$2"
  if [[ -f "$file" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      missing file: $file"
    FAIL=$((FAIL + 1))
  fi
}

# ===================================================================
# Group A — SKILL.md Step 4 self-scan anchors
# ===================================================================
echo "=== TC-AC-SURFACE-001..006: SKILL.md Step 4 anchors ==="

assert_file_exists "TC-AC-SURFACE-000 SKILL.md exists" "$SKILL_MD"

step4_block=$(extract_section "$SKILL_MD" "### Step 4: Confirm with User" "^### ")

# TC-AC-SURFACE-001/002 anchor to strings that ONLY exist in the new paragraph,
# so scoping to the full Step 4 block (which also contains the pre-existing
# #273 paragraph) is safe here.
assert_contains_ci "TC-AC-SURFACE-001 Step 4 lists 'in (the )?PR (body|description|title)' phrasing" \
  "$step4_block" "PR (body|description|title)"

assert_contains "TC-AC-SURFACE-002 Step 4 lists 'PR metadata' phrasing" \
  "$step4_block" "PR metadata"

# TC-AC-SURFACE-003/004/005/012 assert wording ('advisory', 'as a PR comment',
# 'scoped token', the ac-verification.md cross-ref) that the pre-existing #273
# paragraph in the SAME Step 4 block ALSO carries — a codex review finding on
# this PR noted that scoping to step4_block alone would let these pass even if
# the NEW "Advisory agent-unwritable-surface self-scan" paragraph regressed.
# Scope explicitly to that paragraph (from its own heading up to the next
# paragraph boundary) so a regression there is caught.
new_para_block=$(printf '%s\n' "$step4_block" \
  | awk '/^\*\*Advisory agent-unwritable-surface self-scan\*\*/{f=1} f{print; if (/Do not hard-fail the draft on a match\.$/) exit}')

assert_contains_ci "TC-AC-SURFACE-003 new paragraph suggests rewording to 'as a PR comment'" \
  "$new_para_block" "as a PR comment"

assert_contains_ci "TC-AC-SURFACE-004 new paragraph explains WHY: scoped token cannot edit PR metadata" \
  "$new_para_block" "scoped token"

assert_contains_ci "TC-AC-SURFACE-005 new paragraph frames this axis as advisory, not a hard fail" \
  "$new_para_block" "warn the author (advisory, not blocking)"

skill_all=$(cat "$SKILL_MD")
assert_contains "TC-AC-SURFACE-006 SKILL.md links to references/ac-verification.md" \
  "$skill_all" "references/ac-verification.md"

# ===================================================================
# Group B — references/ac-verification.md agent-writable-surface anchors
# ===================================================================
echo
echo "=== TC-AC-SURFACE-007..012: references/ac-verification.md anchors ==="

assert_file_exists "TC-AC-SURFACE-007a ac-verification.md exists" "$ACV_MD"
acv_all=$(cat "$ACV_MD" 2>/dev/null)

assert_contains_ci "TC-AC-SURFACE-007b doc names the 'agent-writable' surface concept" \
  "$acv_all" "agent-writable"

assert_contains_ci "TC-AC-SURFACE-008a PR comment named as agent-writable" \
  "$acv_all" "PR comment"
assert_contains_ci "TC-AC-SURFACE-008b issue comment named as agent-writable" \
  "$acv_all" "issue comment"
assert_contains_ci "TC-AC-SURFACE-008c committed file named as agent-writable" \
  "$acv_all" "committed file"

assert_contains_ci "TC-AC-SURFACE-009a PR body named as maintainer-or-wrapper only" \
  "$acv_all" "PR body"
assert_contains_ci "TC-AC-SURFACE-009b PR title named as maintainer-or-wrapper only" \
  "$acv_all" "PR title"
assert_contains_ci "TC-AC-SURFACE-009c labels named as maintainer-or-wrapper only" \
  "$acv_all" "labels"
assert_contains_ci "TC-AC-SURFACE-009d milestone named as maintainer-or-wrapper only" \
  "$acv_all" "milestone"

assert_contains_ci "TC-AC-SURFACE-010 doc references the scoped-token reasoning (#234 two-token split)" \
  "$acv_all" "scoped token"

assert_contains_ci "TC-AC-SURFACE-011a canonical rewrite example names 'in PR body'" \
  "$acv_all" "in PR body"
assert_contains_ci "TC-AC-SURFACE-011b canonical rewrite example names 'as a PR comment'" \
  "$acv_all" "as a PR comment"

assert_contains "TC-AC-SURFACE-012 new paragraph cross-references the new §5 section" \
  "$new_para_block" "references/ac-verification.md"

# ===================================================================
# Group C — scan-scope regression (unchanged from #273)
# ===================================================================
echo
echo "=== TC-AC-SURFACE-013: scan scope unchanged ==="

assert_contains "TC-AC-SURFACE-013 Step 4 still scopes the scan to 'AC checkbox lines' only" \
  "$step4_block" "AC checkbox lines"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
