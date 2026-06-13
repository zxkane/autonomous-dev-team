# Design: smoke timeout (rc 124/137) classifies UNAVAILABLE, not FAIL (issue #246, INV-63/64)

## Problem

In `lib-agent-smoke.sh::_smoke_classify`, a smoke that **times out** (`run_agent`
rc `124`/`137`) with **no other signal** is classified **FAIL**. Under the
[INV-64](../pipeline/invariants.md) Phase A.5 gate, a single FAIL **aborts the
entire review** — all fan-out members, not just the slow one — and leaves the
issue stuck in `reviewing` until an operator intervenes.

That is too aggressive for a **Bedrock-backed CLI** (codex via IAM-role→Bedrock,
or any model whose first-token latency is backend-capacity dependent). A bare
timeout there is far more likely a **transient backend slow-start / capacity
blip** — i.e. environmental, self-healing — than an operator config/launch hang.

### Observed evidence (this repo's own self-review pipeline)

- A `review` dispatch smoked `codex` and got
  `SMOKE codex FAIL 121s reason=timeout (no model response within 120s)` → the
  gate aborted the whole review (the healthy `agy` member never ran), and the
  issue sat in `reviewing` for ~8.5h with no live wrapper.
- The **same `codex` config** smoked **PASS in 9s** on a different review
  dispatch the same day, and codex fan-out members exited 0 on multiple other
  reviews that day. So codex was NOT misconfigured — the 120s timeout was a
  one-off backend slow-start.

Net: one member's transient slowness took down an entire multi-agent review and
required manual recovery.

## The fix (minimal, one decision branch)

The three-state contract ([INV-63](../pipeline/invariants.md)) is unchanged:
**FAIL = operator-side config/launch breakage (gate-worthy); UNAVAILABLE =
environmental quota/capacity (drop the member, proceed).** The change is to move
the **bare-timeout** case from FAIL to UNAVAILABLE — recognizing a timeout with
no auth/config evidence as a *capacity* signal, the same tolerance INV-40 /
INV-58 (agy quota) / INV-61 (kiro auth) already apply: environmental → drop,
never a deciding veto.

`_smoke_classify`'s decision order already checks the environmental/auth/config
scraper signals **before** the timeout step. That ordering is **preserved** — a
timeout that *does* carry an `auth-failed` / `config-error` scraper signal still
classifies FAIL, because the scraper match (step 2/3) wins before the timeout
branch (step 4) is reached. Only the **fallthrough** of step 4 changes:

```
Decision order (first match wins):
  1. nonce present in STDOUT only                        → PASS
  2. environmental signal (quota/capacity/transient)     → UNAVAILABLE
  3. auth/config signal (per-CLI scraper)                → FAIL   ← preserved
  4. run_agent rc 124/137 (timeout) with no signal       → UNAVAILABLE   ← CHANGED (was FAIL)
  5. otherwise (non-timeout non-zero, no signal)         → FAIL   ← preserved (no-response)
```

### Why step 5 (`no-response`) stays FAIL — explicit decision

The issue calls this out as a judgment call. **Decision: keep step 5 FAIL.** A
**non-timeout** non-zero exit with no token (the CLI launched and exited promptly
without ever producing the nonce and without any recognizable environmental
signal) is far more plausibly a launch/config failure — a CLI that rejected a
flag, failed to authenticate in a way no scraper recognized, or crashed at
startup — than a capacity blip. A capacity/slow-start blip manifests as the
process running long and being *killed by the timeout* (124/137), which is
exactly the branch we are relaxing. A prompt non-zero exit is not that shape, so
the conservative gate-worthy default remains correct for step 5. Scoping the
change to the 124/137 timeout branch only keeps the genuine-config-break signal
intact.

## Gate behavior after the change (no gate code change needed)

`_smoke_classify` is the only place that decides the timeout case. The Phase A.5
gate (`lib-review-smoke.sh::_classify_smoke_state` → `_classify_smoke_gate`) is
**state-agnostic**: it already maps `smoke_agent` rc 2 → `unavailable` (dropped)
and rc 1 → `fail` (abort). So the single `_smoke_classify` change flows through
automatically:

| Scenario | Before | After |
|---|---|---|
| One member times out, another PASSes | review aborts (FAIL) | dropped (`smoke: timeout …`), fan-out proceeds on the survivor |
| Every member times out | review aborts (FAIL) | `all-unavailable` terminal path (INV-40), no empty fan-out |
| Member times out but log shows auth/config | FAIL (abort) | FAIL (abort) — scraper wins, unchanged |
| Member exits non-zero promptly, no token | FAIL (abort) | FAIL (abort) — `no-response`, unchanged |

No change is required in `lib-review-smoke.sh` or `autonomous-review.sh`; the gate
already treats `unavailable` correctly (drop / all-unavailable fall-through).

## Files changed

- `skills/autonomous-dispatcher/scripts/lib-agent-smoke.sh` — `_smoke_classify`
  step-4 branch (`FAIL|timeout` → `UNAVAILABLE|timeout`); the file-top
  THREE-STATE CONTRACT comment, the decision-order header comment, and
  `smoke_agent`'s rc-mapping header comment updated to match.
- `docs/pipeline/invariants.md` — INV-63 amended; a new INV cross-referencing
  INV-63/INV-64 documents the timeout→UNAVAILABLE rule.
- `docs/pipeline/review-agent-flow.md` — Phase A.5 wording updated.
- `tests/unit/test-lib-agent-smoke.sh`, `tests/unit/test-autonomous-review-smoke-gate.sh`
  — regression + preserved-FAIL + gate-proceeds + all-unavailable coverage.

## Out of scope

- The **fan-out** timeout-veto ([INV-48](../pipeline/invariants.md)): a review
  fan-out agent killed by the per-side review wall-clock cap (124/137) with no
  posted verdict is `timed-out`, a **deciding FAIL** that vetoes the merge. That
  is a different path (the actual review run hit its 1h budget after producing no
  verdict) from the pre-fan-out **smoke** probe (a one-token capacity check), and
  is correctly loud. This change does NOT touch INV-48.
