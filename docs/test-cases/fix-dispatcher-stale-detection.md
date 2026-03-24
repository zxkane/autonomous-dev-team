# Test Cases: Fix Dispatcher Stale Detection Crash Loop (#32)

## Fix 1: Skip stale detection for freshly dispatched issues

### TC-STALE-001: Freshly dispatched issues are skipped in Step 5
- **Precondition:** Dispatcher dispatches issue #10 in Step 2 of the current cycle
- **Action:** Step 5 runs stale detection
- **Expected:** Issue #10 is skipped (not checked for PID/stale status)

### TC-STALE-002: Previously dispatched issues are still checked
- **Precondition:** Issue #5 was dispatched in a previous cycle, has `in-progress` label
- **Action:** Step 5 runs stale detection
- **Expected:** Issue #5 is checked for PID/stale status normally

### TC-STALE-003: Issues dispatched in Steps 3 and 4 are also skipped
- **Precondition:** Issue #20 dispatched in Step 3 (review), Issue #30 dispatched in Step 4 (resume)
- **Action:** Step 5 runs stale detection
- **Expected:** Both #20 and #30 are skipped

## Fix 2: Smarter crash transition with PR existence check

### TC-CRASH-001: DEAD in-progress with no PR → pending-dev
- **Precondition:** Issue #10 has `in-progress`, PID is dead, no open PR references #10
- **Action:** Step 5 detects DEAD
- **Expected:** Label changes to `pending-dev` (not `pending-review`)

### TC-CRASH-002: DEAD in-progress with open PR → pending-review
- **Precondition:** Issue #10 has `in-progress`, PID is dead, open PR exists referencing #10
- **Action:** Step 5 detects DEAD
- **Expected:** Label changes to `pending-review`

### TC-CRASH-003: DEAD reviewing → pending-dev (unchanged behavior)
- **Precondition:** Issue #10 has `reviewing`, PID is dead
- **Action:** Step 5 detects DEAD
- **Expected:** Label changes to `pending-dev` (behavior unchanged)

## Fix 3: Count dispatcher crashes toward stalled threshold

### TC-RETRY-001: Dispatcher crash comments count toward retry limit
- **Precondition:** Issue has 3 comments matching "Task appears to have crashed" and 0 Agent Session Reports
- **Action:** Step 4 evaluates retry count
- **Expected:** RETRY_COUNT=3, issue marked as `stalled` (assuming MAX_RETRIES=3)

### TC-RETRY-002: Combined agent failures and dispatcher crashes
- **Precondition:** Issue has 1 failed Agent Session Report (exit code !=0) and 2 dispatcher crash comments
- **Action:** Step 4 evaluates retry count
- **Expected:** RETRY_COUNT=3, issue marked as `stalled`

### TC-RETRY-003: Successful agent reports are not counted
- **Precondition:** Issue has 2 successful Agent Session Reports (exit code 0) and 1 dispatcher crash
- **Action:** Step 4 evaluates retry count
- **Expected:** RETRY_COUNT=1, issue is NOT stalled

## Fix 4: PID guard in wrapper scripts

### TC-PID-001: First instance starts normally
- **Precondition:** No PID file exists for issue #10
- **Action:** autonomous-dev.sh starts for issue #10
- **Expected:** PID file created, script runs normally

### TC-PID-002: Second instance exits when first is running
- **Precondition:** autonomous-dev.sh is running for issue #10 with valid PID file
- **Action:** Another autonomous-dev.sh starts for issue #10
- **Expected:** Second instance logs warning and exits 0

### TC-PID-003: Instance starts if PID file exists but process is dead
- **Precondition:** PID file exists for issue #10 but the process is not running
- **Action:** autonomous-dev.sh starts for issue #10
- **Expected:** PID file overwritten, script runs normally

### TC-PID-004: Review script has same PID guard
- **Precondition:** autonomous-review.sh is running for issue #10
- **Action:** Another autonomous-review.sh starts for issue #10
- **Expected:** Second instance logs warning and exits 0

### TC-PID-005: PID guard rejects symlinked PID files
- **Precondition:** PID file path is a symlink
- **Action:** autonomous-dev.sh starts
- **Expected:** Script exits with error about symlink attack
