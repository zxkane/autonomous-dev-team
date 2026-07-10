#!/bin/bash
# test-issue-461-completed-none-bounded-retry.sh — issue #461.
#
# `handle_completed_session_routing`'s `none)` case was a permanent, unbounded
# silent park: unlike every sibling verdict branch it never retried and never
# escalated to `stalled`. This fix wraps the `none)` case in an if/else keyed
# on whether a PR exists for the issue:
#   - PR exists (or the lookup fails transiently)   -> unchanged INV-12-completed
#                                                       operator handoff.
#   - No PR exists                                   -> mirror failed-substantive's
#                                                       Branch C exactly (acquire
#                                                       marker, INV-12-no-pr-fresh-dev
#                                                       notice, truncate log, label
#                                                       swap, dispatch dev-new,
#                                                       confirm launched) — bounded
#                                                       by the existing MAX_RETRIES
#                                                       counter via the new
#                                                       count_no_pr_attempts() companion
#                                                       fix.
#
# Golden-trace harness mirrors test-handle-completed-routing-golden-trace.sh:
# stub the ITP/CHP VERB layer (not raw `gh`), record every verb call to a trace
# file, assert exact verb-order + argv.
#
# Run: bash tests/unit/test-issue-461-completed-none-bounded-retry.sh

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
export PROJECT_ID="test-461-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5

US=$'\037'

# ---------------------------------------------------------------------------
# Routing-side mocks. Configured per-test.
# ---------------------------------------------------------------------------
_MOCK_VERDICT="none"
_MOCK_PR_EXISTS=0        # 0 = no PR (fetch_pr_for_issue echoes empty), 1 = PR exists
_MOCK_PR_LOOKUP_RC=0     # non-zero => resolve_pr_for_issue-style transport failure
_MOCK_NOTICE_PRESENT=0   # generic dedup marker presence (both INV-12-completed and INV-12-no-pr-fresh-dev)
_MOCK_ACQUIRE_RC=0       # acquire_dispatch_marker return code
_MOCK_RESET_LOG_RC=0     # _reset_session_log return code
_MOCK_LABEL_SWAP_RC=0    # label_swap return code
_MOCK_DISPATCH_RC=0      # dispatch() return code
_MOCK_SID="sid"

_TRACE_FILE=""
_rec() {
  local v="$1"; shift; local a="$v"; local x
  for x in "$@"; do a+="${US}${x}"; done
  a="${a//$'\n'/\\n}"
  printf '%s\n' "$a" >> "$_TRACE_FILE"
}
_trace_reset() { : > "$_TRACE_FILE"; }

itp_list_comments() {
  _rec itp_list_comments "$@"
  local body="baseline comment"
  [ "$_MOCK_NOTICE_PRESENT" = "1" ] && body+=" INV-12-completed:${_MOCK_SID} INV-12-no-pr-fresh-dev:${_MOCK_SID}"
  printf '%s\n' "[{\"body\":\"${body}\"}]"
}
itp_post_comment()     { _rec itp_post_comment "$@"; }
itp_transition_state() { _rec itp_transition_state "$@"; }
fetch_pr_for_issue() {
  _rec fetch_pr_for_issue "$@"
  [ "$_MOCK_PR_LOOKUP_RC" -ne 0 ] && return "$_MOCK_PR_LOOKUP_RC"
  if [ "$_MOCK_PR_EXISTS" = "1" ]; then
    printf '%s\n' '{"number":42,"headRefOid":"deadbeef"}'
  else
    printf ''
  fi
  return 0
}
classify_recent_review_verdict() {
  local _i="$1" _t="$2" _v="$3" _c="$4"
  printf -v "$_v" '%s' "$_MOCK_VERDICT"
  printf -v "$_c" '%s' ""
  return 0
}
acquire_dispatch_marker() { _rec acquire_dispatch_marker "$@"; return "$_MOCK_ACQUIRE_RC"; }
release_dispatch_marker() { _rec release_dispatch_marker "$@"; }
dispatch_marker_confirm_launched() { _rec dispatch_marker_confirm_launched "$@"; }
_reset_session_log() { _rec _reset_session_log "$@"; return "$_MOCK_RESET_LOG_RC"; }
label_swap() { _rec label_swap "$@"; return "$_MOCK_LABEL_SWAP_RC"; }
post_dispatch_token() { _rec post_dispatch_token "$@"; }
dispatch() { _rec dispatch "$@"; return "$_MOCK_DISPATCH_RC"; }
handle_dispatch_deferred() { _rec handle_dispatch_deferred "$@"; }
mark_stalled() { _rec mark_stalled "$@"; }
log() { :; }

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT
_TRACE_FILE="$TMPDIR_T/trace"; : > "$_TRACE_FILE"
export _TRACE_FILE US _MOCK_VERDICT _MOCK_PR_EXISTS _MOCK_PR_LOOKUP_RC _MOCK_NOTICE_PRESENT \
       _MOCK_ACQUIRE_RC _MOCK_RESET_LOG_RC _MOCK_LABEL_SWAP_RC _MOCK_DISPATCH_RC _MOCK_SID

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

# Re-define AFTER sourcing so our mocks win over the lib's real definitions.
itp_list_comments() {
  _rec itp_list_comments "$@"
  local body="baseline comment"
  [ "$_MOCK_NOTICE_PRESENT" = "1" ] && body+=" INV-12-completed:${_MOCK_SID} INV-12-no-pr-fresh-dev:${_MOCK_SID}"
  printf '%s\n' "[{\"body\":\"${body}\"}]"
}
itp_post_comment()     { _rec itp_post_comment "$@"; }
itp_transition_state() { _rec itp_transition_state "$@"; }
fetch_pr_for_issue() {
  _rec fetch_pr_for_issue "$@"
  [ "$_MOCK_PR_LOOKUP_RC" -ne 0 ] && return "$_MOCK_PR_LOOKUP_RC"
  if [ "$_MOCK_PR_EXISTS" = "1" ]; then
    printf '%s\n' '{"number":42,"headRefOid":"deadbeef"}'
  else
    printf ''
  fi
  return 0
}
classify_recent_review_verdict() {
  local _i="$1" _t="$2" _v="$3" _c="$4"
  printf -v "$_v" '%s' "$_MOCK_VERDICT"; printf -v "$_c" '%s' ""; return 0
}
acquire_dispatch_marker() { _rec acquire_dispatch_marker "$@"; return "$_MOCK_ACQUIRE_RC"; }
release_dispatch_marker() { _rec release_dispatch_marker "$@"; }
dispatch_marker_confirm_launched() { _rec dispatch_marker_confirm_launched "$@"; }
_reset_session_log() { _rec _reset_session_log "$@"; return "$_MOCK_RESET_LOG_RC"; }
label_swap() { _rec label_swap "$@"; return "$_MOCK_LABEL_SWAP_RC"; }
post_dispatch_token() { _rec post_dispatch_token "$@"; }
dispatch() { _rec dispatch "$@"; return "$_MOCK_DISPATCH_RC"; }
handle_dispatch_deferred() { _rec handle_dispatch_deferred "$@"; }
mark_stalled() { _rec mark_stalled "$@"; }
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
_trace_verbs() { local e; while IFS= read -r e; do [ -n "$e" ] && printf '%s\n' "${e%%${US}*}"; done < "$_TRACE_FILE"; }
_trace_nth()   { local want="$1" n="$2" e c=0; while IFS= read -r e; do [ "${e%%${US}*}" = "$want" ] && { c=$((c+1)); [ "$c" = "$n" ] && { printf '%s' "$e"; return; }; }; done < "$_TRACE_FILE"; }

_reset_mocks() {
  _trace_reset
  _MOCK_VERDICT="none"; _MOCK_PR_EXISTS=0; _MOCK_PR_LOOKUP_RC=0; _MOCK_NOTICE_PRESENT=0
  _MOCK_ACQUIRE_RC=0; _MOCK_RESET_LOG_RC=0; _MOCK_LABEL_SWAP_RC=0; _MOCK_DISPATCH_RC=0
}

# ===================================================================
echo "=== TC-461-NONE-001..002: no-PR happy path + idempotent repeat ==="

# TC-461-NONE-001 — verdict=none, no PR, notice absent: full Branch-C-mirror
# dispatch sequence.
_reset_mocks; _MOCK_SID="sidA"
handle_completed_session_routing 601 sidA "2026-07-10T00:00:00Z" >/dev/null 2>&1
assert_eq "TC-461-NONE-001 verb order = fetch,acquire,list,post,reset_log,label_swap,token,dispatch,confirm" \
  "fetch_pr_for_issue,acquire_dispatch_marker,itp_list_comments,itp_post_comment,_reset_session_log,label_swap,post_dispatch_token,dispatch,dispatch_marker_confirm_launched" \
  "$(_trace_verbs | paste -sd, -)"
assert_match "TC-461-NONE-001 notice carries INV-12-no-pr-fresh-dev marker" "INV-12-no-pr-fresh-dev:sidA" "$(_trace_nth itp_post_comment 1)"
assert_eq "TC-461-NONE-001 label_swap argv = issue,pending-dev,in-progress" "label_swap${US}601${US}pending-dev${US}in-progress" "$(_trace_nth label_swap 1)"
assert_eq "TC-461-NONE-001 dispatch argv = dev-new,issue" "dispatch${US}dev-new${US}601" "$(_trace_nth dispatch 1)"
assert_eq "TC-461-NONE-001 NO INV-12-completed post" "" "$(_trace_verbs | grep -c 'itp_transition_state' | grep -v '^0$')"

# TC-461-NONE-002 — same but the INV-12-no-pr-fresh-dev marker is already
# present (repeat tick, same session id): dispatch mechanics still proceed
# (Branch C's own dedup is notice-text-only, not a full skip).
_reset_mocks; _MOCK_SID="sidA"; _MOCK_NOTICE_PRESENT=1
handle_completed_session_routing 602 sidA "2026-07-10T00:00:00Z" >/dev/null 2>&1
assert_eq "TC-461-NONE-002 marker-present repeat still dispatches (no duplicate notice post, mechanics unchanged)" \
  "fetch_pr_for_issue,acquire_dispatch_marker,itp_list_comments,_reset_session_log,label_swap,post_dispatch_token,dispatch,dispatch_marker_confirm_launched" \
  "$(_trace_verbs | paste -sd, -)"

# ===================================================================
echo
echo "=== TC-461-NONE-003..005: PR-exists / transport-failure regression pins ==="

# TC-461-NONE-003 — verdict=none, PR EXISTS: unchanged INV-12-completed handoff.
_reset_mocks; _MOCK_PR_EXISTS=1; _MOCK_SID="sidB"
handle_completed_session_routing 603 sidB "2026-07-10T00:00:00Z" >/dev/null 2>&1
assert_eq "TC-461-NONE-003 PR-exists verb order = fetch,list,post (unchanged INV-12-completed)" \
  "fetch_pr_for_issue,itp_list_comments,itp_post_comment" "$(_trace_verbs | paste -sd, -)"
assert_match "TC-461-NONE-003 post body carries INV-12-completed marker" "INV-12-completed:sidB" "$(_trace_nth itp_post_comment 1)"

# TC-461-NONE-004 — verdict=none, PR EXISTS, notice already posted: no re-post.
_reset_mocks; _MOCK_PR_EXISTS=1; _MOCK_SID="sidB"; _MOCK_NOTICE_PRESENT=1
handle_completed_session_routing 604 sidB "2026-07-10T00:00:00Z" >/dev/null 2>&1
assert_eq "TC-461-NONE-004 PR-exists + notice-present = list only, no post, no dispatch" \
  "fetch_pr_for_issue,itp_list_comments" "$(_trace_verbs | paste -sd, -)"

# TC-461-NONE-005 — fetch_pr_for_issue fails (transport error, nonzero rc):
# fail closed to PR-exists handoff, NEVER the no-PR dev-new branch.
_reset_mocks; _MOCK_PR_LOOKUP_RC=1; _MOCK_SID="sidC"
handle_completed_session_routing 605 sidC "2026-07-10T00:00:00Z" >/dev/null 2>&1
assert_eq "TC-461-NONE-005 PR-lookup transport failure fails CLOSED to INV-12-completed handoff" \
  "fetch_pr_for_issue,itp_list_comments,itp_post_comment" "$(_trace_verbs | paste -sd, -)"
assert_match "TC-461-NONE-005 handoff notice posted on lookup failure" "INV-12-completed:sidC" "$(_trace_nth itp_post_comment 1)"

# ===================================================================
echo
echo "=== TC-461-NONE-006..012: no-PR branch error/rc handling (mirrors Branch C) ==="

# TC-461-NONE-006 — acquire_dispatch_marker fails (marker held concurrently):
# skip cleanly, no notice, no truncate, no label swap, no dispatch.
_reset_mocks; _MOCK_ACQUIRE_RC=1; _MOCK_SID="sidD"
handle_completed_session_routing 606 sidD "2026-07-10T00:00:00Z" >/dev/null 2>&1
assert_eq "TC-461-NONE-006 losing acquire => fetch,acquire only" "fetch_pr_for_issue,acquire_dispatch_marker" "$(_trace_verbs | paste -sd, -)"

# TC-461-NONE-007 — _reset_session_log fails: operator comment + release + no dispatch.
_reset_mocks; _MOCK_RESET_LOG_RC=1; _MOCK_SID="sidE"
handle_completed_session_routing 607 sidE "2026-07-10T00:00:00Z" >/dev/null 2>&1
assert_eq "TC-461-NONE-007 reset-log failure => fetch,acquire,list,post,reset_log,post,release (no dispatch)" \
  "fetch_pr_for_issue,acquire_dispatch_marker,itp_list_comments,itp_post_comment,_reset_session_log,itp_post_comment,release_dispatch_marker" \
  "$(_trace_verbs | paste -sd, -)"
assert_eq "TC-461-NONE-007 release_dispatch_marker argv = issue,dev-new" "release_dispatch_marker${US}607${US}dev-new" "$(_trace_nth release_dispatch_marker 1)"

# TC-461-NONE-008 — label_swap fails (errexit-suppressed context): release + no dispatch.
_reset_mocks; _MOCK_LABEL_SWAP_RC=1; _MOCK_SID="sidF"
handle_completed_session_routing 608 sidF "2026-07-10T00:00:00Z" >/dev/null 2>&1
assert_eq "TC-461-NONE-008 label_swap failure => ...,label_swap,release (no post_dispatch_token, no dispatch)" \
  "fetch_pr_for_issue,acquire_dispatch_marker,itp_list_comments,itp_post_comment,_reset_session_log,label_swap,release_dispatch_marker" \
  "$(_trace_verbs | paste -sd, -)"

# TC-461-NONE-009 — dispatch rc=75 (DEFER): handle_dispatch_deferred, no confirm.
_reset_mocks; _MOCK_DISPATCH_RC=75; _MOCK_SID="sidG"
handle_completed_session_routing 609 sidG "2026-07-10T00:00:00Z" >/dev/null 2>&1
assert_eq "TC-461-NONE-009 dispatch rc=75 => ...,dispatch,handle_dispatch_deferred (no confirm_launched)" \
  "fetch_pr_for_issue,acquire_dispatch_marker,itp_list_comments,itp_post_comment,_reset_session_log,label_swap,post_dispatch_token,dispatch,handle_dispatch_deferred" \
  "$(_trace_verbs | paste -sd, -)"
assert_eq "TC-461-NONE-009 handle_dispatch_deferred argv = issue,dev-new,in-progress,pending-dev" \
  "handle_dispatch_deferred${US}609${US}dev-new${US}in-progress${US}pending-dev" "$(_trace_nth handle_dispatch_deferred 1)"

# TC-461-NONE-010 — dispatch rc=1 (generic failure): release + no confirm.
_reset_mocks; _MOCK_DISPATCH_RC=1; _MOCK_SID="sidH"
handle_completed_session_routing 610 sidH "2026-07-10T00:00:00Z" >/dev/null 2>&1
assert_eq "TC-461-NONE-010 dispatch rc=1 => ...,dispatch,release (no confirm_launched)" \
  "fetch_pr_for_issue,acquire_dispatch_marker,itp_list_comments,itp_post_comment,_reset_session_log,label_swap,post_dispatch_token,dispatch,release_dispatch_marker" \
  "$(_trace_verbs | paste -sd, -)"

# TC-461-NONE-011/012 — dispatch rc=0: confirm_launched, and NO per-HEAD
# attempt marker is ever posted (only ONE itp_post_comment call total).
_reset_mocks; _MOCK_SID="sidI"
handle_completed_session_routing 611 sidI "2026-07-10T00:00:00Z" >/dev/null 2>&1
post_count=$(_trace_verbs | grep -c '^itp_post_comment$')
assert_eq "TC-461-NONE-011 dispatch rc=0 => dispatch_marker_confirm_launched called" \
  "fetch_pr_for_issue,acquire_dispatch_marker,itp_list_comments,itp_post_comment,_reset_session_log,label_swap,post_dispatch_token,dispatch,dispatch_marker_confirm_launched" \
  "$(_trace_verbs | paste -sd, -)"
assert_eq "TC-461-NONE-012 exactly ONE itp_post_comment (no per-HEAD attempt marker, unlike Branch C)" "1" "$post_count"

# TC-461-GOLDEN-002 — a deferred (rc=75) no-PR retry does NOT escape counting:
# re-run the TC-461-NONE-009 scenario (dispatch rc=75) and assert
# _reset_session_log fires BEFORE the dispatch-rc branch — so even a deferred
# dispatch leaves the log truncated, meaning the next tick sees a clean log
# rather than re-detecting the same stale `completed` line and looping the
# no-PR branch without a fresh WARNING (the sub-loop this fix exists to close).
_reset_mocks; _MOCK_DISPATCH_RC=75; _MOCK_SID="sidJ"
handle_completed_session_routing 612 sidJ "2026-07-10T00:00:00Z" >/dev/null 2>&1
assert_eq "TC-461-GOLDEN-002 deferred dispatch still truncates the log before the rc branch (verb order pin)" \
  "fetch_pr_for_issue,acquire_dispatch_marker,itp_list_comments,itp_post_comment,_reset_session_log,label_swap,post_dispatch_token,dispatch,handle_dispatch_deferred" \
  "$(_trace_verbs | paste -sd, -)"

# ===================================================================
echo
echo "=== TC-461-SELFHEAL-001: INV-111 self-heal disjoint precondition (regression pin) ==="

# The self-heal branch lives in handle_pending_dev_pr_exists and requires a PR
# to exist (same-HEAD comparison) — structurally disjoint from this fix's
# no-PR branch. Pin that the two marker vocabularies never collide by source
# inspection (both live in lib-dispatch.sh; grep for byte-distinct tokens).
selfheal_marker=$(grep -c 'self-heal-lost-session:' "$LIB")
newbranch_marker=$(grep -c 'INV-12-no-pr-fresh-dev:' "$LIB")
if [ "$selfheal_marker" -ge 1 ] && [ "$newbranch_marker" -ge 1 ]; then
  echo -e "  ${GREEN}PASS${NC}: TC-461-SELFHEAL-001 self-heal-lost-session and INV-12-no-pr-fresh-dev markers are distinct tokens, both present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-461-SELFHEAL-001 expected both marker tokens present in $LIB"
  FAIL=$((FAIL + 1))
fi

# ===================================================================
echo
echo "=== TC-461-COUNT-001..005: count_no_pr_attempts + count_retries + mark_stalled text ==="

# Use the REAL count_no_pr_attempts / count_retries / mark_stalled (not the
# trace-recording stubs above) — re-source in a clean subshell-free context
# by unsetting our overrides for this section via direct function calls
# against itp_list_comments configured with fixture bodies.

_MOCK_COMMENTS_FIXTURE=""
itp_list_comments() {
  printf '%s\n' "$_MOCK_COMMENTS_FIXTURE"
}

# TC-461-COUNT-001 — one no-PR WARNING comment, no stall cutoff => count 1.
_MOCK_COMMENTS_FIXTURE='[{"createdAt":"2026-01-01T00:00:00Z","body":"Agent exited successfully but no PR was created. Moving to pending-dev for retry."}]'
assert_eq "TC-461-COUNT-001 one no-PR WARNING comment => count_no_pr_attempts=1" "1" "$(count_no_pr_attempts 99)"

# TC-461-COUNT-002 — the co-posted exit-0 Session Report comment must NOT
# also match count_no_pr_attempts (distinct text, no double counting).
_MOCK_COMMENTS_FIXTURE='[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Agent Session Report (Dev)\nExit code: 0"},
  {"createdAt":"2026-01-01T00:00:01Z","body":"Agent exited successfully but no PR was created. Moving to pending-dev for retry."}
]'
assert_eq "TC-461-COUNT-002 Session-Report exit-0 comment does not double-count" "1" "$(count_no_pr_attempts 99)"

# TC-461-COUNT-003 — cutoff rule: only post-stall WARNING counts.
_MOCK_COMMENTS_FIXTURE='[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Agent exited successfully but no PR was created. Moving to pending-dev for retry."},
  {"createdAt":"2026-01-02T00:00:00Z","body":"Marking as stalled"},
  {"createdAt":"2026-01-03T00:00:00Z","body":"Agent exited successfully but no PR was created. Moving to pending-dev for retry."}
]'
assert_eq "TC-461-COUNT-003 stalled-cutoff applies to count_no_pr_attempts (INV-05)" "1" "$(count_no_pr_attempts 99)"

# TC-461-COUNT-004 — count_retries sums agent_failures + no_pr_attempts unconditionally.
_MOCK_COMMENTS_FIXTURE='[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Agent Session Report (Dev)\nExit code: 1"},
  {"createdAt":"2026-01-02T00:00:00Z","body":"Agent exited successfully but no PR was created. Moving to pending-dev for retry."}
]'
assert_eq "TC-461-COUNT-004 count_retries sums agent_failures + count_no_pr_attempts" "2" "$(count_retries 99)"

# TC-461-COUNT-005 — mark_stalled's comment text includes the new term.
# Unset every golden-trace-harness STUB that shadows a real lib-dispatch.sh
# function this section needs unstubbed, then re-source the lib so the REAL
# mark_stalled (and its callees: may_stall_now, pid_alive, get_pid,
# _dispatch_marker_recent) are back in scope.
unset -f mark_stalled may_stall_now pid_alive get_pid _dispatch_marker_recent label_swap itp_post_comment itp_list_comments 2>/dev/null
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e
pid_alive() { return 1; }
get_pid() { printf ''; }
_dispatch_marker_recent() { return 1; }
label_swap() { :; }
itp_post_comment() { printf '%s' "$1" > "$TMPDIR_T/mark_stalled_body"; shift; printf '%s' "$1" >> "$TMPDIR_T/mark_stalled_body"; }
itp_list_comments() { printf '%s\n' "$_MOCK_COMMENTS_FIXTURE"; }
_MOCK_COMMENTS_FIXTURE='[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Agent exited successfully but no PR was created. Moving to pending-dev for retry."}
]'
mark_stalled 99 >/dev/null 2>&1
body=$(cat "$TMPDIR_T/mark_stalled_body" 2>/dev/null || true)
assert_match "TC-461-COUNT-005 mark_stalled comment text includes the no-PR-attempts term" "no.PR|no-PR" "$body"

# ===================================================================
echo
echo "=== TC-461-GOLDEN-001: replay the #456-shaped sequence, MAX_RETRIES=3 ==="

# With MAX_RETRIES=3: the ORIGINAL pre-branch WARNING (attempt 1) plus two
# branch-dispatched WARNINGs (attempts 2, 3) bring count_retries() to exactly
# MAX_RETRIES — the dispatcher-tick.sh Step 4 pre-flight gate
# (count_retries() >= MAX_RETRIES) would stall BEFORE a 3rd branch dispatch.
# Pin the exact arithmetic: 2 WARNINGs → still below cap (branch dispatches
# again); 3 WARNINGs → at cap (branch never reached again). (TC-461-GOLDEN-002,
# the deferred-retry-does-not-escape-counting case, is pinned above via
# TC-461-NONE-009's own verb-order assertion.)
_MOCK_COMMENTS_FIXTURE='[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Agent exited successfully but no PR was created. Moving to pending-dev for retry."},
  {"createdAt":"2026-01-02T00:00:00Z","body":"Agent exited successfully but no PR was created. Moving to pending-dev for retry."}
]'
assert_eq "TC-461-GOLDEN-001 2 WARNINGs (attempts 1-2) → count_retries=2, below MAX_RETRIES=3" "2" "$(count_retries 456)"
_MOCK_COMMENTS_FIXTURE='[
  {"createdAt":"2026-01-01T00:00:00Z","body":"Agent exited successfully but no PR was created. Moving to pending-dev for retry."},
  {"createdAt":"2026-01-02T00:00:00Z","body":"Agent exited successfully but no PR was created. Moving to pending-dev for retry."},
  {"createdAt":"2026-01-03T00:00:00Z","body":"Agent exited successfully but no PR was created. Moving to pending-dev for retry."}
]'
assert_eq "TC-461-GOLDEN-001 3 WARNINGs (attempts 1-3) → count_retries=3, AT MAX_RETRIES=3 (stall, never a 3rd branch dispatch)" "3" "$(count_retries 456)"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
