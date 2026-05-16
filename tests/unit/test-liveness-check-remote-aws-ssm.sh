#!/bin/bash
# test-liveness-check-remote-aws-ssm.sh — Unit tests for the SSM-driven
# liveness probe added in #137 (closes the structural false-DEAD bug
# under EXECUTION_BACKEND=remote-aws-ssm; #182 reproduction).
#
# Strategy: stub `aws` to record argv + return canned send-command /
# get-command-invocation JSON, drive the driver with various inputs and
# canned remote stdout, assert exit code + stdout token.
#
# Stdout contract: exactly one of `ALIVE`/`DEAD` (or empty).
# Exit codes:
#   0 — definitive verdict
#   1 — input/env validation
#   2 — indeterminate (transport fault / timeout / parse error / instance offline)
#
# Run: bash tests/unit/test-liveness-check-remote-aws-ssm.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DRIVER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/liveness-check-remote-aws-ssm.sh"

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

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

STUB_BIN="$TMPROOT/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/aws" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$AWS_RECORD_FILE"
case "$*" in
  *send-command*)
    if [[ "${AWS_SEND_FAIL:-0}" != "0" ]]; then
      echo "stub aws: send-command failure" >&2
      exit "${AWS_SEND_FAIL:-1}"
    fi
    echo '{"Command":{"CommandId":"stub-1","Status":"Pending"}}'
    ;;
  *get-command-invocation*)
    case "${AWS_GET_STATUS:-Success}" in
      Success)
        cat <<JSON
{"Status":"Success","StandardOutputContent":"${AWS_GET_STDOUT:-ALIVE}\n","StandardErrorContent":""}
JSON
        ;;
      Failed|TimedOut|Cancelled)
        cat <<JSON
{"Status":"${AWS_GET_STATUS}","StandardOutputContent":"","StandardErrorContent":"stub failure"}
JSON
        ;;
      InProgress|Pending)
        cat <<JSON
{"Status":"${AWS_GET_STATUS}","StandardOutputContent":"","StandardErrorContent":""}
JSON
        ;;
    esac
    ;;
esac
EOF
chmod +x "$STUB_BIN/aws"

reset_recorder() { : > "$TMPROOT/aws-record"; }

run_driver() {
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  bash "$DRIVER" "$@"
}

# Default valid env for happy-path tests.
export SSM_INSTANCE_ID="i-test"
export SSM_REMOTE_PROJECT_ID="testproj"
export SSM_REMOTE_PROJECT_DIR="/data/git/test"
export SSM_REGION="ap-southeast-1"

# ---------------------------------------------------------------------------
echo "=== TC-LCS-001: missing SSM_INSTANCE_ID → rc=1, no aws invocation ==="
# ---------------------------------------------------------------------------
reset_recorder
err=$(unset SSM_INSTANCE_ID; run_driver issue 99 2>&1 >/dev/null)
rc=$?
assert_rc "TC-LCS-001 rc=1 when SSM_INSTANCE_ID unset" 1 "$rc"
assert_contains "TC-LCS-001 stderr names SSM_INSTANCE_ID" "SSM_INSTANCE_ID" "$err"
if [[ ! -s "$TMPROOT/aws-record" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-LCS-001 aws was NOT invoked"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-LCS-001 aws was invoked despite missing env"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LCS-002: bad kind → rc=1 ==="
# ---------------------------------------------------------------------------
reset_recorder
run_driver garbage 99 >/dev/null 2>&1
rc=$?
assert_rc "TC-LCS-002 rc=1 on bad kind" 1 "$rc"
if [[ ! -s "$TMPROOT/aws-record" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-LCS-002 aws not invoked"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-LCS-002 aws invoked despite bad kind"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LCS-003: ALIVE happy path → stdout 'ALIVE', rc=0 ==="
# ---------------------------------------------------------------------------
reset_recorder
out=$(
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  AWS_GET_STATUS="Success" \
  AWS_GET_STDOUT="ALIVE" \
  bash "$DRIVER" issue 99
)
rc=$?
assert_rc "TC-LCS-003 rc=0 on ALIVE verdict" 0 "$rc"
assert_eq "TC-LCS-003 stdout = ALIVE" "ALIVE" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LCS-004: DEAD happy path → stdout 'DEAD', rc=0 ==="
# ---------------------------------------------------------------------------
reset_recorder
out=$(
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  AWS_GET_STATUS="Success" \
  AWS_GET_STDOUT="DEAD" \
  bash "$DRIVER" issue 99
)
rc=$?
assert_rc "TC-LCS-004 rc=0 on DEAD verdict" 0 "$rc"
assert_eq "TC-LCS-004 stdout = DEAD" "DEAD" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LCS-005: send-command failure → rc=2 ==="
# ---------------------------------------------------------------------------
reset_recorder
out=$(
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  AWS_SEND_FAIL=1 \
  bash "$DRIVER" issue 99 2>/dev/null
)
rc=$?
assert_rc "TC-LCS-005 rc=2 on send-command failure" 2 "$rc"
assert_eq "TC-LCS-005 stdout empty on transport fault" "" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LCS-006: Status: Failed → rc=2 ==="
# ---------------------------------------------------------------------------
reset_recorder
out=$(
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  AWS_GET_STATUS="Failed" \
  bash "$DRIVER" issue 99 2>/dev/null
)
rc=$?
assert_rc "TC-LCS-006 rc=2 on Status: Failed" 2 "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LCS-007: poll-loop wall-clock timeout → rc=2 ==="
# ---------------------------------------------------------------------------
reset_recorder
t0=$(date +%s)
PATH="$STUB_BIN:$PATH" \
AWS_RECORD_FILE="$TMPROOT/aws-record" \
AWS_GET_STATUS="InProgress" \
REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS=1 \
bash "$DRIVER" issue 99 >/dev/null 2>&1
rc=$?
t1=$(date +%s)
assert_rc "TC-LCS-007 rc=2 on poll timeout" 2 "$rc"
elapsed=$((t1 - t0))
if [[ "$elapsed" -le 4 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-LCS-007 wall-clock cap honored (elapsed=${elapsed}s)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-LCS-007 wall-clock cap not honored (elapsed=${elapsed}s)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LCS-008: garbage stdout → rc=2 ==="
# ---------------------------------------------------------------------------
# Anything other than ALIVE/DEAD is indeterminate — pin so a future remote
# snippet can't accidentally introduce a third token.
reset_recorder
out=$(
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  AWS_GET_STATUS="Success" \
  AWS_GET_STDOUT="weird-token-that-isnt-alive-or-dead" \
  bash "$DRIVER" issue 99 2>/dev/null
)
rc=$?
assert_rc "TC-LCS-008 rc=2 on garbage stdout" 2 "$rc"
assert_eq "TC-LCS-008 stdout empty (not the garbage)" "" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LCS-009: shell-metachar reject (parity with _has_shell_metachar) ==="
# ---------------------------------------------------------------------------
reset_recorder
err=$(
  SSM_REMOTE_PROJECT_DIR='/data/git/test;rm -rf /' \
  bash "$DRIVER" issue 99 2>&1 >/dev/null
)
rc=$?
assert_rc "TC-LCS-009 rc=1 on shell-metachar in SSM_REMOTE_PROJECT_DIR" 1 "$rc"
if [[ ! -s "$TMPROOT/aws-record" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-LCS-009 aws not invoked with metachar in env"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-LCS-009 aws invoked despite metachar"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LCS-010: argv to aws ssm send-command carries expected args ==="
# ---------------------------------------------------------------------------
reset_recorder
PATH="$STUB_BIN:$PATH" \
AWS_RECORD_FILE="$TMPROOT/aws-record" \
AWS_GET_STATUS="Success" \
AWS_GET_STDOUT="ALIVE" \
bash "$DRIVER" issue 99 >/dev/null 2>&1
argv=$(cat "$TMPROOT/aws-record")
assert_contains "TC-LCS-010 argv contains --region" "--region" "$argv"
assert_contains "TC-LCS-010 argv carries SSM_REGION value" "ap-southeast-1" "$argv"
assert_contains "TC-LCS-010 argv contains --instance-ids" "--instance-ids" "$argv"
assert_contains "TC-LCS-010 argv carries SSM_INSTANCE_ID value" "i-test" "$argv"
# The remote snippet must carry the kind ("issue") and issue number (99)
# verbatim. The argv lands inside a JSON payload (--parameters) so the
# inner double-quotes are JSON-escaped to \" — assert against that form.
assert_contains "TC-LCS-010 remote inner-cmd carries KIND=\"issue\"" 'KIND=\"issue\"' "$argv"
assert_contains "TC-LCS-010 remote inner-cmd carries N=\"99\"" 'N=\"99\"' "$argv"
assert_contains "TC-LCS-010 remote inner-cmd derives PID file via \${KIND}-\${N}.pid" '${KIND}-${N}.pid' "$argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LCS-011: argv carries --timeout-seconds 10 by default ==="
# ---------------------------------------------------------------------------
reset_recorder
PATH="$STUB_BIN:$PATH" \
AWS_RECORD_FILE="$TMPROOT/aws-record" \
AWS_GET_STATUS="Success" \
AWS_GET_STDOUT="ALIVE" \
bash "$DRIVER" issue 99 >/dev/null 2>&1
argv=$(cat "$TMPROOT/aws-record")
assert_contains "TC-LCS-011 argv contains --timeout-seconds" "--timeout-seconds" "$argv"
# 10 is the default per Finding 1.B.
assert_contains "TC-LCS-011 default timeout value is 10" $'--timeout-seconds\n10' "$argv"

# Also test override:
reset_recorder
PATH="$STUB_BIN:$PATH" \
AWS_RECORD_FILE="$TMPROOT/aws-record" \
AWS_GET_STATUS="Success" \
AWS_GET_STDOUT="ALIVE" \
SSM_COMMAND_TIMEOUT_SECONDS=20 \
bash "$DRIVER" issue 99 >/dev/null 2>&1
argv=$(cat "$TMPROOT/aws-record")
assert_contains "TC-LCS-011 SSM_COMMAND_TIMEOUT_SECONDS=20 override carried" $'--timeout-seconds\n20' "$argv"

echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] || exit 1
