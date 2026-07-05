# Design: Lane-GC P5 — guardian sidecar

**Status:** Implementation notes for issue #381 (Lane-GC series PR-5). Full
design authority is `docs/designs/lane-containment-gc.md` §4-C3 (guardian
sidecar), §9 PR-5. This doc records only the PR-open numbering
re-verification, the concrete diff shape, the ordering-bug fix found while
building this PR's own test suite, and the setsid-degradation decision — it
is not a new design; defer to the parent doc for rationale.

## Numbering re-verification (design §8/§10 F10 completeness)

The parent design assumed head INV-105 and reserved INV-106..113 (§8) for
the whole series, drafting the guardian as INV-109. By PR-2's open
(#378/#405 sequence), PR-2 had already shipped INV-109/INV-110 for the
lane-registry/tagging invariants, and PR-3 shipped INV-114/INV-115; PR-4
(#380/#427) shipped INV-117 after two of its own renumber-on-collisions
(drafted INV-110 → claimed INV-116 → yielded to #422's independently-merged
GitLab-transport invariant → re-claimed INV-117). This PR's own rebase onto
`origin/main` landed on top of that already-merged head:

- **INV-118 — Guardian sidecar** (drafted as INV-109 in the parent design's
  §8 table; renumbered here to the first free slot at this PR's open, per
  the design's own stated "first-merged keeps, each INV-adding PR notes the
  convention" rule).

## Scope (this PR)

1. **`skills/autonomous-dispatcher/scripts/lib-guardian.sh`** (new
   `lib-*`-named file — deliberately excluded from `install-project-hooks.sh`'s
   symlink manifest, same contract as every sibling `lib-*.sh`; reached
   purely via each wrapper's own `readlink -f`-resolved `LIB_DIR`). Invoked
   as a script (`setsid bash lib-guardian.sh --lane-dir <dir>`), never
   sourced. Implements the no-writer watchdog, the hard lifetime cap, the
   main EOF wait, and `do_reap` (idempotent, `reap.lock`-guarded, lane-scoped
   escape sweep).
2. **Wrapper integration** (`autonomous-dev.sh`, `autonomous-review.sh`):
   the guardian-install block right after `lane_install` succeeds —
   `mkfifo` → `exec {ADT_GUARD_FD}<>` (write end, opened first) → `setsid`
   prereq check → guardian spawn (closing its own inherited fd copy) →
   `lane_set GUARDIAN_PID`. The `cleanup()` handshake replaces the
   feature-guarded no-op [INV-115] reserved for it.
3. **FD-hygiene closes** at every long-lived background spawn site this
   series already ships: `lib-agent.sh`'s `_run_with_timeout` (the agent CLI
   spawn) and heartbeat loop, both TERM-trap escalator sites, `lib-auth.sh`'s
   token-daemon spawn, `lib-lane.sh`'s `lane_kill` escalator and
   `_bounded_call`'s background invocation, and the review wrapper's
   smoke-probe and fan-out subshells.
4. **Tests**: `tests/unit/test-lane-gc-p5-guardian.sh` (unit/integration,
   TC-LGC5-\*), `tests/e2e/run-lane-gc-p5-guardian-e2e.sh` +
   `tests/unit/test-lane-gc-p5-guardian-e2e.sh` (the CI-loop thin wrapper).

`adt-gc.sh` (P4, already merged), the back-pressure gate (P6), and the
systemd-scope backend (P7) are separate PRs — not touched here.

## The ordering-bug fix (found empirically, not merely a design residual)

The parent design's §4-C3 pseudocode shows the no-writer watchdog's
`_guard_writer_present` check running AFTER the guardian's blocking
`exec 3<"$LANE_DIR/guard.fifo"` open. This is a real bug, not a stylistic
choice: if no writer is ever present (the exact scenario the watchdog exists
to bound), that `open(2)` call itself blocks indefinitely — a check placed
after a line that never returns is dead code for precisely the case it
claims to guard. This was caught while building this PR's own end-to-end
smoke tests (a guardian spawned against a never-written fifo hung for the
full outer test timeout instead of self-exiting at the configured grace).

The fix arms the watchdog timer + `SIGUSR2` trap **before** attempting the
open. Verified empirically on this repo's own dev host: a trapped signal
correctly interrupts a shell blocked in `exec N<fifo` against a fifo with no
writer, the identical mechanism that already interrupts a blocked `read`.
This also let the design's proposed `/proc`-wide "scan every process for an
existing writer" mechanism be dropped entirely:

- It was **unnecessary** — a plain read-only fifo open already returns
  immediately the instant ANY writer (even one opened `O_RDWR`) is
  connected, by ordinary POSIX fifo semantics. No separate positive check
  was needed to get that behavior; the design's own inline comment ("the
  wrapper's `<>` fd already provides a writer") already describes the
  mechanism that makes the check redundant.
- It was **too slow to trust inside a 15s grace window** on this project's
  own dev/CI host — enumerating every process's fd table via `/proc/*/fd/*`
  took multiple seconds under ordinary load, eating meaningfully into the
  grace bound the watchdog is supposed to enforce.
- It is now **portable to macOS for free** — the timer-first approach needs
  only signals and a plain fifo open, neither of which is platform-specific,
  where the original `/proc`-based scan would never have worked on Darwin at
  all (no `/proc`).

## The FD-hygiene ordering bug at the guardian's own spawn site

A second bug of the same class, also found empirically: the design's inline
snippet (§4-C3) shows the guardian spawned via a bare
`setsid bash "$LIB_DIR/lib-guardian.sh" --lane-dir "$LANE_DIR" & `, with no
FD-hygiene close at that spawn site itself. Because `{ADT_GUARD_FD}` fds are
NOT close-on-exec by default (verified: they survive `exec()` into any
binary, and a plain forked/backgrounded process inherits them too), the
guardian process itself would otherwise inherit the wrapper's write-mode
copy of the fifo fd — becoming a second write-mode holder of the very fifo
it is supposed to watch. The wrapper's own later close would then no longer
be sufficient to reach EOF (a second holder is still open), and the
guardian would block in its main `read` forever even after a real wrapper
death. The fix: the guardian's own spawn line closes its inherited fd
FIRST, inside the same `setsid bash -c '…'` wrapper that then execs into
`lib-guardian.sh` — `[[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-;
exec bash "$1" --lane-dir "$2"`.

## `do_reap`'s non-reentrant-flock avoidance

`lane_reap`/`lane_kill` (PR-3) documents that `flock` on an already-held fd
BY THE SAME PROCESS, reacquired via that SAME function's own second call, is
a re-entrant no-op-wait. That description is specific to `lane_kill`'s own
internal re-acquisition pattern; it does NOT generalize to a DIFFERENT
calling frame holding a DIFFERENT fd against the same lock file. Verified
empirically: two separate fds opened by the SAME process against the SAME
lock file, where the first is already held via `flock`, and the second is
then `flock`ed — the second call blocks/deadlocks for its own full wait
bound, it is not a no-op. `do_reap` therefore takes `reap.lock` itself via a
single non-blocking `flock -n` and, on success, calls the shared
`_kill_group_escalate` primitive DIRECTLY over the recorded `pgids` —
never through `lane_kill`, which would otherwise try to re-flock the same
file `do_reap` already holds and silently degrade every guardian reap to
`lane_kill`'s own 10s bound (a real, if quiet, incorrect-latency bug rather
than a crash).

## Interpretation notes (decisions made where the parent design leaves a
degree of freedom — see "Decision Making Guidelines" in the autonomous-dev
skill: pick the simpler, more maintainable option)

- **`setsid`-absent degradation: log-and-continue, not abort.** The parent
  design states "`setsid` is a hard prerequisite on BOTH platforms… no `&
  disown` fallback" and "SKILL.md and `adt-gc.sh --doctor` both fail loud
  when `setsid` is missing" — read strictly, that could mean the wrapper
  itself should refuse to run. This PR reads it as: `setsid` is a hard
  prerequisite **for the guardian's own correctness** (a same-PGID guardian
  is worse than no guardian, since it dies with the wrapper on every
  group-kill), not for the wrapper run as a whole. When `setsid` is absent,
  the wrapper logs a loud, actionable error (mentions `brew install
  util-linux` — the macOS remediation the parent design's own §7/§4-C3
  names) and proceeds WITHOUT installing a guardian for that run, leaving
  the periodic GC ([INV-117], already shipped and unconditional) as the
  sole backstop reaper. Bricking every dispatch on a host that happens to be
  missing `setsid` — a config/environment problem, not a code-correctness
  one — would be strictly worse than degrading one run's reap latency from
  seconds to the GC's ~10-minute cadence. `adt-gc.sh --doctor`'s own loud
  `setsid`-missing surfacing (already shipped by PR-4) remains the
  fail-loud signal an operator actually needs to notice and fix the host;
  this PR does not duplicate that surfacing at the wrapper level beyond the
  per-run log line.
- **No-writer-watchdog mechanism: timer-first signal interrupt, not a
  `/proc` presence scan.** Covered in detail above — chosen for
  correctness (the scan-after-open ordering was a real bug), speed (no
  `/proc`-wide enumeration inside the grace window), and portability (no
  OS-specific introspection needed at all).
- **Escape-sweep platform scope: Linux only, this PR.** The escape sweep's
  `ADT_LANE_ID` matching uses `env_of` (Linux `/proc/PID/environ`). PR-4
  already shipped a macOS `env_of` path via the `sysctl kern.procargs2`
  shim — the guardian's escape sweep inherits that same primitive
  transparently (it calls the shared `env_of`, not a bespoke Linux-only
  read), so no additional macOS-specific code is needed in this PR; the
  registry-driven pgid escalation (step 4 §4-C3, unconditional on any
  platform) remains the primary reap mechanism regardless.

## Out of scope (unchanged from parent design §11, §9 PR-5's own carve-out)

- The systemd-scope backend's `cgroup.kill` fast path in the guardian
  (design §4-C7) — P7, not touched here; the guardian's reap always uses the
  pgid-backend escalation path this PR ships.
- Full macOS-runner CI execution for the guardian itself — no macOS runner
  exists in this repo's CI pool; the escape sweep transparently inherits
  PR-4's macOS `env_of` shim, but live macOS verification of the guardian
  end-to-end is a non-blocking follow-up, same posture PR-4 already
  established for its own macOS-specific paths.

Back-pressure admission gate (P6) and systemd-scope backend (P7) are later
PRs in the series — not touched here.
