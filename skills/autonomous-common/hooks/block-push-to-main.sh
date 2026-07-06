#!/bin/bash
# PreToolUse hook - blocks git push directly to main branch
# All changes must go through PR workflow.
#
# Closes #64: previous regex-only approach had a false positive
# (feature push from a trunk-checked-out clone got blocked) and a
# false negative (`HEAD:refs/heads/main` slipped through). Now uses
# the lib-push.sh parser to identify the actual destination ref(s).
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=lib-push.sh
source "$SCRIPT_DIR/lib-push.sh"

input=$(read_hook_stdin)
command=$(parse_command "$input")

# Only check git push commands
if ! is_git_command "push" "$command"; then
  exit 0
fi

# Trunk branch name. Default to `main`; respect TRUNK_BRANCH override
# for repos with a different trunk (e.g. `master`, `trunk`).
trunk="${TRUNK_BRANCH:-main}"

# Parse the destination ref(s) the push would write to. Block if any of
# them target the trunk (covers --all/--mirror via __ALL__/__MIRROR__).
should_block=0
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  if is_trunk_ref "$ref" "$trunk"; then
    should_block=1
    break
  fi
done < <(parse_push_target_refspec "$command")

if (( should_block == 1 )); then
  cat >&2 <<'EOF'
## BLOCKED - Direct Push to Main

Pushing directly to `main` is **not allowed**. All changes must go through a Pull Request.

### Required Workflow:
1. Create a worktree: `git worktree add .worktrees/feat/<name> -b feat/<name>`
2. Enter the worktree: `cd .worktrees/feat/<name>`
3. Install dependencies and make your changes
4. Commit inside the worktree
5. Push to the feature branch: `git push -u origin feat/<name>`
6. Open a pull/merge request via your platform CLI or the wrapper — e.g. `gh pr create` on GitHub, `glab mr create` on GitLab, or the pipeline's provider seam (`chp_create_pr`).

### See CLAUDE.md for the full development workflow.
EOF
  exit 2
fi

exit 0
