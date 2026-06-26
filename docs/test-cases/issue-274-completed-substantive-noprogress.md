# Test cases — completed-session `failed-substantive` no-progress guard (#274, INV-85)

Covers the no-progress / bot-unfixable guard added to
`handle_completed_session_routing()`'s `failed-substantive)` case in
`lib-dispatch.sh`. See [`docs/designs/issue-274-completed-substantive-noprogress.md`](../designs/issue-274-completed-substantive-noprogress.md)
for the design and [`docs/pipeline/invariants.md` § INV-85](../pipeline/invariants.md)
for the spec.

All cases extend `tests/unit/test-handle-completed-session-routing.sh`. They
reuse its mocking strategy and add mocks for `fetch_pr_for_issue`,
`last_reviewed_head`, and `dev_report_bot_unfixable`, plus a notice-presence
mock keyed per marker so idempotency can be asserted independently of the
`INV-35-fresh-dev` notice.

## Guard cases

### TC-DISP-NOPROG-001: same HEAD + prior dev-new already ran → escalate, no dev-new

**Setup**: `_MOCK_VERDICT=failed-substantive`; `fetch_pr_for_issue` returns a PR
with `headRefOid=deadbeef`; `last_reviewed_head` returns `deadbeef`; a
`no-progress-substantive-attempt:deadbeef` marker is already present (a prior
tick's `dev-new` ran for this HEAD); `dev_report_bot_unfixable` returns false.

**Expected**: NO `dispatch dev-new`; NO `post_dispatch_token`; one idempotent
notice keyed `no-progress-substantive:deadbeef` posted; `mark_stalled` fired;
no label swap to `in-progress`; the per-issue log is NOT truncated.

### TC-DISP-NOPROG-002: new HEAD (dev pushed) → dev-new proceeds (no regression)

**Setup**: `_MOCK_VERDICT=failed-substantive`; `fetch_pr_for_issue` returns
`headRefOid=cafe1234`; `last_reviewed_head` returns `deadbeef` (older); no
attempt marker for `cafe1234`; `dev_report_bot_unfixable` false.

**Expected**: an attempt marker `no-progress-substantive-attempt:cafe1234` is
recorded; `label_swap pending-dev → in-progress`; `post_dispatch_token
100:dev-new`; `dispatch dev-new:100`; log truncated to 0 bytes; NO `mark_stalled`.
Identical end-state to the legacy RT-020 happy path.

### TC-DISP-NOPROG-003: same HEAD + escalation notice already present → idempotent

**Setup**: as TC-001 but the `no-progress-substantive:deadbeef` notice is
already present.

**Expected**: NO duplicate notice posted; still NO `dev-new`; `mark_stalled`
still fired (stall is idempotent against an already-stalled issue).

### TC-DISP-NOPROG-004: bot-unfixable 403 signature at the SAME HEAD → operator handoff, no dev-new

**Setup**: `_MOCK_VERDICT=failed-substantive`; `dev_report_bot_unfixable`
returns true (a `Resource not accessible by integration` in a PR-edit context
within the current HEAD's window); `current_head == last_reviewed_head` (HEAD
unchanged — the gate for branch A, #274 review [P1] finding 1).

**Expected**: one idempotent `no-progress-substantive:<head>` notice citing the
bot-permission signature; `mark_stalled` fired; NO `post_dispatch_token`; NO
`dispatch dev-new`; no label swap to `in-progress`.

### TC-DISP-NOPROG-006: bot-unfixable 403 but HEAD advanced → dev-new proceeds (no stale-stall)

**Setup**: `_MOCK_VERDICT=failed-substantive`; `dev_report_bot_unfixable` would
return true (an old 403 is still on the issue) BUT `current_head != last_head`
(the dev pushed new commits). This is the #274 review [P1] finding-1 regression:
an old 403 must not permanently stall the issue once HEAD advances.

**Expected**: branch A does NOT fire; `dev-new` proceeds (`label_swap pending-dev
→ in-progress`, `dispatch dev-new`, attempt marker for the new HEAD); NO
`mark_stalled`.

### TC-DISP-NOPROG-007: dispatch aborted (truncate fails) → attempt marker NOT written

**Setup**: `_MOCK_VERDICT=failed-substantive`; first attempt at a HEAD (no
marker); the per-issue log is read-only so the fail-closed truncate guard takes
its `return 0` path WITHOUT dispatching. This is the #274 review [P1] finding-2
regression: the attempt marker must be written only after a successful dispatch.

**Expected**: NO `dispatch dev-new`; NO label swap; and crucially NO
`no-progress-substantive-attempt:` marker posted (so the next tick re-attempts
cleanly instead of stalling on a phantom marker).

### TC-DISP-NOPROG-008 (#274 review [P1] round-3 finding 2): marker write failure → retry + loud notice, never silent

**Setup**: first attempt at a HEAD; GitHub rejects the
`no-progress-substantive-attempt:<head>` comment (`_MOCK_ATTEMPT_WRITE_FAILS=1`).

**Expected**: `dev-new` still dispatched; the marker write is retried once (2
attempts total); a **loud operator notice** is posted reporting the degraded N=1
bound — and that notice does NOT contain the literal `no-progress-substantive-attempt:`
grep token (else it would false-trigger branch B's presence check next tick).
`MAX_RETRIES` remains the backstop.

### Source-pin: INV-85 `fetch_pr_for_issue` call includes `body` (round-4 finding 1)

In `test-handle-completed-session-routing.sh`, a grep of `lib-dispatch.sh`
asserts the guard requests `number,headRefOid,body`. The routing suite mocks
`fetch_pr_for_issue`, so only this source check catches a missing `body` field —
which would make `gh pr list` omit `.body`, the helper's `.body` filter return
empty, and both guards silently no-op in production.

### TC-BU (`test-dev-report-bot-unfixable.sh`, ids 001..007 + 010..016, 14 cases): detector dev-author + per-attempt scoping

Standalone tests of the REAL `dev_report_bot_unfixable` against a scripted `gh`
mock (the routing suite mocks the function itself). All fixtures carry
`.author.login`; the dev agent authors `dev-bot[bot]` (with an `Agent Session
Report (Dev)` comment = the dev-login anchor), the dispatcher authors the
`dispatcher-token … mode=dev-*` comment (the per-attempt lower bound):
- **001..007** (dev-authored, per-attempt window): a dev 403 AFTER the current
  dev-dispatch token → unfixable; a 403 BEFORE it → NOT unfixable (prior attempt
  expired); a 403 without PR-metadata context → not the signature; null comment
  bodies tolerated (#148 guard); no dev token → no bound (conservative); a
  `mode=review` token does NOT move the bound.
- **010..011** (review-comment exclusion, round-3): a **review-agent** comment
  quoting the 403 → different author → NOT counted; a genuine dev 403 alongside a
  sibling review quote → the dev one still counts.
- **012** (round-4 finding 2 regression): the agent's completion 403 posted after
  the dev-dispatch token but *before* the cleanup-time `Dev Session ID:` trailer
  → still detected.
- **013**: a 403 before the current dev-dispatch token → out of window → NOT
  unfixable.
- **014** (round-5 [P1] regression): a **maintainer/owner** comment (NOT a review
  agent) quoting the 403 with PR-edit text → different author → NOT counted.
- **015**: no dev session report → dev author unresolvable → fail-open (NOT
  unfixable).
- **016** (round-6 [P1] regression): a PRIOR same-HEAD attempt hit a 403, a
  maintainer cleared the metadata (no new commit), the issue was re-dispatched (a
  NEW dev-dispatch token), and the new same-HEAD attempt did not hit the 403 →
  the old 403 expires at the new token → NOT unfixable (the new finding gets its
  bounded retry).

### TC-DISP-NOPROG-005: first substantive attempt at a HEAD → records marker, dev-new (bounded N=1)

**Setup**: `_MOCK_VERDICT=failed-substantive`; `fetch_pr_for_issue` returns
`headRefOid=deadbeef`; `last_reviewed_head` returns `deadbeef` (same HEAD) but
**no** attempt marker yet; `dev_report_bot_unfixable` false.

**Expected**: an attempt marker `no-progress-substantive-attempt:deadbeef` is
recorded; `dev-new` proceeds (label swap, token, dispatch, log truncated); NO
`mark_stalled`. This is the one-and-only allowed dev-new per unchanged HEAD; the
NEXT same-HEAD tick takes TC-001's escalation path.

## Regression cases (existing INV-35 behavior preserved)

### TC-DISP-NOPROG-R1: RT-020 happy path still dispatches dev-new

The existing `RT-020` assertions (substantive failure mints dev-new, truncates
log, swaps label) still hold when no attempt marker exists and HEAD info is
absent (`fetch_pr_for_issue` empty → can't compute HEAD → fall through to
dispatch). Guards the "PR not yet discoverable" fall-through.

### TC-DISP-NOPROG-R2: non-substantive / passed / none branches unchanged

`RT-010` / `RT-012` / `RT-030` / `RT-001` are untouched — the guard lives only
in the `failed-substantive)` case.
