#!/bin/bash
# Strict pre-fan-out review-disposition contract (issue #540).

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-disposition.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

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

assert_rc_nonzero() {
  local desc="$1"; shift
  "$@" >/dev/null 2>&1
  local rc=$?
  if [[ "$rc" -ne 0 ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    FAIL=$((FAIL + 1))
  fi
}

if [[ ! -f "$LIB" ]]; then
  echo -e "${RED}FAIL${NC}: missing $LIB (expected red before implementation)"
  exit 1
fi

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-disposition.sh
source "$LIB"

HEAD_A="ABCDEF0123456789ABCDEF0123456789ABCDEF01"
HEAD_A_LOWER="${HEAD_A,,}"
HEAD_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
STRICT_SEEN_FILE=$(mktemp)
trap 'rm -f "$STRICT_SEEN_FILE"' EXIT

echo "=== TC-E2E-REBASE-001..004: renderer ==="
assert_eq "TC-E2E-REBASE-001 conflict marker is exact" \
  "<!-- review-disposition: issue=540 head=${HEAD_A_LOWER} phase=pre-fanout result=conflict-rebase -->" \
  "$(_review_disposition_marker 540 "$HEAD_A" conflict-rebase)"
assert_eq "TC-E2E-REBASE-002 unknown marker is exact" \
  "<!-- review-disposition: issue=540 head=${HEAD_A_LOWER} phase=pre-fanout result=mergeable-unknown -->" \
  "$(_review_disposition_marker 540 "$HEAD_A" mergeable-unknown)"
assert_eq "TC-E2E-REBASE-003 uppercase head normalizes" "$HEAD_A_LOWER" \
  "$(_review_normalize_full_head "$HEAD_A")"
assert_rc_nonzero "TC-E2E-REBASE-004 abbreviated head rejected" \
  _review_disposition_marker 540 abcdef0 conflict-rebase
assert_rc_nonzero "TC-E2E-REBASE-004 malformed head rejected" \
  _review_disposition_marker 540 zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz conflict-rebase
assert_rc_nonzero "TC-E2E-REBASE-004 unknown result rejected" \
  _review_disposition_marker 540 "$HEAD_A" conflict
assert_eq "canonical PR conflict marker is exact and normalized" \
  "<!-- auto-merge-conflict: issue=540 head=${HEAD_A_LOWER} result=conflict-rebase -->" \
  "$(_review_auto_merge_conflict_marker 540 "$HEAD_A")"
assert_rc_nonzero "canonical PR conflict marker rejects abbreviated head" \
  _review_auto_merge_conflict_marker 540 abcdef0
assert_eq "TC-E2E-REBASE-052 generic auto-merge failure marker is exact and normalized" \
  "<!-- auto-merge-failure: issue=540 head=${HEAD_A_LOWER} -->" \
  "$(_review_auto_merge_failure_marker 540 "$HEAD_A")"
assert_rc_nonzero "TC-E2E-REBASE-053 generic auto-merge failure marker rejects abbreviated head" \
  _review_auto_merge_failure_marker 540 abcdef0

marker_a="$(_review_disposition_marker 540 "$HEAD_A" conflict-rebase)"
marker_b="$(_review_disposition_marker 540 "$HEAD_B" mergeable-unknown)"

evidence() {
  _review_routing_evidence_from_comments "$1" 540 "${2:-}"
}

echo
echo "=== TC-E2E-REBASE-005..009: parser and newest evidence ==="
comments=$(jq -cn --arg body "$marker_a" \
  '[{id:1,author:"review-app[bot]",authorKind:"self",body:$body,createdAt:"2026-07-30T00:00:00Z"}]')
assert_eq "TC-E2E-REBASE-005 strict-self marker parses" \
  "{\"kind\":\"disposition\",\"head\":\"${HEAD_A_LOWER}\",\"result\":\"conflict-rebase\"}" \
  "$(evidence "$comments")"

spoofs=$(jq -cn --arg exact "$marker_a" --arg wrong "$marker_b" '
  [
    {id:1,authorKind:"human",body:$exact,createdAt:"2026-07-30T00:00:01Z"},
    {id:2,authorKind:"self",body:("> " + $exact),createdAt:"2026-07-30T00:00:02Z"},
    {id:3,authorKind:"self",body:($exact + " trailing"),createdAt:"2026-07-30T00:00:03Z"},
    {id:4,authorKind:"self",body:"<!-- review-disposition: issue=540 head=abcdef0 phase=pre-fanout result=conflict-rebase -->",createdAt:"2026-07-30T00:00:04Z"},
    {id:5,authorKind:"self",body:"<!-- review-disposition: issue=541 head=abcdef0123456789abcdef0123456789abcdef01 phase=pre-fanout result=conflict-rebase -->",createdAt:"2026-07-30T00:00:05Z"},
    {id:6,authorKind:"bot",body:$wrong,createdAt:"2026-07-30T00:00:06Z"},
    {id:7,authorKind:"self",body:($exact + "\n"),createdAt:"2026-07-30T00:00:07Z"}
  ]')
assert_eq "TC-E2E-REBASE-006 spoofed/malformed/wrong-issue markers ignored" "" \
  "$(evidence "$spoofs")"

legacy=$(jq -cn --arg head "$HEAD_A_LOWER" '
  [{id:7,authorKind:"self",body:("Review PASSED\nReviewed HEAD: `" + $head + "` (issue #540, session `s1`)"),createdAt:"2026-07-30T00:00:07Z"}]')
assert_eq "TC-E2E-REBASE-007 Reviewed HEAD remains routing evidence" \
  "{\"kind\":\"reviewed-head\",\"head\":\"${HEAD_A_LOWER}\",\"result\":\"\"}" \
  "$(evidence "$legacy")"

mixed=$(jq -cn --arg head "$HEAD_A_LOWER" --arg marker "$marker_b" '
  [
    {id:8,authorKind:"self",body:("Reviewed HEAD: `" + $head + "` (issue #540, session `s1`)"),createdAt:"2026-07-30T00:00:08Z"},
    {id:9,authorKind:"self",body:$marker,createdAt:"2026-07-30T00:00:09Z"}
  ]')
assert_eq "TC-E2E-REBASE-008 newer disposition wins" \
  "{\"kind\":\"disposition\",\"head\":\"${HEAD_B}\",\"result\":\"mergeable-unknown\"}" \
  "$(evidence "$mixed")"
assert_eq "TC-E2E-REBASE-008 current-HEAD filter selects the newest matching evidence" \
  "{\"kind\":\"reviewed-head\",\"head\":\"${HEAD_A_LOWER}\",\"result\":\"\"}" \
  "$(evidence "$mixed" "$HEAD_A_LOWER")"

actual_head=$(evidence "$mixed" | jq -r '.head // empty')
if [[ "$actual_head" != "$HEAD_A_LOWER" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-E2E-REBASE-009 old-head disposition does not match current head"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-E2E-REBASE-009 stale disposition matched current head"
  FAIL=$((FAIL + 1))
fi

echo
echo "=== strict provider read wiring ==="
itp_list_comments() {
  printf '%s' "${ITP_REQUIRE_SELF_AUTHOR:-0}" >"$STRICT_SEEN_FILE"
  printf '%s\n' "$comments"
}
head_out="" kind_out="" result_out=""
latest_review_routing_evidence 540 head_out kind_out result_out
assert_eq "routing helper asks provider for strict self authors" \
  "1" "$(<"$STRICT_SEEN_FILE")"
assert_eq "routing helper returns normalized head" "$HEAD_A_LOWER" "$head_out"
assert_eq "routing helper returns disposition kind" "disposition" "$kind_out"
assert_eq "routing helper returns disposition result" "conflict-rebase" "$result_out"

comments="$mixed"
latest_review_routing_evidence \
  540 head_out kind_out result_out "$HEAD_A_LOWER"
assert_eq "routing helper filters evidence to the current HEAD" \
  "$HEAD_A_LOWER|reviewed-head|" "$head_out|$kind_out|$result_out"
itp_list_comments() { return 1; }
assert_rc_nonzero "routing helper propagates provider read failure" \
  latest_review_routing_evidence 540 head_out kind_out result_out

echo
echo "=== strict PR recovery marker parser ==="
conflict_marker="$(_review_auto_merge_conflict_marker 540 "$HEAD_A")"
failure_marker="$(_review_auto_merge_failure_marker 540 "$HEAD_A")"
recovery_comments=$(jq -cn \
  --arg conflict "Auto-merge failed: conflict route"$'\n'"$conflict_marker" \
  --arg failure "Auto-merge failed: merge route"$'\n'"$failure_marker" \
  '{
    comments: [
      {id:1,body:$conflict,createdAt:"2026-07-30T00:01:00Z"},
      {id:2,body:$failure,createdAt:"2026-07-30T00:01:01Z"}
    ]
  }')
assert_eq "TC-E2E-REBASE-057 canonical current-HEAD recovery marker uses newest exact final line" \
  "Auto-merge failed: merge route"$'\n'"$failure_marker" \
  "$(_review_pr_recovery_comment_from_comments \
      "$recovery_comments" 540 "$HEAD_A" any 2>/dev/null)"
assert_eq "TC-E2E-REBASE-057 conflict-only recovery parser selects exact conflict marker" \
  "Auto-merge failed: conflict route"$'\n'"$conflict_marker" \
  "$(_review_pr_recovery_comment_from_comments \
      "$recovery_comments" 540 "$HEAD_A" conflict 2>/dev/null)"

legacy_body="Auto-merge failed: legacy producer without a hidden marker"
legacy_comments=$(jq -cn --arg body "$legacy_body" \
  '{comments:[{id:1,body:$body,createdAt:"2026-07-30T00:02:00Z"}]}')
assert_eq "TC-E2E-REBASE-057 marker-free legacy recovery remains compatible" "$legacy_body" \
  "$(_review_pr_recovery_comment_from_comments \
      "$legacy_comments" 540 "$HEAD_A" any 2>/dev/null)"

malformed_recovery=$(jq -cn \
  --arg marker "$conflict_marker" \
  --arg head "$HEAD_A_LOWER" '
  {
    comments: [
      {id:1,body:("Auto-merge failed: quoted marker\n> " + $marker),createdAt:"2026-07-30T00:03:00Z"},
      {id:2,body:("Auto-merge failed: terminal newline\n" + $marker + "\n"),createdAt:"2026-07-30T00:03:01Z"},
      {id:3,body:"Auto-merge failed: abbreviated\n<!-- auto-merge-conflict: issue=540 head=abcdef0 result=conflict-rebase -->",createdAt:"2026-07-30T00:03:02Z"},
      {id:4,body:("Auto-merge failed: wrong issue\n<!-- auto-merge-failure: issue=541 head=" + $head + " -->"),createdAt:"2026-07-30T00:03:03Z"},
      {id:5,body:("Auto-merge failed: case lookalike\n<!-- AUTO-MERGE-CONFLICT: issue=540 head=" + $head + " result=conflict-rebase -->"),createdAt:"2026-07-30T00:03:04Z"}
    ]
  }')
assert_eq "TC-E2E-REBASE-057 quoted, newline-terminated, malformed, and case-lookalike recovery markers are ignored" \
  "" \
  "$(_review_pr_recovery_comment_from_comments \
      "$malformed_recovery" 540 "$HEAD_A" any 2>/dev/null)"

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
