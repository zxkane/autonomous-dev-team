#!/bin/bash
# test-autonomous-dev-rebase-marker.sh — verify autonomous-dev.sh's resume
# branch detects the auto-merge-failure marker comment posted by the review
# wrapper (issue #145) and prepends a "rebase before continuing" instruction
# to the resume prompt.
#
# Strategy: source-of-truth grep against the dev wrapper's resume branch.
# The wrapper is too heavy to execute end-to-end.
#
# Run: bash tests/unit/test-autonomous-dev-rebase-marker.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
DISPOSITION_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-disposition.sh"

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

# ---------------------------------------------------------------------------
echo "=== TC-AMF-008: dev resume detects auto-merge-failure marker ==="
# ---------------------------------------------------------------------------
# The wrapper owns provider reads and delegates the strict current-HEAD marker
# contract to lib-review-disposition.sh. Parser behavior is covered exhaustively
# by test-review-disposition.sh; this test pins only the wrapper integration.
assert_grep "wrapper loads the shared review-disposition contract" \
  'source "\$\{LIB_DIR\}/lib-review-disposition.sh"' "$WRAPPER"

assert_grep "wrapper resolves the linked PR and full HEAD before comment parsing" \
  'resolve_pr_for_issue' "$WRAPPER"

assert_grep "wrapper reads normalized PR comments through the provider seam" \
  'chp_pr_view "\$PR_NUM" "comments"' "$WRAPPER"

assert_grep "wrapper delegates recovery-marker selection to the shared parser" \
  '_review_pr_recovery_comment_from_comments' "$WRAPPER"

assert_grep "shared parser requires Auto-merge failed to begin the body" \
  'startswith\("Auto-merge failed:"\)' "$DISPOSITION_LIB"

# ---------------------------------------------------------------------------
echo ""
echo "=== resume prompt conditionally includes rebase instructions ==="
# ---------------------------------------------------------------------------
# When the marker is found, the resume prompt must include an instruction
# to rebase onto origin/main BEFORE doing other work.
assert_grep "resume prompt mentions rebase pre-implementation when marker found" \
  'rebase' "$WRAPPER"

# Bash syntax check
echo ""
echo "=== TC-AMF-008-syntax: wrapper passes bash -n ==="
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
