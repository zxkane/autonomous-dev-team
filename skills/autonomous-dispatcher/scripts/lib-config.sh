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
