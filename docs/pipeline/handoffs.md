# Handoff Points and Their Invariants

> **Status: scaffold.** This file is filled in by PR-2.

## Purpose

The pipeline has three actors (dispatcher, dev wrapper, review wrapper) but five places where work is handed off. This file enumerates each handoff, the data carrier (label, comment, PID file, PR), the producing-side and consuming-side invariants, and the failure modes when an invariant is violated.

## The five handoffs

1. **Dispatcher → dev (new)** — `autonomous` (no other label) → `in-progress`. Carrier: label + dispatched subprocess.
2. **Dispatcher → dev (resume)** — `pending-dev` → `in-progress`. Carrier: label + session-id extracted from prior dev session report comment.
3. **Dev → review** — `in-progress` → `pending-review`. Carrier: label + open PR referencing the issue.
4. **Dispatcher → review** — `pending-review` → `reviewing`. Carrier: label.
5. **Review → dev (send-back)** — `reviewing` → `pending-dev`. Carrier: label + "Review findings:" comment + PR inline comments + Reviewed-HEAD trailer.

## Outline (filled by PR-2)

For each of the five handoffs, document:

- **Trigger** — what makes the handoff happen.
- **Producer-side invariants** — what the upstream actor MUST guarantee (e.g. dev MUST post Dev Session ID before exiting; review MUST post Reviewed HEAD trailer before exiting).
- **Consumer-side invariants** — what the downstream actor MUST tolerate (e.g. dispatcher MUST handle a missing trailer as "review never ran successfully" not as failure).
- **Race window** — what happens when both sides act simultaneously.
- **Failure mode** — what the next cron tick does if the handoff partially completed.

## Cross-cutting concerns

- **Dispatcher-vs-wrapper-trap race**: covered by Step 5a's `JUST_DISPATCHED` skip and the wrapper trap's idempotent label edits. See #57.
- **Reviewed-HEAD trailer empty-fallthrough**: empty value routes to `pending-review` (safe first-review case OR transient post-failure). Documented in [`invariants.md`](invariants.md).
- **Resume-on-completed-session hang** (#59): dispatcher MUST check session terminal state before issuing resume. Invariant added in PR-5.

## Cross-references

- [`state-machine.md`](state-machine.md) — the label edges this file describes.
- [`dispatcher-flow.md`](dispatcher-flow.md), [`dev-agent-flow.md`](dev-agent-flow.md), [`review-agent-flow.md`](review-agent-flow.md) — the per-actor steps.
- [`invariants.md`](invariants.md) — the rules each side must uphold.
