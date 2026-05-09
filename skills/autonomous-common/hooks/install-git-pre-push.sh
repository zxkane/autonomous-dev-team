#!/usr/bin/env bash
# install-git-pre-push.sh — write a per-worktree git pre-push hook
# that blocks pushes to the trunk branch.
#
# Closes #65. This is Layer 2 of the trunk-protection defense in depth
# (Layer 1 is the Claude PreToolUse hook block-push-to-main.sh; Layer 3
# would be server-side branch protection, which is unavailable on
# GitHub Free private repos).
#
# Usage:
#   bash install-git-pre-push.sh                  # install in current worktree
#   TRUNK_BRANCH=master bash install-git-pre-push.sh   # override trunk name
#
# Idempotent: re-running rewrites the hook with canonical contents. Any
# pre-existing `pre-push` hook NOT marked with the "managed by autonomous-
# common" sentinel is preserved as `pre-push.bak.<timestamp>` first.
#
# The emitted hook is self-contained — no `lib-push.sh` source — because
# git hooks run from the worktree root with no project lib path on $PATH.

set -euo pipefail

# Resolve the worktree's hooks dir. `git rev-parse --git-path hooks`
# correctly handles both regular clones (.git is a directory) and git
# worktrees (.git is a file pointing into the main repo's worktrees/).
hooks_dir=$(git rev-parse --git-path hooks 2>/dev/null) || {
  echo "ERROR: not in a git repo (or git rev-parse failed)" >&2
  exit 1
}
mkdir -p "$hooks_dir"

target="$hooks_dir/pre-push"
sentinel="# managed by autonomous-common::install-git-pre-push.sh"

# Determine trunk name. Priority:
#   1. $TRUNK_BRANCH env override
#   2. Symbolic ref of refs/remotes/origin/HEAD (canonical trunk on origin)
#   3. Fallback: "main"
trunk="${TRUNK_BRANCH:-}"
if [[ -z "$trunk" ]]; then
  if origin_head=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); then
    # Strip the `origin/` prefix.
    trunk="${origin_head#origin/}"
  fi
fi
trunk="${trunk:-main}"

# If a pre-push hook exists and is NOT ours, back it up.
if [[ -f "$target" ]] && ! grep -q "$sentinel" "$target" 2>/dev/null; then
  # Append $$ for uniqueness if two installs race within the same second
  # (not a real attack vector, but cheap defense-in-depth).
  backup="$target.bak.$(date +%s).$$"
  mv "$target" "$backup"
  echo "Existing unmanaged pre-push hook backed up to: $backup" >&2
fi

cat > "$target" <<HOOK
#!/usr/bin/env bash
${sentinel}
# Blocks direct pushes to the trunk branch (refs/heads/${trunk}).
# Override (documented emergencies only): git push --no-verify ...
set -euo pipefail

while read -r local_ref local_sha remote_ref remote_sha; do
  if [[ "\${remote_ref}" == "refs/heads/${trunk}" ]]; then
    cat >&2 <<MSG
## BLOCKED — Direct push to refs/heads/${trunk}

Pushing directly to the trunk branch is not allowed.

Required workflow:
  1. Create a worktree: git worktree add .worktrees/feat/<name> -b feat/<name>
  2. Push the feature branch: git push -u origin feat/<name>
  3. Open a PR: gh pr create

To override (documented emergencies only): git push --no-verify ...
MSG
    exit 1
  fi
done
HOOK

chmod +x "$target"
echo "Installed git pre-push hook at: $target (trunk=${trunk})" >&2
