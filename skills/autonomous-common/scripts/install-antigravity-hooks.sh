#!/usr/bin/env bash
# install-antigravity-hooks.sh — bootstrap project-scoped Antigravity
# (Google) hooks from the canonical template.
#
# Antigravity is undocumented officially but the community-observed
# config (e.g. lehau007/AI-Auto-Log-Windows, AgusRdz/chop) confirms it
# accepts Claude Code's hook schema verbatim. Its config path is
# `.antigravity/hooks.json` — DIFFERENT from Claude / Qoder which use
# settings.json — and the file is hooks-only (no other top-level keys).
#
# So the install strategy differs from Claude / Qoder: write the hooks
# block + _managed_by + _managed_note as the entire file body, no merge.
#
# Caveat: Antigravity's hook contract is undocumented; Google could
# change or remove it without notice. Use at your own risk.
#
# Usage:
#   bash skills/autonomous-common/scripts/install-antigravity-hooks.sh
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

target="$(project_root)/.antigravity/hooks.json"

# Antigravity's hooks.json holds ONLY the hooks block. No merge with
# operator-maintained keys — the file's purpose is hooks. Use the
# hooks-only writer, which still backs up before overwrite.
write_hooks_only_settings "$TEMPLATE" "$target"

if (( INSTALL_GIT_HOOK == 1 )); then
  install_per_worktree_pre_push
fi

ensure_dispatcher_scripts_executable

cat <<'EOF' >&2

NOTE: Antigravity's hook contract is undocumented by Google. The
schema and tool names (Bash, Write, Edit, etc.) are inferred from
community usage and may change. If your hooks stop firing after an
Antigravity update, check Google's release notes and re-verify.

EOF
echo "Done. Project-scoped Antigravity hooks installed at $target." >&2
