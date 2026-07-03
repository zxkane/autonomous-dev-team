# Test Cases — Lane-GC PR-1: source hygiene (#377)

First PR of the Lane-GC series (design: `docs/designs/lane-containment-gc.md`
§4-C8, §9 PR-1). Source-hygiene fixes for the two orphan classes RC5 identifies
plus the RC6 live-lane CPU-burner fix:

1. `gh-token-refresh-daemon.sh` — 60s-chunked, PPID-checked sleep replacing the
   monolithic `sleep $REFRESH_INTERVAL`; TERM/INT trap reaping the in-flight
   sleep child; GH token values scrubbed from the daemon's spawned env.
2. `tests/unit/test-token-split-234.sh` stub daemon fixture — PPID watchdog
   replacing `sleep 99999`; harness EXIT trap backstop.
3. `skills/autonomous-common/hooks/lib.sh` — new `read_hook_stdin` helper
   replacing `input=$(cat)` with a `read -t 5 -d ''` bounded read (bash
   builtin — no external `timeout` dependency, no degraded fallback path)
   across all 12 hooks that read stdin.

Test runner: `bash tests/unit/test-lane-gc-p1-source-hygiene.sh` (auto-discovered
by the CI `unit` job's `tests/unit/test-*.sh` glob), plus the pre-existing
`bash tests/unit/test-token-split-234.sh` (fixture regression coverage). Run the
full suite under `env -u PROJECT_DIR` for CI parity.

## Token daemon — chunked sleep + PPID trap (AC1, AC2)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC1-001 | SIGKILL the daemon mid-sleep (parent alive, `REFRESH_INTERVAL` > 60s) | the in-flight `sleep` child is NOT killed directly (SIGKILL doesn't propagate to children) but self-expires within ≤ 60 s of the daemon's death — never up to the full `REFRESH_INTERVAL` |
| TC-LGC1-002 | Send TERM to the daemon mid-sleep | the TERM/INT trap fires: the in-flight sleep child is killed immediately (not just self-expired) and the daemon exits promptly |
| TC-LGC1-003 | Daemon's real parent process dies (not the daemon itself) while daemon is mid-chunk-sleep | daemon's next `kill -0 "$PPID"` check (at most 60 s later) detects the dead parent, removes `TOKEN_FILE`, and exits 0 |
| TC-LGC1-004 | `REFRESH_INTERVAL=75` (above the pre-existing 60s-floor clamp, below the 120s two-chunk boundary) | first chunk is `sleep 60` (60s cap), not a single unclamped `sleep 75` |
| TC-LGC1-005 | `REFRESH_INTERVAL=180` (spans 3×60s chunks) | daemon's `kill -0 "$PPID"` liveness check is polled once per chunk, not once per 180 s — verified indirectly via TC-LGC1-001 (SIGKILL mid-chunk observes a `sleep <= 60` child, never `sleep 180`) |

## Token daemon — env scrub (AC4)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC1-010 | `setup_github_auth` (app mode) spawns the wrapper-token daemon with `GH_TOKEN`/`GITHUB_TOKEN`/`GITHUB_PERSONAL_ACCESS_TOKEN`/`GH_USER_PAT` set in the caller's env | daemon's own environ (`/proc/<pid>/environ`) contains NONE of those four keys |
| TC-LGC1-011 | `setup_agent_token` (app mode) spawns the SCOPED agent-token daemon under the same caller env (incl. `GITHUB_TOKEN`) | same scrub applies to the second daemon |
| TC-LGC1-012 | Scrubbed daemon still completes its mint + initial token write | `GH_TOKEN_FILE`/`AGENT_GH_TOKEN_FILE` polling succeeds — the scrub removes only env VALUES, the daemon needs no GH_TOKEN env var (it takes `app_id`/`pem_file` as argv and calls `get_gh_app_token` directly) |

## Fixture stub daemon — PPID watchdog + harness EXIT trap (AC2, AC3)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC1-020 | `new_auth_sandbox`'s stub `gh-token-refresh-daemon.sh` is started, then its PID is `kill`ed + `wait`ed (mirrors `cleanup_github_auth`) | the stub's own process exits; NO `sleep 99999` (or any) child process survives — post-run `pgrep -f "$TMPROOT"` finds nothing |
| TC-LGC1-021 | The stub daemon's real parent dies WITHOUT an explicit kill (e.g. the harness itself is interrupted) | the watchdog's `while kill -0 "$PPID"; do sleep 5; done` loop detects the dead parent within ≤ 5 s and exits — no orphan `sleep 99999` |
| TC-LGC1-022 | `test-token-split-234.sh`'s harness-level EXIT trap runs (`pkill -f "$TMPROOT"` before `rm -rf`) | any daemon/watchdog process still alive under `$TMPROOT` at harness exit is killed before the tmpdir is removed — a backstop independent of each test's own `cleanup_github_auth` call |
| TC-LGC1-023 | Full `test-token-split-234.sh` run (both app-mode blocks that spawn stub daemons) | `pgrep -f gh-token-refresh-daemon.sh` run against the test's own `$TMPROOT` immediately after suite completion finds zero matches |

## Git-hook stdin timeout (AC5)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC1-030 | `read_hook_stdin` called with stdin immediately EOF'd (empty pipe, closed write end) | returns immediately (well under the 5 s bound), empty string, no CPU spin |
| TC-LGC1-031 | `read_hook_stdin` called with stdin connected to a normal (possibly multi-line) JSON payload | payload is read through unchanged (`read -t -d ''` reads until EOF, same as the old `cat`) |
| TC-LGC1-032 | `read_hook_stdin` called with stdin open but silent (never closes, never sends data — the load-241 shape) | call returns within ≤ 6 s (the `read -t 5` bound + slack), NOT hung indefinitely, measured at 0% CPU while waiting (blocking read, not a spin) |
| TC-LGC1-033 | `timeout` binary entirely absent from `PATH` | `read_hook_stdin` still works correctly and still bounds the read — the guard is the bash builtin `read -t`, not the external `timeout` binary, so there is no feature-detection and no degraded fallback path that could reintroduce the CPU-spin bug |
| TC-LGC1-034 | grep-pin: all 12 hooks under `skills/autonomous-common/hooks/` that previously had `input=$(cat)` now call `input=$(read_hook_stdin)` | 0 remaining `input=$(cat)` occurrences; 12 `read_hook_stdin` call sites |
| TC-LGC1-035 | Each of the 12 hooks sources `lib.sh` BEFORE its `read_hook_stdin` call | source line number < call line number, for all 12 files |
| TC-LGC1-036 | Pre-existing hook behavior tests (`test-block-push-regex.sh`, `test-install-claude-hooks.sh`, `test-install-kiro-hooks.sh`, `test-is-git-command-quote-strip.sh`) | all still pass — the stdin-read change is a drop-in replacement with no observable behavior difference for well-formed input |

## Design doc (AC (checkbox 1))

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC1-040 | `docs/designs/lane-containment-gc.md` diffed against `docs/lane-gc-design-prework:docs/designs/lane-containment-gc.md` | byte-identical (`diff` exits 0) |

## E2E

No new E2E — all changes are wrapper-internal (daemon lifecycle, test fixture,
hook stdin handling). Full unit suite green is the acceptance surface (run
`for t in tests/unit/test-*.sh; do env -u PROJECT_DIR bash "$t" || exit 1; done`
per the CI `hermetic-unit` job, for CI parity).
