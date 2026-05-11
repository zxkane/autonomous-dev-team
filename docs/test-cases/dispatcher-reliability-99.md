# Test Cases — Dispatcher Reliability (#99)

All tests live in `tests/unit/test-dispatcher-reliability-99.sh` unless otherwise noted. They mock `gh` by overriding the function in the test shell (same approach as `test-lib-dispatch.sh`).

## TC-99-001: Grace period suppresses stale detection

**Helper:** `is_within_grace_period`
**Setup:** issue has a `<!-- dispatcher-token: ... at <iso> ... -->` comment dated 60s ago, `DISPATCH_GRACE_PERIOD_SECONDS=1800`.
**Expected:** `is_within_grace_period 99` returns 0 (true).

## TC-99-002: Grace period expires correctly

**Setup:** dispatch-token comment dated 2000s ago, `DISPATCH_GRACE_PERIOD_SECONDS=1800`.
**Expected:** `is_within_grace_period 99` returns 1 (false).

## TC-99-003: No dispatch token → grace period not applied (backward compat)

**Setup:** issue has no dispatch-token marker comments.
**Expected:** `is_within_grace_period 99` returns 1 (false). Caller falls through to existing behavior.

## TC-99-004: Latest token wins across multiple dispatches

**Setup:** two dispatch-token comments — one 3000s ago, one 60s ago.
**Expected:** `latest_dispatch_token_age_seconds 99` returns ~60.

## TC-99-005: Dispatcher writes dispatch-token marker (helper)

**Helper:** `post_dispatch_token`
**Setup:** mock `gh issue comment` to capture the body.
**Expected:** body contains `<!-- dispatcher-token: <uuid> at <iso8601> mode=dev-new -->` and a human-readable line.

## TC-99-006: count_retries ignores dispatcher crashes when no session ID present

**Setup:**
- 2 dispatcher crash comments ("Task appears to have crashed (no PR found)").
- 0 agent session reports.
- 0 "Dev Session ID:" comments.
**Expected:** `count_retries 99` returns 0.

## TC-99-007: count_retries counts dispatcher crashes when session ID present

**Setup:**
- 1 agent session report with `Dev Session ID: \`abc-123\`` and Exit code 0 (success doesn't count by itself).
- 2 dispatcher crash comments.
**Expected:** `count_retries 99` returns 2 (dispatcher_crashes counted because session ID was confirmed at some point).

## TC-99-008: count_retries — agent failure always counts

**Setup:**
- 1 agent session report Exit code 1 (no session ID listed).
- 0 dispatcher crashes.
**Expected:** `count_retries 99` returns 1.

## TC-99-009: count_retries — stalled-cutoff still applies

**Setup:**
- 1 dispatcher crash + 1 dev-session-id-comment BEFORE "Marking as stalled" cutoff.
- 1 dispatcher crash AFTER cutoff, NO session ID comment after cutoff.
**Expected:** `count_retries 99` returns 0 (post-stall has no session ID, so post-stall dispatcher crashes don't count).

## TC-99-010: Step 4 PR-exists short-circuit (integration-style)

**Helper:** existing `fetch_pr_for_issue` — assert the new logic in dispatcher-tick.sh Step 4.
**Setup:** mock `fetch_pr_for_issue` to return a PR object. Mock `gh issue edit` and `gh issue comment`.
**Expected:** when scan-pending-dev encounters this issue, it calls `label_swap` from `pending-dev` to `pending-review` (NOT to `in-progress`), and does NOT call `dispatch dev-resume`.

> Step 4 integration test deferred — tested via dry-run injection in test-dispatcher-tick-step4-pr-exists.sh in a follow-up if needed. The unit-level coverage of the helper is what gates the fix.

## TC-99-011: post_dispatch_token writes parseable comment that survives a roundtrip

**Setup:** call `post_dispatch_token 99 dev-new`, capture the body, then run it through `latest_dispatch_token_age_seconds`.
**Expected:** age is < 5 seconds.

## Acceptance Criteria → Test Mapping

| Issue acceptance criterion | Tests |
|----|----|
| Newly dispatched agent not stalled within grace period | TC-99-001, TC-99-002 |
| Dispatcher writes dispatch timestamp/token at dispatch time | TC-99-005, TC-99-011 |
| If PR exists, stale detection transitions to pending-review | TC-99-010 (manual integration), Bug 3's existing in-progress branch already does this |
| autonomous-dev.sh has executable permission after skill update | Already covered by `tests/unit/test-script-exec-bits.sh` (#97/#98) |
| MAX_RETRIES only incremented when agent confirmed startup | TC-99-006, TC-99-007, TC-99-008, TC-99-009 |
