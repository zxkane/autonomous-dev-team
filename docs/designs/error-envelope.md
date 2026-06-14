# Design: Operator Error Envelope (issue #231)

## Problem

Today's fail-loud is **log-only** in every config-class startup abort path. A
wrapper that aborts at startup (bad conf, missing binary, token-mint failure,
invalid `E2E_MODE`, launcher/CLI mismatch) leaves the issue stuck in
`reviewing` / `in-progress` with **zero GitHub-visible signal**. The operator
discovers it hours later by log spelunking — the exact silent-stall UX the
project exists to kill.

The crux is **trap timing**: every startup validation in both wrappers aborts
*before* `trap cleanup EXIT` is installed (dev: line 537; review: line 499), so
the existing crash-recovery comment path in `cleanup()` never runs for these
aborts. They are silently log-only.

## Contract (from #229, already merged)

`docs/pipeline/schemas/error-envelope.schema.json`:

```json
{ "schema_version": 1, "class": "config", "code": "KIRO_AUTH_FAILED",
  "problem": "…", "cause": "…", "remediation": "…", "doc": "…",
  "surface": "issue-comment" }
```

- Required: `schema_version` (const 1), `code` (UPPER_SNAKE), `problem`, `cause`,
  `remediation`, `surface` (`issue-comment` | `dispatcher-alert` | `log-only`).
- Optional: `class` (`config`|`auth`|`quota`|`transient`, default `config`),
  `doc`.
- **Clause E2**: operator-actionable classes (`config`/`auth`/`quota`, and the
  default-when-omitted) MUST surface `issue-comment` or `dispatcher-alert` —
  NEVER `log-only`. Only `class: transient` may be `log-only`.
- **Clause E1**: `remediation` MUST be non-empty.
- **Clause E3**: `code` MUST be stable `UPPER_SNAKE`.

## Approach

### 1. `lib-error.sh` — the envelope helper (new lib)

Sourced via `LIB_DIR` (INV-65 two-dir resolution), needs **no** project-side
symlink. Provides:

- `error_envelope <code> <problem> <cause> <remediation> [doc] [class]`
  Renders **one canonical format** used for both the log line and the comment
  body. Returns:
  - a human-readable block (the comment body / log text), AND
  - an embedded machine-readable HTML-comment marker
    `<!-- adt-error-envelope: {json} -->` so the dispatcher Step-5 stale handler
    can detect a surfaced envelope and link it instead of the generic "crashed"
    message. The JSON is built with `jq -nc` (special chars in cause/remediation
    are safe).
  Defaults `class` to `config` (the common case) and `surface` is derived: a
  `transient` class → `log-only`; everything else → `issue-comment` (or
  `dispatcher-alert` when no issue context — caller picks).

- `error_surface <issue> <code> <problem> <cause> <remediation> [doc] [class]`
  Decides the effective surface (`issue-comment` / `dispatcher-alert` /
  `log-only`) FIRST, pins it into the rendered marker JSON, then posts via the
  **token-refresh `gh` proxy**: it prefers the project-side
  `${AUTONOMOUS_CONF_DIR}/gh` symlink (the path `post-verdict.sh` uses) and
  **falls back to the co-located `gh-with-token-refresh.sh`** in its own
  skill-tree dir — so a validation that aborts *before* `setup_github_auth`
  created the symlink still posts (token mode), instead of degrading to
  log-only. It NEVER uses bare PATH `gh` (mis-attribution risk, INV-56).
  **Best-effort**: if the post fails (or the proxy is truly unresolvable), it
  logs the full envelope to stderr (degrade to log-only) and returns 0 anyway —
  surfacing failure MUST NOT change the caller's exit code. When `<issue>` is
  empty/`-`, it skips the post and emits a `dispatcher-alert` envelope to the log
  (marker `surface: dispatcher-alert`) — the tick-global dispatcher aborts have
  no issue to comment on.

Both functions are pure shell + `jq`; no network unless `error_surface` posts.

### 2. Rewire config-class aborts

Each rewired abort calls `error_surface "$ISSUE_NUMBER"` **before** its existing
`exit 1`. The wrapper exit code is unchanged.

**Issue context for pre-arg-parse validations.** Both wrappers run their config
validations *before* the authoritative arg-parse loop. An early, non-destructive
`error_peek_issue_arg "$@"` scan (in `lib-error.sh`) populates `ISSUE_NUMBER` up
front so those validations — and the `lib-agent.sh` launcher guards, which fire
at source-time with the wrapper's `"$@"` in scope — surface on the issue
(`issue-comment`) when the wrapper was launched for one, falling back to
`dispatcher-alert` (`-`) only on manual misinvocation with no `--issue`. The
authoritative arg-parse loop downstream stays the single source of truth for
usage errors / `--validate-config-only` / unknown options.

**Dispatcher required-key preflight.** `dispatcher-tick.sh` checks `REPO` /
`REPO_OWNER` / `PROJECT_ID` / `PROJECT_DIR` and surfaces `ADT_CFG_MISSING_KEY`
*before* sourcing `lib-dispatch.sh` — that library's top-level `${VAR:?}` guards
would otherwise raw-abort the tick before the envelope helper could run.

Inventory (one row per path, each gets a stable code; full table in the PR
body):

| Code | Where | Class | Surface |
|---|---|---|---|
| `ADT_CFG_MISSING_KEY` | dev/review/dispatcher missing required conf key | config | issue / alert |
| `ADT_AUTH_APP_CREDS_MISSING` | `GH_AUTH_MODE=app` missing app id/pem | auth | issue / alert |
| `ADT_AUTH_TOKEN_MINT_FAILED` | token daemon never wrote a token | auth | issue / alert |
| `ADT_CFG_PROJECT_DIR_INVALID` | `cd $PROJECT_DIR` fails | config | issue |
| `ADT_CFG_PID_DIR_UNWRITABLE` | PID dir cannot be resolved | config | issue |
| `ADT_CFG_LAUNCHER_CLI_MISMATCH` | INV-38 launcher only with claude | config | issue / alert |
| `ADT_CFG_LAUNCHER_PARSE` | AGENT_*_LAUNCHER fails to tokenize | config | issue / alert |
| `ADT_CFG_E2E_MODE_REQUIRED` | E2E_ENABLED but E2E_MODE unset | config | issue / alert |
| `ADT_CFG_E2E_MODE_INVALID` | invalid E2E_MODE value | config | issue / alert |
| `ADT_CFG_E2E_MODE_MISMATCH` | E2E_COMMAND* set, wrong mode | config | issue / alert |
| `ADT_CFG_E2E_COMMAND_MISSING` | E2E_MODE=command, no E2E_COMMAND | config | issue / alert |
| `ADT_CFG_E2E_PARSER_MISSING` | E2E_MODE=command, no parser | config | issue / alert |
| `ADT_CFG_E2E_PR_NUMBER_UNBRACED` | unbraced $PR_NUMBER | config | issue / alert |
| `ADT_CFG_REVIEW_TIMEOUT_INVALID` | bad AGENT_REVIEW_TIMEOUT (INV-48) | config | issue / alert |
| `ADT_CFG_E2E_BROWSER_TIMEOUT_INVALID` | bad E2E_BROWSER_TIMEOUT_SECONDS | config | issue / alert |
| `ADT_CFG_SMOKE_TIMEOUT_INVALID` | bad REVIEW_SMOKE_TIMEOUT_SECONDS (INV-64) | config | issue / alert |
| `ADT_CFG_REVIEW_BOTS_INVALID` | invalid REVIEW_BOTS token | config | issue / alert |
| `ADT_CFG_EXECUTION_BACKEND_INVALID` | unknown EXECUTION_BACKEND | config | alert |

Tick-global dispatcher aborts (`dispatcher-tick.sh` — unknown `EXECUTION_BACKEND`,
required-key preflight, `REVIEW_BOTS`, app-creds/token-mint) have no per-issue
context → `surface: dispatcher-alert` (envelope to the log with the
`dispatcher-alert` marker; the OpenClaw dispatcher agent reads its run log). The
per-issue wrapper codes that fire pre-arg-parse (`issue / alert`) resolve to
`issue-comment` via the early `error_peek_issue_arg` scan when `--issue` is
present.

### 3. Transient-class failures: NO change

Agent-exit retries, fan-out drops (INV-58 agy quota, INV-61 kiro auth — those
already surface distinct reasons in their dropped-agent comments), idle gates,
SIGTERM handoff. Envelopes are for **config-class** failures only. This is a
regression-pinned invariant.

### 4. Dispatcher Step-5 stale handling links the envelope

In `dispatcher-tick.sh` Step 5b (DEAD branch), before posting the generic "Task
appears to have crashed" / "Review process appears to have crashed" comment,
check the issue's recent comments for an `<!-- adt-error-envelope: … -->`
marker. If present, the dispatcher comment links/quotes the surfaced envelope's
`code` + `remediation` instead of the opaque generic text — so a config crash
isn't misreported as a transient crash that burns retries.

### 5. Docs

- `docs/pipeline/errors.md`: the error-code registry (code → class → problem /
  cause / remediation / doc). Append-only; codes never renumber.
- `docs/pipeline/invariants.md`: new **INV-72** — "config-class failures MUST
  surface on the issue (or as a dispatcher alert), never log-only" — cross-links
  the error-envelope schema (#229 / INV-66) and `errors.md`.
- Cross-link from `state-machine.md` not needed (no new label transition).

## Testing (TDD)

`docs/test-cases/error-envelope.md` — `TC-ERR-ENVELOPE-NNN`:

- Envelope rendering: special chars in cause/remediation (backticks, quotes,
  `$()`, newlines) survive `jq -nc`; the embedded JSON validates against the
  schema.
- `error_surface` posts a comment via the stubbed `gh` proxy AND logs the
  envelope.
- Comment-post failure degrades to log-only WITHOUT changing rc (stub `gh`
  exits non-zero → `error_surface` still returns 0, envelope on stderr).
- Transient-class failures post nothing (regression pin).
- Code registry drift guard: every `code` emitted by `lib-error.sh` callers
  exists as a row in `docs/pipeline/errors.md` (grep-assert).
- Schema-conformance: the rendered embedded JSON validates against
  `error-envelope.schema.json` (python3 jsonschema if available, else jq
  structural assertions — same dual-path as `test-adapter-spec-schemas.sh`).

E2E: stub-wrapper run with a deliberately broken conf → issue comment appears
with code + remediation; issue label state unchanged by the post.

## Out of scope

- Rewriting retry/backoff for transient failures.
- Alerting channels beyond GitHub comments / the dispatcher run log.
- Emitting the full four-axis AdapterResult (later phase) — this issue is the
  error-envelope surface only.
