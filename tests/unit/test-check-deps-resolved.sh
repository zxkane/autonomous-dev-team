#!/bin/bash
# test-check-deps-resolved.sh — Regression tests for `check_deps_resolved`
# in lib-dispatch.sh, covering:
#   - #61: MERGED PR dependencies count as resolved
#   - #73: portable (non-GNU) dep extraction
#   - #157: cross-repo `owner/repo#N` deps + list-only extraction
#
# `check_deps_resolved` makes multiple gh calls in sequence:
#   1. `gh issue view N --repo $REPO --json body -q .body`
#   2. for each dep: `gh issue view M --repo <repo> --json state -q .state`
#
# The mock `gh` keys state lookups on "<repo>:<num>" so the same number can
# resolve to different states in different repos.
#
# Run: bash tests/unit/test-check-deps-resolved.sh

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
export PROJECT_ID=test-proj
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# State: which JSON field was requested + what to return.
# _MOCK_BODY: text the body lookup returns
# _MOCK_STATES: associative array, "<repo>:<num>" → "CLOSED"/"MERGED"/"OPEN"
_MOCK_BODY=""
declare -A _MOCK_STATES

gh() {
  local mode="" issue_num="" repo=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      view) issue_num="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --json)
        case "$2" in
          body) mode="body" ;;
          state) mode="state" ;;
        esac
        shift 2
        ;;
      *) shift ;;
    esac
  done
  case "$mode" in
    body)  printf '%s' "$_MOCK_BODY" ;;
    state)
      local s="${_MOCK_STATES[${repo}:${issue_num}]:-OPEN}"
      # Sentinel: __FAIL__ simulates a real `gh issue view` failure
      # (404 / network / unauthorized) — non-zero exit, empty stdout.
      if [[ "$s" == "__FAIL__" ]]; then
        return 1
      fi
      printf '%s' "$s"
      ;;
  esac
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
    echo -e "  ${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

# Reset _MOCK_STATES between tests. `unset` + `declare -A` is the only way
# to clear an associative array reliably across bash 4/5 — assigning `()`
# leaves stale keys on some versions.
_reset_states() {
  unset _MOCK_STATES
  declare -gA _MOCK_STATES
}

# Register state for an arbitrary repo:issue pair.
_set_repo_state() {
  local repo="$1" num="$2" state="$3"
  _MOCK_STATES["${repo}:${num}"]="$state"
}

# Convenience: register state for the default same-repo $REPO.
_set_same_repo_state() {
  _set_repo_state "$REPO" "$1" "$2"
}

# ---------------------------------------------------------------------------
echo "=== check_deps_resolved: no deps section ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Summary
Some text without a Dependencies section."
_reset_states
check_deps_resolved 99
assert_eq "no deps section → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: single CLOSED dep ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Summary
foo

## Dependencies
- #42

## Other"
_reset_states
_set_same_repo_state 42 CLOSED
check_deps_resolved 99
assert_eq "one CLOSED dep → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: single MERGED dep [INV-11, #61 fix] ==="
# ---------------------------------------------------------------------------
_reset_states
_set_same_repo_state 42 MERGED
check_deps_resolved 99
assert_eq "one MERGED dep → resolved (rc=0) — was rc=1 before #61 fix" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: single OPEN dep blocks ==="
# ---------------------------------------------------------------------------
_reset_states
_set_same_repo_state 42 OPEN
check_deps_resolved 99
assert_eq "one OPEN dep → blocked (rc=1)" "1" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: multiple deps mixed states ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Dependencies
- #1 something
- #2 something
- #3 something
"
_reset_states
_set_same_repo_state 1 CLOSED
_set_same_repo_state 2 MERGED
_set_same_repo_state 3 CLOSED
check_deps_resolved 99
assert_eq "all CLOSED+MERGED → resolved (rc=0) [#73 grep portability + #61 MERGED]" "0" "$?"

_reset_states
_set_same_repo_state 1 CLOSED
_set_same_repo_state 2 MERGED
_set_same_repo_state 3 OPEN
check_deps_resolved 99
assert_eq "any one OPEN among three → blocked (rc=1)" "1" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: dep numbers extracted with portable regex (#73) ==="
# ---------------------------------------------------------------------------
# Regression guard: dep extraction must strip the leading `#` and pass bare
# numbers to `gh issue view`. If the # is not stripped, our mock returns
# the default "OPEN" → blocked, so a passing test here proves stripping works.

_MOCK_BODY="## Dependencies
- depends on #100 and #200
- and also #300
"
_reset_states
_set_same_repo_state 100 CLOSED
_set_same_repo_state 200 CLOSED
_set_same_repo_state 300 CLOSED
check_deps_resolved 99
assert_eq "portable extraction strips '#' prefix from dep numbers (#73)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: cross-repo dep, CLOSED in remote (#157) ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Dependencies
- other-owner/other-repo#7
"
_reset_states
_set_repo_state other-owner/other-repo 7 CLOSED
check_deps_resolved 99
assert_eq "cross-repo CLOSED dep → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: cross-repo dep, MERGED in remote (#157) ==="
# ---------------------------------------------------------------------------
_reset_states
_set_repo_state other-owner/other-repo 7 MERGED
check_deps_resolved 99
assert_eq "cross-repo MERGED dep → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: cross-repo dep, OPEN in remote (#157) ==="
# ---------------------------------------------------------------------------
_reset_states
_set_repo_state other-owner/other-repo 7 OPEN
check_deps_resolved 99
assert_eq "cross-repo OPEN dep → blocked (rc=1)" "1" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: cross-repo same number resolves to different state (#157) ==="
# ---------------------------------------------------------------------------
# Same number in two repos must NOT collide. #42 is OPEN in $REPO but
# CLOSED in `other-owner/other-repo` — only the cross-repo ref is listed,
# so the result must be unblocked.
_MOCK_BODY="## Dependencies
- other-owner/other-repo#42
"
_reset_states
_set_same_repo_state 42 OPEN
_set_repo_state other-owner/other-repo 42 CLOSED
check_deps_resolved 99
assert_eq "same number, different repos: cross-repo CLOSED wins → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: mixed same-repo + cross-repo (#157) ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Dependencies
- #42
- other-owner/other-repo#7
"
_reset_states
_set_same_repo_state 42 CLOSED
_set_repo_state other-owner/other-repo 7 OPEN
check_deps_resolved 99
assert_eq "same-repo CLOSED + cross-repo OPEN → blocked (rc=1)" "1" "$?"

_reset_states
_set_same_repo_state 42 CLOSED
_set_repo_state other-owner/other-repo 7 MERGED
check_deps_resolved 99
assert_eq "same-repo CLOSED + cross-repo MERGED → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: prose between headings does NOT block (#157) ==="
# ---------------------------------------------------------------------------
# Pre-#157, a prose line `requires #4470` between `## Dependencies` and the
# next `## ` heading was greedy-extracted. If 4470 doesn't exist in $REPO,
# `gh issue view` returns empty state and the dep was treated as unresolved
# — silent permanent block. After #157, prose is ignored entirely.
_MOCK_BODY="## Dependencies

This issue does not directly depend on anything, but is related to
the work happening in #4470 — see that PR for context.

## Acceptance Criteria
"
_reset_states
# 4470 is intentionally NOT registered — pre-#157 this would have caused
# a silent block. Post-fix, the prose line is ignored.
check_deps_resolved 99
assert_eq "prose-embedded #N reference (no list marker) → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: blockquote does NOT block (#157) ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Dependencies

> Note: requires other-owner/other-repo#4470 to be merged first.

## Other
"
_reset_states
check_deps_resolved 99
assert_eq "blockquote-embedded cross-repo ref → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: numbered list items are extracted (#157) ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Dependencies

1. #1
2. other-owner/other-repo#2

## Other
"
_reset_states
_set_same_repo_state 1 CLOSED
_set_repo_state other-owner/other-repo 2 CLOSED
check_deps_resolved 99
assert_eq "numbered list (1./2.) → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: 'None' marker → resolved (#157 acceptance) ==="
# ---------------------------------------------------------------------------
_MOCK_BODY="## Dependencies

None.

## Other
"
_reset_states
check_deps_resolved 99
assert_eq "'None' (no list items, no refs) → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: URL-form ref in prose does NOT block (#157) ==="
# ---------------------------------------------------------------------------
# A literal GitHub URL on a prose line — including the trailing `#NNN`
# fragment — must NOT be parsed as a dep. URL refs aren't supported syntax.
_MOCK_BODY="## Dependencies

See https://github.com/other-owner/other-repo/issues/123 for related context.

## Other
"
_reset_states
check_deps_resolved 99
assert_eq "URL fragment in prose → resolved (rc=0)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== check_deps_resolved: failed lookup blocks AND warns (INV-39) ==="
# ---------------------------------------------------------------------------
# Cross-repo ref to a non-existent / unauthorized repo: the real `gh issue
# view` exits non-zero with empty stdout. The dispatcher MUST fail-safe
# (return 1) AND emit a stderr warning naming the failed ref. Without the
# warning, a typo silently recreates the #157 bug class.
_MOCK_BODY="## Dependencies
- typo-owner/nonexistent#456
"
_reset_states
_set_repo_state typo-owner/nonexistent 456 __FAIL__
err=$(check_deps_resolved 99 2>&1 >/dev/null)
rc=$?
assert_eq "failed cross-repo lookup → blocked (rc=1)" "1" "$rc"
if [[ "$err" == *"WARNING: lookup failed for typo-owner/nonexistent#456"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: failed lookup emits stderr warning naming the ref"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: missing stderr warning (got: ${err})"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
