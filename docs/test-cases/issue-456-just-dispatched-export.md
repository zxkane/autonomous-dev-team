# Test Cases: `JUST_DISPATCHED` array-to-scalar export corruption (issue #456)

## Background

`dispatcher-tick.sh` Step 5 joins the tick-local `JUST_DISPATCHED` bash array into a
space-separated string and re-`export`s it under the same name so
`was_just_dispatched()` (`lib-dispatch.sh`) can read it in scalar context across the
`dispatch()`/subshell boundary. Bash's `existing_array_name="scalar"` only overwrites
index 0 of an existing array — indices ≥ 1 survive untouched — so `${JUST_DISPATCHED[*]}`
(and the "Tick complete. Dispatched: ..." log line) printed N-1 duplicated trailing
entries for an N-element array (e.g. `84 85` → `84 85 85`).

Fix: `unset JUST_DISPATCHED` immediately before the scalar `export`, so the array is
fully replaced rather than partially overwritten.

## Test Suite

`tests/unit/test-issue-456-just-dispatched-export.sh` — drives the real export segment
extracted (via anchor match) from `dispatcher-tick.sh` itself, so the suite tracks the
source file instead of a hand copy.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-456-001 | 2-element array (`84`, `85`) — the exact production repro | Post-export `${JUST_DISPATCHED[*]}` == `84 85` (not `84 85 85`) |
| TC-456-002 | 3-element array (`10`, `20`, `30`) | == `10 20 30` (not `10 20 30 20 30`) — confirms the fix isn't N=2-special-cased |
| TC-456-003 | 4-element array (`1`, `2`, `3`, `4`) | == `1 2 3 4` |
| TC-456-004 | Empty array | Caller's `${JUST_DISPATCHED[*]:-<none>}` fallback == `<none>` |
| TC-456-005 | `was_just_dispatched()` scalar read after the fixed export | `was_just_dispatched 84` and `85` resolve IN, `86` resolves NOT_IN — confirms [INV-09](../pipeline/invariants.md#inv-09-just_dispatched-skip-rule)'s functional skip-logic is unaffected by the export-mechanism fix |

## Acceptance Criteria Mapping

- Regression test reproduces `84 85 85`-style duplication pre-fix, passes post-fix: TC-456-001/002.
- `was_just_dispatched()` / Step 5 dispatch-skip behavior unchanged: TC-456-005 (plus existing `tests/unit/test-lib-dispatch.sh` IN/NOT_IN/boundary/unset coverage, unmodified by this fix).
- `docs/pipeline/invariants.md` INV-09 entry updated with the export-mechanism note and test pointer.
