#!/bin/bash
# test-issue-466-crashed-session-recovery.sh — regression gate for issue #466.
#
# BUG: `handle_pending_dev_pr_exists`'s same-HEAD block only routed a
# `completed` dev session (via [INV-98]) or a lost session-report comment
# ([INV-111] self-heal, `_sid` empty). A session id that RESOLVED but whose
# `is_session_completed` check returned false — a non-terminal stop reason
# such as `api_error`, a non-claude dev CLI, or an unreadable log — fell
# straight to the residual `stale-verdict:<head>` park, permanently: the park
# only unblocks on a new commit, and with the HEAD already reviewed, no
# dev-new will ever be dispatched to produce one.
#
# FIX ([INV-125]): the [INV-111] self-heal case-statement body is extracted
# into a shared helper, `_same_head_verdict_aware_recovery`, called from TWO
# disjoint preconditions — `cause=self-heal` (`_sid` empty) and
# `cause=crashed-session` (`_sid` resolved, `is_session_completed` false) —
# both gated on `may_stall_now` (no live wrapper). The helper is
# verdict-aware and shares budget markers across both causes so neither can
# double-spend the other's one bounded retry. Marker-present /
# budget-exhausted arms call `mark_stalled` directly instead of falling to
# the residual park (Part 2: closes the counting hole).
#
# This suite drives the REAL `handle_pending_dev_pr_exists` /
# `_same_head_verdict_aware_recovery` (stubbing only the VERB / dispatch /
# label / mark_stalled seams — golden-trace style, mirroring
# test-issue-351-stale-verdict-delegate.sh).
#
# Run: bash tests/unit/test-issue-466-crashed-session-recovery.sh

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
export PROJECT_ID="test-466-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5

US=$'\037'

# ---------------------------------------------------------------------------
# Per-test knobs.
# ---------------------------------------------------------------------------
_MOCK_SESSION_ID='sid466'      # extract_dev_session_id
_MOCK_COMPLETED_RC=1           # is_session_completed rc (1 = not completed/unprovable)
_MOCK_MAY_STALL_NOW=0          # 0 = eligible (no live wrapper), 1 = defer (wrapper alive)
_MOCK_VERDICT='failed-substantive'
_MOCK_CAUSE=''
_MOCK_DEV_ACTIONABLE='true'
_MOCK_CURRENT_HEAD='sha-A'
_MOCK_NOTICE_PRESENT=0          # generic dedup marker present (stale-verdict)
_MOCK_SELF_HEAL_PRESENT=0       # self-heal-lost-session:<head> present
_MOCK_CRASHED_RETRY_PRESENT=0   # crashed-session-retry:<head> present
_MOCK_NONSUB_PRESENT=0          # self-heal-non-substantive:<head> present
_MOCK_ACQUIRE_RC=0
_MOCK_LABEL_SWAP_RC=0
_MOCK_DISPATCH_RC=0

_TRACE_FILE=""
_rec() {
  local v="$1"; shift; local a="$v"; local x
  for x in "$@"; do a+="${US}${x}"; done
  a="${a//$'\n'/\\n}"
  printf '%s\n' "$a" >> "$_TRACE_FILE"
}
_trace_reset() { : > "$_TRACE_FILE"; }

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT
_TRACE_FILE="$TMPDIR_T/trace"; : > "$_TRACE_FILE"

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

itp_list_comments() {
  _rec itp_list_comments "$@"
  local body="baseline comment"
  [ "$_MOCK_NOTICE_PRESENT" = "1" ] && body+=" stale-verdict:${_MOCK_CURRENT_HEAD}"
  [ "$_MOCK_SELF_HEAL_PRESENT" = "1" ] && body+=" self-heal-lost-session:${_MOCK_CURRENT_HEAD}"
  [ "$_MOCK_CRASHED_RETRY_PRESENT" = "1" ] && body+=" crashed-session-retry:${_MOCK_CURRENT_HEAD}"
  [ "$_MOCK_NONSUB_PRESENT" = "1" ] && body+=" self-heal-non-substantive:${_MOCK_CURRENT_HEAD}"
  printf '%s\n' "[{\"body\":\"${body}\"}]"
}
itp_post_comment()     { _rec itp_post_comment "$@"; }
itp_transition_state() { _rec itp_transition_state "$@"; }
fetch_pr_for_issue()   { _rec fetch_pr_for_issue "$@"; printf '%s' "{\"number\":42,\"headRefOid\":\"${_MOCK_CURRENT_HEAD}\"}"; }
last_reviewed_head()   { printf '%s' "$_MOCK_CURRENT_HEAD"; }
extract_dev_session_id() { printf '%s' "$_MOCK_SESSION_ID"; }
is_session_completed() {
  [ "$_MOCK_COMPLETED_RC" = "0" ] && return 0
  return 1
}
may_stall_now() { return "$_MOCK_MAY_STALL_NOW"; }
classify_recent_review_verdict() {
  local _v="$3" _c="$4" _da="${5:-}"
  printf -v "$_v" '%s' "$_MOCK_VERDICT"; printf -v "$_c" '%s' "$_MOCK_CAUSE"
  [ -n "$_da" ] && printf -v "$_da" '%s' "$_MOCK_DEV_ACTIONABLE"; return 0
}
acquire_dispatch_marker()          { _rec acquire_dispatch_marker "$@"; return "$_MOCK_ACQUIRE_RC"; }
release_dispatch_marker()          { _rec release_dispatch_marker "$@"; }
dispatch_marker_confirm_launched() { _rec dispatch_marker_confirm_launched "$@"; }
label_swap()                       { _rec label_swap "$@"; return "$_MOCK_LABEL_SWAP_RC"; }
post_dispatch_token()              { _rec post_dispatch_token "$@"; }
dispatch()                         { _rec dispatch "$@"; return "$_MOCK_DISPATCH_RC"; }
handle_dispatch_deferred()         { _rec handle_dispatch_deferred "$@"; }
mark_stalled()                     { _rec mark_stalled "$@"; }
handle_completed_session_routing() { _rec handle_completed_session_routing "$@"; }
log() { :; }

# ---------------------------------------------------------------------------
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1));
  else echo -e "  ${RED}FAIL${NC}: $desc"; echo "      expected: [$expected]"; echo "      actual:   [$actual]"; FAIL=$((FAIL + 1)); fi
}
assert_match() {
  local desc="$1" pat="$2" hay="$3"
  if grep -qE "$pat" <<<"$hay"; then echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1));
  else echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pat)"; echo "      haystack: [$hay]"; FAIL=$((FAIL + 1)); fi
}
assert_no_match() {
  local desc="$1" pat="$2" hay="$3"
  if ! grep -qE "$pat" <<<"$hay"; then echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1));
  else echo -e "  ${RED}FAIL${NC}: $desc (pattern '$pat' should NOT match)"; echo "      haystack: [$hay]"; FAIL=$((FAIL + 1)); fi
}
_trace_verbs() { local e; while IFS= read -r e; do [ -n "$e" ] && printf '%s\n' "${e%%${US}*}"; done < "$_TRACE_FILE"; }
_trace_all()   { cat "$_TRACE_FILE"; }

_reset() {
  _trace_reset
  _MOCK_SESSION_ID='sid466'; _MOCK_COMPLETED_RC=1; _MOCK_MAY_STALL_NOW=0
  _MOCK_VERDICT='failed-substantive'; _MOCK_CAUSE=''; _MOCK_DEV_ACTIONABLE='true'
  _MOCK_CURRENT_HEAD='sha-A'; _MOCK_NOTICE_PRESENT=0; _MOCK_SELF_HEAL_PRESENT=0
  _MOCK_CRASHED_RETRY_PRESENT=0; _MOCK_NONSUB_PRESENT=0
  _MOCK_ACQUIRE_RC=0; _MOCK_LABEL_SWAP_RC=0; _MOCK_DISPATCH_RC=0
}

# ===========================================================================
echo "=== TC-466-CRASH-001: api_error same-HEAD, no live wrapper → bounded crashed-session-retry dev-new, NOT the park ==="
# (Regression test per the issue: fails before the fix — pre-fix, _sid is
# non-empty so the old self-heal branch's [-z "$_sid"] guard never engaged,
# and the code fell straight to the unconditional residual park.)
# ===========================================================================
_reset
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-466-CRASH-001 returns 0" "0" "$rc"
assert_match "TC-466-CRASH-001 dispatched exactly one dev-new" "^dispatch${US}dev-new${US}99$" "$(_trace_all)"
assert_eq   "TC-466-CRASH-001 dev-new dispatched exactly once" "1" "$(_trace_verbs | grep -c '^dispatch$')"
assert_match "TC-466-CRASH-001 label_swap pending-dev → in-progress" "label_swap${US}99${US}pending-dev${US}in-progress" "$(_trace_all)"
assert_match "TC-466-CRASH-001 posts crashed-session-retry marker" "crashed-session-retry:sha-A" "$(_trace_all)"
assert_match "TC-466-CRASH-001 confirms the dispatch marker launched" "^dispatch_marker_confirm_launched" "$(_trace_all)"
assert_no_match "TC-466-CRASH-001 NO stale-verdict park notice posted" "stale-verdict:" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-466-CRASH-002: non-claude dev CLI (is_session_completed false by design, unrelated to api_error) → same recovery ==="
# ===========================================================================
_reset
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-466-CRASH-002 returns 0" "0" "$rc"
assert_match "TC-466-CRASH-002 dispatched exactly one dev-new" "^dispatch${US}dev-new${US}99$" "$(_trace_all)"
assert_no_match "TC-466-CRASH-002 NO stale-verdict park" "stale-verdict:" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-466-VERDICT-001: crashed-session cause, verdict=passed (race) → no-op ==="
# ===========================================================================
_reset
_MOCK_VERDICT='passed'
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-466-VERDICT-001 returns 0" "0" "$rc"
assert_eq   "TC-466-VERDICT-001 ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_no_match "TC-466-VERDICT-001 no marker posted" "crashed-session-retry:" "$(_trace_all)"
assert_no_match "TC-466-VERDICT-001 NO stale-verdict park (race, Step 0 reconciles)" "stale-verdict:" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-466-VERDICT-002: crashed-session cause, dev-actionable=false → mark_stalled, NO dev-new ==="
# ===========================================================================
_reset
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='false'
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-466-VERDICT-002 returns 0" "0" "$rc"
assert_match "TC-466-VERDICT-002 mark_stalled fired" "^mark_stalled" "$(_trace_all)"
assert_eq   "TC-466-VERDICT-002 ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_match "TC-466-VERDICT-002 posts crashed-session-non-actionable marker" "crashed-session-non-actionable:sha-A" "$(_trace_all)"
assert_no_match "TC-466-VERDICT-002 NO stale-verdict park" "stale-verdict:" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-466-VERDICT-003: crashed-session cause, verdict=failed-non-substantive → pending-review re-route, shared marker ==="
# ===========================================================================
_reset
_MOCK_VERDICT='failed-non-substantive'; _MOCK_CAUSE='bot-timeout'
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-466-VERDICT-003 returns 0" "0" "$rc"
assert_match "TC-466-VERDICT-003 label_swap pending-dev → pending-review" "label_swap${US}99${US}pending-dev${US}pending-review" "$(_trace_all)"
assert_eq   "TC-466-VERDICT-003 ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_match "TC-466-VERDICT-003 posts SHARED self-heal-non-substantive marker" "self-heal-non-substantive:sha-A" "$(_trace_all)"
assert_no_match "TC-466-VERDICT-003 NO stale-verdict park" "stale-verdict:" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-466-BUDGET-001: crashed-session cause, self-heal-lost-session marker already present → NO 2nd dev-new, mark_stalled ==="
# ===========================================================================
_reset
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'
_MOCK_SELF_HEAL_PRESENT=1
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-466-BUDGET-001 returns 0" "0" "$rc"
assert_eq   "TC-466-BUDGET-001 ZERO dev-new (shared budget spent)" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_match "TC-466-BUDGET-001 marks stalled instead of parking" "^mark_stalled" "$(_trace_all)"
assert_no_match "TC-466-BUDGET-001 NO stale-verdict park" "stale-verdict:" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-466-BUDGET-002: self-heal cause (no session id), crashed-session-retry marker already present → NO 2nd dev-new, mark_stalled ==="
# ===========================================================================
_reset
_MOCK_SESSION_ID=''   # switches to the self-heal cause call site
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'
_MOCK_CRASHED_RETRY_PRESENT=1
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-466-BUDGET-002 returns 0" "0" "$rc"
assert_eq   "TC-466-BUDGET-002 ZERO dev-new (shared budget spent)" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_match "TC-466-BUDGET-002 marks stalled instead of parking" "^mark_stalled" "$(_trace_all)"
assert_no_match "TC-466-BUDGET-002 NO stale-verdict park" "stale-verdict:" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-466-BUDGET-003: crashed-session cause, verdict=failed-non-substantive, shared marker already present → mark_stalled, not a 2nd flip ==="
# ===========================================================================
_reset
_MOCK_VERDICT='failed-non-substantive'; _MOCK_CAUSE='bot-timeout'
_MOCK_NONSUB_PRESENT=1
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-466-BUDGET-003 returns 0" "0" "$rc"
assert_no_match "TC-466-BUDGET-003 no second pending-review flip" "pending-dev${US}pending-review" "$(_trace_all)"
assert_match "TC-466-BUDGET-003 marks stalled instead of parking" "^mark_stalled" "$(_trace_all)"
assert_no_match "TC-466-BUDGET-003 NO stale-verdict park" "stale-verdict:" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-466-STALL-001/002/003: counting-hole regression — marker-present reaches mark_stalled independent of count_retries ==="
# (count_retries is never consulted by the helper at all — these pins prove
# the stall decision is marker-driven, not count-driven, which is exactly
# what makes it reachable even when a park would have frozen count_retries.)
# ===========================================================================
_reset
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'; _MOCK_SELF_HEAL_PRESENT=1
handle_pending_dev_pr_exists 99 >/dev/null
assert_match "TC-466-STALL-001 self-heal-lost-session marker present → mark_stalled fires" "^mark_stalled" "$(_trace_all)"

_reset
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'; _MOCK_CRASHED_RETRY_PRESENT=1
handle_pending_dev_pr_exists 99 >/dev/null
assert_match "TC-466-STALL-002 crashed-session-retry marker present → mark_stalled fires" "^mark_stalled" "$(_trace_all)"

_reset
_MOCK_VERDICT='failed-non-substantive'; _MOCK_CAUSE='bot-timeout'; _MOCK_NONSUB_PRESENT=1
handle_pending_dev_pr_exists 99 >/dev/null
assert_match "TC-466-STALL-003 self-heal-non-substantive marker present → mark_stalled fires" "^mark_stalled" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-466-LIVE-001: a dev wrapper IS alive → residual park unchanged, never race a healthy wrapper ==="
# ===========================================================================
_reset
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'
_MOCK_MAY_STALL_NOW=1
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-466-LIVE-001 returns 0 (park)" "0" "$rc"
assert_match "TC-466-LIVE-001 posts stale-verdict residual park" "stale-verdict:sha-A" "$(_trace_all)"
assert_match "TC-466-LIVE-001 updated park comment text mentions the transient (not permanent) nature of the wait" "transient wait, not a permanent park" "$(_trace_all)"
assert_eq   "TC-466-LIVE-001 ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_no_match "TC-466-LIVE-001 no in-progress flip" "pending-dev${US}in-progress" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-466-INV108-001: acquire_dispatch_marker held by a concurrent tick → falls to residual park (transient race, NOT budget exhaustion) ==="
# ===========================================================================
_reset
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'
_MOCK_ACQUIRE_RC=1
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-466-INV108-001 returns 0" "0" "$rc"
assert_eq   "TC-466-INV108-001 ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_no_match "TC-466-INV108-001 no marker posted (acquire lost)" "crashed-session-retry:" "$(_trace_all)"
assert_match "TC-466-INV108-001 falls through to the residual stale-verdict park" "stale-verdict:sha-A" "$(_trace_all)"
assert_no_match "TC-466-INV108-001 mark_stalled NOT fired (this is a transient race)" "^mark_stalled" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-466-INV108-002: acquire succeeds but label_swap fails → release marker, no dispatch, no phantom marker ==="
# ===========================================================================
_reset
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'
_MOCK_LABEL_SWAP_RC=1
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-466-INV108-002 returns 0" "0" "$rc"
assert_match "TC-466-INV108-002 acquired the marker" "^acquire_dispatch_marker" "$(_trace_all)"
assert_match "TC-466-INV108-002 released the marker on pre-spawn failure" "^release_dispatch_marker${US}99${US}dev-new$" "$(_trace_all)"
assert_eq   "TC-466-INV108-002 ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_no_match "TC-466-INV108-002 no crashed-session-retry marker posted (dispatch never happened)" "crashed-session-retry:" "$(_trace_all)"
assert_no_match "TC-466-INV108-002 confirm_launched NOT called" "^dispatch_marker_confirm_launched" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-466-INV108-003: dispatch rc=75 (DEFER) → handle_dispatch_deferred, no confirm ==="
# ===========================================================================
_reset
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'
_MOCK_DISPATCH_RC=75
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-466-INV108-003 returns 0" "0" "$rc"
assert_match "TC-466-INV108-003 handle_dispatch_deferred called" "^handle_dispatch_deferred${US}99${US}dev-new${US}in-progress${US}pending-dev$" "$(_trace_all)"
assert_no_match "TC-466-INV108-003 confirm_launched NOT called" "^dispatch_marker_confirm_launched" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-466-INV108-003b: dispatch hard error (rc≠0, rc≠75) → release marker, no confirm, no marker post ==="
# Distinct from INV108-002 (pre-spawn label failure): here the spawn itself
# fails, so the dispatch marker must be released and NO crashed-session-retry
# marker posted — otherwise the next tick would see a phantom budget-spent
# marker and never retry.
# ===========================================================================
_reset
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'
_MOCK_DISPATCH_RC=1
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-466-INV108-003b returns 0" "0" "$rc"
assert_match "TC-466-INV108-003b released the marker on dispatch failure" "^release_dispatch_marker${US}99${US}dev-new$" "$(_trace_all)"
assert_no_match "TC-466-INV108-003b confirm_launched NOT called" "^dispatch_marker_confirm_launched" "$(_trace_all)"
assert_no_match "TC-466-INV108-003b no crashed-session-retry marker posted (dispatch failed)" "crashed-session-retry:" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-466-INV108-004: dispatch rc=0 → confirm_launched, marker posted ==="
# ===========================================================================
_reset
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-466-INV108-004 returns 0" "0" "$rc"
assert_match "TC-466-INV108-004 confirmed the launch" "^dispatch_marker_confirm_launched${US}99${US}dev-new$" "$(_trace_all)"
assert_match "TC-466-INV108-004 posted the crashed-session-retry marker" "crashed-session-retry:sha-A" "$(_trace_all)"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
