# Design: Cheap resume when a prior session pushed the branch but didn't open the PR

Issue: #178

## Problem

`autonomous-dev/SKILL.md` Step 7 runs `git push -u origin <branch>` **immediately before**
`gh pr create`. A session that dies between those two commands leaves a pushed branch with
commits ahead of base **but no PR**. The dispatcher then routes the issue back to
`pending-dev` (Step 5b "Task appears to have crashed (no PR found)" once `dev_near_success`
goes negative), and the next tick re-runs the **entire** dev wrapper from scratch
(re-fetch, re-test, re-implement) only to arrive at `gh pr create` again — where the same
interruption can recur. Result: an `in-progress ↔ pending-dev` oscillation that looks like a
stall even though the branch + commit have been on origin the whole time.

## Architecture constraint (from the issue)

PR creation lives **entirely inside the dev wrapper / agent** — `gh pr create` appears only
in `autonomous-dev/SKILL.md`, executed by the agent with its own PR-body generation. The
dispatcher only *routes* (`dispatch dev-new|dev-resume|review`); under
`EXECUTION_BACKEND=remote-aws-ssm` it runs on a **different box** than the worktree, has no
worktree, and no PR-body generator. **The dispatcher cannot call `gh pr create`.** Therefore
the fix must make *resume* cheap, not move PR creation to the dispatcher.

## Chosen approach (fix direction #1 — the sound fix)

Detect the pushed-but-no-PR state **inside the wrapper** and inject an
`## Open-PR-only fast path` block into the agent prompt that instructs the agent to skip
design/test/implement and go **straight to the open-PR step**, reusing the wrapper's existing
PR-body generation (the `/autonomous-dev` skill's Step 7).

Detection logic (`needs_open_pr_only` helper in `autonomous-dev.sh`):

1. **No open PR for this issue** — reuse the same PR-presence query the cleanup trap already
   uses (`gh pr list ... select(.body | test("#<N>..."))`). If a PR exists, this is NOT the
   target state (the existing PR-exists handoff handles it). Skip.
2. **A head branch was pushed to origin and is ahead of base.** The branch name is
   **agent-chosen** (`feat/issue-${N}*` *or* `fix/issue-${N}*`), so detection must glob, not
   assume a fixed name:
   - `git ls-remote origin 'refs/heads/*issue-${N}*'` enumerates candidate remote branches
     (works on the dispatcher box too — networked, no worktree needed).
   - For each candidate, confirm it has **commits ahead of the base branch** so an empty/
     stale branch with zero new commits is NOT mistaken for finished work. Ahead-count is
     computed against `origin/<base>` via `git rev-list --count origin/<base>..<remote-sha>`
     when the objects are fetchable locally; when they are not (remote-only objects), fall
     back to comparing the remote head SHA against the base head SHA (different SHA + branch
     exists ⇒ treat as ahead). This keeps detection correct in the worktree AND from a
     fetch-light dispatcher box.

When both hold, emit the fast-path block. Otherwise emit nothing (normal full-dev resume).

### Where the block is injected

The helper + block are wired into **both** prompt builders in `autonomous-dev.sh`:

- **`MODE=resume`** resume prompt (the primary path the reproduced loop hits).
- **`MODE=resume` → resume-fallback** (`run_agent` after a failed `resume_agent`) full prompt,
  and the **`MODE=new`** prompt — because after enough resume failures the dispatcher can
  route a fresh `dev-new`, and the branch is still on origin. Covering `new` too means the
  fast path engages no matter which mode the dispatcher picks, satisfying the acceptance
  criterion "opens its PR within the next single tick" regardless of routing.

### Keyword-contract safety ([INV-06])

The fast-path block is a **forward-progress prompt augmentation**, not a status comment. It
contains no `Task appears to have crashed (no PR found)` / `process not found` text, so it
cannot trip Step 4a's crash counter. No new issue/PR *comment* is posted by this change.

## Why not the dispatcher-side hint (fix direction #2)?

It is explicitly "optional, supporting." The wrapper-side detection already works regardless
of whether the dispatcher routes `dev-new` or `dev-resume` — the wrapper inspects origin
itself. Adding dispatcher routing would duplicate the `git ls-remote` probe on the dispatcher
box (extra network calls every tick for every pending-dev issue) for no behavioral gain once
the wrapper is cheap. Minimum-viable interpretation: wrapper-side only.

## New invariant

**INV-45**: pushed-branch-with-commits-ahead + no PR ⇒ resume goes straight to the open-PR
step, never a full design/test/implement re-run. Sibling to [INV-27] (dev near-success) and
the Bug-3/#99 handoff (`handle_pending_dev_pr_exists`).

## Risks

| Risk | Mitigation |
|------|------------|
| False positive: a stale `*issue-N*` branch with zero new commits triggers the fast path | Ahead-of-base check; zero-ahead branches are ignored. |
| `git ls-remote` transient failure | Helper fails closed (returns 1 → normal full-dev resume); no oscillation regression vs. today. |
| Agent ignores the block and re-runs full dev | Best-effort steering; even if ignored, behavior is no worse than today (still eventually opens the PR). |
