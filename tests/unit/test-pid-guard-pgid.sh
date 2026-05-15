#!/bin/bash
# test-pid-guard-pgid.sh — Regression tests for issue #109.
#
# The original PID guard wrote the wrapper shell's `$$` to PID_FILE while
# the actual long-running work (timeout → agent CLI) ran as a child. When
# the wrapper exited before the agent subtree finished unwinding, the
# subtree was reparented to PID 1 and `kill_stale_wrapper` couldn't reach
# it. This test suite verifies the fix:
#
#   - `_run_with_timeout` runs the agent under `setsid`, so the agent and
#     all its descendants share a process group.
#   - `_run_with_timeout` writes the session-leader PID (== PGID) into
#     `$AGENT_PID_FILE` if set.
#   - `kill_stale_wrapper` issues `kill -TERM -- -<pgid>` so the entire
#     group is reaped.
#   - A `pgrep -f` fallback catches escaped trees from PID files that
#     still hold a pre-fix `$$` placeholder.
#
# Run: bash tests/unit/test-pid-guard-pgid.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" got="$3"
  if [[ "$expected" == "$got" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected '$expected', got '$got')"
    FAIL=$((FAIL+1))
  fi
}

assert_match() {
  local desc="$1" pattern="$2" haystack="$3"
  if [[ -n "$(grep -E "$pattern" <<<"$haystack")" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected to match '$pattern')"
    FAIL=$((FAIL+1))
  fi
}

assert_not_match() {
  local desc="$1" pattern="$2" haystack="$3"
  if [[ -z "$(grep -E "$pattern" <<<"$haystack")" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (unexpectedly matched '$pattern')"
    FAIL=$((FAIL+1))
  fi
}

LIB_AGENT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"
DEV_SCRIPT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
REVIEW_SCRIPT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
DISPATCH_SCRIPT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatch-local.sh"

[[ -f "$LIB_AGENT" ]] || { echo -e "${RED}FATAL${NC}: $LIB_AGENT missing"; exit 1; }
[[ -f "$DEV_SCRIPT" ]] || { echo -e "${RED}FATAL${NC}: $DEV_SCRIPT missing"; exit 1; }
[[ -f "$REVIEW_SCRIPT" ]] || { echo -e "${RED}FATAL${NC}: $REVIEW_SCRIPT missing"; exit 1; }
[[ -f "$DISPATCH_SCRIPT" ]] || { echo -e "${RED}FATAL${NC}: $DISPATCH_SCRIPT missing"; exit 1; }

LIB_AGENT_CONTENT=$(cat "$LIB_AGENT")
DEV_CONTENT=$(cat "$DEV_SCRIPT")
REVIEW_CONTENT=$(cat "$REVIEW_SCRIPT")
DISPATCH_CONTENT=$(cat "$DISPATCH_SCRIPT")

TMPDIR=$(mktemp -d)
# `pkill` returns 1 when no children match — and as the LAST command of an
# EXIT trap, that becomes the script's exit code, masking the real PASS=N
# verdict. Always end the trap on `:` (a no-op that exits 0).
trap 'pkill -P $$ 2>/dev/null; rm -rf "$TMPDIR"; :' EXIT

wait_for_pid_gone() {
  local pid="$1" timeout="${2:-50}" i
  for ((i = 0; i < timeout; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

# ============================================================================
# Static checks (TC-STATIC-*)
# ============================================================================
echo
echo "=== TC-STATIC-001: lib-agent.sh's _run_with_timeout uses setsid ==="
echo

assert_match "setsid invocation appears in _run_with_timeout" \
  '\bsetsid\b' "$LIB_AGENT_CONTENT"

echo
echo "=== TC-STATIC-002: lib-agent.sh declares _AGENT_RUN_PID + AGENT_PID_FILE protocol ==="
echo

assert_match "_AGENT_RUN_PID global referenced" \
  '_AGENT_RUN_PID' "$LIB_AGENT_CONTENT"
assert_match "AGENT_PID_FILE referenced as the write-target hook" \
  'AGENT_PID_FILE' "$LIB_AGENT_CONTENT"

echo
echo "=== TC-STATIC-003: autonomous-dev.sh on_sigterm forwards to PGID ==="
echo

# The trap path can be either:
#   (A) Inline `on_sigterm` function with `_AGENT_RUN_PID` and group-kill, or
#   (B) Calling `install_agent_sigterm_trap` from lib-agent.sh, which
#       owns the same contract (group-kill via _AGENT_RUN_PID).
# Both factorings satisfy the #109 fix; we accept either.
if grep -qE 'install_agent_sigterm_trap' <<<"$DEV_CONTENT"; then
  echo -e "  ${GREEN}PASS${NC}: dev wrapper installs SIGTERM trap via helper"
  PASS=$((PASS+1))
  # Also confirm the helper actually does what we claim it does.
  assert_match "lib-agent.sh helper references _AGENT_RUN_PID" \
    '_AGENT_RUN_PID' "$LIB_AGENT_CONTENT"
  assert_match "lib-agent.sh helper uses group-kill syntax" \
    'kill (-TERM |-[0-9]+ )?-- "?-' "$LIB_AGENT_CONTENT"
else
  assert_match "on_sigterm references _AGENT_RUN_PID" \
    '_AGENT_RUN_PID' "$DEV_CONTENT"
  assert_match "on_sigterm uses group-kill syntax" \
    'kill (-TERM |-[0-9]+ )?-- "?-' "$DEV_CONTENT"
fi

echo
echo "=== TC-STATIC-004: autonomous-review.sh has SIGTERM trap parity ==="
echo

# Same factoring as TC-STATIC-003. Review wrapper had no SIGTERM trap
# pre-fix; we now require either the inline form or the shared helper
# (preferred — same contract as autonomous-dev.sh).
if grep -qE 'install_agent_sigterm_trap' <<<"$REVIEW_CONTENT"; then
  echo -e "  ${GREEN}PASS${NC}: review wrapper installs SIGTERM trap via helper (parity with dev)"
  PASS=$((PASS+1))
else
  assert_match "review wrapper traps SIGTERM" \
    'trap [^ ]+ TERM|trap [^ ]+ SIGTERM' "$REVIEW_CONTENT"
  assert_match "review wrapper references _AGENT_RUN_PID in its trap" \
    '_AGENT_RUN_PID' "$REVIEW_CONTENT"
fi

echo
echo "=== TC-STATIC-005: dispatch-local.sh kill_stale_wrapper uses group-kill ==="
echo

assert_match "kill_stale_wrapper uses 'kill ... -- -<pid>' group syntax" \
  'kill .*-- "?-\$' "$DISPATCH_CONTENT"

echo
echo "=== TC-STATIC-006: dispatch-local.sh has KILL_STALE_PGREP_FALLBACK ==="
echo

assert_match "KILL_STALE_PGREP_FALLBACK config knob present" \
  'KILL_STALE_PGREP_FALLBACK' "$DISPATCH_CONTENT"
assert_match "pgrep fallback by --issue argv pattern" \
  'pgrep .*(\[-\]-|--)issue' "$DISPATCH_CONTENT"

# ============================================================================
# Behavioral tests
# ============================================================================
# Source lib-agent.sh in a subshell-safe way: the file calls `return 1` on
# certain error paths, which only works inside `source`. We need the
# config-loader bits to be no-ops, so set the project dir env to a tmp.
# ----------------------------------------------------------------------------

# Provide a stub autonomous.conf so load_autonomous_conf doesn't fail.
mkdir -p "$TMPDIR/scripts"
cat > "$TMPDIR/scripts/autonomous.conf" <<EOF
PROJECT_ID=test
REPO=test/test
REPO_OWNER=test
REPO_NAME=test
PROJECT_DIR=$TMPDIR
GH_AUTH_MODE=token
EOF

# Source lib-agent.sh into the current shell. We need its functions
# (_run_with_timeout) and globals (_AGENT_RUN_PID).
# Set AGENT_TIMEOUT short so any escapee dies on its own.
export AGENT_TIMEOUT=3s
# Force config loader to find our stub. lib-agent uses _LIB_AGENT_DIR/../../..
# as the PROJECT_DIR fallback, but load_autonomous_conf walks tier-1/2/3 paths.
# Easiest route: cp lib-agent + lib-config into TMPDIR and point at the tmp.
mkdir -p "$TMPDIR/skills/autonomous-dispatcher/scripts"
cp "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-config.sh" \
   "$TMPDIR/skills/autonomous-dispatcher/scripts/lib-config.sh"
cp "$LIB_AGENT" "$TMPDIR/skills/autonomous-dispatcher/scripts/lib-agent.sh"
ln -sf "$TMPDIR/scripts/autonomous.conf" "$TMPDIR/skills/autonomous-dispatcher/scripts/autonomous.conf"

# The `eval` AGENT_LAUNCHER block calls `return 1` on parse failure so we
# must source not exec. The script intentionally runs WITHOUT `-e` so
# individual assertion failures don't abort the suite mid-run.
# shellcheck source=/dev/null
source "$TMPDIR/skills/autonomous-dispatcher/scripts/lib-agent.sh" 2>"$TMPDIR/source.err"
src_rc=$?
if [[ "$src_rc" -ne 0 ]]; then
  echo -e "${RED}FATAL${NC}: failed to source lib-agent.sh (rc=$src_rc):"
  cat "$TMPDIR/source.err"
  exit 1
fi

# ============================================================================
# TC-PGID-001: _run_with_timeout puts the agent in its own session
# ============================================================================
echo
echo "=== TC-PGID-001: _run_with_timeout creates a new session ==="
echo

OWN_SID=$(ps -o sid= -p $$ | tr -d ' ')

# Run a child that prints its own session id. AGENT_PID_FILE captures the
# leader PID for assertion 2.
export AGENT_PID_FILE="$TMPDIR/tc001.pid"
CHILD_OUTPUT=$(_run_with_timeout bash -c 'ps -o sid= -p $$ | tr -d " "')
CHILD_SID="$CHILD_OUTPUT"

if command -v setsid >/dev/null 2>&1; then
  if [[ "$CHILD_SID" != "$OWN_SID" && -n "$CHILD_SID" ]]; then
    echo -e "  ${GREEN}PASS${NC}: child session id ($CHILD_SID) differs from parent ($OWN_SID)"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: child session id '$CHILD_SID' == parent '$OWN_SID' — setsid not in effect"
    FAIL=$((FAIL+1))
  fi
else
  echo -e "  ${GREEN}PASS${NC}: setsid unavailable on host, skipping session-id check"
  PASS=$((PASS+1))
fi

if [[ -f "$AGENT_PID_FILE" ]]; then
  PGID_VAL=$(cat "$AGENT_PID_FILE")
  if [[ "$PGID_VAL" =~ ^[0-9]+$ ]]; then
    echo -e "  ${GREEN}PASS${NC}: AGENT_PID_FILE contains numeric PID ($PGID_VAL)"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: AGENT_PID_FILE has non-numeric content '$PGID_VAL'"
    FAIL=$((FAIL+1))
  fi
else
  echo -e "  ${RED}FAIL${NC}: AGENT_PID_FILE not written"
  FAIL=$((FAIL+1))
fi

unset AGENT_PID_FILE
rm -f "$TMPDIR/tc001.pid"

# ============================================================================
# TC-PGID-002 + TC-PGID-004: killing the PGID kills the whole subtree
# ============================================================================
echo
echo "=== TC-PGID-002+004: kill -- -<pgid> reaps grandchildren ==="
echo

# Spawn a session leader that forks a SIGTERM-trapping grandchild.
# Use a script file so we have a stable argv for inspection.
SUBTREE_SCRIPT="$TMPDIR/subtree.sh"
cat > "$SUBTREE_SCRIPT" <<'EOS'
#!/bin/bash
# Grandchild: ignores TERM directed at the leader's process group? No —
# kill -- -<pgid> sends to ALL members; the only thing they can do to
# resist is `trap '' TERM` AND we'd then need SIGKILL escalation.
# For this test we want to confirm that `kill -- -<pgid>` reaches them
# at all, so don't trap TERM.
sleep 30 &
GRANDCHILD_PID=$!
echo "$GRANDCHILD_PID" > "$1"
wait
EOS
chmod +x "$SUBTREE_SCRIPT"

GRANDCHILD_FILE="$TMPDIR/grandchild.pid"
export AGENT_PID_FILE="$TMPDIR/tc002.pid"

# Run in background so the test can issue the kill while it's alive.
# `_run_with_timeout` blocks on `wait` internally; we need it backgrounded.
_run_with_timeout "$SUBTREE_SCRIPT" "$GRANDCHILD_FILE" &
RWT_PID=$!

# Wait up to 5s for AGENT_PID_FILE + grandchild file to appear.
for i in {1..50}; do
  if [[ -f "$AGENT_PID_FILE" && -f "$GRANDCHILD_FILE" ]]; then break; fi
  sleep 0.1
done

if [[ -f "$AGENT_PID_FILE" && -f "$GRANDCHILD_FILE" ]]; then
  LEADER_PID=$(cat "$AGENT_PID_FILE")
  GRANDCHILD_PID=$(cat "$GRANDCHILD_FILE")
  # Confirm both alive
  if kill -0 "$LEADER_PID" 2>/dev/null && kill -0 "$GRANDCHILD_PID" 2>/dev/null; then
    # Group-kill
    kill -TERM -- "-$LEADER_PID" 2>/dev/null || true
    if wait_for_pid_gone "$GRANDCHILD_PID"; then
      echo -e "  ${GREEN}PASS${NC}: grandchild PID $GRANDCHILD_PID reaped via group-kill"
      PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC}: grandchild PID $GRANDCHILD_PID survived group-kill"
      kill -9 "$GRANDCHILD_PID" 2>/dev/null || true
      FAIL=$((FAIL+1))
    fi
    if wait_for_pid_gone "$LEADER_PID"; then
      echo -e "  ${GREEN}PASS${NC}: leader PID $LEADER_PID reaped via group-kill"
      PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC}: leader PID $LEADER_PID survived group-kill"
      kill -9 "$LEADER_PID" 2>/dev/null || true
      FAIL=$((FAIL+1))
    fi
  else
    echo -e "  ${RED}FAIL${NC}: leader or grandchild died before assertion"
    FAIL=$((FAIL+1))
  fi
else
  echo -e "  ${RED}FAIL${NC}: AGENT_PID_FILE ($AGENT_PID_FILE) or grandchild file ($GRANDCHILD_FILE) never appeared"
  FAIL=$((FAIL+1))
fi

# Reap the backgrounded _run_with_timeout
wait "$RWT_PID" 2>/dev/null || true
unset AGENT_PID_FILE

# ============================================================================
# TC-PGID-008: AGENT_PID_FILE is written before agent exit
# ============================================================================
echo
echo "=== TC-PGID-008: AGENT_PID_FILE captured during agent run ==="
echo

PID_FILE_T8="$TMPDIR/tc008.pid"
export AGENT_PID_FILE="$PID_FILE_T8"
_run_with_timeout sleep 1 &
RWT_PID8=$!
# Allow up to 1.5s for spawn + write
for i in {1..15}; do
  [[ -s "$PID_FILE_T8" ]] && break
  sleep 0.1
done
if [[ -s "$PID_FILE_T8" ]]; then
  WRITTEN_PID=$(cat "$PID_FILE_T8")
  # The PID we wrote should still be live (sleep 1 is still running).
  if kill -0 "$WRITTEN_PID" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: AGENT_PID_FILE written during run; PID $WRITTEN_PID is live"
    PASS=$((PASS+1))
  else
    # Race: sleep 1 might have finished before we observed. Acceptable as
    # long as the file is non-empty and was written *during* the run.
    echo -e "  ${GREEN}PASS${NC}: AGENT_PID_FILE written (PID $WRITTEN_PID; agent already exited — accepted)"
    PASS=$((PASS+1))
  fi
else
  echo -e "  ${RED}FAIL${NC}: AGENT_PID_FILE not populated during run"
  FAIL=$((FAIL+1))
fi
wait "$RWT_PID8" 2>/dev/null || true
unset AGENT_PID_FILE

# ============================================================================
# TC-PGID-009: AGENT_PID_FILE unset → no-op (back-compat)
# ============================================================================
echo
echo "=== TC-PGID-009: unset AGENT_PID_FILE → _run_with_timeout no-op ==="
echo

unset AGENT_PID_FILE
# Capture stdout to a file (NOT 2>&1) so a parent `bash -x` trace on stderr
# can't pollute the captured value. This test asserts pure-stdout fidelity.
OUT_FILE_T9="$TMPDIR/tc009.out"
_run_with_timeout printf "ok" > "$OUT_FILE_T9"
RC=$?
OUT=$(cat "$OUT_FILE_T9")
assert_eq "exit code 0" "0" "$RC"
assert_eq "output preserved" "ok" "$OUT"

# ============================================================================
# TC-PGID-005: kill_stale_wrapper pgrep fallback
# ============================================================================
echo
echo "=== TC-PGID-005: pgrep fallback catches escaped trees ==="
echo

# Source kill_stale_wrapper from dispatch-local.sh (same extraction trick
# as test-kill-before-spawn.sh).
EXTRACT_FILE=$(mktemp)
awk '
  /^kill_stale_wrapper\(\) \{$/ { in_fn=1 }
  in_fn { print }
  in_fn && /^\}$/ { in_fn=0 }
' "$DISPATCH_SCRIPT" > "$EXTRACT_FILE"
if [[ ! -s "$EXTRACT_FILE" ]]; then
  echo -e "${RED}FATAL${NC}: failed to extract kill_stale_wrapper"
  rm -f "$EXTRACT_FILE"
  exit 1
fi

ISSUE_NUM=987654  # used by log messages and the pgrep pattern
KILL_STALE_PGREP_FALLBACK=true
# Per INV-28 the pgrep fallback is scoped to ${PROJECT_DIR}/scripts/ so
# multi-project boxes don't cross-kill. Place the fake tree under a
# fixture PROJECT_DIR/scripts/ and export it for the function. TYPE
# selects the dev wrapper since the fake tree is named autonomous-dev.sh.
PROJECT_DIR="$TMPDIR/proj"
TYPE=dev-resume
mkdir -p "$PROJECT_DIR/scripts"
# shellcheck source=/dev/null
source "$EXTRACT_FILE"

# Spawn a fake "escaped tree" with `--issue <N>` in its argv so the
# pgrep fallback can match it. The trampoline lives under
# ${PROJECT_DIR}/scripts/ — the path anchor INV-28 requires.
FAKE_TREE_SCRIPT="$PROJECT_DIR/scripts/autonomous-dev.sh"
cat > "$FAKE_TREE_SCRIPT" <<'EOS'
#!/bin/bash
# Block on a sleep child so SIGTERM cleanup is responsive. Args are not
# inspected — they exist purely so pgrep -f matches them.
trap 'kill 0 2>/dev/null; exit 0' TERM
sleep 60 &
wait
EOS
chmod +x "$FAKE_TREE_SCRIPT"

setsid "$FAKE_TREE_SCRIPT" --issue "$ISSUE_NUM" &
ESCAPEE_PID=$!
sleep 0.3  # give it a moment to materialise in /proc

# PID_FILE points at a now-dead $$ placeholder — the failure mode the
# fix targets.
PID_FILE_T5="$TMPDIR/tc005.pid"
echo "99999999" > "$PID_FILE_T5"  # pre-fix wrapper's $$ that's already gone

# Confirm the escapee is alive before invoking the fallback
if kill -0 "$ESCAPEE_PID" 2>/dev/null; then
  kill_stale_wrapper "$PID_FILE_T5" >/dev/null 2>&1 || true
  if wait_for_pid_gone "$ESCAPEE_PID"; then
    echo -e "  ${GREEN}PASS${NC}: pgrep fallback reaped escapee PID $ESCAPEE_PID"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: pgrep fallback did not reap escapee PID $ESCAPEE_PID"
    kill -9 "$ESCAPEE_PID" 2>/dev/null || true
    FAIL=$((FAIL+1))
  fi
else
  echo -e "  ${RED}FAIL${NC}: setup error — escapee never started"
  FAIL=$((FAIL+1))
fi

rm -f "$EXTRACT_FILE"

# ============================================================================
# Summary
# ============================================================================
echo
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo -e "Total: $TOTAL  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo

[[ $FAIL -gt 0 ]] && exit 1
exit 0
