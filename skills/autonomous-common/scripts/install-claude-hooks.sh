#!/usr/bin/env bash
# install-claude-hooks.sh — bootstrap project-scoped Claude Code hooks
# from the autonomous-common skill's canonical template.
#
# Closes #68: SKILL.md frontmatter hooks are skill-scoped, so they only
# fire while the skill is the active context. Free-form bash work outside
# an explicit /autonomous-dev invocation bypasses them entirely. This
# script materializes the same hooks as project-scoped entries in
# `.claude/settings.json`, where Claude Code loads them on every session.
#
# Designed to be run by consumers AFTER `npx skills add zxkane/autonomous-
# dev-team`. NOT auto-run on install — mutating .claude/settings.json
# without explicit consent would be surprising.
#
# Usage:
#   bash skills/autonomous-common/scripts/install-claude-hooks.sh
#
# Idempotent. Safe to re-run on `skills update`. Preserves any non-hooks
# top-level keys (enabledPlugins, statusLine, etc.) the user has set.
#
# Optionally also installs the per-worktree git pre-push hook (#65) by
# calling install-git-pre-push.sh. Disable with --no-git-hook.
#
# Refactored in PR-11a: shared merge logic now lives in lib-installer.sh
# alongside install-qoder-hooks.sh and install-antigravity-hooks.sh, all
# of which use the same canonical claude-settings.template.json. This
# script's behavior is byte-equivalent to the pre-PR-11 version.

set -euo pipefail

INSTALL_GIT_HOOK=1
for arg in "$@"; do
  case "$arg" in
    --no-git-hook) INSTALL_GIT_HOOK=0 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# shellcheck source=lib-installer.sh
source "$SCRIPT_DIR/lib-installer.sh"

require_jq

TEMPLATE="$SCRIPT_DIR/claude-settings.template.json"
if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: canonical template not found at: $TEMPLATE" >&2
  exit 1
fi

target="$(project_root)/.claude/settings.json"

# Claude Code's settings.json holds many other top-level keys the user
# maintains (enabledPlugins, statusLine, ...). Merge in our hooks block,
# preserve everything else.
merge_hooks_settings "$TEMPLATE" "$target" '.hooks.PreToolUse | length > 0'

if (( INSTALL_GIT_HOOK == 1 )); then
  install_per_worktree_pre_push
fi

ensure_dispatcher_scripts_executable

echo "Done. Project-scoped Claude hooks (#68) and git pre-push (#65) are installed." >&2
