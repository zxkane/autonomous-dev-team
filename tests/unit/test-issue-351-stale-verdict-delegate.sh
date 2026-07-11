#!/bin/bash
# test-issue-351-stale-verdict-delegate.sh — regression gate for issue #351.
#
# BUG: Step 4a.5's PR-exists short-circuit (`handle_pending_dev_pr_exists`, the
# #106 stale-verdict park) parked the same-HEAD case UNCONDITIONALLY, before
# Step 4b's completed-session routing. Because a PR always exists after a review
# FAIL, the INV-35 / INV-85 / INV-92 verdict-routing table
# (`handle_completed_session_routing`) was unreachable — the dev↔review loop
# deadlocked in `pending-dev` after ONE review round.
#
# FIX: the same-HEAD branch now extracts the dev session id, checks
# `is_session_completed`, and DELEGATES a `completed` session to
# `handle_completed_session_routing`; it parks only the residual cases (no
# session id, live/crashed session, non-claude CLI) and returns 1 for
# `prompt_too_long` so the caller falls through to the tick's INV-12 PTL branch.
#
# This suite drives the REAL `handle_completed_session_routing` (stubbing only
# the VERB / dispatch / label / mark_stalled seams — golden-trace style, like
# `test-handle-completed-routing-golden-trace.sh`) so the DELEG cases assert the
# actual routing behavior, not a mocked forward.
#
# Run: bash tests/unit/test-issue-351-stale-verdict-delegate.sh

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
export PROJECT_ID="test-351-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5
export REVIEW_RETRY_LIMIT=2

US=$'\037'

# ---------------------------------------------------------------------------
# Per-test knobs.
# ---------------------------------------------------------------------------
_MOCK_PR_INFO=''                # fetch_pr_for_issue JSON (or "" for no PR)
_MOCK_LAST_REVIEWED=''          # last_reviewed_head
_MOCK_SESSION_ID=''             # extract_dev_session_id
_MOCK_COMPLETED_RC=1            # is_session_completed rc (0=completed/PTL, 1=not)
_MOCK_TERMINAL_REASON=''        # reason out-var written when rc=0
_MOCK_VERDICT='none'            # classify_recent_review_verdict verdict
_MOCK_CAUSE=''
_MOCK_DEV_ACTIONABLE='true'     # INV-92 5th out-var
_MOCK_FLIP_COUNT=0
_MOCK_CURRENT_HEAD='sha-A'      # .headRefOid echoed by the router's fetch
_MOCK_BOT_UNFIXABLE=1
_MOCK_NOTICE_PRESENT=0          # generic dedup marker present (0/1)
_MOCK_ATTEMPT_PRESENT=0         # branch-B attempt marker present (0/1)

# ---------------------------------------------------------------------------
# Verb-layer recorder → TRACE FILE (subshell-safe: the router's dedup reads
# pipe itp_list_comments through jq|grep in a subshell, so a bash-array append
# would be lost; the file append survives).
# ---------------------------------------------------------------------------
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

# Define the mocks AFTER sourcing so they shadow the lib's real definitions
# (the lib runs only its `${VAR:?}` guards at source time — it calls none of
# these — so a single post-source block is sufficient and there is no need for
# a pre-source copy).
#
# The helper AND the router both call itp_list_comments; the returned body must
# satisfy whichever marker the current caller greps for. The stale-verdict park
# greps `stale-verdict:<head>`; the router greps INV-12-completed / no-progress /
# INV-35-fresh-dev / no-progress-substantive-attempt. Echo the tokens the
# per-test knobs enable.
_MOCK_SELF_HEAL_PRESENT=0
_MOCK_SELF_HEAL_NONSUB_PRESENT=0
itp_list_comments() {
  _rec itp_list_comments "$@"
  local body="baseline comment"
  [ "$_MOCK_NOTICE_PRESENT" = "1" ] && body+=" stale-verdict:${_MOCK_CURRENT_HEAD} INV-12-completed:${_MOCK_SESSION_ID:-sid} no-progress-substantive:${_MOCK_CURRENT_HEAD} INV-35-fresh-dev:${_MOCK_SESSION_ID:-sid}"
  [ "$_MOCK_ATTEMPT_PRESENT" = "1" ] && body+=" no-progress-substantive-attempt:${_MOCK_CURRENT_HEAD}"
  [ "$_MOCK_SELF_HEAL_PRESENT" = "1" ] && body+=" self-heal-lost-session:${_MOCK_CURRENT_HEAD}"
  [ "$_MOCK_SELF_HEAL_NONSUB_PRESENT" = "1" ] && body+=" self-heal-non-substantive:${_MOCK_CURRENT_HEAD}"
  printf '%s\n' "[{\"body\":\"${body}\"}]"
}
itp_post_comment()    { _rec itp_post_comment "$@"; }
itp_transition_state(){ _rec itp_transition_state "$@"; }
# fetch_pr_for_issue is called by BOTH the helper (fields "number,headRefOid")
# and the router (fields "number,headRefOid,body"). Echo an object carrying the
# configured current head so both `.headRefOid` reads resolve.
fetch_pr_for_issue()  { _rec fetch_pr_for_issue "$@"; printf '%s' "$_MOCK_PR_INFO"; }
# last_reviewed_head: the helper AND the router both call this single mock, so
# one knob (_MOCK_LAST_REVIEWED) drives both branch selections and they stay
# aligned by construction.
last_reviewed_head()  { printf '%s' "$_MOCK_LAST_REVIEWED"; }
extract_dev_session_id() { printf '%s' "$_MOCK_SESSION_ID"; }
# is_session_completed <issue> [reason_var] [end_ts_var] — write the reason
# out-var when rc=0 (mirrors the real signature).
is_session_completed() {
  local _rvar="${2:-}" _tvar="${3:-}"
  if [ "$_MOCK_COMPLETED_RC" = "0" ]; then
    [ -n "$_rvar" ] && printf -v "$_rvar" '%s' "$_MOCK_TERMINAL_REASON"
    [ -n "$_tvar" ] && printf -v "$_tvar" '%s' "2026-06-30T00:00:00Z"
    return 0
  fi
  return 1
}
classify_recent_review_verdict() {
  local _v="$3" _c="$4" _da="${5:-}"
  printf -v "$_v" '%s' "$_MOCK_VERDICT"; printf -v "$_c" '%s' "$_MOCK_CAUSE"
  [ -n "$_da" ] && printf -v "$_da" '%s' "$_MOCK_DEV_ACTIONABLE"; return 0
}
count_review_aware_flips() { printf '%s' "$_MOCK_FLIP_COUNT"; }
dev_report_bot_unfixable() { return "$_MOCK_BOT_UNFIXABLE"; }
post_dispatch_token()      { _rec post_dispatch_token "$@"; }
dispatch()                 { _rec dispatch "$@"; }
mark_stalled()             { _rec mark_stalled "$@"; }
# [INV-108] (#361): handle_completed_session_routing's own INV-35 fresh-dev
# branch now gates on acquire_dispatch_marker before dispatching; this suite
# exercises delegation/routing, not controller-side dedup, so always acquire.
acquire_dispatch_marker()  { return 0; }
dispatch_marker_confirm_launched() { _rec dispatch_marker_confirm_launched "$@"; }
release_dispatch_marker()          { _rec release_dispatch_marker "$@"; }
# [INV-111] (#402): the self-heal branch's liveness gate. Default: no live
# wrapper (eligible) — TC-351-DELEG-7a (pre-existing, no-session-id park)
# now exercises self-heal by default; a dedicated case flips this to
# simulate a live wrapper deferring self-heal.
_MOCK_MAY_STALL_NOW=0
may_stall_now()            { return "$_MOCK_MAY_STALL_NOW"; }
# [INV-100] (#356): handle_completed_session_routing's Branch C truncate now
# routes through _reset_session_log (real impl is backend-aware — local
# bare truncate vs remote SSM driver). Mocked here so this suite continues
# to exercise ONLY the delegation/routing logic, not truncate mechanics
# (covered by test-is-session-completed-remote.sh and
# test-handle-completed-session-routing.sh).
_reset_session_log()       { _rec _reset_session_log "$@"; return 0; }
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
  _MOCK_PR_INFO=''; _MOCK_LAST_REVIEWED=''; _MOCK_SESSION_ID=''
  _MOCK_COMPLETED_RC=1; _MOCK_TERMINAL_REASON=''
  _MOCK_VERDICT='none'; _MOCK_CAUSE=''; _MOCK_DEV_ACTIONABLE='true'
  _MOCK_FLIP_COUNT=0; _MOCK_CURRENT_HEAD='sha-A'
  _MOCK_BOT_UNFIXABLE=1; _MOCK_NOTICE_PRESENT=0; _MOCK_ATTEMPT_PRESENT=0
  _MOCK_MAY_STALL_NOW=0; _MOCK_SELF_HEAL_PRESENT=0; _MOCK_SELF_HEAL_NONSUB_PRESENT=0
}

# Configure a same-HEAD PR-exists scenario with a completed dev session.
_same_head_completed() {
  _MOCK_PR_INFO='{"number":42,"headRefOid":"sha-A"}'
  _MOCK_CURRENT_HEAD='sha-A'
  _MOCK_LAST_REVIEWED='sha-A'   # helper AND router see same == last
  _MOCK_SESSION_ID='sid351'
  _MOCK_COMPLETED_RC=0
  _MOCK_TERMINAL_REASON='completed'
}

# ===================================================================
echo "=== TC-351-DELEG-1: completed + failed-substantive same-HEAD → ONE dev-new, NO park ==="
# (AC1 regression: fails before the fix — helper parked unconditionally.)
_reset; _same_head_completed
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'
_MOCK_ATTEMPT_PRESENT=0   # first attempt this HEAD → Branch C
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-1 returns 0" "0" "$rc"
assert_match "TC-351-DELEG-1 dispatched exactly one dev-new" "^dispatch${US}dev-new${US}99$" "$(_trace_all)"
assert_eq   "TC-351-DELEG-1 dev-new dispatched exactly once" "1" "$(_trace_verbs | grep -c '^dispatch$')"
assert_match "TC-351-DELEG-1 label_swap pending-dev → in-progress" "itp_transition_state${US}99${US}pending-dev${US}in-progress" "$(_trace_all)"
assert_match "TC-351-DELEG-1 records INV-85 attempt marker" "no-progress-substantive-attempt:sha-A" "$(_trace_all)"
assert_no_match "TC-351-DELEG-1 NO stale-verdict park notice posted" "stale-verdict:" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-2: second attempt same HEAD (attempt marker present) → mark_stalled, no 2nd dev-new ==="
# (AC2: INV-85 bound — proves the fix cannot reintroduce the pre-#274 loop.)
_reset; _same_head_completed
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'
_MOCK_ATTEMPT_PRESENT=1    # prior dev-new already ran for this HEAD → Branch B
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-2 returns 0" "0" "$rc"
assert_match "TC-351-DELEG-2 mark_stalled fired" "^mark_stalled" "$(_trace_all)"
assert_eq   "TC-351-DELEG-2 ZERO dev-new dispatched" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_no_match "TC-351-DELEG-2 no in-progress flip" "pending-dev${US}in-progress" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-3: failed-non-substantive same-HEAD → pending-review (re-review), not park/dev-new ==="
_reset; _same_head_completed
_MOCK_VERDICT='failed-non-substantive'; _MOCK_CAUSE='bot-timeout'; _MOCK_FLIP_COUNT=0
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-3 returns 0" "0" "$rc"
assert_match "TC-351-DELEG-3 label_swap pending-dev → pending-review" "itp_transition_state${US}99${US}pending-dev${US}pending-review" "$(_trace_all)"
assert_eq   "TC-351-DELEG-3 ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_no_match "TC-351-DELEG-3 NO stale-verdict park" "stale-verdict:" "$(_trace_all)"
assert_no_match "TC-351-DELEG-3 NOT stalled" "^mark_stalled" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-4: failed-substantive + dev-actionable=false (INV-92) → mark_stalled, not park/dev-new ==="
_reset; _same_head_completed
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='false'
_MOCK_ATTEMPT_PRESENT=0    # first attempt — but INV-92 escalates BEFORE Branch C
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-4 returns 0" "0" "$rc"
assert_match "TC-351-DELEG-4 mark_stalled fired (INV-92)" "^mark_stalled" "$(_trace_all)"
assert_eq   "TC-351-DELEG-4 ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_match "TC-351-DELEG-4 posts non-actionable notice" "non-actionable-finding:" "$(_trace_all)"
assert_no_match "TC-351-DELEG-4 NO stale-verdict park" "stale-verdict:" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-5: prompt_too_long same-HEAD → helper returns 1 (fall through to tick PTL), NO delegation/park ==="
_reset; _same_head_completed
_MOCK_TERMINAL_REASON='prompt_too_long'
_MOCK_VERDICT='failed-substantive'   # would delegate if PTL were mis-routed
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-5 returns 1 (caller falls through to Step 4b PTL)" "1" "$rc"
assert_no_match "TC-351-DELEG-5 NO dev-new from the helper" "^dispatch${US}dev-new" "$(_trace_all)"
assert_no_match "TC-351-DELEG-5 NO stale-verdict park" "stale-verdict:" "$(_trace_all)"
assert_no_match "TC-351-DELEG-5 NO mark_stalled" "^mark_stalled" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-6: non-claude dev CLI (no result line) same-HEAD, no live wrapper → [INV-125] crashed-session-retry dev-new, NOT the park ==="
# is_session_completed returns 1 by design for non-claude CLIs (per-CLI scope).
# [INV-125] (#466): this is no longer a permanent park — a resolved session
# id whose completion is unprovable, with no live wrapper, gets the SAME
# verdict-aware recovery as the [INV-111] self-heal branch.
_reset; _same_head_completed
_MOCK_COMPLETED_RC=1        # non-claude → is_session_completed false BY DESIGN
_MOCK_SESSION_ID='sid351'   # a session id may exist, but the log has no result line
_MOCK_VERDICT='failed-substantive'
_MOCK_MAY_STALL_NOW=0       # no live wrapper — eligible for recovery
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-6 returns 0" "0" "$rc"
assert_match "TC-351-DELEG-6 dispatched exactly one crashed-session-retry dev-new" "^dispatch${US}dev-new${US}99$" "$(_trace_all)"
assert_eq   "TC-351-DELEG-6 dev-new dispatched exactly once" "1" "$(_trace_verbs | grep -c '^dispatch$')"
assert_match "TC-351-DELEG-6 label_swap pending-dev → in-progress" "itp_transition_state${US}99${US}pending-dev${US}in-progress" "$(_trace_all)"
assert_match "TC-351-DELEG-6 posts crashed-session-retry marker" "crashed-session-retry:sha-A" "$(_trace_all)"
assert_no_match "TC-351-DELEG-6 NO stale-verdict park notice posted" "stale-verdict:" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-6-LIVE: non-claude dev CLI, a dev wrapper IS alive → residual park unchanged (never race a healthy wrapper) ==="
_reset; _same_head_completed
_MOCK_COMPLETED_RC=1
_MOCK_SESSION_ID='sid351'
_MOCK_VERDICT='failed-substantive'
_MOCK_MAY_STALL_NOW=1       # a wrapper is alive — defer
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-6-LIVE returns 0 (park)" "0" "$rc"
assert_match "TC-351-DELEG-6-LIVE posts stale-verdict residual park" "stale-verdict:sha-A" "$(_trace_all)"
assert_eq   "TC-351-DELEG-6-LIVE ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_no_match "TC-351-DELEG-6-LIVE no delegation label move" "pending-dev${US}in-progress" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-7a: no session id + a dev wrapper IS alive → residual park (self-heal deferred) ==="
_reset; _same_head_completed
_MOCK_SESSION_ID=''         # cannot resolve session → park
_MOCK_COMPLETED_RC=0; _MOCK_TERMINAL_REASON='completed'
_MOCK_MAY_STALL_NOW=1       # [INV-111] a wrapper is alive — may_stall_now defers
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-7a returns 0 (park)" "0" "$rc"
assert_match "TC-351-DELEG-7a posts stale-verdict residual park" "stale-verdict:sha-A" "$(_trace_all)"
assert_eq   "TC-351-DELEG-7a ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_no_match "TC-351-DELEG-7a no self-heal marker posted" "self-heal-lost-session:" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-7a-SELFHEAL: no session id + NO live wrapper → [INV-111] self-heal dev-new, no park ==="
_reset; _same_head_completed
_MOCK_SESSION_ID=''         # cannot resolve session
_MOCK_COMPLETED_RC=0; _MOCK_TERMINAL_REASON='completed'
_MOCK_MAY_STALL_NOW=0       # [INV-111] no live wrapper — eligible to self-heal
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-7a-SELFHEAL returns 0" "0" "$rc"
assert_match "TC-351-DELEG-7a-SELFHEAL dispatched exactly one self-heal dev-new" "^dispatch${US}dev-new${US}99$" "$(_trace_all)"
assert_eq   "TC-351-DELEG-7a-SELFHEAL dev-new dispatched exactly once" "1" "$(_trace_verbs | grep -c '^dispatch$')"
assert_match "TC-351-DELEG-7a-SELFHEAL label_swap pending-dev → in-progress" "itp_transition_state${US}99${US}pending-dev${US}in-progress" "$(_trace_all)"
assert_match "TC-351-DELEG-7a-SELFHEAL posts self-heal marker" "self-heal-lost-session:sha-A" "$(_trace_all)"
assert_match "TC-351-DELEG-7a-SELFHEAL confirms the dispatch marker launched" "^dispatch_marker_confirm_launched" "$(_trace_all)"
assert_no_match "TC-351-DELEG-7a-SELFHEAL NO stale-verdict park notice posted" "stale-verdict:" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-7a-SELFHEAL-BOUND: self-heal marker already present for this HEAD → no 2nd dev-new, [INV-125] mark_stalled (NOT the park) ==="
# [INV-125] (#466) Part 2: a marker-present same-HEAD fall-through is a
# spent recovery budget, not a transient wait — it now reaches mark_stalled
# directly instead of the residual stale-verdict park (which would freeze
# count_retries forever with no way for MAX_RETRIES to ever trip).
_reset; _same_head_completed
_MOCK_SESSION_ID=''
_MOCK_COMPLETED_RC=0; _MOCK_TERMINAL_REASON='completed'
_MOCK_MAY_STALL_NOW=0
_MOCK_SELF_HEAL_PRESENT=1   # a self-heal dev-new already ran for this HEAD
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-7a-SELFHEAL-BOUND returns 0" "0" "$rc"
assert_eq   "TC-351-DELEG-7a-SELFHEAL-BOUND ZERO dev-new (bounded)" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_match "TC-351-DELEG-7a-SELFHEAL-BOUND marks stalled instead of parking" "^mark_stalled" "$(_trace_all)"
assert_no_match "TC-351-DELEG-7a-SELFHEAL-BOUND NO stale-verdict park" "stale-verdict:" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-7a-SELFHEAL-PASSED: no session id + no live wrapper + verdict=passed (race) → no-op, NO dev-new, NO park ==="
# [INV-111] (#402 review round-1 [P1] finding 2): the self-heal branch must
# classify the verdict before dispatching, mirroring
# handle_completed_session_routing's own `passed` race branch.
_reset; _same_head_completed
_MOCK_SESSION_ID=''
_MOCK_COMPLETED_RC=0; _MOCK_TERMINAL_REASON='completed'
_MOCK_MAY_STALL_NOW=0
_MOCK_VERDICT='passed'
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-7a-SELFHEAL-PASSED returns 0" "0" "$rc"
assert_eq   "TC-351-DELEG-7a-SELFHEAL-PASSED ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_no_match "TC-351-DELEG-7a-SELFHEAL-PASSED no self-heal marker posted" "self-heal-lost-session:" "$(_trace_all)"
assert_no_match "TC-351-DELEG-7a-SELFHEAL-PASSED NO stale-verdict park (race, Step 0 reconciles)" "stale-verdict:" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-7a-SELFHEAL-NONSUB: no session id + no live wrapper + verdict=failed-non-substantive → pending-review, NO dev-new ==="
_reset; _same_head_completed
_MOCK_SESSION_ID=''
_MOCK_COMPLETED_RC=0; _MOCK_TERMINAL_REASON='completed'
_MOCK_MAY_STALL_NOW=0
_MOCK_VERDICT='failed-non-substantive'; _MOCK_CAUSE='bot-timeout'
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-7a-SELFHEAL-NONSUB returns 0" "0" "$rc"
assert_match "TC-351-DELEG-7a-SELFHEAL-NONSUB label_swap pending-dev → pending-review" "itp_transition_state${US}99${US}pending-dev${US}pending-review" "$(_trace_all)"
assert_eq   "TC-351-DELEG-7a-SELFHEAL-NONSUB ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_match "TC-351-DELEG-7a-SELFHEAL-NONSUB posts self-heal-non-substantive marker" "self-heal-non-substantive:sha-A" "$(_trace_all)"
assert_no_match "TC-351-DELEG-7a-SELFHEAL-NONSUB NO stale-verdict park" "stale-verdict:" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-7a-SELFHEAL-NONSUB-BOUND: second same-HEAD non-substantive verdict (marker present) → [INV-125] mark_stalled, NOT a second re-review flip, NOT the park ==="
# [INV-125] (#466) Part 2: same reasoning as SELFHEAL-BOUND above.
_reset; _same_head_completed
_MOCK_SESSION_ID=''
_MOCK_COMPLETED_RC=0; _MOCK_TERMINAL_REASON='completed'
_MOCK_MAY_STALL_NOW=0
_MOCK_VERDICT='failed-non-substantive'; _MOCK_CAUSE='bot-timeout'
_MOCK_SELF_HEAL_NONSUB_PRESENT=1
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-7a-SELFHEAL-NONSUB-BOUND returns 0" "0" "$rc"
assert_eq   "TC-351-DELEG-7a-SELFHEAL-NONSUB-BOUND ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_no_match "TC-351-DELEG-7a-SELFHEAL-NONSUB-BOUND no second pending-review flip" "pending-dev${US}pending-review" "$(_trace_all)"
assert_match "TC-351-DELEG-7a-SELFHEAL-NONSUB-BOUND marks stalled instead of parking" "^mark_stalled" "$(_trace_all)"
assert_no_match "TC-351-DELEG-7a-SELFHEAL-NONSUB-BOUND NO stale-verdict park" "stale-verdict:" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-7a-SELFHEAL-NONACTIONABLE: no session id + no live wrapper + dev-actionable=false ([INV-92]) → mark_stalled, NO dev-new ==="
_reset; _same_head_completed
_MOCK_SESSION_ID=''
_MOCK_COMPLETED_RC=0; _MOCK_TERMINAL_REASON='completed'
_MOCK_MAY_STALL_NOW=0
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='false'
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-7a-SELFHEAL-NONACTIONABLE returns 0" "0" "$rc"
assert_match "TC-351-DELEG-7a-SELFHEAL-NONACTIONABLE mark_stalled fired" "^mark_stalled" "$(_trace_all)"
assert_eq   "TC-351-DELEG-7a-SELFHEAL-NONACTIONABLE ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_match "TC-351-DELEG-7a-SELFHEAL-NONACTIONABLE posts self-heal-non-actionable marker" "self-heal-non-actionable:sha-A" "$(_trace_all)"
assert_no_match "TC-351-DELEG-7a-SELFHEAL-NONACTIONABLE NO stale-verdict park" "stale-verdict:" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-7a-SELFHEAL-SUBSTANTIVE: no session id + no live wrapper + verdict=failed-substantive (dev-actionable=true, explicit) → self-heal dev-new (unchanged) ==="
_reset; _same_head_completed
_MOCK_SESSION_ID=''
_MOCK_COMPLETED_RC=0; _MOCK_TERMINAL_REASON='completed'
_MOCK_MAY_STALL_NOW=0
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-7a-SELFHEAL-SUBSTANTIVE returns 0" "0" "$rc"
assert_match "TC-351-DELEG-7a-SELFHEAL-SUBSTANTIVE dispatched exactly one self-heal dev-new" "^dispatch${US}dev-new${US}99$" "$(_trace_all)"
assert_match "TC-351-DELEG-7a-SELFHEAL-SUBSTANTIVE posts self-heal marker" "self-heal-lost-session:sha-A" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-7b: session id present but NOT completed, a dev wrapper IS alive → residual park (never race a healthy wrapper) ==="
_reset; _same_head_completed
_MOCK_SESSION_ID='sid351'
_MOCK_COMPLETED_RC=1        # is_session_completed false → completion unprovable
_MOCK_MAY_STALL_NOW=1       # a wrapper is alive — defer
_MOCK_VERDICT='failed-substantive'
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-7b returns 0 (park)" "0" "$rc"
assert_match "TC-351-DELEG-7b posts stale-verdict residual park" "stale-verdict:sha-A" "$(_trace_all)"
assert_eq   "TC-351-DELEG-7b ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"

# ===================================================================
echo
echo "=== TC-351-DELEG-7b-RECOVER: session id present but NOT completed, NO live wrapper → [INV-125] crashed-session-retry dev-new, NOT the park ==="
_reset; _same_head_completed
_MOCK_SESSION_ID='sid351'
_MOCK_COMPLETED_RC=1        # is_session_completed false → completion unprovable (e.g. api_error)
_MOCK_MAY_STALL_NOW=0       # no live wrapper — eligible for recovery
_MOCK_VERDICT='failed-substantive'
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-7b-RECOVER returns 0" "0" "$rc"
assert_match "TC-351-DELEG-7b-RECOVER dispatched exactly one crashed-session-retry dev-new" "^dispatch${US}dev-new${US}99$" "$(_trace_all)"
assert_match "TC-351-DELEG-7b-RECOVER posts crashed-session-retry marker" "crashed-session-retry:sha-A" "$(_trace_all)"
assert_no_match "TC-351-DELEG-7b-RECOVER NO stale-verdict park" "stale-verdict:" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-7c: completed but verdict classification empty (none) → operator handoff, fail-closed (no dev-new) ==="
_reset; _same_head_completed
_MOCK_SESSION_ID='sid351'
_MOCK_COMPLETED_RC=0; _MOCK_TERMINAL_REASON='completed'
_MOCK_VERDICT='none'        # classifier could not bind a verdict
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-7c returns 0" "0" "$rc"
assert_match "TC-351-DELEG-7c operator handoff (INV-12-completed) via router" "INV-12-completed:" "$(_trace_all)"
assert_eq   "TC-351-DELEG-7c ZERO dev-new (fail-closed)" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_no_match "TC-351-DELEG-7c NO stale-verdict park (router owns the none arm)" "stale-verdict:" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-8: HEAD advanced → unchanged Bug 3 flip to pending-review ==="
_reset
_MOCK_PR_INFO='{"number":42,"headRefOid":"sha-B"}'
_MOCK_CURRENT_HEAD='sha-B'
_MOCK_LAST_REVIEWED='sha-A'   # HEAD advanced since last review
_MOCK_SESSION_ID='sid351'; _MOCK_COMPLETED_RC=0; _MOCK_TERMINAL_REASON='completed'
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-8 returns 0" "0" "$rc"
assert_match "TC-351-DELEG-8 Bug 3 flip pending-dev → pending-review" "itp_transition_state${US}99${US}pending-dev${US}pending-review" "$(_trace_all)"
assert_eq   "TC-351-DELEG-8 ZERO dev-new" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_no_match "TC-351-DELEG-8 NO stale-verdict park" "stale-verdict:" "$(_trace_all)"

# ===================================================================
echo
echo "=== TC-351-DELEG-9: no PR → returns 1 (caller falls through), unchanged ==="
_reset
_MOCK_PR_INFO=''
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-9 returns 1" "1" "$rc"
assert_eq   "TC-351-DELEG-9 no verbs recorded past fetch" "fetch_pr_for_issue" "$(_trace_verbs | paste -sd, -)"

# ===================================================================
echo
echo "=== TC-351-DELEG-REMOTE-1: same-HEAD completed delegation under EXECUTION_BACKEND=remote-aws-ssm ==="
# [INV-100] (#356): handle_pending_dev_pr_exists's delegation logic is
# backend-agnostic — it only consumes is_session_completed's return value
# (mocked in this suite via _MOCK_COMPLETED_RC), never the log file
# directly. This proves the #351 delegation shape is unaffected by
# EXECUTION_BACKEND: is_session_completed's own backend-blindness (the #356
# bug) is covered in isolation by test-is-session-completed-remote.sh; this
# test is the golden-trace proof that ONCE is_session_completed correctly
# returns "completed" for a remote-SSM project, Step 4a.5 delegates exactly
# like the local case.
_reset; _same_head_completed
_MOCK_VERDICT='failed-substantive'; _MOCK_DEV_ACTIONABLE='true'
_MOCK_ATTEMPT_PRESENT=0
EXECUTION_BACKEND=remote-aws-ssm SSM_REMOTE_PROJECT_ID='remote-proj' handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-351-DELEG-REMOTE-1 returns 0" "0" "$rc"
assert_match "TC-351-DELEG-REMOTE-1 dispatched exactly one dev-new" "^dispatch${US}dev-new${US}99$" "$(_trace_all)"
assert_no_match "TC-351-DELEG-REMOTE-1 NO stale-verdict park notice posted" "stale-verdict:" "$(_trace_all)"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
