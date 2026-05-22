#!/bin/bash
# test-classify-recent-review-verdict.sh — INV-35 / issue #149.
#
# Unit tests for lib-dispatch.sh::classify_recent_review_verdict.
#
# The helper reads issue comments via gh, picks the newest comment that:
#   (a) is authored by BOT_LOGIN (or matches the session-id-binding fallback
#       when BOT_LOGIN is empty per the gh-api-user-403 pattern), AND
#   (b) was created strictly after <session_end_iso>, AND
#   (c) carries an HTML-comment trailer of form `<!-- review-verdict: ... -->`.
# It returns one of: none / passed / failed-substantive / failed-non-substantive.
# A surviving comment that has no trailer is conservatively treated as
# failed-substantive (back-compat with pre-INV-35 verdict comments).
#
# Test IDs map to docs/test-cases/inv35-review-aware-resume.md § A.
#
# Run: bash tests/unit/test-classify-recent-review-verdict.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-classify-$$
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# _MOCK_COMMENTS_JSON — JSON array fed to the mocked `gh issue view ... --json comments -q .comments`
# Each test case sets this; the gh stub echoes it back.
_MOCK_COMMENTS_JSON='[]'

gh() {
  local cmd="${1:-}"
  local sub="${2:-}"
  if [[ "$cmd" == "issue" && "$sub" == "view" ]]; then
    # Find the -q (jq) arg and apply it to _MOCK_COMMENTS_JSON.
    local jq_query=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-q" || "$1" == "--jq" ]]; then
        jq_query="$2"
        break
      fi
      shift
    done
    if [[ -z "$jq_query" ]]; then
      printf '%s' "$_MOCK_COMMENTS_JSON"
    else
      # Wrap the comments array as { comments: [...] } since the lib helper
      # uses `--json comments` and queries paths under `.comments[]`.
      printf '%s' "{\"comments\":$_MOCK_COMMENTS_JSON}" | jq -r "$jq_query"
    fi
    return 0
  fi
  return 0
}
export -f gh

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

# Re-define gh after sourcing lib (lib-dispatch.sh doesn't override gh, but
# safety belt mirrors test-dispatcher-step4-stale-verdict.sh pattern).
gh() {
  local cmd="${1:-}"
  local sub="${2:-}"
  if [[ "$cmd" == "issue" && "$sub" == "view" ]]; then
    local jq_query=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-q" || "$1" == "--jq" ]]; then
        jq_query="$2"
        break
      fi
      shift
    done
    if [[ -z "$jq_query" ]]; then
      printf '%s' "$_MOCK_COMMENTS_JSON"
    else
      printf '%s' "{\"comments\":$_MOCK_COMMENTS_JSON}" | jq -r "$jq_query"
    fi
    return 0
  fi
  return 0
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

# Helper: build a JSON comment object.
mkc() {
  local login="$1" created_at="$2" body="$3"
  jq -n --arg l "$login" --arg c "$created_at" --arg b "$body" \
    '{author:{login:$l}, createdAt:$c, body:$b}'
}

# ---------------------------------------------------------------------------
echo "=== classify_recent_review_verdict (INV-35) ==="
# ---------------------------------------------------------------------------

BOT="kane-coding-agent[bot]"
SESSION_END="2026-05-21T03:18:00Z"
export BOT_LOGIN="$BOT"

# TC-INV35-CL-001: No comments after session-end → none
_MOCK_COMMENTS_JSON=$(jq -n --argjson c1 "$(mkc "$BOT" "2026-05-21T02:00:00Z" "Review FAILED")" \
  --argjson c2 "$(mkc "$BOT" "2026-05-21T01:00:00Z" "Other comment")" \
  '[$c1,$c2]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-001 verdict (no post-session comments)" "none" "$v"
assert_eq "TC-INV35-CL-001 cause" "" "$c"

# TC-INV35-CL-002: Newest comment carries failed-non-substantive trailer
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:29:00Z" $'<!-- review-verdict: failed-non-substantive cause=bot-timeout -->\nReview FAILED — q-bot timed out')" \
  --argjson c2 "$(mkc "$BOT" "2026-05-21T04:00:00Z" "earlier bot comment")" \
  --argjson c3 "$(mkc "$BOT" "2026-05-21T03:30:00Z" "even earlier bot comment")" \
  '[$c1,$c2,$c3]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-002 verdict" "failed-non-substantive" "$v"
assert_eq "TC-INV35-CL-002 cause" "bot-timeout" "$c"

# TC-INV35-CL-003: Newest by createdAt (gh returns out of order)
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson old "$(mkc "$BOT" "2026-05-21T04:00:00Z" "<!-- review-verdict: passed -->")" \
  --argjson newer "$(mkc "$BOT" "2026-05-21T05:00:00Z" "<!-- review-verdict: failed-substantive -->")" \
  '[$old,$newer]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-003 newest wins" "failed-substantive" "$v"

# TC-INV35-CL-004: Missing trailer falls back to failed-substantive
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" "Review FAILED — found 3 issues with the implementation.")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-004 fallback verdict" "failed-substantive" "$v"
assert_eq "TC-INV35-CL-004 fallback cause" "" "$c"

# TC-INV35-CL-005: Newest comment from non-bot author → ignored, older bot wins
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson human "$(mkc "operator-user" "2026-05-21T06:00:00Z" "Manual comment")" \
  --argjson bot "$(mkc "$BOT" "2026-05-21T05:00:00Z" "<!-- review-verdict: passed -->")" \
  '[$human,$bot]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-005 filter applied before pick" "passed" "$v"

# TC-INV35-CL-006: BOT_LOGIN empty → session-id binding fallback
SESSION_UUID="11111111-2222-3333-4444-555555555555"
export BOT_LOGIN=""
export FALLBACK_SESSION_ID="$SESSION_UUID"
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "anyone" "2026-05-21T05:10:00Z" $'Review FAILED\nReview Session: '"$SESSION_UUID"$'\n<!-- review-verdict: failed-non-substantive cause=ci-transport -->')" \
  --argjson c2 "$(mkc "anyone" "2026-05-21T04:00:00Z" "unrelated")" \
  '[$c1,$c2]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-006 fallback verdict" "failed-non-substantive" "$v"
assert_eq "TC-INV35-CL-006 fallback cause" "ci-transport" "$c"
unset FALLBACK_SESSION_ID
export BOT_LOGIN="$BOT"

# TC-INV35-CL-007: Multiple trailers in body → first match wins (pinned per design §7)
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" $'<!-- review-verdict: passed -->\nQuoted from earlier review.\n<!-- review-verdict: failed-substantive -->\nActual current verdict')" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-007 first match wins" "passed" "$v"

# TC-INV35-CL-008: Unknown cause token still routes to failed-non-substantive
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" "<!-- review-verdict: failed-non-substantive cause=newly-invented-token -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-008 verdict" "failed-non-substantive" "$v"
assert_eq "TC-INV35-CL-008 cause forward-compat" "newly-invented-token" "$c"

# Edge: comment with createdAt exactly at session_end_iso → excluded (strict >)
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "$SESSION_END" "<!-- review-verdict: passed -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "edge: createdAt == session_end → excluded" "none" "$v"

# Edge: bot comment with empty body → none. Empty body carries no signal at
# all — neither a verdict nor a "we tried to review" trailer — so the helper
# returns "none" and the caller falls back to the INV-12-completed branch.
# This is conservative: a verdict comment in the wild always carries body
# text, so an empty body means the gh response was malformed or the comment
# was deleted.
_MOCK_COMMENTS_JSON=$(jq -n --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" "")" '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "edge: empty bot comment body → none (no signal)" "none" "$v"

# Edge: passed trailer with extra whitespace
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" "<!-- review-verdict:   passed   -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "edge: whitespace-tolerant trailer parse" "passed" "$v"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
