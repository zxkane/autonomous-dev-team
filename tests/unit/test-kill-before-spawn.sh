#!/bin/bash
# test-kill-before-spawn.sh — Regression tests for issue #55.
#
# Verifies that dispatch-local.sh kills any stale wrapper for an issue
# before spawning a new one (SIGTERM, 5s grace, SIGKILL escalation).
#
# Run: bash tests/unit/test-kill-before-spawn.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Avoid `grep -q` here — combined with `set -o pipefail` and a large haystack
# it can produce SIGPIPE flakes (rc=141). Use full grep + non-empty check.
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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected to contain '$needle')"
    FAIL=$((FAIL+1))
  fi
}

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

DISPATCH_SCRIPT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatch-local.sh"
[[ -f "$DISPATCH_SCRIPT" ]] || { echo -e "${RED}FATAL${NC}: $DISPATCH_SCRIPT not found"; exit 1; }
DISPATCH_CONTENT=$(cat "$DISPATCH_SCRIPT")

# ============================================================================
# TC-DKBS-001: Static — kill-before-spawn block is present
# ============================================================================
echo
echo "=== TC-DKBS-001: kill-before-spawn block is present ==="
echo

# Patterns accept either uppercase ($PID_FILE / $OLD_PID — inline form) or
# lowercase ($pid_file / $old_pid — function-local form).
assert_match "Reads existing PID via cat"               'cat "?\$\{?(PID_FILE|pid_file)'      "$DISPATCH_CONTENT"
assert_match "Liveness check via kill -0"               'kill -0 "?\$\{?(OLD_PID|old_pid)'    "$DISPATCH_CONTENT"
assert_match "SIGTERM (plain kill)"                     'kill "?\$\{?(OLD_PID|old_pid)'       "$DISPATCH_CONTENT"
assert_match "5-second grace loop"                      'for [_a-z]+ in 1 2 3 4 5'            "$DISPATCH_CONTENT"
assert_match "SIGKILL escalation"                       'kill -9 "?\$\{?(OLD_PID|old_pid)'    "$DISPATCH_CONTENT"
assert_match "PID file removed after kill"              'rm -f "?\$\{?(PID_FILE|pid_file)'    "$DISPATCH_CONTENT"

# ============================================================================
# TC-DKBS-007: Both spawn paths guarded
# ============================================================================
echo
echo "=== TC-DKBS-007: All nohup invocations are preceded by kill-before-spawn ==="
echo

# Two acceptable factorings:
# (A) Inline check per nohup: `kill -0` block appears ≥ 3 times (one per type).
# (B) Factored function: a kill_stale_wrapper-style function exists and is
#     called BEFORE the first nohup. The PID_FILE used at the call site is
#     derived from $TYPE so all three spawn types are covered by the single
#     call. This is the cleaner factoring.
NOHUP_LINE=$(grep -nE '^\s*nohup ' <<<"$DISPATCH_CONTENT" | head -1 | cut -d: -f1)
KILL_FN_DEF_LINE=$(grep -nE '^kill_stale_wrapper *\(\)' <<<"$DISPATCH_CONTENT" | head -1 | cut -d: -f1)
KILL_FN_CALL_LINE=$(grep -nE 'kill_stale_wrapper "\$' <<<"$DISPATCH_CONTENT" | head -1 | cut -d: -f1)
INLINE_KILL0_COUNT=$(grep -c 'kill -0 "\?\$\{\?\(OLD_PID\|old_pid\)' <<<"$DISPATCH_CONTENT" || true)

if [[ -n "$KILL_FN_DEF_LINE" && -n "$KILL_FN_CALL_LINE" && -n "$NOHUP_LINE" ]] \
     && [[ "$KILL_FN_DEF_LINE" -lt "$NOHUP_LINE" ]] \
     && [[ "$KILL_FN_CALL_LINE" -lt "$NOHUP_LINE" ]]; then
  echo -e "  ${GREEN}PASS${NC}: kill_stale_wrapper defined (line $KILL_FN_DEF_LINE) and called (line $KILL_FN_CALL_LINE) before first nohup (line $NOHUP_LINE)"
  PASS=$((PASS+1))
elif [[ "$INLINE_KILL0_COUNT" -ge 3 ]]; then
  echo -e "  ${GREEN}PASS${NC}: inline kill -0 checks ($INLINE_KILL0_COUNT) cover each spawn path"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: no kill_stale_wrapper call before nohup (def=$KILL_FN_DEF_LINE call=$KILL_FN_CALL_LINE nohup=$NOHUP_LINE), and inline kill -0 count is $INLINE_KILL0_COUNT (need ≥3)"
  FAIL=$((FAIL+1))
fi

# Also assert there's a way to derive PID_FILE per type — the call site must
# match on $TYPE and select the right PID file path.
assert_match "PID_FILE selected per type" \
  'dev-new\|dev-resume\)\s*PID_FILE=|case "?\$TYPE"? in.*PID_FILE' "$DISPATCH_CONTENT"

# Each branch must pick the correct path: dev paths use -issue-, review uses
# -review-. Guard against a swap-typo regression where dev-new accidentally
# points at the review PID file or vice-versa.
DEV_PATH_BLOCK=$(grep -E 'dev-new\|dev-resume\)\s*PID_FILE=' <<<"$DISPATCH_CONTENT")
REVIEW_PATH_BLOCK=$(grep -E 'review\)\s*PID_FILE=' <<<"$DISPATCH_CONTENT")
if [[ "$DEV_PATH_BLOCK" == *"-issue-"* ]] && [[ "$DEV_PATH_BLOCK" != *"-review-"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: dev-new/dev-resume picks the -issue- PID file"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: dev branch path is wrong: '$DEV_PATH_BLOCK'"
  FAIL=$((FAIL+1))
fi
if [[ "$REVIEW_PATH_BLOCK" == *"-review-"* ]] && [[ "$REVIEW_PATH_BLOCK" != *"-issue-"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: review picks the -review- PID file"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: review branch path is wrong: '$REVIEW_PATH_BLOCK'"
  FAIL=$((FAIL+1))
fi

# ============================================================================
# TC-DKBS-008: Log message emitted on kill
# ============================================================================
echo
echo "=== TC-DKBS-008: Log message on kill ==="
echo

assert_match "Stderr log on found wrapper" \
  'Found existing wrapper|sending SIGTERM|killing stale' "$DISPATCH_CONTENT"

# ============================================================================
# Behavioral tests — extract the kill function (or inline replica) and run it
# against synthetic processes.
# ============================================================================

# Source the actual implementation so behavioral tests verify the real
# function — no replica drift. Strategy: extract the function definition from
# dispatch-local.sh into a temp file and source it. ISSUE_NUM is required by
# the function's log messages, so set a placeholder.
EXTRACT_FILE=$(mktemp)
awk '
  /^kill_stale_wrapper\(\) \{$/ { in_fn=1 }
  in_fn { print }
  in_fn && /^\}$/ { in_fn=0 }
' "$DISPATCH_SCRIPT" > "$EXTRACT_FILE"
if [[ ! -s "$EXTRACT_FILE" ]]; then
  echo -e "${RED}FATAL${NC}: failed to extract kill_stale_wrapper from $DISPATCH_SCRIPT"
  rm -f "$EXTRACT_FILE"
  exit 1
fi
ISSUE_NUM="test"  # for log messages inside the function
# shellcheck source=/dev/null
source "$EXTRACT_FILE"
rm -f "$EXTRACT_FILE"

# Bounded reap-poll: kill returns before the OS reaps. Wait up to ~2s,
# breaking as soon as the PID is gone. Avoids fixed-sleep flakes on slow CI.
wait_for_pid_gone() {
  local pid="$1" timeout="${2:-20}" i
  for ((i = 0; i < timeout; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"; rm -f "$EXTRACT_FILE"' EXIT

# ============================================================================
# TC-DKBS-002: Alive PID gets killed
# ============================================================================
echo
echo "=== TC-DKBS-002: alive PID is SIGTERM'd ==="
echo

PID_FILE="$TMPDIR/test-002.pid"
sleep 60 &
ALIVE_PID=$!
echo "$ALIVE_PID" > "$PID_FILE"

# Confirm the process is alive before killing
if kill -0 "$ALIVE_PID" 2>/dev/null; then
  # Note: this script runs with `set -uo pipefail` (no errexit), so
  # `kill_stale_wrapper` returning non-zero won't abort the test — that's
  # exactly the assertion path we want to exercise.
  kill_stale_wrapper "$PID_FILE" >/dev/null 2>&1
  RC=$?
  # Assert function-level success FIRST. If the function reports an error,
  # don't let an incidental external-cause death of the sleep process mask it.
  # (Q PR #57: race-condition risk where wait_for_pid_gone could pass while
  # kill_stale_wrapper actually returned non-zero.)
  assert_eq "Function returned 0" "0" "$RC"
  if [[ "$RC" == "0" ]]; then
    if wait_for_pid_gone "$ALIVE_PID"; then
      echo -e "  ${GREEN}PASS${NC}: alive PID $ALIVE_PID was killed"
      PASS=$((PASS+1))
    else
      echo -e "  ${RED}FAIL${NC}: alive sleep PID $ALIVE_PID still running after kill_stale"
      kill -9 "$ALIVE_PID" 2>/dev/null || true
      FAIL=$((FAIL+1))
    fi
    if [[ -e "$PID_FILE" ]]; then
      echo -e "  ${RED}FAIL${NC}: PID file still exists"
      FAIL=$((FAIL+1))
    else
      echo -e "  ${GREEN}PASS${NC}: PID file removed"
      PASS=$((PASS+1))
    fi
  else
    # Skip downstream assertions; cleanup the leaked sleep before continuing.
    kill -9 "$ALIVE_PID" 2>/dev/null || true
    rm -f "$PID_FILE"
  fi
else
  echo -e "  ${RED}FAIL${NC}: setup error — sleep didn't start"
  FAIL=$((FAIL+1))
fi

# ============================================================================
# TC-DKBS-003: Dead PID is handled cleanly
# ============================================================================
echo
echo "=== TC-DKBS-003: dead PID handled cleanly ==="
echo

PID_FILE="$TMPDIR/test-003.pid"
echo "99999999" > "$PID_FILE"  # very unlikely to exist
START_TIME=$SECONDS
kill_stale_wrapper "$PID_FILE"
RC=$?
ELAPSED=$(( SECONDS - START_TIME ))
assert_eq "Function returned 0 for dead PID" "0" "$RC"
if [[ "$ELAPSED" -le 1 ]]; then
  echo -e "  ${GREEN}PASS${NC}: dead-PID path completed quickly (${ELAPSED}s, no needless sleep)"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: dead-PID path took ${ELAPSED}s — should be <=1s"
  FAIL=$((FAIL+1))
fi
if [[ -e "$PID_FILE" ]]; then
  echo -e "  ${RED}FAIL${NC}: PID file still exists after dead-PID handling"
  FAIL=$((FAIL+1))
else
  echo -e "  ${GREEN}PASS${NC}: PID file removed"
  PASS=$((PASS+1))
fi

# ============================================================================
# TC-DKBS-004: SIGTERM-ignoring process is escalated to SIGKILL
# ============================================================================
echo
echo "=== TC-DKBS-004: SIGTERM-resistant process gets SIGKILL ==="
echo

PID_FILE="$TMPDIR/test-004.pid"
# Spawn a bash that traps SIGTERM and keeps sleeping
bash -c 'trap "" TERM; sleep 60' &
RESISTANT_PID=$!
echo "$RESISTANT_PID" > "$PID_FILE"

START_TIME=$SECONDS
kill_stale_wrapper "$PID_FILE"
ELAPSED=$(( SECONDS - START_TIME ))
if wait_for_pid_gone "$RESISTANT_PID"; then
  echo -e "  ${GREEN}PASS${NC}: SIGTERM-resistant PID was eventually killed (took ${ELAPSED}s)"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: SIGTERM-resistant PID $RESISTANT_PID still running"
  kill -9 "$RESISTANT_PID" 2>/dev/null || true
  FAIL=$((FAIL+1))
fi
# Should take 5s grace + 1s escalation settle ≈ 6s. Generous bounds to absorb
# slow CI runners: at least 5s (the grace MUST elapse) and no more than 12s.
if [[ "$ELAPSED" -ge 5 && "$ELAPSED" -le 12 ]]; then
  echo -e "  ${GREEN}PASS${NC}: escalation timing within expected 5-12s window (${ELAPSED}s)"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: escalation took ${ELAPSED}s — outside expected 5-12s window"
  FAIL=$((FAIL+1))
fi

# ============================================================================
# TC-DKBS-005: Empty PID file is tolerated
# ============================================================================
echo
echo "=== TC-DKBS-005: empty PID file tolerated ==="
echo

PID_FILE="$TMPDIR/test-005.pid"
: > "$PID_FILE"  # touch empty
kill_stale_wrapper "$PID_FILE"
RC=$?
assert_eq "Function returned 0 for empty file" "0" "$RC"
if [[ -e "$PID_FILE" ]]; then
  echo -e "  ${RED}FAIL${NC}: empty PID file still exists"
  FAIL=$((FAIL+1))
else
  echo -e "  ${GREEN}PASS${NC}: empty PID file removed"
  PASS=$((PASS+1))
fi

# ============================================================================
# TC-DKBS-006: Symlink PID file is rejected
# ============================================================================
echo
echo "=== TC-DKBS-006: symlink PID file rejected ==="
echo

PID_FILE="$TMPDIR/test-006.pid"
TARGET="$TMPDIR/symlink-target"
echo "should-not-be-deleted" > "$TARGET"
ln -sf "$TARGET" "$PID_FILE"
kill_stale_wrapper "$PID_FILE"
RC=$?
# Function should refuse (return non-zero) and NOT remove the target.
if [[ -f "$TARGET" ]]; then
  echo -e "  ${GREEN}PASS${NC}: symlink target preserved"
  PASS=$((PASS+1))
else
  echo -e "  ${RED}FAIL${NC}: symlink target was deleted — security regression"
  FAIL=$((FAIL+1))
fi

# ============================================================================
# TC-DKBS-009: Unreadable PID file returns 1 (does NOT delete it)
# ============================================================================
echo
echo "=== TC-DKBS-009: unreadable PID file is refused, not silently deleted ==="
echo

PID_FILE="$TMPDIR/test-009.pid"
echo "12345" > "$PID_FILE"
chmod 000 "$PID_FILE"
# Skip if running as root (chmod 000 is bypassed)
if [[ "$(id -u)" == "0" ]]; then
  echo -e "  ${RED}SKIP${NC}: running as root, chmod 000 is bypassed"
  chmod 644 "$PID_FILE"
else
  # Capture function output into the per-run TMPDIR (not /tmp) so concurrent
  # test runs don't collide on a fixed path (Q PR #57 review, CWE-377).
  STDERR_FILE="$TMPDIR/test-009.stderr"
  kill_stale_wrapper "$PID_FILE" >"$STDERR_FILE" 2>&1
  RC=$?
  chmod 644 "$PID_FILE"  # restore so trap can clean up
  if [[ "$RC" != "0" ]]; then
    echo -e "  ${GREEN}PASS${NC}: unreadable PID file → return code $RC (not 0)"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: unreadable PID file silently returned 0"
    FAIL=$((FAIL+1))
  fi
  # File must still exist — we refused to operate on it, didn't delete it
  if [[ -e "$PID_FILE" ]]; then
    echo -e "  ${GREEN}PASS${NC}: unreadable PID file preserved (not deleted)"
    PASS=$((PASS+1))
  else
    echo -e "  ${RED}FAIL${NC}: unreadable PID file was deleted — silent-failure regression"
    FAIL=$((FAIL+1))
  fi
fi
# STDERR_FILE is inside TMPDIR which the EXIT trap removes — no separate cleanup needed.

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo -e "Total: $TOTAL  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo

[[ $FAIL -gt 0 ]] && exit 1
exit 0
