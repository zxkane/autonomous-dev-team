#!/bin/bash
# test-install-kimi-hooks.sh — Tests for the Kimi CLI installer (PR-11c).
#
# Verifies: file path (default user-level, --project for project-level),
# TOML structure ([[hooks]] blocks), event names preserved as PascalCase,
# tool names translated (Bash → RunShell, Write → WriteFile, Edit →
# StrReplaceFile), idempotency (re-run preserves user TOML).
#
# Run: bash tests/unit/test-install-kimi-hooks.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$PROJECT_ROOT/skills/autonomous-common/scripts/install-kimi-hooks.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ---------------------------------------------------------------------------
echo "=== TC-KIMI-01: --project install creates .kimi/config.toml ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo1"
git -C "$TMPDIR/repo1" init --quiet --initial-branch=main
(cd "$TMPDIR/repo1" && bash "$INSTALLER" --no-git-hook --project >/dev/null 2>&1)

target="$TMPDIR/repo1/.kimi/config.toml"
if [[ -f "$target" ]]; then
  echo -e "  ${GREEN}PASS${NC}: config.toml created"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: config.toml NOT created"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIMI-02: TOML uses [[hooks]] array of tables ==="
# ---------------------------------------------------------------------------
hooks_count=$(grep -c '^\[\[hooks\]\]' "$target")
if [[ "$hooks_count" -ge 10 ]]; then
  echo -e "  ${GREEN}PASS${NC}: $hooks_count [[hooks]] blocks emitted"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: expected >= 10 [[hooks]] blocks, got $hooks_count"
  FAIL=$((FAIL + 1))
fi

# Each [[hooks]] should have an event line
event_count=$(grep -cE '^event = "(PreToolUse|PostToolUse|Stop)"' "$target")
if [[ "$event_count" -eq "$hooks_count" ]]; then
  echo -e "  ${GREEN}PASS${NC}: every [[hooks]] block has an event line ($event_count of $hooks_count)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: event count mismatch ($event_count vs $hooks_count)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIMI-03: tool matchers translated (Bash → RunShell, Write → WriteFile, Edit → StrReplaceFile) ==="
# ---------------------------------------------------------------------------
for expected in RunShell WriteFile StrReplaceFile; do
  if grep -qE "^matcher = \"${expected}\"$" "$target"; then
    echo -e "  ${GREEN}PASS${NC}: matcher present: $expected"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: matcher missing: $expected"
    FAIL=$((FAIL + 1))
  fi
done

# Claude-style matchers should NOT leak through.
if grep -qE '^matcher = "(Bash|Write|Edit)"$' "$target"; then
  echo -e "  ${RED}FAIL${NC}: Claude-style matcher leaked"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: no Claude-style matcher leakage"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIMI-04: timeout field present and seconds-based ==="
# ---------------------------------------------------------------------------
# Kimi uses seconds (same as Claude). The canonical template's timeouts
# are 5 / 10 / 15 / 30 — values < 1000 (which would imply ms).
if grep -qE '^timeout = [0-9]+$' "$target"; then
  echo -e "  ${GREEN}PASS${NC}: timeout fields present"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: timeout fields missing"
  FAIL=$((FAIL + 1))
fi

# All emitted timeouts should be < 1000 (seconds, not ms)
if awk '/^timeout = / { val = $3; if (val >= 1000) { print "found ms-shaped timeout: " val; exit 1 } }' "$target"; then
  echo -e "  ${GREEN}PASS${NC}: all timeout values are seconds (< 1000)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: timeout converted to ms (Kimi uses seconds)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIMI-05: re-install preserves user TOML, replaces hooks ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo2/.kimi"
git -C "$TMPDIR/repo2" init --quiet --initial-branch=main
cat > "$TMPDIR/repo2/.kimi/config.toml" <<'EOF'
# user-managed config
[user_section]
api_key = "secret"

[[hooks]]
event = "PreToolUse"
matcher = "OldMatcher"
command = "old-hand-edit.sh"
timeout = 99
EOF
(cd "$TMPDIR/repo2" && bash "$INSTALLER" --no-git-hook --project >/dev/null 2>&1)
target2="$TMPDIR/repo2/.kimi/config.toml"

if grep -q '\[user_section\]' "$target2" && grep -q 'api_key = "secret"' "$target2"; then
  echo -e "  ${GREEN}PASS${NC}: user [user_section] preserved"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: user [user_section] lost"
  FAIL=$((FAIL + 1))
fi

# Old hand-edited [[hooks]] block should be REPLACED with the canonical set
if grep -q 'old-hand-edit.sh' "$target2"; then
  echo -e "  ${RED}FAIL${NC}: old hand-edited [[hooks]] block survived"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: old hand-edited [[hooks]] block replaced"
  PASS=$((PASS + 1))
fi

# Backup file exists
backups=("$TMPDIR/repo2/.kimi/config.toml.bak."*)
if [[ -f "${backups[0]}" ]]; then
  echo -e "  ${GREEN}PASS${NC}: backup file created"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: no backup file"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIMI-05b: re-install doesn't accumulate stale header lines (PR-11c M1) ==="
# ---------------------------------------------------------------------------
# Code-reviewer M1: original awk stripped the wrong line count, leaking
# "# Autogenerated by ..." header into the file on each re-install. After
# 3 installs, the file should be no larger than 1 install plus a constant
# (no per-install accumulation).
mkdir -p "$TMPDIR/repo-stable"
git -C "$TMPDIR/repo-stable" init --quiet --initial-branch=main
(cd "$TMPDIR/repo-stable" && bash "$INSTALLER" --no-git-hook --project >/dev/null 2>&1)
target_stable="$TMPDIR/repo-stable/.kimi/config.toml"
size_after_first=$(wc -l <"$target_stable")

# Three more installs.
for _ in 1 2 3; do
  (cd "$TMPDIR/repo-stable" && bash "$INSTALLER" --no-git-hook --project >/dev/null 2>&1)
done
size_after_four=$(wc -l <"$target_stable")

if [[ "$size_after_first" -eq "$size_after_four" ]]; then
  echo -e "  ${GREEN}PASS${NC}: file size stable across 4 installs ($size_after_first lines, no header accumulation)"
  PASS=$((PASS + 1))
else
  diff=$((size_after_four - size_after_first))
  echo -e "  ${RED}FAIL${NC}: file grew from $size_after_first → $size_after_four lines (+$diff) on re-install — stale headers leaking"
  FAIL=$((FAIL + 1))
fi

# Confirm "# Autogenerated by install-kimi-hooks.sh" appears exactly once.
auto_count=$(grep -c '^# Autogenerated by install-kimi-hooks\.sh' "$target_stable")
if [[ "$auto_count" -eq 1 ]]; then
  echo -e "  ${GREEN}PASS${NC}: exactly 1 autogenerated header (got $auto_count)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: $auto_count autogenerated headers (should be 1)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-KIMI-06: --no-git-hook flag honored ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo3"
git -C "$TMPDIR/repo3" init --quiet --initial-branch=main
(cd "$TMPDIR/repo3" && bash "$INSTALLER" --no-git-hook --project >/dev/null 2>&1)

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
