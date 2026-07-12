#!/bin/bash
# test-liveness-watchdog.sh — issue #467, INV-128.
#
# Pins the pure fingerprint/counter/threshold/tier-decision helpers in
# lib-liveness.sh, plus the orchestration (_liveness_evaluate_issue /
# run_liveness_watchdog — which live in lib-dispatch.sh, NOT lib-liveness.sh,
# so the tier-2 label_swap sits inside a file check-spec-drift.sh's Check C
# actually scans) driven through the REAL functions with only the
# I/O-touching verbs stubbed (golden-trace style, mirrors
# test-issue-466-crashed-session-recovery.sh).
#
# See docs/test-cases/liveness-watchdog.md for the TC-LIVENESS-* mapping.
#
# Run: bash tests/unit/test-liveness-watchdog.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-liveness.sh"
LIB_DISPATCH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID="test-467-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5

US=$'\037'
_TRACE_FILE=""
_rec() {
  local v="$1"; shift; local a="$v"; local x
  for x in "$@"; do a+="${US}${x}"; done
  a="${a//$'\n'/\\n}"
  printf '%s\n' "$a" >> "$_TRACE_FILE"
}
_trace_reset() { : > "$_TRACE_FILE"; }
_trace_verbs() { local e; while IFS= read -r e; do [ -n "$e" ] && printf '%s\n' "${e%%"${US}"*}"; done < "$_TRACE_FILE"; }
_trace_all()   { cat "$_TRACE_FILE"; }

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT
_TRACE_FILE="$TMPDIR_T/trace"; : > "$_TRACE_FILE"

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-liveness.sh
source "$LIB"
# lib-dispatch.sh holds the orchestration (_liveness_evaluate_issue /
# run_liveness_watchdog) that calls the pure helpers above. Sourcing it also
# pulls in its own real itp_*/pid_alive/label_swap/list_pending_*
# definitions; every test below overrides the ones it needs AFTER this
# source (bash function redefinition), exactly like test-issue-466's setup.
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB_DISPATCH"
set +e

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
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1));
  else echo -e "  ${RED}FAIL${NC}: $desc"; echo "      needle: $needle"; FAIL=$((FAIL + 1)); fi
}

# ===========================================================================
echo "=== TC-LIVENESS-001..008: fingerprint ==="
# ===========================================================================

fp_base=$(_liveness_fingerprint "pending-dev" "sha-A" "2" "dispatcher-token:")
fp_repeat=$(_liveness_fingerprint "pending-dev" "sha-A" "2" "dispatcher-token:")
assert_eq "TC-LIVENESS-001 identical inputs -> identical fingerprint" "$fp_base" "$fp_repeat"

fp_label=$(_liveness_fingerprint "pending-review" "sha-A" "2" "dispatcher-token:")
assert_eq "TC-LIVENESS-002 label change -> different fingerprint" "true" "$([ "$fp_base" != "$fp_label" ] && echo true || echo false)"

fp_head=$(_liveness_fingerprint "pending-dev" "sha-B" "2" "dispatcher-token:")
assert_eq "TC-LIVENESS-003 head change -> different fingerprint" "true" "$([ "$fp_base" != "$fp_head" ] && echo true || echo false)"

fp_count=$(_liveness_fingerprint "pending-dev" "sha-A" "3" "dispatcher-token:")
assert_eq "TC-LIVENESS-004 comment-count change -> different fingerprint" "true" "$([ "$fp_base" != "$fp_count" ] && echo true || echo false)"

fp_digest=$(_liveness_fingerprint "pending-dev" "sha-A" "2" "self-heal-lost-session:")
assert_eq "TC-LIVENESS-005 marker-digest change -> different fingerprint" "true" "$([ "$fp_base" != "$fp_digest" ] && echo true || echo false)"

comments_baseline='[{"authorKind":"bot","body":"hello"}]'
comments_with_idempotent='[{"authorKind":"bot","body":"hello"},{"authorKind":"bot","body":"stale-verdict:sha-A"}]'
count_baseline=$(_liveness_non_idempotent_count "$comments_baseline")
count_with_idempotent=$(_liveness_non_idempotent_count "$comments_with_idempotent")
assert_eq "TC-LIVENESS-006 a new stale-verdict idempotent notice does NOT change the count component" "$count_baseline" "$count_with_idempotent"

comments_with_genuine='[{"authorKind":"bot","body":"hello"},{"authorKind":"bot","body":"a genuinely new update"}]'
count_with_genuine=$(_liveness_non_idempotent_count "$comments_with_genuine")
assert_eq "TC-LIVENESS-007 a genuinely new comment changes the count component" "2" "$count_with_genuine"

comments_with_tier1='[{"authorKind":"bot","body":"hello"},{"authorKind":"bot","body":"<!-- dispatcher-liveness-watchdog: issue=1 fingerprint=abc count=6 tier1=1 -->"}]'
count_with_tier1=$(_liveness_non_idempotent_count "$comments_with_tier1")
assert_eq "TC-LIVENESS-008 the watchdog's own marker is excluded from the count component" "1" "$count_with_tier1"

# ===========================================================================
echo
echo "=== TC-LIVENESS-009..015: counter / tier1 latch round-trip ==="
# ===========================================================================

assert_eq "TC-LIVENESS-009a no prior marker -> next count = 1" "1" "$(_liveness_next_count "" "$fp_base")"
assert_eq "TC-LIVENESS-009b no prior marker -> next tier1 = 0" "0" "$(_liveness_next_tier1 "" "$fp_base")"

m5=$(_liveness_marker 42 "$fp_base" 5 0)
assert_eq "TC-LIVENESS-010 same fingerprint -> count increments" "6" "$(_liveness_next_count "$m5" "$fp_base")"

m_other_fp=$(_liveness_marker 42 "different-fp" 17 1)
assert_eq "TC-LIVENESS-011a different fingerprint -> count resets to 1" "1" "$(_liveness_next_count "$m_other_fp" "$fp_base")"
assert_eq "TC-LIVENESS-011b different fingerprint -> tier1 resets to 0" "0" "$(_liveness_next_tier1 "$m_other_fp" "$fp_base")"

m_tier1_latched=$(_liveness_marker 42 "$fp_base" 7 1)
assert_eq "TC-LIVENESS-012 same fingerprint, tier1=1 -> latch persists" "1" "$(_liveness_next_tier1 "$m_tier1_latched" "$fp_base")"

assert_eq "TC-LIVENESS-013a malformed marker -> count parses to 0 (next=1)" "1" "$(_liveness_next_count "garbage not a marker {{{" "$fp_base")"
assert_eq "TC-LIVENESS-013b malformed marker -> tier1 parses to 0" "0" "$(_liveness_next_tier1 "garbage not a marker {{{" "$fp_base")"

m_roundtrip=$(_liveness_marker 99 "abc123" 4 1)
assert_eq "TC-LIVENESS-014a marker round-trip: issue+fingerprint+count" "4" "$(_liveness_parse_marker "$m_roundtrip" "abc123" count)"
assert_eq "TC-LIVENESS-014b marker round-trip: tier1" "1" "$(_liveness_parse_marker "$m_roundtrip" "abc123" tier1)"

# TC-LIVENESS-015: fingerprint change at tick 10 -> full reset, no tier-2 —
# covered end-to-end in Group F (TC-LIVENESS-041) via _liveness_evaluate_issue.

# ===========================================================================
echo
echo "=== TC-LIVENESS-016..022: tier action selection (pure) ==="
# ===========================================================================

assert_eq "TC-LIVENESS-016 count < notice -> none" "none" "$(_liveness_tier_action 5 0 6 18)"
assert_eq "TC-LIVENESS-017 count == notice, tier1=0 -> tier1" "tier1" "$(_liveness_tier_action 6 0 6 18)"
assert_eq "TC-LIVENESS-018 count == notice, tier1=1 (already fired) -> none" "none" "$(_liveness_tier_action 6 1 6 18)"
assert_eq "TC-LIVENESS-019 notice < count < stall, tier1=1 -> none" "none" "$(_liveness_tier_action 10 1 6 18)"
assert_eq "TC-LIVENESS-020 count == stall -> tier2" "tier2" "$(_liveness_tier_action 18 1 6 18)"
assert_eq "TC-LIVENESS-021 count > stall (missed tick) -> tier2" "tier2" "$(_liveness_tier_action 25 1 6 18)"
assert_eq "TC-LIVENESS-022 count == stall but tier1=0 -> tier2 (unconditional)" "tier2" "$(_liveness_tier_action 18 0 6 18)"

# ===========================================================================
echo
echo "=== TC-LIVENESS-023..030: threshold config validation ==="
# ===========================================================================

unset LIVENESS_NOTICE_TICKS LIVENESS_STALL_TICKS
assert_eq "TC-LIVENESS-023 LIVENESS_NOTICE_TICKS unset -> defaults to 6" "6" "$(_liveness_notice_ticks 2>/dev/null)"
assert_eq "TC-LIVENESS-024 LIVENESS_STALL_TICKS unset -> defaults to 18" "18" "$(_liveness_stall_ticks 6 2>/dev/null)"

LIVENESS_NOTICE_TICKS="banana"
warn_out=$(_liveness_notice_ticks 2>&1 1>/dev/null)
val_out=$(_liveness_notice_ticks 2>/dev/null)
assert_eq "TC-LIVENESS-025a non-numeric notice falls back to 6" "6" "$val_out"
assert_contains "TC-LIVENESS-025b non-numeric notice logs a warning" "$warn_out" "WARNING"
unset LIVENESS_NOTICE_TICKS

LIVENESS_NOTICE_TICKS="1"
warn_out=$(_liveness_notice_ticks 2>&1 1>/dev/null)
val_out=$(_liveness_notice_ticks 2>/dev/null)
assert_eq "TC-LIVENESS-026a notice=1 (below floor) falls back to 6" "6" "$val_out"
assert_contains "TC-LIVENESS-026b notice=1 logs a warning" "$warn_out" "WARNING"
unset LIVENESS_NOTICE_TICKS

LIVENESS_STALL_TICKS="6"
warn_out=$(_liveness_stall_ticks 6 2>&1 1>/dev/null)
val_out=$(_liveness_stall_ticks 6 2>/dev/null)
assert_eq "TC-LIVENESS-027a stall==notice falls back to default 18" "18" "$val_out"
assert_contains "TC-LIVENESS-027b stall==notice logs a warning" "$warn_out" "WARNING"
unset LIVENESS_STALL_TICKS

# [codex review, PR #472, BLOCKING] regression pin: stall < notice must fall
# back to the documented default 18, NOT clamp to notice+1 (11) — a
# misconfigured pair is a config error, not a near-miss to nudge.
LIVENESS_STALL_TICKS="3"
warn_out=$(_liveness_stall_ticks 10 2>&1 1>/dev/null)
val_out=$(_liveness_stall_ticks 10 2>/dev/null)
assert_eq "TC-LIVENESS-027c stall<notice falls back to default 18, not notice+1" "18" "$val_out"
assert_contains "TC-LIVENESS-027d stall<notice logs a warning" "$warn_out" "WARNING"
unset LIVENESS_STALL_TICKS

# Regression pin: a validly-configured notice_ticks >= 18 means the default
# 18 no longer satisfies `stall > notice` either — the fallback must escalate
# to notice+1 in THIS case (unlike the two cases above), or the function
# would return an inverted pair to every caller.
unset LIVENESS_STALL_TICKS
warn_out=$(_liveness_stall_ticks 20 2>&1 1>/dev/null)
val_out=$(_liveness_stall_ticks 20 2>/dev/null)
assert_eq "TC-LIVENESS-027e notice>=18 unset stall escalates past the default to notice+1" "21" "$val_out"
assert_contains "TC-LIVENESS-027f notice>=18 unset stall logs a warning" "$warn_out" "WARNING"

# [pr-review-toolkit:code-reviewer self-review] pin the exact escalation
# pivot: notice=17 must still keep the clean default 18 (no warning), while
# notice=18 must escalate to 19 WITH a warning — the tie case. Without this,
# a future `-le` -> `-lt` typo on the escalation check would slip through.
unset LIVENESS_STALL_TICKS
assert_eq "TC-LIVENESS-027g notice=17 (just below pivot) keeps clean default 18" \
  "18" "$(_liveness_stall_ticks 17 2>/dev/null)"
assert_eq "TC-LIVENESS-027h notice=17 keeps default with no warning" \
  "" "$(_liveness_stall_ticks 17 2>&1 1>/dev/null)"
assert_eq "TC-LIVENESS-027i notice=18 (tie at pivot) escalates to 19" \
  "19" "$(_liveness_stall_ticks 18 2>/dev/null)"
assert_contains "TC-LIVENESS-027j notice=18 escalation logs a warning" \
  "$(_liveness_stall_ticks 18 2>&1 1>/dev/null)" "WARNING"

LIVENESS_NOTICE_TICKS="6"; LIVENESS_STALL_TICKS="18"
notice_out=$(_liveness_notice_ticks 2>/dev/null)
warn_out=$(_liveness_stall_ticks "$notice_out" 2>&1 1>/dev/null)
val_out=$(_liveness_stall_ticks "$notice_out" 2>/dev/null)
assert_eq "TC-LIVENESS-028a valid notice=6/stall=18 honored verbatim" "18" "$val_out"
assert_eq "TC-LIVENESS-028b valid config logs no warning" "" "$warn_out"
unset LIVENESS_NOTICE_TICKS LIVENESS_STALL_TICKS

assert_eq "TC-LIVENESS-029 invalid threshold warning does not corrupt the captured numeric value" \
  "6" "$(LIVENESS_NOTICE_TICKS="bogus" bash -c 'source "'"$LIB"'"; _liveness_notice_ticks 2>/dev/null')"

# ===========================================================================
echo
echo "=== TC-LIVENESS-030: LIVENESS_WATCHDOG_ENABLED=false ==="
# ===========================================================================

_trace_reset
log() { :; }
list_pending_dev() { _rec list_pending_dev; printf '%s' '[{"number":99,"labels":["autonomous","pending-dev"]}]'; }
list_pending_review() { _rec list_pending_review; printf '%s' '[]'; }
LIVENESS_WATCHDOG_ENABLED=false run_liveness_watchdog
assert_eq "TC-LIVENESS-030a disabled -> list_pending_dev never called" "0" "$(_trace_verbs | grep -c '^list_pending_dev$')"
assert_eq "TC-LIVENESS-030b disabled -> list_pending_review never called" "0" "$(_trace_verbs | grep -c '^list_pending_review$')"
unset LIVENESS_WATCHDOG_ENABLED

# ===========================================================================
echo
echo "=== TC-LIVENESS-031..037: exemptions ==="
# ===========================================================================

_reset_stubs() {
  _trace_reset
  was_just_dispatched() { _rec was_just_dispatched "$@"; return 1; }
  is_within_grace_period() { _rec is_within_grace_period "$@"; return 1; }
  _dispatch_marker_recent() { _rec _dispatch_marker_recent "$@"; return 1; }
  pid_alive() { _rec pid_alive "$@"; return 1; }
  log() { :; }
  fetch_pr_for_issue() { _rec fetch_pr_for_issue "$@"; printf '%s' '{"headRefOid":"sha-A"}'; }
  itp_list_comments() { _rec itp_list_comments "$@"; printf '%s' '[]'; }
  itp_read_task() { _rec itp_read_task "$@"; printf '%s' '{"labels":["pending-dev"]}'; }
  itp_post_comment() { _rec itp_post_comment "$@"; }
  label_swap() { _rec label_swap "$@"; }
}

_reset_stubs
was_just_dispatched() { return 0; }
_liveness_evaluate_issue 99 issue pending-dev 6 18
assert_eq "TC-LIVENESS-031 JUST_DISPATCHED -> zero I/O beyond the check itself" "0" "$(_trace_verbs | grep -c '^itp_post_comment$')"

_reset_stubs
is_within_grace_period() { return 0; }
_liveness_evaluate_issue 99 issue pending-dev 6 18
assert_eq "TC-LIVENESS-032 grace period -> zero comment posts" "0" "$(_trace_verbs | grep -c '^itp_post_comment$')"

_reset_stubs
pid_alive() { return 0; }
_liveness_evaluate_issue 99 issue pending-dev 6 18
assert_eq "TC-LIVENESS-033 live dev wrapper -> not counted (zero comment posts)" "0" "$(_trace_verbs | grep -c '^itp_post_comment$')"

_reset_stubs
pid_alive() { return 0; }
_liveness_evaluate_issue 99 review pending-review 6 18
assert_eq "TC-LIVENESS-034 live review wrapper -> not counted" "0" "$(_trace_verbs | grep -c '^itp_post_comment$')"

_reset_stubs
_dispatch_marker_recent() { return 0; }
_liveness_evaluate_issue 99 issue pending-dev 6 18
assert_eq "TC-LIVENESS-035 fresh dispatch marker -> not counted" "0" "$(_trace_verbs | grep -c '^itp_post_comment$')"
assert_eq "TC-LIVENESS-035b pid_alive never consulted once the marker check hits" "0" "$(_trace_verbs | grep -c '^pid_alive$')"

_reset_stubs
itp_list_comments() { return 1; }
_liveness_evaluate_issue 99 issue pending-dev 6 18
assert_eq "TC-LIVENESS-036 itp_list_comments transient failure -> zero comment posts" "0" "$(_trace_verbs | grep -c '^itp_post_comment$')"

# TC-LIVENESS-037 (approved/stalled label exclusion) is structural —
# list_pending_dev/list_pending_review already exclude those labels, so
# run_liveness_watchdog never even calls _liveness_evaluate_issue for them.
# Pinned via a source-of-truth grep against lib-dispatch.sh (where the
# orchestration lives, NOT lib-liveness.sh): run_liveness_watchdog delegates
# candidate selection entirely to the pre-existing selectors.
lib_dispatch_src=$(cat "$LIB_DISPATCH")
assert_contains "TC-LIVENESS-037 run_liveness_watchdog delegates to list_pending_dev" "$lib_dispatch_src" "pending_dev=\$(list_pending_dev)"
assert_contains "TC-LIVENESS-037b run_liveness_watchdog delegates to list_pending_review" "$lib_dispatch_src" "pending_review=\$(list_pending_review)"

# ===========================================================================
echo
echo "=== TC-LIVENESS-038..044: two-tier sequence + race + forgery ==="
# ===========================================================================

_reset_stubs
FP=$(_liveness_fingerprint pending-dev sha-A 0 "")
_seq_comments='[]'
itp_list_comments() { printf '%s' "$_seq_comments"; }
itp_post_comment() { _rec itp_post_comment "$@"; _seq_comments=$(jq --arg b "$2" '. + [{"authorKind":"bot","createdAt":"2026-01-01T00:00:00Z","body":$b}]' <<<"$_seq_comments"); }
label_swap() { _rec label_swap "$@"; }
itp_read_task() { printf '%s' '{"labels":["pending-dev"]}'; }

for _t in $(seq 1 6); do
  _liveness_evaluate_issue 99 issue pending-dev 6 18
done
tier1_count=$(jq '[.[] | select(.body | contains("reason=liveness-no-progress"))] | length' <<<"$_seq_comments")
assert_eq "TC-LIVENESS-038 6 no-op ticks -> tier-1 comment posted exactly once" "1" "$tier1_count"
assert_no_match "TC-LIVENESS-038b no label_swap yet" "^label_swap" "$(_trace_all)"

# TC-LIVENESS-038c/d [operator guidance, round 6]: the tier-1 report is now a
# SEPARATE comment from the bare marker — the report body itself no longer
# starts with the marker's `<!--` prefix (it starts with the human-readable
# "No observable progress" text), and a distinct bare-marker comment exists
# in the same tick's output.
tier1_report_body=$(jq -r '[.[] | select(.body | contains("reason=liveness-no-progress"))] | last | .body' <<<"$_seq_comments")
assert_no_match "TC-LIVENESS-038c tier-1 report body does NOT start with the marker prefix (split into two comments)" \
  "^<!-- dispatcher-liveness-watchdog:" "$tier1_report_body"
bare_marker_count_at_tick6=$(jq --arg fp "$FP" '[.[] | select(.body | test("^<!-- dispatcher-liveness-watchdog: issue=99 fingerprint=" + $fp + " count=6 tier1=1 -->[[:space:]]*$"))] | length' <<<"$_seq_comments")
assert_eq "TC-LIVENESS-038d a distinct bare tier1=1 marker comment exists alongside the tier-1 report" "1" "$bare_marker_count_at_tick6"

_liveness_evaluate_issue 99 issue pending-dev 6 18
tier1_count_after=$(jq '[.[] | select(.body | contains("reason=liveness-no-progress"))] | length' <<<"$_seq_comments")
assert_eq "TC-LIVENESS-039 tick 7 (tier1 already fired) -> no second tier-1 comment" "1" "$tier1_count_after"

for _t in $(seq 8 18); do
  _liveness_evaluate_issue 99 issue pending-dev 6 18
done
tier2_count=$(jq '[.[] | select(.body | contains("reason=liveness-timeout"))] | length' <<<"$_seq_comments")
assert_eq "TC-LIVENESS-040a 18 no-op ticks -> exactly one reason=liveness-timeout report" "1" "$tier2_count"
assert_match "TC-LIVENESS-040b stalled transition performed" "^label_swap${US}99${US}pending-dev${US}stalled$" "$(_trace_all)"

# TC-LIVENESS-040e/f/g [operator guidance, round 6]: same split for tier 2 —
# the trip report is a separate comment from the bare marker, and the marker
# is posted BEFORE the report in the SAME evaluation's post ORDER (array
# index, not createdAt — the test stub stamps every posted comment with an
# identical fixed createdAt, so index is the only signal available here; the
# real itp_post_comment leaf timestamps each call with the actual post time).
# Post order matters: it is what makes the NEXT tick's cutoff-scan exclude
# the count=18 marker without depending on a same-second timestamp tie.
tier2_report_body=$(jq -r '[.[] | select(.body | contains("reason=liveness-timeout"))] | last | .body' <<<"$_seq_comments")
assert_no_match "TC-LIVENESS-040e tier-2 report body does NOT start with the marker prefix (split into two comments)" \
  "^<!-- dispatcher-liveness-watchdog:" "$tier2_report_body"
bare_marker_count_at_tick18=$(jq --arg fp "$FP" '[.[] | select(.body | test("^<!-- dispatcher-liveness-watchdog: issue=99 fingerprint=" + $fp + " count=18 tier1=1 -->[[:space:]]*$"))] | length' <<<"$_seq_comments")
assert_eq "TC-LIVENESS-040f a distinct bare count=18 marker comment exists alongside the tier-2 report" "1" "$bare_marker_count_at_tick18"
marker_then_report=$(jq --arg fp "$FP" '
  ([to_entries[] | select(.value.body | test("^<!-- dispatcher-liveness-watchdog: issue=99 fingerprint=" + $fp + " count=18 tier1=1 -->[[:space:]]*$")) | .key] | last) as $mi
  | ([to_entries[] | select(.value.body | contains("reason=liveness-timeout")) | .key] | last) as $ri
  | $mi < $ri
' <<<"$_seq_comments")
assert_eq "TC-LIVENESS-040g the count=18 marker is posted BEFORE the trip report in this evaluation" "true" "$marker_then_report"

# TC-LIVENESS-040c/d: pending-review mirror — the OTHER new declared movement
# (liveness-watchdog-stall-pending-review) must actually fire, not just be
# spec-drift-covered as a declared transition.
_reset_stubs
_seq_pr_comments='[]'
itp_list_comments() { printf '%s' "$_seq_pr_comments"; }
itp_post_comment() { _rec itp_post_comment "$@"; _seq_pr_comments=$(jq --arg b "$2" '. + [{"authorKind":"bot","createdAt":"2026-01-01T00:00:00Z","body":$b}]' <<<"$_seq_pr_comments"); }
label_swap() { _rec label_swap "$@"; }
itp_read_task() { printf '%s' '{"labels":["pending-review"]}'; }
for _t in $(seq 1 18); do
  _liveness_evaluate_issue 99 review pending-review 6 18
done
tier2_pr_count=$(jq '[.[] | select(.body | contains("reason=liveness-timeout"))] | length' <<<"$_seq_pr_comments")
assert_eq "TC-LIVENESS-040c pending-review: 18 no-op ticks -> exactly one reason=liveness-timeout report" "1" "$tier2_pr_count"
assert_match "TC-LIVENESS-040d pending-review: stalled transition performed" "^label_swap${US}99${US}pending-review${US}stalled$" "$(_trace_all)"

# TC-LIVENESS-041: fingerprint change at tick 10 -> full reset, no tier-2.
_reset_stubs
_seq2_comments='[]'
_head2='sha-A'
itp_list_comments() { printf '%s' "$_seq2_comments"; }
itp_post_comment() { _seq2_comments=$(jq --arg b "$2" '. + [{"authorKind":"bot","createdAt":"2026-01-01T00:00:00Z","body":$b}]' <<<"$_seq2_comments"); }
fetch_pr_for_issue() { printf '%s' "{\"headRefOid\":\"${_head2}\"}"; }
label_swap() { _rec label_swap "$@"; }
itp_read_task() { printf '%s' '{"labels":["pending-dev"]}'; }

for _t in $(seq 1 9); do
  _liveness_evaluate_issue 99 issue pending-dev 6 18
done
_head2='sha-B'
for _t in $(seq 10 20); do
  _liveness_evaluate_issue 99 issue pending-dev 6 18
done
tier2_count2=$(jq '[.[] | select(.body | contains("reason=liveness-timeout"))] | length' <<<"$_seq2_comments")
assert_eq "TC-LIVENESS-041 fingerprint change at tick 10 -> full reset, NO tier-2 reached by tick 20" "0" "$tier2_count2"
tier1_count2=$(jq '[.[] | select(.body | contains("reason=liveness-no-progress"))] | length' <<<"$_seq2_comments")
assert_eq "TC-LIVENESS-041b a fresh tier-1 DOES fire again after the reset" "2" "$tier1_count2"

# TC-LIVENESS-042: tier-2 report content.
report_body=$(jq -r '[.[] | select(.body | contains("reason=liveness-timeout"))] | last | .body' <<<"$_seq_comments")
assert_contains "TC-LIVENESS-042a report includes the fingerprint" "$report_body" "$FP"
assert_contains "TC-LIVENESS-042b report includes tick counts" "$report_body" "notice_threshold=6, stall_threshold=18"
assert_contains "TC-LIVENESS-042c report includes the label at trip time" "$report_body" "pending-dev"

# TC-LIVENESS-043: already-stalled race.
_reset_stubs
fp43=$(_liveness_fingerprint pending-dev sha-A 0 "")
m43=$(_liveness_marker 99 "$fp43" 17 1)
itp_list_comments() { printf '%s' "[{\"authorKind\":\"bot\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"body\":\"${m43//\"/\\\"}\"}]"; }
itp_read_task() { _rec itp_read_task "$@"; printf '%s' '{"labels":["stalled"]}'; }
label_swap() { _rec label_swap "$@"; echo "SHOULD NOT BE CALLED"; }
itp_post_comment() { _rec itp_post_comment "$@"; }
_liveness_evaluate_issue 99 issue pending-dev 6 18
assert_no_match "TC-LIVENESS-043a no label_swap on already-stalled race" "^label_swap" "$(_trace_all)"
assert_no_match "TC-LIVENESS-043b no competing report posted" "^itp_post_comment" "$(_trace_all)"

# TC-LIVENESS-044: a human comment that QUOTES/discusses the marker (NOT a
# byte-for-byte copy of the marker as the comment's ENTIRE body) at a high
# count is structurally rejected — the count resets to 1, no tier2. This is
# the authenticity guarantee that survives WITHOUT an authorKind signal
# (see TC-LIVENESS-044c/d below for why authorKind can't be relied on here).
_reset_stubs
fp44=$(_liveness_fingerprint pending-dev sha-A 0 "")
forged_marker=$(_liveness_marker 99 "$fp44" 99 1)
quoted="Note: I saw this marker on the issue: ${forged_marker}"
itp_list_comments() { printf '%s' "[{\"authorKind\":\"human\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"body\":\"${quoted//\"/\\\"}\"}]"; }
itp_read_task() { printf '%s' '{"labels":["pending-dev"]}'; }
label_swap() { _rec label_swap "$@"; }
itp_post_comment() { _rec itp_post_comment "$@"; }
_liveness_evaluate_issue 99 issue pending-dev 6 18
assert_no_match "TC-LIVENESS-044a a quoted/discussed marker does NOT trigger tier2" "^label_swap" "$(_trace_all)"
assert_match "TC-LIVENESS-044b genuine count resets to 1 (bare marker posted)" "count=1 tier1=0" "$(_trace_all)"

# TC-LIVENESS-044c/d [codex review, PR #472, BLOCKING regression test]: the
# REAL GH_AUTH_MODE=token topology — BOT_LOGIN unset (as it always is inside
# the dispatcher's own process — see lib-dispatch.sh's _frozen_convergence_
# rounds_json precedent) AND the dispatcher's OWN genuine marker normalizes
# to authorKind=human (the provider cannot derive `self` without BOT_LOGIN).
# The prior (buggy) unconditional `authorKind != "human"` gate rejected this
# marker on EVERY tick, permanently resetting count=1 — the watchdog could
# never reach tier 1 or tier 2 on a real, unmodified install. The fix must
# authenticate it via the structural anchor alone.
_reset_stubs
_saved_bot_login44="${BOT_LOGIN:-}"; unset BOT_LOGIN
fp44cd=$(_liveness_fingerprint pending-dev sha-A 0 "")
genuine44=$(_liveness_marker 99 "$fp44cd" 3 0)
itp_list_comments() { printf '%s' "[{\"authorKind\":\"human\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"body\":\"${genuine44//\"/\\\"}\"}]"; }
itp_read_task() { printf '%s' '{"labels":["pending-dev"]}'; }
label_swap() { _rec label_swap "$@"; }
itp_post_comment() { _rec itp_post_comment "$@"; }
_liveness_evaluate_issue 99 issue pending-dev 6 18
assert_match "TC-LIVENESS-044c BOT_LOGIN unset + genuine authorKind=human marker -> count STILL increments (4)" "count=4 tier1=0" "$(_trace_all)"
assert_no_match "TC-LIVENESS-044d not yet at notice threshold -> no tier1 comment beyond the bare marker" "TIER1REPORT|no observable progress" "$(_trace_all)"
if [ -n "$_saved_bot_login44" ]; then BOT_LOGIN="$_saved_bot_login44"; fi

# ===========================================================================
echo
echo "=== TC-LIVENESS-046..049: prior-marker cutoff (resume-after-un-stall) ==="
# ===========================================================================
# [codex review, PR #472, BLOCKING #2] Without a cutoff, an operator who fixes
# the park and removes `stalled` (re-arming via Step 2) with an
# otherwise-unchanged fingerprint would have the very next evaluation read the
# OLD trip report's marker back (high count, tier1=1) and immediately re-trip
# tier 2 again. Production always posts the bare marker STRICTLY BEFORE the
# trip report as two separate comments (round 6; see TC-040e/f/g and
# TC-045i/j) — these fixtures model that exact two-comment shape (marker at an
# earlier timestamp, report — whose body starts with the real
# `_LIVENESS_TIER2_HEADING` — at a later or equal one) so the cutoff-then-scan
# logic is pinned against the real producer shape, not a synthetic embed.
# These are BEHAVIORAL tests with constructed fixtures — not wiring greps —
# so a mutation on the cutoff comparison (e.g. `>` -> `>=`) or the heading
# constant itself actually fails a test.

fp46=$(_liveness_fingerprint pending-dev sha-A 0 "")
trip_marker46=$(_liveness_marker 99 "$fp46" 18 1)
# One trip-report body shared by every fixture in this section (TC-046/047/049/
# 050): a body that STARTS WITH the real `_LIVENESS_TIER2_HEADING`, so the
# cutoff `startswith($heading)` scan treats it as a genuine trip. `_reset_stubs`
# (called before TC-049) only rebinds functions, never unsets variables, so this
# survives across it.
trip_report_body="${_LIVENESS_TIER2_HEADING} (\`reason=liveness-timeout\`, [INV-128])"$'\n\nEvidence...'

# TC-LIVENESS-046: the crux self-referential case — a constructed fixture with
# the bare marker (count=18) at T1a and the trip report (whose body starts
# with the real heading) at T1b >= T1a, mirroring the marker-before-report
# post order the production code always uses within one evaluation. Without
# the cutoff, the next evaluation on the SAME (post-resume, unchanged)
# fingerprint would read that T1a marker back and immediately re-trip.
comments46=$(jq -n --arg m "$trip_marker46" --arg r "$trip_report_body" '
  [{"authorKind":"bot","createdAt":"2026-01-01T09:59:59Z","body":$m},
   {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":$r}]
')
assert_eq "TC-LIVENESS-046 trip report's own preceding marker is excluded — no qualifying prior marker right after a trip" "" \
  "$(_liveness_prior_marker "$comments46" 0)"
assert_eq "TC-LIVENESS-046b feeding that into _liveness_next_count starts a FRESH series (1), not a re-trip (19)" "1" \
  "$(_liveness_next_count "$(_liveness_prior_marker "$comments46" 0)" "$fp46")"

# TC-LIVENESS-047: a genuinely POST-resume marker (T2 > T1b, the trip report's
# timestamp) DOES qualify — resuming after removing `stalled` must start a
# fresh series that then continues counting normally, not stay permanently
# excluded.
post_resume_marker47=$(_liveness_marker 99 "$fp46" 2 0)
comments47=$(jq -n --arg m "$trip_marker46" --arg r "$trip_report_body" --arg p "$post_resume_marker47" '
  [{"authorKind":"bot","createdAt":"2026-01-01T09:59:59Z","body":$m},
   {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":$r},
   {"authorKind":"bot","createdAt":"2026-01-01T12:00:00Z","body":$p}]
')
assert_eq "TC-LIVENESS-047a post-resume marker qualifies (strictly after the trip report)" \
  "$post_resume_marker47" "$(_liveness_prior_marker "$comments47" 0)"
assert_eq "TC-LIVENESS-047b feeding that marker into _liveness_next_count continues the fresh post-resume series (3)" "3" \
  "$(_liveness_next_count "$(_liveness_prior_marker "$comments47" 0)" "$fp46")"

# TC-LIVENESS-048: no trip has ever happened — cutoff is the epoch, the only
# marker still qualifies (unchanged pre-fix behavior for the common case).
comments48=$(jq -n --arg m "$post_resume_marker47" '
  [{"authorKind":"bot","createdAt":"2026-01-01T09:00:00Z","body":$m}]
')
assert_eq "TC-LIVENESS-048 no-trip case: cutoff is the epoch, the only marker still qualifies" \
  "$post_resume_marker47" "$(_liveness_prior_marker "$comments48" 0)"

# TC-LIVENESS-049: full end-to-end re-arm sequence through
# _liveness_evaluate_issue itself (not just the pure helper) — an issue whose
# tier-2 report already fired, then a human removes `stalled` restoring
# `pending-dev` with the SAME fingerprint, must NOT immediately re-transition
# to stalled on the next tick; it must restart the count at 1.
_reset_stubs
fp49=$(_liveness_fingerprint pending-dev sha-A 0 "")
trip_marker49=$(_liveness_marker 99 "$fp49" 18 1)
_seq49_comments=$(jq -n --arg m "$trip_marker49" --arg r "$trip_report_body" '
  [{"authorKind":"bot","createdAt":"2026-01-01T09:59:59Z","body":$m},
   {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":$r}]
')
itp_list_comments() { printf '%s' "$_seq49_comments"; }
itp_post_comment() { _rec itp_post_comment "$@"; _seq49_comments=$(jq --arg b "$2" '. + [{"authorKind":"bot","createdAt":"2026-01-01T11:00:00Z","body":$b}]' <<<"$_seq49_comments"); }
fetch_pr_for_issue() { printf '%s' '{"headRefOid":"sha-A"}'; }
label_swap() { _rec label_swap "$@"; }
itp_read_task() { printf '%s' '{"labels":["pending-dev"]}'; }
_liveness_evaluate_issue 99 issue pending-dev 6 18
assert_no_match "TC-LIVENESS-049a re-armed issue does NOT immediately re-transition to stalled" "^label_swap" "$(_trace_all)"
assert_match "TC-LIVENESS-049b re-armed issue restarts the count at 1 (fresh episode)" "count=1 tier1=0" "$(_trace_all)"

# TC-LIVENESS-050 [pr-test-analyzer gap]: a SECOND trip-resume cycle — the
# cutoff must track the LATEST trip report, not the FIRST. History: trip #1
# at T1 (marker+report), a post-resume marker at T2, trip #2 at T3
# (marker+report), then nothing after T3. If the cutoff computation regressed
# from `max` to `min`/`first`, T3's cutoff would incorrectly equal T1, and the
# T2 post-resume marker (T2 < T3) would wrongly qualify as "the prior marker"
# even though it is now BEFORE the second trip.
trip_marker50a=$(_liveness_marker 99 "$fp46" 18 1)
post_resume_marker50=$(_liveness_marker 99 "$fp46" 5 0)
trip_marker50b=$(_liveness_marker 99 "$fp46" 18 1)
comments50=$(jq -n --arg m1 "$trip_marker50a" --arg r "$trip_report_body" --arg p "$post_resume_marker50" --arg m2 "$trip_marker50b" '
  [{"authorKind":"bot","createdAt":"2026-01-01T09:59:59Z","body":$m1},
   {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":$r},
   {"authorKind":"bot","createdAt":"2026-01-01T12:00:00Z","body":$p},
   {"authorKind":"bot","createdAt":"2026-01-01T13:59:59Z","body":$m2},
   {"authorKind":"bot","createdAt":"2026-01-01T14:00:00Z","body":$r}]
')
assert_eq "TC-LIVENESS-050 second trip cycle: cutoff tracks the LATEST trip (T3), not the first (T1) — no qualifying marker after T3" "" \
  "$(_liveness_prior_marker "$comments50" 0)"

# TC-LIVENESS-059 [round 7 regression pin]: the round-6 unanchored
# `contains("Liveness watchdog tripped")` cutoff detection let a human
# comment that merely MENTIONS the phrase — anywhere in its body, with no
# report structure — falsely register as a trip and become the cutoff,
# excluding the genuine earlier marker and permanently resetting a frozen
# issue's series to count=1. Pin the fix: a human comment quoting/discussing
# the phrase (not starting with the exact heading) must NOT act as a cutoff —
# the earlier genuine marker must still qualify.
fp59=$(_liveness_fingerprint pending-dev sha-A 0 "")
genuine_marker59=$(_liveness_marker 99 "$fp59" 17 1)
forged_mention59="A collaborator can post or quote that phrase: ${_LIVENESS_TIER2_HEADING} — see the discussion above."
comments59=$(jq -n --arg m "$genuine_marker59" --arg f "$forged_mention59" '
  [{"authorKind":"human","createdAt":"2026-01-01T10:00:00Z","body":$m},
   {"authorKind":"human","createdAt":"2026-01-01T11:00:00Z","body":$f}]
')
assert_eq "TC-LIVENESS-059 a mid-comment mention of the trip heading does NOT act as a forged cutoff — the genuine earlier marker still qualifies" \
  "$genuine_marker59" "$(_liveness_prior_marker "$comments59" 0)"

# ===========================================================================
echo
echo "=== TC-LIVENESS-051..058 [operator guidance, round 6]: whole-body anchor, ==="
echo "=== app-mode authorKind gate, and count-cap defense-in-depth           ==="
# ===========================================================================

# TC-LIVENESS-051: the whole-body anchor rejects the OLD pre-round-6 shape —
# a marker followed by trailing report prose on later lines, with NO trip
# heading at all (so the cutoff logic can't be what's excluding it). Before
# round 6 this exact shape was the tier1/tier2 post itself and WAS accepted
# (`($|\n)` tolerated trailing content); after round 6 the marker is never
# posted with trailing prose in the same comment, so a comment shaped like
# the old embed must now be rejected outright — regression pin against a
# `[[:space:]]*$` -> `($|\n)` revert.
fp51=$(_liveness_fingerprint pending-dev sha-A 0 "")
old_style_embed51=$(_liveness_marker 99 "$fp51" 12 1)
comments51=$(jq -n --arg m "$old_style_embed51" '
  [{"authorKind":"bot","createdAt":"2026-01-01T09:00:00Z",
    "body":($m + "\nNo observable progress for 12 ticks — some other trailing prose, no trip heading")}]
')
assert_eq "TC-LIVENESS-051 whole-body anchor rejects a marker-plus-trailing-prose shape (the pre-round-6 embed)" "" \
  "$(_liveness_prior_marker "$comments51" 0)"

# TC-LIVENESS-052: the whole-body anchor STILL accepts the marker with only
# trailing whitespace/newline (GitHub commonly appends a trailing newline to
# posted comment bodies) — `[[:space:]]*$` must not be so strict it rejects
# the genuine bare-marker post itself.
bare52=$(_liveness_marker 99 "$fp51" 4 0)
comments52=$(jq -n --arg m "$bare52" '[{"authorKind":"bot","createdAt":"2026-01-01T09:00:00Z","body":($m + "\n")}]')
assert_eq "TC-LIVENESS-052 whole-body anchor still accepts the bare marker plus a trailing newline" "$bare52" \
  "$(_liveness_prior_marker "$comments52" 0)"

# TC-LIVENESS-053/054 [operator guidance, round 6]: GH_AUTH_MODE=app
# authorKind gate. In app mode the genuine wrapper posts under a GitHub App
# identity (authorKind=bot); a forged bare marker posted by a human collaborator
# must now be REJECTED in app mode specifically (closing the round-5 [BLOCKING]
# gap that a bare structural anchor alone cannot close) — WITHOUT reintroducing
# the round-2 [BLOCKING] token-mode-inert bug (TC-LIVENESS-044c/d above pin that
# the default/token mode is UNCHANGED).
_saved_gh_auth_mode53="${GH_AUTH_MODE:-}"

GH_AUTH_MODE=app
fp53=$(_liveness_fingerprint pending-dev sha-A 0 "")
forged_bare53=$(_liveness_marker 99 "$fp53" 17 1)
comments53=$(jq -n --arg m "$forged_bare53" '[{"authorKind":"human","createdAt":"2026-01-01T09:00:00Z","body":$m}]')
assert_eq "TC-LIVENESS-053 GH_AUTH_MODE=app: a forged bare marker from a human is rejected by the authorKind gate" "" \
  "$(_liveness_prior_marker "$comments53" "$(_liveness_strict_author_flag)")"

comments54=$(jq -n --arg m "$forged_bare53" '[{"authorKind":"bot","createdAt":"2026-01-01T09:00:00Z","body":$m}]')
assert_eq "TC-LIVENESS-054 GH_AUTH_MODE=app: the SAME bare marker from a bot/App identity is accepted" "$forged_bare53" \
  "$(_liveness_prior_marker "$comments54" "$(_liveness_strict_author_flag)")"

if [ -n "$_saved_gh_auth_mode53" ]; then GH_AUTH_MODE="$_saved_gh_auth_mode53"; else unset GH_AUTH_MODE; fi

# TC-LIVENESS-055: `_liveness_strict_author_flag` itself — the single source
# of truth the two call sites (_liveness_evaluate_issue's marker read,
# _liveness_marker_digest) both delegate to.
assert_eq "TC-LIVENESS-055a GH_AUTH_MODE unset -> token-mode default -> flag=0" "0" \
  "$(GH_AUTH_MODE= bash -c 'unset GH_AUTH_MODE; source "'"$LIB"'"; _liveness_strict_author_flag')"
assert_eq "TC-LIVENESS-055b GH_AUTH_MODE=token -> flag=0" "0" \
  "$(GH_AUTH_MODE=token bash -c 'source "'"$LIB"'"; _liveness_strict_author_flag')"
assert_eq "TC-LIVENESS-055c GH_AUTH_MODE=app -> flag=1" "1" \
  "$(GH_AUTH_MODE=app bash -c 'source "'"$LIB"'"; _liveness_strict_author_flag')"

# TC-LIVENESS-056/057 [operator guidance, round 6, defense-in-depth]: the
# _liveness_next_count cap. A forged marker at an absurd count must never
# propagate past LIVENESS_STALL_TICKS into the tier-action decision or the
# emitted marker text.
m56=$(_liveness_marker 99 "$fp_base" 999999 1)
assert_eq "TC-LIVENESS-056 an absurd stored count is capped at stall_ticks (18), not 1000000" "18" \
  "$(_liveness_next_count "$m56" "$fp_base" 18)"

assert_eq "TC-LIVENESS-057a without a stall_ticks arg, the increment is uncapped (back-compat for direct pure-helper use)" "1000000" \
  "$(_liveness_next_count "$m56" "$fp_base")"

# A count that would land BELOW stall_ticks after the +1 must be completely
# unaffected by the cap (the cap is a ceiling, not a floor or a rewrite).
m57=$(_liveness_marker 99 "$fp_base" 5 0)
assert_eq "TC-LIVENESS-057b a count that lands below stall_ticks after +1 is untouched by the cap" "6" \
  "$(_liveness_next_count "$m57" "$fp_base" 18)"

# TC-LIVENESS-058: end-to-end through _liveness_evaluate_issue — a forged
# bare marker at count=999999 on a FRESH (never-seen) fingerprint must still
# reset to count=1 (the anchor/fingerprint-match gate runs BEFORE the cap
# ever applies — the cap only bounds an ALREADY-matching series), proving the
# cap is genuinely defense-in-depth and not a replacement for the anchor.
_reset_stubs
fp58=$(_liveness_fingerprint pending-dev sha-A 0 "")
forged58=$(_liveness_marker 99 "different-fingerprint-entirely" 999999 1)
itp_list_comments() { printf '%s' "[{\"authorKind\":\"human\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"body\":\"${forged58//\"/\\\"}\"}]"; }
itp_read_task() { printf '%s' '{"labels":["pending-dev"]}'; }
label_swap() { _rec label_swap "$@"; }
itp_post_comment() { _rec itp_post_comment "$@"; }
_liveness_evaluate_issue 99 issue pending-dev 6 18
assert_no_match "TC-LIVENESS-058a a fingerprint-mismatched forged marker never causes an immediate tier2" "^label_swap" "$(_trace_all)"
assert_match "TC-LIVENESS-058b fingerprint mismatch resets to count=1 regardless of the forged marker's count" "count=1 tier1=0" "$(_trace_all)"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
