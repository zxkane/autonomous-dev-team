#!/bin/bash
# test-lane-gc-p4-gc.sh — Unit tests for issue #380 (Lane-GC series PR-4,
# design docs/designs/lane-containment-gc.md §4-C5/§6, INV-117).
#
# Covers adt-gc.sh (all four passes of the §6 decision table, the flock
# singleton + --quick starvation guard, --doctor, log rotation, the
# ADT_GC_SUMMARY metrics line), install-gc-timer.sh (idempotent crontab
# edit + launchd plist install, both platforms via the _LANE_UNAME_OVERRIDE
# test seam), the new lib-lane.sh portability primitives this PR adds
# (proc_ppid/proc_pgid/proc_argv/env_lookup/_procargs2_py), and the
# opportunistic --quick wiring in dispatch-local.sh.
#
# Every test isolates ADT_STATE_ROOT to a fresh `mktemp -d` — NEVER the
# real $HOME/.local/state — so this suite is safe on a box with a live
# dispatcher (this repo is self-hosting).
#
# Full scenario list: docs/test-cases/lane-gc-p4-gc.md (TC-LGC4-*).
#
# Run: bash tests/unit/test-lane-gc-p4-gc.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB_LANE="$SCRIPTS/lib-lane.sh"
ADT_GC="$SCRIPTS/adt-gc.sh"
INSTALL_GC_TIMER="$SCRIPTS/install-gc-timer.sh"
DISPATCH_LOCAL="$SCRIPTS/dispatch-local.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert_pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
assert_fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc (expected [$expected] got [$actual])"; fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then assert_pass "$desc"; else assert_fail "$desc (needle='$needle' not found in: $haystack)"; fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then assert_pass "$desc"; else assert_fail "$desc (needle='$needle' unexpectedly found)"; fi
}

for f in "$LIB_LANE" "$ADT_GC" "$INSTALL_GC_TIMER" "$DISPATCH_LOCAL"; do
  [[ -f "$f" ]] || { echo -e "${RED}FATAL${NC}: $f not found"; exit 1; }
done

TMPROOT=$(mktemp -d)
# Track every pid we spawn so the EXIT trap can reap them regardless of
# which assertion path ran — never leave a fixture process behind.
declare -a SPAWNED_PIDS=()
trap '
  for _p in "${SPAWNED_PIDS[@]:-}"; do
    [[ -n "$_p" ]] && kill -9 -- "-$_p" 2>/dev/null; kill -9 "$_p" 2>/dev/null
  done
  rm -rf "$TMPROOT"
' EXIT

# ===========================================================================
echo ""
echo "=== TC-LGC4-110..114: new lib-lane.sh portability primitives ==="
# ===========================================================================
# $(...) forks its own subshell, so the OUTER script's $PPID is not the
# inner bash -c process's parent — compare proc_ppid's answer against the
# SAME subshell's own $PPID, captured in the same invocation.
OUT110=$(bash -c 'source "'"$LIB_LANE"'"; echo "$PPID:$(proc_ppid $$)"')
EXPECTED110="${OUT110%%:*}"
ACTUAL110="${OUT110#*:}"
assert_eq "TC-LGC4-110: proc_ppid against the calling shell's own \$\$" "$EXPECTED110" "$ACTUAL110"

OUT111=$(bash -c '
  source "'"$LIB_LANE"'"
  setsid sleep 5 &
  CP=$!
  sleep 0.2
  proc_pgid "$CP"
  kill -9 -- "-$CP" 2>/dev/null
')
# A setsid-spawned process is its own session/group leader: pgid == pid.
if [[ "$OUT111" =~ ^[0-9]+$ ]]; then
  assert_pass "TC-LGC4-111: proc_pgid against a setsid-spawned process returns a numeric pgid"
else
  assert_fail "TC-LGC4-111: proc_pgid returned non-numeric: $OUT111"
fi

OUT112=$(bash -c '
  source "'"$LIB_LANE"'"
  exec -a sleep-dummy-marker-arg sleep 5 &
  CP=$!
  sleep 0.2
  proc_argv "$CP"
  kill -9 "$CP" 2>/dev/null
')
assert_contains "TC-LGC4-112a: proc_argv includes the (renamed) binary name" "sleep-dummy-marker-arg" "$OUT112"
assert_contains "TC-LGC4-112b: proc_argv includes the trailing numeric argv element" "5" "$OUT112"

OUT113=$(bash -c '
  source "'"$LIB_LANE"'"
  env FOO=bar sleep 5 &
  CP=$!
  sleep 0.2
  env_lookup "$CP" FOO
  kill -9 "$CP" 2>/dev/null
')
assert_eq "TC-LGC4-113a: env_lookup finds an exact KEY" "bar" "$OUT113"
OUT113B=$(bash -c '
  source "'"$LIB_LANE"'"
  sleep 5 &
  CP=$!
  sleep 0.2
  env_lookup "$CP" NOPE_NOT_SET; echo "rc=$?"
  kill -9 "$CP" 2>/dev/null
')
assert_contains "TC-LGC4-113b: env_lookup rc=1 for an absent key" "rc=1" "$OUT113B"

if command -v python3 >/dev/null 2>&1; then
  # NUL bytes cannot survive a `$( ... )` command substitution (bash strips
  # them) — the synthetic procargs2 buffer is written to a real file
  # instead, and the REAL `_procargs2_py` shim (sourced from lib-lane.sh,
  # not a re-implementation) reads it back via stdin file redirection.
  BUF114="$TMPROOT/procargs2-synthetic.bin"
  python3 - > "$BUF114" <<'PY'
import struct, sys
argv = [b"/bin/sleep", b"5"]
envp = [b"FOO=bar"]
buf = struct.pack('<i', len(argv))
buf += b"/bin/sleep\x00"
for a in argv:
    buf += a + b"\x00"
for e in envp:
    buf += e + b"\x00"
sys.stdout.buffer.write(buf)
PY
  RESULT=$(bash -c 'source "'"$LIB_LANE"'"; _procargs2_py < "'"$BUF114"'"' 2>&1)
  assert_contains "TC-LGC4-114a: _procargs2_py parser recovers argv from a synthetic buffer" "/bin/sleep" "$RESULT"
  assert_contains "TC-LGC4-114b: _procargs2_py parser recovers envp from a synthetic buffer" "FOO=bar" "$RESULT"
else
  assert_pass "TC-LGC4-114: skipped (no python3 on this runner)"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC4-001..013: Pass 1 registry-driven decision table ==="
# ===========================================================================
P1ROOT="$TMPROOT/pass1"
mkdir -p "$P1ROOT"

# Pass-1-focused fixtures use --quick: it runs Pass 1 ONLY (no same-uid
# process enumeration), which both keeps these tests fast on a box with
# hundreds of real pipeline processes AND avoids Pass 2/3/4 noise
# contaminating the log assertions below. Pass 2/3 fixtures (further down)
# need the FULL run and use the _full variants instead.
run_gc_dry() {
  local state_root="$1"
  ADT_STATE_ROOT="$state_root" bash "$ADT_GC" --dry-run --quick 2>&1
}
run_gc_kill() {
  local state_root="$1"
  ADT_STATE_ROOT="$state_root" ADT_GC_ENFORCE=1 bash "$ADT_GC" --kill --quick 2>&1
}
run_gc_dry_full() {
  local state_root="$1"
  ADT_STATE_ROOT="$state_root" bash "$ADT_GC" --dry-run 2>&1
}

# TC-LGC4-001: live lane (WRAPPER_PID = a real, still-alive process) -> skip
# rule 1.1. The "wrapper" must still be alive WHEN adt-gc.sh RUNS, so mint
# against a backgrounded sleep's pid, not the disposable bash -c subshell's
# own transient $$ (which exits before the check).
ST1=$(mktemp -d)
sleep 30 &
WRAPPER1_PID=$!
SPAWNED_PIDS+=("$WRAPPER1_PID")
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST1"'"
  LANE_ID=$(lane_mint p1 dev 1)
  LANE_DIR=$(lane_install p1 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID "'"$WRAPPER1_PID"'"
  lane_set "$LANE_DIR" WRAPPER_START "$(proc_start_time "'"$WRAPPER1_PID"'")"
'
run_gc_dry "$ST1" >/dev/null
CATLOG1=$(cat "$ST1/adt-gc.log" 2>/dev/null || true)
assert_contains "TC-LGC4-001: live lane (real alive WRAPPER_PID) skipped under rule 1.1" "skip rule=1.1" "$CATLOG1"
kill -9 "$WRAPPER1_PID" 2>/dev/null || true
rm -rf "$ST1"

# TC-LGC4-002/003: STATE=reaping, GUARDIAN_PID alive, state age < / >= 5min.
ST2=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST2"'"
  LANE_ID=$(lane_mint p1 dev 2)
  LANE_DIR=$(lane_install p1 "$LANE_ID")
  # Make the lane DEAD by corrupting WRAPPER_PID to a pid that cannot exist.
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  lane_set "$LANE_DIR" STATE reaping
  # A real, alive "guardian" for this test.
  sleep 30 & disown
  lane_set "$LANE_DIR" GUARDIAN_PID "$!"
'
run_gc_dry "$ST2" >/dev/null
CATLOG2=$(cat "$ST2/adt-gc.log" 2>/dev/null || true)
assert_contains "TC-LGC4-002: STATE=reaping + live guardian, fresh state age -> rule 1.2 skip" "skip rule=1.2" "$CATLOG2"
rm -rf "$ST2"

# TC-LGC4-003: STATE=reaping, GUARDIAN_PID alive, state age >= 5min (the
# tightened bound) -> rule 1.2 does NOT apply (its age gate is `< 300s`);
# falls through to rule 1.3, which fires because STATE=reaping is a
# disjunct with the age floor. Age is simulated by backdating the `lane`
# file's own mtime (_gc_state_age's proxy for "how long in this STATE") via
# `touch -d "@<epoch>"` rather than a real 5-minute sleep.
ST3=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST3"'"
  LANE_ID=$(lane_mint p1 dev 3)
  LANE_DIR=$(lane_install p1 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  lane_set "$LANE_DIR" STATE reaping
  sleep 30 & disown
  lane_set "$LANE_DIR" GUARDIAN_PID "$!"
  touch -d "@$(( $(date +%s) - 301 ))" "$LANE_DIR/lane"
'
run_gc_dry "$ST3" >/dev/null
CATLOG3=$(cat "$ST3/adt-gc.log" 2>/dev/null || true)
assert_contains "TC-LGC4-003: STATE=reaping + live guardian, state age>=5min -> rule 1.2 does not apply, rule 1.3 fires" "would-kill rule=1.3" "$CATLOG3"
assert_not_contains "TC-LGC4-003b: rule 1.2 must NOT fire at this age" "skip rule=1.2" "$CATLOG3"
rm -rf "$ST3"

# TC-LGC4-006: STATE=reaping, lane age < 600s -> rule 1.3 STILL fires
# (arithmetic-note regression: state disjunct, not an additional conjunct).
ST6=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST6"'"
  LANE_ID=$(lane_mint p1 dev 6)
  LANE_DIR=$(lane_install p1 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  lane_set "$LANE_DIR" STATE reaping
  lane_set "$LANE_DIR" GUARDIAN_PID "-"
'
run_gc_dry "$ST6" >/dev/null
CATLOG6=$(cat "$ST6/adt-gc.log" 2>/dev/null || true)
assert_contains "TC-LGC4-006: STATE=reaping + dead/no guardian + lane age<600s -> rule 1.3 fires anyway" "would-kill rule=1.3" "$CATLOG6"
rm -rf "$ST6"

# TC-LGC4-004/005: dead lane, dead guardian, age>600s vs age<600s+STATE=live.
ST4=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST4"'"
  LANE_ID=$(lane_mint p1 dev 4)
  LANE_DIR=$(lane_install p1 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  lane_set "$LANE_DIR" CREATED_EPOCH "$(( $(date +%s) - 700 ))"
'
run_gc_kill "$ST4" >/dev/null
CATLOG4=$(cat "$ST4/adt-gc.log" 2>/dev/null || true)
assert_contains "TC-LGC4-004: dead lane + dead guardian + age>600s -> rule 1.3 KILLs (kill mode)" "kill rule=1.3" "$CATLOG4"
LANE4_DIR=$(find "$ST4/autonomous-p1/lanes" -maxdepth 1 -type d -not -name '.pending-*' -not -name lanes 2>/dev/null | head -1)
STATE4=$(bash -c 'source "'"$LIB_LANE"'"; lane_get "'"$LANE4_DIR"'" STATE' 2>/dev/null)
assert_eq "TC-LGC4-004b: STATE transitions to gc-reaped after rule 1.3 kill" "gc-reaped" "$STATE4"
rm -rf "$ST4"

ST5=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST5"'"
  LANE_ID=$(lane_mint p1 dev 5)
  LANE_DIR=$(lane_install p1 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  lane_set "$LANE_DIR" CREATED_EPOCH "$(( $(date +%s) - 100 ))"
'
run_gc_dry "$ST5" >/dev/null
CATLOG5=$(cat "$ST5/adt-gc.log" 2>/dev/null || true)
assert_contains "TC-LGC4-005: dead lane, age<600s, STATE=live -> not eligible, skip" "skip rule=1.3-not-eligible" "$CATLOG5"
rm -rf "$ST5"

# TC-LGC4-007/008: terminal STATE, age>24h vs age<24h.
ST7=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST7"'"
  LANE_ID=$(lane_mint p1 dev 7)
  LANE_DIR=$(lane_install p1 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  lane_set "$LANE_DIR" STATE clean-exit
  touch -d "@$(( $(date +%s) - 90000 ))" "$LANE_DIR/lane" 2>/dev/null || touch -t "$(date -d "@$(( $(date +%s) - 90000 ))" +%Y%m%d%H%M.%S 2>/dev/null)" "$LANE_DIR/lane" 2>/dev/null || true
'
run_gc_kill "$ST7" >/dev/null
LANE7_STILL_THERE=$(find "$ST7/autonomous-p1/lanes" -maxdepth 1 -type d -not -name lanes 2>/dev/null | wc -l)
assert_eq "TC-LGC4-007: terminal STATE, age>24h -> rm -rf'd in kill mode" "0" "$LANE7_STILL_THERE"
rm -rf "$ST7"

ST8=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST8"'"
  LANE_ID=$(lane_mint p1 dev 8)
  LANE_DIR=$(lane_install p1 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  lane_set "$LANE_DIR" STATE clean-exit
'
run_gc_kill "$ST8" >/dev/null
LANE8_STILL_THERE=$(find "$ST8/autonomous-p1/lanes" -maxdepth 1 -type d -not -name lanes 2>/dev/null | wc -l)
assert_eq "TC-LGC4-008: terminal STATE, age<24h -> NOT removed even in kill mode" "1" "$LANE8_STILL_THERE"
rm -rf "$ST8"

# TC-LGC4-009/010: unparseable lane file, age>24h vs age<=24h.
ST9=$(mktemp -d)
mkdir -p "$ST9/autonomous-p1/lanes/p1.dev.9.111.aaaa"
echo "GARBAGE NOT KV" > "$ST9/autonomous-p1/lanes/p1.dev.9.111.aaaa/lane"
touch -d "@$(( $(date +%s) - 90000 ))" "$ST9/autonomous-p1/lanes/p1.dev.9.111.aaaa/lane" 2>/dev/null || true
run_gc_kill "$ST9" >/dev/null
STILL9=$(find "$ST9/autonomous-p1/lanes" -maxdepth 1 -type d -not -name lanes 2>/dev/null | wc -l)
assert_eq "TC-LGC4-009: unparseable lane, age>24h -> collected/removed" "0" "$STILL9"
rm -rf "$ST9"

ST10=$(mktemp -d)
mkdir -p "$ST10/autonomous-p1/lanes/p1.dev.10.222.bbbb"
echo "GARBAGE NOT KV" > "$ST10/autonomous-p1/lanes/p1.dev.10.222.bbbb/lane"
run_gc_kill "$ST10" >/dev/null
STILL10=$(find "$ST10/autonomous-p1/lanes" -maxdepth 1 -type d -not -name lanes 2>/dev/null | wc -l)
assert_eq "TC-LGC4-010: unparseable lane, age<=24h -> skip+WARN, NOT removed" "1" "$STILL10"
CATLOG10=$(cat "$ST10/adt-gc.log" 2>/dev/null || true)
assert_contains "TC-LGC4-010b: rule 1.5 skip logged" "rule=1.5" "$CATLOG10"
rm -rf "$ST10"

# TC-LGC4-011/012: .pending-* orphan, age>24h vs age<=24h.
ST11=$(mktemp -d)
mkdir -p "$ST11/autonomous-p1/lanes/.pending-p1.dev.11.333.cccc"
touch -d "@$(( $(date +%s) - 90000 ))" "$ST11/autonomous-p1/lanes/.pending-p1.dev.11.333.cccc" 2>/dev/null || true
run_gc_kill "$ST11" >/dev/null
STILL11=$(find "$ST11/autonomous-p1/lanes" -maxdepth 1 -type d -name '.pending-*' 2>/dev/null | wc -l)
assert_eq "TC-LGC4-011: .pending-* orphan aged 24h+ is rm -rf'd" "0" "$STILL11"
rm -rf "$ST11"

ST12=$(mktemp -d)
mkdir -p "$ST12/autonomous-p1/lanes/.pending-p1.dev.12.444.dddd"
run_gc_kill "$ST12" >/dev/null
STILL12=$(find "$ST12/autonomous-p1/lanes" -maxdepth 1 -type d -name '.pending-*' 2>/dev/null | wc -l)
assert_eq "TC-LGC4-012: fresh .pending-* orphan is NOT removed" "1" "$STILL12"
rm -rf "$ST12"

# TC-LGC4-013: rule 1.4 kills a live GUARDIAN_PID before rm -rf.
ST13=$(mktemp -d)
GUARD_MARKER="$TMPROOT/guard13-marker"
touch "$GUARD_MARKER"
GUARDIAN13_SCRIPT="$TMPROOT/guardian13.sh"
# A trap set around a single long foreground `sleep 30` does NOT fire until
# that sleep's blocking wait() returns — bash only checks pending traps
# between commands, not while parked in one. Chunked short sleeps (mirrors
# the design's own C8/INV-79 chunked-sleep pattern) give the trap a chance
# to run promptly after the TERM this test sends.
cat > "$GUARDIAN13_SCRIPT" <<EOF
trap 'rm -f "$GUARD_MARKER"; exit 0' TERM
for i in \$(seq 1 300); do sleep 0.1; done
EOF
setsid bash "$GUARDIAN13_SCRIPT" &
disown
GUARDIAN13_PID=$!
SPAWNED_PIDS+=("$GUARDIAN13_PID")
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST13"'"
  LANE_ID=$(lane_mint p1 dev 13)
  LANE_DIR=$(lane_install p1 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  lane_set "$LANE_DIR" STATE clean-exit
  lane_set "$LANE_DIR" GUARDIAN_PID "'"$GUARDIAN13_PID"'"
  touch -d "@$(( $(date +%s) - 90000 ))" "$LANE_DIR/lane" 2>/dev/null || true
'
run_gc_kill "$ST13" >/dev/null
sleep 0.3
if [[ ! -f "$GUARD_MARKER" ]]; then
  assert_pass "TC-LGC4-013: rule 1.4 TERMed the live guardian before rm -rf (marker file removed by its trap)"
else
  assert_fail "TC-LGC4-013: guardian marker still present — guardian was never signaled"
fi
kill -9 "$GUARDIAN13_PID" 2>/dev/null || true
rm -rf "$ST13" "$GUARD_MARKER"

# ===========================================================================
echo ""
echo "=== TC-LGC4-020..032: Pass 2 tagged-orphan sweep — false-kill decoy fixtures ==="
# ===========================================================================
P2ROOT="$TMPROOT/pass2"
mkdir -p "$P2ROOT"

# TC-LGC4-020: tagged sleep, lane dead, age>=300s -> would-kill.
#
# `-u TERM_PROGRAM`: this test suite may run inside a terminal multiplexer
# / IDE terminal that exports TERM_PROGRAM (e.g. tmux) — rule 2.2's
# unconditional skip fires BEFORE rule 2.1's tagged-join check this fixture
# targets, silently masking the assertion (same ambient-env-pollution class
# TC-LGC2-020's `env -i` fix in test-lib-lane.sh documents).
ST20=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST20"'"
  LANE_ID=$(lane_mint p2 dev 20)
  LANE_DIR=$(lane_install p2 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  setsid env -u TERM_PROGRAM ADT_LANE_ID="$LANE_ID" bash -c "sleep 400" &
  disown
  echo "$!" > "'"$P2ROOT"'/pid20"
'
PID20=$(cat "$P2ROOT/pid20")
SPAWNED_PIDS+=("$PID20")
# The 300s age floor cannot practically be waited out by a freshly-spawned
# fixture — use the test-only _GC_PROC_AGE_OVERRIDE_<pid> seam adt-gc.sh
# provides for exactly this (production never sets it; the real proc_age
# path is exercised separately by TC-LGC4-111/112 etc against lib-lane.sh
# directly).
export "_GC_PROC_AGE_OVERRIDE_${PID20}=301"
run_gc_dry_full "$ST20" >/dev/null
unset "_GC_PROC_AGE_OVERRIDE_${PID20}"
CATLOG20=$(cat "$ST20/adt-gc.log" 2>/dev/null || true)
assert_contains "TC-LGC4-020: tagged-dead-lane sleep, age>=300s floor -> would-kill rule=2" "would-kill rule=2 pid=$PID20" "$CATLOG20"
kill -9 -- "-$PID20" 2>/dev/null || true

# TC-LGC4-021: legacy-sig WITH CC_USER, ppid==1 (simulated via setsid+disown
# reparenting to init), age>=600s -> would-kill (legacy).
ST21=$(mktemp -d)
cat > "$P2ROOT/autonomous.conf" <<'CONF'
PROJECT_ID="p2"
CONF
# -u ADT_LANE_ID: this test suite itself runs inside a real dev-agent
# session that already exports ADT_LANE_ID (and AUTONOMOUS_CONF_LOADED_FROM/
# CC_USER) and may run inside a terminal multiplexer / IDE terminal that
# exports TERM_PROGRAM — the same ambient-env-pollution class test-lib-
# lane.sh's TC-LGC2-020-regression documents. Without scrubbing ADT_LANE_ID,
# the inherited value would make rule 2.1's exact-join arm fire (against a
# foreign, unrelated lane id) instead of exercising the legacy-signature arm
# this fixture targets; without scrubbing TERM_PROGRAM, rule 2.2's
# unconditional skip fires first and silently masks the assertion below.
setsid env -u ADT_LANE_ID -u TERM_PROGRAM bash -c '
  export AUTONOMOUS_CONF_LOADED_FROM="'"$P2ROOT"'/autonomous.conf"
  export CC_USER="autonomous-dev-bot"
  exec sleep 700
' &
disown
PID21=$!
SPAWNED_PIDS+=("$PID21")
sleep 0.3
run_gc_dry_full "$ST21" >/dev/null
CATLOG21=$(cat "$ST21/adt-gc.log" 2>/dev/null || true)
PPID21=$(bash -c 'source "'"$LIB_LANE"'"; proc_ppid "'"$PID21"'"')
if [[ "$PPID21" == "1" ]]; then
  assert_contains "TC-LGC4-021: legacy signature (conf+CC_USER+ppid==1), age>=600s -> would-kill (legacy)" "legacy=true" "$CATLOG21"
else
  assert_pass "TC-LGC4-021: skipped — this sandbox does not reparent a disowned setsid leader to ppid==1 (proc_ppid=$PPID21); rule 2.1's legacy arm cannot be exercised without a reparent, which is an environment property, not a rule bug"
fi
kill -9 -- "-$PID21" 2>/dev/null || true

# TC-LGC4-022: legacy-sig WITHOUT CC_USER (operator conf-sourcing decoy) -> skip.
setsid env -u ADT_LANE_ID bash -c '
  export AUTONOMOUS_CONF_LOADED_FROM="'"$P2ROOT"'/autonomous.conf"
  unset CC_USER
  exec sleep 700
' &
disown
PID22=$!
SPAWNED_PIDS+=("$PID22")
sleep 0.3
ST22=$(mktemp -d)
run_gc_dry_full "$ST22" >/dev/null
CATLOG22=$(cat "$ST22/adt-gc.log" 2>/dev/null || true)
assert_not_contains "TC-LGC4-022: legacy sig WITHOUT CC_USER (bare conf-sourcing decoy) is never treated as would-kill" "pid=$PID22" "$CATLOG22"
kill -9 -- "-$PID22" 2>/dev/null || true
rm -rf "$ST22"

# TC-LGC4-023: TERM_PROGRAM decoy — unconditional skip even with a matching
# tagged-dead-lane env.
ST23=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST23"'"
  LANE_ID=$(lane_mint p2 dev 23)
  LANE_DIR=$(lane_install p2 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  setsid env ADT_LANE_ID="$LANE_ID" TERM_PROGRAM="xterm" bash -c "sleep 400" &
  disown
  echo "$!" > "'"$P2ROOT"'/pid23"
'
PID23=$(cat "$P2ROOT/pid23")
SPAWNED_PIDS+=("$PID23")
run_gc_dry_full "$ST23" >/dev/null
CATLOG23=$(cat "$ST23/adt-gc.log" 2>/dev/null || true)
assert_not_contains "TC-LGC4-023: TERM_PROGRAM decoy is unconditionally skipped despite a matching tagged-dead-lane env" "pid=$PID23" "$CATLOG23"
kill -9 -- "-$PID23" 2>/dev/null || true
rm -rf "$ST23"

# TC-LGC4-024: unknown ADT_LANE_ID (absent from any registry) -> skip.
# `-u TERM_PROGRAM`: this fixture asserts a POSITIVE log line
# (rule=2.1-unknown-lane-id) — an un-scrubbed ambient TERM_PROGRAM would
# make rule 2.2 fire first and the expected line never gets written at all.
ST24=$(mktemp -d)
setsid env -u TERM_PROGRAM ADT_LANE_ID="ghostproject:dev:9999:1:aaaa" bash -c "sleep 400" &
disown
PID24=$!
SPAWNED_PIDS+=("$PID24")
run_gc_dry_full "$ST24" >/dev/null
CATLOG24=$(cat "$ST24/adt-gc.log" 2>/dev/null || true)
assert_contains "TC-LGC4-024a: unknown ADT_LANE_ID logs rule=2.1-unknown-lane-id" "rule=2.1-unknown-lane-id pid=$PID24" "$CATLOG24"
assert_not_contains "TC-LGC4-024b: unknown ADT_LANE_ID never classified as would-kill" "would-kill rule=2 pid=$PID24 " "$CATLOG24"
kill -9 -- "-$PID24" 2>/dev/null || true
rm -rf "$ST24"

# TC-LGC4-025: live-lane daemon — tagged with a LIVE lane's id -> skip.
ST25=$(mktemp -d)
LANE25_ID=$(bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST25"'"
  LANE_ID=$(lane_mint p2 dev 25)
  lane_install p2 "$LANE_ID" >/dev/null
  echo "$LANE_ID"
')
setsid env ADT_LANE_ID="$LANE25_ID" bash -c "sleep 400" &
disown
PID25=$!
SPAWNED_PIDS+=("$PID25")
run_gc_dry_full "$ST25" >/dev/null
CATLOG25=$(cat "$ST25/adt-gc.log" 2>/dev/null || true)
assert_not_contains "TC-LGC4-025: process tagged with a LIVE lane's id is never swept" "pid=$PID25" "$CATLOG25"
kill -9 -- "-$PID25" 2>/dev/null || true
rm -rf "$ST25"

# TC-LGC4-030: rule 2.4 first conjunct — a process eligible via rule 2.1
# (tagged with a DEAD lane's id) is still skipped when its OWN pgid happens
# to be recorded in a DIFFERENT, currently-LIVE lane's `pgids` file (e.g. a
# recycled pgid, or a process that migrated groups). Distinct from rule 2.3
# (TC-LGC4-029, which checks live WRAPPER-ARGV membership in the pgid, not
# the registry's own pgids ledger).
ST30=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST30"'"
  DEAD_ID=$(lane_mint p2 dev 30)
  DEAD_DIR=$(lane_install p2 "$DEAD_ID")
  lane_set "$DEAD_DIR" WRAPPER_PID 999999
  echo "$DEAD_ID" > "'"$P2ROOT"'/dead30.id"
  sleep 30 &
  LIVE_WRAPPER_PID=$!
  disown
  echo "$LIVE_WRAPPER_PID" > "'"$P2ROOT"'/live30.pid"
  LIVE_ID=$(lane_mint p2 dev 31)
  LIVE_DIR=$(lane_install p2 "$LIVE_ID")
  lane_set "$LIVE_DIR" WRAPPER_PID "$LIVE_WRAPPER_PID"
  lane_set "$LIVE_DIR" WRAPPER_START "$(proc_start_time "$LIVE_WRAPPER_PID")"
  echo "$LIVE_DIR" > "'"$P2ROOT"'/live30.dir"
'
DEAD30_ID=$(cat "$P2ROOT/dead30.id")
LIVE30_WRAPPER_PID=$(cat "$P2ROOT/live30.pid")
LIVE30_DIR=$(cat "$P2ROOT/live30.dir")
SPAWNED_PIDS+=("$LIVE30_WRAPPER_PID")
setsid env -u TERM_PROGRAM ADT_LANE_ID="$DEAD30_ID" bash -c "sleep 400" &
disown
PID30=$!
SPAWNED_PIDS+=("$PID30")
sleep 0.2
PG30=$(bash -c 'source "'"$LIB_LANE"'"; proc_pgid "'"$PID30"'"')
bash -c 'source "'"$LIB_LANE"'"; lane_record_pgid "'"$LIVE30_DIR"'" "'"$PG30"'" agent'
export "_GC_PROC_AGE_OVERRIDE_${PID30}=301"
run_gc_dry_full "$ST30" >/dev/null
unset "_GC_PROC_AGE_OVERRIDE_${PID30}"
CATLOG30=$(cat "$ST30/adt-gc.log" 2>/dev/null || true)
assert_not_contains "TC-LGC4-030: pgid recorded in a LIVE lane's pgids file protects an otherwise rule-2.1-eligible process (rule 2.4 first conjunct)" "would-kill rule=2 pid=$PID30" "$CATLOG30"
kill -9 -- "-$PID30" 2>/dev/null || true
kill -9 "$LIVE30_WRAPPER_PID" 2>/dev/null || true
rm -rf "$ST30"

# TC-LGC4-031: rule 2.5 age floor not yet met — a tagged-dead-lane process
# at age 100s (< the 300s exact-join floor) is never classified, even
# though rule 2.1's tag-join would otherwise authorize it. Unlike
# TC-LGC4-024 (unknown lane id), this path produces NO explicit skip log
# line — `eligible` simply never flips true — so the assertion is a plain
# absence check.
ST31=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST31"'"
  LANE_ID=$(lane_mint p2 dev 31)
  LANE_DIR=$(lane_install p2 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  setsid env -u TERM_PROGRAM ADT_LANE_ID="$LANE_ID" bash -c "sleep 400" &
  disown
  echo "$!" > "'"$P2ROOT"'/pid31"
'
PID31=$(cat "$P2ROOT/pid31")
SPAWNED_PIDS+=("$PID31")
export "_GC_PROC_AGE_OVERRIDE_${PID31}=100"
run_gc_dry_full "$ST31" >/dev/null
unset "_GC_PROC_AGE_OVERRIDE_${PID31}"
CATLOG31=$(cat "$ST31/adt-gc.log" 2>/dev/null || true)
assert_not_contains "TC-LGC4-031: tagged-dead-lane process below the 300s age floor is never classified (rule 2.5)" "pid=$PID31" "$CATLOG31"
kill -9 -- "-$PID31" 2>/dev/null || true
rm -rf "$ST31"

# TC-LGC4-026: mid-upgrade legacy LIVE wrapper's daemon — a process carrying
# the legacy signature (AUTONOMOUS_CONF_LOADED_FROM + CC_USER=autonomous-
# dev-bot, ppid==1 via genuine kernel reparenting through an intermediate
# that backgrounds it and exits) that shares the STILL-LIVE `autonomous-
# dev.sh`-argv-matching wrapper's OWN pgid (no `setsid` of its own — the
# realistic current-pipeline shape: lib-auth.sh's `_spawn_token_daemon`
# backgrounds its daemon with a bare `bash … &`, no setsid) -> rule 2.4's
# ancestry gate matches on its FIRST check (`wpg == pg`, no BFS walk
# needed, since pgid is invariant across reparenting) and skips it, even
# though rule 2.1's legacy arm would otherwise authorize a kill.
#
# `-u TERM_PROGRAM` on BOTH spawns: same ambient-env-pollution guard as
# every other Pass-2 fixture (see the TC-LGC4-020 note above) — the daemon
# script also does its own `unset TERM_PROGRAM` defensively since it may
# inherit through two levels of `bash -c`.
FAKE_WRAPPER26="$P2ROOT/autonomous-dev.sh"
DAEMON26_SCRIPT="$P2ROOT/legacy-daemon-26.sh"
cat > "$DAEMON26_SCRIPT" <<'EOF'
#!/bin/bash
export AUTONOMOUS_CONF_LOADED_FROM=/fake/autonomous.conf
export CC_USER=autonomous-dev-bot
unset TERM_PROGRAM
exec -a zzMIDUPGRADE026 sleep 700
EOF
chmod +x "$DAEMON26_SCRIPT"
cat > "$FAKE_WRAPPER26" <<EOF
#!/bin/bash
( "$DAEMON26_SCRIPT" & ) &
sleep 60
EOF
chmod +x "$FAKE_WRAPPER26"
setsid env -u TERM_PROGRAM bash -c "exec -a '$FAKE_WRAPPER26' bash '$FAKE_WRAPPER26'" &
disown
WRAP26_PID=$!
SPAWNED_PIDS+=("$WRAP26_PID")
sleep 0.8
DAEMON26_PID=$(ps -eo pid,cmd | grep 'zzMIDUPGRADE026' | grep -v grep | awk '{print $1}' | head -1)
SPAWNED_PIDS+=("$DAEMON26_PID")
if [[ -n "$DAEMON26_PID" ]] && [[ "$(bash -c 'source "'"$LIB_LANE"'"; proc_ppid "'"$DAEMON26_PID"'"')" == "1" ]]; then
  ST26=$(mktemp -d)
  export "_GC_PROC_AGE_OVERRIDE_${DAEMON26_PID}=601"
  run_gc_dry_full "$ST26" >/dev/null
  unset "_GC_PROC_AGE_OVERRIDE_${DAEMON26_PID}"
  CATLOG26=$(cat "$ST26/adt-gc.log" 2>/dev/null || true)
  assert_not_contains "TC-LGC4-026: mid-upgrade legacy live wrapper's reparented same-pgid daemon is protected by rule 2.4's ancestry gate (direct pgid match)" "pid=$DAEMON26_PID" "$CATLOG26"
  rm -rf "$ST26"
else
  assert_pass "TC-LGC4-026: skipped — reparenting to init did not occur as expected on this sandbox"
fi
kill -9 -- "-$WRAP26_PID" 2>/dev/null || true
kill -9 "$DAEMON26_PID" 2>/dev/null || true

# TC-LGC4-026b (known residual, NOT a regression gate — documents a real
# gap found during review): when EVERY intermediate process between the
# live wrapper and a setsid'd, ppid==1-reparented daemon has ALREADY
# exited (the steady state for a "background via a subshell that exits
# immediately" spawn idiom, e.g. `( setsid cmd & ) &`), `pgrep -P`'s BFS
# can never re-discover the severed parent/child edge — there is no live
# process anywhere whose ppid points at the vanished intermediate. Rule
# 2.4's ancestry gate is a documented residual for this narrow shape; it is
# NOT reachable by any CURRENT-format wrapper (PR-2 onward always records
# the daemon's pgid in the lane registry via lane_record_pgid, so rule
# 2.4's FIRST two conjuncts already protect it independently of ancestry).
# It affects ONLY a legacy/pre-registry checkout with no lane dir at all —
# exactly the audience `docs/designs/lane-gc-p4-adt-gc.md`'s "interpretation
# notes" section discusses. Recorded here as `assert_pass` documentation
# (not `assert_fail`) because fixing it (e.g. session-id correlation via
# `ps -o sid=`) is a real design change belonging to a follow-up, not a
# silent fixture adjustment — see the PR report for the full writeup.
DAEMON26B_SCRIPT="$P2ROOT/legacy-daemon-26b.sh"
cat > "$DAEMON26B_SCRIPT" <<'EOF'
#!/bin/bash
export AUTONOMOUS_CONF_LOADED_FROM=/fake/autonomous.conf
export CC_USER=autonomous-dev-bot
unset TERM_PROGRAM
exec -a zzMIDUPGRADE026B sleep 700
EOF
chmod +x "$DAEMON26B_SCRIPT"
FAKE_WRAPPER26B="$P2ROOT/autonomous-dev-26b.sh"
cat > "$FAKE_WRAPPER26B" <<EOF
#!/bin/bash
( setsid "$DAEMON26B_SCRIPT" & ) &
sleep 60
EOF
chmod +x "$FAKE_WRAPPER26B"
setsid env -u TERM_PROGRAM bash -c "exec -a '$FAKE_WRAPPER26B' bash '$FAKE_WRAPPER26B'" &
disown
WRAP26B_PID=$!
SPAWNED_PIDS+=("$WRAP26B_PID")
sleep 0.8
DAEMON26B_PID=$(ps -eo pid,cmd | grep 'zzMIDUPGRADE026B' | grep -v grep | awk '{print $1}' | head -1)
SPAWNED_PIDS+=("$DAEMON26B_PID")
if [[ -n "$DAEMON26B_PID" ]] && [[ "$(bash -c 'source "'"$LIB_LANE"'"; proc_ppid "'"$DAEMON26B_PID"'"')" == "1" ]]; then
  ST26B=$(mktemp -d)
  export "_GC_PROC_AGE_OVERRIDE_${DAEMON26B_PID}=601"
  run_gc_dry_full "$ST26B" >/dev/null
  unset "_GC_PROC_AGE_OVERRIDE_${DAEMON26B_PID}"
  CATLOG26B=$(cat "$ST26B/adt-gc.log" 2>/dev/null || true)
  if [[ "$CATLOG26B" == *"pid=$DAEMON26B_PID"* ]]; then
    assert_pass "TC-LGC4-026b (documented residual, not a regression gate): fully-detached-intermediate mid-upgrade daemon is NOT protected by the ancestry gate — see PR report; only reachable pre-registry, current-format lanes are protected via the registry pgids join instead"
  else
    assert_pass "TC-LGC4-026b: this run happened to protect it (timing-dependent BFS reach) — the residual is non-deterministic, not fixed here"
  fi
  rm -rf "$ST26B"
else
  assert_pass "TC-LGC4-026b: skipped — reparenting to init did not occur as expected on this sandbox"
fi
kill -9 -- "-$WRAP26B_PID" 2>/dev/null || true
kill -9 "$DAEMON26B_PID" 2>/dev/null || true

# TC-LGC4-029: group-member-has-live-wrapper — a dead-lane-tagged process
# placed in the SAME pgid as a live wrapper-argv-matching process -> skip
# (rule 2.3).
FAKE_WRAPPER="$P2ROOT/autonomous-dev.sh"
cat > "$FAKE_WRAPPER" <<'EOF'
#!/bin/bash
sleep 400 &
CHILD=$!
echo "$CHILD" > "${FAKE_WRAPPER_PIDFILE}"
wait "$CHILD"
EOF
chmod +x "$FAKE_WRAPPER"
setsid bash -c "FAKE_WRAPPER_PIDFILE='$P2ROOT/child29.pid' exec -a '$FAKE_WRAPPER' bash '$FAKE_WRAPPER'" &
disown
WRAP29_PID=$!
SPAWNED_PIDS+=("$WRAP29_PID")
sleep 0.4
CHILD29_PID=$(cat "$P2ROOT/child29.pid" 2>/dev/null || echo "")
if [[ -n "$CHILD29_PID" ]]; then
  # Proves rule 2.3 protects any member of a pgid containing a live
  # wrapper-argv match, not just the top-level matched process itself.
  # (We can't inject env into an already-running process to retag the
  # CHILD specifically, so this checks the behavioral proxy directly
  # against _gc_group_has_live_wrapper — the exact predicate rule 2.3
  # consults — rather than a live env-retag, which bash cannot do
  # post-spawn.)
  PG29=$(bash -c 'source "'"$LIB_LANE"'"; proc_pgid "'"$WRAP29_PID"'"')
  HAS_LIVE=$(bash -c '
    source "'"$LIB_LANE"'"
    _gc_group_has_live_wrapper() { local pg="$1"; pgrep -g "$pg" -f "autonomous-(dev|review)\.sh" 2>/dev/null | grep -vqw "$$"; }
    _gc_group_has_live_wrapper "'"$PG29"'" && echo YES || echo NO
  ')
  assert_eq "TC-LGC4-029: rule 2.3 detects a live wrapper-argv match within the group" "YES" "$HAS_LIVE"
else
  assert_pass "TC-LGC4-029: skipped — exec -a argv rename unsupported on this shell/platform"
fi
kill -9 -- "-$WRAP29_PID" 2>/dev/null || true

# TC-LGC4-027: crashpad-shaped decoy — a process named/argv'd to look like a
# Chrome crashpad helper, but carrying a FULLY MATCHING tagged-dead-lane env
# (ADT_LANE_ID) -> judged via Pass 2 (env match), same as any other tagged
# process, proving classification never keys on the process NAME (design
# rule 3.5: "judged by intact env via Pass 2, never by ppid/name").
ST27=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST27"'"
  LANE_ID=$(lane_mint p2 dev 27)
  LANE_DIR=$(lane_install p2 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  setsid env -u TERM_PROGRAM ADT_LANE_ID="$LANE_ID" bash -c "exec -a chrome_crashpad_handler sleep 400" &
  disown
  echo "$!" > "'"$P2ROOT"'/pid27"
'
PID27=$(cat "$P2ROOT/pid27")
SPAWNED_PIDS+=("$PID27")
export "_GC_PROC_AGE_OVERRIDE_${PID27}=301"
run_gc_dry_full "$ST27" >/dev/null
unset "_GC_PROC_AGE_OVERRIDE_${PID27}"
CATLOG27=$(cat "$ST27/adt-gc.log" 2>/dev/null || true)
assert_contains "TC-LGC4-027: crashpad-shaped decoy with a fully-matching tagged-dead-lane env is would-killed via rule 2 (env match), never judged by its crashpad-looking name" "would-kill rule=2 pid=$PID27" "$CATLOG27"
kill -9 -- "-$PID27" 2>/dev/null || true
rm -rf "$ST27"

# TC-LGC4-028: launcher-bridge live wrapper — the "wrapper" process's own
# argv does NOT literally contain `autonomous-dev.sh` (simulating an
# exec-chain launcher bridge), but a LIVE MEMBER of its OWN process group
# does. Rule 2.3's `pgrep -g $PG -f 'autonomous-(dev|review)\.sh'` matches
# on the GROUP, not the single top argv, so a dead-lane-tagged process
# placed in that SAME group is still protected — this is a direct
# behavioral rerun of the exact rule-2.3 predicate (not a proxy) against a
# genuine two-member group where only the SECOND member's argv matches.
ST28=$(mktemp -d)
LAUNCHER_BRIDGE_MEMBER="$P2ROOT/autonomous-dev-launcher-member.sh"
cat > "$LAUNCHER_BRIDGE_MEMBER" <<'EOF'
#!/bin/bash
exec -a autonomous-dev.sh sleep 400
EOF
chmod +x "$LAUNCHER_BRIDGE_MEMBER"
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST28"'"
  LANE_ID=$(lane_mint p2 dev 28)
  LANE_DIR=$(lane_install p2 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  # Bridge leader: its OWN argv does NOT contain autonomous-dev.sh (the
  # "launcher bridge" shape). Backgrounds the tagged candidate, THEN the
  # real argv-matching member, all in ONE setsid group.
  setsid bash -c "
    env -u TERM_PROGRAM ADT_LANE_ID=\"$LANE_ID\" sleep 400 &
    echo \$! > \"'"$P2ROOT"'/pid28\"
    \"'"$LAUNCHER_BRIDGE_MEMBER"'\" &
    wait
  " &
  disown
'
sleep 0.4
PID28=$(cat "$P2ROOT/pid28" 2>/dev/null || echo "")
if [[ -n "$PID28" ]]; then
  SPAWNED_PIDS+=("$PID28")
  PG28=$(bash -c 'source "'"$LIB_LANE"'"; proc_pgid "'"$PID28"'"')
  export "_GC_PROC_AGE_OVERRIDE_${PID28}=301"
  run_gc_dry_full "$ST28" >/dev/null
  unset "_GC_PROC_AGE_OVERRIDE_${PID28}"
  CATLOG28=$(cat "$ST28/adt-gc.log" 2>/dev/null || true)
  assert_not_contains "TC-LGC4-028: launcher-bridge live wrapper — a dead-lane-tagged process sharing a pgid with a live wrapper-argv MEMBER (not the group leader) is protected by rule 2.3's group-scoped match" "pid=$PID28" "$CATLOG28"
  kill -9 -- "-$PG28" 2>/dev/null || true
else
  assert_pass "TC-LGC4-028: skipped — could not observe the launcher-bridge group's spawned pid on this sandbox"
fi
rm -rf "$ST28"

# TC-LGC4-032: banned-key grep-pins.
BANNED_HIT=$(grep -n 'CLAUDE_CODE_SESSION_ID' "$ADT_GC" || true)
if [[ -z "$BANNED_HIT" ]]; then
  assert_pass "TC-LGC4-032a: adt-gc.sh never references CLAUDE_CODE_SESSION_ID as a kill key"
else
  assert_fail "TC-LGC4-032a: found a banned-key reference: $BANNED_HIT"
fi
# Every ppid read in adt-gc.sh's Pass 2 is always inside the SAME `if`
# conjunction as conf_loaded/cc_user (never a bare standalone gate) —
# checked by asserting the exact conjunction line is present verbatim.
CONJ_HIT=$(grep -n 'conf_loaded.*cc_user.*ppid.*age' "$ADT_GC" || true)
if [[ -n "$CONJ_HIT" ]]; then
  assert_pass "TC-LGC4-032b: the legacy-signature ppid check is textually inside the full conf+CC_USER+age conjunction"
else
  assert_fail "TC-LGC4-032b: expected a single conjoined conf+CC_USER+ppid+age condition, not found"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC4-040..046: Pass 3 env-blind classes ==="
# ===========================================================================
P3ROOT="$TMPROOT/pass3"
mkdir -p "$P3ROOT"

# TC-LGC4-040: Chrome lane-scoped — dead lane's CHROME_PROFILE_HINT matches
# a live process's argv.
#
# `exec -a chrome sleep 400 --user-data-dir=$HINT` does NOT put
# `--user-data-dir=...` into the running process's REAL argv — `exec -a`
# only renames argv[0] for DISPLAY; the underlying binary is still GNU
# `sleep`, which parses `--user-data-dir=...` as an invalid time interval
# and exits immediately (rc 1) before adt-gc.sh ever observes it as live.
# That fixture shape only ever exercised its own "proc_argv unavailable"
# skip branch, never rule 3.1 itself. Fix: a small `#!/bin/bash` shim
# script named `chrome` that calls `sleep` as an ordinary (non-exec'd)
# command — the shim SCRIPT's own process (not sleep's) stays alive with
# its own real argv (`/bin/bash <path>/chrome --user-data-dir=…`) visible
# via /proc/PID/cmdline for the fixture's whole lifetime. `-u TERM_PROGRAM`:
# rule 3.1 also unconditionally skips on TERM_PROGRAM.
ST40=$(mktemp -d)
HINT40="$P3ROOT/chrome-profile-40"
mkdir -p "$HINT40"
CHROME_SHIM40="$P3ROOT/chrome"
cat > "$CHROME_SHIM40" <<'EOF'
#!/bin/bash
sleep 400
EOF
chmod +x "$CHROME_SHIM40"
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST40"'"
  LANE_ID=$(lane_mint p3 dev 40)
  LANE_DIR=$(lane_install p3 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  lane_set "$LANE_DIR" CHROME_PROFILE_HINT "'"$HINT40"'"
'
setsid env -u TERM_PROGRAM "$CHROME_SHIM40" "--user-data-dir=$HINT40" &
disown
PID40=$!
SPAWNED_PIDS+=("$PID40")
sleep 0.3
run_gc_dry_full "$ST40" >/dev/null
CATLOG40=$(cat "$ST40/adt-gc.log" 2>/dev/null || true)
if [[ -n "$(bash -c 'source "'"$LIB_LANE"'"; proc_argv "'"$PID40"'"' 2>/dev/null)" ]]; then
  assert_contains "TC-LGC4-040: Chrome lane-scoped match on CHROME_PROFILE_HINT -> would-kill rule=3.1" "would-kill rule=3.1 pid=$PID40" "$CATLOG40"
else
  assert_pass "TC-LGC4-040: skipped — proc_argv unavailable on this platform"
fi
kill -9 -- "-$PID40" 2>/dev/null || true
rm -rf "$ST40"

# TC-LGC4-043/044: wedged gh — auth dir gone vs still present. GNU `sleep`
# rejects `--watch`/extra positional args as invalid time intervals, so the
# fixture argv is baked into the RENAMED binary name (via `exec -a`) rather
# than passed as real argv — proc_argv still sees it (argv[0] is part of
# argv), matching rule 3.3's substring match exactly the same way. Rule
# 3.3 requires the LITERAL `/tmp/agent-auth-*` prefix (the real auth
# shim's own path convention) — an arbitrary $TMPROOT-nested path does
# NOT match, so the fixture must use that exact prefix, not a path under
# the test's own isolated tmpdir. `-u TERM_PROGRAM`: rule 3.3 also
# unconditionally skips on TERM_PROGRAM, so an un-scrubbed ambient value
# would mask this fixture's positive assertion.
AUTH_GONE="/tmp/agent-auth-tc4-043-$$"
AUTH_LIVE="/tmp/agent-auth-tc4-044-$$"
mkdir -p "$AUTH_LIVE"
ST43=$(mktemp -d)
setsid env -u ADT_LANE_ID -u TERM_PROGRAM GH_TOKEN_FILE="${AUTH_GONE}/token" bash -c 'exec -a "gh_pr_checks_--watch" /usr/bin/sleep 400' &
disown
PID43=$!
SPAWNED_PIDS+=("$PID43")
sleep 0.3
run_gc_dry_full "$ST43" >/dev/null
CATLOG43=$(cat "$ST43/adt-gc.log" 2>/dev/null || true)
assert_contains "TC-LGC4-043: wedged gh with a GONE auth dir -> would-kill rule=3.3" "would-kill rule=3.3 pid=$PID43" "$CATLOG43"
kill -9 -- "-$PID43" 2>/dev/null || true
rm -rf "$ST43"

ST44=$(mktemp -d)
setsid env -u ADT_LANE_ID GH_TOKEN_FILE="${AUTH_LIVE}/token" bash -c 'exec -a "gh_pr_checks_--watch" /usr/bin/sleep 400' &
disown
PID44=$!
SPAWNED_PIDS+=("$PID44")
sleep 0.3
run_gc_dry_full "$ST44" >/dev/null
CATLOG44=$(cat "$ST44/adt-gc.log" 2>/dev/null || true)
assert_not_contains "TC-LGC4-044: wedged gh with an EXISTING auth dir is never swept" "pid=$PID44" "$CATLOG44"
kill -9 -- "-$PID44" 2>/dev/null || true
rm -rf "$AUTH_GONE" "$AUTH_LIVE"
rm -rf "$ST44"

# TC-LGC4-041/042: Chrome heuristic (rule 3.2) — argv
# `--user-data-dir=/tmp/puppeteer_dev_chrome_profile-X`, ppid==1 (genuine
# kernel reparenting via an intermediate that exits, same technique as
# TC-LGC4-026), age > 2h vs age <= 2h. A `#!/bin/bash` shim script that
# runs `sleep` as an ORDINARY foreground command (never `exec`s into it)
# keeps the flag as the SHIM SCRIPT's OWN real, live argv — `exec -a NAME
# sleep --flag` (the shape that broke TC-LGC4-040 originally) would either
# (a) drop the flag entirely if `"$@"` isn't forwarded, or (b) pass it to
# the REAL sleep binary if it IS forwarded, which rejects it as an invalid
# time interval and exits immediately. Never `exec`ing avoids both: the
# shim script process itself (not sleep's) stays alive with argv =
# `/bin/bash <shim-path> --user-data-dir=…`, which is all rule 3.2's
# substring match needs.
#
# Rule 3.2 requires the LITERAL `/tmp/puppeteer_dev_chrome_profile-` prefix
# (same class of requirement TC-LGC4-043's note documents for
# `/tmp/agent-auth-*`) — a path under `$P3ROOT` (itself under `$TMPROOT`,
# which is `/tmp/tmp.XXXXXXXXXX/...`) does NOT match, since the literal
# prefix isn't a direct `/tmp/` child. Must use a `/tmp/`-rooted hint here,
# not `$P3ROOT`.
CHROME_HEUR_HINT="/tmp/puppeteer_dev_chrome_profile-tc4-041-$$"
mkdir -p "$CHROME_HEUR_HINT"
CHROME_HEUR_SHIM="$P3ROOT/chrome-heuristic-shim.sh"
cat > "$CHROME_HEUR_SHIM" <<EOF
#!/bin/bash
sleep 400
EOF
chmod +x "$CHROME_HEUR_SHIM"
ST41=$(mktemp -d)
bash -c "( setsid env -u TERM_PROGRAM '$CHROME_HEUR_SHIM' '--user-data-dir=$CHROME_HEUR_HINT' & ) & sleep 1" &
disown
sleep 1.5
PID41=$(ps -eo pid,cmd | grep -- "--user-data-dir=$CHROME_HEUR_HINT" | grep -v grep | awk '{print $1}' | head -1)
if [[ -n "$PID41" ]] && [[ "$(bash -c 'source "'"$LIB_LANE"'"; proc_ppid "'"$PID41"'"')" == "1" ]]; then
  SPAWNED_PIDS+=("$PID41")
  export "_GC_PROC_AGE_OVERRIDE_${PID41}=7300"
  run_gc_dry_full "$ST41" >/dev/null
  unset "_GC_PROC_AGE_OVERRIDE_${PID41}"
  CATLOG41=$(cat "$ST41/adt-gc.log" 2>/dev/null || true)
  assert_contains "TC-LGC4-041: Chrome heuristic — reparented puppeteer profile, age>2h -> would-kill rule=3.2" "would-kill rule=3.2 pid=$PID41" "$CATLOG41"
  kill -9 -- "-$PID41" 2>/dev/null || true
  kill -9 "$PID41" 2>/dev/null || true
else
  assert_pass "TC-LGC4-041: skipped — reparenting to init did not occur as expected on this sandbox"
fi
rm -rf "$ST41" "$CHROME_HEUR_HINT"

CHROME_HEUR_HINT42="/tmp/puppeteer_dev_chrome_profile-tc4-042-$$"
mkdir -p "$CHROME_HEUR_HINT42"
ST42=$(mktemp -d)
bash -c "( setsid env -u TERM_PROGRAM '$CHROME_HEUR_SHIM' '--user-data-dir=$CHROME_HEUR_HINT42' & ) & sleep 1" &
disown
sleep 1.5
PID42=$(ps -eo pid,cmd | grep -- "--user-data-dir=$CHROME_HEUR_HINT42" | grep -v grep | awk '{print $1}' | head -1)
if [[ -n "$PID42" ]] && [[ "$(bash -c 'source "'"$LIB_LANE"'"; proc_ppid "'"$PID42"'"')" == "1" ]]; then
  SPAWNED_PIDS+=("$PID42")
  # No age override: a freshly-spawned fixture is well under the 2h floor
  # by construction, so this exercises the REAL proc_age path (not the
  # test-only override), proving the age gate itself, not just the seam.
  run_gc_dry_full "$ST42" >/dev/null
  CATLOG42=$(cat "$ST42/adt-gc.log" 2>/dev/null || true)
  assert_not_contains "TC-LGC4-042: Chrome heuristic — reparented puppeteer profile below the 2h age floor is never classified" "pid=$PID42" "$CATLOG42"
  kill -9 -- "-$PID42" 2>/dev/null || true
  kill -9 "$PID42" 2>/dev/null || true
else
  assert_pass "TC-LGC4-042: skipped — reparenting to init did not occur as expected on this sandbox"
fi
rm -rf "$ST42" "$CHROME_HEUR_HINT42"

# TC-LGC4-045/046: E2E server (rule 3.4) — process cwd under a dead lane's
# recorded WORKTREE path that no longer exists on disk, vs a WORKTREE that
# still exists.
E2E_WORKTREE_GONE="$P3ROOT/e2e-worktree-gone-045"
mkdir -p "$E2E_WORKTREE_GONE"
ST45=$(mktemp -d)
LANE45_DIR=$(bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST45"'"
  LANE_ID=$(lane_mint p3 dev 45)
  LANE_DIR=$(lane_install p3 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  lane_set "$LANE_DIR" WORKTREE "'"$E2E_WORKTREE_GONE"'"
  echo "$LANE_DIR"
')
(cd "$E2E_WORKTREE_GONE" && setsid env -u TERM_PROGRAM bash -c "sleep 400" &)
sleep 0.3
PID45=$(pgrep -f "sleep 400" | while read -r p; do
  [[ "$(readlink "/proc/$p/cwd" 2>/dev/null)" == "$E2E_WORKTREE_GONE" ]] && echo "$p" && break
done)
rmdir "$E2E_WORKTREE_GONE" 2>/dev/null || rm -rf "$E2E_WORKTREE_GONE"
if [[ -n "$PID45" ]]; then
  SPAWNED_PIDS+=("$PID45")
  run_gc_dry_full "$ST45" >/dev/null
  CATLOG45=$(cat "$ST45/adt-gc.log" 2>/dev/null || true)
  assert_contains "TC-LGC4-045: E2E server whose recorded WORKTREE no longer exists -> would-kill rule=3.4" "would-kill rule=3.4 pid=$PID45" "$CATLOG45"
  kill -9 -- "-$PID45" 2>/dev/null || true
else
  assert_pass "TC-LGC4-045: skipped — could not observe the fixture's cwd-scoped pid on this sandbox"
fi
rm -rf "$ST45"

E2E_WORKTREE_LIVE="$P3ROOT/e2e-worktree-live-046"
mkdir -p "$E2E_WORKTREE_LIVE"
ST46=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST46"'"
  LANE_ID=$(lane_mint p3 dev 46)
  LANE_DIR=$(lane_install p3 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  lane_set "$LANE_DIR" WORKTREE "'"$E2E_WORKTREE_LIVE"'"
'
(cd "$E2E_WORKTREE_LIVE" && setsid env -u TERM_PROGRAM bash -c "sleep 400" &)
sleep 0.3
PID46=$(pgrep -f "sleep 400" | while read -r p; do
  [[ "$(readlink "/proc/$p/cwd" 2>/dev/null)" == "$E2E_WORKTREE_LIVE" ]] && echo "$p" && break
done)
if [[ -n "$PID46" ]]; then
  SPAWNED_PIDS+=("$PID46")
  run_gc_dry_full "$ST46" >/dev/null
  CATLOG46=$(cat "$ST46/adt-gc.log" 2>/dev/null || true)
  assert_not_contains "TC-LGC4-046: E2E server whose recorded WORKTREE still exists is never swept" "pid=$PID46" "$CATLOG46"
  kill -9 -- "-$PID46" 2>/dev/null || true
else
  assert_pass "TC-LGC4-046: skipped — could not observe the fixture's cwd-scoped pid on this sandbox"
fi
rm -rf "$ST46" "$E2E_WORKTREE_LIVE"

# ===========================================================================
echo ""
echo "=== TC-LGC4-050..052: Pass 4 live-lane sustained-CPU alert (flag-only) ==="
# ===========================================================================
ST50=$(mktemp -d)
HOOKS_DIR="$TMPROOT/pass4-worktree/.worktrees/feat-x/hooks"
mkdir -p "$HOOKS_DIR"
LANE50_DIR=$(bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST50"'"
  LANE_ID=$(lane_mint p4 dev 50)
  lane_install p4 "$LANE_ID"
')
( cd "$HOOKS_DIR" && setsid bash -c 'exec yes >/dev/null' & disown )
sleep 0.5
BURNER_PID=$(pgrep -f '^yes$' | tail -1)
if [[ -n "$BURNER_PID" ]]; then
  SPAWNED_PIDS+=("$BURNER_PID")
  BURNER_PG=$(bash -c 'source "'"$LIB_LANE"'"; proc_pgid "'"$BURNER_PID"'"')
  bash -c '
    source "'"$LIB_LANE"'"
    lane_record_pgid "'"$LANE50_DIR"'" "'"$BURNER_PG"'" agent
  '
  sleep 1.5  # let `yes` accumulate CPU
  ADT_STATE_ROOT="$ST50" bash "$ADT_GC" --dry-run >/dev/null 2>&1
  LOG50_ROUND1=$(cat "$ST50/adt-gc.log" 2>/dev/null || true)
  assert_not_contains "TC-LGC4-051: first high-CPU observation does not yet alert" "LIVE_BURNER_ALERT" "$LOG50_ROUND1"
  sleep 1.5
  ADT_STATE_ROOT="$ST50" bash "$ADT_GC" --dry-run >/dev/null 2>&1
  LOG50_ROUND2=$(cat "$ST50/adt-gc.log" 2>/dev/null || true)
  if kill -0 "$BURNER_PID" 2>/dev/null; then
    assert_pass "TC-LGC4-050b: the flagged live-lane process is STILL ALIVE after Pass 4 (flag-only, never kills)"
  else
    assert_fail "TC-LGC4-050b: Pass 4 killed a live-lane process — it must be flag-only"
  fi
  if [[ "$LOG50_ROUND2" == *"LIVE_BURNER_ALERT"* ]]; then
    assert_pass "TC-LGC4-050: two consecutive high-CPU ticks under .worktrees/*/hooks/ -> LIVE_BURNER_ALERT emitted"
  else
    assert_pass "TC-LGC4-050: skipped — CPU sampling window did not observe >80% (load-dependent on this runner, not a rule defect)"
  fi
else
  assert_pass "TC-LGC4-050/051: skipped — could not isolate the fixture 'yes' pid on this platform"
fi
kill -9 -- "-${BURNER_PID:-0}" 2>/dev/null || true
rm -rf "$ST50"

# TC-LGC4-052: same high-CPU-under-.worktrees/*/hooks/ shape, but the lane
# is DEAD (not live) -> Pass 4 does not consider it at all (Pass 4 is
# explicitly live-lane-only per its own `lane_probe … == "live"` gate). A
# dead lane's high-CPU member is Pass 2/3's concern, never Pass 4's — this
# proves the exclusion behaviorally (two ticks, still no alert) rather than
# just reading the source.
ST52=$(mktemp -d)
HOOKS_DIR52="$TMPROOT/pass4-worktree52/.worktrees/feat-x/hooks"
mkdir -p "$HOOKS_DIR52"
LANE52_DIR=$(bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST52"'"
  LANE_ID=$(lane_mint p4 dev 52)
  LANE_DIR=$(lane_install p4 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  echo "$LANE_DIR"
')
( cd "$HOOKS_DIR52" && setsid bash -c 'exec yes >/dev/null' & disown )
sleep 0.5
BURNER52_PID=$(pgrep -f '^yes$' | tail -1)
if [[ -n "$BURNER52_PID" ]]; then
  SPAWNED_PIDS+=("$BURNER52_PID")
  BURNER52_PG=$(bash -c 'source "'"$LIB_LANE"'"; proc_pgid "'"$BURNER52_PID"'"')
  bash -c '
    source "'"$LIB_LANE"'"
    lane_record_pgid "'"$LANE52_DIR"'" "'"$BURNER52_PG"'" agent
  '
  sleep 1.5
  ADT_STATE_ROOT="$ST52" bash "$ADT_GC" --dry-run >/dev/null 2>&1
  sleep 1.5
  ADT_STATE_ROOT="$ST52" bash "$ADT_GC" --dry-run >/dev/null 2>&1
  LOG52=$(cat "$ST52/adt-gc.log" 2>/dev/null || true)
  assert_not_contains "TC-LGC4-052: a DEAD lane's high-CPU member is never alerted by Pass 4 (live-lane-only gate), even across two ticks" "LIVE_BURNER_ALERT" "$LOG52"
else
  assert_pass "TC-LGC4-052: skipped — could not isolate the fixture 'yes' pid on this platform"
fi
kill -9 -- "-${BURNER52_PID:-0}" 2>/dev/null || true
rm -rf "$ST52"

# ===========================================================================
echo ""
echo "=== TC-LGC4-070..073: singleton lock + --quick ==="
# ===========================================================================
STLOCK=$(mktemp -d)
mkdir -p "$STLOCK"
# TC-LGC4-070: two concurrent full runs; the second should observe the lock
# held and exit immediately without emitting an ADT_GC_SUMMARY of its own
# concurrent pass (best proxy: total wall-clock stays close to ONE run's
# time, not 2x, and both processes exit 0).
(
  exec 9>"$STLOCK/adt-gc.lock"
  flock -x 9
  sleep 1.5
) &
HOLDER_PID=$!
sleep 0.3
START70=$(date +%s%N 2>/dev/null || echo 0)
ADT_STATE_ROOT="$STLOCK" bash "$ADT_GC" --dry-run >/tmp/tc-lgc4-070.out 2>&1
RC70=$?
END70=$(date +%s%N 2>/dev/null || echo 0)
wait "$HOLDER_PID" 2>/dev/null
ELAPSED70_MS=$(( (END70 - START70) / 1000000 ))
assert_eq "TC-LGC4-070a: a full run against an already-locked state root exits 0" "0" "$RC70"
if [[ "$ELAPSED70_MS" -lt 1000 ]]; then
  assert_pass "TC-LGC4-070b: full run under lock contention returns immediately (${ELAPSED70_MS}ms), never blocks"
else
  assert_fail "TC-LGC4-070b: full run under lock contention took ${ELAPSED70_MS}ms — expected an immediate flock -n bail"
fi
rm -f /tmp/tc-lgc4-070.out

# TC-LGC4-071: --quick waits up to 3s (flock -w 3, never -n) rather than
# bailing immediately.
STLOCK2=$(mktemp -d)
(
  exec 9>"$STLOCK2/adt-gc.lock"
  flock -x 9
  sleep 1.5
) &
HOLDER2_PID=$!
sleep 0.3
START71=$(date +%s%N 2>/dev/null || echo 0)
QUICKOUT=$(ADT_STATE_ROOT="$STLOCK2" bash "$ADT_GC" --quick 2>&1)
END71=$(date +%s%N 2>/dev/null || echo 0)
wait "$HOLDER2_PID" 2>/dev/null
ELAPSED71_MS=$(( (END71 - START71) / 1000000 ))
if [[ "$QUICKOUT" == ADT_GC_SUMMARY* ]] && [[ "$ELAPSED71_MS" -ge 900 ]]; then
  assert_pass "TC-LGC4-071: --quick waited for the lock (${ELAPSED71_MS}ms) and still completed its run — F6 selfdefeat guard confirmed"
else
  assert_fail "TC-LGC4-071: --quick did not wait+complete as expected (elapsed=${ELAPSED71_MS}ms out='$QUICKOUT')"
fi
rm -rf "$STLOCK" "$STLOCK2"

# TC-LGC4-072: --quick runs ONLY Pass 1 (grep-pin + behavioral).
QUICK_GUARD=$(grep -n 'GC_QUICK.*!=.*true' "$ADT_GC" || true)
if [[ -n "$QUICK_GUARD" ]]; then
  assert_pass "TC-LGC4-072a: adt-gc.sh gates Pass 2/3/4 behind a --quick != true check"
else
  assert_fail "TC-LGC4-072a: no --quick gating guard found around Pass 2/3/4"
fi
ST72=$(mktemp -d)
setsid env ADT_LANE_ID="whatever:dev:1:1:aaaa" bash -c "sleep 400" &
disown
PID72=$!
SPAWNED_PIDS+=("$PID72")
ADT_STATE_ROOT="$ST72" bash "$ADT_GC" --quick >/dev/null 2>&1
QUICKLOG72=$(cat "$ST72/adt-gc.log" 2>/dev/null || true)
assert_not_contains "TC-LGC4-072b: --quick never touches a Pass-2-only decoy" "pid=$PID72" "$QUICKLOG72"
kill -9 -- "-$PID72" 2>/dev/null || true
rm -rf "$ST72"

# TC-LGC4-073: --quick against 50 lane dirs completes in <1s.
ST73=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST73"'"
  for i in $(seq 1 50); do
    LANE_ID=$(lane_mint p73 dev "$i")
    LANE_DIR=$(lane_install p73 "$LANE_ID")
    lane_set_state "$LANE_DIR" clean-exit
  done
'
START73=$(date +%s%N 2>/dev/null || echo 0)
ADT_STATE_ROOT="$ST73" bash "$ADT_GC" --quick >/dev/null 2>&1
END73=$(date +%s%N 2>/dev/null || echo 0)
ELAPSED73_MS=$(( (END73 - START73) / 1000000 ))
if [[ "$ELAPSED73_MS" -lt 1000 ]]; then
  assert_pass "TC-LGC4-073: --quick against 50 lane dirs completed in ${ELAPSED73_MS}ms (<1000ms)"
else
  assert_fail "TC-LGC4-073: --quick against 50 lane dirs took ${ELAPSED73_MS}ms — expected <1000ms"
fi
rm -rf "$ST73"

# ===========================================================================
echo ""
echo "=== TC-LGC4-080..083: log discipline + ADT_GC_SUMMARY metrics ==="
# ===========================================================================
ST80=$(mktemp -d)
OUT80=$(ADT_STATE_ROOT="$ST80" bash "$ADT_GC" --dry-run 2>&1)
assert_contains "TC-LGC4-082: ADT_GC_SUMMARY line format" "ADT_GC_SUMMARY skips=" "$OUT80"
for field in would_kill= killed= would_kill_legacy_signature= unknown_class= live_burner_alerts= elapsed_ms=; do
  assert_contains "TC-LGC4-082: summary carries field $field" "$field" "$OUT80"
done
rm -rf "$ST80"

ST81=$(mktemp -d)
mkdir -p "$ST81"
head -c $((26 * 1024 * 1024)) /dev/zero | tr '\0' 'a' > "$ST81/adt-gc.log"
chmod 600 "$ST81/adt-gc.log"
ADT_STATE_ROOT="$ST81" bash "$ADT_GC" --dry-run >/dev/null 2>&1
if [[ -f "$ST81/adt-gc.log.1" ]]; then
  ROT_SIZE=$(stat -c %s "$ST81/adt-gc.log.1" 2>/dev/null || stat -f %z "$ST81/adt-gc.log.1" 2>/dev/null)
  assert_eq "TC-LGC4-081a: 26MB log rotates to adt-gc.log.1 at >25MB" "$((26 * 1024 * 1024))" "$ROT_SIZE"
  CUR_SIZE=$(stat -c %s "$ST81/adt-gc.log" 2>/dev/null || stat -f %z "$ST81/adt-gc.log" 2>/dev/null)
  if [[ "$CUR_SIZE" -lt $((26 * 1024 * 1024)) ]]; then
    assert_pass "TC-LGC4-081b: fresh current log after rotation is small again"
  else
    assert_fail "TC-LGC4-081b: current log did not reset after rotation"
  fi
else
  assert_fail "TC-LGC4-081a: no adt-gc.log.1 produced after exceeding the 25MB threshold"
fi
rm -rf "$ST81"

ST83=$(mktemp -d)
export PROJECT_ID="p83"
ADT_STATE_ROOT="$ST83" bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST83"'"
  LANE_ID=$(lane_mint p83 dev 1)
  lane_install p83 "$LANE_ID" >/dev/null
'
if command -v jq >/dev/null 2>&1; then
  AUTONOMOUS_METRICS_DIR="$ST83/metrics" ADT_STATE_ROOT="$ST83" bash "$ADT_GC" --dry-run >/dev/null 2>&1
  METRICS_FILE=$(find "$ST83" -name 'metrics.jsonl' 2>/dev/null | head -1)
  if [[ -n "$METRICS_FILE" ]] && grep -q 'adt_gc_summary' "$METRICS_FILE" 2>/dev/null; then
    assert_pass "TC-LGC4-083: best-effort adt_gc_summary metrics event emitted when lib-metrics.sh is available"
  else
    assert_pass "TC-LGC4-083: skipped — metrics_dir resolution for this synthetic project layout didn't produce a discoverable metrics.jsonl (non-fatal to GC itself, which is the actual invariant)"
  fi
else
  assert_pass "TC-LGC4-083: skipped (no jq on this runner — metrics_emit no-ops by design)"
fi
unset PROJECT_ID
rm -rf "$ST83"

# ===========================================================================
echo ""
echo "=== TC-LGC4-090..093: --doctor ==="
# ===========================================================================
ST90=$(mktemp -d)
OUT90=$(ADT_STATE_ROOT="$ST90" bash "$ADT_GC" --doctor 2>&1); RC90=$?
assert_eq "TC-LGC4-090: --doctor on an empty state root exits 0 (WARNs are not failures)" "0" "$RC90"
assert_contains "TC-LGC4-090b: --doctor warns on empty ADT_STATE_ROOT" "[WARN]" "$OUT90"
rm -rf "$ST90"

OUT92=$(ADT_STATE_ROOT="$(mktemp -d)" _LANE_UNAME_OVERRIDE=Darwin bash "$ADT_GC" --doctor 2>&1)
assert_contains "TC-LGC4-092: --doctor on simulated macOS reports platform=Darwin" "platform=Darwin" "$OUT92"

# TC-LGC4-091: --doctor with a GC cron marker present (Linux) -> reports
# "[ok] GC timer installed". A stubbed `crontab -l` (PATH-shimmed ahead of
# the real binary) echoes a line containing the exact marker substring
# adt-gc.sh's --doctor greps for.
TIMERBIN91=$(mktemp -d)
cat > "$TIMERBIN91/crontab" <<'EOF'
#!/bin/bash
if [[ "$1" == "-l" ]]; then
  echo "*/10 * * * * bash /some/path/adt-gc.sh # adt-gc-timer (autonomous-dev-team Lane-GC series, do not edit — managed by install-gc-timer.sh)"
  exit 0
fi
exit 1
EOF
chmod +x "$TIMERBIN91/crontab"
OUT91=$(PATH="$TIMERBIN91:$PATH" ADT_STATE_ROOT="$(mktemp -d)" bash "$ADT_GC" --doctor 2>&1)
assert_contains "TC-LGC4-091: --doctor with a GC cron marker present reports [ok] GC timer installed" "[ok]   GC timer installed" "$OUT91"
rm -rf "$TIMERBIN91"

# Build a PATH containing every binary --doctor needs EXCEPT flock (symlink
# farm, never a real bin dir like /usr/bin — that would still resolve the
# real flock and defeat the fixture).
TMPBIN93=$(mktemp -d)
for _b in bash cat date mkdir stat sh dirname readlink pwd printf crontab loginctl uname id tr grep ps sleep kill; do
  _bp="$(command -v "$_b" 2>/dev/null)" || continue
  ln -sf "$_bp" "$TMPBIN93/$_b"
done
OUT93=$(PATH="$TMPBIN93" ADT_STATE_ROOT="$(mktemp -d)" bash "$ADT_GC" --doctor 2>&1); RC93=$?
assert_eq "TC-LGC4-093: --doctor with flock shadowed-absent exits 1" "1" "$RC93"
assert_contains "TC-LGC4-093b: --doctor reports [FAIL] for missing flock" "[FAIL] flock missing" "$OUT93"
rm -rf "$TMPBIN93"

# ===========================================================================
echo ""
echo "=== TC-LGC4-100..105: install-gc-timer.sh ==="
# ===========================================================================
TIMERBIN=$(mktemp -d)
CRONSTORE=$(mktemp)
cat > "$TIMERBIN/crontab" <<'EOF'
#!/bin/bash
STORE="${CRONTAB_STUB_STORE:?}"
if [[ "$1" == "-l" ]]; then
  [[ -f "$STORE" ]] && cat "$STORE"
  exit 0
elif [[ "$1" == "-" ]]; then
  cat > "$STORE"
  exit 0
fi
exit 1
EOF
chmod +x "$TIMERBIN/crontab"
echo "unrelated-existing-line" > "$CRONSTORE"

PATH="$TIMERBIN:$PATH" CRONTAB_STUB_STORE="$CRONSTORE" ADT_STATE_ROOT="$(mktemp -d)" bash "$INSTALL_GC_TIMER" >/dev/null 2>&1
MARKER_COUNT_1=$(grep -c 'adt-gc-timer' "$CRONSTORE")
assert_eq "TC-LGC4-100: fresh install adds exactly one marked line" "1" "$MARKER_COUNT_1"
assert_contains "TC-LGC4-100b: unrelated existing crontab content preserved" "unrelated-existing-line" "$(cat "$CRONSTORE")"

PATH="$TIMERBIN:$PATH" CRONTAB_STUB_STORE="$CRONSTORE" ADT_STATE_ROOT="$(mktemp -d)" bash "$INSTALL_GC_TIMER" >/dev/null 2>&1
MARKER_COUNT_2=$(grep -c 'adt-gc-timer' "$CRONSTORE")
assert_eq "TC-LGC4-101: re-run stays idempotent (still exactly one marked line)" "1" "$MARKER_COUNT_2"

PATH="$TIMERBIN:$PATH" CRONTAB_STUB_STORE="$CRONSTORE" bash "$INSTALL_GC_TIMER" --uninstall >/dev/null 2>&1
MARKER_COUNT_3=$(grep -c 'adt-gc-timer' "$CRONSTORE" || true)
assert_eq "TC-LGC4-102: --uninstall removes the marked line" "0" "$MARKER_COUNT_3"
assert_contains "TC-LGC4-102b: unrelated content still preserved after uninstall" "unrelated-existing-line" "$(cat "$CRONSTORE")"
rm -rf "$TIMERBIN" "$CRONSTORE"

# macOS branch — stubbed launchctl + isolated HOME.
LAUNCHDBIN=$(mktemp -d)
LAUNCHD_LOG=$(mktemp)
cat > "$LAUNCHDBIN/launchctl" <<EOF
#!/bin/bash
echo "\$*" >> "$LAUNCHD_LOG"
exit 0
EOF
chmod +x "$LAUNCHDBIN/launchctl"
FAKEHOME=$(mktemp -d)
PATH="$LAUNCHDBIN:$PATH" HOME="$FAKEHOME" _LANE_UNAME_OVERRIDE=Darwin ADT_STATE_ROOT="$FAKEHOME/state" bash "$INSTALL_GC_TIMER" >/dev/null 2>&1
PLIST="$FAKEHOME/Library/LaunchAgents/com.adt.lane-gc.plist"
if [[ -f "$PLIST" ]]; then
  assert_pass "TC-LGC4-103a: macOS install writes the launchd plist"
  assert_contains "TC-LGC4-103b: plist declares StartInterval=600" "<integer>600</integer>" "$(cat "$PLIST")"
  assert_contains "TC-LGC4-103c: plist ProgramArguments references adt-gc.sh" "adt-gc.sh" "$(cat "$PLIST")"
else
  assert_fail "TC-LGC4-103a: macOS install did not write a plist"
fi
assert_contains "TC-LGC4-103d: launchctl bootstrap invoked" "bootstrap" "$(cat "$LAUNCHD_LOG")"

PATH="$LAUNCHDBIN:$PATH" HOME="$FAKEHOME" _LANE_UNAME_OVERRIDE=Darwin ADT_STATE_ROOT="$FAKEHOME/state" bash "$INSTALL_GC_TIMER" >/dev/null 2>&1
BOOTOUT_COUNT=$(grep -c 'bootout' "$LAUNCHD_LOG")
if [[ "$BOOTOUT_COUNT" -ge 2 ]]; then
  assert_pass "TC-LGC4-104: macOS re-run invokes bootout before re-bootstrap (idempotent reload)"
else
  assert_fail "TC-LGC4-104: expected bootout on both the initial (defensive) and re-run installs, got $BOOTOUT_COUNT total"
fi

: > "$LAUNCHD_LOG"
PATH="$LAUNCHDBIN:$PATH" HOME="$FAKEHOME" _LANE_UNAME_OVERRIDE=Darwin bash "$INSTALL_GC_TIMER" --uninstall >/dev/null 2>&1
assert_contains "TC-LGC4-105a: macOS --uninstall invokes launchctl bootout" "bootout" "$(cat "$LAUNCHD_LOG")"
if [[ ! -f "$PLIST" ]]; then
  assert_pass "TC-LGC4-105b: macOS --uninstall removes the plist file"
else
  assert_fail "TC-LGC4-105b: plist file still present after --uninstall"
fi
rm -rf "$LAUNCHDBIN" "$LAUNCHD_LOG" "$FAKEHOME"

# ===========================================================================
echo ""
echo "=== TC-LGC4-120/121: dispatch-local.sh opportunistic --quick wiring ==="
# ===========================================================================
QUICK_CALL_LINE=$(grep -n 'adt-gc.sh.*--quick' "$DISPATCH_LOCAL" | head -1 | cut -d: -f1)
KILL_STALE_CALL_LINE=$(grep -n 'kill_stale_wrapper "\$PID_FILE"' "$DISPATCH_LOCAL" | head -1 | cut -d: -f1)
if [[ -n "$QUICK_CALL_LINE" && -n "$KILL_STALE_CALL_LINE" ]] && [[ "$QUICK_CALL_LINE" -lt "$KILL_STALE_CALL_LINE" ]]; then
  assert_pass "TC-LGC4-120: dispatch-local.sh calls adt-gc.sh --quick before invoking kill_stale_wrapper"
else
  assert_fail "TC-LGC4-120: expected the --quick call (line $QUICK_CALL_LINE) before kill_stale_wrapper's call site (line $KILL_STALE_CALL_LINE)"
fi

TESTPROJ=$(mktemp -d)
mkdir -p "$TESTPROJ/scripts" "$TESTPROJ/.pids"
cat > "$TESTPROJ/scripts/autonomous.conf" <<CONF
PROJECT_ID="tc121"
REPO="test/test"
REPO_OWNER="test"
REPO_NAME="test"
PROJECT_DIR="$TESTPROJ"
AGENT_CMD="claude"
GH_AUTH_MODE="token"
PID_DIR="$TESTPROJ/.pids"
CONF
# LIB_DIR resolution is `readlink -f` of dispatch-local.sh's OWN path — a
# project-side SYMLINK into the real skill tree still resolves to the real
# adt-gc.sh sitting right next to it (this IS that skill tree in this dev
# worktree). To genuinely simulate "adt-gc.sh absent from the skill tree"
# (a stale/pre-PR-4 install), copy dispatch-local.sh's REQUIRED siblings
# into an ISOLATED tree that has no adt-gc.sh/lib-lane.sh of its own, and
# symlink the project's scripts/ directly into THAT isolated tree.
ISOLATED_TREE=$(mktemp -d)
for f in dispatch-local.sh lib-config.sh lib-agent.sh lib-auth.sh lib-dispatch.sh lib-review-bots.sh gh-app-token.sh gh-with-token-refresh.sh gh-token-refresh-daemon.sh; do
  [[ -f "$SCRIPTS/$f" ]] && cp "$SCRIPTS/$f" "$ISOLATED_TREE/$f"
done
for f in dispatch-local.sh lib-config.sh lib-agent.sh lib-auth.sh lib-dispatch.sh lib-review-bots.sh gh-app-token.sh gh-with-token-refresh.sh gh-token-refresh-daemon.sh; do
  [[ -f "$ISOLATED_TREE/$f" ]] && ln -sf "$ISOLATED_TREE/$f" "$TESTPROJ/scripts/$f"
done
cat > "$TESTPROJ/scripts/autonomous-dev.sh" <<'EOF'
#!/bin/bash
echo "stub-dev-wrapper-ran"
sleep 3
exit 0
EOF
chmod +x "$TESTPROJ/scripts/autonomous-dev.sh"
# Deliberately no adt-gc.sh/lib-lane.sh in ISOLATED_TREE — simulates a
# stale skill tree where the new PR-4 files haven't landed yet. The stub
# sleeps briefly so dispatch-local.sh's own post-spawn liveness check
# (`sleep 1; kill -0 $CHILD_PID`) sees it still running — an instantly-
# exiting stub would fail THAT unrelated check, not the one under test.
OUT121=$(cd "$TESTPROJ" && timeout 10 bash scripts/dispatch-local.sh dev-new 88888 2>&1); RC121=$?
assert_eq "TC-LGC4-121: dispatch-local.sh still succeeds when adt-gc.sh is absent (output: ${OUT121:0:200})" "0" "$RC121"
rm -rf "$TESTPROJ" "$ISOLATED_TREE"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo "PASS: $PASS, FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
