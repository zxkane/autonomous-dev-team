#!/bin/bash
# run-lane-gc-p5-guardian-e2e.sh — E2E for Lane-GC series PR-5 (issue #381,
# INV-118). Test ID: TC-LGC5-E2E-01.
#
# WHAT IT DOES
# ------------
# Drives the REAL, unmodified `autonomous-dev.sh` CLI entry point (not a
# sourced/extracted function slice, and not a stub wrapper script standing in
# for it — the unit suite tests/unit/test-lane-gc-p5-guardian.sh already
# covers the sliced-function/fixture shape) far enough into a real run to
# install its lane registry AND the guardian sidecar, using:
#   - a fixture `gh` on PATH (token-mode auth: `gh auth status` succeeds;
#     `gh issue view` returns a minimal normalized issue body/labels/state so
#     itp_github_read_task's fail-closed capture-then-check succeeds)
#   - a fixture `claude` CLI on PATH that just sleeps (simulates a long-
#     running agent session so the wrapper is genuinely still "in flight",
#     not already exited, when the SIGKILL below lands)
#   - a minimal autonomous.conf (token auth mode — no token daemon, so the
#     lane-mint-before-any-background-child ordering has nothing else to
#     race against)
#
# Once the wrapper has reached the real agent CLI spawn (observable via the
# fixture claude's own marker file), the ENTIRE wrapper session is SIGKILLed
# — the exact non-graceful death class (RC1 in the design's forensic audit)
# that traps never survive and this series exists to close. Then asserts:
#   1. the fixture claude process (the "agent subtree") is gone within
#      grace+2s (the issue's stated E2E acceptance bound)
#   2. the lane's STATE promoted to `reaped-by-guardian` (proving the
#      guardian — not merely the OS reaping an orphan on its own — performed
#      the observable state transition)
#
# No real network / credentials — always-on hermetic tier, same posture as
# the sibling Lane-GC PR-3 E2E (tests/e2e/run-lane-gc-p3-kill-paths-e2e.sh).
#
# Run: bash tests/e2e/run-lane-gc-p5-guardian-e2e.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEV_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
LIB_LANE="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-lane.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
PASS=0; FAIL=0
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; echo "      $2"; FAIL=$((FAIL + 1)); }

[[ -f "$DEV_WRAPPER" ]] || { echo -e "${RED}FATAL${NC}: autonomous-dev.sh missing"; exit 1; }
[[ -f "$LIB_LANE" ]] || { echo -e "${RED}FATAL${NC}: lib-lane.sh missing"; exit 1; }
command -v setsid >/dev/null 2>&1 || { echo -e "${RED}FATAL${NC}: setsid missing — cannot run this E2E (setsid is a hard prereq for the guardian itself)"; exit 1; }

TMP="$(mktemp -d)"
trap 'pkill -9 -f "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

BIN="$TMP/bin"; mkdir -p "$BIN"
PROJDIR="$TMP/proj"; mkdir -p "$PROJDIR/scripts"
PIDDIR="$TMP/piddir"; mkdir -p "$PIDDIR"
STATE_ROOT="$TMP/state"; mkdir -p "$STATE_ROOT"
CLAUDE_MARKER="$TMP/claude-launched.marker"
ISSUE_NUM=990501

# ---------------------------------------------------------------------------
# Fixture `gh` — token-mode auth check + the one read this run needs before
# reaching the agent spawn (itp_github_read_task's `gh issue view`).
# ---------------------------------------------------------------------------
cat > "$BIN/gh" <<'GHSTUB'
#!/bin/bash
case "$1 $2" in
  "auth status") exit 0 ;;
esac
if [[ "$1" == "issue" && "$2" == "view" ]]; then
  echo '{"title":"e2e fixture issue","body":"E2E fixture body for the guardian E2E.","state":"OPEN","labels":[{"name":"autonomous"},{"name":"in-progress"}]}'
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "comment" ]]; then
  exit 0
fi
if [[ "$1" == "issue" && "$2" == "edit" ]]; then
  exit 0
fi
if [[ "$1" == "api" ]]; then
  # itp_github_list_comments's `gh api --paginate --slurp repos/.../comments`
  # — an empty comment list is sufficient for this E2E (it never inspects
  # comment content, only that the read succeeds).
  echo '[[]]'
  exit 0
fi
# Anything else: succeed quietly with empty output — this E2E's whole point
# is reached (and the wrapper SIGKILLed) long before any other `gh` verb
# would matter.
exit 0
GHSTUB
chmod +x "$BIN/gh"

# ---------------------------------------------------------------------------
# Fixture `claude` — the "agent CLI". Drops a marker the moment it starts
# (so this script knows the wrapper truly reached the spawn), then sleeps —
# simulating a long-running agent session still in flight when the SIGKILL
# lands.
# ---------------------------------------------------------------------------
cat > "$BIN/claude" <<CLAUDESTUB
#!/bin/bash
echo "\$\$" > "$CLAUDE_MARKER"
exec sleep 60
CLAUDESTUB
chmod +x "$BIN/claude"

# ---------------------------------------------------------------------------
# Minimal autonomous.conf — token auth mode (no App creds, no token daemon;
# this run needs nothing beyond the fixture gh's `auth status` success and a
# GH_TOKEN in the environment so setup_github_auth's own gate is satisfied).
# ---------------------------------------------------------------------------
cat > "$PROJDIR/scripts/autonomous.conf" <<CONF
PROJECT_ID="e2e-lgc5"
REPO="zxkane/e2e-lgc5-fixture"
REPO_OWNER="zxkane"
REPO_NAME="e2e-lgc5-fixture"
PROJECT_DIR="$PROJDIR"
AGENT_CMD="claude"
AGENT_DEV_MODEL=""
GH_AUTH_MODE="token"
MAX_RETRIES=3
HEARTBEAT_INTERVAL_SECONDS=0
CONF

echo "=== TC-LGC5-E2E-01: real autonomous-dev.sh installs lane+guardian, SIGKILL mid-run -> guardian reaps within grace+2s ==="

# Launch the REAL wrapper, in its own session (setsid) so the whole tree can
# be SIGKILLed as one unit by session id — this is the "wrapper session"
# the design's forensic audit means by a non-graceful death.
setsid env \
  PATH="$BIN:$PATH" \
  GH_TOKEN="e2e-fixture-token-not-real" \
  AUTONOMOUS_PID_DIR="$PIDDIR" \
  ADT_STATE_ROOT="$STATE_ROOT" \
  AUTONOMOUS_CONF="$PROJDIR/scripts/autonomous.conf" \
  bash "$DEV_WRAPPER" --issue "$ISSUE_NUM" --mode new \
  > "$TMP/wrapper-stdout.log" 2>&1 &
WRAPPER_LEADER=$!

# Wait for the fixture claude to actually launch (proves the wrapper reached
# past lane mint + guardian install + auth + issue read all the way to the
# real agent spawn) — bounded wait, not a fixed sleep.
DEADLINE=$(( $(date +%s) + 30 ))
while [[ ! -s "$CLAUDE_MARKER" ]] && [[ $(date +%s) -lt $DEADLINE ]]; do
  sleep 0.3
done

if [[ ! -s "$CLAUDE_MARKER" ]]; then
  bad "TC-LGC5-E2E-01: fixture claude never launched within 30s — the wrapper did not reach the agent spawn" "wrapper stdout: $(cat "$TMP/wrapper-stdout.log" 2>/dev/null | tail -20)"
  echo "LANE-GC-P5-GUARDIAN-E2E-SUMMARY pass=${PASS} fail=${FAIL}"
  exit 1
fi
ok "TC-LGC5-E2E-01a: the real autonomous-dev.sh reached the agent spawn (fixture claude launched)"

CLAUDE_PID="$(cat "$CLAUDE_MARKER")"

# Locate the lane dir this run minted — the ONLY lane under this run's
# isolated ADT_STATE_ROOT for project e2e-lgc5.
LANE_DIR=""
for _try in 1 2 3 4 5 6 7 8 9 10; do
  LANE_DIR="$(find "$STATE_ROOT/autonomous-e2e-lgc5/lanes" -maxdepth 1 -mindepth 1 -type d ! -name '.pending-*' 2>/dev/null | head -1)"
  [[ -n "$LANE_DIR" ]] && break
  sleep 0.3
done

if [[ -z "$LANE_DIR" ]]; then
  bad "TC-LGC5-E2E-01b: no lane directory found under the isolated ADT_STATE_ROOT" "expected $STATE_ROOT/autonomous-e2e-lgc5/lanes/<id>"
else
  ok "TC-LGC5-E2E-01b: lane registry directory minted at $LANE_DIR"
fi

GUARDIAN_ALIVE_BEFORE="unknown"
if [[ -n "$LANE_DIR" ]]; then
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-lane.sh
  GUARDIAN_PID_BEFORE="$(bash -c 'source "$1"; lane_get "$2" GUARDIAN_PID' _ "$LIB_LANE" "$LANE_DIR" 2>/dev/null)"
  if [[ "$GUARDIAN_PID_BEFORE" =~ ^[0-9]+$ ]]; then
    GUARDIAN_ALIVE_BEFORE=$(kill -0 "$GUARDIAN_PID_BEFORE" 2>/dev/null && echo yes || echo no)
  fi
fi
if [[ "$GUARDIAN_ALIVE_BEFORE" == "yes" ]]; then
  ok "TC-LGC5-E2E-01c: guardian sidecar is installed and running before the SIGKILL"
else
  bad "TC-LGC5-E2E-01c: guardian sidecar is NOT confirmed alive before the SIGKILL" "GUARDIAN_PID recorded='${GUARDIAN_PID_BEFORE:-<empty>}' alive=$GUARDIAN_ALIVE_BEFORE"
fi

# ---------------------------------------------------------------------------
# The actual test: SIGKILL the ENTIRE wrapper session — the non-graceful
# death class no in-process trap survives. The guardian (a SEPARATE
# setsid-detached session) must NOT die with it.
# ---------------------------------------------------------------------------
GRACE=10   # do_reap's own default grace for the pgid escalation
SETTLE=2
kill -9 -- "-${WRAPPER_LEADER}" 2>/dev/null || true
wait "$WRAPPER_LEADER" 2>/dev/null || true

# Wait for the CLAUDE PID to die first — measured against the grace+settle
# bound for THIS specific assertion (the pgid escalation phase of do_reap).
DEADLINE2=$(( $(date +%s) + GRACE + SETTLE + 5 ))
while [[ $(date +%s) -lt $DEADLINE2 ]]; do
  kill -0 "$CLAUDE_PID" 2>/dev/null || break
  sleep 0.5
done

CLAUDE_ALIVE_AFTER=$(kill -0 "$CLAUDE_PID" 2>/dev/null && echo yes || echo no)
if [[ "$CLAUDE_ALIVE_AFTER" == "no" ]]; then
  ok "TC-LGC5-E2E-01d: fixture agent (claude) process is gone within grace(${GRACE}s)+${SETTLE}s of the wrapper's SIGKILL"
else
  bad "TC-LGC5-E2E-01d: fixture agent process SURVIVED the wrapper's SIGKILL past the grace+settle bound" "claude pid=$CLAUDE_PID still alive"
fi

# do_reap continues past the pgid escalation into its own escape sweep
# before promoting STATE to the terminal reaped-by-guardian value — wait
# for the GUARDIAN ITSELF to exit (its own bounded self-exit after do_reap
# returns) before sampling STATE, rather than racing ahead the instant the
# claude pid dies.
if [[ "$GUARDIAN_PID_BEFORE" =~ ^[0-9]+$ ]]; then
  DEADLINE3=$(( $(date +%s) + 15 ))
  while [[ $(date +%s) -lt $DEADLINE3 ]]; do
    kill -0 "$GUARDIAN_PID_BEFORE" 2>/dev/null || break
    sleep 0.3
  done
fi

STATE_AFTER="unknown"
if [[ -n "$LANE_DIR" ]]; then
  STATE_AFTER="$(bash -c 'source "$1"; lane_get "$2" STATE' _ "$LIB_LANE" "$LANE_DIR" 2>/dev/null)"
fi
if [[ "$STATE_AFTER" == "reaped-by-guardian" ]]; then
  ok "TC-LGC5-E2E-01e: lane STATE promoted to reaped-by-guardian (the guardian, not merely an incidental OS reap, performed this run's teardown)"
else
  bad "TC-LGC5-E2E-01e: lane STATE is not reaped-by-guardian" "STATE=${STATE_AFTER}"
fi

echo ""
echo "LANE-GC-P5-GUARDIAN-E2E-SUMMARY pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
