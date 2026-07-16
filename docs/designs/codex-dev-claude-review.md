# Design: Codex development with Claude review (#486)

## Goal

Make `AGENT_DEV_CMD=codex` with `AGENT_REVIEW_CMD=claude` a documented,
tested topology without changing the existing dispatcher adapters or review
aggregation. Codex lifecycle hooks are defense in depth; git hooks and the
deterministic wrapper gates remain authoritative.

## Scope

1. Render project-scoped Codex hooks from the canonical Claude template.
2. Use Codex's current `features.hooks` key and safely handle its deprecated
   `codex_hooks` alias.
3. Normalize edit-sensitive hook input across Claude `Write`/`Edit` and Codex
   `apply_patch`.
4. Document Codex-native simplification/review options and the ownership
   boundary between internal review subagents and the wrapper-assigned review
   session.
5. Pin the existing per-side CLI/launcher behavior for the mixed topology.

The Codex final-review adapter, `AGENT_REVIEW_AGENTS` aggregation, verdict
attribution, and wrapper merge actions are unchanged.

## Codex hook rendering

`.codex/hooks.json` remains a hooks-only file, but it is rendered specifically
for Codex instead of copying Claude commands verbatim:

- Every command resolves the current worktree with
  `$(git rev-parse --show-toplevel)` and does not require
  `$CLAUDE_PROJECT_DIR`.
- Claude's separate `Write` and `Edit` matcher groups are deduplicated into one
  `^apply_patch$` matcher group. Codex documents `Write` and `Edit` as aliases
  for `apply_patch`, but a direct matcher avoids running the same handler
  twice.
- Shared installer deduplication preserves the canonical hook command order
  while removing duplicate commands that converge on one matcher or event.
- Other event groups, timeouts, and commands stay aligned with the canonical
  template.

Shared workflow state is resolved from the hook process's current Git worktree,
not `$CLAUDE_PROJECT_DIR`. Claude Code keeps that variable fixed to the project
where the session started even after work moves into a linked worktree, while
manual state-manager commands do not necessarily receive it. Resolving both
paths from `git rev-parse --show-toplevel` prevents mark/check state from
splitting across the main checkout and linked worktree.

Project hooks execute only after the project layer and the current hook hash
are trusted. Interactive operators review them with `/hooks`. Unattended runs
may use `--dangerously-bypass-hook-trust` only when the hook source is vetted
outside Codex.

## Feature-key migration

The installer uses Python 3.11's standard-library `tomllib` to parse the
complete document before staging either destination. `hooks` and
`codex_hooks`, when present under `features`, must be booleans.

No-op configurations such as a quoted canonical `"hooks" = true` or dotted
`features.hooks = true` are accepted without textual rewriting. Any operation
that must insert, rename, or remove a key is intentionally limited to one
ordinary `[features]` table with bare keys, no multiline strings, and no
quoted representation of the features table itself. Unrelated quoted tables
are preserved. Other valid but noncanonical mutable forms are refused with an
operator-facing diagnostic instead of risking comment or string corruption.
After every textual rewrite, the parsed staging file must contain canonical
`hooks = true` and no legacy alias; a complex form such as a multiline nested
array therefore fails safely instead of reporting a migration that did not
occur.

| Existing `[features]` state | Result |
|---|---|
| Neither key | Add `hooks = true` |
| `hooks = true` only | No-op |
| `hooks = false` only | Refuse; preserve explicit disable |
| `codex_hooks = true` only | Rename to `hooks = true` |
| `codex_hooks = false` only | Refuse; preserve explicit disable |
| Both `true` | Keep canonical `hooks`; remove deprecated alias |
| Both `false` | Refuse; preserve explicit disable |
| Values differ | Refuse as a conflict; preserve file byte-for-byte |
| Canonical true in a quoted/dotted form | Accept without rewriting |
| Legacy/missing key in a noncanonical mutable form | Refuse; preserve file |
| Duplicate key/table or `[[features]]` | Refuse during semantic parsing |

Unrelated TOML sections, comments, quoted keys, and multiline strings are
retained. Both generated files are rendered before installation. Existing
changed destinations receive timestamped backups and retain their original
file modes; fresh files are private even under a permissive umask.
Same-directory atomic replacements use unpredictable `mktemp` paths, and a
replacement failure or handled termination between replacements rolls both
files back. Hook definitions are installed before the feature config enables
them, so an uncatchable process death cannot newly enable stale hooks.
Exact-target no-clobber links are used for install, capture, and rollback, so a
concurrently created directory cannot become an implicit move target. Capture
postconditions use inode plus content/mode snapshots to reconcile an operation
that completed before its helper returned a failure. The transaction enters
the physical `.codex` directory and uses relative target names, then verifies
that the project path still names the same directory before replacement and
commit. A concurrent parent rename/symlink swap therefore cannot redirect
writes outside the repository. Directory and symbolic-link destinations,
including a symlinked `.codex` parent, are refused; a newly created `.codex`
directory is private regardless of the caller's umask. Rollback content is
itself staged and atomically placed, rollback ignores repeated termination
signals, and pending files are removed on handled termination. Original
content, inode ownership, and mode snapshots are revalidated immediately
before each replacement so an operator edit made during rendering is not
silently overwritten.

## Hook input normalization

`hooks/lib.sh` exposes:

```bash
parse_edit_file_operations "$hook_json"
parse_edit_file_paths "$hook_json"
```

The primary API emits `operation<TAB>path` records in source order with
duplicates removed:

- Claude/Cursor `Write`: `add`; Claude/Cursor `Edit`: `edit`
- Existing installer translations remain supported. Kiro
  `fs_write`/`write`/`fsWrite` uses `tool_input.path` plus `command`: `create`
  maps to `add`, while
  `str_replace`/`insert`/`append` map to `edit`. Gemini
  `write_file`/`replace` and Kimi `WriteFile`/`StrReplaceFile` use
  `tool_input.file_path`; Windsurf `pre_write_code` uses
  `tool_info.file_path`.
- Codex `apply_patch`: every path in `tool_input.command` headers
  `*** Add File:`, `*** Update File:`, `*** Delete File:`, and `*** Move to:`,
  mapped to `add`, `edit`, `delete`, and `move`

`parse_edit_file_paths` remains a compatibility projection that drops the
operation column. Dispatch happens on `tool_name` first, so a non-edit tool
cannot become an edit merely by carrying `file_path`, and an `apply_patch`
payload always parses its complete command even if another field is present.
The parser requires matching `*** Begin Patch` / `*** End Patch` boundaries
and structural header lines. Recognized edit tools with malformed/missing
data return non-zero, as do missing/non-string tool discriminators. The
test-plan hook reports that parser failure but exits successfully because its
TDD policy is advisory; payload-shape drift must not block every edit while an
actual missing test plan only produces a reminder. Unknown tools with a valid
nonempty string name remain a no-op.

Claude-style clients provide `tool_name` and `tool_input`; Windsurf's native
payload uses `agent_action_name` and `tool_info`. Required path/command fields
must be nonempty JSON strings, so malformed scalar/object values cannot be
stringified into a policy bypass.

`check-test-plan.sh` evaluates every `add` operation. A non-implementation
first file can no longer hide a later new implementation file in the same
Codex patch, while updates, deletes, and pure moves cannot produce a false
"new implementation file" reminder.

## Agent roles

- The Codex development session may use native subagents for an independent
  simplification pass and dev-side review. Codex's dedicated
  `codex review --uncommitted` / `--base` workflow is also valid.
- Claude plugins/subagents remain valid equivalents.
- Internal Codex or Claude subagents are advisory and return evidence to their
  parent session.
- Within each wrapper-assigned verdict session, only the parent process runs
  the Findings -> Decision Gate and invokes `post-verdict.sh`; its internal
  subagents never do.
- `AGENT_REVIEW_AGENTS` means independent wrapper-managed verdict agents;
  `REVIEW_BOTS` means external GitHub reviewers. Neither includes internal
  subagents.

## Verification

- Installer matrix and Codex-specific rendering tests.
- Shared parser tests for Claude and Codex payloads.
- A captured Codex 0.144.3 `PreToolUse` payload proving that `apply_patch`
  supplies the bare patch body in `tool_input.command`.
- Behavioral execution of the generated Codex command from a nested
  directory with `$CLAUDE_PROJECT_DIR` unset.
- Linked-worktree state tests in both directions, including a Claude hook that
  carries the main checkout in `$CLAUDE_PROJECT_DIR`.
- Static guidance tests for Codex dev review and Claude main-session verdict
  ownership.
- Existing per-side CLI and launcher suites, followed by the full unit suite.
