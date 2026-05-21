#!/bin/bash
# test-lib-agent-prompt-stdin.sh — Unit tests for the prompt-off-argv
# fix in lib-agent.sh (closes #144).
#
# The bug: every CLI branch in run_agent / resume_agent ended with
# `... "$prompt"` as a single argv element. Linux execve(2) caps any
# single argv element at MAX_ARG_STRLEN = 32 * PAGE_SIZE = 131072 bytes.
# Once `gh issue view --json title,body,comments` exceeded 128 KB the
# wrapper crashed with `setsid: Argument list too long` (exit 126) on
# every dispatcher tick — a size-based silent perma-stall.
#
# The fix: pipe the prompt to the agent CLI via stdin, so the per-arg
# limit no longer applies (stdin is bounded only by available RAM).
#
# Strategy mirrors test-lib-agent-codex.sh — PATH-shadowed CLI stubs
# that record argv AND stdin into recorder files. We probe both:
#   1. The full prompt arrives at the CLI via stdin (proves the fix
#      works end-to-end through _run_with_timeout / setsid / wait).
#   2. argv contains no token longer than a small bound, so a
#      regression that re-adds `"$prompt"` to argv fails the test
#      even on a kernel that happens to allow large argv elements.
#   3. Static grep over lib-agent.sh asserts `"$prompt"` is not used
#      as a positional argv tail anywhere in run_agent / resume_agent.
#
# Run: bash tests/unit/test-lib-agent-prompt-stdin.sh

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
    echo "      haystack[0..300]='${haystack:0:300}'"
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

# True iff every argv token is shorter than $1. Used to assert the
# prompt did not leak onto argv even on kernels with a generous
# MAX_ARG_STRLEN. The CLI stubs space-join "$@" into the recorder, so
# we approximate: any single token longer than the limit would push
# the joined string past the limit too.
all_tokens_below_size() {
  local limit="$1" argv_file="$2"
  local tok
  while IFS= read -r tok; do
    [[ ${#tok} -lt $limit ]] || return 1
  done < "$argv_file"
  return 0
}

# Drop ambient autonomous.conf state. The agent that runs this test may
# have inherited AUTONOMOUS_CONF / AGENT_LAUNCHER / AGENT_PERMISSION_MODE
# from the dispatcher's per-project conf — which would smuggle a real
# `claude` invocation past our PATH-shadowed stubs. Unset before sourcing
# the lib in any sandboxed sub-bash.
unset AUTONOMOUS_CONF AUTONOMOUS_CONF_LOADED_FROM
unset AGENT_LAUNCHER AGENT_LAUNCHER_ARGV
unset AGENT_DEV_EXTRA_ARGS AGENT_REVIEW_EXTRA_ARGS
unset AGENT_PID_FILE

# ---------------------------------------------------------------------------
echo "=== TC-EXEC-009 (static): no '\$prompt' on _run_with_timeout argv ==="
# ---------------------------------------------------------------------------
# After the fix, the only legitimate places `"$prompt"` may appear in
# executable code are:
#   - `printf '%s' "$prompt" | ...` (the new stdin feeder stage)
#   - `run_agent "$session_id" "$prompt" "$model" "$session_name"` (recursive
#      fallback when a sidecar/branch needs to start fresh)
#
# What MUST disappear: any `_run_with_timeout ... "$prompt"` line, where
# `"$prompt"` is the trailing positional arg to a CLI exec — that's the
# specific shape that hit MAX_ARG_STRLEN. Grep just for that pattern.
strip_comments() {
  awk '{
    line = $0
    sub(/[[:space:]]*#.*$/, "", line)
    print line
  }' "$1"
}

executable=$(strip_comments "$LIB")

# Pre-fix every CLI branch ended `_run_with_timeout <cli> ... "$prompt"`,
# either on a single line or split across `\`-continued lines. After
# the fix `"$prompt"` should never appear in a `_run_with_timeout`
# invocation, including across continuations. (`run_agent <session>
# "$prompt"` is fine — it recurses into the same case dispatch where
# the prompt eventually enters the printf stage.)
#
# Join continuations before grepping so a regression that splits the
# offending arg across lines (e.g. `_run_with_timeout cli ... \\\n
#   "$prompt"`) is still caught.
joined=$(awk 'BEGIN{buf=""} {
  line=$0
  sub(/[[:space:]]*#.*$/, "", line)
  if (line ~ /\\$/) {
    sub(/[[:space:]]*\\$/, "", line)
    buf = buf line " "
  } else {
    print buf line
    buf = ""
  }
} END { if (buf != "") print buf }' "$LIB")

if grep -nE '_run_with_timeout[^|]*"\$prompt"' <<<"$joined" >/dev/null; then
  echo -e "  ${RED}FAIL${NC}: TC-EXEC-009 lib-agent.sh still has '_run_with_timeout ... \"\$prompt\"' — prompt still on argv (incl. continuation-line check)"
  echo "      offending lines:"
  grep -nE '_run_with_timeout[^|]*"\$prompt"' <<<"$joined" | head -5 | sed 's/^/        /'
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-EXEC-009 no '_run_with_timeout ... \"\$prompt\"' (after \\-continuation join)"
  PASS=$((PASS + 1))
fi

# Defense in depth: pre-fix the codex / opencode pipelines used
# PIPESTATUS[0] for the CLI rc. After adding the leading printf stage
# the CLI rc is at PIPESTATUS[1]. A regression that drops the leading
# printf would leave PIPESTATUS[1] referring to the awk capture filter
# (always rc=0), masking real CLI failures. Pin both indices.
if grep -nE 'return "\$\{PIPESTATUS\[0\]\}"' <<<"$executable" >/dev/null; then
  echo -e "  ${RED}FAIL${NC}: TC-EXEC-009 lib-agent.sh still uses PIPESTATUS[0] — pipeline shape regressed"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-EXEC-009 no PIPESTATUS[0] reads (codex/opencode now use PIPESTATUS[1])"
  PASS=$((PASS + 1))
fi
if grep -cE 'return "\$\{PIPESTATUS\[1\]\}"' <<<"$executable" | grep -qE '^[2-9]|^[1-9][0-9]'; then
  echo -e "  ${GREEN}PASS${NC}: TC-EXEC-009 PIPESTATUS[1] used in at least 2 places (codex+opencode, run_agent+resume_agent)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EXEC-009 PIPESTATUS[1] not present in expected count — codex/opencode pipeline regressed"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# Behavioral test sandbox setup — shared across all behavioral tests below
# ---------------------------------------------------------------------------
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PID_DIR="$TMPROOT/pid"
mkdir -p "$PID_DIR"
chmod 700 "$PID_DIR"

BIN="$TMPROOT/bin"
mkdir -p "$BIN"

# Stub each CLI: record argv (space-joined, one line) AND record stdin
# (verbatim). For codex/opencode we also emit a JSONL stream that the
# capture filter consumes; otherwise the wrapper can hang waiting for
# a thread.started / sessionID line that never arrives.
cat > "$BIN/claude" <<'EOF'
#!/bin/bash
echo "$@" > "$CLI_ARGS_FILE"
# Record each argv token on its own line for size-bound assertions.
for a in "$@"; do printf '%s\n' "$a"; done > "$CLI_ARGV_TOKENS_FILE"
# Drain stdin to a separate recorder so we can confirm the prompt
# arrived via the new channel.
cat > "$CLI_STDIN_FILE"
EOF
chmod +x "$BIN/claude"

cat > "$BIN/codex" <<'EOF'
#!/bin/bash
echo "$@" > "$CLI_ARGS_FILE"
for a in "$@"; do printf '%s\n' "$a"; done > "$CLI_ARGV_TOKENS_FILE"
cat > "$CLI_STDIN_FILE"
# Emit the JSONL the capture filter expects so run_agent can finish.
cat <<JSONL
{"type":"thread.started","thread_id":"019e1234-aaaa-bbbb-cccc-deadbeefcafe"}
{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
JSONL
EOF
chmod +x "$BIN/codex"

cat > "$BIN/gemini" <<'EOF'
#!/bin/bash
echo "$@" > "$CLI_ARGS_FILE"
for a in "$@"; do printf '%s\n' "$a"; done > "$CLI_ARGV_TOKENS_FILE"
cat > "$CLI_STDIN_FILE"
EOF
chmod +x "$BIN/gemini"

cat > "$BIN/kiro-cli" <<'EOF'
#!/bin/bash
echo "$@" > "$CLI_ARGS_FILE"
for a in "$@"; do printf '%s\n' "$a"; done > "$CLI_ARGV_TOKENS_FILE"
cat > "$CLI_STDIN_FILE"
EOF
chmod +x "$BIN/kiro-cli"

cat > "$BIN/opencode" <<'EOF'
#!/bin/bash
echo "$@" > "$CLI_ARGS_FILE"
for a in "$@"; do printf '%s\n' "$a"; done > "$CLI_ARGV_TOKENS_FILE"
cat > "$CLI_STDIN_FILE"
cat <<JSONL
{"type":"step_start","sessionID":"ses_TEST123abc","part":{"id":"prt_a"}}
{"type":"text","sessionID":"ses_TEST123abc","part":{"type":"text","text":"ok"}}
JSONL
EOF
chmod +x "$BIN/opencode"

cat > "$BIN/generic-cli" <<'EOF'
#!/bin/bash
echo "$@" > "$CLI_ARGS_FILE"
for a in "$@"; do printf '%s\n' "$a"; done > "$CLI_ARGV_TOKENS_FILE"
cat > "$CLI_STDIN_FILE"
EOF
chmod +x "$BIN/generic-cli"

# Stub `env` so `env -u CLAUDECODE claude ...` resolves to our stub.
cat > "$BIN/env" <<'EOF'
#!/bin/bash
while [[ "$1" == "-u" ]]; do shift 2; done
exec "$@"
EOF
chmod +x "$BIN/env"

# Stub `timeout` so we don't depend on coreutils availability and so
# the test runs synchronously. The wrapper invokes us as
#   timeout --kill-after=30s --signal=TERM <DUR> <CMD...>
# — 3 leading args before the real command.
cat > "$BIN/timeout" <<'EOF'
#!/bin/bash
shift 3
exec "$@"
EOF
chmod +x "$BIN/timeout"

# Stub `setsid` so we exec the rest directly. We don't need a real
# session leader for the recorder-based test — what we DO need is for
# the test to NOT depend on the host kernel's MAX_ARG_STRLEN behavior
# of the real /usr/bin/setsid (the production failure mode). That
# also makes the test deterministic across CI hosts.
cat > "$BIN/setsid" <<'EOF'
#!/bin/bash
exec "$@"
EOF
chmod +x "$BIN/setsid"

ARGS_FILE="$TMPROOT/cli-args"
TOKENS_FILE="$TMPROOT/cli-argv-tokens"
STDIN_FILE="$TMPROOT/cli-stdin"
SESSION_ID="abc12345-1111-2222-3333-444444444444"

# Build a 256 KB prompt. Single character so it's easy to verify
# (length + uniformity) but well past the 128 KB MAX_ARG_STRLEN limit
# that the production bug hit at 189 KB.
#
# Stash on disk: passing a 256 KB string via the parent shell's env to
# a `bash -c` sub-shell would itself hit MAX_ARG_STRLEN — env var
# values are subject to the same per-element limit as argv. Each
# sub-bash reads the prompt back from this file, which keeps the
# test's own invocation chain under the limit.
BIG_PROMPT_FILE="$TMPROOT/big-prompt"
printf 'x%.0s' $(seq 1 262144) > "$BIG_PROMPT_FILE"
BIG_PROMPT_SIZE=$(wc -c < "$BIG_PROMPT_FILE")
[[ "$BIG_PROMPT_SIZE" -ge 262144 ]] || {
  echo -e "  ${RED}FATAL${NC}: BIG_PROMPT_FILE only $BIG_PROMPT_SIZE bytes — printf truncated"
  exit 1
}

# Token-size limit: anything bigger than 64 KB is a clear sign the
# prompt leaked onto argv. Real argv tokens we keep are tiny
# (--session-id, model name, etc.). The MAX_ARG_STRLEN production
# limit is 128 KB, so 64 KB is a safe-but-strict bound.
ARGV_SIZE_LIMIT=65536

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-001: claude run_agent with 256 KB prompt ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"; : > "$TOKENS_FILE"; : > "$STDIN_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=claude \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
CLI_ARGV_TOKENS_FILE="$TOKENS_FILE" \
CLI_STDIN_FILE="$STDIN_FILE" \
BIG_PROMPT_FILE="$BIG_PROMPT_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  BIG=$(cat "$BIG_PROMPT_FILE")
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "$BIG" "" ""
' >/dev/null 2>&1
rc=$?

assert_eq "TC-EXEC-001 run_agent claude returns 0 with large prompt" 0 "$rc"

stdin_size=$(wc -c < "$STDIN_FILE")
assert_eq "TC-EXEC-001 stdin recorder size matches BIG_PROMPT" \
  "$BIG_PROMPT_SIZE" "$stdin_size"

if all_tokens_below_size "$ARGV_SIZE_LIMIT" "$TOKENS_FILE"; then
  echo -e "  ${GREEN}PASS${NC}: TC-EXEC-001 no argv token exceeds 64 KB (prompt off-argv)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EXEC-001 argv contains a >64 KB token (prompt leaked onto argv)"
  FAIL=$((FAIL + 1))
fi

claude_argv=$(cat "$ARGS_FILE")
assert_contains "TC-EXEC-001 argv keeps --session-id (structural)" \
  "--session-id $SESSION_ID" "$claude_argv"
assert_contains "TC-EXEC-001 argv keeps -p (structural)" \
  "-p" "$claude_argv"
assert_contains "TC-EXEC-001 argv keeps --output-format json (structural)" \
  "--output-format json" "$claude_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-002: codex run_agent with 256 KB prompt ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"; : > "$TOKENS_FILE"; : > "$STDIN_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=codex \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
CLI_ARGV_TOKENS_FILE="$TOKENS_FILE" \
CLI_STDIN_FILE="$STDIN_FILE" \
BIG_PROMPT_FILE="$BIG_PROMPT_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  BIG=$(cat "$BIG_PROMPT_FILE")
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "$BIG" "" ""
' >/dev/null 2>&1
rc=$?

assert_eq "TC-EXEC-002 run_agent codex returns 0 with large prompt" 0 "$rc"

stdin_size=$(wc -c < "$STDIN_FILE")
assert_eq "TC-EXEC-002 stdin recorder size matches BIG_PROMPT" \
  "$BIG_PROMPT_SIZE" "$stdin_size"

if all_tokens_below_size "$ARGV_SIZE_LIMIT" "$TOKENS_FILE"; then
  echo -e "  ${GREEN}PASS${NC}: TC-EXEC-002 no argv token exceeds 64 KB"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EXEC-002 argv contains a >64 KB token"
  FAIL=$((FAIL + 1))
fi

codex_argv=$(cat "$ARGS_FILE")
assert_contains "TC-EXEC-002 argv keeps 'exec' (structural)" \
  "exec" "$codex_argv"
assert_contains "TC-EXEC-002 argv keeps --json (structural)" \
  "--json" "$codex_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-003: gemini run_agent with 256 KB prompt ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"; : > "$TOKENS_FILE"; : > "$STDIN_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=gemini \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
CLI_ARGV_TOKENS_FILE="$TOKENS_FILE" \
CLI_STDIN_FILE="$STDIN_FILE" \
BIG_PROMPT_FILE="$BIG_PROMPT_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  BIG=$(cat "$BIG_PROMPT_FILE")
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "$BIG" "" ""
' >/dev/null 2>&1
rc=$?

assert_eq "TC-EXEC-003 run_agent gemini returns 0 with large prompt" 0 "$rc"
stdin_size=$(wc -c < "$STDIN_FILE")
assert_eq "TC-EXEC-003 stdin recorder size matches BIG_PROMPT" \
  "$BIG_PROMPT_SIZE" "$stdin_size"

if all_tokens_below_size "$ARGV_SIZE_LIMIT" "$TOKENS_FILE"; then
  echo -e "  ${GREEN}PASS${NC}: TC-EXEC-003 no argv token exceeds 64 KB"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EXEC-003 argv contains a >64 KB token"
  FAIL=$((FAIL + 1))
fi

gemini_argv=$(cat "$ARGS_FILE")
assert_contains "TC-EXEC-003 argv keeps --session-id (structural)" \
  "--session-id $SESSION_ID" "$gemini_argv"
assert_contains "TC-EXEC-003 argv keeps -p (structural)" \
  "-p" "$gemini_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-004: kiro run_agent with 256 KB prompt ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"; : > "$TOKENS_FILE"; : > "$STDIN_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=kiro \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
CLI_ARGV_TOKENS_FILE="$TOKENS_FILE" \
CLI_STDIN_FILE="$STDIN_FILE" \
BIG_PROMPT_FILE="$BIG_PROMPT_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  BIG=$(cat "$BIG_PROMPT_FILE")
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "$BIG" "" ""
' >/dev/null 2>&1
rc=$?

assert_eq "TC-EXEC-004 run_agent kiro returns 0 with large prompt" 0 "$rc"
stdin_size=$(wc -c < "$STDIN_FILE")
assert_eq "TC-EXEC-004 stdin recorder size matches BIG_PROMPT" \
  "$BIG_PROMPT_SIZE" "$stdin_size"

if all_tokens_below_size "$ARGV_SIZE_LIMIT" "$TOKENS_FILE"; then
  echo -e "  ${GREEN}PASS${NC}: TC-EXEC-004 no argv token exceeds 64 KB"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EXEC-004 argv contains a >64 KB token"
  FAIL=$((FAIL + 1))
fi

kiro_argv=$(cat "$ARGS_FILE")
assert_contains "TC-EXEC-004 argv keeps 'chat' (structural)" \
  "chat" "$kiro_argv"
assert_contains "TC-EXEC-004 argv keeps --no-interactive (structural)" \
  "--no-interactive" "$kiro_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-005: opencode run_agent with 256 KB prompt ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"; : > "$TOKENS_FILE"; : > "$STDIN_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=opencode \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
CLI_ARGV_TOKENS_FILE="$TOKENS_FILE" \
CLI_STDIN_FILE="$STDIN_FILE" \
BIG_PROMPT_FILE="$BIG_PROMPT_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  BIG=$(cat "$BIG_PROMPT_FILE")
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "$BIG" "" ""
' >/dev/null 2>&1
rc=$?

assert_eq "TC-EXEC-005 run_agent opencode returns 0 with large prompt" 0 "$rc"
stdin_size=$(wc -c < "$STDIN_FILE")
assert_eq "TC-EXEC-005 stdin recorder size matches BIG_PROMPT" \
  "$BIG_PROMPT_SIZE" "$stdin_size"

if all_tokens_below_size "$ARGV_SIZE_LIMIT" "$TOKENS_FILE"; then
  echo -e "  ${GREEN}PASS${NC}: TC-EXEC-005 no argv token exceeds 64 KB"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EXEC-005 argv contains a >64 KB token"
  FAIL=$((FAIL + 1))
fi

opencode_argv=$(cat "$ARGS_FILE")
assert_contains "TC-EXEC-005 argv keeps 'run' (structural)" \
  "run" "$opencode_argv"
assert_contains "TC-EXEC-005 argv keeps --format json (structural)" \
  "--format json" "$opencode_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-006: generic-cli fallback with 256 KB prompt ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"; : > "$TOKENS_FILE"; : > "$STDIN_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=generic-cli \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
CLI_ARGV_TOKENS_FILE="$TOKENS_FILE" \
CLI_STDIN_FILE="$STDIN_FILE" \
BIG_PROMPT_FILE="$BIG_PROMPT_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  BIG=$(cat "$BIG_PROMPT_FILE")
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "$BIG" "" ""
' >/dev/null 2>&1
rc=$?

assert_eq "TC-EXEC-006 run_agent generic-cli returns 0 with large prompt" 0 "$rc"
stdin_size=$(wc -c < "$STDIN_FILE")
assert_eq "TC-EXEC-006 stdin recorder size matches BIG_PROMPT" \
  "$BIG_PROMPT_SIZE" "$stdin_size"

if all_tokens_below_size "$ARGV_SIZE_LIMIT" "$TOKENS_FILE"; then
  echo -e "  ${GREEN}PASS${NC}: TC-EXEC-006 no argv token exceeds 64 KB"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EXEC-006 argv contains a >64 KB token"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-007: claude resume_agent with 256 KB prompt ==="
# ---------------------------------------------------------------------------
: > "$ARGS_FILE"; : > "$TOKENS_FILE"; : > "$STDIN_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=claude \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
CLI_ARGV_TOKENS_FILE="$TOKENS_FILE" \
CLI_STDIN_FILE="$STDIN_FILE" \
BIG_PROMPT_FILE="$BIG_PROMPT_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  BIG=$(cat "$BIG_PROMPT_FILE")
  source "'"$LIB"'"
  resume_agent "'"$SESSION_ID"'" "$BIG" "" ""
' >/dev/null 2>&1
rc=$?

assert_eq "TC-EXEC-007 resume_agent claude returns 0 with large prompt" 0 "$rc"
stdin_size=$(wc -c < "$STDIN_FILE")
assert_eq "TC-EXEC-007 stdin recorder size matches BIG_PROMPT" \
  "$BIG_PROMPT_SIZE" "$stdin_size"

if all_tokens_below_size "$ARGV_SIZE_LIMIT" "$TOKENS_FILE"; then
  echo -e "  ${GREEN}PASS${NC}: TC-EXEC-007 no argv token exceeds 64 KB"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EXEC-007 argv contains a >64 KB token"
  FAIL=$((FAIL + 1))
fi

resume_argv=$(cat "$ARGS_FILE")
assert_contains "TC-EXEC-007 resume argv keeps --resume (structural)" \
  "--resume $SESSION_ID" "$resume_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-008: codex resume_agent with 256 KB prompt ==="
# ---------------------------------------------------------------------------
# resume_agent codex needs a sidecar with a captured thread_id. Plant
# one before running so we exercise the resume branch (not the fallback
# to run_agent).
sidecar="$PID_DIR/codex-thread-$SESSION_ID"
echo "019e1234-aaaa-bbbb-cccc-deadbeefcafe" > "$sidecar"

: > "$ARGS_FILE"; : > "$TOKENS_FILE"; : > "$STDIN_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=codex \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
CLI_ARGV_TOKENS_FILE="$TOKENS_FILE" \
CLI_STDIN_FILE="$STDIN_FILE" \
BIG_PROMPT_FILE="$BIG_PROMPT_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  BIG=$(cat "$BIG_PROMPT_FILE")
  source "'"$LIB"'"
  resume_agent "'"$SESSION_ID"'" "$BIG" "" ""
' >/dev/null 2>&1
rc=$?

assert_eq "TC-EXEC-008 resume_agent codex returns 0 with large prompt" 0 "$rc"
stdin_size=$(wc -c < "$STDIN_FILE")
assert_eq "TC-EXEC-008 stdin recorder size matches BIG_PROMPT" \
  "$BIG_PROMPT_SIZE" "$stdin_size"

if all_tokens_below_size "$ARGV_SIZE_LIMIT" "$TOKENS_FILE"; then
  echo -e "  ${GREEN}PASS${NC}: TC-EXEC-008 no argv token exceeds 64 KB"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EXEC-008 argv contains a >64 KB token"
  FAIL=$((FAIL + 1))
fi

codex_resume_argv=$(cat "$ARGS_FILE")
assert_contains "TC-EXEC-008 resume argv contains 'exec resume'" \
  "exec resume" "$codex_resume_argv"
assert_contains "TC-EXEC-008 resume argv contains the captured thread_id" \
  "019e1234-aaaa-bbbb-cccc-deadbeefcafe" "$codex_resume_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-013: gemini resume_agent with 256 KB prompt ==="
# ---------------------------------------------------------------------------
# Closes the gap pr-review flagged: resume_agent gemini path uses the
# new pipeline shape (printf | cli) but pre-#144 only TC-EXEC-007/008
# exercised resume-side stdin delivery (claude/codex). gemini resume
# rides single-stage (no awk capture) so its rc propagation differs
# from codex's PIPESTATUS[1] case.
: > "$ARGS_FILE"; : > "$TOKENS_FILE"; : > "$STDIN_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=gemini \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
CLI_ARGV_TOKENS_FILE="$TOKENS_FILE" \
CLI_STDIN_FILE="$STDIN_FILE" \
BIG_PROMPT_FILE="$BIG_PROMPT_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  BIG=$(cat "$BIG_PROMPT_FILE")
  source "'"$LIB"'"
  resume_agent "'"$SESSION_ID"'" "$BIG" "" ""
' >/dev/null 2>&1
rc=$?

assert_eq "TC-EXEC-013 resume_agent gemini returns 0 with large prompt" 0 "$rc"
stdin_size=$(wc -c < "$STDIN_FILE")
assert_eq "TC-EXEC-013 stdin recorder size matches BIG_PROMPT" \
  "$BIG_PROMPT_SIZE" "$stdin_size"
if all_tokens_below_size "$ARGV_SIZE_LIMIT" "$TOKENS_FILE"; then
  echo -e "  ${GREEN}PASS${NC}: TC-EXEC-013 no argv token exceeds 64 KB"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EXEC-013 argv contains a >64 KB token"
  FAIL=$((FAIL + 1))
fi

gemini_resume_argv=$(cat "$ARGS_FILE")
assert_contains "TC-EXEC-013 resume argv contains --resume" \
  "--resume $SESSION_ID" "$gemini_resume_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-014: opencode resume_agent with 256 KB prompt ==="
# ---------------------------------------------------------------------------
# resume_agent opencode reads a sidecar ses_<base62> and uses the same
# three-stage shape as codex resume — PIPESTATUS[1] is the rc-bearing
# index. Plant a sidecar so we exercise the resume branch (not the
# fallback to run_agent).
oc_sidecar="$PID_DIR/opencode-session-$SESSION_ID"
echo "ses_TEST123abc" > "$oc_sidecar"

: > "$ARGS_FILE"; : > "$TOKENS_FILE"; : > "$STDIN_FILE"

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=opencode \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
CLI_ARGV_TOKENS_FILE="$TOKENS_FILE" \
CLI_STDIN_FILE="$STDIN_FILE" \
BIG_PROMPT_FILE="$BIG_PROMPT_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  BIG=$(cat "$BIG_PROMPT_FILE")
  source "'"$LIB"'"
  resume_agent "'"$SESSION_ID"'" "$BIG" "" ""
' >/dev/null 2>&1
rc=$?

assert_eq "TC-EXEC-014 resume_agent opencode returns 0 with large prompt" 0 "$rc"
stdin_size=$(wc -c < "$STDIN_FILE")
assert_eq "TC-EXEC-014 stdin recorder size matches BIG_PROMPT" \
  "$BIG_PROMPT_SIZE" "$stdin_size"
if all_tokens_below_size "$ARGV_SIZE_LIMIT" "$TOKENS_FILE"; then
  echo -e "  ${GREEN}PASS${NC}: TC-EXEC-014 no argv token exceeds 64 KB"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EXEC-014 argv contains a >64 KB token"
  FAIL=$((FAIL + 1))
fi

opencode_resume_argv=$(cat "$ARGS_FILE")
assert_contains "TC-EXEC-014 resume argv contains --session" \
  "--session ses_TEST123abc" "$opencode_resume_argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-010: small prompts still work across all CLIs ==="
# ---------------------------------------------------------------------------
SMALL_PROMPT="implement the thing"
for cli in claude codex gemini kiro opencode; do
  : > "$ARGS_FILE"; : > "$TOKENS_FILE"; : > "$STDIN_FILE"
  rm -f "$PID_DIR/codex-thread-"* "$PID_DIR/opencode-session-"* 2>/dev/null

  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD="$cli" \
  AGENT_PERMISSION_MODE=auto \
  CLI_ARGS_FILE="$ARGS_FILE" \
  CLI_ARGV_TOKENS_FILE="$TOKENS_FILE" \
  CLI_STDIN_FILE="$STDIN_FILE" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  source "'"$LIB"'"
    run_agent "'"$SESSION_ID"'" "'"$SMALL_PROMPT"'" "" "issue-1-dev"
  ' >/dev/null 2>&1
  rc=$?

  assert_eq "TC-EXEC-010 run_agent $cli returns 0 for small prompt" 0 "$rc"
  small_stdin=$(cat "$STDIN_FILE")
  assert_eq "TC-EXEC-010 $cli stdin contains the small prompt" \
    "$SMALL_PROMPT" "$small_stdin"
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-011: codex non-zero exit propagates through pipeline ==="
# ---------------------------------------------------------------------------
# Replace the codex stub with one that exits 7. We need to verify that
# PIPESTATUS in the codex case branch surfaces codex's rc, not the
# upstream printf's rc=0. (After the fix, the pipeline grows a leading
# `printf %s "$prompt" |` stage so PIPESTATUS[0] becomes the printf;
# we must read PIPESTATUS for the codex stage instead.)
cat > "$BIN/codex" <<'EOF'
#!/bin/bash
echo "$@" > "$CLI_ARGS_FILE"
for a in "$@"; do printf '%s\n' "$a"; done > "$CLI_ARGV_TOKENS_FILE"
cat > "$CLI_STDIN_FILE"
echo '{"type":"error","message":"auth failed"}'
exit 7
EOF
chmod +x "$BIN/codex"

: > "$ARGS_FILE"; : > "$TOKENS_FILE"; : > "$STDIN_FILE"
rm -f "$PID_DIR/codex-thread-"* 2>/dev/null

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=codex \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
CLI_ARGV_TOKENS_FILE="$TOKENS_FILE" \
CLI_STDIN_FILE="$STDIN_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "small prompt" "" ""
' >/dev/null 2>&1
rc=$?

assert_eq "TC-EXEC-011 codex exit 7 surfaces through run_agent (PIPESTATUS correct)" 7 "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-012: opencode non-zero exit propagates through pipeline ==="
# ---------------------------------------------------------------------------
cat > "$BIN/opencode" <<'EOF'
#!/bin/bash
echo "$@" > "$CLI_ARGS_FILE"
for a in "$@"; do printf '%s\n' "$a"; done > "$CLI_ARGV_TOKENS_FILE"
cat > "$CLI_STDIN_FILE"
echo '{"type":"error","message":"crashed"}'
exit 5
EOF
chmod +x "$BIN/opencode"

: > "$ARGS_FILE"; : > "$TOKENS_FILE"; : > "$STDIN_FILE"
rm -f "$PID_DIR/opencode-session-"* 2>/dev/null

PATH="$BIN:$PATH" \
AUTONOMOUS_PID_DIR="$PID_DIR" \
PROJECT_ID="testproj" \
PROJECT_DIR="$TMPROOT" \
AGENT_CMD=opencode \
AGENT_PERMISSION_MODE=auto \
CLI_ARGS_FILE="$ARGS_FILE" \
CLI_ARGV_TOKENS_FILE="$TOKENS_FILE" \
CLI_STDIN_FILE="$STDIN_FILE" \
bash -c '
  unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
  source "'"$LIB"'"
  run_agent "'"$SESSION_ID"'" "small prompt" "" ""
' >/dev/null 2>&1
rc=$?

assert_eq "TC-EXEC-012 opencode exit 5 surfaces through run_agent (PIPESTATUS correct)" 5 "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
