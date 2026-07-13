#!/bin/bash
# lib-config.sh — single source of truth for loading autonomous.conf.
#
# Replaces three byte-identical `_LIB_*_DIR + 3-fallback` blocks that
# previously lived in lib-agent.sh, lib-auth.sh, and dispatcher-tick.sh.
# Closes issue #58 by dropping the `readlink -f` that broke the symlink-
# vendoring pattern, and by fixing the depth of the project-root fallback.
#
# Usage (from a script that needs autonomous.conf):
#
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
#   # shellcheck source=lib-config.sh
#   source "${SCRIPT_DIR}/lib-config.sh"
#   load_autonomous_conf "${SCRIPT_DIR}"
#
# Caller is responsible for computing SCRIPT_DIR with ${BASH_SOURCE[0]:-$0}
# (NOT `readlink -f`) so the symlink-vendor pattern works: a project that
# vendors scripts as symlinks into `.claude/skills/.../scripts/` resolves
# SCRIPT_DIR to the project's `scripts/`, where autonomous.conf actually
# lives — see issue #58 / [INV-14].
#
# The contract supports two deployment topologies (verified by
# tests/unit/test-symlink-resolution.sh TC-INV14-1..6):
#   1. Vendored per-project: each project has its own
#      <project>/.agents/skills/.../scripts/ vendored copy of the lib,
#      and <project>/scripts/<file>.sh symlinks point into the vendored
#      copy. Upstream upgrade requires `npx skills update -p` per project.
#   2. Shared install: a single <home>/.claude/skills/.../scripts/ install
#      shared across all projects, and each <project>/scripts/<file>.sh
#      symlinks into the shared install. Upstream upgrade is one
#      `npx skills update -g`.
# Direct invocation of a vendored copy (no project-side symlink) is also
# supported via the legacy `../../../scripts/autonomous.conf` fallback in
# dispatch-local.sh — kept for backward compat.

# load_autonomous_conf <invoking_script_dir>
#
# Loads autonomous.conf from the highest-priority source that exists:
#   1. ${AUTONOMOUS_CONF}                         (env-var override)
#   2. ${invoking_script_dir}/autonomous.conf     (script-local)
#   3. ${PROJECT_DIR}/scripts/autonomous.conf     (project-root fallback,
#                                                  only if PROJECT_DIR set)
#
# On success: sources the file, sets AUTONOMOUS_CONF_LOADED_FROM to the
# absolute path, returns 0.
# On failure (no source found): returns 1 without sourcing anything.
# Caller is responsible for the `: "${REPO:?...}"` checks that detect
# downstream config-incomplete cases.
load_autonomous_conf() {
  local script_dir="$1"
  local candidate=""

  if [[ -n "${AUTONOMOUS_CONF:-}" ]] && [[ -f "${AUTONOMOUS_CONF}" ]]; then
    candidate="${AUTONOMOUS_CONF}"
  elif [[ -n "$script_dir" ]] && [[ -f "${script_dir}/autonomous.conf" ]]; then
    candidate="${script_dir}/autonomous.conf"
  elif [[ -n "${PROJECT_DIR:-}" ]] && [[ -f "${PROJECT_DIR}/scripts/autonomous.conf" ]]; then
    candidate="${PROJECT_DIR}/scripts/autonomous.conf"
  fi

  if [[ -z "$candidate" ]]; then
    return 1
  fi

  # shellcheck disable=SC1090,SC1091
  source "$candidate"
  AUTONOMOUS_CONF_LOADED_FROM="$candidate"
  export AUTONOMOUS_CONF_LOADED_FROM
  return 0
}

# resolve_base_branch — echo the effective base/trunk branch the pipeline
# targets, per the [INV-131] resolution chain (issue #478):
#
#   BASE_BRANCH (new, first-class conf key) → DEFAULT_BRANCH (deprecated
#   fallback; the one pre-#478 code reference, autonomous-dev.sh's
#   needs_open_pr_only) → "main" (default).
#
# Whichever value wins is validated against ^[A-Za-z0-9._/-]+$ (a git
# ref-name-safe charset with no spaces/quotes — the value is interpolated
# into agent prompts AND git/gh command lines, so anything else is an
# injection/parse hazard) PLUS a leading-`-` rejection (a value starting with
# `-` risks being parsed as a flag by a downstream `git`/`gh` invocation,
# even though `-` itself is a legal mid-branch-name character). An invalid
# value falls back to "main" with a loud stderr WARNING, mirroring
# `lib-review-cap.sh::_review_cap_threshold`'s fallback posture. A value that
# came from the deprecated DEFAULT_BRANCH also gets a one-time stderr
# deprecation notice pointing at BASE_BRANCH — even when that value is itself
# invalid (the operator needs both signals: "you're on the old key" AND "the
# value is malformed").
#
# With NEITHER var set (today's universal deployment shape), this echoes
# "main" with NO stderr output — byte-identical to pre-#478 behavior.
resolve_base_branch() {
  local raw="" source=""
  if [[ -n "${BASE_BRANCH:-}" ]]; then
    raw="$BASE_BRANCH"
    source="BASE_BRANCH"
  elif [[ -n "${DEFAULT_BRANCH:-}" ]]; then
    raw="$DEFAULT_BRANCH"
    source="DEFAULT_BRANCH"
    echo "WARNING: DEFAULT_BRANCH is deprecated — set BASE_BRANCH instead (DEFAULT_BRANCH will be removed in a future release)" >&2
  else
    printf '%s\n' "main"
    return 0
  fi

  if [[ "$raw" =~ ^[A-Za-z0-9._/-]+$ ]] && [[ "$raw" != -* ]]; then
    printf '%s\n' "$raw"
  else
    echo "WARNING: ${source}='${raw}' is not a valid branch name (must match ^[A-Za-z0-9._/-]+\$ with no leading '-' — no spaces/quotes) — falling back to 'main'" >&2
    printf '%s\n' "main"
  fi
}

# pid_dir_for_project — echo the per-user directory holding wrapper PID
# files for this project. Replaces the predictable `/tmp/agent-...` paths
# (CWE-377, #72) with a path under $XDG_RUNTIME_DIR (canonical Linux per-user
# runtime, mode 0700 by spec) or the $HOME/.local/state fallback. Both are
# already inaccessible to other local users, so no per-spawn mktemp
# randomness is needed.
#
# Path resolution priority:
#   1. ${AUTONOMOUS_PID_DIR}                         (override; used by tests)
#   2. ${XDG_RUNTIME_DIR}/autonomous-${PROJECT_ID}   (preferred)
#   3. ${HOME}/.local/state/autonomous-${PROJECT_ID} (fallback)
#
# Idempotent: creates the dir + chmod 700 on first call, leaves it alone
# on subsequent calls. Refuses to operate if the path is a pre-existing
# symlink (CWE-59 defense in depth — the parent dir mode is 0700 so this
# should never trigger, but cheap to keep).
#
# Returns:
#   echoes path on stdout, rc=0 on success.
#   echoes nothing, rc=1 on error (writes diagnostic to stderr).
pid_dir_for_project() {
  : "${PROJECT_ID:?pid_dir_for_project: PROJECT_ID must be set}"

  local dir
  if [[ -n "${AUTONOMOUS_PID_DIR:-}" ]]; then
    dir="${AUTONOMOUS_PID_DIR}"
  elif [[ -n "${XDG_RUNTIME_DIR:-}" ]] && [[ -d "${XDG_RUNTIME_DIR}" ]]; then
    dir="${XDG_RUNTIME_DIR}/autonomous-${PROJECT_ID}"
  else
    : "${HOME:?pid_dir_for_project: HOME must be set when XDG_RUNTIME_DIR is unset}"
    dir="${HOME}/.local/state/autonomous-${PROJECT_ID}"
  fi

  if [[ -L "$dir" ]]; then
    echo "pid_dir_for_project: refusing to use symlinked path: $dir" >&2
    return 1
  fi

  if ! mkdir -p "$dir" 2>/dev/null; then
    echo "pid_dir_for_project: cannot create $dir" >&2
    return 1
  fi
  # chmod every call: cheap, and self-heals if a previous run created the
  # dir before we started enforcing 0700. Fail loudly if chmod errors —
  # silently swallowing it would defeat the entire CWE-377 mitigation
  # (a dir left at 0755 is exactly what this PR is closing).
  if ! chmod 700 "$dir" 2>/dev/null; then
    echo "pid_dir_for_project: cannot set mode 700 on $dir — refusing to write PID files to a non-private directory" >&2
    return 1
  fi

  echo "$dir"
}
