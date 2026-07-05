#!/bin/bash
# test-pid-alive-long-running.sh — Unit tests for issue #129.
#
# Two-part regression:
#   Fix A: kill_stale_wrapper does NOT delete the PID file when its
#          `kill -0 <old_pid>` miss path is taken (no actual kill happened).
#   Fix B: install_agent_heartbeat writes a sibling `<base>.heartbeat`
#          file alongside AGENT_PID_FILE; pid_alive's mtime fallback
#          consults EITHER file.
#
# Run: bash tests/unit/test-pid-alive-long-running.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Required env (the libs enforce these via : "${VAR:?...}")
export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-proj-pid-alive-long-running
export MAX_RETRIES=3
export MAX_CONCURRENT=5

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"; jobs -p | xargs -r kill 2>/dev/null || true' EXIT

assert_rc() {
  local label="$1" rc="$2" expected="$3"
  if [ "$rc" = "$expected" ]; then
    echo -e "  ${GREEN}PASS${NC}: $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $label (rc=$rc, expected $expected)"
    FAIL=$((FAIL + 1))
  fi
}

assert_true() {
  local label="$1" cond="$2"
  if [ "$cond" = "1" ]; then
    echo -e "  ${GREEN}PASS${NC}: $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $label"
    FAIL=$((FAIL + 1))
  fi
}

# Helper: set a file's mtime to N seconds ago (Linux + macOS).
touch_age() {
  local path="$1" age="$2" t
  t=$(date -u -d "@$(( $(date +%s) - age ))" +"%Y%m%d%H%M.%S" 2>/dev/null \
    || date -u -v-"${age}"S +"%Y%m%d%H%M.%S")
  touch -t "$t" "$path"
}

# ---------------------------------------------------------------------------
# Source the dispatcher's libraries. lib-dispatch.sh sets `set -e` which
# would abort the test process on any returning-1 helper, so disable it.
# lib-agent.sh has `set -u` requirements; isolate with `set +u`.
# ---------------------------------------------------------------------------

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib-dispatch.sh"
set +e

set +u
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib-agent.sh" 2>/dev/null || true
set -u

# Source kill_stale_wrapper as a function. dispatch-local.sh runs
# top-level statements when sourced; we need the function only.
# Extract just the function definition into a temp file and source it.
# [Lane-GC PR-3 / INV-111]: kill_stale_wrapper now calls the sibling helper
# `_pid_or_group_alive` — capture both function bodies (no early `exit` on
# the first closing brace, so the second definition is also captured).
KILL_FN_FILE=$(mktemp)
awk '
  /^(_pid_or_group_alive|kill_stale_wrapper)\(\) \{/ { capturing = 1 }
  capturing { print }
  capturing && /^\}/ { capturing = 0 }
' "$SCRIPTS_DIR/dispatch-local.sh" >"$KILL_FN_FILE"
# shellcheck disable=SC1090
source "$KILL_FN_FILE"
rm -f "$KILL_FN_FILE"

# Override _pid_file_for so pid_alive picks up our test paths.
_pid_file_for() { echo "$PIDFILE"; }

# ---------------------------------------------------------------------------
# Fix A tests — kill_stale_wrapper PID-file preservation
# ---------------------------------------------------------------------------

echo
echo "=== TC-PALR-001: kill_stale_wrapper preserves PID file when kill -0 missed ==="
PIDFILE="$TMPDIR/issue-1.pid"
echo "999999" >"$PIDFILE"
ORIG_CONTENT=$(cat "$PIDFILE")
# Disable the pgrep fallback so we test the kill -0 miss path in isolation.
KILL_STALE_PGREP_FALLBACK=false \
  PROJECT_DIR="$TMPDIR/proj" \
  PROJECT_ID="$PROJECT_ID" \
  ISSUE_NUM=1 \
  TYPE=dev-resume \
  kill_stale_wrapper "$PIDFILE" >/dev/null 2>&1
KSW_RC=$?
assert_rc "kill_stale_wrapper rc=0 on miss" "$KSW_RC" "0"
if [[ -f "$PIDFILE" ]]; then
  CONTENT_NOW=$(cat "$PIDFILE")
  if [[ "$CONTENT_NOW" == "$ORIG_CONTENT" ]]; then
    assert_true "PID file preserved with original content" "1"
  else
    assert_true "PID file content unchanged (got '$CONTENT_NOW', expected '$ORIG_CONTENT')" "0"
  fi
else
  assert_true "PID file still exists after kill_stale_wrapper miss" "0"
fi

echo
echo "=== TC-PALR-002: kill_stale_wrapper still removes PID file after a successful kill ==="
PIDFILE="$TMPDIR/issue-2.pid"
# Spawn a real sleep so kill -0 succeeds and SIGTERM lands.
sleep 30 &
TARGET_PID=$!
echo "$TARGET_PID" >"$PIDFILE"
KILL_STALE_PGREP_FALLBACK=false \
  PROJECT_DIR="$TMPDIR/proj" \
  PROJECT_ID="$PROJECT_ID" \
  ISSUE_NUM=2 \
  TYPE=dev-resume \
  kill_stale_wrapper "$PIDFILE" >/dev/null 2>&1
KSW_RC=$?
# Reap the killed child so it doesn't show as zombie.
wait "$TARGET_PID" 2>/dev/null || true
assert_rc "kill_stale_wrapper rc=0 on hit" "$KSW_RC" "0"
if [[ ! -f "$PIDFILE" ]]; then
  assert_true "PID file removed after successful kill" "1"
else
  assert_true "PID file removed after successful kill (still exists)" "0"
fi

echo
echo "=== TC-PALR-002b: kill_stale_wrapper removes empty PID file (treat as garbage) ==="
PIDFILE="$TMPDIR/issue-3.pid"
: >"$PIDFILE"  # empty
KILL_STALE_PGREP_FALLBACK=false \
  PROJECT_DIR="$TMPDIR/proj" \
  PROJECT_ID="$PROJECT_ID" \
  ISSUE_NUM=3 \
  TYPE=dev-resume \
  kill_stale_wrapper "$PIDFILE" >/dev/null 2>&1
KSW_RC=$?
assert_rc "kill_stale_wrapper rc=0 on empty file" "$KSW_RC" "0"
if [[ ! -f "$PIDFILE" ]]; then
  assert_true "empty PID file removed (no useful liveness data)" "1"
else
  assert_true "empty PID file removed" "0"
fi

# ---------------------------------------------------------------------------
# Fix B tests — heartbeat sibling file
# ---------------------------------------------------------------------------

echo
echo "=== TC-PALR-003: pid_alive ALIVE when heartbeat sibling is fresh, PID file is stale ==="
PIDFILE="$TMPDIR/issue-10.pid"
HBFILE="${PIDFILE%.pid}.heartbeat"
echo "999999" >"$PIDFILE"
touch_age "$PIDFILE" 1000     # stale PID file
: >"$HBFILE"
touch "$HBFILE"               # fresh heartbeat
HEARTBEAT_INTERVAL_SECONDS=10 pid_alive issue 10
assert_rc "pid_alive ALIVE via fresh heartbeat sibling" "$?" "0"

echo
echo "=== TC-PALR-003b: pid_alive ALIVE when PID file is gone but heartbeat sibling is fresh ==="
PIDFILE="$TMPDIR/issue-11.pid"
HBFILE="${PIDFILE%.pid}.heartbeat"
# Simulate the #129 mid-flight deletion: PID file gone, heartbeat survives.
rm -f "$PIDFILE"
: >"$HBFILE"
touch "$HBFILE"
HEARTBEAT_INTERVAL_SECONDS=10 pid_alive issue 11
assert_rc "pid_alive ALIVE via heartbeat alone (#129 repro)" "$?" "0"

echo
echo "=== TC-PALR-004: pid_alive DEAD when both PID file and heartbeat sibling are stale ==="
PIDFILE="$TMPDIR/issue-12.pid"
HBFILE="${PIDFILE%.pid}.heartbeat"
echo "999999" >"$PIDFILE"
touch_age "$PIDFILE" 1000
: >"$HBFILE"
touch_age "$HBFILE" 1000
HEARTBEAT_INTERVAL_SECONDS=10 pid_alive issue 12
assert_rc "pid_alive DEAD when both files stale" "$?" "1"

echo
echo "=== TC-PALR-004b: pid_alive DEAD when PID file is gone AND heartbeat absent ==="
PIDFILE="$TMPDIR/issue-13.pid"
HBFILE="${PIDFILE%.pid}.heartbeat"
rm -f "$PIDFILE" "$HBFILE"
HEARTBEAT_INTERVAL_SECONDS=10 pid_alive issue 13
assert_rc "pid_alive DEAD when both files absent" "$?" "1"

# ---------------------------------------------------------------------------
# install_agent_heartbeat must touch the heartbeat sibling
# ---------------------------------------------------------------------------

if ! type install_agent_heartbeat >/dev/null 2>&1; then
  echo -e "  ${RED}FAIL${NC}: install_agent_heartbeat is not defined in lib-agent.sh"
  FAIL=$((FAIL + 1))
else
  echo
  echo "=== TC-PALR-005: heartbeat advances mtime of sibling .heartbeat file ==="
  PIDFILE="$TMPDIR/issue-20.pid"
  HBFILE="${PIDFILE%.pid}.heartbeat"
  echo "$$" >"$PIDFILE"
  : >"$HBFILE"
  touch_age "$PIDFILE" 1000
  touch_age "$HBFILE" 1000
  before_pid_mtime=$(stat -c %Y "$PIDFILE" 2>/dev/null || stat -f %m "$PIDFILE")
  before_hb_mtime=$(stat -c %Y "$HBFILE" 2>/dev/null || stat -f %m "$HBFILE")

  AGENT_PID_FILE="$PIDFILE" HEARTBEAT_INTERVAL_SECONDS=1 \
    install_agent_heartbeat
  hb_pid="${_AGENT_HEARTBEAT_PID:-}"
  sleep 2
  after_pid_mtime=$(stat -c %Y "$PIDFILE" 2>/dev/null || stat -f %m "$PIDFILE")
  after_hb_mtime=$(stat -c %Y "$HBFILE" 2>/dev/null || stat -f %m "$HBFILE")
  [ -n "$hb_pid" ] && command kill "$hb_pid" 2>/dev/null || true

  if [ "$after_pid_mtime" -gt "$before_pid_mtime" ]; then
    assert_true "heartbeat advanced PID-file mtime ($before_pid_mtime → $after_pid_mtime)" "1"
  else
    assert_true "heartbeat advanced PID-file mtime ($before_pid_mtime → $after_pid_mtime)" "0"
  fi
  if [ "$after_hb_mtime" -gt "$before_hb_mtime" ]; then
    assert_true "heartbeat advanced sibling mtime ($before_hb_mtime → $after_hb_mtime)" "1"
  else
    assert_true "heartbeat advanced sibling mtime ($before_hb_mtime → $after_hb_mtime)" "0"
  fi

  echo
  echo "=== TC-PALR-005b: heartbeat creates the sibling file if it does not exist yet ==="
  PIDFILE="$TMPDIR/issue-21.pid"
  HBFILE="${PIDFILE%.pid}.heartbeat"
  echo "$$" >"$PIDFILE"
  rm -f "$HBFILE"

  unset _AGENT_HEARTBEAT_PID
  AGENT_PID_FILE="$PIDFILE" HEARTBEAT_INTERVAL_SECONDS=1 \
    install_agent_heartbeat
  hb_pid="${_AGENT_HEARTBEAT_PID:-}"
  sleep 2
  [ -n "$hb_pid" ] && command kill "$hb_pid" 2>/dev/null || true

  if [ -f "$HBFILE" ]; then
    assert_true "heartbeat sibling created when missing" "1"
  else
    assert_true "heartbeat sibling created when missing (still absent)" "0"
  fi

  echo
  echo "=== TC-PALR-005c: heartbeat does NOT resurrect files after parent exit ==="
  # Race: cleanup trap deletes both files, then heartbeat loop wakes from
  # sleep. Without the inner kill -0 re-check, the loop's `touch` would
  # recreate the heartbeat sibling with a fresh mtime — leaving the
  # dispatcher to see a fake-ALIVE wrapper for up to 6 minutes after
  # the wrapper actually exited. This test reproduces that window.
  HB_PIDFILE_R="$TMPDIR/hb-resurrect.pid"
  HB_FILE_R="${HB_PIDFILE_R%.pid}.heartbeat"

  # Run the parent in a subshell so we can synchronously wait for it to
  # exit before checking. The parent installs heartbeat (interval=1),
  # sleeps long enough for the loop to enter `sleep 1`, then exits.
  bash -c "
    set +u
    source '$SCRIPTS_DIR/lib-agent.sh' 2>/dev/null || true
    set -u
    AGENT_PID_FILE='$HB_PIDFILE_R' HEARTBEAT_INTERVAL_SECONDS=1 install_agent_heartbeat
    # Touch both files first so the loop has something to refresh.
    echo \$\$ >'$HB_PIDFILE_R'
    : >'$HB_FILE_R'
    # Let the loop iterate at least once, then sleep partway into its
    # next sleep so it's blocked when we exit.
    sleep 1.5
  " &
  parent_pid=$!
  wait "$parent_pid" 2>/dev/null || true

  # Immediately delete both files (simulating the cleanup trap). The
  # heartbeat subshell is still asleep at this point.
  rm -f "$HB_PIDFILE_R" "$HB_FILE_R"

  # Wait long enough for the heartbeat loop to wake from its sleep
  # (interval=1) AND complete its parent-pid re-check. 3s gives margin.
  sleep 3

  # Neither file should have been resurrected.
  if [ ! -e "$HB_PIDFILE_R" ] && [ ! -e "$HB_FILE_R" ]; then
    assert_true "heartbeat did not resurrect files after parent exit" "1"
  else
    resurrected=""
    [ -e "$HB_PIDFILE_R" ] && resurrected="$resurrected pid_file"
    [ -e "$HB_FILE_R" ]    && resurrected="$resurrected hb_file"
    assert_true "heartbeat did not resurrect files after parent exit (resurrected:$resurrected)" "0"
    rm -f "$HB_PIDFILE_R" "$HB_FILE_R"
  fi
fi

# ---------------------------------------------------------------------------
# Static-analysis pins so the invariant cross-references can't silently rot
# ---------------------------------------------------------------------------

echo
echo "=== TC-PALR-STATIC-001: source files reference INV-29 ==="
if grep -q "INV-29" "$SCRIPTS_DIR/dispatch-local.sh"; then
  assert_true "dispatch-local.sh mentions INV-29" "1"
else
  assert_true "dispatch-local.sh mentions INV-29" "0"
fi
if grep -q "INV-29" "$SCRIPTS_DIR/lib-agent.sh"; then
  assert_true "lib-agent.sh mentions INV-29" "1"
else
  assert_true "lib-agent.sh mentions INV-29" "0"
fi
if grep -q "INV-29" "$SCRIPTS_DIR/lib-dispatch.sh"; then
  assert_true "lib-dispatch.sh mentions INV-29" "1"
else
  assert_true "lib-dispatch.sh mentions INV-29" "0"
fi

echo
echo "=== TC-PALR-STATIC-002: kill_stale_wrapper does NOT touch *.heartbeat ==="
# The heartbeat file is owned exclusively by the wrapper; the dispatcher
# must never delete it. A grep for `.heartbeat` in dispatch-local.sh would
# only be present if a future change accidentally widened the cleanup.
if ! grep -E '\.heartbeat' "$SCRIPTS_DIR/dispatch-local.sh" >/dev/null; then
  assert_true "dispatch-local.sh contains no '.heartbeat' references" "1"
else
  assert_true "dispatch-local.sh must not reference '.heartbeat' (would risk deletion)" "0"
fi

echo
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[ "$FAIL" -eq 0 ]
