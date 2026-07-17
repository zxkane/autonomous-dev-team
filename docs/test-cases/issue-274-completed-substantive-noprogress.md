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

## Structured `dev-blocked-403` marker + success-comment veto (#511)

Extends `dev_report_bot_unfixable()`'s scoping above with a three-step
resolution order — see [INV-85](../pipeline/invariants.md) and
[`dispatcher-flow.md`](../pipeline/dispatcher-flow.md) for the normative spec.
Cases live in `tests/unit/test-dev-report-bot-unfixable.sh` as `BU-020`
through `BU-027`.

### BU-020 (the #485 regression, pinned): success report + head moved + incidental 403 quote → NOT unfixable

**Setup**: a dev-authored comment reports success (fixed all findings, pushed
a new commit) and separately quotes `Resource not accessible by integration`
about an unrelated, optional courtesy action (retriggering a flaked
third-party CI run); the dev agent's `Agent Session Report (Dev)` shows `Exit
code: 0`; the pre-attempt `Reviewed HEAD:` trailer differs from the
caller-supplied current head (HEAD moved during the attempt); no structured
marker is present anywhere.

**Expected**: NOT unfixable — the success-comment veto fires (exit-0 AND head
moved), so the legacy substring match on the incidental 403 mention is
ignored. This is the exact shape observed live on issue #485 / a companion PR;
it fails before the fix (old code returns unfixable) and passes after.

### BU-021: structured marker, matching head, in-window → unfixable

**Setup**: a dev-authored, in-window comment carries `<!-- dev-blocked-403:
head=<sha> -->` where `<sha>` equals the caller-supplied current head; no
legacy substring text is present at all.

**Expected**: unfixable — the structured marker is the primary signal and
fires independently of any free-text heuristic.

### BU-022: marker with a STALE head → NOT unfixable

**Setup**: the only marker present has a `head=` that does NOT equal the
caller-supplied current head (superseded by a later push).

**Expected**: NOT unfixable. Presence of any marker (even non-matching)
disables the legacy substring fallback for this attempt — a stale-head marker
means "blocked at a head that is no longer current," not "fall through to the
free-text heuristic."

### BU-023a: marker authored by a non-dev login → NOT unfixable

**Setup**: a marker with a matching head is posted by a login other than the
resolved dev agent author (e.g. a human/maintainer); no legacy text present.

**Expected**: NOT unfixable — excluded by the existing author allow-list
scoping (unchanged from the #274 scoping (a)).

### BU-023b: dev-authored marker posted BEFORE the current dispatch token → NOT unfixable

**Setup**: a dev-authored marker with a matching head exists, but its
`createdAt` precedes the current attempt's `dispatcher-token … mode=dev-*`
comment (a prior attempt's marker); no legacy text present in the current
window.

**Expected**: NOT unfixable — excluded by the existing per-attempt-token lower
bound (unchanged from the #274 scoping (b)).

### BU-024 (legacy fallback preserved): no marker, legacy 403 present, no success-veto evidence → unfixable

**Setup**: no structured marker exists anywhere in the window; a legacy
403-on-PR-edit substring is present; there is no `Exit code: 0` report at all
(no success-veto evidence).

**Expected**: unfixable — INV-85's original protection for a genuinely blocked
legacy session (no marker-aware dev agent yet) is preserved byte-for-byte.

### BU-025 (success-veto specifics): exit-0 report but HEAD unmoved → veto does NOT apply → unfixable

**Setup**: no marker present; a legacy 403 substring is present; the dev
agent's report shows `Exit code: 0`, but the pre-attempt `Reviewed HEAD:`
trailer EQUALS the caller-supplied current head (no commit landed during the
attempt).

**Expected**: unfixable — the success-comment veto requires BOTH exit-0 AND a
moved head; a no-commit session that quotes a legacy 403 may genuinely be
blocked, so a single satisfied condition must not suppress detection.

### BU-026: matching marker alongside legacy text → marker decides → unfixable

**Setup**: a dev-authored, in-window comment carries a matching structured
marker AND, in the same comment, a legacy 403-on-PR-edit substring.

**Expected**: unfixable — the marker (step 1) decides the outcome regardless
of what legacy text also appears; presence of legacy text alongside a
matching marker must not change the result.

### BU-027: exit-0 report but NO prior `Reviewed HEAD:` trailer at all → veto does NOT apply → unfixable

**Setup**: no marker present; a legacy 403 substring is present; the dev
agent's report shows `Exit code: 0`; there is no `Reviewed HEAD:` trailer
anywhere in the comment history (not merely one equal to the current head, as
in BU-025) — no forensic evidence exists that HEAD moved.

**Expected**: unfixable — absence of a prior trailer is treated as "no
evidence HEAD moved," so the veto does not apply. This is the fail-safe the
code comment calls out: no forensic signal means the legacy path's original
all-or-nothing behavior is preserved (protects the BU-012 regression).
