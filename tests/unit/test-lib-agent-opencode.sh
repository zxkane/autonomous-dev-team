#!/bin/bash
# test-lib-agent-opencode.sh — Unit tests for the opencode branches of
# lib-agent.sh.
#
# Verifies:
#   - run_agent opencode branch invokes `opencode run --format json` (no -p)
#   - The sessionID from the opencode JSON stream is captured to a sidecar
#     under pid_dir_for_project(), keyed by the dispatcher's session_id
#   - resume_agent opencode branch reads the sidecar and invokes
#     `opencode run --session <sessionID>` with the follow-up prompt
#   - resume_agent falls back to run_agent when the sidecar is missing
#   - The capture filter is pass-through (does not corrupt stdout)
#   - --title is forwarded when session_name is provided
#
# JSON shape used in stubs is the actual format emitted by opencode v1.14.46
# (verified against `opencode run --format json --pure "test"`):
#   {"type":"step_start","timestamp":...,"sessionID":"ses_<base62>",...}
#
# Run: bash tests/unit/test-lib-agent-opencode.sh

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
echo "=== TC-LA-OC-01: source-of-truth grep — opencode branch shape ==="
# ---------------------------------------------------------------------------
if grep -qE '^\s*opencode\)\s*$' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: opencode case present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: opencode case missing"
  FAIL=$((FAIL + 1))
fi

if grep -q '"\$AGENT_CMD" run --format json' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: opencode invocation uses 'run --format json'"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: opencode invocation missing 'run --format json'"
  FAIL=$((FAIL + 1))
fi

if grep -q '"\$AGENT_CMD" run --format json --session' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: resume_agent opencode case calls 'run --session'"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: resume_agent opencode case missing 'run --session'"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LA-OC-02: behavioral — run_agent captures sessionID ==="
# ---------------------------------------------------------------------------
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PID_DIR="$TMPROOT/pid"
mkdir -p "$PID_DIR"
chmod 700 "$PID_DIR"

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

# Stub opencode: record argv + drain stdin to recorders, emit a known
# JSONL stream that mirrors the real opencode v1.14.46 output shape.
# After #144 the prompt arrives via stdin (`printf '%s' "$prompt" |`).
cat > "$BIN/opencode" <<'EOF'
#!/bin/bash
echo "$@" > "$OPENCODE_ARGS_FILE"
cat > "${OPENCODE_STDIN_FILE:-/dev/null}"
cat <<JSONL
{"type":"step_start","timestamp":1778415469963,"sessionID":"ses_TESTabc123XYZ456","part":{"id":"prt_a","messageID":"msg_b","sessionID":"ses_TESTabc123XYZ456","type":"step-start"}}
{"type":"text","timestamp":1778415470449,"sessionID":"ses_TESTabc123XYZ456","part":{"id":"prt_c","type":"text","text":"ok"}}
JSONL
EOF
chmod +x "$BIN/opencode"

# Same timeout stub as the codex tests.
cat > "$BIN/timeout" <<'EOF'
#!/bin/bash
shift 3
exec "$@"
EOF
chmod +x "$BIN/timeout"

ARGS_FILE="$TMPROOT/opencode-args"
STDIN_FILE="$TMPROOT/opencode-stdin"
SESSION_ID="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

run_output=$(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=opencode \
  AGENT_PERMISSION_MODE=auto \
  OPENCODE_ARGS_FILE="$ARGS_FILE" \
  OPENCODE_STDIN_FILE="$STDIN_FILE" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    run_agent "'"$SESSION_ID"'" "implement feature X" "" "issue-42-dev"
  ' 2>&1
)
run_rc=$?

assert_eq "run_agent opencode returns 0" 0 "$run_rc"
assert_contains "stdout includes step_start event"  '"step_start"' "$run_output"
assert_contains "stdout includes text event"        '"text"'       "$run_output"
assert_contains "stdout includes sessionID"         'ses_TESTabc123XYZ456' "$run_output"

sidecar="$PID_DIR/opencode-session-$SESSION_ID"
if [[ -f "$sidecar" ]]; then
  echo -e "  ${GREEN}PASS${NC}: sidecar created at expected path"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: sidecar not created at $sidecar"
  FAIL=$((FAIL + 1))
fi
assert_eq "sidecar contains the captured sessionID" \
  "ses_TESTabc123XYZ456" "$(cat "$sidecar" 2>/dev/null)"

opencode_argv=$(cat "$ARGS_FILE")
assert_contains "argv contains 'run'"         "run"         "$opencode_argv"
assert_contains "argv contains '--format json'" "--format json" "$opencode_argv"
# After #144: prompt arrives via stdin, NOT argv.
assert_not_contains "argv does NOT carry the prompt positionally" \
  "implement feature X" "$opencode_argv"
opencode_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)
assert_eq "stdin contains the prompt (post-#144 channel)" \
  "implement feature X" "$opencode_stdin"
assert_contains "argv forwards --title from session_name" "--title issue-42-dev" "$opencode_argv"
assert_not_contains "argv does NOT use legacy -p" "-p" "$opencode_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LA-OC-03: resume_agent uses captured sessionID ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"; : > "$STDIN_FILE"

resume_output=$(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=opencode \
  AGENT_PERMISSION_MODE=auto \
  OPENCODE_ARGS_FILE="$ARGS_FILE" \
  OPENCODE_STDIN_FILE="$STDIN_FILE" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    resume_agent "'"$SESSION_ID"'" "address review feedback" "" ""
  ' 2>&1
)
resume_rc=$?

assert_eq "resume_agent opencode returns 0" 0 "$resume_rc"

resume_argv=$(cat "$ARGS_FILE")
assert_contains "resume argv contains 'run'"             "run"         "$resume_argv"
assert_contains "resume argv contains '--session'"       "--session"   "$resume_argv"
assert_contains "resume argv contains the captured sid"  "ses_TESTabc123XYZ456" "$resume_argv"
# After #144: resume prompt arrives via stdin.
assert_not_contains "resume argv does NOT carry the follow-up prompt positionally" \
  "address review feedback" "$resume_argv"
resume_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)
assert_eq "resume stdin contains the follow-up prompt" \
  "address review feedback" "$resume_stdin"
assert_not_contains "resume argv does NOT use legacy -p" "-p" "$resume_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LA-OC-04: resume falls back when sidecar missing ==="
# ---------------------------------------------------------------------------
NEW_SESSION_ID="11111111-2222-3333-4444-555555555555"
: > "$ARGS_FILE"; : > "$STDIN_FILE"

fallback_output=$(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=opencode \
  AGENT_PERMISSION_MODE=auto \
  OPENCODE_ARGS_FILE="$ARGS_FILE" \
  OPENCODE_STDIN_FILE="$STDIN_FILE" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    resume_agent "'"$NEW_SESSION_ID"'" "fresh prompt" "" ""
  ' 2>&1
)
fallback_rc=$?

assert_eq "fallback resume_agent returns 0" 0 "$fallback_rc"
assert_contains "fallback writes diagnostic about missing sessionID" \
  "no captured opencode sessionID" "$fallback_output"

fallback_argv=$(cat "$ARGS_FILE")
assert_contains "fallback argv contains 'run'" "run" "$fallback_argv"
assert_not_contains "fallback argv does NOT contain '--session'" \
  "--session" "$fallback_argv"
# After #144: prompt arrives via stdin in the fallback path too.
assert_not_contains "fallback argv does NOT carry the fresh prompt positionally" \
  "fresh prompt" "$fallback_argv"
fallback_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)
assert_eq "fallback stdin contains the fresh prompt" \
  "fresh prompt" "$fallback_stdin"

new_sidecar="$PID_DIR/opencode-session-$NEW_SESSION_ID"
if [[ -f "$new_sidecar" ]]; then
  echo -e "  ${GREEN}PASS${NC}: fallback created sidecar for new session_id"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: fallback did not create sidecar for new session_id"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LA-OC-05: capture is robust to no JSON event ==="
# ---------------------------------------------------------------------------
# Replace stub: no JSONL output, just stderr + non-zero exit (e.g. auth fail).
# Drain stdin so the leading printf stage doesn't get SIGPIPE (which
# pipefail would surface as 141 instead of the intended 5).
cat > "$BIN/opencode" <<'EOF'
#!/bin/bash
echo "$@" > "$OPENCODE_ARGS_FILE"
cat > "${OPENCODE_STDIN_FILE:-/dev/null}"
echo "ERROR: not authenticated" >&2
exit 5
EOF

CRASH_SESSION_ID="22222222-aaaa-bbbb-cccc-333333333333"
: > "$ARGS_FILE"; : > "$STDIN_FILE"

crash_output=$(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=opencode \
  AGENT_PERMISSION_MODE=auto \
  OPENCODE_ARGS_FILE="$ARGS_FILE" \
  OPENCODE_STDIN_FILE="$STDIN_FILE" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    run_agent "'"$CRASH_SESSION_ID"'" "crashy prompt" "" ""
  ' 2>&1
)
crash_rc=$?

assert_eq "run_agent surfaces opencode crash exit code" 5 "$crash_rc"

crash_sidecar="$PID_DIR/opencode-session-$CRASH_SESSION_ID"
if [[ ! -f "$crash_sidecar" ]]; then
  echo -e "  ${GREEN}PASS${NC}: no sidecar created when no sessionID arrived"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: sidecar incorrectly created on crash path"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LA-OC-06: malformed sessionID in sidecar is rejected ==="
# ---------------------------------------------------------------------------
# Manually plant a malformed sidecar and confirm _opencode_session_id refuses
# it (so resume_agent falls back to run_agent rather than passing garbage to
# `opencode run --session ...`). Defense-in-depth on top of the awk-side
# regex; cheap to test.
BAD_SESSION_ID="33333333-bad0-bad0-bad0-444444444444"
bad_sidecar="$PID_DIR/opencode-session-$BAD_SESSION_ID"
echo 'ses_with;injection`hazard' > "$bad_sidecar"

# Restore working stub for this test (resume_agent will fall back to run, so
# we want the stub to succeed). Drain stdin too so the leading printf
# stage doesn't SIGPIPE.
cat > "$BIN/opencode" <<'EOF'
#!/bin/bash
echo "$@" > "$OPENCODE_ARGS_FILE"
cat > "${OPENCODE_STDIN_FILE:-/dev/null}"
cat <<JSONL
{"type":"step_start","sessionID":"ses_FRESHsessionID999"}
JSONL
EOF
: > "$ARGS_FILE"; : > "$STDIN_FILE"

malformed_output=$(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=opencode \
  AGENT_PERMISSION_MODE=auto \
  OPENCODE_ARGS_FILE="$ARGS_FILE" \
  OPENCODE_STDIN_FILE="$STDIN_FILE" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    resume_agent "'"$BAD_SESSION_ID"'" "after bad sidecar" "" ""
  ' 2>&1
)

assert_contains "malformed sidecar triggers fallback diagnostic" \
  "no captured opencode sessionID" "$malformed_output"

malformed_argv=$(cat "$ARGS_FILE")
assert_not_contains "malformed sid not passed to opencode argv" \
  "ses_with" "$malformed_argv"
assert_not_contains "malformed sid not passed via --session" \
  "--session" "$malformed_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
