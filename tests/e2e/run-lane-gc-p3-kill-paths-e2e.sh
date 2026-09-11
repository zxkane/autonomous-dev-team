#!/bin/bash
# run-lane-gc-p3-kill-paths-e2e.sh — E2E for Lane-GC PR-3 kill-path
# hardening (issue #379, INV-111). Test IDs: TC-LGC3-E2E-01/02.
#
# WHAT IT DOES
# ------------
# Drives the REAL, unmodified `dispatch-local.sh` CLI entry point (not a
# sourced/extracted function slice — the tests/unit/test-lane-gc-p3-kill-
# paths.sh unit suite already covers the sliced-function shape) against a
# genuine process-group fixture tree: a leader that dies on a plain TERM plus
# a PERSISTENT TERM-trapping member sharing its pgid. This is the exact shape
# the pre-fix leader-only `kill -0 $old_pid` escalation gate leaked (RC2 in
# the design's forensic audit) — a member that survives its own leader's
# death never got SIGKILLed, so it ran forever.
#
#   TC-LGC3-E2E-01 — legacy PID-file path: `dispatch-local.sh dev-new` finds
#     a PID file pointing at the dying leader; kill_stale_wrapper's
#     leader-OR-group gate must SIGKILL the surviving member.
#   TC-LGC3-E2E-02 — pgrep-fallback orphan sweep: no PID file at all; the
#     leader's cmdline anchors the project+type+issue match; same
#     leader-OR-group gate must reach the same surviving member.
#
# Both scenarios assert the WHOLE process group is gone within
# grace(5s)+2s — the issue's stated E2E acceptance bound — using only
# per-scenario temp PROJECT_DIR/PID_DIR anchors, so this can never collide
# with a real wrapper on the host. No network / credentials — always-on
# hermetic tier.
#
# Run: bash tests/e2e/run-lane-gc-p3-kill-paths-e2e.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCH_LOCAL="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatch-local.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
PASS=0; FAIL=0
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; echo "      $2"; FAIL=$((FAIL + 1)); }

[[ -f "$DISPATCH_LOCAL" ]] || { echo -e "${RED}FATAL${NC}: dispatch-local.sh missing"; exit 1; }

TMP="$(mktemp -d)"
# Best-effort cleanup: kill every process this script's own pgid may have
# spawned, whether or not a scenario left something running (e.g. an
# assertion failure short-circuiting before its own kill-9 cleanup runs).
trap 'pkill -9 -f "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# GRACE mirrors kill_stale_wrapper's own hardcoded 5s escalation wait
# (dispatch-local.sh's `for _i in 1 2 3 4 5; do … sleep 1; done` loop). The
# +2s settle covers the SIGKILL delivery + kernel reap, matching the issue's
# stated "tree empty within grace+2s" E2E bound.
GRACE=5
SETTLE=2

# run_scenario <label> <pid_file_or_empty> <piddir> <projdir> <issue> \
#              <pgrep_fallback: true|false> <leader_cmd...>
#
# Spawns the fixture leader (a setsid group whose leader dies on a plain
# TERM, with a persistent TERM-trapping member in the same pgid), then
# drives the REAL dispatch-local.sh CLI entry point exactly as the
# dispatcher invokes it, then asserts the whole group is gone within
# grace+settle.
run_scenario() {
  local label="$1" pid_file="$2" piddir="$3" projdir="$4" issue="$5" \
        pgrep_fallback="$6"
  shift 6
  local leader_cmd=("$@")

  mkdir -p "$piddir" "$projdir/scripts"

  "${leader_cmd[@]}" &
  local leader=$!
  sleep 0.5

  if [[ -n "$pid_file" ]]; then
    echo "$leader" > "$pid_file"
  fi

  local outlog="$TMP/dispatch-out-${label}.log"
  # P8 makes the opportunistic GC enforce by default. Keep that real entry
  # point hermetic: it may mutate this fixture state, never the host registry.
  setsid env ADT_STATE_ROOT="$TMP/state-${label}" \
    AUTONOMOUS_PID_DIR="$piddir" PROJECT_ID="e2e-lgc3-${label}" \
    PROJECT_DIR="$projdir" KILL_STALE_PGREP_FALLBACK="$pgrep_fallback" \
    bash "$DISPATCH_LOCAL" dev-new "$issue" >"$outlog" 2>&1 &
  local dispatch_sid=$!

  sleep "$((GRACE + SETTLE))"

  local verdict
  if kill -0 -- "-${leader}" 2>/dev/null; then
    verdict="GROUP-ALIVE"
  else
    verdict="GROUP-GONE"
  fi

  # Cleanup: the dispatch-local.sh invocation spawns its own agent-wrapper
  # child (the stub autonomous-dev.sh) in addition to the fixture leader —
  # kill both group trees so a failed assertion never leaks a live tree.
  kill -9 -- "-${dispatch_sid}" 2>/dev/null || true
  kill -9 -- "-${leader}" 2>/dev/null || true

  echo "$verdict"
  if [[ "$verdict" != "GROUP-GONE" ]]; then
    echo "      --- dispatch-local.sh output ($label) ---" >&2
    sed 's/^/      /' "$outlog" >&2
  fi
}

# ---------------------------------------------------------------------------
# TC-LGC3-E2E-01: legacy PID-file path.
# ---------------------------------------------------------------------------
echo "=== TC-LGC3-E2E-01: kill_stale_wrapper (PID-file path) reaps a leader-dead/member-alive fixture tree ==="

PIDDIR_A="$TMP/piddir-a"
PROJDIR_A="$TMP/proj-a"
ISSUE_A=990001
mkdir -p "$PROJDIR_A/scripts"
cat > "$PROJDIR_A/scripts/autonomous-dev.sh" <<'STUB'
#!/bin/bash
sleep 2
STUB
chmod +x "$PROJDIR_A/scripts/autonomous-dev.sh"

VERDICT_A=$(run_scenario "a" "$PIDDIR_A/issue-${ISSUE_A}.pid" "$PIDDIR_A" "$PROJDIR_A" "$ISSUE_A" false \
  setsid bash -c '(trap "" TERM; while :; do sleep 1; done) & disown; exec sleep 30')
[[ "$VERDICT_A" == "GROUP-GONE" ]] \
  && ok "TC-LGC3-E2E-01: fixture tree (leader + TERM-trapping member) empty within grace(${GRACE}s)+${SETTLE}s via the PID-file path" \
  || bad "TC-LGC3-E2E-01: fixture tree (leader + TERM-trapping member) empty within grace(${GRACE}s)+${SETTLE}s via the PID-file path" "verdict=$VERDICT_A"

# ---------------------------------------------------------------------------
# TC-LGC3-E2E-02: pgrep-fallback orphan sweep (no PID file).
# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC3-E2E-02: kill_stale_wrapper (pgrep-fallback sweep) reaps a leader-dead/member-alive fixture tree ==="

PIDDIR_B="$TMP/piddir-b"
PROJDIR_B="$TMP/proj-b"
ISSUE_B=990002
mkdir -p "$PROJDIR_B/scripts"
# The orphan leader must KEEP the autonomous-dev.sh cmdline (no exec) so the
# fallback's pgrep anchor (${PROJECT_DIR}/scripts/autonomous-dev.sh … --issue
# N) matches it, while it carries a persistent TERM-trapping member in its
# own pgid.
cat > "$PROJDIR_B/scripts/autonomous-dev.sh" <<'STUB'
#!/bin/bash
(trap "" TERM; while :; do sleep 1; done) & disown
sleep 30
STUB
chmod +x "$PROJDIR_B/scripts/autonomous-dev.sh"

VERDICT_B=$(run_scenario "b" "" "$PIDDIR_B" "$PROJDIR_B" "$ISSUE_B" true \
  setsid bash "$PROJDIR_B/scripts/autonomous-dev.sh" --issue "$ISSUE_B")
[[ "$VERDICT_B" == "GROUP-GONE" ]] \
  && ok "TC-LGC3-E2E-02: orphan fixture tree (no PID file) empty within grace(${GRACE}s)+${SETTLE}s via the pgrep-fallback sweep" \
  || bad "TC-LGC3-E2E-02: orphan fixture tree (no PID file) empty within grace(${GRACE}s)+${SETTLE}s via the pgrep-fallback sweep" "verdict=$VERDICT_B"

echo ""
echo "LANE-GC-P3-KILL-PATHS-E2E-SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
