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
    # AWS_ENFORCE_MIN_TIMEOUT: mirrors test-lib-ssm.sh's stub (#369
    # TC-LSSM-009) so the driver-level regression (TC-LCS-012) can
    # reproduce the REAL AWS send-command ParamValidation rejection for
    # --timeout-seconds < 30, through the actual entrypoint script instead
    # of only the lib-ssm.sh helper.
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
# [#454] FULL_CMD no longer interpolates INNER_CMD verbatim inside the outer
# single-quote wrap — it base64-encodes it (via _ssm_build_full_cmd,
# lib-ssm.sh) and decodes+evals it remotely. So the kind/issue-number/PID-
# file-derivation assertions below must decode that payload first, rather
# than grepping the raw argv for JSON-escaped literal text.
b64_payload=$(printf '%s' "$argv" | grep -oE 'printf %s [A-Za-z0-9+/=]+ \| base64 -d' | sed -E 's/^printf %s //; s/ \| base64 -d$//')
decoded_inner=$(printf '%s' "$b64_payload" | base64 -d)
assert_contains "TC-LCS-010 remote inner-cmd carries KIND=\"issue\"" 'KIND="issue"' "$decoded_inner"
assert_contains "TC-LCS-010 remote inner-cmd carries N=\"99\"" 'N="99"' "$decoded_inner"
assert_contains "TC-LCS-010 remote inner-cmd derives PID file via \${KIND}-\${N}.pid" '${KIND}-${N}.pid' "$decoded_inner"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LCS-011: argv carries --timeout-seconds 30 by default (#369) ==="
# ---------------------------------------------------------------------------
reset_recorder
PATH="$STUB_BIN:$PATH" \
AWS_RECORD_FILE="$TMPROOT/aws-record" \
AWS_GET_STATUS="Success" \
AWS_GET_STDOUT="ALIVE" \
bash "$DRIVER" issue 99 >/dev/null 2>&1
argv=$(cat "$TMPROOT/aws-record")
assert_contains "TC-LCS-011 argv contains --timeout-seconds" "--timeout-seconds" "$argv"
# 30 is AWS ssm send-command's hard API minimum for --timeout-seconds
# (#369); the prior default of 10 was rejected transport-side on every
# unset-env call (ParamValidation: valid min value: 30).
assert_contains "TC-LCS-011 default timeout value is 30" $'--timeout-seconds\n30' "$argv"

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

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LCS-012: driver-level fixture reproduces the real ParamValidation rejection (#369 review) ==="
# ---------------------------------------------------------------------------
# TC-LSSM-009 (test-lib-ssm.sh) already proves this at the lib-ssm.sh helper
# level; this reproduces it through the ACTUAL remote-aws-ssm driver
# entrypoint (liveness-check-remote-aws-ssm.sh), per the 2026-07-03 review
# finding that only the helper-level regression existed.
reset_recorder
stdout_default=$(
  PATH="$STUB_BIN:$PATH" \
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  AWS_ENFORCE_MIN_TIMEOUT=1 \
  bash "$DRIVER" issue 99 2>"$TMPROOT/stderr-driver-default"
)
rc_default=$?
assert_rc "TC-LCS-012 fixed default (unset env) avoids the real ParamValidation rejection through the driver" 0 "$rc_default"
assert_eq "TC-LCS-012 fixed-default driver still returns a definitive verdict (ALIVE)" "ALIVE" "$stdout_default"
stderr_default=$(cat "$TMPROOT/stderr-driver-default")
if [[ "$stderr_default" != *"ParamValidation"* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-LCS-012 fixed-default driver stderr does not mention ParamValidation"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-LCS-012 fixed-default driver stderr unexpectedly mentions ParamValidation: $stderr_default"
  FAIL=$((FAIL + 1))
fi

# Demonstrate the OLD (pre-fix) value of 10 DOES reproduce the real
# rejection through the same driver entrypoint, proving this test would
# have failed before the fix.
reset_recorder
PATH="$STUB_BIN:$PATH" \
AWS_RECORD_FILE="$TMPROOT/aws-record" \
AWS_ENFORCE_MIN_TIMEOUT=1 \
SSM_COMMAND_TIMEOUT_SECONDS=10 \
bash "$DRIVER" issue 99 >/dev/null 2>/dev/null
rc_pre_fix=$?
assert_rc "TC-LCS-012 pre-fix value (10) DOES hit the real ParamValidation rejection through the driver (proves the fixture is faithful)" 2 "$rc_pre_fix"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LCS-013: FULL_CMD sent to SSM is syntactically balanced (#454) ==="
# ---------------------------------------------------------------------------
# #454: b6bf6fa's Lane-GC PR-6 heredoc comment ("...THIS run's own defer...")
# contains a literal apostrophe. Extract the EXACT `commands[0]` string the
# driver hands to `aws ssm send-command` and prove it round-trips through
# `bash -n` cleanly — the same check that, against the pre-fix construction
# (INNER_CMD interpolated verbatim inside the outer single-quote wrap),
# fails with "Unterminated quoted string" on 100% of invocations.
LIB_SSM="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-ssm.sh"
reset_recorder
PATH="$STUB_BIN:$PATH" \
AWS_RECORD_FILE="$TMPROOT/aws-record" \
AWS_GET_STATUS="Success" \
AWS_GET_STDOUT="ALIVE" \
bash "$DRIVER" issue 99 >/dev/null 2>&1
# The recorded --parameters argv element is itself multi-line (it embeds
# the whole INNER_CMD heredoc's newlines) and is followed by a fixed
# `--output` / `json` pair the stub always appends last — grab everything
# between the `--parameters` marker line and that trailing pair.
params_json=$(awk '
  found && /^--output$/ { exit }
  found { print }
  /^--parameters$/ { found=1; next }
' "$TMPROOT/aws-record")
full_cmd=$(printf '%s' "$params_json" | jq -r '.commands[0]')
printf '%s' "$full_cmd" > "$TMPROOT/full_cmd_013.sh"
if bash -n "$TMPROOT/full_cmd_013.sh" 2>"$TMPROOT/full_cmd_013.err"; then
  echo -e "  ${GREEN}PASS${NC}: TC-LCS-013 captured FULL_CMD parses cleanly under bash -n"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-LCS-013 captured FULL_CMD is syntactically broken: $(cat "$TMPROOT/full_cmd_013.err")"
  FAIL=$((FAIL + 1))
fi

# Fidelity check: reconstruct what FULL_CMD would have been under the
# PRE-FIX construction (INNER_CMD interpolated verbatim inside the outer
# single-quote wrap) using the SAME real INNER_CMD text (decoded from the
# base64 payload the fixed driver actually sent) and prove THAT string is
# NOT syntactically balanced — i.e. this test would have failed against
# main before the fix, reproducing the exact "Unterminated quoted string"
# class of bug rather than testing a strawman.
b64_payload=$(printf '%s' "$full_cmd" | grep -oE 'printf %s [A-Za-z0-9+/=]+ \| base64 -d' | sed -E 's/^printf %s //; s/ \| base64 -d$//')
real_inner_cmd=$(printf '%s' "$b64_payload" | base64 -d)
pre_fix_full_cmd="sudo -u ubuntu bash -l -c '${real_inner_cmd}'"
printf '%s' "$pre_fix_full_cmd" > "$TMPROOT/full_cmd_013_prefix.sh"
if bash -n "$TMPROOT/full_cmd_013_prefix.sh" 2>/dev/null; then
  echo -e "  ${RED}FAIL${NC}: TC-LCS-013 pre-fix reconstruction unexpectedly parses cleanly (fixture not faithful — apostrophe missing from real INNER_CMD?)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-LCS-013 pre-fix reconstruction (naive interpolation of the SAME real INNER_CMD) DOES hit the syntax error, proving this test is a faithful regression check"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LCS-014: no unescaped ' reaches the outer FULL_CMD wrap (#454 structural guard) ==="
# ---------------------------------------------------------------------------
# The base64 alphabet is [A-Za-z0-9+/=] only, so once INNER_CMD is
# transported through _ssm_build_full_cmd, FULL_CMD can contain exactly the
# TWO single quotes that delimit the outer `-c '...'` argument — never a
# third one contributed by INNER_CMD's own content. Count them directly on
# the real captured FULL_CMD.
quote_count=$(printf '%s' "$full_cmd" | tr -dc "'" | wc -c)
assert_eq "TC-LCS-014 FULL_CMD contains exactly 2 single quotes (the outer -c delimiters, nothing from INNER_CMD)" "2" "$quote_count"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LCS-015: structural guard survives a FUTURE apostrophe reintroduced into the heredoc (#454, reproduces b6bf6fa) ==="
# ---------------------------------------------------------------------------
# This is the regression the issue asks for by name: prove that re-adding a
# comment containing a literal apostrophe inside the INNER_CMD heredoc body
# — exactly what b6bf6fa did — cannot reintroduce the bug, because the fix
# is structural (base64 transport), not a one-off character removal from
# today's specific comment. Drive lib-ssm.sh's _ssm_build_full_cmd (the
# REAL function the driver calls) directly with a synthetic INNER_CMD that
# reintroduces the apostrophe pattern, and prove the result still parses.
# shellcheck source=/dev/null
source "$LIB_SSM"
regressed_inner_cmd=$(cat <<'INNEREOF'
set -u
# a brand-new hypothetical comment about THIS run's own state, added long
# after this fix shipped, containing a fresh apostrophe
echo DEAD
INNEREOF
)
if ! declare -F _ssm_build_full_cmd >/dev/null; then
  echo -e "  ${RED}FAIL${NC}: TC-LCS-015 _ssm_build_full_cmd is not defined after sourcing lib-ssm.sh — cannot exercise the structural guard"
  FAIL=$((FAIL + 1))
else
  regressed_full_cmd=$(_ssm_build_full_cmd "ubuntu" "bash" "$regressed_inner_cmd")
  if [[ -z "$regressed_full_cmd" ]]; then
    echo -e "  ${RED}FAIL${NC}: TC-LCS-015 _ssm_build_full_cmd produced empty output — cannot exercise the structural guard"
    FAIL=$((FAIL + 1))
  else
    printf '%s' "$regressed_full_cmd" > "$TMPROOT/full_cmd_015.sh"
    if bash -n "$TMPROOT/full_cmd_015.sh" 2>"$TMPROOT/full_cmd_015.err"; then
      echo -e "  ${GREEN}PASS${NC}: TC-LCS-015 a freshly reintroduced heredoc apostrophe still produces a syntactically balanced FULL_CMD"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${NC}: TC-LCS-015 structural guard failed to protect against a reintroduced apostrophe: $(cat "$TMPROOT/full_cmd_015.err")"
      FAIL=$((FAIL + 1))
    fi
  fi
fi

# Negative control: prove the SAME synthetic apostrophe-laden INNER_CMD
# WOULD break the pre-fix (naive-interpolation) construction — i.e. this
# guard is exercising a real hazard, not a no-op.
regressed_pre_fix_full_cmd="sudo -u ubuntu bash -l -c '${regressed_inner_cmd}'"
printf '%s' "$regressed_pre_fix_full_cmd" > "$TMPROOT/full_cmd_015_prefix.sh"
if bash -n "$TMPROOT/full_cmd_015_prefix.sh" 2>/dev/null; then
  echo -e "  ${RED}FAIL${NC}: TC-LCS-015 negative control unexpectedly parses cleanly (synthetic fixture not faithful)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-LCS-015 negative control confirms the SAME apostrophe DOES break naive interpolation (guard is meaningful)"
  PASS=$((PASS + 1))
fi

echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] || exit 1
