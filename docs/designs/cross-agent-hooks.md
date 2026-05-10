# Design Canvas — Cross-Agent Hook Installers (PR-11)

**Branch**: `feat/cross-agent-hooks`
**Closes**: nothing (no specific issue — extends PR-5 / PR-10 to cover 7 additional coding agents).
**PR breakdown**: this is **PR-11a**. PR-11b adds near-clone installers (Cursor, Kiro, Gemini, Codex). PR-11c adds divergent installers (Windsurf, Kimi).

---

## Why

Today the autonomous workflow only enforces hooks for Claude Code (`install-claude-hooks.sh` from PR-5). Users running the same skills under Cursor / Kiro / Gemini / etc. get the workflow logic but no guard rails — pushes to main, commits outside worktrees, etc. all become un-enforced.

Research across 8 popular agents shows **all of them support hooks** with a remarkably consistent contract (JSON config, exit code 2 = block, stdin JSON payload). The schemas differ but translate cleanly.

This PR (11a) ships:

1. The **canonical hook intent** doc (`docs/cross-agent-hooks.md`) — one source of truth for what each hook does, used by all installers.
2. **Schema mapping reference** — exactly how Claude Code's `PreToolUse + matcher: "Bash"` translates to each agent's flavor.
3. Installers for the 2 easiest agents: **Qoder** and **Antigravity**, both of which adopted Claude Code's schema verbatim.

PR-11b and PR-11c will pick up the harder translations.

## Cross-agent landscape

| CLI | Hook config | Schema flavor | Tool-name matcher | Block exit |
|---|---|---|---|---|
| **Claude Code** | `.claude/settings.json` | reference (JSON, `PreToolUse` etc.) | `Bash`, `Write`, `Edit` | 2 |
| **Qoder** | `.qoder/settings.json` | **identical** to Claude Code | `Bash`, `Write`, `Edit` | 2 |
| **Antigravity** | `.antigravity/hooks.json` | identical (undocumented but works) | `Bash` | 2 |
| Cursor (PR-11b) | `.cursor/hooks.json` | Claude-style + shell-specific event | `Shell` (or pipe regex on cmd) | 2 |
| Kiro CLI (PR-11b) | `.kiro/agents/*.json` | camelCase events, `timeout_ms` | `execute_bash`, `fs_write` | 2 |
| Gemini CLI (PR-11b) | `.gemini/settings.json` | `BeforeTool`/`AfterTool` regex | `run_shell_command`, `write_file`, `replace` | 2 |
| Codex CLI (PR-11b) | `.codex/hooks.json` + flag | Claude-style (modeled on it) | undocumented | 2 |
| Windsurf (PR-11c) | `.windsurf/hooks.json` | snake_case, **no matcher** | filter inside script | 2 |
| Kimi CLI (PR-11c) | `~/.kimi/config.toml` | TOML, `[[hooks]]` array | regex (e.g. `WriteFile\|StrReplaceFile`) | 2 |

Universal: **exit 2 = block**, stdin = JSON context. Hook scripts under `skills/autonomous-common/hooks/` already use this contract.

## Why Qoder + Antigravity first

Both adopted Claude Code's schema 1:1:

- Same event names (`PreToolUse`, `PostToolUse`, `Stop`, ...)
- Same `matcher` field semantics
- Same tool names (`Bash`, `Write`, `Edit`)
- Same JSON nesting

Their installers are essentially:

```bash
bash install-claude-hooks.sh   # but writes to .qoder/settings.json
```

Plus a few one-line tweaks (output path, friendly name in messages). No translation needed. This makes them the ideal proving ground for the canonical-hook-intent design.

## Canonical hook intent

The "hook intent" is what we want to enforce, agent-agnostic. From `claude-settings.template.json` (PR-5):

| Intent | Hook script | When |
|---|---|---|
| Block direct push to trunk | `block-push-to-main.sh` | Before any shell command |
| Block commit outside worktree | `block-commit-outside-worktree.sh` | Before any shell command |
| Verify CI on completion | `verify-completion.sh` | On Stop |
| (others under `hooks/`) | various | Before Bash / Edit / Write |

These run identically on any agent that supports the canonical contract:

```
stdin:  {"hook_event_name": "...", "tool_name": "...", "tool_input": {...}, "cwd": "...", ...}
exit 0: allow
exit 2: block (stderr → LLM)
```

All 8 researched agents satisfy this contract. The differences are just **how to declare which script runs when** in their respective config files.

## Schema mapping (PR-11a only — 11b/11c expand)

### Claude Code → Qoder
```diff
- .claude/settings.json
+ .qoder/settings.json
```
That's it. Same file content.

### Claude Code → Antigravity
```diff
- .claude/settings.json
+ .antigravity/hooks.json
```
Same content. Antigravity's `hooks.json` accepts the Claude `settings.json` `hooks` block verbatim (per community evidence — undocumented but consistent).

## Installer architecture

Every installer follows the same pattern:

```bash
install-${agent}-hooks.sh:
  1. Load $SOURCE = path to claude-settings.template.json
  2. Translate to agent-specific schema (for Qoder/Antigravity: identity)
  3. Resolve $TARGET = agent's config path
  4. Merge with existing $TARGET (preserve user's other settings) — same jq-based merge as install-claude-hooks.sh
  5. Optionally install per-worktree git pre-push hook (same as install-claude-hooks.sh, untouched)
```

For PR-11a's two agents, the translation step is identity. The merge step is the existing jq pattern from `install-claude-hooks.sh`.

## Refactor strategy

`install-claude-hooks.sh` (177 lines, written in PR-5) has the merge logic + per-worktree-hook installation logic that we want to share across all installers. Two options:

1. **Extract a shared lib** — `lib-installer.sh` with `merge_settings_into <source> <target>` and `install_per_worktree_pre_push`. Each agent installer becomes ~30 lines of "set source, set target, call lib".
2. **Each installer copy-pastes** — fast but fragile.

Option 1 is the right call. PR-11a includes the refactor.

## Files (PR-11a only)

New:
- `docs/cross-agent-hooks.md` — canonical hook intent + per-agent schema mapping reference (this is the durable spec)
- `skills/autonomous-common/scripts/lib-installer.sh` — shared merge/install logic
- `skills/autonomous-common/scripts/install-qoder-hooks.sh`
- `skills/autonomous-common/scripts/install-antigravity-hooks.sh`
- `tests/unit/test-install-qoder-hooks.sh`
- `tests/unit/test-install-antigravity-hooks.sh`
- `tests/unit/test-lib-installer.sh`

Modified:
- `skills/autonomous-common/scripts/install-claude-hooks.sh` — switch to lib-installer.sh (preserve byte-equivalent behavior)
- `skills/autonomous-common/SKILL.md` — Setup section now lists 3 installers (Claude / Qoder / Antigravity); other 5 marked as "coming in PR-11b/c"

## Out of scope (deferred to PR-11b / PR-11c)

- Cursor, Kiro CLI, Gemini CLI, Codex installers (need event-name + tool-name translation; PR-11b)
- Windsurf, Kimi CLI installers (schema-divergent; PR-11c)
- Updating `.kiro/agents/default.json` — already correct in this repo

## Tests

For each installer:
- Sample `.qoder/settings.json` is created with the right hooks block when run on a clean dir
- Existing `.qoder/settings.json` (with other operator config) is preserved + merged
- Idempotent on second run
- Trust-gate semantics inherited from PR-5's claude installer

`tests/unit/test-lib-installer.sh` tests the shared merge logic in isolation.

## Risk

Low. New installers are additive — no existing user gets a different experience until they explicitly run them. The `install-claude-hooks.sh` refactor must preserve byte-identical output (regression test verifies).
