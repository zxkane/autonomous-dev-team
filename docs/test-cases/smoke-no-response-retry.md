# Test Cases: smoke `no-response` retry-once → UNAVAILABLE (issue #257, INV-75)

Scope: the `smoke_agent` driver-level **retry-once** of a step-5 bare `no-response`
FAIL (rc≠0, nonce absent, no per-CLI scraper signal) and its propagation through the
Phase A.5 gate (`lib-review-smoke.sh` / `autonomous-review.sh`). `_smoke_classify`
stays a pure single-probe function; the retry lives in `smoke_agent`.

ID formats: `TC-AGENT-SMOKE-NNN` (unit, smoke lib), `TC-REVIEW-SMOKE-NNN`
(gate / wrapper).

## Unit — `smoke_agent` retry-once driver (`tests/unit/test-lib-agent-smoke.sh`)

These drive the **real `run_agent`** with a stub CLI whose behavior differs across
the first and second invocation (a counter file in a temp dir tracks which probe is
running) so the retry path is exercised end-to-end.

| ID | Scenario | Expected (after fix) | Before fix |
|---|---|---|---|
| TC-AGENT-SMOKE-075a | Stub CLI: probe #1 exits rc≠0 with **no** token / **no** scraper signal, probe #2 **also** no-response | rc **2** (UNAVAILABLE); evidence `SMOKE <agent> UNAVAILABLE …s reason=no-response (rc=…; no nonce after retry — transient infra)` | rc **1** FAIL (regression — MUST fail before fix) |
| TC-AGENT-SMOKE-075b | Stub CLI: probe #1 no-response, probe #2 **echoes the nonce** (rc 0) | rc **0** (PASS); evidence `SMOKE <agent> PASS …s reason=nonce-ok` | rc 1 FAIL (first probe FAILs, no retry) |
| TC-AGENT-SMOKE-075c | Stub `codex`: probe #1 emits an **`auth-failed`/`config-error`** scraper signal | rc **1** (FAIL) on the **first probe, NO retry**; evidence is a FAIL carrying the scraper phrase (not `no-response`) | FAIL (unchanged) |
| TC-AGENT-SMOKE-075d | Stub CLI: bare timeout (sleeps past a short smoke timeout) → rc 124/137 | rc **2** (UNAVAILABLE), reason `timeout …`, **NO retry** (INV-67 unchanged) | rc 2 UNAVAILABLE (unchanged) |
| TC-AGENT-SMOKE-075e | Stub `agy`: probe #1 writes the **quota** fixture to `--log-file`, exits empty | rc **2** (UNAVAILABLE), quota reason, **NO retry** (env signal wins) | rc 2 UNAVAILABLE (unchanged) |
| TC-AGENT-SMOKE-075f (bound) | Same stub as 075a; assert the stub was invoked **exactly twice** (probe + one retry — never a third) | invocation counter == **2** | (n/a — no retry existed) |
| TC-AGENT-SMOKE-075g | Stub CLI: probe #1 no-response, probe #2 surfaces a genuine **`config-error`** signal | rc **1** (FAIL) — the retry exposed real operator-side breakage; do NOT mask it as UNAVAILABLE | (n/a) |
| TC-AGENT-SMOKE-075j | Stub `claude`: probe #1 exits **`rc=0`** with **no** token / **no** scraper signal (silent success) | rc **1** (FAIL), evidence `SMOKE claude FAIL`, **NO retry** (stub ran exactly 1×) — `rc=0` no-response is genuine broken-output, not a transient (issue #257 review follow-up) | rc **2** UNAVAILABLE, retried (regression — MUST fail before the rc-guard fix) |
| TC-AGENT-SMOKE-075k | `_smoke_is_transient_no_response FAIL "no-response (rc=0; …)"` vs `"… (rc=4; …)"` | rc=0 reason → **NOT transient** (predicate rc 1, no retry); rc=4 reason → **transient** (predicate rc 0, retry) | rc=0 wrongly transient (predicate rc 0) |

## Unit — `_smoke_classify` purity (regression guard, `tests/unit/test-lib-agent-smoke.sh`)

The pure decision function is unchanged for a single probe — these guard that the
fix did NOT alter `_smoke_classify`'s per-probe verdicts.

| ID | Scenario | Expected |
|---|---|---|
| TC-AGENT-SMOKE-075h | `_smoke_classify <agent> 3 <empty-stdout> <nonce> ""` (a single probe, no signal) | echoes `FAIL\|no-response (rc=3; nonce absent from CLI output)` — the step-5 reason string the driver keys on is intact |
| TC-AGENT-SMOKE-075i | `_smoke_classify codex 1 <auth-failed-capture> …` | echoes `FAIL\|<auth/config phrase>` (not `no-response`) — the discriminator the driver uses to skip the retry holds |

## Gate — Phase A.5 propagation (`tests/unit/test-autonomous-review-smoke-gate.sh`)

| ID | Scenario | Expected |
|---|---|---|
| TC-REVIEW-SMOKE-075a | `_classify_smoke_state` maps `smoke_agent` rc 2 (retried-then-UNAVAILABLE) → `unavailable` state | state `unavailable`; evidence reason carried (`no-response … after retry — transient infra`) |
| TC-REVIEW-SMOKE-075b | Gate over `[unavailable, pass]` (one member retried-then-UNAVAILABLE, one PASS) | `_classify_smoke_gate` → **pass**; survivor = the PASS member; dropped member surfaced with `smoke: <reason>`; review **proceeds** (no abort) |
| TC-REVIEW-SMOKE-075c | Gate over `[unavailable, unavailable]` (all members no-response-then-UNAVAILABLE) | `_classify_smoke_gate` → **all-unavailable**; INV-40 all-unavailable terminal path, **no empty fan-out** |
| TC-REVIEW-SMOKE-075d | Gate over `[fail, pass]` (a genuine config FAIL still present) | `_classify_smoke_gate` → **fail** (abort) — the FAIL→abort path is preserved for real config breakage |

## Notes

- **Regression** (MUST fail before the fix, pass after): TC-AGENT-SMOKE-075a — a
  first probe rc≠0 / nonce absent / no scraper signal **and** a retry that is also
  `no-response` asserts final state **UNAVAILABLE** (rc 2). Before the fix the first
  probe is a single-shot FAIL (rc 1).
- **Preservation guards** (guard against an over-broad change): 075c/075d/075e/075g
  — genuine `auth-failed`/`config-error` stays a single-shot FAIL, and the already-
  correct UNAVAILABLE cases (quota / stream-error / malformed-output / bare timeout)
  keep their first-probe verdict with no retry.
- **Bound**: 075f asserts the retry fires **at most once** (the stub's invocation
  counter is exactly 2 for the no-response→no-response path).
- The gate cases (075b/075c) are the user-visible win: a single transient
  no-response member no longer aborts a multi-agent review.
- **E2E**: the existing `SMOKE_STUB=1 bash tests/e2e/run-agent-smoke.sh` harness
  exercises `smoke_agent` end-to-end through the real `run_agent` with stub CLIs.
  TC-AGENT-SMOKE-075a/075b are themselves a cheap shell-level end-to-end (a stub CLI
  that emits no nonce + non-zero exit on probe 1 and a nonce on probe 2, asserting
  the gate proceeds), so no new E2E harness is required for this classification
  change (the issue marks a dedicated E2E optional).
