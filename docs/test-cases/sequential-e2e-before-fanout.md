# Test Cases: Sequential E2E before review fan-out (issue #182, INV-46)

The review wrapper is too heavy to run end-to-end, so coverage is three-pronged
(matching the established `lib-review-*.sh` test pattern):

1. **Pure-logic harness** — source `lib-review-e2e.sh` in isolation and drive
   the pure helpers (`_classify_e2e_gate`, `_run_command_e2e_lane`,
   `_fetch_sha_evidence`) with stubbed `gh` / hooks.
2. **Source-of-truth greps** — assert the wrapper wires the lane before the
   fan-out, command-mode lane is shell (no `run_agent`), runs under
   `setsid`+`timeout`, PGID in trap+reaper, and `build_review_prompt` no longer
   contains the E2E execution block.
3. **Doc-presence** — INV-46 in invariants.md, the flow doc section, the ref
   doc update.

## TC-SE2E-GATE: `_classify_e2e_gate` truth table

| ID | rc | evidence present | expected gate |
|---|---|---|---|
| TC-SE2E-GATE-01 | 0 | yes | `pass` |
| TC-SE2E-GATE-02 | 0 | no | `block-nonsubstantive` (crash-after-parser / transient re-fetch, fail-closed) |
| TC-SE2E-GATE-03 | 1 | yes | `fail` (verify failed; stale-present evidence does not rescue) |
| TC-SE2E-GATE-04 | 1 | no | `fail` |
| TC-SE2E-GATE-05 | 124 | yes | `pass` (timeout-recovered: rc surfaced as 0 by the lane on artifact recovery; gate sees rc=0) |
| TC-SE2E-GATE-06 | 124 | no | `block-nonsubstantive` (no evidence) |
| TC-SE2E-GATE-07 | non-numeric rc | yes | `fail` (defensive — only literal 0 passes) |

> Note: the lane translates a 124-with-recovered-artifact into `rc=0` before
> calling the gate; `_classify_e2e_gate` itself only treats a literal `0` rc as
> the pass precondition, so 124 reaching the gate (no recovery) is a `fail`.

## TC-SE2E-LANE: `_run_command_e2e_lane` harness (stub gh + hooks)

| ID | scenario | expected |
|---|---|---|
| TC-SE2E-LANE-01 | pre-hook non-zero | aborts with `.rc`≠0, parser NOT invoked, `.rc` sidecar WRITTEN (set -e discipline) |
| TC-SE2E-LANE-02 | verify exit 0 | parser invoked → evidence posted → `.rc`==0 |
| TC-SE2E-LANE-03 | verify exit 124 (timeout) | parser invoked on partial log; recovered → `.rc`==0 |
| TC-SE2E-LANE-04 | verify exit other (e.g. 3) | parser SKIPPED → log-tail posted → `.rc`≠0 |
| TC-SE2E-LANE-05 | SHA-matching evidence already present | reuse/skip — pre-hook + verify NOT invoked, `.rc`==0 |
| TC-SE2E-LANE-06 | stale-SHA evidence present | re-run (pre-hook + verify invoked) |
| TC-SE2E-LANE-07 | **set -e discipline** — failing pre-hook still WRITES the `.rc` sidecar | sidecar file exists with non-zero content |

## TC-SE2E-FETCH: `_fetch_sha_evidence`

| ID | scenario | expected |
|---|---|---|
| TC-SE2E-FETCH-01 | SHA-matching comment present | echoes the comment body |
| TC-SE2E-FETCH-02 | only stale-SHA comment | echoes empty |
| TC-SE2E-FETCH-03 | bounded retry then still empty | returns empty after the retry budget (no hang) |

## TC-SE2E-STAMP: `_stamp_browser_evidence_marker` (codex review fix — browser mode stamps the REPORT, fails closed otherwise)

| ID | scenario | expected |
|---|---|---|
| TC-SE2E-STAMP-01 | a `## E2E Verification Report` comment present | helper PATCHes it (marker appended onto the report), returns 0 |
| TC-SE2E-STAMP-02 | **no report comment (the marker-only regression)** | helper returns non-zero (gate fails closed), no PATCH attempted |
| TC-SE2E-STAMP-03 | report already carries the SHA marker | returns 0, no redundant PATCH (idempotent) |
| TC-SE2E-STAMP-04 | wrapper source-of-truth | wrapper posts NO standalone marker-only `gh pr comment` for the browser marker |
| TC-SE2E-STAMP-05 | wrapper source-of-truth | wrapper calls `_stamp_browser_evidence_marker` in the browser lane |
| TC-SE2E-STAMP-06 | wrapper source-of-truth | a stamp failure forces E2E FAIL (`if ! _stamp_browser_evidence_marker; then … rc=1`) |
| TC-SE2E-STAMP-07 | lib source-of-truth | helper PATCHes the report comment in place (`gh api -X PATCH … issues/comments`) |

## TC-SE2E-SRC: source-of-truth greps (autonomous-review.sh / build_review_prompt)

| ID | assertion |
|---|---|
| TC-SE2E-SRC-01 | wrapper sources `lib-review-e2e.sh` |
| TC-SE2E-SRC-02 | the E2E lane runs BEFORE the fan-out loop (`_run_command_e2e_lane` call line < `for _agent in` line; non-zero line required so the check can't pass vacuously) |
| TC-SE2E-SRC-03 | command-mode lane is shell — `_run_command_e2e_lane` does NOT call `run_agent` |
| TC-SE2E-SRC-04 | command-mode lane runs under `setsid` + `timeout --kill-after` |
| TC-SE2E-SRC-05 | the E2E lane PGID is captured into the SIGTERM trap kill-set + the `_reap_fanout_processes` arg list |
| TC-SE2E-SRC-06 | `build_review_prompt` no longer contains the E2E execution block (no "Run pre-hooks", no `timeout ${E2E_COMMAND_TIMEOUT`, no `${E2E_COMMAND_RENDERED}`) |
| TC-SE2E-SRC-07 | review prompt instructs reading the posted evidence comment as input |
| TC-SE2E-SRC-08 | the E2E gate fail path emits an INV-35 trailer and routes `−reviewing +pending-dev` WITHOUT a `for _agent in` fan-out before it |
| TC-SE2E-SRC-09 | browser-mode lane is ONE `run_agent` call (not per review agent) + wrapper stamps the SHA marker |
| TC-SE2E-SRC-10 | `bash -n` parses the wrapper, lib, clean |
| TC-SE2E-SRC-11 | `_classify_e2e_gate` defined in `lib-review-e2e.sh`; gate call placed before INV-44 mergeable block |

## TC-SE2E-REG: regression — pre-hook invoked exactly once (CRITICAL)

| ID | assertion |
|---|---|
| TC-SE2E-REG-01 | with the pre-hook stubbed to a counter, a simulated N=3 review round invokes the pre-hook **exactly once** (structurally — it runs in Phase A before any fan-out). The N×-build regression this design exists to kill. |

## TC-SE2E-AGG: aggregation truth table (E2E gate ∧ review unanimity)

The wrapper's final decision composes the E2E gate with review unanimity. Driven
via a thin harness over the wrapper's compose logic (extracted pure where
feasible) / source-of-truth on the AND.

| ID | E2E gate | review aggregate | final |
|---|---|---|---|
| TC-SE2E-AGG-01 | pass | pass | PASS |
| TC-SE2E-AGG-02 | fail | pass | FAIL (gate overrides) |
| TC-SE2E-AGG-03 | pass | one blocking → fail | FAIL |
| TC-SE2E-AGG-04 | pass | all-unavailable | FAIL |
| TC-SE2E-AGG-05 | none (E2E_ACTIVE=false) | pass | PASS (no E2E gate) |
| TC-SE2E-AGG-06 | configured but no evidence | n/a | re-queue `failed-non-substantive` (transient) — surfaced loud, never silently passed |

## TC-SE2E-DOC: doc presence (pipeline-doc authority)

| ID | assertion |
|---|---|
| TC-SE2E-DOC-01 | INV-46 entry present in `docs/pipeline/invariants.md` |
| TC-SE2E-DOC-02 | `docs/pipeline/review-agent-flow.md` documents the sequential E2E lane (INV-46) |
| TC-SE2E-DOC-03 | `skills/autonomous-review/references/e2e-command-mode.md` updated for the wrapper-run lane |

## Backward-compat gate

`bash -n` + the existing INV-40 / INV-43 / INV-44 suites stay green:
`test-autonomous-review-multi-agent`, `test-review-e2e-command-poll-budget`,
`test-review-cli-exit-grace`, `test-autonomous-review-mergeable-gate`,
`test-e2e-mode-command`, `test-autonomous-review-prompt`,
`test-autonomous-review-per-agent-model`, `test-autonomous-review-per-agent-launcher`.
