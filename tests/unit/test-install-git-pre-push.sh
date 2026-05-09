#!/bin/bash
# test-install-git-pre-push.sh — Tests for #65 install-git-pre-push.sh.
#
# Verifies:
#   1. Hook is written to the correct per-worktree hooks dir.
#   2. Idempotency — re-running produces the same content.
#   3. The emitted hook actually blocks pushes to refs/heads/<trunk>.
#   4. The emitted hook allows pushes to non-trunk refs.
#   5. TRUNK_BRANCH override works.
#
# Run: bash tests/unit/test-install-git-pre-push.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$PROJECT_ROOT/skills/autonomous-common/hooks/install-git-pre-push.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "=== TC-GP-01: installs hook in correct location ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo1"
git -C "$TMPDIR/repo1" init --quiet --initial-branch=main
(cd "$TMPDIR/repo1" && bash "$INSTALLER" >/dev/null 2>&1)

if [[ -x "$TMPDIR/repo1/.git/hooks/pre-push" ]]; then
  echo -e "  ${GREEN}PASS${NC}: pre-push installed and executable"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: pre-push not installed at .git/hooks/pre-push"
  FAIL=$((FAIL + 1))
fi

if grep -q 'managed by autonomous-common' "$TMPDIR/repo1/.git/hooks/pre-push"; then
  echo -e "  ${GREEN}PASS${NC}: hook contains sentinel"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: hook missing sentinel"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GP-02: idempotency (re-running yields same content) ==="
# ---------------------------------------------------------------------------
content_before=$(sha256sum "$TMPDIR/repo1/.git/hooks/pre-push" | cut -d' ' -f1)
(cd "$TMPDIR/repo1" && bash "$INSTALLER" >/dev/null 2>&1)
content_after=$(sha256sum "$TMPDIR/repo1/.git/hooks/pre-push" | cut -d' ' -f1)
assert_eq "second install yields identical hook content" "$content_before" "$content_after"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GP-03: hook blocks push to refs/heads/main ==="
# ---------------------------------------------------------------------------
hook="$TMPDIR/repo1/.git/hooks/pre-push"
input="local-main abc123 refs/heads/main def456"
out=$(echo "$input" | bash "$hook" origin 2>&1; echo "rc=$?")
case "$out" in
  *"BLOCKED"*"rc=1"*) echo -e "  ${GREEN}PASS${NC}: push to refs/heads/main blocked"; PASS=$((PASS + 1)) ;;
  *) echo -e "  ${RED}FAIL${NC}: push to refs/heads/main NOT blocked: $out"; FAIL=$((FAIL + 1)) ;;
esac

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GP-04: hook allows push to feature branch ==="
# ---------------------------------------------------------------------------
input="local-feat abc123 refs/heads/feat/foo def456"
out=$(echo "$input" | bash "$hook" origin 2>&1; echo "rc=$?")
case "$out" in
  *"rc=0"*) echo -e "  ${GREEN}PASS${NC}: push to refs/heads/feat/foo allowed"; PASS=$((PASS + 1)) ;;
  *) echo -e "  ${RED}FAIL${NC}: push to refs/heads/feat/foo not allowed: $out"; FAIL=$((FAIL + 1)) ;;
esac

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GP-05: TRUNK_BRANCH=master override at install time ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo2"
git -C "$TMPDIR/repo2" init --quiet --initial-branch=master
(cd "$TMPDIR/repo2" && TRUNK_BRANCH=master bash "$INSTALLER" >/dev/null 2>&1)
hook2="$TMPDIR/repo2/.git/hooks/pre-push"
if grep -q 'refs/heads/master' "$hook2"; then
  echo -e "  ${GREEN}PASS${NC}: TRUNK_BRANCH=master baked into installed hook"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TRUNK_BRANCH=master NOT in installed hook"
  FAIL=$((FAIL + 1))
fi

# Verify the master-trunk hook actually blocks master pushes.
input="local-master abc123 refs/heads/master def456"
out=$(echo "$input" | bash "$hook2" origin 2>&1; echo "rc=$?")
case "$out" in
  *"BLOCKED"*"rc=1"*) echo -e "  ${GREEN}PASS${NC}: master-trunk hook blocks refs/heads/master"; PASS=$((PASS + 1)) ;;
  *) echo -e "  ${RED}FAIL${NC}: master-trunk hook did NOT block: $out"; FAIL=$((FAIL + 1)) ;;
esac

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-GP-06: pre-existing unmanaged hook is backed up ==="
# ---------------------------------------------------------------------------
mkdir -p "$TMPDIR/repo3"
git -C "$TMPDIR/repo3" init --quiet --initial-branch=main
mkdir -p "$TMPDIR/repo3/.git/hooks"
echo '#!/bin/bash' > "$TMPDIR/repo3/.git/hooks/pre-push"
echo '# pre-existing user hook' >> "$TMPDIR/repo3/.git/hooks/pre-push"
chmod +x "$TMPDIR/repo3/.git/hooks/pre-push"

(cd "$TMPDIR/repo3" && bash "$INSTALLER" >/dev/null 2>&1)

backup_count=$(find "$TMPDIR/repo3/.git/hooks" -name 'pre-push.bak.*' | wc -l)
if (( backup_count == 1 )); then
  echo -e "  ${GREEN}PASS${NC}: unmanaged hook backed up before overwrite"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: expected 1 backup file, found $backup_count"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
