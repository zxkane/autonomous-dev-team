---
name: autonomous-common
description: >
  Use when setting up, troubleshooting, or modifying the shared hooks and
  agent-callable utility scripts that enforce the autonomous dev/review
  workflow. Triggers on phrases like "push to main is blocked",
  "block-commit-outside-worktree hook failing", "configure hooks after
  npx skills add", "what does check-pr-review.sh do", "set up workflow
  hook symlinks", or when editing files under `skills/autonomous-common/`.
  Provides the hooks the autonomous-dev / autonomous-review skills depend
  on, plus utility scripts (gh-as-user.sh, mark-issue-checkbox.sh,
  reply-to-comments.sh, resolve-threads.sh).
---

# Autonomous Common Infrastructure

Shared workflow-enforcement hooks and agent-callable utility scripts used by `autonomous-dev`, `autonomous-review`, and `autonomous-dispatcher`. The other autonomous-* skills reference scripts and hooks here — when those reference paths break, this is usually the skill to look at.

## Setup for `npx skills add` Users

If you installed these skills via `npx skills add`, hook commands in the `autonomous-dev` and `autonomous-review` SKILL.md frontmatter reference `$CLAUDE_PROJECT_DIR/hooks/` and `$CLAUDE_PROJECT_DIR/scripts/`, but `npx skills add` places these files inside `.claude/skills/`. Create symlinks at your project root so the paths resolve:

```bash
# From your project root:
ln -sf .claude/skills/autonomous-common/hooks hooks
ln -sf .claude/skills/autonomous-dispatcher/scripts scripts
```

> Without these symlinks, hook commands silently fail to fire (they look up `$CLAUDE_PROJECT_DIR/hooks/...` but the path doesn't exist). If "the push hook isn't blocking" or "the commit-outside-worktree check isn't running" — check the symlinks first.

### Required Claude Code plugins

Claude Code only. Add to `.claude/settings.json` under `enabledPlugins`:

```json
{
  "enabledPlugins": {
    "code-simplifier@claude-plugins-official": true,
    "pr-review-toolkit@claude-plugins-official": true
  }
}
```

> IDEs without hook support (Cursor, Windsurf, Gemini CLI) don't need symlinks or plugins — the skills work without hooks, but workflow steps must be followed manually.

## What's here

- **`hooks/`** — workflow-enforcement hooks (block-push-to-main, block-commit-outside-worktree, check-pr-review, check-shellcheck, verify-completion, …). See `hooks/README.md` for the canonical list and per-hook semantics.
- **`scripts/`** — agent-callable utilities used by the dev/review skills:
  - `gh-as-user.sh` — runs `gh` as a real user (needed when retriggering bot reviews like `/q review`)
  - `mark-issue-checkbox.sh` — toggles GitHub issue body checkboxes from the agent
  - `reply-to-comments.sh` — replies to PR review comments
  - `resolve-threads.sh` — batch-resolves review threads on a PR

> The hooks and scripts are documented in detail in their respective README/source files. This SKILL.md only catalogs what's available so you can find the right file to edit.
