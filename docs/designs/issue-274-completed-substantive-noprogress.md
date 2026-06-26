# Design: completed-session `failed-substantive` no-progress guard (#274, INV-85)

## Problem

`handle_completed_session_routing()` (`lib-dispatch.sh`) routes a `pending-dev`
issue whose prior dev session reached `end_turn|completed` per the
INV-35 verdict table. The `failed-substantive)` case mints a fresh `dev-new`
session **unconditionally** — there is no `last_reviewed_head` guard.

When a substantive FAIL is one the dev agent **cannot resolve**, every cycle
produces no new commit, the next review re-reports the identical finding against
the unchanged HEAD, and the dispatcher mints yet another `dev-new`. The loop
runs every ~5 min until a human intervenes.

Two real sub-classes of un-resolvable finding:

- **Bot lacks permission**: the only fix is editing the PR *body* (e.g.
  `Closes #N` → `Refs #N`), but the bot's scoped GitHub App token has no
  `pull_request: write` — `gh pr edit` returns
  `403 Resource not accessible by integration` ([INV-79]).
- **Inherently not pre-merge-resolvable**: the finding restates an acceptance
  criterion satisfiable only post-merge / in a deployed environment, so no
  commit on the PR can clear it.

This is the **symmetric gap** to #106. #106 added a `last_reviewed_head` guard
to the crash-recovery PR-exists branch (`handle_pending_dev_pr_exists`); a
session that reaches `completed` and then gets a `failed-substantive` verdict
routes through `handle_completed_session_routing()` instead, and **that** branch
has no same-HEAD check.

## Goal

- Bound the completed-session `failed-substantive` → `dev-new` path to **at most
  one** `dev-new` attempt per unchanged PR HEAD. On the *next* same-HEAD
  detection (the prior attempt produced no new commit), escalate to the operator
  (`mark_stalled` + an idempotent notice) rather than re-dispatching forever.
- Detect the bot-unfixable signature in the dev session's completion report
  (a `403 ... not accessible by integration` on a PR-body / PR-metadata edit)
  and route **straight** to operator handoff without burning even one `dev-new`.

Non-goals: changing the non-substantive / passed / none branches; changing
`handle_pending_dev_pr_exists` (its #106 guard already covers the
crash-recovery PR-exists path — though see the cross-ref note: that branch only
*suppresses* re-dispatch and never escalates; this design routes the
completed-session no-progress case to `mark_stalled` so a stuck issue ends up
`stalled` + a human signal, not churning ticks).

## Fix

In the `failed-substantive)` case, **before** the existing truncate +
`label_swap → in-progress` + `dispatch dev-new`:

```
current_head = fetch_pr_for_issue(issue).headRefOid
last_head    = last_reviewed_head(issue)

# (A) bot-unfixable → escalate immediately, zero dev-new
if dev_report_bot_unfixable(issue):
    post once (no-progress-substantive:<head>) "...403 / maintainer-only..." 
    mark_stalled(issue); return

# (B) no-progress (same HEAD, a prior dev-new already ran for this HEAD)
if last_head non-empty AND current_head == last_head
   AND a `no-progress-substantive-attempt:<head>` marker already exists:
    post once (no-progress-substantive:<head>) "...no new commits since <head>..."
    mark_stalled(issue); return

# (C) first substantive attempt against THIS head — record the attempt
#     marker so the *next* same-HEAD tick takes branch (B), then fall through
#     to the existing INV-35 dev-new dispatch.
if current_head non-empty:
    post hidden marker `<!-- no-progress-substantive-attempt:<head> ... -->`

# ... existing INV-35-fresh-dev notice + truncate + label_swap + dispatch dev-new
```

### Why a per-HEAD attempt marker (bounded retries, N=1)

The marker `no-progress-substantive-attempt:<head>` is the persisted "a dev-new
already ran against this HEAD" signal — the issue body proposal #2's
"bounded no-progress retries (N=1)". On the first `failed-substantive` at a HEAD
we mint one `dev-new` AND drop the attempt marker; the dev legitimately gets one
more pass (it might fix it). If the next review still fails substantively and
HEAD is unchanged, the prior `dev-new` made no progress → branch (B) escalates.
This bounds the "dev legitimately needs one more try" case while killing the
infinite loop.

The attempt marker is HEAD-scoped: a dev push that advances HEAD makes
`current_head != last_head`, so neither (B) nor a stale attempt marker for the
old HEAD applies — branch (C) records a fresh marker for the *new* HEAD and a
`dev-new` proceeds, exactly as today (no regression).

### Bot-unfixable detection (branch A)

`dev_report_bot_unfixable(issue)` scans the most-recent dev **Agent Session
Report (Dev)** comment for the bot-permission signature. We look for the literal
`Resource not accessible by integration` co-occurring with a PR-metadata-edit
context (`pr edit` / `PATCH` / `pull request` / `PR body`). This is the
permission 403 the dev agent hits when the only fix is a PR-body edit its scoped
token can't perform ([INV-79]). When present, no commit the bot can push will
clear the finding, so we escalate without spending a `dev-new`.

The detector is fail-safe: a `gh` transport error yields empty output → the
signature is "not found" → we fall through to the bounded-retry path (B/C), which
still terminates the loop after one attempt. We never *fabricate* a handoff; we
only short-circuit on a positive signature.

### Idempotency

All operator notices key on `no-progress-substantive:<head>` (same `grep -q
'^0$'` fail-closed pattern as #106's `stale-verdict:` and the
`INV-12-completed:` markers). The attempt marker keys on
`no-progress-substantive-attempt:<head>`. Repeated ticks against the same HEAD
find the marker(s) and don't spam comments or re-stall.

`mark_stalled` itself is idempotent against an already-stalled issue and carries
its own liveness-defer ([#121] Fix C); this branch does **not** pass `--at-cap`
(it is the review-no-progress state, not the retry-budget-exhausted state), so it
retains [INV-30]'s ALIVE bias under the remote backend — mirroring the existing
`REVIEW_RETRY_LIMIT` caller.

## State-machine summary

| State | Action |
|---|---|
| pending-dev + completed + failed-substantive + bot-unfixable signature in dev report | `mark_stalled`, post idempotent no-progress notice, NO dev-new |
| pending-dev + completed + failed-substantive + HEAD == last_reviewed_head + attempt marker present | `mark_stalled`, post idempotent no-progress notice, NO dev-new |
| pending-dev + completed + failed-substantive + HEAD == last_reviewed_head + NO attempt marker | record attempt marker, then mint dev-new (existing INV-35 behavior; bounded N=1) |
| pending-dev + completed + failed-substantive + HEAD != last_reviewed_head (dev pushed new commits) | record attempt marker for new HEAD, then mint dev-new (existing INV-35 behavior; no regression) |
| pending-dev + completed + failed-substantive + no PR / no current_head | mint dev-new (existing INV-35 behavior; can't compute HEAD, fall through) |
| any of the above + no-progress notice already present | no duplicate notice (idempotency) |

## Tests

TDD: extend `tests/unit/test-handle-completed-session-routing.sh` (same mocking
strategy — stubbed `gh` / `label_swap` / `mark_stalled` / `dispatch` / and the
new `fetch_pr_for_issue` / `last_reviewed_head` / `dev_report_bot_unfixable`
mocks).

- **TC-DISP-NOPROG-001**: completed + `failed-substantive` + current HEAD ==
  last_reviewed_head + attempt marker present → NO `dev-new`; idempotent
  no-progress notice posted once; `mark_stalled` fired.
- **TC-DISP-NOPROG-002**: completed + `failed-substantive` + current HEAD !=
  last_reviewed_head (dev pushed) → `dev-new` proceeds (no regression),
  attempt marker recorded for the new HEAD, NO stall.
- **TC-DISP-NOPROG-003**: same as 001 but no-progress notice already present →
  no duplicate notice (idempotency); still no `dev-new`; still stalled.
- **TC-DISP-NOPROG-004**: dev completion report contains the
  `403 ... not accessible by integration` PR-body-edit signature → operator
  handoff (`mark_stalled` + notice), NO `dev-new`, regardless of HEAD.
- **TC-DISP-NOPROG-005** (regression of the original INV-35 happy path):
  completed + `failed-substantive` + first attempt at a HEAD (no marker yet) →
  `dev-new` proceeds exactly as RT-020 (label swap → in-progress, token, log
  truncated), with an attempt marker now recorded.

Existing RT-020/021/022 and the #106 `last_reviewed_head` tests must still pass.

## Pipeline doc updates (same PR — Pipeline Documentation Authority)

- `invariants.md`: new **INV-85** entry (next free number — INV-84 is taken by
  #271).
- `transitions.json` + regenerated `state-machine.md`: new
  `pending_dev --> stalled` transition for the completed-session substantive
  no-progress guard. The `+stalled` write reuses the single `mark_stalled()`
  `--add-label "stalled"` site, so the `sites[]` per-(file,movement) count is
  unchanged; a new `code_sites` entry pins the row to `mark_stalled()`.
- `dispatcher-flow.md`: document the no-progress / bot-unfixable branches of the
  completed-session `failed-substantive` routing.

## Acceptance Criteria

- [ ] `failed-substantive` branch fetches `current_head` + `last_reviewed_head`
  before minting `dev-new`.
- [ ] First substantive attempt at a HEAD records a
  `no-progress-substantive-attempt:<head>` marker and still mints `dev-new`
  (bounded N=1).
- [ ] Second same-HEAD substantive failure → `mark_stalled` + idempotent
  `no-progress-substantive:<head>` notice, NO `dev-new`.
- [ ] A `403 ... not accessible by integration` PR-body-edit signature in the
  dev completion report → immediate operator handoff, zero `dev-new`.
- [ ] New HEAD (dev pushed) still mints `dev-new` (no regression).
- [ ] New INV-85 invariant; `state-machine.md` regenerated from
  `transitions.json`; `dispatcher-flow.md` updated.
- [ ] All existing unit + spec-drift tests still pass.
- [ ] PR closes #274.
