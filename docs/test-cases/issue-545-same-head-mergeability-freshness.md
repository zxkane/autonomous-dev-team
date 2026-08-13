# Test Cases: same-HEAD mergeability freshness (issue #545)

The regression harness stubs provider and issue-tracker verbs while driving the
real `handle_pending_dev_pr_exists`,
`_same_head_verdict_aware_recovery`, and mergeability preflight functions.
Every fixture uses one fixed full HEAD and an unprovable dev-session completion.

## Recovery Unit Cases

| ID | Current fixture after a prior `mergeable-unknown` verdict and consumed marker | Expected |
|---|---|---|
| TC-545-FRESH-001 | Provider snapshots stay `OPEN` at HEAD `H`; `chp_mergeable` returns `MERGEABLE` | Requeue `pending-dev -> pending-review`; never call `mark_stalled`; the unchanged HEAD is eligible for normal review. This fails before the fix. |
| TC-545-FRESH-002 | Provider snapshots stay `OPEN` at `H`; `chp_mergeable` returns `CONFLICTING` | Requeue to `pending-review`; the next production preflight classifies `conflict-rebase`, preserving the canonical conflict/rebase route. This fails before the fix. |
| TC-545-FRESH-003 | Provider snapshots stay `OPEN` at `H`; `chp_mergeable` returns `UNKNOWN` | Call `mark_stalled`; no second non-substantive flip. The bound remains fail closed, now supported by fresh evidence. |
| TC-545-FRESH-004 | First snapshot succeeds, but `chp_mergeable` returns non-zero | Do not stall, dispatch, or requeue from stale evidence; return the operational-defer code while retaining the residual notice. The dispatcher does not add `JUST_DISPATCHED`, so the existing repeated-tick INV-128 test proves the liveness watchdog remains a bound. |
| TC-545-FRESH-005 | Verdict is substantive and the same-HEAD dev-new budget is spent | Preserve the existing direct stall and do not read mergeability; freshness applies only to `cause=mergeable-unknown`. |
| TC-545-FRESH-006 | First provider snapshot reports a HEAD different from historical `H` | Requeue normal review without reading mergeability or stalling the new HEAD. |
| TC-545-FRESH-007 | First snapshot is `H`, `chp_mergeable` succeeds, and the second snapshot is a different HEAD | Requeue normal review; prove the second HEAD pin is load-bearing and never bind the mergeability token to the new HEAD. |

## Hermetic Golden Trace

| ID | Sequence | Expected |
|---|---|---|
| TC-545-TRACE-001 | Review preflight at fixed `H` returns `UNKNOWN`; recovery records `self-heal-non-substantive:H` and requeues review; a second preflight at `H` returns `UNKNOWN`; provider then changes to `MERGEABLE` without a new commit; pending-dev recovery runs again; normal preflight runs once more | Recovery does not stall. State reaches `pending-review`, and the final production preflight returns `proceed` for the same HEAD. No manual label change or commit is used. |

## Existing Contract Gates

- `tests/unit/test-chp-gitlab-reads.sh` keeps
  `detailed_merge_status=ci_still_running -> UNKNOWN`.
- `tests/unit/test-review-mergeability-preflight.sh` keeps GitHub/GitLab
  normalized parity and the final mergeability hard gate.
- `tests/unit/test-review-ci-rollup-gate.sh` keeps the independent final CI
  rollup gate.
- `tests/unit/test-issue-466-crashed-session-recovery.sh` keeps substantive,
  completed-session, changed-HEAD, and live-wrapper recovery behavior.
- `tests/unit/test-dispatcher-review-disposition-routing.sh` pins operational
  defer return `3` to no `JUST_DISPATCHED` entry and proves repeated unchanged
  watchdog evaluations reach the INV-128 stall bound.
- Provider conformance, spec drift, shell checks, and the full unit suite remain
  required before merge.
