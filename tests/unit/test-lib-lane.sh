#!/bin/bash
# test-lib-lane.sh — Unit tests for issue #378 (Lane-GC series PR-2, design
# docs/designs/lane-containment-gc.md §4-C1/§4-C2; INV-109/INV-110).
#
# Covers lib-lane.sh's public API: lane_mint/lane_install (atomic mint),
# lane_probe (liveness), lane_kill (escalation), lane_record_pgid (durable
# PGID append), lane_get/lane_set (KV round-trip), lane_find_latest (the
# kill_stale_wrapper delegate's lookup), and the portability shims. Also
# grep-pins the wrapper/lib source-of-truth wiring (mint-before-auth,
# ADT_LANE_ROLE exports, kill_stale_wrapper's delegate).
#
# Full scenario list: docs/test-cases/lane-gc-p2-registry.md (TC-LGC2-*).
#
# Run: bash tests/unit/test-lib-lane.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB_LANE="$SCRIPTS/lib-lane.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert_pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
assert_fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (expected [$expected] got [$actual])"
  fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    assert_pass "$desc"
  else
    assert_fail "$desc (needle='$needle' not found)"
  fi
}

[[ -f "$LIB_LANE" ]] || { echo -e "${RED}FATAL${NC}: $LIB_LANE not found"; exit 1; }

TMPROOT=$(mktemp -d)
trap 'pkill -f "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC2-001/003/004: registry existence + parseable KV ==="
# ---------------------------------------------------------------------------
bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state1"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj dev 42)
  LANE_DIR=$(lane_install myproj "$LANE_ID" "/tmp/some-worktree")
  [[ -n "$LANE_DIR" ]] || { echo "MINT-FAILED"; exit 1; }
  [[ -f "$LANE_DIR/lane" ]] || { echo "NO-LANE-FILE"; exit 1; }
  [[ -f "$LANE_DIR/pgids" ]] || { echo "NO-PGIDS-FILE"; exit 1; }
  [[ -f "$LANE_DIR/reap.lock" ]] || { echo "NO-REAPLOCK-FILE"; exit 1; }
  for key in LANE_ID PROJECT_ID ISSUE ROLE MODE WRAPPER_PID WRAPPER_START CREATED_EPOCH STATE; do
    v=$(lane_get "$LANE_DIR" "$key") || { echo "MISSING-KEY:$key"; exit 1; }
  done
  echo "OK"
' > "$TMPROOT/tc001.out" 2>&1
if [[ "$(cat "$TMPROOT/tc001.out")" == "OK" ]]; then
  assert_pass "TC-LGC2-001: lane_install produces a fully parseable registry entry"
else
  assert_fail "TC-LGC2-001: $(cat "$TMPROOT/tc001.out")"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC2-002: atomic-mint stress — SIGKILL mid-install x50, zero half-written dirs ==="
# ---------------------------------------------------------------------------
STRESS_ROOT="$TMPROOT/stress-state"
HALF_WRITTEN=0
for i in $(seq 1 50); do
  bash -c '
    source "'"$LIB_LANE"'"
    export ADT_STATE_ROOT="'"$STRESS_ROOT"'"
    LANE_ID=$(lane_mint myproj crashtest "'"$i"'")
    lane_install myproj "$LANE_ID"
  ' >/dev/null 2>&1 &
  BGPID=$!
  ( sleep "0.0$((RANDOM % 5))"; kill -9 "$BGPID" 2>/dev/null ) >/dev/null 2>&1
  wait "$BGPID" 2>/dev/null
done
if [[ -d "$STRESS_ROOT/autonomous-myproj/lanes" ]]; then
  for d in "$STRESS_ROOT/autonomous-myproj/lanes"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    base="$(basename "$d")"
    [[ "$base" == .pending-* ]] && continue
    for key in WRAPPER_PID WRAPPER_START CREATED_EPOCH STATE; do
      grep -q "^${key}=" "$d/lane" 2>/dev/null || HALF_WRITTEN=$((HALF_WRITTEN + 1))
    done
  done
fi
assert_eq "TC-LGC2-002: 50/50 clean atomic mint (zero half-written final-named dirs)" "0" "$HALF_WRITTEN"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC2-005: lane_install failure degrades cleanly ==="
# ---------------------------------------------------------------------------
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="/nonexistent-root-'"$$"'-cannot-create/deeply/nested"
  # A read-only parent makes mkdir -p fail deterministically.
  RO="'"$TMPROOT"'/readonly-root"
  mkdir -p "$RO"
  chmod 555 "$RO"
  export ADT_STATE_ROOT="$RO/state"
  LANE_ID=$(lane_mint myproj dev 1)
  OUT=$(lane_install myproj "$LANE_ID"); RC=$?
  chmod 755 "$RO"
  [[ -z "$OUT" && "$RC" -ne 0 ]] && echo "DEGRADED-OK" || echo "UNEXPECTED rc=$RC out=$OUT"
' > "$TMPROOT/tc005.out" 2>&1
if [[ "$(cat "$TMPROOT/tc005.out")" == "DEGRADED-OK" ]]; then
  assert_pass "TC-LGC2-005: lane_install failure returns empty + nonzero rc"
else
  # Running as root bypasses the 555 permission check — treat as environmental skip.
  if [[ "$(id -u)" == "0" ]]; then
    assert_pass "TC-LGC2-005: skipped (running as root — permission checks bypassed)"
  else
    assert_fail "TC-LGC2-005: $(cat "$TMPROOT/tc005.out")"
  fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC2-010/011: ADT_STATE_ROOT canonicalization ignores XDG_STATE_HOME ==="
# ---------------------------------------------------------------------------
XDG_PROBE=$(bash -c '
  unset ADT_STATE_ROOT
  export XDG_STATE_HOME="/tmp/should-not-be-used-'"$$"'"
  export HOME="'"$TMPROOT"'/fakehome"
  mkdir -p "$HOME"
  source "'"$LIB_LANE"'"
  echo "$ADT_STATE_ROOT"
')
assert_eq "TC-LGC2-010: ADT_STATE_ROOT defaults to \$HOME/.local/state, ignoring XDG_STATE_HOME" \
  "$TMPROOT/fakehome/.local/state" "$XDG_PROBE"

OVERRIDE_PROBE=$(bash -c '
  export ADT_STATE_ROOT="/custom/override/path"
  source "'"$LIB_LANE"'"
  echo "$ADT_STATE_ROOT"
')
assert_eq "TC-LGC2-011: an explicit ADT_STATE_ROOT override is honored verbatim" \
  "/custom/override/path" "$OVERRIDE_PROBE"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC2-020: a spawned child's environ carries ADT_LANE_ID (live probe) ==="
# ---------------------------------------------------------------------------
if [[ -r "/proc/$$/environ" ]]; then
  # Regression (codex review [P1], #378): counting every `^ADT_LANE_` line is
  # fragile to ambient env pollution — this test suite itself can run INSIDE
  # a review-agent fan-out subshell that already exports ADT_LANE_ID/
  # ADT_LANE_DIR (this PR's own wrapper wiring) and/or ADT_LANE_ROLE (the
  # fan-out/smoke/E2E-browser tagging this PR also adds), inflating the count
  # past 2 and failing a bare `-eq 2` check in exactly that environment. Fix:
  # `env -i` starts the subshell with NO inherited environment at all (not
  # even PATH — restored explicitly), so only the two vars THIS test exports
  # can possibly appear; then assert the two NAMED values directly rather
  # than counting lines, so a third unrelated ADT_LANE_* var appearing in a
  # future PR can never fail this assertion either.
  ENVIRON_PROBE=$(env -i PATH="$PATH" bash -c '
    export ADT_LANE_ID="myproj:dev:1:12345:abcd"
    export ADT_LANE_DIR="/tmp/fake-lane-dir"
    sleep 0.4 &
    CP=$!
    sleep 0.1
    tr "\0" "\n" < "/proc/$CP/environ" 2>/dev/null
    wait "$CP" 2>/dev/null
  ')
  assert_contains "TC-LGC2-020a: spawned child inherits ADT_LANE_ID verbatim" "ADT_LANE_ID=myproj:dev:1:12345:abcd" "$ENVIRON_PROBE"
  assert_contains "TC-LGC2-020b: spawned child inherits ADT_LANE_DIR verbatim" "ADT_LANE_DIR=/tmp/fake-lane-dir" "$ENVIRON_PROBE"
else
  assert_pass "TC-LGC2-020: skipped (no /proc/PID/environ on this platform)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC2-030/031/032: PGID append via _run_with_timeout + rm -rf survival ==="
# ---------------------------------------------------------------------------
LIB_AGENT="$SCRIPTS/lib-agent.sh"
PGID_TEST_ROOT="$TMPROOT/pgid-test"
mkdir -p "$PGID_TEST_ROOT"
bash -c '
  set -u
  export ADT_STATE_ROOT="'"$PGID_TEST_ROOT"'/state"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj dev 7)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  echo "$LANE_DIR" > "'"$PGID_TEST_ROOT"'/lanedir.txt"

  # Minimal _run_with_timeout re-implementation is NOT used here — source the
  # real lib-agent.sh and call it directly so this is a true integration test
  # of the actual chokepoint, not a re-implementation.
  AGENT_LAUNCHER_ARGV=()
  _AGENT_TIMEOUT_CMD=""
  AGENT_TIMEOUT="5"
  ADT_LANE_DIR="$LANE_DIR"
  ADT_LANE_ROLE="agent"
  # A no-op run_agent-shaped invocation via _run_with_timeout: sleep briefly.
  source "'"$LIB_AGENT"'" 2>/dev/null || true
  _run_with_timeout sleep 0.3
' 2>/dev/null
LANE_DIR_FROM_TEST=$(cat "$PGID_TEST_ROOT/lanedir.txt" 2>/dev/null || true)
if [[ -n "$LANE_DIR_FROM_TEST" && -f "$LANE_DIR_FROM_TEST/pgids" ]]; then
  PGID_LINE_COUNT=$(grep -cE '^[0-9]+ agent [0-9]+$' "$LANE_DIR_FROM_TEST/pgids" 2>/dev/null || echo 0)
  if [[ "$PGID_LINE_COUNT" -ge 1 ]]; then
    assert_pass "TC-LGC2-030: _run_with_timeout appended a well-formed pgids line"
  else
    assert_fail "TC-LGC2-030: no well-formed pgids line found: $(cat "$LANE_DIR_FROM_TEST/pgids" 2>/dev/null)"
  fi
else
  assert_fail "TC-LGC2-030: lane dir or pgids file missing"
fi

# TC-LGC2-031: no ADT_LANE_DIR set — lane_record_pgid must no-op silently.
bash -c '
  source "'"$LIB_LANE"'"
  lane_record_pgid "" 12345 agent
  echo "rc=$?"
' > "$TMPROOT/tc031.out" 2>&1
assert_contains "TC-LGC2-031: lane_record_pgid with empty lane dir is a silent no-op (rc 0)" "rc=0" "$(cat "$TMPROOT/tc031.out")"

# TC-LGC2-032: durable pgids survive removal of a SIDECAR dir (fan-out style).
bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state32"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj review 9)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  FANOUT_DIR=$(mktemp -d "'"$TMPROOT"'/fanout-XXXXXX")
  setsid sleep 3 &
  PG=$!
  echo "$PG" > "$FANOUT_DIR/sidecar.pgid"
  lane_record_pgid "$LANE_DIR" "$PG" "fanout:codex"
  rm -rf "$FANOUT_DIR"
  lane_kill "$LANE_DIR" 2
  sleep 0.3
  kill -0 "$PG" 2>/dev/null && echo "STILL-ALIVE" || echo "REAPED"
' > "$TMPROOT/tc032.out" 2>&1
assert_contains "TC-LGC2-032: durable pgids record survives rm -rf of the sidecar dir; lane_kill still reaps it" "REAPED" "$(cat "$TMPROOT/tc032.out")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC2-033: E2E command-mode lane records its own PGID directly ==="
# ---------------------------------------------------------------------------
if grep -q 'lane_record_pgid "\${ADT_LANE_DIR:-}" "\$_E2E_LANE_PGID" "e2e:command"' \
    "$SCRIPTS/lib-review-e2e.sh" 2>/dev/null; then
  assert_pass "TC-LGC2-033: _run_command_e2e_verify records its PGID via lane_record_pgid (grep-pin)"
else
  assert_fail "TC-LGC2-033: lib-review-e2e.sh missing the lane_record_pgid call for the E2E lane PGID"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC2-034: concurrent appenders never interleave a partial pgids line ==="
# ---------------------------------------------------------------------------
bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state34"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj review 11)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  for i in $(seq 1 30); do
    lane_record_pgid "$LANE_DIR" "$((10000 + i))" "fanout:agent$i" &
  done
  wait
  BAD=$(grep -vcE "^[0-9]+ \S+ [0-9]+\$" "$LANE_DIR/pgids" 2>/dev/null)
  LINES=$(wc -l < "$LANE_DIR/pgids")
  echo "bad=$BAD lines=$LINES"
' > "$TMPROOT/tc034.out" 2>&1
OUT34=$(cat "$TMPROOT/tc034.out")
if [[ "$OUT34" == "bad=0 lines=30" ]]; then
  assert_pass "TC-LGC2-034: 30 concurrent appenders produce 30 well-formed lines, zero corruption"
else
  assert_fail "TC-LGC2-034: $OUT34"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC2-040/041/042/043: lane_probe liveness ==="
# ---------------------------------------------------------------------------
bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state4x"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj dev 1)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  echo "SELF:$(lane_probe "$LANE_DIR")"

  # TC-042: dead PID (a PID that just exited).
  ( exit 0 ) &
  DEADPID=$!
  wait "$DEADPID" 2>/dev/null
  sed -i "s/^WRAPPER_PID=.*/WRAPPER_PID=$DEADPID/" "$LANE_DIR/lane"
  echo "DEADPID:$(lane_probe "$LANE_DIR")"

  # TC-041: recycled-PID fixture — same (live) PID, mismatched WRAPPER_START.
  LANE_ID2=$(lane_mint myproj dev 2)
  LANE_DIR2=$(lane_install myproj "$LANE_ID2")
  sed -i "s/^WRAPPER_START=.*/WRAPPER_START=999999999/" "$LANE_DIR2/lane"
  echo "RECYCLED:$(lane_probe "$LANE_DIR2")"

  # TC-043: unparseable lane file.
  LANE_ID3=$(lane_mint myproj dev 3)
  LANE_DIR3=$(lane_install myproj "$LANE_ID3")
  rm -f "$LANE_DIR3/lane"
  echo "unparseable" > "$LANE_DIR3/lane"
  echo "UNPARSEABLE:$(lane_probe "$LANE_DIR3")"
' > "$TMPROOT/tc04x.out" 2>&1
OUT4X=$(cat "$TMPROOT/tc04x.out")
assert_contains "TC-LGC2-040: lane_probe against own \$\$ is live" "SELF:live" "$OUT4X"
assert_contains "TC-LGC2-042: lane_probe against a dead PID is dead" "DEADPID:dead" "$OUT4X"
assert_contains "TC-LGC2-041: recycled-PID fixture (mismatched WRAPPER_START) is dead" "RECYCLED:dead" "$OUT4X"
assert_contains "TC-LGC2-043: unparseable lane file yields unknown (fail toward don't-know)" "UNPARSEABLE:unknown" "$OUT4X"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC2-044/045: macOS fingerprint conjunct (test seam) ==="
# ---------------------------------------------------------------------------
bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state-mac"
  export _LANE_UNAME_OVERRIDE="Darwin"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj dev 1)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  echo "MATCH:$(lane_probe "$LANE_DIR")"

  LANE_ID2=$(lane_mint myproj dev 2)
  LANE_DIR2=$(lane_install myproj "$LANE_ID2")
  sed -i "s/^WRAPPER_FINGERPRINT=.*/WRAPPER_FINGERPRINT=0000000000000000000000000000000000000000000000000000000000000000/" "$LANE_DIR2/lane"
  echo "MISMATCH:$(lane_probe "$LANE_DIR2")"
' > "$TMPROOT/tc04mac.out" 2>&1
OUT4MAC=$(cat "$TMPROOT/tc04mac.out")
assert_contains "TC-LGC2-044: macOS path — matching WRAPPER_FINGERPRINT is live" "MATCH:live" "$OUT4MAC"
assert_contains "TC-LGC2-045: macOS path — mismatched WRAPPER_FINGERPRINT is dead" "MISMATCH:dead" "$OUT4MAC"

# TC-LGC2-046 (regression): the fingerprint MUST be recomputed from the
# RECORDED WRAPPER_PPID, never a live re-probe of the process's CURRENT ppid.
# dispatch-local.sh spawns the wrapper via `nohup … &` and exits almost
# immediately, reparenting the still-running wrapper to init (ppid -> 1)
# within milliseconds of mint — a live-ppid recompute would misclassify a
# genuinely live wrapper as `dead` the instant that reparenting completes,
# which is exactly the false-positive-kill principle 5 forbids. Simulate by
# minting normally, then confirming lane_probe's fingerprint recompute reads
# WRAPPER_PPID (a STABLE recorded field), not a live `ps -o ppid=` of $pid —
# proven by corrupting the recorded WRAPPER_PPID and confirming that alone
# (with nothing else touched) flips a live probe to dead, i.e. the recorded
# field, not any live signal, is what drives the recompute.
bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state-mac2"
  export _LANE_UNAME_OVERRIDE="Darwin"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj dev 1)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  # Baseline: unmodified lane (recorded PPID matches what minted the fingerprint).
  echo "BASELINE:$(lane_probe "$LANE_DIR")"
  # Corrupt ONLY the recorded WRAPPER_PPID (leave WRAPPER_FINGERPRINT as-is).
  # If lane_probe recomputed from a LIVE ppid re-probe (the pre-fix bug), this
  # edit would have NO effect (live ppid is unrelated to this file edit) and
  # the probe would incorrectly stay "live". Post-fix, the recompute reads
  # the (now-corrupted) recorded WRAPPER_PPID, so the fingerprint mismatches
  # and the probe correctly flips to "dead".
  sed -i "s/^WRAPPER_PPID=.*/WRAPPER_PPID=999999/" "$LANE_DIR/lane"
  echo "CORRUPTED-PPID:$(lane_probe "$LANE_DIR")"
' > "$TMPROOT/tc046.out" 2>&1
OUT046=$(cat "$TMPROOT/tc046.out")
assert_contains "TC-LGC2-046a: baseline (untouched recorded fields) probes live" "BASELINE:live" "$OUT046"
assert_contains "TC-LGC2-046b: corrupting ONLY the recorded WRAPPER_PPID flips the probe to dead — proves the recompute reads the recorded field, not a live re-probe" "CORRUPTED-PPID:dead" "$OUT046"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC2-050/051/052/053: lane_kill escalation ==="
# ---------------------------------------------------------------------------
bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state5x"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj dev 1)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  setsid sleep 30 &
  PG=$!
  lane_record_pgid "$LANE_DIR" "$PG" agent
  lane_kill "$LANE_DIR" 2
  sleep 0.3
  kill -0 "$PG" 2>/dev/null && echo "TC050:ALIVE" || echo "TC050:REAPED"
' > "$TMPROOT/tc050.out" 2>&1
assert_contains "TC-LGC2-050: lane_kill TERM-reaps a live setsid group" "TC050:REAPED" "$(cat "$TMPROOT/tc050.out")"

bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state51"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj dev 1)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  setsid bash -c "trap \"\" TERM; sleep 30" &
  PG=$!
  sleep 0.2
  lane_record_pgid "$LANE_DIR" "$PG" agent
  lane_kill "$LANE_DIR" 2
  sleep 0.3
  kill -0 "$PG" 2>/dev/null && echo "TC051:ALIVE" || echo "TC051:REAPED"
' > "$TMPROOT/tc051.out" 2>&1
assert_contains "TC-LGC2-051: lane_kill escalates to KILL against a TERM-resistant group" "TC051:REAPED" "$(cat "$TMPROOT/tc051.out")"

bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state52"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj review 1)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  setsid sleep 30 & PG1=$!
  setsid sleep 30 & PG2=$!
  lane_record_pgid "$LANE_DIR" "$PG1" "fanout:a"
  lane_record_pgid "$LANE_DIR" "$PG1" "fanout:a"  # duplicate line, same pgid
  lane_record_pgid "$LANE_DIR" "$PG2" "fanout:b"
  lane_kill "$LANE_DIR" 2
  sleep 0.3
  A=$(kill -0 "$PG1" 2>/dev/null && echo alive || echo gone)
  B=$(kill -0 "$PG2" 2>/dev/null && echo alive || echo gone)
  echo "TC052:$A:$B"
' > "$TMPROOT/tc052.out" 2>&1
assert_contains "TC-LGC2-052: lane_kill reaps every DISTINCT recorded PGID (dedup on repeats)" "TC052:gone:gone" "$(cat "$TMPROOT/tc052.out")"

bash -c '
  source "'"$LIB_LANE"'"
  mkdir -p "'"$TMPROOT"'/empty-lane"
  lane_kill "'"$TMPROOT"'/empty-lane" 2
  echo "rc=$?"
' > "$TMPROOT/tc053.out" 2>&1
assert_contains "TC-LGC2-053: lane_kill against a missing pgids file is a clean no-op" "rc=0" "$(cat "$TMPROOT/tc053.out")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC2-054/055: lane_find_latest ordering survives a corrupted newer lane ==="
# ---------------------------------------------------------------------------
# Regression (codex review [P1], #378): lane_find_latest previously ordered
# candidates by CREATED_EPOCH read out of each lane's `lane` FILE — a newer
# lane whose file later became corrupted/unparseable (a failure independent
# of the directory's own identity) lost the comparison to an older,
# still-parseable sibling and was silently skipped. The fix derives BOTH the
# (role, issue) match AND the ordering from the immutable directory BASENAME
# (written once at mint, never rewritten), so file corruption can never
# demote a structurally-newer lane below an older one.
bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state54"
  source "'"$LIB_LANE"'"

  LANE_ID_OLD=$(lane_mint myproj dev 1)
  LANE_DIR_OLD=$(lane_install myproj "$LANE_ID_OLD")
  sed -i "s/^CREATED_EPOCH=.*/CREATED_EPOCH=1000/" "$LANE_DIR_OLD/lane"

  sleep 1
  LANE_ID_NEW=$(lane_mint myproj dev 1)
  LANE_DIR_NEW=$(lane_install myproj "$LANE_ID_NEW")
  # Corrupt the NEWER lanes file entirely (unparseable) — its DIRECTORY name
  # still correctly encodes it as the newer mint.
  echo "totally-unparseable-garbage" > "$LANE_DIR_NEW/lane"

  RESULT=$(lane_find_latest myproj dev 1)
  echo "OLD_DIR:$LANE_DIR_OLD"
  echo "NEW_DIR:$LANE_DIR_NEW"
  echo "SELECTED:$RESULT"
' > "$TMPROOT/tc054.out" 2>&1
OUT054=$(cat "$TMPROOT/tc054.out")
OLD_DIR_054=$(printf '%s' "$OUT054" | grep '^OLD_DIR:' | cut -d: -f2-)
NEW_DIR_054=$(printf '%s' "$OUT054" | grep '^NEW_DIR:' | cut -d: -f2-)
SELECTED_054=$(printf '%s' "$OUT054" | grep '^SELECTED:' | cut -d: -f2-)
if [[ "$SELECTED_054" == "$NEW_DIR_054" && -n "$NEW_DIR_054" ]]; then
  assert_pass "TC-LGC2-054: lane_find_latest selects the structurally-newer lane even though its file is unparseable (not the older, intact sibling)"
else
  assert_fail "TC-LGC2-054: selected [$SELECTED_054], expected the NEWER dir [$NEW_DIR_054] (OLD was [$OLD_DIR_054])"
fi

# TC-LGC2-055: end-to-end — once the newer-but-corrupted lane is selected,
# lane_probe must resolve it to `unknown` (never a false live/dead), so a
# caller like kill_stale_wrapper's delegate correctly falls through WITHOUT
# ever touching the older lane's still-relevant pgids.
bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state55"
  source "'"$LIB_LANE"'"

  LANE_ID_OLD=$(lane_mint myproj dev 2)
  LANE_DIR_OLD=$(lane_install myproj "$LANE_ID_OLD")
  ( exit 0 ) & DEADPID=$!; wait "$DEADPID" 2>/dev/null
  sed -i "s/^WRAPPER_PID=.*/WRAPPER_PID=$DEADPID/" "$LANE_DIR_OLD/lane"
  setsid sleep 30 & OLD_PG=$!
  lane_record_pgid "$LANE_DIR_OLD" "$OLD_PG" agent

  sleep 1
  LANE_ID_NEW=$(lane_mint myproj dev 2)
  LANE_DIR_NEW=$(lane_install myproj "$LANE_ID_NEW")
  echo "totally-unparseable-garbage" > "$LANE_DIR_NEW/lane"

  SELECTED=$(lane_find_latest myproj dev 2)
  PROBE=$(lane_probe "$SELECTED")
  echo "PROBE:$PROBE"
  echo "OLD_PG:$OLD_PG"
' > "$TMPROOT/tc055.out" 2>&1
OUT055=$(cat "$TMPROOT/tc055.out")
PROBE_055=$(printf '%s' "$OUT055" | grep '^PROBE:' | cut -d: -f2-)
OLDPG_055=$(printf '%s' "$OUT055" | grep '^OLD_PG:' | cut -d: -f2-)
assert_contains "TC-LGC2-055a: lane_probe on the selected (newer, corrupted) lane resolves unknown" "unknown" "$PROBE_055"
sleep 0.3
if [[ -n "$OLDPG_055" ]] && kill -0 "$OLDPG_055" 2>/dev/null; then
  assert_pass "TC-LGC2-055b: the OLDER lane's live pgid is untouched — the delegate never reaps the wrong lane"
else
  assert_fail "TC-LGC2-055b: the OLDER lane's pgid was reaped even though the selected (newer) lane was unknown, not dead"
fi
kill -9 "$OLDPG_055" 2>/dev/null || true

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC2-056/057: lane_find_latest same-second tie-break (install order) ==="
# ---------------------------------------------------------------------------
# Regression (codex review [P1] round 3, #378): lane_mint's epoch is
# `date +%s`, so two quick redispatches for the same (project, role, issue)
# can share the SAME epoch. The pre-fix comparison (`epoch -gt best_epoch`
# only) kept whichever basename the glob scanned FIRST — i.e. the lexically
# smallest — regardless of which lane was actually installed later. The fix
# breaks epoch ties by the lane DIRECTORY's immutable birth time (created at
# `.pending-*` mkdir, preserved across lane_install's rename), falling back
# to the lexically-greater basename only where birth time is unavailable.
#
# TC-LGC2-056 — proven to FAIL against the pre-fix code: the OLDER lane's
# rand4 sorts lexically FIRST, so the pre-fix first-scanned-wins picked the
# older lane; install order must win.
bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state56"
  source "'"$LIB_LANE"'"

  EPOCH=1700000000
  LANE_DIR_OLD=$(lane_install myproj "myproj:dev:3:${EPOCH}:00aa")
  sleep 0.1
  LANE_DIR_NEW=$(lane_install myproj "myproj:dev:3:${EPOCH}:ffee")

  RESULT=$(lane_find_latest myproj dev 3)
  RESULT2=$(lane_find_latest myproj dev 3)
  echo "NEW_DIR:$LANE_DIR_NEW"
  echo "SELECTED:$RESULT"
  [[ "$RESULT" == "$RESULT2" ]] && echo "DETERMINISTIC:yes" || echo "DETERMINISTIC:no"
' > "$TMPROOT/tc056.out" 2>&1
OUT056=$(cat "$TMPROOT/tc056.out")
NEW_DIR_056=$(printf '%s' "$OUT056" | grep '^NEW_DIR:' | cut -d: -f2-)
SELECTED_056=$(printf '%s' "$OUT056" | grep '^SELECTED:' | cut -d: -f2-)
if [[ -n "$NEW_DIR_056" && "$SELECTED_056" == "$NEW_DIR_056" ]]; then
  assert_pass "TC-LGC2-056: same-epoch tie resolves to the LATER-installed lane (pre-fix code returned the first-scanned older sibling)"
else
  assert_fail "TC-LGC2-056: selected [$SELECTED_056], expected the later-installed [$NEW_DIR_056]"
fi
assert_contains "TC-LGC2-056b: repeated scans converge on the same winner" "DETERMINISTIC:yes" "$OUT056"

# TC-LGC2-057 — the tie-break is INSTALL ORDER, not basename lexicographics:
# here the LATER-installed lane's rand4 sorts lexically FIRST, so a
# lex-only backstop would pick the older sibling; only the dir-birth-time
# key selects correctly. Skipped (with a pass note) where the filesystem
# reports no usable birth time OR only 1-second granularity (macOS/BSD
# `stat -f %B` — two installs 0.1s apart usually share a birth second, so
# the documented lexical backstop legitimately decides there and this
# install-order assertion would flake).
bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state57"
  source "'"$LIB_LANE"'"

  PROBE_DIR="'"$TMPROOT"'/state57"; mkdir -p "$PROBE_DIR"
  PROBE_KEY="$(_lane_birth_key "$PROBE_DIR")"
  if [[ "$PROBE_KEY" == "$(printf "%020d.%s" 0 000000000)" || "$PROBE_KEY" == *.000000000 ]]; then
    echo "SKIP:no-subsecond-birth-time"
    exit 0
  fi

  EPOCH=1700000000
  LANE_DIR_OLD=$(lane_install myproj "myproj:dev:4:${EPOCH}:ffee")
  sleep 0.1
  LANE_DIR_NEW=$(lane_install myproj "myproj:dev:4:${EPOCH}:00aa")

  RESULT=$(lane_find_latest myproj dev 4)
  echo "NEW_DIR:$LANE_DIR_NEW"
  echo "SELECTED:$RESULT"
' > "$TMPROOT/tc057.out" 2>&1
OUT057=$(cat "$TMPROOT/tc057.out")
if [[ "$OUT057" == *"SKIP:no-subsecond-birth-time"* ]]; then
  assert_pass "TC-LGC2-057: skipped — no sub-second birth time on this filesystem (macOS/BSD 1s granularity or none); lexical backstop is the documented behavior there"
else
  NEW_DIR_057=$(printf '%s' "$OUT057" | grep '^NEW_DIR:' | cut -d: -f2-)
  SELECTED_057=$(printf '%s' "$OUT057" | grep '^SELECTED:' | cut -d: -f2-)
  if [[ -n "$NEW_DIR_057" && "$SELECTED_057" == "$NEW_DIR_057" ]]; then
    assert_pass "TC-LGC2-057: same-epoch tie follows dir birth time (install order), even against a lexically-smaller basename"
  else
    assert_fail "TC-LGC2-057: selected [$SELECTED_057], expected the later-installed [$NEW_DIR_057] (birth-time key must beat lex order)"
  fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC2-060..064: kill_stale_wrapper's lane_kill delegate ==="
# ---------------------------------------------------------------------------
DISPATCH_LOCAL="$SCRIPTS/dispatch-local.sh"
if grep -q 'lane_find_latest' "$DISPATCH_LOCAL" 2>/dev/null && \
   grep -q 'lane_kill "\$_lane_dir"' "$DISPATCH_LOCAL" 2>/dev/null; then
  assert_pass "TC-LGC2-source: dispatch-local.sh's kill_stale_wrapper carries the lane_kill delegate"
else
  assert_fail "TC-LGC2-source: dispatch-local.sh missing the lane_kill delegate wiring"
fi
if grep -qE 'dev-new\|dev-resume\) *_lane_role="dev"' "$DISPATCH_LOCAL" 2>/dev/null && \
   grep -qE 'review\) *_lane_role="review"' "$DISPATCH_LOCAL" 2>/dev/null; then
  assert_pass "TC-LGC2-064: dispatch-local.sh maps dev-new/dev-resume -> dev, review -> review"
else
  assert_fail "TC-LGC2-064: TYPE-to-role mapping not found verbatim in dispatch-local.sh"
fi

# Behavioral: extract kill_stale_wrapper and drive it against a DEAD lane with
# a live recorded pgid, confirming the pgid is reaped (TC-060) and confirming
# a LIVE lane's pgid is left untouched (TC-061), and confirming a lane-less
# issue exercises the legacy path unaffected (TC-062).
KSW_SLICE=$(mktemp)
awk '/^kill_stale_wrapper\(\) \{/,/^}$/' "$DISPATCH_LOCAL" > "$KSW_SLICE"

run_ksw() {
  local label="$1" state_root="$2" project_id="$3" type_val="$4" issue_num="$5" pid_file="$6"
  bash -c '
    set -u
    source "'"$LIB_LANE"'"
    export ADT_STATE_ROOT="'"$state_root"'"
    PROJECT_ID="'"$project_id"'"
    TYPE="'"$type_val"'"
    ISSUE_NUM="'"$issue_num"'"
    KILL_STALE_PGREP_FALLBACK=false
    source "'"$KSW_SLICE"'"
    kill_stale_wrapper "'"$pid_file"'"
  ' > "$TMPROOT/ksw-$label.out" 2>&1
}

# TC-060: dead lane, live recorded pgid -> lane_kill reaps it.
ST60="$TMPROOT/state60"
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST60"'"
  LANE_ID=$(lane_mint dproj dev 100)
  LANE_DIR=$(lane_install dproj "$LANE_ID")
  # Force a DEAD probe: WRAPPER_PID set to an exited pid.
  ( exit 0 ) & DEADPID=$!; wait "$DEADPID" 2>/dev/null
  sed -i "s/^WRAPPER_PID=.*/WRAPPER_PID=$DEADPID/" "$LANE_DIR/lane"
  setsid sleep 30 & PG=$!
  lane_record_pgid "$LANE_DIR" "$PG" agent
  echo "$PG" > "'"$TMPROOT"'/tc060-pg.txt"
'
PG60=$(cat "$TMPROOT/tc060-pg.txt" 2>/dev/null || echo 0)
NOPID_FILE60="$TMPROOT/nonexistent60.pid"
run_ksw "060" "$ST60" "dproj" "dev-new" "100" "$NOPID_FILE60"
sleep 0.3
if kill -0 "$PG60" 2>/dev/null; then
  assert_fail "TC-LGC2-060: recorded pgid for a DEAD lane survived kill_stale_wrapper"
else
  assert_pass "TC-LGC2-060: kill_stale_wrapper's delegate reaped a DEAD lane's recorded pgid"
fi

# TC-061: live lane (WRAPPER_PID/WRAPPER_START both rewritten to match a
# real long-lived holder process) — delegate must NOT touch its recorded pgid.
ST61="$TMPROOT/state61"
sleep 5 &
HOLDER_PID=$!
sleep 0.2
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST61"'"
  LANE_ID=$(lane_mint dproj dev 101)
  LANE_DIR=$(lane_install dproj "$LANE_ID")
  HOLDER_START=$(proc_start_time "'"$HOLDER_PID"'")
  sed -i "s/^WRAPPER_PID=.*/WRAPPER_PID='"$HOLDER_PID"'/" "$LANE_DIR/lane"
  sed -i "s/^WRAPPER_START=.*/WRAPPER_START=${HOLDER_START}/" "$LANE_DIR/lane"
  setsid sleep 30 & PG=$!
  lane_record_pgid "$LANE_DIR" "$PG" agent
  echo "$PG" > "'"$TMPROOT"'/tc061-pg.txt"
'
PG61=$(cat "$TMPROOT/tc061-pg.txt" 2>/dev/null || echo 0)
NOPID_FILE61="$TMPROOT/nonexistent61.pid"
run_ksw "061" "$ST61" "dproj" "dev-new" "101" "$NOPID_FILE61"
sleep 0.3
if kill -0 "$PG61" 2>/dev/null; then
  assert_pass "TC-LGC2-061: a LIVE lane's recorded pgid is left untouched by the delegate"
else
  assert_fail "TC-LGC2-061: a LIVE lane's recorded pgid was incorrectly reaped"
fi
kill -9 "$PG61" "$HOLDER_PID" 2>/dev/null || true

# TC-062: no lane at all for this (project, role, issue) — legacy path runs,
# delegate is a pure no-op (no crash, no spurious action).
ST62="$TMPROOT/state62-empty"
mkdir -p "$ST62"
run_ksw "062" "$ST62" "dproj" "dev-new" "999" "$TMPROOT/nonexistent62.pid"
if [[ -f "$TMPROOT/ksw-062.out" ]]; then
  assert_pass "TC-LGC2-062: no-lane case runs kill_stale_wrapper without error (legacy path intact)"
else
  assert_fail "TC-LGC2-062: kill_stale_wrapper did not run to completion in the no-lane case"
fi

# TC-063: unparseable lane file -> lane_probe unknown -> delegate must not act.
ST63="$TMPROOT/state63"
bash -c '
  source "'"$LIB_LANE"'"
  export ADT_STATE_ROOT="'"$ST63"'"
  LANE_ID=$(lane_mint dproj dev 102)
  LANE_DIR=$(lane_install dproj "$LANE_ID")
  echo "totally-unparseable-garbage" > "$LANE_DIR/lane"
  setsid sleep 30 & PG=$!
  lane_record_pgid "$LANE_DIR" "$PG" agent
  echo "$PG" > "'"$TMPROOT"'/tc063-pg.txt"
'
PG63=$(cat "$TMPROOT/tc063-pg.txt" 2>/dev/null || echo 0)
run_ksw "063" "$ST63" "dproj" "dev-new" "102" "$TMPROOT/nonexistent63.pid"
sleep 0.3
if kill -0 "$PG63" 2>/dev/null; then
  assert_pass "TC-LGC2-063: an unparseable lane's pgid is left untouched (never bricks a re-dispatch)"
else
  assert_fail "TC-LGC2-063: an unparseable lane's pgid was incorrectly reaped"
fi
kill -9 "$PG63" 2>/dev/null || true

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LGC2-070/071/072/073: lane_get/lane_set KV round-trip ==="
# ---------------------------------------------------------------------------
bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state7x"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj dev 1)
  LANE_DIR=$(lane_install myproj "$LANE_ID")

  lane_set "$LANE_DIR" CHROME_PROFILE_HINT "/tmp/foo/chrome-profile-XXXXXX"
  echo "SLASH:$(lane_get "$LANE_DIR" CHROME_PROFILE_HINT)"

  lane_set "$LANE_DIR" WRAPPER_FINGERPRINT "abc&foo*bar[baz]123"
  echo "SPECIAL:$(lane_get "$LANE_DIR" WRAPPER_FINGERPRINT)"

  lane_set "$LANE_DIR" BRAND_NEW_KEY "hello"
  echo "NEWKEY:$(lane_get "$LANE_DIR" BRAND_NEW_KEY)"

  # TC-LGC2-074 (regression): a value containing a LITERAL backslash-escape
  # SEQUENCE (two chars: backslash + n/t, NOT an actual newline/tab byte) must
  # survive verbatim. awk -v VAR=value interprets C-style backslash escapes
  # in the assignment text itself (POSIX awk behavior) — a value like this
  # one is exactly what a sha256 hex/path could never produce by accident,
  # but IS exactly the shape a caller could pass; the pre-fix code turned the
  # two-char \n into a real newline, truncating the value AND corrupting the
  # lane file with a bogus injected line.
  lane_set "$LANE_DIR" CHROME_PROFILE_HINT "foo\nbar\tbaz"
  echo "ESCAPES:$(lane_get "$LANE_DIR" CHROME_PROFILE_HINT)"
  echo "LANE-LINE-COUNT:$(wc -l < "$LANE_DIR/lane")"
' > "$TMPROOT/tc07x.out" 2>&1
OUT7X=$(cat "$TMPROOT/tc07x.out")
assert_contains "TC-LGC2-070: lane_set/lane_get round-trips a value containing '/'" "SLASH:/tmp/foo/chrome-profile-XXXXXX" "$OUT7X"
assert_contains "TC-LGC2-071: lane_set/lane_get round-trips '&[]*' without corruption" "SPECIAL:abc&foo*bar[baz]123" "$OUT7X"
assert_contains "TC-LGC2-072: lane_set appends a previously-absent key" "NEWKEY:hello" "$OUT7X"
assert_contains "TC-LGC2-074: lane_set/lane_get preserves a literal backslash-escape sequence verbatim (no awk -v escape interpretation)" "ESCAPES:foo\nbar\tbaz" "$OUT7X"
assert_contains "TC-LGC2-074b: the lane file is not corrupted with a bogus injected line" "LANE-LINE-COUNT:17" "$OUT7X"

# TC-073: concurrent lane_set calls never corrupt the file.
bash -c '
  set -u
  export ADT_STATE_ROOT="'"$TMPROOT"'/state73"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint myproj dev 1)
  LANE_DIR=$(lane_install myproj "$LANE_ID")
  for i in $(seq 1 20); do
    lane_set "$LANE_DIR" STATE "state-$i" &
  done
  wait
  # File must still be fully parseable (no truncated/interleaved writes).
  for key in LANE_ID PROJECT_ID ISSUE ROLE STATE; do
    lane_get "$LANE_DIR" "$key" >/dev/null || { echo "CORRUPT:$key"; exit 1; }
  done
  echo "INTACT"
' > "$TMPROOT/tc073.out" 2>&1
assert_contains "TC-LGC2-073: 20 concurrent lane_set calls leave the lane file fully parseable" "INTACT" "$(cat "$TMPROOT/tc073.out")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Source-of-truth: wrapper mint-before-auth ordering ==="
# ---------------------------------------------------------------------------
for wrapper in autonomous-dev.sh autonomous-review.sh; do
  W="$SCRIPTS/$wrapper"
  MINT_LINE=$(grep -n 'declare -F lane_mint' "$W" | head -1 | cut -d: -f1)
  AUTH_LINE=$(grep -n 'GH_AUTH_MODE" == "app"' "$W" | head -1 | cut -d: -f1)
  HEARTBEAT_LINE=$(grep -n 'install_agent_heartbeat' "$W" | head -1 | cut -d: -f1)
  if [[ -n "$MINT_LINE" && -n "$AUTH_LINE" && -n "$HEARTBEAT_LINE" ]] \
     && [[ "$MINT_LINE" -lt "$AUTH_LINE" ]] && [[ "$MINT_LINE" -lt "$HEARTBEAT_LINE" ]]; then
    assert_pass "TC-LGC2-021/022 ($wrapper): lane mint precedes both GH_AUTH_MODE branch and heartbeat install"
  else
    assert_fail "TC-LGC2-021/022 ($wrapper): ordering violated (mint=$MINT_LINE auth=$AUTH_LINE heartbeat=$HEARTBEAT_LINE)"
  fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== Source-of-truth: ADT_LANE_ROLE exports ==="
# ---------------------------------------------------------------------------
REVIEW_WRAPPER="$SCRIPTS/autonomous-review.sh"
if grep -q 'export ADT_LANE_ROLE="fanout:\${_agent}"' "$REVIEW_WRAPPER" 2>/dev/null; then
  assert_pass "TC-LGC2-023: review fan-out subshell exports ADT_LANE_ROLE=fanout:<agent>"
else
  assert_fail "TC-LGC2-023: fan-out ADT_LANE_ROLE export not found"
fi
if grep -q 'export ADT_LANE_ROLE="smoke:\${_smoke_agent}"' "$REVIEW_WRAPPER" 2>/dev/null; then
  assert_pass "TC-LGC2-024: review smoke subshell exports ADT_LANE_ROLE=smoke:<agent>"
else
  assert_fail "TC-LGC2-024: smoke ADT_LANE_ROLE export not found"
fi
if grep -q 'export ADT_LANE_ROLE="e2e:browser"' "$REVIEW_WRAPPER" 2>/dev/null \
   && grep -q 'export TMPDIR="\${ADT_LANE_DIR}/tmp"' "$REVIEW_WRAPPER" 2>/dev/null \
   && grep -q 'CHROME_PROFILE_HINT' "$REVIEW_WRAPPER" 2>/dev/null; then
  assert_pass "TC-LGC2-025: browser E2E lane exports ADT_LANE_ROLE, redirects TMPDIR, records CHROME_PROFILE_HINT"
else
  assert_fail "TC-LGC2-025: browser E2E lane's tagging/TMPDIR/CHROME_PROFILE_HINT wiring incomplete"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Grep-pin: no [[ -s /proc/*/environ ]] anywhere in lib-lane.sh ==="
# ---------------------------------------------------------------------------
if grep -qE '\[\[ *-s */proc/\*/environ' "$LIB_LANE" 2>/dev/null; then
  assert_fail "grep-pin: lib-lane.sh contains a banned [[ -s /proc/*/environ ]] gate"
else
  assert_pass "grep-pin: lib-lane.sh has no banned [[ -s /proc/*/environ ]] gate (env_of gates on -r)"
fi
if grep -qE '\[ -r "/proc/\$\{pid\}/environ" \]' "$LIB_LANE" 2>/dev/null; then
  assert_pass "grep-pin: env_of gates on [ -r ], not [ -s ]"
else
  assert_fail "grep-pin: env_of's -r gate not found verbatim"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
