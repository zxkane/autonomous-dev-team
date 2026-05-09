# Cross-cutting Invariants

Rules that span the dispatcher / dev / review boundaries. When a bug fix discovers a new invariant, add it here under a new `INV-NN` ID and reference it from the relevant flow doc.

Each invariant has the same shape:

- **Rule** (one sentence)
- **Why** — the historical bug this exists to prevent
- **Producer** — which actor must uphold it
- **Consumer** — which actor relies on it
- **Test** — where it's verified, or "TODO: add test"

Some invariants below describe behavior the **code does not yet enforce** — they are explicitly marked with `Status: NOT YET ENFORCED` or `Status: DOCUMENTED, NOT YET FIXED`. PR-4 enforced INV-11, INV-14, and INV-16. PR-6 enforced INV-12, INV-13, and INV-15.

---

## INV-01: PID file naming

**Rule**: Wrappers write their PID to `${PID_DIR}/issue-<N>.pid` (dev wrapper) or `${PID_DIR}/review-<N>.pid` (review wrapper), where `${PID_DIR}` is the per-user runtime directory returned by `lib-config.sh::pid_dir_for_project`.

`PID_DIR` resolution priority:

1. `${AUTONOMOUS_PID_DIR}` — env override (used by tests).
2. `${XDG_RUNTIME_DIR}/autonomous-${PROJECT_ID}` — canonical Linux per-user runtime, mode 0700 by spec.
3. `${HOME}/.local/state/autonomous-${PROJECT_ID}` — fallback when `XDG_RUNTIME_DIR` is unset.

The helper `mkdir -p`s the directory and `chmod 700`s it on first call.

**Why**: The dispatcher's Step 5 stale-detection relies on knowing exactly where to look for a wrapper's liveness. Different basenames (`issue-N` vs `review-N`) let the dispatcher distinguish ALIVE-in-progress (eligible for Step 5a) from ALIVE-reviewing (not eligible). PR-7 moved these out of the predictable `/tmp/agent-${PROJECT_ID}-{issue,review}-N.pid` paths because predictable `/tmp` paths are CWE-377 (Insecure Temporary File): a local attacker who can guess `PROJECT_ID` and issue numbers could DoS the pipeline by planting symlinks faster than wrappers can spawn (#72). The per-user dir's 0700 mode makes the predictability harmless — no other local user can plant in there.

**Producer**: `acquire_pid_guard` in `lib-agent.sh`, called from `autonomous-dev.sh` and `autonomous-review.sh`. The PID file path is computed at the call site by combining `pid_dir_for_project` output with `issue-<N>.pid` / `review-<N>.pid`.
**Consumer**: dispatcher Step 5a / 5b (`lib-dispatch.sh::pid_alive`, `get_pid` — both use the same helper), `dispatch-local.sh::kill_stale_wrapper`.
**Status**: **ENFORCED** in PR-7 (closes #72).
**Test**: `tests/unit/test-pid-dir-helper.sh` (13 cases) covers the helper. `tests/unit/test-kill-before-spawn.sh` covers the call sites.

## INV-02: PID file is not a symlink

**Rule**: Both `acquire_pid_guard` (in `lib-agent.sh`) and `kill_stale_wrapper` (in `dispatch-local.sh`) MUST refuse to operate on a PID file that is a symlink, and exit 1 immediately on detection.

**Why**: CWE-59 (Link Following). Originally the primary defense for the predictable `/tmp` PID paths; with [INV-01]'s per-user PID dir (PR-7, mode 0700), this becomes belt-and-suspenders rather than the only line of defense. The defense costs ~3 lines of bash and remains valuable: `pid_dir_for_project` itself refuses a symlinked dir, and the per-PID-file check catches edge cases where the user's own ~/.local/state/autonomous-${PROJECT_ID} is somehow tampered with.

**Producer**: `acquire_pid_guard`, `kill_stale_wrapper`, plus `pid_dir_for_project` (which refuses to use a symlinked parent dir — same defense one level up).
**Consumer**: itself (the check is a precondition, not a consumed value).
**Test**: `tests/unit/test-kill-before-spawn.sh` TC-DKBS-006, `tests/unit/test-pid-dir-helper.sh` TC-PD-005.

## INV-03: Dev session report comment format

**Rule**: The dev wrapper's exit trap MUST post an issue comment matching this format:

```
**Agent Session Report (Dev)**
- Dev Session ID: `<uuid>`
- Exit code: <int>
- Mode: new|resume
- Timestamp: <ISO-8601>
- Log: `/tmp/agent-${PROJECT_ID}-issue-<N>.log`
```

**Why**: Two consumers depend on parsing it. (a) The dispatcher's Step 4b session-id extraction anchors on `Dev Session ID:` (not just `Session ID:`) to avoid matching `Review Session:` trailers from the review wrapper. (b) The dispatcher's Step 4a retry counter counts comments matching both `Agent Session Report \(Dev\)` and `Exit code: 0` → not (i.e. non-zero exit).

**Producer**: `autonomous-dev.sh::cleanup` trap.
**Consumer**: dispatcher Step 4 (both 4a and 4b).
**Test**: TODO: add test that the format hasn't drifted (`tests/unit/test-session-report-format.sh`).

## INV-04: Reviewed-HEAD trailer format

**Rule**: The review wrapper, after a verdict comment is found, posts a separate issue comment matching this format:

```
Reviewed HEAD: `<sha>` (issue #<N>, session `<id>`)
```

`<sha>` is the PR's `headRefOid` at prompt-build time. The trailer is a separate comment from the verdict (different gh issue comment call) so polling failures on the verdict don't suppress the trailer and vice versa.

**Why**: The dispatcher's Step 5b uses the trailer to skip redundant reviews when a dev wrapper exits with no new commits since the last review (#53). Without the trailer, every dev exit with a PR would cycle back through review even if the dev did nothing new.

**Producer**: `autonomous-review.sh` (after verdict polling, before exit).
**Consumer**: dispatcher Step 5b DEAD-with-PR branch (regex: `Reviewed HEAD: \`(?<sha>[0-9a-f]{7,40})\``).
**Test**: TODO: add test (`tests/unit/test-reviewed-head-trailer-format.sh`).

## INV-05: Retry counter cutoff rule

**Rule**: The dispatcher's Step 4a retry counter MUST count failure events (Agent Session Report dev failures + dispatcher-crash comments) ONLY if their `createdAt` is **after** the most recent `Marking as stalled` comment on the issue.

**Why**: Without this, removing the `stalled` label to re-arm the pipeline would leave the historical retry counter intact — the issue would re-stall on the very next failure. With the cutoff, removing `stalled` is a clean reset (#41).

The cutoff timestamp falls back to epoch (1970-01-01) for issues that have never been stalled — counts all comments.

**Producer**: dispatcher Step 4a.
**Consumer**: dispatcher Step 4a's own gating logic.
**Test**: TODO: add test (`tests/unit/test-retry-counter-stalled-cutoff.sh`).

## INV-06: "crashed" / "process not found" keyword contract

**Rule**: The dispatcher's Step 5b dispatcher-crash comments MUST contain one of: `Task appears to have crashed (no PR found)`, or `process not found`. Forward-progress comments — specifically Step 5a's "Dev process still alive but PR ... ready" and Step 5b's "Dev process exited (PR found)" / "Dev process exited (no new commits since last review at ...)" — MUST NOT contain these phrases.

**Why**: Step 4a's retry-counter regex is `Task appears to have crashed \(no PR found\)|process not found`. A forward-progress comment that accidentally contained the word "crashed" (or "process not found") would be miscounted as a dev failure → eventually mark `stalled` despite the dev having actually progressed (#50).

**Producer**: dispatcher Step 5a (writes "Dev process still alive..."), Step 5b (writes "Task appears to have crashed..." or "Dev process exited (PR found)" or "Dev process exited (no new commits since last review at...)").
**Consumer**: dispatcher Step 4a's retry-counter regex.
**Test**: TODO: add test that Step 5a and Step 5b PR-found comments don't match the Step 4a regex.

## INV-07: Empty Reviewed-HEAD trailer routes to pending-review

**Rule**: When the dispatcher's Step 5b DEAD-with-PR branch finds an empty `LAST_REVIEWED_HEAD`, it MUST route to `pending-review`, NOT `pending-dev`.

**Why**: An empty value can mean either (a) review never ran successfully against this PR (the safe first-review case), or (b) the review wrapper's trailer post failed (token expiry, 403, rate limit). Both cases are best served by handing the PR to a fresh review — false-positive route-to-dev would loop forever ("dev exited, dispatcher sees no SHA match because no trailer, sends to dev again, ...").

**Producer**: dispatcher Step 5b.
**Consumer**: dispatcher's own routing decision.
**Test**: TODO: add test for both empty-trailer causes.
**Operator note**: if `pending-review` cycles repeatedly without new commits, grep `/tmp/agent-${PROJECT_ID}-review-*.log` for `WARNING: Failed to post Reviewed HEAD trailer`.

## INV-08: Wrapper exit trap label edits are atomic per call

**Rule**: Wrapper exit traps MUST update labels using single `gh issue edit --remove-label X --add-label Y` calls, never two separate calls. This guarantees no transient "both labels present" or "neither label present" state visible to the dispatcher between calls.

**Why**: Without single-call atomicity, a maintainer or another dispatcher cron tick reading labels at the wrong instant could see `pending-review + pending-dev` (forbidden, see [`state-machine.md` § Forbidden transitions](state-machine.md#forbidden-transitions)) or no active state at all (would reset the issue to "fresh autonomous, dispatch new" via Step 2).

**Note**: this invariant is about **per-edit atomicity**, NOT about cross-actor convergence. When the dispatcher's Step 5a and the wrapper trap both edit labels in the same window, they may target *different* final states — see [INV-15](#inv-15-step-5a-sigterm-race-is-non-deterministic). Each side's individual edit is still atomic, but the last-writer-wins outcome is non-deterministic.

**Producer**: dev wrapper trap, review wrapper trap, dispatcher Step 2/3/4/5.
**Consumer**: any reader of issue labels (other dispatcher ticks, maintainers).
**Test**: TODO: add test that mocks `gh issue edit` and asserts no two-call sequences exist.

## INV-09: `JUST_DISPATCHED` skip rule

**Rule**: Within a single dispatcher tick, Step 5 MUST skip any issue whose number is in the `JUST_DISPATCHED` array (issues dispatched in Steps 2/3/4 of the same tick).

**Why**: Freshly-dispatched wrappers are spawned via `nohup` and may not have written their PID file yet when Step 5 runs. Without the skip, Step 5 sees the PID file missing, diagnoses DEAD-no-PR, increments the retry counter, and eventually marks the issue stalled — for issues that were just dispatched and are in fact running fine (#34, #41).

**Producer**: dispatcher Step 2/3/4 (all append to `JUST_DISPATCHED`).
**Consumer**: dispatcher Step 5.
**Test**: TODO: add test that simulates a Step 2 → Step 5 within the same tick.

## INV-10: 5-minute idle gate before SIGTERM

**Rule**: Step 5a MUST require `now - PR.updatedAt > 300s` (strict greater-than, matching SKILL.md's `[ "$IDLE_SECONDS" -gt 300 ]`) before sending SIGTERM to an alive wrapper.

**Why**: Without it, the dispatcher might SIGTERM an agent that just pushed its passing CI build and is in the middle of its own cleanup (closing worktree handles, posting status comments, etc.). 5 min matches the dispatcher cron interval — the *next* tick will be the one to act on a wrapper still alive after CI is green, not the tick that detected green CI (#56).

**Producer**: dispatcher Step 5a.
**Consumer**: itself.
**Test**: TODO: add test that varies `PR.updatedAt` and confirms gate behavior at 300s, 301s.

## INV-11: Dependency state includes `MERGED`

**Rule**: Step 2's dependency check MUST treat both `CLOSED` and `MERGED` as resolved states. PRs return `MERGED` when merged, NOT `CLOSED`.

**Why**: When a `## Dependencies` section references a PR that has been merged, `gh issue view N --json state` returns `state: "MERGED"`. A naive `state != "CLOSED"` check leaves the dependent issue blocked forever (#61).

**Producer**: dispatcher Step 2 (`lib-dispatch.sh::check_deps_resolved`).
**Consumer**: itself.
**Status**: **ENFORCED** in PR-4 (closes #61). The check now reads `state ∉ {"CLOSED", "MERGED"}`.
**Test**: `tests/unit/test-check-deps-resolved.sh` covers single-CLOSED, single-MERGED, single-OPEN, and multi-dep mixed-state scenarios.

## INV-12: Resume only against unfinished sessions

**Rule**: The dispatcher's Step 4 MUST query the agent session's terminal state before issuing a resume, and skip the resume if `terminal_reason == completed`.

**Why**: A `claude --resume` against a session whose final turn ended with `stop_reason=end_turn` connects to the SSE streaming endpoint and never returns — the model has no work to do, the server keeps the connection alive, and the wrapper hangs indefinitely (#59).

**Producer**: dispatcher Step 4 (`lib-dispatch.sh::is_session_completed` invoked from `dispatcher-tick.sh` Step 4).
**Consumer**: prevents the wrapper from being put in a hang state.
**Status**: **ENFORCED** in PR-6 (closes #59). The dispatcher reads the agent log at `/tmp/agent-${PROJECT_ID}-issue-${N}.log`, finds the last `{"type":"result", ...}` object, and skips dispatch if `stop_reason=end_turn` AND `terminal_reason=completed`. Skip is conservative: the issue stays in `pending-dev` and a comment is posted asking an operator to manually decide between `pending-review` (PR exists) or close (work done) — the helper deliberately doesn't auto-recover, since silent recovery would mask other failure modes.
**Test**: `tests/unit/test-is-session-completed.sh` (11 cases): clean exit returns true; non-end_turn / non-completed / non-claude / missing log / multiple-result / malformed JSON / missing fields all return false.

## INV-13: Wall-clock cap on agent invocations

**Rule**: `lib-agent.sh::run_agent` and `resume_agent` MUST wrap the underlying CLI call in `timeout --kill-after=30s --signal=TERM ${AGENT_TIMEOUT:-4h}` (with graceful fallback to `gtimeout` on macOS).

**Why**: Any of: SSE keepalive without stop event (#59 root cause), MCP server stdio deadlock, DNS/TCP black hole. Without a wall-clock cap, any of those can pin a wrapper for 8+ hours (#60).

**Producer**: `lib-agent.sh::run_agent` and `resume_agent` via the shared `_run_with_timeout` helper.
**Consumer**: prevents wrappers from monopolizing PID slots and quota.
**Status**: **ENFORCED** in PR-6 (closes #60). The helper resolves `timeout`/`gtimeout` once at source time and falls through to an unwrapped invocation with a one-time WARN log when neither is on PATH. All four AGENT_CMD branches (claude / codex / kiro / fallback) and both call sites (run_agent / resume_agent) get the same wrapper.
**Test**: `tests/unit/test-agent-timeout-wrapper.sh` (6 cases): timeout fires within budget on `sleep 5` vs `AGENT_TIMEOUT=1s`; passthrough exit codes preserved (0 and non-zero); fallback path with `_AGENT_TIMEOUT_CMD=""` works for both success and non-zero commands.

## INV-14: Config lookup honors symlink-vendor pattern

**Rule**: Scripts that load `autonomous.conf` MUST resolve their own dir using `${BASH_SOURCE[0]:-$0}` directly, NOT `readlink -f`. The autonomous.conf fallback search path MUST cover the symlink-vendor layout (project's `scripts/lib-agent.sh` is a symlink into `.claude/skills/.../lib-agent.sh`).

**Why**: When projects vendor scripts as symlinks, `readlink -f` resolves to the skill installation dir — but `autonomous.conf` lives in the project's `scripts/`, not in the skill installation. The lookup misses, the wrapper exits at `: "${REPO:?Set REPO in autonomous.conf}"`, the dispatcher sees crash → eventually marks stalled (#58).

**Producer**: `lib-config.sh::load_autonomous_conf` (consolidated in PR-4 from three byte-identical inline blocks that previously lived in `lib-agent.sh`, `lib-auth.sh`, and `dispatcher-tick.sh`).
**Consumer**: every wrapper / dispatcher path that sources `lib-config.sh`.
**Status**: **ENFORCED** in PR-4 (closes #58). The shared helper uses `${BASH_SOURCE[0]:-$0}` (no `readlink -f`) and falls back to `${PROJECT_DIR}/scripts/autonomous.conf` (NOT the broken `../../../scripts/`).
**Test**: `tests/unit/test-bash-source-empty.sh` (TC-CONTENT-003) and `tests/unit/test-symlink-resolution.sh` (TC-CONTENT-006/007) assert no callsite uses `readlink -f` and that all three callsites delegate to `lib-config.sh::load_autonomous_conf`.

## INV-15: Step 5a SIGTERM race is non-deterministic

**Rule**: When the dispatcher's Step 5a sends SIGTERM to an alive wrapper for a PR-ready issue, the dispatcher writes `+pending-review` AND the wrapper's exit trap (which fires from the SIGTERM with bash exit status 143) writes `+pending-dev` — they target **different** final states. The race outcome is whichever `gh issue edit` lands last; in practice the trap's edit lands ~1s after the dispatcher's because the trap also posts a Session Report comment first.

**Why**: surfaced by the PR-2 docs review. The dev wrapper has no SIGTERM-aware code path; `cleanup()` only inspects `$exit_code` (143 ≠ 0 ⇒ failure branch ⇒ `pending-dev`). The dispatcher's Step 5a was designed under the assumption that the trap would route to `pending-review` (the "PR-ready" intent). It does not.

**Effect**: the issue typically lands in `pending-dev` after Step 5a fires (trap's later write wins). The PR is preserved (still open). The next dispatcher tick sees `pending-dev` and dispatches dev-resume. Review is delayed by one tick (~5 min) but no work is lost.

**Producer**: dispatcher Step 5a + dev wrapper trap (jointly).
**Consumer**: future dispatcher tick that has to pick up the resulting state.
**Status**: **ENFORCED** in PR-6 (closes #67). `autonomous-dev.sh` installs `trap on_sigterm TERM` that sets `RECEIVED_SIGTERM=1` and forwards SIGTERM to descendants via `pkill -TERM -P $$` (so the agent CLI exits promptly instead of bash queueing the signal until the foreground `run_agent` returns naturally). The `cleanup()` EXIT trap then rewrites `exit_code 143 → 0` when `RECEIVED_SIGTERM=1 && PR_EXISTS>0`, routing through the success branch to `pending-review`. SIGTERM with no PR keeps `exit_code=143` → `pending-dev` (covers operator-kill / orphan cases). Step 5a still writes its own label edit as belt-and-suspenders against SIGKILL escalation; both writers now converge on `pending-review`.
**Test**: `tests/unit/test-sigterm-trap.sh` (8 cases): the bug being fixed (143 + PR → pending-review) plus regression guards for clean exit / crash / timeout / no-PR variants, plus a source-of-truth grep on the wrapper to detect drift.

## INV-16: jq named-group regex uses Oniguruma syntax, not Python

**Rule**: Any jq regex that names a capture group MUST use Oniguruma syntax `(?<name>...)`, NOT Python-style `(?P<name>...)`. jq 1.6+ uses Oniguruma; the Python-style form errors with `Regex failure: undefined group option`.

**Why**: surfaced by PR-3's unit testing of `extract_dev_session_id` (#70). The original SKILL.md regex used `(?P<id>...)` — every `gh issue view ... -q '...capture(...)...'` call returned exit 5 with the regex error in stderr, and the `// empty` fallback did NOT catch it (jq exits before `//` is evaluated). In production this meant `extract_dev_session_id` always returned empty, and `dispatch-local.sh dev-resume <issue> ""` either failed input validation or silently fell back to a fresh session — i.e. resume mode was probably never resuming context across review cycles.

**Producer**: any helper in `lib-dispatch.sh` (or future jq-using code) that captures a named group. Today: `extract_dev_session_id`, `last_reviewed_head`. Both use the correct `(?<...>)` after PR-4.

**Consumer**: dispatcher Step 4 (which calls `extract_dev_session_id` to find the session-id to resume) and Step 5b (which calls `last_reviewed_head` to compare against the current PR HEAD).

**Status**: **ENFORCED** in PR-4 (closes #70). Both helpers verified.

**Test**: `tests/unit/test-lib-dispatch.sh` asserts that `extract_dev_session_id` returns `abc-123-def` for a comment containing `Dev Session ID: \`abc-123-def\`` (was previously asserting empty under the broken regex).

## INV-17: Trunk protection requires defense in depth across 3 layers

**Rule**: Direct pushes to the trunk branch MUST be blocked by **at least two** independent layers, since each layer alone has known gaps:

1. **Claude Code PreToolUse hook** (`block-push-to-main.sh`) — only fires for Bash commands routed through a Claude session. Free-form work outside `/autonomous-dev` skill activations bypasses it (#68).
2. **Per-worktree git pre-push hook** (`install-git-pre-push.sh`) — fires for ANY `git push`, including outside Claude. Requires per-worktree installation; `git rev-parse --git-path hooks` resolves the right dir.
3. **Server-side branch protection** (GitHub) — best of all, but unavailable on Free-tier private repos.

In environments without Layer 3 (server-side), Layers 1 and 2 must both be installed. Layer 1 alone is insufficient (see #68 production incident: 6 commits landed on trunk outside any PR).

**Why**: surfaced by #64, #65, and #68 collectively. The downstream consumer that hit this had Layer 3 unavailable (GitHub Free private repo) and Layer 1 misconfigured (skill-scoped, not project-scoped). With no Layer 2 installed by default, every gap was simultaneously exposed.

**Producer**: `skills/autonomous-common/scripts/install-claude-hooks.sh` is the consumer-facing one-shot installer that wires up Layer 1 (project-scoped `.claude/settings.json`) and triggers `install-git-pre-push.sh` for Layer 2.

**Consumer**: every project that adopts this skill set. The autonomous-dev workflow's worktree-creation step should call `install-git-pre-push.sh` after each `git worktree add` (Layer 2 is per-worktree).

**Status**: **ENFORCED** in PR-5 (closes #64, #65, #68). The 3-layer model is now documented; the installers exist. Follow-up: wire the per-worktree `install-git-pre-push.sh` call into the autonomous-dev workflow prompt (separate small PR).

**Test**: `tests/unit/test-block-push-regex.sh` covers Layer 1 (11 cases). `tests/unit/test-install-git-pre-push.sh` covers Layer 2 (8 cases). `tests/unit/test-install-claude-hooks.sh` covers the consumer-side installer that wires both Layer 1 and Layer 2 (10 cases).

---

## Adding a new invariant

When fixing a pipeline bug, after locating the bug on the state machine + flow docs:

1. Decide whether the bug surfaces a previously-implicit rule. Most pipeline bugs do.
2. Add a new `INV-NN` entry here (next sequential number).
3. Cite the issue / PR number in the **Why** field.
4. Identify producer and consumer — these are the actors whose behavior the invariant constrains.
5. Add a TODO for the test, even if you don't write the test in the same PR. (Tests for these invariants should live in `tests/unit/` and be enumerated in the CI shellcheck job.)
6. Reference the invariant by ID from the flow doc(s) where it's relevant.

Once `INV-NN` exists, prefer "violates [INV-NN](#inv-NN-...)" in commit messages and PR descriptions over re-explaining the rule.

## Cross-references

- [`state-machine.md`](state-machine.md) — invariants flagged inline at the relevant transitions.
- [`dispatcher-flow.md`](dispatcher-flow.md), [`dev-agent-flow.md`](dev-agent-flow.md), [`review-agent-flow.md`](review-agent-flow.md) — every flow step that depends on or upholds an invariant cites it by ID.
- [`handoffs.md`](handoffs.md) — invariants are the producer/consumer contracts at each handoff.
