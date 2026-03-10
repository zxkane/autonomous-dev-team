---
name: autonomous-review
description: Use when reviewing a PR as part of the autonomous pipeline. Performs thorough code review, checklist verification, and optional E2E verification via Chrome DevTools MCP. Triggered by scripts/autonomous-review.sh wrapper.
---

# Autonomous Review Mode

You are reviewing a PR created by an autonomous development session. Be thorough and objective.

## Review Checklist

Verify ALL of the following:

### 1. Process Compliance
- [ ] Design canvas exists in `docs/designs/` or `docs/plans/`
- [ ] Branch follows naming convention (`feat/`, `fix/`, `refactor/`, etc.)
- [ ] Test cases documented in `docs/test-cases/`
- [ ] PR description follows template (Summary, Design, Test Plan, Checklist sections)
- [ ] PR references the issue (`Closes #N` or `Fixes #N`)

### 2. Code Quality
- [ ] No security issues (no credentials, no injection vulnerabilities)
- [ ] TypeScript types are correct (no `any` abuse)
- [ ] Error handling is appropriate
- [ ] Code follows existing patterns in the codebase
- [ ] No obvious performance regressions

### 3. Testing
- [ ] Unit tests exist for new functionality
- [ ] Unit test coverage is reasonable for new code
- [ ] E2E tests updated if UI changes were made
- [ ] All CI checks are passing

### 4. Infrastructure (if applicable)
- [ ] Infrastructure-as-Code changes are safe
- [ ] No accidental resource deletions
- [ ] IAM permissions follow least privilege

### 5. Optional: Bot Reviewer Verification
- [ ] If configured bot reviewers have posted reviews, verify their findings are addressed
- [ ] All bot review threads are resolved
- [ ] If bot review is missing and configured, trigger it and wait

### 6. E2E Verification via Chrome DevTools MCP

> **If E2E verification is configured (preview URL provided in the prompt), this section is MANDATORY. If no preview URL is configured, skip this section.**

- [ ] Preview URL extracted from PR comments
- [ ] Preview URL navigated successfully via Chrome DevTools MCP
- [ ] Test user login verified on preview environment
- [ ] Happy path test cases selected and executed (see section below)
- [ ] Feature test cases executed against live preview
- [ ] Regression tests executed (auth, navigation, console errors)
- [ ] Screenshots captured, uploaded, and linked as evidence
- [ ] E2E verification report posted as PR comment with screenshot links

## Merge Conflict Resolution — MANDATORY Pre-Review Step

Before starting the review, check whether the PR branch has merge conflicts with main. If it does, rebase the branch so the PR is mergeable.

### Procedure

1. **Check mergeable status**:
   ```bash
   MERGEABLE=$(gh pr view <PR_NUMBER> --repo <REPO> --json mergeable -q '.mergeable')
   ```

2. **If MERGEABLE is "MERGEABLE"** — skip to the Review Process below.

3. **If MERGEABLE is "CONFLICTING"** — rebase the PR branch onto main:
   ```bash
   # Fetch latest main and the PR branch
   git fetch origin main <PR_BRANCH>

   # Create a temporary worktree for the rebase
   git worktree add /tmp/rebase-pr-<PR_NUMBER> <PR_BRANCH>
   cd /tmp/rebase-pr-<PR_NUMBER>

   # Rebase onto main
   git rebase origin/main
   ```

4. **If rebase succeeds** (no conflicts):
   ```bash
   # Force push the rebased branch
   git push --force-with-lease origin <PR_BRANCH>

   # Clean up temporary worktree
   cd -
   git worktree remove /tmp/rebase-pr-<PR_NUMBER>

   # Wait for CI to restart on the new HEAD (checks reset after force push)
   # Poll until checks appear and complete
   sleep 10
   gh pr checks <PR_NUMBER> --watch --interval 30
   ```
   Then proceed to the Review Process below.

5. **If rebase fails** (merge conflicts that cannot be auto-resolved):
   ```bash
   # Abort the rebase
   git rebase --abort

   # Clean up temporary worktree
   cd -
   git worktree remove /tmp/rebase-pr-<PR_NUMBER> --force
   ```
   **FAIL the review immediately** with:
   ```
   Review findings:

   Findings->Decision Gate: 1 blocking finding(s) -- FAIL.

   1. **[BLOCKING] Merge conflict with main** - The PR branch `<PR_BRANCH>` has conflicts
      with `main` that require manual resolution.
      - Conflicting files: <list files from rebase error output>
      - Action: Rebase `<PR_BRANCH>` onto `main`, resolve conflicts, and force push.
   ```
   Post this on the issue and exit. The wrapper script will transition the issue to `pending-dev`.

6. **If MERGEABLE is "UNKNOWN"** — GitHub may still be computing. Wait and retry:
   ```bash
   sleep 10
   MERGEABLE=$(gh pr view <PR_NUMBER> --repo <REPO> --json mergeable -q '.mergeable')
   ```
   If still UNKNOWN after 3 retries, treat as MERGEABLE and proceed (GitHub will block the merge later if there are actual conflicts).

### Important Notes

- Force pushing to a feature branch is safe — only the pipeline agents touch these branches.
- Use `--force-with-lease` (not `--force`) to avoid overwriting unexpected changes.
- After force push, all CI checks will restart automatically. You MUST wait for them to pass before proceeding with the review.

## Review Process

1. **Read the issue** to understand requirements
2. **Read the PR diff** thoroughly (`gh pr diff <number>`)
3. **Check CI status** (`gh pr checks <number>`)
4. **Verify file existence** for design docs, test cases, etc.
5. **Assess code quality** against the checklist above
6. **Verify bot reviewer findings** (if configured — see checklist section 5)
7. **Select happy path test cases** based on PR diff analysis (see below)
8. **Perform E2E verification** (if configured — see procedure below)
9. **Mark acceptance criteria** — for each verified criterion, mark its checkbox in the issue body (see "Marking Acceptance Criteria")
10. **MANDATORY SELF-CHECK GATE** — execute the Findings->Decision Gate (see below) BEFORE submitting any review verdict

## Happy Path Test Cases

Happy path test cases are project-specific. The review agent selects cases based on:

1. Read `docs/test-cases/` directory for available test case documents
2. Analyze the PR diff to determine which areas changed
3. Select the most relevant test cases covering changed functionality
4. Execute at least one happy path test case per review

If no test case documents exist, execute a basic smoke test:
- Navigate to the application root URL
- Verify the page loads without errors
- Check browser console for JavaScript errors

## E2E Verification Procedure

> **This section applies only when E2E verification is configured.** The review wrapper script (`autonomous-review.sh`) will indicate whether E2E is enabled and provide the necessary configuration in the prompt.

### Prerequisites

The review script (`autonomous-review.sh`) extracts and provides:
- **Preview URL**: Preview URL extracted from PR comments or provided by the review wrapper
- **Test user email**: from `{E2E_TEST_USER_EMAIL}` env var
- **Test user password**: from `{E2E_TEST_USER_PASSWORD}` env var
- **Screenshot upload script**: `scripts/upload-screenshot.sh` for uploading screenshots to GitHub

### Step-by-Step Procedure

#### 1. Verify Preview URL
- Check that the preview URL was provided in the prompt
- If `NOT_FOUND`, immediately fail the review with: "E2E verification failed: PR preview URL not found"

#### 2. Open Browser and Navigate
```
Use Chrome DevTools MCP tools:
1. new_page -> open a fresh browser page
2. navigate_page -> go to the preview URL
3. wait_for -> confirm page loads (wait for a known element)
4. take_screenshot -> capture landing page
5. Upload screenshot immediately:
   bash scripts/upload-screenshot.sh "<screenshot-path>" "<PR_NUMBER>" "landing-page"
```

#### 3. Login with Test User
```
1. Click sign-in / login button
2. fill -> enter email in the email field
3. fill -> enter password in the password field
4. Click submit / sign-in button
5. wait_for -> confirm redirect to authenticated page (e.g., dashboard)
6. take_screenshot -> capture authenticated state
7. Upload screenshot immediately:
   bash scripts/upload-screenshot.sh "<screenshot-path>" "<PR_NUMBER>" "auth-login"
```

#### 4. Execute Happy Path Test Cases
- Based on the selection logic above, execute the chosen happy path cases
- **CRITICAL**: After EVERY `take_screenshot`, you MUST immediately run the upload command:
  ```bash
  SCREENSHOT_URL=$(bash scripts/upload-screenshot.sh "<screenshot-path>" "<PR_NUMBER>" "<TC-ID>")
  ```
  Store the returned URL for use in the E2E report table.
- For each case:
  1. Follow the detailed steps in the case definition
  2. Use Chrome DevTools MCP tools (navigate_page, click, fill, wait_for, type_text, etc.)
  3. `take_screenshot` at key verification points
  4. **Immediately** upload each screenshot: `bash scripts/upload-screenshot.sh "<path>" "<PR>" "<TC-ID>"`
  5. Record PASS or FAIL with the uploaded screenshot URL as a clickable link `[TC-ID](url)`

#### 5. Execute Feature Test Cases
- Read `docs/test-cases/<feature>.md` for the feature under review
- For each test case:
  1. Follow the test steps using Chrome DevTools MCP tools
  2. Verify expected outcomes by inspecting visible page content
  3. `take_screenshot` at each key verification point
  4. **Immediately** upload: `bash scripts/upload-screenshot.sh "<path>" "<PR>" "<TC-ID>"`
  5. Record PASS or FAIL with a clickable link `[TC-ID](url)`

#### 6. Regression Checks
- **Auth**: Verify login/logout works
- **Navigation**: Click through main sidebar links, verify pages load
- **Console errors**: Use `list_console_messages` to check for JS errors

#### 7. Post E2E Report
Post a structured comment on the **PR** (not the issue) with this format:

```markdown
## E2E Verification Report

### Summary
| Total | Passed | Failed | Skipped |
|-------|--------|--------|---------|
| N     | X      | Y      | Z       |

### Happy Path Results
| Test Case | Description | Status | Evidence |
|-----------|-------------|--------|----------|
| TC-HP-001 | Generate 1-week plan | PASS | [TC-HP-001](<upload-script-returned-url>) |

### Feature Test Results
| Test Case | Description | Status | Evidence |
|-----------|-------------|--------|----------|
| TC-XXX-001 | Description | PASS | [TC-XXX-001](<upload-script-returned-url>) |

### Regression Tests
| Test | Status |
|------|--------|
| Auth login/logout | PASS |
| Navigation | PASS |
| Console errors | PASS |
```

## Screenshot Publishing

When using Chrome DevTools MCP to take screenshots during E2E verification, **upload them to GitHub and link them in PR comments**.

> **Private repo limitation**: Inline images (`![img](url)`) do not render for private repos because `raw.githubusercontent.com` requires authentication that GitHub's markdown renderer does not inject. Instead, use **clickable links** to `/blob/` URLs — GitHub's web UI renders PNG files natively for authenticated users with repo access.

### Upload Workflow

After each `take_screenshot`, use the upload helper script to get a GitHub blob URL:

```bash
# Usage: scripts/upload-screenshot.sh <png-path> <pr-number> <test-case-id>
# Returns: GitHub blob URL viewable by repo members

URL=$(scripts/upload-screenshot.sh /tmp/screenshot.png 42 TC-HP-001)
# -> https://github.com/{REPO}/blob/screenshots/pr-42/TC-HP-001.png
```

**To call from within the CC review session**, use the Bash tool:

```bash
SCREENSHOT_URL=$(bash scripts/upload-screenshot.sh "<screenshot-path>" "<PR_NUMBER>" "<TC-ID>")
```

### Link Format

Use clickable links (NOT inline images) in the E2E report table:

```markdown
| TC-HP-001 | Generate 1-week plan | PASS | [TC-HP-001](<uploaded-url>) |
```

### Fallback Behavior

If the upload script fails (e.g., network issue, permission error):
1. The script outputs `UPLOAD_FAILED` as the URL
2. In the E2E report, describe the visual state observed instead of linking a screenshot:
   ```
   | TC-HP-001 | Generate 1-week plan | PASS | Screenshot upload failed. Verified: plan shows 7 days, each with video thumbnails, title "Python Basics" |
   ```
3. Continue with the review — screenshot upload failure should NOT block the review itself

### CI Screenshots

The CI workflow automatically captures screenshots in E2E tests and uploads them as artifacts:
- `e2e-screenshots-pr-<N>` artifact (5-day retention)
- The PR comment from CI includes a download link for the full artifact

## Marking Acceptance Criteria

During E2E verification, mark each acceptance criterion checkbox in the issue body as you verify it.

### Procedure

1. Read the issue body and identify the `## Acceptance Criteria` section
2. For each criterion:
   a. Verify it via Chrome DevTools MCP, code inspection, or CI check results
   b. If it **passes**, mark the checkbox:
      ```bash
      bash scripts/mark-issue-checkbox.sh <ISSUE_NUMBER> "<criterion text>"
      ```
   c. If it **fails**, STOP marking — record the failure and proceed to "Review findings"
3. The script uses `gh` (which picks up the active App token via `GH_TOKEN_FILE`), so edits appear as the configured review bot

### Important Rules

- Mark criteria **only after verifying them** — do not pre-mark
- If ANY criterion fails, do NOT mark it — post "Review findings:" instead
- Do NOT mark Requirements checkboxes — those are for the dev agent
- ALL acceptance criteria must be checked (`- [x]`) before approving the PR

## Findings -> Decision Gate — MANDATORY

> **This gate is NON-NEGOTIABLE. You MUST execute this self-check BEFORE submitting any PR review (APPROVE or REQUEST_CHANGES) and BEFORE posting the verdict comment on the issue. If you skip this gate, the review is invalid.**

After completing steps 1-9, you will have collected findings across all checklist categories. Before making your PASS/FAIL decision, you MUST execute the following self-check:

### Gate Procedure

1. **Enumerate all findings** — list every issue you identified during steps 3-9, no matter how minor. Include:
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
   - **There is NO middle ground.** You cannot report blocking findings and then approve. These two actions are mutually exclusive.

4. **Self-check questions** — answer each before proceeding:
   - "Did I list any missing documents, tests, or CI failures above?" -> If YES -> FAIL
   - "Are all CI checks in 'pass' state (not 'pending', not 'fail')?" -> If NO -> FAIL
   - "Did I successfully mark ALL Acceptance Criteria checkboxes?" -> If NO -> FAIL
   - "Did I write the phrase 'must be resolved before this PR can be approved' or similar in my findings?" -> If YES -> that means I found blocking issues -> FAIL

### Why This Gate Exists

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

> **The Findings->Decision Gate MUST be executed before posting any output. If you have not yet run the gate, STOP and run it now.**

Post your review result as a comment on the issue (NOT the PR).

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
