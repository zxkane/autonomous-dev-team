#!/bin/bash
# test-symlink-resolution.sh — Unit tests for symlink resolution in dispatcher scripts
#
# Tests the SCRIPT_DIR / _LIB_AGENT_DIR resolution and config fallback logic.
# Verifies fix for issue #37.
# Run: bash tests/unit/test-symlink-resolution.sh

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
# TC-SYM-001: SCRIPT_DIR resolves through chained symlinks
# ===========================================================================
echo ""
echo "=== TC-SYM-001: SCRIPT_DIR resolves through chained symlinks ==="
echo ""

# Create a chain: project/scripts/test.sh -> .claude/skills/disp/scripts/test.sh -> real/test.sh
mkdir -p "$TMPDIR/sym-001/real/scripts"
mkdir -p "$TMPDIR/sym-001/.claude/skills/disp/scripts"
mkdir -p "$TMPDIR/sym-001/project/scripts"

# Real script that prints its resolved SCRIPT_DIR
cat > "$TMPDIR/sym-001/real/scripts/test.sh" <<'SCRIPT'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
echo "$SCRIPT_DIR"
SCRIPT
chmod +x "$TMPDIR/sym-001/real/scripts/test.sh"

# Level 1 symlink: .claude/skills/disp/scripts/test.sh -> real/scripts/test.sh
ln -sf "$TMPDIR/sym-001/real/scripts/test.sh" "$TMPDIR/sym-001/.claude/skills/disp/scripts/test.sh"

# Level 2 symlink: project/scripts/test.sh -> .claude/skills/disp/scripts/test.sh
ln -sf "$TMPDIR/sym-001/.claude/skills/disp/scripts/test.sh" "$TMPDIR/sym-001/project/scripts/test.sh"

# Run through the double symlink
RESULT=$(bash "$TMPDIR/sym-001/project/scripts/test.sh")
assert_eq "Chained symlink resolves to real directory" "$TMPDIR/sym-001/real/scripts" "$RESULT"

# ===========================================================================
# TC-SYM-002: SCRIPT_DIR works when invoked directly (no symlink)
# ===========================================================================
echo ""
echo "=== TC-SYM-002: SCRIPT_DIR works with direct invocation ==="
echo ""

RESULT=$(bash "$TMPDIR/sym-001/real/scripts/test.sh")
assert_eq "Direct invocation resolves correctly" "$TMPDIR/sym-001/real/scripts" "$RESULT"

# ===========================================================================
# TC-SYM-003: _LIB_AGENT_DIR resolves through symlinks when sourced
# ===========================================================================
echo ""
echo "=== TC-SYM-003: _LIB_AGENT_DIR resolves through symlinks ==="
echo ""

mkdir -p "$TMPDIR/sym-003/real/scripts"
mkdir -p "$TMPDIR/sym-003/project/scripts"

# Real lib that sets _LIB_AGENT_DIR
cat > "$TMPDIR/sym-003/real/scripts/lib.sh" <<'LIB'
#!/bin/bash
_LIB_AGENT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LIB

# Real script that sources the lib and prints the result
cat > "$TMPDIR/sym-003/real/scripts/main.sh" <<'MAIN'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"
echo "$_LIB_AGENT_DIR"
MAIN
chmod +x "$TMPDIR/sym-003/real/scripts/main.sh"

# Symlink the main script
ln -sf "$TMPDIR/sym-003/real/scripts/main.sh" "$TMPDIR/sym-003/project/scripts/main.sh"

RESULT=$(bash "$TMPDIR/sym-003/project/scripts/main.sh")
assert_eq "Sourced lib resolves _LIB_AGENT_DIR through symlink" "$TMPDIR/sym-003/real/scripts" "$RESULT"

# ===========================================================================
# TC-SYM-004: dispatch-local.sh config fallback finds autonomous.conf
# ===========================================================================
echo ""
echo "=== TC-SYM-004: Config fallback finds autonomous.conf ==="
echo ""

mkdir -p "$TMPDIR/sym-004/skill/scripts"
mkdir -p "$TMPDIR/sym-004/project/scripts"

# Config only in project/scripts/ (not in skill/scripts/)
cat > "$TMPDIR/sym-004/project/scripts/autonomous.conf" <<'CONF'
PROJECT_ID="test-project-fallback"
PROJECT_DIR="/tmp/fake-project"
CONF

# Test script simulating dispatch-local.sh config loading
cat > "$TMPDIR/sym-004/skill/scripts/test-config.sh" <<'SCRIPT'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PROJECT_ID=""
if [[ -f "${SCRIPT_DIR}/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/autonomous.conf"
elif [[ -f "${SCRIPT_DIR}/../../../scripts/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/../../../scripts/autonomous.conf"
fi
echo "$PROJECT_ID"
SCRIPT
chmod +x "$TMPDIR/sym-004/skill/scripts/test-config.sh"

# Symlink from project/scripts/ to skill/scripts/
ln -sf "$TMPDIR/sym-004/skill/scripts/test-config.sh" "$TMPDIR/sym-004/project/scripts/test-config.sh"

# Run from the symlink — SCRIPT_DIR resolves to skill/scripts/ which has no conf
# The fallback path ../../../scripts/ from skill/scripts/ won't match the project layout
# But when run directly from the real location, let's verify the logic
RESULT=$(bash "$TMPDIR/sym-004/skill/scripts/test-config.sh")
assert_eq "Config not found in skill dir → empty (correct, no fallback match)" "" "$RESULT"

# Now set up the proper directory structure matching skills layout:
# skills/autonomous-dispatcher/scripts/ -> ../../scripts/ goes to project root
mkdir -p "$TMPDIR/sym-004b/skills/autonomous-dispatcher/scripts"
mkdir -p "$TMPDIR/sym-004b/scripts"

cat > "$TMPDIR/sym-004b/scripts/autonomous.conf" <<'CONF'
PROJECT_ID="test-project-from-fallback"
PROJECT_DIR="/tmp/fake-project"
CONF

cat > "$TMPDIR/sym-004b/skills/autonomous-dispatcher/scripts/test-config.sh" <<'SCRIPT'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PROJECT_ID=""
if [[ -f "${SCRIPT_DIR}/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/autonomous.conf"
elif [[ -f "${SCRIPT_DIR}/../../../scripts/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/../../../scripts/autonomous.conf"
fi
echo "$PROJECT_ID"
SCRIPT
chmod +x "$TMPDIR/sym-004b/skills/autonomous-dispatcher/scripts/test-config.sh"

RESULT=$(bash "$TMPDIR/sym-004b/skills/autonomous-dispatcher/scripts/test-config.sh")
assert_eq "Config loaded from fallback ../../scripts/autonomous.conf" "test-project-from-fallback" "$RESULT"

# ===========================================================================
# TC-SYM-005: Local autonomous.conf takes precedence over fallback
# ===========================================================================
echo ""
echo "=== TC-SYM-005: Local config takes precedence ==="
echo ""

mkdir -p "$TMPDIR/sym-005/skills/autonomous-dispatcher/scripts"
mkdir -p "$TMPDIR/sym-005/scripts"

cat > "$TMPDIR/sym-005/skills/autonomous-dispatcher/scripts/autonomous.conf" <<'CONF'
PROJECT_ID="local-config"
PROJECT_DIR="/tmp/fake-project"
CONF

cat > "$TMPDIR/sym-005/scripts/autonomous.conf" <<'CONF'
PROJECT_ID="fallback-config"
PROJECT_DIR="/tmp/fake-project"
CONF

cat > "$TMPDIR/sym-005/skills/autonomous-dispatcher/scripts/test-config.sh" <<'SCRIPT'
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PROJECT_ID=""
if [[ -f "${SCRIPT_DIR}/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/autonomous.conf"
elif [[ -f "${SCRIPT_DIR}/../../../scripts/autonomous.conf" ]]; then
  source "${SCRIPT_DIR}/../../../scripts/autonomous.conf"
fi
echo "$PROJECT_ID"
SCRIPT
chmod +x "$TMPDIR/sym-005/skills/autonomous-dispatcher/scripts/test-config.sh"

RESULT=$(bash "$TMPDIR/sym-005/skills/autonomous-dispatcher/scripts/test-config.sh")
assert_eq "Local config takes precedence" "local-config" "$RESULT"

# ===========================================================================
# Verify scripts use readlink -f (content checks)
# ===========================================================================
echo ""
echo "=== Script Content Verification ==="
echo ""

DEV_SCRIPT="$DISPATCHER_SCRIPTS/autonomous-dev.sh"
REVIEW_SCRIPT="$DISPATCHER_SCRIPTS/autonomous-review.sh"
DISPATCH_SCRIPT="$DISPATCHER_SCRIPTS/dispatch-local.sh"
LIB_AGENT="$DISPATCHER_SCRIPTS/lib-agent.sh"
LIB_AUTH="$DISPATCHER_SCRIPTS/lib-auth.sh"

echo "TC-CONTENT-001: autonomous-dev.sh uses readlink -f"
if [[ -f "$DEV_SCRIPT" ]]; then
  DEV_CONTENT=$(cat "$DEV_SCRIPT")
  assert_contains "readlink -f in autonomous-dev.sh" 'readlink -f' "$DEV_CONTENT"
else
  echo -e "  ${RED}FAIL${NC}: autonomous-dev.sh not found"
  ((FAIL++))
fi

echo "TC-CONTENT-002: autonomous-review.sh uses readlink -f"
if [[ -f "$REVIEW_SCRIPT" ]]; then
  REVIEW_CONTENT=$(cat "$REVIEW_SCRIPT")
  assert_contains "readlink -f in autonomous-review.sh" 'readlink -f' "$REVIEW_CONTENT"
else
  echo -e "  ${RED}FAIL${NC}: autonomous-review.sh not found"
  ((FAIL++))
fi

echo "TC-CONTENT-003: lib-agent.sh uses readlink -f"
if [[ -f "$LIB_AGENT" ]]; then
  LIB_CONTENT=$(cat "$LIB_AGENT")
  assert_contains "readlink -f in lib-agent.sh" 'readlink -f' "$LIB_CONTENT"
else
  echo -e "  ${RED}FAIL${NC}: lib-agent.sh not found"
  ((FAIL++))
fi

echo "TC-CONTENT-004: lib-auth.sh uses readlink -f"
if [[ -f "$LIB_AUTH" ]]; then
  LIB_AUTH_CONTENT=$(cat "$LIB_AUTH")
  assert_contains "readlink -f in lib-auth.sh" 'readlink -f' "$LIB_AUTH_CONTENT"
else
  echo -e "  ${RED}FAIL${NC}: lib-auth.sh not found"
  ((FAIL++))
fi

echo "TC-CONTENT-005: dispatch-local.sh has config fallback"
if [[ -f "$DISPATCH_SCRIPT" ]]; then
  DISPATCH_CONTENT=$(cat "$DISPATCH_SCRIPT")
  assert_contains "Fallback config path in dispatch-local.sh" 'autonomous.conf' "$DISPATCH_CONTENT"
  assert_contains "readlink -f in dispatch-local.sh" 'readlink -f' "$DISPATCH_CONTENT"
else
  echo -e "  ${RED}FAIL${NC}: dispatch-local.sh not found"
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
