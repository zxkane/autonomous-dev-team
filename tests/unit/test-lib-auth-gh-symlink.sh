#!/bin/bash
# test-lib-auth-gh-symlink.sh — Unit test for INV-32 (issue #142).
#
# Asserts that lib-auth.sh creates the `gh` symlink in BOTH auth modes
# (app and token), so the agent-facing rule
#   bash scripts/gh issue comment …
# in skills/autonomous-dev/SKILL.md Step 12 and
# skills/autonomous-dev/references/autonomous-mode.md works regardless of
# GH_AUTH_MODE.
#
# Background: prior to issue #142, the symlink was created only inside the
# app-mode branch, so token-mode operators had no `gh` file to invoke. The
# wrapper script (gh-with-token-refresh.sh) is itself mode-agnostic — it
# only reads from GH_TOKEN_FILE when set. In token mode it falls through
# to exec the real gh inheriting the host's env (which IS the intended
# identity in token mode). So lifting the symlink out of the app branch
# is safe and unifies the rule.
#
# Run: bash tests/unit/test-lib-auth-gh-symlink.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_pass() {
  echo -e "  ${GREEN}PASS${NC}: $1"
  PASS=$((PASS + 1))
}

assert_fail() {
  echo -e "  ${RED}FAIL${NC}: $1"
  FAIL=$((FAIL + 1))
}

LIB_AUTH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-auth.sh"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/gh-with-token-refresh.sh"

# ---------------------------------------------------------------------------
echo "=== TC-AUTH-SYM-001: token-mode setup creates the gh symlink ==="
# ---------------------------------------------------------------------------
# Run setup_github_auth in a subshell with GH_AUTH_MODE=token. We don't
# stub the PEM/app-id args because the token branch ignores them.
# We sandbox _LIB_AUTH_DIR by copying the real lib + wrapper into a tmpdir
# so the test never mutates production scripts.
TMP1=$(mktemp -d)
trap 'rm -rf "$TMP1" "${TMP2:-}"' EXIT
cp "$LIB_AUTH" "$TMP1/lib-auth.sh"
cp "$WRAPPER" "$TMP1/gh-with-token-refresh.sh"
chmod +x "$TMP1/gh-with-token-refresh.sh"
# lib-config.sh is sourced by lib-auth.sh; provide a minimal stub.
cat > "$TMP1/lib-config.sh" <<'STUB'
#!/bin/bash
load_autonomous_conf() { return 0; }
STUB

# Run setup_github_auth in token mode. Suppress the "WARNING: No GH_TOKEN…"
# message — we set GH_TOKEN to bypass it.
GH_TOKEN="dummy-token-for-test" \
  bash -c "
    source '$TMP1/lib-auth.sh'
    GH_AUTH_MODE='token'
    setup_github_auth
  " >/dev/null 2>&1

if [[ -L "$TMP1/gh" ]]; then
  target=$(readlink "$TMP1/gh")
  if [[ "$target" == *"gh-with-token-refresh.sh" ]]; then
    assert_pass "token-mode: gh symlink exists and points at gh-with-token-refresh.sh"
  else
    assert_fail "token-mode: gh symlink target is wrong: $target"
  fi
else
  assert_fail "token-mode: gh symlink NOT created in _LIB_AUTH_DIR"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-AUTH-SYM-002: symlink creation is NOT inside the GH_AUTH_MODE=app branch ==="
# ---------------------------------------------------------------------------
# Source-level lockdown: a future contributor must not move the symlink
# creation back inside the `if [[ "$GH_AUTH_MODE" == "app" ]]` branch.
#
# Strategy: find the line range of the app-mode branch
# (`if [[ "$GH_AUTH_MODE" == "app" ]]; then` to its matching `else`),
# then assert the symlink line is OUTSIDE that range.

sym_line=$(grep -n 'ln -sf .*gh-with-token-refresh.sh.*"\${_LIB_AUTH_DIR}/gh"' "$LIB_AUTH" | head -1 | cut -d: -f1)
app_branch_start=$(grep -n 'if \[\[ "\$GH_AUTH_MODE" == "app" \]\]' "$LIB_AUTH" | head -1 | cut -d: -f1)

if [[ -z "$sym_line" ]]; then
  assert_fail "could not locate the gh symlink-creation line in lib-auth.sh"
elif [[ -z "$app_branch_start" ]]; then
  assert_fail "could not locate the GH_AUTH_MODE=app branch in lib-auth.sh"
else
  # Find the `else` (or `fi` if there's no else) at the same indentation
  # as the matching `if`. The if at app_branch_start is indented with two
  # spaces (function-body indent). Look for `^  else` or `^  fi` after it.
  app_branch_end=$(awk -v start="$app_branch_start" '
    NR > start && /^  else$/ { print NR; exit }
    NR > start && /^  fi$/   { print NR; exit }
  ' "$LIB_AUTH")

  if [[ -z "$app_branch_end" ]]; then
    assert_fail "could not locate end of GH_AUTH_MODE=app branch (looked for ^  else or ^  fi)"
  elif (( sym_line > app_branch_start && sym_line < app_branch_end )); then
    assert_fail "symlink creation is INSIDE GH_AUTH_MODE=app branch (lines $app_branch_start..$app_branch_end), found at line $sym_line"
  else
    assert_pass "symlink creation is OUTSIDE GH_AUTH_MODE=app branch (line $sym_line, branch ends at $app_branch_end)"
  fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
