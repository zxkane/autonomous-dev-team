#!/bin/bash
# lib-review-cap.sh — INV-126 review-round-cap escalation breaker (issue #449, R2).
#
# A new, independent breaker — does NOT modify INV-105 (lib-dispatch.sh's
# `count_frozen_convergence_rounds`, a dev-side zero-commit-inaction signal)
# or INV-122 (lib-review-e2e.sh's same-HEAD E2E-gate-fail breaker, a
# fixed-point-repetition signal keyed on an UNCHANGED head). This breaker's
# fingerprint is review-side non-convergence: the review agent(s) keep
# finding a P0/P1 across successive HEADs that the dev agent DID change — the
# severity ratchet's own floor (P0/P1, which always blocks at any round) is
# STILL failing after too many rounds. Mirrors INV-122's precedent of
# shipping a structurally-identical but independently-triggered sibling
# breaker rather than widening an existing one.
#
# Design note — deliberately NOT the same counter as R1's
# `review-round-counter` (lib-review-round.sh): that marker is scoped to
# (issue, head) and RESETS to 1 on every new push, by design (it feeds the
# severity-ratchet's blocking floor for repeated re-review pressure against
# UNCHANGED code — e.g. multi-agent retries). The motivating non-convergence
# case this breaker exists to catch (a downstream consumer project's PR that
# churned 10 review↔dev rounds over ~6 hours, each round with a NEW commit,
# never converging) has a NEW head every round — a counter that resets on
# every head change would never reach any cap in that exact scenario,
# defeating the breaker's purpose. So this counter accumulates across
# CONSECUTIVE `failed-substantive` rounds regardless of whether the head
# changed between them; `head` is recorded in the marker for forensic/audit
# purposes only (which head was under review at each round), not as a reset
# key.
#
# Trigger: this counter reaches REVIEW_CONVERGENCE_CAP (new env var, default
# 5) while the aggregated verdict is still `failed-substantive` under the
# round's own P0/P1 floor. Only `failed-substantive` rounds count —
# `failed-non-substantive` is out of scope (already governed by
# REVIEW_RETRY_LIMIT).
#
# Marker grammar (new, sibling to `dispatcher-gate-fail-breaker`):
#
#   <!-- dispatcher-review-cap-breaker: issue=<N> head=<sha> round=<n> -->

# _review_cap_marker <issue> <head> <round> — construct the marker text. An
# empty/unset <head> (e.g. a transient chp_pr_view failure upstream) renders
# as the literal token "unknown" rather than an empty field — the head is
# forensic-only here (this counter is head-AGNOSTIC, see the design note
# above), but an empty field would render an ugly "head= round=N" AND could
# accidentally fail to match `_review_cap_parse_count`'s own regex on some
# future stricter rewrite. Substituting a non-empty placeholder keeps the
# marker's round field reliably parseable regardless of head availability —
# a transient PR_HEAD_SHA read failure must never silently reset this
# breaker's counter (the counter's whole purpose is catching the case where
# something keeps going wrong round after round).
_review_cap_marker() {
  local issue="$1" head="${2:-unknown}" round="$3"
  [[ -n "$head" ]] || head="unknown"
  printf '<!-- dispatcher-review-cap-breaker: issue=%s head=%s round=%s -->' \
    "$issue" "$head" "$round"
}

# _review_cap_parse_count <marker_text> — echo the round field from
# marker_text (head-AGNOSTIC — see the design note above: this counter
# accumulates across head changes, so unlike INV-122's `_gate_breaker_parse_count`
# it does not gate the match on a specific head). The head token itself is
# matched permissively (`.*`, not requiring non-whitespace) so an OLDER
# marker posted with a genuinely empty head field (pre-placeholder-fix) still
# parses instead of silently collapsing to 0 — a malformed round field is the
# only thing that should ever collapse to 0. A malformed or absent marker
# collapses to 0 (bias to MISS: never crash, never silently inherit a
# garbled count).
_review_cap_parse_count() {
  local marker_text="$1"
  local pattern="dispatcher-review-cap-breaker: issue=[0-9]+ head=.* round=([0-9]+)"
  if [[ "$marker_text" =~ $pattern ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '0\n'
  fi
}

# _review_cap_next_count <marker_text> — the round THIS check should compare
# against the threshold: stored_count+1 when a prior marker parses, else 1
# (first-ever failed-substantive round, or no/malformed prior marker).
_review_cap_next_count() {
  local marker_text="$1" stored
  stored=$(_review_cap_parse_count "$marker_text")
  printf '%s\n' "$((stored + 1))"
}

# _review_cap_threshold — read REVIEW_CONVERGENCE_CAP with the same
# regex-then-fallback shape as GATE_FAIL_STALL_THRESHOLD
# (lib-review-e2e.sh::_gate_breaker_threshold), default 5, floor >=2, and a
# logged warning on any fallback (mirrors INV-122's explicit-floor-plus-warning
# posture).
_review_cap_threshold() {
  local raw="${REVIEW_CONVERGENCE_CAP:-5}"
  local val="$raw"
  if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" -lt 2 ]]; then
    # Always stderr, NEVER via log() — every call site captures this
    # function's stdout via $(...) for the numeric result (mirrors
    # _gate_breaker_threshold's own rationale).
    echo "WARNING: REVIEW_CONVERGENCE_CAP='${raw}' invalid (must be an integer >=2) — falling back to default 5" >&2
    val=5
  fi
  printf '%s\n' "$val"
}

# _review_cap_prior_marker <comments_json>
#
# Pure resume-cutoff logic ([P1] #3 + follow-up [P1] #449 codex review round
# 3): given the FULL itp_list_comments JSON array for the issue, echoes the
# prior dispatcher-review-cap-breaker marker body that _review_cap_next_count
# should read — or "" if none qualifies. Extracted from the wrapper call
# site (rather than left as an inline two-query block) so the fix's crux
# behavior — the cutoff must exclude the TRIP REPORT'S OWN embedded marker,
# AND must reset on an intervening non-failing round — is fixture-testable
# in isolation, not just wiring-greppable; a mutation like `>` → `>=` on
# either cutoff comparison is invisible to a source grep but changes this
# function's return value on a constructed fixture.
#
# Three-input cutoff-then-scan, mirroring [INV-05]'s "Marking as stalled"
# cutoff convention (lib-dispatch.sh's count_retries family):
#   1. trip_cutoff = the latest authorKind!=human comment whose body matches
#      the trip-report heading ("Review-round-cap circuit-breaker tripped");
#      the epoch if no trip has ever been reported. Because a trip report
#      EMBEDS its own marker (see autonomous-review.sh's ROUNDCAPREPORT
#      heredoc), without this cutoff the very next round would read that
#      embedded marker back as "the latest marker" and re-trip immediately
#      after an operator removes `stalled` to resume.
#   2. reset_cutoff ([P1] #449 review round 3): the latest authorKind!=human
#      comment carrying a `<!-- review-verdict: … -->` trailer whose verdict
#      is `passed` or `failed-non-substantive` (NOT `failed-substantive`);
#      the epoch if none exists. `dispatcher-review-cap-breaker` markers are
#      posted ONLY on `failed-substantive` rounds (see autonomous-review.sh's
#      `$AGGREGATE == "fail"` gate), so an intervening PASS or
#      failed-non-substantive round leaves no marker of its own to advance
#      the cutoff past — without this second cutoff, a later
#      failed-substantive round would resume counting from the OLDER
#      pre-intervening-round marker instead of restarting at 1, letting the
#      breaker trip on N total (not N CONSECUTIVE) substantive failures.
#      Anchored to the literal `passed`/`failed-non-substantive` tokens (not
#      a bare `failed-` prefix) so it never matches `failed-substantive`
#      itself. FULL-BODY anchored (`^...$`, not a bare `test()` substring
#      search) — mirrors `lib-dispatch.sh::authentic_verdict()`'s own
#      anchored pattern (its round-13/14 fix history is exactly this bug: a
#      bare substring/`startswith` match lets a REAL agent's own FAIL body
#      that merely quotes or discusses a prior trailer in prose — e.g. "the
#      earlier `<!-- review-verdict: passed -->` trailer was wrong" — falsely
#      satisfy the pattern. `emit_verdict_trailer` always posts the genuine
#      trailer as a bare, standalone comment with no other text, so the
#      anchor never rejects a real trailer while it reliably excludes any
#      trailer-shaped substring embedded in a larger comment.
#   3. cutoff = max(trip_cutoff, reset_cutoff). Scan authorKind!=human
#      comments containing the marker fence, STRICTLY (`>`, not `>=`) after
#      the cutoff — the strict inequality is what excludes the trip report's
#      own marker (its createdAt EQUALS trip_cutoff) while still admitting a
#      genuinely later post-resume marker. Echo the latest qualifying body,
#      or "" if none.
# All three steps additionally require `.body` to be a JSON string before
# `test()`/`contains()` runs on it — a bot-authored comment can carry a
# `null` body (rare, but a real GitHub REST shape), and `test()` on `null`
# is a jq RUNTIME ERROR, not merely a non-match; guarding the type keeps a
# stray null body from tripping fail-safe defaults on the WHOLE issue's
# comment scan rather than being skipped as a single non-matching row.
# Fail-safe: a jq failure of any kind (bad JSON, jq missing) yields "" —
# "no prior marker" is the same first-round default this fix would want on a
# genuine crash-then-recovery.
_review_cap_prior_marker() {
  local comments_json="$1"
  jq -r '
    ( [ .[] | select(.authorKind != "human") | select(.body | type == "string") ] ) as $rows
    | ( [ $rows[] | select(.body | test("Review-round-cap circuit-breaker tripped")) | .createdAt ]
        + ["1970-01-01T00:00:00Z"] | max ) as $trip_cutoff
    | ( [ $rows[] | select(.body | test("^<!--[[:space:]]*review-verdict:[[:space:]]*(passed|failed-non-substantive)[^>]*-->[[:space:]]*$")) | .createdAt ]
        + ["1970-01-01T00:00:00Z"] | max ) as $reset_cutoff
    | ( [$trip_cutoff, $reset_cutoff] | max ) as $cutoff
    | ( [ $rows[] | select(.body | contains("dispatcher-review-cap-breaker:")) | select(.createdAt > $cutoff) ]
        | sort_by(.createdAt) | last | .body // "" )
  ' <<<"$comments_json" 2>/dev/null || printf ''
}
