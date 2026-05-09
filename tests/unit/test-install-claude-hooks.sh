#!/bin/bash
# test-install-claude-hooks.sh — Tests for #68 install-claude-hooks.sh.
#
# Verifies:
#   1. First-time install creates .claude/settings.json with the canonical hooks.
#   2. Re-install merges with existing settings.json (preserves other top-level keys).
#   3. _managed_by annotation is present.
#   4. --no-git-hook flag suppresses the git pre-push install.
#
# Run: bash tests/unit/test-install-claude-hooks.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$PROJECT_ROOT/skills/autonomous-common/scripts/install-claude-hooks.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
echo "=== TC-CH-01: first-time install creates .claude/settings.json ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo1"
git -C "$TMPDIR/repo1" init --quiet --initial-branch=main
(cd "$TMPDIR/repo1" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

settings="$TMPDIR/repo1/.claude/settings.json"
if [[ -f "$settings" ]]; then
  echo -e "  ${GREEN}PASS${NC}: settings.json created"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: settings.json NOT created"
  FAIL=$((FAIL + 1))
fi

# Verify it's valid JSON
if python3 -c "import json; json.load(open('$settings'))" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: settings.json is valid JSON"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: settings.json is not valid JSON"
  FAIL=$((FAIL + 1))
fi

# Verify managed_by annotation
if grep -q '"_managed_by": "autonomous-common"' "$settings"; then
  echo -e "  ${GREEN}PASS${NC}: _managed_by annotation present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: _managed_by annotation missing"
  FAIL=$((FAIL + 1))
fi

# Verify the canonical hook list (block-push-to-main as a representative)
if grep -q 'block-push-to-main.sh' "$settings"; then
  echo -e "  ${GREEN}PASS${NC}: block-push-to-main.sh wired up"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: block-push-to-main.sh NOT in settings"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CH-02: re-install merges with existing settings.json ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo2/.claude"
git -C "$TMPDIR/repo2" init --quiet --initial-branch=main
cat > "$TMPDIR/repo2/.claude/settings.json" <<'JSON'
{
  "model": "claude-opus-4-7",
  "enabledPlugins": {
    "my-custom-plugin": true
  }
}
JSON

(cd "$TMPDIR/repo2" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)
settings="$TMPDIR/repo2/.claude/settings.json"

# Existing keys should be preserved
if jq -e '.model == "claude-opus-4-7"' "$settings" >/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: existing 'model' key preserved"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: existing 'model' key was clobbered"
  FAIL=$((FAIL + 1))
fi

if jq -e '.enabledPlugins."my-custom-plugin" == true' "$settings" >/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: existing enabledPlugins preserved"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: existing enabledPlugins was clobbered"
  FAIL=$((FAIL + 1))
fi

# Hooks should now be present
if jq -e '.hooks.PreToolUse | length > 0' "$settings" >/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: hooks merged in"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: hooks NOT merged"
  FAIL=$((FAIL + 1))
fi

# Backup of pre-existing settings should exist
backup_count=$(find "$TMPDIR/repo2/.claude" -name 'settings.json.bak.*' | wc -l)
if (( backup_count == 1 )); then
  echo -e "  ${GREEN}PASS${NC}: pre-existing settings.json backed up"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: expected 1 backup, found $backup_count"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CH-03: --no-git-hook suppresses git pre-push install ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo3"
git -C "$TMPDIR/repo3" init --quiet --initial-branch=main
(cd "$TMPDIR/repo3" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

if [[ ! -f "$TMPDIR/repo3/.git/hooks/pre-push" ]]; then
  echo -e "  ${GREEN}PASS${NC}: --no-git-hook prevented pre-push install"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: --no-git-hook did not suppress pre-push install"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CH-04: default behavior installs git pre-push too ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo4"
git -C "$TMPDIR/repo4" init --quiet --initial-branch=main
(cd "$TMPDIR/repo4" && bash "$INSTALLER" >/dev/null 2>&1)

if [[ -x "$TMPDIR/repo4/.git/hooks/pre-push" ]]; then
  echo -e "  ${GREEN}PASS${NC}: default install also installs git pre-push hook"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: default install did NOT install git pre-push hook"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
