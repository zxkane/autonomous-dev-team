# Test cases: command-mode E2E review poll/stall budget (#172)

Test file: `tests/unit/test-review-e2e-command-poll-budget.sh`

Strategy mirrors the existing review tests: a **pure-logic harness** for the new
`_resolve_verdict_poll_attempts` resolver (sourced from the wrapper without
running it) plus **source-of-truth greps** against `autonomous-review.sh` for the
structural pieces, and **doc-presence** assertions for the Fix-D documentation.

The full wrapper is too heavy to run end-to-end (it spawns agents and calls
`gh`), so we follow the established `test-autonomous-review-multi-agent.sh` /
`test-e2e-mode-command.sh` pattern.

## Poll-budget resolver (`_resolve_verdict_poll_attempts`)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RPB-RES-01 | `E2E_MODE` unset | `6` (legacy 30 s) |
| TC-RPB-RES-02 | `E2E_MODE=none` | `6` |
| TC-RPB-RES-03 | `E2E_MODE=browser` | `6` |
| TC-RPB-RES-04 | `E2E_MODE=command`, `E2E_COMMAND_TIMEOUT_SECONDS=3600` | `> 6` and `≥ ceil(3600/5)` (≥ 720) |
| TC-RPB-RES-05 | `E2E_MODE=command`, `E2E_COMMAND_TIMEOUT_SECONDS=2700` | `≥ ceil(2700/5)` (≥ 540) |
| TC-RPB-RES-06 | `E2E_MODE=command`, `E2E_COMMAND_TIMEOUT_SECONDS` unset (default 3600) | `≥ 720` |
| TC-RPB-RES-07 | `E2E_MODE=command`, tiny timeout `E2E_COMMAND_TIMEOUT_SECONDS=10` | `≥ 6` (never below the legacy floor) |
| TC-RPB-RES-08 | `E2E_MODE=command`, non-numeric `E2E_COMMAND_TIMEOUT_SECONDS=abc` | `6` (defensive fallback to legacy) |
| TC-RPB-RES-09 | `E2E_MODE=command`, `E2E_COMMAND_TIMEOUT_SECONDS=0` | `6` (zero/disabled → legacy floor) |

## Wrapper structure (source-of-truth greps)

| ID | Assertion |
|----|-----------|
| TC-RPB-SRC-01 | wrapper defines `_resolve_verdict_poll_attempts()` |
| TC-RPB-SRC-02 | poll loop uses the resolved attempts var (`seq 1 "$_VERDICT_POLL_ATTEMPTS"`), NOT a hardcoded `seq 1 6` |
| TC-RPB-SRC-03 | resolver references `E2E_COMMAND_TIMEOUT_SECONDS` |
| TC-RPB-SRC-04 | wrapper defines a reap helper (`_reap_fanout_processes`) that group-kills collected fan-out PIDs |
| TC-RPB-SRC-05 | reap step is invoked after verdict resolution (the call site exists) |
| TC-RPB-SRC-06 | reap uses negative-PID group kill (`kill -TERM -- -` form) — INV-23 semantics |
| TC-RPB-SRC-07 | `build_review_prompt` receives a multi-agent signal arg |
| TC-RPB-SRC-08 | command-mode prompt instructs re-checking sibling SHA evidence immediately before pre-hooks when multi-agent |
| TC-RPB-SRC-09 | wrapper references INV-43 |
| TC-RPB-SRC-10 | wrapper passes `bash -n` |

## Regression / back-compat (source-of-truth)

| ID | Assertion |
|----|-----------|
| TC-RPB-REG-01 | no remaining hardcoded `for _poll_attempt in $(seq 1 6)` (the literal-6 loop is gone) |
| TC-RPB-REG-02 | `_VERDICT_POLL_ATTEMPTS` defaults via the resolver so a non-command project still gets 6 |
| TC-RPB-REG-03 | the existing `_aggregate_review_verdicts` import and call are unchanged (no INV-40 regression) |
| TC-RPB-REG-04 | `emit_verdict_trailer` call count is still 6 (no new trailer sites) |

## Documentation (Fix D — AC 4)

| ID | Assertion |
|----|-----------|
| TC-RPB-DOC-01 | `references/e2e-command-mode.md` documents `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS` vs `E2E_COMMAND_TIMEOUT_SECONDS` |
| TC-RPB-DOC-02 | `references/e2e-command-mode.md` documents the auto-scaled verdict-poll budget |
| TC-RPB-DOC-03 | `references/e2e-command-mode.md` documents the duplicated-pre-hook caveat + SHA-evidence reuse |
| TC-RPB-DOC-04 | `docs/pipeline/invariants.md` has an `INV-43` entry |
| TC-RPB-DOC-05 | `docs/pipeline/review-agent-flow.md` references INV-43 |
| TC-RPB-DOC-06 | `autonomous.conf.example` cross-references the two windows |

## Existing suites that MUST stay green (no regression)

- `tests/unit/test-autonomous-review-multi-agent.sh`
- `tests/unit/test-e2e-mode-command.sh`
- `tests/unit/test-autonomous-review-prompt.sh`
- `tests/unit/test-autonomous-review-per-agent-model.sh`
- `tests/unit/test-autonomous-review-verdict-trailer.sh`
