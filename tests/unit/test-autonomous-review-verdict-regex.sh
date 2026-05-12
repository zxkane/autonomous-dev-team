#!/bin/bash
# test-autonomous-review-verdict-regex.sh — verify the verdict-detection
# logic in autonomous-review.sh recognizes common pass/fail phrasings,
# not just the canonical "Review PASSED" / "Review findings:" prefixes.
#
# Closes #95 (review wrapper exited 0 after an "APPROVED FOR MERGE"
# verdict but never approved or merged the PR — the brittle regex
# missed the verdict, the FAILED branch fired, and the dispatcher
# misclassified the result as a crash).
#
# Strategy: extract the live verdict-detection regex(es) from
# autonomous-review.sh, drive them against synthetic comments JSON
# for each verdict-wording variant, and assert which branch fires.
# This couples the test to the wrapper's actual behavior — drift in
# the wrapper's regex will show up here.
#
# Run: bash tests/unit/test-autonomous-review-verdict-regex.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected='$expected'"
    echo "      actual=  '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

# Extract the verdict-polling jq pattern from the wrapper.
#
# Post-Fix-1: the wrapper holds the verdict regex in a shell variable
# `_VERDICT_RE='...'` and references it inside two jq queries (one for
# the actor+window path, one for the legacy session-id fallback). We
# read the variable assignment directly — it is the canonical source.
#
# Anchor: the line `_VERDICT_RE='...'` near the polling loop.
POLL_PATTERN=$(grep -E "^_VERDICT_RE=" "$WRAPPER" | head -1 \
  | sed -E "s/^_VERDICT_RE='//; s/'$//")

# Extract the FAIL and PASS classification regex patterns.
# The post-fix wrapper has two `grep -qiE '...'` checks: FAIL first
# (conservative on ambiguity), then PASS. Extract both.
FAIL_PATTERN=$(grep -oE "grep -qiE '[^']*Review \(FAILED\|REJECTED\)[^']*'" "$WRAPPER" | head -1 | sed -E "s/^grep -qiE '//; s/'$//")
PASS_PATTERN=$(grep -oE "grep -qiE '[^']*Review PASSED[^']*'" "$WRAPPER" | head -1 | sed -E "s/^grep -qiE '//; s/'$//")

if [[ -z "$POLL_PATTERN" ]]; then
  echo -e "${RED}FAIL${NC}: could not extract verdict-poll pattern from $WRAPPER" >&2
  exit 1
fi
if [[ -z "$PASS_PATTERN" || -z "$FAIL_PATTERN" ]]; then
  echo -e "${RED}FAIL${NC}: could not extract pass/fail classification patterns from $WRAPPER" >&2
  echo "  PASS_PATTERN='$PASS_PATTERN'  FAIL_PATTERN='$FAIL_PATTERN'" >&2
  exit 1
fi

echo "Live POLL_PATTERN: $POLL_PATTERN"
echo "Live FAIL_PATTERN: $FAIL_PATTERN"
echo "Live PASS_PATTERN: $PASS_PATTERN"
echo ""

SID="abc-test-session-9c3"
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Run a case through the SAME pipeline the wrapper uses:
#   1. jq filter with the live POLL_PATTERN + session-id binding.
#   2. If matched, classify via the live PASS_PATTERN; otherwise FAIL.
# Returns one of: "pass", "fail", "no-match".
classify() {
  local body="$1"
  local json="$TMPROOT/case.json"
  python3 -c "
import json, sys
out = {'comments': [{'body': sys.argv[1]}]}
with open(sys.argv[2], 'w') as f:
    json.dump(out, f)
" "$body" "$json"

  local jq_q
  jq_q='[.comments[] | select((.body | test("'"$POLL_PATTERN"'"; "i")) and (.body | test("Review Session.*'"$SID"'")))] | last | .body'

  local matched
  matched=$(jq -r "$jq_q" < "$json" 2>/dev/null || echo "")
  if [[ -z "$matched" || "$matched" == "null" ]]; then
    echo "no-match"
    return
  fi

  # Apply the wrapper's two-step classification: FAIL pattern wins on
  # ambiguity (conservative), otherwise PASS pattern; otherwise FAIL.
  if echo "$matched" | grep -qiE "$FAIL_PATTERN"; then
    echo "fail"
  elif echo "$matched" | grep -qiE "$PASS_PATTERN"; then
    echo "pass"
  else
    echo "fail"
  fi
}

# ---------------------------------------------------------------------------
echo "=== TC-RVR cases against live wrapper regex ==="
# ---------------------------------------------------------------------------

assert_eq "TC-RVR-001 Review PASSED → pass" "pass" \
  "$(classify "Review PASSED — All checklist items verified.
Review Session: \`$SID\`")"

assert_eq "TC-RVR-002 APPROVED FOR MERGE → pass (the issue's scenario)" "pass" \
  "$(classify "**APPROVED FOR MERGE**

All criteria pass.
Review Session: \`$SID\`")"

assert_eq "TC-RVR-003 LGTM → pass" "pass" \
  "$(classify "LGTM — code quality is good.
Review Session: \`$SID\`")"

assert_eq "TC-RVR-004 Review APPROVED → pass" "pass" \
  "$(classify "Review APPROVED.
Review Session: \`$SID\`")"

assert_eq "TC-RVR-006 Review findings → fail" "fail" \
  "$(classify "Review findings:
1. Missing test for edge case
Review Session: \`$SID\`")"

assert_eq "TC-RVR-007 Review FAILED → fail" "fail" \
  "$(classify "Review FAILED — see below.
Review Session: \`$SID\`")"

assert_eq "TC-RVR-008 Changes requested → fail" "fail" \
  "$(classify "Changes requested.
Review Session: \`$SID\`")"

assert_eq "TC-RVR-009 missing session-id trailer → no-match (anti-spoof)" "no-match" \
  "$(classify "Review PASSED — but no session id.")"

assert_eq "TC-RVR-010 different session-id → no-match (anti-spoof)" "no-match" \
  "$(classify "Review PASSED.
Review Session: \`other-session-xyz\`")"

assert_eq "TC-RVR-011 ambiguous (LGTM + Review findings) → fail (conservative)" "fail" \
  "$(classify "LGTM mostly but Review findings:
- nit: typo
Review Session: \`$SID\`")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
