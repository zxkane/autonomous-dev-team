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
- **Expect** the regex contains the explicit `Task appears to have crashed \(no PR found\)` alternative
- **Expect** the regex does NOT contain the bare `Task appears to have crashed` alternative
- **Expect** the regex does NOT contain the `crashed\. PR found` alternative
- **Why** Guards against future edits re-introducing a broad `crashed` alternative
  that would substring-match the forward-progress `Dev process exited (PR found)`
  comment and reintroduce this bug.

## Out of scope

- E2E: exercising the full dispatcher cron cycle. Unit-level assertions on SKILL.md
  cover the contract; E2E is covered by observing pipeline behavior on subsequent
  issues.
