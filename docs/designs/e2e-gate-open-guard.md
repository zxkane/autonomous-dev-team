# Design: E2E hard-gate block branches honor the PR-still-open guard (issue #195, INV-54 extension)

## Problem

`autonomous-review.sh` re-checks PR state before writing a `reviewing →
pending-dev` label transition in the **mergeable** hard-gate block branches and
the PASS branch — all three exits of the `if [[ "$PASSED_VERDICT" == "true" ]]`
chain are guarded by the single hoisted `_pr_open_gate` check added by INV-54
(#196). But the **INV-46 E2E hard gate** runs much earlier — *before* the review
fan-out, *before* the verdict is even computed — and its two block branches:

- `fail` (lane `.rc` ≠ 0 — substantive E2E failure), and
- `block-nonsubstantive` (lane clean but no SHA-matching evidence — transient),

unconditionally `--remove-label reviewing --add-label pending-dev` then
`exit 0`, with **no** check of PR state.

So when a PR is merged/closed out-of-band (a concurrent review, a manual merge,
or the agent self-merge incident in #193/#191) *while the E2E lane is running*,
and the lane then resolves to `fail` / `block-nonsubstantive`, the wrapper flips
an **already-merged, already-closed** issue to `pending-dev`. The dispatcher may
then re-dispatch dev against a merged PR — the exact wrong-label-on-a-closed-issue
symptom INV-54 closed for the mergeable branches, but on the E2E gate instead.

INV-54's design doc named this explicitly as out-of-scope-for-#196 and deferred
it: *"The INV-46 E2E hard gate … is out of scope … A follow-up can extend the
same `_pr_open_gate` helper to those paths."* **This is that follow-up.**

## Root cause

The INV-54 open-check is hoisted to the top of the `PASSED_VERDICT == true`
chain. The E2E gate is a **separate, earlier** decision block (`if [[
"${E2E_ACTIVE:-false}" == "true" ]]`) that runs before the fan-out and thus
before `PASSED_VERDICT` exists. INV-54's single hoisted check structurally
cannot cover it. The E2E gate's block branches were added by INV-46 (#182)
without an open-check and were deliberately excluded from the INV-54 carve-out.

## Reconciliation with issue #195 as filed

Issue #195 lists three branches by line number against the pre-INV-54 source:
`:1425` (mergeable `block-substantive` / CONFLICTING), `:1461` (mergeable
`block-nonsubstantive` / UNKNOWN), and `:963` (the E2E gate block). Between the
issue being filed and this fix, **INV-54 (#196, merged as `dfaaa5e`) already
guarded the two mergeable branches** via the hoisted `_pr_open_gate`. So the
only branch in #195's list still missing the guard is the **E2E gate** (now at
`autonomous-review.sh:1060` `fail` / `:1084` `block-nonsubstantive`). This PR
closes exactly that remaining gap; the mergeable-branch acceptance criteria of
#195 are already satisfied by INV-54 and are re-pinned (not re-implemented) here.

## Approach

Mirror INV-54 exactly. Reuse the existing pure helper `_pr_open_gate`
(`lib-review-mergeable.sh`) — no new file, so **no `install-project-hooks.sh`
re-run** is required on onboarded projects (pure edit of an already-sourced lib +
the wrapper).

Hoist a single open-check to the **top of the E2E gate's block routing** — after
the lane has run and `E2E_GATE` is classified, but **before** the two block
branches' `pending-dev` writes. Only the two block branches (`fail`,
`block-nonsubstantive`) write `pending-dev`; the `pass` / `inactive` outcomes
fall through to the fan-out unchanged, so the open-check is placed to gate only
the block exits:

```sh
# E2E gate fail / block → route WITHOUT fanning out the review agents.
if [[ "$E2E_GATE" == "fail" || "$E2E_GATE" == "block-nonsubstantive" ]]; then
  # PR-open guard (INV-54 extension, #195): a concurrent review, a manual merge,
  # or the #191 agent self-merge may have merged/closed the PR while the E2E lane
  # ran. Do NOT flip an already-closed issue to pending-dev. Mirrors the hoisted
  # mergeable/PASS-chain guard; reuses the same _pr_open_gate helper.
  E2E_PR_STATE=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json state -q '.state' 2>/dev/null || echo "UNKNOWN")
  if [[ "$(_pr_open_gate "$E2E_PR_STATE")" == "skip" ]]; then
    log "PR #${PR_NUMBER} is no longer open (state: ${E2E_PR_STATE}) at the E2E gate. Skipping the pending-dev flip — another review/merge likely completed first."
    gh issue edit "$ISSUE_NUMBER" --repo "$REPO" --remove-label "reviewing" 2>/dev/null || true
    RESULT_PARSED=true
    exit 0
  fi
fi
```

This sits immediately before the existing `if [[ "$E2E_GATE" == "fail" ]]; then
… elif [[ "$E2E_GATE" == "block-nonsubstantive" ]]; then …` cascade. When the PR
is OPEN the guard is a no-op and the cascade runs **byte-for-byte as today**
(regression-pinned). When the PR is not OPEN, it removes `reviewing` only and
exits 0 — never adds `pending-dev` — exactly as the INV-54 mergeable/PASS guard
does.

### Why one combined check instead of two

The two block branches both end in `−reviewing +pending-dev; exit 0`. A single
pre-cascade open-check covers both with **one** `gh pr view` call (cost parity
with INV-54's single hoisted query). Putting the check inside each branch would
duplicate the query and the skip-exit block — the DRY anti-pattern INV-54
explicitly removed from the PASS path.

### Why `_pr_open_gate` is reused, not re-defined

`_pr_open_gate` is already the canonical PR-state → {proceed, skip} mapping
(case-insensitive `OPEN` → proceed; `MERGED`/`CLOSED`/`UNKNOWN`/empty/garbage →
skip; failed `gh` query substitutes `UNKNOWN` → skip). The E2E gate wants the
identical semantics, so it calls the same helper. No behavior duplication, no
new helper to test.

## Scope

Covered: the two INV-46 E2E hard-gate block exits (`fail`,
`block-nonsubstantive`).

Out of scope (unchanged from this PR):

- The mergeable block branches + PASS branch — already guarded by INV-54.
- The verdict-`FAILED` `else` branch (`autonomous-review.sh` ~`:1761`) and the
  auto-merge-failure sub-branch. A FAILED verdict implies the fan-out already
  ran (the PR was open when the review agents started), and a merge-failure
  branch only runs after a successful approval on an open PR — both are far
  rarer races than the E2E gate, which runs *before* any verdict. INV-54 made
  the same minimum-viable scoping call for the PASS chain. Left for a future
  follow-up if a real incident surfaces.

## Invariant

Extend **INV-54** with a sub-rule: the PR-still-open guard also gates the INV-46
E2E hard-gate block branches (`fail` / `block-nonsubstantive`) — a PR merged
mid-E2E never receives `pending-dev`. The guard is now applied at **two** points
in the wrapper (the hoisted `PASSED_VERDICT` chain head, and the E2E gate block
head), both delegating to the single `_pr_open_gate` helper.

Docs updated in the same PR (Pipeline Documentation Authority):
`docs/pipeline/invariants.md` (INV-54 sub-rule), `docs/pipeline/state-machine.md`
(the two E2E `→ pending-dev` rows now note the PR-open precondition + a new
`−reviewing` no-add row for the E2E concurrent-merge case),
`docs/pipeline/review-agent-flow.md` (Sequential E2E lane § notes the guard).
