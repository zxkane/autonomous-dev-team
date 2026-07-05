# Test Cases — Lane-GC PR-5: guardian sidecar (#381)

Fifth PR of the Lane-GC series (design: `docs/designs/lane-containment-gc.md`
§4-C3, §9 PR-5; INV-118 — renumbered from the design's drafted INV-109 after
the design-time head assumption (INV-105) went stale; by this PR's rebase,
INV-106..117 were already shipped by prior PRs in the series plus unrelated
PRs, so this PR claims the first free slot, INV-118). A per-lane,
`setsid`-detached death watch that reaps the lane on ANY wrapper death —
including SIGKILL and OOM, which bypass every in-process trap:

1. **`skills/autonomous-dispatcher/scripts/lib-guardian.sh`** (new
   `lib-*`-named entry-point script): no-writer watchdog armed BEFORE the
   blocking fifo open (an ordering-bug fix over the design's own
   pseudocode, found while writing this suite), a chunked/PPID-style hard
   lifetime cap, the main EOF wait, and `do_reap` (idempotent under
   `reap.lock`, lane-scoped escape sweep, ENOENT-tolerant).
2. **Wrapper integration** (`autonomous-dev.sh`, `autonomous-review.sh`):
   `mkfifo` → write-fd open → `setsid` prereq check → guardian spawn
   (closing its own inherited fd) → `GUARDIAN_PID` recorded. `cleanup()`
   gains the FIFO clean-exit handshake in the slot [INV-115] reserved.
3. **FD-hygiene closes** at every long-lived background spawn site this
   series already ships (agent CLI spawn, heartbeat, both TERM-trap
   escalators, token daemon, `lane_kill`'s escalator, `_bounded_call`'s
   spawn, the review side's smoke-probe and fan-out subshells).

Test runner: `bash tests/unit/test-lane-gc-p5-guardian.sh` (auto-discovered
by the CI `hermetic-unit` job's `tests/unit/test-*.sh` glob) plus the E2E
`tests/e2e/run-lane-gc-p5-guardian-e2e.sh` (thin-wrapped for the same loop
via `tests/unit/test-lane-gc-p5-guardian-e2e.sh`, and its own dedicated CI
job). Run the unit suite under `env -u TERM_PROGRAM -u PROJECT_DIR` — the
escape-sweep tests need `TERM_PROGRAM` unset to actually exercise the sweep
(this dev box exports `TERM_PROGRAM=tmux`, which the guardian's own operator
fail-safe unconditionally skips regardless of lane tag — the suite detects
this and marks the affected assertion SKIPPED-AS-FAIL, not silently green).

## No-writer watchdog + the ordering-bug regression (AC covers the "no
writer present" scenario the design's §4-C3 mandates)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC5-001 | Guardian spawned directly against a fifo NOBODY ever opens for write, with `ADT_GUARDIAN_NO_WRITER_GRACE_SECONDS` accelerated | guardian self-exits (does not hang) within an outer backstop timeout |
| TC-LGC5-001b | Same scenario, elapsed-time assertion | guardian exits close to the CONFIGURED grace (not the outer backstop) — proves the watchdog interrupts the BLOCKING OPEN call itself, not merely a post-open check (the exact ordering bug this PR fixes over the design's own pseudocode) |
| TC-LGC5-002 | Guardian log after a no-writer exit | names the no-writer watchdog firing explicitly |
| TC-LGC5-003 | Source-of-truth grep-pin | the watchdog's `trap … USR2` line precedes the `exec 3<"$FIFO_PATH"` open line in the shipped script — structural pin backing TC-LGC5-001b |

## SIGKILL integration — recorded-pgid reap (AC1: "SIGKILL the wrapper's
session → guardian reaps recorded pgids ≤ grace+2s")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC5-010 | Fixture "wrapper": `lane_install`s, opens the write fd, spawns a REAL guardian AND a recorded `setsid` agent child, then the fd is closed (simulating the wrapper session's SIGKILL — the fd-close is the observable effect a real SIGKILL produces identically) | the recorded agent pgid is dead within grace(10s)+2s |
| TC-LGC5-010b | Same fixture | the guardian itself exits after reaping (does not linger) |
| TC-LGC5-011 | Same fixture, lane STATE after the reap | promotes to `reaped-by-guardian` |

## Lane-scoped escape sweep (AC2/AC3: "escaped setsid child carrying THIS
lane's tag is swept; carrying a DIFFERENT lane's tag is NOT swept")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC5-020 | An escapee (no pgid recorded) carrying THIS lane's `ADT_LANE_ID` via inherited env, after the wrapper's fd closes | swept (TERM→2s→KILL) — run with `TERM_PROGRAM` unset; the suite marks this SKIPPED-AS-FAIL (not silently green) when `TERM_PROGRAM` is ambiently set, since the guardian's own operator fail-safe would otherwise mask the sweep-vs-skip distinction under test |
| TC-LGC5-021 | A second escapee carrying a DIFFERENT, but registered, lane's `ADT_LANE_ID` | NOT swept — untouched regardless of `TERM_PROGRAM` |

## FD hygiene — sole-holder fast EOF vs. inherited-fd deferred EOF (design
§4-C3: "sole-holder EOF ~1ms measured; inherited defers to last-close")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC5-030 | A fifo's write fd is opened, then closed with no other holder | a waiting reader observes EOF in well under 2s (generously bounding the design's own sub-millisecond measurement) |
| TC-LGC5-031 | A fifo's write fd is opened; a child subshell inherits it (never closes it); the ORIGINAL opener closes its own copy | EOF is DEFERRED while the inherited-fd-holding child is still alive (a bounded read times out, not EOF) |
| TC-LGC5-031b | Same scenario, after the inherited-fd-holding child exits | EOF finally arrives — proves closing at every spawn site is necessary, not merely at the top-level wrapper |

## Graceful exit — zero kills (AC5: "graceful exit → guardian exits with
zero kills")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC5-040 | Fixture wrapper runs the REAL graceful sequence: `STATE=cleaning` → handshake (`printf 'done'` + fd close) → `STATE=clean-exit` | guardian exits promptly |
| TC-LGC5-040b | Same fixture, lane STATE after | stays at `clean-exit` (the WRAPPER's own promotion) — the guardian never overwrites it |
| TC-LGC5-040c/d | Guardian log content | shows NO escalation/kill activity, no pgid escalation line |
| TC-LGC5-040e | Guardian log content | shows the terminal-STATE zero-kill skip line (proves the graceful path is recognized as such, not merely "happened to find nothing to kill") |

## Lifetime cap (AC6: "lifetime cap fires in an accelerated test AND its
watchdog dies with a SIGKILLed guardian")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC5-050 | Guardian spawned with `ADT_GUARDIAN_CAP_SECONDS_OVERRIDE`/`ADT_GUARDIAN_CAP_CHUNK_SECONDS` accelerated to a few seconds, fd deliberately kept open (never handshaked, never SIGKILLed) | the lifetime cap fires and is logged |
| TC-LGC5-050b | Same scenario, elapsed time | close to the accelerated window, not the real hours-scale cap |
| TC-LGC5-051 | Guardian SIGKILLed directly while its lifetime-cap chunk-watchdog is running (a long, un-accelerated cap) | the guardian is gone |
| TC-LGC5-051b | Same scenario, the chunk-watchdog's own pid | dies within ~1 chunk of the guardian's SIGKILL — never survives to the full cap (the anti-monolithic-sleep guarantee) |

## `reap.lock` race (AC7: "guardian racing GC on the same dead lane →
reap.lock serializes, exactly one reaper acts")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC5-060 | A TERM-trapping recorded pgid (forces the escalation to actually reach the KILL pass — a bare `sleep` dies on the first TERM and makes a double-KILL regression unobservable); the guardian's EOF-triggered reap races a CONCURRENT `lane_kill` call against the same lane | exactly ONE `SIGKILL` is issued against the shared pgid (measured via a wrapped `kill` counter) — `reap.lock` serializes, no double-KILL |
| TC-LGC5-061 | Grep-pin over `do_reap`'s CODE lines (comments excluded — the function's own doc comments reference `lane_kill` by name in prose to explain WHY it is avoided) | `do_reap` never calls `lane_kill` — it escalates via the shared `_kill_group_escalate` primitive directly, avoiding the non-reentrant-flock self-deadlock a `lane_kill` call would cause against a lock `do_reap` already holds |

## ENOENT tolerance (design §4-C3 selfdefeat:F4 — "GC rule 1.4 may have
`rm -rf`'d the dir out from under us")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC5-070 | The ENTIRE lane dir is `rm -rf`'d before the guardian ever wakes (simulating GC rule 1.4 having already collected it) | guardian exits cleanly (no error, no hang) |
| TC-LGC5-070b | Guardian log | names the vanished-dir tolerance explicitly |

## Wrapper install-order grep-pins (design §4-C3's load-bearing FIFO-open
ordering contract)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC5-080 | Both wrappers, source-of-truth grep-pin | `mkfifo` precedes the write-fd open |
| TC-LGC5-081 | Both wrappers, source-of-truth grep-pin | the write-fd open precedes the guardian spawn line — the load-bearing ordering contract |
| TC-LGC5-082 | Both wrappers, the guardian's OWN spawn line | closes its inherited `ADT_GUARD_FD` before exec'ing `lib-guardian.sh` (the second FD-hygiene bug found empirically — without this the guardian becomes a second write-holder of its own watched fifo) |

## `setsid`-absent degradation (AC7 read as: fatal, actionable, but a
DEGRADE not an abort — see the design doc's interpretation note)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC5-090 | Both wrappers' guardian-install block | checks `command -v setsid` |
| TC-LGC5-090b | Same block's failure branch | mentions `util-linux` (actionable remediation) |
| TC-LGC5-090c | Same block's failure branch | does NOT call `exit` — degrades (logs + continues) rather than aborting the wrapper run; the periodic GC ([INV-117]) remains the backstop |

## FD-hygiene grep-pin (design §10's own honesty wording, reused verbatim:
"guards literal sites only")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC5-100 | Every literal spawn site named in the design (agent spawn, heartbeat, both escalators, token daemon, `lane_kill` escalator, `_bounded_call`, smoke probe, fan-out subshell) | at least one `ADT_GUARD_FD` close guard present in its file |
| TC-LGC5-101/102/103 | Per-file MINIMUM close-guard counts (`lib-agent.sh` ≥ 3, `lib-lane.sh` ≥ 2, `autonomous-review.sh` ≥ 2) | catches a regression that removes ONE site while leaving another, which a presence-only check would miss |

## `cleanup()` handshake ordering (INV-115's reserved slot)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC5-110 | Both wrappers, source-of-truth grep-pin | the reap-first block precedes the guardian handshake |
| TC-LGC5-110b | Both wrappers, source-of-truth grep-pin | the handshake precedes the first network-work call site |

## Packaging + hygiene

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC5-120 | `lib-guardian.sh`'s basename against the `lib-*.sh` pattern | matches — confirms `install-project-hooks.sh` never symlinks it (no installer re-run needed) |
| TC-LGC5-130 | Every touched file, private-repo-reference scan | zero hits |
| TC-LGC5-130b | The new `lib-guardian.sh` only (not pre-existing files that legitimately name the `codex review` CLI subcommand) | zero `codex review` phrase hits |

## E2E — real wrapper, fixture CLI (the issue's own stated AC: "full
dev-wrapper run with fixture agent, SIGKILL mid-run → tree empty within
grace+2s, `STATE=reaped-by-guardian`")

`tests/e2e/run-lane-gc-p5-guardian-e2e.sh` (TC-LGC5-E2E-01), thin-wrapped for
the CI unit-test loop by `tests/unit/test-lane-gc-p5-guardian-e2e.sh`, and
given its own dedicated CI job for independent visibility (mirroring the
Lane-GC PR-3 E2E pattern).

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC5-E2E-01a | The REAL, unmodified `autonomous-dev.sh` driven against a fixture `gh` (token-mode auth stub + a minimal normalized `gh issue view`/comments response) and a fixture `claude` (drops a marker on launch, then sleeps) | the wrapper reaches the real agent spawn (fixture claude launches) |
| TC-LGC5-E2E-01b | The run's lane registry directory | minted under the isolated `ADT_STATE_ROOT` |
| TC-LGC5-E2E-01c | The guardian sidecar | confirmed installed and alive BEFORE the SIGKILL |
| TC-LGC5-E2E-01d | The ENTIRE wrapper session is SIGKILLed (`kill -9 -- -<session>`) — the non-graceful death class no in-process trap survives | the fixture agent process is gone within grace(10s)+2s |
| TC-LGC5-E2E-01e | Lane STATE after the SIGKILL | promoted to `reaped-by-guardian` — proving the GUARDIAN, not an incidental OS reap, performed the observable teardown |
