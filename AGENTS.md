# Autonomous Dev Team

## Available Skills

Install via: `npx skills add zxkane/autonomous-dev-team`

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

### create-issue
Interactive GitHub issue creation with structured templates, autonomous
label guidance, and workspace change attachment. Supports feature
requests and bug reports.

## Workflow Summary

1. Design -> 2. Worktree -> 3. Tests -> 4. Implement -> 5. Verify ->
6. Review -> 7. PR -> 8. CI -> 9. E2E -> 10. Merge

## Scripts

Supporting scripts in `scripts/` provide agent CLI abstraction,
GitHub authentication, and pipeline utilities.

## Hooks

Optional workflow enforcement hooks in `hooks/`. See `hooks/README.md`
for IDE-specific setup.
