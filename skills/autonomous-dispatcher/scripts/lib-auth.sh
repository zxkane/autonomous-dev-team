#!/bin/bash
# lib-auth.sh — GitHub authentication abstraction.
# Supports two modes:
#   - "token" (default): uses GH_TOKEN env var or gh auth login
#   - "app": uses GitHub App tokens with background refresh daemon
# Source this file in autonomous-dev.sh and autonomous-review.sh.

# Load project config via the shared helper (closes #58).
# Note: ${BASH_SOURCE[0]:-$0} (NOT readlink -f) so the symlink-vendor
# pattern resolves to the project's scripts/ rather than the skill
# installation dir.
_LIB_AUTH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=lib-config.sh
source "${_LIB_AUTH_DIR}/lib-config.sh"
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

    source "${_LIB_AUTH_DIR}/gh-app-token.sh"

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
  #      project-level artifact: created idempotently (`ln -sf` to a fixed
  #      target is safe under concurrent creation) and NEVER deleted by a
  #      per-run cleanup. Removing it per-run was the #163 root cause.
  #
  # The wrapper itself (gh-with-token-refresh.sh) is mode-agnostic — it reads
  # GH_TOKEN_FILE only when set (app mode); in token mode it exec's the real
  # gh inheriting the host's auth env (the intended identity). Both modes thus
  # get a working `gh` on PATH and a working `scripts/gh` for the agent. See
  # issues #142 (uniform rule) and #163 (per-run isolation).
  if [[ -x "${_LIB_AUTH_DIR}/gh-with-token-refresh.sh" ]]; then
    _ensure_gh_wrapper_dir
    export PATH="${GH_WRAPPER_DIR}:${PATH}"
    ln -sf "${_LIB_AUTH_DIR}/gh-with-token-refresh.sh" "${GH_WRAPPER_DIR}/gh" 2>/dev/null || true
    ln -sf "${_LIB_AUTH_DIR}/gh-with-token-refresh.sh" "${_LIB_AUTH_DIR}/gh" 2>/dev/null || true
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
