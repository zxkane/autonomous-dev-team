# Test Cases — Dispatcher Step 0 Label Hygiene Pass

Tracks: issue #115 Bug B.

## Helper-level tests (`_has_terminal_label`)

Pure predicate over a labels-array JSON.

| ID | Input labels | Expected return |
|----|---|---|
| TC-HAS-TERM-001 | `autonomous, approved` | 0 (truthy) |
| TC-HAS-TERM-002 | `autonomous, stalled` | 0 |
| TC-HAS-TERM-003 | `autonomous, in-progress` | 1 (falsy) |
| TC-HAS-TERM-004 | `autonomous` | 1 |
| TC-HAS-TERM-005 | `autonomous, approved, stalled` | 0 (both qualify) |

## Hygiene-action tests (`hygiene_strip_residual_labels`)

Tests the per-issue strip logic by stubbing `gh issue edit` and capturing the args it was called with.

| ID | Input labels | Expected `--remove-label` args | Notes |
|----|---|---|---|
| TC-HYG-001 | `autonomous, approved, pending-review` | `pending-review` | One transitional residue under approved |
| TC-HYG-002 | `autonomous, approved, in-progress, stalled` | `in-progress` | Both terminals present; only transitional removed |
| TC-HYG-003 | `autonomous, approved, in-progress, reviewing, pending-dev, pending-review` | `in-progress, reviewing, pending-dev, pending-review` | All four transitionals stripped in one call |
| TC-HYG-004 | `autonomous, stalled, pending-dev` | `pending-dev` | Stalled-side residue |
| TC-HYG-005 | `autonomous, approved` | (no edit call) | Already clean — no-op |
| TC-HYG-006 | `autonomous, in-progress` | (no edit call) | Not a terminal-residue case |

## Idempotency-comment tests (`hygiene_post_audit_comment`)

| ID | Existing comments contain marker? | Expected `gh issue comment` call? |
|----|---|---|
| TC-COMMENT-001 | No marker present | one call posting comment + marker |
| TC-COMMENT-002 | Marker for same residue set already exists | no call |
| TC-COMMENT-003 | Marker for *different* residue set exists | one call (different residue → different marker → fresh post) |

## Step 0 integration

Static grep against `dispatcher-tick.sh`:

| ID | Assertion |
|----|---|
| TC-STEP0-INT-001 | Step 0 invocation appears in tick file |
| TC-STEP0-INT-002 | Step 0 invocation appears BEFORE Step 1 concurrency gate (line ordering) |
| TC-STEP0-INT-003 | Step 0 does NOT exit on concurrency-cap (it must run regardless) |

## Acceptance

- All TC-HAS-TERM-001..005 pass
- All TC-HYG-001..006 pass (TC-HYG-005, 006 confirm no-op via assert-no-call)
- All TC-COMMENT-001..003 pass
- All TC-STEP0-INT-001..003 pass
- Pre-existing 325-test unit suite stays green
