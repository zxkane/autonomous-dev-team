# Agent Smoke — three-state CLI launch/auth/model probe

> Spec for `lib-agent-smoke.sh::smoke_agent` and the matrix harness
> `tests/e2e/run-agent-smoke.sh`. The authoritative invariant is
> [INV-63](invariants.md#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path).

## What it is

A reusable capability that verifies each supported coding-agent CLI (`claude`,
`codex`, `kiro`, `agy`, `claude`-with-custom-endpoint, …) can actually
**launch, authenticate, and get a real model response** — wired into this
repo's own PR E2E so regressions in `lib-agent.sh` / agent invocation are caught
on every autonomous-reviewed PR. Unit tests stub the CLIs, so the launch → auth
→ model chain is otherwise never exercised before merge.

"Can it run" is the bar: **CLI starts → auth works → model truly responds.**

## The three-state contract

`smoke_agent <agent-cmd> <model> [timeout-seconds]` (default timeout 120s)
returns one of three states, each with a distinct rc:

| rc | State | Meaning | Gate effect |
|---|---|---|---|
| 0 | **PASS** | stdout contains the nonce — the model truly responded | the win |
| 2 | **UNAVAILABLE** | quota exhausted / backend model capacity / transient backend failure; a bare timeout ([INV-67](invariants.md#inv-67-a-bare-smoke-timeout-rc-124137-with-no-authconfig-signal-classifies-unavailable-not-fail)); a bare `no-response` that stays no-response after one retry ([INV-76](invariants.md#inv-76-a-transient-smoke-no-response-rc0-no-signal-retries-once-then-drops-unavailable--never-a-single-shot-gate-fail)) | recorded, **non-blocking** — environmental, self-healing |
| 1 | **FAIL** | an **auth/config scraper signal**: CLI fails to launch, auth error, region drift, a clap argv rejection. A bare timeout / bare `no-response` is NOT a FAIL (it is UNAVAILABLE — see above) | **blocking** — operator-side config/launch breakage, the gate's reason to exist |

**FAIL = operator-side config/launch breakage (gate-worthy). UNAVAILABLE =
environmental quota/capacity (ignorable).** This mirrors
[INV-40](invariants.md#inv-40-multi-agent-review-attribution-unanimous-aggregation-and-all-unavailable-fallback)'s
review-side treatment of `unavailable`: promoting a quota wall to a deciding
FAIL would block every PR whenever an agent's daily quota is spent.

## Mechanism — reuse the production chain

`smoke_agent` writes **no** parallel invocation path. It:

1. Generates a random nonce `SMOKE-<16 hex>` (CSPRNG; `$RANDOM`-only is avoided
   — a tight loop reseeds slowly and can repeat).
2. Mints a **valid UUID session id** (`_smoke_session_id` via
   `/proc/sys/kernel/random/uuid` → `uuidgen` → a v4-shaped fallback). The Claude
   Code CLI rejects `--session-id` unless it is a UUID, so a non-UUID id would
   fail every real claude / claude-custom-endpoint entry at launch before any
   model call.
3. Builds a prompt: *reply with EXACTLY this token, use no tools.*
4. Sets `AGENT_CMD=<agent-cmd>` and a short `AGENT_TIMEOUT` override (in a
   subshell so neither leaks), then calls the **existing `run_agent`**
   (`lib-agent.sh`). The timeout arg is normalized first — a bare integer gets
   `s` appended (`5` → `5s`), a value already carrying a unit (`5s` / `2m`) is
   passed through verbatim, so a suffixed input never becomes `5ss` (which would
   make `timeout(1)` fail immediately). The smoke therefore exercises the exact
   production launch path — [INV-34](invariants.md#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element)
   stdin channel, [INV-50](invariants.md#inv-50-agy---model-is-validated-against-agy-models-wrapper-side-unknown-ids-are-omitted-not-forwarded)
   agy model validation, launcher handling, EXTRA_ARGS parsing.
5. Captures stdout and stderr to **separate** files (and, for agy, the
   per-session `--log-file`). The nonce PASS check reads **stdout only** — see
   below.

### Classification

`_smoke_classify` reuses the per-CLI drop-reason scrapers. **The nonce PASS check
reads only the stdout file** (`2>"$stderr_file"`, never `2>&1`) **and requires
`run_agent` to have exited `0`**: the prompt contains the nonce, so a broken CLI
that echoes it (onto stdout OR stderr) and then exits non-zero must not be a false
PASS — a healthy round-trip exits 0. The check runs over a **TTY-sanitized** view
of stdout (`_smoke_stdout_has_nonce`): kiro `--no-interactive` wraps its response
in terminal decoration and injects a **BEL (`0x07`) inside the echoed token**
(`SMOKE-^G<hex>`), so a raw `grep` would miss a verified-healthy kiro → false
`no-response` FAIL. The helper strips C0 control bytes (incl. the BEL) + ANSI CSI
before matching; this only recovers a hidden real match (the rc-0 gate +
stdout-only separation + nonce uniqueness keep the false-PASS direction closed).
The kiro/codex scrapers get a combined stdout+stderr view (their error text can
land on either stream); agy reads its own `--log-file`.

| Signal | Source | State |
|---|---|---|
| nonce on stdout (TTY-sanitized) **AND rc 0** | **stdout-only** strip + `grep -F` + exit code | **PASS** |
| `quota-exhausted*` | `_classify_agy_drop_reason` ([INV-58](invariants.md#inv-58-agy-quota--auth-drops-surface-a-distinct-reason-not-an-opaque-unavailable)) | **UNAVAILABLE** |
| agy `auth-failed` | `_classify_agy_drop_reason` | **FAIL** |
| kiro `auth-failed` | `_classify_kiro_drop_reason` ([INV-61](invariants.md#inv-61-kiro-auth-drops-surface-a-distinct-reason-not-an-opaque-unavailable)) | **FAIL** |
| codex `stream-error*` (upstream 5xx) | `_classify_codex_drop_reason` ([INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback)) | **UNAVAILABLE** |
| codex `config-error*` (clap argv rejection) | `_classify_codex_drop_reason` | **FAIL** (names the rejected flag) |
| codex `malformed-output` (prompt-echo / startup-trace) | `_classify_codex_drop_reason` ([INV-73](invariants.md#inv-73-a-codex-review-prompt-echo--startup-trace-stdout-is-malformed-never-a-blocking-p1-fail--retry-or-drop-not-a-phantom-veto)) | **UNAVAILABLE** |
| bare timeout (rc 124/137), no signal | `run_agent` rc | **UNAVAILABLE** ([INV-67](invariants.md#inv-67-a-bare-smoke-timeout-rc-124137-with-no-authconfig-signal-classifies-unavailable-not-fail)) |
| bare `no-response` (rc≠0, no nonce, no signal) — **first probe** | — | retried once ([INV-76](invariants.md#inv-76-a-transient-smoke-no-response-rc0-no-signal-retries-once-then-drops-unavailable--never-a-single-shot-gate-fail)) |
| bare `no-response` still after one retry | `smoke_agent` retry | **UNAVAILABLE** (`no-response (… after retry — transient infra)`) |
| `rc=0` silent-success `no-response` (CLI exits 0, no nonce, no signal) | — | **FAIL**, no retry (issue #257 follow-up — only `rc≠0` is transient) |

The environmental signal is checked **before** the timeout branch, so an agy
that hits a quota wall and then hangs is still UNAVAILABLE (the cause wins over
the bare timeout). The nonce match is exact — a truncated/garbled echo is FAIL.

**`_smoke_classify` is a pure single-probe function ([INV-63](invariants.md#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path)).** The
**retry-once** of a bare `no-response` ([INV-76](invariants.md#inv-76-a-transient-smoke-no-response-rc0-no-signal-retries-once-then-drops-unavailable--never-a-single-shot-gate-fail)) lives in the **driver** `smoke_agent`,
not in the classifier: it factors the single probe into `_smoke_probe_once` and, when
the first probe is the step-5 bare `no-response` FAIL (detected by
`_smoke_is_transient_no_response`: STATE==FAIL && reason starts `no-response` && the
reason's `rc=<n>` is **non-zero**), runs
**exactly one** more fresh probe. A retry that PASSes → PASS; a retry that surfaces a
genuine `auth-failed`/`config-error` → FAIL; a retry that stays no-response (or any
other non-FAIL transient) → UNAVAILABLE. Genuine config FAILs and the already-
environmental UNAVAILABLE cases (quota / stream-error / malformed-output / bare
timeout) are returned on the **first** probe with no retry — the discriminator keys
on the `no-response` prefix that only the step-5 fallthrough emits **and** a non-zero
exit; a **`rc=0` silent-success** `no-response` (CLI exits 0 but produced no token) is
genuine broken-output, **not** a transient, so it stays a single-shot gate-worthy
FAIL with no retry (issue #257 follow-up).

### Evidence line

One machine-readable line per run, consumed by the
[INV-46](invariants.md#inv-46-e2e-runs-once-in-a-dedicated-lane-before-the-review-fan-out--gated-not-per-agent)
command-mode evidence parser:

```
SMOKE <agent> <PASS|FAIL|UNAVAILABLE> <elapsed>s reason=<...>
```

## The matrix harness — `tests/e2e/run-agent-smoke.sh`

- Reads `tests/e2e/e2e.conf` (gitignored, machine-local; commit
  `tests/e2e/e2e.conf.example`). Each entry: `name|agent_cmd|model|env-setup`.
  `env-setup` is `eval`'d in the entry's own subshell (operator-trusted config,
  same trust model as `AGENT_LAUNCHER`).
- `require:VAR;` leading in env-setup: if `VAR` is unset/empty after env-setup
  runs, the entry is **SKIP** (not FAIL) — used for the custom-endpoint entry
  whose API key lives in a local secrets file.
- Entries run **in parallel** — overall wall-clock ≈ slowest entry.
- Aggregation: any FAIL → overall **rc 1**; UNAVAILABLE + SKIP non-blocking;
  final line `SMOKE-SUMMARY pass=N fail=N unavailable=N skip=N`.
- A malformed entry (≠ 4 `|`-fields) or empty matrix → loud reject, rc 1.

### Operator usage (real CLIs on a dev box)

```bash
cp tests/e2e/e2e.conf.example tests/e2e/e2e.conf   # then edit for this box
bash tests/e2e/run-agent-smoke.sh
```

The example matrix covers: claude via Bedrock IAM role, codex via Bedrock IAM
role (with the codex Bedrock region pinned — region pollution was the #180 root
cause), kiro (workspace agent — the entry sets `KIRO_AGENT_NAME` to an agent the
workspace actually defines, since `run_agent`'s kiro branch passes
`--agent "$KIRO_AGENT_NAME"` and a wrong name fails for an invisible config
reason), agy (quota wall → UNAVAILABLE), and claude via a
custom Anthropic-compatible endpoint (`ANTHROPIC_BASE_URL` + `ANTHROPIC_API_KEY`
from a gitignored secrets file, Bedrock vars blanked; `require:ANTHROPIC_API_KEY`
makes it SKIP when the key is absent). Never put real keys in the conf — source
them from a gitignored local file inside env-setup.

### env-setup is the last writer (the #222 [P1] ordering)

When you run the harness from an onboarded project, `lib-agent.sh` auto-loads
that project's `autonomous.conf`, so the smoke inherits the live conf's env
(`AGENT_DEV_EXTRA_ARGS`, `AGENT_PERMISSION_MODE`, per-CLI Bedrock vars, …) — by
design, so the smoke matches the production launch path. The conf assigns those
globals **unconditionally** (`BEDROCK_AWS_REGION=…`, `CLAUDE_CODE_USE_BEDROCK=1`),
so the harness must make the per-entry `env-setup` the **last writer** or the
conf would clobber it. `_run_entry` therefore runs, in order:

1. **source the smoke lib** — `lib-agent.sh` loads `autonomous.conf` (assigning
   the conf globals) and tokenizes `AGENT_LAUNCHER → AGENT_LAUNCHER_ARGV[]`;
2. **neutralize an inherited shared `AGENT_LAUNCHER` for a non-claude entry** —
   the launcher is claude-only (see below), so a shared `cc`-style launcher
   inherited from the conf is cleared for `codex` / `kiro` / `agy` entries here,
   before env-setup, so a healthy non-claude CLI is not falsely FAILed;
3. **neutralize the inherited `AGENT_DEV_EXTRA_ARGS` for every entry** — these
   flags are CLI-specific (kiro's `--trust-all-tools`, gemini's
   `--approval-mode yolo …`), so a conf value tuned for one CLI is wrong for any
   other; cleared here, before env-setup, so a healthy entry is not falsely
   FAILed by another CLI's flags (see below);
4. **eval the entry's `env-setup`** — so an env-setup that pins the codex Bedrock
   region (`BEDROCK_AWS_REGION=us-east-2`) or blanks the custom-endpoint Bedrock
   vars **overrides** the conf value (it ran after the conf load); an env-setup
   `export AGENT_LAUNCHER=…` / `export AGENT_DEV_EXTRA_ARGS=…` here also survives
   the step-2/3 clears, so an entry can opt INTO a CLI-specific launcher / flags;
5. **neutralize an inherited launcher for a custom-endpoint entry** — a claude
   entry that env-setup pointed at a custom endpoint (`ANTHROPIC_BASE_URL` set) is
   still `agent_cmd=claude`, so step 2 did not fire; the inherited Bedrock launcher
   would reintroduce Bedrock / fail before the custom endpoint runs. Cleared here
   (after env-setup, since `ANTHROPIC_BASE_URL` is only known then) **only when
   env-setup did not itself set a launcher** (see below);
6. **re-tokenize the launcher** (`smoke_retokenize_launcher`) — `run_agent` reads
   the pre-tokenized `AGENT_LAUNCHER_ARGV[]`, so an `AGENT_LAUNCHER` set in
   env-setup (or the step-5 clear) is honored only after this re-tokenize.
   (`AGENT_CMD` / `AGENT_TIMEOUT` / `AGENT_DEV_EXTRA_ARGS` are re-read per
   invocation and need no re-tokenize.)

This is the same conf-re-source clobber that [INV-37](invariants.md#inv-37-per-side-agent_cmd-precedence) / [INV-38](invariants.md#inv-38-per-side-agent_launcher-precedence) fix for the dev/review wrappers (the per-side `AGENT_CMD` / launcher rebind must land *after* the lib source). Use the entry's `env-setup` to **override or blank** any conf value you do not want (e.g. the custom-endpoint entry blanks `CLAUDE_CODE_USE_BEDROCK` / `AWS_REGION` / `BEDROCK_AWS_REGION` so claude routes to the custom endpoint, not Bedrock).

### `AGENT_LAUNCHER` is claude-only in the smoke matrix

`AGENT_LAUNCHER` is a claude-only contract ([INV-22](invariants.md#inv-22-agent_launcher-tokenization--claude-only-invocation-contract) / [INV-38](invariants.md#inv-38-per-side-agent_launcher-precedence)): the canonical `cc` launcher ends in `$CLAUDE_CMD "$@"`, so prepending it to a `codex` / `kiro` / `agy` command (`cc codex exec …`) fails. An operator's shared `autonomous.conf` `AGENT_LAUNCHER` is inherited into every entry's subshell, so the harness **clears it for non-claude entries** (step 2 above) to avoid a false `FAIL` on a healthy non-claude CLI. A claude entry keeps the inherited launcher. A non-claude entry that genuinely needs a launcher must set a **CLI-specific** one in its own `env-setup` (`export AGENT_LAUNCHER=…`) — that is honored because it runs after the clear (mirroring [INV-63](invariants.md#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path) sub-rule 7).

**Custom-endpoint exception.** A `claude` entry that env-setup points at a custom Anthropic endpoint (`ANTHROPIC_BASE_URL`, e.g. the `claude-minimax` example) is still `agent_cmd=claude`, so step 2 does NOT clear the inherited launcher — but a Bedrock-specific `cc` launcher would reintroduce Bedrock or fail before the custom endpoint runs, a false `FAIL`. So the harness **also** clears the inherited launcher (step 5 above) for any entry that turned on `ANTHROPIC_BASE_URL`, **unless** env-setup set its own launcher. The committed `claude-minimax` example also clears it explicitly (`export AGENT_LAUNCHER=`) as belt-and-suspenders.

### `AGENT_DEV_EXTRA_ARGS` is per-CLI in the smoke matrix

`run_agent` appends `AGENT_DEV_EXTRA_ARGS` to **every** CLI branch's argv. The operator's `autonomous.conf` tunes it for **one** CLI — `--trust-all-tools` (kiro) or `--approval-mode yolo --output-format stream-json` (gemini). Those flags are CLI-specific, so feeding kiro's `--trust-all-tools` to a `codex` / `claude` / `agy` entry makes that CLI reject the unknown flag → a false `FAIL`. Unlike the launcher (claude-only), no single CLI the shared value is correct for, so the harness **clears `AGENT_DEV_EXTRA_ARGS` for every entry** (step 3 above). An entry that genuinely needs flags opts in via its own `env-setup` (`export AGENT_DEV_EXTRA_ARGS=…`), honored because it runs after the clear (mirroring [INV-63](invariants.md#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path) sub-rule 8 / [INV-31](invariants.md#inv-31-operator-tunable-per-cli-flags-live-in-conf-not-in-lib-agentsh)).

### CI / stub mode (no real CLIs)

```bash
SMOKE_STUB=1 bash tests/e2e/run-agent-smoke.sh
```

Bundles stub CLIs on `PATH` + a stub matrix exercising every branch (PASS, FAIL,
UNAVAILABLE, SKIP), so CI runs the full harness end-to-end without real
CLIs/credentials. This is the E2E artifact for #222.

## Wrapper-free by design

The lib carries **no** wrapper-specific assumptions (no GitHub calls, no wrapper
state) — it needs only `lib-agent.sh` + the three drop-reason libs, sourced by
[INV-14](invariants.md#inv-14-config-lookup-honors-symlink-vendor-pattern)
BASH_SOURCE-relative path. A follow-up issue will consume `smoke_agent` from the
review wrapper as a pre-fan-out gate (Phase A.5) unchanged.

## Cross-references

- [INV-63](invariants.md#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path) — the authoritative invariant.
- [INV-58](invariants.md#inv-58-agy-quota--auth-drops-surface-a-distinct-reason-not-an-opaque-unavailable) / [INV-61](invariants.md#inv-61-kiro-auth-drops-surface-a-distinct-reason-not-an-opaque-unavailable) / [INV-62](invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) — the drop-reason scrapers reused for classification.
- `skills/autonomous-review/references/e2e-command-mode.md` — the command-mode evidence parser the `SMOKE` lines feed.
