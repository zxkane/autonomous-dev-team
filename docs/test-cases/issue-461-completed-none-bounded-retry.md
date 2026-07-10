# Test cases: bound the completed-session `verdict=none` permanent silent park (issue #461)

`handle_completed_session_routing()`'s `none)` case currently either exists already (an
unconditional operator handoff) with no bound of any kind. This fix wraps it in an `if`/`else`
keyed on whether a PR exists for the issue:

- **PR exists** (or the lookup fails transiently) → unchanged `INV-12-completed:<sid>` handoff.
- **No PR exists** → mirror `failed-substantive`'s Branch C exactly (acquire dispatch marker,
  post `INV-12-no-pr-fresh-dev:<sid>`, truncate the session log, label-swap
  `pending-dev → in-progress`, `post_dispatch_token`, `dispatch dev-new`, confirm launched) — no
  per-HEAD attempt marker (there is no HEAD). Bounded by the existing `MAX_RETRIES` counter, which
  requires a companion fix: a new `count_no_pr_attempts()` that matches the wrapper's "Agent
  exited successfully but no PR was created" WARNING text, summed unconditionally into
  `count_retries()`.

Golden-trace style tests mirror `test-handle-completed-routing-golden-trace.sh`'s verb-recording
harness (stub the ITP/CHP verb layer, not `gh`).

## `handle_completed_session_routing` — `none` verdict branch

| ID | Scenario | Expected |
|---|---|---|
| TC-461-NONE-001 | verdict=`none`, no PR exists (`fetch_pr_for_issue` empty), notice absent | `acquire_dispatch_marker(issue, dev-new)` → dedup-check `INV-12-no-pr-fresh-dev:<sid>` absent → post the marker comment → `_reset_session_log` succeeds → `label_swap pending-dev→in-progress` → `post_dispatch_token dev-new` → `dispatch dev-new` rc=0 → `dispatch_marker_confirm_launched`. NO `INV-12-completed:` post. **Fails before the fix** (today: `INV-12-completed:` handoff, no dispatch, regardless of PR existence). |
| TC-461-NONE-002 | Same as 001, but the `INV-12-no-pr-fresh-dev:<sid>` marker is already present (repeat tick, same session id) | Dedup check finds the marker → skip re-posting the notice, but the rest of the Branch-C-mirror sequence (acquire marker, truncate, label swap, dispatch) still proceeds unchanged — idempotent on the notice text only, not a full no-op (mirrors Branch C's own dedup semantics: the marker text is one-shot, the dispatch mechanics are not gated on it). |
| TC-461-NONE-003 | verdict=`none`, PR EXISTS (`fetch_pr_for_issue` returns a PR object) | Unchanged existing behavior: dedup-check `INV-12-completed:<sid>` → post the operator-handoff notice → `return 0`. NO acquire_dispatch_marker, NO dispatch. Regression pin against today's behavior. |
| TC-461-NONE-004 | verdict=`none`, PR EXISTS, `INV-12-completed:<sid>` notice already posted | dedup-check finds it present → NO re-post, `return 0`. Zero verb calls beyond the one dedup read. Regression pin. |
| TC-461-NONE-005 | verdict=`none`, `fetch_pr_for_issue`/`resolve_pr_for_issue` returns nonzero (transport/read failure) | Treated as "PR exists" (fail closed) → same `INV-12-completed:<sid>` handoff path as TC-461-NONE-003, NEVER the no-PR dev-new branch. |
| TC-461-NONE-006 | No-PR branch: `acquire_dispatch_marker` returns non-zero (marker held by a concurrent tick) | Skip cleanly: no notice post, no truncate, no label swap, no dispatch. Mirrors Branch C's own losing-acquire behavior ([INV-108]). |
| TC-461-NONE-007 | No-PR branch: `_reset_session_log` fails (truncate error) | Post an operator-actionable comment, `release_dispatch_marker(issue, dev-new)`, `return 0` — NO dispatch. This is the mandatory fail-closed step; without it a deferred/crashed retry would silently escape `MAX_RETRIES` counting. |
| TC-461-NONE-008 | No-PR branch: `label_swap pending-dev→in-progress` fails (errexit-suppressed context) | `release_dispatch_marker(issue, dev-new)`, `return 0` — NO `post_dispatch_token`, NO `dispatch`. Proves the errexit-safe explicit guard (this router is reachable via an `if` condition that suppresses `set -e`). |
| TC-461-NONE-009 | No-PR branch: `post_dispatch_token` fails | Same as 008 — `release_dispatch_marker`, `return 0`, no dispatch. |
| TC-461-NONE-010 | No-PR branch: `dispatch dev-new` returns rc=75 (back-pressure DEFER, [INV-119]) | `handle_dispatch_deferred(issue, dev-new, in-progress, pending-dev)` (reverts the label swap), `return 0` — NO `dispatch_marker_confirm_launched`. |
| TC-461-NONE-011 | No-PR branch: `dispatch dev-new` returns a non-zero, non-75 rc | `release_dispatch_marker(issue, dev-new)`, `return 0` — NO confirm-launched. |
| TC-461-NONE-012 | No-PR branch: `dispatch dev-new` returns rc=0 | `dispatch_marker_confirm_launched(issue, dev-new)` called. NO per-HEAD attempt marker posted (there is no HEAD to key one on) — distinguishes this from Branch C's `no-progress-substantive-attempt:<head>` write. |
| TC-461-NONE-013 | Verb-order / argv golden trace for the full no-PR happy path | Exact sequence: `fetch_pr_for_issue` (or its resolve delegate), `itp_list_comments` (dedup), `itp_post_comment` (`INV-12-no-pr-fresh-dev:<sid>`), `itp_transition_state` (`pending-dev`→`in-progress`), `post_dispatch_token`, `dispatch dev-new`. Byte-identical shape to Branch C's own golden-trace assertion (TC-HCGT-008) modulo the marker text. |

## The [INV-111] self-heal branch's disjoint precondition (regression pin)

| ID | Scenario | Expected |
|---|---|---|
| TC-461-SELFHEAL-001 | `handle_pending_dev_pr_exists`'s same-HEAD branch, no resolvable session id, no live wrapper, verdict classifies `none` | Unaffected: still dispatches via `self-heal-lost-session:<head>` marker (its own, disjoint from `INV-12-no-pr-fresh-dev:<sid>`) — proves the two branches never collide despite both handling a `none`-shaped verdict, because their entry preconditions (PR exists vs. PR absent) are mutually exclusive. |

## `count_no_pr_attempts()` (the counting-gap companion fix)

| ID | Scenario | Expected |
|---|---|---|
| TC-461-COUNT-001 | One comment containing the literal WARNING text "Agent exited successfully but no PR was created", no stall cutoff | `count_no_pr_attempts` returns 1. |
| TC-461-COUNT-002 | The co-posted `Agent Session Report (Dev)` (exit 0) comment on the SAME tick | Does NOT also match `count_no_pr_attempts`'s regex — the two comments are independent text; no double counting. |
| TC-461-COUNT-003 | Two WARNING comments, one before and one after a "Marking as stalled" comment | Only the post-cutoff one counts (same `last_stalled_at` cutoff rule as `count_agent_failures`/`count_dispatcher_crashes`, [INV-05]). |
| TC-461-COUNT-004 | `count_retries()` with 1 agent failure + 1 no-PR WARNING, both post-cutoff | Returns 2 — summed unconditionally alongside `count_agent_failures`, NOT gated behind `_agent_started_since_stall` (unlike `count_dispatcher_crashes`). |
| TC-461-COUNT-005 | `mark_stalled`'s posted comment text when `count_no_pr_attempts` > 0 | Comment includes the new term (e.g. "N no-PR retry attempts") in addition to the existing "agent failures" / "dispatcher-detected crashes" / "false positives suppressed" terms, and the displayed arithmetic sums to the real `count_retries()` value. |

## Golden-trace / integration: replay the #456-shaped sequence

| ID | Scenario | Expected |
|---|---|---|
| TC-461-GOLDEN-001 | `MAX_RETRIES=3`. Sequence: original dev-new completes with no PR (WARNING #1, attempt 1) → tick classifies `none`+no-PR → dispatch (attempt 2, branch-dispatched) → completes no PR again (WARNING #2) → tick classifies `none`+no-PR again, `count_retries()==2 < 3` → dispatch (attempt 3, branch-dispatched) → completes no PR again (WARNING #3) → next tick's Step-4 pre-flight gate sees `count_retries()==3 >= MAX_RETRIES` | `mark_stalled --at-cap` fires at the Step-4 pre-flight gate, BEFORE a 3rd branch-dispatched `dev-new`. Exactly **2** branch-dispatched `dev-new` attempts total, never a 3rd, never a silent no-op tick. |
| TC-461-GOLDEN-002 | Same sequence, but attempt 2's dispatch is deferred (rc=75) and the wrapper never actually runs (no fresh WARNING posted) | The mandatory `_reset_session_log` truncate on the ORIGINAL branch entry (before the defer) means the next tick re-reads a clean log, not the stale `completed` line — so the branch does NOT silently re-fire without a fresh WARNING. Proves the deferred/crashed-retry does not escape counting via the one-level-down loop the log-truncate step exists to close. |

## Regression gates (existing suites stay green)

- `test-handle-completed-routing-golden-trace.sh` — TC-HCGT-001/002 (the `none` arm) still pass;
  extended coverage lives in this doc's TC-461-NONE-* cases rather than duplicating the existing
  file's assertions.
- `test-issue-402-dispatcher-self-heal.sh` / `test-issue-351-stale-verdict-delegate.sh` — unchanged
  (the [INV-111] self-heal branch's precondition is disjoint from this fix's no-PR branch; see
  TC-461-SELFHEAL-001).
- `test-lib-dispatch.sh`'s existing `count_retries` cases — unchanged; the new
  `count_no_pr_attempts` sub-count is additive, not a rewrite of the existing regex.
- `check-spec-drift.sh` — green: no new label-write SITE beyond the existing
  `pending-dev → in-progress` movement (`dispatch-review-aware-fresh-dev`'s existing transition
  row already declares this movement for `handle_completed_session_routing`; C.4 discovered-site
  reconciliation requires bumping that transition's `sites[]` count by one, since this fix adds a
  SECOND literal `label_swap "$issue_num" "pending-dev" "in-progress"` call site inside the same
  function).
- `check-provider-cutover.sh --require-trusted-ref` — green: the new branch calls only existing
  `itp_*`/`chp_*`-routed helpers, zero raw `gh`.
