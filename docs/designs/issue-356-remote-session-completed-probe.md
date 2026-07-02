# Design: backend-aware `is_session_completed` for `EXECUTION_BACKEND=remote-aws-ssm` (issue #356)

## Problem

`is_session_completed()` (`lib-dispatch.sh`) reads the dev wrapper's per-issue log at a
LOCAL path: `/tmp/agent-${PROJECT_ID}-issue-${N}.log`. Under
`EXECUTION_BACKEND=remote-aws-ssm` the dispatcher tick runs on the controller host while
the wrapper (and its log) live on the execution host. The local `[ -r "$log_file" ]`
check always misses on the controller, so `is_session_completed` unconditionally returns
1 (not completed) for every remote-SSM project.

This silently disables three call sites, all of which assume `is_session_completed` is
authoritative:

1. **Step 4a.5** (`handle_pending_dev_pr_exists`'s same-HEAD branch, [INV-98]/#351) — the
   `completed` delegation to `handle_completed_session_routing` never fires, so the
   residual `stale-verdict:<sha>` park is taken on every same-HEAD tick, forever.
2. **Step 4b.5** (`dispatcher-tick.sh`'s INV-12 PTL gate) — a remote `prompt_too_long`
   session is never auto-recovered.
3. **Step 4b.5.1** entry via the no-PR path — same completed-session detection, same miss.

Step 5 (`list_stale_candidates`) cannot rescue the park either: it selects only
`in-progress`/`reviewing` issues; a parked issue sits in `pending-dev`, which Step 5
never scans (`lib-dispatch.sh:~177`).

Net effect: every remote-SSM project's dev↔review loop deadlocks in `pending-dev` after
the FIRST review FAIL — the #351 fix (delegate-from-4a.5) never activates because its own
gate (`is_session_completed`) is backend-blind.

## Precedent: INV-30's `pid_alive` backend seam

[INV-30] already solved the identical shape of problem for liveness: `pid_alive`
consults a backend-specific transport (`liveness-check-remote-aws-ssm.sh`, via
`_remote_pid_alive_query`) BEFORE any local probe when `EXECUTION_BACKEND != local`. This
issue mirrors that shape for terminal-state detection.

## Fix: `_session_log_probe` seam + remote SSM driver

### 1. Extract the log read into a backend seam

`_session_log_probe <issue_num>` — echoes the LAST `{"type":"result",...}` line from the
dev wrapper's log (or nothing). Two implementations, selected by `EXECUTION_BACKEND`
exactly like `pid_alive`:

- **local** (default): today's `[ -r "$log_file" ] && grep '^{"type":"result"' | tail -1`
  logic, byte-identical, moved verbatim into the seam function.
- **remote-aws-ssm**: `_remote_session_log_probe <issue_num>` runs the same
  `grep '^{"type":"result"' | tail -1` ON THE EXECUTION HOST via a new driver script,
  `session-log-probe-remote-aws-ssm.sh`, reusing `lib-ssm.sh::_ssm_run_remote_command`
  (the same send-command + bounded-poll helper `liveness-check-remote-aws-ssm.sh`
  already uses). On SSM error / timeout / no match: emit NOTHING (empty stdout) — never
  fabricate a result line. `is_session_completed` then sees an empty `last_line` and
  returns 1 (not completed) — the existing fail-closed residual park. This is the same
  conservative-bias shape as [INV-30], but inverted: [INV-30]'s indeterminate biases
  ALIVE (favors deferring a crash declaration); here indeterminate biases NOT-COMPLETED
  (favors the existing safe park over fabricating a routing decision on missing data).

`is_session_completed` is otherwise UNCHANGED: it still does the `jq -er` parse of
`stop_reason`/`terminal_reason` and the `end_ts_var` mtime derivation — those operate on
whatever the probe returned, backend-neutral. The end-ts mtime source under remote
backend is a NEW small wrinkle (see §3).

### 2. Remote-path project id

Per the existing remote-backend convention (`dispatcher.conf.example:~47`,
[`remote-backend.md`](../pipeline/remote-backend.md)), the wrapper's paths on the
execution host key on `SSM_REMOTE_PROJECT_ID`, which may differ from the controller's
`PROJECT_ID`. The remote driver takes `SSM_REMOTE_PROJECT_ID` (mirroring
`liveness-check-remote-aws-ssm.sh`'s own env contract), NOT `PROJECT_ID`.

### 3. End-timestamp under remote backend

Locally, `end_ts_var` is derived from the log file's mtime (`date -u -r "$log_file"`).
Under remote backend we cannot `stat` the file from the controller. The remote driver
additionally emits the log's mtime (as a `%Y` epoch, via `stat -c %Y` on the execution
host) on a second output line; `is_session_completed`'s remote branch converts that
epoch to ISO-8601 with `date -u -d "@$epoch"`. Fail-open: if the epoch line is
missing/unparseable, `end_ts_var` is left empty (same "no time filter" contract the local
path already documents for `date` failures).

### 4. Backend-aware truncate (mandatory in this PR)

Once remote sessions become detectable, the two existing truncate sites become
reachable for remote projects for the first time:

- `handle_completed_session_routing`'s failed-substantive branch (`lib-dispatch.sh`,
  Branch C): `: > "$_log_file"`.
- The tick's INV-12 PTL branch (`dispatcher-tick.sh`): `: > "$_ptl_log"`.

Both currently do a bare local truncate against `/tmp/agent-${PROJECT_ID}-issue-${N}.log`
— a CONTROLLER-side path. Under remote backend this creates/truncates the WRONG
(controller-local, likely nonexistent) file while the execution host's real log keeps
its stale terminal result line. The next tick's probe re-fetches the SAME stale line →
re-detects `completed`/`prompt_too_long` → dispatches ANOTHER dev-new — turning the
current deadlock into an infinite dev-new loop, which is strictly worse (burns retry
budget and spawns wrappers every tick instead of parking quietly).

Fix: extract a `_reset_session_log <issue_num>` seam with the same local/remote split as
the probe:
- **local**: `: > "$log_file"` (today's behavior, unchanged).
- **remote-aws-ssm**: issue a truncate command to the execution host via the SAME SSM
  driver (`session-log-probe-remote-aws-ssm.sh --truncate`), targeting the
  `SSM_REMOTE_PROJECT_ID`-keyed path.

Both call sites route their truncate through `_reset_session_log`; on failure (local
write error OR remote SSM error/timeout), both preserve their EXISTING fail-closed
behavior: skip dispatch, log an ERROR, post the existing operator notice, stay in
`pending-dev`. No behavior change to the failure path — only the success path gains a
working remote implementation.

### 5. `PROJECT_ID != SSM_REMOTE_PROJECT_ID`

All new code paths and their tests use `SSM_REMOTE_PROJECT_ID` for remote paths, never
`PROJECT_ID` (which stays the controller-side GitHub-API project id, used for comment
markers etc.). A dedicated fixture pins `PROJECT_ID != SSM_REMOTE_PROJECT_ID` to catch a
regression that accidentally uses the wrong id.

## Non-goals (Out of Scope, per the issue)

- Moving tick execution onto the wrapper host.
- Extending `is_session_completed` coverage to non-claude dev CLIs (pre-existing,
  documented per-CLI scope).
- Backfilling auto-recovery for issues already parked before this fix ships — the
  operator unparks those manually (see CLAUDE.local.md's unpark recipe); this fix
  prevents recurrence going forward.

## Cost

One SSM round-trip per parked-issue-with-PR per tick (Step 4a.5 only reaches the probe on
the same-HEAD branch) plus, newly, one SSM round-trip per truncate on the (rare)
same-HEAD-completed-substantive-failure / PTL paths. Not cached across ticks — the
existing `liveness-check-remote-aws-ssm.sh` precedent is also uncached per-tick, and the
per-tick issue count is small.

## Testing

See `docs/test-cases/issue-356-remote-session-completed-probe.md`.
