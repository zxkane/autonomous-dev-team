---
name: autonomous-dev
description: Use when working on an autonomous GitHub issue. Adapts github-workflow for fully autonomous execution without user interaction. Triggered by scripts/autonomous-dev.sh wrapper.
---

# Autonomous Development Mode

This skill wraps the standard github-workflow for autonomous execution. You are running inside a wrapper script that will handle label state transitions on exit.

## Key Differences from Interactive Mode

1. **NO user questions** - make reasonable decisions autonomously
2. **Report to issue** - post progress comments to the GitHub issue
3. **Design canvas** - create it but skip interactive approval, proceed immediately
4. **Worktree** - MANDATORY, same as interactive mode
5. **Error handling** - on blocking errors, document in issue comment and exit cleanly
6. **No merge** - the wrapper/review process handles merging

## Workflow

1. Load /github-workflow skill
2. Read the issue body for requirements and acceptance criteria
3. **Check for already-completed work** (see "Resume Awareness")
4. **Check for pre-existing changes** (see below)
5. Execute Steps 1-12 of github-workflow autonomously with these adaptations:
   - Step 1 (Design): Create design doc, skip user approval
   - **After each requirement implemented**: Mark checkbox (see "Marking Requirements Progress")
   - Step 7 (PR creation): Trigger bot review if configured (see "Bot Review Integration")
   - Step 12 (Verification): Run verification, then STOP (don't wait for user merge)
6. Post progress comments to the issue at each major milestone:
   - After design canvas created
   - After PR created (include PR link)
   - After CI checks pass
   - After verification complete
7. Ensure PR description includes `Closes #<issue-number>` or `Fixes #<issue-number>`

## Marking Requirements Progress

After implementing each requirement item from the issue, mark the corresponding checkbox in the issue body. This provides real-time visibility and enables resume on crash.

### Marking a Checkbox

After completing a requirement, call:

```bash
bash scripts/mark-issue-checkbox.sh <ISSUE_NUMBER> "<checkbox text>"
```

Where `<checkbox text>` is a substring matching the requirement line in the issue body. Use enough text to uniquely identify the checkbox.

Example: If the issue has `- [ ] Create MobileMenu component`, run:
```bash
bash scripts/mark-issue-checkbox.sh 42 "Create MobileMenu component"
```

### When to Mark

- Mark each requirement **immediately after implementing it** (not in a batch at the end)
- If a requirement spans multiple sub-items (nested checkboxes), mark the sub-items individually
- If implementation covers a group of related items, mark them together after the group is done

### Do NOT Mark

- Acceptance Criteria items — those are for the review agent
- Items you haven't implemented yet

## Resume Awareness

On resume (or new session for a previously started issue), check which requirements are already done:

1. Read the issue body via `gh issue view <ISSUE_NUMBER> --json body -q '.body'`
2. Parse the `## Requirements` section for checkbox states
3. Items marked `- [x]` are already implemented — **skip them**
4. Items marked `- [ ]` are remaining work — implement these
5. Verify the existing code in the worktree matches the checked items (quick sanity check)

This prevents duplicate work when the dev agent crashes mid-implementation and is resumed by the dispatcher.

## Applying Pre-existing Changes

Before starting development, check the issue body for a `## Pre-existing Changes` section. This section contains workspace changes that the issue creator prepared beforehand (e.g., regression tests, prototype code). Apply these changes as the first step in the worktree.

### Detection

After creating the worktree and before writing any code, scan the issue body for:
1. A `## Pre-existing Changes` heading
2. Either a **branch reference** (`issue-context/<issue-number>`) or an **inline diff** block

### Applying from Branch Reference

If the issue body contains `**Branch**: \`issue-context/<number>\``:

```bash
# Option 1: Cherry-pick (preserves commit metadata)
git cherry-pick issue-context/<number>

# Option 2: Apply as patch (if cherry-pick conflicts)
git diff main...issue-context/<number> | git apply
git add -A
git commit -m "apply: pre-existing workspace changes from issue #<number>"
```

### Applying from Inline Diff

If the issue body contains a diff code block inside `<details>`:

1. Extract the diff content from the issue body
2. Save it to a temporary file
3. Apply it:

```bash
git apply /tmp/pre-existing-changes.patch
rm /tmp/pre-existing-changes.patch
git add -A
git commit -m "apply: pre-existing workspace changes from issue #<number>"
```

### Error Handling

- If cherry-pick or apply fails due to conflicts, log a warning in the issue comment and proceed with normal development
- If the branch does not exist, skip silently
- Always continue with normal development after applying (or failing to apply) pre-existing changes

## Bot Review Integration

After creating a PR, the dev agent should trigger and handle any configured bot reviewers (e.g., Amazon Q Developer, Codex).

### Trigger Bot Review

Some bot reviewers ignore comments posted by GitHub App bot accounts. If your project uses `scripts/gh-as-user.sh`, use it to trigger bot reviews so the comment is attributed to a real user:

```bash
bash scripts/gh-as-user.sh pr comment {pr_number} --body "/q review"
```

> **Do NOT use the default `gh` wrapper** (`gh-with-token-refresh.sh`) for bot review triggers — it authenticates as a bot, which some reviewers ignore. All other `gh` operations should continue using the default `gh` wrapper.

### Wait for Bot Review

Poll for bot review to appear (timeout 3 minutes):

```bash
# Poll every 30 seconds for up to 3 minutes
for i in $(seq 1 6); do
  REVIEWS=$(gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews \
    --jq '[.[] | select(.user.login == "<bot-login>")] | length')
  if [ "$REVIEWS" -gt 0 ]; then
    echo "Bot review found"
    break
  fi
  sleep 30
done
```

### Handle Bot Review Findings

After bot review appears, read and address all findings:

1. **Read bot review comments**: Use `gh api repos/{owner}/{repo}/pulls/{pr_number}/comments` and filter by bot author
2. **For each finding**:
   - **Real issue**: fix it, commit, push
   - **False positive**: reply explaining why, resolve the thread
3. **Re-trigger** bot review via `bash scripts/gh-as-user.sh pr comment {pr_number} --body "<trigger command>"` if fixes were pushed
4. **Iterate** until no unresolved bot findings remain

If bot review does not appear within 3 minutes, proceed without it — the review agent will re-trigger bot review during its verification step.

## Local E2E Verification (Before Push)

Before pushing changes that modify E2E tests or UI components, verify the changes are sound:

1. **If E2E tests were modified**, run a quick local check:
   ```bash
   # Verify TypeScript compilation of E2E tests (if using TypeScript)
   bunx tsc --noEmit --project tsconfig.json

   # Verify test helper imports are correct
   grep -l "takeScreenshot" e2e/*.spec.ts
   ```

2. **Screenshot generation will be verified in CI** — ensure your Playwright config includes a JSON reporter and screenshot helpers save to a known directory. CI should upload these as artifacts.

3. **Local dev server**: For local E2E testing:
   ```bash
   # Option A: Let Playwright start the dev server automatically
   bunx playwright test

   # Option B: Start dev server manually first
   PLAYWRIGHT_BASE_URL=http://localhost:3000 bunx playwright test
   ```

## Decision Making Guidelines

When you need to make a decision that would normally require user input:

| Situation | Decision |
|-----------|----------|
| Architecture choice between options | Pick the simpler, more maintainable option |
| UI/UX design decisions | Follow existing patterns in the codebase |
| Scope ambiguity | Implement the minimum viable interpretation |
| Test coverage questions | Write tests for happy path + main error cases |
| Performance vs simplicity | Choose simplicity unless perf is the issue's focus |

## Error Recovery

- If a tool/API fails, retry once with a brief pause
- If CI fails, analyze logs, fix, and push again (max 3 attempts)
- If you cannot resolve an issue after 3 attempts, post a detailed error comment on the issue and exit
- The wrapper script will transition the issue to `pending-review` regardless of exit code
