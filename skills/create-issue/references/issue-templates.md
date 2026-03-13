# Issue Templates

## Feature Template

```markdown
## Summary
<1-2 sentence description of the feature>

## Motivation
<Why this feature is needed, what problem it solves>

## Requirements
- [ ] <Requirement 1>
- [ ] <Requirement 2>
- [ ] <Requirement 3>

## Testing Requirements

> **Mandatory**: The dev agent MUST follow the project's TDD workflow.
> This section specifies the expected test artifacts. All listed items are required for PR approval.

### Test Cases Document
- [ ] Create test case document with all test scenarios (ID format: `TC-<FEATURE>-NNN`)
- <List 2-4 key test scenarios the document must cover>

### Unit Tests
- [ ] Create unit tests for the new functionality
- [ ] Coverage target: >80%
- <List specific units to test: API handlers, utility functions, data transformations, etc.>

### E2E Tests
- [ ] Create E2E tests covering key user flows
- <List 2-4 key user flows the E2E tests must cover, e.g.:>
- [ ] <Happy path: user performs X and sees Y>
- [ ] <Edge case: empty state / error state / unauthorized access>

## Acceptance Criteria
- [ ] <Criterion 1 -- how to verify>
- [ ] <Criterion 2>

## Dependencies
<List issues that must be completed before this issue can begin. Use GitHub issue links.>
- None | Depends on #N (<brief reason>)

## Design Considerations
<Architecture notes, API changes, data model impact -- if applicable>

## Out of Scope
<Explicitly list what this issue does NOT cover>
```

## Bug Template

```markdown
## Summary
<1-sentence description of the bug>

## Steps to Reproduce
1. <Step 1>
2. <Step 2>
3. <Step 3>

## Expected Behavior
<What should happen>

## Actual Behavior
<What actually happens>

## Environment
- Stage: <prod / staging / PR preview>
- Browser: <if applicable>
- Relevant logs: <error messages, log links>

## Severity
<Blocking / Degraded / Cosmetic>

## Possible Cause
<If known, suggest root cause or area of code>

## Testing Requirements

> **Mandatory**: The dev agent MUST create tests that prevent regression of this bug.

### Unit Tests
- [ ] Add regression test that fails before the fix and passes after
- [ ] Test must cover the exact reproduction scenario

### E2E Tests (if UI-related)
- [ ] Add or update E2E test to cover the fixed behavior
- [ ] Test the exact reproduction steps above end-to-end
```
