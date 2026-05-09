# Design Canvas — PID Directory Hardening (PR-7)

**Branch**: `feat/pid-dir-xdg`
**Closes**: #72
**Pipeline-docs touched**: `docs/pipeline/invariants.md` ([INV-01], [INV-02]).

---

## Problem

Wrapper PID files live at predictable `/tmp/agent-${PROJECT_ID}-{issue,review}-${N}.pid` paths. Existing `INV-02` symlink defense (`acquire_pid_guard`, `kill_stale_wrapper`, `pid_alive`) bounds the worst-case attacker outcome to "wrapper aborts loudly", but the predictable path itself is CWE-377-shaped: a local user who can guess `PROJECT_ID` + issue numbers can DoS the pipeline by planting symlinks faster than the wrapper can spawn.

## Decision

Move PID files into a per-user directory under `XDG_RUNTIME_DIR` (or `$HOME/.local/state` fallback). Per-user directories are already mode 0700 by spec — no other local user can plant symlinks there. This eliminates the CWE-377 surface without needing per-spawn `mktemp`-d randomness.

We deliberately do **not** follow the issue's literal "mktemp-d at install time + persist path in autonomous.conf" path because:

- Most distros wipe `/tmp` on reboot → setup step has to be re-run.
- `XDG_RUNTIME_DIR` is the canonical Linux pattern (systemd creates it, mode 0700, on tmpfs, cleaned at session end).
- A user-private deterministic path is just as secure as a random path: the security boundary is the parent directory's mode, not the leaf-name entropy.

`autonomous.conf` is **not** modified. The dir path is computed lazily from `PROJECT_ID` + the user's runtime base, which both wrappers and the dispatcher already have.

## Scope

PID files only (per the issue). Log files at `/tmp/agent-${PROJECT_ID}-*.log` stay where they are — moving logs has a much larger blast radius (referenced from is_session_completed parser, comments, error messages, README) and is a separate cleanup if it's needed at all. Logs don't have the same DoS surface anyway: the wrapper appends, doesn't depend on file existence.

## Refactor

One new helper, one new use site, no behavior change on the success path.

### `lib-dispatch.sh::pid_dir_for_project`

```bash
# pid_dir_for_project — return the per-user directory holding PID files for
# this project. Idempotent: creates the dir on first call (mode 0700) and
# returns the path on subsequent calls.
#
# Path resolution (in priority order):
#   1. AUTONOMOUS_PID_DIR (env override, used by tests)
#   2. $XDG_RUNTIME_DIR/autonomous-${PROJECT_ID}   (the canonical Linux choice)
#   3. $HOME/.local/state/autonomous-${PROJECT_ID} (fallback)
#
# Refuses to use a path that resolves through a symlink (CWE-59 defense like
# INV-02 — the dir mode is per-user already, but defense in depth).
pid_dir_for_project() { ... }
```

### Affected callsites

| File | Before | After |
|---|---|---|
| `dispatch-local.sh:42` | `LOG_PREFIX="/tmp/agent-${PROJECT_ID}"` | unchanged for log paths; PID lookup separate |
| `dispatch-local.sh:127-128` | `${LOG_PREFIX}-{issue,review}-${N}.pid` | `$(pid_dir_for_project)/{issue,review}-${N}.pid` |
| `autonomous-dev.sh:89` | `/tmp/agent-${PROJECT_ID}-issue-${N}.pid` | `$(pid_dir_for_project)/issue-${N}.pid` |
| `autonomous-review.sh:71` | `/tmp/agent-${PROJECT_ID}-review-${N}.pid` | `$(pid_dir_for_project)/review-${N}.pid` |
| `lib-dispatch.sh:243` (`pid_alive`) | `/tmp/agent-${PROJECT_ID}-${kind}-${N}.pid` | `$(pid_dir_for_project)/${kind}-${N}.pid` |
| `lib-dispatch.sh:251` (`get_pid`) | same as above | same as above |

The logical PID file naming becomes `${kind}-${N}.pid` (drops the redundant `agent-${PROJECT_ID}-` prefix because that's now the parent directory). `${kind}` is `issue` for dev and `review` for review — preserved verbatim.

`dispatch-local.sh::kill_stale_wrapper` accepts the PID file path and is path-shape-agnostic — no change needed there.

`acquire_pid_guard` in `lib-agent.sh` accepts the PID file path verbatim and already enforces INV-02 — no change.

## Behavior parity

| Scenario | Before | After |
|----------|--------|-------|
| Normal wrapper spawn | PID file written to /tmp | PID file written to $XDG_RUNTIME_DIR/autonomous-${PROJECT_ID}/ |
| Concurrent dispatcher + wrapper liveness probe | both read the same /tmp path | both compute the same XDG path |
| Symlink-attack on PID file | INV-02 catches at acquire_pid_guard / kill_stale_wrapper | unchanged — same defense, plus parent dir is 0700 |
| Cron without DBus session ($XDG_RUNTIME_DIR unset) | n/a | falls back to $HOME/.local/state/autonomous-${PROJECT_ID}/ |
| First call on a fresh machine | dir exists (/tmp) | helper does `mkdir -p` and `chmod 700` |
| File-not-found on liveness probe | `cat: No such file: rc=1` (silent) | unchanged: helper creates the dir, but missing PID file still rc=1 |

## Tests

1. `tests/unit/test-pid-dir-helper.sh`:
   - XDG_RUNTIME_DIR honored when set
   - Fallback to ~/.local/state when XDG_RUNTIME_DIR unset
   - AUTONOMOUS_PID_DIR override takes priority
   - Mode 0700 after creation
   - Idempotent on second call
   - Refuses symlink-target dir (rc != 0)
2. Existing `test-pid-guard.sh` and `test-kill-before-spawn.sh` continue to work because they construct PID file paths via the wrapper's own logic; they just need `AUTONOMOUS_PID_DIR=$tmpdir` exported in their setup.

## Out of scope

- Log file path migration (separate cleanup, larger blast radius, no DoS surface).
- The `LOG_PREFIX="/tmp/agent-${PROJECT_ID}"` variable in `dispatch-local.sh` stays for log paths and the error message.
- Backwards-compat for stale PID files at the old `/tmp` paths after upgrade. Wrappers naturally won't find them; the worst case is one wasted retry per active issue at upgrade time. Documented in the migration notes.
