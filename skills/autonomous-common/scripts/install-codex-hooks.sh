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
# upstream; without it, the hooks.json file is ignored.
#
# TOML constraint (PR-11b code review C1): defining `[features]` more
# than once is invalid TOML — the Rust `toml` crate that Codex uses
# rejects the entire config. So we MUST NOT blindly append a second
# `[features]` block. The strategy:
#
#   1. No file → create a fresh one with a single `[features]` block.
#   2. File has `codex_hooks = true` already (anywhere) → no-op.
#   3. File has `codex_hooks = false` → refuse + ask operator to fix.
#      (We assume `false` is intentional; flipping it would surprise.)
#   4. File has a `[features]` section → insert `codex_hooks = true` as
#      the first line of that section.
#   5. File has no `[features]` section → append a new one at EOF.
mkdir -p "$target_dir"

toggle_codex_hooks_flag() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    cat > "$file" <<'EOF'
# Created by install-codex-hooks.sh — required for hooks.json to take effect.
[features]
codex_hooks = true
EOF
    echo "Created: $file" >&2
    return 0
  fi

  # Already enabled? (No-op.)
  if grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*true' "$file"; then
    echo "Note: codex_hooks already enabled in $file" >&2
    return 0
  fi

  # Explicitly disabled? Refuse — operator likely set it on purpose.
  if grep -qE '^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*false' "$file"; then
    echo "ERROR: $file contains 'codex_hooks = false'. Hooks would not fire." >&2
    echo "       Edit that line to 'true' (or remove it) and re-run." >&2
    return 1
  fi

  # Insert into existing [features] section, or append a new section.
  if grep -qE '^[[:space:]]*\[features\][[:space:]]*$' "$file"; then
    # Use awk to insert `codex_hooks = true` as the first line after
    # the `[features]` header. Robust against trailing whitespace and
    # blank lines.
    local tmp
    tmp=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" RETURN
    awk '
      BEGIN { inserted = 0 }
      /^[[:space:]]*\[features\][[:space:]]*$/ {
        print
        if (!inserted) {
          print "codex_hooks = true  # added by install-codex-hooks.sh"
          inserted = 1
        }
        next
      }
      { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
    trap - RETURN
    echo "Updated: $file (inserted codex_hooks = true into existing [features] section)" >&2
  else
    {
      printf '\n# Added by install-codex-hooks.sh — required for hooks.json to take effect.\n'
      printf '[features]\n'
      printf 'codex_hooks = true\n'
    } >> "$file"
    echo "Updated: $file (appended new [features] section)" >&2
  fi
}

toggle_codex_hooks_flag "$config_toml" || exit 1

if (( INSTALL_GIT_HOOK == 1 )); then
  install_per_worktree_pre_push
fi

ensure_dispatcher_scripts_executable

cat <<'EOF' >&2

NOTE: Codex CLI hook support is experimental upstream. Tool-name
matchers (Bash, Write, Edit) are modeled on Claude Code but not
officially documented. Run a no-op test (e.g., a benign shell command
that triggers the push-to-main hook by mistake) to verify hooks fire
before relying on them.

EOF
echo "Done. Project-scoped Codex hooks installed at $target." >&2
