#!/bin/bash
# test-agent-timeout-wrapper.sh — Unit tests for lib-agent.sh::_run_with_timeout.
#
# Closes the test side of #60 (INV-13). The helper wraps agent CLI invocations
# in coreutils `timeout` so a hung CLI cannot eat indefinite wall-clock time.
#
# Run: bash tests/unit/test-agent-timeout-wrapper.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Suppress lib-config.sh from blocking on missing autonomous.conf — provide
# all required vars before sourcing lib-agent.sh.
export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export REPO_NAME=autonomous-dev-team
export PROJECT_ID=test-timeout
export PROJECT_DIR="$PROJECT_ROOT"
export GH_AUTH_MODE=token

# Source lib-agent.sh (also sources lib-config.sh and may load autonomous.conf).
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-agent.sh
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

# ---------------------------------------------------------------------------
echo "=== _run_with_timeout (INV-13) ==="
# ---------------------------------------------------------------------------

# Skip if no timeout binary available (CI matrix may include macOS without
# coreutils — the WARN path is exercised by the absent-binary case below).
if [[ -z "${_AGENT_TIMEOUT_CMD:-}" ]]; then
  echo "  SKIP: no timeout binary on PATH (testing fallback only)"
else
  # TC-WH-001: timeout fires within bound
  AGENT_TIMEOUT=1s
  start=$(date +%s)
  _run_with_timeout sleep 5 >/dev/null 2>&1
  rc=$?
  end=$(date +%s)
  elapsed=$((end - start))
  assert_rc "1s timeout vs sleep 5 returns 124" 124 "$rc"
  if [[ "$elapsed" -le 3 ]]; then
    echo -e "  ${GREEN}PASS${NC}: elapsed ${elapsed}s within 3s budget (--kill-after grace)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: elapsed ${elapsed}s exceeded 3s budget"
    FAIL=$((FAIL + 1))
  fi

  # TC-WH-002 (positive): command finishes before timeout passes through exit code
  AGENT_TIMEOUT=10s
  _run_with_timeout /bin/true
  assert_rc "fast command (true) returns 0" 0 "$?"

  _run_with_timeout bash -c 'exit 7'
  assert_rc "command's own non-zero rc passes through" 7 "$?"
fi

# TC-WH-002 (fallback): when binary is absent, _run_with_timeout still works.
# Simulate absence by clearing the cached path.
saved_cmd="${_AGENT_TIMEOUT_CMD:-}"
_AGENT_TIMEOUT_CMD=""

_run_with_timeout /bin/true
assert_rc "fallback (no timeout binary): /bin/true → 0" 0 "$?"

_run_with_timeout bash -c 'exit 5'
assert_rc "fallback: command exit 5 passes through" 5 "$?"

# Restore for any subsequent tests sourcing this file.
_AGENT_TIMEOUT_CMD="$saved_cmd"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
