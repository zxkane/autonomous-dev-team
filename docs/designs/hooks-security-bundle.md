# Hooks security bundle: trunk-protection defense in depth

PR-5 of the pipeline-docs plan. Closes 3 hook issues that together gate trunk-pushes. The three layers are designed to be independent — any one of them failing should not let an unwanted commit through to the trunk.

## Issues addressed

| # | Title | Affected file(s) |
|---|---|---|
| #64 | `block-push-to-main.sh` regex false-pos / false-neg | existing `skills/autonomous-common/hooks/block-push-to-main.sh` |
| #65 | Worktree creation should install repo-local git pre-push backstop | new `skills/autonomous-common/hooks/install-git-pre-push.sh` |
| #68 | SKILL.md frontmatter hooks are skill-scoped, not project-scoped | new `skills/autonomous-common/scripts/install-claude-hooks.sh` + docs |

## The 3 layers

```
                   git push
                      ↓
┌─────────────────────────────────────────────────────────┐
│ Layer 1: Claude Code PreToolUse hook                    │
│   block-push-to-main.sh                                 │
│   Fires on Bash tool calls inside a Claude session.     │
│   Project-scoped (.claude/settings.json) — NOT skill-   │
│   scoped (#68). Fixed regex (#64).                      │
└─────────────────────────────────────────────────────────┘
                      ↓ (passes through, or hook missing)
┌─────────────────────────────────────────────────────────┐
│ Layer 2: git-side pre-push hook (per-worktree)          │
│   .git/hooks/pre-push (installed by install-git-pre-    │
│   push.sh after every `git worktree add`)               │
│   Fires for ANY git push, including outside Claude.     │
│   Reads stdin, refuses lines with refs/heads/<trunk>.   │
│   Override: --no-verify (documented).                   │
└─────────────────────────────────────────────────────────┘
                      ↓ (passes through, or hook missing)
┌─────────────────────────────────────────────────────────┐
│ Layer 3: server-side branch protection (GitHub)         │
│   Free-tier private repos can't enforce this — Layer 2  │
│   is the only consistent backstop in that environment.  │
└─────────────────────────────────────────────────────────┘
```

**Key insight from #68**: the SKILL.md frontmatter hooks are bound to the skill activation context. As soon as the agent does any free-form bash work outside `/autonomous-dev`, the frontmatter hooks don't fire. They are *not* automatically promoted to project-scoped `.claude/settings.json` entries.

This repo already has a hand-maintained project-scoped `.claude/settings.json` that mirrors the SKILL.md frontmatter. **Downstream consumers don't get that for free.** PR-5 ships the installer that produces it.

## Refactor first

Per project direction. Before applying the 3 fixes, extract the shared parsing into a small helper:

### New `skills/autonomous-common/hooks/lib-push.sh`

Two pure functions used by both Layer 1 (Claude hook) and Layer 2 (git pre-push hook):

- `parse_push_target_refspec(command)` — given a `git push ...` command line, echoes the **destination** ref-name(s) the push would write to. Handles:
  - bare `git push` → `<current_branch>` (matrix push or default upstream)
  - `git push origin feat/foo` → `feat/foo`
  - `git push origin HEAD:refs/heads/main` → `refs/heads/main`
  - `git push origin :main` (delete) → `:main` (caller decides)
  - `git push --all` / `--mirror` → special markers
- `is_trunk_ref(ref, trunk_name)` — given a ref-name, returns 0 if it refers to the trunk branch. Handles:
  - bare `main` / `master` / configured trunk
  - `refs/heads/main` (fully-qualified — #64 false-negative)
  - `refs/heads/main^` etc. (rare, but should still match)

Both #64 (Layer 1 fix) and #65 (Layer 2 new hook) use these primitives. This consolidation removes the duplication risk that caused #64 in the first place — without a shared parser, Layer 2 would just reinvent Layer 1's broken regex.

## Per-issue fixes

### #64: rewrite `block-push-to-main.sh` using `lib-push.sh`

Both bug cases collapse to "use the parser, not ad-hoc regexes":

- **Case A (false positive — bare push from trunk-checked-out worktree pushes a feature branch and gets blocked)**: the parser identifies the actual destination as `feat/foo` (from the explicit refspec `feat/foo`), so `is_trunk_ref` returns 1. Block doesn't fire.
- **Case B (false negative — `HEAD:refs/heads/main` slips through)**: the parser identifies destination as `refs/heads/main`, `is_trunk_ref` returns 0. Block fires.

The 5-condition regex chain in current `block-push-to-main.sh:25-29` becomes one call: `is_trunk_ref "$(parse_push_target_refspec "$command")"`.

### #65: new `install-git-pre-push.sh`

- Idempotent installer; resolves per-worktree hooks dir via `git rev-parse --git-path hooks`.
- Writes a self-contained `.git/hooks/pre-push` that reads stdin lines `<local-ref> <local-sha> <remote-ref> <remote-sha>` and refuses any with `remote-ref == refs/heads/<trunk>`.
- The trunk name is parameterized — the installer reads `git symbolic-ref refs/remotes/origin/HEAD` (or falls back to `main`) at install time and bakes it in.
- The pre-push hook itself is plain bash with no dependencies (no `lib-push.sh` source), because git hooks run from outside any project context. The 4-line refspec parse inside the hook is intentionally simple and self-contained.
- Worktree-bootstrap callsites: this PR doesn't change those (they're in agent prompts / the autonomous-dev SKILL.md skill). Documentation update only — the autonomous-dev skill should call the installer right after `git worktree add`.

### #68: new `install-claude-hooks.sh` bootstrap

A one-shot installer for downstream consumers that materializes a project-scoped `.claude/settings.json` mirroring the autonomous-dev SKILL.md frontmatter. Idempotent — re-running merges (doesn't clobber) hand-edits.

- Reads the canonical hook list from a curated source-of-truth (the autonomous-common skill itself, not the autonomous-dev SKILL.md frontmatter — we don't want the consumer's settings drift to be tied to whether they parse YAML).
- Writes / merges into `.claude/settings.json` with a `"managed_by": "autonomous-common"` annotation so future `skills update` runs can re-merge cleanly.
- Calls `install-git-pre-push.sh` at the end (one-stop install).
- Documented in `autonomous-common/SKILL.md`: "after `npx skills add`, run `bash .claude/skills/autonomous-common/scripts/install-claude-hooks.sh`".

This is intentionally NOT auto-run on `npx skills add`. Mutating the consumer's `.claude/settings.json` without explicit consent would be surprising. The CONTRIBUTING.md / SKILL.md install steps direct consumers to run it.

## Behavior preservation

Strict: every diff line not directly tied to one of the 3 issues is a refactor that preserves byte-equivalent behavior. Specifically:
- The list of hooks in `.claude/settings.json` for THIS repo is unchanged.
- The wording of the BLOCKED message in `block-push-to-main.sh` is preserved verbatim.
- `is_git_command()` semantics in `lib.sh` unchanged.

## Test plan

New tests:

- `tests/unit/test-block-push-regex.sh` — covers all 8 cases from #64's table:
  | Case | Command | Branch | Expect |
  |---|---|---|---|
  | TC-BP-01 Bare push from trunk | `git push` | trunk | block |
  | TC-BP-02 Bare push from feat | `git push` | feat/x | allow |
  | TC-BP-03 Feature push from trunk worktree (#64 case A) | `git push -u origin feat/foo` | trunk | allow |
  | TC-BP-04 Feature push from feat worktree | `git push -u origin feat/foo` | feat/x | allow |
  | TC-BP-05 Explicit `:trunk` short refspec | `git push origin feat:main` | feat/x | block |
  | TC-BP-06 Explicit FQ refspec (#64 case B) | `git push origin HEAD:refs/heads/main` | feat/x | block |
  | TC-BP-07 `--all` flag | `git push --all` | feat/x | block |
  | TC-BP-08 `--mirror` flag | `git push --mirror` | feat/x | block |

- `tests/unit/test-install-git-pre-push.sh` — covers:
  - Idempotency: 2x install → no diff in `.git/hooks/pre-push`
  - Worktree path resolution: install from a `git worktree add`-created subdir → hook lands in the right place (`git rev-parse --git-path hooks`)
  - The hook itself: feed stdin lines, assert exit codes (block trunk, allow feature)

- `tests/unit/test-install-claude-hooks.sh` — covers:
  - First-time install: creates `.claude/settings.json` with the canonical hook list
  - Re-install on existing settings.json: merges, preserves hand-edits
  - Annotation present: `"managed_by": "autonomous-common"` field is written

- `tests/unit/test-lib-push.sh` — covers `parse_push_target_refspec` and `is_trunk_ref` against the same matrix.

## Per CONTRIBUTING.md Rule 1

Touches `skills/autonomous-common/hooks/*.sh` (watched). Also touches `docs/pipeline/invariants.md` (new INV-17). Gate passes via docs-touched.

## Risk

Medium-high. Trunk protection is load-bearing. Mitigations:

- **Behavior preservation**: the BLOCKED message wording and exit code (2) stay identical so existing CI that greps for blocked-by-hook output keeps working.
- **Test coverage**: the 8-case table for #64 is comprehensive.
- **Manual smoke test**: against a throwaway repo with `git worktree add` + `git push`, verify all 3 layers fire correctly.
- **Rollback**: each fix is independently revertable. Layer 1 (#64) is a single-file edit. Layer 2 (#65) is a new script — revert by deleting it. Layer 3 (#68) ships a new install script that's opt-in for consumers.

## Out of scope

- The autonomous-dev workflow integration (calling `install-git-pre-push.sh` after `git worktree add`) is a SKILL.md prompt update, not a hook code change. PR-5 documents the call site but doesn't change the prompt body — that's a follow-up.
- Wrapper-side fixes (#59, #60, #67) — PR-6.
- Multi-repo dispatch (#62) — PR-7.
- PID files CWE-377 (#72) — small follow-up.
