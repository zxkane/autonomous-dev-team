#!/bin/bash
# PreToolUse hook - checks if branch is behind upstream main and requires rebase before push
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

input=$(cat)
command=$(parse_command "$input")

# Only check git push commands
if ! is_git_command "push" "$command"; then
  exit 0
fi

# Skip force-push (already rebased, just pushing result)
if [[ "$command" =~ --force ]] || [[ "$command" =~ --force-with-lease ]]; then
  exit 0
fi

# Get current branch
current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")

# Skip if on main (block-push-to-main.sh handles that)
if [[ "$current_branch" == "main" || "$current_branch" == "unknown" ]]; then
  exit 0
fi

# Fetch latest upstream main (silently)
git fetch origin main --quiet 2>/dev/null || exit 0

# Check if current branch is behind origin/main
BEHIND=$(git rev-list --count "HEAD..origin/main" 2>/dev/null || echo "0")

if [[ "$BEHIND" -gt 0 ]]; then
  cat >&2 <<EOF
## Rebase Required Before Push

Your branch \`$current_branch\` is **$BEHIND commit(s) behind** \`origin/main\`.

You must rebase onto the latest main before pushing to avoid merge conflicts:

\`\`\`bash
git fetch origin main
git rebase origin/main
# Resolve any conflicts if they arise, then:
# git rebase --continue
git push -u origin "$current_branch"
\`\`\`

If conflicts occur during rebase, resolve them file by file, then \`git add <file>\` and \`git rebase --continue\`.
EOF
  exit 2
fi

exit 0
