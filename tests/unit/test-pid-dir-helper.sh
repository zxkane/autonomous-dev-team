#!/bin/bash
# test-pid-dir-helper.sh — Unit tests for lib-config.sh::pid_dir_for_project.
#
# Closes the test side of #72 (CWE-377). The helper relocates wrapper PID
# files from predictable /tmp paths to a per-user runtime directory.
#
# Run: bash tests/unit/test-pid-dir-helper.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-config.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-config.sh
source "$LIB"
set +e

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

# Sandbox: keep tests self-contained.
TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

export PROJECT_ID="test-piddir"

# ---------------------------------------------------------------------------
echo "=== pid_dir_for_project (#72) ==="
# ---------------------------------------------------------------------------

# TC-PD-001: AUTONOMOUS_PID_DIR override wins
unset XDG_RUNTIME_DIR
export AUTONOMOUS_PID_DIR="$TMPROOT/override"
out=$(pid_dir_for_project)
rc=$?
assert_rc "AUTONOMOUS_PID_DIR override returns 0" 0 "$rc"
assert_eq "AUTONOMOUS_PID_DIR override echoes the override path" "$TMPROOT/override" "$out"
assert_eq "AUTONOMOUS_PID_DIR override creates dir" "true" "$([ -d "$TMPROOT/override" ] && echo true || echo false)"
mode=$(stat -c '%a' "$TMPROOT/override" 2>/dev/null || stat -f '%Lp' "$TMPROOT/override" 2>/dev/null)
assert_eq "AUTONOMOUS_PID_DIR override sets mode 700" "700" "$mode"
unset AUTONOMOUS_PID_DIR

# TC-PD-002: XDG_RUNTIME_DIR preferred over HOME fallback
export XDG_RUNTIME_DIR="$TMPROOT/xdg"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
out=$(pid_dir_for_project)
assert_eq "XDG_RUNTIME_DIR honored" "$TMPROOT/xdg/autonomous-test-piddir" "$out"
mode=$(stat -c '%a' "$out" 2>/dev/null || stat -f '%Lp' "$out" 2>/dev/null)
assert_eq "XDG path mode 700" "700" "$mode"

# TC-PD-003: HOME fallback when XDG_RUNTIME_DIR unset
unset XDG_RUNTIME_DIR
export HOME="$TMPROOT/home"
out=$(pid_dir_for_project)
assert_eq "HOME fallback path" "$TMPROOT/home/.local/state/autonomous-test-piddir" "$out"
assert_eq "HOME fallback creates dir" "true" "$([ -d "$out" ] && echo true || echo false)"

# Edge case: XDG_RUNTIME_DIR set but the dir does not exist → fall through
# to HOME fallback (helper guards with [[ -d $XDG_RUNTIME_DIR ]]).
export XDG_RUNTIME_DIR="$TMPROOT/nonexistent-xdg"
[ ! -d "$XDG_RUNTIME_DIR" ] || rmdir "$XDG_RUNTIME_DIR"
out=$(pid_dir_for_project)
assert_eq "XDG_RUNTIME_DIR set but missing → HOME fallback" "$TMPROOT/home/.local/state/autonomous-test-piddir" "$out"
unset XDG_RUNTIME_DIR

# TC-PD-004: idempotent on second call
out1=$(pid_dir_for_project)
out2=$(pid_dir_for_project)
assert_eq "second call returns same path" "$out1" "$out2"

# TC-PD-005: refuses pre-existing symlink
target="$TMPROOT/symlink-target"
mkdir -p "$target"
ln -sfn "$target" "$TMPROOT/home/.local/state/autonomous-test-piddir-link"
export PROJECT_ID="test-piddir-link"
err=$(pid_dir_for_project 2>&1 >/dev/null)
rc=$?
assert_rc "symlinked dir → rc=1" 1 "$rc"
case "$err" in
  *"refusing to use symlinked path"*)
    echo -e "  ${GREEN}PASS${NC}: symlink refusal writes diagnostic to stderr"
    PASS=$((PASS + 1)) ;;
  *)
    echo -e "  ${RED}FAIL${NC}: expected 'refusing to use symlinked path' in stderr; got: $err"
    FAIL=$((FAIL + 1)) ;;
esac
export PROJECT_ID="test-piddir"

# Edge: PROJECT_ID unset → helper aborts via : "${PROJECT_ID:?...}"
(
  unset PROJECT_ID
  pid_dir_for_project
) 2>/dev/null
rc=$?
assert_rc "unset PROJECT_ID → non-zero rc" 1 "$rc"

# Source-of-truth check: chmod failure must return rc=1 (Q PR-77 finding —
# silently swallowing chmod 700 failure would defeat the entire CWE-377
# mitigation). Hard to simulate chmod failure portably in unit tests; assert
# the source contains the loud-failure path so a regression to `|| true`
# would fail this test.
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-config.sh"
if grep -q 'cannot set mode 700' "$LIB" \
   && ! grep -q 'chmod 700.*|| true' "$LIB"; then
  echo -e "  ${GREEN}PASS${NC}: chmod failure routes to rc=1 (no '|| true' silent swallow)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: chmod failure path missing or '|| true' silent-swallow regressed"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
