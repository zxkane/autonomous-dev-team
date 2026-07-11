#!/bin/bash
# lib-review-round.sh — review-round counter (issue #449, R1).
#
# An explicit review-round counter, independent of REVIEW_RETRY_LIMIT's
# failed-non-substantive flip counter (lib-dispatch.sh::count_review_aware_flips)
# and INV-105's frozen-convergence dev-resume-round counter
# (lib-dispatch.sh::count_frozen_convergence_rounds) — neither of those measures
# "how many times has the review agent fan-out actually run against this PR
# head." This counter feeds the severity-aware blocking ratchet
# (lib-review-severity.sh::shouldBlockFinding): later rounds progressively
# narrow the blocking floor, so the wrapper needs to know which round it is.
#
# State storage mirrors INV-122's `dispatcher-gate-fail-breaker` marker
# convention: a structured HTML-comment marker, posted by the review wrapper
# on every round (not only some), scoped to (issue, head):
#
#   <!-- review-round-counter: issue=<N> head=<sha> round=<n> -->
#
# Scoped to (issue, head) — a new HEAD (new commit pushed) resets round to 1;
# the counter increments only while the HEAD is unchanged. The marker read at
# the call site (autonomous-review.sh) filters to `authorKind != "human"`
# (mirrors INV-105/INV-122's own marker-authenticity filter) so a forged
# marker from an ordinary collaborator comment can never be read as the prior
# round count.

# _review_round_marker <issue> <head> <round> — construct the marker text.
_review_round_marker() {
  local issue="$1" head="$2" round="$3"
  printf '<!-- review-round-counter: issue=%s head=%s round=%s -->' \
    "$issue" "$head" "$round"
}

# _review_round_parse_count <marker_text> <head> — echo the round field from
# marker_text IFF it matches the given head; else echo 0. Pure substring/regex
# extraction — no I/O. A malformed, absent, or non-matching marker all
# collapse to 0 (bias to MISS: never crash, never silently inherit an
# unrelated head's round).
_review_round_parse_count() {
  local marker_text="$1" head="$2"
  local pattern="review-round-counter: issue=[0-9]+ head=${head} round=([0-9]+)"
  if [[ "$marker_text" =~ $pattern ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '0\n'
  fi
}

# _review_round_next_count <marker_text> <head> — the round THIS review pass
# should use: stored_round+1 when marker_text matches head exactly, else 1 (a
# fresh series under a new head — new commit pushed since the last marker, or
# no prior marker at all).
_review_round_next_count() {
  local marker_text="$1" head="$2" stored
  stored=$(_review_round_parse_count "$marker_text" "$head")
  printf '%s\n' "$((stored + 1))"
}
