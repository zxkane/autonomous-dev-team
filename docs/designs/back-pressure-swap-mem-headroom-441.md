# Design: Back-pressure gate — swap_pct conditionally gated by memory headroom (#441)

**Status:** Amendment to [INV-119](../pipeline/invariants.md#inv-119-dispatch-localsh-refuses-to-spawn-under-box-distress-exit-75-ex_tempfail-after-one-bounded-reclaim-attempt-and-a-remote-backend-deferral-surfaces-as-a-fourth-deferred-liveness-verdict--never-a-crash) and its parent design, `docs/designs/lane-containment-gc.md` §4-C6 (back-pressure admission gate). This doc records only the delta this issue introduces — it is not a re-derivation of the gate's full design; defer to the parent doc and INV-119 for everything unchanged.

## Problem

INV-119 defined the back-pressure gate's four signals (load/core, MemAvailable floor, swap-used%, global live-lane count) as **strictly independent** — any one signal alone can defer a dispatch. This was a deliberate choice (see the design comment above `_gate_check_signals` in `dispatch-local.sh`: "proving per-signal independence, not merely an OR-of-everything"), and `TC-LGC6-003` actively asserted it for the swap signal (high swap + abundant memory → still defers).

Issue #441 reported that this independence produces a real false positive on large-RAM hosts: `swap_pct` measures swap-used ÷ swap-total, which on a host with a comparatively small, rarely-cycled swap file can sit permanently above `GATE_SWAP_PCT` (default 90) from stale accumulation by processes entirely outside the dispatcher's own process tree — with zero relationship to actual `MemAvailable`. Observed case: 123Gi RAM, 8Gi swap, `swap_pct=91` alongside `mem_available_mb≈109000` (extremely healthy). Dispatch deferred forever; the only recovery was an out-of-band `swapoff -a && swapon -a`.

A 6-model llm-team review (deepseek/kimi/glm5/grok/minimax/codex) unanimously confirmed this is a genuine design trade-off requiring an explicit decision (early-warning value vs. false-positive rate), not a wording fix — because any fix that resolves the false positive necessarily contradicts `TC-LGC6-003`'s existing assertion and the "independent" framing INV-119 currently records.

**Decision (this doc): fix the DEFAULT behavior.** INV-119 is formally amended (not left as an opt-in flag) — see Amendment below.

## Fix: memory-headroom rescue for the swap signal

The swap signal keeps its own ceiling check (`GATE_SWAP_PCT`) but is no longer allowed to fire in isolation when memory headroom is comfortable. It is rescued by an independent, ADDITIONAL predicate on `mem_available_mb`:

```bash
GATE_SWAP_REQUIRES_MEM_MULTIPLE="${GATE_SWAP_REQUIRES_MEM_MULTIPLE:-3}"

swappct="$(_gate_override "${_GATE_SWAP_PCT_OVERRIDE:-}" "${_GATE_SWAP_PCT_OVERRIDE_FILE:-}" || true)"
[[ -n "$swappct" ]] || swappct="$(_gate_health_field "$health" swap_pct || true)"
if [[ "$swappct" =~ ^[0-9]+$ ]] && [[ "$swappct" -gt "$GATE_SWAP_PCT" ]]; then
  memavail="$(_gate_override "${_GATE_MEM_AVAILABLE_MB_OVERRIDE:-}" "${_GATE_MEM_AVAILABLE_MB_OVERRIDE_FILE:-}" || true)"
  [[ -n "$memavail" ]] || memavail="$(_gate_health_field "$health" mem_available_mb || true)"
  swap_mem_gate_mb=$((GATE_MIN_MEM_MB * GATE_SWAP_REQUIRES_MEM_MULTIPLE))
  if ! [[ "$memavail" =~ ^[0-9]+$ ]] || [[ "$memavail" -lt "$swap_mem_gate_mb" ]]; then
    printf 'swap_pct=%s > GATE_SWAP_PCT=%s and mem_available_mb=%s < swap_mem_gate_mb=%s' \
      "$swappct" "$GATE_SWAP_PCT" "${memavail:-unknown}" "$swap_mem_gate_mb"
    return 1
  fi
fi
```

Placement: replaces the existing swap-check block in `_gate_check_signals` (`dispatch-local.sh`, currently ~lines 264-268), in the same fixed check order (load, mem, swap, lane-cap) — unchanged.

**Rejected alternatives** (considered during design, via an independent codex recommendation weighing all three against this script's existing statelessness):
- **Full AND, no independence** (swap only fires when `mem_available_mb < GATE_MIN_MEM_MB` too): rejected — makes `swap_pct` fully redundant with the existing memory floor, losing all early-warning value the original incident (design doc's "swap full" preceding a load-241 crash) relied on.
- **Swap-usage trend/velocity instead of absolute %**: rejected for now — `dispatch-local.sh` is a per-attempt, stateless script (fresh process every invocation, no daemon); tracking a rate of increase would require a NEW persisted sample-history file, with attendant locking/cleanup/concurrency/clock-skew complexity, for a case the memory-headroom rescue already resolves at far lower cost. Not ruled out as a future PR if a case emerges that headroom-gating doesn't cover.

**Behavior at the four bands** (`GATE_MIN_MEM_MB=2048`, `GATE_SWAP_REQUIRES_MEM_MULTIPLE=3` defaults, so the rescue floor is `6144`):
- `swap_pct` within limit → never fires, regardless of memory (unchanged).
- `swap_pct` over limit AND `mem_available_mb ≥ 6144` → **no longer fires** (this is the false-positive fix; the reported case, `mem≈109000`, lands here).
- `swap_pct` over limit AND `2048 ≤ mem_available_mb < 6144` → **still fires** (the early-warning band: memory headroom is shrinking toward the hard floor while swap is also saturated — the two together are more informative than either alone).
- `swap_pct` over limit AND `mem_available_mb < 2048` → still fires (also independently caught by the existing MemAvailable-floor check — belt and suspenders, unchanged).
- `mem_available_mb` missing/non-numeric while swap is over limit → **fires** (fail toward the pre-#441 behavior when the rescue signal itself is unknown — absence of evidence is not evidence of headroom; mirrors `_gate_health_field`'s existing "absent means unknown, never a guess" principle).

**New config knob**: `GATE_SWAP_REQUIRES_MEM_MULTIPLE` (default `3`). Not hardcoded because the multiplier is a real operator-tunable policy choice (a smaller/tighter box may want `2`; a host that wants to preserve more of the old early-warning sensitivity may want `4`+). Documented in `autonomous.conf.example` and `dispatcher.conf.example` alongside the three existing gate knobs, same comment style.

## INV-119 amendment

`docs/pipeline/invariants.md` INV-119 changes:
- The intro line "four INDEPENDENT admission signals" is corrected to: "four admission signals — three (load/core, MemAvailable floor, global live-lane count) strictly independent; the swap signal is conditionally gated by available-memory headroom, see the amendment below."
- Signal 3's own bullet (swap-used%) gains the headroom-rescue formula and a pointer to this doc.
- A new **Amendment note (2026-07-08, #441)** is added, following this repo's existing convention for documenting a later PR's revision of an earlier invariant's assumption (see INV-119's own pre-existing "Numbering note" for the pattern this follows): records that the original "strictly independent" framing was found to false-positive on large-RAM hosts with stale swap accumulation unrelated to dispatcher-managed processes, and that the fix is a memory-headroom rescue, not a removal of the signal.

`dispatch-local.sh`'s own design comment block above `_gate_check_signals` (the "proving per-signal independence, not merely an OR-of-everything" paragraph) is updated to match: three signals remain independent for that rationale; the swap signal is called out as the one exception, with a one-line pointer to this doc.

`docs/designs/lane-containment-gc.md` §4-C6 gets a short amendment pointer (not a rewrite — that doc is the historical parent design) noting that the swap signal's independence assumption was revised by #441; see this doc for the current behavior.

## Test changes

`tests/unit/test-lane-gc-p6-gate.sh`:

- **`TC-LGC6-003` (rewritten, same ID/position, assertion reversed):** high swap (`swap_pct=99` override) + abundant memory (`mem_available_mb=999999` override, unchanged parameters) → dispatch now **proceeds** (was: `exit 75`). Comment updated to record this is the #441 behavior change; the old pre-#441 assertion is explicitly noted as superseded, not silently dropped.
- **`TC-LGC6-003b` (new):** high swap (91) + mid-band memory (5000 — below the default rescue floor 6144, above the hard floor 2048) → still defers (`exit 75`), proving the early-warning band survives.
- **`TC-LGC6-003c` (new):** swap within limit (89) + mid-band memory (5000) → dispatch proceeds, proving the new memory check inside the swap branch only engages when swap itself is already over `GATE_SWAP_PCT` (no new false-positive introduced on the memory axis alone — that's still owned entirely by the pre-existing, unchanged `GATE_MIN_MEM_MB` branch).
- **`TC-LGC6-003d` (new):** high swap (91) + memory signal unset/unavailable → still defers, proving the fail-toward-pre-#441-behavior default when the rescue evidence itself is unknown.
- **`TC-LGC6-001`/`002`/`004`** (load, mem-floor, lane-cap signals) — unchanged, asserted to stay green with no modification, proving no regression on the other three signals.

All four new/changed cases use the existing `_GATE_SWAP_PCT_OVERRIDE` / `_GATE_MEM_AVAILABLE_MB_OVERRIDE` test seam — no new test infrastructure required.

## Out of scope

- `adt-gc.sh --quick`'s reclaim scope is unchanged (correctly targets orphaned lane processes; stale swap from unrelated processes is never something a dispatcher-owned GC should reach into).
- The dispatcher does not gain a `swapoff`/`swapon` capability — that remains an out-of-band operator action.
- The load/core, MemAvailable-floor, and global live-lane-count signals are unchanged; this doc touches only the swap signal's trigger condition.
- Swap-usage trend/velocity tracking (rejected alternative C above) is not implemented — a future PR if the headroom rescue proves insufficient in practice.
