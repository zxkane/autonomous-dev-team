#!/bin/bash
# lib-lane.sh — Lane-GC PR-2: lane identity, durable registry, atomic mint,
# and universal ADT_LANE_ID tagging (design: docs/designs/lane-containment-gc.md
# §4-C1/§4-C2; shipped as INV-109/INV-110 — the design doc's drafted INV-107/
# INV-108 collided with #375's shipped INV-108, renumbered at PR-open per the
# design's own "re-verify numbering against invariants.md HEAD" note).
#
# A "lane" is the unit of ownership for one wrapper run (one dev-new/dev-resume
# or one review dispatch). This lib gives every wrapper a durable, atomically-
# installed registry directory that later Lane-GC PRs (guardian, kill-path
# hardening, periodic GC) join against. THIS PR ships only:
#   - lane_mint / lane_install   — mint the id, atomically install the registry
#   - lane_spawn                 — pgid-backend spawn wrapper (setsid + PGID
#                                  capture); systemd-scope backend is a later PR
#   - lane_record_pgid           — append a spawned PGID to the lane's pgids file
#   - lane_kill                  — registry-authoritative TERM→grace→KILL
#   - lane_probe                 — liveness check (pid ∧ start-time ∧ macOS
#                                  fingerprint)
#   - lane_set_state / lane_get  — KV read/write on the `lane` file
#   - proc_age / proc_start_time / env_of / file_mtime / box_health —
#     portability shims (Linux fast paths + macOS/BSD fallbacks)
#
# The guardian sidecar, kill-path escalation rewrite, adt-gc.sh, and the
# systemd-scope backend are later PRs in the series (§9 PR-3..PR-7) and are
# NOT implemented here.
#
# Public API is intentionally jq-free (bash-4, flat KEY=VAL lane file) so this
# lib has zero new dependencies beyond what the wrappers already require
# (flock, setsid — both already mandatory per lib-agent.sh:586/lib-agent.sh's
# _run_with_timeout).

# ---------------------------------------------------------------------------
# ADT_STATE_ROOT canonicalization (F1 completeness, design §4-C1).
#
# Deliberately ignores XDG_STATE_HOME: the wrapper may run under an SSM
# sudo login shell that inherits an operator's XDG override, while a future
# cron/launchd GC timer runs under a minimal env. Divergence between the two
# would silently scan an empty path and report "0 would_kill" — indistinguish-
# able from success. This is intentionally NOT the same base lib-metrics.sh /
# lib-run-artifacts.sh use (those DO honor XDG_STATE_HOME) — the lane registry
# is read by a box-wide, non-project-scoped future GC process, so it needs one
# canonical anchor that never depends on which shell minted it.
# ---------------------------------------------------------------------------
: "${ADT_STATE_ROOT:=$HOME/.local/state}"
export ADT_STATE_ROOT

# [INV-65] two-dir resolution, same pattern as every other sibling lib.
_LIB_LANE_SELF="${BASH_SOURCE[0]:-$0}"
_LIB_LANE_DIR="$(cd "$(dirname "$_LIB_LANE_SELF")" && pwd)"

# _lane_uname — overridable seam for tests (never for production; production
# always calls the real `uname -s`). Kept as a one-line indirection so a unit
# test can force the macOS branch (WRAPPER_FINGERPRINT, ps -o lstart=) on a
# Linux CI runner without actually running on Darwin.
_lane_uname() {
  echo "${_LANE_UNAME_OVERRIDE:-$(uname -s 2>/dev/null || echo Linux)}"
}

# ---------------------------------------------------------------------------
# Portability shims
# ---------------------------------------------------------------------------

# proc_start_time <pid> — echo a string that uniquely identifies the process
# START (not just its existence), for PID-recycle defense. Linux: /proc/PID/stat
# field 22 (starttime, clock ticks since boot — µs-class granularity, fast,
# no subprocess). macOS/BSD: `ps -o lstart=` (1s granularity — combined with
# WRAPPER_FINGERPRINT at the call site for macOS).
proc_start_time() {
  local pid="$1"
  if [[ -r "/proc/${pid}/stat" ]]; then
    local stat_line rest
    stat_line="$(cat "/proc/${pid}/stat" 2>/dev/null)" || { echo ""; return 1; }
    # comm can contain ')' and spaces; split on the LAST ')' the same way the
    # kernel docs recommend, then re-split the remainder on spaces. Field 22
    # (starttime) is the 20th field of the remainder (remainder starts at
    # field 3 = state).
    rest="${stat_line##*)}"
    # shellcheck disable=SC2206 # intentional word-split of numeric fields
    local fields=($rest)
    if [[ -n "${fields[19]:-}" ]]; then
      echo "${fields[19]}"
      return 0
    fi
    echo ""
    return 1
  fi
  # macOS/BSD fallback: no /proc. `ps -o lstart=` is 1s granularity.
  ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# proc_age <pid> — echo the process's age in whole seconds. Linux: procps
# `etimes=` (integer seconds, no unit suffix). macOS/BSD: `ps -o etime=`
# emits `[[dd-]hh:]mm:ss` — parsed into seconds. Echoes empty + rc 1 if the
# pid is not found.
proc_age() {
  local pid="$1"
  local raw
  if [[ "$(_lane_uname)" == "Linux" ]]; then
    raw="$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$raw" =~ ^[0-9]+$ ]]; then
      echo "$raw"
      return 0
    fi
    echo ""
    return 1
  fi
  raw="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  [[ -n "$raw" ]] || { echo ""; return 1; }
  # [[dd-]hh:]mm:ss
  local days=0 hh=0 mm=0 ss=0 dpart tpart
  if [[ "$raw" == *-* ]]; then
    dpart="${raw%%-*}"; tpart="${raw#*-}"
    days="$dpart"
  else
    tpart="$raw"
  fi
  local ncolons
  ncolons="$(tr -cd ':' <<<"$tpart" | wc -c)"
  case "$ncolons" in
    2) IFS=: read -r hh mm ss <<<"$tpart" ;;
    1) IFS=: read -r mm ss <<<"$tpart" ;;
    *) ss="$tpart" ;;
  esac
  # Strip any leading zeros bash would otherwise treat as octal.
  days=$((10#${days:-0})); hh=$((10#${hh:-0})); mm=$((10#${mm:-0})); ss=$((10#${ss:-0}))
  echo $(( days*86400 + hh*3600 + mm*60 + ss ))
}

# env_of <pid> — echo the process's environment, one `KEY=VALUE` per line.
# Linux: /proc/PID/environ (NUL-delimited → newline-delimited). Gated on
# `[ -r ]`, NEVER `[ -s ]` — `stat -c %s /proc/PID/environ` reports 0 even on
# a readable, non-empty environ (procfs quirk); an `-s` gate would silently
# treat every live process as "no env" and defeat env-tag matching entirely
# (design §4-C2 platform:F5). Echoes nothing + rc 1 when unreadable (dead
# process, permission, or — on macOS with no python3 shim installed — always,
# by design: this lib does not ship the macOS `sysctl kern.procargs2` shim;
# that is deferred to the GC PR, so env_of is Linux-only for now and callers
# must tolerate an empty result on macOS).
env_of() {
  local pid="$1"
  if [[ -r "/proc/${pid}/environ" ]]; then
    tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null
    return 0
  fi
  return 1
}

# file_mtime <path> — echo the file's mtime as an epoch integer. Linux
# `stat -c %Y`, macOS/BSD `stat -f %m`. Echoes nothing + rc 1 on a missing
# file (mirrors the dual-pattern already used by lib-run-artifacts.sh/status.sh).
file_mtime() {
  local path="$1"
  stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null
}

# box_health — echo `load1_per_core=<f> mem_available_mb=<n> swap_pct=<n>` for
# a future admission-gate PR to consume. Best-effort: any unavailable signal is
# omitted from the line rather than aborting. Not consumed by this PR's own
# code — provided now so PR-6 (back-pressure gate) needs no lib-lane.sh change.
box_health() {
  local out="" load1 ncpu mem_avail mem_total swap_used swap_total
  if [[ -r /proc/loadavg ]]; then
    load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"
    ncpu="$(nproc 2>/dev/null || echo 1)"
    if [[ -n "$load1" && "$ncpu" -gt 0 ]] 2>/dev/null; then
      out+=" load1_per_core=$(awk -v l="$load1" -v n="$ncpu" 'BEGIN{printf "%.2f", l/n}')"
    fi
  fi
  if [[ -r /proc/meminfo ]]; then
    mem_avail="$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)"
    [[ -n "$mem_avail" ]] && out+=" mem_available_mb=$((mem_avail / 1024))"
    local swap_free
    swap_total="$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)"
    swap_free="$(awk '/^SwapFree:/{print $2}' /proc/meminfo 2>/dev/null)"
    if [[ -n "$swap_total" && "$swap_total" -gt 0 ]] 2>/dev/null; then
      swap_used=$((swap_total - swap_free))
      out+=" swap_pct=$(awk -v u="$swap_used" -v t="$swap_total" 'BEGIN{printf "%.0f", (u/t)*100}')"
    fi
  fi
  printf '%s\n' "${out# }"
}

# ---------------------------------------------------------------------------
# Lane naming
# ---------------------------------------------------------------------------

# _lane_id_fs <lane_id> — echo the filesystem/systemd-safe form (`:` → `.`).
_lane_id_fs() {
  printf '%s' "${1//:/.}"
}

# _lanes_root <project_id> — echo the registry parent dir for this project,
# creating it (mode 0700) if missing. Sibling of the existing PID-file dir
# (design §4-C1: "sibling of the existing PID files — the natural anchor
# identified in forensics").
_lanes_root() {
  local project_id="$1"
  local root="${ADT_STATE_ROOT}/autonomous-${project_id}/lanes"
  mkdir -p "$root" 2>/dev/null
  chmod 700 "$root" 2>/dev/null || true
  printf '%s\n' "$root"
}

# lane_dir <project_id> <lane_id> — echo the installed lane's directory path
# (does not create it — call after lane_install, or to compute where a
# CALLER already knows a lane lives).
lane_dir() {
  local project_id="$1" lane_id="$2"
  printf '%s/%s\n' "$(_lanes_root "$project_id")" "$(_lane_id_fs "$lane_id")"
}

# lane_find_latest <project_id> <role> <issue> — echo the most-recently-
# CREATED_EPOCH lane dir matching (role, issue) under this project's registry,
# or nothing + rc 1 when none exists. A caller that only knows
# (project, role, issue) — e.g. the `kill_stale_wrapper` delegate in
# dispatch-local.sh, which has no lane id to hand (the wrapper it's about to
# replace minted its OWN id) — uses this to find the CURRENT lane before
# deciding whether to delegate to `lane_kill`. "Most recent" matters because a
# stale terminal-state lane for the SAME (role, issue) can outlive its wrapper
# by up to 24h (age-collected by a future GC pass, not this PR) — the newest
# one is always the one that might still be live.
lane_find_latest() {
  local project_id="$1" role="$2" issue="$3"
  local root
  root="$(_lanes_root "$project_id")"
  local best="" best_epoch=-1
  local d
  for d in "$root"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    [[ "$(basename "$d")" == .pending-* ]] && continue
    local r i e
    r="$(lane_get "$d" ROLE)" || continue
    [[ "$r" == "$role" ]] || continue
    i="$(lane_get "$d" ISSUE)" || continue
    [[ "$i" == "$issue" ]] || continue
    e="$(lane_get "$d" CREATED_EPOCH)" || e=0
    [[ "$e" =~ ^[0-9]+$ ]] || e=0
    if [[ "$e" -gt "$best_epoch" ]]; then
      best_epoch="$e"
      best="$d"
    fi
  done
  [[ -n "$best" ]] || return 1
  printf '%s\n' "$best"
}

# lane_mint <project_id> <role> <issue> — echo a fresh
# `<project_id>:<role>:<issue>:<start-epoch>:<rand4>` lane id. Does not touch
# the filesystem — call lane_install next. `role` is caller-supplied
# (`dev`|`review`); `issue` may be `-` (dispatcher-alert sentinel, no numeric
# issue yet) same as the rest of the pipeline's `-` convention.
lane_mint() {
  local project_id="$1" role="$2" issue="$3"
  local start_epoch rand4
  start_epoch=$(date +%s 2>/dev/null || echo 0)
  if command -v openssl >/dev/null 2>&1 && rand4=$(openssl rand -hex 2 2>/dev/null); then
    :
  elif rand4=$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n'); then
    :
  else
    rand4=$(printf '%04x' "$((RANDOM % 65536))")
  fi
  [[ "$rand4" =~ ^[0-9a-f]{4}$ ]] || rand4=$(printf '%04x' "$((RANDOM % 65536))")
  printf '%s:%s:%s:%s:%s\n' "$project_id" "$role" "$issue" "$start_epoch" "$rand4"
}

# _wrapper_fingerprint <pid> <ppid> <lstart> — echo sha256(comm‖ppid‖lstart).
# macOS PID-recycle guard only (design §4-C1 F7): `ps -o lstart=` has 1s
# granularity there, so lstart-only match can false-positive an unrelated
# operator process as the dead lane. Unused on Linux (the /proc starttime
# tick fast path is µs-granularity and doesn't need it).
#
# <ppid> MUST be the value RECORDED at mint time (lane_install's WRAPPER_PPID
# field), never the process's LIVE current ppid. dispatch-local.sh spawns the
# wrapper via `nohup … &` and exits almost immediately, which reparents the
# still-running wrapper to init (ppid → 1) within milliseconds of mint. If
# lane_probe recomputed the fingerprint from the CURRENT ppid, every probe
# after that reparenting would permanently mismatch a genuinely live wrapper
# — the exact false-positive-kill the design's principle 5 forbids. Passing
# the mint-time-recorded ppid at both ends makes the fingerprint's only live
# check `comm` (does this PID still look like the same process?), which is
# the actual PID-recycle signal beyond the already-checked lstart match.
_wrapper_fingerprint() {
  local pid="$1" ppid="$2" lstart="$3" comm
  comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  local hasher
  if command -v sha256sum >/dev/null 2>&1; then
    hasher="sha256sum"
  elif command -v shasum >/dev/null 2>&1; then
    hasher="shasum -a 256"
  else
    echo ""
    return 1
  fi
  printf '%s' "${comm}${ppid}${lstart}" | $hasher 2>/dev/null | awk '{print $1}'
}

# lane_install <project_id> <lane_id> [worktree] — atomically install the
# registry dir for <lane_id> (design §4-C1 F1 timing: closes the
# pre-existence race). Builds the FULL lane KV + pgids + reap.lock inside
# `lanes/.pending-<id_fs>/`, then `mv -T` (Linux) / `mv` (portable — macOS mv
# has no -T, but a non-directory DEST with the same basename never pre-exists
# here since the id is unique per mint) into `lanes/<id_fs>/`. A half-written
# lane dir is therefore never observable under its final name.
#
# WRAPPER_PID is $$ of the CALLING shell (the wrapper itself — this function
# must be called directly from the wrapper's top-level shell, not a subshell,
# so $$ resolves to the process whose liveness the registry tracks).
#
# Echoes the final lane dir path on success; rc=1 + nothing on mkdir/mv
# failure (fail toward "no registry" rather than a half-built one — the
# caller's own PID-file/heartbeat contracts are unaffected either way).
lane_install() {
  local project_id="$1" lane_id="$2" worktree="${3:--}"
  local id_fs root pending final
  id_fs="$(_lane_id_fs "$lane_id")"
  root="$(_lanes_root "$project_id")"
  pending="${root}/.pending-${id_fs}"
  final="${root}/${id_fs}"

  local role issue
  IFS=: read -r _ role issue _ _ <<<"$lane_id"

  local wrapper_pid="$$" wrapper_ppid="$PPID" wrapper_start wrapper_fingerprint="-"
  wrapper_start="$(proc_start_time "$wrapper_pid")"
  if [[ "$(_lane_uname)" != "Linux" ]]; then
    wrapper_fingerprint="$(_wrapper_fingerprint "$wrapper_pid" "$wrapper_ppid" "$wrapper_start")"
    [[ -n "$wrapper_fingerprint" ]] || wrapper_fingerprint="-"
  fi

  rm -rf "$pending" 2>/dev/null || true
  if ! mkdir -p "$pending" 2>/dev/null; then
    return 1
  fi
  chmod 700 "$pending" 2>/dev/null || true

  {
    printf 'LANE_ID=%s\n' "$lane_id"
    printf 'PROJECT_ID=%s\n' "$project_id"
    printf 'ISSUE=%s\n' "$issue"
    printf 'ROLE=%s\n' "$role"
    printf 'MODE=%s\n' "${ADT_LANE_MODE:-new}"
    printf 'BACKEND=pgid\n'
    printf 'UNIT=-\n'
    printf 'WRAPPER_PID=%s\n' "$wrapper_pid"
    printf 'WRAPPER_PPID=%s\n' "$wrapper_ppid"
    printf 'WRAPPER_START=%s\n' "$wrapper_start"
    printf 'WRAPPER_FINGERPRINT=%s\n' "$wrapper_fingerprint"
    printf 'GUARDIAN_PID=-\n'
    printf 'WORKTREE=%s\n' "$worktree"
    printf 'CHROME_PROFILE_HINT=-\n'
    printf 'CREATED_EPOCH=%s\n' "$(date +%s 2>/dev/null || echo 0)"
    printf 'STATE=live\n'
  } > "${pending}/lane" 2>/dev/null || { rm -rf "$pending" 2>/dev/null; return 1; }
  : > "${pending}/pgids" 2>/dev/null || true
  : > "${pending}/reap.lock" 2>/dev/null || true

  if ! mv -T "$pending" "$final" 2>/dev/null && ! mv "$pending" "$final" 2>/dev/null; then
    rm -rf "$pending" 2>/dev/null || true
    return 1
  fi

  printf '%s\n' "$final"
}

# lane_get <lane_dir> <key> — echo the KEY's value from `<lane_dir>/lane`, or
# nothing (rc 1) if the file is missing/unparseable/the key is absent. A flat
# `KEY=VALUE` grep — no jq dependency (design requirement).
lane_get() {
  local lane_dir="$1" key="$2"
  local f="${lane_dir}/lane"
  [[ -f "$f" && -r "$f" ]] || return 1
  local line
  line="$(grep -m1 "^${key}=" "$f" 2>/dev/null)" || return 1
  printf '%s\n' "${line#*=}"
}

# lane_set <lane_dir> <key> <value> — flock-guarded rewrite-then-mv of a
# single KEY in the `lane` file (atomic update — never a partial rewrite
# visible to a concurrent reader; a reader always sees either the old value
# or the new one, never a half-written line). Returns 1 if the lane file is
# missing. Appends the key if it was not already present (defensive — every
# key this PR writes IS present from lane_install, but a future PR's key
# addition should not require a lane-file migration).
lane_set() {
  local lane_dir="$1" key="$2" value="$3"
  local f="${lane_dir}/lane"
  [[ -f "$f" ]] || return 1
  local lock_fd
  exec {lock_fd}>>"${f}.lock" || return 1
  flock -w 5 "$lock_fd" || { exec {lock_fd}>&-; return 1; }
  local tmp
  tmp="$(mktemp "${lane_dir}/.lane.XXXXXX" 2>/dev/null)" || { exec {lock_fd}>&-; return 1; }
  # awk (not sed) line-replace: the replacement VALUE may contain arbitrary
  # bytes (a filesystem path, a sha256 hex, `-`) that would collide with
  # sed's own delimiter/regex metacharacters. Passed via ENVIRON, NOT `-v` —
  # POSIX awk's `-v var=value` interprets C-style backslash escapes in the
  # assignment text itself (a literal two-character `\n` in the value becomes
  # an actual newline, silently truncating/corrupting the line and, for a
  # value that then looks like `KEY2=...`, injecting a bogus extra KV line).
  # `ENVIRON[]` reads the raw environment string verbatim — no escape
  # interpretation — so this is the only awk-side channel safe for arbitrary
  # bytes.
  if LANE_SET_V="$value" awk -v k="${key}=" 'index($0,k)==1{found=1} END{exit !found}' "$f" 2>/dev/null; then
    LANE_SET_V="$value" awk -v k="$key" 'BEGIN{p=k"="; v=ENVIRON["LANE_SET_V"]} index($0,p)==1 {print k"="v; next} {print}' "$f" > "$tmp" 2>/dev/null
  else
    cp "$f" "$tmp" 2>/dev/null
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  mv -f "$tmp" "$f" 2>/dev/null
  local rc=$?
  exec {lock_fd}>&-
  return $rc
}

# lane_set_state <lane_dir> <state> — convenience alias for
# `lane_set <lane_dir> STATE <state>` (the one key every consumer touches by
# name; kept as its own function so call sites read as intent, not KV trivia).
lane_set_state() {
  lane_set "$1" STATE "$2"
}

# lane_record_pgid <lane_dir> <pgid> <role> — append one line to <lane_dir>/pgids:
# `<pgid> <role> <epoch>`. One write(2) per line — the line is well under the
# POSIX PIPE_BUF floor (512B), so concurrent appenders (fan-out sidecars, the
# E2E lane, smoke probes) never interleave partial lines even without an
# explicit flock (design §4-C1 completeness:F9). Silently no-ops (does not
# abort the caller) when the lane dir is missing/unwritable — PGID tracking is
# additive to, never a precondition for, the caller's own operation.
lane_record_pgid() {
  local lane_dir="$1" pgid="$2" role="${3:-agent}"
  [[ -n "$lane_dir" && -d "$lane_dir" ]] || return 0
  [[ "$pgid" =~ ^[0-9]+$ ]] || return 0
  printf '%s %s %s\n' "$pgid" "$role" "$(date +%s 2>/dev/null || echo 0)" \
    >> "${lane_dir}/pgids" 2>/dev/null || true
  return 0
}

# lane_probe <lane_dir> — echo `live` or `dead` for the lane's WRAPPER_PID.
# Liveness = PID alive AND start-time string-matches WRAPPER_START (PID-recycle
# defense) AND, on macOS, WRAPPER_FINGERPRINT also matches. Never sid-liveness,
# never CLAUDE_CODE_SESSION_ID (design's explicit banned-keys list). Echoes
# `unknown` + rc 1 when the lane file is missing/unparseable (fail toward
# "don't know", which is the same as "don't touch" for any caller that only
# acts on an explicit `dead`).
lane_probe() {
  local lane_dir="$1"
  local pid start fingerprint
  pid="$(lane_get "$lane_dir" WRAPPER_PID)" || { echo "unknown"; return 1; }
  start="$(lane_get "$lane_dir" WRAPPER_START)" || { echo "unknown"; return 1; }
  [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]] || { echo "unknown"; return 1; }

  if ! kill -0 "$pid" 2>/dev/null; then
    echo "dead"
    return 0
  fi

  local now_start
  now_start="$(proc_start_time "$pid")"
  if [[ -z "$now_start" || "$now_start" != "$start" ]]; then
    echo "dead"
    return 0
  fi

  if [[ "$(_lane_uname)" != "Linux" ]]; then
    local recorded_fp now_fp recorded_ppid
    recorded_fp="$(lane_get "$lane_dir" WRAPPER_FINGERPRINT)" || recorded_fp="-"
    if [[ -n "$recorded_fp" && "$recorded_fp" != "-" ]]; then
      # Recompute with the RECORDED ppid (WRAPPER_PPID), never the process's
      # LIVE current ppid: dispatch-local.sh spawns the wrapper via `nohup … &`
      # and exits almost immediately, reparenting the still-running wrapper to
      # init (ppid -> 1) within milliseconds of mint. A live-ppid recompute
      # would permanently mismatch a genuinely live wrapper the instant that
      # reparenting happens — the false-positive-kill principle 5 forbids.
      recorded_ppid="$(lane_get "$lane_dir" WRAPPER_PPID)" || recorded_ppid=""
      now_fp="$(_wrapper_fingerprint "$pid" "$recorded_ppid" "$now_start")"
      [[ "$now_fp" == "$recorded_fp" ]] || { echo "dead"; return 0; }
    fi
  fi

  echo "live"
}

# lane_kill <lane_dir> [grace_secs] — registry-authoritative TERM→grace→KILL
# over every pgid recorded in <lane_dir>/pgids. Does NOT consult lane_probe —
# callers (the future kill_stale_wrapper delegate, PR-3) decide liveness
# first; this function only performs the escalation once a caller has
# decided a lane's pgids should die. Idempotent: an already-empty/missing
# pgids file is a clean no-op.
lane_kill() {
  local lane_dir="$1" grace="${2:-10}"
  local pgids_file="${lane_dir}/pgids"
  [[ -f "$pgids_file" ]] || return 0

  local seen=() pg
  while read -r pg _rest; do
    [[ "$pg" =~ ^[0-9]+$ ]] || continue
    # De-dupe: the same pgid may appear on multiple lines (e.g. re-recorded
    # across a resume within the same lane).
    local already=0 s
    for s in "${seen[@]:-}"; do [[ "$s" == "$pg" ]] && { already=1; break; }; done
    [[ "$already" -eq 1 ]] && continue
    seen+=("$pg")
    kill -TERM -- "-${pg}" 2>/dev/null || true
  done < "$pgids_file"

  [[ "${#seen[@]}" -gt 0 ]] || return 0

  local i
  for ((i = 0; i < grace; i++)); do
    local any_alive=0
    for pg in "${seen[@]}"; do
      kill -0 -- "-${pg}" 2>/dev/null && any_alive=1
    done
    [[ "$any_alive" -eq 0 ]] && return 0
    sleep 1
  done

  for pg in "${seen[@]}"; do
    kill -KILL -- "-${pg}" 2>/dev/null || true
  done
  return 0
}

# lane_spawn <lane_dir> <role> -- <cmd...> — pgid-backend spawn (the ONLY
# backend this PR ships; systemd-scope enrollment is a later PR, §4-C7). Runs
# `setsid <cmd...>` in the background, records the resulting PGID into
# <lane_dir>/pgids via lane_record_pgid, waits for it, and returns its exit
# code. `--` is a REQUIRED separator (keeps <role> unambiguous from the
# command's own argv, which may itself contain `--`).
#
# This is a convenience wrapper for NEW spawn sites this PR adds (E2E/smoke
# lane callers may prefer it); it deliberately does NOT replace
# `_run_with_timeout` (lib-agent.sh) — that primitive already owns the agent
# spawn path (env-scrub ordering, launcher-argv, AGENT_PID_FILE) and gets its
# PGID recorded into the lane via a direct `lane_record_pgid` call at its own
# call site instead (see autonomous-dev.sh/autonomous-review.sh).
lane_spawn() {
  local lane_dir="$1" role="$2"
  shift 2
  [[ "${1:-}" == "--" ]] && shift

  local launcher=()
  command -v setsid >/dev/null 2>&1 && launcher=(setsid)

  "${launcher[@]}" "$@" &
  local pgid=$!
  lane_record_pgid "$lane_dir" "$pgid" "$role"
  wait "$pgid"
}
