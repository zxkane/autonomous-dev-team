#!/bin/bash
# test-list-stale-candidates-approved.sh — Regression for issue #115 Bug A.
#
# `list_stale_candidates` (Step 5 stale-detection in lib-dispatch.sh)
# previously selected every issue with `in-progress` or `reviewing`
# without subtracting `approved`. When an `approved` issue still carried
# a transitional label, Step 5 misclassified it as stale and swapped to
# `pending-dev`, re-arming Step 4 on the next tick — infinite token-burn
# loop.
#
# Mirrors the fixture-and-stub pattern from test-lib-dispatch.sh: stub
# `gh issue list` to emit a controlled JSON array, then run the
# `list_stale_candidates` jq pipeline against it.
#
# Run: bash tests/unit/test-list-stale-candidates-approved.sh

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
export PROJECT_ID=test-stale-approved
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# Stub `gh issue list ... --json number,labels -q '...'`. The real call
# emits a JSON array of {number, labels:[{name,...}]}. Tests set
# _MOCK_ISSUE_LIST to the JSON array; the stub feeds it through jq with
# whatever -q expression `list_stale_candidates` passes.
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
  # mklabels foo bar baz -> [{"name":"foo"},{"name":"bar"},{"name":"baz"}]
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
  # mkissue NUMBER label1 label2 ... -> {"number":NUMBER,"labels":[...]}
  local num="$1"; shift
  printf '{"number":%s,"labels":%s}' "$num" "$(mklabels "$@")"
}

echo "=== TC-STALE-APPROVED-001..004: list_stale_candidates approved exclusion ==="

# TC-001: in-progress + approved → MUST be excluded
_MOCK_ISSUE_LIST="[$(mkissue 101 autonomous in-progress approved)]"
out=$(list_stale_candidates)
assert_count "TC-001 in-progress+approved excluded" 0 "$out"

# TC-002: reviewing + approved → MUST be excluded
_MOCK_ISSUE_LIST="[$(mkissue 102 autonomous reviewing approved)]"
out=$(list_stale_candidates)
assert_count "TC-002 reviewing+approved excluded" 0 "$out"

# TC-003: in-progress alone → MUST still be detected (pre-existing behavior)
_MOCK_ISSUE_LIST="[$(mkissue 103 autonomous in-progress)]"
out=$(list_stale_candidates)
assert_count "TC-003 in-progress alone detected" 1 "$out"

# TC-004: reviewing alone → MUST still be detected
_MOCK_ISSUE_LIST="[$(mkissue 104 autonomous reviewing)]"
out=$(list_stale_candidates)
assert_count "TC-004 reviewing alone detected" 1 "$out"

# Mixed bag — partial defense + partial detection in one query
_MOCK_ISSUE_LIST="[$(mkissue 201 autonomous in-progress approved),$(mkissue 202 autonomous in-progress),$(mkissue 203 autonomous reviewing approved),$(mkissue 204 autonomous reviewing)]"
out=$(list_stale_candidates)
assert_count "TC-mixed: only the two non-approved are returned" 2 "$out"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
