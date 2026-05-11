# Test Cases: dispatcher script exec-bit fix (#97)

## Cases

| ID | What | Expected |
|---|---|---|
| TC-EXEC-001 | `git ls-tree HEAD` mode of `autonomous-dev.sh` | `100755` |
| TC-EXEC-002 | `git ls-tree HEAD` mode of `autonomous-review.sh` | `100755` |
| TC-EXEC-003 | `git ls-tree HEAD` mode of every sourced-only `lib-*.sh` (regular files, not symlinks) | `100644` (preserved) |
| TC-EXEC-004 | dispatcher-tick.sh contains the self-healing block scoped to `autonomous-dev.sh autonomous-review.sh` | found |
| TC-EXEC-005 | dispatcher-tick.sh self-healing block does NOT use blanket `*.sh` glob | confirmed (would flip libs) |
| TC-EXEC-006 | lib-installer.sh exposes `ensure_dispatcher_scripts_executable` | function defined |
| TC-EXEC-007 | every `install-*-hooks.sh` calls `ensure_dispatcher_scripts_executable` | grep finds the call |
| TC-EXEC-008 | autonomous-dispatcher/SKILL.md contains a #97 note (forces hash bump for consumer-side update detection) | found |

## Out of scope

- Functional test of the dispatcher tick under a stripped-mode scenario
  — covered by code inspection (the new block is a 4-line `[[ -x ]] && chmod +x`).
- Behavior of `npx skills update` against the bumped SKILL.md — that's
  the third-party tool's behavior, not ours to test.
