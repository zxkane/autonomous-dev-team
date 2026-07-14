# Test Cases: Codex development with Claude review (#486)

## Installer and feature migration

| ID | Scenario | Expected |
|---|---|---|
| TC-CDCR-001 | Fresh Codex install | `.codex/hooks.json` and `.codex/config.toml` exist; config contains `[features] hooks = true` only |
| TC-CDCR-002 | Generated Codex hooks | Commands resolve through `git rev-parse --show-toplevel`, contain no `$CLAUDE_PROJECT_DIR`, and use one `^apply_patch$` group |
| TC-CDCR-003 | Re-run installer | One canonical key and one apply-patch group remain |
| TC-CDCR-004 | Existing config without `[features]` | Unrelated TOML is preserved and a single table is appended |
| TC-CDCR-005 | Existing `[features]` without hook keys | `hooks = true` is inserted without duplicating the table |
| TC-CDCR-006 | Existing canonical `hooks = true` | Installer is an idempotent no-op for the key |
| TC-CDCR-007 | Existing canonical `hooks = false` | Installer fails and preserves the explicit disable without writing hooks |
| TC-CDCR-008 | Legacy-only `codex_hooks = true` | Key migrates to canonical `hooks = true` |
| TC-CDCR-008A | Unrelated `[[array-table]]` also contains `codex_hooks` data | Migration changes only `[features]` and preserves unrelated keys |
| TC-CDCR-008B | Unrelated quoted table header contains `#` | Mutable migration refuses and preserves both destinations |
| TC-CDCR-009 | Legacy-only `codex_hooks = false` | Installer fails and preserves the explicit disable |
| TC-CDCR-010 | Both keys are `true` | Deprecated alias is removed; canonical key remains |
| TC-CDCR-011 | Keys disagree | Installer fails loudly and preserves config byte-for-byte |
| TC-CDCR-012 | A mutable inline `features` table has no hook key | Installer refuses instead of textually rewriting a noncanonical shape |
| TC-CDCR-013 | Existing TOML has multiline strings and quoted keys | Appended canonical feature configuration preserves their semantic values |
| TC-CDCR-014 | Canonical true uses a quoted or dotted key | Installer accepts it as a no-op without rewriting |
| TC-CDCR-015 | Legacy true uses a quoted or dotted key | Installer refuses the unsafe migration and preserves the file |
| TC-CDCR-016 | `[[features]]`, duplicate key, or duplicate table | Complete TOML parsing refuses before either destination changes |
| TC-CDCR-017 | Hooks replacement fails after config replacement | Existing config and hooks are restored |
| TC-CDCR-017A | Operator edits installed config before hooks failure is handled | Rollback refuses to overwrite the concurrent edit |
| TC-CDCR-018 | Existing files have restrictive modes; fresh install runs under permissive umask | Replacements preserve existing modes and fresh files remain private |
| TC-CDCR-019 | Destination or `.codex` parent is a directory/symbolic-link mismatch | Installer refuses before replacing either destination or writing through the link |
| TC-CDCR-019A | Process receives SIGTERM after config replacement | Signal handler atomically restores both original destinations and removes pending files |
| TC-CDCR-019D | Process receives SIGTERM while a pending file is staged | Signal handler leaves original destinations intact and removes pending files |
| TC-CDCR-019B | Config changes while hooks are rendered | Installer refuses the stale snapshot and preserves the concurrent edit |
| TC-CDCR-019C | Config mode changes while hooks are rendered | Installer refuses and preserves the restrictive mode |

## Hook payload normalization and behavior

| ID | Scenario | Expected |
|---|---|---|
| TC-CDCR-020 | Claude `Write` payload | Emits `add<TAB>path`; compatibility API emits the path |
| TC-CDCR-021 | Claude `Edit` path contains spaces | Emits `edit<TAB>path` without word splitting and does not trigger file-creation policy |
| TC-CDCR-021A | Kiro `fs_write` uses `path` + `command`; Gemini/Kimi use `file_path`; Windsurf uses `tool_info.file_path` | Provider-native payloads retain add/edit semantics; Kiro `create` and Windsurf writes trigger policy |
| TC-CDCR-022 | Codex patch adds, updates, moves, and deletes files | Emits all `add`/`edit`/`move`/`delete` records and compatibility paths in patch order |
| TC-CDCR-023 | Codex multi-file patch has docs first and new `src/` file second | `check-test-plan.sh` emits the reminder; pure move does not |
| TC-CDCR-024 | Missing boundaries, missing/non-string discriminator/path, or empty recognized edit payload | Parser fails and the direct/generated hook exits exactly `2` |
| TC-CDCR-025 | `Read` carries a nonempty `file_path`; `apply_patch` carries a misleading one | `Read` is a no-op and `apply_patch` still parses every command header |
| TC-CDCR-026 | Generated Codex hook command runs from a nested directory with `$CLAUDE_PROJECT_DIR` unset | Command finds the worktree hook and applies TC-CDCR-023/024 behavior |

## Skills, roles, and topology

| ID | Scenario | Expected |
|---|---|---|
| TC-CDCR-030 | `autonomous-dev` guidance and hook feedback | Names Codex native subagents and `codex review`, with Claude/manual equivalents |
| TC-CDCR-031 | `autonomous-review` internal subagent guidance | Internal subagents are advisory; assigned main session alone runs the decision gate and calls `post-verdict.sh` |
| TC-CDCR-032 | Operator docs compare review mechanisms | `REVIEW_BOTS`, `AGENT_REVIEW_AGENTS`, and internal subagents are distinct |
| TC-CDCR-033 | Canonical mixed config | `AGENT_DEV_CMD=codex`, `AGENT_REVIEW_CMD=claude`, default single verdict agent, no dev launcher leakage |
| TC-CDCR-034 | Claude-only review launcher in canonical mixed config | Review launcher is accepted while Codex dev remains unwrapped |

## Regression gates

- `bash tests/unit/test-install-codex-hooks.sh`
- `bash tests/unit/test-hook-edit-paths.sh`
- `bash tests/unit/test-codex-dev-claude-review-docs.sh`
- `bash tests/unit/test-lib-agent-per-side-cmd.sh`
- `bash tests/unit/test-lib-agent-per-side-launcher.sh`
- `bash tests/run-unit-tests.sh`
