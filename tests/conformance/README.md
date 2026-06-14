# Adapter conformance suite

A standalone, **hermetic** test suite that pins each agent-CLI's
classification contract — the four-axis `AdapterResult`
([`docs/pipeline/adapter-spec.md`](../../docs/pipeline/adapter-spec.md),
[INV-66](../../docs/pipeline/invariants.md#inv-66-adapter-conformance-is-spec-defined)) —
with **fixture manifests** replayed against the current classification logic
using **stub CLIs**. No network, no credentials, no real agent CLIs. Runs on any
fork's plain GitHub-hosted CI. ([INV-73](../../docs/pipeline/invariants.md#inv-73-adapter-conformance-is-regression-pinned-by-a-hermetic-fixture-manifest-runner).)

```
tests/conformance/
├── run-conformance.sh      # the runner
├── lib-conformance.sh      # pure helpers (field extraction, projection, axis diff)
├── fixtures/*.json         # per-adapter × per-mode manifests
└── fixtures/files/*        # sidecar/log content a fixture stages (e.g. the agy quota log)
```

## Run the suite

```bash
# Everything:
bash tests/conformance/run-conformance.sh

# One adapter / one mode:
bash tests/conformance/run-conformance.sh --adapter codex
bash tests/conformance/run-conformance.sh --mode review
bash tests/conformance/run-conformance.sh --adapter agy --mode review
```

Output is one line per fixture plus a summary:

```
CONFORMANCE agy/review/agy-quota-exhausted PASS
CONFORMANCE codex/review/codex-cli-error PASS
CONFORMANCE claude/review/claude-timeout-veto FAIL vote: expected=drop actual=timeout-veto
CONFORMANCE-SUMMARY total=12 pass=11 fail=1
```

The runner exits **non-zero** on any `FAIL` (incl. a malformed manifest, an
unmaterializable stub, or a filter that matched zero fixtures — a fixture that
cannot run is a FAIL, never a silent skip).

`jq` is required. `python3` + `jsonschema` is optional — it makes manifest
validation use the full JSON-Schema Draft-07 semantics. Without it the runner
falls back to a `jq` validator that is a **faithful structural mirror** of
`fixture-manifest.schema.json`: it enforces the SAME required nested fields/types
(`input.promptBytes`/`model`/`env`, `command.argv`/`stdinSha256`/`rc`/`stdout`/
`stderr`, the four `expect` axes, each `files` entry's `path`/`sha256`/`role`) and
the SAME `additionalProperties:false` at every object level. It **fails closed** —
a malformed manifest is rejected on a fork with no `jsonschema` exactly as on a
jsonschema-equipped CI (the two are cross-checked agreeing on the valid set plus
every malformed variant the unit suite drives — see `TC-CONFORMANCE-025e..m`), so
the suite is equally strict in plain CI either way.

## What a fixture is

A fixture manifest conforms to
[`fixture-manifest.schema.json`](../../docs/pipeline/schemas/fixture-manifest.schema.json).
It records one `adapter × mode` behavior:

```jsonc
{
  "schema_version": 1,
  "adapter": "agy",            // claude | codex | kiro | agy | gemini | opencode
  "mode": "review",            // dev-new | dev-resume | review | e2e-browser
  "input": {                   // the invoke() inputs
    "promptBytes": 3500,       // byte-length of the stdin prompt (INV-34)
    "model": "Gemini 3.5 Flash (High)",
    "env": {}                  // env the adapter reads (extra-args, sentinels)
  },
  "command": {                 // the recorded process result the stub replays
    "argv": ["agy","-p","--dangerously-skip-permissions",
             "--print-timeout","<timeout>","--log-file","<logfile>",
             "--model","Gemini 3.5 Flash (High)"],
                               //   LOAD-BEARING: the full argv the adapter
                               //   assembles. The runner asserts the argv the
                               //   dispatch path ACTUALLY launches the stub with
                               //   against this (placeholder-aware — see below);
                               //   a dropped/reordered flag FAILs argv-mismatch.
    "stdinSha256": "d5c930c8…",// LOAD-BEARING: SHA-256 of the bytes fed on stdin.
                               //   The runner feeds a DETERMINISTIC-nonce smoke
                               //   prompt and asserts sha256(stub stdin) == this.
                               //   codex review carries the prompt as an argv
                               //   positional → empty stdin → empty-string hash
                               //   (e3b0c442…). A wrong hash FAILs stdin-sha-mismatch.
    "rc": 0,                   // the CLI exit code
    "stdout": "",              // recorded stdout (use the literal <NONCE> for a
                               //   clean-verdict fixture — see below)
    "stderr": ""               // recorded stderr (a codex/kiro signal may land on
                               //   EITHER stream; the runner scans the combined view)
  },
  "files": {                   // sidecars/logs the stub stages (OPTIONAL)
    "agyLog": { "path": "fixtures/files/agy-quota.log", "role": "log" }
  },
  "expect": {                  // the four AdapterResult axes the adapter MUST produce
    "providerClass": "quota",  // none | quota | auth | config | transient
    "verdictState": "absent",  // valid | absent | malformed
    "vote": "drop",            // pass | fail | drop | timeout-veto | not-applicable
    "retryable": false
  }
}
```

### How the runner replays it

1. Validates the manifest against the schema (loud reject on malformed).
2. Stages any `files{}` content and installs a **stub CLI** (named after the
   binary the adapter invokes — `kiro` ⇒ `kiro-cli`) on an isolated `PATH`. The
   stub emits the recorded `rc`/`stdout`/`stderr`, copies a staged `--log-file`
   into place (the agy quota/auth sidecar contract), and records BOTH the argv it
   was launched with and the bytes it read on stdin.
3. **Drives the REAL dispatch path** — it launches the stub through the
   production invocation primitives (`lib-agent.sh::run_agent` / `resume_agent`,
   or `lib-review-codex.sh::_run_codex_review` for codex review), feeding a
   deterministic-nonce smoke prompt over the
   [INV-34](../../docs/pipeline/invariants.md#inv-34-agent-prompt-is-fed-via-stdin-never-as-a-single-argv-element)
   stdin channel. The classification is **env-hermetic**: the operator-facing
   surface lib-agent.sh reads (`AGENT_DEV_EXTRA_ARGS` / `AGENT_REVIEW_EXTRA_ARGS`,
   `AGENT_LAUNCHER` / `AGENT_*_LAUNCHER`, `AGENT_*_CMD`) is reset to an empty
   baseline before the lib is sourced, and the conf-discovery surface
   (`AUTONOMOUS_CONF`, `AUTONOMOUS_CONF_DIR`, `PROJECT_DIR`) is pointed at
   conf-free paths so `load_autonomous_conf` finds no operator conf on any of its
   three branches. An inherited operator env — including a project's real
   `autonomous.conf` reachable via `AUTONOMOUS_CONF_DIR` or `PROJECT_DIR` — can't
   leak extra argv or route through a launcher; only the fixture's `input.env`
   (applied after the scrub) influences the run. The runner is self-defending and
   does not require the caller to pre-scrub the environment.
4. **Asserts the manifest's `command.argv` and `command.stdinSha256` are
   correct** — the stub-recorded argv MUST match `command.argv` (placeholder-aware)
   and `sha256(stdin)` MUST match `command.stdinSha256`. A regression in how the
   adapter assembles argv or feeds the prompt FAILs the fixture
   (`argv-mismatch` / `stdin-sha-mismatch`) — these fields are load-bearing, not
   documentary.
5. Runs the captured process result through the **real** classification path —
   `lib-agent-smoke.sh::_smoke_classify` + the per-CLI
   `_classify_<cli>_drop_reason` scrapers — then projects the result onto the
   four axes and diffs against `expect{}`.

### argv placeholders

`command.argv` records the FULL argv the adapter assembles. Per-run values the
adapter fills in are written as placeholders the runner matches structurally
(not as fixed literals):

| Placeholder         | Matches                                              |
|---------------------|------------------------------------------------------|
| `<uuid>`            | a v4 UUID (claude `--session-id`)                    |
| `<prompt>`          | the positional prompt (codex `review "<prompt>"`)    |
| `<logfile>`         | a `*.log` path (agy `--log-file`)                    |
| `<permission-mode>` | the runtime `AGENT_PERMISSION_MODE` (claude)         |
| `<timeout>`         | a coreutils-`timeout` duration, e.g. `4h` (agy)      |

Every other element is matched literally. The codex `config`-error fixture
sets `input.env.AGENT_DEV_EXTRA_ARGS` so the adapter splices the offending flag
(`-s danger-full-access`) into the argv exactly as the recorded `command.argv`.

### The `<NONCE>` placeholder

A "clean verdict" (PASS) fixture must round-trip the model nonce just as a
healthy CLI would. Put the literal token `<NONCE>` in `command.stdout`; the
runner substitutes its **deterministic** nonce before the stub emits it, so the
classifier sees the model "echo the token" and classifies PASS. A failure
fixture leaves `stdout` empty (or carries the error text) and does **not**
include `<NONCE>`. The nonce is deterministic precisely so the stdin hash is
reproducible and `command.stdinSha256` can be pinned.

## Authoring a manifest (CLI vendors)

To add your CLI to the suite (or pin a new behavior of an existing one):

1. **Capture the real shapes.** Run your CLI under each mode and record the
   exact `argv`, `rc`, `stdout`, `stderr`, and any sidecar/log file for: a clean
   verdict, a quota/auth/config/transient failure, and a timeout. Sanitize
   anything sensitive (tokens, account ids, real domains).
2. **Write one manifest per behavior** under `tests/conformance/fixtures/` (name
   them `<adapter>-<behavior>.json`). Record the FULL `command.argv` (use the
   placeholders above for per-run values) and the `command.stdinSha256` — both are
   asserted, so an easy way to get them right is to run the suite once with a
   placeholder hash, read the `argv-mismatch` / `stdin-sha-mismatch` FAIL lines
   (they print the recorded argv and the actual hash), and paste those in. Use
   `<NONCE>` in `command.stdout` for the clean-verdict fixture; stage any log under
   `fixtures/files/` and reference it from `files{}`.
3. **Fill `expect{}`** from the [adapter-spec §4.4 derivation](../../docs/pipeline/adapter-spec.md#44-voteeligibility--state-reason):
   a clean verdict ⇒ `none/valid/pass`; a 429 ⇒ `quota/absent/drop` (`retryable:false`);
   a login failure ⇒ `auth/absent/drop`; a structural prep/arg error ⇒
   `config/absent/drop`; a retryable upstream blip ⇒ `transient/absent/drop`
   (`retryable:true`); a timed-out review (rc 124/137) with no verdict ⇒
   `none/absent/timeout-veto`; any dev/e2e mode ⇒ `vote:not-applicable`.
4. **Run `bash tests/conformance/run-conformance.sh --adapter <yours>`** until it
   is green. Then add a per-CLI scraper (`_classify_<cli>_drop_reason`) if your
   provider signal is not yet recognized — the conformance FAIL tells you which
   axis is wrong.

A new CLI is **admitted** to the fan-out only once it carries ≥2 conformance
manifests and the suite stays green.

## Scope

- **In scope**: the hermetic, credential-free regression tier for the per-CLI
  classification contract.
- **Out of scope**: live-CLI smoke (that is `tests/e2e/run-agent-smoke.sh`,
  [INV-63](../../docs/pipeline/invariants.md#inv-63-agent-smoke-is-a-three-state-probe-pass--unavailable--fail-run-through-the-production-run_agent-never-a-parallel-invocation-path),
  the separate self-hosted tier); the adapter extraction itself (a later issue);
  gemini/opencode manifests (addable later — not fan-out members today).
