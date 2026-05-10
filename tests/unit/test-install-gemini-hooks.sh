#!/bin/bash
# test-install-gemini-hooks.sh — Tests for the Gemini installer (PR-11b).
#
# Verifies: file path .gemini/settings.json, event-name translation
# (PreToolUse → BeforeTool, PostToolUse → AfterTool, Stop → Stop), tool
# matchers (Bash → run_shell_command, Write → write_file, Edit → replace).
#
# Run: bash tests/unit/test-install-gemini-hooks.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$PROJECT_ROOT/skills/autonomous-common/scripts/install-gemini-hooks.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
echo "=== TC-GEM-01: first-time install creates .gemini/settings.json ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo1"
git -C "$TMPDIR/repo1" init --quiet --initial-branch=main
(cd "$TMPDIR/repo1" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

target="$TMPDIR/repo1/.gemini/settings.json"
if [[ -f "$target" ]]; then
  echo -e "  ${GREEN}PASS${NC}: settings.json created"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: settings.json NOT created"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GEM-02: events are PascalCase Gemini-style (BeforeTool/AfterTool) ==="
# ---------------------------------------------------------------------------
if jq -e '.hooks.BeforeTool | length > 0' "$target" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: hooks.BeforeTool populated"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: hooks.BeforeTool missing"
  FAIL=$((FAIL + 1))
fi

if jq -e '.hooks.AfterTool | length > 0' "$target" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: hooks.AfterTool populated"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: hooks.AfterTool missing"
  FAIL=$((FAIL + 1))
fi

if jq -e '.hooks | has("PreToolUse") or has("PostToolUse")' "$target" >/dev/null 2>&1; then
  echo -e "  ${RED}FAIL${NC}: Claude-style PreToolUse/PostToolUse leaked"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: no Claude-style event leakage"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GEM-03: tool matchers translated to Gemini built-in names ==="
# ---------------------------------------------------------------------------
matchers=$(jq -r '.hooks.BeforeTool[].matcher' "$target" | sort -u)
for expected in run_shell_command write_file replace; do
  if grep -q "^${expected}$" <<<"$matchers"; then
    echo -e "  ${GREEN}PASS${NC}: matcher present: $expected"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: matcher missing: $expected"
    FAIL=$((FAIL + 1))
  fi
done

if grep -qE '^(Bash|Write|Edit)$' <<<"$matchers"; then
  echo -e "  ${RED}FAIL${NC}: Claude-style matcher leaked"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: no Claude-style matcher leakage"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GEM-04: re-install merges with existing top-level keys ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo2/.gemini"
git -C "$TMPDIR/repo2" init --quiet --initial-branch=main
cat > "$TMPDIR/repo2/.gemini/settings.json" <<'EOF'
{
  "userPreference": "preserve me",
  "hooks": { "BeforeTool": [{ "matcher": "old", "hooks": [] }] }
}
EOF
(cd "$TMPDIR/repo2" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)
target2="$TMPDIR/repo2/.gemini/settings.json"

if jq -e '.userPreference == "preserve me"' "$target2" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: pre-existing top-level key preserved"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: pre-existing key lost"
  FAIL=$((FAIL + 1))
fi

backups=("$TMPDIR/repo2/.gemini/settings.json.bak."*)
if [[ -f "${backups[0]}" ]]; then
  echo -e "  ${GREEN}PASS${NC}: backup file created"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: no backup file"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
