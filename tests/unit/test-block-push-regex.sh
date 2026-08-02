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

# The project's own remote. [INV-148] compares push DESTINATIONS, so every
# fixture repo needs an `origin`: what identifies "this project" is the URL a
# push lands on, not which local directory issued it.
PROJECT_URL="https://github.com/zxkane/autonomous-dev-team.git"
# A wiki is `<project>.wiki.git` on both GitHub and GitLab — a different URL
# under the same host+path, which is why it needs no configuration to allow.
WIKI_URL="https://github.com/zxkane/autonomous-dev-team.wiki.git"
trap 'rm -rf "$TMPDIR"' EXIT

setup_repo() {
  local branch="$1"
  rm -rf "$TMPDIR/repo"
  mkdir -p "$TMPDIR/repo"
  git -C "$TMPDIR/repo" init --quiet --initial-branch=main
  git -C "$TMPDIR/repo" -c user.email=test@test -c user.name=test commit \
    --quiet --allow-empty -m init
  # [INV-148]: the destination comparison needs the project's own remote.
  git -C "$TMPDIR/repo" remote add origin "$PROJECT_URL"
  if [[ "$branch" != "main" ]]; then
    git -C "$TMPDIR/repo" checkout --quiet -b "$branch"
  fi
}

# Build the hook's stdin payload — the JSON shape Claude Code delivers. `cwd`
# is included only when passed, matching the two real shapes (a plain Bash call
# carries no cwd key; a resolved one does).
hook_input() {
  local cmd="$1" cwd="${2:-}"
  if [[ -n "$cwd" ]]; then
    printf '{"tool_input":{"command":%s},"cwd":%s}' \
      "$(jq -Rn --arg c "$cmd" '$c')" "$(jq -Rn --arg d "$cwd" '$d')"
  else
    printf '{"tool_input":{"command":%s}}' "$(jq -Rn --arg c "$cmd" '$c')"
  fi
}

# Run the hook from inside the throwaway repo so its `git rev-parse` sees
# the right current branch. CLAUDE_PROJECT_DIR is set so the hook's
# state-dir helpers work without writing into the actual project.
run_hook() {
  local cmd="$1"
  (cd "$TMPDIR/repo" && CLAUDE_PROJECT_DIR="$TMPDIR/repo" \
    bash "$HOOK" <<<"$(hook_input "$cmd")")
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

# Set up a SECOND repo (with `main` checked out) standing in for another
# repository the agent legitimately pushes to. `url` is its `origin`; pass the
# wiki URL for the wiki case, or an unrelated URL for a sibling checkout.
setup_other_repo() {
  local name="$1" url="${2:-https://github.com/other-owner/other-repo.git}"
  rm -rf "${TMPDIR:?}/$name"
  mkdir -p "$TMPDIR/$name"
  git -C "$TMPDIR/$name" init --quiet --initial-branch=main
  git -C "$TMPDIR/$name" -c user.email=test@test -c user.name=test commit \
    --quiet --allow-empty -m init
  git -C "$TMPDIR/$name" remote add origin "$url"
}

# Run the hook with an explicit cwd, and with the project anchor exported the
# way the wrappers do ([INV-131] pattern). The anchor is what lets a bare
# `git push` issued from INSIDE another repo still be judged against this
# project — the hook's own cwd is the pushing repo, not the project.
run_hook_cwd() {
  local cmd="$1" cwd="$2"
  (cd "$cwd" \
    && CLAUDE_PROJECT_DIR="$TMPDIR/repo" \
       AUTONOMOUS_PROJECT_DIR="$TMPDIR/repo" \
       bash "$HOOK" <<<"$(hook_input "$cmd" "$cwd")")
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
# Trunk protection guards THIS project's remote trunk. A push whose
# DESTINATION is a different repository is not this guard's business: the agent
# may legitimately be publishing to a sibling checkout or a vendored
# dependency. Blocking it is a pure false positive — there is no PR flow here
# to route the change through.
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
# project wiki. `<project>.wiki.git` is a separate repository whose only branch
# is `main`, so the guard fired on every wiki update and the docs could not be
# pushed at all. No configuration derives this — the wiki URL simply differs
# from the project URL, so the same destination comparison allows it.
echo ""
echo "=== TC-BP-13: push to <project>.wiki.git main via cd → allow ==="
setup_repo main
setup_other_repo project.wiki "$WIKI_URL"
out=$(run_hook_cwd "cd $TMPDIR/project.wiki && git push origin main" "$TMPDIR/repo")
assert_exit "push to <project>.wiki.git main allowed" "0" "$out"

# ===========================================================================
# TC-BP-13b: BARE `git push` from inside the wiki clone → allow
# ===========================================================================
# The most natural agent workflow: `cd` into the wiki in one turn, then push in
# the next. The hook's own cwd IS the wiki here, so a cwd-anchored identity
# check would compare the wiki against itself and block — which is why the
# project anchor must come from the wrapper-exported value, not `pwd`.
# Pinned against regression to a pwd-derived anchor.
echo ""
echo "=== TC-BP-13b: bare push from inside the wiki clone → allow ==="
setup_repo main
setup_other_repo project.wiki "$WIKI_URL"
out=$(run_hook_cwd "git push" "$TMPDIR/project.wiki")
assert_exit "bare push from inside wiki clone allowed" "0" "$out"
out=$(run_hook_cwd "git push origin main" "$TMPDIR/project.wiki")
assert_exit "explicit push origin main from inside wiki clone allowed" "0" "$out"

# ===========================================================================
# TC-BP-13c: no project anchor exported → fail closed
# ===========================================================================
# With no anchor the hook falls back to its cwd, so the wiki compares equal to
# itself and the push is CHECKED, not waved through. Uncertainty must never
# grant a trunk push; the wiki allowance is a capability the wrapper grants by
# exporting the anchor, never an inference from an absent one.
echo ""
echo "=== TC-BP-13c: bare push from wiki with NO anchor → block (fail closed) ==="
setup_repo main
setup_other_repo project.wiki "$WIKI_URL"
out=$( (cd "$TMPDIR/project.wiki" && env -u AUTONOMOUS_PROJECT_DIR -u CLAUDE_PROJECT_DIR \
  bash "$HOOK" <<<"$(hook_input "git push origin main")" >/dev/null 2>&1); echo $? )
assert_exit "bare wiki push with no anchor fails closed" "2" "$out"

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
# A linked worktree pushes to the same destination as the project repo, so it
# must still count as "this project" — otherwise every guard could be
# sidestepped by pushing from a worktree.
echo ""
echo "=== TC-BP-15: push own repo main from a linked worktree → still block ==="
setup_repo main
git -C "$TMPDIR/repo" worktree add --quiet -b feat/wt "$TMPDIR/wt" >/dev/null 2>&1
out=$(run_hook_cwd "git push origin HEAD:refs/heads/main" "$TMPDIR/wt")
assert_exit "push to own repo's main from linked worktree still blocked" "2" "$out"

# ===========================================================================
# TC-BP-16: SECOND INDEPENDENT CLONE of this project's remote → still block
# ===========================================================================
# The security boundary a local-identity check cannot express. This clone has
# its own git-common-dir, so any "is it the same local repo?" comparison calls
# it a different repository and allows the push — but its `origin` is THIS
# project, so the push lands on the very trunk the guard protects. Comparing
# destinations is what makes this a block. Pinned against regression to a
# local-identity comparison.
echo ""
echo "=== TC-BP-16: push from a 2nd clone of this project's remote → still block ==="
setup_repo main
setup_other_repo clone2 "$PROJECT_URL"
out=$(run_hook_cwd "git -C $TMPDIR/clone2 push origin main" "$TMPDIR/repo")
assert_exit "push to own trunk from a 2nd clone blocked (-C form)" "2" "$out"
out=$(run_hook_cwd "cd $TMPDIR/clone2 && git push origin main" "$TMPDIR/repo")
assert_exit "push to own trunk from a 2nd clone blocked (cd form)" "2" "$out"
out=$(run_hook_cwd "git -C $TMPDIR/clone2 push origin HEAD:refs/heads/main" "$TMPDIR/repo")
assert_exit "push to own trunk from a 2nd clone blocked (HEAD:refs form)" "2" "$out"

# ===========================================================================
# TC-BP-17: URL spelling differences do not defeat the comparison
# ===========================================================================
# The same repository reached over SSH shorthand, with credentials, a port, or
# without the `.git` suffix must still compare EQUAL to the project — else the
# TC-BP-16 bypass reopens under a different spelling.
echo ""
echo "=== TC-BP-17: same destination, different URL spellings → still block ==="
setup_repo main
for _url in \
  "git@github.com:zxkane/autonomous-dev-team.git" \
  "git@github.com:zxkane/autonomous-dev-team" \
  "https://user:token@github.com/zxkane/autonomous-dev-team.git" \
  "ssh://git@github.com:22/zxkane/autonomous-dev-team.git" \
  "https://github.com/zxkane/Autonomous-Dev-Team.git"; do
  setup_other_repo spelling "$_url"
  out=$(run_hook_cwd "git -C $TMPDIR/spelling push origin main" "$TMPDIR/repo")
  assert_exit "spelling '$_url' still blocked" "2" "$out"
done

# ===========================================================================
# TC-BP-18: a wiki-shaped path is NOT special-cased into the project
# ===========================================================================
# Guards the normalization: only a trailing `.git` is stripped, never `.wiki`.
# If `.wiki` were folded away, a wiki push would compare equal to the project
# and be blocked again — the original bug.
echo ""
echo "=== TC-BP-18: wiki URL canonicalizes distinctly from the project URL ==="
setup_repo main
setup_other_repo wikispell "git@github.com:zxkane/autonomous-dev-team.wiki.git"
out=$(run_hook_cwd "git -C $TMPDIR/wikispell push origin main" "$TMPDIR/repo")
assert_exit "wiki over SSH shorthand allowed" "0" "$out"

# ===========================================================================
# TC-BP-19: PUSH_ALLOWED_REMOTE_URLS exempts a named destination
# ===========================================================================
# The explicit, auditable opt-out for a destination that IS this project's
# trunk but which the operator has decided may be pushed directly. An
# unrelated entry must NOT exempt anything, and matching is spelling-insensitive.
echo ""
echo "=== TC-BP-19: PUSH_ALLOWED_REMOTE_URLS allowlist ==="
setup_repo main
run_hook_allow() {
  local cmd="$1" allow="$2"
  (cd "$TMPDIR/repo" \
    && AUTONOMOUS_PROJECT_DIR="$TMPDIR/repo" PUSH_ALLOWED_REMOTE_URLS="$allow" \
       bash "$HOOK" <<<"$(hook_input "$cmd")" >/dev/null 2>&1)
  echo $?
}
out=$(run_hook_allow "git push origin main" "$PROJECT_URL")
assert_exit "own trunk allowed when destination is allowlisted" "0" "$out"
out=$(run_hook_allow "git push origin main" "git@github.com:zxkane/autonomous-dev-team")
assert_exit "allowlist matches a different spelling of the same destination" "0" "$out"
out=$(run_hook_allow "git push origin main" "https://github.com/other/unrelated.git")
assert_exit "unrelated allowlist entry does not exempt own trunk" "2" "$out"
out=$(run_hook_allow "git push origin main" "")
assert_exit "empty allowlist blocks own trunk" "2" "$out"
# An entry holding a glob metachar must stay literal — never expand against the
# hook's cwd (which contains files, so an unguarded split could match one).
out=$(run_hook_allow "git push origin main" "https://github.com/zxkane/*")
assert_exit "glob-shaped allowlist entry does not exempt own trunk" "2" "$out"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
