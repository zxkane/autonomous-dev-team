# Design: Lane-GC P3 — Kill-path hardening

**Status:** Implementation notes for issue #379 (Lane-GC series PR-3). Full
design authority is `docs/designs/lane-containment-gc.md` §4-C4 (kill
choreography), §8 (INV-106/INV-111), §9 PR-3. This doc records only the
PR-open numbering re-verification and the concrete diff shape; it is not a
new design — defer to the parent doc for rationale.

## Numbering re-verification (design §8/§10 F10 completeness)

The parent design assumed head INV-105 and reserved INV-106..113 (§8). Since
the design was written, INV-106 (provider conformance) through INV-110 (lane
tagging) have already shipped under those exact numbers via unrelated PRs
(#370-#392). Current head at this PR's open is **INV-110**. This PR therefore
ships:

- **INV-114 — Kill-escalation contract** (was drafted as INV-106 in the
  design doc's normative table; renumbered here to the first free slot).
- **INV-115 — Bounded, ordered teardown** (was drafted as INV-114).

The design doc's own wording anticipates this exact collision (§8: "Renumber-
on-rebase-collision per repo convention: first-merged keeps, each INV-adding
PR notes the convention") and deliberately references the shipped fan-out-
reap invariant symbolically rather than by number for this reason.

## Scope (this PR)

1. `_kill_group_escalate` shared helper in `lib-lane.sh` (design §4-C4,
   adopted verbatim).
2. Wrapper TERM trap rewrite (`install_agent_sigterm_trap`, `lib-agent.sh`):
   iterate every registry-recorded pgid (fixes the review-side dead arm
   where `_AGENT_RUN_PID` is empty in the main shell — the review wrapper's
   agents run in fan-out subshells, so the main shell's own
   `_AGENT_RUN_PID` is never set) + a backgrounded escalator that KILLs
   surviving groups after grace.
3. `kill_stale_wrapper` group-gate fix (`dispatch-local.sh`, both escalation
   sites): leader-only `kill -0 $old_pid` → leader-OR-group.
4. `cleanup()` reap-first ordering (both wrappers): acquire `reap.lock` →
   `STATE=cleaning` → reap all registry pgids → FIFO handshake (feature-
   guarded no-op until P5 ships the FIFO) → PID/registry state updates →
   network work last, each network call bounded `timeout 60`.
5. INV-26 attribution sentence (rc=137 following a pipeline TERM is
   self-induced).
6. Grep-pin: `pkill -P $$` never widened to `-f <script-name>`.

Guardian (P5), `adt-gc.sh` (P4), systemd-scope (P7), and the back-pressure
gate (P6) are later PRs — not touched here.
