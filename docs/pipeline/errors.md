# Error-code registry (operator error envelopes)

This is the **append-only** registry of operator error-envelope codes emitted by
the dispatcher and the dev/review wrappers. It is the human-readable companion to
[`schemas/error-envelope.schema.json`](schemas/error-envelope.schema.json) and is
the authority [INV-72](invariants.md#inv-72-config-class-failures-must-surface-on-the-issue-never-log-only)
binds every config-class abort path to.

**Rules**

- **Codes are append-only and never renumber.** An operator's alerting rule may
  key on a `code`; renumbering would silently break it.
- Every code is a stable `UPPER_SNAKE` identifier (`^[A-Z][A-Z0-9_]*$`, Clause E3).
- Every code here is **operator-actionable** (`class ∈ {config, auth, quota}`)
  and therefore surfaces on the issue (`issue-comment`) or as a `dispatcher-alert`
  — **never** log-only (Clause E2). `class: transient` envelopes are log-only and
  are NOT registered here (they are retried automatically; no operator action).
- A new code added to a wrapper/dispatcher call site MUST be added here in the
  **same PR** — the drift-guard test (`test-lib-error-envelope.sh`
  TC-ERR-ENVELOPE-020) fails the build otherwise.

The `error_envelope` / `error_surface` helpers live in
[`lib-error.sh`](../../skills/autonomous-dispatcher/scripts/lib-error.sh).

> **Field contract.** All envelope fields (`problem` / `cause` / `remediation`)
> are static, operator-trusted strings supplied by the call site — never
> issue/PR-derived text. The embedded marker is an HTML comment, so a field
> containing the literal `-->` would close it early and break the dispatcher's
> `recent_error_envelope` extraction. No current code path can produce that
> (the fields are constants); if a future call site ever derives an envelope
> field from untrusted input, strip/escape `-->` before passing it.

## Configuration class (`class: config`)

| Code | Problem | Cause | Remediation | Surface |
|---|---|---|---|---|
| `ADT_CFG_MISSING_KEY` | A required `autonomous.conf` key is unset | One of `PROJECT_ID` / `REPO` / `REPO_OWNER` / `REPO_NAME` / `PROJECT_DIR` is missing | Set the named key in the project's `scripts/autonomous.conf` (see `autonomous.conf.example`), then re-dispatch | issue-comment / dispatcher-alert |
| `ADT_CFG_PROJECT_DIR_INVALID` | The wrapper cannot enter `PROJECT_DIR` | `cd "$PROJECT_DIR"` failed (path missing or not a directory) | Fix `PROJECT_DIR` in `autonomous.conf` so it points at the project checkout on the execution host, then re-dispatch | issue-comment |
| `ADT_CFG_PID_DIR_UNWRITABLE` | The per-user PID dir cannot be resolved/created | `pid_dir_for_project` could not create/chmod the run-state dir (`XDG_RUNTIME_DIR` / fallback unwritable) | Ensure the execution user can write its XDG runtime dir (or `~/.local/state`); inspect the `pid_dir_for_project:` diagnostics in the log, then re-dispatch | issue-comment |
| `ADT_CFG_AGENT_BINARY_MISSING` | The configured agent CLI binary is not on `PATH` | `AGENT_CMD` resolves to a launch binary (`AGENT_CMD` itself, or `kiro-cli` when `AGENT_CMD=kiro`) that `command -v` cannot find on the execution host's `PATH` — preflighted before `run_agent`/`resume_agent` (`lib-agent.sh`) **and** before the codex review lane (`lib-review-codex.sh::_run_codex_review`, which launches `codex review` directly), so a missing binary surfaces an envelope instead of an opaque rc 127 / generic session failure / dropped-`unavailable` review agent | Install the named binary on the execution host (or fix `PATH` / `AGENT_CMD` in `scripts/autonomous.conf`), then re-dispatch | issue-comment / dispatcher-alert |
| `ADT_CFG_LAUNCHER_CLI_MISMATCH` | `AGENT_*_LAUNCHER` is set with a non-`claude` CLI | INV-38: a launcher (e.g. the `cc` bridge) is only supported with `AGENT_*_CMD=claude` | Either unset the launcher for the non-claude side, or set the side's CLI to `claude`, then re-dispatch | issue-comment / dispatcher-alert |
| `ADT_CFG_LAUNCHER_PARSE` | An `AGENT_*_LAUNCHER` value does not tokenize as a shell argv list | The launcher string has unbalanced quotes / invalid shell words | Fix the launcher value in `autonomous.conf` to a valid shell argv (e.g. `cc --role dev`), then re-dispatch | issue-comment / dispatcher-alert |
| `ADT_CFG_E2E_MODE_REQUIRED` | `E2E_ENABLED=true` but `E2E_MODE` is unset | E2E is enabled without an explicit mode | Set `E2E_MODE` to `none`, `browser`, or `command` in `autonomous.conf`, then re-dispatch | issue-comment |
| `ADT_CFG_E2E_MODE_INVALID` | `E2E_MODE` has an unrecognized value | `E2E_MODE` is not one of `none` / `browser` / `command` | Set `E2E_MODE` to `none`, `browser`, or `command`, then re-dispatch | issue-comment |
| `ADT_CFG_E2E_MODE_MISMATCH` | `E2E_COMMAND*` fields are set but `E2E_MODE` is not `command` | Command-mode E2E config is present under a non-command mode | Set `E2E_MODE=command` (or clear the `E2E_COMMAND*` fields), then re-dispatch | issue-comment |
| `ADT_CFG_E2E_COMMAND_MISSING` | `E2E_MODE=command` but `E2E_COMMAND` is unset | Command-mode E2E selected without a command | Set `E2E_COMMAND` in `autonomous.conf`, then re-dispatch | issue-comment |
| `ADT_CFG_E2E_PARSER_MISSING` | `E2E_MODE=command` but `E2E_COMMAND_EVIDENCE_PARSER` is unset | Command-mode E2E selected without an evidence parser | Set `E2E_COMMAND_EVIDENCE_PARSER` in `autonomous.conf`, then re-dispatch | issue-comment |
| `ADT_CFG_E2E_PR_NUMBER_UNBRACED` | An `E2E_COMMAND*` field contains an unbraced `$PR_NUMBER` | The field uses `$PR_NUMBER` instead of `${PR_NUMBER}` (ambiguous expansion) | Use `${PR_NUMBER}` in the `E2E_COMMAND*` field, then re-dispatch | issue-comment |
| `ADT_CFG_REVIEW_TIMEOUT_INVALID` | `AGENT_REVIEW_TIMEOUT` is not a valid positive timeout | INV-48: the value is not a positive coreutils-`timeout` duration (e.g. `3600`, `1h`) | Set `AGENT_REVIEW_TIMEOUT` to a positive coreutils-timeout value, then re-dispatch | issue-comment |
| `ADT_CFG_E2E_BROWSER_TIMEOUT_INVALID` | `E2E_BROWSER_TIMEOUT_SECONDS` is not a valid positive timeout | The value is not a positive coreutils-`timeout` duration | Set `E2E_BROWSER_TIMEOUT_SECONDS` to a positive value (e.g. `900`), then re-dispatch | issue-comment |
| `ADT_CFG_SMOKE_TIMEOUT_INVALID` | `REVIEW_SMOKE_TIMEOUT_SECONDS` is not a valid positive timeout | INV-64: the value is not a positive coreutils-`timeout` duration | Set `REVIEW_SMOKE_TIMEOUT_SECONDS` to a positive value, then re-dispatch | issue-comment |
| `ADT_CFG_REVIEW_BOTS_INVALID` | `REVIEW_BOTS` contains an unrecognized token | A `REVIEW_BOTS` entry is not a known bot short-name (`q` / `codex` / `claude` / a configured custom bot) | Fix `REVIEW_BOTS` in `autonomous.conf` to a space-separated list of known bot short-names (or empty), then re-dispatch | issue-comment / dispatcher-alert |
| `ADT_CFG_EXECUTION_BACKEND_INVALID` | `EXECUTION_BACKEND` has an unrecognized value | The dispatcher's `EXECUTION_BACKEND` is not `local` or `remote-aws-ssm` | Set `EXECUTION_BACKEND` to `local` or `remote-aws-ssm` in `dispatcher.conf`/`autonomous.conf` | dispatcher-alert |

## Authentication class (`class: auth`)

| Code | Problem | Cause | Remediation | Surface |
|---|---|---|---|---|
| `ADT_AUTH_APP_CREDS_MISSING` | `GH_AUTH_MODE=app` but the App credentials are unset | The side's `*_APP_ID` / `*_APP_PEM` (dev/review/dispatcher) is missing | Set the App id + PEM path for this side in `autonomous.conf`/`dispatcher.conf` (see `docs/github-app-setup.md`), then re-dispatch | issue-comment / dispatcher-alert |
| `ADT_AUTH_TOKEN_MINT_FAILED` | A GitHub App installation token could not be minted | The token-refresh daemon never wrote an initial token, or `gh-app-token` returned empty/non-zero | Verify the App id, installation id, and PEM are correct on the execution host and the App has the required repo permissions; check the token-daemon log, then re-dispatch | issue-comment / dispatcher-alert |

## Notes

- **Surface column** lists where each code surfaces. A code that can fire both
  with and without per-issue context (e.g. `ADT_CFG_MISSING_KEY` fires in the
  per-issue wrappers AND in the tick-global dispatcher) lists both; the call site
  picks `issue-comment` when an issue number is known, `dispatcher-alert`
  otherwise.
- **Wrappers surface on the issue even for pre-arg-parse validations.** Both
  wrappers run their config validations *before* the authoritative arg-parse
  loop, so an early **non-destructive** `error_peek_issue_arg "$@"` scan (in
  `lib-error.sh`) populates `ISSUE_NUMBER` up front. Every wrapper startup
  validation — including the `lib-agent.sh` launcher guards, which run at
  source-time — therefore targets the issue (`issue-comment`) when the wrapper
  was launched for one, falling back to `dispatcher-alert` only when there is no
  `--issue` (manual misinvocation).
- **`error_surface` resolves the `gh` proxy with a skill-tree fallback**, so a
  validation that aborts *before* `setup_github_auth` (a fresh install, or a
  source-time launcher guard) still POSTS rather than degrading to log-only. It
  prefers the project-side `${AUTONOMOUS_CONF_DIR}/gh` symlink and falls back to
  the co-located `gh-with-token-refresh.sh` in its own skill-tree dir (the file
  the symlink points at — mode-agnostic + identity-correct per INV-56). In
  token mode this posts (the wrapper exec's the host `gh` with the right
  identity); in GitHub-App mode a *source-time* envelope may still degrade to
  log-only because the installation token is not minted until
  `setup_github_auth`. It NEVER falls back to bare PATH `gh` (that would
  mis-attribute the comment). The target repo is `REPO` / `GITHUB_REPO`, falling
  back to `${REPO_OWNER}/${REPO_NAME}` — so an `ADT_CFG_MISSING_KEY` envelope for
  a missing `REPO` (with `REPO_OWNER`/`REPO_NAME` present), surfaced before
  `cd "$PROJECT_DIR"`, still resolves a `--repo` and posts.
- **The full envelope is always written to the wrapper log too** — on the
  SUCCESS path as well as every degradation path. The #231 contract is "the same
  envelope to the wrapper log AND the issue", so the local run log always carries
  the problem / cause / remediation / marker regardless of whether the post
  landed.
- **The marker's `surface` matches where the envelope actually goes.**
  `error_surface` decides the effective surface (`issue-comment` /
  `dispatcher-alert` / `log-only`) *before* rendering and pins it into the
  embedded marker JSON, so a dispatcher-alert envelope reads
  `"surface":"dispatcher-alert"` — not the class-default `issue-comment`.
- **Dispatcher required-key preflight.** The **dispatcher** preflights its
  required keys (`REPO` / `REPO_OWNER` / `PROJECT_ID` / `PROJECT_DIR`) *before*
  sourcing `lib-dispatch.sh` (whose top-level `${VAR:?}` guards would otherwise
  raw-abort the tick before the envelope helper runs), so a missing dispatcher
  key produces `ADT_CFG_MISSING_KEY`, not an opaque shell error.
- **`MODEL_UNKNOWN`** (agy `--model` validated against `agy models`, INV-50) and
  the per-CLI review drop reasons (`AGY_QUOTA_EXHAUSTED` / INV-58,
  `KIRO_AUTH_FAILED` / INV-61, `CODEX_NO_WORKTREE` / INV-62) are part of the same
  envelope family and already surface their distinct reason in the review
  fan-out's dropped-agent comment. They are documented by their owning invariant
  and the adapter-spec mapping appendix; this registry covers the
  dispatcher/wrapper **startup** config-class aborts #231 rewired. New review-lane
  codes are added here when those lanes adopt the typed envelope.
