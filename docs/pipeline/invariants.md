# Cross-cutting Invariants

> **Status: scaffold.** This file is filled in by PR-2.

## Purpose

Catalog of rules that span the dispatcher / dev / review boundaries. When a bug fix discovers a new invariant, add it here and reference it from the relevant flow doc.

Each invariant has a fixed shape:

```
INV-<NN>: <one-sentence rule>

Why: <the historical bug this exists to prevent — link the issue / PR>
Producer: <which actor must uphold it>
Consumer: <which actor relies on it>
Test: <where this is verified, or "TODO: add test">
```

## Outline (filled by PR-2)

Initial invariant set, derived from the bug stream that motivated this scaffold:

- **INV-01: PID file naming** — `/tmp/agent-${PROJECT_ID}-issue-${N}.pid` for dev, `-review-${N}.pid` for review. Producer: wrappers. Consumer: dispatcher Step 5.
- **INV-02: PID file is not a symlink** — wrappers and `kill_stale_wrapper` refuse to operate on symlinked PID files (CWE-59).
- **INV-03: Dev session report comment format** — Producer: dev wrapper exit trap. Consumer: dispatcher Step 4 retry counter + dispatcher Step 4 session-id extraction.
- **INV-04: Reviewed-HEAD trailer format** — `` `Reviewed HEAD: \`<sha>\`` ``. Producer: review wrapper. Consumer: dispatcher Step 5b SHA comparison (#53).
- **INV-05: Retry-counter cutoff rule** — only count failures *after* the most recent "Marking as stalled" comment. Removing `stalled` resets the counter (#41).
- **INV-06: "crashed" / "process not found" keyword contract** — Step 5b dispatcher comments containing these phrases are counted by Step 4 retry regex. Comments for forward-progress paths (PR found, no new commits since last review) MUST NOT contain these phrases (#50).
- **INV-07: Empty Reviewed-HEAD trailer routes to `pending-review`** — covers both first-review and trailer-post-failure cases (#53).
- **INV-08: Wrapper exit trap is idempotent against label state** — wrapper trap can race with dispatcher Step 5; both must converge to the same final label within one tick.
- **INV-09: `JUST_DISPATCHED` skip rule** — Step 5 MUST skip issues dispatched in the current tick (their PID file may not be written yet).
- **INV-10: 5-minute idle gate before SIGTERM** — Step 5a MUST require ≥300s since `PR.updatedAt` before killing an alive wrapper (#56).
- **INV-11: Dependency state includes `MERGED`** — Step 2 dep-check treats both `CLOSED` and `MERGED` as resolved. PRs return `MERGED` not `CLOSED` (#61).
- **INV-12: Resume only against unfinished sessions** — dispatcher MUST NOT issue resume against a session whose terminal state is `completed` (#59). [Added in PR-5.]
- **INV-13: Wall-clock cap on agent invocations** — `run_agent` / `resume_agent` MUST be wrapped in `timeout` (default 4h, override via `AGENT_TIMEOUT`) to bound hung calls (#60). [Added in PR-5.]
- **INV-14: `lib-agent.sh` config lookup honors symlink-vendor pattern** — script-local paths MUST resolve to the invocation path, not the `readlink -f` target (#58). [Added in PR-4.]

## Cross-references

- All flow docs cite these invariants by ID (e.g. "[INV-04]") rather than restating them.
- [`state-machine.md`](state-machine.md) — invariants that constrain transitions are flagged inline there.
