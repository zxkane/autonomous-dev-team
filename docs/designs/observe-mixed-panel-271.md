# Design: observe-loop early-exit for mixed review panels (#271)

## Problem

`autonomous-review.sh`'s post-fan-out **completion-observe loop** (the bounded
loop that replaced a blocking `wait`, INV-78 / #233) can spin until its absolute
6h ceiling (`VERDICT_ARTIFACT_OBSERVE_TIMEOUT_SECONDS`, default 21600s) **even
after every agent's verdict has already posted**, stranding the issue in
`reviewing`.

The loop has three break paths:

- **(a)** all fan-out PIDs exited (`kill -0` miss for every collected PID);
- **(b)** `_all_artifacts_landed "${AGENT_ARTIFACT_PATHS[@]}"` — the early exit;
- **(c)** absolute ceiling (`SECONDS >= _observe_deadline`).

`_all_artifacts_landed` is a pure path-existence check: it returns 0 only if a
verdict-artifact FILE exists for **every** agent slot. `AGENT_ARTIFACT_PATHS` is
provisioned for every agent, but **only artifact-writing agents ever create the
file** — a comment-only agent posts its verdict as a GitHub comment and never
writes the artifact. So on a **mixed panel** (≥1 artifact-writer + ≥1
comment-only agent) early-exit (b) is permanently dead: at least one `-f` check
always misses.

The loop is then left with only (a) and (c). If the artifact-writing agent's
subshell lingers in post-verdict teardown (its PID stays alive past verdict-land),
(a) never fires either, and the loop silently sleeps `_observe_interval` rounds
until (c) — the 6h ceiling. Observed twice in a consumer project's review runs in
one day; both needed a manual kill + label nudge to recover.

## Root cause

The early-exit signal (b) is tied to the wrong thing. It asks *"does a live
artifact FILE exist for every slot right now?"* when what actually matters is
*"has every agent's first verdict been resolved?"* — the same per-agent state the
resolution code (artifact-first seed + `_run_verdict_poll_loop` comment fallback)
uses. For a comment-only agent the verdict resolves from a **comment**, never a
file, so a file-existence gate can never represent its resolution.

## Fix

Replace the `_all_artifacts_landed`-only early-exit with a **per-agent first
verdict resolved** gate. A slot is *resolved* when EITHER:

- its artifact's first-land **frozen snapshot** (`<path>.landed`) is present —
  `_freeze_pass` (already called each round) froze it the moment the artifact
  landed; OR
- (for a comment-only / no-artifact agent) its verdict **comment** is observable
  via the existing `_fetch_agent_verdict_body` (the same fetch
  `_run_verdict_poll_loop` uses, behind the same INV-20 / INV-40 authenticity
  binding).

When **every** slot is resolved, break the loop regardless of live fan-out PIDs;
the already-present `_reap_fanout_processes` call (after verdict resolution,
INV-43) group-kills any lingerer.

### Helpers (in `lib-review-poll.sh`, unit-testable in isolation)

```
_observe_agent_resolved <index>
  → rc 0 iff slot <index> has a resolved first verdict:
      • AGENT_ARTIFACT_SNAPSHOTS[index] exists as a file  (artifact landed), OR
      • _fetch_agent_verdict_body AGENT_NAMES[index] AGENT_SESSION_IDS[index]
        returns a non-empty body                          (comment observed).
    The artifact branch is checked FIRST (a local `[[ -f ]]` stat, no API call);
    the comment fetch runs ONLY when the snapshot is absent, so an
    all-artifact-writer panel makes ZERO extra comment-list API calls (the
    zero-comment-poll AC of INV-78 is preserved on that path).

_all_first_verdicts_resolved
  → rc 0 iff _observe_agent_resolved is true for every index in AGENT_NAMES.
    Empty fleet (no agents) → rc 1 (cannot claim "all resolved" with no slots),
    mirroring _all_artifacts_landed's no-args guard.
```

The observe loop calls `_all_first_verdicts_resolved` for early-exit (b) instead
of `_all_artifacts_landed`.

### Why this preserves INV-48 (the timeout-veto)

The original (b) only early-exited when **every** artifact landed — so no agent
ever flowed to the rc-based terminal sweep on that path, and a still-running
agent's launch rc (124/137) was never consulted. The replacement keeps the same
property by construction:

- An agent we early-exit past is one that is **already resolved** (artifact frozen
  OR comment observed) — its verdict wins over its rc (INV-40), so its rc is
  irrelevant exactly as before.
- An agent that is **NOT** resolved (no artifact, no comment) makes
  `_all_first_verdicts_resolved` return non-zero, so the loop does **not**
  early-exit; it keeps waiting on PIDs (path a) until that agent's CLI exits with
  its real 124/137 cap — preserving INV-48's `timed-out` veto for it.

`_all_artifacts_landed ⟹ _all_first_verdicts_resolved` (a landed artifact freezes
a snapshot ⟹ that slot is resolved), so the **all-artifact-writer panel keeps
byte-for-byte its current behavior** (early-exit on the same round, no extra API
calls).

### Malformed-artifact edge case (unchanged semantics)

A malformed artifact still freezes a `.landed` snapshot (`_freeze_landed_artifact`
copies on first land regardless of validity), so a malformed-then-hang agent is
considered "resolved" for early-exit and is reaped — resolving `unavailable` /
`malformed-output` rather than the `timed-out` veto. This is exactly the
documented INV-78 edge case (Clause V1: "malformed = the agent DID deliver output,
treated absent → dropped", not a weakening of INV-48). No change.

## Invariant

This refines INV-78's "Live artifact-landing completion signal" and is recorded as
a NEW invariant **INV-84** (per the project rule that new behavioral contracts get
a new INV-NN), cross-referencing INV-78. The INV-78 completion-signal paragraph is
updated to point at the generalized gate.

## Alternatives considered

- **Resolve all verdicts inside the observe loop, then break.** Rejected: it would
  duplicate `_run_verdict_poll_loop`'s logic and the artifact-first resolution
  block in the loop body, and risks resolving a comment before the artifact-first
  precedence runs. The minimal-surface fix is a read-only *resolved?* probe that
  reuses the existing fetch; actual resolution stays in the existing post-loop
  code, unchanged.
- **Add `_any_artifacts_landed` (early-exit on ANY artifact).** Rejected: it would
  early-exit past a still-unresolved comment-only agent (premature resolution — the
  exact regression AC#3 forbids).
```
