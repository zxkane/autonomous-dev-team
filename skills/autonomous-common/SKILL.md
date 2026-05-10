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

After `npx skills add`, run the installer for your coding agent once from the project root:

| Agent | Installer | Writes to |
|---|---|---|
| Claude Code | `bash .claude/skills/autonomous-common/scripts/install-claude-hooks.sh` | `.claude/settings.json` |
| Qoder | `bash .claude/skills/autonomous-common/scripts/install-qoder-hooks.sh` | `.qoder/settings.json` |
| Antigravity | `bash .claude/skills/autonomous-common/scripts/install-antigravity-hooks.sh` | `.antigravity/hooks.json` |
| Cursor | `bash .claude/skills/autonomous-common/scripts/install-cursor-hooks.sh` | `.cursor/hooks.json` |
| Kiro CLI | `bash .claude/skills/autonomous-common/scripts/install-kiro-hooks.sh [--agent <name>]` | `.kiro/agents/<name>.json` (default: `default`) |
| Gemini CLI | `bash .claude/skills/autonomous-common/scripts/install-gemini-hooks.sh` | `.gemini/settings.json` |
| Codex CLI | `bash .claude/skills/autonomous-common/scripts/install-codex-hooks.sh` | `.codex/hooks.json` + `.codex/config.toml` |
| Windsurf | `bash .claude/skills/autonomous-common/scripts/install-windsurf-hooks.sh` | `.windsurf/hooks.json` |
| Kimi CLI | `bash .claude/skills/autonomous-common/scripts/install-kimi-hooks.sh [--project]` | `~/.kimi/config.toml` (default; `--project` writes `.kimi/config.toml`) |

Each installer wires up the workflow hooks at the **project scope**, so they fire on every shell command in the repo — not only when an autonomous-* skill is explicitly loaded. Without this, the hook commands declared in skill frontmatter only run while a skill is active in the conversation, which is the regression that closed #68.

For the per-agent schema mapping reference, see [`docs/cross-agent-hooks.md`](https://github.com/zxkane/autonomous-dev-team/blob/main/docs/cross-agent-hooks.md).

### What if you can't run the installer

If installing into your `.claude/settings.json` is undesirable (shared repo, you want hooks isolated to autonomous-* skills only), the legacy fallback is to symlink the hook directories so the skill-scoped hook commands resolve:

```bash
# From your project root:
ln -sf .claude/skills/autonomous-common/hooks hooks
ln -sf .claude/skills/autonomous-dispatcher/scripts scripts
```

This keeps hooks scoped to the skills' frontmatter (Claude Code only fires them when a skill is active). If the push hook isn't blocking or the commit-outside-worktree check isn't running, check the symlinks — but prefer the installer for full coverage.

### Required Claude Code plugins

Claude Code only. The installer prompts for these; if installing manually, add to `.claude/settings.json` under `enabledPlugins`:

```json
{
  "enabledPlugins": {
    "code-simplifier@claude-plugins-official": true,
    "pr-review-toolkit@claude-plugins-official": true
  }
}
```

> IDEs without hook support (Cursor, Windsurf, Gemini CLI) skip both the installer and the symlinks — the skills work without hooks, but workflow steps must be followed manually.

## What's here

- **`hooks/`** — workflow-enforcement hooks (block-push-to-main, block-commit-outside-worktree, check-pr-review, check-shellcheck, verify-completion, …). See `hooks/README.md` for the canonical list and per-hook semantics.
- **`scripts/`** — agent-callable utilities used by the dev/review skills:
  - `lib-installer.sh` — shared merge/write helpers used by every per-agent installer
  - `lib-installer-translate.sh` — schema translation helpers for near-clone agents (event-name map, tool-name map, timeout-unit conversion)
  - `install-claude-hooks.sh` — Claude Code installer (writes `.claude/settings.json`)
  - `install-qoder-hooks.sh` — Qoder installer (writes `.qoder/settings.json` — same schema as Claude Code)
  - `install-antigravity-hooks.sh` — Antigravity installer (writes `.antigravity/hooks.json` — hooks-only file; contract is community-observed, undocumented by Google)
  - `install-cursor-hooks.sh` — Cursor installer (writes `.cursor/hooks.json` — `version: 1` envelope, camelCase events, `Shell` matcher)
  - `install-kiro-hooks.sh` — Kiro CLI / Amazon Q installer (writes `.kiro/agents/<name>.json` — agent definition with camelCase events, `execute_bash`/`fs_write` matchers, `timeout_ms` in milliseconds)
  - `install-gemini-hooks.sh` — Gemini CLI installer (writes `.gemini/settings.json` — `BeforeTool`/`AfterTool` events, `run_shell_command`/`write_file`/`replace` matchers)
  - `install-codex-hooks.sh` — Codex CLI installer (writes `.codex/hooks.json` + sets `[features] codex_hooks = true` in `.codex/config.toml`)
  - `install-windsurf-hooks.sh` — Windsurf installer (writes `.windsurf/hooks.json` — snake_case events that fold matcher info; no per-tool matcher field)
  - `install-kimi-hooks.sh` — Kimi CLI installer (writes `~/.kimi/config.toml` user-level by default, or `.kimi/config.toml` with `--project`; emits TOML `[[hooks]]` blocks)
  - `claude-settings.template.json` — canonical hook list applied by all per-agent installers
  - `gh-as-user.sh` — runs `gh` as a real user (needed when retriggering bot reviews like `/q review`)
  - `mark-issue-checkbox.sh` — toggles GitHub issue body checkboxes from the agent
  - `reply-to-comments.sh` — replies to PR review comments
  - `resolve-threads.sh` — batch-resolves review threads on a PR

> The hooks and scripts are documented in detail in their respective README/source files. This SKILL.md only catalogs what's available so you can find the right file to edit.
