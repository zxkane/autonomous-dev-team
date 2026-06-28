## INV-01: PID file naming

_Triage (issue #236): [machine-checked: tests/unit/test-pid-dir-helper.sh, tests/unit/test-kill-before-spawn.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-kill-before-spawn.sh, tests/unit/test-pid-dir-helper.sh]_

**Rule**: Both `acquire_pid_guard` (in `lib-agent.sh`) and `kill_stale_wrapper` (in `dispatch-local.sh`) MUST refuse to operate on a PID file that is a symlink, and exit 1 immediately on detection.

**Why**: CWE-59 (Link Following). Originally the primary defense for the predictable `/tmp` PID paths; with [INV-01]'s per-user PID dir (PR-7, mode 0700), this becomes belt-and-suspenders rather than the only line of defense. The defense costs ~3 lines of bash and remains valuable: `pid_dir_for_project` itself refuses a symlinked dir, and the per-PID-file check catches edge cases where the user's own ~/.local/state/autonomous-${PROJECT_ID} is somehow tampered with.

**Producer**: `acquire_pid_guard`, `kill_stale_wrapper`, plus `pid_dir_for_project` (which refuses to use a symlinked parent dir — same defense one level up).
**Consumer**: itself (the check is a precondition, not a consumed value).
**Test**: `tests/unit/test-kill-before-spawn.sh` TC-DKBS-006, `tests/unit/test-pid-dir-helper.sh` TC-PD-005.

## INV-03: Dev session report comment format

_Triage (issue #236): [machine-checked: tests/unit/test-autonomous-dev-cleanup-startup-failure.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-autonomous-review-reviewed-head-annotation.sh]_

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

_Triage (issue #236): [design-rationale]_

**Rule**: The dispatcher's Step 4a retry counter MUST count failure events (Agent Session Report dev failures + dispatcher-crash comments) ONLY if their `createdAt` is **after** the most recent `Marking as stalled` comment on the issue.

**Why**: Without this, removing the `stalled` label to re-arm the pipeline would leave the historical retry counter intact — the issue would re-stall on the very next failure. With the cutoff, removing `stalled` is a clean reset (#41).

The cutoff timestamp falls back to epoch (1970-01-01) for issues that have never been stalled — counts all comments.

**Producer**: dispatcher Step 4a.
**Consumer**: dispatcher Step 4a's own gating logic.
**Test**: TODO: add test (`tests/unit/test-retry-counter-stalled-cutoff.sh`).

## INV-06: "crashed" / "process not found" keyword contract

_Triage (issue #236): [design-rationale]_

**Rule**: The dispatcher's Step 5b dispatcher-crash comments MUST contain one of: `Task appears to have crashed (no PR found)`, or `process not found`. Forward-progress comments — specifically Step 5a's "Dev process still alive but PR ... ready" and Step 5b's "Dev process exited (PR found)" / "Dev process exited (no new commits since last review at ...)" — MUST NOT contain these phrases.

**Why**: Step 4a's retry-counter regex is `Task appears to have crashed \(no PR found\)|process not found`. A forward-progress comment that accidentally contained the word "crashed" (or "process not found") would be miscounted as a dev failure → eventually mark `stalled` despite the dev having actually progressed (#50).

**Producer**: dispatcher Step 5a (writes "Dev process still alive..."), Step 5b (writes "Task appears to have crashed..." or "Dev process exited (PR found)" or "Dev process exited (no new commits since last review at...)").
**Consumer**: dispatcher Step 4a's retry-counter regex.
**Test**: TODO: add test that Step 5a and Step 5b PR-found comments don't match the Step 4a regex.

## INV-07: Empty Reviewed-HEAD trailer routes to pending-review

_Triage (issue #236): [design-rationale]_

**Rule**: When the dispatcher's Step 5b DEAD-with-PR branch finds an empty `LAST_REVIEWED_HEAD`, it MUST route to `pending-review`, NOT `pending-dev`.

**Why**: An empty value can mean either (a) review never ran successfully against this PR (the safe first-review case), or (b) the review wrapper's trailer post failed (token expiry, 403, rate limit). Both cases are best served by handing the PR to a fresh review — false-positive route-to-dev would loop forever ("dev exited, dispatcher sees no SHA match because no trailer, sends to dev again, ...").

**Producer**: dispatcher Step 5b.
**Consumer**: dispatcher's own routing decision.
**Test**: TODO: add test for both empty-trailer causes.
**Operator note**: if `pending-review` cycles repeatedly without new commits, grep `/tmp/agent-${PROJECT_ID}-review-*.log` for `WARNING: Failed to post Reviewed HEAD trailer`.

## INV-08: Wrapper exit trap label edits are atomic per call

_Triage (issue #236): [design-rationale]_

**Rule**: Wrapper exit traps MUST update labels using single `gh issue edit --remove-label X --add-label Y` calls, never two separate calls. This guarantees no transient "both labels present" or "neither label present" state visible to the dispatcher between calls.

**Why**: Without single-call atomicity, a maintainer or another dispatcher cron tick reading labels at the wrong instant could see `pending-review + pending-dev` (forbidden, see [`state-machine.md` § Forbidden transitions](state-machine.md#forbidden-transitions)) or no active state at all (would reset the issue to "fresh autonomous, dispatch new" via Step 2).

**Note**: this invariant is about **per-edit atomicity**, NOT about cross-actor convergence. When the dispatcher's Step 5a and the wrapper trap both edit labels in the same window, they may target *different* final states — see [INV-15](#inv-15-step-5a-sigterm-race-is-non-deterministic). Each side's individual edit is still atomic, but the last-writer-wins outcome is non-deterministic.

**Producer**: dev wrapper trap, review wrapper trap, dispatcher Step 2/3/4/5.
**Consumer**: any reader of issue labels (other dispatcher ticks, maintainers).
**Test**: TODO: add test that mocks `gh issue edit` and asserts no two-call sequences exist.

## INV-09: `JUST_DISPATCHED` skip rule

_Triage (issue #236): [design-rationale]_

**Rule**: Within a single dispatcher tick, Step 5 MUST skip any issue whose number is in the `JUST_DISPATCHED` array (issues dispatched in Steps 2/3/4 of the same tick).

**Why**: Freshly-dispatched wrappers are spawned via `nohup` and may not have written their PID file yet when Step 5 runs. Without the skip, Step 5 sees the PID file missing, diagnoses DEAD-no-PR, increments the retry counter, and eventually marks the issue stalled — for issues that were just dispatched and are in fact running fine (#34, #41).

**Producer**: dispatcher Step 2/3/4 (all append to `JUST_DISPATCHED`).
**Consumer**: dispatcher Step 5.
**Test**: TODO: add test that simulates a Step 2 → Step 5 within the same tick.

## INV-10: 5-minute idle gate before SIGTERM

_Triage (issue #236): [design-rationale]_

**Rule**: Step 5a MUST require `now - PR.updatedAt > 300s` (strict greater-than, matching SKILL.md's `[ "$IDLE_SECONDS" -gt 300 ]`) before sending SIGTERM to an alive wrapper.

**Why**: Without it, the dispatcher might SIGTERM an agent that just pushed its passing CI build and is in the middle of its own cleanup (closing worktree handles, posting status comments, etc.). 5 min matches the dispatcher cron interval — the *next* tick will be the one to act on a wrapper still alive after CI is green, not the tick that detected green CI (#56).

**Producer**: dispatcher Step 5a.
**Consumer**: itself.
**Test**: TODO: add test that varies `PR.updatedAt` and confirms gate behavior at 300s, 301s.

## INV-11: Dependency state includes `MERGED`

_Triage (issue #236): [machine-checked: tests/unit/test-check-deps-resolved.sh]_

**Rule**: Step 2's dependency check MUST treat both `CLOSED` and `MERGED` as resolved states. PRs return `MERGED` when merged, NOT `CLOSED`. The same `state ∉ {"CLOSED", "MERGED"}` rule applies to cross-repo refs resolved under [INV-39](#inv-39-dependency-parsing-is-list-item-scoped-and-supports-cross-repo-refs).

**Why**: When a `## Dependencies` section references a PR that has been merged, `gh issue view N --json state` returns `state: "MERGED"`. A naive `state != "CLOSED"` check leaves the dependent issue blocked forever (#61).

**Producer**: dispatcher Step 2 (`lib-dispatch.sh::check_deps_resolved`).
**Consumer**: itself.
**Status**: **ENFORCED** in PR-4 (closes #61). The check reads `state ∉ {"CLOSED", "MERGED"}` for both same-repo and cross-repo refs.
**Test**: `tests/unit/test-check-deps-resolved.sh` covers single-CLOSED, single-MERGED, single-OPEN, multi-dep mixed-state scenarios, and cross-repo MERGED/CLOSED/OPEN.

## INV-12: Resume only against unfinished sessions

_Triage (issue #236): [machine-checked: tests/unit/test-is-session-completed.sh, tests/unit/test-autonomous-launcher-verdict-fresh.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-agent-timeout-wrapper.sh]_

**Rule**: `lib-agent.sh::run_agent` and `resume_agent` MUST wrap the underlying CLI call in `timeout --kill-after=30s --signal=TERM ${AGENT_TIMEOUT:-4h}` (with graceful fallback to `gtimeout` on macOS).

**Why**: Any of: SSE keepalive without stop event (#59 root cause), MCP server stdio deadlock, DNS/TCP black hole. Without a wall-clock cap, any of those can pin a wrapper for 8+ hours (#60).

**Producer**: `lib-agent.sh::run_agent` and `resume_agent` via the shared `_run_with_timeout` helper.
**Consumer**: prevents wrappers from monopolizing PID slots and quota.
**Status**: **ENFORCED** in PR-6 (closes #60). The helper resolves `timeout`/`gtimeout` once at source time and falls through to an unwrapped invocation with a one-time WARN log when neither is on PATH. All six AGENT_CMD branches (claude / codex / gemini / kiro / opencode / fallback) and both call sites (run_agent / resume_agent) get the same wrapper.
**Test**: `tests/unit/test-agent-timeout-wrapper.sh` (6 cases): timeout fires within budget on `sleep 5` vs `AGENT_TIMEOUT=1s`; passthrough exit codes preserved (0 and non-zero); fallback path with `_AGENT_TIMEOUT_CMD=""` works for both success and non-zero commands.

## INV-14: Config lookup honors symlink-vendor pattern

_Triage (issue #236): [machine-checked: tests/unit/test-bash-source-empty.sh, tests/unit/test-symlink-resolution.sh]_

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

> **Superseded for `lib-*.sh` by [INV-65] (#227).** As of #227, entry scripts source siblings from the REAL skill-tree path (`readlink -f`), so `lib-*.sh` no longer need a per-project symlink — `install-project-hooks.sh` symlinks ONLY the STABLE ENTRY manifest (everything that is NOT `lib-*.sh`) and prunes stale per-lib symlinks. The conf-lookup half of INV-14 below is unchanged: entries still resolve `autonomous.conf` from the UNRESOLVED project-side dir. The table below is retained for historical context (pre-#227 behavior) and still describes which files the installer manages — minus the `lib-*.sh` rows, which are now skill-tree-resolved.

Each entry-point script sources sibling lib files via `${SCRIPT_DIR}/<sibling>.sh`. With `BASH_SOURCE[0]`-based `SCRIPT_DIR`, those resolve to the project's `scripts/` — which means the operator MUST symlink every transitive sibling, not just the entry-points. Symlinking only `dispatch-local.sh` would break with `No such file or directory: lib-config.sh`. The minimum set (pre-#227; `lib-*.sh` rows now superseded by [INV-65]):

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

_Triage (issue #236): [machine-checked: tests/unit/test-sigterm-trap.sh]_

**Rule**: When the dispatcher's Step 5a sends SIGTERM to an alive wrapper for a PR-ready issue, the dispatcher writes `+pending-review` AND the wrapper's exit trap (which fires from the SIGTERM with bash exit status 143) writes `+pending-dev` — they target **different** final states. The race outcome is whichever `gh issue edit` lands last; in practice the trap's edit lands ~1s after the dispatcher's because the trap also posts a Session Report comment first.

**Why**: surfaced by the PR-2 docs review. The dev wrapper has no SIGTERM-aware code path; `cleanup()` only inspects `$exit_code` (143 ≠ 0 ⇒ failure branch ⇒ `pending-dev`). The dispatcher's Step 5a was designed under the assumption that the trap would route to `pending-review` (the "PR-ready" intent). It does not.

**Effect**: the issue typically lands in `pending-dev` after Step 5a fires (trap's later write wins). The PR is preserved (still open). The next dispatcher tick sees `pending-dev` and dispatches dev-resume. Review is delayed by one tick (~5 min) but no work is lost.

**Producer**: dispatcher Step 5a + dev wrapper trap (jointly).
**Consumer**: future dispatcher tick that has to pick up the resulting state.
**Status**: **ENFORCED** in PR-6 (closes #67). `autonomous-dev.sh` installs `trap on_sigterm TERM` that sets `RECEIVED_SIGTERM=1` and forwards SIGTERM to descendants via `pkill -TERM -P $$` (so the agent CLI exits promptly instead of bash queueing the signal until the foreground `run_agent` returns naturally). The `cleanup()` EXIT trap then rewrites `exit_code 143 → 0` when `RECEIVED_SIGTERM=1 && PR_EXISTS>0`, routing through the success branch to `pending-review`. SIGTERM with no PR keeps `exit_code=143` → `pending-dev` (covers operator-kill / orphan cases). Step 5a still writes its own label edit as belt-and-suspenders against SIGKILL escalation; both writers now converge on `pending-review`.
**Test**: `tests/unit/test-sigterm-trap.sh` (8 cases): the bug being fixed (143 + PR → pending-review) plus regression guards for clean exit / crash / timeout / no-PR variants, plus a source-of-truth grep on the wrapper to detect drift.

**Residue note (INV-25)**: even with the convergent SIGTERM path, label residue from earlier races, manual reconciliation, or future yet-unknown producers is healed by Step 0 hygiene at every tick — see [INV-25](#inv-25-terminal-labels-approved-stalled-are-sticky-transitional-residue-is-healed-at-tick-start). INV-15 narrows the producer surface; INV-25 closes the residue class regardless of producer.

## INV-16: jq named-group regex uses Oniguruma syntax, not Python

_Triage (issue #236): [machine-checked: tests/unit/test-lib-dispatch.sh]_

**Rule**: Any jq regex that names a capture group MUST use Oniguruma syntax `(?<name>...)`, NOT Python-style `(?P<name>...)`. jq 1.6+ uses Oniguruma; the Python-style form errors with `Regex failure: undefined group option`.

**Why**: surfaced by PR-3's unit testing of `extract_dev_session_id` (#70). The original SKILL.md regex used `(?P<id>...)` — every `gh issue view ... -q '...capture(...)...'` call returned exit 5 with the regex error in stderr, and the `// empty` fallback did NOT catch it (jq exits before `//` is evaluated). In production this meant `extract_dev_session_id` always returned empty, and `dispatch-local.sh dev-resume <issue> ""` either failed input validation or silently fell back to a fresh session — i.e. resume mode was probably never resuming context across review cycles.

**Producer**: any helper in `lib-dispatch.sh` (or future jq-using code) that captures a named group. Today: `extract_dev_session_id`, `last_reviewed_head`. Both use the correct `(?<...>)` after PR-4.

**Consumer**: dispatcher Step 4 (which calls `extract_dev_session_id` to find the session-id to resume) and Step 5b (which calls `last_reviewed_head` to compare against the current PR HEAD).

**Status**: **ENFORCED** in PR-4 (closes #70). Both helpers verified.

**Test**: `tests/unit/test-lib-dispatch.sh` asserts that `extract_dev_session_id` returns `abc-123-def` for a comment containing `Dev Session ID: \`abc-123-def\`` (was previously asserting empty under the broken regex).

## INV-17: Trunk protection requires defense in depth across 3 layers

_Triage (issue #236): [machine-checked: tests/unit/test-block-push-regex.sh, tests/unit/test-install-git-pre-push.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-dispatcher-reliability-99.sh]_

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

**Cross-references**:
- [INV-89](#inv-89-every-machine-marker--agent-and-dispatcher-inv-18inv-39-included--is-posted-only-through-the-declared-marker_channel-the-read-side-capture-regex-branches-on-channel) — the dispatch-token marker is a machine marker; since #283 `post_dispatch_token` posts it through `itp_post_comment` on the declared `marker_channel` (the BODY, incl. the `<!-- dispatcher-token: … -->` text, composed caller-side and round-tripped verbatim).

---

## INV-19: Retry counter requires confirmed agent startup

_Triage (issue #236): [machine-checked: tests/unit/test-dispatcher-reliability-99.sh, tests/unit/test-lib-dispatch.sh]_

**Rule**: `count_retries` MUST count dispatcher-detected crash comments toward `MAX_RETRIES` ONLY when the agent has confirmed startup at some point in the current retry cycle — i.e., a `Dev Session ID:` comment exists after the most recent stalled-cutoff AND that comment is NOT a `Mode: startup-failure` report. Agent failure session reports (`Agent Session Report (Dev)` with non-zero exit code) always count regardless.

The `Mode: startup-failure` exclusion matters: `autonomous-dev.sh`'s startup-failure trap (when the wrapper exits before invoking the agent — e.g., #92 missing-`gh` path) still emits a session report containing the SESSION_ID that was forwarded for dev-resume mode. Counting that as "agent confirmed startup" would re-arm dispatcher-crash counting on a wrapper that never actually invoked the agent.

**Why**: surfaced by #99 Bug 5. Pre-fix, dispatcher-side false positives (Bug 1 cold-start, missing exec bit, broken auth handoff before agent ran) consumed `MAX_RETRIES` even though the agent never failed. By definition such crashes happen before the agent has had a chance to write its session-id comment, so gating the count on session-id presence cleanly suppresses them while preserving counting for legitimate post-startup crashes (network drop mid-session, segfault, OOM kill).

**Producer**: `autonomous-dev.sh` cleanup() trap writes the `Agent Session Report (Dev)` comment containing `Dev Session ID: \`<id>\``. This is the post-startup checkpoint that arms dispatcher-crash counting.

**Consumer**: `lib-dispatch.sh::count_retries` — gates dispatcher-crash counting on the presence of any post-cutoff session-id comment. `count_dispatcher_false_positives` reports the suppressed count for operator visibility in `mark_stalled`'s comment.

**Status**: **ENFORCED** in #99 fix.

**Test**: `tests/unit/test-dispatcher-reliability-99.sh` covers session-id-gate semantics (5 cases including stalled-cutoff interaction). `tests/unit/test-lib-dispatch.sh` regression cases updated to reflect the new gate.

---

## INV-20: Verdict authenticity binding (actor + window + trailer presence)

_Triage (issue #236): [machine-checked: tests/unit/test-autonomous-launcher-verdict-fresh.sh, tests/unit/test-autonomous-review-prompt.sh]_

> **Demoted to a fallback by [INV-78](#inv-78-review-verdicts-resolve-from-a-typed-artifact-file-first-comment-scraping-is-an-explicitly-logged-fallback-a-malformed-artifact-is-loud-never-a-silent-absent) (#233).** The review wrapper now resolves each agent's verdict from a typed artifact FILE FIRST; this comment-authenticity binding runs ONLY for an agent that produced no artifact (logged `verdict-source=comment-fallback`). It remains fully load-bearing on that fallback path and is unchanged.

**Rule**: The review wrapper's verdict polling jq query MUST gate on three layered predicates when actor binding is available: (a) `author.login == BOT_LOGIN`, (b) `createdAt >= WRAPPER_START_TS`, (c) `body matches /Review Session/`. The trailer match MUST NOT bind to the wrapper-generated `SESSION_ID` — only the trailer's presence is checked.

**Per-agent amendment ([INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback), #166)**: when the wrapper fans out to more than one verdict-reaching agent (`AGENT_REVIEW_AGENTS` lists ≥2 CLIs), all N agents post under the SAME GitHub identity (token mode, or app mode sharing `REVIEW_AGENT_APP_ID`), so layers (a)+(b)+(c) match ALL N verdict comments and `last` would collapse them to one. The authenticity layer therefore becomes **per-agent**: each agent's prompt instructs it to emit a `Review Agent: <name>` discriminator line, and the wrapper runs ONE verdict query per agent adding a fourth predicate `body matches /Review Agent: <name>/`, taking `last` per agent. The `Review Session: <uuid>` trailer is still required (presence-only, per the rule above) and remains the `BOT_LOGIN`-empty fallback's narrowing key (now the *per-agent* session UUID). **N=1 carve-out**: when `AGENT_REVIEW_AGENTS` is empty/unset, there is exactly one agent and one query; the added `Review Agent:` predicate is satisfied by the lone agent's discriminator and does not change routing — the single-agent verdict binding is byte-for-byte the pre-#166 behavior.

**Why**: The prior body-text predicate `Review Session.*${SESSION_ID}` depended on the agent echoing the wrapper's UUID verbatim. Agents under context pressure occasionally rewrote the UUID, causing the wrapper to miss valid verdicts and force the FAILED branch. Combined with a same-PR / same-issue dispatcher state machine, this produced infinite dev↔review ping-pong loops on the consumer side. Trailer-presence (without UUID binding) keeps spoof protection intact in `GH_AUTH_MODE=token` (where dev and review wrappers share BOT_LOGIN — the dev agent's prompts don't instruct it to emit `Review Session:`, so its status comments are excluded) without the brittleness.

**Producer**: `autonomous-review.sh` polling loop. Captures `WRAPPER_START_TS` once before `run_agent` (ISO-8601 UTC) and `BOT_LOGIN` once via `gh api user --jq .login` (treats empty / errored / literal-`"null"` as unset).

**Consumer**: prevents (a) verdict regressions when the agent rewrites the trailer UUID, (b) cross-wrapper spoofing in same-identity (token) mode, (c) stale verdicts from prior ticks being picked up.

**Fallback**: when `BOT_LOGIN` is unset, the predicate becomes `(createdAt >= WRAPPER_START_TS) AND (body matches /Review Session.*<SESSION_ID>/)`. This re-introduces the brittleness only on the rare path where actor binding is unavailable, and time-window predicate still narrows out stale comments.

**Status**: **ENFORCED**. Originally replaced the prior session-id-only binding (which closed #95 phrasing-drift but did not address the UUID-rewrite drift). Amended in #166 to add the per-agent `Review Agent: <name>` layer for multi-agent fan-out ([INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)); the N=1 single-agent binding is unchanged.

**Test**: `tests/unit/test-autonomous-launcher-verdict-fresh.sh` TC-VRD-001..009a (12 cases including token-mode dev-agent quoted-verdict anti-spoof). The per-agent `Review Agent:` discriminator amendment is covered by `tests/unit/test-autonomous-review-prompt.sh` TC-ARP-06 and `tests/unit/test-autonomous-review-multi-agent.sh` TC-MAR-SRC-10.

## INV-21: Resume-fallback fresh session id is dispatcher-readable

_Triage (issue #236): [machine-checked: tests/unit/test-autonomous-launcher-verdict-fresh.sh]_

**Rule**: `autonomous-dev.sh` MODE=resume's non-zero-exit fallback path, immediately after assigning `SESSION_ID="$NEW_SESSION_ID"`, MUST post a standalone GitHub issue comment matching the regex `Dev Session ID: \`<id>\``.

**Why**: Without this, the only place the new session id surfaces to GitHub before the agent runs is inside the explanatory "Resume failed... Starting new session..." comment — which does NOT match the dispatcher's `extract_dev_session_id` regex. If the wrapper crashes between the resume-fallback decision and the trap-on-exit `Agent Session Report (Dev)` post (e.g. a transient gh outage on the report post), the dispatcher's next tick reads the OLD session id from prior comments and resumes the dead session forever.

**Producer**: `autonomous-dev.sh:362..366` — two separate `gh issue comment` calls (explanation + standalone marker) so a single failed post can't orphan the marker.

**Consumer**: `lib-dispatch.sh::extract_dev_session_id` — picks up the new id on the next tick.

**Status**: **ENFORCED** in this PR.

**Test**: `tests/unit/test-autonomous-launcher-verdict-fresh.sh` TC-PTL-005.

## INV-22: AGENT_LAUNCHER tokenization + claude-only invocation contract

_Triage (issue #236): [machine-checked: tests/unit/test-autonomous-launcher-verdict-fresh.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-pid-guard-pgid.sh, tests/unit/test-sigterm-trap.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-dispatcher-review-near-success.sh, tests/unit/test-wrapper-heartbeat.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-step0-hygiene.sh]_

**Rule**: When an issue carries either terminal label (`approved` or `stalled`) AND any transitional label (`in-progress`, `reviewing`, `pending-review`, `pending-dev`), the dispatcher MUST strip the transitional label(s) at the very top of every tick — before Step 1's concurrency gate, before any `list_*` selector reads labels. Strips are atomic per issue (single `gh issue edit --remove-label A --remove-label B ...`). For each `(issue, sorted-set-of-stripped-labels)` tuple, an audit comment of the form `Label hygiene: stripped \`X\`, \`Y\` from \`<terminal>\` issue (INV-25). <!-- INV-25-hygiene:<sorted-labels> -->` is posted at most once — the marker comment gates re-posting on subsequent ticks.

**Why**: `state-machine.md::Forbidden transitions` already declared this combination invalid. Code did not enforce it: when residue landed (wrapper crash between two label edits, [INV-15] SIGTERM race, manual reconciliation by an operator), the next tick's `list_*` selectors disagreed about how to handle the issue and one of them re-armed dispatch. Issue #115 Bug A (PR #116) fixed one specific selector; Bug B (this invariant) closes the class by self-healing residue regardless of which selector would have misclassified it.

Step 0 runs UNCONDITIONALLY — even when concurrency is saturated. Hygiene is pure label edits, no agent dispatch, no retry counting; gating it on capacity would defer cleanup by an entire tick on a busy day, exactly when residue is most likely.

**Producer**: `lib-dispatch.sh::run_hygiene_pass`, `list_hygiene_residue`, `hygiene_strip_residual_labels`, `hygiene_post_audit_comment`, `_has_terminal_label`.

**Consumer**: `dispatcher-tick.sh` Step 0 (calls `run_hygiene_pass` before Step 1).

**Cross-references**:
- [INV-15] documents the SIGTERM race that is one *producer* of the residue this invariant heals. The race itself is convergent (PR-6); the residue this heals is from earlier-or-different races and from manual reconciliation, not from the SIGTERM path under normal conditions.
- All four `list_*` selectors in `lib-dispatch.sh` (`list_new_issues`, `list_pending_review`, `list_pending_dev`, `list_stale_candidates`) inline their own `approved` AND `stalled` subtraction. `list_new_issues` was correct from inception (it explicitly excludes every state label); `list_stale_candidates` was fixed in PR #116 (Bug A); `list_pending_review` and `list_pending_dev` were fixed by the Bug C post-investigation PR — pre-fix, `list_pending_review` only excluded `reviewing` and `list_pending_dev` had no inline filter at all. INV-25 makes those inline subtractions defense-in-depth rather than the only line of defense — Step 0 hygiene heals the residue at tick start regardless of which selector would have misclassified. Future selectors should call `_has_terminal_label()` for symmetry; a missed call is no longer a Bug-A-class infinite-loop bug, just a wasted query.
- [INV-26] (stall-decision correctness) reduces one of the producers of the `stalled + transitional` residue this invariant heals: pre-INV-26, `mark_stalled` could fire against a still-live wrapper, the wrapper trap then writing `+pending-review` onto the resulting `+stalled` issue. With INV-26, that producer is closed at the upstream side — the live wrapper finishes first, the trap correctly transitions to `+pending-review` (no `stalled`), and INV-25 only has to heal residue from genuinely-stalled-but-late-trap edge cases.
- [INV-89](#inv-89-every-machine-marker--agent-and-dispatcher-inv-18inv-39-included--is-posted-only-through-the-declared-marker_channel-the-read-side-capture-regex-branches-on-channel) / [INV-87](#inv-87-provider-dispatch-is-spec-defined--callers-route-every-issuecode-host-op-through-itp_chp_-never-a-raw-gh-in-the-caller-layer) — since #283 the four `list_*` selectors route their `gh issue list` enumeration through `itp_list_by_state` and the `label_swap` state transition through `itp_transition_state`, but the **terminal-state jq subtraction here stays CALLER-side** ([`provider-spec.md`](provider-spec.md) §3.1 / the verb↔function mapping appendix). It is NOT folded into `itp_transition_state` — the transition verb is a pure remove+add leaf, and the `approved`/`stalled` subtraction remains defense-in-depth in `lib-dispatch.sh`. The `hygiene_strip_residual_labels` multi-remove strip is the one allowlisted variable label write that stays as a direct `gh` call (it removes a variable-length set with no add — not the single-remove/single-add the transition verb expresses).

**Status**: **ENFORCED** in #115 Bug B; the read/transition leaves route through the ITP verbs as of #281/#283 (the terminal-state subtraction stays caller-side).

**Test**:
- `tests/unit/test-step0-hygiene.sh` (23 cases) — TC-HAS-TERM-001..005 cover the predicate, TC-HYG-001..006 cover per-issue strip logic, TC-COMMENT-001..003 cover audit-comment idempotency, TC-STEP0-INT-001..003 statically pin Step 0 placement (before Step 1, not gated by concurrency).

## INV-26: Stall decision excludes dispatcher-induced terminations and defers on live wrappers

_Triage (issue #236): [machine-checked: tests/unit/test-pid-alive-remote-aws-ssm.sh, tests/unit/test-count-agent-failures-sigterm.sh]_

**Rule**: Two conjunct conditions must hold before the dispatcher can mark an issue `+stalled`:

1. **Failure counter accuracy**: `count_agent_failures` (`lib-dispatch.sh`) MUST exclude Session Reports whose `Exit code` is 0 (success), 143 (SIGTERM), or 137 (SIGKILL) from the agent-failure tally. Exits 143 and 137 are almost exclusively caused by `dispatch-local.sh::kill_stale_wrapper` — the dispatcher's own kill of a stale wrapper to spawn a fresh one. Counting the dispatcher's kill as an "agent failure" silently consumes retry budget the agent never spent.
2. **Liveness deferral**: `mark_stalled` MUST query `pid_alive issue <issue_num>` before any `gh issue edit` or stall comment. If the dev wrapper is alive, the stall decision is deferred — `mark_stalled` returns 0 without changing labels, posts a one-shot deferral comment (idempotency-keyed on the wrapper PID via marker `INV-26-stall-deferral:pid=<pid>`), and lets the next tick re-evaluate. The stall path proceeds only when no live wrapper holds the PID file.

   **At-cap call (issue #263)**: `mark_stalled` accepts an optional leading positional `--at-cap` flag and, when present, propagates it to its liveness probe (`pid_alive --at-cap`). The flag is passed by **exactly one caller** — the retry-budget-exhausted site (`dispatcher-tick.sh` Step 4, fired only when `count_retries >= MAX_RETRIES`). Under `EXECUTION_BACKEND=remote-aws-ssm`, `--at-cap` makes a persistently *indeterminate* SSM liveness verdict return DEAD instead of biasing ALIVE (see [INV-30]'s at-cap exception). This bounds the deferral to ONE tick once retries are exhausted, fixing the unbounded-defer hang where a flaky transport kept `mark_stalled` deferring forever and the `stalled` label was never written (a downstream consumer's ~40h hang). The **other** caller — `handle_completed_session_routing`'s `REVIEW_RETRY_LIMIT` (review-retry-cap) branch — is **not** the retry-budget-exhausted state and therefore calls `mark_stalled` WITHOUT the flag, so its liveness probe keeps [INV-30]'s indeterminate→ALIVE bias. (A blanket `--at-cap` in `mark_stalled` would over-apply the DEAD bias to the review-cap path; this was a BLOCKING finding in the #263 review.) The flag is positional, never an env var, so it cannot leak between callers. Definite ALIVE/DEAD verdicts are unaffected for either caller.

   **Empty-PID = DEAD shortcut, narrowed to local backend (issue #263)**: when the backend is `local` (or unset = local default) AND `get_pid` returns empty AND `pid_alive` returned ALIVE (only reachable under local backend via the tier-2 PID-file-mtime or tier-3 heartbeat-mtime fallbacks, where the PID file *content* can be empty while its mtime is fresh), `mark_stalled` treats the empty PID as DEAD: it skips the one-shot deferral comment entirely and proceeds to write `stalled` — an empty PID means no wrapper is running. This shortcut MUST NOT apply under `remote-aws-ssm`: there the PID file lives on the wrapper box and dispatcher-side `get_pid` is *always* empty regardless of wrapper state, so empty-PID is the steady state, not a DEAD signal — under the remote backend the liveness verdict comes from the SSM transport (with `--at-cap` deciding the indeterminate case for the MAX_RETRIES caller), never from the dispatcher-side empty PID. Applying the shortcut under the remote backend would resurrect the #121 / downstream-consumer false-stall bug. The shortcut is independent of `--at-cap`: it is correct for both callers because an empty PID under local backend genuinely means no wrapper holds the file.

**Why**: Without (1), `kill_stale_wrapper`-induced SIGTERMs accumulate against the retry budget; combined with `pid_alive` misjudgements producing "Task crashed" comments, MAX_RETRIES is hit prematurely. Without (2), `mark_stalled` then transitions to `+stalled` while the wrapper is still alive — and the wrapper subsequently completes work, the trap writes `+pending-review` onto a `+stalled` issue, the next tick's Step 3 picks it up (pre-#118: with no `stalled` filter; post-#118: blocked by Step 0 hygiene but only after a tick lag), and the issue ends in inconsistent label state. Reproduced on a downstream consumer's `#204`-class wedge on 2026-05-14: 2 dispatcher-misjudgement crashes + 1 SIGTERM-from-dispatcher → false stall while the real wrapper finished and PR auto-merged. See #121.

**Producer**:
- (1) `lib-dispatch.sh::count_agent_failures` — jq predicate excludes exit codes 0, 143, 137. Anchors on `\b` word boundary so 144 / 1430 don't false-match.
- (2) `lib-dispatch.sh::mark_stalled` — queries `pid_alive` first (propagating `--at-cap` when the caller passed it; only the `dispatcher-tick.sh` Step 4 MAX_RETRIES site does); defers (post one-shot comment, return 0) if alive, except under local backend with an empty PID (treated as DEAD, no deferral comment, independent of `--at-cap`).

**Consumer**: `dispatcher-tick.sh` Step 4 retry-counter branch — calls `mark_stalled` when `count_retries >= MAX_RETRIES`. With both rules in place, a wrapper that's making real progress can never be `+stalled` until it has actually exited.

**Cross-references**:
- [INV-15] (SIGTERM race) is one *producer* of the residue [INV-25] heals; this invariant prevents the *upstream* false stall that creates the residue in the first place.
- [INV-19] (retry counter requires confirmed agent startup) gates dispatcher-detected crashes; this invariant adds a parallel gate on agent-side Session Reports for terminations the dispatcher itself caused.
- [INV-23] (PID_FILE death reaps subtree) gives `pid_alive` its truth: a wrapper still holding the PID file means the agent subtree is reachable. The liveness deferral relies on that contract.
- [INV-24] (review wrapper DEAD detection requires near-success short-circuit) is the review-side analog. The dev-side near-success short-circuit ([INV-27], `dev_near_success`) complements this invariant by preventing the upstream "Task crashed" comments that would otherwise drive the counter; INV-26 then catches anything INV-27 misses by deferring the actual stall transition when the wrapper is still alive.
- [INV-30] (`pid_alive` authoritative under all execution backends) — `mark_stalled`'s `pid_alive` call inherits remote-backend awareness automatically: when `EXECUTION_BACKEND=remote-aws-ssm`, the SSM-driven liveness query reaches the wrapper box directly. The bare `pid_alive` call needed no code change for #137; issue #263 added the `--at-cap` argument (see [INV-30]'s at-cap exception) so a *persistently-indeterminate* SSM verdict at MAX_RETRIES no longer defers the stall forever. (Verified by TC-RPA-007 and TC-MSL-006 in `tests/unit/test-pid-alive-remote-aws-ssm.sh` / `tests/unit/test-mark-stalled-liveness.sh`.)

**Status**: **ENFORCED** (closes #121 Fix A + Fix C; Fix B / `dev_near_success` is a separate follow-up PR; the at-cap ceiling + empty-PID local-backend shortcut added in #263).

**Tests**:
- `tests/unit/test-count-agent-failures-sigterm.sh` (7 cases): TC-CAF-001/006/007 cover regression bounds (0/1/124/144 still scored correctly), TC-CAF-002/003 cover genuine failures, TC-CAF-004/005 cover the new SIGTERM/SIGKILL exclusions, TC-CAF-007 covers a mixed-bag fixture.
- `tests/unit/test-mark-stalled-liveness.sh` (10 cases): TC-MSL-001/004/005 cover the alive-wrapper deferral path, TC-MSL-002/003 cover the dead-PID and missing-PID paths (existing behavior preserved), TC-MSL-006 covers the remote at-cap indeterminate → `stalled`-on-same-tick fix when the MAX_RETRIES caller passes `--at-cap` (asserts the label write AND the absence of the deferral comment — the downstream-consumer regression), TC-MSL-007 covers the local empty-PID → DEAD shortcut, TC-MSL-008 guards the genuine-alive deferral, TC-MSL-009 guards that `pid_alive` WITHOUT `--at-cap` keeps the [INV-30] ALIVE-bias, TC-MSL-010 guards that `mark_stalled` WITHOUT `--at-cap` (the review-retry-cap caller) keeps the [INV-30] ALIVE-bias under remote indeterminate (the #263-review BLOCKING-finding regression). Uses a real spawned `sleep` for the alive cases to avoid mocking `kill -0`.

## INV-27: Dev wrapper DEAD detection requires both pid_alive miss AND no near-success in-flight signal

_Triage (issue #236): [machine-checked: tests/unit/test-dev-near-success.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-dispatch-local-pgrep-type-scope.sh, tests/unit/test-pid-guard-pgid.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-pid-alive-long-running.sh, tests/unit/test-kill-before-spawn.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-pid-alive-remote-aws-ssm.sh, tests/unit/test-liveness-check-remote-aws-ssm.sh]_

**Rule**: under any non-`local` `EXECUTION_BACKEND`, `pid_alive` MUST consult a backend-specific liveness transport (today: `liveness-check-remote-aws-ssm.sh`) before any local probe. The transport runs the equivalent of [INV-29]'s three-tier check (kill -0, PID-file mtime, heartbeat sibling mtime) on the box where the wrapper actually lives, not on the dispatcher box.

The transport's stdout is one of `ALIVE` / `DEAD` / empty. Indeterminate verdicts (transport fault, timeout, garbled stdout, instance offline) MUST bias toward ALIVE — the dispatcher's `pid_alive` returns 0 (alive), the caller defers crash declaration by one tick, and the next tick retries. **Indeterminate MUST NOT surface as DEAD**.

**Why**: under remote backend (e.g. `EXECUTION_BACKEND=remote-aws-ssm`), the dispatcher's box doesn't have the wrapper's PID file or heartbeat sibling — they live on the wrapper box. The legacy three-tier check ([INV-29]) always misses there, so `pid_alive` returns DEAD on every tick. Combined with [INV-27]'s near-success backstops being timestamp-based and missing during the cold-start window before the agent emits any artifact, every tick declares crashed → six `count_dispatcher_crashes` → `mark_stalled` on a wrapper that's still doing real work. Reproduced on a downstream consumer's #182 (2026-05-16 02:15–04:10 UTC): six "Task appears to have crashed (no PR found)" comments at 5-min cron intervals, sixth wrapper SIGTERMed by `kill_stale_wrapper` 4 seconds after spawn (Session Report: exit 143), marked stalled at 04:10. The session that actually completed (PR opened at 05:21Z) ran outside the dispatcher's reach because `stalled` issues are skipped — "stalled label saved it from the dispatcher" was the user's apt summary.

**Conservative bias rationale**: when the transport can't give a definitive verdict, two error directions are possible:
- (a) Treat unknown as DEAD → false crash comments + premature stall (the bug being fixed). Recovery: manual `gh issue edit --remove-label stalled`. High operator cost.
- (b) Treat unknown as ALIVE → real crashes get delayed detection by 1+ ticks until the transport recovers. Recovery: automatic on the next successful tick. Low operator cost.

(b) is recoverable; (a) is not. INV-30 chooses (b). A `_REMOTE_LIVENESS_DEGRADED_COUNT` per-process counter records consecutive indeterminate verdicts; `pid_alive` emits a stderr WARN on count=1 and every count%10==0 thereafter so operators see degradation without per-tick log spam.

The default `*) return 0` form (the indeterminate → ALIVE bias) is **unchanged** and remains the source-of-truth for normal-budget callers; `tests/unit/test-pid-alive-remote-aws-ssm.sh::TC-RPA-010` grep-asserts that exact form so a reflexive cleanup PR can't flip it to `return 1`.

**At-cap exception (issue #263)**: `pid_alive` accepts an optional leading positional `--at-cap` flag. When set, an *indeterminate* remote verdict returns 1 (DEAD) instead of biasing ALIVE. This does NOT weaken the conservative-bias rationale above — it is a deliberate **policy choice** scoped to the one call path that has already proven the wrapper's retry budget is exhausted: `mark_stalled --at-cap`, passed ONLY by the `dispatcher-tick.sh` Step 4 MAX_RETRIES site ([INV-26]). The review-retry-cap caller of `mark_stalled` omits the flag and retains the ALIVE-bias. At-cap, the trade-off in the table flips: continuing to bias ALIVE on a flaky transport produces the *unbounded* defer loop (the `stalled` label is never written; a downstream consumer hung ~40h), whereas returning DEAD costs at most a false stall on a genuinely-alive wrapper whose recovery is the same one-line `gh issue edit --remove-label stalled` as any other false stall. Framed precisely: **at-cap indeterminate means "stop waiting", NOT "proved dead".** Scope guards:
- The flag is **positional, never an exported env var** — an exported knob would leak into unrelated `pid_alive` calls across the bash test harness's exported functions. Only callers that explicitly pass `--at-cap` get the override.
- The fix is scoped to *indeterminate* verdicts only. A definite ALIVE/DEAD from the transport is honored unchanged. **Stall marking is therefore NOT guaranteed**: a hung SSM driver, a `gh issue edit` failure, or the transport returning ALIVE for a stale/wrong wrapper still won't write `stalled` — those are out of scope.
- `_REMOTE_LIVENESS_DEGRADED_COUNT` is **per-process / per-tick** — it resets each cron tick and is NOT cross-tick memory. It cannot serve as the stall ceiling. The durable ceiling is the dispatcher's retry counter (`count_retries >= MAX_RETRIES`), which is exactly the gate that decides whether `mark_stalled` is called at all and therefore whether `--at-cap` is passed.

Accepted residual trade-off (documented, not fixed): at MAX_RETRIES a genuinely-alive remote wrapper CAN be stalled if SSM is temporarily broken and returns indeterminate. This is the protection [INV-30] normally provides; once retry budget is exhausted the policy deliberately stops deferring on indeterminate.

**Producer**: `lib-dispatch.sh::pid_alive` (extended; `--at-cap` flag added #263); `lib-dispatch.sh::_remote_pid_alive_query`; `liveness-check-remote-aws-ssm.sh`; `lib-ssm.sh::_ssm_run_remote_command`.

**Consumer**: every Step 5 branch in `dispatcher-tick.sh` and `mark_stalled`'s liveness deferral ([INV-26]) — both inherit remote awareness automatically through the unified `pid_alive` interface.

**Disable knobs**:
- `REMOTE_LIVENESS_CHECK_DISABLE=true` — falls back to legacy local-only `pid_alive` even under remote backend (operator escape hatch for transport-blocked deployments).
- `REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS=N` — dispatcher-side polling cap (default 8s).
- `SSM_COMMAND_TIMEOUT_SECONDS=N` — SSM-side cap on the remote shell command (default 10s).

**Cross-references**:
- [INV-23] (PID_FILE reaps subtree) — same setsid PGID semantics; the remote snippet uses `kill -0 <pgid>` and `pgrep -g <pgid>` against the wrapper-box PID file content.
- [INV-26] (stall decision deferral on live wrappers) — `mark_stalled` queries `pid_alive` first; under remote backend that call inherits the remote query automatically. When `mark_stalled` is itself invoked `--at-cap` (only by the `dispatcher-tick.sh` Step 4 MAX_RETRIES site, issue #263), it propagates `--at-cap` to `pid_alive`, capping the indeterminate-defer loop at one tick so a persistently-flaky transport can't strand a retry-exhausted issue in `pending-dev` forever. The review-retry-cap caller (`handle_completed_session_routing`) deliberately omits the flag and keeps the ALIVE-bias.
- [INV-27] (dev DEAD detection requires near-success cross-check) and [INV-24] (review-side analog) — under remote backend these run on the dispatcher box and only see local/comment signals; INV-30's remote `pid_alive` short-circuits before they're consulted on the happy ALIVE/DEAD path. They remain the local-backend defense and a defense-in-depth path when the remote query is indeterminate.
- [INV-29] (heartbeat sibling owned by wrapper) — INV-30's remote snippet implements the same three-tier check (kill -0, PID-file mtime, heartbeat sibling mtime), just on the wrapper box.

**Note on update-ordering for split-box deployments**: dispatcher-side and wrapper-side skill copies CAN be refreshed independently because they only share the on-disk PID-file path schema (`${XDG_RUNTIME_DIR:-$HOME/.local/state}/autonomous-${PROJECT_ID}/${kind}-${N}.pid`), which has been stable since [INV-29]. New dispatcher with old wrapper: the remote snippet still finds the PID file at the expected path and returns an accurate verdict. New wrapper with old dispatcher: the old `pid_alive` falls through to the legacy three-tier and (under remote backend) misses as it did before this PR — no regression vs status quo.

**Status**: **ENFORCED** (closes #137; reproduces and fixes a downstream consumer's #182). The `--at-cap` exception (issue #263) caps the indeterminate-defer loop for the retry-exhausted `mark_stalled` caller; verified by TC-MSL-006 (`tests/unit/test-mark-stalled-liveness.sh`) and TC-MSL-009 / TC-RPA-010 (default ALIVE-bias preserved for non-at-cap callers).

**Test**:
- `tests/unit/test-pid-alive-remote-aws-ssm.sh` (13 cases) — TC-RPA-001..010 cover ALIVE / DEAD / indeterminate / EXECUTION_BACKEND=local no-call regression / `REMOTE_LIVENESS_CHECK_DISABLE=true` / missing env / `mark_stalled` integration / WARN-counter modulo / source-of-truth grep on the indeterminate→ALIVE branch (load-bearing).
- `tests/unit/test-liveness-check-remote-aws-ssm.sh` (28 cases) — TC-LCS-001..011 cover the SSM driver in isolation with stubbed `aws`.
- `tests/unit/test-lib-ssm.sh` (26 cases) — TC-LSSM-001..006 cover the shared SSM helpers extracted from `dispatch-remote-aws-ssm.sh`.

**Cross-reference**: [`docs/pipeline/remote-backend.md`](remote-backend.md) for the full backend-interface contract.

## INV-31: Operator-tunable per-CLI flags live in conf, not in `lib-agent.sh`

_Triage (issue #236): [machine-checked: tests/unit/test-lib-agent-extra-args.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-lib-auth-gh-symlink.sh, tests/unit/test-dev-skill-bash-scripts-gh.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-autonomous-review-auto-merge-failure.sh, tests/unit/test-autonomous-dev-rebase-marker.sh]_

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

**`merge_closes_issue` cross-seam coupling ([M4], #282 — the provider-seam
generalization)**: the "rely on GitHub's link semantics" rule above is a
**code-host capability**, not a universal truth. It is declared as the CHP
`merge_closes_issue` capability ([`provider-spec.md`](provider-spec.md) §4.2):

- **`merge_closes_issue=1` (GitHub, today):** merging a PR whose body carries
  the `Closes #N` keyword auto-transitions the linked issue to its terminal
  state as a side effect of `chp_merge`. The wrapper therefore MUST NOT call
  `itp_transition_state` (the provider-neutral state move) — nor `gh issue
  close` — after the merge. This is exactly the INV-33 rule, now stated
  cross-seam: the CHP merge performs the ITP terminal transition implicitly.
- **`merge_closes_issue=0` (a backend with no merge→issue side-effect):** the
  caller MUST transition the issue to its terminal state after `chp_merge`, or the
  issue never reaches it. **Wired live in #282**: the review wrapper's merge
  success path branches on `chp_caps merge_closes_issue` and, when it is not `1`,
  transitions the issue with a **provider-correct 3-way** (review rounds 6-7):
  1. **`itp_transition_state` defined** → use it (provider-neutral; guarded on
     `declare -F` so it engages automatically once the downstream **itp-writes**
     issue migrates that verb and wires the ITP seam into the review wrapper — a
     blind call to the bodyless shim would abort under `set -e`);
  2. **verb absent AND `ISSUE_PROVIDER=github`** → `gh issue close … --reason
     completed` (the GitHub-rendered terminal transition, correct ONLY because the
     tracker IS GitHub — `itp_transition_state` is named in #282's Out-of-Scope as
     itp-writes' work);
  3. **verb absent AND a NON-GitHub tracker** → a loud `ERROR` log, leaving the
     transition to the operator / the downstream verb — a GitHub `gh issue close`
     would be *wrong* on a non-GitHub tracker, so it is never issued there.

  The `gh issue close` (branch 2) is the SINGLE sanctioned close in the wrapper —
  the #145 regression (an *unconditional* close, and any close on the
  auto-merge-FAILURE path) stays forbidden (`test-autonomous-review-auto-merge-failure.sh`
  TC-AMF-006). On the dev side, the `chp_close_keyword` rendering ([M4]) returns,
  for a `merge_closes_issue=0` backend, a **non-closing** PR-body reference so the
  PR stays discoverable: `Related to #N` when `native_issue_pr_link=0` (body-grep
  discovery), empty when `native_issue_pr_link=1` (native link) — never a
  `Closes #N`. GitHub is `merge_closes_issue=1`, so it renders `Closes #N` and both
  the transition (branch 2 unreached — GitHub auto-closes) and PR-discovery are
  unaffected (zero behavior change).

For the GitHub reference backend this is **zero behavior change** — `chp_merge`
is the same `gh pr merge` leaf and the wrapper still performs no post-merge
transition; the capability merely documents *why* the rule holds so the
GitLab/Asana provider PRs do not re-cut it.

**Producer**: `skills/autonomous-dispatcher/scripts/autonomous-review.sh`
verdict-PASS branch (the auto-merge sub-branch); the merge leaf routes through
`chp_merge` ([INV-87], #282).

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
- [INV-87](#inv-87-provider-dispatch-is-spec-defined--callers-route-every-issuecode-host-op-through-itp_chp_-never-a-raw-gh-in-the-caller-layer)
  + [`provider-spec.md`](provider-spec.md) §4.2 — the `merge_closes_issue`
  capability that generalizes this "GitHub auto-closes on merge" rule across the
  CHP seam; the merge leaf is the `chp_merge` verb (#282).
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

_Triage (issue #236): [machine-checked: tests/unit/test-lib-agent-prompt-stdin.sh]_

> **Implemented in `adapters/<cli>.sh`** ([INV-75](#inv-75-all-per-cli-behavior-lives-in-that-clis-adapter--inline-cli-conditionals-in-orchestration-code-are-a-defect), #232): each `adapter_invoke_<cli>` feeds the prompt on stdin. The one carve-out — codex `review`'s positional `[PROMPT]` (Clause A2) — lives in `adapters/codex.sh::_run_codex_review`.

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

_Triage (issue #236): [machine-checked: tests/unit/test-handle-completed-session-routing.sh, tests/unit/test-classify-recent-review-verdict.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-lib-agent-agy.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-wrapper-rebind-order.sh, tests/unit/test-lib-agent-per-side-cmd.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-lib-agent-per-side-launcher.sh, tests/unit/test-wrapper-rebind-order.sh]_

> **Launcher tokenization/gating stays CLI-agnostic in `lib-agent.sh`** ([INV-75](#inv-75-all-per-cli-behavior-lives-in-that-clis-adapter--inline-cli-conditionals-in-orchestration-code-are-a-defect), #232): the per-side `*_LAUNCHER` → `AGENT_LAUNCHER_ARGV` tokenization + the claude-only guard remain in `lib-agent.sh` (they are config, not per-CLI argv). The claude adapter (`adapters/claude.sh`) reads `AGENT_LAUNCHER_ARGV` to choose its direct-vs-launcher invocation path; `_agent_launch_binary` consults `adapter_binary_<cli>` (the kiro → kiro-cli alias) instead of an inline case.

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

_Triage (issue #236): [machine-checked: tests/unit/test-check-deps-resolved.sh]_

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

**Token used for the lookup** (see [INV-83](#inv-83-cross-repo-dependency-lookups-use-a-per-dep-repo-scoped-read-token-the-app-must-be-installed-on-the-dep-repo)): the cross-repo arm resolves state via `resolve_dep_state` → the `itp_resolve_dep` verb (since #284 the leaf + the scoped-token mint live in `providers/itp-github.sh::itp_github_resolve_dep`), which in app mode mints a token scoped to the **target** dep repo. The ambient dispatcher token is scoped to the **dispatching** repo only and 404s on any other repo — pre-#269 that 404 fell straight into this fail-safe block, silently silencing any issue with a cross-repo dependency forever (#269). The cross-repo `owner/repo#N` shorthand is recognized only when the ITP provider declares `cross_ref_shorthand=1` (GitHub; #284). The App MUST be installed on the dep repo; otherwise the dependency is genuinely unresolvable and the block is correct (now surfaced via a sharpened WARNING + a once-per-issue-per-ref comment).

**Status**: **ENFORCED** in #157's fix. The function uses `grep -E '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]'` to filter the `## Dependencies` section to list items, then bash regex `(^|[[:space:]\(])([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+)` followed by `(^|[[:space:]\(])#([0-9]+)` for stage-2 extraction with a match-and-strip loop. Empty-state lookups emit a `[check_deps_resolved] WARNING: lookup failed for ...` line on stderr and return 1.

**Test**: `tests/unit/test-check-deps-resolved.sh` covers cross-repo CLOSED/MERGED/OPEN, same-repo + cross-repo mixed, prose-embedded refs (must not block), blockquote refs (must not block), URL-fragment refs (must not block), and lookup-failure warning (cross-repo ref to a non-existent repo blocks AND prints the warning). The mock `gh` keys state lookups on `<repo>:<num>` so the same number resolves to different states in different repos.

**Cross-references**:
- [INV-11](#inv-11-dependency-state-includes-merged) — `state ∉ {CLOSED, MERGED}` rule applies to both same-repo and cross-repo refs.
- [INV-83](#inv-83-cross-repo-dependency-lookups-use-a-per-dep-repo-scoped-read-token-the-app-must-be-installed-on-the-dep-repo) — the cross-repo lookup uses a per-dep-repo scoped read token (the #269 fix). The App must be installed on the dep repo.
- [INV-89](#inv-89-every-machine-marker--agent-and-dispatcher-inv-18inv-39-included--is-posted-only-through-the-declared-marker_channel-the-read-side-capture-regex-branches-on-channel) — the once-per-issue-per-ref dependency-block notice is a machine marker; since #283 `_dep_block_comment` posts it through `itp_post_comment` on the declared `marker_channel` (the BODY, incl. the `<!-- dep-block:<repo>#<num> -->` text, composed caller-side and round-tripped verbatim). The dedup READ over existing comments stays on `itp_list_comments` (#281); only the WRITE moved.
- The `create-issue` skill's `## Dependencies` guidance documents the user-facing parsing rules (`skills/create-issue/SKILL.md`, `skills/create-issue/references/issue-templates.md`).

**App-installation migration note (#269)**: with the per-dep-repo scoped token, a cross-repo dependency `owner/repo-B#N` only resolves if the dispatcher's GitHub App is **installed on `repo-B`** (and, if the App uses "selected repositories", `repo-B` is selected). Operators adding a cross-repo dependency MUST ensure the App's installation covers the target repo — otherwise the dependency stays blocked (now with a sharpened WARNING + an on-issue comment instead of a silent skip). This is a precondition, not a regression: the pre-#269 ambient token could never see `repo-B` either; #269 makes the lookup possible *when the App is installed* and makes the failure visible *when it is not*.

## INV-40: Multi-agent review attribution, unanimous aggregation, and all-unavailable fallback

_Triage (issue #236): [machine-checked: tests/unit/test-autonomous-review-multi-agent.sh, tests/unit/test-autonomous-review-prompt.sh]_

> **Verdict CHANNEL changed by [INV-78](#inv-78-review-verdicts-resolve-from-a-typed-artifact-file-first-comment-scraping-is-an-explicitly-logged-fallback-a-malformed-artifact-is-loud-never-a-silent-absent) (#233), aggregation UNCHANGED.** The per-agent verdict now resolves from a typed artifact FILE first (PASS→pass / FAIL→fail), with comment attribution (sub-rule 1) as a logged fallback. A malformed artifact is treated as `absent` for the vote (adapter-spec Clause V1) — it feeds the SAME unanimous-PASS / timed-out-veto aggregation (sub-rules 2-3) below, which is byte-for-byte unchanged.

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

_Triage (issue #236): [machine-checked: tests/unit/test-autonomous-review-per-agent-model.sh, tests/unit/test-lib-review-codex.sh]_

**Rule**: within the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) multi-agent review fan-out, each agent resolves its OWN model and its OWN extra-args from per-agent override keys, falling back to the shared review values when a per-agent key is unset/empty. The keys extend the flat `AGENT_REVIEW_*` convention with an uppercased agent-name suffix where every character outside `[A-Z0-9]` becomes `_`:

- `AGENT_REVIEW_MODEL_<SUFFIX>` (e.g. `AGENT_REVIEW_MODEL_KIRO="claude-sonnet-4.6"`)
- `AGENT_REVIEW_EXTRA_ARGS_<SUFFIX>` (e.g. `AGENT_REVIEW_EXTRA_ARGS_KIRO="--trust-all-tools"`)

The suffix is computed by `lib-review-resolve.sh::_review_agent_key_suffix <name>` (`agy`→`AGY`, `kiro`→`KIRO`, `claude-code`→`CLAUDE_CODE`).

**Resolution precedence** (per agent, inside its fan-out subshell):

1. **Model** — `_resolve_review_agent_model <name>`: `AGENT_REVIEW_MODEL_<SUFFIX>` (if set AND non-empty) → `AGENT_REVIEW_MODEL` (shared) → the wrapper applies the `sonnet` lib default at the `run_agent` call site (`"${_agent_model:-sonnet}"`). An explicit-empty per-agent key collapses to the shared value (empty == unset, matching `:-` semantics).
2. **Extra-args** — `_resolve_review_agent_extra_args <name>`: `AGENT_REVIEW_EXTRA_ARGS_<SUFFIX>` (if set AND non-empty) → `AGENT_REVIEW_EXTRA_ARGS` (shared) → empty. Tokenized downstream by `lib-agent.sh::_parse_extra_args` (the same `eval` trust model as `AGENT_LAUNCHER`, so quoted multi-token values survive).

**Plumbing note (the resolved value is aliased onto BOTH extra-args vars, #212)**: the agent primitives read *two different* variables for the same concept — `run_agent` (a *fresh* session) tokenizes `AGENT_DEV_EXTRA_ARGS`, while `resume_agent` tokenizes `AGENT_REVIEW_EXTRA_ARGS`. So the wrapper resolves the per-agent review extra-args ONCE (into `_resolved_review_extra_args`) and assigns it to **both** `AGENT_DEV_EXTRA_ARGS` **and** `AGENT_REVIEW_EXTRA_ARGS` **inside the subshell**, so the per-agent override reaches whichever launch path the CLI takes. The codex review lane reads `AGENT_DEV_EXTRA_ARGS` via `lib-review-codex.sh::_codex_review_argv` ([INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback)) — so the per-agent `AGENT_REVIEW_EXTRA_ARGS_CODEX` override reaches `codex review`'s argv and #212 stays fixed. **As of [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) no review CLI resumes** (the codex lane moved from `codex exec` + resume to the natively-multi-step `codex review` subcommand, which has no resume), so the `AGENT_REVIEW_EXTRA_ARGS` alias is no longer load-bearing for any current path — it is kept as belt-and-suspenders for any future `resume_agent` caller. Historically (pre-#218) the review fan-out resumed in exactly one case — the codex lane's gather-only turns routed through the now-deleted `_run_codex_review_with_resume` → `resume_agent` (`codex exec resume`, [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn)) — and aliasing onto `AGENT_DEV_EXTRA_ARGS` *alone* (the pre-#212 behavior) dropped the override on that resume (codex inherited e.g. kiro's `--trust-all-tools`, which `codex exec resume` rejects with exit 2, dropping codex `unavailable` every review); #218 makes that failure mode structurally impossible by removing the resume. (This is scoped to the **review fan-out**; the dev-resume caller `autonomous-dev.sh` is a separate path.) The operator-facing surface is still the review knobs (`AGENT_REVIEW_EXTRA_ARGS[_<AGENT>]`); both assignments are internal implementation details scoped to the subshell and never leak to the dev side or to a sibling agent (the `AGENT_REVIEW_EXTRA_ARGS` write happens inside the per-agent `( … )` subshell, so the parent fan-out loop's value is untouched).

**Scope**: per-subshell only. The resolution happens inside the existing fan-out subshell (which already overrides `AGENT_CMD="$agent"` per [INV-37](#inv-37-per-side-agent_cmd-precedence) and neutralizes the launcher per [INV-38](#inv-38-per-side-agent_launcher-precedence)). No change to the dev side, the dispatcher, the `reviewing` label, the single `review-<N>.pid`, or the verdict-attribution / aggregation logic of [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback). The INV-04 Reviewed-HEAD trailer's `model` field continues to render the shared `AGENT_REVIEW_MODEL` (it is a single aggregate forensic trailer per run, not per-agent).

**All-unset / N=1 carve-out (backward compatibility)**: with no `AGENT_REVIEW_MODEL_<AGENT>` / `AGENT_REVIEW_EXTRA_ARGS_<AGENT>` keys set, `_resolve_review_agent_model` returns `$AGENT_REVIEW_MODEL` so the `run_agent` model arg equals the legacy `${AGENT_REVIEW_MODEL:-sonnet}`, and `_resolve_review_agent_extra_args` returns `$AGENT_REVIEW_EXTRA_ARGS`. For an all-default config (`AGENT_REVIEW_MODEL=sonnet`, `AGENT_REVIEW_EXTRA_ARGS=""`) the assembled argv is byte-for-byte today's. The N=1 single-agent path (`AGENT_REVIEW_AGENTS` unset → `REVIEW_AGENTS_LIST=("$AGENT_CMD")`) resolves the same shared values, so it is byte-for-byte legacy.

> **One intentional fix, not a regression**: assigning the resolved *review* extra-args to `AGENT_DEV_EXTRA_ARGS` inside the review subshell means the operator-facing `AGENT_REVIEW_EXTRA_ARGS` now finally takes effect on the review side (previously it was silently ignored — `run_agent` only ever read `AGENT_DEV_EXTRA_ARGS`). A project that had set a non-empty `AGENT_DEV_EXTRA_ARGS` and *relied on it leaking into review* would see review now driven by `AGENT_REVIEW_EXTRA_ARGS` instead. This is the correct, documented behavior; for the default empty config there is no observable change.

> **#212 amendment (codex resume)**: the original wiring aliased the resolved value onto `AGENT_DEV_EXTRA_ARGS` **only** — correct for turn 1, but the codex lane's gather-only **resume** (`resume_agent`, via [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn)) reads `AGENT_REVIEW_EXTRA_ARGS`, so the per-agent `AGENT_REVIEW_EXTRA_ARGS_CODEX` override was dropped on resume and codex inherited the shared value. The fix resolves once and assigns **both** vars. This bug only fired on a project that set a shared `AGENT_REVIEW_EXTRA_ARGS` codex rejects (typically kiro's `--trust-all-tools` on a "dev=kiro, review fleet includes codex" project); a claude-dev project sets no shared review var, so its codex resume read an empty shared value and ran clean — which is why it looked like "codex is flaky on host X but fine on host Y". For an all-default empty config there is no observable change.

**Why**: a multi-CLI review fleet may list CLIs with **mutually incompatible model namespaces** — e.g. kiro wants `claude-sonnet-4.6` (kiro-cli's id) while a claude-family agent wants `sonnet[1m]` (the claude/agy id); kiro rejects `sonnet[1m]` and claude rejects `claude-sonnet-4.6`. A single shared `AGENT_REVIEW_MODEL` forces the operator to pick one id and accept that the other agent fails to launch (→ dropped as unavailable under [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)) or silently ignores it. Per-agent extra-args has the same shape (`--trust-all-tools` for one CLI, `--approval-mode yolo` for another). This was the follow-up explicitly deferred in #166. (`agy` now honors `--model` per [INV-50](#inv-50-agy---model-is-validated-against-agy-models-before-forwarding) — and validates it against `agy models` — so `AGENT_REVIEW_MODEL_AGY` is the key that gives agy a valid *agy-namespace* model while other fleet members keep their own.)

**Producer**: `autonomous-review.sh` — the per-agent resolution inside the fan-out subshell (`_resolve_review_agent_model` / `_resolve_review_agent_extra_args`), and `lib-review-resolve.sh` (the pure resolver helpers).

**Consumer**: `lib-agent.sh::run_agent` (turn 1) tokenizes the resolved extra-args from `AGENT_DEV_EXTRA_ARGS`; `lib-agent.sh::resume_agent` (the codex gather-only resume, [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn)) tokenizes them from `AGENT_REVIEW_EXTRA_ARGS`. The wrapper aliases the single resolved value onto both, so both consumers see the per-agent override (#212). `run_agent` also receives the resolved model as its 3rd positional arg.

**Status**: **ENFORCED** (closes #168; the dual-var extra-args alias added in #212).

**Test**:
- `tests/unit/test-autonomous-review-per-agent-model.sh` — TC-PAM-SUF-01..07 (key-suffix normalization: `agy`/`kiro`/`claude`/`claude-code`/`gpt.4o`/`a b`/mixed-case), TC-PAM-MOD-01..06 + TC-PAM-XA-01..05 (model + extra-args precedence: per-agent wins, other agent keeps shared, explicit-empty falls back, normalized suffix wires the right key), and TC-PAM-SRC-01..07 + TC-PAM-SRC-05pre/05b (source-of-truth greps: wrapper sources `lib-review-resolve.sh`, fan-out resolves per-agent model/extra-args, `run_agent` model arg is the resolved `${_agent_model:-sonnet}` var, resolver result captured once into `_resolved_review_extra_args` and aliased onto **both** `AGENT_DEV_EXTRA_ARGS` AND `AGENT_REVIEW_EXTRA_ARGS`, helper defined, `bash -n`).
- `tests/unit/test-lib-review-codex.sh` — TC-CXR-XA-01..03 + TC-CXR-XA-ISO-01 (#212): the REAL `resume_agent` codex branch carries the per-agent `AGENT_REVIEW_EXTRA_ARGS_CODEX` value on resume (not the shared one), the shared-only case still works, the pre-fix root-cause (per-agent value never reaching `resume_agent`, codex resume carrying the rejected shared `--trust-all-tools`) is pinned, and the `AGENT_REVIEW_EXTRA_ARGS` write does not leak into a sibling subshell or the parent. TC-CXR-XA-SRC-01/02 pin the dual-var alias + removal of the stale "never resumes" claim.
- Backward-compat gate: the full pre-existing review/verdict/launcher regression sweep stays green with all per-agent keys unset.

**Cross-references**:
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the multi-agent fan-out this resolution layers on; the per-subshell override site is the same one INV-40 establishes.
- [INV-37](#inv-37-per-side-agent_cmd-precedence) / [INV-38](#inv-38-per-side-agent_launcher-precedence) — the other per-side / per-subshell overrides the fan-out applies.
- [INV-04](#inv-04-reviewed-head-trailer-format) — the Reviewed-HEAD trailer's `model` field stays the shared value (one aggregate trailer per run).
- [`review-agent-flow.md` § Multi-agent fan-out](review-agent-flow.md#multi-agent-fan-out-inv-40) — runtime walkthrough (per-subshell step documents the resolution).
- [`docs/designs/per-agent-review-model-extra-args.md`](../designs/per-agent-review-model-extra-args.md) — design canvas.
- [INV-42](#inv-42-per-agent-review-launcher-resolution) — per-agent launcher resolution, the third per-agent override axis layered on the same fan-out subshell (#173).

## INV-42: Per-agent review launcher resolution

_Triage (issue #236): [machine-checked: tests/unit/test-autonomous-review-per-agent-launcher.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-review-e2e-command-poll-budget.sh, tests/unit/test-review-cli-exit-grace.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-autonomous-review-mergeable-gate.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-autonomous-dev-pushed-no-pr-resume.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-autonomous-review-sequential-e2e.sh]_

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
- [INV-89](#inv-89-every-machine-marker--agent-and-dispatcher-inv-18inv-39-included--is-posted-only-through-the-declared-marker_channel-the-read-side-capture-regex-branches-on-channel) / [INV-87](#inv-87-provider-dispatch-is-spec-defined--callers-route-every-issuecode-host-op-through-itp_chp_-never-a-raw-gh-in-the-caller-layer) — since #283 the SHA evidence-marker in-place PATCH (`_stamp_browser_evidence_marker`) routes through `itp_edit_comment` (GitHub `edit_comment=1` → the byte-identical `gh api -X PATCH …/issues/comments/<id>`); on an `edit_comment=0` provider the stamp falls back to **re-posting the full report body WITH the marker appended** as a fresh comment via `itp_post_comment` — NOT a marker-only post, because `_fetch_sha_evidence` returns the `last` SHA-marked comment's full body to the dual-signal gate and a marker-only fallback would satisfy the E2E gate with no report/screenshots/AC. The GET-comment-id / GET-body reads stay caller-side; the idempotent SHA-already-present skip and fail-closed return are unchanged.
- [`review-agent-flow.md` § Sequential E2E lane](review-agent-flow.md#sequential-e2e-lane-inv-46) — runtime walkthrough.
- [`docs/designs/sequential-e2e-before-fanout.md`](../designs/sequential-e2e-before-fanout.md) — design canvas.
- [`skills/autonomous-review/references/e2e-command-mode.md`](../../skills/autonomous-review/references/e2e-command-mode.md) — the command-mode contract the wrapper-run lane preserves (this closes the §3 deferral).

## INV-48: Per-side review wall-clock timeout (AGENT_REVIEW_TIMEOUT, 1h default) with browser-E2E exclusion and timeout-veto

_Triage (issue #236): [machine-checked: tests/unit/test-review-agent-timeout.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-autonomous-review-structured-ac.sh]_

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

_Triage (issue #236): [machine-checked: tests/unit/test-lib-agent-agy.sh, tests/unit/test-autonomous-review-per-agent-model.sh]_

> **Implemented in `adapters/agy.sh`** ([INV-75](#inv-75-all-per-cli-behavior-lives-in-that-clis-adapter--inline-cli-conditionals-in-orchestration-code-are-a-defect), #232): `_agy_known_model` / `_agy_build_model_args` moved into the agy adapter (with the rest of agy's per-CLI behavior). The validation stays wrapper-side — never forwarded blindly.

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

The **label-honesty mirror** (#220 — the DISPLAY side of this same drop) is tested in `tests/unit/test-autonomous-review-per-agent-model.sh`: TC-PAML-01..10 (`_resolve_review_agent_model_label`: agy + non-agy resolved id [enumerated-but-unknown] → agy default not the dropped id; valid `AGENT_REVIEW_MODEL_AGY` → verbatim; claude/kiro/codex → verbatim; enumeration-unavailable [rc 2] → generic `agy default` fail-safe; validator-undefined → generic `agy default`; no-model agy → agy default not `sonnet`; case-insensitive agy match; no abort under `set -euo pipefail` command-subst + bare), TC-PAML-FAN-01..03 (`_review_fanout_model_label` renders agy member as the honest default in a divergent fleet; valid agy id verbatim; uniform non-agy fleet unchanged), TC-PAML-SRC-00..03 (source-of-truth: helper defined; verdict-trailer `_agent_model` + `_REVIEW_HEAD_MODEL` + fan-out all route through it). `_agy_known_model` is **stubbed** in every TC-PAML case (deterministic — no `agy models` shell-out). Test plan: `docs/test-cases/agy-model-label-honesty.md`.

**Cross-references**:
- [`docs/pipeline/agy-cli-support.md` § `--model` support](agy-cli-support.md#--model-support-issue-190-inv-50) — full per-CLI spec for the validated pass-through.
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the unanimous-PASS merge gate a wrong-model verdict would corrupt undetected.
- [INV-41](#inv-41-per-agent-review-model--extra-args-resolution) — `AGENT_REVIEW_MODEL_AGY` is the per-agent key that gives agy a valid agy-namespace model in a multi-CLI fleet.
- [INV-36](#inv-36-agy-conversation-id-capture-is-best-effort) — same best-effort degrade-don't-crash philosophy applied to the enumeration-failure path.
- [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) / [INV-60](#inv-60-the-review-model-is-shown-inline-on-every-verdict-comments-review-agent-line) — the model-label / verdict-trailer consumers that **mirror this drop** (#220): for an agy member whose resolved id this invariant drops, the label renders the agy default (`agy default (settings.json)`), never the dropped id, via `lib-review-resolve.sh::_resolve_review_agent_model_label`.

## INV-51: codex review thread auto-resumes until a verdict-posting turn

_Triage (issue #236): [superseded]_

> ⚠️ **SUPERSEDED for the review path by [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) (#218).** The codex review lane no longer runs `codex exec` + a resume loop; it runs the purpose-built `codex review "<prompt>"` subcommand, which is natively multi-step and never strands mid-review. `_run_codex_review_with_resume`, `_codex_log_has_verdict_message`, and `_codex_resume_prompt` are DELETED. This entry is kept for historical context only.

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

**Status**: **SUPERSEDED for the review path by [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) (#218).** The whole `codex exec` + auto-resume machinery this invariant describes — `_run_codex_review_with_resume`, the `_codex_log_has_verdict_message` JSONL verdict parser, the `_codex_resume_prompt` fallback, and `CODEX_REVIEW_MAX_RESUMES` — was DELETED when the codex review lane moved to the purpose-built `codex review "<prompt>"` subcommand (natively multi-step, no single-turn budget, so no resume loop is needed). The recurring bug class this loop tried to patch (#198 / #209 / #212) is moot for the review path because the machinery is gone. The text below is retained for historical context only; no code path references it.

Historical record (pre-#218): **ENFORCED** (closed #189). **Amended by [INV-53](#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message) (#198)**: the
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
- [`review-agent-flow.md` § codex review subcommand (INV-62)](review-agent-flow.md#codex-review-subcommand-inv-62) — runtime walkthrough (the `codex review` lane that REPLACED this resume loop; the original auto-resume walkthrough was retired with the machinery).
- [`docs/designs/codex-review-resume-loop.md`](../designs/codex-review-resume-loop.md) — design canvas.
- [INV-53](#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message) — the corrected convergence contract (#198).

## INV-52: the review WRAPPER owns the GitHub-native PR review/merge action; the agent posts verdicts only

_Triage (issue #236): [machine-checked: tests/unit/test-autonomous-review-request-changes.sh]_

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

_Triage (issue #236): [superseded]_

> **Further demoted by [INV-78](#inv-78-review-verdicts-resolve-from-a-typed-artifact-file-first-comment-scraping-is-an-explicitly-logged-fallback-a-malformed-artifact-is-loud-never-a-silent-absent) (#233).** The verdict-trailer convergence concept (and the INV-62 codex stdout classifier it became) now runs only on the comment-fallback path — when a codex review produced no verdict artifact. With an artifact present, the typed file is the verdict; no trailer/stdout parsing is consulted.

> ⚠️ **SUPERSEDED for the review path by [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) (#218).** This invariant fixed the [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn) JSONL convergence detector (`_codex_log_has_verdict_message`). `codex review` emits no JSONL event stream and needs no convergence loop, so that detector is DELETED. The convergence problem it solved no longer exists — `codex review` is natively multi-step and finishes its own review. The verdict-trailer *concept* lives on as INV-62's stdout classifier (`_codex_review_classify_stdout`) + the authoritative comment poller, not a JSONL parser. This entry is kept for historical context only.

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

**Status**: **SUPERSEDED for the review path by [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) (#218)** — the `_codex_log_has_verdict_message` JSONL convergence detector is deleted with the resume loop; `codex review` is natively multi-step and needs no convergence detection, so the convergence problem this invariant solved no longer exists for the review path. Historical record (pre-#218): **ENFORCED** (closed #198). **Amended (#214)**: the convergence signal also recognized a verdict posted via the [INV-56](#inv-56-review-verdict-is-posted-via-the-deterministic-post-verdict-helper-not-the-agents-bare-gh) helper `post-verdict.sh` (a `command_execution` — signal (B)), not only a verdict-trailer `agent_message`, and `_codex_resume_prompt` stopped instructing codex to hand-write the trailer; that closed an INV-56 gap where codex fired a redundant resume and double-posted the verdict. #218 makes that double-post structurally impossible for the review path by deleting the resume loop entirely.

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
- [INV-56](#inv-56-review-verdict-is-posted-via-the-deterministic-post-verdict-helper-not-the-agents-bare-gh) — the deterministic verdict helper whose `command_execution` signal the #214 amendment taught this detector to recognize (moot for the review path once the detector is deleted by #218).
- [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) — the `codex review` lane that REPLACED this resume loop + its convergence detector for the review path.
- [`review-agent-flow.md` § codex review subcommand (INV-62)](review-agent-flow.md#codex-review-subcommand-inv-62) — runtime walkthrough.
- [`docs/designs/codex-convergence-verdict-detection.md`](../designs/codex-convergence-verdict-detection.md) — design canvas.

## INV-54: the PR-still-open guard gates ALL PASS-chain exits, not just PASS

_Triage (issue #236): [machine-checked: tests/unit/test-autonomous-review-fail-branch-open-guard.sh, tests/unit/test-autonomous-review-e2e-gate-open-guard.sh]_

> **Extended (#195):** the guard now also gates the INV-46 E2E hard-gate block branches (a second application point — see Rule (b) below). The heading is kept for anchor stability; the guard's reach is no longer limited to the PASS chain.

**Rule**: `autonomous-review.sh` MUST re-check PR state before writing a
`reviewing → pending-dev` transition from any wrapper-level block gate, and skip
the `pending-dev` add when the PR is no longer `OPEN`. The check is applied at
**two** points, each delegating to the single pure
`lib-review-mergeable.sh::_pr_open_gate <state>` helper:

- **(a) the `PASSED_VERDICT == true` gate chain** — one hoisted check at the top of the chain, BEFORE the [INV-44](#inv-44-mergeable-hard-gate--a-conflicting-pr-can-never-reach-approved) mergeable poll and BEFORE any block-branch label flip, covering all three PASS-chain exits:
  1. `block-substantive` (PR `CONFLICTING`),
  2. `block-nonsubstantive` (mergeable `UNKNOWN`/empty past the retry budget),
  3. PASS (approve / merge / `no-auto-close`).
- **(b) the [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) E2E hard gate** — one check after `_classify_e2e_gate`, BEFORE the `fail` / `block-nonsubstantive` cascade, covering both E2E block exits. The E2E gate runs *before* the fan-out and is never reached by the `PASSED_VERDICT` chain, so the hoisted check (a) cannot cover it; a second check (b) is required at the gate (#195).

When the PR is no longer `OPEN`, every one of those exits MUST route to a **clean `−reviewing` and `exit 0` with NO `pending-dev` add**. The decision is computed by the pure `lib-review-mergeable.sh::_pr_open_gate <state>` helper:

| `state` (case-insensitive) | gate | wrapper action |
|---|---|---|
| `OPEN` | `proceed` | fall through to the mergeable gate + PASS branch — unchanged |
| `MERGED` / `CLOSED` / `UNKNOWN` / empty / any other token | `skip` | `−reviewing`, `exit 0` — never add `pending-dev` |

Sub-rules:

1. **Conservative classification.** The ONLY value that yields `proceed` is a case-insensitive `OPEN` — the exact inverse of the prior PASS-branch guard's `[[ "$PR_STATE" != "OPEN" ]]` test. A failed `gh pr view --json state` query (the wrapper substitutes the `UNKNOWN` sentinel) → `skip`, matching the prior PASS guard which also treated a failed query as non-OPEN. Fail-closed toward "do not re-queue dev" — when PR state is in doubt we never flip a possibly-merged issue to `pending-dev`.

2. **One query per gate, no duplicate within a gate (DRY).** Check (a) replaces — does not duplicate — the old PASS-branch guard: exactly **one** `gh pr view --json state` call covers all three PASS-chain exits (the redundant second query in the PASS branch was removed). Check (b) adds exactly **one more** `gh pr view --json state` call covering both E2E block exits with a single query (placing it inside each block branch would duplicate the query + skip-exit block — the DRY anti-pattern (a) removed). So the wrapper holds **exactly two** `--json state` queries total — one per gate — and neither gate's block branches re-query.

3. **The E2E-gate check (b) gates the block exits ONLY.** It is wedged after `_classify_e2e_gate` and before the `if [[ "$E2E_GATE" == "fail" ]] … elif … block-nonsubstantive` cascade, and itself runs only when `E2E_GATE ∈ {fail, block-nonsubstantive}`. The gate's `pass`/`inactive` outcomes fall through to the review fan-out before the check is reached, so a merged-mid-E2E PR that nevertheless **passed** E2E is not affected here — it continues to the fan-out and then to the PASS-chain check (a), which guards the approve/merge path. The check costs one `gh` call only on the block paths (an E2E failure or evidence-miss), never on the happy path.

**Why**: the open-check was originally added only to the PASS branch, AFTER the INV-44 mergeable gate. The INV-44 block branches were added later ([#176](https://github.com/zxkane/autonomous-dev-team/issues/176)) and did not inherit it; the INV-46 E2E hard gate ([#182](https://github.com/zxkane/autonomous-dev-team/issues/182)) was added with its own block branches and also did not inherit it. So a PR merged **out-of-band** while a review run was in flight — a manual merge, or the agent self-merge of the #191 incident — that then took a mergeable `block-substantive` / `block-nonsubstantive` path (the #196 half) **or** an E2E `fail` / `block-nonsubstantive` path (the #195 half) had its **already-merged, already-closed** issue flipped to `pending-dev`, which the dispatcher could then try to re-dispatch dev against (degraded: wrong label + needless dev re-dispatch on a merged PR). This is the wrapper-side guard-gap carved out of [#193](https://github.com/zxkane/autonomous-dev-team/issues/193) (which fixed the agent-self-merge root cause). One `_pr_open_gate` helper, applied at both block gates, gives all the `reviewing → pending-dev` block exits identical open-check semantics.

**Scope**: covers the three `PASSED_VERDICT == true` exits (check a, #196) and the two INV-46 E2E hard-gate block exits (check b, #195). The verdict-`FAILED` `else` branch and the auto-merge-failure sub-branch are NOT covered — a FAILED verdict implies the fan-out already ran (the PR was open when the review agents started) and the auto-merge-failure branch only runs after a successful approval on an open PR, so both are far rarer races. A follow-up can extend the same `_pr_open_gate` helper to those paths if a real incident surfaces.

**Producer**: `autonomous-review.sh` — the hoisted open-gate block at the top of the `PASSED_VERDICT == true` chain (check a) AND the E2E-gate open-check wedged between `_classify_e2e_gate` and the block cascade (check b); both call `lib-review-mergeable.sh::_pr_open_gate` (the pure decision helper, defined for #196 and reused for #195).

**Consumer**: the INV-44 mergeable gate's two block branches + the PASS approve/merge branch (reached only when check a is `proceed`), and the INV-46 E2E gate's two block branches (reached only when check b is `proceed`); the dispatcher (no longer sees a merged issue re-flagged `pending-dev` from either gate).

**Status**: **ENFORCED** — check (a) closed #196; check (b) closes #195.

**Test**:
- `tests/unit/test-autonomous-review-fail-branch-open-guard.sh` — check (a): TC-OG-CLS-01..08 (pure decision logic over `_pr_open_gate`: OPEN→proceed, MERGED/CLOSED/UNKNOWN/empty/garbage→skip, case-insensitivity, the "only OPEN proceeds" inverse-of-`!= OPEN` property) and TC-OG-SRC-01..06 (source-of-truth greps: wrapper calls `_pr_open_gate`, the `--json state` query precedes both `_classify_mergeable_gate` and the `MERGEABLE_RETRIES` poll loop, the skip path removes `reviewing` and never adds `pending-dev`, `bash -n`).
- `tests/unit/test-autonomous-review-e2e-gate-open-guard.sh` — check (b): TC-EOG-CLS-01..05 (re-pin `_pr_open_gate` over the merged-mid-E2E states), TC-EOG-SRC-01..07 (the E2E-gate `--json state` query feeds `_pr_open_gate`, sits after `_classify_e2e_gate` and before the cascade, the skip path removes `reviewing` without `pending-dev`, **exactly two** `--json state` queries exist total, `bash -n`), and TC-EOG-REG-01..04 (OPEN-path regression pins: both E2E block branches still write `−reviewing +pending-dev`, the `fail` branch keeps `submit_request_changes` + `failed-substantive`, the `block-nonsubstantive` branch keeps `e2e-evidence-missing` + no request-changes, `emit_verdict_trailer` count unchanged at 10).

The mergeable-gate (`test-autonomous-review-mergeable-gate.sh`) and sequential-E2E (`test-autonomous-review-sequential-e2e.sh`) pins stay green — both checks sit ahead of / outside the existing branches and leave them byte-for-byte unchanged on the OPEN path.

**Cross-references**:
- [INV-44](#inv-44-mergeable-hard-gate--a-conflicting-pr-can-never-reach-approved) — the mergeable gate whose two block branches sit downstream of the hoisted open-check (a).
- [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) — the E2E hard gate whose two block branches sit downstream of the E2E-gate open-check (b).
- [INV-33](#inv-33-review-wrapper-must-not-close-the-linked-issue) — the wrapper never closes the issue; both open-gate skip paths likewise only remove `reviewing`.
- [`review-agent-flow.md` § PR-open guard (INV-54)](review-agent-flow.md#pr-open-guard-inv-54) — runtime walkthrough (both checks).
- [`state-machine.md` § Transition table](state-machine.md#transition-table) — the open-gate `reviewing → (−reviewing)` clean-exit rows for the PASS-chain (a) and the E2E gate (b).
- [`docs/designs/review-fail-branch-open-guard.md`](../designs/review-fail-branch-open-guard.md) — design canvas for check (a, #196).
- [`docs/designs/e2e-gate-open-guard.md`](../designs/e2e-gate-open-guard.md) — design canvas for check (b, #195).

## INV-55: the codex review lane receives the PR diff INLINE in its prompt

_Triage (issue #236): [superseded]_

> ⚠️ **SUPERSEDED by [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) (#218).** The inline-diff was a workaround for `codex exec`'s single-turn budget. `codex review` fetches and re-reads its own auto-scoped diff across multiple steps, so there is nothing to inline — and `[PROMPT]` is mutually exclusive with `--base`/`--commit` anyway. The inline-diff prompt block (`gh pr diff` fetch, nonce'd `DIFF_START`/`DIFF_END` markers, the `CODEX_REVIEW_INLINE_DIFF_MAX_BYTES` cap, the self-fetch fallback) is DELETED from the codex branch of `build_review_prompt`; no other agent used it (it was codex-only), so INV-55 is fully retired. This entry is kept for historical context only.

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

**Status**: **SUPERSEDED by [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) (#218)** — the inline-diff block is deleted; `codex review` fetches its own auto-scoped diff. Historical record (pre-#218): **ENFORCED** (closed #198 follow-up). Complemented
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
- [`review-agent-flow.md` § codex review subcommand (INV-62)](review-agent-flow.md#codex-review-subcommand-inv-62) — runtime walkthrough (the `codex review` lane that REPLACED this resume loop; the original auto-resume walkthrough was retired with the machinery).
- [`docs/designs/codex-inline-diff-review-prompt.md`](../designs/codex-inline-diff-review-prompt.md) — design canvas.

## INV-56: review verdict is posted via the deterministic post-verdict helper, not the agent's bare gh

_Triage (issue #236): [machine-checked: tests/unit/test-post-verdict.sh, tests/unit/test-autonomous-review-verdict-via-helper.sh]_

**Rule**: a review agent's verdict comment MUST be posted through the deterministic,
wrapper-provided helper `scripts/post-verdict.sh`, NOT through a hand-rolled bare
`gh issue comment`. `autonomous-review.sh::build_review_prompt` instructs **every**
review agent (claude/codex/agy/kiro/gemini/opencode — no per-CLI branch for the
verdict post) to post via `bash scripts/post-verdict.sh <issue> <pass|fail>
<body-file> <agent-name> <session-id>`, and explicitly forbids a bare
`gh issue comment` for the verdict. The instruction appears at all THREE verdict-post
spots in the prompt: the Decision block PASS branch, the Decision block FAIL branch,
and the [INV-55](#inv-55-the-codex-review-lane-receives-the-pr-diff-inline-in-its-prompt)
codex-inline-diff block (whose "post your verdict in THIS turn" / "post the verdict in
as few turns as possible" language defers to the same helper).

The helper:
- takes the body from a **FILE** (or stdin via `-`), not an argv string, so a
  multi-line findings body with backticks/quotes/`$()` cannot be mangled by the
  agent's shell quoting;
- guarantees the first-line phrasing the comment poller matches — `Review PASSED`
  for `pass`, `Review findings:` for `fail` (`lib-review-poll.sh::_classify_verdict_body`)
  — prepending the canonical prefix when the agent's body omits it;
- composes the **AGENT verdict trailer** itself — the two load-bearing lines
  `` Review Session: `<session-id>` `` and `Review Agent: <agent-name>`
  ([INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) /
  [INV-20](#inv-20-verdict-authenticity-binding-actor--window--trailer-presence)) — so the agent
  never hand-writes the trailer (this also closes the session-id-rebind hazard where a
  stale session id could be carried). **This is the AGENT verdict trailer, NOT
  `lib-review-verdict.sh::emit_verdict_trailer`** (the wrapper's machine-readable
  `<!-- review-verdict: … -->` marker — a different trailer; the two are not
  interchangeable);
- posts via the token-refresh proxy `gh` co-located in the dispatcher `scripts/` dir
  (the same `gh-with-token-refresh.sh` symlink `mark-issue-checkbox.sh` uses), NOT bare
  gh — this guarantees the correct bot identity + real-gh resolution. **The proxy's
  absence is a LOUD failure, never a fallback to bare PATH `gh`**: bare `gh` would
  resolve to the host operator's `gh auth` session and mis-attribute the verdict to the
  wrong identity (the exact path this helper forbids), so a missing/non-executable
  `${SCRIPT_DIR}/gh` exits non-zero with a "re-run install-project-hooks.sh" message
  instead of posting;
- **fails loudly**: non-zero exit when the post fails (`gh` non-zero) or the proxy is
  absent, exit `2` on invalid args, and echoes the created comment URL on success.

**Why**: each CLI previously hand-rolled its own bare `gh issue comment` for the
verdict. This is unreliable across CLIs: the `agy` review agent **exited 0 claiming it
posted the verdict, but the comment never landed** — so the wrapper's verdict poller
([INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback))
found nothing and dropped agy `unavailable` on **every** multi-agent review. Verified
on the #193 review: in the SAME agy run that was dropped `unavailable`, agy's
`bash scripts/mark-issue-checkbox.sh` calls (a deterministic helper using `gh api` via
the token-refresh wrapper) **landed** (12/12 acceptance-criteria checkboxes checked),
while agy's OWN multi-line `gh issue comment --body "…"` for the verdict **never
landed** — same agent, same token, same PATH, same run. So when agy goes through a
deterministic project helper the gh op succeeds; only its hand-rolled
`gh issue comment` (a multi-line `--body` it mis-forms / mis-escapes) fails. Routing
the verdict through a helper that takes structured args + a body file and forms the
`gh` call itself sidesteps exactly that — the same proven pattern that already makes
agy's `mark-issue-checkbox.sh` calls land.

**The fix is RELIABLE POSTING, not an exit-code signal.** `unavailable` is decided by
the wrapper's verdict poller on comment-absence
(`lib-review-poll.sh` / `lib-review-aggregate.sh::_classify_noverdict_agent`); the
agent's exit code is NOT consulted for that decision (`_classify_noverdict_agent` only
splits rc `124`/`137` → `timed-out` vs everything-else → `unavailable`, and only for an
agent that already posted no verdict). The helper's non-zero-on-failure exit is good
hygiene and the future hook a follow-up wrapper-side change would consume, but it does
NOT, by itself, change today's verdict — reliable posting does.

**Producer**: `scripts/post-verdict.sh` (composes the body + trailer, posts via the
proxy `gh`) and `build_review_prompt` (routes all three verdict-post spots through it).
**Consumer**: the wrapper's authoritative verdict comment poller
([INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) /
[INV-20](#inv-20-verdict-authenticity-binding-actor--window--trailer-presence)) — unchanged; it
now finds a reliably-posted, correctly-trailered comment.

**Scope**: the verdict comment ONLY. Other gh calls the prompt mentions (mergeability
`gh pr view --json`, `gh pr checks`, the Step-0 rebase) are out of scope and keep using
bare/wrapper gh. `mark-issue-checkbox.sh` is already a helper and is unchanged. The
wrapper-side "agent exited 0 but posted no verdict → re-runnable vs unavailable"
detection is a deliberate FOLLOW-UP, not part of this invariant.

**Status**: **ENFORCED** (closes #202).

**Test**: `tests/unit/test-post-verdict.sh` — TC-PV-01..16 (trailer composition;
first-line `Review PASSED`/`Review findings:` guarantee incl. no-double-prefix;
non-zero exit on `gh` failure + URL echo on success; FILE and stdin bodies; multi-line
body with backticks/quotes/`$()` preserved verbatim; arg validation exit `2`;
case-insensitive verdict; posts via the proxy `gh issue comment … --repo …`;
**TC-PV-16: missing co-located proxy → loud non-zero failure with NO bare-PATH-`gh`
fallback** — codex review finding on PR #203).
`tests/unit/test-autonomous-review-verdict-via-helper.sh` — TC-PVP-01..06 (all three
verdict-post spots reference `scripts/post-verdict.sh`; bare `gh issue comment`
forbidden for the verdict; first-line phrasing preserved; no per-CLI branch — rendered
identically for codex and a non-codex agent). Test plan:
`docs/test-cases/post-verdict-helper.md`.

**Post-install / upgrade**: this PR **adds** `scripts/post-verdict.sh`. After merge +
`npx skills update -g`, re-run `install-project-hooks.sh` on every onboarded project
(CLAUDE.local.md → Post-merge Step 2) or their review wrappers will instruct agents to
call a `scripts/post-verdict.sh` symlink that doesn't exist yet.

**Cross-references**:
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the verdict poller / `unavailable` fallback this un-drops agy from, and the `Review Agent:` discriminator the helper writes.
- [INV-20](#inv-20-verdict-authenticity-binding-actor--window--trailer-presence) — the actor+window+`Review Session` trailer-presence binding the helper's trailer satisfies.
- [INV-55](#inv-55-the-codex-review-lane-receives-the-pr-diff-inline-in-its-prompt) — the codex-inline-diff block whose verdict-post language now defers to this helper.
- [`review-agent-flow.md` § Verdict posting (INV-56)](review-agent-flow.md#verdict-posting-inv-56) — runtime walkthrough.
- [`docs/designs/post-verdict-helper.md`](../designs/post-verdict-helper.md) — design canvas.

## INV-57: dev-resume must not short-circuit on a standing APPROVAL when newer review findings exist

_Triage (issue #236): [machine-checked: tests/unit/test-dev-resume-post-approval-findings.sh, tests/unit/test-resume-review-comments-filter.sh]_

**Rule**: on `dev-resume`, the done/not-done decision is governed by **approval-timestamp vs
findings-timestamp ordering**, NOT by the standing `reviewDecision` alone. A PR whose current state is
`reviewDecision == APPROVED` + green CI + mergeable is "nothing outstanding" **only** when there is no
review-findings / change-request comment on the issue *newer than* the latest APPROVED review's
`submittedAt`. When a findings comment post-dates the approval (or there is no approval at all), the resume
MUST address it and MUST NOT post a "Resume check — nothing outstanding to address" comment and exit.

Two layers enforce this:

1. **Wrapper-side override** (`autonomous-dev.sh::emit_post_approval_findings_block <issue> <pr>`): reads the
   latest APPROVED review `submittedAt` (`gh pr view --json reviews`) and the newest findings comment
   `createdAt` (`gh issue view --json comments`), and emits an `## Outstanding post-approval review findings`
   prompt block iff a findings comment exists AND (no approval OR findings newer than approval). The block is
   interpolated into the resume and resume-fallback prompt builders (alongside `OPEN_PR_FAST_PATH` and the
   auto-merge-failure rebase block). It is **FAIL-CLOSED — and a query FAILURE is distinguished from a
   successful "no approval" result**: each `gh` query's exit status is checked separately (`if ! var=$(gh …)`),
   so a transient/permission/API failure of the **approval** query returns 0 with no block rather than being
   mistaken for "no approval" (which would emit). Only an empty result from a query that *succeeded* is treated
   as "no approval". The always-present `## Review Feedback` section still carries the findings — the override
   never *fabricates* work, it only ADDS a do-not-short-circuit signal when it can POSITIVELY prove findings
   post-date the approval (or positively prove there is no approval).
   [INV-06](#inv-06-crashed--process-not-found-keyword-contract) keyword contract: the block is
   forward-progress prompt text, not a status comment, and contains none of the crash keywords.
2. **Narrowed findings recognition** (the `REVIEW_COMMENTS` selector AND the helper): findings are matched
   by the `Review findings` prefix OR a `BLOCKING` / `[P1]` token — NOT the exact `Review findings:` prefix
   alone, so a late/independent findings comment (a heading `## Codex review findings`, or a bare operator note
   `[P1] BLOCKING: …`) is actionable. Two guards keep the token clause from over-matching:
   - The `BLOCKING` token is anchored `(^|[^A-Za-z-])BLOCKING\b` so the review vocabulary's `NON-BLOCKING`
     token (the hyphen is a `\b` boundary) does NOT false-match — otherwise a "remaining items are
     NON-BLOCKING, safe to merge" note would falsely trigger the override. **This MUST be a *consuming*
     leading group, NOT a look-behind** (`(?<![A-Za-z-])`): `gh --jq` runs Go's RE2 engine, which has no
     look-behind and **rejects** `(?<!` at runtime (`invalid regular expression … invalid named capture`).
     A look-behind form makes the findings query exit non-zero — the override silently never fires, and the
     unprotected `REVIEW_COMMENTS=$(gh …)` assignment aborts the wrapper under `set -euo pipefail` before the
     agent runs (issue #188 review round 2: kiro). Tests that stub `gh` via the system `jq` binary (jq
     1.6+/Oniguruma, which DOES support look-behind) cannot catch this engine mismatch — see the dedicated
     RE2-compatibility test below.
   - The token-bearing comment is matched ONLY when its first line is NOT a known **non-findings shape**:
     `Review PASSED` / `Review APPROVED` verdicts, a `## ✅` status heading, `**Agent Session Report`, the
     `Multi-agent review:` / `Reviewed HEAD:` / `<!-- … -->` review-wrapper markers, and the
     `Dispatching`/`Resuming`/`Moving to` dispatcher chatter. Without that exclusion the token clause
     false-matched a `Review PASSED - No BLOCKING issues remain` verdict and dev status/session comments that
     mention `BLOCKING`/`[P1]` in prose (this issue's own `## ✅ Implementation complete` comment does) —
     misclassifying a status report as a change-request and re-opening a genuinely-done approved PR, violating
     the no-regression criterion (issue #188 review finding 2). A `Review PASSED` comment is therefore NEVER a
     finding; the selector still matches it via its own dedicated prefix clause so the resume keeps the latest
     PASS as feedback context.

**Why**: observed on a feature issue whose review fleet approved the PR (APPROVED + mergeable, stopped before
merge under `no-auto-close`); an operator then posted a new `Review findings:` comment with BLOCKING (P1)
items and moved the issue back to `pending-dev`. The resumed dev agent posted "Resume check — nothing
outstanding to address" citing review = APPROVED, CI = green, PR = MERGEABLE, and exited with no code
changes — the standing APPROVED `reviewDecision` short-circuited the resume before the late findings were
acted on, so data-correctness P1s reached the awaiting-merge state looking clean. The exact-`Review findings:`
match compounded it: a findings comment without that literal prefix was invisible to the resume prompt.

**Relationship to [INV-52](#inv-52-the-review-wrapper-owns-the-github-native-pr-reviewmerge-action-the-agent-posts-verdicts-only)**:
INV-52 makes the review **wrapper** submit `--request-changes` on a substantive FAIL, so a wrapper-driven
FAIL flips `reviewDecision` to `CHANGES_REQUESTED` and the standing-APPROVAL trap does not arise. INV-57
covers the **human-in-the-loop / out-of-band** path: a findings comment posted *after* an approval by an
operator or an independent review, with no accompanying wrapper `--request-changes`, leaving a stale
`APPROVED` `reviewDecision`. INV-57 keys on the **comment timestamp**, not on `reviewDecision`, so it is robust
to that gap. Auto-dismissing the stale GitHub approval is intentionally **out of scope** (the issue listed it
as optional) — the override block + broadened recognition already satisfy the acceptance criteria, and the
review wrapper remains the sole owner of the GitHub-native PR action (INV-52).

**Producer**: `emit_post_approval_findings_block` (the override) and the `REVIEW_COMMENTS` selector (both share
the same prefix-or-narrowed-token findings predicate).
**Consumer**: the resumed dev agent's done/not-done decision, governed by
[`autonomous-mode.md` § Resume Awareness](../../skills/autonomous-dev/references/autonomous-mode.md).

**Status**: **ENFORCED** (closes #188).

**Test**: `tests/unit/test-dev-resume-post-approval-findings.sh` — TC-PAF-001..013 (helper: findings newer
than approval → emit; approval newer → no emit; no findings → no emit; no approval + findings → emit;
non-prefix `[P1]` findings → emit; all-`gh`-fail → fail-closed + returns 0; newer `Review PASSED` → no emit;
operator `[P1] BLOCKING` note → emit; newer `NON-BLOCKING` note → no emit; **approval-query-only failure →
fail-closed, NOT treated as no-approval (review finding 1)**; **`Review PASSED - No BLOCKING issues remain`
verdict → no emit**, **dev impl/status comment with tokens in prose → no emit**, **Agent Session Report with
tokens → no emit (review finding 2)**), TC-PAF-W01..W04 (helper defined, output interpolated into a prompt
builder, block content names post-approval findings + do-not-exit + stale-APPROVED, `bash -n`),
TC-PAF-D01..D03 (doc contract). Selector regression: `tests/unit/test-resume-review-comments-filter.sh`
TC-RFB-009..016 (the token clause recognizes non-prefix findings, rejects `NON-BLOCKING`, excludes PASS
verdicts + dev status/session comments that mention the tokens, and does not re-introduce the #113
dispatcher-chatter false positives) + TC-RFB-017 (the exclusion alternation stays byte-identical across the
two single-line selectors); TC-RFB-001..008 stay green. **Engine-compatibility regression**:
`tests/unit/test-resume-selector-re2-compat.sh` — TC-RE2-01..03 (STATIC, network-free, CI-enforced: the
resume `-q` selectors contain NO RE2-incompatible look-behind/look-ahead and DO carry the consuming
`(^|[^A-Za-z-])BLOCKING` anchor) + TC-RE2-04..07 (best-effort: feed the actual token regex through the REAL
`gh --jq` Go RE2 engine — compiles, `[P1] BLOCKING`/`[BLOCKING]` match, `NON-BLOCKING` does not — skipped when
`gh`/token/network is absent). This guards the stub-vs-runtime engine gap that hid review round 2's
look-behind bug. Test plan:
`docs/test-cases/dev-resume-post-approval-findings.md`.

**Cross-references**:
- [INV-52](#inv-52-the-review-wrapper-owns-the-github-native-pr-reviewmerge-action-the-agent-posts-verdicts-only) — the wrapper-driven FAIL path that does flip `reviewDecision`; INV-57 covers the out-of-band path it doesn't.
- [INV-45](#inv-45-pushed-branch-with-commits-ahead--no-pr--resume-to-open-pr-only-never-full-re-dev) — a sibling wrapper-side resume prompt block (`emit_open_pr_fast_path_block`), same fail-closed + [INV-06] discipline.
- The #113 fix (`tests/unit/test-resume-review-comments-filter.sh`) — the dispatcher-chatter exclusion the broadened selector preserves.
- [`dev-agent-flow.md` § Mode = resume](dev-agent-flow.md#mode--resume) — runtime walkthrough.

## INV-58: agy quota/auth `unavailable` drops surface a distinct reason; fan-out + Reviewed-HEAD model labels are per-agent

_Triage (issue #236): [machine-checked: tests/unit/test-lib-review-agy.sh, tests/unit/test-autonomous-review-per-agent-model.sh]_

> **Implemented in `adapters/agy.sh`** ([INV-75](#inv-75-all-per-cli-behavior-lives-in-that-clis-adapter--inline-cli-conditionals-in-orchestration-code-are-a-defect), #232): the `_classify_agy_drop_reason` / `_agy_drop_reason_phrase` scrapers moved from `lib-review-agy.sh` (now a thin compat shim) into the agy adapter.

**Rule**: two related observability fixes to the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) review fan-out, neither of which changes the vote:

1. **agy quota/auth drop-reason detector.** When a fan-out member whose CLI is `agy` is resolved `unavailable` (no verdict within the poll window), the wrapper scrapes that agent's OWN `--log-file` (`pid_dir_for_project()/agy-log-<session_id>.log`, captured per-agent into `AGENT_AGY_LOGS` during fan-out) via `lib-review-agy.sh::_classify_agy_drop_reason <log>` and, if a quota/auth signal is present, attaches a distinct, actionable reason to the `WARNING: review agent(s) dropped (unavailable)` log line AND the posted "dropped agent(s)" issue comment (and the all-unavailable `log` line). Classification:
   - `RESOURCE_EXHAUSTED` / `Individual quota reached` (the HTTP 429 quota wall) → **`quota-exhausted`**, with the `Resets in <dur>` recovery window appended (`quota-exhausted:Resets in 33h48m45s`) when agy printed one;
   - `not logged into Antigravity` / `Failed to get OAuth token` (no quota signal) → **`auth-failed`**;
   - neither → empty token → the bare `unavailable` wording is unchanged.
   Quota takes **precedence** over auth (agy logs the failed-OAuth line as a side effect of the same call that hit the quota wall — both appear in the live repro). `_agy_drop_reason_phrase` renders the token into the human clause posted/logged. The detector is `grep -F` (fixed-substring), single-pass, no `jq` (agy emits no JSON stream — mirrors [INV-36](#inv-36-agy-conversation-id-capture-is-best-effort)), and **fail-safe**: a missing/empty/unreadable/empty-arg log echoes empty and returns 0 (never aborts the `set -euo pipefail` wrapper).

2. **Per-agent model labels.** The `Fanning out …` log line renders each agent's **per-agent RESOLVED** model via `lib-review-resolve.sh::_review_fanout_model_label`: `model: <id>` when uniform, else `models: <agent>=<id>, …`. The [INV-04](#inv-04-reviewed-head-trailer-format) Reviewed-HEAD trailer renders the **representative** (first) fan-out agent's resolved model + CLI name (`_REVIEW_HEAD_MODEL`/`_REVIEW_HEAD_AGENT`), not the shared `${AGENT_REVIEW_MODEL}` / `${AGENT_CMD}`. The INV-04 SHA-anchored parser is unaffected — only the human-attribution metadata changes.

   **agy label honesty (#220).** Both labels render each agent through `lib-review-resolve.sh::_resolve_review_agent_model_label` — the **display-layer** counterpart of `_resolve_review_agent_model` (the launch-arg resolver — [INV-41](#inv-41-per-agent-review-model--extra-args-resolution)) — which **mirrors [INV-50](#inv-50-agy---model-is-validated-against-agy-models-before-forwarding)**: for an `agy` member whose resolved id is NOT an `agy models` id (e.g. the shared `claude-sonnet-4.6` set for kiro, with no `AGENT_REVIEW_MODEL_AGY` key), agy *drops* that `--model` and runs its `settings.json` default — so the label renders **`agy default (settings.json)`** (or the generic **`agy default`** when `_agy_known_model` cannot enumerate / is unavailable), **not** the dropped id. A valid `AGENT_REVIEW_MODEL_AGY` (a known `agy models` id, e.g. `Gemini 3.5 Flash (High)`) is shown verbatim. claude/kiro/codex (which HONOR `--model`) are unchanged — their resolved id IS what ran, shown verbatim. The helper is **fail-safe** (never aborts the `set -euo pipefail` wrapper; degrades to the generic `agy default` rather than asserting a wrong id when enumeration is unavailable or the validator is absent — the resolve-lib-in-isolation unit-test context). Without this, INV-58/INV-60 made the labels show the *resolved* value, but for agy that value is exactly the one INV-50 discards, so the label asserted a model agy never ran.

**Deliberately NOT changed**: a `quota-exhausted` / `auth-failed` agy is STILL dropped from the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) unanimous-PASS aggregation exactly as `unavailable` — it is **observability only**, NOT a deciding FAIL. A quota wall is an infra condition, not a code rejection; promoting it to a veto (like the [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto) `timed-out` veto) would block EVERY merge whenever agy's daily quota is spent, which is worse than degrading to the surviving fleet members. `_classify_noverdict_agent` / `_aggregate_review_verdicts` are untouched.

**Why**: surfaced by #205. On an `agy codex` AND-gate, when agy hit the Antigravity consumer daily quota (429 `RESOURCE_EXHAUSTED`), agy exited **rc 0** with empty stdout/stderr and posted no verdict — so the wrapper dropped it as a bare `unavailable`, indistinguishable from a CLI launch failure or a genuine no-verdict miss, silently degrading the fleet to codex-only with no operator-visible cause. The 429 (and its `Resets in …` window) was present only in agy's separate `--log-file`. Diagnosing it downstream took a multi-step investigation precisely because the reason was hidden. Separately, the `(shared model: sonnet)` fan-out line and the `model \`${AGENT_REVIEW_MODEL}\`` trailer printed the shared default for a per-agent-overridden fleet (`AGENT_REVIEW_MODEL_AGY="Gemini 3.5 Flash (High)"` resolved correctly but was MISreported as `sonnet`), actively misleading the operator into suspecting a model-pin bug. agy's rc-0-for-everything posture is the same root cause [INV-50](#inv-50-agy---model-is-validated-against-agy-models-before-forwarding) records (agy never fails loudly), which is why the signal must be scraped from its log rather than inferred from the exit code.

**Producer**: `lib-review-agy.sh` — `_classify_agy_drop_reason` (log scrape + classify) and `_agy_drop_reason_phrase` (human rendering); `lib-review-resolve.sh::_review_fanout_model_label` (per-agent fan-out label) and `lib-review-resolve.sh::_resolve_review_agent_model_label` (the per-agent honest label that mirrors INV-50's agy drop — #220). `autonomous-review.sh` — captures `AGENT_AGY_LOGS` in the fan-out, builds `_dropped_reasons` in the drop-classification loop, and renders the per-agent fan-out + Reviewed-HEAD labels (the Reviewed-HEAD `_REVIEW_HEAD_MODEL` resolves via `_resolve_review_agent_model_label`).

**Consumer**: the operator reading the wrapper log / the dropped-agent issue comment (the reason + reset window). No consumer change to the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) aggregation, the verdict poller, the E2E gate, or the dispatcher.

**N=1 / non-agy / signal-free carve-out (backward compatibility)**: a non-agy member dropped `unavailable` triggers no agy lookup; an agy member whose log shows neither signal yields an empty token → the bare `unavailable` wording, unchanged. A single-agent fleet whose lone agy hit the quota wall surfaces the reason on the all-unavailable `log` line. The fan-out/trailer labels with no per-agent override resolve to the shared model exactly as before (just rendered through the resolver), so an all-unset config is byte-for-byte equivalent in meaning.

**Status**: **ENFORCED** (closes #205).

**Test**: `tests/unit/test-lib-review-agy.sh` — TC-AGYQ-DET-01..12 (`_classify_agy_drop_reason`: 429+reset → `quota-exhausted:Resets in …`, 429 no-reset → bare, bare phrase, auth-only → `auth-failed`, OAuth-only → `auth-failed`, quota+auth → quota precedence, normal/empty/missing/empty-arg → empty, minutes-seconds shape, committed fixture, no crash under `set -euo pipefail`), TC-AGYQ-PHR-01..04 (`_agy_drop_reason_phrase` rendering + empty passthrough), TC-AGYQ-SRC-01..06 (source-of-truth: wrapper sources the lib, captures `_agy_log_file`, calls the classifier, interpolates the reason, CI shellcheck lists the lib, `bash -n`), TC-AGYQ-MODEL-01..03 (fan-out label derives from the resolver; per-agent override surfaces `Gemini 3.5 Flash (High)` not `sonnet` — with `_agy_known_model` stubbed to treat it as a known agy id per #220; Reviewed-HEAD trailer model is the resolved value), TC-AGYQ-LOOP-01..04 (behavioral: the drop-reason loop yields a distinct reason for a quota log vs. an empty reason for a generic log; non-agy adds nothing), TC-AGYQ-REG-01 (a quota drop is classified distinctly from an opaque/no-verdict drop). The agy label-honesty path itself (#220) is tested in `tests/unit/test-autonomous-review-per-agent-model.sh` — TC-PAML-01..10 + TC-PAML-FAN-01..03 + TC-PAML-SRC-00..03 (see [INV-50](#inv-50-agy---model-is-validated-against-agy-models-before-forwarding) Test). Test plan: `docs/test-cases/agy-quota-detector.md` + `docs/test-cases/agy-model-label-honesty.md`. Backward-compat gate: `test-autonomous-review-multi-agent`, `test-review-agent-timeout`, `test-autonomous-review-per-agent-model`, `test-autonomous-review-verdict-via-helper` stay green.

> **Post-install / upgrade**: this PR ADDS `scripts/lib-review-agy.sh`. After merge + `npx skills update -g`, re-run `install-project-hooks.sh` on every onboarded project (see the project operator's post-merge steps) or the review wrappers will `source` a symlink that doesn't exist yet and crash on startup, stranding the issue in `reviewing`.

**Cross-references**:
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the fan-out + `unavailable` definition this annotates; the aggregation/vote is unchanged (a quota agy stays dropped, not a deciding FAIL).
- [INV-41](#inv-41-per-agent-review-model--extra-args-resolution) — the per-agent model resolution the corrected fan-out/trailer labels now render (vs. the shared default).
- [INV-50](#inv-50-agy---model-is-validated-against-agy-models-before-forwarding) — the SAME agy "rc 0 for everything / never fails loudly" posture; the reason must be scraped from the log, not inferred from the exit code. The label-honesty correction (#220) **mirrors INV-50's drop** into the model label so the displayed value is what agy actually ran, not the dropped id.
- [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn) / [INV-53](#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message) — the analogous codex "ran but no verdict" handling; this is the agy-shaped sibling for a DIFFERENT failure mode (quota, not gather-burn), reading the CLI's own log in a CLI-specific review-side lib.
- [INV-59](#inv-59-codex-transient-stream-error-drops-surface-a-distinct-reason-and-are-ridden-out-by-the-resume-loop-not-opaquely-dropped) — the codex-shaped sibling of THIS detector: the SAME drop-reason assembly loop also enriches a `codex` member dropped on a transient stream 5xx (`turn.failed`).
- [INV-61](#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) — the kiro-shaped sibling of THIS detector: the SAME drop-reason assembly loop also enriches a `kiro` member dropped on an auth/login token expiry.
- [`review-agent-flow.md` § agy quota/auth drop reason (INV-58)](review-agent-flow.md#agy-quotaauth-drop-reason-inv-58) — runtime walkthrough.

## INV-59: codex transient stream-error drops surface a distinct reason and are ridden out by the resume loop, not opaquely dropped

_Triage (issue #236): [machine-checked: tests/unit/test-lib-review-codex.sh]_

> **Implemented in `adapters/codex.sh`** ([INV-75](#inv-75-all-per-cli-behavior-lives-in-that-clis-adapter--inline-cli-conditionals-in-orchestration-code-are-a-defect), #232): the `_codex_review_has_stream_error` / `_classify_codex_drop_reason` / `_codex_drop_reason_phrase` scrapers moved from `lib-review-codex.sh` (now a thin compat shim) into the codex adapter.

> ⚠️ **RE-SCOPED by [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) (#218).** Both halves below are preserved in spirit but re-implemented for the `codex review` subcommand: **(half 1, drop-reason detector)** survives but now scans codex review's human-readable **stdout/stderr capture** for the stream-disconnect / reconnect-ladder signal instead of the `codex exec` JSONL `turn.failed` event (`codex review` emits no JSONL stream). The function names (`_classify_codex_drop_reason`, `_codex_drop_reason_phrase`) and the rc-0-always fail-safe contract are unchanged; `_codex_log_has_stream_error` is renamed `_codex_review_has_stream_error`. **(half 2, transient-retry)** is subsumed by INV-62's bounded **re-run** of `codex review` (a non-zero exit re-runs a fresh review, bounded by `CODEX_REVIEW_MAX_RERUNS` + the `AGENT_REVIEW_TIMEOUT` wall-clock deadline) — there is no resume loop left to "fall through into". The text below describes the pre-#218 `codex exec` implementation; read it as historical.

**Rule**: two related fixes to the [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn) codex review path for a codex model stream that dies with an upstream server error (the CLI exhausts its `5/5` SSE reconnects and emits `{"type":"turn.failed","error":{"message":"stream disconnected before completion: ..."}}`):

1. **codex stream-error drop-reason detector (observability).** When a fan-out member whose CLI is `codex` is resolved `unavailable`, the wrapper scrapes that agent's OWN JSONL event-stream log (`$_agent_log` — the same file `CODEX_REVIEW_LOG` points the resume controller at, captured per-agent into `AGENT_CODEX_LOGS` during fan-out) via `lib-review-codex.sh::_classify_codex_drop_reason <log>` and, if a stream-error signal is present, attaches a distinct, actionable reason to the `WARNING: review agent(s) dropped (unavailable)` log line AND the posted "dropped (unavailable) agent(s)" issue comment (and the all-unavailable `log` line). Classification:
   - a `turn.failed` event whose `error.message` carries `stream disconnected before completion`, OR a `Reconnecting... N/5 (stream disconnected ...)` reconnect-ladder error line → **`stream-error`**, with the highest reconnect-ladder depth appended (`stream-error:5/5`) when the ladder is in the log;
   - a clean `turn.completed` with no verdict (the [INV-53](#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message) / #198 gather-or-narration case) or a verdict turn → empty token → the bare `unavailable` wording is unchanged (**no over-claim**: a no-verdict miss is NOT a stream error).
   `_codex_drop_reason_phrase` renders the token into the human clause posted/logged (`stream-error (upstream 5xx; exhausted 5/5 SSE reconnects, turn.failed)`). The detector keys on the EVENT type scoped to the line shape (`"type":"turn.failed"` / `"type":"error"`), not a bare substring, so a tool-output line that merely contains the literal `turn.failed` (codex grepping its own log) is not a false positive. It is single-pass `awk` + `grep -F`-style fixed matches, no `jq` (mirrors `_codex_log_has_verdict_message`), and **fail-safe**: a missing/empty/unreadable/empty-arg log echoes empty and returns 0 (never aborts the `set -euo pipefail` wrapper).

2. **Transient stream error is retryable, not a permanent early-return.** Pre-#209 `_run_codex_review_with_resume` early-returned on any non-zero, non-`124`/`137` launch rc — so a launch-level `turn.failed` stream error never entered the bounded resume loop, and a *brief* blip permanently cost codex its vote. Now: when turn 1 exits non-zero/non-timeout BUT `_codex_log_has_stream_error` is true on a readable log, the controller does NOT early-return — it falls through into the existing bounded resume loop and issues ANOTHER turn. A **brief** blip is ridden out (the next turn succeeds → codex posts a verdict → its independent vote is kept); a **sustained** outage still degrades gracefully when the loop exhausts `CODEX_REVIEW_MAX_RESUMES` (it never converges) → codex resolved `unavailable` by the post-window sweep with the `stream-error` reason surfaced. A genuine non-stream launch failure (rc ≠ 0, no stream-error signal) still early-returns, unchanged; an unreadable log keeps the conservative early-return.

**Deliberately NOT changed**: a `stream-error` codex is STILL dropped from the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) unanimous-PASS aggregation exactly as `unavailable` — half 1 is **observability only**, NOT a deciding FAIL. A server-side 5xx is an infra condition, not a code rejection; promoting it to a veto (like the [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto) `timed-out` veto) would block every merge whenever the provider blips, which is worse than degrading to the surviving fleet. `_classify_noverdict_agent` / `_aggregate_review_verdicts` are untouched. The retry of half 2 is bounded by the SAME `CODEX_REVIEW_MAX_RESUMES` + `AGENT_REVIEW_TIMEOUT` guards that already cap the gather-burn resume loop, so no new terminal `retryable` state and no dispatcher coordination are introduced (the simpler of the two options the issue offered).

**Why**: surfaced by #209. On an `agy codex` AND-gate (or any codex-bearing fleet), a codex review turn whose model stream hit an upstream 5xx exhausted `5/5` SSE reconnects, emitted `turn.failed`, and was dropped as a bare `unavailable` — the drop-reason assembly only enriched the reason for `agy` (INV-58), so codex's actual failure (a recoverable server-side stream error) was invisible to the operator, indistinguishable from a launch misconfig. And because the launch-level `turn.failed` early-returned from the resume loop, even a *brief* blip permanently cost codex its independent vote (the loop's one-resume gather-burn mitigation never even fired against a stream failure). This is the codex-shaped sibling of [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) for a DIFFERENT failure mode (a transient stream 5xx, not a quota wall), reading the CLI's own log in the same CLI-specific review-side lib.

**Out of scope** (per #209): codex's own SSE reconnect count (`stream_max_retries` — the built-in `amazon-bedrock` provider takes no per-provider retry override); the upstream 5xx itself; drop-reason classifiers for other agents (kiro/claude/gemini/opencode).

**Producer**: `lib-review-codex.sh` — `_codex_log_has_stream_error` (log scan), `_classify_codex_drop_reason` (classify), `_codex_drop_reason_phrase` (human rendering), and the `_run_codex_review_with_resume` early-return fall-through. `autonomous-review.sh` — captures `AGENT_CODEX_LOGS` in the fan-out and builds the codex branch of `_dropped_reasons` in the drop-classification loop.

**Consumer**: the operator reading the wrapper log / the dropped-agent issue comment (the `stream-error` reason). No consumer change to the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) aggregation, the verdict poller, the E2E gate, or the dispatcher.

**N=1 / non-codex / signal-free carve-out (backward compatibility)**: a non-codex member dropped `unavailable` triggers no codex lookup; a codex member whose log shows no stream error (a clean no-verdict miss, or a genuine launch failure) yields an empty token → the bare `unavailable` wording, unchanged. A genuine non-stream launch failure still early-returns from the resume controller exactly as before. `CODEX_REVIEW_MAX_RESUMES=0` still disables the loop entirely (codex behaves as pre-#189, and a stream-error turn 1 then falls through to a loop that immediately hits the `0` bound — a single run, no resumes).

**Status**: **RE-SCOPED by [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) (#218)** — the drop-reason detector now scans the `codex review` stdout capture (not the JSONL log) and the transient-retry half is subsumed by INV-62's bounded re-run. Historical record (pre-#218): **ENFORCED** (closed #209).

**Test**: `tests/unit/test-lib-review-codex.sh` — TC-CODEX-DROP-DET-01..07 (`_codex_log_has_stream_error`: ladder+`turn.failed` → rc 0, clean no-verdict/verdict turn → rc 1, `turn.failed` no-ladder → rc 0, empty/missing/empty-arg → rc 1, tool-output substring not a false positive, committed fixture), TC-CODEX-DROP-CLS-01..08 (`_classify_codex_drop_reason`: ladder → `stream-error:5/5`, no-ladder → bare `stream-error`, no-verdict/verdict → empty, empty/missing/empty-arg → empty, no crash under `set -euo pipefail` (command-subst call), committed fixture, **and TC-CODEX-DROP-CLS-08: a BARE call (not command-subst) under `set -euo pipefail` with a `turn.failed` no-ladder log reaches `return 0` without an errexit abort** — the ladder-extraction pipeline is `|| true`-guarded so its grep-no-match rc 1 under `pipefail` cannot abort the body before the function's load-bearing `return 0`; the sole production caller invokes via command substitution where errexit is suppressed, so the unguarded form was latent, but a future bare call would have crashed. codex review finding on PR #211), TC-CODEX-DROP-PHR-01..03 (`_codex_drop_reason_phrase` rendering + empty passthrough), TC-CODEX-DROP-RETRY-01..03 (resume loop rides out a transient stream error: turn-1 stream-error rc + verdict resume → enters loop & converges; genuine launch failure → early-return, 0 resumes; sustained stream error → bounded), TC-CODEX-DROP-LOOP-01..04 (behavioral: the drop-reason loop yields a distinct reason for a codex stream-error log vs. empty for a generic log; **BOTH agy + codex dropped in one fan-out lists a distinct reason for each**; non-agy/non-codex adds nothing), TC-CODEX-DROP-SRC-01..04 (source-of-truth: wrapper captures `AGENT_CODEX_LOGS`, calls `_classify_codex_drop_reason`, interpolates `_codex_drop_reason_phrase`, `bash -n`), TC-CODEX-DROP-REG-01..02 (a stream-error drop classifies distinctly from a no-verdict drop; a clean no-verdict turn is NOT misreported). Fixture: `tests/unit/fixtures/codex-stream-error-turn.jsonl`. Test plan: `docs/test-cases/codex-stream-error-drop-reason.md`. Backward-compat gate: `test-autonomous-review-multi-agent`, `test-review-agent-timeout`, `test-review-cli-exit-grace` stay green.

> **Post-install / upgrade**: this PR does NOT add a new dispatcher script/`lib-*.sh` — it edits the existing `lib-review-codex.sh` and `autonomous-review.sh`. So the per-project `install-project-hooks.sh` re-run is NOT required after merge; `npx skills update -g` alone refreshes the user-scope copy (the existing per-file symlinks already resolve to the updated content). Only ADDED/REMOVED dispatcher files need the installer re-run.

**Cross-references**:
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the fan-out + `unavailable` definition this annotates; the aggregation/vote is unchanged (a stream-error codex stays dropped, not a deciding FAIL).
- [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn) — the codex resume controller this extends; the retry fall-through and the stream-error detector live in the same `lib-review-codex.sh`.
- [INV-53](#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message) — the verdict-trailer convergence signal; a clean no-verdict turn under INV-53 must NOT be misreported as a stream error (the over-claim guard).
- [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) — the agy-shaped sibling for a DIFFERENT failure mode (quota wall); same drop-reason assembly loop, same CLI-specific review-side-lib layering, same observability-only posture.
- [INV-61](#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) — the kiro-shaped sibling for an auth/login token expiry; same drop-reason assembly loop. (INV-61 has no retry half — kiro fails at launch, not mid-stream.)
- [`review-agent-flow.md` § codex stream-error drop reason + retry (INV-59, re-scoped by INV-62)](review-agent-flow.md#codex-stream-error-drop-reason--retry-inv-59-re-scoped-by-inv-62) — runtime walkthrough.

## INV-60: the review model is shown inline on every verdict comment's `Review Agent:` line

_Triage (issue #236): [machine-checked: tests/unit/test-post-verdict.sh, tests/unit/test-autonomous-review-verdict-via-helper.sh]_

**Rule**: the AGENT verdict trailer that `scripts/post-verdict.sh` appends folds the per-agent **resolved review model** into the existing `Review Agent:` line, inline, as a parenthetical — NOT a new third trailer line:

```
Review Session: `<session-id>`
Review Agent: <name> (model: <model>)
```

The trailer stays **two lines**. The `Review Agent: <name>` substring at the START of the line is preserved **byte-for-byte** (the `(model: …)` parenthetical is appended after it), so the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) discriminator (`lib-review-poll.sh::_agent_predicate` → `test("Review Agent: <name>")`, a substring test under `gh --jq`'s Go RE2) and the [INV-20](#inv-20-verdict-authenticity-binding-actor--window--trailer-presence) trailer-presence binding keep matching the model-bearing line.

**Model resolution + fallback** is identical to the [INV-04](#inv-04-reviewed-head-trailer-format) `Reviewed HEAD: … model` trailer and the [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) fan-out label — all three route through `lib-review-resolve.sh::_resolve_review_agent_model_label` (#220), the display-layer wrapper over `_resolve_review_agent_model`:

1. `AGENT_REVIEW_MODEL_<AGENT>` (per-agent override, if set & non-empty) — via [INV-41](#inv-41-per-agent-review-model--extra-args-resolution)'s `lib-review-resolve.sh::_resolve_review_agent_model`;
2. else shared `AGENT_REVIEW_MODEL`;
3. else the effective launch default **`sonnet`** (`${resolved:-sonnet}`).

The displayed value is the model the wrapper **launched** the agent with — so the verdict comment is consistent with the `Reviewed HEAD:` line — **except** the one case where the launch arg and the runtime model provably diverge: when the agent is `agy` and the resolved id is one [INV-50](#inv-50-agy---model-is-validated-against-agy-models-before-forwarding) drops (`agy` validates `--model` against `agy models` and silently runs its `settings.json` default for an unknown id). Originally (#208) agy was **not special-cased** and the trailer showed the dropped launch arg, which asserted a model agy never ran. **#220 corrects this:** `_resolve_review_agent_model_label` renders an agy member whose resolved id is dropped as **`agy default (settings.json)`** (or generic **`agy default`** when `agy models` can't be enumerated) — never the dropped id; a valid `AGENT_REVIEW_MODEL_AGY` is shown verbatim, and claude/kiro/codex (which honor `--model`) are unchanged. So the verdict comment, `Reviewed HEAD:`, and the fan-out line are now consistently honest for agy too.

**The model comes from the WRAPPER's deterministic resolution, never the agent CLI.** The CLI doesn't reliably know its own resolved model id — the whole point of [INV-56](#inv-56-review-verdict-is-posted-via-the-deterministic-post-verdict-helper-not-the-agents-bare-gh) is that the wrapper supplies trailer facts and the agent doesn't hand-write them. `build_review_prompt` resolves the model itself and interpolates it **single-quoted** (`'${_agent_model}'`) as the 6th `post-verdict.sh` arg in all three verdict-post examples (the generic Helper-usage example, the Decision PASS branch, the Decision FAIL branch). The single-quoting is load-bearing: the agent copies the example "exactly", and a multi-word model id (e.g. `Gemini 3.5 Flash (High)`) rendered unquoted would split into args 6/7/8 (truncating to `(model: Gemini)`) or hit a bash syntax error on the literal `(` (so the agent posts no verdict and the poller drops it `unavailable`). It is safe because the model is wrapper-resolved from operator config and the control-char validation rejects newlines/CR.

**Why**: a verdict comment is the operator-facing record of a review. Without the model, a passing/failing verdict can't be attributed to the model that produced it — which matters for a mixed fleet (`AGENT_REVIEW_AGENTS` lists ≥2 CLIs) where each agent may resolve a DIFFERENT model via [INV-41](#inv-41-per-agent-review-model--extra-args-resolution)'s per-agent override keys. [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) (#205) recently made the `Fanning out …` log line and the `Reviewed HEAD:` trailer report the per-agent resolved model; this extends that same "show the real per-agent model" principle to the verdict comment itself. Filed as #208.

**Producer**: `scripts/post-verdict.sh` — accepts an optional 6th `<model>` arg and folds it into the `Review Agent:` line when present/non-empty. `autonomous-review.sh::build_review_prompt` — resolves the per-agent **honest** model label (`_resolve_review_agent_model_label` → `${…:-sonnet}`, #220 — which mirrors INV-50's agy drop) and passes it as the 6th arg in all three verdict-post examples.

**Consumer**: the operator reading a verdict comment (the model attribution). The [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) discriminator / [INV-20](#inv-20-verdict-authenticity-binding-actor--window--trailer-presence) binding are NOT new consumers — they keep matching unchanged because the `Review Agent: <name>` prefix is preserved.

**Validation (model arg)**: deliberately LOOSE — a model id legitimately contains spaces / parens / dots (e.g. `Gemini 3.5 Flash (High)`, `claude-sonnet-4.6`), so the strict `[A-Za-z0-9._-]` regex the name/session args use does NOT apply. Only a **control character** — a newline OR a carriage return (either would split the single-line trailer, and could forge a second `Review Agent:` line; matched with `[[ "$MODEL" =~ [[:cntrl:]] ]]`) — and an **over-long** value (>128 chars) are rejected (exit `2`); everything else passes verbatim.

**Backward compatibility**: a 5-arg (no-model) call renders exactly the legacy `Review Agent: <name>` two-line trailer — byte-for-byte unchanged. An explicit-empty 6th arg behaves the same (empty == unset). So an all-unset fleet whose agents resolve to `sonnet` still gets a model line (`(model: sonnet)`); only a caller that omits the arg entirely gets the legacy form.

**Out of scope**: the [INV-04](#inv-04-reviewed-head-trailer-format) `Reviewed HEAD:` forensic trailer (already shows the model, unchanged), the `<!-- review-verdict: … -->` machine marker (`lib-review-verdict.sh::emit_verdict_trailer`, unchanged), and the codex resume-prompt fallback trailer in `lib-review-codex.sh` (a fallback instruction, not the authoritative path; codex routes its verdict through `post-verdict.sh` per [INV-56](#inv-56-review-verdict-is-posted-via-the-deterministic-post-verdict-helper-not-the-agents-bare-gh), so it gets the model line for free).

**Status**: **ENFORCED** (closes #208).

**Test**: `tests/unit/test-post-verdict.sh` — TC-PV-17 (6th arg → exact `Review Agent: <name> (model: <model>)` line), TC-PV-18 (omitted → byte-for-byte legacy `Review Agent: <name>`, no parenthetical), TC-PV-19 (explicit-empty → legacy), TC-PV-20 (`Gemini 3.5 Flash (High)` accepted + rendered verbatim), TC-PV-21 (control-char-bearing model — newline OR carriage return → exit 2, no gh call), TC-PV-22 (over-long model → exit 2), TC-PV-23 (`Review Session:` + first-line `Review PASSED`/`Review findings:` guarantees unchanged with the 6th arg), TC-PV-24 (the [INV-40] `test("Review Agent: <name>")` predicate still matches the model-bearing line — validated against **real `gh --jq`** Go RE2 where available, per the `gh --jq is RE2` caveat). `tests/unit/test-autonomous-review-verdict-via-helper.sh` — TC-PVP-07 (all three rendered verdict-post invocations carry a 6th arg), TC-PVP-08/10 (the value equals the per-agent resolved model; rendered identically for a codex and a non-codex agent — no per-CLI branch), TC-PVP-09 (a per-agent override surfaces the distinct id, not the shared default), TC-PVP-11 (no model configured → the launch default `sonnet`), TC-PVP-12/12b (a multi-word model id is rendered single-quoted as one token and the rendered example parses to a single `$6` — with `_agy_known_model` stubbed so the agy override resolves to a known id per #220). The agy label-honesty correction (#220) is tested in `tests/unit/test-autonomous-review-per-agent-model.sh` — TC-PAML-SRC-01 asserts `build_review_prompt`'s `_agent_model` is assigned from `_resolve_review_agent_model_label` (see [INV-50](#inv-50-agy---model-is-validated-against-agy-models-before-forwarding) Test for the full TC-PAML block). Test plan: `docs/test-cases/verdict-model-line.md` + `docs/test-cases/agy-model-label-honesty.md`. **No E2E** (pure wrapper/helper/prompt + doc change; no deployed-resource behavior). Backward-compat gate: `test-post-verdict.sh` TC-PV-01..16, `test-autonomous-review-verdict-via-helper.sh` TC-PVP-01..06, `test-autonomous-review-per-agent-model`, `test-autonomous-review-multi-agent` stay green.

**Cross-references**:
- [INV-56](#inv-56-review-verdict-is-posted-via-the-deterministic-post-verdict-helper-not-the-agents-bare-gh) — the deterministic verdict-post chokepoint this extends; the model is supplied by the wrapper, not hand-written by the agent, for the same reason.
- [INV-41](#inv-41-per-agent-review-model--extra-args-resolution) — the per-agent model resolution (`_resolve_review_agent_model`) reused verbatim as the source of truth.
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) / [INV-20](#inv-20-verdict-authenticity-binding-actor--window--trailer-presence) — the discriminator / trailer binding that keep matching because the `Review Agent: <name>` prefix is preserved.
- [INV-04](#inv-04-reviewed-head-trailer-format) — the `Reviewed HEAD: … model` trailer the verdict-comment model is kept consistent with.
- [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) — the immediately-prior "show the real per-agent model" fix (fan-out + Reviewed-HEAD labels) this extends to the verdict comment; #220 then makes ALL THREE (verdict comment + fan-out + Reviewed-HEAD) honest for an agy member whose resolved id is dropped by INV-50, via the shared `_resolve_review_agent_model_label`.
- [INV-50](#inv-50-agy---model-is-validated-against-agy-models-before-forwarding) — the agy `--model` validation/drop the #220 label correction mirrors so the verdict comment never asserts a model agy never ran.
- [`review-agent-flow.md` § Verdict posting (INV-56)](review-agent-flow.md#verdict-posting-inv-56) — runtime walkthrough (the model-line bullet).

## INV-61: kiro auth/login-failure `unavailable` drops surface a distinct reason, not a bare opaque `unavailable`

_Triage (issue #236): [machine-checked: tests/unit/test-lib-review-kiro.sh, tests/unit/test-autonomous-review-multi-agent.sh]_

> **Implemented in `adapters/kiro.sh`** ([INV-75](#inv-75-all-per-cli-behavior-lives-in-that-clis-adapter--inline-cli-conditionals-in-orchestration-code-are-a-defect), #232): the `_classify_kiro_drop_reason` / `_kiro_drop_reason_phrase` scrapers moved from `lib-review-kiro.sh` (now a thin compat shim) into the kiro adapter.

**Rule**: when a fan-out member whose CLI is `kiro` is resolved `unavailable`, the wrapper scrapes that agent's OWN generic per-agent log (`$_agent_log` = `/tmp/agent-${PROJECT_ID}-review-${ISSUE_NUMBER}-kiro.log`, captured per-agent into `AGENT_KIRO_LOGS` during fan-out — kiro has NO separate `--log-file` like agy) via `lib-review-kiro.sh::_classify_kiro_drop_reason <log>` and, if an auth/login-failure signal is present, attaches a distinct, actionable reason (naming the operator remedy `kiro-cli login --use-device-flow`) to the `WARNING: review agent(s) dropped (unavailable)` log line AND the posted "dropped (unavailable) agent(s)" issue comment (and the all-unavailable `log` line). Classification:

- ANY of the fixed substrings `Failed to open browser for authentication`, `kiro-cli login`, `--use-device-flow`, or `Failed to open URL` (the lines the Kiro CLI prints when its stored OAuth/login token has expired and it cannot open a browser for device-flow re-auth in the headless SSM-spawned shell) → **`auth-failed`**;
- none of those signals present (a clean no-verdict kiro turn, or a genuine non-auth launch failure) → empty token → the bare `unavailable` wording is unchanged (**no over-claim**: a no-verdict miss is NOT an auth failure).

`_kiro_drop_reason_phrase` renders the token into the human clause posted/logged (`auth-failed (browser/device-flow login required on the execution host: kiro-cli login --use-device-flow)`). It is single-pass `grep -F` (fixed-substring, no `jq` — the signal lives in plain CLI stdout/stderr text, not a JSON stream), and **fail-safe**: a missing/empty/unreadable/empty-arg log echoes empty and returns 0 (never aborts the `set -euo pipefail` wrapper). Both helpers `return 0` ALWAYS — load-bearing, because they are called inside a `$(…)` in a `_dropped_reasons` append that would abort the wrapper under `set -e` (stranding the issue in `reviewing`) if non-zero.

**Deliberately NOT changed**: an `auth-failed` kiro is STILL dropped from the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) unanimous-PASS aggregation exactly as `unavailable` — this is **observability only**, NOT a deciding FAIL. An expired token is an operational/infra condition, not a code rejection; promoting it to a veto (like the [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto) `timed-out` veto) would block every merge whenever kiro's token expires on the host, which is worse than degrading to the surviving fleet. `_classify_noverdict_agent` / `_aggregate_review_verdicts` are untouched. This issue does NOT attempt to re-auth kiro — the root-cause remedy is operational (`kiro-cli login --use-device-flow` on the execution host); INV-61 only REPORTS the cause so the bare `unavailable` becomes actionable.

**Why**: surfaced by #215. On a kiro-bearing fleet, a kiro review member whose stored OAuth token expired tried to open a browser for device-flow login, failed in the headless shell, exited at launch with no verdict, and was dropped as a bare `unavailable` — the drop-reason assembly enriched the reason only for `agy` (INV-58) and `codex` (INV-59), so kiro's actual failure (an expired token, fixable with one operator command) was invisible, indistinguishable from a launch misconfig or a no-verdict miss. This is the kiro-shaped sibling of [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) (agy quota wall) / [INV-59](#inv-59-codex-transient-stream-error-drops-surface-a-distinct-reason-and-are-ridden-out-by-the-resume-loop-not-opaquely-dropped) (codex transient stream 5xx) for a DIFFERENT failure mode (an auth/login token expiry), reading the CLI's own log in the same CLI-specific review-side lib.

**Out of scope** (per #215): re-authenticating kiro (operational, not the wrapper's job); the INV-40 vote (unchanged — a kiro auth-failure stays a `unavailable` drop, never a deciding FAIL); a retry of the kiro turn (kiro fails at LAUNCH, not mid-stream — there is nothing to ride out like INV-59's codex stream blip); drop-reason classifiers for other agents (claude/gemini/opencode).

**Producer**: `lib-review-kiro.sh` — `_classify_kiro_drop_reason` (log scan), `_kiro_drop_reason_phrase` (human rendering). `autonomous-review.sh` — captures `AGENT_KIRO_LOGS` in the fan-out and builds the kiro branch of `_dropped_reasons` in the drop-classification loop.

**Consumer**: the operator reading the wrapper log / the dropped-agent issue comment (the `auth-failed` reason). No consumer change to the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) aggregation, the verdict poller, the E2E gate, or the dispatcher.

**N=1 / non-kiro / signal-free carve-out (backward compatibility)**: a non-kiro member dropped `unavailable` triggers no kiro lookup; a kiro member whose log shows no auth signal (a clean no-verdict miss, or a genuine non-auth launch failure) yields an empty token → the bare `unavailable` wording, unchanged. The SAME drop-reason loop now enriches agy (quota/auth), codex (stream-error), AND kiro (auth-failed) members in one fan-out, each with its own distinct clause.

**Status**: **ENFORCED** (closes #215).

**Test**: `tests/unit/test-lib-review-kiro.sh` — TC-KIRO-DROP-CLS-01..07 (`_classify_kiro_drop_reason`: auth-failure log → `auth-failed`, clean no-verdict turn → empty, empty/missing/empty-arg → empty, each individual signal substring alone → `auth-failed`, committed fixture → `auth-failed`, no crash under `set -euo pipefail` via BOTH a command-substitution call AND a BARE call — the same dual-call guard as the codex CLS-08 case), TC-KIRO-DROP-PHR-01..03 (`_kiro_drop_reason_phrase`: `auth-failed` → clause naming `kiro-cli login --use-device-flow`; empty/unknown token → empty phrase), TC-KIRO-DROP-LOOP-01..04 (behavioral: the drop-reason loop yields a distinct reason for a kiro auth-failure log vs. empty for a generic log; **BOTH agy (quota) + kiro (auth) dropped in one fan-out lists a distinct reason for each**; a non-agy/non-codex/non-kiro agent adds nothing), TC-KIRO-DROP-SRC-01..06 (source-of-truth: wrapper sources `lib-review-kiro.sh`, captures `AGENT_KIRO_LOGS`, calls `_classify_kiro_drop_reason`, interpolates `_kiro_drop_reason_phrase`, `bash -n` clean, CI shellcheck lists the lib), TC-KIRO-DROP-REG-01..02 (an auth-failure drop classifies distinctly from a no-verdict drop; a clean no-verdict turn is NOT misreported). `tests/unit/test-autonomous-review-multi-agent.sh` — TC-MAR-SRC-15a..d (the wrapper wires the kiro classifier into the drop loop). Fixture: `tests/unit/fixtures/kiro-auth-failed.fixture`. Test plan: `docs/test-cases/kiro-drop-reason.md`. **No E2E** (pure wrapper/lib + doc change; no deployed-resource behavior). Backward-compat gate: `test-autonomous-review-multi-agent`, `test-lib-review-agy`, `test-lib-review-codex` stay green.

> **Post-install / upgrade**: this PR **ADDS** a new dispatcher lib `scripts/lib-review-kiro.sh`. After merge + `npx skills update -g`, re-run `install-project-hooks.sh` on every onboarded project (per the operator's post-merge Step 2) — the per-project `scripts/` holds per-file symlinks into the user-scope skill, and a newly-added lib has NO symlink until the installer re-runs, so the review wrapper would `source` a missing file and crash on startup (stranding issues in `reviewing`). (Edits to existing files do NOT need this; only ADDED/REMOVED dispatcher files do.)

**Cross-references**:
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the fan-out + `unavailable` definition this annotates; the aggregation/vote is unchanged (an auth-failed kiro stays dropped, not a deciding FAIL).
- [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) — the agy-shaped sibling for a DIFFERENT failure mode (quota wall); same drop-reason assembly loop, same CLI-specific review-side-lib layering, same observability-only posture. INV-61 borrows agy's `auth-failed` token shape but reads kiro's generic per-agent log (not a `--log-file`).
- [INV-59](#inv-59-codex-transient-stream-error-drops-surface-a-distinct-reason-and-are-ridden-out-by-the-resume-loop-not-opaquely-dropped) — the codex-shaped sibling for a transient stream 5xx; same layering. (Unlike INV-59, INV-61 has NO retry half — kiro fails at launch, not mid-stream, so there is no transient blip to ride out.)
- [`review-agent-flow.md` § kiro auth/login drop reason (INV-61)](review-agent-flow.md#kiro-authlogin-drop-reason-inv-61) — runtime walkthrough.

## INV-62: the codex review lane runs the `codex review` subcommand (auto-scoped, prompt-carried gate) with a stdout verdict fallback

_Triage (issue #236): [machine-checked: tests/unit/test-lib-review-codex.sh, tests/unit/test-lib-agent-codex.sh]_

> **Implemented in `adapters/codex.sh`** ([INV-75](#inv-75-all-per-cli-behavior-lives-in-that-clis-adapter--inline-cli-conditionals-in-orchestration-code-are-a-defect), #232): the entire review lane — `_run_codex_review`, the worktree prep/cleanup, the prompt-echo malformed guard, the stdout classifier, and the re-run controller — moved from `lib-review-codex.sh` (now a thin compat shim) into the codex adapter. `codex review`'s positional `[PROMPT]` is the [INV-34](#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element) Clause A2 carve-out.

**Rule**: when a review fan-out member's CLI is `codex`, `autonomous-review.sh` MUST dispatch it through `lib-review-codex.sh::_run_codex_review`, which runs the purpose-built **`codex review "<prompt>"`** subcommand — NOT `codex exec` and NOT a resume loop. `codex review` is natively multi-step (it fetches and re-reads the diff across turns without a single-turn budget) and **auto-scopes the diff to the PR's merge target** (the exact review range), so no `--base` is passed. The codex **dev** path (`autonomous-dev.sh` → `run_agent`/`resume_agent` codex branch in `lib-agent.sh`) stays on `codex exec --json` **byte-for-byte unchanged** — codex-review knowledge stays OUT of the CLI-agnostic primitives and lives only in `lib-review-codex.sh`. Every other review CLI (claude / agy / kiro / gemini / opencode) keeps its single-invocation `run_agent` path unchanged.

Sub-rules:

1. **Invocation shape.** `_codex_review_argv <out-array> "<prompt>" "<model>"` populates a bash array (a **nameref out-array**, mirroring `_parse_extra_args`) with `review "<prompt>" -c 'model="<resolved-model>"' <extra-args>`. The model is passed via `-c 'model="..."'` because **`codex review` rejects `-m`** (verified, CLI 0.137.0). The argv carries **no `--base`** (`[PROMPT]` is mutually exclusive with `--base`/`--commit`; auto-scope is the intended path), **no `-m`**, and **no `--json`** (`codex review` emits human-readable text, not a JSONL event stream). The per-agent extra-args are the [INV-41](#inv-41-per-agent-review-model--extra-args-resolution)-resolved value aliased onto `AGENT_DEV_EXTRA_ARGS` (the var `_codex_review_argv` reads via `_parse_extra_args`), so the per-agent `AGENT_REVIEW_EXTRA_ARGS_<AGENT>` override reaches `codex review`'s argv too — #212 stays fixed. **The prompt is carried as ONE array element**: `build_review_prompt` renders a large MULTI-LINE heredoc, and the out-array (no newline serialize/parse round-trip) keeps it a single positional. An earlier draft emitted the argv one-element-per-line and rebuilt it with `while read`, which split the prompt at every `\n` into many positionals so `codex review` got bogus args and failed before reviewing (#218 review finding 1) — the array build closes that.

2. **"Resume" is a bounded re-run, not a thread resume.** `codex review` has no resume/thread/session flag, and each invocation re-reads the diff fresh. So a **non-zero, NON-timeout** exit (a transient `turn.failed` / SSE stream blip — #209) is ridden out by **re-running a fresh `codex review`**, bounded by `CODEX_REVIEW_MAX_RERUNS` (default 3) **AND** the `AGENT_REVIEW_TIMEOUT`-derived wall-clock deadline (`_codex_review_deadline_seconds`, clock-stubbable via `_codex_now_seconds`). The max-rerun bound is checked BEFORE the deadline so a `max=N` config does exactly N re-runs when time allows. A non-numeric `CODEX_REVIEW_MAX_RERUNS` degrades to the default (no `set -euo pipefail` abort). The loop's continue/break decision keys on the **LAST invocation's rc** (`last_run_rc`), NOT on the sticky return value — it stops the instant a run exits `0` (a verdict-producing run) or `124`/`137` (a timeout, sub-rule 3); it re-runs ONLY while the most recent run was a non-timeout failure. This subsumes [INV-59](#inv-59-codex-transient-stream-error-drops-surface-a-distinct-reason-and-are-ridden-out-by-the-resume-loop-not-opaquely-dropped)'s retry half.

   **A DETERMINISTIC argv rejection STOPS the loop on the first run — it is NOT a transient blip (#223).** `_codex_review_argv` splices the [INV-41](#inv-41-per-agent-review-model--extra-args-resolution)-resolved per-agent extra-args verbatim into the argv. `codex review` accepts only `-c/--config`, `--base`, `--commit`, `--uncommitted`, `--title`, `--enable`, `--disable` (verified 0.137.0); anything else (e.g. a `codex exec`-era `-s danger-full-access` sandbox flag a deployment carried over the #218 migration) is rejected with an **exit-2 clap parse error** (`error: unexpected argument '-s' found` / `error: invalid value … for '<opt>'`). Re-running the **identical** argv can never succeed, so on a run that **exits rc 2** (clap's parse-error exit code) the loop scans the stdout capture for the clap signature via `_codex_review_argv_rejection_flag`; on a match it **breaks immediately (zero further re-runs)** and emits a `config-error`-naming log line (NOT the misleading "transient stream error" framing, which sent operators chasing upstream/network issues instead of their own conf). The non-zero rc still propagates → the post-window sweep resolves codex `unavailable`, and the drop-reason path names the rejected flag as `config-error:<flag>` (sub-rule 5b). The argv builder is **unchanged** — the rejection is caught at RUNTIME, not pre-filtered (flag-filtering was rejected as too magical; the operator remedy is the INV-41 single-space idiom `AGENT_REVIEW_EXTRA_ARGS_CODEX=" "`). A `config-error` is an operator-conf condition, not a code rejection, so — exactly like `stream-error` / `auth-failed` — it stays a dropped `unavailable`, **never a deciding FAIL** (`_classify_noverdict_agent` / `_aggregate_review_verdicts` untouched).

   **The rc-2 gate is load-bearing — the capture scan alone is NOT a sufficient discriminator (#223, PR #225 review finding [P1]).** Breaking early on "any non-zero run whose capture contains the clap string" would misclassify a GENUINE transient failure (e.g. rc 1) whose stdout merely **prints or quotes** `error: unexpected argument '<flag>' found` — codex echoing a reviewed-diff hunk, or a transport blip after partial output — as a deterministic config-error, skipping the configured re-runs and dropping a recoverable agent. So the early-break is gated on **rc 2** (clap parse-error exit) **AND** the capture signature; every other non-zero rc (1, a stream `turn.failed`, …) still takes the bounded re-run path (#209). The drop-reason classifier carries the same gate (sub-rule 5b) so a transient rc-1 drop is named `stream-error` / left bare, never `config-error`.

3. **A per-run timeout STOPS the loop immediately and returns the INV-48 veto rc (zero further re-runs).** A `124` (coreutils `timeout` TERM-expiry) or `137` (`--kill-after` SIGKILL) terminates the re-run loop at once and `_run_codex_review` returns that rc, so the post-window sweep maps a no-verdict 124/137 to `timed-out` (a deciding FAIL that VETOES the merge per [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto)). The re-run loop exists for TRANSIENT stream errors, **not** the per-run timeout cap: re-running a wall-clock-capped run is pointless (the cap refires) and — because each clean re-run is a fresh `codex review` that may self-post — would risk DUPLICATE verdict comments (violating sub-rule 4's "exactly one verdict") and would also pin `AGENT_LAUNCH_RC` at 124/137, which the sub-rule 5 rc-0 gate reads as "not a completed review" and refuses the stdout fallback for. An earlier draft keyed the loop break on the STICKY return value so a turn-1 timeout followed by a clean re-run kept the return rc at 124, never broke, and looped to `CODEX_REVIEW_MAX_RERUNS` — exactly that duplicate-verdict / refused-fallback hazard (#218 review finding 4). Stopping on the FIRST timeout (turn 1 or mid-loop, after some stream-error re-runs) closes it: a non-timeout exhaustion still returns the last rc → the poller resolves `unavailable`.

4. **Verdict capture is double-insured.** (a) The prompt instructs codex to self-post its verdict via `bash scripts/post-verdict.sh` (the [INV-56](#inv-56-review-verdict-is-posted-via-the-deterministic-post-verdict-helper-not-the-agents-bare-gh) deterministic chokepoint), preserving the full verdict contract. (b) `_run_codex_review` captures codex review's **clean stdout** (only codex's review text, stderr folded in, to a per-agent file keyed by session id). After the poll window, if a codex member produced stdout but **no** self-posted verdict comment landed (still `unavailable`), the wrapper classifies the stdout (`_codex_review_classify_stdout`: any `[P1]` blocking-priority marker → `fail`, else `pass` — the same gate the manual `/codex review` skill uses), composes the canonical body (`_codex_review_compose_body`), and posts it via `post-verdict.sh` as agent `codex`, then re-polls. (c) The comment poller (`lib-review-poll.sh::_classify_verdict_body`) stays the **authoritative gate** — unchanged. **Re-fetch-lag guard**: when the wrapper's own fallback post succeeds (rc 0) but the immediate `_fetch_agent_verdict_body` re-fetch returns empty because the GitHub comments API has not yet surfaced the just-posted comment (the same propagation lag the multi-round poll loop absorbs), the wrapper resolves the verdict from **its own composed body + classification** rather than leaving the agent unresolved — otherwise the post-window sweep would drop a verdict comment that DID land as `unavailable` (silently removing a passing/failing codex from the unanimous vote). The poller would classify the posted comment identically (post-verdict.sh prepends the canonical `Review PASSED` / `Review findings:` first line keyed off the same pass/fail arg), so resolving locally on lag is sound. The result: **exactly one** verdict comment lands per codex review — codex self-posted, OR the wrapper posted from parsed stdout — never zero (even under re-fetch lag), never two.

5. **The stdout fallback only trusts a COMPLETED review (rc-0 gate).** The double-insurance is load-bearing, not redundancy — `codex review` has its own review-output orchestration and may not honor a "call post-verdict.sh" instruction as reliably as `codex exec` (a pure prompt executor) did. But the wrapper derives a fallback verdict **only when `_run_codex_review` exited 0** (a completed review). Any non-zero exit is NOT a verdict source and is left UNRESOLVED for the terminal sweep: a `124`/`137` resolves `timed-out` (INV-48 merge veto — a cap-truncated review must not be voted on), and **any other non-zero rc** (a CLI usage / auth / config error, or a broken invocation that exhausted `CODEX_REVIEW_MAX_RERUNS`) resolves `unavailable`. This is critical because such a failure typically prints `error: …` to the capture with **no `[P1]`**, which `_codex_review_classify_stdout` would otherwise read as PASS — so without the rc-0 gate a failed/never-ran review would post a **false PASS** (especially dangerous combined with a malformed invocation; #218 review finding 2). A genuine pure-stream-error stdout is likewise not fabricated into a verdict — a real stream failure **exits non-zero** (the CLI exhausts its SSE reconnects and `turn.failed`s), so it fails the rc-0 gate, and the stream-error drop-reason path ([INV-59](#inv-59-codex-transient-stream-error-drops-surface-a-distinct-reason-and-are-ridden-out-by-the-resume-loop-not-opaquely-dropped) re-scoped) names a distinct `stream-error` reason.

   **The rc-0 gate is the SOLE gate on the fallback — there is NO stream-error skip on the rc-0 path** (#218 review finding 5). EVERY completed (rc 0) review is classified + posted: an EMPTY / missing capture is a valid clean review (`_codex_review_classify_stdout` → PASS, `_codex_review_compose_body` → its default PASS body); a capture whose text merely **mentions** the stream-error phrases (e.g. a legitimate review of THIS PR's stream-error fixtures or the stream-error detector) with no `[P1]` is ALSO a PASS. An earlier draft kept a `_codex_review_has_stream_error` skip on the rc-0 path "as belt-and-suspenders", but that helper is a BROAD substring scan (`stream disconnected before completion` / `Reconnecting... N/M`) — it false-positived on review TEXT that talks about a stream error, dropping a clean rc-0 review `unavailable` and violating "exactly one verdict". Removed: since the rc-0 gate already excludes every real (non-zero) stream failure, the skip was both dead and harmful. So on rc 0 the wrapper ALWAYS posts exactly one verdict; `_codex_review_has_stream_error` is now used only by `_classify_codex_drop_reason` (the drop-reason path for a genuinely non-zero codex), never to gate the fallback.

5b. **A non-zero `config-error` (deterministic argv rejection) gets a distinct drop reason naming the rejected flag, gated on rc 2 (#223, PR #225 finding).** A codex member dropped `unavailable` whose run exited **rc 2** (clap's parse-error exit) AND whose stdout capture shows a clap argv rejection (sub-rule 2's `_codex_review_argv_rejection_flag` matched) classifies to `config-error:<flag>` via `_classify_codex_drop_reason "$capture" "$launch_rc"` (checked BEFORE the `stream-error` scan — a clap error fails before any model stream opens, so they never co-occur; ordering config-error first is defensive and surfaces the more actionable signal). The classifier takes the agent's launch rc as an OPTIONAL 2nd arg and emits `config-error` **only when that rc is `2`** (or when the rc is omitted, for backward-compat): a transient rc-1 drop whose capture merely QUOTES the clap usage string (codex echoed a reviewed-diff hunk) is NOT mislabeled — at a non-2 rc the classifier falls through to the `stream-error` scan, naming the true transient cause. The wrapper's drop-loop threads `AGENT_LAUNCH_RC[<sid>]` into the call so its classification is correctly gated. `_codex_drop_reason_phrase` renders the token into the WARN line + the posted dropped-agent comment as `config-error: codex review rejected '-s' (exec-only flag in extra-args; clear it via AGENT_REVIEW_EXTRA_ARGS_CODEX=" ")` — so the operator sees the rejected flag and the remedy, not a bare opaque `unavailable`. Like the re-scoped [INV-59](#inv-59-codex-transient-stream-error-drops-surface-a-distinct-reason-and-are-ridden-out-by-the-resume-loop-not-opaquely-dropped) `stream-error` and the [INV-61](#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) `auth-failed` reasons, this is **observability only** — a `config-error` codex stays a dropped `unavailable`, never a deciding FAIL. Both helpers keep their `return 0`-always fail-safe contract (a non-zero `$(…)` in the drop-loop append would abort the wrapper under `set -e` and strand the issue in `reviewing`).

6. **`codex review` runs from a PR-branch worktree, NOT `PROJECT_DIR` (the diff-scoping fix).** `codex review` has no `--base`/PR-number flag — it auto-scopes its diff against the **current working tree's** HEAD/merge-base. The review wrapper runs from `PROJECT_DIR`, which the dispatcher keeps synced to `main`; running `codex review` there would scope to `main`'s (empty) diff, not the PR's, so the fallback could post a PASS/FAIL for the **wrong or empty diff**. (This is the scoping the deleted INV-55 path got for free via `gh pr diff <PR_NUMBER>`, which is PR-scoped regardless of cwd.) So before launching, the codex fan-out branch prepares a **throwaway PR-branch worktree** (`_codex_review_prepare_worktree "$PR_BRANCH" <dest>`) and runs `git worktree add --detach <dest> <commit>` at the **authoritative current PR tip** — `--detach` avoids "branch already checked out" collisions with the dev worktree / a sibling codex agent; the dest is session-id-keyed so a multi-codex fleet does not collide. It passes the worktree to `_run_codex_review` as the 4th arg and runs every `codex review` invocation from inside it (in a **subshell** `cd`, so the wrapper's own cwd is untouched). The worktree is torn down (`_codex_review_cleanup_worktree`, rc-0-always, `--force` + `prune`) regardless of rc. #218 review finding 3.

   **Resolving the tip is stale-proof (#218 review finding, stale-ref).** `git fetch origin <branch>` updates `FETCH_HEAD` reliably but updates the remote-tracking ref `origin/<branch>` only when a fetch refspec maps it — absent the refspec, `origin/<branch>` can be STALE while `FETCH_HEAD` is the fresh tip. So the resolver does NOT prefer `origin/<branch>`:
   - **When the repo has an `origin` remote** (production): the fetch is **MANDATORY** — `git fetch origin <branch>` MUST succeed (a failure is a HARD prepare failure → return 1 → fail closed, NEVER a fall-through to a possibly-stale local/`FETCH_HEAD` leftover), and the checkout commit is `FETCH_HEAD` (authoritative for "the tip fetched NOW"), not `origin/<branch>`.
   - **When there is no `origin`** (a local-only repo / the unit-test fixture): resolve a LOCAL ref (`refs/heads/<branch>`) — there is no remote-tracking ref to be stale against.
   This closes the gap where a stale `origin/<branch>` (or a leftover `FETCH_HEAD` after a failed fetch) could let `codex review` vote on the wrong commit/diff, defeating the fail-closed PR-scoping invariant.

   **The wrapper FAILS CLOSED on a worktree-prep failure (#218 review finding 1).** If the PR-branch worktree cannot be prepared (empty `PR_BRANCH`, or a fetch/`worktree add` failure), the wrapper does **NOT** run a vote-producing `codex review` — it SKIPS the run and sets a non-`0`/`124`/`137` sentinel rc (`CODEX_REVIEW_NO_WORKTREE_RC`, default `70`) so the post-window sweep resolves codex `unavailable` (dropped from the vote — an infra inability to scope the diff is not a code rejection, so it is NOT a deciding FAIL). An earlier draft "failed open" — it ran `codex review` from `PROJECT_DIR` with only a warning, but that review can still exit 0 and self-post / wrapper-post a PASS for `main`'s wrong/empty diff, reintroducing the exact safety hole the worktree fix closed (a vote for a non-PR diff). Failing closed means codex **never votes without a PR-scoped diff**. (`_run_codex_review`'s own empty-`pr_workdir` degrade-to-cwd path remains as a defense-in-depth fallback for any other caller, but the wrapper never reaches it — it gates the call behind a `_cx_wt_ready` flag.)

**Why**: the codex review path was shoehorned onto single-turn `codex exec`, which on a large diff burned its one turn on context-gathering and ended with no verdict. Three pieces of accidental complexity were layered on to compensate — `_run_codex_review_with_resume` (the resume loop), `_codex_log_has_verdict_message` (a JSONL parser mirroring the comment poller's classifier, drift-prone), and the [INV-55](#inv-55-the-codex-review-lane-receives-the-pr-diff-inline-in-its-prompt) inline-diff prompt block. That machinery was the root cause of a recurring bug class: **#198** (resume loop ineffective), **#209** (`turn.failed` not retried → opaque `unavailable`), **#212** (resume dropped per-agent extra-args). All three existed ONLY because review was on `codex exec`. `codex review` is purpose-built for exactly this job; moving to it removes the machinery and the bug class together — a net deletion of code.

**Deletions** (no code path references these after #218): `_run_codex_review_with_resume`, `_codex_log_has_verdict_message`, `_codex_resume_prompt`, the `CODEX_REVIEW_MAX_RESUMES` / `CODEX_REVIEW_INLINE_DIFF_MAX_BYTES` knobs, and the [INV-55](#inv-55-the-codex-review-lane-receives-the-pr-diff-inline-in-its-prompt) inline-diff prompt block in `build_review_prompt`'s codex branch (the `gh pr diff` fetch, the nonce'd `DIFF_START`/`DIFF_END` markers, the byte cap, the self-fetch fallback). **Kept + reused**: `_codex_review_deadline_seconds` and `_codex_now_seconds` (already clock-stubbable + unit-tested).

**Producer**: `lib-review-codex.sh` — `_codex_review_argv` (argv builder, nameref out-array), `_run_codex_review` (launch + bounded re-run + sticky-timeout rc + PR-workdir cwd + the #223 deterministic-rejection early-break), `_codex_review_prepare_worktree` / `_codex_review_cleanup_worktree` (the PR-branch worktree the `codex review` diff scopes against — sub-rule 6), `_codex_review_classify_stdout` (stdout→verdict), `_codex_review_compose_body` (canonical body), `_codex_review_argv_rejection_flag` (the #223 clap-rejection detector → rejected flag), `_codex_review_has_stream_error` / `_classify_codex_drop_reason` / `_codex_drop_reason_phrase` (re-scoped INV-59 drop reason, now scanning the stdout capture; the `config-error:<flag>` bucket is checked before `stream-error`). `autonomous-review.sh` — the fan-out codex branch prepares the PR-branch worktree and, ONLY when it is ready (`_cx_wt_ready`), calls `_run_codex_review` with it (4th arg) + tears it down; on a prepare failure it FAILS CLOSED (sentinel `CODEX_REVIEW_NO_WORKTREE_RC=70` → `unavailable`, no vote on the wrong diff); the codex branch of `build_review_prompt` carries the gate rules + verdict format + post-verdict instruction WITHOUT the inline diff; the post-window stdout fallback composes + posts (gated on rc 0; an rc-0 empty capture still posts the default PASS) when codex did not self-post.

**Consumer**: the comment poller (authoritative verdict gate, unchanged), the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) unanimous aggregation (unchanged — a `stream-error` codex stays a dropped `unavailable`, never a deciding FAIL, exactly as INV-59), and the operator reading the distinct drop reason.

**Scope guards**: the codex **dev** path stays on `codex exec` (byte-for-byte); `lib-agent.sh` contains no `codex review` token (no review-knowledge leak into the CLI-agnostic primitives). Other review CLIs keep their `run_agent` path. The upstream Bedrock `openai.gpt-5.5` 5xx condition is an infra matter, out of scope.

**Status**: **ENFORCED** (closes #218; supersedes [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn) and [INV-55](#inv-55-the-codex-review-lane-receives-the-pr-diff-inline-in-its-prompt), re-scopes [INV-59](#inv-59-codex-transient-stream-error-drops-surface-a-distinct-reason-and-are-ridden-out-by-the-resume-loop-not-opaquely-dropped), for the review path. Makes #198 / #209 / #212 moot for the review path by removing the machinery they patch). **Amended (#223)**: sub-rule 2 gains a deterministic-argv-rejection early-break (`_codex_review_argv_rejection_flag` → a clap exit-2 stops the re-run loop on the first run instead of being misread as a transient stream blip and retried to exhaustion), and sub-rule 5b gains the `config-error:<flag>` drop-reason bucket so a poison `codex exec`-era extra-args flag surfaces the rejected flag + the remedy instead of a bare opaque `unavailable`. **Amended again (#223, PR #225 review finding [P1])**: both the early-break and the drop-reason classification are GATED on the clap parse-error exit code (**rc 2**) — the capture scan alone is not a sufficient discriminator, so a genuine transient failure (e.g. rc 1) whose stdout merely quotes the clap usage string still takes the re-run path / is classified as the transient it is (`stream-error` / bare), never short-circuited as `config-error`.

**Test**: `tests/unit/test-lib-review-codex.sh` — TC-CXRS-CLS-01..07 (`_codex_review_classify_stdout`: `[P1]` → fail, only `[P2]`/`[P3]` or none → pass, empty → pass, mid-line/multiple `[P1]` → fail, fenced `[P1]` counted, no `set -euo pipefail` abort), TC-CXRS-BODY-01..04 (`_codex_review_compose_body`: pass/fail summary, empty-stdout default, large-stdout truncation under the post-verdict body cap), TC-CXRS-LAUNCH-01..08 (`_codex_review_argv` out-array shape: positional prompt as ONE element, `-c model=`, no `-m`, no `--base`, no `--json`, extra-args as distinct elements, and **LAUNCH-08 the #218 finding-1 regression — a multi-line prompt stays a single argv element + does not inflate the element count**), TC-CXRS-MLP-01 (end-to-end: `_run_codex_review` passes a multi-line prompt to the stubbed binary as ONE arg, not split at newlines), TC-CXRS-WT-01..06 + WT-SRC-01..09 (**#218 finding-3 PR-branch worktree** + **finding-1 fail-closed** + **finding-5 rc-0-sole-gate** + **stale-ref hardening**: prepare checks out the PR-branch tip [against a throwaway git repo] + cleanup removes it; prepare fails rc1 on empty-branch / empty-dest / non-repo / non-existent-branch; cleanup rc-0-always; **WT-03b — with `origin/<branch>` pinned STALE (no fetch refspec) and the remote advanced, prepare checks out the FRESH tip via `FETCH_HEAD`, not the stale remote-tracking ref [proven to fail against the pre-fix `origin/<branch>`-first resolver]; WT-03c — `origin` present but the fetch FAILS → HARD prepare failure rc1, no stale fall-through**; `_run_codex_review` runs `codex review` FROM the PR-branch worktree with the wrapper's cwd stable; an empty workdir degrades to cwd + warns [lib defense-in-depth]; the wrapper prepares/passes/tears-down the worktree; **WT-SRC-04..07 — the wrapper FAILS CLOSED: it gates `_run_codex_review` behind a `_cx_wt_ready` flag, sets the `CODEX_REVIEW_NO_WORKTREE_RC` (70) sentinel → `unavailable` on prepare failure, and the stale fail-open "running from PROJECT_DIR" path is gone**; and **WT-SRC-08/09 — the rc-0 gate is the SOLE gate: no bare `[[ -n && -s ]] || continue` empty-capture drop, and the wrapper no longer CALLS `_codex_review_has_stream_error` to gate the fallback (finding 5)**), TC-CXRS-RUN-01..08 (bounded re-run: clean → 0 re-runs, transient-then-clean → 1 re-run rc 0 [closes #209], sustained → N re-runs then stop, `MAX_RERUNS=0` → 0 re-runs, non-numeric → default, deadline guard, capture holds stdout; and **#218 finding-4 timeout handling — RUN-07/07b/07c/07d: a turn-1 `124` or `137` STOPS the loop immediately (1 run, returns the veto rc, ZERO re-runs); a timeout after a would-be-clean run issues NO extra re-run [no duplicate-verdict path]; a mid-loop re-run that itself times out stops at the timeout (2 runs, rc 124)**), TC-CXRS-DROP-* (re-scoped INV-59 stdout stream-error detector + phrase), **TC-CXRS-CFG-* (the #223 deterministic argv-rejection split + the PR #225 rc-2 gate: `_codex_review_argv_rejection_flag` detects the clap signature [`unexpected argument`/`invalid value`] and echoes the rejected flag — no false-match on a prose mention or a stream-error capture, fail-safe under `set -euo pipefail`; `_run_codex_review` STOPS on a clap rejection ONLY at rc 2 [CFG-RUN-01 — rc 2 + clap capture → 1 run, ZERO re-runs] while a genuine transient still re-runs [CFG-RUN-02 — stream-error then clean → 2 runs, #209 unregressed; **CFG-RUN-04 — rc 1 with a clap-QUOTING capture → STILL re-runs (2 runs, rc 0); CFG-RUN-05 — sustained rc 1 with a clap-quoting capture → exhausts the re-run budget (4 runs), not short-circuited**]; `_classify_codex_drop_reason "$capture" "$rc"` → `config-error:<flag>` ONLY at rc 2 [checked before stream-error, does NOT shadow it; **CFG-DROP-07 rc 2 → config-error; CFG-DROP-08 rc 1 clap-quoting → empty; CFG-DROP-09 rc 1 clap-quote + stream-error → stream-error wins; CFG-DROP-10 rc omitted → config-error (back-compat); CFG-DROP-11 rc 2 + no clap line → stream-error; CFG-DROP-12 rc 1 bare call → no abort**], `_codex_drop_reason_phrase` names the flag + the `AGENT_REVIEW_EXTRA_ARGS_CODEX=" "` remedy; **WIRE-09b — the wrapper threads `AGENT_LAUNCH_RC` into `_classify_codex_drop_reason` for the rc-2 gate**)**, TC-CXRS-WIRE-01..11 (source-of-truth: wrapper calls `_run_codex_review`; `_run_codex_review_with_resume` / `_codex_log_has_verdict_message` GONE from lib + wrapper; `DIFF_START_`/`DIFF_END_` / the codex `gh pr diff` inline-fetch GONE; bare `run_agent` retained for non-codex; wrapper composes + classifies + posts the fallback; `bash -n` clean; CI shellcheck lists the lib; drop-reason wired; **WIRE-10 the #218 finding-2 rc-0 gate — the real wrapper reads `AGENT_LAUNCH_RC` and admits ONLY rc 0; WIRE-11 the #218 finding-1 fix — `_run_codex_review` builds the argv via the nameref out-array, not a newline round-trip**), TC-CXRS-INT-01..10 (behavioral: `[P1]` not self-posted → wrapper FAIL post; clean not self-posted → wrapper PASS post; codex self-posted → NO double-post; **INT-04 a genuine stream failure (NON-ZERO rc) → dropped by the rc-0 gate; INT-04b the #218 finding-5 regression — an rc-0 review whose text MENTIONS the stream-error phrase with no `[P1]` still posts the default PASS, NOT dropped**; re-fetch lag on PASS / on FAIL → still resolves the posted verdict from the wrapper's composed body, NOT dropped `unavailable` — sub-rule 4 re-fetch-lag guard; **INT-07..09 the #218 finding-2 rc-0 gate — a non-zero exit (CLI error stdout with no `[P1]`, or partial `[P1]` stdout) is NOT posted as a false verdict and is left unresolved, while a clean rc-0 review still posts; INT-10 the second part of finding 2 — an rc-0 review with an EMPTY capture + no self-post still posts the default PASS, NOT dropped `unavailable`**), TC-CXRS-DEV-01..02 (dev-path guard: the codex dev `run_agent` branch still emits `codex exec --json`; `lib-agent.sh` has no `codex review` / review-lib leak). The pre-existing `tests/unit/test-lib-agent-codex.sh` (`TC-LA-CODEX-*`) independently pins the `codex exec` dev branch shape and stays untouched + green. Fixtures: `tests/unit/fixtures/codex-review-stdout-{clean,p1,stream-error,cli-error,config-error}.txt` (the `config-error` fixture added for #223). Test plan: `docs/test-cases/codex-review-subcommand.md` (+ `docs/test-cases/codex-review-config-error.md` for the #223 split). Design: `docs/designs/codex-review-subcommand.md` (+ `docs/designs/codex-review-config-error.md` for #223). Backward-compat gate: `test-autonomous-review-prompt`, `test-autonomous-review-multi-agent`, `test-autonomous-review-per-agent-model`, `test-autonomous-review-verdict-via-helper`, `test-review-cli-exit-grace`, `test-review-agent-timeout` stay green.

> **Post-install / upgrade**: this PR does NOT add or remove a dispatcher script / `lib-*.sh` — it EDITS the existing `lib-review-codex.sh` and `autonomous-review.sh` and DELETES a test fixture/test (`tests/unit/test-codex-inline-diff-prompt.sh` + the old `codex exec` JSONL fixtures). No new `source` target is introduced, so the per-project `install-project-hooks.sh` re-run is NOT required after merge; `npx skills update -g` alone refreshes the user-scope copy (the existing per-file symlinks already resolve to the updated content). Only ADDED/REMOVED dispatcher *source* files (not tests/fixtures) need the installer re-run.

**Cross-references**:
- [INV-51](#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn) — the `codex exec` resume loop this REPLACES (superseded for the review path).
- [INV-55](#inv-55-the-codex-review-lane-receives-the-pr-diff-inline-in-its-prompt) — the inline-diff prompt this REPLACES (superseded; `codex review` fetches its own auto-scoped diff).
- [INV-59](#inv-59-codex-transient-stream-error-drops-surface-a-distinct-reason-and-are-ridden-out-by-the-resume-loop-not-opaquely-dropped) — re-scoped: its drop-reason detector now scans the stdout capture, its retry half is subsumed by sub-rule 2's bounded re-run.
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the fan-out + `unavailable` aggregation (unchanged; a stream-error codex stays dropped, not a deciding FAIL).
- [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto) — the timeout-veto whose 124/137 rc-stickiness sub-rule 3 preserves.
- [INV-56](#inv-56-review-verdict-is-posted-via-the-deterministic-post-verdict-helper-not-the-agents-bare-gh) — the deterministic verdict-post chokepoint both the self-post and the wrapper fallback route through.
- [INV-41](#inv-41-per-agent-review-model--extra-args-resolution) — the per-agent model / extra-args resolution `_codex_review_argv` consumes (`-c model=`, extra-args).
- [`review-agent-flow.md` § codex review subcommand (INV-62)](review-agent-flow.md#codex-review-subcommand-inv-62) — runtime walkthrough.

## INV-63: agent-smoke is a three-state probe (PASS / UNAVAILABLE / FAIL) run through the production `run_agent`, never a parallel invocation path

_Triage (issue #236): [machine-checked: tests/e2e/run-agent-smoke.sh, tests/unit/test-lib-agent-smoke.sh]_

**Rule**: the agent-CLI smoke (`lib-agent-smoke.sh::smoke_agent <agent-cmd> <model> [timeout-seconds]`) verifies that a coding-agent CLI can launch, authenticate, and get a **real model response**, and MUST classify the outcome into exactly **three states**, returning a distinct rc per state:

- **rc 0 — PASS**: the CLI's stdout contains the generated nonce (the model truly responded).
- **rc 2 — UNAVAILABLE**: a quota-exhausted / backend-model-capacity / transient-backend-failure signal, **OR a bare timeout (rc 124/137) with no auth/config signal** ([INV-67](#inv-67-a-bare-smoke-timeout-rc-124137-with-no-authconfig-signal-classifies-unavailable-not-fail), #246 — a Bedrock slow-start / capacity blip). **Environmental, self-healing — NOT a failure.** A consumer (the review-wrapper Phase-A.5 gate, [INV-64](#inv-64-the-review-wrapper-smokes-every-fan-out-member-before-the-fan-out-phase-a5-fail-aborts-the-review-unavailable-drops-the-member-pass-proceeds)) records but does **not** block on it. Promoting a quota wall (or a one-off slow tick) to a deciding FAIL would block every PR whenever an agent's daily quota is spent or its backend has a transient blip — strictly worse than recording it and degrading to the surviving fleet, exactly mirroring [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)'s `unavailable` tolerance.
- **rc 1 — FAIL**: **everything else** — the CLI fails to launch, an auth/config error, region drift (the #180 root cause), or a non-timeout no-response (a prompt non-zero exit with no nonce and no recognizable signal). **Operator-side configuration breakage — this is what the gate exists to catch.** A timeout that **does** carry an auth/config scraper signal is still FAIL (the signal wins before the bare-timeout rule); only the **bare** timeout moved to UNAVAILABLE in [INV-67](#inv-67-a-bare-smoke-timeout-rc-124137-with-no-authconfig-signal-classifies-unavailable-not-fail) (#246).

The split is the whole contract: **FAIL = operator-side config/launch breakage (gate-worthy), UNAVAILABLE = environmental quota/capacity (ignorable).**

Sub-rules:

1. **Reuse the production chain — no parallel invocation code.** `smoke_agent` generates a random nonce, builds a "reply with EXACTLY this token, use no tools" prompt, mints a **valid UUID session id** (`_smoke_session_id` — the Claude Code CLI REJECTS `--session-id` unless it is a UUID, so a non-UUID id would fail every real claude / claude-custom-endpoint entry at launch before any model call; #222 [P1] review), sets `AGENT_CMD=<agent-cmd>` + a short `AGENT_TIMEOUT` override (in a subshell so neither leaks to a sibling/parent), and calls the **existing `run_agent`** (`lib-agent.sh`). So the smoke exercises the exact production launch path — [INV-34](#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element) stdin channel, [INV-50](#inv-50-agy---model-is-validated-against-agy-models-wrapper-side-unknown-ids-are-omitted-not-forwarded) agy model validation, [INV-22](#inv-22-agent_launcher-tokenization--claude-only-invocation-contract) launcher handling, EXTRA_ARGS parsing — with zero duplicated invocation code. A regression in any of those branches surfaces in the smoke. The short `AGENT_TIMEOUT` is validated via `_is_positive_timeout_value` ([INV-13](#inv-13-wall-clock-cap-on-agent-invocations)) so a garbage value cannot DISABLE the bound (GNU `timeout 0` disables); the validated value is **normalized** before export — a bare integer gets `s` appended (`5` → `5s`), a value that already carries a unit (`5s`/`2m`/`1h`) is passed through verbatim, because the validator accepts BOTH forms and a naive `${v}s` would turn `5s` into `5ss`, which makes coreutils `timeout` fail immediately and false-FAIL a healthy CLI (#222 [P2] review).

2. **Classification reuses the per-CLI drop-reason scrapers; quota/capacity → UNAVAILABLE, auth/config → FAIL, bare timeout → UNAVAILABLE, other no-signal → FAIL.** `_smoke_classify` consults the existing CLI-specific scrapers: `_classify_agy_drop_reason` ([INV-58](#inv-58-agy-quota--auth-drops-surface-a-distinct-reason-not-an-opaque-unavailable)), `_classify_kiro_drop_reason` ([INV-61](#inv-61-kiro-auth-drops-surface-a-distinct-reason-not-an-opaque-unavailable)), `_classify_codex_drop_reason` ([INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback)). Mapping: agy `quota-exhausted*` → UNAVAILABLE, agy `auth-failed` → FAIL; kiro `auth-failed` → FAIL; codex `stream-error*` (upstream 5xx, transient backend) → UNAVAILABLE, codex `config-error*` (a deterministic clap argv rejection — INV-62 / #225 — i.e. operator-side config breakage) → FAIL with the rejected flag named (so the smoke surfaces the actionable reason, not a generic `no-response`). The scrapers (steps 2/3) are checked **before** the timeout branch (step 4), so an agy that hits the quota wall and then hangs to the timeout is still UNAVAILABLE, and a kiro/codex whose capture shows `auth-failed`/`config-error` and then hangs is still FAIL — the scraper cause wins over the bare 124/137. A **bare** timeout (rc 124/137) with **no** scraper signal classifies **UNAVAILABLE** (not FAIL) per [INV-67](#inv-67-a-bare-smoke-timeout-rc-124137-with-no-authconfig-signal-classifies-unavailable-not-fail) (#246): on a Bedrock-backed CLI it is a transient slow-start / capacity blip, the same environmental tolerance as a quota wall. A **non-timeout** run with **no nonce and no recognizable signal** (a prompt non-zero exit) → FAIL (`no-response`): the model never answered and there is no environmental excuse, so the conservative, gate-worthy default is FAIL.

3. **Nonce match is exact, stdout-only, AND gated on a successful exit.** The nonce is a unique `SMOKE-<16 hex>` blob (CSPRNG via `openssl rand` / `/dev/urandom`, with a PID+counter fallback that is collision-free within a process — `$RANDOM` alone is NOT the primary source because a tight loop reseeds slowly and can repeat). A truncated or garbled echo does **not** `grep -F`-match → not PASS. This prevents a stale-stdout or partial-echo false PASS. **`smoke_agent` captures the agent subshell's stdout and stderr to SEPARATE files (`2>"$stderr_file"`, never `2>&1`), and the nonce PASS check greps the STDOUT file ONLY** (#222 [P1] review r1). The prompt CONTAINS the nonce, so a broken CLI/wrapper that echoes the stdin prompt onto STDERR and exits non-zero would — if stderr were merged into the nonce-check file — be misreported `PASS` despite no model response. The per-CLI drop-reason scrapers (kiro/codex) instead receive a COMBINED stdout+stderr view (their auth / stream-error text can legitimately land on either stream); the agy scraper reads its own separate `--log-file`. **The PASS branch ALSO requires `run_agent` to have exited `0`** (#222 [P1] review r2): a broken CLI/wrapper can echo the prompt (nonce included) to STDOUT and THEN exit non-zero (a launch/config failure after the echo) — without the rc-0 gate that reads as `PASS` despite no real model response. A healthy model round-trip exits 0; a non-zero exit falls through to the drop-reason scrapers / timeout / `no-response` classification. **The nonce check runs over a TTY-SANITIZED view of stdout** (`_smoke_stdout_has_nonce`): kiro `--no-interactive` stdout wraps its response in terminal decoration AND injects a **BEL (`0x07`) byte INSIDE the echoed token** (captured stdout literally contains `SMOKE-^G<hex>`), so a raw `grep -qF "$nonce"` never matches a verified-healthy kiro and it is misclassified `no-response` FAIL — on a healthy box that rc-1s every PR (this repo's own command-mode E2E) and smoke-fails every healthy kiro fleet member under the Phase A.5 gate (#224 operator live-matrix review). The helper strips C0 control bytes (`tr -d '\000-\010\013-\037\177'`, covering the BEL while keeping `\n`/`\t`) + ANSI CSI sequences (`sed 's/\x1b\[[0-9;]*[a-zA-Z]//g'`), **captures** the sanitized text into a variable, and tests it with a bash glob (`[[ "$cleaned" == *"$nonce"* ]]`) — NOT a trailing `grep -q` pipe. A `… | grep -q` would early-exit on the first match, close its stdin, and (under the wrappers' `set -o pipefail`) make the pipeline return `141` SIGPIPE despite a successful match whenever the nonce lands early in >~64 KB of stdout — re-introducing the very false-`no-response` FAIL this fixes. The capture-then-glob form is SIGPIPE-immune. The strip **only ever recovers a hidden real match** — it does NOT widen the false-PASS surface (the rc-0 gate + stdout-only separation are unchanged, and the nonce's 16-hex uniqueness still enforces exactness).

4. **One machine-readable evidence line per run.** `smoke_agent` emits exactly `SMOKE <agent> <PASS|FAIL|UNAVAILABLE> <elapsed>s reason=<...>` on stdout. The format is stable and consumed by the [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) command-mode evidence parser (this repo's own `autonomous.conf` flips `E2E_MODE=command E2E_COMMAND="bash tests/e2e/run-agent-smoke.sh"` so every autonomous-reviewed PR runs the matrix). `_smoke_classify` returns `STATE|reason` on a single line (command-substitution-safe — a nameref out-var would not survive `$(...)`); the state→rc map is the sole place that converts a state into a process exit code.

5. **The harness aggregates three states + SKIP; any FAIL → overall rc 1, UNAVAILABLE/SKIP non-blocking.** `tests/e2e/run-agent-smoke.sh` reads a gitignored matrix (`tests/e2e/e2e.conf`; commit `tests/e2e/e2e.conf.example`), each entry `name|agent_cmd|model|env-setup` with `env-setup` `eval`'d in the entry's own subshell (operator-trusted config, same trust model as [INV-22](#inv-22-agent_launcher-tokenization--claude-only-invocation-contract) `AGENT_LAUNCHER`). A leading `require:VAR;` directive declares `VAR` mandatory: if it is unset/empty after env-setup runs, the entry is **SKIP** (rc 3, non-blocking) — used for the custom-endpoint entry whose API key lives in a local secrets file. Entries run **in parallel** (wall-clock ≈ slowest entry). Aggregation: any FAIL → overall **rc 1**; UNAVAILABLE + SKIP are recorded but non-blocking; final line `SMOKE-SUMMARY pass=N fail=N unavailable=N skip=N`. A **malformed** entry (not exactly 4 `|`-fields) or an **empty matrix** is a LOUD reject (overall rc 1) — a silently-skipped malformed entry would hide a real CLI from the gate. A `SMOKE_STUB=1` mode bundles stub CLIs on `PATH` + a stub matrix so CI runs the FULL harness end-to-end without real CLIs/credentials.

6. **The per-entry `env-setup` is the LAST writer — it is `eval`'d AFTER the smoke lib is sourced, then the launcher is re-tokenized.** `_run_entry` orders its subshell as: (a) `source lib-agent-smoke.sh` — which via `lib-agent.sh` re-sources the project `autonomous.conf`, assigning conf globals (`BEDROCK_AWS_REGION`, `CLAUDE_CODE_USE_BEDROCK`, `AGENT_DEV_EXTRA_ARGS`, …) **unconditionally**, and tokenizes `AGENT_LAUNCHER → AGENT_LAUNCHER_ARGV[]`; (b) **clear an inherited shared `AGENT_LAUNCHER` for a non-claude entry** (sub-rule 7); (c) **clear the inherited `AGENT_DEV_EXTRA_ARGS` for every entry** (sub-rule 8); (d) `eval` the entry's `env-setup` — so an env-setup that pins the codex Bedrock region or blanks the custom-endpoint Bedrock vars **overrides** the conf value (running it *before* the source would let the conf clobber it — the [P1] bug #222 review caught: the region pin / blanking was ineffective on configured boxes); (d′) **clear an inherited launcher for a custom-endpoint entry** (sub-rule 7) — done *after* env-setup because the custom-endpoint signal (`ANTHROPIC_BASE_URL`) is only known once env-setup has run; (e) `smoke_retokenize_launcher` — `run_agent` reads the pre-tokenized `AGENT_LAUNCHER_ARGV[]`, so an `AGENT_LAUNCHER` set in env-setup is honored only after this re-tokenize (malformed value → empty argv + WARN, never aborts). `AGENT_CMD` / `AGENT_TIMEOUT` / `AGENT_DEV_EXTRA_ARGS` are re-read per `run_agent` invocation and need no re-tokenize. This is the same conf-re-source clobber that [INV-37](#inv-37-per-side-agent_cmd-precedence) / [INV-38](#inv-38-per-side-agent_launcher-precedence) fix wrapper-side (the rebind must land *after* the lib source).

7. **An inherited shared `AGENT_LAUNCHER` is NEUTRALIZED for a non-claude entry (the launcher is a claude-only contract).** `AGENT_LAUNCHER` is claude-only ([INV-22](#inv-22-agent_launcher-tokenization--claude-only-invocation-contract) / [INV-38](#inv-38-per-side-agent_launcher-precedence)): the canonical `cc` launcher ends in `$CLAUDE_CMD "$@"`, so prepending it to a `codex` / `kiro` / `agy` command yields e.g. `cc codex exec …` which fails. When the operator's `autonomous.conf` sets a shared `AGENT_LAUNCHER` (the documented Bedrock-claude shape), it is inherited into every smoke entry's subshell; left in place it would prepend the claude launcher to a non-claude CLI and the smoke would record a **false `FAIL`**, blocking the PR gate on a healthy non-claude CLI. So `_run_entry` clears `AGENT_LAUNCHER` for any entry whose `agent_cmd != claude` **after** the lib source but **before** env-setup — so the entry's `env-setup` can still opt INTO a CLI-specific launcher (an `export AGENT_LAUNCHER=…` in env-setup runs after the clear and is preserved by the sub-rule 6(e) re-tokenize). A claude entry keeps the inherited launcher unchanged.

**Custom-endpoint carve-out (#222 [P1] review).** A claude entry that points at a **custom Anthropic-compatible endpoint** (env-setup sets `ANTHROPIC_BASE_URL` and blanks the Bedrock vars — e.g. the `claude-minimax` example) is still `agent_cmd=claude`, so the non-claude clear above does NOT fire and the inherited shared **Bedrock-specific** `cc` launcher survives — it would reintroduce Bedrock env (or fail) **before** the custom endpoint is exercised, a **false `FAIL`** on a healthy custom setup. So `_run_entry` ALSO clears the launcher **after** env-setup for any entry that turned on a custom endpoint (`ANTHROPIC_BASE_URL` non-empty), but ONLY when env-setup did **not** itself set a launcher (the live `AGENT_LAUNCHER` is byte-identical to a pre-env-setup snapshot — an entry that deliberately `export AGENT_LAUNCHER=…`'d its own keeps it). The committed `e2e.conf.example` custom-endpoint entry ALSO clears it explicitly (`export AGENT_LAUNCHER=`) as belt-and-suspenders.

This mirrors the production wrapper's [INV-38](#inv-38-per-side-agent_launcher-precedence) per-side guard (a non-claude side rejects a blanket launcher), applied per-entry in the smoke matrix.

8. **An inherited `AGENT_DEV_EXTRA_ARGS` is NEUTRALIZED for EVERY entry (the extra-args are CLI-specific).** `run_agent` tokenizes `AGENT_DEV_EXTRA_ARGS` (the fresh-session var; `smoke_agent` always uses `run_agent`, never `resume_agent`/`AGENT_REVIEW_EXTRA_ARGS`) and appends it to **every** CLI branch's argv. The operator's `autonomous.conf` tunes it for **one** CLI — e.g. `--trust-all-tools` (kiro) or `--approval-mode yolo --output-format stream-json` (gemini). Those flags are CLI-specific: feeding kiro's `--trust-all-tools` to a `codex` / `claude` / `agy` smoke entry makes that CLI reject the unknown flag and the smoke records a **false `FAIL`** even though the CLI is healthy. **Unlike the launcher (claude-only, sub-rule 7), there is no single CLI the shared value is correct for**, so `_run_entry` clears `AGENT_DEV_EXTRA_ARGS` for **all** entries **after** the lib source but **before** env-setup. An entry that genuinely needs flags opts in via its own `env-setup` (`export AGENT_DEV_EXTRA_ARGS=…`), which runs after the clear and is preserved (and is re-read per `run_agent` invocation, so no re-tokenize is needed). This is the [INV-31](#inv-31-operator-tunable-per-cli-flags-live-in-conf-not-in-lib-agentsh) "per-CLI flags live in conf" mechanism, scoped per-entry in the smoke matrix.

**Why**: this repo's PRs routinely change `lib-agent.sh` and the per-CLI invocation branches, but nothing executed the real CLIs end-to-end before merge. Unit tests stub the CLIs, so the launch → auth → model chain was never exercised. Three past incidents an agent smoke would have caught **at PR time**: codex fan-out members dropped `unavailable` on every review due to a `BEDROCK_AWS_REGION` env pollution (#180 root cause), agy silent exit-0 with no model call on a quota wall (#205), kiro auth/login token expiry (#215). "Can it run" is the bar.

**Producer**: `lib-agent-smoke.sh` — `smoke_agent` (the production-chain probe + three-state rc), `_smoke_classify` (the pure `STATE|reason` decision), `_smoke_stdout_has_nonce` (TTY-sanitized stdout-only nonce check), `_smoke_nonce` (CSPRNG nonce), `_smoke_session_id` (valid-UUID session id for claude's `--session-id`), `_smoke_prompt`, `smoke_retokenize_launcher`. `tests/e2e/run-agent-smoke.sh` — the matrix parser, `require:` SKIP directive, the launcher / extra-args neutralization, parallel fan-out, three-state+SKIP aggregation, `SMOKE-SUMMARY`, and the `SMOKE_STUB` self-test.

**Consumer**: the harness aggregation; this repo's own command-mode E2E lane ([INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent)) when the operator flips `E2E_COMMAND`; and a follow-up review-wrapper Phase-A.5 pre-fan-out gate (out of scope for this PR). The lib is deliberately **wrapper-free** (no GitHub calls, no wrapper-specific state) so the Phase-A.5 consumer can adopt it unchanged.

**Status**: **ENFORCED** (closes #222).

**Test**: `tests/unit/test-lib-agent-smoke.sh` — TC-AGENT-SMOKE-001..013 (three-state `_smoke_classify` rc mapping: nonce echo → PASS; truncated nonce → FAIL; agy quota fixture → UNAVAILABLE; kiro auth fixture → FAIL; codex stream-error fixture → UNAVAILABLE; non-timeout no-signal → FAIL; **bare timeout 124/137 (no scraper signal) → UNAVAILABLE** ([INV-67](#inv-67-a-bare-smoke-timeout-rc-124137-with-no-authconfig-signal-classifies-unavailable-not-fail) / #246: TC-AGENT-SMOKE-007a/c/g/h + 008b + the hanging-stub end-to-end 007d → rc 2; **proven to FAIL against the pre-#246 FAIL branch**); **timeout WITH an auth/config scraper signal → FAIL** (ordering preserved: 008c kiro-auth, 008d codex-config); **agy-timeout-with-quota-in-log → UNAVAILABLE (env wins)**; bad-args → FAIL), TC-AGENT-SMOKE-009 (nonce uniqueness incl. a 200-iteration tight loop), TC-AGENT-SMOKE-038 (**the #222 [P1] valid-UUID session id**: `_smoke_session_id` is a canonical 8-4-4-4-12 lowercase-hex UUID, distinct per call, 200 tight-loop ids all valid + distinct, the uuidgen / urandom-construct / last-resort fallback branches each yield a valid UUID, and source-of-truth that `smoke_agent` mints `session_id` via `_smoke_session_id` not a non-UUID `smoke-<agent>` string), TC-AGENT-SMOKE-039 (**the #222 [P1] r1 stream separation**: the nonce on STDERR only [stdout empty] → NOT PASS / `no-response` FAIL; the same nonce on STDOUT → PASS [stream is what matters]; end-to-end a CLI that echoes the prompt to STDERR + exits non-zero → FAIL not a false PASS — **proven to FAIL against the pre-fix `2>&1` capture**; source-of-truth that `smoke_agent` captures stderr to a separate file and never merges `2>&1` into the nonce-check stdout), TC-AGENT-SMOKE-045 (**the #222 [P1] r2 successful-exit gate**: the nonce on STDOUT but a non-zero `run_agent` exit → NOT PASS / `no-response` FAIL [classify-level + end-to-end with a stdout-echo-then-exit-3 stub] — **proven to FAIL against the pre-fix rc-less PASS branch**; identical stdout with rc 0 → PASS), TC-AGENT-SMOKE-046 (**the #222 [P2] timeout normalization**: a SUFFIXED timeout `5s` → PASS [no `5ss`] — **proven to FAIL against the pre-fix `${timeout_s}s`**; a bare `5` → PASS [`s` appended]; a unit `2m` → PASS [verbatim]), TC-AGENT-SMOKE-047 (**the #222 operator-review [BLOCKING] kiro-tty-decoration**: a committed `kiro-tty-decoration.fixture` whose token carries a BEL [`0x07`] + ANSI CSI wrapping — raw `grep` misses it [047a], `_smoke_stdout_has_nonce` recovers it [047b], `_smoke_classify kiro 0 …` → PASS [047c, **proven to FAIL against the pre-fix raw grep**], the SAME decorated stdout + non-zero exit still → NOT PASS [047d, rc gate composes], + source-of-truth the PASS branch routes through the sanitizing helper [047e-g]), TC-AGENT-SMOKE-048 (**the sanitize helper is SIGPIPE-immune under `set -o pipefail`**: a nonce EARLY in >64 KB of stdout → `_smoke_stdout_has_nonce` rc 0 + `_smoke_classify … 0 …` → PASS — **proven to FAIL against a trailing-`grep -q` pipe form** [the capture-then-glob avoids the early-exit SIGPIPE that would otherwise rc-141 a real match into a false `no-response` FAIL]), TC-AGENT-SMOKE-010 (`set -euo pipefail` discipline, command-subst + bare), the `smoke_agent` end-to-end cases through the **real `run_agent`** with stubbed CLIs (PASS/FAIL/agy-UNAVAILABLE/timeout), TC-AGENT-SMOKE-020..031 (matrix parser + aggregation: malformed → loud rc 1, empty → rc 1, all-PASS → 0, UNAVAILABLE-only → 0, one-FAIL → 1, `require:` SKIP/present, parallel wall-clock), TC-AGENT-SMOKE-040..043 (the `SMOKE_STUB=1` full-harness self-test — the E2E artifact), TC-AGENT-SMOKE-032..036 (**the #222 [P1] env-setup-last-writer + launcher-neutralize fixes**: an env-setup `BEDROCK_AWS_REGION` override beats a conf value [via `AUTONOMOUS_CONF` pointed at a polluted temp conf]; an env-setup `unset` of a conf-set var survives the conf load [custom-endpoint blanking]; `smoke_retokenize_launcher` re-tokenizes an env-setup `AGENT_LAUNCHER` [valid → argv, malformed → empty + rc 0]; source-of-truth that the lib `source` precedes the env-setup `eval`, the launcher-neutralize sits between source and eval, and the launcher is re-tokenized after; **TC-036 the sub-rule 7 launcher-neutralize**: a non-claude entry with an inherited shared claude launcher PASSes [not a false FAIL] and the launcher probe does NOT run [neutralized] — proven to FAIL against the pre-fix harness; a claude entry PRESERVES the inherited launcher [probe runs]; a non-claude entry can still opt INTO a launcher via env-setup [probe runs]; **TC-037 the sub-rule 8 extra-args-neutralize**: a codex entry with an inherited kiro `--trust-all-tools` from conf PASSes [flag neutralized, not a false FAIL] — proven to FAIL against the pre-fix harness; a codex entry can still opt INTO its own extra-args via env-setup; **TC-035f/g the source-of-truth that the extra-args clear sits between the lib source and the env-setup eval**; **TC-044 the sub-rule 7 custom-endpoint launcher clear**: a claude custom-endpoint entry (`ANTHROPIC_BASE_URL` set) with an inherited shared Bedrock launcher PASSes + the launcher probe does NOT run [neutralized] — proven to FAIL against the pre-fix harness; a custom-endpoint entry can still opt INTO its own launcher via env-setup; TC-044d/e source-of-truth that the clear sits between the env-setup eval and the launcher re-tokenize), TC-AGENT-SMOKE-050..056 (source-of-truth: `bash -n`, lib calls `run_agent` + sets `AGENT_CMD`/`AGENT_TIMEOUT`, sources the three drop-reason libs by [INV-14](#inv-14-config-lookup-honors-symlink-vendor-pattern) BASH_SOURCE-relative path, CI shellcheck + stub self-test wiring, `.gitignore` covers `tests/e2e/e2e.conf`, example matrix covers the 5 CLI shapes with no committed secrets, docs present). Design: `docs/designs/agent-smoke.md`. Test plan: `docs/test-cases/agent-smoke.md`. Contract doc: `docs/pipeline/agent-smoke.md`.

> **Post-install / upgrade**: this PR **ADDS** `skills/autonomous-dispatcher/scripts/lib-agent-smoke.sh`. After merge + `npx skills update -g`, re-run `install-project-hooks.sh` on every onboarded project (CLAUDE.local.md → Post-merge Step 2) or a wrapper that later sources the new lib (via the Phase-A.5 follow-up) would crash on the missing per-file symlink. `tests/e2e/run-agent-smoke.sh` is NOT a dispatcher `source` target (it is invoked as a command), so it needs no symlink.

**Cross-references**:
- [INV-58](#inv-58-agy-quota--auth-drops-surface-a-distinct-reason-not-an-opaque-unavailable) / [INV-61](#inv-61-kiro-auth-drops-surface-a-distinct-reason-not-an-opaque-unavailable) / [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) — the per-CLI drop-reason scrapers `_smoke_classify` reuses.
- [INV-34](#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element) — the stdin prompt channel the smoke exercises through `run_agent`.
- [INV-50](#inv-50-agy---model-is-validated-against-agy-models-wrapper-side-unknown-ids-are-omitted-not-forwarded) — the agy `--model` validation the smoke exercises for an agy entry.
- [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) — the command-mode evidence parser the `SMOKE` / `SMOKE-SUMMARY` lines feed when this repo runs the matrix as its own PR E2E.
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the `unavailable`-tolerance model UNAVAILABLE mirrors.
- [INV-13](#inv-13-wall-clock-cap-on-agent-invocations) — the `AGENT_TIMEOUT` bound the smoke's short override validates against.
- [INV-37](#inv-37-per-side-agent_cmd-precedence) / [INV-38](#inv-38-per-side-agent_launcher-precedence) — the same `autonomous.conf` re-source clobber (a rebind/override must land *after* the lib source) that sub-rule 6's env-setup-last-writer ordering addresses for the smoke harness.

## INV-64: the review wrapper smokes every fan-out member before the fan-out (Phase A.5); FAIL aborts the review, UNAVAILABLE drops the member, PASS proceeds

_Triage (issue #236): [machine-checked: tests/unit/test-lib-review-smoke.sh, tests/unit/test-autonomous-review-smoke-gate.sh]_

**Rule**: when `REVIEW_SMOKE_ENABLED=true`, `autonomous-review.sh` runs a pre-fan-out **agent-smoke gate (Phase A.5)** — positioned AFTER the [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) E2E lane (Phase A) and BEFORE the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) review fan-out (Phase B) — that smokes EVERY `REVIEW_AGENTS_LIST` member via [INV-63](#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path)'s `lib-agent-smoke.sh::smoke_agent` and applies three-state semantics to decide whether — and with which members — the fan-out runs:

- **PASS** (smoke rc 0) → the member proceeds to the fan-out.
- **UNAVAILABLE** (smoke rc 2 — quota/capacity) → the member is dropped from the fan-out set with drop reason `smoke: <classified reason>`, exactly mirroring the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) `unavailable` tolerance; the remaining members fan out and vote. ALL members UNAVAILABLE → the existing all-unavailable fallback path (the list is left UNCHANGED and falls through — every member runs the fan-out, posts no verdict, resolves `unavailable`, and the INV-40 all-unavailable aggregate fires — the legacy review-crash terminal state, unchanged; a single-agent project whose one member is UNAVAILABLE reaches this same state).
- **FAIL** (smoke rc 1 — config/launch error) → **ABORT the entire review loudly**: no fan-out, no verdict; the issue **stays `reviewing`** (NO `pending-dev` flip); the wrapper posts an issue comment naming the failed agent(s) + their `SMOKE …` evidence line(s) and exits **non-zero**.

1. **Same launch path the fan-out uses — model, launcher, AND extra-args.** Each member's smoke resolves its model via `_resolve_review_agent_model` ([INV-41](#inv-41-per-agent-review-model--extra-args-resolution)), applies the [INV-38](#inv-38-per-side-agent_launcher-precedence) / [INV-42](#inv-42-per-agent-review-launcher-resolution) launcher treatment (a per-agent `AGENT_REVIEW_LAUNCHER_<AGENT>` opt-in else the INV-38 rule: non-claude → neutralized, claude → keeps the rebound `AGENT_LAUNCHER_ARGV`), AND resolves the per-agent review EXTRA-ARGS via `_resolve_review_agent_extra_args` ([INV-41](#inv-41-per-agent-review-model--extra-args-resolution)), assigning BOTH `AGENT_DEV_EXTRA_ARGS` (the var `smoke_agent`'s `run_agent` tokenizes) and the `AGENT_REVIEW_EXTRA_ARGS` alias — IDENTICAL to the fan-out's per-agent subshell — so the smoke exercises the exact launch chain the real review run would. The extra-args rebind is load-bearing (#224 review [P1]): without it the smoke's `run_agent` reads the STALE `AGENT_DEV_EXTRA_ARGS` (or the conf-default review args), not the resolved per-agent review args the fan-out uses — so the smoke could ABORT a healthy review agent (the dev args carry a flag the review CLI rejects) or PASS a member whose review-specific flags later fail the real review. A smoke PASS therefore certifies the same `(CLI, model, launcher, extra-args)` tuple the fan-out is about to run.

2. **FAIL is operator-side, NOT a PR defect — so abort + stay `reviewing`.** A smoke FAIL means a wrong model id / expired auth / region drift / a launcher that does not fit the CLI — a configuration error in `autonomous.conf`, not a problem with the PR. Two wrong alternatives this rule forbids: (a) silently shrinking the vote (dropping the FAILed member like an UNAVAILABLE one) would DISGUISE a config error as a quota wall and let a degraded fleet approve a PR; (b) flipping the issue to `pending-dev` would send the dev agent chasing a non-existent PR problem. **Abort + stay `reviewing`** matches the existing wrapper-startup-crash semantics: the wrapper exits non-zero with the `reviewing` label intact, and the dispatcher's [INV-24](#inv-24-review-wrapper-dead-detection-requires-both-pid_alive-miss-and-no-near-success-pr-signal) re-dispatch path re-runs the review on the next tick — which now passes once the operator fixes the config (self-heal). The abort sets `RESULT_PARSED=true` BEFORE exiting so the wrapper's `cleanup` EXIT trap (which flips `reviewing → pending-dev` on a non-zero exit when `RESULT_PARSED != true`) does NOT override the deliberate stay-`reviewing` decision. It emits a `failed-non-substantive` verdict trailer with cause `smoke-config-error` (a heartbeat-consistent exit, so INV-24 stale-detection treats the abort like other startup-abort paths — no false DEAD declaration mid-abort).

3. **Default-off, byte-for-byte unchanged when off.** `REVIEW_SMOKE_ENABLED` must be exactly `true` to enter Phase A.5; the default is `false`, so the block is not entered and the wrapper is byte-for-byte unchanged for every project that has not opted in. Rollout is per-project and individually revertible. `REVIEW_SMOKE_TIMEOUT_SECONDS` (default 120) is the per-member smoke wall-clock cap, validated at startup by `_is_positive_timeout_value` ([INV-13](#inv-13-wall-clock-cap-on-agent-invocations)) — a `0`/fraction/garbage value is a loud startup error, never a silently-disabled cap.

4. **Parallel, explicit-PID wait — never a bare `wait`.** The N members smoke in parallel, one backgrounded subshell each; the wrapper collects each subshell's PID into `_smoke_pids` and joins with `wait "${_smoke_pids[@]}"` — the COLLECTED PIDs only. A bare `wait` is forbidden (the same [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) sub-rule 1 / #167-class hang): it would also block on the long-lived `gh-token-refresh-daemon` and the heartbeat `sleep` loop (neither exits), hanging the wrapper forever after the smokes finish and stranding the issue in `reviewing`. Each subshell writes its three-state outcome + the `SMOKE …` evidence line to a per-member sidecar (`_classify_smoke_state` always returns 0; the state is on the sidecar, not in `$?`) — a missing sidecar (the subshell died before the write) is conservatively read as FAIL.

5. **The smoke is strictly before the fan-out clock.** Phase A.5 posts NO verdict comment, so it counts toward neither the INV-40 verdict-attribution window (actor + `WRAPPER_START_TS` + `Review Session` trailer) nor the per-agent verdict-poll window — both are downstream of the fan-out. The smoke's cost when enabled is N small LLM calls + up to ~`REVIEW_SMOKE_TIMEOUT_SECONDS` wall-clock (parallel, slowest member) per review.

6. **Three-state ↔ four-axis (#229 adapter spec).** PASS / UNAVAILABLE / FAIL is a projection of the adapter provider axis (`quota|auth → UNAVAILABLE`, `config → FAIL`). The classification stays inside `smoke_agent` and the per-CLI drop-reason scrapers it reuses ([INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) / [INV-61](#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) / [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback)), so when #232 moves per-CLI logic into adapters Phase A.5 keeps calling the same `smoke_agent` entry point and the refactor absorbs it with zero behavior change. The FAIL-abort comment adopts the #231 error-envelope format `{code, problem, cause, remediation}` once that lands (until then a plain structured comment is fine — NOT blocked on #231). Per-member `smoke` metric events are emitted via lib-metrics once #228 lands (a `TODO(#228)` marks the site).

**Why**: a misconfigured/broken fan-out member previously burned a full review run (the E2E lane + N parallel review agents + the verdict-poll window) before surfacing as an opaque `unavailable` drop — indistinguishable from a quota wall, so an operator could not tell "I broke the config" (must fix) from "an agent's daily quota is spent" (fine to drop). A cheap pre-fan-out smoke separates the two before any expensive review run starts, with an explicit drop reason for the quota case and a loud abort for the config case. (#224.)

**Producer**: `autonomous-review.sh` Phase A.5 block (the parallel-smoke orchestration + the three-branch cascade); `lib-review-smoke.sh` — `_classify_smoke_state` (run one member's smoke → state + evidence sidecars), `_classify_smoke_gate` (the pure FAIL > all-UNAVAILABLE > pass decision), `_smoke_evidence_reason` (extract the `reason=…` tail for the drop/abort breadcrumb). The probe is [INV-63](#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path)'s `lib-agent-smoke.sh::smoke_agent`.

**Consumer**: the fan-out (Phase B) runs over the surviving `REVIEW_AGENTS_LIST`; the dispatcher's [INV-24](#inv-24-review-wrapper-dead-detection-requires-both-pid_alive-miss-and-no-near-success-pr-signal) re-dispatch path consumes the FAIL-abort's stay-`reviewing` + non-zero exit (self-heal on the next tick); `classify_recent_review_verdict` consumes the `failed-non-substantive smoke-config-error` trailer.

**Status**: **ENFORCED** in this PR (closes #224).

**Test**: `tests/unit/test-lib-review-smoke.sh` — TC-REVIEW-SMOKE-001..011 (`_classify_smoke_gate` truth table incl. FAIL>all-UNAVAILABLE>pass precedence, degenerate single-agent, empty/unknown defensive), TC-REVIEW-SMOKE-020..025 (`_smoke_evidence_reason` extraction + no-over-claim), TC-REVIEW-SMOKE-030..033 (`_classify_smoke_state` rc→state mapping + evidence capture + set-e discipline). `tests/unit/test-autonomous-review-smoke-gate.sh` — TC-REVIEW-SMOKE-040..052 (source-of-truth: sourced, positioned after the E2E lane + before the fan-out, default-off gated, collected-PID wait, per-agent model/launcher resolution, FAIL-abort comment+trailer+`RESULT_PARSED`+no-pending-dev+exit-1+pre-fan-out, UNAVAILABLE-drop survivor rebuild, all-unavailable fall-through, no verdict post, conf knobs + startup validation), TC-REVIEW-SMOKE-060 (stub-mode decision cascade: mixed-fleet drop, FAIL abort, single-agent all-unavailable), TC-REVIEW-SMOKE-061 (doc presence). The whole-wrapper no-bare-`wait` pin is `test-autonomous-review-multi-agent.sh` TC-MAR-SRC-09c; the `emit_verdict_trailer` count rises to 11 (TC-MAR-SRC-12). Design: `docs/designs/review-smoke-gate.md`. Test plan: `docs/test-cases/review-smoke-gate.md`.

> **Post-install / upgrade**: this PR **ADDS** `skills/autonomous-dispatcher/scripts/lib-review-smoke.sh`. After merge + `npx skills update -g`, re-run `install-project-hooks.sh` on every onboarded project (CLAUDE.local.md → Post-merge Step 2) or the review wrapper crashes on the missing per-file symlink when it `source`s the new lib.

- [INV-63](#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path) — the `smoke_agent` probe + three-state contract Phase A.5 consumes.
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the fan-out + `unavailable`-tolerance + all-unavailable fallback the gate feeds.
- [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) — Phase A (E2E lane), which runs immediately before Phase A.5.
- [INV-41](#inv-41-per-agent-review-model--extra-args-resolution) / [INV-38](#inv-38-per-side-agent_launcher-precedence) / [INV-42](#inv-42-per-agent-review-launcher-resolution) — the per-agent model/launcher resolution the smoke mirrors.
- [INV-24](#inv-24-review-wrapper-dead-detection-requires-both-pid_alive-miss-and-no-near-success-pr-signal) — the dead-detection / re-dispatch contract the FAIL-abort's stay-`reviewing` self-heal relies on.

## INV-65: entry scripts resolve conf from the unresolved path and libs from the real skill-tree path (two-dir resolution)

_Triage (issue #236): [machine-checked: tests/unit/test-entry-point-resolution.sh, tests/unit/test-entry-point-startup-e2e.sh]_

**Rule**: Every dispatcher / wrapper **entry script** MUST compute TWO directories from its own `${BASH_SOURCE[0]:-$0}` and use each for a distinct purpose:

| Dir | Computed from | Used for |
|---|---|---|
| **CONF dir** (`SCRIPT_DIR`, or `_LIB_*_DIR`) | `dirname` of the **UNRESOLVED** `${BASH_SOURCE[0]:-$0}` (NOT `readlink -f`) | `load_autonomous_conf` / direct `autonomous.conf` lookup ([INV-14]); invoking the project-side `$PROJECT_DIR/scripts/dispatch-local.sh` the dispatcher hands the wrapper spawn to; and lib-auth's project-side `gh` wrapper symlink the agent calls via `bash scripts/gh` |
| **LIB dir** (`LIB_DIR`, or `_LIB_*_REAL_DIR`) | `dirname` of `readlink -f "${BASH_SOURCE[0]:-$0}"` (the REAL skill-tree path) | every `source "${LIB_DIR}/lib-*.sh"` of a sibling lib; AND invoking sibling **entry executables that themselves source a lib from their own dir** — `dispatcher-tick.sh`'s `dispatch()` runs `dispatch-remote-aws-ssm.sh` via `LIB_DIR` so that driver's `${BASH_SOURCE[0]%/*}/lib-ssm.sh` resolves in the skill tree (the installer no longer symlinks `lib-ssm.sh` project-side) |

`readlink -f` on a non-symlink is identity, so under direct invocation the two dirs coincide and behavior is unchanged. Under a project-side symlink, the CONF dir stays at `<project>/scripts/` (where `autonomous.conf` lives) while the LIB dir resolves into the skill tree (where the real `lib-*.sh` live). **Lib sourcing therefore stops consulting `<project>/scripts/` entirely — no per-project lib symlink is needed.**

**A sourced lib cannot recover the project's `scripts/` on its own.** Once an entry sources `lib-agent.sh` / `lib-auth.sh` via its `LIB_DIR`, those libs' own `${BASH_SOURCE[0]}` is the skill-tree path — so their conf lookup would miss the project's `scripts/`. The entry therefore **exports `AUTONOMOUS_CONF_DIR`** (its own UNRESOLVED `SCRIPT_DIR`) before sourcing them; the libs use `${AUTONOMOUS_CONF_DIR:-<own-unresolved-dir>}` for `load_autonomous_conf` (and, in lib-auth, for the project-side `gh` wrapper + project-side daemon spawn). When `AUTONOMOUS_CONF_DIR` is unset (direct/legacy sourcing) the libs fall back to their own unresolved dir, so [INV-14] holds on both paths.

**Why**: surfaced by #227. Pre-#227 every `lib-*.sh` required its own per-project symlink because entries sourced siblings via the project-side `SCRIPT_DIR`. When an upstream PR added a new lib (`lib-review-e2e.sh`, `lib-review-poll.sh`, `lib-review-mergeable.sh`, …), every consumer project's wrapper died on the first `source` of the missing file (`No such file or directory` → `set -e` exit), stranding the issue in `reviewing`/`in-progress` for hours until the operator re-ran `install-project-hooks.sh`. That was a documented operational hazard (the drift sibling of #153). [INV-65] removes the class **structurally**: lib sourcing no longer depends on per-project symlinks. The upcoming adapter refactor (which churns lib files) is the forcing function — it must land on this foundation.

**Backward compatible**: a project still holding pre-#227 per-lib symlinks keeps working unchanged — `readlink -f` follows each symlink to the same real lib, so `LIB_DIR` lands in the skill tree either way; the stale per-lib symlinks are simply never read (and `install-project-hooks.sh` prunes them).

**Producer**: the entry scripts (`autonomous-dev.sh`, `autonomous-review.sh`, `dispatch-local.sh`, `dispatcher-tick.sh`, `gh-token-refresh-daemon.sh`) and the two sibling-sourcing libs (`lib-agent.sh`, `lib-auth.sh`). `lib-config.sh` is unchanged — it never sources a sibling and never calls `readlink` (the #58 / [INV-14] contract is preserved verbatim; it consumes the CONF dir its caller passes).
**Consumer**: every wrapper/dispatcher invocation, and `install-project-hooks.sh`, which now symlinks ONLY the STABLE ENTRY manifest (everything that is NOT `lib-*.sh`, MINUS the two `*-aws-ssm.sh` helpers — those source `lib-ssm.sh` from their own dir and are invoked from the skill tree, so a project-side symlink to them would crash on the pruned `lib-ssm.sh`; #227 P1) and prunes stale non-manifest symlinks (`lib-*.sh` and `*-aws-ssm.sh`).
**Status**: **ENFORCED** in #227.
**Test**: `tests/unit/test-entry-point-resolution.sh` (TC-ENTRY-SHIM-001..012) drives the two-dir snippet under direct / symlinked / nested-symlink / `bash -c` invocation, pins the missing-lib-symlink regression (a new lib with NO project symlink still sources), and locks the source-level contract on the production scripts. `tests/unit/test-entry-point-startup-e2e.sh` (TC-ENTRY-SHIM-030) drives the real `autonomous-dev.sh` startup with NO project lib symlinks. `tests/unit/test-install-project-hooks.sh` covers the manifest-only symlink + prune + `--doctor` + `--dry-run`. `tests/unit/test-symlink-resolution.sh` TC-CONTENT-006/007 are updated to the two-dir contract (conf lookup uses the unresolved dir; `readlink -f` is allowed for the LIB dir but `readlink -f "$0"` conf-dir form stays banned).

**Cross-references**:
- [INV-14](#inv-14-config-lookup-honors-symlink-vendor-pattern) — the conf-lookup half this extends. INV-14's "Required symlink manifest" is superseded for `lib-*.sh`: only STABLE ENTRY scripts need symlinking now.
- [`dispatcher-flow.md` § install/topology](dispatcher-flow.md#pre-step-wrapper-exec-bit-self-heal-closes-97) — the consumer install topology updated for the manifest-only model.

## INV-66: adapter conformance is spec-defined

_Triage (issue #236): [machine-checked: tests/unit/test-adapter-spec-schemas.sh]_

**Rule**: the agent-CLI adapter boundary (dev + review + e2e) has a single
**normative** contract — [`adapter-spec.md`](adapter-spec.md) (`spec_version: 1`)
+ the four JSON Schemas under [`schemas/`](schemas/) — and any later adapter work
(adapter extraction, verdict-as-data channel, conformance fixture runner, env
scrubbing) **MUST implement that spec and MUST NOT redefine it**. The contract is
five artifacts, each written as RFC-2119 MUST/MUST-NOT clauses so a conformance
check maps 1:1 to a clause:

1. **The adapter interface with a mode axis** — `invoke(mode, prompt, model,
   session, timeout, env) → AdapterResult`, `mode ∈ { dev-new, dev-resume,
   review, e2e-browser }`. Modes differ **structurally** (codex dev = `codex exec
   --json` + thread-sidecar resume; codex review = `codex review` from a PR
   worktree, no resume, fail-closed `no-worktree` rc 70) — the spec states
   per-mode requirements, not one uniform invoke. (`prompt` is stdin-fed
   [INV-34](#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element)
   on every dev mode and every CLI's review mode **except** `codex review`, which
   has no stdin-prompt mode and takes the short gate prompt as its positional
   `[PROMPT]` argument — the one explicit Clause A2 carve-out, consistent with
   [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback).)
2. **The four-axis AdapterResult** — `process` (rc, signal, timedOut), `provider`
   (quota/auth/config/transient + evidence), `verdict` (valid/absent/malformed),
   `voteEligibility` (pass/fail/drop/timeout-veto/not-applicable). A flat failure
   enum is documented as **NON-conformant**. The two load-bearing rc mappings are
   worked examples in the spec **and the full §4.4 derivation is machine-enforced
   by Draft-07 conditionals**: (a) a non-review mode ⇒ `not-applicable`; (b)
   review + valid verdict ⇒ `pass`/`fail`; (c) review + no verdict
   (`absent`/`malformed`) + `timedOut:true` ⇒ `timeout-veto` (deciding FAIL,
   [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto)) — keyed off `timedOut` (not the rc), so EVERY timed-out review
   no-verdict result is covered; (d) review + no verdict + `timedOut:false` ⇒
   `drop` (`unavailable`, [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)). A separate Clause P1 consistency rule
   enforces the `timedOut = true` **iff** `rc ∈ {124,137}` biconditional (both an
   inconsistent `timedOut:true`+non-124/137-rc and a `timedOut:false`+rc-124/137
   are rejected). The schema also requires a non-empty `verdict.payloadRef` when
   `verdict.state = valid` (a `valid` verdict the wrapper/aggregator cannot locate
   is rejected) and a non-empty `provider.evidence` when `provider.class != none`
   (Clause PR1).
3. **The verdict artifact contract** (`schemas/verdict-artifact.schema.json`) —
   `schema_version`, PASS/FAIL (the schema enforces FAIL ⇔ ≥1 blocking finding
   **both directions** — non-empty `blockingFindings` forces FAIL, and FAIL
   requires `blockingFindings` `minItems:1`), blocking/non-blocking findings, an
   `evidence` object that folds the [INV-49](#inv-49-command-mode-e2e-may-feed-the-review-fan-out-a-structured-ac-coverage-artifact--optional-fail-safe) AC-coverage map and the
   [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) E2E report in as typed sub-objects (not parallel ad-hoc
   fences), plus run-id / agent / model. Atomic write (tmp + rename; readers
   ignore post-land writes).
4. **The conformance fixture manifest** (`schemas/fixture-manifest.schema.json`)
   — per-adapter × per-mode `{ adapter, mode, input, command, files, expect }`.
5. **The operator error envelope** (`schemas/error-envelope.schema.json`) —
   `{ class, code, problem, cause, remediation, doc, surface }`; an
   operator-actionable `class` (`config`/`auth`/`quota`, with `config` the
   omitted-default) MUST surface on the GitHub issue or as a dispatcher alert,
   never log-only. **The schema enforces this** via a conditional — a
   config-class envelope with `surface: "log-only"` is rejected at validation
   time; only `class: "transient"` may be `log-only` (making
   [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) / [INV-61](#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) drop-reason surfacing normative **and** machine-checkable).

**Why**: per-CLI handling is scattered across `case "$AGENT_CMD"` branches in
`lib-agent.sh` and the `lib-review-*.sh` special cases, and every contract exists
only as folklore + invariant prose. The redesign's later phases all assume this
spec exists — it is the single document they implement (#229). Writing it first,
as testable MUST clauses with golden/negative-validated schemas, prevents each
later phase from re-inventing (and subtly diverging on) the contract.

**Producer**: this PR (#229) authors the spec + schemas. Later adapter-extraction
PRs are the producers of *conformant adapters*; this invariant binds them to the
spec.
**Consumer**: a new CLI vendor / the next refactor builds against the spec; the
(follow-up) conformance runner consumes the fixture-manifest schema; the
aggregator's vote semantics ([INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)) are the `voteEligibility` axis the spec fixes.
**Status**: **SPEC ONLY — NOT YET ENFORCED in code.** This revision adds the
normative document + machine-checkable schemas + validation tests; it changes no
wrapper / `lib-agent.sh` behavior. Enforcement (a single adapter entry point that
returns a typed `AdapterResult`) is the explicit work of later phases that
implement this spec.

**Test**:
- `tests/unit/test-adapter-spec-schemas.sh` — TC-ADAPTER-SPEC-001..008: all four
  `*.schema.json` present + valid Draft-07; `adapter-spec.md` declares
  `spec_version: 1`; this INV-66 entry present; every example well-formed JSON;
  each schema has ≥2 golden examples; every golden validates and every
  documented negative is rejected (the three issue-mandated negatives: a flat
  failure enum missing the four axes, a verdict artifact without `schema_version`,
  an error envelope without `remediation`; plus the #229-review negatives: a
  config-class error envelope surfaced `log-only`, a timed-out rc-124/137
  no-verdict result mapped to `drop` instead of `timeout-veto`, a
  `verdict.state=valid` result with no `payloadRef`, a review-mode non-timeout
  no-verdict result mapped to `pass` instead of `drop`, a `verdict=FAIL` artifact
  with no blocking findings, a non-`none` provider class with empty `evidence`, a
  non-review mode that votes, a review+valid-verdict result mapped to `drop`, a
  review `timedOut:true` no-verdict result mapped to `drop` instead of
  `timeout-veto`, and an inconsistent `timedOut:true`+non-124/137-rc result).
  Runs under `python3 -m jsonschema` (full Draft-07) when available, else a `jq`
  structural fallback (required-keys + enum membership + the thirteen named
  negatives) so it passes in plain CI either way.
- `docs/test-cases/adapter-spec.md` — TC-ADAPTER-SPEC-NNN enumeration.

**Cross-references**:
- [`adapter-spec.md`](adapter-spec.md) — the normative spec this invariant points at.
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) / [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto) — the vote / timeout-veto the `voteEligibility` axis encodes.
- [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) / [INV-49](#inv-49-command-mode-e2e-may-feed-the-review-fan-out-a-structured-ac-coverage-artifact--optional-fail-safe) — the E2E report + AC-coverage sub-objects folded into the verdict artifact.
- [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) / [INV-61](#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) / [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) — the per-CLI provider classifications + codex-review structural mode the spec's mapping appendix records.

## INV-67: a bare smoke timeout (rc 124/137) with no auth/config signal classifies UNAVAILABLE, not FAIL

_Triage (issue #236): [machine-checked: tests/unit/test-lib-agent-smoke.sh, tests/unit/test-autonomous-review-smoke-gate.sh]_

**Rule**: in `lib-agent-smoke.sh::_smoke_classify`, a smoke that times out (`run_agent` rc `124`/`137`) with **no preceding auth/config scraper signal** classifies **UNAVAILABLE** (smoke `smoke_agent` rc 2), **not FAIL**. This refines the [INV-63](#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path) three-state contract: the "bare timeout → FAIL" of the original (#222) wording becomes "bare timeout → UNAVAILABLE". Consequence at the [INV-64](#inv-64-the-review-wrapper-smokes-every-fan-out-member-before-the-fan-out-phase-a5-fail-aborts-the-review-unavailable-drops-the-member-pass-proceeds) Phase A.5 gate: a timed-out member is **dropped** (drop reason `smoke: timeout …`) and the review **proceeds** on the survivors — instead of the prior FAIL that **aborted the entire review** (all fan-out members) and left the issue stuck in `reviewing`.

Sub-rules:

1. **Ordering preserved — the per-CLI scraper signals win over the bare-timeout rule.** `_smoke_classify`'s decision order is unchanged: (1) nonce PASS, (2) environmental scraper signal → UNAVAILABLE, (3) auth/config scraper signal → FAIL, (4) **bare timeout 124/137 → UNAVAILABLE** (this invariant — was FAIL), (5) other no-signal → FAIL. The scraper checks (steps 2/3) run **before** the timeout branch (step 4), so a timeout that DOES carry an `auth-failed` ([INV-61](#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable)) or `config-error` ([INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback)) signal STILL classifies **FAIL** — genuine operator-side config/launch breakage (wrong model id, expired auth, region drift, a launcher that does not fit the CLI) is unaffected. Only the **bare** timeout (no scraper signal) moved.

2. **The non-timeout no-response branch stays FAIL.** A **non-timeout** non-zero exit with no nonce and no recognizable signal (step 5, `no-response`) remains FAIL. Decision (the #246 judgment call, stated explicitly): a prompt non-zero exit is more plausibly a launch/config failure — a CLI that rejected a flag, failed to authenticate in a way no scraper recognized, or crashed at startup — than a capacity blip. A capacity / slow-start blip manifests as the process running long and being **killed by the timeout** (124/137), which is exactly the branch this invariant relaxes; a prompt exit is not that shape. Scoping the relaxation to the 124/137 timeout branch only keeps the genuine-config-break signal intact.

3. **Why UNAVAILABLE, not FAIL.** On a **Bedrock-backed CLI** (codex via IAM-role→Bedrock, or any model whose first-token latency is backend-capacity dependent) a bare smoke timeout is far more likely a transient backend slow-start / capacity blip than an operator config hang. It is the same environmental class as a quota wall ([INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) / [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) agy) or an auth drop ([INV-61](#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) kiro): environmental → drop, never a deciding veto. Promoting it to a deciding FAIL blocks every PR review whenever a single member's backend has a one-off slow tick.

4. **No gate code change — the propagation is automatic.** `lib-review-smoke.sh::_classify_smoke_state` already maps `smoke_agent` rc 2 → `unavailable`, and `_classify_smoke_gate` already treats `unavailable` as a dropped member (`fail` > `all-unavailable` > `pass` precedence, [INV-64](#inv-64-the-review-wrapper-smokes-every-fan-out-member-before-the-fan-out-phase-a5-fail-aborts-the-review-unavailable-drops-the-member-pass-proceeds)). So this `_smoke_classify` change flows through unchanged: one timed-out member → dropped + review proceeds; ALL members timed out → `all-unavailable` (the existing [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) terminal path, **no empty fan-out spawned**).

5. **Distinct from the [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto) fan-out timeout-veto.** INV-48 makes a **fan-out review agent** killed by the per-side review wall-clock cap (124/137) with no posted verdict a `timed-out` **deciding FAIL** that vetoes the merge. That is a DIFFERENT path — a real review run that hit its 1h budget after producing no verdict, which must be loud — from this **pre-fan-out smoke** probe (a one-token capacity check). This invariant does NOT touch INV-48; the fan-out veto stays a deciding FAIL.

**Why**: observed in this repo's own self-review pipeline (#246). A `review` dispatch smoked `codex` and got `SMOKE codex FAIL 121s reason=timeout` → the Phase A.5 gate aborted the whole review (the healthy `agy` member never ran), and the issue sat in `reviewing` for ~8.5h with no live wrapper. The **same `codex` config** smoked **PASS in 9s** on a different review dispatch the same day, and codex fan-out members exited 0 on multiple other reviews that day — so codex was not misconfigured; the 120s timeout was a one-off backend slow-start. One member's transient slowness took down an entire multi-agent review and required manual recovery — exactly the FAIL→abort overreach this invariant fixes.

**Producer**: `lib-agent-smoke.sh::_smoke_classify` (the step-4 bare-timeout branch, now `UNAVAILABLE|timeout`).

**Consumer**: the [INV-64](#inv-64-the-review-wrapper-smokes-every-fan-out-member-before-the-fan-out-phase-a5-fail-aborts-the-review-unavailable-drops-the-member-pass-proceeds) Phase A.5 gate (`lib-review-smoke.sh::_classify_smoke_state` → `_classify_smoke_gate`), which drops the UNAVAILABLE member and proceeds; the [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) command-mode evidence parser when this repo runs the matrix as its own PR E2E (the `SMOKE … UNAVAILABLE … reason=timeout` line is non-blocking).

**Status**: **ENFORCED** (closes #246).

**Test**: `tests/unit/test-lib-agent-smoke.sh` — TC-AGENT-SMOKE-007a/007c (`_smoke_classify` rc 124/137, no signal → UNAVAILABLE — **proven to FAIL against the pre-#246 FAIL branch**), 007g (codex rc 124 empty capture → UNAVAILABLE, the motivating Bedrock-slow-start shape), 007h (kiro rc 137 empty capture → UNAVAILABLE), 008b (agy timeout + clean log → UNAVAILABLE), 008c/008d (**ordering preserved**: kiro timeout + `auth-failed` → FAIL, codex timeout + `config-error` → FAIL), 006a (non-timeout prompt non-zero exit, no signal → FAIL — `no-response` kept FAIL), 007d (hanging-stub end-to-end through real `run_agent` → `smoke_agent` rc 2 UNAVAILABLE). `tests/unit/test-autonomous-review-smoke-gate.sh` — TC-REVIEW-SMOKE-070..073 (gate propagation: timeout→`unavailable` state, one timed-out + one PASS → gate `pass` + survivor fans out, all timed out → `all-unavailable` no empty fan-out, genuine FAIL + timed-out member → gate `fail` abort preserved). Design: `docs/designs/smoke-timeout-unavailable.md`. Test plan: `docs/test-cases/smoke-timeout-unavailable.md`.

**Cross-references**:
- [INV-63](#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path) — the three-state contract this refines (the rc-1/rc-2 bullets + sub-rule 2 are amended to match).
- [INV-64](#inv-64-the-review-wrapper-smokes-every-fan-out-member-before-the-fan-out-phase-a5-fail-aborts-the-review-unavailable-drops-the-member-pass-proceeds) — the Phase A.5 gate whose drop/abort behavior this changes (UNAVAILABLE drop instead of FAIL abort for a bare timeout).
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) / [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) / [INV-61](#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) — the same environmental → drop tolerance this extends to a bare timeout.
- [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto) — the DISTINCT fan-out timeout-veto (a deciding FAIL) this invariant does NOT touch.

## INV-68: a routine re-dispatch preserves the prior run's per-issue log (single-generation rotation); only the INV-12 / INV-35 recovery branches truncate it deliberately

_Triage (issue #236): [machine-checked: tests/unit/test-dispatch-local-log-retention.sh]_

**Rule**: when `dispatch-local.sh` prepares the per-issue agent log for a `dev-new` / `dev-resume` / `review` spawn, it MUST **preserve the prior run's log content** rather than zeroing it. The mechanism is **single-generation rotation**: if `…-${ISSUE}.log` already exists, `mv -f` it to `…-${ISSUE}.log.1` (overwriting any older `.1` — bounded to one extra generation per `(issue, type)`), then create the fresh current log `0600`. The rotated `.1` is forced to `0600` too, so the prior run's (possibly secret-bearing) output never becomes world-readable across rotation. A first dispatch (no existing log) creates only the fresh `0600` current log — no `.1`.

The **only** code that may truncate the per-issue log is the deliberate recovery path:
- [INV-12](#inv-12-resume-only-against-unfinished-sessions) `prompt_too_long` — `dispatcher-tick.sh` does `: > "$_ptl_log"` so the next tick's terminal-state gate doesn't re-read a stale `result` line and dispatch dev-new forever.
- [INV-35](#inv-35-review-aware-resume-routing-for-completed-sessions) `failed-substantive` — `lib-dispatch.sh` does `: > "$_log_file"` for the same fail-closed reason.

Those recovery-truncates clear the **current** log only; they never touch `…-${ISSUE}.log.1`, so even on the recovery path the immediately-prior run's log survives in the rotated generation. INV-68 MUST NOT disable or weaken them.

**Why**: surfaced by #245. Pre-#245 `dispatch-local.sh` unconditionally zeroed the log via `install -m 600 /dev/null …log` on **every** dispatch (the `0600` hardening dates to #22; the truncate was a pure side effect — the wrapper redirects with `>>`). On a routine re-dispatch of the same issue (retry / resume / operator label flip) this destroyed the PRIOR run's stdout/stderr before the new run started. Observed in production: a review run on a consumer project aborted, the issue was re-dispatched ~4h later, and the second dispatch had already zeroed the log — the abort left **no recoverable evidence** and the stall had to be reconstructed from label timelines + comment archaeology. This is the **cheap tactical** mitigation; the strategic/durable fix is a per-run artifact directory (tracked separately, NOT a blocker, and explicitly out of scope here — this issue only changes how the existing `/tmp/agent-*.log` is (not) wiped on re-dispatch). (Landed as INV-68, after the smoke-timeout INV-67 (#246): several sibling PRs were in flight against the same `main`, so the final number was assigned at merge to avoid a duplicate-heading / broken-anchor collision.)

**Producer**: `dispatch-local.sh` — the `prepare_agent_log()` helper (rotate-then-create) in the log-prep block, applied to both the `dev-new|dev-resume` and `review` arms.
**Consumer**: any operator triaging a crashed/aborted run after a re-dispatch reads `…-${ISSUE}.log.1` for the prior run's evidence; the INV-12 / INV-35 recovery branches continue to truncate the current log only.
**Status**: **ENFORCED** in #245.
**Test**: `tests/unit/test-dispatch-local-log-retention.sh` (TC-LOGRET-1..8) drives the real `dispatch-local.sh` against a stub wrapper: seeds a sentinel in `…-{issue,review}-N.log`, re-dispatches, and asserts the sentinel survives in `…-N.log.1` (regression — fails before the fix); asserts the fresh current log AND the rotated `.1` are `0600`; asserts a first dispatch creates no spurious `.1`; asserts single-generation bound (no `.log.2`, `.1` holds the immediately-preceding run); asserts a symlinked current log does NOT let the rotation `chmod` follow through to the link target (CWE-59 guard — TC-LOGRET-8); and grep-asserts the INV-12 / INV-35 `: > "$log"` recovery-truncates survive (guard against an over-broad fix). Covers both the dev and review arms.

**Cross-references**:
- [INV-12](#inv-12-resume-only-against-unfinished-sessions) / [INV-35](#inv-35-review-aware-resume-routing-for-completed-sessions) — the deliberate recovery-truncates INV-68 preserves.
- [`dispatcher-flow.md` § per-issue agent log retention (INV-68)](dispatcher-flow.md#per-issue-agent-log-retention-inv-69) — runtime walkthrough.

## INV-69: a failed verdict post surfaces a distinct `post-failed` drop reason (CLI-agnostic), not a bare opaque `unavailable`

_Triage (issue #236): [machine-checked: tests/unit/test-lib-review-postfail.sh, tests/unit/test-post-verdict.sh]_

> **Note**: landed as **INV-69**, after the two sibling PRs that merged just ahead of it against the same `main` — INV-67 (smoke-timeout→UNAVAILABLE, #246) and INV-68 (re-dispatch log retention, #245). Several stability-redesign PRs were in flight concurrently, so the final number was assigned at merge to avoid a duplicate-heading / broken-anchor collision (sibling-first: the lower number goes to whichever lands first).

**Rule**: when a review fan-out member is resolved `unavailable` (no classifiable verdict comment within the poll window) AND its verdict post had failed at `gh` time, the wrapper attaches a distinct, actionable **`post-failed`** reason to the `WARNING: review agent(s) dropped (unavailable)` log line AND the posted "dropped agent(s)" issue comment (and the all-unavailable `log` line), rather than the bare opaque `unavailable`. The signal is a **breadcrumb** the deterministic verdict helper ([INV-56](#inv-56-review-verdict-is-posted-via-the-deterministic-post-verdict-helper-not-the-agents-bare-gh)) drops when its `gh issue comment` returns non-zero: `post-verdict.sh` writes `pid_dir_for_project()/verdict-postfail-<session_id>` (mode 0600, `issue=`/`agent=`/`session=`/`gh_rc=` lines) and STILL exits 1. The wrapper reconstructs that path from the agent's own session id (which it already holds in `AGENT_SESSION_IDS` — no fan-out-time capture array is needed, unlike the agy/codex/kiro per-CLI logs) and classifies via `lib-review-postfail.sh::_classify_postfail_drop_reason <session_id>`:
- breadcrumb present → **`post-failed[:gh-rc <n>]`** (the `gh` rc the post failed with, when recorded);
- breadcrumb absent → empty token → the bare `unavailable` wording is unchanged.

Because every CLI posts through the SAME `post-verdict.sh`, this detector is **CLI-agnostic** — it keys on a session id, not on a per-CLI log. It is evaluated **FIRST**, before the per-CLI [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) (agy) / [INV-59](#inv-59-codex-transient-stream-error-drops-surface-a-distinct-reason-and-are-ridden-out-by-the-resume-loop-not-opaquely-dropped) (codex) / [INV-61](#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) (kiro) scrapers: a confirmed post failure is the most specific cause, so it takes precedence; with no breadcrumb the agent falls through to the existing per-CLI branches unchanged. The breadcrumb is **best-effort** — a failure to write it (e.g. `pid_dir_for_project` cannot resolve) never changes the helper's exit code, which stays 1 on the underlying post failure. `_classify_postfail_drop_reason` / `_postfail_drop_reason_phrase` / `_postfail_breadcrumb_path` are `grep`-based, no `jq`, and **fail-safe**: a missing/empty/unreadable breadcrumb or empty session-id arg echoes empty and returns 0 (never aborts the `set -euo pipefail` wrapper — a non-zero `$(…)` in the `_dropped_reasons` append would crash mid-loop and strand the issue in `reviewing`).

**Deliberately NOT changed**: a `post-failed` agent is STILL dropped from the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) unanimous-PASS aggregation exactly as `unavailable` — it posted no classifiable verdict comment, so it cannot be a deciding vote. This is **observability only**, NOT a deciding FAIL and NOT a retry: the dispatcher re-dispatches on the next tick. `_classify_noverdict_agent` / `_aggregate_review_verdicts` are untouched.

**Why**: the explicitly-deferred follow-up from #202 / #247. [INV-56](#inv-56-review-verdict-is-posted-via-the-deterministic-post-verdict-helper-not-the-agents-bare-gh) made verdict posting reliable and had `post-verdict.sh` exit non-zero on a failed `gh issue comment` — but that exit code is observed by the *agent's* session, not the wrapper, so a transient GitHub/API/token error during the post still collapsed into the same opaque `unavailable` as an agent that never reviewed. The wrapper could not tell "reviewed but the post failed" from "never reached a verdict" — exactly the diagnostic gap the per-CLI INV-58/59/61 reasons close for CLI-specific failure modes, but for the (CLI-agnostic) post step that those scrapers structurally cannot see (the failure is after the CLI produced its review). Routing the signal through a breadcrumb the helper already has all the data to write — and keying it on the session id the wrapper already holds — surfaces the cause without new fan-out plumbing.

**Producer**: `post-verdict.sh` (writes the session-keyed breadcrumb on a failed `gh` post; sources `lib-config.sh` for `pid_dir_for_project`); `lib-review-postfail.sh` — `_postfail_breadcrumb_path`, `_classify_postfail_drop_reason` (presence + rc classify), `_postfail_drop_reason_phrase` (human rendering). `autonomous-review.sh` — calls the classifier on each `unavailable` agent's session id ahead of the per-CLI scrapers and folds the phrase into `_dropped_reasons`.

**Consumer**: the operator reading the wrapper log / the dropped-agent issue comment (the `post-failed (… gh rc N …)` reason). No consumer change to the [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) aggregation, the verdict poller, the E2E gate, or the dispatcher.

**N=1 / no-breadcrumb / signal-free carve-out (backward compatibility)**: an `unavailable` agent with no breadcrumb yields an empty token → the bare `unavailable` wording, then falls through to the per-CLI scrapers exactly as before; an agy member dropped for quota (no breadcrumb, agy log present) still surfaces its INV-58 reason. A successful post writes no breadcrumb. An all-unset / single-agent fleet is byte-for-byte equivalent in meaning to pre-INV-69.

**Status**: **ENFORCED** (closes #247).

**Test**: `tests/unit/test-lib-review-postfail.sh` — TC-PF-DET-01..06 (`_classify_postfail_drop_reason`: breadcrumb+rc → `post-failed:gh-rc 1`, breadcrumb no-rc → `post-failed`, absent → empty, unreadable/dir → empty, empty-arg → empty, no crash under `set -euo pipefail`), TC-PF-PHR-01..04 (`_postfail_drop_reason_phrase` rendering + empty/unknown passthrough), TC-PF-SRC-01..06 (source-of-truth: wrapper sources the lib, calls the classifier on `AGENT_SESSION_IDS`, runs it BEFORE the per-CLI branches, interpolates the reason into the dropped-agent comment, CI shellcheck lists the lib, `bash -n`), TC-PF-REG-01..03 (no-breadcrumb keeps bare wording + per-CLI fall-through; INV-40 vote unchanged; agy quota reason still surfaces when no breadcrumb). `tests/unit/test-post-verdict.sh` (extended) — TC-PF-BC-01..07 (breadcrumb written on a failed post with the right fields + 0600 mode, NO breadcrumb on success, pid-dir-unresolvable still exits 1, write-failure never changes the exit code, `bash -n` / `set -euo pipefail`). Test plan: `docs/test-cases/agy-postfail-reason.md`. Backward-compat gate: `test-autonomous-review-multi-agent`, `test-review-agent-timeout`, `test-lib-review-agy.sh`, `test-post-verdict.sh` stay green.

> **Post-install / upgrade**: this PR ADDS `scripts/lib-review-postfail.sh`. After merge + `npx skills update -g`, re-run `install-project-hooks.sh` on every onboarded project (see the project operator's post-merge steps) or the review wrappers will `source` a symlink that doesn't exist yet and crash on startup, stranding the issue in `reviewing`.

**Cross-references**:
- [INV-56](#inv-56-review-verdict-is-posted-via-the-deterministic-post-verdict-helper-not-the-agents-bare-gh) — the deterministic verdict helper whose non-zero `gh` exit this invariant gives the wrapper a channel to observe; the breadcrumb is written by that helper.
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the fan-out + `unavailable` definition this annotates; the aggregation/vote is unchanged (a post-failed agent stays dropped, not a deciding FAIL).
- [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) / [INV-59](#inv-59-codex-transient-stream-error-drops-surface-a-distinct-reason-and-are-ridden-out-by-the-resume-loop-not-opaquely-dropped) / [INV-61](#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) — the per-CLI drop-reason scrapers this CLI-agnostic detector runs AHEAD of (post-failure takes precedence); same `set -e`-safe rc-0-always contract, same `_dropped_reasons` assembly loop.
- [`review-agent-flow.md` § post-failed drop reason (INV-69)](review-agent-flow.md#post-failed-drop-reason-inv-70) — runtime walkthrough.

## INV-70: metrics emission is observe-only — silent-to-pipeline, loud-to-report

_Triage (issue #236): [machine-checked: tests/unit/test-lib-metrics.sh, tests/unit/test-metrics-report.sh]_

**Rule**: The metrics lane (`lib-metrics.sh::metrics_emit` and the events it appends to `metrics.jsonl`) is **purely observational**. A metrics-emission failure of ANY kind — unwritable state dir, missing `jq`, full disk, malformed input — MUST NOT change a wrapper/dispatcher **exit code**, **label transition**, **verdict**, or **merge decision**. Concretely:

- `metrics_emit` swallows every internal error and ALWAYS `return`s 0. It never aborts the caller, even under `set -e`.
- Every call site additionally appends `|| true` (belt-and-suspenders) and guards on `declare -F metrics_emit` so a wrapper whose `lib-metrics.sh` source failed simply skips emission.
- No pipeline control-flow decision (dispatch, retry, stale/DEAD declaration, verdict aggregation, auto-merge) may EVER read back a metrics value. Emission happens strictly AFTER the decision it records is made. This is the inverse of the redesign's later phases — for THIS subsystem, metrics are write-only from the pipeline's perspective ("observe-only forever", issue #228 out-of-scope).

The **report** half (`metrics-report.sh`) is the opposite: it is **loud** about gaps. Missing token data, a CLI with zero runs, a PR that never merged, an empty log — each is surfaced as an explicit `n/a` / count, never silently coerced to a zero that would hide a broken emitter.

**Event schema**: every line is a flat JSON object built exclusively with `jq -nc` (never hand-rolled `echo`), carrying a `schema_version` (currently `1`) so later redesign phases can add fields without breaking the aggregator (which ignores unknown event types and unknown fields). Storage is `<metrics_dir>/metrics.jsonl`, append-only (`>>`, O_APPEND — atomic for single-line records, no lock). `metrics_dir` resolves `${AUTONOMOUS_METRICS_DIR}` → `${XDG_STATE_HOME}/autonomous-<project>` → `${HOME}/.local/state/autonomous-<project>` (the `${XDG_STATE_HOME:-$HOME/.local/state}` contract). The fallback resolves **directly** to `$HOME/.local/state` and deliberately does NOT defer to `pid_dir_for_project`, which prefers the volatile `${XDG_RUNTIME_DIR}` tmpfs — metrics need **durable** retention, PID files don't, so they resolve differently. Retention is built into the collector: the dev + review wrappers prune once per run at `wrapper_end` and the dispatcher prunes once per tick (`metrics_prune ${METRICS_RETENTION_DAYS:-90}`, best-effort). The full event-type catalogue + failure-class taxonomy lives in [`metrics.md`](metrics.md).

**Failure-class taxonomy** (one enum, aligned with the redesign's factory classification): `verdict-absent`, `verdict-malformed`, `agent-unavailable(:quota|:auth|:config|:transient)`, `false-stall`, `label-race`, `infra`.

**Why**: the stability redesign gates its expensive phases on a measured incident-rate threshold ("if P1+P3 hold the rate under N/month for 8 weeks, later phases are cancelled"). Without a baseline measured BEFORE the first redesign phase ships, the stop-rule is unfalsifiable. But a measurement substrate that could itself crash the pipeline would be worse than none — so the observe-only contract is load-bearing: instrumenting the live dev/review wrappers + dispatcher is only safe because a metrics bug can never strand an issue. (#228)

**Producer**: `lib-metrics.sh::metrics_emit`, called from `autonomous-dev.sh` (wrapper_start/end, token_usage, pr_opened), `autonomous-review.sh` (wrapper_start/end, verdict, agent_drop, merge), and `dispatcher-tick.sh` (issue_labeled, dispatch_stale, dispatch_retry). Each call site is guarded + `|| true`.
**Consumer**: `metrics-report.sh` (the only reader); downstream, the redesign's stop-rule / obsolescence checkpoint / per-CLI value-accounting. NOTHING in the pipeline control flow consumes a metrics value.
**Status**: **ENFORCED** in #228.
**Test**: `tests/unit/test-lib-metrics.sh` (TC-METRICS-001..023, 060..062) covers JSON validity incl. quotes/newlines/shell-metachars, numeric coercion, the unwritable-dir + jq-absent observe-only guarantee under `set -e`, the all-call-sites-`|| true` grep, token parsing (claude JSON + codex line), drop-reason→class mapping, and prune retention. `tests/unit/test-metrics-report.sh` (TC-METRICS-040..051) covers the aggregation math (month-boundary bucketing, cost p50/p90 with missing-token exclusion, per-CLI quota rate with zero-run div-by-zero guard, TTHW with missing endpoints, `--since`/`--project` filters, empty file). `tests/e2e/run-metrics-report.sh` (TC-METRICS-080, run by `tests/unit/test-metrics-report-e2e.sh`) synthesizes three months of events and asserts the four headline numbers exactly.

**Cross-references**:
- [`metrics.md`](metrics.md) — the event-type catalogue, field definitions, failure-class taxonomy, and `metrics-report.sh` output blocks.
- [INV-01](#inv-01-pid-file-naming) — the per-project PID dir (`pid_dir_for_project`). The metrics file does NOT co-locate with it: PID files prefer the volatile `${XDG_RUNTIME_DIR}`, metrics resolve to the durable `${XDG_STATE_HOME:-$HOME/.local/state}` instead.

## INV-71: run-event channel decision recorded, implementation gated

_Triage (issue #236): [design-rationale]_

**Rule**: The durable run-event channel that a *future* reconciler/lease design would consume is **decided** in [`docs/designs/run-event-channel-adr.md`](../designs/run-event-channel-adr.md), but is **NOT implemented**. The decision: lease/heartbeat **renewals stay local** (state dir, never a shared-quota GitHub channel — proven rate-limit-unsafe at fleet scale); sparse **lifecycle events** (start/verdict/merge/end) use **create-only issue/PR comments** (the only candidate viable in every auth × execution topology cell), with **GitHub check-runs rejected as a sole channel** (App-mode-only — a PAT cannot create check-runs). Labels stay **canonical** (a canonical run-ledger was evaluated and declined — review T1). No code in any wrapper, dispatcher, hook, label transition, verdict path, or merge decision changes on account of this ADR.

**Why**: Review consensus flagged the event channel as the load-bearing unknown of the gated reconciler phase. Committing reconciler design before measuring the channel would bake in a substrate that fails part of the fleet (check-runs need `checks:write`, comment-editing races itself, a local dir is invisible to a remote SSM dispatcher without a round-trip). The ADR settles the channel choice — with a measured comment-propagation lag (~3–5 s), measured check-run latency (~1.6 s), the step-by-step secondary-rate-limit arithmetic at N=25 concurrent runs, an idempotency-key scheme (§7.1) and a `(run_id, seq)` ordering contract (§7.2) — so that *if* the stop-rule gate opens, the decision is already made. It records the decision; it does not open the gate. (#237)

**Producer**: this ADR (documentation only). No runtime producer — the channel is unimplemented.
**Consumer**: the gated reconciler/lease phase (future). NOTHING in the current pipeline control flow consumes an event-channel value; the current durable signals remain [INV-03] (dev report comment), [INV-40] (verdict comment), and GitHub labels.
**Status**: **DECISION RECORDED, NOT YET IMPLEMENTED** (gated on the #228 metrics-baseline stop-rule; the phase — and this channel — is cancelled if the baseline shows sufficient stability).
**Test**: N/A (no behavior). The ADR's empirical grounding is the throwaway `docs/designs/measure-event-channels.sh` (ShellCheck-green, `--dry-run` offline test) and the doc-quality gates in `docs/test-cases/run-event-channel-adr.md` (TC-EVCH-001..022).

**Cross-references**:
- [`docs/designs/run-event-channel-adr.md`](../designs/run-event-channel-adr.md) — the full ADR (candidate analysis, topology matrix, auth matrix, rate-limit math, run-ledger verdict, flip conditions, stop-rule).
- [INV-29] heartbeat (local file touch — the renewal signal stays here), [INV-70] metrics observe-only (the local JSONL the ADR's C3 candidate generalizes; also the `label-race` failure class the run-ledger question weighs), [INV-24] DEAD cross-check (the dead-detection latency `L_dead` the cadence table tunes).

## INV-72: config-class failures MUST surface on the issue, never log-only

_Triage (issue #236): [machine-checked: tests/unit/test-lib-error-envelope.sh, tests/unit/test-lib-agent-binary-preflight.sh]_

**Rule**: a **config-class** wrapper/dispatcher failure (every
operator-actionable `provider.class` — `config`, `auth`, `quota`) **MUST**
surface an [error envelope](schemas/error-envelope.schema.json) on the GitHub
issue (`surface: issue-comment`) or — when there is no per-issue context (a
tick-global dispatcher abort) — as a dispatcher alert (`surface:
dispatcher-alert`). It **MUST NOT** be log-only. Only an explicit
`class: transient` (a retryable blip the dispatcher re-dispatches automatically)
may be `surface: log-only`. This makes [INV-66](#inv-66-adapter-conformance-is-spec-defined)
Clause E2 enforced at the wrapper boundary, not just in the schema.

The envelope is rendered + surfaced by `lib-error.sh`:
- `error_envelope <code> <problem> <cause> <remediation> [doc] [class]` renders
  the single canonical format used for BOTH the log line and the comment body —
  a human block plus an embedded machine-readable
  `<!-- adt-error-envelope: {json} -->` marker. The JSON conforms to
  `error-envelope.schema.json` (built with `jq -nc`, so special characters in
  `cause`/`remediation` are safe). It rejects (rc 1, emits nothing) a
  non-`UPPER_SNAKE` `code` (Clause E3) or an empty `remediation` (Clause E1).
- `error_surface <issue|-> <code> <problem> <cause> <remediation> [doc] [class]`
  renders AND posts the envelope via the **token-refresh `gh` proxy** — it
  prefers the project-side `${AUTONOMOUS_CONF_DIR}/gh` symlink (the identity-
  correct path [`post-verdict.sh`](../../skills/autonomous-dispatcher/scripts/post-verdict.sh)
  uses, [INV-56](#inv-56-review-agents-post-their-verdict-through-post-verdictsh-not-a-hand-rolled-gh-comment))
  and **falls back to the co-located `gh-with-token-refresh.sh`** in its own
  skill-tree dir so a validation that aborts *before* `setup_github_auth` has
  materialized the symlink (a fresh install; a source-time launcher guard) still
  POSTS rather than degrading to log-only. It never falls back to bare PATH `gh`
  (that would mis-attribute the comment). The target repo is `REPO` /
  `GITHUB_REPO`, **falling back to `${REPO_OWNER}/${REPO_NAME}`** so an
  `ADT_CFG_MISSING_KEY` envelope for a missing `REPO` still resolves a `--repo`
  and posts (the wrappers call `error_surface` before `cd "$PROJECT_DIR"`, so a
  `gh --repo ""` could not infer the repo from a checkout). It **decides the
  effective surface before rendering** and pins it into the marker JSON, so a
  `dispatcher-alert` envelope reads `"surface":"dispatcher-alert"` (not the
  class-default `issue-comment`). It writes the full envelope to the wrapper log
  on **every** path — including the success path — so "the same envelope to the
  log AND the issue" holds whether or not the post landed. It is
  **best-effort**: if the post fails (or the proxy is unresolvable, or
  `class=transient`, or the issue is empty/`-`) it degrades to log-only and
  **returns 0 regardless** — surfacing failure MUST NOT change the caller's exit
  code. A `class=transient` envelope is never posted.

**Both wrappers run their config validations BEFORE the authoritative arg-parse
loop, yet still surface on the issue.** An early, non-destructive
`error_peek_issue_arg "$@"` scan (in `lib-error.sh`) populates `ISSUE_NUMBER` up
front, so every wrapper startup validation — the required-key / app-creds /
token-mint / `E2E_MODE` / timeout / `REVIEW_BOTS` checks AND the `lib-agent.sh`
launcher guards (which fire at source-time, with the wrapper's `"$@"` in scope)
— calls `error_surface "$ISSUE_NUMBER" …` and targets the issue when one was
passed, falling back to `dispatcher-alert` only on manual misinvocation with no
`--issue`. (A *source-time* launcher envelope may still degrade to log-only in
GitHub-App mode because the token is not minted until `setup_github_auth`; token
mode posts.) The **dispatcher** preflights its required keys (`REPO` /
`REPO_OWNER` / `PROJECT_ID` / `PROJECT_DIR`) *before* sourcing `lib-dispatch.sh`
— that library has top-level `${VAR:?}` guards that would raw-abort the tick
before the envelope helper ran — so a missing dispatcher key produces
`ADT_CFG_MISSING_KEY`, not an opaque `: REPO: parameter null or not set`.

**The resolved agent CLI binary is preflighted before launch/resume.**
`lib-agent.sh::preflight_agent_binary` (called at the top of both `run_agent`
and `resume_agent` — **and** at the top of the codex review lane
`lib-review-codex.sh::_run_codex_review`, which launches `codex review`
*directly* via `_run_with_timeout`, bypassing run_agent/resume_agent) confirms
the binary the wrapper will actually exec is on `PATH` *before* it launches it,
so a missing CLI surfaces an `ADT_CFG_AGENT_BINARY_MISSING` envelope via
`error_surface "$ISSUE_NUMBER"` instead of failing through as an opaque rc 127 /
generic session failure (or, in the codex review fan-out, a dropped-`unavailable`
review agent with no operator envelope). The launch binary is `AGENT_CMD` itself
for most CLIs, but `kiro-cli` when `AGENT_CMD=kiro` (the wrapper's one alias).
When a launcher is configured (`AGENT_LAUNCHER_ARGV` non-empty) the preflight
**stands down** — the launcher owns binary resolution and a misconfigured
launcher is already its own config-class abort (INV-38 / `ADT_CFG_LAUNCHER_*`).

Each config-class abort path carries a **stable `UPPER_SNAKE` code** documented
in the append-only registry [`errors.md`](errors.md) (codes never renumber). The
**dispatcher Step-5 stale handler** ([`dispatcher-flow.md`](dispatcher-flow.md))
checks the issue for a recent `<!-- adt-error-envelope: … -->` marker before
posting its generic "Task appears to have crashed" message; when one is present
it links the surfaced `code` + `remediation` instead, so a config crash is not
misreported as a transient crash that burns retries.

**Why**: today's fail-loud is log-only in every config-class startup abort path
(#231). A wrapper that aborts at startup (bad conf, missing app creds,
token-mint failure, invalid `E2E_MODE`, launcher/CLI mismatch per
[INV-38](#inv-38-per-side-agent_dev_launcher--agent_review_launcher-only-with-claude))
leaves the issue stuck in `reviewing`/`in-progress` with **zero GitHub-visible
signal** — the operator discovers it hours later by log spelunking, the exact
silent-stall UX the project exists to kill. The crux is **trap timing**: these
validations abort *before* `trap cleanup EXIT` is installed, so the wrappers'
existing crash-recovery comment path never runs for them.

**Producer**: every config-class abort path in `autonomous-dev.sh`,
`autonomous-review.sh`, `dispatcher-tick.sh`, and the shared libs
(`lib-agent.sh` launcher guards + the `preflight_agent_binary` missing-binary
check in `run_agent`/`resume_agent`) — each calls `error_surface "$ISSUE_NUMBER"`
(issue context from the early `error_peek_issue_arg` scan, or `-` → dispatcher
alert) before its existing `exit 1`.
**Consumer**: the operator reading the issue; the dispatcher Step-5 stale handler
reading the `adt-error-envelope` marker.
**Status**: ENFORCED. Transient-class failures (agent-exit retries, fan-out
drops, idle gates, SIGTERM handoff) are explicitly NOT changed — envelopes are
for config-class failures only.

**Test**:
- `tests/unit/test-lib-error-envelope.sh` — TC-ERR-ENVELOPE-001..022: envelope
  rendering (defaults, classes, doc, special chars), Clause E1/E3 rejection,
  schema conformance of the rendered marker (python3 jsonschema / jq fallback),
  `error_surface` posting via a stubbed proxy, post-failure / missing-proxy /
  dispatcher-alert / transient degradation (rc unchanged, no post for
  transient — the regression pin), the code-registry drift guard (every emitted
  code exists in `errors.md`), and this INV-72 entry's presence.
- `tests/unit/test-lib-agent-binary-preflight.sh` — TC-BINPF-STATIC +
  TC-BINPF-001..006: the `lib-agent.sh` missing-binary preflight. A static pin
  that `preflight_agent_binary || return` is wired into BOTH `run_agent` and
  `resume_agent` and that `ADT_CFG_AGENT_BINARY_MISSING` is emitted + documented;
  behavioral cases (stubbed proxy + controlled `PATH`) that a missing binary
  surfaces the envelope and returns 1, a present binary returns 0 with no post,
  `AGENT_CMD=kiro` resolves `kiro-cli` (not `kiro`), a configured launcher skips
  the preflight, and an empty `ISSUE_NUMBER` degrades to a dispatcher-alert
  (log-only, no `gh` post). TC-BINPF-CODEX pins the codex REVIEW lane: a static
  check that `_run_codex_review` (`lib-review-codex.sh`) wires
  `preflight_agent_binary || return`, plus a behavioral case that with
  `AGENT_CMD=codex` and no `codex` on `PATH`, `_run_codex_review` surfaces the
  envelope on the issue and returns non-zero WITHOUT launching codex (the
  review-lane bypass the run_agent/resume_agent preflight alone did not cover).

**Cross-references**:
- [INV-66](#inv-66-adapter-conformance-is-spec-defined) — the spec (Clause E1/E2/E3) this enforces at the wrapper boundary.
- [`errors.md`](errors.md) — the append-only error-code registry.
- [INV-56](#inv-56-review-agents-post-their-verdict-through-post-verdictsh-not-a-hand-rolled-gh-comment) — the token-refresh `gh` proxy resolution `error_surface` reuses.
- [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) / [INV-61](#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) — the existing distinct-reason drop surfacing this generalizes.

## INV-73: a codex review prompt-echo / startup-trace stdout is `malformed`, never a blocking `[P1]` FAIL — retry-or-drop, not a phantom veto

_Triage (issue #236): [machine-checked: tests/unit/test-lib-review-codex.sh, tests/unit/test-autonomous-review-multi-agent.sh]_

**Rule**: a `codex review` stdout capture that is codex's **own prompt + CLI startup trace echoed back** (the startup banner `OpenAI Codex vX.Y.Z` / a `workdir:`+`model:`+`provider:` header, followed by the verbatim review prompt — the inlined decision-gate rules, the `gh issue view` comment-history dump, and the issue body — truncated at the wrapper's char cap, with NO analysis and NO verdict) MUST be classified **`malformed`**, NOT a blocking `[P1]` FAIL. `_codex_review_classify_stdout` runs the `malformed` check **FIRST**, before its `[P1]` scan, so a `[P1]` present in the capture **only as quoted instruction text** (the prompt's literal `Prefix EACH blocking finding with [P1]` instruction, or a quoted prior-round finding in the comment-history dump) can never produce a verdict. A `malformed` capture is **never composed into a `Review findings:` body and never posted**; codex is left UNRESOLVED for the terminal sweep → `unavailable` (dropped — contributes **no** [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) vote, the "absent ⇒ not a deciding vote" semantics), with a distinct **`malformed-output`** drop reason. A genuine codex review with a real `[P1]` still FAILs; one with no `[P1]` still PASSes — no happy-path change.

This is a **distinct fourth `codex review` failure mode** from the three already handled: it exits **rc 0** ("succeeded", just produced garbage), so it is caught by none of [INV-59](#inv-59-codex-transient-stream-error-drops-surface-a-distinct-reason-and-are-ridden-out-by-the-resume-loop-not-opaquely-dropped)/[INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) (`turn.failed`/5xx → non-zero exit → retry), [INV-67](#inv-67-a-bare-smoke-timeout-rc-124137-with-no-authconfig-signal-classifies-unavailable-not-fail) (smoke timeout rc 124/137 → UNAVAILABLE), or [INV-69](#inv-69-a-failed-verdict-post-surfaces-a-distinct-post-failed-drop-reason-cli-agnostic-not-a-bare-opaque-unavailable) (a failed `gh` post). Before this guard, the bare `_codex_review_classify_stdout` `grep -qF '[P1]'` matched the echoed prompt's `[P1]` instruction text → a phantom blocking FAIL, and `_codex_review_compose_body` posted the 700+-line prompt/trace dump as the `Review findings:` body. Under the INV-40 unanimous-PASS gate, that single phantom FAIL vetoed an otherwise-clean PR on every round — a non-self-terminating dev↔review loop (observed 3× across one PR's review rounds: codex CLI `0.139.0`, model `openai.gpt-5.4`, provider `amazon-bedrock`; the PR was independently PASSED twice by `claude` on the same HEAD, CI-green and `MERGEABLE`).

Sub-rules:

1. **The malformed detector keys on echo/trace STRUCTURE, not on a bare keyword (fail-safe direction).** `_codex_review_stdout_is_malformed <capture>` returns rc 0 iff the capture is prompt-echo / startup-trace; rc 1 otherwise (a genuine review — with or without `[P1]` — an empty / missing / unreadable / short capture, or any plausible review). **rc 1 is the fail-safe direction** — a real review must NEVER be mis-flagged malformed (that would drop a genuine verdict), so the signals are deliberately STRUCTURAL, never a keyword a review could legitimately mention. Three signals, ANY one sufficient (defense in depth): **(1a)** the codex startup banner `^OpenAI Codex v[0-9]` as the capture's **FIRST non-empty line**; **(1b)** a `workdir:`+`model:`+`provider:` triple (all three) within the **CONTIGUOUS LEADING HEADER REGION** — the run of lines from the top up to the first blank / ``` fence / `## ` heading / `[P1]` finding line. Signal 1 keys on the ACTUAL launch-trace STRUCTURE, NOT on the banner/header strings appearing anywhere near the top: a real review writes review TEXT first, so a banner/header it QUOTES in a fenced block sits AFTER review prose (outside the leading region, and never the first non-empty line) and does NOT match. **This is the 2nd-round review finding [P1] (#252, session 5705a2d7) fix**: an earlier draft scanned the first 12 lines (`head -n 12`), so a genuine `[P1]` review whose finding quoted the banner/header fixture in a code block near the top was mis-flagged `malformed` before the `[P1]` scan, dropping a real blocking review. **(2)** **≥2 DISTINCT prompt-scaffolding markers in the ECHO REGION** — an echo reproduces the WHOLE prompt VERBATIM at the TOP as bare structure, so several standalone markers appear together, unfenced, before any finding; a real review writes findings and at most QUOTES prompt text inside ``` fences or after its findings. So the markers are counted only in the **echo region** = the capture with (a) fenced code blocks STRIPPED and (b) truncated at the first **FINDING-BOUNDARY** line (`_echo_region`). The **finding boundary** (shared by `_leading_region` signal 1b and `_echo_region` signal 2, inlined identically) recognizes the finding forms the wrapper documents/posts and a review emits, NOT just a bare leading `[P1]`: **(a)** direct / numbered / bulleted / bold — `[P1]`, `1. [P1]`, `1) **[P1]`, `- [P1]`, `* **[P1]`, `> [P1]` (a `[P1/2/3]` token after only list/number/bold/quote scaffolding — NOT the prompt's `Prefix EACH blocking finding with [P1]` instruction, which has prose before the token, nor a `## Step…` heading); **(b)** a JSON `"severity"`/`"priority"` key line; **(c)** a quoted JSON `P1`/`P2`/`P3` value. The markers counted (line-anchored where `build_review_prompt` emits them as structure): the `## Step 0:` and `## Step 0.5:` `… — MANDATORY PRE-REVIEW` headings (counted SEPARATELY — distinct sections), the `## You are running inside codex review` header, the `## Review Checklist` / `## Review Process` / `## Acceptance Criteria Verification` headings, the `Prefix EACH blocking finding` instruction line, and the `You are reviewing PR #… for issue #…` opener. Three review findings [P1] drove this: **PR #253 1st-round** — a bare global-substring match on ONE marker false-positived on a review that quoted it → require **≥2**; **#252 3rd-round (session fdc9ff60)** — ≥2 markers ANYWHERE still false-positived on a review that QUOTED two prompt headings in a fenced code block → restrict the count to the unfenced LEADING echo region; **#252 4th-round (session 6000c69c)** — the boundary only stopped on a bare leading `[P1]`, but the wrapper's own finding format is NUMBERED + BOLD (`1. **[P1] …`), so a review using that format then quoting two markers as evidence kept them in the region → widen the boundary to numbered/markdown/JSON finding forms. (NB: the boundary is inlined as LITERAL awk regexes — NOT passed via `awk -v`, whose C-style escape processing strips the `\[`/`\]`/`\*` backslashes and silently breaks the literal-bracket `\[P[123]\]` match.) This is the "ignore quoted code blocks / leading prompt region / recognize numbered/markdown/JSON finding formats" structure the findings asked for. **(3)** a large capture (≥ 45000 chars, below the 50000 `_codex_review_compose_body` cap) with NO recognizable verdict/conclusion structure (`Review PASSED`/`Review findings:`/a `Summary:`/`Findings` heading/`no blocking`) **AND no genuine FINDING-BOUNDARY** (the same `[P1]`/numbered/bullet/JSON finding set signals 1b/2 use) — a dump cut mid-text with neither a conclusion nor a finding. The **size floor (≥ 45000) guards signal 3 ONLY**: signal 1 (banner as first non-empty line / header in the contiguous leading region) and signal 2 (≥2 echo-region markers) are unambiguous structural artifacts at any size, but "no verdict structure" is suspicious only in a LARGE dump — a short, plausibly-complete review with no `Summary:` heading is NOT malformed (a review need not carry one). **#252 5th-round review finding [P1] #2 (session 5e569783)**: keying signal 3 on the verdict-HEADING keywords ALONE marked a genuine LONG review carrying numbered/bold `[P1]` findings (but none of those exact headings) as malformed — dropping a real blocking review before the `[P1]` scan; so signal 3 now ALSO requires the ABSENCE of a finding boundary (a long capture WITH finding structure is a real review, not a truncated dump → falls through to the `[P1]` scan and FAILs/PASSes correctly). rc 0/1 only — fail-safe under `set -euo pipefail` (a bare call never aborts).

2. **`malformed` is classified FIRST, before the `[P1]` scan.** `_codex_review_classify_stdout` echoes `pass | fail | malformed`: malformed → `malformed` (the `[P1]` scan does NOT run over an echoed prompt); else any `[P1]` → `fail`; else → `pass`. The existing conservative-on-`[P1]` rule (a fenced/quoted `[P1]` in a REAL review still FAILs — a false FAIL only re-queues to dev) is unchanged, but it now applies ONLY once the capture is confirmed to be a review, not the prompt echoed back. rc 0 always.

3. **A malformed rc-0 capture is RE-RUN (bounded), exactly like a transient.** `codex review` is stateless (re-reads the diff each invocation — [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) sub-rule 2), so a fresh run may produce a real review — the same precedent as the [INV-59](#inv-59-codex-transient-stream-error-drops-surface-a-distinct-reason-and-are-ridden-out-by-the-resume-loop-not-opaquely-dropped)/#209 stream-error re-run. A prompt-echo exits **rc 0**, so it cannot key off `last_run_rc`; `_run_codex_review` carries a `_run_malformed_rc0` flag, recomputed after every run via `_codex_review_stdout_is_malformed "$stdout_file"`. A clean rc-0 run whose capture is a REAL review (not malformed) still breaks the loop at once; only a malformed rc-0 capture continues into the re-run, bounded by the SAME `CODEX_REVIEW_MAX_RERUNS` (default 3; `0` disables — a single invocation) + the `AGENT_REVIEW_TIMEOUT` wall-clock deadline that bound the transient re-run. A timeout (124/137) still STOPS the loop immediately ([INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) sub-rule 3, unchanged). After the budget is exhausted while still malformed, the loop breaks with rc 0 and a malformed capture; the wrapper's rc-0 stdout fallback then sees the `malformed` classifier token (sub-rule 4) and leaves codex unresolved — no phantom FAIL.

4. **The wrapper's rc-0 stdout fallback treats `malformed` as no-verdict.** In `autonomous-review.sh`'s [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) fallback block (already gated on a clean rc 0 — sub-rule 5 there), if `_codex_review_classify_stdout` returns `malformed`, the wrapper does NOT compose a body and does NOT post — it `continue`s, leaving codex UNRESOLVED for the terminal sweep, which resolves it `unavailable` (a clean-rc-0 no-verdict → `unavailable` via `_classify_noverdict_agent`). This is the load-bearing gate that turns the phantom FAIL into a no-vote.

5. **A dropped malformed codex gets a distinct `malformed-output` drop reason — checked LAST among the codex buckets.** `_classify_codex_drop_reason <capture> [<rc>]` gains a `malformed-output` token, checked AFTER `config-error` (rc-2 gated, #223) and the `stream-error` scan: a clap parse error and a 5xx disconnect are MORE specific causes with their own signatures, so a malformed prompt-echo is the **residual** codex bucket and never shadows them; a clean / `[P1]` review still yields empty (no over-claim). `_codex_drop_reason_phrase` renders it as `malformed-output (codex review echoed its prompt/startup trace instead of a review — no verdict; retried, still malformed)` in the WARN log line + the posted dropped-agent comment. Observability only — like `stream-error` / `config-error` / `auth-failed`, a `malformed-output` codex stays a dropped `unavailable`, NEVER a deciding FAIL (`_classify_noverdict_agent` / `_aggregate_review_verdicts` untouched).

6. **The agent-smoke probe maps `malformed-output` to UNAVAILABLE.** `lib-agent-smoke.sh::_smoke_classify` reuses the per-CLI drop-reason scrapers ([INV-63](#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path)); a codex `malformed-output` token classifies **UNAVAILABLE** (environmental — the CLI ran but emitted garbage), grouped with `quota-exhausted*` / `stream-error*`, NOT with the operator-side `auth-failed` / `config-error*` FAIL bucket. FAILing the smoke over a transient prompt-echo would let one misbehaving codex abort the whole Phase A.5 fan-out and strand the issue in `reviewing` ([INV-64](#inv-64-the-review-wrapper-smokes-every-fan-out-member-before-the-fan-out-phase-a5-fail-aborts-the-review-unavailable-drops-the-member-pass-proceeds)) — the same drop-don't-veto tolerance a bare timeout ([INV-67](#inv-67-a-bare-smoke-timeout-rc-124137-with-no-authconfig-signal-classifies-unavailable-not-fail)) gets.

7. **A `malformed-output` drop routes the all-unavailable terminal path NON-substantive, not `failed-substantive` (#252 5th-round review finding [P1] #1).** A malformed prompt-echo exits **rc 0** (a clean exit, just garbage stdout). The terminal all-unavailable branch keys `AGENT_EXIT` on launch rc (rc ≠ 0 → `AGENT_EXIT=1` → `failed-non-substantive`; rc 0 → `AGENT_EXIT=0` → `failed-substantive`, the legacy "ran fine but no verdict = code-side miss" branch). So in a **single-agent codex fleet** (or when every other member is independently `unavailable`), a malformed codex left unresolved at rc 0 would route through the rc-0 `failed-substantive` branch — turning the dropped malformed output back into a **blocking request-changes FAIL** instead of a no-vote drop (the exact non-self-terminating dev↔review loop a single-agent-codex repo hit). The fix: the drop-classification loop sets `_any_nonsubstantive_drop=true` when a dropped codex agent has ANY non-empty infra-drop reason token at launch **rc 0**, and the all-unavailable branch raises `AGENT_EXIT=1` on that flag — routing it `failed-non-substantive` (re-dispatchable infra drop), the same terminal class as a non-zero `stream-error` drop. (`stream-error`/`config-error`/`auth-failed`/`quota-exhausted` that crash the CLI already exit non-zero, so the rc scan already routes them non-substantive; only the rc-0 infra-drop case needed the explicit flag.) This makes the malformed drop genuinely a no-vote / non-deciding outcome end-to-end, not just at classification time. **Broadened (#254 6th-round review finding [P1], session 5732e287)**: the flag originally keyed on the EXACT token string `malformed-output`, but `_classify_codex_drop_reason` scans for stream-error BEFORE the malformed check, so a malformed rc-0 prompt-echo whose echoed issue/comment text contains `Reconnecting... N/M` / `stream disconnected` is tokenized `stream-error:*` — and the exact-match check MISSED it, re-routing a single-agent codex fleet to `failed-substantive` again. The fix keys on **any non-empty token at launch rc 0** (`_codex_launch_rc == "0" && -n "$_codex_reason_token"`): the classifier emits a token ONLY for a genuine codex infra drop, so a non-empty token at rc 0 is unambiguously non-substantive regardless of which infra bucket matched first; a substantive "ran clean but no verdict" drop yields an EMPTY token and stays `failed-substantive`.

**Why**: #218's stdout fallback (INV-62) hardened the codex review verdict path against a non-honored self-post, but it scanned the WHOLE stdout for `[P1]` on the assumption that the capture is a real review. A `codex review` that echoes its prompt instead of reviewing violates that assumption — the prompt itself carries `[P1]` (it instructs the model to use `[P1]`), so the conservative `[P1]` scan ("a false FAIL only re-queues the PR to dev") fired on a non-review and produced a phantom veto. The fix is the targeted near-term guard the issue calls for: detect the echo/trace shape, retry (stateless), and drop-with-reason — without depending on the longer-term #233 verdict-artifact channel that would subsume stdout-scraping entirely.

**Producer**: `lib-review-codex.sh` — `_codex_review_stdout_is_malformed` (the structural detector, sub-rule 1), `_codex_review_classify_stdout` (malformed-first, sub-rule 2), `_run_codex_review` (the `_run_malformed_rc0` re-run, sub-rule 3), `_classify_codex_drop_reason` / `_codex_drop_reason_phrase` (the `malformed-output` bucket + phrase, sub-rule 5). `autonomous-review.sh` — the rc-0 stdout-fallback block `continue`s on a `malformed` classification (sub-rule 4), and the all-unavailable terminal path raises `AGENT_EXIT=1` on `_any_nonsubstantive_drop` — set for any non-empty rc-0 codex infra-drop token (sub-rule 7). `lib-agent-smoke.sh` — `_smoke_classify` maps `malformed-output` → UNAVAILABLE (sub-rule 6).
**Consumer**: the comment poller (authoritative verdict gate, unchanged — the wrapper simply posts no fallback verdict for a malformed capture), the INV-40 aggregation (a `malformed-output` codex stays dropped, never a deciding FAIL), and the operator reading the distinct drop reason.
**Scope guards**: strictly the `codex review` review path (`AGENT_CMD == codex`); the codex **dev** path (`codex exec` via `lib-agent.sh`) and other review CLIs are untouched. The detector is structural and fail-safe (rc 1 on any doubt), so a genuine review is never dropped.
**Status**: **ENFORCED** (closes #252). Hardens [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback)'s stdout fallback against the rc-0 prompt-echo failure mode. **Amended (PR #253 review finding [P1])**: sub-rule 1 signal 2 now requires **≥2 distinct co-occurring** prompt-scaffolding markers, NOT a bare global-substring match on a single marker — a genuine review that merely quotes one marker (e.g. reviewing THIS PR, whose diff/docs contain `Prefix EACH blocking finding`) while reporting a real `[P1]` must still classify `fail`, never `malformed`. **Amended again (PR #253 2nd-round review finding [P1], session 5705a2d7)**: sub-rule 1 signal 1 (banner/header) now matches ONLY the actual launch trace — the banner as the capture's FIRST non-empty line, and the workdir/model/provider triple within the CONTIGUOUS LEADING HEADER REGION (terminated by the first blank / fence / heading / finding line) — NOT the strings appearing anywhere in the first N lines, so a genuine `[P1]` review that quotes the banner/header fixture in a code block near the top is no longer mis-flagged `malformed`. **Amended a third time (#252 3rd-round review finding [P1], session fdc9ff60)**: sub-rule 1 signal 2 now counts the ≥2 prompt markers ONLY in the ECHO REGION (fenced code blocks stripped + truncated at the first finding line, `_echo_region`), NOT anywhere in stdout — so a genuine `[P1]` review that QUOTES two prompt headings in a fenced code block is no longer mis-flagged `malformed`. **Amended a fourth time (#252 4th-round review finding [P1], session 6000c69c)**: the finding boundary in BOTH `_echo_region` and `_leading_region` now recognizes NUMBERED / markdown-list / bold / JSON finding forms (`1. **[P1] …`, `- [P1]`, `"severity":"P1"`), not just a bare leading `[P1]` — so a genuine review in the wrapper's own numbered+bold finding format that then quotes prompt markers as evidence bounds the region at the finding and is no longer mis-flagged `malformed`. (The boundary is inlined as literal awk regexes; passing it via `awk -v` mangled the `\[`/`\]` backslashes.) **Amended a fifth time (#252 5th-round review finding, TWO [P1]s, session 5e569783)**: **(finding #1)** a `malformed-output` drop now routes the all-unavailable terminal path `failed-non-substantive` (sub-rule 7) instead of the rc-0 `failed-substantive` legacy branch — so a malformed codex on a single-agent fleet is a genuine no-vote drop, not a blocking FAIL. **(finding #2)** sub-rule 1 signal 3 (truncated-no-verdict) now also requires the ABSENCE of a finding boundary — so a genuine LONG `[P1]` review lacking the exact verdict headings is no longer mis-flagged `malformed`. **Amended a sixth time (#254 6th-round review finding [P1], session 5732e287)**: sub-rule 7's `_any_nonsubstantive_drop` flag now keys on ANY non-empty codex infra-drop token at launch rc 0, NOT the exact string `malformed-output` — because `_classify_codex_drop_reason` matches stream-error BEFORE malformed-output, a malformed rc-0 prompt-echo whose echoed text contained `Reconnecting... N/M` was tokenized `stream-error:*` and the exact-match check re-routed a single-agent codex fleet to `failed-substantive` again.

**Test**: `tests/unit/test-lib-review-codex.sh` — **TC-CXRS-MAL-DET-01..20** (`_codex_review_stdout_is_malformed`: each signal independently [banner / workdir-model-provider header / ≥2-leading-unfenced-prompt-scaffolding / truncated-no-verdict], a genuine `[P1]`/clean review → NOT malformed, empty/missing/short → NOT malformed + no `set -euo pipefail` abort, a review that merely MENTIONS a banner word with a verdict structure → NOT malformed [no false positive]; the PR #253 1st-round [P1] regressions **DET-10/11** [a genuine review QUOTING ONE prompt marker → NOT malformed] and the ≥2-marker echo pins **DET-12 + DET-03a/b/c**; the PR #253 2nd-round [P1] regressions **DET-13/14** [a genuine `[P1]` review QUOTING the banner/header fixture in a code block → NOT malformed] + the launch-trace regression guards **DET-15/16** [a real startup trace — banner as first non-empty line, or the contiguous leading header — STILL malformed]; the #252 3rd-round [P1] regressions **DET-17/18** [a genuine `[P1]` review QUOTING two prompt headings in a FENCED block, or quoting markers AFTER its finding → NOT malformed] + the unfenced-echo regression guards **DET-19/20** [≥2 unfenced leading markers with no preceding finding, and the fixture, STILL malformed]; the #252 4th-round [P1] regressions **DET-21/22/23** [a genuine `[P1]` review in NUMBERED+bold (`1. **[P1] …`), markdown-bullet, or JSON finding format then quoting two prompt markers → NOT malformed] + the boundary guards **DET-24/25** [the prompt's `[P1]` INSTRUCTION line is NOT a boundary so markers after it are STILL counted → malformed; a direct `[P1]` finding line STILL bounds the region]; the #252 5th-round finding-2 [P1] regressions **DET-26/27** [a genuine LONG (≥45000) review with a numbered/bare `[P1]` finding but no verdict heading → NOT malformed] + the dump guard **DET-28** [a long capture with NO finding structure + no heading → STILL malformed]; fixture-backed), **TC-CXRS-MAL-CLS-01..06 + 02b/02c/02d/02e/02f** (the `malformed` token checked FIRST: the #252 regression — prompt-echo with quoted `[P1]` → `malformed` NOT `fail`; a genuine `[P1]` still `fail`; **CLS-02b** quoting one prompt marker → `fail`; **CLS-02c** quoting the banner/header fixture → `fail`; **CLS-02d** quoting two prompt headings in a fenced block → `fail`; **CLS-02e** a numbered+bold finding then quoting two markers → `fail`; **CLS-02f** a long `[P1]` review with no heading → `fail`; a genuine clean still `pass`; empty → `pass`; fixture-backed; bare-call fail-safe), **TC-MAR-MALEXIT-01/02/03 (`test-autonomous-review-multi-agent.sh`)** (the #252 5th-round finding-1 fix: a single-agent malformed-output codex (rc 0, unavailable) routes the all-unavailable path `AGENT_EXIT=1` / `failed-non-substantive`, NOT `failed-substantive`; + source-of-truth **02a** that the wrapper flags `_any_nonsubstantive_drop` on any non-empty rc-0 codex infra token and **02b** raises `AGENT_EXIT` on it; the #254 6th-round finding [P1] regression **03a/03b** — a malformed rc-0 prompt-echo whose echoed text contains `Reconnecting... 5/5` classifies `stream-error:5/5` [03a pins the premise] yet STILL routes `AGENT_EXIT=1` / `failed-non-substantive` [03b], fixture `codex-review-stdout-prompt-echo-streamtext.txt`), **TC-CXRS-MAL-RUN-01..05** (the `_run_codex_review` malformed rc-0 re-run state machine: malformed-then-clean → 2 runs final pass; malformed-throughout max=3 → 4 runs final malformed; `MAX_RERUNS=0` → 1 run; malformed-then-genuine-`[P1]` → 2 runs final fail; a clean turn-1 → NO malformed re-run [happy path unaffected]), **TC-CXRS-MAL-DROP-01..06** (`_classify_codex_drop_reason` `malformed-output` bucket: prompt-echo → `malformed-output`; a clap config-error [rc 2] and a stream-error still WIN [not shadowed]; clean/`[P1]` → empty; phrase renders the cause; bare-call fail-safe), **TC-CXRS-MAL-INT-01..03** (behavioral via the `fallback_case` harness: rc-0 prompt-echo → NOT posted as FAIL, left unresolved; rc-0 genuine `[P1]` → still posts FAIL; rc-0 clean → still posts PASS), **TC-CXRS-MAL-WIRE-01..02** (source-of-truth: the wrapper fallback gates on the `malformed` token and the gate precedes the body composer). `tests/unit/test-autonomous-review-multi-agent.sh` — **TC-MAR-MAL-E2E-01..06** (stub-fleet end-to-end: a codex prompt-echo classifies `malformed` → resolves `unavailable` via the real `_classify_noverdict_agent` → `malformed-output` drop reason → `_aggregate_review_verdicts(unavailable, pass)` = `pass` [the surviving agent decides, no phantom veto] → the contrast pin that malformed is neither pass nor fail). `tests/unit/test-lib-agent-smoke.sh` / `test-lib-review-smoke.sh` — stay green with the `malformed-output` → UNAVAILABLE smoke mapping. Fixture: `tests/unit/fixtures/codex-review-stdout-prompt-echo.txt` (banner + echoed prompt with `[P1]` present only as quoted instruction text, comment-history dump, truncated mid-issue-body). Test plan: `docs/test-cases/codex-review-prompt-echo.md`. Design: `docs/designs/codex-review-prompt-echo-guard.md`.

> **Post-install / upgrade**: this PR does NOT add or remove a dispatcher script / `lib-*.sh` — it EDITS `lib-review-codex.sh`, `autonomous-review.sh`, and `lib-agent-smoke.sh`. No new `source` target is introduced, so the per-project `install-project-hooks.sh` re-run is NOT required after merge; `npx skills update -g` alone refreshes the user-scope copy (the existing per-file symlinks already resolve to the updated content).

**Cross-references**:
- [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) — the `codex review` stdout fallback this hardens (the rc-0 gate it adds the `malformed` exclusion to; the bounded re-run it reuses for the malformed rc-0 retry).
- [INV-59](#inv-59-codex-transient-stream-error-drops-surface-a-distinct-reason-and-are-ridden-out-by-the-resume-loop-not-opaquely-dropped) — the stream-error drop-reason + bounded-re-run precedent the `malformed-output` reason + retry mirror.
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the unanimous aggregation; a `malformed-output` codex is dropped, never a deciding FAIL (the "absent ⇒ not a deciding vote" semantics).
- [INV-67](#inv-67-a-bare-smoke-timeout-rc-124137-with-no-authconfig-signal-classifies-unavailable-not-fail) — the drop-don't-veto smoke tolerance the `malformed-output` → UNAVAILABLE mapping (sub-rule 6) extends.
- [`review-agent-flow.md` § codex malformed-output (prompt-echo) drop reason (INV-73)](review-agent-flow.md#codex-malformed-output-prompt-echo-drop-reason-inv-73) — runtime walkthrough.

## INV-74: adapter conformance is regression-pinned by a hermetic fixture-manifest runner

_Triage (issue #236): [machine-checked: tests/conformance/run-conformance.sh, tests/e2e/run-agent-smoke.sh]_

> **Note**: landed as **INV-74**, not INV-68 — several stability-redesign PRs
> merged ahead of this one against the same `main` (INV-67 smoke-timeout #246,
> INV-68 log-retention #245, INV-69 post-failed #247, INV-70 metrics #228,
> INV-71 run-event-channel #237, INV-72 operator error-envelope #231/#242,
> INV-73 codex prompt-echo malformed-output #252/#253). The number was reassigned
> at rebase to avoid a duplicate-heading / broken-anchor collision (the original
> PR draft authored it as INV-68, then INV-72, then INV-73, before those siblings
> landed — #253 took INV-73 first).

**Rule**: the per-CLI classification contract ([INV-66](#inv-66-adapter-conformance-is-spec-defined)'s
four-axis `AdapterResult`) is **regression-pinned** by a standalone, **hermetic**
conformance runner — `tests/conformance/run-conformance.sh` — that replays
per-adapter × per-mode fixture manifests
(`docs/pipeline/schemas/fixture-manifest.schema.json`, INV-66) against the
**CURRENT** classification logic and asserts the four `expect{}` axes
(`providerClass`, `verdictState`, `vote`, `retryable`). The runner:

1. **Is hermetic — in PATH *and* ENV.** No network, no credentials, no real
   agent CLIs. Each fixture is classified with `PATH` reset to a stub-only
   sandbox (plus the coreutils dir); the real `claude`/`codex`/`kiro`/`agy` are
   **never** on it. A fixture whose stub binary is missing, or whose `<adapter>`
   resolves to anything other than the stub, fails **loud** (`FAIL stub-missing` /
   `hermeticity-breach`) — it MUST NOT fall through to a real CLI. **The ENV is
   equally scrubbed** (PR #244 [P1] #1): the operator-facing surface
   lib-agent.sh reads — `AGENT_DEV_EXTRA_ARGS` / `AGENT_REVIEW_EXTRA_ARGS` (the
   argv builders splice these in), `AGENT_LAUNCHER` / `AGENT_DEV_LAUNCHER` /
   `AGENT_REVIEW_LAUNCHER` (tokenized into the launcher argv arrays at source
   time), and `AGENT_DEV_CMD` / `AGENT_REVIEW_CMD` — is reset to an empty
   baseline **before** the lib is sourced, so an inherited
   `AGENT_DEV_EXTRA_ARGS=--bogus` cannot append stray argv (→ argv-mismatch) and
   an inherited `AGENT_LAUNCHER` cannot route the dispatch off the isolated PATH
   (→ stdin-not-fed). **The conf-discovery surface is equally neutralized**
   (PR #244 [P1], codex review `dc696d40`): `load_autonomous_conf` reads THREE
   inputs at source time — `AUTONOMOUS_CONF` (a file), `AUTONOMOUS_CONF_DIR`
   (called as `${AUTONOMOUS_CONF_DIR:-$_LIB_AGENT_DIR}/autonomous.conf`), and
   `PROJECT_DIR/scripts/autonomous.conf` — so scrubbing `AUTONOMOUS_CONF` alone is
   insufficient: an inherited `AUTONOMOUS_CONF_DIR` (or `PROJECT_DIR`) pointing at
   a real operator conf would still splice its `AGENT_*_EXTRA_ARGS` into the argv.
   Setting these to `""` does **not** help — `${AUTONOMOUS_CONF_DIR:-$_LIB_AGENT_DIR}`
   treats empty as unset and falls back to `$_LIB_AGENT_DIR`, which on a
   self-hosting checkout resolves into a `scripts/` tree carrying a live
   `autonomous.conf`. So all three are pointed at **concrete conf-free paths** (a
   `mkdir`'d empty dir under the per-fixture work dir, with a `.nonexistent.conf`
   for `AUTONOMOUS_CONF`); all three discovery branches miss and
   `load_autonomous_conf` returns 1. The runner is therefore **self-defending** —
   it no longer relies on the caller passing `env -u PROJECT_DIR`. **The remaining
   argv/launch knobs are reset to deterministic defaults** (PR #244 [P1], codex
   review `fff5f671`): lib-agent.sh reads more operator knobs at source time, two
   of which reach argv/launch — `KIRO_AGENT_NAME` (spliced into the kiro argv as
   `--agent <name>`; an inherited `KIRO_AGENT_NAME=other` ⇒ argv-mismatch) and
   `AGENT_TIMEOUT` (the `timeout(1)` duration; an inherited `AGENT_TIMEOUT=bogus`
   makes the launch never run ⇒ stdin-not-fed). Both (plus `AGENT_PERMISSION_MODE`,
   defense-in-depth) are reset to the lib's own documented defaults
   (`autonomous-dev` / `4h` / `auto` — the values the fixtures were recorded
   against) before the source. (`AGENT_DEV_MODEL` / `AGENT_REVIEW_MODEL` need no
   reset: `run_agent`/`resume_agent` take the model as an explicit positional arg
   from `input.model`, so those knobs never reach the argv.) The
   classification depends ONLY on the fixture's `input.env`, which is applied
   AFTER the scrub (so a fixture that genuinely wants a var — e.g.
   `codex-cli-error`'s `AGENT_DEV_EXTRA_ARGS` — re-enables it). **The codex
   drop-reason classifier is called with the fixture's launch rc** (PR #244 [P1],
   codex review `fff5f671`): production passes the rc into
   `_classify_codex_drop_reason`, which gates the `config-error` bucket on rc == 2
   (clap's parse-error exit). The runner now threads `$rc` too, so a transient
   codex fixture (rc 1) whose capture merely QUOTES a clap usage line classifies
   `stream-error`/transient (not `config`), faithfully replaying production. **The
   codex review lane is stdin- and control-env-hermetic too** (PR #244 [P1], codex
   review `1c29ba19`): (a) the stub unconditionally `cat > .stdin` to record the
   [INV-34] channel, but the codex review path carries the prompt as an argv
   positional and pipes no stdin — on a CI runner stdin is already EOF, but a local
   standalone run from a TTY would block the codex stub forever (rc 124), so the
   runner feeds the codex dispatch `</dev/null` (the stub reads immediate EOF on
   every host, recording empty stdin — matching the codex fixtures' empty-string
   `command.stdinSha256`); (b) `_run_codex_review` reads `CODEX_REVIEW_MAX_RERUNS`
   (default 3) and `AGENT_REVIEW_TIMEOUT` (default 1h) at CALL time (not lib-source
   time), so an inherited `CODEX_REVIEW_MAX_RERUNS=100000` would make a transient
   fixture re-run 100000× → hang; both are reset to the lib defaults before
   `input.env`, so a codex fixture's runtime depends ONLY on the manifest. This is the
   always-on tier; the live-CLI smoke
   ([INV-63](#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path) / `tests/e2e/run-agent-smoke.sh`) is the separate self-hosted tier.
2. **Drives TODAY's monolithic classifier via the REAL dispatch path** — it
   launches the stub through the production invocation primitives
   (`lib-agent.sh::run_agent` / `resume_agent`, or `lib-review-codex.sh::_run_codex_review`
   for codex review) on the isolated PATH, then classifies the captured result
   with `lib-agent-smoke.sh::_smoke_classify` plus the per-CLI
   `_classify_<cli>_drop_reason` scrapers (INV-58/61/62), NOT a re-implemented
   copy. This is **intentional**: pin current behavior so the later adapter
   extraction (a single `invoke() → AdapterResult` entry point) MUST keep
   conformance green BEFORE and AFTER the refactor (green → refactor → still
   green). When that entry point lands, the runner re-points at it with **zero
   fixture changes** — the fixtures are the contract.
3. **Materializes** each fixture: stages `files{}` (logs/sidecars — e.g. the agy
   `--log-file` quota log) and installs a stub CLI that emits the recorded
   `command.{rc,stdout,stderr}` and records both the **argv it was launched with**
   and the **stdin bytes** it received. Because the dispatch path launches the
   stub, the manifest's `command.argv` and `command.stdinSha256` are
   **LOAD-BEARING**: the runner asserts the stub-recorded argv against
   `command.argv` (placeholder-aware — `<uuid>` / `<prompt>` / `<logfile>` /
   `<permission-mode>` / `<timeout>` stand for per-run values) and `sha256(stdin)`
   against `command.stdinSha256` (the
   [INV-34](#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element)
   prompt channel; codex review carries the prompt as an argv positional, so its
   stdin hash is the empty-string hash) **before** classifying. A regression in
   how an adapter assembles argv or feeds the prompt fails the fixture loud
   (`FAIL argv-mismatch` / `FAIL stdin-sha-mismatch`) — it is NOT a
   canned-stdout replay that ignores invocation. The prompt is fed with a
   **deterministic nonce** so the stdin hash is reproducible and pinnable.
4. **Validates** each manifest against the schema (loud reject on malformed —
   python jsonschema when available, else a jq structural fallback). The fallback
   is a **faithful mirror** of `fixture-manifest.schema.json`, NOT a loose subset:
   it enforces the SAME required nested fields/types and the SAME
   `additionalProperties:false` at every object level (top-level, `input`,
   `command`, `expect`, each `files` entry) — so a manifest that python jsonschema
   would reject (missing `input.promptBytes`, a non-string `input.env` value, a
   negative `promptBytes`, an unknown nested key, a bad `files.<k>.role`, OR an
   explicit `files.<k>.role: null` / `sha256: null` — the optional string fields
   have no `null` in their schema type, so `has(...)` distinguishes absent (valid)
   from present-null (invalid), PR #244 [P1] #2) ALSO
   fails `schema-invalid` here. **It fails closed**: a malformed manifest is
   rejected on a fork with NO `jsonschema` installed exactly as it is on a
   jsonschema-equipped CI — the fallback and python jsonschema are cross-checked
   agreeing on the full valid promoted set and on every malformed variant the
   suite drives (TC-CONFORMANCE-025/025e..m — PR #244 [P1] #1).
5. Emits one line per fixture `CONFORMANCE <adapter>/<mode>/<name> PASS|FAIL
   <axis-diff>` and exits non-zero on ANY fail (incl. a malformed manifest or an
   unmaterializable stub — a fixture that cannot run is a FAIL, never a silent
   skip; a filter matching zero fixtures is also loud).

The promoted fixture set carries ≥2 manifests per currently-fan-out-capable CLI
(claude, codex, kiro, agy) and pins **both** halves of **each** load-bearing rc
mapping as actual promoted fixtures the full run exercises (PR #244 [P1] #2):
- `124 + no verdict ⇒ timeout-veto` — `claude-timeout-veto.json` (rc 124);
- `137 + no verdict ⇒ timeout-veto` — `claude-timeout-veto-sigkill.json` (rc 137,
  the `--kill-after` SIGKILL half — deciding FAIL, INV-48);
- `0 + no provider + no verdict ⇒ drop` — `claude-rc0-noverdict-drop.json`
  (rc 0, stdout that does NOT echo the nonce, no provider signal → `unavailable`
  drop, INV-40).

It also pins the codex drop-reason **rc gate** (PR #244 [P1], codex review
`fff5f671`): `codex-quoted-clap-nonconfig.json` (rc 1, a capture that QUOTES a
clap usage line — `error: unexpected argument '-s' found` — alongside a
stream-error ladder) must classify `transient`/`stream-error`, NOT `config`. The
runner threads the fixture rc into `_classify_codex_drop_reason`, which gates the
`config-error` bucket on rc == 2; absent the rc the same capture mislabels
`config` (the regression this fixture guards), diverging from the production
review wrapper.

A regression in EITHER mapping (rc 124, rc 137, or the rc-0 drop) flips the
corresponding fixture's projected `vote` axis and FAILs the run.

**Why**: per-CLI quirk handling is the largest historical bug factory in this
repo (~14 issues — every CLI lies differently at the exit-code level: `agy` rc-0
silent quota, `kiro` headless-auth exit-0, `codex` rc-2 clap vs transient
stream-error). Its only tests were scattered per-bug unit tests. A
manifest-driven conformance suite makes each CLI's contract explicit and
regression-pinned, gives new-CLI admission an objective bar (author a manifest,
run the suite), and is the safety net under the later adapter extraction — that
refactor cannot land unless conformance stays green. (#230.)

**Producer**: this PR (#230) authors the runner + the promoted fixtures. Every
later adapter PR is a producer of *conformant behavior*; this invariant binds it
to keep the suite green. A new-CLI PR is the producer of *its* manifests.
**Consumer**: the runner consumes the INV-66 `fixture-manifest.schema.json`; the
later adapter extraction (the `invoke()` entry point) is the consumer that the
green-before-and-after gate protects.
**Status**: **ENFORCED** — the runner is an always-on CI step
(`.github/workflows/ci.yml` → `unit-tests`), credential-free, runs on any fork.

**Test**:
- `tests/conformance/run-conformance.sh` — the runner itself; the promoted
  fixture set passing IS the E2E (CI job green = pass).
- `tests/unit/test-conformance-runner.sh` — TC-CONFORMANCE-001..053: the pure
  projection/diff/field helpers (`lib-conformance.sh`), runner happy path,
  `--adapter`/`--mode` filtering, expect-mismatch FAIL with axis diff,
  malformed-manifest loud reject, **the jq-fallback nested-required-field
  strictness (TC-CONFORMANCE-025e..k: the fallback rejects a manifest missing
  `input.promptBytes` / `input.model`, a non-string `env` value, a negative
  `promptBytes`, an unknown nested key, a non-string argv element, a bad
  `files.role`, AND an explicit `files.<k>.role:null` / `sha256:null` /
  non-string `sha256` (TC-CONFORMANCE-025o..q — PR #244 [P1] #2) — fails closed
  exactly as python jsonschema; 025l/m: it still ACCEPTS the full valid set —
  PR #244 [P1] #1)**, **ENV hermeticity (TC-CONFORMANCE-035a..e: an inherited
  `AGENT_DEV_EXTRA_ARGS` / `AGENT_LAUNCHER` / heavy multi-var leak does NOT
  contaminate the run — it stays all-PASS — while `input.env` still re-enables a
  var after the scrub — PR #244 [P1] #1; TC-CONFORMANCE-035f..i: a poisoned
  `AUTONOMOUS_CONF_DIR` / `PROJECT_DIR` conf — supplied WITHOUT `env -u PROJECT_DIR`
  — does NOT leak its `AGENT_*_EXTRA_ARGS` into the argv, proving the in-runner
  conf-discovery scrub is self-defending — PR #244 [P1], codex review `dc696d40`;
  TC-CONFORMANCE-035l..o: an inherited `KIRO_AGENT_NAME` (→ kiro `--agent` argv)
  or `AGENT_TIMEOUT=bogus` (→ the launch never runs → stdin-not-fed) does NOT
  contaminate the run — the runner resets those argv/launch knobs to the lib
  defaults before sourcing — PR #244 [P1], codex review `fff5f671`)**,
  **codex drop-reason is rc-gated (TC-CONFORMANCE-036a..d: the runner passes the
  fixture's launch rc into `_classify_codex_drop_reason`, so a transient codex
  fixture (rc 1) whose capture merely QUOTES a clap line classifies `stream-error`
  /transient — NOT `config` — matching production; the promoted
  `codex-quoted-clap-nonconfig` fixture + the WITHOUT-rc→`config-error` /
  WITH-rc-1→`stream-error` gate proof pin it — PR #244 [P1], codex review
  `fff5f671`)**, **codex stdin + control-env hermeticity (TC-CONFORMANCE-037a/b:
  the codex stub does NOT hang on a non-EOF (TTY-proxy) stdin — proven via a fifo
  with an open writer — because the dispatch feeds `</dev/null`; 038a/b: an
  inherited `CODEX_REVIEW_MAX_RERUNS=100000` does NOT leak into the codex run (stays
  exit 0, proven to time out 124 pre-fix) because the runner resets the codex
  review controls — PR #244 [P1], codex review `1c29ba19`)**, hermeticity (PATH isolation,
  stdin-fed contract, stub-missing/breach guards), **the load-bearing
  `command.argv` / `command.stdinSha256` assertions (TC-CONFORMANCE-030..034:
  garbage argv and all-zero hash must FAIL, not silently PASS — PR #244 [P1])**,
  the ≥2-per-CLI count, **both halves of each load-bearing rc mapping as promoted
  fixtures the full run exercises (TC-CONFORMANCE-041a..i: rc 124 + rc 137 ⇒
  timeout-veto, rc 0 + no-verdict ⇒ drop — PR #244 [P1] #2)**, and the
  CI/cross-link wiring.
- `docs/test-cases/conformance-runner.md` — TC-CONFORMANCE-NNN enumeration.

**Cross-references**:
- [`adapter-spec.md` § 8](adapter-spec.md#8-the-conformance-fixture-manifest) — the fixture-manifest the runner consumes.
- [INV-66](#inv-66-adapter-conformance-is-spec-defined) — the spec + the four-axis `AdapterResult` this runner pins.
- [INV-63](#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path) — the `_smoke_classify` classifier the runner drives; the live-CLI smoke is the separate self-hosted tier.
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) / [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto) — the `drop` / `timeout-veto` vote mappings the load-bearing fixtures pin.
- [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) / [INV-61](#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) / [INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) — the per-CLI scrapers the fixtures exercise.

## INV-75: all per-CLI behavior lives in that CLI's adapter — inline CLI conditionals in orchestration code are a defect

_Triage (issue #236): [machine-checked: tests/unit/test-cli-adapters.sh]_

**Rule**: every per-CLI special case — argv assembly, the stdin-vs-positional
prompt channel ([INV-34](#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element)),
session-handle capture/recall (codex thread-id, opencode `ses_`, agy `--log-file`
UUID), `--model` validation ([INV-50](#inv-50-agy---model-is-validated-against-agy-models-before-forwarding)),
the per-CLI review lane ([INV-62](#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback)),
and the drop-reason scrapers ([INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) /
[INV-59](#inv-59-codex-transient-stream-error-drops-surface-a-distinct-reason-and-are-ridden-out-by-the-resume-loop-not-opaquely-dropped) /
[INV-61](#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable)) —
**lives in `skills/autonomous-dispatcher/scripts/adapters/<cli>.sh`**, behind the
`adapter_invoke_<cli> <mode> …` mode-axis entry point. The orchestration core
(`lib-agent.sh`'s `run_agent` / `resume_agent`, `autonomous-review.sh`,
`lib-agent-smoke.sh`) is **CLI-agnostic**: the ONLY permitted CLI conditional in
it is the **thin dispatch** (`case "$AGENT_CMD" in claude|codex|gemini|kiro|opencode|agy) adapter_invoke_"$AGENT_CMD" …`)
plus the **generic-fallback `*)` branch** for an unknown CLI. An inline
`case "$AGENT_CMD"` (or `$cli`) carrying per-CLI flag / argv / classification
**logic** in orchestration code is a **defect**.

- **Producer**: each `adapters/<cli>.sh` (defines `adapter_invoke_<cli>`, the
  CLI's session/capture helpers, model validation, review lane, and
  `_classify_<cli>_drop_reason` / `_<cli>_drop_reason_phrase`; declares its launch
  binary via `adapter_binary_<cli>` when it differs from the id — only `kiro` →
  `kiro-cli`).
- **Consumer**: `lib-agent.sh` sources every adapter and dispatches; the
  `lib-review-{codex,agy,kiro}.sh` files are **thin compat shims** that
  `source adapters/<cli>.sh` to preserve the historical source-by-path contract
  (the conformance runner + `lib-agent-smoke.sh` source those paths; the CI
  shellcheck list names them). Each shim resolves `adapters/<cli>.sh` from its
  OWN real location (`readlink -f` of its `BASH_SOURCE`, like `lib-agent.sh` per
  [INV-65](#inv-65-entry-scripts-resolve-conf-from-the-unresolved-path-and-libs-from-the-real-skill-tree-path-two-dir-resolution)),
  NOT the symlink's dir — so a legacy install carrying a DIRECT per-lib symlink
  to a shim (no sibling `adapters/`) still finds the adapter in the skill tree
  instead of dying with `adapters/<cli>.sh: No such file or directory` (#232
  review). A shim resolving siblings via the bare symlink dir is a defect.
- **Mode axis** ([adapter-spec.md § 3](adapter-spec.md#3-the-mode-axis-modes-differ-structurally)):
  `adapter_invoke_<cli>` takes `dev-new` / `dev-resume`; the codex `review` lane
  is `_run_codex_review` (also in the codex adapter); `e2e-browser` is
  CLI-agnostic (no adapter mode).
- **Why** (#232): Factory D exists because CLI quirks were scattered across
  `lib-agent.sh` `case` branches plus three `lib-review-*.sh` patch files — every
  new quirk landed as another scattered patch. With the spec
  ([INV-66](#inv-66-adapter-conformance-is-spec-defined)) and the conformance pin
  ([INV-74](#inv-74-adapter-conformance-is-regression-pinned-by-a-hermetic-fixture-manifest-runner))
  in place, the quirks move behind one boundary per CLI, making new-CLI admission
  a self-contained file + manifest set. This was a **behavior-preserving**
  relocation: the conformance suite + full unit suite were green before AND after,
  and the per-CLI run_agent/resume_agent argv is byte-identical (golden-argv
  parity, documented in PR #232's body).
- **Test**: `tests/unit/test-cli-adapters.sh` (TC-ADAPTER-EXTRACT-NNN) — dispatch
  (known CLI → adapter; unknown → generic fallback), mode routing, source-by-path
  shim compat, the INV-75 no-inline-literal guard, and INV-50 still wrapper-side;
  plus the conformance suite as the behavior-parity E2E gate.

**Cross-references**:
- [`adapter-spec.md`](adapter-spec.md) — the NORMATIVE adapter interface this implements.
- [INV-66](#inv-66-adapter-conformance-is-spec-defined) / [INV-74](#inv-74-adapter-conformance-is-regression-pinned-by-a-hermetic-fixture-manifest-runner) — the spec + conformance pin the relocation preserved.
- [INV-14](#inv-14-vendored-scripts-resolve-siblings-via-bash_source-not-cwd) / [INV-65](#inv-65-entry-scripts-resolve-conf-from-the-unresolved-path-and-libs-from-the-real-skill-tree-path-two-dir-resolution) — the BASH_SOURCE / skill-tree resolution the shims and adapter sourcing use.

## INV-76: a transient smoke `no-response` (rc≠0, no signal) retries once, then drops UNAVAILABLE — never a single-shot gate FAIL

_Triage (issue #236): [machine-checked: tests/unit/test-lib-agent-smoke.sh]_

> **Note**: authored as INV-75 (next free number when `main` was at INV-74), then
> renumbered to **INV-76** at rebase: PR #259 (per-CLI adapters, issue #232) landed
> INV-75 on `main` first, so this section took the next free number per the standard
> duplicate-heading / broken-anchor avoidance (see "Adding a new invariant"). The
> number is disambiguated by issue #257.

**Rule**: in `lib-agent-smoke.sh`, the **driver** `smoke_agent` retries a bare
`no-response` smoke **exactly once** before deciding. A "bare `no-response`" is the
`_smoke_classify` **step-5** fallthrough: the CLI exited **non-zero**, the nonce is
**absent** from stdout, there is **no** per-CLI scraper signal (not quota /
stream-error / malformed-output / auth-failed / config-error), and it is **not** a
`124`/`137` timeout. On a Bedrock-backed CLI (codex via IAM-role→Bedrock) that shape
is far more likely a **transient infra hiccup** — the CLI died before emitting any
recognizable signal — than operator-side config breakage, so it is treated as a
TRANSIENT (the same tolerance [INV-67](#inv-67-a-bare-smoke-timeout-rc-124137-with-no-authconfig-signal-classifies-unavailable-not-fail) gives a bare timeout and [INV-73](#inv-73-a-codex-review-prompt-echo--startup-trace-stdout-is-malformed-never-a-blocking-p1-fail--retry-or-drop-not-a-phantom-veto) gives a codex malformed-output):

- The first probe classifies as the step-5 bare `no-response` FAIL → run **one
  additional fresh `smoke_agent` probe** of the same member (a one-token round-trip).
- Retry **PASSes** (nonce present) → **PASS** (the transient cleared); the member
  fans out.
- Retry is **still** a bare `no-response` (or any other **non-FAIL** transient on the
  retry) → **UNAVAILABLE**, reason `no-response (rc=<n>; no nonce after retry —
  transient infra)`. The member casts **no** [INV-64](#inv-64-the-review-wrapper-smokes-every-fan-out-member-before-the-fan-out-phase-a5-fail-aborts-the-review-unavailable-drops-the-member-pass-proceeds) Phase A.5 vote — the review proceeds on the survivors instead of aborting.
- Retry surfaces a **genuine `auth-failed` / `config-error`** signal → **FAIL** (the
  retry exposed real operator-side breakage — surface it, do not mask it).

Sub-rules:

1. **ONLY the step-5 bare `no-response` with a NON-ZERO CLI exit is retried.** The
   discriminator is structural (`_smoke_is_transient_no_response`): STATE==`FAIL`
   **and** the reason begins with `no-response` **and** the `rc=<n>` the step-5 reason
   carries is **non-zero**. `_smoke_classify`'s step-5 fallthrough is the ONLY path
   that emits `FAIL|no-response (rc=<n>; …)`; the genuine operator-side FAILs
   (`auth-failed`, `config-error[:<flag>]`) carry their own scraper phrase, never
   `no-response`, and the pre-flight FAILs (`bad-args`, `mktemp-failed`) likewise. So
   a genuine config break is **FAIL on the first probe, no retry** — unchanged,
   gate-worthy.

   **`rc=0` silent-success carve-out (issue #257 review follow-up).** `_smoke_classify`
   step 5 ALSO fires when a CLI exits **`0`** with no nonce/no scraper signal — a CLI
   that CLAIMED success but produced no token. A transient Bedrock hiccup kills the CLI
   with a **non-zero** exit; a clean `rc=0`-with-no-answer is genuine broken-output /
   misconfiguration, **not** a capacity blip. So the retry guard keys on the
   **original non-zero exit code** (preserved in the reason's `rc=<n>`): a `rc=0`
   no-response (or any unparseable rc) is **NOT** transient → **no retry, single-shot
   gate-worthy FAIL** (preserved). This keeps the relaxation scoped exactly to the
   `rc≠0` step-5 fallthrough that #257 set out to fix.

2. **The already-environmental UNAVAILABLE cases are untouched.** `quota-exhausted` /
   `stream-error` / `malformed-output` (the `*|*|*` UNAVAILABLE branch) and the bare
   `124`/`137` timeout ([INV-67](#inv-67-a-bare-smoke-timeout-rc-124137-with-no-authconfig-signal-classifies-unavailable-not-fail)) classify UNAVAILABLE on the **first** probe with **no
   retry**. This invariant changes only the step-5 generic `no-response` fallthrough.

3. **`_smoke_classify` stays a pure single-probe decision function ([INV-63](#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path)).** It
   cannot drive a fresh `run_agent`, so the retry lives in the driver. The single
   probe is factored into `_smoke_probe_once` (a new helper that mints a fresh
   nonce/session-id per probe so a retry cannot stale-PASS off the first probe's
   stdout), invoked at most twice by `smoke_agent`.

4. **Bounded to one extra probe.** The retry fires exactly once — no loop, no
   runaway counter. A second `no-response` resolves to UNAVAILABLE deterministically.
   The wall-clock cost is one extra one-token round-trip in the (rare) transient case
   only; the reported `elapsed` is the sum across both probes.

5. **No gate code change — the propagation is automatic.**
   `lib-review-smoke.sh::_classify_smoke_state` already maps `smoke_agent` rc 2 →
   `unavailable`, and `_classify_smoke_gate` already treats `unavailable` as a dropped
   member (`fail` > `all-unavailable` > `pass` precedence, [INV-64](#inv-64-the-review-wrapper-smokes-every-fan-out-member-before-the-fan-out-phase-a5-fail-aborts-the-review-unavailable-drops-the-member-pass-proceeds)). So this
   `smoke_agent` change flows through unchanged: one no-response member → dropped +
   review proceeds; ALL members no-response → `all-unavailable` (the existing
   [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) terminal path, **no empty fan-out spawned**).

6. **Fail-safe / non-Bedrock care.** The retry-then-UNAVAILABLE applies regardless of
   CLI (a transient no-response is environmental for any CLI). It does NOT mask a
   *consistently* broken CLI: a genuinely misconfigured member typically surfaces an
   `auth-failed` / `config-error` scraper signal (→ FAIL, unaffected, sub-rule 1) or
   fails both the probe and its retry (→ UNAVAILABLE drop, the same terminal class as
   a crashed reviewer — it abstains rather than vetoing every PR).

**Why**: observed in this repo's own self-review pipeline (#257). During a
multi-issue backlog drain on a single-agent codex fleet (the only other member
quota-/auth-unavailable), a review **wedged ~7 times**, every wedge keyed on
`reason=no-response` (`SMOKE codex FAIL <N>s reason=no-response (rc=1; nonce absent
from CLI output)` → `smoke gate over [fail] → fail` → `aborting the review WITHOUT
fan-out`). Each required a manual `reviewing → pending-review` label flip; codex
itself was healthy (~88% smoke-pass on the same config), confirming the
`no-response` was transient, not a misconfiguration. This is the **smoke-stage
sibling** of the review-stage codex transient fixes (#252 / #254, [INV-73](#inv-73-a-codex-review-prompt-echo--startup-trace-stdout-is-malformed-never-a-blocking-p1-fail--retry-or-drop-not-a-phantom-veto)) — the one
transient path that was still single-shot-FAILing.

**Producer**: `lib-agent-smoke.sh` — `smoke_agent` (the retry-once driver), the new
`_smoke_probe_once` (single-probe body) and `_smoke_is_transient_no_response` (the
retry discriminator). `_smoke_classify` is unchanged (still emits `FAIL|no-response`
for a single step-5 probe).

**Consumer**: the [INV-64](#inv-64-the-review-wrapper-smokes-every-fan-out-member-before-the-fan-out-phase-a5-fail-aborts-the-review-unavailable-drops-the-member-pass-proceeds) Phase A.5 gate (`lib-review-smoke.sh::_classify_smoke_state`
→ `_classify_smoke_gate`), which drops the UNAVAILABLE member and proceeds; the
[INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) command-mode evidence parser when this repo runs the matrix as its own PR E2E
(the `SMOKE … UNAVAILABLE … reason=no-response (… after retry — transient infra)`
line is non-blocking).

**Status**: **ENFORCED** (closes #257).

**Test**: `tests/unit/test-lib-agent-smoke.sh` — TC-AGENT-SMOKE-075a (regression:
first probe rc≠0 / nonce absent / no signal AND a retry that is also no-response →
**UNAVAILABLE**, **proven to FAIL against the pre-#257 single-shot-FAIL**), 075b
(retry PASSes → PASS), 075c (config-error on probe 1 → FAIL, no retry), 075d (bare
timeout → UNAVAILABLE, no retry — INV-67 unchanged), 075e (agy quota → UNAVAILABLE,
no retry), 075f (bound: stub invoked exactly twice), 075g (no-response then
config-error on retry → FAIL, not masked), 075h/075i (`_smoke_classify` purity:
single-probe step-5 reason + auth/config discriminator intact), 006c-NR (codex bare
no-response end-to-end through real `run_agent` → UNAVAILABLE), 039d/045d (the #222
no-false-PASS security property preserved across the retry — rc 2 UNAVAILABLE, never
a PASS). `tests/unit/test-autonomous-review-smoke-gate.sh` — TC-REVIEW-SMOKE-075a..d
(gate propagation: retried-UNAVAILABLE → `unavailable` state, one retried-UNAVAILABLE
+ one PASS → gate `pass` + survivor fans out, all retried-UNAVAILABLE →
`all-unavailable` no empty fan-out, genuine FAIL + retried-UNAVAILABLE → gate `fail`
abort preserved). E2E: `tests/e2e/run-agent-smoke.sh` stub matrix's FAIL entry now
uses a genuine config-error stub (a bare no-response would retry → UNAVAILABLE).
Design: `docs/designs/smoke-no-response-retry.md`. Test plan:
`docs/test-cases/smoke-no-response-retry.md`.

**Cross-references**:
- [INV-63](#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path) — the three-state contract this refines; `_smoke_classify` stays a pure single-probe function and the retry lives in the driver.
- [INV-64](#inv-64-the-review-wrapper-smokes-every-fan-out-member-before-the-fan-out-phase-a5-fail-aborts-the-review-unavailable-drops-the-member-pass-proceeds) — the Phase A.5 gate whose abort this prevents for a transient no-response (UNAVAILABLE drop instead of FAIL abort).
- [INV-67](#inv-67-a-bare-smoke-timeout-rc-124137-with-no-authconfig-signal-classifies-unavailable-not-fail) — the sibling tolerance for a bare timeout; this extends the same "environmental → drop" treatment to a bare no-response (with a retry first, since a no-response is cheaper to re-probe than a timeout).
- [INV-73](#inv-73-a-codex-review-prompt-echo--startup-trace-stdout-is-malformed-never-a-blocking-p1-fail--retry-or-drop-not-a-phantom-veto) — the review-stage codex transient fix (#252 / #254) this is the smoke-stage sibling of.
- [INV-40](#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) / [INV-58](#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) / [INV-61](#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) — the environmental → drop tolerance this aligns with.

## INV-77: CI is two tiers — hermetic always-on + credential-free; live agent-smoke is self-hosted, label-gated, and advisory

_Triage (issue #236): [machine-checked: tests/unit/test-ci-two-tier-lanes.sh]_

> **Note**: authored as INV-75 (next free number when `main` was at INV-74), then
> renumbered to **INV-77** across two rebases: PR #259 (per-CLI adapters, issue #232)
> landed INV-75 on `main` first, then PR #258 (smoke no-response retry, issue #257)
> landed INV-76 — so this section took the next free number per the standard
> duplicate-heading / broken-anchor avoidance (see "Adding a new invariant"). The
> number is disambiguated by issue #238.

**Rule**: `.github/workflows/ci.yml` is split into two explicit tiers, and the
split is a hard contract:

1. **Tier 1 — HERMETIC.** Every job whose name starts with `hermetic-`
   (`hermetic-unit`, `hermetic-shellcheck`) runs on `ubuntu-latest` and is
   **credential-free** — no `secrets.*`, no `AWS_*` / `BEDROCK` / `ANTHROPIC_API_KEY`
   / `GH_APP_PRIVATE_KEY`. These are the unit tests, ShellCheck, the adapter
   conformance suite ([INV-74](#inv-74-adapter-conformance-is-regression-pinned-by-a-hermetic-fixture-manifest-runner)),
   and the stub-mode self-tests of the smoke/metrics/error-envelope harnesses.
   Because they need no credentials, a **fork PR** (or any external contributor)
   gets a fully green, fully meaningful CI. These are the **merge-required**
   checks.

2. **Tier 2 — LIVE.** The single `live-smoke` job runs the #222 live agent-CLI
   smoke matrix (`tests/e2e/run-agent-smoke.sh`,
   [INV-63](#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path))
   against the box's **real** CLIs + credentials. It is gated by
   `if: (github.event_name == 'pull_request' && github.event.label.name == 'run-live-smoke') || (github.event_name == 'push' && github.ref == 'refs/heads/main')`
   and targets the self-hosted pool
   (`runs-on: ${{ vars.RUNNER_LABEL && fromJSON(vars.RUNNER_LABEL) || 'self-hosted' }}`).
   It is **advisory (non-required)** — never block a fork PR's merge on hardware /
   credentials only maintainers have. The rc contract is #222's: any FAIL → the
   job fails; UNAVAILABLE (quota) / SKIP → non-blocking. The SMOKE evidence lines
   are written to `$GITHUB_STEP_SUMMARY`.

3. **The gate is the security boundary.** A fork PR with **no** label NEVER
   schedules `live-smoke` — the `if:` has no unconditional branch, so untrusted PR
   code cannot self-trigger the self-hosted tier. Applying the `run-live-smoke`
   label is the **authorization act**; label application requires write access, so
   only a maintainer can authorize a live run. The workflow uses plain
   `pull_request` (with the `labeled` type so the event is delivered), **never**
   `pull_request_target` — `pull_request_target` would run with the base repo's
   token/secrets against untrusted head code (the classic injection foot-gun).

4. **The live matrix config lives OUTSIDE the checkout, and the lane is
   self-provisioning.** The matrix (`name|agent_cmd|model|env-setup` entries,
   credentials sourced in `env-setup`) must NOT sit inside the repo tree, because
   `actions/checkout` defaults to `clean: true` (`git clean -ffdx`) and would
   delete a gitignored `tests/e2e/e2e.conf` before the run step — the job would
   then die on `FATAL: matrix not found/readable` instead of proving the matrix
   (PR #256 review [P1]). The `live-smoke` job resolves the matrix from the first
   of three sources that hits, exports the result as `SMOKE_CONF` to `$GITHUB_ENV`
   (the harness honors the `SMOKE_CONF` override), and **preflights its
   readability**:
   1. **`RUNNER_SMOKE_CONF`** repo variable — a PATH to a runner-local matrix file.
   2. **`SMOKE_MATRIX`** repo variable — the matrix **CONTENT**, materialized at
      job time to a runner TEMP file (`mktemp` under `$RUNNER_TEMP`, outside the
      checkout). This is the **self-provisioning** channel and the one that works
      on the shared pool: the self-hosted fleet is an **ephemeral autoscaling
      spot pool**, so a per-box file does NOT survive pool churn — a labeled run
      lands on a fresh runner with no file. A repo variable travels with the repo,
      so any pool runner materializes the same matrix (cycle-11 [P1] fix). It is
      consumed as a quoted shell env var (never `${{ }}`-inlined into the run
      block), so its content cannot be parsed as workflow/shell syntax;
      maintainer-only (a repo variable needs write access) and MUST NOT carry
      secrets (Bedrock entries use the runner instance role; key entries source a
      runner-local secrets file inside `env-setup`).
   3. **`$HOME/.config/autonomous-dev-team/e2e.conf`** — a stable per-box default
      for a pinned, long-lived runner.
   If none resolve, the preflight emits a `::error::` + a provisioning pointer
   (naming all three sources) rather than the opaque harness FATAL.

5. **The matrix is seeded only from a TRUSTED template — never from the PR
   checkout.** The matrix `env-setup` is `eval`'d by the harness on the
   self-hosted runner, so its content is code. On a **labeled fork PR**,
   `actions/checkout` checks out the fork HEAD, so the in-checkout
   `tests/e2e/e2e.conf.example` is **attacker-controlled** — seeding `SMOKE_MATRIX`
   / the per-box file from that copy would persist arbitrary shell on the runner
   and into future runs (PR #256 review [P1], cycle 12). All provisioning guidance
   (the preflight job-summary pointer, `CONTRIBUTING.md`, `tests/e2e/e2e.conf.example`)
   therefore sources the template from `main` (`gh api …/contents/…?ref=main`) or a
   local trusted clone — never `cp tests/e2e/e2e.conf.example` from the checkout —
   and tells the maintainer to review before use.

6. **An always-on, non-failing status summary covers the unlabeled PR.** The
   label-gated `live-smoke` job never runs on an unlabeled PR, which would leave it
   with no explanation of the live tier (the `Keesan12` requirement, PR #256
   review [P1], cycle 12). A separate **`live-smoke-status`** job — hermetic
   (`ubuntu-latest`, credential-free), **always runs** (no label gate), never
   fails — writes a `$GITHUB_STEP_SUMMARY` stating whether the live tier was
   scheduled for this event or **intentionally skipped pending a maintainer
   `run-live-smoke` label**. It reads the event context via env vars (never
   `${{ }}`-inlined into the run block).

**Why**: the #222 live smoke needs authenticated CLIs (claude/codex/kiro/agy via
IAM/quota) that only the self-hosted box has. If it landed as an unconditional
job, every fork PR would go permanently red (auth-less GitHub-hosted runners),
training everyone to ignore CI; and exposing a self-hosted runner to untrusted PR
code unconditionally is a host-compromise vector that the operator's public-repo
CI guidance forbids. Splitting hermetic (always-on, fork-green) from live
(maintainer-gated, self-hosted, advisory) is the minimal compliant design. (#238,
gates #222 + anchors on [INV-74](#inv-74-adapter-conformance-is-regression-pinned-by-a-hermetic-fixture-manifest-runner).)

**Producer**: `.github/workflows/ci.yml` (the `hermetic-*` jobs, the label-gated
`live-smoke` job + its preflight, and the always-on `live-smoke-status` reporter);
`setup-labels.sh` (defines the `run-live-smoke` gate label so it exists on day one).

**Consumer**: GitHub Actions (schedules jobs per the `on:` triggers + `if:`
gate); maintainers (apply `run-live-smoke` to authorize a live run; set the
`SMOKE_MATRIX` repo variable to self-provision the matrix on the autoscaling
pool); branch protection (marks the two `hermetic-*` jobs required, `live-smoke`
not).

**Tested by**:
- `tests/unit/test-ci-two-tier-lanes.sh` (TC-CI-TIERS-010..051) — structural
  truth-table assertions over `ci.yml` (pyyaml): hermetic jobs are
  `ubuntu-latest` + credential-free; `live-smoke.if` matches the label-OR-push
  gate; no `pull_request_target`; `pull_request` declares `labeled`; `live-smoke`
  invokes `run-agent-smoke.sh`, targets self-hosted, writes a job summary;
  resolves the matrix config OUTSIDE the checkout (TC-CI-TIERS-021: `RUNNER_SMOKE_CONF`
  + `$HOME`-based default), is self-provisioning via the `SMOKE_MATRIX` repo
  variable materialized to a temp file (TC-CI-TIERS-024/025), exports it via
  `$GITHUB_ENV` (022), and preflights its readability with a loud `::error::`
  (023); the always-on `live-smoke-status` job reports skip/scheduled on every PR
  and is hermetic (TC-CI-TIERS-026/027); the provisioning pointer seeds only from a
  trusted `main` template, never the PR checkout (TC-CI-TIERS-028); and
  `setup-labels.sh` defines `run-live-smoke`.
- `hermetic-shellcheck`'s `actionlint` step — deeper workflow syntax +
  `pull_request_target` foot-gun lint (belt-and-suspenders to the gate-logic test).
- `docs/test-cases/ci-two-tier-lanes.md` — TC-CI-TIERS-NNN enumeration + the
  gate truth table.

**Cross-references**:
- [INV-63](#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path) — the live matrix harness this tier runs; its three-state rc contract is why UNAVAILABLE does not fail the job.
- [INV-74](#inv-74-adapter-conformance-is-regression-pinned-by-a-hermetic-fixture-manifest-runner) — the hermetic conformance suite that anchors Tier 1.

## INV-78: review verdicts resolve from a typed artifact FILE first; comment scraping is an explicitly-logged fallback; a malformed artifact is loud, never a silent absent

_Triage (issue #236): [machine-checked: tests/unit/test-verdict-artifact.sh]_

> **Note**: authored as INV-76 (next free number when `main` was at INV-75), then
> renumbered to **INV-78** across two rebases: PR #258 (smoke no-response retry,
> issue #257) landed INV-76 on `main`, then PR #256 (two-tier CI lanes, issue #238)
> landed INV-77 — so this section took the next free number per the standard
> duplicate-heading / broken-anchor avoidance (see "Adding a new invariant"). The
> number is disambiguated by issue #233.

**Rule**: the review wrapper resolves each fan-out agent's PASS/FAIL verdict from
a typed **verdict artifact FILE** the agent wrote — the adapter-spec v1 artifact
([adapter-spec.md § 5](adapter-spec.md#5-the-verdict-artifact-contract), schema
[`verdict-artifact.schema.json`](schemas/verdict-artifact.schema.json), #229 /
[INV-66](#inv-66-adapter-conformance-is-spec-defined)) — **before** any comment
scraping. Comment detection ([INV-20](#inv-20-the-review-wrapper-must-only-act-on-its-own-verdict-comment) /
[INV-40](#inv-40-multi-agent-review-aggregates-under-unanimous-pass-each-agents-verdict-is-attributed-by-a-review-agent-discriminator) /
[INV-53](#inv-53-the-codex-review-convergence-detector-keys-on-the-verdict-trailer-not-any-agent_message))
survives **only** as a fallback for an agent that produced **no** artifact, and
that fallback is **explicitly logged** (`verdict-source=comment-fallback`) so the
per-CLI fallback rate is measurable ([#228](#)) — the signal that gates eventual
fallback removal.

The artifact's `verdict.state` (adapter-spec § 4.3) drives resolution:

- `valid` (schema-pass) → seed the agent's verdict from the artifact
  (`PASS`→pass / `FAIL`→fail); **no comment poll for that agent**. When EVERY
  agent produces a valid artifact the wrapper resolves the whole fleet with
  **ZERO** comment-list API calls.
- `malformed` (file present, schema-fail) → **LOUD** handling: surface an operator
  [error envelope](#inv-72-config-class-failures-must-surface-on-the-issue-never-log-only)
  (#231, `code=VERDICT_ARTIFACT_MALFORMED`, `class=config`,
  `surface=issue-comment`) naming the agent + the schema error, AND treat the
  artifact as **absent for the vote** (adapter-spec § 4.3 Clause V1 —
  fail-safe-not-fail-open: a malformed artifact is **NEVER** coerced into a silent
  PASS, and the agent's own comment is **NOT** consulted to override it). The
  agent then resolves via the terminal sweep (rc 124/137 → `timed-out` veto, else
  `unavailable` drop), exactly as an absent verdict.
- `absent` (no file within the window) → today's bounded-retry/drop semantics,
  resolved by the comment fallback + the post-window sweep — **unchanged**. This
  invariant moves the verdict **CHANNEL**, not the absence model
  ([INV-43](#inv-43-the-verdict-poll-budget-scales-with-the-command-mode-e2e-timeout) /
  [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto)
  still govern absence).

**Atomic write + TRUE read-once + first-land freeze (Clause VA5)**: the agent
writes `<path>.tmp.$$` then `mv` (rename) into place; a half-written `.tmp` is
never the read target (no torn read). Read-once is enforced at TWO layers:
1. **First-land freeze (#233 review round-5, [P1] #2).** The fan-out observe loop
   copies each artifact's bytes to a private `<path>.landed` SNAPSHOT the moment
   it FIRST observes the final file (`_freeze_landed_artifact`), and the
   resolution loop validates that frozen snapshot — NOT a re-read of the live
   path. So a duplicate `mv` that lands in the gap between the
   `_all_artifacts_landed` early-exit signal and the later resolution replaces the
   live file but NOT the snapshot: the FIRST-landed bytes are authoritative, and
   the later rewrite is detected (`cmp` against the snapshot) and logged once as a
   duplicate. This closes the multi-second window the in-function read-once below
   does not cover.
2. **In-function read-once.** `_classify_verdict_artifact` `cat`s the (frozen)
   bytes ONCE into a private temp file and runs BOTH schema validation AND the
   identity check against that snapshot — never a second read. So a rename during
   classification cannot flip the result valid↔malformed (#233 review round-1).

**Identity binding (Clause VA4 enforcement)**: a schema-valid artifact is
accepted ONLY if its `.runId` equals the session UUID the wrapper minted for this
slot AND its `.agent` equals this agent's CLI name. A mismatch is classified
`malformed` (loud envelope, dropped from the vote) — so a buggy adapter that
copies the example JSON or writes another agent's identifiers **cannot cast a
vote for this review slot** (#233 review [P1] #2). The wrapper passes the
expected identity to `_classify_verdict_artifact <path> <session-id> <agent>`.

**Validation backend enforces the FULL schema in BOTH modes**: the preferred
python3-jsonschema path runs the full Draft-07 graph. The `jq` structural
fallback — the **default on a packaged install** (the JSON Schema lives outside
the skill tree, so `npx skills add` does not ship it) — mirrors the schema's
shape rather than checking a few top-level keys: `additionalProperties:false` at
every level, the finding object shape (`title` required string; only the known
finding keys; `line` an integer ≥0), the typed `evidence` sub-objects, and the
FAIL⇔≥1-blocking both-directions rule. A schema-invalid payload (e.g. PASS with
`blockingFindings` as an object, a finding without `title`, an unknown key) is
therefore rejected as `malformed` in the default deployment, not silently
accepted (#233 review [P1] #3).

**post-verdict.sh stays the ONLY comment poster** ([INV-56](#inv-56-review-agents-post-their-verdict-comment-only-through-post-verdictsh)):
agents still post their human-facing verdict comment through it, and the wrapper
still renders ONE aggregate verdict comment + the `<!-- review-verdict: … -->`
trailer ([INV-35](#inv-35-the-review-wrapper-emits-a-machine-readable-verdict-trailer-comment)) —
the rendered comment format is **unchanged**, so every machine consumer of the
comment channel keeps working: the dispatcher's `classify_recent_review_verdict`
(INV-03/06/07) and the dev-resume `Review findings:` parser
([INV-57](#inv-57-a-standing-approval-is-not-terminal-if-a-newer-findings-comment-exists)).
The artifact is the wrapper's **own aggregation** parsing surface; the comment is
the **human record + the fallback channel**.

**Human-facing body derived from the artifact (#233 review round-4/5, [P1] #1)**: a
`valid` artifact populates `AGENT_VERDICT_BODIES` from a body RENDERED off the
artifact (`_verdict_body_from_artifact_json` — `Review PASSED …` / `Review
findings:` + numbered blocking list, matching the phrasing the poller and
post-verdict.sh key on). This makes `LATEST_COMMENT` non-empty whenever any agent
resolved `valid`, so the `Reviewed HEAD` trailer (INV-04) posts and the FAIL
branch takes the SUBSTANTIVE path. The render is a pure string transform (no API,
no comment poll — the zero-comment-poll AC holds).

The wrapper then posts **EXACTLY ONE wrapper-owned AGGREGATE verdict comment** from
`AGGREGATE` (round-5), rendered from the deciding bodies in `LATEST_COMMENT` and
posted via `post-verdict.sh` (INV-56 sole-poster). This replaced a per-agent
breadcrumb-gated re-post that had two defects: an agent reaped BEFORE it ever
called `post-verdict.sh` left no breadcrumb → no rendered comment at all; and
multiple breadcrumb-leaving agents could emit CONTRADICTORY per-agent PASS+FAIL
comments. The aggregate post is gated on **at least one DECIDING agent being
artifact-sourced** (`_any_deciding_artifact`): if the deciding surface was
entirely comment-channel the agents already posted their own comment (today's
behavior — no wrapper post, no double-post); if any deciding agent was
artifact-sourced its human surface may be missing, so the wrapper renders the
authoritative aggregate. It guarantees a comment when **the artifact is the only
successful channel**, and the single aggregate is the newest `Review findings:` /
`Review PASSED` comment so dev-resume's INV-57 newest-wins semantics consume it.

**Timeout-veto folded into the aggregate (round-6, [P1]).** Because the aggregate
renders `LATEST_COMMENT`, an INV-48 timeout veto MUST be present in that body —
otherwise a MIXED fleet (one agent resolves a PASS artifact, another times out →
aggregate FAIL by the veto) would render a newest comment showing only the PASS
body, hiding the blocking timeout reason. So the timeout-veto blocking finding is
folded into `LATEST_COMMENT` **unconditionally** when any agent timed out (not only
when `LATEST_COMMENT` is empty), and the standalone INV-48 timeout comment is
SKIPPED when the aggregate will carry it (`_any_deciding_artifact` true) so there is
no duplicate. The newest wrapper-rendered comment therefore always states why the
run failed.

**Live verdict-resolution completion signal (#233 review round-4, [P1] #2;
generalized in [INV-84](#inv-84-the-fan-out-observe-loop-early-exit-fires-once-every-agent-slot-has-a-resolved-first-verdict-artifact-frozen-or-comment-observed--not-when-every-artifact-file-exists), #271)**: the
fan-out join is a bounded OBSERVE loop, not a blocking `wait`. It breaks on EITHER
(a) every collected `_fanout_pids` PID exited (`kill -0` — the backstop, which
inherits each agent's `_run_with_timeout` 124/137 cap so INV-48's timeout-veto rc
is preserved) OR (b) **every agent slot has a resolved first verdict**
(`_all_first_verdicts_resolved` — the early exit; INV-84). A slot is resolved when
its artifact's first-land snapshot classifies **valid** (`_classify_verdict_artifact`
with the slot identity) OR (for a comment-only agent that never writes an artifact
file) its verdict comment is observed via the comment poll. A landed/posted verdict
is therefore not held hostage by an agent that hangs in `post-verdict.sh` /
teardown until the wall-clock cap.

> **Superseded sub-rule (#233 → #271):** round-4 gated this early exit on
> `_all_artifacts_landed` — an artifact-FILE-existence check over every slot. That
> was permanently DEAD on a MIXED panel (an artifact-writer + a comment-only agent
> that never writes a file), letting a single lingering PID pin the loop to the 6h
> ceiling (#271). INV-84 replaces it with the per-slot first-verdict-resolved gate
> above. The INV-48 property is unchanged: a slot we early-exit past is ALREADY
> resolved with a VALID verdict (its verdict wins over its rc, INV-40); any
> unresolved slot — no VALID artifact (a `malformed` snapshot does NOT count), no
> comment — keeps the gate false, so the loop keeps waiting on PIDs and that agent
> still gets its real 124/137 rc. `_all_artifacts_landed ⟹
> _all_first_verdicts_resolved` therefore holds only for VALID artifacts; an
> all-valid-artifact panel is byte-for-byte unchanged.

A still-running
agent the loop early-exits past is group-killed by `_reap_fanout_processes` after
resolution (its PGID sidecar is written at spawn by `_run_with_timeout`).
(Edge case, consistent with Clause V1: an agent that writes a MALFORMED artifact
and then hangs is NOT early-exited past — INV-84's gate classifies the snapshot and
a `malformed` one is treated absent, so the loop keeps waiting on its PID, and the
agent resolves `unavailable`/`malformed-output` on a clean exit or the `timed-out`
veto on a 124/137 cap, exactly like a no-artifact hang. The pre-#271-review code
gated on file EXISTENCE not validity and would have reaped it early — see
[INV-84](#inv-84-the-fan-out-observe-loop-early-exit-fires-once-every-agent-slot-has-a-resolved-first-verdict-artifact-frozen-or-comment-observed--not-when-every-artifact-file-exists)
"Malformed artifact ⇒ NOT resolved".)

- **Path**: `${XDG_STATE_HOME:-$HOME/.local/state}/autonomous-<project>/runs/<run-id>/verdict-<agent>.json`,
  where `<run-id>` is the per-agent minted session UUID (the `Review Session:`
  trailer, INV-20). One run-dir per agent run → no collision across a
  multi-codex fleet. Provisioned (mkdir 0700) + injected into the prompt + exported
  as `VERDICT_ARTIFACT_PATH` by `autonomous-review.sh`.
- **Producer**: each review agent (instructed by `build_review_prompt`); the
  wrapper itself for the codex stdout fallback (a no-artifact path) AND for an
  artifact-resolved agent whose own `post-verdict.sh` comment failed (the INV-69
  breadcrumb-gated artifact-derived re-post above).
- **Consumer**: `autonomous-review.sh` (the artifact-first resolution loop),
  `lib-review-artifact.sh` (`_verdict_artifact_path` / `_classify_verdict_artifact`
  / `_verdict_from_artifact_json` / `_artifact_schema_error`), and
  `lib-review-poll.sh::_run_verdict_poll_loop` (skips already-resolved + malformed
  agents).
- **Scope**: review side only. The dev side keeps comment parsing; comment
  fallback is NOT removed (only after #228 metrics show fallback rate ~0 across the
  fleet). Token scoping / env scrubbing is a separate issue.
- **Why** (#233): the verdict-attribution machinery (INV-20/40/53 — actor
  matching, time windows, trailer discriminators, comment polling) exists ONLY
  because verdicts travel through comments, and it produced a long incident tail —
  double-posts, silent non-posts (the agy [INV-56](#inv-56-review-agents-post-their-verdict-comment-only-through-post-verdictsh)
  bug), narration false-convergence (codex INV-51/53), propagation lag (INV-43). A
  file has no actor ambiguity and no propagation delay, and schema validation makes
  a malformed verdict a loud, distinct state. This is the redesign's highest-payoff
  change (it kills factory A).
- **Test**: `tests/unit/test-verdict-artifact.sh` (TC-VERDICT-ARTIFACT-NNN) —
  valid/malformed/absent classification, atomic-rename / duplicate / late-write,
  **true read-once (single path read, TC-038)**, **identity binding (matching →
  valid, foreign runId/agent → malformed, TC-039)**, **the jq fallback enforcing
  the full schema shape (TC-040: empty-object findings, finding-without-title,
  additional-property, non-array finding lists all rejected)**, path provisioning,
  aggregation precedence (artifact > comment; conflict logged), the
  zero-comment-poll AC, malformed → loud envelope + treated-absent, comment-
  fallback parity, the timeout-veto regression pin, **the human-facing body
  rendered from the artifact (TC-041..047: PASS/FAIL first-line phrasing, no
  double-prefix, LATEST_COMMENT non-empty, round-trips through
  `_classify_verdict_body`, still zero comment polls)**, **the single wrapper-owned
  AGGREGATE verdict comment gated on a deciding artifact source (W16, W17a-c — the
  per-agent breadcrumb re-post is removed)**, **the timeout-veto finding folded
  into the aggregate body in a mixed fleet so the newest comment always states the
  failure (TC-050, W24a-c)**, **the `_all_artifacts_landed`
  completion-signal helper + the ALL-artifacts-landed early-exit gate (TC-048,
  W18-W19)**, and **the first-land freeze: `_freeze_landed_artifact` snapshots the
  first bytes, a later differing write is reported `duplicate` + logged, and the
  resolved verdict is the first land (TC-049, W20-W22)**; plus the conformance
  manifests asserting `verdict.state` from artifact files and the stub-fleet E2E
  (`run-verdict-artifact-fleet-e2e.sh`) covering a foreign-identity agent.

**Cross-references**:
- [`adapter-spec.md` § 4.3 / § 5](adapter-spec.md#43-verdict--state-payloadref-payloadref-required-when-state--valid) — the NORMATIVE verdict axis + artifact contract this implements.
- [INV-20](#inv-20-the-review-wrapper-must-only-act-on-its-own-verdict-comment) / [INV-40](#inv-40-multi-agent-review-aggregates-under-unanimous-pass-each-agents-verdict-is-attributed-by-a-review-agent-discriminator) / [INV-53](#inv-53-the-codex-review-convergence-detector-keys-on-the-verdict-trailer-not-any-agent_message) — the comment-attribution machinery this demotes to a fallback.
- [INV-56](#inv-56-review-agents-post-their-verdict-comment-only-through-post-verdictsh) — post-verdict.sh stays the sole comment poster.
- [INV-35](#inv-35-the-review-wrapper-emits-a-machine-readable-verdict-trailer-comment) — the rendered aggregate trailer (the dispatcher's machine channel) is unchanged.

## INV-79: in app mode the agent process gets ONLY a scoped token; the wrapper keeps full-write and is the sole approve/merge/PR-create path

_Triage (issue #236): [machine-checked: tests/unit/test-token-split-234.sh]_

> **Note**: authored as INV-76, renumbered to **INV-79** across three rebases —
> PR #258 (smoke `no-response`, #257) took INV-76, PR #256 (two-tier CI, #238) took
> INV-77, and PR #262 (verdict-artifact channel, #233) took INV-78 on `main` before
> this PR merged, so this section took the next free number per the standard
> duplicate-heading / broken-anchor avoidance (see "Adding a new invariant"). The
> number is disambiguated by issue #234.

**Rule**: in `GH_AUTH_MODE=app`, the autonomous **agent** subprocess is launched
with ONLY a SCOPED GitHub-App installation token (`contents:write`,
`issues:write`, `pull_requests:read` — `AGENT_TOKEN_PERMISSIONS`); the
**wrapper's** full-write token (`pull_requests:write`) is NEVER reachable from the
agent subtree. Concretely the agent launch env (assembled CLI-agnostically in
`_run_with_timeout`) has: `GH_TOKEN_FILE`=the **scoped** token file
(`AGENT_GH_TOKEN_FILE`, kept fresh by the scoped refresh daemon — so the agent's
`gh` is REFRESH-AWARE past the 1h App-token TTL, NOT a one-time snapshot that goes
stale on long runs — #234 review [P1]); `GH_TOKEN`=the scoped token as a snapshot
fallback (the shim re-reads the file and overrides it, so the fresh file wins);
`GITHUB_PERSONAL_ACCESS_TOKEN` (the App-token alias) **unset**. `GH_USER_PAT` is
ALSO **scrubbed** — it is a host-user PAT (typically `repo`-scoped), and a scoped
agent retaining it could `export GH_TOKEN="$GH_USER_PAT"` (or invoke `gh-as-user.sh`)
to regain approve/merge, defeating this invariant (#234 review [P1] f97959a3). The
agent's only legitimate use of `GH_USER_PAT` — posting the real-user bot-trigger
comments (`/q review` etc., which reject GitHub-App bot accounts; autonomous-dev
SKILL Step 10/11) — is now **brokered**: the agent writes the trigger phrase(s) to
`AGENT_BOT_TRIGGER_FILE` and the WRAPPER posts them via `gh-as-user.sh` post-run
(`drain_agent_bot_triggers`), keeping `GH_USER_PAT` in the wrapper shell only. The
wrapper's full-write token file (a DIFFERENT path) is NEVER exposed. `PATH` is **rewritten**: the
wrapper's per-run `GH_WRAPPER_DIR` shim entry is **stripped** (AC #1 — the agent env
dump shows "no wrapper gh shim") and the agent's OWN per-run shim dir
(`AGENT_GH_SHIM_DIR`, with its own `gh → gh-with-token-refresh.sh` symlink) is
**prepended** in its place — so the agent's bare `gh` (review-prompt
`gh issue view`/`gh pr checks`, vendored helpers like `mark-issue-checkbox.sh`)
still resolves a `gh` on `REAL_GH`/non-interactive-PATH hosts (#92), resolving the
AGENT-own shim rather than the wrapper's. The agent shim reads the SCOPED
`GH_TOKEN_FILE` and `exec gh` with the fresh scoped token, so bare `gh` keeps
working, stays fresh, AND authenticates scoped (keeping the WRAPPER shim on PATH
violated AC #1; stripping all shims broke bare `gh`; snapshotting the token once
went stale — all three were #234 review [P1]s, reconciled by the agent-own shim).
The wrapper retains the
full-write token in its OWN shell and is the SOLE actor that flips labels,
approves, merges, posts the verdict, brokers `gh pr create` (the scoped token
cannot create a PR — `pull_requests:read`), and brokers the browser-E2E report.
This is the credential-level enforcement of the approve/merge gates
([INV-44](#inv-44-the-wrapper-owns-the-mergeability-gate-merge-only-when-githubs-mergeable-true-not-the-agents-claim) /
[INV-52](#inv-52-a-substantive-fail-asserts-the-prs-github-native-state-not-just-a-comment)):
an agent that runs `gh pr review --approve` / `gh pr merge` gets a deterministic
**403** from its token, independent of the (claude-only) PreToolUse hook layer
(which misses `gh api` and non-claude CLIs — the #191/#193 incident class).

- **Producer**: `lib-auth.sh` — `setup_agent_token` mints the scoped token (via
  `get_gh_app_scoped_token` → the `permissions` body in `gh-app-token.sh`) into
  `AGENT_GH_TOKEN_FILE` and starts a second `gh-token-refresh-daemon.sh` keyed on
  the permissions (refresh integrated, [INV-31] class); `build_agent_env_argv`
  emits the scrub `env`-prefix; `drain_agent_pr_create` brokers `gh pr create`;
  `drain_agent_bot_triggers` brokers the real-user bot-trigger comments via
  `gh-as-user.sh` **constrained to an allow-list** (3rd arg) — only lines that
  exactly match a configured `REVIEW_BOTS` trigger phrase are posted; any other
  line is rejected with a WARN and an empty allow-list is fail-closed (post
  nothing), so the broker cannot be turned into an arbitrary post-as-user channel
  by a compromised agent; `cleanup_github_auth` reaps the second daemon.
  `lib-review-bots.sh` supplies `bot_trigger_allowlist <REVIEW_BOTS>` (the exact
  configured trigger phrases, one per line) and `missing_bot_reviews <REVIEW_BOTS>
  <PR> <REPO>` (short-names of configured bots with no review on the PR; a `gh`
  failure counts a bot as MISSING — fail-closed).
- **Consumer**: `lib-agent.sh::_run_with_timeout` prepends the scrub prefix to
  EVERY adapter invocation (CLI-agnostic — claude/codex/gemini/kiro/opencode/agy/
  generic all route through it), **before** `AGENT_LAUNCHER_ARGV` so the launcher
  runs under the scrubbed env (a scrub placed AFTER the launcher would be passed
  to it as positional `$@` and never applied — #234 review [P1] #1);
  `autonomous-dev.sh` / `autonomous-review.sh` call `setup_agent_token` after
  `setup_github_auth`; the dev wrapper drains the PR-create broker, and BOTH its
  normal prompt and the [INV-45] open-PR fast-path block route `gh pr create`
  through that broker when scoping is armed (the fast path would otherwise 403 on
  a direct create — #234 review [P1] #2); the dev wrapper also drains the
  bot-trigger broker (posts `/q review` etc. via `gh-as-user.sh`, since the agent's
  `GH_USER_PAT` is scrubbed — #234 review [P1] f97959a3); the review wrapper posts
  the brokered E2E report (`lib-review-e2e.sh::_post_brokered_e2e_report`) AND
  enforces a **mandatory-bot-review hard gate** before approving: because the
  scoped review prompt brokers its bot triggers (the agent itself cannot post as
  the user) and the broker only runs in `cleanup`, a `PASSED_VERDICT` could
  otherwise be approved+merged BEFORE the configured `REVIEW_BOTS` have actually
  reviewed. So in the PASS branch (after the PR-open guard) the wrapper computes
  `missing_bot_reviews`; if non-empty and the SHA-bound wait count is `<
  BOT_REVIEW_WAIT_MAX` (3) it re-queues `−reviewing +pending-review` with a
  `failed-non-substantive` `awaiting-bot-review` trailer + a SHA-bound
  `<!-- bot-review-wait sha=… -->` marker (the next tick re-reviews once the bot
  review lands); at/after the max it is a substantive FAIL → `+pending-dev` +
  `gh pr review --request-changes` (the bot is misconfigured/down — a maintainer
  investigates). This is the wrapper-owned enforcement that the prompt's "Do NOT
  FAIL on an absent bot review" instruction relies on — the agent never blocks on
  the bot; the wrapper does — #234 review [P1] 37450359.
- **Degraded mode (PAT)**: `GH_AUTH_MODE=token` — a PAT cannot be down-scoped at
  mint, so there is NO second token. `setup_agent_token` logs a ONE-TIME WARN
  ("enforcement degraded to convention in PAT mode"), `build_agent_env_argv`
  emits an EMPTY prefix (no scrub), and behavior is byte-identical to pre-INV-79.
  An app-mode scoped-mint failure degrades the same way (WARN + no scrub) —
  availability over the defense-in-depth bonus.
- **Containment boundary (NOT isolation)**: same OS user, so the agent could read
  the wrapper's token file off disk if it deliberately went looking — this is
  defense-in-depth, not a sandbox. OS-user / container isolation is out of scope
  (#234). What it buys: the token the agent's `gh` *uses* cannot approve/merge.
- **Why** (#234): agents inherited the wrapper's full-write token via exported
  env, so an agent could `gh pr review --approve` + `gh pr merge` itself, bypassing
  the wrapper gates (the #191 self-merge incident class). Scoping turns "agent CAN
  merge" into "agent's token CANNOT merge".
- **Test**: `tests/unit/test-token-split-234.sh` (TC-TOKEN-SPLIT-NNN) — scoped
  mint body, daemon permissions forwarding, `setup_agent_token` app/PAT paths, the
  one-time PAT WARN, `build_agent_env_argv` scrub assembly, the env-dump
  verify-by-construction gate via the real `_run_with_timeout` (no full-write
  credential + no shim PATH in the agent env), the `pull_requests:read` scope pin,
  the PR-create broker, the E2E report broker, the bot-trigger broker allow-list
  (exact-match accept, non-trigger reject, fail-closed empty), the
  `bot_trigger_allowlist` / `missing_bot_reviews` helpers, and a source-level lock
  that the review wrapper's PASS branch wires the mandatory-bot-review hard gate
  (`missing_bot_reviews` → `pending-review` / `pending-dev`).

## INV-80: the label state machine is a CI-checked executable spec — the mermaid diagram is generated, undeclared label transitions fail CI

_Triage (issue #236): [machine-checked: tests/unit/test-spec-drift.sh]_

> **Note**: authored as INV-78 (next free number when this PR was drafted), then
> renumbered to **INV-80** across two rebases: PR #262 (verdict-artifact channel,
> issue #233) landed INV-78 on `main`, then PR #261 (two-token split, issue #234)
> landed INV-79 — so this section took the next free number per the standard
> duplicate-heading / broken-anchor avoidance (see "Adding a new invariant"). The
> number is disambiguated by issue #236.

**Rule**: The issue-label state machine is encoded as data in [`transitions.json`](transitions.json) (schema: [`schemas/transitions.schema.json`](schemas/transitions.schema.json)), and three CI checks (the `spec-drift` job, `scripts/check-spec-drift.sh`) keep it in lockstep with the dispatcher/wrapper code:

1. **Generated diagram** — the mermaid block in [`state-machine.md`](state-machine.md) is generated FROM `transitions.json` by `scripts/gen-state-machine.sh` (marker-delimited region). Hand-editing inside the markers, or editing the table without regenerating, fails CI (`gen-state-machine.sh --check` diffs and exits non-zero).
2. **Guard/action mapping** — every `guard`/`action` token in `transitions.json` maps (via [`spec-guard-map.json`](spec-guard-map.json)) to a named function or greppable predicate that MUST still resolve in `lib-dispatch.sh` / the wrappers. A token with no mapping, or a mapped anchor that no longer resolves, fails CI naming the pair. (The map keys on function names + grep-stable literals, NEVER line numbers.)
3. **Label-write-site completeness** — five sub-checks (plus a variable-write ban) over every `label_swap` arg + every `--add/--remove-label` literal in the four pipeline files. **C.1 vocabulary**: each label literal written must appear in `transitions.json` as a state or `actions[]` entry (catches a brand-new label, e.g. a typo). **C.2 movement**: each write *site*'s `(removes→adds)` movement — the set it removes plus the set it adds, normalized as `<sorted-removes>|<sorted-adds>` — must equal the `(remove-label:…, add-label:…)` actions of some transition (catches a write that reuses *known* labels in an **undeclared combination**, e.g. `label_swap "$n" "approved" "stalled"`). **C.3 code-site coverage**: C.2 is movement-*set* membership, so two transitions sharing one movement make a row's deletion invisible. [`spec-codesite-map.json`](spec-codesite-map.json)'s `code_sites` pins every **code-bearing** transition (actor ∉ {maintainer, github}) to a grep-stable anchor, checked both ways — *forward* (anchor still greps) and *reverse* (every key is a live transition id); deleting `dispatch-pending-dev-pr-exists` (movement shared with `dispatch-review-aware-reroute-review`) orphans its entry → **CI red**. **C.4 discovered-site reconciliation**: a NEW site whose movement already exists elsewhere passes C.2/C.3, so C.4 requires the count of literal write sites per `(file, movement)` to equal the count of `spec-codesite-map.json`'s `sites[]` manifest entries — an added/removed/duplicate site drifts the count → **CI red**. **C.5 per-site anchor adjacency**: C.4 is a *count*, so RELOCATING a write within a file (same movement, count unchanged) is invisible; each `sites[]` entry's `anchor` must therefore grep **exactly once** AND have a write of its `movement` within ±8 lines — moving the `label_swap "$n" "pending-dev" "pending-review"` out of `handle_pending_dev_pr_exists()` leaves its anchor with no adjacent write → **CI red**. **P1.1 variable-write ban**: a variable-valued `--add/--remove-label "$x"` is a hard **CI red** (not a NOTE) unless its enclosing function is in `variable_write_allowlist` (the `label_swap` helper + the `hygiene_strip_residual_labels` loop) — a variable write could inject an undeclared label invisibly. (C.4/C.5 counts are over CODE SITES, not rows: one site can back several rows and one row can collapse several physical paths, so the count is the stable quantity.) Together C.1+C.2+C.3+C.4+C.5 + the ban make "a PR adding (even a duplicate / shared-movement / relocated / variable) or removing a label-write site without the matching transitions.json entry fails CI" actually hold. Each fails CI with an actionable message naming the orphan label / undeclared movement / orphaned-or-unmapped transition / stale-or-ambiguous anchor / unaccounted-or-count-mismatched site / relocated write / non-allowlisted variable write.

The typed inputs the guards read are enumerated in [`observation-snapshot.md`](observation-snapshot.md) (schema: [`schemas/observation-snapshot.schema.json`](schemas/observation-snapshot.schema.json)), including the SSM-indeterminate third liveness state ([INV-30]).

**Why**: "Docs are authoritative" had no enforcement — the hand-drawn diagram and the transition table drifted from ~11K lines of bash silently, and every drift is a future incident (issue #236). This is the **CI-checker half** of the executable-spec pillar; the runtime reconciler (single-writer enforcement that refuses undeclared transitions at dispatch time) is the gated/stop-ruled phase and would consume the same `transitions.json` unchanged. This invariant changes ZERO dispatch behavior — it documents and gates the existing machine.

**Producer**: `transitions.json`, `spec-guard-map.json`, `spec-codesite-map.json`, `gen-state-machine.sh`, `check-spec-drift.sh` (all additive; no runtime lib is modified).
**Consumer**: the `spec-drift` CI job (`.github/workflows/ci.yml`); `state-machine.md`'s generated region.
**Status**: **ENFORCED** in this PR (closes #236). The runtime reconciler remains out of scope (gated phase).
**Test**: `tests/unit/test-spec-drift.sh` (generator idempotence, bidirectional drift injection, guard-map removal, label-write vocabulary completeness, **movement coverage** — TC-SPEC-GATE-035/036, **code-site coverage** — TC-SPEC-GATE-037 asserts deleting a transition row whose movement is shared elsewhere fails via the orphaned `spec-codesite-map.json` entry, TC-SPEC-GATE-038 a stale code-site anchor fails, TC-SPEC-GATE-039 full code-site coverage on the real repo, **discovered-site reconciliation** — TC-SPEC-GATE-042 asserts a NEW write site with an already-declared (shared) movement fails via the per-(file,movement) count, TC-SPEC-GATE-043 a count delta in an existing group fails, TC-SPEC-GATE-044 full reconciliation on the real repo, **anchor adjacency + variable-write ban** — TC-SPEC-GATE-045 asserts a non-allowlisted variable-valued write fails (P1.1), TC-SPEC-GATE-046 asserts relocating a write within a file (same movement) fails via C.5 anchor adjacency, TC-SPEC-GATE-047 full per-site anchor adjacency on the real repo, **equals-flag form** — TC-SPEC-GATE-050 asserts a variable-valued `--add-label=$x` write fails (P1.1 `=` form), TC-SPEC-GATE-052 asserts a literal `--add-label="frobnicate"` write fails the C.1/C.2 literal scanners (the `[ \t=]+` separator covers both the whitespace and `=` write forms), **continuation + single-quote forms** — TC-SPEC-GATE-053 asserts a variable write split across backslash-continuation lines fails (P1.1 logical-line join), TC-SPEC-GATE-054 asserts a single-quoted literal `--add-label 'frobnicate'` write fails the literal scanners (the `["']` quote class covers both quote styles), **digit-bearing label** — TC-SPEC-GATE-056 asserts a literal `--add-label "v2-blocked"` write fails (the `[a-z][a-z0-9-]*` char class matches `transitions.schema.json` exactly, so a digit/hyphen label is not silently skipped), **unquoted (bare-word) form** — TC-SPEC-GATE-057 asserts an UNQUOTED literal `--add-label frobnicate` write fails (the form-2 regex accepts a quoted-OR-bare label alternative; a bare label can never match a `$`-prefixed variable write, so the P1.1 ban still owns those — TC-SPEC-GATE-045); together these make every write form — whitespace/`=` separator, **no quote / single / double quote**, single-line/continuation, literal/variable, and any schema-legal label spelling — fail the gate, none bypasses — schema golden+negatives, triage-tag coverage).

## INV-81: every wrapper run mints a run-id and a durable per-run artifact dir; the run-id threads through logs, metrics, and every wrapper-posted comment footer; `status.sh` answers pipeline state from the dispatcher's REAL predicates (observe-only — never changes wrapper rc or labels)

_Triage (issue #236): [machine-checked: tests/unit/test-lib-run-artifacts.sh, tests/unit/test-status.sh, tests/e2e/run-run-artifacts-e2e.sh]_

> **Note**: authored as INV-79 (next free number when this PR branched off `main`),
> then renumbered to **INV-80** (PR #261 two-token split, issue #234, took INV-79),
> then again to **INV-81** at the next rebase: PR #260 (executable-spec gate, issue
> #236) landed INV-80 on `main` first, so this section took the next free number per
> the standard duplicate-heading / broken-anchor avoidance (see "Adding a new
> invariant"). The number is disambiguated by issue #235.

**Rule**: at start, each dev/review wrapper run mints a **run-id**
`<project>-<issue>-<dev|review>-<ts>` (UTC, second resolution; honors a pre-set
`RUN_ID`) and provisions a **durable** per-run directory
`${XDG_STATE_HOME:-$HOME/.local/state}/autonomous-<project>/runs/<run-id>/`
(mode 0700, [`lib-run-artifacts.sh`](../../skills/autonomous-dispatcher/scripts/lib-run-artifacts.sh)).
The dir holds:

- `meta.json` — start marker (run-id, project, issue, side, started_at, redacted
  `host_env`) rewritten at cleanup with `ended_at` + `rc` + `duration_s`.
- `run.log` — a tee of the wrapper's own stdout/stderr (seeded with a `run-dir:`/
  `tmp-log:` first-line pointer). Survives a `/tmp` wipe (reboot); the legacy
  `/tmp/agent-*.log` (append + INV-69 rotation) is **unchanged**, this is additive.
  **Reciprocally**, `run_artifacts_init` also writes a one-line `[run-artifacts]
  run-dir: … · run-id: …` breadcrumb into the legacy `/tmp/agent-*.log` itself, so
  an operator who starts from the old `/tmp` log (muscle memory) still has the
  one-hop link to the durable dir after a rotation/reboot (issue #235 requirement;
  review [P1]). The `/tmp` log is **reused across retries/resumes** for the same
  issue (dispatch-local.sh rotates only a single `.1` generation), so the CURRENT
  run must own the **top-of-file** pointer: init strips any prior `[run-artifacts]
  run-dir:` line(s) and **prepends** the active run's, keeping the prior log body
  below (#235 review [P1] r18). Without this, a plain append left the FIRST run's
  breadcrumb at the top forever and an operator reading `head -1` would land on a
  STALE run dir. The rewrite is **in place** (`cat >`, not `mv`) so the file inode
  is preserved and a concurrent open `>>` fd from dispatch-local.sh is not orphaned;
  it is safe because init runs early (before the wrapper's `exec >(tee …)` and any
  agent output, so there is no concurrent writer at that instant). Exactly one
  breadcrumb survives per run; best-effort + symlink-guarded.
- `drops.jsonl` — one `{agent, reason, ts}` line per dropped/unavailable review
  fan-out member (review side only).
- `agent-logs/<agent>.log` — the raw per-agent **controller** log (the
  deterministic `/tmp/agent-<project>-review-<issue>-<agent>.log` that EVERY CLI's
  invocation tee's into: PR-worktree setup, stream/auth failures, the wrapper's own
  per-agent diagnostics) copied by `run_artifacts_persist_log` so the per-agent
  evidence survives a `/tmp` wipe (review side; #235 review [P1]). Persisted for
  every fan-out member (pass/fail AND dropped/timed-out). A codex member ALSO gets
  its CLEAN stdout capture under `<agent>-stdout.log` — that is distinct evidence
  from the controller log (and for codex the controller log is what a pre-stdout
  failure leaves behind, so persisting the controller log — NOT the stdout alias —
  is what saves a codex that dies before emitting stdout; #235 review [P1] r16).
  The label is sanitized to `[A-Za-z0-9._-]` (path-traversal defense) and the
  subdir is symlink-guarded (CWE-59).

The run-id is:
1. **Exported** as `RUN_ID`/`RUN_DIR` so sourced libs/adapters inherit it.
2. **Threaded into every `metrics_emit`** ([INV-70](#inv-70-metrics-are-observe-only-emit-failures-never-change-wrapper-behavior))
   as `run_id=<id>` — the correlation key joining a metrics event to its run dir.
3. **Embedded in EVERY wrapper-owned comment** as a footer
   `run-id: <id> · artifacts: <dir>` — so any wrapper comment is a one-hop link to
   the raw evidence (issue #235 AC1). This is exhaustive across the wrapper's
   comment paths:
   - dev wrapper: session report, startup-failure report, no-PR retry;
   - review wrapper: the crash note, the two **wrapper-owned verdict comments**
     (the codex stdout-fallback, INV-62; and the INV-78 aggregate verdict comment —
     footered on the body file via `_append_run_footer_to_file` before
     `post-verdict.sh`), AND every wrapper-owned **diagnostic** comment: no-PR-found,
     E2E-gate fail / evidence-missing, pre-fan-out smoke FAIL / all-unavailable /
     dropped-survivor, timeout-veto, dropped-agent, mandatory-bot-review
     fail / re-queue, mergeable CONFLICTING / UNKNOWN, approval-failed fallback,
     no-auto-close manual-merge notice, and auto-merge-failure (the PR-side rebase
     marker) (#235 review [P1] r4);
   - **the operator error envelope** ([INV-72](#inv-72-config-class-failures-must-surface-on-the-issue-never-log-only)) for a
     startup-failure abort (config / auth / E2E-mode / project-dir / PID-dir):
     `lib-error.sh::error_surface` appends the footer to the rendered envelope.
     For this to carry a run dir, **`run_artifacts_init` is provisioned EARLY** in
     both wrappers — right after the `--issue` peek, BEFORE the first
     `error_surface` call — so the startup scenarios this issue set out to improve
     are exactly the ones that footer (#235 review [P1]). Two footerless-by-ordering
     exceptions remain, both acceptable: (a) `ADT_CFG_MISSING_KEY` for `PROJECT_ID`
     itself — with no project there is nothing to anchor a run dir on (run-id minting
     needs `PROJECT_ID`); and (b) the **source-time launcher guards** in
     `lib-agent.sh` (`ADT_CFG_LAUNCHER_PARSE`, `ADT_CFG_LAUNCHER_CLI_MISMATCH`, INV-38)
     — these run during `source lib-agent.sh`, which is structurally BEFORE the
     `--issue` peek + early init, so `RUN_ID` is not yet minted (init cannot move
     ahead of that source: `PROJECT_ID` is loaded BY lib-agent.sh's
     `load_autonomous_conf`). Both are rare operator-misconfig aborts; every other
     startup envelope (the config/auth/E2E/project-dir/PID-dir set surfaced from the
     wrapper body, after the early init) carries the footer.
   The footer is appended at the END of the body (after `run_footer`'s own
   `\n---\n`), so a comment whose FIRST line is a machine-parsed token
   (`Review findings:`, `Auto-merge failed:`) keeps that leading line intact; the
   error-envelope's `<!-- adt-error-envelope: … -->` marker is likewise preserved
   (footer follows it).
   **Two deliberate exceptions, both pure machine channels:** the `Reviewed HEAD:`
   SHA trailer and the `<!-- review-verdict: … -->` HTML trailer (both emitted for
   the dispatcher's detection, never operator-facing) are NOT footered — a footer
   there is noise the SHA-match / verdict regex would have to skip. An AGENT's own
   self-posted verdict runs in the scrubbed agent subtree (`RUN_DIR` unset), so it
   too is out of scope — the footer is a **wrapper-owned-comment** guarantee.

**Coordination with [INV-78](#inv-78-review-verdicts-resolve-from-a-typed-artifact-file-first-comment-scraping-is-an-explicitly-logged-fallback-a-malformed-artifact-is-loud-never-a-silent-absent)
— same `runs/` parent, distinct namespaces, NO duplication.** INV-78's per-AGENT
verdict artifacts live at `…/runs/<review-session-uuid>/verdict-<agent>.json`
where `<review-session-uuid>` is a bare RFC-4122 UUID (the minted Review Session,
[INV-20](#inv-20-the-review-wrapper-must-only-act-on-its-own-verdict-comment)).
This invariant's wrapper-run dirs are SIBLINGS under the same `runs/` parent but
always match `<project>-<issue>-(dev|review)-<ts>`. The two are structurally
distinguishable, so `status.sh` scanning + `run_prune` key on the wrapper-run-id
glob and **never touch** INV-78's per-agent UUID dirs. The verdict-artifact path
owner stays INV-78; `status.sh` only *reads* it.

**Retention**: `run_prune [days]` (default 30, `RUN_RETENTION_DAYS`) runs once per
wrapper start (best-effort, like `metrics_prune`). It removes wrapper-run-id dirs
strictly older than N days (exactly-N is retained) and **NEVER** the active run-id
(excluded by exact name match) nor INV-78's UUID dirs nor a symlinked candidate
(CWE-59). `run_artifacts_init` invokes it for **ALL issues** of the project (no
issue arg → the all-issues glob), NOT just the current issue: a run for issue N
must also reap aged dirs left by issues that never run again, or the store grows
unbounded (#235 review [P1]).

**`status.sh <issue> [--project <id>]` predicate parity.** The read-only inspector
([`status.sh`](../../skills/autonomous-dispatcher/scripts/status.sh)) **sources the
dispatcher's real predicate library** (`lib-dispatch.sh`) and answers "what will
the next tick do?" by calling the SAME functions the tick calls —
[`pid_alive`](#inv-29-the-wrapper-owns-a-heartbeat-file-the-dispatcher-reads-its-mtime),
`count_retries` ([INV-05](#inv-05-the-retry-counter-resets-at-each-stall)),
`fetch_pr_for_issue`,
[`dev_near_success`](#inv-27-dev-side-crash-declaration-is-gated-by-dev_near_success) /
[`review_near_success`](#inv-24-review-side-crash-declaration-is-gated-by-review_near_success).
It NEVER reimplements them — a divergent answer would be a NEW false-signal source,
worse than no tool. `status.sh` is strictly **read-only**: it issues no
`gh issue edit`, no `gh pr merge`, no `gh * comment`.

**Observe-only contract**: every `lib-run-artifacts.sh` function is best-effort —
a failure (unwritable XDG base, missing jq, missing PROJECT_ID) is a silent no-op
that leaves `RUN_ID`/`RUN_DIR` empty and degrades the footer/threading to no-ops.
It can **never** change a wrapper's rc or its label transitions. Same contract as
[INV-70](#inv-70-metrics-are-observe-only-emit-failures-never-change-wrapper-behavior).

**Why**: issue #235 (funded debuggability scope T2). The 2am story was grepping
append-mode `/tmp/agent-*.log` files that evaporate on reboot, with no correlation
key between a GitHub comment and the run that produced it. A run-id footer + a
durable dir turns "spelunk three logs" into "open one directory"; `status.sh`
turns "reconstruct labels + ps + PID files + read dispatcher source" into one
read-only command. Depends on #228 (metrics carry the run-id) and #233 (shared
`runs/<run-id>/` layout).

**Producer**: `autonomous-dev.sh` + `autonomous-review.sh` (mint/init/finalize/
footer/drop, thread `run_id` into metrics). **Consumer**: operators (via the
footer + `status.sh`); the metrics aggregator (run-id is an additive field).

**Tests**: `tests/unit/test-lib-run-artifacts.sh` (TC-RUN-ARTIFACTS-001..039 —
minting/uniqueness, init/finalize, footer, prune age-boundary + never-active +
INV-78 UUID untouched), `tests/unit/test-status.sh` (TC-RUN-ARTIFACTS-040..051 —
four canonical states, read-only contract, predicate-parity grep-assert),
`tests/e2e/run-run-artifacts-e2e.sh` (TC-RUN-ARTIFACTS-080..085 — stub dev+review
cycle, status.sh snapshot, reboot simulation, footer→dir round-trip).

**Cross-references**:
- [INV-70](#inv-70-metrics-are-observe-only-emit-failures-never-change-wrapper-behavior) — the observe-only sibling; metrics events now carry `run_id`.
- [INV-78](#inv-78-review-verdicts-resolve-from-a-typed-artifact-file-first-comment-scraping-is-an-explicitly-logged-fallback-a-malformed-artifact-is-loud-never-a-silent-absent) — the per-agent verdict artifact channel sharing the `runs/` parent.
- [INV-69](#inv-69-on-re-dispatch-the-prior-runs-agent-log-is-rotated-to-a-single-1-generation-not-truncated) — the legacy `/tmp/agent-*.log` rotation that `run.log` complements (does not replace).
- [`debugging.md`](debugging.md) — the 2am runbook: comment footer → run-id → dir → what's in it → `status.sh`.

## INV-82: the workflow-enforcement hooks' `is_git_command` quote-strip MUST terminate on every input — a glob-significant char inside a quoted region can never spin the strip loop

_Triage (issue #236): [machine-checked: tests/unit/test-is-git-command-quote-strip.sh]_

**Rule**: `is_git_command(operation, command)` in
[`skills/autonomous-common/hooks/lib.sh`](../../skills/autonomous-common/hooks/lib.sh)
strips single- and double-quoted regions from `command` before scanning for a
`git <operation>` invocation, so an incidental mention inside a quoted argument
(`--body "see git push docs"`) cannot trip a gate. The strip loops
(`while [[ "$stripped" =~ … ]]; do stripped="${stripped/…/ }"; done`) MUST make
forward progress on **every** input and terminate in bounded time. They MUST NOT
busy-loop, regardless of what characters the quoted region contains.

**Why**: the strip fed the regex match into a bash **glob-pattern** substitution
**unquoted** — `${stripped/${BASH_REMATCH[0]}/ }`. The first operand of
`${var/pattern/repl}` is interpreted as a glob, but `BASH_REMATCH[0]` is *literal*
matched text. When the matched region held a glob-significant char (a backslash
from an escaped quote `\"`, or `[` / `?` / `*` that matched nothing), the
substitution replaced nothing, `stripped` stayed unchanged, and the
`while [[ … =~ … ]]` test re-matched the identical region forever — a 100%-CPU
busy-loop. On the shared dispatcher/wrapper host this leaked **212** orphan hook
processes (all `PPID=1`, on-CPU, ~8h CPU each). Every PreToolUse `git`-gating hook
that sources this function (`block-push-to-main`, `block-commit-outside-worktree`,
`check-design-canvas`, `check-unit-tests`, `post-git-action-clear`,
`check-pr-review`, `check-code-simplifier`, `check-shellcheck`, `post-git-push`,
`check-rebase-before-push`, `warn-skip-verification`, `check-test-plan`) fanned the
one offending command out to a spinner per session tick. The fix quotes the match
on both loops — `${stripped/"${BASH_REMATCH[0]}"/ }` — forcing a **literal**
substitution and removing the glob interpretation. See issue #266 / PR #267.

**Producer**: `is_git_command` in `lib.sh` (and every hook that sources it).
**Consumer**: every git-gating PreToolUse / PostToolUse hook — they rely on the
function returning a verdict promptly so the session is never wedged.

**Scope note**: this is the *termination* contract only. The strip's documented
defense-in-depth limitation is unchanged — the ERE treats `\"` as a region
boundary, so a *missed strip* (a `git push` mention surviving inside an escaped
inner quote) remains possible. That is acceptable: the intent is to suppress
incidental mentions, not to defeat an adversarial author (who can always use
`--no-verify`). A full shell-quoting parser is out of scope. What is **not**
acceptable, and what this invariant pins, is the strip failing to terminate.

**Tests**: `tests/unit/test-is-git-command-quote-strip.sh`
(TC-IGC-QS-001..009 — escaped-quote payload, `[x]` / `?` / `*` glob metachars, the
single-quote sibling loop, the genuine-invocation no-regression cases, and the
whole `block-commit-outside-worktree.sh` hook on the repro payload — each
bounded-time case runs under `timeout` in a fresh `bash` so a pre-fix loop cannot
hang the harness).

## INV-83: cross-repo dependency lookups use a per-dep-repo scoped read token; the App MUST be installed on the dep repo

_Triage (issue #236): [machine-checked: tests/unit/test-check-deps-resolved.sh, tests/unit/test-gh-app-token-split-269.sh, tests/e2e/run-cross-repo-dep-e2e.sh]_

**Rule**: When Step 2's dependency check ([INV-39](#inv-39-dependency-parsing-is-list-item-scoped-and-supports-cross-repo-refs)) resolves a **cross-repo** `owner/repo#N` reference, it MUST do so with a token scoped to the **target** dependency repo, not the ambient dispatcher token. **The per-dep-repo scoped-token mint and the tick-scoped `_DEP_TOKEN_CACHE` are provider-internal to the GitHub ITP provider (`providers/itp-github.sh`), behind two verbs (#284, [provider-spec.md §3.6](provider-spec.md)):** the leaf state lookup is `itp_resolve_dep` (GitHub leaf `itp_github_resolve_dep`) and the tick-boundary cache reset is `itp_begin_tick` (GitHub leaf `itp_github_begin_tick`). In app mode (`GH_AUTH_MODE=app` with `DISPATCHER_APP_ID` + `DISPATCHER_APP_PEM` present) the GitHub provider mints a read-only installation token scoped to the dep repo (`{"issues":"read"}`) via `get_gh_app_scoped_token`, **cached by `owner/repo` for the duration of the tick** (AC #2): a single mint covers every dep on that repo across **all** issues processed in the tick. The cache (`_DEP_TOKEN_CACHE`) lives at the provider's module scope; `providers/itp-github.sh` is sourced once per dispatcher process (via `lib-issue-provider.sh`, self-sourced by `lib-dispatch.sh`), so the cache persists across the tick's multiple `check_deps_resolved` calls, and it is cleared ONLY at the **tick boundary** — `dispatcher-tick.sh` calls `itp_begin_tick` once, before Step 2 (scan-new). `check_deps_resolved` does **not** self-reset per issue; a per-issue reset would defeat the cross-issue dedup AC #2 requires (#269 review [P1]). `resolve_dep_state` is now a thin caller-side wrapper that forwards `(owner_repo, num, out_var)` to `itp_resolve_dep`, preserving the **out-var `printf -v` contract** so the cache mutation stays in the caller's shell ownership chain into the provider (a command-substitution capture would reset the dedup cache per ref). The cross-repo `owner/repo#N` ref form is gated on the `cross_ref_shorthand` capability ([provider-spec.md §4](provider-spec.md), `=1` for GitHub → today's path; a `cross_ref_shorthand=0` backend uses full-id/permalink refs, not live yet). The **same-repo** `#N` arm is unchanged — it routes through `itp_resolve_dep` against `$REPO`, where the provider skips the mint (the ambient `$GH_TOKEN` already covers `$REPO`) so the emitted argv stays byte-identical and zero mints fire for the dispatching repo. The `## Dependencies` body parse, the [INV-11] CLOSED/MERGED predicate, the fail-safe `return 1`, and the `_dep_block_comment` call all stay **caller-side** in `check_deps_resolved`. In PAT mode (or app mode with creds absent) no mint happens and the ambient token is used (a PAT already spans repos) — byte-identical to the pre-#269 behavior; the provider's `itp_begin_tick` leaves the cache empty.

**Hard requirement (operator)**: the App MUST be installed on each dependency repo (and, if the App uses "selected repositories", that repo must be selected). No token shape avoids this: an installation token can only be scoped to repos the installation can already see. If the App cannot see the dep repo, the dependency is genuinely unresolvable and the fail-safe block ([INV-39]) is correct — the cross-repo empty-state WARNING names the scope/installation cause first, and a once-per-issue-per-ref comment surfaces the persistent block on the issue so it is not invisible behind a stderr WARN.

**Why**: the dispatcher's tick mints its token at `dispatcher-tick.sh` via `get_gh_app_token "$REPO_OWNER" "$REPO_NAME"` with **no permissions arg**, so `_build_access_token_body` produces `{"repositories":["repo-A"]}` and `export GH_TOKEN=<repo-A-scoped token>`. The pre-#269 cross-repo arm ran `gh issue view N --repo owner/repo-B --json state` under that ambient token; GitHub returns 404 / `Could not resolve to a Repository`, `$state` is empty, and the [INV-39] fail-safe `return 1` silently skips the issue **every tick** — a cross-repo dependency permanently silences the issue even when the dependency is already CLOSED. The parsing ([INV-39] `owner/repo#N` extraction) was already correct; only the **token used for the cross-repo lookup** was wrong (#269).

**Permissions object**: `{"issues":"read"}`. `metadata` is implicit for GitHub App installation tokens and the `POST /app/installations/{id}/access_tokens` exchange returns HTTP 422 if it is named explicitly. Per the issue #269 locked decision the empirical contract is `{"issues":"read"}` → HTTP 200 + a token that reads issue state; `{"issues":"read","metadata":"read"}` → HTTP 422. The single live mint against `api.github.com` confirming this is an **operator pre-merge step** (#269 T8) — it is not run from inside a wrapper (no live credential mint in the dependency-check path). Operator-overridable via `DEP_LOOKUP_PERMISSIONS`.

**Failure semantics**: a per-dep-repo mint failure (App not installed, transport error) is **negative-cached** (empty token) so the doomed repo is not re-minted — neither for sibling refs nor for later issues in the same tick; the lookup then falls back to the ambient token, which 404s → empty state → fail-safe block. A mint failure NEVER aborts the tick — a same-repo issue must still dispatch (#269 T4). In PAT mode the mint branch is never entered, so the cache stays empty; combined with the tick-boundary reset (and the fresh-process-per-tick cron model, plus the per-project subshell isolation in `dispatcher-multi-tick.sh`), a dep-lookup token can never leak across ticks or into PAT mode. The negative-cache + no-tick-abort + PAT-mode-no-mint behaviors are all owned by `providers/itp-github.sh::itp_github_resolve_dep` (#284).

**Producer**: `providers/itp-github.sh::itp_github_resolve_dep` (token routing + the `_DEP_TOKEN_CACHE` mint+cache) + `providers/itp-github.sh::itp_github_begin_tick` (the tick-boundary cache reset) + `gh-app-token.sh::get_gh_app_scoped_token` (the scoped mint, which reuses the structural `_app_install_token` core extracted in #269 T1). The caller-side `lib-dispatch.sh::resolve_dep_state` is a thin wrapper that forwards to the `itp_resolve_dep` shim (#284). Threaded by `dispatcher-tick.sh` (the app-mode block exports `DISPATCHER_APP_ID` / `DISPATCHER_APP_PEM`, which the provider reads from the environment, and calls `itp_begin_tick` once before Step 2).

**Consumer**: `lib-dispatch.sh::check_deps_resolved` (the cross-repo arm, gated on `cross_ref_shorthand`; the same-repo arm routes through `itp_resolve_dep` against `$REPO` with the mint skipped). Both arms route through the `itp_resolve_dep` verb; because `lib-issue-provider.sh` always defines the shim but a not-yet-migrated provider defines no `itp_${ISSUE_PROVIDER}_resolve_dep` leaf, `check_deps_resolved` guards on the **provider leaf** and skips dependency-gating (returns resolved/proceed, never a `set -e` abort or a spurious permanent block) when the leaf is absent (#284 review [P1]). GitHub defines the leaf, so production gating is unaffected.

**Status**: **ENFORCED** in #269's fix; the leaf relocated behind `itp_resolve_dep` / `itp_begin_tick` in #284 (no behavior change).

**Tests**: `tests/unit/test-check-deps-resolved.sh` (TC-CRDEP-001..012 — a `$GH_TOKEN`-aware mock `gh` simulates the scope 404; cross-repo CLOSED/MERGED/OPEN, App-not-installed empty-state + sharpened WARNING + block comment, token routing same-repo-ambient vs cross-repo-scoped, per-repo mint-failure degradation without `exit`, PAT-mode no-mint fallback, PR-number ref, within-call mint dedup, once-per-ref block-comment dedup, **TC-CRDEP-011 the TICK-scoped cross-ISSUE dedup — two issues on the same dep repo mint ONCE (AC #2, fails under a per-issue reset)**, and TC-CRDEP-012 the tick-boundary reset re-mints a new tick — now driven through `itp_begin_tick` rather than a direct `_reset_dep_token_cache` call). `tests/unit/test-itp-resolve-dep-golden-trace.sh` (#284 — byte-identical `gh issue view` argv for both the cross-repo and same-repo arms after the move behind `itp_resolve_dep`, the single-mint-per-tick golden trace via `itp_begin_tick`, dispatch routing `itp_resolve_dep`→`itp_github_resolve_dep` / `itp_begin_tick`→`itp_github_begin_tick`, and the `cross_ref_shorthand=0` capability-branch via a degraded fake provider). `tests/unit/test-gh-app-token-split-269.sh` (the T1 structural split — `_app_install_token` extraction + byte-identical body shape). `tests/e2e/run-cross-repo-dep-e2e.sh` (end-to-end against a scope-enforcing stub `gh`, with a counter-proof that the no-mint path 404s, and **E2E-CRDEP-5 proving the tick-scoped cross-issue dedup**, now driven through `itp_begin_tick`) — run in the hermetic CI tier via the `tests/unit/test-cross-repo-dep-e2e-wrapper.sh` wrapper (a scoped App token cannot edit `.github/workflows/`, so the E2E is gated through the existing `tests/unit/test-*.sh` loop rather than a dedicated CI step).

**Cross-references**:
- [INV-39](#inv-39-dependency-parsing-is-list-item-scoped-and-supports-cross-repo-refs) — the cross-repo ref parsing this token-routing fix sits inside. The parse was always correct; #269 fixes only the lookup token.
- [INV-11](#inv-11-dependency-state-includes-merged) — `state ∉ {CLOSED, MERGED}` still applies to the resolved cross-repo state.
- [INV-79](#inv-79-in-app-mode-the-agent-process-gets-only-a-scoped-token-the-wrapper-keeps-full-write-and-is-the-sole-approvemergepr-create-path) — the scoped-mint machinery (`get_gh_app_scoped_token`, `_build_access_token_body`) reused here. #269 T1 extracts the shared exchange core (`_app_install_token`) byte-identically.

## INV-84: the fan-out observe-loop early-exit fires once every agent slot has a RESOLVED FIRST VERDICT (artifact frozen OR comment observed) — not when every artifact FILE exists

_Triage (issue #236): [machine-checked: tests/unit/test-verdict-artifact.sh]_

**Rule**: the review wrapper's post-fan-out **completion-observe loop**
([INV-78](#inv-78-review-verdicts-resolve-from-a-typed-artifact-file-first-comment-scraping-is-an-explicitly-logged-fallback-a-malformed-artifact-is-loud-never-a-silent-absent)
"Live artifact-landing completion signal") takes its EARLY exit when
**every fan-out agent slot has a resolved first verdict** — NOT when an artifact
FILE exists for every slot. A slot is *resolved* when EITHER:

- its artifact's first-land **frozen snapshot** (`<path>.landed`, frozen by
  `_freeze_pass` the moment the artifact lands) exists; OR
- (for a **comment-only** agent that never writes an artifact file) its verdict
  **comment** is observable via `_fetch_agent_verdict_body` — the SAME fetch +
  INV-20/INV-40 authenticity binding `_run_verdict_poll_loop` uses.

The gate is `_all_first_verdicts_resolved` (an OR over `_observe_agent_resolved`
per slot, both in `lib-review-poll.sh`); it REPLACES the file-only
`_all_artifacts_landed "${AGENT_ARTIFACT_PATHS[@]}"` early-exit. The artifact
branch is checked FIRST (a local `[[ -f ]]` stat, no API call); the comment fetch
runs ONLY for a slot whose artifact has not landed — so an **all-artifact-writer**
panel still makes ZERO comment-list API calls (INV-78's zero-comment-poll AC is
preserved). A still-running agent the loop early-exits past is group-killed by
`_reap_fanout_processes` after resolution, exactly as under INV-78.

**Why** (#271): INV-78's early exit was gated purely on `_all_artifacts_landed` —
a path-existence check over EVERY slot's artifact FILE. `AGENT_ARTIFACT_PATHS` is
provisioned for every agent, but only an **artifact-writing** agent ever creates
the file; a **comment-only** agent posts its verdict as a GitHub comment and never
writes the artifact. So on a **MIXED panel** (≥1 artifact-writer + ≥1 comment-only
agent) the early exit was permanently **dead**: at least one `-f` check always
missed. The loop was then left with only (a) "all PIDs exited" and (c) the 6h
`VERDICT_ARTIFACT_OBSERVE_TIMEOUT_SECONDS` ceiling. If the artifact-writing agent's
subshell lingered in post-verdict teardown (its PID alive past verdict-land), (a)
never fired either, and the loop silently spun to (c) — stranding the issue in
`reviewing` for hours with a posted-but-unconsumed verdict. Observed twice in a
consumer project's review runs in one day; both needed a manual kill + label nudge.

**INV-48 timeout-veto preserved (by construction)**: the original early exit only
fired when EVERY artifact landed, so no agent ever flowed to the rc-based terminal
sweep on that path and a still-running agent's launch rc (124/137) was never
consulted. The replacement keeps that property: a slot the loop early-exits past
is ALREADY resolved with a **valid** verdict (a valid artifact OR a posted comment;
its verdict wins over its rc —
[INV-40](#inv-40-multi-agent-review-aggregates-under-unanimous-pass-each-agents-verdict-is-attributed-by-a-review-agent-discriminator)),
and any slot that is NOT resolved (no valid artifact, no comment) makes
`_all_first_verdicts_resolved` false, so the loop keeps waiting on PIDs (path a)
until that agent's CLI exits with its real 124/137 cap — preserving
[INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto)'s
`timed-out` veto for it. An all-**valid**-artifact panel still early-exits on the
same round with zero comment polls (a valid snapshot resolves its slot before the
comment branch runs).

**Malformed artifact ⇒ NOT resolved, and its comment is NOT consulted (#271 review
[P1] ×2)**: `_observe_agent_resolved` classifies the landed snapshot
(`_classify_verdict_artifact` with the slot's identity) and resolves the slot ONLY
on `valid`. A `malformed` snapshot returns NOT-resolved **and does NOT fall through
to the comment branch** — it short-circuits exactly like the POST-LOOP resolution,
which refuses to let a malformed agent's comment override its artifact (a malformed
artifact means the agent's machine output is untrustworthy — INV-78 Clause V1). This
double rule is load-bearing for INV-48: a malformed artifact is "treated absent FOR
THE VOTE", and an absent verdict is exactly what must keep the loop waiting on the
PID. Were a malformed-AND-still-running agent treated as resolved — whether via its
snapshot OR via a comment it happened to also post — the early exit would reap it
**before its rc sidecar landed**, silently converting an rc-124/137 `timed-out`
deciding-FAIL veto into a dropped `unavailable` vote (the terminal sweep keys on the
durable `artifact-malformed` source) — letting a passing sibling approve the PR. If
the observe gate consulted the comment for a malformed slot, a malformed agent that
ALSO self-posted would re-open that dropped-veto bug through the comment door; so the
gate skips the comment for `malformed`, matching the post-loop Clause V1 skip. (A
malformed agent that has ALREADY exited is reaped via break-path (a) "all PIDs
exited", where its rc sidecar IS present — so the `valid`-only gate changes only the
still-running case, which is precisely the one that must wait.) Consequently
`_all_artifacts_landed ⟹ _all_first_verdicts_resolved` holds **only for valid
artifacts**: a panel of all-valid artifacts is byte-for-byte the prior behavior; a
panel containing a malformed-AND-still-running artifact now correctly WAITS on that
agent's PID rather than reaping it early. Once the agent exits and resolves
`unavailable`/`malformed-output` (or `timed-out` on a 124/137 cap), that is the
documented INV-78 Clause V1 outcome.

**Producer**: `lib-review-poll.sh::_observe_agent_resolved` /
`::_all_first_verdicts_resolved` (the per-slot + fleet resolved checks).

**Consumer**: `autonomous-review.sh` (the post-fan-out observe loop's early-exit
gate).

**Status**: **ENFORCED** in #271's fix.

**Tests**: `tests/unit/test-verdict-artifact.sh` — pure-lib TC-OBS-271-01..09
(artifact-first resolution with no comment fetch, comment-only resolution, the
mixed-panel all-resolved + the regression that a pending comment agent keeps the
gate false, the all-artifact-writer parity + zero-comment-poll, the empty-fleet
guard, and the `_all_artifacts_landed ⟹ _all_first_verdicts_resolved`
generalization); integration TC-OBS-271-10/11 (the loop breaks on the resolved
gate with a lingering PID and does NOT prematurely break while a comment agent is
pending); and source-of-truth wiring W18/W19/W19b/W25-W28 (the wrapper uses the
new gate, no longer the file-only one, names the completion signal, and reaps the
lingerer after resolution).

**Cross-references**:
- [INV-78](#inv-78-review-verdicts-resolve-from-a-typed-artifact-file-first-comment-scraping-is-an-explicitly-logged-fallback-a-malformed-artifact-is-loud-never-a-silent-absent) — the verdict-artifact channel this refines; the "Live artifact-landing completion signal" paragraph now points here for the early-exit gate.
- [INV-40](#inv-40-multi-agent-review-aggregates-under-unanimous-pass-each-agents-verdict-is-attributed-by-a-review-agent-discriminator) — a posted verdict wins over the launch rc (why a resolved slot's rc is irrelevant).
- [INV-43](#inv-43-the-verdict-poll-budget-scales-with-the-command-mode-e2e-timeout) — `_reap_fanout_processes` (the lingerer cleanup) + the comment-poll fetch this gate reuses.
- [INV-48](#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto) — the timeout-veto preserved for genuinely-unresolved (no-artifact, no-comment) agents.

## INV-85: the completed-session `failed-substantive` route is bounded to one `dev-new` per unchanged HEAD; a no-progress or bot-unfixable finding escalates to `stalled`, never loops

_Triage (issue #236): [machine-checked: tests/unit/test-handle-completed-session-routing.sh]_

**Rule**: when `handle_completed_session_routing()` ([INV-35](#inv-35-review-aware-resume-routing-for-completed-sessions)) routes a `pending-dev` issue on the `failed-substantive` verdict, it MUST NOT mint a fresh `dev-new` unconditionally. Before dispatching, it consults the PR `headRefOid` and the most recent `Reviewed HEAD:` trailer ([INV-04](#inv-04-reviewed-head-trailer-format) / [INV-07](#inv-07-empty-reviewed-head-trailer-routes-to-pending-review)), the same signals the #106 guard uses in `handle_pending_dev_pr_exists`. The routing is:

| Condition | Route |
|---|---|
| Current PR HEAD == last `Reviewed HEAD:` trailer **AND** the dev agent's comments carry the **bot-unfixable signature** *within the current HEAD's review window* — `Resource not accessible by integration` (a 403) co-occurring with a PR-metadata-edit context (`gh pr edit`, `PATCH .../pulls/N`, "PR body"/"pull request") | Escalate: post a one-time `no-progress-substantive:<head>` operator notice (@owner) and `mark_stalled`. **Zero** `dev-new`. |
| Current PR HEAD == last `Reviewed HEAD:` trailer **AND** a `no-progress-substantive-attempt:<head>` marker already exists (a prior `dev-new` ran for this HEAD and produced no new commit) | Escalate: post a one-time `no-progress-substantive:<head>` notice (@owner) and `mark_stalled`. **Zero** further `dev-new`. |
| Otherwise (first substantive attempt at this HEAD, HEAD advanced since last review, or no PR yet so HEAD is uncomputable) | Dispatch the existing INV-35 fresh-`dev-new`, then — *only after the dispatch succeeds* — record a `no-progress-substantive-attempt:<head>` marker (when a HEAD is known). This is the **one** allowed `dev-new` per unchanged HEAD. |

**Why** (#274): #106 added a `last_reviewed_head` guard to the *crash-recovery* PR-exists branch, but a session that reaches `end_turn|completed` and then gets a `failed-substantive` verdict routes through `handle_completed_session_routing()` instead — and that branch minted `dev-new` with no HEAD comparison. When the substantive FAIL is one the dev agent cannot resolve (its scoped token can't edit the PR body per [INV-79](#inv-79-in-app-mode-the-agent-process-gets-only-a-scoped-token-the-wrapper-keeps-full-write-and-is-the-sole-approvemergepr-create-path), or the finding is satisfiable only post-merge), each cycle produced no new commit, the next review re-reported the identical finding against the unchanged HEAD, and the dispatcher minted yet another `dev-new` — looping every ~5 min until a human intervened. Observed on a consumer project: a PR sat ~14h in this loop, three near-identical `failed-substantive` comments against the same HEAD, broken only when a maintainer manually edited the PR body. This is the runtime backstop to #273's authoring-time prevention of the same failure class.

**Bounded-retry (N=1) rationale**: the `no-progress-substantive-attempt:<head>` marker is the persisted "a `dev-new` already ran against this HEAD" signal. The first substantive failure at a HEAD mints one `dev-new` (the dev legitimately gets one more pass — it might fix it) and records the marker **only after that `dev-new` has actually been dispatched** (#274 review [P1] finding 2 — recording it up-front would, on a transient truncate/label/dispatch failure that takes the fail-closed `return 0` path, leave a marker claiming a `dev-new` ran when none did, stalling the issue next tick). If the next review still fails substantively and HEAD is unchanged, the prior `dev-new` made no progress → escalate. The marker is HEAD-scoped: a dev push that advances HEAD makes `current_head != last_head`, so a fresh attempt against the **new** HEAD proceeds exactly as before — no regression.

**The attempt-marker write failure is never silently swallowed (#274 review [P1] round-3 finding 2)**: the one-per-HEAD bound depends on the marker comment landing, so the write is retried once and, on persistent failure, a **loud operator notice** is posted (it must NOT contain the literal `no-progress-substantive-attempt:<head>` token verbatim — otherwise the notice itself would satisfy branch B's marker-presence grep next tick and cause a false stall). A lost marker degrades the tight N=1 bound, but the issue is **still bounded by `MAX_RETRIES`** (the completed-session `dev-new` path consumes a retry slot per [INV-35]), so the loop can never run unbounded even if GitHub rejects the marker write.

**Bot-unfixable detection is scoped to a DEV-AUTHORED comment in the CURRENT dev attempt (#274 review [P1], findings refined across rounds)**: `dev_report_bot_unfixable` only counts a 403 signature reported BY the dev agent in the current attempt, not one any review / maintainer / owner / human comment merely *quotes*, and not one a PRIOR attempt against the same HEAD hit. Three scopings: (a) an **author allow-list** — resolve the dev agent's comment-author login from the most recent `Agent Session Report (Dev)` comment, and count a 403 ONLY in comments by that same author; a reviewer/maintainer/owner/human comment quoting the 403 has a *different* author and is excluded. If the dev author can't be resolved (no dev session report yet), return NOT-unfixable. This is the primary, robust discriminator (the round-5 finding: a maintainer comment quoting the 403 is NOT a review-agent comment, so the review-marker exclusion alone could not drop it). (b) a lower bound at the **current dev attempt's start** — the createdAt of the most recent `dispatcher-token … mode=dev-new` / `mode=dev-resume` comment (posted by `post_dispatch_token` / Step 4 *before* the agent runs, so it precedes the agent's completion 403 — round-4 finding 2 stays fixed). This **expires** a 403 after each same-HEAD review cycle (round-6 finding): every re-dispatch posts a fresh dev-dispatch token, so a 403 the dev hit in a PRIOR same-HEAD attempt falls before the new token and is ignored — if a maintainer clears the obstacle without a new commit and a later same-HEAD review finds a *different* actionable issue, that new finding still gets its bounded `dev-new`. The bound is deliberately NOT a `Reviewed HEAD:` trailer (review-side, persists across same-HEAD cycles) nor the cleanup-time `Dev Session ID:` trailer (posted after the agent's 403). "No lower bound" only when no dev-dispatch token exists. (c) an **exclusion of review-agent comments** (`Review Session:` / `Review findings` / `Review Agent:` markers) — redundant given the author allow-list but kept as belt-and-suspenders. The escalation branch is **additionally** gated on `current_head == last_reviewed_head`: a 403 only blocks when HEAD has NOT advanced. All scopings are fail-open toward NOT-unfixable, so a same-HEAD substantive failure whose dev attempt did not actually hit the 403 still gets its bounded retry rather than a spurious stall. Without this scoping, a single historical, quoted, or prior-attempt 403 would route every later completed-session substantive failure on the issue to `mark_stalled`, even after the underlying obstacle was cleared.

**The PR-head fetch MUST include `body` (#274 review [P1] round-4 finding 1)**: the guard calls `fetch_pr_for_issue "$issue_num" "number,headRefOid,body"`. `fetch_pr_for_issue` filters PRs on `.body` (`select(.body != null and (.body | test("#N")))`), so omitting `body` from the `--json` field list makes `gh pr list` return objects with no `.body` → the filter sees null → empty result → `current_head` stays blank → both INV-85 guards silently no-op and `dev-new` loops exactly as before. (The unit tests mock `fetch_pr_for_issue`, so a source-pin grep test guards the field list.)

**Fail-safe / escalation contract**: the bot-unfixable detector (`dev_report_bot_unfixable`) and the attempt-marker presence check are both fail-closed toward *more* `dev-new`, never toward a false stall: a `gh` transport error or absent signature falls through to the bounded-retry path (which still terminates the loop after one attempt). The escalation routes to `mark_stalled` (not merely "hold in `pending-dev` without re-dispatch" — the gap the #274 review flagged in `handle_pending_dev_pr_exists`), so a stuck issue ends up with a `stalled` label + a human signal rather than churning ticks silently. This `mark_stalled` call does NOT pass `--at-cap` (it is the review-no-progress state, not the retry-budget-exhausted state), retaining [INV-30](#inv-30-pid_alive-is-authoritative-under-all-execution-backends)'s ALIVE bias under the remote backend, mirroring the [INV-35] `REVIEW_RETRY_LIMIT` caller.

**Idempotency**: the operator notice keys on `no-progress-substantive:<head>` and the attempt marker on `no-progress-substantive-attempt:<head>` — both use the `grep -q '^0$'`-style fail-closed presence check (same pattern as `stale-verdict:` / `INV-12-completed:` / `INV-35-fresh-dev:`). Repeated ticks against the same HEAD find the marker(s) and don't spam comments or re-stall.

**Producer**: `lib-dispatch.sh::handle_completed_session_routing` (the `failed-substantive)` case) + `lib-dispatch.sh::dev_report_bot_unfixable` (the bot-unfixable detector). The attempt + notice markers are produced by the same function.

**Consumer**: subsequent dispatcher ticks (read the markers to decide escalate-vs-dispatch); the operator (reads the `stalled` label + `no-progress-substantive:<head>` notice).

**Status**: **ENFORCED** as of #274. Delta on top of [INV-35](#inv-35-review-aware-resume-routing-for-completed-sessions); design recorded in `docs/designs/issue-274-completed-substantive-noprogress.md`.

> **Update (#277 / [INV-86](#inv-86-prissue-binding-is-authoritative-via-closingissuesreferences-never-a-bare-n-body-mention-and-no-pr-is-mutated-without-verified-linkage))**: `fetch_pr_for_issue` no longer filters PRs on a `.body | test("#N")` body mention — it now delegates to `resolve_pr_for_issue`, which binds by GitHub's parsed `closingIssuesReferences` (with a branch-name fallback). The "MUST include `body`" rule above is therefore no longer load-bearing for *resolution* (the resolver keys on `closingIssuesReferences`/`headRefName`); INV-85's caller still requests `number,headRefOid,body` and reads `.headRefOid`, and `body` remains in the echoed object (harmless), so the source-pin grep test stays valid. The HEAD-comparison logic of INV-85 is unchanged.

## INV-86: PR↔issue binding is authoritative via `closingIssuesReferences` (never a bare `#N` body mention), and no PR is mutated without verified linkage

_Triage (issue #236): [machine-checked: tests/unit/test-pr-issue-linkage-277.sh]_

**Rule**: PR-to-issue resolution MUST bind an issue to the open PR that **closes** it — GitHub's parsed close linkage, read via `gh pr list --json closingIssuesReferences` — NOT to any open PR whose body merely **mentions** `#N`. The shared resolver `resolve_pr_for_issue` ([`lib-pr-linkage.sh`](../../skills/autonomous-dispatcher/scripts/lib-pr-linkage.sh)) applies this precedence:

1. **Close linkage (authoritative)**: the open PR whose `closingIssuesReferences[].number` equals the issue. Lowest PR number on ties (deterministic; GitHub binds one closing PR per issue).
2. **Branch-name fallback**: only when no PR carries close linkage — the open PR whose `headRefName` matches the boundary-anchored `issue-<N>` marker (`(^|[^0-9])issue-N([^0-9]|$)`), lowest PR number on ties. This serves close-keyword-less partial-fix PRs (which deliberately omit `Closes #N` so GitHub doesn't auto-close — see [the close-keyword guidance](../../skills/create-issue/SKILL.md)). **Never** a bare `.[0]` body mention.

**Both discovery sites use this resolver**: `autonomous-review.sh`'s "Finding PR for issue" block (its old Method 1 loose `select(.body | test("#N"))] | .[0]`, plus the loose Method 2 comment scrape and Method 3 `gh search "issue N"`, are removed) AND the shared `lib-dispatch.sh::fetch_pr_for_issue` (which delegates to `resolve_pr_for_issue`; its name is preserved so the [spec guard-map](spec-guard-map.json) anchor `pr-exists-for-issue` / `no-pr-for-issue` keeps resolving).

**Hard linkage guard before ANY PR mutation**: before the review wrapper hands the resolved `PR_NUMBER` to any GitHub-state-changing action — `submit_request_changes` / `gh pr review --approve` / `gh pr merge` / label flip — it MUST assert `verify_pr_closes_issue "$PR_NUMBER" "$ISSUE_NUMBER"` (the resolved PR closes this issue by close linkage, or — when it carries no close linkage at all — matches the `issue-<N>` branch marker). On failure the wrapper refuses to review, emits a diagnostic, and routes through the **existing** no-valid-PR branch (`failed-non-substantive` / `no-pr-found` → `reviewing` → `pending-dev`). **No GitHub review action is ever taken against a PR not linked to the issue under review.** This is a second, independent guard: pre-#277 `submit_request_changes` was unguarded once `PR_NUMBER` was set, so a mis-resolved foreign PR would receive a `REQUEST_CHANGES`.

**Why** (#277): the pre-fix matcher keyed on a bare `#N` body mention and trusted `.[0]`. When two issues were in flight concurrently and one PR's body cross-referenced the other issue (a deliberate, good-practice `related to #A` line), the review wrapper for issue A selected the cross-referencing PR-B, reviewed the wrong PR, posted a dev-actionable FAILED verdict to issue A citing files that exist only in PR-B, submitted `REQUEST_CHANGES` against the foreign PR-B, and moved issue A to `pending-dev` — a non-terminating dev↔review loop driver that also mutated an unrelated PR's review state. Reproduced in this repo during the #273/#274 cycle: the issue-273 review wrapper resolved PR #276 (the #274 fix) because #276's body contained a `- #273 — …` line, yet `gh pr view 276 --json closingIssuesReferences` returns `274` (not 273), proving the close linkage is authoritative and immune to body cross-references. The trigger (cross-referencing in a PR body) is exactly the context-linking we want authors to write, so the fix tolerates mentions and binds only on the *close* reference.

**RE2 / null safety**: every jq regex is RE2-safe (`(^|[^0-9])` / `([^0-9]|$)` — plain alternation, no look-behind/ahead) so a `gh --jq` run can never abort a caller under `set -e` ([gh --jq is RE2](#)); `.body` / `.headRefName` / `.closingIssuesReferences` are guarded with `// ""` / `[]?` so a null field can't abort the filter and silently hide a match (parity with the [INV-?] #148 null-body guard).

**No new label transition**: the foreign-PR / no-linkage case reuses the **existing** `reviewing → pending-dev` no-valid-PR transition, so `transitions.json` / `state-machine.md` are unchanged.

**Producer**: `lib-pr-linkage.sh::resolve_pr_for_issue` (discovery) + `lib-pr-linkage.sh::verify_pr_closes_issue` (mutation guard); `lib-dispatch.sh::fetch_pr_for_issue` (delegate); `autonomous-review.sh` (discovery + guard wiring).

**Consumer**: the review wrapper (binds the PR it reviews); the dispatcher Step-5 helpers `review_near_success` / `handle_pending_dev_pr_exists` (resolve the PR via `fetch_pr_for_issue`).

**Out of scope** (follow-up): a broader audit of every `#N` body-mention match elsewhere in the dispatcher (dev cleanup/resume, bot-trigger brokerage). This invariant fixes the review-discovery path + the shared `fetch_pr_for_issue` it depends on.

**Status**: **ENFORCED** as of #277. Design recorded in `docs/designs/issue-277-pr-linkage.md`.

## INV-87: provider-dispatch is spec-defined — callers route every issue/code-host op through `itp_*`/`chp_*`, never a raw `gh` in the caller layer

_Triage (issue #236): [machine-checked: tests/unit/test-provider-spec.sh]_

**Rule**: the pipeline's GitHub coupling is abstracted behind **two provider seams** ([`provider-spec.md`](provider-spec.md)) — an Issue-Tracker Provider (ITP, `ISSUE_PROVIDER`) and a Code-Host Provider (CHP, `CODE_HOST`). Once a verb exists for an operation, the provider-neutral caller layer (`lib-dispatch.sh`, the wrappers, `lib-review-*.sh`) MUST invoke it through the verb's thin dispatcher (`itp_<verb>` → `itp_${ISSUE_PROVIDER}_<verb>`, `chp_<verb>` → `chp_${CODE_HOST}_<verb>`) and MUST NOT emit a raw `gh` call for that operation. This explicitly includes the **dispatcher's own marker writers** — `post_dispatch_token` ([INV-18]) and `_dep_block_comment` ([INV-39]) route through `itp_post_comment`, not a bare `gh issue comment`. The verb tables and the exact current function each verb replaces are normative in [`provider-spec.md`](provider-spec.md) §3.1 (13 ITP verbs) / §3.2 (12 CHP verbs); the marker-parsing, retry-counting, verdict-routing, and INV-coupled timing logic stays in the caller layer — only the leaf I/O call moves behind a verb.

**Why**: GitHub today fills two distinct roles (issue tracker + code host) the codebase conflates across ~145 `gh` call sites in ~30 files with no abstraction. The headline `asana`/`github` topology needs the two roles to be independent, separately-configured seams. Mirrors the agent-CLI adapter precedent ([INV-66]/[INV-75], [`adapter-spec.md`](adapter-spec.md)): a normative spec + a thin dispatcher + one file per backend.

**CHP caller-layer scope ([#282])**: the `chp_*` rule covers the provider-neutral CALLER layer's PR-lifecycle leaves. The caller layer carries **ZERO executable raw `gh pr`** (#282 review round 8): besides the 11 named §3.2 PR-lifecycle verbs, the incidental PR reads — the issue-keyed body-mention `gh pr list … select(.body|test("#N"))` existence/number lookups and the PR-number-keyed `gh pr view $PR --json comments/state/headRefName/headRefOid/reviews` reads — route through two **general read primitives** `chp_pr_view` / `chp_pr_list` (added to `lib-code-host.sh`/`providers/chp-github.sh`; NOT named lifecycle verbs, the lifecycle count is unchanged). Unlike the lifecycle verbs (caller-guarded via `chp_has_leaf`), these read shims are invoked unguarded by the incidental-read sites, so the shims are **self-guarding** (#282 review round 9): when the enabled provider omits the leaf (the degraded fixture; any not-yet-implemented non-GitHub provider) the shim emits a WARN and returns 1 — a clean non-zero the read call sites already degrade on (`$(… || echo/true)`, `if !`, `… || return 1`) — instead of `command not found`-aborting the wrapper at its first PR read. The only residual grep hits in the caller files are non-executable (`#` comments, log strings, and prompt-heredoc text instructing the *agent* to run `gh pr checks`/`gh pr view` during its own review). A standalone literal-`gh`-freedom CI lint is still the separate cutover-guard issue. The `lib-auth.sh` brokers (`drain_agent_pr_create` / `drain_agent_bot_triggers`) route their `gh pr create` / bot-trigger leaves through `chp_create_pr` / `chp_trigger_bot` (leaf-only swap, guarded on `chp_has_leaf`; byte-identical argv).

**Status**: **DISPATCH SKELETON SHIPS; ITP READ leaves (#281) + ITP WRITE leaves (#283) + ALL CHP PR-lifecycle leaves (#282) code-enforced; ITP dep refactor not yet.** The normative `provider-spec.md` landed with issue #279. The dispatch skeleton — `lib-issue-provider.sh` / `lib-code-host.sh` (the 13 ITP + 12 CHP thin shims routing `itp_<verb>` → `itp_${ISSUE_PROVIDER}_<verb>` / `chp_<verb>` → `chp_${CODE_HOST}_<verb>`) + the empty `providers/itp-github.{sh,caps}` / `chp-github.{sh,caps}` scaffolds + the `.caps` reader — ships in issue #280 with **ZERO verb leaves migrated and zero behavior change**. **The ITP READ leaves** (`itp_github_list_by_state`/`count_by_state`/`list_forbidden_combos`/`read_task`/`list_comments`) **are migrated in #281**: the six state-list callers route through the verbs with byte-identical `gh` argv, the 28 `gh issue view --json comments` marker-scanners consolidate behind `itp_list_comments` (the [INV-90] normalized array; `capture`/`sort_by`/exact-eq parse stays caller-side), and the `title`/`body`/`state` reads route through `itp_read_task`. **The ITP WRITE leaves** (`itp_github_transition_state`/`post_comment`/`edit_comment`/`mark_checkbox`/`provision_states`) **are migrated in #283**: `label_swap` → `itp_transition_state`; all 18 `gh issue comment` sites (incl. dispatcher markers [INV-18]/[INV-39]) → `itp_post_comment` ([INV-89]); the INV-46 SHA stamp → `itp_edit_comment` (+ `edit_comment=0` fallback); `mark-issue-checkbox.sh` → `itp_mark_checkbox`; `setup-labels.sh` → `itp_provision_states` — marker text / retry / dedup / [INV-25] subtraction staying caller-side. **The CHP PR-lifecycle leaves** (`chp_github_find_pr_for_issue`/`ci_status`/`mergeable`/`create_pr`/`approve`/`request_changes`/`merge`/`review_threads`/`resolve_thread`/`trigger_bot`/`close_keyword`) **are migrated in #282**: `ci_is_green` (`gh pr checks`), `resolve_pr_for_issue`/`verify_pr_closes_issue` (`gh pr list --json $FIELDS`, [M1]), the mergeable poll ([M2], `_classify_mergeable_gate`/`_pr_open_gate` byte-unchanged caller-side), the approve / request-changes ([INV-52]) / merge ([INV-33] cap-gated post-merge transition) leaves, the `resolve-threads.sh` reviewThreads list + `resolveReviewThread` mutation ([M8]), the `Closes #N` PR-body keyword ([M4], caps-aware `_render_close_keyword`), the `lib-auth.sh` PR-create/bot-trigger brokers, and the incidental `gh pr view`/`gh pr list` reads (via `chp_pr_view`/`chp_pr_list`) — all proven zero-behavior-change by golden-trace. **The two entangled multi-op orchestrators** (`mark_stalled`, `handle_completed_session_routing`) are now **golden-trace-gated in #285**: their leaf I/O moved in #283/#282 (comment posts → `itp_post_comment`, label moves → `label_swap`→`itp_transition_state`, the PR lookup → `fetch_pr_for_issue`→`chp_find_pr_for_issue`), and #285 ships the per-class-(b) golden-trace tests asserting byte-identical verb argv on every documented path — plus the §7.3.3 function-mock shim audit confirming the moved leaves keep their same-named caller-side shims (`label_swap`, `post_dispatch_token`, `fetch_pr_for_issue`) so the existing function-level mocks still intercept. Both functions hold ZERO raw `gh ` and contain no caps gate (GitHub takes the identical path); the NON-host ops (`pid_alive`, `count_*`, `classify_recent_review_verdict`, `dev_report_bot_unfixable`, the `: > $log` truncate, `post_dispatch_token`, `dispatch dev-new`) stay caller-side per §7.1(b). The remaining `gh`-site refactor (the ITP dep leaves) was completed in #284 (`itp_resolve_dep`/`itp_begin_tick`, [INV-83]). No wrapper behavior changes in #279–#285.

**Producer**: `lib-issue-provider.sh` / `lib-code-host.sh` dispatchers + `providers/itp-github.sh` / `providers/chp-github.sh` (the shim layer + scaffolds exist as of #280; the ITP READ `itp_github_<verb>` bodies are populated by #281, the ITP WRITE bodies by #283, ALL CHP bodies by #282; the ITP dep leaf bodies are populated by the downstream migration issue). **Consumer**: every caller in `lib-dispatch.sh` / the wrappers that today emits a `gh` call.

**Tests**: `tests/unit/test-provider-spec.sh` asserts the spec lists all 25 verbs and names the dispatcher's own marker writers. `tests/unit/test-provider-dispatch.sh` (#280, updated #281/#282/#283) asserts the dispatch layer routes `itp_<verb>` → `itp_github_<verb>` / `chp_<verb>` → `chp_github_<verb>` under the default `github` provider, that all 13 ITP + 12 CHP shims are defined, that the libs resolve `providers/` via `readlink -f` of `BASH_SOURCE`, that the migrated ITP READ+WRITE + ALL CHP leaf bodies are now DEFINED, and that the ITP dep verbs are still empty scaffolds. `tests/unit/test-itp-read-leaves.sh` (#281), `tests/unit/test-itp-write-leaves.sh` (#283), and `tests/unit/test-chp-pr-lifecycle.sh` (#282) are the golden-trace / dispatch-routing / `.caps`-parse / capability-branch suites for the ITP READ, ITP WRITE, and CHP leaves respectively. `tests/unit/test-mark-stalled-golden-trace.sh` and `tests/unit/test-handle-completed-routing-golden-trace.sh` (#285) are the per-class-(b) golden-trace suites for the two entangled multi-op orchestrators: they stub the VERB LAYER (not the `gh` binary, so the gate is *sufficient* per §7.2.1) and assert byte-identical verb argv on every documented path — anchored on #148 (the `chp_find_pr_for_issue` FIELDS string `number,headRefOid,body` includes `body`) and #274/[INV-85] (the `no-progress-substantive-attempt:<head>` marker token) — plus the source-level zero-raw-`gh` / no-caps-gate / caller-side-op invariants and the function-mock shim audit. `tests/unit/test-itp-resolve-dep-golden-trace.sh` (#284) gates the ITP dep leaves.

**Cross-references**:
- [`provider-spec.md`](provider-spec.md) — the verb tables this invariant enforces routing through.
- [INV-66](#inv-66-adapter-conformance-is-spec-defined) / [INV-75](#inv-75-all-per-cli-behavior-lives-in-that-clis-adapter--inline-cli-conditionals-in-orchestration-code-are-a-defect) — the agent-CLI adapter precedent this mirrors.
- [INV-89](#inv-89-every-machine-marker--agent-and-dispatcher-inv-18inv-39-included--is-posted-only-through-the-declared-marker_channel-the-read-side-capture-regex-branches-on-channel) — the marker-channel pin that `itp_post_comment` enforces.

## INV-88: the GitHub `.caps` manifests describe current behavior EXACTLY (the no-behavior-change anchor) — honestly declared, not all-ones

_Triage (issue #236): [machine-checked: tests/unit/test-provider-spec.sh]_

**Rule**: each provider declares a `.caps` capability manifest (a declarative key=value file, parsed not sourced) and callers branch on it ([`provider-spec.md`](provider-spec.md) §4). The GitHub provider's manifests (`providers/itp-github.caps`, `providers/chp-github.caps`) MUST describe **exactly today's behavior** — this is the no-behavior-change anchor. That means GitHub is honestly declared, **not** all-ones: `server_side_state_negation=0` (GitHub does label negation client-side via jq, not server-side) and `native_issue_pr_link=0` (GitHub has no native issue↔PR link and greps the PR body for `#N`) are GitHub's **real current behavior**. Every caller therefore takes the **identical code path** it takes now; the only *new* runtime behavior is the `caps=0` branches, which GitHub never takes.

**Why**: forcing every provider to fake GitHub's full surface produces silent breakage (e.g. Asana strips `<!-- -->` HTML comments). Declaring caps honestly — including the two GitHub-is-weaker cases — lets GitLab/Asana PRs slot in without re-architecting callers, while keeping the GitHub reference path byte-identical. Same discipline as the adapter-spec: write the contract now, implement one reference backend, prove zero behavior change.

**Status**: **CAPS MANIFESTS + READER SHIP** with the dispatch skeleton (#280). The `.caps` manifests (`providers/itp-github.caps`, `providers/chp-github.caps`) declaring exactly today's GitHub behavior, and the parsed-not-sourced `itp_caps`/`chp_caps` reader, land in #280. The 9 ITP + 4 CHP capability keys and their github/gitlab/asana columns are normative in [`provider-spec.md`](provider-spec.md) §4.1/§4.2. The capability *branches* in callers ship with the leaf-migration issues; #280 proves each `caps=0` branch is reachable via a named degraded fake fixture provider, with zero behavior change. **#281 (ITP READ leaves)** consumes the GitHub `.caps` as the no-behavior-change anchor: GitHub's `server_side_state_negation=0` (negation client-side via jq) and `server_side_state_and=1` are its real current behavior, so every migrated read caller takes the identical code path. `tests/unit/test-itp-read-leaves.sh` re-asserts the `.caps` values consumed by the read verbs and exercises the read-side `caps=0` branches (negation + AND done client-side) through the degraded fake provider via the PUBLIC seam. **#282 (CHP PR-lifecycle leaves)** ships the THREE CHP `caps=0` caller branches live: `rest_request_changes=0` (`submit_request_changes` skips the native REST submit), `review_bots=0` (bot-review enforcement disabled end-to-end — the effective `REVIEW_BOTS_VALIDATED` is blanked at the source, suppressing the review-agent prompt bot-review section, the trigger broker `drain_agent_bot_triggers`, AND the wrapper's mandatory-bot-review wait gate, so a `review_bots=0` backend neither asks the agent to trigger/wait for a bot review nor waits for one that can't arrive), and `merge_closes_issue=0` (the merge success path explicitly closes the issue after `chp_merge`). GitHub's `caps=1` values keep all three on the unchanged path; `tests/unit/test-chp-pr-lifecycle.sh` exercises each `caps=0` branch through the degraded fake provider via the PUBLIC seam.

**Producer**: `providers/itp-github.caps` / `providers/chp-github.caps` (exist as of #280). **Consumer**: the `itp_caps`/`chp_caps` reader (#280) + every capability-branching caller (downstream).

**Tests**: `tests/unit/test-provider-spec.sh` asserts the spec pins `server_side_state_negation=0`, `native_issue_pr_link=0`, and `marker_channel=html` as GitHub's declared values. `tests/unit/test-provider-dispatch.sh` (#280) asserts the reader returns those documented values against the real `.caps` manifests, that it ignores `#` comments / blank lines / unknown keys, that it NEVER `source`s the manifest (parsed-key=value guard), and that a named degraded fake fixture provider — selected through the PUBLIC `itp_caps`/`chp_caps` seam via `ISSUE_PROVIDER=degraded` / `CODE_HOST=degraded` + the `AUTONOMOUS_PROVIDERS_DIR` provider-search-dir override — reports the `caps=0` / `marker_channel=text` values, so each gated branch is exercisable now through the real provider-selection path (the reusable harness downstream caps-branch issues build on).

**Cross-references**:
- [`provider-spec.md`](provider-spec.md) §4.3 — the no-behavior-change anchor.
- [INV-87](#inv-87-provider-dispatch-is-spec-defined--callers-route-every-issuecode-host-op-through-itp_chp_-never-a-raw-gh-in-the-caller-layer) — the dispatch the caps gate.

## INV-89: every machine marker — agent AND dispatcher (INV-18/INV-39 included) — is posted only through the declared `marker_channel`; the read-side `capture()` regex branches on channel

_Triage (issue #236): [machine-checked: tests/unit/test-provider-spec.sh]_

**Rule**: a provider declares a `marker_channel` capability (`html` for GitHub/GitLab, `text` for Asana). EVERY machine marker the pipeline writes — agent progress/verdict comments **and** the dispatcher's own markers ([INV-18] dispatch token, [INV-39] dependency-block notice) — MUST be posted through `itp_post_comment` on that declared channel, and the **read-side** `capture()` regexes MUST branch on the channel too. A `text`-channel provider MUST NOT use a sanitizing rich field: Asana's `html_text` field is strict-XML-whitelisted and **rejects HTML comments (`<!-- marker -->`) with HTTP 400**, so a `marker_channel=text` provider posts via the plain `text` story field, which round-trips `<!-- marker -->` verbatim. `itp_post_comment` is the single choke-point for ALL machine markers.

**Why**: the marker scheme uses `<!-- dispatcher-token: … -->` / `<!-- … -->` HTML comments that survive on GitHub but would be silently stripped (or rejected) by a backend with a sanitizing rich field — the marker scheme would then die **silently**. Covering the dispatcher's *own* writers (not just the comment readers) closes the gap where a v1 framing pinned only the read side and let `post_dispatch_token`/`_dep_block_comment` emit raw GitHub-shaped markers a non-GitHub provider could not round-trip.

**Status**: **IMPLEMENTED for GitHub in #283** (spec-defined with #279). The ITP WRITE leaf `itp_github_post_comment` (`providers/itp-github.sh`) is the single byte-identical `gh issue comment "$issue" --repo "$REPO" --body "$BODY"` choke-point. **EVERY machine-marker ISSUE comment the pipeline writes now routes through `itp_post_comment`** — `lib-dispatch.sh` (18 sites, incl. the dispatcher markers `post_dispatch_token` [INV-18] / `_dep_block_comment` [INV-39]), `autonomous-dev.sh` (session-report + resume-fallback markers), `autonomous-review.sh` (verdict / diagnostic / held / smoke comments), `dispatcher-tick.sh` (PTL / crash / pending-review markers), `lib-review-verdict.sh` (the `emit_verdict_trailer` `<!-- review-verdict: … -->` trailer), and `post-verdict.sh` (the [INV-56] AGENT verdict comment — the [INV-78] fallback verdict comment the review wrapper scrapes when the typed artifact is absent; it routes through `itp_post_comment` with the proxy `gh` kept on PATH so the [INV-56] identity guarantee holds). The marker BODY is composed caller-side. `grep -c 'gh issue comment "' <each file>` (excluding `#` comment lines) == 0 across all six files. GitHub's `marker_channel=html` is today's behavior (zero change); the `text`-channel branch is the Asana path that ships with the Asana provider. The read-side `capture()` scanners already consolidated behind `itp_list_comments` ([INV-90], #281). **Out of scope for #283** (so still raw `gh` and deferred): `gh pr comment` / review-thread replies (CHP, owned by chp-pr-lifecycle); and the CI **cutover-guard lint** that mechanically rejects any future raw `gh` issue-comment (owned by the cutover-guard-lint sibling — this invariant is the migration; that sibling is the enforcement).

**Producer**: `itp_github_post_comment` (the write leaf, #283) + the per-provider `marker_channel` cap. **Consumer**: every machine-marker issue-comment writer — `post_dispatch_token`, `_dep_block_comment`, the dev/review wrappers' session/verdict/diagnostic comments, `dispatcher-tick.sh`'s stale-detection markers, and `emit_verdict_trailer` — now all via `itp_post_comment` — plus every `capture()`-style read-side scanner.

**Tests**: `tests/unit/test-provider-spec.sh` asserts the spec pins `marker_channel=html` for GitHub and documents the agent-AND-dispatcher coverage + the read-side channel branch. `tests/unit/test-itp-write-leaves.sh` (#283) golden-traces `itp_github_post_comment` byte-identical (incl. the INV-18 `dispatcher-token` + INV-39 `dep-block` marker bodies verbatim), pins the html channel does NOT strip `<!-- … -->`, asserts ZERO raw `gh issue comment` across all six ITP-issue-comment files (`lib-dispatch.sh`, `autonomous-{dev,review}.sh`, `dispatcher-tick.sh`, `lib-review-verdict.sh`, `post-verdict.sh`), and exercises the `marker_channel=text` / `edit_comment=0` degraded-provider branches. `tests/unit/test-autonomous-review-verdict-trailer.sh` confirms `emit_verdict_trailer` still emits the byte-identical trailer through the verb; `tests/unit/test-itp-write-leaves.sh::TC-POSTVERDICT-*` drives the real `post-verdict.sh` (with the seam loaded) and asserts the verdict routes through `itp_post_comment` to the [INV-56] proxy `gh` with byte-identical argv + the INV-20/INV-40 trailer. `tests/unit/test-mark-stalled-golden-trace.sh` / `tests/unit/test-handle-completed-routing-golden-trace.sh` (#285) golden-trace the two entangled orchestrators' marker posts — including the [INV-18]-class `INV-26-stall-deferral` / `INV-35-fresh-dev` markers and the [INV-85] `no-progress-substantive-attempt:<head>` HTML marker — all through `itp_post_comment`, proving the marker choke-point holds for the orchestrator layer too.

**Cross-references**:
- [`provider-spec.md`](provider-spec.md) §4 (`marker_channel`) + §3.1 (`itp_post_comment` choke-point).
- INV-18 (dispatch-token comment, `post_dispatch_token`) / [INV-39](#inv-39-dependency-parsing-is-list-item-scoped-and-supports-cross-repo-refs) (dependency-block comment, `_dep_block_comment`) — the dispatcher markers this pin now covers. (Issue #279 cites the dispatch-token marker as "INV-18"; it is pinned by the `post_dispatch_token` function, not a same-numbered heading — the current INV-18 is "Cold-start grace period".)
- [INV-87](#inv-87-provider-dispatch-is-spec-defined--callers-route-every-issuecode-host-op-through-itp_chp_-never-a-raw-gh-in-the-caller-layer) — the dispatch routing that funnels markers through `itp_post_comment`.

## INV-90: the normalized issue-comment shape is `[{id, author, body, createdAt}]`, sorted ascending by `createdAt`, with `author` a machine handle for EXACT equality

_Triage (issue #236): [machine-checked: tests/unit/test-provider-spec.sh]_

**Rule**: `itp_list_comments` returns ISSUE-level comments as a normalized JSON array `[{id, author, body, createdAt}]` (plus the normalized `authorKind` enum `bot`/`human`/`self`), **sorted ascending by `createdAt` (a normative MUST)**. Field contracts ([`provider-spec.md`](provider-spec.md) §3.3): `id` is the backend-native comment id the **same provider's** `itp_edit_comment`/reply verbs consume (GitHub: REST **numeric** id — the [INV-46] PATCH path needs numeric, not a GraphQL node_id); `author` is a **stable machine handle for EXACT equality**, NOT a display name (GitHub: `user.login` **including the `[bot]` suffix verbatim**); `createdAt` is an ISO-8601 UTC string. The marker-parsing logic stays caller-side and provider-neutral; only the fetch moves behind the ITP. Review-thread / inline-PR comments are a **separate CHP shape** (`{thread_id, resolved, comments:[{id, path, line, author, body, createdAt}]}`), never folded into this issue-comment shape.

**Why**: the shape is load-bearing for two existing invariants. [INV-46] (the SHA evidence stamp) GETs the last bot comment's `id` then PATCHes it — a shape without `id` cannot identify-then-mutate. [INV-85] (the bot-unfixable exact-equality detector) does `select((.author.login // "") == $dev)` — a display name silently breaks `== $dev`. The ascending-`createdAt` order is what the `| last` and `sort_by(.createdAt) | last` idioms ([INV-05]/[INV-57]) and the `.createdAt > cutoff` string compares depend on. Deliberately OUT of the shape (zero consumers): `reactions`, `isMinimized`, `permalink`, `viewerDidAuthor`, `authorAssociation`, `updatedAt`/`lastEditedAt` — recorded as a forward risk for any future in-place-edit backend.

**Status**: **IMPLEMENTED for GitHub in #281** (spec-defined with #279). `itp_github_list_comments` (`providers/itp-github.sh`) fetches `gh issue view --json comments` and normalizes to `[{id, author, authorKind, body, createdAt}]` sorted ascending by `createdAt`: `id` is the REST numeric id parsed from the comment `url` (`issuecomment-<n>`), `author` is `user.login` incl `[bot]` verbatim, `authorKind` is `self` (== `$BOT_LOGIN`) / `bot` (login ends `[bot]`) / `human`. The 28 marker-scanners are refactored to consume this array with all `capture`/`sort_by(.createdAt)|last`/exact-eq parse staying caller-side and provider-neutral. Proven behavior-preserving by `tests/unit/test-itp-read-leaves.sh` (the [INV-85] exact-eq and [INV-05]/[INV-57] cutoff idioms select identically pre/post) and the unchanged existing suites.

**Producer**: `itp_github_list_comments` (GitHub impl, #281). **Consumer**: the 28 marker-scanners (`extract_dev_session_id`, `last_reviewed_head`, `classify_recent_review_verdict`, `count_agent_failures`, the [INV-85] detector, …) — all now fetch via `itp_list_comments`.

**Tests**: `tests/unit/test-provider-spec.sh` asserts the spec carries the `[{id, author, body, createdAt}]` shape literal + the `authorKind` enum. `tests/unit/test-itp-read-leaves.sh` (#281) asserts the GitHub impl emits exactly the five-field shape sorted ascending by `createdAt`, that `id` is the REST numeric id, and that the INV-85 exact-equality + INV-05 cutoff selection are identical to the pre-refactor inline jq.

**Cross-references**:
- [`provider-spec.md`](provider-spec.md) §3.3 — the normalized comment-JSON contract.
- [INV-46](#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) — the edit/PATCH path that needs the numeric `id`.
- [INV-85](#inv-85-the-completed-session-failed-substantive-route-is-bounded-to-one-dev-new-per-unchanged-head-a-no-progress-or-bot-unfixable-finding-escalates-to-stalled-never-loops) — the exact-equality detector that needs `author` as a machine handle.

## INV-91: the provider-neutral caller layer routes ALL host I/O through `itp_*`/`chp_*` verbs — a NEW raw `gh` outside `providers/` is a CI-failing cutover regression (baseline-anchored)

_Triage (issue #236): [machine-checked: tests/unit/test-provider-cutover.sh]_

**Rule**: the provider-neutral caller layer (`lib-dispatch.sh`, `autonomous-dev.sh`, `autonomous-review.sh`, every `lib-review-*.sh`) MUST route every issue-tracker / code-host operation through an ITP/CHP verb (`itp_*`/`chp_*`), never a raw `gh`. This explicitly includes the dispatcher's OWN marker writers — `post_dispatch_token` ([INV-18]) and `_dep_block_comment` ([INV-39]) — which post through `itp_post_comment`, the **sole marker choke-point** ([provider-spec.md](provider-spec.md) §M6, [INV-89]). The host-I/O leaves live ONLY under `scripts/providers/` (`itp-github.sh`, `chp-github.sh`); ONLY the auth/transport wrappers (`scripts/gh`, `gh-with-token-refresh.sh`, `gh-app-token.sh`, `gh-as-user.sh`, `dispatch-remote-aws-ssm.sh`) are allowlisted by file (spec §8: GitHub auth is unchanged, not refactored). The guard script is **NOT** allowlisted — it is scanned like any file, its own legitimate `gh `-mentioning lines recorded as ordinary baselined survivors, so a NEW raw `gh` added to the checker itself trips the guard (#286 review round 2). `check-provider-cutover.sh` enforces this: it **recursively** scans the WHOLE dispatcher scripts tree (`find -L` over every `*.sh` at any depth — top-level, `adapters/`, `providers/`, future subdirs; `-L` so the symlinked tracked scripts like `mark-issue-checkbox.sh` stay in scope) for a raw `gh ` token via the RE2-safe consuming boundary `(^|[^A-Za-z_-])gh ` (never a look-behind — [gh --jq is RE2]), and classifies each non-comment hit as `providers/` (the migration target) / an allowlisted file / a baselined surviving site — anything else FAILs LOUD naming the exact **`file:line`**. This satisfies #286 AC #41 (every surviving raw-gh in `skills/autonomous-dispatcher/scripts/` — at any nesting depth — resolves to providers/ or an allowlisted file) and AC #2 (the failure names `file:line`). The guard additionally anchors the baseline to the trusted merged ref (a PR may only SHRINK it — see the Monotonicity guard below) so the baseline cannot self-ratify a new raw-gh in the same change that introduces it.

**Baseline-anchored, NOT a from-zero ban**: the depends-on issues (#281–#285) migrated only the spec-named verb leaves (§3.1/§3.2), so the caller layer still holds the surviving raw-gh sites the first deliverable did not migrate (label flips, `gh issue view/close`, `gh pr comment`, `gh api`, and agent-prompt heredoc prose). Those are frozen in the declarative manifest `providers/cutover-baseline.json`, keyed by `(file, trimmed-content)` COUNT (the same discovered-vs-declared reconciliation as [INV-80]'s `check-spec-drift.sh` Check C.4). The guard PASSES today, FAILs any NEW raw-gh (content not baselined), FAILs a DUPLICATE of a baselined line (count bump), and FAILs a REMOVED baselined site (count drop) — so a migration PR that pulls a caller-side `gh` leaf behind a verb is FORCED to shrink the baseline in the same PR. As the survivors migrate, the baseline shrinks to empty and the guard becomes the strict from-zero ban the cutover envisioned.

**Monotonicity guard (closes the same-PR self-ratification bypass)**: the discovered-vs-declared reconcile above only proves the tree matches WHATEVER baseline ships in the same change — so a PR that BOTH adds a raw-gh AND regenerates the baseline (`--generate-baseline`) would satisfy it (a #286 review reproduced `gh issue view 123` + regenerate → exit 0). The guard therefore ALSO compares the working-tree baseline against the **trusted (merged) survivor set** at `--trusted-ref` (default `origin/main`; override via the flag or `CUTOVER_TRUSTED_REF`) and FAILs if it GREW — a new `(file,content)` signature OR a higher count for an existing one — naming the grown site. The trusted survivor set is read from (1) the trusted baseline JSON at the ref if present (the steady state), ELSE (2) **DERIVED FROM THE TRUSTED TREE** by discovering raw-gh directly from the ref's `*.sh` (`git show <ref>:<path>`, dereferencing symlinked tracked scripts — the ref-tree analogue of the working-tree `find -L`). Source (2) closes the **initial-landing self-ratification hole** (#286 review finding #1): the PR that INTRODUCES the baseline has no baseline JSON on main, so deriving from the tree catches a new raw-gh added to an EXISTING (on-ref) script even on that first PR; a growth in a file ABSENT from the ref is the legitimate introduction of a NEW file (e.g. the guard itself), allowed (still gated by Check 1), not a regression. The baseline may therefore only ever SHRINK; ratifying a NEW raw-gh site is rejected even when the in-PR reconcile is satisfied. When not in a git work tree, or the ref / trusted baseline is unresolvable (shallow / fork checkout, or the very first PR that introduces the baseline), the monotonicity check SKIPS gracefully **by default** — BUT `--require-trusted-ref` (env `CUTOVER_REQUIRE_TRUSTED_REF=1`) turns that skip into a hard FAILURE. The strict mode closes the **shallow-CI hole** (#286 review): the hermetic-unit job runs the guard via the `test-*.sh` glob under a depth-1 `actions/checkout` where `origin/main` is absent, so a permissive skip there would let a self-ratifying PR pass green. The unit test drives the guard with `--require-trusted-ref` against a self-contained git fixture, so monotonicity is enforced regardless of checkout depth; the operator-applied ci.yml step uses `fetch-depth: 0` + `--require-trusted-ref` so the dedicated step enforces it too. The detector greps with `-a` (force text) so a script carrying UTF-8 punctuation is never misclassified "binary" and silently skipped.

**Why**: the "sole choke-point" property (one verb per host operation) is what lets a GitLab/Asana backend slot in without re-architecting callers (spec §1/§7). A raw `gh` that re-enters the caller layer silently re-couples the pipeline to GitHub and bypasses the capability/marker-channel branches — exactly the regression this guard exists to catch. Without a CI gate, the partial migration would silently rot back toward raw-gh as new pipeline code is added (issue #286).

**Producer**: the ITP/CHP verb dispatch (`lib-issue-provider.sh`/`lib-code-host.sh`, [INV-87]) + `providers/itp-github.sh`/`chp-github.sh`. **Consumer**: every caller-layer file + `check-provider-cutover.sh` (the CI gate) + `providers/cutover-baseline.json` (the regression anchor).

**Status**: **IMPLEMENTED in #286** (the cutover guard). Wiring the lint into a dedicated `.github/workflows/ci.yml` step (`check-provider-cutover.sh` in the credential-free `spec-drift` job, with `fetch-depth: 0` + `--require-trusted-ref` so Check 4 monotonicity runs there too, plus the three scripts on the hermetic `shellcheck -S error` list) is a **NON-BLOCKING maintainer follow-up (#295), NOT part of #286** (owner ruling 2026-06-28). **The dev-side scoped App token cannot push `.github/workflows/`** ([INV-83] — a `git push` of any workflow change is rejected `without 'workflows' permission`), and #286 was re-scoped so the PR MUST NOT be blocked on a workflows edit. **Strict-mode fail-closed (AC #6 / review P1#1)**: under `--require-trusted-ref` a missing/unreadable/unparseable working-tree baseline — or a trusted ref that resolves but lacks `cutover-baseline.json` — exits 1 (never "nothing to regress against yet" + exit 0; no silent derive-from-tree fallback in strict mode); a baseline is (re)generated ONLY under `--generate-baseline`, never silently during a normal lint. Until then the guard still executes in CI through the existing `tests/unit/test-*.sh` loop (`test-provider-cutover.sh` invokes it against the real repo, so a regression goes red in the hermetic-unit job). The §7.4 fake degraded-capability fixture is promoted to a coverage gate (`tests/unit/test-provider-caps-branches.sh`): it EXERCISES (reachable + degraded-value-driveable through the public seam) the 8 caps that have a live caller branch today — RUNNING four of them end-to-end against the degraded fixture (`label_colors` via `setup-labels.sh`; `merge_closes_issue`/`native_issue_pr_link` via `_render_close_keyword`; `body_checkbox` via `mark-issue-checkbox.sh`) — and WAIVES the 5 caps whose caller branch is not yet wired (spec §4.3) behind a fail-on-wiring tripwire: if any waived cap ever gains a caller branch the suite FAILs, so no future caps=0 branch can ship untested. The headline prints `exercised=8 waived=5 total=13` and asserts the split equals the full 9 ITP + 4 CHP matrix. NOTE: on the HEAD #286 targets the migration is PARTIAL (~70+ surviving raw-`gh ` tokens tree-wide), so the guard is the baseline-anchored regression form described above, not yet a from-zero ban; likewise 5 caps are waived-not-exercised because their caller branch does not exist on a GitHub-only HEAD.

**Tests**: `tests/unit/test-provider-cutover.sh` (clean-pass; injected-new-gh fail naming `file:line`; tree-wide catch of a NEW gh in a NON-caller dispatcher script (AC #41); a NEW gh under `providers/` does NOT trip; guard self-exclusion; allowlisted-file pass; consuming-boundary catch; duplicate-bump fail; removed-site fail; stale-baseline fail; missing-provider fail; `--generate-baseline` round-trip; **same-PR baseline self-ratification bypass closed by Check 4 monotonicity (TC-CUTOVER-017); shrink/clean allowed + missing-trusted-ref graceful skip (TC-CUTOVER-018); `--require-trusted-ref` makes a missing ref a hard FAIL, closing the shallow-CI skip hole, while non-strict still skips (TC-CUTOVER-019); derive-from-tree catches a new gh in an EXISTING on-ref script on the initial-landing PR (no baseline JSON on main), exempts new files, and dereferences symlinked tracked scripts (TC-CUTOVER-020)**). `tests/unit/test-provider-caps-branches.sh` (tripwire self-test; 8 live caps reachable+driveable with 4 RUN end-to-end; 5 deferred caps waived behind a fail-on-wiring tripwire; `exercised=8 waived=5 total=13` accounting).

**Cross-references**:
- [`provider-spec.md`](provider-spec.md) §9 — references this invariant as the cutover/anti-regression guard.
- [INV-87](#inv-87-provider-dispatch-is-spec-defined--callers-route-every-issuecode-host-op-through-itp_chp_-never-a-raw-gh-in-the-caller-layer) — the verb-dispatch contract this guard enforces.
- [INV-89](#inv-89-every-machine-marker--agent-and-dispatcher-inv-18inv-39-included--is-posted-only-through-the-declared-marker_channel-the-read-side-capture-regex-branches-on-channel) — the marker choke-point ([INV-18]/[INV-39] markers via `itp_post_comment`).
- [INV-80](#inv-80-the-label-state-machine-is-a-ci-checked-executable-spec--the-mermaid-diagram-is-generated-undeclared-label-transitions-fail-ci) — the sibling `check-spec-drift.sh` discovered-vs-declared (C.4) reconciliation pattern.

## Adding a new invariant

When fixing a pipeline bug, after locating the bug on the state machine + flow docs:

1. Decide whether the bug surfaces a previously-implicit rule. Most pipeline bugs do.
2. Add a new `INV-NN` entry here (next sequential number).
3. Cite the issue / PR number in the **Why** field.
4. Identify producer and consumer — these are the actors whose behavior the invariant constrains.
5. Add a TODO for the test, even if you don't write the test in the same PR. (Tests for these invariants should live in `tests/unit/` and be enumerated in the CI shellcheck job.)
6. Reference the invariant by ID from the flow doc(s) where it's relevant.
7. Add the one-line triage tag (see [Triage tags](#triage-tags) below) directly under the heading.

Once `INV-NN` exists, prefer "violates [INV-NN](#inv-NN-...)" in commit messages and PR descriptions over re-explaining the rule.

## Triage tags

Every `## INV-NN:` heading carries a one-line `_Triage (issue #236): [<tag>]_`
annotation directly beneath it (issue #236). The tag is one of:

- **`[machine-checked: <test/CI>]`** — a test or CI job mechanically enforces this invariant today. The cited file is the enforcement of record.
- **`[design-rationale]`** — a real rule with no current machine check (the `**Test**:` line is a `TODO`, or enforcement is human-review-only / gated). A candidate for a future regression test.
- **`[superseded]`** — the invariant's mechanism was removed/replaced (the `**Status**:` line says SUPERSEDED); the text is retained for historical context only.

This is triage metadata, not a content rewrite — the full machine-checked-vs-rationale migration (writing the missing regression tests) is later, gated work. New INV entries MUST carry a tag (step 7 above); `tests/unit/test-spec-drift.sh` asserts every heading is tagged and the tag is one of the three forms.

## Cross-references

- [`state-machine.md`](state-machine.md) — invariants flagged inline at the relevant transitions.
- [`dispatcher-flow.md`](dispatcher-flow.md), [`dev-agent-flow.md`](dev-agent-flow.md), [`review-agent-flow.md`](review-agent-flow.md) — every flow step that depends on or upholds an invariant cites it by ID.
- [`handoffs.md`](handoffs.md) — invariants are the producer/consumer contracts at each handoff.
