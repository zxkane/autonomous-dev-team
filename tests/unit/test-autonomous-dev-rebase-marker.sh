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
# The resume branch must scan PR comments for a comment whose body starts
# with "Auto-merge failed:" — the marker the review wrapper writes when
# gh pr merge fails. Without this detection, the dev agent would not know
# to rebase first.
assert_grep "wrapper queries PR comments for Auto-merge failure marker" \
  'Auto-merge failed' "$WRAPPER"

# The marker selector should be a deterministic startswith (not a brittle
# substring contains) so dev status comments mentioning the phrase in
# quoted history can't trigger a false positive.
assert_grep "marker selector uses startswith for determinism" \
  'startswith.*"Auto-merge failed' "$WRAPPER"

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
