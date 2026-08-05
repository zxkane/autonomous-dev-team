# Test Cases — Lane-GC PR-7: systemd `--user` scope backend (#383)

Seventh PR of the Lane-GC series (design: `docs/designs/lane-containment-gc.md`
§4-C1 `_lane_backend`, §4-C7; INV-120 — see
`docs/designs/lane-gc-p7-scope.md` for the numbering re-verification). A
Linux-only, feature-detected, linger-gated enhancement: enroll lanes in
`systemd-run --user --scope` units whose cgroup membership survives
re-setsid — the only mechanism in this series that structurally defeats
group-escape (RC3) rather than merely detecting it after the fact. **Never
load-bearing**: the portable pgid backend (PR-2..PR-5) remains fully
sufficient alone; any missing prerequisite is a silent, complete fallback.

1. **`skills/autonomous-dispatcher/scripts/lib-lane.sh`**: `_lane_backend()`
   (the probe — Linux ∧ `systemd-run` ∧ `Linger=yes` at selection time ∧
   reachable bus ∧ a real probe spawn succeeds), `_lane_unit_name()`,
   `_lane_cgroup_path()`/`_lane_cgroup_empty()` (cgroupfs helpers),
   `_lane_scope_kill()` (the TERM → poll → `cgroup.kill` fast path);
   `lane_install()` records the probed `BACKEND`/`UNIT` instead of the
   PR-2-era hardcoded `BACKEND=pgid`/`UNIT=-`; `lane_spawn()` dispatches on
   the lane's own recorded backend; best-effort `lane_kill()` calls the scope
   fast path BEFORE its existing pgid escalation (defense in depth — the pgid
   escalation always also runs). P8's delayed-GC `require-identity` policy is
   the explicit exception and refuses scope pending #522.
2. **`skills/autonomous-dispatcher/scripts/lib-guardian.sh`**: `do_reap()`
   gains the identical `_lane_scope_kill()` call in the identical position.
3. **`skills/autonomous-dispatcher/scripts/adt-gc.sh`**: `--doctor` gains a
   bus-socket-reachability check and a `backend_eligibility=` summary line.
   P7 originally let rule 1.3 inherit the scope path; P8 now refuses that
   delayed strict path until #522 proves full-wrapper enrollment.

Test runner: `bash tests/unit/test-lane-gc-p7-scope.sh` (auto-discovered by
the CI `hermetic-unit` job's `tests/unit/test-*.sh` glob). No new E2E job —
see `docs/designs/lane-gc-p7-scope.md`'s CI-feasibility section for why
(GitHub-hosted `ubuntu-latest` runners have no linger/user-bus by default;
deferred to a follow-up). The production host is already `Linger=yes`, but
the current no-user probe returns empty and falls back to PGID. P8 leaves
that probe unchanged and makes its explicit-user correction plus the
full-wrapper E2E hard prerequisites for scope enablement; it does not claim
this deferred coverage passed.

**Test-class legend** used throughout this doc:
- **REAL** — runs against this box's actual `systemd-run`/`loginctl`/
  `systemctl`, no shim, and skips explicitly when the host does not satisfy
  the scenario's prerequisite. Proves genuine behavior, not merely argv shape.
- **SHIM** — a PATH-prepended fixture script replaces `systemd-run`/
  `systemctl`/`loginctl` to force/observe a specific branch. Proves
  selection logic and kill-path command construction ONLY — see the
  "Honest-scope note" in the design doc for exactly what a shim cannot
  prove.

## Backend selection — REAL refusal when the host is Linger=no (design AC:
"linger=no host: backend probe refuses systemd-scope with WARN,
`BACKEND=pgid` recorded, wrapper spawns fine")

| ID | Scenario | Expected | Class |
|----|----------|----------|-------|
| TC-LGC7-001 | `_lane_backend()` called directly on this suite's real host (no override) | on an explicit-user `Linger!=yes` host, echoes `pgid`; otherwise SKIP with the actual value | REAL, conditional |
| TC-LGC7-002 | Same call, stderr captured | on an explicit-user `Linger!=yes` host, one `[lib-lane] WARN:` line names linger; otherwise SKIP | REAL, conditional |
| TC-LGC7-003 | `lane_install` with no override on this host | on an explicit-user `Linger!=yes` host, lane file has `BACKEND=pgid`, `UNIT=-`; otherwise SKIP | REAL, conditional |
| TC-LGC7-004 | force `BACKEND=pgid`, then run `lane_spawn`+`lane_kill` | wrapper spawns and is killed exactly as pre-PR-7, independent of host linger state | REAL |

## Backend selection — per-prerequisite isolation (design AC: "probe-failure
host falls back to pgid backend with `BACKEND=pgid` recorded")

| ID | Scenario | Expected | Class |
|----|----------|----------|-------|
| TC-LGC7-010 | `systemd-run` absent from a GENUINELY curated `PATH` (every real binary symlinked EXCEPT `systemd-run` — a decoy dir merely PREPENDED to the ambient `$PATH` is insufficient on a host where `/bin` -> `/usr/bin`, since `command -v` still finds the real binary later in the search) | `pgid`, WARN names `systemd-run` | SHIM |
| TC-LGC7-011 | `loginctl` shim returns `no` for Linger | `pgid`, WARN names linger/`enable-linger` | SHIM |
| TC-LGC7-012 | No bus socket at the probed `XDG_RUNTIME_DIR/bus` path (point at an empty tmpdir) | `pgid`, WARN names the bus socket path | SHIM |
| TC-LGC7-013 | `loginctl` shim returns `yes` AND a real bus socket exists, but the `systemd-run --scope --quiet -- true` probe shim exits non-zero | `pgid`, WARN names the probe spawn | SHIM |
| TC-LGC7-014 | All four prerequisites shimmed to succeed | `systemd-scope` (proves the positive path is reachable via shims, not just the negative ones) | SHIM |

## Override semantics — narrow only, never widen (review round-1 P1-1 fix;
design principle 8 — the pgid path must remain sufficient, an inherited env
var must never enroll scopes past the real linger gate)

| ID | Scenario | Expected | Class |
|----|----------|----------|-------|
| TC-LGC7-080 | `ADT_LANE_BACKEND_OVERRIDE=systemd-scope` on a real explicit-user `Linger!=yes` host | still `pgid`; on `Linger=yes`, SKIP and rely on TC-LGC7-011 for the refusal branch | REAL, conditional |
| TC-LGC7-080c | `ADT_LANE_BACKEND_OVERRIDE=pgid` | unconditionally `pgid`, no checks run at all (the only direction the override may safely force) | REAL |

## Unit naming (design AC: "unit-name collision test (two lanes, same
second) passes via rand4"; review round-1 P2-2/P3: sanitization + length cap
+ the FIXED test now derives from a REAL `lane_mint`/`_lane_unit_name` call
instead of a hand-picked literal)

| ID | Scenario | Expected | Class |
|----|----------|----------|-------|
| TC-LGC7-020 | Two `lane_mint` calls for the same (project, role, issue) forced into the same wall-clock second (stubbed `date`, or a tight loop asserting distinctness across many real calls) | the two `_lane_unit_name()` outputs are non-identical strings (rand4 differs) | REAL |
| TC-LGC7-021 | `_lane_unit_name` output shape | matches `^adt-[^:]+$` (colons already replaced by `_lane_id_fs`) | REAL |
| TC-LGC7-021c | The ACTUAL unit name computed by TC-LGC7-020 (not a hand-picked literal) is handed to a REAL `systemd-run --unit` | accepted (rc 0) | REAL |
| TC-LGC7-022 | A 300-char, `@`/`/`-bearing `PROJECT_ID` fed through `lane_mint` -> `_lane_unit_name` | output is <= 249 chars (255-byte systemd cap minus the 6-byte `.scope` suffix, probed live: 249 raw chars accepted, 250 rejected) | REAL |
| TC-LGC7-022b | The sanitized long/bad-char unit name handed to a REAL `systemd-run --unit` | accepted (rc 0); absent a real systemd-run, shape-asserted against systemd's own safe alphabet `[A-Za-z0-9:_.-]` instead | REAL (or shape-only) |

## Registration-failure fallback (review round-1 P2-2 fix — a `systemd-run`
registration failure must never mean the payload silently never ran)

| ID | Scenario | Expected | Class |
|----|----------|----------|-------|
| TC-LGC7-023 | `lane_spawn` with a PATH-shimmed `systemd-run` that emits its registration-failure diagnostic and exits before payload exec | the payload (a marker-file `touch`) STILL RUNS, via the pgid fallback | SHIM |
| TC-LGC7-023b | Same | `lane_spawn`'s own reported rc is the FALLBACK payload's real exit code, never a leaked internal sentinel | SHIM |
| TC-LGC7-023c | Same, stderr captured | a WARN names the registration failure and the fallback | SHIM |
| TC-LGC7-024 | Same scenario, payload increments a counter file | counter is exactly `1` — the fallback runs the payload EXACTLY ONCE, never twice | SHIM |
| TC-LGC7-025 | A GENUINE payload failure (valid unit, payload itself `exit 9`) | counter is exactly `1` (no spurious fallback/double-run) AND `lane_spawn`'s rc is exactly `9` (the real payload exit code, unchanged) | REAL |

## Bounded systemd/loginctl calls (review round-1 P1-2/P2-1 fix — no call
this PR adds may hang a load-bearing path indefinitely)

| ID | Scenario | Expected | Class |
|----|----------|----------|-------|
| TC-LGC7-026 | `_lane_backend()` with `loginctl` PATH-shimmed to `sleep 60` | still returns `pgid` (the linger check failed via TIMEOUT, treated identically to any other probe failure) | SHIM (wedge) |
| TC-LGC7-026b | Same, wall-clock measured | returns within ~5s, NOT 60s — proven to genuinely regress (FAIL) when the bounding fix is reverted, confirming this is a real regression test, not cosmetic | SHIM (wedge) |
| TC-LGC7-027 | `_lane_scope_kill()` with `systemctl` PATH-shimmed to `sleep 60` | still returns rc 0 (degrades silently, same posture as every other prerequisite failure) | SHIM (wedge) |
| TC-LGC7-027b | Same, wall-clock measured | returns within ~20s (the TERM-kill bound + the ControlGroup-show bound, both 10s each), NOT 60s — `lane_kill`'s `reap.lock` is never held indefinitely by a wedged bus | SHIM (wedge) |

## Scope spawn argv shape (design AC: "TasksMax visible in `systemctl --user
show`")

| ID | Scenario | Expected | Class |
|----|----------|----------|-------|
| TC-LGC7-030 | `lane_spawn` on a lane whose file was directly `lane_set` to `BACKEND=systemd-scope` post-install (never via `ADT_LANE_BACKEND_OVERRIDE` — see the override-semantics section above for why), `systemd-run` PATH-shimmed to record its argv | argv contains `--scope`, `--collect`, `--quiet`, `--unit <name>`, `-p TasksMax=512` (default), and `-- setsid` immediately precedes the wrapped command — ordering asserted, not just presence | SHIM |
| TC-LGC7-031 | Same, with `LANE_MEMORY_MAX=2G` exported | argv additionally contains `-p MemoryMax=2G` | SHIM |
| TC-LGC7-032 | Same, `LANE_MEMORY_MAX` unset (default) | argv contains NO `MemoryMax` flag at all (not merely an empty value) | SHIM |
| TC-LGC7-033 | REAL (no shim): `lane_spawn` a scope lane with `LANE_TASKS_MAX=64`, then `systemctl --user show -p TasksMax --value <unit>.scope` | reports `64` | REAL |

## Reap fast path — REAL cgroup semantics (design AC: "on a linger-enabled
host: `setsid`-escaping child inside a scope is reaped by `lane_kill`" —
here proven via the override seam rather than a real linger flip, since
enabling linger durably changes host state a test suite must not touch)

| ID | Scenario | Expected | Class |
|----|----------|----------|-------|
| TC-LGC7-040 | `lane_spawn` (via override) a payload that immediately `setsid`s a grandchild that sleeps; `lane_kill` the lane | the setsid-escaped grandchild (verified via `ps -o sid` to have a DIFFERENT session than the scope leader before the kill) is gone afterward — proves cgroup membership, not pgid membership, is what caught it | REAL |
| TC-LGC7-041 | Same, but assert via the cgroup's OWN `cgroup.procs` mid-kill (best-effort timing window) | the escapee is listed in `cgroup.procs` BEFORE the kill (proves it truly escaped the pgid) | REAL |
| TC-LGC7-042 | `_lane_cgroup_empty()` unit test against a real cgroup dir with a live member pid inside it | returns false (non-empty) — the `[[ -s ]]`-footgun regression pin: `stat`-size is 0 even though a pid is listed | REAL |
| TC-LGC7-043 | `systemctl --user kill -s TERM <unit>` (bare, no `.scope` suffix) vs `<unit>.scope` | bare form fails (`Unit <name>.service not loaded`); suffixed form succeeds — regression pin for the suffix-required finding | REAL |
| TC-LGC7-044 | `_lane_scope_kill` on a lane whose `BACKEND=pgid` | no-op (never calls `systemctl`) — the "silent no-op unless this lane's OWN recorded backend is scope" contract | REAL |
| TC-LGC7-045 | `_lane_scope_kill` on a lane whose `BACKEND=systemd-scope` but whose `UNIT` was never actually created (unit not loaded) | no-op, no error propagated to the caller | REAL |

## Kill-path argv shape (SHIM companion to TC-LGC7-040..045 — proves the
COMMANDS `_lane_scope_kill` builds, independent of real kernel semantics)

| ID | Scenario | Expected | Class |
|----|----------|----------|-------|
| TC-LGC7-050 | `_lane_scope_kill` on a scope-backend lane, `systemctl` PATH-shimmed to record argv | first call is `kill -s TERM <unit>.scope`; a later call is `show -p ControlGroup --value <unit>.scope` | SHIM |
| TC-LGC7-051 | Shimmed `systemctl show` returns a `ControlGroup` value pointing at a REAL (fixture-created) cgroup-shaped directory tree with a `cgroup.kill` file | `_lane_scope_kill` writes `1` to that file after the poll window elapses with the fixture "non-empty" | SHIM+REAL-fs |
| TC-LGC7-052 | Same, but the fixture directory has NO `cgroup.kill` file (pre-5.14 simulation) | falls back to reading `cgroup.procs` and issuing per-pid `kill -KILL`, never errors | SHIM+REAL-fs |

## Defense in depth (design point 4 — "the pgid escalation ALWAYS also runs
afterward regardless of what the scope path did or didn't reap")

| ID | Scenario | Expected | Class |
|----|----------|----------|-------|
| TC-LGC7-060 | `lane_kill` on a scope-backend lane where `_lane_scope_kill` no-ops (TC-LGC7-045's setup) but a REAL pgid IS recorded in `pgids` | the recorded pgid is still TERM'd/escalated — the pgid path is not skipped just because the backend is `systemd-scope` | REAL |
| TC-LGC7-061 | Source grep-pin | `lane_kill`'s call to `_lane_scope_kill` appears BEFORE the pgid `seen[]` escalation loop in the function body | grep-pin |

## Guardian integration (`do_reap` gains the same fast path)

| ID | Scenario | Expected | Class |
|----|----------|----------|-------|
| TC-LGC7-070 | Source grep-pin: `lib-guardian.sh`'s `do_reap` | calls `_lane_scope_kill` BEFORE its pgid `seen[]` escalation loop, same ordering as `lane_kill` | grep-pin |
| TC-LGC7-071 | `systemctl`/`systemd-run` PATH-shimmed, guardian `do_reap` invoked directly against a scope-backend lane fixture | the shim records the same `kill -s TERM <unit>.scope` call `lane_kill`'s own path makes | SHIM |

## Lane-file recording (both branches)

| ID | Scenario | Expected | Class |
|----|----------|----------|-------|
| TC-LGC7-080 | `lane_install` requests `ADT_LANE_BACKEND_OVERRIDE=systemd-scope` on a real explicit-user `Linger!=yes` host | lane file remains `BACKEND=pgid`, `UNIT=-`; `Linger=yes` hosts SKIP this refusal scenario | REAL, conditional |
| TC-LGC7-081 | `lane_install` with no override on a real explicit-user `Linger!=yes` host | lane file: `BACKEND=pgid`, `UNIT=-`; `Linger=yes` hosts SKIP | REAL, conditional |

## Regression pin — pgid path fully unaffected (design's own acceptance
gate: "pgid path byte-equivalent when backend=pgid — existing tests must
stay green unmodified")

| ID | Scenario | Expected | Class |
|----|----------|----------|-------|
| TC-LGC7-090 | Full `lane_spawn` → `lane_record_pgid` → `lane_kill` roundtrip on a real `pgid`-backend lane, comparing against the PRE-PR-7 code path's observable behavior (spawned pid escalates TERM→KILL, `pgids` file content unchanged in shape) | byte-identical outcome; no `systemctl`/`systemd-run` call is EVER made for a pgid-backend lane (asserted via a shim that FAILS the test if invoked) | REAL+SHIM-tripwire |
| TC-LGC7-091 | Full neighbor-suite gauntlet (see PR checklist) | all pre-existing Lane-GC unit/E2E suites remain green, run twice consecutively | external, see PR notes |

## Mixed fleet GC (design AC: "Mixed fleet: scope-lane and pgid-lane
reaped correctly by the same GC pass")

| ID | Scenario | Expected | Class |
|----|----------|----------|-------|
| TC-LGC7-100 | Two dead lanes under one `ADT_STATE_ROOT`: one real pgid lane, one lane whose file claims `BACKEND=systemd-scope` but whose `UNIT` was never actually created (degraded/mixed fleet) | best-effort direct `lane_kill` reaps BOTH with no error — the scope path degrades silently to pgid-only reaping for the second lane; P8's later strict-GC refusal is covered by TC-LGC8-018 | REAL |

## Honest-scope note (repeated from the design doc, load-bearing enough to
restate here)

SHIM-class tests prove selection logic and kill-path **command
construction** — they cannot and do not prove real cgroup/kernel semantics.
Those are proven instead by the REAL-class tests above (TC-LGC7-040..045),
which exercise the `lane_spawn` primitive against a real systemd/kernel. They
do **not** prove full-wrapper enrollment: the production agent chokepoint
`_run_with_timeout` still starts the agent through plain `setsid` rather than
calling `lane_spawn`. The production host is already `Linger=yes`; the
current no-user probe returns empty and happens to keep it on PGID. P8 does
not treat that as proof of correct scope gating. Full-wrapper scope enablement
remains gated on the explicit-user probe correction and follow-up E2E in
`docs/designs/lane-gc-p8-enforcement.md`. A host where the real primitive
cannot run SKIPs the REAL-class tests with an explicit `SKIP (reason: ...)`
line — never a silent pass, and never a fabricated result.
