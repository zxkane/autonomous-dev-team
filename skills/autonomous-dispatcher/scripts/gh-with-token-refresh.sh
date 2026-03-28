#!/bin/bash
# gh-with-token-refresh.sh — Wrapper around `gh` that reads the latest token
# from a token file before each invocation. Used by autonomous dev/review scripts
# to keep GH_TOKEN fresh when the original token may have expired.
#
# The real `gh` binary is expected at /usr/bin/gh or /usr/local/bin/gh.
# This wrapper is placed earlier in PATH so Claude Code's Bash tool uses it.

# Find the real gh binary (skip ourselves by temporarily removing our dir from PATH)
SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CLEAN_PATH=$(echo "$PATH" | tr ':' '\n' | grep -v "^${SELF_DIR}$" | tr '\n' ':' | sed 's/:$//')
REAL_GH=$(PATH="$CLEAN_PATH" command -v gh 2>/dev/null) || {
  echo "ERROR: Cannot find real gh binary (looked in PATH minus ${SELF_DIR})" >&2
  exit 1
}

# Read latest token from file if available.
# Retry briefly if the file is momentarily empty (race during daemon refresh).
# IMPORTANT: Never fall through without a token — the host `gh auth` session
# may be logged in as a different user (e.g., the repo owner), which would
# cause comments to be attributed to that user instead of the bot.
if [[ -n "${GH_TOKEN_FILE:-}" ]]; then
  for _attempt in 1 2 3; do
    if [[ -s "$GH_TOKEN_FILE" ]]; then
      export GH_TOKEN=$(cat "$GH_TOKEN_FILE")
      export GITHUB_PERSONAL_ACCESS_TOKEN="$GH_TOKEN"
      break
    fi
    sleep 1
  done
  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "ERROR: GH_TOKEN_FILE is set but token file is empty after retries: $GH_TOKEN_FILE" >&2
    exit 1
  fi
fi

exec "$REAL_GH" "$@"
