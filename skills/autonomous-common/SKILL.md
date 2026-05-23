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

### Project-side `scripts/` and `hooks/` symlinks

The IDE installer above only writes the IDE config file (e.g. `.claude/settings.json`). The project-side `<project>/scripts/` symlinks (so `dispatcher-tick.sh` finds `autonomous-dev.sh`, `lib-agent.sh`, etc.) and the `<project>/hooks` directory symlink are managed by a separate, IDE-agnostic bootstrap script — **the canonical pattern for projects whose `scripts/` already contains project-local files**:

```bash
# From your project root, after `npx skills add`:
bash .agents/skills/autonomous-common/scripts/install-project-hooks.sh
```

What it does:

- Symlinks every `*.sh` from the installed `autonomous-dispatcher/scripts/` into `<project>/scripts/`, **without overwriting** real (non-symlink) project-local files like `autonomous.conf` or per-project deploy helpers.
- Prunes dangling symlinks if upstream removes a file.
- Symlinks `<project>/hooks` → `autonomous-common/hooks` (refuses to shadow an existing real directory).
- Installs the per-worktree git `pre-push` hook (#65). Skip with `--no-git-hook`.

Idempotent — re-run after every `npx skills update` so newly-added upstream files (e.g. when this skill set adds a new `lib-*.sh`) are picked up automatically. Closes the silent-drift mode behind #153, where projects bootstrapped via per-file `ln -s` cargo-culted lists missed new files and `autonomous-review.sh` died on `source` of the missing file before any review work ran.

### Legacy directory-level fallback (deprecated)

The earlier docs suggested replacing the project's `scripts/` directory with a single symlink:

```bash
ln -sf .claude/skills/autonomous-dispatcher/scripts scripts   # DEPRECATED
```

This loses any project-local files in `scripts/`. Use `install-project-hooks.sh` instead — it does the right thing on a directory that already has project-local content, and re-running picks up upstream changes.

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
  - `install-project-hooks.sh` — IDE-agnostic project-side bootstrap: symlinks dispatcher `*.sh` into `<project>/scripts/` (without overwriting project-local files), symlinks `<project>/hooks`, prunes dangling links, installs the git pre-push hook. Re-run after every `npx skills update` (closes #153)
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
