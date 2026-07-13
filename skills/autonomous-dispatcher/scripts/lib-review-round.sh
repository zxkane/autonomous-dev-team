#!/bin/bash
# lib-review-round.sh — review-round counter (issue #449 R1; redefined
# head-agnostic by issue #475, INV-129).
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
# [INV-129, issue #475] REDEFINED head-agnostic: REVIEW_ROUND is now the
# length of the current series of CONSECUTIVE decided `failed-substantive`
# rounds (plus 1), accumulating ACROSS head changes — not scoped to
# (issue, head) as issue #449 originally shipped it. The original head-scoped
# reset-on-every-push semantics never let the floor loosen past round 1-2 in
# an ACTIVE dev↔review loop (a new fix commit every round — #449's own
# motivating scenario), so a loop sustained by a new P2/P3 finding each round
# was bounded by no mechanism at all (see INV-129 in invariants.md for the
# full gap analysis). This lib now reuses INV-127's proven
# cutoff-then-scan grammar (`_review_round_prior_marker`, mirroring
# `_review_cap_prior_marker` in lib-review-cap.sh) instead of a head match.
#
# State storage mirrors INV-122's `dispatcher-gate-fail-breaker` marker
# convention: a structured HTML-comment marker, posted by the review wrapper
# on every DECIDED round, head-AGNOSTIC:
#
#   <!-- review-round-counter: issue=<N> head=<sha|unknown> round=<n> -->
#
# `head` is forensic-only (which head was under review at each round) — NOT
# a reset key. Resets happen via explicit channels only (see
# `_review_round_prior_marker` below): a `passed`/`failed-non-substantive`
# `review-verdict` trailer, an INV-127 trip report, or an explicit `round=0`
# marker (R3, posted on every PASS round). The marker read at the call site
# (autonomous-review.sh) filters to `authorKind != "human"` (mirrors
# INV-105/INV-122's own marker-authenticity filter) so a forged marker from
# an ordinary collaborator comment can never be read as the prior round
# count.

# _review_round_marker <issue> <head> <round> — construct the marker text.
# An empty/unset <head> renders as the literal placeholder "unknown" rather
# than an empty field — mirrors `_review_cap_marker`'s (lib-review-cap.sh)
# own placeholder rationale verbatim: the head is forensic-only here (this
# counter is head-AGNOSTIC), but an empty field would render an ugly
# "head= round=N" AND could accidentally fail to match a future stricter
# parse regex. A transient PR_HEAD_SHA read failure must never silently
# block this counter's series from advancing or being recorded.
_review_round_marker() {
  local issue="$1" head="${2:-unknown}" round="$3"
  [[ -n "$head" ]] || head="unknown"
  printf '<!-- review-round-counter: issue=%s head=%s round=%s -->' \
    "$issue" "$head" "$round"
}

# _review_round_parse_count <marker_text> — echo the round field from
# marker_text (head-AGNOSTIC, [INV-129]). The head token itself is matched
# permissively (`head=.*`, mirroring `_review_cap_parse_count`'s own
# permissive head match) so a legacy head-KEYED marker (posted by the
# pre-#475 code, carrying a real sha in the `head=` field rather than the
# post-#475 forensic-only placeholder) still parses instead of silently
# collapsing to 0. Pure substring/regex extraction — no I/O. A malformed or
# absent marker collapses to 0 (bias to MISS: never crash, never silently
# inherit a garbled count).
_review_round_parse_count() {
  local marker_text="$1"
  local pattern="review-round-counter: issue=[0-9]+ head=.* round=([0-9]+)"
  if [[ "$marker_text" =~ $pattern ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '0\n'
  fi
}

# _review_round_next_count <marker_text> — the round THIS review pass
# should use: stored_round+1 when marker_text parses, else 1 (a fresh series
# — no prior marker at all, or the prior marker's own round field was 0, e.g.
# the R3 reset marker posted on a PASS round).
_review_round_next_count() {
  local marker_text="$1" stored
  stored=$(_review_round_parse_count "$marker_text")
  printf '%s\n' "$((stored + 1))"
}

# _review_round_prior_marker <comments_json>
#
# [INV-129, issue #475 R2] Pure resume-cutoff logic, mirroring
# `_review_cap_prior_marker` (lib-review-cap.sh) — a SIBLING function, NOT a
# widening of the cap's own function (INV-122's sibling-breaker precedent:
# the two counters have independent state and independent reset triggers,
# even though they now share the same cutoff-then-scan shape).
#
# Given the FULL itp_list_comments JSON array for the issue, echoes the
# prior review-round-counter marker body that _review_round_next_count
# should read — or "" if none qualifies.
#
# Cutoff = max of:
#   (a) the latest full-body-anchored `passed`/`failed-non-substantive`
#       `review-verdict` trailer (authorKind != "human", `.body` type-string
#       guarded) — a PASS or non-substantive-FAIL round is evidence the
#       series was resolved/not-a-real-substantive-failure, so a LATER
#       substantive fail must not inherit a stale pre-reset round. (R3 also
#       posts an explicit `round=0` marker on PASS rounds as a second,
#       independent reset channel — see this file's own module doc — but
#       this trailer-based cutoff catches the case where that marker post
#       itself failed, e.g. a transient itp_post_comment failure.)
#   (b) the latest INV-127 trip report (body matching
#       "Review-round-cap circuit-breaker tripped"). Explicit rule: an
#       INV-127 trip is ITSELF a reset cutoff — after an operator removes
#       `stalled` and the loop resumes, the next review runs at round 1 (the
#       strictest floor), rather than inheriting the pre-trip series.
#
# INV-105/INV-122 trip reports are deliberately NOT cutoffs here: those
# stalls are dev-side inaction / same-head E2E-gate fixed points — neither is
# evidence the review-round series itself was wrong, and the series
# legitimately continues across them (it is head-agnostic and does not care
# whether the dev side made progress or the E2E gate flapped).
#
# All jq comparisons additionally require `.body` to be a JSON string before
# `test()` runs on it (a bot-authored comment can carry a `null` body — a
# real GitHub REST shape; `test()` on `null` is a jq RUNTIME ERROR, not a
# per-row non-match). Fail-safe: any jq failure yields "" — "no prior
# marker" is the same first-round default a genuine crash-then-recovery
# would want.
_review_round_prior_marker() {
  local comments_json="$1"
  jq -r '
    ( [ .[] | select(.authorKind != "human") | select(.body | type == "string") ] ) as $rows
    | ( [ $rows[] | select(.body | test("Review-round-cap circuit-breaker tripped")) | .createdAt ]
        + ["1970-01-01T00:00:00Z"] | max ) as $trip_cutoff
    | ( [ $rows[] | select(.body | test("^<!--[[:space:]]*review-verdict:[[:space:]]*(passed|failed-non-substantive)[^>]*-->[[:space:]]*$")) | .createdAt ]
        + ["1970-01-01T00:00:00Z"] | max ) as $reset_cutoff
    | ( [$trip_cutoff, $reset_cutoff] | max ) as $cutoff
    | ( [ $rows[] | select(.body | test("^<!--[[:space:]]*review-round-counter:[[:space:]]*issue=[0-9]+ head=[^ ]+ round=[0-9]+[[:space:]]*-->[[:space:]]*$")) | select(.createdAt > $cutoff) ]
        | sort_by(.createdAt) | last | .body // "" )
  ' <<<"$comments_json" 2>/dev/null || printf ''
}
