#!/bin/bash
# test-is-session-completed.sh — Unit tests for lib-dispatch.sh::is_session_completed.
#
# Closes the test side of #59 (INV-12). The helper inspects the agent log file
# at /tmp/agent-${PROJECT_ID}-issue-${N}.log, parses the last result JSON, and
# returns 0 if the session ended with stop_reason=end_turn AND
# terminal_reason=completed.
#
# Run: bash tests/unit/test-is-session-completed.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Required env (lib-dispatch.sh enforces these via : "${VAR:?...}")
export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID="test-iscompleted-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# Stub gh — is_session_completed never calls it, but lib-dispatch.sh sources
# may run other helpers. Provide a no-op.
gh() { :; }
export -f gh

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

assert_returns() {
  local desc="$1" expected_rc="$2"; shift 2
  "$@"
  local actual_rc=$?
  if [[ "$expected_rc" == "$actual_rc" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected_rc=$expected_rc actual_rc=$actual_rc"
    FAIL=$((FAIL + 1))
  fi
}

write_log() {
  local issue_num="$1" content="$2"
  local log_file="/tmp/agent-${PROJECT_ID}-issue-${issue_num}.log"
  printf '%s' "$content" > "$log_file"
}

cleanup_log() {
  local issue_num="$1"
  rm -f "/tmp/agent-${PROJECT_ID}-issue-${issue_num}.log"
}

# ---------------------------------------------------------------------------
echo "=== is_session_completed (INV-12) ==="
# ---------------------------------------------------------------------------

# TC-WH-003: clean Claude exit returns true
write_log 1001 'some agent output
{"type":"result","stop_reason":"end_turn","terminal_reason":"completed","duration_ms":5000}
'
export AGENT_CMD=claude
assert_returns "clean Claude exit (end_turn + completed) → true" 0 is_session_completed 1001
cleanup_log 1001

# TC-WH-004: crashed mid-turn returns false (no result object at all)
write_log 1002 'agent started... then process killed'
assert_returns "crashed mid-turn (no result object) → false" 1 is_session_completed 1002
cleanup_log 1002

# Variant: result object with non-completed terminal_reason
write_log 1003 '{"type":"result","stop_reason":"end_turn","terminal_reason":"interrupted"}'
assert_returns "result with non-completed terminal_reason → false" 1 is_session_completed 1003
cleanup_log 1003

# Variant: result object with non-end_turn stop_reason
write_log 1004 '{"type":"result","stop_reason":"max_tokens","terminal_reason":"completed"}'
assert_returns "result with non-end_turn stop_reason → false" 1 is_session_completed 1004
cleanup_log 1004

# TC-WH-005: non-claude AGENT_CMD returns false even with valid log content
write_log 1005 '{"type":"result","stop_reason":"end_turn","terminal_reason":"completed"}'
export AGENT_CMD=codex
assert_returns "AGENT_CMD=codex → false (only claude emits this format)" 1 is_session_completed 1005
export AGENT_CMD=kiro
assert_returns "AGENT_CMD=kiro → false" 1 is_session_completed 1005
export AGENT_CMD=claude
cleanup_log 1005

# TC-WH-006: missing log returns false
assert_returns "missing log file → false" 1 is_session_completed 9999

# Multiple result objects → use the latest (simulates resume cycles)
write_log 1006 '{"type":"result","stop_reason":"end_turn","terminal_reason":"completed"}
{"type":"result","stop_reason":"max_tokens","terminal_reason":"interrupted"}
'
assert_returns "multiple results → latest wins (interrupted)" 1 is_session_completed 1006

write_log 1007 '{"type":"result","stop_reason":"max_tokens","terminal_reason":"interrupted"}
{"type":"result","stop_reason":"end_turn","terminal_reason":"completed"}
'
assert_returns "multiple results → latest wins (completed)" 0 is_session_completed 1007
cleanup_log 1006
cleanup_log 1007

# Malformed JSON in result object → false (jq -e fails)
write_log 1008 '{"type":"result","stop_reason":'
assert_returns "malformed JSON → false" 1 is_session_completed 1008
cleanup_log 1008

# Result object with missing fields → false
write_log 1009 '{"type":"result"}'
assert_returns "result missing stop_reason and terminal_reason → false" 1 is_session_completed 1009
cleanup_log 1009

# Realistic Claude log shape: result with nested usage object AND model
# output containing `}` inside the .result string. Earlier regex
# `\{"type":"result"[^}]*\}` would truncate at the first inner `}` and the
# parse would fail — verifying the line-based extractor handles it.
write_log 1010 '[autonomous-dev] 21:41:15 Resuming session: abc-123
{"type":"result","subtype":"success","is_error":false,"duration_ms":138004,"num_turns":31,"result":"Done. The fix is `{...}` and the test passes.","stop_reason":"end_turn","session_id":"abc-123","total_cost_usd":0.33,"usage":{"input_tokens":168,"output_tokens":3982,"cache_creation":{"ephemeral_1h_input_tokens":0}},"permission_denials":[],"terminal_reason":"completed","uuid":"xyz"}
[autonomous-dev] 21:44:01 Agent exited with code: 0'
assert_returns "realistic Claude shape with nested usage and {} in result string → true" 0 is_session_completed 1010
cleanup_log 1010

# prompt_too_long: claude -p has no auto-compaction, so resume re-feeds the
# whole transcript and crashes again. The dispatcher must treat this as
# terminal so dispatcher-tick routes to a fresh session instead of looping.
# Behavior change: pre-Fix-3 returned 1 (retry-worthy); post-Fix-3 returns 0
# (terminal — caller flips label so next tick mints a fresh session).
write_log 1011 '{"type":"result","subtype":"success","is_error":true,"api_error_status":400,"result":"Prompt is too long","stop_reason":"stop_sequence","session_id":"abc","usage":{"input_tokens":0},"terminal_reason":"prompt_too_long"}'
assert_returns "prompt_too_long → terminal (no auto-compact in claude -p; force fresh)" 0 is_session_completed 1011
cleanup_log 1011

# Transient api_error (e.g. Bedrock 503, not a context overflow) should
# remain non-terminal — resume might succeed when the upstream recovers.
write_log 1013 '{"type":"result","subtype":"error","is_error":true,"api_error_status":503,"result":"Service unavailable","stop_reason":"end_turn","session_id":"abc","usage":{"input_tokens":1},"terminal_reason":"api_error"}'
assert_returns "api_error → not terminal (transient, resume worthwhile)" 1 is_session_completed 1013
cleanup_log 1013

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
