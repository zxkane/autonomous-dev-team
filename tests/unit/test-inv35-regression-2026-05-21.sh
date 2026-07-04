#!/bin/bash
# test-inv35-regression-2026-05-21.sh — INV-35 / issue #149 regression.
#
# Replays the live 2026-05-21 #144 / #145 sequence:
#   1. Dev wrapper finished cleanly: log ends `end_turn|completed`.
#   2. ~2h11m later, review wrapper ran with REVIEW_BOTS=q, q-bot timed out.
#   3. Review wrapper posted FAILED verdict carrying
#      `<!-- review-verdict: failed-non-substantive cause=bot-timeout -->`.
#   4. Review wrapper flipped issue to `pending-dev`.
#   5. Dispatcher tick fires.
#
# Pre-fix expectation (must FAIL): dispatcher posts INV-12-completed and stalls.
# Post-fix expectation: dispatcher flips back to `pending-review`, no
# INV-12-completed comment, retry counter unchanged.
#
# This is the gating regression test for #149. It exercises the same
# `handle_completed_session_routing` helper used by Step 4b.5.1 with the
# real `classify_recent_review_verdict` parser (no helper mock) so the
# whole pipeline from issue-comments → routing decision is exercised.
#
# Run: bash tests/unit/test-inv35-regression-2026-05-21.sh

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
export PROJECT_ID="test-inv35-reg-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5

BOT_LOGIN_FIXTURE="kane-coding-agent[bot]"
export BOT_LOGIN="$BOT_LOGIN_FIXTURE"

# Side-effect capture
_MOCK_LAST_COMMENT_BODY=""
_MOCK_COMMENT_COUNT=0
_MOCK_LABEL_SWAPS=""
_MOCK_DISPATCH_CALLS=""
_MOCK_POST_TOKEN_CALLS=""
_MOCK_NOTICE_PRESENT="0"
_MOCK_FLIP_COUNT=0
_MOCK_COMMENTS_JSON='[]'

# Stub gh handles two query shapes:
#   1. `gh issue view ... --json comments -q <jq>` for the verdict classifier
#      (uses the full _MOCK_COMMENTS_JSON via jq query)
#   2. `gh issue view ... -q [...contains(<marker>)...] | length` for
#      idempotency checks (returns _MOCK_NOTICE_PRESENT directly)
#   3. `gh issue comment --body <body>` to capture posts
gh() {
  # [#393] itp_list_comments reads REST (gh api --paginate --slurp .../comments).
  # Serve the GraphQL-style fixture converted to REST page shape (type=Bot iff
  # login ends [bot]; id=ordinal), so authorKind derivation works unchanged.
  if [[ "${1:-}" == "api" && "${2:-}" == "--paginate" ]]; then
    jq '(if type == "object" then (.comments // []) else . end) | [ [ .[] | {id: 0, user: {login: (.author.login // ""), type: (if ((.author.login // "") | endswith("[bot]")) then "Bot" else "User" end)}, body: (.body // ""), created_at: (.createdAt // null)} ] | to_entries | map(.value + {id: (.key + 1)}) ]' <<<"${_MOCK_COMMENTS_JSON:-[]}"
    return 0
  fi
  local cmd="${1:-}"
  local sub="${2:-}"
  if [[ "$cmd" == "issue" && "$sub" == "comment" ]]; then
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
  if [[ "$cmd" == "issue" && "$sub" == "view" ]]; then
    local jq_query=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-q" || "$1" == "--jq" ]]; then
        jq_query="$2"
        break
      fi
      shift
    done
    # Idempotency-style query (contains "<marker>")
    if [[ "$jq_query" == *"contains("* ]]; then
      printf '%s\n' "$_MOCK_NOTICE_PRESENT"
      return 0
    fi
    # Real classifier query — apply jq against {comments: <json>}
    if [[ -n "$jq_query" ]]; then
      printf '%s' "{\"comments\":$_MOCK_COMMENTS_JSON}" | jq -r "$jq_query"
      return 0
    fi
    printf '%s' "$_MOCK_COMMENTS_JSON"
    return 0
  fi
  return 0
}
export -f gh

# Mock side-effect functions used by routing
log() { :; }
label_swap() {
  _MOCK_LABEL_SWAPS+="${1}:${2}:${3} "
}
mark_stalled() {
  : # not expected on the regression case
}
post_dispatch_token() {
  _MOCK_POST_TOKEN_CALLS+="${1}:${2} "
}
dispatch() {
  _MOCK_DISPATCH_CALLS+="${1}:${2} "
}
count_review_aware_flips() {
  printf '%s' "$_MOCK_FLIP_COUNT"
}

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

# Re-define mocks AFTER sourcing.
gh() {
  # [#393] itp_list_comments reads REST (gh api --paginate --slurp .../comments).
  # Serve the GraphQL-style fixture converted to REST page shape (type=Bot iff
  # login ends [bot]; id=ordinal), so authorKind derivation works unchanged.
  if [[ "${1:-}" == "api" && "${2:-}" == "--paginate" ]]; then
    jq '(if type == "object" then (.comments // []) else . end) | [ [ .[] | {id: 0, user: {login: (.author.login // ""), type: (if ((.author.login // "") | endswith("[bot]")) then "Bot" else "User" end)}, body: (.body // ""), created_at: (.createdAt // null)} ] | to_entries | map(.value + {id: (.key + 1)}) ]' <<<"${_MOCK_COMMENTS_JSON:-[]}"
    return 0
  fi
  local cmd="${1:-}"
  local sub="${2:-}"
  if [[ "$cmd" == "issue" && "$sub" == "comment" ]]; then
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
  if [[ "$cmd" == "issue" && "$sub" == "view" ]]; then
    local jq_query=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-q" || "$1" == "--jq" ]]; then
        jq_query="$2"
        break
      fi
      shift
    done
    if [[ "$jq_query" == *"contains("* ]]; then
      printf '%s\n' "$_MOCK_NOTICE_PRESENT"
      return 0
    fi
    if [[ -n "$jq_query" ]]; then
      printf '%s' "{\"comments\":$_MOCK_COMMENTS_JSON}" | jq -r "$jq_query"
      return 0
    fi
    printf '%s' "$_MOCK_COMMENTS_JSON"
    return 0
  fi
  return 0
}
log() { :; }
label_swap() { _MOCK_LABEL_SWAPS+="${1}:${2}:${3} "; }
mark_stalled() { :; }
post_dispatch_token() { _MOCK_POST_TOKEN_CALLS+="${1}:${2} "; }
dispatch() { _MOCK_DISPATCH_CALLS+="${1}:${2} "; }
count_review_aware_flips() { printf '%s' "$_MOCK_FLIP_COUNT"; }

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle=[$needle]"
    echo "      body=[$haystack]"
    FAIL=$((FAIL + 1))
  fi
}

mkc() {
  jq -n --arg l "$1" --arg c "$2" --arg b "$3" \
    '{author:{login:$l}, createdAt:$c, body:$b}'
}

# ---------------------------------------------------------------------------
echo "=== TC-INV35-REG-001: 2026-05-21 #144 / #145 sequence ==="
# ---------------------------------------------------------------------------

# Build comment timeline:
#   03:18 — dev session ended (we model this via session_end_iso below;
#           the dev session-end comment itself is not part of the verdict feed).
#   05:29 — review wrapper FAILED verdict with the trailer.
SESSION_ID_FIXTURE="11111111-aaaa-bbbb-cccc-222222222222"
SESSION_END="2026-05-21T03:18:00Z"
REVIEW_VERDICT_BODY=$(printf '%s\n%s\n%s\n%s\n' \
  "Review FAILED — q-bot did not respond within 3 min." \
  "Review Session: ${SESSION_ID_FIXTURE}" \
  "Reviewed HEAD: \`abc123\`" \
  "<!-- review-verdict: failed-non-substantive cause=bot-timeout -->")

_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson dev_done "$(mkc "$BOT_LOGIN_FIXTURE" "2026-05-21T03:18:00Z" "Dev Session ID: \`${SESSION_ID_FIXTURE}\`")" \
  --argjson review "$(mkc "$BOT_LOGIN_FIXTURE" "2026-05-21T05:29:00Z" "$REVIEW_VERDICT_BODY")" \
  '[$dev_done,$review]')

# Sanity: classifier alone returns expected verdict
v=""; c=""
classify_recent_review_verdict 144 "$SESSION_END" v c
assert_eq "REG-001 classifier verdict" "failed-non-substantive" "$v"
assert_eq "REG-001 classifier cause" "bot-timeout" "$c"

# Now drive routing: must NOT post INV-12-completed; MUST flip to pending-review.
_MOCK_NOTICE_PRESENT="0"
_MOCK_FLIP_COUNT=0
handle_completed_session_routing 144 "$SESSION_ID_FIXTURE" "$SESSION_END"
rc=$?
assert_eq "REG-001 routing returns 0 (handled)" "0" "$rc"

# Critical assertion: must NOT post INV-12-completed marker (that was the bug).
if [[ "$_MOCK_LAST_COMMENT_BODY" != *"INV-12-completed"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: REG-001 NO INV-12-completed marker (this was the bug)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: REG-001 INV-12-completed marker WAS posted (regression)"
  echo "      body=[$_MOCK_LAST_COMMENT_BODY]"
  FAIL=$((FAIL + 1))
fi

assert_eq "REG-001 label flip to pending-review" "144:pending-dev:pending-review " "$_MOCK_LABEL_SWAPS"
assert_contains "REG-001 marker prefix" "<!-- review-aware-flip:non-substantive" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "REG-001 marker cause" "cause=bot-timeout" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "REG-001 marker session-binding" "session=${SESSION_ID_FIXTURE}" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "REG-001 marker has human-readable line" "Re-routing to review" "$_MOCK_LAST_COMMENT_BODY"

# Retry counter must not have been consumed (no dispatch fired)
assert_eq "REG-001 no dispatch" "" "$_MOCK_DISPATCH_CALLS"
assert_eq "REG-001 no dispatch token (Step 3 will post on next tick)" "" "$_MOCK_POST_TOKEN_CALLS"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-INV35-REG-002: same sequence, no trailer (pre-INV-35 review wrapper) ==="
# ---------------------------------------------------------------------------

# Reset
_MOCK_LAST_COMMENT_BODY=""
_MOCK_COMMENT_COUNT=0
_MOCK_LABEL_SWAPS=""
_MOCK_DISPATCH_CALLS=""
_MOCK_POST_TOKEN_CALLS=""

REVIEW_VERDICT_NO_TRAILER=$(printf '%s\n%s\n' \
  "Review FAILED — q-bot did not respond within 3 min." \
  "Review Session: ${SESSION_ID_FIXTURE}")
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson dev_done "$(mkc "$BOT_LOGIN_FIXTURE" "2026-05-21T03:18:00Z" "Dev Session ID: \`${SESSION_ID_FIXTURE}\`")" \
  --argjson review "$(mkc "$BOT_LOGIN_FIXTURE" "2026-05-21T05:29:00Z" "$REVIEW_VERDICT_NO_TRAILER")" \
  '[$dev_done,$review]')

# Prepare a writable log so dev-new can truncate.
LOG_FILE_REG2="/tmp/agent-${PROJECT_ID}-issue-145.log"
printf 'old log content\n' > "$LOG_FILE_REG2"

handle_completed_session_routing 145 "$SESSION_ID_FIXTURE" "$SESSION_END"
rc=$?
assert_eq "REG-002 routing returns 0" "0" "$rc"
assert_eq "REG-002 fallback dispatches dev-new (substantive default)" "dev-new:145 " "$_MOCK_DISPATCH_CALLS"
assert_eq "REG-002 label swap to in-progress" "145:pending-dev:in-progress " "$_MOCK_LABEL_SWAPS"
assert_contains "REG-002 INV-35-fresh-dev marker present" "INV-35-fresh-dev:" "$_MOCK_LAST_COMMENT_BODY"
log_size=$(stat -c '%s' "$LOG_FILE_REG2" 2>/dev/null || echo "missing")
assert_eq "REG-002 log truncated" "0" "$log_size"

# Cleanup
rm -f "$LOG_FILE_REG2"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
