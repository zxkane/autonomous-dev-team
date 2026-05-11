#!/usr/bin/env bash
# lib-installer.sh — shared logic for cross-agent hook installers.
#
# Sourced by install-{claude,qoder,antigravity,...}-hooks.sh. Provides:
#
#   - merge_hooks_settings <template> <target> <required-jq-check>
#       Merge the canonical hook block from <template> into <target>,
#       preserving any other top-level keys the user has set. Backs up
#       the existing target before mutation. <required-jq-check> is a
#       jq filter that must evaluate to true on the merged file (used
#       to verify the merge produced sane output before committing).
#
#   - write_hooks_only_settings <template> <target>
#       For agents whose config file holds ONLY the hooks block
#       (e.g. Antigravity's .antigravity/hooks.json). Writes the
#       template's `hooks` field as the entire file body.
#
#   - install_per_worktree_pre_push
#       Runs the autonomous-common per-worktree git pre-push installer
#       (closes #65). No-op-with-warning if the script isn't present.
#
# These helpers are agent-agnostic. The per-agent installer scripts
# decide WHICH file to write to and WHICH merge strategy to use; this
# lib provides the verified plumbing.
#
# Required: jq.

set -euo pipefail

# Path to the autonomous-common scripts dir (where this lib lives).
_LIB_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# require_jq — abort if jq isn't on PATH. All merges go through jq for
# JSON correctness; no jq means no installer.
require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required (apt: jq, brew: jq)." >&2
    exit 1
  fi
}

# project_root — best-effort project root: git toplevel, fall back to CWD.
project_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

# backup_path <file>
# Append epoch + PID for uniqueness if two installs race within the same
# second. Echo the chosen backup path on stdout.
backup_path() {
  local f="$1"
  echo "${f}.bak.$(date +%s).$$"
}

# merge_hooks_settings <template> <target> <verify-jq-filter>
#
# For agents whose config file is a settings.json that may have OTHER
# top-level keys the user maintains (Claude Code, Qoder, ...). Merges
# the template's `_managed_by`, `_managed_note`, `hooks` fields into the
# existing settings file, preserving everything else.
#
# If <target> doesn't exist yet, copies the template verbatim.
#
# <verify-jq-filter> is a jq -e expression that must succeed on the
# merged file before it's committed (typically: `.hooks.PreToolUse |
# length > 0`). On failure, the backup is restored and we exit 1.
merge_hooks_settings() {
  local template="$1" target="$2" verify_filter="$3"
  local target_dir
  target_dir="$(dirname "$target")"
  mkdir -p "$target_dir"

  if [[ ! -f "$target" ]]; then
    cp "$template" "$target"
    echo "Created: $target (from template)" >&2
    return 0
  fi

  local backup
  backup="$(backup_path "$target")"
  cp "$target" "$backup"

  # Right side wins on key conflicts; the template's `hooks` block
  # OVERWRITES any existing hooks (operators who hand-edit hooks must
  # update the template, not the merged file — the `_managed_note`
  # field documents this).
  local tmp
  tmp=$(mktemp)
  # EXIT (not RETURN) so cleanup fires even on `set -e` abort paths inside
  # this function. Caller scripts run with `set -euo pipefail`; jq failures
  # on a malformed existing target would otherwise leak the tmp file.
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" EXIT
  jq -s '
    .[0] as $existing |
    .[1] as $tmpl |
    $existing
      + ($tmpl | {_managed_by, _managed_note, hooks})
  ' "$target" "$template" > "$tmp"

  # Verify the merged file is sane:
  #   - Caller-supplied filter (typically '.hooks.PreToolUse | length > 0')
  #     catches wholesale hook-block destruction.
  #   - We additionally hard-check `_managed_by == "autonomous-common"` so
  #     a template edit that silently drops the management annotation is
  #     also caught (without it, the "hand-edits will be overwritten on
  #     re-run" contract documented in _managed_note is invisible).
  if ! jq -e "($verify_filter) and (._managed_by == \"autonomous-common\")" "$tmp" >/dev/null; then
    mv "$backup" "$target"
    echo "ERROR: merge produced an unexpected result; restored backup" >&2
    exit 1
  fi

  mv "$tmp" "$target"
  trap - EXIT
  echo "Updated: $target (backup at $backup)" >&2
}

# write_hooks_only_settings <template> <target>
#
# For agents whose config file holds ONLY the hooks block — e.g.
# Antigravity's `.antigravity/hooks.json`. Writes the `hooks`,
# `_managed_by`, and `_managed_note` fields from the template as the
# entire file body. Existing file is backed up before overwrite.
write_hooks_only_settings() {
  local template="$1" target="$2"
  local target_dir
  target_dir="$(dirname "$target")"
  mkdir -p "$target_dir"

  local content
  content=$(jq '{_managed_by, _managed_note, hooks}' "$template")

  if [[ -f "$target" ]]; then
    local backup
    backup="$(backup_path "$target")"
    cp "$target" "$backup"
    printf '%s\n' "$content" > "$target"
    echo "Updated: $target (backup at $backup)" >&2
  else
    printf '%s\n' "$content" > "$target"
    echo "Created: $target" >&2
  fi
}

# ensure_dispatcher_scripts_executable
#
# Heal +x on the autonomous-dispatcher's directly-invoked wrapper scripts
# in the consumer's installed tree (closes #97). The skills CLI hashes
# only path + content (not file mode), so a 644→755 mode flip in the
# upstream repo does NOT change the consumer's computedHash and they
# never see the fix via `npx skills update`. This helper closes that gap
# at install-time: if the consumer ever re-runs install-*-hooks.sh, the
# wrapper scripts get +x even when the underlying skill bits are stale.
#
# Scoped to the two scripts dispatch-local.sh invokes directly. Sourced-
# only siblings (lib-*.sh) are deliberately left alone — the contract is
# "wrapper scripts get +x, libs don't". Best-effort: a missing file or
# read-only filesystem warns and continues; never aborts the installer.
ensure_dispatcher_scripts_executable() {
  local root candidate dispatcher_dir
  root="$(project_root)"
  dispatcher_dir=""
  # Resolve the consumer-side dispatcher scripts dir. The skills CLI may
  # install under .agents/skills/, .claude/skills/, or directly at
  # skills/ depending on the consumer's project shape. Probe each.
  for candidate in \
    "$root/.agents/skills/autonomous-dispatcher/scripts" \
    "$root/.claude/skills/autonomous-dispatcher/scripts" \
    "$root/skills/autonomous-dispatcher/scripts"; do
    if [[ -d "$candidate" ]]; then
      dispatcher_dir="$candidate"
      break
    fi
  done

  if [[ -z "$dispatcher_dir" ]]; then
    echo "WARN: ensure_dispatcher_scripts_executable: no autonomous-dispatcher/scripts dir found under $root — skipping" >&2
    return 0
  fi

  local f
  for f in autonomous-dev.sh autonomous-review.sh; do
    if [[ -f "$dispatcher_dir/$f" && ! -x "$dispatcher_dir/$f" ]]; then
      if chmod +x "$dispatcher_dir/$f" 2>/dev/null; then
        echo "Restored +x: $dispatcher_dir/$f" >&2
      else
        echo "WARN: failed to chmod +x $dispatcher_dir/$f (read-only?) — skipping" >&2
      fi
    fi
  done
}

# install_per_worktree_pre_push
#
# Calls the per-worktree git pre-push hook installer (closes #65).
# No-op-with-warning if the script is missing. Used by every per-agent
# installer's --git-hook (default-on) path.
install_per_worktree_pre_push() {
  local hooks_dir installer
  hooks_dir="$(dirname "$_LIB_INSTALLER_DIR")/hooks"
  installer="$hooks_dir/install-git-pre-push.sh"
  if [[ -x "$installer" ]]; then
    echo "Installing git-side pre-push hook (#65)..." >&2
    bash "$installer"
  else
    echo "WARN: git-side hook installer not found at: $installer" >&2
    echo "      Skipping. Re-run with --no-git-hook to suppress this warning." >&2
  fi
}
