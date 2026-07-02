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
# TC-ATOMIC-001c: a crashed holder's lock is released automatically by the
# kernel (flock semantics) — no stale-lock heuristic, no reclaim code path,
# no permanent wedge.
# ============================================================================
echo
echo "=== TC-ATOMIC-001c: a killed holder's lock is released automatically (flock, not a staleness heuristic) ==="
echo

CRASH_PID_FILE="$TMPDIR/crash.pid"
CRASH_LOCK_FILE="${CRASH_PID_FILE}.lock"
rm -f "$CRASH_PID_FILE" "$CRASH_LOCK_FILE"

# Hold the lock in a background subshell, then SIGKILL it mid-hold — no
# graceful unlock, no cleanup trap. flock's kernel-level guarantee is that
# closing the fd (including via process death) releases the lock; there is
# no separate "is this lock stale" check to get wrong.
#
# `exec sleep 30` (replacing the subshell's OWN process image) rather than a
# plain `sleep 30` (which forks a CHILD that inherits the open fd) is
# load-bearing here: with a forked child, `kill -9` on the subshell's PID
# does not touch the child, which still holds the fd open and the flock —
# a test artifact that would make this test wrongly assert liveness the
# real crash path (a killed wrapper process, not a forked descendant of it)
# does not exhibit.
(
  exec {crash_fd}>"$CRASH_LOCK_FILE"
  flock "$crash_fd"
  exec sleep 30
) &
CRASH_HOLDER_PID=$!
sleep 0.3
kill -9 "$CRASH_HOLDER_PID" 2>/dev/null
wait "$CRASH_HOLDER_PID" 2>/dev/null

( timeout 5 bash -c 'source "'"$TMPDIR"'/skills/autonomous-dispatcher/scripts/lib-agent.sh" 2>/dev/null; acquire_pid_guard "'"$CRASH_PID_FILE"'" test-crash 42' )
CRASH_RC=$?
assert_eq "acquire after a killed holder succeeds immediately (not stuck)" "0" "$CRASH_RC"
CRASH_PID_CONTENT=$(cat "$CRASH_PID_FILE" 2>/dev/null)
assert_match "post-crash acquire still wrote a numeric PID" '^[0-9]+$' "$CRASH_PID_CONTENT"

# ============================================================================
# TC-ATOMIC-001d: high-concurrency stress (20 racers) — exactly one winner,
# every loser exits 0 within the wait budget. Regression coverage for the
# specific failure mode an earlier mkdir-lock-dir design had: a "reclaim a
# stale lock" code path that itself raced (two racers both reclaiming, the
# second deleting the first's freshly-acquired lock). flock has no such
# code path, so this is a pure concurrency stress test, not a staleness test.
# ============================================================================
echo
echo "=== TC-ATOMIC-001d: 20-way concurrent acquire stress — still exactly one winner ==="
echo

STRESS_PID_FILE="$TMPDIR/stress.pid"
STRESS_RESULT_DIR="$TMPDIR/stress-results"
rm -rf "$STRESS_RESULT_DIR"; mkdir -p "$STRESS_RESULT_DIR"
rm -f "$STRESS_PID_FILE" "${STRESS_PID_FILE}.lock"

STRESS_N=20
declare -a STRESS_BGPIDS=()
for i in $(seq 1 "$STRESS_N"); do
  (
    acquire_pid_guard "$STRESS_PID_FILE" "test-stress" "77$i"
    echo "won" > "$STRESS_RESULT_DIR/outcome-$i"
    sleep 0.2
    exit 0
  ) &
  STRESS_BGPIDS+=("$!")
done
for bg_pid in "${STRESS_BGPIDS[@]}"; do wait "$bg_pid"; done

STRESS_WINNER_COUNT=$(grep -l '^won$' "$STRESS_RESULT_DIR"/outcome-* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "exactly ONE winner among $STRESS_N concurrent acquires" "1" "$STRESS_WINNER_COUNT"

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
# TC-ATOMIC-004b: symlinked LOCK sidecar is rejected before the flock open
# (codex review finding on PR #365, CWE-59) — a same-user attacker can
# pre-plant `${pid_file}.lock` as a symlink to an arbitrary victim file; the
# `exec {fd}>"$lock_file"` open follows a symlink and truncates whatever it
# points at, BEFORE `flock` ever runs. Proves both the rejection (exit 1) AND
# that the victim file's content is left untouched.
# ============================================================================
echo
echo "=== TC-ATOMIC-004b: symlinked lock sidecar is rejected — victim file untouched ==="
echo

ATTACK_PID_FILE="$TMPDIR/attack.pid"
ATTACK_LOCK_FILE="${ATTACK_PID_FILE}.lock"
VICTIM_FILE="$TMPDIR/victim-file"
rm -f "$ATTACK_PID_FILE" "$ATTACK_LOCK_FILE" "$VICTIM_FILE"
echo "VICTIM-ORIGINAL-CONTENT" > "$VICTIM_FILE"
ln -sf "$VICTIM_FILE" "$ATTACK_LOCK_FILE"

( acquire_pid_guard "$ATTACK_PID_FILE" "test-symlink-lock" "99" 2>/dev/null )
ATTACK_RC=$?
assert_eq "symlinked lock sidecar rejected with exit 1" "1" "$ATTACK_RC"

VICTIM_CONTENT=$(cat "$VICTIM_FILE" 2>/dev/null)
assert_eq "victim file content is untouched (no truncation via the symlinked lock)" "VICTIM-ORIGINAL-CONTENT" "$VICTIM_CONTENT"

if [[ -L "$ATTACK_LOCK_FILE" ]]; then
  echo -e "  ${GREEN}PASS${NC}: attack symlink left in place (not silently removed/followed)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: attack symlink unexpectedly gone"
  FAIL=$((FAIL + 1))
fi
rm -f "$ATTACK_LOCK_FILE" "$VICTIM_FILE" "$ATTACK_PID_FILE"

# ============================================================================
# TC-ATOMIC-004c: HARD-linked LOCK sidecar's victim survives untouched
# (codex review finding on PR #365, round 2 — a `-L` symlink check alone is
# insufficient). A hard link shares the target's inode and `-L` never
# reports it as a symlink, so TC-ATOMIC-004b's defense does not catch this
# case; the load-bearing fix is opening the lock file in APPEND mode (no
# O_TRUNC) so the open itself can never zero a hard-linked (or symlinked)
# victim, regardless of whether any symlink check fires. Unlike the
# symlink case, `acquire_pid_guard` has no way to detect (and no reason to
# reject) a hard link — the victim's SURVIVAL, not an exit code, is the
# contract under test here.
# ============================================================================
echo
echo "=== TC-ATOMIC-004c: hard-linked lock sidecar — victim file untouched (no O_TRUNC on open) ==="
echo

HARDLINK_PID_FILE="$TMPDIR/hardlink-attack.pid"
HARDLINK_LOCK_FILE="${HARDLINK_PID_FILE}.lock"
HARDLINK_VICTIM_FILE="$TMPDIR/hardlink-victim-file"
rm -f "$HARDLINK_PID_FILE" "$HARDLINK_LOCK_FILE" "$HARDLINK_VICTIM_FILE"
echo "HARDLINK-VICTIM-ORIGINAL-CONTENT" > "$HARDLINK_VICTIM_FILE"
ln "$HARDLINK_VICTIM_FILE" "$HARDLINK_LOCK_FILE"

if [[ -L "$HARDLINK_LOCK_FILE" ]]; then
  echo -e "  ${RED}FAIL${NC}: setup error — hard link unexpectedly reported as a symlink by -L (test does not exercise the intended case)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: setup confirmed — hard link is NOT reported by -L (the exact gap a symlink-only check misses)"
  PASS=$((PASS + 1))
fi

( acquire_pid_guard "$HARDLINK_PID_FILE" "test-hardlink-lock" "100" 2>/dev/null )
HARDLINK_RC=$?
assert_eq "acquire against a hard-linked lock sidecar still succeeds (append-mode open, no rejection needed)" "0" "$HARDLINK_RC"

HARDLINK_VICTIM_CONTENT=$(cat "$HARDLINK_VICTIM_FILE" 2>/dev/null)
assert_eq "victim file content is untouched (no truncation via the hard-linked lock)" "HARDLINK-VICTIM-ORIGINAL-CONTENT" "$HARDLINK_VICTIM_CONTENT"
rm -f "$HARDLINK_PID_FILE" "$HARDLINK_LOCK_FILE" "$HARDLINK_VICTIM_FILE"

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

# Regression pin: no separate "is this lock stale, reclaim it" code path.
# An earlier mkdir-lock-dir draft had exactly this shape (age-check the lock
# dir, then rmdir it) and the reclaim itself raced — two callers could both
# decide a lock was stale and both rmdir, with the second deleting the
# FIRST caller's freshly-reacquired lock instead of the stale one. flock's
# kernel-level auto-release on fd-close (including process death) makes any
# such heuristic unnecessary; its presence here would be a regression.
if grep -qE '_lock_dir_age_seconds|stale.*lock|reclaim.*lock' <<<"$(tr '[:upper:]' '[:lower:]' <<<"$FN_BODY")"; then
  echo -e "  ${RED}FAIL${NC}: acquire_pid_guard still contains a stale-lock reclaim path (the raced design this PR replaced with flock)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: no separate stale-lock reclaim code path (flock's kernel auto-release makes one unnecessary)"
  PASS=$((PASS + 1))
fi

# Regression pin (codex review, PR #365 round 1, CWE-59): the lock-file
# symlink check MUST appear in source before the `exec {fd}>>` redirection
# that opens it, as belt-and-suspenders (round 2 below is the load-bearing
# fix — the symlink check alone cannot catch a hard link).
LOCK_SYMLINK_CHECK_LINE=$(grep -n '\[\[ -L "\$lock_file" \]\]' "$LIB_AGENT" | head -1 | cut -d: -f1)
LOCK_EXEC_LINE=$(grep -n 'exec {_lock_fd}>>"\$lock_file"' "$LIB_AGENT" | head -1 | cut -d: -f1)
if [[ -n "$LOCK_SYMLINK_CHECK_LINE" && -n "$LOCK_EXEC_LINE" && "$LOCK_SYMLINK_CHECK_LINE" -lt "$LOCK_EXEC_LINE" ]]; then
  echo -e "  ${GREEN}PASS${NC}: lock-file symlink check (line $LOCK_SYMLINK_CHECK_LINE) precedes the flock-open exec (line $LOCK_EXEC_LINE)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: lock-file symlink check missing or does not precede the flock-open exec (check_line='$LOCK_SYMLINK_CHECK_LINE' exec_line='$LOCK_EXEC_LINE')"
  FAIL=$((FAIL + 1))
fi

# Regression pin (codex review, PR #365 round 2): the flock-open MUST use
# APPEND mode (`>>`, no O_TRUNC), never plain truncating `>` — a hard link
# shares the target's inode and is invisible to the `-L` check above, so
# the ONLY thing that closes the hard-link vector is never truncating on
# open in the first place. Explicitly assert the truncating form is ABSENT.
if grep -qE 'exec \{_lock_fd\}>"\$lock_file"' <<<"$FN_BODY"; then
  echo -e "  ${RED}FAIL${NC}: acquire_pid_guard opens the lock file with TRUNCATING redirection ('>' not '>>') — reopens the hard-link attack vector"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: acquire_pid_guard does not open the lock file with truncating redirection"
  PASS=$((PASS + 1))
fi
if grep -qE 'exec \{_lock_fd\}>>"\$lock_file"' <<<"$FN_BODY"; then
  echo -e "  ${GREEN}PASS${NC}: acquire_pid_guard opens the lock file in append mode (no O_TRUNC — closes symlink AND hard-link truncation)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: acquire_pid_guard does not open the lock file in append mode"
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
