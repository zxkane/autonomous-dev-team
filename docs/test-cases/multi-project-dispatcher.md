# Test Cases — Multi-project Dispatcher (PR-8)

## TC-MP-001: PROJECTS=() iterates the right number of times

**Given** dispatcher.conf with PROJECTS=("/tmp/conf-a" "/tmp/conf-b" "/tmp/conf-c")
**When** dispatcher-multi-tick.sh runs (with stub dispatcher-tick.sh)
**Then** the stub is invoked 3 times.

## TC-MP-002: AUTONOMOUS_CONF env propagated per iteration

**Given** PROJECTS=("/tmp/conf-a" "/tmp/conf-b")
**When** dispatcher-multi-tick.sh runs (with a stub that records `$AUTONOMOUS_CONF`)
**Then** the stub recorded "/tmp/conf-a" once and "/tmp/conf-b" once, in PROJECTS order.

## TC-MP-003: Per-project failure does not break the loop

**Given** PROJECTS=("/tmp/conf-a" "/tmp/conf-b") and stub returns rc=1 for conf-a, rc=0 for conf-b
**When** dispatcher-multi-tick.sh runs
**Then** both projects are attempted, the wrapper exits 0, and stderr contains a "tick failed for /tmp/conf-a" warning.

## TC-MP-004: DISPATCHER_CONF unset → wrapper aborts

**Given** DISPATCHER_CONF env unset (and no $HOME/.autonomous/dispatcher.conf, no $XDG_CONFIG_HOME/.../dispatcher.conf)
**When** dispatcher-multi-tick.sh runs
**Then** rc != 0 and stderr explains "DISPATCHER_CONF not set".

## TC-MP-005: DISPATCHER_CONF set but file missing → diagnostic

**Given** DISPATCHER_CONF=/nonexistent/path
**When** dispatcher-multi-tick.sh runs
**Then** rc != 0 and stderr names the missing path.

## TC-MP-006: Empty PROJECTS=() → exit 0 with one log line

**Given** dispatcher.conf with `PROJECTS=()`
**When** dispatcher-multi-tick.sh runs
**Then** rc == 0 and exactly one "no projects configured" log line.

## TC-MP-007: PROJECTS unset → diagnostic

**Given** dispatcher.conf that does NOT define PROJECTS
**When** dispatcher-multi-tick.sh runs
**Then** rc != 0 and stderr explains PROJECTS array missing.

## TC-MP-008: Source-of-truth check on outer loop subshell

**Given** dispatcher-multi-tick.sh source
**When** grepped for the iteration logic
**Then** the loop body runs `dispatcher-tick.sh` inside parentheses (subshell isolation), passes AUTONOMOUS_CONF as a per-iteration env, and does NOT exit on per-project failure.

## TC-MP-009: Backwards compat (single-project path)

The existing `dispatcher-tick.sh` continues to work standalone. Verified by the existing 20 unit-test files passing unchanged — no test in this PR modifies anything those tests probe.
