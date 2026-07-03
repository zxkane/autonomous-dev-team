#!/bin/bash
# test-lib-ssm.sh — Unit tests for the shared SSM helpers extracted from
# dispatch-remote-aws-ssm.sh (#137 Finding 2.A).
#
# lib-ssm.sh exposes:
#   _has_shell_metachar <value>       — CWE-78 reject of shell metachars
#   _ssm_run_remote_command <iid> <region> <inner-cmd>
#                                     — synchronous send-command + poll;
#                                       prints stdout, returns 0 (success),
#                                       2 (transport fault / timeout / failure).
#
# Run: bash tests/unit/test-lib-ssm.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-ssm.sh"

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

# Sandbox: stub `aws` to record argv + return canned send-command /
# get-command-invocation JSON per env knobs.
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

STUB_BIN="$TMPROOT/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/aws" <<'EOF'
#!/bin/bash
# Record argv (each on a new line for grep convenience).
printf '%s\n' "$@" >> "$AWS_RECORD_FILE"
# Distinguish send-command from get-command-invocation by argv match.
case "$*" in
  *send-command*)
    if [[ "${AWS_SEND_FAIL:-0}" != "0" ]]; then
      echo "stub aws: send-command failure" >&2
      exit "${AWS_SEND_FAIL:-1}"
    fi
    # AWS_ENFORCE_MIN_TIMEOUT: reproduce the REAL AWS API's ParamValidation
    # rejection for --timeout-seconds < 30 (#369 TC-LSSM-009), instead of
    # the generic AWS_SEND_FAIL failure above.
    if [[ "${AWS_ENFORCE_MIN_TIMEOUT:-0}" != "0" ]]; then
      prev="" ts=""
      for a in "$@"; do
        [[ "$prev" == "--timeout-seconds" ]] && ts="$a"
        prev="$a"
      done
      if [[ "$ts" =~ ^[0-9]+$ ]] && [[ "$ts" -lt 30 ]]; then
        echo "Parameter validation failed: Invalid value for parameter TimeoutSeconds, value: $ts, valid min value: 30" >&2
        exit 255
      fi
    fi
    echo "{\"Command\":{\"CommandId\":\"stub-cmd-1\",\"Status\":\"Pending\"}}"
    ;;
  *get-command-invocation*)
    # Honor AWS_GET_STATUS to drive different terminal states.
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
      *)
        cat <<JSON
{"Status":"Success","StandardOutputContent":"${AWS_GET_STDOUT:-ALIVE}\n","StandardErrorContent":""}
JSON
        ;;
    esac
    ;;
  *)
    echo "stub aws: unexpected subcommand: $*" >&2
    exit 99
    ;;
esac
EOF
chmod +x "$STUB_BIN/aws"

reset_recorder() {
  : > "$TMPROOT/aws-record"
}

# ---------------------------------------------------------------------------
echo "=== TC-LSSM-001: _has_shell_metachar truth table ==="
# ---------------------------------------------------------------------------
# Source the lib once for these direct calls.
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-ssm.sh
source "$LIB"

# Should accept (rc=1):
for safe in "valid" "valid-with-dashes" "valid_with_underscores" "/abs/path/ok" "1234"; do
  if _has_shell_metachar "$safe"; then
    echo -e "  ${RED}FAIL${NC}: _has_shell_metachar incorrectly rejected safe value: '$safe'"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${NC}: _has_shell_metachar accepts '$safe'"
    PASS=$((PASS + 1))
  fi
done

# Should reject (rc=0):
for unsafe in 'has$dollar' 'has`backtick' 'has;semi' 'has&amp' 'has|pipe' 'has<lt' 'has>gt' 'has*star' 'has?q' "has'apos" 'has"quote' $'has\nnewline' $'has\rcret'; do
  if _has_shell_metachar "$unsafe"; then
    echo -e "  ${GREEN}PASS${NC}: _has_shell_metachar rejects unsafe value (one of \$ \` ; & | < > * ? ' \" \\n \\r)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: _has_shell_metachar incorrectly accepted: '$unsafe'"
    FAIL=$((FAIL + 1))
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LSSM-002: _ssm_run_remote_command happy path ==="
# ---------------------------------------------------------------------------
reset_recorder
out=$(
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  AWS_GET_STATUS="Success" \
  AWS_GET_STDOUT="hello-world" \
  bash -c "source '$LIB'; _ssm_run_remote_command i-test ap-southeast-1 'echo hello'"
)
rc=$?
assert_rc "TC-LSSM-002 helper returns 0 on Success" 0 "$rc"
assert_contains "TC-LSSM-002 stdout contains the remote stdout" "hello-world" "$out"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LSSM-003: send-command failure → rc=2 ==="
# ---------------------------------------------------------------------------
reset_recorder
out=$(
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  AWS_SEND_FAIL=1 \
  bash -c "source '$LIB'; _ssm_run_remote_command i-test ap-southeast-1 'echo hi' 2>/dev/null"
)
rc=$?
assert_rc "TC-LSSM-003 helper returns 2 on send-command failure" 2 "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LSSM-004: argv carries --timeout-seconds from env override ==="
# ---------------------------------------------------------------------------
reset_recorder
PATH="$STUB_BIN:$PATH" \
AWS_RECORD_FILE="$TMPROOT/aws-record" \
AWS_GET_STATUS="Success" \
SSM_COMMAND_TIMEOUT_SECONDS=15 \
bash -c "source '$LIB'; _ssm_run_remote_command i-test ap-southeast-1 'echo hi'" >/dev/null
argv=$(cat "$TMPROOT/aws-record")
assert_contains "TC-LSSM-004 argv contains --timeout-seconds 15 (env override)" "--timeout-seconds" "$argv"
assert_contains "TC-LSSM-004 argv carries the override value" "15" "$argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LSSM-005: Status: TimedOut → rc=2 ==="
# ---------------------------------------------------------------------------
reset_recorder
out=$(
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  AWS_GET_STATUS="TimedOut" \
  bash -c "source '$LIB'; _ssm_run_remote_command i-test ap-southeast-1 'echo hi' 2>/dev/null"
)
rc=$?
assert_rc "TC-LSSM-005 helper returns 2 on Status: TimedOut" 2 "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LSSM-006: poll-loop wall-clock cap ==="
# ---------------------------------------------------------------------------
# Stuck InProgress + 1s wall-clock cap → must return 2 within ~2s.
reset_recorder
t0=$(date +%s)
PATH="$STUB_BIN:$PATH" \
AWS_RECORD_FILE="$TMPROOT/aws-record" \
AWS_GET_STATUS="InProgress" \
REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS=1 \
bash -c "source '$LIB'; _ssm_run_remote_command i-test ap-southeast-1 'sleep forever' 2>/dev/null"
rc=$?
t1=$(date +%s)
assert_rc "TC-LSSM-006 helper returns 2 on poll timeout" 2 "$rc"
elapsed=$((t1 - t0))
if [[ "$elapsed" -le 4 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-LSSM-006 wall-clock cap honored (elapsed=${elapsed}s)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-LSSM-006 wall-clock cap not honored (elapsed=${elapsed}s, expected <=4s)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LSSM-007: default cmd_timeout (env unset) is >= 30 (#369) ==="
# ---------------------------------------------------------------------------
# AWS ssm send-command's hard API minimum for --timeout-seconds is 30; the
# prior default of 10 guaranteed a transport-side ParamValidation rejection
# on every unset-env call. This is the unset-env default path.
reset_recorder
PATH="$STUB_BIN:$PATH" \
AWS_RECORD_FILE="$TMPROOT/aws-record" \
AWS_GET_STATUS="Success" \
bash -c "unset SSM_COMMAND_TIMEOUT_SECONDS; source '$LIB'; _ssm_run_remote_command i-test ap-southeast-1 'echo hi'" >/dev/null
argv=$(cat "$TMPROOT/aws-record")
assert_contains "TC-LSSM-007 default --timeout-seconds is >= 30 (unset-env path)" $'--timeout-seconds\n30' "$argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LSSM-008: non-numeric SSM_COMMAND_TIMEOUT_SECONDS guard fallback is >= 30 (#369) ==="
# ---------------------------------------------------------------------------
# lib-ssm.sh:80's non-numeric guard has its OWN literal fallback, separate
# from the unset-env default on line 78. Both must be >= 30 or a garbage
# env value still produces the rejected value.
reset_recorder
PATH="$STUB_BIN:$PATH" \
AWS_RECORD_FILE="$TMPROOT/aws-record" \
AWS_GET_STATUS="Success" \
SSM_COMMAND_TIMEOUT_SECONDS="not-a-number" \
bash -c "source '$LIB'; _ssm_run_remote_command i-test ap-southeast-1 'echo hi'" >/dev/null
argv=$(cat "$TMPROOT/aws-record")
assert_contains "TC-LSSM-008 non-numeric-guard fallback --timeout-seconds is >= 30" $'--timeout-seconds\n30' "$argv"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LSSM-009: stubbed real AWS ParamValidation rejection for --timeout-seconds < 30 ==="
# ---------------------------------------------------------------------------
# Reproduces the ACTUAL AWS CLI rejection observed in #369 (ParamValidation:
# valid min value: 30) via the shared stub's AWS_ENFORCE_MIN_TIMEOUT knob,
# rather than a generic AWS_SEND_FAIL failure, and proves the fixed default
# (unset env) never hits it.
reset_recorder
rc_default=$(
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  AWS_ENFORCE_MIN_TIMEOUT=1 \
  bash -c "unset SSM_COMMAND_TIMEOUT_SECONDS; source '$LIB'; _ssm_run_remote_command i-test ap-southeast-1 'echo hi'" \
  >/dev/null 2>"$TMPROOT/stderr-default"
  echo $?
)
assert_rc "TC-LSSM-009 fixed default (unset env) avoids the real ParamValidation rejection" 0 "$rc_default"
stderr_default=$(cat "$TMPROOT/stderr-default")
if [[ "$stderr_default" != *"ParamValidation"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-LSSM-009 fixed-default stderr does not mention ParamValidation"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-LSSM-009 fixed-default stderr unexpectedly mentions ParamValidation: $stderr_default"
  FAIL=$((FAIL + 1))
fi

# Demonstrate the OLD (pre-fix) value of 10 DOES reproduce the real rejection
# against this same stub, proving the stub faithfully models the AWS API and
# that this test would have failed before the fix.
reset_recorder
rc_pre_fix=$(
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  AWS_ENFORCE_MIN_TIMEOUT=1 \
  SSM_COMMAND_TIMEOUT_SECONDS=10 \
  bash -c "source '$LIB'; _ssm_run_remote_command i-test ap-southeast-1 'echo hi'" \
  >/dev/null 2>"$TMPROOT/stderr-prefix"
  echo $?
)
assert_rc "TC-LSSM-009 pre-fix value (10) DOES hit the real ParamValidation rejection (proves the stub is faithful)" 2 "$rc_pre_fix"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LSSM-010: inherited/exported _SSM_MIN_COMMAND_TIMEOUT_SECONDS below 30 does NOT win (2026-07-03 review) ==="
# ---------------------------------------------------------------------------
# codex review finding: if _SSM_MIN_COMMAND_TIMEOUT_SECONDS were defined via
# `: "${_SSM_MIN_COMMAND_TIMEOUT_SECONDS:=30}"` (default-if-unset), an
# inherited/exported value from the caller's environment (e.g. a stale
# `export _SSM_MIN_COMMAND_TIMEOUT_SECONDS=20` left over from a prior shell)
# would win over the constant, silently recreating #369's rejection. The
# constant must be a PLAIN assignment so sourcing lib-ssm.sh always resets it
# to 30 regardless of what the environment carries in.
reset_recorder
PATH="$STUB_BIN:$PATH" \
AWS_RECORD_FILE="$TMPROOT/aws-record" \
AWS_GET_STATUS="Success" \
_SSM_MIN_COMMAND_TIMEOUT_SECONDS=20 \
bash -c "unset SSM_COMMAND_TIMEOUT_SECONDS; source '$LIB'; _ssm_run_remote_command i-test ap-southeast-1 'echo hi'" >/dev/null
argv=$(cat "$TMPROOT/aws-record")
assert_contains "TC-LSSM-010 inherited _SSM_MIN_COMMAND_TIMEOUT_SECONDS=20 does not lower --timeout-seconds below 30" $'--timeout-seconds\n30' "$argv"

echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] || exit 1
