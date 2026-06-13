# Design — re-dispatch log retention (issue #245)

## Problem

`dispatch-local.sh:60-63` zeroes the per-issue agent log on **every** dispatch via
`install -m 600 /dev/null "${LOG_PREFIX}-{issue,review}-${ISSUE_NUM}.log"`. The wrapper then
redirects with `>>` (append) — but the preceding `install` already truncated the file to empty, so
a **re-dispatch of the same issue destroys the prior run's log content** before the new run starts.

When a wrapper crashes/aborts and the issue is re-dispatched (retry, resume, operator label flip),
the crashed run's stdout/stderr is gone — no forensic trail to triage the failure.

The `install -m 600 /dev/null` exists only to create the file `0600` before the agent writes
potentially-secret output (added in #22). It was a perm-hardening side effect, never a
log-rotation policy.

## Goal

Preserve the prior run's log on a routine re-dispatch, while:
- retaining the `0600` permission guarantee (the log must never exist world-readable, including the
  rotated generation),
- leaving the **deliberate** INV-12 (`prompt_too_long`) and INV-35 (`failed-substantive`)
  recovery-truncates in `lib-dispatch.sh` / `dispatcher-tick.sh` untouched,
- bounding disk growth.

This is the **cheap tactical** mitigation. The strategic/durable fix (per-run artifact directory,
#235) is explicitly out of scope.

## Chosen strategy: single-generation rotation

On each dispatch, before creating the fresh `0600` log, **rotate** the existing log:

```
mv -f "${log}" "${log}.1"               # moves the path entry (does not follow a symlinked log
                                        # through to its target); overwrites any older .1
[[ -L "${log}.1" ]] || chmod 600 "${log}.1"   # force 0600 on the rotated generation, but skip if it's
                                        # a symlink — chmod follows symlinks (CWE-59 guard, mirrors
                                        # kill_stale_wrapper's PID-file symlink refusal)
install -m 600 /dev/null "${log}"       # fresh 0600 regular file for the new run
```

### Why rotate over run-header append

| | Rotate (chosen) | Run-header append |
|---|---|---|
| Prior run recoverable | yes, in `…-N.log.1` | yes, in same file |
| Disk bound | one extra generation, capped | grows unbounded across re-dispatches until INV-12/35 truncate |
| New-run log isolation | clean (fresh file per run) | interleaved; consumers that `tail`/grep the log must skip prior runs |
| INV-12 / INV-35 recovery interaction | unchanged — they still `: > log` the *current* file; the loop they guard against reads the current log, which a rotation leaves empty for the fresh run | the recovery truncate would have to also clear accumulated prior-run text, or risk the re-detection loop reading a stale `result` line from an earlier run |
| Test signature | sentinel ends up in `.log.1` (clear, single assertion) | sentinel stays inline; must parse run boundaries |

Rotation keeps each run's log a clean single-run file (the `is_session_completed` /
PTL detection in INV-12/INV-35 reads "the last `{"type":"result"}` object in the log" — a
single-run file makes that detection unambiguous, exactly as today). Append would risk leaving a
stale `result` line from a prior run in the same file that the terminal-state gate re-reads.

### Disk bound

Only `…-N.log` and `…-N.log.1` ever exist per (issue, type). `mv -f` overwrites the prior `.1`, so
re-dispatch number 3 discards run-1's log and keeps run-2 + run-3. Single generation is sufficient
for triage (you want the immediately-preceding crashed run) and matches the issue's "do not
accumulate `.log.1 .log.2 …`" requirement.

## INV-12 / INV-35 are NOT touched

The intentional recovery-truncates:
- `dispatcher-tick.sh:318` — INV-12 `prompt_too_long`: `: > "$_ptl_log"`
- `lib-dispatch.sh:809` — INV-35 `failed-substantive`: `: > "$_log_file"`

both truncate the **current** `…-issue-N.log` so the next tick's terminal-state gate
(`is_session_completed`) does not re-read a stale `result` line and loop forever. This change does
NOT modify those lines. Because rotation creates a fresh empty current-log per dispatch anyway, the
INV-12/INV-35 invariant ("the next tick sees an empty/missing current log") is preserved — they
simply remain the explicit fail-closed guards for the recovery branches that mint a fresh dev
session mid-cycle (where no new dispatch-local rotation has happened yet).

> The recovery-truncate clears `…-N.log` (the current run). It does **not** touch `…-N.log.1`, so
> even in the INV-12/INV-35 path the immediately-prior run's log survives in the rotated generation.

## New invariant

**INV-68**: a routine re-dispatch (`dev-new` / `dev-resume` / `review`) preserves the prior run's
per-issue log by rotating it to a single `…-N.log.1` generation (mode `0600`) before creating the
fresh `0600` current log; only the INV-12 / INV-35 recovery branches truncate the current log
deliberately.

## Files

- `skills/autonomous-dispatcher/scripts/dispatch-local.sh` — rotation in the log-prep block (both
  arms).
- `docs/pipeline/invariants.md` — new INV-68.
- `docs/pipeline/dispatcher-flow.md` — document the log-retention behavior; cross-reference
  INV-12/INV-35.
- `tests/unit/test-dispatch-local-log-retention.sh` — regression + perm + INV-12/35-preserved
  assertions.
- `docs/test-cases/redispatch-log-retention.md` — test case enumeration.
- `CLAUDE.local.md` (operator-only, gitignored) — update the "Append-mode; multiple dispatch
  attempts accumulate" note to match rotation.
