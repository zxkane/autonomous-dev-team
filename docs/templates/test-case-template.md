# <Feature Name> Test Cases

## Overview

- **Feature**: F<N> - <Feature Name>
- **PRD Reference**: [Link to PRD section or design document]
- **Design Document**: [Link to docs/designs/<feature>.md]
- **Date Created**: YYYY-MM-DD
- **Last Updated**: YYYY-MM-DD

## Test Environment

| Environment | URL | Notes |
|------------|-----|-------|
| Local | http://localhost:3000 | Development |
| Preview | https://pr-xxx.preview.example.com | PR Preview |
| Staging | https://staging.example.com | Pre-production |

## Test Data

[Document any test data, accounts, or fixtures needed]

```
Test User: test@example.com
Test Password: [See secrets manager]
```

---

## Test Scenarios

### TC-<FEATURE>-001: <Scenario Name - Happy Path>

- **Description**: [What is being tested - the main successful flow]
- **Preconditions**: 
  - [Condition 1 - e.g., User is logged in]
  - [Condition 2 - e.g., Database is in known state]
- **Test Steps**:
  1. [Step 1 - e.g., Navigate to /feature page]
  2. [Step 2 - e.g., Click "Create" button]
  3. [Step 3 - e.g., Fill in form fields]
  4. [Step 4 - e.g., Submit form]
- **Expected Result**: 
  - [Expected outcome 1 - e.g., Success message displayed]
  - [Expected outcome 2 - e.g., Data persisted to database]
- **Priority**: P0 (Critical)
- **Type**: E2E / Unit / Integration

---

### TC-<FEATURE>-002: <Scenario Name - Input Validation>

- **Description**: [Validate input handling]
- **Preconditions**: 
  - [List preconditions]
- **Test Steps**:
  1. [Step 1]
  2. [Step 2 - e.g., Enter invalid data]
- **Expected Result**: 
  - [Expected validation error message]
- **Priority**: P1 (High)
- **Type**: E2E / Unit

---

### TC-<FEATURE>-003: <Scenario Name - Edge Case>

- **Description**: [Test boundary conditions]
- **Preconditions**: 
  - [List preconditions]
- **Test Data**:
  - Min value: [value]
  - Max value: [value]
  - Empty: [expected behavior]
- **Test Steps**:
  1. [Test with min value]
  2. [Test with max value]
  3. [Test with empty input]
- **Expected Result**: 
  - [Expected behavior for each case]
- **Priority**: P1 (High)
- **Type**: Unit

---

### TC-<FEATURE>-004: <Scenario Name - Error Handling>

- **Description**: [Test error scenarios]
- **Preconditions**: 
  - [Setup for error condition - e.g., network failure simulated]
- **Test Steps**:
  1. [Trigger error condition]
  2. [Observe error handling]
- **Expected Result**: 
  - [User-friendly error message]
  - [System recovers gracefully]
  - [Error logged appropriately]
- **Priority**: P1 (High)
- **Type**: E2E / Integration

---

### TC-<FEATURE>-005: <Scenario Name - Authentication/Authorization>

- **Description**: [Test access control]
- **Preconditions**: 
  - [User role/permission setup]
- **Test Steps**:
  1. [Attempt action as unauthorized user]
  2. [Attempt action as authorized user]
- **Expected Result**: 
  - Unauthorized: [Expected denial]
  - Authorized: [Expected success]
- **Priority**: P0 (Critical)
- **Type**: E2E / Integration

---

## Test Coverage Summary

| Test ID | Description | Priority | Type | Automated |
|---------|-------------|----------|------|-----------|
| TC-<FEATURE>-001 | Happy Path | P0 | E2E | ⬜ |
| TC-<FEATURE>-002 | Input Validation | P1 | Unit | ⬜ |
| TC-<FEATURE>-003 | Edge Cases | P1 | Unit | ⬜ |
| TC-<FEATURE>-004 | Error Handling | P1 | E2E | ⬜ |
| TC-<FEATURE>-005 | Auth Check | P0 | E2E | ⬜ |

Legend:
- ✅ Automated and passing
- ⬜ Not yet automated
- 🔄 In progress

---

## Acceptance Criteria

- [ ] All P0 tests pass
- [ ] All P1 tests pass
- [ ] Unit test coverage >80%
- [ ] E2E tests pass on preview environment
- [ ] No console errors during E2E testing
- [ ] Performance within acceptable limits

---

## Notes

[Additional notes, known issues, or considerations]
