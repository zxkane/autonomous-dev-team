#!/bin/bash
# test-dispatch-remote-aws-ssm.sh — Unit tests for the SSM transport driver
# added in PR-9 (closes #62 axis 2).
#
# Strategy: stub `aws` and `jq` selectively, capture argv to a record file,
# and assert on the constructed remote command shape + JSON escaping path.
#
# Run: bash tests/unit/test-dispatch-remote-aws-ssm.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DRIVER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatch-remote-aws-ssm.sh"

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
    echo "      haystack='$haystack'"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      should NOT contain: '$needle'"
    echo "      haystack='$haystack'"
    FAIL=$((FAIL + 1))
  fi
}

# Sandbox: stub `aws` to record argv; jq stays real.
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

STUB_BIN="$TMPROOT/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/aws" <<'EOF'
#!/bin/bash
# Record full argv to AWS_RECORD_FILE; emit a fake send-command JSON.
printf '%s\n' "$@" >> "$AWS_RECORD_FILE"
exitcode="${AWS_FAIL_RC:-0}"
if [[ "$exitcode" != "0" ]]; then
  echo "stub aws: simulated failure" >&2
  exit "$exitcode"
fi
echo '{"Command":{"CommandId":"abc-stub","Status":"Pending"}}'
EOF
chmod +x "$STUB_BIN/aws"
export PATH="$STUB_BIN:$PATH"

run_driver() {
  AWS_RECORD_FILE="$TMPROOT/aws-record" \
  bash "$DRIVER" "$@"
}

# ---------------------------------------------------------------------------
echo "=== TC-EB-005: dispatch-remote-aws-ssm.sh requires SSM_INSTANCE_ID ==="
# ---------------------------------------------------------------------------
: > "$TMPROOT/aws-record"
unset SSM_INSTANCE_ID
export SSM_REMOTE_PROJECT_DIR=/data/git/test SSM_REMOTE_PROJECT_ID=test
err=$(run_driver dev-new 99 2>&1 >/dev/null)
rc=$?
assert_rc "rc=1 when SSM_INSTANCE_ID unset" 1 "$rc"
assert_contains "stderr names SSM_INSTANCE_ID" "SSM_INSTANCE_ID" "$err"
[[ ! -s "$TMPROOT/aws-record" ]] && {
  echo -e "  ${GREEN}PASS${NC}: aws was NOT invoked"
  PASS=$((PASS + 1))
} || {
  echo -e "  ${RED}FAIL${NC}: aws was invoked despite missing SSM_INSTANCE_ID"
  FAIL=$((FAIL + 1))
}

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-006: requires SSM_REMOTE_PROJECT_DIR / _PROJECT_ID ==="
# ---------------------------------------------------------------------------
export SSM_INSTANCE_ID=i-test
unset SSM_REMOTE_PROJECT_DIR
err=$(run_driver dev-new 99 2>&1 >/dev/null)
rc=$?
assert_rc "rc=1 when SSM_REMOTE_PROJECT_DIR unset" 1 "$rc"
assert_contains "stderr names SSM_REMOTE_PROJECT_DIR" "SSM_REMOTE_PROJECT_DIR" "$err"

export SSM_REMOTE_PROJECT_DIR=/data/git/test
unset SSM_REMOTE_PROJECT_ID
err=$(run_driver dev-new 99 2>&1 >/dev/null)
rc=$?
assert_rc "rc=1 when SSM_REMOTE_PROJECT_ID unset" 1 "$rc"

# Reset to valid
export SSM_REMOTE_PROJECT_ID=test

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-007: input + env validation rejects unsafe values ==="
# ---------------------------------------------------------------------------
run_driver dev-new abc >/dev/null 2>&1
assert_rc "non-numeric issue → rc=1" 1 "$?"

run_driver dev-resume 99 'bad;chars' >/dev/null 2>&1
assert_rc "session_id with semicolons → rc=1" 1 "$?"

# Each invalid-env case runs in a subshell so the bad value doesn't leak to
# subsequent tests.
( export SSM_REMOTE_PROJECT_ID='with/slash'; run_driver dev-new 99 ) >/dev/null 2>&1
assert_rc "SSM_REMOTE_PROJECT_ID with slash → rc=1" 1 "$?"

( export SSM_REMOTE_PROJECT_DIR='/data/git/$(rm -rf /)'; run_driver dev-new 99 ) >/dev/null 2>&1
assert_rc "SSM_REMOTE_PROJECT_DIR with command-substitution shape → rc=1" 1 "$?"

( export SSM_REMOTE_PROJECT_DIR='relative/path'; run_driver dev-new 99 ) >/dev/null 2>&1
assert_rc "SSM_REMOTE_PROJECT_DIR not absolute → rc=1" 1 "$?"

( export SSM_REMOTE_USER='bad;user'; run_driver dev-new 99 ) >/dev/null 2>&1
assert_rc "SSM_REMOTE_USER with semicolon → rc=1" 1 "$?"

( export SSM_REMOTE_SHELL='/bin/csh'; run_driver dev-new 99 ) >/dev/null 2>&1
assert_rc "SSM_REMOTE_SHELL not in allow-list → rc=1" 1 "$?"

# ---------------------------------------------------------------------------
# PR-9 review C1 + C2: shell metachars must be rejected on every operator-
# controlled value embedded in INNER_CMD. The prior validator missed `'`,
# `"`, `<`, `>`, `\n` — these break out of the
# `sudo -u $USER $SHELL -l -c '<INNER_CMD>'` single-quote wrap on the
# remote side.
# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-007c: C1 — single-quote in SSM_REMOTE_PROJECT_DIR rejected ==="
( export SSM_REMOTE_PROJECT_DIR="/data/git/foo' >/tmp/PWNED '"; run_driver dev-new 99 ) >/dev/null 2>&1
assert_rc "single-quote in SSM_REMOTE_PROJECT_DIR → rc=1" 1 "$?"

( export SSM_REMOTE_PROJECT_DIR='/data/git/foo<bar'; run_driver dev-new 99 ) >/dev/null 2>&1
assert_rc "redirect-char in SSM_REMOTE_PROJECT_DIR → rc=1" 1 "$?"

( export SSM_REMOTE_PROJECT_DIR='/data/git/foo*'; run_driver dev-new 99 ) >/dev/null 2>&1
assert_rc "glob-char in SSM_REMOTE_PROJECT_DIR → rc=1" 1 "$?"

newline_value=$'/data/git/foo\nrm -rf /'
( export SSM_REMOTE_PROJECT_DIR="$newline_value"; run_driver dev-new 99 ) >/dev/null 2>&1
assert_rc "newline in SSM_REMOTE_PROJECT_DIR → rc=1" 1 "$?"

echo ""
echo "=== TC-EB-009b: C2 — SSM_REMOTE_PROFILE metachar gate ==="
( export SSM_REMOTE_PROFILE="/etc/foo'; touch /tmp/PWNED; '"; run_driver dev-new 99 ) >/dev/null 2>&1
assert_rc "single-quote in SSM_REMOTE_PROFILE → rc=1" 1 "$?"

( export SSM_REMOTE_PROFILE='/etc/foo$(rm -rf /)'; run_driver dev-new 99 ) >/dev/null 2>&1
assert_rc "command-substitution in SSM_REMOTE_PROFILE → rc=1" 1 "$?"

newline_profile=$'/etc/foo\nrm -rf /'
( export SSM_REMOTE_PROFILE="$newline_profile"; run_driver dev-new 99 ) >/dev/null 2>&1
assert_rc "newline in SSM_REMOTE_PROFILE → rc=1" 1 "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-008: defaults applied when optional env unset ==="
# ---------------------------------------------------------------------------
: > "$TMPROOT/aws-record"
unset SSM_REGION SSM_REMOTE_USER SSM_REMOTE_SHELL SSM_REMOTE_PROFILE
run_driver dev-new 99 >/dev/null 2>&1
assert_rc "happy path → rc=0" 0 "$?"
record=$(cat "$TMPROOT/aws-record")
assert_contains "default SSM_REGION ap-southeast-1 reaches aws" "ap-southeast-1" "$record"
# INNER_CMD shape ends up inside the JSON parameters; capture it via grep.
assert_contains "default user=ubuntu in INNER_CMD" "sudo -u ubuntu" "$record"
assert_contains "default shell=bash with -l in INNER_CMD" "bash -l" "$record"
assert_not_contains "no profile source when SSM_REMOTE_PROFILE empty" "source /home" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-009: SSM_REMOTE_PROFILE prepends source ==="
# ---------------------------------------------------------------------------
: > "$TMPROOT/aws-record"
( export SSM_REMOTE_PROFILE=/home/ubuntu/.bash_aliases; run_driver dev-new 99 >/dev/null 2>&1 )
record=$(cat "$TMPROOT/aws-record")
assert_contains "INNER_CMD has 'source /home/ubuntu/.bash_aliases;'" "source /home/ubuntu/.bash_aliases;" "$record"

# Non-absolute SSM_REMOTE_PROFILE is rejected
( export SSM_REMOTE_PROFILE='.bash_aliases'; run_driver dev-new 99 >/dev/null 2>&1 )
assert_rc "relative SSM_REMOTE_PROFILE → rc=1" 1 "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-010: source-of-truth — jq -n --arg cmd is used (CWE-78) ==="
# ---------------------------------------------------------------------------
if grep -q 'jq -n --arg cmd' "$DRIVER"; then
  echo -e "  ${GREEN}PASS${NC}: driver uses jq -n --arg for JSON construction"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: jq -n --arg cmd missing — possible shell-injection regression"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-011: aws failure propagates ==="
# ---------------------------------------------------------------------------
: > "$TMPROOT/aws-record"
err=$(AWS_FAIL_RC=2 AWS_RECORD_FILE="$TMPROOT/aws-record" bash "$DRIVER" dev-new 99 2>&1 >/dev/null)
rc=$?
[ "$rc" -ne 0 ] && {
  echo -e "  ${GREEN}PASS${NC}: aws rc=2 → driver rc != 0"
  PASS=$((PASS + 1))
} || {
  echo -e "  ${RED}FAIL${NC}: driver should propagate aws failure"
  FAIL=$((FAIL + 1))
}
assert_contains "stderr names instance ID" "$SSM_INSTANCE_ID" "$err"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-007b: dev-resume requires session_id (run before PATH test) ==="
# ---------------------------------------------------------------------------
err=$(run_driver dev-resume 99 2>&1 >/dev/null)
assert_rc "dev-resume without session_id → rc=1" 1 "$?"
assert_contains "stderr names session_id" "session_id" "$err"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-012: missing aws / jq → rc=1 ==="
# ---------------------------------------------------------------------------
# Run in a subshell with PATH pointing to a dir that contains real bash
# but no aws/jq, so the driver's `command -v aws` returns false. Use
# /usr/sbin only (where bash is reachable on Ubuntu via /bin → /usr/bin
# but not aws). Actually the safest is: leave only the dir with bash and
# nothing else.
EMPTY_BIN="$TMPROOT/empty-bin"
mkdir -p "$EMPTY_BIN"
cp /usr/bin/bash "$EMPTY_BIN/bash" 2>/dev/null || cp /bin/bash "$EMPTY_BIN/bash"
err=$(PATH="$EMPTY_BIN" bash "$DRIVER" dev-new 99 2>&1 >/dev/null)
rc=$?
assert_rc "missing aws on PATH → rc=1" 1 "$rc"
case "$err" in
  *"not found in PATH"*)
    echo -e "  ${GREEN}PASS${NC}: stderr names missing dep"
    PASS=$((PASS + 1)) ;;
  *)
    echo -e "  ${RED}FAIL${NC}: expected 'not found in PATH' in stderr; got: $err"
    FAIL=$((FAIL + 1)) ;;
esac

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
