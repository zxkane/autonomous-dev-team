# Design: verdict-aware crashed-session recovery for the same-HEAD `pending-dev` park (issue #466)

## Problem

`handle_pending_dev_pr_exists()`'s same-HEAD block (`lib-dispatch.sh`) already has two
handled cases for a dev session that isn't reachable via the [INV-98] completed-session
delegation:

1. `_sid` empty (session-report comment lost) + no live wrapper → [INV-111] self-heal.
2. Otherwise → residual `stale-verdict:<head>` park.

Case 2 is too broad. It also catches `_sid` **resolved** but `is_session_completed` returning
false — which happens for a non-terminal stop reason (`api_error`, a Bedrock 5xx mid-response,
etc.), any non-claude dev CLI (`is_session_completed` is claude-only by design), or a missing/
unreadable log. None of those mean the session is still running. When no wrapper is alive
either, the park is permanent: it waits for a new commit, but the only thing that could produce
one — a `dev-new` — will never be dispatched, because the HEAD is already-reviewed and Step
4a.5 only re-dispatches on a HEAD change.

## Decisions

| # | Question | Decision |
|---|---|---|
| Q1 | Does "not completed" mean "crashed"? | No. `is_session_completed=false` means *completion is unprovable* — for a non-terminal stop reason that may include a session that finished normally. The recovery predicate is narrower and CLI-agnostic: same reviewed HEAD + no live wrapper + no new commits = no progress, and one bounded retry is safe regardless of *why* completion is unprovable. This framing must not leak to call sites without the same-HEAD/no-progress context. |
| Q2 | Unconditional `dev-new`, or verdict-aware? | Verdict-aware — reuse `classify_recent_review_verdict` exactly as the [INV-111] self-heal branch already does (empty `session_end_iso`). A `failed-non-substantive` or `dev-actionable=false` verdict must not burn a `dev-new` it can never satisfy. |
| Q3 | New markers, or share [INV-111]'s? | Share where the action is identical regardless of *why* completion is unprovable (`self-heal-non-actionable:<head>`, `self-heal-non-substantive:<head>` — neither dispatches a `dev-new`, so there is no budget to double-spend, and the two entry preconditions — `_sid` empty vs. resolved — never co-occur in one tick). Use a **new** marker, `crashed-session-retry:<head>`, only for the dev-new-dispatching arm, and check it **together** with `self-heal-lost-session:<head>` as one shared per-HEAD budget — either one present blocks the other cause from spending a second `dev-new`. |
| Q4 | What closes the counting hole? | All three same-HEAD marker-present fall-throughs (`self-heal-lost-session`, `self-heal-non-substantive`, `crashed-session-retry`) now call `mark_stalled` instead of falling to the residual park. In a park, `count_retries` is frozen (no dispatch → no countable comment), so "MAX_RETRIES remains the backstop" can never come true — the marker itself is the evidence that the one bounded recovery for this HEAD was already spent with no progress. A **concurrent-tick acquire loss** (a different, transient reason for not dispatching) is NOT a marker-present case and keeps falling to the residual park unchanged — conflating the two would stall an issue on a routine dispatch-marker race. |

## Implementation shape

Extract the self-heal branch's case-statement body into a shared helper,
`_dispatch_same_head_verdict_aware_recovery(issue_num, pr_ref, current_head, cause)`,
called from two call sites with disjoint preconditions:

```
if   [ -z "$_sid" ] && may_stall_now "$issue_num"; then   # [INV-111] cause=self-heal
elif [ -n "$_sid" ] && may_stall_now "$issue_num"; then   # [INV-125] cause=crashed-session
```

`cause` only changes: the dev-new-arm's post-dispatch notice wording, and the log text. All
marker names and control flow are shared. The helper returns 1 **only** for the concurrent-
acquire-loss sub-case (so the caller falls through to the unchanged residual park); every other
arm returns 0 (handled).

## Guards preserved

INV-98 / INV-111 / INV-123 untouched (disjoint preconditions). INV-108 dispatch sequencing
identical to the adjacent INV-111 dispatch. INV-26 liveness via the existing `may_stall_now`
predicate, no new liveness logic. INV-92 (`dev-actionable=false` still escalates, never burns a
`dev-new`). INV-91 (all I/O through existing `itp_*` verbs).

## New invariant

INV-124 is reserved by the in-flight #449 PR (`feat/issue-449-review-convergence-rules`,
already merged to that branch's history at design time). This work claims **INV-125**.
