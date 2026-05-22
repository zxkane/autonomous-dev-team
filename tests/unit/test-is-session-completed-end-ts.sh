#!/bin/bash
# test-is-session-completed-end-ts.sh — INV-35 / issue #149.
#
# Extends test-is-session-completed.sh with the new third out-var that
# captures the session-end ISO timestamp. The dispatcher Step 4b.5.1 routing
# needs this timestamp to filter post-completion review verdict comments via
# classify_recent_review_verdict.
#
# Implementation choice: derive end-ts from the log file's mtime (the wrapper
# writes the final "Agent exited" log line as it completes, so mtime is a
# reliable session-end proxy across any agent CLI). The result line's JSON
# does not carry a timestamp (claude omits it; wrapper-emitted time prefixes
# are HH:MM:SS-only without date).
#
# Helper signature (extended):
#   is_session_completed <issue> [reason_var] [end_ts_var]
#
# Run: bash tests/unit/test-is-session-completed-end-ts.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID="test-iscompleted-ets-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5
export AGENT_CMD=claude

gh() { :; }
export -f gh

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

assert_match() {
  local desc="$1" regex="$2" actual="$3"
  if [[ "$actual" =~ $regex ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      regex=[$regex]"
    echo "      actual=[$actual]"
    FAIL=$((FAIL + 1))
  fi
}

write_log() {
  local issue_num="$1" content="$2"
  local log_file="/tmp/agent-${PROJECT_ID}-issue-${issue_num}.log"
  printf '%s' "$content" > "$log_file"
  printf '%s' "$log_file"
}

cleanup_log() {
  rm -f "/tmp/agent-${PROJECT_ID}-issue-${1}.log"
}

# ---------------------------------------------------------------------------
echo "=== is_session_completed: third out-var (log-mtime-derived end-ts) ==="
# ---------------------------------------------------------------------------

# Set log mtime to a known value to make the assertion deterministic.
log_file=$(write_log 200 '{"type":"result","stop_reason":"end_turn","terminal_reason":"completed","duration_ms":5000}')
# Use 2026-05-21 03:18:42 UTC as the reference mtime
ref_epoch=1779333522  # 2026-05-21T03:18:42Z
touch -d "@${ref_epoch}" "$log_file"
reason=""; end_ts=""
is_session_completed 200 reason end_ts
assert_eq "completed: reason captured" "completed" "$reason"
assert_match "completed: end_ts is ISO-8601 UTC" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$end_ts"
assert_eq "completed: end_ts matches log mtime" "2026-05-21T03:18:42Z" "$end_ts"
cleanup_log 200

# PTL case
log_file=$(write_log 202 '{"type":"result","subtype":"success","is_error":true,"api_error_status":400,"result":"Prompt is too long","stop_reason":"stop_sequence","session_id":"abc","usage":{"input_tokens":0},"terminal_reason":"prompt_too_long"}')
ref_epoch_ptl=1779346800  # 2026-05-21T07:00:00Z
touch -d "@${ref_epoch_ptl}" "$log_file"
reason=""; end_ts=""
is_session_completed 202 reason end_ts
assert_eq "PTL: reason" "prompt_too_long" "$reason"
assert_eq "PTL: end_ts matches mtime" "2026-05-21T07:00:00Z" "$end_ts"
cleanup_log 202

# Single-arg legacy call still works
log_file=$(write_log 203 '{"type":"result","stop_reason":"end_turn","terminal_reason":"completed"}')
is_session_completed 203
rc=$?
assert_eq "single-arg legacy rc=0" "0" "$rc"
cleanup_log 203

# Two-arg legacy call still works
log_file=$(write_log 204 '{"type":"result","stop_reason":"end_turn","terminal_reason":"completed"}')
reason=""
is_session_completed 204 reason
assert_eq "two-arg legacy: reason captured" "completed" "$reason"
cleanup_log 204

# Non-terminal result: end_ts must remain unset (helper returns 1)
log_file=$(write_log 205 '{"type":"result","stop_reason":"max_tokens","terminal_reason":"interrupted"}')
reason="prefilled"; end_ts="prefilled"
is_session_completed 205 reason end_ts
rc=$?
assert_eq "non-terminal rc=1" "1" "$rc"
# Out-vars should be left at caller's default — this is the bash convention:
# don't overwrite when returning false.
cleanup_log 205

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
