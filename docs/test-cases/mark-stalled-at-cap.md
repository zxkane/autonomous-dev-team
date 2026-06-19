# Test Cases — `mark_stalled` at-cap liveness ceiling (issue #263)

Tracks: issue #263 ([INV-26] / [INV-30] amendments).

## Scenario

`mark_stalled()` defers the stall decision whenever `pid_alive` reports ALIVE
([INV-26] rule 2). Under `EXECUTION_BACKEND=remote-aws-ssm`, `pid_alive`
delegates to the SSM liveness transport; when that transport is persistently
**indeterminate** (transport fault, timeout, garbled stdout), [INV-30]'s
conservative bias maps indeterminate → ALIVE. That bias is correct while retry
budget is intact (losing one tick is cheap) but wrong once retries are
exhausted: `mark_stalled` is *only* called at `count_retries >= MAX_RETRIES`,
and at that point the wrapper has no claim to deference. The pre-fix behavior is
an unbounded defer loop — the `stalled` label is never written, the issue hangs
in `pending-dev` indefinitely (reproduced as a downstream consumer's 40h hang).

### Fix (locked plan, issue #263)

1. **`pid_alive` gains a positional `--at-cap` flag.** When set, the
   remote-backend *indeterminate* verdict returns 1 (DEAD) instead of 0 (ALIVE).
   All other verdicts (ALIVE/DEAD) and all other callers are unchanged. The
   default `*) return 0` form (the [INV-30] ALIVE-bias) is preserved literally
   for callers that do NOT pass `--at-cap` — TC-RPA-010 still grep-asserts it.
2. **`mark_stalled` is the only `--at-cap` caller.** It is invoked from exactly
   one site and only when retries are exhausted, so it always passes the flag:
   `pid_alive --at-cap issue "$issue_num"`.
3. **Empty-PID short-circuit, narrowed to local backend.** Under local backend,
   an empty/absent PID file means no wrapper is running, so `mark_stalled` treats
   it as DEAD (no deferral comment, write `stalled` immediately). This is NOT
   applied under `remote-aws-ssm`, where the PID file lives on the wrapper box
   and dispatcher-side `get_pid` is always empty regardless of wrapper state.

**Policy framing**: at-cap indeterminate means "stop waiting", NOT "proved
dead". The fix is scoped to indeterminate verdicts only; a hung SSM driver, a
failing `gh issue edit`, or the driver returning ALIVE for a stale/wrong wrapper
still won't write `stalled` — those are out of scope. `_REMOTE_LIVENESS_DEGRADED_COUNT`
is per-process / per-tick (resets each cron tick); the durable ceiling is the
dispatcher's retry counter, which is what `--at-cap` keys on.

## Test Cases (extend `tests/unit/test-mark-stalled-liveness.sh`)

| ID | Setup | Expected |
|----|---|---|
| TC-MSL-006 | `EXECUTION_BACKEND=remote-aws-ssm`, retry exhausted, SSM driver stubbed to return indeterminate (rc≠0, empty stdout) | `mark_stalled` writes `stalled` on the SAME tick. **Assert BOTH:** (a) `issue edit <N> ... --add-label stalled` IS called, AND (b) NO `INV-26-stall-deferral` comment posted. Fails before fix, passes after. This is the downstream-consumer ~40h-hang bug. |
| TC-MSL-007 | local backend, `get_pid` empty + `pid_alive` ALIVE (legacy three-tier returns 0 via fresh PID-file/heartbeat mtime, PID content empty) | `mark_stalled` writes `stalled`, NO deferral comment posted. |
| TC-MSL-008 | non-empty PID + `pid_alive` genuine ALIVE (real spawned process under the PID) | existing [INV-26] deferral path preserved: deferral comment posted, NO `stalled` label edit. TC-MSL-001/004/005 still pass. |
| TC-MSL-009 | `pid_alive issue <N>` called directly WITHOUT `--at-cap` under `EXECUTION_BACKEND=remote-aws-ssm` with indeterminate driver | still returns 0 (ALIVE). TC-RPA-010's `*) return 0` form intact. Capture rc into a variable under `set -e` before asserting. |

## Acceptance

- TC-MSL-006 fails before the fix (pre-fix `mark_stalled` defers forever on
  remote indeterminate) and passes after; it asserts the actual label write AND
  the absence of the deferral comment (a return-code-only assertion would pass
  before the fix and prove nothing).
- TC-MSL-007 covers the empty-PID local-backend fast-path.
- TC-MSL-008 (and the pre-existing TC-MSL-001/004/005) guard against regressing
  the genuine-alive deferral.
- TC-MSL-009 (and the pre-existing TC-RPA-010 / TC-RPA-003) guard that the
  default `pid_alive` ALIVE-bias for non-at-cap callers is unchanged.
- A retry-exhausted issue receives the `stalled` label within ONE dispatcher
  tick once the at-cap flag overrides the indeterminate ALIVE-bias.
- The pre-existing unit suite stays green.
