# Test cases: session-report teardown resilience (#402)

## Layer 1 — reorder `cleanup()`

| ID | Scenario | Expected |
|---|---|---|
| TC-STR-001 | Extract `cleanup()` from `autonomous-dev.sh`, grep the source-order of the Agent Session Report post vs. `drain_agent_pr_create` / `drain_agent_bot_triggers` | Session-report post's line number < `drain_agent_pr_create` call's line number < `drain_agent_bot_triggers` call's line number |
| TC-STR-002 | Regression harness (`run_cleanup`-style): shim dir vanishes right after cleanup-time token refresh, before any `gh`-touching write | Session-report comment still lands AND the label flip still runs (both observed via the recording `gh` stub) |
| TC-STR-003 | Same harness, run against a pre-fix checkout (report posted after the brokers) | Both the report and the label flip fail rc=127 (proves the regression is real pre-fix) |

## Layer 2 — `gh`-resolution resilience

| ID | Scenario | Expected |
|---|---|---|
| TC-STR-010 | `GH_WRAPPER_DIR` set, but `${GH_WRAPPER_DIR}/gh` missing (dir vanished) at cleanup entry | `hash -d gh` runs; `PATH` no longer contains `GH_WRAPPER_DIR`; a bare `gh` call resolves to the stub system `gh` |
| TC-STR-011 | `GH_WRAPPER_DIR` set and `${GH_WRAPPER_DIR}/gh` still present (normal case) | No `hash -d` / `PATH` mutation; behavior unchanged |
| TC-STR-012 | Fresh-token env (`GH_TOKEN` from the cleanup-time refresh) reaches the system `gh` stub after the fallback | Stub observes `GH_TOKEN` equal to the freshly refreshed value |

## Layer 3 — dispatcher self-heal

| ID | Scenario | Expected |
|---|---|---|
| TC-STR-020 | `handle_pending_dev_pr_exists` same-HEAD branch; `extract_dev_session_id` empty; no live wrapper (`may_stall_now` eligible); classified verdict = `failed-substantive` (dev-actionable=true) or `none` | Exactly one `dev-new` dispatch + `self-heal-lost-session:<head>` marker comment; NO `stale-verdict:` park |
| TC-STR-021 | Same as TC-STR-020, second tick, same HEAD (marker already present) | No-op: zero additional dispatch, park stays bounded |
| TC-STR-022 | Same as TC-STR-020 but a wrapper IS alive (`may_stall_now` → defer) | NO dispatch; falls through to the existing residual `stale-verdict:` park |
| TC-STR-023 | Same-HEAD branch with a resolvable session id (existing #351 delegation path) | Unaffected — routes through `handle_completed_session_routing` as before; self-heal never engages when a session id resolves |
| TC-STR-024 | Self-heal preconditions met (no session id, no live wrapper), classified verdict = `passed` (race) | No-op — no dev-new, no marker, no park; Step 0 hygiene reconciles next tick |
| TC-STR-025 | Self-heal preconditions met, classified verdict = `failed-non-substantive` | Label-flip `pending-dev → pending-review` + `self-heal-non-substantive:<head>` marker; NO `dev-new` |
| TC-STR-026 | Same as TC-STR-025, second tick, same HEAD (marker already present) | No second re-review flip; falls through to residual `stale-verdict:` park |
| TC-STR-027 | Self-heal preconditions met, classified `dev-actionable=false` ([INV-92]) | `mark_stalled` + `self-heal-non-actionable:<head>` marker; NO `dev-new`; NO `stale-verdict:` park |

## E2E

| ID | Scenario | Expected |
|---|---|---|
| TC-STR-030 | Full dev-wrapper dry run (fixture agent) with the auth dir deleted mid-cleanup | Issue lands on `pending-review` with the session report comment posted |
