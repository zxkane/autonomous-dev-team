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

If you installed these skills via `npx skills add`, hook commands in the `autonomous-dev` and `autonomous-review` SKILL.md frontmatter reference `$CLAUDE_PROJECT_DIR/hooks/` and `$CLAUDE_PROJECT_DIR/scripts/`, but `npx skills add` places these files inside `.claude/skills/`. Create symlinks at your project root so the paths resolve:

```bash
# From your project root:
ln -sf .claude/skills/autonomous-common/hooks hooks
ln -sf .claude/skills/autonomous-dispatcher/scripts scripts
```

Required Claude Code plugins (add to `.claude/settings.json` under `enabledPlugins`):

```json
{
  "enabledPlugins": {
    "code-simplifier@claude-plugins-official": true,
    "pr-review-toolkit@claude-plugins-official": true
  }
}
```

> IDEs without hook support (Cursor, Windsurf, Gemini CLI) don't need symlinks — the skills work without hooks, but workflow steps must be followed manually.

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
| `verify-completion.sh` | Stop | Blocks completion until CI/E2E pass |

## Scripts

Agent-callable utility scripts in `scripts/` directory.

| Script | Used By | Purpose |
|--------|---------|---------|
| `mark-issue-checkbox.sh` | autonomous-dev, autonomous-review | Mark issue checkboxes as complete |
| `gh-as-user.sh` | autonomous-dev, autonomous-review | Run `gh` as real user (not bot) |
| `reply-to-comments.sh` | autonomous-dev | Reply to PR review comments |
| `resolve-threads.sh` | autonomous-dev | Batch resolve review threads |
