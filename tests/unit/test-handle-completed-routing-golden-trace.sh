#!/bin/bash
# test-handle-completed-routing-golden-trace.sh — #285 class-(b) golden-trace gate.
#
# `handle_completed_session_routing` is the second named class-(b) entangled
# multi-op orchestrator (provider-spec.md §7.1(b)/§7.3). After #283/#282 its
# inner `gh` primitives moved behind ITP/CHP verbs across all five case arms; it
# is now provider-neutral glue calling itp_list_comments (dedup reads),
# itp_post_comment (every comment incl. the INV-85 no-progress attempt marker),
# itp_transition_state (the label move, via label_swap), and chp_find_pr_for_issue
# (via the fetch_pr_for_issue same-named delegate shim) — interleaved with NON-host
# ops that stay caller-side (classify_recent_review_verdict, last_reviewed_head,
# dev_report_bot_unfixable, count_review_aware_flips, the `: > log` truncate,
# post_dispatch_token, dispatch dev-new).
#
# This is the golden-trace gate #283 deferred (provider-spec.md §7.2). It stubs the
# VERB LAYER (not the `gh` binary) and asserts byte-identical verb argv on each
# documented path — anchored on #148 (chp_find_pr_for_issue FIELDS MUST include
# `body`) and #274/INV-85 (the no-progress attempt-marker token). Recording at the
# verb boundary is what makes the gate *sufficient* (a gh-binary stub passes by
# construction even if a verb's GitHub impl stops calling `gh`, §7.2.1).
#
# Run: bash tests/unit/test-handle-completed-routing-golden-trace.sh

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
export PROJECT_ID="test-hcgt-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5
export REVIEW_RETRY_LIMIT=2

US=$'\037'

# ---------------------------------------------------------------------------
# Routing-side mocks (the NON-host caller ops). Configured per-test.
# ---------------------------------------------------------------------------
_MOCK_VERDICT="none"          # classify_recent_review_verdict result
_MOCK_CAUSE=""
_MOCK_FLIP_COUNT=0            # count_review_aware_flips
_MOCK_CURRENT_HEAD="abc123"   # .headRefOid echoed by fetch_pr_for_issue
_MOCK_LAST_HEAD=""            # last_reviewed_head
_MOCK_BOT_UNFIXABLE=1         # dev_report_bot_unfixable rc (0=true,1=false)
_MOCK_NOTICE_PRESENT=0        # generic dedup: 0 absent / 1 present
_MOCK_ATTEMPT_PRESENT=0       # branch-B attempt marker present

# ---------------------------------------------------------------------------
# Verb-layer recorder → TRACE FILE (subshell-safe; the dedup reads pipe
# itp_list_comments through jq|grep in a subshell — a bash-array append would be
# lost, the file append survives). itp_list_comments emits a {body} array whose
# presence of the searched marker is controlled per-test.
# ---------------------------------------------------------------------------
_TRACE_FILE=""
# Each verb call is recorded as EXACTLY one line. A comment BODY arg may itself
# contain embedded newlines (the non-substantive flip / fresh-dev posts use
# `printf '%s\n%s'`), so collapse any literal newline inside the joined record to
# a `\n` escape before writing — otherwise the second line of a multi-line body
# would be misread as a separate verb by the line-based trace reader.
_rec() {
  local v="$1"; shift; local a="$v"; local x
  for x in "$@"; do a+="${US}${x}"; done
  a="${a//$'\n'/\\n}"
  printf '%s\n' "$a" >> "$_TRACE_FILE"
}
_trace_reset() { : > "$_TRACE_FILE"; }

# itp_list_comments — the caller greps for several distinct markers across the
# arms (INV-12-completed, no-progress-substantive, no-progress-substantive-attempt,
# INV-35-fresh-dev). We return a body that satisfies the configured presence: the
# attempt-marker presence is keyed separately (Branch B) from the generic notice
# dedup. Echo BOTH possible tokens when the corresponding flag is set so the
# caller's `select(contains(...))` matches whichever it's currently grepping for.
itp_list_comments() {
  _rec itp_list_comments "$@"
  local body="baseline comment"
  [ "$_MOCK_NOTICE_PRESENT" = "1" ] && body+=" INV-12-completed:${_MOCK_SID:-sid} no-progress-substantive:${_MOCK_CURRENT_HEAD} INV-35-fresh-dev:${_MOCK_SID:-sid}"
  [ "$_MOCK_ATTEMPT_PRESENT" = "1" ] && body+=" no-progress-substantive-attempt:${_MOCK_CURRENT_HEAD}"
  printf '%s\n' "[{\"body\":\"${body}\"}]"
}
itp_post_comment()    { _rec itp_post_comment "$@"; }
itp_transition_state(){ _rec itp_transition_state "$@"; }
# fetch_pr_for_issue is the kept same-named caller-side delegate shim (§7.2 m3,
# post-#277 it delegates to resolve_pr_for_issue → chp_find_pr_for_issue). We
# record the direct call (the argv the ORCHESTRATOR emits: "number,headRefOid,body")
# then invoke the REAL resolve_pr_for_issue (sourced from lib-pr-linkage.sh via
# lib-dispatch.sh) so the genuine delegation chain — including resolve's field
# union + `-q` projection — runs and lands on the recorded chp_find_pr_for_issue
# verb with its ACTUAL runtime argv (NOT a hand-rolled forward; #285 review m3/r1).
fetch_pr_for_issue() {
  _rec fetch_pr_for_issue "$@"
  resolve_pr_for_issue "$@"
}
# chp_find_pr_for_issue — record the REAL union argv resolve_pr_for_issue emits,
# and return the single-line projected PR object the orchestrator's
# `jq -r '.headRefOid // empty'` reads. (resolve's `-q "$q"` would normally do
# the projection against a PR list; here we shortcut to the already-projected
# object since the caller only consumes .headRefOid.)
chp_find_pr_for_issue() {
  _rec chp_find_pr_for_issue "$@"
  printf '%s\n' "{\"number\":7,\"headRefOid\":\"${_MOCK_CURRENT_HEAD}\",\"body\":\"b\"}"
}

# Non-host caller-side ops.
classify_recent_review_verdict() {
  local _i="$1" _t="$2" _v="$3" _c="$4"
  printf -v "$_v" '%s' "$_MOCK_VERDICT"
  printf -v "$_c" '%s' "$_MOCK_CAUSE"
  return 0
}
count_review_aware_flips() { printf '%s' "$_MOCK_FLIP_COUNT"; }
last_reviewed_head()       { printf '%s' "$_MOCK_LAST_HEAD"; }
dev_report_bot_unfixable() { return "$_MOCK_BOT_UNFIXABLE"; }
post_dispatch_token()      { _rec post_dispatch_token "$@"; }
dispatch()                 { _rec dispatch "$@"; }
mark_stalled()             { _rec mark_stalled "$@"; }
log() { :; }

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT
_TRACE_FILE="$TMPDIR_T/trace"; : > "$_TRACE_FILE"
export _TRACE_FILE US _MOCK_VERDICT _MOCK_CAUSE _MOCK_FLIP_COUNT _MOCK_CURRENT_HEAD \
       _MOCK_LAST_HEAD _MOCK_BOT_UNFIXABLE _MOCK_NOTICE_PRESENT _MOCK_ATTEMPT_PRESENT _MOCK_SID
export -f _rec itp_list_comments itp_post_comment itp_transition_state \
          fetch_pr_for_issue chp_find_pr_for_issue 2>/dev/null || true

# The real Branch C `: > /tmp/agent-…log` truncate is harmless here: the function
# computes _log_file=/tmp/agent-${PROJECT_ID}-issue-${N}.log; with a unique
# PROJECT_ID per run it cannot collide with a live wrapper log.

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

# Re-define AFTER sourcing so our mocks win over the lib's real definitions.
itp_list_comments() {
  _rec itp_list_comments "$@"
  local body="baseline comment"
  [ "$_MOCK_NOTICE_PRESENT" = "1" ] && body+=" INV-12-completed:${_MOCK_SID:-sid} no-progress-substantive:${_MOCK_CURRENT_HEAD} INV-35-fresh-dev:${_MOCK_SID:-sid}"
  [ "$_MOCK_ATTEMPT_PRESENT" = "1" ] && body+=" no-progress-substantive-attempt:${_MOCK_CURRENT_HEAD}"
  printf '%s\n' "[{\"body\":\"${body}\"}]"
}
itp_post_comment()    { _rec itp_post_comment "$@"; }
itp_transition_state(){ _rec itp_transition_state "$@"; }
# Record the orchestrator's direct call, then drive the REAL resolve_pr_for_issue
# (we do NOT override it) so chp_find_pr_for_issue receives its genuine runtime
# union argv — see the before-source copy for the rationale.
fetch_pr_for_issue() {
  _rec fetch_pr_for_issue "$@"
  resolve_pr_for_issue "$@"
}
chp_find_pr_for_issue() {
  _rec chp_find_pr_for_issue "$@"
  printf '%s\n' "{\"number\":7,\"headRefOid\":\"${_MOCK_CURRENT_HEAD}\",\"body\":\"b\"}"
}
classify_recent_review_verdict() {
  local _i="$1" _t="$2" _v="$3" _c="$4"
  printf -v "$_v" '%s' "$_MOCK_VERDICT"; printf -v "$_c" '%s' "$_MOCK_CAUSE"; return 0
}
count_review_aware_flips() { printf '%s' "$_MOCK_FLIP_COUNT"; }
last_reviewed_head()       { printf '%s' "$_MOCK_LAST_HEAD"; }
dev_report_bot_unfixable() { return "$_MOCK_BOT_UNFIXABLE"; }
post_dispatch_token()      { _rec post_dispatch_token "$@"; }
dispatch()                 { _rec dispatch "$@"; }
mark_stalled()             { _rec mark_stalled "$@"; }
log() { :; }
export -f _rec itp_list_comments itp_post_comment itp_transition_state \
          fetch_pr_for_issue chp_find_pr_for_issue 2>/dev/null || true

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
_trace_nth()   { local want="$1" n="$2" e c=0; while IFS= read -r e; do [ "${e%%${US}*}" = "$want" ] && { c=$((c+1)); [ "$c" = "$n" ] && { printf '%s' "$e"; return; }; }; done < "$_TRACE_FILE"; }

# Reset all routing mocks to a neutral baseline before each test.
_reset_mocks() {
  _trace_reset
  _MOCK_VERDICT="none"; _MOCK_CAUSE=""; _MOCK_FLIP_COUNT=0
  _MOCK_CURRENT_HEAD="abc123"; _MOCK_LAST_HEAD=""; _MOCK_BOT_UNFIXABLE=1
  _MOCK_NOTICE_PRESENT=0; _MOCK_ATTEMPT_PRESENT=0
}

# ===================================================================
echo "=== TC-HCGT-001..003: none / passed arms ==="

# TC-HCGT-001 — none, notice absent: dedup read then operator-handoff post.
_reset_mocks; _MOCK_VERDICT="none"; _MOCK_SID="sidA"
handle_completed_session_routing 301 sidA "2026-06-28T00:00:00Z" >/dev/null 2>&1
assert_eq     "TC-HCGT-001 none arm verb order = list,post" "itp_list_comments,itp_post_comment" "$(_trace_verbs | paste -sd, -)"
assert_match  "TC-HCGT-001 post body carries INV-12-completed marker" "INV-12-completed:sidA" "$(_trace_nth itp_post_comment 1)"

# TC-HCGT-002 — none, notice PRESENT: dedup read only, NO post.
_reset_mocks; _MOCK_VERDICT="none"; _MOCK_SID="sidA"; _MOCK_NOTICE_PRESENT=1
handle_completed_session_routing 302 sidA "2026-06-28T00:00:00Z" >/dev/null 2>&1
assert_eq     "TC-HCGT-002 none arm (notice present) verb order = list only" "itp_list_comments" "$(_trace_verbs | paste -sd, -)"

# TC-HCGT-003 — passed (race no-op): ZERO verb calls.
_reset_mocks; _MOCK_VERDICT="passed"
handle_completed_session_routing 303 sidA "2026-06-28T00:00:00Z" >/dev/null 2>&1
assert_eq     "TC-HCGT-003 passed arm emits ZERO verbs" "" "$(_trace_verbs | paste -sd, -)"

# ===================================================================
echo
echo "=== TC-HCGT-004..005: failed-non-substantive arm ==="

# TC-HCGT-004 — flip < limit: flip post then label move pending-dev→pending-review.
_reset_mocks; _MOCK_VERDICT="failed-non-substantive"; _MOCK_CAUSE="bot-timeout"; _MOCK_FLIP_COUNT=0
handle_completed_session_routing 304 sidA "2026-06-28T00:00:00Z" >/dev/null 2>&1
assert_eq     "TC-HCGT-004 non-substantive flip verb order = post,transition" "itp_post_comment,itp_transition_state" "$(_trace_verbs | paste -sd, -)"
assert_eq     "TC-HCGT-004 transition argv = issue,pending-dev,pending-review" "itp_transition_state${US}304${US}pending-dev${US}pending-review" "$(_trace_nth itp_transition_state 1)"
assert_match  "TC-HCGT-004 flip post carries review-aware-flip marker" "review-aware-flip:non-substantive" "$(_trace_nth itp_post_comment 1)"

# TC-HCGT-005 — flip ≥ limit: persistent-failure post then mark_stalled, NO reroute.
_reset_mocks; _MOCK_VERDICT="failed-non-substantive"; _MOCK_CAUSE="bot-timeout"; _MOCK_FLIP_COUNT=2
handle_completed_session_routing 305 sidA "2026-06-28T00:00:00Z" >/dev/null 2>&1
assert_eq     "TC-HCGT-005 retry-cap verb order = post,mark_stalled" "itp_post_comment,mark_stalled" "$(_trace_verbs | paste -sd, -)"
assert_no_match "TC-HCGT-005 NO pending-review transition at retry cap" "pending-review" "$(_trace_verbs)"

# ===================================================================
echo
echo "=== TC-HCGT-006..008: failed-substantive Branches A/B/C ==="

# TC-HCGT-006 — Branch A bot-unfixable (head==last, dev_report_bot_unfixable true).
_reset_mocks; _MOCK_VERDICT="failed-substantive"; _MOCK_CURRENT_HEAD="head9"; _MOCK_LAST_HEAD="head9"; _MOCK_BOT_UNFIXABLE=0
handle_completed_session_routing 306 sidB "2026-06-28T00:00:00Z" >/dev/null 2>&1
assert_eq     "TC-HCGT-006 Branch A verb order = fetch,chp_find,list,post,mark_stalled" \
              "fetch_pr_for_issue,chp_find_pr_for_issue,itp_list_comments,itp_post_comment,mark_stalled" "$(_trace_verbs | paste -sd, -)"
assert_match  "TC-HCGT-006 Branch A notice carries no-progress-substantive:<head>" "no-progress-substantive:head9" "$(_trace_nth itp_post_comment 1)"

# TC-HCGT-007 — Branch B no-progress (head==last, NOT bot-unfixable, attempt marker present).
_reset_mocks; _MOCK_VERDICT="failed-substantive"; _MOCK_CURRENT_HEAD="head9"; _MOCK_LAST_HEAD="head9"; _MOCK_BOT_UNFIXABLE=1; _MOCK_ATTEMPT_PRESENT=1
handle_completed_session_routing 307 sidB "2026-06-28T00:00:00Z" >/dev/null 2>&1
# fetch (head), then list (attempt-marker presence), then list (notice dedup), then post, then mark_stalled.
assert_eq     "TC-HCGT-007 Branch B verb order = fetch,chp_find,list,list,post,mark_stalled" \
              "fetch_pr_for_issue,chp_find_pr_for_issue,itp_list_comments,itp_list_comments,itp_post_comment,mark_stalled" "$(_trace_verbs | paste -sd, -)"
assert_match  "TC-HCGT-007 Branch B notice mentions unchanged HEAD" "unchanged since the last review" "$(_trace_nth itp_post_comment 1)"

# TC-HCGT-008 — Branch C fresh dev-new (head moved / no attempt marker).
_reset_mocks; _MOCK_VERDICT="failed-substantive"; _MOCK_CURRENT_HEAD="headNEW"; _MOCK_LAST_HEAD="headOLD"; _MOCK_BOT_UNFIXABLE=1; _MOCK_SID="sidC"
handle_completed_session_routing 308 sidC "2026-06-28T00:00:00Z" >/dev/null 2>&1
# fetch, list (fresh-dev dedup), post (INV-35-fresh-dev), transition pending-dev→in-progress,
# post_dispatch_token, dispatch, then list-free attempt-marker post.
assert_eq     "TC-HCGT-008 Branch C verb order = fetch,chp_find,list,post,transition,post_dispatch_token,dispatch,post" \
              "fetch_pr_for_issue,chp_find_pr_for_issue,itp_list_comments,itp_post_comment,itp_transition_state,post_dispatch_token,dispatch,itp_post_comment" "$(_trace_verbs | paste -sd, -)"
assert_eq     "TC-HCGT-008 Branch C transition argv = issue,pending-dev,in-progress" "itp_transition_state${US}308${US}pending-dev${US}in-progress" "$(_trace_nth itp_transition_state 1)"
assert_eq     "TC-HCGT-008 Branch C dispatch argv = dev-new,issue" "dispatch${US}dev-new${US}308" "$(_trace_nth dispatch 1)"

# ===================================================================
echo
echo "=== TC-HCGT-009: default (unknown verdict) arm ==="
_reset_mocks; _MOCK_VERDICT="weird-unexpected"; _MOCK_SID="sidD"
handle_completed_session_routing 309 sidD "2026-06-28T00:00:00Z" >/dev/null 2>&1
assert_eq     "TC-HCGT-009 default arm verb order = list,post" "itp_list_comments,itp_post_comment" "$(_trace_verbs | paste -sd, -)"
assert_match  "TC-HCGT-009 default post carries INV-12-completed handoff marker" "INV-12-completed:sidD" "$(_trace_nth itp_post_comment 1)"

# ===================================================================
echo
echo "=== TC-HCGT-010..011: #148 + #274/INV-85 anchors ==="

# TC-HCGT-010 — #148 anchor. Two distinct boundaries (the real delegation chain
# fetch_pr_for_issue → resolve_pr_for_issue → chp_find_pr_for_issue runs LIVE here;
# only fetch_pr_for_issue and chp_find_pr_for_issue are recorded, resolve is real):
#   (a) the argv the ORCHESTRATOR emits directly is byte-identical
#       "number,headRefOid,body" (the literal #274 source-pin); AND
#   (b) at the REAL chp_find_pr_for_issue verb boundary the FIELDS positional arg
#       is resolve_pr_for_issue's genuine union (caller fields + the [INV-86]
#       resolution fields number,closingIssuesReferences,headRefName) — which MUST
#       still CONTAIN `body` (the #148 body-inclusion guarantee at the verb), and
#       the call carries the `-q` projection. We assert the real union argv
#       exactly so a regression in resolve's field union (dropping body) is caught
#       at the verb, not hidden behind a hand-rolled mock forward (#285 review m3).
_reset_mocks; _MOCK_VERDICT="failed-substantive"; _MOCK_CURRENT_HEAD="headNEW"; _MOCK_LAST_HEAD="headOLD"; _MOCK_SID="sidC"
handle_completed_session_routing 310 sidC "2026-06-28T00:00:00Z" >/dev/null 2>&1
assert_eq     "TC-HCGT-010a fetch_pr_for_issue (orchestrator's direct call) FIELDS = number,headRefOid,body (#274 source-pin)" \
              "fetch_pr_for_issue${US}310${US}number,headRefOid,body" "$(_trace_nth fetch_pr_for_issue 1)"
chp_call=$(_trace_nth chp_find_pr_for_issue 1)
# Positional FIELDS = arg 2 (the 3rd US-separated field: verb, issue, FIELDS, …).
chp_fields=$(awk -v FS="$US" '{print $3}' <<<"$chp_call")
assert_eq     "TC-HCGT-010b chp_find_pr_for_issue real union FIELDS (resolve_pr_for_issue, #148 body retained)" \
              "number,headRefOid,body,closingIssuesReferences,headRefName" "$chp_fields"
assert_match  "TC-HCGT-010b chp_find_pr_for_issue FIELDS still includes body (#148 anchor at the verb boundary)" \
              "(^|,)body(,|$)" "$chp_fields"
assert_match  "TC-HCGT-010b chp_find_pr_for_issue carries the -q projection" "${US}-q${US}" "$chp_call"

# TC-HCGT-011 — #274/INV-85 anchor: Branch C's attempt-marker post carries the
# EXACT token no-progress-substantive-attempt:<head> via itp_post_comment.
attempt_post=$(_trace_nth itp_post_comment 2)
assert_match  "TC-HCGT-011 attempt marker token = no-progress-substantive-attempt:headNEW (#274/INV-85)" \
              "no-progress-substantive-attempt:headNEW" "$attempt_post"
assert_match  "TC-HCGT-011 attempt marker is an HTML comment" "<!-- no-progress-substantive-attempt:headNEW session=sidC -->" "$attempt_post"

# ===================================================================
echo
echo "=== TC-HCGT-012..016: source-level invariants + capability negative + shim ==="

_fn_body() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" {inb=1}
    inb {print}
    inb && /^\}/ {exit}
  ' "$LIB"
}
HC_BODY="$(_fn_body handle_completed_session_routing)"

# TC-HCGT-012 — label order pin already covered by argv asserts above; pin the
# source too: the pending-dev→pending-review and pending-dev→in-progress moves go
# through label_swap (→ itp_transition_state), never a raw gh issue edit.
assert_match  "TC-HCGT-012 non-substantive flip uses label_swap pending-dev pending-review" \
              "label_swap \"\\\$issue_num\" \"pending-dev\" \"pending-review\"" "$HC_BODY"
assert_match  "TC-HCGT-012 Branch C uses label_swap pending-dev in-progress" \
              "label_swap \"\\\$issue_num\" \"pending-dev\" \"in-progress\"" "$HC_BODY"

# TC-HCGT-013 — zero executable raw `gh ` in the body.
gh_exec=$(grep -nE '\bgh ' <<<"$HC_BODY" | grep -vE '^\s*[0-9]*:?\s*#' || true)
assert_eq     "TC-HCGT-013 handle_completed body has ZERO executable raw 'gh ' invocations" "" "$gh_exec"

# TC-HCGT-014 — §7.4 negative: NO caps gate inside the orchestrator.
assert_no_match "TC-HCGT-014 handle_completed body has NO itp_caps/chp_caps branch" "itp_caps|chp_caps" "$HC_BODY"

# TC-HCGT-015 — degraded fake-provider selection emits the IDENTICAL Branch C
# verb SEQUENCE (the orchestrator does not branch on caps; the marker_channel /
# edit_comment fallbacks live in the verb IMPLs). Our verb recorders override the
# seam regardless of ISSUE_PROVIDER, so selecting the degraded provider must not
# change the recorded sequence.
_reset_mocks; _MOCK_VERDICT="failed-substantive"; _MOCK_CURRENT_HEAD="headNEW"; _MOCK_LAST_HEAD="headOLD"; _MOCK_SID="sidC"
ISSUE_PROVIDER=degraded CODE_HOST=degraded \
  handle_completed_session_routing 315 sidC "2026-06-28T00:00:00Z" >/dev/null 2>&1
assert_eq     "TC-HCGT-015 degraded provider → IDENTICAL Branch C verb sequence" \
              "fetch_pr_for_issue,chp_find_pr_for_issue,itp_list_comments,itp_post_comment,itp_transition_state,post_dispatch_token,dispatch,itp_post_comment" "$(_trace_verbs | paste -sd, -)"

# TC-HCGT-016 — function-mock shim audit: fetch_pr_for_issue is a defined
# caller-side function delegating to chp_find_pr_for_issue (§7.2 m3), so existing
# fetch_pr_for_issue() {…} test mocks still intercept.
assert_match  "TC-HCGT-016 fetch_pr_for_issue shim is defined" "^fetch_pr_for_issue\(\) \{" "$(cat "$LIB")"
fp_body=$(_fn_body fetch_pr_for_issue)
assert_match  "TC-HCGT-016 fetch_pr_for_issue delegates to chp_find_pr_for_issue (or resolve_pr_for_issue)" \
              "chp_find_pr_for_issue|resolve_pr_for_issue" "$fp_body"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
