#!/bin/bash
# test-multi-tick-inline-projects.sh — Verify dispatcher-multi-tick.sh
# handles inline metadata blocks for remote projects (PR-9, #62 axis 2)
# while preserving PR-8's path-string behavior for local projects.
#
# Strategy: stub dispatcher-tick.sh to record its env (in particular
# REPO, REPO_OWNER, REPO_NAME, EXECUTION_BACKEND, SSM_*) and AUTONOMOUS_CONF.
# Run multi-tick against various PROJECTS shapes.
#
# Run: bash tests/unit/test-multi-tick-inline-projects.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER_SRC="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-multi-tick.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

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
    FAIL=$((FAIL + 1))
  fi
}

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

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
SANDBOX="$TMPROOT/scripts"
mkdir -p "$SANDBOX"
cp "$WRAPPER_SRC" "$SANDBOX/dispatcher-multi-tick.sh"

# Stub dispatcher-tick.sh records relevant env to a sentinel file. For
# local projects, we source AUTONOMOUS_CONF first to mirror what the real
# dispatcher-tick.sh does via lib-config.sh — without that, the stub would
# see REPO=<unset> for local entries and the test wouldn't reflect real flow.
cat > "$SANDBOX/dispatcher-tick.sh" <<'EOF'
#!/bin/bash
# Mirror lib-config.sh::load_autonomous_conf priority-1 behavior.
if [[ -n "${AUTONOMOUS_CONF:-}" ]] && [[ -f "$AUTONOMOUS_CONF" ]]; then
  # shellcheck disable=SC1090
  source "$AUTONOMOUS_CONF"
fi
{
  printf 'AUTONOMOUS_CONF=%s\n' "${AUTONOMOUS_CONF:-<unset>}"
  printf 'REPO=%s\n' "${REPO:-<unset>}"
  printf 'REPO_OWNER=%s\n' "${REPO_OWNER:-<unset>}"
  printf 'REPO_NAME=%s\n' "${REPO_NAME:-<unset>}"
  printf 'PROJECT_ID=%s\n' "${PROJECT_ID:-<unset>}"
  printf 'EXECUTION_BACKEND=%s\n' "${EXECUTION_BACKEND:-<unset>}"
  printf 'SSM_INSTANCE_ID=%s\n' "${SSM_INSTANCE_ID:-<unset>}"
  printf 'SSM_REMOTE_PROJECT_DIR=%s\n' "${SSM_REMOTE_PROJECT_DIR:-<unset>}"
  printf '%s\n' '---'
} >> "$TICK_RECORD_FILE"
exit 0
EOF
chmod +x "$SANDBOX/dispatcher-tick.sh"

# AUTONOMOUS_TRUST_CONF=1 because /tmp is mode 1777 (PR-8 trust gate)
export AUTONOMOUS_TRUST_CONF=1

# ---------------------------------------------------------------------------
echo "=== TC-EB-013/014: inline block — REPO_OWNER/_NAME auto-derived ==="
# ---------------------------------------------------------------------------
CONF="$TMPROOT/disp-013.conf"
RECORD="$TMPROOT/record-013"
: > "$RECORD"
cat > "$CONF" <<'EOF'
PROJECTS=()
PROJECTS+=( '
PROJECT_ID=projB
REPO=myorg/projB
EXECUTION_BACKEND=remote-aws-ssm
SSM_INSTANCE_ID=i-0abc123
SSM_REMOTE_PROJECT_DIR=/data/git/projB
SSM_REMOTE_PROJECT_ID=projB
' )
EOF

DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
rc=$?
assert_rc "rc=0 for happy-path inline project" 0 "$rc"
record=$(cat "$RECORD")
assert_contains "REPO propagated" "REPO=myorg/projB" "$record"
assert_contains "REPO_OWNER auto-derived" "REPO_OWNER=myorg" "$record"
assert_contains "REPO_NAME auto-derived" "REPO_NAME=projB" "$record"
assert_contains "PROJECT_ID propagated" "PROJECT_ID=projB" "$record"
assert_contains "EXECUTION_BACKEND propagated" "EXECUTION_BACKEND=remote-aws-ssm" "$record"
assert_contains "SSM_INSTANCE_ID propagated" "SSM_INSTANCE_ID=i-0abc123" "$record"
assert_contains "AUTONOMOUS_CONF unset for inline" "AUTONOMOUS_CONF=<unset>" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-015: inline block with non-assignment line is rejected ==="
# ---------------------------------------------------------------------------
CONF="$TMPROOT/disp-015.conf"
RECORD="$TMPROOT/record-015"
: > "$RECORD"
cat > "$CONF" <<'EOF'
PROJECTS=()
PROJECTS+=( '
PROJECT_ID=mal
REPO=evil/repo
rm -rf /
' )
EOF
stderr_log="$TMPROOT/stderr-015"
DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>"$stderr_log"
rc=$?
assert_rc "rc=0 (per-project failure isolation)" 0 "$rc"
case "$(cat "$stderr_log")" in
  *"non-assignment lines"*)
    echo -e "  ${GREEN}PASS${NC}: stderr explains the validator rejection"
    PASS=$((PASS + 1)) ;;
  *)
    echo -e "  ${RED}FAIL${NC}: expected 'non-assignment lines' in stderr"
    FAIL=$((FAIL + 1)) ;;
esac
# Stub should NOT have been invoked (validator caught the bad block)
[ ! -s "$RECORD" ] && {
  echo -e "  ${GREEN}PASS${NC}: stub was NOT invoked for malformed block"
  PASS=$((PASS + 1))
} || {
  echo -e "  ${RED}FAIL${NC}: stub was invoked despite malformed block"
  FAIL=$((FAIL + 1))
}

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-015b: Q PR-80 — value-side metachars rejected (CWE-95) ==="
# ---------------------------------------------------------------------------
# Q's finding: pre-fix, validator only checked LHS, so values like
# `REPO=$(rm -rf /)` would pass validation and execute on eval.
for badval in \
  'REPO=$(echo PWNED)' \
  'REPO=`echo PWNED`' \
  'REPO=foo;rm -rf /' \
  'REPO=foo&&evil' \
  'REPO=foo|evil' \
  'REPO=foo$VAR' \
  'REPO=foo\nnewlinetrick' ; do
  CONF="$TMPROOT/disp-015b.conf"
  RECORD="$TMPROOT/record-015b"
  : > "$RECORD"
  printf 'PROJECTS=()\nPROJECTS+=( '\''\nPROJECT_ID=test\n%s\nEXECUTION_BACKEND=remote-aws-ssm\nSSM_INSTANCE_ID=i-x\nSSM_REMOTE_PROJECT_DIR=/data/test\nSSM_REMOTE_PROJECT_ID=test\n'\'' )\n' "$badval" > "$CONF"
  stderr_log="$TMPROOT/stderr-015b"
  DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
    bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>"$stderr_log"
  rc=$?
  if [ "$rc" -eq 0 ] && [ ! -s "$RECORD" ]; then
    echo -e "  ${GREEN}PASS${NC}: rejected metachar value: $badval"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: did NOT reject: $badval (rc=$rc, record=$(wc -l <"$RECORD"))"
    FAIL=$((FAIL + 1))
  fi
done

# Sanity: a legitimate value WITHOUT metachars must still pass.
CONF="$TMPROOT/disp-015c.conf"
RECORD="$TMPROOT/record-015c"
: > "$RECORD"
cat > "$CONF" <<'EOF'
PROJECTS=()
PROJECTS+=( '
PROJECT_ID=projB
REPO=myorg/projB
EXECUTION_BACKEND=remote-aws-ssm
SSM_INSTANCE_ID=i-0abc123
SSM_REMOTE_PROJECT_DIR=/data/git/projB
SSM_REMOTE_PROJECT_ID=projB
' )
EOF
DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
[ -s "$RECORD" ] && {
  echo -e "  ${GREEN}PASS${NC}: legitimate metachar-free values still accepted"
  PASS=$((PASS + 1))
} || {
  echo -e "  ${RED}FAIL${NC}: legitimate values were rejected — validator too strict"
  FAIL=$((FAIL + 1))
}

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-016: inline block missing REPO → warn-and-skip ==="
# ---------------------------------------------------------------------------
CONF="$TMPROOT/disp-016.conf"
RECORD="$TMPROOT/record-016"
: > "$RECORD"
cat > "$CONF" <<'EOF'
PROJECTS=()
PROJECTS+=( '
PROJECT_ID=projX
EXECUTION_BACKEND=remote-aws-ssm
SSM_INSTANCE_ID=i-empty
SSM_REMOTE_PROJECT_DIR=/data/git/projX
SSM_REMOTE_PROJECT_ID=projX
' )
EOF
stderr_log="$TMPROOT/stderr-016"
DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>"$stderr_log"
rc=$?
assert_rc "rc=0 even with missing-REPO inline project" 0 "$rc"
[ ! -s "$RECORD" ] && {
  echo -e "  ${GREEN}PASS${NC}: stub NOT invoked for missing-REPO project"
  PASS=$((PASS + 1))
} || {
  echo -e "  ${RED}FAIL${NC}: stub was invoked despite missing REPO"
  FAIL=$((FAIL + 1))
}

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-017: mixed local + remote projects in one PROJECTS array ==="
# ---------------------------------------------------------------------------
LOCAL_CONF="$TMPROOT/local-autoconf.conf"
cat > "$LOCAL_CONF" <<'EOF'
REPO=myorg/local-proj
REPO_OWNER=myorg
REPO_NAME=local-proj
PROJECT_ID=local-proj
PROJECT_DIR=/tmp/local-proj
EOF

CONF="$TMPROOT/disp-017.conf"
RECORD="$TMPROOT/record-017"
: > "$RECORD"
{
  echo 'PROJECTS=()'
  printf 'PROJECTS+=( %q )\n' "$LOCAL_CONF"
  echo "PROJECTS+=( '"
  echo 'PROJECT_ID=remote-proj'
  echo 'REPO=myorg/remote-proj'
  echo 'EXECUTION_BACKEND=remote-aws-ssm'
  echo 'SSM_INSTANCE_ID=i-mix'
  echo 'SSM_REMOTE_PROJECT_DIR=/data/git/remote-proj'
  echo 'SSM_REMOTE_PROJECT_ID=remote-proj'
  echo "' )"
} > "$CONF"

DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
rc=$?
assert_rc "rc=0 for mixed projects" 0 "$rc"
record=$(cat "$RECORD")
# Two ticks recorded — separated by '---'.
tick_count=$(grep -c '^---$' "$RECORD")
[ "$tick_count" = "2" ] && {
  echo -e "  ${GREEN}PASS${NC}: both projects ticked (count=$tick_count)"
  PASS=$((PASS + 1))
} || {
  echo -e "  ${RED}FAIL${NC}: expected 2 ticks, got $tick_count"
  FAIL=$((FAIL + 1))
}
# Local project tick records AUTONOMOUS_CONF=$LOCAL_CONF
assert_contains "local project: AUTONOMOUS_CONF set to autonomous.conf path" "AUTONOMOUS_CONF=$LOCAL_CONF" "$record"
# Remote project records inline metadata + AUTONOMOUS_CONF=<unset>
assert_contains "remote project: REPO=myorg/remote-proj propagated" "REPO=myorg/remote-proj" "$record"
assert_contains "remote project: AUTONOMOUS_CONF unset" "AUTONOMOUS_CONF=<unset>" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EB-018: backwards compat — pure-path PROJECTS still works ==="
# ---------------------------------------------------------------------------
LOCAL_ONLY_CONF="$TMPROOT/disp-018.conf"
RECORD="$TMPROOT/record-018"
: > "$RECORD"
{
  echo 'PROJECTS=()'
  printf 'PROJECTS+=( %q )\n' "$LOCAL_CONF"
} > "$LOCAL_ONLY_CONF"

DISPATCHER_CONF="$LOCAL_ONLY_CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
assert_rc "rc=0 for PR-8-shape pure-path PROJECTS" 0 "$?"
record=$(cat "$RECORD")
assert_contains "PR-8 path entry: AUTONOMOUS_CONF set" "AUTONOMOUS_CONF=$LOCAL_CONF" "$record"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
