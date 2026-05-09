#!/bin/bash
# test-lib-dispatch.sh — Unit tests for the helpers extracted in PR-3.
#
# Tests pure-logic helpers in lib-dispatch.sh. Mocks `gh` by overriding the
# function in the test shell. Tested helpers:
#   - extract_dev_session_id ([INV-03] Dev not Review)
#   - count_retries          (stalled-cutoff rule, [INV-05])
#   - last_reviewed_head     ([INV-04] format)
#   - pr_idle_seconds        (boundary, cross-platform date)
#   - was_just_dispatched    ([INV-09])
#
# Helpers not unit-tested here (manual verification — body byte-identical to
# original SKILL.md bash):
#   - check_deps_resolved (sed/grep on issue body, multiple gh calls per dep)
#   - count_active, list_*  (single jq query each, trivial passthrough)
#   - fetch_pr_for_issue, ci_is_green (gh wrappers, hard to stub usefully)
#   - pid_alive, get_pid    (filesystem + kill -0)
#   - label_swap, mark_stalled (single gh issue edit / comment)
#
# Run: bash tests/unit/test-lib-dispatch.sh

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

# Default mocked gh: returns nothing. Tests override _MOCK_COMMENTS_JSON
# to control what `gh issue view ... --json comments -q ...` returns: the
# mock pipes the fixture through jq with the requested -q expression.
_MOCK_COMMENTS_JSON=""
gh() {
  # Find the -q expression in the args, if any.
  local q_expr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -q) q_expr="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -n "$q_expr" && -n "$_MOCK_COMMENTS_JSON" ]]; then
    jq -r "$q_expr" <<<"$_MOCK_COMMENTS_JSON"
  fi
}
export -f gh

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"

# lib-dispatch.sh sets -euo pipefail — turn off -e for tests since some
# helpers are EXPECTED to fail (e.g. extract_dev_session_id with the broken
# regex from issue #70).
set +e

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

# ---------------------------------------------------------------------------
echo "=== extract_dev_session_id ([INV-03]) ==="
# ---------------------------------------------------------------------------

# PR-4 (#70 fix) flipped the regex from Python-style `(?P<id>...)` to
# Oniguruma `(?<id>...)`. Tests now assert REAL extraction. See [INV-16].

_MOCK_COMMENTS_JSON='{"comments":[{"body":"**Agent Session Report (Dev)**\nDev Session ID: `abc-123-def`\nExit code: 0"}]}'
assert_eq "Dev Session ID extracted from one comment" "abc-123-def" "$(extract_dev_session_id 99)"

_MOCK_COMMENTS_JSON='{"comments":[{"body":"Review PASSED ... Review Session ID: `xyz-789`"}]}'
assert_eq "Review Session ID does NOT match Dev pattern (regex anchored on 'Dev Session ID')" "" "$(extract_dev_session_id 99)"

_MOCK_COMMENTS_JSON='{"comments":[{"body":"Dev Session ID: `older-dev-id`"},{"body":"Review Session: `some-review`"},{"body":"Dev Session ID: `newer-dev-id`"}]}'
assert_eq "latest Dev Session ID wins across multiple comments" "newer-dev-id" "$(extract_dev_session_id 99)"

_MOCK_COMMENTS_JSON='{"comments":[]}'
assert_eq "no comments → empty" "" "$(extract_dev_session_id 99)"

# ---------------------------------------------------------------------------
echo ""
echo "=== count_retries ([INV-05] stalled-cutoff rule) ==="
# ---------------------------------------------------------------------------

# 2 failures, no stall comment → counter = 2 (cutoff = epoch).
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Agent Session Report (Dev)\nExit code: 1"},
  {"createdAt":"2026-01-02T00:00:00Z","body":"Agent Session Report (Dev)\nExit code: 1"}
]}'
assert_eq "2 failures, no stall comment → 2" "2" "$(count_retries 99)"

# 2 pre-stall failures + 1 post-stall failure → counter = 1.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Agent Session Report (Dev)\nExit code: 1"},
  {"createdAt":"2026-01-02T00:00:00Z","body":"Agent Session Report (Dev)\nExit code: 1"},
  {"createdAt":"2026-01-03T00:00:00Z","body":"Marking as stalled"},
  {"createdAt":"2026-01-04T00:00:00Z","body":"Agent Session Report (Dev)\nExit code: 1"}
]}'
assert_eq "2 pre-stall + 1 post-stall failures → 1 (cutoff applies)" "1" "$(count_retries 99)"

# Successful Dev session report (Exit code: 0) does NOT count.
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Agent Session Report (Dev)\nExit code: 0"}
]}'
assert_eq "Exit code: 0 dev report does NOT count" "0" "$(count_retries 99)"

# Dispatcher crash regex matches "Task appears to have crashed (no PR found)".
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Task appears to have crashed (no PR found). Moving to pending-dev for retry."}
]}'
assert_eq "dispatcher crash 'Task appears to have crashed (no PR found)' → 1" "1" "$(count_retries 99)"

# Forward-progress comment must NOT count [INV-06].
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Dev process exited (PR found). Moving to pending-review for assessment."}
]}'
assert_eq "forward-progress 'Dev process exited (PR found)' does NOT count [INV-06]" "0" "$(count_retries 99)"

# Forward-progress no-new-commits comment must NOT count [INV-06].
_MOCK_COMMENTS_JSON='{"comments":[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Dev process exited (no new commits since last review at `abc1234`). Moving to pending-dev for retry."}
]}'
assert_eq "forward-progress 'no new commits' does NOT count [INV-06]" "0" "$(count_retries 99)"

# ---------------------------------------------------------------------------
echo ""
echo "=== last_reviewed_head ([INV-04] format, [INV-07] empty fallthrough) ==="
# ---------------------------------------------------------------------------

_MOCK_COMMENTS_JSON='{"comments":[{"body":"Reviewed HEAD: `abc1234567890def` (issue #99, session `s1`)"}]}'
assert_eq "trailer present → SHA returned" "abc1234567890def" "$(last_reviewed_head 99)"

_MOCK_COMMENTS_JSON='{"comments":[{"body":"Some unrelated comment"}]}'
assert_eq "no trailer → empty [INV-07]" "" "$(last_reviewed_head 99)"

# Use real-looking lowercase-hex SHAs (regex is `[0-9a-f]{7,40}`).
_MOCK_COMMENTS_JSON='{"comments":[
  {"body":"Reviewed HEAD: `aaaaaaa1111` (issue #99, session `s1`)"},
  {"body":"Reviewed HEAD: `bbbbbbb2222` (issue #99, session `s2`)"}
]}'
assert_eq "multiple trailers → latest wins" "bbbbbbb2222" "$(last_reviewed_head 99)"

# Short SHA (7 chars minimum per the regex `[0-9a-f]{7,40}`).
_MOCK_COMMENTS_JSON='{"comments":[{"body":"Reviewed HEAD: `abc1234` (issue #99, session `s1`)"}]}'
assert_eq "7-char short SHA accepted" "abc1234" "$(last_reviewed_head 99)"

# ---------------------------------------------------------------------------
echo ""
echo "=== pr_idle_seconds (boundary, cross-platform date) ==="
# ---------------------------------------------------------------------------

# 301s in the past should yield ~301.
NOW_EPOCH=$(date -u +%s)
PAST_EPOCH=$((NOW_EPOCH - 301))
PAST_ISO=$(date -u -d "@$PAST_EPOCH" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || date -u -r "$PAST_EPOCH" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)

if [ -n "$PAST_ISO" ]; then
  out=$(pr_idle_seconds "$PAST_ISO")
  if (( out >= 299 && out <= 305 )); then
    echo -e "  ${GREEN}PASS${NC}: pr_idle_seconds for 301s-old returns ~301 (got $out)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: pr_idle_seconds for 301s-old returned $out, expected ~301"
    FAIL=$((FAIL + 1))
  fi
fi

# Malformed timestamp → empty (caller fails closed).
out=$(pr_idle_seconds 'not-a-timestamp' 2>/dev/null)
assert_eq "malformed timestamp → empty (fail closed)" "" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== was_just_dispatched ([INV-09]) ==="
# ---------------------------------------------------------------------------

JUST_DISPATCHED="58 59 60"
if was_just_dispatched 59; then
  echo -e "  ${GREEN}PASS${NC}: 59 in '58 59 60' → IN"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: 59 should be IN '58 59 60'"; FAIL=$((FAIL + 1))
fi

if was_just_dispatched 61; then
  echo -e "  ${RED}FAIL${NC}: 61 should NOT be IN '58 59 60'"; FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: 61 not in '58 59 60' → NOT_IN"; PASS=$((PASS + 1))
fi

JUST_DISPATCHED="158"
if was_just_dispatched 58; then
  echo -e "  ${RED}FAIL${NC}: 58 should NOT be IN '158' (no substring match)"; FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: 58 not in '158' (boundary check) → NOT_IN"; PASS=$((PASS + 1))
fi

unset JUST_DISPATCHED
if was_just_dispatched 58; then
  echo -e "  ${RED}FAIL${NC}: unset JUST_DISPATCHED should be NOT_IN"; FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: unset JUST_DISPATCHED → NOT_IN (defensive)"; PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
