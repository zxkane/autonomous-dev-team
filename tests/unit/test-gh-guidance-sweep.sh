#!/bin/bash
# test-gh-guidance-sweep.sh — issue #429.
#
# Pins the post-sweep `gh ` word-boundary token count in every swept skill
# markdown file + the block-push-to-main hook, so unintentional regrowth is
# caught in CI `unit`. Uses the SAME RE2-safe consuming-boundary matcher
# check-provider-cutover.sh uses in the dispatcher tree, so a raw `gh …`
# added later inside a code block, table cell, or prose sentence trips a
# FAIL naming the file. Also asserts the hook's block message contains
# `merge request` (the provider-neutral phrasing per R1) and that the hook
# still passes `bash -n`.
#
# Run: env -u PROJECT_DIR bash tests/unit/test-gh-guidance-sweep.sh
#
# Doc pair: docs/test-cases/issue-429-gh-guidance-sweep.md
# (per-file inventory + rationale for deliberately-kept sites).

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

# Same RE2-safe consuming-boundary detector check-provider-cutover.sh uses:
# `(^|[^A-Za-z_-])gh ` — non-word / non-hyphen preceding, or start of line.
# Note this counts LINES (grep -c) that match, matching the ANNOUNCED metric
# in the issue and the pin scheme in test-provider-prompts-site-removal.sh.
count_gh_lines() {
  grep -cE '(^|[^A-Za-z_-])gh ' "$1" 2>/dev/null || echo 0
}

assert_count() {
  local file="$1" expected="$2" tc="$3"
  local abs="$PROJECT_ROOT/$file"
  if [[ ! -f "$abs" ]]; then
    bad "$tc file missing: $file"
    return
  fi
  local n
  n=$(count_gh_lines "$abs")
  if [[ "$n" -eq "$expected" ]]; then
    ok "$tc $file gh-token line count == $expected"
  else
    bad "$tc $file expected $expected gh-token lines, got $n"
  fi
}

echo "=== TC-GHSWEEP-001: block-push-to-main.sh message contains 'merge request' (provider-neutral phrasing per R1) ==="
HOOK="$PROJECT_ROOT/skills/autonomous-common/hooks/block-push-to-main.sh"
if grep -qF 'merge request' "$HOOK"; then
  ok "TC-GHSWEEP-001 block message contains 'merge request'"
else
  bad "TC-GHSWEEP-001 block message missing 'merge request' phrase"
fi

echo ""
echo "=== TC-GHSWEEP-002: block-push-to-main.sh syntactically valid (bash -n) ==="
if bash -n "$HOOK" 2>/dev/null; then
  ok "TC-GHSWEEP-002 bash -n rc=0"
else
  bad "TC-GHSWEEP-002 bash -n failed"
fi

echo ""
echo "=== TC-GHSWEEP-003..012: pinned gh-token line counts per swept file ==="
# Pins are frozen by this test. Regrowth beyond a pin needs a coordinated
# doc+pin bump in the TC doc AND here — this catches the case where a later
# PR silently re-introduces `gh` guidance inside a swept surface without
# updating the inventory.
assert_count "skills/autonomous-common/hooks/block-push-to-main.sh"           1  "TC-GHSWEEP-003"
assert_count "skills/autonomous-dev/SKILL.md"                                 6  "TC-GHSWEEP-004"
assert_count "skills/autonomous-dev/references/review-commands.md"           26  "TC-GHSWEEP-005"
assert_count "skills/autonomous-dev/references/review-threads.md"             9  "TC-GHSWEEP-006"
assert_count "skills/autonomous-dev/references/autonomous-mode.md"           12  "TC-GHSWEEP-007"
assert_count "skills/autonomous-review/SKILL.md"                             13  "TC-GHSWEEP-008"
assert_count "skills/autonomous-review/references/decision-gate.md"           9  "TC-GHSWEEP-009"
assert_count "skills/autonomous-review/references/merge-conflict-resolution.md" 4 "TC-GHSWEEP-010"
assert_count "skills/autonomous-dispatcher/SKILL.md"                          1  "TC-GHSWEEP-011"
assert_count "skills/create-issue/SKILL.md"                                   1  "TC-GHSWEEP-012"

echo ""
echo "=== TC-GHSWEEP-013: every swept file mentions CODE_HOST or GitLab (proves a scope-note exists) ==="
# If a later PR strips the scope-note but keeps the `gh` count identical
# (e.g., replaces the note with unrelated `gh` prose), this fires. This is
# the shape check that pairs with the count pin above — count PIN + scope-
# note PRESENCE = kept-under-scope is preserved.
SWEPT_MARKDOWN=(
  "skills/autonomous-dev/SKILL.md"
  "skills/autonomous-dev/references/review-commands.md"
  "skills/autonomous-dev/references/review-threads.md"
  "skills/autonomous-dev/references/autonomous-mode.md"
  "skills/autonomous-review/SKILL.md"
  "skills/autonomous-review/references/decision-gate.md"
  "skills/autonomous-review/references/merge-conflict-resolution.md"
  "skills/autonomous-dispatcher/SKILL.md"
  "skills/create-issue/SKILL.md"
)
all_ok=1
for f in "${SWEPT_MARKDOWN[@]}"; do
  abs="$PROJECT_ROOT/$f"
  if ! grep -qE 'CODE_HOST|GitLab|glab|chp_|itp_' "$abs" 2>/dev/null; then
    bad "TC-GHSWEEP-013 no scope-note / GitLab-lane marker in $f"
    all_ok=0
  fi
done
if [[ "$all_ok" -eq 1 ]]; then
  ok "TC-GHSWEEP-013 every swept markdown file carries at least one scope-note marker (CODE_HOST/GitLab/glab/chp_/itp_)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
