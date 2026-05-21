#!/bin/bash
# test-lib-agent-codex.sh — Unit tests for the codex branches of
# lib-agent.sh after the legacy `-p` → `codex exec` migration.
#
# Verifies:
#   - run_agent codex branch invokes `codex exec --json [PROMPT]` (not -p)
#   - The thread_id from the codex JSON stream is captured to a sidecar
#     under pid_dir_for_project(), keyed by the dispatcher's session_id
#   - resume_agent codex branch reads the sidecar and invokes
#     `codex exec resume <thread_id> [PROMPT]`
#   - resume_agent falls back to run_agent when the sidecar is missing
#   - The capture filter is pass-through (does not corrupt stdout)
#
# Strategy: source lib-agent.sh in a sandbox with a stub `codex` on PATH
# that records its argv to a recorder file and emits a known JSONL payload
# that includes thread.started.
#
# Run: bash tests/unit/test-lib-agent-codex.sh

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
echo "=== TC-LA-CODEX-01: source-of-truth grep — codex branch shape ==="
# ---------------------------------------------------------------------------
# Cheap structural assertions before exercising behavior.

if grep -qE '^\s*codex\)\s*$' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: codex case still present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: codex case missing"
  FAIL=$((FAIL + 1))
fi

# The legacy `codex ... -p "$prompt"` form is what we're removing. The
# generic `*)` fallback below the codex case still uses `<cli> -p <prompt>`
# correctly for non-codex CLIs, so a whole-file grep would false-positive.
# Scope the check to just the run_agent codex case body.
codex_case_body=$(awk '
  /^[[:space:]]*codex\)[[:space:]]*$/,/^[[:space:]]*;;[[:space:]]*$/
' "$LIB" | head -40)
if [[ "$codex_case_body" != *'-p "$prompt"'* ]]; then
  echo -e "  ${GREEN}PASS${NC}: codex case does not invoke 'codex -p \"\$prompt\"'"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: codex case still uses legacy '-p \$prompt'"
  FAIL=$((FAIL + 1))
fi

# The new exec invocation must be there and use --json.
if grep -q '"\$AGENT_CMD" exec --json' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: new 'codex exec --json' invocation present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: new 'codex exec --json' invocation missing"
  FAIL=$((FAIL + 1))
fi

# resume_agent codex case must call `exec resume`.
if grep -q '"\$AGENT_CMD" exec resume' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: resume_agent codex case calls 'codex exec resume'"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: resume_agent codex case missing 'codex exec resume'"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LA-CODEX-02: behavioral — run_agent captures thread_id ==="
# ---------------------------------------------------------------------------
# Build a sandbox: AUTONOMOUS_PID_DIR override + a stub `codex` on PATH that
# records argv and emits a known JSONL stream.
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PID_DIR="$TMPROOT/pid"
mkdir -p "$PID_DIR"
chmod 700 "$PID_DIR"

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

# Stub codex: print argv + drain stdin to recorders, emit thread.started
# + a simple completion event. Honors --json by emitting JSONL only.
# After #144 the prompt arrives via stdin — the wrapper feeds it as a
# leading `printf '%s' "$prompt" |` pipeline stage.
cat > "$BIN/codex" <<'EOF'
#!/bin/bash
echo "$@" > "$CODEX_ARGS_FILE"
cat > "${CODEX_STDIN_FILE:-/dev/null}"
cat <<JSONL
{"type":"thread.started","thread_id":"019e1234-aaaa-bbbb-cccc-deadbeefcafe"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"ok"}}
{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}
JSONL
EOF
chmod +x "$BIN/codex"

# Stub timeout: run argv directly (no real wall-clock cap needed for tests).
# _run_with_timeout invokes us as: timeout --kill-after=30s --signal=TERM <DURATION> <CMD...>
# That's 3 leading args before the real command.
cat > "$BIN/timeout" <<'EOF'
#!/bin/bash
shift 3
exec "$@"
EOF
chmod +x "$BIN/timeout"

# Source lib-agent in a subshell with the sandbox set up.
ARGS_FILE="$TMPROOT/codex-args"
STDIN_FILE="$TMPROOT/codex-stdin"
SESSION_ID="22222222-3333-4444-5555-666666666666"

run_agent_output=$(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=codex \
  AGENT_PERMISSION_MODE=auto \
  CODEX_ARGS_FILE="$ARGS_FILE" \
  CODEX_STDIN_FILE="$STDIN_FILE" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    run_agent "'"$SESSION_ID"'" "implement the thing" "" ""
  ' 2>&1
)
run_agent_rc=$?

assert_eq "run_agent codex returns 0 on success" 0 "$run_agent_rc"

# stdout must be pass-through: every JSON line we emitted should appear.
assert_contains "stdout includes thread.started event" \
  '"thread.started"' "$run_agent_output"
assert_contains "stdout includes turn.completed event" \
  '"turn.completed"' "$run_agent_output"

# Sidecar must exist and contain the captured thread_id.
sidecar="$PID_DIR/codex-thread-$SESSION_ID"
if [[ -f "$sidecar" ]]; then
  echo -e "  ${GREEN}PASS${NC}: sidecar file created at expected path"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: sidecar not created at $sidecar"
  FAIL=$((FAIL + 1))
fi
assert_eq "sidecar contains the thread_id from JSONL" \
  "019e1234-aaaa-bbbb-cccc-deadbeefcafe" "$(cat "$sidecar" 2>/dev/null)"

# codex argv must use the new shape: `exec --json ... -` (stdin marker
# in place of the old positional prompt). After #144 the prompt arrives
# on stdin, not argv.
codex_argv=$(cat "$ARGS_FILE")
assert_contains "codex argv contains 'exec'"   "exec"        "$codex_argv"
assert_contains "codex argv contains '--json'" "--json"      "$codex_argv"
assert_contains "codex argv ends with the stdin marker '-'" \
  "-" "$codex_argv"
assert_not_contains "codex argv does NOT carry the prompt positionally" \
  "implement the thing" "$codex_argv"

# After #144: prompt arrives via stdin.
codex_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)
assert_eq "codex stdin contains the prompt" \
  "implement the thing" "$codex_stdin"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LA-CODEX-03: behavioral — resume_agent uses captured thread_id ==="
# ---------------------------------------------------------------------------
# Same sandbox; sidecar is already populated by TC-LA-CODEX-02.
: > "$ARGS_FILE"; : > "$STDIN_FILE"

resume_output=$(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=codex \
  AGENT_PERMISSION_MODE=auto \
  CODEX_ARGS_FILE="$ARGS_FILE" \
  CODEX_STDIN_FILE="$STDIN_FILE" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    resume_agent "'"$SESSION_ID"'" "follow-up: address review feedback" "" ""
  ' 2>&1
)
resume_rc=$?

assert_eq "resume_agent codex returns 0" 0 "$resume_rc"

resume_argv=$(cat "$ARGS_FILE")
assert_contains "resume argv contains 'exec resume'" \
  "exec resume" "$resume_argv"
assert_contains "resume argv contains the captured thread_id" \
  "019e1234-aaaa-bbbb-cccc-deadbeefcafe" "$resume_argv"
assert_contains "resume argv contains '--json'" "--json" "$resume_argv"
assert_not_contains "resume argv does NOT carry the prompt positionally" \
  "follow-up: address review feedback" "$resume_argv"
assert_not_contains "resume argv does NOT use legacy -p" "-p" "$resume_argv"

# After #144: resume prompt arrives via stdin.
resume_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)
assert_eq "resume stdin contains the follow-up prompt" \
  "follow-up: address review feedback" "$resume_stdin"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LA-CODEX-04: resume falls back to new run when sidecar missing ==="
# ---------------------------------------------------------------------------
# Use a fresh session_id that has no sidecar.
NEW_SESSION_ID="99999999-aaaa-bbbb-cccc-dddddddddddd"
: > "$ARGS_FILE"; : > "$STDIN_FILE"

fallback_output=$(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=codex \
  AGENT_PERMISSION_MODE=auto \
  CODEX_ARGS_FILE="$ARGS_FILE" \
  CODEX_STDIN_FILE="$STDIN_FILE" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    resume_agent "'"$NEW_SESSION_ID"'" "fresh prompt" "" ""
  ' 2>&1
)
fallback_rc=$?

assert_eq "fallback resume_agent returns 0" 0 "$fallback_rc"
assert_contains "fallback writes diagnostic about missing thread_id" \
  "no captured codex thread_id" "$fallback_output"

# Argv should be the run_agent shape (`exec --json -`), not `exec resume`.
fallback_argv=$(cat "$ARGS_FILE")
assert_contains "fallback argv contains 'exec'" "exec" "$fallback_argv"
assert_not_contains "fallback argv does NOT contain 'resume'" \
  "resume" "$fallback_argv"
assert_not_contains "fallback argv does NOT carry the prompt positionally" \
  "fresh prompt" "$fallback_argv"

# After #144: prompt arrives via stdin in the fallback path too.
fallback_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)
assert_eq "fallback stdin contains the fresh prompt" \
  "fresh prompt" "$fallback_stdin"

# A new sidecar should now exist for the fresh session_id.
new_sidecar="$PID_DIR/codex-thread-$NEW_SESSION_ID"
if [[ -f "$new_sidecar" ]]; then
  echo -e "  ${GREEN}PASS${NC}: fallback created sidecar for the new session_id"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: fallback did not create sidecar for the new session_id"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LA-CODEX-05: capture is robust to no thread.started event ==="
# ---------------------------------------------------------------------------
# Replace stub codex with one that crashes before emitting thread.started.
# Drains stdin so the leading `printf '%s' "$prompt" |` stage doesn't get
# SIGPIPE before producing — otherwise pipefail surfaces 141 instead of 7.
cat > "$BIN/codex" <<'EOF'
#!/bin/bash
echo "$@" > "$CODEX_ARGS_FILE"
cat > "${CODEX_STDIN_FILE:-/dev/null}"
echo '{"type":"error","message":"auth failed"}'
exit 7
EOF

CRASH_SESSION_ID="abcdef00-1111-2222-3333-444444444444"
: > "$ARGS_FILE"; : > "$STDIN_FILE"

crash_output=$(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=codex \
  AGENT_PERMISSION_MODE=auto \
  CODEX_ARGS_FILE="$ARGS_FILE" \
  CODEX_STDIN_FILE="$STDIN_FILE" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    run_agent "'"$CRASH_SESSION_ID"'" "crashy prompt" "" ""
  ' 2>&1
)
crash_rc=$?

assert_eq "run_agent surfaces codex crash exit code" 7 "$crash_rc"

crash_sidecar="$PID_DIR/codex-thread-$CRASH_SESSION_ID"
if [[ ! -f "$crash_sidecar" ]]; then
  echo -e "  ${GREEN}PASS${NC}: no sidecar created when thread.started never arrived"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: sidecar incorrectly created on crash path"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
