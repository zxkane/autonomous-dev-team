#!/usr/bin/env bash
# install-gemini-hooks.sh — bootstrap project-scoped Gemini CLI hooks
# from the canonical template.
#
# Gemini CLI's hook config is at `.gemini/settings.json`, which is a
# multi-key settings file (operators may have other top-level keys).
# Schema reference: github.com/google-gemini/gemini-cli/blob/main/docs/hooks/index.md.
#
# Translation from Claude:
#   Event names:  PreToolUse → BeforeTool, PostToolUse → AfterTool,
#                 Stop → Stop (kept; Gemini's `Stop` event semantically matches).
#   Tool matchers: regex against tool name. Built-in Gemini tool names:
#                 Bash → run_shell_command
#                 Write → write_file (covers new-file writes)
#                 Edit → replace (covers in-place edits)
#   Timeout unit: same as Claude (seconds via `timeout` field).
#
# Notable: Gemini explicitly provides a $CLAUDE_PROJECT_DIR env var for
# Claude Code compatibility, so the existing hook scripts under
# skills/autonomous-common/hooks/ run unchanged.
#
# Usage:
#   bash skills/autonomous-common/scripts/install-gemini-hooks.sh
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

target="$(project_root)/.gemini/settings.json"

# Translate Claude → Gemini names.
AGENT_EVENT_MAP="PreToolUse:BeforeTool PostToolUse:AfterTool Stop:Stop"
AGENT_TOOL_MAP="Bash:run_shell_command Write:write_file Edit:replace"
export AGENT_EVENT_MAP AGENT_TOOL_MAP

# Build a "fake" template file that has Gemini-shaped hooks but the same
# top-level _managed_by/_managed_note as the canonical template. Then
# feed it through the same merge_hooks_settings used by Claude/Qoder.
translated_hooks=$(translate_template_hooks "$TEMPLATE")
managed_meta=$(jq '{_managed_by, _managed_note}' "$TEMPLATE")

tmp_template=$(mktemp)
# shellcheck disable=SC2064  # we want $tmp_template expanded NOW, not at trap fire
trap "rm -f '$tmp_template'" EXIT
jq -n --argjson meta "$managed_meta" --argjson hooks "$translated_hooks" \
  '$meta + {hooks: $hooks}' > "$tmp_template"

# Gemini's settings.json is multi-key, so use the merge writer. The
# verify filter checks that BeforeTool (the new event name) is populated.
merge_hooks_settings "$tmp_template" "$target" '.hooks.BeforeTool | length > 0'

if (( INSTALL_GIT_HOOK == 1 )); then
  install_per_worktree_pre_push
fi

ensure_dispatcher_scripts_executable

echo "Done. Project-scoped Gemini hooks installed at $target." >&2
