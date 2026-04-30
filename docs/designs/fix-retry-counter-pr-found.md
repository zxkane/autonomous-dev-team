# Design: Exclude "crashed. PR found" from Retry Counter

## Problem

Issue zxkane/quant-scorer#192 was marked `stalled` right after the review agent
completed its first review and posted blocking findings. See the 06:41 comment:
https://github.com/zxkane/quant-scorer/issues/192#issuecomment-4350233257

### Observed timeline
1. 06:08 — dispatcher: "Task appears to have crashed (no PR found)" (real crash #1)
2. 06:16 — dispatcher: "Task appears to have crashed (no PR found)" (real crash #2)
3. 06:31 — dispatcher: "Task appears to have crashed. **PR found** — moving to pending-review"
4. 06:35 — review dispatched
5. 06:38 — review agent posts findings, moves label `reviewing` → `pending-dev`
6. 06:41 — next cycle counts 3 crash comments, marks `stalled`

### Root cause

`skills/autonomous-dispatcher/SKILL.md` Step 4 retry-count regex matches
`"crashed\\. PR found"` as a dispatcher-detected crash. But that event actually
indicates **forward progress**: the dev process produced a PR before exiting, so
the work is successfully handed to review. Counting it as a retry punishes
progress and causes premature `stalled`.

Prior fix #41/#44 only reset the counter on `stalled → unstalled`. It does not
handle the legitimate `review → pending-dev` handoff for blocking findings.

## Fix

Scope: minimal. Remove `crashed. PR found` from the crash-counting regex, and
rename the Step 5 comment so the word "crashed" never appears in a forward-progress
path. This keeps counting accurate without adding new state.

### Changes

1. `skills/autonomous-dispatcher/SKILL.md` Step 4:
   - Drop `|crashed\\. PR found` from the `DISPATCHER_CRASHES` regex.
2. `skills/autonomous-dispatcher/SKILL.md` Step 5:
   - Change the "PR found" comment from `"Task appears to have crashed. PR found — moving to pending-review for assessment."` to `"Dev process exited (PR found). Moving to pending-review for assessment."`
   - This avoids future regex collisions and reads accurately: a PR is not a crash.
3. `tests/unit/test-retry-counter-reset.sh`:
   - Add TC-RCR-004 asserting `crashed. PR found` is no longer in the counting regex.
   - Add TC-RCR-005 asserting the "Dev process exited; PR found" wording is used.

### Non-goals

- Do not change the "no PR found" retry path — that is a real dev failure.
- Do not add a new label or state.
- Do not touch review-side logic.

## Risk

- Historical comments on existing issues still contain the old "crashed. PR found"
  wording. After this change, the new regex will not count them, so any running
  issue's retry counter effectively drops by ≤1. That is the intended effect (those
  instances were never real failures).
- Step 5 comment wording change is cosmetic for humans; no script greps for it.
