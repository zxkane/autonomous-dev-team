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

# Trunk protection guards THIS project's repository. Resolve the repository the
# push actually targets (`git -C <path> push`, `cd <path> && git push`) and bow
# out when it is a different one: a sibling checkout, a vendored dependency, or
# a project's separate `<project>.wiki.git`. A wiki has no PR flow and `main` is
# its only branch, so blocking it made wiki updates impossible rather than
# routing them through review.
#
# Mirrors the identity check block-commit-outside-worktree.sh already performs.
# Comparing git-common-dir (shared by a repo and all its linked worktrees) keeps
# a worktree of this project counted as this project — the scoping must not
# become an escape hatch (see TC-BP-14/15). Any resolution uncertainty falls
# back to the inherited cwd, so an unparsable command is still checked.
hook_common_dir=""
if hook_common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
  hook_common_dir=$(_canonical_existing_directory "$hook_common_dir") || hook_common_dir=""
fi

push_dir="$(pwd -P)"
if resolved_dir=$(resolve_git_command_cwd "push" "$command" "$push_dir"); then
  push_dir="$resolved_dir"
fi

if [[ -n "$hook_common_dir" ]] &&
  target_common_dir=$(git -C "$push_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) &&
  target_common_dir=$(_canonical_existing_directory "$target_common_dir") &&
  [[ "$target_common_dir" != "$hook_common_dir" ]]; then
  exit 0
fi

# Trunk branch name (issue #478, [INV-131]): BASE_BRANCH (the wrapper
# resolves+exports it once at startup) → TRUNK_BRANCH (this hook's pre-#478
# override, still honored standalone e.g. for a manually-run hook outside the
# wrapper) → "main" default. Byte-identical to today when neither is set.
trunk="${BASE_BRANCH:-${TRUNK_BRANCH:-main}}"

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
  cat >&2 <<EOF
## BLOCKED - Direct Push to \`${trunk}\`

Pushing directly to \`${trunk}\` is **not allowed**. All changes must go through a Pull Request.

### Required Workflow:
1. Create a worktree: \`git worktree add .worktrees/feat/<name> -b feat/<name>\`
2. Enter the worktree: \`cd .worktrees/feat/<name>\`
3. Install dependencies and make your changes
4. Commit inside the worktree
5. Push to the feature branch: \`git push -u origin feat/<name>\`
6. Open a pull/merge request via your platform CLI or the wrapper — e.g. \`gh pr create\` on GitHub, \`glab mr create\` on GitLab, or the pipeline's provider seam (\`chp_create_pr\`).

### See CLAUDE.md for the full development workflow.
EOF
  exit 2
fi

exit 0
