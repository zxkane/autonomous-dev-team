# Test Cases — Wrapper Hangs Bundle (PR-6)

Covers tests for #59 (INV-12), #60 (INV-13), #67 (INV-15), #500 (INV-15 rev 2).

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

## TC-500-01: SIGTERM path, first PR lookup FAILS, retry SUCCEEDS finding the PR

**Given** `RECEIVED_SIGTERM=1` and a stubbed `chp_pr_list` that fails on call 1 (rc≠0, empty capture) and succeeds on call 2 with a body matching `#<issue>`
**When** `cleanup()` runs
**Then** exactly 2 `chp_pr_list` calls and exactly 1 intervening 2s sleep occur, and the label transition converges on `pending-review` (the 143→0 rewrite fires on attempt 2). Regression: fails before the fix (a failed read was coerced to "0 matches" on attempt 1, routing straight to `pending-dev`).

## TC-500-02: SIGTERM path, BOTH lookup attempts fail → UNKNOWN-defer, no label write

**Given** `RECEIVED_SIGTERM=1` and a stubbed `chp_pr_list` that fails on both call 1 and call 2
**When** `cleanup()` runs
**Then** exactly 2 `chp_pr_list` calls and exactly 1 sleep occur (bounded, not unbounded), a WARN is logged naming the failed read, and NO wrapper label transition of any kind is written — neither `pending-review` nor `pending-dev`. Regression: fails before the fix (the failure branch always wrote `pending-dev`).

## TC-500-03: jq parse failure on a successful transport read follows the same UNKNOWN path

**Given** `RECEIVED_SIGTERM=1` and a stubbed `chp_pr_list` that returns rc 0 with non-JSON output on call 1 (jq parse failure) and a matching PR on call 2
**When** `cleanup()` runs
**Then** the parse failure is retried identically to a transport failure — exactly 2 calls, 1 sleep, converging on `pending-review` on the successful retry.

## TC-500-04 (companion — guards over-correction): SIGTERM path, lookup SUCCEEDS with zero matches

**Given** `RECEIVED_SIGTERM=1` and a stubbed `chp_pr_list` that succeeds on call 1 with a body matching no `#<issue>` reference
**When** `cleanup()` runs
**Then** exactly 1 `chp_pr_list` call occurs (no retry — a clean zero-match is not UNKNOWN), and the label transition takes the failure branch, unchanged (`pending-dev`).

## TC-500-05: non-SIGTERM paths are byte-unchanged

**Given** `RECEIVED_SIGTERM=0` and a stubbed `chp_pr_list` that fails on call 1
**When** `cleanup()` runs
**Then** exactly 1 `chp_pr_list` call occurs (no retry is introduced outside the SIGTERM branch) and the original single-attempt fail-soft-to-`"0"` contract is preserved.

(TC-500-01 through TC-500-05 are covered by `tests/unit/test-sigterm-trap.sh`'s extraction-based harness, which runs the real `cleanup()` fragment against a stubbed `chp_pr_list` scripted per-call — see [`docs/pipeline/invariants.md` INV-15 rev 2](../pipeline/invariants.md#inv-15-step-5a-sigterm-race-is-non-deterministic).)

## TC-WH-010: Step 4 skips dispatch when session is completed

**Given** dispatcher-tick.sh Step 4 sees an issue with `pending-dev`, valid session id, log shows completed terminal state
**When** Step 4 runs against this issue
**Then** no `dispatch-local.sh dev-resume` is spawned and an explanatory comment is posted.

(TC-WH-010 is covered by an integration-style test in `tests/unit/test-dispatcher-tick-step4-completed-skip.sh` using fakeroot mocks for `gh` / `dispatch-local.sh`.)
