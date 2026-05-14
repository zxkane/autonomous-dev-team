#!/bin/bash
# test-list-selectors-terminal-defense.sh — Regression for issue #115 Bug C
# (re-scoped: after investigation, the actual third bug was that
# list_pending_review and list_pending_dev didn't subtract `approved`,
# same class as Bug A's list_stale_candidates fix in PR #116).
#
# This pins the same defense across both selectors:
#   - approved residue is excluded
#   - stalled residue is excluded
#   - happy path (clean autonomous + transitional) still picked up
#
# Stub strategy mirrors test-list-stale-candidates-approved.sh: override
# `gh` to feed _MOCK_ISSUE_LIST through jq with whatever -q expression
# the selector passes.
#
# Run: bash tests/unit/test-list-selectors-terminal-defense.sh

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
export PROJECT_ID=test-selectors-defense
export MAX_RETRIES=3
export MAX_CONCURRENT=5

_MOCK_ISSUE_LIST=""
gh() {
  local q_expr=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -q) q_expr="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  if [[ -n "$q_expr" ]]; then
    jq "$q_expr" <<<"${_MOCK_ISSUE_LIST:-[]}"
  else
    printf '%s' "${_MOCK_ISSUE_LIST:-[]}"
  fi
}
export -f gh

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

assert_count() {
  local desc="$1" expected="$2" json="$3"
  local actual
  actual=$(jq 'length' <<<"$json")
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc (count=$actual)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected count=$expected"
    echo "      actual count=  $actual"
    echo "      json=          $json"
    FAIL=$((FAIL + 1))
  fi
}

mklabels() {
  local out="["
  local first=1
  for n in "$@"; do
    if [[ $first -eq 1 ]]; then first=0; else out+=","; fi
    out+="{\"name\":\"$n\"}"
  done
  out+="]"
  printf '%s' "$out"
}

mkissue() {
  local num="$1"; shift
  printf '{"number":%s,"labels":%s}' "$num" "$(mklabels "$@")"
}

echo "=== TC-PREV: list_pending_review terminal defense ==="

# TC-PREV-001: pending-review + approved → MUST be excluded
_MOCK_ISSUE_LIST="[$(mkissue 301 autonomous pending-review approved)]"
out=$(list_pending_review)
assert_count "TC-PREV-001 pending-review+approved excluded" 0 "$out"

# TC-PREV-002: pending-review + stalled → MUST be excluded
_MOCK_ISSUE_LIST="[$(mkissue 302 autonomous pending-review stalled)]"
out=$(list_pending_review)
assert_count "TC-PREV-002 pending-review+stalled excluded" 0 "$out"

# TC-PREV-003: clean pending-review → still picked up
_MOCK_ISSUE_LIST="[$(mkissue 303 autonomous pending-review)]"
out=$(list_pending_review)
assert_count "TC-PREV-003 clean pending-review detected" 1 "$out"

# TC-PREV-004: pending-review + reviewing → existing exclusion still applies
_MOCK_ISSUE_LIST="[$(mkissue 304 autonomous pending-review reviewing)]"
out=$(list_pending_review)
assert_count "TC-PREV-004 pending-review+reviewing excluded (pre-existing)" 0 "$out"

echo
echo "=== TC-PDEV: list_pending_dev terminal defense ==="

# TC-PDEV-001: pending-dev + approved → MUST be excluded
_MOCK_ISSUE_LIST="[$(mkissue 401 autonomous pending-dev approved)]"
out=$(list_pending_dev)
assert_count "TC-PDEV-001 pending-dev+approved excluded" 0 "$out"

# TC-PDEV-002: pending-dev + stalled → MUST be excluded
_MOCK_ISSUE_LIST="[$(mkissue 402 autonomous pending-dev stalled)]"
out=$(list_pending_dev)
assert_count "TC-PDEV-002 pending-dev+stalled excluded" 0 "$out"

# TC-PDEV-003: clean pending-dev → still picked up
_MOCK_ISSUE_LIST="[$(mkissue 403 autonomous pending-dev)]"
out=$(list_pending_dev)
assert_count "TC-PDEV-003 clean pending-dev detected" 1 "$out"

# TC-PDEV-004: mixed bag — only #403-shaped issues survive
_MOCK_ISSUE_LIST="[$(mkissue 411 autonomous pending-dev approved),$(mkissue 412 autonomous pending-dev stalled),$(mkissue 413 autonomous pending-dev)]"
out=$(list_pending_dev)
assert_count "TC-PDEV-004 mixed: only the clean one returned" 1 "$out"

echo
echo "=== Cross-selector sanity: same fixture, different selectors ==="

# Same residue should be invisible to BOTH selectors at once.
_MOCK_ISSUE_LIST="[$(mkissue 500 autonomous approved pending-review pending-dev)]"
out_prev=$(list_pending_review)
out_pdev=$(list_pending_dev)
assert_count "list_pending_review excludes approved-with-both-residues" 0 "$out_prev"
assert_count "list_pending_dev excludes approved-with-both-residues" 0 "$out_pdev"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
