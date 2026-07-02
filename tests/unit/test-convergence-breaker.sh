#!/bin/bash
# test-convergence-breaker.sh — INV-103 / issue #297.
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
# round-10 [P1] finding 1: records label_swap/itp_post_comment call sequence in a
# FILE (survives a set -e subshell — see CB-ATOMIC-014). One file for the whole run;
# reset_mocks truncates it between cases.
_CALL_ORDER_FILE="$(mktemp)"
trap 'rm -f "$_CALL_ORDER_FILE"' EXIT
_MOCK_LABEL_SWAP_FAILS=0  # 1 = simulate a transient label_swap failure (rc 1, no state change)
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
_MOCK_FROZEN_ROUND_COMMENTS=0     # how many ACTIVE-case (matching-trailer) frozen-head rounds to synthesize
_MOCK_STALE_ROUNDS=0              # how many STALE (non-matching-trailer) frozen-head rounds to prepend ([P1] finding 1)
_MOCK_STALE_VERDICT_TRAILER="<!-- review-verdict: failed-non-substantive cause=bot-timeout -->"  # the stale rounds' preceding verdict
_MOCK_ROUND_VERDICT_TRAILER="<!-- review-verdict: failed-substantive -->"  # the active rounds' preceding verdict (canonical failed-substantive||true)
_MOCK_NONACT_MARKER_PRESENT=0     # a non-actionable-finding:<head> marker already on the issue?
_MOCK_CB_MARKER_PRESENT=0         # a dispatcher-convergence-breaker marker (same trailer) already posted?
_MOCK_CB_MARKER_HASH=""           # the trailer-hash the synthesized existing marker carries
_MOCK_CB_MARKER_SESSION=""        # round-12: the session= the synthesized existing marker carries
_MOCK_CB_MARKER_AUTHORKIND="self" # round-12: authorKind of the synthesized existing marker (self=genuine dispatcher post; human=impersonation/quote)
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
# _CALL_ORDER_FILE records the sequence of label_swap / itp_post_comment calls
# (round-10 [P1] finding 1: atomicity — the transition MUST land before the
# marker/report is posted). A FILE (not a plain variable) so the record survives
# a `set -e` subshell invocation (CB-ATOMIC-014 below) — a subshell's variable
# writes never propagate to the parent, but its file writes do.
# _MOCK_LABEL_SWAP_FAILS simulates a transient `label_swap` failure (e.g. a
# `gh issue edit` transport error) so the test can assert NO marker/report is
# posted when the transition doesn't land.
label_swap() {
  local issue_num="$1" remove="$2" add="$3"
  echo "label_swap" >> "$_CALL_ORDER_FILE"
  if [[ "${_MOCK_LABEL_SWAP_FAILS:-0}" != "0" ]]; then
    return 1
  fi
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

# Synthesize the normalized issue-comment array. [P1] finding 1: each per-round
# "no new commits" comment is now PRECEDED by a review-verdict trailer comment, so
# the join in _frozen_convergence_rounds_json can classify each round. Emits, in
# chronological order:
#   - _MOCK_STALE_ROUNDS pairs of (STALE verdict trailer + round comment) on the
#     current head FIRST — these have a non-matching canonical (default a
#     failed-non-substantive trailer) and MUST be excluded from the count,
#   - _MOCK_FROZEN_ROUND_COMMENTS pairs of (_MOCK_ROUND_VERDICT_TRAILER + round
#     comment) on the current head — the ACTIVE-case rounds the count includes,
#   - a non-actionable-finding:<head> marker when _MOCK_NONACT_MARKER_PRESENT,
#   - an existing dispatcher-convergence-breaker marker when _MOCK_CB_MARKER_PRESENT.
# Timestamps are zero-padded to 4 digits so >9 comments stay monotonic.
itp_list_comments() {
  local _bodies=() i
  local _round="Dev process exited (no new commits since last review at \`${_MOCK_PR_HEAD}\`). Moving to pending-dev for retry."
  # Stale, non-matching rounds first (default: failed-non-substantive → different canonical).
  for ((i = 0; i < ${_MOCK_STALE_ROUNDS:-0}; i++)); do
    _bodies+=("${_MOCK_STALE_VERDICT_TRAILER:-<!-- review-verdict: failed-non-substantive cause=bot-timeout -->}")
    _bodies+=("$_round")
  done
  # Active-case rounds: each preceded by the active verdict trailer, THEN
  # (round-11 [P1]) an optional UNAUTHENTICATED comment quoting a trailer —
  # positioned AFTER the genuine verdict and BEFORE the round comment, so a
  # naive (unauthenticated) `last`-before-round selection would pick the quote
  # instead of the real trailer. `_MOCK_HUMAN_TRAILER_QUOTE` = a human
  # (authorKind=human) quoting `_MOCK_HUMAN_TRAILER_QUOTE`'s trailer text;
  # `_MOCK_OTHERBOT_TRAILER_QUOTE` = a DIFFERENT bot (authorKind=bot, author
  # != BOT_LOGIN) posting its own trailer text — both must be rejected by the
  # authenticity gate regardless of authorKind.
  for ((i = 0; i < _MOCK_FROZEN_ROUND_COMMENTS; i++)); do
    _bodies+=("${_MOCK_ROUND_VERDICT_TRAILER:-<!-- review-verdict: failed-substantive -->}")
    [[ -n "${_MOCK_HUMAN_TRAILER_QUOTE:-}" ]] && _bodies+=("HUMANQUOTE:${_MOCK_HUMAN_TRAILER_QUOTE}")
    [[ -n "${_MOCK_OTHERBOT_TRAILER_QUOTE:-}" ]] && _bodies+=("OTHERBOT:${_MOCK_OTHERBOT_TRAILER_QUOTE}")
    _bodies+=("$_round")
  done
  if [[ "$_MOCK_NONACT_MARKER_PRESENT" != "0" ]]; then
    _bodies+=("non-actionable-finding:${_MOCK_PR_HEAD} prior escalation")
  fi
  # Round-7 [P1] regression: a HUMAN comment QUOTING the Step-5b status line
  # (and one embedding it mid-body) must NOT count as rounds. Injected AFTER the
  # active rounds so a naive contains() scan would count them.
  for ((i = 0; i < ${_MOCK_HUMAN_QUOTE_COMMENTS:-0}; i++)); do
    _bodies+=("HUMANQUOTE:> ${_round}")
  done
  for ((i = 0; i < ${_MOCK_MACHINE_MIDBODY_QUOTES:-0}; i++)); do
    _bodies+=("Re-checking the prior status: ${_round} — investigating.")
  done
  if [[ "$_MOCK_CB_MARKER_PRESENT" != "0" ]]; then
    # round-12: the marker now embeds `session=<sid>` — the test sets
    # _MOCK_CB_MARKER_SESSION to the CURRENT session-id to simulate a genuine
    # same-session re-tick, or to a DIFFERENT sid (default, sentinel
    # "__no_session__") to simulate a stale marker from a PRIOR, already-resolved
    # trip that must NOT suppress a fresh one. authorKind is controlled by
    # _MOCK_CB_MARKER_AUTHORKIND ("self" = genuine dispatcher post, "human" =
    # an impersonation/quote that must never suppress the halt).
    if [[ "${_MOCK_CB_MARKER_AUTHORKIND:-self}" == "human" ]]; then
      _bodies+=("HUMANQUOTE:<!-- dispatcher-convergence-breaker: issue=100 head=${_MOCK_PR_HEAD} trailer=${_MOCK_CB_MARKER_HASH} session=${_MOCK_CB_MARKER_SESSION:-__no_session__} -->")
    else
      _bodies+=("<!-- dispatcher-convergence-breaker: issue=100 head=${_MOCK_PR_HEAD} trailer=${_MOCK_CB_MARKER_HASH} session=${_MOCK_CB_MARKER_SESSION:-__no_session__} -->")
    fi
  fi
  local _json="[]" _ts=0 b _hh _mm _tsiso
  for b in "${_bodies[@]}"; do
    # Monotonic ISO timestamp: HH:MM derived from the index (supports up to
    # 24*60 comments, far beyond any test). Zero-padded so string sort == time.
    _hh=$(printf '%02d' $(( _ts / 60 )))
    _mm=$(printf '%02d' $(( _ts % 60 )))
    _tsiso="2026-06-12T${_hh}:${_mm}:00Z"
    # Author: verdict trailers default to BOT-authored (kane-review-agent);
    # everything else is self/dispatcher (my-claw). round-13 [BLOCKING]:
    # _MOCK_VERDICT_AUTHORKIND overrides this to simulate the REAL
    # GH_AUTH_MODE=token topology, where the review wrapper's genuine verdict
    # comment shares the dispatcher's PAT identity and ALSO normalizes to
    # authorKind=human (the provider cannot derive `self` without BOT_LOGIN) —
    # CB-COUNT-009f/g predate this override and always hardcoded the verdict
    # trailer to bot-authored, which masked the round-13 regression (the
    # empty-BOT_LOGIN fallback rejected every genuine human-authorKind verdict).
    # The join keys on the trailer TEXT + structural startswith, not the
    # author, but keep authors realistic.
    local _author="my-claw" _akind="${_MOCK_ROUNDS_AUTHORKIND:-self}"
    if [[ "$b" == *"review-verdict:"* ]]; then
      if [[ -n "${_MOCK_VERDICT_AUTHORKIND:-}" ]]; then
        _akind="$_MOCK_VERDICT_AUTHORKIND"
        _author="my-claw"
        [[ "$_akind" == "bot" ]] && _author="kane-review-agent"
      else
        _author="kane-review-agent"; _akind="bot"
      fi
    fi
    if [[ "$b" == HUMANQUOTE:* ]]; then
      _author="zxkane"; _akind="human"; b="${b#HUMANQUOTE:}"
    fi
    # round-11 [P1]: a DIFFERENT bot (authorKind=bot, but author != BOT_LOGIN)
    # posting/quoting a trailer — must be rejected by the exact author==BOT_LOGIN
    # binding regardless of its authorKind matching the coarse "not human" bound.
    if [[ "$b" == OTHERBOT:* ]]; then
      _author="some-other-bot[bot]"; _akind="bot"; b="${b#OTHERBOT:}"
    fi
    _json=$(jq -c --arg b "$b" --arg a "$_author" --arg k "$_akind" --arg ts "$_tsiso" --argjson id "$(( 100 + _ts ))" \
      '. + [{id:$id, author:$a, authorKind:$k, body:$b, createdAt:$ts}]' <<<"$_json")
    _ts=$((_ts + 1))
  done
  printf '%s' "$_json"
}
itp_post_comment() {
  echo "itp_post_comment" >> "$_CALL_ORDER_FILE"
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
  : > "$_CALL_ORDER_FILE"
  _MOCK_LABEL_SWAP_FAILS=0
  _MOCK_DISPATCH_CALLS=""
  _MOCK_POST_TOKEN_CALLS=""
  _MOCK_MARK_STALLED_CALLS=""
  _MOCK_COMMENT_COUNT=0
  _MOCK_HUMAN_QUOTE_COMMENTS=0
  _MOCK_MACHINE_MIDBODY_QUOTES=0
  _MOCK_HUMAN_TRAILER_QUOTE=""
  _MOCK_OTHERBOT_TRAILER_QUOTE=""
  _MOCK_ROUNDS_AUTHORKIND="self"
  _MOCK_VERDICT_AUTHORKIND=""
  _MOCK_LAST_COMMENT_BODY=""
  _MOCK_FULL_COMMENT_LOG=""
  _MOCK_PR_HEAD=""
  _MOCK_PR_NUMBER="777"
  _MOCK_LAST_REVIEWED_HEAD=""
  _MOCK_BOT_UNFIXABLE=1
  _MOCK_FROZEN_ROUND_COMMENTS=0
  _MOCK_STALE_ROUNDS=0
  _MOCK_STALE_VERDICT_TRAILER="<!-- review-verdict: failed-non-substantive cause=bot-timeout -->"
  _MOCK_ROUND_VERDICT_TRAILER="<!-- review-verdict: failed-substantive -->"
  _MOCK_NONACT_MARKER_PRESENT=0
  _MOCK_CB_MARKER_PRESENT=0
  _MOCK_CB_MARKER_HASH=""
  _MOCK_CB_MARKER_SESSION=""
  _MOCK_CB_MARKER_AUTHORKIND="self"
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
echo "=== count_frozen_convergence_rounds: trailer-joined active-case window ([P1] finding 1) ==="
AC_SUB="$(convergence_canonical failed-substantive "" true)"   # the active case: failed-substantive||true

# Baseline: 3 rounds each preceded by a matching failed-substantive verdict → counted.
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
assert_eq "counts 3 active-case (matching-trailer) rounds" "3" "$(count_frozen_convergence_rounds 100 deadbeef "$AC_SUB")"

# CB-COUNT-009a: STALE failed-non-substantive rounds on the SAME head are EXCLUDED —
# only the 2 active-case rounds count (does NOT trip at threshold 3). This is the
# early-trip fix: stale history no longer inflates the count.
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_STALE_ROUNDS=4                    # 4 stale failed-non-substantive rounds
_MOCK_FROZEN_ROUND_COMMENTS=2          # 2 active-case rounds
assert_eq "CB-COUNT-009a: stale non-substantive rounds excluded (only 2 active count, not 6)" "2" "$(count_frozen_convergence_rounds 100 deadbeef "$AC_SUB")"

# CB-COUNT-009b: a prior dev-actionable=false round on the SAME head is EXCLUDED
# (different canonical) but does NOT zero-out the genuine active-case rounds — this
# is the forever-suppression fix (old blanket non-actionable-finding zero-out gone).
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_STALE_ROUNDS=1
_MOCK_STALE_VERDICT_TRAILER="<!-- review-verdict: failed-substantive dev-actionable=false -->"  # #298 round
_MOCK_FROZEN_ROUND_COMMENTS=3
assert_eq "CB-COUNT-009b: prior dev-actionable=false round excluded, active 3 still counted (no forever-suppression)" "3" "$(count_frozen_convergence_rounds 100 deadbeef "$AC_SUB")"

# CB-COUNT-009c: the active canonical MUST match — asking for a DIFFERENT case
# (a different cause) counts 0 of the failed-substantive||true rounds.
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
assert_eq "CB-COUNT-009c: non-matching active canonical → 0" "0" "$(count_frozen_convergence_rounds 100 deadbeef "$(convergence_canonical failed-non-substantive ci-transport true)")"

assert_eq "empty head → 0" "0" "$(count_frozen_convergence_rounds 100 "" "$AC_SUB")"
assert_eq "empty canonical → 0" "0" "$(count_frozen_convergence_rounds 100 deadbeef "")"

# CB-COUNT-009d (round-7 [P1] regression): comments QUOTING the round line are
# excluded — a human quote (authorKind=human) and a machine comment embedding the
# line MID-BODY both fail the authenticity filters; only the 2 genuine dispatcher
# rounds count. A naive contains() scan would return 4 here (the reviewer
# reproduced 3-with-only-2-real on live data).
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=2
_MOCK_HUMAN_QUOTE_COMMENTS=1
_MOCK_MACHINE_MIDBODY_QUOTES=1
assert_eq "CB-COUNT-009d: human quote + mid-body machine quote excluded (2 counted, not 4)" "2" "$(count_frozen_convergence_rounds 100 deadbeef "$AC_SUB")"

# CB-COUNT-009f (token-mode / empty BOT_LOGIN): with BOT_LOGIN unset the provider
# has no self identity to match, so it normalizes the dispatcher's OWN comments
# to authorKind=human — the strict author filter would exclude GENUINE rounds
# and kill the breaker in GH_AUTH_MODE=token. The strictness gate drops the
# author filter when BOT_LOGIN is empty (rounds counted via the startswith
# anchor alone); the mid-body machine quote stays excluded by the anchor.
# _MOCK_ROUNDS_AUTHORKIND=human simulates the token-mode normalization.
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
_MOCK_MACHINE_MIDBODY_QUOTES=1
_MOCK_ROUNDS_AUTHORKIND="human"
_saved_bot_login="$BOT_LOGIN"; BOT_LOGIN=""
assert_eq "CB-COUNT-009f: empty BOT_LOGIN (token mode) — genuine rounds (normalized human) still counted (3), mid-body quote still excluded" \
  "3" "$(count_frozen_convergence_rounds 100 deadbeef "$AC_SUB")"
BOT_LOGIN="$_saved_bot_login"

# CB-COUNT-009g: the strictness gate is gated on BOT_LOGIN — with it SET, the
# same human-authorKind rounds ARE excluded (proves 009f's acceptance flows from
# the gate, not from a hole in the author filter).
assert_eq "CB-COUNT-009g: BOT_LOGIN set — human-authorKind rounds excluded (0)" \
  "0" "$(count_frozen_convergence_rounds 100 deadbeef "$AC_SUB")"

# CB-COUNT-009e: the quote exclusions must not FLIP a below-threshold case above
# it — 2 real + 2 quotes stays 2 (< threshold 3) so the breaker does not trip
# (routing proceeds without a convergence halt).
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=2
_MOCK_HUMAN_QUOTE_COMMENTS=2
_MOCK_PID_ALIVE=1
prepare_log 100
handle_completed_session_routing 100 "sid-cb009e" "2026-05-21T03:18:00Z"
assert_not_contains "CB-COUNT-009e: 2 real + 2 quoted rounds does NOT trip the breaker" \
  "reason=non-convergence" "$_MOCK_FULL_COMMENT_LOG"
assert_not_contains "CB-COUNT-009e: no stalled transition" "pending-dev:stalled" "$_MOCK_LABEL_SWAPS"

# ===========================================================================
echo ""
echo "=== CB-COUNT-009h/i/j: preceding-verdict AUTHENTICITY (round-11 [P1] BLOCKING) ==="

# CB-COUNT-009h: the ONLY genuine preceding verdict is failed-non-substantive
# (does not match the active canonical), but a HUMAN comment posted between it
# and the round comment QUOTES a matching failed-substantive trailer. Before
# the fix, the unauthenticated `last` selection would pick the human quote and
# count the round; after the fix, the quote is rejected and the genuine
# (non-matching) verdict is used instead — round excluded, count 0.
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=1
_MOCK_STALE_ROUNDS=0
_MOCK_ROUND_VERDICT_TRAILER="<!-- review-verdict: failed-non-substantive cause=bot-timeout -->"
_MOCK_HUMAN_TRAILER_QUOTE="Just quoting for context: <!-- review-verdict: failed-substantive -->"
assert_eq "CB-COUNT-009h: human quote of a matching trailer is REJECTED — genuine non-substantive verdict used, round excluded (0)" \
  "0" "$(count_frozen_convergence_rounds 100 deadbeef "$AC_SUB")"

# CB-COUNT-009i: same shape, but the impersonating comment is from a DIFFERENT
# bot (authorKind=bot, author != BOT_LOGIN) rather than a human — the exact
# author==BOT_LOGIN binding rejects it regardless of authorKind.
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=1
_MOCK_STALE_ROUNDS=0
_MOCK_ROUND_VERDICT_TRAILER="<!-- review-verdict: failed-non-substantive cause=bot-timeout -->"
_MOCK_OTHERBOT_TRAILER_QUOTE="<!-- review-verdict: failed-substantive -->"
assert_eq "CB-COUNT-009i: a DIFFERENT bot's trailer is REJECTED (author != BOT_LOGIN) — round excluded (0)" \
  "0" "$(count_frozen_convergence_rounds 100 deadbeef "$AC_SUB")"

# CB-COUNT-009j: regression guard — the genuine bot verdict is STILL picked up
# (and the round STILL counted) even when a human/other-bot quote is also
# present, as long as the genuine trailer's canonical matches the active case.
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=1
_MOCK_STALE_ROUNDS=0
_MOCK_ROUND_VERDICT_TRAILER="<!-- review-verdict: failed-substantive -->"
_MOCK_HUMAN_TRAILER_QUOTE="Just quoting for context: <!-- review-verdict: failed-non-substantive cause=x -->"
assert_eq "CB-COUNT-009j: genuine matching trailer still counted despite an unrelated human quote present" \
  "1" "$(count_frozen_convergence_rounds 100 deadbeef "$AC_SUB")"

# CB-COUNT-009k: BOT_LOGIN-empty fallback (token mode) — the structural
# startswith anchor still rejects the human quote (proves the fallback path,
# not just the strict-author path, closes the round-11 finding).
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=1
_MOCK_STALE_ROUNDS=0
_MOCK_ROUND_VERDICT_TRAILER="<!-- review-verdict: failed-non-substantive cause=bot-timeout -->"
_MOCK_HUMAN_TRAILER_QUOTE="Just quoting for context: <!-- review-verdict: failed-substantive -->"
_saved_bot_login="$BOT_LOGIN"; BOT_LOGIN=""
assert_eq "CB-COUNT-009k: BOT_LOGIN empty — human quote (prose before trailer) still rejected via startswith anchor (0)" \
  "0" "$(count_frozen_convergence_rounds 100 deadbeef "$AC_SUB")"
BOT_LOGIN="$_saved_bot_login"

# ===========================================================================
echo ""
echo "=== CB-COUNT-009l/m/n: preceding-verdict authenticity is STRUCTURAL, not actor-based (round-13 BLOCKING) ==="

# CB-COUNT-009l: the REAL GH_AUTH_MODE=token topology — BOT_LOGIN is unset (as
# it ALWAYS is in the dispatcher's own process; it is resolved only inside
# autonomous-review.sh's SEPARATE process) AND the review wrapper's genuine
# verdict comments normalize to authorKind=human (shared PAT identity, same as
# the dispatcher's own comments). Before the fix, `authentic_verdict`'s
# empty-BOT_LOGIN fallback required `authorKind != "human"`, which REJECTED
# these genuine verdicts outright — count stayed 0 forever, Branch B″ dead in
# token mode. After the fix (structural `startswith` anchor, author-independent),
# these bare-trailer comments authenticate correctly.
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
_MOCK_ROUNDS_AUTHORKIND="human"    # token mode: the dispatcher's own comments too
_MOCK_VERDICT_AUTHORKIND="human"   # round-13: the review wrapper's verdict ALSO normalizes to human
_saved_bot_login="$BOT_LOGIN"; BOT_LOGIN=""
assert_eq "CB-COUNT-009l: token mode (BOT_LOGIN empty, verdict authorKind=human) — genuine rounds STILL counted (3)" \
  "3" "$(count_frozen_convergence_rounds 100 deadbeef "$AC_SUB")"
BOT_LOGIN="$_saved_bot_login"

# CB-COUNT-009m: end-to-end token-mode trip — the breaker must actually HALT
# the loop in this topology (not just report a non-zero count in isolation).
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
_MOCK_ROUNDS_AUTHORKIND="human"
_MOCK_VERDICT_AUTHORKIND="human"
_MOCK_PID_ALIVE=1
_saved_bot_login="$BOT_LOGIN"; BOT_LOGIN=""
prepare_log 100
handle_completed_session_routing 100 "sid-cb009m" "2026-05-21T03:18:00Z"
assert_eq "CB-COUNT-009m: token-mode end-to-end trip (label_swap pending-dev → stalled)" \
  "100:pending-dev:stalled " "$_MOCK_LABEL_SWAPS"
assert_eq "CB-COUNT-009m: posts the report" "1" "$_MOCK_COMMENT_COUNT"
BOT_LOGIN="$_saved_bot_login"

# CB-COUNT-009n (regression guard): the round-11 human-quote-with-prose
# rejection MUST still hold even in the token-mode topology (structural
# startswith, not authorKind, is what excludes it) — proves the fix didn't
# simply stop checking anything.
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=1
_MOCK_ROUND_VERDICT_TRAILER="<!-- review-verdict: failed-non-substantive cause=bot-timeout -->"
_MOCK_HUMAN_TRAILER_QUOTE="Just quoting for context: <!-- review-verdict: failed-substantive -->"
_MOCK_ROUNDS_AUTHORKIND="human"
_MOCK_VERDICT_AUTHORKIND="human"
_saved_bot_login="$BOT_LOGIN"; BOT_LOGIN=""
assert_eq "CB-COUNT-009n: even in token mode, a human quote WITH PROSE before the trailer is still rejected (0)" \
  "0" "$(count_frozen_convergence_rounds 100 deadbeef "$AC_SUB")"
BOT_LOGIN="$_saved_bot_login"

# CB-COUNT-009o (round-14 [Critical]): a forged comment pastes the trailer
# text VERBATIM and then appends MORE content AFTER it (the mirror-image of
# 009n's prose-BEFORE case) — round-13's first fix used a bare `startswith`
# anchor, which is satisfied by ANY body beginning with the trailer text
# regardless of what follows, so this forgery would have authenticated and
# won the `last`-before-round selection over the genuine non-matching verdict,
# inflating the count. The round-14 fix anchors the match at BOTH ends
# (`^...$`), which this forgery fails (trailing content after the closing
# `-->`). Must run with BOT_LOGIN EMPTY — the permanent topology at this call
# site — so the structural anchor (not `.author == BOT_LOGIN`) is the thing
# actually under test.
reset_mocks
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=1
_MOCK_ROUND_VERDICT_TRAILER="<!-- review-verdict: failed-non-substantive cause=bot-timeout -->"
_MOCK_HUMAN_TRAILER_QUOTE="<!-- review-verdict: failed-substantive --> (editing my comment above, ignore the old one)"
_saved_bot_login="$BOT_LOGIN"; BOT_LOGIN=""
assert_eq "CB-COUNT-009o: a forged trailer with TRAILING content after it is still rejected (0)" \
  "0" "$(count_frozen_convergence_rounds 100 deadbeef "$AC_SUB")"
BOT_LOGIN="$_saved_bot_login"

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
assert_contains "CB-REPORT-008 resume instruction present" "REMOVE the \`stalled\` label" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "CB-REPORT-008 repeated-failure count present" "Repeated-failure count on this frozen head: **3**" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "CB-REPORT-008 verbatim finding excerpt present" "acceptance criterion #3 contradicts #1" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "CB-REPORT-008 human-action checklist present" "Human action needed" "$_MOCK_LAST_COMMENT_BODY"
# [P1] finding 2: per-round timestamps of the counted rounds are in the evidence block.
assert_contains "CB-REPORT-008/finding-2 per-round timestamps label present" "Counted completed dev-resume rounds (timestamps):" "$_MOCK_LAST_COMMENT_BODY"
assert_contains "CB-REPORT-008/finding-2 an actual round timestamp present (ISO)" "2026-06-12T00:" "$_MOCK_LAST_COMMENT_BODY"
# The timestamps line must NOT be the "(unavailable)" fallback when rounds exist.
if [[ "$_MOCK_LAST_COMMENT_BODY" == *"Counted completed dev-resume rounds (timestamps): (unavailable)"* ]]; then
  echo -e "  ${RED}FAIL${NC}: CB-REPORT-008/finding-2 timestamps fell back to (unavailable) despite counted rounds"; FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: CB-REPORT-008/finding-2 timestamps populated (not the unavailable fallback)"; PASS=$((PASS + 1))
fi

# ===========================================================================
echo ""
echo "=== CB-ATOMIC-013/014: marker atomic with the transition (round-10 [P1] finding 1) ==="

# CB-ATOMIC-013: on a successful trip, label_swap (the transition) is called
# STRICTLY BEFORE itp_post_comment (the marker/report) — the fix ordering.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
_MOCK_PID_ALIVE=1
prepare_log 100
handle_completed_session_routing 100 "sid-atomic013" "2026-05-21T03:18:00Z" >/dev/null
assert_eq "CB-ATOMIC-013 label_swap called before itp_post_comment" \
  "$(printf 'label_swap\nitp_post_comment')" "$(cat "$_CALL_ORDER_FILE")"

# CB-ATOMIC-014: if label_swap FAILS (transient transport error), under the
# real dispatcher's `set -euo pipefail` the bare `label_swap` statement aborts
# the function BEFORE the marker/report is ever posted — no orphan marker, no
# state left claiming "reported" while the issue is still `pending-dev`. Drive
# this in a real `set -e` subshell (the harness itself runs `set +e` so it can
# keep asserting after a routing call returns non-zero). `_CALL_ORDER_FILE` is a
# real file, so the subshell's write to it survives past the subshell exiting —
# unlike a plain bash variable, which a subshell can never mutate in the parent.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
_MOCK_PID_ALIVE=1
_MOCK_LABEL_SWAP_FAILS=1
prepare_log 100
(
  set -e
  handle_completed_session_routing 100 "sid-atomic014" "2026-05-21T03:18:00Z" >/dev/null
) 2>/dev/null
rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo -e "  ${GREEN}PASS${NC}: CB-ATOMIC-014 a failing label_swap aborts under set -e (rc=$rc)"; PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: CB-ATOMIC-014 expected a non-zero abort when label_swap fails under set -e"; FAIL=$((FAIL + 1))
fi
assert_eq "CB-ATOMIC-014 NO marker/report posted when the transition failed" "0" "$_MOCK_COMMENT_COUNT"
assert_eq "CB-ATOMIC-014 label_swap was attempted (recorded via the survives-subshell file)" \
  "label_swap" "$(cat "$_CALL_ORDER_FILE")"
assert_eq "CB-ATOMIC-014 the label state did NOT change (label_swap failed)" "" "$_MOCK_LABEL_SWAPS"

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
echo "=== CB-IDEM-006: same {issue,head,trailer-hash,session} marker already present → no-op ==="
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
_MOCK_CB_MARKER_SESSION="sid-cb006"  # round-12: SAME session as this call — the true idempotency case
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
_MOCK_CB_MARKER_SESSION="sid-cb007"           # SAME session — isolates the hash mismatch as the cause of re-evaluation
prepare_log 100
handle_completed_session_routing 100 "sid-cb007" "2026-05-21T03:18:00Z"
assert_eq "CB-IDEM-007 trips (new hash not suppressed)" "100:pending-dev:stalled " "$_MOCK_LABEL_SWAPS"
assert_eq "CB-IDEM-007 posts the fresh report" "1" "$_MOCK_COMMENT_COUNT"

# ===========================================================================
echo ""
echo "=== CB-IDEM-015/016/017: session-scoped dedupe + authenticity (round-12 BLOCKING) ==="

# CB-IDEM-015: a marker from a PRIOR, already-resolved trip (a DIFFERENT
# session-id, same {head, trailer-hash}) is present on the issue — e.g. the
# operator followed the documented resume step (removed `stalled`), and the
# SAME frozen-head+verdict case genuinely recurred in a NEW dev session. Before
# the fix, the stale marker made the breaker "one-shot only" (silently no-op'd
# forever). After the fix, a DIFFERENT session-id → a DIFFERENT marker → trips.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_CAUSE=""
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
_MOCK_PID_ALIVE=1
_MOCK_CB_MARKER_PRESENT=1
_MOCK_CB_MARKER_HASH="$(convergence_trailer_hash failed-substantive "" true)"  # SAME hash as the current case
_MOCK_CB_MARKER_SESSION="sid-OLD-session"  # a PRIOR, already-resolved trip's session
prepare_log 100
handle_completed_session_routing 100 "sid-NEW-session" "2026-05-21T03:18:00Z"
assert_eq "CB-IDEM-015: stale marker from a PRIOR session does NOT suppress a fresh trip (re-arm re-trips)" \
  "100:pending-dev:stalled " "$_MOCK_LABEL_SWAPS"
assert_eq "CB-IDEM-015: posts the fresh report" "1" "$_MOCK_COMMENT_COUNT"
assert_contains "CB-IDEM-015: the NEW marker carries the NEW session id" "session=sid-NEW-session" "$_MOCK_LAST_COMMENT_BODY"

# CB-IDEM-016: a HUMAN comment QUOTES the exact marker for THIS session (not a
# genuine dispatcher post) — must NOT suppress the halt while the issue is
# still `pending-dev`. The quote is injected via _MOCK_CB_MARKER_AUTHORKIND.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_CAUSE=""
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
_MOCK_PID_ALIVE=1
_MOCK_CB_MARKER_PRESENT=1
_MOCK_CB_MARKER_HASH="$(convergence_trailer_hash failed-substantive "" true)"
_MOCK_CB_MARKER_SESSION="sid-cb016"          # SAME session as this call
_MOCK_CB_MARKER_AUTHORKIND="human"           # a human QUOTED the marker, did not genuinely post it
prepare_log 100
handle_completed_session_routing 100 "sid-cb016" "2026-05-21T03:18:00Z"
assert_eq "CB-IDEM-016: a human quote of the marker does NOT suppress the halt" \
  "100:pending-dev:stalled " "$_MOCK_LABEL_SWAPS"
assert_eq "CB-IDEM-016: posts the report despite the quote being present" "1" "$_MOCK_COMMENT_COUNT"

# CB-IDEM-017: BOT_LOGIN-empty fallback — the coarse authorKind!=human bound
# still rejects a human quote of the marker (proves the fallback path too).
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_CAUSE=""
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
_MOCK_PID_ALIVE=1
_MOCK_CB_MARKER_PRESENT=1
_MOCK_CB_MARKER_HASH="$(convergence_trailer_hash failed-substantive "" true)"
_MOCK_CB_MARKER_SESSION="sid-cb017"
_MOCK_CB_MARKER_AUTHORKIND="human"
_saved_bot_login="$BOT_LOGIN"; BOT_LOGIN=""
prepare_log 100
handle_completed_session_routing 100 "sid-cb017" "2026-05-21T03:18:00Z"
assert_eq "CB-IDEM-017: BOT_LOGIN empty — human quote still rejected via authorKind!=human fallback" \
  "100:pending-dev:stalled " "$_MOCK_LABEL_SWAPS"
BOT_LOGIN="$_saved_bot_login"

# CB-IDEM-018 (regression guard): a GENUINE self-authored marker for the SAME
# session still suppresses — the fix must not over-reject true idempotency.
reset_mocks
_MOCK_VERDICT="failed-substantive"
_MOCK_DEV_ACTIONABLE="true"
_MOCK_CAUSE=""
_MOCK_PR_HEAD="deadbeef"
_MOCK_LAST_REVIEWED_HEAD="deadbeef"
_MOCK_FROZEN_ROUND_COMMENTS=3
_MOCK_PID_ALIVE=1
_MOCK_CB_MARKER_PRESENT=1
_MOCK_CB_MARKER_HASH="$(convergence_trailer_hash failed-substantive "" true)"
_MOCK_CB_MARKER_SESSION="sid-cb018"
_MOCK_CB_MARKER_AUTHORKIND="self"
prepare_log 100
handle_completed_session_routing 100 "sid-cb018" "2026-05-21T03:18:00Z"
assert_eq "CB-IDEM-018: genuine same-session marker still suppresses (true idempotency preserved)" "" "$_MOCK_LABEL_SWAPS"
assert_eq "CB-IDEM-018: posts nothing" "0" "$_MOCK_COMMENT_COUNT"

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
echo "=== recent_review_verdict_body: skips wrapper-metadata comments, returns the actual findings body ==="
# Every other test in this file mocks recent_review_verdict_body() (line ~97) so
# the routing tests don't depend on comment-scan details. This section tests the
# REAL function against a realistic review-round comment sequence — the review
# wrapper posts the agent's `Review findings:` body FIRST, then its own
# `Reviewed HEAD: ...` forensic-attribution comment, then the bare
# `<!-- review-verdict: ... -->` trailer (lib-review-verdict.sh::emit_verdict_trailer),
# all same-actor and each later than the last. A naive "newest bot comment"
# selection (what classify_recent_review_verdict correctly uses, since IT wants
# the trailer) would return the bare trailer or the Reviewed-HEAD line here
# instead of the findings text the [INV-103] evidence block needs to quote.
# The mock at line ~97 shadowed the real function the moment it was defined
# (both are top-level `name() { ... }` defs in the same shell — there is no
# saved original to `unset -f` back to). Re-extract and re-source ONLY the real
# `recent_review_verdict_body` definition from $LIB so this section exercises
# the actual implementation, not the mock.
_rrvb_real_fn="$(awk '/^recent_review_verdict_body\(\) \{/,/^}/' "$LIB")"
eval "$_rrvb_real_fn"
_RRVB_FINDINGS_BODY="Review findings:

Findings->Decision Gate: 1 blocking finding(s) -- FAIL.

1. **[BLOCKING] acceptance criterion #3 contradicts #1** — cannot satisfy both."
_RRVB_SESSION_END="2026-06-12T09:00:00Z"
itp_list_comments() {
  jq -c -n \
    --arg findings "$_RRVB_FINDINGS_BODY" \
    --arg reviewed_head "Reviewed HEAD: \`abc1234\` (issue #42, session \`sid-1\`, agent \`claude\`, model \`sonnet\`)" \
    --arg trailer "<!-- review-verdict: failed-substantive -->" \
    '[
      {id: 201, author: "kane-review-agent", authorKind: "bot", body: $findings, createdAt: "2026-06-12T09:05:00Z"},
      {id: 202, author: "kane-review-agent", authorKind: "bot", body: $reviewed_head, createdAt: "2026-06-12T09:05:01Z"},
      {id: 203, author: "kane-review-agent", authorKind: "bot", body: $trailer, createdAt: "2026-06-12T09:05:02Z"}
    ]'
}
_rrvb_result=$(recent_review_verdict_body "42" "$_RRVB_SESSION_END")
assert_eq "RRVB-001 returns the agent's findings body, not the newest (trailer) comment" \
  "$_RRVB_FINDINGS_BODY" "$_rrvb_result"
assert_eq "RRVB-002 result is not the bare verdict trailer" \
  "no" "$([[ "$_rrvb_result" == "<!-- review-verdict: failed-substantive -->" ]] && echo yes || echo no)"
assert_eq "RRVB-003 result is not the Reviewed-HEAD metadata line" \
  "no" "$([[ "$_rrvb_result" == "Reviewed HEAD:"* ]] && echo yes || echo no)"

# RRVB-004: only the metadata comments exist after session_end (no findings comment
# in the window, e.g. the findings comment predates session_end) — falls back to
# empty rather than returning the trailer or Reviewed-HEAD line as a false "finding".
itp_list_comments() {
  jq -c -n \
    --arg reviewed_head "Reviewed HEAD: \`abc1234\` (issue #42, session \`sid-1\`, agent \`claude\`, model \`sonnet\`)" \
    --arg trailer "<!-- review-verdict: failed-substantive -->" \
    '[
      {id: 202, author: "kane-review-agent", authorKind: "bot", body: $reviewed_head, createdAt: "2026-06-12T09:05:01Z"},
      {id: 203, author: "kane-review-agent", authorKind: "bot", body: $trailer, createdAt: "2026-06-12T09:05:02Z"}
    ]'
}
_rrvb_result2=$(recent_review_verdict_body "42" "$_RRVB_SESSION_END")
assert_eq "RRVB-004 no findings comment in window → empty (never the trailer/Reviewed-HEAD as a false finding)" \
  "" "$_rrvb_result2"

# RRVB-005: a real findings comment that happens to MENTION "Reviewed HEAD" or a
# verdict trailer mid-body (not as its literal opening) is NOT excluded — the
# exclusion is a structural startswith(), not a substring/contains() check.
itp_list_comments() {
  jq -c -n \
    --arg findings "Review findings:

1. [BLOCKING] the dispatcher's Reviewed HEAD comment and the <!-- review-verdict: ... --> trailer are both posted separately from this comment; see design doc." \
    '[{id: 301, author: "kane-review-agent", authorKind: "bot", body: $findings, createdAt: "2026-06-12T09:05:00Z"}]'
}
_rrvb_result3=$(recent_review_verdict_body "42" "$_RRVB_SESSION_END")
assert_contains "RRVB-005 a findings body that merely MENTIONS the excluded phrases mid-body is NOT excluded" \
  "[BLOCKING] the dispatcher's Reviewed HEAD comment" "$_rrvb_result3"

# Restore the routing-side mock for any test that might run after this section
# (source-order safety; this section is currently last).
recent_review_verdict_body() { printf '%s' "$_MOCK_VERDICT_BODY"; }

# ===========================================================================
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
