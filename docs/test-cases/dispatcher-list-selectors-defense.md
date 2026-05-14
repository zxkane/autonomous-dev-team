# Test Cases — `list_pending_review` / `list_pending_dev` defense in depth

Tracks: issue #115 Bug C (re-scoped after investigation).

## Scenario

The original Bug C hypothesis (downstream investigation note) claimed the dev wrapper's exit path flipped `approved` issues back to `in-progress`, forming a loop. Code inspection of `autonomous-dev.sh::cleanup` proved that hypothesis WRONG — every label-edit branch of the cleanup trap only `--remove-label "in-progress"`; none re-add it.

The actual third producer of the panoptes #37 wedge was that `list_pending_review` and `list_pending_dev` in `lib-dispatch.sh` did NOT subtract `approved` (same shape as Bug A's `list_stale_candidates`). PR #117's Step 0 hygiene heals the residue at tick start, so these selectors no longer see approved issues in steady state — but if Step 0 ever fails (rate-limit error, API outage, or an issue lands between Step 0 and the selector somehow), the pre-Bug-A loop returns.

This change closes the class by giving every selector its own `approved` (and `stalled`) subtraction. Step 0 stays as defense-in-depth; the selectors are the primary defense.

## Test Cases

### `list_pending_review`

| ID | Labels on fixture | Returns | Why |
|----|---|---|---|
| TC-PREV-001 | `autonomous, pending-review, approved` | `[]` | Approved is terminal; selector must not pick |
| TC-PREV-002 | `autonomous, pending-review, stalled` | `[]` | Stalled is terminal; same rule |
| TC-PREV-003 | `autonomous, pending-review` | one entry | Pre-existing happy path |
| TC-PREV-004 | `autonomous, pending-review, reviewing` | `[]` | Pre-existing `reviewing` exclusion still works |

### `list_pending_dev`

| ID | Labels on fixture | Returns | Why |
|----|---|---|---|
| TC-PDEV-001 | `autonomous, pending-dev, approved` | `[]` | Approved-side defense |
| TC-PDEV-002 | `autonomous, pending-dev, stalled` | `[]` | Stalled-side defense |
| TC-PDEV-003 | `autonomous, pending-dev` | one entry | Pre-existing happy path |
| TC-PDEV-004 | mix of all four above shapes | one entry (only TC-PDEV-003) | Combined sanity check |

## Acceptance

- TC-PREV-001/002 fail against current `main` → pass after fix
- TC-PDEV-001/002 fail against current `main` → pass after fix
- All happy-path (003) cases pass on both sides of the fix
- Pre-existing 350-test unit suite stays green
