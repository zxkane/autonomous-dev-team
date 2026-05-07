#!/bin/bash
# test-skip-redundant-review.sh — Unit tests for dispatcher skipping redundant review
# when the PR HEAD SHA has not advanced since the last review.
#
# See docs/designs/dispatcher-skip-redundant-review.md
# Run: bash tests/unit/test-skip-redundant-review.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected to contain '$needle')"
    FAIL=$((FAIL+1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (should NOT contain '$needle')"
    FAIL=$((FAIL+1))
  fi
}

assert_match() {
  local desc="$1" pattern="$2" haystack="$3"
  if echo "$haystack" | grep -Eq "$pattern"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected to match '$pattern')"
    FAIL=$((FAIL+1))
  fi
}

REVIEW_SCRIPT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
SKILL_FILE="$PROJECT_ROOT/skills/autonomous-dispatcher/SKILL.md"

[[ -f "$REVIEW_SCRIPT" ]] || { echo -e "${RED}FATAL${NC}: $REVIEW_SCRIPT not found"; exit 1; }
[[ -f "$SKILL_FILE"   ]] || { echo -e "${RED}FATAL${NC}: $SKILL_FILE not found";   exit 1; }

REVIEW_CONTENT=$(cat "$REVIEW_SCRIPT")
SKILL_CONTENT=$(cat "$SKILL_FILE")

# ============================================================================
# TC-DSRR-001: Review wrapper records reviewed HEAD SHA
# ============================================================================
echo
echo "=== TC-DSRR-001: Review wrapper records reviewed HEAD SHA ==="
echo

assert_contains "PR_HEAD_SHA captured via headRefOid" "headRefOid" "$REVIEW_CONTENT"
assert_contains "PR_HEAD_SHA variable defined"        "PR_HEAD_SHA=" "$REVIEW_CONTENT"
assert_contains "Trailer string present"              "Reviewed HEAD:" "$REVIEW_CONTENT"

# ============================================================================
# TC-DSRR-002: Trailer post failure does not abort review
# ============================================================================
echo
echo "=== TC-DSRR-002: Trailer post is non-fatal ==="
echo

# Extract just the trailer command — from "gh issue comment ... Reviewed HEAD"
# up to the next blank line or `fi`. The post must either:
#   - be wrapped in `|| true`, OR
#   - chain to a `log` warning with `||` (which under set -e still suppresses
#     the failure because log returns 0, ending the chain successfully).
TRAILER_BLOCK=$(awk '
  /gh issue comment.*Reviewed HEAD|--body "Reviewed HEAD/ { found=1 }
  found {
    print
    if (/^[[:space:]]*$/ || /^fi[[:space:]]*$/) { found=0 }
  }
' "$REVIEW_SCRIPT")

# Guard against silent vacuous-pass if the trailer layout changes and the
# block extractor produces an empty match — fail loudly instead.
if [[ -z "$TRAILER_BLOCK" ]]; then
  echo -e "  ${RED}FAIL${NC}: trailer block extraction empty — script layout changed, update awk pattern"
  FAIL=$((FAIL+1))
else
  assert_match "Trailer post tolerates failure (|| true or || log fallback)" \
    '\|\| (true|log )' "$TRAILER_BLOCK"
fi

# ============================================================================
# TC-DSRR-003: Dispatcher SKILL.md describes SHA comparison
# ============================================================================
echo
echo "=== TC-DSRR-003: SKILL.md Step 5 compares SHAs ==="
echo

assert_contains "SKILL.md mentions headRefOid"           "headRefOid"      "$SKILL_CONTENT"
assert_contains "SKILL.md extracts Reviewed HEAD SHA"    "Reviewed HEAD:"  "$SKILL_CONTENT"
assert_contains "SKILL.md branches on SHA equality"      "no new commits since last review" "$SKILL_CONTENT"
assert_contains "SKILL.md keeps PR-found handoff path"   "Dev process exited (PR found)"    "$SKILL_CONTENT"

# ============================================================================
# TC-DSRR-004: New "no new commits" wording does not match retry regex
# ============================================================================
echo
echo "=== TC-DSRR-004: New wording is excluded from retry counter ==="
echo

NEW_WORDING="Dev process exited (no new commits since last review at \`abc1234\`). Moving to pending-dev for retry."
RETRY_REGEX='Task appears to have crashed \(no PR found\)|process not found'

if echo "$NEW_WORDING" | grep -Eq "$RETRY_REGEX"; then
  echo -e "  ${RED}FAIL${NC}: new wording incorrectly matches retry regex"
  FAIL=$((FAIL+1))
else
  echo -e "  ${GREEN}PASS${NC}: new wording does not match retry regex"
  PASS=$((PASS+1))
fi

# ============================================================================
# TC-DSRR-005: Existing PR-found wording still excluded from retry regex
# ============================================================================
echo
echo "=== TC-DSRR-005: PR-found handoff wording is excluded from retry counter ==="
echo

OLD_WORDING="Dev process exited (PR found). Moving to pending-review for assessment."

if echo "$OLD_WORDING" | grep -Eq "$RETRY_REGEX"; then
  echo -e "  ${RED}FAIL${NC}: PR-found wording incorrectly matches retry regex"
  FAIL=$((FAIL+1))
else
  echo -e "  ${GREEN}PASS${NC}: PR-found wording does not match retry regex"
  PASS=$((PASS+1))
fi

# ============================================================================
# TC-DSRR-006: SKILL.md falls through to pending-review when no trailer found
# ============================================================================
echo
echo "=== TC-DSRR-006: Empty LAST_REVIEWED_HEAD → pending-review ==="
echo

assert_contains "SKILL.md notes empty-trailer fallback" "no prior review trailer" "$SKILL_CONTENT"

# ============================================================================
# TC-DSRR-007: Trailer marker is jq/regex-greppable as documented
# ============================================================================
echo
echo "=== TC-DSRR-007: Trailer is parseable by documented regex ==="
echo

if ! command -v jq >/dev/null 2>&1; then
  echo -e "  ${RED}SKIP${NC}: jq not installed"
else
  # Single-trailer fixture
  SAMPLE=$(cat <<'EOF'
{
  "comments": [
    {"body": "Dispatching autonomous review..."},
    {"body": "Review findings:\n\n1. **[BLOCKING]** ...\n\nReview Session: `f95638fe-e8d1-4e5d-87b6-d505b79961dc`"},
    {"body": "Reviewed HEAD: `abcdef1234567890abcdef1234567890abcdef12` (issue #115, session `f95638fe-e8d1-4e5d-87b6-d505b79961dc`)"}
  ]
}
EOF
  )

  EXTRACTED=$(echo "$SAMPLE" | jq -r '
    [.comments[].body | capture("Reviewed HEAD: `(?<sha>[0-9a-f]{7,40})`"; "g") | .sha] | last // empty
  ')

  if [[ "$EXTRACTED" == "abcdef1234567890abcdef1234567890abcdef12" ]]; then
    echo -e "  ${GREEN}PASS${NC}: jq capture extracts the SHA"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: jq capture did not return SHA, got: '$EXTRACTED'"
    FAIL=$((FAIL+1))
  fi

  # Multi-trailer fixture — assert `last` returns the newest SHA, not the oldest.
  # Guards against a regression that swaps `last` for `first`.
  MULTI_SAMPLE=$(cat <<'EOF'
{
  "comments": [
    {"body": "Reviewed HEAD: `1111111111111111111111111111111111111111` (issue #1, session `aaa`)"},
    {"body": "Resuming development..."},
    {"body": "Reviewed HEAD: `2222222222222222222222222222222222222222` (issue #1, session `bbb`)"}
  ]
}
EOF
  )
  MULTI_EXTRACTED=$(echo "$MULTI_SAMPLE" | jq -r '
    [.comments[].body | capture("Reviewed HEAD: `(?<sha>[0-9a-f]{7,40})`"; "g") | .sha] | last // empty
  ')
  if [[ "$MULTI_EXTRACTED" == "2222222222222222222222222222222222222222" ]]; then
    echo -e "  ${GREEN}PASS${NC}: jq capture returns newest SHA across multiple trailers"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: expected newest SHA from multi-trailer fixture, got: '$MULTI_EXTRACTED'"
    FAIL=$((FAIL+1))
  fi
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo -e "Total: $TOTAL  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo

[[ $FAIL -gt 0 ]] && exit 1
exit 0
