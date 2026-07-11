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
| `skills/autonomous-dispatcher/scripts/lib-review-e2e.sh` | R3: `_e2e_ci_green_precheck` pre-check helper feeding the E2E gate's evidence-present signal |
| `skills/autonomous-dispatcher/scripts/lib-review-artifact.sh` | `_verdict_body_from_artifact_json` renders the OPTIONAL `severity` field inline so the JSON verdict-artifact channel (INV-78, the primary resolution path) feeds real severity into the ratchet |
| `docs/pipeline/schemas/verdict-artifact.schema.json` | New OPTIONAL `severity` enum (`P0`\|`P1`\|`P2`\|`P3`) on the finding definition |
| `skills/autonomous-dispatcher/scripts/autonomous-review.sh` | Wiring: severity filter runs pre-aggregation; INV-124 breaker runs in the FAIL substantive branch before `emit_verdict_trailer`; R3 pre-check runs before `_classify_e2e_gate`; empty-`PR_HEAD_SHA` guard on the R1 round counter; demoted-verdict body re-rendering |
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
| TC-REVIEW-CONV-020d | Numbered body: one correctly-tagged `[P3]` finding + one UNTAGGED finding | extracted = `none` (fail-safe — the untagged finding is not masked by the sibling tag) |
| TC-REVIEW-CONV-020e | Numbered body: every finding tagged (`[P2]`+`[P1]`) | extracted highest = `P1` (normal highest-wins, unaffected) |
| TC-REVIEW-CONV-020f | Free-form body, no numbered lines (codex-shaped) | falls back to whole-text scan (per-finding check does not apply — no numbering to key it on) |
| TC-REVIEW-CONV-020g | Single numbered finding, no tag anywhere | extracted = `none` |

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
| TC-REVIEW-CONV-027c/d | `PR_HEAD_SHA` is empty (transient `chp_pr_view` failure) | wrapper defaults `REVIEW_ROUND=1` (strictest floor) and skips posting a marker this round — mirrors INV-122's own non-empty-`PR_HEAD_SHA` guard |

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
| TC-REVIEW-CONV-034c/d | Exact-threshold boundary: `next_count == threshold` (5==5) trips; `next_count == threshold-1` (4<5) does not | `-ge` comparison confirmed at the exact boundary, not just one-past-it |
| TC-REVIEW-CONV-034e/f | Marker constructed with an empty/unknown head (e.g. a transient `PR_HEAD_SHA` read failure) | renders as the `unknown` placeholder (not an empty field) and the round field still parses/increments correctly — this counter is head-AGNOSTIC by design, so an unknown head must never silently reset it |

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

### Group G — artifact-channel severity round-trip (TC-REVIEW-CONV-049..052)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-REVIEW-CONV-049 | Schema-conformant artifact FAIL with a `severity: "P3"` field on a blocking finding | rendered body carries `[P3]` inline; severity filter extracts `P3`; demoted to non-blocking at round 5 |
| TC-REVIEW-CONV-050 | Artifact FAIL with `severity: "P1"` | still blocks at round 5 (regression pin) |
| TC-REVIEW-CONV-051 | Artifact FAIL finding with `severity` OMITTED | extracts as `none`; still blocks at round 5 (fail-safe — matches pre-#449 unconditional-block behavior) |
| TC-REVIEW-CONV-052 | Schema declares the `P0`-`P3` enum on the finding's `severity` field | present (drift guard between the schema and the renderer/prompt) |

### Group H — demoted-verdict body consistency (covered inline in Group F's wiring, manual verification below)

A demoted `fail→pass` round re-renders `AGENT_VERDICT_BODIES[i]`: the `Review
findings:` prefix and `[BLOCKING]` markers are replaced with an explicit
non-blocking note (the original finding text is retained for transparency).
Manually verified via `_review_apply_severity_filter` + a direct read of the
mutated `AGENT_VERDICT_BODIES` array in `autonomous-review.sh` — not a
standalone TC id (the transformation is inline in the wrapper, not a separate
pure function), but exercised end-to-end by TC-REVIEW-CONV-045/049.

### Group I — codex-review [P1] fixes (TC-REVIEW-CONV-053..059d)

Three [P1]-tagged findings from the initial codex review round on this
issue's own PR. Fix #1 (severity in the jq fallback) and fix #2 (marker-post
timing) are pinned as source-of-truth wiring greps against
`autonomous-review.sh`, mirroring this test file's existing two-pronged
style. Fix #3 (the INV-124 resume cutoff) was found by a follow-up
pr-test-analyzer pass to be under-tested by wiring greps alone — a
`>`→`>=` mutation on the cutoff comparison is invisible to a substring grep
but changes the breaker's actual trip behavior — so its cutoff-then-scan
logic was extracted into a pure function, `_review_cap_prior_marker`
(`lib-review-cap.sh`), and is now covered by fixture-driven behavioral
tests instead.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-REVIEW-CONV-053 | jq structural fallback validates a finding carrying the new `severity` key | valid with `severity` in-enum (`P0`-`P3`); malformed with an out-of-enum value — closes the gap where a non-codex agent's `severity`-tagged artifact was downgraded to `malformed` and lost its vote entirely |
| TC-REVIEW-CONV-054 | No unconditional `review-round-counter` post in the prompt-render region (before the E2E gate / smoke gate / fan-out have run) | wiring grep finds no `itp_post_comment` of the round marker in that region |
| TC-REVIEW-CONV-055 | The `review-round-counter` marker IS posted, but only after `AGGREGATE` is computed | wiring grep: marker-post line > aggregate-compute line |
| TC-REVIEW-CONV-056 | The post-aggregation marker post is gated on a decided verdict | wiring grep: gate condition checks `$AGGREGATE == "pass"` or `"fail"` (excludes `all-unavailable`) |
| TC-REVIEW-CONV-057 | `_review_cap_prior_marker` given a fixture where a trip report (embedding its own marker) is the newest comment | echoes `""` — the trip report's own embedded marker does NOT satisfy the cutoff (the self-referential-exclusion case the whole fix exists for) |
| TC-REVIEW-CONV-058 | `_review_cap_prior_marker` given a fixture with a marker genuinely AFTER the trip report | echoes that marker; feeding it into `_review_cap_next_count` continues a fresh series (2), not a re-trip (6) |
| TC-REVIEW-CONV-059 | `_review_cap_prior_marker` given a fixture with no trip report at all | cutoff is the epoch; the only marker present still qualifies (unchanged pre-fix behavior) |
| TC-REVIEW-CONV-059b | `_review_cap_prior_marker` given a fixture with a human comment forging the trip heading and a human comment forging a marker | both are ignored (`authorKind != "human"`); the genuine bot marker wins |
| TC-REVIEW-CONV-059c | `_review_cap_prior_marker` given a fixture with a `null` `.body` row | does not crash (jq `test()`/`contains()` on `null` is a runtime error, not a non-match); the null row is skipped and the genuine marker is still found |
| TC-REVIEW-CONV-059d | Wrapper wiring | `autonomous-review.sh` calls `_review_cap_prior_marker`, not an inlined two-query block |

### Group J — round-cap series reset on an intervening non-failing round (TC-REVIEW-CONV-060..066)

A [P1]-tagged finding from the second codex review round on this issue's
own PR: `_review_cap_prior_marker` cut off at the last trip report only,
so an intervening `Review PASSED` or `failed-non-substantive` round did
not reset the series — the next substantive FAIL resumed counting from the
OLDER pre-intervening-round marker instead of restarting at 1, letting the
breaker trip on N *total* substantive failures rather than N *consecutive*
ones. Fixed by adding a second cutoff input: the latest `<!-- review-verdict:
… -->` trailer whose verdict is `passed` or `failed-non-substantive` (never
`failed-substantive` itself); the effective cutoff is the max of the
trip-report cutoff and this reset cutoff.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-REVIEW-CONV-060 | `_review_cap_prior_marker` given a fixture with a `failed-substantive` marker followed by a `<!-- review-verdict: passed -->` trailer, no marker posted since | echoes `""` — the PASS resets the series |
| TC-REVIEW-CONV-060b | Same fixture fed into `_review_cap_next_count` | returns `1`, not a carry-forward of the pre-reset count |
| TC-REVIEW-CONV-061 | Same shape, but the intervening trailer is `failed-non-substantive` instead of `passed` | also resets — echoes `""` |
| TC-REVIEW-CONV-062 | A `failed-substantive` verdict trailer (including with `dev-actionable=false`) between two markers | does NOT reset — the prior marker still qualifies and the count still accumulates (regression pin against a `failed-non-substantive`/`failed-substantive` substring mix-up) |
| TC-REVIEW-CONV-063 | A HUMAN-authored `<!-- review-verdict: passed -->` forgery between two markers | does NOT reset (authenticity filter — mirrors the existing `authorKind != "human"` guard on the marker fence itself) |
| TC-REVIEW-CONV-064 | A genuine reset trailer timestamped AFTER the latest trip report | the effective cutoff is the reset cutoff (the later of the two), excluding a marker posted between the trip and the reset |
| TC-REVIEW-CONV-065 | A genuine reset trailer timestamped BEFORE the latest trip report | the effective cutoff is the trip cutoff (the later of the two) — unchanged TC-057/058 behavior |
| TC-REVIEW-CONV-066 | A 3-round series, reset by a PASS, then 1 more `failed-substantive` round (3 total, 2 "generations") | next round is `2`, not `4` — confirms the breaker (default threshold 5) would not trip on 5 total-but-non-consecutive substantive failures |
| TC-REVIEW-CONV-067 | [CRITICAL, silent-failure-hunter finding on the reset fix above] A bot-authored FAIL body that merely quotes/discusses a prior `<!-- review-verdict: passed -->` trailer in prose (not as a bare, standalone trailer) | does NOT reset the series — the reset-cutoff test is full-body anchored (`^...$`), not a bare substring `test()`, mirroring `lib-dispatch.sh::authentic_verdict()`'s own anchored pattern (which itself was hardened against this exact class of false-match in earlier review rounds) |
| TC-REVIEW-CONV-067b | Same fixture fed into `_review_cap_next_count` | returns `4` (accumulates), not falsely reset to `1` |
| TC-REVIEW-CONV-068 | A bot-authored FAIL body mentioning "circuit-breaker" in passing (not the exact trip heading, no marker fence) | is not misread as a trip report — the genuine later marker still wins |

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
