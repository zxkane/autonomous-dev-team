# Test cases — Layer-1 trunk protection scoped by push destination ([INV-148])

Covers `skills/autonomous-common/hooks/block-push-to-main.sh` and the three
`lib-push.sh` helpers it added (`parse_push_remote_operand`,
`canonical_remote_url`, `push_destination_url`).

Suite: `tests/unit/test-block-push-regex.sh` — 32 assertions, hermetic (throwaway
repos under `mktemp -d`, no network; a remote URL only has to be *configured*,
never reachable, because the comparison is textual).

## What is under test

The guard must answer one question: **does this push land on the trunk this
project protects?** Local repository identity cannot answer it — see
[INV-148](../pipeline/invariants.md) for why the sibling guard's
`git-common-dir` comparison is correct for worktree hygiene but wrong here.

Two properties are load-bearing and each has dedicated cases:

- **No false negative** — a push reaching this project's trunk is blocked *however*
  it is spelled or wherever it is issued from (TC-BP-14..17).
- **No false positive** — a push to a genuinely different repository is allowed,
  including the wiki, in every command shape (TC-BP-12, 13, 13b, 18).

Fail-closed is the tie-breaker: allowing requires *both* destinations to resolve
*and* differ (TC-BP-13c).

## Fixtures

| Fixture | `origin` | Role |
|---|---|---|
| `repo` | `github.com/zxkane/autonomous-dev-team.git` | the project; the anchor |
| `other` | `github.com/other-owner/other-repo.git` | unrelated sibling checkout |
| `project.wiki` | `…/autonomous-dev-team.wiki.git` | the motivating wiki case |
| `clone2` | `…/autonomous-dev-team.git` (same as `repo`) | second independent clone — different local repo, **same destination** |
| `wt` | (linked worktree of `repo`) | shares `repo`'s destination |

`run_hook_cwd` exports `AUTONOMOUS_PROJECT_DIR="$TMPDIR/repo"`, reproducing what
the wrappers export ([INV-131] pattern). The hook's own cwd is set
independently, so the tests can distinguish "anchored on the project" from
"anchored on `pwd`" — the distinction TC-BP-13b turns on.

## Cases

### Pre-existing (#64) — unchanged, regression guards

| ID | Case | Expected |
|---|---|---|
| TC-BP-01 | bare push from trunk | block (2) |
| TC-BP-02 | bare push from a feature branch | allow (0) |
| TC-BP-03 | feature push from a trunk-checked-out clone | allow (0) |
| TC-BP-04 | feature push from a feature worktree | allow (0) |
| TC-BP-05 | explicit short refspec to trunk | block (2) |
| TC-BP-06 | `HEAD:refs/heads/main` | block (2) |
| TC-BP-07 | `--all` | block (2) |
| TC-BP-08 | `--mirror` | block (2) |
| TC-BP-09 | `--tags` only | allow (0) |
| TC-BP-10 | `TRUNK_BRANCH=master` + push to `refs/heads/master` | block (2) |
| TC-BP-11 | not a push command | allow (0) |

### Different destination → allow

| ID | Case | Expected |
|---|---|---|
| TC-BP-12 | `git -C <other> push origin main` | allow (0) |
| TC-BP-13 | `cd <wiki> && git push origin main` | allow (0) |
| TC-BP-13b | **bare `git push`** with hook cwd = wiki clone | allow (0) |
| TC-BP-13b′ | `git push origin main` with hook cwd = wiki clone | allow (0) |
| TC-BP-18 | wiki over SSH shorthand (`git@host:owner/p.wiki.git`) | allow (0) |

TC-BP-13b is the case PR #539's parent implementation got wrong: with the
anchor derived from `pwd`, the wiki was compared against itself and the push was
blocked. It pins the anchor against regressing to a `pwd`-derived value.

TC-BP-18 pins the normalization boundary: only a trailing `.git` is stripped,
never `.wiki`. Folding `.wiki` away would make a wiki push compare equal to the
project and reintroduce the original bug.

### Same destination → block

| ID | Case | Expected |
|---|---|---|
| TC-BP-14 | `git -C <self> push origin main` | block (2) |
| TC-BP-15 | push trunk from a linked worktree | block (2) |
| TC-BP-16 | second clone of this project's remote — `-C`, `cd &&`, and `HEAD:refs/heads/main` forms | block (2) ×3 |
| TC-BP-17 | five spellings of the project URL: SSH shorthand, SSH without `.git`, embedded credentials, `ssh://` with port, mixed case | block (2) ×5 |

TC-BP-16 is the security boundary a local-identity check cannot express: this
clone *is* a different local repository, so a `git-common-dir` comparison allows
the push, yet it lands on the protected trunk. TC-BP-17 guards the same boundary
against being reopened by respelling the URL.

### Fail-closed

| ID | Case | Expected |
|---|---|---|
| TC-BP-13c | bare push from the wiki with **no** anchor exported (`env -u AUTONOMOUS_PROJECT_DIR -u CLAUDE_PROJECT_DIR`) | block (2) |

With no anchor the hook falls back to its cwd, the wiki compares equal to
itself, and the push is **checked**. The wiki allowance is a capability the
wrapper grants by exporting the anchor — never an inference drawn from its
absence.

> Additional uncertainty paths (unparsable command, non-git or missing `-C`
> target, `env`/wrapper prefixes, variable expansion) are covered by
> `resolve_git_command_cwd`'s own matrix under
> [INV-146](../pipeline/invariants.md) and were verified unchanged by this
> change: each still reaches the trunk check and blocks.

### `PUSH_ALLOWED_REMOTE_URLS` allowlist

| ID | Case | Expected |
|---|---|---|
| TC-BP-19a | own trunk, destination listed verbatim | allow (0) |
| TC-BP-19b | own trunk, listed under a *different spelling* of the same URL | allow (0) |
| TC-BP-19c | own trunk, allowlist holds only an unrelated URL | block (2) |
| TC-BP-19d | own trunk, allowlist empty | block (2) |
| TC-BP-19e | own trunk, allowlist entry contains a glob metachar (`…/zxkane/*`) | block (2) |

19c and 19d are the important half: the lever must exempt only what it names,
and an empty or unset value must behave exactly as if the lever did not exist.
19e pins the word-split: the list is split under `set -f`, so a glob-shaped
entry stays a literal URL instead of expanding against the hook's cwd and
matching an unintended path.

## Red/green evidence

Against PR #539's parent implementation (original hook + `lib-push.sh`, current
tests): **20 pass / 12 fail**. The 12 red assertions are exactly the two
wiki-bare-push cases, the three second-clone forms, the five URL spellings, and
the two positive allowlist cases. On the fixed implementation: **32/32**.

Suites re-run green alongside this change: `test-block-commit-outside-worktree.sh`
(186), `test-is-git-command-quote-strip.sh` (9), `test-install-git-pre-push.sh`
(8), `test-install-claude-hooks.sh` (10), `test-install-project-hooks.sh` (28),
`test-chp-commit-file.sh` (36), `test-hook-exit-code.sh`.
