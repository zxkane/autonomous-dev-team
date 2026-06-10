# Test cases: kiro auth/login failure drop reason (INV-61, #215)

Mirrors the INV-58 (agy) / INV-59 (codex) drop-reason test plans. Regression tests
FAIL before the fix (no kiro branch → a kiro auth-failure reads identically to a
launch failure; a fan-out dropping BOTH agy and kiro lists a reason only for agy)
and PASS after.

## Unit — `tests/unit/test-lib-review-kiro.sh`

### `_classify_kiro_drop_reason`

| ID | Scenario | Expected |
|----|----------|----------|
| TC-KIRO-DROP-CLS-01 | Log containing `Failed to open browser for authentication` / `kiro-cli login --use-device-flow` lines | echoes `auth-failed`, rc 0 |
| TC-KIRO-DROP-CLS-02 | Log with NO auth signal (clean no-verdict kiro turn) | echoes empty (no over-claim), rc 0 |
| TC-KIRO-DROP-CLS-03a | Empty log | empty, rc 0 |
| TC-KIRO-DROP-CLS-03b | Missing log path | empty, rc 0 |
| TC-KIRO-DROP-CLS-03c | Empty arg | empty, rc 0 |
| TC-KIRO-DROP-CLS-04 | Each individual signal substring alone (`Failed to open URL`, `--use-device-flow`, `kiro-cli login`) | echoes `auth-failed`, rc 0 |
| TC-KIRO-DROP-CLS-05 | Committed fixture (sanitized real auth-failure log) | echoes `auth-failed`, rc 0 |
| TC-KIRO-DROP-CLS-06 | Command-substitution call under `set -euo pipefail` | `rc=0\|auth-failed`, no abort |
| TC-KIRO-DROP-CLS-07 | **BARE** call (not command-subst) under `set -euo pipefail` on a signal log | reaches `return 0` without errexit abort (the CLS-08-style dual-call guard) |

### `_kiro_drop_reason_phrase`

| ID | Scenario | Expected |
|----|----------|----------|
| TC-KIRO-DROP-PHR-01 | token `auth-failed` | clause naming `kiro-cli login --use-device-flow` |
| TC-KIRO-DROP-PHR-02 | empty token | empty phrase |
| TC-KIRO-DROP-PHR-03 | unknown token | empty phrase |

### Source-of-truth (wrapper wiring)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-KIRO-DROP-SRC-01 | wrapper sources `lib-review-kiro.sh` | grep hit |
| TC-KIRO-DROP-SRC-02 | wrapper captures `AGENT_KIRO_LOGS` | grep hit |
| TC-KIRO-DROP-SRC-03 | wrapper calls `_classify_kiro_drop_reason` | grep hit |
| TC-KIRO-DROP-SRC-04 | wrapper interpolates `_kiro_drop_reason_phrase` | grep hit |
| TC-KIRO-DROP-SRC-05a | `lib-review-kiro.sh` parses `bash -n` | clean |
| TC-KIRO-DROP-SRC-05b | `autonomous-review.sh` parses `bash -n` | clean |
| TC-KIRO-DROP-SRC-06 | CI shellcheck job lists `lib-review-kiro.sh` | grep hit |

### Behavioral — drop-reason assembly loop (mirrors the wrapper body)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-KIRO-DROP-LOOP-01 | kiro dropped on an auth-failure log | reason names `kiro: auth-failed` |
| TC-KIRO-DROP-LOOP-02 | kiro dropped on a generic/no-signal log | empty reason (bare `unavailable`) |
| TC-KIRO-DROP-LOOP-03 | BOTH agy (quota) AND kiro (auth) dropped in ONE fan-out | a DISTINCT clause for each (`agy: quota-exhausted` + `kiro: auth-failed`) |
| TC-KIRO-DROP-LOOP-04 | a non-kiro/non-agy/non-codex unavailable agent (e.g. claude) | adds no reason |

### Regression

| ID | Scenario | Expected |
|----|----------|----------|
| TC-KIRO-DROP-REG-01 | auth-failure drop classifies DISTINCTLY from a generic/no-verdict drop | distinct + non-empty |
| TC-KIRO-DROP-REG-02 | a clean no-verdict turn is NOT misreported as auth-failed | empty |

## Behavioral / source-of-truth (extend `tests/unit/test-autonomous-review-multi-agent.sh`)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-MAR-SRC-15 | wrapper sources `lib-review-kiro.sh`, captures `AGENT_KIRO_LOGS`, calls `_classify_kiro_drop_reason` + interpolates `_kiro_drop_reason_phrase` | grep hits |

## Backward-compat

Existing multi-agent / agy / codex drop-reason tests stay green. A non-kiro drop
and a signal-free kiro drop both keep the bare `unavailable` wording.

## Fixture

`tests/unit/fixtures/kiro-auth-failed.fixture` — a sanitized real kiro auth-failure
log (the four signal lines from the issue).
