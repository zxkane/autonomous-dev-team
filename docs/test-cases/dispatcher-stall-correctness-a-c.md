# Test Cases — Stall-decision correctness (Fix A + Fix C)

Tracks: issue #121 (Fix A and Fix C; Fix B in a follow-up PR).

## Scenario

Two of the three failure modes documented in #121:

- **Fix A**: `count_agent_failures` (lib-dispatch.sh) counts every Session Report whose `Exit code` is non-zero as an agent failure — including SIGTERM (143) and SIGKILL (137) caused by the dispatcher's own `kill_stale_wrapper`. The dispatcher is essentially scoring its own kills against the wrapper.
- **Fix C**: `mark_stalled` (lib-dispatch.sh) transitions an issue to `+stalled` without checking whether a wrapper is still alive. Once the retry counter is wrong (e.g. via Fix A), `mark_stalled` lies about a healthy wrapper that's making progress.

Together they produce the panoptes-class wedge: 2 dispatcher-misjudgement crashes + 1 SIGTERM-from-dispatcher → 3 strikes → false stall while the real wrapper finishes the work.

## Test Cases

### Fix A — `count_agent_failures` exit-code filter

| ID | Session Report exit code | Expected: counted as agent failure? |
|----|---|---|
| TC-CAF-001 | `Exit code: 0` | NO (pre-existing behavior) |
| TC-CAF-002 | `Exit code: 1` (real crash) | YES (pre-existing behavior preserved) |
| TC-CAF-003 | `Exit code: 124` (timeout) | YES (genuine hang must still count) |
| TC-CAF-004 | `Exit code: 143` (SIGTERM) | NO (dispatcher-induced, not agent failure) |
| TC-CAF-005 | `Exit code: 137` (SIGKILL) | NO (dispatcher-induced escalation) |
| TC-CAF-006 | `Exit code: 144` (must NOT collide with 143) | YES (only 143 is excluded; 144 is a genuine crash) |
| TC-CAF-007 | Mixed bag of exit codes | counts only the genuine failures |

### Fix C — `mark_stalled` liveness check

| ID | PID file state | Expected: stall fires? |
|----|---|---|
| TC-MSL-001 | PID file present, process alive (real `kill -0` succeeds) | NO — defer with diagnostic comment |
| TC-MSL-002 | PID file present, process dead | YES — existing behavior preserved |
| TC-MSL-003 | PID file absent | YES — existing behavior preserved |
| TC-MSL-004 | PID file present, process alive — verify the deferral comment is posted | comment posted, no label edit |
| TC-MSL-005 | PID file present, process alive — verify NO `gh issue edit ... --add-label stalled` call | edit call absent |

## Acceptance

- All TC-CAF-001..007 pass after Fix A; TC-CAF-001/002/003/006/007 pass on both sides of Fix A (no regression on genuine failures); TC-CAF-004/005 fail before Fix A (SIGTERM counts) and pass after.
- All TC-MSL-001..005 pass after Fix C; TC-MSL-002/003 pass on both sides of Fix C (no regression on dead/missing PID); TC-MSL-001/004/005 fail before (mark_stalled fires regardless of liveness) and pass after.
- Pre-existing 378-test unit suite stays green.
- `mark_stalled` deferral path posts an idempotency-keyed comment (per future tick re-evaluations) so the issue timeline doesn't fill with one-comment-per-tick when the wrapper is genuinely making progress over many ticks.
