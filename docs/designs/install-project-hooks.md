# Design: `install-project-hooks.sh` — generic project-side bootstrap

Closes #153.

## Problem

Consumer projects bootstrap against this skill by symlinking the dispatcher
scripts into their own `scripts/` directory. The `SKILL.md` "legacy fallback"
documents a directory-level symlink:

```bash
ln -sf .claude/skills/autonomous-dispatcher/scripts scripts
```

…but a project's `scripts/` already contains project-local files
(`autonomous.conf`, deploy helpers, validators), so directory replacement
isn't viable. Consumers fall back to per-file symlinks, e.g.:

```bash
for f in lib-agent.sh lib-auth.sh lib-config.sh autonomous-{dev,review}.sh; do
  ln -s "$HOME/.claude/skills/autonomous-dispatcher/scripts/$f" "scripts/$f"
done
```

When upstream adds a new file (e.g. `lib-review-verdict.sh`), per-file lists
**don't auto-sync**. `autonomous-review.sh` `source`s the missing file from
the project-side `scripts/` (because `BASH_SOURCE[0]` resolves through the
project symlink, per `[INV-14]` in `autonomous-review.sh:18-20`) and dies on
line 27 before any review work runs. The dispatcher labels the issue
`reviewing`, the agent dies silently, and the issue stays stuck for hours
with no signal on the issue thread.

## Solution

Ship `install-project-hooks.sh` inside `autonomous-common` (already a hard
dependency of every consumer). The script is the canonical project-side
bootstrap. Consumers re-run it after every `npx skills update` and it
**re-syncs the symlinks** with whatever the upstream skill currently ships.

### What it does

1. **Symlink dispatcher scripts.** For each `*.sh` in
   `<skills-root>/autonomous-dispatcher/scripts/`, create a symlink
   `<project>/scripts/<name>` pointing at it.
   - **Skip** files that already exist as a real (non-symlink) file in the
     project's `scripts/` — these are project-local files
     (`autonomous.conf`, `deploy.sh`, …).
   - **Replace** existing symlinks (so re-running picks up moved upstream
     paths).
   - **Idempotent.** Re-running on an already-bootstrapped project is a
     no-op for unchanged files and a heal for changed/added/removed files.
2. **Symlink the hooks dir.** `<project>/hooks` →
   `<skills-root>/autonomous-common/hooks`. Existing real `hooks/`
   directory blocks this with a clear error (the operator needs to
   inspect; we won't silently shadow project-local hooks).
3. **Prune dangling symlinks.** Any `<project>/scripts/*.sh` that's a
   symlink into the dispatcher scripts dir but whose target no longer
   exists is removed. (Closes the "removed upstream" testing requirement.)
4. **Install the per-worktree git pre-push hook.** Reuse
   `lib-installer.sh::install_per_worktree_pre_push` (#65). Disable with
   `--no-git-hook`.

### What it does NOT do

- It does not write `.claude/settings.json` or any other IDE-specific
  config. That's the per-IDE `install-*-hooks.sh`'s job. Both can be run
  side-by-side; `install-claude-hooks.sh` already runs the git pre-push
  step too, so on Claude Code projects only one of the two needs the
  `--no-git-hook` flag.
- It does not symlink files from `autonomous-common/scripts/` itself.
  Those are agent-callable utilities (`mark-issue-checkbox.sh`, …) that
  consumers reach via `.agents/skills/autonomous-common/scripts/...`
  paths, not via project-side `scripts/` symlinks. Adding them here
  would conflict with the consumer's existing per-project pattern.

### Skills root resolution

The script needs to find the on-disk autonomous-dispatcher skill root.
Probe order (matches `lib-installer.sh::ensure_dispatcher_scripts_executable`):

1. `<project-root>/.agents/skills/autonomous-dispatcher/scripts`
2. `<project-root>/.claude/skills/autonomous-dispatcher/scripts`
3. `<project-root>/skills/autonomous-dispatcher/scripts`

If none found, abort with a clear error pointing to `npx skills add`.

### Where the script lives

`skills/autonomous-common/scripts/install-project-hooks.sh`. Materialized
into the consumer at `.agents/skills/autonomous-common/scripts/...` via
`npx skills add`.

### Bootstrap sequence (new docs, replaces "legacy fallback")

```bash
npx skills add zxkane/autonomous-dev-team -a claude-code -y
bash .agents/skills/autonomous-common/scripts/install-project-hooks.sh
bash .agents/skills/autonomous-common/scripts/install-claude-hooks.sh   # IDE-specific
```

## Out of scope

- Refactoring dispatcher scripts to live in their own subdirectory inside
  the project. Per-file symlinks under the existing `scripts/` is less
  disruptive.
- Folding the project-side bootstrap into every per-IDE installer.
  `install-project-hooks.sh` is IDE-agnostic and runs once per project,
  not once per IDE.

## INV references

- `[INV-14]` — `BASH_SOURCE[0]` is intentionally NOT `readlink -f`'d in
  `autonomous-review.sh:18-20`, so a project-side symlink resolves
  `SCRIPT_DIR` to `<project>/scripts/`. This makes `source
  "${SCRIPT_DIR}/<lib>.sh"` look up the lib in the project's `scripts/`,
  which is exactly why drift between per-file symlinks and upstream is
  fatal. The fix lives at the bootstrap layer (this script), not by
  changing INV-14.
