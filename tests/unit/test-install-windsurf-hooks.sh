#!/bin/bash
# test-install-windsurf-hooks.sh — Tests for the Windsurf installer (PR-11c).
#
# Verifies: file path, snake_case events, NO matcher field, Edit+Write
# deduped to single pre_write_code event with merged hooks, idempotency,
# --no-git-hook flag.
#
# Run: bash tests/unit/test-install-windsurf-hooks.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$PROJECT_ROOT/skills/autonomous-common/scripts/install-windsurf-hooks.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
echo "=== TC-WS-01: first-time install creates .windsurf/hooks.json ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo1"
git -C "$TMPDIR/repo1" init --quiet --initial-branch=main
(cd "$TMPDIR/repo1" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

target="$TMPDIR/repo1/.windsurf/hooks.json"
if [[ -f "$target" ]]; then
  echo -e "  ${GREEN}PASS${NC}: hooks.json created"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: hooks.json NOT created"
  FAIL=$((FAIL + 1))
fi

if jq -e '.' "$target" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: valid JSON"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: malformed JSON"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-WS-02: events are snake_case Windsurf names ==="
# ---------------------------------------------------------------------------
event_keys=$(jq -r '.hooks | keys[]' "$target" | sort)
for expected in pre_run_command post_run_command pre_write_code post_cascade_response; do
  if grep -q "^${expected}$" <<<"$event_keys"; then
    echo -e "  ${GREEN}PASS${NC}: event present: $expected"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: event missing: $expected"
    FAIL=$((FAIL + 1))
  fi
done

# Claude-style PascalCase events must NOT leak through.
if jq -e '.hooks | has("PreToolUse") or has("PostToolUse")' "$target" >/dev/null 2>&1; then
  echo -e "  ${RED}FAIL${NC}: Claude-style PreToolUse/PostToolUse leaked"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: no Claude-style event leakage"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-WS-03: NO matcher field on hook entries (Windsurf has no matcher) ==="
# ---------------------------------------------------------------------------
matchers=$(jq '[.hooks | to_entries[].value[] | has("matcher")] | any' "$target")
if [[ "$matchers" == "false" ]]; then
  echo -e "  ${GREEN}PASS${NC}: no hook entry has a matcher field"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: at least one hook entry has a matcher field (Windsurf doesn't support it)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-WS-04: pre_write_code dedups Write+Edit hooks ==="
# ---------------------------------------------------------------------------
# Canonical template: PreToolUse + Write has 1 hook, PreToolUse + Edit has
# 1 hook. After folding both into pre_write_code, expect 2 hooks total.
pre_write_count=$(jq '.hooks.pre_write_code | length' "$target")
if [[ "$pre_write_count" -eq 2 ]]; then
  echo -e "  ${GREEN}PASS${NC}: pre_write_code has 2 merged hooks (Write + Edit)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: pre_write_code expected 2, got $pre_write_count"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-WS-05: re-install creates a backup ==="
# ---------------------------------------------------------------------------
(cd "$TMPDIR/repo1" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)
backups=("$TMPDIR/repo1/.windsurf/hooks.json.bak."*)
if [[ -f "${backups[0]}" ]]; then
  echo -e "  ${GREEN}PASS${NC}: backup file created on re-install"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: no backup file"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-WS-06: --no-git-hook suppresses git pre-push install ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo2"
git -C "$TMPDIR/repo2" init --quiet --initial-branch=main
(cd "$TMPDIR/repo2" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

if [[ ! -f "$TMPDIR/repo2/.git/hooks/pre-push" ]]; then
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
