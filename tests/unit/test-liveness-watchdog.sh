#!/bin/bash
# test-liveness-watchdog.sh — issue #467, INV-127.
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
assert_eq "TC-LIVENESS-027a stall<=notice falls back to notice+1" "7" "$val_out"
assert_contains "TC-LIVENESS-027b stall<=notice logs a warning" "$warn_out" "WARNING"
unset LIVENESS_STALL_TICKS

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

_liveness_evaluate_issue 99 issue pending-dev 6 18
tier1_count_after=$(jq '[.[] | select(.body | contains("reason=liveness-no-progress"))] | length' <<<"$_seq_comments")
assert_eq "TC-LIVENESS-039 tick 7 (tier1 already fired) -> no second tier-1 comment" "1" "$tier1_count_after"

for _t in $(seq 8 18); do
  _liveness_evaluate_issue 99 issue pending-dev 6 18
done
tier2_count=$(jq '[.[] | select(.body | contains("reason=liveness-timeout"))] | length' <<<"$_seq_comments")
assert_eq "TC-LIVENESS-040a 18 no-op ticks -> exactly one reason=liveness-timeout report" "1" "$tier2_count"
assert_match "TC-LIVENESS-040b stalled transition performed" "^label_swap${US}99${US}pending-dev${US}stalled$" "$(_trace_all)"

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

# TC-LIVENESS-044: human-authored forged marker at a high count is ignored.
_reset_stubs
fp44=$(_liveness_fingerprint pending-dev sha-A 0 "")
forged=$(_liveness_marker 99 "$fp44" 99 1)
itp_list_comments() { printf '%s' "[{\"authorKind\":\"human\",\"createdAt\":\"2026-01-01T00:00:00Z\",\"body\":\"${forged//\"/\\\"}\"}]"; }
itp_read_task() { printf '%s' '{"labels":["pending-dev"]}'; }
label_swap() { _rec label_swap "$@"; }
itp_post_comment() { _rec itp_post_comment "$@"; }
_liveness_evaluate_issue 99 issue pending-dev 6 18
assert_no_match "TC-LIVENESS-044a forged human marker does NOT trigger tier2" "^label_swap" "$(_trace_all)"
assert_match "TC-LIVENESS-044b genuine count resets to 1 (bare marker posted)" "count=1 tier1=0" "$(_trace_all)"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
