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

## Pre-step: wrapper exec-bit self-heal (closes #97)

Before sourcing config, `dispatcher-tick.sh` self-heals the execute bit on the two scripts that `dispatch-local.sh` invokes directly via `nohup`:

- `autonomous-dev.sh`
- `autonomous-review.sh`

Some installs strip `+x` (a 644-mode upstream commit, the skills CLI's content-only hashing, or a consumer-side `git clone` under a restrictive umask). Without `+x`, the wrapper exits before the agent starts, no Session Report is posted, and Step 5b counts the issue as a crash.

The self-heal is **scoped narrowly** — only the two directly-executed scripts. Sourced-only siblings (`lib-*.sh`) are deliberately not touched; flipping their mode would propagate the wrong contract.

Defense in depth: the same heal also runs in every `install-*-hooks.sh` via `lib-installer.sh::ensure_dispatcher_scripts_executable`, so consumers re-running the installer get the heal even if their installed skill version still has the broken mode (the skills CLI's `computedHash` is content-only, not mode-aware).

## Pre-step: GitHub authentication (closes #91)

`dispatcher-tick.sh` resolves auth before any `gh` call so the dispatcher's
issue comments and label changes appear under the configured identity.

Behavior:

| `GH_AUTH_MODE` | Setup | Token source for `gh` |
|---|---|---|
| `app` | sources `gh-app-token.sh::get_gh_app_token`, exports `GH_TOKEN` | Installation token scoped to one repo, valid 1h. A single token covers the whole tick (typically <1 min) — no refresh daemon. |
| `token` (default) | none | `GH_TOKEN` env or `gh auth login` token |

Required when `GH_AUTH_MODE=app`: `DISPATCHER_APP_ID`, `DISPATCHER_APP_PEM`,
`REPO`, `REPO_OWNER`. `REPO_NAME` is auto-derived from `REPO` if unset (older
path-entry confs sometimes omit it).

Failure modes — all exit 1 with `FATAL`, before any `gh` call:

- Missing `DISPATCHER_APP_ID` or `DISPATCHER_APP_PEM` while `GH_AUTH_MODE=app`.
- `get_gh_app_token` returns non-zero (network / API error / bad PEM / app not
  installed for repo).
- Token returned is empty.

There is no silent fallback to user auth — silently impersonating the
operator was the bug closed by #91.

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
3. **Post dispatch token** ([INV-18](invariants.md#inv-18-cold-start-grace-period-before-stale-detection)): write `<!-- dispatcher-token: <id> at <iso> mode=dev-new -->` followed by the human-readable "Dispatching autonomous development..." line. The HTML comment encodes the dispatch timestamp for Step 5's grace-period check.
4. **Dispatch**: `bash $PROJECT_DIR/scripts/dispatch-local.sh dev-new <issue>`
5. **Append issue to `JUST_DISPATCHED`.**
6. **Re-check concurrency** before processing the next match.

The issue is now in `in-progress`; the dev wrapper is launching via `nohup`. Step 5 must skip this issue this tick ([INV-09](invariants.md#inv-09-just_dispatched-skip-rule)) and for the duration of the dispatch-token grace period ([INV-18](invariants.md#inv-18-cold-start-grace-period-before-stale-detection)).

## Step 3: scan-pending-review

Implementation: `lib-dispatch.sh::list_pending_review`, `label_swap`.

Find issues labeled `autonomous` AND `pending-review` AND NOT `reviewing`.

For each match, in order:

1. **Atomic label swap**: `gh issue edit --remove-label pending-review --add-label reviewing` in a single call. (Two separate `gh issue edit` calls would create a `pending-review` + `reviewing` window — see [Forbidden transitions](state-machine.md#forbidden-transitions).)
2. **Post dispatch token** ([INV-18](invariants.md#inv-18-cold-start-grace-period-before-stale-detection)): `<!-- dispatcher-token: <id> at <iso> mode=review -->` + "Dispatching autonomous review...".
3. **Dispatch**: `bash $PROJECT_DIR/scripts/dispatch-local.sh review <issue>`
4. **Append to `JUST_DISPATCHED`.**

## Step 4: scan-pending-dev

Implementation: `lib-dispatch.sh::list_pending_dev`, `count_retries`, `mark_stalled`, `extract_dev_session_id`, `label_swap`.

Find issues labeled `autonomous` AND `pending-dev`.

For each match, in order:

### Step 4a: retry counter check

This is the most subtle gate in the dispatcher. Two failure events count toward the retry budget, **but only if they occurred after the most recent `Marking as stalled` comment**. This makes "remove the `stalled` label" a reset (a maintainer's gesture of "try again") instead of a cumulative-retry bomb. See [INV-05](invariants.md#inv-05-retry-counter-cutoff-rule).

Failure events:

- **`Agent Session Report (Dev)` comments with non-zero exit code.** Posted by the dev wrapper trap on agent failure ([INV-03](invariants.md#inv-03-dev-session-report-comment-format)). Always count.
- **Dispatcher-detected crash comments matching the regex `Task appears to have crashed \(no PR found\)|process not found`.** This regex anchors only on Step 5b-DEAD-no-PR comments and explicit "process not found" wording. It MUST NOT match the forward-progress phrases — see [INV-06](invariants.md#inv-06-crashed--process-not-found-keyword-contract). **Only counts when the agent has confirmed startup** in this retry cycle (a `Dev Session ID:` comment exists post-cutoff) — see [INV-19](invariants.md#inv-19-retry-counter-requires-confirmed-agent-startup).

Pseudocode:

```
LAST_STALLED_AT = timestamp of last comment matching "Marking as stalled" (else epoch)
AGENT_FAILURES = count of Dev Session Reports with non-zero exit AFTER LAST_STALLED_AT
DISPATCHER_CRASHES = count of comments matching the crash regex AFTER LAST_STALLED_AT
SESSION_SEEN = count of "Dev Session ID: ..." comments AFTER LAST_STALLED_AT (INV-19)
RETRY_COUNT = AGENT_FAILURES + (SESSION_SEEN > 0 ? DISPATCHER_CRASHES : 0)

if RETRY_COUNT >= MAX_RETRIES (default 3):
  remove pending-dev, add stalled
  comment "Marking as stalled. <counter breakdown including suppressed false positives> @owner please investigate manually."
  skip
```

### Step 4a.5: PR-exists short-circuit (#99 Bug 3, #106)

Before extracting the session-id and dispatching a resume, the helper `handle_pending_dev_pr_exists` (in `lib-dispatch.sh`) checks `fetch_pr_for_issue` for a PR referencing this issue. If a PR is already open, the agent had finished publishing — any subsequent crash that landed it in `pending-dev` (e.g. cleanup-trap fired with non-zero exit after `gh pr create` succeeded) does not warrant re-developing.

The helper consults `last_reviewed_head` to distinguish "first review (or new commits)" from "stale verdict on unchanged HEAD" (#106):

| State | Action |
|---|---|
| PR exists, `current_head == last_reviewed_head` (FAILED verdict against unchanged HEAD) | Post idempotent `stale-verdict:<sha>` notice (fail-closed via `grep -q '^0$'`), keep `pending-dev`, append to `JUST_DISPATCHED`. |
| PR exists, `current_head != last_reviewed_head` (new commits to assess) | Post Bug 3 transition comment, `label_swap pending-dev → pending-review`, append to `JUST_DISPATCHED`. |
| PR exists, no prior `Reviewed HEAD:` trailer (first review) | Same as the new-commits branch. |
| Empty `current_head` from PR JSON (schema drift / partial response) | Defensive: treat as new-commits branch, transition to `pending-review`. |
| No PR | Helper returns 1; caller falls through to session-id extraction (Step 4b). |

This is the Step 4 mirror of Step 5b's "DEAD + in-progress + PR exists" branch — it covers the case where the cleanup trap got there first and the issue is already on `pending-dev` when the next tick arrives. The `last_reviewed_head` check prevents the prior-review-FAILED-on-unchanged-HEAD loop where every tick would otherwise re-dispatch review against identical code.

### Step 4b: extract session-id

Find the most recent comment matching `Dev Session ID: \`<id>\`` (note: `Review Session ID: ...` is a separate trailer and MUST NOT match — they share the word "Session" so the regex anchors on `Dev Session ID:` specifically, see [INV-03](invariants.md#inv-03-dev-session-report-comment-format)).

If no session-id can be extracted, the resume cannot proceed at the wrapper level — but the wrapper's `--mode resume` path falls back to `--mode new` when `SESSION_ID` is empty (see [`dev-agent-flow.md`](dev-agent-flow.md#mode-normalization)). Both transport drivers (`dispatch-local.sh` and `dispatch-remote-aws-ssm.sh`) tolerate empty `SESSION_ID` in the `dev-resume` branch and forward the call without `--session`, so the wrapper-side fallback is reachable for first-time `pending-dev` pickup (#107). Prior to this fix, both drivers rejected empty session with `exit 1`, leaving the issue stuck in `in-progress` until Step 5 stale-detection swapped it back one tick later.

### Step 4b.5: terminal-state gate ([INV-12](invariants.md#inv-12-resume-only-against-unfinished-sessions))

Before dispatching a resume, call `is_session_completed <issue> _reason` (in `lib-dispatch.sh`). The helper inspects the agent log at `/tmp/agent-${PROJECT_ID}-issue-<N>.log`, finds the last `{"type":"result", ...}` JSON object, and returns 0 in two cases. The optional second arg captures `terminal_reason` so the caller can branch on which case fired:

| `terminal_reason` | Meaning | Dispatcher action |
|---|---|---|
| `completed` | Normal end-of-turn (`stop_reason=end_turn` too). Resuming would attach to a closed SSE stream and hang. | Operator handoff: post `INV-12-completed:<sid>` notice, leave issue in `pending-dev`, do not auto-recover. |
| `prompt_too_long` | JSONL transcript exceeded the model's input window. Headless `claude -p` has no auto-compaction, so resuming re-feeds the whole transcript and crashes again. | Auto-recover: post `INV-12-prompt-too-long:<sid>` notice, **truncate the per-issue log**, `label_swap pending-dev → in-progress`, `post_dispatch_token dev-new`, `dispatch dev-new`. The next tick mints a fresh session id with a smaller seed prompt that re-derives state from git/issue/PR. |

The PTL branch hard-fails if the log truncate fails (perm drift, ENOSPC): post an operator-actionable comment and `continue` without dispatching. Without this guard, the next tick would re-read the same stale PTL log, the idempotency-marker check would suppress a fresh notice (it's keyed on the old session_id), and the dispatcher would silently dispatch dev-new every tick forever.

This is a conservative gate: it only fires when the helper is certain the prior session reached one of the two terminal states. False negatives (claiming "not terminal" when it was) just keep the prior behavior — Step 4c attempts the resume, and the wall-clock timeout from [INV-13](invariants.md#inv-13-wall-clock-cap-on-agent-invocations) bounds the damage to `AGENT_TIMEOUT` (default `4h`).

### Step 4c: dispatch resume

1. **Atomic label swap**: `gh issue edit --remove-label pending-dev --add-label in-progress`.
2. **Post dispatch token** ([INV-18](invariants.md#inv-18-cold-start-grace-period-before-stale-detection)): `<!-- dispatcher-token: <id> at <iso> mode=dev-resume -->` + "Resuming autonomous development...".
3. **Dispatch**: `bash $PROJECT_DIR/scripts/dispatch-local.sh dev-resume <issue> <session-id>`
4. **Append to `JUST_DISPATCHED`.**

## Step 5: stale detection

Implementation: `lib-dispatch.sh::list_stale_candidates`, `was_just_dispatched`, `pid_alive`, `get_pid`, `fetch_pr_for_issue`, `ci_is_green`, `pr_idle_seconds`, `last_reviewed_head`, `label_swap`.

Find issues labeled `in-progress` OR `reviewing` **and not also `approved`**. The `approved` exclusion is critical: an issue in the `approved` terminal state that still carries a transitional label (residue from a wrapper crash between two label edits, or from the [INV-15](invariants.md#inv-15-step-5a-sigterm-race-is-non-deterministic) SIGTERM race) must not be treated as stale. Without the exclusion, Step 5 would swap the active label to `pending-dev`, which re-arms Step 4 on the next tick — an infinite loop burning tokens on a terminally-decided issue (issue #115 Bug A).

For each match:

1. **Skip if in `JUST_DISPATCHED`** ([INV-09](invariants.md#inv-09-just_dispatched-skip-rule)).
2. **Skip if within cold-start grace period** ([INV-18](invariants.md#inv-18-cold-start-grace-period-before-stale-detection)) — `is_within_grace_period` reads the most recent `<!-- dispatcher-token: ... -->` marker comment. While its age is below `DISPATCH_GRACE_PERIOD_SECONDS` (default 600 = 10 min), defer all stale-detection branching to a future tick. JUST_DISPATCHED only protects the current tick; this rule extends protection across the cold-start window during which the wrapper has not yet written its PID file. (Empirical wrapper startup is 1–7 sec; 10 min leaves headroom for slow MCP / remote SSM paths.)
3. **Locate PID file** ([INV-01](invariants.md#inv-01-pid-file-naming)):
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

Before posting "crashed" or swapping labels, the dispatcher consults `review_near_success` ([INV-24](invariants.md#inv-24-review-wrapper-dead-detection-requires-both-pid_alive-miss-and-no-near-success-pr-signal)). If ANY of the four PR-state signals (recent merge, recent APPROVED review, recent verdict comment, defensive `kill -0` re-check) is positive within `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS` (default 300s), the branch logs and short-circuits — the wrapper has either already finished successfully or is in its post-verdict / merge tail.

Only when ALL four signals are negative does the crash path fire:

Comment: "Review process appears to have crashed. Moving to pending-dev for retry."
Labels: `−reviewing +pending-dev`.

This branch is the safety net for the case where the wrapper died so abruptly that even its trap didn't fire. The `pid_alive` check that gates entry to this branch ALSO honors a heartbeat-based mtime fallback ([INV-24](invariants.md#inv-24-review-wrapper-dead-detection-requires-both-pid_alive-miss-and-no-near-success-pr-signal)): a fresh PID-file mtime (within `HEARTBEAT_INTERVAL_SECONDS * 3`) keeps the wrapper in the ALIVE bucket, eliminating false alarms from transient races.

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
