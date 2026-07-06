#!/bin/bash
# lib-guardian.sh — Lane-GC series PR-5: the per-lane guardian sidecar
# (design docs/designs/lane-containment-gc.md §4-C3; shipped as INV-118 —
# the design doc's drafted INV-109 collided with the head at PR-open, per
# the design's own "re-verify numbering against invariants.md HEAD" note;
# see docs/pipeline/invariants.md for the shipped number).
#
# This is a deliberately `lib-*`-named ENTRY point (not a library sourced
# into a caller's shell): install-project-hooks.sh's `is_entry_script`
# treats every `lib-*.sh` as a non-manifest file it never symlinks
# (skills/autonomous-common/scripts/install-project-hooks.sh), so this file
# reaches every onboarded project purely via the wrapper's own
# `readlink -f`-resolved LIB_DIR — no installer re-run needed after a merge,
# same contract as every OTHER lib-*.sh in this tree. It is still invoked
# as a SCRIPT (`setsid bash lib-guardian.sh --lane-dir <dir>`), never
# sourced, which is why it parses its own argv below instead of exposing a
# callable function.
#
# WHAT THIS IS
# ------------
# One guardian process per lane: a `setsid`-detached pure-POSIX death watch
# that holds the READ end of the lane's `guard.fifo`. The wrapper opens the
# WRITE end (`exec {ADT_GUARD_FD}<>guard.fifo`) BEFORE spawning this script
# (design §4-C3, INV-118) — so this script's own `exec 3<"$LANE_DIR/guard.fifo"`
# never blocks (a writer is already present; O_RDWR counts as a writer for
# FIFO open-order purposes, verified empirically against this exact box: a
# read-only `exec 3<fifo` against a fifo already held `<>` by another
# process returns immediately, never blocking on open(2)).
#
# The guardian's `read -r _ <&3` then blocks until EOF — which the KERNEL
# delivers the instant the LAST write-mode holder of the fifo closes it,
# by ANY means: a graceful `exec {ADT_GUARD_FD}>&-` handshake, a plain
# process exit, SIGTERM, SIGKILL, or OOM. EOF is therefore a signal no
# in-process trap can ever miss — this is the whole point of the guardian
# (RC1 in the design's forensic audit: traps never run under SIGKILL/OOM).
#
# Once woken (EOF, the no-writer watchdog, or the lifetime-cap USR1), the
# guardian runs `do_reap` (idempotent, `reap.lock`-guarded) and exits.
#
# WHAT THIS IS NOT
# -----------------
# Not load-bearing alone (design principle 3): a guardian that itself dies
# (OOM, host reboot, a bug) leaves its lane's residue to the periodic GC
# (`adt-gc.sh`, Lane-GC PR-4/INV-117), which performs the identical
# `do_reap` under the same `reap.lock` from rule 1.3 of its decision table.
#
# Usage: setsid bash lib-guardian.sh --lane-dir <dir>
#   (always backgrounded by the caller; never intended to be run in the
#   foreground of an interactive shell — it blocks until the lane dies)
#
# Exit codes: always 0 on a normal wake (EOF / no-writer / lifetime-cap);
# 1 only on a usage error (missing/bad --lane-dir) before any work starts.

set -uo pipefail
# Deliberately NOT `set -e`: `do_reap`'s own internal error handling (ENOENT
# tolerance — a lane dir can be `rm -rf`'d out from under a running guardian
# by GC rule 1.4) relies on individual commands failing softly and being
# checked explicitly, not on `set -e` unwinding the whole script on the
# first non-zero rc from a best-effort `kill`/`flock`/`rm`.

# [INV-65]-style two-dir resolution, same pattern as every sibling script in
# this tree: resolve LIB_DIR from the REAL path (readlink -f) so lib-lane.sh
# sources from the skill tree regardless of how this script itself was
# invoked (a project-side path, a skill-tree path, or a test harness copy).
_GUARDIAN_SELF="${BASH_SOURCE[0]:-$0}"
_GUARDIAN_LIB_DIR="$(cd "$(dirname "$(readlink -f "$_GUARDIAN_SELF")")" && pwd)"

# shellcheck source=lib-lane.sh
source "${_GUARDIAN_LIB_DIR}/lib-lane.sh"

_guard_log() {
  # Timestamped line to the guardian's OWN log — the caller redirects this
  # script's stdout+stderr to "$LANE_DIR/guardian.log" at spawn time
  # (design §4-C3), so a bare `echo` here is sufficient; no separate log
  # helper/rotation needed (guardian.log is explicitly exempt from the
  # box-wide adt-gc.log rotation, design §5).
  printf '[guardian] %s %s\n' "$(date -u +%H:%M:%S 2>/dev/null || echo '??:??:??')" "$*"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
LANE_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lane-dir)
      [[ $# -ge 2 ]] || { echo "[guardian] FATAL: --lane-dir requires an argument" >&2; exit 1; }
      LANE_DIR="$2"; shift 2 ;;
    *)
      echo "[guardian] FATAL: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$LANE_DIR" || ! -d "$LANE_DIR" ]]; then
  echo "[guardian] FATAL: --lane-dir '$LANE_DIR' missing or not a directory" >&2
  exit 1
fi

FIFO_PATH="${LANE_DIR}/guard.fifo"
if [[ ! -p "$FIFO_PATH" ]]; then
  echo "[guardian] FATAL: '$FIFO_PATH' does not exist or is not a FIFO" >&2
  exit 1
fi

_guard_log "starting for lane dir: $LANE_DIR (pid=$$, fifo=$FIFO_PATH)"

# ---------------------------------------------------------------------------
# do_reap — idempotent lane reap (design §4-C3, INV-118).
#
# Shares `reap.lock` with `lane_kill`/`lane_reap`/GC's own reap (rule 1.3),
# so a re-dispatch's delegate call, the outgoing wrapper's own graceful
# `cleanup()`, and this guardian can never issue overlapping KILLs against
# the same pgid.
#
# LOAD-BEARING NOTE (empirically verified on this box, see the PR's test
# suite TC-LGC5-090): `flock` on a SECOND fd opened by the SAME process
# against the SAME lock file is NOT re-entrant — it blocks/deadlocks against
# the process's own already-held lock exactly like a foreign holder would.
# `do_reap` therefore takes `reap.lock` itself via a NON-BLOCKING `flock -n`
# (never a blocking `-w`) and, on success, calls `lane_kill` DIRECTLY
# without letting `lane_kill` re-flock — `lane_kill`'s own internal
# `flock -w 10` on ITS OWN separate fd would otherwise wait out the full 10s
# bound every single time (self-deadlock avoided only by the wait
# eventually timing out, silently degrading every reap to a 10s floor).
# This mirrors `lane_reap`'s own doc comment ("flock on an already-held fd
# BY THE SAME PROCESS is a re-entrant no-op-wait" — that comment describes
# `lane_kill`'s SECOND acquisition of the SAME fd variable being a no-op
# ONLY because `lane_kill` computes its OWN local lock_fd via a fresh
# `exec {lock_fd}>>` and takes it itself; it is a wait, not a true no-op,
# when a DIFFERENT calling frame already holds a DIFFERENT fd against the
# same file — this guardian sidesteps that entirely by holding the ONE lock
# for its whole reap and calling the pgid-escalation primitive
# (`_kill_group_escalate`, exported by lib-lane.sh) directly over the
# `pgids` file instead of going through `lane_kill`'s own lock-taking
# wrapper).
do_reap() {
  local lock_fd
  exec {lock_fd}>>"${LANE_DIR}/reap.lock" 2>/dev/null || { _guard_log "reap.lock open failed — proceeding unlocked (best-effort, degraded posture)"; lock_fd=""; }
  if [[ -n "$lock_fd" ]]; then
    if ! flock -n "$lock_fd" 2>/dev/null; then
      _guard_log "reap.lock held by another reaper — skipping (someone else is reaping this lane)"
      exec {lock_fd}>&- 2>/dev/null || true
      return 0
    fi
  fi

  # ENOENT tolerance (design §4-C3 selfdefeat:F4): GC rule 1.4 may have
  # rm -rf'd the lane dir out from under us (after killing a WEDGED guardian
  # first, per that rule) — treat any missing artifact as "someone finished".
  if [[ ! -d "$LANE_DIR" ]]; then
    _guard_log "lane dir vanished before reap — treating as already-finished"
    [[ -n "$lock_fd" ]] && { exec {lock_fd}>&- 2>/dev/null || true; }
    return 0
  fi

  local st
  st="$(lane_get "$LANE_DIR" STATE 2>/dev/null)" || st=""
  case "$st" in
    clean-exit|cleaning|gc-reaped|reaped-by-guardian)
      _guard_log "STATE=$st is terminal/in-progress-by-a-peer — zero-kill wake (graceful exit or a peer already reaped)"
      [[ -n "$lock_fd" ]] && { exec {lock_fd}>&- 2>/dev/null || true; }
      return 0
      ;;
  esac

  lane_set_state "$LANE_DIR" reaping 2>/dev/null || true

  # [Lane-GC PR-7 / INV-120] cgroup fast path FIRST — a no-op unless this
  # lane's OWN recorded BACKEND is `systemd-scope` (`_lane_scope_kill`,
  # lib-lane.sh, decides that by reading the `lane` file, never by
  # re-probing the host). Runs strictly BEFORE the pgid escalation below,
  # matching the design's own ordering ("cgroup fast path (C7); else
  # per-pgid TERM→10s→KILL") — but "before", not "instead of": the pgid
  # escalation ALWAYS still runs afterward regardless of what the scope
  # path did or didn't reap (defense in depth, same rationale `lane_kill`
  # documents at its own call site). Grace matches the pgid escalation's
  # own hardcoded 10s below for symmetry.
  _lane_scope_kill "$LANE_DIR" 10

  # Registry pgid escalation. Deliberately calls `_kill_group_escalate`
  # DIRECTLY (the primitive `lane_kill` itself builds on) rather than
  # `lane_kill` — see the load-bearing note above: `lane_kill` would try to
  # re-flock the SAME lock file we already hold and self-deadlock for its
  # own bound. Runs each recorded pgid's escalation CONCURRENTLY (one
  # setsid-isolated background job per pgid, same isolation rationale
  # `lane_kill` itself documents — a group-form signal aimed at this
  # guardian's OWN pgid, e.g. a stale operator script that still tries to
  # group-kill by lane-dir-adjacent heuristics, must never collaterally
  # kill an in-flight escalator mid-grace) so total wall-clock stays
  # ~grace regardless of how many pgids are recorded.
  local pgids_file="${LANE_DIR}/pgids" seen=() pg
  if [[ -f "$pgids_file" ]]; then
    while read -r pg _rest; do
      [[ "$pg" =~ ^[0-9]+$ ]] || continue
      local already=0 s
      for s in "${seen[@]:-}"; do [[ "$s" == "$pg" ]] && { already=1; break; }; done
      [[ "$already" -eq 1 ]] && continue
      seen+=("$pg")
    done < "$pgids_file"
  fi

  if [[ "${#seen[@]}" -gt 0 ]]; then
    _guard_log "escalating ${#seen[@]} recorded pgid(s): ${seen[*]}"
    local escalate_pids=() _g_setsid=()
    command -v setsid >/dev/null 2>&1 && _g_setsid=(setsid)
    export -f _kill_group_escalate
    for pg in "${seen[@]}"; do
      "${_g_setsid[@]}" bash -c '_kill_group_escalate "$1" "$2"' _ "$pg" 10 &
      escalate_pids+=("$!")
    done
    wait "${escalate_pids[@]}" 2>/dev/null || true
  else
    _guard_log "no recorded pgids to reap"
  fi

  # Escape sweep: env-tag match on THIS lane's ADT_LANE_ID ONLY (design
  # §4-C3 falsekill:F3 — a foreign lane's tag must be skipped, never swept;
  # PR-5 AC #3/#7). Same-uid enumeration via /proc on Linux (the only
  # platform env_of supports without the macOS procargs2 shim, which is a
  # later-PR concern — degrades to registry-only reaping on macOS, matching
  # the design's stated platform posture for this series' portable path).
  local my_lane_id
  my_lane_id="$(lane_get "$LANE_DIR" LANE_ID 2>/dev/null)" || my_lane_id=""
  if [[ -n "$my_lane_id" && -d /proc ]]; then
    local candidate cpid env_snapshot tag term_program
    for candidate in /proc/[0-9]*; do
      [[ -d "$candidate" ]] || continue
      cpid="${candidate#/proc/}"
      [[ "$cpid" =~ ^[0-9]+$ ]] || continue
      # Never touch ourselves or anything already reachable via the pgid
      # escalation above (best-effort: recorded pgids ARE the process-group
      # leaders we just escalated, not necessarily every member pid — the
      # escape sweep's job is specifically the ones that escaped the group,
      # so re-touching a leader here is harmless idempotent overlap, not a
      # correctness requirement to exclude by pid list).
      [[ "$cpid" == "$$" ]] && continue
      # ONE env read per candidate, reused for both the tag match and the
      # TERM_PROGRAM check — and read-failure is a SKIP, never a proceed
      # (fail toward leak, the same env-unknowable posture adt-gc.sh's
      # Pass-2/3 guards enforce per INV-117: an unreadable env cannot
      # prove the ABSENCE of TERM_PROGRAM, so it must never be treated as
      # "operator-clean"; the original two-read shape also raced a
      # process dying between the reads).
      env_snapshot="$(env_of "$cpid" 2>/dev/null)" || continue
      tag="$(grep -m1 '^ADT_LANE_ID=' <<<"$env_snapshot")" || continue
      [[ "${tag#ADT_LANE_ID=}" == "$my_lane_id" ]] || continue
      term_program="$(grep -m1 '^TERM_PROGRAM=' <<<"$env_snapshot")" || term_program=""
      if [[ -n "$term_program" ]]; then
        _guard_log "escape-sweep: pid=$cpid carries our lane tag but ALSO TERM_PROGRAM — unconditional skip (operator fail-safe)"
        continue
      fi
      _guard_log "escape-sweep: pid=$cpid carries our lane tag ($my_lane_id) — TERM->2s->KILL"
      kill -TERM "$cpid" 2>/dev/null || continue
      local _i
      for ((_i = 0; _i < 2; _i++)); do
        kill -0 "$cpid" 2>/dev/null || break
        sleep 1
      done
      kill -0 "$cpid" 2>/dev/null && kill -KILL "$cpid" 2>/dev/null || true
    done
  fi

  lane_set_state "$LANE_DIR" reaped-by-guardian 2>/dev/null || true
  rm -f "$FIFO_PATH" 2>/dev/null || true
  _guard_log "reap complete — STATE=reaped-by-guardian"

  [[ -n "$lock_fd" ]] && { exec {lock_fd}>&- 2>/dev/null || true; }
  return 0
}

# ---------------------------------------------------------------------------
# No-writer watchdog (design §4-C3 F2 timing — defensive only; the wrapper's
# own open-before-spawn ordering means this should never actually fire in
# production, but a future accidental reordering, or this script being
# hand-invoked against a fifo nobody ever opened for write, must not park
# forever).
#
# LOAD-BEARING ORDERING (found empirically while writing this PR's test
# suite, TC-LGC5-070 — the design doc's own §4-C3 pseudocode has this same
# ordering bug): the watchdog timer + trap MUST be armed BEFORE attempting
# the open below, not after. If no writer is EVER present, the plain
# `exec 3<"$FIFO_PATH"` open(2) call itself blocks indefinitely — a
# check placed AFTER that line is dead code for the exact scenario it
# claims to guard, since control never reaches it. Arming the SIGUSR2
# trap first means the timer's `kill -USR2 $$` can interrupt the blocked
# open(2) syscall directly (verified empirically: a trap fires and exits
# while a sibling shell is parked in `exec 3<fifo` against a fifo with no
# writer, exactly like it interrupts a blocked `read`).
#
# This also drops the original design's `/proc`-wide "is a writer already
# connected" scan entirely — it is unnecessary (a plain read-only open
# already returns immediately if ANY writer is connected, by FIFO/POSIX
# semantics; no separate check is needed to get that behavior) AND, on a
# busy multi-tenant host, prohibitively slow (empirically: enumerating
# every fd of every process on this project's own dev/CI host took several
# seconds, which would itself eat into the 15s grace or race against a
# genuinely fast wrapper crash-and-restart cycle). The timer-first
# approach is simultaneously simpler, faster, and (unlike the /proc scan)
# portable to macOS for free — it needs no OS-specific introspection at
# all, only signals and a plain fifo open.
# ---------------------------------------------------------------------------
_guard_log "arming the ${ADT_GUARDIAN_NO_WRITER_GRACE_SECONDS:-15}s no-writer watchdog before opening the fifo for read"
(
  sleep "${ADT_GUARDIAN_NO_WRITER_GRACE_SECONDS:-15}"
  kill -USR2 $$ 2>/dev/null || true
) &
_NO_WRITER_WD_PID=$!
# shellcheck disable=SC2064 # intentional immediate expansion of $$ (OUR pid, not the trap's future pid)
trap "_guard_log 'no-writer watchdog fired — self-exiting without a reap (never had a writer to watch within the grace window)'; exit 0" USR2

# Open the read end. The wrapper's `exec {ADT_GUARD_FD}<>guard.fifo` runs
# BEFORE this script is ever spawned (design §4-C3 FIFO-open-ordering
# contract, INV-118) — so in the NORMAL case this open(2) returns
# immediately: a write-mode holder is already present. Kept as a PLAIN
# redirect (`exec 3<"$FIFO_PATH"`), not `<>`, because the guardian is the
# READER, never a writer — `<>` here would make the guardian itself a
# spurious extra write-mode holder of its own fifo, which would silently
# defeat the entire death-watch (its own open fd would keep the fifo from
# ever reaching EOF even after the wrapper's real writer closes).
exec 3<"$FIFO_PATH"
_guard_log "fifo opened for read (fd 3)"

# A writer was present (the open above returned) — the watchdog's job is
# done; disarm it so it can never fire a spurious USR2 later (e.g. if this
# guardian process's pid is recycled after exit — defensive only, `kill`
# on our own already-running chunk-watchdog is not itself a race here
# since we are still the same live process).
kill "$_NO_WRITER_WD_PID" 2>/dev/null || true
trap - USR2

# ---------------------------------------------------------------------------
# Hard lifetime cap — chunked, PPID-checked (design §4-C3 selfdefeat:F5:
# symmetry with the token-daemon's own chunked-sleep fix, Lane-GC PR-1 /
# INV-79's pattern). A monolithic `sleep $cap` child would itself survive a
# SIGKILL of the guardian for up to the full cap — exactly the anti-pattern
# this series exists to close elsewhere. Each 60s chunk instead re-checks
# `kill -0 $$` (are we, the guardian, still alive?) so a SIGKILLed guardian
# takes its chunk-watchdog down within one chunk, never up to the full cap.
#
# ADT_GUARDIAN_CAP_CHUNK_SECONDS and ADT_GUARDIAN_CAP_SECONDS_OVERRIDE are
# TEST-ONLY seams (undocumented to operators; not read anywhere else) —
# production always computes the real `AGENT_TIMEOUT_SECONDS + 3600` cap in
# the real 60s chunk; the unit suite shrinks BOTH (the fixed `+3600` offset
# alone keeps any AGENT_TIMEOUT_SECONDS value well over an hour, so a cap
# override is needed independent of the chunk-size override to run the
# lifetime-cap-fires scenario in seconds instead of hours).
# ---------------------------------------------------------------------------
if [[ -n "${ADT_GUARDIAN_CAP_SECONDS_OVERRIDE:-}" ]]; then
  _cap_secs="$ADT_GUARDIAN_CAP_SECONDS_OVERRIDE"
else
  _cap_secs=$(( ${AGENT_TIMEOUT_SECONDS:-14400} + 3600 ))
fi
_chunk_secs="${ADT_GUARDIAN_CAP_CHUNK_SECONDS:-60}"
[[ "$_chunk_secs" =~ ^[0-9]+$ ]] && [[ "$_chunk_secs" -gt 0 ]] || _chunk_secs=60
(
  _n=0
  while (( _n < _cap_secs )); do
    kill -0 "$$" 2>/dev/null || exit 0   # guardian gone -> chunk-watchdog exits too
    sleep "$_chunk_secs"
    _n=$(( _n + _chunk_secs ))
  done
  kill -USR1 "$$" 2>/dev/null || true
) &
_CAP_WD_PID=$!
trap '_guard_log "lifetime cap reached ($_cap_secs s) — reaping and exiting"; do_reap; kill "$_CAP_WD_PID" 2>/dev/null || true; exit 0' USR1

# ---------------------------------------------------------------------------
# Main wait: block on the fifo until EOF (wrapper died by ANY means,
# graceful or not) or one of the two watchdogs above fires via signal.
# `read` returning at all (rc 0 or 1 — EOF is rc>0 with an empty $_) means
# EOF; a signal delivered while blocked here is handled by the traps
# already installed and jumps out via their own `exit 0`, never falling
# through to the line below in that case.
# ---------------------------------------------------------------------------
read -r _ <&3 || true
_guard_log "fifo EOF observed — wrapper is gone by some means (graceful handshake or a non-graceful death); reaping"
do_reap
[[ -n "${_NO_WRITER_WD_PID:-}" ]] && kill "$_NO_WRITER_WD_PID" 2>/dev/null || true
kill "$_CAP_WD_PID" 2>/dev/null || true
exit 0
