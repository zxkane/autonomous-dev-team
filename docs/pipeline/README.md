# Autonomous Pipeline — Authoritative Flow Reference

This directory is the **single source of truth** for how the autonomous pipeline behaves end-to-end. The dispatcher, dev-agent wrapper, and review-agent wrapper are all required to match what is documented here. Bug fixes and features MUST update the relevant doc(s) before (or in the same PR as) the code change. See [`CONTRIBUTING.md`](../../CONTRIBUTING.md) for the rule.

For the high-level overview and quick start, see [`docs/autonomous-pipeline.md`](../autonomous-pipeline.md). This directory is the spec; that file is the orientation.

## Files

| File | Scope |
|---|---|
| [`state-machine.md`](state-machine.md) | The label state machine for an `autonomous`-tagged GitHub issue. The entire pipeline is a function of label transitions. |
| [`dispatcher-flow.md`](dispatcher-flow.md) | What the dispatcher does on each cron tick. The five steps, dependency check, retry counter, stale detection (5a + 5b). |
| [`dev-agent-flow.md`](dev-agent-flow.md) | The dev-agent wrapper lifecycle: PID guard, prompt construction, agent invocation, exit-trap label transitions. |
| [`review-agent-flow.md`](review-agent-flow.md) | The review-agent wrapper lifecycle: PID guard, requirement-drift detection, decision gate, reviewed-HEAD trailer. |
| [`handoffs.md`](handoffs.md) | The five handoff points between dispatcher / dev / review and the invariants each side is required to uphold. |
| [`invariants.md`](invariants.md) | Cross-cutting invariants (PID file naming, retry-counter cutoff rule, SHA trailer format, "crashed"-keyword regex contract, etc.). |

## Reading order

First time:

1. `state-machine.md` — get the labels and transitions in your head.
2. `handoffs.md` — see where the three agents meet.
3. `dispatcher-flow.md`, `dev-agent-flow.md`, `review-agent-flow.md` — the per-agent details.
4. `invariants.md` — the rules that keep them coherent.

Fixing a bug:

1. Find the misbehavior on the state-machine diagram.
2. Read the relevant flow doc.
3. Read the invariant the bug violated (or, if none exists, write one as part of your fix).
4. Update the flow doc to describe the new behavior.
5. Then change the code.

## Status

| Doc | Status |
|---|---|
| `README.md` | Done (this file) |
| `state-machine.md` | Stub — filled in PR-2 |
| `dispatcher-flow.md` | Stub — filled in PR-2 |
| `dev-agent-flow.md` | Stub — filled in PR-2 |
| `review-agent-flow.md` | Stub — filled in PR-2 |
| `handoffs.md` | Stub — filled in PR-2 |
| `invariants.md` | Stub — filled in PR-2 |
