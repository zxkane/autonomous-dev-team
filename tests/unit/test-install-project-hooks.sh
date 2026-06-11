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
  # lib-config.sh is the first sibling every entry sources; --doctor checks for
  # its presence in the skill tree as the entry-resolution sanity probe.
  echo "# upstream lib-config" > "$disp/lib-config.sh"
  echo "# upstream autonomous-dev" > "$disp/autonomous-dev.sh"
  echo "# upstream autonomous-review" > "$disp/autonomous-review.sh"
  # The two SSM helpers + their shared lib-ssm.sh. The SSM helpers source
  # lib-ssm.sh from their OWN dir (readlink-free, TC-EB-008), so they must NOT
  # be symlinked project-side (where lib-ssm.sh is absent) — see TC-ENTRY-SHIM-032.
  echo "# upstream dispatch-remote-aws-ssm" > "$disp/dispatch-remote-aws-ssm.sh"
  echo "# upstream liveness-check-remote-aws-ssm" > "$disp/liveness-check-remote-aws-ssm.sh"
  echo "# upstream lib-ssm" > "$disp/lib-ssm.sh"
  echo "# upstream hook stub" > "$common_hooks/lib.sh"
  chmod +x "$disp"/*.sh
}

# ---------------------------------------------------------------------------
echo "=== TC-IPH-01: clean install symlinks ENTRY scripts, NOT lib-*.sh (#227) ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo1"
make_repo_with_skills "$repo"

(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

# Entry scripts (NOT lib-*.sh) must be symlinked.
for f in autonomous-dev.sh autonomous-review.sh; do
  if [[ -L "$repo/scripts/$f" ]]; then
    target="$(readlink "$repo/scripts/$f")"
    # Target should point to the dispatcher scripts dir. Path may be
    # absolute or relative depending on the implementation; just check
    # the basename matches.
    if [[ "$(basename "$target")" == "$f" ]]; then
      echo -e "  ${GREEN}PASS${NC}: entry $f symlinked"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${NC}: $f symlink target wrong: $target"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}FAIL${NC}: entry $f is not a symlink"
    FAIL=$((FAIL + 1))
  fi
done

# lib-*.sh must NOT be symlinked ([INV-65]: entries source them from the skill
# tree). This is the structural change that kills the missing-lib-symlink class.
for f in lib-agent.sh lib-auth.sh; do
  if [[ ! -e "$repo/scripts/$f" ]]; then
    echo -e "  ${GREEN}PASS${NC}: lib $f NOT symlinked (resolved from skill tree)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: lib $f was symlinked (should be skipped post-#227)"
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

# Dispatcher ENTRY scripts should still be symlinked even when project-local
# files coexist.
if [[ -L "$repo/scripts/autonomous-dev.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC}: entry scripts symlinked alongside project-local files"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: entry scripts NOT symlinked when project-local files coexist"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IPH-03: re-run picks up new ENTRY point; new lib stays unsymlinked ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo3"
make_repo_with_skills "$repo"
(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

# Add a new ENTRY point upstream (simulating an `npx skills update`).
echo "# upstream new entry" \
  > "$repo/.agents/skills/autonomous-dispatcher/scripts/setup-labels.sh"
# Add a new LIB upstream — this is the #227 regression target: it must NOT be
# symlinked, and the wrapper must still source it from the skill tree.
echo "# upstream lib-review-verdict" \
  > "$repo/.agents/skills/autonomous-dispatcher/scripts/lib-review-verdict.sh"
chmod +x "$repo/.agents/skills/autonomous-dispatcher/scripts/"*.sh

(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

if [[ -L "$repo/scripts/setup-labels.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC}: re-run picks up new ENTRY point setup-labels.sh"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: re-run did NOT pick up new entry point"
  FAIL=$((FAIL + 1))
fi
if [[ ! -e "$repo/scripts/lib-review-verdict.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC}: new lib-review-verdict.sh NOT symlinked (#227 — no re-run needed for libs)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: new lib was symlinked (defeats #227)"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-IPH-04: re-run prunes dangling AND stale per-lib symlinks ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo4"
make_repo_with_skills "$repo"
(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

# Simulate a pre-#227 install that had per-lib symlinks: seed them by hand.
ln -s "$repo/.agents/skills/autonomous-dispatcher/scripts/lib-agent.sh" \
      "$repo/scripts/lib-agent.sh"
ln -s "$repo/.agents/skills/autonomous-dispatcher/scripts/lib-auth.sh" \
      "$repo/scripts/lib-auth.sh"

# Remove an ENTRY point upstream (dangling-symlink prune path).
rm "$repo/.agents/skills/autonomous-dispatcher/scripts/autonomous-review.sh"

(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

if [[ ! -e "$repo/scripts/autonomous-review.sh" ]] && [[ ! -L "$repo/scripts/autonomous-review.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC}: dangling entry symlink autonomous-review.sh pruned"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: dangling entry symlink not pruned"
  FAIL=$((FAIL + 1))
fi

# Stale per-lib symlinks must be pruned (live target, but no longer needed).
if [[ ! -e "$repo/scripts/lib-agent.sh" ]] && [[ ! -L "$repo/scripts/lib-agent.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC}: stale per-lib symlink lib-agent.sh pruned (#227)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: stale per-lib symlink lib-agent.sh NOT pruned"
  FAIL=$((FAIL + 1))
fi

# The surviving entry symlink should still be intact after pruning.
if [[ -L "$repo/scripts/autonomous-dev.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC}: pruning did not affect other entry symlinks"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: pruning collateral-damaged autonomous-dev.sh"
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
echo "=== TC-ENTRY-SHIM-020: --dry-run makes ZERO filesystem changes (#227) ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo-dry"
make_repo_with_skills "$repo"
# Snapshot the project tree (paths + inodes + mtimes) BEFORE the dry-run.
snapshot() { find "$1" -printf '%p|%i|%T@\n' 2>/dev/null | sort; }
before="$(snapshot "$repo")"
out="$(cd "$repo" && bash "$INSTALLER" --no-git-hook --dry-run 2>&1)" || true
after="$(snapshot "$repo")"
if [[ "$before" == "$after" ]]; then
  echo -e "  ${GREEN}PASS${NC}: --dry-run left the tree byte-identical (no inode/mtime change)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: --dry-run mutated the filesystem:"
  diff <(echo "$before") <(echo "$after") | sed 's/^/    /'
  FAIL=$((FAIL + 1))
fi
# No scripts/ symlinks should have been created.
if [[ ! -e "$repo/scripts/autonomous-dev.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC}: --dry-run created no entry symlink"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: --dry-run created scripts/autonomous-dev.sh"
  FAIL=$((FAIL + 1))
fi
# It should still PRINT a plan.
if grep -q 'dry-run' <<<"$out" && grep -q 'autonomous-dev.sh' <<<"$out"; then
  echo -e "  ${GREEN}PASS${NC}: --dry-run printed the planned changes"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: --dry-run did not print a plan; got: $out"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ENTRY-SHIM-023: --doctor clean project exits 0 ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo-doc-ok"
make_repo_with_skills "$repo"
(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)
# A real conf at mode 600 so doctor is fully clean.
printf 'PROJECT_ID=x\n' > "$repo/scripts/autonomous.conf"
chmod 600 "$repo/scripts/autonomous.conf"
doc_out="$(cd "$repo" && bash "$INSTALLER" --doctor 2>&1)"; doc_rc=$?
if [[ "$doc_rc" -eq 0 ]] && grep -q 'Doctor: OK' <<<"$doc_out"; then
  echo -e "  ${GREEN}PASS${NC}: --doctor clean → exit 0 + OK"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: --doctor on clean project rc=$doc_rc out=$doc_out"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ENTRY-SHIM-024: --doctor detects a broken entry symlink ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo-doc-broken"
make_repo_with_skills "$repo"
(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)
printf 'PROJECT_ID=x\n' > "$repo/scripts/autonomous.conf"
chmod 600 "$repo/scripts/autonomous.conf"
# Break one entry symlink by removing its target.
rm "$repo/.agents/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
doc_out="$(cd "$repo" && bash "$INSTALLER" --doctor 2>&1)"; doc_rc=$?
if [[ "$doc_rc" -ne 0 ]] && grep -qiE 'broken|missing' <<<"$doc_out" \
   && grep -q 'autonomous-dev.sh' <<<"$doc_out"; then
  echo -e "  ${GREEN}PASS${NC}: --doctor flagged the broken entry symlink (rc=$doc_rc)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: --doctor missed broken symlink rc=$doc_rc out=$doc_out"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ENTRY-SHIM-025: --doctor flags a missing autonomous.conf ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo-doc-noconf"
make_repo_with_skills "$repo"
(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)
# No autonomous.conf at all.
doc_out="$(cd "$repo" && bash "$INSTALLER" --doctor 2>&1)"; doc_rc=$?
if [[ "$doc_rc" -ne 0 ]] && grep -q 'autonomous.conf is MISSING' <<<"$doc_out"; then
  echo -e "  ${GREEN}PASS${NC}: --doctor flagged missing conf (rc=$doc_rc)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: --doctor missed missing conf rc=$doc_rc out=$doc_out"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ENTRY-SHIM-026: --doctor is read-only (zero fs mutation) ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo-doc-readonly"
make_repo_with_skills "$repo"
(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)
printf 'PROJECT_ID=x\n' > "$repo/scripts/autonomous.conf"
chmod 600 "$repo/scripts/autonomous.conf"
# Seed a stale per-lib symlink; --doctor should REPORT but NOT prune it.
ln -s "$repo/.agents/skills/autonomous-dispatcher/scripts/lib-agent.sh" \
      "$repo/scripts/lib-agent.sh"
before="$(snapshot "$repo")"
(cd "$repo" && bash "$INSTALLER" --doctor >/dev/null 2>&1) || true
after="$(snapshot "$repo")"
if [[ "$before" == "$after" ]]; then
  echo -e "  ${GREEN}PASS${NC}: --doctor mutated nothing (stale lib symlink left intact)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: --doctor mutated the filesystem"
  diff <(echo "$before") <(echo "$after") | sed 's/^/    /'
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ENTRY-SHIM-027: real project-local files never pruned ==="
# ---------------------------------------------------------------------------
repo="$TMPDIR/repo-local-safe"
make_repo_with_skills "$repo"
mkdir -p "$repo/scripts"
echo "echo deploy" > "$repo/scripts/deploy.sh"          # real file, not symlink
# A project-local symlink whose target is OUTSIDE the dispatcher dir — must be
# left alone by the prune loop.
echo "echo helper" > "$repo/helper-real.sh"
ln -s "$repo/helper-real.sh" "$repo/scripts/my-helper.sh"
(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)
ok=1
[[ -f "$repo/scripts/deploy.sh" && ! -L "$repo/scripts/deploy.sh" ]] || ok=0
[[ -L "$repo/scripts/my-helper.sh" ]] || ok=0
if [[ "$ok" -eq 1 ]]; then
  echo -e "  ${GREEN}PASS${NC}: project-local deploy.sh + non-dispatcher symlink preserved"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: installer disturbed a project-local file/symlink"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-ENTRY-SHIM-032: *-aws-ssm.sh NOT symlinked project-side + pruned (#227 P1) ==="
# ---------------------------------------------------------------------------
# The two SSM helpers source their shared lib-ssm.sh from their OWN unresolved
# dir (readlink-free for the PATH-scrubbed TC-EB-008). Because the installer no
# longer symlinks lib-*.sh (incl. lib-ssm.sh), a project-side symlink to an SSM
# helper would resolve lib-ssm.sh in <project>/scripts/ → `No such file` crash
# when invoked directly (e.g. `bash scripts/dispatch-remote-aws-ssm.sh`). The
# dispatcher invokes them from the skill tree (dispatch() via LIB_DIR; liveness
# via lib-dispatch.sh's skill-tree BASH_SOURCE), so they need NO project-side
# symlink. The installer therefore EXCLUDES them from the entry manifest and
# PRUNES any pre-existing project-side symlink to them.
repo="$TMPDIR/repo-ssm"
make_repo_with_skills "$repo"
# Pre-seed a stale pre-fix project-side symlink to each SSM helper (a pre-#227
# install would have created these).
mkdir -p "$repo/scripts"
ln -s "$repo/.agents/skills/autonomous-dispatcher/scripts/dispatch-remote-aws-ssm.sh" \
      "$repo/scripts/dispatch-remote-aws-ssm.sh"
ln -s "$repo/.agents/skills/autonomous-dispatcher/scripts/liveness-check-remote-aws-ssm.sh" \
      "$repo/scripts/liveness-check-remote-aws-ssm.sh"

(cd "$repo" && bash "$INSTALLER" --no-git-hook >/dev/null 2>&1)

ssm_ok=1
for f in dispatch-remote-aws-ssm.sh liveness-check-remote-aws-ssm.sh; do
  if [[ -e "$repo/scripts/$f" || -L "$repo/scripts/$f" ]]; then
    echo -e "  ${RED}FAIL${NC}: $f is still present project-side (should be pruned/skipped)"
    ssm_ok=0; FAIL=$((FAIL + 1))
  fi
done
if [[ "$ssm_ok" -eq 1 ]]; then
  echo -e "  ${GREEN}PASS${NC}: both *-aws-ssm.sh pruned + not re-symlinked (no project-side footgun)"
  PASS=$((PASS + 1))
fi
# The real entry points must still be symlinked (regression guard).
if [[ -L "$repo/scripts/autonomous-dev.sh" ]]; then
  echo -e "  ${GREEN}PASS${NC}: real entry points still symlinked (exclusion is SSM-scoped)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: SSM exclusion collateral-damaged a real entry symlink"
  FAIL=$((FAIL + 1))
fi
# --doctor must NOT flag the (correctly-absent) SSM helpers as missing entries.
doc_out="$(cd "$repo" && printf 'PROJECT_ID=x\n' > "$repo/scripts/autonomous.conf"; chmod 600 "$repo/scripts/autonomous.conf"; bash "$INSTALLER" --doctor 2>&1)"; doc_rc=$?
if [[ "$doc_rc" -eq 0 ]] && ! grep -qE 'missing entry symlink: scripts/(dispatch-remote|liveness-check)-aws-ssm' <<<"$doc_out"; then
  echo -e "  ${GREEN}PASS${NC}: --doctor does not flag the excluded SSM helpers as missing"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: --doctor wrongly flags SSM helpers (rc=$doc_rc)"
  echo "$doc_out" | sed 's/^/    /'
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
