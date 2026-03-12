---
name: create-issue
description: >
  This skill should be used when the user asks to "create an issue", "file a bug",
  "create a feature request", "open a GitHub issue", "report a bug", "request a feature",
  "create a task", or describes a feature/bug they want tracked. Guides interactive issue
  creation with structured templates and optional autonomous label.
---

# Create GitHub Issue

Create well-structured GitHub issues from user descriptions through interactive clarification.

## Repository Detection

Detect the repository from the current git remote:

```bash
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
# Splits into OWNER and REPO_NAME
```

If detection fails, ask the user for the target repository.

## Process

### Step 1: Understand the Request

When the user describes a feature or bug, gather context through clarifying questions. Do NOT create the issue immediately.

**For features, clarify:**
- What is the user-facing goal? (not implementation details)
- What are the acceptance criteria? (how to verify it works)
- Are there UI/UX implications?
- What existing functionality does this relate to?
- Priority and scope constraints

**For bugs, clarify:**
- Steps to reproduce
- Expected vs actual behavior
- Environment (prod, staging, PR preview)
- Severity (blocking, degraded, cosmetic)
- Any error messages or logs

Ask 2-3 focused questions per round. Stop when there is enough information to write a clear issue.

### Step 2: Draft the Issue

Use the appropriate template based on issue type.

**Feature template:**

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

## Design Considerations
<Architecture notes, API changes, data model impact -- if applicable>

## Out of Scope
<Explicitly list what this issue does NOT cover>
```

**Bug template:**

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

### Step 2.5: Detect & Attach Workspace Changes

After drafting the issue, check the workspace for local changes (unstaged, staged, or untracked files) that may provide useful context for the autonomous dev agent. The dev agent works in an isolated git worktree from `main` and cannot see the user's local workspace, so attaching these changes to the issue bridges that gap.

**Skip this step silently if there are no local changes.**

#### 2.5.1 Detect Changes

Run these commands to check for workspace modifications:

```bash
# Check for any changes (modified, staged, untracked)
git status --short

# Count diff lines for staged + unstaged changes
STAGED_LINES=$(git diff --cached | wc -l)
UNSTAGED_LINES=$(git diff | wc -l)

# List untracked files (null-delimited for safe handling)
UNTRACKED=$(git ls-files --others --exclude-standard)

# Count untracked file content lines (handles spaces in filenames)
UNTRACKED_LINES=0
if [ -n "$UNTRACKED" ]; then
  UNTRACKED_LINES=$(git ls-files --others --exclude-standard -z | xargs -0 cat 2>/dev/null | wc -l)
fi

TOTAL_DIFF_LINES=$((STAGED_LINES + UNSTAGED_LINES + UNTRACKED_LINES))
```

If `git status --short` produces no output, skip to Step 3.

#### 2.5.2 Summarize and Confirm

Display a summary to the user:
- Number of files changed (modified + staged + untracked)
- Approximate lines added/removed
- List of affected file paths

Then ask:
> "These local changes appear related to this issue. Should I attach them to the issue so the dev agent can use them? (Y/n)"

If the user declines, skip to Step 3.

#### 2.5.3 Choose Attachment Strategy

| Total Diff Lines | Strategy | Details |
|------------------|----------|--------|
| < 500 lines | **Inline diff** | Embed combined diff in issue body as a collapsible code block |
| >= 500 lines | **Branch push** | Commit to `issue-context/<issue-number>` branch, reference in issue body |
| Push fails | **File list fallback** | List changed file paths with brief descriptions |

#### 2.5.4 Generate Combined Diff (for inline strategy)

Combine staged, unstaged, and untracked file contents into a single diff:

```bash
{
  # Staged changes
  git diff --cached
  # Unstaged changes
  git diff
  # Untracked files as new-file diffs
  git ls-files --others --exclude-standard | while IFS= read -r f; do
    [ -f "$f" ] || continue
    LINES=$(wc -l < "$f")
    echo "diff --git a/$f b/$f"
    echo "new file mode 100644"
    echo "--- /dev/null"
    echo "+++ b/$f"
    echo "@@ -0,0 +1,$LINES @@"
    sed 's/^/+/' "$f"
  done
}
```

#### 2.5.5 Add Pre-existing Changes Section to Issue Body

**For inline diff (< 500 lines)**, append to the issue body:

```markdown
## Pre-existing Changes

The following workspace changes were prepared before this issue was created.
Dev agent should apply these changes first before starting implementation.

<details>
<summary>Click to expand diff (N files changed, +X/-Y lines)</summary>

```diff
<combined diff output>
```
</details>
```

**For branch push (>= 500 lines)**, the branch is created after the issue (need issue number):

1. Stage all changes (including untracked files)
2. Create a commit: `context: workspace changes for issue #<number>`
3. Push to `issue-context/<issue-number>` branch
4. Restore the workspace to its original state

```bash
# Save current index state
git stash --keep-index --quiet 2>/dev/null || true

# Stage everything including untracked
git add -A

# Create temporary commit
git commit -m "context: workspace changes for issue #<number>"

# Push to context branch
git push origin HEAD:refs/heads/issue-context/<number>

# Undo the commit but keep changes in working tree
git reset HEAD~1

# Restore original index state
git stash pop --quiet 2>/dev/null || true
```

Then update the issue body to include:

```markdown
## Pre-existing Changes

The following workspace changes were prepared before this issue was created.
Dev agent should apply these changes first before starting implementation.

**Branch**: `issue-context/<issue-number>`

To apply in your worktree:
```bash
git cherry-pick issue-context/<issue-number>
# or
git diff main...issue-context/<issue-number> | git apply
```

### Files Changed
- `path/to/file1.ts` -- <brief description>
- `path/to/file2.test.ts` -- <brief description>
```

**File list fallback** (if branch push fails):

```markdown
## Pre-existing Changes

The following workspace changes were prepared before this issue was created.
These changes could not be automatically attached. The dev agent should recreate them based on the descriptions below.

### Files Changed
- `path/to/file1.ts` -- <brief description of changes>
- `path/to/file2.test.ts` -- <brief description of changes>

### Summary of Changes
<Prose description of what the changes do and why>
```

#### 2.5.6 Post-Attachment Cleanup (Optional)

After successfully attaching changes, ask the user:
> "The workspace changes have been attached to the issue. Would you like to clean up (discard) these local changes? (y/N)"

If the user agrees, only clean up the files that were part of the attached diff -- do NOT remove unrelated untracked files:

```bash
# Revert tracked file modifications (staged and unstaged)
git checkout -- <list of modified tracked files from the diff>

# Remove only the untracked files that were included in the diff
rm <list of untracked files from the diff>
```

**Important**: Do NOT use `git clean -fd` as it removes ALL untracked files, including those unrelated to the issue. Only remove files that were explicitly included in the attached diff.

Default is to keep the changes (user must explicitly opt in to cleanup).

### Step 3: Confirm with User

Present the draft issue to the user with:
1. Proposed title (concise, descriptive)
2. Full issue body (including Pre-existing Changes section if applicable)
3. Proposed labels
4. Whether to add `autonomous` label

Use AskUserQuestion to confirm:
- "Does this issue look correct? Should I create it?"
- Ask about autonomous label: whether AI should handle this automatically

### Step 4: Create the Issue

Use GitHub MCP tools or `gh` CLI to create the issue with:
- `title`: The confirmed title
- `body`: The confirmed body
- `labels`: Appropriate labels (see Label Guide below)

Report the created issue URL to the user.

**If branch push was deferred (large diff strategy):**

After the issue is created and the issue number is known:
1. Execute the branch push commands from Step 2.5.5 using the actual issue number
2. Update the issue body to include the branch reference section

## Label Guide

| Label | When to Apply |
|-------|-------------|
| `bug` | Bug reports |
| `enhancement` | Feature requests |
| `autonomous` | User confirms AI should handle dev/test/review/merge automatically |
| `no-auto-close` | Used with `autonomous` -- AI handles dev/test/review but stops before merge, requiring manual approval |
| `documentation` | Documentation-only changes |
| `good first issue` | Simple, well-scoped tasks |

## Autonomous Label Decision

After drafting the issue, explicitly ask the user whether to add the `autonomous` label.

Provide guidance on when `autonomous` is appropriate:
- **Good fit**: Well-defined scope, clear acceptance criteria, follows existing patterns, no ambiguous design decisions
- **Poor fit**: Requires significant architecture decisions, needs user input during development, involves sensitive infrastructure changes, exploratory/research tasks

Frame the question as:
> "Should this issue be handled by the autonomous development pipeline? The AI will automatically develop, test, review, and merge the changes. This works best for well-defined tasks with clear acceptance criteria."

**If the user selects `autonomous`, also ask about `no-auto-close`:**

> "Should this issue also have the `no-auto-close` label? With this label, the AI will handle development, testing, and review, but will **stop before merging** -- you'll be notified to make the final merge decision. This is recommended for sensitive infrastructure changes, features needing product sign-off, or experimental work."

**Label interaction summary:**
- `autonomous` alone = AI handles dev/test/review **and** auto-merges on pass
- `autonomous` + `no-auto-close` = AI handles dev/test/review but **stops before merge**, notifying the owner for manual approval

## Writing Guidelines

- **Title**: Start with verb, be specific. "Add pagination to plans list page" not "Plans page improvement"
- **Body**: Write for an AI developer who has access to the full codebase but no verbal context from this conversation
- **Acceptance criteria**: Must be objectively verifiable, not subjective
- **Scope**: Prefer smaller, focused issues over large multi-part ones
- **References**: Link to related issues, PRD sections, or code paths when relevant
- **Testing Requirements**: ALWAYS include the "Testing Requirements" section. The dev agent follows the project's TDD workflow but has been observed to skip E2E tests or test-case docs when the issue doesn't explicitly call them out. Be specific about:
  - Key scenarios each test type must cover (2-4 bullet points)
  - For bugs: the regression test must fail before the fix and pass after
