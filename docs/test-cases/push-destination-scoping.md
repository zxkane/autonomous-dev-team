# Test cases — Layer-1 trunk protection scoped by push destination ([INV-148])

Covers `skills/autonomous-common/hooks/block-push-to-main.sh` and the four
`lib-push.sh` helpers it added (`parse_push_remote_operand`,
`canonical_remote_url`, `push_destination_url`, `anchor_owns_destination`).

Suite: `tests/unit/test-block-push-regex.sh` — 73 assertions, hermetic (throwaway
repos under `mktemp -d`, no network; a remote URL only has to be *configured*,
never reachable, because the comparison is textual).

## What is under test

The guard must answer one question: **does this push land on the trunk this
project protects?** Local repository identity cannot answer it — see
[INV-148](../pipeline/invariants.md) for why the sibling guard's
`git-common-dir` comparison is correct for worktree hygiene but wrong here.

Two properties are load-bearing and each has dedicated cases:

- **No false negative** — a push reaching this project's trunk is blocked
  *however* it is spelled or wherever it is issued from (TC-BP-14..17, 26).
- **No false positive** — a push to a genuinely different repository is allowed,
  including the wiki, in every parsable command shape (TC-BP-12, 13, 13b, 18, 24).

Fail-closed is the tie-breaker: an allow requires the target destination to be
**proven** and the anchor to be **readable and not own it**. Every form of
uncertainty blocks (TC-BP-13c, 20, 21, 22, 27).

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

### Push option grammar (#542)

The destination and refspec parsers mirror option classification so they agree
where positional operands begin. Bare `--signed` consumes no value. `--repo`
does consume a repository value, but a later positional repository overrides
it. `-o` / `--push-option`, `--receive-pack`, and `--exec` continue to consume a
separate value, while `--flag=value` forms remain one token.

Git rejects bare `--recurse-submodules` followed by a remote as an invalid mode.
Layer 1 handles that unsupported form conservatively as one token so it cannot
shift the parsed remote boundary.

| ID | Case | Expected |
|---|---|---|
| TC-BP-28 | `git push --signed origin main` from `feat/x` | block (2) |
| TC-BP-29 | `git push --repo origin main` from `feat/x` | allow (0), implicit feature ref |
| TC-BP-29a | `git push --repo origin feat/foo` from `main` | block (2), implicit trunk ref |
| TC-BP-29b | `git push --repo origin origin main` from `feat/x` | block (2), explicit trunk ref |
| TC-BP-29c | `git push --repo other` from a second clone on `main`, where `origin` is protected and `other` is unrelated | allow (0), option repository controls destination |
| TC-BP-30 | `git push --signed origin feat/foo` from `main` | allow (0) |
| TC-BP-31 | `git push -o ci.skip origin main` from `feat/x` | block (2) |
| TC-BP-32 | direct remote-parser checks for bare, value-taking, and `--flag=value` options | parsed operand matches Git precedence |
| TC-BP-33 | `git push --signed=if-asked origin main` from `feat/x` | block (2) |
| TC-BP-34 | `git push --recurse-submodules origin main` from `feat/x` | block (2) |

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

Uncertainty is not one path but five, and each has its own case below:
unresolvable command context (TC-BP-22), an ambiguous operand (TC-BP-21),
multiple pushes on one line (TC-BP-20), an unreadable anchor (TC-BP-27), and a
destination that cannot be canonicalized at all (`canonical_remote_url` returns
non-zero, so the allow gate cannot fire).

The important consequence of TC-BP-22 is that **the wiki allowance only applies
to command shapes `resolve_git_command_cwd` can parse.** A wiki push written as
`env git -C <wiki> push origin main` or `timeout 60 git -C <wiki> push …` is
rc=2, so it is treated as unknown and **blocked** — the same as on the parent
branch. That is deliberate: a shape that can't be resolved must not be waved
through just because it *might* be a wiki. Widening the supported grammar is the
way to allow more shapes, never relaxing the fail-closed rule.

### `PUSH_ALLOWED_REMOTE_URLS` allowlist

| ID | Case | Expected |
|---|---|---|
| TC-BP-19a | own trunk, destination listed verbatim | allow (0) |
| TC-BP-19b | own trunk, listed under a *different spelling* of the same URL | allow (0) |
| TC-BP-19c | own trunk, allowlist holds only an unrelated URL | block (2) |
| TC-BP-19d | own trunk, allowlist empty | block (2) |
| TC-BP-19e | own trunk, allowlist entry contains a glob metachar (`github.com/zxkane/*`) | block (2) |

19c and 19d are the important half: the lever must exempt only what it names,
and an empty or unset value must behave exactly as if the lever did not exist.

19e pins the word-split under `set -f`, and does so **non-vacuously**: it plants
a file in the hook's cwd whose path *is* the canonical destination, so without
`set -f` the pattern expands into a matching entry and wrongly exempts the push.
Confirmed by neutralizing `set -f` in the hook — the assertion flips to a
failure, and only that one.

### Adversarial cases (added over two review passes)

Each of these was a **verified bypass or false positive** in an earlier cut of
this change, reproduced and compared against `origin/main` to confirm it was a
regression rather than pre-existing. They are kept as regression pins. TC-BP-24b,
26, and 27 come from the second pass — which found that the first pass's own
fixes had introduced new holes, so the pins below are what keep that from
recurring silently.

| ID | Case | Expected |
|---|---|---|
| TC-BP-20 | `git push upstream feat/x && git push origin main` — a second push riding along on one line | block (2) |
| TC-BP-20b | same, with a literal URL in the first arm | block (2) |
| TC-BP-21 | own-trunk URL operand in double quotes | block (2) |
| TC-BP-21b | …in single quotes | block (2) |
| TC-BP-21c | operand is `$REMOTE` (variable expansion) | block (2) |
| TC-BP-22 | four rc=2 grammars (`env`, `timeout`, `;`-separated `cd`, `--git-dir/--work-tree`) reaching own trunk from a *wiki* cwd | block (2) ×4 |
| TC-BP-23 | `remote.pushDefault` points elsewhere | block (2) |
| TC-BP-23b | `branch.<b>.pushRemote` points elsewhere | block (2) |
| TC-BP-24 | a repo whose *path* embeds `@` must not collapse onto another host's | allow (0) |
| TC-BP-24b | path embeds the project's **own** host+path after an `@` — an unscoped `${url#*@}` would canonicalize it to the project itself | allow (0) |
| TC-BP-26 | four DNS/path-equivalent spellings of own trunk: trailing-dot host (HTTPS + SSH), `..` and `.` path segments | block (2) ×4 |
| TC-BP-27 | anchor is not a git repo / has zero remotes → UNKNOWN, not "not mine" | block (2) ×2 |
| TC-BP-27c | readable anchor that genuinely does not own the destination | allow (0) |

TC-BP-24b is the non-vacuous form of TC-BP-24 — the original fixture passes even
on the first cut, so only this one pins the host/path split.

TC-BP-26 covers spellings that reach the real repository: a trailing dot on a
hostname is DNS-equivalent, and `.`/`..` segments resolve server-side.

TC-BP-27 is a class TC-BP-13c cannot reach. A *missing* anchor falls back to the
cwd (already fail-closed); these are anchors that **exist** but yield no usable
remote, where conflating "couldn't read it" with "doesn't own it" would turn a
mis-set anchor into a blanket opt-out. TC-BP-27c is the counter-proof that the
block is on *unknown*, not on every non-match.

TC-BP-20/21 exist because a single operand cannot describe two destinations, and
because `read -ra` does not strip quotes — a quoted token canonicalizes to a
*confidently wrong* destination, which is worse than an unresolved one, since it
satisfies the allow gate. TC-BP-23 exists because the anchor's own bare-push
destination is not a safe definition of "this project": ordinary local push
config would otherwise move the protected trunk and silently disable the guard.

## Red/green evidence

All counts below were measured, not estimated — by checking out the named
implementation and running the current suite against it.

**On this implementation: 73/73.**

The destination-scoping counts below were measured with the original
TC-BP-01..27 slice (56 assertions). **Against PR #539's parent (`216a906`): 36
pass / 20 fail.** The 20 red:
the 2 wiki-bare-push cases, the 3 second-clone forms, the 5 URL spellings, the
2 positive allowlist cases, the 4 DNS/path-equivalent spellings (TC-BP-26), and
the 4 wrapper-export statics (TC-BP-25).

**Against the first cut of that change (`2d71c7f`): 42 pass / 14 fail.** Those
14 are the adversarial pins — each was a *verified live bypass or false
positive* in that commit, reproduced and compared against `origin/main` to
confirm it was a regression rather than pre-existing.

The two red sets barely overlap, and that is the point: the parent is red where
it is too *strict* (wiki, allowlist) or where a local-identity check cannot see
the destination at all (second clone, spellings); the first cut is red where it
was too *permissive* (guessed destinations). A pin that only failed on one of the
two would leave the other failure mode unguarded.

Some cases are green on both — e.g. TC-BP-20..23 pass on the parent, because the
parent never allows on the strength of a resolved destination and so cannot
exhibit those bypasses. They are still worth pinning: they constrain this
implementation's allow gate, not the parent's.

For #542, restoring only the old flag-classification arms produces **67 pass /
6 fail**: the two hook-level bare-`--signed` direction checks, the hook-level
`--repo other` destination check, and three direct parser operand checks.
Reapplying the correction produces **73/73**. The other `--repo` hook cases and
the `-o` case deliberately remain green across the change; they pin Git
behavior that must not be "fixed" in the wrong direction.

Suites re-run green alongside this change: `test-block-commit-outside-worktree.sh`
(186), `test-is-git-command-quote-strip.sh` (9), `test-install-git-pre-push.sh`
(8), `test-install-claude-hooks.sh` (10), `test-install-project-hooks.sh` (28),
`test-chp-commit-file.sh` (36), `test-hook-exit-code.sh`.
