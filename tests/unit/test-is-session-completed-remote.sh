#!/bin/bash
# test-is-session-completed-remote.sh — [INV-101] (#356) AC1 regression.
#
# BUG: is_session_completed() read the dev wrapper's log at a controller-local
# path (/tmp/agent-${PROJECT_ID}-issue-N.log). Under
# EXECUTION_BACKEND=remote-aws-ssm the wrapper's log lives on the EXECUTION
# host, not the controller — the local `[ -r ]` check always missed, so this
# function returned 1 (not completed) unconditionally for every remote-SSM
# project, permanently disabling the INV-98 delegation and the INV-12 PTL
# gate for those projects.
#
# FIX: is_session_completed now branches on EXECUTION_BACKEND. Under
# remote-aws-ssm it calls _remote_session_log_probe (which shells out to
# session-log-probe-remote-aws-ssm.sh over SSM) instead of reading the local
# file directly. This suite stubs the driver via
# _SESSION_LOG_PROBE_DRIVER_OVERRIDE so it can drive the remote branch without
# a real SSM round-trip.
#
# Run: bash tests/unit/test-is-session-completed-remote.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID="controller-proj-$$"
export MAX_RETRIES=3
export MAX_CONCURRENT=5
export AGENT_CMD=claude

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

TMPDIR_T=$(mktemp -d)
trap 'rm -rf "$TMPDIR_T"' EXIT

# Stub driver: records its argv (mode + issue) and the env it saw, echoes
# a scripted --probe response. --truncate mode always succeeds unless
# STUB_TRUNCATE_FAIL=1.
STUB_DRIVER="$TMPDIR_T/stub-driver.sh"
STUB_CALLS="$TMPDIR_T/stub-calls.log"
cat > "$STUB_DRIVER" <<'STUB'
#!/bin/bash
{
  echo "MODE=$1 ISSUE=$2"
  echo "SSM_REMOTE_PROJECT_ID=${SSM_REMOTE_PROJECT_ID:-}"
  echo "PROJECT_ID=${PROJECT_ID:-}"
} >> "$STUB_CALLS"
case "$1" in
  --probe)
    if [[ "${STUB_PROBE_RC:-0}" != "0" ]]; then
      exit "${STUB_PROBE_RC}"
    fi
    printf '%s' "${STUB_PROBE_OUTPUT:-}"
    ;;
  --truncate)
    [[ "${STUB_TRUNCATE_FAIL:-0}" = "1" ]] && exit 2
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DRIVER"
export _SESSION_LOG_PROBE_DRIVER_OVERRIDE="$STUB_DRIVER"
export STUB_CALLS

# The stub driver runs in a subprocess (bash "$driver" ...) forked by
# _remote_session_log_probe / _reset_session_log — these vars must stay
# EXPORTED to reach it. `unset` would strip the export flag, and a later
# plain reassignment would silently become a local (non-exported) var — so
# reset_stub sets them to "" instead of unsetting.
export STUB_PROBE_RC="" STUB_PROBE_OUTPUT="" STUB_TRUNCATE_FAIL=""
reset_stub() { : > "$STUB_CALLS"; STUB_PROBE_RC=""; STUB_PROBE_OUTPUT=""; STUB_TRUNCATE_FAIL=""; }

# ---------------------------------------------------------------------------
echo "=== TC-ISCR-001: remote backend, stubbed completed result → rc=0, reason+end_ts captured ==="
# ---------------------------------------------------------------------------
reset_stub
STUB_PROBE_OUTPUT=$'{"type":"result","stop_reason":"end_turn","terminal_reason":"completed"}\n1779333522'
reason=""; end_ts=""
EXECUTION_BACKEND=remote-aws-ssm SSM_REMOTE_PROJECT_ID="remoteproj" \
  is_session_completed 501 reason end_ts
rc=$?
assert_eq "TC-ISCR-001 rc=0" "0" "$rc"
assert_eq "TC-ISCR-001 reason=completed" "completed" "$reason"
assert_eq "TC-ISCR-001 end_ts derived from stubbed epoch" "2026-05-21T03:18:42Z" "$end_ts"
assert_eq "TC-ISCR-001 driver invoked with --probe mode" "1" "$(grep -c '^MODE=--probe ISSUE=501$' "$STUB_CALLS")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ISCR-002: remote backend, stubbed prompt_too_long → rc=0, reason captured ==="
# ---------------------------------------------------------------------------
reset_stub
STUB_PROBE_OUTPUT=$'{"type":"result","stop_reason":"stop_sequence","terminal_reason":"prompt_too_long"}\n1779346800'
reason=""
EXECUTION_BACKEND=remote-aws-ssm SSM_REMOTE_PROJECT_ID="remoteproj" \
  is_session_completed 502 reason
rc=$?
assert_eq "TC-ISCR-002 rc=0" "0" "$rc"
assert_eq "TC-ISCR-002 reason=prompt_too_long" "prompt_too_long" "$reason"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ISCR-003: remote backend, stubbed probe returns EMPTY (SSM timeout/error/no-match) → rc=1, fail-closed ==="
# ---------------------------------------------------------------------------
reset_stub
STUB_PROBE_OUTPUT=""
EXECUTION_BACKEND=remote-aws-ssm SSM_REMOTE_PROJECT_ID="remoteproj" \
  is_session_completed 503
rc=$?
assert_eq "TC-ISCR-003 empty probe → not completed (fail-closed)" "1" "$rc"

reset_stub
STUB_PROBE_RC=2
EXECUTION_BACKEND=remote-aws-ssm SSM_REMOTE_PROJECT_ID="remoteproj" \
  is_session_completed 504
rc=$?
assert_eq "TC-ISCR-003b driver rc=2 (SSM error) → is_session_completed returns 1" "1" "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ISCR-004: EXECUTION_BACKEND unset/local with the SAME stub installed → stub NEVER invoked, local path used ==="
# ---------------------------------------------------------------------------
reset_stub
log_file="/tmp/agent-${PROJECT_ID}-issue-505.log"
printf '%s' '{"type":"result","stop_reason":"end_turn","terminal_reason":"completed"}' > "$log_file"
reason=""
is_session_completed 505 reason
rc=$?
assert_eq "TC-ISCR-004 rc=0 via LOCAL path" "0" "$rc"
assert_eq "TC-ISCR-004 reason=completed via LOCAL path" "completed" "$reason"
if [[ -s "$STUB_CALLS" ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-ISCR-004 the remote stub was invoked despite EXECUTION_BACKEND=local"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-ISCR-004 remote stub NOT invoked under local backend"
  PASS=$((PASS + 1))
fi
rm -f "$log_file"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ISCR-005: non-claude dev CLI short-circuits BEFORE the backend branch (no wasted SSM round-trip) ==="
# ---------------------------------------------------------------------------
reset_stub
AGENT_DEV_CMD=codex EXECUTION_BACKEND=remote-aws-ssm SSM_REMOTE_PROJECT_ID="remoteproj" \
  is_session_completed 506
rc=$?
assert_eq "TC-ISCR-005 rc=1 for non-claude dev CLI" "1" "$rc"
if [[ -s "$STUB_CALLS" ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-ISCR-005 remote probe invoked despite non-claude dev CLI gate"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-ISCR-005 remote probe never invoked (CLI gate short-circuits first)"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ISCR-006: PROJECT_ID != SSM_REMOTE_PROJECT_ID — driver receives the REMOTE id, never the controller id ==="
# ---------------------------------------------------------------------------
reset_stub
STUB_PROBE_OUTPUT=""
EXECUTION_BACKEND=remote-aws-ssm SSM_REMOTE_PROJECT_ID="remote-proj-xyz" \
  is_session_completed 507
call_line=$(grep '^SSM_REMOTE_PROJECT_ID=' "$STUB_CALLS")
assert_eq "TC-ISCR-006 driver saw SSM_REMOTE_PROJECT_ID=remote-proj-xyz" "SSM_REMOTE_PROJECT_ID=remote-proj-xyz" "$call_line"
controller_line=$(grep '^PROJECT_ID=' "$STUB_CALLS")
assert_eq "TC-ISCR-006 controller PROJECT_ID (${PROJECT_ID}) is visible to the driver env but is NOT what it must key on" \
  "PROJECT_ID=${PROJECT_ID}" "$controller_line"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ISCR-007: remote --truncate routes through _reset_session_log ==="
# ---------------------------------------------------------------------------
reset_stub
EXECUTION_BACKEND=remote-aws-ssm SSM_REMOTE_PROJECT_ID="remoteproj" \
  _reset_session_log 508
rc=$?
assert_eq "TC-ISCR-007 _reset_session_log rc=0 via remote driver" "0" "$rc"
assert_eq "TC-ISCR-007 driver invoked with --truncate mode" "1" "$(grep -c '^MODE=--truncate ISSUE=508$' "$STUB_CALLS")"

reset_stub
STUB_TRUNCATE_FAIL=1
EXECUTION_BACKEND=remote-aws-ssm SSM_REMOTE_PROJECT_ID="remoteproj" \
  _reset_session_log 509
rc=$?
assert_eq "TC-ISCR-007b _reset_session_log rc!=0 when remote truncate fails" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ISCR-008: local _reset_session_log unchanged (byte-identical local truncate) ==="
# ---------------------------------------------------------------------------
reset_stub
log_file="/tmp/agent-${PROJECT_ID}-issue-510.log"
printf 'stale content' > "$log_file"
_reset_session_log 510
rc=$?
assert_eq "TC-ISCR-008 rc=0" "0" "$rc"
assert_eq "TC-ISCR-008 log truncated to 0 bytes" "0" "$(stat -c %s "$log_file")"
if [[ -s "$STUB_CALLS" ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-ISCR-008 remote stub invoked despite local backend"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-ISCR-008 remote stub NOT invoked under local backend"
  PASS=$((PASS + 1))
fi
rm -f "$log_file"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
