# Test Cases — Lane-GC PR-6: back-pressure gate + remote DEFERRED (#382)

Sixth PR of the Lane-GC series (design: `docs/designs/lane-containment-gc.md`
§4-C6, §9 PR-6; INV-119 — renumbered from the design's drafted INV-112 after
the design-time head assumption went stale; by this PR's rebase, INV-111
through INV-118 were already shipped by prior PRs in the series, so this PR
claims the first free slot, INV-119). Stops the OOM-feedback amplifier
(design §1) by refusing to spawn under box distress, plus the remote-backend
plumbing so a deferral is never misattributed as a crash:

1. **`skills/autonomous-dispatcher/scripts/dispatch-local.sh`**: a
   back-pressure admission gate before `kill_stale_wrapper`/spawn — four
   signals (load/core, MemAvailable, swap%, global live-lane count; three
   strictly independent, the swap signal conditionally rescued by memory
   headroom as of **#441**, see below), one bounded `adt-gc.sh --quick`
   reclaim attempt on refusal, a re-check-once, a defer marker + `exit 75`
   on persistent distress.
2. **`lib-lane.sh::lane_global_live_count`** (new): registry-driven global
   live-lane count across every project, falling back to a PID-file count
   on a fresh host with no registry yet. `box_health` gains macOS/BSD
   fallback probes.
3. **`lib-dispatch.sh`**: `is_dispatch_deferred_rc` + `handle_dispatch_deferred`
   (rc=75 attribution — no retry-budget decrement, no label change, wired
   into every `dispatch()` call site).
4. **Remote DEFERRED plumbing (three files)**: `liveness-check-remote-aws-ssm.sh`
   emits a fourth `DEFERRED\n<age_s>` verdict; `_remote_pid_alive_query`
   parses it; `pid_alive` carries it on a side channel; `dispatcher-tick.sh`
   Step 5b fast-returns on it before the no-PR/near-success crash checks.

Test runner: `bash tests/unit/test-lane-gc-p6-gate.sh` (auto-discovered by
the CI `hermetic-unit` job's `tests/unit/test-*.sh` glob) plus the E2E
`tests/e2e/run-lane-gc-p6-gate-e2e.sh` (thin-wrapped for the same loop via
`tests/unit/test-lane-gc-p6-gate-e2e.sh`, and its own dedicated CI job). Run
the unit suite under `env -u PROJECT_DIR bash ...` too, for CI parity.

## Load/mem-floor/lane-cap signals fire independently (AC: "each signal
independently → exit 75 + marker + logged reason")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC6-001 | `_GATE_LOAD1_PER_CORE_OVERRIDE=99`, other three signals healthy, real `dispatch-local.sh dev-new` invocation | exit 75; stderr names `load1_per_core`; defer marker touched naming the same reason |
| TC-LGC6-002 | `_GATE_MEM_AVAILABLE_MB_OVERRIDE=1`, other three healthy | exit 75; stderr/marker name `mem_available_mb` |
| TC-LGC6-004 | `_GATE_LIVE_LANE_COUNT_OVERRIDE=999`, other three healthy | exit 75; stderr/marker name `live_lane_count` |

## Swap signal — memory-headroom rescue (**#441**, amends INV-119; AC: "swap
false-positive on large-RAM hosts no longer defers when MemAvailable is
abundant; genuine-pressure case still defers")

`GATE_MIN_MEM_MB` default 2048, `GATE_SWAP_REQUIRES_MEM_MULTIPLE` default 3
→ rescue floor (`swap_mem_gate_mb`) = 6144 MB with defaults.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC6-003 | `_GATE_SWAP_PCT_OVERRIDE=99`, `_GATE_MEM_AVAILABLE_MB_OVERRIDE=999999` (abundant), other two healthy | exit **0** (was exit 75 pre-#441) — dispatch actually proceeds to spawn; no defer marker. The reported false-positive case (large-RAM host, healthy MemAvailable). |
| TC-LGC6-003b | `_GATE_SWAP_PCT_OVERRIDE=91`, `_GATE_MEM_AVAILABLE_MB_OVERRIDE=5000` (mid-band: below the 6144 rescue floor, above the 2048 hard floor), other two healthy | exit 75; stderr/marker name `swap_mem_gate_mb` — early-warning band preserved |
| TC-LGC6-003c | `_GATE_SWAP_PCT_OVERRIDE=89` (within limit), `_GATE_MEM_AVAILABLE_MB_OVERRIDE=5000` (same mid-band value as 003b), other two healthy | exit 0 — the memory check inside the swap branch never engages when swap itself is not over `GATE_SWAP_PCT` |
| TC-LGC6-003d | `_GATE_SWAP_PCT_OVERRIDE=91`, `_GATE_MEM_AVAILABLE_MB_OVERRIDE` set to a non-numeric/unavailable value, other two healthy | exit 75; stderr/marker record the unresolved `mem_available_mb` value — fails toward the pre-#441 behavior when the rescue evidence itself is unknown |
| TC-LGC6-003e | `GATE_SWAP_REQUIRES_MEM_MULTIPLE="not-a-number"` (operator typo), high swap (99), abundant memory (999999) | exit 0, dispatch actually proceeds — a malformed multiplier falls back to the default (3) instead of crashing the gate's arithmetic under `set -euo pipefail` |

## Healthy box proceeds to spawn (AC: "healthy box → proceeds")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC6-010 | All four signals overridden to healthy values, real `dispatch-local.sh dev-new` invocation | exit 0; "Dispatched dev-new for issue #…" printed (spawn actually attempted, not merely rc=0); no defer marker written |

## Pre-refusal `--quick` reclaim attempt (AC: "pre-refusal --quick attempted")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC6-020 | `_ADT_GC_ENTRY_OVERRIDE` points at a recording stub; one signal distressed | refusal path still exits 75 (stub doesn't clear the override); stub invoked exactly TWICE — once by the pre-existing unconditional opportunistic call, once by the gate's own refusal-path reclaim attempt; at least one invocation carries `--quick` |

## Re-check-once semantics (AC: "pressure clears after --quick → dispatch
proceeds")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC6-030 | A file-based override (`_GATE_LOAD1_PER_CORE_OVERRIDE_FILE`) starts distressed; a stub `adt-gc.sh --quick` rewrites the file to a healthy value ONLY on its second (gate-triggered) invocation | dispatch proceeds (rc=0); "dispatch proceeding" logged after the reclaim; wrapper actually spawns; no defer marker left |
| TC-LGC6-031 | Counter-test: SAME setup but the stub never clears the override | exit 75 (proves 030 isn't vacuously passing because the gate never actually re-checked) |

## `lane_global_live_count` — registry-count and PID-file-fallback branches
(AC: "both tested")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC6-040 | One lane minted + installed under an isolated `ADT_STATE_ROOT` (self-referential, live per `lane_probe`) | count = 1 (registry-driven branch) |
| TC-LGC6-041 | NO `lanes/` directory exists anywhere under an isolated `ADT_STATE_ROOT`; two live PID files across two different projects, one dead PID file | count = 2 (PID-file-fallback branch; dead PID excluded) |
| TC-LGC6-042 | A project's `lanes/` directory EXISTS but is EMPTY (the ordinary idle-project case) | count = 0 via the REGISTRY path, not the fallback (an existing-but-empty lanes dir must not trip the fallback) |

## rc=75 attribution (AC: "no-decrement/no-label verdict")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC6-050 | `is_dispatch_deferred_rc` fed 75 / 1 / 0 | true only for 75 |
| TC-LGC6-050d-g | `handle_dispatch_deferred` with stubbed `release_dispatch_marker`/`label_swap`/`itp_post_comment`/`count_retries` | releases the marker for (issue,mode); reverts the label (args reversed from the caller's own swap); never posts a comment; never calls `count_retries` |

## Gate is provably signal-free (AC: "no kill/pkill/signal call reachable
from the gate path")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC6-060 | Extract the gate's own code block (`_run_adt_gc_quick` through the end of `_admission_gate`'s definition) via `awk`, strip comments | no `kill`/`pkill`/`SIGTERM`/`SIGKILL` token anywhere in the extracted code |

## Marker cleanup on next successful dispatch (design §5)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC6-070 | A stale defer marker pre-exists for (kind, issue); a subsequent healthy dispatch for the SAME (kind, issue) | dispatch succeeds; the stale marker is removed |

## Mock-SSM DEFERRED (AC: "mock-SSM: liveness snippet returns DEFERRED →
Step 5b posts nothing, flips nothing, decrements nothing")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC6-080 | Stub `aws` CLI's `get-command-invocation` returns `StandardOutputContent: "DEFERRED\n45\n"` | `liveness-check-remote-aws-ssm.sh` exits 0, stdout exactly `DEFERRED\n45` |
| TC-LGC6-081 | Same, but the age line is unparseable (`not-a-number`) | driver exits 2 (indeterminate) — never fabricates a DEFERRED verdict with garbage age data |
| TC-LGC6-090 | `_remote_pid_alive_query` driven against a fake driver emitting the two-line DEFERRED form | returns the single-token `DEFERRED:45` |
| TC-LGC6-100 | `pid_alive issue N` under `EXECUTION_BACKEND=remote-aws-ssm` with the driver override emitting DEFERRED | `pid_alive` returns 1 (not-alive); `PID_ALIVE_LAST_VERDICT=DEFERRED`; `PID_ALIVE_LAST_DEFERRED_AGE=45` |
| TC-LGC6-101 | A DEFERRED probe followed by a subsequent ALIVE probe (different issue, same tick) | the side channel resets to empty on the second call — no stale DEFERRED leak across issues |
| TC-LGC6-110 | Step 5b's loop body extracted and driven with `pid_alive` stubbed to set the DEFERRED side channel + return 1 | posts NO comment; flips NO label |
| TC-LGC6-111 | Counter-test: same harness, `pid_alive` returns 1 with an EMPTY side channel (a plain DEAD, not DEFERRED) | DOES post the crash comment; DOES flip the label — proves TC-LGC6-110's fast-return is gated on the verdict, not dead code |

## Hygiene

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC6-120 | grep every touched file for private-repo references / the literal `codex review` phrase | zero hits |

## E2E (`tests/e2e/run-lane-gc-p6-gate-e2e.sh`)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC6-E2E-01 | Real, unmodified `dispatch-local.sh` against a real fixture project layout, box distress injected via the override env vars | exits 75; deferral logged; defer marker touched; NO fixture wrapper process spawned |
| TC-LGC6-E2E-02 | Same invocation repeated with the overrides cleared | exits 0; fixture wrapper genuinely spawns (observable via its own marker); the TC-LGC6-E2E-01 defer marker is removed |
