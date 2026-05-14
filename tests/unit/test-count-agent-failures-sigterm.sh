#!/bin/bash
# test-count-agent-failures-sigterm.sh — Regression for issue #121 Fix A.
#
# `count_agent_failures` previously counted every Session Report whose
# `Exit code` is non-zero. That includes SIGTERM (143) and SIGKILL (137)
# from `dispatch-local.sh::kill_stale_wrapper` — i.e. the dispatcher's
# own kills were scored as agent failures, fueling premature
# `mark_stalled` calls.
#
# Fix A: exclude exit codes 143 and 137 from the agent-failure count.
# Genuine failures (1, 2, 124-timeout, custom non-143/137 exits) still
# count. The wall-clock timeout exit 124 is the catch-all for genuine
# hangs and remains counted.
#
# Run: bash tests/unit/test-count-agent-failures-sigterm.sh

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
export PROJECT_ID=test-caf
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# `gh` stub: feeds _MOCK_COMMENTS_JSON through jq with the requested -q
# expression. Same pattern as test-lib-dispatch.sh / test-step0-hygiene.sh.
_MOCK_COMMENTS_JSON=""
gh() {
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
set +e

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected: $expected"
    echo "      actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# Build a comments JSON wrapper around an array of {createdAt, body} objects.
# Each Session Report is a comment whose body matches the regex used by
# count_agent_failures: 'Agent Session Report \(Dev\)' AND a specific
# 'Exit code: <N>' line.
mk_session_report() {
  # mk_session_report "<iso-ts>" <exit-code>
  local ts="$1" code="$2"
  jq -n --arg ts "$ts" --arg code "$code" \
    '{createdAt: $ts, body: ("**Agent Session Report (Dev)**\n- Dev Session ID: `abc-\($code)`\n- Exit code: \($code)\n- Mode: new\n- Timestamp: \($ts)")}'
}

mk_comments_json() {
  # mk_comments_json <comment1> <comment2> ...
  jq -n --argjson arr "$(printf '%s\n' "$@" | jq -s '.')" \
    '{comments: $arr}'
}

# ===================================================================
echo "=== TC-CAF-001..007: count_agent_failures excludes SIGTERM/SIGKILL ==="

# TC-CAF-001 — exit 0 → 0 (pre-existing, no regression)
_MOCK_COMMENTS_JSON=$(mk_comments_json \
  "$(mk_session_report '2026-05-14T07:00:00Z' '0')")
out=$(count_agent_failures 1)
assert_eq "TC-CAF-001 exit 0 → not counted" "0" "$out"

# TC-CAF-002 — exit 1 → 1 (genuine crash, must still count)
_MOCK_COMMENTS_JSON=$(mk_comments_json \
  "$(mk_session_report '2026-05-14T07:00:00Z' '1')")
out=$(count_agent_failures 2)
assert_eq "TC-CAF-002 exit 1 (genuine crash) → counted" "1" "$out"

# TC-CAF-003 — exit 124 (wall-clock timeout) → 1 (must count: genuine hang)
_MOCK_COMMENTS_JSON=$(mk_comments_json \
  "$(mk_session_report '2026-05-14T07:00:00Z' '124')")
out=$(count_agent_failures 3)
assert_eq "TC-CAF-003 exit 124 (timeout) → counted" "1" "$out"

# TC-CAF-004 — exit 143 (SIGTERM) → 0 (dispatcher-induced, must NOT count)
_MOCK_COMMENTS_JSON=$(mk_comments_json \
  "$(mk_session_report '2026-05-14T07:00:00Z' '143')")
out=$(count_agent_failures 4)
assert_eq "TC-CAF-004 exit 143 (SIGTERM from kill_stale_wrapper) → not counted" "0" "$out"

# TC-CAF-005 — exit 137 (SIGKILL) → 0 (dispatcher-escalation kill)
_MOCK_COMMENTS_JSON=$(mk_comments_json \
  "$(mk_session_report '2026-05-14T07:00:00Z' '137')")
out=$(count_agent_failures 5)
assert_eq "TC-CAF-005 exit 137 (SIGKILL escalation) → not counted" "0" "$out"

# TC-CAF-006 — exit 144 (custom; must NOT collide with 143 prefix-match)
_MOCK_COMMENTS_JSON=$(mk_comments_json \
  "$(mk_session_report '2026-05-14T07:00:00Z' '144')")
out=$(count_agent_failures 6)
assert_eq "TC-CAF-006 exit 144 (genuine — must NOT match 143 by prefix)" "1" "$out"

# TC-CAF-007 — mixed bag: counts only genuine failures
_MOCK_COMMENTS_JSON=$(mk_comments_json \
  "$(mk_session_report '2026-05-14T07:00:00Z' '0')" \
  "$(mk_session_report '2026-05-14T07:05:00Z' '1')" \
  "$(mk_session_report '2026-05-14T07:10:00Z' '143')" \
  "$(mk_session_report '2026-05-14T07:15:00Z' '137')" \
  "$(mk_session_report '2026-05-14T07:20:00Z' '124')" \
  "$(mk_session_report '2026-05-14T07:25:00Z' '2')" \
  "$(mk_session_report '2026-05-14T07:30:00Z' '144')")
# Genuine: 1, 124, 2, 144 = 4
# Excluded: 0, 143, 137 = 3
out=$(count_agent_failures 7)
assert_eq "TC-CAF-007 mixed bag → only genuine failures counted (4)" "4" "$out"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
