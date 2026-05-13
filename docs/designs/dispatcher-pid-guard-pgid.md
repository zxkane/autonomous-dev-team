# Dispatcher: PID guard tracks the entire agent subtree (process groups)

Closes #109.

## Problem

`acquire_pid_guard` (`lib-agent.sh:278`) writes `$$` of the wrapper shell
(`autonomous-dev.sh` / `autonomous-review.sh`) into PID_FILE. The actual
long-running work — `timeout 4h … claude …` — runs as a child of that
shell. When the wrapper shell exits before the agent subtree finishes
unwinding (cleanup-trap path, SIGTERM forwarding race, normal completion),
the timeout subtree gets reparented to PID 1 and the next dispatcher tick
can no longer reach it through PID_FILE.

`kill_stale_wrapper` runs but reads a PID that's either:
- already gone (shell exited; ESRCH on `kill -0`); or
- a fresh wrapper's `$$` (the file was rewritten),

so it declares the slot clean and `dispatch-local.sh` fork-execs another
wrapper. Multiple agent trees coexist. Today's reproduction (4 generations
06:30/06:45/07:06/07:25, 2 still alive an hour after merge) is the
failure mode.

This is **not** the same bug as #55 (which fixed "no kill before spawn at
all"). Here `kill_stale_wrapper` runs but reads the wrong PID.

## Goal

**PID_FILE must point at a process whose death is sufficient to reap the
entire agent subtree.** The shell's `$$` does not satisfy this. Either:

- (A) write the `timeout(1)` PID and rely on its single death to cascade, or
- (B) put the agent tree in its own process group (PGID) and signal the
  group, or
- (C) leave PID_FILE as `$$` and have `kill_stale_wrapper` chase descendants
  by name.

## Decision: option B — process groups via `setsid`, with C as defence

Trade-off:

- **(A) timeout PID** is small but fragile — if `timeout` itself is
  bypassed (no coreutils on PATH, the rare host without `timeout(1)`),
  `_run_with_timeout` falls back to running the agent directly, with no
  single ancestor to track. The hung-agent-without-timeout case still
  leaks. PID is also a moving target (we'd need `&` + `wait` + `$!` and
  rewrite PID_FILE *after* spawn — racy under SIGTERM-during-spawn).
- **(B) PGID via `setsid`** is the durable contract: every descendant
  inherits the PGID, `kill -TERM -- -<PGID>` cascades atomically, and the
  PGID is stable from the moment we spawn. Works whether `timeout(1)` is
  present or not (we put the launcher itself in a session). The PGID we
  write to PID_FILE is exactly the leader's PID, which `kill -0 <pgid>`
  validates the same way.
- **(C) `pgrep` fallback** is a belt-and-suspenders for old PID files
  written by pre-fix wrappers (mid-rollout) or for trees where the
  session leader has died but descendants still cling to the old PGID
  number that's been recycled. Cheap, runs only on the kill path.

Pick **B + C**. (A) is rejected as fragile.

## Design

### `_run_with_timeout` becomes the session leader

```bash
_run_with_timeout() {
  if [[ -n "$_AGENT_TIMEOUT_CMD" ]]; then
    setsid "$_AGENT_TIMEOUT_CMD" --kill-after=30s --signal=TERM "$AGENT_TIMEOUT" \
      "${AGENT_LAUNCHER_ARGV[@]}" "$@"
  else
    setsid "${AGENT_LAUNCHER_ARGV[@]}" "$@"
  fi
}
```

`setsid(1)` forks (so the wrapper shell stays in the foreground via the
exec'd `setsid` returning when its child exits) and starts a new session.
Every descendant inherits the new PGID. We capture the PGID of the session
leader by recording `$!` of a backgrounded launcher and `wait`'ing on it.

Concretely the wrapper changes shape: instead of running the agent as a
foreground child of the shell, it runs it as a backgrounded session leader
and `wait`s. That gives us:

- `$!` is the session leader's PID (and PGID, since `setsid` makes it the
  group leader too).
- We can write that PID to PID_FILE *after spawn* but *before* `wait` —
  `kill_stale_wrapper` always sees a real, live group.
- On SIGTERM the wrapper's trap sends `kill -TERM -- -<pgid>` which
  cascades to every descendant.

```bash
# autonomous-dev.sh
AGENT_PGID=""
on_sigterm() {
  RECEIVED_SIGTERM=1
  if [[ -n "$AGENT_PGID" ]]; then
    kill -TERM -- "-$AGENT_PGID" 2>/dev/null || true
  fi
}

run_agent_supervised "$SESSION_ID" "$PROMPT" "$AGENT_DEV_MODEL" "$SESSION_NAME" &
AGENT_PGID=$!
echo "$AGENT_PGID" > "$PID_FILE"
wait "$AGENT_PGID"
AGENT_EXIT=$?
```

But this approach changes too much (we'd need to refactor every `run_agent`
caller). A simpler alternative keeps the call sites identical:

#### Implementation: encapsulate inside `_run_with_timeout`

`_run_with_timeout` runs the launcher with `setsid` in the background,
records the PGID in a global, writes it to PID_FILE via a callback, then
`wait`s. The wrapper provides the PID_FILE path via an environment
variable; if unset, `_run_with_timeout` skips the write (preserves
behaviour for direct callers like tests).

```bash
# Globals:
#   AGENT_PID_FILE — if set, _run_with_timeout writes the session-leader
#                    PID into this file after spawn and BEFORE wait.
#   _AGENT_RUN_PID — last spawned session-leader PID, exported for use by
#                    SIGTERM traps in callers.

_run_with_timeout() {
  local cmd=()
  if [[ -n "$_AGENT_TIMEOUT_CMD" ]]; then
    cmd=("$_AGENT_TIMEOUT_CMD" --kill-after=30s --signal=TERM "$AGENT_TIMEOUT")
  fi
  cmd+=("${AGENT_LAUNCHER_ARGV[@]}" "$@")

  if command -v setsid >/dev/null 2>&1; then
    setsid "${cmd[@]}" &
  else
    # Defensive fallback: setsid is in util-linux; if absent (busybox?), run
    # in the same group as the wrapper. We lose the cascade guarantee but
    # the pgrep fallback in kill_stale_wrapper still picks up orphans.
    "${cmd[@]}" &
  fi
  _AGENT_RUN_PID=$!
  if [[ -n "${AGENT_PID_FILE:-}" ]]; then
    # Symlink-defence: refuse to write through a symlink (CWE-59).
    # Do NOT delete a symlinked target — let acquire_pid_guard already
    # have rejected it; we just no-op the write.
    if [[ ! -L "$AGENT_PID_FILE" ]]; then
      printf '%s\n' "$_AGENT_RUN_PID" > "$AGENT_PID_FILE"
    fi
  fi
  wait "$_AGENT_RUN_PID"
}
```

Because `setsid` makes the spawned process a session and group leader,
`_AGENT_RUN_PID` IS the PGID. `kill -- -$_AGENT_RUN_PID` signals the
group.

#### Pipeline branches (codex / opencode)

Codex and opencode pipe `_run_with_timeout … | _capture_filter`. The
backgrounded `setsid` call doesn't compose with `|` the same way. We
keep the pipeline shape but redirect through a FIFO:

```bash
fifo=$(mktemp -u "$PID_DIR/agent-fifo.XXXXXX")
mkfifo -m 600 "$fifo"
trap 'rm -f "$fifo"' RETURN

_capture_thread "$session_id" < "$fifo" &
capture_pid=$!

# _run_with_timeout writes its stdout to the fifo
_run_with_timeout "$AGENT_CMD" exec --json … > "$fifo"
rc=$?

wait "$capture_pid" 2>/dev/null || true
return $rc
```

Slightly more code but preserves the capture-thread sidecar semantics and
keeps the agent in its own session.

### `acquire_pid_guard` in the wrapper shell

The wrapper still calls `acquire_pid_guard` early to refuse a duplicate
launch. But it must NOT pre-write `$$` — the real PID is written later
by `_run_with_timeout`. New shape:

```bash
acquire_pid_guard() {
  local pid_file="$1" label="$2" issue_num="$3"
  [[ -L "$pid_file" ]] && { echo "Error: PID file is a symlink — possible attack" >&2; exit 1; }
  if [[ -f "$pid_file" ]]; then
    local existing_pid
    existing_pid=$(cat "$pid_file" 2>/dev/null)
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "[$label] Another instance for issue #${issue_num} is already running (PID $existing_pid). Exiting." >&2
      exit 0
    fi
  fi
  # Write a placeholder ($$) so kill_stale_wrapper can still see SOMETHING
  # owns this slot. _run_with_timeout will overwrite with the real PGID.
  echo $$ > "$pid_file"
}
```

We keep the placeholder write so the slot is reserved between
`acquire_pid_guard` and the first `_run_with_timeout` call (e.g., during
`gh issue view` to fetch context). `kill_stale_wrapper` calling
SIGTERM on `$$` would still work — bash forwards SIGTERM via the
existing `on_sigterm` trap, which now also kills the group via PGID
once `_run_with_timeout` has run.

### Wrapper SIGTERM trap

Both `autonomous-dev.sh` and `autonomous-review.sh` install a SIGTERM
trap. Update them to additionally signal the session group:

```bash
on_sigterm() {
  RECEIVED_SIGTERM=1
  # Forward TERM to the agent session (set by _run_with_timeout).
  # Falls back to direct children if we caught SIGTERM before the agent spawned.
  if [[ -n "${_AGENT_RUN_PID:-}" ]]; then
    kill -TERM -- "-${_AGENT_RUN_PID}" 2>/dev/null || true
  fi
  pkill -TERM -P $$ 2>/dev/null || true
}
```

### `kill_stale_wrapper` in `dispatch-local.sh`

The function reads PID_FILE and kills whatever PID it finds. Two changes:

1. **Send the kill to the group, not just the leader.** `kill -TERM -- -PID`
   nukes the whole tree atomically. Falls back to `kill -TERM PID` if
   the group kill fails (e.g., the file still holds a `$$` placeholder
   from acquire_pid_guard, before _run_with_timeout had a chance to
   rewrite — extremely narrow window, but harmless).
2. **Defence: scan for orphans by command line.** After the PID-file
   path, additionally `pgrep -f "autonomous-(dev|review).sh.*--issue ${ISSUE_NUM}\b"`
   plus matching by session name (`dev-issue-N`, `review-issue-N`).
   Any matches that aren't us, SIGTERM their group too. Catches:
   - escaped trees from pre-fix deployments
   - the rare case where setsid wasn't available and the tree shares
     our group

The defence step is gated on `KILL_STALE_PGREP_FALLBACK` (default `true`)
so an operator who suspects the matcher is over-reaching can disable it.

### Ordering & race notes

- The wrapper writes `$$` via `acquire_pid_guard`. If a kill arrives
  between that write and `_run_with_timeout`, the wrapper trap forwards
  to children but there are none yet — the wrapper itself dies on
  SIGTERM and that's the entire tree. No leak.
- `_run_with_timeout` writes the PGID to PID_FILE *before* calling
  `wait`. If a kill arrives between spawn and write, the group is
  reachable via `pgrep` defence even though PID_FILE still holds `$$`.
- After `wait` returns (agent exited normally), the cleanup trap
  removes PID_FILE. If a fresh tick races us, `kill_stale_wrapper` sees
  no file and skips the kill path. The agent has already exited so no
  orphans.

### What we deliberately do not do

- We don't refactor `run_agent` to background-and-wait at the call sites.
  `_run_with_timeout` is the chokepoint; one place to get setsid right.
- We don't change the PID_FILE filename or location. Same path, same
  per-user 0700 dir, same symlink-refusal contract.
- We don't change the success-path label transitions. SIGTERM-with-PR
  still rewrites exit_code → 0 (INV-15 / #67 contract preserved).

## Acceptance criteria → mapping

| Criterion (from #109) | Where addressed |
|---|---|
| PID_FILE points at a process whose death reaps the whole subtree | `_run_with_timeout` writes PGID via `setsid` |
| Regression test: SIGTERM-during-agent leaves 0 descendants | `tests/lib-agent_pgid.bats::sigterm_kills_subtree` |
| No new orphan-tree accumulation across N ticks | `tests/dispatch-local_kill_stale.bats::N_ticks_no_accumulation` |
| Existing symlink-refusal + ESRCH preserved | `acquire_pid_guard` symlink check unchanged; `kill_stale_wrapper` ESRCH path unchanged |
| `dev-resume` empty-session falls back to new (#107) | Untouched in this PR |

## Risks

| Risk | Mitigation |
|---|---|
| `setsid` missing on a target host | Fallback to non-setsid spawn; `pgrep` defence still catches orphans (degraded but not broken) |
| `pgrep` defence over-matches | Scoped to `--issue ${N}\b` AND `dev-issue-N` / `review-issue-N` patterns, both highly specific. Disable via `KILL_STALE_PGREP_FALLBACK=false`. |
| FIFO-based capture pipeline introduces a hang if capture filter dies first | We `wait` on the capture pid with a `\|\| true` and rely on `_run_with_timeout` writing to the fifo. If the reader dies, the writer gets EPIPE and exits. Add explicit cleanup of the fifo file in a RETURN trap. |
| Pre-rollout PID files (containing `$$`) don't have a process group | `kill_stale_wrapper` falls through to `pgrep` defence; old `$$` is reaped by direct kill on the leader, descendants by pgrep |

## Test coverage

See `docs/test-cases/dispatcher-pid-guard-pgid.md`. Two unit fixtures
(SIGTERM cascade; symlink/ESRCH preservation) and one integration
fixture (N consecutive ticks, assert one tree after each).
