#!/bin/bash
# test-dispatch-local-empty-session.sh — Unit tests for issue #107.
#
# dispatch-local.sh's dev-resume branch must tolerate an empty session_id.
# dispatcher-tick.sh:314 unconditionally calls
#   dispatch dev-resume "$issue_num" "$session_id"
# from Step 4 (pending-dev scan), and "$session_id" is empty on first-time
# pickup of a pending-dev issue with no prior `Dev Session ID:` comment.
# autonomous-dev.sh:257-260 already falls back to MODE=new when --mode
# resume is invoked without --session, so dispatch-local.sh must forward
# the call (without --session) instead of exiting 1.
#
# Run: bash tests/unit/test-dispatch-local-empty-session.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCHER_SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
DISPATCH_LOCAL="$DISPATCHER_SCRIPTS/dispatch-local.sh"

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
    echo "      needle='$needle' (should NOT appear)"
    echo "      haystack='$haystack'"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# Sandbox: replicate the project-side scripts/ layout that dispatch-local.sh
# expects (autonomous.conf + autonomous-dev.sh stub that records its argv).
# ---------------------------------------------------------------------------

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

PROJ="$TMPROOT/proj"
mkdir -p "$PROJ/scripts" "$PROJ/.pids"

# Stub autonomous-dev.sh: record argv to a deterministic file and exit 0
# quickly so dispatch-local.sh's `kill -0 $CHILD_PID` post-spawn check can
# see the process is alive (we sleep briefly before exiting).
ARGV_FILE="$TMPROOT/argv.log"
cat > "$PROJ/scripts/autonomous-dev.sh" <<STUB
#!/bin/bash
# Test stub — records argv to capture how dispatch-local.sh forwarded the call.
echo "argv: \$*" >> "$ARGV_FILE"
# Stay alive briefly so the post-spawn kill -0 check in dispatch-local.sh
# (sleep 1 + kill -0) sees a live PID.
sleep 2
exit 0
STUB
chmod +x "$PROJ/scripts/autonomous-dev.sh"

cat > "$PROJ/scripts/autonomous.conf" <<CONF
PROJECT_ID="empty-session-test"
REPO="test/test"
REPO_OWNER="test"
REPO_NAME="test"
PROJECT_DIR="$PROJ"
AGENT_CMD="claude"
GH_AUTH_MODE="token"
PID_DIR="$PROJ/.pids"
CONF

# Symlink dispatch-local.sh + lib chain into the project's scripts/. This is
# the production "shared-install" topology (PR #105) where the project side
# only holds symlinks pointing at the upstream skill checkout.
LIB_FILES=(
  dispatch-local.sh lib-config.sh lib-agent.sh lib-auth.sh
  lib-dispatch.sh lib-review-bots.sh
  gh-app-token.sh gh-with-token-refresh.sh gh-token-refresh-daemon.sh
)
for f in "${LIB_FILES[@]}"; do
  if [[ -f "$DISPATCHER_SCRIPTS/$f" ]]; then
    ln -sf "$DISPATCHER_SCRIPTS/$f" "$PROJ/scripts/$f"
  fi
done

DISPATCH_ENTRY="$PROJ/scripts/dispatch-local.sh"

# Helper: invoke dispatch-local.sh and wait for the stub's argv to land.
# Captures stderr from dispatch-local.sh itself so we can assert on it
# (the pre-fix "session_id required" error message lives there).
run_dispatch() {
  : > "$ARGV_FILE"
  rm -f "$PROJ/.pids/"*.pid 2>/dev/null
  local stderr_capture="$TMPROOT/stderr.log"
  : > "$stderr_capture"
  local rc=0
  ( cd "$PROJ" && bash "$DISPATCH_ENTRY" "$@" >/dev/null 2>"$stderr_capture" ) || rc=$?
  # Wait briefly for the stub to write argv (dispatch-local nohup'd it).
  local _i found=""
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    if [[ -s "$ARGV_FILE" ]]; then
      found=1
      break
    fi
    sleep 0.2
  done
  echo "rc=$rc"
  echo "---argv---"
  cat "$ARGV_FILE" 2>/dev/null
  echo "---stderr---"
  cat "$stderr_capture" 2>/dev/null
  echo "---end---"
}

# ---------------------------------------------------------------------------
echo "=== TC-EMPTY-RESUME-1: dev-resume + empty session → wrapper invoked w/o --session ==="
# ---------------------------------------------------------------------------

OUTPUT=$(run_dispatch dev-resume 99 "")

# Expected post-fix:
#   - exit 0 (no rejection)
#   - argv logged with --mode resume (no --session)
#   - stderr does not contain "session_id required"
assert_contains "exit code 0" "rc=0" "$OUTPUT"
assert_contains "argv contains --mode resume" "--mode resume" "$OUTPUT"
assert_contains "argv contains --issue 99" "--issue 99" "$OUTPUT"
assert_not_contains "argv does NOT contain --session" "--session" "$OUTPUT"
assert_not_contains "stderr does NOT say 'session_id required'" "session_id required" "$OUTPUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EMPTY-RESUME-2: dev-resume + real session → --session forwarded (regression) ==="
# ---------------------------------------------------------------------------

OUTPUT=$(run_dispatch dev-resume 99 abc-session-id-123)

assert_contains "exit code 0" "rc=0" "$OUTPUT"
assert_contains "argv contains --mode resume" "--mode resume" "$OUTPUT"
assert_contains "argv contains --session abc-session-id-123" "--session abc-session-id-123" "$OUTPUT"
assert_contains "argv contains --issue 99" "--issue 99" "$OUTPUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EMPTY-RESUME-3: dev-new path unaffected (regression) ==="
# ---------------------------------------------------------------------------

OUTPUT=$(run_dispatch dev-new 99)

assert_contains "exit code 0" "rc=0" "$OUTPUT"
assert_contains "argv contains --mode new" "--mode new" "$OUTPUT"
assert_contains "argv contains --issue 99" "--issue 99" "$OUTPUT"
assert_not_contains "argv does NOT contain --session" "--session" "$OUTPUT"

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
