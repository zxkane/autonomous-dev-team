#!/bin/bash
# test-dispatcher-step4-stale-verdict.sh — Unit tests for issue #106.
#
# Step 4a.5 PR-exists short-circuit must consult last_reviewed_head before
# routing to pending-review. If the current PR HEAD has already been
# reviewed (so the prior verdict was FAILED — otherwise the issue wouldn't
# be in pending-dev), keep the issue in pending-dev and surface a one-time
# idempotent stale-verdict notice. Only flip to pending-review when the
# HEAD has changed (new commits to assess) or no prior `Reviewed HEAD:`
# trailer exists (first review).
#
# The Step 4a.5 logic is extracted from dispatcher-tick.sh into a new
# lib-dispatch.sh helper `handle_pending_dev_pr_exists` so it can be unit
# tested in isolation.
#
# NOTE ([INV-98], #351): the same-HEAD park is no longer unconditional — it now
# DELEGATES a `completed` dev session to `handle_completed_session_routing` and
# only parks the residual cases (no session id / session not completed). The
# same-HEAD cases here exercise the RESIDUAL park path: the mocked environment
# resolves no `Dev Session ID:` trailer (real `extract_dev_session_id` over the
# stub gh) and has no `{"type":"result"}` agent log, so `is_session_completed`
# returns false and the helper falls through to the `stale-verdict:` park exactly
# as documented. The delegation branch is covered by
# `test-issue-351-stale-verdict-delegate.sh`.
#
# Run: bash tests/unit/test-dispatcher-step4-stale-verdict.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Required env (lib-dispatch.sh enforces these via : "${VAR:?...}")
export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-proj
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# ---------------------------------------------------------------------------
# Mocks — overridden per test case.
#
# We intercept gh/fetch_pr_for_issue/last_reviewed_head/label_swap and
# track which side effects fire so each assertion can verify exactly the
# expected behavior (notice posted exactly once / label swapped / both /
# neither).
# ---------------------------------------------------------------------------
_MOCK_PR_INFO=""           # JSON returned by fetch_pr_for_issue, or "" for no PR
_MOCK_LAST_REVIEWED=""     # last_reviewed_head return value
_MOCK_NOTICE_PRESENT="0"   # "0" (no prior notice) or "1" (already present)
_MOCK_LAST_COMMENT_BODY="" # last gh issue comment --body argument
_MOCK_COMMENT_COUNT=0      # how many gh issue comment calls fired
_MOCK_LABEL_SWAPS=""       # space-separated list of "issue:remove:add" tuples

fetch_pr_for_issue() {
  printf '%s' "$_MOCK_PR_INFO"
}

last_reviewed_head() {
  printf '%s' "$_MOCK_LAST_REVIEWED"
}

label_swap() {
  local issue_num="$1" remove="$2" add="$3"
  _MOCK_LABEL_SWAPS+="${issue_num}:${remove}:${add} "
}

# Mocked gh: handles `gh issue view ... --json comments -q ...` (returns
# the count of contains() matches based on _MOCK_NOTICE_PRESENT) and
# `gh issue comment ... --body ...` (records body / increments counter).
gh() {
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
    # The handler counts prior stale-verdict notices. Post the ITP read-leaf
    # refactor (#281) it runs `itp_list_comments | jq '[.[]|select(contains(
    # marker))]|length' | grep '^0$'`, where itp_list_comments calls a single
    # `gh issue view … --json comments -q '<normalize>'`. So this stub applies
    # the requested `-q` to a synthesized `{comments:[…]}` of _MOCK_NOTICE_PRESENT
    # comments whose body carries the exact `stale-verdict:<head>` marker the
    # handler searches for (head taken from _MOCK_PR_INFO).
    local _q="" _i=1 _j
    while [[ $_i -le $# ]]; do
      if [[ "${!_i}" == "-q" || "${!_i}" == "--jq" ]]; then _j=$((_i+1)); _q="${!_j}"; break; fi
      _i=$((_i+1))
    done
    local _head; _head=$(jq -r '.headRefOid // empty' <<<"${_MOCK_PR_INFO:-{}}" 2>/dev/null)
    local _n="${_MOCK_NOTICE_PRESENT:-0}"; [[ "$_n" =~ ^[0-9]+$ ]] || _n=0
    local _arr; _arr=$(jq -cn --argjson n "$_n" --arg body "PR #42 HEAD already reviewed (\`stale-verdict:${_head}\`)" \
      '{comments: [range($n) | {url:"https://x/issues/1#issuecomment-\(.+1)", author:{login:"my-claw"}, body:$body, createdAt:"2026-06-12T00:00:0\(.)Z"}]}')
    if [[ -n "$_q" ]]; then jq -r "$_q" <<<"$_arr"; else printf '%s' "$_arr"; fi
    return 0
  fi
  return 0
}
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

# Re-define mocks AFTER sourcing the lib so they shadow lib's real
# implementations of fetch_pr_for_issue/last_reviewed_head/label_swap.
fetch_pr_for_issue() {
  printf '%s' "$_MOCK_PR_INFO"
}

last_reviewed_head() {
  printf '%s' "$_MOCK_LAST_REVIEWED"
}

label_swap() {
  local issue_num="$1" remove="$2" add="$3"
  _MOCK_LABEL_SWAPS+="${issue_num}:${remove}:${add} "
}

reset_mocks() {
  _MOCK_PR_INFO=""
  _MOCK_LAST_REVIEWED=""
  _MOCK_NOTICE_PRESENT="0"
  _MOCK_LAST_COMMENT_BODY=""
  _MOCK_COMMENT_COUNT=0
  _MOCK_LABEL_SWAPS=""
  # [INV-98], #351: the same-HEAD branch now consults is_session_completed,
  # which reads /tmp/agent-${PROJECT_ID}-issue-<N>.log for the claude dev CLI.
  # Remove any stray log so the same-HEAD tests deterministically take the
  # residual-park path (no completed session detected → park, not delegate).
  rm -f "/tmp/agent-${PROJECT_ID}-issue-99.log" 2>/dev/null || true
}

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    echo "      haystack='$haystack'"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "=== TC-STALE-VERDICT-1: same HEAD reviewed → keep pending-dev, post notice ==="
# ---------------------------------------------------------------------------

reset_mocks
_MOCK_PR_INFO='{"number":42,"headRefOid":"sha-A"}'
_MOCK_LAST_REVIEWED="sha-A"
_MOCK_NOTICE_PRESENT="0"

handle_pending_dev_pr_exists 99
rc=$?

assert_eq "function returns 0 (caller continues)" "0" "$rc"
assert_eq "label_swap NOT called" "" "$_MOCK_LABEL_SWAPS"
assert_eq "exactly one comment posted" "1" "$_MOCK_COMMENT_COUNT"
assert_contains "comment body contains marker" "stale-verdict:sha-A" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "comment body mentions HEAD reviewed" "already reviewed" "$_MOCK_LAST_COMMENT_BODY"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-STALE-VERDICT-2: HEAD differs → flip to pending-review ==="
# ---------------------------------------------------------------------------

reset_mocks
_MOCK_PR_INFO='{"number":42,"headRefOid":"sha-B"}'
_MOCK_LAST_REVIEWED="sha-A"
_MOCK_NOTICE_PRESENT="0"

handle_pending_dev_pr_exists 99
rc=$?

assert_eq "function returns 0" "0" "$rc"
assert_contains "label swapped pending-dev → pending-review" "99:pending-dev:pending-review" "$_MOCK_LABEL_SWAPS"
assert_eq "exactly one comment posted (Bug 3 transition message)" "1" "$_MOCK_COMMENT_COUNT"
assert_contains "comment body says transitioning to pending-review" "transitioning to pending-review" "$_MOCK_LAST_COMMENT_BODY"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-STALE-VERDICT-3: no prior Reviewed HEAD trailer → flip to pending-review ==="
# ---------------------------------------------------------------------------

reset_mocks
_MOCK_PR_INFO='{"number":42,"headRefOid":"sha-A"}'
_MOCK_LAST_REVIEWED=""    # no prior review
_MOCK_NOTICE_PRESENT="0"

handle_pending_dev_pr_exists 99
rc=$?

assert_eq "function returns 0" "0" "$rc"
assert_contains "label swapped pending-dev → pending-review" "99:pending-dev:pending-review" "$_MOCK_LABEL_SWAPS"
assert_contains "comment body says transitioning to pending-review" "transitioning to pending-review" "$_MOCK_LAST_COMMENT_BODY"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-STALE-VERDICT-4: idempotency — notice already present → no duplicate ==="
# ---------------------------------------------------------------------------

reset_mocks
_MOCK_PR_INFO='{"number":42,"headRefOid":"sha-A"}'
_MOCK_LAST_REVIEWED="sha-A"
_MOCK_NOTICE_PRESENT="1"   # marker already in comments

handle_pending_dev_pr_exists 99
rc=$?

assert_eq "function returns 0" "0" "$rc"
assert_eq "label_swap NOT called" "" "$_MOCK_LABEL_SWAPS"
assert_eq "no duplicate comment posted" "0" "$_MOCK_COMMENT_COUNT"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-STALE-VERDICT-4b: HEAD moved + stale marker still present → flip ==="
# ---------------------------------------------------------------------------
# Recovery scenario: prior tick posted a stale-verdict marker for sha-A,
# but the dev agent has since pushed sha-B. We must NOT let the stale
# marker gate the flip — last_head!=current_head dominates.

reset_mocks
_MOCK_PR_INFO='{"number":42,"headRefOid":"sha-B"}'
_MOCK_LAST_REVIEWED="sha-A"
_MOCK_NOTICE_PRESENT="1"   # prior stale-verdict:sha-A marker still present

handle_pending_dev_pr_exists 99
rc=$?

assert_eq "function returns 0" "0" "$rc"
assert_contains "label swapped pending-dev → pending-review (HEAD wins)" "99:pending-dev:pending-review" "$_MOCK_LABEL_SWAPS"
assert_contains "transition message posted" "transitioning to pending-review" "$_MOCK_LAST_COMMENT_BODY"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-STALE-VERDICT-4c: empty current_head from PR JSON → flip (defensive) ==="
# ---------------------------------------------------------------------------
# If fetch_pr_for_issue returns a PR with empty headRefOid (API schema
# drift / partial JSON), the same-HEAD comparison's `[ -n "$current_head" ]`
# guard must reject the match and route to pending-review (the existing
# Bug 3 path) rather than silently posting a marker for an empty SHA.

reset_mocks
_MOCK_PR_INFO='{"number":42,"headRefOid":""}'
_MOCK_LAST_REVIEWED="sha-A"

handle_pending_dev_pr_exists 99
rc=$?

assert_eq "function returns 0" "0" "$rc"
assert_contains "label swapped pending-dev → pending-review" "99:pending-dev:pending-review" "$_MOCK_LABEL_SWAPS"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-STALE-VERDICT-5: no PR → function returns 1 (caller falls through) ==="
# ---------------------------------------------------------------------------

reset_mocks
_MOCK_PR_INFO=""           # no PR for this issue

handle_pending_dev_pr_exists 99
rc=$?

assert_eq "function returns 1 (caller does NOT continue)" "1" "$rc"
assert_eq "label_swap NOT called" "" "$_MOCK_LABEL_SWAPS"
assert_eq "no comment posted" "0" "$_MOCK_COMMENT_COUNT"

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
