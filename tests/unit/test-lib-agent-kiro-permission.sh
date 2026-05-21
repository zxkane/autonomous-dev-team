#!/bin/bash
# test-lib-agent-kiro-permission.sh — Unit tests for the kiro branch of
# lib-agent.sh.
#
# Originally introduced in #136 to lock in `--trust-all-tools` as a
# conditional flag keyed on AGENT_PERMISSION_MODE=bypassPermissions.
# After #140 that conditional moved out of the wrapper and into operator
# conf via `AGENT_DEV_EXTRA_ARGS` / `AGENT_REVIEW_EXTRA_ARGS`. This file
# now verifies the structural-only contract:
#
#   - run_agent kiro branch invokes
#       `kiro-cli chat --agent <name> --no-interactive [--model <m>]
#        [<EXTRA_ARGS>...] <prompt>`
#     (no AGENT_PERMISSION_MODE conditional in the wrapper anymore)
#   - When the operator supplies AGENT_DEV_EXTRA_ARGS=--trust-all-tools,
#     the flag is appended verbatim — the post-#140 migration path
#   - resume_agent falls through to run_agent for kiro and honors the
#     EXTRA_ARGS the same way
#   - --model still threads correctly when EXTRA_ARGS is set
#
# Strategy: mirror test-lib-agent-gemini.sh — source lib-agent.sh in a
# sandbox with a stub `kiro-cli` on PATH that records argv to a
# recorder file.
#
# Run: bash tests/unit/test-lib-agent-kiro-permission.sh

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

# Defensive helper: kiro's short flag for --trust-all-tools is `-a`.
# We need to assert "no -a flag anywhere" in TC-KIR-002 without
# false-positiving on substrings (e.g. `--agent` contains -a).
# Tokenize argv on whitespace and check each token literally.
argv_has_token() {
  local needle="$1" argv="$2"
  local tok
  for tok in $argv; do
    [[ "$tok" == "$needle" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
echo "=== TC-KIR-STATIC-001: source-of-truth grep — kiro branch shape ==="
# ---------------------------------------------------------------------------
# Cheap structural assertions before exercising behavior. Catches the
# refactor-drops-the-branch failure mode immediately.

# Both run_agent and resume_agent must have a kiro case (count 2).
kiro_case_count=$(grep -cE '^[[:space:]]*kiro\)[[:space:]]*$' "$LIB" || echo 0)
assert_eq "lib-agent.sh has kiro case in both run_agent and resume_agent" \
  "2" "$kiro_case_count"

# Post-#140: the kiro case body MUST NOT contain executable references
# to `--trust-all-tools` — the flag has been demoted to operator conf
# (AGENT_DEV_EXTRA_ARGS). Mentions inside `#` comments are allowed (and
# expected, as the docstring documents the canonical EXTRA_ARGS value
# for operators). Strip comments before grepping so we test code, not
# narrative.
#
# Pin the demotion: a refactor that re-hardcodes the flag would silently
# override operators' allowedTools posture, reproducing the #102 R5
# fabrication failure mode for everyone who sets AGENT_PERMISSION_MODE
# to anything other than bypassPermissions.
kiro_executable=$(awk '
  /^[[:space:]]*kiro\)[[:space:]]*$/ { flag=1 }
  flag {
    line = $0
    sub(/[[:space:]]*#.*$/, "", line)
    if (line ~ /^[[:space:]]*$/) next
    if (line ~ /^[[:space:]]*;;[[:space:]]*$/) { flag=0; next }
    print line
  }
' "$LIB")
if [[ "$kiro_executable" != *"--trust-all-tools"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: kiro case body does not hardcode --trust-all-tools (demoted to AGENT_DEV_EXTRA_ARGS, #140)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: kiro case body still hardcodes --trust-all-tools (should live in AGENT_DEV_EXTRA_ARGS, #140)"
  FAIL=$((FAIL + 1))
fi

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

# Stub kiro-cli: print argv + drain stdin to recorders. No JSONL stream
# needed — kiro-cli is invoked positionally (no --output-format flag),
# and the only contract under test is the argv composition. After #144
# the prompt arrives via stdin instead of as a positional message.
cat > "$BIN/kiro-cli" <<'EOF'
#!/bin/bash
echo "$@" > "$KIRO_ARGS_FILE"
cat > "${KIRO_STDIN_FILE:-/dev/null}"
exit 0
EOF
chmod +x "$BIN/kiro-cli"

# Stub timeout: run argv directly. Same shape as test-lib-agent-gemini.sh.
# _run_with_timeout invokes us as: timeout --kill-after=30s --signal=TERM <DURATION> <CMD...>
cat > "$BIN/timeout" <<'EOF'
#!/bin/bash
shift 3
exec "$@"
EOF
chmod +x "$BIN/timeout"

ARGS_FILE="$TMPROOT/kiro-args"
STDIN_FILE="$TMPROOT/kiro-stdin"
SESSION_ID="b2c3d4e5-1111-2222-3333-555555555555"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIR-001: run_agent + AGENT_DEV_EXTRA_ARGS=--trust-all-tools ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"; : > "$STDIN_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=kiro \
AGENT_PERMISSION_MODE=bypassPermissions \
AGENT_DEV_EXTRA_ARGS="--trust-all-tools" \
KIRO_ARGS_FILE="$ARGS_FILE" \
  KIRO_STDIN_FILE="$STDIN_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "implement the thing" "" ""
' >/dev/null 2>&1

bypass_argv=$(cat "$ARGS_FILE")

assert_contains "TC-KIR-001 argv contains --trust-all-tools (load-bearing, via EXTRA_ARGS)" \
  "--trust-all-tools" "$bypass_argv"

# Existing flags must survive.
assert_contains "TC-KIR-001 argv still contains --no-interactive" \
  "--no-interactive" "$bypass_argv"
assert_contains "TC-KIR-001 argv still contains --agent" \
  "--agent" "$bypass_argv"
assert_contains "TC-KIR-001 argv contains the chat subcommand" \
  "chat" "$bypass_argv"
# After #144: prompt arrives via stdin, NOT argv.
assert_not_contains "TC-KIR-001 argv does NOT carry the prompt positionally" \
  "implement the thing" "$bypass_argv"
bypass_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)
assert_eq "TC-KIR-001 stdin contains the prompt (post-#144 channel)" \
  "implement the thing" "$bypass_stdin"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIR-002: run_agent + empty AGENT_DEV_EXTRA_ARGS → no --trust-all-tools ==="
# ---------------------------------------------------------------------------
# Post-#140: AGENT_PERMISSION_MODE no longer drives the kiro trust flag.
# An operator who leaves AGENT_DEV_EXTRA_ARGS empty (the migration
# regression we expect for un-updated gemini/kiro deployments) gets a
# wrapper invocation WITHOUT --trust-all-tools. This is intentional —
# the conf.example callout makes the migration explicit.
: > "$ARGS_FILE"; : > "$STDIN_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=kiro \
AGENT_PERMISSION_MODE=auto \
KIRO_ARGS_FILE="$ARGS_FILE" \
  KIRO_STDIN_FILE="$STDIN_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "restrictive default" "" ""
' >/dev/null 2>&1

auto_argv=$(cat "$ARGS_FILE")

assert_not_contains "TC-KIR-002 argv does NOT contain --trust-all-tools when AGENT_DEV_EXTRA_ARGS empty" \
  "--trust-all-tools" "$auto_argv"

# Defensive: also rule out the short -a flag (which kiro-cli accepts as
# an alias for --trust-all-tools). Tokenize to avoid false positives on
# substrings like `--agent`.
if argv_has_token "-a" "$auto_argv"; then
  echo -e "  ${RED}FAIL${NC}: TC-KIR-002 argv contains -a short flag when AGENT_PERMISSION_MODE=auto"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-KIR-002 argv does NOT contain -a when AGENT_PERMISSION_MODE=auto"
  PASS=$((PASS + 1))
fi

# Sanity: the harness actually invoked the stub, otherwise TC-KIR-002 is
# vacuously passing on an empty argv file.
assert_contains "TC-KIR-002 argv still contains --no-interactive (sanity)" \
  "--no-interactive" "$auto_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIR-003: resume_agent + AGENT_DEV_EXTRA_ARGS=--trust-all-tools ==="
# ---------------------------------------------------------------------------
# Kiro has no session model: resume_agent falls back to run_agent, which
# reads AGENT_DEV_EXTRA_ARGS (not the review-side var). Operators wiring
# kiro for a fresh-conversation resume must ensure both vars are set if
# they need the trust flag on either path. We document the
# fall-through here.
: > "$ARGS_FILE"; : > "$STDIN_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=kiro \
AGENT_PERMISSION_MODE=bypassPermissions \
AGENT_DEV_EXTRA_ARGS="--trust-all-tools" \
KIRO_ARGS_FILE="$ARGS_FILE" \
  KIRO_STDIN_FILE="$STDIN_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  source "'"$LIB"'"
  resume_agent "'"$SESSION_ID"'" "follow-up: address review feedback" "" ""
' >/dev/null 2>&1

resume_argv=$(cat "$ARGS_FILE")

assert_contains "TC-KIR-003 resume argv contains --trust-all-tools (via DEV_EXTRA_ARGS fall-through)" \
  "--trust-all-tools" "$resume_argv"
# After #144: resume prompt also arrives via stdin (kiro resume is
# fall-through to run_agent, so same stdin contract).
assert_not_contains "TC-KIR-003 resume argv does NOT carry the follow-up prompt positionally" \
  "follow-up: address review feedback" "$resume_argv"
resume_stdin=$(cat "$STDIN_FILE" 2>/dev/null || true)
assert_eq "TC-KIR-003 resume stdin contains the follow-up prompt" \
  "follow-up: address review feedback" "$resume_stdin"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIR-004: --model still threads when both knobs are set ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"; : > "$STDIN_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=kiro \
AGENT_PERMISSION_MODE=bypassPermissions \
AGENT_DEV_EXTRA_ARGS="--trust-all-tools" \
KIRO_ARGS_FILE="$ARGS_FILE" \
  KIRO_STDIN_FILE="$STDIN_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "with model" "claude-sonnet-4-6" ""
' >/dev/null 2>&1

model_argv=$(cat "$ARGS_FILE")

assert_contains "TC-KIR-004 argv contains --model claude-sonnet-4-6" \
  "--model claude-sonnet-4-6" "$model_argv"
assert_contains "TC-KIR-004 argv still has --trust-all-tools with model set" \
  "--trust-all-tools" "$model_argv"
assert_contains "TC-KIR-004 argv still has --no-interactive" \
  "--no-interactive" "$model_argv"
assert_contains "TC-KIR-004 argv still has --agent" \
  "--agent" "$model_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
