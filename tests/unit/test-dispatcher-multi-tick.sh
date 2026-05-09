#!/bin/bash
# test-dispatcher-multi-tick.sh — Unit tests for dispatcher-multi-tick.sh.
#
# Closes the test side of #62 (config-driven multi-project dispatch).
#
# Strategy: stub `dispatcher-tick.sh` with a recording shim that captures
# its $AUTONOMOUS_CONF env on each invocation. The wrapper sees the stub
# via $SCRIPT_DIR/dispatcher-tick.sh resolution, since the test runs the
# wrapper from a sandbox copy of skills/autonomous-dispatcher/scripts/.
#
# Run: bash tests/unit/test-dispatcher-multi-tick.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER_SRC="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-multi-tick.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

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

assert_rc() {
  local desc="$1" expected_rc="$2" actual_rc="$3"
  if [[ "$expected_rc" == "$actual_rc" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected_rc=$expected_rc actual_rc=$actual_rc"
    FAIL=$((FAIL + 1))
  fi
}

# Sandbox: copy wrapper + stub tick into a temp dir to control its lookup.
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
SANDBOX="$TMPROOT/scripts"
mkdir -p "$SANDBOX"
cp "$WRAPPER_SRC" "$SANDBOX/dispatcher-multi-tick.sh"

# Stub dispatcher-tick.sh: appends "$AUTONOMOUS_CONF\n" to a sentinel file
# and exits with the rc encoded in $TICK_RC_FOR_<basename of conf>.
# Defaults to 0 if no override env is set.
cat > "$SANDBOX/dispatcher-tick.sh" <<'EOF'
#!/bin/bash
echo "$AUTONOMOUS_CONF" >> "$TICK_RECORD_FILE"
override_var="TICK_RC_FOR_$(basename "$AUTONOMOUS_CONF" | tr -c 'A-Za-z0-9' '_')"
rc=${!override_var:-0}
exit "$rc"
EOF
chmod +x "$SANDBOX/dispatcher-tick.sh"

# Helper: write a dispatcher.conf with given project paths.
write_conf() {
  local conf="$1"; shift
  {
    echo 'PROJECTS=('
    for p in "$@"; do
      printf '  %q\n' "$p"
    done
    echo ')'
  } > "$conf"
}

# ---------------------------------------------------------------------------
echo "=== TC-MP-001: PROJECTS=() iterates the right number of times ==="
# ---------------------------------------------------------------------------
CONF="$TMPROOT/disp-001.conf"
RECORD="$TMPROOT/record-001"
: > "$RECORD"
# Touch fake project confs so the readability check passes.
for p in "$TMPROOT/proj-a.conf" "$TMPROOT/proj-b.conf" "$TMPROOT/proj-c.conf"; do
  touch "$p"
done
write_conf "$CONF" "$TMPROOT/proj-a.conf" "$TMPROOT/proj-b.conf" "$TMPROOT/proj-c.conf"

DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>&1
rc=$?
assert_rc "rc=0 when all projects tick cleanly" 0 "$rc"
assert_eq "stub invoked 3 times" "3" "$(wc -l <"$RECORD" | tr -d ' ')"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-MP-002: AUTONOMOUS_CONF env propagated per iteration ==="
# ---------------------------------------------------------------------------
expected="$TMPROOT/proj-a.conf
$TMPROOT/proj-b.conf
$TMPROOT/proj-c.conf"
assert_eq "AUTONOMOUS_CONF recorded in PROJECTS order" "$expected" "$(cat "$RECORD")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-MP-003: Per-project failure does not break the loop ==="
# ---------------------------------------------------------------------------
RECORD="$TMPROOT/record-003"
: > "$RECORD"
# Force conf-a's tick to return rc=2. Build the override env name from the
# filename, then export it so the subshell sees it. (Inline `VAR=value cmd`
# would require a literal var name, which we can't write here because the
# name depends on $TMPROOT.)
override_var="TICK_RC_FOR_$(basename "$TMPROOT/proj-a.conf" | tr -c 'A-Za-z0-9' '_')"
export "$override_var=2"

stderr_log="$TMPROOT/stderr-003"
DISPATCHER_CONF="$CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>"$stderr_log"
unset "$override_var"
rc=$?
# Wrapper exits 0 even though one project failed.
assert_rc "wrapper exits 0 despite per-project failure" 0 "$rc"
assert_eq "all 3 projects still attempted" "3" "$(wc -l <"$RECORD" | tr -d ' ')"
case "$(cat "$stderr_log")" in
  *"tick failed for $TMPROOT/proj-a.conf"*)
    echo -e "  ${GREEN}PASS${NC}: stderr names the failed project"
    PASS=$((PASS + 1)) ;;
  *)
    echo -e "  ${RED}FAIL${NC}: expected 'tick failed for ${TMPROOT}/proj-a.conf' in stderr"
    FAIL=$((FAIL + 1)) ;;
esac

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-MP-004: DISPATCHER_CONF unset → wrapper aborts ==="
# ---------------------------------------------------------------------------
# Point HOME and XDG away from anything that exists.
RECORD="$TMPROOT/record-004"
: > "$RECORD"
stderr_log="$TMPROOT/stderr-004"
HOME="$TMPROOT/no-home" XDG_CONFIG_HOME="$TMPROOT/no-xdg" \
  TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>"$stderr_log"
rc=$?
[ "$rc" -ne 0 ] && {
  echo -e "  ${GREEN}PASS${NC}: rc != 0 (got $rc)"
  PASS=$((PASS + 1))
} || {
  echo -e "  ${RED}FAIL${NC}: expected non-zero rc"
  FAIL=$((FAIL + 1))
}
case "$(cat "$stderr_log")" in
  *"dispatcher.conf not found"*)
    echo -e "  ${GREEN}PASS${NC}: stderr explains missing dispatcher.conf"
    PASS=$((PASS + 1)) ;;
  *)
    echo -e "  ${RED}FAIL${NC}: expected 'dispatcher.conf not found' in stderr"
    FAIL=$((FAIL + 1)) ;;
esac
assert_eq "no projects ticked when conf is missing" "0" "$(wc -l <"$RECORD" | tr -d ' ')"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-MP-005: DISPATCHER_CONF set but file missing → diagnostic ==="
# ---------------------------------------------------------------------------
stderr_log="$TMPROOT/stderr-005"
DISPATCHER_CONF="$TMPROOT/nonexistent-conf" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>"$stderr_log"
rc=$?
[ "$rc" -ne 0 ] && {
  echo -e "  ${GREEN}PASS${NC}: rc != 0 (got $rc)"
  PASS=$((PASS + 1))
} || {
  echo -e "  ${RED}FAIL${NC}: expected non-zero rc"
  FAIL=$((FAIL + 1))
}
case "$(cat "$stderr_log")" in
  *"missing or unreadable"*)
    echo -e "  ${GREEN}PASS${NC}: stderr explains missing path"
    PASS=$((PASS + 1)) ;;
  *)
    echo -e "  ${RED}FAIL${NC}: expected 'missing or unreadable' in stderr"
    FAIL=$((FAIL + 1)) ;;
esac

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-MP-006: Empty PROJECTS=() → exit 0 with one log line ==="
# ---------------------------------------------------------------------------
EMPTY_CONF="$TMPROOT/disp-empty.conf"
echo 'PROJECTS=()' > "$EMPTY_CONF"
RECORD="$TMPROOT/record-006"
: > "$RECORD"
stdout_log="$TMPROOT/stdout-006"
DISPATCHER_CONF="$EMPTY_CONF" TICK_RECORD_FILE="$RECORD" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >"$stdout_log" 2>&1
rc=$?
assert_rc "empty PROJECTS → rc=0" 0 "$rc"
assert_eq "no projects ticked" "0" "$(wc -l <"$RECORD" | tr -d ' ')"
case "$(cat "$stdout_log")" in
  *"no projects configured"*)
    echo -e "  ${GREEN}PASS${NC}: stdout has 'no projects configured' log line"
    PASS=$((PASS + 1)) ;;
  *)
    echo -e "  ${RED}FAIL${NC}: expected 'no projects configured' in stdout"
    FAIL=$((FAIL + 1)) ;;
esac

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-MP-007: PROJECTS unset → diagnostic ==="
# ---------------------------------------------------------------------------
NO_ARRAY_CONF="$TMPROOT/disp-no-array.conf"
echo 'OTHER_VAR=42' > "$NO_ARRAY_CONF"
stderr_log="$TMPROOT/stderr-007"
DISPATCHER_CONF="$NO_ARRAY_CONF" \
  bash "$SANDBOX/dispatcher-multi-tick.sh" >/dev/null 2>"$stderr_log"
rc=$?
[ "$rc" -ne 0 ] && {
  echo -e "  ${GREEN}PASS${NC}: rc != 0 (got $rc)"
  PASS=$((PASS + 1))
} || {
  echo -e "  ${RED}FAIL${NC}: expected non-zero rc"
  FAIL=$((FAIL + 1))
}
case "$(cat "$stderr_log")" in
  *"PROJECTS array"*)
    echo -e "  ${GREEN}PASS${NC}: stderr names PROJECTS"
    PASS=$((PASS + 1)) ;;
  *)
    echo -e "  ${RED}FAIL${NC}: expected 'PROJECTS array' in stderr"
    FAIL=$((FAIL + 1)) ;;
esac

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-MP-008: Source-of-truth check on outer loop subshell ==="
# ---------------------------------------------------------------------------
# The loop body must run dispatcher-tick.sh in a subshell (parentheses),
# pass AUTONOMOUS_CONF as a per-iteration env, and not exit on per-project
# failure. Detect drift via grep.
if grep -q '^\s*if ( AUTONOMOUS_CONF=' "$WRAPPER_SRC" \
   && grep -q 'bash "\$SCRIPT_DIR/dispatcher-tick.sh"' "$WRAPPER_SRC"; then
  echo -e "  ${GREEN}PASS${NC}: loop runs dispatcher-tick.sh in subshell with AUTONOMOUS_CONF env"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: outer loop subshell pattern missing or changed shape"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
