#!/bin/bash
# test-pid-guard-atomic.sh — Regression tests for issue #360 (302a).
#
# Pre-fix, acquire_pid_guard (lib-agent.sh) does a non-atomic check-then-write
# on the PID file: read existing PID -> kill -0 probe -> (if dead/absent)
# write $$. Two near-simultaneous wrappers for the same (issue, mode) can both
# pass the kill -0 probe before either writes, so both proceed to fan out —
# the duplicate-review incident observed on #298 / PR #300 (2026-06-29).
#
# This suite proves:
#   - the OLD check-then-write shape is racy under an injected delay (so the
#     regression test would have caught the pre-fix bug);
#   - the NEW atomic acquire has exactly ONE winner across N concurrent
#     callers on the same PID path;
#   - the loser exits 0 (not an error), logs one line, and never fans out;
#   - the winner's PID file is readable by the EXISTING pid_alive code path
#     (R1 hard constraint: read-side semantics unchanged) — same path, same
#     content (winner's PID).
#
# Run: bash tests/unit/test-pid-guard-atomic.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_match() {
  local desc="$1" pattern="$2" haystack="$3"
  if [[ -n "$(grep -E "$pattern" <<<"$haystack")" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected to match '$pattern')"
    FAIL=$((FAIL + 1))
  fi
}

LIB_AGENT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"
[[ -f "$LIB_AGENT" ]] || { echo -e "${RED}FATAL${NC}: $LIB_AGENT missing"; exit 1; }

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ============================================================================
# Regression shape: the OLD check-then-write is demonstrably racy.
# ============================================================================
# We replicate the exact pre-fix shape (read -> kill -0 probe -> sleep
# (injected delay simulating a "two near-simultaneous wrappers" gap) -> write)
# in a standalone function so this test is a pinned regression: if a future
# refactor to acquire_pid_guard ever regresses to something like this racy
# shape, this test proves the shape is racy and would have failed. It does
# NOT call acquire_pid_guard itself — it demonstrates the BUG the fix closes.
echo
echo "=== TC-ATOMIC-000: pre-fix check-then-write shape is racy under injected delay ==="
echo

_old_racy_guard() {
  local pid_file="$1" out_file="$2" delay="$3"
  local existing_pid
  existing_pid=$(cat "$pid_file" 2>/dev/null)
  if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
    echo "blocked" >> "$out_file"
    return 0
  fi
  # Injected delay: simulates two wrappers landing within the TOCTOU window
  # (e.g. both dispatched off the same duplicated-dispatch tick).
  sleep "$delay"
  echo "$$" > "$pid_file"
  echo "won:$$" >> "$out_file"
}

RACY_PID_FILE="$TMPDIR/racy.pid"
RACY_OUT="$TMPDIR/racy.out"
rm -f "$RACY_PID_FILE" "$RACY_OUT"
touch "$RACY_OUT"

# Two callers race: both see no PID file / dead PID, both sleep, both write.
_old_racy_guard "$RACY_PID_FILE" "$RACY_OUT" 0.2 &
RACY_PID1=$!
_old_racy_guard "$RACY_PID_FILE" "$RACY_OUT" 0.2 &
RACY_PID2=$!
wait "$RACY_PID1" "$RACY_PID2" 2>/dev/null

RACY_WINNERS=$(grep -c '^won:' "$RACY_OUT" || true)
assert_eq "pre-fix shape: BOTH racers 'win' (the bug this PR closes)" "2" "$RACY_WINNERS"

# ============================================================================
# Source the real lib-agent.sh so we exercise the ACTUAL fixed function.
# ============================================================================
mkdir -p "$TMPDIR/scripts"
cat > "$TMPDIR/scripts/autonomous.conf" <<EOF
PROJECT_ID=test
REPO=test/test
REPO_OWNER=test
REPO_NAME=test
PROJECT_DIR=$TMPDIR
GH_AUTH_MODE=token
EOF

mkdir -p "$TMPDIR/skills/autonomous-dispatcher/scripts"
cp "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-config.sh" \
   "$TMPDIR/skills/autonomous-dispatcher/scripts/lib-config.sh"
cp "$LIB_AGENT" "$TMPDIR/skills/autonomous-dispatcher/scripts/lib-agent.sh"
ln -sf "$TMPDIR/scripts/autonomous.conf" "$TMPDIR/skills/autonomous-dispatcher/scripts/autonomous.conf"

export AGENT_TIMEOUT=3s
# shellcheck source=/dev/null
source "$TMPDIR/skills/autonomous-dispatcher/scripts/lib-agent.sh" 2>"$TMPDIR/source.err"
SRC_RC=$?
if [[ "$SRC_RC" -ne 0 ]]; then
  echo -e "${RED}FATAL${NC}: failed to source lib-agent.sh (rc=$SRC_RC):"
  cat "$TMPDIR/source.err"
  exit 1
fi

# ============================================================================
# TC-ATOMIC-001: N concurrent acquire_pid_guard calls -> exactly ONE winner
# ============================================================================
echo
echo "=== TC-ATOMIC-001: N concurrent acquire_pid_guard calls, exactly one winner ==="
echo

N=10
CONC_PID_FILE="$TMPDIR/conc.pid"
CONC_RESULT_DIR="$TMPDIR/conc-results"
rm -rf "$CONC_RESULT_DIR"; mkdir -p "$CONC_RESULT_DIR"
rm -f "$CONC_PID_FILE"

# Fan N subshells, each in its own process, each calling the REAL
# acquire_pid_guard against the SAME pid_file. acquire_pid_guard calls `exit`
# (not `return`) on BOTH the winner and loser paths (see lib-agent.sh), so the
# subshell's own exit code — captured via `wait "$pid"` from the parent, not
# from inside the subshell — is the only reliable way to observe the loser's
# rc. A winner runs to completion (its "process" is this subshell itself,
# sleeping briefly to hold the slot open like a real wrapper would) then
# exits 0 too; we distinguish winner from loser via the "won" marker file
# written AFTER acquire_pid_guard returns (only reachable on the winner path).
declare -a CONC_BGPIDS=()
for i in $(seq 1 "$N"); do
  (
    exec 2>"$CONC_RESULT_DIR/stderr-$i"
    acquire_pid_guard "$CONC_PID_FILE" "test-atomic" "999$i"
    # Only reached on the winner path (loser's acquire_pid_guard exits the
    # subshell directly).
    echo "won" > "$CONC_RESULT_DIR/outcome-$i"
    sleep 0.3
    exit 0
  ) &
  CONC_BGPIDS+=("$!:$i")
done
for entry in "${CONC_BGPIDS[@]}"; do
  bg_pid="${entry%%:*}"; idx="${entry##*:}"
  wait "$bg_pid"
  echo "$?" > "$CONC_RESULT_DIR/rc-$idx"
done

WINNER_COUNT=$(grep -l '^won$' "$CONC_RESULT_DIR"/outcome-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "exactly ONE winner among $N concurrent acquires" "1" "$WINNER_COUNT"

LOSER_COUNT=0
for i in $(seq 1 "$N"); do
  if [[ ! -f "$CONC_RESULT_DIR/outcome-$i" ]]; then
    RC_VAL=$(cat "$CONC_RESULT_DIR/rc-$i" 2>/dev/null || echo "")
    assert_eq "loser #$i exits 0 (not an error)" "0" "$RC_VAL"
    LOSER_COUNT=$((LOSER_COUNT + 1))
  fi
done
assert_eq "loser count is N-1" "$((N - 1))" "$LOSER_COUNT"

# R2: loser logs exactly one line, posts nothing (no extra stderr chatter).
for i in $(seq 1 "$N"); do
  [[ -f "$CONC_RESULT_DIR/outcome-$i" ]] && continue
  LOSER_STDERR_LINES=$(wc -l < "$CONC_RESULT_DIR/stderr-$i" 2>/dev/null || echo 0)
  assert_eq "loser #$i logs exactly one line" "1" "$LOSER_STDERR_LINES"
done

# ============================================================================
# TC-ATOMIC-001b: the fixed function closes the EXACT window TC-ATOMIC-000
# proved racy — widen the liveness-check-to-write gap via the test-only hook
# and confirm still exactly one winner.
# ============================================================================
echo
echo "=== TC-ATOMIC-001b: fixed acquire_pid_guard stays single-winner even with the check-to-write window widened ==="
echo

WIDE_PID_FILE="$TMPDIR/wide.pid"
WIDE_RESULT_DIR="$TMPDIR/wide-results"
rm -rf "$WIDE_RESULT_DIR"; mkdir -p "$WIDE_RESULT_DIR"
rm -f "$WIDE_PID_FILE"

declare -a WIDE_BGPIDS=()
for i in 1 2 3; do
  (
    export _ACQUIRE_PID_GUARD_TEST_DELAY_SECONDS=0.2
    acquire_pid_guard "$WIDE_PID_FILE" "test-wide" "42"
    echo "won" > "$WIDE_RESULT_DIR/outcome-$i"
    exit 0
  ) &
  WIDE_BGPIDS+=("$!")
done
for bg_pid in "${WIDE_BGPIDS[@]}"; do wait "$bg_pid"; done

WIDE_WINNER_COUNT=$(grep -l '^won$' "$WIDE_RESULT_DIR"/outcome-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "exactly ONE winner even with the check-to-write window widened to 0.2s" "1" "$WIDE_WINNER_COUNT"

# ============================================================================
# TC-ATOMIC-001c: a stale lock dir (owner crashed mid-hold) is reclaimed, not
# a permanent wedge.
# ============================================================================
echo
echo "=== TC-ATOMIC-001c: a stale lock dir is reclaimed rather than blocking forever ==="
echo

STALE_PID_FILE="$TMPDIR/stale.pid"
STALE_LOCK_DIR="${STALE_PID_FILE}.lockdir"
rm -f "$STALE_PID_FILE"
mkdir "$STALE_LOCK_DIR"
# Backdate the lock dir's mtime to simulate an owner that crashed mid-hold
# well past the stale threshold.
touch -d "@$(($(date -u +%s) - 100))" "$STALE_LOCK_DIR"

( export ACQUIRE_PID_GUARD_LOCK_STALE_SECONDS=60
  timeout 5 bash -c 'source "'"$TMPDIR"'/skills/autonomous-dispatcher/scripts/lib-agent.sh" 2>/dev/null; acquire_pid_guard "'"$STALE_PID_FILE"'" test-stale 42' )
STALE_RC=$?
assert_eq "acquire against a stale lock succeeds (not stuck)" "0" "$STALE_RC"
if [[ -d "$STALE_LOCK_DIR" ]]; then
  echo -e "  ${RED}FAIL${NC}: stale lock dir was not cleaned up"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: stale lock dir was reclaimed and removed"
  PASS=$((PASS + 1))
fi
STALE_PID_CONTENT=$(cat "$STALE_PID_FILE" 2>/dev/null)
assert_match "reclaimed acquire still wrote a numeric PID" '^[0-9]+$' "$STALE_PID_CONTENT"

# ============================================================================
# TC-ATOMIC-002: PID-file read-side compatibility (pid_alive-style check)
# ============================================================================
echo
echo "=== TC-ATOMIC-002: winner's PID file is readable by the existing pid_alive check ==="
echo

[[ -f "$CONC_PID_FILE" ]]
assert_eq "PID file exists at the SAME path after acquire" "0" "$?"

WINNER_PID_CONTENT=$(cat "$CONC_PID_FILE" 2>/dev/null)
assert_match "PID file content is numeric (pid_alive's kill -0 contract)" '^[0-9]+$' "$WINNER_PID_CONTENT"

# Replicate pid_alive's tier-1 check verbatim (lib-dispatch.sh::pid_alive):
#   pid=$(cat "$pid_file"); [ -n "$pid" ] && kill -0 "$pid"
# The winner subshell has already exited by the time we get here (its sleep
# 0.3 completed and `wait` returned), so kill -0 legitimately fails — but the
# CONTRACT under test is "same path, same content shape (numeric PID)", which
# is what R1 requires unchanged. We assert the shape, not liveness (liveness
# depends on process lifetime, orthogonal to the atomicity fix).
PID_ALIVE_STYLE_PID=$(cat "$CONC_PID_FILE" 2>/dev/null)
if [[ -n "$PID_ALIVE_STYLE_PID" ]]; then
  echo -e "  ${GREEN}PASS${NC}: pid_alive-style read succeeds (non-empty numeric content)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: pid_alive-style read got empty content"
  FAIL=$((FAIL + 1))
fi

# ============================================================================
# TC-ATOMIC-003: dead-PID reuse still works (existing behavior preserved)
# ============================================================================
echo
echo "=== TC-ATOMIC-003: a dead PID in the file allows a fresh acquire to win ==="
echo

DEAD_PID_FILE="$TMPDIR/dead.pid"
echo "99999999" > "$DEAD_PID_FILE"  # very unlikely to be a real PID
# acquire_pid_guard calls `exit` internally — capture the SUBSHELL's own exit
# code from the outside (`$?` right after the `( ... )` group), not from a
# line inside the group (which `exit` would skip).
( acquire_pid_guard "$DEAD_PID_FILE" "test-dead" "12345" )
DEAD_RC=$?
assert_eq "acquire succeeds when existing PID is dead" "0" "$DEAD_RC"
DEAD_PID_CONTENT=$(cat "$DEAD_PID_FILE" 2>/dev/null)
if [[ "$DEAD_PID_CONTENT" != "99999999" && -n "$DEAD_PID_CONTENT" ]]; then
  echo -e "  ${GREEN}PASS${NC}: PID file rewritten with the new acquirer's PID"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: PID file not rewritten (still '$DEAD_PID_CONTENT')"
  FAIL=$((FAIL + 1))
fi

# ============================================================================
# TC-ATOMIC-004: symlink defence unchanged
# ============================================================================
echo
echo "=== TC-ATOMIC-004: symlink PID file is still rejected ==="
echo

SYMLINK_PID_FILE="$TMPDIR/symlink.pid"
ln -sf /etc/passwd "$SYMLINK_PID_FILE"
( acquire_pid_guard "$SYMLINK_PID_FILE" "test-symlink" "1" 2>/dev/null )
SYMLINK_RC=$?
assert_eq "symlink PID file rejected with exit 1" "1" "$SYMLINK_RC"
rm -f "$SYMLINK_PID_FILE"

# ============================================================================
# TC-ATOMIC-005: source-of-truth — no bare check-then-write left in the fn
# ============================================================================
echo
echo "=== TC-ATOMIC-005: source shows an atomic primitive (mkdir/flock/O_EXCL), not bare check-then-write ==="
echo

FN_BODY=$(awk '/^acquire_pid_guard\(\) \{$/,/^\}$/' "$LIB_AGENT")
if grep -qE '\bmkdir\b|\bflock\b|noclobber|set -C' <<<"$FN_BODY"; then
  echo -e "  ${GREEN}PASS${NC}: acquire_pid_guard uses an atomic acquire primitive"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: acquire_pid_guard does not appear to use mkdir/flock/O_EXCL"
  FAIL=$((FAIL + 1))
fi

# ============================================================================
# TC-ATOMIC-006: doc presence (R4 / AC3)
# ============================================================================
echo
echo "=== TC-ATOMIC-006: invariants.md + flow docs updated in the same PR ==="
echo

INVARIANTS_DOC="$PROJECT_ROOT/docs/pipeline/invariants.md"
DEV_FLOW_DOC="$PROJECT_ROOT/docs/pipeline/dev-agent-flow.md"
REVIEW_FLOW_DOC="$PROJECT_ROOT/docs/pipeline/review-agent-flow.md"

if grep -qE '^## INV-103:' "$INVARIANTS_DOC" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: invariants.md has an INV-103 entry"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: invariants.md missing an INV-103 entry"
  FAIL=$((FAIL + 1))
fi

if grep -q 'INV-103' "$DEV_FLOW_DOC" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: dev-agent-flow.md references INV-103"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: dev-agent-flow.md does not reference INV-103"
  FAIL=$((FAIL + 1))
fi

if grep -q 'INV-103' "$REVIEW_FLOW_DOC" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: review-agent-flow.md references INV-103"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: review-agent-flow.md does not reference INV-103"
  FAIL=$((FAIL + 1))
fi

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
