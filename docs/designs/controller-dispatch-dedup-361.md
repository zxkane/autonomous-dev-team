# Design — controller-side per-(issue,mode) dispatch dedup + run-id attribution (#361, 302b, INV-108)

> 302b of the #302 pair. 302a (#360/INV-103) closed the wrapper-HOST start race with a
> kernel-held `flock`; this half closes the controller-side tick-vs-tick race that let two
> overlapping dispatcher ticks each dispatch the same `(issue, mode)` — the #298 incident
> (three duplicate `dispatcher-token` pairs ~1s apart). Full normative contract: INV-108
> in `docs/pipeline/invariants.md` (this canvas is the narrative; the invariant is the spec).

## Problem

`JUST_DISPATCHED` (INV-09) is a tick-LOCAL in-memory array — it protects one tick's own
Step 5 from re-classifying an issue it just dispatched, but a SECOND overlapping tick
process cannot see it. Two ticks both read "not just dispatched" → both `label_swap` +
`post_dispatch_token` + `dispatch()` → duplicate wrapper runs.

## Shape

```
Step 2/3/4 dispatch site (×4 in dispatcher-tick.sh)
+ handle_completed_session_routing Branch C (lib-dispatch.sh, also reached via INV-98)
        │
        ├─ acquire_dispatch_marker <issue> <mode>     ← BEFORE any side effect
        │      mkdir pid_dir/dispatch-marker-<issue>-<mode>   (atomic, EEXIST = held)
        │      rc0 acquired / infra-fail-open · rc1 held-by-concurrent-tick → skip cleanly
        │
        ├─ label edit / notice / token (mode=… run=<run-id>) / dispatch()
        │
        ├─ dispatch() OK → dispatch_marker_confirm_launched   (marker lives out TTL)
        └─ any pre-spawn failure → release:
               explicit release_dispatch_marker at soft-fail branches (PTL, INV-35 truncate)
               trap _dispatch_marker_release_pending EXIT      (set -e teardown backstop)
```

- **TTL** = `DISPATCH_MARKER_TTL_SECONDS` (default INV-18 grace, 600s); stale reclaim via
  atomic `mv`+`mkdir` (avoids #360's rmdir double-reclaim race). Never a permanent lock.
- **Fail-open, three classes** (marker infra must never freeze dispatch; INV-103 is the
  definitive backstop): base-dir unresolvable; symlinked marker path; **non-EEXIST
  marker-creation failure** (round-6 [P1]: ENOSPC/permissions after the base dir resolved —
  distinguished from a dedup hit by a post-mkdir existence check + ONE mkdir retry, so a
  holder-release landing in the mkdir→check window re-acquires instead of falsely
  fail-opening; a nonexistent marker must not read as "held", which would stall every
  retry with nothing to expire).
- **Single-controller scope by contract**: dedup covers ticks of ONE controller process
  (the OpenClaw gateway topology). Multi-controller is out of contract — no cross-host state.
- **R2**: `post_dispatch_token` appends `run=<run-id>` after `mode=` (env `DISPATCHER_RUN_ID`
  or `$$-<epoch>`, minted once per tick process). Readers keep an optional trailing group —
  legacy tokens parse unchanged.

## Review-round hardening (rounds 4-6)

1. Release-on-pre-spawn-failure (pending list + confirm + EXIT trap) — round-4 [P1].
2. Branch C parity coverage (TC-031b/033, mutation-verified) — round-5 [P1].
3. Marker-creation failure fails OPEN (fail-open class 3 above; TC-010b/c/d) — round-6 [P1].

## Test map

`tests/unit/test-controller-dispatch-dedup-361.sh` (TC-DEDUP-361-001..033): real-process
10-way mkdir race; TTL block/reclaim; the three fail-open classes + plain-file boundary
control; run= format/override/cache + backward compat; verbatim-extracted guard blocks
executed against the real functions (mutation-tested); acquire/confirm call-count parity
in BOTH files; EXIT-trap installation. Full per-TC inventory: INV-108 **Test** section.
