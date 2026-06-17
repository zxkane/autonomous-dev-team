# Design: smoke `no-response` (rc≠0, no signal) retries once then UNAVAILABLE-drops, not single-shot FAIL (issue #257, INV-76)

## Problem

In `lib-agent-smoke.sh::_smoke_classify`, the **final fallthrough** (step 5) maps a
smoke whose CLI exits **non-zero** with the **nonce absent** and **no recognized
per-CLI scraper signal** (not a quota line, not a stream-error, not auth/config,
not a `124`/`137` timeout) to **`no-response` FAIL** — a gate-worthy verdict.

Under the [INV-64](../pipeline/invariants.md) Phase A.5 gate a single FAIL **aborts
the whole review** — no fan-out, no verdict — and leaves the issue stuck in
`reviewing` until an operator manually flips it to `pending-review`.

For a **Bedrock-backed CLI** (codex via IAM-role→Bedrock) a bare `no-response`
(`rc≠0`, no diagnostic the scrapers can match) is far more likely a **transient
infra hiccup** — the CLI died before emitting any recognizable stream-error /
quota / auth signal — than operator-side config breakage. Treating it as a
deciding FAIL is the same over-strict overreach already fixed for the adjacent
cases:

- [INV-67](../pipeline/invariants.md) — a **bare timeout** (124/137, no signal) →
  UNAVAILABLE, not FAIL.
- [INV-73](../pipeline/invariants.md) — a codex **malformed-output** (prompt-echo /
  startup-trace) → UNAVAILABLE retry-or-drop, never a phantom `[P1]` FAIL.

This issue is the **smoke-side sibling** of the review-side fixes in #252 / #254
(INV-73). The generic `no-response` fallthrough (step 5) is the one transient path
still single-shot-FAILing.

### Observed evidence (this repo's own self-review pipeline)

During a multi-issue backlog drain on a single-agent codex fleet (the only other
member quota-/auth-unavailable), a review **wedged ~7 times**, every wedge keyed on
`reason=no-response`:

```
INV-64: smoke 'codex' → fail (SMOKE codex FAIL <N>s reason=no-response (rc=1; nonce absent from CLI output))
smoke gate over [fail] → fail
aborting the review WITHOUT fan-out
```

Each required a manual label flip. codex itself was healthy (~88% smoke-pass on the
same config), confirming the `no-response` was transient, not a misconfiguration.

## The fix (retry once, then drop — not FAIL)

The three-state contract ([INV-63](../pipeline/invariants.md)) is unchanged:
**FAIL = operator-side config/launch breakage (gate-worthy); UNAVAILABLE =
environmental / transient (drop the member, proceed).** The change recognizes a
**bare `no-response`** (rc≠0, nonce absent, no scraper signal) as a *transient*
signal — the same tolerance INV-67 (bare timeout) and INV-73 (codex malformed)
already apply — and gives it a cheap **retry-once** before deciding:

1. **Probe once.** Unchanged: drive `run_agent` and classify.
2. If the classification is **anything other than the step-5 bare `no-response`
   FAIL** — PASS, an environmental UNAVAILABLE (quota / stream-error /
   malformed-output / bare timeout), or a genuine `auth-failed` / `config-error`
   FAIL — **return it immediately, no retry.** Genuine operator-side config breakage
   stays a single-shot gate FAIL.
3. **Only** for a step-5 bare `no-response` FAIL: run **exactly one** additional
   fresh `smoke_agent` probe of the same member (a one-token round-trip — cheap).
   - If the retry **PASSes** (nonce present) → **PASS**, the member fans out.
   - If the retry is **still** non-PASS (still `no-response`, or any other non-FAIL
     transient) → **UNAVAILABLE**, drop reason
     `no-response (rc=<n>; no nonce after retry — transient infra)`. The member
     casts no Phase A.5 vote; the review proceeds on the survivors.
   - If the retry surfaces a **genuine `auth-failed` / `config-error`** signal →
     **FAIL** (the retry exposed real operator-side breakage — surface it, don't
     mask it).

### Why retry-then-UNAVAILABLE rather than retry-then-FAIL

A bare `no-response` that clears on a fresh one-token round-trip is transient by
definition — environmental, self-healing. A member that fails **both** the probe
and its retry casts **no vote** rather than vetoing every PR. That is the same
terminal class as a crashed reviewer ([INV-40](../pipeline/invariants.md)
all-unavailable fallback) and is strictly safer than the status quo: a transient
no longer wedges the whole review, while a *consistently* broken CLI still surfaces
as `auth-failed` / `config-error` → FAIL (unaffected) or fails both attempts →
UNAVAILABLE drop (correct — no false green, the member simply abstains).

### Fail-safe / non-Bedrock care

The retry-then-UNAVAILABLE applies to the generic `no-response` fallthrough
**regardless of CLI** — a transient no-response is environmental for any CLI. This
does not mask a *consistently* broken CLI: a genuinely misconfigured member
typically surfaces an `auth-failed` / `config-error` scraper signal (→ FAIL,
unaffected) or fails both the probe and its retry (→ UNAVAILABLE drop, the same
terminal class as a crashed reviewer).

## Where the change lives (minimal, driver-level)

`_smoke_classify` is a **pure** decision function — it maps one `(agent, rc, stdout,
nonce, log)` tuple to a state and **cannot** drive a fresh `run_agent`. The retry
therefore lives in the **driver**, `smoke_agent`, which already owns the
`run_agent` round-trip:

- Factor the single-probe body (nonce/session-id mint → `run_agent` in a subshell →
  classify) into an inner helper `_smoke_probe_once`, which echoes a structured
  `STATE|reason|elapsed` line (the original CLI exit code is carried inside the
  reason text — `_smoke_classify` step 5 always renders `rc=<n>` — so the driver
  recovers it from the reason rather than a separate field).
- `_smoke_classify` keeps emitting the human-readable `FAIL|no-response (rc=%s; …)`
  reason for step 5 unchanged; the driver detects the retry-eligible case
  **structurally**: `STATE == FAIL` **and** the reason begins with `no-response`
  **and** the `rc=<n>` it carries is **non-zero** (the auth/config FAILs carry their
  own scraper phrases, never `no-response`; the bad-args/mktemp pre-flight FAILs are
  emitted by the driver before any probe and never reach this path).
- **`rc=0` silent-success carve-out (issue #257 review follow-up).** Step 5 also
  fires when a CLI exits **`0`** with no nonce/no signal — a CLI that claimed success
  but produced no token. That is genuine broken-output / misconfiguration, not a
  Bedrock transient (a transient kills the CLI with a non-zero exit). So the retry
  guard keys on the **original non-zero exit code**: a `rc=0` no-response (or any
  unparseable rc) stays a **single-shot gate-worthy FAIL** — no retry — keeping the
  relaxation scoped exactly to the `rc≠0` fallthrough #257 targets.
- On a retry-eligible first probe, run a second `_smoke_probe_once`; map
  `PASS → PASS`, a genuine config FAIL → FAIL, anything else → the
  `no-response … no nonce after retry — transient infra` UNAVAILABLE.

No `lib-review-smoke.sh` change is needed: `_classify_smoke_state` already maps
`smoke_agent` rc 2 → `unavailable` and `_classify_smoke_gate` already treats
`unavailable` as a dropped member (`fail` > `all-unavailable` > `pass`). The new
UNAVAILABLE flows through unchanged — one no-response member → dropped + review
proceeds; ALL members no-response → `all-unavailable` (the existing INV-40 terminal
path, no empty fan-out spawned).

### Bound — at most one retry

The retry fires **exactly once** (no loop, no counter that can run away). A second
no-response resolves to UNAVAILABLE deterministically. The wall-clock cost is one
extra one-token round-trip in the (rare) transient case only.

## Decision flow (after the fix)

```
smoke_agent <agent> <model> <timeout>
  │
  ├─ bad-args / mktemp pre-flight failure ──────────────► FAIL  (no probe)
  │
  ├─ probe #1 (_smoke_probe_once → _smoke_classify)
  │     │
  │     ├─ PASS ─────────────────────────────────────────► PASS
  │     ├─ UNAVAILABLE (quota/stream/malformed/timeout) ──► UNAVAILABLE (unchanged)
  │     ├─ FAIL auth-failed / config-error ──────────────► FAIL (unchanged, gate-worthy)
  │     └─ FAIL no-response (rc≠0, nonce absent, no sig) ─┐ retry-eligible
  │                                                       │
  │                                ┌──────────────────────┘
  │                                ▼
  │                          probe #2 (one extra fresh round-trip)
  │                                │
  │                                ├─ PASS ──────────────► PASS
  │                                ├─ FAIL auth/config ──► FAIL (retry exposed real breakage)
  │                                └─ anything else ─────► UNAVAILABLE
  │                                       reason=no-response (rc=<n>; no nonce after retry — transient infra)
  ▼
```

## What is explicitly NOT changed

- `auth-failed` / `config-error[:<flag>]` (step 3) → FAIL on the FIRST probe, **no
  retry, no downgrade**. Operator-side breakage stays gate-worthy.
- `quota-exhausted` / `stream-error` / `malformed-output` (the `*|*|*` UNAVAILABLE
  branch) and the bare `124`/`137` timeout ([INV-67](../pipeline/invariants.md)) →
  UNAVAILABLE on the FIRST probe, **no retry** (unchanged).
- `_smoke_classify` itself stays a pure single-probe decision function; the retry is
  purely a driver concern.
- The [INV-48](../pipeline/invariants.md) fan-out post-window timeout-veto (a real
  review run that hit its budget) is a DIFFERENT path and is untouched.

## Invariant + doc updates (same PR — Pipeline Documentation Authority)

- **New [INV-76](../pipeline/invariants.md)**: a transient smoke `no-response`
  retries once, then drops UNAVAILABLE — never a single-shot gate FAIL.
  Cross-references INV-63 (three-state contract), INV-64 (Phase A.5 gate), INV-67
  (bare timeout) and INV-73 (codex malformed) as the sibling transient tolerances.
- **`review-agent-flow.md`** + **`agent-smoke.md`**: update the smoke walkthrough to
  describe the retry-once step.

## Test plan

See [`docs/test-cases/smoke-no-response-retry.md`](../test-cases/smoke-no-response-retry.md)
(`TC-AGENT-SMOKE-NNN`).
