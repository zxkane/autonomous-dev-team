# Design Canvas — Standalone Conformance Runner (issue #230)

```
status: autonomous-mode design (no interactive gate)
implements: docs/pipeline/adapter-spec.md §8 (fixture manifest) + INV-66
adds: INV-73 (conformance suite pins TODAY's per-CLI classification)
```

## Problem

Per-CLI quirk handling is the largest historical bug factory in this repo (~14
issues: every CLI lies differently at the exit-code level — `agy` rc-0 silent
quota, `kiro` headless-auth exit-0, `codex` rc-2 clap vs transient stream-error).
Today its only tests are scattered per-bug unit tests (`test-lib-review-agy.sh`,
`test-lib-review-codex.sh`, `test-lib-review-kiro.sh`, `test-lib-agent-smoke.sh`).
There is **no single suite** that makes each CLI's contract explicit and
regression-pinned, gives new-CLI admission an objective bar, or acts as the
safety net under the later adapter extraction (#232).

#229 (merged, PR #239) authored the **fixture-manifest schema**
(`docs/pipeline/schemas/fixture-manifest.schema.json`) and the four-axis
`AdapterResult` it points at — but explicitly left the *runner that replays
manifests against the real classification path* as this follow-up (§8:
"The standalone conformance runner … is a **follow-up issue** and is out of
scope here").

## What we build

`tests/conformance/run-conformance.sh [--adapter X] [--mode Y]` — a hermetic,
manifest-driven suite that:

1. **Loads** `tests/conformance/fixtures/*.json` (each conforming to the #229
   `fixture-manifest.schema.json`), filtered by optional `--adapter` / `--mode`.
2. **Validates** each manifest against the schema (loud reject on malformed —
   reusing the #229 python-jsonschema-or-jq-fallback validation approach so it
   stays green in plain CI with or without `jsonschema` installed).
3. **Materializes** the fixture: stages any `files{}` (logs / sidecars) into a
   per-fixture temp root, and installs a **stub CLI** on `PATH` that emits the
   recorded `command.{rc,stdout,stderr}` and (for `agy`) writes the staged log
   into the `--log-file` path it is handed — so the recorded process result is
   what the classification path observes.
4. **Invokes the REAL classification path** — `lib-agent-smoke.sh::_smoke_classify`
   plus the per-CLI scrapers it dispatches to
   (`_classify_agy_drop_reason` / `_classify_kiro_drop_reason` /
   `_classify_codex_drop_reason`). This is **TODAY's monolithic classification
   logic**, by design (issue "Design Considerations"): pin current behavior so
   the later adapter extraction must preserve it (green → refactor → still green).
5. **Projects** the classifier output onto the four `expect{}` axes
   (`providerClass`, `verdictState`, `vote`, `retryable`) and asserts equality,
   emitting one line per fixture:
   `CONFORMANCE <adapter>/<mode>/<name> PASS|FAIL <axis-diff>`.
   Non-zero exit on any FAIL.

## Why `_smoke_classify` is the classification path under test

The adapter-spec's `invoke() → AdapterResult` four-axis entry point does **not
exist as code yet** (INV-66 status: "SPEC ONLY — NOT YET ENFORCED in code"). The
spec is explicit that the runner "tests TODAY's monolithic classification logic
first." Today the single function that maps `(agent, rc, stdout, stderr, log)` →
a classified state is `lib-agent-smoke.sh::_smoke_classify` (INV-63), which:

- reads **stdout only** for the success signal (the verdict-present axis),
- dispatches to the per-CLI **provider scrapers** for the quota/auth/config/
  transient signal,
- maps rc 124/137 → timeout.

The runner therefore drives `_smoke_classify` (and, for the per-CLI
provider-classification axis, the scrapers directly) and maps its
`STATE|reason` + the scraper token to the four-axis projection. When #232 moves
this logic behind a real `invoke()`, the runner re-points at that entry point
with **zero fixture changes** — the fixtures are the contract.

### Projection table (classifier output → four-axis `expect`)

| classifier signal | providerClass | verdictState | vote | retryable |
|---|---|---|---|---|
| PASS (nonce echoed, rc 0) — review | none | valid | pass | false |
| `[P1]` in review stdout (rc 0) — review | none | valid | fail | false |
| `quota-exhausted*` token | quota | absent | drop | false |
| `auth-failed` token | auth | absent | drop | false |
| `config-error*` token | config | absent | drop | false |
| `stream-error*` token | transient | absent | drop | **true** |
| rc 124/137, no verdict — review | none | absent | timeout-veto | false |
| rc 0, no verdict, no signal — review | none | absent | drop | false |
| dev-new / dev-resume / e2e (any) | none | absent\|valid | not-applicable | false |

The `vote` axis for review-no-verdict is derived per adapter-spec §4.4: the
projection consults `process.timedOut` (rc∈{124,137}) to split `timeout-veto`
from `drop`, exactly as the schema's conditionals do. `retryable` is the
spec's per-class recovery flag (`transient` ⇒ true; `quota`/`auth`/`config` ⇒
false until the operator acts).

## Hermeticity guarantee

- `PATH` is reset to a stub-only sandbox dir for the duration of each fixture's
  classification; the real CLIs (`claude`/`codex`/`kiro`/`agy`) are **never** on
  it. A fixture whose stub binary is missing fails **loud**
  (`CONFORMANCE … FAIL stub-missing`), never falls through to a real CLI.
- No network, no credentials, no `gh`. The classification path is pure shell +
  `grep`; the scrapers read only local files.
- The runner proves the **INV-34 stdin-fed-prompt contract**: the stub records
  the bytes it receives on stdin, and the runner asserts the prompt actually
  reached the stub over that channel (a stub that read nothing → loud
  `CONFORMANCE … FAIL stdin-not-fed`). It does **not** byte-compare against
  `command.stdinSha256`: the runner feeds a freshly-built smoke prompt carrying a
  live per-call nonce (so a PASS fixture round-trips the nonce exactly as a healthy
  CLI would), not the manifest's recorded prompt, so a fixed recorded hash could
  never match the live bytes. `command.stdinSha256` is schema-validated as a 64-hex
  digest (manifest well-formedness) but is the prompt-fixture's recorded identity,
  not a runtime assertion target. `<prompt>`/`<uuid>`/`<logfile>` placeholder argv
  elements are treated as wildcards (the spec records them as placeholders).

## Files

| File | Role |
|---|---|
| `tests/conformance/run-conformance.sh` | The runner (loader, stub materialization, classification, axis diff). |
| `tests/conformance/lib-conformance.sh` | Pure helpers (manifest field extraction, projection, axis diff) — unit-testable in isolation, mirrors the `lib-review-*.sh` split. |
| `tests/conformance/fixtures/*.json` | Promoted manifests (≥2 per fan-out CLI). |
| `tests/conformance/README.md` | How a CLI vendor authors a manifest + runs the suite standalone. |
| `tests/unit/test-conformance-runner.sh` | Unit tests for the runner/lib (loading, filtering, diff, hermeticity, malformed reject). |
| `.github/workflows/ci.yml` | New always-on `conformance` step in the existing `unit-tests` job. |
| `docs/pipeline/invariants.md` | New **INV-73**. |

## Promoted fixtures (≥2 per fan-out CLI: claude, codex, kiro, agy)

| Fixture | adapter/mode | expect (provider/verdict/vote/retryable) |
|---|---|---|
| `claude-happy-path` | claude/review | none / valid / pass / false |
| `claude-timeout-veto` | claude/review | none / absent / timeout-veto / false (rc 124) |
| `claude-dev-new` | claude/dev-new | none / absent / not-applicable / false |
| `codex-review-clean` | codex/review | none / valid / pass / false |
| `codex-stream-error` | codex/review | transient / absent / drop / **true** |
| `codex-cli-error` | codex/review | config / absent / drop / false (clap rc 2) |
| `kiro-auth-failed` | kiro/review | auth / absent / drop / false |
| `kiro-happy-path` | kiro/review | none / valid / pass / false |
| `agy-quota-exhausted` | agy/review | quota / absent / drop / false |
| `agy-happy-path` | agy/review | none / valid / pass / false |

(gemini/opencode manifests are out of scope — not fan-out members today.)

## Out of scope (per issue)

- The adapter extraction itself (#232).
- Live-CLI smoke (#222 / `tests/e2e/run-agent-smoke.sh` is the separate
  self-hosted tier).
- gemini / opencode manifests.
```
