# Design Canvas — E2E_MODE: pluggable E2E channel for the autonomous-review wrapper

**Issue**: #161
**Status**: design recorded; implementation merged on the branch alongside this canvas.
**Authors / decision date**: 2026-05-29.

## 1. Problem

`autonomous-review`'s E2E channel is hardcoded to **browser-driven UI smoke testing** via Chrome DevTools MCP — login flow, navigate, screenshot upload, structured report. This shape only fits SaaS web apps with a per-PR preview URL.

Concrete trigger: a backend-pipeline consumer's PR required a 30–60 min run on a deployed PR-stage (DDB row state + S3 artifact assertions + visual confirmation of an LLM-cleaned transcript). The existing wrapper had no way to dispatch this — the review agent looped 3 times against operator-gated findings, the dev agent self-deescalated by removing the `autonomous` label, the operator ran the E2E manually and pasted the evidence by hand. Next consumer in this shape should not need that ceremony.

Three project shapes are NOT served by the existing `browser` channel:

- **Backend pipelines** — verification is "did the artifact land + assert its content shape", not "is this button clickable on the page".
- **CLI tools / libraries** — no preview URL, no login flow.
- **Infra-as-code / ML pipelines** — verify by reading deploy outputs / DDB rows / S3 keys.

## 2. Decisions

| # | Question | Decision | Rationale |
|---|---|---|---|
| Q1 | One mode, or multiple? | **Three modes** via `E2E_MODE`: `none` (default), `browser` (existing logic), `command` (new). | Browser-mode preserves back-compat for the SaaS web app case; command-mode covers the three new shapes; `none` is the explicit no-E2E default. |
| Q2 | Default value of `E2E_MODE` when unset? | **`none`** — explicit opt-in to a specific mode. | Implicit-default-to-`browser` was the prior shape and the most common upgrade footgun. Making opt-in explicit catches the typo at startup. |
| Q3 | What if `E2E_ENABLED=true` but `E2E_MODE` is unset? | **Fail-loud at wrapper startup** with the three accepted values listed. | Existing projects had only `E2E_ENABLED`. Without fail-loud, the upgrade silently falls through to `none` and projects believe E2E is wired up. |
| Q4 | Who owns the evidence block — agent or project? | **Project** (`E2E_COMMAND_EVIDENCE_PARSER` is REQUIRED in command-mode). | Pipeline-specific evidence (raw.json clusters, DDB row state, prod-baseline diff) is project knowledge. Agent is the runner + judge, not the author. |
| Q5 | Marker format for evidence-block detection? | **SHA-bound: `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->`** | Without the SHA, a stale evidence comment from a prior commit can silently satisfy a re-review of newer code. The wrapper exports `PR_HEAD_SHA` so the parser can embed it. |
| Q6 | Sync vs async execution? | **MVP is synchronous** — the agent waits for `E2E_COMMAND` under `timeout(1)` with `E2E_COMMAND_TIMEOUT_SECONDS` (default 3600). | Async with an `e2e-running` PR label is the right shape for >60 min cases but adds dispatcher state-machine complexity. Defer to follow-up. |
| Q7 | Parser invocation gating? | **Run parser only when `EXIT_CODE ∈ {0, 124}`.** Other failures post a `tail -50` of the log file directly. | Parsers consume successful runs; a hard-failure log is malformed and crashes the parser, masking the real failure. |
| Q8 | Decision-block FAIL message — shared or per-mode? | **Per-mode** (`case ${E2E_MODE}` in the prompt's "Decision" section). | `browser` says "screenshot evidence", `command` says "verify-command exit code + log tail". Sharing the message confuses the agent in command-mode (no browser, no screenshots). |
| Q9 | Unbraced `$PR_NUMBER` in command-mode fields? | **Reject at config validation.** | The wrapper substitutes only braced `${PR_NUMBER}`. Bare `$PR_NUMBER` would render as empty and target the wrong stage. |
| Q10 | Pipeline-doc impact? | **Update `docs/pipeline/review-agent-flow.md`** with E2E mode dispatch + Step 4b stale-evidence guard. **No new INV-NN.** | This is a wrapper-config schema, not a label-state-machine invariant. Existing INV set is unchanged. |

### Rejected alternatives

- **A. New skill (e.g. `autonomous-review-pipeline`).** Doubles the maintenance surface; project switching between web-app and pipeline shapes (e.g. a monorepo) would need two confs.
- **B. GHA workflow indirection** — `gh workflow run` to trigger E2E on the runner, agent only reads the comment. Adds CI/CD round-trip to every review tick; fights with the wrapper's existing token / cost-attribution model.
- **C. Implicit-default `browser` when `E2E_MODE` unset.** The most common upgrade footgun pattern. See Q3 rationale.

## 3. Configuration schema (canonical)

```bash
# autonomous.conf
E2E_ENABLED="true"          # legacy back-compat toggle (still respected)
E2E_MODE="command"          # none | browser | command — REQUIRED if ENABLED=true

# Browser-mode fields (used when E2E_MODE=browser)
E2E_PREVIEW_URL_PATTERN="https://pr-{N}.example.com"
E2E_TEST_USER_EMAIL="..."
E2E_TEST_USER_PASSWORD="..."
E2E_SCREENSHOT_UPLOAD="false"

# Command-mode fields (used when E2E_MODE=command)
E2E_COMMAND='bash scripts/e2e-pr-stage.sh ${PR_NUMBER}'           # required
E2E_COMMAND_EVIDENCE_PARSER='bash scripts/e2e-evidence.sh'        # required
E2E_COMMAND_PRE_HOOKS='bash scripts/e2e-seed-pr-stage.sh ${PR_NUMBER}'  # optional
E2E_COMMAND_TIMEOUT_SECONDS=3600                                   # optional, default 3600
```

`${PR_NUMBER}` placeholder is substituted at render time by the wrapper. Operators MUST single-quote the assignments so the shell does not eagerly expand at conf-source time.

## 4. Dispatch table (canonical)

For each rendered review prompt:

| `E2E_MODE` | Wrapper behavior | Agent receives |
|---|---|---|
| unset | `validate_e2e_config` returns 0 (no-E2E path) | no E2E section in prompt |
| `none` | as above | no E2E section |
| `browser` | extract preview URL from PR comments + pattern; export test creds | existing browser block (mandatory) |
| `command` | export `PR_NUMBER` + `PR_HEAD_SHA`; substitute `${PR_NUMBER}` in command-mode fields | new command block (mandatory) |
| any other value | fail-loud at startup with three accepted values listed | (wrapper exits 1) |

`E2E_ENABLED=true` + `E2E_MODE` unset → fail-loud. Same fail-loud for command-mode without `E2E_COMMAND` or `E2E_COMMAND_EVIDENCE_PARSER`, or for command-mode fields populated when `E2E_MODE` is `none`/`browser`.

The `E2E_ACTIVE` flag (true when mode ∈ {browser, command}) is a derived internal var. Downstream prompt language (decision-gate, env-export block, "E2E completed" suffix) gates off `E2E_ACTIVE` rather than `E2E_ENABLED`. Legacy `E2E_ENABLED` is preserved in conf for back-compat but the wrapper's source of truth is `E2E_MODE`.

## 5. Project-side contract for command-mode

Two scripts the project supplies:

1. **`E2E_COMMAND`** — the verify command. Reads PR_NUMBER from substitution. Exits 0 on success, 124 on timeout, other non-zero on hard fail. Idempotent against retries.

2. **`E2E_COMMAND_EVIDENCE_PARSER`** — reads the verify command's log file as `$1`, emits a markdown evidence block to stdout. Block MUST end with `<!-- e2e-evidence: complete sha="${PR_HEAD_SHA}" -->` (parser reads `PR_HEAD_SHA` from env). Returns 0 on success, non-zero if log is malformed or required artifacts are missing.

Full contract: `skills/autonomous-review/references/e2e-command-mode.md`.

## 6. Out of scope (follow-up)

- **Background / async long-running E2E** with `e2e-running` PR label, for >60 min cases without blocking the agent session. The MVP's `timeout(1)` cap is sufficient for the first consumer (~48 min observed) but won't scale.
- **Wrapper-side last-line marker validation** — currently the agent parses the marker. Future PR may move it into the wrapper.
- **`timeout-124` stale-artifact acceptance hardening** — require artifacts to embed `PR_NUMBER` + nonce so a hung pipeline can't fall back on yesterday's S3 object.
- **`E2E_ENABLED=false` + `E2E_MODE=command` semantic ambiguity** — today the wrapper drives off `E2E_MODE` exclusively; `E2E_ENABLED=false` is a no-op once `E2E_MODE` is set. Future schema cleanup may either honor `E2E_ENABLED` as a hard kill switch or remove it entirely.
