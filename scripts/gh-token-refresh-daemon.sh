#!/bin/bash
# gh-token-refresh-daemon.sh — Background daemon that refreshes GitHub App token
# periodically and writes it to a token file. Designed to keep tokens fresh during
# long-running Claude Code sessions (which can exceed the 1-hour token TTL).
#
# Usage:
#   scripts/gh-token-refresh-daemon.sh <token_file> <app_id> <pem_file> <repo_owner> <repo_name> &
#   DAEMON_PID=$!
#
# The daemon writes the token to <token_file> every REFRESH_INTERVAL seconds.
# The wrapper script should set GH_TOKEN to read from this file before each gh call.
#
# Kill the daemon when the session ends (e.g., in a trap handler).

set -euo pipefail

TOKEN_FILE="${1:?Usage: gh-token-refresh-daemon.sh <token_file> <app_id> <pem_file> <repo_owner> <repo_name>}"
APP_ID="${2:?Missing app_id}"
PEM_FILE="${3:?Missing pem_file}"
REPO_OWNER="${4:?Missing repo_owner}"
REPO_NAME="${5:?Missing repo_name}"

# Refresh every 45 minutes (token TTL is 60 minutes)
REFRESH_INTERVAL="${GH_TOKEN_REFRESH_INTERVAL:-2700}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/gh-app-token.sh"

log() { echo "[token-refresh] $(date -u +%H:%M:%S) $*"; }

# Write initial token atomically with restrictive permissions
TOKEN=$(get_gh_app_token "$APP_ID" "$PEM_FILE" "$REPO_OWNER" "$REPO_NAME") || {
  log "ERROR: Failed to generate initial token"
  exit 1
}
TOKEN_TMP="${TOKEN_FILE}.tmp.$$"
(umask 077 && echo "$TOKEN" > "$TOKEN_TMP")
mv -f "$TOKEN_TMP" "$TOKEN_FILE"
log "Initial token written to $TOKEN_FILE"

# Validate refresh interval is reasonable (minimum 60 seconds)
if [[ "$REFRESH_INTERVAL" -lt 60 ]]; then
  log "WARNING: REFRESH_INTERVAL ($REFRESH_INTERVAL) too low, clamping to 60"
  REFRESH_INTERVAL=60
fi

# Refresh loop with failure limit and parent liveness check
MAX_CONSECUTIVE_FAILURES=10
FAIL_COUNT=0

while true; do
  sleep "$REFRESH_INTERVAL"

  # Exit if parent process is dead (orphan daemon)
  if ! kill -0 "$PPID" 2>/dev/null; then
    log "Parent process ($PPID) is dead. Exiting."
    rm -f "$TOKEN_FILE" 2>/dev/null || true
    exit 0
  fi

  NEW_TOKEN=$(get_gh_app_token "$APP_ID" "$PEM_FILE" "$REPO_OWNER" "$REPO_NAME") || {
    ((FAIL_COUNT++))
    log "WARNING: Failed to refresh token (failure $FAIL_COUNT/$MAX_CONSECUTIVE_FAILURES), keeping existing"
    if [[ $FAIL_COUNT -ge $MAX_CONSECUTIVE_FAILURES ]]; then
      log "FATAL: $MAX_CONSECUTIVE_FAILURES consecutive refresh failures. Exiting."
      exit 1
    fi
    continue
  }

  FAIL_COUNT=0
  TOKEN_TMP="${TOKEN_FILE}.tmp.$$"
  (umask 077 && echo "$NEW_TOKEN" > "$TOKEN_TMP")
  mv -f "$TOKEN_TMP" "$TOKEN_FILE"
  log "Token refreshed"
done
