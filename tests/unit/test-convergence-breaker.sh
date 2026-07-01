#!/bin/bash
# test-convergence-breaker.sh — INV-97 / issue #297.
#
# Unit tests for the dispatcher convergence circuit-breaker (Branch B″ in
# lib-dispatch.sh::handle_completed_session_routing) + its helpers
# (may_stall_now, convergence_trailer_hash, count_frozen_convergence_rounds).
#
# The breaker halts a non-converging dev↔review loop: a `failed-substantive` +
# `dev-actionable=true` verdict that churns dev-resume across ≥3 COMPLETED
# zero-commit rounds against a FROZEN PR head (the #286 deadlock shape). It posts
# ONE structured `reason=non-convergence` report + marker, then transitions the
# issue to `stalled` (the declared pending-dev → stalled movement). Biased to MISS
# (a false-trip is expensive; MAX_RETRIES is the backstop).
#
# Test IDs map to docs/test-cases/convergence-breaker.md.
#
# Run: env -u PROJECT_DIR bash tests/unit/test-convergence-breaker.sh

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
export PROJECT_ID="test-inv97-breaker-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5
export BOT_LOGIN="kane-review-agent"

# ---------------------------------------------------------------------------
# Routing-side mocks (mirrors test-handle-completed-session-routing.sh).
# ---------------------------------------------------------------------------
_MOCK_VERDICT="failed-substantive"
_MOCK_CAUSE=""
_MOCK_DEV_ACTIONABLE="true"
_MOCK_FLIP_COUNT=0
_MOCK_LABEL_SWAPS=""
_MOCK_DISPATCH_CALLS=""
_MOCK_POST_TOKEN_CALLS=""
_MOCK_MARK_STALLED_CALLS=""
_MOCK_COMMENT_COUNT=0
_MOCK_LAST_COMMENT_BODY=""
_MOCK_FULL_COMMENT_LOG=""
_MOCK_PR_HEAD=""
_MOCK_PR_NUMBER="777"
_MOCK_LAST_REVIEWED_HEAD=""
_MOCK_BOT_UNFIXABLE=1
# Convergence-specific:
_MOCK_FROZEN_ROUND_COMMENTS=0     # how many "no new commits since last review at `<head>`" comments to synthesize
_MOCK_NONACT_MARKER_PRESENT=0     # a non-actionable-finding:<head> marker already on the issue?
_MOCK_CB_MARKER_PRESENT=0         # a dispatcher-convergence-breaker marker (same trailer) already posted?
_MOCK_CB_MARKER_HASH=""           # the trailer-hash the synthesized existing marker carries
_MOCK_PID_ALIVE=1                 # 1 = DEAD (eligible); 0 = ALIVE (defer)
_MOCK_VERDICT_BODY="Blocking: acceptance criterion #3 contradicts #1 — cannot satisfy both. <!-- review-verdict: failed-substantive dev-actionable=true -->"

log() { :; }

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

# Re-define mocks AFTER sourcing so they win over the real functions.
log() { :; }

classify_recent_review_verdict() {
  local _issue="$1" _ts="$2" _v="$3" _c="$4" _da="${5:-}"
  printf -v "$_v" '%s' "$_MOCK_VERDICT"
  printf -v "$_c" '%s' "$_MOCK_CAUSE"
  [ -n "$_da" ] && printf -v "$_da" '%s' "${_MOCK_DEV_ACTIONABLE:-true}"
  return 0
}
count_review_aware_flips() { printf '%s' "$_MOCK_FLIP_COUNT"; }
label_swap() {
  local issue_num="$1" remove="$2" add="$3"
  _MOCK_LABEL_SWAPS+="${issue_num}:${remove}:${add} "
}
mark_stalled() { _MOCK_MARK_STALLED_CALLS+="${1} "; }
post_dispatch_token() { _MOCK_POST_TOKEN_CALLS+="${1}:${2} "; }
dispatch() { _MOCK_DISPATCH_CALLS+="${1}:${2} "; }
fetch_pr_for_issue() {
  [ -n "$_MOCK_PR_HEAD" ] || { printf '%s' ""; return 0; }
  printf '{"number":%s,"headRefOid":"%s"}\n' "$_MOCK_PR_NUMBER" "$_MOCK_PR_HEAD"
}
last_reviewed_head() { printf '%s' "$_MOCK_LAST_REVIEWED_HEAD"; }
dev_report_bot_unfixable() { return "$_MOCK_BOT_UNFIXABLE"; }
recent_review_verdict_body() { printf '%s' "$_MOCK_VERDICT_BODY"; }

# may_stall_now is the shared liveness pre-gate. Mock it directly for the routing
# tests (its own internals are exercised by the source-of-truth + MSL tests).
may_stall_now() {
  # honor an optional leading --at-cap for signature parity
  [ "${1:-}" = "--at-cap" ] && shift
  # 0 = eligible (DEAD), 1 = defer (ALIVE)
  [ "$_MOCK_PID_ALIVE" = 0 ] && return 1
  return 0
}

# Synthesize the normalized issue-comment array. Emits:
#   - _MOCK_FROZEN_ROUND_COMMENTS copies of the per-round "no new commits" comment
#     for the current head (this is what count_frozen_convergence_rounds counts),
#   - a non-actionable-finding:<head> marker when _MOCK_NONACT_MARKER_PRESENT,
#   - an existing dispatcher-convergence-breaker marker when _MOCK_CB_MARKER_PRESENT.
itp_list_comments() {
  local _bodies=() i
  for ((i = 0; i < _MOCK_FROZEN_ROUND_COMMENTS; i++)); do
    _bodies+=("Dev process exited (no new commits since last review at \`${_MOCK_PR_HEAD}\`). Moving to pending-dev for retry.")
  done
  if [[ "$_MOCK_NONACT_MARKER_PRESENT" != "0" ]]; then
    _bodies+=("non-actionable-finding:${_MOCK_PR_HEAD} prior escalation")
  fi
  if [[ "$_MOCK_CB_MARKER_PRESENT" != "0" ]]; then
    _bodies+=("<!-- dispatcher-convergence-breaker: issue=100 head=${_MOCK_PR_HEAD} trailer=${_MOCK_CB_MARKER_HASH} -->")
  fi
  local _json="[]" _ts=0 b
  for b in "${_bodies[@]}"; do
    _json=$(jq -c --arg b "$b" --argjson t "$_ts" \
      '. + [{id:(100+$t), author:"my-claw", authorKind:"self", body:$b, createdAt:"2026-06-12T00:00:0\($t)Z"}]' <<<"$_json")
    _ts=$((_ts + 1))
  done
  printf '%s' "$_json"
}
itp_post_comment() {
  _MOCK_LAST_COMMENT_BODY="$2"
  _MOCK_FULL_COMMENT_LOG+="$2"$'\n'
  _MOCK_COMMENT_COUNT=$((_MOCK_COMMENT_COUNT + 1))
  return 0
}

reset_mocks() {
  _MOCK_VERDICT="failed-substantive"
  _MOCK_CAUSE=""
  _MOCK_DEV_ACTIONABLE="true"
  _MOCK_FLIP_COUNT=0
  _MOCK_LABEL_SWAPS=""
  _MOCK_DISPATCH_CALLS=""
  _MOCK_POST_TOKEN_CALLS=""
  _MOCK_MARK_STALLED_CALLS=""
  _MOCK_COMMENT_COUNT=0
  _MOCK_LAST_COMMENT_BODY=""
  _MOCK_FULL_COMMENT_LOG=""
  _MOCK_PR_HEAD=""
  _MOCK_PR_NUMBER="777"
  _MOCK_LAST_REVIEWED_HEAD=""
  _MOCK_BOT_UNFIXABLE=1
  _MOCK_FROZEN_ROUND_COMMENTS=0
  _MOCK_NONACT_MARKER_PRESENT=0
  _MOCK_CB_MARKER_PRESENT=0
  _MOCK_CB_MARKER_HASH=""
  _MOCK_PID_ALIVE=1
  _MOCK_VERDICT_BODY="Blocking: acceptance criterion #3 contradicts #1 — cannot satisfy both. <!-- review-verdict: failed-substantive dev-actionable=true -->"
  unset CONVERGENCE_STALL_THRESHOLD
  if [[ -n "${_MOCK_LOG_FILE:-}" ]]; then
    chmod u+w "$_MOCK_LOG_FILE" 2>/dev/null || true
    rm -f "$_MOCK_LOG_FILE"
    _MOCK_LOG_FILE=""
  fi
}
_MOCK_LOG_FILE=""
prepare_log() {
  _MOCK_LOG_FILE="/tmp/agent-${PROJECT_ID}-issue-${1}.log"
  printf 'something\n' > "$_MOCK_LOG_FILE"
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"; echo "      actual=  [$actual]"; FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle=[$needle]"; echo "      haystack=[$haystack]"; FAIL=$((FAIL + 1))
  fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle should be ABSENT=[$needle]"; FAIL=$((FAIL + 1))
  fi
}

# ===========================================================================
echo "=== convergence_trailer_hash: deterministic, keyed on {verdict}|{cause}|{dev-actionable} ==="
h1=$(convergence_trailer_hash "failed-substantive" "" "true")
h2=$(convergence_trailer_hash "failed-substantive" "" "true")
assert_eq "same inputs → same hash" "$h1" "$h2"
h3=$(convergence_trailer_hash "failed-substantive" "bot-timeout" "true")
if [[ "$h1" != "$h3" ]]; then
  echo -e "  ${GREEN}PASS${NC}: different cause → different hash"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: different cause produced the same hash"; FAIL=$((FAIL + 1))
fi
h4=$(convergence_trailer_hash "failed-substantive" "" "false")
if [[ "$h1" != "$h4" ]]; then
  echo -e "  ${GREEN}PASS${NC}: different dev-actionable → different hash"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: different dev-actionable produced the same hash"; FAIL=$((FAIL + 1))
fi

# ===========================================================================
echo ""
echo "=== count_frozen_convergence_rounds: derives from the per-round comment ==="
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
assert_eq "counts 3 per-round frozen-head comments" "3" "$(count_frozen_convergence_rounds 100 deadbeef)"
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
_MOCK_NONACT_MARKER_PRESENT=1
assert_eq "CB-COUNT-009: a #298 non-actionable marker on this head → count 0 (round routed to #298)" "0" "$(count_frozen_convergence_rounds 100 deadbeef)"
assert_eq "empty head → 0" "0" "$(count_frozen_convergence_rounds 100 "")"

# ===========================================================================
echo ""
echo "=== CB-TRIP-001: ≥3 frozen rounds + dev-actionable=true + eligible → trip ==="
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_PR_HEAD="deadbeef"
_MOCK_PR_NUMBER="777"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"   # frozen
_MOCK_FROZEN_ROUND_COMMENTS=3
_MOCK_PID_ALIVE=1                      # DEAD → eligible
prepare_log 100
handle_completed_session_routing 100 "sid-cb001" "2026-05-21T03:18:00Z"
rc=$?
assert_eq "CB-TRIP-001 returns 0" "0" "$rc"
assert_eq "CB-TRIP-001 label_swap pending-dev → stalled (declared movement)" "100:pending-dev:stalled " "$_MOCK_LABEL_SWAPS"
assert_eq "CB-TRIP-001 NO dispatch dev-new" "" "$_MOCK_DISPATCH_CALLS"
assert_eq "CB-TRIP-001 NO post_dispatch_token" "" "$_MOCK_POST_TOKEN_CALLS"
assert_eq "CB-TRIP-001 does NOT route through mark_stalled (no dual comment)" "" "$_MOCK_MARK_STALLED_CALLS"
assert_eq "CB-DUAL-011 exactly ONE terminal comment" "1" "$_MOCK_COMMENT_COUNT"
assert_contains "CB-TRIP-001 report reason=non-convergence" "reason=non-convergence" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "CB-TRIP-001 report carries the marker" "<!-- dispatcher-convergence-breaker: issue=100 head=deadbeef trailer=" "$_MOCK_LAST_COMMENT_BODY"
# Log NOT truncated on the halt path.
log_size=$(stat -c '%s' "$_MOCK_LOG_FILE" 2>/dev/null || echo 0)
if [[ "$log_size" != "0" ]]; then
  echo -e "  ${GREEN}PASS${NC}: CB-TRIP-001 log left intact (not truncated)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: CB-TRIP-001 log was truncated on the halt path"; FAIL=$((FAIL + 1))
fi

# ===========================================================================
echo ""
echo "=== CB-REPORT-008: report content (PR ref + SHA + resume instruction) ==="
# reuse CB-TRIP-001's _MOCK_LAST_COMMENT_BODY
assert_contains "CB-REPORT-008 PR ref present" "PR: #777" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "CB-REPORT-008 frozen SHA present" "\`deadbeef\`" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "CB-REPORT-008 resume instruction present" "re-add the \`autonomous\` label" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "CB-REPORT-008 repeated-failure count present" "Repeated-failure count on this frozen head: **3**" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "CB-REPORT-008 verbatim finding excerpt present" "acceptance criterion #3 contradicts #1" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "CB-REPORT-008 human-action checklist present" "Human action needed" "$_MOCK_LAST_COMMENT_BODY"

# ===========================================================================
echo ""
echo "=== CB-MISS-002: head ADVANCED (converging) → does NOT trip, dev-new proceeds ==="
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_PR_HEAD="cafe1234"            # advanced
_MOCK_LAST_REVIEWED_HEAD="deadbeef" # older
_MOCK_FROZEN_ROUND_COMMENTS=3       # (on the old head — but current != last, so no freeze)
_MOCK_PID_ALIVE=1
prepare_log 100
handle_completed_session_routing 100 "sid-cb002" "2026-05-21T03:18:00Z"
assert_eq "CB-MISS-002 dispatch dev-new fired (converging)" "dev-new:100 " "$_MOCK_DISPATCH_CALLS"
assert_not_contains "CB-MISS-002 no convergence report" "reason=non-convergence" "$_MOCK_FULL_COMMENT_LOG"
assert_not_contains "CB-MISS-002 no stalled transition" "pending-dev:stalled" "$_MOCK_LABEL_SWAPS"

# ===========================================================================
echo ""
echo "=== CB-MISS-003: only 2 frozen rounds (< threshold 3) → does NOT trip ==="
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=2
_MOCK_PID_ALIVE=1
prepare_log 100
handle_completed_session_routing 100 "sid-cb003" "2026-05-21T03:18:00Z"
assert_eq "CB-MISS-003 dispatch dev-new fired (< threshold)" "dev-new:100 " "$_MOCK_DISPATCH_CALLS"
assert_not_contains "CB-MISS-003 no convergence report" "reason=non-convergence" "$_MOCK_FULL_COMMENT_LOG"

# ===========================================================================
echo ""
echo "=== CB-PRECEDENCE-004: dev-actionable=false → #298 Branch B′ runs, breaker does NOT ==="
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="false"        # #298 owns this
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=5       # even with many frozen rounds
_MOCK_PID_ALIVE=1
prepare_log 100
handle_completed_session_routing 100 "sid-cb004" "2026-05-21T03:18:00Z"
assert_eq "CB-PRECEDENCE-004 #298 mark_stalled fired" "100 " "$_MOCK_MARK_STALLED_CALLS"
assert_contains "CB-PRECEDENCE-004 #298 notice (not #297)" "non-actionable-finding:deadbeef" "$_MOCK_LAST_COMMENT_BODY"
assert_not_contains "CB-PRECEDENCE-004 NO convergence report" "reason=non-convergence" "$_MOCK_FULL_COMMENT_LOG"
assert_not_contains "CB-PRECEDENCE-004 NO breaker label_swap" "pending-dev:stalled" "$_MOCK_LABEL_SWAPS"

# ===========================================================================
echo ""
echo "=== CB-LIVE-005: ≥3 frozen rounds BUT dev PID ALIVE → defer, no orphan report ==="
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
_MOCK_PID_ALIVE=0                   # ALIVE → defer
prepare_log 100
handle_completed_session_routing 100 "sid-cb005" "2026-05-21T03:18:00Z"
rc=$?
assert_eq "CB-LIVE-005 returns 0 (deferred)" "0" "$rc"
assert_eq "CB-LIVE-005 posts NOTHING (no orphan report)" "0" "$_MOCK_COMMENT_COUNT"
assert_eq "CB-LIVE-005 marks NOTHING (no label_swap)" "" "$_MOCK_LABEL_SWAPS"
assert_eq "CB-LIVE-005 dispatches NOTHING" "" "$_MOCK_DISPATCH_CALLS"

# ===========================================================================
echo ""
echo "=== CB-IDEM-006: same {issue,head,trailer-hash} marker already present → no-op ==="
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_CAUSE=""
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
_MOCK_PID_ALIVE=1
_MOCK_CB_MARKER_PRESENT=1
_MOCK_CB_MARKER_HASH="$(convergence_trailer_hash failed-substantive "" true)"  # SAME hash as would be computed
prepare_log 100
handle_completed_session_routing 100 "sid-cb006" "2026-05-21T03:18:00Z"
rc=$?
assert_eq "CB-IDEM-006 returns 0" "0" "$rc"
assert_eq "CB-IDEM-006 posts NOTHING (idempotent)" "0" "$_MOCK_COMMENT_COUNT"
assert_eq "CB-IDEM-006 no duplicate label_swap" "" "$_MOCK_LABEL_SWAPS"
assert_eq "CB-IDEM-006 no dispatch" "" "$_MOCK_DISPATCH_CALLS"

# ===========================================================================
echo ""
echo "=== CB-IDEM-007: NEW trailer-hash on same frozen head → re-evaluates (trips) ==="
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_CAUSE=""
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
_MOCK_PID_ALIVE=1
_MOCK_CB_MARKER_PRESENT=1
_MOCK_CB_MARKER_HASH="STALE_DIFFERENT_HASH"   # an OLD case's marker — different hash
prepare_log 100
handle_completed_session_routing 100 "sid-cb007" "2026-05-21T03:18:00Z"
assert_eq "CB-IDEM-007 trips (new hash not suppressed)" "100:pending-dev:stalled " "$_MOCK_LABEL_SWAPS"
assert_eq "CB-IDEM-007 posts the fresh report" "1" "$_MOCK_COMMENT_COUNT"

# ===========================================================================
echo ""
echo "=== CB-THRESH-012: CONVERGENCE_STALL_THRESHOLD override honored ==="
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
_MOCK_PID_ALIVE=1
export CONVERGENCE_STALL_THRESHOLD=4
prepare_log 100
handle_completed_session_routing 100 "sid-cb012a" "2026-05-21T03:18:00Z"
assert_eq "CB-THRESH-012 threshold=4: 3 rounds do NOT trip → dev-new" "dev-new:100 " "$_MOCK_DISPATCH_CALLS"
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=4
_MOCK_PID_ALIVE=1
export CONVERGENCE_STALL_THRESHOLD=4
prepare_log 100
handle_completed_session_routing 100 "sid-cb012b" "2026-05-21T03:18:00Z"
assert_eq "CB-THRESH-012 threshold=4: 4 rounds trip → stalled" "100:pending-dev:stalled " "$_MOCK_LABEL_SWAPS"
unset CONVERGENCE_STALL_THRESHOLD

# ===========================================================================
echo ""
echo "=== CB-SHARED-010 (source-of-truth): mark_stalled + breaker both call may_stall_now ==="
# The breaker's live-PID pre-gate MUST call may_stall_now (not a copy-pasted
# pid_alive block). And mark_stalled's liveness gate MUST also route through it.
if grep -qE 'may_stall_now[[:space:]]+"\$issue_num"' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: CB-SHARED-010 the breaker calls may_stall_now"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: CB-SHARED-010 the breaker does not call the shared may_stall_now"; FAIL=$((FAIL + 1))
fi
# mark_stalled routes its liveness through may_stall_now (WITH the --at-cap parity call).
if grep -qE 'may_stall_now --at-cap "\$issue_num"' "$LIB" && grep -qE 'may_stall_now "\$issue_num"' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: CB-SHARED-010 mark_stalled routes liveness through may_stall_now (both --at-cap and plain)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: CB-SHARED-010 mark_stalled does not route through the shared may_stall_now"; FAIL=$((FAIL + 1))
fi
# The pid_alive liveness/empty-PID block must NOT be duplicated: exactly ONE
# function (may_stall_now) should carry the local empty-PID→DEAD narrowing.
narrow_count=$(grep -cE '_backend" != "remote-aws-ssm" \] && \[ -z "\$pid"' "$LIB")
assert_eq "CB-SHARED-010 empty-PID→DEAD narrowing lives in exactly ONE place (may_stall_now)" "1" "$narrow_count"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
