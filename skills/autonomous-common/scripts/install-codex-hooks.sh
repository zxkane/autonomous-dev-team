#!/usr/bin/env bash
# install-codex-hooks.sh — bootstrap project-scoped OpenAI Codex CLI hooks
# from the canonical template.
#
# Codex accepts the same hook event structure as Claude Code, with two
# project-specific adaptations:
#
#   1. Hooks live in `.codex/hooks.json` (NOT `.claude/settings.json`).
#      The file is hooks-only — no other top-level keys.
#   2. The canonical feature key is `[features] hooks = true`.
#
# Codex project hooks and each changed hook definition must be trusted before
# they run. Use /hooks interactively, or --dangerously-bypass-hook-trust only
# in automation that vets the installed hook source independently.
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

require_tomllib() {
  if ! command -v python3 >/dev/null 2>&1 ||
     ! python3 -c 'import tomllib' >/dev/null 2>&1; then
    echo "ERROR: Python 3.11+ with the standard-library tomllib module is required." >&2
    exit 1
  fi
}

require_tomllib

TEMPLATE="$SCRIPT_DIR/claude-settings.template.json"
if [[ ! -f "$TEMPLATE" ]]; then
  echo "ERROR: canonical template not found at: $TEMPLATE" >&2
  exit 1
fi

project_dir="$(project_root)"
target_dir="$project_dir/.codex"
target="$target_dir/hooks.json"
config_toml="$target_dir/config.toml"
target_display="$target"
config_display="$config_toml"

if [[ -L "$target_dir" ]]; then
  echo "ERROR: refusing to install through symbolic-link directory: $target_dir" >&2
  exit 1
fi
if [[ -e "$target_dir" && ! -d "$target_dir" ]]; then
  echo "ERROR: Codex config path exists but is not a directory: $target_dir" >&2
  exit 1
fi
if [[ ! -d "$target_dir" ]] && ! (umask 077; mkdir -p "$target_dir"); then
  echo "ERROR: could not create private Codex config directory: $target_dir" >&2
  exit 1
fi

_require_regular_destination() {
  local path="$1"
  if [[ -L "$path" ]]; then
    echo "ERROR: refusing to replace symbolic-link destination: $path" >&2
    return 1
  fi
  if [[ -e "$path" && ! -f "$path" ]]; then
    echo "ERROR: destination exists but is not a regular file: $path" >&2
    return 1
  fi
}

# Parse the complete TOML document before making any textual change. Python's
# standard-library parser catches quoted/dotted keys, arrays of tables,
# multiline strings, and duplicate definitions that a line parser cannot.
_analyze_codex_config() {
  python3 - "$1" "${2:-$1}" <<'PY'
import json
import sys
import tomllib

path = sys.argv[1]
display_path = sys.argv[2]
try:
    with open(path, "rb") as stream:
        config = tomllib.load(stream)
except (OSError, tomllib.TOMLDecodeError) as exc:
    print(f"ERROR: cannot parse {display_path}: {exc}", file=sys.stderr)
    raise SystemExit(1)

if "features" not in config:
    print(json.dumps({"features_present": False, "hooks": None, "codex_hooks": None}))
    raise SystemExit(0)

features = config["features"]
if not isinstance(features, dict):
    print(f"ERROR: {display_path} must define features as a TOML table", file=sys.stderr)
    raise SystemExit(1)

values = {}
for key in ("hooks", "codex_hooks"):
    value = features.get(key)
    if value is not None and type(value) is not bool:
        print(f"ERROR: [features].{key} must be boolean in {display_path}", file=sys.stderr)
        raise SystemExit(1)
    values[key] = value

print(json.dumps({"features_present": True, **values}))
PY
}

_canonical_line_count() {
  local file="$1" kind="$2" pattern
  case "$kind" in
    header) pattern='^[[:space:]]*\[[[:space:]]*features[[:space:]]*\][[:space:]]*(#.*)?$' ;;
    legacy) pattern='^[[:space:]]*codex_hooks[[:space:]]*=[[:space:]]*(true|false)[[:space:]]*(#.*)?$' ;;
    *) return 2 ;;
  esac
  # grep -c prints the desired zero count but exits 1 when no line matches.
  grep -cE "$pattern" "$file" 2>/dev/null || true
}

# Comment-preserving edits are intentionally limited to one ordinary
# [features] table with bare keys. tomllib still validates every other shape;
# valid but noncanonical forms are refused rather than rewritten unsafely.
_require_mutable_feature_table() {
  local file="$1" require_legacy="${2:-0}" display_file="${3:-$1}"
  local header_count legacy_count

  if grep -qE "'''|\"\"\"" "$file"; then
    echo "ERROR: $display_file uses multiline TOML strings; automatic [features] edits are disabled." >&2
    return 1
  fi
  header_count=$(_canonical_line_count "$file" "header")
  if (( header_count != 1 )); then
    echo "ERROR: $display_file does not use one canonical [features] table." >&2
    echo "       Normalize that table to a bare [features] header, then re-run." >&2
    return 1
  fi

  if (( require_legacy == 1 )); then
    legacy_count=$(_canonical_line_count "$file" "legacy")
    if (( legacy_count != 1 )); then
      echo "ERROR: $display_file uses a noncanonical codex_hooks key representation." >&2
      echo "       Replace it with a bare boolean key in [features], then re-run." >&2
      return 1
    fi
  fi
}

_rewrite_staged_config() {
  local file="$1" action="$2"
  local tmp
  tmp=$(mktemp "${file}.next.XXXXXX")

  if ! awk -v action="$action" '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    {
      raw = $0

      # Recognize table headers before removing comments: a quoted table
      # component may itself contain "#".
      header = trim(raw)
      if (header ~ /^\[\[.*\]\][[:space:]]*(#.*)?$/) {
        section = "other"
        print raw
        next
      }
      if (header ~ /^\[.*\][[:space:]]*(#.*)?$/) {
        section = (header ~ /^\[[[:space:]]*features[[:space:]]*\][[:space:]]*(#.*)?$/) ? "features" : "other"
        print raw
        if (section == "features" && action == "insert") {
          print "hooks = true  # added by install-codex-hooks.sh"
        }
        next
      }

      comparable = raw
      sub(/[[:space:]]*#.*/, "", comparable)
      comparable = trim(comparable)

      if (section == "features" &&
          comparable ~ /^codex_hooks[[:space:]]*=/) {
        if (action == "migrate") {
          sub(/codex_hooks/, "hooks", raw)
          print raw
        } else if (action != "drop-legacy") {
          print raw
        }
        next
      }

      print raw
    }
    END {
      if (action == "append") {
        print ""
        print "# Added by install-codex-hooks.sh."
        print "[features]"
        print "hooks = true"
      }
    }
  ' "$file" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  # Keep the staged file's mode; replacing it with the umask-created temp file
  # could widen permissions inherited from a private config.
  if ! cat "$tmp" > "$file"; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

_stage_codex_config() {
  local file="$1" staged="$2" display_file="${3:-$1}"

  if [[ ! -f "$file" ]]; then
    cat > "$staged" <<'EOF'
# Created by install-codex-hooks.sh.
[features]
hooks = true
EOF
    _analyze_codex_config "$staged" >/dev/null
    return 0
  fi

  local analysis features_present canonical legacy
  if ! analysis=$(_analyze_codex_config "$file" "$display_file"); then
    return 1
  fi
  features_present=$(jq -r '.features_present' <<<"$analysis")
  canonical=$(jq -r 'if .hooks == null then "" else (.hooks | tostring) end' <<<"$analysis")
  legacy=$(jq -r 'if .codex_hooks == null then "" else (.codex_hooks | tostring) end' <<<"$analysis")

  if [[ -n "$canonical" && -n "$legacy" && "$canonical" != "$legacy" ]]; then
    echo "ERROR: $display_file has conflicting hooks=$canonical and codex_hooks=$legacy." >&2
    echo "       Resolve the conflict explicitly, then re-run." >&2
    return 1
  fi

  if [[ "$canonical" == "false" || "$legacy" == "false" ]]; then
    echo "ERROR: $display_file explicitly disables Codex hooks." >&2
    echo "       Preserve that choice, or set the relevant feature key to true and re-run." >&2
    return 1
  fi

  cp -p "$file" "$staged"

  if [[ "$canonical" == "true" && "$legacy" == "true" ]]; then
    _require_mutable_feature_table "$file" 1 "$display_file" || return 1
    _rewrite_staged_config "$staged" "drop-legacy"
  elif [[ "$legacy" == "true" ]]; then
    _require_mutable_feature_table "$file" 1 "$display_file" || return 1
    _rewrite_staged_config "$staged" "migrate"
  elif [[ "$canonical" == "true" ]]; then
    :
  elif [[ "$features_present" == "true" ]]; then
    _require_mutable_feature_table "$file" 0 "$display_file" || return 1
    _rewrite_staged_config "$staged" "insert"
  else
    _rewrite_staged_config "$staged" "append"
  fi

  local staged_analysis
  if ! staged_analysis=$(_analyze_codex_config "$staged" "$display_file") ||
     ! jq -e '
       .features_present == true
       and .hooks == true
       and .codex_hooks == null
     ' <<<"$staged_analysis" >/dev/null; then
    echo "ERROR: could not safely canonicalize [features].hooks in $display_file" >&2
    return 1
  fi
}

render_codex_hooks() {
  local template="$1" output="$2"
  # Codex's hooks-config parser is strict: top-level keys are limited to
  # `description` and `hooks`. Provenance therefore rides in `description`
  # instead of the `_managed_by`/`_managed_note` markers other installers
  # extract from the canonical template (issue #501).
  if ! jq '
    del(._managed_by, ._managed_note)
    | .description = "Managed by skills/autonomous-common/scripts/install-codex-hooks.sh — hand-edits are overwritten on the next install."
    | .hooks.PreToolUse as $pre
    | ([
        $pre[]
        | select(.matcher == "Write" or .matcher == "Edit")
        | .hooks[]
      ] | unique_by(.command)) as $edit_hooks
    | .hooks.PreToolUse = (
        [$pre[] | select(.matcher != "Write" and .matcher != "Edit")]
        + (if ($edit_hooks | length) > 0
           then [{matcher: "^apply_patch$", hooks: $edit_hooks}]
           else []
           end)
      )
    | (.hooks[][] | .hooks[] | .command) |=
        sub("^\"\\$CLAUDE_PROJECT_DIR\"/hooks/";
            "\"$(git rev-parse --show-toplevel)\"/hooks/")
  ' "$template" > "$output"; then
    echo "ERROR: failed to render Codex hook configuration" >&2
    return 1
  fi

  if ! jq -e '
    ([.hooks.PreToolUse[] | select(.matcher == "^apply_patch$")] | length == 1)
    and ([.. | strings | select(contains("$CLAUDE_PROJECT_DIR"))] | length == 0)
    and ((keys | sort) == ["description", "hooks"])
  ' "$output" >/dev/null; then
    echo "ERROR: rendered Codex hooks failed validation" >&2
    return 1
  fi
}

_CODEX_TXN_ACTIVE=0
_CODEX_TXN_CONFIG_CHANGED=0
_CODEX_TXN_CONFIG_EXISTED=0
_CODEX_TXN_CONFIG_BACKUP=""
_CODEX_TXN_CONFIG_CAPTURED=0
_CODEX_TXN_CONFIG_ORIGINAL=""
_CODEX_TXN_CONFIG_PATH=""
_CODEX_TXN_HOOKS_CHANGED=0
_CODEX_TXN_HOOKS_EXISTED=0
_CODEX_TXN_HOOKS_BACKUP=""
_CODEX_TXN_HOOKS_CAPTURED=0
_CODEX_TXN_HOOKS_ORIGINAL=""
_CODEX_TXN_HOOKS_PATH=""
_CODEX_TXN_PENDING_CONFIG=""
_CODEX_TXN_PENDING_HOOKS=""
_CODEX_TXN_STAGED_CONFIG=""
_CODEX_TXN_STAGED_HOOKS=""
_CODEX_TXN_REPLACEMENTS_STARTED=0
_CODEX_TARGET_DIR_ID=""
_CODEX_TARGET_DIR_PATH=""

_place_codex_path_no_clobber() {
  local source="$1" destination="$2" expected_identity="${3:-}"

  # link(2) and symlink(2) address the exact destination and fail if any path
  # already exists there. Unlike `mv -n`, they never reinterpret a concurrent
  # directory as a container for the source. Capture callers also pass the
  # inode observed before entering this helper so a raced symlink or file is
  # rejected before it can be linked and unlinked.
  CODEX_ATOMIC_PLACE=1 python3 - \
    "$source" "$destination" "$expected_identity" <<'PY'
import os
import stat
import sys

source, destination, expected_identity = sys.argv[1:]
try:
    source_stat = os.lstat(source)
    mode = source_stat.st_mode
    if expected_identity:
        actual_identity = f"{source_stat.st_dev}:{source_stat.st_ino}"
        if actual_identity != expected_identity or not stat.S_ISREG(mode):
            raise OSError("source changed before capture")
    if stat.S_ISREG(mode):
        os.link(source, destination, follow_symlinks=False)
    elif stat.S_ISLNK(mode):
        os.symlink(os.readlink(source), destination)
    else:
        raise OSError("unsupported source type")
    if expected_identity:
        linked_stat = os.lstat(destination)
        active_stat = os.lstat(source)
        linked_identity = f"{linked_stat.st_dev}:{linked_stat.st_ino}"
        active_identity = f"{active_stat.st_dev}:{active_stat.st_ino}"
        if linked_identity != expected_identity or active_identity != expected_identity:
            raise OSError("source changed during capture")
    os.unlink(source)
except OSError:
    raise SystemExit(1)
PY
}

_capture_codex_destination() {
  local path="$1" backup="$2" expected="$3" captured_var="$4"
  local source_identity

  source_identity=$(_file_identity "$path") || return 1
  if _place_codex_path_no_clobber "$path" "$backup" "$source_identity"; then
    :
  else
    # The helper status is intentionally reconciled from inode postconditions.
    :
  fi

  # Reconcile ambiguous helper failures from signals after link/unlink. The
  # backup is ours only when it has the inode observed at the source path.
  if ! _path_has_identity "$backup" "$source_identity"; then
    return 1
  fi
  printf -v "$captured_var" '%s' 1

  if ! _destination_matches_snapshot "$backup" "$expected" 1; then
    return 1
  fi
  if _path_has_identity "$path" "$source_identity"; then
    # link(2) completed but unlink(2) did not. Keep both names and abort; the
    # rollback path sees the original still active and leaves it untouched.
    return 1
  fi

  # A nonzero helper status is safe to accept once the complete postcondition
  # proves that the original inode is captured and no longer active.
  return 0
}

_restore_codex_destination() {
  local backup="$1" path="$2"
  local restore_tmp

  if ! restore_tmp=$(mktemp "${path}.rollback.XXXXXX"); then
    return 1
  fi

  if ! cp -p "$backup" "$restore_tmp"; then
    rm -f "$restore_tmp"
    return 1
  fi
  if ! _place_codex_path_no_clobber "$restore_tmp" "$path"; then
    rm -f "$restore_tmp"
    return 1
  fi
}

_remove_codex_destination_if_installed() {
  local path="$1" installed="$2"
  local captured path_identity place_rc=0 captured_by_us=0

  if ! captured=$(mktemp "${path}.rollback-current.XXXXXX"); then
    return 1
  fi
  rm -f "$captured"

  if ! _destination_matches_snapshot "$path" "$installed" 1; then
    return 1
  fi
  path_identity=$(_file_identity "$path") || return 1
  _place_codex_path_no_clobber "$path" "$captured" || place_rc=$?

  if (( place_rc == 0 )) ||
     _path_has_identity "$captured" "$path_identity"; then
    captured_by_us=1
  fi
  (( captured_by_us == 1 )) || return 1

  if _path_has_identity "$path" "$path_identity"; then
    return 1
  fi
  if _destination_matches_snapshot "$captured" "$installed" 1; then
    rm -f "$captured"
    return 0
  fi

  if ! _place_codex_path_no_clobber "$captured" "$path"; then
    echo "ERROR: could not restore concurrent content at $path" >&2
  fi
  return 1
}

_rollback_codex_destination() {
  local path="$1" original="$2" existed="$3" installed="$4"
  local backup="$5" captured="$6"

  if (( existed == 1 )); then
    if _destination_matches_snapshot "$path" "$original" 1; then
      return 0
    fi
    # A signal can run the trap after atomic capture completes but before the
    # shell records its flag. Reconcile that ambiguous state from the backup.
    if (( captured == 0 )) && [[ -n "$backup" ]] &&
       _destination_matches_snapshot "$backup" "$original" 1; then
      captured=1
    fi
    if (( captured == 0 )); then
      echo "ERROR: refusing to overwrite a concurrent edit at $path during rollback" >&2
      return 1
    fi

    if [[ -e "$path" || -L "$path" ]] &&
       ! _remove_codex_destination_if_installed "$path" "$installed"; then
      echo "ERROR: refusing to overwrite a concurrent edit at $path during rollback" >&2
      return 1
    fi
    _restore_codex_destination "$backup" "$path"
    return
  fi

  if [[ ! -e "$path" && ! -L "$path" ]]; then
    return 0
  fi
  if ! _remove_codex_destination_if_installed "$path" "$installed"; then
    echo "ERROR: refusing to remove a concurrent file at $path during rollback" >&2
    return 1
  fi
}

_rollback_codex_transaction() {
  (( _CODEX_TXN_ACTIVE == 1 )) || return 0
  local rollback_failed=0
  trap '' HUP INT TERM

  rm -f "$_CODEX_TXN_PENDING_CONFIG" "$_CODEX_TXN_PENDING_HOOKS"

  if (( _CODEX_TXN_REPLACEMENTS_STARTED == 1 )); then
    # Reverse installation order: disable/restore config before replacing the
    # hook definitions it selects.
    if (( _CODEX_TXN_CONFIG_CHANGED == 1 )) &&
       ! _rollback_codex_destination \
         "$_CODEX_TXN_CONFIG_PATH" "$_CODEX_TXN_CONFIG_ORIGINAL" \
         "$_CODEX_TXN_CONFIG_EXISTED" "$_CODEX_TXN_STAGED_CONFIG" \
         "$_CODEX_TXN_CONFIG_BACKUP" "$_CODEX_TXN_CONFIG_CAPTURED"; then
      echo "ERROR: failed to restore $_CODEX_TXN_CONFIG_PATH" >&2
      rollback_failed=1
    fi

    if (( _CODEX_TXN_HOOKS_CHANGED == 1 )) &&
       ! _rollback_codex_destination \
         "$_CODEX_TXN_HOOKS_PATH" "$_CODEX_TXN_HOOKS_ORIGINAL" \
         "$_CODEX_TXN_HOOKS_EXISTED" "$_CODEX_TXN_STAGED_HOOKS" \
         "$_CODEX_TXN_HOOKS_BACKUP" "$_CODEX_TXN_HOOKS_CAPTURED"; then
      echo "ERROR: failed to restore $_CODEX_TXN_HOOKS_PATH" >&2
      rollback_failed=1
    fi
  fi

  _CODEX_TXN_ACTIVE=0
  return "$rollback_failed"
}

_cancel_codex_transaction() {
  local rollback_failed=0
  trap '' HUP INT TERM
  if ! _rollback_codex_transaction; then
    rollback_failed=1
  fi
  trap - HUP INT TERM
  return "$rollback_failed"
}

_abort_codex_transaction() {
  local exit_code="$1"
  trap '' HUP INT TERM
  echo "ERROR: hook installation interrupted; rolling back config and hooks" >&2
  if ! _rollback_codex_transaction; then
    echo "ERROR: interrupted installation could not be fully rolled back" >&2
  fi
  exit "$exit_code"
}

_file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

_file_identity() {
  stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null
}

_path_has_identity() {
  local path="$1" identity="$2" actual
  [[ -e "$path" || -L "$path" ]] || return 1
  actual=$(_file_identity "$path") || return 1
  [[ "$actual" == "$identity" ]]
}

_codex_target_dir_is_current() {
  [[ -n "$_CODEX_TARGET_DIR_PATH" && -n "$_CODEX_TARGET_DIR_ID" ]] &&
    [[ ! -L "$_CODEX_TARGET_DIR_PATH" ]] &&
    _path_has_identity "$_CODEX_TARGET_DIR_PATH" "$_CODEX_TARGET_DIR_ID"
}

_destination_matches_snapshot() {
  local path="$1" snapshot="$2" existed="$3"
  if (( existed == 1 )); then
    [[ -f "$path" && ! -L "$path" ]] &&
      cmp -s "$snapshot" "$path" &&
      [[ "$(_file_mode "$snapshot")" == "$(_file_mode "$path")" ]]
  else
    [[ ! -e "$path" && ! -L "$path" ]]
  fi
}

_commit_codex_files() {
  local staged_config="$1" config="$2" staged_hooks="$3" hooks="$4"
  local expected_config="$5" config_existed="$6"
  local expected_hooks="$7" hooks_existed="$8"
  local config_changed=1 hooks_changed=1
  local config_backup="" hooks_backup=""
  local pending_config="" pending_hooks=""

  (( config_existed == 1 )) &&
    cmp -s "$staged_config" "$expected_config" &&
    config_changed=0
  (( hooks_existed == 1 )) &&
    cmp -s "$staged_hooks" "$expected_hooks" &&
    hooks_changed=0

  if ! _codex_target_dir_is_current ||
     ! _destination_matches_snapshot "$config" "$expected_config" "$config_existed" ||
     ! _destination_matches_snapshot "$hooks" "$expected_hooks" "$hooks_existed"; then
    echo "ERROR: Codex config changed while hooks were being rendered; refusing to overwrite it." >&2
    return 1
  fi

  _CODEX_TXN_ACTIVE=1
  _CODEX_TXN_CONFIG_CHANGED=$config_changed
  _CODEX_TXN_CONFIG_EXISTED=$config_existed
  _CODEX_TXN_CONFIG_CAPTURED=0
  _CODEX_TXN_CONFIG_ORIGINAL=$expected_config
  _CODEX_TXN_CONFIG_PATH=$config
  _CODEX_TXN_HOOKS_CHANGED=$hooks_changed
  _CODEX_TXN_HOOKS_EXISTED=$hooks_existed
  _CODEX_TXN_HOOKS_CAPTURED=0
  _CODEX_TXN_HOOKS_ORIGINAL=$expected_hooks
  _CODEX_TXN_HOOKS_PATH=$hooks
  _CODEX_TXN_PENDING_CONFIG=$pending_config
  _CODEX_TXN_PENDING_HOOKS=$pending_hooks
  _CODEX_TXN_STAGED_CONFIG=$staged_config
  _CODEX_TXN_STAGED_HOOKS=$staged_hooks
  _CODEX_TXN_REPLACEMENTS_STARTED=0
  trap '_abort_codex_transaction 129' HUP
  trap '_abort_codex_transaction 130' INT
  trap '_abort_codex_transaction 143' TERM

  # Copy across filesystem boundaries before touching either destination.
  # The final hard-link placements stay within target_dir, so each individual
  # replacement is atomic. mktemp prevents pre-planted scratch symlinks.
  if (( config_changed == 1 )); then
    if ! pending_config=$(mktemp "${config}.pending.XXXXXX"); then
      echo "ERROR: failed to stage $config" >&2
      _cancel_codex_transaction
      return 1
    fi
    _CODEX_TXN_PENDING_CONFIG=$pending_config
    if ! cp -p "$staged_config" "$pending_config"; then
      echo "ERROR: failed to stage $config" >&2
      _cancel_codex_transaction
      return 1
    fi
  fi
  if (( hooks_changed == 1 )); then
    if ! pending_hooks=$(mktemp "${hooks}.pending.XXXXXX"); then
      echo "ERROR: failed to stage $hooks" >&2
      _cancel_codex_transaction
      return 1
    fi
    _CODEX_TXN_PENDING_HOOKS=$pending_hooks
    if ! cp -p "$staged_hooks" "$pending_hooks"; then
      echo "ERROR: failed to stage $hooks" >&2
      _cancel_codex_transaction
      return 1
    fi
  fi

  if (( config_changed == 1 )) && [[ -f "$config" ]]; then
    if ! config_backup=$(mktemp "${config}.bak.$(date +%s).XXXXXX"); then
      echo "ERROR: failed to allocate backup for $config" >&2
      _cancel_codex_transaction
      return 1
    fi
    rm -f "$config_backup"
    _CODEX_TXN_CONFIG_BACKUP=$config_backup
  fi
  if (( hooks_changed == 1 )) && [[ -f "$hooks" ]]; then
    if ! hooks_backup=$(mktemp "${hooks}.bak.$(date +%s).XXXXXX"); then
      echo "ERROR: failed to allocate backup for $hooks" >&2
      _cancel_codex_transaction
      return 1
    fi
    rm -f "$hooks_backup"
    _CODEX_TXN_HOOKS_BACKUP=$hooks_backup
  fi

  if ! _codex_target_dir_is_current ||
     ! _destination_matches_snapshot "$config" "$expected_config" "$config_existed" ||
     ! _destination_matches_snapshot "$hooks" "$expected_hooks" "$hooks_existed"; then
    echo "ERROR: Codex config changed before replacement; refusing to overwrite it." >&2
    _cancel_codex_transaction
    return 1
  fi

  _CODEX_TXN_REPLACEMENTS_STARTED=1

  # Install definitions before enabling them. An uncatchable process death
  # between the two placements can leave new hooks disabled, never stale hooks
  # newly enabled.
  if ! _destination_matches_snapshot "$hooks" "$expected_hooks" "$hooks_existed"; then
    echo "ERROR: $hooks changed immediately before replacement; refusing to overwrite it." >&2
    _cancel_codex_transaction
    return 1
  fi
  if (( hooks_changed == 1 )); then
    if (( hooks_existed == 1 )); then
      if ! _capture_codex_destination \
        "$hooks" "$hooks_backup" "$expected_hooks" \
        _CODEX_TXN_HOOKS_CAPTURED; then
        echo "ERROR: $hooks changed during atomic capture; refusing to overwrite it." >&2
        if ! _rollback_codex_transaction; then
          echo "ERROR: failed hooks capture could not be fully rolled back" >&2
        fi
        trap - HUP INT TERM
        return 1
      fi
    fi
    if ! _place_codex_path_no_clobber "$pending_hooks" "$hooks"; then
      echo "ERROR: failed to install $hooks without overwriting concurrent content" >&2
      if ! _rollback_codex_transaction; then
        echo "ERROR: failed hooks installation could not be fully rolled back" >&2
      fi
      trap - HUP INT TERM
      rm -f "$pending_config" "$pending_hooks"
      return 1
    fi
  fi

  if ! _destination_matches_snapshot "$config" "$expected_config" "$config_existed"; then
    echo "ERROR: $config changed immediately before replacement; rolling back hooks." >&2
    _cancel_codex_transaction
    return 1
  fi
  if (( config_changed == 1 )); then
    if (( config_existed == 1 )); then
      if ! _capture_codex_destination \
        "$config" "$config_backup" "$expected_config" \
        _CODEX_TXN_CONFIG_CAPTURED; then
        echo "ERROR: $config changed during atomic capture; rolling back hooks." >&2
        if ! _rollback_codex_transaction; then
          echo "ERROR: failed config capture could not be fully rolled back" >&2
        fi
        trap - HUP INT TERM
        return 1
      fi
    fi
    if ! _place_codex_path_no_clobber "$pending_config" "$config"; then
      echo "ERROR: failed to install $config without overwriting concurrent content" >&2
      if ! _rollback_codex_transaction; then
        echo "ERROR: failed config installation could not be fully rolled back" >&2
      fi
      trap - HUP INT TERM
      rm -f "$pending_config" "$pending_hooks"
      return 1
    fi
  fi

  if ! _codex_target_dir_is_current; then
    echo "ERROR: Codex config directory changed during installation; rolling back." >&2
    _cancel_codex_transaction
    return 1
  fi
  trap - HUP INT TERM
  _CODEX_TXN_ACTIVE=0
  rm -f "$pending_config" "$pending_hooks"

  if (( config_changed == 1 )); then
    if [[ -n "$config_backup" ]]; then
      echo "Updated: $config (backup at $config_backup)" >&2
    else
      echo "Created: $config" >&2
    fi
  else
    echo "Note: Codex feature config already current in $config" >&2
  fi

  if (( hooks_changed == 1 )); then
    if [[ -n "$hooks_backup" ]]; then
      echo "Updated: $hooks (backup at $hooks_backup)" >&2
    else
      echo "Created: $hooks" >&2
    fi
  else
    echo "Note: Codex hooks already current in $hooks" >&2
  fi
}

if ! cd -P "$target_dir"; then
  echo "ERROR: could not enter Codex config directory: $target_dir" >&2
  exit 1
fi
_CODEX_TARGET_DIR_PATH=$target_dir
_CODEX_TARGET_DIR_ID=$(_file_identity .) || {
  echo "ERROR: could not identify Codex config directory: $target_dir" >&2
  exit 1
}
target="hooks.json"
config_toml="config.toml"

_codex_target_dir_is_current || {
  echo "ERROR: Codex config directory changed before installation: $target_dir" >&2
  exit 1
}
_require_regular_destination "$config_toml" || exit 1
_require_regular_destination "$target" || exit 1

staged_config=$(mktemp)
staged_hooks=$(mktemp)
original_config=$(mktemp)
original_hooks=$(mktemp)
rm -f "$original_config" "$original_hooks"
trap 'rm -f "$staged_config" "$staged_hooks" "$original_config" "$original_hooks"' EXIT

config_existed=0
hooks_existed=0
if [[ -f "$config_toml" ]]; then
  cp -p "$config_toml" "$original_config"
  config_existed=1
fi
if [[ -f "$target" ]]; then
  cp -p "$target" "$original_hooks"
  cp -p "$original_hooks" "$staged_hooks"
  hooks_existed=1
fi

_stage_codex_config "$original_config" "$staged_config" "$config_display" || exit 1
render_codex_hooks "$TEMPLATE" "$staged_hooks" || exit 1
_commit_codex_files \
  "$staged_config" "$config_toml" "$staged_hooks" "$target" \
  "$original_config" "$config_existed" "$original_hooks" "$hooks_existed" ||
  exit 1

rm -f "$staged_config" "$staged_hooks" "$original_config" "$original_hooks"
trap - EXIT

cd "$project_dir"

if (( INSTALL_GIT_HOOK == 1 )); then
  install_per_worktree_pre_push
fi

ensure_dispatcher_scripts_executable

cat <<'EOF' >&2

NOTE: Codex project hooks run only after the project and current hook
definitions are trusted. Review them with /hooks. For vetted unattended
automation, Codex also provides --dangerously-bypass-hook-trust.

EOF
echo "Done. Project-scoped Codex hooks installed at $target_display." >&2
