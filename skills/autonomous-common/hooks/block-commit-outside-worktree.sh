#!/bin/bash
# PreToolUse hook - blocks git commits when not in a worktree
# All development must happen in a git worktree
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

input=$(read_hook_stdin)
command=$(parse_command "$input")

# Capture the installing repository identity before evaluating command context.
base_dir=$(pwd -P)
hook_common_dir=""
if hook_common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  hook_common_dir=$(_canonical_existing_directory "$hook_common_dir") || hook_common_dir=""
fi

# The resolver is the single source of truth: rc=0 is a supported commit,
# rc=1 is a proven no-match, and rc=2 is a matching but uncertain command that
# must fail closed. Avoid running the same shell scanner twice inside the
# hook's five-second budget.
resolved_dir=""
if resolved_dir=$(resolve_git_command_cwd "commit" "$command" "$base_dir"); then
  resolve_rc=0
else
  resolve_rc=$?
fi

if [[ "$resolve_rc" -eq 1 ]]; then
  exit 0
fi

# Allow amends (fixing existing commits)
if [[ "$command" =~ --amend ]]; then
  exit 0
fi

# Any mismatch or resolution uncertainty falls back to the inherited cwd.
if [[ "$resolve_rc" -ne 0 ]]; then
  resolved_dir="$base_dir"
fi

target_common_dir=""
if [[ -n "$hook_common_dir" ]] &&
  target_common_dir=$(git -C "$resolved_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
  target_common_dir=$(_canonical_existing_directory "$target_common_dir"); then
  if [[ "$target_common_dir" != "$hook_common_dir" ]]; then
    exit 0
  fi
else
  resolved_dir="$base_dir"
  target_common_dir="$hook_common_dir"
fi

# For repo A, git-dir differs from git-common-dir only in a linked worktree.
target_git_dir=""
if [[ -n "$target_common_dir" ]] &&
  target_git_dir=$(git -C "$resolved_dir" rev-parse --path-format=absolute --git-dir 2>/dev/null) &&
  target_git_dir=$(_canonical_existing_directory "$target_git_dir") &&
  [[ "$target_git_dir" != "$target_common_dir" ]]; then
  exit 0
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
