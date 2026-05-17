#!/bin/bash
# test-lib-agent-kiro-permission.sh — Unit tests for the kiro
# permission-mode wiring in lib-agent.sh (#136).
#
# Verifies:
#   - run_agent kiro branch invokes
#       `kiro-cli chat --agent <name> --no-interactive [--model <m>]
#        [--trust-all-tools] <prompt>`
#     with --trust-all-tools appended IFF
#     AGENT_PERMISSION_MODE=bypassPermissions.
#   - resume_agent (which falls through to run_agent for kiro since
#     kiro has no session model) honors the same wiring on the
#     fresh-conversation invocation it spawns.
#   - --trust-all-tools is NOT appended when AGENT_PERMISSION_MODE is
#     left at the lib default (auto), preserving operators' restrictive
#     allowedTools posture.
#   - --model still threads correctly when both knobs are set
#     (regression pin against argv-construction reorder).
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

# The conditional that gates --trust-all-tools must reference
# AGENT_PERMISSION_MODE — pin against a refactor that hardcodes the flag
# always-on (would silently override operators' allowedTools posture).
if grep -q 'AGENT_PERMISSION_MODE.*bypassPermissions' "$LIB" \
   && grep -q -- '--trust-all-tools' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: lib-agent.sh wires AGENT_PERMISSION_MODE=bypassPermissions to --trust-all-tools"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: lib-agent.sh missing AGENT_PERMISSION_MODE→--trust-all-tools wiring"
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

# Stub kiro-cli: print argv to a recorder. No JSONL stream needed —
# kiro-cli is invoked positionally (no --output-format flag), and the
# only contract under test is the argv composition. Exit 0 unless the
# stub explicitly opts into a denied-tool sequence.
cat > "$BIN/kiro-cli" <<'EOF'
#!/bin/bash
echo "$@" > "$KIRO_ARGS_FILE"
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
SESSION_ID="b2c3d4e5-1111-2222-3333-555555555555"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIR-001: run_agent + bypassPermissions → --trust-all-tools ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=kiro \
AGENT_PERMISSION_MODE=bypassPermissions \
KIRO_ARGS_FILE="$ARGS_FILE" \
bash -c '
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "implement the thing" "" ""
' >/dev/null 2>&1

bypass_argv=$(cat "$ARGS_FILE")

assert_contains "TC-KIR-001 argv contains --trust-all-tools (load-bearing)" \
  "--trust-all-tools" "$bypass_argv"

# Existing flags must survive.
assert_contains "TC-KIR-001 argv still contains --no-interactive" \
  "--no-interactive" "$bypass_argv"
assert_contains "TC-KIR-001 argv still contains --agent" \
  "--agent" "$bypass_argv"
assert_contains "TC-KIR-001 argv contains the chat subcommand" \
  "chat" "$bypass_argv"
assert_contains "TC-KIR-001 argv contains the prompt" \
  "implement the thing" "$bypass_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIR-002: run_agent + auto → does NOT include --trust-all-tools ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=kiro \
AGENT_PERMISSION_MODE=auto \
KIRO_ARGS_FILE="$ARGS_FILE" \
bash -c '
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "restrictive default" "" ""
' >/dev/null 2>&1

auto_argv=$(cat "$ARGS_FILE")

assert_not_contains "TC-KIR-002 argv does NOT contain --trust-all-tools when AGENT_PERMISSION_MODE=auto" \
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
echo "=== TC-KIR-003: resume_agent + bypassPermissions → --trust-all-tools ==="
# ---------------------------------------------------------------------------
# Kiro has no session model: resume_agent falls back to run_agent. The
# trust flag must still ride along on the fresh-conversation invocation.
: > "$ARGS_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=kiro \
AGENT_PERMISSION_MODE=bypassPermissions \
KIRO_ARGS_FILE="$ARGS_FILE" \
bash -c '
  source "'"$LIB"'"
  resume_agent "'"$SESSION_ID"'" "follow-up: address review feedback" "" ""
' >/dev/null 2>&1

resume_argv=$(cat "$ARGS_FILE")

assert_contains "TC-KIR-003 resume argv contains --trust-all-tools" \
  "--trust-all-tools" "$resume_argv"
assert_contains "TC-KIR-003 resume argv contains the follow-up prompt (sanity)" \
  "follow-up: address review feedback" "$resume_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIR-004: --model still threads when both knobs are set ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=kiro \
AGENT_PERMISSION_MODE=bypassPermissions \
KIRO_ARGS_FILE="$ARGS_FILE" \
bash -c '
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
