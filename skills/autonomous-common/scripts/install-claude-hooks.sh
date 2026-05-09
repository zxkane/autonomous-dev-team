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

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required (apt: jq, brew: jq)." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/claude-settings.template.json"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: canonical template not found at: $TEMPLATE" >&2
  exit 1
fi

# Locate project root. Prefer git toplevel; fall back to CWD.
project_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
settings_dir="$project_root/.claude"
settings_file="$settings_dir/settings.json"
mkdir -p "$settings_dir"

# Strategy:
#   - If settings.json doesn't exist: write the template verbatim.
#   - If it exists: merge our `hooks`, `_managed_by`, `_managed_note`
#     into the existing file, preserving any other top-level keys.
#     This OVERWRITES any prior `hooks` block (including hand-edits).
#     The `_managed_note` field documents this contract loud-and-clear.
#
# Merge uses jq, which guarantees JSON-correctness regardless of
# whitespace / comments in the input (`.claude/settings.json` is JSON,
# not JSONC; comments aren't valid).

if [[ ! -f "$settings_file" ]]; then
  cp "$TEMPLATE" "$settings_file"
  echo "Created: $settings_file (from template)" >&2
else
  # Backup the existing file before mutation.
  # Append $$ for uniqueness if two installs race within the same second.
  backup="$settings_file.bak.$(date +%s).$$"
  cp "$settings_file" "$backup"

  # Compose: existing settings + (template's _managed_by, _managed_note,
  # hooks fields). Right side wins on key conflicts.
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  jq -s '
    .[0] as $existing |
    .[1] as $tmpl |
    $existing
      + ($tmpl | {_managed_by, _managed_note, hooks})
  ' "$settings_file" "$TEMPLATE" > "$tmp"

  # Sanity check: the merged file must still be valid JSON and contain
  # the canonical hooks block. If anything went wrong, restore the
  # backup and fail loudly.
  if ! jq -e '.hooks.PreToolUse | length > 0' "$tmp" >/dev/null; then
    mv "$backup" "$settings_file"
    echo "ERROR: merge produced an unexpected result; restored backup" >&2
    exit 1
  fi

  mv "$tmp" "$settings_file"
  trap - EXIT
  echo "Updated: $settings_file (backup at $backup)" >&2
fi

# Optional: also install the per-worktree git pre-push hook (#65).
if (( INSTALL_GIT_HOOK == 1 )); then
  git_hook_installer="$(dirname "$SCRIPT_DIR")/hooks/install-git-pre-push.sh"
  if [[ -x "$git_hook_installer" ]]; then
    echo "Installing git-side pre-push hook (#65)..." >&2
    bash "$git_hook_installer"
  else
    echo "WARN: git-side hook installer not found at: $git_hook_installer" >&2
    echo "      Skipping. Re-run with --no-git-hook to suppress this warning." >&2
  fi
fi

echo "Done. Project-scoped Claude hooks (#68) and git pre-push (#65) are installed." >&2
