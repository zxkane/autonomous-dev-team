#!/bin/bash
# test-script-exec-bits.sh — Verify the chmod fix for issue #97.
#
# Audits the git tree mode of every regular .sh file under
# skills/autonomous-dispatcher/scripts/ and skills/autonomous-common/scripts/
# against its actual usage pattern (directly-executed vs sourced-only):
#
#   - Directly-executed via `nohup` / `bash X` / `./X` → mode 100755
#   - Sourced-only via `source X` / `. X`             → mode 100644 (left alone)
#
# Also asserts the dispatcher-tick.sh self-healing block is scoped to the
# directly-executed scripts only (NOT a blanket *.sh glob), and that the
# installer-side helper + per-agent installer wiring are in place.
#
# Run: bash tests/unit/test-script-exec-bits.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected='$expected'"
    echo "      actual=  '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      needle='$needle'"
    FAIL=$((FAIL + 1))
  fi
}

git_mode() {
  # Read from the index, not HEAD, so the test passes as soon as the
  # `git update-index --chmod=+x` is staged — without requiring a commit.
  # CI runs from a fresh checkout where index == HEAD, so this is
  # equivalent there. Locally, this avoids spurious failures pre-commit.
  cd "$PROJECT_ROOT" && git ls-files --stage -- "$1" | awk '{print $1}'
}

# ---------------------------------------------------------------------------
echo "=== TC-EXEC-001/002: directly-executed dispatcher wrappers are 100755 ==="
# ---------------------------------------------------------------------------
assert_eq "autonomous-dev.sh mode" "100755" \
  "$(git_mode skills/autonomous-dispatcher/scripts/autonomous-dev.sh)"
assert_eq "autonomous-review.sh mode" "100755" \
  "$(git_mode skills/autonomous-dispatcher/scripts/autonomous-review.sh)"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-003: sourced-only libs left at their committed mode (no churn) ==="
# ---------------------------------------------------------------------------
# These three lib files are sourced-only (verified by grepping for
# `source X` callers and confirming no `bash X`/`./X` invocations).
# This PR deliberately does NOT flip their mode — the issue listed
# lib-review-bots.sh but auditing showed it's sourced-only.
for lib in \
  skills/autonomous-dispatcher/scripts/lib-review-bots.sh \
  skills/autonomous-common/scripts/lib-installer.sh \
  skills/autonomous-common/scripts/lib-installer-translate.sh; do
  mode=$(git_mode "$lib")
  if [[ "$mode" == "100644" ]]; then
    echo -e "  ${GREEN}PASS${NC}: ${lib##*/} preserved at 100644 (sourced-only)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: ${lib##*/} mode is $mode, expected 100644 (sourced-only files should not get +x)"
    FAIL=$((FAIL + 1))
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-004/005: dispatcher-tick.sh self-healing block ==="
# ---------------------------------------------------------------------------
TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"
TICK_CONTENT=$(<"$TICK")

assert_contains "tick self-heals autonomous-dev.sh" \
  "autonomous-dev.sh" "$TICK_CONTENT"
assert_contains "tick self-heals autonomous-review.sh" \
  "autonomous-review.sh" "$TICK_CONTENT"
assert_contains "tick self-heal block uses chmod +x" \
  "chmod +x" "$TICK_CONTENT"

# Negative assertion: the self-healing block must NOT use a blanket *.sh
# glob — that would flip sourced-only libs to executable, propagating
# the wrong contract.
if grep -qE 'chmod[[:space:]]+\+x[[:space:]]+"[^"]*"/\*\.sh' "$TICK"; then
  echo -e "  ${RED}FAIL${NC}: tick uses blanket *.sh glob (would flip sourced-only libs)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: tick does NOT use blanket *.sh glob"
  PASS=$((PASS + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-006: lib-installer.sh exposes ensure_dispatcher_scripts_executable ==="
# ---------------------------------------------------------------------------
LIB_INST="$PROJECT_ROOT/skills/autonomous-common/scripts/lib-installer.sh"
if grep -qE '^ensure_dispatcher_scripts_executable\(\)' "$LIB_INST"; then
  echo -e "  ${GREEN}PASS${NC}: ensure_dispatcher_scripts_executable defined"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: ensure_dispatcher_scripts_executable NOT defined in lib-installer.sh"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-007: every install-*-hooks.sh calls the helper ==="
# ---------------------------------------------------------------------------
for installer in "$PROJECT_ROOT"/skills/autonomous-common/scripts/install-*-hooks.sh; do
  base=$(basename "$installer")
  if grep -q 'ensure_dispatcher_scripts_executable' "$installer"; then
    echo -e "  ${GREEN}PASS${NC}: $base calls ensure_dispatcher_scripts_executable"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $base does NOT call ensure_dispatcher_scripts_executable"
    FAIL=$((FAIL + 1))
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EXEC-008: autonomous-dispatcher/SKILL.md has #97 hash-bump note ==="
# ---------------------------------------------------------------------------
DISP_SKILL="$PROJECT_ROOT/skills/autonomous-dispatcher/SKILL.md"
if grep -q '#97' "$DISP_SKILL"; then
  echo -e "  ${GREEN}PASS${NC}: SKILL.md mentions #97 (forces hash bump for downstream)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: SKILL.md does NOT mention #97 — downstream consumers will not see the update via computedHash"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
