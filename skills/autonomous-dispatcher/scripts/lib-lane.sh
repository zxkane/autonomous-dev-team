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
# minted lane dir matching (role, issue) under this project's registry, or
# nothing + rc 1 when none exists. A caller that only knows
# (project, role, issue) — e.g. the `kill_stale_wrapper` delegate in
# dispatch-local.sh, which has no lane id to hand (the wrapper it's about to
# replace minted its OWN id) — uses this to find the CURRENT lane before
# deciding whether to delegate to `lane_kill`. "Most recent" matters because a
# stale terminal-state lane for the SAME (role, issue) can outlive its wrapper
# by up to 24h (age-collected by a future GC pass, not this PR) — the newest
# one is always the one that might still be live.
#
# Match + ordering are derived SOLELY from the directory BASENAME
# (`<project_id_fs>.<role>.<issue>.<epoch>.<rand4>`) — written once,
# atomically, at mint (`lane_install`'s `mv -T` into place) and never
# rewritten — never from the `lane` FILE's content. A prior version matched/
# ordered via `lane_get … ROLE/ISSUE/CREATED_EPOCH`, which made a NEWER lane
# whose `lane` file later became corrupted/unparseable (a plausible failure
# independent of the directory's own identity) INVISIBLE to the scan — an
# OLDER, still-parseable sibling then won by default, so `kill_stale_wrapper`
# could reap the wrong lane instead of correctly falling through to the
# legacy path when the newest lane can't be probed (codex review, #378).
# Deriving everything from the immutable basename means the newest MATCHING
# lane is always selected regardless of its file's later parseability; the
# caller's own `lane_probe` (called on the returned dir) then correctly
# resolves `unknown` for an unparseable file and falls through untouched —
# exactly the desired behavior.
#
# SAME-SECOND ties (codex review [P1] round 3, #378): lane_mint's epoch is
# `date +%s` (1s granularity), so two quick redispatches for the same
# (project, role, issue) can legitimately share an epoch — the basename alone
# then cannot encode which lane was actually installed later. The tie-break
# must still be structural (never the `lane` FILE's content, per the
# corruption rationale above), so equal-epoch candidates are ordered by the
# lane DIRECTORY's own birth time (`_lane_birth_key`): the dir inode is
# created once (as `.pending-<id>/`) and `lane_install`'s rename into place
# keeps the same inode, so its birth timestamp is immutable and exactly
# records install order at nanosecond granularity on Linux. Where the
# filesystem/stat cannot report birth time (key collapses to the zero
# constant) or two births genuinely compare equal (macOS 1s granularity),
# the final backstop is the lexically-greater basename — arbitrary but
# DETERMINISTIC, so repeated scans always converge on the same lane.
lane_find_latest() {
  local project_id="$1" role="$2" issue="$3"
  # C collation for the composite-key `>` compare below — locale-dependent
  # strcoll() ordering of `.`/digits must not change which lane wins.
  local LC_ALL=C LC_COLLATE=C
  local root
  root="$(_lanes_root "$project_id")"
  local best="" best_key=""
  local d base
  # ^(project_id_fs).(role).(issue).(epoch).(rand4)$ — anchored end-to-end so
  # a malformed/foreign basename never partially matches. project_id_fs is
  # matched greedily (it may itself contain literal dots); role is any
  # dot-free token; issue is either the `-` dispatcher-alert sentinel or
  # digits; epoch is digits (lane_mint's `date +%s`); rand4 is exactly 4
  # lowercase hex chars (lane_mint's openssl/urandom/RANDOM fallback chain).
  local pat='^(.+)\.([^.]+)\.(-|[0-9]+)\.([0-9]+)\.([0-9a-f]{4})$'
  for d in "$root"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    base="$(basename "$d")"
    [[ "$base" == .pending-* ]] && continue
    [[ "$base" =~ $pat ]] || continue
    [[ "${BASH_REMATCH[2]}" == "$role" ]] || continue
    [[ "${BASH_REMATCH[3]}" == "$issue" ]] || continue
    # Composite ordering key: zero-padded mint epoch (primary, basename),
    # then dir birth time (same-second tie-break, install order), then the
    # basename itself (determinism backstop). Fixed-width numeric fields make
    # plain string `>` a correct total order. `10#` pins decimal — a
    # leading-zero epoch in a (foreign) basename must not flip printf/((...))
    # into octal.
    local key
    key="$(printf '%020d' "$((10#${BASH_REMATCH[4]}))" 2>/dev/null).$(_lane_birth_key "$d").${base}"
    if [[ -z "$best" || "$key" > "$best_key" ]]; then
      best_key="$key"
      best="$d"
    fi
  done
  [[ -n "$best" ]] || return 1
  printf '%s\n' "$best"
}

# _lane_birth_key <dir> — echo a fixed-width, string-comparable form of the
# directory inode's birth (creation) timestamp: `<secs%020d>.<frac-9-digits>`.
# Linux: `stat -c %.W` (nanosecond-fractional birth via statx; coreutils
# ≥8.31); macOS/BSD: `stat -f %B` (integer seconds). The dir inode is created
# exactly once — `lane_install` renames `.pending-<id>/` into place, which
# preserves the inode — so this timestamp is immutable install-order ground
# truth, unlike the dir's mtime (mutated by `lane_set`'s tmp-file churn) or
# any file's content/mtime inside it. Filesystems that don't record birth
# make stat report 0 (GNU convention) — normalized here to the all-zeros
# constant so both tie candidates compare equal and the caller falls through
# to its basename backstop instead of trusting a bogus timestamp.
_lane_birth_key() {
  local d="$1" b sec frac
  # LC_ALL=C: the fractional separator must be `.` (a locale comma would
  # fail the format regex below and demote a real birth time to the zero key).
  b="$(LC_ALL=C stat -c %.W "$d" 2>/dev/null)" || b="$(LC_ALL=C stat -f %B "$d" 2>/dev/null)" || b=""
  sec="${b%%.*}"
  if [[ ! "$b" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ "$sec" =~ ^0+$ ]]; then
    printf '%020d.%s' 0 000000000
    return 0
  fi
  frac=""
  [[ "$b" == *.* ]] && frac="${b#*.}"
  frac="${frac}000000000"
  printf '%020d.%s' "$((10#$sec))" "${frac:0:9}"
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

# _kill_group_escalate <pgid> [grace_secs] — the minimal-diff TERM→grace→KILL
# primitive (design §4-C4, adopted verbatim as the shared building block).
# Completion is gated on the GROUP being unreachable (`kill -0 -- -pgid`
# failing), never on any single leader PID's liveness — this is the exact
# distinction INV-106/INV-114 requires: a TERM-trapping member whose leader
# already died must still get the KILL pass. A miss on the initial TERM
# (group already gone) short-circuits to a clean return without waiting out
# the grace window.
_kill_group_escalate() {
  local pg="$1" g="${2:-5}" i
  kill -TERM -- "-${pg}" 2>/dev/null || return 0
  for ((i = 0; i < g; i++)); do
    kill -0 -- "-${pg}" 2>/dev/null || return 0
    sleep 1
  done
  kill -KILL -- "-${pg}" 2>/dev/null || true
  return 0
}

# lane_kill <lane_dir> [grace_secs] — registry-authoritative TERM→grace→KILL
# over every DISTINCT pgid recorded in <lane_dir>/pgids. Does NOT consult
# lane_probe — callers (the kill_stale_wrapper delegate, guardian, GC) decide
# liveness first; this function only performs the escalation once a caller
# has decided a lane's pgids should die. Idempotent: an already-empty/missing
# pgids file is a clean no-op.
#
# Serialized on the lane's own `reap.lock` (design §4-C4/INV-114 selfdefeat
# F3) — shared with `cleanup()`'s own reap so a re-dispatch's delegate call
# and the outgoing wrapper's own graceful teardown can never issue
# overlapping KILLs against the same pgid. A missing/unwritable lock file
# degrades to unlocked (best-effort — a lock outage must never block a kill
# that's otherwise authorized). Bounded `flock -w 10` rather than an
# indefinite wait: flock's advisory lock is released by the kernel the
# instant the holding process dies (no separate reclaim logic needed, unlike
# a mkdir-based lock — see the #360 double-reclaim lesson), so a 10s bound is
# purely defensive against an implausible pathological hold, not a real
# recovery mechanism.
#
# Each distinct pgid escalates via `_kill_group_escalate` in its OWN
# backgrounded job so N pgids run their grace windows CONCURRENTLY — total
# wall-clock stays ~grace regardless of how many groups are recorded, not
# grace*N.
lane_kill() {
  local lane_dir="$1" grace="${2:-10}"
  local pgids_file="${lane_dir}/pgids"
  [[ -f "$pgids_file" ]] || return 0

  local lock_fd=""
  if [[ -f "${lane_dir}/reap.lock" ]]; then
    exec {lock_fd}>>"${lane_dir}/reap.lock" 2>/dev/null || lock_fd=""
    [[ -n "$lock_fd" ]] && { flock -w 10 "$lock_fd" 2>/dev/null || true; }
  fi

  local seen=() pg
  while read -r pg _rest; do
    [[ "$pg" =~ ^[0-9]+$ ]] || continue
    # De-dupe: the same pgid may appear on multiple lines (e.g. re-recorded
    # across a resume within the same lane).
    local already=0 s
    for s in "${seen[@]:-}"; do [[ "$s" == "$pg" ]] && { already=1; break; }; done
    [[ "$already" -eq 1 ]] && continue
    seen+=("$pg")
  done < "$pgids_file"

  if [[ "${#seen[@]}" -gt 0 ]]; then
    # [INV-114] Escalator pgid isolation (review round-8 [P1], same class as
    # the sigterm-trap escalators): a bare backgrounded escalator is a direct
    # child sharing the CALLER's pgid — when the caller's own group is later
    # group-SIGKILLed mid-escalation (kill_stale_wrapper escalating against a
    # still-alive wrapper whose cleanup()/lane_reap is running this very
    # function), the escalator dies with it mid-grace and the pending KILL
    # follow-through for a TERM-resistant recorded group is silently lost.
    # `setsid` puts each escalator in its own session/pgid so only its target
    # and its own bounded sleep decide its lifetime. Still a direct CHILD, so
    # the `wait` below works unchanged; `export -f` carries the (call-free)
    # primitive across the bash -c boundary. Falls back to the bare form when
    # setsid is unavailable (non-Linux) — same degraded posture as the trap.
    local escalate_pids=() _lk_setsid=()
    command -v setsid >/dev/null 2>&1 && _lk_setsid=(setsid)
    export -f _kill_group_escalate
    for pg in "${seen[@]}"; do
      "${_lk_setsid[@]}" bash -c '_kill_group_escalate "$1" "$2"' _ "$pg" "$grace" &
      escalate_pids+=("$!")
    done
    wait "${escalate_pids[@]}" 2>/dev/null || true
  fi

  [[ -n "$lock_fd" ]] && exec {lock_fd}>&-
  return 0
}

# lane_reap <lane_dir> [grace_secs] — the exact reap-first primitive
# `cleanup()` uses in both wrappers ([Lane-GC PR-3], INV-114 row 2): acquires
# `reap.lock`, records `STATE=reaping` while the escalation runs (so a
# concurrent GC/guardian/delegate scan — later PRs — sees "someone is already
# reaping this lane" rather than double-dispatching a second reap), calls
# `lane_kill` (which itself re-acquires the SAME `reap.lock` — `flock` on an
# already-held fd by the SAME process is a re-entrant no-op-wait, never a
# self-deadlock, because both acquisitions happen inside the SAME shell
# process and flock's advisory lock is per-fd/per-process, not per-call), then
# restores `STATE=cleaning` (the caller's own state — `lane_reap` never sets
# the terminal `clean-exit`; that transition belongs to the caller's own
# lifecycle, not this helper). Best-effort: a missing/degraded lane dir is a
# silent no-op, matching every other lane_* consumer-side guard.
lane_reap() {
  local lane_dir="$1" grace="${2:-5}"
  [[ -n "$lane_dir" && -d "$lane_dir" ]] || return 0
  declare -F lane_set_state >/dev/null 2>&1 && lane_set_state "$lane_dir" reaping || true
  lane_kill "$lane_dir" "$grace"
  declare -F lane_set_state >/dev/null 2>&1 && lane_set_state "$lane_dir" cleaning || true
  return 0
}

# _bounded_call <secs> <cmd...> — run "$@" with a wall-clock bound of <secs>
# seconds so a teardown-path network call (GitHub API, PR create, comment
# post) can never hang a `cleanup()` EXIT trap indefinitely while it holds
# lane state ([Lane-GC PR-3], INV-114 row 2 — design §4-C4/§12 R10's 60s
# network-call bound).
#
# Deliberately does NOT delegate to coreutils `timeout` (unlike
# `_run_with_timeout` in lib-agent.sh, which bounds an exec'd CLI BINARY):
# every teardown call site this wraps (`itp_post_comment`, `chp_pr_list`,
# `drain_agent_pr_create`, `get_gh_app_token`, …) is a bash FUNCTION already
# sourced into the wrapper's own shell, and `timeout <secs> <bash-function>`
# fails outright (`exec` cannot resolve a shell function as a binary — proven
# empirically: `timeout 2 myfunc` → "failed to run command … No such file or
# directory", rc 127) — coreutils `timeout` can only ever bound a real
# exec'd program, never a function in the calling shell.
#
# Implementation: temporarily enable job control (`set -m`) around the
# background spawn, so the wrapped call gets its OWN process group (PID ==
# PGID), then restore the caller's prior monitor-mode setting immediately
# after capturing `$!` — the child's pgid assignment is a property fixed at
# fork time, so toggling `set -m` back off right away never affects it. This
# is load-bearing, not cosmetic: a GitHub-API helper that itself does
# `out=$(some_long_curl_command)` forks a GRANDCHILD via command
# substitution — a plain (job-control-disabled) background job shares the
# calling shell's own PGID, so a plain `kill -TERM "$cpid"` reaches only the
# direct child, never that grandchild, leaking it past the wrapper's own
# exit (verified empirically: a wrapped function forking a `sleep 20`
# grandchild survived a "plain kill" implementation indefinitely). A
# group-form kill on ESCALATION reaches the whole subtree, the same
# `_kill_group_escalate` guarantee this file already gives every OTHER kill
# path.
#
# Rejected alternative: `export -f "$1"` + `setsid bash -c '"$@"' _ "$@"`
# (a nested shell, matching `_kill_group_escalate`'s pgid semantics via
# `setsid` instead of `set -m`). Rejected because `export -f` only exports
# the ONE named function — every real call site here (`itp_post_comment`,
# `chp_pr_list`, …) internally calls OTHER functions (`itp_post_comment` →
# `itp_${ISSUE_PROVIDER}_post_comment`) that would NOT be exported, so the
# nested `bash -c` subshell would fail with "command not found" on the
# very first internal call (verified empirically). `set -m` backgrounds the
# call in THIS SAME shell (no new bash process, no export step), so every
# function already sourced into the caller stays naturally visible — no
# additional plumbing needed.
#
# Poll loop uses a PLAIN (non-group) `kill -0 "$cpid"` — never `-- "-$cpid"`
# — for the liveness check: `set -m`'s pgid assignment IS synchronous with
# `&` (unlike `setsid`, which asynchronously calls `setsid(2)` inside the
# forked child — verified empirically to intermittently ESRCH-miss a
# same-tick group probe), so there is no race here; the plain-PID form is
# simply the minimal-diff choice matching pre-PR-3 behavior for the common
# (no-timeout) path. By escalation time several seconds have already
# elapsed regardless, so the group form is unambiguously safe (and
# necessary, to reach the grandchild) there.
#
# stdout and stderr are captured to TWO SEPARATE private tmpfiles and
# replayed to their own fds — so the caller's own `2>/dev/null`/`2>&1` on the
# `_bounded_call` invocation itself still works exactly as if the wrapped
# call had run inline. A single merged tmpfile was tried first and rejected:
# several real call sites (e.g. `chp_pr_list --state open … 2>/dev/null ||
# echo "0"`) rely on THEIR OWN outer `2>/dev/null` to drop stderr before the
# value is used in an arithmetic/string comparison — a merged capture
# defeats that redirection (proven empirically: a wrapped function that logs
# one benign stderr line before printing its real stdout value corrupts the
# captured variable into a multi-line string even though the caller wrote
# `2>/dev/null`), which can trip `set -euo pipefail`'s unbound-
# variable/arithmetic-comparison guards downstream and abort `cleanup()`
# before it finishes label transitions.
#
# `Feature-detected; unwrapped+WARN without` (per the design's own wording)
# is satisfied by falling back to a plain unwrapped call whenever EITHER
# tmpfile can't be created (e.g. /tmp unwritable) — the design's escape
# hatch is for a MISSING BOUNDING MECHANISM, and background+poll needs no
# external tool, so that fallback triggers only on this narrow I/O failure.
_bounded_call() {
  local secs="$1"; shift
  local outfile errfile
  outfile="$(mktemp 2>/dev/null)" && errfile="$(mktemp 2>/dev/null)" || {
    echo "[lib-lane] WARN: cannot create tmpfile for bounded call; running teardown call unbounded (may hang): $*" >&2
    rm -f "${outfile:-}" "${errfile:-}" 2>/dev/null || true
    "$@"
    return $?
  }
  local _old_monitor=0
  case "$-" in *m*) _old_monitor=1 ;; esac
  set -m
  "$@" > "$outfile" 2> "$errfile" &
  local cpid=$! i rc
  # Restore the caller's monitor-mode setting immediately — the child's
  # pgid is already fixed at this point (fork-time property), so this
  # never affects it, and the caller's own `set -m`/job-control state
  # (e.g. `set -euo pipefail` scripts that never enable it) is never
  # permanently altered by a call into this helper.
  [[ "$_old_monitor" -eq 0 ]] && set +m
  for ((i = 0; i < secs; i++)); do
    if ! kill -0 "$cpid" 2>/dev/null; then
      # `wait`'s own exit status mirrors the waited-on child's — under a
      # caller's `set -e` (every real call site here runs inside a
      # `set -euo pipefail` wrapper), a bare `wait "$cpid"` for a
      # NON-ZERO-exiting wrapped call aborts the CALLING shell right here,
      # before `rc=$?` ever runs (proven empirically). `|| rc=$?` — never a
      # bare statement followed by a separate `rc=$?` line — is required on
      # every `wait` in this function so a wrapped call's real failure exit
      # code is captured instead of unwinding whatever shell called
      # `_bounded_call`.
      rc=0; wait "$cpid" 2>/dev/null || rc=$?
      cat "$outfile"
      cat "$errfile" >&2
      rm -f "$outfile" "$errfile"
      return "$rc"
    fi
    sleep 1
  done
  echo "[lib-lane] WARN: teardown call exceeded ${secs}s bound; terminating: $*" >&2
  kill -TERM -- "-${cpid}" 2>/dev/null || true
  sleep 1
  kill -KILL -- "-${cpid}" 2>/dev/null || true
  wait "$cpid" 2>/dev/null || true
  cat "$outfile"
  cat "$errfile" >&2
  rm -f "$outfile" "$errfile"
  return 124
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
