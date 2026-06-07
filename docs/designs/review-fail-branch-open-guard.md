# Design: FAIL-gate branches honor the PR-still-open guard (issue #196, INV-54)

## Problem

`autonomous-review.sh` has a PR-still-open guard only in the **PASS** branch
(`gh pr view --json state` → if `!= OPEN`, remove `reviewing` and `exit 0`).
The two INV-44 mergeable hard-gate FAIL branches —

- `block-substantive` (PR `CONFLICTING`), and
- `block-nonsubstantive` (mergeable `UNKNOWN`/empty past the retry budget) —

run **before** that guard and blindly `--remove-label reviewing --add-label
pending-dev` then `exit 0`, with no check of PR state.

So when a PR is merged out-of-band (manual merge, or the PR #191 agent
self-merge incident) while a review run is in flight, and that run then reaches
a block-gate path, the wrapper flips an **already-merged, already-closed** issue
to `pending-dev`. The dispatcher may then re-dispatch dev against a merged PR.

This is the wrapper-side guard-gap half carved out of #193 (which fixed the
agent-self-merge root cause). See #193 and the #191 incident.

## Root cause

The PR-open guard was only ever added to the PASS branch. The INV-44 mergeable
gate branches were added later (#176) and did not inherit it. Both gate branches
and the PASS branch already live inside the single `if [[ "$PASSED_VERDICT" ==
"true" ]]` block, so a **single** open-check at the top of that block covers all
three exits.

## Approach

Hoist the open-check to run **once**, at the top of the
`if [[ "$PASSED_VERDICT" == "true" ]]` gate chain — **before** the mergeable
polling and before any FAIL-branch label flip. This is exactly the issue's
suggested direction ("place it once at the top of the gate chain").

### Pure helper (testable in isolation)

Mirror the lib-split convention used by INV-44's `_classify_mergeable_gate`
(`lib-review-mergeable.sh`): the `gh pr view --json state` I/O stays in the
wrapper; the string→decision mapping moves to a pure helper that can be
unit-tested without a live PR.

`lib-review-mergeable.sh` already owns the mergeable gate and is sourced by the
wrapper; the open-check is the same gate chain, so the helper lives there too
(no new file → **no `install-project-hooks.sh` re-run needed** on onboarded
projects; this is a pure-edit, not an added-file change).

```sh
# _pr_open_gate <state> → "proceed" | "skip"
#   OPEN (any case)  → proceed   (run the mergeable gate + PASS branch as before)
#   anything else    → skip      (PR no longer open: clean -reviewing, no pending-dev)
# Conservative inverse of the PASS guard's `!= OPEN`. UNKNOWN/empty/CLOSED/MERGED
# all → skip, matching the existing PASS-branch semantics (which treated a failed
# `gh` query as UNKNOWN → `!= OPEN` → skip approve/merge).
```

Note the existing PASS-branch guard substitutes `UNKNOWN` for a failed `gh`
query and treats it as non-OPEN (skip approve/merge but still removes
`reviewing`). The hoisted gate preserves that: any non-`OPEN` value (including
the empty/UNKNOWN failed-query case) routes to the clean `-reviewing` exit. This
is intentionally conservative — when in doubt about PR state we do **not** add
`pending-dev`.

### Wrapper wiring

At the top of the `if [[ "$PASSED_VERDICT" == "true" ]]` block (before the
`MERGEABLE_RETRIES` poll loop):

```sh
PR_STATE=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
if [[ "$(_pr_open_gate "$PR_STATE")" == "skip" ]]; then
  log "PR #${PR_NUMBER} is no longer open (state: ${PR_STATE}). Skipping mergeable gate + approve/merge — another review/merge likely completed first."
  gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "reviewing" 2>/dev/null || true
  RESULT_PARSED=true
  exit 0
fi
```

The now-redundant PASS-branch guard (the second `gh pr view --json state` block)
is **removed** — the hoisted check already ran for every PASS-path execution,
so re-querying would be a wasted `gh` call and dead code. DRY: one guard, three
exits.

## Scope (matches issue #196 AC)

Covered exits (all inside the `PASSED_VERDICT == true` chain):

1. `block-substantive` (CONFLICTING)
2. `block-nonsubstantive` (mergeable UNKNOWN)
3. PASS (approve/merge / no-auto-close)

**Out of scope** (deliberately, per the issue carve-out):

- The INV-46 E2E hard gate (runs before the fan-out, separate concern).
- The verdict-FAIL `else` branch (a FAILED verdict on a merged PR is a far rarer
  race and is not what #196 scopes). The issue explicitly lists only the three
  `PASSED_VERDICT == true` exits.

## Invariant

New invariant **INV-54**: *FAIL-gate branches skip the `pending-dev` flip when
the PR is no longer open.* Documented in `docs/pipeline/invariants.md`, with the
state-machine `pending-dev` transitions (rows for INV-44 block paths) and
`review-agent-flow.md` updated to note the shared open-check.

## Why not also guard the E2E gate / FAILED branch?

Minimum-viable interpretation of the issue (autonomous-mode decision guideline:
implement the minimum viable interpretation; the issue scopes exactly three
exits). Widening to the E2E gate or the verdict-FAIL branch would be scope creep
relative to #196's AC and would touch INV-46 docs unnecessarily. A follow-up can
extend the same `_pr_open_gate` helper to those paths if desired.
