#!/bin/bash
# test-block-push-regex.sh — Layer-1 trunk-protection regression tests.
#
# Covers the original #64 cases, destination scoping, fail-closed behavior, and
# push-option parsing. Each case runs in a throwaway repository and feeds the
# hook the JSON input shape delivered by supported coding agents.
#
# Run: bash tests/unit/test-block-push-regex.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOK="$PROJECT_ROOT/skills/autonomous-common/hooks/block-push-to-main.sh"
LIB_PUSH="$PROJECT_ROOT/skills/autonomous-common/hooks/lib-push.sh"

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

run_hook_bounded() {
  local cmd="$1" budget="${2:-5}"
  (
    cd "$TMPDIR/repo" &&
      CLAUDE_PROJECT_DIR="$TMPDIR/repo" timeout "$budget" bash "$HOOK" \
        <<<"$(hook_input "$cmd")"
  )
  echo $?
}

run_remote_parser() {
  local cmd="$1"
  (
    # shellcheck source=../../skills/autonomous-common/hooks/lib-push.sh
    source "$LIB_PUSH"
    parse_push_remote_operand "$cmd"
  )
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

assert_output() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
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
# hook's cwd. Made non-vacuous by planting a file in the cwd whose name IS the
# canonical destination, so an unguarded split would expand the pattern into a
# matching entry and wrongly exempt the push. With `set -f` the pattern stays
# literal and the push is blocked. (Verified to FAIL when `set -f` is removed.)
(cd "$TMPDIR/repo" && mkdir -p "github.com/zxkane" \
  && : > "github.com/zxkane/autonomous-dev-team")
out=$(run_hook_allow "git push origin main" "github.com/zxkane/*")
assert_exit "glob-shaped allowlist entry stays literal (set -f), does not exempt" "2" "$out"
rm -rf "$TMPDIR/repo/github.com"

# ===========================================================================
# TC-BP-20: chained pushes — a second `git push` cannot ride along
# ===========================================================================
# One operand cannot describe two destinations, and the trunk-ref parser reads
# refspecs from the WHOLE line. Answering for only the first push would let the
# second reach trunk unexamined. Two pushes on a line = UNKNOWN = fail closed.
echo ""
echo "=== TC-BP-20: chained push does not bypass ==="
setup_repo main
git -C "$TMPDIR/repo" remote add upstream https://github.com/upstream-owner/adt.git
out=$(run_hook_cwd "git push upstream feat/x && git push origin main" "$TMPDIR/repo")
assert_exit "chained push whose 2nd targets own trunk blocked" "2" "$out"
out=$(run_hook_cwd "git push https://github.com/other/x.git main && git push origin main" "$TMPDIR/repo")
assert_exit "chained push with literal-URL 1st arm blocked" "2" "$out"

# ===========================================================================
# TC-BP-21: a quoted operand is UNKNOWN, not a literal destination
# ===========================================================================
# `read -ra` does not strip quotes, so the token still carries them. Treating it
# as a URL would canonicalize `…team.git"` — a confidently WRONG destination
# that differs from the anchor and would be waved through, while the real shell
# strips the quotes and pushes to the protected trunk.
echo ""
echo "=== TC-BP-21: quoted URL operand fails closed ==="
setup_repo main
out=$(run_hook_cwd "git push \"$PROJECT_URL\" main" "$TMPDIR/repo")
assert_exit "double-quoted own-trunk URL operand blocked" "2" "$out"
out=$(run_hook_cwd "git push '$PROJECT_URL' main" "$TMPDIR/repo")
assert_exit "single-quoted own-trunk URL operand blocked" "2" "$out"
out=$(run_hook_cwd 'git push $REMOTE main' "$TMPDIR/repo")
assert_exit "variable-expansion operand blocked" "2" "$out"

# ===========================================================================
# TC-BP-22: unresolvable command context is UNKNOWN, never "the cwd"
# ===========================================================================
# `resolve_git_command_cwd` rc=2 means a push matched but its target repo cannot
# be resolved ([INV-146]). Substituting the hook's cwd would compare the WRONG
# repository — allowing a project-trunk push issued from a wiki cwd. These
# grammars are all rc=2, and every one must still be checked.
echo ""
echo "=== TC-BP-22: rc=2 grammars fail closed (cwd = a different repo) ==="
setup_repo main
setup_other_repo project.wiki "$WIKI_URL"
for _cmd in \
  "env git -C $TMPDIR/repo push origin main" \
  "timeout 60 git -C $TMPDIR/repo push origin main" \
  "cd $TMPDIR/repo ; git push origin main" \
  "git --git-dir=$TMPDIR/repo/.git --work-tree=$TMPDIR/repo push origin main"; do
  out=$(run_hook_cwd "$_cmd" "$TMPDIR/project.wiki")
  assert_exit "rc=2 grammar reaching own trunk blocked: ${_cmd:0:38}…" "2" "$out"
done

# ===========================================================================
# TC-BP-23: local push config cannot redefine the protected trunk
# ===========================================================================
# The anchor's BARE-PUSH destination is not a safe definition of "this project":
# `remote.pushDefault` / `branch.<b>.pushRemote` in the project checkout would
# silently move it and switch the guard off. The anchor check therefore matches
# against ALL of the anchor's remotes.
echo ""
echo "=== TC-BP-23: pushDefault/pushRemote cannot disable the guard ==="
setup_repo main
git -C "$TMPDIR/repo" remote add myfork https://github.com/zxkane/fork.git
git -C "$TMPDIR/repo" config remote.pushDefault myfork
out=$(run_hook_cwd "git push origin main" "$TMPDIR/repo")
assert_exit "remote.pushDefault redirect does not disable trunk protection" "2" "$out"
git -C "$TMPDIR/repo" config --unset remote.pushDefault
git -C "$TMPDIR/repo" config branch.main.pushRemote myfork
out=$(run_hook_cwd "git push origin main" "$TMPDIR/repo")
assert_exit "branch.<b>.pushRemote redirect does not disable trunk protection" "2" "$out"

# ===========================================================================
# TC-BP-24: URL spellings that must NOT collide
# ===========================================================================
# Guards the host/path split: a `@`, `:`, or `//` inside the PATH must never be
# read as host syntax, or two unrelated repositories canonicalize equal and a
# legitimate push to one is blocked as if it were the other.
echo ""
echo "=== TC-BP-24: path-embedded @ / // do not collapse distinct repos ==="
setup_repo main
setup_other_repo atpath "https://gitlab.example.com/group/u@n/repo.git"
out=$(run_hook_cwd "git -C $TMPDIR/atpath push origin main" "$TMPDIR/repo")
assert_exit "path-embedded @ repo treated as a different destination" "0" "$out"
# Non-vacuous variant: the path embeds the PROJECT'S OWN host+path after an `@`.
# An unscoped `${url#*@}` would strip through it and canonicalize this to the
# project itself, blocking a legitimate push to an unrelated host.
setup_other_repo atown "https://example.com/x@github.com/zxkane/autonomous-dev-team.git"
out=$(run_hook_cwd "git -C $TMPDIR/atown push origin main" "$TMPDIR/repo")
assert_exit "path embedding the project's own host stays a different destination" "0" "$out"

# ===========================================================================
# TC-BP-26: DNS/path-equivalent spellings of own trunk are still blocked
# ===========================================================================
# A trailing dot on a hostname is DNS-equivalent, and `.`/`..` path segments
# resolve server-side. Each spelling below reaches this project's real trunk, so
# treating any of them as "a different destination" is a bypass.
echo ""
echo "=== TC-BP-26: trailing-dot host and dot-segment paths still blocked ==="
setup_repo main
for _url in \
  "https://github.com./zxkane/autonomous-dev-team.git" \
  "git@github.com.:zxkane/autonomous-dev-team.git" \
  "https://github.com/zxkane/../zxkane/autonomous-dev-team.git" \
  "https://github.com/./zxkane/autonomous-dev-team.git"; do
  setup_other_repo equiv "$_url"
  out=$(run_hook_cwd "git -C $TMPDIR/equiv push origin main" "$TMPDIR/repo")
  assert_exit "equivalent spelling still blocked: $_url" "2" "$out"
done

# ===========================================================================
# TC-BP-27: an unreadable or remote-less anchor is UNKNOWN, not "not mine"
# ===========================================================================
# `anchor_owns_destination` must distinguish "read the anchor, it owns no such
# remote" (allow) from "could not read the anchor at all" (unknown → check).
# Otherwise a mis-set anchor becomes a blanket opt-out from trunk protection,
# which is worse than no scoping. Note TC-BP-13c cannot catch this class: a
# MISSING anchor falls back to the cwd, whereas these are anchors that exist but
# yield no usable remote.
echo ""
echo "=== TC-BP-27: unreadable / remote-less anchor fails closed ==="
setup_repo main
mkdir -p "$TMPDIR/anchor-not-a-repo"
rm -rf "${TMPDIR:?}/anchor-no-remotes"
mkdir -p "$TMPDIR/anchor-no-remotes"
git -C "$TMPDIR/anchor-no-remotes" init --quiet --initial-branch=main
git -C "$TMPDIR/anchor-no-remotes" -c user.email=test@test -c user.name=test \
  commit --quiet --allow-empty -m init
run_hook_anchor() {
  local cmd="$1" anchor="$2"
  (cd "$TMPDIR/repo" && AUTONOMOUS_PROJECT_DIR="$anchor" \
    bash "$HOOK" <<<"$(hook_input "$cmd")" >/dev/null 2>&1)
  echo $?
}
out=$(run_hook_anchor "git push origin main" "$TMPDIR/anchor-not-a-repo")
assert_exit "anchor that is not a git repo fails closed" "2" "$out"
out=$(run_hook_anchor "git push origin main" "$TMPDIR/anchor-no-remotes")
assert_exit "anchor with zero remotes fails closed" "2" "$out"
# Sanity: a readable anchor that genuinely does not own the destination still
# allows — proving the above block on UNKNOWN, not on every non-match.
setup_other_repo unrelated "https://github.com/other-owner/other-repo.git"
out=$(run_hook_cwd "git -C $TMPDIR/unrelated push origin main" "$TMPDIR/repo")
assert_exit "readable anchor not owning the destination still allows" "0" "$out"

# ===========================================================================
# TC-BP-25: both wrappers export the project anchor
# ===========================================================================
# The hook cannot derive the project from its own cwd, so the anchor MUST arrive
# by export ([INV-148]). Dropping the export is fail-closed, not permissive — a
# wiki push starts being blocked again — so nothing else would catch it. Static
# assertion mirrors TC-BASEBR-025's treatment of the BASE_BRANCH export.
echo ""
echo "=== TC-BP-25: wrappers export AUTONOMOUS_PROJECT_DIR ==="
for _w in autonomous-dev autonomous-review; do
  _f="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/${_w}.sh"
  if grep -qE '^export AUTONOMOUS_PROJECT_DIR="\$PROJECT_DIR"$' "$_f"; then
    assert_exit "${_w}.sh exports AUTONOMOUS_PROJECT_DIR" "0" "0"
  else
    assert_exit "${_w}.sh exports AUTONOMOUS_PROJECT_DIR" "0" "1"
  fi
  if grep -qE '^  export PUSH_ALLOWED_REMOTE_URLS$' "$_f"; then
    assert_exit "${_w}.sh exports PUSH_ALLOWED_REMOTE_URLS when set" "0" "0"
  else
    assert_exit "${_w}.sh exports PUSH_ALLOWED_REMOTE_URLS when set" "0" "1"
  fi
done

# ===========================================================================
# TC-BP-28: bare --signed must not consume the remote
# ===========================================================================
echo ""
echo "=== TC-BP-28: --signed push to main from feat -> block ==="
setup_repo feat/x
out=$(run_hook "git push --signed origin main")
assert_exit "--signed push to main from feat blocked" "2" "$out"

# ===========================================================================
# TC-BP-29: --repo value and positional repository follow Git precedence
# ===========================================================================
echo ""
echo "=== TC-BP-29: --repo repository precedence ==="
setup_repo feat/x
out=$(run_hook "git push --repo origin main")
assert_exit "--repo origin main from feat has an implicit feature ref" "0" "$out"
setup_repo main
out=$(run_hook "git push --repo origin feat/foo")
assert_exit "--repo origin feat/foo from main has an implicit trunk ref" "2" "$out"
setup_repo feat/x
out=$(run_hook "git push --repo origin origin main")
assert_exit "--repo plus positional origin and explicit main ref blocked" "2" "$out"
setup_repo main
setup_other_repo repo-override "$PROJECT_URL"
git -C "$TMPDIR/repo-override" remote add other https://github.com/other-owner/other-repo.git
out=$(run_hook_cwd "git push --repo other" "$TMPDIR/repo-override")
assert_exit "--repo unrelated remote overrides protected push destination" "0" "$out"

# ===========================================================================
# TC-BP-30: --signed feature push from trunk -> allow
# ===========================================================================
echo ""
echo "=== TC-BP-30: --signed feature push from main -> allow ==="
setup_repo main
out=$(run_hook "git push --signed origin feat/foo")
assert_exit "--signed feature push from main allowed" "0" "$out"

# ===========================================================================
# TC-BP-31: -o still consumes its separate value
# ===========================================================================
echo ""
echo "=== TC-BP-31: -o value before push to main -> block ==="
setup_repo feat/x
out=$(run_hook "git push -o ci.skip origin main")
assert_exit "-o value skipped and push to main blocked" "2" "$out"

# ===========================================================================
# TC-BP-32: the remote parser mirrors push-option token handling
# ===========================================================================
echo ""
echo "=== TC-BP-32: remote operand parser flag handling ==="
out=$(run_remote_parser "git push --signed origin main")
assert_output "--signed leaves origin as the remote operand" "origin" "$out"
out=$(run_remote_parser "git push --repo origin main")
assert_output "positional main overrides the --repo value" "main" "$out"
out=$(run_remote_parser "git push --repo origin")
assert_output "--repo value is used without a positional repository" "origin" "$out"
out=$(run_remote_parser "git push --repo=origin")
assert_output "--repo=value is used without a positional repository" "origin" "$out"
out=$(run_remote_parser "git push --repo origin origin main")
assert_output "positional origin overrides the --repo value" "origin" "$out"
out=$(run_remote_parser "git push -o ci.skip origin main")
assert_output "-o still consumes ci.skip before the remote" "origin" "$out"
out=$(run_remote_parser "git push --signed=if-asked origin main")
assert_output "--signed=value remains a one-token option" "origin" "$out"
out=$(run_remote_parser "git push --recurse-submodules origin main")
assert_output "invalid bare --recurse-submodules is handled conservatively" "origin" "$out"
out=$(run_remote_parser "git push --recurse-submodules no origin main")
assert_output "valid mode remains the operand in the bounded parser" "no" "$out"

# ===========================================================================
# TC-BP-33: --flag=value remains one token
# ===========================================================================
echo ""
echo "=== TC-BP-33: --signed=value push to main from feat -> block ==="
setup_repo feat/x
out=$(run_hook "git push --signed=if-asked origin main")
assert_exit "--signed=value push to main from feat blocked" "2" "$out"

# ===========================================================================
# TC-BP-34: valid mode with no same-name remote fails closed
# ===========================================================================
echo ""
echo "=== TC-BP-34: --recurse-submodules no with no 'no' remote -> block ==="
setup_repo feat/x
out=$(run_hook "git push --recurse-submodules no origin main")
assert_exit "unresolved mode-named destination leaves the trunk check armed" "2" "$out"

# ===========================================================================
# TC-BP-35: large ambiguous push stays fail-closed within the hook budget
# ===========================================================================
echo ""
echo "=== TC-BP-35: large ambiguous push remains bounded and blocked ==="
setup_repo main
large_command=$'python3 - <<PY\n'
for ((i = 0; i < 250; i++)); do
  large_command+="def f$i(x):"$'\n'
  large_command+="    return g(x)+$i"$'\n'
done
large_command+=$'PY\ngit push origin main'
out=$(run_hook_bounded "$large_command")
assert_exit "large uncertain trunk push blocks within five seconds" "2" "$out"

# ===========================================================================
# TC-BP-36: chained and multi-line feature pushes remain allowed
# ===========================================================================
echo ""
echo "=== TC-BP-36: chained and multi-line feature pushes remain allowed ==="
setup_repo feat/x
out=$(run_hook "git add -A && git commit -m x && git push origin feat/x")
assert_exit "feature push after add and commit is allowed" "0" "$out"
out=$(run_hook "git rebase --autostash origin/main && git push --force-with-lease origin feat/x")
assert_exit "feature push after rebase is allowed" "0" "$out"
out=$(run_hook $'cd /tmp\ngit push origin feat/x')
assert_exit "feature push on a later physical line is allowed" "0" "$out"
out=$(run_hook $'git add a.txt\ngit commit -m "feat(x): y"\ngit push -u origin feat/x')
assert_exit "documented multi-line feature workflow is allowed" "0" "$out"
out=$(run_hook "git add -A && git commit -m x && git push origin main")
assert_exit "equivalent chained trunk push remains blocked" "2" "$out"
out=$(run_hook 'git push "$REMOTE" feat/x')
assert_exit "quoted dynamic remote keeps the literal feature refspec readable" "0" "$out"
out=$(run_hook 'git push $REMOTE feat/x')
assert_exit "unquoted dynamic remote remains fail-closed" "2" "$out"

# ===========================================================================
# TC-BP-37: git-free expansion commands are not treated as pushes
# ===========================================================================
echo ""
echo "=== TC-BP-37: git-free expansion commands remain allowed ==="
for command in \
  'git -C $dir status' \
  '$PYTHON $SCRIPT' \
  '"$PYTHON" "$SCRIPT"' \
  '${TOOL} ${ARG}' \
  '$CMD --flag $x' \
  './run.sh && $CMD $ARG'
do
  out=$(run_hook "$command")
  assert_exit "git-free command allowed: $command" "0" "$out"
done
out=$(run_hook '$GIT push origin main')
assert_exit "dynamic git command with a literal trunk push stays fail-closed" "2" "$out"

# ===========================================================================
# TC-BP-38: large git-free ambiguous input stays within the hook budget
# ===========================================================================
echo ""
echo "=== TC-BP-38: large git-free ambiguous input remains bounded ==="
setup_repo feat/x
large_command=$'python3 - <<PY\n'
for ((i = 0; i < 625; i++)); do
  large_command+="def f$i(x):"$'\n'
  large_command+="    return g(x)+$i"$'\n'
done
large_command+=$'PY\nprintf done'
out=$(run_hook_bounded "$large_command")
assert_exit "large git-free ambiguous command is allowed within five seconds" "0" "$out"

# ===========================================================================
# TC-BP-39: non-executable push text does not override a real feature push
# ===========================================================================
echo ""
echo "=== TC-BP-39: non-executable push text remains ignored ==="
setup_repo feat/x
out=$(run_hook "echo git push origin main && git push origin feat/x")
assert_exit "echo arguments mentioning a trunk push stay non-executable" "0" "$out"
out=$(run_hook $'cat <<EOF\ngit push origin main\nEOF\ngit push origin feat/x')
assert_exit "heredoc data mentioning a trunk push stays non-executable" "0" "$out"
out=$(run_hook "echo git push origin feat/x && git push origin main")
assert_exit "a real trunk push still blocks after benign push text" "2" "$out"

# ===========================================================================
# TC-BP-40: prefixed pushes cannot disappear from a multi-command parse
# ===========================================================================
echo ""
echo "=== TC-BP-40: prefixed pushes remain visible and fail closed ==="
setup_repo feat/x
for command in \
  "git push origin feat/x && ( git push origin main )" \
  "git push origin feat/x && sudo git push origin main" \
  "timeout 5 git push origin main && git push origin feat/x" \
  'GIT_SSH_COMMAND="ssh -i k" git push origin main && git push origin feat/x' \
  "nohup git push origin main & git push origin feat/x" \
  "unknown-wrapper git push origin main && git push origin feat/x"
do
  out=$(run_hook "$command")
  assert_exit "prefixed trunk push blocked: $command" "2" "$out"
done
git -C "$TMPDIR/repo" remote add other https://github.com/other-owner/other-repo.git
out=$(run_hook "git push other feat/x && sudo git push origin main")
assert_exit "unreadable second push cannot reuse the first push's remote scope" "2" "$out"

# ===========================================================================
# TC-BP-41: a supported prefix does not block a feature-only push
# ===========================================================================
echo ""
echo "=== TC-BP-41: prefixed feature pushes remain allowed ==="
setup_repo feat/x
for command in \
  "timeout 60 git push -u origin feat/x" \
  "if git push origin feat/x; then echo ok; fi" \
  "! git push origin feat/x" \
  "sudo git push origin feat/x" \
  "nohup git push origin feat/x" \
  "command git push origin feat/x" \
  "time git push origin feat/x" \
  "stdbuf -oL git push origin feat/x" \
  'GIT_SSH_COMMAND="ssh -i k" git push origin feat/x'
do
  out=$(run_hook "$command")
  assert_exit "prefixed feature push allowed: $command" "0" "$out"
done

# ===========================================================================
# TC-BP-42: a lone data-only push mention remains non-executable
# ===========================================================================
echo ""
echo "=== TC-BP-42: lone non-executable push text remains allowed ==="
setup_repo feat/x
out=$(run_hook "echo git push origin feat/x")
assert_exit "lone echo arguments mentioning a feature push are allowed" "0" "$out"
out=$(run_hook "echo Running git push origin feat/x now")
assert_exit "prose echo arguments mentioning a feature push are allowed" "0" "$out"
out=$(run_hook "echo git push origin main")
assert_exit "lone echo arguments mentioning a trunk push are allowed" "0" "$out"

# ===========================================================================
# TC-BP-43: mixed quote fragments cannot disguise the trunk destination
# ===========================================================================
echo ""
echo "=== TC-BP-43: mixed quote fragments stay fail closed ==="
setup_repo feat/x
for command in \
  'git push origin main""' \
  'git push origin ""main' \
  'git push origin ma"in"' \
  'git push origin HEAD:main""'
do
  out=$(run_hook "$command")
  assert_exit "mixed-quoted trunk refspec blocked: $command" "2" "$out"
done

# ===========================================================================
# TC-BP-44: realistic large push commands stay within the hook budget
# ===========================================================================
echo ""
echo "=== TC-BP-44: realistic large push commands remain bounded ==="
setup_repo feat/x
large_body=""
for ((i = 0; i < 2500; i++)); do
  large_body+="word$i "
done
large_command="git push -u origin feat/x && gh pr create --title t --body \"$large_body\""
out=$(run_hook_bounded "$large_command")
assert_exit "feature push chained to a large PR body is allowed within five seconds" "0" "$out"
printf -v large_option '%*s' 21000 ''
large_option="${large_option// /x}"
large_command="git push origin feat/x --push-option=$large_option"
out=$(run_hook_bounded "$large_command")
assert_exit "feature push with a large option stays within five seconds" "0" "$out"

# ===========================================================================
# TC-BP-45: data text becomes executable when routed into a shell
# ===========================================================================
echo ""
echo "=== TC-BP-45: executable consumers keep push text fail closed ==="
setup_repo feat/x
out=$(run_hook "echo git push origin main | bash")
assert_exit "echo output piped to bash remains blocked" "2" "$out"
out=$(run_hook "echo git push origin main | sh")
assert_exit "echo output piped to sh remains blocked" "2" "$out"
out=$(run_hook "echo git push origin main | bash -s")
assert_exit "echo output piped to bash stdin remains blocked" "2" "$out"
out=$(run_hook "echo git push origin main | ssh host bash")
assert_exit "echo output piped to a remote shell remains blocked" "2" "$out"
out=$(run_hook 'printf "%s\n" "$SCRIPT" | ssh host "bash -s"')
assert_exit "dynamic input piped to a quoted remote shell remains fail-closed" "2" "$out"
out=$(run_hook 'printf "%s\n" "$SCRIPT" | ssh host "env -i bash -s"')
assert_exit "dynamic input piped to a wrapped quoted remote shell remains fail-closed" "2" "$out"
out=$(run_hook "echo git push origin main |& bash")
assert_exit "echo stdout/stderr pipe to bash remains blocked" "2" "$out"
out=$(run_hook "printf 'git push origin main\\n' | bash")
assert_exit "printf output piped to bash remains blocked" "2" "$out"
out=$(run_hook "printf \$'git\\x20push origin main\\n' | bash")
assert_exit "ANSI-quoted push text piped to bash remains blocked" "2" "$out"
out=$(run_hook "echo g'it push origin main' | bash")
assert_exit "quote-concatenated push text piped to bash remains blocked" "2" "$out"
out=$(run_hook 'printf "%s\n" "$SCRIPT" | bash')
assert_exit "dynamic shell input remains fail-closed" "2" "$out"
out=$(run_hook 'printf "%s\n" "$SCRIPT" | env -i bash -s')
assert_exit "dynamic shell input through env remains fail-closed" "2" "$out"
out=$(run_hook 'printf "%s\n" "$SCRIPT" | /bin/bash -s')
assert_exit "dynamic shell input through an absolute shell path remains fail-closed" "2" "$out"
out=$(run_hook 'printf "%s\n" "$SCRIPT" | /usr/bin/env bash -s')
assert_exit "dynamic shell input through an absolute env path remains fail-closed" "2" "$out"
out=$(run_hook 'printf "%s\n" "$SCRIPT" | source /dev/stdin')
assert_exit "dynamic shell input sourced from stdin remains fail-closed" "2" "$out"
out=$(run_hook 'printf "%s\n" "$SCRIPT" | . /dev/stdin')
assert_exit "dynamic shell input dot-sourced from stdin remains fail-closed" "2" "$out"
out=$(run_hook "echo git push origin main | command bash")
assert_exit "shell input through command remains blocked" "2" "$out"
out=$(run_hook "echo git push origin main | timeout 5 bash")
assert_exit "shell input through timeout remains blocked" "2" "$out"
out=$(run_hook "echo git push origin main | xargs -I{} bash -c '{}'")
assert_exit "shell input through xargs remains blocked" "2" "$out"
out=$(run_hook "echo git push origin main > >(bash)")
assert_exit "echo output redirected to a bash process substitution remains blocked" "2" "$out"
out=$(run_hook 'echo "$(git push origin main)"')
assert_exit "push inside an echo command substitution remains blocked" "2" "$out"
out=$(run_hook 'echo "$PREFIX" git push origin main')
assert_exit "a dynamic data argument without an executable consumer remains allowed" "0" "$out"
out=$(run_hook "echo git push origin main > /tmp/push-doc")
assert_exit "echo text redirected to a regular file remains data-only" "0" "$out"
out=$(run_hook "printf hello | bash")
assert_exit "git-free literal shell input remains allowed" "0" "$out"

# ===========================================================================
# TC-BP-46: shell syntax around a readable push is not a refspec
# ===========================================================================
echo ""
echo "=== TC-BP-46: redirections, groups, and continuations remain readable ==="
setup_repo feat/x
for command in \
  "git push origin feat/x > /tmp/log" \
  "git push -u origin feat/x >/dev/null" \
  "git push origin feat/x 2>&1 | tee /tmp/log" \
  "git push -u origin feat/x 2>/dev/null" \
  "git push origin feat/x < /dev/null" \
  "git push origin feat/x &>/tmp/log" \
  "git push origin feat/x 2>>/tmp/log" \
  ">/tmp/log git push origin feat/x" \
  "git 2>/dev/null push origin feat/x" \
  "git push 2>/dev/null origin feat/x" \
  "{ git push origin feat/x; }" \
  $'git push \\\n  -u origin feat/x' \
  $'git push -u \\\n  origin feat/x' \
  $'git push origin \\\n  feat/x'
do
  out=$(run_hook "$command")
  assert_exit "feature push with shell syntax allowed: ${command:0:42}" "0" "$out"
done
for command in \
  "git push origin main > /tmp/log" \
  "git push origin main &>/tmp/log" \
  "{ git push origin main; }" \
  $'git push origin \\\n  main'
do
  out=$(run_hook "$command")
  assert_exit "trunk push with shell syntax blocked: ${command:0:42}" "2" "$out"
done
out=$(run_hook $'git \\\n  commit -m x')
assert_exit "continued non-push git command is allowed" "0" "$out"
out=$(run_hook 'git ${OPTS} status')
assert_exit "dynamic global args before a definite non-push operation are allowed" "0" "$out"

# ===========================================================================
# TC-BP-47: dynamic refspecs are intentionally fail closed
# ===========================================================================
echo ""
echo "=== TC-BP-47: dynamic refspecs remain fail closed ==="
setup_repo feat/x
for command in \
  'git push -u origin "$BRANCH"' \
  'git push --force-with-lease origin "$PR_BRANCH"' \
  'git push -u origin "$(git branch --show-current)"'
do
  out=$(run_hook "$command")
  assert_exit "dynamic refspec remains unreadable: $command" "2" "$out"
done

# ===========================================================================
# TC-BP-48: ordinary variable data pipelines remain non-executable
# ===========================================================================
echo ""
echo "=== TC-BP-48: variable data piped to non-shell consumers remains allowed ==="
setup_repo feat/x
for command in \
  'echo "$json" | jq .' \
  'echo "$msg" | tee -a /tmp/log' \
  'printf "%s\n" "${arr[@]}" | sort' \
  'echo "$body" | gh pr comment 12 --body-file -' \
  'echo "$sha" | cut -c1-7' \
  'echo "$json" | env jq .' \
  'echo "$json" | ssh host cat' \
  'echo "$json" | ssh host "cat > /tmp/data"' \
  'echo "$json" | xargs jq .'
do
  out=$(run_hook "$command")
  assert_exit "non-shell data pipeline allowed: $command" "0" "$out"
done

# ===========================================================================
# TC-BP-49: arithmetic expansion is data, not executable command substitution
# ===========================================================================
echo ""
echo "=== TC-BP-49: arithmetic expansion remains allowed in data commands ==="
setup_repo feat/x
for command in \
  'echo "n=$((x + 1))" > /tmp/x' \
  'printf "%d\n" "$((total))" > /tmp/y'
do
  out=$(run_hook "$command")
  assert_exit "arithmetic data expansion allowed: $command" "0" "$out"
done

# ===========================================================================
# TC-BP-50: dynamic git global values can precede more global flags
# ===========================================================================
echo ""
echo "=== TC-BP-50: dynamic globals before definite non-push operations allow ==="
setup_repo feat/x
for command in \
  'git -C "$D" -c a=b commit -m x 2>&1' \
  'git -C "$D" -c user.email=t commit -m fix 2>&1' \
  'git -C "$D" -c core.pager=cat log --oneline | head'
do
  out=$(run_hook "$command")
  assert_exit "definite non-push after dynamic globals allowed: $command" "0" "$out"
done

# ===========================================================================
# TC-BP-51: mixed quote fragments cannot disguise the push operation
# ===========================================================================
echo ""
echo "=== TC-BP-51: mixed-quoted push operation remains fail closed ==="
setup_repo feat/x
for command in \
  "git pu'sh' origin main" \
  'git "pu""sh" origin main'
do
  out=$(run_hook "$command")
  assert_exit "mixed-quoted trunk push operation blocked: $command" "2" "$out"
done

# ===========================================================================
# TC-BP-52: substitution bodies are classified by what they execute
# ===========================================================================
echo ""
echo "=== TC-BP-52: benign substitutions allow; executable push bodies block ==="
setup_repo feat/x
for command in \
  'echo "$(date)"' \
  'echo "started at $(date -u +%FT%TZ)"' \
  'printf "%s\n" "$(cat /etc/hostname)"' \
  'echo "HEAD is $(git rev-parse --short HEAD)"' \
  'echo "$(cat notes.md)" > /tmp/notes.copy' \
  'echo "$(cat x.json)" | jq .' \
  'echo "$(echo git push origin main)"' \
  'log() { echo "[tick] $(date -u +%H:%M:%S) $*"; }' \
  'echo "`date`"'
do
  out=$(run_hook "$command")
  assert_exit "benign substitution remains allowed: $command" "0" "$out"
done
for command in \
  '$(echo git push origin main)' \
  "bash <(echo 'git push origin main')" \
  "source <(echo 'git push origin main')" \
  ". <(echo 'git push origin main')" \
  'out="$(git push origin main)"' \
  'eval $(echo git push origin main)' \
  'echo "n=$(( $(git push origin main) + 1 ))"' \
  'git push origin feat/x; echo "$(git push origin main)"' \
  'if $(echo git push origin main); then echo hi; fi'
do
  out=$(run_hook "$command")
  assert_exit "executable substitution push blocked: $command" "2" "$out"
done

# ===========================================================================
# TC-BP-53: non-shell stdin evaluators distinguish code from data
# ===========================================================================
echo ""
echo "=== TC-BP-53: stdin evaluators block code without blocking data controls ==="
setup_repo feat/x
for command in \
  "echo git push origin main | awk '{system(\$0)}'" \
  "echo git push origin main | awk '{print | \"sh\"}'" \
  "echo git push origin main | awk '{ \"sh\" | getline x }'" \
  "echo git push origin main | sed 's/.*/&/e'" \
  "echo git push origin main | sed 'e'" \
  "echo git push origin main | sed -i '' 'e'" \
  "echo git push origin main | awk -f script.awk" \
  "echo git push origin main | gawk -i script.awk ''" \
  "echo git push origin main | gawk --include=script.awk '{print}'" \
  "echo git push origin main | gawk '@load \"filefuncs\"; {print}'" \
  "echo git push origin main | gawk -E script.awk" \
  "echo git push origin main | gawk --exec=script.awk" \
  "echo git push origin main | gawk --fil=script.awk" \
  "echo git push origin main | gawk --incl=script.awk '{print}'" \
  "echo git push origin main | gawk --lo=plugin '{print}'" \
  'echo git push origin main | parallel' \
  'echo git push origin main | at now' \
  'echo git push origin main | crontab -' \
  'echo git push origin main | while read l; do $l; done' \
  'echo git push origin main | tee >(bash)' \
  'echo git push origin main | xargs env'
do
  out=$(run_hook "$command")
  assert_exit "stdin-evaluated trunk push blocked: $command" "2" "$out"
done
for command in \
  "echo git push origin main | awk '{print \$0}'" \
  "echo git push origin main | sed 's/x/y/'" \
  "echo git push origin main | sed -e 's/x/y/'" \
  "echo git push origin main | sed -n 'p'" \
  "echo git push origin main | awk -F: '{print \$1}'" \
  "echo git push origin main | awk --field-separator=: '{print \$1}'" \
  "echo git push origin main | awk -v prefix=x '{print prefix \$0}'" \
  "echo git push origin main | gawk --assign=prefix=x '{print prefix \$0}'" \
  "echo git push origin main | awk -- '{print \$0}'" \
  'echo git push origin main | rev' \
  'echo git push origin main | base64' \
  'echo git push origin main | tac' \
  'echo git push origin main | dd of=/tmp/push-copy' \
  'echo git push origin main | while read l; do echo "$l"; done' \
  'echo git push origin main | tee >(cat >/tmp/push-copy)' \
  'echo git push origin main | xargs echo'
do
  out=$(run_hook "$command")
  assert_exit "stdin data-only control allowed: $command" "0" "$out"
done

# ===========================================================================
# TC-BP-54: executable consumers remain visible through data-only stages
# ===========================================================================
echo ""
echo "=== TC-BP-54: multi-stage pipelines preserve executable consumers ==="
setup_repo feat/x
for command in \
  'echo git push origin main | cat | bash' \
  'echo git push origin main | tee /tmp/push-copy | bash' \
  'echo git push origin main | sort | sh' \
  'echo git push origin main | grep push | bash' \
  'echo git push origin main | tr a-z a-z | bash' \
  'echo git push origin main | cat |& bash' \
  'echo git push origin main | cat | python3 -' \
  'echo git push origin main | cat | source /dev/stdin' \
  'echo git push origin main | cat | while read -r l; do eval "$l"; done' \
  'echo git push origin main | tee >(cat) | bash' \
  'echo git push origin main | while read -r l; do echo "$l"; done | bash' \
  'echo git push origin main | if read -r l; then echo "$l"; fi | bash' \
  'echo git push origin main | tee >(cat | bash)' \
  'echo git push origin main | cat | (bash)' \
  'echo git push origin main | cat | { bash; }'
do
  out=$(run_hook "$command")
  assert_exit "downstream executable consumer blocks trunk push: $command" "2" "$out"
done
for command in \
  'echo git push origin main | cat | jq .' \
  'echo git push origin main | sort | tee /tmp/push-copy' \
  'echo git push origin main | tee >(cat) | grep push' \
  'echo git push origin main | cat ; echo true | bash' \
  'echo git push origin main | cat && echo true | bash'
do
  out=$(run_hook "$command")
  assert_exit "multi-stage data-only pipeline remains allowed: $command" "0" "$out"
done

# ===========================================================================
# TC-BP-55: large substitution-bearing input stays within the hook budget
# ===========================================================================
echo ""
echo "=== TC-BP-55: large benign substitution input remains bounded ==="
setup_repo feat/x
large_command=$'python3 - <<PY\n'
for ((i = 0; i < 625; i++)); do
  large_command+="def f$i(x):"$'\n'
  large_command+="    return g(x)+$i"$'\n'
done
large_command+=$'PY\nprintf "%s\\n" "$(date)"'
out=$(run_hook_bounded "$large_command")
assert_exit "large benign substitution command is allowed within five seconds" "0" "$out"

# ===========================================================================
# TC-BP-56: compound commands and execution wrappers inspect their bodies
# ===========================================================================
echo ""
echo "=== TC-BP-56: compound and wrapped consumers distinguish code from data ==="
setup_repo feat/x
for command in \
  'echo git push origin main | if true; then bash; fi' \
  'echo git push origin main | if read -r l; then bash; fi' \
  'echo git push origin main | for f in x; do bash; done' \
  'echo git push origin main | select f in x; do bash; done' \
  'echo git push origin main | case x in x) bash;; esac' \
  'echo git push origin main | case y in x) if true; then cat; fi;; y) bash;; esac' \
  'echo git push origin main | nice bash' \
  'echo git push origin main | setsid bash' \
  'echo git push origin main | ionice bash' \
  "echo git push origin main | env -S 'bash -s'" \
  "echo git push origin main | env --split-string='bash -s'" \
  'echo git push origin main | cat | nice bash' \
  'echo git push origin main | tee >(if true; then bash; fi)'
do
  out=$(run_hook "$command")
  assert_exit "compound or wrapped executable consumer blocks: $command" "2" "$out"
done
for command in \
  'echo git push origin main | if true; then cat; fi' \
  'echo git push origin main | if read -r l; then cat; fi' \
  'echo git push origin main | for f in x; do cat; done' \
  'echo git push origin main | select f in x; do cat; done' \
  'echo git push origin main | case x in x) cat;; esac' \
  'echo git push origin main | case y in x) if true; then cat; fi;; y) cat;; esac' \
  'echo git push origin main | nice cat' \
  'echo git push origin main | setsid cat' \
  'echo git push origin main | ionice cat' \
  "echo git push origin main | env -S 'cat'" \
  "echo git push origin main | env --split-string='cat'" \
  'echo git push origin main | cat | nice cat' \
  'echo git push origin main | tee >(if true; then cat; fi)' \
  'echo git push origin main | cat | { cat; }' \
  'echo git push origin main | cat | (cat)'
do
  out=$(run_hook "$command")
  assert_exit "compound or wrapped data-only consumer allows: $command" "0" "$out"
done

# ===========================================================================
# TC-BP-57: downstream pipeline scanning remains linear
# ===========================================================================
echo ""
echo "=== TC-BP-57: long pipelines remain within the hook budget ==="
setup_repo feat/x
long_pipeline="echo hello"
for ((i = 0; i < 200; i++)); do
  long_pipeline+=" | cat"
done
out=$(run_hook_bounded "$long_pipeline")
assert_exit "two-hundred-stage data pipeline is allowed within five seconds" "0" "$out"
dynamic_pipeline='echo "$CMD"'
for ((i = 0; i < 200; i++)); do
  dynamic_pipeline+=" | cat"
done
dynamic_pipeline+=" | bash"
out=$(run_hook_bounded "$dynamic_pipeline")
assert_exit "two-hundred-stage dynamic pipeline reaches bash within five seconds" "2" "$out"
producer_pipeline="echo git push origin main"
for ((i = 0; i < 200; i++)); do
  producer_pipeline+=" | echo a$i"
done
out=$(run_hook_bounded "$producer_pipeline" 3)
assert_exit "two-hundred-stage producer pipeline is allowed within three seconds" "0" "$out"
grouped_producer_pipeline="{ $producer_pipeline; } | cat"
out=$(run_hook_bounded "$grouped_producer_pipeline" 3)
assert_exit "grouped two-hundred-stage producer pipeline is allowed within three seconds" "0" "$out"
grouped_producer_pipeline="${grouped_producer_pipeline%cat}bash"
out=$(run_hook_bounded "$grouped_producer_pipeline" 3)
assert_exit "grouped two-hundred-stage producer pipeline reaches bash within three seconds" "2" "$out"
producer_pipeline+=" | bash"
out=$(run_hook_bounded "$producer_pipeline" 3)
assert_exit "two-hundred-stage producer pipeline reaches bash within three seconds" "2" "$out"
deep_process_pipeline=""
deep_process_closers=""
for ((i = 0; i < 40; i++)); do
  deep_process_pipeline+="cat > >("
  deep_process_closers+=")"
done
deep_process_pipeline+="cat $deep_process_closers"
out=$(run_hook_bounded \
  "git push origin main; echo x | $deep_process_pipeline")
assert_exit "forty nested process substitutions keep trunk push within five seconds" "2" "$out"
out=$(run_hook_bounded "echo ok; echo x | $deep_process_pipeline")
assert_exit "forty nested data-only process substitutions allow within five seconds" "0" "$out"

# ===========================================================================
# TC-BP-58: grouped producers and consumers preserve executable stdin flow
# ===========================================================================
echo ""
echo "=== TC-BP-58: grouped stdin execution stays visible to the push parser ==="
setup_repo feat/x
for command in \
  'echo git push origin main | { true; bash; }' \
  'echo git push origin main | { :; bash; }' \
  'echo git push origin main | { cd /tmp; bash; }' \
  'echo git push origin main | { true && bash; }' \
  'echo git push origin main | { { true; }; bash; }' \
  'echo git push origin main | { (true); bash; }' \
  'echo git push origin main | { true; { bash; }; }' \
  'echo git push origin main | { true; source /dev/stdin; }' \
  '( echo git push origin main ) | bash' \
  '{ echo git push origin main; } | bash' \
  'if true; then echo git push origin main; fi | bash' \
  'for f in x; do echo git push origin main; done | bash' \
  'case x in x) echo git push origin main;; esac | bash' \
  '{ echo git push origin main | cat; } | bash' \
  '( echo git push origin main | cat ) | bash' \
  '{ echo git push origin main | cat; } | sh' \
  '{ echo git push origin main | cat; } | cat | bash' \
  '{ echo git push origin main | cat; } | env -Sbash' \
  '{ echo git push origin main | grep push; } | bash' \
  '{ echo git push origin main | tee /dev/null | cat; } | bash' \
  "{ printf '%s' git push origin main | cat; } | bash" \
  '{ ( echo git push origin main | cat ); } | bash' \
  'if true; then echo git push origin main | cat; fi | bash' \
  'for f in x; do echo git push origin main | cat; done | bash' \
  'while :; do echo git push origin main | cat; break; done | bash' \
  'case x in x) echo git push origin main | cat;; esac | bash' \
  '{ echo git push origin main | cat; } > >(bash)'
do
  out=$(run_hook "$command")
  assert_exit "grouped executable stdin flow blocks: $command" "2" "$out"
done
for command in \
  'echo git push origin main | { true; cat; }' \
  'echo git push origin main | { :; cat; }' \
  'echo git push origin main | { cd /tmp; cat; }' \
  'echo git push origin main | { true && cat; }' \
  'echo git push origin main | { { true; }; cat; }' \
  'echo git push origin main | { (true); cat; }' \
  'echo git push origin main | { true; { cat; }; }' \
  'echo git push origin main | { true; cat; }' \
  '( echo git push origin main ) | cat' \
  '{ echo git push origin main; } | cat' \
  'if true; then echo git push origin main; fi | cat' \
  'for f in x; do echo git push origin main; done | cat' \
  'case x in x) echo git push origin main;; esac | cat' \
  '{ echo git push origin main | cat; } | cat' \
  '( echo git push origin main | cat ) | cat' \
  'if true; then echo git push origin main | cat; fi | cat' \
  'for f in x; do echo git push origin main | cat; done | cat' \
  'while :; do echo git push origin main | cat; break; done | cat' \
  'case x in x) echo git push origin main | cat;; esac | cat' \
  '{ echo git push origin main | cat; } > >(cat)' \
  'echo a | cat; echo git push origin main | cat'
do
  out=$(run_hook "$command")
  assert_exit "grouped data-only stdin flow allows: $command" "0" "$out"
done

# ===========================================================================
# TC-BP-59: compact env options and shell applets execute stdin
# ===========================================================================
echo ""
echo "=== TC-BP-59: compact env options and shell applets stay fail closed ==="
setup_repo feat/x
for command in \
  'echo git push origin main | env -Sbash' \
  'echo git push origin main | env -vSbash' \
  'echo git push origin main | env -ivSbash' \
  'echo git push origin main | env -i -Sbash' \
  'echo git push origin main | env -C/tmp -Sbash' \
  'echo git push origin main | env -uFOO -Sbash' \
  'echo git push origin main | env FOO=1 -Sbash' \
  'echo git push origin main | ash' \
  'echo git push origin main | mksh' \
  'echo git push origin main | yash' \
  'echo git push origin main | posh' \
  'echo git push origin main | csh' \
  'echo git push origin main | tcsh' \
  'echo git push origin main | fish' \
  'echo git push origin main | hush' \
  'echo git push origin main | busybox ash'
do
  out=$(run_hook "$command")
  assert_exit "compact or alternate shell consumer blocks: $command" "2" "$out"
done
for command in \
  'echo git push origin main | env -Scat' \
  'echo git push origin main | env -vScat' \
  'echo git push origin main | env -ivScat' \
  'echo git push origin main | env -i -Scat' \
  'echo git push origin main | env -C/tmp -Scat' \
  'echo git push origin main | env -uFOO -Scat' \
  'echo git push origin main | env FOO=1 -Scat' \
  'echo git push origin main | busybox cat'
do
  out=$(run_hook "$command")
  assert_exit "compact data-only consumer allows: $command" "0" "$out"
done

# ===========================================================================
# TC-BP-60: large benign substitutions retain timeout headroom
# ===========================================================================
echo ""
echo "=== TC-BP-60: larger benign substitution input retains hook headroom ==="
setup_repo feat/x
large_command=$'python3 - <<PY\n'
for ((i = 0; i < 1250; i++)); do
  large_command+="def f$i(x):"$'\n'
  large_command+="    return g(x)+$i"$'\n'
done
large_command+=$'PY\n'
large_prefix="$large_command"
large_command+='printf "%s\n" "$(date)"'
out=$(run_hook_bounded "$large_command" 3)
assert_exit "approximately forty KiB benign substitution allows within three seconds" "0" "$out"
large_command=$'cat > /tmp/issue547-large-doc <<EOF\n'
for ((i = 0; i < 1500; i++)); do
  large_command+="documentation line $i"$'\n'
done
large_command+=$'git push origin main\nEOF'
out=$(run_hook_bounded "$large_command" 3)
assert_exit "large heredoc trunk prose remains non-executable within three seconds" "0" "$out"
large_command="${large_prefix}git push origin main"
out=$(run_hook_bounded "$large_command" 3)
assert_exit "approximately forty KiB literal trunk push blocks within three seconds" "2" "$out"
large_command="${large_prefix}g'i't p'u'sh origin main"
out=$(run_hook_bounded "$large_command" 3)
assert_exit "approximately forty KiB split-quoted trunk push blocks within three seconds" "2" "$out"
grouped_pipeline="{"
for ((i = 0; i < 200; i++)); do
  grouped_pipeline+=" echo git push origin main;"
done
grouped_pipeline+=" } | cat"
out=$(run_hook_bounded "$grouped_pipeline" 3)
assert_exit "two hundred grouped data segments allow within three seconds" "0" "$out"
grouped_pipeline="${grouped_pipeline%cat}bash"
out=$(run_hook_bounded "$grouped_pipeline" 3)
assert_exit "two hundred grouped data segments reach bash within three seconds" "2" "$out"
distinct_stages='git push -u origin feat/x;'
for ((i = 0; i < 400; i++)); do
  distinct_stages+=" echo w$i;"
done
out=$(run_hook_bounded "$distinct_stages" 3)
assert_exit "four hundred distinct data stages allow within three seconds" "0" "$out"
substitution_dense='git push origin main'
for ((i = 0; i < 450; i++)); do
  substitution_dense+=' $(:)'
done
out=$(run_hook_bounded "$substitution_dense" 3)
assert_exit "four hundred fifty repeated substitutions keep trunk push within three seconds" "2" "$out"
substitution_dense='git push origin main'
for ((i = 0; i < 700; i++)); do
  substitution_dense+=' `:`'
done
out=$(run_hook_bounded "$substitution_dense" 3)
assert_exit "seven hundred repeated backticks keep trunk push within three seconds" "2" "$out"
substitution_dense='git push origin main'
for ((i = 0; i < 500; i++)); do
  substitution_dense+=' > >(:)'
done
out=$(run_hook_bounded "$substitution_dense" 3)
assert_exit "five hundred process substitutions keep trunk push within three seconds" "2" "$out"
substitution_dense='git push origin main'
for ((i = 0; i < 300; i++)); do
  substitution_dense+=" \$(:$i)"
done
out=$(run_hook_bounded "$substitution_dense" 3)
assert_exit "three hundred unique substitutions fail closed within three seconds" "2" "$out"
substitution_dense='echo ok'
for ((i = 0; i < 64; i++)); do
  substitution_dense+=" \$(:$i)"
done
out=$(run_hook_bounded "$substitution_dense")
assert_exit "sixty-four unique benign substitutions remain allowed within five seconds" "0" "$out"
substitution_dense+=' $(:64)'
out=$(run_hook_bounded "$substitution_dense")
assert_exit "sixty-fifth unique benign substitution fails closed within five seconds" "2" "$out"
substitution_dense='echo ok'
for ((i = 0; i < 450; i++)); do
  substitution_dense+=' $(:)'
done
out=$(run_hook_bounded "$substitution_dense" 3)
assert_exit "repeated benign substitutions remain allowed within three seconds" "0" "$out"
executor_dense='git push origin main $('
for ((i = 0; i < 500; i++)); do
  executor_dense+='$a;'
done
executor_dense+=')'
out=$(run_hook_bounded "$executor_dense")
assert_exit "single dense substitution keeps trunk push within five seconds" "2" "$out"
executor_dense="echo ok ${executor_dense#git push origin main }"
out=$(run_hook_bounded "$executor_dense")
assert_exit "single dense benign substitution remains allowed within five seconds" "0" "$out"
deep_padding=$(printf 'x%.0s' {1..47})
deep_substitution='date'
for ((i = 1; i <= 62; i++)); do
  deep_substitution="printf %s_${deep_padding}${i} \$($deep_substitution)"
done
deep_command="git push origin main; echo \$($deep_substitution)"
out=$(run_hook_bounded "$deep_command")
assert_exit "direct trunk push precedes deep benign substitutions within five seconds" "2" "$out"
masked_large_command="cat > /tmp/issue547-masked-push <<'EOF'"$'\n'
for ((i = 0; i < 1500; i++)); do
  masked_large_command+="documentation line $i"$'\n'
done
masked_large_command+=$'EOF\n'
out=$(run_hook_bounded "${masked_large_command}"'echo "$(date)"')
assert_exit "large masked benign substitution allows within five seconds" "0" "$out"
out=$(run_hook_bounded "${masked_large_command}"'echo "$(git push origin main)"')
assert_exit "large masked hidden trunk push blocks within five seconds" "2" "$out"
comment_padding=$(printf 'x%.0s' {1..47})
large_comments=""
for ((i = 0; i < 1000; i++)); do
  large_comments+="# ${comment_padding}${i}"$'\n'
done
out=$(run_hook_bounded "${large_comments}"'echo "$(date)"')
assert_exit "large comment-masked benign substitution allows within five seconds" "0" "$out"
out=$(run_hook_bounded "${large_comments}"'echo "$(git push origin main)"')
assert_exit "large comment-masked hidden trunk push blocks within five seconds" "2" "$out"
out=$(run_hook_bounded "echo \$($deep_substitution)")
assert_exit "deeply nested benign substitution terminates fail-closed within five seconds" "2" "$out"
out=$(run_hook_bounded "echo \$(git push origin main; $deep_substitution)")
assert_exit "deeply nested hidden trunk push blocks within five seconds" "2" "$out"
large_backtick_padding=$(printf 'x%.0s' {1..5000})
out=$(run_hook_bounded "echo $large_backtick_padding; echo \`date\`")
assert_exit "large benign backtick substitution remains allowed" "0" "$out"
out=$(run_hook_bounded "echo $large_backtick_padding; echo \`git push origin main\`")
assert_exit "large hidden backtick trunk push remains blocked" "2" "$out"
mixed_substitution='date'
for ((i = 0; i < 1635; i++)); do
  if (( i % 2 == 0 )); then
    mixed_substitution="\$($mixed_substitution)"
  else
    mixed_substitution="\`$mixed_substitution\`"
  fi
done
mixed_substitution="${mixed_substitution:0:4090}"
out=$(run_hook_bounded "$mixed_substitution" 3)
assert_exit "worst-case mixed substitution fails closed within three seconds" "2" "$out"

# ===========================================================================
# TC-BP-61: large substitutions preserve executable and data-only boundaries
# ===========================================================================
echo ""
echo "=== TC-BP-61: large substitution scans stay scoped to executable bodies ==="
setup_repo feat/x
threshold_padding=$(printf 'x%.0s' {1..4100})
out=$(run_hook_bounded \
  "echo \`\$'git' \$'push' origin main\`; echo $threshold_padding")
assert_exit "large ANSI-C quoted backtick trunk push remains blocked" "2" "$out"
out=$(run_hook_bounded \
  "git push origin feat/x; echo \$(date); echo $threshold_padding")
assert_exit "large feature push beside benign command substitution remains allowed" "0" "$out"
out=$(run_hook_bounded \
  "git push origin feat/x; echo data > >(cat); echo $threshold_padding")
assert_exit "large feature push beside data-only process substitution remains allowed" "0" "$out"

near_threshold_padding=$(printf 'x%.0s' {1..3200})
out=$(run_hook_bounded \
  "echo git push origin main | tee >(cat); echo $near_threshold_padding")
assert_exit "large data-only tee process substitution remains allowed" "0" "$out"
out=$(run_hook_bounded \
  "{ echo git push origin main; } > >(cat); echo $near_threshold_padding")
assert_exit "large grouped data-only process substitution remains allowed" "0" "$out"
out=$(run_hook_bounded \
  "echo \"git push origin main\"; echo \$(date); echo $near_threshold_padding")
assert_exit "large quoted push prose beside benign substitution remains allowed" "0" "$out"

small_heredoc_command=$'cat > /tmp/issue547-push-doc <<\'EOF\'\n'
small_heredoc_command+=$'git push origin main\n'
small_heredoc_command+="$(printf 'documentation %.0s' {1..100})"
small_heredoc_command+=$'\nEOF\necho "$(date)"'
out=$(run_hook_bounded "$small_heredoc_command")
assert_exit "sub-four-KiB heredoc push prose beside benign substitution remains allowed" "0" "$out"

skill_pr_command=$'gh pr create --title "fix: example" --body "$(cat <<\'PRBODY\'\n'
skill_pr_command+=$'- Feature work is published with `git push origin feat/x`.\n'
skill_pr_command+=$'PRBODY\n)"'
out=$(run_hook_bounded "$skill_pr_command")
assert_exit "skill PR body feature-push prose remains allowed" "0" "$out"
out=$(run_hook_bounded \
  "${skill_pr_command}"'; echo "$(git push origin main)"')
assert_exit "real trunk push beside skill PR body remains blocked" "2" "$out"
compact_pr_command="git push -u origin feat/x && ${skill_pr_command}"
out=$(run_hook_bounded "$compact_pr_command")
assert_exit "compact feature push and generated PR body remain allowed" "0" "$out"

large_pr_command=$'git push -u origin feat/x && gh pr create --body "$(cat <<\'PRBODY\'\n'
for ((i = 0; i < 220; i++)); do
  large_pr_command+="release note $i records feature branch publication"$'\n'
done
large_pr_command+=$'- Feature work is published with `git push origin feat/x`.\n'
large_pr_command+=$'PRBODY\n)"'
out=$(run_hook_bounded "$large_pr_command")
assert_exit "large real-world feature push and generated PR body remain allowed" "0" "$out"

unicode_prefix=$'\u2615\u2615\u2615\u2615'
out=$(run_hook_bounded \
  "echo \"$unicode_prefix\" && x=\$(eval \"git push origin main\")")
assert_exit "UTF-8 text before hidden trunk push remains blocked" "2" "$out"
for command in \
  'git p$(echo ush) origin main' \
  'git "pu"$(echo sh) origin main' \
  'git -c a=b pu$(echo sh) origin main'
do
  out=$(run_hook_bounded "$command")
  assert_exit "split dynamic trunk-push operation remains blocked: $command" "2" "$out"
done

large_inline_body=$(printf 'A%.0s' {1..8300})
inline_pr_command="gh pr create --title x --body \"\$(printf '%s\\n' '$large_inline_body')\""
out=$(run_hook_bounded "$inline_pr_command")
assert_exit "greater-than-eight-KiB inline PR body remains allowed" "0" "$out"
out=$(run_hook_bounded \
  "${inline_pr_command}"'; echo "$(git push origin main)"')
assert_exit "real trunk push beside large inline PR body remains blocked" "2" "$out"

body_file_pr=$'gh pr comment 12 --body-file - <<\'EOF\'\n'
body_file_pr+=$'Run `git push origin main` only through a pull request.\nEOF'
out=$(run_hook_bounded "$body_file_pr")
assert_exit "stdin PR body heredoc push prose remains allowed" "0" "$out"
out=$(run_hook_bounded "${body_file_pr}"$'\ngit push origin main')
assert_exit "real trunk push after stdin PR body heredoc remains blocked" "2" "$out"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
