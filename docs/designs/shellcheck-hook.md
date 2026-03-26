# Design: ShellCheck Pre-Commit Hook

**Feature:** check-shellcheck.sh PreToolUse hook
**Date:** 2026-03-26
**Status:** Draft
**Issue:** #35

## Problem

Shell scripts in the autonomous-dev-team project get flagged by PR review bots (Amazon Q Developer, etc.) for injection vulnerabilities, unquoted variables, and other shell pitfalls. These are easily detectable statically with ShellCheck and should be caught at dev time, not during PR review.

## Solution

A `check-shellcheck.sh` PreToolUse hook that runs ShellCheck on staged `.sh` files before `git commit`, blocking the commit if error-level findings exist.

## Hook Behavior

```
git commit triggered
  -> Parse command from hook JSON input
  -> Skip if not a git commit command
  -> Skip if --amend (code already checked)
  -> Find staged .sh files via: git diff --cached --name-only --diff-filter=ACM -- '*.sh'
  -> If no .sh files staged: exit 0 (pass)
  -> If shellcheck not installed: warn on stderr, exit 0 (allow)
  -> Run shellcheck --severity=error on each staged file
  -> If any errors found: print findings, exit 2 (block)
  -> If all clean: exit 0 (pass)
```

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Error-level only (`--severity=error`) | Avoids noise from style/info warnings; focuses on real bugs |
| Graceful degradation | Not all environments have shellcheck; warn but don't block |
| Skip `--amend` | Code was already checked on the original commit |
| Only staged files | Don't check unstaged or untracked files |
| `--diff-filter=ACM` | Only check Added, Copied, Modified files (skip Deleted) |
| Uses `lib.sh` patterns | Consistent with existing hooks (`parse_command`, `is_git_command`) |
| Exit code 2 for block | Matches project convention (exit 2 = block) |

## Files Changed

| File | Change |
|------|--------|
| `skills/autonomous-common/hooks/check-shellcheck.sh` | New hook script |
| `skills/autonomous-common/hooks/README.md` | Add to hook reference table |
| `skills/autonomous-common/SKILL.md` | Add to hook table |

## Integration

The hook is a PreToolUse hook triggered on `Bash` commands. It will be added to `.claude/settings.json` by users who want shellcheck enforcement. The hook follows the same pattern as `block-commit-outside-worktree.sh`.
