#!/bin/bash
# test-lib-agent-agy.sh — Unit tests for the agy branches of
# lib-agent.sh (Antigravity 2.0 CLI support, INV-36).
#
# Verifies:
#   - run_agent agy branch invokes `agy -p --dangerously-skip-permissions
#     --print-timeout <timeout> --log-file <path>` (stdin prompt, INV-34)
#   - The conversation UUID is grepped from the log file and captured
#     to a sidecar under pid_dir_for_project(), keyed by session_id
#   - resume_agent agy branch reads the sidecar and invokes
#     `agy --conversation <uuid> -p ...`
#   - resume_agent falls back to run_agent when the sidecar is missing
#   - Non-empty `model` arg emits one-time WARN, execution continues
#   - Capture is best-effort (INV-36): missing log line / symlink sidecar
#     do not fail run_agent
#
# Strategy: source lib-agent.sh in a sandbox with a stub `agy` on PATH
# that records argv to a recorder file and writes a fixed log file with
# a `Print mode: conversation=<UUID>` line.
#
# Run: bash tests/unit/test-lib-agent-agy.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected='$expected'"
    echo "      actual=  '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    echo "      haystack='${haystack:0:300}'"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      should not contain: '$needle'"
    FAIL=$((FAIL + 1))
  fi
}

# Placeholder — test cases land in subsequent steps.
echo "=== test-lib-agent-agy.sh — scaffolding only (test cases follow) ==="

# ---------------------------------------------------------------------------
echo "=== AGY-S1: source-of-truth — helper functions exist ==="
# ---------------------------------------------------------------------------

if grep -qE '^_agy_log_file\(\)' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: _agy_log_file defined"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: _agy_log_file missing"
  FAIL=$((FAIL + 1))
fi

if grep -qE '^_agy_conversation_file\(\)' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: _agy_conversation_file defined"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: _agy_conversation_file missing"
  FAIL=$((FAIL + 1))
fi

if grep -qE '^_agy_capture_conversation\(\)' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: _agy_capture_conversation defined"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: _agy_capture_conversation missing"
  FAIL=$((FAIL + 1))
fi

if grep -qE '^_agy_conversation_id\(\)' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: _agy_conversation_id defined"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: _agy_conversation_id missing"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-S2: behavioral — _agy_capture_conversation writes sidecar ==="
# ---------------------------------------------------------------------------
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PID_DIR="$TMPROOT/pid"
mkdir -p "$PID_DIR"
chmod 700 "$PID_DIR"

# Fixture log line copied from a real `agy -p` run.
cat > "$TMPROOT/agy.log" <<'EOF'
I0524 22:56:05.692100 1234 input.go:42] Starting print mode
I0524 22:56:05.692112 1234 printmode.go:130] Print mode: conversation=f41baebb-89f5-4c15-9dae-35c2adde4e32, sending message
I0524 22:56:08.236212 1234 input_loop.go:499] Auth done received
EOF

SESSION_ID="11111111-2222-3333-4444-555555555555"

(
  PATH="$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    _agy_capture_conversation "'"$SESSION_ID"'" "'"$TMPROOT"'/agy.log"
  '
)

sidecar="$PID_DIR/agy-conversation-$SESSION_ID"
if [[ -f "$sidecar" ]]; then
  echo -e "  ${GREEN}PASS${NC}: sidecar created at $sidecar"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: sidecar missing at $sidecar"
  FAIL=$((FAIL + 1))
fi
assert_eq "sidecar contains UUID from log" \
  "f41baebb-89f5-4c15-9dae-35c2adde4e32" \
  "$(cat "$sidecar" 2>/dev/null)"

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-S3: best-effort — log without match leaves sidecar absent (INV-36) ==="
# ---------------------------------------------------------------------------
SESSION_ID2="22222222-bbbb-cccc-dddd-eeeeeeeeeeee"
cat > "$TMPROOT/agy-nomatch.log" <<'EOF'
I0524 22:56:05.692100 1234 input.go:42] Starting print mode
I0524 22:56:05.692112 1234 something.go:99] Some other line
EOF

(
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    _agy_capture_conversation "'"$SESSION_ID2"'" "'"$TMPROOT"'/agy-nomatch.log"
  '
)

sidecar2="$PID_DIR/agy-conversation-$SESSION_ID2"
if [[ ! -e "$sidecar2" ]]; then
  echo -e "  ${GREEN}PASS${NC}: sidecar absent for log without match"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: sidecar should be absent but exists"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-S4: CWE-59 — symlink sidecar is refused with WARN ==="
# ---------------------------------------------------------------------------
SESSION_ID3="33333333-cccc-dddd-eeee-ffffffffffff"
# Pre-create the sidecar path as a symlink pointing at /etc/passwd.
ln -s /etc/passwd "$PID_DIR/agy-conversation-$SESSION_ID3"

stderr_capture=$(
  (
    AUTONOMOUS_PID_DIR="$PID_DIR" \
    PROJECT_ID="testproj" \
    PROJECT_DIR="$TMPROOT" \
    AGENT_CMD=agy \
    bash -c '
      unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
      source "'"$LIB"'"
      _agy_capture_conversation "'"$SESSION_ID3"'" "'"$TMPROOT"'/agy.log"
    '
  ) 2>&1 1>/dev/null
)

# /etc/passwd content must NOT have been overwritten — readlink still
# points at /etc/passwd, and the actual file is unchanged. We just check
# the symlink wasn't resolved-and-overwritten by inspecting that the
# target is intact (assert head -1 is still root:).
target_first_line=$(head -1 /etc/passwd 2>/dev/null)
assert_contains "/etc/passwd not overwritten by symlink-following write" \
  "root:" "$target_first_line"
assert_contains "WARN logged for symlink refusal" \
  "is a symlink; refusing to write" "$stderr_capture"

echo ""
echo "PASS: $PASS    FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
