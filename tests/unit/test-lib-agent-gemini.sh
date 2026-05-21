#!/bin/bash
# test-lib-agent-gemini.sh — Unit tests for the gemini branches of
# lib-agent.sh.
#
# Originally introduced in #134 to lock in `--approval-mode yolo +
# --output-format stream-json` as hardcoded gemini flags. After #140
# those flags moved out of the wrapper and into operator conf via
# `AGENT_DEV_EXTRA_ARGS` / `AGENT_REVIEW_EXTRA_ARGS`. This file now
# verifies the structural-only contract:
#
#   - run_agent gemini branch invokes `gemini --session-id <uuid>
#     [--model <m>] [<EXTRA_ARGS>...] -p <prompt>` (no hardcoded yolo
#     or stream-json)
#   - When the operator supplies AGENT_DEV_EXTRA_ARGS with the canonical
#     gemini values, those flags ride along — confirming the migration
#     path matches the pre-#140 argv shape end-to-end
#   - resume_agent gemini branch invokes `gemini --resume <uuid> ...`
#     and accepts AGENT_REVIEW_EXTRA_ARGS the same way
#   - --model flag is conditional on AGENT_DEV_MODEL / AGENT_REVIEW_MODEL
#
# Strategy: mirror test-lib-agent-codex.sh — source lib-agent.sh in a
# sandbox with a stub `gemini` on PATH that records argv to a recorder
# file and emits a known JSONL payload.
#
# Run: bash tests/unit/test-lib-agent-gemini.sh

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

# ---------------------------------------------------------------------------
echo "=== TC-GEM-STATIC-001: source-of-truth grep — gemini branch shape ==="
# ---------------------------------------------------------------------------
# Cheap structural assertions before exercising behavior. Catches the
# refactor-drops-the-branch failure mode immediately.

# run_agent gemini case
if grep -qE '^[[:space:]]*gemini\)[[:space:]]*$' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: gemini case label present in lib-agent.sh"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: gemini case label missing in lib-agent.sh"
  FAIL=$((FAIL + 1))
fi

# Both run_agent and resume_agent must have a gemini case (count 2).
gemini_case_count=$(grep -cE '^[[:space:]]*gemini\)[[:space:]]*$' "$LIB" || echo 0)
assert_eq "lib-agent.sh has gemini case in both run_agent and resume_agent" \
  "2" "$gemini_case_count"

# ---------------------------------------------------------------------------
# Behavioral test sandbox setup
# ---------------------------------------------------------------------------
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PID_DIR="$TMPROOT/pid"
mkdir -p "$PID_DIR"
chmod 700 "$PID_DIR"

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

# Stub gemini: print argv + drain stdin to recorders, emit a known
# JSONL stream including a tool_use → error → result sequence so
# TC-GEM-008 can assert the capture filter doesn't strip the denial
# event. After #144 the prompt arrives via stdin.
cat > "$BIN/gemini" <<'EOF'
#!/bin/bash
echo "$@" > "$GEMINI_ARGS_FILE"
cat > "${GEMINI_STDIN_FILE:-/dev/null}"
cat <<JSONL
{"type":"init","timestamp":"2026-05-16T00:00:00Z","session_id":"replayed-by-stub","model":"gemini-2.5-pro"}
{"type":"tool_use","name":"run_shell_command","args":{"command":"git commit -m test"}}
{"type":"error","message":"Unauthorized tool call: 'run_shell_command' is not available to this agent."}
{"type":"result","timestamp":"2026-05-16T00:00:01Z","status":"success","stats":{"total_tokens":100}}
JSONL
EOF
chmod +x "$BIN/gemini"

# Stub timeout: run argv directly. Same shape as test-lib-agent-codex.sh.
# _run_with_timeout invokes us as: timeout --kill-after=30s --signal=TERM <DURATION> <CMD...>
cat > "$BIN/timeout" <<'EOF'
#!/bin/bash
shift 3
exec "$@"
EOF
chmod +x "$BIN/timeout"

ARGS_FILE="$TMPROOT/gemini-args"
STDIN_FILE="$TMPROOT/gemini-stdin"
SESSION_ID="a1b2c3d4-1111-2222-3333-444444444444"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GEM-001..003,005,008: run_agent default invocation ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"; : > "$STDIN_FILE"
run_agent_output=$(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=gemini \
  AGENT_PERMISSION_MODE=auto \
  AGENT_DEV_EXTRA_ARGS="--approval-mode yolo --output-format stream-json" \
  GEMINI_ARGS_FILE="$ARGS_FILE" \
  GEMINI_STDIN_FILE="$STDIN_FILE" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    run_agent "'"$SESSION_ID"'" "implement the thing" "" ""
  ' 2>&1
)
run_agent_rc=$?

assert_eq "run_agent gemini returns 0 on success" 0 "$run_agent_rc"

# TC-GEM-008 (hallucination defense): stdout pass-through preserves all
# four JSONL event types including the load-bearing `error` event for the
# tool-denial signal.
assert_contains "TC-GEM-008 stdout includes init event" \
  '"type":"init"' "$run_agent_output"
assert_contains "TC-GEM-008 stdout includes tool_use event" \
  '"type":"tool_use"' "$run_agent_output"
assert_contains "TC-GEM-008 stdout PRESERVES tool-denial error event" \
  "Unauthorized tool call" "$run_agent_output"
assert_contains "TC-GEM-008 stdout includes result event" \
  '"type":"result"' "$run_agent_output"

# Recover argv for the flag-composition assertions.
gemini_argv=$(cat "$ARGS_FILE")

# TC-GEM-001: --approval-mode yolo arrives via AGENT_DEV_EXTRA_ARGS
# passthrough (post-#140 the wrapper no longer hardcodes it).
assert_contains "TC-GEM-001 argv contains --approval-mode yolo (load-bearing, via EXTRA_ARGS)" \
  "--approval-mode yolo" "$gemini_argv"

# TC-GEM-002: --output-format stream-json arrives via EXTRA_ARGS too.
assert_contains "TC-GEM-002 argv contains --output-format stream-json (via EXTRA_ARGS)" \
  "--output-format stream-json" "$gemini_argv"

# TC-GEM-003: --session-id passes the dispatcher's UUID exactly.
assert_contains "TC-GEM-003 argv contains the literal session UUID" \
  "$SESSION_ID" "$gemini_argv"
assert_contains "TC-GEM-003 argv pairs --session-id with that UUID" \
  "--session-id $SESSION_ID" "$gemini_argv"

# TC-GEM-005: empty model → no --model / -m flag.
assert_not_contains "TC-GEM-005 argv does NOT contain --model when model empty" \
  "--model" "$gemini_argv"
# Defensive: also rule out the short form.
case " $gemini_argv " in
  *" -m "*)
    echo -e "  ${RED}FAIL${NC}: TC-GEM-005 argv contains -m short flag when model empty"
    FAIL=$((FAIL + 1))
    ;;
  *)
    echo -e "  ${GREEN}PASS${NC}: TC-GEM-005 argv does NOT contain -m when model empty"
    PASS=$((PASS + 1))
    ;;
esac

# After #144: prompt arrives via stdin, NOT argv. The wrapper feeds
# `printf '%s' "$prompt" | gemini ... -p` (no positional value after -p).
gemini_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)
assert_eq "stdin contains the prompt (post-#144 channel)" \
  "implement the thing" "$gemini_stdin"
assert_not_contains "argv does NOT carry the prompt as a positional" \
  "implement the thing" "$gemini_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GEM-004: run_agent with AGENT_DEV_MODEL=gemini-2.5-pro passes --model ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=gemini \
AGENT_PERMISSION_MODE=auto \
AGENT_DEV_EXTRA_ARGS="--approval-mode yolo --output-format stream-json" \
GEMINI_ARGS_FILE="$ARGS_FILE" \
GEMINI_STDIN_FILE="$STDIN_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "with model" "gemini-2.5-pro" ""
' >/dev/null 2>&1

model_argv=$(cat "$ARGS_FILE")
assert_contains "TC-GEM-004 argv contains --model gemini-2.5-pro" \
  "--model gemini-2.5-pro" "$model_argv"
assert_contains "TC-GEM-004 argv still has --approval-mode yolo with model set" \
  "--approval-mode yolo" "$model_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GEM-006,007: resume_agent uses --resume <session_id> ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"; : > "$STDIN_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=gemini \
AGENT_PERMISSION_MODE=auto \
AGENT_REVIEW_EXTRA_ARGS="--approval-mode yolo --output-format stream-json" \
GEMINI_ARGS_FILE="$ARGS_FILE" \
GEMINI_STDIN_FILE="$STDIN_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  source "'"$LIB"'"
  resume_agent "'"$SESSION_ID"'" "follow-up: address review feedback" "" ""
' >/dev/null 2>&1

resume_argv=$(cat "$ARGS_FILE")
resume_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)

# TC-GEM-006: --resume <same-uuid>, no sidecar needed.
assert_contains "TC-GEM-006 resume argv contains --resume + the dispatcher session UUID" \
  "--resume $SESSION_ID" "$resume_argv"

# TC-GEM-006 (load-bearing flags arrive via AGENT_REVIEW_EXTRA_ARGS):
# yolo + stream-json must survive on the resume path.
assert_contains "TC-GEM-006 resume argv keeps --approval-mode yolo (via REVIEW_EXTRA_ARGS)" \
  "--approval-mode yolo" "$resume_argv"
assert_contains "TC-GEM-006 resume argv keeps --output-format stream-json (via REVIEW_EXTRA_ARGS)" \
  "--output-format stream-json" "$resume_argv"

# After #144: resume prompt arrives via stdin, not argv.
assert_eq "TC-GEM-006 resume stdin contains follow-up prompt" \
  "follow-up: address review feedback" "$resume_stdin"
assert_not_contains "TC-GEM-006 resume argv does NOT carry the prompt positionally" \
  "follow-up: address review feedback" "$resume_argv"

# Resume must NOT also pass --session-id (would conflict with --resume).
assert_not_contains "TC-GEM-006 resume argv does NOT also pass --session-id" \
  "--session-id" "$resume_argv"

# TC-GEM-007: empty model on resume → no --model flag.
assert_not_contains "TC-GEM-007 resume argv does NOT contain --model when model empty" \
  "--model" "$resume_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
