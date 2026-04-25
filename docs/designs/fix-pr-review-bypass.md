# Fix: check-pr-review Hook Bypass and is_git_command Substring Match

**Date:** 2026-04-25
**Issue:** #48
**Status:** Approved

## Problem

### Primary: pr-review mark is a ritual, not a receipt

`check-pr-review.sh` calls `state-manager.sh check pr-review`, which only
verifies a JSON state file exists and was written less than 30 minutes ago.
The mark has no tie to the diff that is being pushed, so:

- Running `hooks/state-manager.sh mark pr-review` unblocks pushes for 30
  minutes across any number of commits.
- In long sessions the mark becomes a learned incantation rather than a
  gate; the enforcement succeeds but the intent (a real review) does not.
- A single mark covers 30 commits identically to 1 commit. The tooling
  cannot distinguish "reviewed this diff" from "reviewed something 29
  minutes ago".

### Minor: is_git_command substring match

`lib.sh::is_git_command` uses the regex `git[[:space:]]+${operation}`.
This matches the operation name anywhere in the command line, so a
command like `gh issue create --body "run git push later"` trips the
push hooks. Filing an issue about this bug via the CLI is itself blocked
by the hook chain.

## Fix

### 1. Commit-SHA binding for `pr-review` (Option 2 from the issue)

`state-manager.sh` already records `git_head` at mark time. Extend the
`check` command with an optional action-specific rule:

- For `pr-review`: compare `git_head` in the state file against
  `git rev-parse HEAD` right now. If they differ, the state is stale —
  delete it and fail. Mark becomes a receipt for a specific commit, not
  a 30-minute window.
- For other actions: keep existing time-based behaviour (they relate to
  staged work, not pushed commits).

Rationale for scoping to `pr-review` only:
- `code-simplifier` runs pre-commit, before HEAD advances, so SHA
  binding would break it on the first commit.
- `test-plan`, `design-canvas`, `unit-tests` are authored before
  commits and re-used across the branch — not per-commit artifacts.
- `pr-review` is the only action whose intent is explicitly
  per-diff-being-pushed, so the SHA-binding semantics fit cleanly.

The 30-minute timeout is retained as a secondary guard.

### 2. Subcommand match in `is_git_command`

Rewrite the matcher to require the operation as the first non-flag
token after `git`. Accept an optional leading path (`bash scripts/foo;
git push`) and global flags like `-c user.email=…` before the
subcommand, but reject matches inside quoted strings or embedded
commands.

Approach: use bash parameter expansion to extract tokens after `git`
and compare the first non-flag token to the requested operation.

```bash
is_git_command() {
  local operation="$1"
  local command="$2"

  # Extract everything after the first occurrence of `git ` (word-bounded).
  # Require `git` to be at start-of-string or preceded by whitespace/;/&/|.
  if ! [[ "$command" =~ (^|[[:space:]\;\&\|])git[[:space:]]+(.*) ]]; then
    return 1
  fi
  local rest="${BASH_REMATCH[2]}"

  # Skip global flags like -c key=value, -C path, --git-dir=...
  while [[ "$rest" =~ ^(-c[[:space:]]+[^[:space:]]+|-C[[:space:]]+[^[:space:]]+|--[a-zA-Z-]+(=[^[:space:]]+)?)[[:space:]]+(.*) ]]; do
    rest="${BASH_REMATCH[3]}"
  done

  # First remaining token should be the subcommand
  local subcmd="${rest%%[[:space:]]*}"
  [[ "$subcmd" == "$operation" ]]
}
```

This accepts:
- `git push`, `git push origin main`
- `git -c user.name=foo push`
- `cd /tmp && git push`

And rejects:
- `gh issue create --body "mentions git push"` (no word-bounded `git `
  at start or after `;&|`)
- `echo "git push"` (same reason — inside quotes)
- `git log` when checking for `push`

Note: we cannot perfectly parse quoted strings in bash regex, but
requiring a word boundary before `git` (start of line or `;&|` +
whitespace) and the subcommand being the next non-flag token
eliminates the overwhelming majority of false positives from issue
bodies and echo commands.

## Tests

See `docs/test-cases/fix-pr-review-bypass.md`. Covered by:
- `tests/unit/test-pr-review-bypass.sh` — SHA binding behaviour
- `tests/unit/test-is-git-command.sh` — subcommand matcher

## Impact

- **Backward compatibility:** `mark pr-review` and `check pr-review`
  keep the same CLI. The check becomes stricter (fails when HEAD
  advances). Users must re-run review + mark after each new commit.
  This is the intended behaviour.
- **Other `check <action>` callers:** unchanged. Only `pr-review`
  gets the SHA-binding rule.
- **Existing hooks using `is_git_command`:** all still match their
  intended git subcommands. False positives from substring-in-quoted-
  strings disappear.
