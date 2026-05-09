#!/bin/bash
# test-bash-source-empty.sh — Unit tests for BASH_SOURCE[0] empty handling
#
# Tests the AUTONOMOUS_CONF env var and ${BASH_SOURCE[0]:-$0} fallback.
# Verifies fix for issue #39.
# Run: bash tests/unit/test-bash-source-empty.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
    ((FAIL++))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    ((PASS++))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected to contain '$needle')"
    ((FAIL++))
  fi
}

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

DISPATCHER_SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"

# ===========================================================================
# TC-BSE-001: AUTONOMOUS_CONF env var takes highest priority
# ===========================================================================
echo ""
echo "=== TC-BSE-001: AUTONOMOUS_CONF env var takes highest priority ==="
echo ""

mkdir -p "$TMPDIR/bse-001/scripts"

# Config via env var
cat > "$TMPDIR/bse-001/env-config.conf" <<'CONF'
PROJECT_ID="from-env-var"
PROJECT_DIR="/tmp/fake"
CONF

# Config in script dir (should be ignored when AUTONOMOUS_CONF is set)
cat > "$TMPDIR/bse-001/scripts/autonomous.conf" <<'CONF'
PROJECT_ID="from-local-dir"
PROJECT_DIR="/tmp/fake"
CONF

# Test script simulating lib-agent.sh config loading
cat > "$TMPDIR/bse-001/scripts/test-config.sh" <<'SCRIPT'
#!/bin/bash
PROJECT_ID=""
if [[ -n "${AUTONOMOUS_CONF:-}" && -f "$AUTONOMOUS_CONF" ]]; then
  source "$AUTONOMOUS_CONF"
else
  _SELF="${BASH_SOURCE[0]:-$0}"
  _DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"
  if [[ -f "${_DIR}/autonomous.conf" ]]; then
    source "${_DIR}/autonomous.conf"
  fi
fi
echo "$PROJECT_ID"
SCRIPT
chmod +x "$TMPDIR/bse-001/scripts/test-config.sh"

RESULT=$(AUTONOMOUS_CONF="$TMPDIR/bse-001/env-config.conf" bash "$TMPDIR/bse-001/scripts/test-config.sh")
assert_eq "AUTONOMOUS_CONF env var takes priority" "from-env-var" "$RESULT"

# ===========================================================================
# TC-BSE-002: Config loads normally when AUTONOMOUS_CONF is not set
# ===========================================================================
echo ""
echo "=== TC-BSE-002: Config loads from local dir without AUTONOMOUS_CONF ==="
echo ""

RESULT=$(unset AUTONOMOUS_CONF; bash "$TMPDIR/bse-001/scripts/test-config.sh")
assert_eq "Local config loaded when AUTONOMOUS_CONF unset" "from-local-dir" "$RESULT"

# ===========================================================================
# TC-BSE-003: bash -c invocation works with AUTONOMOUS_CONF
# ===========================================================================
echo ""
echo "=== TC-BSE-003: bash -c invocation works with AUTONOMOUS_CONF ==="
echo ""

RESULT=$(AUTONOMOUS_CONF="$TMPDIR/bse-001/env-config.conf" bash -c "bash $TMPDIR/bse-001/scripts/test-config.sh")
assert_eq "bash -c with AUTONOMOUS_CONF works" "from-env-var" "$RESULT"

# ===========================================================================
# TC-BSE-004: BASH_SOURCE fallback to $0 in bash -c context
# ===========================================================================
echo ""
echo "=== TC-BSE-004: BASH_SOURCE fallback to \$0 ==="
echo ""

# Create a script that uses the BASH_SOURCE fallback pattern
mkdir -p "$TMPDIR/bse-004/scripts"
cat > "$TMPDIR/bse-004/scripts/autonomous.conf" <<'CONF'
PROJECT_ID="bash-c-fallback"
PROJECT_DIR="/tmp/fake"
CONF

cat > "$TMPDIR/bse-004/scripts/test-fallback.sh" <<'SCRIPT'
#!/bin/bash
PROJECT_ID=""
_SELF="${BASH_SOURCE[0]:-$0}"
_DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"
if [[ -f "${_DIR}/autonomous.conf" ]]; then
  source "${_DIR}/autonomous.conf"
fi
echo "$PROJECT_ID"
SCRIPT
chmod +x "$TMPDIR/bse-004/scripts/test-fallback.sh"

# Direct invocation (BASH_SOURCE[0] is set)
RESULT=$(bash "$TMPDIR/bse-004/scripts/test-fallback.sh")
assert_eq "Direct invocation: BASH_SOURCE works" "bash-c-fallback" "$RESULT"

# bash -c invocation (BASH_SOURCE[0] may be empty, $0 fallback kicks in)
RESULT=$(bash -c "bash $TMPDIR/bse-004/scripts/test-fallback.sh")
assert_eq "bash -c invocation: \$0 fallback works" "bash-c-fallback" "$RESULT"

# ===========================================================================
# TC-BSE-005: Invalid AUTONOMOUS_CONF path falls through to local config
# ===========================================================================
echo ""
echo "=== TC-BSE-005: Invalid AUTONOMOUS_CONF falls through ==="
echo ""

RESULT=$(AUTONOMOUS_CONF="/nonexistent/path.conf" bash "$TMPDIR/bse-001/scripts/test-config.sh")
assert_eq "Invalid AUTONOMOUS_CONF falls through to local" "from-local-dir" "$RESULT"

# ===========================================================================
# Script Content Verification
# ===========================================================================
echo ""
echo "=== Script Content Verification ==="
echo ""

LIB_AGENT="$DISPATCHER_SCRIPTS/lib-agent.sh"
LIB_AUTH="$DISPATCHER_SCRIPTS/lib-auth.sh"

# PR-4 (#58 fix) consolidated AUTONOMOUS_CONF / BASH_SOURCE handling into
# lib-config.sh::load_autonomous_conf. lib-agent.sh and lib-auth.sh now
# delegate via `source lib-config.sh; load_autonomous_conf "$dir"`.
LIB_CONFIG="$DISPATCHER_SCRIPTS/lib-config.sh"

echo "TC-CONTENT-001: lib-agent.sh delegates to lib-config.sh"
if [[ -f "$LIB_AGENT" ]]; then
  CONTENT=$(cat "$LIB_AGENT")
  assert_contains "lib-agent.sh sources lib-config.sh" 'lib-config.sh' "$CONTENT"
  assert_contains "lib-agent.sh calls load_autonomous_conf" 'load_autonomous_conf' "$CONTENT"
  assert_contains "BASH_SOURCE fallback in lib-agent.sh" 'BASH_SOURCE[0]:-$0' "$CONTENT"
else
  echo -e "  ${RED}FAIL${NC}: lib-agent.sh not found"
  ((FAIL++))
fi

echo "TC-CONTENT-002: lib-auth.sh delegates to lib-config.sh"
if [[ -f "$LIB_AUTH" ]]; then
  CONTENT=$(cat "$LIB_AUTH")
  assert_contains "lib-auth.sh sources lib-config.sh" 'lib-config.sh' "$CONTENT"
  assert_contains "lib-auth.sh calls load_autonomous_conf" 'load_autonomous_conf' "$CONTENT"
  assert_contains "BASH_SOURCE fallback in lib-auth.sh" 'BASH_SOURCE[0]:-$0' "$CONTENT"
else
  echo -e "  ${RED}FAIL${NC}: lib-auth.sh not found"
  ((FAIL++))
fi

echo "TC-CONTENT-003: lib-config.sh implements the 3-priority lookup (#58)"
if [[ -f "$LIB_CONFIG" ]]; then
  CONTENT=$(cat "$LIB_CONFIG")
  assert_contains "lib-config.sh defines load_autonomous_conf" 'load_autonomous_conf()' "$CONTENT"
  assert_contains "lib-config.sh AUTONOMOUS_CONF priority 1" 'AUTONOMOUS_CONF' "$CONTENT"
  assert_contains "lib-config.sh script-local priority 2" 'script_dir' "$CONTENT"
  assert_contains "lib-config.sh PROJECT_DIR fallback priority 3" 'PROJECT_DIR' "$CONTENT"
  # The whole point of #58: do NOT call readlink -f. Strip comments
  # before grepping so prose mentioning the disallowed call (e.g., a
  # commit-message reference) doesn't trigger a false positive.
  if grep -v '^[[:space:]]*#' "$LIB_CONFIG" | grep -q 'readlink -f'; then
    echo -e "  ${RED}FAIL${NC}: lib-config.sh contains a readlink -f call outside comments (#58 regression)"
    ((FAIL++))
  else
    echo -e "  ${GREEN}PASS${NC}: lib-config.sh does not call readlink -f (#58 mitigation in place)"
    ((PASS++))
  fi
else
  echo -e "  ${RED}FAIL${NC}: lib-config.sh not found"
  ((FAIL++))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo -e "Total: $TOTAL  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
exit 0
