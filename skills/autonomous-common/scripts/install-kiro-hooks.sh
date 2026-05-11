#!/usr/bin/env bash
# install-kiro-hooks.sh — bootstrap project-scoped Kiro CLI / Amazon Q
# Developer CLI hooks from the canonical template.
#
# Kiro CLI uses agent definitions at `.kiro/agents/<name>.json`. Each
# agent has a top-level shape with `name`, `prompt`, `tools`, `hooks`,
# etc. We merge into the agent's `hooks` field, preserving everything
# else.
#
# Schema reference: kiro.dev/docs/cli/hooks
#
# Translation from Claude:
#   Event names:  PreToolUse → preToolUse, PostToolUse → postToolUse,
#                 Stop → stop, UserPromptSubmit → userPromptSubmit (camelCase).
#   Tool matchers: Bash → execute_bash, Write → fs_write, Edit → fs_write
#                 (Kiro unifies write+edit into fs_write).
#   Timeout unit: MILLISECONDS via `timeout_ms` field (Claude uses seconds
#                 via `timeout`). We multiply by 1000.
#
# Default agent: `default`. Override with --agent <name>.
#
# Usage:
#   bash skills/autonomous-common/scripts/install-kiro-hooks.sh
#   bash skills/autonomous-common/scripts/install-kiro-hooks.sh --agent autonomous-dev
#
# Idempotent. --no-git-hook to skip the per-worktree git pre-push (#65).

set -euo pipefail

INSTALL_GIT_HOOK=1
AGENT_NAME="default"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-git-hook) INSTALL_GIT_HOOK=0; shift ;;
    --agent)
      [[ $# -ge 2 ]] || { echo "ERROR: --agent requires a value" >&2; exit 2; }
      AGENT_NAME="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if ! [[ "$AGENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "ERROR: --agent name must be alphanumeric, dash, or underscore: '$AGENT_NAME'" >&2
  exit 2
fi

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

target="$(project_root)/.kiro/agents/${AGENT_NAME}.json"

# Translate Claude → Kiro names + convert timeouts to milliseconds.
AGENT_EVENT_MAP="PreToolUse:preToolUse PostToolUse:postToolUse Stop:stop"
AGENT_TOOL_MAP="Bash:execute_bash Write:fs_write Edit:fs_write"
export AGENT_EVENT_MAP AGENT_TOOL_MAP

translated_hooks=$(translate_template_hooks "$TEMPLATE" | convert_timeouts_to_ms)
managed_meta=$(jq '{_managed_by, _managed_note}' "$TEMPLATE")

# Kiro agent files have many top-level keys (name, prompt, tools, ...)
# that the operator owns. We merge ONLY the hooks field + management
# annotations. If the file doesn't exist, create a minimal stub with
# just hooks — the operator can add name/prompt/tools if they want a
# fully functional agent. (Kiro will run the agent without those fields
# if it can fall back to defaults.)
mkdir -p "$(dirname "$target")"

if [[ ! -f "$target" ]]; then
  # Stub the agent with sensible defaults pointing at this repo's
  # AGENTS.md and skills. Operators can edit later.
  jq -n --argjson meta "$managed_meta" --argjson hooks "$translated_hooks" \
    --arg name "$AGENT_NAME" \
    '$meta + {
       name: $name,
       description: "autonomous-dev workflow agent",
       prompt: "file://../../CLAUDE.md",
       tools: ["fs_read", "fs_write", "execute_bash"],
       allowedTools: ["fs_read", "fs_write", "execute_bash"],
       hooks: $hooks
     }' > "$target"
  echo "Created: $target (stub agent — edit prompt/tools/resources as needed)" >&2
else
  backup="$(backup_path "$target")"
  cp "$target" "$backup"

  tmp=$(mktemp)
  # shellcheck disable=SC2064  # we want $tmp expanded NOW, not at trap fire
  trap "rm -f '$tmp'" EXIT
  jq --argjson meta "$managed_meta" --argjson hooks "$translated_hooks" \
    '. + $meta + {hooks: $hooks}' "$target" > "$tmp"

  # Verify before commit.
  if ! jq -e '.hooks.preToolUse | length > 0' "$tmp" >/dev/null \
     || ! jq -e '._managed_by == "autonomous-common"' "$tmp" >/dev/null; then
    mv "$backup" "$target"
    echo "ERROR: merge produced an unexpected result; restored backup" >&2
    exit 1
  fi

  mv "$tmp" "$target"
  trap - EXIT
  echo "Updated: $target (backup at $backup)" >&2
fi

if (( INSTALL_GIT_HOOK == 1 )); then
  install_per_worktree_pre_push
fi

ensure_dispatcher_scripts_executable

echo "Done. Project-scoped Kiro hooks installed at $target." >&2
