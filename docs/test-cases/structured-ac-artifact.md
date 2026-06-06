# Test cases: structured AC-coverage artifact (INV-49, #183)

Unit suite: `tests/unit/test-autonomous-review-structured-ac.sh`.

The wrapper is too heavy to run end-to-end, so (mirroring the #182 suite) the
tests are three-pronged:

1. **pure-logic harness** for `_extract_ac_coverage_artifact` sourced from
   `lib-review-e2e.sh` in isolation;
2. **lane harness** asserting the lane writes the validated sidecar (fresh +
   reuse + malformed paths);
3. **source-of-truth greps** against `autonomous-review.sh` / `lib-review-e2e.sh`
   + doc-presence checks.

## Extraction / validation (`_extract_ac_coverage_artifact`)

| ID | Scenario | Expected |
|---|---|---|
| TC-AC-EXT-01 | text contains a valid `ac-coverage:begin/end` fence with a `{ "k":"pass" }` object | echoes the compact JSON `{"k":"pass"}` |
| TC-AC-EXT-02 | no fence in the text (#182 parser) | echoes empty (back-compat) |
| TC-AC-EXT-03 | fence present but body is invalid JSON | echoes empty (fail-safe) |
| TC-AC-EXT-04 | fence present, valid JSON but a value is not `pass`/`fail` (e.g. `"skip"`) | echoes empty (fail-safe — value domain enforced) |
| TC-AC-EXT-05 | fence present, valid JSON but it is an array not an object | echoes empty (fail-safe — object shape enforced) |
| TC-AC-EXT-06 | valid fence with multiple criteria incl. a `"fail"` value | echoes the compact JSON, retains the `fail` entry |
| TC-AC-EXT-07 | fence body is empty | echoes empty (fail-safe) |
| TC-AC-EXT-08 | two fences present (contract violation) | echoes the FIRST object only (single-object contract) |

## Lane writes the sidecar (`_run_command_e2e_lane`)

| ID | Scenario | Expected |
|---|---|---|
| TC-AC-LANE-01 | fresh run, parser stdout includes a valid fence | sidecar file contains the compact JSON, `.rc=0` |
| TC-AC-LANE-02 | fresh run, parser stdout has NO fence (#182) | sidecar exists and is EMPTY; lane `.rc=0` (free-form path) |
| TC-AC-LANE-03 | fresh run, parser emits a malformed fence | sidecar EMPTY (fail-safe); lane still `.rc=0`; warning logged |
| TC-AC-LANE-04 | reuse path: SHA-matching comment already carries a valid fence | sidecar contains the JSON extracted from the reused comment |
| TC-AC-LANE-05 | a stale sidecar from a prior round exists; this round's parser emits no fence | sidecar is TRUNCATED to empty (no stale leak) |
| TC-AC-LANE-06 | the sidecar path is non-writable (codex finding 2) | `_write_ac_coverage_sidecar` `unset`s `E2E_AC_COVERAGE_FILE` (no stale leak); warning logged |

## Prompt-read re-validation (`_revalidate_ac_coverage_file`, codex finding 1)

| ID | Scenario | Expected |
|---|---|---|
| TC-AC-REVAL-01 | sidecar holds a valid AC-coverage object | echoes the canonical compact JSON |
| TC-AC-REVAL-02 | sidecar was overwritten with attacker content after the lane (TOCTOU) | echoes empty (re-validation rejects it) → free-form path |
| TC-AC-REVAL-03 | sidecar empty / file absent | echoes empty |
| TC-AC-REVAL-04 | `E2E_AC_COVERAGE_FILE` unset | echoes empty |

## Wrapper wiring / prompt (source-of-truth greps)

| ID | Scenario | Expected |
|---|---|---|
| TC-AC-SRC-01 | wrapper exports `E2E_AC_COVERAGE_FILE` for command mode | grep matches |
| TC-AC-SRC-02 | `build_review_prompt` re-validates via `_revalidate_ac_coverage_file` (NOT plain `cat`) | grep matches the re-validation call; no plain `cat "${E2E_AC_COVERAGE_FILE}"` |
| TC-AC-SRC-03 | `build_review_prompt` still emits the free-form `## E2E Evidence` block when no map | the free-form block remains reachable (back-compat) |
| TC-AC-SRC-04 | extraction is command-mode only (no browser-lane coupling) | `_extract_ac_coverage_artifact` is invoked only from the command lane |
| TC-AC-SRC-05 | `bash -n` parses wrapper + lib clean | exit 0 |
| TC-AC-SRC-06 | write-failure disarms the sidecar | `_write_ac_coverage_sidecar` `unset`s `E2E_AC_COVERAGE_FILE` on write failure |

## Back-compat / regression

| ID | Scenario | Expected |
|---|---|---|
| TC-AC-REG-01 | #182 free-form behavior preserved when no artifact present | the `_classify_e2e_gate` truth table + the free-form prompt block are unchanged |
| TC-AC-REG-02 | existing `test-autonomous-review-sequential-e2e.sh` stays green | all #182 tests pass |
| TC-AC-REG-03 | existing `test-e2e-mode-command.sh` stays green | all command-mode tests pass |
| TC-AC-REG-04 | existing `test-review-agent-timeout.sh` (INV-48) stays green | all #185 tests pass |

## Doc presence

| ID | Scenario | Expected |
|---|---|---|
| TC-AC-DOC-01 | `references/e2e-command-mode.md` documents the optional structured-artifact contract | grep matches `ac-coverage` + `optional` |
| TC-AC-DOC-02 | `invariants.md` has an `INV-49` entry | grep matches |
| TC-AC-DOC-03 | `review-agent-flow.md` mentions the structured AC artifact | grep matches |
