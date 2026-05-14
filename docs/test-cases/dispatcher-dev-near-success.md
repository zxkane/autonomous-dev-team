# Test Cases — `dev_near_success` short-circuit (Fix B)

Tracks: issue #121 Fix B (the third axis).

## Scenario

Step 5b dev branch (in `dispatcher-tick.sh`) currently posts
`Task appears to have crashed (no PR found). Moving to pending-dev for
retry.` whenever `pid_alive` returns DEAD on an `in-progress` issue
without a PR. There's no near-success short-circuit for the dev side
analogous to [INV-24]'s `review_near_success`. A transient `pid_alive`
miss (cold-start race, brief subshell exit between checks, NFS mtime
flush hiccup) reliably files the crash comment, which the
`count_dispatcher_crashes` counter then accumulates against the retry
budget — fueling the `mark_stalled` false-positive that #121 Fix C
defers but doesn't fully prevent.

Fix B: introduce `dev_near_success` (parallel to `review_near_success`)
that returns 0 (skip the crashed-comment path) when ANY of these
signals are positive within `DEV_NEAR_SUCCESS_WINDOW_SECONDS` (default
300s):

1. Most recent `Agent Session Report (Dev) ... Exit code: 0` comment
   within window — agent already finished successfully (operator may
   not have reviewed yet, or the trap raced with the PR-existence
   check). PR detection failure on the dispatcher side ≠ agent
   failure.
2. Most recent `Dev Session ID:` comment within window — agent
   confirmed startup recently; the `pid_alive` miss is a transient
   probe race.
3. Defensive `kill -0 <pid>` against the current PID-file content
   succeeds — the original `pid_alive` miss raced with the wrapper's
   normal scheduling.

`DEV_NEAR_SUCCESS_WINDOW_SECONDS=0` disables the short-circuit (legacy
strict behavior, parity with `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=0`).

## Test Cases (helper `dev_near_success`)

| ID | Signal positive | Expected return |
|----|---|---|
| TC-DNS-001 | Session Report Exit code: 0 within window | 0 (skip crash) |
| TC-DNS-002 | Session Report Exit code: 0 outside window | 1 (proceed) |
| TC-DNS-003 | Dev Session ID comment within window | 0 |
| TC-DNS-004 | Dev Session ID comment outside window | 1 |
| TC-DNS-005 | Defensive `kill -0` succeeds (live PID) | 0 |
| TC-DNS-006 | All three signals negative (DEAD + stale + no recent activity) | 1 |
| TC-DNS-007 | `DEV_NEAR_SUCCESS_WINDOW_SECONDS=0` (disabled) — even with a fresh signal, returns 1 | 1 (legacy strict) |
| TC-DNS-008 | `DEV_NEAR_SUCCESS_WINDOW_SECONDS=invalid` (not numeric) — fallback to legacy strict | 1 |
| TC-DNS-009 | Mixed: SUCCESS recent + Session ID stale + dead PID — first signal wins | 0 |

## Test Cases (Step 5b dev branch integration)

Static-grep against `dispatcher-tick.sh` to pin the structural placement:

| ID | Assertion |
|----|---|
| TC-DNS-INT-001 | `dev_near_success` is invoked in the `kind=issue` (dev) DEAD branch |
| TC-DNS-INT-002 | The `Task appears to have crashed (no PR found)` comment lives only AFTER the `dev_near_success` short-circuit (i.e. `dev_near_success`-skip path uses `continue` to bypass the crash comment) |
| TC-DNS-INT-003 | The short-circuit path logs an INFO line referencing INV-27 so operators can see the deferral |

## Acceptance

- TC-DNS-001..009 all pass after Fix B; pre-fix, helper doesn't exist
  (cmd-not-found rc=127).
- TC-DNS-INT-001..003 all pass after Fix B; pre-fix, the structural
  pattern is absent.
- Pre-existing 390-test unit suite stays green.
- New invariant **INV-27** added to `docs/pipeline/invariants.md`,
  cross-referenced from INV-24 (parallel structure) and INV-26
  (complementary upstream gate).
- `docs/pipeline/dispatcher-flow.md::Step 5b dev` updated to reference
  INV-27 (parallel to existing INV-24 reference in Step 5b reviewing).
