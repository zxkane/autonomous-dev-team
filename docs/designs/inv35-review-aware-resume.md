# Design Canvas — INV-35: review-aware Step 4 routing for completed sessions

**Issue**: #149 (bug: INV-12 session-completed gate traps issues whose review failed for non-substantive reasons)
**Status**: design recorded; implementation tracked under acceptance criteria of #149.
**Authors / decision date**: 2026-05-22.

## 1. Problem

`is_session_completed()` (in `lib-dispatch.sh`) reads the dev wrapper's last `{"type":"result"}` line. If `stop_reason=end_turn` and `terminal_reason=completed`, the helper returns true and `dispatcher-tick.sh` Step 4 refuses to dev-resume — instead it posts an `INV-12-completed:<sid>` operator-handoff comment and leaves the issue in `pending-dev`.

That gate exists for the right reason (closes #59 — `claude --resume` against a closed SSE stream hangs), but its scope is too broad. It does not distinguish:

- **dev session ended cleanly AND no review has run yet** — operator must decide. Original INV-12 case.
- **dev session ended cleanly AND the most recent review failed for a non-substantive reason** (configured `REVIEW_BOTS=q` and the bot timed out, CI flake, "no PR found" race, transport error). The dev work is fine; an upstream dependency failed.
- **dev session ended cleanly AND the most recent review failed for a substantive reason** (code findings, requirement drift, auto-merge blocked by rebase). The dev needs another pass, but resume cannot re-engage a `completed` session.

For the second and third cases the dispatcher should NOT post the operator-handoff comment — but pre-fix it does, every tick, until the operator manually intervenes.

**Live reproduction**, this very repo, 2026-05-21: issues #144 and #145 had clean dev sessions that ended `end_turn|completed` at 03:18 / 03:19 UTC. Reviews ran at 05:29 UTC, configured `REVIEW_BOTS=q` timed out (3-min poll without an Amazon Q response), reviews flipped both issues to `pending-dev` with `Review FAILED` verdict comments. From 05:34 UTC onward the dispatcher posted `INV-12-completed:<sid>` every tick on both issues for ~50 minutes, never resuming. Operator manually flipped both back to `pending-review` and unset `REVIEW_BOTS`.

## 2. Decisions

| # | Question | Decision | Rationale (one line) |
|---|---|---|---|
| Q1 | How does the dispatcher classify a verdict as substantive vs non-substantive? | **Structured HTML-comment trailer** emitted by the review wrapper (B). Missing trailer ⇒ treat as `failed-substantive` (safest fallback). | Producer owns classification — same idiom as `Reviewed HEAD:` (#106). Backwards-compatible, no brittle pattern list. |
| Q2 | Re-dispatch review directly, or flip the label and let Step 3 pick it up? | **Flip the label** `pending-dev → pending-review`. | Reuses `MAX_CONCURRENT`, JUST_DISPATCHED, and Step 3's existing dispatch path. No code duplication inside Step 4. |
| Q3 | For substantive failures with a completed session, fresh session or attempt resume? | **Fresh `dev-new`** (truncate log, mint new session_id), reusing the INV-12 PTL pattern. | A `completed` session has nothing to resume into. Fresh-dev is the only mechanically valid recovery. |
| Q4 | Interaction with `MAX_RETRIES`? | Substantive `dev-new` consumes `MAX_RETRIES` (it IS a fresh dev attempt). Non-substantive flip uses a separate `REVIEW_RETRY_LIMIT` counter (default 2, per-session-id). | Don't burn the dev-side retry budget on a flaky bot, but cap the non-substantive loop so a permanently broken bot doesn't bounce forever. |

### Rejected alternatives for Q1

- **A. Pattern-match the verdict comment** for known strings like "q review timeout" or "CI checks pending". Brittle — every new bot or new transient cause requires a dispatcher patch. Pattern list lives far from the producer.
- **C. New label** like `review-failed-non-substantive`. Adds label-state-machine complexity; races with the existing `pending-dev` flip; less expressive than a cause token.

## 3. Routing table (canonical)

For each `pending-dev` issue evaluated by Step 4 — after `is_session_completed` returns the prior session's terminal state:

| Dev session state | Most recent post-completion review verdict | Action | Consumes `MAX_RETRIES`? |
|---|---|---|---|
| Not completed (no `{"type":"result"}` row, or non-terminal `stop_reason`) | (any) | dev-resume (today's behavior, unchanged) | yes (existing) |
| `prompt_too_long` | (any) | dev-new + truncate (today's behavior, unchanged) | yes (existing) |
| `end_turn\|completed` | none | INV-12 operator notice (today's behavior, unchanged) | no |
| `end_turn\|completed` | `passed` (race) | no-op + WARN log; Step 0 hygiene reconciles next tick | no |
| `end_turn\|completed` | `failed-non-substantive`, flip count < `REVIEW_RETRY_LIMIT` | label-flip `pending-dev → pending-review` + post marker | **no** — separate counter |
| `end_turn\|completed` | `failed-non-substantive`, flip count ≥ `REVIEW_RETRY_LIMIT` | mark stalled + operator @-mention | n/a |
| `end_turn\|completed` | `failed-substantive` | dev-new + truncate (PTL path, with INV-35-fresh-dev marker) | yes |

Same routing applies regardless of `EXECUTION_BACKEND` ([INV-30](../pipeline/invariants.md#inv-30-pid_alive-is-authoritative-under-all-execution-backends)) — the helper reads issue comments + log file, both of which are accessible from the dispatcher box on either backend.

## 4. Verdict-trailer schema

Emitted by `autonomous-review.sh` in every verdict comment (PASS and FAIL paths). HTML-comment form so it never renders in the GitHub UI.

```
<!-- review-verdict: passed -->
<!-- review-verdict: failed-substantive -->
<!-- review-verdict: failed-non-substantive cause=<token> -->
```

`<token>` ∈ `{ bot-timeout, ci-transport, no-pr-found, merge-conflict-unresolvable, other }`. Extensible: dispatcher treats unknown causes as `failed-non-substantive` (same routing).

**Backwards compatibility**: a verdict comment with no trailer is treated as `failed-substantive`. This is the safest of the four routes:
- It never silently no-ops (which `passed` does).
- It does the right thing for any genuine substantive failure that pre-dates the trailer.
- Worst-case false-positive: a missing-trailer non-substantive failure routes to a fresh dev session, consuming one `MAX_RETRIES` slot. The dev session will likely produce the same PR HEAD ⇒ Step 4a.5's PR-exists short-circuit kicks in next tick to route back to review. Bounded waste.

**Trailer collision avoidance**: the wrapper already emits `Reviewed HEAD: <sha>` and `Review Session ID: <sid>` lines elsewhere in the comment. The new trailer goes inside an HTML comment (`<!-- ... -->`) per [INV-04](../pipeline/invariants.md#inv-04-reviewed-head-trailer-format)'s precedent so renderers ignore it.

## 5. Helper API

New function in `lib-dispatch.sh`:

```bash
classify_recent_review_verdict <issue_num> <session_end_iso> <out_verdict_var> <out_cause_var>
```

Returns 0 always. Out-vars receive:
- `<out_verdict_var>` ∈ `{ none, passed, failed-substantive, failed-non-substantive }`.
- `<out_cause_var>` is non-empty only when the verdict is `failed-non-substantive`.

Implementation:
1. `gh issue view <N> --repo $REPO --json comments` → list of comments with `author.login`, `createdAt`, `body`.
2. Filter: `author.login == BOT_LOGIN` (or fallback per session-id binding when `BOT_LOGIN` is empty per the existing `gh api user` 403 pattern), AND `createdAt > session_end_iso`.
3. Of the survivors, pick the newest by `createdAt`.
4. Match `body` against `<!-- review-verdict: ... -->` regex.
5. No match → `none`. Match without trailer (legacy verdict) → `failed-substantive`. With trailer → return the trailer's verdict + cause tokens.

The session-end timestamp is extracted from the same `{"type":"result"}` JSON line that `is_session_completed` already parses — add a third out-var to that helper to expose `_session_end_ts` to the caller.

## 6. Marker comments and idempotency

| Marker | Where | Purpose |
|---|---|---|
| `INV-12-completed:<sid>` | issue comment | (existing) operator-handoff for "completed + no verdict" — fires at most once per session-id. |
| `INV-35-fresh-dev:<sid>` | issue comment | new — fires before dev-new dispatch in the substantive-failure branch. Idempotent on the marker. |
| `<!-- review-aware-flip:non-substantive cause=<x> -->` | issue comment | new — emitted with the label flip in the non-substantive branch. Counted on each tick to compute the per-session flip count. |
| `<!-- review-verdict: ... -->` | review verdict comment (PR or issue, wherever the wrapper posts) | new — the trailer that drives the routing. |

All comments go via `bash scripts/gh issue comment` per [INV-32](../pipeline/invariants.md#inv-32-gh-wrapper-symlink-is-created-in-both-auth-modes).

## 7. Failure modes considered

| Scenario | Routing | Why this is safe |
|---|---|---|
| Verdict-trailer parser regex matches partial input (e.g. quoted prior verdict in a thread reply) | helper takes the *newest* comment matching the BOT_LOGIN + post-completion timestamp filter, not the lexically first | False matches only happen if the bot itself posts a quoted prior verdict — same author, same time-window, but the regex anchors on `<!-- review-verdict: ` (HTML comment opener) so quoted blockquote-rendered text without the literal `<!--` prefix doesn't match. |
| Bot posts multiple verdicts (race: human triggered review while dispatcher was reading) | helper picks newest; whichever verdict the human's intervention left becomes the source of truth | Same producer/timestamp model as today. |
| Log truncate fails on `failed-substantive` branch | dispatcher posts an operator-actionable comment and `continue`s without dispatching | Same fail-closed pattern as INV-12 PTL branch — prevents silent retry loop. |
| `REVIEW_RETRY_LIMIT` reached but the bot recovers on tick N+1 | issue is `stalled`; operator must remove `stalled` to re-arm | Acceptable. The `stalled`-removal flow already has clear operator semantics. Setting `REVIEW_RETRY_LIMIT=0` disables the cap (bounce forever) for operators who'd rather take the noise. |
| Verdict trailer present but cause token unknown | dispatcher treats as `failed-non-substantive` with `cause=<unknown-token>` | Forward-compatible; unknown causes still route to the safe re-review branch. |
| Both INV-12-completed and INV-35-fresh-dev markers present on the same issue (operator manually replayed) | idempotency keys are session-id-scoped; each session-id sees at most one of each | Operator-replay (label flip + comment delete) is rare and the worst case is one extra dispatch. |

## 8. Composition with existing invariants and prior fixes

- **INV-12 (resume only against unfinished sessions)**: INV-35 *carves out* from INV-12's `completed` arm. INV-12's `prompt_too_long` arm is unchanged.
- **INV-33 (review wrapper MUST NOT close issue)**: orthogonal — INV-33 is a producer rule for the review wrapper, INV-35 is a routing rule for the dispatcher. INV-35 only reads the verdict comments INV-33's emitter produces.
- **#146 auto-merge-failure recovery** (`Auto-merge failed:` PR comment + resume-prompt rebase prepend): composes cleanly. The prepend in `resume_agent` fires on a PR-comment match regardless of whether the dispatch is dev-resume or dev-new, so the substantive-failure → dev-new branch still gets the rebase guidance when the cause was an auto-merge block.
- **INV-30 (`pid_alive` authoritative under all execution backends)**: Step 4b.5.1 reads only issue comments (via `gh`) and the log file (local to the dispatcher box for both `local` and `remote-aws-ssm` per `/tmp/agent-${PROJECT_ID}-issue-N.log` location). No backend-specific behavior.

## 9. Out of scope

- **Adding a non-substantive label**: rejected (Q1 alternative C). Trailer is sufficient.
- **Generalizing classification to non-bot reviewers**: maintainers writing manual review comments don't get a trailer. Their verdict is opaque to the routing — defaults to `failed-substantive` (safe). If a future need arises, we'd extend the regex; for now this is YAGNI.
- **Per-cause routing variants** (e.g. `bot-timeout` → wait 5 min before re-dispatching; `ci-transport` → re-run CI before re-review): all causes route to the same re-review branch. Operator can read the cause token in the marker for diagnostics.
- **Implementation in this PR**: this PR ships only the design canvas + spec doc updates + opt-out default for `REVIEW_BOTS`. Code, helper, and tests come in follow-up PRs gated on this design being approved.

## 10. Testing strategy (referenced from `docs/test-cases/inv35-review-aware-resume.md`)

- Unit-tests for `classify_recent_review_verdict` covering trailer parsing, timestamp filter, missing-trailer fallback, multiple verdicts → newest.
- Step-4 routing tests with gh-fixture mocks covering every row of the routing table in §3.
- Regression fixture for the 2026-05-21 #144/#145 sequence: dev session ends `end_turn|completed`, q-bot posts a verdict comment 2h later carrying `cause=bot-timeout`, dispatcher tick must label-flip to `pending-review` (NOT post `INV-12-completed`).
- All log-truncate-fail paths gated by an injected fault (read-only chmod on the log file).

## 11. Pipeline doc updates shipped with this design

- [`docs/pipeline/state-machine.md`](../pipeline/state-machine.md) — three new pending-dev outgoing transitions in the mermaid diagram + transition table.
- [`docs/pipeline/invariants.md`](../pipeline/invariants.md) — INV-12 carve-out note + new INV-35 entry.
- [`docs/pipeline/dispatcher-flow.md`](../pipeline/dispatcher-flow.md) — new Step 4b.5.1 with the runtime view; recovery-table cross-reference updated.

## 12. Default `REVIEW_BOTS` flipped to empty

`skills/autonomous-dispatcher/scripts/autonomous.conf.example` ships `REVIEW_BOTS=""` by default in this PR. Rationale: each external bot is an availability dependency the operator takes on; until INV-35 is implemented, a slow bot keeps the issue bouncing between `pending-review` and `pending-dev`. Operators who actively want bot findings opt in. Even after INV-35 ships, this default stays — the implementation makes bot bouncing graceful, not free.
