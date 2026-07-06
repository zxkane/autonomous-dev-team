#!/bin/bash
# run-lane-gc-p6-gate-e2e.sh — E2E for Lane-GC series PR-6 (issue #382,
# INV-119). Test IDs: TC-LGC6-E2E-01/02.
#
# WHAT IT DOES
# ------------
# Drives the REAL, unmodified `dispatch-local.sh` CLI entry point (not a
# sourced/extracted function slice — the tests/unit/test-lane-gc-p6-gate.sh
# unit suite already covers the sliced-function shape) through the
# back-pressure admission gate's full refusal→spawn lifecycle against a
# real fixture project layout (fixture `autonomous-dev.sh`/
# `autonomous-review.sh` on PATH, a real `autonomous.conf`, symlinked libs —
# mirrors the project-side deployment topology exactly):
#
#   TC-LGC6-E2E-01 — box distress injected via the test-only override env
#     vars (the SAME seam the unit suite uses, exercised here through the
#     REAL CLI entry point end-to-end rather than a sourced function) ->
#     `dispatch-local.sh` exits 75, logs the deferral, and touches the
#     defer marker under the isolated ADT_STATE_ROOT. No fixture wrapper
#     process is ever spawned.
#   TC-LGC6-E2E-02 — the SAME invocation repeated with the injected
#     overrides cleared (a normal/healthy env) -> `dispatch-local.sh`
#     exits 0 and the fixture wrapper is genuinely spawned (observable via
#     its own marker file) — proving the gate is not permanently wedged by
#     the first refusal and a subsequent healthy tick proceeds normally.
#
# No network / credentials — always-on hermetic tier, same posture as the
# sibling Lane-GC PR-3/PR-5 E2E scripts.
#
# Run: bash tests/e2e/run-lane-gc-p6-gate-e2e.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
DISPATCH_LOCAL="$SCRIPTS/dispatch-local.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
PASS=0; FAIL=0
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; echo "      $2"; FAIL=$((FAIL + 1)); }

[[ -f "$DISPATCH_LOCAL" ]] || { echo -e "${RED}FATAL${NC}: dispatch-local.sh missing"; exit 1; }

TMP="$(mktemp -d)"
trap 'pkill -9 -f "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

PROJ="$TMP/proj"; mkdir -p "$PROJ/scripts"
STATE_ROOT="$TMP/state"; mkdir -p "$STATE_ROOT"
WRAPPER_MARKER="$TMP/dev-wrapper-launched.marker"
ISSUE_NUM=990601

# ---------------------------------------------------------------------------
# Fixture dev/review wrappers — drop a marker the instant they start (so this
# script can prove a spawn genuinely happened), then sleep briefly so
# dispatch-local.sh's own post-spawn `kill -0 $CHILD_PID` liveness check
# (its "did the process start successfully" gate) observes a live process.
# ---------------------------------------------------------------------------
cat > "$PROJ/scripts/autonomous-dev.sh" <<STUB
#!/bin/bash
echo "\$\$" > "$WRAPPER_MARKER"
sleep 3
STUB
chmod +x "$PROJ/scripts/autonomous-dev.sh"
cp "$PROJ/scripts/autonomous-dev.sh" "$PROJ/scripts/autonomous-review.sh"

cat > "$PROJ/scripts/autonomous.conf" <<CONF
PROJECT_ID="e2e-lgc6"
REPO="zxkane/e2e-lgc6-fixture"
REPO_OWNER="zxkane"
REPO_NAME="e2e-lgc6-fixture"
PROJECT_DIR="$PROJ"
AGENT_CMD="claude"
GH_AUTH_MODE="token"
MAX_RETRIES=3
CONF

for f in dispatch-local.sh lib-config.sh lib-lane.sh; do
  ln -sf "$SCRIPTS/$f" "$PROJ/scripts/$f"
done

echo "=== TC-LGC6-E2E-01: real dispatch-local.sh under injected pressure -> exit 75 + defer marker, no spawn ==="

OUT01=$(
  ADT_STATE_ROOT="$STATE_ROOT" \
  _GATE_LOAD1_PER_CORE_OVERRIDE="99" \
  _GATE_MEM_AVAILABLE_MB_OVERRIDE="999999" \
  _GATE_SWAP_PCT_OVERRIDE="0" \
  _GATE_LIVE_LANE_COUNT_OVERRIDE="0" \
  bash -c "cd '$PROJ' && bash scripts/dispatch-local.sh dev-new $ISSUE_NUM" 2>&1
)
RC01=$?

if [[ "$RC01" -eq 75 ]]; then
  ok "TC-LGC6-E2E-01a: dispatch-local.sh exits 75 under injected back-pressure"
else
  bad "TC-LGC6-E2E-01a: expected exit 75, got $RC01" "output: $OUT01"
fi

if grep -q 'back-pressure' <<<"$OUT01"; then
  ok "TC-LGC6-E2E-01b: deferral is logged with a back-pressure reason"
else
  bad "TC-LGC6-E2E-01b: no back-pressure deferral logged" "output: $OUT01"
fi

MARKER01="$STATE_ROOT/autonomous-e2e-lgc6/lanes/.defer-issue-${ISSUE_NUM}"
if [[ -f "$MARKER01" ]]; then
  ok "TC-LGC6-E2E-01c: defer marker touched at $MARKER01"
else
  bad "TC-LGC6-E2E-01c: defer marker NOT found" "expected $MARKER01"
fi

if [[ -s "$WRAPPER_MARKER" ]]; then
  bad "TC-LGC6-E2E-01d: fixture wrapper was spawned despite the gate refusing — the gate did NOT block the spawn" "marker unexpectedly present: $(cat "$WRAPPER_MARKER")"
else
  ok "TC-LGC6-E2E-01d: no fixture wrapper was spawned (the gate genuinely blocked it, not just logged a warning)"
fi

echo ""
echo "=== TC-LGC6-E2E-02: SAME invocation with a healthy (uninjected) env -> exit 0, fixture wrapper genuinely spawns ==="

OUT02=$(
  ADT_STATE_ROOT="$STATE_ROOT" \
  _GATE_LOAD1_PER_CORE_OVERRIDE="0.1" \
  _GATE_MEM_AVAILABLE_MB_OVERRIDE="999999" \
  _GATE_SWAP_PCT_OVERRIDE="0" \
  _GATE_LIVE_LANE_COUNT_OVERRIDE="0" \
  bash -c "cd '$PROJ' && bash scripts/dispatch-local.sh dev-new $ISSUE_NUM" 2>&1
)
RC02=$?

if [[ "$RC02" -eq 0 ]]; then
  ok "TC-LGC6-E2E-02a: dispatch-local.sh exits 0 under a healthy env (gate is not permanently wedged by the prior refusal)"
else
  bad "TC-LGC6-E2E-02a: expected exit 0, got $RC02" "output: $OUT02"
fi

DEADLINE=$(( $(date +%s) + 10 ))
while [[ ! -s "$WRAPPER_MARKER" ]] && [[ $(date +%s) -lt $DEADLINE ]]; do
  sleep 0.2
done
if [[ -s "$WRAPPER_MARKER" ]]; then
  ok "TC-LGC6-E2E-02b: fixture wrapper genuinely spawned (marker present, PID=$(cat "$WRAPPER_MARKER"))"
else
  bad "TC-LGC6-E2E-02b: fixture wrapper never spawned within 10s" "no marker at $WRAPPER_MARKER"
fi

if [[ -f "$MARKER01" ]]; then
  bad "TC-LGC6-E2E-02c: stale defer marker from TC-LGC6-E2E-01 should be removed after this successful dispatch" "marker still present: $MARKER01"
else
  ok "TC-LGC6-E2E-02c: prior defer marker removed after the successful dispatch (design §5 cleanup)"
fi

echo ""
echo "LANE-GC-P6-GATE-E2E-SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
