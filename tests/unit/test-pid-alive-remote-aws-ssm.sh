#!/bin/bash
# test-pid-alive-remote-aws-ssm.sh — Integration tests for `pid_alive`'s
# remote-backend short-circuit (#137, INV-30).
#
# Strategy: stub liveness-check-remote-aws-ssm.sh via PATH override (a fake
# under TMPROOT) that emits chosen verdicts and records invocation count.
# Source lib-dispatch.sh and exercise pid_alive across backend/knob combos.
#
# Run: bash tests/unit/test-pid-alive-remote-aws-ssm.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_rc() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected_rc=$expected actual_rc=$actual"
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
    echo "      expected='$expected'"
    echo "      actual=  '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    echo "      haystack='${haystack:0:300}'"
    FAIL=$((FAIL + 1))
  fi
}

# Required env (lib-dispatch.sh enforces these via : "${VAR:?...}")
export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-pid-alive-remote
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# Sandbox: TMPROOT contains a stub liveness-check script. We override the
# path that lib-dispatch's _remote_pid_alive_query uses by setting
# `_LIVENESS_CHECK_DRIVER_OVERRIDE` (a test-only knob honored by the lib).
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

export DRIVER_RECORD="$TMPROOT/driver-call-count"
export DRIVER_STDOUT_FILE="$TMPROOT/driver-stdout"
export DRIVER_RC_FILE="$TMPROOT/driver-rc"

mkdir -p "$TMPROOT/bin"
STUB_DRIVER="$TMPROOT/bin/liveness-check-remote-aws-ssm.sh"
cat > "$STUB_DRIVER" <<'EOF'
#!/bin/bash
# Stub: increment counter, emit canned stdout, exit canned rc.
echo "called: $*" >> "$DRIVER_RECORD"
[[ -f "$DRIVER_STDOUT_FILE" ]] && cat "$DRIVER_STDOUT_FILE"
exit "$(cat "$DRIVER_RC_FILE" 2>/dev/null || echo 0)"
EOF
chmod +x "$STUB_DRIVER"

reset_stub() {
  : > "$DRIVER_RECORD"
  : > "$DRIVER_STDOUT_FILE"
  echo "0" > "$DRIVER_RC_FILE"
}

# Stub PID dir so the LOCAL fall-through path doesn't hit a real ~/.local/state.
export AUTONOMOUS_PID_DIR="$TMPROOT/pid-state"
mkdir -p "$AUTONOMOUS_PID_DIR"
chmod 700 "$AUTONOMOUS_PID_DIR"

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

# Force lib to use our stub driver instead of resolving SCRIPT_DIR.
export _LIVENESS_CHECK_DRIVER_OVERRIDE="$STUB_DRIVER"

# ---------------------------------------------------------------------------
echo "=== TC-RPA-001: ALIVE verdict → pid_alive returns 0 ==="
# ---------------------------------------------------------------------------
reset_stub
echo "ALIVE" > "$DRIVER_STDOUT_FILE"
echo "0" > "$DRIVER_RC_FILE"
EXECUTION_BACKEND=remote-aws-ssm pid_alive issue 99
assert_rc "TC-RPA-001 ALIVE → 0" 0 "$?"
calls=$(wc -l < "$DRIVER_RECORD" | tr -d ' ')
assert_eq "TC-RPA-001 driver invoked once" "1" "$calls"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RPA-002: DEAD verdict → pid_alive returns 1 ==="
# ---------------------------------------------------------------------------
reset_stub
echo "DEAD" > "$DRIVER_STDOUT_FILE"
echo "0" > "$DRIVER_RC_FILE"
EXECUTION_BACKEND=remote-aws-ssm pid_alive issue 99
assert_rc "TC-RPA-002 DEAD → 1" 1 "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RPA-003: indeterminate (rc=2) → pid_alive returns 0 (ALIVE-bias) ==="
# ---------------------------------------------------------------------------
# Load-bearing: this is the WHOLE point of the fix. A reflexive cleanup PR
# must not flip this to return 1.
reset_stub
echo "" > "$DRIVER_STDOUT_FILE"
echo "2" > "$DRIVER_RC_FILE"
_REMOTE_LIVENESS_DEGRADED_COUNT=0  # reset for clean WARN-counter test below
EXECUTION_BACKEND=remote-aws-ssm pid_alive issue 99 2>/dev/null
assert_rc "TC-RPA-003 indeterminate → 0 (ALIVE-bias)" 0 "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RPA-004: EXECUTION_BACKEND=local → driver MUST NOT be invoked ==="
# ---------------------------------------------------------------------------
reset_stub
EXECUTION_BACKEND=local pid_alive issue 99
# We don't care about the rc here (local-backend behavior is unchanged);
# we ONLY assert the remote driver was not consulted.
calls=$(wc -l < "$DRIVER_RECORD" | tr -d ' ')
assert_eq "TC-RPA-004 driver NOT invoked under EXECUTION_BACKEND=local" "0" "$calls"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RPA-005: REMOTE_LIVENESS_CHECK_DISABLE=true → driver NOT invoked ==="
# ---------------------------------------------------------------------------
reset_stub
EXECUTION_BACKEND=remote-aws-ssm REMOTE_LIVENESS_CHECK_DISABLE=true pid_alive issue 99
calls=$(wc -l < "$DRIVER_RECORD" | tr -d ' ')
assert_eq "TC-RPA-005 driver NOT invoked when DISABLE=true" "0" "$calls"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RPA-006: stub returns rc=1 with empty stdout → ALIVE-bias ==="
# ---------------------------------------------------------------------------
# Mirrors what happens when the driver itself crashes / not on PATH.
reset_stub
echo "" > "$DRIVER_STDOUT_FILE"
echo "1" > "$DRIVER_RC_FILE"
_REMOTE_LIVENESS_DEGRADED_COUNT=0
EXECUTION_BACKEND=remote-aws-ssm pid_alive issue 99 2>/dev/null
assert_rc "TC-RPA-006 driver crash → ALIVE-bias (0)" 0 "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RPA-007: mark_stalled under remote backend with ALIVE → defers ==="
# ---------------------------------------------------------------------------
# INV-26 inheritance: mark_stalled queries pid_alive first; if ALIVE,
# defers the stall transition. Here we verify the remote path is
# consulted by mark_stalled and respected.
reset_stub
echo "ALIVE" > "$DRIVER_STDOUT_FILE"
echo "0" > "$DRIVER_RC_FILE"
# mark_stalled requires GH calls; stub gh as a no-op.
gh() {
  case "$1" in
    issue)
      case "$2" in
        view) printf '[]'; return 0 ;;
        comment|edit) return 0 ;;
      esac
      ;;
  esac
  return 0
}
export -f gh

# Source-of-truth check: pid_alive is called inside mark_stalled BEFORE
# any GH edit. We mock get_pid to return a stable PID so the deferral
# comment branch can format its idempotency marker.
get_pid() { echo "12345"; }
export -f get_pid

EXECUTION_BACKEND=remote-aws-ssm mark_stalled 99
assert_rc "TC-RPA-007 mark_stalled returns 0 (deferred) under remote ALIVE" 0 "$?"
# Driver must have been called at least once.
calls=$(wc -l < "$DRIVER_RECORD" | tr -d ' ')
if [[ "$calls" -ge 1 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-RPA-007 mark_stalled invoked driver via pid_alive"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RPA-007 mark_stalled did not invoke driver (calls=$calls)"
  FAIL=$((FAIL + 1))
fi

unset -f gh
unset -f get_pid

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RPA-008: degraded-state counter increments on indeterminate ==="
# ---------------------------------------------------------------------------
reset_stub
echo "" > "$DRIVER_STDOUT_FILE"
echo "2" > "$DRIVER_RC_FILE"
_REMOTE_LIVENESS_DEGRADED_COUNT=0
EXECUTION_BACKEND=remote-aws-ssm pid_alive issue 99 2>/dev/null
assert_eq "TC-RPA-008 counter = 1 after first indeterminate" "1" "$_REMOTE_LIVENESS_DEGRADED_COUNT"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RPA-009: WARN log on 1st + 10th indeterminate, NOT on 2-9 ==="
# ---------------------------------------------------------------------------
reset_stub
echo "" > "$DRIVER_STDOUT_FILE"
echo "2" > "$DRIVER_RC_FILE"
_REMOTE_LIVENESS_DEGRADED_COUNT=0
warn_log="$TMPROOT/warn-log"
: > "$warn_log"
for i in 1 2 3 4 5 6 7 8 9 10; do
  EXECUTION_BACKEND=remote-aws-ssm pid_alive issue 99 2>>"$warn_log" >/dev/null
done
warn_count=$(grep -c "WARN" "$warn_log" || echo 0)
assert_eq "TC-RPA-009 WARN emitted exactly 2 times in 10 ticks (tick 1 + tick 10)" "2" "$warn_count"
assert_eq "TC-RPA-009 counter = 10 after 10 indeterminate ticks" "10" "$_REMOTE_LIVENESS_DEGRADED_COUNT"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-RPA-010: source-of-truth grep — indeterminate branch returns 0 ==="
# ---------------------------------------------------------------------------
# Load-bearing: the conservative-bias decision lives or dies on this single
# line. A reflexive cleanup PR must fail the suite if it flips to return 1.
if grep -A 30 'EXECUTION_BACKEND.*remote-aws-ssm' "$LIB" | grep -E '^[[:space:]]*\*\)[[:space:]]*$' >/dev/null; then
  # Extract the *) branch body (between `*)` and the next `;;`).
  branch_body=$(awk '
    /EXECUTION_BACKEND.*remote-aws-ssm/ { in_block=1 }
    in_block && /^[[:space:]]*\*\)[[:space:]]*$/ { in_star=1; next }
    in_star && /^[[:space:]]*;;[[:space:]]*$/ { exit }
    in_star { print }
  ' "$LIB")
  # Strip comment lines so prose mentioning `return 1` doesn't
  # false-fail the assert. We want to verify the BRANCH BODY contains
  # an actual `return 0` statement and NO `return 1` statement.
  body_no_comments=$(echo "$branch_body" | sed -E 's/^[[:space:]]*#.*$//')
  has_return_0=$(echo "$body_no_comments" | grep -cE '^[[:space:]]*return[[:space:]]+0[[:space:]]*$' || true)
  has_return_1=$(echo "$body_no_comments" | grep -cE '^[[:space:]]*return[[:space:]]+1[[:space:]]*$' || true)
  if [[ "$has_return_0" -ge 1 ]] && [[ "$has_return_1" -eq 0 ]]; then
    echo -e "  ${GREEN}PASS${NC}: TC-RPA-010 indeterminate *) branch returns 0 (ALIVE-bias preserved)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-RPA-010 indeterminate branch must have exactly 'return 0' (got: return_0=$has_return_0 return_1=$has_return_1)"
    FAIL=$((FAIL + 1))
  fi
else
  echo -e "  ${RED}FAIL${NC}: TC-RPA-010 indeterminate *) branch not found in pid_alive"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] || exit 1
