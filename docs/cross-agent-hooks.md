# Cross-Agent Hook Support

Reference for installing the autonomous-dev-team workflow hooks across coding agents that support hook-style enforcement (a shell command runs before/after a tool call, with the option to block).

## Canonical hook intent (agent-agnostic)

The hooks themselves live in `skills/autonomous-common/hooks/` and are agent-portable: they read JSON from stdin, exit `0` to allow or `2` to block, and use `$CLAUDE_PROJECT_DIR` to find scripts. This contract works on every agent in the table below.

What differs between agents is **how to declare which script runs when** — i.e. the per-agent config file path, schema, event names, and tool-name matchers.

## Per-agent matrix

| CLI | Config path | Schema flavor | Tool-name matchers | Block exit | Installer |
|---|---|---|---|---|---|
| **Claude Code** | `.claude/settings.json` | Reference (JSON, `PreToolUse`, …) | `Bash`, `Write`, `Edit` | `2` | `install-claude-hooks.sh` (PR-5) |
| **Qoder** | `.qoder/settings.json` | Identical to Claude Code | `Bash`, `Write`, `Edit` | `2` | `install-qoder-hooks.sh` (PR-11a) |
| **Antigravity** | `.antigravity/hooks.json` | Identical to Claude Code (undocumented) | `Bash` | `2` | `install-antigravity-hooks.sh` (PR-11a) |
| **Cursor** | `.cursor/hooks.json` | Claude-style, camelCase events, `version: 1` envelope | `Shell` (or pipe regex on cmd) | `2` | `install-cursor-hooks.sh` (PR-11b) |
| **Kiro CLI / Amazon Q** | `.kiro/agents/<name>.json` | Agent definition; camelCase events; `timeout_ms` (ms not seconds) | `execute_bash`, `fs_write` (Write+Edit unified) | `2` | `install-kiro-hooks.sh` (PR-11b) |
| **Gemini CLI** | `.gemini/settings.json` | `BeforeTool`/`AfterTool` events; provides `$CLAUDE_PROJECT_DIR` env compat alias | `run_shell_command`, `write_file`, `replace` | `2` | `install-gemini-hooks.sh` (PR-11b) |
| **Codex CLI** | `.codex/hooks.json` + `[features]codex_hooks=true` in `config.toml` | Claude-style (modeled verbatim) | `Bash`, `Write`, `Edit` (undocumented but inferred) | `2` | `install-codex-hooks.sh` (PR-11b) |
| **Windsurf** | `.windsurf/hooks.json` | snake_case events that fold matcher info; **no matcher field** on entries | event encodes the kind: `pre_run_command` (Bash) / `pre_write_code` (Write+Edit merged) / etc. | `2` | `install-windsurf-hooks.sh` (PR-11c) |
| **Kimi CLI** | `~/.kimi/config.toml` (or `.kimi/config.toml` with `--project`) | TOML, `[[hooks]]` array of tables | exact / regex (`RunShell`, `WriteFile`, `StrReplaceFile`) | `2` | `install-kimi-hooks.sh` (PR-11c) |

## Per-agent installation

After `npx skills add zxkane/autonomous-dev-team`, run **one** of these from the project root:

```bash
# Claude Code
bash .claude/skills/autonomous-common/scripts/install-claude-hooks.sh

# Qoder
bash .claude/skills/autonomous-common/scripts/install-qoder-hooks.sh

# Antigravity (undocumented contract — see caveat below)
bash .claude/skills/autonomous-common/scripts/install-antigravity-hooks.sh

# Cursor
bash .claude/skills/autonomous-common/scripts/install-cursor-hooks.sh

# Kiro CLI / Amazon Q (default agent name is "default"; override with --agent <name>)
bash .claude/skills/autonomous-common/scripts/install-kiro-hooks.sh

# Gemini CLI
bash .claude/skills/autonomous-common/scripts/install-gemini-hooks.sh

# Codex CLI (also enables [features] codex_hooks = true in .codex/config.toml)
bash .claude/skills/autonomous-common/scripts/install-codex-hooks.sh

# Windsurf (folds Bash/Write/Edit matchers into pre_run_command / pre_write_code events)
bash .claude/skills/autonomous-common/scripts/install-windsurf-hooks.sh

# Kimi CLI (default: ~/.kimi/config.toml; --project for .kimi/config.toml)
bash .claude/skills/autonomous-common/scripts/install-kimi-hooks.sh
```

Each installer is idempotent and preserves any other top-level keys you have in the agent's config file. They also install a per-worktree git pre-push hook (closes #65); pass `--no-git-hook` to skip.

## Caveats

- **Antigravity**: Google has not documented hook support. Community evidence shows the Claude Code schema works in practice, but it could change without notice. Treat as best-effort.
- **Codex CLI** (PR-11b): hook support is behind an experimental feature flag (`codex_hooks = true` in `~/.codex/config.toml`). Tool-name matchers like `Bash`, `Write` are modeled on Claude Code but not officially documented.
- **Windsurf**: no per-tool matcher field — `pre_run_command` fires for every shell command, `pre_write_code` for every file write/edit. Hooks must self-filter inside the script (e.g., `block-push-to-main.sh` already inspects the command). The installer folds Claude's `(event, matcher)` pairs into Windsurf's tool-specific events.
- **Kimi CLI**: TOML config, beta feature upstream. Tool names differ (`WriteFile`/`StrReplaceFile`/`RunShell` rather than Claude's `Write`/`Edit`/`Bash`). Default install target is user-level (`~/.kimi/config.toml`); `--project` writes `.kimi/config.toml` (experimental — Kimi may only read user-level).

## Hook-script portability

Scripts under `skills/autonomous-common/hooks/` use the canonical contract:

```
stdin: {"hook_event_name": "...", "tool_name": "...", "tool_input": {...}, "cwd": "...", ...}
exit 0: allow (stdout added to agent context)
exit 2: block (stderr fed back to LLM as the reason)
env:   $CLAUDE_PROJECT_DIR points at the repo root
```

This works on every agent in the matrix. **Gemini CLI explicitly provides `$CLAUDE_PROJECT_DIR`** as a Claude Code compatibility alias. The other agents either provide an equivalent (e.g. `CURSOR_PROJECT_DIR`) or run hooks with `cwd = project root` so the relative path inside `tool_input.cwd` works.

## Adding a new agent

If you want to support an agent not yet in the matrix:

1. Verify the agent supports hooks at all (check official docs).
2. Document the schema in this file's matrix.
3. Add an `install-<agent>-hooks.sh` under `skills/autonomous-common/scripts/`. Use `lib-installer.sh` helpers (`require_jq`, `merge_hooks_settings`, `write_hooks_only_settings`, `install_per_worktree_pre_push`).
4. Update `skills/autonomous-common/SKILL.md` Setup section.
5. Add a unit test under `tests/unit/`.

The canonical template at `skills/autonomous-common/scripts/claude-settings.template.json` is the single source of truth — your installer translates it to the agent's flavor at install time.
