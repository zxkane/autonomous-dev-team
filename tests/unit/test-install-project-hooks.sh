#!/bin/bash
# test-install-project-hooks.sh — Tests for #153 install-project-hooks.sh.
#
# Verifies the project-side bootstrap script:
#   1. First-time install symlinks every dispatcher *.sh into <project>/scripts/
#   2. Real (non-symlink) project-local files are NOT overwritten
#   3. Re-run after upstream adds a new file picks up the new file
#   4. Re-run after upstream removes a file prunes the dangling symlink
#   5. bash -n syntax check
#   6. Aborts with a clear error if no skills tree is found
#   7. Git pre-push hook is installed by default
#   8. --no-git-hook suppresses pre-push
#
# Run: bash tests/unit/test-install-project-hooks.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$PROJECT_ROOT/skills/autonomous-common/scripts/install-project-hooks.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Set up a fixture skills tree under <repo>/.agents/skills/. Mirrors the
# layout npx skills add materializes. Two scripts in the dispatcher,
# representative of lib-* and wrapper-* shapes.
make_repo_with_skills() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init --quiet --initial-branch=main

  local disp="$repo/.agents/skills/autonomous-dispatcher/scripts"
  local common_hooks="$repo/.agents/skills/autonomous-common/hooks"
  mkdir -p "$disp" "$common_hooks"
  echo "# upstream lib-agent" > "$disp/lib-agent.sh"
  echo "# upstream lib-auth" > "$disp/lib-auth.sh"
  echo "# upstream autonomous-dev" > "$disp/autonomous-dev.sh"
  echo "# upstream autonomous-review" > "$disp/autonomous-review.sh"
  echo "# upstream hook stub" > "$common_hooks/lib.sh"
  chmod +x "$disp"/*.sh
}

# ---------------------------------------------------------------------------
echo "=== TC-IPH-01: clean install symlinks every dispatcher script ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo1"
make_repo_with_skills "$repo"

(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

for f in lib-agent.sh lib-auth.sh autonomous-dev.sh autonomous-review.sh; do
  if [[ -L "$repo/scripts/$f" ]]; then
    target="$(readlink "$repo/scripts/$f")"
    # Target should point to the dispatcher scripts dir. Path may be
    # absolute or relative depending on the implementation; just check
    # the basename matches.
    if [[ "$(basename "$target")" == "$f" ]]; then
      echo -e "  ${GREEN}PASS${NC}: $f symlinked"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${NC}: $f symlink target wrong: $target"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}FAIL${NC}: $f is not a symlink"
    FAIL=$((FAIL + 1))
  fi
done

if [[ -L "$repo/hooks" ]]; then
  echo -e "  ${GREEN}PASS${NC}: hooks dir symlinked"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: hooks dir not symlinked"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IPH-02: project-local files are NOT overwritten ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo2"
make_repo_with_skills "$repo"
mkdir -p "$repo/scripts"
echo "PROJECT=local" > "$repo/scripts/autonomous.conf"
echo "echo deploy" > "$repo/scripts/deploy.sh"
conf_before="$(cat "$repo/scripts/autonomous.conf")"

(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

if [[ ! -L "$repo/scripts/autonomous.conf" ]] && \
   [[ "$(cat "$repo/scripts/autonomous.conf")" == "$conf_before" ]]; then
  echo -e "  ${GREEN}PASS${NC}: autonomous.conf preserved (real file, contents intact)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: autonomous.conf was overwritten or symlinked"
  FAIL=$((FAIL + 1))
fi

if [[ ! -L "$repo/scripts/deploy.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC}: project-local deploy.sh preserved"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: project-local deploy.sh was symlinked over"
  FAIL=$((FAIL + 1))
fi

# Dispatcher scripts should still be symlinked even when project-local
# files coexist.
if [[ -L "$repo/scripts/lib-agent.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC}: dispatcher scripts symlinked alongside project-local files"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: dispatcher scripts NOT symlinked when project-local files coexist"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IPH-03: re-run picks up newly-added upstream file ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo3"
make_repo_with_skills "$repo"
(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

# Add a new lib upstream (simulating an `npx skills update`).
echo "# upstream lib-review-verdict" \
  > "$repo/.agents/skills/autonomous-dispatcher/scripts/lib-review-verdict.sh"
chmod +x "$repo/.agents/skills/autonomous-dispatcher/scripts/lib-review-verdict.sh"

(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

if [[ -L "$repo/scripts/lib-review-verdict.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC}: re-run picks up new lib-review-verdict.sh"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: re-run did NOT pick up new upstream file"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IPH-04: re-run prunes dangling symlink for removed upstream file ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo4"
make_repo_with_skills "$repo"
(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

# Remove a lib upstream.
rm "$repo/.agents/skills/autonomous-dispatcher/scripts/lib-auth.sh"

(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

if [[ ! -e "$repo/scripts/lib-auth.sh" ]] && [[ ! -L "$repo/scripts/lib-auth.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC}: dangling symlink lib-auth.sh pruned"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: dangling symlink not pruned (-e=$([[ -e "$repo/scripts/lib-auth.sh" ]] && echo yes || echo no), -L=$([[ -L "$repo/scripts/lib-auth.sh" ]] && echo yes || echo no))"
  FAIL=$((FAIL + 1))
fi

# Other symlinks should still be intact after pruning.
if [[ -L "$repo/scripts/lib-agent.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC}: pruning did not affect other symlinks"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: pruning collateral-damaged lib-agent.sh"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IPH-05: bash -n syntax check ==="
# ---------------------------------------------------------------------------
if bash -n "$INSTALLER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: installer passes bash -n"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: installer has syntax errors"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IPH-06: aborts with clear error if no skills tree found ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo6"
mkdir -p "$repo"
git -C "$repo" init --quiet --initial-branch=main

err="$(cd "$repo" && bash "$INSTALLER" --no-git-hook 2>&1 >/dev/null)" || rc=$?
rc="${rc:-0}"
if [[ "$rc" -ne 0 ]] && grep -q "autonomous-dispatcher" <<<"$err" \
   && grep -q "npx skills" <<<"$err"; then
  echo -e "  ${GREEN}PASS${NC}: missing skills tree errored with guidance"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: expected non-zero exit + guidance, got rc=$rc, err='$err'"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IPH-07: git pre-push hook installed by default ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo7"
make_repo_with_skills "$repo"

# We need a real install-git-pre-push.sh in the autonomous-common/hooks
# fixture for this to work end-to-end. Symlink the real one from the
# project repo so the installer's `install_per_worktree_pre_push` finds
# an actual installer script.
ln -sf "$PROJECT_ROOT/skills/autonomous-common/hooks/install-git-pre-push.sh" \
       "$repo/.agents/skills/autonomous-common/hooks/install-git-pre-push.sh"

(cd "$repo" && bash "$INSTALLER" >/dev/null 2>&1) || true

if [[ -x "$repo/.git/hooks/pre-push" ]]; then
  echo -e "  ${GREEN}PASS${NC}: git pre-push hook installed by default"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: default install did NOT install git pre-push"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IPH-08: --no-git-hook suppresses pre-push install ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo8"
make_repo_with_skills "$repo"

(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

if [[ ! -f "$repo/.git/hooks/pre-push" ]]; then
  echo -e "  ${GREEN}PASS${NC}: --no-git-hook prevented pre-push install"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: --no-git-hook did not suppress pre-push install"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
