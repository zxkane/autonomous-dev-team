#!/bin/bash
# adt-gc.sh — Lane-GC series PR-4: periodic, issue-independent garbage
# collector (design: docs/designs/lane-containment-gc.md §4-C5/§6;
# docs/designs/lane-gc-p4-adt-gc.md; shipped as INV-117 — the design doc's
# drafted INV-110 collided with shipped INV-106..115 from unrelated PRs
# (renumbered to INV-116 at PR-open), then a rebase pulled in #422's
# GitLab-transport invariant, which had independently and earlier-mergedly
# claimed INV-116 for itself — renumbered again to INV-117).
#
# Reclaims dead-lane process residue left behind when a wrapper (or its
# guardian, in a later PR) dies without a clean teardown. Box-wide and
# project-agnostic: scans every project's lane registry under
# ${ADT_STATE_ROOT}/autonomous-*/lanes/ in one invocation.
#
# Usage:
#   adt-gc.sh [--dry-run|--kill] [--quick] [--doctor] [-h|--help]
#
#   --dry-run   Classify and log every candidate; never signal anything.
#               DEFAULT until the series' final enforcement flip (PR-8) —
#               also the default whenever ADT_GC_ENFORCE is unset/not "1".
#   --kill      Actually TERM/KILL/rm-rf classified candidates. Same as
#               setting ADT_GC_ENFORCE=1 for this invocation.
#   --quick     Pass 1 (registry-driven) ONLY — no env reads, no same-uid
#               process enumeration. Meant for the opportunistic call at
#               the top of every dispatch-local.sh run, so it must be fast
#               and non-blocking: the singleton lock uses `flock -w 3`
#               (never `-n`) so a quick call queues briefly behind a
#               concurrent full run instead of unconditionally bailing out
#               (F6 selfdefeat — thundering-herd starvation under load).
#   --doctor    Read-only health report (timers, linger, flock, setsid,
#               backend, python3-on-macOS, ADT_STATE_ROOT content). Exits
#               0 clean / 1 on any [FAIL]. Does not take the GC lock.
#
# Exit codes: 0 success (incl. lock contention — GC is opportunistic, a
# missed run is never an error); 1 --doctor found a [FAIL]; 2 bad args.
#
# Not yet implemented (later Lane-GC PRs, not this issue): guardian-aware
# STATE=reaping ownership beyond a plain PID-liveness check on GUARDIAN_PID
# (PR-5 ships the guardian sidecar itself), systemd-scope cgroup.kill reap
# (PR-7), and the back-pressure admission gate (PR-6).

set -uo pipefail

# ---------------------------------------------------------------------------
# Resolution + sourcing
# ---------------------------------------------------------------------------
# [INV-65] LIB_DIR (readlink -f) sources siblings from the REAL skill tree
# regardless of which project's scripts/ symlink invoked us. GC is
# project-agnostic and never loads autonomous.conf, so unlike most entry
# scripts there is no separate unresolved conf-dir to compute.
_SELF="${BASH_SOURCE[0]:-$0}"
LIB_DIR="$(cd "$(dirname "$(readlink -f "$_SELF")")" && pwd)"

# shellcheck source=lib-lane.sh
source "${LIB_DIR}/lib-lane.sh"
# Metrics emission is best-effort and project-scoped (metrics_dir needs
# PROJECT_ID); GC has no single PROJECT_ID, so _gc_emit_metrics (below)
# loops per-project and sets PROJECT_ID locally for each emit. Absence of
# lib-metrics.sh degrades to "no metrics emitted" — GC's own log line is
# always the primary record regardless (design §4-C5 "log discipline").
# shellcheck source=lib-metrics.sh
source "${LIB_DIR}/lib-metrics.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
GC_MODE="dry-run"
[[ "${ADT_GC_ENFORCE:-}" == "1" ]] && GC_MODE="kill"
GC_QUICK=false
GC_DOCTOR=false

_gc_usage() {
  cat <<'EOF'
Usage: adt-gc.sh [--dry-run|--kill] [--quick] [--doctor] [-h|--help]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) GC_MODE="dry-run" ;;
    --kill)    GC_MODE="kill" ;;
    --quick)   GC_QUICK=true ;;
    --doctor)  GC_DOCTOR=true ;;
    -h|--help) _gc_usage; exit 0 ;;
    *) echo "adt-gc.sh: unknown argument: $1" >&2; _gc_usage >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$ADT_STATE_ROOT" 2>/dev/null || true
GC_LOG="${ADT_STATE_ROOT}/adt-gc.log"
GC_LOCK="${ADT_STATE_ROOT}/adt-gc.lock"
GC_PASS4_STATE="${ADT_STATE_ROOT}/adt-gc-pass4.state"

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# _gc_proc_age <pid> — thin wrapper over lib-lane.sh::proc_age with a
# test-only override seam (`_GC_PROC_AGE_OVERRIDE_<pid>`), mirroring the
# `_SESSION_LOG_PROBE_DRIVER_OVERRIDE`/`_LIVENESS_CHECK_DRIVER_OVERRIDE`
# pattern already used elsewhere in this skill. Pass 2/3's age floors
# (300s/600s/2h) cannot practically be waited out by a freshly-spawned
# test fixture process; production code always calls the real `proc_age`
# (no override set in production), a unit test sets the per-pid override
# to simulate an aged process without a real multi-minute sleep.
_gc_proc_age() {
  # [Lane-GC PR-4 review round-2 hardening] `local pid="$1" v="X${pid}"` in
  # ONE compound statement is a bash landmine: every RHS in a `local ...`
  # list is expanded BEFORE any assignment in that same statement takes
  # effect, so `${pid}` here would resolve via dynamic scoping to whatever
  # a CALLER's own local variable literally named `pid` holds (or crash
  # under `set -u` if no such caller-scope variable exists) — NOT the
  # value just assigned on this same line. Every current call site happens
  # to have an enclosing `pid` of the identical value, which is why this
  # "worked" by coincidence; splitting into two statements makes the
  # second's expansion see this function's OWN just-assigned value
  # unconditionally, regardless of what the caller's scope contains.
  local pid="$1"
  local override_var="_GC_PROC_AGE_OVERRIDE_${pid}"
  if [[ -n "${!override_var:-}" ]]; then
    printf '%s\n' "${!override_var}"
    return 0
  fi
  proc_age "$pid"
}

# _gc_env_readable <pid> — thin wrapper over lib-lane.sh::env_readable with
# a test-only override seam (`_GC_ENV_UNREADABLE_OVERRIDE_<pid>`), mirroring
# `_gc_proc_age`'s pattern immediately above. Same-uid `/proc/PID/environ`
# is ALWAYS readable in a unit-test sandbox (the fixture and the test
# harness run as the same user), so there is no practical way to make a
# real process's env genuinely unreadable to prove the P1-2 fail-closed
# fix behaviorally — production code always calls the real `env_readable`
# (no override set in production); a unit test sets the per-pid override
# to simulate the "env unreadable" case (dead-mid-scan / EPERM / macOS
# without the shim) without needing a privilege-dropped or cross-uid
# fixture process.
_gc_env_readable() {
  # See `_gc_proc_age`'s comment for why this is two statements, not one
  # compound `local` — the same dynamic-scoping landmine applies here.
  local pid="$1"
  local override_var="_GC_ENV_UNREADABLE_OVERRIDE_${pid}"
  if [[ -n "${!override_var:-}" ]]; then
    return 1
  fi
  env_readable "$pid"
}

# _gc_now_ms — epoch milliseconds. GNU date supports %3N; BSD/macOS date
# does not, so the fallback degrades to whole-second precision (still
# monotonic-enough for a single run's elapsed_ms field, which is telemetry
# only — never a decision input).
_gc_now_ms() {
  local ms
  ms="$(date +%s%3N 2>/dev/null)"
  if [[ "$ms" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$ms"
  else
    printf '%s\n' "$(( $(date +%s) * 1000 ))"
  fi
}

# _gc_rotate_log — single-generation rotation at 25MB (design §4-C5 "log
# discipline", mirrors dispatch-local.sh::prepare_agent_log's INV-68
# pattern). Never truncates below the threshold — GC's log is a running
# operator/soak record, not a per-run scratch file.
_gc_rotate_log() {
  if [[ ! -f "$GC_LOG" ]]; then
    install -m 600 /dev/null "$GC_LOG" 2>/dev/null || touch "$GC_LOG" 2>/dev/null || true
    return 0
  fi
  local size
  size="$(stat -c %s "$GC_LOG" 2>/dev/null || stat -f %z "$GC_LOG" 2>/dev/null || echo 0)"
  if [[ "$size" =~ ^[0-9]+$ ]] && [[ "$size" -gt $((25 * 1024 * 1024)) ]]; then
    mv -f "$GC_LOG" "${GC_LOG}.1" 2>/dev/null || true
    [[ -L "${GC_LOG}.1" ]] || chmod 600 "${GC_LOG}.1" 2>/dev/null || true
    install -m 600 /dev/null "$GC_LOG" 2>/dev/null || touch "$GC_LOG" 2>/dev/null || true
  fi
}

_gc_log() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo -)" "$*" >> "$GC_LOG" 2>/dev/null || true
}

# _gc_state_age <lane_dir> <now_epoch> — approximate "how long has this
# lane held its CURRENT STATE value" via the `lane` file's own mtime.
# There is no dedicated STATE-transition-timestamp field in the registry
# (design §5 lists no such key); every `lane_set` call rewrites-then-`mv`s
# the whole file, which updates its mtime on every STATE change — a
# reasonable proxy without a schema change (interpretation note recorded
# in docs/designs/lane-gc-p4-adt-gc.md).
_gc_state_age() {
  local lane_dir="$1" now="$2" mtime
  mtime="$(file_mtime "${lane_dir}/lane" 2>/dev/null)"
  [[ "$mtime" =~ ^[0-9]+$ ]] || { echo 999999; return 0; }
  echo $(( now - mtime ))
}

_gc_lane_age() {
  local lane_dir="$1" now="$2" created
  created="$(lane_get "$lane_dir" CREATED_EPOCH 2>/dev/null)"
  [[ "$created" =~ ^[0-9]+$ ]] || { echo 999999; return 0; }
  echo $(( now - created ))
}

# _gc_pending_age <pending_dir> <now_epoch> — age of a surviving
# `.pending-*` dir (rule 1.4 third clause). Falls back to the dir's own
# mtime since a mid-crash `.pending-*` may or may not have a `lane` file.
_gc_pending_age() {
  local dir="$1" now="$2" mtime
  mtime="$(file_mtime "${dir}/lane" 2>/dev/null)" || mtime="$(file_mtime "$dir" 2>/dev/null)"
  [[ "$mtime" =~ ^[0-9]+$ ]] || { echo 0; return 0; }
  echo $(( now - mtime ))
}

# _gc_all_lane_dirs — echo every FINAL-named (non-.pending) lane dir path
# across every project's registry, one per line.
_gc_all_lane_dirs() {
  local lanes_dir lane_dir base
  for lanes_dir in "$ADT_STATE_ROOT"/autonomous-*/lanes; do
    [[ -d "$lanes_dir" ]] || continue
    for lane_dir in "$lanes_dir"/*/; do
      [[ -d "$lane_dir" ]] || continue
      lane_dir="${lane_dir%/}"
      base="$(basename "$lane_dir")"
      [[ "$base" == .pending-* ]] && continue
      printf '%s\n' "$lane_dir"
    done
  done
}

_gc_all_pending_dirs() {
  local lanes_dir dir base
  for lanes_dir in "$ADT_STATE_ROOT"/autonomous-*/lanes; do
    [[ -d "$lanes_dir" ]] || continue
    for dir in "$lanes_dir"/.pending-*/; do
      [[ -d "$dir" ]] || continue
      dir="${dir%/}"
      printf '%s\n' "$dir"
    done
  done
}

# _gc_lane_dir_for_id <lane_id> — resolve a lane id string
# (`<project>:<role>:<issue>:<epoch>:<rand4>`) to its registry dir path, or
# nothing + rc 1 when the project prefix has no such dir. Distinct from
# lib-lane.sh's own `lane_dir` (which just computes the path — it does not
# check existence).
_gc_lane_dir_for_id() {
  local lane_id="$1" proj d
  proj="${lane_id%%:*}"
  [[ -n "$proj" && "$proj" != "$lane_id" ]] || return 1
  d="$(lane_dir "$proj" "$lane_id" 2>/dev/null)" || return 1
  [[ -d "$d" ]] || return 1
  printf '%s\n' "$d"
}

# _gc_emit_summary_metric <event> <k=v...> — best-effort metrics_emit,
# scoped per-project since metrics_dir needs PROJECT_ID. No-ops cleanly
# when lib-metrics.sh isn't sourced (declare -F guard).
_gc_emit_metric() {
  declare -F metrics_emit >/dev/null 2>&1 || return 0
  local project_id="$1"; shift
  ( PROJECT_ID="$project_id" metrics_emit "$@" ) 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Pass 1 — registry-driven (design §6, no env reads; runs under --quick)
# ---------------------------------------------------------------------------
SKIPS=0
WOULD_KILL=0
KILLED=0
WOULD_KILL_LEGACY=0
UNKNOWN_CLASS=0
LIVE_BURNER_ALERTS=0

# _gc_own_pgid — cache-once, echo THIS process's own pgid (numeric string).
# Every kill-authorization site consults this to refuse touching its own
# group; computed once since it cannot change during a single run.
_GC_OWN_PGID=""
_gc_own_pgid() {
  if [[ -z "$_GC_OWN_PGID" ]]; then
    _GC_OWN_PGID="$(proc_pgid "$$" 2>/dev/null || echo "")"
  fi
  printf '%s\n' "$_GC_OWN_PGID"
}

# _gc_safe_kill_pid <pid> — [Lane-GC PR-4 review round-2, P1-3] true iff
# <pid> is a SAFE individual-kill target: numeric, and NOT this process's
# own $$. Every individual-PID kill site (`_gc_term_then_kill_pid`, rule
# 1.4's guardian kill, `_gc_kill_candidate`'s pgid-invalid fallback) MUST
# gate on this before signaling — `_gc_same_uid_pids` already excludes
# `$$` from Pass 2/3's OWN candidate enumeration, but that exclusion lives
# in one call site and does not protect callers reached indirectly (rule
# 1.4's `GUARDIAN_PID` comes from registry content, not the same-uid
# enumeration, so it has no such built-in exclusion).
_gc_safe_kill_pid() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  [[ "$pid" != "$$" ]]
}

# _gc_safe_kill_pgid <pgid> — [Lane-GC PR-4 review round-2, P1-3] true iff
# <pgid> is a SAFE process-GROUP kill target: numeric, > 1 (pgid 0 is a
# kernel alias for "the SENDER's own process group" — `kill -TERM -- -0`
# or a bare `kill -TERM 0` signals US, not any classified candidate; pgid
# 1 is the init/systemd group and must never be targeted regardless), and
# not equal to this process's OWN pgid (`_gc_own_pgid`) — a `proc_pgid`
# read racing a process's exit, or any future refactor that lets a
# candidate's pgid alias GC's own group, must never be able to
# self-signal. Every group-form kill site (`_gc_kill_candidate`,
# `_kill_group_escalate` callers here) gates on this FIRST.
_gc_safe_kill_pgid() {
  local pg="$1" own_pg
  [[ "$pg" =~ ^[0-9]+$ ]] || return 1
  [[ "$pg" -gt 1 ]] || return 1
  own_pg="$(_gc_own_pgid)"
  [[ -z "$own_pg" || "$pg" != "$own_pg" ]]
}

# _gc_term_then_kill_pid <pid> — individual-PID TERM->1s->KILL (the
# non-group escalation shape rule 1.4's guardian-first kill and Pass 2/3's
# _gc_kill_candidate fallback both need). Distinct from lib-lane.sh's
# `_kill_group_escalate` (which signals a whole process GROUP over a 10s
# grace) — this is the shorter, single-pid variant used where there is no
# group to reach (a guardian pid, or a candidate whose pgid lookup failed).
# [P1-3] Refuses to signal unless `_gc_safe_kill_pid` clears it — this is
# the LAST line of defense before every individual-pid kill in this file.
_gc_term_then_kill_pid() {
  local pid="$1"
  _gc_safe_kill_pid "$pid" || return 0
  kill -TERM "$pid" 2>/dev/null || true
  sleep 1
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  return 0
}

# _gc_rule14_reap <lane_dir_or_pending_dir> — rule 1.4: TERM->1s->KILL the
# guardian FIRST (if `GUARDIAN_PID` alive), THEN rm -rf the dir. Killing the
# guardian before removal avoids parking it on `guard.fifo` for up to its
# hard lifetime cap when the dir it's watching vanishes out from under it
# (design §4-C5/§10 selfdefeat:F4).
_gc_rule14_reap() {
  local dir="$1" guardian_pid
  guardian_pid="$(lane_get "$dir" GUARDIAN_PID 2>/dev/null)" || guardian_pid="-"
  if [[ "$guardian_pid" =~ ^[0-9]+$ ]] && kill -0 "$guardian_pid" 2>/dev/null; then
    [[ "$GC_MODE" == "kill" ]] && _gc_term_then_kill_pid "$guardian_pid"
  fi
  if [[ "$GC_MODE" == "kill" ]]; then
    rm -rf "$dir" 2>/dev/null || true
    KILLED=$((KILLED + 1))
    _gc_log "kill rule=1.4 dir=$dir action=rm-rf-after-guardian-term"
  else
    WOULD_KILL=$((WOULD_KILL + 1))
    _gc_log "would-kill rule=1.4 dir=$dir action=rm-rf-after-guardian-term"
  fi
}

_gc_pass1_pending() {
  local dir="$1" now="$2" age
  age="$(_gc_pending_age "$dir" "$now")"
  if [[ "$age" -gt 86400 ]]; then
    _gc_rule14_reap "$dir"
  else
    SKIPS=$((SKIPS + 1))
    _gc_log "skip rule=1.4-pending-not-yet-24h dir=$dir age=${age}s"
  fi
}

_gc_pass1_lane() {
  local lane_dir="$1" now="$2"
  local liveness state guardian_pid

  liveness="$(lane_probe "$lane_dir" 2>/dev/null)"

  if [[ "$liveness" == "unknown" ]]; then
    local age
    age="$(_gc_pending_age "$lane_dir" "$now")"
    if [[ "$age" -gt 86400 ]]; then
      _gc_rule14_reap "$lane_dir"
    else
      SKIPS=$((SKIPS + 1))
      _gc_log "skip rule=1.5 lane=$lane_dir reason=unparseable age=${age}s"
    fi
    return 0
  fi

  state="$(lane_get "$lane_dir" STATE 2>/dev/null || echo "")"

  if [[ "$liveness" == "live" ]]; then
    SKIPS=$((SKIPS + 1))
    _gc_log "skip rule=1.1 lane=$lane_dir reason=live state=$state"
    return 0
  fi

  # liveness == dead, parseable.
  case "$state" in
    clean-exit|reaped-by-guardian|gc-reaped)
      local term_age
      term_age="$(_gc_state_age "$lane_dir" "$now")"
      if [[ "$term_age" -gt 86400 ]]; then
        _gc_rule14_reap "$lane_dir"
      else
        SKIPS=$((SKIPS + 1))
        _gc_log "skip rule=1.4-terminal-not-yet-24h lane=$lane_dir state=$state age=${term_age}s"
      fi
      return 0
      ;;
  esac

  guardian_pid="$(lane_get "$lane_dir" GUARDIAN_PID 2>/dev/null || echo -)"
  local guardian_alive=false
  [[ "$guardian_pid" =~ ^[0-9]+$ ]] && kill -0 "$guardian_pid" 2>/dev/null && guardian_alive=true

  if [[ "$state" == "reaping" && "$guardian_alive" == true ]]; then
    local reaping_age
    reaping_age="$(_gc_state_age "$lane_dir" "$now")"
    if [[ "$reaping_age" -lt 300 ]]; then
      SKIPS=$((SKIPS + 1))
      _gc_log "skip rule=1.2 lane=$lane_dir reason=guardian-owns-reap state_age=${reaping_age}s"
      return 0
    fi
  fi

  # Wedged (guardian dead, or reaping beyond the 5min tightened bound) —
  # rule 1.3. Arithmetic note (design §6 F3 timing): a STATE=reaping/
  # cleaning lane is ALWAYS reap-eligible regardless of overall lane age;
  # otherwise the lane age must exceed the 600s floor.
  local lane_age
  lane_age="$(_gc_lane_age "$lane_dir" "$now")"
  if [[ "$lane_age" -gt 600 || "$state" == "reaping" || "$state" == "cleaning" ]]; then
    if [[ "$GC_MODE" == "kill" ]]; then
      lane_kill "$lane_dir" 10 || true
      lane_set_state "$lane_dir" gc-reaped || true
      KILLED=$((KILLED + 1))
      _gc_log "kill rule=1.3 lane=$lane_dir state=$state lane_age=${lane_age}s"
    else
      WOULD_KILL=$((WOULD_KILL + 1))
      _gc_log "would-kill rule=1.3 lane=$lane_dir state=$state lane_age=${lane_age}s"
    fi
  else
    SKIPS=$((SKIPS + 1))
    _gc_log "skip rule=1.3-not-eligible lane=$lane_dir state=$state lane_age=${lane_age}s"
  fi
}

_gc_pass1() {
  local now lane_dir dir
  now="$(date +%s)"
  while IFS= read -r lane_dir; do
    [[ -n "$lane_dir" ]] || continue
    _gc_pass1_lane "$lane_dir" "$now"
  done < <(_gc_all_lane_dirs)
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    _gc_pass1_pending "$dir" "$now"
  done < <(_gc_all_pending_dirs)
}

# ---------------------------------------------------------------------------
# Pass 2 — tagged-orphan sweep (design §6; same-uid process enumeration)
# ---------------------------------------------------------------------------

# _gc_same_uid_pids — every PID owned by this uid, one per line, excluding
# THIS process (self-match safety, design §4-C5 "grep -vw $$"). Cached
# after the first call (`_GC_SAME_UID_PIDS_CACHED` flag, since the PID set
# itself may legitimately be empty): Pass 2/3 call this from five separate
# sites (once per Pass-3 sub-rule plus once per dead-lane match in the two
# lane-scoped sub-rules), and the same-uid PID set cannot change meaning
# mid-run — re-shelling out to `ps`/`tr`/`grep` on every call is pure
# waste on exactly the incident (many orphans) GC exists to clean up.
# `--quick` (Pass 1 only) never calls this at all, so the AC-pinned "<1s
# on 50 lane dirs" Pass-1 budget is unaffected either way.
_GC_SAME_UID_PIDS_CACHED=false
_GC_SAME_UID_PIDS_CACHE=""
_gc_same_uid_pids() {
  if [[ "$_GC_SAME_UID_PIDS_CACHED" != true ]]; then
    _GC_SAME_UID_PIDS_CACHE="$(ps -eo pid= -U "$(id -u)" 2>/dev/null | tr -d ' ' | grep -vw "$$" || true)"
    _GC_SAME_UID_PIDS_CACHED=true
  fi
  [[ -n "$_GC_SAME_UID_PIDS_CACHE" ]] && printf '%s\n' "$_GC_SAME_UID_PIDS_CACHE"
  return 0
}

# _gc_has_term_program <pid> — rule 2.2's unconditional-skip test: true iff
# the process's env carries ANY TERM_PROGRAM value (operator tooling,
# including an operator hand-running a wrapper, is untouchable regardless
# of what else matches). Centralizes the identical
# `env_lookup … TERM_PROGRAM || echo ""` + emptiness check every Pass-2/3
# rule repeats.
#
# [Lane-GC PR-4 review round-2, P1-2] Deliberately does NOT itself decide
# the "env unreadable" case — that is `_gc_env_unknowable`'s job (below),
# called SEPARATELY and FIRST by every guard site. Collapsing both checks
# into one function would make "unreadable" and "readable-but-absent"
# indistinguishable to a caller that only checks a single boolean, which
# is the exact class of bug being fixed here: this function's OWN
# `env_lookup … || echo ""` fallback still can't tell why the lookup
# failed, so it must never be the only gate protecting a kill decision.
_gc_has_term_program() {
  [[ -n "$(env_lookup "$1" TERM_PROGRAM 2>/dev/null || echo "")" ]]
}

# _gc_env_unknowable <pid> — true iff this pid's environment cannot be
# read at all right now (fail-toward-leak per design principle 5: skip,
# never kill, whenever we cannot positively confirm the ABSENCE of
# TERM_PROGRAM or any other env-tag signal). MUST be checked before, and
# independently of, `_gc_has_term_program`/`env_lookup` at every
# kill-authorization site in Pass 2/3 — see `_gc_common_kill_guards`.
_gc_env_unknowable() {
  ! _gc_env_readable "$1"
}

# _gc_group_has_live_wrapper <pgid> — rule 2.3: argv-based (never
# comm-name-based) match, so it survives comm truncation and the
# launcher-bridge exec chain one consumer project uses.
_gc_group_has_live_wrapper() {
  local pg="$1"
  pgrep -g "$pg" -f 'autonomous-(dev|review)\.sh' 2>/dev/null | grep -vqw "$$"
}

# _gc_pgid_in_live_lane_pgids <pgid> — rule 2.4 first conjunct: is this
# pgid recorded in any currently-LIVE lane's `pgids` file?
_gc_pgid_in_live_lane_pgids() {
  local pg="$1" lane_dir
  while IFS= read -r lane_dir; do
    [[ -n "$lane_dir" ]] || continue
    [[ "$(lane_probe "$lane_dir" 2>/dev/null)" == "live" ]] || continue
    grep -qE "^${pg} " "${lane_dir}/pgids" 2>/dev/null && return 0
  done < <(_gc_all_lane_dirs)
  return 1
}

# _gc_pgid_is_live_pidfile_pgid <pgid> — rule 2.4 second conjunct: best-
# effort scan of PID-file locations (`pid_dir_for_project`'s two possible
# roots — see docs/designs/lane-gc-p4-adt-gc.md interpretation notes: GC
# has no per-project manifest of which projects override AUTONOMOUS_PID_DIR,
# so this is deliberately best-effort, never exhaustive; the registry
# check above is the exact-join primary path for any PR-2-onward wrapper).
_gc_pgid_is_live_pidfile_pgid() {
  local pg="$1" root f pid fpg
  for root in "$ADT_STATE_ROOT" "${XDG_RUNTIME_DIR:-}"; do
    [[ -n "$root" && -d "$root" ]] || continue
    for f in "$root"/autonomous-*/*.pid; do
      [[ -f "$f" ]] || continue
      pid="$(cat "$f" 2>/dev/null)"
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      kill -0 "$pid" 2>/dev/null || continue
      fpg="$(proc_pgid "$pid" 2>/dev/null || echo "")"
      [[ "$fpg" == "$pg" ]] && return 0
    done
  done
  return 1
}

# _gc_pgid_in_live_wrapper_ancestry <pgid> — rule 2.4 third conjunct
# (F2 selfdefeat): walks every live wrapper's descendant tree (BFS via
# `pgrep -P`, box-wide — see docs/designs/lane-gc-p4-adt-gc.md's
# interpretation note on why this is NOT scoped per-PROJECT_DIR) and
# checks whether <pgid> belongs to the wrapper itself or any descendant.
# Protects an old-format / mid-upgrade live wrapper's daemons (ppid==1,
# no lane dir of their own) from being swept as orphan residue.
_gc_pgid_in_live_wrapper_ancestry() {
  local pg="$1" wp wpg queue cur kids k kpg
  while IFS= read -r wp; do
    [[ -n "$wp" ]] || continue
    wpg="$(proc_pgid "$wp" 2>/dev/null || echo "")"
    [[ "$wpg" == "$pg" ]] && return 0
    queue="$wp"
    while [[ -n "$queue" ]]; do
      cur="${queue%%$'\n'*}"
      if [[ "$queue" == *$'\n'* ]]; then queue="${queue#*$'\n'}"; else queue=""; fi
      kids="$(pgrep -P "$cur" 2>/dev/null || true)"
      [[ -z "$kids" ]] && continue
      for k in $kids; do
        kpg="$(proc_pgid "$k" 2>/dev/null || echo "")"
        [[ "$kpg" == "$pg" ]] && return 0
        queue="${queue:+$queue$'\n'}$k"
      done
    done
  done < <(pgrep -f 'autonomous-(dev|review)\.sh' 2>/dev/null | grep -vw "$$" || true)
  return 1
}

# _gc_common_kill_guards <pid> <pg> <age_floor> [rule_id] — [Lane-GC PR-4
# review round-2, Class A / P1-1, P1-4, P2-1] the ONE shared guard set
# every Pass-2/3 kill-authorization site must clear before signaling
# anything. <pg> is the candidate's pgid, resolved by the CALLER (every
# call site already needs it for its own `_gc_kill_candidate`/log-line
# purposes, so this function does not re-resolve it). Returns 0 when
# every guard passes; returns 1 (caller must skip) otherwise. Order
# matters: cheapest/most decisive checks first so a rejected candidate
# short-circuits before any process-table walk.
#
#   1. env-unknowable  → skip (fail toward leak; P1-2's fix, checked
#      FIRST and SEPARATELY from TERM_PROGRAM so an unreadable env is
#      never silently treated as "TERM_PROGRAM absent"; logged with its
#      own reason when [rule_id] is given, per the design's
#      registry-authoritative-only posture on macOS-without-shim)
#   2. TERM_PROGRAM present → skip (rule 2.2, unconditional)
#   3. age < floor → skip (the caller passes ITS OWN floor: 300s/600s
#      exact-vs-legacy for rule 2, and per Pass-3 sub-rule below)
#   4. pgid is a SAFE kill target (`_gc_safe_kill_pgid` — numeric, not
#      0/1, not GC's own group; P1-3's self/pgid-0 fix)
#   5. `_gc_group_has_live_wrapper` — pgid contains no live wrapper-argv
#      match (rule 2.3)
#   6. `_gc_pgid_in_live_lane_pgids` — pgid not recorded by any live lane
#      (rule 2.4 first conjunct)
#   7. `_gc_pgid_is_live_pidfile_pgid` — pgid not a live PID-file's own
#      group (rule 2.4 second conjunct)
#   8. `_gc_pgid_in_live_wrapper_ancestry` — pgid outside every live
#      wrapper's descendant tree (rule 2.4 third conjunct)
#
# Before this PR's round-2 fix, Pass 2 alone applied this full set;
# EVERY Pass-3 sub-rule (3.1 lane-scoped Chrome, 3.2 Chrome heuristic,
# 3.3 wedged gh, 3.4 E2E servers) applied only an ARBITRARY SUBSET —
# 3.4 applied NONE of it at all (P1-1: an operator shell cwd'd inside a
# since-removed worktree directory was killable outright, whole pgid,
# no TERM_PROGRAM check, no age floor, no live-anything guard); 3.2
# omitted the design's two Chrome-specific conjuncts (added separately,
# see `_gc_pass3_chrome_heuristic`); 3.3 computed an age but never
# compared it to a floor and omitted the live-lane-pgids/live-pidfile-pgid
# checks (P2-1). Extracting one function that EVERY rule calls makes the
# guard set structurally impossible to omit a conjunct from again — a
# future Pass-3 rule that skips calling this has an immediately visible
# gap in its own body, rather than a silently-incomplete inline copy.
_gc_common_kill_guards() {
  local pid="$1" pg="$2" age_floor="$3" rule_id="${4:-}" age

  if _gc_env_unknowable "$pid"; then
    if [[ -n "$rule_id" ]]; then
      SKIPS=$((SKIPS + 1))
      _gc_log "skip rule=${rule_id}-env-unreadable pid=$pid reason=env-unknowable-fail-toward-leak"
    fi
    return 1
  fi
  _gc_has_term_program "$pid" && return 1

  age="$(_gc_proc_age "$pid" 2>/dev/null || echo 0)"
  [[ "$age" =~ ^[0-9]+$ ]] || age=0
  [[ "$age" -ge "$age_floor" ]] || return 1

  _gc_safe_kill_pgid "$pg" || return 1

  _gc_group_has_live_wrapper "$pg" && return 1
  _gc_pgid_in_live_lane_pgids "$pg" && return 1
  _gc_pgid_is_live_pidfile_pgid "$pg" && return 1
  _gc_pgid_in_live_wrapper_ancestry "$pg" && return 1

  return 0
}

# _gc_kill_candidate <pid> <pgid> <rule> — apply the design's TERM->10s->
# KILL escalation (group-form where the pgid is real, individual-pid form
# as a fallback) under `reap.lock`-free best-effort (GC's own kills are
# non-lane, so there is no per-lane lock to take — design §4-C4 row 6:
# "Take reap.lock (non-blocking; skip if held) — a live guardian is
# authoritative" only applies to lane-scoped kills; Pass 2/3 candidates by
# definition have no live lane, so no reap.lock exists to take).
_gc_kill_candidate() {
  local pid="$1" pg="$2"
  # [P1-3] Group-form is authorized ONLY through `_gc_safe_kill_pgid` —
  # numeric, > 1, and not GC's own pgid (see that function's own comment
  # for why pgid 0/1 and self-pgid are all refused here rather than
  # trusting the caller to have filtered them out already: this is the
  # LAST line of defense before the group-form kill fires). The pid-form
  # fallback is gated by `_gc_term_then_kill_pid`'s own `_gc_safe_kill_pid`
  # check, so a bad pgid never silently escalates to an unsafe pid kill.
  if _gc_safe_kill_pgid "$pg"; then
    _kill_group_escalate "$pg" 10
  else
    _gc_term_then_kill_pid "$pid"
  fi
}

_gc_pass2() {
  local pid lane_id pg is_legacy eligible age_floor
  local conf_loaded cc_user ppid lane_dir_match
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue

    # [P1-2] env-unknowable is checked HERE too (not only inside
    # `_gc_common_kill_guards` below) because Pass 2's OWN eligibility
    # decision (rules 2.1's exact-join vs the legacy-signature arm) reads
    # ADT_LANE_ID/AUTONOMOUS_CONF_LOADED_FROM/CC_USER directly — an
    # unreadable env must skip BEFORE those reads are even attempted, not
    # just before the final kill. `_gc_has_term_program`'s own
    # `env_lookup … || echo ""` fallback can't distinguish "unreadable"
    # from "TERM_PROGRAM absent", so this early env-unknowable check is
    # the fix, not a redundant belt-and-suspenders duplicate of the guard
    # function's own internal check (which still applies again below,
    # defending the age/pgid/live-* conjuncts against a TOCTOU env change
    # between here and there).
    if _gc_env_unknowable "$pid"; then
      SKIPS=$((SKIPS + 1))
      _gc_log "skip rule=2-env-unreadable pid=$pid reason=env-unknowable-fail-toward-leak"
      continue
    fi
    _gc_has_term_program "$pid" && continue  # rule 2.2 — unconditional skip

    is_legacy=false
    eligible=false
    age_floor=0

    lane_id="$(env_lookup "$pid" ADT_LANE_ID 2>/dev/null || echo "")"
    if [[ -n "$lane_id" ]]; then
      lane_dir_match="$(_gc_lane_dir_for_id "$lane_id" 2>/dev/null || echo "")"
      if [[ -z "$lane_dir_match" ]]; then
        # rule 2.1: unknown ADT_LANE_ID (absent from any registry) — skip,
        # never kill.
        UNKNOWN_CLASS=$((UNKNOWN_CLASS + 1))
        _gc_log "skip rule=2.1-unknown-lane-id pid=$pid lane_id=$lane_id"
        continue
      fi
      if [[ "$(lane_probe "$lane_dir_match" 2>/dev/null)" == "dead" ]]; then
        eligible=true
        age_floor=300
      fi
    else
      conf_loaded="$(env_lookup "$pid" AUTONOMOUS_CONF_LOADED_FROM 2>/dev/null || echo "")"
      cc_user="$(env_lookup "$pid" CC_USER 2>/dev/null || echo "")"
      ppid="$(proc_ppid "$pid" 2>/dev/null || echo "")"
      # Banned-keys note: this is the ONLY place ppid is consulted, and it
      # is ALWAYS in conjunction with the conf+CC_USER signature and the
      # age floor below — never as a bare `ppid==1` kill key on its own
      # (design's explicit banned-keys list, §6).
      if [[ -n "$conf_loaded" ]] && [[ "$cc_user" =~ ^autonomous-(dev|review)-bot$ ]] && [[ "$ppid" == "1" ]]; then
        eligible=true
        is_legacy=true
        age_floor=600
      fi
    fi

    [[ "$eligible" == true ]] || continue

    pg="$(proc_pgid "$pid" 2>/dev/null || echo "")"
    _gc_common_kill_guards "$pid" "$pg" "$age_floor" || continue

    if [[ "$GC_MODE" == "kill" ]]; then
      _gc_kill_candidate "$pid" "$pg"
      KILLED=$((KILLED + 1))
      _gc_log "kill rule=2 pid=$pid pgid=$pg legacy=$is_legacy argv=$(proc_argv "$pid" 2>/dev/null | head -1)"
    else
      WOULD_KILL=$((WOULD_KILL + 1))
      [[ "$is_legacy" == true ]] && WOULD_KILL_LEGACY=$((WOULD_KILL_LEGACY + 1))
      _gc_log "would-kill rule=2 pid=$pid pgid=$pg legacy=$is_legacy argv=$(proc_argv "$pid" 2>/dev/null | head -1)"
    fi
  done < <(_gc_same_uid_pids)
}

# ---------------------------------------------------------------------------
# Pass 3 — env-blind classes (design §6)
# ---------------------------------------------------------------------------

_gc_pass3_chrome_lane_scoped() {
  local lane_dir hint pid argv pg
  while IFS= read -r lane_dir; do
    [[ -n "$lane_dir" ]] || continue
    [[ "$(lane_probe "$lane_dir" 2>/dev/null)" == "dead" ]] || continue
    hint="$(lane_get "$lane_dir" CHROME_PROFILE_HINT 2>/dev/null || echo -)"
    [[ -n "$hint" && "$hint" != "-" ]] || continue
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      argv="$(proc_argv "$pid" 2>/dev/null | tr '\n' ' ')"
      [[ "$argv" == *"--user-data-dir=${hint}"* || "$argv" == *"$hint"* ]] || continue
      pg="$(proc_pgid "$pid" 2>/dev/null || echo "")"
      # [Lane-GC PR-4 review round-2, P1-1 class fix] age_floor=0 — design
      # §6 row 3.1 lists no age conjunct for this rule; the dead-lane
      # CHROME_PROFILE_HINT match is already an exact, positive join (same
      # confidence class as rule 2.1's exact ADT_LANE_ID join). Every OTHER
      # shared guard now applies too — pre-fix this rule checked ONLY
      # TERM_PROGRAM, nothing else.
      _gc_common_kill_guards "$pid" "$pg" 0 "3.1" || continue
      if [[ "$GC_MODE" == "kill" ]]; then
        _gc_kill_candidate "$pid" "$pg"
        KILLED=$((KILLED + 1))
        _gc_log "kill rule=3.1 pid=$pid lane=$lane_dir hint=$hint"
      else
        WOULD_KILL=$((WOULD_KILL + 1))
        _gc_log "would-kill rule=3.1 pid=$pid lane=$lane_dir hint=$hint"
      fi
    done < <(_gc_same_uid_pids)
  done < <(_gc_all_lane_dirs)
}

# _gc_chrome_profile_has_live_sharer <profile_dir> <exclude_pid> — rule
# 3.2's first rule-local extra conjunct (design §6 row 3.2 / §5 line 215:
# "no live process shares that profile dir"). Kept OUTSIDE
# `_gc_common_kill_guards` — no other Pass-3 rule keys on a shared
# filesystem profile directory, so this concept has exactly one caller.
_gc_chrome_profile_has_live_sharer() {
  local profile_dir="$1" exclude_pid="$2" pid argv
  while IFS= read -r pid; do
    [[ -n "$pid" && "$pid" != "$exclude_pid" ]] || continue
    argv="$(proc_argv "$pid" 2>/dev/null | tr '\n' ' ')"
    [[ "$argv" == *"--user-data-dir=${profile_dir}"* ]] && return 0
  done < <(_gc_same_uid_pids)
  return 1
}

# _gc_chrome_has_live_mcp_parent <pid> — rule 3.2's second rule-local
# extra conjunct (design §6 row 3.2 / §5 line 215: "no live
# chrome-devtools-mcp parent... Operator chromes have a live MCP parent,
# so ppid≠1 — validated live"). The caller already requires ppid==1, so a
# genuinely orphaned chrome has no live ancestor at all in the common
# case; this is defense-in-depth for a subreaper/race shape where the
# ppid==1 read and this check straddle a respawn, or a containerized
# subreaper re-adopts the chrome while an MCP server process remains
# alive. Walks the live descendant tree of every live
# chrome-devtools-mcp-matching process (same BFS technique as
# `_gc_pgid_in_live_wrapper_ancestry`) and also checks the immediate ppid
# directly.
_gc_chrome_has_live_mcp_parent() {
  local pid="$1" ppid mp queue cur kids k
  ppid="$(proc_ppid "$pid" 2>/dev/null || echo "")"
  while IFS= read -r mp; do
    [[ -n "$mp" ]] || continue
    [[ "$mp" == "$ppid" ]] && return 0
    queue="$mp"
    while [[ -n "$queue" ]]; do
      cur="${queue%%$'\n'*}"
      if [[ "$queue" == *$'\n'* ]]; then queue="${queue#*$'\n'}"; else queue=""; fi
      kids="$(pgrep -P "$cur" 2>/dev/null || true)"
      [[ -z "$kids" ]] && continue
      for k in $kids; do
        [[ "$k" == "$pid" ]] && return 0
        queue="${queue:+$queue$'\n'}$k"
      done
    done
  done < <(pgrep -f 'chrome-devtools-mcp' 2>/dev/null | grep -vw "$$" || true)
  return 1
}

_gc_pass3_chrome_heuristic() {
  local pid argv ppid pg hint_dir
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    argv="$(proc_argv "$pid" 2>/dev/null | tr '\n' ' ')"
    [[ "$argv" == *"--user-data-dir=/tmp/puppeteer_dev_chrome_profile-"* ]] || continue
    ppid="$(proc_ppid "$pid" 2>/dev/null || echo "")"
    [[ "$ppid" == "1" ]] || continue
    pg="$(proc_pgid "$pid" 2>/dev/null || echo "")"
    # [Lane-GC PR-4 review round-2, P1-4 class fix] floor=7200 unchanged
    # from the pre-fix inline check (design row 3.2: "age > 2h"); the
    # shared guard's `-ge` vs the design's literal `>` differ by at most
    # 1s, immaterial at 10-min cron granularity. Every OTHER shared guard
    # now applies too — pre-fix this rule checked ONLY ppid==1, age, and
    # TERM_PROGRAM (no live-wrapper/live-lane-pgid/live-pidfile-pgid/
    # ancestry guards at all).
    _gc_common_kill_guards "$pid" "$pg" 7200 "3.2" || continue

    # [P1-4] rule-local extra conjuncts (design §6 row 3.2) — kept OUTSIDE
    # _gc_common_kill_guards; see the two helper functions' own docstrings.
    hint_dir="$(printf '%s' "$argv" | grep -oE -- '--user-data-dir=/tmp/puppeteer_dev_chrome_profile-[^ ]*' | head -1 | cut -d= -f2-)"
    if [[ -n "$hint_dir" ]] && _gc_chrome_profile_has_live_sharer "$hint_dir" "$pid"; then
      continue
    fi
    _gc_chrome_has_live_mcp_parent "$pid" && continue

    if [[ "$GC_MODE" == "kill" ]]; then
      _gc_kill_candidate "$pid" "$pg"
      KILLED=$((KILLED + 1))
      _gc_log "kill rule=3.2 pid=$pid"
    else
      WOULD_KILL=$((WOULD_KILL + 1))
      _gc_log "would-kill rule=3.2 pid=$pid"
    fi
  done < <(_gc_same_uid_pids)
}

_gc_pass3_wedged_gh() {
  local pid argv token_file pg
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    argv="$(proc_argv "$pid" 2>/dev/null | tr '\n' ' ')"
    [[ "$argv" == *"gh"*"pr"*"checks"*"--watch"* || "$argv" == *"gh"*"api"* ]] || continue

    # [P1-2 class parity] env-unknowable is checked HERE, before reading
    # GH_TOKEN_FILE, for the same reason Pass 2 checks it before reading
    # ADT_LANE_ID/CC_USER: this rule's OWN eligibility test reads the env
    # directly, so an unreadable env must be logged and skipped before
    # that read is even attempted, not just inside the shared guard below.
    if _gc_env_unknowable "$pid"; then
      SKIPS=$((SKIPS + 1))
      _gc_log "skip rule=3.3-env-unreadable pid=$pid reason=env-unknowable-fail-toward-leak"
      continue
    fi
    token_file="$(env_lookup "$pid" GH_TOKEN_FILE 2>/dev/null || echo "")"
    [[ "$token_file" == /tmp/agent-auth-* ]] || continue
    [[ -e "$(dirname "$token_file")" ]] && continue

    pg="$(proc_pgid "$pid" 2>/dev/null || echo "")"
    # [Lane-GC PR-4 review round-2, P2-1 class fix] floor=300 — design row
    # 3.3 says "∧ 2.2–2.5", inheriting rule 2's full conjunct set; 3.3 has
    # no ADT_LANE_ID/legacy-signature arm of its own, so there is no
    # direct analog to 2.1's floor SELECTOR. The GH_TOKEN_FILE-pattern +
    # dir-gone match is an exact, specific positive signal (same
    # confidence class as 2.1's exact ADT_LANE_ID join), so it gets that
    # join's tighter 300s floor rather than the legacy signature's weaker
    # 600s. Every OTHER shared guard now applies too — pre-fix this rule
    # computed an age but never compared it to ANY floor, and never
    # checked live-lane-pgids/live-pidfile-pgid (only live-wrapper-in-pgid
    # + ancestry).
    _gc_common_kill_guards "$pid" "$pg" 300 "3.3" || continue

    if [[ "$GC_MODE" == "kill" ]]; then
      _gc_kill_candidate "$pid" "$pg"
      KILLED=$((KILLED + 1))
      _gc_log "kill rule=3.3 pid=$pid"
    else
      WOULD_KILL=$((WOULD_KILL + 1))
      _gc_log "would-kill rule=3.3 pid=$pid"
    fi
  done < <(_gc_same_uid_pids)
}

_gc_pass3_e2e_servers() {
  local lane_dir worktree pid cwd pg
  while IFS= read -r lane_dir; do
    [[ -n "$lane_dir" ]] || continue
    [[ "$(lane_probe "$lane_dir" 2>/dev/null)" == "dead" ]] || continue
    worktree="$(lane_get "$lane_dir" WORKTREE 2>/dev/null || echo -)"
    [[ -n "$worktree" && "$worktree" != "-" ]] || continue
    [[ -e "$worktree" ]] && continue  # worktree still exists — not this rule
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      cwd="$(readlink "/proc/${pid}/cwd" 2>/dev/null || echo "")"
      [[ "$cwd" == "${worktree}"* || "$cwd" == "${worktree} (deleted)"* ]] || continue
      pg="$(proc_pgid "$pid" 2>/dev/null || echo "")"
      # [Lane-GC PR-4 review round-2, P1-1] this rule previously applied
      # NO guard at all before killing — no TERM_PROGRAM skip, no age
      # floor, no live-pgid/ancestry check — so an operator shell (or a
      # still-useful dev server) `cwd`'d inside a worktree directory that
      # has since been `rm -rf`'d got its WHOLE PGID killed outright.
      # floor=0: design row 3.4 lists no age conjunct (like 3.1, this is
      # an exact structural match — dead lane + WORKTREE path gone + cwd
      # still points there — not a fuzzy heuristic needing a wait).
      _gc_common_kill_guards "$pid" "$pg" 0 "3.4" || continue
      if [[ "$GC_MODE" == "kill" ]]; then
        _gc_kill_candidate "$pid" "$pg"
        KILLED=$((KILLED + 1))
        _gc_log "kill rule=3.4 pid=$pid lane=$lane_dir worktree=$worktree"
      else
        WOULD_KILL=$((WOULD_KILL + 1))
        _gc_log "would-kill rule=3.4 pid=$pid lane=$lane_dir worktree=$worktree"
      fi
    done < <(_gc_same_uid_pids)
  done < <(_gc_all_lane_dirs)
}

_gc_pass3() {
  _gc_pass3_chrome_lane_scoped
  _gc_pass3_chrome_heuristic
  _gc_pass3_wedged_gh
  _gc_pass3_e2e_servers
}

# ---------------------------------------------------------------------------
# Pass 4 — live-lane sustained-CPU alert (flag-only, NEVER kill)
# ---------------------------------------------------------------------------

_gc_pass4() {
  local now lane_dir pg pid cpu is_hooks_path cwd
  local -A seen_high=()
  now="$(date +%s)"

  # Load prior-tick "was high" state: `pid high_since_epoch`.
  local -A prior_high=()
  if [[ -f "$GC_PASS4_STATE" ]]; then
    while IFS=' ' read -r p e; do
      [[ "$p" =~ ^[0-9]+$ ]] || continue
      prior_high["$p"]="$e"
    done < "$GC_PASS4_STATE"
  fi

  while IFS= read -r lane_dir; do
    [[ -n "$lane_dir" ]] || continue
    [[ "$(lane_probe "$lane_dir" 2>/dev/null)" == "live" ]] || continue
    [[ -f "${lane_dir}/pgids" ]] || continue
    while IFS=' ' read -r pg _role _epoch; do
      [[ "$pg" =~ ^[0-9]+$ ]] || continue
      for pid in $(pgrep -g "$pg" 2>/dev/null || true); do
        cwd="$(readlink "/proc/${pid}/cwd" 2>/dev/null || echo "")"
        is_hooks_path=false
        [[ "$cwd" == *".worktrees/"*"/hooks/"* ]] && is_hooks_path=true
        [[ "$is_hooks_path" == true ]] || continue
        cpu="$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')"
        [[ "$cpu" =~ ^[0-9]+(\.[0-9]+)?$ ]] || continue
        # Integer-compare via awk (avoids a bash float-arithmetic dep).
        if awk -v c="$cpu" 'BEGIN{exit !(c>80)}'; then
          if [[ -n "${prior_high[$pid]:-}" ]]; then
            LIVE_BURNER_ALERTS=$((LIVE_BURNER_ALERTS + 1))
            _gc_log "LIVE_BURNER_ALERT lane=$lane_dir pid=$pid argv=$(proc_argv "$pid" 2>/dev/null | head -1) cpu_pct=$cpu age_s=$(( now - ${prior_high[$pid]} ))"
          fi
          seen_high["$pid"]="${prior_high[$pid]:-$now}"
        fi
      done
    done < "${lane_dir}/pgids"
  done < <(_gc_all_lane_dirs)

  {
    local p
    for p in "${!seen_high[@]}"; do
      printf '%s %s\n' "$p" "${seen_high[$p]}"
    done
  } > "${GC_PASS4_STATE}.tmp" 2>/dev/null && mv -f "${GC_PASS4_STATE}.tmp" "$GC_PASS4_STATE" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# --doctor
# ---------------------------------------------------------------------------

_gc_doctor() {
  local rc=0 os
  os="$(_lane_uname)"
  echo "adt-gc.sh --doctor"
  echo "ADT_STATE_ROOT=${ADT_STATE_ROOT}"
  echo "platform=${os}"

  if command -v flock >/dev/null 2>&1; then
    echo "[ok]   flock present"
  else
    echo "[FAIL] flock missing — GC singleton lock and every lane_kill/reap.lock call degrade to unlocked"
    rc=1
  fi

  if command -v setsid >/dev/null 2>&1; then
    echo "[ok]   setsid present"
  else
    echo "[FAIL] setsid missing — lane_spawn / escalator isolation degrade"
    rc=1
  fi

  if [[ "$os" == "Linux" ]]; then
    if crontab -l 2>/dev/null | grep -q '# adt-gc-timer'; then
      echo "[ok]   GC timer installed (cron marker found)"
    else
      echo "[WARN] no GC cron marker found — run install-gc-timer.sh"
    fi
    local linger
    linger="$(loginctl show-user -p Linger --value 2>/dev/null || echo "")"
    if [[ "$linger" == "yes" ]]; then
      echo "[ok]   linger enabled (systemd-scope backend eligible)"
    else
      echo "[WARN] linger not enabled — systemd-scope backend unavailable, pgid backend remains sufficient"
    fi
  else
    if launchctl list 2>/dev/null | grep -q 'com.adt.lane-gc'; then
      echo "[ok]   GC timer installed (launchd label found)"
    else
      echo "[WARN] no launchd GC timer found — run install-gc-timer.sh"
    fi
    if _lane_procargs2_available; then
      echo "[ok]   python3 present (procargs2 shim usable — env-tag GC authorization available)"
    else
      echo "[WARN] python3 absent — macOS GC is registry-authoritative only (env-tag = dry-run diagnostic)"
    fi
  fi

  local project_count=0 lanes_dir
  for lanes_dir in "$ADT_STATE_ROOT"/autonomous-*/lanes; do
    [[ -d "$lanes_dir" ]] || continue
    project_count=$((project_count + 1))
  done
  if [[ "$project_count" -gt 0 ]]; then
    echo "[ok]   ADT_STATE_ROOT has lane registry content (${project_count} project(s))"
  else
    echo "[WARN] ADT_STATE_ROOT has no lane registry content — either no wrapper has run yet on this host, or ADT_STATE_ROOT is misconfigured"
  fi

  echo "mode_default=${GC_MODE} (ADT_GC_ENFORCE=${ADT_GC_ENFORCE:-<unset>})"
  return "$rc"
}

if [[ "$GC_DOCTOR" == true ]]; then
  _gc_doctor
  exit $?
fi

# ---------------------------------------------------------------------------
# Singleton lock + run
# ---------------------------------------------------------------------------
# [Lane-GC PR-4 review round-2, P2-5] Lock BEFORE rotate, never the reverse.
# Rotation was previously called before the flock acquisition — two
# concurrent invocations (e.g. a --quick opportunistic call racing a cron
# tick) could BOTH observe the log over the 25MB threshold and both run
# `mv -f "$GC_LOG" "${GC_LOG}.1"`, with the second mv silently destroying
# the first mv's just-rotated history (mv -f is not atomic against a
# second mv -f to the same destination) before either had exclusive
# ownership of the log file. Moving rotation inside the lock (after a
# successful flock, before any pass runs) makes rotation itself
# single-writer, matching every other GC_LOG-mutating operation (_gc_log
# itself is only ever called after the lock is held). --doctor never
# reaches this block at all (it returns above, at the GC_DOCTOR check) —
# doctor's read-only probes correctly never rotate the log.
exec 9>"$GC_LOCK" || exit 0
if [[ "$GC_QUICK" == true ]]; then
  # F6 selfdefeat: `-w 3`, never `-n` — a quick opportunistic call queues
  # briefly behind a concurrent full run rather than starving under load.
  flock -w 3 9 2>/dev/null || exit 0
else
  flock -n 9 2>/dev/null || exit 0
fi

_gc_rotate_log

START_MS="$(_gc_now_ms)"

_gc_pass1
if [[ "$GC_QUICK" != true ]]; then
  _gc_pass2
  _gc_pass3
  _gc_pass4
fi

END_MS="$(_gc_now_ms)"
ELAPSED_MS=$(( END_MS - START_MS ))

SUMMARY="ADT_GC_SUMMARY skips=${SKIPS} would_kill=${WOULD_KILL} killed=${KILLED} would_kill_legacy_signature=${WOULD_KILL_LEGACY} unknown_class=${UNKNOWN_CLASS} live_burner_alerts=${LIVE_BURNER_ALERTS} elapsed_ms=${ELAPSED_MS}"
_gc_log "$SUMMARY"
echo "$SUMMARY"

# Best-effort per-project metrics emission (INV-70) — one event per
# project whose registry this run touched, so metrics-report.sh can join
# on `project` like every other emitted event.
for _gc_lanes_dir in "$ADT_STATE_ROOT"/autonomous-*/lanes; do
  [[ -d "$_gc_lanes_dir" ]] || continue
  _gc_proj="$(basename "$(dirname "$_gc_lanes_dir")")"
  _gc_proj="${_gc_proj#autonomous-}"
  _gc_emit_metric "$_gc_proj" adt_gc_summary \
    skips="$SKIPS" would_kill="$WOULD_KILL" killed="$KILLED" \
    would_kill_legacy_signature="$WOULD_KILL_LEGACY" unknown_class="$UNKNOWN_CLASS" \
    live_burner_alerts="$LIVE_BURNER_ALERTS" elapsed_ms="$ELAPSED_MS"
done

exit 0
