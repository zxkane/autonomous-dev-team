# Autonomous Dev Team

## Install Skills

Install all skills into any of 40+ supported coding agents:

```bash
npx skills add zxkane/autonomous-dev-team
```

Supports Claude Code, Cursor, Windsurf, Gemini CLI, Kiro CLI, and [more](https://skills.sh).

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
Shared infrastructure: workflow enforcement hooks and agent-callable utility
scripts (mark-issue-checkbox, reply-to-comments, resolve-threads, gh-as-user).
Required by autonomous-dev and autonomous-review. Not directly invocable.

### create-issue
Interactive GitHub issue creation with structured templates, autonomous
label guidance, and workspace change attachment. Supports feature
requests and bug reports.

## Workflow Summary

1. Design -> 2. Worktree -> 3. Tests -> 4. Implement -> 5. Verify ->
6. Review -> 7. PR -> 8. CI -> 9. E2E -> 10. Merge

## Hooks

Workflow enforcement hooks are bundled in `skills/autonomous-common/hooks/`
and accessible via the `hooks/` symlink at the project root. Supported by
Claude Code and Kiro CLI. See `hooks/README.md` for per-agent setup.

For `npx skills add` users, hooks are also available via skill frontmatter
in autonomous-dev and autonomous-review SKILL.md files.

## Scripts

Pipeline and utility scripts are bundled inside skill directories:
- Shared scripts: `skills/autonomous-common/scripts/`
- Pipeline scripts: `skills/autonomous-dispatcher/scripts/`
- Review scripts: `skills/autonomous-review/scripts/`

All accessible via the `scripts/` symlink at the project root.
