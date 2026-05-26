#!/bin/bash
# test-pgid-has-agent-process.sh — Unit tests for the per-side argument
# extension of lib-dispatch.sh::_pgid_has_agent_process (agy review
# Finding 2 from PR #156).
#
# Verifies:
#   - Helper accepts an optional 2nd argument (the per-side CLI to
#     match against process comms in the group).
#   - Empty/missing 2nd arg falls back to $AGENT_CMD (back-compat).
#   - Non-matching CLI name returns 1 silently.
#   - Matching CLI name returns 0.
#
# Strategy: spawn a controlled child via `exec -a <name>` so its `comm`
# is exactly the name we want, then exercise the helper against the
# child's PGID with various 2nd-arg values.
#
# Run: bash tests/unit/test-pgid-has-agent-process.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Required env (lib-dispatch.sh enforces these via : "${VAR:?...}")
export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID="test-pgid-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5

gh() { :; }
export -f gh

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

assert_returns() {
  local desc="$1" expected_rc="$2"; shift 2
  "$@"
  local actual_rc=$?
  if [[ "$expected_rc" == "$actual_rc" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected_rc=$expected_rc actual_rc=$actual_rc"
    FAIL=$((FAIL + 1))
  fi
}

# Spawn a controlled child whose `comm` is exactly $1, store its PID in
# the global SPAWN_PID. NOTE: do NOT use command substitution to capture
# the PID — bash's command-substitution subshell SIGHUPs its
# background children when it exits, killing our setsid child before
# the helper can probe it. Use a side-channel global instead.
#
# `comm` reads from /proc/<pid>/comm which is the binary's basename
# (NOT argv[0] — `exec -a` doesn't change comm). Portable trick: copy
# /bin/sleep to a renamed file under a tempdir, exec it. `setsid`
# makes the child its own session/process-group leader so its PGID
# equals its PID — same invariant lib-agent.sh::_run_with_timeout sets up.
TMPBINS=$(mktemp -d)
SPAWN_PID=""
spawn_named_child() {
  local name="$1"
  local bin="$TMPBINS/$name"
  cp /bin/sleep "$bin"
  setsid "$bin" 60 &
  SPAWN_PID=$!
  # Brief wait so /proc/<pid>/comm settles after exec.
  sleep 0.1
}

cleanup_pids=()
trap 'for p in "${cleanup_pids[@]}"; do kill -TERM "$p" 2>/dev/null; done; rm -rf "$TMPBINS"' EXIT

echo "=== test-pgid-has-agent-process.sh — per-side CLI argument ==="

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PSC-COUP-01a: helper accepts per-side CLI argument ==="
# ---------------------------------------------------------------------------

spawn_named_child "fake-agy"
agy_pid="$SPAWN_PID"
cleanup_pids+=("$agy_pid")

# Match: per-side CLI = "agy" → finds fake-agy via substring match.
assert_returns \
  "_pgid_has_agent_process <pgid> 'agy' matches fake-agy comm" \
  0 _pgid_has_agent_process "$agy_pid" "agy"

# No-match: per-side CLI = "claude" → fake-agy comm doesn't contain claude.
assert_returns \
  "_pgid_has_agent_process <pgid> 'claude' does not match fake-agy" \
  1 _pgid_has_agent_process "$agy_pid" "claude"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PSC-COUP-01b: empty 2nd arg falls back to AGENT_CMD ==="
# ---------------------------------------------------------------------------

# AGENT_CMD=agy + empty 2nd arg → fallback finds fake-agy.
export AGENT_CMD=agy
assert_returns \
  "_pgid_has_agent_process <pgid> '' falls back to AGENT_CMD=agy" \
  0 _pgid_has_agent_process "$agy_pid" ""

# AGENT_CMD=claude + empty 2nd arg → fallback misses (back-compat).
export AGENT_CMD=claude
assert_returns \
  "_pgid_has_agent_process <pgid> '' falls back to AGENT_CMD=claude (no match)" \
  1 _pgid_has_agent_process "$agy_pid" ""

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PSC-COUP-01c: 1-arg call (back-compat) reads AGENT_CMD ==="
# ---------------------------------------------------------------------------

# Back-compat: existing callers that pass only the PGID still work via
# the AGENT_CMD fallback.
export AGENT_CMD=agy
assert_returns \
  "_pgid_has_agent_process <pgid> (no 2nd arg) reads AGENT_CMD=agy" \
  0 _pgid_has_agent_process "$agy_pid"

export AGENT_CMD=claude
assert_returns \
  "_pgid_has_agent_process <pgid> (no 2nd arg) reads AGENT_CMD=claude" \
  1 _pgid_has_agent_process "$agy_pid"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-PSC-COUP-01d: bad PGID still rejected with per-side arg ==="
# ---------------------------------------------------------------------------

# Pre-existing safety: integer guard, positive guard. Should still hold
# regardless of 2nd-arg presence.
assert_returns \
  "_pgid_has_agent_process 'notanumber' 'agy' returns 1" \
  1 _pgid_has_agent_process "notanumber" "agy"

assert_returns \
  "_pgid_has_agent_process '0' 'agy' returns 1" \
  1 _pgid_has_agent_process "0" "agy"

assert_returns \
  "_pgid_has_agent_process '' 'agy' returns 1 (empty PGID)" \
  1 _pgid_has_agent_process "" "agy"

echo ""
echo "PASS: $PASS    FAIL: $FAIL"
[[ $FAIL -eq 0 ]]
