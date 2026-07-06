# Design: Lane-GC P7 — systemd `--user` scope backend

**Status:** Implementation notes for issue #383 (Lane-GC series PR-7). Full
design authority is `docs/designs/lane-containment-gc.md` §4-C1
(`_lane_backend`), §4-C7 (scope spawn + cgroup fast paths), §9 PR-7. This doc
records only the PR-open numbering re-verification, the concrete diff shape,
the empirical findings made while building this PR's own test suite, and the
CI-feasibility decision for a real scope E2E job — it is not a new design;
defer to the parent doc for rationale.

## Numbering re-verification (design §8/§10 F10 completeness)

The parent design drafted this PR's invariant as INV-113/INV-114 ("Linux
scope enrollment") and separately flagged "re-verify numbering at PR-open."
By this PR's own open, the shipped head on `origin/main` was
[INV-118](../pipeline/invariants.md) (Lane-GC PR-5's guardian sidecar,
#381/#430). A sibling in-flight PR in this same series (Lane-GC PR-6,
back-pressure gate + remote DEFERRED, issue #382) independently claims the
next free slot, **INV-119**, at the same time this PR was being written —
so this PR claims the slot after that:

- **INV-120 — systemd `--user` scope backend** (drafted as INV-113/114 in
  the parent design's §8 table; renumbered here to the first free slot,
  contingent on PR-6 landing first per the "first-merged keeps it" repo
  convention — re-verified again if that assumption turns out wrong at this
  PR's own merge).

## Scope (this PR)

1. **`skills/autonomous-dispatcher/scripts/lib-lane.sh`**: `_lane_backend()`
   (the probe, verbatim per design §4-C1 with the linger gate at selection
   time), `_lane_warn()` (centralizes the one WARN-line convention this file
   already had scattered at two `_bounded_call` sites), `_lane_unit_name()`,
   `_lane_cgroup_path()`, `_lane_cgroup_empty()`, `_lane_scope_kill()`;
   `lane_install()` now calls `_lane_backend()` once at mint and records
   `BACKEND`/`UNIT` instead of the PR-2-era hardcoded `BACKEND=pgid`/
   `UNIT=-` lines; `lane_spawn()` gains a backend-dispatching branch (scope
   vs. plain `setsid`); `lane_kill()` calls `_lane_scope_kill()` before its
   existing pgid escalation, unconditionally, every time.
2. **`skills/autonomous-dispatcher/scripts/lib-guardian.sh`**: `do_reap()`
   gains the identical `_lane_scope_kill()` call, in the identical position
   (before the pgid escalation), for the identical reason.
3. **`skills/autonomous-dispatcher/scripts/adt-gc.sh`**: `--doctor` gains a
   user-bus-socket reachability check (independent of the existing linger
   check — a linger=yes host can still have no reachable bus) and a
   `backend_eligibility=<systemd-scope|pgid>` summary line that runs the
   real probe live. **No GC decision-table code changes** — rule 1.3's
   existing `lane_kill "$lane_dir" 10` call inherits the scope fast path
   automatically, because the dispatch lives inside `lane_kill` itself, not
   inside the caller.
4. **`skills/autonomous-dispatcher/scripts/autonomous.conf.example`**: two
   new knobs, `LANE_TASKS_MAX` (default 512) and `LANE_MEMORY_MAX` (unset
   default), documented with the same "only takes effect when eligible"
   framing `--doctor` now surfaces.
5. **Tests**: `tests/unit/test-lane-gc-p7-scope.sh` (TC-LGC7-\*). No new E2E
   job — see the CI-feasibility section below.

## What is genuinely new vs. what already existed

`lib-lane.sh` already had `BACKEND=pgid`/`UNIT=-` as **hardcoded literal
strings** inside `lane_install` (a placeholder the PR-2 doc comment names
explicitly: "pgid backend only... systemd-scope backend is a later PR").
`lane_spawn` and `lane_kill` were pgid-only. This PR's diff is therefore
purely additive at three call sites — no existing pgid-path line was
deleted or reordered; every existing PR-2..PR-5 unit test that greps for
pgid-branch behavior stayed green unmodified (verified — see Test Results
below).

## Empirical findings (this PR's own dev/CI box: Ubuntu 24.04, systemd 249,
kernel 6.8, Linger=no)

These are the load-bearing facts the design's own §4-C1/§4-C7 pseudocode
assumes but does not itself prove; each was independently verified against
the real host before being relied on in code or tests.

1. **The core P7 claim is real, not aspirational.** A `systemd-run --user
   --scope` unit's `cgroup.procs` retained a `setsid`-escaped grandchild
   (different sid/pgid than the scope's own leader) after the escape, and
   `echo 1 > cgroup.kill` reaped it — the process was gone from
   `cgroup.procs` afterward with no separate per-pid kill needed. This is
   the exact "probe-verified: escaped setsid child stayed in cgroup.procs
   and was reaped" claim design §4-C7 makes; it now has a reproducible test
   (`tests/unit/test-lane-gc-p7-scope.sh`) behind it, not just prose.
2. **`cgroup.procs`'s `stat`-size is 0 even when it lists a live pid** — the
   identical procfs-style quirk design §7 platform:F5 already documents for
   `/proc/PID/environ`, now confirmed to extend to cgroupfs pseudo-files
   too. `_lane_cgroup_empty()` therefore reads the file's actual content,
   never gates on `[[ -s ]]`.
3. **`systemctl --user kill` requires the explicit `.scope` suffix.**
   Without it, systemd assumes `.service` and the call fails outright
   (`Unit <name>.service not loaded`) even though the `.scope` unit is
   loaded and active. Every kill-side call in this PR appends `.scope`
   explicitly.
4. **The cgroup path is resolved via the unit's own `ControlGroup`
   property** (`systemctl --user show -p ControlGroup --value <unit>.scope`
   → `/sys/fs/cgroup<value>`), not a hand-assembled
   `user.slice/user-<uid>.slice/user@<uid>.service/app.slice/<unit>.scope`
   path — the design mentions both forms; `ControlGroup` is the portable
   source of truth and needs no assumption about which slice systemd
   actually placed the scope under.
5. **`$!` from a backgrounded `systemd-run --user --scope ... -- setsid
   <cmd>` resolves to the scope's own leader pid**, which is also its pgid
   (`setsid` creates a fresh session/group for it) — confirmed by direct
   `ps -o pid,pgid,sid` inspection immediately after spawn. This is why
   `lane_spawn`'s scope branch can reuse the exact same `lane_record_pgid`
   call the pgid branch already makes, with no special-casing.
6. **`wait` on that same `$!` correctly propagates the payload's real exit
   code** (tested with a deliberate `exit 37` payload — `wait` returned 37),
   so `lane_spawn`'s return-code contract is unchanged for callers that
   don't care which backend ran.
7. **A probe spawn's transient unit self-cleans on success** — `systemd-run
   --user --scope --quiet -- true` (no `--collect`) leaves no residual
   `run-*.scope` unit behind after it exits successfully; the design's own
   probe snippet (§4-C1) is safe to call repeatedly (e.g. once per
   `--doctor` invocation) without unit accumulation.
8. **This host's actual eligibility is exactly what the design predicted**:
   `loginctl show-user -p Linger --value` returns empty/`no`, so
   `_lane_backend()` correctly and silently returns `pgid` with a WARN —
   this is the REAL (non-shimmed) refusal-path test in the suite below, not
   a simulated one.

## Review-round-1 fixes (post-empirical-findings, before merge)

An independent review pass on the first draft of this PR found three real
defects, all fixed in this same PR (no follow-up needed):

1. **Every `systemd-run`/`systemctl`/`loginctl` call this PR adds was
   unbounded.** A wedged user bus (a real, observable failure mode — this
   box's own `systemctl --user status` already reports 3 failed units) would
   have hung `_lane_backend()`'s mint-time probe (blocking every dispatch,
   not just scope-eligible ones) and `_lane_scope_kill`'s TERM/show calls
   WHILE `lane_kill` holds `reap.lock` — starving the unconditional pgid
   escalation that must always run afterward, i.e. turning the "never
   load-bearing" enhancement into a real blocker. Fixed by wrapping every
   such call through a new `_lane_bounded <secs> <cmd...>` helper
   (feature-detects `timeout`/`gtimeout`, mirroring `lib-agent.sh`'s own
   `_AGENT_TIMEOUT_CMD` resolution; absent a bounding tool, degrades to
   unwrapped rather than refusing to run at all). Verified empirically with
   a PATH-shimmed 60-second-sleeping `loginctl`/`systemctl`: `_lane_backend`
   now returns in ~5s (not 60s), `_lane_scope_kill` in ~20s (not 60s) —
   TC-LGC7-026/026b/027/027b, and proven to genuinely catch a regression by
   temporarily reverting the fix and confirming the assertion fails against
   the unbounded code.
2. **`ADT_LANE_BACKEND_OVERRIDE=systemd-scope` could bypass the entire
   probe, including the load-bearing linger gate.** An inherited (even
   accidental) copy of that env var in a wrapper's environment would enroll
   scopes on a Linger=no host — the exact mass-SIGKILL-on-last-logout
   scenario §4-C1/§4-C7 exist to forbid. Fixed: the override now can only
   NARROW `_lane_backend`'s result, never widen it — `=pgid` unconditionally
   forces pgid (always safe, no checks needed); `=systemd-scope` is a
   REQUEST that still has to pass every real check. `lane_install` no longer
   contains its own override-handling logic at all; it calls `_lane_backend`
   unconditionally and lets that function own the (narrowing-only) seam.
   Tests that need a deterministic scope-backend `lane` file for downstream
   argv/kill-path assertions now do so via a direct post-install
   `lane_set ... BACKEND systemd-scope` rather than relying on the override
   to manufacture eligibility the real host doesn't have.
3. **`_lane_unit_name` didn't sanitize or bound `PROJECT_ID`, and
   `lane_spawn`'s scope branch had no fallback when `systemd-run` itself
   failed to register.** Empirically verified on this box: `@` inside a
   unit name makes `systemd-run --unit` fail outright with "Invalid
   argument" (registration failure, not a payload failure), and unit names
   are capped at 255 bytes total INCLUDING the `.scope` suffix systemd
   appends (probed the exact boundary live: 249 raw chars => 255 total =>
   accepted; 250 => 256 => rejected). Worse: on a registration failure, the
   payload is NEVER exec'd at all — no process bearing its argv exists
   anywhere on the host. Two independent fixes: (a) `_lane_unit_name` now
   sanitizes every byte outside systemd's own safe alphabet
   (`[A-Za-z0-9:_.-]`) to `-` and truncates to a 200-char total budget
   while preserving the `.<epoch>.<rand4>` uniqueness tail intact; (b)
   `lane_spawn`'s scope branch now captures `systemd-run`'s own stderr and
   discriminates a REGISTRATION failure (systemd-run's own diagnostics are
   always emitted with a `Failed to ` line-start prefix, verified both
   directions — present on every registration failure, absent even when the
   payload itself fails or writes noisy stderr) from a genuine PAYLOAD
   failure; only the former triggers a real pgid-spawn retry, so the payload
   is guaranteed to run at least once regardless of which backend actually
   executes it. Proven with a genuine "would-have-failed" test
   (TC-LGC7-023/024) that spawns via a deliberately invalid unit name and
   asserts a marker file was created by the fallback-executed payload, plus
   a companion test (TC-LGC7-025) proving a genuine payload failure does
   NOT trigger a spurious retry/double-run.

Residual, explicitly accepted: the `Failed to ` prefix match is a
translated CLI string, not a stable machine-readable exit code — a future
systemd version or non-English locale could in principle drift this
discriminator. This is the same class of residual the design's own env-tag
matching accepts elsewhere (best-effort string matching against a CLI's
own diagnostic text, not a public API contract); the failure MODE if it
ever drifts is "an occasional registration failure is misclassified as a
payload failure and doesn't get the pgid retry" — still bounded (the
already-recorded scope-attempt pgid is escalated normally, a no-op against
a process that never existed), never a silent total loss of the payload
across every failure mode, which was the actual defect being fixed.

## CI-feasibility decision for a real scope E2E job

**Decision: no new CI E2E job for the scope backend in this PR.**

Research (both an external web-search pass and this PR's own bootstrapping
attempt) confirms GitHub-hosted `ubuntu-latest` runners do **not** have
`loginctl enable-linger` set for the runner user, and do **not** have a
running user D-Bus session by default in a non-login CI shell —
`systemctl --user status` fails with "Failed to connect to bus" until a job
explicitly does `sudo loginctl enable-linger $USER` and exports
`XDG_RUNTIME_DIR="/run/user/$(id -u)"` itself. That bootstrapping is real
work (a `sudo` step, a linger-enable, an env export, and unlearning it again
since GitHub-hosted runners are ephemeral so it would need to repeat every
job) — not a one-line probe. Because:

- the design's own principle 8 requires the portable pgid path to remain
  fully sufficient alone (i.e. an E2E job proving the scope path is a nice
  extra, not a completeness gate on this PR), and
- the design's own §11 ("macOS ACs decision") already establishes the
  precedent that a feasibility-gated AC may be **deferred to a follow-up PR
  that must land before the series' final enforcement flip (PR-8)** rather
  than blocking the PR that introduces the feature,

this PR follows that exact precedent: the scope backend ships fully
implemented and unit-tested (including one REAL, non-shimmed
spawn-and-cgroup-kill test on THIS PR's own dev/CI box, which — unlike a
GitHub-hosted runner — already has systemd + a live user bus by default),
and a CI E2E job that actually exercises `systemd-run --user --scope` under
the hosted runner's bootstrapped linger is deferred to a follow-up PR that
must land before PR-8's dry-run→kill enforcement flip. That follow-up would
add the `sudo loginctl enable-linger` + `XDG_RUNTIME_DIR` export bootstrap
as its own CI step and is out of scope here.

This is a narrower deferral than PR-4's macOS-runner deferral (that one
covers an entire platform's AC set; this one covers exactly one job on one
already-supported platform), but the shape of the decision — and the
requirement that it land before PR-8 — is identical.

## Test coverage shape (design §9 PR-7's own AC list, mapped to TC-LGC7-\*)

| Design AC | Test | Class |
|---|---|---|
| linger=no host refuses scope, `BACKEND=pgid` recorded, wrapper spawns fine | TC-LGC7-001..003 | REAL (this host) |
| probe-failure host falls back to pgid, `BACKEND=pgid` recorded | TC-LGC7-010..013 | PATH-shim (per-prerequisite isolation) |
| unit-name collision (two lanes, same second) resolved via rand4 | TC-LGC7-020 | REAL (string assertion, no real collision needed) |
| TasksMax visible in `systemctl --user show` | TC-LGC7-030..031 | PATH-shim argv capture |
| setsid-escaping child inside a scope is reaped by `lane_kill` | TC-LGC7-040 | REAL (this host, override seam) |
| mixed fleet: scope-lane + pgid-lane reaped by the same GC pass | TC-LGC7-050 | REAL |
| guardian `do_reap` scope-branch ordering + argv | TC-LGC7-060..061 | grep-pin + PATH-shim |
| lane file records BACKEND/UNIT correctly (both branches) | TC-LGC7-070..071 | REAL |
| pgid-backend lanes fully unaffected by this PR (regression pin) | TC-LGC7-080 | REAL roundtrip |

Full scenario list: `docs/test-cases/lane-gc-p7-scope.md`.

## Honest-scope note on what the PATH-shims can and cannot prove

A PATH-shim replacing `systemd-run`/`systemctl`/`loginctl` with a recording
script proves **selection logic** (did `_lane_backend()` make the right
call given a controlled prerequisite state?) and **kill-path command
construction** (did `lane_kill`/`do_reap` build the argv the design
specifies — `--unit`, `-p TasksMax=`, `--collect`, `-- setsid` ordering;
`kill -s TERM <unit>.scope`, `show -p ControlGroup --value <unit>.scope`?).
It cannot and does not prove real cgroup/kernel semantics — that a
`setsid`-escaping process genuinely stays visible in `cgroup.procs`, that
`cgroup.kill` is genuinely atomic across fork races. Those claims are proven
instead by this PR's own REAL (non-shimmed) scope-spawn-and-kill test
(TC-LGC7-040), which runs directly against this host's real systemd/kernel
using the `ADT_LANE_BACKEND_OVERRIDE` test-only seam to force scope
selection without needing to mutate the host's actual linger setting (which
needs root and is a durable host-wide change, not something a test suite
should touch). A host where even `systemd-run`/`loginctl`/`systemctl` are
entirely absent from `PATH` skips TC-LGC7-040 with an explicit
`SKIP (reason: ...)` line rather than faking a pass.
