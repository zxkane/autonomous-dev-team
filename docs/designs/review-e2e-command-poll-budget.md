# Design: Multi-agent review must not drop the agent that runs the command-mode E2E

Issue: #172

## Problem

When a project runs **multi-agent review** (`AGENT_REVIEW_AGENTS` with ≥2 entries)
**and** `E2E_MODE=command` with a heavy `E2E_COMMAND_PRE_HOOKS` + a raised
`E2E_COMMAND_TIMEOUT_SECONDS` (e.g. 2700s for a container build + verify), the
review agent that *faithfully* runs the full command-mode E2E is dropped as
`unavailable` from the unanimous-PASS vote, while a faster agent that does less
real verification becomes the sole decider. The diligent agent is penalized for
honoring the contract.

### Mechanisms (from the issue)

1. **The verdict-poll budget is a fixed 30 s.** After the fan-out `wait`
   returns, `autonomous-review.sh` polls issue comments `6 × 5 s = 30 s`
   (`for _poll_attempt in $(seq 1 6); do sleep 5`). An agent whose verdict
   comment lands after that 30 s window — entirely plausible when the E2E takes
   tens of minutes and the agent posts its verdict only after E2E finishes — is
   resolved `unavailable`.

2. **The command-mode E2E can legitimately exceed the review wrapper's effective
   wait/stall budget.** `E2E_COMMAND_TIMEOUT_SECONDS` defaults to 3600 s, but the
   review-side `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS` (the dispatcher's
   crash-detection short-circuit) defaults to 300 s. A command-mode E2E that runs
   the documented pre-hook build + verify outlasts the window the dispatcher is
   willing to wait, so the dispatcher declares the still-working review wrapper
   "crashed" and the next tick's `kill_stale_wrapper` SIGTERMs it mid-verify. The
   killed CLI exits non-zero, posts no verdict, → dropped.

### Compounding side effects

- **Repeated heavy pre-hook work** — each fanned-out agent runs
  `E2E_COMMAND_PRE_HOOKS` independently and each round re-runs.
- **Orphaned agent processes** — a dropped agent's CLI (launched under
  `timeout <AGENT_TIMEOUT>`, default 4 h) is not always reaped when the wrapper
  moves on.

## Goals (acceptance criteria from #172)

1. On a heavy command-mode E2E PR with 2+ review agents, every *available*
   agent's verdict is counted — no agent dropped solely for taking as long as the
   configured `E2E_COMMAND_TIMEOUT_SECONDS`.
2. The expensive pre-hook runs at most once per review round regardless of
   fan-out count.
3. No agent CLI process outlives its review round after being resolved/dropped.
4. `references/e2e-command-mode.md` documents the interaction between
   `E2E_COMMAND_TIMEOUT_SECONDS` and the multi-agent review wait/stall windows.

## Non-goals

- Background-mode / detached E2E execution (`>60 min` E2E) — explicitly deferred
  in `e2e-command-mode.md` ("When NOT to use command-mode").
- Changing the unanimous-PASS aggregation rule (INV-40) or the verdict
  authenticity binding (INV-20). The drop is a *timing* bug, not an
  aggregation-logic bug.

## Approach (minimal viable, in-wrapper)

### Fix A — E2E-aware verdict-poll budget (covers AC 1)

The fan-out `wait` is already unbounded by `AGENT_TIMEOUT` (it blocks until every
agent subshell exits), so an agent that runs a 45-min E2E and posts its verdict
*before* exiting is already waited for. The residual gap is the **30 s poll
window after `wait` returns**: in the no-actor-binding fallback, or when GitHub
comment propagation lags, or when an agent posts its verdict in a final flush
just before exit, 30 s can be too tight.

Make the poll budget **derived from `E2E_COMMAND_TIMEOUT_SECONDS` when
`E2E_MODE=command`**:

- Introduce `_resolve_verdict_poll_attempts`: returns the number of 5 s poll
  attempts. Default is the legacy `6` (30 s). When `E2E_MODE=command`, it returns
  `max(6, ceil(E2E_COMMAND_TIMEOUT_SECONDS / 5) + headroom)` so the wrapper is
  willing to wait *at least* as long as the E2E it asked the agent to run, plus a
  small headroom for comment propagation.
- Replace the hardcoded `seq 1 6` with `seq 1 "$_VERDICT_POLL_ATTEMPTS"`.
- The early-exit short-circuit (`_all_resolved` once every agent has a verdict OR
  a known non-zero launch rc) is unchanged, so the *happy path* still settles in
  one round (~5 s). The longer budget only matters when an agent is genuinely
  still mid-E2E with a clean (zero / not-yet) launch rc — exactly the diligent
  agent the issue is about.

Crucially, an agent with a **non-zero launch rc** (killed/crashed) is still
resolved `unavailable` *early* — we do not wait the full E2E budget for a CLI
that already exited. Only agents that are launched-clean-but-verdict-not-yet keep
the loop alive, which is bounded by the fan-out `wait` anyway (the loop only runs
*after* `wait`). So in practice the extended budget protects the
comment-propagation tail, and the structural dispatcher-kill problem is addressed
by Fix D (docs/config).

### Fix B — reap dropped/undecided agents' process groups (covers AC 3)

After the poll resolves agents, any agent the wrapper treats as `unavailable`
(or any leftover detached CLI) must not keep running.

**What to kill — the agent's setsid PGID, NOT the fan-out subshell PID.** This is
the subtle part (caught in review): the fan-out backgrounds each agent in a plain
`( … ) &` subshell, and the wrapper runs with NO job control (`set -m` is never
enabled), so that subshell does *not* get its own process group — its PID is not
a group leader (`kill -- -<subshell_pid>` is inert, exactly like `kill -- -$$`).
The real session/group leader is the `setsid`-spawned agent, whose PID == PGID is
captured in `lib-agent.sh::_run_with_timeout`'s `_AGENT_RUN_PID` and written to
`AGENT_PID_FILE` when set (INV-23). So:

- Each fan-out subshell points `AGENT_PID_FILE` at a PRIVATE per-agent PGID
  sidecar under `_FANOUT_DIR` (NOT the shared `review-<N>.pid`, which would
  thrash the dispatcher's liveness model — INV-40). `_run_with_timeout` then
  writes the agent's real PGID there.
- The wrapper drains those sidecars into an `_AGENT_PGIDS` array (alongside the
  rc sidecars, before `_FANOUT_DIR` is removed).
- `_reap_fanout_processes` (in `lib-review-poll.sh`, unit-testable in isolation)
  group-kills each PGID (`kill -TERM -- -<pgid>`, then a short grace + `KILL`).
  It is a no-op for agents that already exited (the common case, since `wait`
  returned) and a real reap for the pathological detached-CLI case the issue
  describes.

This runs unconditionally at end of fan-out (cheap: a handful of `kill -0`
probes), so it also protects the single-agent path.

### Fix C — pre-hook runs at most once per review round (covers AC 2)

The command-mode prompt already instructs each agent to **reuse a fresh,
SHA-matching evidence comment** before running the verify command (Step 4b
stale-evidence guard). When N agents fan out, the *first* agent to finish E2E
posts the SHA-bound `<!-- e2e-evidence: complete sha="..." -->` comment; the
others, per Step 4b, find it and skip their own pre-hook + verify. The gap is
**timing**: all N agents start simultaneously, so each checks Step 4b *before*
any sibling has posted evidence, and all N run the pre-hook in parallel.

The minimal, robust fix that does not require cross-subshell coordination of the
agent's own steps is to **strengthen the prompt's Step 4b** so each agent, in
multi-agent mode, (a) re-checks for a sibling's SHA-matching evidence comment
*immediately before* invoking `E2E_COMMAND_PRE_HOOKS` (not only at the top), and
(b) is told that a sibling review agent may be running the same E2E concurrently,
so it should prefer reusing a sibling's evidence. This shrinks the duplicated
window without a new locking primitive. The wrapper passes a
`MULTI_AGENT_REVIEW=true|false` signal into `build_review_prompt` so the
single-agent prompt is byte-for-byte unchanged.

> A wrapper-level "run the pre-hook once before fan-out and feed all agents the
> result" is the stronger guarantee, but it changes the command-mode contract
> (the wrapper would have to run the project E2E itself rather than the agent
> running it) and is a larger redesign; deferred. The prompt-level guard above
> reduces — but does not provably eliminate — the duplicated pre-hook in the
> worst case (all N agents reach the pre-hook in the same sub-second window). The
> doc records this honestly (no silent cap).

### Fix D — documentation (covers AC 4)

`references/e2e-command-mode.md` gains a section documenting:

- The relationship `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS ≥ E2E_COMMAND_TIMEOUT_SECONDS`
  required so the dispatcher does not declare a still-working command-mode review
  wrapper "crashed" and SIGTERM it mid-E2E.
- The verdict-poll budget now auto-scales from `E2E_COMMAND_TIMEOUT_SECONDS`.
- The duplicated-pre-hook caveat and the SHA-evidence reuse path.

`autonomous.conf.example` gains a cross-reference note on
`REVIEW_NEAR_SUCCESS_WINDOW_SECONDS` and `E2E_COMMAND_TIMEOUT_SECONDS`.

## Invariant

New invariant **INV-43**: *command-mode E2E review wait budgets must not be
smaller than the E2E it dispatched.* Producer: `autonomous-review.sh`
(`_resolve_verdict_poll_attempts`) + operator config
(`REVIEW_NEAR_SUCCESS_WINDOW_SECONDS`). Consumer: the per-agent verdict-poll loop
and the dispatcher's `review_near_success`.

## Backward compatibility

- `E2E_MODE != command`: `_resolve_verdict_poll_attempts` returns `6` — the
  poll loop is byte-for-byte the legacy 30 s window.
- Single-agent (`AGENT_REVIEW_AGENTS` unset): `MULTI_AGENT_REVIEW=false`, the
  prompt's Step 4b sibling-recheck text is omitted, and the prompt is unchanged.
- The reap step is a no-op when subshells already exited (the common case).
- INV-40 / INV-41 / INV-42 fan-out semantics are untouched.

## Files touched

- `skills/autonomous-dispatcher/scripts/autonomous-review.sh` — poll-budget
  resolver, `seq` change, reap step, multi-agent prompt signal + Step 4b
  strengthening.
- `skills/autonomous-review/references/e2e-command-mode.md` — Fix D doc.
- `skills/autonomous-dispatcher/scripts/autonomous.conf.example` — cross-ref note.
- `docs/pipeline/invariants.md` — INV-43.
- `docs/pipeline/review-agent-flow.md` — reference INV-43 from the verdict-poll
  and command-mode E2E sections.
- `tests/unit/test-review-e2e-command-poll-budget.sh` — new test.
- `docs/test-cases/review-e2e-command-poll-budget.md` — test-case doc.
