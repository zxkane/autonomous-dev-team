# verify-completion.sh — fail-closed truncation guard (#412)

## Problem

`skills/autonomous-common/hooks/verify-completion.sh` issues two raw
`gh api graphql` reads with `reviewThreads(first: 100)` and no awareness of
further pages. On a PR with >100 review threads, unresolved threads beyond
page 1 are invisible: `check_unresolved_reviews` under-counts and the Stop
hook can stop blocking while real unresolved threads remain — a silent
truncation, the same hazard class the CHP seam closed in #401 (W1f).

## Constraints (why not a cursor walk)

- A full pagination loop here would duplicate the cursor-walk logic that
  already lives in `chp_review_threads` (#401) — two implementations of the
  same GraphQL walk to keep in sync.
- Hooks are deliberately dependency-free: they do not source the CHP/ITP
  provider libs, and that boundary stays.
- This Stop hook is a bounded advisory (Claude Code force-ends the turn
  after 8 consecutive no-progress blocks); no merge decision keys on its
  count. The proportionate fix is loud-on-truncation, not full completeness.

## Design

Add `pageInfo { hasNextPage }` to both GraphQL queries. In
`check_unresolved_reviews`, check `hasNextPage` FIRST:

- `hasNextPage == true` → the hook cannot prove all threads are resolved.
  Emit the sentinel `truncated` instead of a count. The caller blocks with a
  distinct message: the PR has >100 review threads, the hook cannot verify
  completeness, verify manually (`gh pr view --web`). The message claims no
  specific count (it cannot know one).
- `hasNextPage == false` (or `pageInfo` absent — old-shape responses) →
  behavior is byte-identical to today: numeric count, existing block
  message on >0, no block on 0.
- GraphQL query failure (`.data == null`) keeps today's fail-open
  `echo "0"` — changing the failure posture is out of scope (#412 body).

The sentinel check must precede the numeric `-gt` comparison in the caller:
bash `[[ -gt ]]` arithmetic-evaluates its operands, so `"truncated"` resolves
as an unset-variable lookup → 0 → `0 -gt 0` → false, **silently, rc 0**. A
missed sentinel would not error under `set -e` — it would silently un-block,
the exact failure this guard exists to prevent.

`get_unresolved_review_details` gets the same `pageInfo { hasNextPage }`
field added for query-shape parity (R1), but its output path is unreachable
in the truncated case — the caller blocks on the sentinel before requesting
details.

## Accepted trade-off

A >100-thread PR whose threads are ALL resolved is blocked up to the 8-round
Stop-hook cap, then force-released with a warning. Bounded annoyance in an
extreme-outlier scenario, in exchange for eliminating a silent false-unblock.

## Test surface

`tests/unit/test-verify-completion-pagination.sh` — hermetic (PATH-stubbed
`gh` + `git`), drives the real hook end-to-end. See
`docs/test-cases/verify-completion-pagination-guard.md`.
