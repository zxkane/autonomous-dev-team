#!/usr/bin/env bash
# install-cursor-hooks.sh — bootstrap project-scoped Cursor hooks from
# the canonical template.
#
# Cursor's hook config is at `.cursor/hooks.json` (hooks-only file).
# The schema is Claude-Code-style but with camelCase event names and
# different tool-name matchers. Per cursor.com/docs/agent/hooks:
#
#   Events:    preToolUse, postToolUse, stop, sessionStart, sessionEnd,
#              beforeShellExecution, afterShellExecution, ...
#   Matchers:  Tool names for preToolUse — "Shell", "Write", "Edit", ...
#              Pipe-regex against command text for beforeShellExecution.
#
# We translate the canonical template's PreToolUse/PostToolUse/Stop
# events to Cursor's camelCase forms, and Bash/Write/Edit matchers to
# Shell/Write/Edit. (Cursor's `Shell` tool covers Bash; Write/Edit names
# are the same.)
#
# Cursor hooks expect a `version: 1` envelope at the top level.
#
# Usage:
#   bash skills/autonomous-common/scripts/install-cursor-hooks.sh
#
# Idempotent. --no-git-hook to skip the per-worktree git pre-push (#65).

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
# shellcheck source=lib-installer-translate.sh
source "$SCRIPT_DIR/lib-installer-translate.sh"

require_jq

TEMPLATE="$SCRIPT_DIR/claude-settings.template.json"
if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: canonical template not found at: $TEMPLATE" >&2
  exit 1
fi

target="$(project_root)/.cursor/hooks.json"

# Translate Claude → Cursor names.
AGENT_EVENT_MAP="PreToolUse:preToolUse PostToolUse:postToolUse Stop:stop"
AGENT_TOOL_MAP="Bash:Shell Write:Write Edit:Edit"
export AGENT_EVENT_MAP AGENT_TOOL_MAP

# Build the full Cursor hooks.json: {version: 1, _managed_*, hooks: {...}}.
mkdir -p "$(dirname "$target")"
translated_hooks=$(translate_template_hooks "$TEMPLATE")
managed_meta=$(jq '{_managed_by, _managed_note}' "$TEMPLATE")
content=$(jq -n --argjson meta "$managed_meta" --argjson hooks "$translated_hooks" \
  '{version: 1} + $meta + {hooks: $hooks}')

if [[ -f "$target" ]]; then
  backup="$(backup_path "$target")"
  cp "$target" "$backup"
  printf '%s\n' "$content" > "$target"
  echo "Updated: $target (backup at $backup)" >&2
else
  printf '%s\n' "$content" > "$target"
  echo "Created: $target" >&2
fi

if (( INSTALL_GIT_HOOK == 1 )); then
  install_per_worktree_pre_push
fi

ensure_dispatcher_scripts_executable

echo "Done. Project-scoped Cursor hooks installed at $target." >&2
