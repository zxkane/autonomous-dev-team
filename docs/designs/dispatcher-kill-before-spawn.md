# Dispatcher: kill stale wrapper before spawning a new one

Closes #55.

## Problem

`dispatch-local.sh` spawns a wrapper via `nohup` without checking whether a previous wrapper for the same issue is still alive. When a stale wrapper lingers (e.g. its inner agent CLI died but the outer `bash autonomous-dev.sh` is still running), the new spawn happens anyway. Two wrappers now coexist for one issue.

The `acquire_pid_guard` in `lib-agent.sh` was supposed to prevent this, but it `exit 0`s instead of taking corrective action — silently no-oping the second wrapper. The dispatcher's labels still flip (`pending-dev` → `in-progress`) but no new work happens.

In production this looked like:

- Issue dispatched, wrapper A starts.
- Wrapper A's inner `claude` CLI dies but the outer bash hangs.
- Dispatcher Step 5 marks the issue DEAD-with-no-PR → moves to `pending-dev`.
- Next cycle dispatches resume; spawn B happens; B's `acquire_pid_guard` sees A's stale PID alive → exits 0.
- Issue silently flips back and forth between `pending-dev` and `in-progress` with no real progress.

## Goal

Before any `nohup` spawn in `dispatch-local.sh`, kill any wrapper that already holds the relevant PID file for this issue+type. SIGTERM first (allow the trap to clean up), escalate to SIGKILL only if needed.

## Design

### Where the fix lives

Single chokepoint in `dispatch-local.sh`. Other options considered:

- **Modify `acquire_pid_guard` to kill instead of exit.** Rejected: spreads the kill responsibility across every wrapper, harder to reason about.
- **Have the wrapper trap clean up before exiting.** Rejected: the bug is exactly that wrappers can hang in a way the trap doesn't cover (uninterruptible IO, deadlock).

### Kill strategy

```bash
PID_FILE="<derived from $TYPE and $ISSUE_NUM>"
if [[ -f "$PID_FILE" ]]; then
  OLD_PID=$(cat "$PID_FILE" 2>/dev/null)
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Found existing wrapper for issue #${ISSUE_NUM} (PID ${OLD_PID}); sending SIGTERM..." >&2
    kill "$OLD_PID" 2>/dev/null || true
    # Wait up to 5s for the trap to run
    for _ in 1 2 3 4 5; do
      kill -0 "$OLD_PID" 2>/dev/null || break
      sleep 1
    done
    # Escalate if still alive
    if kill -0 "$OLD_PID" 2>/dev/null; then
      echo "PID ${OLD_PID} ignored SIGTERM after 5s; escalating to SIGKILL" >&2
      kill -9 "$OLD_PID" 2>/dev/null || true
      sleep 1
    fi
  fi
  # Remove the stale PID file regardless — the new wrapper will write its own.
  rm -f "$PID_FILE"
fi
```

### Why SIGTERM first, then SIGKILL after 5s

- Wrappers may have a cleanup trap that flushes logs, posts a session report, removes their own PID file. SIGTERM lets that run.
- 5 seconds is plenty for typical cleanup (gh API calls take ~1s each, traps post one-or-two comments). Longer would slow the dispatcher noticeably; shorter would too often escalate unnecessarily.
- If the wrapper is genuinely stuck (uninterruptible IO, kernel deadlock), no signal helps anyway — SIGKILL at least ensures the kernel reaps the process so the new wrapper isn't blocked.

### PID file removal

After kill (or if the file existed but the PID was already dead), `rm -f "$PID_FILE"`. Otherwise the new wrapper's `acquire_pid_guard` would see a stale file and could behave inconsistently.

### Cooperation with `acquire_pid_guard`

We do NOT change `acquire_pid_guard`. After kill-before-spawn:
- Old wrapper is dead, old PID file is removed.
- New wrapper starts, calls `acquire_pid_guard`, finds no PID file (or one with a non-existent PID), writes its own PID. Normal flow.

If we changed the guard too (defense in depth), the kill-before-spawn would mask any guard logic the wrapper relies on for direct invocations (someone running `bash autonomous-dev.sh` outside the dispatcher). Better to keep responsibilities separated.

### Edge cases

- **PID file exists, PID is already dead.** `kill -0` fails, the if-block falls through, file is removed. New spawn proceeds.
- **PID file is empty.** `cat` returns empty, `[[ -n "" ]]` fails, file is removed. New spawn proceeds.
- **PID file is a symlink.** Same risk as `acquire_pid_guard` warns about. Add the same `-L` check before `cat`.
- **PID points to an unrelated process** (PID reuse on a long-running system). Kill-before-spawn would SIGTERM something that isn't ours. Mitigated by checking that the PID file's mtime is recent (heuristic) — but that adds complexity. For now we accept the small risk: the PID file is in `/tmp/` and only this dispatcher writes there with this naming pattern.
- **SIGTERM ignored, SIGKILL also ignored.** Process is in uninterruptible kernel state. No way to recover; the new wrapper's `acquire_pid_guard` will see the empty/removed file and proceed, which is correct — there's no longer a useful wrapper to defer to.

## Out of Scope

- Changing `acquire_pid_guard` semantics (still exits 0 on conflict for direct invocations).
- Killing on `dispatch-local.sh review` calls when it would interrupt a real review in progress. The review wrapper has the same PID-file shape, so the same logic applies symmetrically; this is desired.
- Cleaning up other dispatcher-related state (worktrees, log files). Out of scope.
