#!/bin/bash
# test-install-codex-hooks.sh — Tests for the Codex installer (PR-11b).
#
# Verifies: file paths .codex/hooks.json + .codex/config.toml, the
# `[features] codex_hooks = true` flag toggle (required upstream), and
# Claude-verbatim hooks block (Codex models its schema on Claude).
#
# Run: bash tests/unit/test-install-codex-hooks.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$PROJECT_ROOT/skills/autonomous-common/scripts/install-codex-hooks.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
echo "=== TC-CDX-01: first-time install creates both files ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo1"
git -C "$TMPDIR/repo1" init --quiet --initial-branch=main
(cd "$TMPDIR/repo1" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

hooks_file="$TMPDIR/repo1/.codex/hooks.json"
config_file="$TMPDIR/repo1/.codex/config.toml"

if [[ -f "$hooks_file" ]]; then
  echo -e "  ${GREEN}PASS${NC}: hooks.json created"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: hooks.json NOT created"
  FAIL=$((FAIL + 1))
fi

if [[ -f "$config_file" ]]; then
  echo -e "  ${GREEN}PASS${NC}: config.toml created"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: config.toml NOT created"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CDX-02: codex_hooks feature flag is enabled ==="
# ---------------------------------------------------------------------------
if grep -qE '^\s*codex_hooks\s*=\s*true\s*$' "$config_file"; then
  echo -e "  ${GREEN}PASS${NC}: [features] codex_hooks = true present in config.toml"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: codex_hooks = true missing — hooks.json will be ignored upstream"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CDX-03: hooks block uses Claude-verbatim event names ==="
# ---------------------------------------------------------------------------
# Codex modeled schema on Claude — should keep PreToolUse/PostToolUse/Stop.
if jq -e '.hooks.PreToolUse | length > 0' "$hooks_file" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: hooks.PreToolUse populated (Claude-verbatim)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: hooks.PreToolUse missing"
  FAIL=$((FAIL + 1))
fi

# Bash matcher should be preserved verbatim
matchers=$(jq -r '.hooks.PreToolUse[].matcher' "$hooks_file" | sort -u)
if grep -q '^Bash$' <<<"$matchers"; then
  echo -e "  ${GREEN}PASS${NC}: Bash matcher preserved (Claude-verbatim)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: Bash matcher missing"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CDX-04: re-running installer doesn't duplicate config.toml flag ==="
# ---------------------------------------------------------------------------
(cd "$TMPDIR/repo1" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)
flag_count=$(grep -cE '^\s*codex_hooks\s*=\s*true\s*$' "$config_file")
if [[ "$flag_count" -eq 1 ]]; then
  echo -e "  ${GREEN}PASS${NC}: codex_hooks flag appears exactly once after re-run (got $flag_count)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: re-run duplicated the flag (got $flag_count occurrences)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-CDX-05: existing config.toml without flag → flag appended (no overwrite) ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo2/.codex"
git -C "$TMPDIR/repo2" init --quiet --initial-branch=main
cat > "$TMPDIR/repo2/.codex/config.toml" <<'EOF'
# Existing user config
[some_other_section]
foo = "bar"
EOF
(cd "$TMPDIR/repo2" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

if grep -q '\[some_other_section\]' "$TMPDIR/repo2/.codex/config.toml"; then
  echo -e "  ${GREEN}PASS${NC}: existing user TOML preserved"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: existing user TOML lost"
  FAIL=$((FAIL + 1))
fi

if grep -qE '^\s*codex_hooks\s*=\s*true\s*$' "$TMPDIR/repo2/.codex/config.toml"; then
  echo -e "  ${GREEN}PASS${NC}: codex_hooks flag appended"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: codex_hooks flag NOT appended"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
