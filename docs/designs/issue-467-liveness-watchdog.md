# Design: generic liveness watchdog — two-tier no-op-tick escalation (issue #467)

## Problem

Five "permanent silent park" incidents have shipped point-fixes in six months (INV-105,
INV-111, INV-122, INV-123, INV-125): an issue's label is legal and stable (usually
`pending-dev`), but the dispatch decision layer falls into an absorbing loop that posts one
idempotent notice and then no-ops every tick — no retry, no `stalled`, no operator mention.
Each fix so far is a per-entry patch keyed on a specific park shape. The entry set is open
(new provider stop reasons, new CLI adapters, future marker fall-throughs), so enumeration
can never finish. This issue adds a class-level backstop: any non-terminal issue whose
*observable state fingerprint* stays unchanged for N ticks gets an operator-visible
escalation, and after M further unchanged ticks (M > N) is unconditionally transitioned to
`stalled`.

## Decisions

| # | Question | Decision |
|---|---|---|
| D1 | What counts as "no progress"? | A fingerprint over 4 observable components: active label, PR head SHA (or empty), a count of comments MINUS known-idempotent-notice matches, and a digest of which known marker grammars are present. Unchanged fingerprint across a tick = no-op tick. |
| D2 | How is the counter persisted across tick processes? | A single HTML-comment marker (`<!-- dispatcher-liveness-watchdog: issue=<N> fingerprint=<hash> count=<n> tier1=<0\|1> -->`), posted/updated every evaluated tick — mirrors INV-122's "computed and posted on EVERY round, not only on a trip" requirement. On an ordinary counting tick (below tier 1), the posted comment is the BARE marker with no other text (the codebase already has this pattern: `emit_verdict_trailer` posts a separate bare comment whose body is JUST the trailer line, INV-105's round-13 fix). Read back via the LAST `authorKind != "human"` comment matching the grammar (unbounded scan, mirrors INV-105/INV-122). |
| D3 | Does the watchdog's own bookkeeping comment count as progress? | No — its marker grammar (`dispatcher-liveness-watchdog:`) is added to the SAME idempotent-exclusion list the tier-1 comment needs (R1). Without this the watchdog would defeat itself: its own per-tick post would look like "a new comment" and the fingerprint's comment-count component would grow every tick, so two consecutive ticks would never look equal. |
| D4 | Which liveness predicate for the "wrapper alive" exemption? | Reuse, never reinvent: `_dispatch_marker_recent` (fresh-dispatch-marker check) + `pid_alive <kind> <issue>`, where `<kind>` is `issue` for a `pending-dev` candidate and `review` for a `pending-review` candidate — the SAME two primitives `may_stall_now` already composes, just parameterized by which wrapper kind is relevant to the label actually being evaluated (a pending-dev issue's live-wrapper question is about the DEV pid file, not the review one). |
| D5 | Threshold validation shape? | Mirror `_gate_breaker_threshold`'s regex-then-fallback-with-warning (stderr-only, never through `log()`, so the numeric capture isn't corrupted). `LIVENESS_STALL_TICKS` additionally validates `> LIVENESS_NOTICE_TICKS` (itself validated `>= 2` first); if the relative constraint fails even after each falls back to its own default, `LIVENESS_STALL_TICKS` is bumped to `notice+1` as a last-resort clamp (defaults 6/18 never hit this). |
| D6 | Scope this iteration? | `pending-dev` and `pending-review` only (R2). `in-progress`/`reviewing` are already covered by Step 5b's DEAD-process scans; unifying the two mechanisms risks double-escalation and is deferred. |
| D7 | Already-stalled race? | Re-check `itp_read_task` labels for `stalled` immediately before the tier-2 transition (mirrors INV-122's `_gf_already_stalled` check) — a specific breaker may have won the race between candidate-list fetch and this evaluation. |

## Fingerprint

```
_liveness_canonical(label, head, non_idempotent_count, marker_digest) = "label|head|count|digest"
_liveness_fingerprint(...) = sha1sum(canonical) | cut -c1-12   (cksum fallback, mirrors convergence_trailer_hash)
```

`non_idempotent_count` = total comments MINUS comments matching any of a fixed grep-able
pattern list (`_LIVENESS_IDEMPOTENT_MARKERS`) covering `stale-verdict:`, `INV-12-completed:`,
`INV-12-no-pr-fresh-dev:`, `INV-35-fresh-dev:`, `no-progress-substantive(-attempt)?:`,
`non-actionable-finding:`, `self-heal-lost-session:`, `self-heal-non-substantive:`,
`crashed-session-retry:`, `dispatcher-convergence-breaker:`, `dispatcher-gate-fail-breaker:`,
and `dispatcher-liveness-watchdog:` (this watchdog's own marker, D3). `marker_digest` scans
the SAME pattern list and joins the sorted subset actually present (authorKind-gated) — a
NEW grammar appearing changes the digest even though it may already be excluded from the
count (e.g. a FIRST `self-heal-lost-session:` marker is progress; the SAME one persisting
next tick is not).

## Counter + tier action (pure)

```
_liveness_next_count(stored_marker, fingerprint)  = stored.count+1 if stored.fingerprint==fingerprint else 1
_liveness_next_tier1(stored_marker, fingerprint)  = stored.tier1   if stored.fingerprint==fingerprint else 0
_liveness_tier_action(count, tier1, notice, stall):
  count >= stall                    -> "tier2"
  count >= notice AND tier1 == 0    -> "tier1"
  else                               -> "none"
```

A fingerprint change resets both count and the tier1 latch — a fresh episode gets a fresh
tier-1 warning even on a HEAD/label that previously tripped tier 1 before recovering.

## Exemptions (R2), evaluated in order, cheapest first

1. `was_just_dispatched` (JUST_DISPATCHED, already exported by the time Step 6 runs).
2. `is_within_grace_period` (INV-18 dispatch-marker TTL).
3. `_liveness_wrapper_alive` (D4).
4. `itp_list_comments` transient failure → skip this tick (fail-toward-defer, mirrors
   INV-125's Part-2 preflight fix — an empty/failed read must never be misread as "no
   comments exist").

`list_pending_dev()`/`list_pending_review()` (re-fetched fresh at Step 6, AFTER Steps 2-5 may
have dispatched some of these issues away) already exclude `approved`/`stalled` — the
terminal-label exemption is structural, not a separate runtime check.

## Side effects — exactly one comment per evaluated issue per tick

| Action | Label transition | Comment |
|---|---|---|
| `none` | none | bare marker only (D2/D3) |
| `tier1` | none | human-readable escalation + `@REPO_OWNER` + marker (`tier1=1`) |
| `tier2` | `pending-{dev,review} -> stalled` (transition FIRST, mirrors INV-105's TOCTOU fix) | structured `reason=liveness-timeout` report + marker |

## Guards preserved

No changes to any existing breaker's threshold, fingerprint, or marker (INV-105/111/122/123/125
untouched). All I/O through existing `itp_*`/`chp_*` verbs (INV-91). No new liveness predicate
(D4 composes two existing ones). `in-progress`/`reviewing` are out of scope (D6).

## New invariant

Claims **INV-127** (INV-126 is claimed by the in-flight #449 branch; all other higher numbers
on open branches at design time are already spoken for — see the invariants.md entry for the
verified free-slot check).
