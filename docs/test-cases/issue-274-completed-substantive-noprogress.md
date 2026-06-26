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

### TC-DISP-NOPROG-004: bot-unfixable 403 signature → operator handoff, no dev-new

**Setup**: `_MOCK_VERDICT=failed-substantive`; `dev_report_bot_unfixable`
returns true (the most-recent dev report contains
`Resource not accessible by integration` in a PR-edit context). HEAD values are
irrelevant (the bot-unfixable branch precedes the HEAD comparison).

**Expected**: one idempotent `no-progress-substantive:<head>` notice citing the
bot-permission signature; `mark_stalled` fired; NO `post_dispatch_token`; NO
`dispatch dev-new`; no label swap to `in-progress`.

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
