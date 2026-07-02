#!/bin/bash
# test-reap-recorded-descendants.sh — Regression tests for issue #360 (302a),
# R3: harden the INV-43 fan-out reap so a review-agent child that re-parented
# (e.g. via its own `setsid`) does not survive verdict resolution.
#
# Pre-#360, `_reap_fanout_processes` (lib-review-poll.sh) only group-kills the
# fan-out agent's setsid PGID. A child that ITSELF calls setsid (or is
# otherwise re-parented out of that process group) escapes the group-kill and
# can keep running — the observed #298/PR #300 incident where a duplicate
# review's codex child survived the reap and posted findings after merge+close.
#
# The fix adds `_reap_fanout_recorded_descendants`: a best-effort sweep that
# matches processes by a marker env var recorded at spawn time (the fan-out
# loop already mints a per-agent session id BEFORE launch — see
# AGENT_SESSION_IDS in autonomous-review.sh) via /proc/<pid>/environ, and
# TERM->KILLs any match. This is explicitly a best-effort, SCOPED guarantee:
#   - a child that stays in the pgid OR that re-parented but still carries the
#     recorded marker in its environment -> guaranteed reaped;
#   - a fully detached, double-forked grandchild that dropped ALL identifying
#     env state (e.g. re-executed via `env -i`) -> explicitly OUT of scope,
#     and this suite does NOT assert it is reaped (documented-unreachable
#     case, per R3's "scope honestly" requirement).
#
# Run: bash tests/unit/test-reap-recorded-descendants.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
POLL_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-poll.sh"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"

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

TMPDIR=$(mktemp -d)
trap 'pkill -P $$ 2>/dev/null; rm -rf "$TMPDIR"; :' EXIT

# shellcheck source=/dev/null
source "$POLL_LIB"

# ============================================================================
# TC-REAP-DESC-001: the new sweep helper exists
# ============================================================================
echo
echo "=== TC-REAP-DESC-001: lib-review-poll.sh defines the recorded-descendant sweep ==="
echo

assert_grep "_reap_fanout_recorded_descendants defined" \
  '_reap_fanout_recorded_descendants\(\)' "$POLL_LIB"

if ! command -v setsid >/dev/null 2>&1; then
  echo "  SKIP: setsid not available — behavioral reap tests skipped"
  echo
  echo "=== Results ==="
  TOTAL=$((PASS + FAIL))
  echo -e "Total: $TOTAL  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
  [[ $FAIL -gt 0 ]] && exit 1
  exit 0
fi

# ============================================================================
# TC-REAP-DESC-002: empty / garbage args -> no-op, no crash (set -e safe)
# ============================================================================
echo
echo "=== TC-REAP-DESC-002: no-op on empty / garbage marker args ==="
echo

if _reap_fanout_recorded_descendants "ADT_FANOUT_LANE_MARKER" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: empty marker-value list is a clean no-op"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: empty marker-value list returned non-zero"
  FAIL=$((FAIL + 1))
fi

if _reap_fanout_recorded_descendants "ADT_FANOUT_LANE_MARKER" "no-such-marker-value-ever" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: a marker value matching nothing is a clean no-op"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: non-matching marker value caused an error"
  FAIL=$((FAIL + 1))
fi

# ============================================================================
# TC-REAP-DESC-003: the GUARANTEED set — (a) a pgid-surviving child AND
# (b) a setsid-escaped-but-recorded child — are BOTH terminated after the
# full reap sequence (mirrors AC2: "reap test green for the guaranteed set
# (pgid + recorded descendants incl. one setsid child)").
# ============================================================================
echo
echo "=== TC-REAP-DESC-003: guaranteed set — pgid child + setsid-escaped marked child both reaped ==="
echo

MARKER_VALUE="test-lane-$$-$RANDOM"

# (a) A leader spawned under setsid whose child STAYS in the group (mirrors
#     TC-RPB-REAP-01's existing coverage — pinned here too so the "guaranteed
#     set" is proven as ONE combined pass, per AC2).
setsid bash -c 'sleep 120' >/dev/null 2>&1 &
PGID_LEADER=$!
sleep 0.3

# (b) A SEPARATE leader (simulating the fan-out agent's setsid session, the
#     one whose PGID IS in _AGENT_PGIDS) that forks a grandchild which calls
#     setsid AGAIN — escaping the leader's process group entirely — but the
#     grandchild carries the recorded marker in its environment (inherited
#     export, survives setsid + exec, per #360's design).
setsid bash -c "
  export ADT_FANOUT_LANE_MARKER='$MARKER_VALUE'
  setsid bash -c 'sleep 120' &
  echo \$! > '$TMPDIR/escaped-child.pid'
  wait
" >/dev/null 2>&1 &
ESCAPING_LEADER=$!

for i in {1..50}; do
  [[ -s "$TMPDIR/escaped-child.pid" ]] && break
  sleep 0.1
done
ESCAPED_CHILD_PID=$(cat "$TMPDIR/escaped-child.pid" 2>/dev/null)

if [[ -z "$ESCAPED_CHILD_PID" ]]; then
  echo -e "  ${RED}FAIL${NC}: setup error — escaped-child pid file never populated"
  FAIL=$((FAIL + 1))
else
  # Confirm both victims alive and the escaped child really did escape the
  # leader's process group (proves this test exercises the hard case, not a
  # trivially pgid-reapable one).
  if kill -0 -- "-$PGID_LEADER" 2>/dev/null && kill -0 "$ESCAPED_CHILD_PID" 2>/dev/null; then
    ESCAPED_CHILD_PGID=$(ps -o pgid= -p "$ESCAPED_CHILD_PID" 2>/dev/null | tr -d ' ')
    LEADER_PGID=$(ps -o pgid= -p "$ESCAPING_LEADER" 2>/dev/null | tr -d ' ')
    if [[ -n "$ESCAPED_CHILD_PGID" && "$ESCAPED_CHILD_PGID" != "$LEADER_PGID" ]]; then
      echo -e "  ${GREEN}PASS${NC}: escaped child's pgid ($ESCAPED_CHILD_PGID) differs from its leader's ($LEADER_PGID) — genuinely escaped"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${NC}: setup error — escaped child did not actually leave its leader's pgid"
      FAIL=$((FAIL + 1))
    fi

    # Run the FULL guaranteed-set reap sequence: pgid reap for (a), marker
    # sweep for (b).
    _reap_fanout_processes "$PGID_LEADER" >/dev/null 2>&1
    _reap_fanout_recorded_descendants "ADT_FANOUT_LANE_MARKER" "$MARKER_VALUE" >/dev/null 2>&1

    if wait_for_pid_gone "$ESCAPED_CHILD_PID" 80; then
      echo -e "  ${GREEN}PASS${NC}: setsid-escaped marked child (pid=$ESCAPED_CHILD_PID) reaped via recorded-descendant sweep"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${NC}: setsid-escaped marked child (pid=$ESCAPED_CHILD_PID) survived the reap"
      kill -9 "$ESCAPED_CHILD_PID" 2>/dev/null || true
      FAIL=$((FAIL + 1))
    fi

    if kill -0 -- "-$PGID_LEADER" 2>/dev/null; then
      echo -e "  ${RED}FAIL${NC}: pgid-surviving leader ($PGID_LEADER) NOT reaped (regression on existing _reap_fanout_processes coverage)"
      kill -KILL -- "-$PGID_LEADER" 2>/dev/null || true
      FAIL=$((FAIL + 1))
    else
      echo -e "  ${GREEN}PASS${NC}: pgid-surviving leader ($PGID_LEADER) reaped (existing coverage still holds)"
      PASS=$((PASS + 1))
    fi
  else
    echo -e "  ${RED}FAIL${NC}: setup error — one of the two victims died before the assertion"
    FAIL=$((FAIL + 1))
  fi
fi

kill -KILL -- "-$ESCAPING_LEADER" 2>/dev/null || true
kill -KILL "$ESCAPED_CHILD_PID" 2>/dev/null || true
kill -KILL -- "-$PGID_LEADER" 2>/dev/null || true

# ============================================================================
# TC-REAP-DESC-004: documented-unreachable case is explicitly NOT asserted
# ============================================================================
echo
echo "=== TC-REAP-DESC-004: a fully detached process with NO recorded marker is explicitly out of scope (not asserted) ==="
echo

# A process that drops ALL identifying env state (env -i) has nothing for the
# marker sweep to match on — this is the honestly-documented unreachable case
# (R3: "a truly detached double-forked grandchild that dropped all
# identifying state is out of reach"). We spawn it, run the sweep, and
# confirm the sweep does NOT claim to have reaped it — the test documents the
# boundary rather than asserting a guarantee this mechanism cannot provide.
setsid env -i bash -c 'sleep 5' >/dev/null 2>&1 &
DETACHED_PID=$!
sleep 0.3

if kill -0 "$DETACHED_PID" 2>/dev/null; then
  _reap_fanout_recorded_descendants "ADT_FANOUT_LANE_MARKER" "$MARKER_VALUE" >/dev/null 2>&1
  sleep 0.3
  if kill -0 "$DETACHED_PID" 2>/dev/null; then
    echo -e "  ${GREEN}PASS${NC}: detached env-stripped process correctly NOT reached by the marker sweep (documented scope boundary)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: detached process unexpectedly died — test setup invalid (expected it to survive, proving the scope boundary)"
    FAIL=$((FAIL + 1))
  fi
else
  echo -e "  ${RED}FAIL${NC}: setup error — detached process never started"
  FAIL=$((FAIL + 1))
fi
kill -KILL "$DETACHED_PID" 2>/dev/null || true

# ============================================================================
# Source-of-truth: wrapper records per-agent markers at spawn time and calls
# the sweep after verdict resolution.
# ============================================================================
echo
echo "=== TC-REAP-DESC-005: wrapper wiring — marker recorded at spawn, sweep called post-verdict ==="
echo

assert_grep "wrapper exports a per-agent fan-out lane marker before launch" \
  'export ADT_FANOUT_LANE_MARKER=' "$WRAPPER"
assert_grep "wrapper calls the recorded-descendant sweep at the reap call site" \
  '_reap_fanout_recorded_descendants' "$WRAPPER"
assert_grep "sweep is fed the per-agent session ids recorded at spawn time (AGENT_SESSION_IDS)" \
  '_reap_fanout_recorded_descendants "ADT_FANOUT_LANE_MARKER" "\$\{AGENT_SESSION_IDS\[@\]:-\}"' "$WRAPPER"
# Regression: the existing PGID reap call must be UNCHANGED (byte-identical
# substring still present) so TC-RPB-SRC-05 in test-review-e2e-command-poll-budget.sh
# keeps passing — the new sweep is an ADDITIONAL call, not a replacement.
assert_grep "existing PGID reap call site is unchanged" \
  '_reap_fanout_processes "\$\{_AGENT_PGIDS\[@\]:-\}"' "$WRAPPER"

# ============================================================================
# TC-REAP-DESC-006: doc presence (R4 / AC3)
# ============================================================================
echo
echo "=== TC-REAP-DESC-006: invariants.md + review-agent-flow.md updated in the same PR ==="
echo

INVARIANTS_DOC="$PROJECT_ROOT/docs/pipeline/invariants.md"
REVIEW_FLOW_DOC="$PROJECT_ROOT/docs/pipeline/review-agent-flow.md"

assert_grep "invariants.md has an INV-104 entry" '^## INV-104:' "$INVARIANTS_DOC"
assert_grep "review-agent-flow.md references INV-104" 'INV-104' "$REVIEW_FLOW_DOC"

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
