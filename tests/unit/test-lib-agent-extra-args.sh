#!/bin/bash
# test-lib-agent-extra-args.sh — Unit tests for AGENT_DEV_EXTRA_ARGS /
# AGENT_REVIEW_EXTRA_ARGS pluggable per-CLI flag passthrough (#140,
# closes #102).
#
# Verifies:
#   - claude run_agent appends operator EXTRA_ARGS without breaking the
#     existing structural --permission-mode flag (TC-EXTRA-001)
#   - gemini case no longer hardcodes --approval-mode yolo /
#     --output-format stream-json (regression-pin demotion, TC-EXTRA-002)
#   - gemini with explicit AGENT_DEV_EXTRA_ARGS produces both load-bearing
#     flags in argv (TC-EXTRA-003)
#   - kiro case no longer hardcodes --trust-all-tools (TC-EXTRA-004)
#   - kiro with explicit AGENT_DEV_EXTRA_ARGS produces the trust flag
#     (TC-EXTRA-005)
#   - review-side AGENT_REVIEW_EXTRA_ARGS used in resume_agent, distinct
#     from dev-side (TC-EXTRA-006)
#   - structural flags preserved across all five CLIs (TC-EXTRA-007)
#   - shell quoting — paths-with-spaces survive tokenization (TC-EXTRA-008)
#   - empty/unset EXTRA_ARGS produces clean argv with no leftover empty
#     strings (TC-EXTRA-009)
#   - backward compat: gemini/kiro w/o EXTRA_ARGS produce wrapper
#     invocations omitting the demoted flags (TC-EXTRA-010 — operators
#     MUST migrate per the conf.example callout)
#
# Strategy: mirror test-lib-agent-gemini.sh — source lib-agent.sh in a
# sandbox with a stub CLI on PATH that records argv to a recorder file,
# and assert flag composition.
#
# Run: bash tests/unit/test-lib-agent-extra-args.sh

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

# Tokenize argv string (whitespace-separated, no quote handling) and
# report whether `needle` appears as an exact token. Used to defend
# against substring false positives such as `--agent` matching `-a`.
argv_has_token() {
  local needle="$1" argv="$2"
  local tok
  for tok in $argv; do
    [[ "$tok" == "$needle" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
echo "=== Static assertions: source-of-truth grep on lib-agent.sh ==="
# ---------------------------------------------------------------------------
# Pin the demotions and the new symbols so a future refactor that
# re-hardcodes flags or removes EXTRA_ARGS support fails loudly here.

# Strip line comments so we test executable code, not narrative.
strip_comments() {
  awk '{
    line = $0
    sub(/[[:space:]]*#.*$/, "", line)
    print line
  }' "$1"
}

executable=$(strip_comments "$LIB")

# TC-EXTRA-002 (static): the gemini case body must not contain executable
# `--approval-mode yolo` references.
if [[ "$executable" != *"--approval-mode yolo"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-EXTRA-002 lib-agent.sh has no executable --approval-mode yolo (gemini demoted to EXTRA_ARGS)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EXTRA-002 lib-agent.sh still has executable --approval-mode yolo"
  FAIL=$((FAIL + 1))
fi

# TC-EXTRA-002 (static): no executable `--output-format stream-json`
# either — same demotion.
if [[ "$executable" != *"--output-format stream-json"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-EXTRA-002 lib-agent.sh has no executable --output-format stream-json (gemini demoted to EXTRA_ARGS)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EXTRA-002 lib-agent.sh still has executable --output-format stream-json"
  FAIL=$((FAIL + 1))
fi

# TC-EXTRA-004 (static): no executable `--trust-all-tools` references
# (kiro demoted to EXTRA_ARGS).
if [[ "$executable" != *"--trust-all-tools"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-EXTRA-004 lib-agent.sh has no executable --trust-all-tools (kiro demoted to EXTRA_ARGS)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EXTRA-004 lib-agent.sh still has executable --trust-all-tools"
  FAIL=$((FAIL + 1))
fi

# Symbol presence: AGENT_DEV_EXTRA_ARGS and AGENT_REVIEW_EXTRA_ARGS must
# both be referenced in the lib (not just docs).
for var in AGENT_DEV_EXTRA_ARGS AGENT_REVIEW_EXTRA_ARGS; do
  if grep -q "$var" "$LIB"; then
    echo -e "  ${GREEN}PASS${NC}: $var symbol referenced in lib-agent.sh"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $var symbol missing from lib-agent.sh"
    FAIL=$((FAIL + 1))
  fi
done

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

# Stub each CLI: print argv to a recorder. claude needs a JSON output
# (its branch consumes stdout via _claude_capture_session, but the
# wrapper doesn't pipe through anything for claude — it just runs and
# reads the exit code, so a plain echo is fine).
for cli in claude codex gemini kiro-cli opencode generic-cli; do
  cat > "$BIN/$cli" <<EOF
#!/bin/bash
echo "\$@" > "\${CLI_ARGS_FILE}"
EOF
  chmod +x "$BIN/$cli"
done

# Stub `env` so `env -u CLAUDECODE claude ...` resolves to our stub.
# The wrapper prepends `env -u CLAUDECODE` for claude when no launcher
# is set; the real `env` reorders argv and hands off to claude. Mimic
# that by skipping `env -u <var>` and exec'ing the rest.
cat > "$BIN/env" <<'EOF'
#!/bin/bash
# Skip leading -u VAR pairs.
while [[ "$1" == "-u" ]]; do
  shift 2
done
exec "$@"
EOF
chmod +x "$BIN/env"

# Stub timeout: skip its 3 leading args (--kill-after, --signal, duration)
# and exec the rest.
cat > "$BIN/timeout" <<'EOF'
#!/bin/bash
shift 3
exec "$@"
EOF
chmod +x "$BIN/timeout"

ARGS_FILE="$TMPROOT/cli-args"
SESSION_ID="abc12345-1111-2222-3333-444444444444"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXTRA-001: claude run_agent + --debug via AGENT_DEV_EXTRA_ARGS ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=claude \
AGENT_PERMISSION_MODE=auto \
AGENT_DEV_EXTRA_ARGS="--debug" \
CLI_ARGS_FILE="$ARGS_FILE" \
bash -c '
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "implement the thing" "" ""
' >/dev/null 2>&1

claude_argv=$(cat "$ARGS_FILE")

assert_contains "TC-EXTRA-001 argv keeps existing --permission-mode auto" \
  "--permission-mode auto" "$claude_argv"
assert_contains "TC-EXTRA-001 argv contains operator-supplied --debug" \
  "--debug" "$claude_argv"
assert_contains "TC-EXTRA-001 argv keeps --session-id (structural)" \
  "--session-id $SESSION_ID" "$claude_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXTRA-003: gemini run_agent + canonical migration EXTRA_ARGS ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=gemini \
AGENT_PERMISSION_MODE=auto \
AGENT_DEV_EXTRA_ARGS="--approval-mode yolo --output-format stream-json" \
CLI_ARGS_FILE="$ARGS_FILE" \
bash -c '
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "implement the thing" "" ""
' >/dev/null 2>&1

gemini_argv=$(cat "$ARGS_FILE")

assert_contains "TC-EXTRA-003 argv contains --approval-mode yolo (load-bearing)" \
  "--approval-mode yolo" "$gemini_argv"
assert_contains "TC-EXTRA-003 argv contains --output-format stream-json (load-bearing)" \
  "--output-format stream-json" "$gemini_argv"
assert_contains "TC-EXTRA-003 argv keeps --session-id (structural)" \
  "--session-id $SESSION_ID" "$gemini_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXTRA-005: kiro run_agent + --trust-all-tools via EXTRA_ARGS ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=kiro \
AGENT_PERMISSION_MODE=auto \
AGENT_DEV_EXTRA_ARGS="--trust-all-tools" \
CLI_ARGS_FILE="$ARGS_FILE" \
bash -c '
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "implement the thing" "" ""
' >/dev/null 2>&1

kiro_argv=$(cat "$ARGS_FILE")

assert_contains "TC-EXTRA-005 argv contains --trust-all-tools (load-bearing)" \
  "--trust-all-tools" "$kiro_argv"
assert_contains "TC-EXTRA-005 argv keeps chat (structural)" \
  "chat" "$kiro_argv"
assert_contains "TC-EXTRA-005 argv keeps --no-interactive (structural)" \
  "--no-interactive" "$kiro_argv"
assert_contains "TC-EXTRA-005 argv keeps --agent (structural)" \
  "--agent" "$kiro_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXTRA-006: review-side EXTRA_ARGS distinct from dev-side ==="
# ---------------------------------------------------------------------------
# Run resume_agent with both vars set to DIFFERENT values. Only the
# review-side value should appear in argv; the dev-side value must NOT
# leak. Use gemini because resume_agent has a real gemini branch (not a
# fall-through to run_agent).
: > "$ARGS_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=gemini \
AGENT_PERMISSION_MODE=auto \
AGENT_DEV_EXTRA_ARGS="--dev-only-flag" \
AGENT_REVIEW_EXTRA_ARGS="--review-only-flag" \
CLI_ARGS_FILE="$ARGS_FILE" \
bash -c '
  source "'"$LIB"'"
  resume_agent "'"$SESSION_ID"'" "follow up" "" ""
' >/dev/null 2>&1

resume_argv=$(cat "$ARGS_FILE")

assert_contains "TC-EXTRA-006 resume argv contains --review-only-flag (review-side)" \
  "--review-only-flag" "$resume_argv"
assert_not_contains "TC-EXTRA-006 resume argv does NOT contain --dev-only-flag (dev-side must not leak)" \
  "--dev-only-flag" "$resume_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXTRA-007: structural flags preserved per CLI (regression pin) ==="
# ---------------------------------------------------------------------------
# claude — already covered in TC-EXTRA-001.

# codex: structural shape `exec --json [<EXTRA>] [<PROMPT>]`.
: > "$ARGS_FILE"
PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=codex \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
bash -c '
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "do work" "" ""
' >/dev/null 2>&1
codex_argv=$(cat "$ARGS_FILE")
assert_contains "TC-EXTRA-007 codex argv keeps 'exec' subcommand (structural)" \
  "exec" "$codex_argv"
assert_contains "TC-EXTRA-007 codex argv keeps --json (structural)" \
  "--json" "$codex_argv"

# kiro: structural shape (already exercised in TC-EXTRA-005).

# opencode: structural shape `run --format json [<EXTRA>] [<PROMPT>]`.
: > "$ARGS_FILE"
PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=opencode \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
bash -c '
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "do work" "" ""
' >/dev/null 2>&1
opencode_argv=$(cat "$ARGS_FILE")
assert_contains "TC-EXTRA-007 opencode argv keeps 'run' subcommand (structural)" \
  "run" "$opencode_argv"
assert_contains "TC-EXTRA-007 opencode argv keeps --format json (structural)" \
  "--format json" "$opencode_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXTRA-008: shell quoting — paths with spaces survive intact ==="
# ---------------------------------------------------------------------------
# `read -ra` does NOT honor shell quoting around tokens with embedded
# spaces. Our parser uses `eval` (same trust model as AGENT_LAUNCHER)
# specifically so this works.
: > "$ARGS_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=claude \
AGENT_PERMISSION_MODE=auto \
AGENT_DEV_EXTRA_ARGS='--policy "/path with spaces/policy.json"' \
CLI_ARGS_FILE="$ARGS_FILE" \
bash -c '
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "with policy" "" ""
' >/dev/null 2>&1

# Note: the CLI stub records argv via space-joined "$@", which flattens
# a multi-word value. We probe exact token composition below via the
# argv-probe helper; the recorder file is a sanity-only check that
# something happened.

cat > "$BIN/argv-probe" <<'EOF'
#!/bin/bash
# Append (not >) so callers can pre-stage metadata lines (e.g. ARR_LEN=)
# before invoking us with the array contents.
for arg in "$@"; do
  printf '%s\n' "$arg"
done >> "$ARGV_PROBE_FILE"
EOF
chmod +x "$BIN/argv-probe"

PROBE_FILE="$TMPROOT/probe"
: > "$PROBE_FILE"

# Manually drive the parser (faster + isolates from CLI dispatch).
PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=claude \
AGENT_DEV_EXTRA_ARGS='--policy "/path with spaces/policy.json"' \
ARGV_PROBE_FILE="$PROBE_FILE" \
bash -c '
  source "'"$LIB"'"
  arr=()
  _parse_extra_args AGENT_DEV_EXTRA_ARGS arr
  argv-probe "${arr[@]}"
'

probe_lines=$(wc -l < "$PROBE_FILE")
assert_eq "TC-EXTRA-008 _parse_extra_args produces exactly 2 tokens for quoted spaced value" \
  "2" "$probe_lines"
quoted_path=$(sed -n '2p' "$PROBE_FILE")
assert_eq "TC-EXTRA-008 token 2 is the path WITH spaces preserved" \
  "/path with spaces/policy.json" "$quoted_path"
flag_token=$(sed -n '1p' "$PROBE_FILE")
assert_eq "TC-EXTRA-008 token 1 is the flag" \
  "--policy" "$flag_token"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXTRA-009: empty/unset EXTRA_ARGS produces no leftover empty argv ==="
# ---------------------------------------------------------------------------
: > "$PROBE_FILE"

# Empty string case.
PATH="$BIN:$PATH" \
AGENT_DEV_EXTRA_ARGS="" \
ARGV_PROBE_FILE="$PROBE_FILE" \
bash -c '
  source "'"$LIB"'"
  arr=()
  _parse_extra_args AGENT_DEV_EXTRA_ARGS arr
  echo "ARR_LEN=${#arr[@]}" > "$ARGV_PROBE_FILE"
  argv-probe "${arr[@]}"
'

empty_len=$(grep '^ARR_LEN=' "$PROBE_FILE" | head -1 | cut -d= -f2)
assert_eq "TC-EXTRA-009 empty AGENT_DEV_EXTRA_ARGS yields zero-length array" \
  "0" "$empty_len"

# Unset case.
: > "$PROBE_FILE"
PATH="$BIN:$PATH" \
ARGV_PROBE_FILE="$PROBE_FILE" \
bash -c '
  unset AGENT_DEV_EXTRA_ARGS
  source "'"$LIB"'"
  arr=()
  _parse_extra_args AGENT_DEV_EXTRA_ARGS arr
  echo "ARR_LEN=${#arr[@]}" > "$ARGV_PROBE_FILE"
  argv-probe "${arr[@]}"
'

unset_len=$(grep '^ARR_LEN=' "$PROBE_FILE" | head -1 | cut -d= -f2)
assert_eq "TC-EXTRA-009 unset AGENT_DEV_EXTRA_ARGS yields zero-length array" \
  "0" "$unset_len"

# Behavioral: a real run_agent with empty EXTRA_ARGS must not leak an
# empty token into argv. Use gemini because its branch was the one
# previously tested with hardcoded flags — pin that nothing slips in.
: > "$ARGS_FILE"
PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=gemini \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
bash -c '
  unset AGENT_DEV_EXTRA_ARGS
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "do work" "" ""
' >/dev/null 2>&1

clean_argv=$(cat "$ARGS_FILE")

if argv_has_token "" "$clean_argv"; then
  echo -e "  ${RED}FAIL${NC}: TC-EXTRA-009 gemini argv contains an empty-string token (EXTRA_ARGS leaked)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-EXTRA-009 gemini argv contains no empty-string tokens"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXTRA-010: backward-compat — no EXTRA_ARGS = no demoted flags ==="
# ---------------------------------------------------------------------------
# This is the migration regression-by-design assertion. Operators who
# fail to migrate gemini/kiro deployments after pulling this PR will
# observe the silent fabrication failure that #134 / #136 originally
# fixed. The conf.example header callout is the load-bearing
# operator-facing artifact for this migration.

# gemini without EXTRA_ARGS must NOT have the demoted flags.
: > "$ARGS_FILE"
PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=gemini \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
bash -c '
  unset AGENT_DEV_EXTRA_ARGS AGENT_REVIEW_EXTRA_ARGS
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "do work" "" ""
' >/dev/null 2>&1
no_extra_gemini=$(cat "$ARGS_FILE")

assert_not_contains "TC-EXTRA-010 gemini w/o EXTRA_ARGS does NOT carry --approval-mode yolo" \
  "--approval-mode yolo" "$no_extra_gemini"
assert_not_contains "TC-EXTRA-010 gemini w/o EXTRA_ARGS does NOT carry --output-format stream-json" \
  "--output-format stream-json" "$no_extra_gemini"

# kiro without EXTRA_ARGS even when AGENT_PERMISSION_MODE=bypassPermissions
# must NOT carry --trust-all-tools (the conditional was demoted).
: > "$ARGS_FILE"
PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=kiro \
AGENT_PERMISSION_MODE=bypassPermissions \
CLI_ARGS_FILE="$ARGS_FILE" \
bash -c '
  unset AGENT_DEV_EXTRA_ARGS AGENT_REVIEW_EXTRA_ARGS
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "do work" "" ""
' >/dev/null 2>&1
no_extra_kiro=$(cat "$ARGS_FILE")

assert_not_contains "TC-EXTRA-010 kiro w/o EXTRA_ARGS does NOT carry --trust-all-tools (even with bypassPermissions)" \
  "--trust-all-tools" "$no_extra_kiro"

# claude without EXTRA_ARGS still has the (preserved-as-structural)
# --permission-mode flag — claude was NOT demoted.
: > "$ARGS_FILE"
PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=claude \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
bash -c '
  unset AGENT_DEV_EXTRA_ARGS AGENT_REVIEW_EXTRA_ARGS
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "do work" "" ""
' >/dev/null 2>&1
no_extra_claude=$(cat "$ARGS_FILE")

assert_contains "TC-EXTRA-010 claude w/o EXTRA_ARGS keeps --permission-mode (structural, NOT demoted)" \
  "--permission-mode auto" "$no_extra_claude"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
