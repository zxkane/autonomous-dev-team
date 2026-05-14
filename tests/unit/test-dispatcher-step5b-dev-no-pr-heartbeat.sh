#!/bin/bash
# test-dispatcher-step5b-dev-no-pr-heartbeat.sh — Regression for the
# false-alarm class observed on podcast-curation#200 (2026-05-14 00:50 UTC):
# a dev-new wrapper still mid-design (no PR yet) was declared crashed
# because pid_alive returned DEAD on a transient probe, falling through
# to Step 5b's "no PR — Task appears to have crashed (no PR found)" branch.
#
# This test pins two parts of the contract the #111 fix relies on for
# dev-side coverage:
#
#   1. pid_alive's mtime fallback ([INV-24], lib-dispatch.sh) returns 0
#      (ALIVE) when `kill -0 <pid>` fails BUT the PID file's mtime is
#      within HEARTBEAT_INTERVAL_SECONDS * 3 — same code path the dev
#      wrapper relies on while the agent is still in design / write-tests
#      / implement phase before any commit lands.
#
#   2. dispatcher-tick.sh's Step 5b "no PR found" branch is reached only
#      under the OUTER `else` of the pid_alive check. So pid_alive
#      returning ALIVE is structurally sufficient to skip the crash
#      declaration, regardless of PR existence.
#
# (1) is checked at the helper level (sources lib-dispatch.sh and stubs
# the PID file). (2) is checked statically by grepping the tick script
# to ensure the no-PR comment lives only inside the DEAD branch — a
# refactor that hoisted it would silently re-introduce the #200 bug.
#
# Run: bash tests/unit/test-dispatcher-step5b-dev-no-pr-heartbeat.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-step5b-dev
export MAX_RETRIES=3
export MAX_CONCURRENT=5

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PIDFILE="$TMPDIR/issue-200.pid"

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

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/lib-dispatch.sh"
set +e

# Stub _pid_file_for so pid_alive picks up our test PIDFILE for any kind.
_pid_file_for() { echo "$PIDFILE"; }

echo
echo "=== TC-200-1: kind=issue, dead PID, fresh heartbeat → pid_alive=ALIVE ==="
# Simulates the #200 scenario: wrapper has been running 15 min, claude
# is still in design phase (no commits, no PR), but its background
# heartbeat keeps the PID-file mtime fresh. A transient kill -0 miss
# (race) MUST NOT flip pid_alive to DEAD.
echo "999999" >"$PIDFILE"
touch "$PIDFILE"
HEARTBEAT_INTERVAL_SECONDS=120 pid_alive issue 200
assert_rc "fresh heartbeat keeps dev wrapper ALIVE despite kill -0 miss" "$?" "0"

echo
echo "=== TC-200-2: kind=issue, dead PID, stale mtime → pid_alive=DEAD ==="
# Counter-test: when the heartbeat genuinely stops (wrapper crashed,
# heartbeat parent-pid watchdog took it down), mtime stops advancing
# and pid_alive correctly returns DEAD.
echo "999999" >"$PIDFILE"
old_t=$(date -u -d "@$(( $(date +%s) - 1000 ))" +"%Y%m%d%H%M.%S" 2>/dev/null \
  || date -u -v-1000S +"%Y%m%d%H%M.%S")
touch -t "$old_t" "$PIDFILE"
HEARTBEAT_INTERVAL_SECONDS=120 pid_alive issue 200
assert_rc "stale heartbeat → DEAD (real crash still detected)" "$?" "1"

echo
echo "=== TC-200-3: structural — Step 5b no-PR branch is gated by pid_alive DEAD ==="
# Static grep guard: the "Task appears to have crashed (no PR found)"
# comment MUST live only inside Step 5b's outer DEAD branch (the OUTER
# `else` clause of the pid_alive check). Hoisting it out would
# re-introduce the #200 bug — so we pin the structure here.
TICK="$SCRIPTS_DIR/dispatcher-tick.sh"
# Find the line of the crash comment.
crash_line=$(grep -n "Task appears to have crashed (no PR found)" "$TICK" | head -1 | cut -d: -f1)
if [ -z "$crash_line" ]; then
  assert_true "no-PR crash comment exists in dispatcher-tick.sh" "0"
else
  # Walk backwards looking for either `if pid_alive` (new structure: gated)
  # or a top-level `if` that doesn't depend on pid_alive (regression).
  # Step 5b's pid_alive gate is the outer `if pid_alive ... else` block.
  # The comment must appear AFTER an `else` AFTER an `if pid_alive`.
  preceding=$(awk -v stop="$crash_line" 'NR < stop' "$TICK")
  # Use POSIX-portable bracket expressions only — `\s` and `\b` are GNU
  # grep extensions that BSD/POSIX grep on macOS or Alpine will miss
  # (per Q-bot review on PR #114). The trailing `[^[:alnum:]_]` plays
  # the role of `\b` against the next character (call site is always
  # followed by whitespace or a paren in this codebase).
  last_if=$(printf '%s\n' "$preceding" | grep -nE "^[[:space:]]*if[[:space:]]+pid_alive[^[:alnum:]_]|^[[:space:]]*if[[:space:]]+![[:space:]]*pid_alive[^[:alnum:]_]" | tail -1 | cut -d: -f1)
  last_else=$(printf '%s\n' "$preceding" | grep -nE "^[[:space:]]*else[[:space:]]*$|^[[:space:]]*else[[:space:]]*#" | tail -1 | cut -d: -f1)
  if [ -n "$last_if" ] && [ -n "$last_else" ] && [ "$last_else" -gt "$last_if" ]; then
    assert_true "no-PR crash comment is gated behind 'if pid_alive ... else'" "1"
  else
    assert_true "no-PR crash comment is gated behind 'if pid_alive ... else' (last_if=$last_if, last_else=$last_else)" "0"
  fi
fi

echo
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[ "$FAIL" -eq 0 ]
