# Test cases: verdict-aware crashed-session recovery for the same-HEAD park (issue #466)

`handle_pending_dev_pr_exists()`'s same-HEAD block only routed a `completed` dev session
(via [INV-98]'s delegation) or a lost session-report comment ([INV-111]'s self-heal). A
session id that RESOLVED but whose `is_session_completed` check returned false (a
non-terminal stop reason such as `api_error`, a non-claude dev CLI, or an unreadable log)
fell straight to the residual `stale-verdict:<head>` park with no live wrapper to eventually
finish it — permanent, since the park only unblocks on a new commit, and nothing dispatches
one.

The fix extracts the [INV-111] self-heal case-statement body into a shared helper,
`_same_head_verdict_aware_recovery(issue_num, pr_ref, current_head, cause)`, called from two
disjoint preconditions — `cause=self-heal` (`_sid` empty) and `cause=crashed-session` (`_sid`
resolved, `is_session_completed` false) — both gated on `may_stall_now` (no live wrapper).
The helper is verdict-aware (reuses `classify_recent_review_verdict`) and shares budget
markers across both causes so neither can double-spend the other's one bounded retry. All
marker-present / budget-exhausted arms now call `mark_stalled` directly instead of falling to
the residual park (closing the `count_retries`-never-grows counting hole).

Golden-trace style tests mirror `test-issue-351-stale-verdict-delegate.sh`'s existing harness
(stub the ITP/CHP verb layer, not raw `gh`).

## The new `crashed-session` cause (regression test — fails before the fix)

| ID | Scenario | Expected |
|---|---|---|
| TC-466-CRASH-001 | Same-HEAD, review verdict `failed-substantive` (dev-actionable=true), session id resolves, `is_session_completed` returns false with `terminal_reason=api_error`, no live wrapper (`may_stall_now`=eligible) | Dispatches exactly ONE `dev-new`: `acquire_dispatch_marker` → `label_swap pending-dev→in-progress` → `post_dispatch_token` → `dispatch dev-new` rc=0 → `dispatch_marker_confirm_launched` → posts `crashed-session-retry:<head>` marker. **NO** `stale-verdict:<head>` park. **Must fail before the fix** (pre-fix: falls straight to the residual park, since `_sid` is non-empty so the old self-heal `if [ -z "$_sid" ]` guard never engaged). |
| TC-466-CRASH-002 | Same as CRASH-001 but `AGENT_DEV_CMD=codex` (non-claude dev CLI — `is_session_completed` returns false by design, unrelated to `api_error`) | Same dispatch sequence as CRASH-001 — the helper's precondition is CLI-agnostic ("completion is unprovable"), not `api_error`-specific. |
| TC-466-CRASH-003 | Same as CRASH-001 but the per-issue log file is missing/unreadable (`is_session_completed` returns false via its `[ -r "$log_file" ]` guard) | Same dispatch sequence — a missing log is just another "completion unprovable" cause. |

## Verdict-aware routing (shared by both causes)

| ID | Scenario | Expected |
|---|---|---|
| TC-466-VERDICT-001 | `crashed-session` cause, verdict=`passed` (race) | No-op: `return 0`, ZERO dev-new, no marker posted, no park. Mirrors `handle_completed_session_routing`'s own `passed` branch. |
| TC-466-VERDICT-002 | `crashed-session` cause, verdict=`dev-actionable=false` | `mark_stalled`, ZERO dev-new. Posts `crashed-session-non-actionable:<head>` marker (own namespace per cause — the [INV-92] non-actionable posture doesn't need cross-cause budget sharing since it never dispatches). |
| TC-466-VERDICT-003 | `crashed-session` cause, verdict=`failed-non-substantive` | `label_swap pending-dev→pending-review`, ZERO dev-new. Posts the **shared** `self-heal-non-substantive:<head>` marker (same namespace `cause=self-heal` uses — see Shared-Budget section). |
| TC-466-VERDICT-004 | `crashed-session` cause, verdict=`failed-substantive` (dev-actionable=true) or `none` | Bounded `dev-new` dispatch (TC-466-CRASH-001's sequence), posts `crashed-session-retry:<head>` marker. |

## Shared-budget pins (neither cause double-spends the other)

| ID | Scenario | Expected |
|---|---|---|
| TC-466-BUDGET-001 | `crashed-session` cause, `self-heal-lost-session:<head>` marker ALREADY present (a prior `self-heal` cause dev-new already ran for this HEAD) | The `crashed-session` cause does NOT dispatch a second `dev-new` — it sees the shared budget spent and calls `mark_stalled` instead. |
| TC-466-BUDGET-002 | `self-heal` cause, `crashed-session-retry:<head>` marker ALREADY present (a prior `crashed-session` cause dev-new already ran for this HEAD) | Symmetric to BUDGET-001: `self-heal` cause does NOT dispatch a second `dev-new`, calls `mark_stalled`. |
| TC-466-BUDGET-003 | `crashed-session` cause, verdict=`failed-non-substantive`, `self-heal-non-substantive:<head>` marker present (posted by either cause on a prior tick) | The `crashed-session` cause does NOT flip to `pending-review` a second time — calls `mark_stalled` instead (the shared re-review budget is spent). |

## Counting-hole regression (Part 2 — marker-present fall-throughs reach `mark_stalled`, never the park)

With `MAX_RETRIES=3` and `count_retries` frozen at 1 (no countable comment posted by an idempotent park notice):

| ID | Scenario | Expected |
|---|---|---|
| TC-466-STALL-001 | `self-heal-lost-session:<head>` marker present, `count_retries()` returns 1 (well below `MAX_RETRIES`) | `mark_stalled` fires anyway — the stall decision does NOT depend on `count_retries` reaching `MAX_RETRIES`; the marker itself is sufficient evidence the one bounded recovery for this HEAD was already spent with no progress. Regression pin for the counting hole the issue describes: pre-fix, this scenario fell to the residual park forever, since a park posts only an idempotent notice that `count_retries` never counts. |
| TC-466-STALL-002 | `crashed-session-retry:<head>` marker present, same `count_retries` setup | Same as STALL-001, for the new marker. |
| TC-466-STALL-003 | `self-heal-non-substantive:<head>` marker present, verdict=`failed-non-substantive`, same `count_retries` setup | Same as STALL-001, for the shared non-substantive marker. |

## Live-wrapper pin (never race a healthy wrapper — residual park unchanged)

| ID | Scenario | Expected |
|---|---|---|
| TC-466-LIVE-001 | `crashed-session` cause precondition (`_sid` resolved, not completed), but `may_stall_now` reports a wrapper IS alive | Neither `_same_head_verdict_aware_recovery` call site engages (the `elif` guard requires `may_stall_now` eligible) — falls straight to the residual `stale-verdict:<head>` park. NO dispatch, NO stall. Also asserts the park's comment text was updated to describe the wait as transient (mentioning a live wrapper / concurrent dispatch), not the old unconditional "awaiting new commits" wording — satisfies the issue's AC that the park comment mentions the crashed-session recovery path exists. |

## [INV-108] dispatch-marker concurrency pins (mirrors the [INV-111] self-heal branch's own tests)

| ID | Scenario | Expected |
|---|---|---|
| TC-466-INV108-001 | `crashed-session` cause, dev-new arm reached, `acquire_dispatch_marker` returns non-zero (held by a concurrent tick) | Helper returns 1 (NOT 0) — caller falls through to the residual `stale-verdict:<head>` park (a transient race, not a marker-present exhaustion). ZERO dev-new. |
| TC-466-INV108-002 | `crashed-session` cause, acquire succeeds but `label_swap pending-dev→in-progress` fails | `release_dispatch_marker`, `return 0` (handled, no park) — NO `post_dispatch_token`, NO `dispatch`. |
| TC-466-INV108-003 | `crashed-session` cause, `dispatch dev-new` returns rc=75 (DEFER) | `handle_dispatch_deferred(issue, dev-new, in-progress, pending-dev)`, `return 0` — NO confirm-launched. |
| TC-466-INV108-004 | `crashed-session` cause, `dispatch dev-new` returns rc=0 | `dispatch_marker_confirm_launched` called, `crashed-session-retry:<head>` marker posted. |

## Regression gates (existing suites stay green)

- `test-issue-351-stale-verdict-delegate.sh` — updated in this PR: TC-351-DELEG-6 (non-claude
  CLI) and TC-351-DELEG-7b (session id present, not completed) now assert the NEW
  `crashed-session-retry:<head>` dev-new dispatch instead of the old permanent park (this was
  the exact bug); new TC-351-DELEG-6-LIVE / TC-351-DELEG-7b-RECOVER pins preserve the
  live-wrapper-defers-to-park behavior explicitly. TC-351-DELEG-7a-SELFHEAL-BOUND and
  TC-351-DELEG-7a-SELFHEAL-NONSUB-BOUND updated: marker-present fall-throughs now assert
  `mark_stalled`, not the park (Part 2 of this fix).
- `test-issue-402-dispatcher-self-heal.sh` — unchanged; its scenarios (concurrent-acquire-loss,
  label-swap failure) exercise the shared helper's `self-heal` cause call site, which keeps the
  identical [INV-108] sequencing.
- `test-issue-461-completed-none-bounded-retry.sh` — unchanged; disjoint precondition
  (`handle_completed_session_routing`'s no-PR branch requires a `completed` session, never
  reached by this fix's `crashed-session` cause).
- `check-spec-drift.sh` — green: new/moved label-write sites (the renamed self-heal dev-new
  anchor, the new crashed-session-retry dev-new site sharing the `pending-dev|in-progress`
  movement, and the new `mark_stalled` budget-exhausted sites on `pending-dev|stalled`) are
  declared in `docs/pipeline/spec-codesite-map.json`'s `sites[]` manifest with grep-unique
  anchors, and `docs/pipeline/transitions.json` gains the corresponding transition rows.
- `check-provider-cutover.sh --require-trusted-ref` — green: the new helper calls only existing
  `itp_*`/`chp_*`-routed verbs (`itp_list_comments`, `itp_post_comment`, `label_swap` →
  `itp_transition_state`, `acquire_dispatch_marker`, `dispatch`, `post_dispatch_token`,
  `mark_stalled`), zero raw `gh`.
- ShellCheck green on `lib-dispatch.sh`.
