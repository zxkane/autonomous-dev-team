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
| What evidence is fresh enough for a terminal decision? | Read provider-normalized state and HEAD, read mergeability once, then read state and HEAD again. A terminal interpretation is valid only when both snapshots describe the same open expected HEAD. |
| What happens for current `MERGEABLE`? | Requeue `pending-dev -> pending-review`. The normal review preflight, E2E, fan-out, CI, approval, and merge gates remain authoritative. |
| What happens for current `CONFLICTING`? | Requeue `pending-dev -> pending-review`. The normal review preflight then enters the existing canonical conflict/rebase route and writes its required durable evidence. |
| What happens for persistent `UNKNOWN`? | Keep the existing bounded terminal stall. The earlier verdict is now corroborated by a fresh same-HEAD provider observation. |
| What happens when the mergeability read fails? | Fail toward defer: retain the residual same-HEAD notice without stalling or dispatching, but return the operational-defer code so the tick does not add `JUST_DISPATCHED`. The existing liveness watchdog then bounds a persistent provider outage. A read failure is not fabricated as fresh `UNKNOWN` evidence. |
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
  chp_mergeable(PR)
        |
        v
  snapshot OPEN/H
        |
        +-- MERGEABLE   --> pending-review --> normal review gates
        +-- CONFLICTING --> pending-review --> canonical conflict/rebase route
        +-- UNKNOWN     --> stalled (bounded, fresh evidence)
        +-- read error  --> residual park --> liveness watchdog bound
        +-- new HEAD    --> pending-review (no stale evidence)
        +-- closed      --> no-op (Step 0 reconciliation)
```

## Guards Preserved

- No global retry count changes.
- No provider normalization changes; GitLab policy states remain `UNKNOWN`.
- No direct approval or merge path is added.
- Final mergeability, CI, review-thread, approval, and merge gates remain in
  the review wrapper.
- Substantive failures, completed sessions, changed HEAD handling, and live
  wrapper liveness remain on their existing branches.
- All provider I/O stays behind `chp_*` and `itp_*` seams.
