#!/bin/bash
# Pinned mergeability preflight and canonical conflict routing (issue #540).

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MG_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-mergeable.sh"
DISP_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-disposition.sh"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
DEV_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ok() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    ok "$desc"
  else
    bad "$desc"
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then ok "$desc"; else bad "$desc"; fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then ok "$desc"; else bad "$desc"; fi
}

if [[ ! -f "$DISP_LIB" ]]; then
  echo -e "${RED}FAIL${NC}: missing disposition library (expected red before implementation)"
  exit 1
fi

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-disposition.sh
source "$DISP_LIB"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-mergeable.sh
source "$MG_LIB"
set +e

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
HEAD_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
CONFLICT_TRAILER_A="<!-- review-verdict: failed-substantive head=${HEAD_A} -->"
UNKNOWN_TRAILER_A="<!-- review-verdict: failed-non-substantive cause=mergeable-unknown head=${HEAD_A} -->"
MERGEABLE_RETRIES=3
MERGEABLE_RETRY_DELAY_SECONDS=0

log() { :; }
sleep() { :; }

_set_sequence() {
  local file="$1"; shift
  printf '%s\n' "$@" > "$file"
  printf '0' > "${file}.idx"
}

_next_sequence() {
  local file="$1" idx value
  idx=$(<"${file}.idx")
  value=$(sed -n "$((idx + 1))p" "$file")
  [[ -n "$value" ]] || value=$(tail -n1 "$file")
  printf '%s' "$((idx + 1))" > "${file}.idx"
  [[ "$value" != "FAIL" ]] || return 1
  printf '%s' "$value"
}

chp_pr_view() { _next_sequence "$TMP/snapshots"; }
chp_mergeable() { _next_sequence "$TMP/mergeable"; }

_run_preflight() {
  local initial="$1" final="$2"; shift 2
  _set_sequence "$TMP/snapshots" "$initial" "$final"
  _set_sequence "$TMP/mergeable" "$@"
  PF_STATE="" PF_HEAD="" PF_BRANCH="" PF_STATUS="" PF_ACTION=""
  review_mergeability_preflight 42 \
    PF_STATE PF_HEAD PF_BRANCH PF_STATUS PF_ACTION
  PF_RC=$?
}

echo "=== TC-E2E-REBASE-010..017: pinned preflight matrix ==="
open_a=$(jq -cn --arg h "$HEAD_A" '{state:"OPEN",headRefOid:$h,headRefName:"fix/540"}')
open_b=$(jq -cn --arg h "$HEAD_B" '{state:"OPEN",headRefOid:$h,headRefName:"fix/540"}')
closed_a=$(jq -cn --arg h "$HEAD_A" '{state:"CLOSED",headRefOid:$h,headRefName:"fix/540"}')
unknown_state_a=$(jq -cn --arg h "$HEAD_A" '{state:"UNKNOWN",headRefOid:$h,headRefName:"fix/540"}')

_run_preflight "$open_a" "$open_a" MERGEABLE
assert_eq "TC-E2E-REBASE-010 stable MERGEABLE proceeds" "proceed|MERGEABLE|$HEAD_A" \
  "$PF_ACTION|$PF_STATUS|$PF_HEAD"

_run_preflight "$open_a" "$open_a" CONFLICTING
assert_eq "TC-E2E-REBASE-011 stable CONFLICTING routes conflict" "conflict-rebase" "$PF_ACTION"

_run_preflight "$open_a" "$open_a" UNKNOWN UNKNOWN UNKNOWN
assert_eq "TC-E2E-REBASE-012 persistent UNKNOWN is non-substantive" \
  "mergeable-unknown|UNKNOWN" "$PF_ACTION|$PF_STATUS"
assert_eq "TC-E2E-REBASE-012 UNKNOWN uses the bounded retry count" "3" \
  "$(<"$TMP/mergeable.idx")"

_run_preflight "$open_a" "$open_a" "" "" ""
assert_eq "TC-E2E-REBASE-013 persistent empty result is non-substantive" \
  "mergeable-unknown|" "$PF_ACTION|$PF_STATUS"

_run_preflight "$open_a" "$closed_a" CONFLICTING
assert_eq "TC-E2E-REBASE-014 closure wins over stale conflict result" "closed" "$PF_ACTION"

_run_preflight "$open_a" "$open_b" CONFLICTING
assert_eq "TC-E2E-REBASE-015 changed HEAD wins over stale conflict result" "head-changed" "$PF_ACTION"

_run_preflight FAIL "$open_a" MERGEABLE
assert_eq "TC-E2E-REBASE-016 initial snapshot failure retries review" "read-failed" "$PF_ACTION"

_run_preflight "$open_a" FAIL MERGEABLE
assert_eq "TC-E2E-REBASE-016 final snapshot failure retries review" "read-failed" "$PF_ACTION"

_run_preflight "$unknown_state_a" "$open_a" MERGEABLE
assert_eq "TC-E2E-REBASE-016 unknown initial PR state retries review" "read-failed" "$PF_ACTION"

_run_preflight "$open_a" "$unknown_state_a" MERGEABLE
assert_eq "TC-E2E-REBASE-016 unknown final PR state retries review" "read-failed" "$PF_ACTION"

_run_preflight "$open_a" "$open_a" UNKNOWN MERGEABLE
assert_eq "TC-E2E-REBASE-017 UNKNOWN settling to MERGEABLE proceeds" \
  "proceed|MERGEABLE" "$PF_ACTION|$PF_STATUS"
assert_eq "TC-E2E-REBASE-017 settled poll stops early" "2" "$(<"$TMP/mergeable.idx")"

_set_sequence "$TMP/mergeable" UNKNOWN UNKNOWN
(
  set -e
  MERGEABLE_RETRIES=2
  MERGEABLE_RETRY_DELAY_SECONDS=invalid
  POLL_STATUS=""
  _review_poll_mergeable 42 POLL_STATUS
  [[ "$POLL_STATUS" == "UNKNOWN" ]]
)
assert_eq "TC-E2E-REBASE-047 invalid retry delay cannot terminate set -e caller" \
  "0|2" "$?|$(<"$TMP/mergeable.idx")"

_set_sequence "$TMP/snapshots" "$open_b"
PIN_STATE="" PIN_HEAD="" PIN_BRANCH="" PIN_ACTION=""
review_validate_pinned_pr 42 "$HEAD_A" \
  PIN_STATE PIN_HEAD PIN_BRANCH PIN_ACTION
assert_eq "TC-E2E-REBASE-050 post-poll validator rejects a changed HEAD" \
  "head-changed|$HEAD_B" "$PIN_ACTION|$PIN_HEAD"

echo
echo "=== TC-E2E-REBASE-018..019: source ordering ==="
pre_line=$(grep -n 'review_mergeability_preflight "\$PR_NUMBER"' "$WRAPPER" | head -1 | cut -d: -f1)
cmd_line=$(grep -n '_run_command_e2e_lane "\$_E2E_RC_FILE"' "$WRAPPER" | head -1 | cut -d: -f1)
browser_line=$(grep -n '_e2e_prompt=\$(build_browser_e2e_prompt)' "$WRAPPER" | head -1 | cut -d: -f1)
post_line=$(grep -n 'Mergeable hard gate (INV-44' "$WRAPPER" | tail -1 | cut -d: -f1)
fanout_line=$(grep -n 'log "Fanning out .* review agent(s)' "$WRAPPER" | head -1 | cut -d: -f1)
post_pin_line=$(grep -n 'review_validate_pinned_pr "\$PR_NUMBER" "\$PR_HEAD_SHA"' "$WRAPPER" | head -1 | cut -d: -f1)
if [[ -n "$pre_line" && -n "$cmd_line" && -n "$browser_line" \
      && "$pre_line" -lt "$cmd_line" && "$pre_line" -lt "$browser_line" ]]; then
  ok "TC-E2E-REBASE-018 preflight precedes command and browser E2E"
else
  bad "TC-E2E-REBASE-018 preflight must precede both E2E lanes"
fi
if [[ -n "$post_line" && -n "$fanout_line" && "$post_line" -gt "$fanout_line" ]]; then
  ok "TC-E2E-REBASE-019 post-fan-out INV-44 remains after fan-out"
else
  bad "TC-E2E-REBASE-019 post-fan-out INV-44 gate was removed or moved before fan-out"
fi
if [[ -n "$post_pin_line" && -n "$fanout_line" \
      && "$post_pin_line" -gt "$fanout_line" ]]; then
  ok "TC-E2E-REBASE-050 post-fan-out mergeability decision re-pins the reviewed HEAD"
else
  bad "TC-E2E-REBASE-050 post-fan-out mergeability decision can bind stale HEAD evidence"
fi

if grep -q 'REVIEW_CRASH_RETRY_STATE="pending-review"' "$WRAPPER" \
   && grep -q 'terminal_intent_cleanup_transition.*' "$WRAPPER" \
   && grep -q '"pending-review"' "$WRAPPER"; then
  ok "TC-E2E-REBASE-020..022 failed recovery transition retains pending-review cleanup intent"
else
  bad "TC-E2E-REBASE-020..022 required-write recovery can fall through to pending-dev cleanup"
fi

preflight_conflict_case=$(sed -n '/^  conflict-rebase)/,/^  mergeable-unknown)/p' "$WRAPPER")
preflight_unknown_case=$(sed -n '/^  mergeable-unknown)/,/^  \*)/p' "$WRAPPER")
post_conflict_case=$(sed -n \
  '/if \[\[ "\$MERGEABLE_GATE" == "block-substantive" \]\]; then/,/elif \[\[ "\$MERGEABLE_GATE" == "block-nonsubstantive" \]\]; then/p' \
  "$WRAPPER")
for phase_case in \
  "$preflight_conflict_case" "$preflight_unknown_case" "$post_conflict_case"; do
  arm_line=$(grep -n 'REVIEW_CRASH_RETRY_STATE="pending-review"' \
    <<<"$phase_case" | head -1 | cut -d: -f1)
  route_line=$(grep -nE '_review_route_(conflict|mergeable_unknown)' \
    <<<"$phase_case" | head -1 | cut -d: -f1)
  if [[ "$arm_line" =~ ^[0-9]+$ && "$route_line" =~ ^[0-9]+$ \
        && "$arm_line" -lt "$route_line" ]]; then
    ok "TC-E2E-REBASE-020..022 required-write phase arms pending-review cleanup before its first write"
  else
    bad "TC-E2E-REBASE-020..022 required-write phase can be interrupted before safe cleanup is armed"
  fi
done

echo
echo "=== TC-E2E-REBASE-020..026: durable conflict writes ==="
ISSUE_COMMENTS="$TMP/issue-comments.json"
PR_COMMENTS="$TMP/pr-comments.json"
TRACE="$TMP/trace"
printf '[]' > "$ISSUE_COMMENTS"
printf '[]' > "$PR_COMMENTS"
: > "$TRACE"
_FAIL_WRITE=""

_append_issue_comment() {
  local body="$1" next tmp
  next=$(($(jq 'length' "$ISSUE_COMMENTS") + 1))
  tmp="${ISSUE_COMMENTS}.tmp"
  jq --argjson id "$next" --arg body "$body" \
    '. + [{id:$id,author:"review-app[bot]",authorKind:"self",body:$body,createdAt:("2026-07-30T00:00:" + ($id|tostring|if length==1 then "0"+. else . end) + "Z")}]' \
    "$ISSUE_COMMENTS" > "$tmp" && mv "$tmp" "$ISSUE_COMMENTS"
}

itp_list_comments() { cat "$ISSUE_COMMENTS"; }
itp_post_comment() {
  local body="$2" kind="finding"
  [[ "$body" == "<!-- review-disposition:"* ]] && kind="disposition"
  [[ "$body" == "<!-- review-round-counter:"*" round=0 -->" ]] && kind="round-reset"
  [[ "$body" == "Reviewed HEAD:"* ]] && kind="reviewed-head"
  printf 'issue:%s\n' "$kind" >> "$TRACE"
  [[ "$_FAIL_WRITE" != "$kind" ]] || return 1
  _append_issue_comment "$body"
}
chp_pr_view() {
  case "${2:-}" in
    state,headRefOid,headRefName)
      _next_sequence "$TMP/snapshots"
      ;;
    comments)
      jq -cn --argjson comments "$(cat "$PR_COMMENTS")" '{comments:$comments}'
      ;;
    *)
      return 1
      ;;
  esac
}
chp_pr_comment() {
  local body="" tmp
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "--body" ]] && { body="$2"; break; }
    shift
  done
  printf 'pr:auto-merge\n' >> "$TRACE"
  [[ "$_FAIL_WRITE" != "pr-marker" ]] || return 1
  tmp="${PR_COMMENTS}.tmp"
  jq --arg body "$body" '. + [{id:(length+1),body:$body}]' "$PR_COMMENTS" > "$tmp" \
    && mv "$tmp" "$PR_COMMENTS"
}
emit_verdict_trailer_required() {
  local verdict="$3" cause="${4:-}" head="${6:-}" body
  if [[ "$verdict" == "failed-substantive" ]]; then
    body="<!-- review-verdict: failed-substantive head=${head} -->"
  else
    body="<!-- review-verdict: failed-non-substantive cause=${cause} head=${head} -->"
  fi
  printf 'verdict:%s\n' "$verdict" >> "$TRACE"
  [[ "$_FAIL_WRITE" != "verdict" ]] || return 1
  _append_issue_comment "$body"
}
emit_verdict_trailer() {
  local verdict="$3" cause="${4:-}" body
  body="<!-- review-verdict: ${verdict}"
  [[ -z "$cause" ]] || body+=" cause=${cause}"
  body+=" -->"
  printf 'verdict:%s\n' "$verdict" >> "$TRACE"
  [[ "$_FAIL_WRITE" != "verdict" ]] || return 1
  _append_issue_comment "$body"
}
submit_request_changes() { printf 'request-changes\n' >> "$TRACE"; }
itp_transition_state() {
  printf 'transition:%s>%s\n' "$2" "$3" >> "$TRACE"
  [[ "$_FAIL_WRITE" != "transition" ]]
}
RUN_FOOTER_TEXT=""
run_footer() { printf '%s' "$RUN_FOOTER_TEXT"; }

_reset_route() {
  printf '[]' > "$ISSUE_COMMENTS"
  printf '[]' > "$PR_COMMENTS"
  : > "$TRACE"
  _FAIL_WRITE=""
  RUN_FOOTER_TEXT=""
}

for failure in finding disposition pr-marker verdict; do
  _reset_route
  _FAIL_WRITE="$failure"
  _review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
  rc=$?
  trace=$(cat "$TRACE")
  _failure_id="TC-E2E-REBASE-020..022"
  [[ "$failure" == "finding" ]] && _failure_id="TC-E2E-REBASE-040"
  assert_eq "${_failure_id} $failure failure returns required-write rc" "20" "$rc"
  assert_not_contains "${_failure_id} $failure failure never reaches pending-dev" \
    "transition:reviewing>pending-dev" "$trace"

  _FAIL_WRITE=""
  _review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
  rc=$?
  assert_eq "TC-E2E-REBASE-024 $failure retry succeeds" "0" "$rc"
  assert_eq "TC-E2E-REBASE-024 disposition remains idempotent after $failure" "1" \
    "$(jq --arg h "$HEAD_A" '[.[] | select(.body == ("<!-- review-disposition: issue=540 head=" + $h + " phase=pre-fanout result=conflict-rebase -->"))] | length' "$ISSUE_COMMENTS")"
  assert_eq "TC-E2E-REBASE-024 PR marker remains idempotent after $failure" "1" \
    "$(jq '[.[] | select(.body | contains("auto-merge-conflict: issue=540"))] | length' "$PR_COMMENTS")"
done

_reset_route
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
trace=$(cat "$TRACE")
required=$(printf '%s\n' "$trace" | grep -E 'issue:disposition|pr:auto-merge|verdict:failed-substantive|transition:reviewing>pending-dev')
assert_eq "TC-E2E-REBASE-023 required writes precede pending-dev" \
  $'issue:disposition\npr:auto-merge\nverdict:failed-substantive\ntransition:reviewing>pending-dev' "$required"
assert_eq "TC-E2E-REBASE-023 blocking finding is durable before pending-dev" \
  "1" "$(grep -c '^issue:finding$' "$TRACE")"
assert_eq "TC-E2E-REBASE-023 canonical PR recovery marker is the exact final line" \
  "<!-- auto-merge-conflict: issue=540 head=${HEAD_A} result=conflict-rebase -->" \
  "$(jq -r '.[0].body | split("\n") | last' "$PR_COMMENTS")"

_reset_route
_FAIL_WRITE="transition"
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
assert_eq "TC-E2E-REBASE-025 transition failure remains distinguishable" "21" "$?"
assert_eq "TC-E2E-REBASE-025 all routing inputs are durable before transition" "1|1|1" \
  "$(jq '[.[] | select(.body | startswith("<!-- review-disposition:"))] | length' "$ISSUE_COMMENTS")|$(jq '[.[] | select(.body | contains("auto-merge-conflict:"))] | length' "$PR_COMMENTS")|$(jq --arg trailer "$CONFLICT_TRAILER_A" '[.[] | select(.body == $trailer)] | length' "$ISSUE_COMMENTS")"

_reset_route
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main post-fanout
trace=$(cat "$TRACE")
assert_not_contains "TC-E2E-REBASE-026 post-fan-out route does not emit preflight disposition" \
  "issue:disposition" "$trace"
assert_eq "TC-E2E-REBASE-026 post-fan-out persists Reviewed HEAD before conflict writes" "1|1|1" \
  "$(jq '[.[] | select(.body | startswith("Reviewed HEAD:"))] | length' "$ISSUE_COMMENTS")|$(jq '[.[] | select(.body | contains("auto-merge-conflict:"))] | length' "$PR_COMMENTS")|$(jq --arg trailer "$CONFLICT_TRAILER_A" '[.[] | select(.body == $trailer)] | length' "$ISSUE_COMMENTS")"
assert_eq "TC-E2E-REBASE-026 post-fan-out uses common finding/request/transition semantics" \
  "1|1|1" \
  "$(jq '[.[] | select(.body | contains("merge-conflict-finding: issue=540"))] | length' "$ISSUE_COMMENTS")|$(grep -c '^request-changes$' "$TRACE")|$(grep -c '^transition:reviewing>pending-dev$' "$TRACE")"

_reset_route
_FAIL_WRITE="reviewed-head"
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main post-fanout
assert_eq "TC-E2E-REBASE-041 post-fan-out missing HEAD evidence blocks pending-dev" \
  "20" "$?"
assert_eq "TC-E2E-REBASE-041 post-fan-out HEAD-write failure emits no pending-dev transition" \
  "0" "$(grep -c '^transition:reviewing>pending-dev$' "$TRACE")"

_reset_route
_append_issue_comment \
  "Reviewed HEAD: \`${HEAD_A}\` (issue #540, phase \`historical-review\`)"
_append_issue_comment \
  "<!-- review-disposition: issue=540 head=${HEAD_B} phase=pre-fanout result=conflict-rebase -->"
_FAIL_WRITE="reviewed-head"
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main post-fanout
assert_eq "TC-E2E-REBASE-055 A-B-A reuses the existing tuple anchor" \
  "0" "$?"
assert_eq "TC-E2E-REBASE-055 current-HEAD filtering avoids a duplicate Reviewed HEAD write" \
  "reviewed-head|${HEAD_A}|1|1" \
  "$(_review_routing_evidence_from_comments \
      "$(cat "$ISSUE_COMMENTS")" 540 "$HEAD_A" \
      | jq -r '.kind + "|" + .head')|$(jq --arg h "$HEAD_A" \
        '[.[] | select(.body | contains("Reviewed HEAD: `" + $h + "`"))] | length' \
        "$ISSUE_COMMENTS")|$(grep -c '^transition:reviewing>pending-dev$' "$TRACE")"
assert_eq "TC-E2E-REBASE-055 fresh verdict lands after newer routing evidence" \
  "$CONFLICT_TRAILER_A" \
  "$(jq -r '.[-1].body' "$ISSUE_COMMENTS")"

_reset_route
spoof_marker="<!-- auto-merge-conflict: issue=540 head=${HEAD_A} result=conflict-rebase -->"
jq --arg body "> Auto-merge failed: quoted history ${spoof_marker}" \
  '. + [{id:1,author:"human",body:$body}]' "$PR_COMMENTS" >"${PR_COMMENTS}.tmp"
mv "${PR_COMMENTS}.tmp" "$PR_COMMENTS"
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
assert_eq "TC-E2E-REBASE-042 quoted PR marker cannot suppress canonical write" \
  "1" "$(grep -c '^pr:auto-merge$' "$TRACE")"
assert_eq "TC-E2E-REBASE-042 canonical PR marker begins Auto-merge failed" \
  "1" "$(jq --arg marker "$spoof_marker" \
    '[.[] | select((.body | startswith("Auto-merge failed:")) and (.body | contains($marker)))] | length' \
    "$PR_COMMENTS")"

_reset_route
jq --arg body "Auto-merge failed: quoted canonical history"$'\n'"> ${spoof_marker}" \
  '. + [{id:1,author:"human",body:$body}]' "$PR_COMMENTS" >"${PR_COMMENTS}.tmp"
mv "${PR_COMMENTS}.tmp" "$PR_COMMENTS"
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
assert_eq "TC-E2E-REBASE-042 quoted final-line PR marker cannot suppress canonical write" \
  "1" "$(grep -c '^pr:auto-merge$' "$TRACE")"

_reset_route
RUN_FOOTER_TEXT=$'\nrun-id: first'
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
RUN_FOOTER_TEXT=$'\nrun-id: retry'
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
assert_eq "TC-E2E-REBASE-024 conflict finding remains idempotent across run footers" \
  "1" \
  "$(jq '[.[] | select(.body | contains("merge-conflict-finding: issue=540"))] | length' "$ISSUE_COMMENTS")"
assert_eq "TC-E2E-REBASE-024 tuple evidence remains idempotent across run footers" \
  "1|1|1" \
  "$(jq '[.[] | select(.body | startswith("<!-- review-disposition:"))] | length' "$ISSUE_COMMENTS")|$(jq --arg trailer "$CONFLICT_TRAILER_A" '[.[] | select(.body == $trailer)] | length' "$ISSUE_COMMENTS")|$(jq '[.[] | select(.body | contains("auto-merge-conflict:"))] | length' "$PR_COMMENTS")"

_reset_route
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
_append_issue_comment \
  "<!-- no-progress-substantive-attempt:${HEAD_A} session=dev-after-first-review -->"
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
assert_eq "TC-E2E-REBASE-048 new dev attempt refreshes only verdict evidence" \
  "1|2" \
  "$(jq '[.[] | select(.body | startswith("<!-- review-disposition:"))] | length' "$ISSUE_COMMENTS")|$(jq --arg trailer "$CONFLICT_TRAILER_A" '[.[] | select(.body == $trailer)] | length' "$ISSUE_COMMENTS")"

_reset_route
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
_append_issue_comment \
  "<!-- review-verdict: failed-non-substantive cause=transport-failed -->"
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
assert_eq "TC-E2E-REBASE-024 newer contradictory verdict forces a fresh required trailer" \
  "2|$CONFLICT_TRAILER_A" \
  "$(jq --arg trailer "$CONFLICT_TRAILER_A" '[.[] | select(.body == $trailer)] | length' "$ISSUE_COMMENTS")|$(jq -r '.[-1].body' "$ISSUE_COMMENTS")"

_reset_route
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
_append_issue_comment \
  "<!-- review-disposition: issue=540 head=${HEAD_B} phase=pre-fanout result=conflict-rebase -->"
_append_issue_comment \
  "<!-- review-verdict: failed-substantive head=${HEAD_B} -->"
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
aba_head="$(_review_routing_evidence_from_comments \
  "$(cat "$ISSUE_COMMENTS")" 540 "$HEAD_A" | jq -r '.head // empty')"
assert_eq "TC-E2E-REBASE-051 A-B-A routing reuses the unique A tuple" \
  "$HEAD_A|1|$CONFLICT_TRAILER_A" \
  "$aba_head|$(jq --arg h "$HEAD_A" \
    '[.[] | select(.body | contains("head=" + $h + " phase=pre-fanout"))] | length' \
    "$ISSUE_COMMENTS")|$(jq -r '.[-1].body' "$ISSUE_COMMENTS")"

_reset_route
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
jq '. + [
      {
        id: 900,
        author: "review-app[bot]",
        authorKind: "self",
        body: "malformed timestamp row",
        createdAt: null
      },
      {
        id: 901,
        author: "review-app[bot]",
        authorKind: "self",
        body: "missing timestamp row"
      }
    ]' "$ISSUE_COMMENTS" >"${ISSUE_COMMENTS}.tmp"
mv "${ISSUE_COMMENTS}.tmp" "$ISSUE_COMMENTS"
_append_issue_comment \
  "<!-- review-disposition: issue=540 head=${HEAD_B} phase=pre-fanout result=conflict-rebase -->"
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main pre-fanout
assert_eq "TC-E2E-REBASE-061 malformed rows cannot shift the routing boundary" \
  "2|$CONFLICT_TRAILER_A" \
  "$(jq --arg trailer "$CONFLICT_TRAILER_A" \
    '[.[] | select(.body == $trailer)] | length' "$ISSUE_COMMENTS")|$(jq -r '.[-1].body' "$ISSUE_COMMENTS")"

_reset_route
_review_route_mergeable_unknown 540 "$HEAD_A"
trace=$(cat "$TRACE")
assert_eq "TC-E2E-REBASE-012 unknown route reaches pending-dev" "0" "$?"
assert_not_contains "TC-E2E-REBASE-012 unknown route emits no PR conflict marker" "pr:auto-merge" "$trace"
assert_eq "TC-E2E-REBASE-012 unknown route persists disposition and trailer" "1|1" \
  "$(jq '[.[] | select(.body | contains("result=mergeable-unknown"))] | length' "$ISSUE_COMMENTS")|$(jq --arg trailer "$UNKNOWN_TRAILER_A" '[.[] | select(.body == $trailer)] | length' "$ISSUE_COMMENTS")"
assert_eq "TC-E2E-REBASE-063 UNKNOWN resets INV-129 immediately after its verdict" \
  $'verdict:failed-non-substantive\nissue:round-reset\ntransition:reviewing>pending-dev' \
  "$(grep -E '^(verdict:failed-non-substantive|issue:round-reset|transition:reviewing>pending-dev)$' "$TRACE")"

for requeue_cause in \
  head-changed mergeable-read-failed preflight-write-failed \
  auto-merge-marker-write-failed; do
  _reset_route
  _review_requeue_preflight \
    540 "$requeue_cause" "fixture retry for ${requeue_cause}"
  assert_eq "TC-E2E-REBASE-063 ${requeue_cause} resets INV-129 before requeue" \
    $'verdict:failed-non-substantive\nissue:round-reset\ntransition:reviewing>pending-review' \
    "$(grep -E '^(verdict:failed-non-substantive|issue:round-reset|transition:reviewing>pending-review)$' "$TRACE")"
done

unknown_case=$(sed -n '/^  mergeable-unknown)/,/^    ;;/p' "$WRAPPER")
assert_contains "TC-E2E-REBASE-025 UNKNOWN transition failure preserves non-substantive cleanup" \
  '_review_finish_required_pending_dev_route' "$unknown_case"
route_result_helper=$(sed -n \
  '/^_review_finish_required_pending_dev_route()/,/^}/p' "$WRAPPER")
assert_contains "TC-E2E-REBASE-025 shared route handler distinguishes required-write failure" \
  '20)' "$route_result_helper"
assert_contains "TC-E2E-REBASE-025 shared route handler retries only pending-dev after durable writes" \
  'REVIEW_CRASH_RETRY_EMIT_VERDICT="false"' "$route_result_helper"
assert_not_contains "TC-E2E-REBASE-025 dead crash-verdict overrides are removed" \
  'REVIEW_CRASH_RETRY_VERDICT' "$(cat "$WRAPPER")"

echo
echo "=== TC-E2E-REBASE-032..034: wrapper convergence ==="
E2E_CALLS=0
FANOUT_CALLS=0
_simulate_review_round() {
  local initial="$1" final="$2"; shift 2
  _run_preflight "$initial" "$final" "$@"
  case "$PF_ACTION" in
    proceed)
      E2E_CALLS=$((E2E_CALLS + 1))
      FANOUT_CALLS=$((FANOUT_CALLS + 1))
      ;;
    conflict-rebase)
      _review_route_conflict 540 42 "$PF_HEAD" "$PF_BRANCH" main pre-fanout
      ;;
  esac
}

_reset_route
E2E_CALLS=0 FANOUT_CALLS=0
_simulate_review_round "$open_a" "$open_a" CONFLICTING
assert_eq "TC-E2E-REBASE-032 conflict preflight reaches pending-dev" "0" "$?"
assert_eq "TC-E2E-REBASE-032 conflicting old HEAD runs zero E2E/fan-out" \
  "0|0" "$E2E_CALLS|$FANOUT_CALLS"
assert_eq "TC-E2E-REBASE-032 lifecycle route ends reviewing -> pending-dev" "1" \
  "$(grep -c 'transition:reviewing>pending-dev' "$TRACE")"

# A successful rebase advances the provider HEAD. The old disposition remains
# durable but does not match, and the new clean round runs the E2E lane once.
_simulate_review_round "$open_b" "$open_b" MERGEABLE
assert_eq "TC-E2E-REBASE-033 rebased HEAD runs E2E/fan-out exactly once" \
  "1|1" "$E2E_CALLS|$FANOUT_CALLS"
old_evidence="$(_review_routing_evidence_from_comments "$(cat "$ISSUE_COMMENTS")" 540 | jq -r '.head // empty')"
assert_eq "TC-E2E-REBASE-033 old disposition remains stale after HEAD advance" \
  "$HEAD_A" "$old_evidence"

# A second unresolved conflict on the unchanged old HEAD still stops before
# E2E. The dispatcher suite exercises the matching one-attempt -> stalled bound.
_reset_route
E2E_CALLS=0 FANOUT_CALLS=0
_simulate_review_round "$open_a" "$open_a" CONFLICTING
_simulate_review_round "$open_a" "$open_a" CONFLICTING
assert_eq "TC-E2E-REBASE-034 unresolved same-HEAD conflict never runs E2E/fan-out" \
  "0|0" "$E2E_CALLS|$FANOUT_CALLS"
assert_eq "TC-E2E-REBASE-034 repeated route keeps one semantic disposition/PR marker" \
  "1|1" \
  "$(jq '[.[] | select(.body | startswith("<!-- review-disposition:"))] | length' "$ISSUE_COMMENTS")|$(jq '[.[] | select(.body | contains("auto-merge-conflict: issue=540"))] | length' "$PR_COMMENTS")"

rebase_heading_line=$(grep -n 'Pre-implementation: rebase onto .*MANDATORY FIRST STEP' "$DEV_WRAPPER" | head -1 | cut -d: -f1)
feedback_line=$(grep -n '^## Review Feedback' "$DEV_WRAPPER" | head -1 | cut -d: -f1)
if [[ -n "$rebase_heading_line" && -n "$feedback_line" \
      && "$rebase_heading_line" -lt "$feedback_line" ]]; then
  ok "TC-E2E-REBASE-032 dev prompt puts mandatory rebase before review work"
else
  bad "TC-E2E-REBASE-032 mandatory rebase block must precede review feedback"
fi
if grep -q 'git push --force-with-lease' "$DEV_WRAPPER" \
   && grep -q 'git rebase --abort' "$DEV_WRAPPER" \
   && grep -q "record the conflicting files" "$DEV_WRAPPER"; then
  ok "TC-E2E-REBASE-033..034 dev prompt pins safe push and abort/human report"
else
  bad "TC-E2E-REBASE-033..034 dev prompt is missing safe rebase convergence instructions"
fi

echo
echo "=== TC-E2E-REBASE-019: clean preflight race closes at post-fan-out INV-44 ==="
_reset_route
E2E_CALLS=0 FANOUT_CALLS=0
_simulate_review_round "$open_a" "$open_a" MERGEABLE
_review_route_conflict 540 42 "$HEAD_A" "fix/540" main post-fanout
assert_eq "TC-E2E-REBASE-019 clean preflight ran E2E/fan-out once" \
  "1|1" "$E2E_CALLS|$FANOUT_CALLS"
assert_eq "TC-E2E-REBASE-019 later conflict still reaches canonical pending-dev route" \
  "1" "$(grep -c 'transition:reviewing>pending-dev' "$TRACE")"

echo
echo "=== TC-E2E-REBASE-035..037: provider-neutral caller ==="
CHP_GITHUB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/chp-github.sh"
CHP_GITLAB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/chp-gitlab.sh"
ITP_GITHUB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/itp-github.sh"
ITP_GITLAB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/itp-gitlab.sh"

# Prevent chp-gitlab.sh from loading the live transport before the fixture
# implementation below is installed.
_gl_api() { return 1; }
# shellcheck source=../../skills/autonomous-dispatcher/scripts/providers/chp-github.sh
source "$CHP_GITHUB"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/providers/chp-gitlab.sh
source "$CHP_GITLAB"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/providers/itp-github.sh
source "$ITP_GITHUB"
# shellcheck source=../../skills/autonomous-dispatcher/scripts/providers/itp-gitlab.sh
source "$ITP_GITLAB"

REPO="example/project"
GITLAB_PROJECT="example%2Fproject"
_LEAF_PROVIDER=""
_LEAF_MODE=""

# GitHub's real leaves consume gh-normalized snapshots and the projected
# mergeable token. The sequence files make counters survive command
# substitutions inside the production leaves.
gh() {
  local arg body="" remove="" add=""
  if [[ " $* " == *"/issues/540/comments "* ]]; then
    jq -cn --arg body "$(_review_disposition_marker 540 "$HEAD_A" conflict-rebase)" '
      [[{
        id: 1,
        user: {login:"review-bot[bot]", type:"Bot"},
        body: $body,
        created_at:"2026-07-30T00:00:01Z"
      }]]
    '
    return
  elif [[ "${1:-} ${2:-}" == "issue comment" ]]; then
    while [[ $# -gt 0 ]]; do
      [[ "$1" == "--body" ]] && body="$2"
      shift
    done
    printf 'post:%s\n' "$body" >>"$_ITP_TRACE_FILE"
    return
  elif [[ "${1:-} ${2:-}" == "issue edit" ]]; then
    while [[ $# -gt 0 ]]; do
      [[ "$1" == "--remove-label" ]] && remove="$2"
      [[ "$1" == "--add-label" ]] && add="$2"
      shift
    done
    printf 'transition:%s>%s\n' "$remove" "$add" >>"$_ITP_TRACE_FILE"
    return
  fi
  if [[ " $* " == *" --json mergeable "* ]]; then
    _next_sequence "$TMP/leaf-mergeable"
  else
    _next_sequence "$TMP/leaf-snapshots"
  fi
}

# GitLab's two real leaves share the MR-view endpoint. The adapter's temporary
# _LEAF_MODE identifies whether this call needs a snapshot fixture or a
# detailed_merge_status fixture.
_gl_api() {
  local value dms path="${!#}" method="" body="" arg
  if [[ "$path" == "/user" ]]; then
    printf '%s\n' '{"username":"review-bot"}'
    return
  elif [[ "$path" == *"/issues/540/notes?sort=asc&order_by=created_at" ]]; then
    jq -cn --arg body "$(_review_disposition_marker 540 "$HEAD_A" conflict-rebase)" '
      [{
        id: 1,
        author: {username:"review-bot"},
        system: false,
        body: $body,
        created_at:"2026-07-30T00:00:01Z"
      }]
    '
    return
  elif [[ "$path" == *"/issues/540/notes" || "$path" == *"/issues/540" ]]; then
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --method) method="$2"; shift ;;
        --body) body="$2"; shift ;;
      esac
      shift
    done
    if [[ "$method" == "POST" ]]; then
      printf 'post:%s\n' "$(jq -r '.body' <<<"$body")" >>"$_ITP_TRACE_FILE"
    elif [[ "$method" == "PUT" ]]; then
      printf 'transition:%s>%s\n' \
        "$(jq -r '.remove_labels // ""' <<<"$body")" \
        "$(jq -r '.add_labels // ""' <<<"$body")" >>"$_ITP_TRACE_FILE"
    fi
    return
  fi
  if [[ "$_LEAF_MODE" == "mergeable" ]]; then
    value="$(_next_sequence "$TMP/leaf-mergeable")" || return 1
    case "${value^^}" in
      MERGEABLE) dms="mergeable" ;;
      CONFLICTING) dms="conflict" ;;
      UNKNOWN) dms="checking" ;;
      *) return 1 ;;
    esac
    jq -cn --arg dms "$dms" '{detailed_merge_status:$dms}'
    return
  fi

  value="$(_next_sequence "$TMP/leaf-snapshots")" || return 1
  jq -c '
    {
      iid: 42,
      state: (
        if .state == "OPEN" then "opened"
        elif .state == "MERGED" then "merged"
        else "closed"
        end
      ),
      sha: .headRefOid,
      source_branch: .headRefName
    }
  ' <<<"$value"
}

chp_pr_view() {
  if [[ "$_LEAF_PROVIDER" == "github" ]]; then
    chp_github_pr_view "$@"
  else
    _LEAF_MODE="snapshot" chp_gitlab_pr_view "$@"
  fi
}

chp_mergeable() {
  if [[ "$_LEAF_PROVIDER" == "github" ]]; then
    chp_github_mergeable "$@"
  else
    _LEAF_MODE="mergeable" chp_gitlab_mergeable "$@"
  fi
}

_run_leaf_preflight() {
  local provider="$1" initial="$2" final="$3"; shift 3
  _LEAF_PROVIDER="$provider"
  _set_sequence "$TMP/leaf-snapshots" "$initial" "$final"
  _set_sequence "$TMP/leaf-mergeable" "$@"
  PF_STATE="" PF_HEAD="" PF_BRANCH="" PF_STATUS="" PF_ACTION=""
  review_mergeability_preflight 42 \
    PF_STATE PF_HEAD PF_BRANCH PF_STATUS PF_ACTION
  printf '%s|%s|%s|%s' "$PF_ACTION" "$PF_STATUS" "$PF_HEAD" "$PF_STATE"
}

_assert_leaf_parity() {
  local id="$1" name="$2" expected="$3" initial="$4" final="$5"; shift 5
  local github_trace gitlab_trace
  github_trace="$(_run_leaf_preflight github "$initial" "$final" "$@")"
  gitlab_trace="$(_run_leaf_preflight gitlab "$initial" "$final" "$@")"
  assert_eq "${id} ${name}: GitHub/GitLab normalized traces match" \
    "$github_trace" "$gitlab_trace"
  assert_eq "${id} ${name}: expected decision trace" "$expected" "$github_trace"
}

_assert_leaf_parity "TC-E2E-REBASE-035..036" "stable MERGEABLE" \
  "proceed|MERGEABLE|$HEAD_A|OPEN" "$open_a" "$open_a" MERGEABLE
_assert_leaf_parity "TC-E2E-REBASE-035..036" "stable CONFLICTING" \
  "conflict-rebase|CONFLICTING|$HEAD_A|OPEN" "$open_a" "$open_a" CONFLICTING
_assert_leaf_parity "TC-E2E-REBASE-035..036" "persistent UNKNOWN" \
  "mergeable-unknown|UNKNOWN|$HEAD_A|OPEN" "$open_a" "$open_a" \
  UNKNOWN UNKNOWN UNKNOWN
_assert_leaf_parity "TC-E2E-REBASE-035..036" "persistent provider failure" \
  "mergeable-unknown||$HEAD_A|OPEN" "$open_a" "$open_a" FAIL FAIL FAIL
_assert_leaf_parity "TC-E2E-REBASE-035..036" "closed during polling" \
  "closed|CONFLICTING|$HEAD_A|CLOSED" "$open_a" "$closed_a" CONFLICTING
_assert_leaf_parity "TC-E2E-REBASE-035..036" "HEAD changed during polling" \
  "head-changed|CONFLICTING|$HEAD_A|OPEN" "$open_a" "$open_b" CONFLICTING
_assert_leaf_parity "TC-E2E-REBASE-035..036" "initial snapshot failure" \
  "read-failed|||" FAIL "$open_a" MERGEABLE
_assert_leaf_parity "TC-E2E-REBASE-035..036" "final snapshot failure" \
  "read-failed|MERGEABLE|$HEAD_A|OPEN" "$open_a" FAIL MERGEABLE

_ITP_TRACE_FILE="$TMP/itp-trace"
BOT_LOGIN="review-bot[bot]"
GH_AUTH_MODE="token"
ITP_REQUIRE_SELF_AUTHOR=1
_run_itp_trace() {
  local provider="$1" comments evidence
  : >"$_ITP_TRACE_FILE"
  if [[ "$provider" == "github" ]]; then
    comments=$(itp_github_list_comments 540) || return 1
    itp_github_post_comment 540 "durable-write" || return 1
    itp_github_transition_state 540 reviewing pending-dev || return 1
  else
    comments=$(itp_gitlab_list_comments 540) || return 1
    itp_gitlab_post_comment 540 "durable-write" || return 1
    itp_gitlab_transition_state 540 reviewing pending-dev || return 1
  fi
  evidence="$(_review_routing_evidence_from_comments "$comments" 540)" || return 1
  printf '%s|%s' \
    "$(jq -r '[.kind,.head,.result] | join(":")' <<<"$evidence")" \
    "$(paste -sd, "$_ITP_TRACE_FILE")"
}
github_itp_trace="$(_run_itp_trace github)"
gitlab_itp_trace="$(_run_itp_trace gitlab)"
assert_eq "TC-E2E-REBASE-035..036 GitHub/GitLab ITP disposition/write/transition traces match" \
  "$github_itp_trace" "$gitlab_itp_trace"
assert_eq "TC-E2E-REBASE-035..036 ITP trace preserves strict disposition and state movement" \
  "disposition:${HEAD_A}:conflict-rebase|post:durable-write,transition:reviewing>pending-dev" \
  "$github_itp_trace"
unset ITP_REQUIRE_SELF_AUTHOR

caller_code=$(sed '/^[[:space:]]*#/d' "$MG_LIB")
if ! grep -Eq '(^|[;&|[:space:]])(gh|glab)[[:space:]]' <<<"$caller_code"; then
  ok "TC-E2E-REBASE-037 caller layer adds no raw gh/glab call"
else
  bad "TC-E2E-REBASE-037 caller layer must stay provider-neutral"
fi

echo
echo "PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
