# Design: same-HEAD mergeability freshness at terminal recovery (issue #545)

## Problem

`_same_head_verdict_aware_recovery` treats a consumed
`self-heal-non-substantive:<head>` marker as sufficient evidence to stall an
issue. For `cause=mergeable-unknown`, that combines a current retry-budget fact
with a historical provider observation. Mergeability can change while the PR
HEAD stays fixed, especially when GitLab maps policy states such as
`ci_still_running` to normalized `UNKNOWN`.

The terminal branch therefore can stall a conflict-free, now-mergeable PR
without consulting the provider again.

## Decisions

| Question | Decision |
|---|---|
| Which non-substantive causes need a freshness check? | Only `mergeable-unknown`. Other causes keep their existing marker-bounded behavior because they do not claim a mutable provider mergeability state. |
| What evidence is fresh enough for a terminal decision? | Read provider-normalized state and HEAD, reuse the review preflight's bounded mergeability poll, then read state and HEAD again. A terminal `UNKNOWN` requires every poll read to succeed and both snapshots to describe the same open expected HEAD. |
| What happens for current `MERGEABLE`? | Requeue `pending-dev -> pending-review` under the existing `REVIEW_RETRY_LIMIT`. The normal review preflight, E2E, fan-out, CI, approval, and merge gates remain authoritative. |
| What happens for current `CONFLICTING`? | Requeue `pending-dev -> pending-review` under the same cap. The normal review preflight then enters the existing canonical conflict/rebase route and writes its required durable evidence. |
| What happens for persistent `UNKNOWN`? | Keep the existing bounded terminal stall, but only after the full poll succeeds with no decisive token. One unsettled read is never terminal evidence. |
| What happens when a provider read fails? | If the poll never reaches `MERGEABLE` or `CONFLICTING`, fail toward defer: retain the residual same-HEAD notice without stalling or dispatching, but return the operational-defer code so the tick does not add `JUST_DISPATCHED`. INV-128 bounds a persistent outage. |
| How is the refresh requeue bounded and made idempotent? | Write one per-ordinal intent reservation before the label transition. Reservations count toward `REVIEW_RETRY_LIMIT`, including an ambiguous or failed label write, so no post-transition comment failure can escape accounting. A reservation and its `review-aware-flip` completion marker are one logical attempt keyed by session + HEAD + ordinal; duplicate comments for the same key also count once. |
| What if session completion later becomes provable? | The completed-session router uses the same logical counter: ordinary review-aware flips count individually, while freshness reservations/completions count once per key. It therefore cannot requeue after same-HEAD freshness already consumed the cap. An unreadable or malformed comment timeline returns operational defer instead of resetting the count to zero; both dispatcher entry points skip only that issue without setting `JUST_DISPATCHED`, while hard nested errors retain their prior propagation. |
| What happens if the PR closes or HEAD changes during the refresh? | Closed/merged is a no-op for Step 0 reconciliation. A changed HEAD requeues review without binding the old verdict to the new HEAD. |

## Data Flow

```text
failed-non-substantive(mergeable-unknown)
  + self-heal-non-substantive:<H> already present
        |
        v
  snapshot OPEN/H
        |
        v
  bounded chp_mergeable(PR) poll
        |
        v
  snapshot OPEN/H
        |
        +-- MERGEABLE   --> counted pending-review --> normal review gates
        +-- CONFLICTING --> counted pending-review --> canonical conflict route
        +-- persistent successful UNKNOWN --> stalled
        +-- undecided poll with read error --> operational defer --> INV-128
        +-- requeue cap --> stalled (bounded convergence)
        +-- intent read/write error --> operational defer --> INV-128
        +-- duplicate intent ordinal --> same logical attempt (no extra spend)
        +-- failed/ambiguous label write --> reserved retry --> bounded cap
        +-- new HEAD    --> pending-review (no stale evidence)
        +-- closed      --> no-op (Step 0 reconciliation)
```

## Guards Preserved

- No global retry count changes.
- Freshness requeues reuse `REVIEW_RETRY_LIMIT`; no second retry policy exists.
- No provider normalization changes; GitLab policy states remain `UNKNOWN`.
- No direct approval or merge path is added.
- Final mergeability, CI, review-thread, approval, and merge gates remain in
  the review wrapper.
- Substantive failures, completed-session routing decisions, changed HEAD
  handling, and live wrapper liveness remain on their existing branches. The
  completed router only shares the corrected logical retry accounting.
- All provider I/O stays behind `chp_*` and `itp_*` seams.
