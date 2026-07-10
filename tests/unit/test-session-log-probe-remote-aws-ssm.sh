#!/bin/bash
# test-session-log-probe-remote-aws-ssm.sh — Unit tests for the SSM-driven
# terminal-state probe added in #356 (INV-101). Closes the structural
# backend-blind bug where is_session_completed() read a controller-local
# path under EXECUTION_BACKEND=remote-aws-ssm and always missed.
#
# Strategy: stub `aws` to record argv + return canned send-command /
# get-command-invocation JSON, drive the driver in both --probe and
# --truncate modes, assert exit code + stdout contract.
#
# --probe stdout contract:
#   line 1: last `{"type":"result",...}` line (or empty)
#   line 2: log mtime as Unix epoch (only when line 1 non-empty)
# --truncate stdout: empty.
#
# Exit codes:
#   0 — definitive result (including "nothing found" for --probe)
#   1 — input/env validation
#   2 — indeterminate (transport fault / timeout / parse error)
#
# Run: bash tests/unit/test-session-log-probe-remote-aws-ssm.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DRIVER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/session-log-probe-remote-aws-ssm.sh"

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

# decode_inner_cmd <argv-record>
#
# [#454] FULL_CMD no longer interpolates INNER_CMD verbatim inside the outer
# single-quote wrap — it base64-encodes it (via _ssm_build_full_cmd,
# lib-ssm.sh) and decodes+evals it remotely. Assertions on INNER_CMD's
# actual content must decode that payload first rather than grepping the
# raw argv for literal text.
decode_inner_cmd() {
  local argv="$1" b64
  b64=$(printf '%s' "$argv" | grep -oE 'printf %s [A-Za-z0-9+/=]+ \| base64 -d' | sed -E 's/^printf %s //; s/ \| base64 -d$//')
  printf '%s' "$b64" | base64 -d
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
        jq -n --arg out "${AWS_GET_STDOUT:-}" \
          '{"Status":"Success","StandardOutputContent":$out,"StandardErrorContent":""}'
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
echo "=== TC-SLP-001: missing SSM_INSTANCE_ID → rc=1, no aws invocation ==="
# ---------------------------------------------------------------------------
reset_recorder
err=$(unset SSM_INSTANCE_ID; run_driver --probe 99 2>&1 >/dev/null)
rc=$?
assert_rc "TC-SLP-001 rc=1 when SSM_INSTANCE_ID unset" 1 "$rc"
assert_contains "TC-SLP-001 stderr names SSM_INSTANCE_ID" "SSM_INSTANCE_ID" "$err"
if [[ ! -s "$TMPROOT/aws-record" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-SLP-001 aws was NOT invoked"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-SLP-001 aws was invoked despite missing env"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SLP-002: missing SSM_REMOTE_PROJECT_ID → rc=1, no aws invocation ==="
# ---------------------------------------------------------------------------
reset_recorder
err=$(unset SSM_REMOTE_PROJECT_ID; run_driver --probe 99 2>&1 >/dev/null)
rc=$?
assert_rc "TC-SLP-002 rc=1 when SSM_REMOTE_PROJECT_ID unset" 1 "$rc"
assert_contains "TC-SLP-002 stderr names SSM_REMOTE_PROJECT_ID" "SSM_REMOTE_PROJECT_ID" "$err"
if [[ ! -s "$TMPROOT/aws-record" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-SLP-002 aws not invoked"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-SLP-002 aws invoked despite missing env"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SLP-003: --probe happy path, completed result line + mtime epoch ==="
# ---------------------------------------------------------------------------
reset_recorder
RESULT_LINE='{"type":"result","stop_reason":"end_turn","terminal_reason":"completed"}'
out=$(
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  AWS_GET_STATUS="Success" \
  AWS_GET_STDOUT="${RESULT_LINE}
1779333522" \
  bash "$DRIVER" --probe 99
)
rc=$?
assert_rc "TC-SLP-003 rc=0" 0 "$rc"
assert_eq "TC-SLP-003 line 1 = result line" "$RESULT_LINE" "$(echo "$out" | sed -n '1p')"
assert_eq "TC-SLP-003 line 2 = epoch" "1779333522" "$(echo "$out" | sed -n '2p')"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SLP-004: --probe, remote log absent / no result line → empty stdout, rc=0 ==="
# ---------------------------------------------------------------------------
reset_recorder
out=$(
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  AWS_GET_STATUS="Success" \
  AWS_GET_STDOUT="" \
  bash "$DRIVER" --probe 99
)
rc=$?
assert_rc "TC-SLP-004 rc=0 (nothing found is NOT an error)" 0 "$rc"
assert_eq "TC-SLP-004 stdout empty" "" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SLP-005: --probe, send-command failure → rc=2 ==="
# ---------------------------------------------------------------------------
reset_recorder
out=$(
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  AWS_SEND_FAIL=1 \
  bash "$DRIVER" --probe 99 2>/dev/null
)
rc=$?
assert_rc "TC-SLP-005 rc=2 on send-command failure" 2 "$rc"
assert_eq "TC-SLP-005 stdout empty on transport fault" "" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SLP-006: --probe, poll-loop wall-clock timeout → rc=2 ==="
# ---------------------------------------------------------------------------
reset_recorder
t0=$(date +%s)
PATH="$STUB_BIN:$PATH" \
AWS_RECORD_FILE="$TMPROOT/aws-record" \
AWS_GET_STATUS="InProgress" \
REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS=1 \
bash "$DRIVER" --probe 99 >/dev/null 2>&1
rc=$?
t1=$(date +%s)
assert_rc "TC-SLP-006 rc=2 on poll timeout" 2 "$rc"
elapsed=$((t1 - t0))
if [[ "$elapsed" -le 4 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-SLP-006 wall-clock cap honored (elapsed=${elapsed}s)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-SLP-006 wall-clock cap not honored (elapsed=${elapsed}s)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SLP-007: --truncate happy path → rc=0, empty stdout ==="
# ---------------------------------------------------------------------------
reset_recorder
out=$(
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  AWS_GET_STATUS="Success" \
  AWS_GET_STDOUT="" \
  bash "$DRIVER" --truncate 99
)
rc=$?
assert_rc "TC-SLP-007 rc=0" 0 "$rc"
assert_eq "TC-SLP-007 stdout empty" "" "$out"
argv=$(cat "$TMPROOT/aws-record")
decoded=$(decode_inner_cmd "$argv")
assert_contains "TC-SLP-007 remote inner-cmd truncates the SSM_REMOTE_PROJECT_ID-keyed log path" \
  'agent-${PROJECT_ID}-issue-${N}.log' "$decoded"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SLP-008: --truncate, SSM error → rc=2 ==="
# ---------------------------------------------------------------------------
reset_recorder
PATH="$STUB_BIN:$PATH" \
AWS_RECORD_FILE="$TMPROOT/aws-record" \
AWS_SEND_FAIL=1 \
bash "$DRIVER" --truncate 99 >/dev/null 2>&1
rc=$?
assert_rc "TC-SLP-008 rc=2 on SSM error" 2 "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SLP-009: shell-metachar reject (parity with _has_shell_metachar) ==="
# ---------------------------------------------------------------------------
reset_recorder
err=$(
  SSM_REMOTE_PROJECT_DIR='/data/git/test;rm -rf /' \
  bash "$DRIVER" --probe 99 2>&1 >/dev/null
)
rc=$?
assert_rc "TC-SLP-009 rc=1 on shell-metachar in SSM_REMOTE_PROJECT_DIR" 1 "$rc"
if [[ ! -s "$TMPROOT/aws-record" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-SLP-009 aws not invoked with metachar in env"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-SLP-009 aws invoked despite metachar"
  FAIL=$((FAIL + 1))
fi

reset_recorder
err=$(
  SSM_REMOTE_PROJECT_ID='bad;id' \
  bash "$DRIVER" --probe 99 2>&1 >/dev/null
)
rc=$?
assert_rc "TC-SLP-009b rc=1 on shell-metachar in SSM_REMOTE_PROJECT_ID" 1 "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-SLP-010: argv carries SSM_REMOTE_PROJECT_ID (NOT a controller PROJECT_ID) + issue number verbatim ==="
# ---------------------------------------------------------------------------
reset_recorder
PATH="$STUB_BIN:$PATH" \
AWS_RECORD_FILE="$TMPROOT/aws-record" \
AWS_GET_STATUS="Success" \
AWS_GET_STDOUT="" \
SSM_REMOTE_PROJECT_ID="remote-proj-xyz" \
PROJECT_ID="controller-proj" \
bash "$DRIVER" --probe 77 >/dev/null 2>&1
argv=$(cat "$TMPROOT/aws-record")
assert_contains "TC-SLP-010 argv contains --region" "--region" "$argv"
assert_contains "TC-SLP-010 argv carries SSM_REGION value" "ap-southeast-1" "$argv"
assert_contains "TC-SLP-010 argv contains --instance-ids" "--instance-ids" "$argv"
decoded=$(decode_inner_cmd "$argv")
assert_contains "TC-SLP-010 remote inner-cmd carries the REMOTE project id" 'PROJECT_ID="remote-proj-xyz"' "$decoded"
assert_contains "TC-SLP-010 remote inner-cmd carries N=\"77\"" 'N="77"' "$decoded"
# The controller sets a totally different PROJECT_ID env var locally — this
# driver must never read $PROJECT_ID, only $SSM_REMOTE_PROJECT_ID (#356
# PROJECT_ID != SSM_REMOTE_PROJECT_ID requirement).
if [[ "$decoded" == *'PROJECT_ID="controller-proj"'* ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-SLP-010 leaked the controller PROJECT_ID into remote argv"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-SLP-010 controller PROJECT_ID never reaches remote argv"
  PASS=$((PASS + 1))
fi

echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] || exit 1
