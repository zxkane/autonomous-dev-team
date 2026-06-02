# Test Cases: per-agent launcher resolution for the review fan-out (#173)

Covers INV-42 (per-agent `AGENT_REVIEW_LAUNCHER_<AGENT>` resolution) layered on
the INV-40 multi-agent review fan-out and the INV-41 per-agent model/extra-args
resolution. The wrapper is too heavy to run end-to-end, so testing is three
pronged (mirrors `test-autonomous-review-per-agent-model.sh`):

1. **Pure helper harness** — source `lib-review-resolve.sh` and drive
   `_resolve_review_agent_launcher` over the normalization + precedence matrix.
2. **Fan-out branch harness** — extract the three-branch decision logic and
   drive it directly so the *applied / keep-claude / cleared-non-claude* outcomes
   are exercised as behavior, not just greps.
3. **Source-of-truth greps** — assert the structural wiring in
   `autonomous-review.sh` without executing the wrapper.

Test file: `tests/unit/test-autonomous-review-per-agent-launcher.sh`.

## Pure helper: `_resolve_review_agent_launcher` (precedence)

Precedence: `AGENT_REVIEW_LAUNCHER_<SUFFIX>` (per-agent, set AND non-empty) →
**empty**. Unlike `_resolve_review_agent_model`, there is **no fallback to the
shared `AGENT_REVIEW_LAUNCHER`**: the shared launcher is claude-only by INV-38
and must not auto-apply to a non-claude per-agent slot (see design doc / INV-42).

| ID | Env | Agent | Expected |
|----|-----|-------|----------|
| TC-PAL-RES-01 | `AGENT_REVIEW_LAUNCHER_CODEX="bridge --"`, no shared | `codex` | `bridge --` (per-agent value) |
| TC-PAL-RES-02 | only shared `AGENT_REVIEW_LAUNCHER="cc-bridge --"`, no per-agent key | `codex` | `` (empty — shared does NOT auto-apply) |
| TC-PAL-RES-03 | `AGENT_REVIEW_LAUNCHER_CODEX=""` (explicit empty), shared set | `codex` | `` (empty — explicit empty resolves to empty, no shared fallback) |
| TC-PAL-RES-04 | `AGENT_REVIEW_LAUNCHER_GPT_5="x --"` | `gpt-5` | `x --` (suffix normalization `gpt-5`→`GPT_5` wires the right key) |
| TC-PAL-RES-05 | per-agent set for `codex`, querying a sibling | `kiro` | `` (sibling has no key → empty) |
| TC-PAL-RES-06 | per-agent multi-token value with quotes | `codex` | value preserved verbatim (tokenized downstream by the fan-out `eval`) |

## Fan-out branch harness: the three branches

Replicates the fan-out subshell's launcher decision as a standalone function
sourced with `lib-review-resolve.sh`, then drives each branch. The harness sets
`AGENT_LAUNCHER_ARGV` to a sentinel "shared" value first (mimicking the wrapper's
rebind), runs the branch for `$_agent`, and reports the resulting argv.

| ID | Setup | Agent | Expected resulting `AGENT_LAUNCHER_ARGV[*]` |
|----|-------|-------|---------------------------------------------|
| TC-PAL-BR-01 | `AGENT_REVIEW_LAUNCHER_CODEX="echo CODEX_LAUNCHED --"` | `codex` | `echo CODEX_LAUNCHED --` (per-agent applied; INV-38 bypassed) |
| TC-PAL-BR-02 | no per-agent key; shared argv = `cc --` | `claude` | `cc --` (claude keeps the shared launcher) |
| TC-PAL-BR-03 | no per-agent key; shared argv = `cc --` | `kiro` | `` (non-claude cleared — INV-38 zeroing) |
| TC-PAL-BR-04 | `AGENT_REVIEW_LAUNCHER_KIRO="wrap --"` | `kiro` | `wrap --` (per-agent applied to a non-claude CLI; INV-38 bypassed for it) |
| TC-PAL-BR-05 | `AGENT_REVIEW_LAUNCHER_CODEX="(unterminated"` (malformed) | `codex` | `` + an ERROR log line (tokenize failure → naked) |

## Source-of-truth greps (against `autonomous-review.sh` + `lib-review-resolve.sh`)

| ID | Assertion |
|----|-----------|
| TC-PAL-SRC-01 | fan-out resolves a per-agent launcher (`_resolve_review_agent_launcher`) inside the subshell |
| TC-PAL-SRC-02 | fan-out tokenizes the resolved launcher into `AGENT_LAUNCHER_ARGV` via `eval` |
| TC-PAL-SRC-03 | the INV-38 non-claude `AGENT_LAUNCHER_ARGV=()` zeroing survives as the `elif` fallback (no per-agent key + non-claude) |
| TC-PAL-SRC-04 | tokenize-failure path emits a log line and falls back to `AGENT_LAUNCHER_ARGV=()` |
| TC-PAL-SRC-05 | `_resolve_review_agent_launcher` defined in `lib-review-resolve.sh` |
| TC-PAL-SRC-06 | resolver does NOT fall back to the shared `AGENT_REVIEW_LAUNCHER` (no `${AGENT_REVIEW_LAUNCHER` reference in the function body) |
| TC-PAL-SRC-07 | `bash -n` clean on the wrapper |
| TC-PAL-SRC-08 | `autonomous.conf.example` documents `AGENT_REVIEW_LAUNCHER_<AGENT>` with a `codex` example |

## Regression test (must FAIL before the fix, PASS after)

| ID | Assertion |
|----|-----------|
| TC-PAL-REG-01 | With `AGENT_REVIEW_AGENTS="kiro codex"` + `AGENT_REVIEW_LAUNCHER_CODEX="echo CODEX_LAUNCHED --"`, the captured argv for the **codex** member starts with `echo CODEX_LAUNCHED` (proves the launcher was applied and not zeroed by the old unconditional non-claude branch). The same harness confirms the **kiro** member (no per-agent key) is still zeroed. |

## Backward-compatibility regression gate (no per-agent launcher keys set)

The full pre-existing sweep stays green:
`test-autonomous-review-multi-agent` (incl. TC-MAR-SRC-07 non-claude zeroing),
`test-autonomous-review-per-agent-model`, `test-autonomous-review-prompt`,
`test-lib-agent-per-side-launcher`, `test-lib-agent-per-side-cmd`,
`test-autonomous-launcher-verdict-fresh`, plus `bash -n`.

## Acceptance mapping

- AC "`_resolve_review_agent_launcher` mirrors `_resolve_review_agent_model`
  precedence (per-agent → empty), unit-tested in isolation" → TC-PAL-RES-01..06.
- AC "fan-out applies the resolved per-agent launcher; falls back to INV-38
  zeroing when unset; tokenize failure logs + naked" → TC-PAL-BR-01..05,
  TC-PAL-SRC-01..04.
- AC "N=1 byte-for-byte unchanged when no keys set" → TC-PAL-BR-02/03 +
  regression gate.
- AC "`AGENT_REVIEW_AGENTS=\"kiro agy\"` (no per-agent launchers) unchanged" →
  TC-PAL-BR-03 + regression gate.
- AC "regression: codex argv starts with the launcher" → TC-PAL-REG-01.
- AC "conf.example shows a working `AGENT_REVIEW_LAUNCHER_CODEX`" → TC-PAL-SRC-08.
