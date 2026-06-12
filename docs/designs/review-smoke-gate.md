# Design: Review wrapper Phase A.5 — pre-fan-out agent smoke gate (issue #224, INV-64)

## Problem

A misconfigured or broken `AGENT_REVIEW_AGENTS` fan-out member burns a full review
run (E2E lane + N parallel review agents + the verdict-poll window) before
surfacing as an opaque `unavailable` drop ([INV-40](../pipeline/invariants.md)).
Worse, the wrapper cannot distinguish two fundamentally different causes from a
bare `unavailable`:

| Cause | Example | Correct response |
|---|---|---|
| **Operator broke the config** | wrong model id, expired auth, region drift, a launcher that wraps a non-claude CLI | **must be fixed** — silently shrinking the vote disguises the breakage |
| **Quota wall** | agy 429 `RESOURCE_EXHAUSTED`, backend capacity | **fine to drop** — environmental, self-healing; promoting it to a deciding FAIL would block every PR while a daily quota is spent |

A cheap pre-fan-out smoke separates the two **before** any expensive review run
starts: it runs a one-token model round-trip per fan-out member through the
production `run_agent` chain ([INV-63](../pipeline/invariants.md) / `lib-agent-smoke.sh::smoke_agent`,
issue #222) and applies three-state semantics.

## The three-state gate (INV-64)

Phase A.5 sits in `autonomous-review.sh` **after** the [INV-46](../pipeline/invariants.md)
E2E lane (Phase A) and **before** the [INV-40](../pipeline/invariants.md) review
fan-out loop (Phase B). For each `REVIEW_AGENTS_LIST` member it runs `smoke_agent`
**in parallel** (explicit subshell PIDs — never bare `wait`, [INV-40](../pipeline/invariants.md)
sub-rule 1) with that member's resolved per-agent model ([INV-41](../pipeline/invariants.md))
and launcher treatment ([INV-38](../pipeline/invariants.md) neutralization for
non-claude members) — the **same resolution the fan-out itself uses**.

```
        Phase A (INV-46 E2E lane, ran once)
                    │ gate == pass
                    ▼
        Phase A.5 (INV-64 smoke gate)   ── only when REVIEW_SMOKE_ENABLED=true
                    │
   parallel smoke_agent per REVIEW_AGENTS_LIST member
   (resolved per-agent model + INV-38/INV-42 launcher, explicit-PID wait)
                    │
   ┌────────────────┼─────────────────────────────────────────────┐
   │ any member FAIL │ some/all UNAVAILABLE          │ all PASS     │
   │ (rc 1)          │ (rc 2)                         │ (rc 0)       │
   ▼                 ▼                                ▼              │
 ABORT             drop UNAVAILABLE members          fan out all    │
 (loud)            via existing INV-40 machinery;    members        │
 post naming       remaining members fan out;                       │
 comment;          ALL unavailable → existing                       │
 stay reviewing;   all-unavailable fallback                         │
 exit non-zero     (UNCHANGED)                                      │
```

### PASS (rc 0) — member proceeds to fan-out

The smoke confirmed launch → auth → real model response. The member is added to
the post-smoke fan-out set verbatim.

### UNAVAILABLE (rc 2) — drop the member pre-fan-out

Quota/capacity. The member is **dropped from the fan-out set** with drop reason
`smoke: <classified reason>` (e.g. `smoke: quota-exhausted, resets in 2h`,
scraped from `smoke_agent`'s evidence line). Remaining members fan out and vote
normally. This reuses the existing [INV-40](../pipeline/invariants.md) `unavailable`
tolerance — a dropped member does not block.

**Degenerate cases:**
- **ALL members UNAVAILABLE** → the fan-out set is empty. We do **not** spawn an
  empty fan-out; instead we drive the wrapper straight to the existing
  **all-unavailable fallback** (the same terminal state as today's review-crash
  fallback: `−reviewing +pending-dev`, `failed-substantive` trailer). This is
  reached by leaving `REVIEW_AGENTS_LIST` collapsed and synthesizing the
  all-unavailable aggregate — see "Implementation: empty-set handling" below.
- **Single-agent project, that one member UNAVAILABLE** → identical to "all
  UNAVAILABLE" (the set of one is empty after the drop).

### FAIL (rc 1) — abort the entire review loudly

Config/launch error. Phase A.5 **aborts**:
- no fan-out, no verdict;
- the issue stays `reviewing` (NO `pending-dev` flip);
- post one issue comment naming the failed agent(s) + the SMOKE evidence line(s);
- emit a heartbeat-consistent verdict trailer (`failed-non-substantive smoke-config-error`)
  so [INV-24](../pipeline/invariants.md) stale-detection treats it like other
  startup-abort paths (no false DEAD declaration mid-abort);
- the wrapper exits **non-zero**.

**Rationale** (locked in the issue): a config error is operator-side, not a PR
defect. Silently shrinking the vote would disguise a FAIL as UNAVAILABLE.
Flipping to `pending-dev` would send the dev agent chasing a non-existent PR
problem. **Abort + stay `reviewing`** matches the existing wrapper-startup-crash
semantics and self-heals on the next dispatch tick once the operator fixes the
config (the dispatcher re-dispatches the still-`reviewing` issue per the
[INV-24](../pipeline/invariants.md) recovery path).

> **Crash trap interaction:** the wrapper's `cleanup` EXIT trap (the crash path)
> flips a `reviewing` issue to `pending-dev` when `RESULT_PARSED != true` and the
> exit code is non-zero. The FAIL-abort must therefore set `RESULT_PARSED=true`
> **before** exiting so the crash trap does NOT override the deliberate
> stay-`reviewing` decision. (The trailer + label state are written by the abort
> block itself, exactly like the INV-46 gate-fail exits.)

## Config knobs (default-off)

In `autonomous.conf.example`:

| Knob | Default | Meaning |
|---|---|---|
| `REVIEW_SMOKE_ENABLED` | **`false`** | explicit per-project opt-in; rollout is per-project and individually revertible |
| `REVIEW_SMOKE_TIMEOUT_SECONDS` | `120` | per-member smoke wall-clock cap (passed to `smoke_agent`'s 3rd arg) |

With `REVIEW_SMOKE_ENABLED=false` (the default), Phase A.5 is **not entered at
all** — the wrapper behavior is byte-for-byte unchanged (regression-pinned).

## Why a new lib (`lib-review-smoke.sh`)

The pure decision logic — *given the collected per-member smoke states, what is
the gate outcome and what is the surviving fan-out set?* — is extracted into
`lib-review-smoke.sh` so it is unit-testable in isolation, mirroring
`lib-review-e2e.sh` (INV-46) / `lib-review-aggregate.sh` (INV-40) /
`lib-review-poll.sh` (INV-43). The wrapper keeps the parallel-subshell
orchestration (it needs wrapper state: `REVIEW_AGENTS_LIST`, the resolvers, the
fan-out dir), and calls the lib for:

- `_classify_smoke_state <agent> <model> <timeout> <rc-file> <evidence-file>` —
  run one member's smoke in a subshell-friendly way (writes rc + evidence to
  sidecars), so the wrapper's parallel loop is a thin fan-out;
- `_smoke_evidence_reason <evidence-line>` — extract the `reason=…` tail from a
  `SMOKE …` evidence line for the `smoke: <reason>` drop reason / FAIL comment;
- `_classify_smoke_gate <state...>` — the pure verdict: `fail` if any member
  FAILed, else `all-unavailable` if every member is UNAVAILABLE, else `pass`.

> **Post-install / upgrade:** this PR **ADDS** `lib-review-smoke.sh`. After merge
> + user-scope skill update, `install-project-hooks.sh` must be re-run on every
> onboarded project (CLAUDE.local.md → Post-merge Step 2) or a wrapper that
> sources the new lib crashes on the missing per-file symlink. The PR body
> carries the standard note.

## Coordination with the stability redesign (#227–#238)

- **Three-state ↔ four-axis mapping:** Phase A.5's PASS / UNAVAILABLE / FAIL is a
  projection of the adapter-spec (#229) provider axis (`quota|auth → UNAVAILABLE`,
  `config → FAIL`). The classification stays inside `smoke_agent` / the per-CLI
  scrapers it reuses, so when #232 moves per-CLI logic into adapters, Phase A.5
  keeps calling the same `smoke_agent` entry point and the refactor absorbs it
  with zero behavior change.
- **FAIL-abort surfacing:** when #231 (error envelope) lands, the FAIL-abort
  comment adopts `{code, problem, cause, remediation}`. Until then a plain
  structured comment is fine — NOT blocked on #231.
- **Metrics:** #228 had not landed at implementation time, so a `TODO(#228)` marks
  where per-member `smoke` events would be emitted via lib-metrics.

## Cost when enabled

N small LLM calls + up to ~`REVIEW_SMOKE_TIMEOUT_SECONDS` wall-clock (parallel,
slowest member) per review. The smoke runs count toward **neither** the INV-40
verdict-attribution window **nor** the poll window — they complete strictly
before `WRAPPER_START_TS`-anchored fan-out clock work begins (the smoke is before
the fan-out loop; `WRAPPER_START_TS` is captured before `build_review_prompt`,
which is unchanged, but the smoke does not post any verdict comment so it cannot
pollute the attribution window).

## Out of scope

- Dev-side single-agent dev wrapper smoke gating (dev failures handled by INV-24/retry).
- Smoke result caching/TTL (each review smokes live).
- Dispatcher-side pre-dispatch smoke.
