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
| TC-545-FRESH-003 | Provider snapshots stay `OPEN` at `H`; every bounded `chp_mergeable` read returns `UNKNOWN` successfully | Poll exactly `MERGEABLE_RETRIES`, then call `mark_stalled`; no second non-substantive flip. Terminal evidence is a successful persistent `UNKNOWN`, not one unsettled read. |
| TC-545-FRESH-004 | Provider snapshots stay `OPEN` at `H`; every bounded `chp_mergeable` read returns non-zero | Poll exactly `MERGEABLE_RETRIES`, but do not stall, dispatch, or requeue from stale evidence; return the operational-defer code while retaining the residual notice. The dispatcher does not add `JUST_DISPATCHED`, so INV-128 remains the outage bound. |
| TC-545-FRESH-005 | Verdict is substantive and the same-HEAD dev-new budget is spent | Preserve the existing direct stall and do not read mergeability; freshness applies only to `cause=mergeable-unknown`. |
| TC-545-FRESH-006 | First provider snapshot reports a HEAD different from historical `H` | Requeue normal review without reading mergeability or stalling the new HEAD. |
| TC-545-FRESH-007 | First snapshot is `H`, `chp_mergeable` succeeds, and the second snapshot is a different HEAD | Requeue normal review; prove the second HEAD pin is load-bearing and never bind the mergeability token to the new HEAD. |
| TC-545-FRESH-008 | The first refresh read is `UNKNOWN`, then a later read in the same bounded poll is `MERGEABLE` | Requeue normal review after two reads; one unsettled observation cannot drive a terminal stall. |
| TC-545-FRESH-009 | Current mergeability is repeatedly `MERGEABLE` on the same HEAD for more than `REVIEW_RETRY_LIMIT` recovery cycles | Reserve one counted intent per attempt and stall at the configured cap; successful transitions also emit completion evidence. |
| TC-545-FRESH-010 | The freshness intent succeeds but `pending-dev -> pending-review` fails repeatedly | Return operational defer (`3`) below the cap, reserve each bounded attempt, never emit completion evidence, and converge to `stalled` at `REVIEW_RETRY_LIMIT` without aborting the project tick. |
| TC-545-FRESH-011 | A prior reservation exists but its current comment-list read fails selectively | Return operational defer (`3`); do not fabricate count zero, requeue, or stall from unreadable accounting. |
| TC-545-FRESH-012 | Label transitions succeed but every post-transition completion-marker write fails | The durable intent remains the retry reservation, normal review remains eligible, and repeated cycles still stall at the configured cap. |
| TC-545-FRESH-013 | A concurrent check-then-post race duplicates one reservation ordinal and its completion marker; one ordinary flip also exists | Count the reservation/completion duplicates as one logical freshness attempt and the ordinary flip as one separate attempt. Duplicate reservation comments cannot exhaust the cap early. |
| TC-545-FRESH-014 | Two freshness ordinals consumed the cap while completion was unprovable; completion later becomes provable on the same session and HEAD | The completed-session router observes the shared cap and stalls instead of adding another pending-review requeue. |
| TC-545-FRESH-015 | Completion is provable, but the completed-session logical flip count cannot read comments | Propagate operational defer (`3`) without requeueing or stalling from fabricated zero. |
| TC-545-FRESH-016 | The comment provider returns a malformed row or a body-start-recognized marker that fails its grammar | Return nonzero with no numeric output; malformed accounting cannot become count zero. |
| TC-545-FRESH-017 | The direct Step 4b completed-session entry point receives operational defer (`3`) for one issue before another pending issue | Continue scanning the project, omit the deferred issue from `JUST_DISPATCHED`, and preserve ordinary handled-route exemption for the later issue. Hard non-`3` errors retain their prior tick-failing contract. |
| TC-545-FRESH-018 | An ordinary prose comment quotes review-aware flip and freshness-reservation marker examples | Ignore the unanchored examples, return a successful logical flip count of zero, and do not classify reviewer prose as corrupt accounting. |
| TC-545-FRESH-019 | A prose comment quotes a byte-exact freshness reservation for ordinal 1 before repeated same-HEAD `MERGEABLE` recovery ticks | The quote satisfies neither idempotency nor accounting. Persist real anchored reservations, requeue exactly `REVIEW_RETRY_LIMIT` times, then converge to `stalled`. |
| TC-545-FRESH-020 | Only a sparse retained reservation ordinal (for example, `flip=2`) exists below the unique reservation cap | Allocate the next ordinal above the retained maximum, perform only the remaining bounded requeue, and then stall at the unique reservation cap. |

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
- `tests/unit/test-liveness-watchdog.sh` transcribes the freshness intent,
  completion-evidence, changed-HEAD, and retry-limit producer bodies byte-for-byte;
  each is excluded from non-idempotent progress counting and contributes a
  stable digest token.
- Provider conformance, spec drift, shell checks, and the full unit suite remain
  required before merge.
