# Dispatcher Flow (per cron tick)

> **Status: scaffold.** This file is filled in by PR-2.

## Purpose

Describes exactly what the dispatcher does on each cron tick (default: every 5 minutes). The dispatcher is stateless — it reads issue labels and PID files, makes decisions, dispatches subprocesses, and updates labels.

## Outline (filled by PR-2)

1. **Tick lifecycle** — initialize `JUST_DISPATCHED`, run Steps 1–5, exit. No persistent state across ticks.
2. **Step 1: concurrency gate** — count `in-progress` + `reviewing` issues, abort tick if at `MAX_CONCURRENT`.
3. **Step 2: scan-new** — find `autonomous`-only issues, dependency-check, label `in-progress`, dispatch `dev-new`.
4. **Step 3: scan-pending-review** — label `reviewing`, dispatch `review`.
5. **Step 4: scan-pending-dev** — retry-counter check (with stalled-cutoff rule), session-id extraction, label `in-progress`, dispatch `dev-resume`.
6. **Step 5: stale detection**
   - 5a: ALIVE-with-PR-ready-for-review (idle gate, CI-green gate, SIGTERM, transition to `pending-review`).
   - 5b: DEAD-with-PR (HEAD SHA comparison, transition to `pending-review` or `pending-dev`).
   - 5b: DEAD-without-PR (transition to `pending-dev`).
   - 5b: DEAD-while-`reviewing` (transition to `pending-dev`).
7. **`JUST_DISPATCHED` rationale** — why freshly dispatched issues are skipped from stale detection.
8. **Failure modes** — token expiry, malformed jq output, fail-closed defaults.

## Cross-references

- [`state-machine.md`](state-machine.md) — the label transitions caused by each step.
- [`handoffs.md`](handoffs.md) — Step 5 is the most race-prone handoff.
- [`invariants.md`](invariants.md) — retry-counter cutoff rule, "crashed"-keyword regex contract.
