# Test Cases: codex re-run orphan containment (#406)

Three layers, layer 1 primary:

1. `adapters/codex.sh::_run_codex_review` — treat ANY signal-death rc (>= 128,
   covers 124/137/143) as loop-terminal, never a #209 transient blip.
2. `lib-review-poll.sh::_reap_fanout_controller_subshells` (new) +
   `autonomous-review.sh` — direct-PID reap of the fan-out controller subshells
   at the same post-resolution reap call site as the existing two reapers.
3. `adapters/codex.sh::_run_codex_review` (liveness gate) +
   `autonomous-review.sh` (rc-sidecar write guard) — a re-run iteration
   re-checks the wrapper's fan-out dir exists before every fresh launch, and
   the post-loop rc-sidecar write is guarded on the same dir existing.

All new unit tests live in `tests/unit/test-codex-rerun-orphan-containment.sh`,
plus regression additions to `tests/unit/test-lib-review-codex.sh` (the existing
`_run_codex_review` re-run harness). `tests/unit/test-reap-recorded-descendants.sh`
(the existing reap-call-site source-of-truth suite) is unchanged and stays green.

## Layer 1 — `_run_codex_review` treats rc >= 128 as terminal (PRIMARY fix)

Extends the existing `TC-CXRS-RUN-07*` timeout-veto suite in
`test-lib-review-codex.sh`.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-RUN-09 (regression, fails pre-fix) | first `codex review` invocation exits rc 143 (SIGTERM) | loop breaks immediately, rc 143 returned, exactly ONE invocation recorded (pre-fix: a second invocation fires because 143 fell through to the #209 transient-retry arm) |
| TC-CXRS-RUN-09b | rc 143 then (had the loop continued) a clean run | NO extra re-run — 1 run, rc 143 (mirrors RUN-07b for 124) |
| TC-CXRS-RUN-10 | a re-run that itself gets SIGTERM (rc 143) after an initial transient rc 1 | stops at the 143 (2 runs total), rc 143 |
| TC-CXRS-RUN-11 | rc 137 (SIGKILL) — pre-existing behavior | still 1 run, rc 137 (byte-identical to RUN-07c; proves the generalization to `rc >= 128` didn't regress the enumerated case) |
| TC-CXRS-RUN-12 | rc 124 (timeout) — pre-existing behavior | still 1 run, rc 124 (byte-identical to RUN-07; INV-48 veto unchanged) |
| TC-CXRS-RUN-13 | rc 1 (genuine transient, #209) | still re-runs (1 < 128) — RUN-02 unregressed |
| TC-CXRS-RUN-14 | INV-73 malformed-rc0 (rc 0, prompt-echo capture) | still re-runs — unaffected (0 < 128) |
| TC-CXRS-RUN-15 | rc 130 (SIGINT, 128+2) — an un-enumerated signal-death rc | ALSO terminal (proves the fix is a genuine `rc >= 128` generalization, not an enumerated allowlist of `{124,137,143}`) |
| TC-CXRS-RUN-16 | rc 2 with a clap-rejection capture (#223 config-error) | unaffected — still breaks on the rc-2 gate, not the rc>=128 gate (2 < 128) |

## Layer 2 — `_reap_fanout_controller_subshells` (new reaper)

New assertions in `tests/unit/test-codex-rerun-orphan-containment.sh`, mirroring the shape of `test-reap-recorded-descendants.sh`.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RFCS-001 | helper `_reap_fanout_controller_subshells()` is defined in `lib-review-poll.sh` | source-of-truth grep passes |
| TC-RFCS-002 | empty PID-arg list | clean no-op, no error |
| TC-RFCS-003 | non-numeric / already-dead PID args | skipped cleanly, no error |
| TC-RFCS-004 (regression) | a **fixture controller subshell** — a `( sleep 60 ) &` fork sharing the CALLING shell's process group (no `setsid`), mirroring the production fan-out subshell shape — survives naively after the existing `_reap_fanout_processes`/`_reap_fanout_recorded_descendants` calls (neither reaches it, pre-fix) | is reaped by `_reap_fanout_controller_subshells` within its TERM grace + KILL escalation |
| TC-RFCS-005 (the group-kill footgun guard) | after TC-RFCS-004's reap call, the TEST HARNESS'S OWN process (the "wrapper" stand-in whose pgid the fixture subshell shares) | is asserted STILL ALIVE — proves the reap used a direct `kill "$pid"`, never a group form `kill -- -$pid` (which would have killed the calling shell too) |
| TC-RFCS-006 | wrapper wiring: `autonomous-review.sh` calls `_reap_fanout_controller_subshells` at the post-resolution reap call site, fed `${_fanout_pids[@]:-}` | source-of-truth grep |
| TC-RFCS-007 | wrapper wiring: the call site does NOT `lane_record_pgid` these PIDs | source-of-truth (no `lane_record_pgid.*_fanout_pids` in the wrapper) |
| TC-RFCS-008 | existing `_reap_fanout_processes` / `_reap_fanout_recorded_descendants` call sites unchanged | source-of-truth (byte-identical substrings still present, mirrors TC-REAP-DESC-005's regression guard) |

## Layer 3a — fan-out-dir liveness gate (pre-launch)

Extends `test-lib-review-codex.sh`'s `_run_codex_review` harness with a 5th
(optional) arg.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-LIVE-01 | liveness dir deleted BETWEEN the first run and the scheduled re-run (first run rc 1, transient) | loop breaks with a log line naming the dir; NO second invocation |
| TC-CXRS-LIVE-02 | liveness dir present throughout | re-run proceeds normally (byte-identical to `TC-CXRS-RUN-02`) |
| TC-CXRS-LIVE-03 | liveness dir arg omitted (existing 4-arg call shape, e.g. every pre-#406 unit test call) | behavior byte-identical to today — the gate is a no-op (standalone-call safety) |
| TC-CXRS-LIVE-04 | liveness dir deleted mid-loop (present for run 1's re-run check, gone before run 2's) | breaks before the run-2 launch, 2 total runs |

## Layer 3b — rc-sidecar write guard

New assertions in `tests/unit/test-codex-rerun-orphan-containment.sh` plus a
source-of-truth grep on `autonomous-review.sh`.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RSG-001 | fan-out dir deleted before the per-agent subshell's rc-sidecar write | no write attempt is made, no stderr "No such file or directory" line |
| TC-RSG-002 | fan-out dir present | write proceeds exactly as before (byte-identical to pre-#406) |
| TC-RSG-003 | wrapper wiring: the sidecar `printf` is gated on `[[ -d "$_FANOUT_DIR" ]]` | source-of-truth grep |

## Missing-rc tolerance (existing contract, pinned here)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RSG-004 | a controller subshell is reaped (Layer 2) BEFORE it wrote its `.rc` sidecar | the wrapper's existing sidecar-missing branch (`AGENT_LAUNCH_RC["$_sid"]=1`, `autonomous-review.sh` around the `_rc_file` read) classifies it gracefully — no crash/hang; verdict resolution for OTHER agents is unaffected (this is pre-existing code, pinned as a regression guard, not new behavior) |

## E2E (existing wrapper dry-run harness)

Full review-wrapper dry run (fixture codex adapter writing a verdict artifact
mid-run, matching this repo's existing wrapper dry-run fixtures): 5s after
"Review complete" is logged, no process on the host carries THIS RUN's
fixture session-id/marker (`ADT_FANOUT_LANE_MARKER=<this run's session id>`) —
scoped to the fixture's own IDs (never a global process-name sweep, so
parallel CI jobs cannot flake each other); the log contains no rc-file "No
such file or directory" error line for this run.

## Acceptance-criteria cross-check (non-regression)

| Invariant | Must stay byte-identical |
|---|---|
| INV-48 timeout veto | rc 124/137 → `timed-out` (deciding FAIL) — `_classify_noverdict_agent` untouched |
| #209 transient re-run | rc 1 / other < 128 non-zero still re-runs |
| INV-73 malformed-rc0 | rc 0 + prompt-echo capture still re-runs |
| #223 config-error | rc 2 + clap capture still breaks on the rc-2 gate (checked before the rc>=128 gate; 2 never reaches it) |
