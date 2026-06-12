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
    opt REVIEW_SMOKE_ENABLED (Phase A.5, INV-64)
        W->>L: smoke_agent per REVIEW_AGENTS_LIST member (parallel)
        alt any member FAIL
            W->>GH: comment 'Review aborted: smoke FAILED' + emit trailer
            Note over W,GH: stays reviewing; RESULT_PARSED=true; exit 1 (self-heals next tick)
        else some/all UNAVAILABLE
            W->>W: drop UNAVAILABLE members (smoke: reason); all → all-unavailable
        end
    end
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
  gate in {fail, block-nonsubstantive} → PR-OPEN GUARD FIRST (INV-54 ext, #195):
                                 E2E_PR_STATE = gh pr view --json state
                                 if _pr_open_gate "$E2E_PR_STATE" == "skip":
                                   # merged/closed WHILE the E2E lane ran
                                   −reviewing (NO +pending-dev) ; exit 0
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
- **PR-open guard on the block exits ([INV-54](invariants.md#inv-54-the-pr-still-open-guard-gates-all-pass-chain-exits-not-just-pass) extension, #195).** A `fail`/`block-nonsubstantive` gate re-checks `gh pr view --json state` (via the reused `_pr_open_gate` helper) before writing `−reviewing +pending-dev`; if the PR was merged/closed WHILE the lane ran, it removes `reviewing` only and exits — never re-queues a merged PR's issue to `pending-dev`. The check is wedged after `_classify_e2e_gate` and before the block cascade, so the `pass`/`inactive` fall-through is unaffected. See [§ PR-open guard (INV-54)](#pr-open-guard-inv-54).

## Pre-fan-out agent-smoke gate (Phase A.5, INV-64)

When `REVIEW_SMOKE_ENABLED=true`, the wrapper runs a **pre-fan-out agent-smoke gate** in a dedicated Phase A.5 — AFTER the [INV-46](invariants.md#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) E2E lane (Phase A) and BEFORE the review fan-out (Phase B). It smokes EVERY `REVIEW_AGENTS_LIST` member via [INV-63](invariants.md#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path)'s `lib-agent-smoke.sh::smoke_agent` and applies three-state semantics. Default OFF — opt in per project; with it off the wrapper is byte-for-byte unchanged. See [INV-64](invariants.md#inv-64-the-review-wrapper-smokes-every-fan-out-member-before-the-fan-out-phase-a5-fail-aborts-the-review-unavailable-drops-the-member-pass-proceeds).

```
        E2E gate == pass (Phase A) ──┐
                                     ▼
   Phase A.5: smoke each REVIEW_AGENTS_LIST member IN PARALLEL
   (resolved per-agent model [INV-41] + INV-38/INV-42 launcher;
    collected-PID wait, never bare wait — #167-class hang)
                                     │
   ┌─────────────────────┬──────────┴───────────────┬───────────────────────┐
   │ any member FAIL      │ some/all UNAVAILABLE       │ all PASS              │
   │ (smoke rc 1)         │ (smoke rc 2)               │ (smoke rc 0)          │
   ▼                      ▼                            ▼                       │
 ABORT review:          drop UNAVAILABLE members      fan out all members     │
 post naming comment    (drop reason `smoke: …`,                              │
 + SMOKE evidence;      INV-40 unavailable tolerance);                        │
 emit failed-non-       remaining members fan out;                            │
 substantive trailer    ALL unavailable → list                               │
 (cause smoke-config-   UNCHANGED, falls through to                          │
 error); RESULT_PARSED  the INV-40 all-unavailable                            │
 =true (crash trap not  terminal state                                       │
 overriding); stays                                                          │
 `reviewing`; exit 1                                                         │
```

- **FAIL = config error, not a PR defect.** A smoke FAIL (wrong model id / expired auth / region drift / a launcher that does not fit the CLI) aborts the whole review: no fan-out, no verdict, the issue stays `reviewing`, and the wrapper exits non-zero after posting a comment naming the failed agent(s) + their `SMOKE …` evidence. It does NOT flip to `pending-dev` (that would send dev chasing a non-existent PR problem) and does NOT shrink the vote (that would disguise the config error as a quota wall). It sets `RESULT_PARSED=true` so the crash EXIT trap does not override the stay-`reviewing` decision, and emits a `failed-non-substantive` trailer (cause `smoke-config-error`) — a heartbeat-consistent exit so [INV-24](invariants.md#inv-24-review-wrapper-dead-detection-requires-both-pid_alive-miss-and-no-near-success-pr-signal) does not false-DEAD mid-abort. The dispatcher re-runs the review on the next tick → self-heals once the operator fixes the config.
- **UNAVAILABLE = quota/capacity, fine to drop.** An UNAVAILABLE member is removed from the fan-out set with a `smoke: <reason>` breadcrumb (the same INV-40 `unavailable` tolerance); the rest fan out and vote. ALL members UNAVAILABLE → the list is left UNCHANGED and falls through to the existing INV-40 all-unavailable terminal state (no empty fan-out spawned). A single-agent project whose one member is UNAVAILABLE reaches this same state; a single-agent FAIL aborts as above.
- **Same launch path as the fan-out.** The smoke resolves each member's model (`_resolve_review_agent_model`, INV-41) and applies the INV-38/INV-42 launcher treatment — identical to the fan-out subshell — so a smoke PASS certifies the same `(CLI, model, launcher)` tuple the fan-out runs.
- **Strictly before the fan-out clock.** Phase A.5 posts no verdict comment, so it counts toward neither the INV-40 verdict-attribution window nor the verdict-poll window. Cost when enabled: N small LLM calls + up to ~`REVIEW_SMOKE_TIMEOUT_SECONDS` wall-clock (parallel, slowest member).

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
- **resolves its OWN model + extra-args** ([INV-41](invariants.md#inv-41-per-agent-review-model--extra-args-resolution), #168) via `lib-review-resolve.sh`: `_resolve_review_agent_model "$agent"` looks up `AGENT_REVIEW_MODEL_<SUFFIX>` (suffix = uppercased name, every char outside `[A-Z0-9]`→`_`) else the shared `AGENT_REVIEW_MODEL`, and the resolved value is passed to `run_agent` as `"${_agent_model:-sonnet}"`; `_resolve_review_agent_extra_args "$agent"` looks up `AGENT_REVIEW_EXTRA_ARGS_<SUFFIX>` else the shared `AGENT_REVIEW_EXTRA_ARGS`, resolved **once** into `_resolved_review_extra_args` and aliased onto **both** `AGENT_DEV_EXTRA_ARGS` (read by `run_agent`, turn 1; ALSO the var `lib-review-codex.sh::_codex_review_argv` reads for the `codex review` lane — [INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback)) **and** `AGENT_REVIEW_EXTRA_ARGS` (the var `resume_agent` reads), so the per-agent override reaches whichever launch path the CLI takes (#212). The dual alias is kept as belt-and-suspenders even though [INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) retired the codex resume path (`codex review` is multi-step and never resumes): no review CLI resumes any more, so the `AGENT_REVIEW_EXTRA_ARGS` alias is harmless and guards any future resume caller. Both lookups are scoped to this subshell (the `AGENT_REVIEW_EXTRA_ARGS` write does not leak to the parent loop or a sibling agent). With no per-agent key set, both resolve to the shared values, so the model arg is identical to the legacy `${AGENT_REVIEW_MODEL:-sonnet}` and the N=1 path is byte-for-byte legacy. This lets a mixed `"kiro <claude-fam>"` fleet give kiro `claude-sonnet-4.6` and the claude-family agent `sonnet[1m]` — two model ids each CLI would reject if forced to share one;
- writes to its OWN log `/tmp/agent-${PROJECT_ID}-review-${N}-${agent}.log`;
- builds its prompt via `build_review_prompt "$agent" "$SESSION_ID"` and records its CLI exit code to a per-run sidecar (a subshell can't mutate the parent's variables);
- **dispatches via the right agent-launch path for its CLI**: a `codex` agent goes through `lib-review-codex.sh::_run_codex_review` (the `codex review` subcommand + bounded re-run, [INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback)); every other CLI calls `run_agent` directly — byte-for-byte the legacy invocation. See [codex review subcommand (INV-62)](#codex-review-subcommand-inv-62) below.

The fan-out loop appends each subshell's PID (`$!`) to a `_fanout_pids` array and the wrapper joins with `wait "${_fanout_pids[@]}"` — the **collected PIDs only**. A bare `wait` is forbidden here: it would also block on the long-lived `gh-token-refresh-daemon` and the heartbeat `sleep` loop (neither exits), hanging the wrapper forever after the agents finish and stranding the issue in `reviewing`. See [INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) sub-rule 1.

### codex review subcommand (INV-62)

> **History.** Before [INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) (#218) the codex review member ran `codex exec` (one agentic turn) + a JSONL-driven auto-resume loop ([INV-51](invariants.md#inv-51-codex-review-thread-auto-resumes-until-a-verdict-posting-turn)) + an inline-diff prompt ([INV-55](invariants.md#inv-55-the-codex-review-lane-receives-the-pr-diff-inline-in-its-prompt)) to coax that one turn into a verdict. That machinery was the root cause of a recurring bug class (#198 / #209 / #212). It is **all deleted** — moving to the purpose-built `codex review` subcommand removes the machinery and the bug class together.

`codex review "<prompt>"` is purpose-built for reviewing a PR: it is natively **multi-step** (it fetches and re-reads the diff across turns without a single-turn budget) and **auto-scopes** the diff against the **current working tree's** merge-base. So a `codex` fan-out member is dispatched through `lib-review-codex.sh::_run_codex_review` instead of a bare `run_agent` ([INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback)). The launch path:

1. **establishes the PR-branch context** (`_codex_review_prepare_worktree "$PR_BRANCH" <dest>`, #218 findings 3 + 1 + stale-ref): because `codex review` has no `--base`/PR-number flag and scopes against the **current checkout**, and the wrapper runs from `PROJECT_DIR` (kept on `main` by the dispatcher), the codex branch `git worktree add --detach`s the PR tip into a throwaway, session-id-keyed dir — then runs `codex review` FROM that worktree (a subshell `cd`, so the wrapper's cwd is untouched). This is the scoping the deleted INV-55 path got via `gh pr diff <PR_NUMBER>`. **Stale-proof tip resolution**: when an `origin` remote exists, the fetch is MANDATORY (`git fetch origin <branch>` MUST succeed) and the checkout commit is `FETCH_HEAD` (the tip fetched NOW) — NOT `origin/<branch>`, which the targeted fetch may leave stale absent a refspec; no `origin` → a local ref. The worktree is torn down (`_codex_review_cleanup_worktree`, rc-0-always) regardless of rc. **FAIL CLOSED (finding 1)**: if preparation fails (no `PR_BRANCH`, a fetch failure when a remote exists, or an add error), the wrapper does NOT run a vote-producing `codex review` from `PROJECT_DIR` — it skips the run and sets the `CODEX_REVIEW_NO_WORKTREE_RC` (70) sentinel rc so codex resolves `unavailable` (dropped, never a vote on a stale / `main`'s wrong / empty diff). (`_run_codex_review`'s own empty-workdir → degrade-to-cwd+warn path stays as a lib-level defense-in-depth fallback, but the wrapper gates the call behind `_cx_wt_ready` and never reaches it.);
2. **builds the argv** (`_codex_review_argv`): `review "<prompt>" -c 'model="<resolved-model>"' <extra-args>`. The model is `-c 'model="..."'` because `codex review` **rejects `-m`**; there is **no `--base`** (`[PROMPT]` is mutually exclusive with `--base`/`--commit`, and auto-scope is what we want) and **no `--json`** (`codex review` output is human-readable text, not a JSONL event stream). The `<extra-args>` are the [INV-41](invariants.md#inv-41-per-agent-review-model--extra-args-resolution) per-agent resolved value (read from `AGENT_DEV_EXTRA_ARGS`), so `AGENT_REVIEW_EXTRA_ARGS_CODEX` reaches the argv — #212 stays fixed without a resume path;
3. **runs `codex review` once** from the PR-branch worktree under the shared `_run_with_timeout` (so the launcher / setsid / PGID-sidecar / per-run wall-clock cap all match `run_agent`), capturing codex's **clean stdout** (stderr folded in) to a per-agent file keyed by session id;
4. **re-runs on a transient (non-timeout) failure** (no resume exists — each run re-reads the diff fresh, re-using the same PR-branch worktree). A non-zero, **non-timeout** exit (a transient `turn.failed` / SSE stream blip — #209) re-runs a fresh `codex review`, bounded by `CODEX_REVIEW_MAX_RERUNS` (default 3; a non-numeric value degrades to the default, no `set -euo pipefail` abort) **AND** the `AGENT_REVIEW_TIMEOUT`-derived wall-clock deadline (`_codex_review_deadline_seconds`, clock seam `_codex_now_seconds`). The max-rerun bound is checked BEFORE the deadline so a `max=N` config does exactly N re-runs when time allows. The loop's break decision keys on the **last invocation's rc** (`last_run_rc`), not the sticky return value — it stops the instant a run exits `0`;
5. **a per-run timeout STOPS the loop immediately (zero further re-runs) and returns the INV-48 veto rc**: a `124`/`137` (per-run wall-clock cap TERM/SIGKILL) terminates the loop at once, and `_run_codex_review` returns that rc, so the post-window sweep maps a no-verdict 124/137 to `timed-out` (a deciding FAIL that VETOES the merge, [INV-48](invariants.md#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto)). The re-run loop is for transient stream errors, NOT the timeout cap: re-running a capped run is pointless (it refires) and — since each clean re-run could self-post — would risk DUPLICATE verdict comments (#218 finding 4). A non-timeout exhaustion returns the last rc → the poller resolves `unavailable`.

**Verdict capture is double-insured** ([INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) sub-rule 4):

- **(a)** the codex prompt (the codex branch of `build_review_prompt`) carries the decision-gate rules + the `Review PASSED` / `Review findings:` verdict format + the instruction to self-post via `bash scripts/post-verdict.sh` ([INV-56](invariants.md#inv-56-review-verdict-is-posted-via-the-deterministic-post-verdict-helper-not-the-agents-bare-gh)) — and tells codex it is running inside `codex review` (the diff is already scoped, do NOT re-run `git diff`/`gh pr diff`) and to mark blocking findings with `[P1]`. The inline diff is GONE — `codex review` fetches its own;
- **(b)** after the poll window, if a codex member that **exited rc 0** (the SOLE gate) produced stdout but **no** self-posted verdict landed, the wrapper classifies the stdout (`_codex_review_classify_stdout`: any `[P1]` → `fail`, else `pass` — the gate the manual `/codex review` skill uses), composes the canonical body (`_codex_review_compose_body`), and posts it via `post-verdict.sh` as agent `codex`, then re-polls. EVERY completed (rc 0) review posts exactly one verdict — an empty capture (→ default PASS body) and a capture whose text merely **mentions** the stream-error phrases (no `[P1]`) both post PASS. There is **no stream-error skip on the rc-0 path** (#218 finding 5): a genuine stream failure exits non-zero (filtered by the rc-0 gate → `unavailable` + the stream-error drop-reason), and `_codex_review_has_stream_error` is a broad substring scan that would false-positive on review TEXT about a stream error — so it gates only the drop-reason path, never the fallback;
- **(c)** the comment poller (`lib-review-poll.sh::_classify_verdict_body`) stays the **authoritative** verdict gate, unchanged.

The result: **exactly one** verdict comment per codex review — codex self-posted, OR the wrapper posted from parsed stdout — never zero, never two. The double-insurance is load-bearing because `codex review` has its own review-output orchestration and may not honor a "call post-verdict.sh" instruction as reliably as `codex exec` (a pure prompt executor) did. Scope is strictly `AGENT_CMD == codex`; the codex **dev** path stays on `codex exec` byte-for-byte and `lib-agent.sh` carries no `codex review` token — the review-only knowledge lives in `lib-review-codex.sh` so verdict/GitHub semantics never leak into the CLI-agnostic plumbing.

#### Fan-out model label (INV-58)

The `Fanning out N review agent(s): …` log line reports each agent's **per-agent RESOLVED** model — `lib-review-resolve.sh::_review_fanout_model_label` renders each agent through `_resolve_review_agent_model_label` (the honest display label over `_resolve_review_agent_model`, [INV-41](invariants.md#inv-41-per-agent-review-model--extra-args-resolution)) and prints `model: <id>` when uniform or `models: <agent>=<id>, …` when they diverge. Before [INV-58](invariants.md#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) this line printed `(shared model: ${AGENT_REVIEW_MODEL})`, which for a fleet with per-agent overrides (e.g. `AGENT_REVIEW_MODEL_AGY="Gemini 3.5 Flash (High)"`) misreported the model as the shared `sonnet` default and misled operators into suspecting a model-pin bug.

**agy label honesty (#220):** for an `agy` member whose resolved id is NOT an `agy models` id (e.g. the shared `claude-sonnet-4.6` with no `AGENT_REVIEW_MODEL_AGY` key), [INV-50](invariants.md#inv-50-agy---model-is-validated-against-agy-models-before-forwarding) drops that `--model` and agy runs its `settings.json` default — so the label renders `agy default (settings.json)` (or the generic `agy default` when `agy models` can't be enumerated), **not** the dropped id. A valid `AGENT_REVIEW_MODEL_AGY` is shown verbatim; claude/kiro/codex (which honor `--model`) are unchanged. This keeps the fan-out label honest about what agy *actually ran*, consistent with the INV-60 verdict comment and the INV-04 Reviewed-HEAD trailer (which route through the same helper). The helper is fail-safe under `set -euo pipefail` — it degrades to a generic `agy default` rather than ever asserting a wrong id.

### agy quota/auth drop reason (INV-58)

When a fan-out member whose CLI is `agy` exits, agy does NOT fail loudly: it returns **rc 0** even when it hit the Antigravity consumer **quota wall** (HTTP 429 `RESOURCE_EXHAUSTED`, "Individual quota reached") or an **auth failure** ("not logged into Antigravity"), with empty stdout/stderr and no verdict comment. The verdict poller therefore finds nothing and the post-window sweep resolves agy `unavailable` ([INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)) — but the 429 (and its `Resets in …` recovery window) lives only in agy's separate `--log-file`, so the operator sees a bare `unavailable` indistinguishable from a launch failure. On an `agy codex` AND-gate this silently degrades the fleet to codex-only with no visible cause.

[INV-58](invariants.md#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) closes that gap:

1. During fan-out the wrapper captures each agy member's `--log-file` path (`lib-agent.sh::_agy_log_file <session-id>`, deterministic from the session id) into `AGENT_AGY_LOGS`.
2. In the drop-classification loop, for any agent resolved `unavailable` whose CLI is `agy`, the wrapper calls `lib-review-agy.sh::_classify_agy_drop_reason <log>` (a `grep -F`, single-pass, jq-free, fail-safe scrape). It echoes `quota-exhausted[:Resets in <dur>]` for a 429/quota signal (the reset window appended when agy printed one), `auth-failed` for an auth/login signal with no quota signal (quota takes precedence — agy logs the OAuth failure as a side effect of the same quota-walled call), or empty when neither signal is present.
3. `_agy_drop_reason_phrase` renders the token into a human clause, which is appended to BOTH the `WARNING: review agent(s) dropped (unavailable)` log line + the posted "dropped (unavailable) agent(s)" issue comment (partial-unavailability path) and the `All N review agent(s) unavailable` log line (all-unavailable path).

This is **observability only** — it does NOT change the [INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) vote. A `quota-exhausted` / `auth-failed` agy is still DROPPED from the unanimous-PASS aggregation exactly as `unavailable` (a quota wall is an infra condition, not a code rejection; promoting it to a deciding FAIL would block every merge whenever agy's daily quota is spent). `_classify_noverdict_agent` / `_aggregate_review_verdicts` are untouched. Scope is strictly an `agy` member that was dropped; a non-agy drop or a signal-free agy log adds nothing and keeps the bare `unavailable` wording. The detector lives in a CLI-specific review-side lib (mirroring `lib-review-codex.sh`) so the CLI-agnostic `lib-agent.sh` never gains quota/GitHub knowledge.

### codex stream-error drop reason + retry (INV-59, re-scoped by INV-62)

> **Re-scoped by [INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) (#218).** The original [INV-59](invariants.md#inv-59-codex-transient-stream-error-drops-surface-a-distinct-reason-and-are-ridden-out-by-the-resume-loop-not-opaquely-dropped) read the `codex exec` JSONL `turn.failed` event and rode the blip out in the resume loop. `codex review` emits no JSONL stream and has no resume loop, so both halves are re-implemented: **the detector scans codex review's stdout/stderr capture** and **the retry is INV-62's bounded re-run**. The function names + the rc-0-always fail-safe contract are unchanged.

A codex review member's model stream can die with an **upstream server error** (HTTP 5xx — "The server had an error while processing your request"). codex's CLI retries the SSE stream up to `Reconnecting... 5/5`, then prints `stream disconnected before completion: ...` and exits non-zero with no verdict comment. Before INV-59 this was dropped as a bare, opaque `unavailable` (the drop-reason assembly enriched only `agy`, INV-58), and the launch early-returned so even a *brief* blip permanently cost codex its independent vote.

INV-59 (as re-scoped by INV-62) closes both gaps — the codex-shaped sibling of the agy detector above, for a transient stream 5xx instead of a quota wall:

1. **Retry (half 2) is INV-62's bounded re-run.** `_run_codex_review` re-runs a fresh `codex review` on any non-zero, non-`124`/`137` exit (a transient `turn.failed` / stream blip), bounded by `CODEX_REVIEW_MAX_RERUNS` + the `AGENT_REVIEW_TIMEOUT` wall-clock deadline. A **brief** blip is ridden out (the re-run succeeds → codex posts a verdict → its vote is kept); a **sustained** outage exhausts the re-run bound → codex resolved `unavailable` by the post-window sweep, gracefully degrading to the surviving fleet. There is no resume-loop "fall-through" any more — every non-timeout failure is simply re-run, so the old early-return distinction is moot. No new terminal `retryable` state and no dispatcher coordination — the re-run + timeout guards already bound "N pointless re-runs against a sustained outage".
2. **Drop reason (half 1, observability) scans the stdout capture.** During fan-out the wrapper captures each codex member's `codex review` **stdout-capture** path (the same file `_run_codex_review` writes, into `AGENT_CODEX_LOGS`). In the drop-classification loop, for any agent resolved `unavailable` whose CLI is `codex`, the wrapper calls `lib-review-codex.sh::_classify_codex_drop_reason <stdout-file>` (`_codex_review_has_stream_error` underneath; `grep -iE` for `stream disconnected before completion` or a `Reconnecting... N/M` ladder; no jq, fail-safe). It echoes `stream-error[:N/M]` for a stream error (the highest ladder depth appended when present), or empty when no stream-error signal — a clean review (with or without findings, incl. a genuine `[P1]`) yields empty, so the detector never over-claims (a real review is NOT a stream error). `_codex_drop_reason_phrase` renders the token into the human clause appended to the `WARNING: review agent(s) dropped (unavailable)` log line + the posted "dropped (unavailable) agent(s)" comment (and the all-unavailable `log` line). The classifier's `return 0`-always contract holds even for a BARE call under `set -euo pipefail`: the reconnect-ladder-depth extraction pipeline is `|| true`-guarded so a no-ladder capture (the inner grep matches nothing → rc 1 under `pipefail`) cannot abort the function body before its load-bearing `return 0`.

Like INV-58 this is **observability only** — a `stream-error` codex is still DROPPED from the [INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) aggregation exactly as `unavailable`, NOT a deciding FAIL (a server-side 5xx is an infra condition; promoting it to a veto would block merges whenever the provider blips). `_classify_noverdict_agent` / `_aggregate_review_verdicts` are untouched. The SAME drop-reason loop enriches agy (quota/auth), codex (stream-error / config-error), AND kiro (auth-failed) members in one fan-out, each with its own distinct clause. Scope is strictly a dropped `codex` member; a non-codex drop or a signal-free codex capture keeps the bare `unavailable` wording. Out of scope (per #209): codex's `stream_max_retries` (the `amazon-bedrock` provider takes no per-provider override), the upstream 5xx itself, and classifiers for other CLIs.

### codex config-error drop reason — deterministic argv rejection (INV-62 sub-rules 2 + 5b, #223)

A second codex-shaped no-verdict cause is **deterministic**, not transient: `_codex_review_argv` splices the [INV-41](invariants.md#inv-41-per-agent-review-model--extra-args-resolution)-resolved per-agent extra-args verbatim into the `codex review` argv, but `codex review` accepts only `-c/--config`, `--base`, `--commit`, `--uncommitted`, `--title`, `--enable`, `--disable` (0.137.0). A `codex exec`-era sandbox flag carried over the #218 migration — e.g. `AGENT_REVIEW_EXTRA_ARGS_CODEX="-s danger-full-access"`, valid+needed on the deleted `codex exec` lane — is rejected with an **exit-2 clap parse error** (`error: unexpected argument '-s' found`). Two separate gaps before #223:

1. **The re-run controller misread it as transient** and re-ran the identical argv to `CODEX_REVIEW_MAX_RERUNS` exhaustion, emitting the misleading "likely a transient stream error / turn.failed" line on every re-run — sending the operator chasing upstream/network issues instead of their own conf.
2. **The drop-reason scan had no bucket for it** — a clap usage block matched neither the stream-error phrases nor anything else, so the agent resolved as a bare opaque `unavailable` with no reason naming the flag. The fleet silently degraded to the surviving members on every fan-out.

#223 fixes both (the codex-shaped sibling of the stream-error split above, for an operator-conf error instead of an infra 5xx):

1. **Stop on the first run — gated on rc 2** ([INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) sub-rule 2). On a run that exits **rc 2** (clap's parse-error exit code), `_run_codex_review` scans the stdout capture via `_codex_review_argv_rejection_flag` (`grep -iE` for `error: unexpected argument '<flag>' found` or `error: invalid value … for '<opt>'`; the leading `error:` + clap grammar is the discriminator, so a prose mention does not false-match; no jq, fail-safe). On a match it **breaks immediately (zero further re-runs)** and logs a `config-error`-naming line with the `AGENT_REVIEW_EXTRA_ARGS_CODEX=" "` remedy. The non-zero rc still propagates → the post-window sweep resolves codex `unavailable`. The argv builder is unchanged — the rejection is caught at runtime, not pre-filtered (flag-filtering was rejected as too magical).
2. **Distinct drop reason — gated on rc 2** ([INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) sub-rule 5b). In the same drop-classification loop, the wrapper passes the agent's launch rc to `_classify_codex_drop_reason "$capture" "$rc"`, which checks the clap signature **before** the stream-error scan (a clap error fails before any model stream opens, so they never co-occur; config-error first is defensive) and echoes `config-error:<flag>` **only when the rc is 2**. `_codex_drop_reason_phrase` renders it as `config-error: codex review rejected '-s' (exec-only flag in extra-args; clear it via AGENT_REVIEW_EXTRA_ARGS_CODEX=" ")` in the WARN line + the posted dropped-agent comment.

**The rc-2 gate is load-bearing (PR #225 review finding [P1]).** The capture scan alone is not a sufficient discriminator: a GENUINE transient failure (e.g. rc 1) whose stdout merely **quotes** `error: unexpected argument '-s' found` — codex echoing a reviewed-diff hunk, or a transport blip after partial output — would otherwise skip the configured re-runs and be dropped as config-error. So both the early-break and the drop-reason classification require **rc 2**; every other non-zero rc takes the bounded re-run path (#209) and, if it stays dropped, is classified `stream-error` / left bare — the true transient cause, not a phantom config-error.

Like the stream-error and auth-failed reasons this is **observability only** — a `config-error` codex stays a dropped `unavailable`, NOT a deciding FAIL (an operator-conf error is not a code rejection; promoting it to a veto would block merges over a stale conf value). `_classify_noverdict_agent` / `_aggregate_review_verdicts` are untouched. The remedy is the [INV-41](invariants.md#inv-41-per-agent-review-model--extra-args-resolution) single-space idiom: set `AGENT_REVIEW_EXTRA_ARGS_CODEX=" "` to clear the poison exec-era value out of the codex review extra-args. Out of scope (per #223): pre-filtering exec-only flags out of the argv (too magical — the runtime classification alone fixes diagnosability), and classifiers for other CLIs.

### kiro auth/login drop reason (INV-61)

A `kiro` review member whose stored OAuth/login token on the execution host has expired tries to open a browser for device-flow re-auth. In the headless (SSM-spawned) shell that is impossible, so kiro exits at **launch** with no verdict comment, and the post-window sweep resolves it `unavailable` ([INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)). Before [INV-61](invariants.md#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) this was dropped as a bare, opaque `unavailable` — the drop-reason assembly enriched only `agy` (INV-58) and `codex` (INV-59), so kiro's actual failure (an expired token, fixable with one operator command) was invisible, indistinguishable from a launch misconfig or a no-verdict miss.

[INV-61](invariants.md#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) closes that gap — the kiro-shaped sibling of the agy / codex detectors above, for an auth/login token expiry instead of a quota wall or a transient stream 5xx:

1. During fan-out the wrapper captures each kiro member's GENERIC per-agent log path (`$_agent_log` = `/tmp/agent-${PROJECT_ID}-review-${ISSUE_NUMBER}-kiro.log` — kiro has no separate `--log-file` like agy) into `AGENT_KIRO_LOGS`.
2. In the drop-classification loop, for any agent resolved `unavailable` whose CLI is `kiro`, the wrapper calls `lib-review-kiro.sh::_classify_kiro_drop_reason <log>` (single-pass `grep -F`, fixed-substring, no jq, fail-safe). It echoes `auth-failed` for ANY of the documented signals (`Failed to open browser for authentication`, `kiro-cli login`, `--use-device-flow`, `Failed to open URL`), or empty when none is present — a clean no-verdict kiro turn yields empty, so the detector never over-claims. `_kiro_drop_reason_phrase` renders the token into the human clause appended to the `WARNING: review agent(s) dropped (unavailable)` log line + the posted "dropped (unavailable) agent(s)" comment (and the all-unavailable `log` line): `auth-failed (browser/device-flow login required on the execution host: kiro-cli login --use-device-flow)`.

Unlike INV-59 there is NO retry half — kiro fails at LAUNCH, not mid-stream, so there is no transient blip to ride out (re-running the same expired-token launch would fail identically). The remedy is operational: `kiro-cli login --use-device-flow` on the execution host. Like INV-58/INV-59 this is **observability only** — an `auth-failed` kiro is still DROPPED from the [INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) aggregation exactly as `unavailable`, NOT a deciding FAIL (an expired token is an operational/infra condition; promoting it to a veto would block merges whenever kiro's token expires on the host). `_classify_noverdict_agent` / `_aggregate_review_verdicts` are untouched. The SAME drop-reason loop now enriches agy (quota/auth), codex (stream-error), AND kiro (auth-failed) members in one fan-out, each with its own distinct clause. Scope is strictly a dropped `kiro` member; a non-kiro drop or a signal-free kiro log keeps the bare `unavailable` wording. Out of scope (per #215): re-authenticating kiro (operational), the INV-40 vote, and classifiers for other CLIs (claude/gemini/opencode).

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
| **Decision** | PASS ⇒ post a "Review PASSED ..." verdict on the **issue** (not PR). FAIL ⇒ post a "Review findings: ..." verdict with a numbered remediation list. **The verdict is posted ONLY via `bash scripts/post-verdict.sh` — never a bare `gh issue comment`** ([INV-56](invariants.md#inv-56-review-verdict-is-posted-via-the-deterministic-post-verdict-helper-not-the-agents-bare-gh)); the helper guarantees the first-line phrasing and appends the `Review Session:` / `Review Agent:` trailer itself. See [Verdict posting (INV-56)](#verdict-posting-inv-56) below. |

The `Review Session:` trailer (presence) + the `Review Agent: <name>` discriminator (per-agent) are how the wrapper identifies which comment is each agent's verdict — see [Verdict polling](#verdict-polling) below.

## Verdict posting (INV-56)

Each review agent posts its verdict comment through the deterministic, wrapper-provided helper `scripts/post-verdict.sh` — **not** a hand-rolled bare `gh issue comment`. `build_review_prompt` routes ALL THREE verdict-post spots through the helper (the generic Helper-usage example, the Decision PASS branch, and the Decision FAIL branch) and explicitly forbids bare `gh issue comment` for the verdict. The verdict-post instruction is identical for every CLI — there is no per-CLI branch for the verdict post (the only codex-specific prompt difference is the [INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) "you are inside `codex review`, the diff is already scoped, do NOT re-run `git diff`" note). For codex, [INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) ALSO has the wrapper post the verdict from parsed stdout as a fallback if codex did not self-post — still through `post-verdict.sh`, so the deterministic chokepoint holds.

The agent writes its body to a FILE and calls:

```bash
bash scripts/post-verdict.sh <issue-number> <pass|fail> <body-file|-> <agent-name> <session-id> [<model>]
```

The helper:

- reads the body from a **FILE** (or stdin via `-`), so a multi-line findings body with backticks/quotes/`$()` can't be mangled by the agent's shell quoting — the suspected `agy` failure mode;
- **guarantees the first-line phrasing the poller matches** (`Review PASSED` for `pass`, `Review findings:` for `fail`, `lib-review-poll.sh::_classify_verdict_body`), prepending the canonical prefix when the agent's body omits it;
- **composes the AGENT verdict trailer itself** — `` Review Session: `<session-id>` `` + `Review Agent: <agent-name>` ([INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) / [INV-20](invariants.md#inv-20-verdict-authenticity-binding-actor--window--trailer-presence)) — so the agent never hand-writes it (closing the session-id-rebind hazard). This is the AGENT verdict trailer, distinct from `lib-review-verdict.sh::emit_verdict_trailer` (the wrapper's `<!-- review-verdict: … -->` machine marker);
- **folds the review model into the `Review Agent:` line** when the optional 6th `<model>` arg is supplied ([INV-60](invariants.md#inv-60-the-review-model-is-shown-inline-on-every-verdict-comments-review-agent-line)): the line becomes `Review Agent: <agent-name> (model: <model>)` so the verdict comment records which model produced it — consistent with the [INV-04](invariants.md#inv-04-reviewed-head-trailer-format) `Reviewed HEAD: … model` trailer and the [INV-58](invariants.md#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) fan-out label. `build_review_prompt` resolves the per-agent **honest** model label (`_resolve_review_agent_model_label` → `${…:-sonnet}`, the same helper the `Reviewed HEAD:` trailer and the fan-out label use) and passes it as the 6th arg in all three verdict-post examples. **agy honesty (#220):** when the agent is `agy` and the resolved id is one [INV-50](invariants.md#inv-50-agy---model-is-validated-against-agy-models-before-forwarding) drops (agy runs its `settings.json` default), the label is `agy default (settings.json)` (or generic `agy default`), not the dropped id — so the verdict comment never asserts a model agy never ran; a valid `AGENT_REVIEW_MODEL_AGY` and the honor-`--model` CLIs (claude/kiro/codex) are shown verbatim. The `Review Agent: <agent-name>` substring at the START of the line is preserved byte-for-byte, so the INV-40 discriminator (`test("Review Agent: <name>")`, a substring test) and the INV-20 trailer binding keep matching. A 5-arg (no-model) call renders the legacy two-line trailer unchanged;
- **posts via the token-refresh proxy `gh`** co-located in the dispatcher `scripts/` dir (the same wrapper `mark-issue-checkbox.sh` uses) — guaranteeing the correct bot identity + real-gh resolution;
- **fails loudly**: non-zero exit on a failed `gh` post (exit `2` on invalid args, including a `<model>` arg that contains a newline or exceeds the length cap), and echoes the created comment URL on success.

**Why**: review agents previously hand-rolled their own bare `gh issue comment`. `agy` exited `0` claiming it posted the verdict, but its multi-line `--body` call never landed, so the verdict poller ([INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)) found nothing and dropped agy `unavailable` on every fleet review. In the SAME run, agy's `mark-issue-checkbox.sh` calls (a deterministic helper) landed fine — so routing the verdict through the same kind of helper makes the post reliable. **The fix is reliable posting, not the exit code**: `unavailable` is decided on comment-absence, not the agent's exit code (`lib-review-aggregate.sh::_classify_noverdict_agent` only consults rc to split `124`/`137` `timed-out` from everything-else `unavailable`, and only for an agent that already posted no verdict). The helper's non-zero-on-failure exit is hygiene + a future hook a follow-up wrapper-side change would consume.

> **Post-install / upgrade**: this added `scripts/post-verdict.sh`. After `npx skills update -g`, re-run `install-project-hooks.sh` on every onboarded project or the review wrappers will instruct agents to call a `scripts/post-verdict.sh` symlink that doesn't exist yet.

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

The trailing parenthesised metadata also carries `agent` / `model` for forensic attribution. Per [INV-58](invariants.md#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) these render the **representative** (first) fan-out agent's name (`_REVIEW_HEAD_AGENT`) and its **per-agent RESOLVED** model (`_REVIEW_HEAD_MODEL` via `_resolve_review_agent_model_label`), not the shared `${AGENT_CMD}` / `${AGENT_REVIEW_MODEL}` defaults — so for a per-agent-overridden fleet the trailer attributes the model the agent actually reviewed with. **agy honesty (#220):** when the representative agent is `agy` and its resolved id is dropped by [INV-50](invariants.md#inv-50-agy---model-is-validated-against-agy-models-before-forwarding) (agy runs its `settings.json` default), `_REVIEW_HEAD_MODEL` renders `agy default (settings.json)` (or generic `agy default`), not the dropped id — the same honest label the INV-60 verdict comment and the INV-58 fan-out line use, via the shared `_resolve_review_agent_model_label`. `SESSION_ID` is already the first agent's session, so session/agent/model now describe ONE agent consistently. The dispatcher parser anchors only on the leading `Reviewed HEAD: \`<sha>\``, so this metadata change is purely human-attribution.

The dispatcher's Step 5b reads the most recent trailer matching `Reviewed HEAD: \`<sha>\`` and compares it to the current `PR.headRefOid`. If they match, the dispatcher sends the issue back to `pending-dev` ("no new commits since last review") instead of bouncing it through review again — see [`dispatcher-flow.md` § Step 5b in-progress](dispatcher-flow.md#dead--in-progress) and [#53](https://github.com/zxkane/autonomous-dev-team/issues/53).

If the trailer post fails (token expiry, 403, rate limit), the wrapper logs `WARNING: Failed to post Reviewed HEAD trailer` and continues — the failed trailer means the dispatcher cannot detect SHA-match, but the empty-trailer fallthrough routes to `pending-review` ([INV-07](invariants.md#inv-07-empty-reviewed-head-trailer-routes-to-pending-review)) which is the safe default.

## PR-open guard (INV-54)

The PR-still-open check ([INV-54](invariants.md#inv-54-the-pr-still-open-guard-gates-all-pass-chain-exits-not-just-pass)) runs before any wrapper-level block gate writes a `reviewing → pending-dev` transition, and skips the `pending-dev` add when the PR is no longer OPEN. It is applied at **two** points, each delegating to the same `lib-review-mergeable.sh::_pr_open_gate` helper.

**(a) Top of the `PASSED_VERDICT == true` chain** — before the mergeable gate, before any block-branch label flip. The check used to live only in the PASS path (step 1 below), AFTER the mergeable gate, so a PR merged out-of-band (manual merge, or the #191 agent self-merge) that then took an INV-44 block branch flipped its already-closed issue to `pending-dev`. Hoisting it makes all three PASS-chain exits (block-substantive, block-nonsubstantive, PASS) honor it with one query.

```
if PASSED_VERDICT == true:
  PR_STATE = gh pr view --json state  (failed query → "UNKNOWN" sentinel)
  if _pr_open_gate "$PR_STATE" == "skip":     # lib-review-mergeable.sh
      # PR no longer OPEN — merged/closed out-of-band, or state in doubt
      −reviewing  (NO +pending-dev) ; exit 0
  # else proceed → mergeable gate + PASS path below
```

**(b) The INV-46 E2E hard gate** (#195) — after `_classify_e2e_gate`, before the `fail`/`block-nonsubstantive` block cascade. The E2E gate runs *before* the fan-out and *before* any verdict, so the hoisted check (a) — which only runs inside the `PASSED_VERDICT == true` chain — never reaches it. A PR merged WHILE the E2E lane ran (a concurrent review / manual merge / #191 self-merge) would otherwise flip its already-closed issue to `pending-dev` from the E2E block branch. The same helper guards it with one query, gating both E2E block exits:

```
if E2E_ACTIVE:
  E2E_GATE = _classify_e2e_gate "$rc" "$evidence_present"     # lib-review-e2e.sh
  if E2E_GATE in {fail, block-nonsubstantive}:
    E2E_PR_STATE = gh pr view --json state  (failed query → "UNKNOWN" sentinel)
    if _pr_open_gate "$E2E_PR_STATE" == "skip":   # lib-review-mergeable.sh (reused)
        # PR merged/closed while the E2E lane ran, or state in doubt
        −reviewing  (NO +pending-dev) ; exit 0
  # else (pass/inactive) → fall through to the review fan-out (UNCHANGED)
```

- The ONLY value that proceeds is a case-insensitive `OPEN` — the exact inverse of the old PASS-branch `!= OPEN` test. `MERGED`/`CLOSED`/`UNKNOWN`/empty/any other token → `skip` → clean `−reviewing` exit, never `+pending-dev`. Fail-closed toward "do not re-queue dev on a merged PR".
- DRY: check (a) **replaces** the old PASS-branch duplicate (step 1 below is now a no-op — by the time the PASS path runs, the PR is guaranteed open); check (b) guards both E2E block exits with a single pre-cascade query. The wrapper holds **exactly two** `gh pr view --json state` calls — one per gate — and neither gate's block branches re-query.
- The E2E check (b) runs only on the block paths (`fail`/`block-nonsubstantive`); the gate's `pass`/`inactive` outcomes fall through to the fan-out before the check is reached, so the happy path costs no extra `gh` call.

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
