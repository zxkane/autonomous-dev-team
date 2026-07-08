# Design: Lane Containment & Garbage Collection for the Autonomous Pipeline

**Status:** Final (rev 3). Rev 2 was adversarially re-attacked from five lenses (timing/signals, false-kill, platform-reality, completeness, self-defeat/operations); 28 findings were confirmed against the running code and the live wrapper host. All 28 are integrated into the design below — no "known issues" section; the mechanisms are correct as specified. Lens-by-lens ledger in §13.

> **Public-artifact note:** this document references only this repository's own files, line numbers, issues, and invariants. Consumer projects are referred to generically ("an onboarded project", "the wrapper host", "one consumer project uses a launcher bridge", "the one legacy-style checkout") per the repo's public-artifact policy.

---

## 1. Problem statement

Wrappers spawn deep process trees (agent CLI → MCP servers → Chrome → E2E servers → token daemons). Reclamation today depends on (a) traps that never run under SIGKILL/OOM/crash, (b) TERM-only group kills that some children trap (`lib-agent.sh:306` documents this) and others escape entirely (Chrome re-setsids; some CLI workers re-setpgid), and (c) a dispatcher sweep that fires only on same-issue re-dispatch and matches only wrapper-script argv (`dispatch-local.sh:254-270`). Result: monotonic accumulation of PPID=1 orphans (observed: 26–58 days old, hundreds of processes, load 241, swap full), with a positive feedback loop — pressure kills more wrappers non-gracefully, each death sheds a new batch.

Root causes, corroborated by code and live autopsy:

1. **RC1** — Non-graceful death skips all teardown (traps never run).
2. **RC2** — Kill paths are TERM-only; KILL escalation exists only in `kill_stale_wrapper` and is gated on **leader** liveness (`dispatch-local.sh:174`, `:269`), so TERM-trapping children whose leader died never get KILLed.
3. **RC3** — Children escape the process group (Chrome re-setsid, CLI heap workers re-setpgid, daemonized E2E servers) — `kill -- -PGID` cannot reach them. (INV-104's `ADT_FANOUT_LANE_MARKER` sweep already closes this for review fan-out agents post-verdict; nothing covers the dev side, crash paths, or non-fan-out spawns.)
4. **RC4** — The only sweep is per-issue + wrapper-argv-scoped; MCP/browser/sleep/E2E residue carries no matchable marker and is never reclaimed, especially for issues that reach terminal state.
5. **RC5** — `sleep 99999` keepalives (the `tests/unit/test-token-split-234.sh:152` fixture daemon stub plus the real token daemon's monolithic sleep at `gh-token-refresh-daemon.sh:67`) orphan on every group-killed test run.
6. **RC6** *(added rev 3, completeness lens F2)* — CPU-burner descendants inside a **still-live** lane have no reap path. The load-241 incident was proximately driven by four spinning git-hook processes (`input=$(cat)` on EOF'd stdin, 98.8% CPU, >10 h) running under a **live** agent; every reap component in this design is death-triggered, so a live-lane CPU burner is invisible to them. This is addressed by source-fix + a flag-only sustained-CPU alert (C8, §4-C8), never by killing under a live lane.

Hard constraints: no containers; core mechanism portable Linux+macOS (bash ≥ 4, no /proc-dependence in the core, no cgroup/prctl dependence); **false-positive kills are worse than slow leaks** — operator interactive sessions, other projects' live lanes, and unrelated processes must be untouchable; fits the existing PID-file/heartbeat/label architecture and the INV culture; ships as independently useful PRs through the pipeline itself.

---

## 2. Design principles

1. **The lane is the unit of ownership.** Every wrapper run mints one lane; every long-lived descendant is attributable to exactly one lane.
2. **Registry is the driver; env-tag is the confirmer.** Kill decisions join against durable on-disk state written *before* spawn, not against process-table heuristics. Env/argv evidence confirms membership; it never solely authorizes a kill. On macOS the confirmer degrades to a diagnostic (§7, F2) — registry authority is deliberate.
3. **No single reaper is load-bearing.** Guardian (fast, per-lane) and periodic GC (slow, box-wide) each fully cover the other's death.
4. **Every kill escalates**: TERM → bounded grace → KILL, completion keyed on **group/scope emptiness**, never leader liveness. TERM always precedes KILL so agent exit-143 attribution (INV-26 Fix A) survives.
5. **Fail toward leaking, never toward killing.** Unparseable registry, suppressed env, ambiguous ancestry ⇒ skip. `TERM_PROGRAM` in env ⇒ unconditional skip. Live-lane CPU burners are alerted, never killed.
6. **State transitions are load-bearing, not just values.** Every state-carrying operation names its transition, its lock, and its atomic operator; there are no "the wrapper has minted but not yet written" gaps. Atomic install via `lanes/.pending-<id>/` + `mv`, `STATE=cleaning` before reap, `reap.lock` shared between guardian/GC/lane_kill/kill_stale — see §4-C1/C3/C4.
7. **FIFO open ordering is a contract.** The wrapper opens the write end of `guard.fifo` **before** spawning the guardian, so no non-graceful death between spawn and open can strand the guardian in a blocking open (see §4-C3 F2 fix).
8. **Prevention where the platform allows it** (Linux cgroup scopes defeat re-setsid structurally), **but the portable path must be sufficient alone**.

---

## 3. Architecture

```
                dispatcher host (remote, SSM)                    wrapper host
 ┌──────────────────────────────┐        ┌────────────────────────────────────────────────────────┐
 │ dispatcher-tick.sh           │  SSM   │ dispatch-local.sh                                      │
 │  Steps 0-5 (labels, pid_alive│───────▶│  [C6] back-pressure gate ──defer(75)──▶ defer ledger   │
 │  probe via SSM snippet;      │        │  [C5] adt-gc.sh --quick (opportunistic)                │
 │  DEFERRED branch in Step 5b) │        │  kill_stale_wrapper → lane_kill (registry-first)       │
 └──────────────────────────────┘        │  nohup wrapper &                                       │
                                         └───────────────┬────────────────────────────────────────┘
                                                         ▼
                    ┌────────────────────────────────────────────────────────────────────┐
                    │ WRAPPER (autonomous-dev.sh / autonomous-review.sh)                 │
                    │  mint ADT_LANE_ID ── write .pending-<id>/ ── mv → lanes/<id>/      │
                    │  mkfifo guard.fifo                                                 │
                    │  exec {GFD}<> guard.fifo          (SOLE write-fd holder — OPEN     │
                    │                                    BEFORE guardian spawn)          │
                    │  setsid bash lib-guardian.sh (session-detached, holds read end)    │
                    │        │                                                           │
                    │  lane_spawn ─ backend probe:                                       │
                    │   ├── [Linux+bus+linger] systemd-run --user --scope -p TasksMax    │
                    │   │                       -p MemoryMax … → setsid … {GFD}>&-       │
                    │   └── [portable] setsid timeout --kill-after=30s TERM $T …  {GFD}>&-│
                    │  every spawn appends PGID→ registry pgids; exports ADT_LANE_ID     │
                    │  (agent CLI, fan-out lanes, E2E, smoke, heartbeat, token daemons)  │
                    └───────────────┬──────────────────────────────┬─────────────────────┘
                          any death │ (fd closed by kernel,        │ graceful exit
                          incl. -9  │  incl. SIGKILL/OOM)          │ cleanup(): flock+reap-first,
                                    ▼                              ▼ STATE=cleaning → clean-exit,
                    ┌───────────────────────────┐    ┌──────────────────────────────┐
                    │ GUARDIAN (per lane)       │    │ lane registry (durable)      │
                    │  read <&3  → EOF ≈ 25ms   │◀──▶│ $ADT_STATE_ROOT/autonomous-  │
                    │  reap.lock (shared)       │    │  <project>/lanes/<id>/       │
                    │  lane_kill: TERM→10s→KILL │    │  {lane, pgids, guard.fifo,   │
                    │  + tag/argv escape sweep  │    │   guardian.log, reap.lock}   │
                    │  no-writer watchdog       │    └───────────▲──────────────────┘
                    │  self-exit, chunked cap   │                │ joins
                    └───────────────────────────┘                │
                    ┌────────────────────────────────────────────┴───────────────────┐
                    │ adt-gc.sh  (cron */10 Linux · launchd StartInterval=600 macOS  │
                    │             · opportunistic from dispatch-local)               │
                    │  Pass 1: registry-driven (dead lane ⇒ lane_kill)  [no env need]│
                    │  Pass 2: tagged-orphan sweep (5-way conjunction)               │
                    │  Pass 3: env-blind classes (chrome argv, wedged gh, E2E srv)   │
                    │  Pass 4: flag-only sustained-CPU alert (live-lane burner)      │
                    │  flock singleton · --dry-run default until soak complete       │
                    │  self-rotates log >25MB · ADT_GC_SUMMARY metrics line          │
                    └────────────────────────────────────────────────────────────────┘
```

**Four defense layers → five capabilities:** Prevention = scope/pgid containment + fd hygiene + per-lane TasksMax/MemoryMax + source-fixed spinners (C7/C8). Detection = registry ⋈ env-tag/argv (C1/C2). Reclamation = guardian (C3) + periodic GC (C5) + escalating kill paths (C4). Back-pressure = admission gate (C6). Live-lane visibility = Pass-4 alert (C8/C5).

---

## 4. Component specifications

### C1. Lane identity, registry, and the `lib-lane.sh` abstraction

New lib `skills/autonomous-dispatcher/scripts/lib-lane.sh` (a `lib-*.sh` — consumers pick it up via the `readlink -f` LIB_DIR resolution; **no installer re-run needed**). Public functions: `lane_mint`, `lane_install`, `lane_spawn`, `lane_record_pgid`, `lane_kill`, `lane_probe`, `lane_set_state`, plus portability shims `proc_age`, `proc_start_time`, `proc_fingerprint`, `env_of`, `file_mtime`.

**Lane ID (canonical tag):**

```
ADT_LANE_ID=<PROJECT_ID>:<role>:<issue>:<start-epoch>:<rand4>
            e.g.  myproj:dev:361:1783059974:a1f3
role ∈ {dev, review}          # ONE lane per wrapper run (resolution R3, §12)
```

Sub-lanes inside a run (fan-out agents, E2E, smoke, daemons) share the wrapper's `ADT_LANE_ID` and additionally export `ADT_LANE_ROLE` (`fanout:<agent>`, `e2e`, `smoke`, `daemon`) for diagnostics. `rand4` disambiguates same-second re-dispatch. Filesystem/systemd-safe form `lane_id_fs` replaces `:` with `.`.

**State root (canonical, F1 completeness lens):**

```bash
: "${ADT_STATE_ROOT:=$HOME/.local/state}"      # NEVER XDG_STATE_HOME
export ADT_STATE_ROOT
```

`ADT_STATE_ROOT` is canonicalized identically in `lib-lane.sh`, `adt-gc.sh`, `install-gc-timer.sh`, and every wrapper — `XDG_STATE_HOME` is **deliberately ignored** because the wrapper may run under an SSM sudo login shell that inherits an operator's XDG override while cron/launchd runs under a minimal env. Divergence would silently scan an empty path and report `0 would_kill`, indistinguishable from success. `adt-gc.sh --doctor` fails loud when `ADT_STATE_ROOT` on a host that has run a wrapper contains no `autonomous-*/lanes/` subtree.

**Registry layout** (dir-per-lane; sibling of the existing PID files — the natural anchor identified in forensics):

```
$ADT_STATE_ROOT/autonomous-<PROJECT_ID>/lanes/<lane_id_fs>/
├── lane          # KV, flock-guarded, rewrite-then-mv (atomic)
├── pgids         # append-only: "<pgid> <role> <epoch>"  — one write(2) per line ≤ PIPE_BUF (512B floor); do not widen schema without flock
├── guard.fifo    # guardian pipe (C3)
├── guardian.log  # guardian's own log (never touched by INV-68 log rotation)
└── reap.lock     # shared reap serialization (C3/C4, selfdefeat F3)
```

`lane` file keys (flat KEY=VAL, bash-parseable, no jq dependency):

```
LANE_ID=            PROJECT_ID=         ISSUE=              ROLE=dev|review
MODE=new|resume     BACKEND=pgid|systemd-scope              UNIT=<scope name or ->
WRAPPER_PID=        WRAPPER_START=<`ps -o lstart=` string>
WRAPPER_START_TICKS=<Linux /proc/PID/stat f22 or ->
WRAPPER_FINGERPRINT=<sha256(comm+ppid+lstart)>              # macOS PID-recycle guard (F7 timing)
GUARDIAN_PID=       WORKTREE=<abs path or ->                CHROME_PROFILE_HINT=<path or ->
CREATED_EPOCH=      STATE=live|cleaning|reaping|clean-exit|reaped-by-guardian|gc-reaped
```

**Atomic mint / install (F1 timing — closes the pre-existence race, satisfies principle 6):**

```bash
lane_install() {
  local id_fs=$1
  local pending="$LANES_ROOT/.pending-$id_fs"
  local final="$LANES_ROOT/$id_fs"
  mkdir -p "$pending"
  # Write everything the delegate path (kill_stale, GC Pass 1) needs to make a decision:
  #   LANE_ID, PROJECT_ID, ISSUE, ROLE, WRAPPER_PID, WRAPPER_START, WRAPPER_FINGERPRINT,
  #   CREATED_EPOCH, STATE=live. GUARDIAN_PID is filled after guardian spawn (row-3 update).
  printf '%s\n' "$LANE_KV" > "$pending/lane"
  : > "$pending/pgids"
  : > "$pending/reap.lock"
  mv -T "$pending" "$final"        # POSIX rename — atomic when same fs
}
```

If the wrapper dies non-gracefully **after** `lane_install` returns, the directory always contains a parseable `lane` file with `WRAPPER_PID` + `WRAPPER_START` + `CREATED_EPOCH` + `STATE=live` — Pass-1 rules 1.1 (live-check) or 1.3 (dead-check) always apply. If the wrapper dies **before** `mv -T` completes, `.pending-*` is never observed by any consumer (no other component scans `.pending-*`) and is cleaned up by rule 1.4 after 24 h.

**Delegate behavior on partial state (F1):** `kill_stale_wrapper`'s `lane_kill` delegate probes for `WRAPPER_PID`+`WRAPPER_START` inside the lane file; on parse failure or missing required keys it **falls through to the pre-existing kill_stale_wrapper legacy path** (not to lane_kill's registry-authoritative branch), so a torn write can never brick a re-dispatch. `lane_kill` re-checks the parse before every action.

Rules:

- Registry is written **before ANY background child is spawned, including token daemons, heartbeat, and pre-agent utilities** (INV-107 tightening; falsekill lens F6). The token daemons at `lib-auth.sh:128, :255-258` — which today fire before `_run_with_timeout` — must have a live registry to write PGIDs into.
- `_run_with_timeout` appends `_AGENT_RUN_PID` to `pgids` **in addition to** the existing `AGENT_PID_FILE` write; review fan-out sidecar PGIDs and the E2E lane PGID are appended too — PGIDs now survive the mid-run `rm -rf $_FANOUT_DIR` and wrapper death (closes the crash-path PGID-loss hole).
- Liveness of a lane = `WRAPPER_PID` alive **AND** its start time string-matches `WRAPPER_START` (PID-recycle defense; Linux fast path compares starttime ticks; **macOS additionally requires `WRAPPER_FINGERPRINT` match** — see F7 below). Never sid-liveness (SSM lanes share the always-alive ssm-agent session), never `CLAUDE_CODE_SESSION_ID` (reused across resumes).
- **macOS PID-recycle fingerprint (F7 timing):** on macOS `ps -o lstart=` has 1-second granularity and PID recycle is fast, so lstart-only match false-positives operator processes as the dead lane. `WRAPPER_FINGERPRINT=sha256(comm‖ppid‖lstart)` at mint time; rule 1.1 combines lstart-match **and** fingerprint-match on macOS. Linux uses the /proc/PID/stat starttime tick fast path (µs granularity) and does not need the extra hash.
- Graceful `cleanup()` reaps under `reap.lock`, sets `STATE=cleaning`, then `STATE=clean-exit`; lane dirs in a terminal state are removed by GC after 24 h (audit trail).
- Existing PID-file/heartbeat contracts (INV-23/24/29) are **unchanged**; the registry is additive. `kill_stale_wrapper` prefers `lane_kill` when a parseable lane file exists (this also bypasses the review-PID-file-holds-`$$` ESRCH no-op), falling back to its current behavior for pre-upgrade lanes.

**Backend selection** (probed once per wrapper, recorded in `BACKEND` so kill-side never re-guesses; **includes linger lifetime gate**, platform lens F3):

```bash
_lane_backend() {
  if [[ $(uname -s) == Linux ]] && command -v systemd-run >/dev/null 2>&1; then
    local xdg="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    # Linger MUST be enabled — otherwise last-operator-logout tears down user@.service
    # and cascade-SIGKILLs every enrolled scope (fleet-wide mass-kill event, F3).
    if [[ $(loginctl show-user -p Linger --value 2>/dev/null || echo no) != yes ]]; then
      _lane_warn "systemd-scope backend requires 'loginctl enable-linger \$USER'; falling back to pgid"
      echo pgid; return
    fi
    if [[ -S "$xdg/bus" ]] && XDG_RUNTIME_DIR="$xdg" \
         systemd-run --user --scope --quiet -- true 2>/dev/null; then
      echo systemd-scope; return
    fi
  fi
  echo pgid
}
```

### C2. Universal tagging — env-tag naming and matching rules

**Export rule (INV-107/108 — tightened, falsekill F6):** `ADT_LANE_ID` is exported in the wrapper's main shell **before ANY background child is spawned, including token daemons at `lib-auth.sh:128,:255-258`, heartbeat, and pre-agent utilities** — not merely "before the first spawn returns". It is therefore inherited by the agent subtree, all MCP servers, heartbeat, both token daemons, fan-out lanes, E2E command and browser lanes, and **smoke probes (which today carry zero marker)**. This generalizes the shipped fan-out-reap invariant (the recorded-descendant sweep introduced by #360 and cited as the precedent for this design) from review-fan-out-post-verdict-only to all ten spawner classes, dev side included, and to crash paths where the shipped sweep's call site never runs.

**Matching rules:**

| Evidence | Read mechanism | Authorizes |
|---|---|---|
| `ADT_LANE_ID=<X>` exact NUL-delimited line | Linux: `tr '\0' '\n' </proc/PID/environ`; macOS: **`sysctl kern.procargs2` via `python3` shim (F2 platform)** parsing the argc-delimited layout — NOT `ps eww` | membership in lane X (kill only if lane X is dead per registry) |
| Legacy signature: `AUTONOMOUS_CONF_LOADED_FROM=` present **AND** `CC_USER=autonomous-(dev\|review)-bot` | same | pre-upgrade pipeline residue (F1 falsekill: **∧ not ∨** — bare `AUTONOMOUS_CONF_LOADED_FROM` also fires from operator-sourced `autonomous.conf`, so it can't authorize alone; `CC_USER=autonomous-*-bot` is set only inside the two wrapper entry points at `autonomous-dev.sh:222` and `autonomous-review.sh:628`, so the conjunction requires an actual wrapper ancestor) |
| `TERM_PROGRAM=` present | same | **unconditional skip** (operator; fail-safe even if an operator hand-runs a wrapper from tmux — that residue is deliberately not collected) |
| `ADT_LANE_ID=<X>` where lane X is **not present** in the registry at all | same | **unconditional skip** (F2 falsekill: unknown lane id ⇒ leak, never kill — protects mid-upgrade / cross-project mis-tags) |
| `CLAUDE_CODE_SESSION_ID`, kernel sid, bare `ppid==1`, comm name | — | **banned as kill keys** (each empirically false-positives: resume reuse; shared SSM session; crashpad-of-live-chrome) |

**macOS env-read seam (platform F2 — hard):** `ps eww -o command=` concatenates cmdline and environ with no delimiter, so a token shaped like `VAR=value` in argv is byte-indistinguishable from env; using `ps eww` for authorization would misclassify operator processes with tag-shaped argv substrings as pipeline residue and would also mis-observe `TERM_PROGRAM`. The `env_of` shim on macOS therefore uses `sysctl kern.procargs2` (whose header carries `argc`, letting argv and envp be separated cleanly) via a ~30-line `python3` shim shipped alongside `lib-lane.sh`. Until that parser is present on a given host, **macOS GC is registry-authoritative only** — env-tag matches are `--dry-run` diagnostic output, never `--kill` authorization; §7 marks this explicitly.

**Env-read gate (platform F5):** `env_of` **must** gate on `[ -r /proc/PID/environ ]`, never `[ -s ]` — `stat -c %s /proc/PID/environ` returns 0 even on readable non-empty environs. A grep-pin test forbids `[[ -s /proc/*/environ ]]` in `lib-lane.sh` and `adt-gc.sh`.

**Chrome exception** (Chrome mains clobber their environ region — 0 readable env lines; crashpad retains env): handled by **argv**, two tiers:

1. *Primary (exact):* export `TMPDIR="$LANE_SCRATCH/tmp"` (the INV-100 per-lane scratch namespace) before the agent spawn, so puppeteer's profile dir lands at `…/tmp/puppeteer_dev_chrome_profile-XXXX` **inside the lane scratch path** — Chrome's `--user-data-dir` argv then carries a lane-unique path, matchable with `pgrep -f -- "$LANE_SCRATCH/"`. Record it as `CHROME_PROFILE_HINT`.
2. *Fallback (heuristic, GC Pass 3 only):* argv contains `--user-data-dir=/tmp/puppeteer_dev_chrome_profile-` ∧ `ppid==1` ∧ age > 2 h ∧ no live process shares that profile dir ∧ no live chrome-devtools-mcp parent. (Operator chromes have a live MCP parent, so ppid≠1 — validated live.)

**Token-security rider:** token daemons get GH token **values** scrubbed from their env at spawn (they need only `GH_TOKEN_FILE` paths) — closes the live-PAT-in-27-day-old-environ finding.

**Coverage note (completeness F6):** token daemons and the heartbeat subshell share the wrapper's PGID (which is dispatch-local's PGID); appending their PGID to `pgids` would false-attribute the wrapper's own group. They are therefore **not PGID-recorded** — coverage is env-tag escape sweep only, plus the C8 PPID-watchdog for the token daemon and the FIFO EOF for the heartbeat. This is a deliberate architectural choice, called out in §5 and §10.

### C3. Guardian sidecar — pipe-EOF death watch (RC1)

**FIFO open ordering — reversed from rev 2 (F2 timing, principle 7):** the wrapper opens its write fd **before** spawning the guardian, so the guardian's blocking `open` for read always finds a writer already present:

```bash
mkfifo "$LANE_DIR/guard.fifo"
exec {ADT_GUARD_FD}<>"$LANE_DIR/guard.fifo"           # <> never blocks; O_RDWR counts as write end
export ADT_GUARD_FD                                   # SOLE write-fd holder
setsid bash "$LIB_DIR/lib-guardian.sh" --lane-dir "$LANE_DIR" \
    </dev/null >>"$LANE_DIR/guardian.log" 2>&1 &      # setsid is a HARD prerequisite on both platforms
lane_set GUARDIAN_PID $!
```

**`setsid` is a hard prerequisite on both platforms** (platform F1). Without `setsid`, the guardian inherits the wrapper's PGID and any group-scoped SIGKILL (e.g. `kill_stale_wrapper`'s `kill -9 -- -PGID` at `dispatch-local.sh:176`) kills wrapper **and** guardian together — on macOS the routine re-dispatch path becomes the guardian death path, degrading the fast reaper to GC-only (~15 min). Rev 2's `& disown` fallback is dropped. macOS installs `setsid` via `brew install util-linux` (the same keg that ships `flock`, which is already mandatory per `lib-agent.sh:586`). SKILL.md and `adt-gc.sh --doctor` both fail loud if `setsid` is missing.

**FD hygiene (load-bearing, empirically verified):** the wrapper must be the **sole** write-fd holder. Every background spawn site adds `{ADT_GUARD_FD}>&-`: `_run_with_timeout`'s agent spawn, heartbeat subshell, both token daemons, each fan-out subshell, E2E lanes, smoke probes, `tee`. An inherited write fd defers EOF until the last holder dies (confirmed both ways on the reference box; sole-holder EOF ~1 ms, inherited defers to last-close as spec'd); a forgotten close **degrades** semantics from "wrapper died" to "subtree died" — still correct, just later.

**Honest wording of the fd-hygiene regression guard:** the grep-based unit test scans literal `&`-spawn sites in the shipped scripts for the `{ADT_GUARD_FD}>&-` close; it **guards literal sites only** and cannot catch syntactic variants (pipeline subshells, `bash -c '…'` strings, dynamically constructed commands). A missed site is a graceful degradation, not a false kill, and §10 residuals list this explicitly (previous "guards regressions" wording was an over-claim, F6 timing).

Guardian body (`lib-guardian.sh` — deliberately `lib-*` named so the installer never symlinks it):

```bash
exec 3<"$LANE_DIR/guard.fifo"                  # opens instantly — wrapper's <> already provides writer

# No-writer watchdog (F2 timing): if guardian ever finds itself alone on the FIFO
# (wrapper died between mkfifo and <> — pre-F2 window; also defensive against
# accidental future reorderings), self-exit rather than parking for 5 h.
if ! _guard_writer_present; then
  # 15 s grace — a healthy wrapper opens <> and exports before we get here in nanoseconds
  ( sleep 15; _guard_writer_present || kill -USR2 $$ ) &
  trap 'exit 0' USR2
fi

# Hard lifetime cap — chunked, PPID-checked (selfdefeat F5: SIGKILL-survivable sleep is
# exactly the anti-pattern C8 fixes in the token daemon; symmetry required).
_cap_secs=$(( ${AGENT_TIMEOUT_SECONDS:-14400} + 3600 ))
( _n=0
  while (( _n < _cap_secs )); do
    kill -0 "$$" 2>/dev/null || exit 0        # guardian gone → chunk-watchdog exits
    sleep 60; _n=$(( _n + 60 ))
  done
  kill -USR1 $$
) & wd=$!
trap 'do_reap; exit 0' USR1
read -r _ <&3 || true            # EOF ⇒ wrapper dead by ANY means (SIGKILL/OOM incl.); ~25ms measured
do_reap; kill "$wd" 2>/dev/null; exit 0
```

`do_reap` (idempotent; **flocks `reap.lock`**, F3/F4 selfdefeat) — shared with `lane_kill` and `cleanup()` so a re-dispatch can't run two reaps in parallel:

```bash
do_reap() {
  exec 8>"$LANE_DIR/reap.lock"
  flock -n 8 || return 0                     # someone else is reaping this lane
  local st; st=$(lane_get STATE)
  case $st in
    clean-exit|cleaning|gc-reaped|reaped-by-guardian) return 0 ;;   # broadened skip (F4 timing)
  esac
  lane_set STATE reaping
  # ENOENT tolerance (F4 selfdefeat): rule 1.4 may have rm -rf'd the dir out from under us
  # after killing the guardian first — treat any missing artifact as "someone finished".
  [[ -d "$LANE_DIR" ]] || return 0
  # 1) cgroup fast path (C7); else per-pgid TERM→10s→KILL over pgids file
  # 2) escape sweep: env-tag match on THIS lane's ADT_LANE_ID only (F3 falsekill —
  #    guardian A given a process carrying lane B's tag MUST skip), TERM → 2 s → KILL
  #    per hit, always excluding $$, guardian's own pgid, and any pid whose env contains
  #    TERM_PROGRAM
  lane_set STATE reaped-by-guardian
  rm -f "$LANE_DIR/guard.fifo"
}
```

Graceful path: `cleanup()` performs its own reap, **taking the same `reap.lock`**, sets `STATE=cleaning`, reaps under the lock, promotes to `STATE=clean-exit`, **then** `printf 'done\n' >&$ADT_GUARD_FD; exec {ADT_GUARD_FD}>&-` — guardian wakes, sees a terminal state, exits without work. The handshake is sent **before** any network work in cleanup, so a TERM-trap escalator KILLing the wrapper mid-network won't leave the guardian to double-reap active pgids (F4 timing). Re-dispatch: each dispatch mints a fresh lane; `kill_stale_wrapper`'s KILL of the old wrapper closes the old write fd → the **old** guardian reaps that round's escapees under `reap.lock`, and the delegate's own `lane_kill` blocks on the same lock (F5 timing) so W2's spawn is gated on old-guardian completion, eliminating the recycled-pgid-eats-W2's-group tail. Guardian death (it is ~1 page of bash blocked in `read`, minimal OOM badness): GC Pass 1 performs the identical `do_reap` under `reap.lock`. The guardian never sets pdeathsig relative to the wrapper — it must **outlive** it.

**Guardian escape sweep AC pin (F3 falsekill, load-bearing):** PR-5 asserts that guardian A given a process carrying lane B's `ADT_LANE_ID` skips it — the sweep is *this lane only*, never a lane-wide free-for-all.

### C4. Kill choreography — every path escalates (RC2)

Shared helper in `lib-lane.sh` (the minimal-diff primitive, adopted verbatim as the building block):

```bash
_kill_group_escalate() {   # $1=pgid  $2=grace_secs(default 5)
  local pg=$1 g=${2:-5} i
  kill -TERM -- "-$pg" 2>/dev/null || return 0
  for ((i=0; i<g; i++)); do kill -0 -- "-$pg" 2>/dev/null || return 0; sleep 1; done
  kill -KILL -- "-$pg" 2>/dev/null || true
}
```

**Signal choreography table (normative):**

| # | Path | Trigger | Sequence | Grace | Completion gate |
|---|---|---|---|---|---|
| 1 | Wrapper TERM trap (`install_agent_sigterm_trap`) | SIGTERM to wrapper | TERM to **every registry-recorded pgid** (not just `_AGENT_RUN_PID` — fixes the review-side dead arm) + `pkill -TERM -P $$` (**pinned narrow — never widened to `-f script-name`, F5 falsekill, would cross-kill sibling lanes**); then backgrounded escalator KILLs surviving groups | 5 s | group `kill -0 -- -pg` |
| 2 | `cleanup()` EXIT trap (both wrappers) | any wrapper exit incl. set-e | Take `reap.lock`; set `STATE=cleaning`; **reap first**: `_kill_group_escalate` over recorded pgids (dev gains its first-ever post-run reap; review gains the crash-path reap) → rm PID/heartbeat → send FIFO handshake → set `STATE=clean-exit` → network work **last**, each call bounded `timeout 60` (feature-detected; unwrapped+WARN without timeout) | 5 s per group; 60 s per network call | group emptiness |
| 3 | `lane_kill` (guardian, GC, `kill_stale_wrapper` delegate) | lane dead / re-dispatch | **Take `reap.lock` (bounded wait grace+2 s if lane's `GUARDIAN_PID` alive ∧ `STATE=reaping`)**; scope: `systemctl --user kill -s TERM $unit` → poll `cgroup.procs` → `echo 1 > …/cgroup.kill`; pgid: TERM group → poll → KILL group → tag/argv escape sweep (TERM → 2 s → KILL each) | 10 s (kill_stale keeps its existing 5 s) | cgroup.procs empty / group ESRCH |
| 4 | `kill_stale_wrapper` gate fix | same-issue re-dispatch | existing choreography, but the KILL escalation gate at `dispatch-local.sh:174` (and the pgrep-fallback loop at `:269`) changes from leader `kill -0 $old_pid` to **`kill -0 "$old_pid" ∥ kill -0 -- "-$old_pid"`** — TERM-trapping members whose leader died now get the KILL pass. Delegate blocks on `reap.lock` before spawning W2 (F5 timing) | 5 s | leader **or group** liveness |
| 5 | coreutils `timeout --kill-after=30s` | wall-clock cap | unchanged (in-group backstop) | 30 s | n/a |
| 6 | GC victim (Pass 2/3) | decision table §6 | Take `reap.lock` (non-blocking; skip if held); TERM → 10 s → KILL, per-pgid where known else per-pid | 10 s | pid gone |

**Exit-code attribution (preserves INV-26 Fix A):** every path is TERM-first, so compliant agents still exit 143 (attributed to dispatcher/self-induced termination, no retry-budget burn). The invariants doc gains one sentence: rc = 137 produced by a bounded escalation that followed a pipeline TERM is likewise self-induced, not a crash. GC never generates wrapper exit codes at all (it only touches DEAD-lane residue).

### C5. `adt-gc.sh` — periodic, issue-independent GC (RC4, RC5 backstop; live-lane visibility Pass 4)

New **entry-point** script `skills/autonomous-dispatcher/scripts/adt-gc.sh` (⇒ PR carries the `## Post-install / upgrade` installer-rerun note). Singleton via `exec 9>"$ADT_STATE_ROOT/adt-gc.lock"; flock -n 9 || exit 0`. Modes: `--dry-run` (default until soak sign-off), `--kill`, `--quick` (Pass 1 only, `flock -w 3` to avoid thundering-herd starve; F6 selfdefeat), `--doctor` (probes timers, linger, flock, backend, `setsid`, `python3` on macOS, `ADT_STATE_ROOT` content on a wrapper-run host — F1 completeness).

Passes: **Pass 1** registry-driven (needs no env reads — this is why the registry is the driver: macOS hardened-runtime env suppression degrades only the confirmer); **Pass 2** tagged-orphan sweep; **Pass 3** env-blind classes; **Pass 4** live-lane sustained-CPU alert (flag-only, F2 completeness). Decision table in §6.

**Log discipline (F8 selfdefeat):** one box-wide path `$ADT_STATE_ROOT/adt-gc.log` (both §4-C5 and §5 name this exact path — the earlier §5-vs-§4 divergence is resolved). At entry `adt-gc.sh` self-rotates when the log exceeds 25 MB (single-generation `.1` rotation, mirrors INV-68 — never touches per-lane `guardian.log`). Every kill/would-kill logged with full evidence (pid, argv head, lane, rule id, decision).

**Metrics integration (F8 completeness):** every run emits a single trailing line

```
ADT_GC_SUMMARY skips=<n> would_kill=<n> killed=<n> unknown_class=<n> live_burner_alerts=<n> pass=<1|2|3|4> elapsed_ms=<n>
```

which the existing INV-67 metrics collector already ingests via prefix match. During the PR-8 soak, an alert fires when any daily `would_kill_legacy_signature > 0` OR when `unknown_class` climbs — this is the mechanism §10 previously lacked and the mechanism PR-8 sign-off consumes.

**Timer wiring — box-wide, idempotent:** ship `install-gc-timer.sh` (F3 completeness) as an **entry-point** script — Linux edits crontab (`*/10 * * * * bash $ABS/adt-gc.sh >> $ADT_STATE_ROOT/adt-gc.log 2>&1`, with a fixed marker line so re-runs replace instead of stacking); macOS drops `~/Library/LaunchAgents/com.adt.lane-gc.plist` (`StartInterval=600`, `ProgramArguments=[<brew-bash>, …/adt-gc.sh]`) and calls `launchctl bootstrap gui/$(id -u)`. Cron chosen over a systemd user timer on Linux because it works without linger; cron on macOS avoided because it trips TCC prompts. One timer per **box** pointing at the skill tree, not per project — matched by `--doctor`. **Rollout adds a hand-invocation line for the one legacy-style checkout** whose `scripts/` does not receive `install-project-hooks.sh` (see §9 ops sequencing) — the installer materializes the entry-point everywhere else.

Opportunistic `adt-gc.sh --quick || true` at the top of every `dispatch-local.sh` run means busy boxes self-clean even with no timer installed. Self-match safety: `grep -vw $$` + bracketed patterns (`autonomous[-]`) — the pkill-self-kill incident is a regression test.

### C6. Back-pressure admission gate (amplifier) — with remote DEFERRED plumbing

> **Amendment (2026-07-08, #441):** the swap-used% signal's independence assumption below was revised — it false-positived on large-RAM hosts with stale swap accumulation unrelated to dispatcher-managed processes. The signal now also requires `MemAvailable` to be below a headroom multiple of `GATE_MIN_MEM_MB` before it fires. This section is the historical parent design and is not rewritten in place; see `docs/designs/back-pressure-swap-mem-headroom-441.md` and INV-119's amendment note (`docs/pipeline/invariants.md`) for the current behavior.

In `dispatch-local.sh`, before `kill_stale_wrapper`/spawn:

- **Signals:** `load1/ncpu > ${GATE_LOAD_PER_CORE:-3}` (`/proc/loadavg` ∥ `sysctl -n vm.loadavg`; `nproc` ∥ `sysctl -n hw.ncpu`); `MemAvailable < ${GATE_MIN_MEM_MB:-2048}` (`/proc/meminfo` ∥ `vm_stat` free+inactive×pagesize); swap-used% > `${GATE_SWAP_PCT:-90}` (`/proc/meminfo` ∥ `sysctl vm.swapusage`); live-lane registry count across **all** `autonomous-*/lanes/` ≥ `${MAX_TOTAL_CONCURRENT:-12}` (the registry finally makes a cross-project global cap possible; per-project `MAX_CONCURRENT` unchanged).
- **Refusal path:** log `dispatch deferred: back-pressure (<reason>)` → run `adt-gc.sh --quick` (reclaim before giving up) → re-check once → `exit 75` (EX_TEMPFAIL). Also touch a per-(issue,type) **defer marker** `…/lanes/.defer-<type>-<N>` with the reason and a `mtime` capturing the defer moment.
- **Attribution:** `lib-dispatch.sh` extends the INV-26 exit-code table: rc = 75 = defer — no retry-budget decrement, no `failed-*` label, issue picked up next tick.

**Remote DEFERRED plumbing (F1 selfdefeat — this was under-scoped in rev 2; PR-6 grows to three dispatcher-side files, not one):** under `EXECUTION_BACKEND=remote-aws-ssm` the wrapper-host exit code is never observed by the dispatcher host, so an unmarked deferral would masquerade as a no-PR crash in Step 5b (dispatcher-tick.sh) after the defer marker window expires. Three files change in the same PR:

1. `skills/autonomous-dispatcher/scripts/liveness-check-remote-aws-ssm.sh` — extend the emitter with a new verdict `DEFERRED\n<age_s>` when a `defer-<type>-<N>` marker's mtime is fresher than the last dispatch token for that (issue,type). (Today it emits only `ALIVE` / `DEAD` / `indeterminate` — per INV-30.)
2. `skills/autonomous-dispatcher/scripts/lib-dispatch.sh` — extend `_remote_pid_alive_query`'s return schema to include DEFERRED, extend the INV-30 verdict-set documentation, plumb DEFERRED through `pid_alive`'s return contract.
3. `skills/autonomous-dispatcher/scripts/dispatcher-tick.sh` — Step 5b adds a fast-return branch on DEFERRED **before** the no-PR / near-success checks; DEFERRED short-circuits to "defer, no comment, no label flip, no retry decrement".

**AC (mock-SSM):** a fixture SSM snippet returning `DEFERRED\n45\n` causes Step 5b to post no INV-24 crash comment, flip no label, and burn no retry budget.

- The gate is pure admission control: it never kills running lanes (killing live lanes would violate the false-positive constraint). Linux scopes (C7) add the third leg: per-lane `MemoryMax` makes the kernel OOM the *lane's* cgroup, whose guardian then reaps it — the feedback loop's trigger is localized.

### C7. Linux enhancement — systemd `--user` scope enrollment (feature-detected, never load-bearing)

When `_lane_backend` selects `systemd-scope`, `lane_spawn` becomes:

```bash
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"   # SSM chain doesn't set it; verified sufficient (no DBUS var needed)
systemd-run --user --scope --collect --quiet --unit "adt-${lane_id_fs}" \
  -p TasksMax=${LANE_TASKS_MAX:-512} ${LANE_MEMORY_MAX:+-p MemoryMax=$LANE_MEMORY_MAX} \
  -- setsid ${timeout_wrap[@]} "${agent_argv[@]}" &
```

- cgroup membership **survives re-setsid** (probe-verified: escaped setsid child stayed in `cgroup.procs` and was reaped) — the only mechanism that structurally defeats RC3.
- Reap fast path in `lane_kill`/guardian/GC: `echo 1 > /sys/fs/cgroup/…/adt-<id>.scope/cgroup.kill` (kernel ≥ 5.14) — atomic SIGKILL-all including fork races; graceful variant `systemctl --user kill -s TERM` first.
- **Linger is checked at backend-*selection* time (§4-C1 `_lane_backend`), not only at probe time (F3 platform).** Without `Linger=yes` the user manager lives only while operator ttys exist; enrolling scopes then means "last operator logout → cascade-SIGKILL every enrolled scope". Backend selection therefore **refuses systemd-scope and drops to pgid** unless `loginctl show-user -p Linger --value` returns `yes`, emitting a WARN. PR-7 gates enablement on linger.
- `TasksMax` caps fork bombs; optional `MemoryMax` localizes OOM. `--collect` prevents failed-scope unit accumulation. Unit name derives from the (epoch+rand-suffixed) lane id — no collisions.
- Deliberately **not** adopted: `PR_SET_CHILD_SUBREAPER` (needs a ctypes shim, bit dies with its holder, marginal over registry+tag sweep) and pdeathsig on the wrapper→guardian edge (guardian must outlive the wrapper). `setpriv --pdeathsig` may be used as a non-load-bearing hardener on Linux for auxiliary children only.

### C8. Source fixes — stop minting the biggest orphan class, and stop the live-lane CPU burner (RC5, RC6)

**Token daemon (`gh-token-refresh-daemon.sh:67`):** replace the monolithic `sleep $REFRESH_INTERVAL` with a **60 s-chunked, PPID-checked loop** — the canonical pattern reused by the guardian watchdog (F5 selfdefeat symmetry). Trap TERM/INT to reap the in-flight sleep child:

```bash
_chunked_sleep() {   # $1 = total secs
  local left=$1 _sp
  trap 'kill "$_sp" 2>/dev/null; exit 0' TERM INT
  while (( left > 0 )); do
    kill -0 "$PPID" 2>/dev/null || exit 0                  # parent gone → daemon exits
    local chunk=$(( left > 60 ? 60 : left ))
    sleep $chunk & _sp=$!; wait "$_sp"; trap - CHLD
    left=$(( left - chunk ))
  done
}
```

Post-SIGKILL daemon survival drops ≤ 45 min → ≤ 60 s; an orphaned in-flight sleep self-expires ≤ 60 s instead of ~27.8 h. Scrub GH token **values** from daemon env (file paths only).

**Test fixture (`tests/unit/test-token-split-234.sh:145-153`):** the stub daemon heredoc gets the same PPID watchdog (`while kill -0 $PPID; do sleep 5; done` instead of `sleep 99999` at `:152`); fixture `GH_TOKEN_REFRESH_INTERVAL` drops 99999 → 120; the harness EXIT trap kills recorded stub PIDs/groups before `rm -rf`. (15/20 live sleep orphans were this exact fixture, leaked by group-killed dev-lane test runs.)

**Git-hook spinner (RC6, F2 completeness — the actual load-241 driver):** the pre-commit / pre-push hooks under `.worktrees/*/hooks/` read stdin via `input=$(cat)` and spin at 98–99 % CPU when stdin is EOF'd early. Source-fix wraps the read in a timeout so the hook exits on EOF instead of spinning:

```bash
input=$(timeout 5 cat 2>/dev/null || true)
```

**Live-lane sustained-CPU alert (Pass 4, flag-only — NEVER kill):** GC Pass 4 (§6) walks pipeline-tagged processes with `%cpu > 80` sustained across two GC ticks (~20 min), `cwd` under a live lane's worktree, and emits a `LIVE_BURNER_ALERT lane=<id> pid=<n> argv=<head> cpu_pct=<n> age_s=<n>` line — never a signal. The design forbids killing under a live lane (principle 5, RC6 aftermath — the driver of load-241 was under a **live** agent). Alert also surfaces via `adt-gc.sh --doctor`.

---

## 5. State-file summary

| File | Owner | Written | Removed | Read by |
|---|---|---|---|---|
| `…/lanes/.pending-<id>/*` | wrapper (atomic install, C1 F1 fix) | during mint, before `mv -T` | never observed post-mv; rule 1.4 after 24 h if wrapper died pre-mv | none |
| `…/lanes/<id>/lane` | wrapper (flock, rewrite-then-mv) | before first spawn (incl. token daemons — F6 falsekill) | GC, 24 h after terminal STATE | guardian, GC, gate, kill_stale delegate |
| `…/lanes/<id>/pgids` | wrapper + `_run_with_timeout` + fan-out/E2E/smoke spawn sites (append; one write(2) per line ≤ PIPE_BUF) | per spawn | with lane dir | guardian, GC, TERM trap, cleanup |
| `…/lanes/<id>/guard.fifo` | wrapper (mkfifo) | at guardian install | guardian after reap (rule 1.4 kills guardian FIRST then rm) | guardian (read), wrapper (sole write) |
| `…/lanes/<id>/reap.lock` | wrapper (touch) | before first spawn | with lane dir | `do_reap`, `lane_kill`, `cleanup()` (shared serialization, F3/F4/F5) |
| `…/lanes/.defer-<type>-<N>` | gate | on deferral | next successful dispatch | remote liveness snippet (returns DEFERRED when fresher than dispatch token) |
| `issue-N.pid` / `.heartbeat` | existing contracts (INV-23/24/29) | unchanged | unchanged | unchanged |
| `$ADT_STATE_ROOT/adt-gc.{lock,log}` | GC | per run | log self-rotated at 25 MB, single-generation | operator audit / INV-67 collector via ADT_GC_SUMMARY |

**Coverage note:** token daemons and the heartbeat subshell are deliberately **not** PGID-recorded (they share the wrapper's PGID = dispatch-local's PGID; recording would false-attribute the wrapper's own group). Their reap path is env-tag escape sweep + C8 PPID watchdog + FIFO EOF — never the pgids-file join.

---

## 6. GC decision table (normative)

**Pass 1 — registry-driven** (no env reads; runs in `--quick`):

| # | Conditions (ALL) | Action |
|---|---|---|
| 1.1 | lane `STATE∈{live,cleaning,reaping}` ∧ `WRAPPER_PID` alive ∧ start-time matches `WRAPPER_START` ∧ (macOS only: `WRAPPER_FINGERPRINT` matches — F7 timing) | **skip** (live lane) |
| 1.2 | lane dead ∧ `GUARDIAN_PID` alive ∧ `STATE=reaping` for < 5 min (tightened from 15 min per F7 completeness — do_reap completes in seconds absent bugs) | **skip** (guardian owns the reap; wedged-guardian residual is §10-listed) |
| 1.3 | (lane dead ∧ (guardian dead ∨ `reaping` > 5 min ⇒ wedged)) ∧ (`CREATED_EPOCH` age > 600 s ∨ `STATE∈{reaping,cleaning}`) | `lane_kill` (choreography row 3, takes `reap.lock`) → `STATE=gc-reaped` |
| 1.4 | `STATE∈{clean-exit, reaped-by-guardian, gc-reaped}` ∧ age > 24 h; **or** `lane` unparseable ∧ age > 24 h; **or** `.pending-*` orphan ∧ age > 24 h | **Kill guardian first (TERM→1s→KILL if `GUARDIAN_PID` alive) THEN `rm -rf` lane dir** (F4 selfdefeat: rm-rf-while-guardian-holds-FIFO would park guardian up to 5 h) |
| 1.5 | `lane` file unparseable / partially written ∧ age ≤ 24 h | **skip + WARN** (fail toward leak; F1 timing: age-bounded — 1.4 collects it eventually) |

**Arithmetic note (F3 timing):** rule 1.3's disjunction on the age arm means a `STATE=reaping` lane at age < 600 s with a dead-or-wedged guardian is **always** reap-eligible (previously fell through the crack between 1.2 and the 600 s floor).

**Pass 2 — tagged-orphan sweep** (same-uid process enumeration). Kill candidate **iff ALL** of:

| # | Condition | False-kill guard it encodes |
|---|---|---|
| 2.1 | env has `ADT_LANE_ID=<X>` where lane X is dead per Pass-1 rules (age floor 300 s), **or** legacy pipeline signature **`AUTONOMOUS_CONF_LOADED_FROM` present ∧ `CC_USER=autonomous-(dev\|review)-bot`** (F1 falsekill: **∧, not ∨**) ∧ `ppid==1` (age floor 600 s). **Unknown `ADT_LANE_ID` — not present in any registry — is skipped, never killed (F2 falsekill).** | only pipeline-attributable processes; exact join preferred |
| 2.2 | env does **not** contain `TERM_PROGRAM` | operator tooling unconditionally untouchable (incl. operator hand-running a wrapper) |
| 2.3 | candidate's pgid contains no live wrapper member; the match is **argv-based, not comm-name-based** (`pgrep -g $PG -f 'autonomous-(dev\|review)\.sh'`) to survive comm truncation and launcher-bridge exec chains — F4 falsekill | never sweep a lane that's actually running; robust to the launcher-bridge one consumer project uses |
| 2.4 | candidate's pgid ∉ {pgids recorded by any **live** lane} ∧ ∉ {pgid of any PID in a live `.pid` file} ∧ **∉ ancestry of any live wrapper process** (`pgrep -f 'autonomous-(dev\|review)\.sh'` scoped by `PROJECT_DIR`; walk each result's descendant tree) — F2 selfdefeat: old-format LIVE wrapper (pre-upgrade / one legacy-style checkout) whose daemons have `ppid==1` and no lane dir would otherwise pass 2.1–2.5; ancestry gate blocks that class | re-dispatched/resumed lanes protected; mid-upgrade legacy lanes protected |
| 2.5 | `proc_age` > floor (2.1) | startup windows (daemons precede PID-file writes) + INV-17 grace respected |
| — | **banned keys** (never sufficient, never used): `CLAUDE_CODE_SESSION_ID`, kernel sid liveness, bare `ppid==1`, comm/name match | resume-reuse trap; shared SSM session trap; crashpad-of-live-chrome trap |

Action: TERM → 10 s → KILL (group where known, else pid), under `reap.lock` (non-blocking; skip if held — a live guardian is authoritative).

**Pass 3 — env-blind classes:**

| # | Class | Conditions (ALL) | Action |
|---|---|---|---|
| 3.1 | Chrome (lane-scoped) | argv `--user-data-dir` under a **dead** lane's `LANE_SCRATCH` (or matches its `CHROME_PROFILE_HINT`) | kill (TERM→10s→KILL) |
| 3.2 | Chrome (heuristic) | argv `--user-data-dir=/tmp/puppeteer_dev_chrome_profile-` ∧ `ppid==1` ∧ age > 2 h ∧ no live sharer of that profile dir ∧ no live MCP parent | kill |
| 3.3 | Wedged gh | argv `gh pr checks --watch` ∥ long-poll `gh api` ∧ env `GH_TOKEN_FILE=/tmp/agent-auth-*` whose dir is gone ∧ 2.2–2.5 | kill |
| 3.4 | E2E servers | registry `WORKTREE` path no longer exists ∧ proc cwd was under it (Linux `(deleted)` readlink; macOS: stat the **recorded** path — lsof deletion flag unreliable) ∧ lane dead | kill |
| 3.5 | crashpad / helpers | judged by their **intact env** via Pass 2 (never by ppid/name) | per Pass 2 |

**Pass 4 — live-lane sustained-CPU alert (flag-only, RC6; F2 completeness):**

| # | Class | Conditions (ALL) | Action |
|---|---|---|---|
| 4.1 | Live-lane CPU burner | pipeline-tagged (env `ADT_LANE_ID`) ∧ lane X is Pass-1 live ∧ `%cpu > 80` for ≥ 2 consecutive GC ticks ∧ cwd under a `.worktrees/*/hooks/` or similar known-spinner path | **emit `LIVE_BURNER_ALERT` line — never signal** (fail-toward-leak under a live lane; principle 5). Source fixes (C8) address the root cause. |

---

## 7. Platform matrix

| Component / primitive | Linux | macOS | Notes |
|---|---|---|---|
| `kill -TERM/-KILL -- -PGID` | ✅ | ✅ | identical POSIX; core kill primitive |
| `setsid(1)` | ✅ util-linux | **✅ HARD PREREQ via `brew install util-linux`** (F1 platform) | rides the same keg as the already-mandatory `flock` (`lib-agent.sh:586`); `& disown` fallback dropped — without setsid the routine re-dispatch group-KILL kills the guardian |
| Guardian FIFO pipe-EOF | ✅ verified (25 ms) | ✅ (POSIX mkfifo/fd semantics) | zero deps; the portable death-watch |
| Env read for kill authorization | `/proc/PID/environ` (same-uid; **gate on `[ -r ]`, never `[ -s ]`** — F5 platform) | **`sysctl kern.procargs2` via `python3` shim** (F2 platform — argc-delimited layout separates argv from envp cleanly). `ps eww` is UNSAFE for authorization (no argv/env delimiter). Absent the python3 shim: registry-authoritative only; env-tag = dry-run diagnostic. | registry = driver, env = confirmer by design |
| Process age | `ps -o etimes=` (procps) | parse `ps -o etime=` `[[dd-]hh:]mm:ss` | BSD pgrep has **no** `--older`; BSD `-o` = oldest-match (false friend) — centralized in `proc_age()` |
| Start-time (pid-recycle) | `/proc/PID/stat` f22 fast path (µs) | `ps -o lstart=` (1 s granularity) **+ `WRAPPER_FINGERPRINT=sha256(comm‖ppid‖lstart)`** — F7 timing | both recorded in lane file |
| `pgrep -f` / `-g` | ✅ | ✅ | compatible both sides |
| stat mtime | `stat -c %Y` | `stat -f %m` (or `find -mmin`) | existing dual pattern reused |
| flock(1) | ✅ | via brew (already mandatory, `lib-agent.sh:586`) | do not regress to mkdir locks (#360); `reap.lock` uses `flock` |
| systemd scope + cgroup.kill (C7) | ✅ kernel ≥ 5.14; needs XDG self-export + **`Linger=yes` at backend selection (F3 platform)** + `enable-linger` | ❌ none (launchd `AbandonProcessGroup` evaluated & rejected — same re-setsid hole) | optional enhancement only |
| pdeathsig / subreaper | ✅ (`setpriv`; ctypes) — non-load-bearing hardener only | ❌ | deliberately not architectural |
| Exit watch for adopted PIDs | n/a (have /proc) | `python3 select.kqueue` EVFILT_PROC NOTE_EXIT | optional; pipe-EOF is primary |
| GC timer | cron `*/10` (works without linger) | launchd `StartInterval=600` (cron trips TCC) | plus opportunistic dispatch-local call on both; `install-gc-timer.sh` is the idempotent per-host installer |
| Deleted-cwd detection | `readlink /proc/PID/cwd` `(deleted)` | unreliable ⇒ inverse check: stat registry-recorded worktree | rule 3.4 |
| Load/mem gate | `/proc/loadavg`, `MemAvailable` | `sysctl vm.loadavg`, `vm_stat`, `vm.swapusage` | `box_health()` helper |
| bash ≥ 4 | ✅ | brew bash (repo constraint; noted in lib-lane.sh header) | |
| Hardened-runtime env suppression | n/a | ✅ residual (F5 completeness): non-Chrome codesigned re-setsid'd descendants have no argv marker AND no readable env — invisible on macOS portable path; only closed by INV-113 scopes (Linux) or `sysctl kern.procargs2` where the argv still carries the tag | §10 residual |

---

## 8. New invariants (exact wording; numbering starts at INV-106 — current head is INV-105 (#341); INV-103/104 were claimed by #365. Renumber-on-rebase-collision per repo convention: first-merged keeps, each INV-adding PR notes the convention. Numbering is re-verified at PR-open per F10 completeness; wording below references the shipped fan-out-reap invariant symbolically rather than by number, so a rebase renumber does not require re-wording INV-108.)

> Each new `## INV-NN:` heading carries the required `_Triage (issue #236):` marker line per the existing convention.

**INV-106 — Kill-escalation contract.** Every pipeline-initiated kill of a process group or lane is SIGTERM → bounded grace → SIGKILL. Escalation and completion are gated on **group/scope emptiness** (`kill -0 -- -PGID` / `cgroup.procs`), never on leader liveness alone. SIGTERM always precedes SIGKILL so agent exit code 143 retains its INV-26 dispatcher-induced attribution; rc = 137 following a pipeline-initiated TERM is likewise attributed as induced, not a crash. Grace defaults: wrapper TERM trap 5 s; `lane_kill` 10 s; `kill_stale_wrapper` 5 s. `pkill -TERM -P $$` in the wrapper TERM trap is scoped to `-P $$` and never widened to `-f <script-name>` (widening would cross-kill sibling lanes).

**INV-107 — Lane identity, registry, and atomic install.** Every wrapper run mints `ADT_LANE_ID=<project>:<role>:<issue>:<start-epoch>:<rand4>` and installs its lane registry directory atomically — populated inside `${ADT_STATE_ROOT}/autonomous-<PROJECT_ID>/lanes/.pending-<id>/` with `WRAPPER_PID`, `WRAPPER_START`, `WRAPPER_FINGERPRINT` (on macOS), `CREATED_EPOCH`, and `STATE=live` all written, then `mv -T` into place — **before any background child is spawned, including token daemons, heartbeat, and pre-agent utilities**. Every spawned PGID is appended to `pgids` (one `write(2)` per line, ≤ PIPE_BUF), including review fan-out sidecars, E2E, and smoke lanes, so PGIDs survive tmpdir removal and wrapper death. Lane liveness = pid alive ∧ start-time match ∧ (macOS: fingerprint match); kernel sid liveness and `CLAUDE_CODE_SESSION_ID` are never lane-liveness or kill keys. Graceful exit takes `reap.lock`, sets `STATE=cleaning`, reaps, promotes to `STATE=clean-exit`. `ADT_STATE_ROOT` is canonicalized to `$HOME/.local/state` (or an explicit operator override); `XDG_STATE_HOME` is deliberately ignored to prevent wrapper-vs-timer path divergence. The registry is additive to, and never replaces, the INV-23/24/29 PID-file contracts. Token daemons and the heartbeat subshell inherit `ADT_LANE_ID` for tagging but are deliberately not PGID-recorded (they share the wrapper's PGID).

**INV-108 — Universal lane tagging.** `ADT_LANE_ID` is exported in the wrapper main shell before any child spawn and therefore inherited by every long-lived descendant, dev and review side, including smoke probes and E2E lanes. This generalizes the shipped fan-out-reap invariant's recorded-descendant mechanism from the post-verdict fan-out reap to all spawner classes and all death paths; that invariant's call site and marker are unchanged. The browser lane additionally scopes `TMPDIR` under the lane scratch namespace (INV-100) so Chrome's `--user-data-dir` argv carries a lane-unique path (env-blind-process coverage). Legacy residue is identifiable **only by the conjunction** `AUTONOMOUS_CONF_LOADED_FROM` present ∧ `CC_USER=autonomous-(dev\|review)-bot` (the `CC_USER` conjunct is required to distinguish operator-sourced `autonomous.conf` from wrapper-run residue). An unknown `ADT_LANE_ID` — one not present in any registry — is a skip, never a kill. Token daemons receive token **file paths** only; token values must not appear in descendant environments.

**INV-109 — Guardian.** Each lane runs a `setsid`-detached guardian holding the read end of `guard.fifo`; the wrapper opens its write end **before** spawning the guardian, guaranteeing the guardian's read-side `open` finds a writer. The wrapper is the **sole** write-fd holder and every background spawn closes the fd (`{ADT_GUARD_FD}>&-`). `setsid` is a hard prerequisite on both Linux and macOS (dropped `& disown` fallback would let a group-scoped SIGKILL of the wrapper also kill the guardian). EOF — which the kernel delivers on wrapper death by any means, including SIGKILL and OOM — triggers an idempotent lane reap under a shared `reap.lock` per INV-106, plus a lane-scoped env/argv escape sweep (this lane's `ADT_LANE_ID` only; a foreign tag is skipped). The guardian's own long waits use the 60-second chunked, PPID-checked pattern of INV-79 — never a SIGKILL-survivable monolithic sleep. The guardian skips work when `STATE∈{clean-exit,cleaning,gc-reaped,reaped-by-guardian}`, self-exits after bounded work, and carries a hard lifetime cap of `AGENT_TIMEOUT + 1h`. If no writer is present at open time (defense against future reorderings of INV-107's atomic install), the guardian self-exits within 15 s. The guardian is not load-bearing alone: GC (INV-110) must fully reap a lane whose guardian died.

**INV-110 — GC safety predicate and periodic reclamation.** A periodic, issue-independent GC (`adt-gc.sh`; flock singleton; cron/launchd + opportunistic pre-dispatch invocation) reclaims dead-lane residue. A process may be killed **only** under the §6 decision table: (registry-dead lane tag ∨ legacy pipeline signature under the ∧ conjunction of INV-108) ∧ ¬`TERM_PROGRAM` ∧ wrapper-less pgid (argv-matched) ∧ pgid outside all live-lane sets **and outside the descendant ancestry of every live wrapper (`PROJECT_DIR`-scoped)** ∧ age above floor. Unknown `ADT_LANE_ID` is a skip. `TERM_PROGRAM` is an unconditional skip. Session-id, sid-liveness, bare ppid, and process names are banned as kill authorization. Unparseable state fails toward skip (rule 1.5) and is age-collected by rule 1.4 after 24 h. `env -i` re-exec'd descendants with no tag and no lane-scoped argv are a documented residual (already stated at `lib-review-poll.sh:476-481`; unreachable portably; closed only by INV-114 scopes). Non-Chrome hardened-runtime-suppressed macOS descendants are a documented residual (§10). Live-lane CPU burners are alerted (Pass 4), never killed — the source fix (INV-79's chunked pattern extended to hooks) is the closure. Every run emits a single `ADT_GC_SUMMARY` metrics line consumable by the INV-67 collector. Dry-run is the default until an operator soak sign-off; soak sign-off criteria include zero `would_kill_legacy_signature` and stable `unknown_class` across ≥ 2 weeks.

**INV-111 — Bounded, ordered teardown.** `cleanup()` in both wrappers takes `reap.lock`, sets `STATE=cleaning`, reaps all registry-recorded PGIDs (per INV-106) **before** any network call; PID/registry state updates precede network work; the FIFO clean-exit handshake is sent before any network work; every network call in a teardown path is bounded (`timeout 60`, feature-detected, unwrapped+WARN when absent) so an EXIT trap can never hang indefinitely while holding lane state. Crash/set-e EXIT paths perform the same reap as verdict-path reaps (extends INV-43/the shipped fan-out-reap invariant to abnormal exits and to the dev wrapper).

**INV-112 — Back-pressure admission gate.** `dispatch-local.sh` refuses to spawn (exit 75, EX_TEMPFAIL) when box distress thresholds are exceeded (load/core, MemAvailable, swap%, global live-lane cap `MAX_TOTAL_CONCURRENT`), after attempting one opportunistic `--quick` GC pass. rc = 75 is a defer: no retry-budget decrement, no label flip, no crash attribution. A defer marker fresher than the dispatch token must be surfaced by the remote liveness probe as `DEFERRED` (extending its verdict set beyond ALIVE/DEAD/indeterminate per INV-30) so remote-backend stale detection (Step 5b in `dispatcher-tick.sh`) routes it as defer-not-crash before any near-success check. The gate never kills running processes.

**INV-114 — Linux scope enrollment (optional enhancement).** Where feature-detected (Linux ∧ `systemd-run` ∧ user bus socket reachable after wrapper-side `XDG_RUNTIME_DIR` self-export ∧ `Linger=yes` at backend-selection time ∧ probe spawn succeeds), lanes are enrolled in `systemd-run --user --scope --collect` units named from the lane id, with `TasksMax` (default 512) and optional `MemoryMax`; the backend is recorded per-lane and reaping prefers `cgroup.kill`. `loginctl enable-linger <user>` is a documented host prerequisite checked by `adt-gc.sh --doctor`; enrolling scopes without linger would cascade-kill every lane on last operator logout, so backend selection refuses systemd-scope in that case and drops to pgid. Absence of any prerequisite degrades silently to the pgid backend, which MUST remain fully sufficient.

---

## 9. Rollout plan — ordered, PR-sized, each independently useful

All work in worktrees (self-hosting rule); every pipeline-touching PR updates the matching `docs/pipeline/*.md` in the same PR; skills refresh per the post-merge checklist (Step 1 for libs; installer re-run only for entry-point PRs).

**PR ordering was reordered rev 3** (F7 selfdefeat): registry lands **before** kill-path hardening because PR-3's TERM-trap iterates the durable registry pgids the design specifies, and its fan-out reap depends on registry sidecars surviving `rm -rf $_FANOUT_DIR`. Without PR-2 first, PR-3 would ship reading `_FANOUT_DIR` sidecars that `rm -rf` can remove pre-TERM, re-introducing the review-side dead arm.

**PR-1 — Source hygiene: token-daemon + fixture sleep fix + git-hook spinner fix (C8).** Files: `gh-token-refresh-daemon.sh`, `tests/unit/test-token-split-234.sh`, all `.githooks/pre-commit` / `.githooks/pre-push` / `install-claude-hooks.sh`-managed hooks that use `input=$(cat)`. No new INV (footnotes under INV-79/INV-109/INV-110 land with the invariant PRs). *AC:* (1) unit test: SIGKILL the daemon → no `sleep` child survives > 60 s; (2) fixture harness EXIT kills all stub PIDs (asserted via post-run pgrep); (3) fixture interval = 120; (4) grep proves no token **values** in daemon-spawned env; (5) hook stdin EOF test: `input=$(timeout 5 cat)` fixture exits ≤ 6 s, no CPU spin; (6) suite green.

**PR-2 — Lane identity, registry, atomic install, tagging (C1 + C2, INV-107 + INV-108).** New `lib-lane.sh` (pgid backend only); atomic mint via `.pending-<id>/` + `mv -T`; `ADT_STATE_ROOT` canonicalization; mint/export/registry in both wrappers **before token daemons and heartbeat** (F6 falsekill); PGID appends in `_run_with_timeout`, fan-out, E2E, smoke; TMPDIR scratch redirect; `WRAPPER_FINGERPRINT` (macOS) at mint; daemon token-value scrub; legacy-tag documentation (∧ conjunction, F1 falsekill). Lib-only ⇒ Step-1 refresh suffices — no `## Post-install / upgrade` note required. *AC:* (1) unit: registry exists at `lanes/<id>/` with parseable `lane` file before ANY spawn (including token daemons at `lib-auth.sh:128`); (2) atomic mint stress: SIGKILL wrapper mid-`lane_install` × 50 → zero `lanes/<id>/` dirs with missing WRAPPER_PID/WRAPPER_START/CREATED_EPOCH observed by GC; either full state or `.pending-*` only; (3) fan-out PGIDs present in `pgids` after `rm -rf $_FANOUT_DIR`; (4) live probe: a spawned test child's env contains `ADT_LANE_ID`; smoke lane included; (5) chrome profile hint recorded when browser E2E configured; (6) `STATE=cleaning` observed during graceful cleanup, then `STATE=clean-exit`; (7) start-time recorded and match logic unit-tested against a recycled-pid fixture; (8) macOS AC: `WRAPPER_FINGERPRINT` populated + a same-second same-lstart operator PID does not satisfy rule 1.1; (9) legacy-signature ∧ fixture: `bash -c 'source autonomous.conf; sleep 3600'` from a shell without `CC_USER` set is NOT authorized by rule 2.1; (10) unknown-`ADT_LANE_ID` fixture: tagged sleep with lane id absent from registry is skipped.

**PR-3 — Kill-path hardening (C4, INV-106 + INV-111).** Escalation helper; TERM-trap rewrite iterating **registry-recorded pgids** (depends on PR-2); `kill_stale_wrapper` group-gate fix (both sites, `dispatch-local.sh:174` and `:269`); dev + review `cleanup()` under `reap.lock` with `STATE=cleaning`; bounded+reordered teardown; FIFO handshake before network work; INV-26 attribution sentence; `pkill -P $$` pin (never widened to `-f`, F5 falsekill). *AC:* (1) unit: group whose leader died on TERM but member traps TERM → member is KILLed within grace; (2) unit: review wrapper SIGTERMed mid-fan-out → all fan-out PGIDs reaped by EXIT path using registry pgids; (3) unit: cleanup with a hung `gh` stub completes ≤ 90 s and labels still flip; (4) grep-pin: TERM precedes KILL in every kill site; (5) grep-pin: no `pkill -f 'autonomous-'` widening anywhere; (6) unit: cleanup + concurrent guardian EOF → `reap.lock` serializes both, no double-KILL of the same pgid observed via strace; (7) unit: FIFO handshake precedes every network call in cleanup; (8) docs updated same PR.

**PR-4 — `adt-gc.sh` + `install-gc-timer.sh` (C5, INV-110).** Two **entry-point** scripts (⇒ `## Post-install / upgrade` note in PR body; installer re-run across onboarded checkouts after merge; hand-symlink line for the one legacy-style checkout), decision table §6, `--dry-run` default, `--quick` (`flock -w 3` per F6 selfdefeat), `--doctor` (probes timers, linger, flock, backend, `setsid`, `python3` on macOS, `ADT_STATE_ROOT` content — F1 completeness), timers docs (cron + launchd plist shipped), opportunistic dispatch-local call, self-match exclusion tests, self-log-rotation ≥ 25 MB (F8 selfdefeat), `ADT_GC_SUMMARY` metrics line for INV-67 (F8 completeness), rule 1.4 kills guardian first (F4 selfdefeat). *AC:* (1) fixture harness spawning fake orphans (tagged sleep, legacy-sig-with-CC_USER sleep, legacy-sig-WITHOUT-CC_USER decoy from operator conf sourcing, TERM_PROGRAM decoy, unknown-lane-id decoy, live-lane daemon, mid-upgrade legacy live wrapper's daemon with `ppid==1`, crashpad-shaped decoy) → dry-run classifies exactly per §6 with zero false positives; (2) flock singleton verified under concurrent invocation; `--quick` `flock -w 3` starve test passes; (3) `--quick` < 1 s on 50 lane dirs; (4) every would-kill line carries pid/argv/lane/rule; ADT_GC_SUMMARY parsed by an INV-67 fixture; (5) BSD-age-parser unit test; (6) macOS: `sysctl kern.procargs2` shim installed via `python3` returns correct env for a synthetic argv-with-VAR=X child; absent shim, `--kill` refuses env-authorized kills; (7) log at 26 MB rotates to `.1`, single generation; (8) rule 1.4 fixture: `.pending-*` orphan aged 24 h is `rm -rf`'d; wedged guardian is TERM'd then rm'd. **macOS AC (F4 completeness required):** all of the above run under macOS CI (`sysctl` shim, `setsid` prereq check via `--doctor`, launchd plist bootstrap+unbootstrap, BSD age parser, hardened-runtime env-empty decoy stays skipped). Where a full macOS runner is not yet in the CI pool, PR-4 declares those ACs deferred to a follow-up "macOS enablement" PR that runs before PR-8 flip — this is spelled out explicitly in the PR body so it cannot be rubber-stamped away.

**PR-5 — Guardian (C3, INV-109).** `lib-guardian.sh`; FIFO write-fd opened BEFORE guardian spawn (F2 timing); `setsid` hard prereq (both platforms; F1 platform); chunked-PPID-checked lifetime cap (F5 selfdefeat symmetry with C8); no-writer watchdog (F2 timing defense); fd hygiene at all spawn sites + the grep-based spawn-site unit test with §10 honesty-reworded scope; `reap.lock` acquire in `do_reap`; clean-exit handshake ordering. Depends on PR-2 + PR-3. *AC:* (1) integration: SIGKILL the wrapper's session → guardian reaps recorded pgids ≤ grace+2 s under `reap.lock`; (2) escaped `setsid` child carrying THIS lane's tag is swept; (3) escaped child carrying a DIFFERENT lane's tag is NOT swept (F3 falsekill scope pin); (4) escaped child holding an unclosed guard fd test proves the `>&-` regression guard; (5) graceful exit → guardian exits with **zero** kills; (6) guardian lifetime cap fires in an accelerated test AND is SIGKILL-non-survivable (chunk-watchdog exits on `kill -0 $$` failure); (7) macOS: `setsid` missing → wrapper refuses to spawn guardian, emits fatal error (drop-fallback pinned); (8) sole-holder EOF measured ≤ 100 ms; inherited-fd EOF defers to last-close (both branches asserted per F4 platform).

**PR-6 — Back-pressure gate + remote DEFERRED (C6, INV-112).** Gate + knobs in `autonomous.conf.example`/`dispatcher.conf`; rc-75 attribution in `lib-dispatch.sh`; defer marker; **and the three dispatcher-side files (F1 selfdefeat): `liveness-check-remote-aws-ssm.sh` (emit DEFERRED\n<age_s>), `lib-dispatch.sh` (extend `_remote_pid_alive_query` return schema and INV-30 verdict-set doc), `dispatcher-tick.sh` (Step 5b DEFERRED fast-return before near-success checks)**. Global lane cap via registry count (falls back to PID-file count pre-PR-2, so only soft-depends on PR-2 order). *AC:* (1) unit: synthetic pressure → exit 75, no label change, no retry decrement; (2) **mock-SSM AC**: liveness snippet returns DEFERRED → Step 5b posts nothing, flips nothing, decrements nothing (F1 selfdefeat closure); (3) gate provably never signals any process; (4) knobs documented.

**PR-7 — systemd scope backend (C7, INV-114).** Backend probe + linger gate at selection (F3 platform) + scope spawn + `cgroup.kill` fast paths in guardian/GC + `--doctor` linger check + onboarding docs (`loginctl enable-linger`). Depends on PR-2 (naming), consumes PR-4/5 reap seams. *AC:* (1) on a linger-enabled host: `setsid`-escaping child inside a scope is reaped by `lane_kill`; (2) linger=no host: backend probe refuses systemd-scope with WARN, `BACKEND=pgid` recorded, wrapper spawns fine; (3) probe-failure host falls back to pgid backend with `BACKEND=pgid` recorded; (4) unit-name collision test (two lanes, same second) passes via rand4; (5) TasksMax visible in `systemctl --user show`.

**PR-8 — GC enforcement flip.** After a ≥ 2-week soak with (a) zero `would_kill_legacy_signature` in `adt-gc.log` — the F8 completeness alert; (b) stable `unknown_class`; (c) any pre-PR-2 old-format live-wrapper checkouts confirmed re-onboarded post-PR-2 (F2 selfdefeat: legacy-signature hits stay dry-run-only until all onboarded projects run PR-2's atomic install), operator sign-off recorded in the PR body: default `--dry-run` → `--kill` (env `ADT_GC_ENFORCE=1` honored earlier for opt-in). *AC:* soak evidence attached (ADT_GC_SUMMARY roll-up), alert mechanism proven, re-onboarding audit; rollback = single conf flag.

**Ops sequencing** on the current fleet: after PR-2, one manual dry-run over legacy residue; after PR-4 merge + `npx skills update -g`, install the cron on the wrapper host via `install-gc-timer.sh`, re-run `install-project-hooks.sh` across onboarded projects (the two entry-point scripts land in every project's `scripts/`), and hand-symlink `adt-gc.sh` + `install-gc-timer.sh` into the one legacy-style checkout's `scripts/` directory (that checkout does not carry a `.agents/skills/` dir the installer can walk); `enable-linger` before PR-7 enablement; dotfiles lock commit after every user-scope skill update per local ops notes.

---

## 10. Residual risks

| Risk | Bound / mitigation | Accepted? |
|---|---|---|
| `env -i` re-exec'd grandchild with no tag and no lane-scoped argv (documented at `lib-review-poll.sh:476-481`) | unreachable on the portable path; closed only by INV-113 scopes on Linux; Pass-2 legacy signature may still catch inherited vars | ✅ stated in INV-110 |
| macOS non-Chrome hardened-runtime-suppressed descendants (codesigned binaries that re-setsid; env unreadable AND no argv marker) | invisible on the portable path; only closed by INV-114 scopes (Linux) or `sysctl kern.procargs2` where argv still carries the tag; flag-only Pass-4-style predicate (env empty ∧ ppid==1 ∧ age > floor ∧ pgid outside all live sets ∧ ancestor-tagged) is retained as a monitored option | ✅ stated in §7 & INV-110 (F5 completeness) |
| Wrapper + guardian both SIGKILLed inside one GC interval | residue lives ≤ GC interval (10 min) + floor — vs 26–58 days today | ✅ |
| Wedged-guardian window (rule 1.2, up to 5 min at tightened bound) | rule 1.2 tightened to 5 min from rev 2's 15 min (F7 completeness); after 5 min rule 1.3 reclaims; rule 1.4 kills guardian first before `rm -rf` (F4 selfdefeat) | ✅ |
| Chrome mains on macOS / non-scope Linux where the TMPDIR trick is defeated (future MCP pins `/tmp`) | falls to heuristic 3.2 (ppid==1 ∧ 2 h ∧ no-live-sharer); crashpad still env-taggable; monitored via GC metrics line | ✅ monitored |
| Operator-session leaks (their own MCP/chrome/node servers) | out of scope by the `TERM_PROGRAM` fail-safe — deliberately manual | ✅ by policy |
| Forgotten `{ADT_GUARD_FD}>&-` at a future spawn site | degrades EOF from "wrapper died" to "subtree died" (correct, later); grep-based unit test guards **literal sites only** — cannot catch pipeline subshells, `bash -c '…'` strings, or dynamically constructed commands (F6 timing honesty reword) | ✅ accepted degradation |
| Token daemons / heartbeat not PGID-recorded (they share the wrapper's PGID = dispatch-local's PGID) | env-tag escape sweep + C8 PPID watchdog + FIFO EOF cover them; deliberate architectural choice, documented in §5 (F6 completeness) | ✅ by design |
| rc=137 vs 143 perturbing crash attribution | TERM-first everywhere + INV-106 attribution sentence; GC only touches dead lanes so it emits no wrapper rcs | ✅ |
| Gate mis-tuning starves dispatch | worst case = slow pipeline, never a kill; knobs + defer log lines; remote DEFERRED surfacing avoids retry burn | ✅ |
| Linger disabled / operator logs out mid-fleet | scope probe fails-closed to pgid **at backend-selection time** (F3 platform); recorded-PGID fallback for already-enrolled lanes; `--doctor` warns | ✅ |
| Live-lane CPU burner (RC6) — pipeline-tagged descendant burning CPU under a still-live agent | Pass-4 flag-only alert (never kill under live lane, principle 5); root-cause closure is the C8 hook `timeout 5 cat` source fix | ✅ alert-only |
| SIGKILL mid-git-write corrupts a dead lane's worktree | same exposure as existing `kill_stale_wrapper`; worktrees are disposable | ✅ |
| Registry partial write / corruption | atomic `.pending-*` + `mv -T` (F1 timing); `flock` + rewrite-then-mv on updates; parse failure = skip+WARN (fail toward leak); rule 1.4 age-collects at 24 h | ✅ |
| Old-format live wrapper's daemons mistaken for orphan residue during rollout | rule 2.4 ancestry gate (`pgrep -f 'autonomous-(dev\|review)\.sh'` scoped by `PROJECT_DIR`; walk descendant tree) skips them (F2 selfdefeat); PR-8 additionally waits until all onboarded projects run PR-2's atomic install | ✅ |
| GC or timer never installed on a host | opportunistic `--quick` from every dispatch is the floor; `install-gc-timer.sh` + `--doctor` catch it | ✅ |
| INV numbering collision with in-flight PRs | numbering here (106–113) verified against main at design time; re-verified at PR-open (F10 completeness); INV-108 wording references the shipped fan-out-reap invariant symbolically so a rebase renumber does not force re-wording | ✅ convention |
| OOM narrative | incident showed swap-full + load but **no** kernel oom-kill records — all INV text says "SIGKILL/crash/OOM class", never asserts OOM fired | ✅ honest wording |

---

## 11. Explicitly out of scope

Containers/VMs (rejected as too heavy); killing operator-session residue; killing under a live lane (Pass-4 is alert-only); changing the label state machine or PID-file contracts (INV-23/24/26/29 untouched, only extended); dispatcher-host (remote) process hygiene (it spawns nothing long-lived); fixing the pre-existing remote-backend log-read blindness (#356) beyond the DEFERRED surfacing in PR-6.

**macOS ACs decision (F4 completeness):** PR-2/3/5's macOS ACs are **required** (registry parse, `setsid` prereq check, `WRAPPER_FINGERPRINT`, sole-holder-vs-inherited-fd EOF branches, `pkill -P $$` scoping). PR-4's full macOS-runner ACs (`sysctl kern.procargs2` shim, BSD age parser, launchd plist bootstrap, hardened-runtime env-empty skip) are **also required**; where a full macOS runner is not yet in the CI pool, they are deferred to a "macOS enablement" PR that must land **before PR-8 flip** — so no dry-run→kill transition without them. PR-6/7 have no macOS branch (PR-7 is Linux-only by design; PR-6 is dispatcher-host code path-agnostic).

---

## 12. Contradiction resolutions (across the three source designs)

| # | Contradiction | Resolution & rationale |
|---|---|---|
| R1 | D1: no guardian (GC-only, ≤ ~25 min reclamation) vs D2/D3: guardian sidecar | **Guardian adopted** (seconds vs minutes; converts the re-dispatch amplifier into a cleaner), but sequenced **after** GC (PR-4 → PR-5) so the backstop exists before the fast path; neither is singly load-bearing (principle 3). D1's escalation helper adopted verbatim as the shared primitive. |
| R2 | Naming: `ADT_LANE_ID`+`lanes/` (D1/D3) vs `ADT_LEASE_ID`+`leases/` (D2) | **Lane** — matches the operational vocabulary already in use and the shipped fan-out-reap invariant this design generalizes. |
| R3 | Lane granularity: role-in-id per sub-lane (D3) vs one lease per wrapper run (D2) | **One lane per wrapper run**; sub-lanes share the id and add `ADT_LANE_ROLE`. Simplifies the GC join (one registry per run) while preserving diagnostics. |
| R4 | Registry shape: flat `.lane` file (D3) vs dir-per-lane (D2) | **Dir-per-lane** — the FIFO, append-only `pgids`, and `reap.lock` need a directory anyway; atomic KV rewrite + append-only PGIDs are simpler as separate files. Atomic install via `.pending-*` + `mv -T` was added rev 3 to close the pre-existence race (F1 timing). |
| R5 | Defer signaling: `exit 0` (D1) vs `exit 75` EX_TEMPFAIL (D2/D3) | **rc = 75** with explicit lib-dispatch attribution — exit 0 is ambiguous with success. Synthesis addition: the **defer marker + remote-liveness `DEFERRED`** surfacing. Rev 3 tightening (F1 selfdefeat): PR-6 grows to touch three dispatcher-side files (`liveness-check-remote-aws-ssm.sh`, `lib-dispatch.sh`, `dispatcher-tick.sh`), not one — under the fire-and-forget SSM backend neither rc is ever observed by the dispatcher and an unmarked deferral would masquerade as a no-PR crash in Step 5b. |
| R6 | Chrome handling: argv heuristic only (D1/D3-fallback) vs TMPDIR lane-scratch redirect (D2) | **Both, tiered**: TMPDIR redirect is primary (exact, lane-joined); heuristic retained for legacy residue and TMPDIR-defeating futures. |
| R7 | FIFO open mode: `exec {fd}>` (D3, blocks until reader) vs `exec {fd}<>` (D2, never blocks) | **`<>`** — a slow/dead guardian can never deadlock the wrapper; O_RDWR still counts as a write end for EOF semantics. Rev 3 additional pin (F2 timing): wrapper opens `<>` **before** spawning the guardian so the guardian's read-side `open` finds a writer even under non-graceful death mid-spawn. |
| R8 | Grace timings: trap 5 s (D1) vs 15 s (D3); guardian/GC 10 s (D2/D3); daemon chunk 60 s (D1/D2) vs 30 s (D3) | Standardized: trap 5 s (fast path; `timeout --kill-after=30s` remains the in-group backstop), `lane_kill`/GC 10 s, `kill_stale_wrapper` keeps its existing 5 s, daemon chunks 60 s. Guardian lifetime-cap chunks 60 s (F5 selfdefeat symmetry). Single normative table in §4-C4. |
| R9 | GC cadence: 15 min (D1/D3) vs 10 min (D2); age floors 300 s vs 600 s | 10 min cadence; **600 s** floor for heuristic/legacy matches, **300 s** where the dead-lane tag join is exact (tighter join earns the shorter floor). Wedged-guardian tightener: rule 1.2 5 min (was 15 min, F7 completeness). |
| R10 | Cleanup network bound: 30 s (D1) vs 60 s (D2/D3) | 60 s per call (App-token mint latitude), with reap-first ordering **under `reap.lock` and `STATE=cleaning`** so even a re-killed hung cleanup has already de-leaked and cannot be double-reaped by the guardian mid-network (F4 timing). |
| R11 | INV numbering: start 104 (D1/D2) vs 106 (D3) | Start **106** — on-repo verification (2026-07-03) shows the head is INV-105 (#341's convergence breaker), with INV-103/104 claimed by #365; D1/D2's assumed head (INV-103) was stale. Rev 3: numbering re-verified at PR-open (F10 completeness); INV-108 refers to the recorded-descendant sweep by name ("the shipped fan-out-reap invariant") rather than by fixed number, so a rebase renumber does not require re-wording. |
| R12 | Subreaper/pdeathsig adoption (D3 mentions, D2 rejects) | Not architectural: subreaper rejected (shim dependency, bit dies with holder); pdeathsig allowed only as a non-load-bearing Linux hardener, never on the wrapper→guardian edge. |
| R13 | GC packaging: matcher inline in one entry-point (D1) vs helpers in the lane lib (D2/D3) | Helpers (`proc_age`, `env_of`, `proc_start_time`, `proc_fingerprint`, `box_health`) live in `lib-lane.sh` (Step-1 refresh); `adt-gc.sh` and `install-gc-timer.sh` stay thin entry-points — minimizes future installer re-runs to two entry-point PRs total (PR-4). |
| R14 *(new rev 3)* | Rollout order: kill-path hardening before registry (rev 2) vs registry before kill paths (rev 3, F7 selfdefeat) | **Registry (PR-2) before kill paths (PR-3).** Rev 2 PR-2 iterated `_FANOUT_DIR` sidecars that `rm -rf $_FANOUT_DIR` removes pre-TERM — reintroducing the review-side dead arm the design is meant to close. Rev 3 PR-3's TERM-trap iterates durable registry pgids and depends on PR-2 having landed. |
| R15 *(new rev 3)* | Legacy-signature match: `∨` (rev 2) vs `∧ CC_USER=autonomous-*-bot` (rev 3, F1 falsekill) | **∧** — bare `AUTONOMOUS_CONF_LOADED_FROM` fires from operator-sourced `autonomous.conf`; `CC_USER=autonomous-{dev,review}-bot` is set only inside the two wrapper entry points, so the conjunction is required for the legacy-signature arm to authorize a kill. Under `∨` an operator SSM debug session (no `TERM_PROGRAM`) sourcing the conf poisons every long-lived child. |

---

## 13. Attack-verification ledger

One line per integrated finding — lens : ID — what changed:

- **timing:F1** — Atomic mint via `lanes/.pending-<id>/` + `mv -T`; `lane_install` populates WRAPPER_PID/START/FINGERPRINT/CREATED_EPOCH/STATE=live inside `.pending-*` **before** the atomic rename (§4-C1). Rule 1.5 becomes age-bounded (unparseable ∧ age > 24 h → collect via 1.4). `kill_stale_wrapper` delegate falls through to legacy path on parse failure. New INV-107 wording ("atomic install").
- **timing:F2** — FIFO open order reversed: wrapper `exec {ADT_GUARD_FD}<>` **before** spawning guardian (§4-C3, INV-109). Guardian gains a 15 s no-writer watchdog as a defensive backstop.
- **timing:F3** — Rule 1.3 arithmetic re-cast: `(guardian dead ∨ reaping > 5 min) ∧ (age > 600 s ∨ STATE ∈ {reaping,cleaning})`; stale-reaping lanes are always eligible (§6 Pass 1).
- **timing:F4** — `STATE=cleaning` added to the state set (§4-C1); `cleanup()` takes `reap.lock` (shared with `do_reap` and `lane_kill`), sets `cleaning`, reaps, sends FIFO handshake, promotes to `clean-exit`, then network work. Guardian skip predicate broadened to `{clean-exit, cleaning, reaped-by-guardian, gc-reaped}`.
- **timing:F5** — `lane_kill` acquires `reap.lock` with bounded wait `grace + 2 s` when target's `GUARDIAN_PID` alive ∧ `STATE=reaping`; delegate path in `kill_stale_wrapper` blocks on the same lock before spawning W2 (§4-C4 choreography rows 3 & 4). Prevents guardian/delegate double-reap and recycled-pgid-eats-W2's-group tail.
- **timing:F6** — §10 residual reworded honestly: grep test "guards literal sites only; syntactic variants (pipeline subshells, `bash -c '…'` strings) are an accepted graceful-degradation surface".
- **timing:F7** — macOS `WRAPPER_FINGERPRINT=sha256(comm‖ppid‖lstart)` recorded at mint; rule 1.1 requires fingerprint match on macOS (§4-C1, §6, §7).
- **falsekill:F1** — Legacy-signature `∨` → `∧`: rule 2.1 requires `AUTONOMOUS_CONF_LOADED_FROM ∧ CC_USER=autonomous-{dev,review}-bot` (§6, INV-108). New R15 in §12.
- **falsekill:F2** — Unknown `ADT_LANE_ID` (not in any registry) is a skip, never a kill (§4-C2, §6 rule 2.1, INV-108, INV-110).
- **falsekill:F3** — Guardian escape sweep pinned to *this lane only* (§4-C3, INV-109); PR-5 AC (3) proves guardian A skips a process carrying lane B's tag.
- **falsekill:F4** — Rule 2.3 codified as argv-based (`pgrep -g $PG -f 'autonomous-(dev\|review)\.sh'`), not comm-name-based, to survive comm truncation and launcher-bridge exec (§6, INV-110). PR-4 AC (1) includes exec'd-through-launcher fixture.
- **falsekill:F5** — `pkill -P $$` pinned narrow in INV-106 wording and PR-3 AC (5): never widened to `-f <script-name>` (would cross-kill sibling lanes).
- **falsekill:F6** — INV-107 tightened: registry written "before ANY background child is spawned, including token daemons at `lib-auth.sh:128,:255-258`, heartbeat, and pre-agent utilities" — replacing "before the first spawn returns".
- **platform:F1** — `setsid` promoted to hard prereq on both platforms; macOS installs via `brew install util-linux` (same keg as flock); `& disown` fallback dropped (§4-C3, §7, INV-109). PR-5 AC (7) proves macOS refusal to spawn without `setsid`.
- **platform:F2** — macOS env-read via `sysctl kern.procargs2` `python3` shim (argc-delimited); `ps eww` banned for authorization (no argv/env delimiter). Until shim present, macOS GC is registry-authoritative only (env-tag = `--dry-run` diagnostic). §7 & INV-110 updated.
- **platform:F3** — Linger checked at backend-*selection* time in `_lane_backend`, not only at probe time (§4-C1, §4-C7, INV-113). PR-7 AC (2) proves linger=no host refuses systemd-scope with WARN.
- **platform:F4** — PR-5 AC (8) splits sole-holder-vs-inherited-fd EOF branches explicitly.
- **platform:F5** — `env_of` shim gates on `[ -r /proc/PID/environ ]`, never `[ -s ]`; grep-pin test forbids `[[ -s /proc/*/environ ]]` in lane/GC libs (§4-C2).
- **completeness:F1** — `ADT_STATE_ROOT` canonicalized to `$HOME/.local/state` (or explicit override), `XDG_STATE_HOME` deliberately ignored (§4-C1). `--doctor` fails loud when a wrapper-run host's root has no content. INV-107 wording added.
- **completeness:F2** — New RC6 in §1; Pass 4 flag-only sustained-CPU alert (§6, §4-C8); source fix `input=$(timeout 5 cat)` in git hooks (§4-C8, PR-1). Kill-under-live-lane forbidden by principle 5.
- **completeness:F3** — `install-gc-timer.sh` shipped as an idempotent per-host installer (crontab-edit Linux with fixed marker line, launchd plist + `launchctl bootstrap` macOS) alongside `adt-gc.sh` in PR-4; §9 ops sequencing calls out hand-symlink into the one legacy-style checkout.
- **completeness:F4** — §11 "macOS ACs decision" makes PR-2/3/5 macOS ACs required; PR-4 full macOS-runner ACs required with explicit deferral-before-PR-8-flip fallback if the runner is not yet in CI.
- **completeness:F5** — §10 residual row names macOS non-Chrome hardened-runtime-suppressed re-setsid descendants; §7 hardened-runtime row added.
- **completeness:F6** — §5 & §10 explicitly document that token daemons + heartbeat are not PGID-recorded (share wrapper's PGID); coverage is env-tag sweep + PPID watchdog + FIFO EOF.
- **completeness:F7** — Rule 1.2 tightened from 15 min to 5 min (§6 Pass 1); §10 keeps a wedged-guardian residual row with the new bound.
- **completeness:F8** — `ADT_GC_SUMMARY` metrics line emitted every run (§4-C5), consumed by INV-67 collector; soak alert on `would_kill_legacy_signature > 0` and `unknown_class` growth (§9 PR-8 sign-off criteria). `adt-gc.sh` self-rotates its log at 25 MB, single-generation (§5).
- **completeness:F9** — `pgids` schema notes the one-`write(2)`-per-line ≤ PIPE_BUF constraint in §5 and §4-C1.
- **completeness:F10** — INV-108 references the recorded-descendant precedent symbolically ("the shipped fan-out-reap invariant") — no fixed PR/INV number in the wording; numbering re-verified at PR-open per §10 residual.
- **selfdefeat:F1** — PR-6 scope grew from one file to four (§4-C6, §9 PR-6, §12 R5): adds `liveness-check-remote-aws-ssm.sh` (DEFERRED verdict), `lib-dispatch.sh` (schema + INV-30 doc), `dispatcher-tick.sh` (Step 5b fast-return). Mock-SSM AC pinned.
- **selfdefeat:F2** — Rule 2.4 extended with live-wrapper ancestry gate (`pgrep -f 'autonomous-(dev\|review)\.sh'` scoped by `PROJECT_DIR`, walk descendant tree — §6, INV-110). PR-8 additionally waits for all onboarded projects to run PR-2's atomic install (§9).
- **selfdefeat:F3** — `reap.lock` shared between `do_reap`, `lane_kill`, `cleanup()`, and GC (§4-C3/C4/C5); non-acquirer skips; guardian treats `STATE=gc-reaped` as no-op on wake.
- **selfdefeat:F4** — Rule 1.4 kills guardian first (TERM→1 s→KILL if `GUARDIAN_PID` alive) then `rm -rf`; `do_reap` tolerates ENOENT as "someone else finished" (§6, §4-C3).
- **selfdefeat:F5** — Guardian lifetime cap uses the same 60-s-chunked, PPID-checked pattern C8 mandates for the token daemon (§4-C3, INV-109).
- **selfdefeat:F6** — `--quick` uses `flock -w 3` instead of `-n` to avoid thundering-herd starvation (§4-C5).
- **selfdefeat:F7** — PR order swapped: registry (rev-3 PR-2) lands **before** kill-path hardening (rev-3 PR-3), because PR-3's TERM trap iterates durable registry pgids (§9, §12 R14).
- **selfdefeat:F8** — `adt-gc.log` self-rotates at 25 MB, single-generation, one box-wide path `$ADT_STATE_ROOT/adt-gc.log` (§4-C5, §5).
