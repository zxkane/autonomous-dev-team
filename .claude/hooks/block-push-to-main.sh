#!/bin/bash
# PreToolUse hook - blocks git push directly to main branch
# All changes must go through PR workflow
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

input=$(cat)
command=$(parse_command "$input")

# Only check git push commands
if ! is_git_command "push" "$command"; then
  exit 0
fi

# Get current branch
current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

# Block pushes targeting main:
# 1. Pushing while on main (without explicit refspec)
# 2. Using refspec to push to main (e.g., git push origin feature:main)
if [[ "$command" =~ :main([[:space:]]|$) ]] || [[ "$current_branch" == "main" && ! "$command" =~ : ]]; then
  cat >&2 <<'EOF'
## BLOCKED - Direct Push to Main

Pushing directly to `main` is **not allowed**. All changes must go through a Pull Request.

### Required Workflow:
1. Create a worktree: `git worktree add .worktrees/feat/<name> -b feat/<name>`
2. Enter the worktree: `cd .worktrees/feat/<name>`
3. Install dependencies and make your changes
4. Commit inside the worktree
5. Push to the feature branch: `git push -u origin feat/<name>`
6. Create a PR via `gh pr create`

### See CLAUDE.md for the full development workflow.
EOF
  exit 2
fi

exit 0
