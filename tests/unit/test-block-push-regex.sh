#!/bin/bash
# test-block-push-regex.sh — Regression tests for #64 in block-push-to-main.sh.
#
# Covers all 8 cases from the issue's "Proposed scope" table. The test
# constructs a throwaway git repo with both `main` and a feature branch,
# checks out the relevant branch, then feeds the hook a JSON input
# matching what Claude Code would deliver and asserts the exit code.
#
# Run: bash tests/unit/test-block-push-regex.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_ROOT/skills/autonomous-common/hooks/block-push-to-main.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Set up a throwaway repo so `git rev-parse --abbrev-ref HEAD` returns
# a real branch name during the hook run. The hook calls `git` for the
# current branch; tests must not contaminate the worktree we're running
# in. Use a temp dir + `cd` into it for each case.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

setup_repo() {
  local branch="$1"
  rm -rf "$TMPDIR/repo"
  mkdir -p "$TMPDIR/repo"
  git -C "$TMPDIR/repo" init --quiet --initial-branch=main
  git -C "$TMPDIR/repo" -c user.email=test@test -c user.name=test commit \
    --quiet --allow-empty -m init
  if [[ "$branch" != "main" ]]; then
    git -C "$TMPDIR/repo" checkout --quiet -b "$branch"
  fi
}

# Run the hook from inside the throwaway repo so its `git rev-parse` sees
# the right current branch. CLAUDE_PROJECT_DIR is set so the hook's
# state-dir helpers work without writing into the actual project.
run_hook() {
  local cmd="$1"
  local input
  input=$(printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')")
  (cd "$TMPDIR/repo" && CLAUDE_PROJECT_DIR="$TMPDIR/repo" bash "$HOOK" <<<"$input")
  echo $?
}

assert_exit() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected exit=$expected, actual exit=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

# Set up a SECOND, unrelated repo (with `main` checked out) to stand in for
# another repository the agent legitimately pushes to — most importantly a
# project's separate `<project>.wiki.git`, whose default and only branch is
# `main` and which has no PR flow at all.
setup_other_repo() {
  local name="$1"
  rm -rf "$TMPDIR/$name"
  mkdir -p "$TMPDIR/$name"
  git -C "$TMPDIR/$name" init --quiet --initial-branch=main
  git -C "$TMPDIR/$name" -c user.email=test@test -c user.name=test commit \
    --quiet --allow-empty -m init
}

# Run the hook with cwd = the project repo (what Claude Code actually passes)
# while the command targets a different repo.
run_hook_cwd() {
  local cmd="$1" cwd="$2"
  local input
  input=$(printf '{"tool_input":{"command":%s},"cwd":%s}' \
    "$(jq -Rn --arg c "$cmd" '$c')" "$(jq -Rn --arg d "$cwd" '$d')")
  (cd "$cwd" && CLAUDE_PROJECT_DIR="$TMPDIR/repo" bash "$HOOK" <<<"$input")
  echo $?
}

# ===========================================================================
# TC-BP-01: Bare push from trunk → block
# ===========================================================================
echo "=== TC-BP-01: bare push from main → block ==="
setup_repo main
out=$(run_hook "git push")
assert_exit "bare push from main blocked" "2" "$out"

# ===========================================================================
# TC-BP-02: Bare push from feat branch → allow
# ===========================================================================
echo ""
echo "=== TC-BP-02: bare push from feat → allow ==="
setup_repo feat/x
out=$(run_hook "git push")
assert_exit "bare push from feat allowed" "0" "$out"

# ===========================================================================
# TC-BP-03: Feature push from trunk-checked-out worktree → allow (#64 case A)
# ===========================================================================
echo ""
echo "=== TC-BP-03: feature push from trunk worktree (#64 case A) → allow ==="
setup_repo main
out=$(run_hook "git push -u origin feat/foo")
assert_exit "feature push from trunk worktree allowed (#64 case A regression guard)" "0" "$out"

# ===========================================================================
# TC-BP-04: Feature push from feat worktree → allow
# ===========================================================================
echo ""
echo "=== TC-BP-04: feature push from feat worktree → allow ==="
setup_repo feat/x
out=$(run_hook "git push -u origin feat/foo")
assert_exit "feature push from feat worktree allowed" "0" "$out"

# ===========================================================================
# TC-BP-05: Explicit short refspec to main → block
# ===========================================================================
echo ""
echo "=== TC-BP-05: explicit short refspec to main → block ==="
setup_repo feat/x
out=$(run_hook "git push origin feat:main")
assert_exit "explicit short refspec to main blocked" "2" "$out"

# ===========================================================================
# TC-BP-06: Explicit fully-qualified refspec to main → block (#64 case B)
# ===========================================================================
echo ""
echo "=== TC-BP-06: fully-qualified refspec to main (#64 case B) → block ==="
setup_repo feat/x
out=$(run_hook "git push origin HEAD:refs/heads/main")
assert_exit "fully-qualified refspec to main blocked (#64 case B regression guard)" "2" "$out"

# ===========================================================================
# TC-BP-07: --all flag → block (matrix push that includes trunk)
# ===========================================================================
echo ""
echo "=== TC-BP-07: --all flag → block ==="
setup_repo feat/x
out=$(run_hook "git push --all origin")
assert_exit "--all blocked" "2" "$out"

# ===========================================================================
# TC-BP-08: --mirror flag → block
# ===========================================================================
echo ""
echo "=== TC-BP-08: --mirror flag → block ==="
setup_repo feat/x
out=$(run_hook "git push --mirror origin")
assert_exit "--mirror blocked" "2" "$out"

# ===========================================================================
# TC-BP-09: --tags flag (tags only, doesn't write trunk) → allow
# ===========================================================================
echo ""
echo "=== TC-BP-09: --tags only → allow ==="
setup_repo feat/x
out=$(run_hook "git push --tags origin")
assert_exit "--tags only push allowed" "0" "$out"

# ===========================================================================
# TC-BP-10: TRUNK_BRANCH=master override
# ===========================================================================
echo ""
echo "=== TC-BP-10: TRUNK_BRANCH=master override ==="
rm -rf "$TMPDIR/repo"
mkdir -p "$TMPDIR/repo"
git -C "$TMPDIR/repo" init --quiet --initial-branch=master
git -C "$TMPDIR/repo" -c user.email=test@test -c user.name=test commit \
  --quiet --allow-empty -m init
git -C "$TMPDIR/repo" checkout --quiet -b feat/x
input=$(printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "git push origin HEAD:refs/heads/master" '$c')")
actual=$(cd "$TMPDIR/repo" && CLAUDE_PROJECT_DIR="$TMPDIR/repo" TRUNK_BRANCH=master bash "$HOOK" <<<"$input"; echo $?)
assert_exit "TRUNK_BRANCH=master + push to refs/heads/master blocked" "2" "$actual"

# ===========================================================================
# TC-BP-11: not-a-push command → allow (sanity)
# ===========================================================================
echo ""
echo "=== TC-BP-11: not a push command → allow ==="
setup_repo main
out=$(run_hook "git status")
assert_exit "git status (not a push) allowed" "0" "$out"

# ===========================================================================
# TC-BP-12: push to ANOTHER repo's main via `git -C <other>` → allow
# ===========================================================================
# Trunk protection guards THIS project's repo. A push whose destination
# repository is a different one is not this guard's business: the agent may
# legitimately be publishing to a sibling checkout, a vendored dependency, or
# a wiki. Blocking it is a pure false positive — there is no PR flow here to
# route the change through.
echo ""
echo "=== TC-BP-12: push another repo's main via -C → allow ==="
setup_repo main
setup_other_repo other
out=$(run_hook_cwd "git -C $TMPDIR/other push origin main" "$TMPDIR/repo")
assert_exit "push to another repo's main via -C allowed" "0" "$out"

# ===========================================================================
# TC-BP-13: push to a .wiki.git clone's main via `cd && git push` → allow
# ===========================================================================
# The real-world shape that motivated this: publishing a design doc to a
# GitLab project wiki. `<project>.wiki.git` is a separate repository whose
# only branch is `main`, so the guard fired on every wiki update and the docs
# could not be pushed at all.
echo ""
echo "=== TC-BP-13: push to <project>.wiki.git main via cd → allow ==="
setup_repo main
setup_other_repo project.wiki
out=$(run_hook_cwd "cd $TMPDIR/project.wiki && git push origin main" "$TMPDIR/repo")
assert_exit "push to <project>.wiki.git main allowed" "0" "$out"

# ===========================================================================
# TC-BP-14: push THIS repo's main via `git -C <self>` → still block
# ===========================================================================
# The scoping must not become an escape hatch: naming the project's own repo
# explicitly still routes through trunk protection.
echo ""
echo "=== TC-BP-14: push own repo main via -C → still block ==="
setup_repo main
out=$(run_hook_cwd "git -C $TMPDIR/repo push origin main" "$TMPDIR/repo")
assert_exit "push to own repo's main via -C still blocked" "2" "$out"

# ===========================================================================
# TC-BP-15: push main from a linked worktree of THIS repo → still block
# ===========================================================================
# A linked worktree shares its git-common-dir with the project repo, so it
# must still count as "this repo" — otherwise every guard could be sidestepped
# by committing from a worktree.
echo ""
echo "=== TC-BP-15: push own repo main from a linked worktree → still block ==="
setup_repo main
git -C "$TMPDIR/repo" worktree add --quiet -b feat/wt "$TMPDIR/wt" >/dev/null 2>&1
out=$(run_hook_cwd "git push origin HEAD:refs/heads/main" "$TMPDIR/wt")
assert_exit "push to own repo's main from linked worktree still blocked" "2" "$out"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
