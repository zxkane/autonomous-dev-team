# Test Cases — PID Directory Hardening (PR-7)

## TC-PD-001: AUTONOMOUS_PID_DIR override wins

**Given** `AUTONOMOUS_PID_DIR=/tmp/test-pid-xxx` is set
**When** `pid_dir_for_project` is called
**Then** returns `/tmp/test-pid-xxx`, dir is created with mode 0700.

## TC-PD-002: XDG_RUNTIME_DIR is preferred over HOME fallback

**Given** `AUTONOMOUS_PID_DIR` unset, `XDG_RUNTIME_DIR=/run/user/1000` set
**When** `pid_dir_for_project` is called with `PROJECT_ID=test`
**Then** returns `/run/user/1000/autonomous-test`, dir created with mode 0700.

## TC-PD-003: HOME fallback when XDG_RUNTIME_DIR unset

**Given** `AUTONOMOUS_PID_DIR` and `XDG_RUNTIME_DIR` both unset, `HOME=/home/u`
**When** `pid_dir_for_project` is called with `PROJECT_ID=test`
**Then** returns `/home/u/.local/state/autonomous-test`, dir created with mode 0700.

## TC-PD-004: Idempotent on second call

**Given** the dir already exists with mode 0700
**When** `pid_dir_for_project` is called twice
**Then** both calls return the same path; second call does not error; mode remains 0700.

## TC-PD-005: Refuses pre-existing symlink

**Given** `XDG_RUNTIME_DIR/autonomous-test` is a symlink to `/tmp/anywhere`
**When** `pid_dir_for_project` is called
**Then** returns rc != 0 and writes a clear error to stderr; does NOT create the dir.

## TC-PD-006: All existing PID-using tests pass with AUTONOMOUS_PID_DIR

**Given** AUTONOMOUS_PID_DIR is exported in test setup
**When** test-pid-guard.sh, test-kill-before-spawn.sh run
**Then** all assertions pass; PID files are written under the test dir, not /tmp.

## TC-PD-007: dispatch-local.sh writes PID files to the new dir

**Given** A dispatch invocation with AUTONOMOUS_PID_DIR set
**When** kill_stale_wrapper / new wrapper spawn
**Then** PID file path matches `${AUTONOMOUS_PID_DIR}/{issue,review}-${N}.pid`.
