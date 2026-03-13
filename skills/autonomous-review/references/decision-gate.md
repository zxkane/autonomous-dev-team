# Findings -> Decision Gate — MANDATORY

> **This gate is NON-NEGOTIABLE. Execute this self-check BEFORE submitting any PR review (APPROVE or REQUEST_CHANGES) and BEFORE posting the verdict comment on the issue. If this gate is skipped, the review is invalid.**

After completing steps 1-9, all findings across checklist categories will have been collected. Before making the PASS/FAIL decision, execute the following self-check:

## Gate Procedure

1. **Enumerate all findings** — list every issue identified during steps 3-9, no matter how minor. Include:
   - Process compliance gaps (missing docs, missing tests, unchecked PR items)
   - Code quality issues
   - CI check failures or pending checks
   - E2E test failures
   - Acceptance criteria that could not be verified

2. **Classify each finding** as BLOCKING or NON-BLOCKING:
   | Category | Blocking? | Examples |
   |----------|-----------|---------|
   | Missing design doc | BLOCKING | No `docs/plans/` or `docs/designs/` file |
   | Missing test case doc | BLOCKING | No `docs/test-cases/` file |
   | Missing unit tests for new code | BLOCKING | New hook/component with 0 tests |
   | CI check not passing (including pending) | BLOCKING | Deploy Preview still pending |
   | E2E test failure | BLOCKING | Any happy path or feature test fails |
   | Acceptance criteria not verified | BLOCKING | Any AC checkbox left unchecked |
   | Security vulnerability | BLOCKING | Credentials, injection, etc. |
   | PR checklist item unchecked | BLOCKING | Required items not marked |
   | Minor style suggestion | NON-BLOCKING | Naming preference, optional refactor |
   | Bot review missing (after timeout) | NON-BLOCKING | Best-effort per existing policy |

3. **Apply the hard rule**:
   - **If ANY finding is BLOCKING -> verdict MUST be FAIL**. Do NOT approve the PR. Do NOT post "Review PASSED". Post "Review findings:" with all issues.
   - **If ZERO findings are BLOCKING -> verdict is PASS**. Approve the PR and post "Review PASSED".
   - **There is NO middle ground.** Reporting blocking findings and then approving are mutually exclusive actions.

4. **Self-check questions** — answer each before proceeding:
   - "Did I list any missing documents, tests, or CI failures above?" -> If YES -> FAIL
   - "Are all CI checks in 'pass' state (not 'pending', not 'fail')?" -> If NO -> FAIL
   - "Did I successfully mark ALL Acceptance Criteria checkboxes?" -> If NO -> FAIL
   - "Did I write the phrase 'must be resolved before this PR can be approved' or similar in my findings?" -> If YES -> that means I found blocking issues -> FAIL

## Why This Gate Exists

In a previous review, the review agent posted multiple blocking findings (missing design doc, missing test cases, missing unit tests, CI pending, PR checklist unchecked) and then immediately approved the PR anyway. The E2E pass "felt" sufficient, but the skill explicitly requires ALL checklist items to be satisfied. This gate prevents that disconnect by forcing the agent to reconcile findings with the verdict before acting.

## Decision Criteria

### PASS (post "Review PASSED" + submit APPROVE review on PR)

**ALL of the following must be true** — if even ONE is false, the verdict is FAIL:

- All review checklist items (sections 1-5) are satisfied
- At least one happy path test case passes (from docs or smoke test)
- Code quality is acceptable
- No security concerns
- **All CI checks are in "pass" state** (not "pending", not "queued", not "fail")
- E2E verification passes (if configured)
- **All Acceptance Criteria checkboxes marked as checked in the issue body**
- **The Findings->Decision Gate produced ZERO blocking findings**

### FAIL (post "Review findings:" + do NOT approve the PR)

**If ANY of the following is true**, the verdict is FAIL — do NOT submit an APPROVE review:

- Any checklist item is not satisfied
- Security vulnerability found
- Significant code quality issues
- **Any CI check is not in "pass" state** (pending counts as not passing)
- **Any E2E test case fails** (if E2E configured)
- **Any happy path test case fails** (if E2E configured)
- **Preview URL is not available** (if E2E configured)
- **Any Acceptance Criteria checkbox remains unchecked**
- **The Findings->Decision Gate produced one or more blocking findings**

When failing, provide SPECIFIC and ACTIONABLE feedback:
- Quote the problematic code
- Explain why it's an issue
- Suggest the fix
- Include E2E failure screenshots as evidence (if available)

## Output Format

> **The Findings->Decision Gate MUST be executed before posting any output. If it has not yet been run, STOP and run it now.**

Post the review result as a comment on the issue (NOT the PR).

**Action pairing — these MUST match:**
| Verdict | Issue comment | PR review action |
|---------|--------------|-----------------|
| PASS | Post "Review PASSED" | Submit APPROVE review on PR |
| FAIL | Post "Review findings:" | Do NOT submit any review (or submit REQUEST_CHANGES) |

**It is FORBIDDEN to post "Review findings:" with blocking items AND submit an APPROVE review. These are mutually exclusive.**

For PASS:
```
Review PASSED - All checklist items verified, code quality good. E2E verification completed.

Findings->Decision Gate: 0 blocking findings.

Summary:
- Design: docs/plans/xxx.md
- Tests: X unit tests, Y E2E tests
- CI: All checks passing
- Code: Clean, follows project conventions
- E2E: All N test cases passed (including M happy path), K regression checks passed
- Happy path: TC-HP-XXX executed, plan generation verified
```

For FAIL:
```
Review findings:

Findings->Decision Gate: N blocking finding(s) — FAIL.

1. **[BLOCKING] E2E test failure** - TC-HP-001 failed
   - Expected: Plan with 7 days of Python videos
   - Actual: Plan generated with only 3 days
   - Evidence: [inline screenshot in PR E2E report comment]
   - Action: Fix plan generation to respect duration requirements

2. **[BLOCKING] Missing test cases** - No test case document found in docs/test-cases/
   - Action: Create docs/test-cases/<feature>.md following the template in CLAUDE.md

3. **[BLOCKING] CI check pending** - Deploy Preview not yet passed
   - Action: Wait for deployment to complete before requesting review
```
