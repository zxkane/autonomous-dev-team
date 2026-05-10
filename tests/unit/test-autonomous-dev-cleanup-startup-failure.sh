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
run_cleanup() {
  local label="$1" agent_ran="$2" issue_num="$3" want_exit="$4"
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
  MODE="new" \
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
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
