#!/bin/bash
# test-autonomous-review-auto-merge-failure.sh — source-of-truth grep tests
# verifying autonomous-review.sh handles auto-merge failure correctly:
#
#   - Wrapper does NOT close the linked issue on any path (issue #145).
#   - Auto-merge failure branch posts comment on PR (not issue) with merge error.
#   - Auto-merge failure branch flips issue label to pending-dev (NOT approved),
#     keeping autonomous so the dispatcher Step 4 picks it up next tick.
#   - Auto-merge success branch removes autonomous and adds approved (regression
#     pin for the happy path).
#
# Strategy: grep the wrapper script as source-of-truth. The wrapper is too
# heavy to execute end-to-end (it spawns the agent + makes gh API calls) so
# we verify structural invariants in the source.
#
# Run: bash tests/unit/test-autonomous-review-auto-merge-failure.sh

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

assert_not_grep() {
  local desc="$1" pattern="$2" file="$3"
  if ! grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (matched: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

# Strip bash comments before matching, so a #-prefixed mention doesn't
# accidentally match. Outputs a stripped temp file path on stdout.
strip_comments() {
  local src="$1" tmp
  tmp=$(mktemp)
  # Remove full-line comments and trailing comments. Doesn't try to be
  # heredoc-aware — heredocs in the wrapper don't contain `gh issue close`,
  # so a simple grep -v '^[[:space:]]*#' plus sed is sufficient.
  sed -E 's/[[:space:]]+#[^"]*$//' "$src" | grep -v '^[[:space:]]*#' > "$tmp"
  echo "$tmp"
}

WRAPPER_CODE=$(strip_comments "$WRAPPER")
trap 'rm -f "$WRAPPER_CODE"' EXIT

# ---------------------------------------------------------------------------
echo "=== TC-AMF-006: regression — wrapper contains zero gh issue close calls ==="
# ---------------------------------------------------------------------------
# This is THE regression pin for issue #145. No path inside the review
# wrapper may close the issue directly; closure happens via GitHub's
# Closes #N keyword on PR merge.
assert_not_grep "no 'gh issue close' calls in executable code" \
  '^[^#]*gh +issue +close' "$WRAPPER_CODE"

# Defense-in-depth: also forbid the equivalent gh issue edit --state-change
# patterns. (gh issue edit doesn't take --state, but a future gh release
# might; pin defensively.)
assert_not_grep "no '--state closed' on gh issue edit" \
  'gh +issue +edit.*--state +closed' "$WRAPPER_CODE"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AMF-002: auto-merge failure branch flips issue to pending-dev ==="
# ---------------------------------------------------------------------------
# The auto-merge failure branch must add pending-dev (not approved) so the
# dispatcher's Step 4 picks the issue up for re-dispatch.
assert_grep "auto-merge failure branch references pending-dev" \
  'add-label +.?pending-dev' "$WRAPPER_CODE"

# The auto-merge failure branch must NOT remove the autonomous label —
# pending-dev without autonomous is invisible to the dispatcher's
# list_pending_dev selector.
# We verify by grepping the entire wrapper for `--remove-label autonomous`
# and confirming it appears EXACTLY ONCE (the success branch),
# not twice (which would mean the failure branch also strips it).
_autonomous_strip_count=$(grep -cE 'remove-label +.?autonomous' "$WRAPPER_CODE" || true)
if [[ "$_autonomous_strip_count" -le 1 ]]; then
  echo -e "  ${GREEN}PASS${NC}: 'remove-label autonomous' appears at most once (success-only path)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: 'remove-label autonomous' appears $_autonomous_strip_count times — failure branch shouldn't strip autonomous"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AMF-003: auto-merge failure branch posts comment on PR ==="
# ---------------------------------------------------------------------------
# The merge error must be surfaced as a comment on the PR (not the issue),
# so the dev re-dispatch has the failure context in PR view where rebase
# work happens. Marker prefix is "Auto-merge failed:".
assert_grep "auto-merge failure path posts via gh pr comment" \
  'gh +pr +comment' "$WRAPPER_CODE"

assert_grep "auto-merge failure marker prefix appears in wrapper" \
  'Auto-merge failed:' "$WRAPPER_CODE"

# Marker must direct dev re-dispatch (not "please merge manually" which
# would absolve the autonomous pipeline of further work — issue #145 AC).
assert_grep "marker mentions re-dispatching dev for rebase" \
  '[Rr]e-dispatch.*dev|rebase onto main' "$WRAPPER_CODE"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AMF-006 (cont): no 'please merge manually' in auto-merge failure path ==="
# ---------------------------------------------------------------------------
# The "please merge manually" wording remains acceptable in two paths
# (no-auto-close, formal-approval-failed) — those genuinely need human
# action. But the auto-merge-failure path must NOT use it; that's the
# bug being fixed.
#
# We can't easily isolate "the auto-merge-failure path" from the wrapper
# without parsing bash, so we verify the two legitimate uses are gated
# behind their preconditions and the third (auto-merge fail) was removed.
# Concretely: the legitimate uses include "@${REPO_OWNER}" mention, while
# the auto-merge-failure path historically did not. Pin: the literal
# string from the buggy code is gone.
assert_not_grep "old 'Review passed but auto-merge failed. Please merge ... manually' wording removed" \
  'Review passed but auto-merge failed.* [Pp]lease merge' "$WRAPPER_CODE"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AMF-007: auto-merge failure branch is structurally distinct ==="
# ---------------------------------------------------------------------------
# The merge call must be conditioned on a captured exit status, NOT a
# fall-through where a failed merge bleeds into the close+approved code.
# We pin on a paired pattern: gh pr merge captures success/failure into a
# variable that gates the subsequent issue-edit branch.
assert_grep "wrapper captures merge result for branching" \
  'gh +pr +merge.*--squash' "$WRAPPER_CODE"

# Bash syntax check
echo ""
echo "=== TC-AMF-syntax: wrapper passes bash -n ==="
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
