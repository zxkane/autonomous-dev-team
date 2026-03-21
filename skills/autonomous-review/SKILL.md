---
name: autonomous-review
description: >
  This skill should be used when performing autonomous PR code review,
  verifying acceptance criteria, resolving merge conflicts, running E2E
  tests via browser automation, or deciding whether to approve and merge
  a pull request. Use when asked to "review this PR", "check PR status",
  "run E2E verification", "verify acceptance criteria", "resolve merge
  conflicts", "approve and merge", or during autonomous review dispatch.
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/block-push-to-main.sh"
          timeout: 5
  Stop:
    - hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/verify-completion.sh"
          timeout: 10
---

# Autonomous Review Mode

You are reviewing a PR created by an autonomous development session. Be thorough and objective.

## Cross-Platform Notes

This skill works with any IDE/CLI that supports skills. Browser automation
steps use Chrome DevTools MCP — ensure your IDE has this MCP server configured
for E2E verification.

### Hooks (Optional)
If your IDE supports hooks (Claude Code, Kiro CLI), workflow enforcement
hooks in `hooks/` provide automatic gate checks. Without hooks, follow
each step manually.

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
- [ ] If bot review is missing and configured, trigger it using `scripts/gh-as-user.sh` (see below) and wait

> **IMPORTANT:** Some bot reviewers (e.g., Amazon Q Developer) ignore trigger comments posted by GitHub App bot accounts. When triggering bot reviews, you **MUST** use `scripts/gh-as-user.sh` so the comment is attributed to a real user:
> ```bash
> bash scripts/gh-as-user.sh pr comment {pr_number} --body "/q review"
> bash scripts/gh-as-user.sh pr comment {pr_number} --body "/codex review"
> ```
> Do NOT use the default `gh` wrapper for bot review triggers — it authenticates as a bot, which some reviewers ignore. If `scripts/gh-as-user.sh` is not available, fall back to `gh pr comment` directly.

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

Before starting the review, check whether the PR branch has merge conflicts with main. If it does, rebase the branch so the PR is mergeable. For the complete rebase procedure, conflict handling, and failure protocol, consult **`references/merge-conflict-resolution.md`**.

Quick check:
```bash
MERGEABLE=$(gh pr view <PR_NUMBER> --repo <REPO> --json mergeable -q '.mergeable')
```
- **MERGEABLE** — proceed to Review Process
- **CONFLICTING** — follow rebase procedure in references
- **UNKNOWN** — wait and retry (up to 3 times)

## Review Process

1. **Read the issue** to understand requirements
2. **Read ALL issue comments** to detect requirement changes (see "Requirement Drift Detection" below)
3. **Read the PR diff** thoroughly (`gh pr diff <number>`)
4. **Check CI status** (`gh pr checks <number>`)
5. **Read the files** for design docs, test cases, etc. to verify they exist
6. **Assess code quality** against the checklist above
7. **Verify bot reviewer findings** (if configured — see checklist section 5)
8. **Select happy path test cases** based on PR diff analysis (see below)
9. **Perform E2E verification** (if configured — see procedure below)
10. **Mark acceptance criteria** — for each verified criterion, mark its checkbox in the issue body (see "Marking Acceptance Criteria")
11. **MANDATORY SELF-CHECK GATE** — execute the Findings->Decision Gate (see below) BEFORE submitting any review verdict

## Requirement Drift Detection — MANDATORY

> **This step MUST be performed BEFORE reading the PR diff. Requirements can change after implementation via issue comments from the repo owner or maintainers.**

Read ALL comments on the issue (not just the body) and look for:
- Scope changes ("remove", "no longer", "drop", "don't support", "instead of")
- New requirements added after the original issue was created
- Corrections or clarifications from the repo owner
- Explicit instructions to the dev agent that may not yet be reflected in the PR code

```bash
# Read all issue comments to check for requirement changes
gh issue view <ISSUE_NUMBER> --repo <REPO> --json comments \
  -q '.comments[] | "\(.author.login) [\(.createdAt)]: \(.body[0:500])"'
```

If any requirement change is found that the PR code does **NOT** reflect:
- This is a **[BLOCKING] Requirement drift** finding
- The PR must be sent back to dev with specific instructions about what changed
- Quote the comment that changed the requirement
- List the specific code/files that need to be updated

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

For the complete step-by-step E2E procedure (browser automation, screenshot upload, test execution, report format), consult **`references/e2e-verification.md`**.

Key steps:
1. Verify preview URL is available
2. Open browser and navigate via Chrome DevTools MCP
3. Login with test user credentials
4. Execute happy path and feature test cases
5. Run regression checks (auth, navigation, console errors)
6. Post structured E2E report on the PR with screenshot evidence

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

> **This gate is NON-NEGOTIABLE. Execute this self-check BEFORE submitting any PR review (APPROVE or REQUEST_CHANGES) and BEFORE posting the verdict comment on the issue.**

For the complete gate procedure (finding classification, blocking vs non-blocking rules, self-check questions, decision criteria, and output format), consult **`references/decision-gate.md`**.

Summary of the hard rule:
- **ANY blocking finding -> verdict MUST be FAIL** (do NOT approve)
- **ZERO blocking findings -> verdict is PASS** (approve + merge)
- **There is NO middle ground** — blocking findings and APPROVE are mutually exclusive

Post the review result as a comment on the **issue** (NOT the PR). Use "Review PASSED" for pass, "Review findings:" for fail.

---

## References

For detailed procedures, consult:
- **`references/merge-conflict-resolution.md`** -- Complete rebase procedure, conflict handling, and failure protocol
- **`references/e2e-verification.md`** -- Browser automation steps, screenshot upload, test execution, E2E report format
- **`references/decision-gate.md`** -- Finding classification, blocking rules, decision criteria, and output format
