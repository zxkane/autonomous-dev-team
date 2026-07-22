# Design Canvas - Review Unavailable Cap

Feature: Consecutive all-unavailable review breaker
Date: 2026-07-21
Status: Approved (autonomous mode)

## Problem

An `all-unavailable` review aggregate has no decided verdict and no
`Reviewed HEAD` trailer. The dispatcher therefore treats the next
`pending-dev` visit as a first review and starts another full fan-out. Existing
review, retry, and convergence counters do not advance, so deterministic
review-agent unavailability can repeat forever.

## Decision

Add an independent review-wrapper breaker with its own durable marker:

```text
<!-- dispatcher-review-unavailable-breaker: issue=<N> head=<sha|unknown> round=<n> -->
```

The counter is head-agnostic. `head` is forensic only because an unavailable
result carries no deciding verdict proving whether review and reporting
completed for either head; a head change does not prove capacity or reporting
recovered.

`REVIEW_UNAVAILABLE_CAP` defaults to `3`. `0` disables unavailable-round
increments and tripping, `1` trips on the first unavailable round, and malformed
values warn and fall back to `3`. Decided-round resets remain active while
disabled so later re-enabling cannot inherit a stale streak.

Every `all-unavailable` round persists its incremented marker. Every decided
aggregate (`pass` or `fail`) posts this breaker's explicit `round=0` reset
marker, including when the PR head is unresolved. The reset is independent of
verdict and Reviewed-HEAD comments because both are best-effort or absent on
relevant paths.

## Data Flow

```text
fan-out / smoke
      |
      v
aggregate == all-unavailable
      |
      +--> cap disabled ------------------------------> existing pending-dev route
      |
      +--> issue already stalled --------------------> handled exit, no label write
      |
      +--> read comments after latest prior trip
             |
             +--> next round < cap --> post marker --> existing pending-dev route
             |
             +--> next round >= cap
                    |
                    +--> reviewing -> stalled
                    +--> RESULT_PARSED=true
                    +--> persist threshold marker
                    +--> persist round=0 re-arm marker
                    +--> one structured escalation report
                    +--> handled exit

aggregate == pass or fail
      |
      +--> post round=0 reset marker (head may be unknown)
```

## Failure Modes

- A transition failure remains a wrapper failure: transition happens before
  `RESULT_PARSED=true`, matching the existing breaker ordering.
- The sibling-stall guard remains active when the cap is disabled, so a live
  wrapper cannot overwrite another breaker's terminal state with `pending-dev`.
- A report-post failure cannot re-add `pending-dev`: `RESULT_PARSED=true` is
  set immediately after the stalled transition.
- Removing `stalled` re-arms the breaker: the trip persists an independent
  `round=0` marker before attempting the report. A successful report is a
  second scan cutoff. The latest provider-neutral `stalled` removal event is a
  third cutoff, so re-arming survives failure of every post-transition comment.
- Marker reads request exact self-author classification from the provider and
  require `authorKind=self`; human and unrelated-bot markers are ignored.
- A self-authored marker whose `issue=` field does not equal the active issue is
  ignored.
- Comment ordering uses `(createdAt, id)`, so same-second threshold and reset
  posts deterministically select the later `round=0` marker.
- Missing drop classifiers degrade to `no reason token recorded`; the report
  does not infer a cause.

## INV-64 Interaction

Smoke-driven `all-unavailable` rounds count. A persistent capacity outage is
operationally actionable after the same bounded number of rounds. Smoke
evidence is carried separately from post-fan-out drop reasons and included in
the trip report. Partial-smoke reasons are appended to the shared in-memory
`_smoke_reasons` collector before the surviving fleet is built, so they remain
visible if every survivor later drops too.
