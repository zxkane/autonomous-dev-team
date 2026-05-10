# Design Canvas — Cross-Agent Hook Installers PR-11c (Windsurf + Kimi)

**Branch**: `feat/cross-agent-hooks-c`
**Closes**: nothing (closes the cross-agent hook coverage extension started in PR-11a/PR-11b).
**PR breakdown**: this is PR-11c — the final tier. After this lands, all 9 researched agents have working installers.

---

## Why two more

PR-11a covered Claude-Code-clone agents (Qoder, Antigravity). PR-11b covered near-clone agents (Cursor, Kiro, Gemini, Codex) where the schema is JSON with translatable event/tool names. **PR-11c covers the schema-divergent tier**:

- **Windsurf**: JSON, but the schema has NO per-tool matcher field. Events themselves are tool-specific (`pre_run_command`, `pre_write_code`, `pre_read_code`). Translation has to "fold" Claude's `event + matcher` pair into Windsurf's single tool-specific event.
- **Kimi CLI**: TOML, not JSON. `[[hooks]]` is a flat array of hook blocks rather than nested under events.

Both are confirmed-supported per the research from before PR-11a, but they don't fit the existing `lib-installer-translate.sh` pattern from PR-11b.

## Per-agent mapping

### Windsurf

| Claude (template) | Windsurf event | Filter |
|---|---|---|
| `PreToolUse + matcher: "Bash"` | `pre_run_command` | none — fires for all shell commands |
| `PostToolUse + matcher: "Bash"` | `post_run_command` | none |
| `PreToolUse + matcher: "Write"` | `pre_write_code` | none |
| `PreToolUse + matcher: "Edit"` | `pre_write_code` (merged with Write — same dedup as Kiro) | none |
| `Stop` | `post_cascade_response` | none |

Output shape:

```json
{
  "_managed_by": "autonomous-common",
  "_managed_note": "...",
  "hooks": {
    "pre_run_command": [
      { "command": "bash $CLAUDE_PROJECT_DIR/hooks/block-push-to-main.sh", "timeout": 5 },
      ...
    ],
    "pre_write_code": [
      { "command": "bash $CLAUDE_PROJECT_DIR/hooks/check-test-plan.sh", "timeout": 5 }
    ],
    "post_cascade_response": [...]
  }
}
```

Note: Windsurf's hooks block has the same general shape as Claude's but **no `matcher` field on each entry, no nested `hooks` array** (it's flat). Each event maps directly to a list of `{command, timeout, ...}` blocks.

### Kimi CLI

Different format entirely — TOML, with `[[hooks]]` blocks:

```toml
# Auto-derived from claude-settings.template.json by install-kimi-hooks.sh.

[[hooks]]
event = "PreToolUse"
matcher = "RunShell"
command = "bash $CLAUDE_PROJECT_DIR/hooks/block-push-to-main.sh"
timeout = 5

[[hooks]]
event = "PreToolUse"
matcher = "RunShell"
command = "bash $CLAUDE_PROJECT_DIR/hooks/block-commit-outside-worktree.sh"
timeout = 5

# ... (one [[hooks]] block per command/matcher combination)
```

Kimi tool name mapping (per their docs):

| Claude matcher | Kimi matcher |
|---|---|
| `Bash` | `RunShell` |
| `Write` | `WriteFile` |
| `Edit` | `StrReplaceFile` |

Kimi events use Claude's PascalCase verbatim (`PreToolUse`, `PostToolUse`, `Stop`).

### Configuration scope

Both Windsurf and Kimi support project-level config — but **Kimi's docs only mention user-level `~/.kimi/config.toml`**. We'll write to user-level by default with an opt-in `--project` flag for an experimental project-level config.

## Architecture

Two new installers + one extension to `lib-installer-translate.sh`:

### `lib-installer-translate.sh` extension — `fold_matcher_into_event`

For Windsurf-style schemas where matcher info goes into the event name:

```bash
# fold_matcher_into_event <template-path>
#   Reads $AGENT_FOLD_MAP (Claude-event:Claude-matcher → agent-event)
#   Outputs JSON: {<agent-event>: [<flat hook-list>]}
```

Example map for Windsurf:
```
AGENT_FOLD_MAP="
  PreToolUse:Bash:pre_run_command
  PreToolUse:Write:pre_write_code
  PreToolUse:Edit:pre_write_code
  PostToolUse:Bash:post_run_command
  Stop::post_cascade_response
"
```

The function resolves each `(claude_event, claude_matcher)` pair into a Windsurf event name, dedups when multiple claude pairs map to the same Windsurf event (Edit + Write → pre_write_code), and outputs a flat-list-per-event JSON.

### Installer scripts

- `install-windsurf-hooks.sh`: writes `.windsurf/hooks.json` (hooks-only file). Uses the new `fold_matcher_into_event` helper.
- `install-kimi-hooks.sh`: writes `~/.kimi/config.toml` (or `.kimi/config.toml` with `--project`). TOML output requires escaping. Uses jq + a TOML serializer fallback (since jq doesn't speak TOML, we'll generate TOML manually with a small bash function — the format is simple enough).

## Why no shared TOML serializer lib

The Codex installer also touches TOML (PR-11b), but only to insert a single line into a `[features]` block — different problem. The Kimi case is "generate a sequence of `[[hooks]]` blocks from JSON". A real TOML serializer would be over-engineered; a small purpose-built bash function inline in `install-kimi-hooks.sh` is enough. We document the contract clearly so a future TOML-needing installer can extract a shared lib if it makes sense.

## Tests

Per existing pattern:

- `test-install-windsurf-hooks.sh` — file path, hooks-only shape, snake_case events, **no matcher field**, Edit+Write deduped to single `pre_write_code` event with merged hooks list, idempotency, `--no-git-hook` flag.
- `test-install-kimi-hooks.sh` — file path (default `~/.kimi/config.toml`, `--project` overrides to `.kimi/config.toml`), TOML shape (`[[hooks]]` blocks), event names preserved (`PreToolUse`), tool names translated (`Bash → RunShell`, `Write → WriteFile`, `Edit → StrReplaceFile`), idempotency.

## Documentation

- `docs/cross-agent-hooks.md` matrix: flip Windsurf and Kimi rows to ✅ shipped status.
- `skills/autonomous-common/SKILL.md` Setup table: add the 2 final installers; remove the "coming in PR-11c" stub.

## Out of scope

- Cross-agent installer test runner (call all 9 installers in CI). One follow-up PR if needed.
- Kimi's per-event capability matrix (some `[[hooks]]` events may not work cross-platform — operators verify).
- Windsurf's MCP/file/subagent hook events — we only care about pre_run_command / pre_write_code / post_cascade_response.
- Kimi's project-level config is documented as `--project` opt-in; user-level is the default per upstream docs.

## Files touched

New:
- `skills/autonomous-common/scripts/install-windsurf-hooks.sh`
- `skills/autonomous-common/scripts/install-kimi-hooks.sh`
- `tests/unit/test-install-windsurf-hooks.sh`
- `tests/unit/test-install-kimi-hooks.sh`
- `docs/designs/cross-agent-hooks-c.md` (this file)

Modified:
- `skills/autonomous-common/scripts/lib-installer-translate.sh` — new `fold_matcher_into_event` helper
- `docs/cross-agent-hooks.md` — matrix updated, Windsurf + Kimi marked shipped
- `skills/autonomous-common/SKILL.md` — Setup table extended

## Risk

Lower than PR-11b. Both installers are net-new (no existing code modified except the lib extension which adds a function, not changes one). Existing installers are byte-identical to their PR-11b shape. The 30 unit tests from PR-11a/b must continue to pass; new tests cover the 2 new installers.
