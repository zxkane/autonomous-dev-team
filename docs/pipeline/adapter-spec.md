# Agent-CLI Adapter Spec

```
spec_version: 1
status: NORMATIVE — this document is the contract later phases implement
scope: the agent-CLI adapter boundary (dev + review + e2e)
```

> **This is the redesign's keystone artifact.** Later issues — the conformance
> fixture runner, the verdict-as-data channel, env scrubbing — *implement* this
> spec and **MUST NOT redefine it**. When this spec and the wrapper code
> disagree, this spec is authoritative for the *target contract*; a current
> wrapper that diverges is documented in the [Mapping appendix](#mapping-appendix-current-clis-onto-the-contract)
> as a known gap, not a contradiction of the spec.
>
> This revision is **spec + schemas only — no wrapper / `lib-agent.sh` behavior
> change.** It describes what an adapter MUST do; it does not yet refactor the
> code to a single adapter entry point. See [INV-66](invariants.md#inv-66-adapter-conformance-is-spec-defined).

The key words **MUST**, **MUST NOT**, **REQUIRED**, **SHALL**, **SHALL NOT**,
**SHOULD**, **SHOULD NOT**, **MAY**, and **OPTIONAL** are to be interpreted as
described in [RFC 2119](https://www.rfc-editor.org/rfc/rfc2119). Each normative
clause is written so a conformance check can map 1:1 to it.

---

## 1. Why this spec exists

Per-CLI handling today is scattered across `case "$AGENT_CMD"` branches in
[`lib-agent.sh`](../../skills/autonomous-dispatcher/scripts/lib-agent.sh) and
special-cased in the `lib-review-*.sh` family (`lib-review-codex.sh`,
`lib-review-agy.sh`, `lib-review-kiro.sh`, `lib-review-aggregate.sh`,
`lib-review-resolve.sh`). The contracts that hold the pipeline together exist
only as folklore plus `INV-NN` prose. A new CLI vendor — or the next refactor —
has nothing normative to build against, and every behavior is reverse-engineered
from the wrapper.

This spec makes the adapter boundary a **contract**: a single interface with a
**mode axis**, a **four-axis result**, a **verdict artifact**, a **conformance
fixture manifest**, and an **operator error envelope**, each with a JSON Schema
under [`schemas/`](schemas/).

---

## 2. The adapter interface

An **adapter** wraps one agent-CLI (`claude`, `codex`, `kiro`, `agy`, `gemini`,
`opencode`). It exposes a single conceptual entry point:

```
invoke(mode, prompt, model, session, timeout, env) → AdapterResult
```

| Param | Meaning |
|---|---|
| `mode` | One of `dev-new`, `dev-resume`, `review`, `e2e-browser`. The **mode axis** — see §3. |
| `prompt` | The instruction text. The default channel is the CLI's stdin, not an argv string ([INV-34](invariants.md#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element)) — a multi-kilobyte prompt as argv risks `E2BIG`/`execve` arg-length limits. The one carve-out is a review-mode CLI with **no** stdin-prompt mode (`codex review`), which takes the prompt as its positional `[PROMPT]` argument by design — see Clause A2 and Clause M4. |
| `model` | The resolved model id (per-agent resolution per [INV-41](invariants.md#inv-41-per-agent-review-model--extra-args-resolution); `agy` is validated against `agy models` per [INV-50](invariants.md#inv-50-agy---model-is-validated-against-agy-models-before-forwarding)). MAY be empty (adapter applies its launch default). |
| `session` | The session identity. For `dev-new`/`review` the wrapper mints a UUID; for `dev-resume` it is the prior session handle the adapter persisted. Some CLIs mint their own (see §3.5). |
| `timeout` | The per-side wall-clock cap (dev timeout / `AGENT_REVIEW_TIMEOUT`, default 1h, [INV-48](invariants.md#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto)). The adapter **MUST** run under it and surface a timeout distinctly (§4.1). |
| `env` | Environment the adapter reads: `AGENT_*_EXTRA_ARGS[_<AGENT>]`, launcher, sentinel overrides (`CODEX_REVIEW_NO_WORKTREE_RC`). |

**Clause A1 (single result).** An adapter **MUST** return exactly one
`AdapterResult` per `invoke`, conforming to
[`schemas/adapter-result.schema.json`](schemas/adapter-result.schema.json).

**Clause A2 (stdin prompt — default channel, with an explicit review carve-out).**
The adapter **MUST** feed `prompt` on the CLI's stdin and **MUST NOT** pass it as
an argv element ([INV-34](invariants.md#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element)), **except** for a review-mode adapter whose CLI
exposes **no** stdin-prompt mode. The sole such case today is `codex review`,
which takes the prompt as its positional `[PROMPT]` argument (Clause M4 /
[INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback)). A review adapter MAY use the positional `[PROMPT]` channel **only when**
(a) the CLI offers no stdin-prompt mode for that subcommand AND (b) the prompt is
small enough that argv length limits are not a concern (a `codex review` gate
prompt is short — it does not carry the diff, which `codex review` fetches
itself). Every dev-mode (`dev-new` / `dev-resume`) and every other CLI's review
adapter **MUST** still use stdin. A conformance fixture's `command.argv` records
which channel the adapter actually used, so the carve-out is auditable (the codex
review fixture's `argv` includes `<prompt>`; a stdin adapter's does not, and pins
the prompt via `command.stdinSha256`).

**Clause A3 (no uniform invoke fiction).** The spec **MUST NOT** be read as
asserting one CLI invocation shape covers all modes. Modes differ
*structurally* (§3); a conformant adapter implements each mode it supports per
the per-mode clauses, and an adapter that does not support a mode **MUST**
return `voteEligibility.state = "not-applicable"` rather than fabricating a
result.

---

## 3. The mode axis (modes differ structurally)

### 3.1 `dev-new`

Start a fresh dev session. The wrapper mints the session UUID and passes it in.

- **Clause M1.** The adapter **MUST** begin a new session and **MUST** persist
  whatever handle `dev-resume` later needs (a session UUID the CLI round-trips,
  or a CLI-minted thread id written to a sidecar — §3.5).
- `voteEligibility.state` for dev modes is **always** `not-applicable` (dev does
  not vote).

### 3.2 `dev-resume`

Continue a previously-started dev session with a new prompt (e.g. review
findings).

- **Clause M2.** If the CLI supports resume, the adapter **MUST** resume the
  *same* session/thread the matching `dev-new` persisted. If the CLI does **not**
  support resume (e.g. `kiro`), the adapter **MUST** fall back to a fresh
  session and **MUST** rely on the prompt carrying the full context. It **MUST
  NOT** silently no-op.

### 3.3 `review`

Reach a PASS/FAIL verdict on a PR. This is the only mode whose result
participates in the [INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)
unanimous-PASS vote.

- **Clause M3.** The adapter **MUST** produce a verdict artifact (§5) — or, if
  it cannot, **MUST** set `verdict.state = "absent"` so the aggregator can
  resolve it (§4.4). It **MUST NOT** claim success without an artifact a reader
  can find (the `agy` rc-0-silent failure mode, §7).
- **Clause M4 (codex review structural difference).** The `codex` review adapter
  **MUST** run the purpose-built `codex review "<prompt>"` subcommand from a
  PR-branch worktree (so the diff is auto-scoped to the PR, not `main`),
  **MUST NOT** resume, and **MUST** fail closed with the `no-worktree` sentinel
  (`rc 70`, `provider.class = "config"`) when worktree prep fails, rather than
  reviewing the wrong tree. ([INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback).)
  `codex review` has **no** stdin-prompt mode — it takes the gate prompt as its
  positional `[PROMPT]` argument. This is the explicit Clause A2 carve-out: the
  prompt is the short gate instruction (not the diff, which the subcommand
  fetches itself), so argv length is not a concern. A future codex review adapter
  therefore satisfies the contract by carrying the prompt positionally; it does
  **not** violate A2.

### 3.4 `e2e-browser`

Drive a browser to produce E2E evidence. Runs **once per review** in a dedicated
lane, **not per review agent** ([INV-46](invariants.md#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent)).

- **Clause M5.** `voteEligibility.state` **MUST** be `not-applicable` — the E2E
  lane feeds the hard gate and the verdict artifact's `evidence.e2eReport`, but
  does not itself cast a vote.

### 3.5 Session-handle persistence (per CLI)

| CLI | Session model | `dev-resume` handle |
|---|---|---|
| `claude` | Wrapper-minted UUID via `--session-id`; `--resume <uuid>`. | the same UUID |
| `codex` (dev) | CLI mints `thread_id`; captured to a sidecar. | `codex exec resume <thread_id>` |
| `codex` (review) | **No session.** | n/a — review never resumes (Clause M4) |
| `gemini` | Wrapper-minted UUID round-trips; `--resume <uuid>`. | the same UUID |
| `kiro` | **No session.** | fresh conversation (Clause M2) |
| `opencode` | CLI mints `ses_<base62>`; captured + resumed. | the captured id |
| `agy` | CLI mints an internal UUID; captured via `--log-file`. | the captured id |

---

## 4. The four-axis AdapterResult

A flat failure enum is **documented as NON-conformant**: it discards
information the aggregator already depends on. An `AdapterResult` **MUST** carry
all four orthogonal axes. Schema:
[`schemas/adapter-result.schema.json`](schemas/adapter-result.schema.json).

### 4.1 `process` — `{ rc, signal, timedOut }`

How the CLI process exited.

- **Clause P1.** `rc` is the raw exit code. The adapter **MUST** set `timedOut =
  true` **iff** the process was killed by the wall-clock cap — i.e. `rc ∈ {124,
  137}` (`timeout` TERM-expiry / `--kill-after` SIGKILL). (INV-48.) This is a
  **biconditional**, and the schema enforces it as an rc↔timedOut consistency
  rule: `timedOut = true` with a non-`{124,137}` rc, **and** `timedOut = false`
  with `rc ∈ {124, 137}`, are both rejected (negative fixture
  [`adapter-result.negative.timedout-rc-inconsistent.json`](schemas/examples/adapter-result.negative.timedout-rc-inconsistent.json)).
- **Clause P1 (timeout-veto derivation).** **The schema enforces the review-mode
  no-verdict timeout case** with a conditional keyed off **`timedOut`** (not the
  raw rc, so every timed-out result is covered): when `mode = review` AND
  `process.timedOut = true` AND `verdict.state ∈ {absent, malformed}`,
  `voteEligibility.state` MUST be `timeout-veto` — so a timed-out review
  no-verdict result cannot validate as `pass`/`fail`/`drop` (negative fixtures
  [`adapter-result.negative.timeout-vote-wrong.json`](schemas/examples/adapter-result.negative.timeout-vote-wrong.json)
  and [`adapter-result.negative.timeout-not-veto.json`](schemas/examples/adapter-result.negative.timeout-not-veto.json)).
  The conditional is **gated on `mode = review`**: a non-review
  (`dev-new`/`dev-resume`/`e2e-browser`) timeout result is `not-applicable` (it
  does not vote — §4.4) and is a valid AdapterResult (golden
  [`adapter-result.golden.dev-resume-timeout.json`](schemas/examples/adapter-result.golden.dev-resume-timeout.json)).
  A timed-out run that *did* post a verdict (`verdict.state = valid`) is exempt —
  the matched verdict wins ([INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)) — so the conditional is gated on the
  no-verdict case only.
- A dispatcher-induced `SIGTERM` (`rc 143`) **MUST NOT** be counted as a
  crash by the retry counter ([INV-26](invariants.md#inv-26-stall-decision-excludes-dispatcher-induced-terminations-and-defers-on-live-wrappers)).

### 4.2 `provider` — `{ class, evidence, resetHint? }`

Why the model backend failed, with evidence, when it did.

| `class` | Meaning | Retryable? |
|---|---|---|
| `none` | Provider OK (the model ran; verdict outcome is on the `verdict` axis). | — |
| `quota` | 429 / `RESOURCE_EXHAUSTED` ([INV-58](invariants.md#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent)). | no (until reset) |
| `auth` | login / OAuth / device-flow failure (INV-58 `agy`, [INV-61](invariants.md#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) `kiro`). | no (operator must log in) |
| `config` | structural prep failure an operator must fix (codex `no-worktree` rc 70, bad model id, missing trust flag). | no (operator must fix) |
| `transient` | retryable upstream blip (codex `stream-error`, INV-59/INV-62 5xx reconnect). | yes |

- **Clause PR1.** When `class != none` the adapter **MUST** populate `evidence`
  with a **non-empty** sanitized operator-facing reason (e.g.
  `"quota-exhausted (Antigravity 429: daily quota reached; resets in
  33h48m45s)"`). The schema enforces this with a conditional `required` **plus**
  `minLength: 1` on `evidence`, so a non-`none` class with an empty `evidence`
  string is rejected (negative fixture
  [`adapter-result.negative.empty-evidence.json`](schemas/examples/adapter-result.negative.empty-evidence.json)) —
  there is no useful empty evidence.
- **Clause PR2.** For `class = config` the adapter **MUST** also emit an
  [error envelope](#6-the-operator-error-envelope) (§6) and surface it to the
  operator — never log-only.

### 4.3 `verdict` — `{ state, payloadRef }` (`payloadRef` REQUIRED when `state = valid`)

Whether the adapter produced a classifiable verdict artifact within the poll
window.

- `valid` — a well-formed verdict artifact (§5) was produced; `payloadRef`
  points at it. **Clause V0:** when `verdict.state = valid`, `payloadRef`
  **MUST** be a non-empty string — a `valid` verdict the wrapper/aggregator
  cannot locate is non-conformant. **The schema enforces this** with a
  conditional (`required` non-empty `payloadRef` for `state = valid`); negative
  fixture [`adapter-result.negative.valid-no-payloadref.json`](schemas/examples/adapter-result.negative.valid-no-payloadref.json).
  `payloadRef` stays optional/nullable for `absent` / `malformed`.
- `absent` — no artifact within the window. Drives `drop` / `timeout-veto`
  (§4.4).
- `malformed` — an artifact was produced but failed schema validation.
  **Clause V1:** a `malformed` verdict **MUST** be treated exactly as `absent`
  for vote purposes — it **MUST NOT** be coerced into a silent PASS (fail-safe,
  matching INV-49's fail-safe-not-fail-open rule).

### 4.4 `voteEligibility` — `{ state, reason? }`

How this result participates in the INV-40 vote. This axis is **derived** from
the other three; the spec fixes the derivation so every adapter computes it
identically. **Every row is machine-enforced by Draft-07 conditionals** — see
§4.1 Clause P1 and the negative fixtures
[`adapter-result.negative.timeout-not-veto.json`](schemas/examples/adapter-result.negative.timeout-not-veto.json),
[`adapter-result.negative.noverdict-not-drop.json`](schemas/examples/adapter-result.negative.noverdict-not-drop.json),
[`adapter-result.negative.valid-verdict-drop.json`](schemas/examples/adapter-result.negative.valid-verdict-drop.json),
and [`adapter-result.negative.devmode-votes.json`](schemas/examples/adapter-result.negative.devmode-votes.json).

| `state` | Derivation | Effect on the merge |
|---|---|---|
| `pass` | `mode = review` ∧ `verdict.state = valid` ∧ artifact verdict = `PASS` | deciding PASS |
| `fail` | `mode = review` ∧ `verdict.state = valid` ∧ artifact verdict = `FAIL` | deciding FAIL |
| `drop` | `mode = review` ∧ `verdict.state ∈ {absent, malformed}` ∧ `process.timedOut = false` | removed from the vote (`unavailable`) |
| `timeout-veto` | `mode = review` ∧ `verdict.state ∈ {absent, malformed}` ∧ `process.timedOut = true` | **deciding FAIL that vetoes the merge** |
| `not-applicable` | `mode ∈ {dev-new, dev-resume, e2e-browser}` | does not vote |

> **Schema enforcement (full derivation).** The conditionals cover every row:
> - A **non-review** mode (`dev-new`/`dev-resume`/`e2e-browser`) MUST be
>   `not-applicable` — it cannot validate as `pass`/`fail`/`drop`/`timeout-veto`.
> - For `mode = review` with a **valid** verdict, the vote MUST be `pass` or
>   `fail` (the PASS/FAIL artifact decides which) — not `drop`/`timeout-veto`/`not-applicable`.
> - For `mode = review` with **no** verdict (`absent`/`malformed`): `timeout-veto`
>   when `process.timedOut = true`, else `drop`.

#### Worked example 1 — provider 429s mid-run (the AC question)

> *"What must my new CLI's adapter return when the provider 429s mid-run?"*

The CLI exits cleanly (rc 0) having posted nothing:

```json
{
  "process":  { "rc": 0, "signal": null, "timedOut": false },
  "provider": { "class": "quota", "evidence": "quota-exhausted (… resets in 33h48m45s)", "resetHint": "Resets in 33h48m45s" },
  "verdict":  { "state": "absent", "payloadRef": null },
  "voteEligibility": { "state": "drop", "reason": "unavailable" }
}
```

The adapter **MUST** classify the 429 on the `provider` axis (scraping its own
log if the CLI only surfaces the signal there, as `agy` does), set `verdict`
absent, and resolve `voteEligibility = drop`. The agent is removed from the
vote, not counted as a FAIL — but the drop reason is surfaced
(§6 / INV-58), never an opaque bare `unavailable`. See golden
[`adapter-result.golden.quota-drop.json`](schemas/examples/adapter-result.golden.quota-drop.json).

#### Worked example 2 — timeout with no verdict

The reviewer is killed by the 1h cap (rc 124) before posting:

```json
{
  "process":  { "rc": 124, "signal": "SIGTERM", "timedOut": true },
  "provider": { "class": "none" },
  "verdict":  { "state": "absent", "payloadRef": null },
  "voteEligibility": { "state": "timeout-veto", "reason": "timed-out" }
}
```

This is a **deciding FAIL** (INV-48 timeout-veto): a timed-out reviewer must be
LOUD (FAIL → `−reviewing +pending-dev`), not silently dropped. See golden
[`adapter-result.golden.timeout-veto.json`](schemas/examples/adapter-result.golden.timeout-veto.json).

---

## 5. The verdict artifact contract

> *"What file does the wrapper read for my verdict and what schema must it satisfy?"*

A review-mode adapter produces a **verdict artifact** conforming to
[`schemas/verdict-artifact.schema.json`](schemas/verdict-artifact.schema.json).
Today the wrapper reads it as the issue comment posted via
[`post-verdict.sh`](../../skills/autonomous-dispatcher/scripts/post-verdict.sh)
(first line `Review PASSED` / `Review findings:`, plus the `Review Session:` /
`Review Agent:` trailer the helper composes); the spec's target is this same
information as **typed data**.

- **Clause VA1 (schema_version).** The artifact **MUST** carry `schema_version`
  (value `1` this revision). An artifact without `schema_version` is
  NON-conformant (the schema rejects it).
- **Clause VA2 (verdict ∈ {PASS, FAIL}; FAIL ⇔ ≥1 blocking finding).** There is
  no middle ground (INV-40 / decision gate). The schema enforces **both
  directions** with conditionals: a non-empty `blockingFindings` array **MUST**
  force `verdict = FAIL`, **and** `verdict = FAIL` **MUST** carry ≥1 blocking
  finding (`blockingFindings` present, `minItems: 1`). A FAIL with empty/absent
  `blockingFindings` is non-conformant — it would block a merge with nothing
  actionable for the dev side to fix (negative fixture
  [`verdict-artifact.negative.fail-no-blocking.json`](schemas/examples/verdict-artifact.negative.fail-no-blocking.json)).
  PASS keeps `blockingFindings` empty/absent.
- **Clause VA3 (folded evidence, not parallel fences).** The artifact folds in,
  as **typed sub-objects** under `evidence`:
  - `acCoverage` — the [INV-49](invariants.md#inv-49-command-mode-e2e-may-feed-the-review-fan-out-a-structured-ac-coverage-artifact--optional-fail-safe)
    AC-coverage map `{ "<criterion>": "pass" | "fail" }`. This replaces the
    standalone `ac-coverage:begin…end` HTML fence.
  - `e2eReport` — the [INV-46](invariants.md#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent)
    E2E lane result (`gate`, `mode`, `summary`). This replaces the parallel
    free-form E2E evidence comment as the typed channel.
- **Clause VA4 (identity).** The artifact **MUST** carry `runId` (the minted
  session UUID, the `Review Session:` trailer, INV-20) and `agent` (the
  `Review Agent:` discriminator, INV-40), and **SHOULD** carry `model` (the
  resolved review model, [INV-60](invariants.md#inv-60-the-review-model-is-shown-inline-on-every-verdict-comments-review-agent-line)).
- **Clause VA5 (atomic write).** The artifact **MUST** be written atomically
  (write a temp file, then `rename(2)` into place). A reader **MUST** ignore any
  write that lands after it first reads the artifact (no torn reads, no
  post-land mutation observed). This generalizes the INV-49 sidecar's
  fail-safe / no-stale-leak discipline to the verdict channel.

Goldens: [`verdict-artifact.golden.pass.json`](schemas/examples/verdict-artifact.golden.pass.json),
[`verdict-artifact.golden.fail.json`](schemas/examples/verdict-artifact.golden.fail.json).

---

## 6. The operator error envelope

When a failure needs human attention (every operator-actionable
`provider.class` — `config`, `auth`, `quota`), the adapter emits an **error
envelope** conforming to
[`schemas/error-envelope.schema.json`](schemas/error-envelope.schema.json):

```json
{ "class": "config", "code": "KIRO_AUTH_FAILED", "problem": "…", "cause": "…", "remediation": "…", "doc": "…", "surface": "issue-comment" }
```

- **Clause E1 (remediation REQUIRED).** `remediation` **MUST** be present and
  non-empty. An error an operator cannot act on is NON-conformant (schema
  rejects it).
- **Clause E2 (operator-actionable classes surface, never log-only).** An
  operator-actionable `class` — `config` (codex `no-worktree`, unknown model),
  `auth` (kiro/agy login), or `quota` — **MUST** surface on the GitHub issue
  (`surface: "issue-comment"`) or as a dispatcher alert
  (`surface: "dispatcher-alert"`) and **MUST NOT** be `log-only`. **The schema
  enforces this** with a conditional: when `class` is omitted (it defaults to
  `config`) or is one of `config` / `auth` / `quota`, `surface` is constrained to
  `issue-comment` / `dispatcher-alert`, so a `config`-class envelope with
  `surface: "log-only"` is rejected at validation time (see negative fixture
  [`error-envelope.negative.config-log-only.json`](schemas/examples/error-envelope.negative.config-log-only.json)).
  `log-only` is permitted **only** for an explicit `class: "transient"` (a
  retryable blip the dispatcher re-dispatches automatically — no operator
  action). This makes the existing INV-58 / INV-61 drop-reason surfacing
  normative and machine-checkable.
- **Clause E3 (stable code).** `code` **MUST** be a stable `UPPER_SNAKE`
  identifier so an operator/alerting rule can key on it.

Goldens: [`error-envelope.golden.kiro-auth.json`](schemas/examples/error-envelope.golden.kiro-auth.json),
[`error-envelope.golden.codex-no-worktree.json`](schemas/examples/error-envelope.golden.codex-no-worktree.json),
[`error-envelope.golden.transient-log-only.json`](schemas/examples/error-envelope.golden.transient-log-only.json) (the only log-only case — `class: transient`).

---

## 7. Per-CLI "lying modes" — which axis absorbs each

Every CLI has a failure mode where it *appears* to succeed (or fails opaquely).
The spec's job is to name which axis absorbs each, so a conformant adapter
cannot let it through as a silent PASS.

| CLI | Lying mode | rc | Absorbed by | Reason string / sentinel |
|---|---|---|---|---|
| `claude` | (none documented — fails loudly) | varies | normal axes | — |
| `codex` | **clap arg error vs transient stream-error both non-zero**: a `codex review` arg/clap error (rc 2) looks like a transient blip but is a `config` failure; a 5xx mid-stream is `transient`. | 1/2 | `provider.class` = `config` (clap) vs `transient` (stream) | `stream-error (upstream 5xx; exhausted 5/5 stream reconnects)` (INV-59/INV-62); clap → `no-worktree`/config envelope |
| `codex` | **no-worktree** prep failure could review the wrong tree | 70 | `provider.class = config` + fail-closed | `no-worktree` sentinel (INV-62, Clause M4) |
| `kiro` | **exit-0 fabrication / headless auth**: with no login token kiro tries to open a browser; in a headless shell that fails, and it can exit claiming success or produce no verdict | varies | `provider.class = auth`, `verdict.state = absent` → `drop` | `auth-failed (browser/device-flow login required …: kiro-cli login --use-device-flow)` (INV-61) |
| `agy` | **rc-0 silent quota**: hits the 429 quota wall, exits 0 with empty stdout, the verdict comment never lands | 0 | `provider.class = quota`, `verdict.state = absent` → `drop` | `quota-exhausted (Antigravity 429: daily quota reached; resets in <dur>)` (INV-58) |
| `agy` | **rc-0 silent auth** | 0 | `provider.class = auth` → `drop` | `auth-failed (agy not logged into Antigravity / OAuth token unavailable)` (INV-58) |
| `agy` | **accepts any `--model` at rc 0** (invalid → silent fallback to default) | 0 | validated *before* invoke (INV-50) → `config` envelope if unknown | validated against `agy models` |
| `gemini` | **tool-denial fabrication** without `--approval-mode yolo`: silently denies tool calls and may narrate success | 0 | `env` (extra-args) precondition; absent → `verdict.state = absent` → `drop` | requires `--approval-mode yolo` |
| `opencode` | (session-mint capture failure → resume can't find thread) | varies | `provider.class = config` if capture fails | sidecar capture |

**Clause L1.** For every CLI whose success can be faked at `rc 0`, the adapter
**MUST NOT** infer `verdict.state = valid` from `rc 0` alone — it **MUST**
confirm a classifiable verdict artifact actually exists (the lesson of INV-56 /
the `agy` silent-post bug). Absent the artifact, `verdict.state = absent` and
the `provider` axis carries the real reason.

---

## 8. The conformance fixture manifest

A `FixtureManifest` ([`schemas/fixture-manifest.schema.json`](schemas/fixture-manifest.schema.json))
pins one `adapter × mode` behavior: the `input` (prompt byte-length, model,
env), the `command` the adapter assembled (argv, stdin SHA-256, canned rc /
stdout / stderr), any `files` (sidecars / logs / artifacts), and the `expect`ed
AdapterResult axes (`providerClass`, `verdictState`, `vote`, `retryable`).

The standalone conformance runner that *replays* these manifests against the
current classification path is implemented in
[`tests/conformance/run-conformance.sh`](../../tests/conformance/) (issue #230,
[INV-74](invariants.md#inv-74-adapter-conformance-is-regression-pinned-by-a-hermetic-fixture-manifest-runner)).
It is **hermetic** — stub CLIs on an isolated `PATH`, no network, no
credentials — and drives TODAY's monolithic classifier
(`lib-agent-smoke.sh::_smoke_classify` + the per-CLI scrapers), so the later
adapter extraction must keep conformance green before AND after the refactor.
See [`tests/conformance/README.md`](../../tests/conformance/README.md) for how a
CLI vendor authors a manifest and runs the suite standalone.

Goldens: [`fixture-manifest.golden.codex-review.json`](schemas/examples/fixture-manifest.golden.codex-review.json),
[`fixture-manifest.golden.agy-quota.json`](schemas/examples/fixture-manifest.golden.agy-quota.json).

---

## 9. The agent-progress recorder (dev mode, #493)

> This section documents the PRODUCER contract only. Nothing in the pipeline
> reads the lease yet — see [INV-135](invariants.md#inv-135-the-agent-progress-lease-is-a-producer-only-signal-refreshed-on-launch-and-per-complete-output-record-never-by-the-heartbeat).

Every `dev-new` / `dev-resume` adapter invocation composes one additional
pipeline stage after its own CLI invocation (and after any pre-existing
session-handle capture filter):

```
printf '%s' "$prompt" | _run_with_timeout <cli> <args> | [<capture-filter> |] _agent_progress_recorder <framing>
```

**Clause R1 (framing per adapter).** `_agent_progress_recorder` takes exactly
one framing argument, `json` or `line`:

| Adapter | Framing | Why |
|---|---|---|
| `claude` | `json` | `--output-format stream-json --verbose` (§ dev-agent-flow.md R4) — one complete JSON object per line. |
| `codex` | `json` | `codex exec --json` — JSONL event stream. |
| `opencode` | `json` | `opencode run --format json` — JSON event stream. |
| `gemini` | `json` **iff** the resolved `AGENT_*_EXTRA_ARGS` selects stream-json (either the two-token `--output-format stream-json` or the equals-joined `--output-format=stream-json`); **else `line`** | Gemini's JSON stream mode is operator-opted-in via `AGENT_DEV_EXTRA_ARGS`/`AGENT_REVIEW_EXTRA_ARGS` ([INV-31](invariants.md#inv-31-operator-tunable-per-cli-flags-live-in-conf-not-in-lib-agentsh)), not hardcoded — the adapter scans its OWN resolved extra-args array (not the raw env var) so the framing choice tracks whatever actually reached the CLI's argv, matching both argv forms so an equals-joined flag can't fall through to `line` framing and let a truncated JSONL record falsely refresh the lease (round-2 review finding). |
| `agy` | `line` | No JSON event stream (§7 lying-modes table; agy's only structured channel is `--log-file`, which the recorder does not read). |
| `kiro` | `line` | No JSON event stream. |
| unknown-CLI fallback (`run_agent`'s generic branch) | `line` | An unrecognized CLI is never assumed to emit a JSON stream. |

**Clause R2 (a record).** Under `json` framing, a record is a line that is a
COMPLETE, valid JSON object — the recorder pre-filters on the first character
being `{` (cheap discriminator, avoids invoking `jq` on plain-text/non-JSON
lines) and then validates the candidate with `jq -e .` before treating it as a
record. A truncated or malformed line (e.g. a crashed or malformed JSONL
agent mid-write) does NOT refresh the lease — falling through to the next
line, which either completes the record or is itself dropped. `jq`
unavailability at call time degrades to the cheap prefix check alone (same
posture as every other `command -v jq` guard in `lib-agent.sh`). Under `line`
framing, every non-empty line is a record — no JSON validation applies.

**Clause R3 (byte-identical pass-through).** The recorder **MUST NOT** buffer,
reorder, drop, or otherwise alter a single byte of the CLI's stdout — including
preserving a final line with no trailing newline. It **MUST NOT** touch stderr
at all. This is a hard requirement because the recorder sits in the SAME
pipeline that ultimately lands in `/tmp/agent-*-issue-N.log` — anything it
alters corrupts the log every downstream consumer (`is_session_completed`,
`metrics_parse_tokens`, the remote probe, an operator `tail -f`) reads.

**Clause R4 (exit-status transparency).** The recorder's own exit status
(always `0`) **MUST NOT** be read by any caller. Every call site appends the
recorder strictly AFTER the CLI's own `_run_with_timeout` stage (and after any
existing capture filter), so the CLI's rc is read from the SAME `PIPESTATUS`
index every call site used before the recorder was inserted — the recorder
never shifts that index.

**Clause R5 (composes with existing capture filters).** Where a CLI already
has a session-handle capture filter in its pipeline (`_codex_capture_thread`,
`_opencode_capture_session`), the recorder composes AFTER it: `... | <capture
filter> | _agent_progress_recorder <framing>`. Both are pass-through awk/read
filters operating on the same byte stream; chaining them changes neither's
behavior.

**Clause R6 (never driven by the heartbeat).** The recorder is the ONLY writer
of progress refreshes driven by CLI *output*. `install_agent_heartbeat`'s touch
loop **MUST NOT** call the progress-refresh primitive — conflating "wrapper
process is alive" with "agent made progress" is exactly the ambiguity this
feature exists to resolve (dispatcher polling, transport keepalives, and
PR/CI/label/issue changes made by OTHER processes are likewise never progress
events).

---

## Mapping appendix — current CLIs onto the contract

How today's behavior maps onto the contract, per CLI × mode. "Gap" = where the
current code does not yet emit the typed artifact/envelope the spec targets
(those are the later phases' work).

| CLI | dev-new | dev-resume | review | e2e-browser |
|---|---|---|---|---|
| `claude` | `--session-id <uuid>`, stdin prompt | `--resume <uuid>` | verdict via `post-verdict.sh` comment (gap: not yet typed JSON) | n/a (browser lane is CLI-agnostic) |
| `codex` | `codex exec --json`, thread-id sidecar | `codex exec resume <thread_id>` | **`codex review "<prompt>"` from PR worktree, no resume, `no-worktree` rc 70** (INV-62) | n/a |
| `kiro` | stdin prompt, `--trust-all-tools` | **fresh session** (no resume) | verdict via comment; `auth-failed` drop on headless login fail (INV-61) | n/a |
| `agy` | `--log-file` capture | resume via captured id | verdict via `post-verdict.sh`; `quota`/`auth` drop scraped from `--log-file` (INV-58); `--model` validated (INV-50) | n/a |
| `gemini` | `--session-id`, `--approval-mode yolo` | `--resume <uuid>` | verdict via comment | n/a |
| `opencode` | mints `ses_<base62>`, captured | resume via captured id | verdict via comment | n/a |

**Where each lying mode is absorbed (summary):** `agy` rc-0 quota/auth →
`provider` axis via log scrape (INV-58); `kiro` exit-0 / headless-auth →
`provider.class = auth` + `verdict.absent` (INV-61); `codex` rc-2 clap vs
transient stream-error → `provider.class = config` vs `transient` (INV-59/62);
`codex` no-worktree → fail-closed `config` (INV-62); `gemini` tool-denial →
`env` precondition + `verdict.absent`.

---

## Authoring a new CLI adapter

The per-CLI behavior is extracted into one file per CLI under
[`skills/autonomous-dispatcher/scripts/adapters/<cli>.sh`](../../skills/autonomous-dispatcher/scripts/adapters/)
([INV-75](invariants.md#inv-75-all-per-cli-behavior-lives-in-that-clis-adapter--inline-cli-conditionals-in-orchestration-code-are-a-defect)).
`run_agent` / `resume_agent` are thin dispatchers. To add a new CLI:

1. **Copy the closest template.** `adapters/claude.sh` is the minimal shape (no
   sidecar, no scraper); `adapters/agy.sh` is the full shape (model validation +
   session capture + drop-reason scrapers). Define:
   - `adapter_invoke_<cli> <mode> <session_id> <prompt> <model> <session_name>` —
     the mode-axis entry. Handle `dev-new` and `dev-resume` (§3); feed the prompt
     on **stdin** (Clause A2 / INV-34) unless your review subcommand has no stdin
     mode (the codex carve-out). Parse `AGENT_DEV_EXTRA_ARGS` for `dev-new`,
     `AGENT_REVIEW_EXTRA_ARGS` for `dev-resume` (a no-resume CLI uses
     `AGENT_DEV_EXTRA_ARGS` for both, like kiro).
   - `adapter_binary_<cli>` — ONLY if the exec binary differs from the adapter id
     (e.g. kiro → `kiro-cli`); otherwise omit (the default is the id).
   - a `_classify_<cli>_drop_reason` + `_<cli>_drop_reason_phrase` pair if your
     CLI has a "lying mode" (§7) the `provider` axis must absorb.
   - session capture/recall helpers if your CLI mints its own session id (§3.5).
2. **Register it** in `lib-agent.sh`'s `for _adapter in …` source loop and the
   two thin-dispatch `case "$AGENT_CMD" in claude|codex|…)` arms. Add the file to
   the CI shellcheck list (`.github/workflows/ci.yml`).
3. **Write ≥2 conformance manifests** under `tests/conformance/fixtures/` (a clean
   verdict + at least one failure mode) per §8 and the
   [conformance README](../../tests/conformance/README.md#authoring-a-manifest-cli-vendors).
4. **Pass conformance**: `bash tests/conformance/run-conformance.sh --adapter <cli>`
   green. A new CLI is admitted to the fan-out only once it carries ≥2 manifests
   and the suite stays green (INV-74).

No orchestration-core change is needed beyond the dispatch arms + source loop —
that is the whole point of [INV-75](invariants.md#inv-75-all-per-cli-behavior-lives-in-that-clis-adapter--inline-cli-conditionals-in-orchestration-code-are-a-defect).

---

## Cross-references

- [`invariants.md` § INV-66](invariants.md#inv-66-adapter-conformance-is-spec-defined) — adapter conformance is spec-defined (this document).
- [`invariants.md` § INV-75](invariants.md#inv-75-all-per-cli-behavior-lives-in-that-clis-adapter--inline-cli-conditionals-in-orchestration-code-are-a-defect) — the implementation: all per-CLI behavior lives in `adapters/<cli>.sh` (#232).
- [`invariants.md` § INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback) — the vote this `voteEligibility` axis feeds.
- [`invariants.md` § INV-48](invariants.md#inv-48-per-side-review-wall-clock-timeout-agent_review_timeout-1h-default-with-browser-e2e-exclusion-and-timeout-veto) — the timeout-veto worked example.
- [`invariants.md` § INV-46](invariants.md#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent) / [INV-49](invariants.md#inv-49-command-mode-e2e-may-feed-the-review-fan-out-a-structured-ac-coverage-artifact--optional-fail-safe) — the E2E report + AC-coverage sub-objects.
- [`invariants.md` § INV-58](invariants.md#inv-58-agy-quotaauth-unavailable-drops-surface-a-distinct-reason-fan-out--reviewed-head-model-labels-are-per-agent) / [INV-61](invariants.md#inv-61-kiro-authlogin-failure-unavailable-drops-surface-a-distinct-reason-not-a-bare-opaque-unavailable) / [INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) — the per-CLI provider classifications.
- [`autonomous-pipeline.md`](../autonomous-pipeline.md) — the orientation doc this spec is linked from.
- [`docs/designs/adapter-spec.md`](../designs/adapter-spec.md) — design canvas.
- [`invariants.md` § INV-135](invariants.md#inv-135-the-agent-progress-lease-is-a-producer-only-signal-refreshed-on-launch-and-per-complete-output-record-never-by-the-heartbeat) — the agent-progress lease contract (§9, #493).
- [`dev-agent-flow.md`](dev-agent-flow.md) — the lease's sidecar-file ownership, init/cleanup lifecycle, and the Claude stream-json migration (#493 R4).
