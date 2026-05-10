#!/bin/bash
# test-install-qoder-hooks.sh — Tests for the Qoder installer (PR-11a).
#
# Verifies:
#   1. First-time install creates .qoder/settings.json with the canonical hooks.
#   2. Re-install merges with existing settings.json (preserves other top-level keys).
#   3. _managed_by annotation is present.
#   4. --no-git-hook flag suppresses the git pre-push install.
#
# The Qoder installer reuses lib-installer.sh's merge_hooks_settings, so the
# happy-path behavior is byte-equivalent to install-claude-hooks.sh except
# for the target path (.qoder/settings.json vs .claude/settings.json).
#
# Run: bash tests/unit/test-install-qoder-hooks.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$PROJECT_ROOT/skills/autonomous-common/scripts/install-qoder-hooks.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
echo "=== TC-Q-01: first-time install creates .qoder/settings.json ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo1"
git -C "$TMPDIR/repo1" init --quiet --initial-branch=main
(cd "$TMPDIR/repo1" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

settings="$TMPDIR/repo1/.qoder/settings.json"
if [[ -f "$settings" ]]; then
  echo -e "  ${GREEN}PASS${NC}: .qoder/settings.json created"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: .qoder/settings.json NOT created"
  FAIL=$((FAIL + 1))
fi

if python3 -c "import json; json.load(open('$settings'))" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: settings.json is valid JSON"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: settings.json is not valid JSON"
  FAIL=$((FAIL + 1))
fi

if grep -q '"_managed_by": "autonomous-common"' "$settings"; then
  echo -e "  ${GREEN}PASS${NC}: _managed_by annotation present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: _managed_by annotation missing"
  FAIL=$((FAIL + 1))
fi

if jq -e '.hooks.PreToolUse | length > 0' "$settings" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: hooks.PreToolUse populated"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: hooks.PreToolUse missing or empty"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-Q-02: re-install merges, preserves other top-level keys ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo2"
git -C "$TMPDIR/repo2" init --quiet --initial-branch=main
mkdir -p "$TMPDIR/repo2/.qoder"
cat > "$TMPDIR/repo2/.qoder/settings.json" <<'EOF'
{
  "userPreference": "preserve me",
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "command": "old-hook.sh" }] }
    ]
  }
}
EOF
(cd "$TMPDIR/repo2" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)
settings="$TMPDIR/repo2/.qoder/settings.json"

if jq -e '.userPreference == "preserve me"' "$settings" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: pre-existing top-level key preserved"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: pre-existing top-level key lost"
  FAIL=$((FAIL + 1))
fi

# Old hooks block must have been overwritten by the canonical template.
if jq -e '.hooks.PreToolUse | map(.hooks[].command) | any(. == "old-hook.sh")' "$settings" >/dev/null 2>&1; then
  echo -e "  ${RED}FAIL${NC}: old hand-edited hooks block was NOT overwritten"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: old hooks block overwritten by canonical template"
  PASS=$((PASS + 1))
fi

# Backup file should exist
backups=("$TMPDIR/repo2/.qoder/settings.json.bak."*)
if [[ -f "${backups[0]}" ]]; then
  echo -e "  ${GREEN}PASS${NC}: backup file created"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: no backup file found"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-Q-03: --no-git-hook suppresses git pre-push install ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo3"
git -C "$TMPDIR/repo3" init --quiet --initial-branch=main
(cd "$TMPDIR/repo3" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

if [[ ! -f "$TMPDIR/repo3/.git/hooks/pre-push" ]]; then
  echo -e "  ${GREEN}PASS${NC}: --no-git-hook prevented pre-push install"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: --no-git-hook did NOT prevent pre-push install"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
