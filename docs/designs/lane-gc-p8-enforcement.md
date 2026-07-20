# Lane-GC P8 enforcement rollout record

**Status:** implementation candidate for issue #384; production rollout is not
authorized. The frozen architecture authority remains
`docs/designs/lane-containment-gc.md` rev 3. This file records the available
production evidence, the still-open soak gate, rollout boundaries, and the
implementation hardening prepared for a future Linux dry-run-to-kill flip.

## Production soak

The Linux wrapper host's `adt-gc-cron.log` was created at
2026-07-10T04:30:01Z. The exact first 730 `ADT_GC_SUMMARY` lines are frozen as
an interim evidence prefix. At the configured ten-minute interval, 730 records
represent only about 5.07 days of nominal scheduled coverage, not the at least
14 days required by issue #384:

| Metric | Result |
|---|---:|
| `would_kill_legacy_signature` sum / max | 0 / 0 |
| `unknown_class` sum / max | 7 / 1 |
| runs with non-zero `unknown_class` | 7 isolated runs |
| `killed` sum | 0 |
| `live_burner_alerts` sum | 0 |

The seven unknowns occurred at records 15, 103, 132, 171, 222, 592, and 593;
each run had exactly one. Records 594 through 730 have zero
`would_kill_legacy_signature`, `unknown_class`, `killed`, and
`live_burner_alerts`. This is a stable interim tail, but it does not satisfy the
duration gate. The SHA-256 of those exact 730 newline-terminated summary lines is
`e204c2cb91521d39b1cb0f6dbc0079496c0997b9a0eb668a3978262169405e97`.

The cron log continues appending, but records 740 onward are contaminated by
P8 test fixtures on this shared host: `would_kill_legacy_signature` first
becomes 2 at record 740 and reaches 6 at record 747. Those records are not
production-soak evidence. The frozen prefix is immutable and excludes every
post-freeze record, including the uncontaminated-looking 731-739 interval, so
future appends cannot silently change this evidence population. A new clean
window of at least 14 days, or equivalent uncontaminated evidence accepted by
the operator, is still required before merge or rollout.

The actual post-P2 onboarding snapshot contains two project ticks in the host
crontab: `autonomous-dev-team` and one downstream checkout. Both projects' effective
dev/review wrappers contain the P2 `lane_mint`/`lane_install`/tag-export wiring,
so both checkouts are code-wired. `autonomous-dev-team` has 681 final lane
directories; all 681 contain the P2 atomic-install KV fields plus `pgids` and
`reap.lock`. Those pre-P8 records do not yet contain P8's new
`GUARDIAN_IDENTITY`/`pgids.lock` schema, as expected before this branch is
installed. The downstream checkout has no runtime lane records, so its runtime schema
cannot be proven from this snapshot. No live `autonomous-dev.sh` or
`autonomous-review.sh` process was present at audit time. This replaces the
unsupported claim that 13/13 `--doctor` results proved onboarding. No
production process was signaled during evidence collection.

## Grandfather decision

The one-time 26-58-day orphan cohort was treated as incident residue and
removed during the pre-soak incident response, after its ownership signatures
were inspected. P8 does not repeat a broad process-name sweep: zero legacy
signature candidates across the full soak and a current read-only process
inventory are the closure evidence that no grandfather cohort remains.
Remaining old registry rows are metadata, not authority to signal a live PID.

P8 adds a durable process identity to every new PGID and guardian record.
Linux uses `v2-linux:<boot-id>:<start-ticks>`, so a reboot cannot make a
reused start-tick value look authoritative. Pre-boot-ID `v1-linux` and the
one-second-granularity BSD v1 form remain diagnostic-only.
Delayed PGID GC verifies the whole lane before sending any TERM, sends TERM to
all verified groups, waits one shared grace interval, then revalidates every
survivor before starting KILL. It also revalidates each target immediately
before that target's TERM or KILL. A whole-phase preflight refusal sends no
signal in that phase; a later per-target refusal stops that target and all
remaining targets, but cannot undo signals already sent earlier in the phase.
The operation is therefore deliberately fail-toward-leak, not kernel-atomic.
Any refusal returns non-zero, so GC never marks the lane `gc-reaped`. Rule 1.4
similarly revalidates a guardian immediately before TERM and again before KILL.
A live old three-field PGID record, an identity-less guardian, a recycled
PID/PGID, or a leaderless group is deliberately left for manual inspection.

Strict lane reaping must own `reap.lock`. It then takes `pgids.lock`, creates
`pgids.closed`, and snapshots the complete registered set; later appenders
observe the marker under the same lock and cannot escape that snapshot.
Passes 2 and 3 separately bind both the classified candidate PID and its PGID
leader to Linux v2 identities, confirm that the candidate still belongs to
that group before TERM, and revalidate the leader before KILL. These checks
cannot make identity verification plus signal delivery one kernel-atomic
operation; eliminating that final userspace race requires pidfds or complete
cgroup enrollment and remains outside P8.

## Fleet waivers

**macOS:** explicitly waived for the proposed Linux-only rollout and guarded in
code. The procargs2 parser, BSD process seams, and launchd generation stay
unit-tested, but an unset mode on Darwin or an unknown platform defaults to
dry-run with source `built-in-platform-guard`. An explicit
`ADT_GC_ENFORCE=1` or `--kill` remains available only after a separate operator
validation.

**systemd scope:** not enabled by the proposed rollout. On the audited
production wrapper host, the authoritative explicit-user command
`loginctl show-user "$USER" -p Linger --value` reports `yes`. The current P7
probe omits the username; on this host that command returns an empty value
with rc 0, so `_lane_backend` currently falls back to `pgid` and records
`BACKEND=pgid`. That accidental fallback is not treated as a correct
linger-disabled safety claim.

P8 deliberately does not correct the probe in isolation: doing so on this
already-linger-enabled host could select `systemd-scope` before the primary
agent launch path is enrolled. Follow-up #522 must change both `_lane_backend`
and `--doctor` to use an explicit user while completing the enrollment and
E2E work below. Operators must not rely on the current empty probe or alter
linger as part of P8.

The P7 scope implementation covers `lane_spawn`, but the real agent launch
chokepoint is `lib-agent.sh::_run_with_timeout`, which currently creates a
plain `setsid` process group rather than entering `lane_spawn`. A wrapper may
therefore record scope eligibility without proving that its main agent subtree
was enrolled in that scope. Before any host may select `systemd-scope`,
follow-up #522 must:

1. correct the linger probe to pass `${USER:-$(id -un)}` explicitly;
2. route `_run_with_timeout` through the selected scope backend without
   weakening timeout, PID-file, turn-control, stdin, or credential-scrub
   contracts;
3. run a full wrapper under the existing real linger-enabled user manager;
4. SIGKILL the wrapper mid-run and prove the agent plus a re-setsid escapee
   leave `cgroup.procs` and are reaped through the guardian/GC path.

Until that work lands, and before any host is allowed to select
`systemd-scope`, the portable PGID path is the only backend proposed for this
candidate. It is not production-authorized until the soak gate closes.
`lane_kill ... require-identity` enforces the boundary directly: a recorded
`BACKEND=systemd-scope` returns refusal code 3 before either the scope or any
recorded PGID is signaled. Immediate wrapper/guardian-owned cleanup keeps the
existing scope fast path.

## Rollback

The candidate implementation changes the Linux built-in mode to `kill`; the
production installation remains dry-run until the soak gate closes and this
change is merged and installed. Other platforms retain the built-in platform
guard described above. The persistent box-wide rollback is exactly:

```text
ADT_GC_ENFORCE=0
```

stored at `$ADT_STATE_ROOT/adt-gc.conf`. Precedence is explicit CLI mode >
present box config veto > environment > built-in default. A present config is
rollback-only and therefore overrides `ADT_GC_ENFORCE=1` from the environment.
The config is parsed as data and accepts only that rollback assignment plus
blank/comment lines. Invalid selected environment or config input warns and
falls back to dry-run.

`install-gc-timer.sh` validates and creates a custom `ADT_STATE_ROOT` before
installing either scheduler, then persists it in both the Linux cron entry and
macOS launchd environment so scheduled and opportunistic collectors read the
same registry and rollback file and their log redirections have a valid parent.
It also atomically writes that absolute root to the host-user pointer
`$HOME/.local/state/adt-state-root` with mode 600. Later wrappers and
opportunistic collectors with `ADT_STATE_ROOT` unset resolve the pointer;
an explicit environment value still wins. An installer re-run with no
explicit value also resolves the existing pointer instead of resetting a
custom installation. A missing pointer uses `$HOME/.local/state`, while
malformed, unreadable, non-regular, or symlinked pointer state warns and safely
falls back there.

Scheduler publication and pointer publication are one rollback-aware
transaction. On Linux, a failed crontab update leaves the old pointer
untouched; if pointer persistence fails after the crontab update, the installer
restores the previous crontab. On macOS, the new plist is staged and the old
plist is backed up; a bootstrap or pointer-persistence failure restores the
previous plist and loaded agent. The previous pointer remains intact on every
failed path.

The pointer parser is shared in `lib-state-root.sh`. `lib-lane.sh` uses it for
wrappers and GC, `lib-dispatch.sh` uses it for local dispatcher marker reads,
and the remote SSM liveness command embeds the same resolver function before
reading remote lane markers.

## Verification

`tests/unit/test-lane-gc-p8-enforcement.sh` contains 113 passing assertions.
They cover the default/rollback precedence, invalid and dangling config,
custom timer roots and transactional rollback, shared local/remote state-root
resolution, boot-bound identities, legacy refusal, guardian and Pass 2/3
signal-time identity changes, strict lock ownership, registration closure,
exact-`pgid` backend whitelisting, Pass 2/3 scope refusal, explicit identity
transport, and the scope rollout guard.

Owner-side re-dispatch, legacy PID-file, wrapper cleanup, and guardian EOF
paths intentionally retain their pre-P8 best-effort behavior because they act
while ownership is contemporaneous. Moving those paths to the delayed-GC
authority model is not part of the enforcement flip.
