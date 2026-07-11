#!/bin/bash
# lib-review-cap.sh — INV-124 review-round-cap escalation breaker (issue #449, R2).
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
