#!/usr/bin/env bash
# install-project-hooks.sh — generic project-side bootstrap (closes #153).
#
# Why this exists:
#   Consumer projects that bootstrap against autonomous-dev-team symlink
#   the dispatcher's wrapper + lib-*.sh files into <project>/scripts/.
#   Per-file symlink lists drift silently when upstream adds a new file
#   (e.g. lib-review-verdict.sh): autonomous-review.sh source's the
#   missing file via [INV-14]'s BASH_SOURCE[0]-driven SCRIPT_DIR and
#   dies on first source. The dispatcher labels the issue `reviewing`,
#   the agent dies silently, and review hangs for hours.
#
# What this does:
#   1. Symlinks every *.sh from the on-disk autonomous-dispatcher/scripts/
#      into <project>/scripts/. Skips real (non-symlink) project-local
#      files. Idempotent: re-run after `npx skills update` to pick up
#      newly-added upstream files.
#   2. Prunes dangling symlinks under <project>/scripts/ that point into
#      the dispatcher scripts dir. (Removed-upstream cleanup.)
#   3. Symlinks <project>/hooks → autonomous-common/hooks.
#   4. Installs the per-worktree git pre-push hook (#65). Disable with
#      --no-git-hook.
#
# What this does NOT do:
#   - Doesn't touch IDE-specific config (.claude/settings.json, etc.) —
#     that's the per-IDE install-*-hooks.sh's job. Both can run side by
#     side; pre-push is idempotent across the two.
#   - Doesn't symlink autonomous-common/scripts/* (those are reached via
#     .agents/skills/autonomous-common/scripts/... paths directly).
#
# Usage:
#   bash <project>/.agents/skills/autonomous-common/scripts/install-project-hooks.sh
#   bash ... install-project-hooks.sh --no-git-hook   # skip git pre-push step
#
# Idempotent. Safe to re-run on every `npx skills update`.

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

ROOT="$(project_root)"

# Resolve the on-disk autonomous-dispatcher scripts dir and
# autonomous-common hooks dir. Mirrors lib-installer.sh's probe order so
# a consumer with .agents/skills/, .claude/skills/, or vendored skills/
# all bootstrap the same way.
DISPATCHER_DIR=""
HOOKS_DIR=""
for base in \
  "$ROOT/.agents/skills" \
  "$ROOT/.claude/skills" \
  "$ROOT/skills"; do
  if [[ -d "$base/autonomous-dispatcher/scripts" ]]; then
    DISPATCHER_DIR="$base/autonomous-dispatcher/scripts"
    HOOKS_DIR="$base/autonomous-common/hooks"
    break
  fi
done

if [[ -z "$DISPATCHER_DIR" ]]; then
  cat >&2 <<EOF
ERROR: cannot find autonomous-dispatcher skill on disk under:
  $ROOT/.agents/skills/
  $ROOT/.claude/skills/
  $ROOT/skills/

Install the skills first:
  npx skills add zxkane/autonomous-dev-team -a claude-code -y
EOF
  exit 1
fi

# Symlink dispatcher scripts into <project>/scripts/ — file-by-file, so
# project-local files (autonomous.conf, deploy.sh, validators, …) coexist
# with the upstream-managed wrappers.
mkdir -p "$ROOT/scripts"
linked=0
skipped=0
for src in "$DISPATCHER_DIR"/*.sh; do
  [[ -e "$src" ]] || continue   # empty glob guard
  name="$(basename "$src")"
  dst="$ROOT/scripts/$name"

  if [[ -L "$dst" ]]; then
    # Existing symlink: re-point it (handles upstream rename / moved
    # skills root). `ln -sf` to a symlink replaces the link target.
    ln -sf "$src" "$dst"
    linked=$((linked + 1))
  elif [[ -e "$dst" ]]; then
    # Real (non-symlink) file already there — operator owns it. Don't
    # overwrite project-local wrappers / configs.
    skipped=$((skipped + 1))
    echo "Skipped (project-local file exists): scripts/$name" >&2
  else
    ln -s "$src" "$dst"
    linked=$((linked + 1))
  fi
done

# Prune dangling symlinks: any <project>/scripts/*.sh that's a symlink
# whose target is missing AND that target lives in the dispatcher scripts
# dir. Two clauses keep this narrow — we will not delete a project-local
# dangling symlink (which is a different operator problem we shouldn't
# auto-fix here).
pruned=0
for dst in "$ROOT/scripts"/*.sh; do
  [[ -L "$dst" ]] || continue
  target="$(readlink "$dst")"
  # Resolve relative readlinks against the symlink's own dir for the
  # "is in dispatcher dir?" check.
  case "$target" in
    /*) abs_target="$target" ;;
    *)  abs_target="$(dirname "$dst")/$target" ;;
  esac
  if [[ ! -e "$dst" ]] && [[ "$abs_target" == "$DISPATCHER_DIR/"* ]]; then
    rm -f "$dst"
    pruned=$((pruned + 1))
    echo "Pruned dangling symlink: scripts/$(basename "$dst")" >&2
  fi
done

# Symlink the hooks directory. If <project>/hooks already exists as a real
# directory, refuse to shadow it — operator inspection required. An
# existing symlink (correct or stale) is replaced.
if [[ -L "$ROOT/hooks" ]]; then
  ln -sfn "$HOOKS_DIR" "$ROOT/hooks"
elif [[ -e "$ROOT/hooks" ]]; then
  echo "WARN: $ROOT/hooks exists as a real directory; not symlinking." >&2
  echo "      Move or remove it, then re-run." >&2
else
  ln -s "$HOOKS_DIR" "$ROOT/hooks"
fi

echo "Project-side bootstrap: $linked symlinked, $skipped skipped, $pruned pruned." >&2

if (( INSTALL_GIT_HOOK == 1 )); then
  install_per_worktree_pre_push
fi

ensure_dispatcher_scripts_executable

echo "Done. Project-side scripts/ + hooks symlinks are in sync with the installed skills." >&2
