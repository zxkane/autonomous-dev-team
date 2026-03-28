#!/bin/bash
# lib-auth.sh — GitHub authentication abstraction.
# Supports two modes:
#   - "token" (default): uses GH_TOKEN env var or gh auth login
#   - "app": uses GitHub App tokens with background refresh daemon
# Source this file in autonomous-dev.sh and autonomous-review.sh.

_LIB_AUTH_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# Load project config if available.
# Fall back to <project-root>/scripts/autonomous.conf when installed via skills.
if [[ -f "${_LIB_AUTH_DIR}/autonomous.conf" ]]; then
  source "${_LIB_AUTH_DIR}/autonomous.conf"
elif [[ -f "${_LIB_AUTH_DIR}/../../../scripts/autonomous.conf" ]]; then
  source "${_LIB_AUTH_DIR}/../../../scripts/autonomous.conf"
fi

GH_AUTH_MODE="${GH_AUTH_MODE:-token}"
TOKEN_DAEMON_PID=""
GH_TOKEN_FILE=""

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

    # Use a private directory for token files (not predictable /tmp paths)
    local token_dir
    token_dir=$(mktemp -d "/tmp/agent-auth-XXXXXX")
    chmod 700 "$token_dir"
    GH_TOKEN_FILE="${token_dir}/token"

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

    if [[ -x "${_LIB_AUTH_DIR}/gh-with-token-refresh.sh" ]]; then
      export PATH="${_LIB_AUTH_DIR}:${PATH}"
      ln -sf "${_LIB_AUTH_DIR}/gh-with-token-refresh.sh" "${_LIB_AUTH_DIR}/gh" 2>/dev/null || true
    fi
  else
    if [[ -z "${GH_TOKEN:-}" ]]; then
      if ! command -v gh &>/dev/null || ! gh auth status &>/dev/null 2>&1; then
        echo "WARNING: No GH_TOKEN set and gh auth not configured." >&2
        echo "Run 'export GH_TOKEN=<token>' or 'gh auth login'." >&2
      fi
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
  # Remove token file and its private directory
  if [[ -n "$GH_TOKEN_FILE" ]]; then
    local token_dir
    token_dir=$(dirname "$GH_TOKEN_FILE")
    rm -f "$GH_TOKEN_FILE" 2>/dev/null || true
    [[ "$token_dir" == /tmp/agent-auth-* ]] && rmdir "$token_dir" 2>/dev/null || true
  fi
  rm -f "${_LIB_AUTH_DIR}/gh" 2>/dev/null || true
}

# Export GH_USER_PAT if available (for gh-as-user.sh bot workaround).
if [[ -n "${GH_USER_PAT:-}" ]]; then
  export GH_USER_PAT
fi
