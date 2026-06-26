#!/bin/bash
# test-create-issue-ac-verification-guidance.sh — Regression for issue #273.
#
# Pins the AC-verification-surface guidance in the create-issue skill so future
# doc rewrites must preserve the loop-prevention language. The guidance teaches
# issue authors to separate PR/CI/preview-verifiable acceptance criteria from
# genuinely post-merge/prod-only ones, to NAME the verification surface, and to
# split a true post-merge AC into a NON-blocking, NON-autonomous follow-up — so
# the autonomous dev/review loop is never handed a blocking criterion it cannot
# satisfy pre-merge (a known driver of non-terminating dev<->review cycles).
#
# Static-grep test (mirrors the #120 harness: extract_section / assert_contains).
# Verifies anchors in four places — the NEW references/ac-verification.md, the
# SKILL.md Step 1 / Writing Guidelines / Step 4 regions, and the issue-templates
# bug+feature Acceptance Criteria sections.
#
# IMPORTANT (count assertions): extract_section is FIRST-match. Once the bug
# template ALSO carries `## Acceptance Criteria` / `## Dependencies`, a naive
# section extraction would silently pin only the feature one. The TC-ACV-016/017
# count assertions guard the parity fix by requiring each header to appear TWICE.
#
# Run: bash tests/unit/test-create-issue-ac-verification-guidance.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_MD="$PROJECT_ROOT/skills/create-issue/SKILL.md"
TEMPLATES_MD="$PROJECT_ROOT/skills/create-issue/references/issue-templates.md"
ACV_MD="$PROJECT_ROOT/skills/create-issue/references/ac-verification.md"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Extract a section delimited by an exact start line and an end-marker regex.
# (Same contract as the #120 harness.) FIRST-match only.
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

# Case-insensitive variant for prose anchors whose casing may drift.
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

assert_count() {
  local desc="$1" file="$2" pattern="$3" want="$4" got
  got=$(grep -cE "$pattern" "$file")
  if [[ "$got" -eq "$want" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc (count=$got)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      pattern: $pattern  want: $want  got: $got"
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
# Group A — references/ac-verification.md
# ===================================================================
echo "=== TC-ACV-001..010: references/ac-verification.md anchors ==="

assert_file_exists "TC-ACV-000 ac-verification.md exists" "$ACV_MD"
acv_all=$(cat "$ACV_MD" 2>/dev/null)

assert_contains "TC-ACV-001a rubric names 'pre-merge verifiable'" \
  "$acv_all" "pre-merge verifiable"
assert_contains "TC-ACV-001b rubric names 'not pre-merge verifiable'" \
  "$acv_all" "not pre-merge verifiable"

assert_contains_ci "TC-ACV-002a author must name the surface" \
  "$acv_all" "name the"
assert_contains_ci "TC-ACV-002b expected evidence" \
  "$acv_all" "expected evidence"

assert_contains "TC-ACV-003a reuse existing PR-preview path" \
  "$acv_all" "PR-preview"
assert_contains_ci "TC-ACV-003b same code path" \
  "$acv_all" "same code path"

assert_contains_ci "TC-ACV-004 split: create the follow-up FIRST" \
  "$acv_all" "follow-up issue first"

assert_contains_ci "TC-ACV-005a follow-up must NOT be autonomous: 'do NOT add'" \
  "$acv_all" "do NOT add"
assert_contains "TC-ACV-005b follow-up rule mentions 'autonomous'" \
  "$acv_all" "autonomous"

assert_contains_ci "TC-ACV-006a reference under Out of Scope, NEVER Dependencies" \
  "$acv_all" "do NOT list it under"
assert_contains "TC-ACV-006b cross-warning names 'Dependencies'" \
  "$acv_all" "Dependencies"

assert_contains "TC-ACV-007a hedged loop-driver warning: 'known driver'" \
  "$acv_all" "known driver"
assert_contains "TC-ACV-007b loop wording: 'non-terminating'" \
  "$acv_all" "non-terminating"

assert_contains "TC-ACV-008a no-auto-close clarification present" \
  "$acv_all" "no-auto-close"
assert_contains_ci "TC-ACV-008b no-auto-close still fails the review gate" \
  "$acv_all" "fails the review gate"

assert_contains "TC-ACV-009 worked Example 1 (reframe to PR-preview E2E)" \
  "$acv_all" "Example 1"
assert_contains "TC-ACV-010 worked Example 2 (split to non-blocking follow-up)" \
  "$acv_all" "Example 2"

# ===================================================================
# Group B — SKILL.md anchors
# ===================================================================
echo
echo "=== TC-ACV-011..015: SKILL.md anchors ==="

# Step 1 region: from '### Step 1' to the next '### ' header.
step1_block=$(extract_section "$SKILL_MD" "### Step 1: Understand the Request" "^### ")
assert_contains "TC-ACV-011 Step 1 adds per-AC 'pre-merge verifiable' classification prompt" \
  "$step1_block" "pre-merge verifiable"

# Step 1 must apply the classification to BOTH issue types, not just features —
# a bug report can otherwise ship a blocking prod-only AC and recreate the loop
# (regression for the [P1] review finding on #273).
assert_contains_ci "TC-ACV-011b Step 1 states the classification applies to bugs too" \
  "$step1_block" "applies to **both** issue"

# TC-ACV-011c must guard the BUG-clarify bullet SPECIFICALLY — a region-wide count
# is too loose (the feature bullet alone already contains the phrase twice, so a
# `>= 2` over the whole Step 1 region stays green even if the bug bullet is
# reverted — the exact [P1] regression). Scope the assertion to the bug sub-block
# (from `**For bugs, clarify:**` up to the `Ask 2-3` line) and require the phrase
# there directly, so deleting the bug bullet fails this test.
bug_block=$(printf '%s\n' "$step1_block" \
  | awk '/\*\*For bugs, clarify/{f=1; next} /^Ask 2-3/{f=0} f')
assert_contains "TC-ACV-011c bug-clarify block ITSELF carries the pre-merge classification" \
  "$bug_block" "pre-merge verifiable"

# TC-ACV-011d: the bug-clarify prompt must classify EACH criterion, not just ask
# for a single "how will the fix be verified" plan — bug issues commonly carry
# multiple ACs, so a per-criterion prompt is what stops a prod-only criterion from
# slipping through unclassified (regression for the second [P1] on #273).
assert_contains_ci "TC-ACV-011d bug-clarify prompt is PER-criterion (not a single verification plan)" \
  "$bug_block" "for each acceptance criterion"

# Writing Guidelines section.
wg_block=$(extract_section "$SKILL_MD" "## Writing Guidelines" "^## ")
assert_contains "TC-ACV-012a Writing Guidelines has an 'AC verification surface' bullet" \
  "$wg_block" "verification surface"
assert_contains_ci "TC-ACV-012b Writing Guidelines bullet says name the surface" \
  "$wg_block" "name the"

# Step 4 region.
step4_block=$(extract_section "$SKILL_MD" "### Step 4: Confirm with User" "^### ")
assert_contains_ci "TC-ACV-013a Step 4 advisory self-scan directive" \
  "$step4_block" "advisory"
assert_contains "TC-ACV-013b Step 4 scans 'AC checkbox lines' only" \
  "$step4_block" "AC checkbox lines"
assert_contains "TC-ACV-014a Step 4 lists 'after merge' phrase" \
  "$step4_block" "after merge"
assert_contains "TC-ACV-014b Step 4 lists 'in production' phrase" \
  "$step4_block" "in production"
assert_contains_ci "TC-ACV-014c Step 4 lists a long-tail token (soak/rollout)" \
  "$step4_block" "soak"

# Ref-doc link anywhere in SKILL.md.
skill_all=$(cat "$SKILL_MD")
assert_contains "TC-ACV-015 SKILL.md links to references/ac-verification.md" \
  "$skill_all" "references/ac-verification.md"

# ===================================================================
# Group C — issue-templates.md (parity fix + both AC notes)
# ===================================================================
echo
echo "=== TC-ACV-016..020: issue-templates.md anchors ==="

# Count assertions guard the bug-template parity fix: each header must now
# appear in BOTH templates (feature + bug) => exactly 2.
assert_count "TC-ACV-016 '## Acceptance Criteria' appears in both templates" \
  "$TEMPLATES_MD" '^## Acceptance Criteria' 2
assert_count "TC-ACV-017 '## Dependencies' appears in both templates" \
  "$TEMPLATES_MD" '^## Dependencies' 2

# TC-ACV-023: the bug template must ALSO have an '## Out of Scope' section — the
# split-to-follow-up note tells authors to reference a non-blocking post-merge
# follow-up under `## Out of Scope`, so that section must actually exist in the bug
# template (it previously jumped straight from AC to Dependencies). With the feature
# template's existing section, '## Out of Scope' must now appear in BOTH => exactly 2
# (regression for the second [P1] on #273: guidance pointing at a non-existent
# section nudges authors back toward AC/Dependencies, the loop-causing outcomes).
assert_count "TC-ACV-023 '## Out of Scope' appears in both templates (bug now has a non-blocking follow-up home)" \
  "$TEMPLATES_MD" '^## Out of Scope' 2

# Always-present pre-merge note must sit inside an Acceptance Criteria section.
# Both AC sections carry the same note; pin it via the loop-driver wording, which
# is UNIQUE to the note (not reused in checkbox placeholders) and must appear once
# per template => exactly 2. This proves the note is present in BOTH AC sections.
assert_count "TC-ACV-018/019 pre-merge note (loop-driver wording) present in BOTH AC sections" \
  "$TEMPLATES_MD" 'known driver of non-terminating dev' 2
assert_contains "TC-ACV-020 templates reference the surface concept (verification surface)" \
  "$(cat "$TEMPLATES_MD")" "verification surface"

# TC-ACV-021: the note must be VISIBLE in the rendered GitHub draft, not buried in
# an HTML comment (GitHub's renderer hides `<!-- ... -->`, so a commented note is
# invisible on every draft — the exact [P1] finding on #273). Requirement: every
# line carrying the loop-driver wording must be a Markdown BLOCKQUOTE line (begins
# with `>`, optionally indented), which renders. A naive count of HTML-comment
# wrappers won't do — the `## Dependencies` sections legitimately still use `<!--`.
note_lines=$(grep -nE 'known driver of non-terminating dev' "$TEMPLATES_MD")
note_total=$(printf '%s\n' "$note_lines" | grep -c .)
# Anchor to the `grep -n` line-number prefix (`<N>:`) so the `>` must be the FIRST
# rendered character of the line (optionally indented), not a `: >` sequence buried
# inside the note's body text — a blockquote line is what GitHub actually renders.
note_blockquote=$(printf '%s\n' "$note_lines" | grep -cE '^[0-9]+:[[:space:]]*>')
if [[ "$note_total" -eq 2 && "$note_blockquote" -eq 2 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-ACV-021 pre-merge note is a VISIBLE blockquote in BOTH AC sections (not an HTML comment)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-ACV-021 pre-merge note must be a visible blockquote (line starting with the > marker) in both AC sections"
  echo "      note lines total: $note_total ; blockquote lines: $note_blockquote (both must be 2)"
  echo "      offending lines:"; printf '%s\n' "$note_lines" | sed 's/^/        /'
  FAIL=$((FAIL + 1))
fi

# TC-ACV-022: belt-and-suspenders — the note must NOT be inside an HTML comment.
# Scan each line for the note wording and confirm none sits between a `<!--` and a
# `-->` (would render invisibly). Implemented as an awk in-comment state machine.
note_in_comment=$(awk '
  /<!--/ { incomment=1 }
  incomment && /known driver of non-terminating dev/ { hits++ }
  /-->/ { incomment=0 }
  END { print hits + 0 }
' "$TEMPLATES_MD")
if [[ "$note_in_comment" -eq 0 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-ACV-022 pre-merge note never appears inside an HTML comment (would be hidden on GitHub)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-ACV-022 pre-merge note found INSIDE an HTML comment ($note_in_comment occurrence(s)) — GitHub hides it"
  FAIL=$((FAIL + 1))
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
