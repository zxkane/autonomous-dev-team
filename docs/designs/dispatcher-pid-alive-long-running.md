# Design: long-running healthy wrappers must not be misclassified as DEAD (#129)

## Problem

A long-running healthy `autonomous-dev` wrapper (~70+ min, single Claude session, real progress, eventual successful PR) is repeatedly classified as crashed by the dispatcher's `pid_alive` check, exhausting `MAX_RETRIES` and triggering `mark_stalled` despite continuous progress. See issue #129 for the full timeline.

Existing defences each individually fail in this scenario:

- `dev_near_success` ([INV-27]) needs a `Dev Session ID:` / `Exit code: 0` / live `kill -0 <pid>` signal within 300s. None hold for a long mid-session run.
- `mark_stalled` ([INV-26]) defers only when `pid_alive` reports ALIVE — same false-negative re-rolls.
- `pid_alive` mtime fallback (#111 Part B) needs the PID file's mtime to be fresh. The heartbeat loop *should* keep it fresh, but doesn't, because:
  - At T0+15m the dev-resume's `kill_stale_wrapper` runs. `kill -0 $old_pid` fails (the agent-tree session leader's PID has drifted out of `kill -0` reachability via the `AGENT_LAUNCHER='bash -c "source ~/.bash_aliases && cc \"$@\"' --'` indirection). Nothing is actually killed — but `rm -f "$pid_file"` runs **unconditionally** (line 144 of `dispatch-local.sh`).
  - The heartbeat loop's `touch` is guarded by `[[ -f "$pid_file" && ! -L "$pid_file" ]]`, so after the deletion the next iteration silently no-ops. The PID file is gone; there is nothing to keep fresh.
  - Next tick: `pid_alive` finds no PID file → DEAD → "Task appears to have crashed (no PR found)" → cycle repeats until `MAX_RETRIES`.

## Fix

Two complementary fixes — both land in this PR.

### Fix A: `kill_stale_wrapper` preserves the PID file when nothing was killed

In `skills/autonomous-dispatcher/scripts/dispatch-local.sh::kill_stale_wrapper`, the `rm -f "$pid_file"` at the bottom of the function runs even when the inner `kill -0 "$old_pid"` returned failure (i.e. nothing was actually killed). This is the bug the inline comment "Remove PID file regardless" identifies — "regardless" is precisely wrong.

Change: track whether we successfully signalled the old PID. If we did not (the `kill -0` miss path), leave the PID file in place. The heartbeat loop in the (still-alive) wrapper then continues touching it, the `pid_alive` mtime fallback gets the data it needs, and the dispatcher correctly classifies the wrapper as ALIVE on subsequent ticks.

If we *did* successfully kill (or the file is empty / unreadable / contains a non-numeric PID), keep the existing behaviour and `rm -f` the PID file — leaving stale data behind would leak into the next acquire.

### Fix B: sibling `*.heartbeat` file owned only by the wrapper

Defence in depth against future regressions of Fix A and against any other code path that might delete the PID file out from under a live wrapper:

- `install_agent_heartbeat` (`lib-agent.sh`) writes a sibling file alongside `AGENT_PID_FILE`: `${AGENT_PID_FILE%.pid}.heartbeat`. The same `touch` cadence applies — the loop touches BOTH the PID file (back-compat: existing pid_alive mtime fallback still works on hosts running mixed wrapper/dispatcher versions) AND the heartbeat file.
- The wrapper's `cleanup` trap removes both files at exit — so the heartbeat file does not outlive the wrapper.
- `kill_stale_wrapper` does NOT touch the heartbeat file. Its responsibility is the PID file (which is keyed on the PID it kills); the heartbeat file's mtime is owned exclusively by the still-alive wrapper.
- `pid_alive` extends the existing mtime fallback to also consult the heartbeat file's mtime: ALIVE if EITHER file's mtime is fresh within `HEARTBEAT_INTERVAL_SECONDS * 3`.

This means: even if a future change re-introduces the unconditional `rm -f` (or some other path nukes the PID file), the heartbeat file survives, the wrapper keeps refreshing its mtime, and `pid_alive` stays accurate.

## Out of scope

Fix (c) from the issue — replacing `kill -0 <leader>` with a process-group probe — is more invasive and not required to close #129. The mtime-based fallback (Fix B) already covers the failure mode without changing the kill semantics. Filed as a future option if a downstream consumer hits a different escape.

The proposed `dev_near_success` window stretch is also not adopted: it widens the false-positive window for long runs but does not fix the root cause and would over-extend the legitimate-crash detection budget.

## Invariant

New invariant **INV-29**: the dispatcher's `pid_alive` mtime tier MUST consult a heartbeat sibling file whose lifecycle is owned exclusively by the wrapper, NOT the PID file alone. `kill_stale_wrapper` MUST NOT delete a PID file when its `kill -0` liveness check returned failure (no actual kill happened).

Added to `docs/pipeline/invariants.md` with cross-references to [INV-23] (PID_FILE reaps subtree, primary path), [INV-24] / [INV-27] (near-success short-circuits, upstream gates), and [INV-26] (stall-decision liveness deferral, downstream gate).

## Test plan

See `docs/test-cases/dispatcher-pid-alive-long-running.md`. The unit tests simulate the exact failure mode from #129 in seconds rather than running real 75-min sessions:

- TC-PALR-001: `kill_stale_wrapper` does not delete the PID file when its `kill -0` miss path is taken (PID is dead but content is non-empty).
- TC-PALR-002: `kill_stale_wrapper` still deletes the PID file when it successfully killed an alive wrapper.
- TC-PALR-003: `pid_alive` returns ALIVE when the PID is unreachable but the heartbeat sibling file is fresh.
- TC-PALR-004: `pid_alive` returns DEAD when both PID file and heartbeat file are stale.
- TC-PALR-005: `install_agent_heartbeat` creates and refreshes the heartbeat sibling.
- TC-PALR-006: end-to-end — PID file deleted mid-flight, heartbeat survives, `pid_alive` stays ALIVE.

E2E coverage of the 75-min window is intentionally left to the consumer-project regression tests; replicating it here would 15× the unit test runtime.
