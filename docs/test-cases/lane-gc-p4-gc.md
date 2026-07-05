# Test Cases — Lane-GC PR-4: `adt-gc.sh` periodic GC + `install-gc-timer.sh` (#380)

Fourth PR of the Lane-GC series (design: `docs/designs/lane-containment-gc.md`
§4-C5, §6, §9 PR-4; `docs/designs/lane-gc-p4-adt-gc.md`; INV-116 — renumbered
from the design's drafted INV-110 after PR-2/PR-3 already claimed
INV-109/INV-110/INV-114/INV-115). The periodic, issue-independent garbage
collector plus its per-host timer installer.

Test runner: `bash tests/unit/test-lane-gc-p4-gc.sh` (auto-discovered by the
CI `hermetic-unit` job's `tests/unit/test-*.sh` glob). Run the full suite
under `env -u PROJECT_DIR` for CI parity. Every test isolates
`ADT_STATE_ROOT` to a fresh `mktemp -d` — never the real
`$HOME/.local/state` — so this suite is safe to run on a box with a live
dispatcher.

## Pass 1 — registry-driven (AC1)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC4-001 | Lane with `STATE=live`, `WRAPPER_PID` = the calling shell's own alive `$$` | rule 1.1 skip — `--dry-run` log shows `skip rule=1.1` |
| TC-LGC4-002 | Lane `STATE=reaping`, `GUARDIAN_PID` alive, state age < 5 min | rule 1.2 skip (guardian owns the reap) |
| TC-LGC4-003 | Lane `STATE=reaping`, `GUARDIAN_PID` alive, state age ≥ 5 min (tightened bound) | rule 1.2 does NOT apply; falls to rule 1.3 (wedged) — reap-eligible |
| TC-LGC4-004 | Lane dead, `GUARDIAN_PID` dead, lane age > 600s | rule 1.3 fires: `lane_kill` invoked, `STATE` becomes `gc-reaped` in `--kill` mode |
| TC-LGC4-005 | Lane dead, `GUARDIAN_PID` dead, lane age < 600s, `STATE=live` (i.e. not reaping/cleaning) | rule 1.3 does NOT fire (age floor not met, state not reaping/cleaning) — skip |
| TC-LGC4-006 | Lane dead, `STATE=reaping`, lane age < 600s (the F3 arithmetic-note regression) | rule 1.3 STILL fires — `STATE∈{reaping,cleaning}` is a disjunct with the age floor, not an additional conjunct |
| TC-LGC4-007 | Lane `STATE=clean-exit`, state age > 24h | rule 1.4: `rm -rf` the lane dir (`--kill` mode) / would-kill logged (`--dry-run`) |
| TC-LGC4-008 | Lane `STATE=clean-exit`, state age < 24h | skip — terminal state alone is not enough, age gate required |
| TC-LGC4-009 | Lane file unparseable (garbage content), age > 24h | rule 1.4 third clause: collected/`rm -rf`'d |
| TC-LGC4-010 | Lane file unparseable, age ≤ 24h | rule 1.5: skip + WARN logged, never collected early |
| TC-LGC4-011 | `.pending-<id>/` orphan dir (mid-crash mint), age > 24h | rule 1.4 second clause: collected/`rm -rf`'d |
| TC-LGC4-012 | `.pending-<id>/` orphan dir, age ≤ 24h | skip — not yet eligible |
| TC-LGC4-013 | Rule 1.4 with a LIVE `GUARDIAN_PID` on the terminal-state lane being collected | guardian is TERM'd (1s grace) then KILLed-if-still-alive BEFORE `rm -rf` — never rm-rf'd out from under a live guardian (F4 selfdefeat) |

## Pass 2 — tagged-orphan sweep, false-kill decoys (AC1, the issue's stated fixture set)

Every decoy below is spawned as a REAL `setsid`-detached process (never a
description) so the classification is proven against actual `env_of`/
`proc_ppid`/`proc_pgid` reads, not a mocked shortcut.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC4-020 | Tagged sleep: `ADT_LANE_ID=<X>` where lane X is registered and DEAD, age ≥ 300s | **would-kill** (rule 2.1 exact-join arm) |
| TC-LGC4-021 | Legacy-sig sleep: `AUTONOMOUS_CONF_LOADED_FROM` set ∧ `CC_USER=autonomous-dev-bot` ∧ `ppid==1`, age ≥ 600s | **would-kill (legacy)** — `would_kill_legacy_signature` counter increments |
| TC-LGC4-022 | Legacy-sig-WITHOUT-CC_USER decoy: `AUTONOMOUS_CONF_LOADED_FROM` set (simulating an operator hand-sourcing `autonomous.conf` in an SSM debug shell), `CC_USER` UNSET, `ppid==1` | **skip** — the `∧` conjunction (not `∨`) means a bare conf-load signature alone never authorizes a kill (design falsekill:F1 / R15) |
| TC-LGC4-023 | `TERM_PROGRAM` decoy: env carries `TERM_PROGRAM=xterm` (or any value) alongside an otherwise-fully-matching tagged lane id | **skip** — rule 2.2 is unconditional and checked before any other rule |
| TC-LGC4-024 | Unknown-lane-id decoy: `ADT_LANE_ID=someproject:dev:9999:1:aaaa` where no such lane dir exists in any project's registry | **skip** (`unknown_class` counter increments) — never treated as "legacy" or killed |
| TC-LGC4-025 | Live-lane daemon: `ADT_LANE_ID=<X>` where lane X's `STATE=live` and `WRAPPER_PID` is a genuinely alive process | **skip** — `lane_probe` on X resolves `live`, so rule 2.1's dead-lane join never matches |
| TC-LGC4-026 | Mid-upgrade legacy LIVE wrapper's daemon: spawn a fake `autonomous-dev.sh`-argv-matching process (the "live wrapper"), then a CHILD of it with `ppid==1`-simulated legacy signature (own `setsid`, no lane dir) | **skip** — rule 2.4's live-wrapper-ancestry gate (`_gc_pgid_in_live_wrapper_ancestry`) protects it even though its ppid/signature would otherwise match rule 2.1's legacy arm |
| TC-LGC4-027 | Crashpad-shaped decoy: a process named/argv'd to look like a Chrome crashpad helper, but carrying a FULLY MATCHING tagged-dead-lane env (`ADT_LANE_ID`) | judged via Pass 2 (env match), same as any other tagged process — **would-kill**, proving classification never keys on the process NAME (design 3.5 "judged by intact env via Pass 2, never by ppid/name") |
| TC-LGC4-028 | Launcher-bridge live wrapper: the "wrapper" process's own argv does NOT literally contain `autonomous-dev.sh` (simulating an exec-chain launcher bridge), but a live member of its OWN process group does | rule 2.3's `pgrep -g $PG -f 'autonomous-(dev\|review)\.sh'` matches on the GROUP, not the single top argv — **no kill** (group excluded) |
| TC-LGC4-029 | Group-member-has-live-wrapper: a dead-lane-tagged process placed in the SAME pgid as a live wrapper-argv process | **skip** — rule 2.3 |
| TC-LGC4-030 | Recorded in a live lane's `pgids` file (even though untagged itself) | **skip** — rule 2.4 first conjunct |
| TC-LGC4-031 | Age floor not yet met: tagged-dead-lane process at age 100s (< 300s floor) | **skip** — rule 2.5 |
| TC-LGC4-032 | Banned-key grep-pin: `adt-gc.sh` never gates a kill decision on `CLAUDE_CODE_SESSION_ID`, bare `kill -0` on a kernel sid, or a `comm`/process-name string match as the SOLE condition | grep-pin: no occurrence of `CLAUDE_CODE_SESSION_ID` in `adt-gc.sh`; every `ppid` read is textually inside a conjunction with the conf+CC_USER signature, never used alone |

## Pass 3 — env-blind classes (AC1)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC4-040 | Chrome (lane-scoped): a process whose argv contains `--user-data-dir=<hint>` where `<hint>` matches a DEAD lane's `CHROME_PROFILE_HINT` | would-kill (rule 3.1) |
| TC-LGC4-041 | Chrome (heuristic): argv `--user-data-dir=/tmp/puppeteer_dev_chrome_profile-X`, `ppid==1`, age > 2h, no live sharer | would-kill (rule 3.2) |
| TC-LGC4-042 | Chrome (heuristic) age < 2h | skip — age gate not met |
| TC-LGC4-043 | Wedged `gh`: argv `gh pr checks --watch`, `GH_TOKEN_FILE=/tmp/agent-auth-XXXX/token` whose dir no longer exists | would-kill (rule 3.3) |
| TC-LGC4-044 | Wedged `gh` whose `GH_TOKEN_FILE` dir still exists | skip — the auth dir being gone is the signal, not merely running `gh pr checks --watch` |
| TC-LGC4-045 | E2E server: process cwd under a dead lane's recorded `WORKTREE` path, and that worktree path no longer exists on disk | would-kill (rule 3.4) |
| TC-LGC4-046 | E2E server whose recorded `WORKTREE` still exists | skip — rule 3.4 requires the worktree to be gone |

## Pass 4 — live-lane sustained-CPU alert (AC1, flag-only, NEVER kill)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC4-050 | A live lane's recorded pgid has a member with cwd under `.worktrees/*/hooks/` and `%cpu` > 80 for TWO consecutive `adt-gc.sh` invocations | `LIVE_BURNER_ALERT` line emitted on the SECOND invocation; `live_burner_alerts` counter increments; **no signal sent** — the process is still alive after the run |
| TC-LGC4-051 | Same shape, but only ONE invocation has observed high CPU so far | no alert yet (the ≥2-consecutive-tick gate) — state file records the first observation |
| TC-LGC4-052 | Same high-CPU shape, but the lane is DEAD (not live) | Pass 4 does not consider it at all — Pass 4 is explicitly live-lane-only; a dead lane's high-CPU member is Pass 2/3's concern, never Pass 4's |

## `.pending-*` + wedged-guardian rm-rf ordering (AC1, rule 1.4)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC4-060 | `.pending-<id>/` dir aged 24h+ (simulated mid-crash mint, wrapper died between `mkdir` and `mv -T`) | `--kill` mode: dir is `rm -rf`'d; `--dry-run`: would-kill logged, dir untouched |
| TC-LGC4-061 | Terminal-state lane aged 24h+ WITH a live `GUARDIAN_PID` | guardian process observed TERM'd (and gone) before the dir stops existing — ordering assertion via a marker file the guardian stub deletes on TERM |

## Singleton lock + `--quick` (AC2)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC4-070 | Two concurrent `adt-gc.sh` (non-quick) invocations against the same `ADT_STATE_ROOT` | the second blocks on `flock -n` and exits 0 immediately (never runs its passes) while the first completes normally — no double-processing of the same lane observed |
| TC-LGC4-071 | `--quick` invoked while a full run already holds the lock | the quick call's `flock -w 3` waits up to 3s rather than bailing immediately (F6 selfdefeat: never starves under load) — proven by making the full run release the lock at ~1.5s and observing the quick call still completes (not skipped) |
| TC-LGC4-072 | `--quick` runs ONLY Pass 1 | grep-pin + behavioral: a Pass-2-only decoy (tagged sleep, no matching Pass-1 lane condition) is untouched by `--quick` but IS classified by a full run |
| TC-LGC4-073 | `--quick` against 50 lane dirs (mix of live/dead/terminal), isolated fresh `ADT_STATE_ROOT` | completes in < 1s (design AC "PR-4 (3)") |

## Log discipline + metrics (AC3)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC4-080 | Every would-kill/kill log line | contains `pid`/`argv` (where applicable)/`lane` (where applicable)/`rule=` fields |
| TC-LGC4-081 | Log file grown to 26 MB before a run | rotates to `adt-gc.log.1` (single generation, mode 600 preserved) — mirrors the [INV-68] dispatch-local.sh log-retention pattern |
| TC-LGC4-082 | `ADT_GC_SUMMARY` line format | matches `ADT_GC_SUMMARY skips=<n> would_kill=<n> killed=<n> would_kill_legacy_signature=<n> unknown_class=<n> live_burner_alerts=<n> elapsed_ms=<n>` — parseable by a simple `key=value` split fixture (the INV-67/INV-70 metrics-collector contract) |
| TC-LGC4-083 | `metrics_emit` best-effort call | when `lib-metrics.sh` is sourced, an `adt_gc_summary` event lands in that project's `metrics.jsonl`; when NOT sourced (simulated stale/absent lib), `adt-gc.sh` still completes cleanly (no abort) |

## `--doctor` (AC per design §4-C5)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC4-090 | `--doctor` on a host with `flock`/`setsid` present, no timer installed, empty `ADT_STATE_ROOT` | exits 0 (WARNs are not failures); reports `[WARN]` for missing timer and empty state root |
| TC-LGC4-091 | `--doctor` with a GC cron marker present (Linux) | reports `[ok] GC timer installed` |
| TC-LGC4-092 | `--doctor` with `_LANE_UNAME_OVERRIDE=Darwin` and no `python3` | reports `[WARN]` for the missing procargs2 shim dependency, still exits 0 |
| TC-LGC4-093 | `--doctor` with `flock` shadowed as absent (`PATH` trick) | reports `[FAIL] flock missing`, exits 1 |

## `install-gc-timer.sh` (AC "install-gc-timer.sh idempotent")

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC4-100 | Fresh install against a stubbed `crontab` (Linux) | one marked line added; existing unrelated crontab content preserved |
| TC-LGC4-101 | Re-run against an already-installed crontab | idempotent — exactly ONE marked line after the second run (never two) |
| TC-LGC4-102 | `--uninstall` | the marked line is removed; unrelated content preserved |
| TC-LGC4-103 | `_LANE_UNAME_OVERRIDE=Darwin`, stubbed `launchctl` | a plist is written to `~/Library/LaunchAgents/com.adt.lane-gc.plist` with `StartInterval=600` and the correct `adt-gc.sh` path; `launchctl bootstrap` invoked |
| TC-LGC4-104 | macOS re-run (idempotent) | `launchctl bootout` invoked before re-`bootstrap` (never a duplicate-load warning path) |
| TC-LGC4-105 | macOS `--uninstall` | `launchctl bootout` invoked, plist file removed |

## BSD `etime`/portability reuse (AC "BSD-age-parser unit test")

`adt-gc.sh` consumes `lib-lane.sh::proc_age`, whose BSD/macOS `[[dd-]hh:]mm:ss`
parser is already regression-pinned by `tests/unit/test-lib-lane.sh`
(TC-LGC2-*). This suite does not duplicate that parser test; TC-LGC4-092
above covers the macOS-specific NEW primitive this PR adds (the procargs2
shim), and `proc_ppid`/`proc_pgid`/`proc_argv` each get a direct unit test
(TC-LGC4-110..113 below) since they are new to this PR.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC4-110 | `proc_ppid` against the calling shell's own `$$` | echoes `$PPID` |
| TC-LGC4-111 | `proc_pgid` against a `setsid`-spawned process | echoes that process's own pid (session/group leader) |
| TC-LGC4-112 | `proc_argv` against a process with a multi-word argv | one element per line, in order, matching the spawned argv exactly |
| TC-LGC4-113 | `env_lookup` against a process with `FOO=bar` in its env | echoes `bar`; echoes nothing + rc 1 for an absent key |
| TC-LGC4-114 | `_procargs2_py`'s pure parser against a SYNTHETIC procargs2-shaped buffer (argc=2, exec_path, argv[0], argv[1], envp with 1 entry) | `ARGV`/`ENV` sections split correctly — proves the parser logic without a real macOS `sysctl` call (design §11 "macOS ACs decision" — unit-testable on Linux CI) |

## Opportunistic `--quick` wiring in `dispatch-local.sh`

| ID | Scenario | Expected |
|----|----------|----------|
| TC-LGC4-120 | grep-pin: `dispatch-local.sh` calls `adt-gc.sh --quick` before `kill_stale_wrapper` | source-of-truth line-order assertion |
| TC-LGC4-121 | `dispatch-local.sh` runs successfully when `adt-gc.sh` is DELETED/absent (simulated stale skill tree) | the `|| true` guard means dispatch still proceeds — never a hard dependency |
