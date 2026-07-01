# Test cases: Step 4a.5 same-HEAD park delegates to INV-35 routing (issue #351)

Extends `tests/unit/test-dispatcher-step4-stale-verdict.sh` (the existing #106 suite) with
golden-trace assertions over the verb / dispatch / label seams, mirroring
`test-handle-completed-routing-golden-trace.sh`.

`handle_pending_dev_pr_exists` now, in its same-HEAD branch, extracts the dev session id,
checks `is_session_completed`, and delegates to `handle_completed_session_routing` for
`completed` sessions; it parks only the residual cases and returns 1 for `prompt_too_long`.

| ID | Scenario | Expected |
|---|---|---|
| TC-351-DELEG-1 | PR-exists, `current_head == last_reviewed_head`, **completed** dev session, `failed-substantive` dev-actionable verdict, no attempt marker | exactly ONE `dev-new` dispatched (`dispatch dev-new <issue>`), `label_swap pending-dev → in-progress`, `no-progress-substantive-attempt:<head>` marker recorded, and NO `stale-verdict:` park notice. **Fails before the fix** (parks unconditionally). |
| TC-351-DELEG-2 | Same as 1 but the `no-progress-substantive-attempt:<head>` marker is already present (second same-HEAD attempt) | `mark_stalled`, NO second `dev-new`, no `stale-verdict:` notice. Proves the fix cannot reintroduce the pre-#274 infinite dev-new loop (INV-85 bound). |
| TC-351-DELEG-3 | Same-HEAD completed session, `failed-non-substantive` verdict, under cap | `label_swap pending-dev → pending-review` (re-review), NOT parked, NOT dev-new. |
| TC-351-DELEG-4 | Same-HEAD completed session, `failed-substantive` + `dev-actionable=false` (INV-92) | `mark_stalled` escalation, NOT parked, NOT dev-new. |
| TC-351-DELEG-5 | `prompt_too_long` terminal reason, PR-exists same HEAD | helper returns **1** (caller falls through to the tick INV-12 PTL branch); NO delegation to `handle_completed_session_routing`, NO `stale-verdict:` park. |
| TC-351-DELEG-6 | Non-claude dev CLI (`AGENT_DEV_CMD=codex`, no `{"type":"result"}` log line) same HEAD | residual `stale-verdict:` park (documents the CLI/log scope); NO delegation, keeps `pending-dev`. |
| TC-351-DELEG-7a | Residual park — no session id resolvable, same HEAD | `stale-verdict:` notice posted once, keep `pending-dev`, NO dispatch/delegation. |
| TC-351-DELEG-7b | Residual park — session id present but NOT completed (live/crashed wrapper) | `stale-verdict:` notice, keep `pending-dev`, NO dispatch. |
| TC-351-DELEG-7c | Residual park — completed session but verdict classification empty (`none`) | delegates to router's `none` arm → operator handoff (`INV-12-completed:`), fail-closed (never dev-new). |
| TC-351-DELEG-8 | `current_head != last_reviewed_head` (HEAD advanced) | unchanged: Bug 3 flip to `pending-review`. Existing TC-STALE-VERDICT-2 still green. |
| Existing TC-STALE-VERDICT-1/4 | Re-scoped: same-HEAD park now only for the residual cases | updated to configure a residual state (no session id) so the park still fires; the new completed+verdict cases are covered by the DELEG cases above. |

## Regression gates (existing suites stay green)

- `test-handle-completed-routing-golden-trace.sh` — unchanged (the router is untouched).
- `test-mark-stalled-golden-trace.sh` — unchanged.
- `test-dispatcher-step4-stale-verdict.sh` — updated park expectations to the residual scope.
- `check-spec-drift.sh`, `check-provider-cutover.sh --require-trusted-ref` — green (no new
  label transition, no new raw `gh`).
