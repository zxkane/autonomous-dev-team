#!/usr/bin/env bash
# install-codex-hooks.sh — bootstrap project-scoped OpenAI Codex CLI hooks
# from the canonical template.
#
# Codex CLI's hook system is modeled directly on Claude Code's
# (per github.com/openai/codex codex-rs/hooks/) and accepts the same
# event names + matcher field. The differences:
#
#   1. Hooks live in `.codex/hooks.json` (NOT `.claude/settings.json`).
#      The file is hooks-only — no other top-level keys.
#   2. The feature is gated behind `[features] codex_hooks = true` in
#      `~/.codex/config.toml` or the project's `.codex/config.toml`.
#      We toggle the project-level flag here.
#
# Caveat: Codex hook support is experimental upstream. The exact tool-
# name matchers ("Bash", "Write", "Edit") are modeled on Claude Code's
# but not officially documented in the Codex docs at
# developers.openai.com/codex/config-advanced. Verify your first hook
# fires before relying on the install.
#
# Usage:
#   bash skills/autonomous-common/scripts/install-codex-hooks.sh
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

require_jq

TEMPLATE="$SCRIPT_DIR/claude-settings.template.json"
if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: canonical template not found at: $TEMPLATE" >&2
  exit 1
fi

target_dir="$(project_root)/.codex"
target="$target_dir/hooks.json"
config_toml="$target_dir/config.toml"

# Codex's hooks.json is hooks-only (same shape as Antigravity). Use the
# hooks-only writer.
write_hooks_only_settings "$TEMPLATE" "$target"

# Toggle the [features] codex_hooks = true flag. This is required
# upstream; without it, the hooks.json file is ignored. We append the
# section if missing, or no-op if already set.
mkdir -p "$target_dir"
if [[ -f "$config_toml" ]]; then
  if grep -qE '^\s*codex_hooks\s*=\s*true\s*$' "$config_toml"; then
    echo "Note: codex_hooks already enabled in $config_toml" >&2
  else
    {
      echo ""
      echo "# Added by install-codex-hooks.sh — required for hooks.json to take effect."
      echo "[features]"
      echo "codex_hooks = true"
    } >> "$config_toml"
    echo "Updated: $config_toml (appended [features] codex_hooks = true)" >&2
  fi
else
  cat > "$config_toml" <<'EOF'
# Created by install-codex-hooks.sh — required for hooks.json to take effect.
[features]
codex_hooks = true
EOF
  echo "Created: $config_toml" >&2
fi

if (( INSTALL_GIT_HOOK == 1 )); then
  install_per_worktree_pre_push
fi

cat <<'EOF' >&2

NOTE: Codex CLI hook support is experimental upstream. Tool-name
matchers (Bash, Write, Edit) are modeled on Claude Code but not
officially documented. Run a no-op test (e.g., a benign shell command
that triggers the push-to-main hook by mistake) to verify hooks fire
before relying on them.

EOF
echo "Done. Project-scoped Codex hooks installed at $target." >&2
