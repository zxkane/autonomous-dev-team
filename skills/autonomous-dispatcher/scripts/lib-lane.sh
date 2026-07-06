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
# [Lane-GC PR-7 review round-1, P1-2/P2-1] Bounded systemd/loginctl calls.
#
# The scope backend is explicitly "never load-bearing" (design principle 8) —
# but EVERY `systemd-run`/`systemctl`/`loginctl` invocation this file makes
# was, before this fix, unbounded. A wedged user bus (a real, observed
# systemd failure mode — this box's own `systemctl --user status` already
# reports 3 failed units) would hang:
#   - `_lane_backend`'s mint-time probe -> hangs the WRAPPER before the
#     registry even exists, on every single dispatch, not just scope hosts.
#   - `_lane_scope_kill`'s TERM/show calls -> hangs `lane_kill` WHILE IT
#     HOLDS `reap.lock`, starving the pgid escalation that must always run
#     afterward per this same function's own "defense in depth" contract.
# `_LANE_TIMEOUT_CMD` is resolved ONCE at source time (mirrors
# `lib-agent.sh`'s `_AGENT_TIMEOUT_CMD` resolution verbatim — same
# timeout/gtimeout feature-detection, same "absent -> unwrapped, degraded
# posture" fallback, since a bounding tool is a nice-to-have hardener here,
# not a hard dependency the way `flock`/`setsid` are).
_LANE_TIMEOUT_CMD="$(command -v timeout || command -v gtimeout || true)"

# _lane_bounded <secs> <cmd...> — run "$@" bounded to <secs> wall-clock
# seconds when a `timeout`/`gtimeout` binary is available; otherwise runs
# "$@" unwrapped (absence of a bounding tool must never be a HARDER failure
# mode than having one — every call site already treats a non-zero rc as
# "prerequisite failed, fall back", so an unbounded call here still fails
# SOMETHING eventually via the wedged command's own eventual rc, it just
# loses the wall-clock guarantee). `timeout`/`gtimeout` cleanly wraps a REAL
# exec'd binary (systemd-run/systemctl/loginctl are all real binaries, never
# shell functions), unlike the `_bounded_call` background+poll technique
# `lane_kill`'s own network-call primitive uses for wrapping bash FUNCTIONS.
_lane_bounded() {
  local secs="$1"; shift
  if [[ -n "$_LANE_TIMEOUT_CMD" ]]; then
    "$_LANE_TIMEOUT_CMD" "$secs" "$@"
  else
    "$@"
  fi
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
# (design §4-C2 platform:F5). macOS: the `sysctl kern.procargs2` shim
# (`_procargs2_py`, this PR) when python3 is present — the SAME source of
# truth `env_readable` consults, deliberately: `env_readable` answering
# "readable" (via a successful procargs2 probe) while env_of/env_lookup
# silently returned nothing (the pre-round-3 state — env_of was
# Linux-only) re-opened on Darwin the exact fail-open hole `env_readable`
# exists to close: a TERM_PROGRAM-protected operator process probed
# READABLE, then env_lookup found no TERM_PROGRAM in an EMPTY read, and
# the candidate fell through to full kill eligibility. The two functions
# MUST stay source-aligned — any read path added to one must be added to
# both (review round-3 [P1]). Echoes nothing + rc 1 when unreadable (dead
# process, permission, or macOS with no python3 shim).
env_of() {
  local pid="$1"
  if [[ -r "/proc/${pid}/environ" ]]; then
    tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null
    return 0
  fi
  if [[ "$(_lane_uname)" != "Linux" ]] && _lane_procargs2_available; then
    local out
    out="$(_procargs2_py "$pid" 2>/dev/null)" || return 1
    [[ -n "$out" ]] || return 1
    awk '/^ENV$/{f=1;next} f' <<<"$out"
    return 0
  fi
  return 1
}

# env_readable <pid> — true iff `env_of` can actually READ this process's
# environment (Linux: `[ -r /proc/PID/environ ]`; macOS: the procargs2 shim
# is installed AND actually returns data for THIS pid, not merely "python3
# exists somewhere on PATH" — `_lane_procargs2_available` alone answers a
# host-wide question, not a per-pid one).
#
# [Lane-GC PR-4 review round-2, P1-2] Exists to let a caller distinguish
# two DIFFERENT reasons `env_lookup`/`_gc_has_term_program`-style callers
# see "no TERM_PROGRAM found": (a) the environment IS readable and
# TERM_PROGRAM genuinely is not set — proceed with the rest of the
# decision table; vs. (b) the environment is UNREADABLE (the process died
# between the enumeration and the env read, EPERM from a uid mismatch, or
# macOS with no shim) — the process is UNKNOWABLE, not "known clean", and
# every kill-authorization path must therefore skip it (fail toward leak,
# design principle 5), the same posture the design already mandates for
# TERM_PROGRAM itself. Before this primitive existed, callers could not
# tell the two cases apart: `env_lookup … TERM_PROGRAM || echo ""` returns
# an identical empty string for both, so an unreadable-env process
# (whose true env is entirely unknown) was silently treated the same as
# an env-clean one and fell through to full kill eligibility — exactly
# the moment the least is known about a candidate.
env_readable() {
  local pid="$1"
  if [[ "$(_lane_uname)" == "Linux" ]]; then
    [[ -r "/proc/${pid}/environ" ]]
    return $?
  fi
  # macOS: readable only if the shim is installed AND its LIVE fetch (by
  # pid, not the synthetic-buffer parser-only test path) actually
  # succeeds for this specific pid right now — `_procargs2_py`'s own rc
  # already distinguishes "parsed a real procargs2 buffer" (0) from
  # "sysctl failed (dead pid / EPERM) or the buffer was too short /
  # malformed" (1); a dead-pid probe or a permission error both correctly
  # report unreadable here, never masquerading as "readable, empty env".
  _lane_procargs2_available || return 1
  _procargs2_py "$pid" >/dev/null 2>&1
}

# file_mtime <path> — echo the file's mtime as an epoch integer. Linux
# `stat -c %Y`, macOS/BSD `stat -f %m`. Echoes nothing + rc 1 on a missing
# file (mirrors the dual-pattern already used by lib-run-artifacts.sh/status.sh).
file_mtime() {
  local path="$1"
  stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null
}

# ---------------------------------------------------------------------------
# macOS `sysctl kern.procargs2` shim ([Lane-GC PR-4], design §4-C5/§7
# platform:F2) — the env_of docstring above deferred this to "the GC PR";
# this is that PR. `ps eww` is explicitly BANNED for kill authorization (no
# argv/env delimiter — a value containing a space is indistinguishable from
# a new argv element); the KERN_PROCARGS2 buffer is argc-DELIMITED (a leading
# int32 argc, then NUL-terminated exec_path/argv[]/envp[] strings), so it is
# the only portable way to split argv from envp on Darwin without guessing.
#
# Split into a PURE PARSER (`_procargs2_parse_py`, stdin bytes -> ARGV/ENV
# sections) and a LIVE FETCHER (`_procargs2_py`, ctypes sysctl(3) call by pid
# -> parser) so the parser is unit-testable on Linux CI against a SYNTHETIC
# buffer — no macOS runner, no real sysctl call, required (design §11 "macOS
# ACs decision": PR-4's macOS ACs may be deferred to a follow-up when no
# runner exists, but must still be unit-tested against mocked output).
_procargs2_py() {
  # Writes the script to a TEMP FILE rather than feeding it to `python3 -`
  # via a heredoc: `python3 -` reads the SCRIPT ITSELF from stdin, which
  # would consume the fd and leave nothing for the script's own
  # `sys.stdin.buffer.read()` (the no-pid/parser-test call path) to read —
  # a real bug caught by TC-LGC4-114 unit-testing this exact path against
  # a synthetic buffer piped on stdin.
  local _py_script
  _py_script="$(mktemp 2>/dev/null)" || return 1
  cat > "$_py_script" <<'PY'
import sys, struct

def parse(data):
    if len(data) < 4:
        return None
    argc = struct.unpack('<i', data[0:4])[0]
    rest = data[4:]
    # Skip the NUL-terminated exec_path, then any NUL padding before argv[0].
    idx = rest.find(b'\x00')
    if idx < 0:
        return None
    idx += 1
    while idx < len(rest) and rest[idx:idx + 1] == b'\x00':
        idx += 1
    strings = []
    cur = idx
    while cur < len(rest):
        nul = rest.find(b'\x00', cur)
        if nul < 0:
            break
        strings.append(rest[cur:nul])
        cur = nul + 1
    argv = strings[:argc]
    envp = [e for e in strings[argc:] if e]
    return argv, envp

def emit(data):
    parsed = parse(data)
    if parsed is None:
        return 1
    argv, envp = parsed
    print("ARGV")
    for a in argv:
        print(a.decode('utf-8', 'surrogateescape'))
    print("ENV")
    for e in envp:
        print(e.decode('utf-8', 'surrogateescape'))
    return 0

def fetch(pid):
    import ctypes, ctypes.util
    libc_path = ctypes.util.find_library('c')
    if not libc_path:
        return None
    libc = ctypes.CDLL(libc_path, use_errno=True)
    CTL_KERN, KERN_PROCARGS2 = 1, 49
    mib = (ctypes.c_int * 3)(CTL_KERN, KERN_PROCARGS2, pid)
    size = ctypes.c_size_t(0)
    if libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0:
        return None
    if size.value == 0:
        return None
    buf = ctypes.create_string_buffer(size.value)
    if libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        return None
    return buf.raw[:size.value]

def main():
    if len(sys.argv) > 1 and sys.argv[1].isdigit():
        data = fetch(int(sys.argv[1]))
        if data is None:
            return 1
    else:
        data = sys.stdin.buffer.read()
    return emit(data)

sys.exit(main())
PY
  python3 "$_py_script" "$@"
  local _rc=$?
  rm -f "$_py_script" 2>/dev/null
  return $_rc
}

# _lane_procargs2_available — true iff the macOS shim's runtime
# dependency (python3) is present. Never true on Linux (env_of/proc_argv
# already have a faster native path there and never call this).
_lane_procargs2_available() {
  command -v python3 >/dev/null 2>&1
}

# proc_argv <pid> — echo the process's argv, one element per line. Linux:
# `/proc/PID/cmdline` (NUL-delimited). macOS: the procargs2 shim when
# python3 is present. Echoes nothing + rc 1 when neither source is
# available — callers must tolerate an empty result (design §7: absent the
# shim, macOS GC is registry-authoritative only).
proc_argv() {
  local pid="$1"
  if [[ -r "/proc/${pid}/cmdline" ]]; then
    tr '\0' '\n' < "/proc/${pid}/cmdline" 2>/dev/null
    return 0
  fi
  if [[ "$(_lane_uname)" != "Linux" ]] && _lane_procargs2_available; then
    local out
    out="$(_procargs2_py "$pid" 2>/dev/null)" || return 1
    [[ -n "$out" ]] || return 1
    awk '/^ARGV$/{f=1;next} /^ENV$/{f=0} f' <<<"$out"
    return 0
  fi
  return 1
}

# proc_ppid <pid> — echo the process's PARENT pid. Linux: `/proc/PID/stat`
# field 4 (the fast, subprocess-free path — same field-splitting technique
# as proc_start_time). macOS/BSD fallback: `ps -o ppid=`.
proc_ppid() {
  local pid="$1"
  if [[ -r "/proc/${pid}/stat" ]]; then
    local stat_line rest
    stat_line="$(cat "/proc/${pid}/stat" 2>/dev/null)" || { echo ""; return 1; }
    rest="${stat_line##*)}"
    # shellcheck disable=SC2206 # intentional word-split of numeric fields
    local fields=($rest)
    if [[ -n "${fields[1]:-}" ]]; then
      echo "${fields[1]}"
      return 0
    fi
    echo ""
    return 1
  fi
  ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]'
}

# proc_pgid <pid> — echo the process's process-group id via `ps -o pgid=`
# (identical on Linux and macOS/BSD — no dual-path needed).
proc_pgid() {
  local pid="$1"
  ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]'
}

# env_lookup <pid> <KEY> — echo VALUE for the exact KEY from `env_of`'s
# output, or nothing + rc 1 when absent/unreadable. Centralizes the `KEY=`
# prefix match every GC decision-table rule needs (ADT_LANE_ID, CC_USER,
# AUTONOMOUS_CONF_LOADED_FROM, TERM_PROGRAM, GH_TOKEN_FILE) behind one
# call, so no caller hand-rolls its own grep against env_of's raw lines.
env_lookup() {
  local pid="$1" key="$2" line
  line="$(env_of "$pid" 2>/dev/null | grep -m1 "^${key}=")" || return 1
  printf '%s\n' "${line#*=}"
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
# Backend selection ([Lane-GC PR-7], design §4-C1/§4-C7; INV-120) — probed
# ONCE per wrapper run at mint time (lane_install calls this), recorded into
# the lane's own BACKEND field so every later kill-side consumer (lane_kill,
# the guardian, GC) reads the DECISION instead of re-probing. Re-probing at
# kill time would let the host's linger/bus state drift between mint and
# kill and disagree with what was actually spawned.
# ---------------------------------------------------------------------------

# _lane_warn <msg> — the one WARN sink this file already has a scattered
# convention for (`echo "[lib-lane] WARN: ..." >&2` at the two _bounded_call
# sites); centralized here so the backend probe's own WARN (design §4-C1
# "any prerequisite missing -> BACKEND=pgid + WARN, silent full fallback")
# uses the identical prefix instead of inventing a second wording.
_lane_warn() {
  echo "[lib-lane] WARN: $*" >&2
}

# _lane_backend — echo `systemd-scope` or `pgid` (design §4-C1 `_lane_backend`,
# §4-C7, §7 platform:F3; INV-120). Every prerequisite is a SILENT fallback to
# `pgid` (never a hard failure — the pgid path must remain fully sufficient
# alone, design principle 8) with exactly one WARN line naming the missing
# prerequisite, so an operator reading the wrapper's own stderr/log can tell
# WHY a host never enrolls without digging into this function.
#
# [Lane-GC PR-7 review round-1, P1-1] `ADT_LANE_BACKEND_OVERRIDE` (test-only
# seam) may ONLY NARROW the result, never WIDEN it:
#   - `ADT_LANE_BACKEND_OVERRIDE=pgid`  -> unconditionally forces pgid. Always
#     safe (pgid is the universally-sufficient backend), so no checks are
#     needed or run.
#   - `ADT_LANE_BACKEND_OVERRIDE=systemd-scope` -> REQUESTS scope, but the
#     request still has to pass every real linger/bus/probe check below —
#     it does NOT skip them. Before this fix, an inherited (even
#     accidental) `ADT_LANE_BACKEND_OVERRIDE=systemd-scope` in a wrapper's
#     environment would enroll scopes on a Linger=no host by skipping the
#     ENTIRE probe including the load-bearing linger gate — exactly the
#     mass-SIGKILL-on-last-logout scenario the design forbids (§4-C7,
#     platform:F3). A test that needs a deterministic scope-backend lane on
#     a Linger=no CI/dev box must therefore mutate the LANE FILE directly
#     after installation (`lane_set "$LANE_DIR" BACKEND systemd-scope`),
#     not rely on this override to manufacture a scope backend the real
#     host doesn't actually support — the override's only reachable
#     positive outcome is "this host genuinely qualifies anyway".
#   - unset -> normal probe, no forcing either direction.
#
# Order matters — cheapest/most-decisive checks first, so a host that is
# obviously ineligible (non-Linux, no systemd-run) never pays for a bus-probe
# spawn:
#   1. Linux only (uname).
#   2. `systemd-run` on PATH.
#   3. Linger=yes — checked at SELECTION time, not merely at probe time (the
#      design's platform:F3 finding): a linger-less host's user@.service dies
#      with the last operator session and cascade-SIGKILLs every enrolled
#      scope, so this gate is checked before any bus/probe work, and its
#      absence produces the WARN unconditionally (the other candidate
#      failures are comparatively rare in production; this one is the
#      documented default posture on a freshly onboarded host — see the
#      design's own "this host currently has Linger=no").
#   4. The user bus socket exists (`$XDG_RUNTIME_DIR/bus`, self-exporting
#      XDG_RUNTIME_DIR exactly like the design's C7 spawn snippet does — the
#      SSM dispatch chain does not set it).
#   5. A real probe spawn (`systemd-run --user --scope --quiet -- true`)
#      actually succeeds — the preceding checks establish plausibility, this
#      one proves it (a degraded user manager, e.g. `systemctl --user status`
#      showing failed units as observed on THIS box, can still fail an actual
#      spawn even with linger=yes and a live bus).
#
# [Lane-GC PR-7 review round-1, P1-2/P2-1] Every `loginctl`/`systemd-run`
# call below is bounded via `_lane_bounded` — a wedged user bus must never
# hang the WRAPPER at mint time, before the registry even exists. A timeout
# is treated identically to any other probe failure: silent fallback to
# pgid, one WARN naming which check timed out.
_lane_backend() {
  if [[ "${ADT_LANE_BACKEND_OVERRIDE:-}" == "pgid" ]]; then
    echo "pgid"
    return 0
  fi
  if [[ "$(_lane_uname)" != "Linux" ]]; then
    echo "pgid"
    return 0
  fi
  if ! command -v systemd-run >/dev/null 2>&1; then
    _lane_warn "systemd-scope backend requires 'systemd-run' on PATH; falling back to pgid"
    echo "pgid"
    return 0
  fi

  local linger
  linger="$(_lane_bounded 5 loginctl show-user -p Linger --value 2>/dev/null || echo no)"
  if [[ "$linger" != "yes" ]]; then
    _lane_warn "systemd-scope backend requires 'loginctl enable-linger \$USER' (Linger=yes at backend-selection time — without it, the last operator logout cascade-SIGKILLs every enrolled scope), or the linger probe timed out; falling back to pgid"
    echo "pgid"
    return 0
  fi

  local xdg="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  if [[ ! -S "${xdg}/bus" ]]; then
    _lane_warn "systemd-scope backend requires a reachable user bus socket at '${xdg}/bus'; falling back to pgid"
    echo "pgid"
    return 0
  fi

  if ! XDG_RUNTIME_DIR="$xdg" _lane_bounded 5 systemd-run --user --scope --quiet -- true >/dev/null 2>&1; then
    _lane_warn "systemd-scope backend probe spawn failed or timed out ('systemd-run --user --scope --quiet -- true'); falling back to pgid"
    echo "pgid"
    return 0
  fi

  echo "systemd-scope"
}

# ---------------------------------------------------------------------------
# Lane naming
# ---------------------------------------------------------------------------

# _lane_id_fs <lane_id> — echo the filesystem/systemd-safe form (`:` → `.`).
_lane_id_fs() {
  printf '%s' "${1//:/.}"
}

# _lane_unit_name <lane_id> — echo the systemd `--unit` name for <lane_id>
# (design §4-C7: `adt-<lane_id_fs>`). `lane_id_fs` already carries the mint
# epoch + rand4 (from lane_mint's own collision-avoidance), so a unit name
# derived from it is collision-free by construction — no separate rand
# suffix needed here (design §4-C7 "Unit name derives from the (epoch+
# rand-suffixed) lane id — no collisions").
#
# [Lane-GC PR-7 review round-1, P2-2] `PROJECT_ID` is caller-supplied
# (dispatcher conf, not this file's own invariant), so `_lane_id_fs`'s bare
# `:`->`.` substitution alone does not guarantee a systemd-acceptable unit
# name: empirically verified on this box, `@` is rejected outright
# (`systemd-run --unit` fails with "Invalid argument"), and unit names are
# capped at 255 bytes TOTAL including the `.scope` suffix systemd appends
# (`adt-<name>.scope` at 250 raw chars => 256 total => rejected; 249 raw
# chars => 255 total => accepted — the exact boundary probed live). Two
# independent hardenings, both load-bearing given `lane_spawn`'s own
# fallback added in the same PR-7 review round (a rejected unit name must
# never mean "the payload never ran" — see `lane_spawn`'s own comment):
#   1. Sanitize: replace every byte OUTSIDE systemd's own safe unit-name
#      alphabet (`[A-Za-z0-9:_.\-]` per systemd.unit(5) "Unit names must
#      consist only of...") with `-`. `:` survives this class but is
#      ALREADY converted to `.` upstream by `_lane_id_fs`, so in practice
#      this step only ever fires on `PROJECT_ID`-contributed bytes.
#   2. Truncate to a total budget of 200 chars (well under systemd's 255,
#      matching the review's own margin) while PRESERVING THE TAIL — the
#      `.<epoch>.<rand4>` suffix `lane_mint` appended for uniqueness is
#      the part that MUST survive truncation intact, or two lanes with a
#      long, truncation-colliding PROJECT_ID prefix would mint identical
#      unit names. The head (project_id.role.issue) is truncated first;
#      the tail is re-appended verbatim.
_lane_unit_name() {
  local lane_id="$1" project role issue epoch rand4
  IFS=: read -r project role issue epoch rand4 <<<"$lane_id"
  local safe_project
  safe_project="$(printf '%s' "$project" | tr -c 'A-Za-z0-9:_.-' '-')"
  local tail=".${role}.${issue}.${epoch}.${rand4}"
  local budget=$(( 200 - 4 - ${#tail} ))   # 4 = strlen("adt-")
  [[ "$budget" -lt 1 ]] && budget=1
  printf 'adt-%s%s' "${safe_project:0:$budget}" "$tail"
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

  # [Lane-GC PR-7 / INV-120] Probed ONCE, here, at mint — never re-probed at
  # kill time (design §4-C1: "recorded in BACKEND so kill-side never
  # re-guesses"). `_lane_backend` itself owns the (narrowing-only)
  # `ADT_LANE_BACKEND_OVERRIDE` test seam — see its own doc comment; this
  # call site does NOT re-implement any override logic, so a real linger/
  # bus/probe check is never skippable from here.
  local backend unit_name="-"
  backend="$(_lane_backend)"
  [[ "$backend" == "systemd-scope" ]] && unit_name="$(_lane_unit_name "$lane_id")"

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
    printf 'BACKEND=%s\n' "$backend"
    printf 'UNIT=%s\n' "$unit_name"
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

# _lane_cgroup_path <unit_scope> — echo the cgroupfs directory for a loaded
# scope unit, or nothing + rc 1 when the unit isn't loaded / has no
# ControlGroup. Resolved via the unit's OWN reported `ControlGroup` property
# rather than hand-assembling `user.slice/user-<uid>.slice/.../<unit>.scope`
# — the design's §4-C7 mentions both forms; ControlGroup is the portable
# source of truth (correct regardless of which slice systemd actually placed
# the scope under, including future systemd versions or a delegated slice).
_lane_cgroup_path() {
  local unit_scope="$1" xdg="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local cgrel
  # [Lane-GC PR-7 review round-1, P1-2] Bounded — see `_lane_bounded`'s own
  # header comment (a wedged bus must never hang `lane_kill` while it holds
  # `reap.lock`).
  cgrel="$(XDG_RUNTIME_DIR="$xdg" _lane_bounded 10 systemctl --user show -p ControlGroup --value "$unit_scope" 2>/dev/null)" || return 1
  [[ -n "$cgrel" ]] || return 1
  # _LANE_CGROUP_ROOT_OVERRIDE — test-only seam (never read anywhere else,
  # never documented to operators). Real cgroupfs is mounted at a fixed
  # kernel-controlled path (`/sys/fs/cgroup`) that an unprivileged test
  # cannot remount or fake in-place; this lets a unit test point at a
  # PATH-shim-controlled fixture directory tree instead while exercising
  # the exact same relative-path-join logic production uses.
  # `${VAR-default}` (no colon) — substitutes the default only when UNSET,
  # never when set-but-empty. A test needs the empty string to be a valid,
  # deliberate override value (see the seam's own comment above), which the
  # `:-` form would incorrectly treat as "unset" and silently ignore.
  printf '%s%s\n' "${_LANE_CGROUP_ROOT_OVERRIDE-/sys/fs/cgroup}" "$cgrel"
}

# _lane_cgroup_empty <cgroup_dir> — true iff <cgroup_dir>/cgroup.procs has no
# member pids (or the path/file is already gone — torn-down cgroup, treated
# as empty). Deliberately reads the FILE CONTENT rather than gating on
# `[[ -s ]]` — empirically verified on this series' own dev box: cgroupfs's
# `cgroup.procs` reports `stat`-size 0 EVEN WHILE listing a live member pid
# (the exact same procfs-style quirk design §7 platform:F5 already
# documents for `/proc/PID/environ`, confirmed here to extend to cgroupfs
# pseudo-files too) — a `-s`-gated check would misclassify a POPULATED
# cgroup as already-empty and skip straight to declaring victory without
# ever escalating to `cgroup.kill`.
_lane_cgroup_empty() {
  local cgdir="$1"
  [[ -f "${cgdir}/cgroup.procs" ]] || return 0
  local procs
  procs="$(cat "${cgdir}/cgroup.procs" 2>/dev/null)"
  [[ -z "$procs" ]]
}

# _lane_scope_kill <lane_dir> [grace_secs] — the cgroup fast path (design
# §4-C4 choreography row 3, §4-C7; INV-120). A silent no-op (rc 0, no side
# effect) unless the LANE'S OWN recorded BACKEND is `systemd-scope` — this
# function never re-probes the host, it only acts on what `lane_install`
# already decided once at mint (kill-side never re-guesses, design §4-C1).
#
# Sequence, TERM-first per INV-106/120 (so a compliant member still exits
# 143 before any KILL-class escalation):
#   1. `systemctl --user kill -s TERM <unit>.scope` (graceful).
#   2. Poll `cgroup.procs` for emptiness across the grace window.
#   3. `echo 1 > cgroup.kill` (kernel >= 5.14, atomic, includes fork races —
#      feature-detected; a pre-5.14 kernel without the file falls back to a
#      best-effort per-pid KILL loop over whatever cgroup.procs still lists).
#
# ANY failure at ANY step (unit not loaded — e.g. it already exited and
# `--collect` cleaned it up, cgroup path unresolvable, cgroup.kill absent)
# degrades silently to a plain return. This is safe specifically BECAUSE the
# caller (`lane_kill`, below) unconditionally ALSO runs the pgid escalation
# afterward regardless of this function's outcome (design's own "defense in
# depth" framing) — the scope's own leader process is ALSO always
# pgid-recorded by `lane_spawn`, so the portable pgid path alone still
# reaches at least the leader even when this entire function no-ops.
_lane_scope_kill() {
  local lane_dir="$1" grace="${2:-10}"
  local backend unit
  backend="$(lane_get "$lane_dir" BACKEND 2>/dev/null)" || return 0
  [[ "$backend" == "systemd-scope" ]] || return 0
  unit="$(lane_get "$lane_dir" UNIT 2>/dev/null)" || return 0
  [[ -n "$unit" && "$unit" != "-" ]] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0

  local xdg="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local unit_scope="${unit}.scope"

  # [Lane-GC PR-7 review round-1, P1-2] Bounded — a wedged user bus must
  # never hang `lane_kill` while it holds `reap.lock`, starving the
  # unconditional pgid escalation that must always run afterward (this
  # function's own "defense in depth" contract, its caller's own comment).
  XDG_RUNTIME_DIR="$xdg" _lane_bounded 10 systemctl --user kill -s TERM "$unit_scope" >/dev/null 2>&1 || true

  local cgdir
  cgdir="$(_lane_cgroup_path "$unit_scope")" || return 0
  [[ -n "$cgdir" && -d "$cgdir" ]] || return 0

  local i
  for ((i = 0; i < grace; i++)); do
    _lane_cgroup_empty "$cgdir" && return 0
    sleep 1
  done

  if [[ -f "${cgdir}/cgroup.kill" ]]; then
    echo 1 > "${cgdir}/cgroup.kill" 2>/dev/null || true
  else
    # Pre-5.14 kernel — no cgroup.kill feature file. Best-effort per-pid
    # KILL over whatever is still listed; never fails the caller.
    local cp
    while read -r cp; do
      [[ "$cp" =~ ^[0-9]+$ ]] || continue
      kill -KILL "$cp" 2>/dev/null || true
    done < "${cgdir}/cgroup.procs" 2>/dev/null || true
  fi
  return 0
}

# lane_kill <lane_dir> [grace_secs] — registry-authoritative TERM→grace→KILL
# over every DISTINCT pgid recorded in <lane_dir>/pgids, PLUS (design §4-C7;
# INV-120) the cgroup fast path when this lane's own recorded BACKEND is
# `systemd-scope` — see `_lane_scope_kill` immediately above. The scope path
# runs FIRST but is never the only mechanism: the pgid escalation below
# ALWAYS also runs afterward, unconditionally, regardless of whether the
# scope path found anything to do (defense in depth — a scope kill that
# silently no-ops for any reason, e.g. an already-collected transient unit,
# must never leave a still-registered pgid unreaped).
#
# Does NOT consult lane_probe — callers (the kill_stale_wrapper delegate,
# guardian, GC) decide liveness first; this function only performs the
# escalation once a caller has decided a lane's residue should die.
# Idempotent: an already-empty/missing pgids file (and, for the scope path,
# an already-gone unit) is a clean no-op.
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

  local lock_fd=""
  if [[ -f "${lane_dir}/reap.lock" ]]; then
    exec {lock_fd}>>"${lane_dir}/reap.lock" 2>/dev/null || lock_fd=""
    [[ -n "$lock_fd" ]] && { flock -w 10 "$lock_fd" 2>/dev/null || true; }
  fi

  _lane_scope_kill "$lane_dir" "$grace"

  if [[ ! -f "$pgids_file" ]]; then
    [[ -n "$lock_fd" ]] && exec {lock_fd}>&-
    return 0
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
      # [Lane-GC PR-5 / INV-118] FD hygiene: close an inherited guardian
      # write-fd before the bounded (≤grace-second) escalation body — same
      # accepted-degradation posture as the sigterm-trap escalators in
      # lib-agent.sh (a forgotten close here only defers EOF by the grace
      # window, never blocks it indefinitely).
      "${_lk_setsid[@]}" bash -c '[[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-; _kill_group_escalate "$1" "$2"' _ "$pg" "$grace" &
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
  # [Lane-GC PR-5 / INV-118] FD hygiene: close an inherited guardian
  # write-fd before running the wrapped call — `_bounded_call` backs every
  # teardown-path network call in cleanup() (up to 60s each), so a
  # forgotten close here would be the single biggest source of deferred
  # guardian EOF on a wrapper crash mid-network-call. Wrapped in an
  # (unnamed) subshell rather than `exec`'d directly — the wrapped "$@" is
  # a bash FUNCTION (itp_post_comment, etc.), never a real binary, so it
  # cannot itself be exec'd in place the way lib-agent.sh's CLI spawn can;
  # `$!`/rc/stdout/stderr are all unaffected by the extra subshell layer
  # (verified empirically).
  (
    [[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-
    "$@"
  ) > "$outfile" 2> "$errfile" &
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

# lane_spawn <lane_dir> <role> -- <cmd...> — backend-dispatching spawn.
# Reads the lane's OWN recorded BACKEND (written once by `lane_install` at
# mint — this function never re-probes, per design §4-C1 "recorded in
# BACKEND so kill-side never re-guesses"; the same "decide once" contract
# applies spawn-side, not just kill-side) and either:
#   - `systemd-scope`: `systemd-run --user --scope --collect --quiet --unit
#     <UNIT> -p TasksMax=... [-p MemoryMax=...] -- setsid <cmd...>` (design
#     §4-C7). cgroup membership survives re-setsid — the structural defeat
#     of RC3 that is this whole PR's point (empirically verified on this
#     series' own dev box: a `setsid`-escaping grandchild inside the scope
#     stayed in `cgroup.procs` and was reaped by `cgroup.kill`).
#   - `pgid` (default; also the silent fallback for every missing
#     prerequisite, and the ONLY backend this file shipped pre-PR-7): plain
#     `setsid <cmd...>`.
# EITHER WAY, the resulting PGID is recorded into <lane_dir>/pgids via
# `lane_record_pgid` — the registry stays the kill-side's authoritative
# join key regardless of backend (design §4-C7 "backend is recorded
# per-lane" — that's the UNIT field; the pgids file is unconditional so a
# scope lane whose systemd/cgroup path degrades at kill time still has a
# working pgid fallback, per row 3 of the kill choreography table).
#
# `$!` from a backgrounded `systemd-run --user --scope ... -- setsid <cmd>`
# resolves to the scope's own leader PID, which IS also its PGID (setsid
# puts it in a fresh session/group) — verified empirically on this box: no
# separate "extract the scope's leader pid" step is needed beyond the same
# `$!` capture the pgid branch already does.
#
# `--` is a REQUIRED separator (keeps <role> unambiguous from the command's
# own argv, which may itself contain `--`).
#
# This is a convenience wrapper for NEW spawn sites this PR adds (E2E/smoke
# lane callers may prefer it); it deliberately does NOT replace
# `_run_with_timeout` (lib-agent.sh) — that primitive already owns the agent
# spawn path (env-scrub ordering, launcher-argv, AGENT_PID_FILE) and gets its
# PGID recorded into the lane via a direct `lane_record_pgid` call at its own
# call site instead (see autonomous-dev.sh/autonomous-review.sh). A future
# PR may teach `_run_with_timeout` the same backend dispatch; out of scope
# here (the design's own §9 PR-7 scope is `lane_spawn`/`lane_kill`/guardian/
# GC, not the agent-CLI spawn path).
# [Lane-GC PR-7 review round-1, P2-2] `systemd-run`'s OWN registration can
# fail for reasons that have NOTHING to do with the payload (an unacceptable
# unit name — empirically verified even after this PR's own `_lane_unit_name`
# sanitizer, e.g. a not-yet-anticipated systemd version's stricter rules; a
# bus that wedged/died between mint-time probe and spawn-time; a transient
# resource limit). When that happens, `systemd-run` exits non-zero having
# NEVER exec'd the payload at all — empirically verified: no process bearing
# the payload's argv exists anywhere on the host afterward. Silently
# swallowing that failure would mean "the agent/E2E/smoke lane this call was
# supposed to run… never ran, with no error surfaced" — the single worst
# possible outcome for a "never load-bearing" enhancement (design principle
# 8). `lane_spawn` therefore detects a REGISTRATION failure specifically
# (vs. the PAYLOAD's own exit code on a successful registration) and retries
# via the portable pgid path instead of losing the spawn.
#
# Discriminator (empirically verified, both directions, on this box):
# `systemd-run`'s OWN failure diagnostics are ALWAYS emitted to stderr with
# an English `Failed to ...` prefix, REGARDLESS of `--quiet` (`--quiet`
# suppresses its INFORMATIONAL "Running as unit..." line, never its ERROR
# path) — and a payload that runs at all (even one that itself exits
# non-zero, even one that itself writes to stderr) produces NO such line
# from systemd-run itself (the payload's own stderr is passed through
# unmodified alongside it, which is why the check is anchored to the START
# of a line, not a bare substring match, to minimize — though, being a
# translated CLI message, not eliminate — collision with payload output
# that happens to start the same way; see the residual note in the design
# doc).
#
# IMPLEMENTATION NOTE (why this logic lives inline in `lane_spawn`, not in
# a separate helper function backgrounded with `&`): backgrounding a
# FUNCTION CALL (`some_func ... &`) makes `$!` resolve to the subshell that
# runs the function body, never to a process spawned INSIDE that function —
# verified empirically while writing this fix. `lane_spawn`'s entire
# contract is that `$!` after the background spawn IS the payload's own
# pgid (systemd-run's own scope leader, in the scope-backend case); wrapping
# the systemd-run invocation in a helper and backgrounding the HELPER would
# silently break that contract (the recorded "pgid" would be the wrapper
# subshell's pid, in the WRONG process group, and `lane_kill`'s group-form
# signals would never reach the real payload). `systemd-run` is therefore
# backgrounded DIRECTLY here, exactly as the pgid branch already does.
lane_spawn() {
  local lane_dir="$1" role="$2"
  shift 2
  [[ "${1:-}" == "--" ]] && shift

  local backend="pgid" unit_name="-"
  if [[ -d "$lane_dir" ]]; then
    backend="$(lane_get "$lane_dir" BACKEND 2>/dev/null)" || backend="pgid"
    unit_name="$(lane_get "$lane_dir" UNIT 2>/dev/null)" || unit_name="-"
  fi

  local pgid used_scope=false errfile="" _spawn_startmark=""
  if [[ "$backend" == "systemd-scope" && "$unit_name" != "-" ]] && command -v systemd-run >/dev/null 2>&1; then
    local xdg="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    local setsid_launcher=()
    command -v setsid >/dev/null 2>&1 && setsid_launcher=(setsid)
    local mem_opt=()
    [[ -n "${LANE_MEMORY_MAX:-}" ]] && mem_opt=(-p "MemoryMax=${LANE_MEMORY_MAX}")
    used_scope=true
    errfile="$(mktemp 2>/dev/null)" || errfile=""
    if [[ -n "$errfile" ]]; then
      # Start marker (review round-2 [P1]): the stderr `^Failed to ` prefix
      # alone cannot distinguish "systemd-run refused registration, payload
      # NEVER ran" from "payload ran, wrote a line that happens to start
      # with `Failed to `, and exited non-zero" — the fds are merged, so a
      # payload like that would be DOUBLE-RUN by the pgid retry below. The
      # payload's provable first act is therefore touching a marker file
      # (`: > marker; exec real-command` — the exec keeps pid/pgid/argv
      # identical after the one-instruction prelude): marker present ⇒ the
      # payload started ⇒ NEVER retry, regardless of rc or stderr content.
      _spawn_startmark="${errfile}.ran"
      XDG_RUNTIME_DIR="$xdg" systemd-run --user --scope --collect --quiet \
        --unit "$unit_name" -p "TasksMax=${LANE_TASKS_MAX:-512}" "${mem_opt[@]}" \
        -- "${setsid_launcher[@]}" bash -c ': > "$1"; shift; exec "$@"' _ "$_spawn_startmark" "$@" 2>"$errfile" &
    else
      # tmpfile creation itself failed (e.g. /tmp unwritable) — degrade to
      # an unwrapped call; the registration-failure discriminator below is
      # skipped for this attempt (a registration failure and a payload
      # failure both surface as a plain non-zero rc with no way to tell
      # them apart), matching `_bounded_call`'s own documented degraded
      # posture for the identical tmpfile-failure case.
      XDG_RUNTIME_DIR="$xdg" systemd-run --user --scope --collect --quiet \
        --unit "$unit_name" -p "TasksMax=${LANE_TASKS_MAX:-512}" "${mem_opt[@]}" \
        -- "${setsid_launcher[@]}" "$@" &
    fi
    pgid=$!
  else
    local launcher=()
    command -v setsid >/dev/null 2>&1 && launcher=(setsid)
    "${launcher[@]}" "$@" &
    pgid=$!
  fi

  lane_record_pgid "$lane_dir" "$pgid" "$role"
  # `|| rc=$?` — never a bare wait: under a caller's `set -e` a non-zero
  # payload exit would otherwise unwind the CALLING shell right here,
  # skipping both the registration-fallback discriminator and the tmpfile
  # cleanup below (review round-2 [P2]).
  local rc=0
  wait "$pgid" || rc=$?

  if [[ "$used_scope" == true && -n "$errfile" ]]; then
    # Registration failure ⇔ rc≠0 ∧ systemd-run's `^Failed to ` diagnostic
    # present ∧ the payload's start-marker ABSENT (review round-2 [P1]: the
    # marker is the authoritative "did the payload ever start" signal — a
    # payload that started, printed its own `Failed to …` line, and exited
    # non-zero has the marker and is NEVER retried; only a spawn whose
    # payload provably never began is re-run via pgid).
    if [[ "$rc" -ne 0 && ! -e "$_spawn_startmark" ]] && grep -qm1 '^Failed to ' "$errfile" 2>/dev/null; then
      cat "$errfile" >&2
      rm -f "$errfile" "$_spawn_startmark" 2>/dev/null
      # Retry via a real pgid spawn so the caller's command still executes —
      # the ONLY case where `lane_spawn` runs the command more than once.
      # `lane_record_pgid` is called again for the NEW pgid — the stale
      # scope-attempt pgid is harmless (lane_kill against a dead pgid is a
      # documented no-op).
      _lane_warn "systemd-scope spawn registration failed for unit '$unit_name' — payload never ran; falling back to a pgid spawn now"
      local launcher=()
      command -v setsid >/dev/null 2>&1 && launcher=(setsid)
      "${launcher[@]}" "$@" &
      pgid=$!
      lane_record_pgid "$lane_dir" "$pgid" "$role"
      rc=0
      wait "$pgid" || rc=$?
    else
      cat "$errfile" >&2
      rm -f "$errfile" "${_spawn_startmark:-}" 2>/dev/null
    fi
  fi

  return "$rc"
}
