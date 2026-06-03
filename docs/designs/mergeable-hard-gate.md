# Design: Wrapper-enforced mergeable hard gate (issue #176, INV-44)

## Problem

A PR with an unresolved merge conflict against its base branch
(`mergeable == CONFLICTING`) can still be **approved** by the autonomous-review
pipeline. Today the only mergeable check lives in **Step 0 of the review
agent's prompt** (`build_review_prompt` → "MANDATORY PRE-REVIEW"). That is
prompt text the agent is *trusted* to execute; it is not enforced by the
wrapper, and the verdict aggregation (`_aggregate_review_verdicts` →
`PASSED_VERDICT`) never re-consults `mergeable` before acting on a PASS.

When the agent skips Step 0 (or the `UNKNOWN → treat as MERGEABLE` fallback in
`references/merge-conflict-resolution.md` misfires), a CONFLICTING PR sails
through as PASS and lands in the terminal `approved` state. The conflict then
has **no owner**: dev-resume already exited, and review judged PASS, so the
rebase falls through the cracks until an operator notices.

This is the same shape as the previously-closed prompt-only E2E-poll gap: the
correct behaviour is written in the prompt, but nothing in the wrapper enforces
it, so an agent that doesn't follow the prompt produces a structurally invalid
verdict.

## Goal

Make `mergeable` a **wrapper-enforced gate**, mechanically equivalent to "any
blocking finding → FAIL", independent of whether the review agent ran Step 0.

## Design

### Where the gate runs

In `autonomous-review.sh`, immediately **after** the `case "$AGGREGATE"` block
sets `PASSED_VERDICT` and **before** the wrapper acts on a PASS (the
`emit_verdict_trailer "passed"` + approve/merge branch). The gate only matters
when the aggregate was `pass` — a `fail` / `all-unavailable` aggregate already
routes to `pending-dev`, so re-checking mergeable for those is redundant.

```
case "$AGGREGATE" in pass|fail|all-unavailable) ... esac   # sets PASSED_VERDICT
            │
            ▼
┌───────────────────────────────────────────────────────┐
│ MERGEABLE HARD GATE  (only when PASSED_VERDICT == true) │
│   m = gh pr view <PR> --json mergeable -q .mergeable    │
│       (retry while UNKNOWN, up to N attempts)           │
│   gate = _classify_mergeable_gate "$m"                  │
│     MERGEABLE   → proceed (no change to happy path)     │
│     CONFLICTING → block-substantive                     │
│     UNKNOWN     → block-nonsubstantive (re-queue)       │
└───────────────────────────────────────────────────────┘
            │ block-*                       │ proceed
            ▼                               ▼
   post [BLOCKING] finding on issue   existing PASS branch
   post "Auto-merge failed:" marker    (approve + merge) UNCHANGED
     on PR (triggers dev-resume rebase, only for CONFLICTING)
   emit_verdict_trailer (substantive | non-substantive mergeable-unknown)
   −reviewing +pending-dev ; exit 0
```

The gate is **self-contained**: on a block it posts, emits its own trailer,
flips the label, and `exit 0`s — it does NOT thread through the existing FAIL
branch. This keeps every existing PASS/FAIL/crash branch byte-for-byte
unchanged (important: this wrapper is heavily regression-pinned).

### Pure decision helper (unit-testable)

The mergeable→action decision is extracted into
`lib-review-mergeable.sh::_classify_mergeable_gate <mergeable>`:

| input (`mergeable`)        | echoes               | meaning                              |
|----------------------------|----------------------|--------------------------------------|
| `MERGEABLE`                | `proceed`            | happy path — approve/merge unchanged |
| `CONFLICTING`              | `block-substantive`  | dev must rebase                      |
| `UNKNOWN` / empty / other  | `block-nonsubstantive` | GitHub still computing / unknowable; re-queue |

"Conservative default": anything not explicitly `MERGEABLE` and not
`CONFLICTING` (including an empty string from a failed `gh` call, or a literal
`UNKNOWN` that survived the retry budget) is `block-nonsubstantive` — never
`proceed`. This is what closes the stale-`UNKNOWN` pass-through: a value GitHub
hasn't resolved can never be silently treated as mergeable.

The wrapper does the `gh` query + `UNKNOWN` retry loop (`MERGEABLE_RETRIES`,
default 3, 10s apart) and calls the helper once on the settled value.

### Routing on a block

- **CONFLICTING (`block-substantive`)**: dev genuinely must rebase.
  - Post `[BLOCKING] Merge conflict with main` finding on the **issue** with the
    dev-actionable rebase instructions (mirrors
    `references/merge-conflict-resolution.md`).
  - Post an `Auto-merge failed:`-prefixed marker on the **PR**. This reuses the
    existing dev-resume hook (`autonomous-dev.sh` greps PR comments for a body
    starting `Auto-merge failed:` and prepends a "rebase onto main" pre-step to
    the resume prompt). That is exactly the owner we want: the next dispatched
    dev session rebases first.
  - `emit_verdict_trailer ... failed-substantive` (the conflict is a real,
    dev-actionable finding — INV-35 routes a completed dev session through the
    substantive recovery path).
- **UNKNOWN past the retry budget (`block-nonsubstantive`)**: not dev's fault;
  GitHub is still computing or returned an unusable value.
  - Post a short status comment on the **issue** (no PR marker — there may be no
    actual conflict, so we must NOT trigger an unnecessary rebase).
  - `emit_verdict_trailer ... failed-non-substantive mergeable-unknown` so the
    dispatcher re-routes to review next tick (re-queue/wait), not a dev retry.
- Both: `−reviewing +pending-dev` (keep `autonomous`), `RESULT_PARSED=true`,
  `exit 0`.

### Why `pending-dev` (not a new label)

`pending-dev` + `autonomous` is the state the dispatcher's `list_pending_dev`
selector already picks up, and the dev-resume rebase hook already exists. No new
label ⇒ no state-machine node added; only a new *reason* for an existing
transition (`reviewing → pending-dev`), which the state-machine doc records
under the existing "Invalid combinations / transitions" prose.

## Backward compatibility

- Happy path (`MERGEABLE` + unanimous PASS) is byte-for-byte unchanged: the gate
  evaluates `proceed` and falls straight through to the existing PASS branch.
- The gate adds exactly **one** `gh pr view --json mergeable` call on the PASS
  path (plus retries only while UNKNOWN). No new call on the FAIL/crash paths.
- No new label; `emit_verdict_trailer` gains one new non-substantive cause token
  (`mergeable-unknown`) — already permitted by its `[a-z0-9-]+` whitelist.

## Alternatives considered

- **Wrapper owns the rebase deterministically** (issue suggestion #3-optional):
  rebase-onto-base in a throwaway worktree, force-push on clean rebase, only
  FAIL→pending-dev on real conflicts. Deferred — larger scope, and the
  `Auto-merge failed:` dev-resume hook already owns the rebase deterministically
  once we route to `pending-dev`. Routing-to-the-existing-owner is the minimum
  viable interpretation that closes the "nobody owns it" gap.
- **Gate inside the verdict-aggregation helper**
  (`_aggregate_review_verdicts`): rejected — that helper is pure (no `gh`), and
  mergeable is a PR-state fact, not a per-agent verdict. Keeping the I/O in the
  wrapper and the decision in a pure helper mirrors the
  `lib-review-aggregate.sh` split.

## Cross-references

- `docs/pipeline/invariants.md::INV-44` — the new invariant.
- `docs/pipeline/review-agent-flow.md` — runtime walkthrough of the gate.
- `docs/pipeline/state-machine.md` — new reason for `reviewing → pending-dev`.
- `skills/autonomous-review/references/decision-gate.md` — agent-side
  reinforcement (mergeable is a blocking finding).
- `skills/autonomous-review/references/merge-conflict-resolution.md` — the
  `UNKNOWN` pass-through tightened.
