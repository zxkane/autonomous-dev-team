# Test cases — Dispatcher PID guard tracks the agent subtree (PGID)

Closes #109. Companion to `docs/designs/dispatcher-pid-guard-pgid.md`.

## Acceptance criteria → test mapping

| Criterion | Test ID |
|---|---|
| PID_FILE points at a process whose death reaps the entire subtree | TC-PGID-001, TC-PGID-002 |
| Regression: SIGTERM-during-agent leaves 0 surviving descendants | TC-PGID-003 |
| `kill_stale_wrapper` group-kills via `kill -TERM -- -<pgid>` | TC-PGID-004 |
| Defensive `pgrep` fallback catches escaped trees from pre-fix wrappers | TC-PGID-005 |
| Existing symlink-refusal preserved | TC-PGID-006 |
| Existing ESRCH/dead-PID handling preserved | TC-PGID-007 |
| `_run_with_timeout` writes PGID into `$AGENT_PID_FILE` if set | TC-PGID-008 |
| `_run_with_timeout` no-op when `AGENT_PID_FILE` unset (back-compat) | TC-PGID-009 |
| Wrapper SIGTERM trap forwards to PGID once spawn has run | TC-PGID-010 |

## Test fixtures

### TC-PGID-001 — `_run_with_timeout` puts the agent in its own session

**Setup**: source `lib-agent.sh`, set `AGENT_TIMEOUT=10s`, set `AGENT_PID_FILE` to a tmp path. Run a fake agent script that prints its session ID (`ps -o sid= -p $$`).

**Assert**:
- The session ID printed by the child is NOT equal to the parent shell's session ID.
- The PID written to `AGENT_PID_FILE` equals the session leader's PID (so killing it with `kill -- -<pid>` is valid).

### TC-PGID-002 — Killing the PGID kills the whole subtree

**Setup**: spawn an agent that forks two grandchildren that `trap '' TERM; sleep 60`.

**Assert** after `kill -TERM -- -<pgid>`:
- All three processes (agent + two grandchildren) are gone within 5 seconds.
- The `pkill -P` direct-children-only path WOULD have failed to reap the grandchildren — verify by also testing that a grandchild PID is no longer reachable.

### TC-PGID-003 — Wrapper SIGTERM during running agent leaves 0 descendants

**Setup**: spawn `autonomous-dev.sh` (mocked end-to-end with a fake `claude` that ignores SIGTERM for 30s and forks a grandchild that also ignores it). SIGTERM the wrapper after 1 second.

**Assert** within 10 seconds:
- The wrapper itself is gone.
- The fake `claude` and its grandchild are both gone.
- No process with `--issue ${N}` in its argv remains alive.

### TC-PGID-004 — `kill_stale_wrapper` issues a group-kill, not just a leader-kill

**Setup**: write a PID into PID_FILE that points at a session leader spawned via `setsid`. The leader has a child that ignores SIGTERM directed at the leader (`trap '' TERM`) but obeys SIGTERM directed at the group.

**Assert**: `kill_stale_wrapper` reaps the entire group, not just the leader. (Tests via `pgrep -g <pgid>` returning empty.)

### TC-PGID-005 — `pgrep` fallback catches escaped trees from pre-fix PID files

**Setup**: write a `$$` placeholder into PID_FILE (simulating a pre-fix wrapper that died before writing the real PGID). Spawn an orphaned tree manually with the matching `dev-issue-123` argv.

**Assert**: `kill_stale_wrapper` finds and reaps the orphan via the `pgrep -f` fallback (gated on `KILL_STALE_PGREP_FALLBACK=true`, which is the default).

### TC-PGID-006 — Symlink PID file still rejected

Same as existing TC-DKBS-006: PID_FILE is a symlink → `kill_stale_wrapper` returns non-zero AND does not delete the symlink target.

### TC-PGID-007 — Dead PID handled cleanly (ESRCH path)

Same as existing TC-DKBS-003: `kill -0` returns ESRCH → function returns 0 quickly, removes the PID file. Plus: pgrep fallback runs and finds nothing.

### TC-PGID-008 — `_run_with_timeout` writes PGID to `$AGENT_PID_FILE`

**Setup**: source `lib-agent.sh`, export `AGENT_PID_FILE=/tmp/test.pid`, run a quick agent (`echo hi`). Read the file after the call returns.

**Assert**: file contains a numeric PID; `kill -0 <pid>` returns ESRCH (process already exited, expected); the value previously WAS a real PID (we observed it before exit via a `wait`-after-spawn race-free hook).

Implementation note: easier to validate by reading the value during the spawn (sleep agent) — see test code.

### TC-PGID-009 — `_run_with_timeout` no-op when `AGENT_PID_FILE` unset

**Setup**: unset `AGENT_PID_FILE`. Run `_run_with_timeout echo hi`.

**Assert**: returns 0; no file written; output is `hi`.

### TC-PGID-010 — Wrapper SIGTERM trap forwards to PGID

**Setup**: extract `on_sigterm` from `autonomous-dev.sh`, set `_AGENT_RUN_PID` to a session leader's PID, send SIGTERM to the test shell.

**Assert**: the agent session leader (and its descendants) get SIGTERM.

## Static checks (script content)

| ID | Check |
|---|---|
| TC-STATIC-001 | `lib-agent.sh` defines `_run_with_timeout` using `setsid` (or a documented fallback) |
| TC-STATIC-002 | `lib-agent.sh` introduces `_AGENT_RUN_PID` and `AGENT_PID_FILE` globals |
| TC-STATIC-003 | `autonomous-dev.sh` `on_sigterm` references `_AGENT_RUN_PID` and uses `kill -- -<pid>` group syntax |
| TC-STATIC-004 | `autonomous-review.sh` has the same SIGTERM trap (parity) |
| TC-STATIC-005 | `dispatch-local.sh::kill_stale_wrapper` uses `kill -TERM -- -<pid>` group syntax |
| TC-STATIC-006 | `dispatch-local.sh` has a `pgrep -f` fallback path gated on `KILL_STALE_PGREP_FALLBACK` |

## Risks left untested (out of scope here)

- `setsid` behavior on macOS GNU coreutils builds — the dispatcher fleet
  is Linux/Ubuntu, and macOS users will pick up util-linux via Homebrew.
  Documented in the design doc's risk table.
- True multi-tick orphan accumulation across cron — covered by the
  reproduction artifact in #109 and validated manually post-deploy.
