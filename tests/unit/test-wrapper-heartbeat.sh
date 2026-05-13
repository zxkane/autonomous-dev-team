#!/bin/bash
# test-wrapper-heartbeat.sh — Unit tests for issue #111 Part B.
#
# Tests:
#   - pid_alive returns 0 when PID is alive (kill -0 path).
#   - pid_alive returns 0 when PID is dead but PID-file mtime is fresh
#     (within HEARTBEAT_INTERVAL_SECONDS * 3).
#   - pid_alive returns 1 when PID is dead AND mtime is stale.
#   - install_agent_heartbeat touches the PID file at least once during
#     its interval.
#   - install_agent_heartbeat exits cleanly when its parent shell exits
#     (no orphan loop).
#   - HEARTBEAT_INTERVAL_SECONDS=0 disables heartbeat (no spawn).
#
# Run: bash tests/unit/test-wrapper-heartbeat.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Required env (sourced libs enforce these via : "${VAR:?...}")
export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-proj-heartbeat
export MAX_RETRIES=3
export MAX_CONCURRENT=5

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"; jobs -p | xargs -r kill 2>/dev/null || true' EXIT

PIDFILE="$TMPDIR/issue-1.pid"

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

# ---------------------------------------------------------------------------
# pid_alive tests — invoke the helper directly via a stubbed _pid_file_for.
# ---------------------------------------------------------------------------

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib-dispatch.sh"
# lib-dispatch.sh sets -e; turn it off so a returning-1 helper doesn't
# abort the test process before the assertion harness can read $?.
set +e

# Override _pid_file_for so pid_alive picks up our test PIDFILE.
_pid_file_for() { echo "$PIDFILE"; }

echo
echo "=== TC-HB-001: pid_alive — live PID returns 0 ==="
# Use the current shell's PID — it's guaranteed alive.
echo $$ >"$PIDFILE"
pid_alive issue 1
assert_rc "live PID → alive" "$?" "0"

echo
echo "=== TC-HB-002: pid_alive — dead PID, fresh mtime → 0 ==="
echo "999999" >"$PIDFILE"
HEARTBEAT_INTERVAL_SECONDS=10 pid_alive issue 1
assert_rc "dead PID + fresh mtime → alive" "$?" "0"

echo
echo "=== TC-HB-003: pid_alive — dead PID, stale mtime → 1 ==="
echo "999999" >"$PIDFILE"
# Set mtime to 1000s ago. HEARTBEAT_INTERVAL_SECONDS=10 → threshold 30s.
old_t=$(date -u -d "@$(( $(date +%s) - 1000 ))" +"%Y%m%d%H%M.%S" 2>/dev/null \
  || date -u -v-1000S +"%Y%m%d%H%M.%S")
touch -t "$old_t" "$PIDFILE"
HEARTBEAT_INTERVAL_SECONDS=10 pid_alive issue 1
assert_rc "dead PID + stale mtime → dead" "$?" "1"

echo
echo "=== TC-HB-004: pid_alive — HEARTBEAT_INTERVAL_SECONDS=0 falls back to legacy ==="
# With heartbeat disabled, the mtime fallback should NOT save a dead PID.
echo "999999" >"$PIDFILE"
touch "$PIDFILE"
HEARTBEAT_INTERVAL_SECONDS=0 pid_alive issue 1
assert_rc "heartbeat=0 + dead PID → dead (legacy)" "$?" "1"

# ---------------------------------------------------------------------------
# install_agent_heartbeat tests — must source lib-agent.sh, which has its
# own deps. We isolate by exporting AGENT_PID_FILE and calling the helper
# directly in a subshell.
# ---------------------------------------------------------------------------

# Avoid lib-agent.sh's heavy dependencies by stubbing what we need and
# then sourcing only the helper. Since lib-agent.sh sources lib-config.sh,
# we need PROJECT_ID set (already exported above).

# Some functions in lib-agent.sh need lib-config.sh helpers; sourcing the
# whole file is safe under set +u (we don't trigger run_agent here).
set +u
# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib-agent.sh" 2>/dev/null || true
set -u

if ! type install_agent_heartbeat >/dev/null 2>&1; then
  echo -e "  ${RED}FAIL${NC}: install_agent_heartbeat is not defined in lib-agent.sh"
  FAIL=$((FAIL + 1))
else
  echo
  echo "=== TC-HB-005: heartbeat touches PID file ==="
  HB_PIDFILE="$TMPDIR/hb-touch.pid"
  echo "$$" >"$HB_PIDFILE"
  # Set mtime far in the past so an advance is unmistakable.
  old_t=$(date -u -d "@$(( $(date +%s) - 1000 ))" +"%Y%m%d%H%M.%S" 2>/dev/null \
    || date -u -v-1000S +"%Y%m%d%H%M.%S")
  touch -t "$old_t" "$HB_PIDFILE"
  before_mtime=$(stat -c %Y "$HB_PIDFILE" 2>/dev/null || stat -f %m "$HB_PIDFILE")

  AGENT_PID_FILE="$HB_PIDFILE" HEARTBEAT_INTERVAL_SECONDS=1 \
    install_agent_heartbeat
  hb_pid="${_AGENT_HEARTBEAT_PID:-}"
  sleep 2
  after_mtime=$(stat -c %Y "$HB_PIDFILE" 2>/dev/null || stat -f %m "$HB_PIDFILE")
  # Tear down the heartbeat we spawned.
  [ -n "$hb_pid" ] && command kill "$hb_pid" 2>/dev/null || true

  if [ "$after_mtime" -gt "$before_mtime" ]; then
    assert_true "heartbeat advanced mtime ($before_mtime → $after_mtime)" "1"
  else
    assert_true "heartbeat advanced mtime ($before_mtime → $after_mtime)" "0"
  fi

  echo
  echo "=== TC-HB-006: HEARTBEAT_INTERVAL_SECONDS=0 disables heartbeat ==="
  HB_PIDFILE2="$TMPDIR/hb-disabled.pid"
  echo "$$" >"$HB_PIDFILE2"
  old_t=$(date -u -d "@$(( $(date +%s) - 1000 ))" +"%Y%m%d%H%M.%S" 2>/dev/null \
    || date -u -v-1000S +"%Y%m%d%H%M.%S")
  touch -t "$old_t" "$HB_PIDFILE2"
  before_mtime=$(stat -c %Y "$HB_PIDFILE2" 2>/dev/null || stat -f %m "$HB_PIDFILE2")
  unset _AGENT_HEARTBEAT_PID
  AGENT_PID_FILE="$HB_PIDFILE2" HEARTBEAT_INTERVAL_SECONDS=0 \
    install_agent_heartbeat
  sleep 2
  after_mtime=$(stat -c %Y "$HB_PIDFILE2" 2>/dev/null || stat -f %m "$HB_PIDFILE2")
  if [ "$after_mtime" = "$before_mtime" ] && [ -z "${_AGENT_HEARTBEAT_PID:-}" ]; then
    assert_true "interval=0 → no spawn, no mtime advance" "1"
  else
    assert_true "interval=0 → no spawn, no mtime advance (got hb_pid='${_AGENT_HEARTBEAT_PID:-}', mtime $before_mtime → $after_mtime)" "0"
  fi

  echo
  echo "=== TC-HB-007: heartbeat exits when parent exits ==="
  HB_PIDFILE3="$TMPDIR/hb-orphan.pid"
  echo "$$" >"$HB_PIDFILE3"
  # Spawn a subshell that installs heartbeat then exits. The heartbeat's
  # parent-pid watchdog should make it exit promptly.
  hb_child_pid=$(
    bash -c "
      set +u
      source '$SCRIPTS_DIR/lib-agent.sh' 2>/dev/null || true
      set -u
      AGENT_PID_FILE='$HB_PIDFILE3' HEARTBEAT_INTERVAL_SECONDS=1 install_agent_heartbeat
      echo \"\${_AGENT_HEARTBEAT_PID:-}\"
    "
  )
  # Give the watchdog up to 4s to react to the parent exit.
  for _ in 1 2 3 4 5 6 7 8; do
    if [ -n "$hb_child_pid" ] && command kill -0 "$hb_child_pid" 2>/dev/null; then
      sleep 1
    else
      break
    fi
  done
  if [ -z "$hb_child_pid" ] || ! command kill -0 "$hb_child_pid" 2>/dev/null; then
    assert_true "heartbeat process exited with parent" "1"
  else
    assert_true "heartbeat process exited with parent (still running pid=$hb_child_pid)" "0"
    command kill -9 "$hb_child_pid" 2>/dev/null || true
  fi
fi

echo
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[ "$FAIL" -eq 0 ]
