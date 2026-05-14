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

**Rule**: The dispatcher's Step 4 MUST query the agent session's terminal state before issuing a resume, and treat both `terminal_reason == completed` and `terminal_reason == prompt_too_long` as terminal (skip resume).

**Why**:
- `end_turn|completed`: a `claude --resume` against a session whose final turn ended cleanly connects to the SSE streaming endpoint and never returns (#59).
- `*|prompt_too_long`: headless `claude -p` has no auto-compaction (the TUI's `/compact` is interactive-only). Resuming re-feeds the entire JSONL transcript, which is what blew the context window in the first place — guaranteed re-crash, infinite loop.

**Producer**: dispatcher Step 4 (`lib-dispatch.sh::is_session_completed` invoked from `dispatcher-tick.sh` Step 4). The helper writes the matched `terminal_reason` to a caller-provided var via `printf -v` so the caller can branch on the case.

**Consumer**: prevents the wrapper from being put in a hang state (completed) or a dispatch loop (prompt_too_long).

**Status**: **ENFORCED**. Closed cases:
- PR-6 (closes #59) — initial enforcement for `end_turn|completed`.
- This PR — extends to `prompt_too_long`. The completed branch posts an `INV-12-completed:<sid>` notice and leaves the issue in `pending-dev` for operator decision; the prompt-too-long branch posts an `INV-12-prompt-too-long:<sid>` notice, truncates the per-issue log, and `dispatch dev-new` to auto-recover with a fresh session.

**Test**: `tests/unit/test-is-session-completed.sh` (14 cases) and `tests/unit/test-autonomous-launcher-verdict-fresh.sh` TC-PTL-001..007d.

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

### Supported deployment topologies (post-#104)

The contract is satisfied across two distinct topologies because every script computes `SCRIPT_DIR` from `${BASH_SOURCE[0]:-$0}`:

| Topology | Layout | conf-lookup tier that hits |
|---|---|---|
| **Vendored per-project** | `<project>/.agents/skills/.../scripts/dispatch-local.sh` (real file) ← `<project>/scripts/dispatch-local.sh` (symlink) | tier-2 — `SCRIPT_DIR` resolves to `<project>/scripts/`, conf is right there |
| **Shared install** | `~/.claude/skills/.../scripts/dispatch-local.sh` (real file) ← `<project>/scripts/dispatch-local.sh` (symlink) | tier-2 — same — `BASH_SOURCE[0]` keeps the project-side path |

Both topologies yield the same `SCRIPT_DIR` for symlinked invocations: the project's `scripts/`. Direct invocation of a vendored copy (no project-side symlink) still works via the legacy `${SCRIPT_DIR}/../../../scripts/autonomous.conf` fallback in `dispatch-local.sh`. That fallback only fires for the legacy 2-deep `<project>/skills/.../scripts/` layout (3 levels up from `<scripts>` lands at `<project>`); the modern 3-deep layouts under `.agents/skills/` or `.claude/skills/` rely on the project-side symlink + tier-2 path.

#### Required symlink manifest (shared-install topology)

Each entry-point script sources sibling lib files via `${SCRIPT_DIR}/<sibling>.sh`. With `BASH_SOURCE[0]`-based `SCRIPT_DIR`, those resolve to the project's `scripts/` — which means the operator MUST symlink every transitive sibling, not just the entry-points. Symlinking only `dispatch-local.sh` would break with `No such file or directory: lib-config.sh`. The minimum set:

| File | Why it must be symlinked |
|---|---|
| `autonomous-dev.sh`, `autonomous-review.sh` | wrapper entry points |
| `dispatch-local.sh` | dispatcher → wrapper bridge |
| `lib-agent.sh`, `lib-auth.sh`, `lib-config.sh`, `lib-dispatch.sh`, `lib-review-bots.sh` | sourced transitively from the entry points |
| `gh-app-token.sh`, `gh-with-token-refresh.sh`, `gh-token-refresh-daemon.sh` | sourced by lib-auth.sh; daemon spawned by token-refresh path |

`autonomous.conf.example` documents this manifest in operator-facing form. A future helper script `install-shared-symlinks.sh` (out of scope per #104) could automate the symlink creation.

**Producer**: `lib-config.sh::load_autonomous_conf` (consolidated in PR-4 from three byte-identical inline blocks). Six entry-point scripts (`dispatch-local.sh`, `autonomous-dev.sh`, `autonomous-review.sh`, `gh-token-refresh-daemon.sh`, `gh-with-token-refresh.sh`, `setup-labels.sh`) whose own `SCRIPT_DIR` feeds into the same lookup chain are aligned in #104.
**Consumer**: every wrapper / dispatcher path that sources `lib-config.sh`.
**Status**: **ENFORCED**. Close history:
- PR-4 (closes #58) — initial enforcement on the three lib paths via `lib-config.sh`.
- #104 — extended enforcement to the six entry-point scripts that previously used `readlink -f "$0"`. Pre-#104 the contract worked for vendored topology only (via `dispatch-local.sh`'s legacy fallback); post-#104 the shared-install topology also works.

**Test**: `tests/unit/test-bash-source-empty.sh` (TC-CONTENT-003) and `tests/unit/test-symlink-resolution.sh` (TC-CONTENT-006/007 + TC-INV14-1..6) assert no callsite uses `readlink -f`, all callsites delegate to `lib-config.sh::load_autonomous_conf`, and conf-loading works under both deployment topologies.

## INV-15: Step 5a SIGTERM race is non-deterministic

**Rule**: When the dispatcher's Step 5a sends SIGTERM to an alive wrapper for a PR-ready issue, the dispatcher writes `+pending-review` AND the wrapper's exit trap (which fires from the SIGTERM with bash exit status 143) writes `+pending-dev` — they target **different** final states. The race outcome is whichever `gh issue edit` lands last; in practice the trap's edit lands ~1s after the dispatcher's because the trap also posts a Session Report comment first.

**Why**: surfaced by the PR-2 docs review. The dev wrapper has no SIGTERM-aware code path; `cleanup()` only inspects `$exit_code` (143 ≠ 0 ⇒ failure branch ⇒ `pending-dev`). The dispatcher's Step 5a was designed under the assumption that the trap would route to `pending-review` (the "PR-ready" intent). It does not.

**Effect**: the issue typically lands in `pending-dev` after Step 5a fires (trap's later write wins). The PR is preserved (still open). The next dispatcher tick sees `pending-dev` and dispatches dev-resume. Review is delayed by one tick (~5 min) but no work is lost.

**Producer**: dispatcher Step 5a + dev wrapper trap (jointly).
**Consumer**: future dispatcher tick that has to pick up the resulting state.
**Status**: **ENFORCED** in PR-6 (closes #67). `autonomous-dev.sh` installs `trap on_sigterm TERM` that sets `RECEIVED_SIGTERM=1` and forwards SIGTERM to descendants via `pkill -TERM -P $$` (so the agent CLI exits promptly instead of bash queueing the signal until the foreground `run_agent` returns naturally). The `cleanup()` EXIT trap then rewrites `exit_code 143 → 0` when `RECEIVED_SIGTERM=1 && PR_EXISTS>0`, routing through the success branch to `pending-review`. SIGTERM with no PR keeps `exit_code=143` → `pending-dev` (covers operator-kill / orphan cases). Step 5a still writes its own label edit as belt-and-suspenders against SIGKILL escalation; both writers now converge on `pending-review`.
**Test**: `tests/unit/test-sigterm-trap.sh` (8 cases): the bug being fixed (143 + PR → pending-review) plus regression guards for clean exit / crash / timeout / no-PR variants, plus a source-of-truth grep on the wrapper to detect drift.

**Residue note (INV-25)**: even with the convergent SIGTERM path, label residue from earlier races, manual reconciliation, or future yet-unknown producers is healed by Step 0 hygiene at every tick — see [INV-25](#inv-25-terminal-labels-approved-stalled-are-sticky-transitional-residue-is-healed-at-tick-start). INV-15 narrows the producer surface; INV-25 closes the residue class regardless of producer.

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

## INV-18: Cold-start grace period before stale detection

**Rule**: every Step 2/3/4 dispatch in `dispatcher-tick.sh` MUST write a dispatcher-controlled marker comment in the form

```
<!-- dispatcher-token: <id> at <ISO-8601 UTC> mode=<dev-new|dev-resume|review> -->
<human-readable line>
```

Step 5 stale detection MUST NOT classify an active issue as crashed while its latest dispatcher-token comment is younger than `DISPATCH_GRACE_PERIOD_SECONDS` (default 600 = 10 min).

**Why**: surfaced by #99 Bug 1. Agent startup involves wrapper spawn + auth setup + agent CLI cold start + first API call before the wrapper writes its PID file. Empirical measurements on a real dev box show this window is consistently 1–7 seconds for healthy invocations, but slow MCP negotiation, remote SSM dispatch, or upstream model latency can push it longer. Pre-fix, before the wrapper had written its PID file, `pid_alive` returned false → DEAD branch fired → dispatcher posted "Task appears to have crashed (no PR found)" → after `MAX_RETRIES` of these false positives the issue stalled. `JUST_DISPATCHED` only protects the current tick; the very next tick (5 min later) was misclassifying a cold-starting wrapper as dead. 10 min is roughly two cron ticks of headroom — enough for a slow-but-alive wrapper, short enough that genuinely-dead wrappers don't sit too long before retry.

**Producer**: `dispatcher-tick.sh` Steps 2/3/4 — `post_dispatch_token` is invoked inside each step body before `dispatch()`.

**Consumer**: `dispatcher-tick.sh` Step 5 stale detection — calls `is_within_grace_period` after the JUST_DISPATCHED check and before DEAD/ALIVE branching.

**Status**: **ENFORCED** in #99 fix.

**Test**: `tests/unit/test-dispatcher-reliability-99.sh` covers `latest_dispatch_token_age_seconds`, `is_within_grace_period`, and `post_dispatch_token` roundtrip (10 cases).

---

## INV-19: Retry counter requires confirmed agent startup

**Rule**: `count_retries` MUST count dispatcher-detected crash comments toward `MAX_RETRIES` ONLY when the agent has confirmed startup at some point in the current retry cycle — i.e., a `Dev Session ID:` comment exists after the most recent stalled-cutoff AND that comment is NOT a `Mode: startup-failure` report. Agent failure session reports (`Agent Session Report (Dev)` with non-zero exit code) always count regardless.

The `Mode: startup-failure` exclusion matters: `autonomous-dev.sh`'s startup-failure trap (when the wrapper exits before invoking the agent — e.g., #92 missing-`gh` path) still emits a session report containing the SESSION_ID that was forwarded for dev-resume mode. Counting that as "agent confirmed startup" would re-arm dispatcher-crash counting on a wrapper that never actually invoked the agent.

**Why**: surfaced by #99 Bug 5. Pre-fix, dispatcher-side false positives (Bug 1 cold-start, missing exec bit, broken auth handoff before agent ran) consumed `MAX_RETRIES` even though the agent never failed. By definition such crashes happen before the agent has had a chance to write its session-id comment, so gating the count on session-id presence cleanly suppresses them while preserving counting for legitimate post-startup crashes (network drop mid-session, segfault, OOM kill).

**Producer**: `autonomous-dev.sh` cleanup() trap writes the `Agent Session Report (Dev)` comment containing `Dev Session ID: \`<id>\``. This is the post-startup checkpoint that arms dispatcher-crash counting.

**Consumer**: `lib-dispatch.sh::count_retries` — gates dispatcher-crash counting on the presence of any post-cutoff session-id comment. `count_dispatcher_false_positives` reports the suppressed count for operator visibility in `mark_stalled`'s comment.

**Status**: **ENFORCED** in #99 fix.

**Test**: `tests/unit/test-dispatcher-reliability-99.sh` covers session-id-gate semantics (5 cases including stalled-cutoff interaction). `tests/unit/test-lib-dispatch.sh` regression cases updated to reflect the new gate.

---

## INV-20: Verdict authenticity binding (actor + window + trailer presence)

**Rule**: The review wrapper's verdict polling jq query MUST gate on three layered predicates when actor binding is available: (a) `author.login == BOT_LOGIN`, (b) `createdAt >= WRAPPER_START_TS`, (c) `body matches /Review Session/`. The trailer match MUST NOT bind to the wrapper-generated `SESSION_ID` — only the trailer's presence is checked.

**Why**: The prior body-text predicate `Review Session.*${SESSION_ID}` depended on the agent echoing the wrapper's UUID verbatim. Agents under context pressure occasionally rewrote the UUID, causing the wrapper to miss valid verdicts and force the FAILED branch. Combined with a same-PR / same-issue dispatcher state machine, this produced infinite dev↔review ping-pong loops on the consumer side. Trailer-presence (without UUID binding) keeps spoof protection intact in `GH_AUTH_MODE=token` (where dev and review wrappers share BOT_LOGIN — the dev agent's prompts don't instruct it to emit `Review Session:`, so its status comments are excluded) without the brittleness.

**Producer**: `autonomous-review.sh` polling loop. Captures `WRAPPER_START_TS` once before `run_agent` (ISO-8601 UTC) and `BOT_LOGIN` once via `gh api user --jq .login` (treats empty / errored / literal-`"null"` as unset).

**Consumer**: prevents (a) verdict regressions when the agent rewrites the trailer UUID, (b) cross-wrapper spoofing in same-identity (token) mode, (c) stale verdicts from prior ticks being picked up.

**Fallback**: when `BOT_LOGIN` is unset, the predicate becomes `(createdAt >= WRAPPER_START_TS) AND (body matches /Review Session.*<SESSION_ID>/)`. This re-introduces the brittleness only on the rare path where actor binding is unavailable, and time-window predicate still narrows out stale comments.

**Status**: **ENFORCED** in this PR. Replaces the prior session-id-only binding (which closed #95 phrasing-drift but did not address the UUID-rewrite drift).

**Test**: `tests/unit/test-autonomous-launcher-verdict-fresh.sh` TC-VRD-001..009a (12 cases including token-mode dev-agent quoted-verdict anti-spoof).

## INV-21: Resume-fallback fresh session id is dispatcher-readable

**Rule**: `autonomous-dev.sh` MODE=resume's non-zero-exit fallback path, immediately after assigning `SESSION_ID="$NEW_SESSION_ID"`, MUST post a standalone GitHub issue comment matching the regex `Dev Session ID: \`<id>\``.

**Why**: Without this, the only place the new session id surfaces to GitHub before the agent runs is inside the explanatory "Resume failed... Starting new session..." comment — which does NOT match the dispatcher's `extract_dev_session_id` regex. If the wrapper crashes between the resume-fallback decision and the trap-on-exit `Agent Session Report (Dev)` post (e.g. a transient gh outage on the report post), the dispatcher's next tick reads the OLD session id from prior comments and resumes the dead session forever.

**Producer**: `autonomous-dev.sh:362..366` — two separate `gh issue comment` calls (explanation + standalone marker) so a single failed post can't orphan the marker.

**Consumer**: `lib-dispatch.sh::extract_dev_session_id` — picks up the new id on the next tick.

**Status**: **ENFORCED** in this PR.

**Test**: `tests/unit/test-autonomous-launcher-verdict-fresh.sh` TC-PTL-005.

## INV-22: AGENT_LAUNCHER tokenization + claude-only invocation contract

**Rule**: `lib-agent.sh` MUST tokenize `AGENT_LAUNCHER` (when non-empty) into `AGENT_LAUNCHER_ARGV[]` exactly once at source time via `eval "AGENT_LAUNCHER_ARGV=($AGENT_LAUNCHER)"`.

**Scope**: `AGENT_LAUNCHER` is only valid with `AGENT_CMD=claude`. The combination is rejected at config load otherwise — the canonical launcher (a `cc` shell function ending with `$CLAUDE_CMD "$@"`) is hardcoded to invoke claude, so it cannot launch codex / kiro / opencode.

**Invocation contract** (claude branch only): the launcher script is responsible for invoking the claude binary itself. The wrapper passes only **flags + prompt** as `"$@"` to the launcher — NOT the binary name and NOT `env -u CLAUDECODE`. Pre-fix the wrapper passed `env -u CLAUDECODE claude --session-id ...` through to the launcher; the launcher's terminal `$CLAUDE_CMD "$@"` then invoked `claude env -u CLAUDECODE claude --session-id ...` and claude rejected `-u` as an unknown option (observed in production on a downstream consumer — wrapper exited 1 within 5 seconds of every dispatch). Post-fix, `lib-agent.sh::run_agent` / `resume_agent` branches on `${#AGENT_LAUNCHER_ARGV[@]}`: launcher set → flags-only argv; launcher unset → full `env -u CLAUDECODE claude args...` shape.

**Why**: The consumer-machine motivation is to bridge dispatcher-spawned wrappers (non-interactive `nohup` shell, no `~/.bashrc`) into the same env that powers the operator's interactive `claude` shell function. Without `AGENT_LAUNCHER`, autonomous wrappers ran with `--model opus[1m]` but the alias resolved to whatever model claude defaults to (no `ANTHROPIC_DEFAULT_OPUS_MODEL` set), silently downgrading to a different model.

**Producer**: `lib-agent.sh` — the `eval` parses the launcher string once, with hard-fails on parse error and on `AGENT_CMD!=claude` mismatch, and a WARN when the parse succeeds but yields zero argv elements (almost always operator typo).

**Consumer**: `_run_with_timeout` unconditionally prepends `${AGENT_LAUNCHER_ARGV[@]}` to every invocation; the claude branches in `run_agent` / `resume_agent` decide whether to include the binary name + `env -u CLAUDECODE` based on `AGENT_LAUNCHER_ARGV` length, while non-claude branches are guaranteed empty by the config-load claude-only check.

**Trust**: `AGENT_LAUNCHER` is read from `autonomous.conf`. Treating its contents as shell input is no worse than executing `AGENT_CMD` itself — both are operator-controlled config in the same file. The wrapper documents this trust assumption explicitly.

**Operator pitfalls** (documented in `autonomous.conf.example`):
- The launcher must invoke claude with plain `cc "$@"` or `exec claude "$@"`, never `exec cc "$@"`. `exec` resolves `cc` to `/usr/bin/cc` (the GNU C compiler) instead of the shell function.
- `cc` must be a shell *function*, not an alias. bash non-interactive shells do not expand aliases by default, so a `cc` alias would fall through to PATH lookup → again the C compiler.

**Status**: **ENFORCED**.

**Test**: `tests/unit/test-autonomous-launcher-verdict-fresh.sh` TC-LCH-001..003 (including the TC-LCH-002 anti-regression assertion: argv must NOT contain `-u` or the literal `claude` token under launcher mode), plus TC-LCH-007/008 for the `CC_USER` / `CC_ROLE_KIND` env exports the wrapper sets before invoking the launcher.

## INV-23: PID_FILE points at a process whose death reaps the entire agent subtree

**Rule**: The PID written to PID_FILE MUST identify a process whose death is sufficient to terminate every descendant of the agent invocation. In practice this means the session leader of a setsid-spawned process group: `_run_with_timeout` (in `lib-agent.sh`) launches the agent under `setsid`, captures the resulting PID into `_AGENT_RUN_PID`, and writes it to `$AGENT_PID_FILE` if set. Because setsid makes the child a session and group leader, `_AGENT_RUN_PID` IS the PGID, so `kill -TERM -- -<pid>` (in both `kill_stale_wrapper` and the wrappers' SIGTERM trap) cascades to every descendant atomically.

**Why**: Pre-fix, `acquire_pid_guard` wrote the wrapper shell's `$$` while the timeout/agent subtree ran as a child. When the wrapper exited before the subtree finished unwinding (cleanup-trap path, SIGTERM-forwarding race, or normal completion before the agent fully stopped), the subtree was reparented to PID 1 and unreachable through PID_FILE. The next tick's `kill_stale_wrapper` saw ESRCH on the dead `$$`, declared the slot clean, and dispatched a fresh agent — producing multiple coexisting agent trees per issue (#109 reproduced 4 generations across one session, 2 still alive an hour after merge). $$ is not a process group leader, so `kill -- -$$` is a no-op; only the session leader's PID gives the cascade we need.

**Producer**: `_run_with_timeout` in `lib-agent.sh`. The session leader is always the spawned `setsid` (or the bare command when setsid is unavailable, in which case the contract is degraded — see fallback below).

**Consumer**:
- `dispatch-local.sh::kill_stale_wrapper` issues `kill -TERM -- -<old_pid>` AND a leader-only kill, on both TERM and KILL escalation paths. The leader-only kill is a fallback for mid-rollout PID files that still hold a pre-fix `$$`.
- `autonomous-dev.sh` and `autonomous-review.sh`, via `lib-agent.sh::install_agent_sigterm_trap`, forward dispatcher SIGTERM to the group via `kill -TERM -- -${_AGENT_RUN_PID}`.

**Defence in depth (option C)**: `kill_stale_wrapper` additionally runs `pgrep -f -- '--issue ${ISSUE_NUM}\b'` and group-kills any matches not reachable through PID_FILE. Catches escaped trees from pre-fix wrappers and races between `acquire_pid_guard` and `_run_with_timeout` overwriting PID_FILE. Operators can disable via `KILL_STALE_PGREP_FALLBACK=false` if the heuristic over-matches.

**Fallback when setsid is missing**: `_run_with_timeout` falls back to a non-setsid background spawn (defensive: the dispatcher fleet is Linux/Ubuntu and util-linux is universal there; macOS operators get setsid via Homebrew). In that mode the agent runs in the wrapper's process group; `kill_stale_wrapper`'s pgrep fallback still picks up orphans, with degraded — but not broken — atomicity.

**Status**: **ENFORCED** in this PR (closes #109).

**Test**:
- `tests/unit/test-pid-guard-pgid.sh` (18 cases) — TC-PGID-001 (new session under setsid), TC-PGID-002+004 (group-kill reaps grandchildren), TC-PGID-005 (pgrep fallback), TC-PGID-008/009 (`AGENT_PID_FILE` write contract), plus TC-STATIC-001..006 for source-of-truth.
- `tests/unit/test-sigterm-trap.sh` updated to accept either inline `on_sigterm` or `install_agent_sigterm_trap` factoring.

## INV-24: Review wrapper DEAD detection requires both pid_alive miss AND no near-success PR signal

**Rule**: The dispatcher's Step 5b review-DEAD branch MUST NOT post a "Review process appears to have crashed" comment or flip `reviewing` → `pending-dev` on a bare `pid_alive` miss. It must additionally consult `review_near_success` (in `lib-dispatch.sh`), which returns 0 (skip) when ANY of these PR-state signals are positive within `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS` (default 300s):

1. `PR.mergedAt` within the window — wrapper is finishing the merge step.
2. Most recent `APPROVED` review event within the window — wrapper has reached approve step.
3. Most recent `^Review (PASSED|findings)` comment within the window — wrapper completed verdict, may be merging or just exiting normally.
4. Defensive `kill -0 <pid>` against the current PID-file content now succeeds — the original `pid_alive` miss raced with the wrapper's normal scheduling.

Only when ALL four signals are negative does the existing crash + label-swap fire.

Complementary, `pid_alive` itself MUST honor a heartbeat-based mtime fallback: when `kill -0 <pid>` fails but the PID file's mtime is within `HEARTBEAT_INTERVAL_SECONDS * 3` (default 360s), still treat as ALIVE. The wrapper's `install_agent_heartbeat` helper (in `lib-agent.sh`) refreshes the mtime every `HEARTBEAT_INTERVAL_SECONDS` (default 120s) for its lifetime, so a stale mtime is strong evidence the process is genuinely dead.

**Why**: Real review wrappers routinely run 15-30 min (E2E browser automation + multiple bot rounds + line-by-line review). The cold-start grace period (`DISPATCH_GRACE_PERIOD_SECONDS=600`) is sized for dev-side hangs, not review duration; cranking it to 1800 globally would make legitimate dev hangs take 30 min to detect. The right fix is to make the DEAD-branch decision smarter, not the grace longer (#111).

Pre-fix, a transient `pid_alive` miss (race or short-lived sub-shell exit) within the 21-min review window made the dispatcher post a misleading "crashed" comment and flip the label, even though the wrapper subsequently posted PASSED + auto-merged the PR. The user-visible result was correct, but the timeline was noisy and the label remained stuck on `pending-dev` after the issue closed.

**Producer**: `lib-dispatch.sh::review_near_success` + `lib-dispatch.sh::pid_alive` (mtime tier) + `lib-agent.sh::install_agent_heartbeat`.

**Consumer**: `dispatcher-tick.sh` Step 5b review branch — guards the crash comment + label swap behind `review_near_success`.

**Disable knobs**:
- `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=0` — restores legacy strict behavior (every `pid_alive` miss declares crashed). Useful for ops who hit edge cases with the four-signal cross-check.
- `HEARTBEAT_INTERVAL_SECONDS=0` — disables both the wrapper-side heartbeat spawn and the dispatcher-side mtime fallback. Useful for hosts where the background loop is undesired.

**Status**: **ENFORCED** in this PR (closes #111).

**Test**:
- `tests/unit/test-dispatcher-review-near-success.sh` (6 cases) — TC-RNS-001..004 cover each signal positive; TC-RNS-005 covers all signals negative (crash path still fires); TC-RNS-006 covers the `=0` legacy strict knob.
- `tests/unit/test-wrapper-heartbeat.sh` (7 cases) — TC-HB-001..004 cover `pid_alive` decision matrix; TC-HB-005..007 cover heartbeat lifecycle (touches mtime, exits with parent, `=0` no-op).

## INV-25: Terminal labels (`approved`, `stalled`) are sticky; transitional residue is healed at tick start

**Rule**: When an issue carries either terminal label (`approved` or `stalled`) AND any transitional label (`in-progress`, `reviewing`, `pending-review`, `pending-dev`), the dispatcher MUST strip the transitional label(s) at the very top of every tick — before Step 1's concurrency gate, before any `list_*` selector reads labels. Strips are atomic per issue (single `gh issue edit --remove-label A --remove-label B ...`). For each `(issue, sorted-set-of-stripped-labels)` tuple, an audit comment of the form `Label hygiene: stripped \`X\`, \`Y\` from \`<terminal>\` issue (INV-25). <!-- INV-25-hygiene:<sorted-labels> -->` is posted at most once — the marker comment gates re-posting on subsequent ticks.

**Why**: `state-machine.md::Forbidden transitions` already declared this combination invalid. Code did not enforce it: when residue landed (wrapper crash between two label edits, [INV-15] SIGTERM race, manual reconciliation by an operator), the next tick's `list_*` selectors disagreed about how to handle the issue and one of them re-armed dispatch. Issue #115 Bug A (PR #116) fixed one specific selector; Bug B (this invariant) closes the class by self-healing residue regardless of which selector would have misclassified it.

Step 0 runs UNCONDITIONALLY — even when concurrency is saturated. Hygiene is pure label edits, no agent dispatch, no retry counting; gating it on capacity would defer cleanup by an entire tick on a busy day, exactly when residue is most likely.

**Producer**: `lib-dispatch.sh::run_hygiene_pass`, `list_hygiene_residue`, `hygiene_strip_residual_labels`, `hygiene_post_audit_comment`, `_has_terminal_label`.

**Consumer**: `dispatcher-tick.sh` Step 0 (calls `run_hygiene_pass` before Step 1).

**Cross-references**:
- [INV-15] documents the SIGTERM race that is one *producer* of the residue this invariant heals. The race itself is convergent (PR-6); the residue this heals is from earlier-or-different races and from manual reconciliation, not from the SIGTERM path under normal conditions.
- All four `list_*` selectors in `lib-dispatch.sh` (`list_new_issues`, `list_pending_review`, `list_pending_dev`, `list_stale_candidates`) inline their own `approved` AND `stalled` subtraction. `list_new_issues` was correct from inception (it explicitly excludes every state label); `list_stale_candidates` was fixed in PR #116 (Bug A); `list_pending_review` and `list_pending_dev` were fixed by the Bug C post-investigation PR — pre-fix, `list_pending_review` only excluded `reviewing` and `list_pending_dev` had no inline filter at all. INV-25 makes those inline subtractions defense-in-depth rather than the only line of defense — Step 0 hygiene heals the residue at tick start regardless of which selector would have misclassified. Future selectors should call `_has_terminal_label()` for symmetry; a missed call is no longer a Bug-A-class infinite-loop bug, just a wasted query.
- [INV-26] (stall-decision correctness) reduces one of the producers of the `stalled + transitional` residue this invariant heals: pre-INV-26, `mark_stalled` could fire against a still-live wrapper, the wrapper trap then writing `+pending-review` onto the resulting `+stalled` issue. With INV-26, that producer is closed at the upstream side — the live wrapper finishes first, the trap correctly transitions to `+pending-review` (no `stalled`), and INV-25 only has to heal residue from genuinely-stalled-but-late-trap edge cases.

**Status**: **ENFORCED** in this PR (closes #115 Bug B).

**Test**:
- `tests/unit/test-step0-hygiene.sh` (23 cases) — TC-HAS-TERM-001..005 cover the predicate, TC-HYG-001..006 cover per-issue strip logic, TC-COMMENT-001..003 cover audit-comment idempotency, TC-STEP0-INT-001..003 statically pin Step 0 placement (before Step 1, not gated by concurrency).

## INV-26: Stall decision excludes dispatcher-induced terminations and defers on live wrappers

**Rule**: Two conjunct conditions must hold before the dispatcher can mark an issue `+stalled`:

1. **Failure counter accuracy**: `count_agent_failures` (`lib-dispatch.sh`) MUST exclude Session Reports whose `Exit code` is 0 (success), 143 (SIGTERM), or 137 (SIGKILL) from the agent-failure tally. Exits 143 and 137 are almost exclusively caused by `dispatch-local.sh::kill_stale_wrapper` — the dispatcher's own kill of a stale wrapper to spawn a fresh one. Counting the dispatcher's kill as an "agent failure" silently consumes retry budget the agent never spent.
2. **Liveness deferral**: `mark_stalled` MUST query `pid_alive issue <issue_num>` before any `gh issue edit` or stall comment. If the dev wrapper is alive, the stall decision is deferred — `mark_stalled` returns 0 without changing labels, posts a one-shot deferral comment (idempotency-keyed on the wrapper PID via marker `INV-26-stall-deferral:pid=<pid>`), and lets the next tick re-evaluate. The stall path proceeds only when no live wrapper holds the PID file.

**Why**: Without (1), `kill_stale_wrapper`-induced SIGTERMs accumulate against the retry budget; combined with `pid_alive` misjudgements producing "Task crashed" comments, MAX_RETRIES is hit prematurely. Without (2), `mark_stalled` then transitions to `+stalled` while the wrapper is still alive — and the wrapper subsequently completes work, the trap writes `+pending-review` onto a `+stalled` issue, the next tick's Step 3 picks it up (pre-#118: with no `stalled` filter; post-#118: blocked by Step 0 hygiene but only after a tick lag), and the issue ends in inconsistent label state. Reproduced on a downstream consumer's `#204`-class wedge on 2026-05-14: 2 dispatcher-misjudgement crashes + 1 SIGTERM-from-dispatcher → false stall while the real wrapper finished and PR auto-merged. See #121.

**Producer**:
- (1) `lib-dispatch.sh::count_agent_failures` — jq predicate excludes exit codes 0, 143, 137. Anchors on `\b` word boundary so 144 / 1430 don't false-match.
- (2) `lib-dispatch.sh::mark_stalled` — calls `pid_alive issue $issue_num` first; defers (post one-shot comment, return 0) if alive.

**Consumer**: `dispatcher-tick.sh` Step 4 retry-counter branch — calls `mark_stalled` when `count_retries >= MAX_RETRIES`. With both rules in place, a wrapper that's making real progress can never be `+stalled` until it has actually exited.

**Cross-references**:
- [INV-15] (SIGTERM race) is one *producer* of the residue [INV-25] heals; this invariant prevents the *upstream* false stall that creates the residue in the first place.
- [INV-19] (retry counter requires confirmed agent startup) gates dispatcher-detected crashes; this invariant adds a parallel gate on agent-side Session Reports for terminations the dispatcher itself caused.
- [INV-23] (PID_FILE death reaps subtree) gives `pid_alive` its truth: a wrapper still holding the PID file means the agent subtree is reachable. The liveness deferral relies on that contract.
- [INV-24] (review wrapper DEAD detection requires near-success short-circuit) is the review-side analog. The dev-side near-success short-circuit ([INV-27], `dev_near_success`) complements this invariant by preventing the upstream "Task crashed" comments that would otherwise drive the counter; INV-26 then catches anything INV-27 misses by deferring the actual stall transition when the wrapper is still alive.

**Status**: **ENFORCED** in this PR (closes #121 Fix A + Fix C; Fix B / `dev_near_success` is a separate follow-up PR).

**Tests**:
- `tests/unit/test-count-agent-failures-sigterm.sh` (7 cases): TC-CAF-001/006/007 cover regression bounds (0/1/124/144 still scored correctly), TC-CAF-002/003 cover genuine failures, TC-CAF-004/005 cover the new SIGTERM/SIGKILL exclusions, TC-CAF-007 covers a mixed-bag fixture.
- `tests/unit/test-mark-stalled-liveness.sh` (5 cases): TC-MSL-001/004/005 cover the alive-wrapper deferral path, TC-MSL-002/003 cover the dead-PID and missing-PID paths (existing behavior preserved). Uses a real spawned `sleep` for the alive case to avoid mocking `kill -0`.

## INV-27: Dev wrapper DEAD detection requires both pid_alive miss AND no near-success in-flight signal

**Rule**: The dispatcher's Step 5b dev-DEAD-no-PR branch MUST NOT post a "Task appears to have crashed (no PR found)" comment or flip `in-progress` → `pending-dev` on a bare `pid_alive` miss. It must additionally consult `dev_near_success` (in `lib-dispatch.sh`), which returns 0 (skip) when ANY of these in-flight signals are positive within `DEV_NEAR_SUCCESS_WINDOW_SECONDS` (default 300s):

1. Most recent `Agent Session Report (Dev) ... Exit code: 0` comment within window — agent already finished cleanly. PR-detection failure on the dispatcher side is NOT an agent failure; the trap that wrote the success report has authoritative knowledge.
2. Most recent `Dev Session ID:` comment within window — agent confirmed startup recently ([INV-21]); the `pid_alive` miss is overwhelmingly likely a transient probe race against a healthy wrapper.
3. Defensive `kill -0 <pid>` against the current PID-file content now succeeds — the original `pid_alive` miss raced with the wrapper's normal scheduling.

Only when ALL three signals are negative does the existing crashed-comment + label swap fire.

**Why**: The dev-side parity gap with [INV-24] (review-side) was the third axis of #121: a transient `pid_alive` miss reliably files a "Task crashed" comment, which the `count_dispatcher_crashes` counter accumulates against the retry budget. Combined with [INV-26]'s upstream gates (Fix A excluding SIGTERM, Fix C deferring on alive wrappers), INV-27 closes the producer of the false-crash comments before they enter the counter at all.

`DEV_NEAR_SUCCESS_WINDOW_SECONDS=0` disables the short-circuit (legacy strict behavior — every `pid_alive` miss declares crashed); non-numeric or negative falls back to legacy strict (parity with [INV-24]'s defensive numeric guard).

**Producer**: `lib-dispatch.sh::dev_near_success`, `latest_dev_success_age_seconds`, `latest_dev_session_id_age_seconds`.

**Consumer**: `dispatcher-tick.sh` Step 5b dev branch (kind=issue, no-PR sub-branch) — guards the crash comment + label swap behind `dev_near_success`.

**Cross-references**:
- [INV-24] is the review-side analog. Same shape, different signals (PR-state for review vs. agent-state for dev), same guarantee: every `pid_alive` miss must clear a near-success cross-check before declaring crashed.
- [INV-26] is the downstream gate that defers `mark_stalled` when a wrapper is alive. INV-27 prevents the false-crash comments that would have driven the counter to MAX_RETRIES; INV-26 catches anything that slips through. Together they close #121 across counter and decision surfaces.
- [INV-18] (dispatch grace period) is a coarser upstream gate that defers all of Step 5 stale detection during the cold-start window. INV-27 is the finer-grained successor that also covers post-grace transient races (e.g. a `claude --resume` SSE keepalive blip 15 minutes into a session).

**Status**: **ENFORCED** in this PR (closes #121 Fix B; #121 fully resolved with PR-1 + this PR).

**Disable knobs**:
- `DEV_NEAR_SUCCESS_WINDOW_SECONDS=0` — restores legacy strict (every `pid_alive` miss declares crashed). Useful for ops who hit edge cases.

**Test**:
- `tests/unit/test-dev-near-success.sh` (12 cases): TC-DNS-001..006 cover each signal independently (positive within window / stale / negative); TC-DNS-007/008 cover the disable knob and non-numeric fallback; TC-DNS-009 covers mixed-bag (any-signal-wins); TC-DNS-INT-001..003 statically pin the dispatcher-tick.sh placement before the crash comment with an INV-27 reference.

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
