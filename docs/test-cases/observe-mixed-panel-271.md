# Test cases: observe-loop early-exit for mixed panels (#271 / INV-84)

Tests live in `tests/unit/test-verdict-artifact.sh` (the existing INV-78 suite),
extended with a pure-lib harness around the new `lib-review-poll.sh` helpers plus
source-of-truth wiring greps against `autonomous-review.sh`.

## Pure-lib: `_observe_agent_resolved` / `_all_first_verdicts_resolved`

The harness stubs `_fetch_agent_verdict_body` to model comment availability and
sets `AGENT_NAMES` / `AGENT_SESSION_IDS` / `AGENT_ARTIFACT_SNAPSHOTS` arrays.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-OBS-271-01 | artifact slot whose `.landed` snapshot exists | `_observe_agent_resolved` rc 0 (no comment fetch) |
| TC-OBS-271-02 | comment-only slot, snapshot absent, comment body present | `_observe_agent_resolved` rc 0 (resolved via comment) |
| TC-OBS-271-03 | comment-only slot, snapshot absent, no comment yet | `_observe_agent_resolved` rc 1 (unresolved) |
| TC-OBS-271-04 | artifact branch checked first → snapshot present means the comment fetch is NOT called | stub fetch counter stays 0 |
| TC-OBS-271-05 | MIXED panel: artifact slot frozen + comment slot has comment | `_all_first_verdicts_resolved` rc 0 |
| TC-OBS-271-06 | MIXED panel: artifact slot frozen + comment slot has NO comment | `_all_first_verdicts_resolved` rc 1 (does not early-exit while a comment agent is still pending — regression AC#3) |
| TC-OBS-271-07 | all-artifact-writer panel: every snapshot present | `_all_first_verdicts_resolved` rc 0 (parity with `_all_artifacts_landed`) |
| TC-OBS-271-08 | empty fleet (no agents) | `_all_first_verdicts_resolved` rc 1 (cannot claim all-resolved with zero slots) |
| TC-OBS-271-09 | `_all_artifacts_landed` true ⟹ `_all_first_verdicts_resolved` true (generalization holds for the all-**valid**-writer case) | both rc 0 |
| TC-OBS-271-13a | **malformed** artifact snapshot (file exists, schema-fail) | `_observe_agent_resolved` rc 1 — NOT resolved (#271 review [P1]) |
| TC-OBS-271-13b | the same malformed snapshot DOES exist | `_all_artifacts_landed` rc 0 — proving existence ≠ resolved (the gate divergence is intentional) |
| TC-OBS-271-13c | MIXED panel: malformed artifact (still-running) + comment sibling resolved | `_all_first_verdicts_resolved` rc 1 — loop keeps waiting on the malformed agent's PID so its real 124/137 rc lands (INV-48 `timed-out` veto preserved, NOT a dropped `unavailable`) |

> Artifacts in the pure-lib tests are provisioned **identity-matching** (`runId` =
> slot session-id, `agent` = slot name) via `obs_write_artifact`, because
> `_observe_agent_resolved` now runs the real `_classify_verdict_artifact` identity
> check — a bare golden fixture would (correctly) classify `malformed`.

## Integration: the observe loop early-exits a mixed panel with a lingering PID

A focused harness that drives the *actual loop body* logic (extracted decision)
over a mixed panel where the artifact agent's PID lingers (never exits) — asserts
the loop breaks via the first-verdict-resolved gate, NOT by waiting on the
lingering PID and NOT by reaching the ceiling.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-OBS-271-10 | mixed panel, artifact frozen + comment present, one PID alive forever | loop breaks on the resolved gate within a few rounds; `SECONDS` never approaches `_observe_deadline` |
| TC-OBS-271-11 | mixed panel, comment agent still pending while PID alive | loop does NOT break on the resolved gate (keeps polling) |

## Source-of-truth wiring (greps against `autonomous-review.sh`)

| ID | Assertion |
|----|-----------|
| TC-VERDICT-ARTIFACT-W25 | the observe loop's early-exit calls `_all_first_verdicts_resolved` (the mixed-panel-aware gate) |
| TC-VERDICT-ARTIFACT-W26 | the early-exit no longer depends solely on `_all_artifacts_landed` for the break (it is at most a fast-path delegate inside the resolved gate) |
| TC-VERDICT-ARTIFACT-W27 | `_reap_fanout_processes` is invoked AFTER the observe loop / verdict resolution so a lingering PID early-exited past is reaped |
| TC-VERDICT-ARTIFACT-W28 | the early-exit log line names the first-verdict-resolved (mixed-panel) completion signal |

## Regression

| ID | Assertion |
|----|-----------|
| TC-VERDICT-ARTIFACT-048* | existing `_all_artifacts_landed` unit tests still pass (the helper is unchanged) |
| TC-VERDICT-ARTIFACT-049* | existing `_freeze_landed_artifact` unit tests still pass |
| TC-VERDICT-ARTIFACT-W18/W19/W20 | existing observe-loop wiring greps still pass (the loop still freezes + the all-landed helper is still referenced) |

## Acceptance criteria mapping

- AC#1 (mixed panel with lingering PID early-exits well under the 6h ceiling once
  all first verdicts resolve) → TC-OBS-271-05, TC-OBS-271-10, W25.
- AC#2 (lingering PID reaped after resolution) → W27 (the existing
  `_reap_fanout_processes` call after resolution).
- AC#3 (no premature exit before a comment-only agent's verdict is observed) →
  TC-OBS-271-06, TC-OBS-271-11.
- AC#4 (all-artifact-writer behavior unchanged; existing observe-loop tests pass)
  → TC-OBS-271-07, TC-OBS-271-09, the unchanged TC-048/049/W18-W22.
