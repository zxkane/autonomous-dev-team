# Design - pre-fan-out mergeability preflight (issue #540)

Feature: Conflict-aware review preflight
Date: 2026-07-30
Status: Approved (autonomous mode)

## Problem

The review wrapper currently runs INV-46 E2E before the only wrapper-owned
mergeability gate. A conflicting PR whose E2E command fails never reaches the
post-fan-out INV-44 conflict route, so the dispatcher sees no reviewed-head
evidence and sends the unchanged head back through review.

The fix must reject a known conflict before E2E while retaining INV-44 after
fan-out as the race-closing check.

## Control Flow

```text
resolve linked PR
  -> capture {state, full head, branch}
  -> poll chp_mergeable with MERGEABLE_RETRIES and
     MERGEABLE_RETRY_DELAY_SECONDS
  -> capture {state, full head, branch} again
     -> not OPEN: INV-54 remove-only cleanup
     -> head changed: failed-non-substantive(head-changed) -> pending-review
     -> stable MERGEABLE: continue to INV-46 and fan-out
     -> stable CONFLICTING: canonical conflict route -> pending-dev
     -> stable UNKNOWN/empty: mergeable-unknown route -> pending-dev
     -> snapshot read failed: non-substantive retry -> pending-review

fan-out PASS
  -> existing PR-open guard
  -> poll chp_mergeable again
  -> re-read state and full head against the reviewed head
     -> closed: INV-54 remove-only cleanup
     -> head changed/read failed: pending-review without stale conflict evidence
     -> stable CONFLICTING: same canonical conflict route
     -> stable UNKNOWN/empty: existing non-substantive route
     -> stable MERGEABLE: continue to CI rollup and approval
```

The second poll is intentionally not removed. A base update can introduce a
conflict after the preflight and before approval. Its terminal decision is
also HEAD-pinned: a force-push during the poll cannot bind conflict evidence to
the head that fan-out reviewed.

## Shared Disposition Contract

`lib-review-disposition.sh` owns rendering and parsing:

```text
<!-- review-disposition: issue=<N> head=<40-lowercase-hex> phase=pre-fanout result=<conflict-rebase|mergeable-unknown> -->
```

The parser accepts only a whole-body match, the active issue number, a full
normalized head, the literal phase, and one allow-listed result. Reads request
the provider's strict self-author normalization. Human prose, quotes,
abbreviated heads, wrong-issue markers, and trailing content are excluded.

`last_reviewed_head` remains unchanged for INV-04 consumers. A new routing
evidence helper examines strict-self comments once and selects the newest valid
item by `(createdAt,id)` across:

- the existing `Reviewed HEAD:` trailer; and
- the new pre-fan-out disposition marker.

The dispatcher asks the helper for the newest evidence matching the current PR
head before entering the existing INV-35/INV-85/INV-98 verdict-aware route.
Older-head evidence does not suppress review of a newer head. Every terminal
same-head route re-reads the PR before acting, including the no-session and
unconfirmed-session recovery paths, so a force-push after the initial
comparison requeues review without dispatching against stale evidence.

Canonical disposition and Reviewed-HEAD anchors remain write-once per tuple.
When a force-push sequence returns from A to B and back to A, current-head
filtering reuses the existing A anchor instead of duplicating it. Freshness is
carried by the required verdict, whose trailer appends
`head=<full-lowercase-head>`: it must match the active head, occur after the
newest routing evidence of any head, and occur after any newer INV-85
`no-progress-substantive-attempt:<head>` boundary. The dispatcher therefore
classifies the current review round rather than reusing a stale pre-attempt
verdict, including an identical verdict for an intervening head, or falling
through to the INV-12 no-verdict path. Generic verdict producers remain
unbound. Routing candidates and freshness checks consume one shared
strict-self timeline that excludes rows with malformed timestamps, so their
indices cannot diverge. The verdict grammar permits each optional `cause`,
`dev-actionable`, and `head` key at most once in canonical renderer order.

## Canonical Conflict Route

One helper serves preflight and post-fan-out conflict decisions. It persists:

1. the required issue blocking finding, bound to `(issue, head, conflict-rebase)`;
2. for preflight only, the bare disposition marker;
3. the PR `Auto-merge failed:` marker, bound to the same tuple;
4. the `failed-substantive` verdict trailer bound to the full affected HEAD;
5. a best-effort native request-changes action; and
6. `reviewing -> pending-dev`.

The issue finding, disposition, PR marker, and verdict trailer are mandatory
writes. Post-fan-out also repairs a missing strict-self `Reviewed HEAD:` anchor
before the verdict write. Their return codes are checked. Existing canonical
markers suppress duplicate semantic writes on retry; quoted PR-marker history
does not. The transition is attempted only after all required writes are
durable.

A required-write failure emits a best-effort
`failed-non-substantive cause=preflight-write-failed` trailer and requeues to
`pending-review`. The cleanup target is armed to `pending-review` before the
first required write starts, so an interruption between writes cannot
manufacture an orphan `pending-dev` transition. `RESULT_PARSED` is set only
after that retry route is selected. A failed final `pending-dev` transition
leaves `RESULT_PARSED` false; after the helper confirms every routing input is
durable, cleanup may safely retry only the intended state movement. It suppresses
its generic crash verdict because the required HEAD-bound verdict is already
durable.

## Unknown And Read-Failure Routes

A stable known head with persistent `UNKNOWN` or empty mergeability receives a
`mergeable-unknown` disposition plus the matching non-substantive trailer, but
never an `Auto-merge failed:` marker. It enters `pending-dev` so the existing
verdict-aware retry cap owns convergence.

An initial/final snapshot failure cannot prove head stability. It emits no
disposition and returns to `pending-review` non-substantively. A changed head
also emits no stale disposition and returns to `pending-review` with
`cause=head-changed`.

## Provider Boundary

Caller code uses only:

- `chp_pr_view` for normalized state/head/branch snapshots;
- `chp_mergeable` for mergeability;
- `chp_pr_comment` for the rebase marker;
- `itp_list_comments`, `itp_post_comment`, and `itp_transition_state` for issue
  evidence and movement.

No provider CLI or provider-native field crosses the caller layer. GitHub and
GitLab fixtures therefore drive the same decision helper and normalized trace.

## Rebase Convergence

The existing dev prompt remains authoritative:

- the `Auto-merge failed:` prefix makes rebase the mandatory first action;
- success pushes with `git push --force-with-lease`, producing a new head;
- an unsafe conflict is aborted with `git rebase --abort` and reported for
  human resolution;
- the existing one-dev-attempt-per-head bound escalates an unchanged,
  unresolved conflict to `stalled`.

The new disposition is head-bound, so it is ignored after a successful rebase.
INV-122 remains defense in depth for non-conflict E2E fixed points.

Every dev mode resolves the linked PR, full current HEAD, and canonical
HEAD-bound `Auto-merge failed:` comment before constructing its prompt. It
accepts either the confirmed-conflict marker produced by this design or the
separate generic `auto-merge-failure` marker produced by INV-33 after an
ordinary post-approval merge failure. Both are rendered from the current
`(issue,HEAD)` by the shared contract; neither changes the
`review-disposition` grammar. The marker must be the exact final line.
Stale, malformed, terminal-newline, wrong-issue, and quoted canonical-marker
lookalikes are ignored. Marker-free legacy INV-33 comments remain accepted for
backward compatibility only when no case-insensitive marker lookalike appears
in the body. The GitHub comment read page-walks the issue-comments endpoint, so
evidence after comment 100 remains visible. The generic INV-33 producer treats failure to write
its current-HEAD marker as retryable and requeues review before any dev
dispatch. A match prepends the mandatory rebase block ahead of implementation
work. If any provider read needed to establish that context fails, the prompt
instead starts with a mandatory context-recovery block:
ordinary implementation is forbidden until the current HEAD and marker can be
re-read. If the read still fails, the agent posts the exact whole-body marker
`<!-- dev-conflict-context-read-failed: issue=<N> head=<full-lowercase-sha> -->`.
The wrapper renders the exact reviewed HEAD from a successful PR read or the
newest strict issue routing evidence; it never asks the agent to derive the
marker from the base checkout's `git rev-parse HEAD`. The agent posts it once
and exits without changing code. If neither trusted source supplies a full
HEAD, the agent may post only after validating an issue-bound PR worktree and
running `git -C <validated-pr-worktree> rev-parse HEAD`; without that validation
it exits without a marker rather than guessing. The dispatcher accepts
that marker only after the latest trusted dev dispatch token and only for the
unchanged reviewed full HEAD. A completed or completion-unprovable attempt with
that evidence transitions directly from `pending-dev` to `stalled` without
another `dev-new`; the completed route recognizes the strict current-HEAD
`conflict-rebase` disposition because its required verdict predates the dev
session and is outside the ordinary post-session verdict window. A stale-attempt
marker is ignored, and same-second ordering uses the normalized monotone comment
ID. INV-128 classifies the marker as idempotent for consistency, but is not the
primary bound because each wrapper attempt's session report legitimately
changes the generic liveness fingerprint.

Every preflight `failed-non-substantive` exit also posts INV-129's `round=0`
reset immediately after its verdict and before its state transition. This is a
second reset channel when the verdict-cutoff write is unavailable.
