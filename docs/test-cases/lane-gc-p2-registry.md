# Test Cases — Lane-GC PR-2: lane identity & registry (#378)

Second PR of the Lane-GC series (design: `docs/designs/lane-containment-gc.md`
§4-C1/§4-C2, §9 PR-2; INV-109/INV-110 — renumbered from the design's drafted
INV-107/INV-108 after a rebase collision with #375's shipped INV-108).
Introduces the lane identity + registry layer:

1. **New `skills/autonomous-dispatcher/scripts/lib-lane.sh`** — `lane_mint`,
   `lane_install`, `lane_spawn` (pgid backend only), `lane_record_pgid`,
   `lane_kill`, `lane_probe`, `lane_get`/`lane_set`/`lane_set_state`,
   `lane_find_latest`, `lane_dir`; portability shims `proc_age`,
   `proc_start_time`, `env_of`, `file_mtime`, `box_health`.
2. **Atomic mint**: `lanes/.pending-<id_fs>/` fully populated, then `mv -T`
   (falling back to plain `mv`) to `lanes/<id_fs>/`.
3. **State root**: `ADT_STATE_ROOT` canonicalized to `$HOME/.local/state`
   (or an explicit override), `XDG_STATE_HOME` deliberately ignored.
4. **Universal tagging**: both wrappers `export ADT_LANE_ID`/`ADT_LANE_DIR`
   before the `GH_AUTH_MODE` branch (which spawns the token daemon) and
   before `install_agent_heartbeat`. Sub-lanes (review fan-out, smoke, E2E)
   add `ADT_LANE_ROLE`. The browser E2E lane scopes `TMPDIR` under the lane
   dir and records `CHROME_PROFILE_HINT`.
5. **PGID appends**: `_run_with_timeout` (the one chokepoint every CLI
   adapter funnels through) appends to `lanes/<id>/pgids`; the E2E
   command-mode lane appends directly (it bypasses `_run_with_timeout`).
6. `STATE=cleaning`/`clean-exit` transitions wired into both wrappers'
   `cleanup()`.
7. `kill_stale_wrapper` prefers `lane_kill` when a parseable, currently-dead
   lane exists; falls through to its pre-existing behavior otherwise.

Test runner: `bash tests/unit/test-lib-lane.sh` (auto-discovered by the CI
`hermetic-unit` job's `tests/unit/test-*.sh` glob). Run the full suite under
`env -u PROJECT_DIR` for CI parity.

## Atomic mint / registry existence (AC1, AC2)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC2-001 | `lane_install` called normally | returns the final lane dir path; `lane/pgids/reap.lock` all present; `lane` file parses with `lane_get` for every KV key |
| TC-LGC2-002 | Atomic-mint stress: SIGKILL a subshell running `lane_install` mid-flight, × 50 iterations | zero iterations observe a `lanes/<id>/` dir under its FINAL name missing `WRAPPER_PID`/`WRAPPER_START`/`CREATED_EPOCH`/`STATE` — either fully absent, or `.pending-*` only, or fully populated |
| TC-LGC2-003 | Registry existence before ANY spawn (dev wrapper) | after the mint block runs (before the `GH_AUTH_MODE` branch), `ADT_LANE_DIR/lane` exists and is parseable |
| TC-LGC2-004 | Registry existence before ANY spawn (review wrapper) | same as TC-LGC2-003, mirrored for `autonomous-review.sh` |
| TC-LGC2-005 | `lane_install` failure (e.g. unwritable `ADT_STATE_ROOT`) | returns empty + rc 1; caller's `ADT_LANE_DIR` stays empty; wrapper proceeds without a registry entry (no abort) |

## State root canonicalization (AC3)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC2-010 | `XDG_STATE_HOME` set to a different path than `$HOME/.local/state`, `ADT_STATE_ROOT` unset | `lib-lane.sh` resolves `ADT_STATE_ROOT="$HOME/.local/state"` — `XDG_STATE_HOME` is NOT consulted |
| TC-LGC2-011 | `ADT_STATE_ROOT` explicitly set by the caller | that value is used verbatim (operator override honored) |

## Universal tagging (AC4)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC2-020 | A test child process spawned after `export ADT_LANE_ID`/`ADT_LANE_DIR` in the calling shell | `/proc/<child-pid>/environ` contains both `ADT_LANE_ID=` and `ADT_LANE_DIR=` (verified via `tr '\0' '\n'` — the `env_of` shim's own read path) |
| TC-LGC2-021 | Dev wrapper source-of-truth: mint+export block appears BEFORE the `GH_AUTH_MODE` branch AND before the `--mode` arg-parse loop | grep-pin: line number of `export ADT_LANE_ID` < line number of `if [[ "$GH_AUTH_MODE" == "app" ]]` < line number of `install_agent_heartbeat` |
| TC-LGC2-022 | Review wrapper source-of-truth: same ordering | grep-pin mirrored for `autonomous-review.sh` |
| TC-LGC2-023 | Review fan-out subshell | exports `ADT_LANE_ROLE="fanout:<agent>"` alongside the pre-existing `ADT_FANOUT_LANE_MARKER` export (grep-pin: both exports in the same subshell block) |
| TC-LGC2-024 | Review smoke subshell (Phase A.5) | exports `ADT_LANE_ROLE="smoke:<agent>"` before its `_classify_smoke_state` call (grep-pin) |
| TC-LGC2-025 | Review browser-E2E lane subshell | exports `ADT_LANE_ROLE="e2e:browser"`, redirects `TMPDIR` under `${ADT_LANE_DIR}/tmp`, and records `CHROME_PROFILE_HINT` via `lane_set` (grep-pin for all three) |

## PGID append sites (AC5)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC2-030 | `_run_with_timeout` spawns a command with `ADT_LANE_DIR` set | the spawned PGID is appended as one line `<pgid> <role> <epoch>` to `${ADT_LANE_DIR}/pgids` |
| TC-LGC2-031 | `_run_with_timeout` spawns with `ADT_LANE_DIR` unset/empty | no error, no write attempted (silent no-op — `lane_record_pgid`'s own missing-dir guard) |
| TC-LGC2-032 | Fan-out-style scenario: PGID recorded into the durable lane dir, then the SIDECAR tmpdir (`_FANOUT_DIR`-equivalent) is `rm -rf`'d | the durable `pgids` file entry survives the sidecar removal — `lane_kill` still reaps the recorded PGID afterward |
| TC-LGC2-033 | E2E command-mode lane (`_run_command_e2e_verify`) | records its own PGID directly into `pgids` (bypasses `_run_with_timeout`) — grep-pin + behavioral (spawn a stub verify command, confirm the `pgids` line appears) |
| TC-LGC2-034 | Multiple concurrent appenders write to the same `pgids` file | no interleaved/partial lines — every line matches `^[0-9]+ \S+ [0-9]+$` (each append is < POSIX PIPE_BUF) |

## Liveness probe (AC: lane liveness = pid ∧ start-time match)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC2-040 | `lane_probe` against a lane whose `WRAPPER_PID` is the CALLING shell's own `$$` | `live` |
| TC-LGC2-041 | Recycled-PID fixture: same `WRAPPER_PID`, `WRAPPER_START` overwritten to a value that does not match the process's actual start time | `dead` (PID-recycle defense fires) |
| TC-LGC2-042 | `WRAPPER_PID` refers to a process that has exited | `dead` |
| TC-LGC2-043 | Lane file missing or unparseable (no `WRAPPER_PID` key) | `unknown` + rc 1 (fail toward "don't know", never a false `dead`/`live`) |
| TC-LGC2-044 | Non-Linux path (`_LANE_UNAME_OVERRIDE=Darwin` test seam): `WRAPPER_FINGERPRINT` populated at mint, matches at probe time | `live` |
| TC-LGC2-045 | Non-Linux path: `WRAPPER_FINGERPRINT` recorded but does NOT match at probe time (simulated PID-recycle with matching lstart-second) | `dead` — the fingerprint conjunct catches what lstart-only matching would miss |
| TC-LGC2-046 | **Regression (review-caught, pre-fix reproduced live):** the fingerprint recompute at probe time must use the RECORDED `WRAPPER_PPID`, never a live re-probe of the process's current ppid — `dispatch-local.sh` spawns the wrapper via `nohup … &` and exits almost immediately, reparenting the still-running wrapper to init within milliseconds of mint. Corrupt ONLY the recorded `WRAPPER_PPID` (leave everything else untouched) | probe flips from `live` to `dead` — proving the recompute reads the recorded field (which this edit changed), not a live re-probe (which this edit cannot affect) |

## `lane_kill` escalation

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC2-050 | `lane_kill` against a lane with one live `setsid`-grouped PGID recorded | TERM sent; process group gone within the grace window; function returns 0 |
| TC-LGC2-051 | `lane_kill` against a lane with a TERM-resistant (trapped) PGID | escalates to KILL after the grace window; group gone afterward |
| TC-LGC2-052 | `lane_kill` against a lane with multiple recorded PGIDs (fan-out-style) | every recorded PGID is signaled; duplicate lines for the same PGID are de-duplicated (signaled once) |
| TC-LGC2-053 | `lane_kill` against a lane with an empty/missing `pgids` file | clean no-op, rc 0 |

## `kill_stale_wrapper` delegate (AC7)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC2-060 | A parseable lane exists for `(project, dev, issue)`, probes `dead` | `lane_kill` is invoked on that lane's full pgid set BEFORE the legacy PID-file-only path runs |
| TC-LGC2-061 | A parseable lane exists but probes `live` | delegate does NOT touch it; legacy path proceeds unchanged (same-tick liveness is the legacy path's own concern) |
| TC-LGC2-062 | No lane exists for `(project, role, issue)` (pre-upgrade / never-minted) | delegate is a no-op; legacy PID-file-only path runs exactly as before (byte-identical to pre-#378 behavior) |
| TC-LGC2-063 | Lane file exists but is unparseable (corrupted/torn) | `lane_probe` returns `unknown`; delegate does NOT act on it; falls through to legacy path — a torn lane can never brick a re-dispatch |
| TC-LGC2-064 | `TYPE=review` maps to lane role `review`; `TYPE=dev-new`/`dev-resume` both map to role `dev` | `lane_find_latest` is called with the correct mapped role in each case |

## `lane_get`/`lane_set` KV round-trip (regression: sed-delimiter collision)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC2-070 | `lane_set` a value containing `/` (a filesystem path) | `lane_get` returns the value verbatim, not truncated/corrupted |
| TC-LGC2-071 | `lane_set` a value containing `&`, `[`, `]`, `*` | `lane_get` returns the value verbatim (awk literal-print, not sed substitution) |
| TC-LGC2-072 | `lane_set` a key not yet present in the `lane` file | key is appended; `lane_get` finds it |
| TC-LGC2-073 | Concurrent `lane_set` calls against the same lane file | `flock`-serialized — no lost update, no corrupted file (each writer's rewrite-then-mv is atomic) |
| TC-LGC2-074 | **Regression (review-caught, pre-fix reproduced live):** `lane_set` a value containing a LITERAL backslash-escape sequence (two chars, e.g. `\n`/`\t` — not an actual newline/tab byte) | `lane_get` returns the value byte-for-byte verbatim; the lane file's line count is unchanged (no bogus injected line from a collapsed escape) — passed via awk `ENVIRON[]`, never awk `-v` (which interprets C-style backslash escapes in the assignment text per POSIX) |

## E2E

No new E2E — all changes are wrapper-internal (lane mint/tag/PGID-record
plumbing). Full unit suite green plus the AC's live-probe requirement (a
real spawned test child's environ contains the lane tag — TC-LGC2-020) is
the acceptance surface for this PR.
