# Test Cases — review convergence rules: severity ratchet, round cap, evidence freshness (issue #449)

Pins the pure decision-logic helpers added for the severity-aware blocking
ratchet (R1), the INV-124 review-round-cap escalation breaker (R2), and the
E2E evidence-freshness pre-check (R3). Mirrors
`docs/test-cases/e2e-gate-circuit-breaker.md`'s structure: pure logic tables +
source-of-truth wiring greps against `autonomous-review.sh`, since the wrapper
itself is too heavy to run end-to-end.

## Files under test

| File | Role |
|------|------|
| `skills/autonomous-dispatcher/scripts/lib-review-severity.sh` (NEW) | `shouldBlockFinding`, severity-tag extraction (generic + codex paths), the pre-aggregation severity filter |
| `skills/autonomous-dispatcher/scripts/adapters/codex.sh` | `_codex_review_classify_stdout` extended to extract highest severity, not just `[P1]`; finding-boundary regex extended to recognize `[P0]` |
| `skills/autonomous-dispatcher/scripts/lib-review-poll.sh` | `_classify_verdict_body` unchanged; new sibling severity extraction for the generic numbered-list body |
| `skills/autonomous-dispatcher/scripts/lib-review-round.sh` (NEW) | `review-round-counter` marker helpers: parse/increment/reset, authenticity filter |
| `skills/autonomous-dispatcher/scripts/lib-review-cap.sh` (NEW) | INV-124 pure helpers: `_review_cap_next_count`, `_review_cap_threshold` |
| `skills/autonomous-dispatcher/scripts/lib-review-e2e.sh` | R3: `_ci_green_precheck` pre-check helper feeding the E2E gate's evidence-present signal |
| `skills/autonomous-dispatcher/scripts/autonomous-review.sh` | Wiring: severity filter runs pre-aggregation; INV-124 breaker runs in the FAIL substantive branch before `emit_verdict_trailer`; R3 pre-check runs before `_classify_e2e_gate` |
| `tests/unit/test-review-convergence-rules.sh` (NEW) | This regression suite |

## Test scenarios

### Group A — severity vocabulary / `shouldBlockFinding` matrix (TC-REVIEW-CONV-001..012)

| ID | round | severity | Expected (blocks?) |
|----|-------|----------|---------------------|
| TC-REVIEW-CONV-001 | 1 | P0 | true |
| TC-REVIEW-CONV-002 | 1 | P1 | true |
| TC-REVIEW-CONV-003 | 1 | P2 | true |
| TC-REVIEW-CONV-004 | 1 | P3 | true |
| TC-REVIEW-CONV-005 | 2 | P3 | true |
| TC-REVIEW-CONV-006 | 3 | P0 | true |
| TC-REVIEW-CONV-007 | 3 | P2 | true |
| TC-REVIEW-CONV-008 | 3 | P3 | false |
| TC-REVIEW-CONV-009 | 4 | P3 | false |
| TC-REVIEW-CONV-010 | 5 | P1 | true |
| TC-REVIEW-CONV-011 | 5 | P2 | false |
| TC-REVIEW-CONV-012 | 5 | P3 | false |

### Group B — severity-tag extraction (TC-REVIEW-CONV-013..020)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-REVIEW-CONV-013 | codex stdout carrying only `[P1]` | extracted highest = `P1` |
| TC-REVIEW-CONV-014 | codex stdout carrying `[P0]` and `[P2]` | extracted highest = `P0` |
| TC-REVIEW-CONV-015 | codex stdout with no severity tag at all | extracted = `none` |
| TC-REVIEW-CONV-016 | codex stdout with `[P3]` only | extracted highest = `P3` |
| TC-REVIEW-CONV-017 | generic numbered-list body: `1. [P2] ...` / `2. [P1] ...` | extracted highest = `P1` |
| TC-REVIEW-CONV-018 | generic numbered-list body: all `[P3]` | extracted highest = `P3` |
| TC-REVIEW-CONV-019 | generic numbered-list body with no tags (legacy FAIL body) | extracted = `none` |
| TC-REVIEW-CONV-020 | codex malformed-output finding-boundary regex recognizes `[P0]` (regression: pre-#449 regex was `P[123]` only) | `[P0]` line is treated as a finding boundary, not echo-region text |

### Group C — `review-round-counter` marker (TC-REVIEW-CONV-021..027)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-REVIEW-CONV-021 | Fresh issue, no prior marker | round = 1 |
| TC-REVIEW-CONV-022 | Same HEAD as the stored marker | round increments by 1 |
| TC-REVIEW-CONV-023 | New HEAD (different sha than the stored marker) | round resets to 1 |
| TC-REVIEW-CONV-024 | Malformed/corrupted marker text | parses as round=0, next=1, does not crash |
| TC-REVIEW-CONV-025 | Marker authored by a human (`authorKind == "human"`) | ignored — not read as the prior round marker (forgery guard) |
| TC-REVIEW-CONV-026 | Marker authored by a bot (`authorKind != "human"`) | read normally |
| TC-REVIEW-CONV-027 | Marker round-trip: construct then parse | fields match exactly |

### Group D — INV-124 round-cap breaker (TC-REVIEW-CONV-028..038)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-REVIEW-CONV-028 | `REVIEW_CONVERGENCE_CAP` unset | defaults to 5 |
| TC-REVIEW-CONV-029 | `REVIEW_CONVERGENCE_CAP` non-numeric | falls back to 5, warning logged (stderr) |
| TC-REVIEW-CONV-030 | `REVIEW_CONVERGENCE_CAP=1` (below the `>=2` floor) | falls back to 5, warning logged |
| TC-REVIEW-CONV-031 | `REVIEW_CONVERGENCE_CAP=8` (valid) | honored verbatim, no warning |
| TC-REVIEW-CONV-032 | Same head → next count = stored + 1 | `_review_cap_next_count` returns `stored+1` |
| TC-REVIEW-CONV-033 | New head → resets to 1 | does not accumulate |
| TC-REVIEW-CONV-034 | 5 consecutive `failed-substantive` rounds with a P1 finding present each round on the SAME HEAD progression | 6th round blocked, issue transitions to `stalled`, exactly one `reason=review-round-cap` report |
| TC-REVIEW-CONV-035 | Already `stalled` (e.g. INV-105 or INV-122 tripped first) | INV-124 does not re-trip, does not post a competing report |
| TC-REVIEW-CONV-036 | Round cap reached but the round's own severity floor is NOT failing (e.g. only P3 findings at round 5+, demoted to non-blocking) | breaker does not trip — the ratchet's own floor must still be failing |
| TC-REVIEW-CONV-037 | `failed-non-substantive` rounds | do not count toward the round-cap (out of scope; governed by `REVIEW_RETRY_LIMIT`) |
| TC-REVIEW-CONV-038 | Trip report is posted exactly once, transition precedes report (mirrors INV-122's TOCTOU-safe ordering) | transition call line precedes report call line |

### Group E — R3 evidence-freshness on a new HEAD (TC-REVIEW-CONV-039..044)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-REVIEW-CONV-039 | New HEAD, CI green, no evidence comment posted yet for that HEAD | E2E gate passes without waiting for a fresh evidence post |
| TC-REVIEW-CONV-040 | New HEAD, CI red | gate behavior unchanged — still fails (requires the lane / a fresh evidence post) |
| TC-REVIEW-CONV-041 | New HEAD, CI pending | gate behavior unchanged — still requires the lane / a fresh evidence post |
| TC-REVIEW-CONV-042 | Same HEAD, evidence comment already present (pre-existing INV-46 reuse path) | unaffected — reuse path still short-circuits before the R3 pre-check is consulted |
| TC-REVIEW-CONV-043 | `chp_ci_status` query fails/errors | pre-check fails safe (does not treat an error as green) |
| TC-REVIEW-CONV-044 | `_classify_e2e_gate`'s signature and lane-failure semantics are unchanged (regression pin) | function signature/branches byte-identical to pre-#449 |

### Group F — pre-aggregation severity-filter wiring (TC-REVIEW-CONV-045..048)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-REVIEW-CONV-045 | Per-agent raw findings + round fed into the filter, all findings below the round's floor | agent's verdict demoted `fail` → `pass`, comment still shows the finding as a non-blocking note |
| TC-REVIEW-CONV-046 | Per-agent raw findings + round fed into the filter, at least one finding at/above the round's floor | agent's verdict stays `fail` |
| TC-REVIEW-CONV-047 | Severity filter runs strictly between the terminal no-verdict sweep and `_aggregate_review_verdicts` | wiring grep: filter call line > terminal-sweep line, filter call line < aggregation call line |
| TC-REVIEW-CONV-048 | `_aggregate_review_verdicts` itself is unchanged (still consumes `pass\|fail\|unavailable\|timed-out`) | regression pin — no signature/vocabulary change |

## Acceptance criteria for this change (pre-merge verifiable)

- [ ] **Surface**: CI job `hermetic-unit` runs `tests/unit/test-*.sh`; the new
  `test-review-convergence-rules.sh` passes (all TC-REVIEW-CONV-* green).
  Expected evidence: green `Hermetic / Unit + conformance` check on the PR.
- [ ] **Surface**: CI job `spec-drift` passes with the new `transitions.json`
  entry (`review-round-cap-breaker`), guard-map entries, and codesite-map
  entries. Expected evidence: green `Spec Drift` check on the PR.
- [ ] **Surface**: `skills/autonomous-dispatcher/scripts/gen-state-machine.sh
  --check` passes (the regenerated mermaid block matches `transitions.json`).
- [ ] **Surface**: pre-existing `tests/unit/test-e2e-gate-circuit-breaker.sh`,
  `tests/unit/test-convergence-breaker.sh`, and `tests/unit/test-spec-drift.sh`
  still pass (no harness regression — INV-105/INV-122 fingerprints untouched).
  Expected evidence: same CI unit job green.
- [ ] ShellCheck green on every new/modified script.
