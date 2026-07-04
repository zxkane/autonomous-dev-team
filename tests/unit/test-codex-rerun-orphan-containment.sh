#!/bin/bash
# test-codex-rerun-orphan-containment.sh — Regression tests for issue #406:
# the review wrapper's post-resolution reap does not terminate the codex
# fan-out subshell's bounded re-run controller, so an orphaned, token-burning
# `codex review` loop can survive verdict resolution and post a stale
# duplicate "Review findings:" comment on an already-decided PR.
#
# Layer 1 (the PRIMARY fix — rc>=128/rc-124 treated as terminal in the
# adapter's re-run loop) is covered in tests/unit/test-lib-review-codex.sh
# (TC-CXRS-RUN-09..16, TC-CXRS-LIVE-01..04). This file covers:
#   - Layer 2: _reap_fanout_controller_subshells (lib-review-poll.sh, new) —
#     direct-PID reap of the fan-out controller subshell itself, which
#     neither pre-existing reaper (_reap_fanout_processes,
#     _reap_fanout_recorded_descendants) can reach.
#   - Layer 3b: the rc-sidecar write in autonomous-review.sh is guarded on
#     the fan-out dir still existing, so a deleted dir produces silence, not
#     a "No such file or directory" error line.
#   - Missing-rc tolerance: the wrapper's existing sidecar-missing branch
#     classifies gracefully when a controller subshell is reaped before it
#     wrote its .rc sidecar (pre-existing code, pinned here as a regression
#     guard for this issue's Layer-2 interaction).
#
# Run: bash tests/unit/test-codex-rerun-orphan-containment.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
POLL_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-poll.sh"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
CODEX_ADAPTER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/adapters/codex.sh"

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
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${RED}FAIL${NC}: $desc (pattern unexpectedly found: $pattern)"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  fi
}

wait_for_pid_gone() {
  local pid="$1" timeout="${2:-50}" i
  for ((i = 0; i < timeout; i++)); do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

[[ -f "$POLL_LIB" ]] || { echo -e "${RED}FATAL${NC}: $POLL_LIB missing"; exit 1; }
[[ -f "$WRAPPER" ]] || { echo -e "${RED}FATAL${NC}: $WRAPPER missing"; exit 1; }
[[ -f "$CODEX_ADAPTER" ]] || { echo -e "${RED}FATAL${NC}: $CODEX_ADAPTER missing"; exit 1; }

# shellcheck source=/dev/null
source "$POLL_LIB"

# ============================================================================
# TC-RFCS-001: the new reaper helper exists
# ============================================================================
echo
echo "=== TC-RFCS-001: lib-review-poll.sh defines the fan-out controller subshell reaper ==="
echo

assert_grep "_reap_fanout_controller_subshells defined" \
  '_reap_fanout_controller_subshells\(\)' "$POLL_LIB"

# ============================================================================
# TC-RFCS-002/003: empty / garbage args -> no-op, no crash (set -e safe)
# ============================================================================
echo
echo "=== TC-RFCS-002/003: no-op on empty / garbage PID args ==="
echo

if _reap_fanout_controller_subshells >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: TC-RFCS-002 empty PID list is a clean no-op"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RFCS-002 empty PID list returned non-zero"
  FAIL=$((FAIL + 1))
fi

if _reap_fanout_controller_subshells "abc" "0" "999999999" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: TC-RFCS-003 non-numeric / already-dead PID args skipped cleanly"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RFCS-003 non-numeric / dead PID args caused an error"
  FAIL=$((FAIL + 1))
fi

# ============================================================================
# TC-RFCS-004/005: a fixture CONTROLLER SUBSHELL — a plain `( … ) &` fork that
# shares the CALLING shell's process group (no setsid, mirroring the
# production fan-out subshell shape exactly) — is reaped by DIRECT PID kill,
# and the calling shell itself (the "wrapper" stand-in) survives (proves the
# reap never used a group-form kill, which would have hit the caller too).
# ============================================================================
echo
echo "=== TC-RFCS-004/005: fixture controller subshell reaped; wrapper stand-in survives (group-kill footgun guard) ==="
echo

STANDIN_OUT_FILE=$(mktemp)
(
  # This inner subshell is OUR "wrapper" stand-in: it backgrounds a fixture
  # controller subshell exactly the way autonomous-review.sh's fan-out loop
  # does (`( … ) &`, no setsid) and then calls the reaper against ITS pid,
  # from within the SAME process group. If the reaper ever used a group-form
  # `kill -- -$pid`, it would signal this whole process group — including
  # this stand-in itself — which the test below would detect as this
  # subshell dying before it could report survival.
  ( sleep 60 ) &
  CONTROLLER_PID=$!
  sleep 0.3

  if kill -0 "$CONTROLLER_PID" 2>/dev/null; then
    _reap_fanout_controller_subshells "$CONTROLLER_PID" >/dev/null 2>&1
    echo "STANDIN_ALIVE=1"
    echo "CONTROLLER_PID=$CONTROLLER_PID"
  else
    echo "SETUP_ERROR=1"
  fi
) > "$STANDIN_OUT_FILE" 2>&1 &
STANDIN_SUBSHELL_PID=$!
wait "$STANDIN_SUBSHELL_PID" 2>/dev/null

if grep -q "SETUP_ERROR=1" "$STANDIN_OUT_FILE" 2>/dev/null; then
  echo -e "  ${RED}FAIL${NC}: TC-RFCS-004 setup error — fixture controller subshell never started"
  FAIL=$((FAIL + 1))
elif grep -q "STANDIN_ALIVE=1" "$STANDIN_OUT_FILE" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-RFCS-005 wrapper stand-in survived the reap call (direct PID kill, not a group kill)"
  PASS=$((PASS + 1))
  CONTROLLER_PID_VAL=$(grep '^CONTROLLER_PID=' "$STANDIN_OUT_FILE" | cut -d= -f2)
  if [[ -n "$CONTROLLER_PID_VAL" ]] && wait_for_pid_gone "$CONTROLLER_PID_VAL" 80; then
    echo -e "  ${GREEN}PASS${NC}: TC-RFCS-004 fixture controller subshell (pid=$CONTROLLER_PID_VAL) reaped"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-RFCS-004 fixture controller subshell survived the reap"
    [[ -n "$CONTROLLER_PID_VAL" ]] && kill -9 "$CONTROLLER_PID_VAL" 2>/dev/null || true
    FAIL=$((FAIL + 1))
  fi
else
  echo -e "  ${RED}FAIL${NC}: TC-RFCS-005 wrapper stand-in did NOT survive — the reap likely used a group-form kill that hit its own caller"
  FAIL=$((FAIL + 1))
fi
rm -f "$STANDIN_OUT_FILE" 2>/dev/null || true

# ============================================================================
# TC-RFCS-006/007/008: wrapper wiring (source-of-truth)
# ============================================================================
echo
echo "=== TC-RFCS-006/007/008: wrapper wiring — controller reap call site ==="
echo

assert_grep "TC-RFCS-006 wrapper calls the fan-out controller subshell reaper" \
  '_reap_fanout_controller_subshells' "$WRAPPER"
assert_grep "TC-RFCS-006b reaper is fed the collected fan-out subshell PIDs (_fanout_pids)" \
  '_reap_fanout_controller_subshells "\$\{_fanout_pids\[@\]:-\}"' "$WRAPPER"
assert_not_grep "TC-RFCS-007 the wrapper does NOT lane_record_pgid the fan-out subshell PIDs (would let Lane-GC kill the live wrapper)" \
  'lane_record_pgid.*_fanout_pids' "$WRAPPER"
# Regression: the existing two reap call sites are UNCHANGED (byte-identical
# substrings still present) — the new reap is an ADDITIONAL call, not a
# replacement, at the same post-resolution call site.
assert_grep "TC-RFCS-008a existing PGID reap call site is unchanged" \
  '_reap_fanout_processes "\$\{_AGENT_PGIDS\[@\]:-\}"' "$WRAPPER"
assert_grep "TC-RFCS-008b existing recorded-descendant sweep call site is unchanged" \
  '_reap_fanout_recorded_descendants "ADT_FANOUT_LANE_MARKER" "\$\{AGENT_SESSION_IDS\[@\]:-\}"' "$WRAPPER"

# ============================================================================
# TC-RFCS-009: review-round-2 finding — a controller that has already
# committed to a re-run launch can spawn ONE more marked child in the window
# between the FIRST marker sweep and the controller-PID kill; that child's
# PGID is never sidecar-recorded (the fan-out dir is already gone), so only a
# SECOND marker sweep AFTER the controller kill can catch it.
# ============================================================================
echo
echo "=== TC-RFCS-009: marker sweep repeats AFTER the controller-subshell kill (closes the late-spawn race) ==="
echo

_sweep_count=$(grep -cE '_reap_fanout_recorded_descendants "ADT_FANOUT_LANE_MARKER" "\$\{AGENT_SESSION_IDS\[@\]:-\}"' "$WRAPPER")
assert_eq "TC-RFCS-009a marker sweep call appears exactly twice (once before, once after the controller kill)" \
  "2" "$_sweep_count"

_first_sweep_line=$(grep -nE '_reap_fanout_recorded_descendants "ADT_FANOUT_LANE_MARKER" "\$\{AGENT_SESSION_IDS\[@\]:-\}"' "$WRAPPER" | head -1 | cut -d: -f1)
_controller_kill_line=$(grep -nE '^_reap_fanout_controller_subshells "\$\{_fanout_pids\[@\]:-\}"' "$WRAPPER" | head -1 | cut -d: -f1)
_second_sweep_line=$(grep -nE '_reap_fanout_recorded_descendants "ADT_FANOUT_LANE_MARKER" "\$\{AGENT_SESSION_IDS\[@\]:-\}"' "$WRAPPER" | tail -1 | cut -d: -f1)

if [[ -n "$_first_sweep_line" && -n "$_controller_kill_line" && -n "$_second_sweep_line" \
      && "$_first_sweep_line" -lt "$_controller_kill_line" \
      && "$_controller_kill_line" -lt "$_second_sweep_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-RFCS-009b ordering is first-sweep < controller-kill < second-sweep"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RFCS-009b ordering is NOT first-sweep < controller-kill < second-sweep (got lines $_first_sweep_line / $_controller_kill_line / $_second_sweep_line)"
  FAIL=$((FAIL + 1))
fi

# ============================================================================
# TC-RSG: Layer 3b — rc-sidecar write guarded on the fan-out dir existing
# ============================================================================
echo
echo "=== TC-RSG-001/002: rc-sidecar write is silent when the fan-out dir is gone, unchanged when present ==="
echo

TMPDIR_RSG=$(mktemp -d)

# TC-RSG-001: fan-out dir deleted before the write → no write, no stderr error.
rm -rf "$TMPDIR_RSG/gone"
out_rsg1=$(
  _FANOUT_DIR="$TMPDIR_RSG/gone"
  _agent_rc_file="$TMPDIR_RSG/gone/sid.rc"
  _rc=1
  [[ -d "$_FANOUT_DIR" ]] && printf '%s\n' "$_rc" 2>/dev/null > "$_agent_rc_file"
  echo "wrote=$([[ -f "$_agent_rc_file" ]] && echo yes || echo no)"
) 2>"$TMPDIR_RSG/stderr1"
assert_eq "TC-RSG-001a no write attempted when the fan-out dir is gone" "wrote=no" "$out_rsg1"
assert_eq "TC-RSG-001b no stderr output (silent, not a 'No such file or directory' error)" "" "$(cat "$TMPDIR_RSG/stderr1")"

# TC-RSG-002: fan-out dir present → write proceeds exactly as before.
mkdir -p "$TMPDIR_RSG/present"
out_rsg2=$(
  _FANOUT_DIR="$TMPDIR_RSG/present"
  _agent_rc_file="$TMPDIR_RSG/present/sid.rc"
  _rc=1
  [[ -d "$_FANOUT_DIR" ]] && printf '%s\n' "$_rc" 2>/dev/null > "$_agent_rc_file"
  echo "wrote=$([[ -f "$_agent_rc_file" ]] && echo yes || echo no)|content=$(cat "$_agent_rc_file" 2>/dev/null)"
)
assert_eq "TC-RSG-002 fan-out dir present → write proceeds unchanged" "wrote=yes|content=1" "$out_rsg2"

rm -rf "$TMPDIR_RSG"

# TC-RSG-001c (redirect-order regression): `> file 2>/dev/null` does NOT
# suppress the `>` open's own ENOENT — bash opens redirects left-to-right, so
# the file-open error hits stderr BEFORE the dup2-to-/dev/null takes effect.
# Only `2>/dev/null > file` (stderr redirected first) actually silences it.
# This is the TOCTOU race the [[ -d ]] check alone cannot close: the check can
# pass and the dir can still vanish before the printf's `>` open runs.
TMPDIR_RSG3=$(mktemp -d)
{
  out_rsg1c_wrongorder=$(
    printf '%s\n' 1 > "$TMPDIR_RSG3/missing/sid.rc" 2>/dev/null
    echo done
  )
} 2>"$TMPDIR_RSG3/stderr_wrongorder"
assert_eq "TC-RSG-001c-control wrong order (> file 2>/dev/null) DOES leak stderr — proves the ordering matters" \
  "1" "$(grep -c 'No such file or directory' "$TMPDIR_RSG3/stderr_wrongorder")"
{
  out_rsg1c_rightorder=$(
    printf '%s\n' 1 2>/dev/null > "$TMPDIR_RSG3/missing/sid.rc"
    echo done
  )
} 2>"$TMPDIR_RSG3/stderr_rightorder"
assert_eq "TC-RSG-001c fix order (2>/dev/null > file) suppresses the ENOENT" \
  "" "$(cat "$TMPDIR_RSG3/stderr_rightorder")"
rm -rf "$TMPDIR_RSG3"

echo
echo "=== TC-RSG-003: wrapper wiring — sidecar write gated on the fan-out dir existing ==="
echo

assert_grep "TC-RSG-003 sidecar printf is gated on \[\[ -d \"\$_FANOUT_DIR\" \]\]" \
  '\[\[ -d "\$_FANOUT_DIR" \]\] && printf' "$WRAPPER"

assert_grep "TC-RSG-003b sidecar printf redirects stderr BEFORE the file open (2>/dev/null precedes >) so a TOCTOU-race ENOENT stays silent" \
  'printf .%s.n. "\$_rc" 2>/dev/null > "\$_agent_rc_file"' "$WRAPPER"

# ============================================================================
# TC-RSG-004: missing-rc tolerance (pre-existing code, pinned as a regression
# guard for this issue's Layer-2 interaction — a controller subshell reaped
# before it wrote its .rc sidecar must classify gracefully, not crash/hang).
# ============================================================================
echo
echo "=== TC-RSG-004: missing-rc sidecar classifies gracefully (no crash/hang) ==="
echo

assert_grep "TC-RSG-004 wrapper's rc-file read has a missing-sidecar fallback (AGENT_LAUNCH_RC defaults to 1, no crash)" \
  'AGENT_LAUNCH_RC\["\$_sid"\]=1' "$WRAPPER"

# ============================================================================
# Doc presence (test-cases doc referenced by the issue)
# ============================================================================
echo
echo "=== Doc presence: test-cases doc exists ==="
echo

TESTCASE_DOC="$PROJECT_ROOT/docs/test-cases/codex-rerun-orphan-containment.md"
if [[ -f "$TESTCASE_DOC" ]]; then
  echo -e "  ${GREEN}PASS${NC}: docs/test-cases/codex-rerun-orphan-containment.md exists"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: docs/test-cases/codex-rerun-orphan-containment.md missing"
  FAIL=$((FAIL + 1))
fi

# ============================================================================
# Doc presence: invariants.md / review-agent-flow.md reference #406
# ============================================================================
echo
echo "=== TC-RFCS-DOC: invariants.md + review-agent-flow.md updated in the same PR ==="
echo

INVARIANTS_DOC="$PROJECT_ROOT/docs/pipeline/invariants.md"
REVIEW_FLOW_DOC="$PROJECT_ROOT/docs/pipeline/review-agent-flow.md"

assert_grep "invariants.md references #406" '#406' "$INVARIANTS_DOC"
assert_grep "review-agent-flow.md references #406" '#406' "$REVIEW_FLOW_DOC"

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
