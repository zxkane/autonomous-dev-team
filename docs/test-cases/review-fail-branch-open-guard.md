# Test Cases: FAIL-gate branches honor the PR-open guard (issue #196, INV-54)

Test file: `tests/unit/test-autonomous-review-fail-branch-open-guard.sh`

Two-pronged, mirroring `test-autonomous-review-mergeable-gate.sh` (the wrapper is
too heavy to run end-to-end):

1. **Pure decision-logic harness** — source `lib-review-mergeable.sh` and drive
   the new `_pr_open_gate` helper over its full input space.
2. **Source-of-truth greps** against `autonomous-review.sh` — assert the hoisted
   guard is wired in at the top of the `PASSED_VERDICT == true` gate chain,
   ahead of both block branches, and that the redundant PASS-branch duplicate
   was removed.

## Pure-logic cases (`_pr_open_gate`)

| ID | Input `state` | Expected | Rationale |
|----|---------------|----------|-----------|
| TC-OG-CLS-01 | `OPEN` | `proceed` | PR open → run gate + PASS branch as before |
| TC-OG-CLS-02 | `open` (lowercase) | `proceed` | case-insensitive |
| TC-OG-CLS-03 | `MERGED` | `skip` | merged out-of-band → no pending-dev flip |
| TC-OG-CLS-04 | `CLOSED` | `skip` | closed out-of-band → no pending-dev flip |
| TC-OG-CLS-05 | `UNKNOWN` | `skip` | failed `gh` query sentinel → conservative skip |
| TC-OG-CLS-06 | `` (empty) | `skip` | empty → conservative skip |
| TC-OG-CLS-07 | `garbage` | `skip` | only OPEN proceeds; everything else skips |
| TC-OG-CLS-08 | sweep | only OPEN/open proceed (count == 2) | key property: inverse of PASS guard's `!= OPEN` |

## Source-of-truth grep cases (wrapper structure)

| ID | Assertion |
|----|-----------|
| TC-OG-SRC-01 | wrapper calls `_pr_open_gate` |
| TC-OG-SRC-02 | the open-check `gh pr view ... --json state` appears **before** the `_classify_mergeable_gate` call (hoisted ahead of the block branches) |
| TC-OG-SRC-03 | the open-gate `skip` path removes `reviewing` and does **not** add `pending-dev` (the skip block contains `--remove-label "reviewing"` with no `add-label "pending-dev"` between the gate and its `exit 0`) |
| TC-OG-SRC-04 | exactly **one** `gh pr view ... --json state` call remains (redundant PASS-branch duplicate removed) |
| TC-OG-SRC-05 | wrapper still passes `bash -n` |

## Regression property (the bug)

`TC-OG-SRC-02` + `TC-OG-SRC-03` together encode the regression: before the fix
the only `gh pr view --json state` lives *after* both block branches, so a grep
asserting the state query precedes `_classify_mergeable_gate` **fails** on the
unfixed wrapper and **passes** after the hoist. `TC-OG-CLS-*` fail before the
fix because `_pr_open_gate` does not yet exist (source fails / function unbound).

## Out of scope (asserted by absence)

No new behavior added to the INV-46 E2E gate or the verdict-FAIL `else` branch —
the test does not assert anything about those paths (issue #196 scopes only the
three `PASSED_VERDICT == true` exits).
