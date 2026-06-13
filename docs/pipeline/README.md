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
| [`adapter-spec.md`](adapter-spec.md) | **Normative** agent-CLI adapter contract (`spec_version: 1`): the `invoke(mode, …) → AdapterResult` interface with a mode axis, the four-axis result, the verdict-artifact / fixture-manifest / error-envelope JSON Schemas under [`schemas/`](schemas/), and the per-CLI mapping appendix (INV-66). Later adapter work implements it. |
| [`remote-backend.md`](remote-backend.md) | The `EXECUTION_BACKEND` contract every dispatch transport (local, remote-aws-ssm, future) must satisfy. |
| [`agy-cli-support.md`](agy-cli-support.md) | Per-CLI spec for the `AGENT_CMD=agy` (Antigravity 2.0) branch in `lib-agent.sh` — sidecar pattern, structural flags, INV-36 capture contract. |
| [`per-side-agent-cmd.md`](per-side-agent-cmd.md) | `AGENT_DEV_CMD` / `AGENT_REVIEW_CMD` — let dev and review run on different CLIs in the same project (INV-37). |
| [`per-side-launcher.md`](per-side-launcher.md) | `AGENT_DEV_LAUNCHER` / `AGENT_REVIEW_LAUNCHER` — per-side launcher prefix; pairs with INV-37 to allow mixed-CLI deployments where only one side has a launcher (INV-38). |
| [`agent-smoke.md`](agent-smoke.md) | The three-state agent-CLI smoke (`lib-agent-smoke.sh::smoke_agent`) + matrix harness — PASS / UNAVAILABLE / FAIL launch-auth-model probe through the production `run_agent` (INV-63). |
| [`metrics.md`](metrics.md) | The observe-only metrics lane (`lib-metrics.sh` event log + `metrics-report.sh` aggregator) — event types, fields, failure-class taxonomy, and the four baseline numbers (incidents/month, cost-per-merged-PR, quota-failure rate, TTHW). Observe-only per INV-70. |

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
| `README.md` | Done |
| `state-machine.md` | Done |
| `dispatcher-flow.md` | Done |
| `dev-agent-flow.md` | Done |
| `review-agent-flow.md` | Done |
| `handoffs.md` | Done |
| `invariants.md` | Done (INV-01..INV-15; INV-11, INV-12, INV-13, INV-14, INV-15 are documented but not yet code-enforced — see notes inside) |
