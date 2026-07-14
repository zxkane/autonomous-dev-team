# Cross-Platform Notes — autonomous-dev

This skill is portable across coding agents that follow the skills.sh model. The workflow logic in `SKILL.md` uses generic language that maps to each platform's tooling.

## Hooks support

| IDE/CLI | Hooks support | Setup |
|---------|--------------|-------|
| Claude Code | Full | `hooks/README.md` (in `autonomous-common`) |
| Codex CLI | Full | Run `install-codex-hooks.sh`; review project hooks with `/hooks` |
| Kiro CLI | Full | `hooks/README.md` (in `autonomous-common`) |
| Cursor | None | Follow workflow steps manually |
| Windsurf | None | Follow workflow steps manually |
| Gemini CLI | None | Follow workflow steps manually |

If your IDE supports hooks, install them from `autonomous-common/hooks/` for hard enforcement of the MANDATORY steps. Without hooks, the discipline is the same — you just have to remember to run each step yourself.

## Tool name mapping

The SKILL.md uses generic verbs. Map them to your IDE's tools:

| SKILL.md says | Claude Code | Codex CLI | Cursor | Gemini CLI |
|---|---|---|---|---|
| "Execute in your terminal" | Bash tool | shell tool | terminal | shell |
| "Read the file" | Read tool | shell/read tool | file viewer / open | `cat` |
| "Create or edit the file" | Write / Edit tool | `apply_patch` | editor | manual edit |
| "Use a subagent" | Task / Agent tool | Native subagent | (no equivalent — do it inline) | (no equivalent) |
| "Load the skill" | Skill tool | read the referenced SKILL.md | read the referenced SKILL.md | read the referenced SKILL.md |

When the SKILL.md says "use a subagent" and your IDE doesn't have one, follow the listed steps manually instead.
