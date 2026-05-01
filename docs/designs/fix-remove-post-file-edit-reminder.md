# Design: Remove post-file-edit-reminder Hook

## Problem

`autonomous-common/hooks/post-file-edit-reminder.sh` fires on every
`Write|Edit|MultiEdit` PostToolUse event and emits a ~150-word
`additionalContext` block reminding the agent to run tests, typecheck,
code-simplifier, and pr-review.

In practice this fires after *every* edit — dozens of times per task — and
causes two concrete failures:

1. **Premature interruption mid-task.** The reminder reads as a "do this now"
   checklist and nudges the agent to end the turn between edits, treating each
   intermediate edit as a milestone. Real sessions have seen the agent stop
   before the planned verification step because the hook text made it feel like
   a natural hand-off point.
2. **Context dilution.** ~150 words of evergreen boilerplate repeated verbatim
   on every edit (~3 KB across a 20-edit task) competes with the actual task
   context. The advice is also generic (`npm test`, `npm run typecheck`) and
   does not adapt to project-specific commands.

### Why the hook is redundant

The reminder adds nothing the existing enforcement doesn't already cover:

- `skills/autonomous-dev/SKILL.md` explicitly describes when to run tests,
  code-simplifier, and pr-review as part of the workflow (Steps 5, 6, 8).
- `check-pr-review.sh` hard-blocks pushes until the pr-review agent has run.
- `check-code-simplifier.sh` hard-blocks commits until code-simplifier has run.
- `check-unit-tests.sh` hard-blocks commits when unit tests fail.
- `block-commit-outside-worktree.sh` / `block-push-to-main.sh` hard-block the
  actual dangerous mistakes.

The blocking hooks are the load-bearing enforcement. The per-edit reminder is
pure noise on top.

## Fix

Scope: remove the hook entirely (option 1 from the issue). The SKILL.md
workflow prose plus the blocking hooks provide the real discipline.

### Changes

1. **Delete** `skills/autonomous-common/hooks/post-file-edit-reminder.sh`.
2. **Unregister** from hook configs:
   - `.claude/settings.json` — remove the two `PostToolUse` matchers
     (`Write|Edit` and `MultiEdit`) that point at the script.
   - `.kiro/agents/default.json` — remove the corresponding entry.
   - `skills/autonomous-dev/SKILL.md` — remove the two registration snippets
     in the hook configuration block.
3. **Documentation:**
   - `skills/autonomous-common/SKILL.md` — drop the row from the hook table.
   - `skills/autonomous-common/hooks/README.md` — drop the row from the hook
     table.
   - `README.md` — drop the row from the hook summary.
   - `CLAUDE.md` — remove `post-file-edit-reminder.sh` from the project
     structure listing.

Existing spec/plan references under `docs/superpowers/` are historical records
and are left untouched.

## Non-Goals

- Do not add a replacement "smarter" reminder hook. If a load-bearing reminder
  is later desired (option 2/3 from the issue), it can be introduced in a
  separate change after observing whether removal causes any regression.
- Do not change the other PostToolUse/PreToolUse hooks.

## Verification

- `grep -r "post-file-edit-reminder" .` returns no hits after the change
  (except possibly pre-existing historical design docs under
  `docs/superpowers/` which are intentionally untouched).
- `.claude/settings.json` and `.kiro/agents/default.json` parse as valid JSON.
- Run `bash hooks/state-manager.sh list` to confirm state manager is unaffected.
- Manually trigger an Edit in a test session and confirm no reminder is
  emitted.

## Risk

Low. The hook produces advisory text only — removing it cannot break the
workflow. The enforcement path is unchanged.
