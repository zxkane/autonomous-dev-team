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
#   - `--model` is forwarded ONLY for a known agy model (validated via
#     `_agy_known_model` against `agy models`, INV-50): unknown → omitted
#     + one-time WARN; enumeration failure → best-effort pass-through;
#     empty → no --model (AGY-06a/06b/06b2/06b3, TC-AGYM-KM, AGY-06c/06d)
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

echo "=== test-lib-agent-agy.sh — agy sidecar helpers (S1-S4 + S5) ==="

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

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-S5: _agy_conversation_id refuses symlink + validates format ==="
# ---------------------------------------------------------------------------
# Reuse SESSION_ID3 — its sidecar is a symlink to /etc/passwd from AGY-S4.
S5_OUT=$(
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    _agy_conversation_id "'"$SESSION_ID3"'"
    echo "rc=$?"
  ' 2>/dev/null
)
assert_contains "_agy_conversation_id refuses symlink (rc=1)" "rc=1" "$S5_OUT"
assert_not_contains "_agy_conversation_id does not leak symlink target content" "root:" "$S5_OUT"

# Now: write a corrupted sidecar (not a UUID) and confirm format rejection.
SESSION_ID5="55555555-aaaa-bbbb-cccc-ffffffffffff"
echo "not a uuid; semicolons; rm -rf /" > "$PID_DIR/agy-conversation-$SESSION_ID5"
S5B_OUT=$(
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    _agy_conversation_id "'"$SESSION_ID5"'"
    echo "rc=$?"
  ' 2>/dev/null
)
assert_contains "_agy_conversation_id rejects non-UUID sidecar content (rc=1)" "rc=1" "$S5B_OUT"
assert_not_contains "_agy_conversation_id does not echo corrupted content" "rm -rf" "$S5B_OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-01/02: run_agent agy branch — stdin prompt + structural flags ==="
# ---------------------------------------------------------------------------
BIN="$TMPROOT/bin"
mkdir -p "$BIN"

# Stub agy: record argv + drain stdin to recorders, then write a fake
# log file at the path requested via --log-file containing the
# Print mode line. Exits 0.
#
# The `models` subcommand (`agy models`) prints a fixed listing so the
# wrapper's _agy_known_model can enumerate. Set AGY_MODELS_FAIL=1 (in the
# stub's environment) to make `agy models` exit non-zero — exercises the
# enumeration-failure best-effort-passthrough path (AGY-06b3).
cat > "$BIN/agy" <<'STUB'
#!/bin/bash
if [[ "${1:-}" == "models" ]]; then
  if [[ -n "${AGY_MODELS_FAIL:-}" ]]; then
    exit 1
  fi
  cat <<'MODELS'
Gemini 3.5 Flash (Medium)
Gemini 3.5 Flash (High)
Gemini 3.5 Flash (Low)
Gemini 3.1 Pro (Low)
Gemini 3.1 Pro (High)
Claude Sonnet 4.6 (Thinking)
Claude Opus 4.6 (Thinking)
GPT-OSS 120B (Medium)
MODELS
  exit 0
fi
echo "$@" > "$AGY_ARGS_FILE"
cat > "${AGY_STDIN_FILE:-/dev/null}"
# Find --log-file argument and write a fixture log there.
log_file=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--log-file" ]]; then
    log_file="$arg"
    break
  fi
  prev="$arg"
done
if [[ -n "$log_file" ]]; then
  cat > "$log_file" <<EOF
I0524 22:56:05.692112 1234 printmode.go:130] Print mode: conversation=${AGY_FAKE_UUID:-aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb}, sending message
EOF
fi
exit 0
STUB
chmod +x "$BIN/agy"

# Stub timeout: pass through, drop the leading 3 args (--kill-after,
# --signal, DURATION).
cat > "$BIN/timeout" <<'STUB'
#!/bin/bash
shift 3
exec "$@"
STUB
chmod +x "$BIN/timeout"

ARGS_FILE="$TMPROOT/agy-args"
STDIN_FILE="$TMPROOT/agy-stdin"
SESSION_ID4="44444444-aaaa-bbbb-cccc-dddddddddddd"
FAKE_UUID="deadbeef-cafe-4000-8111-1111aaaa2222"

# Capture stdout+stderr to keep them out of the test report; we only
# assert on argv/stdin recorders and the exit code below.
PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  AGENT_PERMISSION_MODE=auto \
  AGENT_TIMEOUT=4h \
  AGY_ARGS_FILE="$ARGS_FILE" \
  AGY_STDIN_FILE="$STDIN_FILE" \
  AGY_FAKE_UUID="$FAKE_UUID" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    run_agent "'"$SESSION_ID4"'" "implement the agy thing" "" ""
  ' >/dev/null 2>&1
run_rc=$?

assert_eq "run_agent agy returns 0 on success" 0 "$run_rc"

agy_argv=$(cat "$ARGS_FILE")
assert_contains "agy argv contains -p"                          "-p"                              "$agy_argv"
assert_contains "agy argv contains --dangerously-skip-permissions" "--dangerously-skip-permissions" "$agy_argv"
assert_contains "agy argv contains --print-timeout 4h"          "--print-timeout 4h"              "$agy_argv"
assert_contains "agy argv contains --log-file under PID_DIR"    "--log-file $PID_DIR/agy-log-$SESSION_ID4.log" "$agy_argv"
assert_not_contains "agy argv does NOT carry the prompt positionally" \
  "implement the agy thing" "$agy_argv"

agy_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)
assert_eq "agy stdin contains the prompt (INV-34)" \
  "implement the agy thing" "$agy_stdin"

# AGY-03: sidecar populated from the fake log line written by the stub.
sidecar4="$PID_DIR/agy-conversation-$SESSION_ID4"
if [[ -f "$sidecar4" ]]; then
  echo -e "  ${GREEN}PASS${NC}: AGY-03 — sidecar populated post-run"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: AGY-03 — sidecar missing at $sidecar4"
  FAIL=$((FAIL + 1))
fi
assert_eq "AGY-03 — sidecar contains UUID from stub-written log" \
  "$FAKE_UUID" "$(cat "$sidecar4" 2>/dev/null)"

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-04: resume_agent agy branch — uses captured conversation UUID ==="
# ---------------------------------------------------------------------------
# Reuse the sandbox from AGY-01/02/03 — sidecar4 is already populated
# from the prior run_agent invocation.
: > "$ARGS_FILE"
: > "$STDIN_FILE"

PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  AGENT_PERMISSION_MODE=auto \
  AGENT_TIMEOUT=4h \
  AGY_ARGS_FILE="$ARGS_FILE" \
  AGY_STDIN_FILE="$STDIN_FILE" \
  AGY_FAKE_UUID="$FAKE_UUID" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    resume_agent "'"$SESSION_ID4"'" "address review feedback" "" ""
  ' >/dev/null 2>&1
resume_rc=$?

assert_eq "resume_agent agy returns 0 on success" 0 "$resume_rc"

agy_argv=$(cat "$ARGS_FILE")
assert_contains "resume agy argv contains --conversation <UUID>" \
  "--conversation $FAKE_UUID" "$agy_argv"
assert_contains "resume agy argv still contains -p"                          "-p"                              "$agy_argv"
assert_contains "resume agy argv still contains --dangerously-skip-permissions" "--dangerously-skip-permissions" "$agy_argv"
assert_contains "resume agy argv still contains --log-file"                  "--log-file"                      "$agy_argv"

agy_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)
assert_eq "resume agy stdin contains the new prompt" \
  "address review feedback" "$agy_stdin"

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-05: resume_agent without sidecar — falls back to run_agent ==="
# ---------------------------------------------------------------------------
SESSION_ID5="55555555-eeee-ffff-aaaa-bbbbbbbbbbbb"  # No sidecar pre-populated.
: > "$ARGS_FILE"
: > "$STDIN_FILE"

fallback_stderr=$(
  (
    PATH="$BIN:$PATH" \
    AUTONOMOUS_PID_DIR="$PID_DIR" \
    PROJECT_ID="testproj" \
    PROJECT_DIR="$TMPROOT" \
    AGENT_CMD=agy \
    AGENT_PERMISSION_MODE=auto \
    AGENT_TIMEOUT=4h \
    AGY_ARGS_FILE="$ARGS_FILE" \
    AGY_STDIN_FILE="$STDIN_FILE" \
    AGY_FAKE_UUID="fa11bac4-aaaa-4bbb-8ccc-cccccccccccc" \
    bash -c '
      unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
      source "'"$LIB"'"
      resume_agent "'"$SESSION_ID5"'" "fresh start" "" ""
    '
  ) 2>&1 1>/dev/null
)

agy_argv=$(cat "$ARGS_FILE")
assert_contains "fallback stderr mentions 'no captured agy conversation_id'" \
  "no captured agy conversation_id" "$fallback_stderr"
assert_not_contains "fallback argv does NOT contain --conversation" \
  "--conversation" "$agy_argv"
# After fallback to run_agent, the new sidecar is created.
sidecar5="$PID_DIR/agy-conversation-$SESSION_ID5"
if [[ -f "$sidecar5" ]]; then
  echo -e "  ${GREEN}PASS${NC}: fallback created a new sidecar"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: fallback did not create new sidecar"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-06a: known agy model → forwarded via --model (single argv elem) ==="
# ---------------------------------------------------------------------------
# Issue #190: agy now honors --model. A model that `agy models` lists is
# forwarded; a multi-word name reaches the CLI as ONE argv element.
SESSION_ID6="66666666-1234-1234-1234-123456789012"
KNOWN_MODEL="Gemini 3.5 Flash (High)"
: > "$ARGS_FILE"
: > "$STDIN_FILE"

run_06a() {
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  AGENT_PERMISSION_MODE=auto \
  AGENT_TIMEOUT=4h \
  AGY_ARGS_FILE="$ARGS_FILE" \
  AGY_STDIN_FILE="$STDIN_FILE" \
  AGY_FAKE_UUID="20de1aaa-aaaa-4bbb-8ccc-cccccccccccc" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE \
          _LIB_AGENT_AGY_MODEL_WARNED _LIB_AGENT_AGY_MODELS_CACHE
    source "'"$LIB"'"
    run_agent "'"$SESSION_ID6"'" "with known model" "'"$KNOWN_MODEL"'" ""
  '
}
run_06a >/dev/null 2>&1
agy06a_rc=$?
assert_eq "AGY-06a — run_agent rc 0 with known model" 0 "$agy06a_rc"
agy_argv=$(cat "$ARGS_FILE")
assert_contains "AGY-06a — argv contains --model" "--model" "$agy_argv"
assert_contains "AGY-06a — argv contains the known model name" "$KNOWN_MODEL" "$agy_argv"

# Single-argv-element check: a wordsplit of the recorded argv must keep
# "Gemini 3.5 Flash (High)" intact AS THE TOKEN AFTER --model. We re-run
# with the `agy` stub temporarily swapped for a NUL-delimited recorder
# (renaming the command would miss the agy case branch, which matches the
# literal `agy`). Restore the real stub afterwards.
NUL_ARGS="$TMPROOT/agy-args-nul"
cat > "$BIN/agy-nul" <<'STUB'
#!/bin/bash
if [[ "${1:-}" == "models" ]]; then
  cat <<'MODELS'
Gemini 3.5 Flash (High)
MODELS
  exit 0
fi
printf '%s\0' "$@" > "$AGY_NUL_ARGS_FILE"
cat > /dev/null
exit 0
STUB
chmod +x "$BIN/agy-nul"
mv "$BIN/agy" "$BIN/agy.real-06a"
ln -sf "$BIN/agy-nul" "$BIN/agy"
: > "$NUL_ARGS"
PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  AGENT_PERMISSION_MODE=auto \
  AGENT_TIMEOUT=4h \
  AGY_NUL_ARGS_FILE="$NUL_ARGS" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE \
          _LIB_AGENT_AGY_MODEL_WARNED _LIB_AGENT_AGY_MODELS_CACHE
    source "'"$LIB"'"
    run_agent "'"$SESSION_ID6"'" "with known model" "'"$KNOWN_MODEL"'" ""
  ' >/dev/null 2>&1
# Restore the real stub for later cases.
rm -f "$BIN/agy"
mv "$BIN/agy.real-06a" "$BIN/agy"
# Walk the NUL-delimited elements: the element after "--model" must equal
# the full model name (proves spaces/parens stayed in one argv slot).
mapfile -d '' -t _nul_elems < "$NUL_ARGS" 2>/dev/null || {
  # zsh / no-mapfile fallback: read into an array via a NUL loop.
  _nul_elems=(); while IFS= read -r -d '' _e; do _nul_elems+=("$_e"); done < "$NUL_ARGS"
}
_model_elem=""
for ((_i = 0; _i < ${#_nul_elems[@]}; _i++)); do
  if [[ "${_nul_elems[$_i]}" == "--model" ]]; then
    _model_elem="${_nul_elems[$((_i + 1))]}"
    break
  fi
done
assert_eq "AGY-06a — model is a single argv element (quoting preserved)" \
  "$KNOWN_MODEL" "$_model_elem"

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-06b: empty model → no --model, no WARN ==="
# ---------------------------------------------------------------------------
SESSION_ID6B="66666666-bbbb-2222-3333-123456789012"
: > "$ARGS_FILE"; : > "$STDIN_FILE"
run06b_stderr=$(
  (
    PATH="$BIN:$PATH" \
    AUTONOMOUS_PID_DIR="$PID_DIR" \
    PROJECT_ID="testproj" \
    PROJECT_DIR="$TMPROOT" \
    AGENT_CMD=agy \
    AGENT_PERMISSION_MODE=auto \
    AGENT_TIMEOUT=4h \
    AGY_ARGS_FILE="$ARGS_FILE" \
    AGY_STDIN_FILE="$STDIN_FILE" \
    AGY_FAKE_UUID="20de1bbb-aaaa-4bbb-8ccc-cccccccccccc" \
    bash -c '
      unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE \
            _LIB_AGENT_AGY_MODEL_WARNED _LIB_AGENT_AGY_MODELS_CACHE
      source "'"$LIB"'"
      run_agent "'"$SESSION_ID6B"'" "no model" "" ""
    '
  ) 2>&1 1>/dev/null
)
agy_argv=$(cat "$ARGS_FILE")
assert_not_contains "AGY-06b — empty model: argv has no --model" "--model" "$agy_argv"
assert_not_contains "AGY-06b — empty model: no WARN to stderr" "agy" "$run06b_stderr"

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-06b2: enumerated-but-unknown model → omitted + one-time WARN ==="
# ---------------------------------------------------------------------------
# agy accepts ANY --model string at rc 0 and silently runs its default, so the
# wrapper must drop a cross-namespace id (e.g. kiro's "claude-sonnet-4.6") and
# WARN instead of forwarding it into the INV-40 merge gate.
SESSION_ID6B2="66666666-b2b2-2222-3333-123456789012"
UNKNOWN_MODEL="claude-sonnet-4.6"
: > "$ARGS_FILE"; : > "$STDIN_FILE"
run06b2_stderr=$(
  (
    PATH="$BIN:$PATH" \
    AUTONOMOUS_PID_DIR="$PID_DIR" \
    PROJECT_ID="testproj" \
    PROJECT_DIR="$TMPROOT" \
    AGENT_CMD=agy \
    AGENT_PERMISSION_MODE=auto \
    AGENT_TIMEOUT=4h \
    AGY_ARGS_FILE="$ARGS_FILE" \
    AGY_STDIN_FILE="$STDIN_FILE" \
    AGY_FAKE_UUID="20de1b22-aaaa-4bbb-8ccc-cccccccccccc" \
    bash -c '
      unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE \
            _LIB_AGENT_AGY_MODEL_WARNED _LIB_AGENT_AGY_MODELS_CACHE
      source "'"$LIB"'"
      run_agent "'"$SESSION_ID6B2"'" "unknown model" "'"$UNKNOWN_MODEL"'" ""
    '
  ) 2>&1 1>/dev/null
)
# rc captured separately.
(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  AGENT_PERMISSION_MODE=auto \
  AGENT_TIMEOUT=4h \
  AGY_ARGS_FILE="$ARGS_FILE" \
  AGY_STDIN_FILE="$STDIN_FILE" \
  AGY_FAKE_UUID="20de1b22-aaaa-4bbb-8ccc-cccccccccccc" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE \
          _LIB_AGENT_AGY_MODEL_WARNED _LIB_AGENT_AGY_MODELS_CACHE
    source "'"$LIB"'"
    run_agent "'"$SESSION_ID6B2"'" "unknown model" "'"$UNKNOWN_MODEL"'" ""
  ' >/dev/null 2>&1
)
agy06b2_rc=$?
assert_eq "AGY-06b2 — rc 0 (agy default, not a drop)" 0 "$agy06b2_rc"
agy_argv=$(cat "$ARGS_FILE")
assert_not_contains "AGY-06b2 — unknown model NOT forwarded" "--model" "$agy_argv"
assert_contains "AGY-06b2 — WARN names the bad value" "$UNKNOWN_MODEL" "$run06b2_stderr"
assert_contains "AGY-06b2 — WARN points at AGENT_REVIEW_MODEL_AGY" \
  "AGENT_REVIEW_MODEL_AGY" "$run06b2_stderr"
assert_contains "AGY-06b2 — WARN says not a known agy model" \
  "not a known agy model" "$run06b2_stderr"

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-06b3: agy models enumeration failure → best-effort pass-through ==="
# ---------------------------------------------------------------------------
# If `agy models` can't be enumerated we cannot prove the value invalid, so we
# forward it (mirrors INV-36 best-effort) rather than silently drop a maybe-valid id.
SESSION_ID6B3="66666666-b3b3-2222-3333-123456789012"
ENUMFAIL_MODEL="some-model"
: > "$ARGS_FILE"; : > "$STDIN_FILE"
(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  AGENT_PERMISSION_MODE=auto \
  AGENT_TIMEOUT=4h \
  AGY_ARGS_FILE="$ARGS_FILE" \
  AGY_STDIN_FILE="$STDIN_FILE" \
  AGY_MODELS_FAIL=1 \
  AGY_FAKE_UUID="20de1b33-aaaa-4bbb-8ccc-cccccccccccc" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE \
          _LIB_AGENT_AGY_MODEL_WARNED _LIB_AGENT_AGY_MODELS_CACHE
    source "'"$LIB"'"
    run_agent "'"$SESSION_ID6B3"'" "enum fail model" "'"$ENUMFAIL_MODEL"'" ""
  ' >/dev/null 2>&1
)
agy06b3_rc=$?
assert_eq "AGY-06b3 — rc 0 on enumeration failure" 0 "$agy06b3_rc"
agy_argv=$(cat "$ARGS_FILE")
assert_contains "AGY-06b3 — model forwarded best-effort when enum fails" \
  "--model $ENUMFAIL_MODEL" "$agy_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AGYM-KM: _agy_known_model unit ==="
# ---------------------------------------------------------------------------
# known → rc 0; unknown → rc 1; prefix of a listed name → rc 1 (whole-line);
# regex-metachar arg treated literally → rc 1; empty → rc 1.
km_out=$(
  PATH="$BIN:$PATH" \
  AGENT_CMD=agy \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE \
          _LIB_AGENT_AGY_MODEL_WARNED _LIB_AGENT_AGY_MODELS_CACHE
    source "'"$LIB"'"
    _agy_known_model "Gemini 3.5 Flash (High)";  echo "known=$?"
    _agy_known_model "claude-sonnet-4.6";        echo "unknown=$?"
    _agy_known_model "Gemini 3.5 Flash";         echo "prefix=$?"
    _agy_known_model "Gemini.*";                 echo "regex=$?"
    _agy_known_model "";                         echo "empty=$?"
  ' 2>/dev/null
)
assert_contains "TC-AGYM-KM — known name → rc 0"            "known=0"   "$km_out"
assert_contains "TC-AGYM-KM — unknown name → rc 1"          "unknown=1" "$km_out"
assert_contains "TC-AGYM-KM — prefix of listed name → rc 1" "prefix=1"  "$km_out"
assert_contains "TC-AGYM-KM — regex metachars literal → rc 1" "regex=1" "$km_out"
assert_contains "TC-AGYM-KM — empty arg → rc 1"             "empty=1"   "$km_out"

# Caching: _agy_known_model must enumerate `agy models` at most ONCE per
# process. Use a counting stub that bumps a counter file on each `models` call.
COUNT_FILE="$TMPROOT/agy-models-count"
cat > "$BIN/agy-count" <<'STUB'
#!/bin/bash
if [[ "${1:-}" == "models" ]]; then
  c=$(cat "$AGY_COUNT_FILE" 2>/dev/null || echo 0)
  echo $((c + 1)) > "$AGY_COUNT_FILE"
  echo "Gemini 3.5 Flash (High)"
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/agy-count"
echo 0 > "$COUNT_FILE"
PATH="$BIN:$PATH" \
  AGENT_CMD=agy-count \
  AGY_COUNT_FILE="$COUNT_FILE" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE \
          _LIB_AGENT_AGY_MODEL_WARNED _LIB_AGENT_AGY_MODELS_CACHE
    source "'"$LIB"'"
    _agy_known_model "Gemini 3.5 Flash (High)" || true
    _agy_known_model "claude-sonnet-4.6"       || true
    _agy_known_model "Gemini 3.5 Flash (Low)"  || true
  ' >/dev/null 2>&1
assert_eq "TC-AGYM-KM — agy models enumerated once per process (cached)" \
  "1" "$(cat "$COUNT_FILE")"

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-06c: resume_agent --conversation path forwards --model ==="
# ---------------------------------------------------------------------------
# Reuse sidecar4 from AGY-04 (populated). resume with a known model.
: > "$ARGS_FILE"; : > "$STDIN_FILE"
PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  AGENT_PERMISSION_MODE=auto \
  AGENT_TIMEOUT=4h \
  AGY_ARGS_FILE="$ARGS_FILE" \
  AGY_STDIN_FILE="$STDIN_FILE" \
  AGY_FAKE_UUID="$FAKE_UUID" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE \
          _LIB_AGENT_AGY_MODEL_WARNED _LIB_AGENT_AGY_MODELS_CACHE
    source "'"$LIB"'"
    resume_agent "'"$SESSION_ID4"'" "resume with model" "'"$KNOWN_MODEL"'" ""
  ' >/dev/null 2>&1
agy06c_rc=$?
assert_eq "AGY-06c — resume rc 0 with known model" 0 "$agy06c_rc"
agy_argv=$(cat "$ARGS_FILE")
assert_contains "AGY-06c — resume argv contains --conversation <UUID>" \
  "--conversation $FAKE_UUID" "$agy_argv"
assert_contains "AGY-06c — resume argv contains --model" "--model" "$agy_argv"
assert_contains "AGY-06c — resume argv contains the model name" "$KNOWN_MODEL" "$agy_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-06d: resume_agent no sidecar → run_agent fallback threads --model ==="
# ---------------------------------------------------------------------------
SESSION_ID6D="6666666d-eeee-ffff-aaaa-bbbbbbbbbbbb"  # no sidecar pre-populated
: > "$ARGS_FILE"; : > "$STDIN_FILE"
PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  AGENT_PERMISSION_MODE=auto \
  AGENT_TIMEOUT=4h \
  AGY_ARGS_FILE="$ARGS_FILE" \
  AGY_STDIN_FILE="$STDIN_FILE" \
  AGY_FAKE_UUID="6dde1aaa-aaaa-4bbb-8ccc-cccccccccccc" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE \
          _LIB_AGENT_AGY_MODEL_WARNED _LIB_AGENT_AGY_MODELS_CACHE
    source "'"$LIB"'"
    resume_agent "'"$SESSION_ID6D"'" "fallback with model" "'"$KNOWN_MODEL"'" ""
  ' >/dev/null 2>&1
agy06d_rc=$?
assert_eq "AGY-06d — resume-fallback rc 0" 0 "$agy06d_rc"
agy_argv=$(cat "$ARGS_FILE")
assert_not_contains "AGY-06d — fallback argv has no --conversation" "--conversation" "$agy_argv"
assert_contains "AGY-06d — fallback argv contains --model (threaded through)" "--model" "$agy_argv"
assert_contains "AGY-06d — fallback argv contains the model name" "$KNOWN_MODEL" "$agy_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-WARN-GONE: old warn-and-ignore string removed from lib-agent.sh ==="
# ---------------------------------------------------------------------------
if grep -q "does not support --model" "$LIB"; then
  echo -e "  ${RED}FAIL${NC}: AGY-WARN-GONE — stale 'does not support --model' WARN still present in lib-agent.sh"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: AGY-WARN-GONE — warn-and-ignore string removed"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== AGY-07: log without Print-mode line — INV-36 best-effort ==="
# ---------------------------------------------------------------------------
SESSION_ID7="77777777-aaaa-bbbb-cccc-dddddddddddd"

# Stub agy variant that writes a log file WITHOUT the Print-mode line.
cat > "$BIN/agy-nomatch" <<'STUB'
#!/bin/bash
echo "$@" > "$AGY_ARGS_FILE"
cat > "${AGY_STDIN_FILE:-/dev/null}"
log_file=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--log-file" ]]; then
    log_file="$arg"
    break
  fi
  prev="$arg"
done
if [[ -n "$log_file" ]]; then
  cat > "$log_file" <<EOF
I0524 22:56:05.692100 1234 input.go:42] Starting print mode
I0524 22:56:05.692500 1234 nomatch.go:99] Some unrelated line
EOF
fi
exit 0
STUB
chmod +x "$BIN/agy-nomatch"

# Symlink agy → agy-nomatch for this case.
mv "$BIN/agy" "$BIN/agy.real"
ln -sf "$BIN/agy-nomatch" "$BIN/agy"

: > "$ARGS_FILE"; : > "$STDIN_FILE"

(
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=agy \
  AGENT_PERMISSION_MODE=auto \
  AGENT_TIMEOUT=4h \
  AGY_ARGS_FILE="$ARGS_FILE" \
  AGY_STDIN_FILE="$STDIN_FILE" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE _LIB_AGENT_AGY_MODEL_WARNED
    source "'"$LIB"'"
    run_agent "'"$SESSION_ID7"'" "no-match prompt" "" ""
  ' >/dev/null 2>&1
)
nomatch_rc=$?

# Restore real stub for any later cases.
rm -f "$BIN/agy"
mv "$BIN/agy.real" "$BIN/agy"

assert_eq "AGY-07 — rc still propagates from agy stub (0)" 0 "$nomatch_rc"
sidecar7="$PID_DIR/agy-conversation-$SESSION_ID7"
if [[ ! -e "$sidecar7" ]]; then
  echo -e "  ${GREEN}PASS${NC}: AGY-07 — sidecar absent for log without Print-mode line"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: AGY-07 — sidecar should be absent"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "PASS: $PASS    FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
