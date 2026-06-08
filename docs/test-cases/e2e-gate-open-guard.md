# Test Cases: E2E hard-gate PR-open guard (issue #195, INV-54 extension)

Test file: `tests/unit/test-autonomous-review-e2e-gate-open-guard.sh`

The wrapper is too heavy to run end-to-end, so (like the INV-54 and INV-46 test
suites) the regression is two-pronged:

1. **Pure decision-logic** — re-pin that the reused `_pr_open_gate` helper
   (`lib-review-mergeable.sh`) classifies PR state correctly. The E2E gate
   delegates the open/not-open decision to this exact helper, so its behavior is
   the testable core of the guard.
2. **Source-of-truth greps** against `autonomous-review.sh` — assert the
   open-check is wired into the E2E gate block routing **before** both
   `pending-dev` writes, that the skip path removes `reviewing` without adding
   `pending-dev`, and that the OPEN path is unchanged.

## Pure decision logic (reused helper)

| ID | Input (`_pr_open_gate <state>`) | Expected |
|----|----------------------------------|----------|
| TC-EOG-CLS-01 | `OPEN` | `proceed` |
| TC-EOG-CLS-02 | `MERGED` | `skip` |
| TC-EOG-CLS-03 | `CLOSED` | `skip` |
| TC-EOG-CLS-04 | `UNKNOWN` (failed-`gh`-query sentinel) | `skip` |
| TC-EOG-CLS-05 | empty | `skip` |

(The full enum is exhaustively covered by the INV-54 suite; here we re-pin the
states that matter for the merged-mid-E2E race — `MERGED`/`CLOSED` skip, `OPEN`
proceeds.)

## Source-of-truth structure

| ID | Assertion |
|----|-----------|
| TC-EOG-SRC-01 | The wrapper queries `gh pr view … --json state` at the E2E gate (a second `--json state` query distinct from the INV-54 hoisted one), feeding `_pr_open_gate`. |
| TC-EOG-SRC-02 | The E2E-gate open-check precedes the `if [[ "$E2E_GATE" == "fail" ]]` cascade (so it gates both block branches). |
| TC-EOG-SRC-03 | The E2E-gate open-check is downstream of the `_classify_e2e_gate` call (it acts on the classified gate, not before the lane runs). |
| TC-EOG-SRC-04 | The E2E-gate skip path removes `reviewing` and does NOT add `pending-dev`. |
| TC-EOG-SRC-05 | Exactly TWO `gh pr view … --json state` queries exist in the wrapper now (the INV-54 hoisted PASS-chain guard + this new E2E-gate guard) — no accidental third. |
| TC-EOG-SRC-06 | The E2E-gate open-check guards the block exits only — it is positioned after `_classify_e2e_gate` and before the `fail`/`block-nonsubstantive` cascade, so `pass`/`inactive` fall through unchanged. |
| TC-EOG-SRC-07 | `wrapper` passes `bash -n`. |

## OPEN-path regression pin (byte-for-byte unchanged)

| ID | Assertion |
|----|-----------|
| TC-EOG-REG-01 | Both E2E block branches still write `−reviewing +pending-dev` (their existing label transition is intact under the guard for the OPEN case). |
| TC-EOG-REG-02 | The E2E `fail` branch still calls `submit_request_changes` and emits a `failed-substantive` trailer (INV-52/INV-46 behavior preserved). |
| TC-EOG-REG-03 | The E2E `block-nonsubstantive` branch still emits a `failed-non-substantive` cause `e2e-evidence-missing` trailer and does NOT request changes. |
| TC-EOG-REG-04 | `emit_verdict_trailer` call count in the wrapper is unchanged (the guard adds no new trailer). |

## Integration / E2E (documented, not automated)

A live review run where the PR flips to MERGED while the E2E lane runs ends with
the issue NOT labeled `pending-dev` (and `reviewing` removed). This requires a
live GitHub PR + concurrent merge and is covered structurally by the
source-of-truth greps above (the skip path provably removes `reviewing` and
never adds `pending-dev`).

## Pass/fail contract

- **Before the fix**: TC-EOG-SRC-01..06 FAIL (no E2E-gate open-check exists);
  TC-EOG-SRC-05 in particular sees only ONE `--json state` query.
- **After the fix**: all tests PASS. The full existing suite (INV-54, INV-46
  sequential-e2e, mergeable-gate) stays green — the guard is additive and the
  OPEN path is byte-for-byte unchanged.
