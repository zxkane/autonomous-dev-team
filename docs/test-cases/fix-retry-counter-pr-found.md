# Test Cases: Exclude "crashed. PR found" from Retry Counter

## Scope

Unit tests guarding the SKILL.md contract. Extends
`tests/unit/test-retry-counter-reset.sh` with two new cases.

## Cases

### TC-RCR-004 — Step 5 comment for PR-found path uses non-crash wording
- **Given** Step 5 stale-detection guidance for the `in-progress` + PR-exists branch
- **Expect** SKILL.md documents the comment `Dev process exited (PR found). Moving to pending-review for assessment.`
- **Expect** SKILL.md does NOT contain the old `Task appears to have crashed. PR found` phrasing
- **Why** The Step 4 retry-counter regex treats `Task appears to have crashed` as a
  crash marker. Removing the phrase from the forward-progress branch is the single
  behavioral guarantee that prevents premature `stalled` — guarding the comment
  wording also guards the regex indirectly (since the regex alternative literal
  was already dropped in the matching change).

## Out of scope

- E2E: exercising the full dispatcher cron cycle. Unit-level assertions on SKILL.md
  cover the contract; E2E is covered by observing pipeline behavior on subsequent
  issues.
