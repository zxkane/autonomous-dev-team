# Test cases: `AGENT_REVIEW_TIMEOUT` + browser-E2E exclusion + timeout-veto (INV-48, #185)

The review wrapper is too heavy to run end-to-end, so tests are split across:
a pure-logic harness (sourced libs), source-of-truth greps against
`autonomous-review.sh`, and a behavioral rebind-order simulation that extracts
the wrapper's source/rebind block (same technique as
`test-wrapper-rebind-order.sh`).

## Resolved review cap (rebind)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RTO-RES-01 | `AGENT_REVIEW_TIMEOUT=2h` | review `AGENT_TIMEOUT` = `2h` |
| TC-RTO-RES-02 | `AGENT_REVIEW_TIMEOUT` unset | review `AGENT_TIMEOUT` = `1h` (new default) |
| TC-RTO-RES-03 | `AGENT_REVIEW_TIMEOUT=""` | review `AGENT_TIMEOUT` = `1h` |
| TC-RTO-RES-04 | rebind ordering | rebind survives the conf re-source (after `lib-auth.sh`, before fan-out) — extends `test-wrapper-rebind-order.sh` |
| TC-RTO-RES-05 | dev wrapper | dev `AGENT_TIMEOUT` stays `4h`; dev wrapper does NOT read `AGENT_REVIEW_TIMEOUT` |

## Browser-E2E cap

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RTO-E2E-01 | `E2E_BROWSER_TIMEOUT_SECONDS` unset | defaults to the ORIGINAL `AGENT_TIMEOUT` (4h), NOT the 1h review cap |
| TC-RTO-E2E-02 | `E2E_BROWSER_TIMEOUT_SECONDS=7200` | browser lane cap = `7200` |
| TC-RTO-E2E-03 | browser lane wiring | the browser `run_agent` lane rebinds `AGENT_TIMEOUT` to `E2E_BROWSER_TIMEOUT_SECONDS` and restores it after |
| TC-RTO-E2E-04 | command-mode lane | still uses `E2E_COMMAND_TIMEOUT_SECONDS` (unchanged) |

## Timeout-veto (INV-40 amendment)

`_classify_noverdict_agent <rc>` → `timed-out` for 124/137, else `unavailable`.
`_aggregate_review_verdicts` counts `timed-out` as a deciding FAIL.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RTO-VETO-01 | rc 124 + no verdict | `_classify_noverdict_agent 124` = `timed-out` |
| TC-RTO-VETO-02 | rc 137 + no verdict | `_classify_noverdict_agent 137` = `timed-out` |
| TC-RTO-VETO-03 | rc 1 + no verdict | `_classify_noverdict_agent 1` = `unavailable` (unchanged) |
| TC-RTO-VETO-04 | rc 0 + no verdict | `_classify_noverdict_agent 0` = `unavailable` (unchanged) |
| TC-RTO-VETO-05 | aggregate `pass timed-out` | `fail` (veto) |
| TC-RTO-VETO-06 | aggregate `timed-out` (single) | `fail` (veto, ≥1 deciding) |
| TC-RTO-VETO-07 | aggregate `pass unavailable` | `pass` (unchanged: unavailable dropped) |
| TC-RTO-VETO-08 | aggregate `unavailable unavailable` | `all-unavailable` (unchanged) |
| TC-RTO-VETO-09 | aggregate `timed-out unavailable` | `fail` (veto wins, ≥1 deciding) |
| TC-RTO-VETO-10 | INV-40 existing rows | all stay green (pass/fail/unavailable truth table) |
| TC-RTO-VETO-11 | wrapper wiring | post-window sweep classifies a no-verdict agent via `_classify_noverdict_agent` on its launch rc |

## Startup validation (fail-loud)

`_is_positive_timeout_value <value>` (lib-agent.sh) + `validate_review_timeout_config` (wrapper).

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RTO-VAL-01 | `_is_positive_timeout_value 0` | rejected (rc 1) |
| TC-RTO-VAL-02 | `_is_positive_timeout_value 0h` | rejected |
| TC-RTO-VAL-03 | `_is_positive_timeout_value ""` | rejected |
| TC-RTO-VAL-04 | `_is_positive_timeout_value abc` | rejected |
| TC-RTO-VAL-05 | `_is_positive_timeout_value 1.5h` | rejected |
| TC-RTO-VAL-06 | `_is_positive_timeout_value -5` | rejected |
| TC-RTO-VAL-07 | `_is_positive_timeout_value 90m` | accepted (rc 0) |
| TC-RTO-VAL-08 | `_is_positive_timeout_value 2h` | accepted |
| TC-RTO-VAL-09 | `_is_positive_timeout_value 3600` | accepted (bare seconds) |
| TC-RTO-VAL-10 | `_is_positive_timeout_value 1d` | accepted |
| TC-RTO-VAL-11 | `validate_review_timeout_config` with `AGENT_REVIEW_TIMEOUT=0` | exits non-zero with a clear message |
| TC-RTO-VAL-12 | wrapper wiring | `validate_review_timeout_config` is defined and called at startup; startup log line shows the resolved review cap |

## Source-of-truth / back-compat

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RTO-SRC-01 | rebind present | `_ORIG_AGENT_TIMEOUT="$AGENT_TIMEOUT"` then `AGENT_TIMEOUT="${AGENT_REVIEW_TIMEOUT:-1h}"` |
| TC-RTO-SRC-02 | browser cap default | `E2E_BROWSER_TIMEOUT_SECONDS:-$_ORIG_AGENT_TIMEOUT` |
| TC-RTO-SRC-03 | dev wrapper clean | `autonomous-dev.sh` does NOT mention `AGENT_REVIEW_TIMEOUT` |
| TC-RTO-SRC-04 | conf example | `AGENT_REVIEW_TIMEOUT` and `E2E_BROWSER_TIMEOUT_SECONDS` documented |
| TC-RTO-SRC-05 | wrapper `bash -n` | passes |
| TC-RTO-SRC-06 | `emit_verdict_trailer` count | unchanged (10) — the veto adds no new trailer site |
| TC-RTO-DOC-01 | INV-48 added | invariants.md has an `## INV-48` entry |
| TC-RTO-DOC-02 | INV-40 amended | invariants.md INV-40 mentions `timed-out` deciding FAIL |
| TC-RTO-DOC-03 | flow doc | review-agent-flow.md references the review timeout / browser cap |

## Back-compat suites kept green

`test-wrapper-rebind-order`, `test-autonomous-review-multi-agent`,
`test-agent-timeout-wrapper`, `test-e2e-mode-command`,
`test-review-e2e-command-poll-budget`, `test-autonomous-review-sequential-e2e`,
`test-review-cli-exit-grace`, `test-autonomous-review-mergeable-gate`,
`test-autonomous-review-prompt`, `test-autonomous-review-per-agent-model`,
`test-autonomous-review-per-agent-launcher`.
