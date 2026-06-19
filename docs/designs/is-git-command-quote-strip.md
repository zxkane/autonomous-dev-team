# Design: stop the `is_git_command` quote-strip infinite-loop ([INV-82])

Issue #266 / PR #267. A bug fix in the workflow-enforcement hook library
[`skills/autonomous-common/hooks/lib.sh`](../../skills/autonomous-common/hooks/lib.sh).

## Problem

`is_git_command(operation, command)` decides whether a shell command actually
invokes `git <operation>` (so the gating hooks — `block-push-to-main`,
`block-commit-outside-worktree`, etc. — only fire on real invocations, not on a
`git push` mention buried inside a quoted argument like `--body "see git push
docs"`). To do that it first **strips quoted regions** from the command:

```bash
local stripped="$command"
while [[ "$stripped" =~ \"[^\"]*\" ]]; do
  stripped="${stripped/${BASH_REMATCH[0]}/ }"   # ← unquoted: BUG
done
while [[ "$stripped" =~ \'[^\']*\' ]]; do
  stripped="${stripped/${BASH_REMATCH[0]}/ }"   # ← same bug
done
```

The match is fed into a bash parameter-substitution **unquoted**. The first
operand of `${var/pattern/repl}` is interpreted as a **glob pattern**, but
`BASH_REMATCH[0]` is *literal* matched text. When the matched region contains a
glob-significant character, the substitution does not match the literal text it
came from:

- **escaped quote** `git commit -m "fix \"x\" y"` → regex matches `"fix \"`; the
  `\"` inside the substitution pattern is a glob escape, so it does not match the
  literal backslash+quote → **no-op**.
- **glob class** `git commit -m "fix [x]"` → `[x]` is a character class → **no-op**.
- `?` / `*` likewise are glob metacharacters.

A no-op substitution leaves `stripped` unchanged, so the `while [[ … =~ … ]]`
test re-matches the *identical* region forever → a **100%-CPU busy-loop**. The
hook never returns; when the parent session exits, the spinner reparents to init
(`PPID=1`) and burns a core indefinitely. Every PreToolUse `git`-gating hook
sources this function, so one offending command fans out to ~4 spinners per
session tick.

### Observed incident

On the shared dispatcher/wrapper host: **212** orphan hook processes, all
`PPID=1`, `ps` state `R` (on-CPU), ~7h53m CPU each, oldest spawned 2026-06-13.
`/proc/<pid>/syscall` empty, `wchan`=0, `utime` ≫ `stime` — a pure userspace
busy-loop, not blocked I/O. (This corrects an earlier "stuck `cat` on a dead
session socket" theory; there is no blocked `cat`.)

## Goal

Make the quote-strip **terminate on every input** in bounded time, with no
subprocess and no behavior change in the common (non-glob) case. Pin the
termination contract as a documented invariant so the regression cannot recur
silently.

## Non-goals

- Making the quote parser fully shell-correct for escaped quotes. The ERE still
  treats `\"` as a region boundary, so a *missed strip* (a `git push` mention
  surviving inside an escaped inner quote) remains possible. That is documented
  defense-in-depth behavior — the intent is to suppress incidental mentions, not
  to defeat an adversarial author, who can always use `--no-verify`. A full
  shell-quoting parser is out of scope for this fix.

## Approach

Quote the match so bash substitutes it **literally**, removing the glob
interpretation entirely. This fixes the actual bug with a two-character change on
each loop and no semantic change:

```bash
stripped="${stripped/"${BASH_REMATCH[0]}"/ }"   # both loops
```

Considered and rejected: a forward-progress guard (`break` when the substitution
left the string unchanged). It would also stop the spin, but it papers over the
root cause (it would silently leave a glob-bearing region un-stripped) rather than
removing the bug class. Quoting the operand is the direct, complete fix.

The function's existing limitation comment is updated: the worst case was an
*infinite loop*, not a *missed match*.

## Invariant

[INV-82](../pipeline/invariants.md):
the `is_git_command` quote-strip MUST terminate on every input — a glob-significant
char inside a quoted region can never spin the strip loop. Producer: `is_git_command`
in `lib.sh` (and every hook sourcing it). Consumer: every git-gating PreToolUse /
PostToolUse hook, which relies on the function returning a verdict promptly.

## Test plan

See [`docs/test-cases/is-git-command-quote-strip.md`](../test-cases/is-git-command-quote-strip.md).
Regression test: [`tests/unit/test-is-git-command-quote-strip.sh`](../../tests/unit/test-is-git-command-quote-strip.sh)
— bounded-time assertions (escaped-quote payload, `[x]`/`?`/`*` glob metachars,
single-quote sibling, whole-`block-commit`-hook on the repro payload, each run
under `timeout` in a fresh `bash` so a pre-fix loop cannot hang the harness) plus
no-regression correctness assertions (quoted-only mention NOT matched; genuine
`git push` / `git commit` still matched). The existing `test-is-git-command.sh`
and `test-block-push-regex.sh` stay green.
