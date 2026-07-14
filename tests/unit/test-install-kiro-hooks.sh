#!/bin/bash
# test-install-kiro-hooks.sh — Tests for the Kiro installer (PR-11b).
#
# Verifies: file path .kiro/agents/<name>.json, --agent flag, event
# camelCase, tool name translation (Bash → execute_bash, Write/Edit → fs_write),
# timeout-to-milliseconds conversion, agent-stub creation when file is new.
#
# Run: bash tests/unit/test-install-kiro-hooks.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$PROJECT_ROOT/skills/autonomous-common/scripts/install-kiro-hooks.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
echo "=== TC-KIRO-01: first-time install creates .kiro/agents/default.json ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo1"
git -C "$TMPDIR/repo1" init --quiet --initial-branch=main
(cd "$TMPDIR/repo1" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

target="$TMPDIR/repo1/.kiro/agents/default.json"
if [[ -f "$target" ]]; then
  echo -e "  ${GREEN}PASS${NC}: default.json created"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: default.json NOT created"
  FAIL=$((FAIL + 1))
fi

# Stub agent should have name and tools fields
if jq -e '.name == "default" and (.tools | length > 0)' "$target" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: stub agent has name + tools"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: stub agent missing name or tools"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIRO-02: events are camelCase ==="
# ---------------------------------------------------------------------------
if jq -e '.hooks.preToolUse | length > 0' "$target" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: hooks.preToolUse populated"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: hooks.preToolUse missing"
  FAIL=$((FAIL + 1))
fi

if jq -e '.hooks | has("PreToolUse")' "$target" >/dev/null 2>&1; then
  echo -e "  ${RED}FAIL${NC}: PascalCase PreToolUse leaked"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: no PascalCase event leakage"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIRO-03: tool matchers translated (Bash → execute_bash, Write/Edit → fs_write) ==="
# ---------------------------------------------------------------------------
matchers=$(jq -r '.hooks.preToolUse[].matcher' "$target" | sort -u)
if grep -q '^execute_bash$' <<<"$matchers"; then
  echo -e "  ${GREEN}PASS${NC}: execute_bash matcher present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: execute_bash matcher missing"
  FAIL=$((FAIL + 1))
fi

if grep -q '^fs_write$' <<<"$matchers"; then
  echo -e "  ${GREEN}PASS${NC}: fs_write matcher present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: fs_write matcher missing"
  FAIL=$((FAIL + 1))
fi

if grep -qE '^(Bash|Write|Edit)$' <<<"$matchers"; then
  echo -e "  ${RED}FAIL${NC}: Claude-style matcher leaked"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: no Claude-style matcher leakage"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIRO-04: timeouts converted to milliseconds ==="
# ---------------------------------------------------------------------------
# Canonical template uses timeout: 5 (seconds). Kiro expects timeout_ms: 5000.
ms_value=$(jq '.hooks.preToolUse[0].hooks[0].timeout_ms' "$target")
if [[ "$ms_value" -ge 1000 ]]; then
  echo -e "  ${GREEN}PASS${NC}: timeout_ms field present and >= 1000 (got $ms_value)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: timeout_ms missing or wrong unit (got $ms_value)"
  FAIL=$((FAIL + 1))
fi

if jq -e '.hooks.preToolUse[0].hooks[0] | has("timeout")' "$target" >/dev/null 2>&1; then
  echo -e "  ${RED}FAIL${NC}: seconds-based timeout field leaked (should be timeout_ms)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: no seconds-based timeout leakage"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIRO-04b: Write+Edit deduplicated to single fs_write entry (PR-11b C2) ==="
# ---------------------------------------------------------------------------
# Many-to-one tool mapping (Write → fs_write AND Edit → fs_write) must
# merge into a single matcher entry, not two duplicates that fire the
# same hook twice.
fs_write_count=$(jq '[.hooks.preToolUse[] | select(.matcher == "fs_write")] | length' "$target")
if [[ "$fs_write_count" -eq 1 ]]; then
  echo -e "  ${GREEN}PASS${NC}: exactly 1 fs_write matcher entry (no duplicates)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: expected 1 fs_write entry, got $fs_write_count (duplicate matchers fire hooks twice)"
  FAIL=$((FAIL + 1))
fi

# Write and Edit currently name the same hook command, so the merged matcher
# must execute it once.
fs_write_hooks=$(jq '.hooks.preToolUse[] | select(.matcher == "fs_write") | .hooks | length' "$target")
if [[ "$fs_write_hooks" -eq 1 ]]; then
  echo -e "  ${GREEN}PASS${NC}: duplicate Write/Edit hook command executes once"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: fs_write entry has $fs_write_hooks duplicate hook commands"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIRO-05: --agent <name> overrides default agent name ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo2"
git -C "$TMPDIR/repo2" init --quiet --initial-branch=main
(cd "$TMPDIR/repo2" && bash "$INSTALLER" --no-git-hook --agent autonomous-dev >/dev/null 2>&1)

target2="$TMPDIR/repo2/.kiro/agents/autonomous-dev.json"
if [[ -f "$target2" ]]; then
  echo -e "  ${GREEN}PASS${NC}: --agent autonomous-dev created the right file"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: --agent autonomous-dev did NOT create the expected file"
  FAIL=$((FAIL + 1))
fi

# Bad agent name with /
err=$(cd "$TMPDIR/repo2" && bash "$INSTALLER" --no-git-hook --agent "bad/name" 2>&1 >/dev/null) || rc=$?
if [[ "${rc:-0}" -eq 2 ]]; then
  echo -e "  ${GREEN}PASS${NC}: --agent with slash → rc=2"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: --agent with slash should reject (rc=${rc:-0})"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
