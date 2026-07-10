# Test Cases — same-HEAD E2E-gate circuit breaker (issue #453)

Pins the pure decision-logic helpers added to `lib-review-e2e.sh` for the
same-HEAD circuit breaker, plus a source-of-truth grep pin that
`autonomous-review.sh` wires the breaker in at the correct hook point (mirrors
`test-autonomous-review-e2e-gate-open-guard.sh`'s two-pronged style: pure logic
+ wiring greps, since the wrapper itself is too heavy to run end-to-end).

## Files under test

| File | Role |
|------|------|
| `skills/autonomous-dispatcher/scripts/lib-review-e2e.sh` | New pure helpers: `_gate_breaker_marker`, `_gate_breaker_parse_count`, `_gate_breaker_next_count`, `_gate_breaker_threshold` |
| `skills/autonomous-dispatcher/scripts/autonomous-review.sh` | Wiring: the breaker check runs inside `E2E_GATE == "fail"`, before the existing `pending-dev` routing |
| `skills/autonomous-dispatcher/scripts/lib-error.sh` | Reused as-is (no changes) — `error_envelope` called with `class=transient` to render the `ADT_TRANSIENT_E2E_DEPLOY_FAIL` text embedded in the breaker's own report |
| `tests/unit/test-e2e-gate-circuit-breaker.sh` (NEW) | This regression suite |

## Test scenarios

### Group A — fingerprint / counter logic (TC-CIRCUIT-001..010)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CIRCUIT-001 | Marker construction round-trip: same `(sha, rc, count)` in → same fields out on parse | fields match exactly |
| TC-CIRCUIT-002 | Same head + same rc as stored marker → count increments by 1 | `_gate_breaker_next_count` returns `stored_count + 1` |
| TC-CIRCUIT-003 | Same head, **different** rc than stored marker → resets to count=1 under the new rc | does NOT accumulate the old count |
| TC-CIRCUIT-004 | Different head (new commit pushed) → resets to count=1 under the new sha/rc pair | does NOT accumulate the old count |
| TC-CIRCUIT-005 | No prior marker (first-ever failure) → parsed as count=0, next count=1 | does not crash, no malformed-input error |
| TC-CIRCUIT-006 | Malformed / corrupted marker text → parsed as count=0 | does not crash the wrapper |
| TC-CIRCUIT-007 | `GATE_FAIL_STALL_THRESHOLD` unset → defaults to 2 | `_gate_breaker_threshold` echoes `2` |
| TC-CIRCUIT-008 | `GATE_FAIL_STALL_THRESHOLD` set to non-numeric → falls back to default 2 with a warning | echoes `2`, warning logged (stderr) |
| TC-CIRCUIT-009 | `GATE_FAIL_STALL_THRESHOLD=1` (below the `>=2` floor) → falls back to default 2 with a warning | echoes `2`, warning logged |
| TC-CIRCUIT-010 | `GATE_FAIL_STALL_THRESHOLD=5` (valid, `>=2`) → honored verbatim | echoes `5`, no warning |

### Group B — trip / no-trip decision (TC-CIRCUIT-011..016)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CIRCUIT-011 | count reaches threshold (2 consecutive same-head-same-rc failures, 3rd dispatch) → trip | breaker fires |
| TC-CIRCUIT-012 | count below threshold → no trip, normal `pending-dev` routing proceeds | breaker does not fire |
| TC-CIRCUIT-013 | Same-head, DIFFERENT rc between rounds → does NOT trip on round 2 (counter reset, not accumulated) | breaker does not fire |
| TC-CIRCUIT-014 | New commit pushed after N-1 failures → breaker does not trip; marker under the new SHA starts at count=1 | breaker does not fire, fresh marker |
| TC-CIRCUIT-015 | Regression: genuine review findings with CHANGING head (normal FAIL path, no E2E gate involvement) → breaker logic never invoked, no behavior change | N/A — the breaker's own trip function is not on this path |
| TC-CIRCUIT-016 | Operator removes `stalled` without a new commit → next round re-reads the still-armed marker at count>=threshold-1 and re-trips on the very next failure (documented, intentional) | breaker fires again |

### Group C — already-stalled skip + report content (TC-CIRCUIT-017..020)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CIRCUIT-017 | Issue already carries `stalled` (e.g. INV-105 tripped first) → breaker does not re-trip, does not post a competing report | no `label_swap`/`itp_transition_state` call, no report |
| TC-CIRCUIT-018 | Trip report contains `reason=same-head-gate-failure` | pinned string present |
| TC-CIRCUIT-019 | Trip report embeds the `ADT_TRANSIENT_E2E_DEPLOY_FAIL` classification text (via `error_envelope ... transient`) | pinned string present |
| TC-CIRCUIT-020 | Trip performs the transition BEFORE posting the report (atomicity ordering, mirrors INV-105's TOCTOU fix) | transition call recorded before the report call |

### Group D — wrapper wiring (source-of-truth grep, TC-CIRCUIT-021..023)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CIRCUIT-021 | `autonomous-review.sh`'s `E2E_GATE == "fail"` block calls the breaker check BEFORE `itp_transition_state ... "pending-dev"` | breaker call line precedes the pending-dev transition line |
| TC-CIRCUIT-022 | The breaker's own trip path `exit`s (or `return`s) before reaching the existing pending-dev routing | control-flow short-circuit present |
| TC-CIRCUIT-023 | `docs/pipeline/errors.md` contains the literal `ADT_TRANSIENT_E2E_DEPLOY_FAIL` string (drift-guard `TC-ERR-ENVELOPE-020` forward-check) | present |

## Acceptance criteria for this change (pre-merge verifiable)

- [ ] **Surface**: CI job `hermetic-unit` runs `tests/unit/test-*.sh`; the new
  `test-e2e-gate-circuit-breaker.sh` passes (all TC-CIRCUIT-* green). Expected
  evidence: green `Hermetic / Unit + conformance` check on the PR.
- [ ] **Surface**: CI job `spec-drift` passes with the new `transitions.json`
  entry, guard-map entries, and codesite-map entries. Expected evidence: green
  `Spec Drift` check on the PR.
- [ ] **Surface**: `tests/unit/test-lib-error-envelope.sh`'s
  `TC-ERR-ENVELOPE-020/020-rev` drift guard passes with the new registered
  code. Expected evidence: same CI unit job green.
- [ ] **Surface**: pre-existing `tests/unit/test-autonomous-review-e2e-gate-open-guard.sh`
  and `tests/unit/test-spec-drift.sh` still pass (no harness regression).
  Expected evidence: same CI unit job green.
