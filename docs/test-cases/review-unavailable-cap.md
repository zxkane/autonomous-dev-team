# Test Cases - Review Unavailable Cap

## Helper Rules

| ID | Scenario | Expected |
|---|---|---|
| TC-RUC-001 | Marker construct and parse | Issue, forensic head, and round survive a round trip |
| TC-RUC-002 | Missing or malformed marker | Stored count is 0; next count is 1 |
| TC-RUC-003 | Empty head | Marker records `head=unknown` |
| TC-RUC-004 | Reset marker | Dedicated helper records `round=0` |
| TC-RUC-005 | Different heads across rounds | Counter increments; head does not reset it |
| TC-RUC-006 | Trip followed by operator re-arm, including total trip-side comment failure | Threshold and `round=0` markers precede the report when posts work; the latest `stalled` removal cutoff restarts at 1 even when every post after the transition failed |
| TC-RUC-007 | Human, unrelated-bot, wrong-issue, or quoted marker | Ignored by the exact-self, active-issue prior-marker scan |
| TC-RUC-007b | Threshold and reset comments share a timestamp | Provider comment ID breaks the tie and selects the later `round=0` marker |
| TC-RUC-007c | Trip report and post-trip marker share a timestamp | Provider comment ID breaks the cutoff tie; only the higher-ID marker qualifies |
| TC-RUC-008 | Explicit `round=0` marker | Next unavailable count is 1 |

## Configuration

| ID | Scenario | Expected |
|---|---|---|
| TC-RUC-010 | Knob unset | Threshold is 3 |
| TC-RUC-011 | Knob is `0` | Unavailable rounds produce no marker or transition; decided resets still persist for safe re-enabling |
| TC-RUC-012 | Knob is `1` | First unavailable round stalls |
| TC-RUC-013 | Knob malformed | Warning is emitted; threshold falls back to 3 |
| TC-RUC-014 | Representable positive integer | Value is honored without warning; values above signed 64-bit arithmetic range warn and fall back |

## Wrapper Route

| ID | Scenario | Expected |
|---|---|---|
| TC-RUC-020 | Three consecutive all-unavailable rounds | Rounds 1-2 persist markers and continue to `pending-dev`; round 3 transitions to `stalled`, posts one report, and never flips to `pending-dev` |
| TC-RUC-021 | Two unavailable rounds then decided PASS | PASS posts `round=0`; the next unavailable round starts at 1 |
| TC-RUC-022 | Two unavailable rounds then decided FAIL | FAIL posts `round=0`; the next unavailable round starts at 1 |
| TC-RUC-023 | Decided round with unresolved head | Reset marker records `head=unknown round=0` |
| TC-RUC-024 | Sibling breaker already stalled the issue, including cap-disabled mode | Route exits handled without a competing label transition or report |
| TC-RUC-025 | Trip report ordering | `reviewing -> stalled` occurs before the report post and before `RESULT_PARSED=true` can suppress transition failures |
| TC-RUC-026 | Drop reason is known | Trip report includes the per-agent drop reason |
| TC-RUC-027 | No drop reason token | Trip report states that no reason token was recorded |

## Smoke And Fleet Fixtures

| ID | Scenario | Expected |
|---|---|---|
| TC-RUC-030 | Repeated smoke-driven all-unavailable | Rounds count and the trip report includes `_smoke_reasons` evidence |
| TC-RUC-031 | Partial smoke drop followed by all surviving members dropping | Each classified pre-fan-out reason is appended to `_smoke_reasons` before the fleet shrinks |
| TC-RUC-032 | Trip handler invoked again while stalled | No second report or transition |
| TC-RUC-033..036 | Invoke the sourceable production terminal route over N persisted rounds and pin the wrapper's `exit 0` guard | Rounds 1..N-1 reach a fake pending-dev continuation; round N stalls and suppresses that continuation |
| TC-RUC-E2E-001 | Stub fleet members all exit 0 with no artifact/comment verdict | Aggregate is `all-unavailable`; the configured Nth wrapper route stalls |

## Documentation And Wiring

| ID | Scenario | Expected |
|---|---|---|
| TC-RUC-040 | Wrapper source list | Dedicated unavailable-cap library is sourced |
| TC-RUC-041 | Aggregate branch wiring | Handler is called only from `all-unavailable`; decided pass/fail calls the reset helper |
| TC-RUC-042 | State graph | A distinct review-unavailable-cap `reviewing -> stalled` transition exists |
| TC-RUC-042b/c | Guard map | INV-144's sibling-stall guard is independently anchored to the new helper |
| TC-RUC-043 | Pipeline docs | INV-144, state machine, review flow, handoff marker index, and INV-64 explicitly document the bounded smoke behavior |
| TC-RUC-043g | Invariant registry | Every `## INV-N:` heading has a globally unique identifier |
| TC-RUC-044 | Shell syntax | New helper, wrapper, and test harness parse |
| TC-RUC-045 | CI wiring | ShellCheck includes the new library |
