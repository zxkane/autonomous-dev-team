#!/bin/bash
# test-autonomous-dev-cleanup-startup-failure.sh — verify that
# autonomous-dev.sh's cleanup trap posts an "Agent Session Report (Dev)"
# comment when the wrapper exits before the agent runs (closes issue #92
# Part 2). Pre-#92 the cleanup returned silently in this case, which left
# the dispatcher misdiagnosing the failure as a "crash" instead of an
# "agent failure" — see the issue body for the misdiagnosis chain.
#
# Strategy: extract the cleanup() function from autonomous-dev.sh and
# run it inside a harness with a stubbed `gh` and a stubbed
# `cleanup_github_auth`, varying AGENT_RAN/ISSUE_NUMBER per case.
#
# Run: bash tests/unit/test-autonomous-dev-cleanup-startup-failure.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    echo "      haystack='$haystack'"
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
    echo "      should NOT contain: '$needle'"
    FAIL=$((FAIL + 1))
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Extract cleanup() from autonomous-dev.sh. The function spans from
# `^cleanup\(\) \{` to the next standalone `^}` at column 0.
CLEANUP_FN=$(awk '/^cleanup\(\) \{/,/^\}/' "$WRAPPER")
if [[ -z "$CLEANUP_FN" ]]; then
  echo -e "${RED}FAIL${NC}: could not extract cleanup() from $WRAPPER"
  exit 1
fi

# Recording stub for gh on PATH. Captures argv to a record file.
STUB_DIR="$TMPROOT/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/gh" <<'EOF'
#!/bin/bash
echo "GH $*" >> "$GH_RECORD"
exit 0
EOF
chmod +x "$STUB_DIR/gh"

# Run the cleanup harness with a controlled scenario. Invoking $exit_code
# inside the function uses bash's built-in `$?` of the previous command,
# so we deliberately invoke `(exit N); cleanup` to seed it.
#
# AGENT_CMD / AGENT_DEV_MODEL use the non-colon `${6-default}` /
# `${7-default}` parameter expansion: a missing positional renders
# the default, while a set-but-empty positional ("") propagates as
# empty so the *wrapper's* expansion (which uses `-` / `:-` per the
# semantics under test) decides the rendered value. This is
# load-bearing — switching to `${6:-default}` collapses the
# set-but-empty case onto the default-fallback path, masking
# TC-CL-006 / TC-CL-007 entirely.
run_cleanup() {
  local label="$1" agent_ran="$2" issue_num="$3" want_exit="$4" mode="${5:-new}"
  local agent_cmd="${6-claude}" agent_dev_model="${7-sonnet}"
  local record="$TMPROOT/gh-${label}.log"
  local stderr_log="$TMPROOT/stderr-${label}.log"
  : > "$record"
  : > "$stderr_log"

  PATH="$STUB_DIR:$PATH" \
  GH_RECORD="$record" \
  AGENT_RAN="$agent_ran" \
  ISSUE_NUMBER="$issue_num" \
  REPO="acme/widget" \
  PID_FILE="/dev/null" \
  SESSION_ID="test-session" \
  LOG_FILE="/tmp/test.log" \
  GH_AUTH_MODE="token" \
  RECEIVED_SIGTERM=0 \
  MODE="$mode" \
  AGENT_CMD="$agent_cmd" \
  AGENT_DEV_MODEL="$agent_dev_model" \
  bash -c "
    set +e
    log() { echo \"[test-log] \$*\" >&2; }
    cleanup_github_auth() { :; }
    $CLEANUP_FN
    (exit $want_exit); cleanup
  " 2>"$stderr_log"
  GH_LOG=$(cat "$record")
  STDERR_LOG=$(cat "$stderr_log")
}

# ---------------------------------------------------------------------------
echo "=== TC-CL-001: AGENT_RAN=false + ISSUE_NUMBER set + exit 1 → posts startup-failure report ==="
# ---------------------------------------------------------------------------
run_cleanup "001" "false" "42" 1

assert_contains "gh issue comment fired" \
  "GH issue comment 42" "$GH_LOG"
assert_contains "comment body has Agent Session Report (Dev) marker" \
  "Agent Session Report (Dev)" "$GH_LOG"
assert_contains "comment body has Exit code: 1" \
  "Exit code: 1" "$GH_LOG"
assert_contains "comment body has startup-failure mode" \
  "Mode: startup-failure" "$GH_LOG"
assert_contains "label edit removes in-progress" \
  "--remove-label in-progress" "$GH_LOG"
assert_contains "label edit adds pending-dev" \
  "--add-label pending-dev" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CL-002: AGENT_RAN=false + ISSUE_NUMBER unset → silent (no comment) ==="
# ---------------------------------------------------------------------------
run_cleanup "002" "false" "" 1

assert_not_contains "no gh issue comment when ISSUE_NUMBER unset" \
  "GH issue comment" "$GH_LOG"
assert_not_contains "no gh issue edit when ISSUE_NUMBER unset" \
  "GH issue edit" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CL-003: AGENT_RAN=true + exit 0 → normal session report (NOT startup-failure) ==="
# ---------------------------------------------------------------------------
run_cleanup "003" "true" "42" 0

assert_contains "normal session report posted" \
  "Agent Session Report (Dev)" "$GH_LOG"
assert_not_contains "NOT startup-failure mode" \
  "Mode: startup-failure" "$GH_LOG"
assert_contains "Mode: new for normal exit" \
  "Mode: new" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CL-004: startup-failure path with codex/gpt-5.1-codex-max emits Agent + Model ==="
# ---------------------------------------------------------------------------
run_cleanup "004" "false" "42" 1 "new" "codex" "gpt-5.1-codex-max"

assert_contains "TC-CL-004 has Agent: codex" \
  "Agent: codex" "$GH_LOG"
assert_contains "TC-CL-004 has Model: gpt-5.1-codex-max" \
  "Model: gpt-5.1-codex-max" "$GH_LOG"
assert_contains "TC-CL-004 still has startup-failure marker" \
  "Mode: startup-failure" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CL-005: normal-exit path with opencode/long-bedrock-model emits Agent + Model ==="
# ---------------------------------------------------------------------------
run_cleanup "005" "true" "42" 0 "new" "opencode" "amazon-bedrock/global.anthropic.claude-opus-4-7"

assert_contains "TC-CL-005 has Agent: opencode" \
  "Agent: opencode" "$GH_LOG"
assert_contains "TC-CL-005 has long bedrock Model" \
  "Model: amazon-bedrock/global.anthropic.claude-opus-4-7" "$GH_LOG"
assert_contains "TC-CL-005 still has Agent Session Report (Dev)" \
  "Agent Session Report (Dev)" "$GH_LOG"
assert_contains "TC-CL-005 still has Mode: new" \
  "Mode: new" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CL-006: empty AGENT_DEV_MODEL renders Model: <default> (adjacent assert) ==="
# ---------------------------------------------------------------------------
# AGENT_DEV_MODEL="" set-but-empty — exercises the load-bearing
# `:-` (colon-minus) parameter expansion in the wrapper. The wrapper
# uses `:-<default>` so both unset and set-but-empty render `<default>`,
# because lib-agent.sh:42 defaults AGENT_DEV_MODEL to "" and that's the
# dominant operator-side case for unconfigured deployments. The
# *harness* (run_cleanup) uses the *non-colon* `${7-sonnet}` form for
# its positionals so a passed `""` propagates as empty (test author's
# intent: "exercise the empty path") rather than collapsing onto the
# default. The two `-` vs `:-` choices live in opposite directions
# on purpose. (#128 spec — see also TC-CL-STATIC-001 below.)
#
# Adjacency assert: the gh stub records each `gh ... --body "<heredoc>"`
# call as one argv line in the log, with the heredoc's embedded newlines
# preserved. So `- Agent: gemini` and `- Model: <default>` appear on
# adjacent lines, separated by `\n- `. Assert that adjacency literally —
# a bare substring assert on `Model: <default>` could match an unrelated
# `<default>` elsewhere in a future refactor.
run_cleanup "006" "true" "42" 0 "new" "gemini" ""

ADJACENT_NEEDLE=$'- Agent: gemini\n- Model: <default>'
assert_contains "TC-CL-006 Agent: gemini and Model: <default> appear adjacent" \
  "$ADJACENT_NEEDLE" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CL-007: empty AGENT_CMD renders Agent: claude (locks in :-claude fallback) ==="
# ---------------------------------------------------------------------------
run_cleanup "007" "true" "42" 0 "new" "" "sonnet"

assert_contains "TC-CL-007 has Agent: claude (fallback)" \
  "Agent: claude" "$GH_LOG"
assert_contains "TC-CL-007 has Model: sonnet" \
  "Model: sonnet" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CL-008: exit-1 normal path also contains the new fields ==="
# ---------------------------------------------------------------------------
# Locks in that the annotation isn't accidentally gated on exit_code -eq 0.
run_cleanup "008" "true" "42" 1 "new" "claude" "sonnet"

assert_contains "TC-CL-008 has Agent: claude on failure path" \
  "Agent: claude" "$GH_LOG"
assert_contains "TC-CL-008 has Model: sonnet on failure path" \
  "Model: sonnet" "$GH_LOG"
assert_contains "TC-CL-008 still records Exit code: 1" \
  "Exit code: 1" "$GH_LOG"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CL-STATIC-001: harness uses non-colon ${6-default} for AGENT_CMD positional ==="
# ---------------------------------------------------------------------------
# Pin the run_cleanup harness's non-colon `${6-claude}` / `${7-sonnet}`
# parameter expansion so a reflexive cleanup PR can't silently flip them to
# `${6:-claude}` and `${7:-sonnet}`. The non-colon form is what lets a
# *missing* positional render the harness default ("test author asked for
# the default") while a *passed empty positional* propagates as empty
# ("test author asked for the empty-string path") — the two cases stay
# distinguishable. The wrapper itself uses `:-` (colon) for the opposite
# reason; see TC-CL-006 docstring + autonomous-dev.sh comment.
HARNESS_FILE="$0"
if grep -qE 'agent_cmd="\$\{6-claude\}".*agent_dev_model="\$\{7-sonnet\}"' "$HARNESS_FILE"; then
  echo -e "  ${GREEN}PASS${NC}: harness uses non-colon \${6-claude} \${7-sonnet}"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: harness does NOT use non-colon positional defaults"
  grep -n 'agent_cmd=\|agent_dev_model=' "$HARNESS_FILE" || true
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
