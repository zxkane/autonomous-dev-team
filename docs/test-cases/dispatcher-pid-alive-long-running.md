# Test cases — long-running pid_alive false-negative (#129)

Covers the two-part fix in `dispatch-local.sh::kill_stale_wrapper` and `lib-agent.sh::install_agent_heartbeat` + `lib-dispatch.sh::pid_alive`.

Located in `tests/unit/test-pid-alive-long-running.sh`. Run via:

```bash
bash tests/unit/test-pid-alive-long-running.sh
```

## TC-PALR-001 — `kill_stale_wrapper` does NOT delete the PID file when `kill -0` missed

**Intent**: The bug from #129's "Most likely root cause" section. When `kill_stale_wrapper`'s `kill -0 $old_pid` returns failure (the PID is unreachable), the function used to `rm -f` the PID file regardless. After the fix, the file must survive.

**Setup**:
- Create a temp PID file containing a known-dead PID (e.g. `999999`).
- Set `PROJECT_DIR`, `ISSUE_NUM`, `TYPE`, `KILL_STALE_PGREP_FALLBACK=false` so the function takes the `kill -0` miss path without invoking `pgrep`.
- Source `dispatch-local.sh::kill_stale_wrapper` and call it.

**Expected**:
- Return code 0.
- PID file still exists with original content untouched.

## TC-PALR-002 — `kill_stale_wrapper` still deletes the PID file after successfully killing an alive wrapper

**Intent**: Regression-pin that Fix A does not over-correct. When we DO actually kill the holder, removing the file is still the right thing.

**Setup**:
- Spawn a real `sleep 30` subshell.
- Write its PID into the PID file.
- Call `kill_stale_wrapper`.

**Expected**:
- The sleep subshell is gone (kill -0 fails).
- PID file is removed.

## TC-PALR-003 — `pid_alive` returns ALIVE when the heartbeat sibling file is fresh, regardless of PID file state

**Intent**: Defence in depth. Even if the PID file has a stale mtime (or is gone), a fresh heartbeat sibling is sufficient evidence the wrapper is alive.

**Setup**:
- Create the PID file with a dead PID and an old mtime (e.g. 1000s ago).
- Create the sibling `*.heartbeat` file with `mtime = now`.
- Call `pid_alive issue <N>` with `HEARTBEAT_INTERVAL_SECONDS=10`.

**Expected**:
- Return code 0 (ALIVE).

## TC-PALR-004 — `pid_alive` returns DEAD when BOTH PID file and heartbeat file are stale

**Intent**: Don't regress legitimate crash detection (Acceptance Criteria #2 from #129).

**Setup**:
- Create the PID file with a dead PID and an old mtime (1000s ago).
- Create the heartbeat file with a matching old mtime.
- Call `pid_alive issue <N>` with `HEARTBEAT_INTERVAL_SECONDS=10` (threshold = 30s).

**Expected**:
- Return code 1 (DEAD).

## TC-PALR-005 — `install_agent_heartbeat` creates and refreshes the heartbeat sibling

**Intent**: The heartbeat loop must touch BOTH the PID file (back-compat with pre-#129 dispatcher) AND the new sibling file. Both mtimes advance.

**Setup**:
- Set the PID file mtime far in the past.
- Pre-create the sibling file with the same far-past mtime.
- Call `install_agent_heartbeat` with `HEARTBEAT_INTERVAL_SECONDS=1`, `AGENT_PID_FILE=<path>`.
- Sleep 2s.
- Tear down the heartbeat process.

**Expected**:
- Both mtimes have advanced.
- Heartbeat process exits when the parent shell exits (re-uses TC-HB-007's coverage).

## TC-PALR-006 — end-to-end: PID file deleted mid-run, heartbeat sibling keeps `pid_alive` ALIVE

**Intent**: Repro of #129's exact failure mode. A spurious deletion of the PID file (e.g. by the buggy pre-fix `kill_stale_wrapper`) must NOT trip `pid_alive` into DEAD as long as the heartbeat is still ticking.

**Setup**:
- Use the current process PID (guaranteed alive; bypasses the `kill -0` miss).
- Wait — actually we need the failure mode to *also* cover the `kill -0` miss. Two flavours:
  - **TC-PALR-006a**: PID file gone, heartbeat sibling fresh → `pid_alive` returns ALIVE.
  - **TC-PALR-006b**: PID file gone, heartbeat sibling absent → `pid_alive` returns DEAD (regression bound; without Fix B alone there's no escape).

**Expected**:
- TC-PALR-006a: rc=0 (ALIVE) — Fix B saves us.
- TC-PALR-006b: rc=1 (DEAD) — without the heartbeat sibling, `pid_alive` correctly fails closed.

## Static-analysis pin (TC-PALR-STATIC-001)

`grep` for the literal "INV-29" string in `dispatch-local.sh` and `lib-agent.sh` so a future refactor can't silently drop the invariant reference. Also pins the `_HEARTBEAT_FILE` derivation pattern in `lib-agent.sh` and that `kill_stale_wrapper` does NOT remove `*.heartbeat`.

## Out-of-scope: 75-min real-time test

The acceptance criterion "75-min healthy wrapper does not stall" is verified at the consumer-project level (downstream regression run). Reproducing it as a unit test would 15× the test suite runtime; the failure-mode-simulating tests above cover the same failure surface in seconds.
