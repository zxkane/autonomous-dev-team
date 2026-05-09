# Issue Label State Machine

> **Status: scaffold.** This file is filled in by PR-2. The structure below is the contract; the content is a placeholder until the next PR lands.

## Purpose

The autonomous pipeline is driven entirely by GitHub issue labels. This document is the authoritative description of the legal label states, the transitions between them, and which actor performs each transition.

## Outline (filled by PR-2)

1. **Labels** — table of every label, owner, meaning.
2. **State diagram** — mermaid `stateDiagram-v2` covering the five active states (`autonomous`, `in-progress`, `pending-review`, `reviewing`, `pending-dev`) and the two terminal states (`approved`, `stalled`).
3. **Transition table** — for each transition: trigger, actor (dispatcher / dev wrapper / review wrapper / dispatcher cleanup trap), preconditions, postconditions, comment-on-issue side effect.
4. **Forbidden transitions** — explicit list of "this must never happen" combinations (e.g. `in-progress` + `reviewing` simultaneously).
5. **Concurrent-modification semantics** — what happens when the wrapper trap and the dispatcher both edit labels in the same window (see #57 race).

## Cross-references

- [`dispatcher-flow.md`](dispatcher-flow.md) — the steps that *cause* most transitions.
- [`handoffs.md`](handoffs.md) — the transitions that span actors.
- [`invariants.md`](invariants.md) — invariants that constrain valid transitions.
