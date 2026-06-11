#!/bin/bash
# lib-auth.sh — GitHub authentication abstraction.
# Supports two modes:
#   - "token" (default): uses GH_TOKEN env var or gh auth login
#   - "app": uses GitHub App tokens with background refresh daemon
# Source this file in autonomous-dev.sh and autonomous-review.sh.

# Load project config via the shared helper (closes #58).
# [INV-65] Two-dir resolution. _LIB_AUTH_DIR is the PROJECT-SIDE dir. It is
# load-bearing for THREE things that MUST stay project-side:
#   (1) load_autonomous_conf [INV-14],
#   (2) the shared project-level `${_LIB_AUTH_DIR}/gh` wrapper symlink the
#       *agent* invokes via `bash scripts/gh` (resolving it to the skill tree
#       would put `gh` where the agent can't find it), and
#   (3) spawning the project-side gh-token-refresh-daemon.sh / pointing the
#       `gh` wrapper at the project-side gh-with-token-refresh.sh (both are
#       entry points the installer symlinks into <project>/scripts/).
# Once an entry sources us via its LIB_DIR (the skill tree), ${BASH_SOURCE[0]}
# here IS the skill-tree path — so we take the project-side dir from the entry's
# exported AUTONOMOUS_CONF_DIR, falling back to our own unresolved BASH_SOURCE
# dir for direct/legacy sourcing. _LIB_AUTH_REAL_DIR is the REAL path (readlink
# -f) used ONLY to source siblings (lib-config.sh, gh-app-token.sh) from the
# skill tree so the project needs no per-lib symlink for them (#227).
_LIB_AUTH_SELF="${BASH_SOURCE[0]:-$0}"
_LIB_AUTH_OWN_DIR="$(cd "$(dirname "$_LIB_AUTH_SELF")" && pwd)"
_LIB_AUTH_DIR="${AUTONOMOUS_CONF_DIR:-$_LIB_AUTH_OWN_DIR}"
_LIB_AUTH_REAL_DIR="$(cd "$(dirname "$(readlink -f "$_LIB_AUTH_SELF")")" && pwd)"
# `pwd` (no -P needed for this) always yields an absolute path. Assert it: the
# `gh` wrapper symlink is created in a /tmp dir with ${_LIB_AUTH_DIR}/... as its
# target, so a relative _LIB_AUTH_DIR would produce a symlink that resolves
# relative to /tmp (broken). Fail loud rather than ship a dangling wrapper.
if [[ "$_LIB_AUTH_DIR" != /* ]]; then
  echo "FATAL: lib-auth.sh expected an absolute _LIB_AUTH_DIR, got '${_LIB_AUTH_DIR}'" >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck source=lib-config.sh
source "${_LIB_AUTH_REAL_DIR}/lib-config.sh"
load_autonomous_conf "${_LIB_AUTH_DIR}" || true

GH_AUTH_MODE="${GH_AUTH_MODE:-token}"
TOKEN_DAEMON_PID=""
GH_TOKEN_FILE=""
# [INV-32] Per-run /tmp directory holding the `gh` wrapper symlink that this
# run prepends to PATH (for the wrapper's OWN bare `gh` calls). Distinct from
# the shared, project-level `${_LIB_AUTH_DIR}/gh` that the *agent* invokes via
# `bash scripts/gh`. Isolating PATH per-run means a concurrent run's cleanup
# can never delete the `gh` this run resolves (issue #163).
GH_WRAPPER_DIR=""

# Create the per-run GH_WRAPPER_DIR (mode 700) if not already set. Idempotent:
# both auth modes call this, and a second call is a no-op once the dir exists.
_ensure_gh_wrapper_dir() {
  if [[ -z "$GH_WRAPPER_DIR" ]]; then
    GH_WRAPPER_DIR=$(mktemp -d "/tmp/agent-auth-XXXXXX")
    chmod 700 "$GH_WRAPPER_DIR"
  fi
}

# Setup GitHub authentication based on GH_AUTH_MODE.
# For "app" mode, caller must pass app_id and app_pem.
# Args: $1=app_id (for app mode), $2=app_pem (for app mode)
setup_github_auth() {
  local app_id="${1:-}"
  local app_pem="${2:-}"

  if [[ "$GH_AUTH_MODE" == "app" ]]; then
    if [[ -z "$app_id" || -z "$app_pem" ]]; then
      echo "ERROR: GH_AUTH_MODE=app requires app_id and app_pem arguments" >&2
      return 1
    fi

    # [INV-65] sibling lib sourced from the REAL skill tree (no project symlink
    # needed); the `gh` wrapper symlinks below stay on the project-side
    # _LIB_AUTH_DIR (the agent invokes them via `bash scripts/gh`).
    source "${_LIB_AUTH_REAL_DIR}/gh-app-token.sh"

    # Use a private directory for token files (not predictable /tmp paths).
    # This same per-run dir doubles as GH_WRAPPER_DIR below (the `gh` wrapper
    # symlink lives alongside the token file and is cleaned up with it).
    _ensure_gh_wrapper_dir
    GH_TOKEN_FILE="${GH_WRAPPER_DIR}/token"

    bash "${_LIB_AUTH_DIR}/gh-token-refresh-daemon.sh" \
      "$GH_TOKEN_FILE" "$app_id" "$app_pem" "$REPO_OWNER" "$REPO_NAME" &
    TOKEN_DAEMON_PID=$!

    # Poll for token file (token generation involves multiple API calls and
    # can take >1s depending on network latency)
    local _wait_max=10
    local _waited=0
    while [[ $_waited -lt $_wait_max ]] && [[ ! -s "$GH_TOKEN_FILE" ]]; do
      sleep 1
      _waited=$((_waited + 1))
    done

    if [[ ! -s "$GH_TOKEN_FILE" ]]; then
      echo "FATAL: Token daemon failed to write initial token after ${_wait_max}s" >&2
      kill "$TOKEN_DAEMON_PID" 2>/dev/null || true
      return 1
    fi

    refresh_token_env
    export GH_TOKEN_FILE
  else
    if [[ -z "${GH_TOKEN:-}" ]]; then
      if ! command -v gh &>/dev/null || ! gh auth status &>/dev/null 2>&1; then
        echo "WARNING: No GH_TOKEN set and gh auth not configured." >&2
        echo "Run 'export GH_TOKEN=<token>' or 'gh auth login'." >&2
      fi
    fi
  fi

  # [INV-32] Install the `gh` wrapper for BOTH consumers, on two distinct
  # paths (issue #163):
  #
  #   1. The wrapper's OWN bare `gh` calls (autonomous-dev.sh / -review.sh)
  #      resolve through PATH. We point PATH at a per-run /tmp dir
  #      (GH_WRAPPER_DIR) so a concurrent run's cleanup can never delete the
  #      `gh` this run resolves. token mode has no daemon and so didn't yet
  #      create the dir — create it here.
  #
  #   2. The *agent* invokes `bash scripts/gh issue comment …` (a relative
  #      path from PROJECT_DIR, NOT a PATH lookup), so it needs the physical
  #      file ${_LIB_AUTH_DIR}/gh to exist. That is a stable, shared,
  #      project-level artifact: created idempotently AND atomically (temp
  #      symlink + `mv -f`, see below — a bare `ln -sf` would briefly unlink
  #      it under a concurrent reader) and NEVER deleted by a per-run cleanup.
  #      Removing it per-run was the #163 root cause.
  #
  # The wrapper itself (gh-with-token-refresh.sh) is mode-agnostic — it reads
  # GH_TOKEN_FILE only when set (app mode); in token mode it exec's the real
  # gh inheriting the host's auth env (the intended identity). Both modes thus
  # get a working `gh` on PATH and a working `scripts/gh` for the agent. See
  # issues #142 (uniform rule) and #163 (per-run isolation).
  if [[ -x "${_LIB_AUTH_DIR}/gh-with-token-refresh.sh" ]]; then
    _ensure_gh_wrapper_dir
    export PATH="${GH_WRAPPER_DIR}:${PATH}"
    # Per-run dir is private to this run — a bare `ln -sf` is fine.
    ln -sf "${_LIB_AUTH_DIR}/gh-with-token-refresh.sh" "${GH_WRAPPER_DIR}/gh" 2>/dev/null || true
    # Shared, project-level ${_LIB_AUTH_DIR}/gh: created ATOMICALLY. A bare
    # `ln -sf` unlinks the existing symlink before recreating it, leaving a
    # brief window where a concurrent run's `bash scripts/gh …` sees no file
    # ("No such file or directory"). Build the symlink under a unique temp name
    # in the same dir, then `mv -f` it into place — rename(2) is atomic, so the
    # path is never momentarily absent for concurrent readers.
    local _gh_tmp="${_LIB_AUTH_DIR}/.gh.$$.$RANDOM"
    if ln -s "${_LIB_AUTH_DIR}/gh-with-token-refresh.sh" "$_gh_tmp" 2>/dev/null; then
      mv -f "$_gh_tmp" "${_LIB_AUTH_DIR}/gh" 2>/dev/null || rm -f "$_gh_tmp" 2>/dev/null || true
    fi
  fi
}

# Read latest token from file (for app mode).
refresh_token_env() {
  if [[ -n "$GH_TOKEN_FILE" && -s "$GH_TOKEN_FILE" ]]; then
    local token
    token=$(cat "$GH_TOKEN_FILE" 2>/dev/null) || return 1
    export GH_TOKEN="$token"
    export GITHUB_PERSONAL_ACCESS_TOKEN="$token"
  fi
}

# Cleanup auth resources. Call in trap handler.
cleanup_github_auth() {
  if [[ -n "$TOKEN_DAEMON_PID" ]]; then
    kill "$TOKEN_DAEMON_PID" 2>/dev/null || true
    wait "$TOKEN_DAEMON_PID" 2>/dev/null || true
  fi
  # Remove the per-run wrapper dir (holds both the token file and this run's
  # `gh` symlink). Guarded on the /tmp/agent-auth-* shape so we never rm -rf
  # an unexpected path. [INV-32] We deliberately do NOT touch
  # ${_LIB_AUTH_DIR}/gh — it is a shared, project-level artifact the agent's
  # `bash scripts/gh` and any concurrent run depend on. Removing it per-run
  # was the #163 concurrency footgun.
  rm -f "$GH_TOKEN_FILE" 2>/dev/null || true
  if [[ "$GH_WRAPPER_DIR" == /tmp/agent-auth-* ]]; then
    rm -rf "$GH_WRAPPER_DIR" 2>/dev/null || true
  fi
  # Reset the module-level state we just tore down. Without this, a second
  # setup_github_auth in the SAME shell (persistent test runners, consecutive
  # tasks) would see GH_WRAPPER_DIR still set, _ensure_gh_wrapper_dir would skip
  # the mktemp, and GH_TOKEN_FILE / the per-run `gh` symlink would point into the
  # directory we just rm -rf'd. Clearing here makes setup→cleanup→setup idempotent.
  GH_WRAPPER_DIR=""
  GH_TOKEN_FILE=""
  TOKEN_DAEMON_PID=""
}

# Export GH_USER_PAT if available (for gh-as-user.sh bot workaround).
if [[ -n "${GH_USER_PAT:-}" ]]; then
  export GH_USER_PAT
fi

# Export REAL_GH if set in autonomous.conf so gh-with-token-refresh.sh sees
# it across the PATH-injection boundary (closes #92). The wrapper child
# only reads its env, not the parent's shell vars.
if [[ -n "${REAL_GH:-}" ]]; then
  export REAL_GH
fi
