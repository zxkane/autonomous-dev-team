# Dispatcher Flow (per cron tick)

The dispatcher runs as a cron job (default every 5 minutes) and is **stateless across ticks**. Each tick reads the current label set on every `autonomous` issue, reads PID files for any wrappers it might be tracking, makes decisions, dispatches subprocesses, and updates labels. There is no in-memory carry-over from the previous tick.

The behavior described here is implemented by `skills/autonomous-dispatcher/scripts/dispatcher-tick.sh` (the per-project entry point) backed by `skills/autonomous-dispatcher/scripts/lib-dispatch.sh` (composable helpers — one function per gh/jq query). The dispatcher agent reads `SKILL.md` and runs `bash "$PROJECT_DIR/scripts/dispatcher-tick.sh"`; that script does everything described below in one process. Function names cited below (e.g. `count_active`, `check_deps_resolved`) are defined in `lib-dispatch.sh`.

## Multi-project outer loop (PR-8, #62)

For deployments that scan more than one repository per cron, `dispatcher-multi-tick.sh` wraps `dispatcher-tick.sh` in an outer iteration over a `PROJECTS=()` array declared in a separate `dispatcher.conf` file. Each iteration runs `dispatcher-tick.sh` in a subshell, so per-project state cannot leak between iterations.

Each `PROJECTS[]` entry is one of two shapes (PR-9, #62 axis 2):

- **Local project — file path**: a path to a per-project `autonomous.conf` on this dispatcher box. The wrapper sources it via the `AUTONOMOUS_CONF` priority-1 path. Used when the dispatcher and project source live on the same machine.
- **Remote project — inline metadata block**: a multi-line string of bash assignments (REPO, EXECUTION_BACKEND=remote-aws-ssm, SSM_INSTANCE_ID, SSM_REMOTE_PROJECT_DIR, etc.). Used when the project source lives on a remote dev EC2 — the dispatcher box does NOT have the project's `autonomous.conf`. The wrapper validates the block (KEY=VALUE lines only — defense-in-depth against accidental injection), eval's it in the subshell, and auto-derives `REPO_OWNER`/`REPO_NAME` from `REPO`.

The outer loop intentionally does NOT carry shared state (no global concurrency cap, no cross-project JUST_DISPATCHED). Each project's tick is independent — concurrency is enforced per-project against that project's `MAX_CONCURRENT`. Per-project failures are logged but do not abort sibling projects.

## Backend routing (PR-9, #62 axis 2)

`dispatcher-tick.sh` defines a `dispatch()` helper that routes wrapper-spawn requests by `EXECUTION_BACKEND`:

| Backend | Driver script | What happens |
|---|---|---|
| `local` (default) | `scripts/dispatch-local.sh` (in `$PROJECT_DIR/scripts/`) | Same as PR-8 single-machine flow: nohup-spawn the wrapper on this box. |
| `remote-aws-ssm` | `scripts/dispatch-remote-aws-ssm.sh` (in the skill scripts dir) | Build a `sudo -u $SSM_REMOTE_USER $SSM_REMOTE_SHELL -l -c '<inner>'` command, JSON-escape via `jq -n --arg cmd`, and `aws ssm send-command` to `$SSM_INSTANCE_ID`. The inner command runs `dispatch-local.sh` on the remote box. SSM is purely transport — PID/process management still belongs to `dispatch-local.sh` on whatever box runs it. |
| anything else | — | Logged as ERROR; that step skips the dispatch (issue stays in its current label state). Step 5b will re-evaluate next tick. |

The rest of this document describes the per-project tick in isolation; everything below applies whether `dispatcher-tick.sh` is invoked directly (single-project), by the multi-tick wrapper (one of N projects), and whether the dispatch goes via `local` or `remote-aws-ssm`.

### Caveat: remote backend + PID liveness

`lib-dispatch.sh::pid_alive` does `kill -0 $(cat $PID_FILE)` against `${XDG_RUNTIME_DIR}/autonomous-${PROJECT_ID}/issue-N.pid` ([INV-01]). For a remote project, the PID file is on the remote dev box, not on the dispatcher box. The dispatcher's `kill -0` always fails → all remote projects appear DEAD to the dispatcher.

Effects on Step 5:

- **Step 5a (ALIVE + PR ready) is unreachable for remote projects.** The proactive "SIGTERM-when-PR-ready" optimization doesn't fire; review delay grows from "next tick after CI passes" to "next tick after the wrapper exits naturally."
- **Step 5b DEAD-branch is the only path.** Each tick treats every active remote issue as DEAD and routes via the PR-state machine ([INV-04], [INV-06], [INV-07]). The wall-clock timeout in `lib-agent.sh::run_agent` ([INV-13], default 4h) bounds the worst case.

This is acceptable for this PR's surface area. A real remote-alive check (per-tick `aws ssm send-command kill -0 $PID`) would 2-3x the SSM call volume; not worth doing speculatively.

## Tick lifecycle

```mermaid
flowchart TD
    start([cron fires]) --> init[Initialize JUST_DISPATCHED empty]
    init --> step1{Step 1<br/>concurrency cap?}
    step1 -- ACTIVE >= MAX --> exit_cap([abort tick])
    step1 -- room available --> step2[Step 2 scan-new]
    step2 --> step3[Step 3 scan-pending-review]
    step3 --> step4[Step 4 scan-pending-dev]
    step4 --> step5[Step 5 stale detection]
    step5 --> done([end tick])

    step2 -. for each match .-> dispatch_dev[dispatch dev-new<br/>add in-progress label<br/>append JUST_DISPATCHED]
    step3 -. for each match .-> dispatch_review[dispatch review<br/>remove pending-review add reviewing<br/>append JUST_DISPATCHED]
    step4 -. retries OK .-> dispatch_resume[dispatch dev-resume<br/>remove pending-dev add in-progress<br/>append JUST_DISPATCHED]
    step4 -. retries exhausted .-> stall[remove pending-dev add stalled<br/>comment @owner]
```

`JUST_DISPATCHED` is the only piece of state the tick maintains in memory — and it dies when the tick ends.

## Step 1: concurrency gate

Implementation: `lib-dispatch.sh::count_active`.

```
ACTIVE = count of issues labeled autonomous AND (in-progress OR reviewing)
if ACTIVE >= MAX_CONCURRENT: abort tick
```

`MAX_CONCURRENT` defaults to 5. Counts both kinds of active wrappers because both consume Opus / Sonnet quota and local PID slots.

If the cap is hit, the tick aborts entirely — no Step 2/3/4/5. This is intentional: dispatching new work while at the cap would just produce wrappers that immediately collide with `acquire_pid_guard` or starve on quota.

## Step 2: scan-new

Implementation: `lib-dispatch.sh::list_new_issues`, `check_deps_resolved`, `label_swap`.

Find issues labeled `autonomous` with **no other active state label** (no `in-progress`, `pending-review`, `reviewing`, `pending-dev`, `stalled`, `approved`).

For each match, in order:

1. **Dependency check.** Read the issue body for a `## Dependencies` section. Extract every `#N` reference. For each, call `gh issue view N --json state` and require state `CLOSED` or `MERGED` ([INV-11](invariants.md#inv-11-dependency-state-includes-merged) — PRs report `MERGED`, not `CLOSED`). If any dependency is still open, **skip silently** — no comment, no label change. The issue picks up next tick once dependencies clear.
2. **Add `in-progress` label.**
3. **Comment**: "Dispatching autonomous development..."
4. **Dispatch**: `bash $PROJECT_DIR/scripts/dispatch-local.sh dev-new <issue>`
5. **Append issue to `JUST_DISPATCHED`.**
6. **Re-check concurrency** before processing the next match.

The issue is now in `in-progress`; the dev wrapper is launching via `nohup`. Step 5 must skip this issue this tick ([INV-09](invariants.md#inv-09-just_dispatched-skip-rule)).

## Step 3: scan-pending-review

Implementation: `lib-dispatch.sh::list_pending_review`, `label_swap`.

Find issues labeled `autonomous` AND `pending-review` AND NOT `reviewing`.

For each match, in order:

1. **Atomic label swap**: `gh issue edit --remove-label pending-review --add-label reviewing` in a single call. (Two separate `gh issue edit` calls would create a `pending-review` + `reviewing` window — see [Forbidden transitions](state-machine.md#forbidden-transitions).)
2. **Comment**: "Dispatching autonomous review..."
3. **Dispatch**: `bash $PROJECT_DIR/scripts/dispatch-local.sh review <issue>`
4. **Append to `JUST_DISPATCHED`.**

## Step 4: scan-pending-dev

Implementation: `lib-dispatch.sh::list_pending_dev`, `count_retries`, `mark_stalled`, `extract_dev_session_id`, `label_swap`.

Find issues labeled `autonomous` AND `pending-dev`.

For each match, in order:

### Step 4a: retry counter check

This is the most subtle gate in the dispatcher. Two failure events count toward the retry budget, **but only if they occurred after the most recent `Marking as stalled` comment**. This makes "remove the `stalled` label" a reset (a maintainer's gesture of "try again") instead of a cumulative-retry bomb. See [INV-05](invariants.md#inv-05-retry-counter-cutoff-rule).

Failure events:

- **`Agent Session Report (Dev)` comments with non-zero exit code.** Posted by the dev wrapper trap on agent failure ([INV-03](invariants.md#inv-03-dev-session-report-comment-format)).
- **Dispatcher-detected crash comments matching the regex `Task appears to have crashed \(no PR found\)|process not found`.** This regex anchors only on Step 5b-DEAD-no-PR comments and explicit "process not found" wording. It MUST NOT match the forward-progress phrases — see [INV-06](invariants.md#inv-06-crashed--process-not-found-keyword-contract).

Pseudocode:

```
LAST_STALLED_AT = timestamp of last comment matching "Marking as stalled" (else epoch)
AGENT_FAILURES = count of Dev Session Reports with non-zero exit AFTER LAST_STALLED_AT
DISPATCHER_CRASHES = count of comments matching the crash regex AFTER LAST_STALLED_AT
RETRY_COUNT = AGENT_FAILURES + DISPATCHER_CRASHES

if RETRY_COUNT >= MAX_RETRIES (default 3):
  remove pending-dev, add stalled
  comment "Marking as stalled. @owner please investigate manually."
  skip
```

### Step 4b: extract session-id

Find the most recent comment matching `Dev Session ID: \`<id>\`` (note: `Review Session ID: ...` is a separate trailer and MUST NOT match — they share the word "Session" so the regex anchors on `Dev Session ID:` specifically, see [INV-03](invariants.md#inv-03-dev-session-report-comment-format)).

If no session-id can be extracted, the resume cannot proceed. Today, the dispatcher dispatches a new dev session anyway (the wrapper's `--mode resume` path falls back to `--mode new` when `SESSION_ID` is empty — see [`dev-agent-flow.md`](dev-agent-flow.md#mode-normalization)).

### Step 4b.5: terminal-state gate (PR-6, [INV-12](invariants.md#inv-12-resume-only-against-unfinished-sessions))

Before dispatching a resume, call `is_session_completed <issue>` (in `lib-dispatch.sh`). The helper inspects the agent log at `/tmp/agent-${PROJECT_ID}-issue-<N>.log`, finds the last `{"type":"result", ...}` JSON object, and returns 0 if `stop_reason=end_turn` AND `terminal_reason=completed`.

If the gate fires:

1. Post a comment naming the session-id and inviting an operator to manually flip to `pending-review` (PR exists) or close the issue (work done).
2. Append the issue to `JUST_DISPATCHED` so Step 5 doesn't reprobe it on the same tick.
3. **Do not** transition the label automatically. The issue stays in `pending-dev`. Silent recovery would mask other failure modes — surface the symptom and let a human decide.

This is a conservative gate: it only fires when the helper is certain the prior session ended cleanly. False negatives (claiming "not completed" when it was) just keep the prior behavior — Step 4c attempts the resume, and the wall-clock timeout from [INV-13](invariants.md#inv-13-wall-clock-cap-on-agent-invocations) bounds the damage to `AGENT_TIMEOUT` (default `4h`).

### Step 4c: dispatch resume

1. **Atomic label swap**: `gh issue edit --remove-label pending-dev --add-label in-progress`.
2. **Comment**: "Resuming development (session: <id>)..."
3. **Dispatch**: `bash $PROJECT_DIR/scripts/dispatch-local.sh dev-resume <issue> <session-id>`
4. **Append to `JUST_DISPATCHED`.**

## Step 5: stale detection

Implementation: `lib-dispatch.sh::list_stale_candidates`, `was_just_dispatched`, `pid_alive`, `get_pid`, `fetch_pr_for_issue`, `ci_is_green`, `pr_idle_seconds`, `last_reviewed_head`, `label_swap`.

Find issues labeled `in-progress` OR `reviewing`.

For each match:

1. **Skip if in `JUST_DISPATCHED`** ([INV-09](invariants.md#inv-09-just_dispatched-skip-rule)).
2. **Locate PID file** ([INV-01](invariants.md#inv-01-pid-file-naming)):
   - `in-progress` → `${PID_DIR}/issue-<N>.pid`
   - `reviewing` → `${PID_DIR}/review-<N>.pid`
   - `${PID_DIR}` is computed by `lib-config.sh::pid_dir_for_project` (per-user runtime dir, mode 0700).
3. **Liveness probe**: `kill -0 $(cat <pid-file>)`. PID file is also re-checked for the symlink-attack defense ([INV-02](invariants.md#inv-02-pid-file-is-not-a-symlink)).
4. Branch on liveness:
   - **ALIVE + `in-progress`** → Step 5a (below). Reviewers in `reviewing` are not subject to the 5a SIGTERM logic — review wrappers are bounded by their own internal polling.
   - **DEAD + `in-progress`** → Step 5b in-progress branch.
   - **DEAD + `reviewing`** → Step 5b reviewing branch.

### Step 5a: ALIVE in-progress + PR ready for review (#54, #56)

The dev wrapper might have finished its real work — pushed a passing CI build — and then hung in some auxiliary code (polling loop, stuck stdio). Without intervention the issue stays `in-progress` forever and no review fires.

All these gates must hold before sending SIGTERM (any one failing → leave alone):

| Gate | What | If false |
|---|---|---|
| **PR exists** | `gh pr list` finds an open PR whose body references `#N` | Agent still developing; leave alone. |
| **CI green** | `gh pr checks <pr>` returns ≥1 check, all `SUCCESS` | CI pending or failed; agent still working. |
| **Idle** | `now - PR.updatedAt > 300s` (strict `-gt`, [INV-10](invariants.md#inv-10-5-minute-idle-gate-before-sigterm)) | Recent activity; agent may be cleaning up. |
| **PID still alive on recheck** | `kill -0 $PID` after the prior gates | Wrapper exited between the original probe and the SIGTERM decision; defer to next tick which will hit Step 5b DEAD. |

When all gates hold:

1. `kill $PID` (SIGTERM, NOT SIGKILL — wrapper trap needs to clean up).
2. Comment: "Dev process still alive but PR #N is ready (all CI checks passed, idle Ns). Sent SIGTERM to PID. Moving to pending-review."
3. `gh issue edit --remove-label in-progress --add-label pending-review`.

**Convergence with the wrapper trap** ([INV-15](invariants.md#inv-15-step-5a-sigterm-race-is-non-deterministic)) — fixed in PR-6: the dev wrapper installs `trap on_sigterm TERM` that sets `RECEIVED_SIGTERM=1` and forwards SIGTERM to descendants. Its `cleanup()` rewrites `exit_code 143 → 0` when a PR exists, so the wrapper's own label edit also targets `+pending-review`. Both writers now agree on the target; the dispatcher's edit here is belt-and-suspenders against SIGKILL escalation (where the trap may not fire at all). See [`state-machine.md` § Wrapper trap vs. dispatcher Step 5](state-machine.md#wrapper-trap-vs-dispatcher-step-5).

#### Robustness against malformed responses

The Step 5a code does fail-closed on malformed inputs, by design:

- `gh pr list` returns malformed JSON or empty → log WARN, leave issue alone.
- `gh pr checks` errors (token expiry, transport) → treat as "CI not green" (since we cannot prove it green). Captures stderr to a `mktemp` file (not a fixed `/tmp` path — concurrent dispatcher instances would collide; CWE-377).
- `date -d` (GNU) and `date -j -f` (BSD/macOS) both fail → log WARN, leave alone (otherwise `IDLE_SECONDS = NOW - 0` would always exceed 300s and unconditionally fire SIGTERM).

### Step 5b: DEAD branches

The wrapper has exited; its own trap has already (or attempted to) update labels. The dispatcher reads the post-trap state and reconciles.

#### DEAD + `in-progress`

Look for a PR linked to the issue (same query Step 5a uses):

- **PR found, current `headRefOid` differs from last `Reviewed HEAD: \`<sha>\`` trailer** ([INV-04](invariants.md#inv-04-reviewed-head-trailer-format))
  → comment "Dev process exited (PR found). Moving to pending-review for assessment.", `−in-progress +pending-review`.
- **PR found, current SHA = last reviewed SHA**
  → comment "Dev process exited (no new commits since last review at \`<sha>\`). Moving to pending-dev for retry.", `−in-progress +pending-dev`.
- **PR found, no prior trailer** (empty `LAST_REVIEWED_HEAD`) → routes to `pending-review`. Two distinct causes converge here ([INV-07](invariants.md#inv-07-empty-reviewed-head-trailer-routes-to-pending-review)):
  - Review never ran successfully against this PR yet (the safe first-review case).
  - Trailer post failed (token expiry, 403, rate limit). Operator sees `WARNING: Failed to post Reviewed HEAD trailer` in the review log; cycling pending-review without new commits is the symptom.
- **No PR found** → comment "Task appears to have crashed (no PR found). Moving to pending-dev for retry.", `−in-progress +pending-dev`.

The wording in the "PR found" branches deliberately avoids the keywords `crashed` and `process not found` so the Step 4a retry-counter regex does not count these as failures ([INV-06](invariants.md#inv-06-crashed--process-not-found-keyword-contract)).

#### DEAD + `reviewing`

Comment: "Review process appears to have crashed. Moving to pending-dev for retry."
Labels: `−reviewing +pending-dev`.

(No SHA-comparison shortcut here — the review wrapper's own trap should have already done this transition for genuine crashes; this 5b branch is the safety net for the case where the wrapper died so abruptly that even its trap didn't fire.)

## Failure modes by step

| Failure | Where | Behavior |
|---|---|---|
| GH App token expired mid-tick | any step | gh calls fail loudly. Tick aborts; next cron retries. Mitigated by `gh-token-refresh-daemon` for the wrappers (dispatcher's own token is generated at tick start). |
| jq returns `null` for malformed PR JSON | Step 5a | Validated before use (`PR_NUM =~ ^[0-9]+$ && PR_UPDATED_AT non-empty`). On failure: WARN, leave issue alone. |
| `date` parse fails on PR.updatedAt | Step 5a | WARN, leave alone (fail-closed — see above). |
| Concurrent dispatcher instance | tick-tick | `mktemp` for CI-error capture file (CWE-377 mitigation). Concurrent ticks otherwise serialize on `gh issue edit` — the second one's edits race but converge. |
| `JUST_DISPATCHED` not maintained | Step 5 | Step 5 evaluates a freshly-dispatched issue, sees no PID file yet, diagnoses DEAD-no-PR, increments crash counter, eventually marks stalled. **This was the root of #34, #41 — the array exists specifically to prevent this.** |
| Resume against a completed session | Step 4b.5 | PR-6 added `is_session_completed` ([INV-12](invariants.md#inv-12-resume-only-against-unfinished-sessions)). Step 4b.5 inspects the agent log; if the prior turn ended with `stop_reason=end_turn` AND `terminal_reason=completed`, the dispatcher posts an explanatory comment and skips the resume — leaving the issue in `pending-dev` for an operator to flip manually. The wall-clock timeout ([INV-13](invariants.md#inv-13-wall-clock-cap-on-agent-invocations)) is the safety net for false negatives. |
| Agent invocation hangs in CLI | wrapper, not dispatcher | Bounded by future wall-clock timeout ([#60](https://github.com/zxkane/autonomous-dev-team/issues/60), [INV-13](invariants.md#inv-13-wall-clock-cap-on-agent-invocations)). Until then the dispatcher's Step 5a is the only way to clear it. |

## Cross-references

- [`state-machine.md`](state-machine.md) — the label transitions each step performs.
- [`dev-agent-flow.md`](dev-agent-flow.md), [`review-agent-flow.md`](review-agent-flow.md) — what the dispatched wrapper does next.
- [`handoffs.md`](handoffs.md) — Step 5 is the most race-prone handoff.
- [`invariants.md`](invariants.md) — INV-01 through INV-11 are all referenced from this file.
