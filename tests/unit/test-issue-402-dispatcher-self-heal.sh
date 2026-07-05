#!/bin/bash
# test-issue-402-dispatcher-self-heal.sh — regression gate for the [INV-111]
# self-heal extension to `handle_pending_dev_pr_exists`'s same-HEAD residual
# park (issue #402, layer 3).
#
# The core routing matrix (no-session-id + live-wrapper → defer;
# no-session-id + no-live-wrapper → self-heal dev-new; already-self-healed
# HEAD → bounded, falls back to park) is covered by
# test-issue-351-stale-verdict-delegate.sh (the same golden-trace harness
# that already drives handle_pending_dev_pr_exists for the #351 delegation).
# This file covers the two [INV-108] concurrency/failure edges that suite
# does not: a concurrent tick holding the dispatch marker, and a pre-spawn
# step failing after a successful acquire.
#
# Run: bash tests/unit/test-issue-402-dispatcher-self-heal.sh

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
export PROJECT_ID="test-402-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5

US=$'\037'

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT
_TRACE_FILE="$TMPDIR_T/trace"; : > "$_TRACE_FILE"
_rec() {
  local v="$1"; shift; local a="$v"; local x
  for x in "$@"; do a+="${US}${x}"; done
  a="${a//$'\n'/\\n}"
  printf '%s\n' "$a" >> "$_TRACE_FILE"
}
_trace_reset() { : > "$_TRACE_FILE"; }
_trace_all()   { cat "$_TRACE_FILE"; }
_trace_verbs() { local e; while IFS= read -r e; do [ -n "$e" ] && printf '%s\n' "${e%%${US}*}"; done < "$_TRACE_FILE"; }

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

# ---------------------------------------------------------------------------
# Mocks — same-HEAD, no session id (the self-heal precondition), no live
# wrapper by default. Each test overrides only what it needs.
# ---------------------------------------------------------------------------
_MOCK_ACQUIRE_RC=0
_MOCK_LABEL_SWAP_RC=0

itp_list_comments()   { _rec itp_list_comments "$@"; printf '%s\n' '[{"body":"baseline comment"}]'; }
itp_post_comment()    { _rec itp_post_comment "$@"; }
itp_transition_state(){ _rec itp_transition_state "$@"; }
fetch_pr_for_issue()   { _rec fetch_pr_for_issue "$@"; printf '%s' '{"number":42,"headRefOid":"sha-A"}'; }
last_reviewed_head()   { printf '%s' 'sha-A'; }
extract_dev_session_id() { printf '%s' ''; }
is_session_completed() { return 1; }
may_stall_now()         { return 0; }   # 0 = eligible (no live wrapper) — matches lib-dispatch.sh's contract
acquire_dispatch_marker() { _rec acquire_dispatch_marker "$@"; return "$_MOCK_ACQUIRE_RC"; }
dispatch_marker_confirm_launched() { _rec dispatch_marker_confirm_launched "$@"; }
release_dispatch_marker()          { _rec release_dispatch_marker "$@"; }
label_swap() { _rec label_swap "$@"; return "$_MOCK_LABEL_SWAP_RC"; }
post_dispatch_token() { _rec post_dispatch_token "$@"; }
dispatch()             { _rec dispatch "$@"; }
log() { :; }

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

_reset() {
  _trace_reset
  _MOCK_ACQUIRE_RC=0
  _MOCK_LABEL_SWAP_RC=0
}

# ===========================================================================
echo "=== TC-SH-001: concurrent tick holds the dispatch marker → self-heal skips cleanly, no dispatch ([INV-108]) ==="
# ===========================================================================
_reset
_MOCK_ACQUIRE_RC=1   # a concurrent tick already owns (issue, dev-new)
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-SH-001 returns 0" "0" "$rc"
assert_eq   "TC-SH-001 ZERO dev-new dispatched" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_no_match "TC-SH-001 no self-heal marker posted (acquire lost)" "self-heal-lost-session:" "$(_trace_all)"
assert_match "TC-SH-001 falls through to the residual stale-verdict park" "stale-verdict:sha-A" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-SH-002: acquire succeeds but label_swap fails → release the marker, no dispatch, no phantom marker ==="
# ===========================================================================
_reset
_MOCK_LABEL_SWAP_RC=1
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-SH-002 returns 0" "0" "$rc"
assert_match "TC-SH-002 acquired the marker" "^acquire_dispatch_marker" "$(_trace_all)"
assert_match "TC-SH-002 released the marker on pre-spawn failure" "^release_dispatch_marker${US}99${US}dev-new$" "$(_trace_all)"
assert_eq   "TC-SH-002 ZERO dev-new dispatched" "0" "$(_trace_verbs | grep -c '^dispatch$')"
assert_no_match "TC-SH-002 no self-heal marker posted (dispatch never happened)" "self-heal-lost-session:" "$(_trace_all)"
assert_no_match "TC-SH-002 confirm_launched NOT called (pre-spawn failed)" "^dispatch_marker_confirm_launched" "$(_trace_all)"

# ===========================================================================
echo
echo "=== TC-SH-003: happy path — acquire + label_swap + dispatch all succeed → confirmed, marker posted ==="
# ===========================================================================
_reset
handle_pending_dev_pr_exists 99
rc=$?
assert_eq   "TC-SH-003 returns 0" "0" "$rc"
assert_match "TC-SH-003 dispatched exactly one dev-new" "^dispatch${US}dev-new${US}99$" "$(_trace_all)"
assert_match "TC-SH-003 confirmed the launch" "^dispatch_marker_confirm_launched${US}99${US}dev-new$" "$(_trace_all)"
assert_match "TC-SH-003 posted the self-heal marker" "self-heal-lost-session:sha-A" "$(_trace_all)"
assert_no_match "TC-SH-003 NO stale-verdict park" "stale-verdict:" "$(_trace_all)"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
