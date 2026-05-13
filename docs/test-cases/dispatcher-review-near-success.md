# Test Cases: dispatcher-review-near-success (#111)

## TC-RNS-001: PR-state cross-check — recent merge

**Setup**: Step 5b review branch, `pid_alive` returns 1, PR `mergedAt`
within `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS`.

**Expected**: `review_near_success` returns 0 (skip). No "crashed" comment
posted, no label swap.

## TC-RNS-002: PR-state cross-check — recent APPROVED review

**Setup**: `pid_alive` miss, PR has no `mergedAt`, but most recent review
event is APPROVED within window.

**Expected**: `review_near_success` returns 0. No "crashed" comment.

## TC-RNS-003: PR-state cross-check — recent verdict comment

**Setup**: `pid_alive` miss, no merge, no approval, but issue has a
recent comment matching `^Review (PASSED|findings)` within window.

**Expected**: `review_near_success` returns 0. No "crashed" comment.

## TC-RNS-004: PR-state cross-check — defensive PID re-check

**Setup**: `pid_alive` miss on first call, but `kill -0` against the
PID-file content now succeeds (race recovered).

**Expected**: `review_near_success` returns 0 (defer to next cycle).

## TC-RNS-005: PR-state cross-check — all signals negative

**Setup**: `pid_alive` miss, no merge, no approval, no recent verdict
comment, defensive PID re-check fails.

**Expected**: `review_near_success` returns 1. The existing crash path
fires (caller posts "crashed" comment + label swap).

## TC-RNS-006: REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=0

**Setup**: `pid_alive` miss; even though merge / approval signals exist,
the operator has set the window to 0.

**Expected**: `review_near_success` returns 1 (legacy strict behavior
preserved).

## TC-HB-001: pid_alive — kill -0 success

**Setup**: PID file points at a live process.

**Expected**: `pid_alive` returns 0 immediately (no mtime check needed).

## TC-HB-002: pid_alive — kill -0 fails, mtime fresh

**Setup**: PID file content points at a non-existent PID, but file mtime
is within `HEARTBEAT_INTERVAL_SECONDS * 3`.

**Expected**: `pid_alive` returns 0 (treat as ALIVE, race / transition).

## TC-HB-003: pid_alive — kill -0 fails, mtime stale

**Setup**: PID file content points at a non-existent PID, file mtime is
older than `HEARTBEAT_INTERVAL_SECONDS * 3`.

**Expected**: `pid_alive` returns 1 (DEAD).

## TC-HB-004: heartbeat lifecycle — touches PID file

**Setup**: `install_agent_heartbeat` is called with a PID file path,
`HEARTBEAT_INTERVAL_SECONDS=1`. Wait > 1s.

**Expected**: PID file mtime advances (recently touched).

## TC-HB-005: heartbeat exits when wrapper exits

**Setup**: Spawn a subshell, install heartbeat, then exit subshell.

**Expected**: No orphan heartbeat process — the heartbeat exits within
2s of its parent.

## TC-HB-006: HEARTBEAT_INTERVAL_SECONDS=0 disables heartbeat

**Setup**: `HEARTBEAT_INTERVAL_SECONDS=0`, install heartbeat.

**Expected**: No background process spawned (the `install` is a no-op).
PID file mtime does NOT advance.
