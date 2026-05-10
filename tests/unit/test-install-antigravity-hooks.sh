#!/bin/bash
# test-install-antigravity-hooks.sh — Tests for the Antigravity installer (PR-11a).
#
# Antigravity differs from Claude/Qoder: its config file is hooks-only
# (.antigravity/hooks.json), so the installer uses write_hooks_only_settings
# instead of merge_hooks_settings. Existing files ARE backed up before
# overwrite (so an operator's hand-edited hooks aren't lost silently).
#
# Run: bash tests/unit/test-install-antigravity-hooks.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$PROJECT_ROOT/skills/autonomous-common/scripts/install-antigravity-hooks.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
echo "=== TC-AG-01: first-time install creates .antigravity/hooks.json ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo1"
git -C "$TMPDIR/repo1" init --quiet --initial-branch=main
(cd "$TMPDIR/repo1" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

target="$TMPDIR/repo1/.antigravity/hooks.json"
if [[ -f "$target" ]]; then
  echo -e "  ${GREEN}PASS${NC}: .antigravity/hooks.json created"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: .antigravity/hooks.json NOT created"
  FAIL=$((FAIL + 1))
fi

if python3 -c "import json; json.load(open('$target'))" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: hooks.json is valid JSON"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: hooks.json is not valid JSON"
  FAIL=$((FAIL + 1))
fi

if grep -q '"_managed_by": "autonomous-common"' "$target"; then
  echo -e "  ${GREEN}PASS${NC}: _managed_by annotation present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: _managed_by annotation missing"
  FAIL=$((FAIL + 1))
fi

if jq -e '.hooks.PreToolUse | length > 0' "$target" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: hooks.PreToolUse populated"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: hooks.PreToolUse missing"
  FAIL=$((FAIL + 1))
fi

# Antigravity's hooks.json is hooks-only — should NOT contain other
# top-level Claude-settings.json keys like enabledPlugins.
if jq -e 'has("enabledPlugins")' "$target" >/dev/null 2>&1; then
  echo -e "  ${RED}FAIL${NC}: hooks-only file unexpectedly contains enabledPlugins"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: hooks-only file (no settings.json bloat)"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AG-02: re-install backs up the existing file before overwrite ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo2/.antigravity"
git -C "$TMPDIR/repo2" init --quiet --initial-branch=main
cat > "$TMPDIR/repo2/.antigravity/hooks.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [{ "command": "operator-custom.sh" }] }
    ]
  }
}
EOF
(cd "$TMPDIR/repo2" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)
target="$TMPDIR/repo2/.antigravity/hooks.json"

# Old custom hook is gone (overwritten — this is the documented contract).
if jq -e '.hooks.PreToolUse | map(.hooks[].command) | any(. == "operator-custom.sh")' "$target" >/dev/null 2>&1; then
  echo -e "  ${RED}FAIL${NC}: operator's hand-edited hooks block was NOT overwritten"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: operator's hand-edited hooks overwritten by canonical template"
  PASS=$((PASS + 1))
fi

# Backup must exist — otherwise we silently destroyed the operator's work.
backups=("$TMPDIR/repo2/.antigravity/hooks.json.bak."*)
if [[ -f "${backups[0]}" ]]; then
  echo -e "  ${GREEN}PASS${NC}: backup file created"
  PASS=$((PASS + 1))
  # Backup should still contain the operator's old content
  if jq -e '.hooks.PreToolUse | map(.hooks[].command) | any(. == "operator-custom.sh")' "${backups[0]}" >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${NC}: backup contains the operator's old content"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: backup does NOT contain operator's old content"
    FAIL=$((FAIL + 1))
  fi
else
  echo -e "  ${RED}FAIL${NC}: no backup file — operator's work would be silently destroyed"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AG-03: --no-git-hook suppresses git pre-push install ==="
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
