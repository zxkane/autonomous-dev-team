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
- Mode: new|resume|startup-failure
- Agent: <agent-cli>
- Model: <model-id-or-<default>>
- Timestamp: <ISO-8601>
- Log: `/tmp/agent-${PROJECT_ID}-issue-<N>.log`
```

**Why**: Two consumers depend on parsing it. (a) The dispatcher's Step 4b session-id extraction anchors on `Dev Session ID:` (not just `Session ID:`) to avoid matching `Review Session:` trailers from the review wrapper. (b) The dispatcher's Step 4a retry counter counts comments matching both `Agent Session Report \(Dev\)` and `Exit code: 0` → not (i.e. non-zero exit).

**Note on Agent / Model fields (added 2026-05-15, #128)**: `Agent:` and
`Model:` are append-only, human-attribution metadata for multi-CLI
deployments where `AGENT_CMD` is rotated between rounds (claude → gemini
→ codex → opencode → kiro). They have **no** consumer parser today —
neither the Step 4a retry-counter regex nor the Step 4b session-id
extraction reads them. They live between the existing `- Mode:` and
`- Timestamp:` lines. The wrapper renders them via:

- `Agent: ${AGENT_CMD:-claude}` (colon-minus → renders `claude` for both
  unset and set-but-empty `AGENT_CMD`, matching `lib-agent.sh:41`'s own
  collapse-to-default).
- `Model: ${AGENT_DEV_MODEL:-<default>}` (colon-minus → renders
  `<default>` for both unset and set-but-empty `AGENT_DEV_MODEL`. This
  is the dominant operator-side case because `lib-agent.sh:42` defaults
  the variable to `""`).

**Producer**: `autonomous-dev.sh::cleanup` trap.
**Consumer**: dispatcher Step 4 (both 4a and 4b).
**Test**: `tests/unit/test-autonomous-dev-cleanup-startup-failure.sh` TC-CL-001 through TC-CL-008 + TC-CL-STATIC-001 (#128).

## INV-04: Reviewed-HEAD trailer format

**Rule**: The review wrapper, after a verdict comment is found, posts a separate issue comment matching this format:

```
Reviewed HEAD: `<sha>` (issue #<N>, session `<id>`, agent `<agent-cli>`, model `<model-id>`)
```

`<sha>` is the PR's `headRefOid` at prompt-build time. The trailer is a separate comment from the verdict (different gh issue comment call) so polling failures on the verdict don't suppress the trailer and vice versa.

**Why**: The dispatcher's Step 5b uses the trailer to skip redundant reviews when a dev wrapper exits with no new commits since the last review (#53). Without the trailer, every dev exit with a PR would cycle back through review even if the dev did nothing new.

**Note on agent / model fields (added 2026-05-15, #128)**: `agent` and
`model` are append-only, human-attribution metadata for multi-CLI
deployments. They have **no** consumer parser today. The dispatcher's
`last_reviewed_head` regex anchors on the leading
`Reviewed HEAD: \`<sha>\`` backtick-pair only — the trailing
parenthesised metadata is unparsed and unaffected by this addition.
The wrapper renders the model field via `${AGENT_REVIEW_MODEL}` directly
(no `:-<default>` fallback) because `lib-agent.sh:43` already defaults
the variable to `sonnet`; a wrapper-side fallback would render dead
code. The agent field uses `${AGENT_CMD:-claude}`, matching the dev
side and `lib-agent.sh:41`.

**Producer**: `autonomous-review.sh` (after verdict polling, before exit).
**Consumer**: dispatcher Step 5b DEAD-with-PR branch (regex: `Reviewed HEAD: \`(?<sha>[0-9a-f]{7,40})\``).
**Test**: `tests/unit/test-autonomous-review-reviewed-head-annotation.sh` TC-RHA-001 through TC-RHA-003 (#128).

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

**Rule**: Step 2's dependency check MUST treat both `CLOSED` and `MERGED` as resolved states. PRs return `MERGED` when merged, NOT `CLOSED`. The same `state ∉ {"CLOSED", "MERGED"}` rule applies to cross-repo refs resolved under [INV-39](#inv-39-dependency-parsing-is-list-item-scoped-and-supports-cross-repo-refs).

**Why**: When a `## Dependencies` section references a PR that has been merged, `gh issue view N --json state` returns `state: "MERGED"`. A naive `state != "CLOSED"` check leaves the dependent issue blocked forever (#61).

**Producer**: dispatcher Step 2 (`lib-dispatch.sh::check_deps_resolved`).
**Consumer**: itself.
**Status**: **ENFORCED** in PR-4 (closes #61). The check reads `state ∉ {"CLOSED", "MERGED"}` for both same-repo and cross-repo refs.
**Test**: `tests/unit/test-check-deps-resolved.sh` covers single-CLOSED, single-MERGED, single-OPEN, multi-dep mixed-state scenarios, and cross-repo MERGED/CLOSED/OPEN.

## INV-12: Resume only against unfinished sessions

**Rule**: The dispatcher's Step 4 MUST query the agent session's terminal state before issuing a resume, and treat both `terminal_reason == completed` and `terminal_reason == prompt_too_long` as terminal (skip resume).

**Why**:
- `end_turn|completed`: a `claude --resume` against a session whose final turn ended cleanly connects to the SSE streaming endpoint and never returns (#59).
- `*|prompt_too_long`: headless `claude -p` has no auto-compaction (the TUI's `/compact` is interactive-only). Resuming re-feeds the entire JSONL transcript, which is what blew the context window in the first place — guaranteed re-crash, infinite loop.

**Producer**: dispatcher Step 4 (`lib-dispatch.sh::is_session_completed` invoked from `dispatcher-tick.sh` Step 4). The helper writes the matched `terminal_reason` to a caller-provided var via `printf -v` so the caller can branch on the case.

**Consumer**: prevents the wrapper from being put in a hang state (completed) or a dispatch loop (prompt_too_long).

**Status**: **ENFORCED**. Closed cases:
- PR-6 (closes #59) — initial enforcement for `end_turn|completed`.
- PR (closes #128) — extends to `prompt_too_long`. The prompt-too-long branch posts an `INV-12-prompt-too-long:<sid>` notice, truncates the per-issue log, and `dispatch dev-new` to auto-recover with a fresh session.
- #152 (closes #149) — pairs the `completed` branch with [INV-35](#inv-35-review-aware-resume-routing-for-completed-sessions), which routes `completed`-with-review-failure cases to either re-review (non-substantive) or dev-new (substantive). The `INV-12-completed:<sid>` operator-handoff notice now fires only when the issue is `pending-dev` AND no review-failure verdict exists newer than the dev session's end-of-turn — the original "operator must decide" case (e.g. dev finished, no review ever ran). All other completed-session cases route through INV-35.

**Test**: `tests/unit/test-is-session-completed.sh` (14 cases), `tests/unit/test-autonomous-launcher-verdict-fresh.sh` TC-PTL-001..007d, and `tests/unit/test-handle-completed-session-routing.sh` + `tests/unit/test-classify-recent-review-verdict.sh` + `tests/unit/test-inv35-regression-2026-05-21.sh` for the INV-35 carve-out (per #149).

## INV-13: Wall-clock cap on agent invocations

**Rule**: `lib-agent.sh::run_agent` and `resume_agent` MUST wrap the underlying CLI call in `timeout --kill-after=30s --signal=TERM ${AGENT_TIMEOUT:-4h}` (with graceful fallback to `gtimeout` on macOS).

**Why**: Any of: SSE keepalive without stop event (#59 root cause), MCP server stdio deadlock, DNS/TCP black hole. Without a wall-clock cap, any of those can pin a wrapper for 8+ hours (#60).

**Producer**: `lib-agent.sh::run_agent` and `resume_agent` via the shared `_run_with_timeout` helper.
**Consumer**: prevents wrappers from monopolizing PID slots and quota.
**Status**: **ENFORCED** in PR-6 (closes #60). The helper resolves `timeout`/`gtimeout` once at source time and falls through to an unwrapped invocation with a one-time WARN log when neither is on PATH. All six AGENT_CMD branches (claude / codex / gemini / kiro / opencode / fallback) and both call sites (run_agent / resume_agent) get the same wrapper.
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

`autonomous.conf.example` documents this manifest in operator-facing form. **As of #153**, the helper script `skills/autonomous-common/scripts/install-project-hooks.sh` automates the symlink creation: for every `*.sh` shipped by `autonomous-dispatcher/scripts/`, it creates a project-side symlink (without overwriting real project-local files like `autonomous.conf` or `deploy.sh`), prunes dangling links if upstream removes a file, and re-runs are idempotent. Operators on this skill set should re-run after every `npx skills update` so newly-added upstream `lib-*.sh` files are picked up automatically — closes the silent-drift mode where `autonomous-review.sh` died on the first `source` of a missing lib because per-file `ln -s` lists didn't auto-sync.

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

**Per-agent amendment ([INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback), #166)**: when the wrapper fans out to more than one verdict-reaching agent (`AGENT_REVIEW_AGENTS` lists ≥2 CLIs), all N agents post under the SAME GitHub identity (token mode, or app mode sharing `REVIEW_AGENT_APP_ID`), so layers (a)+(b)+(c) match ALL N verdict comments and `last` would collapse them to one. The authenticity layer therefore becomes **per-agent**: each agent's prompt instructs it to emit a `Review Agent: <name>` discriminator line, and the wrapper runs ONE verdict query per agent adding a fourth predicate `body matches /Review Agent: <name>/`, taking `last` per agent. The `Review Session: <uuid>` trailer is still required (presence-only, per the rule above) and remains the `BOT_LOGIN`-empty fallback's narrowing key (now the *per-agent* session UUID). **N=1 carve-out**: when `AGENT_REVIEW_AGENTS` is empty/unset, there is exactly one agent and one query; the added `Review Agent:` predicate is satisfied by the lone agent's discriminator and does not change routing — the single-agent verdict binding is byte-for-byte the pre-#166 behavior.

**Why**: The prior body-text predicate `Review Session.*${SESSION_ID}` depended on the agent echoing the wrapper's UUID verbatim. Agents under context pressure occasionally rewrote the UUID, causing the wrapper to miss valid verdicts and force the FAILED branch. Combined with a same-PR / same-issue dispatcher state machine, this produced infinite dev↔review ping-pong loops on the consumer side. Trailer-presence (without UUID binding) keeps spoof protection intact in `GH_AUTH_MODE=token` (where dev and review wrappers share BOT_LOGIN — the dev agent's prompts don't instruct it to emit `Review Session:`, so its status comments are excluded) without the brittleness.

**Producer**: `autonomous-review.sh` polling loop. Captures `WRAPPER_START_TS` once before `run_agent` (ISO-8601 UTC) and `BOT_LOGIN` once via `gh api user --jq .login` (treats empty / errored / literal-`"null"` as unset).

**Consumer**: prevents (a) verdict regressions when the agent rewrites the trailer UUID, (b) cross-wrapper spoofing in same-identity (token) mode, (c) stale verdicts from prior ticks being picked up.

**Fallback**: when `BOT_LOGIN` is unset, the predicate becomes `(createdAt >= WRAPPER_START_TS) AND (body matches /Review Session.*<SESSION_ID>/)`. This re-introduces the brittleness only on the rare path where actor binding is unavailable, and time-window predicate still narrows out stale comments.

**Status**: **ENFORCED**. Originally replaced the prior session-id-only binding (which closed #95 phrasing-drift but did not address the UUID-rewrite drift). Amended in #166 to add the per-agent `Review Agent: <name>` layer for multi-agent fan-out ([INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)); the N=1 single-agent binding is unchanged.

**Test**: `tests/unit/test-autonomous-launcher-verdict-fresh.sh` TC-VRD-001..009a (12 cases including token-mode dev-agent quoted-verdict anti-spoof). The per-agent `Review Agent:` discriminator amendment is covered by `tests/unit/test-autonomous-review-prompt.sh` TC-ARP-06 and `tests/unit/test-autonomous-review-multi-agent.sh` TC-MAR-SRC-10.

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

**Defence in depth (option C)**: `kill_stale_wrapper` additionally runs `pgrep -f` against a regex anchored on `${PROJECT_DIR}/scripts/autonomous-(dev|review)\.sh.*--issue ${ISSUE_NUM}\b` (per [INV-28](#inv-28-pgrep-fallback-must-be-scoped-by-project-and-wrapper-type)) and group-kills any matches not reachable through PID_FILE. Catches escaped trees from pre-fix wrappers and races between `acquire_pid_guard` and `_run_with_timeout` overwriting PID_FILE. Operators can disable via `KILL_STALE_PGREP_FALLBACK=false` if the heuristic over-matches.

**Fallback when setsid is missing**: `_run_with_timeout` falls back to a non-setsid background spawn (defensive: the dispatcher fleet is Linux/Ubuntu and util-linux is universal there; macOS operators get setsid via Homebrew). In that mode the agent runs in the wrapper's process group; `kill_stale_wrapper`'s pgrep fallback still picks up orphans, with degraded — but not broken — atomicity.

**Status**: **ENFORCED** in this PR (closes #109).

**Test**:
- `tests/unit/test-pid-guard-pgid.sh` (18 cases) — TC-PGID-001 (new session under setsid), TC-PGID-002+004 (group-kill reaps grandchildren), TC-PGID-005 (pgrep fallback), TC-PGID-008/009 (`AGENT_PID_FILE` write contract), plus TC-STATIC-001..006 for source-of-truth.
- `tests/unit/test-sigterm-trap.sh` updated to accept either inline `on_sigterm` or `install_agent_sigterm_trap` factoring.

## INV-24: Review wrapper DEAD detection requires both pid_alive miss AND no near-success PR signal

**Rule**: The dispatcher's Step 5b review-DEAD branch MUST NOT post a "Review process appears to have crashed" comment or flip `reviewing` → `pending-dev` on a bare `pid_alive` miss. It must additionally consult `review_near_success` (in `lib-dispatch.sh`), which returns 0 (skip) when ANY of these signals are positive within `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS` (default 300s):

1. `PR.mergedAt` within the window — wrapper is finishing the merge step.
2. Most recent `APPROVED` review event within the window — wrapper has reached approve step.
3. Most recent `^Review (PASSED|findings)` comment within the window — wrapper completed verdict, may be merging or just exiting normally.
4. Defensive `kill -0 <pid>` against the current PID-file content now succeeds — the original `pid_alive` miss raced with the wrapper's normal scheduling.
5. Process-group walk (#132): the review wrapper's PGID — equal to the content of `review-${ISSUE}.pid` because `_run_with_timeout`'s `setsid` makes the session-leader PID == PGID — has at least one descendant whose `comm` matches `AGENT_CMD`. Implemented in `_pgid_has_agent_process` (renamed from `_review_pgid_has_agent_process` in #137 once the dev side gained a parity signal) via `pgrep -g <pgid>` + `ps -o comm= -p <pid>`; tolerant of Linux's 15-char `comm` truncation via substring match. Skipped silently when PID file is empty / unparseable, or when `pgrep`/`ps` are absent on the host — never fail-closed.

Only when ALL five signals are negative does the existing crash + label-swap fire.

**Note on signal 5 (added 2026-05-16, #132)**: Signals 1–4 cover wrappers that have produced an externally visible state change (PR merged / APPROVED review submitted / verdict comment posted / live PID-file PID). They do not cover the gap between "review wrapper is processing" and "review wrapper has emitted its first artifact" — empirically 5–15 min for E2E + multi-bot rounds + line-by-line review. Reproduced on a downstream consumer's #209 (2026-05-15 16:00:39Z): `pid_alive` triple miss (kill -0 / PID-file mtime / heartbeat sibling mtime all stale), four PR-state signals all negative, declare crashed → `reviewing → pending-dev`; 4 minutes later the same wrapper posted its verdict + APPROVED + merged the PR. Signal 5 is additive — never replaces an existing positive signal — and runs last in the cost-ordered chain so the happy path is unchanged. Ordering is pinned by TC-RNS-009.

**Note on remote backend (added 2026-05-17, #137)**: under `EXECUTION_BACKEND=remote-aws-ssm`, signals 4 and 5 fire on the dispatcher box and find nothing (the wrapper's PID is on a different box). Both signals are short-circuited upstream by [INV-30]'s remote `pid_alive` query that reaches the wrapper box via SSM and returns ALIVE / DEAD / indeterminate before any near-success evaluation runs. The local-only signals 4 and 5 here remain the primary defense for `EXECUTION_BACKEND=local` deployments and a defense-in-depth path for the rare case where [INV-30]'s remote query is indeterminate.

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
- `tests/unit/test-dispatcher-review-near-success.sh` (15 cases as of #132) — TC-RNS-001..004 cover each legacy signal positive; TC-RNS-005 covers all signals negative (crash path still fires); TC-RNS-006 covers the `=0` legacy strict knob; TC-RNS-007..011 (#132) cover the process-group signal: alone-positive (007), all-five-negative (008), legacy-positive-short-circuits-before-pgrep (009 ordering pin), strict-knob-overrides-pgrep (010), empty-PID-skips-pgrep-silently (011 defensive guard).
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
- [INV-30] (`pid_alive` authoritative under all execution backends) — `mark_stalled`'s `pid_alive` call inherits remote-backend awareness automatically: when `EXECUTION_BACKEND=remote-aws-ssm`, the SSM-driven liveness query reaches the wrapper box directly. No code change to `mark_stalled` itself was required for #137. (Verified by TC-RPA-007 in `tests/unit/test-pid-alive-remote-aws-ssm.sh`.)

**Status**: **ENFORCED** in this PR (closes #121 Fix A + Fix C; Fix B / `dev_near_success` is a separate follow-up PR).

**Tests**:
- `tests/unit/test-count-agent-failures-sigterm.sh` (7 cases): TC-CAF-001/006/007 cover regression bounds (0/1/124/144 still scored correctly), TC-CAF-002/003 cover genuine failures, TC-CAF-004/005 cover the new SIGTERM/SIGKILL exclusions, TC-CAF-007 covers a mixed-bag fixture.
- `tests/unit/test-mark-stalled-liveness.sh` (5 cases): TC-MSL-001/004/005 cover the alive-wrapper deferral path, TC-MSL-002/003 cover the dead-PID and missing-PID paths (existing behavior preserved). Uses a real spawned `sleep` for the alive case to avoid mocking `kill -0`.

## INV-27: Dev wrapper DEAD detection requires both pid_alive miss AND no near-success in-flight signal

**Rule**: The dispatcher's Step 5b dev-DEAD-no-PR branch MUST NOT post a "Task appears to have crashed (no PR found)" comment or flip `in-progress` → `pending-dev` on a bare `pid_alive` miss. It must additionally consult `dev_near_success` (in `lib-dispatch.sh`), which returns 0 (skip) when ANY of these in-flight signals are positive within `DEV_NEAR_SUCCESS_WINDOW_SECONDS` (default 300s):

1. Most recent `Agent Session Report (Dev) ... Exit code: 0` comment within window — agent already finished cleanly. PR-detection failure on the dispatcher side is NOT an agent failure; the trap that wrote the success report has authoritative knowledge.
2. Most recent `Dev Session ID:` comment within window — agent confirmed startup recently ([INV-21]); the `pid_alive` miss is overwhelmingly likely a transient probe race against a healthy wrapper.
3. Defensive `kill -0 <pid>` against the current PID-file content now succeeds — the original `pid_alive` miss raced with the wrapper's normal scheduling.
4. Process-group walk (`_pgid_has_agent_process <pgid>`) finds an `AGENT_CMD` descendant under the wrapper's PGID. Catches the gap reproduced on a downstream consumer's #182 (long-running TDD agent SIGTERMed by `kill_stale_wrapper` before it could emit any artifact): signals 1+2 are timestamp-based and miss when the agent never produced a comment, signal 3 misses when the session-leader PID drifts out of `kill -0` reachability under launcher indirection, but the PGID walk catches a live agent subtree.

Only when ALL four signals are negative does the existing crashed-comment + label swap fire.

**Note on signal 4 (added 2026-05-17, #137)**: parity with [INV-24] signal 5 added in #132. Both sides now share `_pgid_has_agent_process` (renamed from `_review_pgid_has_agent_process`). Under `EXECUTION_BACKEND=remote-aws-ssm` ([INV-30]), `_pgid_has_agent_process` runs on the dispatcher box and finds nothing because the wrapper is on a different box — that case is handled by [INV-30]'s remote `pid_alive` short-circuit before any near-success evaluation runs; signal 4 is the local-backend defense and a defense-in-depth path for the rare case where [INV-30]'s remote query is indeterminate AND the legacy comment-timestamp signals also miss.

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

## INV-28: pgrep fallback must be scoped by project AND wrapper type

**Rule**: `dispatch-local.sh::kill_stale_wrapper`'s `pgrep -f` defence-in-depth (the [INV-23] "option C" fallback) MUST scope its match on three independent axes:

1. **Project**: anchor on `${PROJECT_DIR}/scripts/`. Multiple autonomous projects can run on the same host with overlapping issue numbers; a regex without this anchor cross-kills wrappers across projects.
2. **Wrapper type**: `dev-new` / `dev-resume` dispatch only matches `autonomous-dev.sh`; `review` only matches `autonomous-review.sh`. The two wrapper scripts have disjoint names and disjoint PID-file paths (`issue-N.pid` vs `review-N.pid`); the pgrep fallback must respect the same separation.
3. **Issue**: `--issue <N>` with a `\b` word boundary so issue 9 doesn't match issue 99.

`PROJECT_DIR` MUST be regex-quoted before composition into the pattern (e.g. via `sed 's|[][\\.*^$+?(){}|]|\\&|g'`), so an operator path containing `.`, `+`, `(`, etc. doesn't silently widen the match set.

**Why**: Pre-fix the matcher was `[-]-issue ${ISSUE_NUM}\b` only — type-agnostic and project-agnostic. Two distinct loops resulted:

- **Cross-type loop (#126)**: a live `autonomous-review.sh` wrapper (>5 min CLI run) racing a transient `pid_alive review` miss caused `dispatcher-tick.sh` to flip `reviewing` → `pending-dev`. The next tick dispatched `dev-resume`, whose `kill_stale_wrapper` then SIGTERMed the still-alive review wrapper in its verdict-posting window. Net effect: ~$1 of sonnet-1M time per cycle wasted with zero actionable output. The `review_near_success` defence ([INV-24]) was upstream of this kill — it gates the `pid_alive` *miss interpretation*, not the cross-type kill that follows the label flip.
- **Cross-project amplification**: on a multi-project dispatcher box (the operator's actual topology runs 5+ projects against the same host), any two projects whose issue numbers happen to overlap cross-killed each other on every dispatch. Type-scope alone is necessary but not sufficient — every project has its own `autonomous-dev.sh` copy.

**Producer**: `dispatch-local.sh::kill_stale_wrapper` (the only consumer of the regex).

**Consumer**: same — the regex is private to the function. Other actors (`acquire_pid_guard`, the wrappers' SIGTERM trap) reach orphans through PID_FILE per [INV-23]'s primary path; the pgrep fallback is reached only when PID_FILE misses.

**Operator override**: `KILL_STALE_PGREP_FALLBACK=false` still bypasses the entire fallback block — INV-28 narrows the *match set* when the fallback runs, not its on/off semantics.

**Status**: **ENFORCED** in this PR (closes #126).

**Test**:
- `tests/unit/test-dispatch-local-pgrep-type-scope.sh` (21 cases): TC-REGEX-001..005 pin the script_re shape per TYPE plus PROJECT_DIR regex-quoting; TC-PGREP-001/002 are the cross-type regression for #126 (dev-resume must not kill live review wrapper, and vice versa); TC-PGREP-003 confirms same-type/same-project orphans are still group-killed (no regression of #109's [INV-23]); TC-PGREP-004 preserves the issue-9-vs-99 word boundary; TC-PGREP-005 is the cross-project regression (proj-A dispatch must not kill proj-B wrapper); TC-DISABLE-001 confirms `KILL_STALE_PGREP_FALLBACK=false` still fully bypasses; TC-STATIC-001/002 grep-pin the regex shape and `INV-28` reference in source.
- `tests/unit/test-pid-guard-pgid.sh::TC-PGID-005` updated: the fake escaped tree is now placed under `${PROJECT_DIR}/scripts/autonomous-dev.sh` and `TYPE=dev-resume` is set so the project-anchored regex matches it.

**Cross-references**:
- [INV-23] (PID_FILE reaps subtree) is the primary path; INV-28 narrows the option-C fallback's match set.
- [INV-24] (review-side near-success short-circuit) and [INV-27] (dev-side near-success) sit upstream of the label flip that triggers the cross-type kill described in #126's reproduction. They reduce frequency; INV-28 closes the cross-kill bug regardless of how the label flip was reached.
- [INV-26] (stall decision excludes dispatcher-induced terminations + defers on live wrappers) reduces the residue created when `kill_stale_wrapper` itself fires. INV-28 prevents the *wrong* kills that caused the residue in the first place.

## INV-29: pid_alive heartbeat is owned exclusively by the wrapper, NOT by the PID file alone

**Rule**: Two conjunct sub-rules.

1. **Wrapper-side**: `lib-agent.sh::install_agent_heartbeat` MUST maintain a sibling heartbeat file at `${AGENT_PID_FILE%.pid}.heartbeat`, in addition to touching `AGENT_PID_FILE` itself. The sibling is created if missing and `touch`'d every `HEARTBEAT_INTERVAL_SECONDS` (default 120s). The wrapper's `cleanup` trap removes BOTH files at exit. The heartbeat loop re-checks parent liveness (`kill -0 <parent_pid>`) immediately before each `touch`, so a parent that exited during the loop's `sleep` cannot get either file resurrected after the cleanup trap deleted them — this closes the post-exit ALIVE-window race that would otherwise persist for up to `HEARTBEAT_INTERVAL_SECONDS * 3`.
2. **Dispatcher-side**: `lib-dispatch.sh::pid_alive` mtime fallback MUST consult EITHER file's mtime — ALIVE if either is fresh within `HEARTBEAT_INTERVAL_SECONDS * 3` (default 360s), DEAD only when both are stale (or both are absent). Symmetrically, `dispatch-local.sh::kill_stale_wrapper` MUST NOT delete the PID file when its `kill -0 <old_pid>` returned failure (i.e. nothing was actually killed) and MUST NEVER touch the heartbeat sibling. The PID file is deleted only when (a) we successfully signalled an alive holder, or (b) the file content is empty / non-numeric.

**Why**: A long-running healthy `autonomous-dev` wrapper (~70+ min real run) was repeatedly classified DEAD by `pid_alive`, exhausting `MAX_RETRIES`, and `mark_stalled` fired despite continuous progress. Reproduced on a downstream consumer's #N-class issue 2026-05-13. The cascade:

- The agent-tree session leader's PID drifted out of `kill -0` reachability while the underlying process group was still ticking (observed under `AGENT_LAUNCHER='bash -c "source ~/.bash_aliases && cc \"$@\"' --'` indirection, where the launcher's outer `bash -c` exited after the agent had been backgrounded by `_run_with_timeout`).
- Pre-fix, `kill_stale_wrapper`'s `rm -f "$pid_file"` ran unconditionally — even on the `kill -0` miss path where nothing was actually killed (literal inline comment "Remove PID file regardless" was the bug).
- The wrapper's heartbeat loop then had no file to refresh (the `[[ -f "$pid_file" ]]` guard at `lib-agent.sh::install_agent_heartbeat` no-op'd), so the dispatcher's `pid_alive` mtime fallback (#111 Part B / [INV-24]) saw nothing to consult.
- Each subsequent tick re-rolled the false DEAD verdict, accumulating dispatcher-detected crash comments. [INV-26] would have deferred `mark_stalled` had `pid_alive` reported ALIVE — but it didn't, exactly because the heartbeat carrier was gone.
- After `MAX_RETRIES` ticks the issue was `+stalled` while the real wrapper continued, eventually opened a successful PR, and the trap tried to flip `in-progress` → `pending-review` onto a `+stalled` issue ([INV-25] residue).

The two sub-rules close the loop independently: rule (1) gives `pid_alive` an owner-isolated heartbeat that survives any `kill_stale_wrapper` change; rule (2) prevents the wrong deletion in the first place. Either alone is sufficient to fix the reported scenario; both together are defence-in-depth and protect against future regressions of either side.

**Producer**:
- (1) `lib-agent.sh::install_agent_heartbeat` (writes the sibling); `autonomous-dev.sh::cleanup` and `autonomous-review.sh::cleanup` (remove both files at exit).
- (2) `dispatch-local.sh::kill_stale_wrapper` (preserves the PID file on `kill -0` miss; never references the heartbeat sibling).

**Consumer**: `lib-dispatch.sh::pid_alive` (three-tier check: kill -0 → PID-file mtime → heartbeat-sibling mtime). The heartbeat sibling is also implicitly consumed by [INV-26]'s liveness deferral, [INV-24]'s defensive `kill -0` re-check, and [INV-27]'s defensive `kill -0` re-check — each is unaffected when the agent's session-leader PID still answers `kill -0`, and each falls through to `pid_alive` when it doesn't.

**Disable knobs**:
- `HEARTBEAT_INTERVAL_SECONDS=0` — disables BOTH the wrapper-side heartbeat spawn (no PID-file or sibling refresh) AND the dispatcher-side mtime fallback. Restores the `kill -0`-only legacy behavior.

**Status**: **ENFORCED** in this PR (closes #129).

**Test**:
- `tests/unit/test-pid-alive-long-running.sh` (18 cases): TC-PALR-001 / 002 / 002b cover `kill_stale_wrapper`'s deletion policy (preserve on miss; delete on hit; delete on empty-content); TC-PALR-003 / 003b / 004 / 004b cover `pid_alive`'s three-tier decision matrix including the #129 repro (PID file gone but sibling fresh → ALIVE); TC-PALR-005 / 005b cover heartbeat sibling creation + refresh; TC-PALR-005c is the resurrection-race regression (heartbeat does NOT recreate the files after the parent's cleanup trap deleted them); TC-PALR-STATIC-001 / 002 pin the INV-29 cross-references and that `kill_stale_wrapper` does not reference `*.heartbeat`.
- `tests/unit/test-kill-before-spawn.sh::TC-DKBS-003` updated to reflect the new contract: the dead-PID `kill -0` miss path now PRESERVES the PID file rather than deleting it.

**Cross-references**:
- [INV-01] (PID file naming) — the heartbeat sibling lives in the same per-user, mode-0700 dir as the PID file. Same CWE-377 protection; the sibling's path is mechanically derived (`%.pid` strip + `.heartbeat` append) so [INV-01]'s naming guarantees transitively cover it.
- [INV-23] (PID_FILE reaps subtree) — the primary kill path is unchanged; INV-29 only narrows what `kill_stale_wrapper` deletes after that path runs, and adds a parallel liveness-carrier file.
- [INV-24] / [INV-27] (review / dev near-success short-circuits) — these gate `pid_alive` *miss interpretation*. INV-29 makes `pid_alive` itself correct on the failure mode where the agent is truly alive but `kill -0` misses, so the upstream gates are no longer the only safety net.
- [INV-26] (stall decision deferral on live wrappers) — relies on `pid_alive` returning ALIVE for genuinely-alive wrappers. INV-29 closes the producer-side gap that pre-fix could feed it a false DEAD.
- [INV-25] (sticky terminal labels with hygiene at tick start) — heals residue from rare cases where the stall decision still slips through. INV-29 reduces the producer of that residue; [INV-25]'s hygiene pass remains the safety net.

## INV-30: `pid_alive` is authoritative under all execution backends

**Rule**: under any non-`local` `EXECUTION_BACKEND`, `pid_alive` MUST consult a backend-specific liveness transport (today: `liveness-check-remote-aws-ssm.sh`) before any local probe. The transport runs the equivalent of [INV-29]'s three-tier check (kill -0, PID-file mtime, heartbeat sibling mtime) on the box where the wrapper actually lives, not on the dispatcher box.

The transport's stdout is one of `ALIVE` / `DEAD` / empty. Indeterminate verdicts (transport fault, timeout, garbled stdout, instance offline) MUST bias toward ALIVE — the dispatcher's `pid_alive` returns 0 (alive), the caller defers crash declaration by one tick, and the next tick retries. **Indeterminate MUST NOT surface as DEAD**.

**Why**: under remote backend (e.g. `EXECUTION_BACKEND=remote-aws-ssm`), the dispatcher's box doesn't have the wrapper's PID file or heartbeat sibling — they live on the wrapper box. The legacy three-tier check ([INV-29]) always misses there, so `pid_alive` returns DEAD on every tick. Combined with [INV-27]'s near-success backstops being timestamp-based and missing during the cold-start window before the agent emits any artifact, every tick declares crashed → six `count_dispatcher_crashes` → `mark_stalled` on a wrapper that's still doing real work. Reproduced on a downstream consumer's #182 (2026-05-16 02:15–04:10 UTC): six "Task appears to have crashed (no PR found)" comments at 5-min cron intervals, sixth wrapper SIGTERMed by `kill_stale_wrapper` 4 seconds after spawn (Session Report: exit 143), marked stalled at 04:10. The session that actually completed (PR opened at 05:21Z) ran outside the dispatcher's reach because `stalled` issues are skipped — "stalled label saved it from the dispatcher" was the user's apt summary.

**Conservative bias rationale**: when the transport can't give a definitive verdict, two error directions are possible:
- (a) Treat unknown as DEAD → false crash comments + premature stall (the bug being fixed). Recovery: manual `gh issue edit --remove-label stalled`. High operator cost.
- (b) Treat unknown as ALIVE → real crashes get delayed detection by 1+ ticks until the transport recovers. Recovery: automatic on the next successful tick. Low operator cost.

(b) is recoverable; (a) is not. INV-30 chooses (b). A `_REMOTE_LIVENESS_DEGRADED_COUNT` per-process counter records consecutive indeterminate verdicts; `pid_alive` emits a stderr WARN on count=1 and every count%10==0 thereafter so operators see degradation without per-tick log spam.

**Producer**: `lib-dispatch.sh::pid_alive` (extended); `lib-dispatch.sh::_remote_pid_alive_query`; `liveness-check-remote-aws-ssm.sh`; `lib-ssm.sh::_ssm_run_remote_command`.

**Consumer**: every Step 5 branch in `dispatcher-tick.sh` and `mark_stalled`'s liveness deferral ([INV-26]) — both inherit remote awareness automatically through the unified `pid_alive` interface.

**Disable knobs**:
- `REMOTE_LIVENESS_CHECK_DISABLE=true` — falls back to legacy local-only `pid_alive` even under remote backend (operator escape hatch for transport-blocked deployments).
- `REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS=N` — dispatcher-side polling cap (default 8s).
- `SSM_COMMAND_TIMEOUT_SECONDS=N` — SSM-side cap on the remote shell command (default 10s).

**Cross-references**:
- [INV-23] (PID_FILE reaps subtree) — same setsid PGID semantics; the remote snippet uses `kill -0 <pgid>` and `pgrep -g <pgid>` against the wrapper-box PID file content.
- [INV-26] (stall decision deferral on live wrappers) — `mark_stalled` calls `pid_alive` first; under remote backend that call inherits the remote query automatically. No code change to `mark_stalled` itself was required.
- [INV-27] (dev DEAD detection requires near-success cross-check) and [INV-24] (review-side analog) — under remote backend these run on the dispatcher box and only see local/comment signals; INV-30's remote `pid_alive` short-circuits before they're consulted on the happy ALIVE/DEAD path. They remain the local-backend defense and a defense-in-depth path when the remote query is indeterminate.
- [INV-29] (heartbeat sibling owned by wrapper) — INV-30's remote snippet implements the same three-tier check (kill -0, PID-file mtime, heartbeat sibling mtime), just on the wrapper box.

**Note on update-ordering for split-box deployments**: dispatcher-side and wrapper-side skill copies CAN be refreshed independently because they only share the on-disk PID-file path schema (`${XDG_RUNTIME_DIR:-$HOME/.local/state}/autonomous-${PROJECT_ID}/${kind}-${N}.pid`), which has been stable since [INV-29]. New dispatcher with old wrapper: the remote snippet still finds the PID file at the expected path and returns an accurate verdict. New wrapper with old dispatcher: the old `pid_alive` falls through to the legacy three-tier and (under remote backend) misses as it did before this PR — no regression vs status quo.

**Status**: **ENFORCED** in this PR (closes #137; reproduces and fixes a downstream consumer's #182).

**Test**:
- `tests/unit/test-pid-alive-remote-aws-ssm.sh` (13 cases) — TC-RPA-001..010 cover ALIVE / DEAD / indeterminate / EXECUTION_BACKEND=local no-call regression / `REMOTE_LIVENESS_CHECK_DISABLE=true` / missing env / `mark_stalled` integration / WARN-counter modulo / source-of-truth grep on the indeterminate→ALIVE branch (load-bearing).
- `tests/unit/test-liveness-check-remote-aws-ssm.sh` (28 cases) — TC-LCS-001..011 cover the SSM driver in isolation with stubbed `aws`.
- `tests/unit/test-lib-ssm.sh` (26 cases) — TC-LSSM-001..006 cover the shared SSM helpers extracted from `dispatch-remote-aws-ssm.sh`.

**Cross-reference**: [`docs/pipeline/remote-backend.md`](remote-backend.md) for the full backend-interface contract.

## INV-31: Operator-tunable per-CLI flags live in conf, not in `lib-agent.sh`

**Rule**: `lib-agent.sh` MUST NOT hardcode operator-tunable safety / output-format flags inside per-CLI `case` branches. The two passthrough vars — `AGENT_DEV_EXTRA_ARGS` (consumed by `run_agent`) and `AGENT_REVIEW_EXTRA_ARGS` (consumed by `resume_agent`) — are tokenized at call time by `_parse_extra_args` and appended verbatim after the structural arguments (and before the prompt positional) of every case branch. Defaults are empty strings.

**Scope**: "operator-tunable" = flags whose correct value depends on deployment environment (auth model, sandbox posture, debug needs) rather than on the CLI invocation contract. **Structural** flags — `--session-id` / `--resume` / `--model` / `exec --json` / `run --format json` / `--agent` / `--no-interactive` / `chat` / `-p` / `--output-format json` (claude) / `--permission-mode` (claude, mapped 1:1 from `AGENT_PERMISSION_MODE`) — remain hardcoded because they encode the CLI's expected invocation shape, not operator policy.

**Why**: Pre-#140, gemini's `--approval-mode yolo --output-format stream-json` and kiro's conditional `--trust-all-tools` lived in `lib-agent.sh` case branches. Both were operationally load-bearing — without them, gemini and kiro silently fabricate success at exit 0 (the #102 R2 / R5 failure modes, originally fixed in #134 / #135 and #136 / #139 respectively). But that placement meant adding a new CLI, or a new debug flag for an existing CLI, required a wrapper PR + `npx skills update` on every operator's box. INV-31 demotes that responsibility to operator conf so the wrapper code stops being the choke point.

**Migration semantics**: gemini and kiro deployments that pulled #140 without updating `autonomous.conf` reproduce the original #102 fabrication failure mode. The migration callout at the top of `autonomous.conf.example` and the per-CLI EXTRA_ARGS blocks are the operator-facing artifacts; the README "Multi-CLI support matrix" reinforces the requirement.

**Tokenization trust**: `_parse_extra_args` uses `eval` (same trust model as `AGENT_LAUNCHER` per [INV-22](#inv-22-agent_launcher-tokenization--claude-only-invocation-contract)) so quoted multi-word values survive intact (`AGENT_DEV_EXTRA_ARGS='--policy "/path with spaces/policy.json"'`). Bare `read -ra` does not honor those quotes.

**Producer**: `lib-agent.sh::run_agent` and `lib-agent.sh::resume_agent`. Each of the 5 case branches MUST append `"${extra_args[@]}"` to the agent argv between structural args and the prompt positional. The generic `*` fallback also appends. `_parse_extra_args` is invoked once per call (top of the function body) so the array is in scope of each case branch.

**Consumer**: every CLI invocation. The agent CLI receives the operator's flags as part of its argv.

**Status**: **ENFORCED** in this PR (closes #140; closes #102 by collapsing the multi-CLI test conclusions into a self-service framework).

**Test**: `tests/unit/test-lib-agent-extra-args.sh` (TC-EXTRA-001..010, 31 assertions) — including:
- TC-EXTRA-002 / TC-EXTRA-004: regression-pin demotion via comment-stripped grep on `lib-agent.sh` executable lines (no `--approval-mode yolo` / `--output-format stream-json` / `--trust-all-tools` outside `#` comments).
- TC-EXTRA-007: structural flags preserved across all 5 CLIs.
- TC-EXTRA-008: shell-quoting honors paths with spaces.
- TC-EXTRA-009: empty/unset → no leftover empty-string elements in argv.
- TC-EXTRA-010: backward-compat by-design — gemini/kiro w/o EXTRA_ARGS produce wrapper invocations omitting the demoted flags, reproducing the #102 R2/R5 failure mode (the migration is operator-driven).

Plus the existing `test-lib-agent-gemini.sh` (22 assertions) and `test-lib-agent-kiro-permission.sh` (16 assertions) updated to assert the post-#140 structural-only contract on the gemini and kiro branches.

## INV-32: gh wrapper is installed on two paths: shared scripts/gh for the agent, per-run PATH dir for the wrapper

**Rule**: `setup_github_auth` in `lib-auth.sh` MUST, regardless of
`GH_AUTH_MODE`, install the `gh-with-token-refresh.sh` wrapper for **both** of
its consumers, on **two distinct paths**:

1. **Agent path** — create the `${_LIB_AUTH_DIR}/gh` symlink (i.e.
   `${PROJECT_DIR}/scripts/gh`) pointing at `gh-with-token-refresh.sh`. This
   is a **stable, shared, project-level** artifact. It MUST be created
   **idempotently AND atomically** — NOT a bare `ln -sf`, which unlinks the
   existing symlink before recreating it, leaving a window where a concurrent
   run's `bash scripts/gh …` observes no file. Build the symlink under a unique
   temp name in `${_LIB_AUTH_DIR}` then `mv -f` it into place; `rename(2)` is
   atomic, so the shared path is never momentarily absent for concurrent
   readers. It MUST **NOT** be removed by `cleanup_github_auth` (a per-run
   cleanup must never delete a shared artifact a concurrent run depends on).
   `${_LIB_AUTH_DIR}` MUST be absolute (asserted at source time): the
   `/tmp`-resident per-run `gh` symlink's target is `${_LIB_AUTH_DIR}/...`, so
   a relative value would resolve relative to `/tmp` and dangle.

2. **Wrapper path** — create a **per-run** directory
   `GH_WRAPPER_DIR=/tmp/agent-auth-XXXXXX` (mode 700), drop a `gh` symlink in
   it (a bare `ln -sf` is fine here — the dir is private to this run), and
   prepend `GH_WRAPPER_DIR` (NOT `_LIB_AUTH_DIR`) to `PATH`. App mode reuses
   the token daemon's `mktemp -d` dir as `GH_WRAPPER_DIR`; token mode creates
   it on demand. `cleanup_github_auth` removes `GH_WRAPPER_DIR` (guarded on the
   `/tmp/agent-auth-*` prefix) together with the token file, then MUST **reset
   the module state it tore down** — clear `GH_WRAPPER_DIR`, `GH_TOKEN_FILE`,
   and `TOKEN_DAEMON_PID` to empty. Otherwise a second `setup_github_auth` in
   the **same shell** (persistent test runners, consecutive tasks) sees
   `GH_WRAPPER_DIR` still set, `_ensure_gh_wrapper_dir` skips the `mktemp`, and
   the token file + per-run `gh` symlink point into the directory cleanup just
   `rm -rf`'d. The reset makes `setup → cleanup → setup` idempotent within one
   process.

Both `app` and `token` modes must produce a working `scripts/gh` invocation
(consumer 1) AND a working PATH-resolved `gh` (consumer 2).

**Why**: there are two consumers of "the `gh` wrapper" and they resolve it by
different mechanisms:

- **The agent** invokes `bash scripts/gh issue comment …` — a uniform rule
  prescribed by `skills/autonomous-dev/SKILL.md` Step 12 and
  `skills/autonomous-dev/references/autonomous-mode.md` "Posting Issue/PR
  Comments". This is a **relative-path** invocation from `$PROJECT_DIR` (the
  wrapper does `cd "$PROJECT_DIR"`), NOT a PATH lookup — the explicit path
  forces resolution through the project-vendored wrapper symlink, sidestepping
  the agent's Bash tool's unreliable PATH-resolution for `gh` (the bug fixed
  by #142). So the physical file `${PROJECT_DIR}/scripts/gh` must exist.

- **The wrapper itself** (`autonomous-dev.sh` / `autonomous-review.sh`) issues
  bare `gh issue edit`, `gh pr comment`, etc. that resolve through **`PATH`**.

Pre-#163, BOTH consumers were served by the single shared `${_LIB_AUTH_DIR}/gh`
symlink, which `setup` created and `cleanup` `rm -f`'d. Because that path is
shared across concurrent runs on the same host, one run's `cleanup_github_auth`
deleted the symlink another run was mid-using — the surviving run's next bare
`gh` then failed with `scripts/gh: No such file or directory`, silently
breaking its post-agent label update and session-report comment. #163 splits
the two consumers onto two paths: the wrapper's PATH `gh` moves into a per-run
`/tmp` dir (isolated, cleaned up per-run), while the agent's `scripts/gh` stays
put, is created idempotently, and is never deleted by a per-run cleanup.

The wrapper itself (`gh-with-token-refresh.sh`) is mode-agnostic — it consults
`GH_TOKEN_FILE` (a per-process env var) only when set (app mode) and otherwise
exec's the real `gh` inheriting the host's auth env (which IS the intended
identity in token mode). Two runs pointing `scripts/gh` at the same fixed
target is therefore harmless: each carries its own `GH_TOKEN_FILE`/`REAL_GH`.

**Producer**: `skills/autonomous-dispatcher/scripts/lib-auth.sh::setup_github_auth`
(installs both paths) and `::cleanup_github_auth` (removes only the per-run
`GH_WRAPPER_DIR`; never touches `${_LIB_AUTH_DIR}/gh`).

**Consumer**:
- Agent-facing docs that prescribe `bash scripts/gh …`; agent processes that
  follow that prescription; any operator script that invokes `bash scripts/gh`
  from the project's `scripts/` directory (consumer 1 — `scripts/gh`).
- The wrapper scripts' own bare `gh` calls (consumer 2 — PATH).

**Status**: **ENFORCED** by this PR (closes #163; supersedes the #142 form).
- Pre-#142: the symlink creation lived inside the `if [[ "$GH_AUTH_MODE" ==
  "app" ]]` branch, so token-mode invocations of `scripts/gh` fell through to
  a "no such file" error.
- #142: lifted symlink creation out of the app branch (single shared
  `${_LIB_AUTH_DIR}/gh` on PATH, removed in cleanup).
- #163: split the two consumers — `scripts/gh` (shared, idempotent, never
  deleted) for the agent; a per-run `GH_WRAPPER_DIR` on PATH for the wrapper.
- #163 review follow-up (agy second-opinion): hardened the split — the shared
  `scripts/gh` is now created **atomically** (temp + `mv -f`, not bare
  `ln -sf`); `cleanup_github_auth` **resets** `GH_WRAPPER_DIR` /
  `GH_TOKEN_FILE` / `TOKEN_DAEMON_PID` so reused-shell `setup → cleanup →
  setup` doesn't point at a deleted dir; and `${_LIB_AUTH_DIR}` is asserted
  absolute at source time.

**Test**:
- `tests/unit/test-lib-auth-gh-symlink.sh` (11 cases):
  - TC-AUTH-SYM-001 — token-mode `setup` creates `${_LIB_AUTH_DIR}/gh`
    targeting `gh-with-token-refresh.sh`.
  - TC-AUTH-SYM-002 — source-level guard: the `${_LIB_AUTH_DIR}/gh`
    creation line (`mv -f … "${_LIB_AUTH_DIR}/gh"`) is OUTSIDE the
    `GH_AUTH_MODE=app` branch.
  - TC-AUTH-SYM-003 — `setup` exports a per-run `GH_WRAPPER_DIR` under
    `/tmp/agent-auth-*`, drops a `gh` symlink in it, and prepends it to PATH.
  - TC-AUTH-SYM-004 — two concurrent `setup` calls get **distinct**
    `GH_WRAPPER_DIR` paths (no sharing).
  - TC-AUTH-SYM-005 — `cleanup` removes the per-run `GH_WRAPPER_DIR`.
  - TC-AUTH-SYM-006 — `cleanup` does NOT touch `${_LIB_AUTH_DIR}/gh`.
  - TC-AUTH-SYM-007 — source-level guard: no `rm -f` of `${_LIB_AUTH_DIR}/gh`
    anywhere in `lib-auth.sh` (the #163 footgun regression pin).
  - TC-AUTH-SYM-008 — `setup` still creates `${_LIB_AUTH_DIR}/gh` (INV-32) and
    is idempotent across two calls.
  - TC-AUTH-SYM-009 — reused shell: `setup → cleanup → setup` lands on a
    **fresh, existing** `GH_WRAPPER_DIR` distinct from the first (High review
    finding — stale `GH_WRAPPER_DIR` after `rm -rf`).
  - TC-AUTH-SYM-010 — source + behavioural: the shared `${_LIB_AUTH_DIR}/gh`
    is created **atomically** (no bare `ln -sf` on the shared path; Medium
    review finding).
  - TC-AUTH-SYM-011 — `cleanup` clears `GH_TOKEN_FILE` / `TOKEN_DAEMON_PID` /
    `GH_WRAPPER_DIR` (no stale state leaks into a reused shell).

**Cross-references**:
- Agent-facing rule: `skills/autonomous-dev/references/autonomous-mode.md`
  "Posting Issue/PR Comments" section — describes when to use
  `bash scripts/gh issue comment …` vs `bash scripts/gh-as-user.sh pr
  comment …`. INV-32 is what makes the former actually work in both modes.
- Doc-lint guard: `tests/unit/test-dev-skill-bash-scripts-gh.sh` — fails
  on regressions to bare `gh issue comment` in `skills/autonomous-dev/`
  markdown.

## INV-33: Review wrapper MUST NOT close the linked issue

**Rule**: `autonomous-review.sh` (and any helper it sources) MUST NOT call
`gh issue close` (nor any equivalent state-mutating call that transitions
an issue from `OPEN` to `CLOSED`) on any code path. The only sanctioned
issue-closure path is GitHub's own resolution of the `Closes #N` /
`Fixes #N` / `Resolves #N` keyword in the PR body when the PR is merged
into the default branch.

When `gh pr merge` returns non-zero (auto-merge failure: merge conflict,
branch protection blocking, transient API error, required check missing),
the wrapper MUST:

1. Capture the merge stderr (truncated to 500 chars).
2. Post a comment on the **PR** with prefix `Auto-merge failed:` followed by
   the captured excerpt and the directive `Re-dispatching dev agent to
   rebase onto main.`
3. Edit the issue: `−reviewing +pending-dev`. Do NOT remove `autonomous`
   (the dispatcher's `list_pending_dev` selector gates on `autonomous`).
4. NOT add `+approved`. NOT call `gh issue close`. NOT post a "please
   merge manually" message that hands the work back to a human — auto-merge
   failure is a dev-rebase task, not a human-handoff.

The dev wrapper's resume branch detects the marker by querying PR-issue
comments for `startswith("Auto-merge failed:")` and prepends a
`## Pre-implementation: rebase` section to the resume prompt that
instructs `git fetch origin && git rebase origin/main` before any other
work. Once the rebase succeeds, the dev wrapper trap transitions back to
`+pending-review`, the next dispatcher tick re-dispatches review, and the
merge succeeds — GitHub then closes the issue via the PR's `Closes #N`
keyword.

**Why**: Reproduced live on a downstream consumer at
2026-05-20T12:17:35–12:17:37Z: review wrapper PASSED, posted "Reviewed
HEAD" trailer, attempted auto-merge, auto-merge failed, wrapper posted
"please merge manually" — and within 2 seconds the issue closed with
`stateReason=COMPLETED` and the PR still `OPEN`. Cause: the wrapper called
`gh issue close --reason completed` unconditionally after the merge
attempt, regardless of merge success/failure. The closed issue is then
invisible to `list_pending_dev` (open-only filter), so any further
automation against it stalls until manually reopened.

GitHub's default behavior already closes the issue when the PR resolves
`Closes #N` on merge. The explicit close call from the wrapper is
redundant on success and actively wrong on failure — there is no path
where it does the right thing, so the right design is to remove it
entirely and rely on GitHub's link semantics.

**Producer**: `skills/autonomous-dispatcher/scripts/autonomous-review.sh`
verdict-PASS branch (the auto-merge sub-branch).

**Consumer**:
- The dispatcher's `list_pending_dev` selector (in `lib-dispatch.sh`) —
  consumes the `+pending-dev` issue label set by the failure path and
  re-dispatches dev.
- `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` resume branch
  — consumes the `Auto-merge failed:` marker comment and prepends rebase
  instructions to the resume prompt.

**Status**: **ENFORCED** in this PR (closes #145).

**Test**:
- `tests/unit/test-autonomous-review-auto-merge-failure.sh` — source-of-truth
  grep tests:
  - TC-AMF-006: zero `gh issue close` calls in the wrapper (regression pin).
  - TC-AMF-002: failure branch sets `+pending-dev` on the issue.
  - TC-AMF-003: failure branch posts via `gh pr comment` with the
    `Auto-merge failed:` marker prefix and `Re-dispatching dev`/`rebase
    onto main` directive.
  - Failure branch keeps `autonomous` (single `--remove-label autonomous`
    occurrence: the success branch only).
  - Old "Review passed but auto-merge failed. Please merge ... manually"
    wording is removed.
- `tests/unit/test-autonomous-dev-rebase-marker.sh` — verifies the dev
  wrapper's resume branch detects the marker via `startswith("Auto-merge
  failed:")` and conditionally injects rebase instructions.

**Cross-references**:
- [INV-32](#inv-32-gh-wrapper-is-installed-on-two-paths-shared-scriptsgh-for-the-agent-per-run-path-dir-for-the-wrapper) —
  the marker-posting `gh pr comment` is one of the wrapper's own bare `gh`
  calls, so it routes through the per-run `GH_WRAPPER_DIR` `gh` on PATH;
  token-mode and app-mode behave identically.
- [INV-04](#inv-04-reviewed-head-trailer-format) — the "Reviewed HEAD"
  trailer is still posted in the auto-merge-failure path (the wrapper's
  trailer write happens before the merge attempt) — the dispatcher's
  Step 5b SHA-match logic continues to work as designed.
- [INV-26](#inv-26-stall-decision-excludes-dispatcher-induced-terminations-and-defers-on-live-wrappers)
  — caps the auto-merge-failure → dev-rebase → review-retry loop at
  MAX_RETRIES; the issue transitions to `stalled` if the loop fails to
  converge.
- [`state-machine.md`](state-machine.md) — the `reviewing → pending-dev
  (auto-merge failed)` transition is documented in the transition table
  and mermaid diagram.
- [`review-agent-flow.md`](review-agent-flow.md#auto-merge-failure--dev-re-dispatch-inv-33)
  — full procedure walkthrough.


## INV-34: agent prompt is fed via stdin, never as a single argv element

**Rule**: `lib-agent.sh::run_agent` and `resume_agent` MUST feed the
constructed prompt to the underlying agent CLI via stdin (a leading
`printf '%s' "$prompt" | _run_with_timeout <cli> ...` pipeline stage).
The prompt MUST NOT appear as a positional argv element to any
exec'd binary in the chain (`setsid`, `timeout`, `env`, the agent CLI
itself, or any operator-supplied `AGENT_LAUNCHER`).

**Why**: Linux `execve(2)` rejects any single argv element larger than
`MAX_ARG_STRLEN = 32 * PAGE_SIZE = 131072 bytes` (128 KB on every
common page-size architecture), independent of the much larger total
`ARG_MAX` limit. The autonomous-dev wrapper assembles the prompt from
`gh issue view --json title,body,comments`, which on a normal
multi-cycle dev → review → conflict → re-review lifecycle accumulates
hundreds of machine-author comments (dispatcher tokens, Session Reports,
review summaries) and routinely crosses 128 KB. Pre-#144 the wrapper
crashed at `setsid: Argument list too long` (exit 126) on every
dispatcher tick once the issue grew past that threshold — a
size-based silent perma-stall, recoverable only by manually deleting
machine comments to shrink the JSON. Reproduced downstream at 189 KB.

**Pipeline-stage exit propagation**: with the new printf stage, the
pipelines that already had an awk capture filter (`codex`, `opencode`)
become three-stage:
`printf | _run_with_timeout <cli> | _<cli>_capture_*`. PIPESTATUS[0]
is the printf (always 0); PIPESTATUS[1] is the CLI's exit code (load-
bearing for `count_agent_failures`); PIPESTATUS[2] is the awk filter
(always 0). Pre-#144 the codex / opencode branches read PIPESTATUS[0]
because the printf stage didn't exist; that path now reads
PIPESTATUS[1]. The single-stage CLIs (`claude`, `gemini`, `kiro`,
generic fallback) propagate the rc through the wrapper's normal
`set -o pipefail` semantics — no PIPESTATUS read needed.

**Producer**:
`skills/autonomous-dispatcher/scripts/lib-agent.sh::{run_agent,resume_agent}`.

**Consumer**: every agent CLI branch (`claude`, `codex`, `gemini`,
`kiro`, `opencode`, `*` generic). Each CLI's stdin marker is
documented in its branch comment:
- `claude -p` (no value) — claude reads stdin when `-p` has no arg.
- `codex exec -` — `-` tells codex to read the prompt from stdin.
- `gemini -p` (no value) — gemini reads stdin when `-p` has no arg.
- `kiro chat --no-interactive` (no positional message) — reads stdin.
- `opencode run` (no positional message) — reads stdin.
- `*` generic fallback — `<cli> -p` (no value) — best-effort.

**Test**: `tests/unit/test-lib-agent-prompt-stdin.sh` — 61 cases:
TC-EXEC-001..006 exercise each `run_agent` CLI branch with a 256 KB
prompt loaded from a sidecar file (env-var passing would itself hit
MAX_ARG_STRLEN), assert that the CLI stub sees the full prompt on
stdin AND that no argv token exceeds 64 KB. TC-EXEC-007/008 cover
`resume_agent` for claude (single-stage) and codex (three-stage with
PIPESTATUS[1]). TC-EXEC-013/014 cover `resume_agent` for gemini
(single-stage) and opencode (three-stage). TC-EXEC-009 is a static
grep, tightened to handle `\\`-line continuations, that fails if any
`_run_with_timeout ... "$prompt"` invocation appears (incl. across
continuation lines), and pins PIPESTATUS[0] absence + PIPESTATUS[1]
presence. TC-EXEC-010 verifies small prompts still work via the new
channel for all five CLIs. TC-EXEC-011/012 pin codex / opencode
non-zero exit propagation through the new three-stage pipeline. The
four existing per-CLI behavioral test files
(`test-lib-agent-{codex,gemini,kiro-permission,opencode}.sh`) were
updated in the same PR to assert "prompt on stdin, not argv".

**Cross-references**:
- [INV-13](#inv-13-wall-clock-cap-on-agent-invocations) — `_run_with_timeout`
  is unchanged; the printf stage is added before it. The wall-clock
  cap, setsid PGID semantics, and `_AGENT_RUN_PID` capture all still
  apply because they wrap the CLI stage, which is downstream of the
  printf.
- [INV-22](#inv-22-agent_launcher-tokenization--claude-only-invocation-contract)
  — `AGENT_LAUNCHER_ARGV` is unchanged; the launcher still receives
  the structural flags as `"$@"`, with the prompt arriving via stdin
  inherited through the pipeline. Operator-defined launchers (e.g.
  the canonical `cc` shell function) MUST forward stdin to the CLI
  exec — `exec $CLAUDE_CMD "$@"` does this implicitly.
- [INV-31](#inv-31-operator-tunable-per-cli-flags-live-in-conf-not-in-lib-agentsh)
  — `AGENT_DEV_EXTRA_ARGS` / `AGENT_REVIEW_EXTRA_ARGS` are unchanged
  (operator-supplied flags continue to ride on argv between the
  structural flags and the now-absent prompt positional).

## INV-35: Review-aware resume routing for completed sessions

**Rule**: When the dispatcher's Step 4 finds a `pending-dev` issue whose prior dev session reached `end_turn|completed` ([INV-12](#inv-12-resume-only-against-unfinished-sessions)), it MUST consult the most recent review-failure verdict comment that is newer than the session's end-of-turn before deciding what to do. The routing is:

| Recent post-completion verdict | Route |
|---|---|
| (none) | INV-12 operator handoff: post `INV-12-completed:<sid>` notice, leave in `pending-dev`. *(Original INV-12 behavior, preserved.)* |
| `passed` (race: review approved while dispatcher was reading) | No-op + WARN log. The `approved` label hygiene at Step 0 ([INV-25](#inv-25-terminal-labels-approved-stalled-are-sticky-transitional-residue-is-healed-at-tick-start)) will reconcile next tick. |
| `failed-non-substantive` AND non-substantive flip count for this session < `REVIEW_RETRY_LIMIT` (default 2) | Label-flip `pending-dev → pending-review` + post `<!-- review-aware-flip:non-substantive cause=<x> -->` marker. Step 3 picks it up next tick. Does NOT consume `MAX_RETRIES`. |
| `failed-non-substantive` AND flip count ≥ `REVIEW_RETRY_LIMIT` | Mark stalled with operator @-mention citing the persistent non-substantive failure (e.g. bot consistently times out). |
| `failed-substantive` | Treat the same as the PTL branch: post `INV-35-fresh-dev:<sid>` notice, **truncate the per-issue log** (fail-closed if truncate fails — same pattern as INV-12 PTL), `label_swap pending-dev → in-progress`, `post_dispatch_token dev-new`, `dispatch dev-new`. Consumes `MAX_RETRIES` via the existing retry-comment count. |

**Why**: Pre-fix, INV-12's `completed` branch was overly broad. It correctly prevented the SSE-stream hang on `claude --resume`, but it was the WRONG gate for the case where a dev session finished cleanly and a *later* review failed — the review failure routed the issue to `pending-dev`, then every subsequent tick re-saw `end_turn|completed` in the dev log and posted the `INV-12-completed` operator notice without ever re-running anything. Issues stuck indefinitely (#149, observed live with #144 / #145 on 2026-05-21 when configured `REVIEW_BOTS=q` timed out).

The fix preserves INV-12's hang-prevention rationale while distinguishing three distinct post-completion situations:

1. **No review yet** (or review still in-flight): the dev finished cleanly with no failing verdict — the original "operator decides" case. INV-12-completed notice fires.
2. **Review failed for non-substantive reasons** (bot timeout, CI transport, "no PR found" race): re-running review is the correct recovery. The dev didn't fail; an upstream dependency did.
3. **Review failed for substantive reasons** (code findings, requirement drift, auto-merge-failed-with-rebase-needed per [INV-33](#inv-33-review-wrapper-must-not-close-the-linked-issue) + #146): the dev needs to take another pass, but resume cannot re-engage a completed session — fresh-dev (INV-12 PTL pattern) is the right recovery. The resume-prompt rebase block from #146 is layered on by `resume_agent`'s prepend logic regardless of new-vs-resume mode, so fresh-dev still gets the rebase guidance when applicable.

**Verdict-classification contract**: the review wrapper emits a structured trailer in its verdict comment (HTML-comment form, mirroring [INV-04](#inv-04-reviewed-head-trailer-format)'s `Reviewed HEAD:` idiom):

```
<!-- review-verdict: passed -->
<!-- review-verdict: failed-substantive -->
<!-- review-verdict: failed-non-substantive cause=<short-token> -->
```

Where `<short-token>` is one of `bot-timeout`, `ci-transport`, `no-pr-found`, `merge-conflict-unresolvable`, or `other` (extensible). Comments lacking the trailer are conservatively treated as `failed-substantive` so any pre-INV-35 verdict comment in flight at deploy time falls into the safe-recovery branch (fresh-dev) rather than the silent-noop branch.

**Producer**:
- The trailer: `autonomous-review.sh` (verdict comment emission paths — both PASS and the various FAIL branches).
- The routing decision: a new helper `lib-dispatch.sh::classify_recent_review_verdict` invoked from `dispatcher-tick.sh` Step 4 right after `is_session_completed` returns `completed`. The helper reads issue comments, finds the newest comment authored by `BOT_LOGIN` (or fallback) that contains a `<!-- review-verdict: ... -->` trailer AND whose `createdAt` is newer than the dev-session-end-of-turn timestamp (extracted from the same `{"type":"result"}` line `is_session_completed` already parses).

**Consumer**: dispatcher Step 4 routing logic, indirectly the dev wrapper (gets a fresh `dev-new` for substantive failures) and Step 3 (gets a re-fired `pending-review` for non-substantive failures).

**Interaction with `MAX_RETRIES`**: the substantive `dev-new` path consumes a retry slot via the existing retry-comment count (same as the INV-12 PTL path). The non-substantive flip path does NOT consume `MAX_RETRIES` — it is bounded by its own `REVIEW_RETRY_LIMIT` counter (count of `<!-- review-aware-flip:non-substantive -->` markers on the issue, scoped to the current session-id) so a permanently broken bot doesn't loop forever, but a flaky bot doesn't burn down the dev-side retry budget.

**Implementation note (#149 follow-up)**: the per-session non-substantive flip counter is bound to the dev session-id by extending the marker comment to `<!-- review-aware-flip:non-substantive cause=<x> session=<sid> -->`. This is a backwards-compatible extension of the design's `<!-- review-aware-flip:non-substantive cause=<x> -->` marker — a fresh `dev-new` session re-runs the counter from zero (intentional: a new dev session is also a new chance for the review side to succeed).

**Implementation note (session-end timestamp)**: the design says "the session-end timestamp is extracted from the same `{"type":"result"}` JSON line that `is_session_completed` already parses". In implementation, the result JSON does not carry a timestamp (claude omits it; wrapper-emitted log prefixes are `HH:MM:SS`-only), so `is_session_completed`'s third out-var derives the ISO-8601 timestamp from the per-issue log file's mtime instead. The wrapper writes the final "Agent exited" line at session end, so mtime is a reliable proxy across any agent CLI. Empty mtime (date(1) failure) falls back to "no time filter — accept all post-session bot comments", which is conservative.

**Status**: **ENFORCED** as of #152 (issue #149 implementation PR). Design recorded in `docs/designs/inv35-review-aware-resume.md`.

**Test**:
- `tests/unit/test-handle-completed-session-routing.sh` — 47 cases asserting Step 4b.5.1's branch decision matches every row of the routing table above (TC-INV35-RT-001/010/011/012/013/014/020/021/022/030 + idempotency).
- `tests/unit/test-classify-recent-review-verdict.sh` — 16 cases for the `classify_recent_review_verdict` helper (trailer parsing, timestamp comparison, missing-trailer fallback, multiple verdicts pick the newest, BOT_LOGIN-empty fallback per session-id binding).
- `tests/unit/test-inv35-regression-2026-05-21.sh` — TC-INV35-REG-001/002 replaying the 2026-05-21 #144/#145 fixture (dev `end_turn|completed` → q-bot timeout review → dispatcher tick must label-flip to `pending-review`, not post `INV-12-completed`).
- `tests/unit/test-is-session-completed-end-ts.sh` — 8 cases for the new third out-var that exposes the session-end ISO timestamp via log mtime.
- `tests/unit/test-autonomous-review-verdict-trailer.sh` — 9 cases for `lib-review-verdict.sh::emit_verdict_trailer` covering each verdict, cause-token sanitization, and unknown-verdict rejection.

**Cross-references**:
- [INV-12](#inv-12-resume-only-against-unfinished-sessions) — the hang-prevention invariant this carves out from.
- [INV-33](#inv-33-review-wrapper-must-not-close-the-linked-issue) + #146 auto-merge-failure handling — INV-35's `failed-substantive` branch composes with #146's resume-prompt rebase prepend (the prepend fires whenever the most recent PR comment matches `Auto-merge failed:`, regardless of whether the next dispatch is dev-resume or dev-new).
- [`docs/designs/inv35-review-aware-resume.md`](../designs/inv35-review-aware-resume.md) — design canvas with the full routing table and verdict-trailer schema.
- [`dispatcher-flow.md` § Step 4b.5](dispatcher-flow.md#step-4b5-terminal-state-gate-inv-12) — Step 4's runtime view of the routing.

## INV-36: agy conversation id capture is best-effort

**Rule**: `_agy_capture_conversation` (in `lib-agent.sh`, used by the `agy)` branch of `run_agent` / `resume_agent`) MUST NOT gate `run_agent`'s exit code on capture success. A grep miss, missing log file, or unwritable sidecar path all return 0 from the helper and leave the sidecar absent. `resume_agent` MUST handle sidecar-absent by falling back to a fresh `run_agent`.

**Why**: agy's `Print mode: conversation=<UUID>` log line is undocumented (emitted from agy's internal `printmode.go:130` as of agy 1.0.2). A future agy version may rename the log message, change the format, or move the channel entirely. Gating `run_agent` on capture would convert a documentation drift into a pipeline outage. The sidecar pattern already includes a degraded-but-functional fallback (fresh run loses conversation continuity but preserves pipeline progress) — INV-36 makes that explicit so future maintainers do not "helpfully" promote capture failure to a hard error.

**Producer**: `_agy_capture_conversation` in `skills/autonomous-dispatcher/scripts/lib-agent.sh`.

**Consumer**: `resume_agent` agy branch reads the sidecar via `_agy_conversation_id`; absent return-1 triggers fallback to `run_agent`.

**Test**: `tests/unit/test-lib-agent-agy.sh` — AGY-S3 (log without match leaves sidecar absent), AGY-S4 (symlink sidecar refused with WARN), AGY-S5 (read-side symlink + corrupted-content rejection), AGY-05 (resume without sidecar falls back to fresh run), AGY-07 (`run_agent` rc still propagates when log lacks the Print-mode line).

**Cross-references**:
- [`docs/pipeline/agy-cli-support.md`](agy-cli-support.md) — full per-CLI spec for the agy branch.
- [INV-31](#inv-31-operator-tunable-per-cli-flags-live-in-conf-not-in-lib-agentsh) — agy's structural flags (-p, --dangerously-skip-permissions, --print-timeout, --log-file) live in `lib-agent.sh`, NOT in `AGENT_*_EXTRA_ARGS`.
- [INV-34](#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element) — agy's `-p` (no value) reads from stdin, same channel contract as claude/gemini.

## INV-37: per-side AGENT_CMD precedence

**Rule**: `lib-agent.sh` exposes `AGENT_DEV_CMD` and `AGENT_REVIEW_CMD` as side-specific overrides of `AGENT_CMD`. Both default to `${AGENT_CMD:-claude}` so existing deployments are byte-for-byte unchanged. `autonomous-dev.sh` sets `AGENT_CMD="$AGENT_DEV_CMD"` exactly once, **after sourcing both `lib-agent.sh` AND `lib-auth.sh`** (and any other lib that may transitively re-source `autonomous.conf`). `autonomous-review.sh` sets `AGENT_CMD="$AGENT_REVIEW_CMD"` in the same position — after `lib-agent.sh` + `lib-auth.sh` + `lib-review-bots.sh` + `lib-review-verdict.sh`. After the override, the `case "$AGENT_CMD"` statements in `run_agent` / `resume_agent` dispatch to the right CLI per-side without any signature change.

**Why "after lib-auth.sh"**: `lib-auth.sh` transitively sources `lib-config.sh::load_autonomous_conf`, which re-sources `autonomous.conf`. Operator confs declare `AGENT_CMD="claude"` unconditionally (the default-CLI declaration), so re-sourcing reverts any earlier per-side rebind. Bug discovered 2026-05-26: a podcast-curation review wrapper with `AGENT_REVIEW_CMD=kiro` kept invoking `claude` because the rebind was being undone by the re-source. The fix is purely structural — move the rebind line below the offending `source`. See `tests/unit/test-wrapper-rebind-order.sh` for the behavioral regression test that pins this contract.

**Why**: lets one project run dev and review on different CLIs (typical pattern: claude for dev, agy or another cheaper / specialized CLI for review). Without this, `AGENT_CMD` is a single value shared by both wrappers and operators must choose one CLI for the whole project. The model knobs (`AGENT_DEV_MODEL` / `AGENT_REVIEW_MODEL`) and per-side flags (`AGENT_DEV_EXTRA_ARGS` / `AGENT_REVIEW_EXTRA_ARGS`) already split — INV-37 closes the conspicuous gap on the CLI knob.

**Constraint**: `AGENT_LAUNCHER` (claude-only at this writing) is rejected at `lib-agent.sh` source time when **either** `AGENT_DEV_CMD` or `AGENT_REVIEW_CMD` resolves to a non-claude CLI. The launcher would otherwise be applied to a CLI it wasn't written for. The guard reads `AGENT_DEV_CMD` and `AGENT_REVIEW_CMD` directly (not `$AGENT_CMD`) so it fires correctly regardless of which wrapper does the subsequent override.

**Producer**: `lib-agent.sh` init block (the two `${VAR:-$AGENT_CMD}` assignments after `AGENT_CMD="${AGENT_CMD:-claude}"`).

**Consumer**: `autonomous-dev.sh` and `autonomous-review.sh` entry blocks set the active `AGENT_CMD` before any `run_agent` / `resume_agent` call. The dispatcher tick also has two per-side reads in `lib-dispatch.sh`: `_pgid_has_agent_process` accepts an optional 2nd-arg per-side CLI override (callers pass `${AGENT_DEV_CMD:-...}` from `dev_near_success` and `${AGENT_REVIEW_CMD:-...}` from `review_near_success`); `is_session_completed` gates on `${AGENT_DEV_CMD:-${AGENT_CMD:-claude}}` because it parses the dev wrapper's log. The dispatcher tick does NOT source lib-agent.sh, so it cannot inherit the wrapper-level override — these reads are the substitute.

**Test**: `tests/unit/test-lib-agent-per-side-cmd.sh` PSC-S1 (defaults), PSC-S2/S3 (single-side override), PSC-S4 (both set), PSC-S5 (empty-string fallback), PSC-S6 (launcher + both claude → pass), PSC-S7/S8/S11 (launcher + any non-claude side → fail with both var values in the error), PSC-S9/S10 (rebind lands AFTER `source lib-auth.sh` — pins the bug-fix contract). Behavioral regression: `tests/unit/test-wrapper-rebind-order.sh` (T2 reproduces the podcast-curation #333/#334 misroute by simulating the wrapper source order and asserting `AGENT_CMD == kiro` post-rebind). Dispatcher-side coverage: `tests/unit/test-pgid-has-agent-process.sh` (TC-PSC-COUP-01a..d) and `tests/unit/test-is-session-completed.sh` (TC-WH-005b).

**Cross-references**:
- [`docs/pipeline/per-side-agent-cmd.md`](per-side-agent-cmd.md) — full spec.
- [INV-31](#inv-31-operator-tunable-per-cli-flags-live-in-conf-not-in-lib-agentsh) — the new vars are operator-tunable and live in `autonomous.conf`, following INV-31's contract.
- [`docs/pipeline/agy-cli-support.md`](agy-cli-support.md) — agy is the most likely review-side CLI today and the motivating example.
- [INV-38](#inv-38-per-side-agent_launcher-precedence) — per-side `AGENT_LAUNCHER` (the launcher-side analogue, replaces this invariant's single guard with two per-side guards).

## INV-38: per-side AGENT_LAUNCHER precedence

**Rule**: `lib-agent.sh` exposes `AGENT_DEV_LAUNCHER` and `AGENT_REVIEW_LAUNCHER` as side-specific overrides of `AGENT_LAUNCHER`. Both default to `${AGENT_LAUNCHER:-}` so existing deployments are byte-for-byte unchanged. Each side's tokenized argv array is gated independently: `AGENT_DEV_LAUNCHER` non-empty requires `AGENT_DEV_CMD=claude`; `AGENT_REVIEW_LAUNCHER` non-empty requires `AGENT_REVIEW_CMD=claude`. The two guards replace the single `[INV-37]` guard. Each wrapper rebinds the existing `AGENT_LAUNCHER_ARGV` (the array `_run_with_timeout` reads) to its side's array immediately after sourcing `lib-agent.sh` — paired with the existing `AGENT_CMD` rebind from `[INV-37]`. After both rebinds, `run_agent` / `resume_agent` continue reading `AGENT_LAUNCHER_ARGV[@]` without signature changes.

**Why**: Pairs with `[INV-37]` (per-side `AGENT_CMD`). Without per-side launchers, a project that wants to run dev on claude with a Bedrock-bridge launcher (e.g. `cc`) AND review on a non-claude CLI (e.g. kiro) is blocked by `[INV-37]`'s "both sides claude" guard. The `cc` bridge is claude-specific (sets `ANTHROPIC_DEFAULT_*`, `AWS_PROFILE`, `CLAUDE_CODE_USE_BEDROCK=1`) and would harm a non-claude CLI even if applied. Per-side launchers let each side use the launcher that fits its CLI. Strictly more permissive than the `[INV-37]` form: every operator config that passed before still passes; the freed configurations are exactly those where one side has a launcher and the other side runs a non-claude CLI without one.

**Producer**: `lib-agent.sh` init block — the two `${VAR:-$AGENT_LAUNCHER}` assignments + per-side `eval` tokenization mirroring the existing `AGENT_LAUNCHER` block.

**Consumer**: `autonomous-dev.sh` and `autonomous-review.sh` entry blocks rebind `AGENT_LAUNCHER_ARGV` to `AGENT_{DEV,REVIEW}_LAUNCHER_ARGV` after sourcing both `lib-agent.sh` AND `lib-auth.sh` (same ordering as the `[INV-37]` rebind, for the same reason — see INV-37's "Why after lib-auth.sh" note). Downstream `_run_with_timeout` reads the rebound `AGENT_LAUNCHER_ARGV[@]` unchanged.

**Test**: `tests/unit/test-lib-agent-per-side-launcher.sh` PSL-S1 (defaults), PSL-S2 (back-compat AGENT_LAUNCHER fallback), PSL-S3/S4 (single-side override), PSL-S5 (both set), PSL-S6 (per-side guard pass), PSL-S7/S8 (per-side guard fails with side-specific error message), PSL-S9/S10 (launcher rebind lands AFTER `source lib-auth.sh`). Behavioral regression: `tests/unit/test-wrapper-rebind-order.sh` (T1 dev / T2 review) — pins both INV-37 (`AGENT_CMD`) and INV-38 (`AGENT_LAUNCHER_ARGV`) survive lib-auth's conf re-source. PSC-S7/S8/S11 in `test-lib-agent-per-side-cmd.sh` continue to match the per-side error messages.

**Cross-references**:
- [`docs/pipeline/per-side-launcher.md`](per-side-launcher.md) — full spec.
- [INV-37](#inv-37-per-side-agent_cmd-precedence) — per-side `AGENT_CMD`. INV-38 builds on it: the launcher guard now keys on per-side CLIs.
- [INV-31](#inv-31-operator-tunable-per-cli-flags-live-in-conf-not-in-lib-agentsh) — operator-tunable flags live in `autonomous.conf`. The new vars follow that contract.
- [INV-13](#inv-13-wall-clock-cap-on-agent-invocations) — wall-clock cap. Unaffected: each side's launcher still runs inside `_run_with_timeout` exactly as before.

## INV-39: Dependency parsing is list-item scoped and supports cross-repo refs

**Rule**: Step 2's dependency check parses ONLY list-item lines (lines that start with `-`, `*`, or `1.` after optional leading whitespace) inside the `## Dependencies` section. Prose, blockquotes (`> ...`), and headings between `## Dependencies` and the next `## ` heading are ignored — they MUST NOT cause an issue to be blocked. On each list item, two ref shapes are recognized:

- `#N` — same-repo issue/PR, resolved against `$REPO`.
- `owner/repo#N` — cross-repo issue/PR, resolved against the named repo.

Both shapes require a left boundary (start-of-line, whitespace, or `(`) so URL fragments like `https://github.com/owner/repo/issues/123` and inline punctuation don't misparse, while parenthesized refs like `(owner/repo#42)` are still recognized. The longer `owner/repo#N` shape is always matched before bare `#N` so a single ref is never double-counted.

**Why**: The pre-#157 implementation greedy-extracted every `#NNN` substring between `## Dependencies` and the next `## ` heading via `grep -oE '#[0-9]+'`, then looked each one up in `$REPO`. Two related failure modes followed:

1. Cross-repo refs (`owner/repo#NNN`) yielded a bare `NNN` which got queried against the wrong repo. If no such issue existed there, `gh issue view` errored, the surrounding `|| true` swallowed the error, the empty `$state` failed the `!= "CLOSED"` check, and the issue was silently blocked forever.
2. The same greedy extraction picked up `#NNN` tokens inside prose, blockquotes, and inline-prose `owner/repo#NNN` mentions, producing identical silent blocks.

List-item-only scope eliminates the prose false positives. Explicit `owner/repo#N` syntax makes cross-repo dependencies a first-class case instead of a silent failure.

**Producer**: dispatcher Step 2 (`lib-dispatch.sh::check_deps_resolved`).

**Consumer**: itself.

**Lookup-failure semantics**: when `gh issue view` returns a non-zero exit (404 / network error / private repo the dispatcher token can't see), the resulting empty `$state` MUST be treated as fail-safe block AND emit a stderr warning naming the failed `<repo>#N`. The original #157 bug was the silent-block half of this rule; without the warning half, a typo in `owner/repo#N` would silently recreate the same bug class.

**Status**: **ENFORCED** in #157's fix. The function uses `grep -E '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]'` to filter the `## Dependencies` section to list items, then bash regex `(^|[[:space:]\(])([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)` followed by `(^|[[:space:]\(])#([0-9]+)` for stage-2 extraction with a match-and-strip loop. Empty-state lookups emit a `[check_deps_resolved] WARNING: lookup failed for ...` line on stderr and return 1.

**Test**: `tests/unit/test-check-deps-resolved.sh` covers cross-repo CLOSED/MERGED/OPEN, same-repo + cross-repo mixed, prose-embedded refs (must not block), blockquote refs (must not block), URL-fragment refs (must not block), and lookup-failure warning (cross-repo ref to a non-existent repo blocks AND prints the warning). The mock `gh` keys state lookups on `<repo>:<num>` so the same number resolves to different states in different repos.

**Cross-references**:
- [INV-11](#inv-11-dependency-state-includes-merged) — `state ∉ {CLOSED, MERGED}` rule applies to both same-repo and cross-repo refs.
- The `create-issue` skill's `## Dependencies` guidance documents the user-facing parsing rules (`skills/create-issue/SKILL.md`, `skills/create-issue/references/issue-templates.md`).

## INV-40: Multi-agent review attribution, unanimous aggregation, and all-unavailable fallback

**Rule**: `autonomous-review.sh` MAY run more than one verdict-reaching review agent against the same PR, driven by the space-separated `AGENT_REVIEW_AGENTS` config var (e.g. `"agy kiro"`). When it does, three sub-rules hold:

1. **Per-agent attribution.** Each agent runs in its own parallel subshell with its OWN minted `SESSION_ID`, its OWN per-subshell `AGENT_CMD` override, its OWN log (`/tmp/agent-${PROJECT_ID}-review-${N}-${agent}.log`), the launcher neutralized (`AGENT_LAUNCHER_ARGV=()`) for non-`claude` members ([INV-38](#inv-38-per-side-agent_launcher-precedence)), and `AGENT_PID_FILE` unset inside the subshell (so per-agent `run_agent` does NOT rewrite the wrapper's single `review-${N}.pid`). Each agent's prompt (built by `build_review_prompt <name> <session-id>`) instructs it to end its verdict comment with a `Review Agent: <name>` discriminator line in addition to the retained `Review Session: <uuid>` trailer. The wrapper attributes verdicts by running one verdict jq query per agent keyed on `Review Agent: <name>` and taking `last` per agent — see the amended [INV-20](#inv-20-verdict-authenticity-binding-actor--window--trailer-presence).

   **Bounded join — wait by collected PID, never a bare `wait`.** The fan-out loop appends each backgrounded subshell's PID (`$!`) to a `_fanout_pids` array and joins with `wait "${_fanout_pids[@]}"`. A bare `wait` is **forbidden** here: it would block on ALL of the shell's background jobs, which include the long-lived `gh-token-refresh-daemon` (started by `lib-auth.sh`) and the heartbeat `sleep` loop (`_AGENT_HEARTBEAT_PID`). Neither ever exits, so a bare `wait` hangs the wrapper FOREVER after the review agents finish — the issue strands in `reviewing` with no aggregation, no verdict trailer, and no label transition (observed and fixed: a multi-agent — and even N=1 fan-out — review hung indefinitely while the agents had already posted PASS verdicts). The single-agent pre-INV-40 path ran `run_agent` in the foreground (no `wait`), which is why this surfaced only once fan-out backgrounded the agents alongside those daemons.

2. **Unanimous-PASS aggregation.** The aggregated verdict is PASS iff there is ≥1 *deciding* agent AND every deciding agent passed. Any single deciding FAIL → aggregated FAIL (matches the decision-gate "any blocking finding → FAIL" philosophy). An agent is *unavailable* (dropped from the vote) when it produced no classifiable verdict comment within the poll window — whether because its CLI failed to launch or because it launched cleanly but never posted one. A non-zero launch rc is **not itself** the unavailability condition and does **not** drop an agent early: a no-verdict agent keeps being polled for the full scaled poll window regardless of rc, and is resolved at window-expiry ([INV-43](#inv-43-command-mode-e2e-review-wait-budgets-must-not-be-smaller-than-the-e2e-they-dispatched) sub-rule 1b, [#180](https://github.com/zxkane/autonomous-dev-team/issues/180)). This matters because the loop runs AFTER the fan-out `wait` (every CLI has already exited), so dropping a non-zero-rc agent *immediately* on round 1 would miss a passing verdict still propagating to the comments API or flushed just before/after the CLI exited. Conversely, a FAIL (or PASS) an agent *did* post still counts as a deciding verdict even if the CLI also exited non-zero — the matched verdict comment takes precedence over the launch rc (enforced mechanically by `_classify_unresolved_agent`).

   **`timed-out` amendment ([INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto), #185)**: the window-expiry resolution of a *no-verdict* agent is no longer uniformly `unavailable`. It is split by launch rc via `lib-review-aggregate.sh::_classify_noverdict_agent`: rc `124` (coreutils `timeout` TERM-expiry) or `137` (the `--kill-after` SIGKILL escalation) → **`timed-out`**, a **deciding FAIL** that VETOES the merge; any other no-verdict rc (`0` clean-but-silent, `1` launch failure, …) → `unavailable` (dropped), exactly as before. `_aggregate_review_verdicts` treats `timed-out` as a deciding FAIL explicitly (not via the defensive unknown-token catch-all). The veto exists because the review side is now capped aggressively (1h default, [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto)); a timed-out reviewer must be LOUD (FAIL → `−reviewing +pending-dev`) rather than silently dropped, so that e.g. a >1h CI queue the agent was told to `gh pr checks --watch` cannot become a silent pass-through. A round of only `timed-out` + `unavailable` agents is therefore `fail` (≥1 deciding), NOT `all-unavailable`. A verdict the agent DID post still wins (the classifier is only consulted for no-verdict agents at window-expiry).

   The aggregation maps onto the existing `PASSED_VERDICT` / `LATEST_COMMENT` / `AGENT_EXIT` variables so the downstream PASS / FAIL / crash branches and the `emit_verdict_trailer` call sites run UNCHANGED — exactly **one** aggregated INV-35 trailer and **one** INV-04 Reviewed-HEAD trailer per review run. The `timed-out` veto adds NO new `emit_verdict_trailer` site (it flows through the same substantive-FAIL path); it adds one human-visible veto breadcrumb comment and synthesizes a `LATEST_COMMENT` so the FAIL routes substantive even when every deciding agent timed out.

3. **All-unavailable fallback.** If EVERY agent is *unavailable* (note: a `timed-out` agent is DECIDING, not unavailable — so a round with any `timed-out` agent is `fail`, never `all-unavailable`), the wrapper sets `LATEST_COMMENT=""` and falls back to today's single-agent FAIL path verbatim, preserving the legacy AGENT_EXIT distinction so the N=1 path is byte-for-byte: `AGENT_EXIT=1` when any agent's CLI actually crashed (rc ≠ 0) → crash-fallback comment + `failed-non-substantive other` trailer; `AGENT_EXIT=0` when every agent exited cleanly (rc = 0) but posted no verdict comment → no crash comment + `failed-substantive` trailer (the agent ran fine but never reached a verdict — a code-side miss). Both route `−reviewing +pending-dev`. On *partial* unavailability (some, not all, dropped), the wrapper posts ONE human-visible issue comment listing dropped vs. deciding agents and logs a WARN, then decides on the deciding agents.

**N=1 carve-out (backward compatibility)**: when `AGENT_REVIEW_AGENTS` is empty/unset, `REVIEW_AGENTS_LIST` resolves to `("$AGENT_CMD")` — exactly one element equal to the already-rebound per-side review CLI (`$AGENT_REVIEW_CMD`, [INV-37](#inv-37-per-side-agent_cmd-precedence)). The single-agent path's label transitions, trailers, approve/merge behavior, and verdict semantics are byte-for-byte the legacy behavior. The only observable difference for N=1 is the prompt now also instructs the agent to emit the `Review Agent: <name>` discriminator and the verdict query also keys on it — both no-ops for routing when there's a single agent under a single identity.

**Why**: Running two independent verdict-reaching agents and requiring them to agree raises confidence before an autonomous merge — a blocking finding one model misses, the other may catch (#166). The core technical obstacle is attribution: verdict detection ([INV-20](#inv-20-verdict-authenticity-binding-actor--window--trailer-presence)) selects the `last` comment matching `author == BOT_LOGIN` + `createdAt >= WRAPPER_START_TS` + body contains `Review Session`. With N agents under the SAME GitHub identity (the `GH_AUTH_MODE=token` common case; even app-mode shares `REVIEW_AGENT_APP_ID`), all N verdict comments share the same author and trailer, so `last` collapses them to one. The `Review Agent: <name>` discriminator is what re-separates them.

This is DISTINCT from `REVIEW_BOTS` (`/q review`, `/codex review`): those trigger external GitHub bots whose comments are read as *input* by the verdict agent(s); `AGENT_REVIEW_AGENTS` runs N *verdict-reaching* agents and gates the merge on their unanimous agreement.

**Producer**: `autonomous-review.sh` — the fan-out loop (one backgrounded subshell per agent), the per-agent verdict-collection loop, and `lib-review-aggregate.sh::_aggregate_review_verdicts` (the pure unanimous-PASS helper). `build_review_prompt <name> <session-id>` renders the per-agent prompt.

**Consumer**: the wrapper's own downstream PASS / FAIL / crash branches (via `PASSED_VERDICT` / `LATEST_COMMENT` / `AGENT_EXIT`). The dispatcher and the `reviewing` label are unaffected — the fan-out is entirely internal to the wrapper.

**Status**: **ENFORCED** (closes #166). Amended in #185 to add the `timed-out` deciding-FAIL veto for an agent killed by the [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto) review wall-clock cap; the `unavailable`-drop semantics for every non-124/137 no-verdict case are unchanged.

**Test**:
- `tests/unit/test-autonomous-review-multi-agent.sh` — TC-MAR-AGG-01..09 (pure aggregation truth table over `_aggregate_review_verdicts`: both PASS, one FAIL, all-FAIL, decide-on-available, all-unavailable, unavailable+fail, plus the three N=1 cases) and TC-MAR-SRC-01..14 (source-of-truth greps: `AGENT_REVIEW_AGENTS` read, `REVIEW_AGENTS_LIST=("$AGENT_CMD")` N=1 collapse, `build_review_prompt` function, `Review Agent:` discriminator, backgrounded per-agent subshell, per-subshell `AGENT_CMD` override, `AGENT_LAUNCHER_ARGV=()` neutralization, `unset AGENT_PID_FILE`, fan-out PID collection (`_fanout_pids+=($!)`) + bounded `wait "${_fanout_pids[@]}"` with NO bare `wait` (TC-MAR-SRC-09a/b/c — the hang regression), per-agent `Review Agent:` jq predicate, all-unavailable AGENT_EXIT rc-aware mapping (1 on genuine crash, 0 clean-but-silent for legacy N=1 parity) + per-agent `|| _rc=$?` rc capture under `set -e`, no `emit_verdict_trailer` growth, dropped-agent summary comment, `bash -n`).
- `tests/unit/test-autonomous-review-prompt.sh` — TC-ARP-06 (per-agent `Review Agent:` discriminator instruction + jq predicate).
- `tests/unit/test-review-agent-timeout.sh` (#185) — the `timed-out` veto amendment: `_classify_noverdict_agent` rc→state, `_aggregate_review_verdicts` with `timed-out` as a deciding FAIL, and the wrapper's post-window sweep wiring (the INV-40 existing truth-table rows are re-asserted green).
- Backward-compat gate: the full pre-#166 review/verdict/launcher regression sweep stays green with `AGENT_REVIEW_AGENTS` unset.

**Cross-references**:
- [INV-20](#inv-20-verdict-authenticity-binding-actor--window--trailer-presence) — the verdict-authenticity binding this amends with the per-agent `Review Agent:` discriminator.
- [INV-37](#inv-37-per-side-agent_cmd-precedence) / [INV-38](#inv-38-per-side-agent_launcher-precedence) — the per-side `AGENT_CMD` / launcher knobs the fan-out reuses per-subshell.
- [INV-35](#inv-35-review-aware-resume-routing-for-completed-sessions) / [INV-04](#inv-04-reviewed-head-trailer-format) — exactly one aggregated verdict trailer / Reviewed-HEAD trailer per run; aggregation funnels through the unchanged downstream branches.
- [`review-agent-flow.md` § Multi-agent fan-out](review-agent-flow.md#multi-agent-fan-out-inv-40) — runtime walkthrough.
- [`docs/designs/multi-review-agents.md`](../designs/multi-review-agents.md) — design canvas.
- [INV-41](#inv-41-per-agent-review-model--extra-args-resolution) — per-agent model / extra-args resolution layered on this fan-out (#168).

## INV-41: Per-agent review model / extra-args resolution

**Rule**: within the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) multi-agent review fan-out, each agent resolves its OWN model and its OWN extra-args from per-agent override keys, falling back to the shared review values when a per-agent key is unset/empty. The keys extend the flat `AGENT_REVIEW_*` convention with an uppercased agent-name suffix where every character outside `[A-Z0-9]` becomes `_`:

- `AGENT_REVIEW_MODEL_<SUFFIX>` (e.g. `AGENT_REVIEW_MODEL_KIRO="claude-sonnet-4.6"`)
- `AGENT_REVIEW_EXTRA_ARGS_<SUFFIX>` (e.g. `AGENT_REVIEW_EXTRA_ARGS_KIRO="--trust-all-tools"`)

The suffix is computed by `lib-review-resolve.sh::_review_agent_key_suffix <name>` (`agy`→`AGY`, `kiro`→`KIRO`, `claude-code`→`CLAUDE_CODE`).

**Resolution precedence** (per agent, inside its fan-out subshell):

1. **Model** — `_resolve_review_agent_model <name>`: `AGENT_REVIEW_MODEL_<SUFFIX>` (if set AND non-empty) → `AGENT_REVIEW_MODEL` (shared) → the wrapper applies the `sonnet` lib default at the `run_agent` call site (`"${_agent_model:-sonnet}"`). An explicit-empty per-agent key collapses to the shared value (empty == unset, matching `:-` semantics).
2. **Extra-args** — `_resolve_review_agent_extra_args <name>`: `AGENT_REVIEW_EXTRA_ARGS_<SUFFIX>` (if set AND non-empty) → `AGENT_REVIEW_EXTRA_ARGS` (shared) → empty. Tokenized downstream by `lib-agent.sh::_parse_extra_args` (the same `eval` trust model as `AGENT_LAUNCHER`, so quoted multi-token values survive).

**Plumbing note (review side reads `AGENT_DEV_EXTRA_ARGS`)**: the fan-out calls `run_agent` (a *fresh* session), and `run_agent` tokenizes `AGENT_DEV_EXTRA_ARGS` — NOT `AGENT_REVIEW_EXTRA_ARGS` (only `resume_agent` reads the latter, and the review wrapper never resumes). So the wrapper assigns the *resolved review* extra-args string to `AGENT_DEV_EXTRA_ARGS` **inside the subshell** before calling `run_agent`. The operator-facing surface is still the review knobs (`AGENT_REVIEW_EXTRA_ARGS[_<AGENT>]`); the `AGENT_DEV_EXTRA_ARGS` assignment is an internal implementation detail scoped to the subshell and never leaks to the dev side or to a sibling agent.

**Scope**: per-subshell only. The resolution happens inside the existing fan-out subshell (which already overrides `AGENT_CMD="$agent"` per [INV-37](#inv-37-per-side-agent_cmd-precedence) and neutralizes the launcher per [INV-38](#inv-38-per-side-agent_launcher-precedence)). No change to the dev side, the dispatcher, the `reviewing` label, the single `review-<N>.pid`, or the verdict-attribution / aggregation logic of [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback). The INV-04 Reviewed-HEAD trailer's `model` field continues to render the shared `AGENT_REVIEW_MODEL` (it is a single aggregate forensic trailer per run, not per-agent).

**All-unset / N=1 carve-out (backward compatibility)**: with no `AGENT_REVIEW_MODEL_<AGENT>` / `AGENT_REVIEW_EXTRA_ARGS_<AGENT>` keys set, `_resolve_review_agent_model` returns `$AGENT_REVIEW_MODEL` so the `run_agent` model arg equals the legacy `${AGENT_REVIEW_MODEL:-sonnet}`, and `_resolve_review_agent_extra_args` returns `$AGENT_REVIEW_EXTRA_ARGS`. For an all-default config (`AGENT_REVIEW_MODEL=sonnet`, `AGENT_REVIEW_EXTRA_ARGS=""`) the assembled argv is byte-for-byte today's. The N=1 single-agent path (`AGENT_REVIEW_AGENTS` unset → `REVIEW_AGENTS_LIST=("$AGENT_CMD")`) resolves the same shared values, so it is byte-for-byte legacy.

> **One intentional fix, not a regression**: assigning the resolved *review* extra-args to `AGENT_DEV_EXTRA_ARGS` inside the review subshell means the operator-facing `AGENT_REVIEW_EXTRA_ARGS` now finally takes effect on the review side (previously it was silently ignored — `run_agent` only ever read `AGENT_DEV_EXTRA_ARGS`). A project that had set a non-empty `AGENT_DEV_EXTRA_ARGS` and *relied on it leaking into review* would see review now driven by `AGENT_REVIEW_EXTRA_ARGS` instead. This is the correct, documented behavior; for the default empty config there is no observable change.

**Why**: a multi-CLI review fleet may list CLIs with **mutually incompatible model namespaces** — e.g. kiro wants `claude-sonnet-4.6` (kiro-cli's id) while a claude-family agent wants `sonnet[1m]` (the claude/agy id); kiro rejects `sonnet[1m]` and claude rejects `claude-sonnet-4.6`. A single shared `AGENT_REVIEW_MODEL` forces the operator to pick one id and accept that the other agent fails to launch (→ dropped as unavailable under [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)) or silently ignores it. Per-agent extra-args has the same shape (`--trust-all-tools` for one CLI, `--approval-mode yolo` for another). This was the follow-up explicitly deferred in #166. (`agy` now honors `--model` per [INV-50](#inv-50-agy---model-is-validated-against-agy-models-before-forwarding) — and validates it against `agy models` — so `AGENT_REVIEW_MODEL_AGY` is the key that gives agy a valid *agy-namespace* model while other fleet members keep their own.)

**Producer**: `autonomous-review.sh` — the per-agent resolution inside the fan-out subshell (`_resolve_review_agent_model` / `_resolve_review_agent_extra_args`), and `lib-review-resolve.sh` (the pure resolver helpers).

**Consumer**: `lib-agent.sh::run_agent` — receives the resolved model as its 3rd positional arg and tokenizes the resolved extra-args from `AGENT_DEV_EXTRA_ARGS` via `_parse_extra_args`.

**Status**: **ENFORCED** in this PR (closes #168).

**Test**:
- `tests/unit/test-autonomous-review-per-agent-model.sh` — TC-PAM-SUF-01..07 (key-suffix normalization: `agy`/`kiro`/`claude`/`claude-code`/`gpt.4o`/`a b`/mixed-case), TC-PAM-MOD-01..06 + TC-PAM-XA-01..05 (model + extra-args precedence: per-agent wins, other agent keeps shared, explicit-empty falls back, normalized suffix wires the right key), and TC-PAM-SRC-01..07 (source-of-truth greps: wrapper sources `lib-review-resolve.sh`, fan-out resolves per-agent model/extra-args, `run_agent` model arg is the resolved `${_agent_model:-sonnet}` var, resolved extra-args assigned to `AGENT_DEV_EXTRA_ARGS`, helper defined, `bash -n`).
- Backward-compat gate: the full pre-existing review/verdict/launcher regression sweep stays green with all per-agent keys unset.

**Cross-references**:
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the multi-agent fan-out this resolution layers on; the per-subshell override site is the same one INV-40 establishes.
- [INV-37](#inv-37-per-side-agent_cmd-precedence) / [INV-38](#inv-38-per-side-agent_launcher-precedence) — the other per-side / per-subshell overrides the fan-out applies.
- [INV-04](#inv-04-reviewed-head-trailer-format) — the Reviewed-HEAD trailer's `model` field stays the shared value (one aggregate trailer per run).
- [`review-agent-flow.md` § Multi-agent fan-out](review-agent-flow.md#multi-agent-fan-out-inv-40) — runtime walkthrough (per-subshell step documents the resolution).
- [`docs/designs/per-agent-review-model-extra-args.md`](../designs/per-agent-review-model-extra-args.md) — design canvas.
- [INV-42](#inv-42-per-agent-review-launcher-resolution) — per-agent launcher resolution, the third per-agent override axis layered on the same fan-out subshell (#173).

## INV-42: Per-agent review launcher resolution

**Rule**: within the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) multi-agent review fan-out, each agent MAY resolve its OWN launcher from a per-agent override key, extending the per-agent override convention of [INV-41](#inv-41-per-agent-review-model--extra-args-resolution) with a third axis. The key uses the same uppercased agent-name suffix (every char outside `[A-Z0-9]` → `_`, via `lib-review-resolve.sh::_review_agent_key_suffix`):

- `AGENT_REVIEW_LAUNCHER_<SUFFIX>` (e.g. `AGENT_REVIEW_LAUNCHER_CODEX=$'bash -c \'source ~/.bash_aliases && codex "$@"\' --'`)

**Resolution precedence** (per agent, inside its fan-out subshell, via `_resolve_review_agent_launcher <name>`):

1. `AGENT_REVIEW_LAUNCHER_<SUFFIX>` set AND non-empty → tokenized (`eval`, the same trust model `lib-agent.sh` uses for `AGENT_LAUNCHER`) into the subshell's `AGENT_LAUNCHER_ARGV`, and **the [INV-38](#inv-38-per-side-agent_launcher-precedence) claude-only guard is bypassed for this agent specifically** (the operator setting the key is asserting the launcher fits this CLI). A tokenize failure emits an `ERROR: AGENT_REVIEW_LAUNCHER_<agent> failed to tokenize` log line and falls back to naked (`AGENT_LAUNCHER_ARGV=()`).
2. unset/empty → fall through to the existing [INV-38](#inv-38-per-side-agent_launcher-precedence) fan-out behavior: a non-`claude` member's launcher is zeroed (`AGENT_LAUNCHER_ARGV=()`); a `claude` member keeps the shared `AGENT_REVIEW_LAUNCHER` already rebound onto `AGENT_LAUNCHER_ARGV` by the wrapper.

**Deliberate asymmetry with [INV-41](#inv-41-per-agent-review-model--extra-args-resolution)**: `_resolve_review_agent_launcher` does **NOT** fall back to the shared `AGENT_REVIEW_LAUNCHER` (whereas `_resolve_review_agent_model` *does* fall back to the shared `AGENT_REVIEW_MODEL`). The shared launcher is claude-only by [INV-38](#inv-38-per-side-agent_launcher-precedence)'s startup guard; auto-applying it to a non-`claude` per-agent slot would re-introduce exactly the breakage INV-38 prevents (a `cc` bridge ending in `claude "$@"` producing `claude codex ...`). A shared model id is merely namespace-specific (agy consumes `--model` but validates it against `agy models` and omits an unknown id with a WARN — see [INV-50](#inv-50-agy---model-is-validated-against-agy-models-before-forwarding) — so a cross-namespace shared model degrades to agy's default, never to a wrong CLI invocation), but a shared launcher prefix is *actively harmful* to the wrong CLI — so the safe resolution for an un-keyed agent is "no per-agent launcher" (empty), and the fan-out keeps the INV-38 zeroing/keep behavior.

**Scope**: per-subshell only. The resolution and the `eval` tokenization happen inside the existing fan-out subshell (which already overrides `AGENT_CMD="$agent"` per [INV-37](#inv-37-per-side-agent_cmd-precedence), resolves model/extra-args per [INV-41](#inv-41-per-agent-review-model--extra-args-resolution), and `unset AGENT_PID_FILE` per [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)). No change to the dev side, the dispatcher, the `reviewing` label, the single `review-<N>.pid`, the verdict-attribution / aggregation logic, or the INV-04 Reviewed-HEAD trailer.

**The startup guard is unchanged**: `lib-agent.sh`'s [INV-38](#inv-38-per-side-agent_launcher-precedence) guard governs only the SHARED, blanket `AGENT_REVIEW_LAUNCHER` default; it runs at startup, BEFORE the fan-out subshells. The per-agent key is resolved later, inside each subshell, so a per-agent launcher for a non-`claude` CLI is never subject to that guard. Only the guard's leading comment is extended to point at this invariant.

**All-unset / N=1 carve-out (backward compatibility)**: with no `AGENT_REVIEW_LAUNCHER_<AGENT>` keys set, `_resolve_review_agent_launcher` returns empty for every agent, so the fan-out takes the INV-38 branch unchanged — non-`claude` members zeroed, `claude` keeps the shared launcher. The N=1 single-agent path (`AGENT_REVIEW_AGENTS` unset → `REVIEW_AGENTS_LIST=("$AGENT_CMD")`) likewise resolves empty and is byte-for-byte legacy. `AGENT_REVIEW_AGENTS="kiro agy"` with no per-agent launchers is also byte-for-byte unchanged.

**Why**: a multi-CLI review fleet may add a third reviewer (e.g. `codex` alongside `kiro agy`) whose headless launch from the dispatcher's nohup shell REQUIRES a per-machine bridge (start a bedrock proxy, export `OPENAI_BASE_URL` + a dummy `OPENAI_API_KEY`) — the exact pattern `AGENT_DEV_LAUNCHER` solves for `cc`/claude. Before this invariant, the fan-out force-cleared the launcher for any non-`claude` member ([INV-38](#inv-38-per-side-agent_launcher-precedence)) with no escape valve, so codex ran naked and failed. INV-42 is the per-agent escape valve, gated on an explicit operator opt-in.

**Producer**: `autonomous-review.sh` — the per-agent launcher resolution + `eval` tokenization inside the fan-out subshell; `lib-review-resolve.sh::_resolve_review_agent_launcher` (the pure resolver).

**Consumer**: `lib-agent.sh::_run_with_timeout` — reads the per-subshell `AGENT_LAUNCHER_ARGV[@]` (prepended to the agent command) exactly as for any other launcher.

**Status**: **ENFORCED** in this PR (closes #173).

**Test**:
- `tests/unit/test-autonomous-review-per-agent-launcher.sh` — TC-PAL-RES-01..06 (resolver precedence: per-agent value, only-shared→empty, explicit-empty→empty, suffix normalization `gpt-5`→`GPT_5`, sibling→empty, multi-token preserved), TC-PAL-BR-01..05 (fan-out branch behavior: per-agent applied, claude keeps shared, non-claude cleared, per-agent applied to non-claude with INV-38 bypassed, malformed→naked+ERROR log), TC-PAL-REG-01 (the #173 regression: with `AGENT_REVIEW_AGENTS="kiro codex"` + `AGENT_REVIEW_LAUNCHER_CODEX` set, the codex member's argv starts with the launcher while the un-keyed kiro member stays zeroed), TC-PAL-SRC-01..08 (source-of-truth: resolver wired in fan-out, `eval` tokenization, INV-38 `elif` fallback survives, tokenize-failure log path, resolver defined, resolver does NOT reference shared `AGENT_REVIEW_LAUNCHER`, `bash -n`, conf.example documents the key).
- Backward-compat gate: `test-autonomous-review-multi-agent` (incl. TC-MAR-SRC-07 non-claude zeroing), `test-autonomous-review-per-agent-model`, `test-lib-agent-per-side-launcher`, `test-lib-agent-per-side-cmd` stay green with no per-agent launcher keys set.

**Cross-references**:
- [INV-41](#inv-41-per-agent-review-model--extra-args-resolution) — the per-agent model/extra-args resolution this extends with a launcher axis; same suffix convention and per-subshell scope.
- [INV-38](#inv-38-per-side-agent_launcher-precedence) — the per-side / claude-only launcher guard the per-agent key bypasses for its own agent (and whose fan-out zeroing remains the un-keyed fallback).
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the multi-agent fan-out this resolution layers on; the per-subshell override site is the same one INV-40 establishes.
- [`review-agent-flow.md` § Multi-agent fan-out](review-agent-flow.md#multi-agent-fan-out-inv-40) — runtime walkthrough (the per-subshell step documents the launcher resolution).
- [`docs/designs/per-agent-review-launcher.md`](../designs/per-agent-review-launcher.md) — design canvas.

## INV-43: Command-mode E2E review wait budgets must not be smaller than the E2E they dispatched

**Rule**: when `E2E_MODE=command`, the review wrapper's verdict-poll budget AND the dispatcher's review-stall window MUST be sized for the configured `E2E_COMMAND_TIMEOUT_SECONDS`, so a review agent that FAITHFULLY runs the (slow) command-mode E2E is not dropped as `unavailable` solely for taking as long as the E2E it was asked to run.

Three sub-rules:

1. **Verdict-poll budget auto-scales (wrapper-owned).** `autonomous-review.sh`'s per-agent verdict-poll loop attempt count is resolved by `lib-review-poll.sh::_resolve_verdict_poll_attempts`: the legacy floor of `6` (6 × 5 s = 30 s) for every non-`command` mode, and `max(6, ceil(E2E_COMMAND_TIMEOUT_SECONDS / 5))` when `E2E_MODE=command`. A non-numeric / zero / unset timeout falls back to the floor (defensive — never below 6, never crash). The loop still **early-exits** as soon as every agent has a verdict, so the happy path settles in one round (~5 s) regardless of budget; the extended budget only extends the wait for an agent that has not yet posted a verdict — precisely the diligent agent this protects (and, per sub-rule 1b, that includes a non-zero-rc agent whose verdict is still propagating).

1b. **A non-zero CLI exit does not, by itself, drop an agent while the poll window is open (wrapper-owned, [#180](https://github.com/zxkane/autonomous-dev-team/issues/180)).** The verdict-poll loop runs AFTER the fan-out `wait`, so every agent's CLI has already exited and `AGENT_LAUNCH_RC` is fully populated before round 1. Resolving a non-zero-rc agent to `unavailable` **immediately** (the pre-#180 short-circuit) dropped agents that DID post a passing verdict whose comment was still propagating, or whose CLI/verify command exited non-zero on a soft path just after the verdict was posted — so a multi-agent command-mode review could structurally degrade to whichever agent's verdict propagated fastest. (This is a LATENT defect: every captured field drop ran under the pre-INV-43 fixed 30 s window with `rc == 0` — i.e. it was the sub-rule-1 timing bug, not this short-circuit, which had no real-world trigger. The fix is proactive; the regression test is the only proof.) The per-round decision is now made by the pure `lib-review-poll.sh::_classify_unresolved_agent <body> <rc>`: a matched verdict comment is classified FAIL-first and **wins over the launch rc** (the INV-40 precedence made mechanical); an agent with no verdict keeps being polled **regardless of rc** — the rc-vs-no-verdict path is now byte-for-byte identical to the `rc == 0`-vs-no-verdict path sub-rule 1 already protected. There is **no separate post-exit grace timer** (#180 Fix 2): because sub-rule 1 already enlarged the command-mode window to tens of minutes, removing the premature short-circuit turns that window itself into the propagation grace. Terminal `unavailable` is unchanged — an agent that posts no verdict by window-expiry is resolved `unavailable` by the wrapper's **post-window sweep** (the SINGLE terminal resolution point for a no-verdict agent, clean OR non-zero rc), not pre-empted on round 1. The accepted trade-off: a genuinely-crashed non-zero-rc agent (no verdict ever) holds its poll slot until window-expiry even after every sibling resolved — identical to today's behavior for a clean-rc agent that never posts, and the price of never dropping a verdict still in flight. The loop short-circuits the instant **all** agents are resolved, so the happy path is unchanged.

2. **`REVIEW_NEAR_SUCCESS_WINDOW_SECONDS` ≥ `E2E_COMMAND_TIMEOUT_SECONDS` (operator-owned).** The dispatcher-side crash short-circuit ([INV-24](#inv-24-review-wrapper-dead-detection-requires-both-pid_alive-miss-and-no-near-success-pr-signal)) defaults to 300 s. If it is smaller than the command-mode E2E, the dispatcher declares the still-working review wrapper "crashed" on a `pid_alive` miss and the next tick's `kill_stale_wrapper` SIGTERMs it mid-E2E; the killed CLI exits non-zero with no verdict → dropped. The wrapper cannot fix this itself (the window lives in the dispatcher's conf), so the contract is documented and the operator must raise it. `HEARTBEAT_INTERVAL_SECONDS` keeping `pid_alive` fresh ([INV-29](#inv-29-pid_alive-heartbeat-is-owned-exclusively-by-the-wrapper-not-by-the-pid-file-alone)) is the complementary defense — together they keep the long-running command-mode review wrapper classified ALIVE.

**Side-effect mitigations (same PR):**

- **Orphan reap.** After verdict resolution the wrapper calls `_reap_fanout_processes` (in `lib-review-poll.sh`), group-killing (`kill -TERM -- -<pgid>`, escalating to `KILL`) any still-running fan-out agent process group. **It kills the AGENT'S setsid PGID, NOT the fan-out subshell PID.** The fan-out backgrounds each agent in a plain `( … ) &` subshell; the wrapper runs with NO job control (`set -m` is never enabled), so that subshell does *not* get its own process group — its PID is *not* a group leader (the same reason `kill -- -$$` is a no-op, see [INV-23](#inv-23-pid_file-points-at-a-process-whose-death-reaps-the-entire-agent-subtree)). The real session/group leader is the `setsid`-spawned agent, whose PID == PGID is captured in `lib-agent.sh::_run_with_timeout`'s `_AGENT_RUN_PID` and written to a PRIVATE per-agent PGID sidecar (each subshell points `AGENT_PID_FILE` at that sidecar — NOT the shared `review-<N>.pid`, which would thrash the dispatcher's liveness model). The wrapper drains those sidecars into `_AGENT_PGIDS` and passes them to the reaper. No-op when every agent already exited (the common case — the fan-out `wait` returned first); a real reap only for a dropped agent whose CLI lingered. So a dropped agent does not keep running (and spending tokens) after its verdict can no longer count.
- **Duplicated pre-hook shrink (best-effort, not a hard cap).** In multi-agent mode (`AGENT_REVIEW_AGENTS` ≥2, signalled to `build_review_prompt` via a 3rd arg) the command-mode prompt instructs each agent to re-check for a sibling's SHA-matching `<!-- e2e-evidence: complete sha="..." -->` comment **immediately before** running `E2E_COMMAND_PRE_HOOKS`, reusing it when present. This shrinks — but does not provably eliminate — the duplicated pre-hook window (all N agents can reach the re-check in the same sub-second window before any sibling posts evidence). The honest limitation is documented in `references/e2e-command-mode.md`; the wrapper-level "run pre-hook once before fan-out" strong guarantee is deferred (it changes the command-mode contract).

**N=1 / non-command carve-out (backward compatibility)**: for `E2E_MODE != command`, `_resolve_verdict_poll_attempts` returns `6` — the poll loop is byte-for-byte the legacy 30 s window. For single-agent review (`AGENT_REVIEW_AGENTS` unset → one agent), the multi-agent prompt signal is `false` and the prompt is byte-for-byte legacy; `_reap_fanout_processes` is a no-op for the lone already-exited subshell.

**Why**: surfaced by #172. A consumer running `E2E_MODE=command` with `AGENT_REVIEW_AGENTS` (2 agents) + a heavy `E2E_COMMAND_PRE_HOOKS` (container build, 10–30 min) + a raised `E2E_COMMAND_TIMEOUT_SECONDS` (2700) saw the diligent agent that ran the full E2E (~45 min wall-clock) dropped as `unavailable` while the faster agent that did less became the sole decider — losing the multi-model cross-check the project configured, duplicating heavy CI/registry work, and leaking agent processes. The 30 s poll window and the 300 s stall window were both structurally smaller than the E2E, so the agent honoring the contract was guaranteed to be dropped on heavy-E2E PRs.

**Producer**: `autonomous-review.sh` (`_resolve_verdict_poll_attempts` wiring, the `_run_verdict_poll_loop` call + the single post-window `unavailable` sweep, the multi-agent prompt signal) + `lib-review-poll.sh` (`_resolve_verdict_poll_attempts`, `_run_verdict_poll_loop`, `_fetch_agent_verdict_body`, `_classify_unresolved_agent`, `_classify_verdict_body`, `_reap_fanout_processes`) + operator config (`REVIEW_NEAR_SUCCESS_WINDOW_SECONDS`).

**Consumer**: the wrapper's per-agent verdict-poll loop (sub-rules 1 + 1b) and the dispatcher's `review_near_success` ([INV-24](#inv-24-review-wrapper-dead-detection-requires-both-pid_alive-miss-and-no-near-success-pr-signal), sub-rule 2).

**Status**: **ENFORCED**. Sub-rule 1 (#172) + the side-effect mitigations + sub-rule 1b (no early non-zero-rc drop, #180) are wrapper-enforced; sub-rule 2 is documented-contract (operator config) — the matching `INV-24` window has no code change.

**Test**:
- `tests/unit/test-review-e2e-command-poll-budget.sh` — TC-RPB-RES-01..09 (pure resolver: non-command→6, command scales with `E2E_COMMAND_TIMEOUT_SECONDS`, floor + defensive fallbacks), TC-RPB-SRC-01..10 (source-of-truth: lib sourced, poll loop uses the resolved var, reap helper defined + invoked + negative-PID group kill, `build_review_prompt` multi-agent arg, INV-43 reference, `bash -n`), TC-RPB-REG-01..04 (no hardcoded `seq 1 6`, resolver-driven default, INV-40 aggregation unchanged, `emit_verdict_trailer` count unchanged), TC-RPB-DOC-01..06 (ref doc + invariants + flow doc + conf cross-refs).
- `tests/unit/test-review-cli-exit-grace.sh` (#180) — TC-CXG-DEC-01..07 (pure `_classify_unresolved_agent`: a matched verdict wins over any rc → pass/fail; no verdict → `keep` regardless of rc, never `unavailable`), TC-CXG-LOOP-01..05 (the **mandatory loop regression** driving `_run_verdict_poll_loop` with the verdict-fetch + sleep + log stubbed: a non-zero-rc agent whose verdict lands on round ≥2 is counted `pass` not dropped; a never-posting non-zero-rc agent resolves `unavailable` only at window-expiry; a slower sibling is not dropped; the happy path settles in one round), TC-CXG-LIB/SRC/DOC (lib + wrapper wiring greps incl. the regression that the immediate `rc != 0 → unavailable` short-circuit AND the grace constant/array are gone, the all-unavailable discriminator is untouched, plus doc presence).
- Backward-compat gate: the full pre-existing review/verdict/e2e-command regression sweep (`test-autonomous-review-multi-agent`, `test-e2e-mode-command`, `test-autonomous-review-prompt`, `test-autonomous-review-per-agent-model`, `test-autonomous-review-per-agent-launcher`, `test-review-e2e-command-poll-budget`) stays green; the happy path (every agent posts a verdict in round 1) is byte-for-byte unchanged since a found verdict short-circuits before the rc is ever considered.

**Cross-references**:
- [INV-24](#inv-24-review-wrapper-dead-detection-requires-both-pid_alive-miss-and-no-near-success-pr-signal) — the dispatcher-side stall window sub-rule 2 governs; raising `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS` keeps the command-mode review wrapper ALIVE.
- [INV-29](#inv-29-pid_alive-heartbeat-is-owned-exclusively-by-the-wrapper-not-by-the-pid-file-alone) — the heartbeat that keeps `pid_alive` fresh through a long command-mode E2E.
- [INV-23](#inv-23-pid_file-points-at-a-process-whose-death-reaps-the-entire-agent-subtree) — setsid PGID semantics the orphan reap relies on.
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the multi-agent fan-out + `unavailable` definition this protects; the verdict-poll loop and aggregation are otherwise unchanged.
- [`review-agent-flow.md` § Verdict polling](review-agent-flow.md#verdict-polling) / [§ command-mode E2E](review-agent-flow.md) — runtime walkthrough.
- [`docs/designs/review-e2e-command-poll-budget.md`](../designs/review-e2e-command-poll-budget.md) — design canvas (sub-rule 1, #172).
- [`docs/designs/multi-agent-cli-exit-grace.md`](../designs/multi-agent-cli-exit-grace.md) — design canvas (sub-rule 1b, no early non-zero-rc drop, #180).
- [`skills/autonomous-review/references/e2e-command-mode.md`](../../skills/autonomous-review/references/e2e-command-mode.md) — operator-facing window-tuning guidance.

## INV-44: Mergeable hard gate — a CONFLICTING PR can never reach `approved`

**Rule**: after `autonomous-review.sh` aggregates the per-agent verdicts to PASS, and BEFORE it acts on that PASS (the `emit_verdict_trailer "passed"` + approve/merge branch), the wrapper re-queries the PR's `mergeable` status and gates on it **mechanically** — independently of whether the review agent ran its Step-0 pre-review rebase prompt. The decision is computed by the pure `lib-review-mergeable.sh::_classify_mergeable_gate <mergeable>` helper:

| `mergeable` (case-insensitive) | gate | wrapper action |
|---|---|---|
| `MERGEABLE` | `proceed` | fall through to the existing PASS branch — **byte-for-byte unchanged** |
| `CONFLICTING` | `block-substantive` | override the PASS: post a `[BLOCKING] Merge conflict with main` finding on the issue + an `Auto-merge failed:`-prefixed marker on the PR (reusing the dev-resume rebase hook, [INV-33](#inv-33-review-wrapper-must-not-close-the-linked-issue)), emit `failed-substantive`, `−reviewing +pending-dev`, `exit 0` |
| `UNKNOWN` / empty / any other token | `block-nonsubstantive` | do NOT auto-approve: post a "review held" status comment, emit `failed-non-substantive` with cause `mergeable-unknown`, `−reviewing +pending-dev`, `exit 0` |

Two sub-rules:

1. **Conservative classification.** The ONLY value that yields `proceed` is a case-insensitive `MERGEABLE`. Everything else blocks. This closes the **stale-`UNKNOWN` pass-through**: the prior prompt-side protocol (`references/merge-conflict-resolution.md`) said "after 3 retries still UNKNOWN → treat as MERGEABLE and proceed", which let a status GitHub had not finished computing be silently approved. An empty string (from a failed `gh pr view`) also blocks — fail-closed.

2. **UNKNOWN retry budget in the wrapper.** GitHub computes `mergeable` asynchronously, so the wrapper polls `gh pr view --json mergeable` up to `MERGEABLE_RETRIES` (default 3, 10s apart) while the value is UNKNOWN/empty, then classifies the settled value once. A value that never settles is `block-nonsubstantive` (re-queue), never `proceed`.

**Routing rationale**: the gate routes to the existing `pending-dev` state (keeping `autonomous`) rather than introducing a new label — no new state-machine node, only a new *reason* for the existing `reviewing → pending-dev` transition. For `CONFLICTING`, the `Auto-merge failed:` PR marker gives the conflict a deterministic owner: the dev-resume branch ([`dev-agent-flow.md`](dev-agent-flow.md), [INV-33](#inv-33-review-wrapper-must-not-close-the-linked-issue)) detects that marker and prepends a mandatory `git rebase origin/main && git push --force-with-lease` pre-step. For `UNKNOWN`, no PR marker is posted (there may be no real conflict, so an unconditional rebase would be wasteful); the `failed-non-substantive` trailer makes the dispatcher's `handle_completed_session_routing` flip the issue back to `pending-review` (re-review) under the `REVIEW_RETRY_LIMIT` cap ([INV-35](#inv-35-review-aware-resume-routing-for-completed-sessions)).

**N=1 / happy-path carve-out (backward compatibility)**: when `mergeable == MERGEABLE` (the common case) the gate evaluates `proceed` and the wrapper falls straight through to the existing PASS branch — approve, no-auto-close handling, and auto-merge are all byte-for-byte today's behavior. The gate adds exactly one `gh pr view --json mergeable` call on the PASS path (plus retries only while UNKNOWN); the FAIL / crash / all-unavailable paths add no new `gh` call. The clean-rebase path the review agent performs in Step 0 (force-push then proceed) is untouched — that happens before aggregation; the gate only adds a final post-aggregation check.

**Why**: a CONFLICTING PR receiving a PASS verdict is a structurally invalid outcome — the same shape as the prompt-only E2E-poll gap closed earlier. A dev-resume round that fixes findings and pushes but does NOT rebase onto a since-advanced base leaves the PR `CONFLICTING`; if the review agent then reaches a verdict from its findings (code looks fine) and posts PASS without running Step 0, the issue lands in terminal `approved` with the conflict owned by nobody (dev already exited, review said PASS). Enforcing `mergeable != MERGEABLE → FAIL` in the wrapper makes the merge-conflict block mechanical, mirroring the decision gate's "any blocking finding → FAIL" philosophy ([#176](https://github.com/zxkane/autonomous-dev-team/issues/176)).

**Producer**: `autonomous-review.sh` — the post-aggregation gate block (the `gh pr view --json mergeable` query + `MERGEABLE_RETRIES` UNKNOWN-retry loop + the two block branches) and `lib-review-mergeable.sh::_classify_mergeable_gate` (the pure decision helper).

**Consumer**: the wrapper's own PASS branch (only reached when the gate is `proceed`); the dev-resume rebase hook ([INV-33](#inv-33-review-wrapper-must-not-close-the-linked-issue)) and the dispatcher's `handle_completed_session_routing` ([INV-35](#inv-35-review-aware-resume-routing-for-completed-sessions)) consume the routing the block branches produce.

**Status**: **ENFORCED** in this PR (closes #176).

**Test**:
- `tests/unit/test-autonomous-review-mergeable-gate.sh` — TC-MG-CLS-01..08 (pure decision logic over `_classify_mergeable_gate`: MERGEABLE→proceed, CONFLICTING→block-substantive, UNKNOWN/empty/garbage→block-nonsubstantive, case-insensitivity, and the "only MERGEABLE proceeds" stale-UNKNOWN-closure property) and TC-MG-SRC-01..12 (source-of-truth greps: lib sourced, `gh pr view --json mergeable` query, `_classify_mergeable_gate` call, `PASSED_VERDICT==true` guard, CONFLICTING `[BLOCKING]` finding + `Auto-merge failed:` PR marker + `failed-substantive` trailer, UNKNOWN `failed-non-substantive mergeable-unknown` trailer, both block paths `−reviewing +pending-dev`, `MERGEABLE_RETRIES` retry loop, `emit_verdict_trailer` count grew by exactly 2, `bash -n`).
- Backward-compat gate: `test-autonomous-review-multi-agent`, `test-autonomous-review-auto-merge-failure`, `test-autonomous-review-prompt`, `test-autonomous-review-verdict-trailer` stay green — the gate reuses the `Auto-merge failed:` marker prefix and adds no `gh issue close` / `−autonomous`, so the #145 pins hold.

**Cross-references**:
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the aggregation whose PASS result this gate re-checks; the gate runs after `_aggregate_review_verdicts` and the downstream PASS branch is otherwise unchanged.
- [INV-33](#inv-33-review-wrapper-must-not-close-the-linked-issue) — the `Auto-merge failed:` PR marker the CONFLICTING path reuses to trigger dev-resume rebase; the gate also never closes the issue.
- [INV-35](#inv-35-review-aware-resume-routing-for-completed-sessions) — the verdict-trailer routing the UNKNOWN (`failed-non-substantive`) and CONFLICTING (`failed-substantive`) paths emit.
- [`review-agent-flow.md` § Mergeable hard gate](review-agent-flow.md#mergeable-hard-gate-inv-44) — runtime walkthrough.
- [`state-machine.md` § Transition table](state-machine.md#transition-table) — the two new `reviewing → pending-dev` rows (CONFLICTING / mergeable-UNKNOWN).
- [`docs/designs/mergeable-hard-gate.md`](../designs/mergeable-hard-gate.md) — design canvas.
- [`skills/autonomous-review/references/decision-gate.md`](../../skills/autonomous-review/references/decision-gate.md) / [`merge-conflict-resolution.md`](../../skills/autonomous-review/references/merge-conflict-resolution.md) — agent-side reinforcement + the tightened `UNKNOWN` protocol.

## INV-45: Pushed-branch-with-commits-ahead + no PR ⇒ resume to open-PR-only, never full re-dev

**Rule**: when a dev session is (re)dispatched for an issue whose head branch is **already pushed to origin with commits ahead of the base branch** but for which **no open PR exists**, the dev wrapper MUST steer the agent **straight to the open-PR step** (Step 7 `gh pr create`) and MUST NOT cause design/test/implement to be re-run from scratch. Development is effectively complete; only PR creation remains.

`autonomous-dev.sh::needs_open_pr_only <issue_num>` is the detector. It returns 0 (engage the fast path) only when BOTH hold:

1. **No open PR for the issue** — `gh pr list --state open` filtered by the same `#<N>` body-reference selector the cleanup trap uses. A PR existing means the existing PR-exists handoff (`handle_pending_dev_pr_exists`, Bug-3/#99) owns the routing — NOT this fast path.
2. **A head branch is pushed to origin and is ahead of base** — the branch name is **agent-chosen** (`feat/issue-${N}*` *or* `fix/issue-${N}*`, or any other `*issue-${N}*` suffix), so detection **globs** `git ls-remote origin 'refs/heads/*issue-${N}*'` rather than assuming a fixed name. A candidate is "ahead" when `git rev-list --count origin/<base>..<sha> > 0`; when the objects are remote-only (rev-list can't count locally), a head SHA that **differs** from the base head SHA is treated as ahead. Each candidate ref is additionally regex-anchored on `issue-<N>` followed by a non-digit or end-of-ref, so an unrelated `issue-1789` branch never satisfies issue `178`.

When `needs_open_pr_only` returns 0, `emit_open_pr_fast_path_block` produces the `## Open-PR-only fast path` prompt block, which is interpolated into **all three** prompt builders — `MODE=new`, `MODE=resume`, and the resume-fallback full prompt — so the fast path engages regardless of which mode the dispatcher routed (a key property: after enough resume failures the dispatcher can route a fresh `dev-new`, but the branch is still on origin). The block instructs the agent to check out the pushed branch, SKIP design/test/implement, and go straight to `gh pr create` with a body containing `Closes #<N>`.

**Fail-closed**: any error (e.g. `git ls-remote` transport failure, non-numeric PR count) returns 1 — the wrapper falls back to the normal full workflow. A false fast path that skipped real development is strictly worse than a redundant full re-dev, so the detector never engages on uncertainty.

**[INV-06](#inv-06-crashed--process-not-found-keyword-contract) keyword contract**: the fast-path block is forward-progress **prompt** text, not a status comment, and contains none of the crash keywords (`Task appears to have crashed`, `process not found`) that Step 4a's `count_retries` keys on. This change posts **no** new issue/PR comment, so it cannot miscount the recovery as a crash.

**Why**: `autonomous-dev/SKILL.md` Step 7 runs `git push -u origin <branch>` immediately before `gh pr create`. A session interrupted between those two commands leaves a pushed branch with commits ahead of base but no PR. Both dispatcher routes to `pending-dev` (Step 5b's DEAD-no-PR branch once [INV-27]'s `dev_near_success` goes negative, and Step 4's `handle_pending_dev_pr_exists` returning 1 on "no PR") then re-run the **entire** dev wrapper — re-fetch, re-test, re-implement — only to reach `gh pr create` again, where the same interruption can recur. The observed effect ([#178](https://github.com/zxkane/autonomous-dev-team/issues/178)) is an `in-progress ↔ pending-dev` oscillation (4 consecutive "no PR" retries before self-healing on the 5th) even though the branch + commit sat on origin the whole time. Making resume cheap means it can't burn its window re-testing.

**Architecture note**: PR creation lives entirely inside the dev wrapper/agent (`gh pr create` appears only in `autonomous-dev/SKILL.md`, executed by the agent with its own PR-body generation). The dispatcher only routes; under `EXECUTION_BACKEND=remote-aws-ssm` it has no worktree and runs on a different box, so it **cannot** call `gh pr create` itself. INV-45 therefore lives wrapper-side (the detector queries origin directly via `git ls-remote`, networked and worktree-free) and works whether the dispatcher routes `dev-new` or `dev-resume`. The optional dispatcher-side hint (route a pushed-branch-no-PR issue to an explicitly open-PR-only resume) is intentionally **not** implemented — it would duplicate the `git ls-remote` probe on the dispatcher box for no behavioral gain once the wrapper is cheap.

**Producer**: `autonomous-dev.sh::needs_open_pr_only`, `autonomous-dev.sh::emit_open_pr_fast_path_block`, and the `OPEN_PR_FAST_PATH` interpolation in the three prompt builders.

**Consumer**: the dev agent following the `/autonomous-dev` skill — it reads the fast-path block and short-circuits to Step 7.

**Status**: **ENFORCED** in this PR (closes #178).

**Test**:
- `tests/unit/test-autonomous-dev-pushed-no-pr-resume.sh` — TC-CR-001..003 (feat/fix/non-default-suffix branch, ahead, no PR → fast path), TC-CR-004 (no pushed branch → full re-dev), TC-CR-005 (zero-ahead branch → full re-dev), TC-CR-006 (open PR exists → helper returns 1, PR-exists handoff unchanged), TC-CR-007 (`ls-remote` failure → fail-closed), TC-CR-008 (different-SHA ahead fallback), TC-CR-015 (issue-1789 must not satisfy issue 178); plus source-of-truth greps TC-CR-009..014 (helper defined + gated, block names the fast path, instructs skipping design/test/implement, points at `gh pr create`, [INV-06] keyword absence, branch glob, ≥2 prompt builders) and TC-CR-013 (`bash -n`).

**Cross-references**:
- [INV-27](#inv-27-dev-wrapper-dead-detection-requires-both-pid_alive-miss-and-no-near-success-in-flight-signal) — the Step 5b dev near-success gate whose negative result is one of the two routes that lands the issue back in `pending-dev`; INV-45 makes the subsequent resume cheap rather than preventing the route.
- `handle_pending_dev_pr_exists` (Bug-3/#99) — the sibling Step 4 helper that handles **PR exists → review**; INV-45 covers the missing third state (**branch pushed, commits ahead, no PR → open-PR-only resume**).
- [INV-33](#inv-33-review-wrapper-must-not-close-the-linked-issue) — the `Auto-merge failed:` rebase hook the resume prompt also detects. The two blocks are **mutually exclusive**: `needs_open_pr_only` engages only when no PR exists, whereas the auto-merge-failure marker is only populated when a PR exists — so a single resume prompt never carries both.
- [`dev-agent-flow.md` § Open-PR-only fast path](dev-agent-flow.md#open-pr-only-fast-path-inv-45) — runtime walkthrough.

## INV-46: E2E runs ONCE in a dedicated lane before the review fan-out — gated, not per-agent

**Rule**: when `E2E_MODE` is active (`browser` or `command`), `autonomous-review.sh` MUST run the project E2E **exactly once per review round** in a dedicated lane that runs to completion **before** the review fan-out, compute a mechanical **E2E hard gate** from the lane's result, and only fan out the N review agents on a gate pass. The review agents are PURE code reviewers — `build_review_prompt` MUST NOT contain any E2E execution block; the prompt instead instructs the agent to READ the wrapper-posted E2E evidence comment as input. A gate FAIL short-circuits to the FAIL route (`−reviewing +pending-dev`) **without** spawning the review agents at all.

Five sub-rules:

1. **E2E runs once, sequentially, before fan-out.** The wrapper runs the Phase-A E2E lane — an inline `if [[ "${E2E_ACTIVE}" == "true" ]]` block that dispatches `command`→`_run_command_e2e_lane` (shell) / `browser`→one `run_agent` lane — before the `for _agent in "${REVIEW_AGENTS_LIST[@]}"` fan-out loop. Because the fan-out has not started when the lane runs, the (expensive) `E2E_COMMAND_PRE_HOOKS` structurally **cannot** run N times — the strong guarantee that supersedes the pre-#182 best-effort "duplicated pre-hook shrink" ([INV-43](#inv-43-command-mode-e2e-review-wait-budgets-must-not-be-smaller-than-the-e2e-they-dispatched) side-effect mitigation, whose prompt-side sibling-evidence re-check all N agents could race past).

2. **command-mode lane is a pure SHELL subshell (non-LLM, token-free).** For `E2E_MODE=command`, `lib-review-e2e.sh::_run_command_e2e_lane` runs the rendered pre-hooks → verify → parser → evidence-post entirely in shell — NO `run_agent`. The verify command runs under `setsid` + `timeout --kill-after=30s --signal=TERM ${E2E_COMMAND_TIMEOUT_SECONDS}` (`_run_command_e2e_verify`), so its child subtree shares a new process group reachable for reaping ([INV-23](#inv-23-pid_file-points-at-a-process-whose-death-reaps-the-entire-agent-subtree) PGID semantics); the lane's PGID is exposed via `_E2E_LANE_PGID` and added to the wrapper's `_reap_fanout_processes` arg list + the SIGTERM trap reach. The exit-code semantics are unchanged from `references/e2e-command-mode.md` (`0` → parser; `124` → parser on partial, recover-or-fail; other → skip parser, log-tail, fail). Every fallible step is guarded `|| rc=$?` so `set -e` cannot abort the lane before the `.rc` sidecar is written — a non-zero pre-hook still WRITES the sidecar.

3. **browser-mode stays an LLM lane, but exactly ONE.** `E2E_MODE=browser` needs an LLM to drive Chrome DevTools MCP, so it remains a single LLM-driven lane (`run_agent` against `build_browser_e2e_prompt`), NOT replicated across the N review agents. The LLM runs the smoke test and posts a `## E2E Verification Report` PR comment (tables, screenshots, AC results); the **WRAPPER** (not the LLM) then mechanically stamps `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->` **onto that report comment** via `lib-review-e2e.sh::_stamp_browser_evidence_marker` (REST `PATCH issues/comments/<id>`, idempotent), so the gate anchor is deterministic (the LLM never transcribes the SHA). The marker MUST be stamped onto the report, NOT posted as a standalone marker-only comment: `_fetch_sha_evidence` selects the latest comment containing the marker, so a marker-only comment would (a) let the gate pass with no real evidence and (b) hand the review agents a comment with no tables/screenshots/AC. If the lane exits clean but no report comment can be found to stamp, `_stamp_browser_evidence_marker` returns non-zero and the wrapper forces the lane rc non-zero → the gate **fails closed** (no marker-only pass). The report comment is matched by the INV-20 binding (latest comment by `BOT_LOGIN`, `created_at >= WRAPPER_START_TS`, body contains `## E2E Verification Report`; the actor predicate is dropped on the `BOT_LOGIN`-empty fallback).

4. **E2E hard gate = mechanical dual-signal.** `lib-review-e2e.sh::_classify_e2e_gate <rc> <evidence_present>` decides from two independent signals: (a) the lane's `.rc` == 0 (≡ pre-hooks=0 ∧ verify∈{0,124-recovered} ∧ parser=0 ∧ comment-post ok), AND (b) a re-fetch (`_fetch_sha_evidence`, bounded retry) finds a SHA-matching evidence comment for the **captured** `PR_HEAD_SHA`. Truth table: `rc=0`+evidence → `pass`; `rc=0`+no-evidence → `block-nonsubstantive` (crash between parser-ok and comment-post, OR transient GitHub on the re-fetch — **fail closed**, re-queue for re-review, NOT a substantive dev bounce); `rc≠0`+(any) → `fail` (a stale-but-present evidence comment does NOT rescue a failed run); non-numeric rc → `fail` (only a literal `0` passes).

5. **The gate is mandatory, AND-ed with review unanimity, placed before INV-44.** The composed decision is `final PASS ≡ (E2E_ACTIVE==false OR e2e_gate==pass) AND review-unanimity-pass`. Because a gate `fail` / `block-nonsubstantive` exits the wrapper before the fan-out, only `e2e_gate ∈ {pass, inactive}` ever reaches the review aggregation — the AND is enforced structurally by the early short-circuit, not by a re-check after fan-out. The gate is a **mandatory** gate (NOT a voter subject to [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)'s unavailable tolerance) and runs before the [INV-44](#inv-44-mergeable-hard-gate--a-conflicting-pr-can-never-reach-approved) mergeable block and the PASS branch.

**Routing**: `fail` → `[BLOCKING] E2E verification failed` finding on the issue + `failed-substantive` trailer + `−reviewing +pending-dev` (no PR rebase marker — an E2E failure is a code fix, not a rebase). `block-nonsubstantive` → "Review held" comment + `failed-non-substantive` cause `e2e-evidence-missing` + `−reviewing +pending-dev` (re-queue; the next tick re-checks once the evidence propagates) — mirroring [INV-44](#inv-44-mergeable-hard-gate--a-conflicting-pr-can-never-reach-approved)'s `mergeable-UNKNOWN` routing.

**Why**: pre-#182 the E2E execution block was injected into every review agent's prompt, so `AGENT_REVIEW_AGENTS` with N CLIs ran the full E2E N times — N× `E2E_COMMAND_PRE_HOOKS` (e.g. a container image build dispatched 3 times in one round on a downstream consumer), N× `E2E_COMMAND` (real deploy/poll/LLM calls), N× evidence generation. The per-agent runs also raced on shared stage state (N agents submitting the same fixture → collisions → each re-submits) and the slowest agent's long E2E stalled or was dropped from verdict collection ([INV-43](#inv-43-command-mode-e2e-review-wait-budgets-must-not-be-smaller-than-the-e2e-they-dispatched) sub-rule 1 addressed the *drop*; INV-46 addresses the *root* N×-redundancy). The pre-#182 "duplicated pre-hook shrink" was explicitly best-effort and documented as such (`e2e-command-mode.md` §3 "honest limitation / no silent cap"); INV-46 lands the deferred strong guarantee: the wrapper runs the pre-hook once before any fan-out.

**Sequential, not parallel (rejected)**: the first design draft ran E2E as a parallel (N+1)th lane overlapping the review agents, with two-phase review agents polling for E2E evidence mid-review. That stacks two [INV-43](#inv-43-command-mode-e2e-review-wait-budgets-must-not-be-smaller-than-the-e2e-they-dispatched)-scaled poll windows serially (agent-side evidence wait + the wrapper's post-exit verdict poll), pushing worst-case wall-clock to `~2 × E2E_COMMAND_TIMEOUT_SECONDS` — past the `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS` operators set per INV-43 sub-rule 2, so the dispatcher would SIGTERM the still-working wrapper and reproduce the very #172 failure this work fixes. It also created a `.rc`-sidecar-lifetime race against `_FANOUT_DIR` cleanup. The sequential design dissolves both structurally; review-to-E2E wall-clock overlap is given up on purpose (a heavy E2E dwarfs ~1–2 min code review).

**Producer**: `autonomous-review.sh` — the Phase-A E2E lane orchestration + gate block (before the fan-out loop), the gate-fail / block-nonsubstantive early-exit routes, the browser-lane report-stamp call (forcing rc non-zero when no report can be stamped), and the E2E-block removal from `build_review_prompt`. `lib-review-e2e.sh` — the pure helpers (`_classify_e2e_gate`, `_fetch_sha_evidence`, `_run_command_e2e_lane`, `_run_command_e2e_verify`, `_stamp_browser_evidence_marker`, `build_browser_e2e_prompt`).

**Consumer**: the wrapper's own review fan-out (only reached on a gate pass) and the downstream PASS / FAIL branches; the dev-resume routing for the `failed-substantive` / `failed-non-substantive` trailers ([INV-35](#inv-35-review-aware-resume-routing-for-completed-sessions)). The dispatcher and the `reviewing` label are unaffected — the lane + gate are entirely internal to the wrapper.

**N=1 / non-E2E carve-out (backward compatibility)**: `E2E_MODE=none` → `E2E_ACTIVE=false` → no lane, no gate, `E2E_GATE=inactive`; the review fan-out + aggregation are byte-for-byte today's. N=1 single review agent: E2E runs once (it always did per-agent before; now it runs once in the lane), then the single review agent runs as a pure code reviewer. The INV-40 / INV-43 / INV-44 contracts are all preserved — the E2E gate is a NEW layer composed before them, not a replacement.

**Status**: **ENFORCED** in this PR (closes #182).

**Test**:
- `tests/unit/test-autonomous-review-sequential-e2e.sh` — TC-SE2E-GATE-01..07 (`_classify_e2e_gate` truth table incl. crash-after-parser fail-closed + defensive non-numeric rc), TC-SE2E-LANE-01..07 (`_run_command_e2e_lane` harness: pre-hook-fail skips parser + writes sidecar, verify-0/124/other exit semantics, SHA-match reuse skips pre-hook, **set -e discipline writes the `.rc` on a failing pre-hook**), TC-SE2E-FETCH-01..03 (`_fetch_sha_evidence` present/absent + bounded-retry-then-empty), TC-SE2E-REG-01 (**the N×-build regression: pre-hook invoked EXACTLY once for an N=3 round**), TC-SE2E-AGG-01..06 (aggregation truth table: E2E gate ∧ review unanimity, incl. configured-no-evidence → re-queue), TC-SE2E-SRC-01..11 (source-of-truth: lib sourced, lane before fan-out, command lane is shell / setsid+timeout, lane PGID in reaper, `build_review_prompt` drops the E2E execution block + reads the posted evidence, gate before INV-44, `bash -n`), TC-SE2E-STAMP-01..07 (browser-mode report stamp, **the codex review fix**: report present → REST PATCH onto the report; **NO report → fails closed (the marker-only-comment regression)**; idempotent re-stamp; the wrapper routes through `_stamp_browser_evidence_marker` and never posts a standalone marker-only comment; stamp failure forces E2E FAIL), TC-SE2E-DOC-01..03 (this invariant + flow + ref doc presence).
- Backward-compat gate: `test-autonomous-review-multi-agent`, `test-review-e2e-command-poll-budget`, `test-review-cli-exit-grace`, `test-autonomous-review-mergeable-gate`, `test-e2e-mode-command`, `test-autonomous-review-prompt`, `test-autonomous-review-per-agent-model`, `test-autonomous-review-per-agent-launcher` stay green.

**Cross-references**:
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the multi-agent fan-out this gates; the fan-out machinery, bounded `wait`, and unanimous-PASS aggregation are unchanged.
- [INV-43](#inv-43-command-mode-e2e-review-wait-budgets-must-not-be-smaller-than-the-e2e-they-dispatched) — the per-agent-E2E poll-window scaling whose root cause (N agents each running E2E) INV-46 removes; the verdict-poll budget still scales for the residual review-verdict wait, and `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS` ≥ `E2E_COMMAND_TIMEOUT_SECONDS` is still required (the lane runs synchronously inside the wrapper, so the dispatcher must not SIGTERM it mid-E2E).
- [INV-44](#inv-44-mergeable-hard-gate--a-conflicting-pr-can-never-reach-approved) — the sibling mechanical gate; INV-46's E2E gate runs before it, so an E2E-failing PR never reaches the mergeable check or the PASS branch.
- [INV-23](#inv-23-pid_file-points-at-a-process-whose-death-reaps-the-entire-agent-subtree) — the setsid PGID semantics the command lane's reapable verify subtree relies on.
- [INV-35](#inv-35-review-aware-resume-routing-for-completed-sessions) — the `failed-substantive` / `failed-non-substantive` trailers the gate-fail / block routes emit.
- [`review-agent-flow.md` § Sequential E2E lane](review-agent-flow.md#sequential-e2e-lane-inv-46) — runtime walkthrough.
- [`docs/designs/sequential-e2e-before-fanout.md`](../designs/sequential-e2e-before-fanout.md) — design canvas.
- [`skills/autonomous-review/references/e2e-command-mode.md`](../../skills/autonomous-review/references/e2e-command-mode.md) — the command-mode contract the wrapper-run lane preserves (this closes the §3 deferral).

## INV-48: Per-side review wall-clock timeout (AGENT_REVIEW_TIMEOUT, 1h default) with browser-E2E exclusion and timeout-veto

**Rule**: `autonomous-review.sh` MUST cap REVIEW-agent CLIs with a **per-side** wall-clock timeout that defaults to **1h** (not the shared 4h [INV-13](#inv-13-wall-clock-cap-on-agent-invocations) `AGENT_TIMEOUT`), operator-overridable via `AGENT_REVIEW_TIMEOUT`. The dev wrapper (`autonomous-dev.sh`) is UNTOUCHED — it keeps `AGENT_TIMEOUT` (4h). The cap is implemented by **rebinding the live `AGENT_TIMEOUT`** in the review wrapper's per-side override block (next to the [INV-37](#inv-37-per-side-agent_cmd-precedence) `AGENT_CMD` and [INV-38](#inv-38-per-side-agent_launcher-precedence) `AGENT_LAUNCHER_ARGV` rebinds), so [INV-13](#inv-13-wall-clock-cap-on-agent-invocations)'s `_run_with_timeout` (which reads the live `AGENT_TIMEOUT` at call time) and agy's `--print-timeout "$AGENT_TIMEOUT"` apply the review cap to every review fan-out agent with no change to `lib-agent.sh`'s invocation sites.

Four sub-rules:

1. **Rebind order + 1h literal default.** The rebind MUST come AFTER `source lib-auth.sh` (which transitively re-sources the conf's unconditional `AGENT_TIMEOUT="4h"`) and BEFORE the `: "${PROJECT_ID:?}"` validation — exactly the position the INV-37/INV-38 rebinds occupy, for the same clobber reason. It captures `_ORIG_AGENT_TIMEOUT="$AGENT_TIMEOUT"` (the conf 4h) FIRST, then sets `AGENT_TIMEOUT="${AGENT_REVIEW_TIMEOUT:-1h}"`. The default is the **literal `1h`**, NOT an inherit of `AGENT_TIMEOUT` — a code review is ~1–2 min, so a review CLI running for hours is almost always hung, and 1h reaps it ~3h sooner than the 4h dev cap. `AGENT_REVIEW_TIMEOUT=""` (empty) also resolves to 1h.

2. **Browser-mode E2E gets its OWN cap (`E2E_BROWSER_TIMEOUT_SECONDS`, default = the original 4h).** The browser-mode E2E lane ([INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) Phase A) is a normal `run_agent` LLM lane, so it would otherwise inherit the aggressive 1h review cap — and a real browser smoke test against a freshly-deployed preview (slow build / cold start) can legitimately exceed 1h. The lane therefore runs under a LOCAL rebind `AGENT_TIMEOUT="$E2E_BROWSER_TIMEOUT_SECONDS"` *inside its existing subshell* (so the rebind is naturally scoped — the parent's review cap is unchanged for the fan-out, no manual restore needed). `E2E_BROWSER_TIMEOUT_SECONDS` defaults to `_ORIG_AGENT_TIMEOUT` (the conf's 4h), so the review-cap shrink does NOT shrink browser E2E. This is symmetric with command-mode, whose verify already runs under `timeout … ${E2E_COMMAND_TIMEOUT_SECONDS}` (`lib-review-e2e.sh::_run_command_e2e_verify`) and is thus independent of `AGENT_TIMEOUT` — command-mode E2E is unaffected by this invariant.

3. **Timeout-veto ([INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) amendment).** A fan-out review agent whose `AGENT_LAUNCH_RC` is `124` (coreutils `timeout` TERM-expiry) or `137` (the `--kill-after` SIGKILL escalation) AND that posted no verdict is classified **`timed-out`** by `lib-review-aggregate.sh::_classify_noverdict_agent` and counted as a **deciding FAIL** (veto) in `_aggregate_review_verdicts`, NOT dropped as `unavailable`. Every OTHER no-verdict case (clean rc 0, launch failure rc 1, …) remains `unavailable` (dropped), unchanged. This is the single point where INV-40's previously-uniform "no verdict → `unavailable`" window-expiry sweep is split by rc. Rationale: with the review side now capped at 1h, a slow-but-legitimate review (the prompt tells agents to rebase and `gh pr checks --watch` — a >1h CI queue would surface as a review *timeout*) must produce a LOUD FAIL → dev re-dispatch, never a silent pass-through. The veto adds NO new `emit_verdict_trailer` site (it flows through the substantive-FAIL path), one human-visible breadcrumb comment, and a synthesized `LATEST_COMMENT` so an all-timed-out round still routes substantive.

4. **Startup validation (fail-loud).** `validate_review_timeout_config` (mirrors `validate_e2e_config`) rejects `AGENT_REVIEW_TIMEOUT` / `E2E_BROWSER_TIMEOUT_SECONDS` values that are not a positive coreutils-`timeout` value — a positive integer optionally suffixed `s`/`m`/`h`/`d` (e.g. `3600`, `90m`, `2h`, `1d`) — and explicitly rejects `0` (GNU `timeout 0` DISABLES the cap, the opposite of intent). The pure predicate `lib-agent.sh::_is_positive_timeout_value` (next to `AGENT_TIMEOUT`) is the unit-testable core. A startup `log` line reports the resolved review cap, browser-E2E cap, and the (unaffected) dev cap.

**Why**: surfaced by #185. Observed: a 3-agent review fan-out (`kiro agy codex`) where a review CLI silently hung — no output, no exit — for ~3 h. The wrapper's bounded `wait "${_fanout_pids[@]}"` ([INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)) correctly blocked on the hung subshell, so the whole review stalled in `reviewing` (two siblings' verdicts already posted) until the CLI's `timeout 4h` ([INV-13](#inv-13-wall-clock-cap-on-agent-invocations)) would eventually fire. A 1h review cap reaps the hung CLI ~3 h sooner. The original draft made the review default *inherit* `AGENT_TIMEOUT`; it was changed to a 1h literal per operator instruction. An independent codex review then found two ways a naive 1h cap mis-kills legitimate work — browser-mode E2E inheriting the cap, and a >1h CI queue surfacing as a review timeout — addressed by sub-rules 2 and 3 respectively.

**Producer**: `autonomous-review.sh` — the per-side `AGENT_TIMEOUT` rebind + `_ORIG_AGENT_TIMEOUT` capture + `E2E_BROWSER_TIMEOUT_SECONDS` resolution (in the override block), `validate_review_timeout_config` + its startup call, the resolved-cap startup `log` line, the browser-lane LOCAL `AGENT_TIMEOUT` rebind, the post-window sweep's `_classify_noverdict_agent` wiring, and the timeout-veto breadcrumb/`LATEST_COMMENT` synthesis. `lib-agent.sh::_is_positive_timeout_value` (validation predicate). `lib-review-aggregate.sh::_classify_noverdict_agent` (rc→state) + `_aggregate_review_verdicts` (`timed-out` = deciding FAIL).

**Consumer**: every review fan-out agent (capped at the review timeout via [INV-13](#inv-13-wall-clock-cap-on-agent-invocations)'s `_run_with_timeout`), the browser E2E lane (capped at `E2E_BROWSER_TIMEOUT_SECONDS`), and the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) aggregation (a `timed-out` deciding FAIL). The dev wrapper, the dispatcher, and the `reviewing` label are unaffected.

**Dev-side carve-out**: `autonomous-dev.sh` never reads `AGENT_REVIEW_TIMEOUT` and is not modified — the dev side keeps `AGENT_TIMEOUT` (4h, [INV-13](#inv-13-wall-clock-cap-on-agent-invocations)). The N=1 review path (no `AGENT_REVIEW_AGENTS`) still gets the 1h cap on its lone agent; its aggregation truth table is unchanged except the new `timed-out` row.

**Status**: **ENFORCED** in this PR (closes #185).

**Test**:
- `tests/unit/test-review-agent-timeout.sh` — TC-RTO-VAL-01..10b (`_is_positive_timeout_value`: rejects `0`/`0h`/empty/`abc`/`1.5h`/`-5`/`10x`, accepts `90m`/`2h`/`3600`/`1d`/`30s`), TC-RTO-VETO-01..10c (`_classify_noverdict_agent` rc→state for 124/137/1/0/2 + `_aggregate_review_verdicts` with `timed-out` as a deciding FAIL, INV-40 existing rows re-asserted green), TC-RTO-RES-01..03 + TC-RTO-E2E-01..02b (rebind-order simulation: review cap 2h/1h-default/1h-empty, browser cap defaults to the ORIGINAL 4h not the review cap, explicit browser cap honored + review cap still 1h), TC-RTO-SRC-01..06 / TC-RTO-VAL-12 / TC-RTO-VETO-11 (source-of-truth: `_ORIG_AGENT_TIMEOUT` capture, `AGENT_REVIEW_TIMEOUT:-1h` rebind, browser-cap default, dev wrapper does NOT read `AGENT_REVIEW_TIMEOUT`, browser lane rebinds to the browser cap, `validate_review_timeout_config` defined+called, startup log line, `emit_verdict_trailer` count unchanged at 10, post-window sweep uses `_classify_noverdict_agent`, `bash -n`), TC-RTO-SRC-04 / TC-RTO-DOC-01..03 (conf-example + INV-48 + INV-40-`timed-out` + flow-doc presence).
- Backward-compat gate: `test-wrapper-rebind-order`, `test-autonomous-review-multi-agent`, `test-agent-timeout-wrapper`, `test-e2e-mode-command`, `test-review-e2e-command-poll-budget`, `test-autonomous-review-sequential-e2e`, `test-review-cli-exit-grace`, `test-autonomous-review-mergeable-gate`, `test-autonomous-review-prompt`, `test-autonomous-review-per-agent-model`, `test-autonomous-review-per-agent-launcher` stay green.

**Cross-references**:
- [INV-13](#inv-13-wall-clock-cap-on-agent-invocations) — the shared wall-clock cap this rebinds per-side for review; `_run_with_timeout` reads the live `AGENT_TIMEOUT`, which is the entire mechanism.
- [INV-37](#inv-37-per-side-agent_cmd-precedence) / [INV-38](#inv-38-per-side-agent_launcher-precedence) — the sibling per-side review overrides; the `AGENT_TIMEOUT` rebind shares their override-block position and post-`lib-auth.sh` ordering requirement.
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the multi-agent aggregation this amends with the `timed-out` deciding-FAIL veto.
- [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) — the single browser-E2E lane that gets its own `E2E_BROWSER_TIMEOUT_SECONDS` cap; command-mode's `E2E_COMMAND_TIMEOUT_SECONDS` is the symmetric command-side cap.
- [`review-agent-flow.md` § Per-side review timeout](review-agent-flow.md#per-side-review-timeout-inv-48) — runtime walkthrough.
- [`docs/designs/review-agent-timeout.md`](../designs/review-agent-timeout.md) — design canvas.

## INV-49: command-mode E2E may feed the review fan-out a structured AC-coverage artifact — optional, fail-safe

**Rule**: a command-mode E2E evidence parser MAY emit an **optional** structured AC-coverage artifact — a flat JSON object `{ "<criterion-id-or-text>": "pass" | "fail", ... }` — inside an `ac-coverage:begin … ac-coverage:end` HTML-comment fence embedded in its evidence stdout. The wrapper's command-mode E2E lane ([INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent)) extracts + validates it (`jq`) and writes the result to the per-round sidecar `E2E_AC_COVERAGE_FILE` (`/tmp/e2e-ac-coverage-${PR_NUMBER}.json`). When that sidecar is non-empty AND **re-validates** at prompt-read time, each review agent's prompt PREFERS the structured map to verify acceptance-criteria coverage **deterministically** instead of LLM-parsing the free-form markdown table. The artifact is a **review double-check aid only** — it does NOT change the E2E hard gate.

Five sub-rules:

1. **Optional / back-compat.** A parser that emits no fence yields an EMPTY sidecar, and `build_review_prompt` emits the exact post-#182 free-form `## E2E Evidence — READ AS INPUT` block — byte-for-byte the pre-#183 behavior. The structured-map prompt branch is reached **only** when the sidecar is non-empty and passes the prompt-read re-validation (sub-rule 5).

2. **Fail-safe, NOT fail-open.** `lib-review-e2e.sh::_extract_ac_coverage_artifact` validates with `jq`: the body must parse, be a non-empty object, and every value must be exactly `"pass"` or `"fail"`. Any deviation (no fence / unparseable / not an object / bad value domain / empty body / `jq` unavailable) echoes EMPTY and returns 0 — the lane never crashes and a malformed artifact never becomes a passing structured map. `_write_ac_coverage_sidecar` logs an `INV-49` warning when a fence was present but failed validation, then writes the sidecar empty so the fan-out falls back to the free-form double-check. A bad artifact can therefore never silently pass the gate.

3. **Per-round sidecar, write-failure = no map.** `_run_command_e2e_lane` truncates `E2E_AC_COVERAGE_FILE` to empty at lane entry, then re-populates it from THIS round's evidence on the fresh-success path (from the parser output) and the idempotent reuse path (from the re-fetched SHA-matching comment — the fence travels into the SHA-bound comment, so reuse recovers it the same way). `_write_ac_coverage_sidecar` no longer silently swallows a truncate/write failure: if the sidecar cannot be made to hold exactly this round's validated artifact (non-writable / chmodded / not truncatable), it `unset`s `E2E_AC_COVERAGE_FILE` for the rest of the run and logs a warning, so the fan-out reads **no** structured map (the free-form fallback) rather than a possibly-stale prior-round file. A round whose parser stopped emitting the artifact (or emitted a malformed one) gets an empty sidecar, never a prior round's map.

4. **Command-mode only.** The extraction is wired into the command-mode lane only — never into `build_browser_e2e_prompt` / `_stamp_browser_evidence_marker`. Browser-mode evidence is free-form by nature; there is no browser-mode structured equivalent, and the browser lane is byte-for-byte unchanged.

5. **Re-validate at prompt-read time (TOCTOU defense).** `build_review_prompt` does NOT trust the sidecar's bytes — `E2E_AC_COVERAGE_FILE` lives under a predictable, exported `/tmp` path, and PR-controlled command-mode `E2E_COMMAND` / parser code runs between `_write_ac_coverage_sidecar`'s validation and prompt construction, so it could overwrite the file with attacker-chosen content (a prompt-injection / fail-open path). The wrapper therefore re-runs the SAME `jq` validation (`_revalidate_ac_coverage_file`, sharing `_validate_ac_coverage_json` with `_extract_ac_coverage_artifact`) at prompt-read time; only the re-validated, canonicalized (`jq -c`) JSON is interpolated into the prompt, and a now-malformed/replaced sidecar falls back to the free-form block. The check-and-use is a single read inside `build_review_prompt`, so there is no second TOCTOU window between the re-validation and the interpolation.

**Why**: post-[INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent), the N review agents LLM-parse the free-form markdown evidence table to double-check acceptance-criteria coverage. LLM parsing of a free-form table is the weak link on the auto-merge gate: a re-worded header, a merged cell, or a truncated row can make the double-check miss a *failing* criterion (a false-negative that lets a non-covering PR through). The parser already computes the per-criterion pass/fail when it builds the table; exposing it machine-readably makes the review-side double-check deterministic and removes that class of LLM-parse false-negatives. (#183, follow-up to #182.) Sub-rules 3 + 5 were added after an independent codex review found that (a) a predictable exported `/tmp` sidecar read with plain `cat` is a TOCTOU prompt-injection path, and (b) a swallowed truncate/write failure could leak a prior round's sidecar.

**Producer**: `lib-review-e2e.sh` — `_validate_ac_coverage_json` (shared `jq` validator), `_extract_ac_coverage_artifact` (fence-slice + validate), `_write_ac_coverage_sidecar` (write-failure → `unset E2E_AC_COVERAGE_FILE`), and `_revalidate_ac_coverage_file` (prompt-read re-validation), called from `_run_command_e2e_lane` (entry truncate + fresh-success + reuse paths). `autonomous-review.sh` — exports `E2E_AC_COVERAGE_FILE` for command mode; `build_review_prompt` calls `_revalidate_ac_coverage_file` and prefers the structured map only when it returns a valid object.

**Consumer**: the review fan-out agents — each reads the re-validated map via its prompt and verifies acceptance criteria from it (falling back to the free-form comment for criteria absent from the map). No change to the E2E hard gate ([INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) `_classify_e2e_gate`), the verdict attribution ([INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)), or the aggregation.

**N=1 / non-emitting carve-out (backward compatibility)**: a parser that does not emit the fence, `jq` being unavailable, browser mode, or a sidecar that fails the prompt-read re-validation → empty/unset/rejected sidecar → the free-form double-check, unchanged. N=1 single review agent reads the same per-round sidecar as N agents would.

**Status**: **ENFORCED** in this PR (closes #183).

**Test**:
- `tests/unit/test-autonomous-review-structured-ac.sh` — TC-AC-EXT-01..08 (`_extract_ac_coverage_artifact` validation: valid pass/fail object → compact JSON, no fence → empty, invalid JSON → empty, bad value domain → empty, array-not-object → empty, multi-criteria with fail retained, empty body → empty, two-fence → first object only), TC-AC-LANE-01..06 (`_run_command_e2e_lane` writes the validated sidecar: fresh+valid fence, no fence → empty, malformed fence → empty (fail-safe), reuse path extracts from the re-fetched comment, **stale sidecar truncated when this round emits no fence**, **non-writable sidecar → `E2E_AC_COVERAGE_FILE` unset (no stale leak)**), TC-AC-REVAL-01..04 (`_revalidate_ac_coverage_file`: valid file → canonical JSON, attacker-overwritten file → empty (TOCTOU), empty/absent file → empty, unset var → empty), TC-AC-SRC-01..06 (source-of-truth: wrapper exports `E2E_AC_COVERAGE_FILE`, `build_review_prompt` calls `_revalidate_ac_coverage_file` (NOT plain `cat`), free-form block still reachable, extraction is command-mode only, write-failure unsets the var, `bash -n`), TC-AC-DOC-01..03 (this invariant + ref + flow doc presence).
- Backward-compat gate: `test-autonomous-review-sequential-e2e`, `test-e2e-mode-command`, `test-autonomous-review-prompt`, `test-autonomous-review-multi-agent`, `test-review-e2e-command-poll-budget`, `test-review-agent-timeout` stay green.

**Cross-references**:
- [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) — the sequential E2E lane this layers on; the artifact is extracted in that lane and the hard gate is unchanged.
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the multi-agent fan-out that consumes the sidecar; the prompt change is per-agent-uniform and does not touch attribution/aggregation.
- [`review-agent-flow.md` § Sequential E2E lane](review-agent-flow.md#sequential-e2e-lane-inv-46) — runtime walkthrough (the lane writes the sidecar before the fan-out re-validates and reads it).
- [`skills/autonomous-review/references/e2e-command-mode.md`](../../skills/autonomous-review/references/e2e-command-mode.md) § "Optional structured AC-coverage artifact" — the project-side emission contract.

## INV-50: agy `--model` is validated against `agy models` before forwarding

**Rule**: the `agy` branch of `run_agent` / `resume_agent` (in `lib-agent.sh`) forwards `--model` to the agy CLI **only after validating** the resolved model id against `agy models`. Resolution (in `_agy_build_model_args` → `_agy_known_model`):

1. **Known agy model** (a name `agy models` lists) → forwarded as `--model "<name>"`, the name kept as a **single argv element** so spaces/parens (`"Gemini 3.5 Flash (High)"`) survive.
2. **Enumerated-but-unknown model** → `--model` is **OMITTED** (NOT forwarded, NOT relied on to fail) with a one-time WARN naming the value and pointing at `AGENT_REVIEW_MODEL_AGY`; agy runs its configured default.
3. **`agy models` enumeration failure** (subcommand renamed, agy transiently unavailable) → **best-effort pass-through**: `--model "<value>"` is forwarded, because the wrapper cannot prove the value invalid (mirrors the [INV-36](#inv-36-agy-conversation-id-capture-is-best-effort) best-effort philosophy).

Empty/unset model → no `--model` (agy uses its config default). The enumeration is cached once per process in `_LIB_AGENT_AGY_MODELS_CACHE`; the match is **fixed-string, whole-line** (`grep -Fxq`) so a prefix or a regex-metachar string never matches.

This is a **deliberate exception** to the pattern every other CLI follows — claude / codex / gemini / kiro / opencode forward `${model:+--model "$model"}` **verbatim** and let the CLI reject an unknown id. agy MUST NOT be "simplified" back to verbatim forwarding.

**Why**: agy is unique in that `agy -p --model "<anything>"` returns **rc 0 for any string** and silently falls back to its default model (Gemini 3.5 Flash) — it does **not** reject an invalid id (empirically verified on the box: `claude-sonnet-4.6` and pure garbage both → rc 0, ran as the default). Every other CLI fails loudly on a bad model, so verbatim forwarding there self-corrects (the agent is dropped as unavailable under [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)). For agy, verbatim forwarding of a non-agy id (e.g. a kiro-namespace `claude-sonnet-4.6` inherited from a shared `AGENT_REVIEW_MODEL`) would make agy **silently review with the wrong model**, and that verdict still counts toward the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) unanimous-PASS merge gate. Silent wrong-model in the merge path is worse than the pre-#190 documented no-op; wrapper-side `agy models` validation is the only way to make a misconfiguration observable. (#190.)

The original #190 spec assumed an invalid `--model` makes agy fail with non-zero rc (so [INV-40] would drop the lane); that was empirically falsified during a plan review, which is what drove the validate-wrapper-side design. The invariant records WHY (agy swallows invalid ids) so a future maintainer does not regress it to verbatim.

**Producer**: `_agy_known_model` + `_agy_build_model_args` in `skills/autonomous-dispatcher/scripts/lib-agent.sh`, called from the `agy` branch of `run_agent` and `resume_agent`.

**Consumer**: the agy CLI invocation. `AGENT_DEV_MODEL` / `AGENT_REVIEW_MODEL` (and the per-agent [INV-41](#inv-41-per-agent-review-model--extra-args-resolution) key `AGENT_REVIEW_MODEL_AGY`) become effective for agy when they name a real agy model.

**Status**: **ENFORCED** in this PR (closes #190).

**Test**: `tests/unit/test-lib-agent-agy.sh` — AGY-06a (known model → single-argv `--model`), AGY-06b (empty → no `--model`, no WARN), AGY-06b2 (unknown → omitted + WARN naming value + `AGENT_REVIEW_MODEL_AGY`, rc 0), AGY-06b3 (`agy models` failure → best-effort pass-through), TC-AGYM-KM (`_agy_known_model`: known/unknown/prefix/regex-metachar/empty + once-per-process caching), AGY-06c (resume `--conversation` path forwards `--model`), AGY-06d (resume-fallback threads `--model` through `run_agent`), AGY-WARN-GONE (old `does not support --model` string removed from source). Test plan: `docs/test-cases/agy-model-support.md`.

**Cross-references**:
- [`docs/pipeline/agy-cli-support.md` § `--model` support](agy-cli-support.md#--model-support-issue-190-inv-50) — full per-CLI spec for the validated pass-through.
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the unanimous-PASS merge gate a wrong-model verdict would corrupt undetected.
- [INV-41](#inv-41-per-agent-review-model--extra-args-resolution) — `AGENT_REVIEW_MODEL_AGY` is the per-agent key that gives agy a valid agy-namespace model in a multi-CLI fleet.
- [INV-36](#inv-36-agy-conversation-id-capture-is-best-effort) — same best-effort degrade-don't-crash philosophy applied to the enumeration-failure path.

## INV-51: codex review thread auto-resumes until a verdict-posting turn

**Rule**: when a review fan-out member's CLI is `codex`, `autonomous-review.sh`
MUST dispatch it through `lib-review-codex.sh::_run_codex_review_with_resume`
instead of a bare `run_agent`. The controller runs codex once
(`run_agent` → `codex exec --json`, capturing the `thread_id` from the
`thread.started` event into the existing sidecar), then **auto-resumes the SAME
thread** (`resume_agent` → `codex exec resume <thread_id>`) while turns end
**gather-only**, bounded by `CODEX_REVIEW_MAX_RESUMES` (default 3) **AND** a
wall-clock deadline derived from `AGENT_REVIEW_TIMEOUT`. Every other CLI
(claude / agy / kiro / gemini / opencode) keeps the single-invocation
`run_agent` path **byte-for-byte unchanged**.

Sub-rules:

1. **Gather-only detection is from the JSONL stream, not GitHub.**
   `_codex_log_has_verdict_message <log>` scans codex's own `--json` event log
   (the same per-agent log the invocation writes) and returns true iff the LAST
   **completed** turn (segment ending at the final `turn.completed`) contains an
   `item.completed` `agent_message` **whose text carries a VERDICT TRAILER**
   ([INV-53](#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message); amended here from the original
   #189 "any `agent_message`" rule). A turn whose items are all
   `tool_call`/`reasoning`/`command_execution` (a `git diff` + file reads turn) is
   gather-only → the resume trigger; **and so is a turn whose only `agent_message`s
   are PROGRESS NARRATION** (no verdict trailer) — the #198 correction. An
   `agent_message` with no trailing `turn.completed` (turn still in flight /
   killed) does NOT count. Empty/missing log → no verdict (rc 1, never crashes).
   Awk-based (jq is not a hard dep — mirrors `_codex_capture_thread`). See
   [INV-53](#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message) for the verdict-trailer phrasing set and the resume-carries-session finding.
2. **The loop NEVER queries the GitHub comments API.** That is the wrapper's
   verdict poller's job ([INV-20](#inv-20-verdict-authenticity-binding-actor--window--trailer-presence)/[INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)),
   which stays the **authoritative** verdict gate AFTER the controller returns.
   The JSONL loop only gets codex to FINISH a turn; the comment poller confirms
   the verdict comment landed (`Review Agent: codex` discriminator). Querying
   GitHub mid-loop would be the wrong layer and add per-turn latency.
3. **Bounded; falls back to today's behavior on exhaustion.** The loop stops at
   the FIRST of: a verdict-posting turn; `CODEX_REVIEW_MAX_RESUMES` resumes; or
   `now >= base + _codex_review_deadline_seconds` (the max-resume bound is checked
   BEFORE the wall-clock bound, so a `max=N` config does exactly N resumes when
   time allows). On exhaustion with no verdict, the controller returns and the
   post-window sweep resolves codex `unavailable` ([INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)) — **exactly the
   pre-#189 fallback**. `CODEX_REVIEW_MAX_RESUMES=0` disables the loop.
   `_codex_review_deadline_seconds` parses the `AGENT_REVIEW_TIMEOUT` coreutils
   duration (`s`/`m`/`h`/`d` or bare seconds) to seconds; an empty / unset /
   unparseable value degrades to **3600 (1h), never unbounded**.
4. **Per-turn cap is separate, and a timeout rc is STICKY across resumes.** Each
   individual turn is still wrapped by `_run_with_timeout` (`AGENT_TIMEOUT`,
   rebound to the review cap, [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto)).
   The loop's own deadline is a SECOND guard so N turns × per-turn-cap cannot blow
   far past the review window. The controller normally returns the LAST turn's
   exit code, **EXCEPT** a `124` (coreutils `timeout` TERM-expiry) or `137`
   (`--kill-after` SIGKILL) from ANY turn is **sticky** — once a turn was killed by
   the per-turn cap, that rc is preserved even if a later resume turn exits `0`.
   This is load-bearing for the [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto)
   timeout-veto: the wrapper's post-window sweep maps a no-verdict rc `124`/`137`
   to `timed-out` (a deciding FAIL that VETOES the merge); if the loop reset rc to
   `0` on a subsequent clean-but-still-no-verdict turn, the agent would be silently
   dropped as `unavailable` instead of vetoing — defeating the cap (#189 review
   finding 1). So a timed-out turn followed by clean-but-no-verdict resumes still
   returns `124`/`137`, feeding the wrapper-side veto.
5. **Layer.** The loop lives in the review layer (`lib-review-codex.sh`), NOT in
   the generic `run_agent`/`resume_agent` of `lib-agent.sh` — putting
   verdict/GitHub knowledge there would violate that file's CLI-agnostic layering.
   The codex `run_agent`/`resume_agent` branches are reused unmodified.

**Why**: `codex exec` runs ONE agentic turn. On a ~4,300-line diff codex
non-deterministically consumed the whole turn reading the diff (`git diff
master...HEAD` → `turn.completed`, ~55k tokens) and emitted **no findings and no
verdict comment**; the same fleet posted a full codex review on a smaller diff —
so it is diff-size-sensitive and non-deterministic, not a config/auth/region
problem (the region-collision confounder — `BEDROCK_AWS_REGION` pollution — was
ruled out in the #189 eng review: the launcher exports `CODEX_AWS_REGION=us-east-2`
and a live probe returned a clean `turn.completed`). A longer verdict-poll window
does NOT help — codex's turn already ENDED; the fix must issue another turn.
`codex exec --help` has no `--max-turns`/`--max-steps`, so raising codex's step
budget is not an option — the resume loop is the only avenue. Net effect before
#189: on large diffs the fleet silently degraded to the non-codex agent(s), losing
the independent second opinion (which in the observed case caught real BLOCKING
findings the other agent missed) exactly when the diff was large enough to need
it. (#189.)

**Rejected alternatives** (recorded so they are not re-attempted): pre-stuffing
the full diff into the prompt (bloats unboundedly on large diffs, loses codex's
file navigation, diverges the codex prompt shape from other CLIs); a longer
verdict-poll window only (codex's turn ENDED — polling waits for a verdict that
will never come without another turn); raising codex's step budget (no native
flag exists).

**Producer**: `lib-review-codex.sh` — `_run_codex_review_with_resume` (the bounded
controller), `_codex_log_has_verdict_message` (gather-only detection),
`_codex_review_deadline_seconds` (wall-clock budget), `_codex_resume_prompt` (the
continue-and-emit-verdict prompt), `_codex_now_seconds` (clock seam). The fan-out
`codex` branch in `autonomous-review.sh` that routes to it.

**Consumer**: the wrapper's per-agent verdict poll loop (the authoritative gate)
and the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) aggregation — both UNCHANGED. The codex `run_agent`/`resume_agent`
branches in `lib-agent.sh` are reused, not modified.

**Status**: **ENFORCED** (closes #189). **Amended by [INV-53](#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message) (#198)**: the
convergence signal in sub-rule 1 now keys on the **verdict trailer** in the
`agent_message` text, not on the mere presence of an `agent_message` — the
original any-message rule false-converged on codex's progress narration and the
codex member was still dropped `unavailable`. The resume loop, its bounds, the
layer, and the INV-48 rc-stickiness (sub-rule 4) are **unchanged**.

**Test**: `tests/unit/test-lib-review-codex.sh` — TC-CXR-DET-01..14
(`_codex_log_has_verdict_message`: last-turn-decides, gather-only, empty/missing,
mid-flight turn, the cross-turn killed-mid-message leak, the tool-output
`agent_message` substring false-positive — #189 review finding 2 — and the
[INV-53](#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message)
verdict-trailer cases DET-09..14: narration-only → resumes, pass/fail/discriminator
trailers → converge, last-turn-decides for the trailer, and a verdict-phrase in a
tool output not a false verdict — #198), TC-CXR-DL-01..06
(`_codex_review_deadline_seconds`: units + garbage→1h default), TC-CXR-CTL-01..12
(controller: one-resume-then-verdict, immediate-verdict-no-resume,
never-converges-bounded-at-max, wall-clock guard, resume prompt content,
same-session-id reuse, rc propagation, max=0 disables, a non-numeric max
degrading without an `unbound variable` crash under `set -u`, the **sticky 124
across a clean resume + bound-exhaustion → returns 124** timeout-veto regression
on turn 1 AND on a mid-loop resume turn (#189 review finding 1), and an early
return on a non-timeout launch failure with no resumes — #189 review finding 3),
TC-CXR-ISO-02..06
(wrapper routes codex through the controller guarded on `AGENT_CMD == codex`,
non-codex keeps bare `run_agent`, wrapper sources the lib, CI shellcheck lists it).
Backward-compat gate: `test-lib-agent-codex.sh` (generic codex branch unchanged),
`test-autonomous-review-multi-agent.sh`, `test-autonomous-review-per-agent-model.sh`,
`test-autonomous-review-per-agent-launcher.sh`, `test-review-cli-exit-grace.sh`
stay green. Test plan: `docs/test-cases/codex-review-resume-loop.md`.

**Cross-references**:
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the unanimous-PASS fan-out + the `unavailable` fallback this loop is trying to avoid (and falls back to on exhaustion). The verdict poller is unchanged.
- [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto) — the `AGENT_REVIEW_TIMEOUT` review wall-clock cap the loop derives its deadline from, and the per-turn timeout-veto.
- [INV-34](#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element) — the stdin prompt channel the reused codex `run_agent`/`resume_agent` branches uphold.
- [`review-agent-flow.md` § Codex auto-resume (INV-51)](review-agent-flow.md#codex-auto-resume-inv-51) — runtime walkthrough.
- [`docs/designs/codex-review-resume-loop.md`](../designs/codex-review-resume-loop.md) — design canvas.
- [INV-53](#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message) — the corrected convergence contract (#198).

## INV-52: the review WRAPPER owns the GitHub-native PR review/merge action; the agent posts verdicts only

**Rule**: the review **wrapper** (`autonomous-review.sh`) is the SOLE actor that submits a GitHub-native PR review or merge. It submits `gh pr review --approve` (+ `gh pr merge`, unless `no-auto-close`) on a PASS — **after** the [INV-44](#inv-44-mergeable-hard-gate--a-conflicting-pr-can-never-reach-approved) mergeable hard gate and the `no-auto-close` skip-merge check — and `gh pr review --request-changes` on a **substantive** FAIL, so the PR's GitHub-native `reviewDecision` always reflects the verdict (`CHANGES_REQUESTED` on a blocking FAIL). The review **agent** posts a verdict **comment** only (`Review PASSED` / `Review findings:` + the trailers) and MUST NEVER run `gh pr review --approve`, `gh pr review --request-changes`, `gh pr merge`, or the MCP merge tools.

Two halves of one invariant:

### Half A — FAIL ⇒ REQUEST_CHANGES (the durable GitHub-native state)

On a **substantive** FAIL the wrapper submits `gh pr review --request-changes` via `lib-review-request-changes.sh::submit_request_changes <pr> <body>`, so `reviewDecision` becomes `CHANGES_REQUESTED` — authoritative for humans browsing the PR, branch protection, the dispatcher, and the dev-resume agent. Which routes request changes:

| FAIL route | Substantive? | Submit `--request-changes`? |
|---|---|---|
| Agent posted blocking findings (`failed-substantive`, the `Review findings:` FAIL branch) | yes | **YES** |
| Merge conflict (`block-substantive`, the [INV-44](#inv-44-mergeable-hard-gate--a-conflicting-pr-can-never-reach-approved) `CONFLICTING` gate) | yes | **YES** |
| E2E hard-gate failure (`failed-substantive`, the [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) `E2E_GATE == fail` route, lane rc≠0, runs before the fan-out) | yes | **YES** |
| Mergeable `UNKNOWN` re-queue (`block-nonsubstantive`, INV-44) | no — transient GitHub-side hold | **NO** |
| E2E evidence missing re-queue (`block-nonsubstantive` cause `e2e-evidence-missing`, INV-46) | no — transient comment-propagation | **NO** |
| Agent crash with no verdict (`failed-non-substantive other`) | no — transport/mid-stream failure | **NO** |

Sub-rules:

1. **Best-effort under `set -e`.** `submit_request_changes` always returns 0; a 403 / permission / transient `gh` failure is logged and swallowed, and the call site adds a belt-and-suspenders `|| log`. A failed submission must NOT abort the wrapper and strand the issue in `reviewing` — the FAIL route still flips the label to `pending-dev`. Mirrors the PASS-side approval-failure fallback and the dev-resume `|| log` discipline.
2. **Substantive-only.** REQUEST_CHANGES is submitted ONLY on the three substantive routes above (agent-posted findings, CONFLICTING block, E2E hard-gate failure). A non-substantive route (mergeable-`UNKNOWN` re-queue, E2E-`evidence-missing` re-queue, or an agent crash with no verdict) is NOT a dev-actionable blocking finding; a standing `CHANGES_REQUESTED` there would falsely accuse the dev and linger on the PR. The substantive set is defined by the verdict being a real, dev-actionable blocking finding — NOT by which gate produced it — so the E2E hard gate (which produces a `failed-substantive` verdict before the fan-out, [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent)) is included (#197 codex review finding).
3. **Mutual exclusion with PASS.** PASS submits `--approve`; substantive FAIL submits `--request-changes`. They are different branches of the `if [[ "$PASSED_VERDICT" == "true" ]]` split — never both in one run.
4. **Next-PASS supersedes a standing CHANGES_REQUESTED.** The PASS path already submits `gh pr review --approve` against the new HEAD; a fresh APPROVE from the same reviewer supersedes the prior `CHANGES_REQUESTED` (and `dismiss-stale-reviews-on-push` branch protection, if configured, dismisses it on the dev's force-push). No permanently-stuck `CHANGES_REQUESTED`.

### Half B — the agent never approves/merges (the incident)

`SKILL.md` previously framed the agent's job as "approve + merge" (e.g. "verdict is PASS (approve + merge)") and `decision-gate.md`'s action-pairing table told the agent to "Submit APPROVE review on PR", while the wrapper assumed only the wrapper approves/merges. On PR #191 the kiro review **agent** ran `gh pr review --approve` itself and the PR merged 8 s later — ~18 min BEFORE the wrapper's gates ran — so the [INV-44](#inv-44-mergeable-hard-gate--a-conflicting-pr-can-never-reach-approved) mergeable hard gate (the PR was `UNKNOWN`-mergeable) and the `no-auto-close` skip-merge were both bypassed, and the wrapper later wrote a stale `pending-dev` onto the now-closed issue. The fix re-scopes the agent-side docs to "post your verdict comment; the wrapper approves/merges/requests-changes after its gates" and makes the agent issuing any GitHub PR review/merge an explicit defect.

**Mechanical backstop (rejected, recorded so it is not re-attempted)**: the issue suggested tool-denying `gh pr merge`/`gh pr review --approve` in the review agent's permission set. The review agent runs headless under `--dangerously-skip-permissions` (`lib-agent.sh`), so a per-tool deny-list is not reliably enforceable there. The robust enforcement is the prompt rule (Half B) backed by the wrapper owning the action (Half A) — the wrapper's gates ([INV-44](#inv-44-mergeable-hard-gate--a-conflicting-pr-can-never-reach-approved), `no-auto-close`) are the real safety net, and an agent that nonetheless self-merges is a defect to be caught in review, not silently tolerated.

**Why**: a PR with known blocking findings whose GitHub-native `reviewDecision` stays `APPROVED`/`REVIEW_REQUIRED` looks mergeable to anyone not parsing the issue comment thread (the root cause behind #188). And an agent that self-approves/merges races the wrapper's INV-44 + `no-auto-close` gates and can merge an `UNKNOWN`-mergeable or `no-auto-close` PR (PR #191). Both are the same thesis from two sides: **the GitHub-native PR review/merge action is wrapper-owned; the agent posts verdicts only.** (#193.)

**Producer**: `autonomous-review.sh` — `submit_request_changes` calls on the three substantive routes: the `failed-substantive` agent-findings FAIL branch, the `block-substantive` (CONFLICTING) branch, and the [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) `E2E_GATE == fail` branch; `lib-review-request-changes.sh::submit_request_changes` (the best-effort helper). The existing `--approve`/`gh pr merge` PASS branch is the PASS-side half (unchanged). The agent-side docs (`SKILL.md`, `references/decision-gate.md`) constrain the agent.

**Consumer**: humans browsing the PR, branch protection, the dispatcher's routing, and the dev-resume agent — all of which read `reviewDecision`. The review agent consumes the re-scoped prompt/docs.

**Status**: **ENFORCED** in this PR (closes #193).

**Test**: `tests/unit/test-autonomous-review-request-changes.sh` — TC-RC-FN-01..05 (executable `submit_request_changes`: requests-changes-not-approve, passes pr+`--body`, non-zero `gh` → returns 0 + warns, success → 0, continues past the helper under `set -e`), TC-RC-SRC-00..11 (source-of-truth: wrapper sources the lib, helper defined, called on EXACTLY the **3** substantive routes (agent-findings FAIL + CONFLICTING block + E2E hard-gate fail; UNKNOWN/e2e-evidence-missing/crash excluded — TC-RC-SRC-04 count==3, TC-RC-SRC-04b E2E-fail requests changes, TC-RC-SRC-04c E2E-evidence-missing does NOT), every call best-effort `|| log`, PASS still `--approve`, no line mixes approve+request-changes, body references findings/blocking, `bash -n`), TC-RC-DOC-01..05 (agent-side framing: SKILL.md no longer says "PASS (approve + merge)", prohibits the agent running `gh pr review`/`merge`, says the wrapper owns the action; decision-gate.md no longer instructs the agent to "Submit APPROVE review on PR"; INV-52 exists + referenced from the flow doc). Backward-compat gate: `test-autonomous-review-auto-merge-failure.sh`, `…-mergeable-gate.sh`, `…-multi-agent.sh`, `…-verdict-trailer.sh`, `…-prompt.sh`, `…-sequential-e2e.sh` stay green (the helper adds a PR-review call on FAIL but changes no label transition, posts no `gh issue close`, and does not touch `−autonomous` — the #145 / INV-44 / INV-46 pins hold). Test plan: `docs/test-cases/request-changes-on-fail.md`.

**Cross-references**:
- [INV-44](#inv-44-mergeable-hard-gate--a-conflicting-pr-can-never-reach-approved) — the mergeable hard gate the agent's self-merge bypassed; the wrapper's `--request-changes` on the CONFLICTING block path is this invariant's Half-A action for that gate's `block-substantive` route.
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the unanimous aggregation that produces the single PASS/FAIL the wrapper acts on; with N agents the wrapper still submits the native action exactly once.
- [INV-33](#inv-33-review-wrapper-must-not-close-the-linked-issue) — the wrapper never closes the issue; INV-52 likewise keeps the GitHub-native PR action wrapper-side.
- [INV-35](#inv-35-review-aware-resume-routing-for-completed-sessions) — the substantive-vs-non-substantive verdict-trailer classification this invariant reuses to decide whether to request changes.
- [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) — the E2E hard gate. Its `E2E_GATE == fail` route is a `failed-substantive` blocking FAIL produced **before** the review fan-out, so this invariant requests changes on it too; its `block-nonsubstantive` (evidence-missing) re-queue route is transient and does NOT (#197 codex review finding).
- [INV-54](#inv-54-the-pr-still-open-guard-gates-all-pass-chain-exits-not-just-pass) — the hoisted PR-open guard at the top of the `PASSED_VERDICT=true` chain runs **before** this invariant's `block-substantive` (CONFLICTING) `--request-changes` call, so a PR merged/closed out-of-band exits silently and never has changes requested on it (correct — you cannot request changes on a closed PR). The substantive **agent-findings** and **E2E hard-gate** FAIL branches are outside the PASS chain, so they request changes whenever the verdict is a real blocking FAIL; a `--request-changes` against an already-closed PR there is harmless (best-effort, logged, returns 0).
- [`review-agent-flow.md` § Verdict = FAIL path (INV-52)](review-agent-flow.md#verdict--fail-or-missing-path) — runtime walkthrough.
- [`skills/autonomous-review/references/decision-gate.md` § Who submits the GitHub-native PR action](../../skills/autonomous-review/references/decision-gate.md) / [`SKILL.md`](../../skills/autonomous-review/SKILL.md) — agent-side reinforcement.
- [`docs/designs/request-changes-on-fail.md`](../designs/request-changes-on-fail.md) — design canvas.

## INV-53: codex review convergence keys on the VERDICT TRAILER, not any `agent_message`

**Rule**: the [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn)
convergence detector `lib-review-codex.sh::_codex_log_has_verdict_message` MUST
treat codex's last completed turn as **converged only when it posted the VERDICT**
— i.e. when an `item.completed` `agent_message` in that turn carries a **verdict
trailer**: one of the pass/fail phrasings the wrapper poller itself matches
(`lib-review-poll.sh::_classify_verdict_body`) **or** the `Review Agent: codex`
attribution discriminator the resume prompt forces codex to emit. A turn whose
`agent_message`s are pure **progress narration** ("Next I'm reading the
instructions…", "I'll verify the PR…") is **gather-only** → the loop RESUMES
(bounded by `CODEX_REVIEW_MAX_RESUMES` + the wall-clock deadline, unchanged).

Recognised verdict-trailer phrases (case-insensitive substring, kept in sync with
the poller so the two ALWAYS agree): pass-side `Review PASSED` / `Review APPROVED`
/ `APPROVED FOR MERGE` / `LGTM` / `Review PASS`; fail-side `Review FAILED` /
`Review REJECTED` / `Review findings:` / `Changes requested`; plus
`Review Agent: codex`.

Sub-rules:

1. **The trailer must be inside an `agent_message` item, on the same JSONL line.**
   The match conjoins (a) `item.completed`, (b) item-scoped `agent_message`
   (`"item":{…,"type":"agent_message"…}`), and (c) a verdict-trailer phrase — all
   on one physical line (codex emits one event per line; newlines inside the text
   are escaped as `\n`). So a verdict PHRASE appearing in a separate
   `command_execution` `aggregated_output` line within the same turn (codex catting
   `SKILL.md` / the review prompt, both of which contain the literal phrasings)
   does NOT count — it fails conjunct (b). This subsumes the #189 review-finding-2
   substring guard and extends it to the text match.
2. **Plain substrings, no word boundaries.** The phrases are matched as plain
   case-insensitive substrings — IDENTICAL to the poller's `grep -qiE` — so the
   detector and the authoritative comment poller never disagree, AND the awk stays
   portable to any POSIX awk (gawk `\<`/`\>` word boundaries are a GNU extension
   this subsystem must not depend on, mirroring `_codex_capture_thread`).
3. **Fail-safe toward resuming.** An ambiguous / narration-only turn RESUMES
   (bounded), it never false-STOPS. Worst case wastes one bounded resume; it never
   silently drops codex by false-converging. The [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn)
   last-turn-decides + per-turn-reset + mid-flight rules are preserved verbatim
   (a trailer in an EARLIER turn, or in a turn with no `turn.completed`, does NOT
   count).
4. **The INV-48 timeout rc-stickiness is orthogonal and UNCHANGED.** This rule
   only changes the *gather-only DETECTION*; the controller's rc handling — a
   per-turn `124`/`137` stays sticky so a timed-out codex turn vetoes via the
   wrapper sweep ([INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto)) — is byte-for-byte the #194 code.
5. **The resume prompt must not strand a context-compacted turn.**
   `_codex_resume_prompt` PREFERS the context codex already loaded (avoid
   gratuitous re-gather on the common path, the INV-51 goal) but **explicitly
   allows re-reading the minimum needed when codex's own context was compacted**
   and the diff/files are no longer in its working context, and instructs codex to
   **NEVER refuse a verdict for lack of context** ("I cannot verify because my
   context is unavailable" is not a valid finding). The original #189 prompt was
   ABSOLUTE ("do NOT re-run `git diff` and do NOT re-read files you already read"),
   which left a compacted codex turn unable to substantiate a verdict — it
   defensively posted a `[BLOCKING] review context unavailable` FAIL (a
   non-substantive deciding FAIL that blocked the merge), observed on the codex
   lane reviewing the very PR that added INV-53. Softening the prompt removes that
   strand-on-compaction failure mode without re-opening the gather-the-whole-turn
   problem INV-51 solved.

**Investigation finding (recorded so it is not re-litigated)**: #198 hypothesised
that `codex exec resume <tid>` is a **no-op on the amazon-bedrock provider** (each
resume mints a fresh `thread.started`, re-reads everything from zero), which would
invalidate INV-51's premise. A minimal `remember 42` repro on **codex-cli 0.137.0**
(`model_provider=amazon-bedrock`, `openai.gpt-5.5`, `us-east-2`) **DISPROVES** this:
resume KEEPS the same `thread.started` id across turns, the prior conversation is
replayed and Bedrock-prompt-cached (growing `input_tokens` with non-zero
`cached_input_tokens`), and codex recalls prior context (`OK 42` → `RECALL 42` →
`AGAIN 42`). So **resume does carry session** on the current CLI; the resume loop
is sound and is KEPT. The issue's prod-log evidence (distinct thread ids per
dispatch) is most consistent with an older codex CLI or the `_codex_capture_thread`
sidecar being clobbered on each resume — not a provider limitation. The artifact
is `tests/unit/fixtures/codex-resume-carry-session-repro.txt`.

**Why**: codex emits `agent_message` for narration, not only for the final
findings. A gather-heavy turn (mergeability check, SKILL read, issue-comment read)
that narrates then ends WITHOUT posting the verdict tripped the original
any-`agent_message` detector as "converged" → the loop broke on round 1, no resume
fired, the comment poller found no verdict, and codex was dropped `unavailable` —
exactly the failure INV-51 was meant to prevent. Verified against a real review-193
codex log (`input_tokens:138668, output_tokens:746`, three short narration
`agent_message`s, never read the diff, never posted a verdict): the pre-fix
detector returned converged. Keying on the verdict trailer makes "the JSONL stream
shows a verdict-shaped message" agree with "the poller will find the comment".

**Rejected alternatives**: abandon resume and inline the full diff in the prompt
(rejected by INV-51 already — bloats on large diffs, loses codex's file
navigation, diverges the codex prompt shape; and now moot because resume DOES carry
session); use the GitHub comment poller as the in-loop break signal (wrong layer —
adds per-turn GitHub latency and violates [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn) sub-rule 2; the JSONL trailer is a cheap local proxy and the poller remains the authoritative post-loop gate).

**Producer**: `lib-review-codex.sh::_codex_log_has_verdict_message` (the verdict-trailer match, sub-rules 1–4) and `_codex_resume_prompt` (the context-compaction-safe prompt, sub-rule 5). The controller, deadline parser, and rc-stickiness are unchanged from [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn).

**Consumer**: the [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn) resume controller (the break condition), and downstream the wrapper's authoritative comment poller ([INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)) — unchanged.

**Status**: **ENFORCED** in this PR (closes #198).

**Test**: `tests/unit/test-lib-review-codex.sh` — TC-CXR-DET-09..14
(narration-only → rc 1 / resumes, incl. the committed `fixtures/codex-gather-only-turn.jsonl`;
pass/fail/discriminator trailers → rc 0; last-turn-decides for the trailer; a
verdict phrase in a tool output is not a false verdict) and TC-CXR-RP-01..05
(sub-rule 5: the resume prompt drops the absolute "do NOT re-read" bar, allows
minimal re-reading on context compaction, prefers already-loaded context, instructs
codex to never refuse a verdict for missing context, and keeps the INV-40/INV-20
attribution trailers). Investigation artifact:
`tests/unit/fixtures/codex-resume-carry-session-repro.txt`. Test plan:
`docs/test-cases/codex-review-resume-loop.md`.

**Cross-references**:
- [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn) — the resume loop this corrects the convergence signal of (and which this confirms is sound).
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the authoritative comment poller / `unavailable` fallback whose phrasings this match mirrors.
- [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto) — the timeout rc-stickiness preserved unchanged.
- [`review-agent-flow.md` § Codex auto-resume (INV-51)](review-agent-flow.md#codex-auto-resume-inv-51) — runtime walkthrough (updated for the verdict-trailer signal).
- [`docs/designs/codex-convergence-verdict-detection.md`](../designs/codex-convergence-verdict-detection.md) — design canvas.

## INV-54: the PR-still-open guard gates ALL PASS-chain exits, not just PASS

**Rule**: the PR-still-open check in `autonomous-review.sh` MUST run **once at the top of the `PASSED_VERDICT == true` gate chain** — BEFORE the [INV-44](#inv-44-mergeable-hard-gate--a-conflicting-pr-can-never-reach-approved) mergeable poll and BEFORE any FAIL-branch label flip — so that all three PASS-chain exits honor it identically:

1. `block-substantive` (PR `CONFLICTING`),
2. `block-nonsubstantive` (mergeable `UNKNOWN`/empty past the retry budget),
3. PASS (approve / merge / `no-auto-close`).

When the PR is no longer `OPEN`, every one of those exits MUST route to a **clean `−reviewing` and `exit 0` with NO `pending-dev` add**. The decision is computed by the pure `lib-review-mergeable.sh::_pr_open_gate <state>` helper:

| `state` (case-insensitive) | gate | wrapper action |
|---|---|---|
| `OPEN` | `proceed` | fall through to the mergeable gate + PASS branch — unchanged |
| `MERGED` / `CLOSED` / `UNKNOWN` / empty / any other token | `skip` | `−reviewing`, `exit 0` — never add `pending-dev` |

Sub-rules:

1. **Conservative classification.** The ONLY value that yields `proceed` is a case-insensitive `OPEN` — the exact inverse of the prior PASS-branch guard's `[[ "$PR_STATE" != "OPEN" ]]` test. A failed `gh pr view --json state` query (the wrapper substitutes the `UNKNOWN` sentinel) → `skip`, matching the prior PASS guard which also treated a failed query as non-OPEN. Fail-closed toward "do not re-queue dev" — when PR state is in doubt we never flip a possibly-merged issue to `pending-dev`.

2. **One query, three exits (DRY).** The hoisted check replaces — does not duplicate — the old PASS-branch guard. Exactly one `gh pr view --json state` call exists in the wrapper; the redundant second query in the PASS branch was removed. The hoist adds **zero** net `gh` calls on the PASS path (the one query simply moved earlier) and runs before the mergeable poll on the block paths.

**Why**: the open-check was originally added only to the PASS branch, AFTER the INV-44 mergeable gate. The INV-44 block branches were added later ([#176](https://github.com/zxkane/autonomous-dev-team/issues/176)) and did not inherit it. So a PR merged **out-of-band** while a review run was in flight — a manual merge, or the agent self-merge of the #191 incident — that then took a `block-substantive` / `block-nonsubstantive` path had its **already-merged, already-closed** issue flipped to `pending-dev`, which the dispatcher could then try to re-dispatch dev against (degraded: wrong label + needless dev re-dispatch on a merged PR). This is the wrapper-side guard-gap half carved out of [#193](https://github.com/zxkane/autonomous-dev-team/issues/193) (which fixed the agent-self-merge root cause). Hoisting the single check to the top of the gate chain makes the three exits share one open-check semantics.

**Scope**: deliberately limited to the three `PASSED_VERDICT == true` exits (the issue carve-out). The [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) E2E hard gate (runs before the fan-out) and the verdict-`FAILED` `else` branch are NOT covered — a FAILED verdict on a merged PR is a far rarer race and out of scope for #196. A follow-up can extend the same `_pr_open_gate` helper to those paths.

**Producer**: `autonomous-review.sh` — the hoisted open-gate block at the top of the `PASSED_VERDICT == true` chain (the `gh pr view --json state` query + `_pr_open_gate` call) and `lib-review-mergeable.sh::_pr_open_gate` (the pure decision helper).

**Consumer**: the INV-44 mergeable gate's two block branches and the PASS approve/merge branch — all three reached only when the open-gate is `proceed`; the dispatcher (no longer sees a merged issue re-flagged `pending-dev`).

**Status**: **ENFORCED** in this PR (closes #196).

**Test**: `tests/unit/test-autonomous-review-fail-branch-open-guard.sh` — TC-OG-CLS-01..08 (pure decision logic over `_pr_open_gate`: OPEN→proceed, MERGED/CLOSED/UNKNOWN/empty/garbage→skip, case-insensitivity, and the "only OPEN proceeds" inverse-of-`!= OPEN` property) and TC-OG-SRC-01..06 (source-of-truth greps: wrapper calls `_pr_open_gate`, the `--json state` query precedes both `_classify_mergeable_gate` and the `MERGEABLE_RETRIES` poll loop, exactly one `--json state` query remains, the skip path removes `reviewing` and never adds `pending-dev`, `bash -n`). The mergeable-gate pins (`test-autonomous-review-mergeable-gate.sh`) stay green — the hoist sits ahead of the gate and leaves the block branches byte-for-byte unchanged.

**Cross-references**:
- [INV-44](#inv-44-mergeable-hard-gate--a-conflicting-pr-can-never-reach-approved) — the mergeable gate whose two block branches now sit downstream of the hoisted open-check.
- [INV-33](#inv-33-review-wrapper-must-not-close-the-linked-issue) — the wrapper never closes the issue; the open-gate skip path likewise only removes `reviewing`.
- [`review-agent-flow.md` § PR-open guard (INV-54)](review-agent-flow.md#pr-open-guard-inv-54) — runtime walkthrough.
- [`state-machine.md` § Transition table](state-machine.md#transition-table) — the open-gate `reviewing → (−reviewing)` clean-exit row shared by all three PASS-chain exits.
- [`docs/designs/review-fail-branch-open-guard.md`](../designs/review-fail-branch-open-guard.md) — design canvas.

## INV-55: the codex review lane receives the PR diff INLINE in its prompt

**Rule**: when `autonomous-review.sh::build_review_prompt` renders for the **codex**
agent (`_agent_name == codex`), it MUST embed the full PR diff INLINE in the prompt
— fetched once via `gh pr diff "${PR_NUMBER}" --repo "${REPO}"`, placed between
`DIFF_START` / `DIFF_END` markers — and instruct codex NOT to run `git diff` /
`gh pr diff` itself. The other CLIs (claude/agy/kiro/gemini/opencode) keep the
byte-for-byte unchanged prompt that tells the agent to read the diff itself.

**Why**: codex runs ONE agentic turn (`codex exec`). On a non-trivial PR the
CLI-agnostic prompt's "read the PR diff" step makes codex re-run `git diff` at
several `--unified` sizes, consuming the whole turn on context-gathering (observed:
**320k input tokens, `output_tokens:1945`, no verdict**) and exhausting
`CODEX_REVIEW_MAX_RESUMES` before producing findings — so it is dropped
`unavailable` and the fleet decides without it (#198 re-review of #193, run under
the INV-53 code: `[lib-review-codex] ... hit CODEX_REVIEW_MAX_RESUMES=3 with no
verdict turn`). [INV-53](#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message)
stopped the detector **false-converging**; INV-55 removes the reason the **real**
turn can't converge. The verified pattern: a manual `/codex review` that inlines the
diff and forbids self-fetch produced 7 findings (incl. 2 P1) on a 4318-line diff in
ONE turn. The diff is fenced between **nonce'd** markers `DIFF_START_<sid>` /
`DIFF_END_<sid>` (suffixed with the agent's per-render session UUID) so the
data/instruction boundary cannot be forged by a PR diff that itself contains a
literal `DIFF_END` line — a static sentinel would let attacker-controlled text after
a bare `DIFF_END` land in instruction position. The prompt also explicitly tells
codex to treat everything between the markers as untrusted DATA and disregard any
directive-shaped text inside it. Belt-and-suspenders: if the fetched diff somehow
contains the exact nonce'd end marker, the lane does NOT inline and falls back to the
self-fetch note.

**Producer**: `build_review_prompt` (the codex-gated inline block).
**Consumer**: the codex review agent's single `codex exec` turn (it produces findings
+ posts the verdict from the inlined diff without re-gathering).

**Bound**: `CODEX_REVIEW_INLINE_DIFF_MAX_BYTES` (default 600000). Above the cap — or
when the diff can't be fetched, or contains the nonce'd end marker — the lane does NOT
inline (a megadiff would blow the prompt the other way) and falls back to a "read it
with a SINGLE `gh pr diff`" instruction. The byte count is computed into a plain
integer (`wc -c | tr -dc 0-9`, default 0) so a `set -euo pipefail` arithmetic
comparison can never abort the **wrapper process** (this block renders in the main
wrapper, inside the per-agent loop but BEFORE the `( … ) &` fan-out subshell, so an
abort here would strand the issue in `reviewing` — hence the defensive guards).

**Scope**: codex lane only. `agy` exhibits the same gather-burn (its log is
wall-to-wall "I will check… I will view…" narration that cuts off with no verdict),
but the robust agy fix is a separate question (agy's CLI diff-injection / multi-turn
surface differs) and is intentionally NOT bundled here — captured as a follow-up so
this change stays small and the blast radius contained.

**Status**: **ENFORCED** (closes #198 follow-up). Complements
[INV-53](#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message)
— INV-53 fixes detection; INV-55 makes turn-1 self-sufficient so detection has a real
verdict to detect.

**Test**: `tests/unit/test-codex-inline-diff-prompt.sh` — TC-CXIN-SRC-01..06
(codex-gated branch; `gh pr diff` fetch; `DIFF_START`/`DIFF_END` markers; no-git-diff
instruction; `CODEX_REVIEW_INLINE_DIFF_MAX_BYTES` guard) and TC-CXIN-BEHAVE-01..03
(rendered codex prompt INLINES the fetched diff body; non-codex/claude prompt does
NOT; codex prompt carries the no-git-diff instruction). Backward-compat:
`test-autonomous-review-prompt.sh`, `test-autonomous-review-multi-agent.sh`,
`test-autonomous-review-structured-ac.sh`, `test-autonomous-review-sequential-e2e.sh`
stay green. Test plan: `docs/test-cases/codex-inline-diff-review-prompt.md`.

**Cross-references**:
- [INV-53](#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message) — the convergence-detection fix INV-55 complements.
- [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn) — the resume loop INV-55 lets converge in turn-1 (resume becomes a thin fallback).
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the `unavailable` drop this avoids.
- [`review-agent-flow.md` § Codex auto-resume (INV-51)](review-agent-flow.md#codex-auto-resume-inv-51) — runtime walkthrough.
- [`docs/designs/codex-inline-diff-review-prompt.md`](../designs/codex-inline-diff-review-prompt.md) — design canvas.

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
