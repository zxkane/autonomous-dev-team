#!/bin/bash
# test-mark-stalled-golden-trace.sh — #285 class-(b) golden-trace gate.
#
# `mark_stalled` is one of the two named class-(b) entangled multi-op
# orchestrators (provider-spec.md §7.1(b)/§7.3). After #283 its inner `gh`
# primitives moved behind ITP verbs; it is now provider-neutral glue that
# interleaves verb calls (itp_list_comments, itp_post_comment via the
# stalled-summary, itp_transition_state via the label_swap shim) with NON-host
# ops that stay caller-side (pid_alive, get_pid, EXECUTION_BACKEND resolve,
# count_agent_failures/dispatcher_crashes/false_positives).
#
# This is the golden-trace gate #283 deferred (provider-spec.md §7.2: "These are
# the code-bearing siblings' tests — NOT this PR"). Unlike
# test-mark-stalled-liveness.sh — which stubs the `gh` BINARY and passes by
# construction even if a verb's GitHub impl stops calling `gh` (§7.2.1, the
# necessary-but-not-sufficient gate) — this suite stubs the VERB LAYER and
# asserts byte-identical verb argv on each documented path. Recording at the
# verb boundary is what makes the gate *sufficient*.
#
# Run: bash tests/unit/test-mark-stalled-golden-trace.sh

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
export PROJECT_ID=test-msgt
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# Unit separator for argv capture — NUL-safe, never appears in a verb arg.
US=$'\037'

# ---------------------------------------------------------------------------
# Verb-layer recorder. Each verb APPENDS one line "VERB<US>arg1<US>arg2…" to a
# TRACE FILE (not a bash array): the deferral dedup read calls
# `itp_list_comments … | jq | grep` in a PIPE subshell, and a subshell-scoped
# array append would be lost — the file append survives (the same subshell-loses-
# state lesson as the verdict poll counters, #235). A test reads the file back to
# assert the EXACT argv vector, not a fuzzy substring. itp_list_comments returns
# a canned comments array (the dedup-read source); a per-test _MOCK_MARKER_PRESENT
# flips whether the dedup marker is already present.
# ---------------------------------------------------------------------------
_TRACE_FILE=""           # set after TMPDIR_T is created, exported to subshells
_MOCK_MARKER_PRESENT=0   # 0 → marker absent (post fires); 1 → present (skip)
_MOCK_PRESENT_MARKER=""  # exact marker substring the mock embeds when present

# One line per verb call: collapse any embedded newline in a BODY arg to `\n` so
# the line-based trace reader never misreads a multi-line body as a second verb.
_rec() {
  local v="$1"; shift; local a="$v"; local x
  for x in "$@"; do a+="${US}${x}"; done
  a="${a//$'\n'/\\n}"
  printf '%s\n' "$a" >> "$_TRACE_FILE"
}
_trace_reset() { : > "$_TRACE_FILE"; }

itp_list_comments() {
  _rec itp_list_comments "$@"
  # Emit a comments array whose single body either CONTAINS or OMITS the
  # caller's dedup marker, so the caller-side `select(contains(...)) | length`
  # jq sees the configured presence. The caller pipes us to its own jq, so we
  # just print a {body} array the caller's jq can run `.[].body` over.
  if [ "$_MOCK_MARKER_PRESENT" = "1" ]; then
    printf '%s\n' '[{"body":"__MARKER_PRESENT__ INV-26-stall-deferral:pid=ANY no-progress-substantive:ANY"}]'
  else
    printf '%s\n' '[{"body":"unrelated comment"}]'
  fi
}
itp_post_comment()    { _rec itp_post_comment "$@"; }
itp_transition_state(){ _rec itp_transition_state "$@"; }

# Non-host caller-side ops the counters need — keep them deterministic so the
# terminal-stall path is reached without real gh / comment scraping.
# count_no_pr_attempts (#461, [INV-123]) is mocked the same way: a real call
# would invoke itp_list_comments a second time and pollute the verb trace
# this suite asserts byte-identical order over.
count_agent_failures()            { echo 3; }
count_no_pr_attempts()            { echo 0; }
count_dispatcher_crashes()        { echo 0; }
count_dispatcher_false_positives(){ echo 0; }

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT
_TRACE_FILE="$TMPDIR_T/trace"
: > "$_TRACE_FILE"
# Export the recorder + its state so the PIPE-subshell verb calls (the deferral
# dedup `itp_list_comments | jq | grep`) record into the SAME file.
export _TRACE_FILE US _MOCK_MARKER_PRESENT _MOCK_PRESENT_MARKER
export -f _rec itp_list_comments itp_post_comment itp_transition_state \
          count_agent_failures count_no_pr_attempts count_dispatcher_crashes \
          count_dispatcher_false_positives 2>/dev/null || true

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

# Re-define the verb recorders + counter mocks AFTER sourcing so they win over
# the lib's real definitions (and over the seam's itp_* shims).
itp_list_comments() {
  _rec itp_list_comments "$@"
  if [ "$_MOCK_MARKER_PRESENT" = "1" ]; then
    # Echo a body containing the EXACT marker substring the caller greps for
    # (set per-test in _MOCK_PRESENT_MARKER). The caller's
    # `select(contains("<marker>")) | length` then sees the marker present and
    # skips the post.
    printf '%s\n' "[{\"body\":\"prior marker ${_MOCK_PRESENT_MARKER:-__none__}\"}]"
  else
    printf '%s\n' '[{"body":"unrelated comment"}]'
  fi
}
itp_post_comment()    { _rec itp_post_comment "$@"; }
itp_transition_state(){ _rec itp_transition_state "$@"; }
count_agent_failures()            { echo 3; }
count_no_pr_attempts()            { echo 0; }
count_dispatcher_crashes()        { echo 0; }
count_dispatcher_false_positives(){ echo 0; }
export -f _rec itp_list_comments itp_post_comment itp_transition_state \
          count_agent_failures count_no_pr_attempts count_dispatcher_crashes \
          count_dispatcher_false_positives 2>/dev/null || true

# Sandbox the PID dir so pid_alive/get_pid read our fixtures.
pid_dir_for_project() { echo "$TMPDIR_T"; }

# ---------------------------------------------------------------------------
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected: [$expected]"
    echo "      actual:   [$actual]"
    FAIL=$((FAIL + 1))
  fi
}
assert_match() {
  local desc="$1" pat="$2" hay="$3"
  if grep -qE "$pat" <<<"$hay"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pat)"
    echo "      haystack: [$hay]"
    FAIL=$((FAIL + 1))
  fi
}
assert_no_match() {
  local desc="$1" pat="$2" hay="$3"
  if ! grep -qE "$pat" <<<"$hay"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern '$pat' should NOT match)"
    echo "      haystack: [$hay]"
    FAIL=$((FAIL + 1))
  fi
}
# Echo the recorded verb NAMES in order, one per line (read from the trace file).
_trace_verbs() { local e; while IFS= read -r e; do [ -n "$e" ] && printf '%s\n' "${e%%${US}*}"; done < "$_TRACE_FILE"; }
# Echo the full argv vector for the Nth (1-based) recorded call matching VERB.
_trace_nth()   { local want="$1" n="$2" e c=0; while IFS= read -r e; do [ "${e%%${US}*}" = "$want" ] && { c=$((c+1)); [ "$c" = "$n" ] && { printf '%s' "$e"; return; }; }; done < "$_TRACE_FILE"; }

# ===================================================================
echo "=== TC-MSGT-001..002: liveness-defer verb trace ==="

# TC-MSGT-001 — pid_alive ALIVE, marker ABSENT: dedup read then deferral post,
# NO transition, NO stalled-summary.
_trace_reset; _MOCK_MARKER_PRESENT=0
sleep 60 & LIVE_PID=$!; echo "$LIVE_PID" > "$TMPDIR_T/issue-201.pid"
EXECUTION_BACKEND=local mark_stalled 201 >/dev/null 2>&1
verbs=$(_trace_verbs | paste -sd, -)
assert_eq        "TC-MSGT-001 defer (marker absent) verb order = list,post" "itp_list_comments,itp_post_comment" "$verbs"
post1=$(_trace_nth itp_post_comment 1)
assert_match     "TC-MSGT-001 deferral post body carries INV-26-stall-deferral marker" "INV-26-stall-deferral:pid=${LIVE_PID}" "$post1"
assert_no_match  "TC-MSGT-001 NO transition on defer" "itp_transition_state" "$verbs"
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null; rm -f "$TMPDIR_T/issue-201.pid"

# TC-MSGT-002 — ALIVE, marker PRESENT: dedup read only, NO post.
_trace_reset; _MOCK_MARKER_PRESENT=1
sleep 60 & LIVE_PID=$!; echo "$LIVE_PID" > "$TMPDIR_T/issue-202.pid"
_MOCK_PRESENT_MARKER="INV-26-stall-deferral:pid=${LIVE_PID}"
EXECUTION_BACKEND=local mark_stalled 202 >/dev/null 2>&1
verbs=$(_trace_verbs | paste -sd, -)
assert_eq        "TC-MSGT-002 defer (marker present) verb order = list only" "itp_list_comments" "$verbs"
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null; rm -f "$TMPDIR_T/issue-202.pid"

# ===================================================================
echo
echo "=== TC-MSGT-003..005: terminal stall verb trace + label order ==="

# TC-MSGT-003 — local empty-PID (DEAD shortcut): transition THEN stalled-summary,
# NO deferral comment, NO dedup read.
_trace_reset; _MOCK_MARKER_PRESENT=0
: > "$TMPDIR_T/issue-203.pid"; touch "$TMPDIR_T/issue-203.pid"
EXECUTION_BACKEND=local mark_stalled 203 >/dev/null 2>&1
verbs=$(_trace_verbs | paste -sd, -)
assert_eq        "TC-MSGT-003 empty-PID terminal verb order = transition,post" "itp_transition_state,itp_post_comment" "$verbs"
assert_no_match  "TC-MSGT-003 NO deferral list-read on DEAD shortcut" "itp_list_comments" "$verbs"
rm -f "$TMPDIR_T/issue-203.pid"

# TC-MSGT-004 — PID file present but process dead: same terminal sequence.
_trace_reset; _MOCK_MARKER_PRESENT=0
echo "999999" > "$TMPDIR_T/issue-204.pid"; touch -t 200001010000.00 "$TMPDIR_T/issue-204.pid"
EXECUTION_BACKEND=local mark_stalled 204 >/dev/null 2>&1
verbs=$(_trace_verbs | paste -sd, -)
assert_eq        "TC-MSGT-004 dead-wrapper terminal verb order = transition,post" "itp_transition_state,itp_post_comment" "$verbs"
summary=$(_trace_nth itp_post_comment 1)
assert_match     "TC-MSGT-004 stalled-summary post mentions retry limit" "exceeded the maximum retry limit" "$summary"
rm -f "$TMPDIR_T/issue-204.pid"

# TC-MSGT-005 — label order pin (the #283/INV-87 transition byte-identical argv).
_trace_reset; _MOCK_MARKER_PRESENT=0
echo "999999" > "$TMPDIR_T/issue-205.pid"; touch -t 200001010000.00 "$TMPDIR_T/issue-205.pid"
EXECUTION_BACKEND=local mark_stalled 205 >/dev/null 2>&1
trans=$(_trace_nth itp_transition_state 1)
assert_eq        "TC-MSGT-005 transition argv byte-identical = issue,pending-dev,stalled" "itp_transition_state${US}205${US}pending-dev${US}stalled" "$trans"
rm -f "$TMPDIR_T/issue-205.pid"

# ===================================================================
echo
echo "=== TC-MSGT-006..009: source-level invariants (zero raw gh, caller-side, no caps gate, shim) ==="

# Extract the mark_stalled() body: from its def line to the next top-level `}`.
_fn_body() {
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\) \\{" {inb=1}
    inb {print}
    inb && /^\}/ {exit}
  ' "$LIB"
}
MS_BODY="$(_fn_body mark_stalled)"

# TC-MSGT-006 — zero executable raw `gh ` (a `# … gh …` comment line is allowed).
gh_exec=$(grep -nE '\bgh ' <<<"$MS_BODY" | grep -vE '^\s*[0-9]*:?\s*#' || true)
assert_eq        "TC-MSGT-006 mark_stalled body has ZERO executable raw 'gh ' invocations" "" "$gh_exec"

# TC-MSGT-007 — caller-side non-host ops remain literal calls (NOT verb-wrapped).
for op in pid_alive get_pid count_agent_failures count_no_pr_attempts count_dispatcher_crashes count_dispatcher_false_positives; do
  assert_match   "TC-MSGT-007 caller-side op '$op' is a literal call in mark_stalled" "\b${op}\b" "$MS_BODY"
done

# TC-MSGT-008 — §7.4 negative: NO caps gate inside the orchestrator (the
# marker_channel/edit_comment fallbacks live in the verb IMPLs, not here).
assert_no_match  "TC-MSGT-008 mark_stalled body has NO itp_caps/chp_caps branch" "itp_caps|chp_caps" "$MS_BODY"

# TC-MSGT-009 — function-mock shim audit: label_swap is a caller-side function
# delegating to itp_transition_state, so label_swap() {…} test mocks intercept.
assert_match     "TC-MSGT-009 label_swap shim is defined" "^label_swap\(\) \{" "$(cat "$LIB")"
ls_body=$(_fn_body label_swap)
assert_match     "TC-MSGT-009 label_swap delegates to itp_transition_state" "itp_transition_state" "$ls_body"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
