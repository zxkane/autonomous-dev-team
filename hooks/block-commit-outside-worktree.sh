#!/bin/bash
# PreToolUse hook - blocks git commits when not in a worktree
# All development must happen in a git worktree
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

input=$(cat)
command=$(parse_command "$input")

# Only check git commit commands
if ! is_git_command "commit" "$command"; then
  exit 0
fi

# Allow amends (fixing existing commits)
if [[ "$command" =~ --amend ]]; then
  exit 0
fi

# Check if we're inside a worktree (not the main working tree)
# Uses git-dir vs git-common-dir: in a worktree, git-dir points to
# .git/worktrees/<name> which differs from git-common-dir (.git)
if git rev-parse --is-inside-work-tree &>/dev/null; then
  git_dir=$(git rev-parse --git-dir 2>/dev/null || echo "")
  git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
  if [[ "$git_dir" != "$git_common_dir" ]]; then
    exit 0
  fi
fi

# Block the commit
cat >&2 <<'EOF'
## BLOCKED - Must Use Git Worktree

Committing directly in the main workspace is **not allowed**. All development must happen in a git worktree.

### Required Workflow:
1. Create a worktree:
   ```bash
   git worktree add .worktrees/feat/<name> -b feat/<name>
   cd .worktrees/feat/<name>
   ```

2. Install dependencies and do all development inside the worktree

3. Commit and push from the worktree

### Why Worktrees?
- Isolates each feature/fix in its own directory
- Prevents accidental changes to main workspace
- Enables parallel work on multiple features
- See CLAUDE.md for the full development workflow

### Exception:
If this is a config-only change (hooks, settings, docs), create a worktree anyway — the workflow applies to ALL changes.
EOF

exit 2
