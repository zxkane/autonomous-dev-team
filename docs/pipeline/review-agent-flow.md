# Review-Agent Wrapper Flow

The review-agent wrapper is `skills/autonomous-dispatcher/scripts/autonomous-review.sh`. The dispatcher launches it via `dispatch-local.sh review <issue>`. The wrapper finds the PR linked to the issue, runs the underlying agent against it, parses the agent's verdict from issue comments, and either approves+merges (PASS) or submits `--request-changes` and sends the issue back to dev (FAIL). The **wrapper** owns the GitHub-native PR review/merge action on BOTH sides — `--approve`/`gh pr merge` on PASS and `--request-changes` on a substantive FAIL — while the review **agent** posts a verdict comment only and never runs `gh pr review`/`gh pr merge` itself ([INV-52](invariants.md#inv-52-the-review-wrapper-owns-the-github-native-pr-reviewmerge-action-the-agent-posts-verdicts-only)).

The wrapper is the **producer** for two of the five [handoffs](handoffs.md) (review → approved/merged, review → pending-dev) and the **consumer** for one (dispatcher → review).

The default model is Sonnet (vs Opus for dev) — review is checklist-driven and benefits less from the larger model, and using a different model class avoids quota contention with the more expensive dev sessions.

## Lifecycle

```mermaid
sequenceDiagram
    participant D as dispatch-local.sh
    participant W as autonomous-review.sh
    participant L as lib-agent.sh
    participant A as claude / codex / gemini / kiro / opencode
    participant GH as GitHub API

    D->>D: kill_stale_wrapper(PID_FILE)
    D->>W: nohup autonomous-review.sh --issue N
    W->>W: setup_github_auth
    W->>W: acquire_pid_guard(PID_FILE)
    W->>GH: find PR linked to issue (3 fallback methods)
    alt no PR found
        W->>GH: comment 'Review failed - no PR found'
        W->>GH: remove reviewing, add pending-dev
        W-->>D: exit 1
    end
    W->>GH: extract preview URL (if E2E_MODE=browser)
    W->>W: build review prompt (mergeability, drift, checklist, decision)
    W->>L: run_agent
    L->>A: printf '%s' PROMPT | claude --session-id ... --model sonnet -p
    A->>GH: post verdict comment ('Review PASSED' or 'Review findings')
    A-->>L: agent exits
    W->>GH: poll for verdict comment (6 attempts, 5s each, actor + window + trailer)
    W->>GH: post 'Reviewed HEAD' trailer (if verdict and SHA known)
    alt verdict PASS
        W->>GH: gh pr view --json state (re-check OPEN)
        W->>GH: gh pr review --approve
        opt no-auto-close NOT set
            W->>GH: gh pr merge --squash --delete-branch
            alt merge succeeded
                W->>GH: remove autonomous and reviewing, add approved
                Note over W,GH: GitHub auto-closes issue via 'Closes #N' (INV-33; wrapper does NOT call gh issue close)
            else merge failed (INV-33)
                W->>GH: gh pr comment 'Auto-merge failed: ... Re-dispatching dev'
                W->>GH: remove reviewing, add pending-dev (autonomous KEPT)
            end
        end
        opt no-auto-close set
            W->>GH: remove reviewing, add approved (autonomous KEPT)
        end
    else verdict FAIL or missing
        opt substantive FAIL (agent posted findings, or CONFLICTING gate)
            W->>GH: gh pr review --request-changes (INV-52; reviewDecision=CHANGES_REQUESTED; best-effort)
        end
        W->>GH: remove reviewing, add pending-dev
    end
    W->>W: rm -f PID_FILE and cleanup_github_auth
```

## Spawn, PID guard, auth

Same pattern as the dev wrapper — see [`dev-agent-flow.md`](dev-agent-flow.md#spawn-in-dispatch-localsh) — except:

- PID file: `${PID_DIR}/review-<N>.pid` ([INV-01](invariants.md#inv-01-pid-file-naming)) — `${PID_DIR}` resolved by `lib-config.sh::pid_dir_for_project`.
- Auth: review-agent app mode uses `REVIEW_AGENT_APP_ID` / `REVIEW_AGENT_APP_PEM` (separate App identity from dev so reviewer comments are attributed correctly).

## PR discovery (3 fallback methods)

1. **Body reference**: `gh pr list --state open --json number,body` and select the one whose body matches `#N` (with a non-digit boundary so `#1` doesn't match `#123`).
2. **Comment-mention extract**: scan issue comments for `(?:PR|pull)[/ #]*<digits>`.
3. **Search**: `gh pr list --search "issue N"` as a last resort.

If all three fail → comment "Review failed: no PR found linked to this issue. Please ensure the PR description contains 'Closes #N'." → `−reviewing +pending-dev` → exit 1.

This is one of the five legitimate ways the wrapper can transition to `pending-dev` even though the agent never ran. The dispatcher's Step 4a retry counter does NOT count this as a dev-failure — only `Agent Session Report (Dev)` comments and the dispatcher's own crash regex feed the counter.

## E2E mode dispatch (issue #161)

The review wrapper supports three E2E modes via `E2E_MODE` in `autonomous.conf`:

| `E2E_MODE` | Activates when | Prompt block |
|---|---|---|
| `none` (default when unset) | always — no E2E section in the prompt | (none) |
| `browser` | project explicitly opts in | Chrome DevTools MCP UI smoke test (existing) |
| `command` | project explicitly opts in | Project-supplied verify command (new) |

**Fail-loud at startup**: `E2E_ENABLED=true` with `E2E_MODE` unset exits the wrapper non-zero. Projects must opt into a specific mode rather than implicitly inheriting `browser`. This catches the most common upgrade footgun (existing projects had only `E2E_ENABLED`).

The wrapper internally derives `E2E_ACTIVE` (true when mode is `browser` or `command`); downstream prompt language gates off this flag rather than `E2E_ENABLED`.

### Preview URL extraction (browser mode only)

Only relevant when `E2E_MODE=browser` AND `E2E_PREVIEW_URL_PATTERN` is configured. The wrapper builds a URL from the pattern (replacing `{N}` with the PR number) and also scans PR comments for the most recent comment containing "Preview" + an `https://` URL. Comment-extracted URL takes priority (it's specific to the actual deploy).

If browser-mode E2E is enabled but preview URL extraction yields nothing, the agent's review prompt receives `Preview URL: NOT_FOUND`, and the agent is instructed to FAIL the review with "E2E verification failed: PR preview URL not found."

### Command rendering (command mode only)

In `command` mode the wrapper substitutes the literal `${PR_NUMBER}` placeholder in `E2E_COMMAND`, `E2E_COMMAND_PRE_HOOKS`, and `E2E_COMMAND_EVIDENCE_PARSER` with the resolved PR number before pasting them into the prompt. Operators MUST single-quote those assignments in `autonomous.conf` so the shell does not eagerly expand `${PR_NUMBER}` when sourcing the conf file. Unbraced `$PR_NUMBER` is rejected at config-validation time (would silently render as empty since the var is exported only inside the command-mode block, after substitution).

The wrapper exports `PR_NUMBER` and `PR_HEAD_SHA` into the lane process's environment when `E2E_MODE=command`. The project's evidence parser reads `PR_HEAD_SHA` from env to embed in the evidence-block marker.

**Since #182 ([INV-46](invariants.md#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent)) the E2E runs in a dedicated WRAPPER lane, ONCE, before the review fan-out — NOT in each review agent's prompt.** The exit-code semantics (0 → parser; 124 → parser on partial, recover-or-fail; other → skip parser + log-tail), the SHA-bound evidence marker, and the stale-evidence skip are unchanged, but they now execute in `lib-review-e2e.sh::_run_command_e2e_lane` (shell) / the one browser lane (LLM), not in N review-agent prompts. See [Sequential E2E lane (INV-46)](#sequential-e2e-lane-inv-46) below for the full lane + gate flow.

For the project-side contract (`E2E_COMMAND` semantics, evidence-block format, parser PR_HEAD_SHA usage), see `skills/autonomous-review/references/e2e-command-mode.md`.

> **Wait/stall budgets must fit the E2E ([INV-43](invariants.md#inv-43-command-mode-e2e-review-wait-budgets-must-not-be-smaller-than-the-e2e-they-dispatched), #172).** A command-mode E2E can take far longer than the legacy 30 s verdict-poll window or the 300 s dispatcher stall window. Post-#182 the E2E runs once in the wrapper lane (not per agent), so the per-agent verdict-poll window now only spans the residual code-review verdict wait — but the operator MUST still set `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS` ≥ `E2E_COMMAND_TIMEOUT_SECONDS` because the lane runs **synchronously inside the wrapper** before the fan-out, so the dispatcher's [INV-24](invariants.md#inv-24-review-wrapper-dead-detection-requires-both-pid_alive-miss-and-no-near-success-pr-signal) crash check must not SIGTERM the still-working wrapper mid-E2E. The verdict-poll budget still auto-scales (`lib-review-poll.sh::_resolve_verdict_poll_attempts`) as belt-and-suspenders. After verdict resolution the wrapper reaps any lingering fan-out agent process group AND the E2E lane's process group so neither outlives the round.

## Sequential E2E lane (INV-46)

When `E2E_MODE` is active (`browser` or `command`), the wrapper runs the project E2E **exactly once per review round** in a dedicated lane that completes **before** the review fan-out, then gates on the result. This replaces the pre-#182 design where the E2E execution block was injected into every review agent's prompt — so `AGENT_REVIEW_AGENTS` with N CLIs ran the full E2E N times (N× `E2E_COMMAND_PRE_HOOKS` container builds, N× verify, N× evidence, racing on shared stage state). See [INV-46](invariants.md#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent).

```
E2E_ACTIVE == true:
  PHASE A — run the E2E lane ONCE, to completion:
    command mode → _run_command_e2e_lane (lib-review-e2e.sh): a PURE SHELL subshell
        (no run_agent, token-free). Idempotency: reuse a SHA-matching evidence
        comment if present. Else pre-hooks → verify (under setsid + timeout
        --kill-after, PGID captured in _E2E_LANE_PGID) → parser → post evidence.
        Each step guarded `|| rc=$?` so set -e can't skip the .rc sidecar.
        INV-49: also extracts the OPTIONAL structured AC-coverage artifact from the
        evidence (fence ac-coverage:begin/end, jq-validated, fail-safe) → the
        per-round sidecar E2E_AC_COVERAGE_FILE for the fan-out's deterministic check.
    browser mode → ONE LLM lane (run_agent against build_browser_e2e_prompt). The
        LLM posts a `## E2E Verification Report` comment; the WRAPPER stamps the SHA
        marker ONTO that report (_stamp_browser_evidence_marker, REST PATCH) after a
        clean exit. No report to stamp → fail closed (rc forced non-zero).
  E2E HARD GATE — _classify_e2e_gate <lane_rc> <evidence_present>:
    (a) lane .rc == 0  AND
    (b) re-fetch (_fetch_sha_evidence, bounded retry) finds a SHA-matching
        evidence comment for the captured PR_HEAD_SHA
    → pass | fail | block-nonsubstantive
  gate == fail                 → [BLOCKING] E2E finding + failed-substantive
                                 + submit_request_changes (INV-52, best-effort)
                                 + −reviewing +pending-dev ; exit 0  (NO fan-out)
  gate == block-nonsubstantive → "Review held" + failed-non-substantive
                                 cause=e2e-evidence-missing + −reviewing
                                 +pending-dev ; exit 0  (re-queue, NO fan-out,
                                 NO request-changes — transient)
  gate == pass                 → PHASE B (review fan-out below)
E2E_ACTIVE == false → no lane, no gate (E2E_GATE=inactive); straight to fan-out.
```

- **command-mode lane is shell, not an LLM.** `_run_command_e2e_lane` runs entirely in the wrapper shell — no `run_agent`, no tokens. The verify command runs under `setsid` + `timeout --kill-after=30s --signal=TERM ${E2E_COMMAND_TIMEOUT_SECONDS}` so its subtree is reapable ([INV-23](invariants.md#inv-23-pid_file-points-at-a-process-whose-death-reaps-the-entire-agent-subtree)); the lane's PGID is added to `_reap_fanout_processes`'s arg list alongside the fan-out agents'.
- **browser-mode is ONE LLM lane**, not replicated across review agents. The wrapper stamps `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->` **onto the LLM-posted `## E2E Verification Report` comment** (`_stamp_browser_evidence_marker`, REST `PATCH`, idempotent) so the gate anchor is deterministic without the LLM transcribing the SHA — and so the gate's evidence-present signal + the review agents' evidence-read both resolve to the REAL report, not a marker-only comment. A clean exit with NO stampable report comment fails the gate closed (rc forced non-zero) — a marker-only comment can never satisfy the gate.
- **The gate is a mechanical dual-signal**, fail-closed: a crash between parser-ok and comment-post (`rc=0` but no SHA-matching evidence) routes `block-nonsubstantive` (transient re-queue), not a dev bounce; a real verify failure (`rc≠0`) routes `fail` (substantive). A `rc≠0`-with-stale-present-evidence does NOT pass.
- **Review agents are PURE code reviewers.** `build_review_prompt` no longer contains any E2E execution block; the prompt tells each agent to READ the wrapper-posted evidence comment as input and cross-check it against the acceptance criteria. They do not run E2E.
- **Structured AC-coverage double-check ([INV-49](invariants.md#inv-49-command-mode-e2e-may-feed-the-review-fan-out-a-structured-ac-coverage-artifact--optional-fail-safe), #183).** Command-mode only: when the evidence parser emits the optional `ac-coverage:begin … ac-coverage:end` JSON fence, the lane jq-validates it (fail-safe — malformed → empty, fall back to free-form; never fail-open) and writes it to `E2E_AC_COVERAGE_FILE`. When that per-round sidecar is non-empty, `build_review_prompt` PREFERS the deterministic map over LLM-parsing the free-form markdown table; an empty/absent sidecar yields the exact post-#182 free-form double-check. The artifact is a review aid only — the E2E hard gate is unchanged.
- **Composition**: `final PASS ≡ (E2E_ACTIVE==false OR gate==pass) AND review-unanimity-pass`. Because a gate fail/block exits before the fan-out, only `gate ∈ {pass, inactive}` ever reaches the review aggregation — the AND is enforced by the short-circuit. The E2E gate runs before the [INV-44](invariants.md#inv-44-mergeable-hard-gate--a-conflicting-pr-can-never-reach-approved) mergeable block.

## Per-side review timeout (INV-48)

The review side has its OWN wall-clock cap, separate from the shared 4h `AGENT_TIMEOUT` ([INV-13](invariants.md#inv-13-wall-clock-cap-on-agent-invocations)). In the per-side override block (next to the [INV-37](invariants.md#inv-37-per-side-agent_cmd-precedence) `AGENT_CMD` and [INV-38](invariants.md#inv-38-per-side-agent_launcher-precedence) `AGENT_LAUNCHER_ARGV` rebinds, AFTER `source lib-auth.sh`), the wrapper:

```bash
_ORIG_AGENT_TIMEOUT="$AGENT_TIMEOUT"                          # the conf 4h (INV-13)
AGENT_TIMEOUT="${AGENT_REVIEW_TIMEOUT:-1h}"                   # review cap, 1h literal default
E2E_BROWSER_TIMEOUT_SECONDS="${E2E_BROWSER_TIMEOUT_SECONDS:-$_ORIG_AGENT_TIMEOUT}"  # browser-E2E keeps 4h
```

Because `_run_with_timeout` reads the LIVE `AGENT_TIMEOUT` at call time, this rebind caps every review fan-out agent at the review timeout — with no change to `lib-agent.sh`. The **dev wrapper is untouched** (keeps 4h); it never reads `AGENT_REVIEW_TIMEOUT`. See [INV-48](invariants.md#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto). Three safety rails make the aggressive 1h cap safe:

- **Browser-E2E exclusion.** The browser-mode E2E lane ([INV-46](invariants.md#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) Phase A) is an LLM `run_agent` lane that would otherwise inherit the 1h cap; it runs under a LOCAL `AGENT_TIMEOUT="$E2E_BROWSER_TIMEOUT_SECONDS"` rebind inside its existing subshell (naturally scoped; the parent's review cap is unchanged for the fan-out), defaulting to the original 4h so a slow preview deploy is not killed at 1h. Command-mode E2E already runs its verify under `timeout … ${E2E_COMMAND_TIMEOUT_SECONDS}` and is unaffected.
- **Timeout-veto.** A fan-out agent killed BY the cap (CLI exit `124`/`137`) with no posted verdict is classified `timed-out` and counted as a deciding FAIL ([INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) amendment) — it VETOES the merge instead of being silently dropped as `unavailable`. See [Aggregation](#aggregation-unanimous-pass) below.
- **Startup validation.** `validate_review_timeout_config` rejects non-`timeout`-unit and `0` values for `AGENT_REVIEW_TIMEOUT` / `E2E_BROWSER_TIMEOUT_SECONDS` (fail-loud, mirrors `validate_e2e_config`); a startup `log` line reports the resolved review cap, browser-E2E cap, and the unaffected dev cap.

## Multi-agent fan-out (INV-40)

By default the wrapper runs exactly ONE verdict-reaching agent (`AGENT_REVIEW_CMD`, the per-side review CLI). Setting `AGENT_REVIEW_AGENTS` to a space-separated list (e.g. `"agy kiro"`) makes the wrapper run all listed agents **in parallel against the same PR** and gate the merge on their **unanimous agreement** ([INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)). The fan-out is entirely internal to the wrapper: the dispatcher, the single `review-${N}.pid` file, and the `reviewing` label are unchanged.

> **Distinct from `REVIEW_BOTS`.** `REVIEW_BOTS` (`/q review`, `/codex review`) triggers *external GitHub bots* whose review comments are read as **input** by the verdict agent(s). `AGENT_REVIEW_AGENTS` runs N *independent verdict-reaching* agents — each reaches its own approve/pushback decision, and the wrapper aggregates them.

### Agent-list resolution

`REVIEW_AGENTS_LIST` resolves once at startup:
- `AGENT_REVIEW_AGENTS` non-empty → the word-split list (`agy kiro` → `(agy kiro)`).
- empty/unset → `("$AGENT_CMD")` — exactly one element equal to the already-rebound `$AGENT_REVIEW_CMD` ([INV-37](invariants.md#inv-37-per-side-agent_cmd-precedence)). This is the N=1 backward-compatible default; everything below collapses to the legacy single-agent behavior.

### Fan-out

One backgrounded subshell per agent. Each subshell:
- overrides `AGENT_CMD="$agent"` locally so `run_agent` dispatches to THAT CLI;
- mints its OWN `SESSION_ID` (`uuidgen`) — distinct per agent so verdict comments don't collapse under a shared GitHub identity;
- **resolves its OWN launcher** ([INV-42](invariants.md#inv-42-per-agent-review-launcher-resolution), #173) via `lib-review-resolve.sh::_resolve_review_agent_launcher "$agent"` (looks up `AGENT_REVIEW_LAUNCHER_<SUFFIX>`, same suffix transform): if a per-agent key is set, the value is `eval`-tokenized into `AGENT_LAUNCHER_ARGV` and the [INV-38](invariants.md#inv-38-per-side-agent_launcher-precedence) claude-only guard is **bypassed for this agent** (the operator asserted the launcher fits this CLI; a tokenize failure logs an ERROR and runs naked). If NO per-agent key is set, the launcher is neutralized (`AGENT_LAUNCHER_ARGV=()`) for non-`claude` members ([INV-38](invariants.md#inv-38-per-side-agent_launcher-precedence): a claude-only `cc` bridge must not wrap a non-claude CLI) while a `claude` member keeps the shared `AGENT_REVIEW_LAUNCHER`. The resolver deliberately does NOT fall back to the shared launcher — see INV-42. This is the escape valve that lets a fleet add a third reviewer like `codex` whose headless launch needs a per-machine bridge (the same `bash -c 'source ~/.bash_aliases && codex "$@"' --` shape as the `cc` claude launcher);
- `unset AGENT_PID_FILE` so the per-agent `run_agent` does NOT rewrite the wrapper's single `review-${N}.pid` (the wrapper owns that file; the dispatcher's liveness model depends on it);
- **resolves its OWN model + extra-args** ([INV-41](invariants.md#inv-41-per-agent-review-model--extra-args-resolution), #168) via `lib-review-resolve.sh`: `_resolve_review_agent_model "$agent"` looks up `AGENT_REVIEW_MODEL_<SUFFIX>` (suffix = uppercased name, every char outside `[A-Z0-9]`→`_`) else the shared `AGENT_REVIEW_MODEL`, and the resolved value is passed to `run_agent` as `"${_agent_model:-sonnet}"`; `_resolve_review_agent_extra_args "$agent"` looks up `AGENT_REVIEW_EXTRA_ARGS_<SUFFIX>` else the shared `AGENT_REVIEW_EXTRA_ARGS`, and is assigned to `AGENT_DEV_EXTRA_ARGS` — the var `run_agent`'s `_parse_extra_args` actually reads, since the fan-out runs a *fresh* `run_agent` (not `resume_agent`). Both lookups are scoped to this subshell. With no per-agent key set, both resolve to the shared values, so the model arg is identical to the legacy `${AGENT_REVIEW_MODEL:-sonnet}` and the N=1 path is byte-for-byte legacy. This lets a mixed `"kiro <claude-fam>"` fleet give kiro `claude-sonnet-4.6` and the claude-family agent `sonnet[1m]` — two model ids each CLI would reject if forced to share one;
- writes to its OWN log `/tmp/agent-${PROJECT_ID}-review-${N}-${agent}.log`;
- builds its prompt via `build_review_prompt "$agent" "$SESSION_ID"` and records its CLI exit code to a per-run sidecar (a subshell can't mutate the parent's variables);
- **dispatches via the right agent-launch path for its CLI**: a `codex` agent goes through `lib-review-codex.sh::_run_codex_review_with_resume` (the auto-resume loop, [INV-51](invariants.md#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn)); every other CLI calls `run_agent` directly — byte-for-byte the pre-#189 invocation. See [Codex auto-resume (INV-51)](#codex-auto-resume-inv-51) below.

The fan-out loop appends each subshell's PID (`$!`) to a `_fanout_pids` array and the wrapper joins with `wait "${_fanout_pids[@]}"` — the **collected PIDs only**. A bare `wait` is forbidden here: it would also block on the long-lived `gh-token-refresh-daemon` and the heartbeat `sleep` loop (neither exits), hanging the wrapper forever after the agents finish and stranding the issue in `reviewing`. See [INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) sub-rule 1.

### Codex auto-resume (INV-51)

`codex exec` runs exactly ONE agentic turn. On a large review diff codex
non-deterministically spends that whole turn on context-gathering (`git diff`,
file reads — 55k–120k input tokens) and then emits `turn.completed` with no
findings and **no verdict comment**; the verdict poller below sees nothing within
its window and the agent is dropped as `unavailable` ([INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)) — losing codex's independent second opinion exactly on the diffs that need it. Waiting longer does NOT help: codex's turn already **ENDED**. The fix is to issue **another turn**.

So a `codex` fan-out member is dispatched through `lib-review-codex.sh::_run_codex_review_with_resume` instead of a bare `run_agent` ([INV-51](invariants.md#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn)). The controller:

1. runs codex once via `run_agent` (its codex branch captures the `thread_id` from the `thread.started` JSONL event into the existing sidecar, keyed by the dispatcher session id);
2. inspects codex's own JSONL event stream — the **same** `$_agent_log` the invocation writes — for whether the LAST completed turn **posted the VERDICT** (`_codex_log_has_verdict_message`, [INV-53](invariants.md#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message)): an `item.completed` `agent_message` whose **text carries a verdict trailer** — a pass/fail phrasing the comment poller matches (`Review PASSED` / `Review findings:` / …) or the `Review Agent: codex` discriminator. A `turn.completed` whose items are all `tool_call`/`reasoning`/`command_execution`, **or whose only `agent_message`s are progress narration** (no verdict trailer), is gather-only;
3. while the last turn is gather-only, resumes the SAME thread via `resume_agent` (`codex exec resume <thread_id>`) with an explicit "continue — do NOT re-run `git diff` — produce findings and post the verdict now" prompt;
4. stops at the FIRST of: a verdict-posting turn, `CODEX_REVIEW_MAX_RESUMES` (default 3) resumes, or the `AGENT_REVIEW_TIMEOUT`-derived wall-clock deadline (`_codex_review_deadline_seconds`; an unparseable cap degrades to the 1h default, never unbounded).

> **#198 / [INV-53](invariants.md#inv-53-codex-review-convergence-keys-on-the-verdict-trailer-not-any-agent_message)** corrects step 2: the original #189 detector converged on the mere PRESENCE of an `agent_message`, but codex emits `agent_message` for narration ("Next I'm reading the instructions…"), so a gather-heavy turn that narrated then died before posting a verdict false-converged → the loop broke on round 1, no resume fired, the poller found no verdict, and codex was still dropped `unavailable`. Keying on the verdict TRAILER (the same phrasings the poller matches, plus `Review Agent: codex`) makes "the JSONL stream shows a verdict-shaped message" agree with "the poller will find the comment". The detection is fail-safe toward resuming (ambiguous turn → bounded resume, never a false stop). A separate investigation (#198) also CONFIRMED that `codex exec resume` carries session on amazon-bedrock (codex-cli 0.137.0) — same `thread.started` id, replayed + cached prior conversation, recall verified — so the resume loop itself is sound and is kept; only the convergence signal changed.

> **[INV-55](invariants.md#inv-55-the-codex-review-lane-receives-the-pr-diff-inline-in-its-prompt)** is the other half of the fix. Re-reviewing #193 under the INV-53 code showed codex still dropped `unavailable`: the loop correctly resumed (no more false-converge), but EVERY turn re-ran `git diff` at several `--unified` sizes (320k input tokens, no verdict) and burned all 3 resumes still gathering. So `build_review_prompt` now, for the **codex lane only**, fetches the diff ONCE in shell (`gh pr diff`) and inlines it between `DIFF_START`/`DIFF_END` with an explicit "do NOT run `git diff`" instruction, bounded by `CODEX_REVIEW_INLINE_DIFF_MAX_BYTES` (default 600k → fall back to a single-`gh pr diff` instruction above the cap). With the diff in hand, codex's single turn produces findings + posts the verdict instead of re-gathering — so the resume loop becomes a thin fallback rather than the mechanism. The other CLIs keep the unchanged self-fetch prompt. `agy` shows the same gather-burn but is a scoped-out follow-up.

The loop NEVER queries the GitHub comments API — that is the verdict poller's job below, and it stays the **authoritative** verdict gate after the controller returns. The JSONL loop only gets codex to FINISH a turn; the poller confirms the verdict comment landed. On bound exhaustion with no verdict, codex is resolved `unavailable` by the post-window sweep — exactly the pre-#189 fallback (no regression). The INV-48 timeout rc-stickiness is unchanged: a timed-out codex turn still vetoes via the sweep, never silently dropped. Scope is strictly `AGENT_CMD == codex`; `CODEX_REVIEW_MAX_RESUMES=0` disables the loop (codex behaves as before #189). The generic `run_agent`/`resume_agent` in `lib-agent.sh` are **not** modified — the loop lives in the review layer so verdict/GitHub semantics never leak into the CLI-agnostic plumbing.

### Per-agent verdict collection

For each agent, the wrapper runs ONE verdict jq query with the [INV-20](invariants.md#inv-20-verdict-authenticity-binding-actor--window--trailer-presence) authenticity binding PLUS a per-agent `Review Agent: <name>` discriminator predicate, taking `last` per agent. Each matched comment is classified with the existing two-step FAIL-first rule (`_classify_verdict_body`, in `lib-review-poll.sh`). A no-verdict agent is resolved at window-expiry by `lib-review-aggregate.sh::_classify_noverdict_agent <rc>` ([INV-48](invariants.md#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto)): CLI exit `124`/`137` (killed by the review wall-clock cap) → **`timed-out`** (a deciding FAIL veto), any other rc → **`unavailable`** (dropped). The window is the full (INV-43-scaled) poll window — a non-zero exit does **not** drop it early (see [Verdict polling](#verdict-polling), #180), and a verdict (PASS or FAIL) it *did* post always counts, even if the CLI also exited non-zero.

### Aggregation (unanimous PASS)

`lib-review-aggregate.sh::_aggregate_review_verdicts` collapses the per-agent outcomes:
- PASS iff ≥1 deciding agent AND every deciding agent passed;
- any deciding FAIL → FAIL — including a `timed-out` veto ([INV-48](invariants.md#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto): an agent killed by the review cap with no verdict is deciding, not dropped);
- zero deciding agents (all `unavailable`) → `all-unavailable` (a `timed-out` agent is deciding, so a round with any `timed-out` agent is `fail`, never `all-unavailable`).

The aggregate maps onto the existing `PASSED_VERDICT` / `LATEST_COMMENT` / `AGENT_EXIT` variables, so the downstream PASS / FAIL / crash branches run UNCHANGED — exactly one aggregated INV-35 verdict trailer and one INV-04 Reviewed-HEAD trailer per run. `all-unavailable` sets `LATEST_COMMENT=""` and falls back to the single-agent FAIL path, preserving the legacy `AGENT_EXIT` distinction so N=1 is byte-for-byte: `AGENT_EXIT=1` when any agent's CLI actually crashed (rc ≠ 0) → crash-fallback comment + `failed-non-substantive other`; `AGENT_EXIT=0` when every agent exited cleanly but posted no verdict → no crash comment + `failed-substantive`. On *partial* unavailability the wrapper posts one human-visible summary comment (dropped vs. deciding agents) and logs a WARN, then decides on the deciding agents.

## Prompt construction

The prompt encodes the entire review procedure as numbered steps. The wrapper does NOT execute any of those steps itself — they're all instructions to the underlying agent. The wrapper's job is to construct the prompt (per agent via `build_review_prompt <name> <session-id>`), kick off the agent(s), and parse the verdict(s).

Major prompt sections:

| Section | Purpose |
|---|---|
| **Step 0: merge-conflict resolution** | Mandatory pre-review. `gh pr view --json mergeable` ⇒ proceed (`MERGEABLE`), rebase (`CONFLICTING`), wait+retry (`UNKNOWN`). On rebase failure the agent FAILs with "[BLOCKING] Merge conflict with main" and step-by-step rebase instructions. |
| **Step 0.5: requirement drift detection** | Read all issue comments before reading the PR diff. Find scope changes posted after implementation began. Drift ⇒ FAIL with "[BLOCKING] Requirement drift". |
| **Review checklist** | Process compliance, code quality, testing, infra. The Kiro path skips `code-simplifier` / `pr-review` items since Kiro doesn't support those. |
| **Acceptance criteria verification** | For each `## Acceptance Criteria` checkbox in the issue body, verify against PR code/tests/build then mark via `bash scripts/mark-issue-checkbox.sh`. ALL must be checked before approving. |
| **Amazon Q Developer trigger** | Mandatory bot-review trigger. Q ignores `/q review` from bot accounts ⇒ wrapper instructs the agent to use `bash scripts/gh-as-user.sh pr comment N --body "/q review"`. Poll up to 3 min for the bot to respond. |
| **E2E verification (if `E2E_MODE` ∈ {browser, command})** | Branch on `E2E_MODE`. `browser`: Chrome DevTools MCP procedure (navigate, login, execute happy-path + feature test cases, screenshot+upload each, post structured E2E report on PR). `command`: invoke project-supplied `E2E_COMMAND`, run `E2E_COMMAND_EVIDENCE_PARSER`, post evidence block ending with SHA-bound marker `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->` as PR comment. See **E2E mode dispatch** above. |
| **Decision** | PASS ⇒ post "Review PASSED ..." on the **issue** (not PR). FAIL ⇒ post "Review findings: ..." with numbered remediation list. Either way the comment ends with BOTH a `Review Session: \`<id>\`` trailer AND a `Review Agent: <name>` discriminator line ([INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)) — the latter lets the wrapper attribute N verdicts posted under one GitHub identity. |

The `Review Session:` trailer (presence) + the `Review Agent: <name>` discriminator (per-agent) are how the wrapper identifies which comment is each agent's verdict — see [Verdict polling](#verdict-polling) below.

## Verdict polling

After the agent exits, the wrapper polls issue comments looking for a comment that satisfies all applicable predicates. The loop body lives in `lib-review-poll.sh::_run_verdict_poll_loop` (extracted so the round-by-round behavior is unit-testable, #180); the wrapper resolves the budget, declares the verdict arrays, calls it, then runs the post-window sweep. The poll budget is **command-mode-aware ([INV-43](invariants.md#inv-43-command-mode-e2e-review-wait-budgets-must-not-be-smaller-than-the-e2e-they-dispatched), #172)**: `lib-review-poll.sh::_resolve_verdict_poll_attempts` returns the legacy `6` attempts (5s interval = 30s window) for every non-`command` mode, and `max(6, ceil(E2E_COMMAND_TIMEOUT_SECONDS/5))` when `E2E_MODE=command` — so a review agent that faithfully runs a slow command-mode E2E (and posts its verdict only after it finishes) is not dropped as `unavailable` for taking as long as the E2E it was asked to run. The loop still **early-exits** once every agent has a verdict, so the happy path settles in one round (~5s) regardless of budget.

**No early non-zero-rc drop ([INV-43](invariants.md#inv-43-command-mode-e2e-review-wait-budgets-must-not-be-smaller-than-the-e2e-they-dispatched) sub-rule 1b, #180)**: because the poll loop runs *after* the fan-out `wait`, every agent's CLI has already exited and `AGENT_LAUNCH_RC` is fully populated before round 1. A non-zero CLI exit therefore must NOT, by itself, drop an agent while the window is still open — the verify command can exit non-zero on a soft path, or the CLI can exit non-zero just after the agent posted its `Review PASSED` verdict, or the verdict comment is still propagating. The per-round decision is made by the pure `lib-review-poll.sh::_classify_unresolved_agent <body> <rc>`: a matched verdict **wins over the launch rc** (classified FAIL-first); an agent with no verdict keeps being polled **regardless of rc** for the full INV-43-scaled budget — there is no separate post-exit grace timer (#180 Fix 2: the scaled window IS the propagation grace). Only the wrapper's post-window sweep resolves a still-no-verdict agent to `unavailable`. This pre-#180 short-circuit was a LATENT defect (every captured field drop was actually the sub-rule-1 timing bug, rc 0); the fix is proactive, proven by the loop regression test. The candidate comment must satisfy all applicable predicates:

- Body matches a verdict phrasing (case-insensitive). The supported set was broadened in #95 to handle agent phrasing drift:
  - **Pass-side**: `Review PASSED`, `Review APPROVED`, `APPROVED FOR MERGE`, `LGTM`, `Review PASS`.
  - **Fail-side**: `Review findings:`, `Review FAILED`, `Review REJECTED`, `Changes requested`.
- Authenticity binding — three layers, all required (primary path):
  - **Actor**: `author.login == BOT_LOGIN`. The wrapper resolves `BOT_LOGIN` once at startup via `gh api user --jq .login`. In `GH_AUTH_MODE=app` the dev and review wrappers authenticate as distinct GitHub Apps, so the actor predicate alone separates them.
  - **Time window**: `createdAt >= WRAPPER_START_TS`. Captured before `run_agent` in ISO-8601 UTC. Excludes stale verdict comments left by a prior tick.
  - **Body trailer presence**: body matches `/Review Session/`. Note: the trailer's UUID is NOT bound to the wrapper's `SESSION_ID` — only the trailer's presence is checked. This eliminates a long-standing brittleness where the agent occasionally rewrote the UUID and broke the regex match. The trailer requirement is load-bearing in `GH_AUTH_MODE=token`, where dev and review wrappers share `BOT_LOGIN`: only the review agent's prompt instructs it to emit `Review Session:`, so the trailer excludes the dev agent's status comments that contain a verdict keyword as quoted history.

Fallback path: if `gh api user` fails at startup (returns empty, errors out, or returns the literal string `"null"` from a misconfigured GitHub App), `BOT_LOGIN` is treated as unset and the predicate becomes `createdAt >= WRAPPER_START_TS AND body matches Review Session.*<SESSION_ID>`. This restores the prior brittleness (agent must echo the wrapper's UUID) only on the rare path where actor binding is unavailable.

**Per-agent discriminator ([INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback), #166)**: with multi-agent fan-out, all N agents post under the same identity, so the three predicates above match all N verdicts and `last` would pick one arbitrarily. The wrapper therefore runs ONE query **per agent**, adding a fourth predicate `body matches /Review Agent: <name>/` and taking `last` per agent. In the `BOT_LOGIN`-empty fallback the per-agent UUID (`Review Session.*<that-agent's-session-id>`) is the narrowing key. For N=1 this is the lone agent's discriminator — identical routing to the pre-#166 single query. See [Multi-agent fan-out](#multi-agent-fan-out-inv-40) above.

If polling completes (the full INV-43-scaled budget is exhausted) without finding a verdict comment for an agent — whether its CLI exited clean or non-zero — that agent is treated as **unavailable** (dropped from the vote) by the post-window sweep. If NO agent yields a verdict, the wrapper proceeds to the FAIL branch via the all-unavailable crash fallback (no false-positive PASS); that fallback's crash-vs-no-verdict discriminator (`AGENT_LAUNCH_RC != 0` → `AGENT_EXIT=1`) is a **separate** check from the poll loop and is unchanged by #180.

### Pass-vs-fail classification

Once polling finds a candidate comment, the wrapper applies a two-step classification (#95 — was previously a brittle `head -1 | grep -qi "^Review PASSED"` check that missed "APPROVED FOR MERGE" and similar drift):

1. **FAIL pattern first** (`Review FAILED|Review REJECTED|Review findings:|Changes requested`) — if any matches, classify as FAIL. Conservative on ambiguity: a comment containing both "LGTM" and "Review findings:" routes to FAIL since the agent flagged at least one issue.
2. **PASS pattern next** (`Review PASSED|Review APPROVED|APPROVED FOR MERGE|LGTM|Review PASS`) — if any matches and no FAIL phrasing did, classify as PASS.
3. Otherwise FAIL by default.

The classification scans the entire body, not just the first line, because some agents emit a heading (`## Review Verdict`) on line 1 and the verdict on line 2.

## Reviewed HEAD trailer

Posted as a separate comment, exactly once, only when:

- A verdict comment was found in polling AND
- `PR_HEAD_SHA` (captured at prompt-build time) is non-empty.

Format ([INV-04](invariants.md#inv-04-reviewed-head-trailer-format)):
```
Reviewed HEAD: `<sha>` (issue #N, session `<id>`)
```

The dispatcher's Step 5b reads the most recent trailer matching `Reviewed HEAD: \`<sha>\`` and compares it to the current `PR.headRefOid`. If they match, the dispatcher sends the issue back to `pending-dev` ("no new commits since last review") instead of bouncing it through review again — see [`dispatcher-flow.md` § Step 5b in-progress](dispatcher-flow.md#dead--in-progress) and [#53](https://github.com/zxkane/autonomous-dev-team/issues/53).

If the trailer post fails (token expiry, 403, rate limit), the wrapper logs `WARNING: Failed to post Reviewed HEAD trailer` and continues — the failed trailer means the dispatcher cannot detect SHA-match, but the empty-trailer fallthrough routes to `pending-review` ([INV-07](invariants.md#inv-07-empty-reviewed-head-trailer-routes-to-pending-review)) which is the safe default.

## PR-open guard (INV-54)

The **first** thing the `PASSED_VERDICT == true` chain does — before the mergeable gate, before any FAIL-branch label flip — is a single PR-still-open check ([INV-54](invariants.md#inv-54-the-pr-still-open-guard-gates-all-pass-chain-exits-not-just-pass)). The check used to live only in the PASS path (step 1 below), AFTER the mergeable gate, so a PR merged out-of-band (manual merge, or the #191 agent self-merge) that then took an INV-44 block branch flipped its already-closed issue to `pending-dev`. Hoisting it makes all three PASS-chain exits (block-substantive, block-nonsubstantive, PASS) honor it with one query.

```
if PASSED_VERDICT == true:
  PR_STATE = gh pr view --json state  (failed query → "UNKNOWN" sentinel)
  if _pr_open_gate "$PR_STATE" == "skip":     # lib-review-mergeable.sh
      # PR no longer OPEN — merged/closed out-of-band, or state in doubt
      −reviewing  (NO +pending-dev) ; exit 0
  # else proceed → mergeable gate + PASS path below
```

- The ONLY value that proceeds is a case-insensitive `OPEN` — the exact inverse of the old PASS-branch `!= OPEN` test. `MERGED`/`CLOSED`/`UNKNOWN`/empty/any other token → `skip` → clean `−reviewing` exit, never `+pending-dev`. Fail-closed toward "do not re-queue dev on a merged PR".
- DRY: the hoisted check **replaces** the old PASS-branch duplicate (step 1 below is now a no-op — by the time the PASS path runs, the PR is guaranteed open). Exactly one `gh pr view --json state` call remains; net `gh` calls on the PASS path are unchanged.

## Mergeable hard gate (INV-44)

After the PR-open guard ([INV-54](invariants.md#inv-54-the-pr-still-open-guard-gates-all-pass-chain-exits-not-just-pass)) confirms the PR is OPEN, and **before** the wrapper acts on the PASS, a wrapper-enforced gate re-checks the PR's `mergeable` status — so a CONFLICTING PR can never reach `approved`, regardless of whether the review agent ran its Step-0 pre-review rebase prompt ([INV-44](invariants.md#inv-44-mergeable-hard-gate--a-conflicting-pr-can-never-reach-approved)). This is the mechanical counterpart to the agent's best-effort Step 0; the prompt step still rebases clean conflicts up-front, the gate is the safety net for when it is skipped.

```
if PASSED_VERDICT == true:
  # (PR-open guard already ran here — see § PR-open guard (INV-54))
  MERGEABLE_STATUS = poll `gh pr view --json mergeable` while UNKNOWN/empty,
                     up to MERGEABLE_RETRIES (default 3, 10s apart)
  gate = _classify_mergeable_gate "$MERGEABLE_STATUS"   # lib-review-mergeable.sh
    MERGEABLE   → proceed → fall through to the PASS path below (UNCHANGED)
    CONFLICTING → block-substantive:
        issue comment "Review findings: ... [BLOCKING] Merge conflict with main ... rebase steps"
        PR    comment "Auto-merge failed: PR is CONFLICTING ... Re-dispatching dev agent to rebase onto main."
        emit_verdict_trailer failed-substantive
        submit_request_changes <PR> "<merge-conflict body>"  # INV-52, best-effort (CONFLICTING is substantive)
        −reviewing +pending-dev ; exit 0
    UNKNOWN/empty/other → block-nonsubstantive:
        issue comment "Review held: mergeable is UNKNOWN ... will be re-reviewed next tick"
        emit_verdict_trailer failed-non-substantive cause=mergeable-unknown
        −reviewing +pending-dev ; exit 0
```

- The ONLY value that proceeds is a case-insensitive `MERGEABLE`. An empty string (failed `gh` call), a literal `UNKNOWN` that survived the retry budget, or any unexpected token all **block** — fail-closed. This closes the stale-`UNKNOWN` pass-through (the prior prompt-side "after 3 retries treat as MERGEABLE" shortcut).
- **CONFLICTING** reuses the `Auto-merge failed:` PR marker so the dev-resume branch ([§ Auto-merge failure → dev re-dispatch](#auto-merge-failure--dev-re-dispatch-inv-33)) prepends its mandatory rebase pre-step — giving the conflict a deterministic owner. It is a substantive blocking finding, so the wrapper also submits `--request-changes` ([INV-52](invariants.md#inv-52-the-review-wrapper-owns-the-github-native-pr-reviewmerge-action-the-agent-posts-verdicts-only); `reviewDecision=CHANGES_REQUESTED`).
- **UNKNOWN** posts no PR marker (no confirmed conflict ⇒ no forced rebase) and does NOT submit `--request-changes` ([INV-52](invariants.md#inv-52-the-review-wrapper-owns-the-github-native-pr-reviewmerge-action-the-agent-posts-verdicts-only): a transient re-queue is not a dev-actionable blocking finding); the `failed-non-substantive` trailer makes the dispatcher flip the issue back to `pending-review` (re-review) under the `REVIEW_RETRY_LIMIT` cap ([INV-35](invariants.md#inv-35-review-aware-resume-routing-for-completed-sessions)).
- Happy path (`MERGEABLE`) is byte-for-byte today's behavior plus one `gh pr view --json mergeable` call.

## Verdict = PASS path

```
1. (PR-open guard already ran at the top of the gate chain — INV-54.
    The PR is guaranteed OPEN here; no re-query.)
2. refresh_token_env (token may have expired during the review)
3. gh pr review --approve --body "All acceptance criteria verified. ..."
   (INV-52: a fresh APPROVE on the current HEAD supersedes any prior
    CHANGES_REQUESTED this reviewer left on an earlier round.)
   if approve fails (permission issue):
     comment "Review PASSED but formal PR approval failed... please approve and merge manually"
     −reviewing +approved
     exit 0
4. Read no-auto-close label
   if no-auto-close set:
     comment "Review PASSED — this issue has the 'no-auto-close' label..."
     −reviewing +approved (autonomous and no-auto-close kept)
   else (auto-merge path):
     MERGE_OUT=$(gh pr merge --squash --delete-branch 2>&1); MERGE_RC=$?
     if MERGE_RC == 0:
       −autonomous −reviewing +approved
       (issue auto-closes via GitHub's `Closes #N` resolution — wrapper does NOT call `gh issue close`, INV-33)
     else (auto-merge failed — INV-33):
       PR comment "Auto-merge failed: <stderr-excerpt>. Re-dispatching dev agent to rebase onto main."
       −reviewing +pending-dev (autonomous retained)
       (next dispatcher tick re-dispatches dev; dev resume detects the marker and rebases first)
```

### Auto-merge failure → dev re-dispatch (INV-33)

When `gh pr merge` returns non-zero, the wrapper:

1. Captures `MERGE_OUT` (combined stdout+stderr, truncated to 500 chars for the comment).
2. Posts a comment on the **PR** (not the issue) with prefix `Auto-merge failed:` followed by the captured excerpt and the directive `Re-dispatching dev agent to rebase onto main.`
3. Does NOT call `gh issue close`. Does NOT add `+approved`. Does NOT remove `autonomous` (the dispatcher's `list_pending_dev` selector gates on `autonomous`).
4. Edits the issue: `−reviewing +pending-dev`.

The dev wrapper's resume branch detects the marker by querying PR-issue comments for one whose body starts with `Auto-merge failed:`, and prepends a `## Pre-implementation: rebase` section to the resume prompt instructing `git fetch origin && git rebase origin/main && git push --force-with-lease`. Once the rebase succeeds, the dev wrapper trap transitions back to `+pending-review`, the next dispatcher tick re-dispatches review, and the merge succeeds — at which point GitHub closes the issue via the PR's `Closes #N` keyword.

If the rebase has unresolvable conflicts, the dev agent posts a `needs human` comment and exits cleanly. The dispatcher's MAX_RETRIES gate eventually transitions the issue to `stalled` if the loop fails to converge.

### Approval guard (`PR.state != OPEN`) — now the hoisted PR-open guard (INV-54)

A maintainer running `/q review` plus a manual `gh pr merge` while the autonomous review wrapper is in flight can cause the PR to be merged before the wrapper reaches the approve step. Without the guard, `gh pr review --approve` against a closed PR would fail noisily and the wrapper would fall into the approval-failure branch — incorrect, since the PR was already approved+merged by the human. The guard short-circuits to a silent `−reviewing` (no add) and exit 0.

Since [INV-54](invariants.md#inv-54-the-pr-still-open-guard-gates-all-pass-chain-exits-not-just-pass) (#196) this guard is **hoisted to the top of the `PASSED_VERDICT == true` chain** (see [§ PR-open guard (INV-54)](#pr-open-guard-inv-54)) so it also protects the INV-44 block-substantive / block-nonsubstantive branches — not just the approve/merge path. The old in-PASS-branch copy was removed (DRY). The original concurrent-merge motivation is unchanged. See [`state-machine.md` § Concurrent reviews on the same PR](state-machine.md#concurrent-reviews-on-the-same-pr) and [#31](https://github.com/zxkane/autonomous-dev-team/issues/31).

## Verdict = FAIL or missing path

```
1. If agent exit ≠ 0 AND no verdict comment was found (NON-substantive crash):
     post "Review process encountered an error (agent exit code: N). Moving back to development for investigation."
     emit_verdict_trailer failed-non-substantive other
   (This is the only fallback comment; if a verdict was posted but agent exited non-zero, the verdict already says everything.)
   else (SUBSTANTIVE — agent posted a FAIL verdict comment):
     emit_verdict_trailer failed-substantive
     submit_request_changes <PR> "<body linking the Review findings: comment>"   # INV-52, best-effort
2. −reviewing +pending-dev
```

**REQUEST_CHANGES on a substantive FAIL ([INV-52](invariants.md#inv-52-the-review-wrapper-owns-the-github-native-pr-reviewmerge-action-the-agent-posts-verdicts-only))**: when the agent posted a blocking FAIL verdict, the wrapper additionally submits `gh pr review --request-changes` (via `lib-review-request-changes.sh::submit_request_changes`) so the PR's GitHub-native `reviewDecision` becomes `CHANGES_REQUESTED` — authoritative for humans browsing the PR, branch protection, and the dev-resume agent (closing the false-green-PR gap behind #188). The call is **best-effort**: `submit_request_changes` always returns 0, a 403/transient `gh` failure is logged and swallowed, and the call site adds a belt-and-suspenders `|| log` — a failed submit MUST NOT abort the FAIL route and strand the issue in `reviewing`. The **non-substantive** sub-path (agent crash, no verdict) does NOT request changes: a transport failure is not a dev-actionable blocking finding, and a standing `CHANGES_REQUESTED` would falsely accuse the dev. There are **three** substantive routes that request changes, each a real dev-actionable blocking FAIL: (1) the agent-posted `Review findings:` FAIL here, (2) the mergeable-gate's `block-substantive` (CONFLICTING) path, and (3) the [INV-46](invariants.md#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) E2E hard-gate `fail` path (which runs before the fan-out). Their non-substantive siblings — `block-nonsubstantive` (mergeable UNKNOWN re-queue) and the E2E `block-nonsubstantive` (evidence-missing re-queue) — do NOT — see [Mergeable hard gate](#mergeable-hard-gate-inv-44) and [Sequential E2E lane (INV-46)](#sequential-e2e-lane-inv-46).

A subsequent PASS re-approves the new HEAD: the [PASS path](#verdict--pass-path) submits `gh pr review --approve` against the post-fix HEAD, which supersedes the prior `CHANGES_REQUESTED` from the same reviewer (and `dismiss-stale-reviews-on-push` branch protection, if configured, dismisses it on the dev's force-push) — so there is no permanently-stuck `CHANGES_REQUESTED`.

The next dispatcher tick's Step 4 will pick the issue up. Crucially, this `pending-dev` does NOT count toward the dispatcher's retry counter — only `Agent Session Report (Dev)` failures and the dispatcher's own crash-regex matches do ([INV-05](invariants.md#inv-05-retry-counter-cutoff-rule), [INV-06](invariants.md#inv-06-crashed--process-not-found-keyword-contract)).

## Exit trap (`cleanup`)

Different from the dev wrapper's trap — this one's contract is **only** to handle the case where the wrapper crashed *before* the result-parsing block ran. The trap uses `RESULT_PARSED=true` (set on the last line of the script) as the signal that the verdict-handling code already updated labels and the trap should do nothing label-related.

```mermaid
flowchart TD
    enter([trap fires<br/>exit_code captured]) --> rm_pid[rm -f PID_FILE]
    rm_pid --> parsed{RESULT_PARSED?}
    parsed -- true --> auth_done[cleanup_github_auth]
    auth_done --> done([exit])

    parsed -- false --> exit_branch{exit_code != 0?}
    exit_branch -- no --> auth_done
    exit_branch -- yes --> refresh[refresh GH App token]
    refresh --> crash_comment[comment 'Review process crashed exit N']
    crash_comment --> to_dev[remove reviewing<br/>add pending-dev]
    to_dev --> auth_done
```

This means if the script exits 0 (normal completion) but `RESULT_PARSED` was never set (logic bug), the trap silently leaves labels alone — defense-in-depth against a future refactor that forgets to set the flag would manifest as "issue stuck in `reviewing`" rather than "issue corrupted to `pending-dev` for no reason".

## Cross-references

- [`dispatcher-flow.md`](dispatcher-flow.md) — Step 3 is the producer side of the dispatcher → review handoff.
- [`dev-agent-flow.md`](dev-agent-flow.md) — the consumer of the `pending-dev` label this wrapper sets on FAIL.
- [`handoffs.md`](handoffs.md) — invariants for review → approved and review → pending-dev.
- [`invariants.md`](invariants.md) — INV-01, INV-04, INV-05, INV-06, INV-07, INV-08 are all referenced here.
