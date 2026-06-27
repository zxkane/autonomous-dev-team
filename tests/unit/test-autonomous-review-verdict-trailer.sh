#!/bin/bash
# test-autonomous-review-verdict-trailer.sh — INV-35 / issue #149.
#
# The wrapper must emit a `<!-- review-verdict: ... -->` HTML-comment trailer
# after the agent's verdict comment so the dispatcher's
# classify_recent_review_verdict can route Step 4b.5.1 correctly. The emitter
# logic lives in skills/autonomous-dispatcher/scripts/lib-review-verdict.sh
# (a new helper file) so it can be unit-tested without spawning the full
# review wrapper.
#
# Function under test:
#   emit_verdict_trailer <issue_num> <repo> <verdict> <cause>
#     verdict ∈ { passed, failed-substantive, failed-non-substantive }
#     cause   — required only for failed-non-substantive; ignored otherwise.
#   Posts a single comment via `gh issue comment` whose body is the trailer
#   (one HTML comment line). Designed to be safe to call multiple times — the
#   classifier picks the newest comment, so an earlier-posted trailer is
#   shadowed by a later-posted one. The wrapper's exit branches all funnel
#   through this helper, so each branch emits exactly the right verdict.
#
# Run: bash tests/unit/test-autonomous-review-verdict-trailer.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-verdict.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

_MOCK_LAST_COMMENT_BODY=""
_MOCK_COMMENT_COUNT=0
_MOCK_GH_LAST_ARGS=()

gh() {
  local cmd="${1:-}"
  local sub="${2:-}"
  if [[ "$cmd" == "issue" && "$sub" == "comment" ]]; then
    _MOCK_GH_LAST_ARGS=("$@")
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--body" ]]; then
        _MOCK_LAST_COMMENT_BODY="$2"
        _MOCK_COMMENT_COUNT=$((_MOCK_COMMENT_COUNT + 1))
        return 0
      fi
      shift
    done
    return 0
  fi
  return 0
}

[[ -f "$LIB" ]] || {
  echo "ERROR: $LIB not found — implementation step required first" >&2
  exit 1
}
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-verdict.sh
source "$LIB"
set +e

# Re-define mocks AFTER sourcing.
gh() {
  local cmd="${1:-}"
  local sub="${2:-}"
  if [[ "$cmd" == "issue" && "$sub" == "comment" ]]; then
    _MOCK_GH_LAST_ARGS=("$@")
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "--body" ]]; then
        _MOCK_LAST_COMMENT_BODY="$2"
        _MOCK_COMMENT_COUNT=$((_MOCK_COMMENT_COUNT + 1))
        return 0
      fi
      shift
    done
    return 0
  fi
  return 0
}

reset() {
  _MOCK_LAST_COMMENT_BODY=""
  _MOCK_COMMENT_COUNT=0
  _MOCK_GH_LAST_ARGS=()
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle=[$needle]"
    echo "      haystack=[$haystack]"
    FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

# [INV-87]/[INV-89] emit_verdict_trailer now routes its issue-comment write through
# itp_post_comment → itp_github_post_comment, which posts to the provider's config
# namespace $REPO (spec §3.4). In production the review wrapper always has $REPO set
# (from autonomous.conf); every emit_verdict_trailer caller passes $REPO as arg2, so
# the emitted `gh issue comment … --body` is byte-identical. Export it here to match.
export REPO="zxkane/autonomous-dev-team"

# ---------------------------------------------------------------------------
echo "=== emit_verdict_trailer (INV-35) ==="
# ---------------------------------------------------------------------------

# passed
reset
emit_verdict_trailer 149 "zxkane/autonomous-dev-team" "passed" ""
assert_eq "passed: one comment posted" "1" "$_MOCK_COMMENT_COUNT"
assert_contains "passed: trailer body" "<!-- review-verdict: passed -->" "$_MOCK_LAST_COMMENT_BODY"

# failed-substantive
reset
emit_verdict_trailer 149 "zxkane/autonomous-dev-team" "failed-substantive" ""
assert_contains "failed-substantive: trailer body" "<!-- review-verdict: failed-substantive -->" "$_MOCK_LAST_COMMENT_BODY"

# failed-non-substantive with cause
reset
emit_verdict_trailer 149 "zxkane/autonomous-dev-team" "failed-non-substantive" "bot-timeout"
assert_contains "failed-non-substantive: trailer body" "<!-- review-verdict: failed-non-substantive cause=bot-timeout -->" "$_MOCK_LAST_COMMENT_BODY"

# failed-non-substantive without cause → defaults to "other"
reset
emit_verdict_trailer 149 "zxkane/autonomous-dev-team" "failed-non-substantive" ""
assert_contains "failed-non-substantive without cause defaults to 'other'" "<!-- review-verdict: failed-non-substantive cause=other -->" "$_MOCK_LAST_COMMENT_BODY"

# unknown verdict → no comment posted (helper rejects)
reset
emit_verdict_trailer 149 "zxkane/autonomous-dev-team" "wat" ""
rc=$?
assert_eq "unknown verdict → exit non-zero" "1" "$rc"
assert_eq "unknown verdict → no comment" "0" "$_MOCK_COMMENT_COUNT"

# Cause token sanitization: embedded shell metacharacters are sanitized to "other"
reset
emit_verdict_trailer 149 "zxkane/autonomous-dev-team" "failed-non-substantive" "bot-timeout; rm -rf /"
rc=$?
if [[ $rc -eq 0 ]]; then
  assert_contains "metachar cause sanitized" "cause=other" "$_MOCK_LAST_COMMENT_BODY"
else
  echo -e "  ${RED}FAIL${NC}: emit_verdict_trailer rejected sanitizable cause (rc=$rc)"
  FAIL=$((FAIL + 1))
fi

# Cause token whitelist normalization: lowercase, dashes only
reset
emit_verdict_trailer 149 "zxkane/autonomous-dev-team" "failed-non-substantive" "BOT_Timeout"
assert_contains "uppercase cause is rejected/normalized" "cause=" "$_MOCK_LAST_COMMENT_BODY"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
