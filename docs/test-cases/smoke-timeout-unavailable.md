# Test Cases: smoke timeout → UNAVAILABLE (issue #246, INV-63/64)

Scope: the `_smoke_classify` bare-timeout reclassification (rc 124/137 with no
auth/config scraper signal → UNAVAILABLE, not FAIL) and its propagation through
the Phase A.5 gate (`lib-review-smoke.sh` / `autonomous-review.sh`).

ID formats: `TC-AGENT-SMOKE-NNN` (unit, smoke lib), `TC-REVIEW-SMOKE-NNN`
(gate / wrapper).

## Unit — `_smoke_classify` reclassification (`tests/unit/test-lib-agent-smoke.sh`)

| ID | Scenario | Expected (after fix) | Before fix |
|---|---|---|---|
| TC-AGENT-SMOKE-007a | `claude`, rc 124, empty stdout, no scraper signal | **UNAVAILABLE**; reason names `timeout` | FAIL |
| TC-AGENT-SMOKE-007c | `claude`, rc 137, empty stdout, no scraper signal | **UNAVAILABLE**; reason names `timeout` | FAIL |
| TC-AGENT-SMOKE-007g | `codex`, rc 124, empty capture (no stream-error / config-error) | **UNAVAILABLE** (Bedrock slow-start, the #246 motivating shape) | FAIL |
| TC-AGENT-SMOKE-007h | `kiro`, rc 137, empty capture (no auth signal) | **UNAVAILABLE** | FAIL |
| TC-AGENT-SMOKE-008 | `agy`, rc 124, **quota** signal in `--log-file` | UNAVAILABLE (env signal wins — unchanged) | UNAVAILABLE |
| TC-AGENT-SMOKE-008b | `agy`, rc 124, **clean** log (no signal) | **UNAVAILABLE** (bare timeout) | FAIL |
| TC-AGENT-SMOKE-008c | `kiro`, rc 124, **auth-failed** fixture in capture | **FAIL** (ordering preserved — config/auth signal beats the bare-timeout rule) | FAIL |
| TC-AGENT-SMOKE-008d | `codex`, rc 137, **config-error** fixture in capture (when present) | **FAIL** (ordering preserved) | FAIL |
| TC-AGENT-SMOKE-006a | `claude`, **rc 3** (non-timeout non-zero), no token, no signal | **FAIL**; reason `no-response` (explicitly kept FAIL) | FAIL |

## Unit — `smoke_agent` end-to-end (real `run_agent`, stub CLI)

| ID | Scenario | Expected (after fix) | Before fix |
|---|---|---|---|
| TC-AGENT-SMOKE-007d | A stub CLI that sleeps past a short smoke timeout (hangs) | rc **2** (UNAVAILABLE); evidence `SMOKE <agent> UNAVAILABLE …s reason=timeout …` | rc 1 FAIL |

## Gate — Phase A.5 propagation (`tests/unit/test-autonomous-review-smoke-gate.sh`)

| ID | Scenario | Expected |
|---|---|---|
| TC-REVIEW-SMOKE-070 | `_classify_smoke_state` maps `smoke_agent` rc 2 (timeout-UNAVAILABLE) → `unavailable` state | state `unavailable`; evidence reason carried |
| TC-REVIEW-SMOKE-071 | Gate over `[pass, unavailable]` (one member timed-out → unavailable, one PASS) | `_classify_smoke_gate` → **pass**; survivor list = the PASS member; dropped member surfaced with `smoke: <reason>` breadcrumb; review **proceeds** (no abort) |
| TC-REVIEW-SMOKE-072 | Gate over `[unavailable, unavailable]` (all members timed-out) | `_classify_smoke_gate` → **all-unavailable**; list left unchanged → INV-40 all-unavailable terminal path, **no empty fan-out** |
| TC-REVIEW-SMOKE-073 | Gate over `[fail, pass]` (a genuine config FAIL still present) | `_classify_smoke_gate` → **fail** (abort) — the FAIL→abort path is preserved for real config breakage |

## Notes

- The regression cases (007a/007c/007g/007h, 008b, 007d) MUST fail before the fix
  (they assert UNAVAILABLE where the code returns FAIL) and pass after.
- 008c/008d and 006a are the **preservation** guards: the ordering (scraper
  signal before the bare-timeout step) and the non-timeout `no-response` FAIL are
  unchanged.
- The gate cases (071/072) are the user-visible win: a single slow Bedrock member
  no longer aborts a multi-agent review.
- E2E: the existing `SMOKE_STUB=1 bash tests/e2e/run-agent-smoke.sh` harness
  exercises `smoke_agent` end-to-end through the real `run_agent` with stub CLIs;
  TC-AGENT-SMOKE-007d covers the hang→UNAVAILABLE shell-level end-to-end. No new
  E2E harness is required for a classification-logic change (the issue marks E2E
  optional for this).
