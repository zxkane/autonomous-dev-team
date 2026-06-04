# Design: A non-zero CLI exit must not drop a review agent while the poll window is open

Issue: #180 (sibling clarification of #172 / INV-43)

## Problem

The INV-43 poll-window scaling (`lib-review-poll.sh::_resolve_verdict_poll_attempts`)
works — for `E2E_MODE=command` the verdict-poll budget now scales to
`E2E_COMMAND_TIMEOUT_SECONDS`. But a multi-agent review (`AGENT_REVIEW_AGENTS`
with ≥2 CLIs) running `E2E_MODE=command` could STILL drop an agent as
`unavailable` even after it posted a passing verdict, because of a **separate
short-circuit** in the verdict-poll loop:

```bash
# autonomous-review.sh, inside the per-agent verdict-poll loop (pre-#180):
else
  # No verdict yet. If the agent's CLI already exited, it won't post one,
  if [[ "${AGENT_LAUNCH_RC[$_sid]:-1}" -ne 0 ]]; then
    AGENT_VERDICTS[$_i]="unavailable"
  else
    _all_resolved=0
  fi
fi
```

### Why the scaling fix doesn't reach this path

The verdict-poll loop runs **after** the fan-out `wait "${_fanout_pids[@]}"`
join — and that join blocks until *every* agent subshell has exited. So by the
time the FIRST poll round executes, **all** agent CLIs have already exited and
`AGENT_LAUNCH_RC` is fully populated. Consequently:

- An agent whose CLI exited non-zero was resolved `unavailable` on poll
  **round 1**, *before* its verdict comment had time to propagate to the GitHub
  issue comments API (comment-propagation lag is seconds).
- The INV-43 scaling only extended the wait for the **`rc == 0` & verdict-not-yet**
  branch (`_all_resolved=0`). It could never help a non-zero-rc agent, because
  that agent never reached the keep-polling branch. **Widening the window cannot
  help an agent that is killed on round 1.**

The assumption *"non-zero CLI exit ⇒ no verdict will be posted"* is false for
command-mode E2E:

- The verify command legitimately exits non-zero on a soft / timeout-recoverable
  path, or the agent's own shell exits non-zero *after* it already posted its
  `Review PASSED` verdict comment.
- Comment-propagation lag means the verdict comment can appear on the issue a few
  seconds AFTER the CLI process exits.

### This is a LATENT defect, not the cause of any captured field drop

Per the issue's own triage: every captured field drop (`dropped (unavailable)
agent(s): …`) ran under the **pre-INV-43 fixed 30 s window** and the dropped
agent's **CLI rc was 0** — i.e. it was dropped for being slower than 30 s, which
is exactly the timing bug #172/INV-43 already fixed. The rc short-circuit was
**never the trigger** in any captured round. We are fixing this **proactively**:
the logic is wrong in principle and will bite the first time an agent posts a
passing verdict and then exits non-zero. A regression test that exercises the bug
path is the only thing that can prove the fix — there is no real-world sample.

This is the spec/code disagreement that INV-40 already names (docs are
authoritative — CLAUDE.md):

> INV-40: "A non-zero launch rc only lets the wrapper resolve an agent as
> unavailable **early** … it is not itself the unavailability condition.
> Conversely, a FAIL an agent *did* post still counts as a deciding FAIL even if
> the CLI also exited non-zero — **the matched verdict comment takes precedence
> over the launch rc**."

The pre-#180 code violated "the matched verdict comment takes precedence" by
resolving `unavailable` on the first round, before re-querying for the verdict
that the precedence rule says must win.

## Goals (acceptance criteria from #180)

1. On a multi-agent command-mode review, every agent that posts a passing verdict
   within the INV-43-scaled window is counted; the unanimous-PASS check reflects
   all of them.
2. A non-zero CLI exit does not, by itself, drop an agent while the poll window
   is still open.

## Non-goals

- **Share one E2E run across fan-out agents** (run `E2E_COMMAND_PRE_HOOKS` once
  per review round, share one SHA-bound evidence artifact). This is a fan-out
  **architecture** change of a different magnitude — explicitly out of scope per
  #180. #175 already shipped a soft mitigation (each agent re-checks for a
  sibling's SHA-bound evidence before its own pre-hooks). A structural "exactly
  one pre-hook per round" gets its own follow-up issue. No code or test for it
  here.
- Changing the unanimous-PASS aggregation rule (INV-40) or the verdict
  authenticity binding (INV-20). The drop is a *timing* bug in resolution, not an
  aggregation-logic bug.
- The separate `all-unavailable` crash-vs-no-verdict discriminator
  (~`autonomous-review.sh:1297`). Its `AGENT_LAUNCH_RC[…] -ne 0` check only runs
  when **every** agent is already unavailable, and distinguishes a genuine crash
  (`AGENT_EXIT=1`) from "ran clean but produced no verdict" (`AGENT_EXIT=0`). It
  is **not** the bug — left byte-for-byte.

## Approach (the spec-mandated minimal fix)

Per #180 Suggested Fix #1 + #2: **don't treat a non-zero CLI exit as
terminal-unavailable while the poll window is still open.** When an agent's CLI
exited (zero OR non-zero) and no verdict is recorded yet, KEEP POLLING for that
agent's verdict comment until the (already INV-43-scaled) window elapses; only
resolve `unavailable` if the window expires with still no verdict.

> **Propagation grace is subsumed.** Because INV-43 already enlarged the
> command-mode window to tens of minutes, removing the premature short-circuit
> automatically turns that window into the propagation grace — **no separate
> post-exit grace timer is needed** (#180 Fix 2). A non-zero rc no longer changes
> the per-round decision at all; the rc-vs-no-verdict path is now byte-for-byte
> identical to the `rc == 0`-vs-no-verdict path that INV-43 already protected.

### Why not a bounded grace counter?

An earlier draft added a small bounded "post-exit grace" (N extra rounds before
dropping a non-zero-rc agent) to avoid a genuinely-crashed agent holding the loop
open for the whole minutes-long budget. #180 was **re-scoped to reject that**:
the window already IS the grace, and a crashed agent holding the loop until
window-expiry is the *exact same* terminal behavior the `rc == 0`-no-verdict
agent already has — accepted as the cost of never dropping a real verdict. The
simpler fix (no new constant, no per-agent counter, no clamp logic) is the one
the spec mandates; per CLAUDE.md the spec is authoritative.

The trade-off this accepts: a multi-agent command-mode review where one agent
genuinely crashes (CLI exits non-zero, never posts a verdict) keeps polling that
slot until the budget is exhausted, even after every sibling has resolved. This
is identical to today's behavior when a clean-rc agent never posts a verdict, and
is the price of "never drop a verdict that is still propagating". The loop still
short-circuits the instant **all** agents are resolved, so the happy path is
unchanged.

### Implementation

1. **`lib-review-poll.sh`**
   - `_classify_unresolved_agent <verdict_body> <rc>` — the single per-round
     decision. A matched verdict → `pass`/`fail` (FAIL-first; wins over rc,
     INV-40). No verdict → `keep`, **regardless of rc**. (No `unavailable`
     return — that is now decided only at window-expiry by the caller.) The `rc`
     arg is retained for documentation/symmetry but no longer affects the result
     — that *is* the fix.
   - `_classify_verdict_body` moved here from the wrapper so the single
     verdict-classification rule is co-located and unit-testable.
   - `_fetch_agent_verdict_body <agent> <session_id>` — encapsulates the one
     `gh issue view … -q <jq>` call (INV-20 authenticity + INV-40 per-agent
     discriminator) so the poll loop can be driven in unit tests by overriding
     this single function.
   - `_run_verdict_poll_loop` — the loop itself, extracted from the wrapper so
     the round-by-round behavior (not just the per-round decision) is testable.
     Polls up to `_VERDICT_POLL_ATTEMPTS` rounds; stops early once every agent
     has a verdict; leaves no-verdict agents unresolved for the caller's sweep.

2. **`autonomous-review.sh`** — replace the inline loop with a call to
   `_run_verdict_poll_loop`. Drop the `AGENT_EXIT_GRACE_LEFT` array, the
   `export _VERDICT_POLL_ATTEMPTS`, and the inline `rc -ne 0 → unavailable`
   short-circuit. The post-window sweep
   (`[[ -z … ]] && AGENT_VERDICTS=unavailable`) is now the **single** terminal
   resolution point for any no-verdict agent — clean OR non-zero rc.

3. The `_reap_fanout_processes` reap is unchanged — a no-verdict agent that ends
   `unavailable` still has its lingering process group (if any) reaped.

### Worked timing

| Round | agy (rc≠0, verdict lands round 2) | codex (rc≠0, never posts) |
|---|---|---|
| 1 | no verdict → `keep` | no verdict → `keep` |
| 2 | verdict found → **pass** ✅ | no verdict → `keep` |
| … | resolved | … keep polling |
| budget exhausted | — | post-window sweep → **unavailable** |

Pre-#180, both agy and codex resolved `unavailable` on round 1.

## Invariant

Amends **INV-43** with the "no early non-zero-rc drop" sub-rule (a sibling
clarification, not a new mechanism) and tightens the INV-40 cross-reference so
"the matched verdict comment takes precedence over the launch rc" is mechanically
enforced. Producer: `autonomous-review.sh` (poll-loop caller) +
`lib-review-poll.sh` (`_classify_unresolved_agent` / `_run_verdict_poll_loop`).
Consumer: the verdict-poll loop and its post-window sweep.

## Backward compatibility

- `E2E_MODE != command`: the poll budget is still the legacy `6` (30 s). A
  non-zero-rc agent that posts no verdict now waits the full 30 s (instead of
  being dropped on round 1) before `unavailable` — the same 30 s window the loop
  already ran for a clean-rc no-verdict agent. The happy path (every agent posts
  a verdict in round 1) is byte-for-byte unchanged for every mode and agent
  count, since a found verdict short-circuits before the rc is ever considered.
- N=1 single-agent review: the lone agent either posts a verdict (resolved
  immediately) or is resolved `unavailable` at window-expiry. The all-unavailable
  fallback (and its rc-aware `AGENT_EXIT` mapping for legacy N=1 parity) is
  unchanged — a lone agent with no verdict still lands in the same
  `all-unavailable` branch with the same `AGENT_EXIT`.
- INV-40 / INV-41 / INV-42 fan-out semantics, INV-20 authenticity binding, and
  the verdict-trailer count are untouched.

## Files touched

- `skills/autonomous-dispatcher/scripts/lib-review-poll.sh` —
  `_classify_unresolved_agent` (simplified to 2 args, no grace), `_classify_verdict_body`
  (moved here), `_fetch_agent_verdict_body` + `_run_verdict_poll_loop` (new,
  testable loop).
- `skills/autonomous-dispatcher/scripts/autonomous-review.sh` — call
  `_run_verdict_poll_loop`; remove the inline loop and the rc short-circuit.
- `docs/pipeline/invariants.md` — amend INV-43 (no-early-drop sub-rule) + INV-40 cross-ref.
- `docs/pipeline/review-agent-flow.md` — Verdict-polling section update.
- `tests/unit/test-review-cli-exit-grace.sh` — pure-decision tests + the
  mandatory loop regression test (verdict on round ≥2 with non-zero rc → pass).
- `docs/test-cases/multi-agent-cli-exit-grace.md` — test-case doc.
