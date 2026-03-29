# Test Cases: Fix cleanup PR check (#40)

## TC-CPC-001: Script contains PR existence check in success branch

**Steps:** Verify autonomous-dev.sh has `PR_EXISTS` check inside the exit_code==0 branch
**Expected:** Content check passes

## TC-CPC-002: Script posts warning when exit 0 but no PR

**Steps:** Verify autonomous-dev.sh has "no PR was created" warning message
**Expected:** Content check passes

## TC-CPC-003: Script still sets pending-review when PR exists

**Steps:** Verify the pending-review label transition is still present
**Expected:** Content check passes

## TC-CPC-004: Non-zero exit still goes to pending-dev

**Steps:** Verify the failure branch (exit != 0) is unchanged
**Expected:** Content check passes
