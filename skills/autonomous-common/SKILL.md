---
name: autonomous-common
description: >
  Shared infrastructure for the autonomous dev team skills. Provides workflow
  enforcement hooks (block-push-to-main, block-commit-outside-worktree,
  check-design-canvas, etc.) and agent-callable utility scripts
  (mark-issue-checkbox, reply-to-comments, resolve-threads, gh-as-user).
  This skill is loaded automatically as background context by other
  autonomous-* skills. Do not invoke directly.
user-invocable: false
---

# Autonomous Common Infrastructure

Shared hooks and scripts used by the autonomous-dev, autonomous-review, and autonomous-dispatcher skills.

## Setup for `npx skills add` Users

If you installed these skills via `npx skills add`, create symlinks at your project root so that path references in the other skills resolve correctly:

```bash
# From your project root:
ln -sf .claude/skills/autonomous-common/hooks hooks
ln -sf .claude/skills/autonomous-dispatcher/scripts scripts
```

Then copy and configure `.claude/settings.json` from the autonomous-dev-team template repository to enable workflow enforcement hooks.

## Hooks

Workflow enforcement hooks in `hooks/` directory. See `hooks/README.md` for the full reference.

| Hook | Type | Purpose |
|------|------|---------|
| `block-push-to-main.sh` | PreToolUse | Blocks direct pushes to main |
| `block-commit-outside-worktree.sh` | PreToolUse | Blocks commits outside worktrees |
| `check-design-canvas.sh` | PreToolUse | Reminds about design canvas |
| `check-code-simplifier.sh` | PreToolUse | Blocks commits until code-simplifier review |
| `check-pr-review.sh` | PreToolUse | Blocks pushes until PR review |
| `check-test-plan.sh` | PreToolUse | Reminds about test plan |
| `check-shellcheck.sh` | PreToolUse | Blocks commits if staged .sh files have shellcheck errors |
| `check-unit-tests.sh` | PreToolUse | Warns about unrun unit tests |
| `check-rebase-before-push.sh` | PreToolUse | Blocks push if behind origin/main |
| `warn-skip-verification.sh` | PreToolUse | Warns about --no-verify |
| `post-git-action-clear.sh` | PostToolUse | Clears state after git actions |
| `post-git-push.sh` | PostToolUse | Post-push CI/E2E reminder |
| `post-file-edit-reminder.sh` | PostToolUse | Reminds to run tests after edits |
| `verify-completion.sh` | Stop | Blocks completion until CI/E2E pass |

## Scripts

Agent-callable utility scripts in `scripts/` directory.

| Script | Used By | Purpose |
|--------|---------|---------|
| `mark-issue-checkbox.sh` | autonomous-dev, autonomous-review | Mark issue checkboxes as complete |
| `gh-as-user.sh` | autonomous-dev, autonomous-review | Run `gh` as real user (not bot) |
| `reply-to-comments.sh` | autonomous-dev | Reply to PR review comments |
| `resolve-threads.sh` | autonomous-dev | Batch resolve review threads |
