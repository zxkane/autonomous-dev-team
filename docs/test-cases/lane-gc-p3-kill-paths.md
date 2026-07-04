# Test Cases — Lane-GC PR-3: kill-path hardening (#379)

Third PR of the Lane-GC series (design: `docs/designs/lane-containment-gc.md`
§4-C4, §9 PR-3; INV-111/INV-112 — renumbered from the design's drafted
INV-106/INV-111 after the design-time head assumption (INV-105) went stale;
by this PR's open, INV-106..110 were already shipped by unrelated PRs, so
this PR claims the first free slot, INV-111, and its sibling INV-112). Every
pipeline kill path escalates TERM → bounded grace → KILL, gated on **group
emptiness** (never leader liveness), serialized under the per-lane
`reap.lock`:

1. Shared `_kill_group_escalate` helper in `lib-lane.sh`.
2. Wrapper TERM trap rewrite (`_agent_sigterm_handler`/
   `install_agent_sigterm_trap`, `lib-agent.sh`): iterates registry-recorded
   pgids (fixes the review-side dead arm where `_AGENT_RUN_PID` is empty in
   the main shell) + backgrounded escalator KILLs surviving groups after 5s.
3. `kill_stale_wrapper` group-gate fix (`dispatch-local.sh`, both the
   legacy PID-file path and the pgrep-fallback orphan sweep): escalation
   gate changes from leader `kill -0 $old_pid` to leader-OR-group via the
   new `_pid_or_group_alive` helper.
4. `cleanup()` (both wrappers): acquire `reap.lock` → `STATE=cleaning` →
   reap all recorded pgids FIRST (`lane_reap`) → FIFO handshake
   (feature-guarded no-op until PR-5) → PID/registry state updates →
   network work LAST, each call bounded via `_bounded_call`/`_teardown_call`
   (60s). Dev side gains its first-ever post-run reap; review gains the
   crash-path reap (the graceful fan-out reap, INV-104, is unchanged).
5. INV-26 attribution sentence: rc=137 following a pipeline-initiated TERM
   is self-induced, not a crash — extended to name every INV-114 kill path
   explicitly.
6. Grep-pin: `pkill -P $$` never widened to `-f <script-name>`.

Test runner: `bash tests/unit/test-lane-gc-p3-kill-paths.sh` (auto-discovered
by the CI `hermetic-unit` job's `tests/unit/test-*.sh` glob). Run the full
suite under `env -u PROJECT_DIR` for CI parity.

## `_kill_group_escalate` (AC1)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC3-001 | `_kill_group_escalate` against a live `setsid` group that honors TERM | group is gone at or before the grace bound; function returns 0 |
| TC-LGC3-002 | `_kill_group_escalate` against a `setsid` group that traps/ignores TERM | group survives the initial TERM, is still alive through the grace window, then is SIGKILLed; verified gone shortly after the grace bound elapses |
| TC-LGC3-003 | `_kill_group_escalate` against an already-dead pgid | initial TERM misses (ESRCH, swallowed); function returns 0 immediately, without waiting out the grace window |
| TC-LGC3-004 | `lane_kill` (refactored onto `_kill_group_escalate`) against N distinct recorded pgids, one TERM-trapping | ALL N pgids reaped; wall-clock stays ~grace regardless of N (concurrent backgrounded escalation, not serial) — regression guard for the PR-2 behavior `lane_kill` must keep bit-for-bit |

## Wrapper TERM trap iterates registry pgids (AC2, the review-side dead-arm fix)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC3-010 | SIGTERM delivered to a wrapper shell with `install_agent_sigterm_trap` installed, `ADT_LANE_DIR` exported, and TWO registry-recorded pgids: one `_AGENT_RUN_PID`-tracked `setsid sleep`, one review-fan-out-style `setsid` group with NO `_AGENT_RUN_PID` tracking and a TERM-ignoring member | BOTH groups are TERM'd immediately; the TERM-ignoring one is KILLed within its grace window; `RECEIVED_SIGTERM` is set to 1 |
| TC-LGC3-011 | Same as TC-LGC3-010 but `_AGENT_RUN_PID` is UNSET (the review wrapper's exact main-shell condition — the dead arm this PR fixes) | the registry-recorded pgid is STILL reached and reaped purely via the `${ADT_LANE_DIR}/pgids` read, proving the fix does not depend on `_AGENT_RUN_PID` at all |
| TC-LGC3-012 | Ordering regression guard: the direct-children `pkill -TERM -P $$` fallback must run BEFORE any `_kill_group_escalate … &` job is backgrounded | grep-pin on `lib-agent.sh`: the `pkill -TERM -P $$` line precedes the escalation loop's `& disown` lines in `_agent_sigterm_handler`'s source; behavioral proof: a TERM-trapping registry pgid is STILL correctly KILLed within grace (this is exactly the bug the wrong ordering caused — `pkill -P $$` killing the escalator subshell itself before its grace-then-KILL completes) |
| TC-LGC3-013 | `_kill_group_escalate` unavailable (lib-lane.sh not sourced) | `_agent_sigterm_handler` falls back to inline TERM + a single backgrounded grace-then-KILL sweep over the same pgid set — degrades, never silently drops the escalation |

## `kill_stale_wrapper` leader-OR-group gate (AC3)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC3-020 | `_pid_or_group_alive <pid>` where the pid itself answers `kill -0` | returns 0 (true) via the leader check alone |
| TC-LGC3-021 | `_pid_or_group_alive <pid>` where the leader is dead but a group member (same pgid) is alive | returns 0 (true) via the group-form check |
| TC-LGC3-022 | `_pid_or_group_alive <pid>` where neither the leader nor any group member is alive | returns 1 (false) |
| TC-LGC3-023a | Fixture self-proof: the 023/024 fixture tree (leader `exec sleep` + a persistent `(trap "" TERM; while :; do sleep 1; done)` member in the same pgid) receives a PLAIN group TERM — what the pre-fix leader-only gate effectively ended at | leader dies, the trapping member SURVIVES (`LEADER-DEAD-MEMBER-ALIVE`) — proving the fixture reproduces the leak shape, so 023/024 cannot pass vacuously (review-caught: an earlier fixture's `trap "" TERM &` child exited immediately and left nothing to leak) |
| TC-LGC3-023 | `kill_stale_wrapper`, legacy PID-file path: old_pid's leader dies right after the initial TERM, but a TERM-trapping member of its group survives | the escalation gate fires (leader-or-group still reports alive) and the group member is SIGKILLed — regression proof for the pre-fix bug (leader-only gate would have skipped SIGKILL and left the member running); verified to FAIL against origin/main's kill_stale_wrapper (`GROUP-ALIVE`) |
| TC-LGC3-024 | `kill_stale_wrapper`, pgrep-fallback orphan sweep (no PID file): an orphan tree whose cmdline matches the sweep's project+type+issue anchors; the leader dies after the sweep's initial TERM, the trapping member survives | same leader-or-group gate fires in the fallback loop; member is SIGKILLed; verified to FAIL against origin/main's fallback loop (`GROUP-ALIVE`) |
| TC-LGC3-025 | Existing behavior preserved: leader alive → normal TERM→grace→KILL sequence unchanged; leader AND group both dead → no spurious SIGKILL attempt | `test-kill-before-spawn.sh` / `test-dispatch-local-pgrep-type-scope.sh` / `test-pid-guard-pgid.sh` / `test-pid-alive-long-running.sh` stay green (extraction snippets updated to capture the new sibling helper) |

## `cleanup()` reap-first ordering + bounded network calls (AC4)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC3-030 | `lane_reap` against a lane with a live recorded pgid | `STATE` transitions `live`→`reaping`→`cleaning`; the pgid is TERM/KILLed within grace; function is a clean no-op on a missing lane dir |
| TC-LGC3-031 | Grep-pin: in BOTH `autonomous-dev.sh` and `autonomous-review.sh`, `cleanup()`'s `lane_reap` call appears BEFORE the first PID-file removal AND before the first network-work call site (`itp_post_comment`/`itp_transition_state`/`chp_pr_list`/`drain_agent_pr_create`/`drain_agent_bot_triggers`/`get_gh_app_token`/`emit_verdict_trailer`) | line-number ordering assertion holds in both files |
| TC-LGC3-032 | `_bounded_call` against a fast bash FUNCTION (not an external binary) | stdout and stderr each preserved exactly on their own stream, exit code preserved, faster than the bound |
| TC-LGC3-032d | `_bounded_call` wrapping a function that writes a benign line to stderr before its real stdout value, invoked with the CALLER's own `2>/dev/null` on the `_bounded_call` call itself | the caller's `2>/dev/null` still drops the wrapped function's stderr — dual-tmpfile capture never merges the two streams (regression: an earlier draft merged them into one file and silently defeated every caller's own redirection) |
| TC-LGC3-033 | `_bounded_call` against a hanging bash function, bound=2s | terminated at (or just after) the bound; returns 124; partial output captured up to termination is still returned |
| TC-LGC3-033d | `_bounded_call` wrapping a function that itself forks a GRANDCHILD via command substitution (`out=$(sleep 20)` — the shape of `get_gh_app_token`'s HTTP calls), bound=2s | the grandchild is gone after escalation — `set -m` (job control) gives the backgrounded call its own process group, and a group-form kill on escalation reaches it (regression: an earlier draft used a plain non-group kill on the direct child only, which never reached the grandchild; a `setsid`+`export -f`+nested-`bash -c` draft was ALSO rejected because `export -f` only exports the one named function, breaking every real call site's internal function calls) |
| TC-LGC3-033e | `_bounded_call` called BARE (no `\|\|`/`if`/`$(...)` guard) under `set -euo pipefail`, wrapping a function that returns non-zero | the wrapped function's exit code propagates as `_bounded_call`'s own return — does NOT abort the calling shell mid-`wait` (regression: `wait "$cpid"` without `\|\| rc=$?` aborts the CALLER at that line under `set -e` whenever the wrapped call's exit is non-zero, before `return "$rc"` ever runs) |
| TC-LGC3-034 | Regression proof that coreutils `timeout` cannot be used directly on a wrapper's own bash functions (documents WHY `_bounded_call` backgrounds+polls instead of delegating to `timeout`) | `timeout <n> <bash-function-name>` fails with rc 127 / "No such file or directory" — confirms the design choice, not a behavior this PR ships |
| TC-LGC3-035 | `cleanup()` with every network-call site replaced by a hung stub function (simulating a wedged `gh`) | `cleanup()` completes in well under 90s (bounded by grace + N×60s, N = number of distinct network call sites hit on that exit path) AND still performs its label-flip / STATE=clean-exit transition |
| TC-LGC3-036 | Concurrent `lane_kill`/`lane_reap` invocations contending on the same lane's `reap.lock` | serialized (one waits for the other via `flock`); the target pgid is KILLed exactly once — no double-KILL race, verified via a side-effect counter fixture (not `strace`) |
| TC-LGC3-037 | Review side: `lane_reap` in `cleanup()` fires on a SIGTERM-mid-fan-out crash (before the graceful `_reap_fanout_processes`/`_reap_fanout_recorded_descendants` call in the main body ever runs) | every fan-out/E2E/smoke PGID recorded in the registry (regardless of which subshell spawned it) is reaped by the `cleanup()` EXIT-trap path alone |
| TC-LGC3-038 | Idempotency: the graceful fan-out reap (INV-104) already reaped a pgid before `cleanup()`'s `lane_reap` runs | `lane_reap`/`lane_kill` treat the already-dead pgid as a clean no-op — no error, no spurious second kill |

## INV-26 attribution + grep-pins (AC5, AC6)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC3-040 | `count_agent_failures` given a Session Report with `Exit code: 137` immediately following a pipeline-initiated TERM (any of the three INV-111 paths) | excluded from the failure tally, same as the pre-existing 143/0 exclusions — regression-safe extension, not a behavior change to the jq predicate itself (137 was already excluded pre-PR-3; this PR's contribution is the DOC sentence tying that exclusion explicitly to every INV-111 kill path, not a code change to the predicate) |
| TC-LGC3-041 | Grep-pin across every kill site this PR touches (`lib-lane.sh::_kill_group_escalate`/`lane_kill`, `lib-agent.sh::_agent_sigterm_handler`, `dispatch-local.sh::kill_stale_wrapper` both sites) | TERM (`kill -TERM`) textually precedes KILL (`kill -KILL`/`kill -9`) in every function body |
| TC-LGC3-042 | Grep-pin, repo-wide | zero occurrences of `pkill -f 'autonomous-'` (or any `-f`-based wrapper-script-name match) anywhere — the widening the design explicitly forbids (would cross-kill sibling lanes) |

## Acceptance Criteria mapping

- [ ] All unit tests above pass (surface: CI unit job) — TC-LGC3-001..042
- [ ] Fixture-tree E2E: `kill_stale_wrapper` against a fixture tree with a
      TERM-trapping member → tree empty within grace+2s (surface: CI unit
      job — this repo's CI has no separate E2E workflow, so the unit job IS
      the CI surface for this criterion. TC-LGC3-023 drives the REAL
      `kill_stale_wrapper` end-to-end against a real process tree — leader
      dies on TERM, a persistent TERM-trapping member survives in its group
      — through the PID-file path; TC-LGC3-024 drives the same shape through
      the pgrep-fallback orphan sweep (no PID file); TC-LGC3-023a is the
      fixture self-proof that this exact tree LEAKS under a plain group TERM,
      i.e. under the pre-fix leader-only gate — so 023/024 fail against
      pre-fix code rather than passing vacuously)
- [ ] `invariants.md` updated (INV-111 + INV-112 + the INV-26 attribution
      sentence), numbering re-verified against HEAD at PR-open, with triage
      markers; `state-machine.md`/flow docs updated same PR (surface: PR
      diff)
- [ ] Full suite green (surface: CI)
