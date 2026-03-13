# Workflow Enforcement Hooks

These hooks enforce the TDD development workflow defined in `CLAUDE.md`. They ensure that every code change follows the mandatory steps: design canvas, git worktree isolation, test-first development, code review, PR review, CI verification, and E2E testing.

## Claude Code Setup

Claude Code hooks are already configured in `.claude/settings.json`. No additional setup is needed — the hooks run automatically when Claude Code executes tool calls.

### Required Plugins

The following plugins must be enabled (configured via `enabledPlugins` in `.claude/settings.json`):

- `code-simplifier@claude-plugins-official` — Reviews code for simplification opportunities before commit
- `pr-review-toolkit@claude-plugins-official` — Performs PR-level review before push

### Hook Configuration

The `.claude/settings.json` file defines three hook lifecycle events:

- **PreToolUse** — Runs before a tool executes. Used to block or warn about disallowed actions.
- **PostToolUse** — Runs after a tool executes. Used to clear state and show reminders.
- **Stop** — Runs when the agent attempts to finish. Used to verify all workflow steps are complete.

Each hook entry specifies a `matcher` (the tool name it applies to), the shell command to run, and a timeout in seconds. See `.claude/settings.json` for the full configuration.

## Kiro CLI Setup

Kiro CLI supports hooks. Adapt the Claude Code hook configuration for Kiro's hook format. See Kiro CLI documentation for details.

## Other IDEs

IDEs without hook support (Cursor, Windsurf, Gemini CLI, etc.) rely on skill instructions for workflow enforcement. Follow each step in the autonomous-dev skill manually.

## Hook Reference

| Hook | Type | Trigger | Purpose |
|------|------|---------|---------|
| `block-push-to-main.sh` | PreToolUse | Bash | Blocks direct pushes to main branch |
| `block-commit-outside-worktree.sh` | PreToolUse | Bash | Blocks commits outside git worktrees |
| `check-design-canvas.sh` | PreToolUse | Bash | Reminds about design canvas before coding |
| `check-code-simplifier.sh` | PreToolUse | Bash | Blocks commits until code-simplifier review |
| `check-pr-review.sh` | PreToolUse | Bash | Blocks pushes until PR review complete |
| `check-test-plan.sh` | PreToolUse | Write/Edit | Reminds about test plan before code changes |
| `check-unit-tests.sh` | PreToolUse | Bash | Warns about unrun unit tests |
| `warn-skip-verification.sh` | PreToolUse | Bash | Warns about --no-verify usage |
| `check-rebase-before-push.sh` | PreToolUse | Bash | Blocks push if branch is behind origin/main |
| `post-git-action-clear.sh` | PostToolUse | Bash | Clears state after git actions |
| `post-git-push.sh` | PostToolUse | Bash | Post-push reminder for CI/E2E |
| `post-file-edit-reminder.sh` | PostToolUse | Write/Edit | Reminds to run tests after edits |
| `verify-completion.sh` | Stop | All | Blocks task completion until CI/E2E pass |
| `lib.sh` | Library | N/A | Shared utility functions |
| `state-manager.sh` | Library | N/A | Workflow state management |

## State Manager Usage

The state manager tracks which workflow steps have been completed in the current session:

```bash
hooks/state-manager.sh list          # View current states
hooks/state-manager.sh mark <action> # Mark action as complete
hooks/state-manager.sh clear <action> # Clear state
```
