#!/usr/bin/env bash
# install-qoder-hooks.sh — bootstrap project-scoped Qoder (Alibaba) hooks
# from the canonical template.
#
# Qoder adopted Claude Code's hook schema verbatim (events, matcher
# field, JSON shape, exit code 2 = block). Its config file is
# `.qoder/settings.json`, also a multi-key settings file with other
# top-level keys the operator maintains (similar to .claude/settings.json).
# So the merge strategy is identical to the Claude installer: merge the
# canonical hooks block in, preserve everything else.
#
# Usage:
#   bash skills/autonomous-common/scripts/install-qoder-hooks.sh
#
# Idempotent. Optional --no-git-hook to skip the per-worktree git
# pre-push hook (#65). Source: docs.qoder.com/cli/hooks.

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

target="$(project_root)/.qoder/settings.json"

# Same merge contract as the Claude installer: Qoder's settings.json
# holds other operator-managed keys; preserve them.
merge_hooks_settings "$TEMPLATE" "$target" '.hooks.PreToolUse | length > 0'

if (( INSTALL_GIT_HOOK == 1 )); then
  install_per_worktree_pre_push
fi

ensure_dispatcher_scripts_executable

echo "Done. Project-scoped Qoder hooks installed at $target." >&2
