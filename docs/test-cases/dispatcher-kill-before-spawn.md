# Test Cases: dispatcher-kill-before-spawn

Closes #55.

## TC-DKBS-001: Static — `dispatch-local.sh` checks PID file before nohup

**Verify** `dispatch-local.sh` contains a kill-before-spawn block that:
- Reads the PID file matching `$TYPE` (issue or review)
- Calls `kill -0` to test liveness
- Sends SIGTERM (plain `kill`) before any `nohup`
- Waits up to 5 seconds for the process to exit
- Escalates to `kill -9` only if still alive
- Removes the PID file after kill (or if the PID was already dead)

## TC-DKBS-002: Behavioral — alive PID gets SIGTERM'd

**Setup:** Start a `sleep 60` background process. Write its PID to a temp PID file. Invoke just the kill-before-spawn function (extracted as a sourceable function or inline-replicated).

**Verify:** the sleep process is no longer running after the function returns. PID file is gone.

## TC-DKBS-003: Behavioral — dead PID is handled cleanly

**Setup:** Write a clearly-not-running PID (e.g. 99999999) to a temp PID file. Invoke the kill-before-spawn function.

**Verify:** no error, function returns 0, PID file is gone.

## TC-DKBS-004: Behavioral — SIGTERM-ignoring process is escalated to SIGKILL

**Setup:** Start a process that traps SIGTERM and sleeps. Write its PID. Invoke kill-before-spawn.

**Verify:** the process is dead within ~6 seconds (5s SIGTERM grace + 1s SIGKILL settle). PID file is gone.

## TC-DKBS-005: Behavioral — empty PID file is tolerated

**Setup:** Touch an empty PID file. Invoke kill-before-spawn.

**Verify:** no error, function returns 0, file is gone afterward.

## TC-DKBS-006: Behavioral — symlink PID file is rejected

**Setup:** Create a symlink at the PID file path pointing to `/etc/passwd`. Invoke kill-before-spawn.

**Verify:** function refuses (does not follow the symlink, does not delete `/etc/passwd`).

## TC-DKBS-007: Static — both spawn paths (dev-new/resume + review) are guarded

**Verify:** every `nohup` invocation in `dispatch-local.sh` is preceded by the kill-before-spawn check (i.e. dev-new, dev-resume, review all benefit).

## TC-DKBS-008: Static — log message is emitted on kill

**Verify:** the kill-before-spawn block writes a stderr message identifying the killed PID, so operators reading dispatcher logs can correlate "agent disappeared" with "dispatcher killed it".
