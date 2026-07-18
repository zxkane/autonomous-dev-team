# Design: durable terminal control

Issue #515 (parent tracking issue #450). Builds on the resource-accounting
authority from #505, but remains inert until #506 writes terminal intents.

## Problem

A resource-cap decision made during a wrapper run can be lost if the process
dies before changing labels. Existing wrapper cleanup then unconditionally
routes the issue back to `pending-dev` or `pending-review`. The dispatcher-side
`mark_stalled` helper cannot be reused because it owns retry-exhaustion
wording, counters, and external-liveness gating.

## Boundaries

- Add one provider-neutral terminal-control library.
- Add a dormant cleanup guard to the dev and review wrapper traps.
- Do not write intents from production code; #506 owns enforcement.
- Do not modify `mark_stalled` or any existing call to it.
- Reuse the existing `stalled` destination and three existing movements. The
  required `in-progress -> stalled` cleanup movement is declared explicitly;
  no label is added.

## Comment Protocol

Issue comments are the authority because they survive wrapper-host loss and
are visible across local and remote-SSM execution topologies. All marker bodies
are single-line, fully anchored strings:

```text
<!-- resource-terminal-intent-v1: issue=<N> intent=<id> invocation=<id> reason=<token-cap|turn-cap|usage-unknown> owner=<dispatcher|dev-wrapper|review-wrapper> -->
<!-- resource-terminal-intent-consume-v1: issue=<N> intent=<id> invocation=<id> -->
<!-- resource-terminal-intent-clear-v1: issue=<N> intent=<id> invocation=<id> reason=<token> -->
```

`intent`, `invocation`, and clear-reason tokens use
`[A-Za-z0-9][A-Za-z0-9._:-]{0,127}`. Only normalized comments whose
`authorKind` is `self` participate. Terminal-control reads privately opt into
provider-side authority classification. GitHub PAT and GitLab resolve the
authenticated user exactly. GitHub App installation tokens have no supported
self-identity endpoint, so each configured dev, review, and dispatcher App
slug is resolved exactly with that App's JWT and `GET /app`. GitLab deployments
with distinct role identities list the other exact usernames in
`TERMINAL_CONTROL_TRUSTED_AUTHORS`. GitHub terminal-control authority uses exact
logins only; App-mode matches additionally require REST `user.type=Bot`.
Human/App slug collisions in either direction and unrelated-bot copies are
ignored. Identity-resolution failure is fail-closed.

The normalized `itp_list_comments` array is already chronological. A read:

1. Parses only fully anchored, trusted markers for the requested issue.
2. Excludes a write generation when a matching trusted consume or clear
   follows the first write for that `intent` and `invocation`.
3. Returns the newest remaining write as compact JSON, or no output.

An exact trusted write replay is a no-op. The same stable intent ID can name a
new generation when a later invocation writes it. Consume and clear target the
newest live generation for that intent, then fall back to its newest generation
for idempotent replay. A delayed duplicate write cannot resurrect a generation
whose lifecycle marker follows its first matching write, and a lifecycle marker
that predates its matching write is inert. Clear is the operator re-arm action
and dominates stale cleanup consumes within the same generation regardless of
comment order. A future decision may reuse the intent ID with a new invocation.

## Transition Contract

`stall_from_pending` accepts only `pending-dev` or `pending-review`.
`stall_from_active` accepts only `in-progress` or `reviewing`. Both read current
labels through `itp_read_task` and apply this decision:

```text
already stalled       -> rc 0, no write
expected state absent -> rc nonzero, no write
expected state present -> one itp_transition_state expected -> stalled
```

The transition removes only the expected state and therefore preserves
`autonomous`. The intent id is validated for attribution but does not change
label semantics. If an already-invalid state carries another transitional label
(for example `in-progress` plus `pending-dev`), the helper deliberately leaves
that non-owner residue for INV-25 tick-start hygiene instead of widening the
pinned expected-state-only transition contract. Neither helper calls
`mark_stalled`.

## Cleanup Ordering

Both wrapper traps call one library guard in place of each cleanup transition
whose target is `pending-dev` or `pending-review`:

```text
read intent
  |
  +-- none -> perform the original itp_transition_state with identical argv
  |
  +-- live -> stall_from_active(expected owner state)
               |
               +-- success/already stalled -> post consume marker
               +-- wrong owner/failure -> no consume, no pending transition
```

The transition precedes consume. If the wrapper dies after the transition, the
next cleanup reads the still-live intent, observes `stalled`, and posts consume.
Cleanup binds that consume to the invocation generation returned by its initial
read; a newer same-ID generation arriving during the transition is not consumed
in its place.
If consume is durable, re-entry sees no live intent and the already-stalled
state remains terminal: cleanup recognizes that the newest decision was
consumed, confirms the current `stalled` label, and makes no pending write. A
clear that races between the stalled transition and consume has the same
re-entry protection: clear remains authoritative even if the stale consume
posts after it, then cleanup recognizes the cleared generation plus `stalled`
and makes no pending write.
Clear re-arms the marker generation only; it does not itself move labels. A
wrong-owner race leaves the intent unconsumed so the next legitimate owner can
reconcile it.

An `itp_list_comments` or parse failure is fail-closed: cleanup performs no
pending transition. This avoids resurrecting work when the authoritative
terminal-intent state is unknown. With a successful empty read, the original
transition call and arguments are unchanged.

## Test Strategy

- Hermetic in-memory `itp_*` comment and label stores with frozen timestamps.
- Unit coverage for marker grammar, trust, lifecycle, ordering, transition
  ownership, no-intent regressions, and both crash windows.
- Provider coverage for PAT/GitLab exact self-classification and App-mode
  cross-role bot classification without unsupported identity calls.
- Source pins that `mark_stalled` and all existing call sites are unchanged.
- A hermetic E2E driver that writes an intent, simulates wrapper restart, runs
  cleanup routing, and verifies `stalled` plus a consumed intent.
- Source-derived branch inventory and xtrace accounting above 80 percent for
  the new library's decision branches.
