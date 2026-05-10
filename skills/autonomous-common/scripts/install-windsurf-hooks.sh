#!/usr/bin/env bash
# install-windsurf-hooks.sh — bootstrap project-scoped Windsurf hooks
# from the canonical template.
#
# Windsurf's hook config is at `.windsurf/hooks.json` (hooks-only file).
# Schema reference: docs.windsurf.com/windsurf/cascade/hooks.
#
# Translation from Claude:
#   Event names + matcher are FOLDED into a single event name. Windsurf
#   has separate events for each tool kind (no per-tool matcher field):
#     PreToolUse + Bash    → pre_run_command
#     PreToolUse + Write   → pre_write_code
#     PreToolUse + Edit    → pre_write_code (deduped with Write)
#     PostToolUse + Bash   → post_run_command
#     Stop                 → post_cascade_response
#
#   Hook entries have NO matcher field (Windsurf filters via the event
#   name alone). Each entry keeps {type, command, timeout}.
#
# Hook scripts under skills/autonomous-common/hooks/ use $CLAUDE_PROJECT_DIR
# which Windsurf does NOT natively provide — but the env-var reference
# lives in the command string, so callers must `cd` to the project root
# before running. Windsurf's docs say hooks run with `cwd = project root`,
# so that's typically fine.
#
# Usage:
#   bash skills/autonomous-common/scripts/install-windsurf-hooks.sh
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

target="$(project_root)/.windsurf/hooks.json"

# Fold Claude (event, matcher) → Windsurf event.
AGENT_FOLD_MAP="PreToolUse:Bash:pre_run_command PreToolUse:Write:pre_write_code PreToolUse:Edit:pre_write_code PostToolUse:Bash:post_run_command Stop::post_cascade_response"
export AGENT_FOLD_MAP

folded=$(fold_matcher_into_event "$TEMPLATE")
managed_meta=$(jq '{_managed_by, _managed_note}' "$TEMPLATE")

content=$(jq -n --argjson meta "$managed_meta" --argjson hooks "$folded" \
  '$meta + {hooks: $hooks}')

mkdir -p "$(dirname "$target")"
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

cat <<'EOF' >&2

NOTE: Windsurf hooks fire with cwd = project root, but hook scripts
under skills/autonomous-common/hooks/ reference $CLAUDE_PROJECT_DIR.
If the variable isn't set in your shell, set it explicitly in your
shell rc or wrap the command:
    "command": "cd \"${CASCADE_PROJECT_DIR:-.}\" && bash hooks/...sh"

EOF
echo "Done. Project-scoped Windsurf hooks installed at $target." >&2
