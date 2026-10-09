# Autonomous Dev Team

## Install Skills

Install all skills into any of 40+ supported coding agents:

```bash
npx skills add zxkane/autonomous-dev-team
```

Supports Claude Code, Cursor, Windsurf, Antigravity, Kiro CLI, and [more](https://skills.sh).

## Available Skills

### autonomous-dev
TDD development workflow with git worktree isolation, design canvas,
test-first development, code review, and CI verification. Supports
interactive and autonomous modes.

### autonomous-review
PR code review with checklist verification, merge conflict resolution,
E2E testing via browser automation, and auto-merge.

### autonomous-dispatcher
GitHub issue scanner that dispatches dev and review agents on a cron
schedule. Manages the autonomous pipeline lifecycle via labels.

### autonomous-common
Shared infrastructure: workflow enforcement hooks, optional session knowledge,
and agent-callable utility scripts (mark-issue-checkbox, reply-to-comments,
resolve-threads, gh-as-user).
Required by autonomous-dev and autonomous-review. Not directly invocable.

### create-issue
Interactive GitHub issue creation with structured templates, autonomous
label guidance, and workspace change attachment. Supports feature
requests and bug reports.

## Workflow Summary

1. Design -> 2. Worktree -> 3. Tests -> 4. Implement -> 5. Verify ->
6. Review -> 7. PR -> 8. CI -> 9. E2E -> 10. Merge

## Hooks

Workflow enforcement hooks are bundled in `skills/autonomous-common/hooks/`.
Claude frontmatter commands reference `$CLAUDE_PROJECT_DIR/hooks/`; the Codex
installer renders equivalent git-worktree-root commands. Both require the
project-root `hooks` symlink.

**Template users** already have `hooks -> skills/autonomous-common/hooks`.

**`npx skills add` users** bootstrap the project links after install:

```bash
bash .agents/skills/autonomous-common/scripts/install-project-hooks.sh
```

The installer preserves project-local scripts and links dispatcher entry points
individually. Re-run it after upgrading skills to pick up new entries.

Hooks are supported by Claude Code, Codex CLI, and Kiro CLI. Other IDEs follow
the workflow steps manually. See `hooks/README.md` for the full reference.

## Scripts

Pipeline and utility scripts are bundled inside skill directories:
- Shared scripts: `skills/autonomous-common/scripts/`
- Pipeline scripts: `skills/autonomous-dispatcher/scripts/`
- Review scripts: `skills/autonomous-review/scripts/`

Dispatcher entries are accessible through `scripts/`; common utilities remain
in the installed common skill directory.

## Session Knowledge

Before dev handoff or a review verdict, assess verified durable facts or record
why no update is needed. Read the common
[`session knowledge reference`](skills/autonomous-common/references/session-knowledge.md).
After confirmed merge, useful updates become an isolated documentation commit
and separate PR. Keep current instructions in the nearest `AGENTS.md`, diagnoses
in `docs/troubleshooting/`, and reusable lessons in `docs/lessons-learned/`.
Correct stale facts instead of adding contradictions. No useful diff means no
commit. Machine details and credential references belong in ignored, mode-600
`AGENTS.local.md` in the primary checkout; consult it when local context is needed.
Never record credential values in an assessment or tracked documentation.
