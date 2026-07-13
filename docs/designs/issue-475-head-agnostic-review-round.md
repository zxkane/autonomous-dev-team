# Design: head-agnostic `REVIEW_ROUND` series — closing the new-P2-per-round loop (issue #475, INV-129)

## Problem

The #449 R1 severity ratchet's `REVIEW_ROUND` counter (`lib-review-round.sh`) was
scoped to `(issue, head)` and reset to 1 on every push. In an **active dev↔review
loop** — a new fix commit every round, #449's own motivating scenario — that
reset-on-push behavior meant the blocking floor never loosened past round 1-2, no
matter how many rounds ran. Combined with INV-127's deliberate
`_aggregate_has_p0p1_fail` gate (which only counts a round toward its own cap when
a P0/P1 survives), a loop sustained by a **new P2/P3 finding each round** was
bounded by no mechanism at all — none of the six existing convergence/liveness
mechanisms (R1 ratchet, INV-127 cap, `REVIEW_RETRY_LIMIT`, INV-105, INV-122,
INV-128) engages, each for a different reason (see the issue body's table). A
downstream consumer project's PR churned 10 review↔dev rounds over ~6 hours with a
new commit every round; this repo's own history has a 7-round single-theme loop of
the same shape — both would have stayed frozen at ratchet round 1.

## Decision

Redefine `REVIEW_ROUND` as a **head-agnostic series of consecutive decided
`failed-substantive` rounds**, reusing INV-127's proven cutoff-then-scan grammar
instead of a head match — rather than adding a second (parallel) counter or
widening INV-127's gate. A parallel head-scoped + head-agnostic pair (floor = max)
preserves nothing of value, since the head-scoped counter is 1 in every scenario
where the two would differ, while doubling the marker surface. Widening INV-127's
gate to trip on P2-only loops converts a convergence problem into guaranteed
operator work for every narrow-finding loop. Redefinition fixes the root premise
with one marker grammar and no new state.

The full rationale, reset-channel design, marker grammar, and the "new P2 each
round" vs. "same P2 never fixed" (deliberately not distinguished) tradeoff are
recorded as **INV-129** in `docs/pipeline/invariants.md` — that entry is the
source of truth; this doc summarizes the shape of the change and where it lives.

## Implementation shape

| File | Change |
|---|---|
| `lib-review-round.sh` | `_review_round_parse_count`/`_review_round_next_count` drop the `<head>` parameter (head-permissive `head=.*` regex, so legacy head-keyed markers still parse). `_review_round_marker` keeps its 3-arg signature; empty/unset head renders as the literal `unknown` placeholder (mirrors `_review_cap_marker`). New `_review_round_prior_marker <comments_json>` — a cutoff-then-scan **sibling** of `_review_cap_prior_marker` (INV-122's sibling-breaker precedent, not a widening of the cap's function): cutoff = max of the latest `passed`/`failed-non-substantive` `review-verdict` trailer and the latest INV-127 trip report; scans strictly after for the latest full-body-anchored `review-round-counter` marker. |
| `autonomous-review.sh` (read site) | Drops the old "empty `PR_HEAD_SHA` forces round=1 and skips the marker" branch — its rationale (head-key contamination) no longer applies once the head is forensic-only. Calls `_review_round_prior_marker` instead of an inline `contains()` substring scan. |
| `autonomous-review.sh` (post site) | A `pass` aggregate posts an explicit `round=0` reset marker instead of the incremented round (R3) — a second, independent reset channel alongside the trailer cutoff, so a transient `emit_verdict_trailer` post failure can't let a later fail round inherit a stale high round. Every one of the wrapper's seven `failed-non-substantive` exit paths also posts its own `round=0` marker for the identical reason (added in response to a round-1 review finding on this PR — see below). A substantive `fail` posts the incremented round exactly as before. |
| `lib-review-aggregate.sh` | `_aggregate_has_p0p1_fail` and its call site: byte-identical (R5, regression-pinned). Comments updated to explain it's now harmless defense-in-depth rather than load-bearing, since a P2-only round is demoted to `pass` by the ratchet at round 5+ before it ever reaches this gate. |
| `docs/pipeline/invariants.md` | New INV-129 entry. |
| `docs/pipeline/review-agent-flow.md`, `docs/pipeline/handoffs.md` | Swept for the stale head-scoped/reset-on-push premise. |

No `state-machine.md` / `transitions.json` change — INV-129 changes an existing
breaker's inputs, not the state graph.

## Review-round-1 finding addressed in this PR

Codex flagged (round 1, [P3] BLOCKING): the `round=0` backup marker was only wired
into the `pass` branch. A `failed-non-substantive` exit (e.g.
`awaiting-bot-review`, `mergeable-unknown`) that loses its `emit_verdict_trailer`
post (`|| true`) would leave `_review_round_prior_marker` with no reset signal,
letting a later substantive fail inherit the stale high round. Fixed by mirroring
the same `round=0` post at all seven `failed-non-substantive` exit sites.

## Out of scope

Token-mode `authorKind` derivation (R6 documents the residual as fail-safe: round
stays 1). Finding-identity tracking across rounds (over-design — the marker-only
architecture has no persistent per-finding state). Any change to INV-105 / INV-122
/ INV-128 fingerprints or triggers.

## Test plan

See `docs/test-cases/inv-129-head-agnostic-review-round.md` — pure-logic tables
plus source-of-truth wiring greps against `autonomous-review.sh`, extending
`tests/unit/test-review-convergence-rules.sh` (the existing home of the
round/severity/cap fixtures).
