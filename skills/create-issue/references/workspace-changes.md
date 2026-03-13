# Workspace Change Attachment

After drafting the issue, check the workspace for local changes (unstaged, staged, or untracked files) that may provide useful context for the autonomous dev agent. The dev agent works in an isolated git worktree from `main` and cannot see the user's local workspace, so attaching these changes to the issue bridges that gap.

**Skip this step silently if there are no local changes.**

## Detect Changes

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

If `git status --short` produces no output, skip workspace change attachment entirely.

## Summarize and Confirm

Display a summary to the user:
- Number of files changed (modified + staged + untracked)
- Approximate lines added/removed
- List of affected file paths

Then ask:
> "These local changes appear related to this issue. Should I attach them to the issue so the dev agent can use them? (Y/n)"

If the user declines, skip to issue creation.

## Choose Attachment Strategy

| Total Diff Lines | Strategy | Details |
|------------------|----------|--------|
| < 500 lines | **Inline diff** | Embed combined diff in issue body as a collapsible code block |
| >= 500 lines | **Branch push** | Commit to `issue-context/<issue-number>` branch, reference in issue body |
| Push fails | **File list fallback** | List changed file paths with brief descriptions |

## Generate Combined Diff (for inline strategy)

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

## Add Pre-existing Changes Section to Issue Body

**For inline diff (< 500 lines)**, append to the issue body:

```markdown
## Pre-existing Changes

The following workspace changes were prepared before this issue was created.
Dev agent should apply these changes first before starting implementation.

<details>
<summary>Click to expand diff (N files changed, +X/-Y lines)</summary>

\`\`\`diff
<combined diff output>
\`\`\`
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
\`\`\`bash
git cherry-pick issue-context/<issue-number>
# or
git diff main...issue-context/<issue-number> | git apply
\`\`\`

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

## Post-Attachment Cleanup (Optional)

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
