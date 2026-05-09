# Test Cases — Wrapper Hangs Bundle (PR-6)

Covers tests for #59 (INV-12), #60 (INV-13), #67 (INV-15).

## TC-WH-001: `_run_with_timeout` wraps when binary present

**Given** `_AGENT_TIMEOUT_CMD=$(command -v timeout)` resolves to a real binary
**When** `_run_with_timeout sleep 5` is called with `AGENT_TIMEOUT=1s`
**Then** exit code is `124` (timeout) within 2 seconds.

## TC-WH-002: `_run_with_timeout` falls through when binary absent

**Given** `_AGENT_TIMEOUT_CMD=""`
**When** `_run_with_timeout /bin/true` is called
**Then** exit code is `0` and the underlying command ran (no extra wrapping).

## TC-WH-003: `is_session_completed` — clean Claude exit returns true

**Given** a fixture log containing a final JSON object with `stop_reason=end_turn` and `terminal_reason=completed`
**When** `is_session_completed 999` is called with that fixture as the issue log
**Then** returns 0.

## TC-WH-004: `is_session_completed` — crashed mid-turn returns false

**Given** a fixture log with partial JSON or a non-terminal stop_reason
**When** `is_session_completed 999` is called
**Then** returns 1.

## TC-WH-005: `is_session_completed` — non-claude AGENT_CMD returns false

**Given** `AGENT_CMD=codex` and any log content
**When** `is_session_completed 999` is called
**Then** returns 1 immediately (no log parsing).

## TC-WH-006: `is_session_completed` — missing log returns false

**Given** no log file at `/tmp/agent-${PROJECT_ID}-issue-999.log`
**When** `is_session_completed 999` is called
**Then** returns 1.

## TC-WH-007: SIGTERM trap with PR rewrites exit_code to 0

**Given** a wrapper-shaped harness with `RECEIVED_SIGTERM=1` and `gh pr list` mocked to return 1 matching PR
**When** the cleanup logic runs
**Then** the label transition path treats it as success (`pending-review`).

## TC-WH-008: SIGTERM trap without PR keeps exit_code at 143

**Given** a wrapper-shaped harness with `RECEIVED_SIGTERM=1` and `gh pr list` mocked to return 0 PRs
**When** cleanup runs
**Then** the label transition path treats it as failure (`pending-dev`).

## TC-WH-009: Normal exit code 0 ignores RECEIVED_SIGTERM=0

**Given** wrapper exits cleanly without SIGTERM
**When** cleanup runs
**Then** existing PR-existence-check path is exercised unchanged (regression guard).

## TC-WH-010: Step 4 skips dispatch when session is completed

**Given** dispatcher-tick.sh Step 4 sees an issue with `pending-dev`, valid session id, log shows completed terminal state
**When** Step 4 runs against this issue
**Then** no `dispatch-local.sh dev-resume` is spawned and an explanatory comment is posted.

(TC-WH-010 is covered by an integration-style test in `tests/unit/test-dispatcher-tick-step4-completed-skip.sh` using fakeroot mocks for `gh` / `dispatch-local.sh`.)
