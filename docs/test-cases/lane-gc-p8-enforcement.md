# Test Cases - Lane-GC P8 enforcement flip (#384)

Final issue in the Lane-GC series. These tests prove the implementation
candidate that changes Linux `adt-gc.sh` from dry-run-by-default to
kill-by-default while retaining one box-wide rollback flag and a non-Linux
platform guard. They do not satisfy issue #384's operator-owned, at-least
two-week production-soak gate; merge and rollout remain blocked on that
evidence.

Production evidence and the Linux-only/scope rollout boundaries are recorded
in `docs/designs/lane-gc-p8-enforcement.md`.

Test runner: `bash tests/unit/test-lane-gc-p8-enforcement.sh`.

## Mode selection

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC8-001 | `ADT_GC_ENFORCE` unset and no box-wide config | Linux default mode is `kill`; unvalidated Darwin remains `dry-run` unless explicitly enabled |
| TC-LGC8-001d | `uname -s` fails | platform is unknown and the built-in mode remains `dry-run` |
| TC-LGC8-002 | `ADT_GC_ENFORCE=1` in the environment | mode is `kill`; the pre-P8 opt-in remains valid |
| TC-LGC8-003 | `ADT_GC_ENFORCE=0` in the environment | mode is `dry-run`; this is the immediate rollback |
| TC-LGC8-004 | `$ADT_STATE_ROOT/adt-gc.conf` contains `ADT_GC_ENFORCE=0` | mode is `dry-run`; cron and opportunistic GC share the persistent rollback |
| TC-LGC8-005 | box-wide config contains `ADT_GC_ENFORCE=1` | reject it: the persistent file is rollback-only; warn and fail toward `dry-run` |
| TC-LGC8-006 | box-wide config says `0`, environment says `1` | the persistent rollback veto wins and mode remains `dry-run` |
| TC-LGC8-007 | explicit `--dry-run`/`--kill` is present with an invalid lower-precedence environment/config value | explicit CLI mode wins; ignored lower-precedence sources are not parsed or warned about |
| TC-LGC8-008a-g | environment is invalid, or box-wide config is missing/duplicate/contains extra content | warn and fail toward `dry-run`; parse config as data and never execute its content |
| TC-LGC8-008h/i | the rollback path is a dangling symlink | treat the selected config as invalid, warn, and fail toward `dry-run` rather than restoring the kill default |

## Behavioral proof

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC8-009 | an isolated `.pending-*` directory older than 24h, no mode flag | Linux default removes it and reports `killed=1`; Darwin's platform guard preserves it and reports classification only |
| TC-LGC8-010 | the same fixture with box-wide `ADT_GC_ENFORCE=0` | directory remains and the run reports `would_kill=1`, `killed=0` |
| TC-LGC8-011a-f | install the Linux cron timer and macOS launchd agent with a fresh custom `ADT_STATE_ROOT` | the installer creates the root before scheduler log redirection, persists it in the host-wide root pointer, and scheduled plus unset opportunistic callers resolve the same root; a re-run without an explicit root preserves the existing custom root, a symlinked pointer warns and falls back, and macOS-loaded `lib-lane.sh` retains sibling-library resolution when GNU `readlink -f` is unavailable |
| TC-LGC8-011g/h | install a timer with relative `ADT_STATE_ROOT` | reject the path and exit non-zero before writing scheduler configuration |
| TC-LGC8-011i-l | Linux scheduler update fails; separately, root-pointer persistence fails after a scheduler update | return non-zero without publishing a split configuration: a scheduler failure leaves the old pointer intact, and a pointer failure restores the prior crontab |
| TC-LGC8-011m/n | `ADT_STATE_ROOT` is unset after installing a custom root; local dispatcher and remote liveness read a defer marker | both consumers resolve the host-user pointer and inspect the same custom-root marker written by `dispatch-local.sh` |
| TC-LGC8-011o/p | macOS launchd bootstrap fails while replacing an existing installation | return non-zero and restore both the prior plist and prior host root pointer |
| TC-LGC8-012a-d | a new live PGID record carries a matching process identity; PGID lock acquisition is followed by a caller stderr sentinel | the record has four fields, lock acquisition preserves caller stderr, and strict GC rule 1.3 verifies the identity, reaps the group, and reports a kill |
| TC-LGC8-012aa/ab | Linux identity is captured, then the boot ID seam changes while PID/start ticks stay fixed | identity is `v2-linux:<boot-id>:<start-ticks>` and the different boot ID proves a mismatch |
| TC-LGC8-013 | a live recorded PGID has a mismatched identity (simulated PGID reuse) | strict GC refuses every signal, leaves the group alive, leaves the lane non-terminal, and logs an identity-verification skip |
| TC-LGC8-014a/b | a legacy three-field PGID record names a live group | strict GC treats the missing identity as unverifiable and fails toward leak |
| TC-LGC8-014c | a live group has a matching pre-boot-ID `v1-linux` identity | retain it for diagnostics but refuse to use it as delayed-signal authority |
| TC-LGC8-015 | rule 1.4 finds a live `GUARDIAN_PID` whose recorded identity mismatches | GC does not signal the recycled PID; because mismatch proves it is not the guardian, the stale terminal lane directory may still be removed |
| TC-LGC8-016 | rule 1.4 finds a live legacy guardian PID with no identity | GC cannot distinguish the real guardian from PID reuse, so it signals nothing and preserves the lane directory for a later/manual reap |
| TC-LGC8-017 | BSD/macOS process-identity seam against a live fixture process | emits a compact `v1-bsd:<recorded-ppid>:<sha256>` identity; exact identity matches, a changed hash proves mismatch, and malformed identity is unverifiable |
| TC-LGC8-017e | a matching BSD v1 identity is presented to delayed-signal authorization | diagnostic matching remains available, but authorization refuses it |
| TC-LGC8-018a-d | two live groups pass snapshot identity checks, then one fails the lane-wide pre-TERM revalidation; separately, a lane records `BACKEND=systemd-scope` | a phase-preflight refusal returns `3` before that phase starts; strict delayed GC also returns `3` for the scope lane before invoking `systemctl` or signaling its PGID, pending #522 |
| TC-LGC8-018e-g | strict reap lacks `reap.lock`; separately, a writer attempts registration after strict snapshot closure | missing lock returns `3` and sends no signal; strict GC creates `pgids.closed` under `pgids.lock`, and the late append is rejected |
| TC-LGC8-018h-k | strict reap sees missing/unknown `BACKEND`, or `lane_kill` receives a misspelled policy | only exact `BACKEND=pgid` is accepted; an unknown policy returns usage error before locks or signals |
| TC-LGC8-018l-o | every group passes phase preflight, then the second group changes identity immediately before its TERM or KILL | the first group may already have received that phase's signal; return `3` and stop before signaling the changed group or any remaining group |
| TC-LGC8-019 | an identity-aware individual-PID escalation delivers TERM, then identity revalidation fails before KILL | returns `3`; KILL is refused and the changed live process remains |
| TC-LGC8-020a/b | a Pass 2/3 candidate and its PGID leader match at classification, TERM lands, then leader identity changes before KILL | returns `3`; the KILL phase is refused and the changed process remains |
| TC-LGC8-021 | Pass 2 and every Pass 3 rule encounter a candidate tagged to a dead `systemd-scope` lane | refuse before signaling; lane-scoped rules also refuse before enumerating lane-owned candidates, pending full-wrapper scope enrollment in #522 |
| TC-LGC8-022 | Pass 2/3 candidate classification order and identity transport | bind the PID before any env/argv/cwd classification, pass identities explicitly, and use one durable authorization helper |

All fixtures use a fresh `ADT_STATE_ROOT`; the tests never inspect or mutate the
operator's real lane registry.
