#!/bin/bash
# PreToolUse hook - checks if branch is behind upstream base branch and requires rebase before push
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"

input=$(read_hook_stdin)
command=$(parse_command "$input")

# Only check git push commands
if ! is_git_command "push" "$command"; then
  exit 0
fi

# Skip force-push (already rebased, just pushing result)
if [[ "$command" =~ --force ]] || [[ "$command" =~ --force-with-lease ]]; then
  exit 0
fi

# Base/trunk branch. Hooks stay zero-dependency shell (no conf parsing) —
# issue #478 ([INV-131]): the wrapper resolves+exports BASE_BRANCH once at
# startup, so this hook just reads the env chain BASE_BRANCH → TRUNK_BRANCH
# (block-push-to-main.sh's own override) → "main". Byte-identical to today
# when neither is set.
base_branch="${BASE_BRANCH:-${TRUNK_BRANCH:-main}}"

# Get current branch
current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")

# Skip if on the base branch itself (block-push-to-main.sh handles that)
if [[ "$current_branch" == "$base_branch" || "$current_branch" == "unknown" ]]; then
  exit 0
fi

# Fetch latest upstream base branch (silently)
git fetch origin "$base_branch" --quiet 2>/dev/null || exit 0

# Check if current branch is behind origin/<base_branch>
BEHIND=$(git rev-list --count "HEAD..origin/${base_branch}" 2>/dev/null || echo "0")

if [[ "$BEHIND" -gt 0 ]]; then
  cat >&2 <<EOF
## Rebase Required Before Push

Your branch \`$current_branch\` is **$BEHIND commit(s) behind** \`origin/${base_branch}\`.

You must rebase onto the latest ${base_branch} before pushing to avoid merge conflicts:

\`\`\`bash
git fetch origin ${base_branch}
git rebase origin/${base_branch}
# Resolve any conflicts if they arise, then:
# git rebase --continue
git push -u origin "$current_branch"
\`\`\`

If conflicts occur during rebase, resolve them file by file, then \`git add <file>\` and \`git rebase --continue\`.
EOF
  exit 2
fi

exit 0
