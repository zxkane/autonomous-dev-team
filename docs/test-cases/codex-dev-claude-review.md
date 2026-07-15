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
| TC-CDCR-008B | Unrelated quoted table header contains `#` | Canonical migration succeeds and preserves the unrelated table data |
| TC-CDCR-008C | A multiline nested array precedes legacy `codex_hooks` | Semantic postcondition detects the missed rewrite and refuses before either destination changes |
| TC-CDCR-009 | Legacy-only `codex_hooks = false` | Installer fails and preserves the explicit disable |
| TC-CDCR-010 | Both keys are `true` | Deprecated alias is removed; canonical key remains |
| TC-CDCR-011 | Keys disagree | Installer fails loudly and preserves config byte-for-byte |
| TC-CDCR-012 | A mutable inline `features` table has no hook key | Installer refuses instead of textually rewriting a noncanonical shape |
| TC-CDCR-013 | Existing TOML has multiline strings and quoted keys | Appended canonical feature configuration preserves their semantic values |
| TC-CDCR-014 | Canonical true uses a quoted or dotted key | Installer accepts it as a no-op without rewriting |
| TC-CDCR-015 | Legacy true uses a quoted or dotted key | Installer refuses the unsafe migration and preserves the file |
| TC-CDCR-016 | `[[features]]`, duplicate key, or duplicate table | Complete TOML parsing refuses before either destination changes |
| TC-CDCR-017 | A destination replacement fails | Existing config and hooks are restored |
| TC-CDCR-017A | Config placement fails; hooks change during rollback capture and TERM arrives | Rollback preserves the concurrent edit and cannot be re-entered by the signal |
| TC-CDCR-017B | Both Codex files change | `hooks.json` is replaced before `config.toml` enables the canonical feature |
| TC-CDCR-018 | Existing files have restrictive modes; fresh install runs under permissive umask | Replacements preserve existing modes and fresh files/directories remain private |
| TC-CDCR-019 | Destination or `.codex` parent is a directory/symbolic-link mismatch | Installer refuses before replacing either destination or writing through the link |
| TC-CDCR-019A | Process receives SIGTERM after replacement and again during rollback | Signal handler restores config before hooks, ignores the repeated signal, and removes pending files |
| TC-CDCR-019D | Process receives SIGTERM while a pending file is staged | Signal handler leaves original destinations intact and removes pending files |
| TC-CDCR-019B | Config changes while hooks are rendered | Installer refuses the stale snapshot and preserves the concurrent edit |
| TC-CDCR-019C | Config mode changes while hooks are rendered | Installer refuses and preserves the restrictive mode |
| TC-CDCR-019E | Operator creates/edits a destination in the final placement window | No-clobber installation aborts, preserves the concurrent content, and rolls back the other destination |
| TC-CDCR-019F | Another installer wins the atomic capture race | The losing installer leaves ownership with the winner and does not synthesize an empty destination |
| TC-CDCR-019H | Capture completes but its helper returns nonzero | Inode/content postconditions recognize the captured original and installation remains consistent |
| TC-CDCR-019I | Operator creates a directory at the randomized backup path | Exact-target capture aborts while preserving the canonical file and directory |
| TC-CDCR-019J | Operator creates a directory at rollback's randomized capture path | Rollback does not move the canonical file inside that directory |
| TC-CDCR-019K | TERM arrives after capture placement but before shell bookkeeping | The signal is handled with exit 143 and both destinations are restored |
| TC-CDCR-019L | Operator creates a directory in the final placement window | Exact-target placement aborts without moving generated content inside the directory |
| TC-CDCR-019M | Project `.codex` is replaced by an external symlink after final placement | Anchored rollback restores the original physical directory and writes nothing externally |
| TC-CDCR-019N | Canonical rollback source disappears while an unrelated scratch object appears | Inode ownership check leaves both unowned objects untouched |
| TC-CDCR-019O | Kiro/Windsurf translation deduplicates hooks that converge on one matcher/event | Duplicate commands are removed without changing canonical command order |

## Hook payload normalization and behavior

| ID | Scenario | Expected |
|---|---|---|
| TC-CDCR-020 | Claude `Write` payload | Emits `add<TAB>path`; compatibility API emits the path |
| TC-CDCR-021 | Claude `Edit` path contains spaces | Emits `edit<TAB>path` without word splitting and does not trigger file-creation policy |
| TC-CDCR-021A | Kiro `fs_write`/`write`/`fsWrite` uses `path` + `command`; Gemini/Kimi use `file_path`; Windsurf uses `tool_info.file_path` | Provider-native payloads retain add/edit semantics; Kiro `create` and Windsurf writes trigger policy |
| TC-CDCR-022 | Codex patch adds, updates, moves, and deletes files | Emits all `add`/`edit`/`move`/`delete` records and compatibility paths in patch order |
| TC-CDCR-022A | Real Codex 0.144.3 `PreToolUse` payload captured from an `apply_patch` invocation | Full runtime payload parses the bare patch body from `tool_input.command` |
| TC-CDCR-023 | Codex multi-file patch has docs first and new `src/` file second | `check-test-plan.sh` emits the reminder; pure move does not |
| TC-CDCR-024 | Missing boundaries, missing/non-string discriminator/path, or empty recognized edit payload | Strict parser fails; advisory direct/generated hook warns and exits `0` without blocking the edit |
| TC-CDCR-025 | `Read` carries a nonempty `file_path`; `apply_patch` carries a misleading one | `Read` is a no-op and `apply_patch` still parses every command header |
| TC-CDCR-026 | Generated Codex hook command runs from a nested directory with `$CLAUDE_PROJECT_DIR` unset | Command finds the worktree hook and applies TC-CDCR-023/024 behavior |
| TC-CDCR-027 | Main checkout has a fresh test-plan mark while Codex edits a linked worktree | Linked-worktree state stays isolated and the worktree edit still emits the reminder |
| TC-CDCR-027A | Worktree has a fresh test-plan mark while a Claude hook carries the main checkout in `$CLAUDE_PROJECT_DIR` | Hook resolves state from its worktree `cwd`, sees the mark, and emits no reminder |

## Skills, roles, and topology

| ID | Scenario | Expected |
|---|---|---|
| TC-CDCR-030 | `autonomous-dev` guidance and hook feedback | Names Codex native subagents and `codex review`, with Claude/manual equivalents |
| TC-CDCR-031 | `autonomous-review` and authoritative pipeline guidance | Within each wrapper-assigned verdict session, internal subagents are advisory and only the parent runs the decision gate and calls `post-verdict.sh` |
| TC-CDCR-032 | Operator and pipeline docs compare review mechanisms | `REVIEW_BOTS`, `AGENT_REVIEW_AGENTS`, and internal subagents are distinct |
| TC-CDCR-033 | Canonical mixed config in operator and pipeline docs | `AGENT_DEV_CMD=codex`, `AGENT_REVIEW_CMD=claude`, default single verdict agent, no dev launcher leakage |
| TC-CDCR-034 | Claude-only review launcher in canonical mixed config | Review launcher is accepted while Codex dev remains unwrapped |

## Regression gates

- `bash tests/unit/test-install-codex-hooks.sh`
- `bash tests/unit/test-hook-edit-paths.sh`
- `bash tests/unit/test-codex-dev-claude-review-docs.sh`
- `bash tests/unit/test-lib-agent-per-side-cmd.sh`
- `bash tests/unit/test-lib-agent-per-side-launcher.sh`
- `bash tests/run-unit-tests.sh`
