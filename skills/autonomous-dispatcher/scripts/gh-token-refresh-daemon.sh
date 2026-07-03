#!/bin/bash
# gh-token-refresh-daemon.sh — Background daemon that refreshes GitHub App token
# periodically and writes it to a token file. Designed to keep tokens fresh during
# long-running Claude Code sessions (which can exceed the 1-hour token TTL).
#
# Usage:
#   scripts/gh-token-refresh-daemon.sh <token_file> <app_id> <pem_file> <repo_owner> <repo_name> [permissions_json] &
#   DAEMON_PID=$!
#
# The daemon writes the token to <token_file> every REFRESH_INTERVAL seconds.
# The wrapper script should set GH_TOKEN to read from this file before each gh call.
#
# [INV-79] Optional 6th arg <permissions_json>: when non-empty, every mint
# (initial + each refresh) down-scopes the token to that permissions object —
# this is how the SCOPED agent-token daemon keeps the agent's narrower token
# fresh. Omitted/empty → full-grant token (the existing wrapper-token daemon,
# byte-identical to the pre-[INV-79] 5-arg form).
#
# Kill the daemon when the session ends (e.g., in a trap handler).

set -euo pipefail

TOKEN_FILE="${1:?Usage: gh-token-refresh-daemon.sh <token_file> <app_id> <pem_file> <repo_owner> <repo_name> [permissions_json]}"
APP_ID="${2:?Missing app_id}"
PEM_FILE="${3:?Missing pem_file}"
REPO_OWNER="${4:?Missing repo_owner}"
REPO_NAME="${5:?Missing repo_name}"
PERMISSIONS_JSON="${6:-}"

# Refresh every 45 minutes (token TTL is 60 minutes)
REFRESH_INTERVAL="${GH_TOKEN_REFRESH_INTERVAL:-2700}"

# [INV-65] Resolve LIB_DIR from the REAL path (readlink -f) so the sibling
# gh-app-token.sh sources from the skill tree even if the project doesn't
# symlink it (#227). This daemon reads no autonomous.conf, so it needs no
# separate unresolved CONF_DIR. On a real (non-symlink) invocation readlink -f
# is identity, so LIB_DIR equals the daemon's own dir.
_SELF="${BASH_SOURCE[0]:-$0}"
LIB_DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"
source "${LIB_DIR}/gh-app-token.sh"

log() { echo "[token-refresh] $(date -u +%H:%M:%S) $*"; }

# Write initial token atomically with restrictive permissions.
# [INV-79] PERMISSIONS_JSON (when set) is forwarded as get_gh_app_token's 5th
# arg so the minted token is down-scoped; empty → full-grant (5-arg behavior).
TOKEN=$(get_gh_app_token "$APP_ID" "$PEM_FILE" "$REPO_OWNER" "$REPO_NAME" "$PERMISSIONS_JSON") || {
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

# [Lane-GC PR-1, RC5] 60s-chunked, PPID-checked sleep replacing the monolithic
# `sleep $REFRESH_INTERVAL`. A SIGKILLed daemon's in-flight sleep child would
# otherwise survive up to REFRESH_INTERVAL (≤45 min default, ≤27.8h with a
# misconfigured interval); chunking bounds that to ≤60s. The TERM/INT trap
# reaps the in-flight sleep child so a graceful signal doesn't leave it behind.
# Returns 1 (instead of exiting directly) when the parent has died mid-sleep,
# so the caller still runs the TOKEN_FILE cleanup below.
_chunked_sleep() {
  local left=$1 _sp
  trap 'kill "$_sp" 2>/dev/null; exit 0' TERM INT
  while (( left > 0 )); do
    kill -0 "$PPID" 2>/dev/null || return 1
    local chunk=$(( left > 60 ? 60 : left ))
    sleep "$chunk" & _sp=$!
    wait "$_sp"
    left=$(( left - chunk ))
  done
  trap - TERM INT
}

# Refresh loop with failure limit and parent liveness check
MAX_CONSECUTIVE_FAILURES=10
FAIL_COUNT=0

while true; do
  # Exit if parent process is dead (orphan daemon)
  if ! _chunked_sleep "$REFRESH_INTERVAL"; then
    log "Parent process ($PPID) is dead. Exiting."
    rm -f "$TOKEN_FILE" 2>/dev/null || true
    exit 0
  fi

  NEW_TOKEN=$(get_gh_app_token "$APP_ID" "$PEM_FILE" "$REPO_OWNER" "$REPO_NAME" "$PERMISSIONS_JSON") || {
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
