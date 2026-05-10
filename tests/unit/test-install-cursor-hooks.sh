#!/bin/bash
# test-install-cursor-hooks.sh — Tests for the Cursor installer (PR-11b).
#
# Verifies: file path, version envelope, event-name translation
# (PreToolUse → preToolUse), tool-matcher translation (Bash → Shell).
#
# Run: bash tests/unit/test-install-cursor-hooks.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$PROJECT_ROOT/skills/autonomous-common/scripts/install-cursor-hooks.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
echo "=== TC-CUR-01: first-time install creates .cursor/hooks.json ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo1"
git -C "$TMPDIR/repo1" init --quiet --initial-branch=main
(cd "$TMPDIR/repo1" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

target="$TMPDIR/repo1/.cursor/hooks.json"
if [[ -f "$target" ]]; then
  echo -e "  ${GREEN}PASS${NC}: hooks.json created"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: hooks.json NOT created"
  FAIL=$((FAIL + 1))
fi

# Cursor expects version: 1
if jq -e '.version == 1' "$target" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: version: 1 envelope present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: version: 1 missing"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CUR-02: events are camelCase (PreToolUse → preToolUse) ==="
# ---------------------------------------------------------------------------
if jq -e '.hooks.preToolUse | length > 0' "$target" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: hooks.preToolUse populated"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: hooks.preToolUse missing or empty"
  FAIL=$((FAIL + 1))
fi

if jq -e '.hooks | has("PreToolUse")' "$target" >/dev/null 2>&1; then
  echo -e "  ${RED}FAIL${NC}: PascalCase PreToolUse leaked into output"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: no PascalCase event leakage"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CUR-03: tool matchers translated (Bash → Shell) ==="
# ---------------------------------------------------------------------------
matchers=$(jq -r '.hooks.preToolUse[].matcher' "$target" | sort -u)
if grep -q '^Shell$' <<<"$matchers"; then
  echo -e "  ${GREEN}PASS${NC}: Shell matcher present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: Shell matcher missing"
  FAIL=$((FAIL + 1))
fi

if grep -q '^Bash$' <<<"$matchers"; then
  echo -e "  ${RED}FAIL${NC}: Bash matcher leaked (should be Shell)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: no Bash matcher leakage"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CUR-04: _managed_by annotation present ==="
# ---------------------------------------------------------------------------
if jq -e '._managed_by == "autonomous-common"' "$target" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: _managed_by annotation present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: _managed_by annotation missing"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
