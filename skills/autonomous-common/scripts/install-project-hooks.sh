#!/usr/bin/env bash
# install-project-hooks.sh — generic project-side bootstrap (closes #153; #227).
#
# Why this exists:
#   Consumer projects that bootstrap against autonomous-dev-team symlink the
#   dispatcher's STABLE ENTRY scripts + agent-callable utilities into
#   <project>/scripts/. As of #227 ([INV-65]), the wrapper/dispatcher entry
#   scripts source their sibling lib-*.sh from the REAL skill tree (resolved
#   via `readlink -f`), NOT from <project>/scripts/. That structurally removes
#   the missing-lib-symlink crash class: an upstream PR can add/remove a
#   lib-*.sh and NO consumer re-run is required for lib sourcing to keep
#   working.
#
# What this does:
#   1. Symlinks every STABLE ENTRY *.sh (everything that is NOT `lib-*.sh` and
#      NOT `*-aws-ssm.sh`) from the on-disk autonomous-dispatcher/scripts/ into
#      <project>/scripts/. Skips real (non-symlink) project-local files. Idempotent.
#   2. Prunes (a) dangling symlinks into the dispatcher dir, AND (b) stale
#      non-manifest symlinks (`scripts/lib-*.sh` and `scripts/*-aws-ssm.sh`)
#      that a pre-#227 installer created and that are now dead weight (lib
#      sourcing no longer reads them; the SSM helpers run from the skill tree).
#   3. Symlinks <project>/hooks → autonomous-common/hooks.
#   4. Installs the per-worktree git pre-push hook (#65). Disable with
#      --no-git-hook.
#
# Modes:
#   (default)    apply the changes above.
#   --dry-run    print every planned create / repoint / prune WITHOUT touching
#                the filesystem. Exits 0.
#   --doctor     read-only health report: broken/missing entry symlinks,
#                stale non-manifest symlinks, conf presence + permissions, and
#                entry resolution sanity (does the real skill tree hold
#                lib-config.sh?). Exits 0 when clean, 1 when problems are found.
#
# What this does NOT do:
#   - Doesn't symlink lib-*.sh or *-aws-ssm.sh (lib-*.sh resolve from the skill
#     tree via [INV-65]; the SSM helpers run from the skill tree, #227 P1).
#   - Doesn't touch IDE-specific config (.claude/settings.json, etc.).
#   - Doesn't symlink autonomous-common/scripts/* (reached via .agents paths).
#
# Usage:
#   bash <project>/.agents/skills/autonomous-common/scripts/install-project-hooks.sh
#   bash ... install-project-hooks.sh --no-git-hook
#   bash ... install-project-hooks.sh --dry-run
#   bash ... install-project-hooks.sh --doctor
#
# Idempotent. Safe to re-run on every `npx skills update`.

set -euo pipefail

INSTALL_GIT_HOOK=1
DRY_RUN=0
DOCTOR=0
for arg in "$@"; do
  case "$arg" in
    --no-git-hook) INSTALL_GIT_HOOK=0 ;;
    --dry-run)     DRY_RUN=1 ;;
    --doctor)      DOCTOR=1 ;;
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

# is_entry_script <basename> — true when the script is a STABLE ENTRY point /
# agent-callable utility that the project must symlink. The manifest is the
# rule "everything that is NOT lib-*.sh, EXCEPT the *-aws-ssm.sh helpers":
# new entry points auto-symlink, new lib-*.sh auto-skip (they resolve from the
# skill tree via [INV-65]). Keeping it a rule rather than a hand-maintained
# list means the manifest can never drift behind an upstream addition.
#
# The two *-aws-ssm.sh helpers (dispatch-remote-aws-ssm.sh,
# liveness-check-remote-aws-ssm.sh) are EXCLUDED (#227 P1): they source their
# shared lib-ssm.sh from their OWN unresolved dir (readlink-free, for the
# PATH-scrubbed TC-EB-008), so a project-side symlink to them would resolve
# lib-ssm.sh in <project>/scripts/ — which is now absent (lib-*.sh aren't
# symlinked) — and crash on `bash scripts/dispatch-remote-aws-ssm.sh` with
# `lib-ssm.sh: No such file or directory`. They are dispatcher-host-internal,
# never agent-callable, and the dispatcher invokes them from the REAL skill tree
# (dispatcher-tick.sh's dispatch() via LIB_DIR; liveness via lib-dispatch.sh's
# skill-tree BASH_SOURCE), so they need NO project-side symlink. The prune loop
# below removes any pre-#227 project-side symlink to them.
is_entry_script() {
  case "$1" in
    lib-*.sh)        return 1 ;;
    *-aws-ssm.sh)    return 1 ;;
    *.sh)            return 0 ;;
    *)               return 1 ;;
  esac
}

# symlink_into_dispatcher_dir <symlink-path> — true when <symlink-path> is a
# symlink whose target (resolved against the link's own dir when relative)
# lives in $DISPATCHER_DIR. Both the --doctor scan and the prune loop need
# this exact "is this one of our managed symlinks?" test, so it's factored
# out to keep the relative-readlink resolution defined once.
symlink_into_dispatcher_dir() {
  local dst="$1" target abs_target
  [[ -L "$dst" ]] || return 1
  target="$(readlink "$dst")"
  case "$target" in
    /*) abs_target="$target" ;;
    *)  abs_target="$(dirname "$dst")/$target" ;;
  esac
  [[ "$abs_target" == "$DISPATCHER_DIR/"* ]]
}

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

# ---------------------------------------------------------------------------
# --doctor — read-only health report. No filesystem mutation.
# ---------------------------------------------------------------------------
if (( DOCTOR == 1 )); then
  problems=0
  echo "install-project-hooks --doctor"
  echo "  project root:    $ROOT"
  echo "  dispatcher dir:  $DISPATCHER_DIR"

  # Entry-resolution sanity: the real skill tree must hold lib-config.sh, the
  # first sibling every entry sources. If it's missing the install is broken
  # regardless of symlinks.
  if [[ -f "$DISPATCHER_DIR/lib-config.sh" ]]; then
    echo "  [ok] skill tree has lib-config.sh (entry lib resolution will work)"
  else
    echo "  [FAIL] skill tree is MISSING lib-config.sh — entries cannot source siblings"
    problems=$((problems + 1))
  fi

  # Entry symlinks: each entry script should be a symlink into the dispatcher dir.
  for src in "$DISPATCHER_DIR"/*.sh; do
    [[ -e "$src" ]] || continue
    name="$(basename "$src")"
    is_entry_script "$name" || continue
    dst="$ROOT/scripts/$name"
    if [[ -L "$dst" ]]; then
      if [[ -e "$dst" ]]; then
        :  # present + resolves — fine, stay quiet to keep output scannable
      else
        echo "  [FAIL] broken entry symlink: scripts/$name → $(readlink "$dst")"
        problems=$((problems + 1))
      fi
    elif [[ -e "$dst" ]]; then
      echo "  [warn] scripts/$name is a real file (project-local override), not a managed symlink"
    else
      echo "  [FAIL] missing entry symlink: scripts/$name (run the installer)"
      problems=$((problems + 1))
    fi
  done

  # Project-side scan: catch broken symlinks into the dispatcher dir whose
  # upstream target was removed (the entry-scan above only visits scripts that
  # STILL exist upstream, so a dangling link to a deleted entry needs its own
  # pass), and report stale non-manifest symlinks (lib-*.sh or *-aws-ssm.sh —
  # should NOT exist post-#227; `is_entry_script` is the single source of truth
  # for what belongs project-side, matching the prune loop).
  if [[ -d "$ROOT/scripts" ]]; then
    for dst in "$ROOT/scripts"/*.sh; do
      symlink_into_dispatcher_dir "$dst" || continue
      name="$(basename "$dst")"
      if [[ ! -e "$dst" ]]; then
        echo "  [FAIL] broken symlink (upstream target gone): scripts/$name → $(readlink "$dst")"
        problems=$((problems + 1))
      elif ! is_entry_script "$name"; then
        echo "  [warn] stale non-manifest symlink: scripts/$name (run the installer to prune)"
      fi
    done
  fi

  # Conf presence + permissions.
  conf="$ROOT/scripts/autonomous.conf"
  if [[ -f "$conf" ]]; then
    mode="$(stat -c '%a' "$conf" 2>/dev/null || stat -f '%Lp' "$conf" 2>/dev/null || echo '???')"
    if [[ "$mode" == "600" ]]; then
      echo "  [ok] scripts/autonomous.conf present (mode $mode)"
    else
      echo "  [warn] scripts/autonomous.conf present but mode is $mode (expected 600)"
    fi
  else
    echo "  [FAIL] scripts/autonomous.conf is MISSING — copy autonomous.conf.example and fill it in"
    problems=$((problems + 1))
  fi

  if (( problems == 0 )); then
    echo "Doctor: OK — no problems found."
    exit 0
  fi
  echo "Doctor: $problems problem(s) found." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Symlink helpers — honor --dry-run by printing instead of mutating.
# ---------------------------------------------------------------------------
PLAN_PREFIX=""
if (( DRY_RUN == 1 )); then
  PLAN_PREFIX="[dry-run] would "
fi

do_ln() {  # do_ln <src> <dst>  (create or repoint a symlink)
  local src="$1" dst="$2"
  if (( DRY_RUN == 1 )); then
    echo "${PLAN_PREFIX}symlink: scripts/$(basename "$dst") → $src" >&2
    return 0
  fi
  ln -sf "$src" "$dst"
}

do_rm() {  # do_rm <dst>  (prune a symlink)
  local dst="$1"
  if (( DRY_RUN == 1 )); then
    echo "${PLAN_PREFIX}prune: scripts/$(basename "$dst")" >&2
    return 0
  fi
  rm -f "$dst"
}

# Symlink STABLE ENTRY dispatcher scripts into <project>/scripts/ — file-by-file,
# so project-local files (autonomous.conf, deploy.sh, validators, …) coexist
# with the upstream-managed wrappers. lib-*.sh are intentionally skipped
# ([INV-65]: entries source them from the skill tree).
if (( DRY_RUN == 0 )); then
  mkdir -p "$ROOT/scripts"
fi
linked=0
skipped=0
for src in "$DISPATCHER_DIR"/*.sh; do
  [[ -e "$src" ]] || continue   # empty glob guard
  name="$(basename "$src")"
  is_entry_script "$name" || continue   # lib-*.sh — not symlinked
  dst="$ROOT/scripts/$name"

  if [[ -L "$dst" ]]; then
    # Existing symlink: re-point it (handles upstream rename / moved
    # skills root). `ln -sf` to a symlink replaces the link target.
    do_ln "$src" "$dst"
    linked=$((linked + 1))
  elif [[ -e "$dst" ]]; then
    # Real (non-symlink) file already there — operator owns it. Don't
    # overwrite project-local wrappers / configs.
    skipped=$((skipped + 1))
    echo "Skipped (project-local file exists): scripts/$name" >&2
  else
    do_ln "$src" "$dst"
    linked=$((linked + 1))
  fi
done

# Prune two classes of <project>/scripts/*.sh symlinks:
#   (a) dangling symlinks whose target is missing AND lived in the dispatcher
#       dir (removed-upstream cleanup), and
#   (b) stale non-manifest symlinks pointing into the dispatcher dir — any
#       managed symlink whose basename is NOT an entry script per
#       is_entry_script(). Post-#227 ([INV-65]) that covers the per-lib symlinks
#       (scripts/lib-*.sh; lib sourcing no longer reads <project>/scripts/) AND
#       the *-aws-ssm.sh helpers (#227 P1; they source lib-ssm.sh from their own
#       dir and must run from the skill tree, never the project-side symlink).
#       Keying the prune on is_entry_script() keeps it in lock-step with the
#       symlink-creation rule — anything we no longer create, we also remove.
# Project-local dangling symlinks (target outside the dispatcher dir) are left
# alone — that's a different operator problem we shouldn't auto-fix.
pruned=0
if [[ -d "$ROOT/scripts" ]]; then
  for dst in "$ROOT/scripts"/*.sh; do
    # Only our own managed symlinks are prune candidates; a project-local
    # symlink (target outside the dispatcher dir) is left untouched.
    symlink_into_dispatcher_dir "$dst" || continue
    name="$(basename "$dst")"

    if [[ ! -e "$dst" ]]; then
      # (a) dangling symlink into the dispatcher dir
      do_rm "$dst"
      pruned=$((pruned + 1))
      echo "${PLAN_PREFIX:-Pruned }dangling symlink: scripts/$name" >&2
    elif ! is_entry_script "$name"; then
      # (b) stale non-manifest symlink (lib-*.sh or *-aws-ssm.sh) — no longer
      #     created, so remove it. Live or dangling.
      do_rm "$dst"
      pruned=$((pruned + 1))
      echo "${PLAN_PREFIX:-Pruned }stale non-manifest symlink: scripts/$name" >&2
    fi
  done
fi

# Symlink the hooks directory. If <project>/hooks already exists as a real
# directory, refuse to shadow it — operator inspection required. An
# existing symlink (correct or stale) is replaced.
if (( DRY_RUN == 1 )); then
  if [[ -L "$ROOT/hooks" ]]; then
    echo "${PLAN_PREFIX}repoint: hooks → $HOOKS_DIR" >&2
  elif [[ -e "$ROOT/hooks" ]]; then
    echo "[dry-run] hooks is a real dir; would NOT symlink (operator inspection required)" >&2
  else
    echo "${PLAN_PREFIX}symlink: hooks → $HOOKS_DIR" >&2
  fi
elif [[ -L "$ROOT/hooks" ]]; then
  ln -sfn "$HOOKS_DIR" "$ROOT/hooks"
elif [[ -e "$ROOT/hooks" ]]; then
  echo "WARN: $ROOT/hooks exists as a real directory; not symlinking." >&2
  echo "      Move or remove it, then re-run." >&2
else
  ln -s "$HOOKS_DIR" "$ROOT/hooks"
fi

echo "Project-side bootstrap: $linked symlinked, $skipped skipped, $pruned pruned." >&2

if (( DRY_RUN == 1 )); then
  echo "[dry-run] No filesystem changes were made." >&2
  exit 0
fi

if (( INSTALL_GIT_HOOK == 1 )); then
  install_per_worktree_pre_push
fi

ensure_dispatcher_scripts_executable

echo "Done. Project-side scripts/ + hooks symlinks are in sync with the installed skills." >&2
