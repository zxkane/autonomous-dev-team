# Test cases: backend-aware `is_session_completed` for remote-aws-ssm (issue #356)

`is_session_completed()` (`lib-dispatch.sh`) gains a backend seam: `_session_log_probe`
(local: today's `[ -r ] + grep + tail -1`; remote: `session-log-probe-remote-aws-ssm.sh`
via SSM, mirroring [INV-30]'s `pid_alive` shape). The two existing truncate sites
(`handle_completed_session_routing` Branch C, and the tick's INV-12 PTL branch) route
through a new `_reset_session_log` seam with the same local/remote split.

## Unit tests

### `tests/unit/test-session-log-probe-remote-aws-ssm.sh` (new driver, mirrors `test-liveness-check-remote-aws-ssm.sh`)

| ID | Scenario | Expected |
|---|---|---|
| TC-SLP-001 | Missing `SSM_INSTANCE_ID` | rc=1, no `aws` invocation. |
| TC-SLP-002 | Missing `SSM_REMOTE_PROJECT_ID` | rc=1, no `aws` invocation. |
| TC-SLP-003 | `--probe <issue>`, remote emits a `{"type":"result",...}` line + mtime epoch | stdout carries the result line on line 1, the epoch on line 2; rc=0. |
| TC-SLP-004 | `--probe <issue>`, remote log absent / grep no-match | stdout empty; rc=0 (a clean "nothing found" is NOT an error). |
| TC-SLP-005 | `--probe`, SSM send-command failure | rc=2 (indeterminate, mirrors `liveness-check`'s rc=2 contract), stdout empty. |
| TC-SLP-006 | `--probe`, poll timeout | rc=2, stdout empty, bounded wall-clock (same `REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS` cap). |
| TC-SLP-007 | `--truncate <issue>`, remote truncate succeeds | rc=0; argv sent to the execution host truncates the `SSM_REMOTE_PROJECT_ID`-keyed log path. |
| TC-SLP-008 | `--truncate`, SSM error | rc=2. |
| TC-SLP-009 | shell-metachar in `SSM_REMOTE_PROJECT_ID` / `SSM_REMOTE_PROJECT_DIR` | rc=1, no `aws` invocation (parity with `_has_shell_metachar`). |
| TC-SLP-010 | argv assertions | remote inner-cmd carries `PROJECT_ID="<SSM_REMOTE_PROJECT_ID value>"` (NOT the controller's `PROJECT_ID`) and the issue number verbatim. |

### `tests/unit/test-is-session-completed-remote.sh` (new — the AC1 regression)

| ID | Scenario | Expected |
|---|---|---|
| TC-ISCR-001 | `EXECUTION_BACKEND=remote-aws-ssm`, stubbed remote probe returns a `completed` result line + epoch | `is_session_completed` returns 0, `reason_var=completed`, `end_ts_var` = ISO-8601 derived from the stubbed epoch. **Fails before the fix** (local `[ -r ]` always misses under remote backend → always returns 1). |
| TC-ISCR-002 | Same, but `terminal_reason=prompt_too_long` | returns 0, `reason_var=prompt_too_long`. |
| TC-ISCR-003 | Stubbed probe returns empty (SSM timeout / error / no match) | returns 1 (fail-closed — no fabricated completion). |
| TC-ISCR-004 | `EXECUTION_BACKEND=local` (unset/default) with the SAME stub installed | stub is NEVER invoked; local path behavior is byte-unchanged (regression guard against the seam leaking into the local branch). |
| TC-ISCR-005 | `AGENT_DEV_CMD`/`AGENT_CMD` gate (existing [INV-37] behavior) | unchanged: non-claude dev CLI still short-circuits to 1 BEFORE the backend branch runs (no wasted SSM round-trip on a CLI whose log shape isn't `{"type":"result"}`). |
| TC-ISCR-006 | `PROJECT_ID != SSM_REMOTE_PROJECT_ID` fixture | the probe call is driven with `SSM_REMOTE_PROJECT_ID`; asserts the stub/driver never receives the controller's `PROJECT_ID`. |

### `tests/unit/test-issue-351-stale-verdict-delegate.sh` (extend, no removal)

| ID | Scenario | Expected |
|---|---|---|
| TC-351-DELEG-REMOTE-1 | Same-HEAD PR-exists scenario (as TC-351-DELEG-1) but with `EXECUTION_BACKEND=remote-aws-ssm` and `is_session_completed` mocked to return completed via the remote path | Step 4a.5 DELEGATES exactly as the local case does — `handle_completed_session_routing` invoked, ONE `dev-new`, NO `stale-verdict:` park. This is the golden-trace proof that the seam change doesn't alter `handle_pending_dev_pr_exists`'s own logic — it only fixes what `is_session_completed` returns. |

### `tests/unit/test-handle-completed-session-routing.sh` / PTL branch (extend)

| ID | Scenario | Expected |
|---|---|---|
| TC-RESET-REMOTE-1 | `handle_completed_session_routing`'s failed-substantive Branch C, `EXECUTION_BACKEND=remote-aws-ssm`, remote truncate stub succeeds | `_reset_session_log` issues the remote truncate (argv captured, keyed on `SSM_REMOTE_PROJECT_ID`); `dev-new` dispatched; NO local `: >` write attempted. |
| TC-RESET-REMOTE-2 | Same, remote truncate stub fails (SSM error) | fail-closed: skip-dispatch preserved (existing ERROR log + operator notice), NO `dev-new`, `pending-dev` unchanged — same shape as today's local truncate-failure test. |
| TC-RESET-REMOTE-3 (dispatcher-tick PTL branch, `tests/unit/test-autonomous-launcher-verdict-fresh.sh::TC-PTL-007`-style harness) | PTL branch, `EXECUTION_BACKEND=remote-aws-ssm`, remote truncate succeeds | `dev-new` dispatched after the remote truncate call. |
| TC-RESET-REMOTE-4 | PTL branch, remote truncate fails | fail-closed: dispatch skipped, existing "Could not reset..." operator notice posted, `pending-dev` unchanged. |

### Fail-closed / regression guards

| ID | Scenario | Expected |
|---|---|---|
| TC-ISCR-FC-1 | Remote probe driver crashes / not found | `_session_log_probe` returns empty, NOT an error that aborts the tick (`is_session_completed` treats empty as "no result line" → returns 1). |
| Existing `test-is-session-completed.sh` / `test-is-session-completed-end-ts.sh` | Unchanged, run with `EXECUTION_BACKEND` unset (local/default) | Green, byte-for-byte — the local branch of `_session_log_probe` reproduces today's inline logic exactly. |
| Existing `test-issue-351-stale-verdict-delegate.sh`, `test-dispatcher-step4-stale-verdict.sh` | Unchanged | Green — local-backend behavior is untouched. |

## E2E

Not applicable — the scenario needs two hosts; CI `unit` is the full surface (per the
issue's own Testing Requirements).

## Docs (same PR, per Pipeline Documentation Authority)

- `docs/pipeline/invariants.md` — new `INV-101` entry: backend-aware terminal-state
  detection, mirroring [INV-30]'s shape and cross-referencing it.
- `docs/pipeline/dispatcher-flow.md` — Step 4a.5 / Step 4b.5 notes updated to mention the
  backend seam; [INV-98]'s scope note updated to no longer describe remote-SSM as an
  unfixed gap.
