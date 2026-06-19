# Test Cases: `is_git_command` quote-strip loop (issue #266)

## Context

`is_git_command()` in `skills/autonomous-common/hooks/lib.sh` strips quoted
regions from the command before scanning for a `git <operation>` invocation. The
strip used `${stripped/${BASH_REMATCH[0]}/ }` — an **unquoted** parameter
expansion, so the matched text was interpreted as a **glob pattern** rather than
substituted literally. When the matched region contained a glob-significant
character (`\`, `[`, `?`, `*`), the substitution matched nothing, `stripped` was
unchanged, and the `while [[ … =~ … ]]` test re-matched the identical region
forever → 100% CPU busy-loop that leaked orphan processes (PPID=1).

The fix quotes the match — `${stripped/"${BASH_REMATCH[0]}"/ }` — forcing a
literal substitution and removing the glob-pattern interpretation entirely.

## Test IDs

| ID | Scenario | Expectation |
|----|----------|-------------|
| TC-IGC-QS-001 | escaped-quote payload `git commit -m "fix \"x\" y"` | `is_git_command` returns within a hard `timeout 2` (124 before fix, terminates after) — the case that produced the 212 orphans |
| TC-IGC-QS-002 | glob char class `git commit -m "fix [x]"` | returns within bounded time |
| TC-IGC-QS-003 | glob `?` `git commit -m "fix ?"` | returns within bounded time |
| TC-IGC-QS-004 | glob `*` `git commit -m "fix *"` | returns within bounded time |
| TC-IGC-QS-005 | git verb only inside a quoted arg `git commit -m "remember to git push later"` | NOT detected as `push` (quote-strip still works for the normal case) |
| TC-IGC-QS-006 | genuine `git push origin main` | still detected as `push` (no gating regression) |
| TC-IGC-QS-007 | genuine `git commit -m "msg"` | still detected as `commit` (no gating regression) |
| TC-IGC-QS-008 | single-quote sibling with glob payload `git commit -m 'fix [x] ?'` | returns within bounded time (line-93 path) |
| TC-IGC-QS-009 | reproduction payload through `block-commit-outside-worktree.sh` | hook exits non-124 on the escaped-quote repro (whole-hook regression) |

## Acceptance criteria (from issue #266)

- `is_git_command` returns within bounded time for any command containing
  glob-significant characters inside quotes (no infinite loop under any input).
- No regression: commands mentioning a git verb only inside quotes are still NOT
  matched; genuine `git push` / `git commit` invocations are still matched.
- All hooks sourcing `is_git_command` / `parse_command` exit promptly on the
  reproduction payloads.
- Bounded-time regression unit test added covering the escaped-quote case AND at
  least one glob-metachar case.
- Existing hook unit tests remain green.
