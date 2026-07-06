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

assert_eq_field() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected='$expected' actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains_field() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (should not contain '$needle': $haystack)"
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
echo "=== TC-IFILT-100..104: ISSUE_FILTER takes effect at all five list_* call sites (#436, AC-B4) ==="

# mkissue_a <num> <assignees-csv-or-empty> <label...> — like mkissue but with
# a real gh-raw-shape `assignees:[{"login":...}]` array so assignee: atoms can
# be exercised through the FULL itp_github leaf normalization pipe (not just
# the pure-function unit tests in test-issue-filter.sh).
mkassignees() {
  local out="["
  local first=1
  for n in "$@"; do
    [[ -z "$n" ]] && continue
    if [[ $first -eq 1 ]]; then first=0; else out+=","; fi
    out+="{\"login\":\"$n\"}"
  done
  out+="]"
  printf '%s' "$out"
}
mkissue_a() {
  local num="$1" assignees_csv="$2"; shift 2
  local -a assignees_arr=()
  if [[ -n "$assignees_csv" ]]; then
    IFS=',' read -ra assignees_arr <<<"$assignees_csv"
  fi
  printf '{"number":%s,"labels":%s,"assignees":%s}' "$num" "$(mklabels "$@")" "$(mkassignees "${assignees_arr[@]}")"
}

echo "--- TC-IFILT-100: list_new_issues ---"
ISSUE_FILTER="label:team-a"
_MOCK_ISSUE_LIST="[$(mkissue 601 autonomous team-a),$(mkissue 602 autonomous team-b)]"
out=$(list_new_issues)
assert_count "TC-IFILT-100 list_new_issues narrows to filter match" 1 "$out"
assert_eq_field "TC-IFILT-100 the matching issue is #601" "601" "$(jq -r '.[0].number' <<<"$out")"
unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS

echo "--- TC-IFILT-101: list_pending_review ---"
ISSUE_FILTER="label:team-a"
_MOCK_ISSUE_LIST="[$(mkissue 611 autonomous pending-review team-a),$(mkissue 612 autonomous pending-review team-b)]"
out=$(list_pending_review)
assert_count "TC-IFILT-101 list_pending_review narrows to filter match" 1 "$out"
unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS

echo "--- TC-IFILT-102: list_pending_dev ---"
ISSUE_FILTER="label:team-a"
_MOCK_ISSUE_LIST="[$(mkissue 621 autonomous pending-dev team-a),$(mkissue 622 autonomous pending-dev team-b)]"
out=$(list_pending_dev)
assert_count "TC-IFILT-102 list_pending_dev narrows to filter match" 1 "$out"
unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS

echo "--- TC-IFILT-103: list_stale_candidates ---"
ISSUE_FILTER="label:team-a"
_MOCK_ISSUE_LIST="[$(mkissue 631 autonomous in-progress team-a),$(mkissue 632 autonomous reviewing team-b)]"
out=$(list_stale_candidates)
assert_count "TC-IFILT-103 list_stale_candidates narrows to filter match" 1 "$out"
unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS

echo "--- TC-IFILT-104: list_hygiene_residue ---"
# list_hygiene_residue routes through itp_list_forbidden_combos, a DIFFERENT
# leaf whose jq predicate ignores -q entirely too (same mock shape applies).
ISSUE_FILTER="label:team-a"
_MOCK_ISSUE_LIST="[$(mkissue 641 autonomous approved in-progress team-a),$(mkissue 642 autonomous approved in-progress team-b)]"
out=$(list_hygiene_residue)
assert_count "TC-IFILT-104 list_hygiene_residue narrows to filter match" 1 "$out"
unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS

echo "--- TC-IFILT-015: assignee: atom exercised through the full leaf normalization ---"
ISSUE_FILTER="assignee:alice"
_MOCK_ISSUE_LIST="[$(mkissue_a 651 "alice,bob" autonomous team-a),$(mkissue_a 652 "carol" autonomous team-a)]"
out=$(list_new_issues)
assert_count "assignee:alice matches only the issue assigned to alice" 1 "$out"
assert_eq_field "the matching issue is #651" "651" "$(jq -r '.[0].number' <<<"$out")"
assert_not_contains_field "output never carries an assignees key" "assignees" "$(jq -c '.[0]' <<<"$out")"
unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS

echo "--- TC-IFILT-108: empty/unset filter is jq-equal to pre-PR output (identity, re-asserted per selector) ---"
unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS
_MOCK_ISSUE_LIST="[$(mkissue 661 autonomous)]"
out=$(list_new_issues)
assert_count "list_new_issues identity: still returns the clean issue" 1 "$out"
assert_not_contains_field "list_new_issues identity: no assignees key leaks in" "assignees" "$(jq -c '.[0]' <<<"$out")"

echo
echo "=== TC-IFILT-106/107: count_active dual-path equivalence (#436, AC-B4/AC-B9) ==="

echo "--- TC-IFILT-106: filter matches ALL actives -> equals the unfiltered count ---"
_MOCK_ISSUE_LIST="[$(mkissue 701 autonomous in-progress team-a),$(mkissue 702 autonomous reviewing team-a)]"
unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS
unfiltered_count=$(count_active)
ISSUE_FILTER="label:team-a"
filtered_count=$(count_active)
assert_eq_field "count_active empty-filter path returns 2" "2" "$unfiltered_count"
assert_eq_field "count_active filtered path (matches all) equals unfiltered" "$unfiltered_count" "$filtered_count"
unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS

echo "--- TC-IFILT-107: filter matches a SUBSET -> strictly less than the unfiltered count ---"
_MOCK_ISSUE_LIST="[$(mkissue 711 autonomous in-progress team-a),$(mkissue 712 autonomous reviewing team-b)]"
unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS
unfiltered_count=$(count_active)
ISSUE_FILTER="label:team-a"
filtered_count=$(count_active)
assert_eq_field "count_active empty-filter path returns 2 (both active)" "2" "$unfiltered_count"
assert_eq_field "count_active filtered path (subset) returns 1" "1" "$filtered_count"
unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS

echo
echo "=== TC-IFILT-110..113: ISSUE_SCAN_LIMIT reaches selectors + count_active (both paths) (#436, AC-B9) ==="

# Dedicated arg-capturing mock — this section cares about the actual
# `--limit` value passed to `gh`, which the shared mock above discards.
# `gh` here always runs at the near end of an internal pipe (lib-dispatch.sh's
# selectors pipe itp_list_by_state's output through more jq/issue_filter_apply
# stages), and bash runs every non-last pipeline stage in a subshell (lastpipe
# is off by default) — so a plain variable write inside `gh` never survives
# back to this top-level shell. Capture to a FILE instead.
_CAPTURED_LIMIT_FILE=$(mktemp)
gh() {
  local q_expr="" limit=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -q) q_expr="$2"; shift 2 ;;
      --limit) limit="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "$limit" ]] && printf '%s' "$limit" > "$_CAPTURED_LIMIT_FILE"
  if [[ -n "$q_expr" ]]; then
    jq "$q_expr" <<<"${_MOCK_ISSUE_LIST:-[]}"
  else
    printf '%s' "${_MOCK_ISSUE_LIST:-[]}"
  fi
}
export -f gh

_MOCK_ISSUE_LIST="[]"

: > "$_CAPTURED_LIMIT_FILE"
list_new_issues >/dev/null
assert_eq_field "TC-IFILT-110 unset ISSUE_SCAN_LIMIT -> selector uses default 100" "100" "$(cat "$_CAPTURED_LIMIT_FILE")"

ISSUE_SCAN_LIMIT=250
: > "$_CAPTURED_LIMIT_FILE"
list_new_issues >/dev/null
assert_eq_field "TC-IFILT-111 ISSUE_SCAN_LIMIT=250 reaches list_new_issues" "250" "$(cat "$_CAPTURED_LIMIT_FILE")"

ISSUE_FILTER="label:team-a"
unset ISSUE_FILTER_JQ ISSUE_FILTER_ARGS
: > "$_CAPTURED_LIMIT_FILE"
count_active >/dev/null
assert_eq_field "TC-IFILT-112 ISSUE_SCAN_LIMIT=250 reaches count_active's FILTERED path" "250" "$(cat "$_CAPTURED_LIMIT_FILE")"
unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS

: > "$_CAPTURED_LIMIT_FILE"
count_active >/dev/null
assert_eq_field "TC-IFILT-113 ISSUE_SCAN_LIMIT=250 reaches count_active's EMPTY-FILTER path" "250" "$(cat "$_CAPTURED_LIMIT_FILE")"
unset ISSUE_SCAN_LIMIT
rm -f "$_CAPTURED_LIMIT_FILE"

echo
echo "=== TC-IFILT-090..092: enumeration fail-closed on a failing leaf (#436, AC-B6) ==="

# A `gh` that fails outright (rc=1, no stdout) — simulates an API outage /
# rate-limit at the leaf. Under `pipefail` (set at file top), the selector's
# internal pipe must propagate a non-zero exit rather than degrading to an
# empty array / a 0 count.
gh() { return 1; }
export -f gh

unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS
count_active >/dev/null 2>/dev/null
rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-IFILT-090 count_active empty-filter path aborts on leaf failure (rc=$rc, never coerces to 0)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-IFILT-090 count_active empty-filter path should abort on leaf failure (got rc=0)"
  FAIL=$((FAIL + 1))
fi

ISSUE_FILTER="label:team-a"
unset ISSUE_FILTER_JQ ISSUE_FILTER_ARGS
count_active >/dev/null 2>/dev/null
rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-IFILT-091 count_active FILTERED path aborts on leaf failure (rc=$rc, never coerces to 0)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-IFILT-091 count_active filtered path should abort on leaf failure (got rc=0)"
  FAIL=$((FAIL + 1))
fi
unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS

for sel in list_new_issues list_pending_review list_pending_dev list_stale_candidates list_hygiene_residue; do
  ISSUE_FILTER="label:team-a"
  unset ISSUE_FILTER_JQ ISSUE_FILTER_ARGS
  out=$("$sel" 2>/dev/null)
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-IFILT-092 $sel propagates leaf failure (rc=$rc, never emits [])"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-IFILT-092 $sel should propagate leaf failure (got rc=0, out='$out')"
    FAIL=$((FAIL + 1))
  fi
  unset ISSUE_FILTER ISSUE_FILTER_JQ ISSUE_FILTER_ARGS
done

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
