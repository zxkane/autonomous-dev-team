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

# [issue #473 UPDATE] Every genuine producer's grammar in
# `_LIVENESS_GRAMMARS_JSON` is now a WHOLE-BODY match, not a wrapped-token
# substring test — this fixture uses the GENUINE full-body `stale-verdict:`
# producer shape (lib-dispatch.sh's `_same_head_verdict_aware_recovery`),
# byte-matched from that call site, not a shortened parenthetical.
comments_baseline='[{"authorKind":"bot","body":"hello"}]'
stale_verdict_body006='PR #12 HEAD `sha-A` already reviewed with FAILED verdict; awaiting new commits before re-review. A dev wrapper appears to still be running for this issue, or a concurrent dispatcher tick is mid-dispatch — this is a transient wait, not a permanent park (`stale-verdict:sha-A`).'
comments_with_idempotent=$(jq -n --arg b "$stale_verdict_body006" '[{"authorKind":"bot","body":"hello"},{"authorKind":"bot","body":$b}]')
count_baseline=$(_liveness_non_idempotent_count "$comments_baseline")
count_with_idempotent=$(_liveness_non_idempotent_count "$comments_with_idempotent")
assert_eq "TC-LIVENESS-006 a new stale-verdict idempotent notice does NOT change the count component" "$count_baseline" "$count_with_idempotent"

comments_with_genuine='[{"authorKind":"bot","body":"hello"},{"authorKind":"bot","body":"a genuinely new update"}]'
count_with_genuine=$(_liveness_non_idempotent_count "$comments_with_genuine")
assert_eq "TC-LIVENESS-007 a genuinely new comment changes the count component" "2" "$count_with_genuine"

# [issue #473 UPDATE] The watchdog's own marker grammar requires the
# `tripped=<0|1>` field ([round 8] — see `_liveness_marker`'s docstring); the
# pre-round-8 fixture below omitted it, which the whole-body anchor now
# correctly rejects as non-canonical. Use `_liveness_marker` itself to build
# the fixture so it can never drift from the producer's actual grammar.
watchdog_marker008=$(_liveness_marker 1 abc 6 1 0)
comments_with_tier1=$(jq -n --arg b "$watchdog_marker008" '[{"authorKind":"bot","body":"hello"},{"authorKind":"bot","body":$b}]')
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
bare_marker_count_at_tick6=$(jq --arg fp "$FP" '[.[] | select(.body | test("^<!-- dispatcher-liveness-watchdog: issue=99 fingerprint=" + $fp + " count=6 tier1=1 tripped=0 -->[[:space:]]*$"))] | length' <<<"$_seq_comments")
assert_eq "TC-LIVENESS-038d a distinct bare tier1=1 tripped=0 marker comment exists alongside the tier-1 report" "1" "$bare_marker_count_at_tick6"

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
bare_marker_count_at_tick18=$(jq --arg fp "$FP" '[.[] | select(.body | test("^<!-- dispatcher-liveness-watchdog: issue=99 fingerprint=" + $fp + " count=18 tier1=1 tripped=1 -->[[:space:]]*$"))] | length' <<<"$_seq_comments")
assert_eq "TC-LIVENESS-040f a distinct bare count=18 tripped=1 marker comment exists alongside the tier-2 report" "1" "$bare_marker_count_at_tick18"
marker_then_report=$(jq --arg fp "$FP" '
  ([to_entries[] | select(.value.body | test("^<!-- dispatcher-liveness-watchdog: issue=99 fingerprint=" + $fp + " count=18 tier1=1 tripped=1 -->[[:space:]]*$")) | .key] | last) as $mi
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
# [codex review, PR #472, BLOCKING #2, then round 8 BLOCKING #1] Without a
# cutoff, an operator who fixes the park and removes `stalled` (re-arming via
# Step 2) with an otherwise-unchanged fingerprint would have the very next
# evaluation read the OLD trip marker back (high count, tier1=1) and
# immediately re-trip tier 2 again. [round 8] The cutoff is now the
# `tripped` FIELD on the marker's own already-authenticated, whole-body-
# anchored grammar — NOT a separately-typed heading-text pattern (rounds 6/7
# tried that twice; both were forgeable in GH_AUTH_MODE=token because the
# heading is prose, not part of the marker grammar). Production posts a
# `tripped=1` marker on the trip tick and `tripped=0` on every other tick
# (see `_liveness_evaluate_issue`'s `marker_tripped` assignment).

fp46=$(_liveness_fingerprint pending-dev sha-A 0 "")
trip_marker46=$(_liveness_marker 99 "$fp46" 18 1 1)
# One trip-report body shared by every fixture in this section (TC-046/047/049/
# 050) — purely operator-facing display text now (round 8): no detector reads
# it, so its exact content is irrelevant to what these fixtures pin, but it
# still models the real two-comment (marker, then report) producer shape.
trip_report_body="${_LIVENESS_TIER2_HEADING} (\`reason=liveness-timeout\`, [INV-128])"$'\n\nEvidence...'

# TC-LIVENESS-046: the crux self-referential case — a constructed fixture with
# the `tripped=1` marker at T1a and the trip report at T1b >= T1a, mirroring
# the marker-before-report post order production always uses within one
# evaluation. Without the cutoff, the next evaluation on the SAME
# (post-resume, unchanged) fingerprint would read that T1a marker back and
# immediately re-trip.
comments46=$(jq -n --arg m "$trip_marker46" --arg r "$trip_report_body" '
  [{"authorKind":"bot","createdAt":"2026-01-01T09:59:59Z","body":$m},
   {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":$r}]
')
assert_eq "TC-LIVENESS-046 the tripped=1 marker itself is excluded — no qualifying prior marker right after a trip" "" \
  "$(_liveness_prior_marker "$comments46" 0)"
assert_eq "TC-LIVENESS-046b feeding that into _liveness_next_count starts a FRESH series (1), not a re-trip (19)" "1" \
  "$(_liveness_next_count "$(_liveness_prior_marker "$comments46" 0)" "$fp46")"

# TC-LIVENESS-047: a genuinely POST-resume marker (T2 > T1a, the trip marker's
# own timestamp) DOES qualify — resuming after removing `stalled` must start a
# fresh series that then continues counting normally, not stay permanently
# excluded.
post_resume_marker47=$(_liveness_marker 99 "$fp46" 2 0 0)
comments47=$(jq -n --arg m "$trip_marker46" --arg r "$trip_report_body" --arg p "$post_resume_marker47" '
  [{"authorKind":"bot","createdAt":"2026-01-01T09:59:59Z","body":$m},
   {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":$r},
   {"authorKind":"bot","createdAt":"2026-01-01T12:00:00Z","body":$p}]
')
assert_eq "TC-LIVENESS-047a post-resume marker qualifies (strictly after the trip marker)" \
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
trip_marker49=$(_liveness_marker 99 "$fp49" 18 1 1)
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
assert_match "TC-LIVENESS-049b re-armed issue restarts the count at 1 (fresh episode)" "count=1 tier1=0 tripped=0" "$(_trace_all)"

# TC-LIVENESS-050 [pr-test-analyzer gap]: a SECOND trip-resume cycle — the
# cutoff must track the LATEST `tripped=1` marker, not the FIRST. History:
# trip #1 at T1 (marker+report), a post-resume marker at T2, trip #2 at T3
# (marker+report), then nothing after T3. If the cutoff computation regressed
# from `max` to `min`/`first`, T3's cutoff would incorrectly equal T1, and the
# T2 post-resume marker (T2 < T3) would wrongly qualify as "the prior marker"
# even though it is now BEFORE the second trip.
trip_marker50a=$(_liveness_marker 99 "$fp46" 18 1 1)
post_resume_marker50=$(_liveness_marker 99 "$fp46" 5 0 0)
trip_marker50b=$(_liveness_marker 99 "$fp46" 18 1 1)
comments50=$(jq -n --arg m1 "$trip_marker50a" --arg r "$trip_report_body" --arg p "$post_resume_marker50" --arg m2 "$trip_marker50b" '
  [{"authorKind":"bot","createdAt":"2026-01-01T09:59:59Z","body":$m1},
   {"authorKind":"bot","createdAt":"2026-01-01T10:00:00Z","body":$r},
   {"authorKind":"bot","createdAt":"2026-01-01T12:00:00Z","body":$p},
   {"authorKind":"bot","createdAt":"2026-01-01T13:59:59Z","body":$m2},
   {"authorKind":"bot","createdAt":"2026-01-01T14:00:00Z","body":$r}]
')
assert_eq "TC-LIVENESS-050 second trip cycle: cutoff tracks the LATEST trip (T3), not the first (T1) — no qualifying marker after T3" "" \
  "$(_liveness_prior_marker "$comments50" 0)"

# TC-LIVENESS-059 [round 7/8 regression pin]: rounds 6 and 7 anchored the
# cutoff to a separately-typed heading-text pattern (first `contains()`, then
# `startswith()`) — round 7 found `contains()` let a bare mid-comment mention
# of the phrase register as a forged trip; round 8 found `startswith()` was
# STILL forgeable (a comment merely OPENING with the exact heading also
# registered, with no real marker at all). The round-8 fix eliminates the
# free-text cutoff signal entirely: the cutoff now reads the `tripped` FIELD
# off the marker's own whole-body-anchored, structurally-authenticated
# grammar, so there is no separate prose pattern left for a human to forge.
# Pin BOTH historical forgery shapes here — a bare mid-comment mention, and a
# comment that opens with the exact heading — to prove neither can register
# as a cutoff anymore, regardless of the (now-decorative) heading text.
fp59=$(_liveness_fingerprint pending-dev sha-A 0 "")
genuine_marker59=$(_liveness_marker 99 "$fp59" 17 1 0)
forged_mid_mention59="A collaborator can post or quote that phrase: ${_LIVENESS_TIER2_HEADING} — see the discussion above."
forged_heading_open59="${_LIVENESS_TIER2_HEADING} (this comment merely OPENS with the heading — no real marker at all)"
comments59=$(jq -n --arg m "$genuine_marker59" --arg f1 "$forged_mid_mention59" --arg f2 "$forged_heading_open59" '
  [{"authorKind":"human","createdAt":"2026-01-01T10:00:00Z","body":$m},
   {"authorKind":"human","createdAt":"2026-01-01T11:00:00Z","body":$f1},
   {"authorKind":"human","createdAt":"2026-01-01T12:00:00Z","body":$f2}]
')
assert_eq "TC-LIVENESS-059 neither a mid-comment mention NOR a heading-opening forgery acts as a cutoff — the genuine earlier marker still qualifies" \
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

# ===========================================================================
echo
echo "=== TC-LIVENESS-060..064 [codex review, PR #472, round 8]: wrapper-anchored ==="
echo "=== idempotent/digest patterns and the PR-lookup transport-failure defer  ==="
# ===========================================================================
# [round 8 BLOCKING #2] Both _LIVENESS_IDEMPOTENT_PATTERN and
# _LIVENESS_DIGEST_PATTERN require a leading wrapper (backtick or HTML-comment
# opening) immediately before the token — a bare-prose mention must NOT match.
#
# [issue #473 UPDATE] TC-LIVENESS-060b/061b are REWRITTEN here: the
# whole-body conversion overturns the round-8/round-10 assumption that a
# CLOSED backtick/HTML-comment span around a token is sufficient — issue
# #473's own quoted-token-is-progress requirement is exactly "a human comment
# quoting `reason=liveness-timeout` in prose (even backtick-wrapped) must
# NOT be excluded from the count," so a merely wrapped token (060b) or a bare
# marker line with no report (061b) no longer match ANY grammar. The
# "genuinely CLOSED span, real producer shape, still matches" pin moves to
# TC-LIVENESS-082a/b below, now using an ACTUAL full-body producer report
# (not a bare wrapped token) — see that group's docstring.

assert_eq "TC-LIVENESS-060a a bare mid-prose mention of a token does NOT reduce the non-idempotent count" "1" \
  "$(_liveness_non_idempotent_count '[{"authorKind":"human","body":"I saw reason=liveness-timeout mentioned somewhere in prose"}]')"
assert_eq "TC-LIVENESS-060b [issue #473] a backtick-WRAPPED quote of the token (not the genuine full-body report) is NOT excluded — it counts as progress" "1" \
  "$(_liveness_non_idempotent_count '[{"authorKind":"human","body":"see `reason=liveness-timeout` for details"}]')"
assert_eq "TC-LIVENESS-061a a bare mid-prose mention of a marker grammar does NOT register in the digest" "" \
  "$(_liveness_marker_digest '[{"authorKind":"human","createdAt":"t","body":"quoting the marker: dispatcher-convergence-breaker: issue=1 head=abc"}]')"
assert_eq "TC-LIVENESS-061b [issue #473] a bare HTML-comment marker line with NO accompanying report (not the genuine whole-body producer shape) does NOT register in the digest" "" \
  "$(_liveness_marker_digest '[{"authorKind":"human","createdAt":"t","body":"<!-- dispatcher-convergence-breaker: issue=1 head=abc trailer=xyz session=s1 -->"}]')"
assert_eq "TC-LIVENESS-062 [issue #473] a BARE no-progress-substantive-attempt: marker (its genuine whole-body producer shape — a standalone HTML comment, unlike the OTHER grammars above) still registers in the digest" "no-progress-substantive-attempt:" \
  "$(_liveness_marker_digest '[{"authorKind":"human","createdAt":"t","body":"<!-- no-progress-substantive-attempt:sha session=abc -->"}]')"

# ===========================================================================
echo
echo "=== TC-LIVENESS-079..083 [codex review, PR #472, round 10 BLOCKING]: ==="
echo "=== the wrapper anchor now requires the CLOSING delimiter too, not   ==="
echo "=== just the opening one                                              ==="
# ===========================================================================
# [round 10] The round-8 pattern required only an OPENING backtick or
# `<!--` immediately before the token, with no requirement that the span
# ever CLOSE — an unclosed backtick/HTML-comment opening still satisfied it.
# Pin both directions of that gap now closed: an unclosed span must NOT
# reduce the count and must NOT register in the digest, while a genuinely
# closed span (the real producer shape) still does both, unchanged.

assert_eq "TC-LIVENESS-079a an UNCLOSED backtick span does NOT reduce the non-idempotent count" "1" \
  "$(_liveness_non_idempotent_count '[{"authorKind":"human","body":"I saw `reason=liveness-timeout mentioned somewhere, never closed"}]')"
assert_eq "TC-LIVENESS-079b an UNCLOSED HTML-comment opening does NOT reduce the non-idempotent count" "1" \
  "$(_liveness_non_idempotent_count '[{"authorKind":"human","body":"I saw a <!-- dispatcher-token: mentioned in the logs"}]')"
assert_eq "TC-LIVENESS-080a an UNCLOSED backtick span does NOT register in the digest" "" \
  "$(_liveness_marker_digest '[{"authorKind":"human","createdAt":"t","body":"quoting the marker: `dispatcher-convergence-breaker: issue=1 head=abc, never closed"}]')"
assert_eq "TC-LIVENESS-080b an UNCLOSED HTML-comment opening does NOT register in the digest" "" \
  "$(_liveness_marker_digest '[{"authorKind":"human","createdAt":"t","body":"I saw <!-- dispatcher-token: mentioned, but never closed the comment"}]')"
assert_eq "TC-LIVENESS-081 a backtick span that closes only after a newline (not a real Markdown code span) is still rejected" "1" \
  "$(_liveness_non_idempotent_count '[{"authorKind":"human","body":"`dispatcher-token: abc\nstill inside`"}]')"
# TC-LIVENESS-082a [issue #473 UPDATE]: the round-10 "genuinely CLOSED span,
# real producer shape, still excluded" pin now uses the ACTUAL genuine
# dispatcher-token: whole-body shape (marker line + enum human line) rather
# than a bare wrapped token — see TC-LIVENESS-060b's docstring for why a
# merely wrapped token no longer qualifies as the genuine producer shape
# post-#473.
dispatcher_token_body82=$(printf '<!-- dispatcher-token: abc at 2026-01-01T00:00:00Z mode=dev-new run=1-2 -->\nDispatching autonomous development...')
assert_eq "TC-LIVENESS-082a [issue #473] a genuine whole-body dispatcher-token: producer comment is still excluded from the count" "0" \
  "$(_liveness_non_idempotent_count "$(jq -n --arg b "$dispatcher_token_body82" '[{"authorKind":"human","body":$b}]')")"
assert_eq "TC-LIVENESS-082b a genuinely CLOSED single-line HTML-comment marker (the real producer shape) still registers in the digest" "dispatcher-token:" \
  "$(_liveness_marker_digest "$(jq -n --arg b "$dispatcher_token_body82" '[{"authorKind":"human","createdAt":"t","body":$b}]')")"
# TC-LIVENESS-083 [issue #473 UPDATE]: the dispatcher-convergence-breaker:
# entry is now a full-body grammar (marker + the ENTIRE CBREPORT), so the
# fixture's second comment must be the genuine full report body, not a
# truncated "## tripped" placeholder — captured via a real heredoc
# expansion of the SAME template lib-dispatch.sh's CBREPORT renders, so this
# fixture can never drift from the producer's actual text.
cbreport_marker83='<!-- dispatcher-convergence-breaker: issue=1 head=sha-A trailer=abc123 session=s1 -->'
cbreport_body83=$(cat <<CBREPORT83
${cbreport_marker83}
## ⛔ Convergence circuit-breaker tripped — halting a non-converging dev↔review loop (\`reason=non-convergence\`, [INV-105])

The autonomous dev↔review loop is **not converging**: the review keeps failing
substantively on PR **#12** while the PR head SHA stays **frozen**
— the dev agent completed **3** dev-resume rounds against
\`sha-A\` (≥ threshold 3) and produced **zero new
commits** each time. This is the #286 deadlock shape: a \`failed-substantive\`
verdict the dev agent cannot satisfy (typically a self-contradictory / malformed
acceptance criterion, or a fix the agent's scoped token can't apply).

**Dispatcher actions taken** (this loop is now HALTED — no more \`dev-resume\`):
- Transitioned the issue to \`stalled\` (autonomy halted; \`pending-dev\` removed; \`autonomous\` is retained) — REMOVING the \`stalled\` label is the operator's explicit opt-in to resume (re-enters via Step 2; retry counter resets, INV-05).
- Posted this one-time report.

**Evidence**
- PR: #12
- Frozen PR head: \`sha-A\`
- Repeated substantive review verdict (\`cause=some-cause\`, \`dev-actionable=true\`):
  > some quoted verdict text
- Repeated-failure count on this frozen head: **3**
- Counted completed dev-resume rounds (timestamps): 2026-01-01T00:00:00Z, 2026-01-01T01:00:00Z

**Human action needed** — pick one, then resume:
- [ ] Rewrite the invalid / self-contradictory acceptance criterion in the issue body, OR
- [ ] Grant the permission / scope the dev agent lacked (if the fix needs a privileged token or a protected-path edit), OR
- [ ] Close the issue, or split the un-satisfiable part into a maintainer follow-up.

**To resume: fix per the checklist above, then REMOVE the \`stalled\` label (the \`autonomous\` label is retained; removal re-arms the pipeline and resets the retry counter, INV-05).**
@zxkane
CBREPORT83
)
assert_eq "TC-LIVENESS-083 the whole-body extraction still works when TWO distinct grammars are present across two comments" "dispatcher-convergence-breaker:,dispatcher-token:" \
  "$(_liveness_marker_digest "$(jq -n --arg b1 "$dispatcher_token_body82" --arg b2 "$cbreport_body83" '[{"authorKind":"human","createdAt":"t1","body":$b1},{"authorKind":"human","createdAt":"t2","body":$b2}]')")"

# [round 8 BLOCKING #3] fetch_pr_for_issue transport failure (nonzero rc) must
# defer the WHOLE tick — never fall through to "no PR" (empty head), which
# would silently reset the counter and mask a park.
_reset_stubs
fetch_pr_for_issue() { return 1; }
_liveness_evaluate_issue 99 issue pending-dev 6 18
assert_eq "TC-LIVENESS-063 fetch_pr_for_issue transport failure -> zero comment posts (tick deferred, not evaluated)" "0" "$(_trace_verbs | grep -c '^itp_post_comment$')"

# Contrast case: fetch_pr_for_issue succeeding with rc=0 and EMPTY output
# (genuinely no PR bound) must NOT defer — it proceeds with an empty head,
# same as before this fix.
_reset_stubs
fetch_pr_for_issue() { :; }
_liveness_evaluate_issue 99 issue pending-dev 6 18
assert_eq "TC-LIVENESS-064 genuinely-no-PR (rc=0, empty result) still proceeds and posts the bare marker" "1" "$(_trace_verbs | grep -c '^itp_post_comment$')"

# TC-LIVENESS-065/066 [round-9 independent review gap]: the `tripped` field
# added in round 8 has TWO forgery directions, not one (see
# `_liveness_strict_author_flag`'s docstring) — a forged HIGH count still
# TRIGGERS an early tier action (bounded by the count cap, TC-056..058
# above), but a forged `tripped=1` marker can also SUPPRESS an in-progress
# series by moving the cutoff forward past a genuine, still-relevant marker.
# The trigger direction was pinned; the suppression direction was not. Pin
# it now: in the default GH_AUTH_MODE=token topology (no authorKind signal
# to layer on top — the SAME documented residual class INV-105's round-14
# finding already carries), a human's forged `tripped=1` marker DOES suppress
# a genuine bot-authored in-progress marker; in GH_AUTH_MODE=app, the SAME
# forgery is rejected by the authorKind gate and the genuine marker still
# qualifies. Any tightening of this is a conscious future change, not a
# silent regression.
fp65=$(_liveness_fingerprint pending-dev sha-A 0 "")
genuine65=$(_liveness_marker 99 "$fp65" 10 0 0)
forged65=$(_liveness_marker 99 "$fp65" 2 0 1)
comments65=$(jq -n --arg g "$genuine65" --arg f "$forged65" '
  [{"authorKind":"bot","createdAt":"2026-01-01T00:00:00Z","body":$g},
   {"authorKind":"human","createdAt":"2026-01-01T01:00:00Z","body":$f}]
')
GH_AUTH_MODE=token
assert_eq "TC-LIVENESS-065 token-mode residual: a forged human tripped=1 marker DOES suppress a genuine bot in-progress marker (documented, accepted exposure)" \
  "" "$(_liveness_prior_marker "$comments65" "$(_liveness_strict_author_flag)")"
GH_AUTH_MODE=app
assert_eq "TC-LIVENESS-066 app-mode: the SAME forged human tripped=1 marker is rejected by the authorKind gate — the genuine bot marker still qualifies" \
  "$genuine65" "$(_liveness_prior_marker "$comments65" "$(_liveness_strict_author_flag)")"
unset GH_AUTH_MODE

# ===========================================================================
echo
echo "=== TC-LIVENESS-067..069 [codex review, PR #472, round 9 BLOCKING #1]: ==="
echo "=== _liveness_non_idempotent_count gains the SAME authorKind gate the ==="
echo "=== digest/marker reads already have                                 ==="
# ===========================================================================
# Pre-round-9, _liveness_non_idempotent_count had NO authorKind gate at all:
# a human comment merely wrapping a known token in a backtick span or an
# HTML-comment opening satisfied the round-8 wrapper anchor exactly as well
# as a genuine producer's comment, so it was (wrongly) treated as idempotent
# and excluded from the count. The fix RECLASSIFIES an untrusted match as
# counted (not "excluded from consideration") — in GH_AUTH_MODE=app, via
# _liveness_strict_author_flag, a human's wrapped-token comment now counts
# as genuine progress instead of being masked as an idempotent notice.
#
# [issue #473 UPDATE] TC-067/068/069 are REWRITTEN here to use a GENUINE
# whole-body dispatcher-token: producer comment instead of a merely
# backtick-wrapped token: post-#473 a wrapped-token quote (TC-LIVENESS-060b's
# new fixture) no longer matches ANY grammar regardless of authorKind, so it
# can no longer exercise this gate at all (it always counts as progress —
# the trust distinction below is meaningless against a fixture that never
# matches in the first place). The gate this group pins is about an
# authentic-shaped comment from an UNTRUSTED author, which requires the
# genuine full-body shape to even reach the grammar-match branch.

dispatcher_token_body67=$(printf '<!-- dispatcher-token: abc at 2026-01-01T00:00:00Z mode=dev-new run=1-2 -->\nDispatching autonomous development...')
_saved_gh_auth_mode67="${GH_AUTH_MODE:-}"
GH_AUTH_MODE=app
assert_eq "TC-LIVENESS-067 app-mode: a human posting the genuine whole-body dispatcher-token: shape now COUNTS as progress (untrusted match reclassified, not masked as idempotent)" "2" \
  "$(_liveness_non_idempotent_count "$(jq -n --arg b "$dispatcher_token_body67" '[{"authorKind":"human","body":"a genuinely new update"},{"authorKind":"human","body":$b}]')")"
assert_eq "TC-LIVENESS-068 app-mode: the SAME genuine whole-body shape from a bot/App identity is STILL excluded (a trusted match is trusted)" "1" \
  "$(_liveness_non_idempotent_count "$(jq -n --arg b "$dispatcher_token_body67" '[{"authorKind":"human","body":"a genuinely new update"},{"authorKind":"bot","body":$b}]')")"
if [ -n "$_saved_gh_auth_mode67" ]; then GH_AUTH_MODE="$_saved_gh_auth_mode67"; else unset GH_AUTH_MODE; fi

# TC-LIVENESS-069: token-mode residual — UNCHANGED behavior, the gate is a
# no-op there ($strict == "0"), matching the documented, accepted exposure
# every other liveness read carries in GH_AUTH_MODE=token.
_saved_gh_auth_mode69="${GH_AUTH_MODE:-}"
GH_AUTH_MODE=token
assert_eq "TC-LIVENESS-069 token-mode: a human posting the genuine whole-body dispatcher-token: shape is still excluded from the count via the grammar match (gate is a no-op here, documented residual)" "1" \
  "$(_liveness_non_idempotent_count "$(jq -n --arg b "$dispatcher_token_body67" '[{"authorKind":"human","body":"a genuinely new update"},{"authorKind":"human","body":$b}]')")"
if [ -n "$_saved_gh_auth_mode69" ]; then GH_AUTH_MODE="$_saved_gh_auth_mode69"; else unset GH_AUTH_MODE; fi

# ===========================================================================
echo
echo "=== TC-LIVENESS-070..074 [codex review, PR #472, round 9 BLOCKING #2]: ==="
echo "=== marker/report writes retry once and surface a loud notice on    ==="
echo "=== persistent failure instead of a silent || true                   ==="
# ===========================================================================

# TC-LIVENESS-070: _liveness_post_marker succeeds on the first attempt ->
# exactly one itp_post_comment call, no WARNING, returns 0.
_trace_reset
log() { _rec log "$@"; }
itp_post_comment() { _rec itp_post_comment "$@"; return 0; }
_liveness_post_marker 99 "<!-- marker -->"
_pm70_rc=$?
assert_eq "TC-LIVENESS-070a first-attempt success -> exactly one itp_post_comment call" "1" "$(_trace_verbs | grep -c '^itp_post_comment$')"
assert_eq "TC-LIVENESS-070b first-attempt success -> no WARNING logged" "0" "$(_trace_verbs | grep -c '^log$')"
assert_eq "TC-LIVENESS-070c first-attempt success -> returns 0" "0" "$_pm70_rc"

# TC-LIVENESS-071: first attempt fails, retry succeeds -> exactly two
# itp_post_comment calls (both the marker body), no operator notice, returns 0.
_trace_reset
_pm71_calls=0
itp_post_comment() { _rec itp_post_comment "$@"; _pm71_calls=$((_pm71_calls + 1)); [ "$_pm71_calls" -ge 2 ] && return 0; return 1; }
_liveness_post_marker 99 "<!-- marker -->"
_pm71_rc=$?
assert_eq "TC-LIVENESS-071a fail-then-succeed -> exactly two itp_post_comment calls, both the marker" "2" \
  "$(_trace_all | grep -c 'marker -->')"
assert_eq "TC-LIVENESS-071b fail-then-succeed -> no operator notice (only the marker body was ever posted)" "0" \
  "$(_trace_all | grep -c 'liveness watchdog could not record')"
assert_eq "TC-LIVENESS-071c fail-then-succeed -> returns 0" "0" "$_pm71_rc"

# TC-LIVENESS-072: BOTH attempts fail -> a WARNING is logged AND a loud
# operator notice is posted as a THIRD itp_post_comment call; returns 1.
_trace_reset
itp_post_comment() { _rec itp_post_comment "$@"; return 1; }
_liveness_post_marker 99 "<!-- marker -->"
_pm72_rc=$?
assert_eq "TC-LIVENESS-072a persistent failure -> three itp_post_comment attempts (2 marker + 1 notice)" "3" "$(_trace_verbs | grep -c '^itp_post_comment$')"
assert_match "TC-LIVENESS-072b persistent failure -> a WARNING is logged" "WARNING.*failed to post the bookkeeping marker" "$(_trace_all)"
assert_match "TC-LIVENESS-072c persistent failure -> the third call is the loud @REPO_OWNER operator notice" "could not record its bookkeeping marker" "$(_trace_all)"
assert_eq "TC-LIVENESS-072d persistent failure -> returns 1" "1" "$_pm72_rc"

# TC-LIVENESS-073: _liveness_post_report mirrors the same retry shape (no
# loud notice — see the helper's own docstring for why the report doesn't
# need one) — both attempts fail -> exactly 2 calls, one WARNING, returns 1.
_trace_reset
itp_post_comment() { _rec itp_post_comment "$@"; return 1; }
_liveness_post_report 99 "some report text"
_pr73_rc=$?
assert_eq "TC-LIVENESS-073a report persistent failure -> exactly two itp_post_comment attempts (no third loud-notice call)" "2" "$(_trace_verbs | grep -c '^itp_post_comment$')"
assert_match "TC-LIVENESS-073b report persistent failure -> a WARNING is logged" "WARNING.*failed to post the human-readable report" "$(_trace_all)"
assert_eq "TC-LIVENESS-073c report persistent failure -> returns 1" "1" "$_pr73_rc"

# TC-LIVENESS-074: end-to-end through _liveness_evaluate_issue — when the
# TIER-1 marker write persistently fails, the dependent tier-1 REPORT is
# skipped entirely (never posted with stale/absent counter state), proving
# the tier1 branch's `_liveness_post_marker ... || return 0` short-circuit.
_reset_stubs
FP74=$(_liveness_fingerprint pending-dev sha-A 0 "")
_seq74_comments='[]'
itp_list_comments() { printf '%s' "$_seq74_comments"; }
itp_read_task() { printf '%s' '{"labels":["pending-dev"]}'; }
label_swap() { _rec label_swap "$@"; }
log() { :; }
# First 5 ticks succeed normally so the counter reaches 5 (one below notice).
itp_post_comment() { _rec itp_post_comment "$@"; _seq74_comments=$(jq --arg b "$2" '. + [{"authorKind":"bot","createdAt":"2026-01-01T00:00:00Z","body":$b}]' <<<"$_seq74_comments"); return 0; }
for _t74 in $(seq 1 5); do
  _liveness_evaluate_issue 99 issue pending-dev 6 18
done
# The 6th tick (tier1 threshold) has EVERY itp_post_comment call fail.
_trace_reset
itp_post_comment() { _rec itp_post_comment "$@"; return 1; }
_liveness_evaluate_issue 99 issue pending-dev 6 18
assert_eq "TC-LIVENESS-074a tier1 marker persistently fails -> zero report posts (short-circuited)" "0" \
  "$(_trace_all | grep -c 'reason=liveness-no-progress')"
assert_eq "TC-LIVENESS-074b tier1 marker write was attempted twice (initial + one retry) despite failing" "2" \
  "$(_trace_all | grep -cE 'fingerprint=[0-9a-f]+ count=6 tier1=1 tripped=0')"

# ===========================================================================
echo
echo "=== TC-LIVENESS-075..078 [codex review, PR #472, round 9 follow-up]: ==="
echo "=== bare helper calls must not trip set -e and abort the tick        ==="
# ===========================================================================
# CRITICAL: this file and dispatcher-tick.sh both run under
# `set -euo pipefail` in production, but this test harness runs under
# `set +e` (line 60 above) so it can keep counting PASS/FAIL after an
# assertion failure. _liveness_post_marker/_liveness_post_report were
# introduced to RETURN 1 on persistent failure (so the tier1 branch can
# detect it) — but a BARE call to a function that can return 1, under real
# `set -e`, aborts the calling function immediately, which then propagates
# up through run_liveness_watchdog's loop and aborts the ENTIRE dispatcher
# tick. Every call site EXCEPT the tier1 marker (which is deliberately
# gated on `|| return 0`) must swallow that non-zero return with `|| true`
# to preserve the pre-round-9 never-abort-the-tick guarantee. The `set +e`
# harness above cannot catch this class of regression — sourcing under
# `set +e` makes every bare call "safe" regardless of whether `|| true` is
# present. These four cases spawn a FRESH bash subshell with REAL
# `set -euo pipefail` (mirroring production) to prove the function returns
# normally instead of aborting.

_sete_probe() {
  local action_ticks="$1"
  bash -euo pipefail -c '
    export REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane PROJECT_ID=sete-probe-$$ MAX_RETRIES=3 MAX_CONCURRENT=5
    source "'"$LIB"'"
    source "'"$LIB_DISPATCH"'"
    was_just_dispatched() { return 1; }
    is_within_grace_period() { return 1; }
    _dispatch_marker_recent() { return 1; }
    pid_alive() { return 1; }
    log() { :; }
    fetch_pr_for_issue() { printf "%s" "{\"headRefOid\":\"sha-A\"}"; }
    itp_list_comments() { printf "%s" "[]"; }
    itp_read_task() { printf "%s" "{\"labels\":[\"pending-dev\"]}"; }
    label_swap() { :; }
    itp_post_comment() { return 1; }
    _liveness_evaluate_issue 99 issue pending-dev '"$action_ticks"'
    echo "REACHED_END"
  ' 2>/dev/null
}

assert_eq "TC-LIVENESS-075 none branch: persistent marker-write failure under real set -e does NOT abort the function" "REACHED_END" \
  "$(_sete_probe '99 6 18')"
assert_eq "TC-LIVENESS-076 tier2 branch: persistent marker-write failure under real set -e does NOT abort (report still attempted)" "REACHED_END" \
  "$(_sete_probe '99 18 18')"

# TC-LIVENESS-077/078: same probe, but only the REPORT post fails (the
# marker succeeds) — isolates the tier1-report and tier2-report `|| true`
# guards specifically, since TC-075/076 exercise a total itp_post_comment
# failure that could mask a report-only regression. A prior marker at
# count=(threshold-1) is SEEDED into itp_list_comments so the fresh
# evaluation's `count = stored+1` actually LANDS on the tier1/tier2
# threshold and reaches that branch (a fresh series with no prior marker
# would take the `none` action regardless of `notice`/`stall`, which would
# make this probe pass VACUOUSLY without ever exercising the report path).
_sete_probe_report_only() {
  local notice="$1" stall="$2" seed_count="$3"
  bash -euo pipefail -c '
    export REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane PROJECT_ID=sete-probe2-$$ MAX_RETRIES=3 MAX_CONCURRENT=5
    source "'"$LIB"'"
    source "'"$LIB_DISPATCH"'"
    was_just_dispatched() { return 1; }
    is_within_grace_period() { return 1; }
    _dispatch_marker_recent() { return 1; }
    pid_alive() { return 1; }
    log() { :; }
    fetch_pr_for_issue() { printf "%s" "{\"headRefOid\":\"sha-A\"}"; }
    itp_read_task() { printf "%s" "{\"labels\":[\"pending-dev\"]}"; }
    label_swap() { :; }
    # Seed a prior marker whose fingerprint matches what this evaluation
    # will freshly compute from (pending-dev, sha-A, 0, ""): the watchdog own
    # marker is idempotent-pattern-excluded from the count and digest-pattern
    # excluded from the digest (D3), so a comments array containing ONLY the
    # prior marker yields the identical fingerprint as an EMPTY comments
    # array — `_liveness_non_idempotent_count`/`_liveness_marker_digest` both
    # see it and exclude it either way.
    _seed_fp=$(_liveness_fingerprint pending-dev sha-A 0 "")
    _seed_marker=$(_liveness_marker 99 "$_seed_fp" '"$seed_count"' 0 0)
    itp_list_comments() { printf "%s" "[{\"authorKind\":\"bot\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"body\":\"$(printf "%s" "$_seed_marker" | sed "s/\"/\\\\\"/g")\"}]"; }
    _sp_n=0
    itp_post_comment() {
      _sp_n=$((_sp_n + 1))
      # Every call whose body starts with the marker HTML-comment prefix
      # succeeds; every other call (the human-readable report) fails.
      case "$2" in
        "<!-- dispatcher-liveness-watchdog:"*) return 0 ;;
        *) return 1 ;;
      esac
    }
    _liveness_evaluate_issue 99 issue pending-dev '"$notice"' '"$stall"'
    echo "REACHED_END"
  ' 2>/dev/null
}

assert_eq "TC-LIVENESS-077 tier1 branch: marker succeeds, report persistently fails under real set -e -> still does NOT abort" "REACHED_END" \
  "$(_sete_probe_report_only 6 18 5)"
assert_eq "TC-LIVENESS-078 tier2 branch: marker succeeds, report persistently fails under real set -e -> still does NOT abort" "REACHED_END" \
  "$(_sete_probe_report_only 6 18 17)"

# ===========================================================================
echo
echo "=== TC-LIVENESS-084..085 [issue #473]: whole-body grammar conversion — ==="
echo "=== the two Acceptance Criteria pins, quoted verbatim from the issue  ==="
# ===========================================================================
# These two pins are stated directly (not merely exercised indirectly by the
# TC-060b/067-069/082/083 rewrites above) so the issue's own Requirements
# checklist has dedicated, unambiguous evidence.

# TC-LIVENESS-084: "Quoted-token-is-progress pin for
# _liveness_non_idempotent_count: a human comment quoting
# reason=liveness-timeout (backtick-wrapped, inside prose) counts toward the
# non-idempotent progress count; the genuine full-body notice does not."
quoted_token_prose_084="please see \`reason=liveness-timeout\` for context, everything is fine"
assert_eq "TC-LIVENESS-084a a human comment quoting reason=liveness-timeout backtick-wrapped inside prose COUNTS as progress" "1" \
  "$(_liveness_non_idempotent_count "$(jq -n --arg b "$quoted_token_prose_084" '[{"authorKind":"human","body":$b}]')")"
genuine_tier2_body084=$(cat <<TIER2GENUINE084
${_LIVENESS_TIER2_HEADING} (\`reason=liveness-timeout\`, [INV-128])

This issue's observable state (label + PR head + non-idempotent comments + marker set) has not changed for **18** consecutive dispatcher ticks — well past the **18**-tick stall threshold.

**Evidence**
- Last-known fingerprint: \`abc123\`
- Label at time of trip: \`pending-dev\`
- PR head: \`sha-A\`
- Non-idempotent comment count: 3
- Marker digest (known grammars present): \`dispatcher-token:\`
- Tick counts: count=18, notice_threshold=6, stall_threshold=18
- Newest session report / verdict pointer: (none found)

**Dispatcher actions taken** (autonomy halted for this issue):
- Transitioned to \`stalled\` (\`autonomous\` is retained — removing \`stalled\` re-arms via Step 2 and resets the retry counter, [INV-05]).
- Posted this one-time report.

@zxkane please investigate — this is the class-level backstop (a specific breaker for this park shape may not exist yet). To resume: fix per the evidence above, then remove the \`stalled\` label.
TIER2GENUINE084
)
assert_eq "TC-LIVENESS-084b the genuine full-body reason=liveness-timeout notice does NOT count as progress" "0" \
  "$(_liveness_non_idempotent_count "$(jq -n --arg b "$genuine_tier2_body084" '[{"authorKind":"bot","body":$b}]')")"

# TC-LIVENESS-085: "First-line-forgery pin for _liveness_marker_digest: a
# comment whose first line is a canonical <!-- dispatcher-token: ... --> but
# whose body continues with prose does NOT alter the digest; the genuine
# full-body marker does."
forged_firstline_085=$(printf '<!-- dispatcher-token: abc at 2026-01-01T00:00:00Z mode=dev-new run=1-2 -->\nthis is prose that continues, not the real enum human line')
assert_eq "TC-LIVENESS-085a a comment whose FIRST LINE is a canonical dispatcher-token: marker but continues with prose does NOT alter the digest" "" \
  "$(_liveness_marker_digest "$(jq -n --arg b "$forged_firstline_085" '[{"authorKind":"human","createdAt":"t","body":$b}]')")"
genuine_firstline_085=$(printf '<!-- dispatcher-token: abc at 2026-01-01T00:00:00Z mode=dev-new run=1-2 -->\nDispatching autonomous development...')
assert_eq "TC-LIVENESS-085b the genuine full-body dispatcher-token: marker DOES register in the digest" "dispatcher-token:" \
  "$(_liveness_marker_digest "$(jq -n --arg b "$genuine_firstline_085" '[{"authorKind":"human","createdAt":"t","body":$b}]')")"

# ===========================================================================
echo
echo "=== TC-LIVENESS-086..094 [issue #473 UPDATE, pr-test-analyzer gap]: ==="
echo "=== full-body fixture coverage for the 9 producer grammars that     ==="
echo "=== TC-006..085 never exercised directly (only via digest/count     ==="
echo "=== plumbing tests) -- each fixture is transcribed byte-for-byte    ==="
echo "=== from its real itp_post_comment call site so a future producer- ==="
echo "=== text edit trips a red test instead of silently desyncing.      ==="
# ===========================================================================

genuine_inv12completed_086='Session `sess-1` already ended (stop_reason=end_turn, terminal_reason=completed) and no post-session review verdict was found. Resume would hang on idle SSE — skipping. If review findings exist, unpark by flipping to `in-progress` + posting a dispatcher-token comment + running `dispatch-local.sh dev-resume <issue>` (a fresh session re-reads the issue and findings; do NOT flip to `pending-review` — the stale-verdict guard rejects an already-reviewed HEAD). Close the issue if the work is done. (`INV-12-completed:sess-1`)'
assert_eq "TC-LIVENESS-086 genuine full-body INV-12-completed: registers in the digest" "INV-12-completed:" \
  "$(_liveness_marker_digest "$(jq -n --arg b "$genuine_inv12completed_086" '[{"authorKind":"bot","createdAt":"t","body":$b}]')")"

genuine_inv12nopr_087='Session `sess-1` ended cleanly (stop_reason=end_turn, terminal_reason=completed) but no PR was ever created, so no review could run. Minting a fresh dev session (bounded by `MAX_RETRIES`). (`INV-12-no-pr-fresh-dev:sess-1`)'
assert_eq "TC-LIVENESS-087 genuine full-body INV-12-no-pr-fresh-dev: registers in the digest" "INV-12-no-pr-fresh-dev:" \
  "$(_liveness_marker_digest "$(jq -n --arg b "$genuine_inv12nopr_087" '[{"authorKind":"bot","createdAt":"t","body":$b}]')")"

genuine_inv35_088='Review failed substantively on completed session `sess-1`. A completed session cannot be resumed; minting a fresh dev session via the INV-12 PTL recovery pattern. (`INV-35-fresh-dev:sess-1`)'
assert_eq "TC-LIVENESS-088 genuine full-body INV-35-fresh-dev: registers in the digest" "INV-35-fresh-dev:" \
  "$(_liveness_marker_digest "$(jq -n --arg b "$genuine_inv35_088" '[{"authorKind":"bot","createdAt":"t","body":$b}]')")"

genuine_noprogress_089='Substantive review failure on completed session `sess-1` is **not resolvable by the autonomous dev agent**: its scoped token hit `Resource not accessible by integration` on a PR-metadata edit, or the finding requires a maintainer / post-merge action. Marking stalled — no further `dev-new` will be dispatched. @zxkane please apply the PR-body / metadata change manually, or split the post-merge criterion into a follow-up. (`no-progress-substantive:sess-1`)'
assert_eq "TC-LIVENESS-089 genuine full-body no-progress-substantive: (non-attempt form) registers in the digest" "no-progress-substantive:" \
  "$(_liveness_marker_digest "$(jq -n --arg b "$genuine_noprogress_089" '[{"authorKind":"bot","createdAt":"t","body":$b}]')")"

genuine_nonactionable_090='Substantive review failure on completed session `sess-1` is **not resolvable by the autonomous dev agent**: the review classified every blocking finding as requiring a human or a privileged token the agent'"'"'s scoped token lacks (e.g. a `.github/workflows` edit needs the `workflows` scope, or a CODEOWNERS / maintainer-owned change — [INV-92]). Marking stalled — no `dev-new` will be dispatched (`reason=non_actionable_finding`). @zxkane please apply the change manually, grant the required scope, or split the criterion into a maintainer follow-up. (`non-actionable-finding:sess-1`)'
assert_eq "TC-LIVENESS-090 genuine full-body non-actionable-finding: registers in the digest" "non-actionable-finding:" \
  "$(_liveness_marker_digest "$(jq -n --arg b "$genuine_nonactionable_090" '[{"authorKind":"bot","createdAt":"t","body":$b}]')")"

genuine_selfhealnonsub_091='PR #12 HEAD `sha-A` was reviewed with a non-substantive FAILED verdict (cause=`some-cause`), and no `Dev Session ID:` could be resolved for the prior dev session (its session-report comment was likely lost — e.g. a mid-cleanup auth-teardown race). Re-routing to review rather than dispatching a fresh dev session. (`self-heal-non-substantive:sha-A`)'
assert_eq "TC-LIVENESS-091 genuine full-body self-heal-non-substantive: registers in the digest" "self-heal-non-substantive:" \
  "$(_liveness_marker_digest "$(jq -n --arg b "$genuine_selfhealnonsub_091" '[{"authorKind":"bot","createdAt":"t","body":$b}]')")"

genuine_crashednonact_092='PR #12 HEAD `sha-A` was reviewed with a FAILED verdict that classified every blocking finding as **not resolvable by the autonomous dev agent** (requires a human or a privileged token the agent'"'"'s scoped token lacks, [INV-92]), and a `Dev Session ID:` was resolved for the prior dev session, but its completion could not be confirmed (a non-terminal stop reason such as `api_error`, a non-claude dev CLI, or an unreadable session log). Marking stalled — no `dev-new` will be dispatched. @zxkane please apply the change manually. (`crashed-session-non-actionable:sha-A`)'
assert_eq "TC-LIVENESS-092 genuine full-body crashed-session-non-actionable: registers in the digest" "crashed-session-non-actionable:" \
  "$(_liveness_marker_digest "$(jq -n --arg b "$genuine_crashednonact_092" '[{"authorKind":"bot","createdAt":"t","body":$b}]')")"

genuine_inv25_093='Label hygiene: stripped `foo`, `bar` from `some-issue` issue (INV-25). <!-- INV-25-hygiene:foo,bar; -->'
assert_eq "TC-LIVENESS-093 genuine full-body INV-25-hygiene: registers in the digest" "INV-25-hygiene:" \
  "$(_liveness_marker_digest "$(jq -n --arg b "$genuine_inv25_093" '[{"authorKind":"bot","createdAt":"t","body":$b}]')")"

# TC-LIVENESS-094: dispatcher-gate-fail-breaker: — the SECOND big multi-line
# breaker report (sibling to dispatcher-convergence-breaker:, pinned by
# TC-LIVENESS-083 above), transcribed byte-for-byte from its real
# `itp_post_comment` heredoc (autonomous-review.sh's GATEBREAKREPORT).
gatebreak_marker094='<!-- dispatcher-gate-fail-breaker: issue=1 head=sha-A rc=1 count=3 -->'
gatebreak_body094=$(cat <<GATEBREAK094
${gatebreak_marker094}
## ⛔ Same-HEAD E2E-gate circuit-breaker tripped — halting repeated re-dispatch (\`reason=same-head-gate-failure\`, [#453])

The E2E hard gate (INV-46) has failed **3** times in a row
against the SAME PR head \`sha-A\` with the SAME lane exit code
\`1\` (>= threshold 3). Re-dispatching review
against this unchanged head would only repeat the identical failure —
nothing the dev agent can fix without a new commit.

**Dispatcher actions taken** (this loop is now HALTED):
- Transitioned the issue to \`stalled\` (autonomy halted; \`autonomous\` is
  retained) — REMOVING the \`stalled\` label is the operator's explicit
  opt-in to resume.
- Posted this one-time report.

**Best-effort classification**
lane rc=1 is consistent with the E2E job never actually running

**Evidence**
- PR: #12
- Frozen PR head: \`sha-A\`
- E2E lane exit code: \`1\` (evidence_present=0)
- Repeated-failure count on this frozen (head, rc) pair: **3**

**Human action needed** — pick one, then push a new commit to resume:
- [ ] Fix the external/environment prerequisite the E2E gate depends on
      (e.g. deploy the missing IAM grant), OR
- [ ] Fix a genuine code defect the E2E gate is correctly catching, OR
- [ ] Close the issue if the feature is no longer wanted.

**To resume: fix per the checklist above, then push a new commit and REMOVE
the \`stalled\` label (the \`autonomous\` label is retained; removal re-arms
the pipeline).**
@zxkane
GATEBREAK094
)
assert_eq "TC-LIVENESS-094 genuine full-body dispatcher-gate-fail-breaker: registers in the digest" "dispatcher-gate-fail-breaker:" \
  "$(_liveness_marker_digest "$(jq -n --arg b "$gatebreak_body094" '[{"authorKind":"bot","createdAt":"t","body":$b}]')")"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
