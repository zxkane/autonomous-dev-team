# Test Cases — `list_stale_candidates` excludes `approved`

Tracks: issue #115 (Bug A).

## Scenario

`skills/autonomous-dispatcher/scripts/lib-dispatch.sh::list_stale_candidates`
is the Step 5 stale-detection selector. Before this fix it returned every
issue with the `autonomous` label whose label set contained `in-progress`
or `reviewing`, without subtracting `approved`. When an `approved` issue
also still carried a transitional label (residue from a wrapper crash
between two label transitions, or from the [INV-15] SIGTERM race), Step 5
re-classified it as stale and swapped the active label to `pending-dev`,
which then re-armed Step 4 on the next tick — an infinite token-burning
loop.

## Test Cases

| ID | Labels on fixture | `list_stale_candidates` returns | Why |
|----|---|---|---|
| TC-STALE-APPROVED-001 | `autonomous`, `in-progress`, `approved` | `[]` | Approved issues are terminal; Step 5 must not touch them |
| TC-STALE-APPROVED-002 | `autonomous`, `reviewing`, `approved` | `[]` | Same rule, other transitional label |
| TC-STALE-APPROVED-003 | `autonomous`, `in-progress` | one entry | Pre-existing behavior: actual stale candidates still detected |
| TC-STALE-APPROVED-004 | `autonomous`, `reviewing` | one entry | Pre-existing behavior preserved |

## Acceptance

- TC-001 and TC-002 fail against current `main` (regression coverage)
- TC-003 and TC-004 pass against current `main` AND after the fix
- All four pass after the fix
