# Test Cases: Exclude "crashed. PR found" from Retry Counter

## Scope

Unit tests guarding the SKILL.md contract. Extends
`tests/unit/test-retry-counter-reset.sh` with two new cases.

## Cases

### TC-RCR-004 — Step 5 comment for PR-found path uses non-crash wording
- **Given** Step 5 stale-detection guidance for the `in-progress` + PR-exists branch
- **Expect** SKILL.md documents the comment `Dev process exited (PR found). Moving to pending-review for assessment.`
- **Expect** SKILL.md does NOT contain the old `Task appears to have crashed. PR found` phrasing
- **Why** Removing the "crashed" wording from the forward-progress branch is the
  behavioral guarantee that prevents premature `stalled` after review returns work.

### TC-RCR-005 — Step 4 retry-counter regex is anchored on explicit preambles
- **Given** the Step 4 `DISPATCHER_CRASHES` jq regex in SKILL.md
- **Extract** the full `test(...)` argument from the `DISPATCHER_CRASHES=` line only
  (so other file occurrences of the phrase don't leak into the assertion)
- **Expect** the extracted regex is exactly `test("Task appears to have crashed \(no PR found\)|process not found")`
- **Expect** the extracted regex does NOT contain the `crashed\. PR found` alternative
- **Why** Guards against future edits broadening the regex — a bare `crashed`
  alternative, a `crashed[^(]` alternative, or re-adding `crashed. PR found`
  would all substring-match the forward-progress `Dev process exited (PR found)`
  comment and reintroduce this bug. Extracting the exact regex argument (rather
  than scanning the whole file) avoids false positives from prose references to
  the same phrase elsewhere in SKILL.md.

## Out of scope

- E2E: exercising the full dispatcher cron cycle. Unit-level assertions on SKILL.md
  cover the contract; E2E is covered by observing pipeline behavior on subsequent
  issues.
