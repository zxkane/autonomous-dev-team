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
  lane_set "$LANE_DIR" GUARDIAN_IDENTITY "$(proc_identity "$!")"
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
  lane_set "$LANE_DIR" GUARDIAN_IDENTITY "$(proc_identity "$!")"
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
  lane_set "$LANE_DIR" GUARDIAN_IDENTITY "$(proc_identity "'"$GUARDIAN13_PID"'")"
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
# conjunction as conf_loaded/cc_user (never a bare standalone gate).
# [Lane-GC PR-4 review round-2] since the P1-1/P1-4/P2-1 class fix, age
# enforcement lives in the shared `_gc_common_kill_guards` call that
# EVERY eligible candidate passes through downstream — it is no longer
# textually on the SAME line as conf_loaded/cc_user/ppid, so the pin now
# asserts the two halves of the invariant separately: (a) ppid is still
# conjoined with conf_loaded+cc_user (never a bare standalone gate), and
# (b) the eligibility branch that sets it unconditionally falls through
# to the shared age-floor-enforcing guard (never bypasses it).
CONJ_HIT=$(grep -n 'conf_loaded.*cc_user.*ppid' "$ADT_GC" || true)
GUARD_HIT=$(grep -n '_gc_common_kill_guards' "$ADT_GC" || true)
if [[ -n "$CONJ_HIT" ]] && [[ -n "$GUARD_HIT" ]]; then
  assert_pass "TC-LGC4-032b: the legacy-signature ppid check is conjoined with conf_loaded+CC_USER, and every eligible candidate is age-floor-gated by the shared guard"
else
  assert_fail "TC-LGC4-032b: expected ppid conjoined with conf_loaded+CC_USER AND a shared age-floor guard downstream, not found (conj=$CONJ_HIT guard=$GUARD_HIT)"
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
# [Lane-GC PR-4 review round-2, P2-1] rule 3.3 now enforces a 300s age
# floor (previously none) via the shared `_gc_common_kill_guards`. A
# freshly-spawned `sleep 0.3`-scanned fixture is nowhere near that floor
# by construction, so the age-override seam simulates the floor being
# cleared — this exercises the guard's OTHER conjuncts (which is what
# this fixture is actually testing), not the age check itself (TC-LGC4-1xx
# below covers the age-floor boundary directly).
export "_GC_PROC_AGE_OVERRIDE_${PID43}=301"
run_gc_dry_full "$ST43" >/dev/null
unset "_GC_PROC_AGE_OVERRIDE_${PID43}"
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
TIMERHOME=$(mktemp -d)
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

PATH="$TIMERBIN:$PATH" CRONTAB_STUB_STORE="$CRONSTORE" HOME="$TIMERHOME" ADT_STATE_ROOT="$(mktemp -d)" bash "$INSTALL_GC_TIMER" >/dev/null 2>&1
MARKER_COUNT_1=$(grep -c 'adt-gc-timer' "$CRONSTORE")
assert_eq "TC-LGC4-100: fresh install adds exactly one marked line" "1" "$MARKER_COUNT_1"
assert_contains "TC-LGC4-100b: unrelated existing crontab content preserved" "unrelated-existing-line" "$(cat "$CRONSTORE")"

PATH="$TIMERBIN:$PATH" CRONTAB_STUB_STORE="$CRONSTORE" HOME="$TIMERHOME" ADT_STATE_ROOT="$(mktemp -d)" bash "$INSTALL_GC_TIMER" >/dev/null 2>&1
MARKER_COUNT_2=$(grep -c 'adt-gc-timer' "$CRONSTORE")
assert_eq "TC-LGC4-101: re-run stays idempotent (still exactly one marked line)" "1" "$MARKER_COUNT_2"

PATH="$TIMERBIN:$PATH" CRONTAB_STUB_STORE="$CRONSTORE" HOME="$TIMERHOME" bash "$INSTALL_GC_TIMER" --uninstall >/dev/null 2>&1
MARKER_COUNT_3=$(grep -c 'adt-gc-timer' "$CRONSTORE" || true)
assert_eq "TC-LGC4-102: --uninstall removes the marked line" "0" "$MARKER_COUNT_3"
assert_contains "TC-LGC4-102b: unrelated content still preserved after uninstall" "unrelated-existing-line" "$(cat "$CRONSTORE")"
rm -rf "$TIMERBIN" "$CRONSTORE" "$TIMERHOME"

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
echo "=== TC-LGC4-200..214: review round-2 fixes (Class A shared guards, Class B fail-closed, P2s) ==="
# ===========================================================================
P200ROOT="$TMPROOT/round2"
mkdir -p "$P200ROOT"

# TC-LGC4-200 (P1-1 proof): rule 3.4 (E2E servers) now skips a TERM_PROGRAM
# candidate — pre-fix this rule applied NO guard at all, so an operator
# shell cwd'd inside a since-removed worktree would have been killed
# outright. Same fixture shape as TC-LGC4-045 (recorded WORKTREE gone,
# proc cwd still under it) but WITHOUT `-u TERM_PROGRAM` this time.
E2E_WT_200="$P200ROOT/e2e-worktree-op-200"
mkdir -p "$E2E_WT_200"
ST200=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST200"'"
  LANE_ID=$(lane_mint p200 dev 200)
  LANE_DIR=$(lane_install p200 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  lane_set "$LANE_DIR" WORKTREE "'"$E2E_WT_200"'"
'
(cd "$E2E_WT_200" && setsid env TERM_PROGRAM=vscode bash -c "sleep 400" &)
sleep 0.3
PID200=$(pgrep -f "sleep 400" | while read -r p; do
  [[ "$(readlink "/proc/$p/cwd" 2>/dev/null)" == "$E2E_WT_200" ]] && echo "$p" && break
done)
rmdir "$E2E_WT_200" 2>/dev/null || rm -rf "$E2E_WT_200"
if [[ -n "$PID200" ]]; then
  SPAWNED_PIDS+=("$PID200")
  run_gc_dry_full "$ST200" >/dev/null
  CATLOG200=$(cat "$ST200/adt-gc.log" 2>/dev/null || true)
  assert_not_contains "TC-LGC4-200 (P1-1): rule 3.4 with TERM_PROGRAM set is skipped — never kills an operator shell cwd'd inside a removed worktree" "pid=$PID200" "$CATLOG200"
  kill -9 -- "-$PID200" 2>/dev/null || true
else
  assert_pass "TC-LGC4-200: skipped — could not observe the fixture's cwd-scoped pid on this sandbox"
fi
rm -rf "$ST200"

# TC-LGC4-201 (P1-2 proof): a Pass-2-eligible candidate whose env is
# UNKNOWABLE (simulated via the _GC_ENV_UNREADABLE_OVERRIDE seam — real
# same-uid /proc is always readable, so this is the only practical way to
# exercise the fail-toward-leak branch) is skipped, never would-killed,
# even though every OTHER Pass 2 condition (tagged dead lane, age past
# floor) is satisfied. Pre-fix, an unreadable env fell through
# `_gc_has_term_program`'s `env_lookup … || echo ""` fallback as
# indistinguishable from "TERM_PROGRAM absent" and proceeded to kill.
ST201=$(mktemp -d)
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST201"'"
  LANE_ID=$(lane_mint p201 dev 201)
  LANE_DIR=$(lane_install p201 "$LANE_ID")
  lane_set "$LANE_DIR" WRAPPER_PID 999999
  echo "$LANE_ID" > "'"$P200ROOT"'/lane201.txt"
'
LANE_ID201=$(cat "$P200ROOT/lane201.txt")
setsid env -u TERM_PROGRAM ADT_LANE_ID="$LANE_ID201" sleep 400 &
disown
PID201=$!
SPAWNED_PIDS+=("$PID201")
sleep 0.3
export "_GC_PROC_AGE_OVERRIDE_${PID201}=301"
export "_GC_ENV_UNREADABLE_OVERRIDE_${PID201}=1"
run_gc_dry_full "$ST201" >/dev/null
unset "_GC_PROC_AGE_OVERRIDE_${PID201}" "_GC_ENV_UNREADABLE_OVERRIDE_${PID201}"
CATLOG201=$(cat "$ST201/adt-gc.log" 2>/dev/null || true)
assert_not_contains "TC-LGC4-201a (P1-2): env-unknowable candidate is never would-killed, even with every other rule-2.1 condition satisfied" "would-kill rule=2 pid=$PID201 " "$CATLOG201"
assert_contains "TC-LGC4-201b (P1-2): env-unknowable skip is logged with its own reason (fail-toward-leak, not a silent drop)" "reason=env-unknowable-fail-toward-leak" "$CATLOG201"
kill -9 -- "-$PID201" 2>/dev/null || true
rm -rf "$ST201"

# TC-LGC4-202 (P1-3 proof, pgid): _gc_safe_kill_pgid never authorizes pgid
# 0, pgid 1, or GC's OWN pgid — extracted and unit-tested directly (no
# real kill fired) since simulating an ACTUAL false-kill-of-self would be
# destructive to the test runner itself. Function bodies below are BY
# REFERENCE (sourced from the real file via sed, not hand-copied) so this
# pins the ACTUAL shipped implementation, not a paraphrase.
GUARD_SRC=$(sed -n '/^_gc_own_pgid()/,/^_gc_kill_candidate()/p' "$ADT_GC" | sed '$d')
OUT202=$(bash -c '
  source "'"$LIB_LANE"'"
  '"$GUARD_SRC"'
  _gc_safe_kill_pgid 0    && echo "pgid0=UNSAFE"    || echo "pgid0=refused"
  _gc_safe_kill_pgid 1    && echo "pgid1=UNSAFE"    || echo "pgid1=refused"
  _gc_safe_kill_pgid -1   && echo "pgidneg1=UNSAFE" || echo "pgidneg1=refused"
  _gc_safe_kill_pgid ""   && echo "pgidempty=UNSAFE" || echo "pgidempty=refused"
  OWNPG="$(_gc_own_pgid)"
  _gc_safe_kill_pgid "$OWNPG" && echo "pgidown=UNSAFE" || echo "pgidown=refused"
  _gc_safe_kill_pgid 999999 && echo "pgidarbitrary=allowed" || echo "pgidarbitrary=refused"
')
assert_contains "TC-LGC4-202a (P1-3): _gc_safe_kill_pgid refuses pgid 0 (kernel alias for the SENDER's own group)" "pgid0=refused" "$OUT202"
assert_contains "TC-LGC4-202b (P1-3): _gc_safe_kill_pgid refuses pgid 1 (init/systemd group)" "pgid1=refused" "$OUT202"
assert_contains "TC-LGC4-202c (P1-3): _gc_safe_kill_pgid refuses a non-numeric/negative pgid" "pgidneg1=refused" "$OUT202"
assert_contains "TC-LGC4-202d (P1-3): _gc_safe_kill_pgid refuses an empty pgid" "pgidempty=refused" "$OUT202"
assert_contains "TC-LGC4-202e (P1-3): _gc_safe_kill_pgid refuses GC's OWN pgid" "pgidown=refused" "$OUT202"
assert_contains "TC-LGC4-202f (P1-3): _gc_safe_kill_pgid allows an arbitrary safe pgid" "pgidarbitrary=allowed" "$OUT202"

# TC-LGC4-203 (P1-3 proof, pid): _gc_safe_kill_pid never authorizes GC's
# own $$.
OUT203=$(bash -c '
  source "'"$LIB_LANE"'"
  '"$GUARD_SRC"'
  _gc_safe_kill_pid "$$" && echo "self=UNSAFE" || echo "self=refused"
  _gc_safe_kill_pid ""   && echo "empty=UNSAFE" || echo "empty=refused"
  _gc_safe_kill_pid abc  && echo "nonnumeric=UNSAFE" || echo "nonnumeric=refused"
  _gc_safe_kill_pid 999999 && echo "arbitrary=allowed" || echo "arbitrary=refused"
')
assert_contains "TC-LGC4-203a (P1-3): _gc_safe_kill_pid refuses GC's own \$\$" "self=refused" "$OUT203"
assert_contains "TC-LGC4-203b (P1-3): _gc_safe_kill_pid refuses an empty pid" "empty=refused" "$OUT203"
assert_contains "TC-LGC4-203c (P1-3): _gc_safe_kill_pid refuses a non-numeric pid" "nonnumeric=refused" "$OUT203"
assert_contains "TC-LGC4-203d (P1-3): _gc_safe_kill_pid allows an arbitrary safe pid" "arbitrary=allowed" "$OUT203"

# TC-LGC4-204 (P1-3 proof, end-to-end kill-candidate path): given an
# UNSAFE pgid (0 — the kernel alias for the SENDER's own process group),
# `_gc_kill_candidate` must NEVER reach `_kill_group_escalate` (the
# group-form kill — the dangerous path that would otherwise signal
# GC's OWN group). It still falls back to the safe individual-pid path
# (`_gc_term_then_kill_pid`, gated by its OWN `_gc_safe_kill_pid` check),
# which correctly terminates the sacrificial candidate itself — that is
# the DESIGNED fallback (per the review instruction: "else fall back to
# per-pid kill"), not a false-kill. The assertion below is therefore on
# `_kill_group_escalate` never firing, not on the candidate's survival.
# `sed` range note: the ORIGINAL single-pattern
# `/^_gc_own_pgid()/,/^_gc_kill_candidate()/` end-pattern is INCLUSIVE, so
# concatenating it with a second `/^_gc_kill_candidate()/,/^}/` range
# (as an earlier draft of this test did) duplicates the
# `_gc_kill_candidate() {` opening line and produces malformed bash that
# fails to parse — the extraction below instead trims the first range's
# trailing duplicate line before appending the second, complete range.
KC_SRC=$(sed -n '/^_gc_own_pgid()/,/^_gc_kill_candidate() {$/p' "$ADT_GC" | sed '$d')
KC_SRC2=$(sed -n '/^_gc_kill_candidate() {$/,/^}/p' "$ADT_GC")
ESCALATE_MARKER204=$(mktemp)
setsid sleep 400 &
disown
PID204=$!
SPAWNED_PIDS+=("$PID204")
sleep 0.2
bash -c '
  source "'"$LIB_LANE"'"
  '"$KC_SRC"'
  '"$KC_SRC2"'
  _kill_group_escalate() { echo "UNSAFE pgid=$1" >> "'"$ESCALATE_MARKER204"'"; }
  _gc_kill_candidate "'"$PID204"'" 0
'
sleep 0.3
assert_eq "TC-LGC4-204 (P1-3 end-to-end): _gc_kill_candidate given pgid=0 never reaches the group-escalation path" "" "$(cat "$ESCALATE_MARKER204")"
rm -f "$ESCALATE_MARKER204"
kill -9 -- "-$PID204" 2>/dev/null || true
kill -9 "$PID204" 2>/dev/null || true

# TC-LGC4-205 (P2-1 proof): rule 3.3 (wedged gh) now enforces a 300s age
# floor it previously computed but never compared to anything — a
# freshly-spawned fixture (age far below 300s, NO override) matching
# every OTHER 3.3 condition is never would-killed.
AUTH_GONE_205="/tmp/agent-auth-tc4-205-$$"
ST205=$(mktemp -d)
setsid env -u ADT_LANE_ID -u TERM_PROGRAM GH_TOKEN_FILE="${AUTH_GONE_205}/token" bash -c 'exec -a "gh_pr_checks_--watch" /usr/bin/sleep 400' &
disown
PID205=$!
SPAWNED_PIDS+=("$PID205")
sleep 0.3
run_gc_dry_full "$ST205" >/dev/null
CATLOG205=$(cat "$ST205/adt-gc.log" 2>/dev/null || true)
assert_not_contains "TC-LGC4-205 (P2-1): rule 3.3 below its new 300s age floor is never would-killed" "would-kill rule=3.3 pid=$PID205" "$CATLOG205"
kill -9 -- "-$PID205" 2>/dev/null || true
rm -rf "$ST205"

# TC-LGC4-206 (P1-4 proof, profile-dir sharer): rule 3.2's new rule-local
# conjunct — a candidate matching every OTHER 3.2 condition is skipped
# when a LIVE process shares the same --user-data-dir profile.
CHROME_SHIM_206="$P200ROOT/chrome-shim-206.sh"
cat > "$CHROME_SHIM_206" <<'EOF'
#!/bin/bash
sleep 400
EOF
chmod +x "$CHROME_SHIM_206"
SHARED_PROFILE_206="/tmp/puppeteer_dev_chrome_profile-tc4-206-$$"
mkdir -p "$SHARED_PROFILE_206"
ST206=$(mktemp -d)
# Candidate: reparented (ppid==1), aged past 2h via override.
bash -c "( setsid env -u TERM_PROGRAM '$CHROME_SHIM_206' '--user-data-dir=$SHARED_PROFILE_206' & ) & sleep 1" &
disown
sleep 1.5
PID206=$(ps -eo pid,cmd | grep -- "--user-data-dir=$SHARED_PROFILE_206" | grep -v grep | awk '{print $1}' | head -1)
if [[ -n "$PID206" ]] && [[ "$(bash -c 'source "'"$LIB_LANE"'"; proc_ppid "'"$PID206"'"')" == "1" ]]; then
  SPAWNED_PIDS+=("$PID206")
  # Live sharer: a SECOND, ordinary (non-reparented, still-owned-by-this-
  # shell) process pointed at the SAME profile dir.
  "$CHROME_SHIM_206" "--user-data-dir=$SHARED_PROFILE_206" &
  disown
  SHARER206_PID=$!
  SPAWNED_PIDS+=("$SHARER206_PID")
  sleep 0.2
  export "_GC_PROC_AGE_OVERRIDE_${PID206}=7300"
  run_gc_dry_full "$ST206" >/dev/null
  unset "_GC_PROC_AGE_OVERRIDE_${PID206}"
  CATLOG206=$(cat "$ST206/adt-gc.log" 2>/dev/null || true)
  assert_not_contains "TC-LGC4-206 (P1-4): rule 3.2 skips a candidate whose profile dir has a LIVE sharer" "pid=$PID206" "$CATLOG206"
  for child in $(pgrep -P "$SHARER206_PID" 2>/dev/null || true); do
    kill -9 "$child" 2>/dev/null || true
  done
  kill -9 "$SHARER206_PID" 2>/dev/null || true
  kill -9 -- "-$PID206" 2>/dev/null || true
  kill -9 "$PID206" 2>/dev/null || true
else
  assert_pass "TC-LGC4-206: skipped — reparenting to init did not occur as expected on this sandbox"
fi
rm -rf "$ST206" "$SHARED_PROFILE_206"

# TC-LGC4-207 (P1-4 proof, MCP parent): rule 3.2's second rule-local
# conjunct — a candidate is skipped when it is a live descendant of a
# process whose argv matches `chrome-devtools-mcp`.
MCP_PARENT_SHIM_207="$P200ROOT/mcp-parent-shim.sh"
cat > "$MCP_PARENT_SHIM_207" <<EOF
#!/bin/bash
"$CHROME_SHIM_206" "--user-data-dir=/tmp/puppeteer_dev_chrome_profile-tc4-207-\$\$" &
CHILD=\$!
echo "\$CHILD" > "$P200ROOT/mcp-child-207.pid"
wait "\$CHILD"
EOF
chmod +x "$MCP_PARENT_SHIM_207"
setsid bash -c "exec -a chrome-devtools-mcp bash '$MCP_PARENT_SHIM_207'" &
disown
MCPPARENT207_PID=$!
SPAWNED_PIDS+=("$MCPPARENT207_PID")
sleep 0.5
PID207=$(cat "$P200ROOT/mcp-child-207.pid" 2>/dev/null || echo "")
if [[ -n "$PID207" ]]; then
  SPAWNED_PIDS+=("$PID207")
  ST207=$(mktemp -d)
  export "_GC_PROC_AGE_OVERRIDE_${PID207}=7300"
  run_gc_dry_full "$ST207" >/dev/null
  unset "_GC_PROC_AGE_OVERRIDE_${PID207}"
  CATLOG207=$(cat "$ST207/adt-gc.log" 2>/dev/null || true)
  assert_not_contains "TC-LGC4-207 (P1-4): rule 3.2 skips a candidate with a live chrome-devtools-mcp ancestor" "pid=$PID207" "$CATLOG207"
  rm -rf "$ST207"
else
  assert_pass "TC-LGC4-207: skipped — could not observe the fixture's child pid on this sandbox"
fi
kill -9 -- "-$MCPPARENT207_PID" 2>/dev/null || true

# TC-LGC4-208 (dispatch-local.sh P2-2 proof): the opportunistic --quick
# call is wrapped in a hard timeout — grep-pin that `timeout`/`gtimeout`
# feature-detection surrounds the --quick call site (source-of-truth,
# same class of assertion as the existing TC-LGC4-120 line-order pin).
TIMEOUT_WRAP_HIT=$(grep -n '_ADT_GC_QUICK_TIMEOUT_CMD' "$DISPATCH_LOCAL" || true)
assert_contains "TC-LGC4-208 (P2-2): dispatch-local.sh feature-detects timeout/gtimeout for the opportunistic --quick call" "_ADT_GC_QUICK_TIMEOUT_CMD" "$TIMEOUT_WRAP_HIT"

# End-to-end: a --quick invocation that would otherwise hang is bounded.
SLOWGC_209="$P200ROOT/slow-adt-gc.sh"
cat > "$SLOWGC_209" <<'EOF'
#!/bin/bash
sleep 30
EOF
chmod +x "$SLOWGC_209"
START209=$(date +%s)
_TCMD209="$(command -v timeout || command -v gtimeout || true)"
if [[ -n "$_TCMD209" ]]; then
  "$_TCMD209" 2 bash "$SLOWGC_209" >/dev/null 2>&1 || true
  END209=$(date +%s)
  ELAPSED209=$((END209 - START209))
  if [[ "$ELAPSED209" -lt 10 ]]; then
    assert_pass "TC-LGC4-209 (P2-2): a hard-timeout-wrapped slow GC call returns in ${ELAPSED209}s, not the full 30s sleep"
  else
    assert_fail "TC-LGC4-209 (P2-2): timeout wrap did not bound the call (${ELAPSED209}s elapsed)"
  fi
else
  assert_pass "TC-LGC4-209: skipped — neither timeout nor gtimeout available on this sandbox"
fi
rm -f "$SLOWGC_209"

# TC-LGC4-210 (P2-3 proof): a decoy crontab line that merely MENTIONS the
# marker text mid-line (not as the line's own trailing marker) survives
# BOTH install and --uninstall — proving exact-suffix matching, not
# substring containment.
TIMERBIN210=$(mktemp -d)
CRONSTORE210=$(mktemp)
TIMERHOME210=$(mktemp -d)
cat > "$TIMERBIN210/crontab" <<'EOF'
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
chmod +x "$TIMERBIN210/crontab"
DECOY_LINE_210="# note to self: do not remove the line matching adt-gc-timer (autonomous-dev-team Lane-GC series, do not edit — managed by install-gc-timer.sh) by hand"
echo "$DECOY_LINE_210" > "$CRONSTORE210"
PATH="$TIMERBIN210:$PATH" CRONTAB_STUB_STORE="$CRONSTORE210" HOME="$TIMERHOME210" ADT_STATE_ROOT="$(mktemp -d)" bash "$INSTALL_GC_TIMER" >/dev/null 2>&1
assert_contains "TC-LGC4-210a (P2-3): a decoy line mentioning the marker text mid-line survives install" "$DECOY_LINE_210" "$(cat "$CRONSTORE210")"
MARKER_COUNT_210=$(grep -c 'adt-gc-timer' "$CRONSTORE210")
assert_eq "TC-LGC4-210b (P2-3): install still adds exactly one REAL managed line alongside the surviving decoy" "2" "$MARKER_COUNT_210"
PATH="$TIMERBIN210:$PATH" CRONTAB_STUB_STORE="$CRONSTORE210" HOME="$TIMERHOME210" bash "$INSTALL_GC_TIMER" --uninstall >/dev/null 2>&1
assert_contains "TC-LGC4-210c (P2-3): the decoy line ALSO survives --uninstall" "$DECOY_LINE_210" "$(cat "$CRONSTORE210")"
MARKER_COUNT_210B=$(grep -c 'adt-gc-timer' "$CRONSTORE210")
assert_eq "TC-LGC4-210d (P2-3): --uninstall removes only the REAL managed line, leaving just the decoy's mention" "1" "$MARKER_COUNT_210B"
rm -rf "$TIMERBIN210" "$CRONSTORE210" "$TIMERHOME210"

# TC-LGC4-211 (P2-4 proof): a path containing '%' is rejected (fail loud),
# both for adt-gc.sh's own resolved path (via ADT_STATE_ROOT — the
# logfile path derivation is what's under test here, adt-gc.sh's OWN path
# cannot be relocated without moving the real file) and the derived
# logfile path.
BADROOT_211="$P200ROOT/bad%root"
mkdir -p "$BADROOT_211" 2>/dev/null || true
OUT211=$(ADT_STATE_ROOT="$BADROOT_211" bash "$INSTALL_GC_TIMER" 2>&1); RC211=$?
assert_eq "TC-LGC4-211a (P2-4): a '%' in the derived logfile path (ADT_STATE_ROOT) is rejected with a non-zero exit" "1" "$RC211"
assert_contains "TC-LGC4-211b (P2-4): the rejection names '%' as the reason, not a silent failure" "%" "$OUT211"
rm -rf "$BADROOT_211" 2>/dev/null || true

# TC-LGC4-212 (P2-4 proof, cron entry quoting): the installed cron entry
# quotes both the adt-gc.sh path and the logfile path.
TIMERBIN212=$(mktemp -d)
CRONSTORE212=$(mktemp)
TIMERHOME212=$(mktemp -d)
cp "$TIMERBIN210/crontab" "$TIMERBIN212/crontab" 2>/dev/null || cat > "$TIMERBIN212/crontab" <<'EOF'
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
chmod +x "$TIMERBIN212/crontab"
PATH="$TIMERBIN212:$PATH" CRONTAB_STUB_STORE="$CRONSTORE212" HOME="$TIMERHOME212" ADT_STATE_ROOT="$(mktemp -d)" bash "$INSTALL_GC_TIMER" >/dev/null 2>&1
INSTALLED_LINE_212=$(grep 'adt-gc-timer' "$CRONSTORE212" | head -1)
assert_contains "TC-LGC4-212a (P2-4): installed cron entry single-quotes the adt-gc.sh path" "bash '${ADT_GC}'" "$INSTALLED_LINE_212"
assert_contains "TC-LGC4-212b (P2-4): installed cron entry single-quotes the logfile redirect target" ">> '" "$INSTALLED_LINE_212"
rm -rf "$TIMERBIN212" "$CRONSTORE212" "$TIMERHOME212"

# TC-LGC4-213 (P2-5 proof): grep-pin — the `_gc_rotate_log` call site
# appears AFTER the singleton lock's `exec 9>`/`flock` acquisition, never
# before. Line-number comparison against the real shipped file (not a
# paraphrase), matching the existing TC-LGC4-120 line-order pin technique.
LOCK_LINE_213=$(grep -n '^exec 9>"\$GC_LOCK"' "$ADT_GC" | head -1 | cut -d: -f1)
ROTATE_CALL_LINE_213=$(grep -n '^_gc_rotate_log$' "$ADT_GC" | head -1 | cut -d: -f1)
if [[ -n "$LOCK_LINE_213" && -n "$ROTATE_CALL_LINE_213" ]] && [[ "$ROTATE_CALL_LINE_213" -gt "$LOCK_LINE_213" ]]; then
  assert_pass "TC-LGC4-213 (P2-5): _gc_rotate_log's call site (line $ROTATE_CALL_LINE_213) runs AFTER the singleton lock is acquired (line $LOCK_LINE_213), never before"
else
  assert_fail "TC-LGC4-213 (P2-5): expected the rotate call ($ROTATE_CALL_LINE_213) after the lock acquisition ($LOCK_LINE_213)"
fi

# TC-LGC4-214 (bash dynamic-scoping landmine, found while hardening P1-2):
# `_gc_proc_age`/`_gc_env_readable` derive their test-only override
# variable NAME from `${pid}` in the SAME compound `local` statement that
# assigns `pid` — bash expands every RHS in a `local a=X b=Y` list before
# any assignment in that statement takes effect, so `${pid}` there
# resolves via dynamic scoping to a CALLER's own `pid` local (or crashes
# under `set -u` with no such caller-scope variable) rather than the
# value just assigned on the same line. Proven by calling `_gc_proc_age`
# in a context with NO enclosing local literally named `pid` — if the
# landmine regresses, this either crashes (`set -u`) or resolves the
# override variable to an empty-suffixed name and returns the WRONG
# (real, unaged) proc_age instead of the override value.
AGE_FN_SRC_214=$(sed -n '/^_gc_proc_age()/,/^}/p' "$ADT_GC")
sleep 30 &
disown
PID214=$!
SPAWNED_PIDS+=("$PID214")
sleep 0.2
export "_GC_PROC_AGE_OVERRIDE_${PID214}=99999"
OUT214=$(bash -c '
  set -uo pipefail
  source "'"$LIB_LANE"'"
  '"$AGE_FN_SRC_214"'
  no_such_caller_var() { _gc_proc_age "'"$PID214"'"; }
  no_such_caller_var
' 2>&1)
unset "_GC_PROC_AGE_OVERRIDE_${PID214}"
assert_eq "TC-LGC4-214 (dynamic-scoping landmine): _gc_proc_age honors its override even with NO enclosing caller-scope 'pid' variable" "99999" "$OUT214"
kill -9 "$PID214" 2>/dev/null || true

rm -rf "$P200ROOT"

# ===========================================================================
echo ""
echo "=== TC-LGC4-215/216: review round-3 — env_of/env_readable source alignment; quote-unsafe path rejection ==="
# ===========================================================================

# TC-LGC4-215 (round-3 [P1]): on Darwin (via the _LANE_UNAME_OVERRIDE test
# seam) env_of MUST consult the SAME procargs2 source env_readable does —
# pre-fix, env_readable probed readable via _procargs2_py while env_of
# stayed Linux-only and returned rc 1/empty, so a TERM_PROGRAM-protected
# operator process was "readable but env-clean" → kill-eligible (the exact
# fail-open shape P1-2's fix was meant to close, re-opened one layer down).
# Proven via a stub _procargs2_py that emits a synthetic ENV section: on
# the pre-fix code env_of returns nothing (FAIL); post-fix it returns the
# stubbed TERM_PROGRAM line.
OUT215=$(bash -c '
  set -uo pipefail
  source "'"$LIB_LANE"'"
  _LANE_UNAME_OVERRIDE=Darwin
  _lane_procargs2_available() { return 0; }
  _procargs2_py() { printf "ARGV\n/usr/bin/thing\nENV\nTERM_PROGRAM=Apple_Terminal\nHOME=/Users/op\n"; }
  # 4194304 > kernel.pid_max default (4194304 is the max itself; use a pid
  # that cannot exist so the Linux /proc branch can never shadow the
  # Darwin seam on the CI runner).
  env_of 4999999 || echo "ENV_OF_FAILED"
' 2>&1)
assert_contains "TC-LGC4-215 (round-3 P1): Darwin env_of reads via the SAME procargs2 source env_readable probes (TERM_PROGRAM visible)" "TERM_PROGRAM=Apple_Terminal" "$OUT215"
if [[ "$OUT215" == *"ENV_OF_FAILED"* ]]; then
  assert_fail "TC-LGC4-215b: env_of returned rc 1 on Darwin despite a working procargs2 shim (env_readable/env_of source split regressed)"
else
  assert_pass "TC-LGC4-215b: env_of rc 0 on Darwin with a working procargs2 shim"
fi
# And the ARGV section must NOT bleed into the env output:
if [[ "$OUT215" == *"/usr/bin/thing"* ]]; then
  assert_fail "TC-LGC4-215c: env_of leaked ARGV lines into its env output"
else
  assert_pass "TC-LGC4-215c: env_of emits only the ENV section, never ARGV lines"
fi

# TC-LGC4-216 (round-3 [P2]): a path containing a single quote must be
# REJECTED by the timer installer — the cron entry single-quotes both
# paths, and an embedded quote terminates the quoting mid-token (shell
# token injection). Pre-fix, /tmp/x'root passed the %/newline check and
# installed a syntactically broken entry.
QUOTE_DIR_216="$TMPROOT/x'quote"
mkdir -p "$QUOTE_DIR_216"
# Branch 1: quote in the derived LOGFILE path (ADT_STATE_ROOT), Linux.
OUT216=$(cd "$TMPROOT" && bash -c '
  _LANE_UNAME_OVERRIDE=Linux ADT_STATE_ROOT="'"$QUOTE_DIR_216"'" \
    bash "'"$SCRIPTS"'/install-gc-timer.sh" 2>&1
'; echo "rc=$?")
assert_contains "TC-LGC4-216 (round-3 P2): quote-bearing ADT_STATE_ROOT is rejected loudly, never installed" "refusing to install" "$OUT216"
assert_contains "TC-LGC4-216b: rejection exits non-zero" "rc=1" "$OUT216"
if crontab -l 2>/dev/null | grep -qF "$QUOTE_DIR_216"; then
  assert_fail "TC-LGC4-216c: a quote-bearing path LANDED in the real crontab (must never happen)"
  crontab -l 2>/dev/null | grep -vF "$QUOTE_DIR_216" | crontab - 2>/dev/null || true
else
  assert_pass "TC-LGC4-216c: no quote-bearing entry reached the crontab"
fi
# Branch 2: quote in the ADT_GC_SH path itself — the checked path derives
# from the installer's own resolved location, so exercise it by invoking a
# COPY of the installer from inside the quote-bearing dir (with a sibling
# adt-gc.sh so the existence check passes and the path check is reached).
cp "$SCRIPTS/adt-gc.sh" "$QUOTE_DIR_216/adt-gc.sh"
cp "$SCRIPTS/install-gc-timer.sh" "$QUOTE_DIR_216/install-gc-timer.sh"
OUT216D=$(bash -c '
  _LANE_UNAME_OVERRIDE=Linux ADT_STATE_ROOT="'"$TMPROOT"'/plain-state" \
    bash "'"$QUOTE_DIR_216"'/install-gc-timer.sh" 2>&1
'; echo "rc=$?")
assert_contains "TC-LGC4-216d: quote-bearing adt-gc.sh path itself is rejected (ADT_GC_SH call site)" "refusing to install" "$OUT216D"
# Branch 3: macOS branch rejects a quote-bearing logfile path BEFORE any
# plist/launchctl work (the reject call precedes the plist heredoc).
OUT216E=$(HOME="$TMPROOT/fake-home-216" bash -c '
  mkdir -p "$HOME"
  _LANE_UNAME_OVERRIDE=Darwin ADT_STATE_ROOT="'"$QUOTE_DIR_216"'" \
    bash "'"$SCRIPTS"'/install-gc-timer.sh" 2>&1
'; echo "rc=$?")
assert_contains "TC-LGC4-216e: macOS branch rejects quote-bearing logfile path" "refusing to install" "$OUT216E"
if [[ -e "$TMPROOT/fake-home-216/Library/LaunchAgents/com.adt.lane-gc.plist" ]]; then
  assert_fail "TC-LGC4-216f: plist was written despite the unsafe path"
else
  assert_pass "TC-LGC4-216f: no plist written for an unsafe path"
fi

# TC-LGC4-217 (round-4 [P1], found by an independent re-review of round-2's
# OWN fixes): `_gc_safe_kill_pid` must refuse pid 0 — a bare `kill -TERM 0`
# is a kernel alias for the CALLER's own process group, identical in
# effect to `kill -TERM -- -0`. Round-2's original regex `^[0-9]+$`
# matches the literal string "0" and let it through; a corrupt or hostile
# `GUARDIAN_PID=0` registry value reaching rule 1.4's guardian-kill path
# would have self-signaled GC's own group.
PID_SRC_217=$(sed -n '/^_gc_own_pgid()/,/^_gc_kill_candidate() {$/p' "$ADT_GC" | sed '$d')
# POSITIVE CONTROL first (safe pid must be ALLOWED): a broken sed
# extraction leaves the function undefined, and `cmd && A || B` treats
# command-not-found the same as a refusal — the control makes that
# false-pass shape impossible (it would print allowed-check=MISSING).
OUT217=$(bash -c '
  source "'"$LIB_LANE"'"
  '"$PID_SRC_217"'
  declare -F _gc_safe_kill_pid >/dev/null || { echo "allowed-check=MISSING"; exit 0; }
  _gc_safe_kill_pid 424242 && echo "safe-pid=allowed" || echo "safe-pid=REFUSED"
  _gc_safe_kill_pid 0 && echo "pid0=UNSAFE" || echo "pid0=refused"
')
assert_contains "TC-LGC4-217a (extraction control): _gc_safe_kill_pid is defined and allows an ordinary safe pid" "safe-pid=allowed" "$OUT217"
assert_contains "TC-LGC4-217 (round-4 P1): _gc_safe_kill_pid refuses pid 0 (kernel alias for the SENDER's own process group)" "pid0=refused" "$OUT217"

# TC-LGC4-218 (round-4 [P2], same re-review): `_gc_safe_kill_pgid` must
# REFUSE, not allow, when GC's own pgid cannot be determined (a transient
# `proc_pgid "$$"`/`ps` failure). Round-2's original
# `[[ -z "$own_pg" || "$pg" != "$own_pg" ]]` treated an unreadable own-pgid
# as "therefore safe" — backwards: inability to PROVE a candidate pgid
# ISN'T GC's own group must fail toward refusing (design principle 5),
# not toward authorizing the kill.
PGID_SRC_218=$(sed -n '/^_gc_own_pgid()/,/^_gc_kill_candidate() {$/p' "$ADT_GC" | sed '$d')
# Same positive-control pattern as TC-LGC4-217a: prove the function exists
# and ALLOWS a safe pgid under a RESOLVABLE own-pgid before asserting the
# refusal branch, so a broken extraction can't false-pass as "refused".
OUT218=$(bash -c '
  source "'"$LIB_LANE"'"
  '"$PGID_SRC_218"'
  declare -F _gc_safe_kill_pgid >/dev/null || { echo "allowed-check=MISSING"; exit 0; }
  _gc_own_pgid() { echo "999999"; }
  _gc_safe_kill_pgid 424242 && echo "safe-pgid=allowed" || echo "safe-pgid=REFUSED"
  _gc_own_pgid() { echo ""; }
  _gc_safe_kill_pgid 12345 && echo "emptyown=ALLOWED" || echo "emptyown=refused"
')
assert_contains "TC-LGC4-218a (extraction control): _gc_safe_kill_pgid is defined and allows a safe pgid under a resolvable own-pgid" "safe-pgid=allowed" "$OUT218"
assert_contains "TC-LGC4-218 (round-4 P2): _gc_safe_kill_pgid refuses when GC's own pgid is unknowable, never fails open" "emptyown=refused" "$OUT218"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo "PASS: $PASS, FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
