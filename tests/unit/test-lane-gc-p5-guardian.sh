#!/bin/bash
# test-lane-gc-p5-guardian.sh — Unit tests for issue #381 (Lane-GC series
# PR-5, design docs/designs/lane-containment-gc.md §4-C3; INV-118).
#
# Covers:
#   - lib-guardian.sh: the standalone guardian sidecar entry-point script —
#     no-writer watchdog (armed BEFORE the blocking open, per the ordering
#     bug found while writing this suite), SIGKILL/EOF reap, lane-scoped
#     escape sweep, reap.lock non-reentrancy, lifetime cap + its
#     SIGKILL-non-survivable chunk-watchdog, graceful zero-kill exit.
#   - autonomous-dev.sh / autonomous-review.sh: guardian install-order
#     grep-pins (write-fd-before-spawn) and the setsid-absent degradation.
#   - FD-hygiene grep-pins across every literal spawn site touched by this
#     PR (honest scope: literal `&`/`bash -c` sites only — see the design's
#     own §10 residual wording for why syntactic variants are excluded).
#
# Full scenario list: docs/test-cases/lane-gc-p5-guardian.md (TC-LGC5-*).
#
# Run: bash tests/unit/test-lane-gc-p5-guardian.sh
# (Run under `bash`, and once under `env -u PROJECT_DIR bash ...` for CI
# parity — ambient PROJECT_DIR contaminates lib-config.sh's conf lookup in
# some sibling suites; this suite sources lib-lane.sh/lib-guardian.sh only,
# neither of which reads PROJECT_DIR, but the convention is kept for
# consistency with the rest of the series.)

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB_LANE="$SCRIPTS/lib-lane.sh"
LIB_GUARDIAN="$SCRIPTS/lib-guardian.sh"
DEV_WRAPPER="$SCRIPTS/autonomous-dev.sh"
REVIEW_WRAPPER="$SCRIPTS/autonomous-review.sh"
LIB_AGENT="$SCRIPTS/lib-agent.sh"
LIB_AUTH="$SCRIPTS/lib-auth.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert_pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
assert_fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc (expected [$expected] got [$actual])"; fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then assert_pass "$desc"; else assert_fail "$desc (needle='$needle' not found)"; fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then assert_pass "$desc"; else assert_fail "$desc (needle='$needle' unexpectedly found)"; fi
}

for f in "$LIB_LANE" "$LIB_GUARDIAN" "$DEV_WRAPPER" "$REVIEW_WRAPPER" "$LIB_AGENT" "$LIB_AUTH"; do
  [[ -f "$f" ]] || { echo -e "${RED}FATAL${NC}: $f not found"; exit 1; }
done

TMPROOT=$(mktemp -d)
# EXIT trap pkills every fixture spawned under TMPROOT by path, then removes
# the tree — matches the house convention (test-lane-gc-p3-kill-paths.sh).
trap 'pkill -9 -f "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

# _mint_lane <ns> <role> <issue> — echo a fresh lane dir under its own
# isolated ADT_STATE_ROOT (namespaced per test so parallel/rerun invocations
# never collide). Caller must `export ADT_STATE_ROOT=...` matching <ns>
# before sourcing lib-lane.sh in its OWN subshell — this helper is for the
# PARENT test shell's bookkeeping only (path computation), not a sourced
# call.
_lane_state_root() { printf '%s/state-%s\n' "$TMPROOT" "$1"; }

# ===========================================================================
echo ""
echo "=== TC-LGC5-001/002: no-writer watchdog fires within the configured grace, ordering-bug regression ==="
# ===========================================================================
# TC-LGC5-001 — the actual regression this suite exists to pin: the
# watchdog must fire even though NOTHING ever opens the fifo for write —
# i.e. the guardian's own blocking `exec 3<fifo` open call must itself be
# interruptible. A guardian that arms the watchdog AFTER attempting that
# open (the ordering bug found empirically while writing this test) would
# hang here forever; this test has its OWN outer `timeout` as a backstop so
# a regression fails loudly instead of wedging the whole suite.
LANE001="$TMPROOT/lane001"
mkdir -p "$LANE001"
mkfifo "$LANE001/guard.fifo"
START001=$(date +%s)
timeout 10 env ADT_GUARDIAN_NO_WRITER_GRACE_SECONDS=2 \
  bash "$LIB_GUARDIAN" --lane-dir "$LANE001" >"$LANE001/guardian.log" 2>&1
RC001=$?
END001=$(date +%s)
ELAPSED001=$((END001 - START001))
assert_eq "TC-LGC5-001: guardian against a NEVER-written fifo exits (does not hang) within the outer timeout" "0" "$RC001"
if [[ "$ELAPSED001" -le 6 ]]; then
  assert_pass "TC-LGC5-001b: no-writer watchdog fires close to its configured 2s grace (elapsed=${ELAPSED001}s), not the outer 10s backstop — proves the watchdog interrupts the BLOCKING OPEN itself, not merely a post-open check"
else
  assert_fail "TC-LGC5-001b: took ${ELAPSED001}s — watchdog did not fire promptly (ordering-bug regression: armed AFTER the blocking open instead of before)"
fi
assert_contains "TC-LGC5-002: guardian log names the no-writer watchdog firing" "no-writer watchdog fired" "$(cat "$LANE001/guardian.log")"

# TC-LGC5-003 — source-of-truth grep-pin: the watchdog's `trap ... USR2` and
# its backgrounded timer must appear BEFORE the `exec 3<"$FIFO_PATH"` open
# line in the shipped script — this is the exact ordering TC-LGC5-001
# behaviorally proves; pin it structurally too so a future refactor that
# silently reorders these two blocks fails fast in review.
TRAP_LINE=$(grep -n 'trap ".*no-writer watchdog fired' "$LIB_GUARDIAN" | head -1 | cut -d: -f1)
OPEN_LINE=$(grep -n '^exec 3<"\$FIFO_PATH"' "$LIB_GUARDIAN" | head -1 | cut -d: -f1)
if [[ -n "$TRAP_LINE" && -n "$OPEN_LINE" && "$TRAP_LINE" -lt "$OPEN_LINE" ]]; then
  assert_pass "TC-LGC5-003: source-of-truth — no-writer watchdog trap (line $TRAP_LINE) precedes the fifo open (line $OPEN_LINE)"
else
  assert_fail "TC-LGC5-003: watchdog trap (line ${TRAP_LINE:-MISSING}) does NOT precede the fifo open (line ${OPEN_LINE:-MISSING}) — this is the exact ordering bug TC-LGC5-001 behaviorally catches"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC5-010/011: SIGKILL integration — guardian reaps recorded pgids within grace+2s ==="
# ===========================================================================
NS010="lgc5-010"
export ADT_STATE_ROOT="$(_lane_state_root "$NS010")"
(
  source "$LIB_LANE"
  LANE_ID=$(lane_mint proj010 dev 10)
  LANE_DIR=$(lane_install proj010 "$LANE_ID")
  echo "$LANE_DIR" > "$TMPROOT/lane010.path"
  mkfifo "$LANE_DIR/guard.fifo"
  exec {ADT_GUARD_FD}<>"$LANE_DIR/guard.fifo"
  export ADT_GUARD_FD

  # Recorded agent child (fixture "wrapper"'s agent), FD-hygiene-clean.
  setsid bash -c '[[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-; exec sleep 60' &
  AGENT_PGID=$!
  disown 2>/dev/null || true
  sleep 0.2
  lane_record_pgid "$LANE_DIR" "$AGENT_PGID" agent
  echo "$AGENT_PGID" > "$TMPROOT/lane010.agentpgid"

  # Spawn the REAL guardian, FD-hygiene-clean at its own spawn site.
  setsid bash -c '[[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-; exec bash "$1" --lane-dir "$2"' \
    _ "$LIB_GUARDIAN" "$LANE_DIR" >>"$LANE_DIR/guardian.log" 2>&1 &
  GUARDIAN_PID=$!
  disown 2>/dev/null || true
  lane_set "$LANE_DIR" GUARDIAN_PID "$GUARDIAN_PID"
  echo "$GUARDIAN_PID" > "$TMPROOT/lane010.guardianpid"
  sleep 0.3

  # Simulate SIGKILL of the "wrapper session": close our own write fd
  # (the kernel does exactly this atomically on a real SIGKILL of the
  # process holding it — the effect on the fifo is identical whether the
  # fd is closed by an explicit exec or by kernel process teardown).
  exec {ADT_GUARD_FD}>&-
  wait
) &
FIXTURE010=$!
wait "$FIXTURE010" 2>/dev/null

LANE010=$(cat "$TMPROOT/lane010.path")
AGENT_PGID010=$(cat "$TMPROOT/lane010.agentpgid")
GUARDIAN_PID010=$(cat "$TMPROOT/lane010.guardianpid")

# grace(10s, do_reap's default) + 2s settle bound (the AC's own wording).
# Wait for the GUARDIAN itself to exit (not merely the agent pgid dying) —
# do_reap continues past the pgid escalation into its own escape sweep
# before self-exiting, so sampling STATE/guardian-liveness the instant the
# agent pgid dies races ahead of that remaining work.
DEADLINE010=$(( $(date +%s) + 15 ))
while [[ $(date +%s) -lt $DEADLINE010 ]]; do
  kill -0 "$GUARDIAN_PID010" 2>/dev/null || break
  sleep 0.3
done
AGENT_ALIVE010=$(kill -0 -- "-$AGENT_PGID010" 2>/dev/null && echo yes || echo no)
GUARDIAN_ALIVE010=$(kill -0 "$GUARDIAN_PID010" 2>/dev/null && echo yes || echo no)
STATE010=$( (source "$LIB_LANE"; lane_get "$LANE010" STATE) 2>/dev/null)

assert_eq "TC-LGC5-010: SIGKILL-simulated wrapper -> guardian reaps the recorded agent pgid within grace(10s)+2s" "no" "$AGENT_ALIVE010"
assert_eq "TC-LGC5-010b: guardian itself exits after reaping (does not linger)" "no" "$GUARDIAN_ALIVE010"
assert_eq "TC-LGC5-011: STATE promotes to reaped-by-guardian" "reaped-by-guardian" "$STATE010"
kill -9 -- "-$AGENT_PGID010" 2>/dev/null || true

# ===========================================================================
echo ""
echo "=== TC-LGC5-020/021: lane-scoped escape sweep — this-lane tag swept, foreign-lane tag NOT swept ==="
# ===========================================================================
NS020="lgc5-020"
export ADT_STATE_ROOT="$(_lane_state_root "$NS020")"
(
  source "$LIB_LANE"
  LANE_ID=$(lane_mint proj020 dev 20)
  LANE_DIR=$(lane_install proj020 "$LANE_ID")
  export ADT_LANE_ID="$LANE_ID"
  echo "$LANE_DIR" > "$TMPROOT/lane020.path"
  mkfifo "$LANE_DIR/guard.fifo"
  exec {ADT_GUARD_FD}<>"$LANE_DIR/guard.fifo"
  export ADT_GUARD_FD

  # An escapee carrying THIS lane's tag but NOT recorded in pgids (the
  # class only the escape sweep — not the pgid escalation — can reach).
  # `-u TERM_PROGRAM`: this box's shell exports TERM_PROGRAM=tmux, and the
  # guardian's operator fail-safe unconditionally skips any tagged process
  # that carries it — the fixture must scrub it so the sweep rule under
  # test (lane-tag match) is the one actually exercised (the P4 suite hit
  # this exact ambient-env class, TC-LGC4 fixture lesson).
  setsid env -u TERM_PROGRAM bash -c '[[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-; exec sleep 60' &
  OUR_ESCAPEE=$!
  disown 2>/dev/null || true
  echo "$OUR_ESCAPEE" > "$TMPROOT/lane020.ourescapee"

  # A registered but FOREIGN lane and an escapee carrying THAT lane's tag.
  # TERM_PROGRAM scrubbed here too: the foreign escapee must survive
  # because of the FOREIGN-TAG rule, not because the operator fail-safe
  # fired first — with tmux's ambient TERM_PROGRAM present, TC-LGC5-021
  # would pass vacuously for the wrong reason.
  FOREIGN_LANE_ID=$(lane_mint proj020 dev 21)
  lane_install proj020 "$FOREIGN_LANE_ID" >/dev/null
  setsid env -u TERM_PROGRAM ADT_LANE_ID="$FOREIGN_LANE_ID" bash -c '[[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-; exec sleep 60' &
  FOREIGN_ESCAPEE=$!
  disown 2>/dev/null || true
  echo "$FOREIGN_ESCAPEE" > "$TMPROOT/lane020.foreignescapee"

  sleep 0.3
  setsid bash -c '[[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-; exec bash "$1" --lane-dir "$2"' \
    _ "$LIB_GUARDIAN" "$LANE_DIR" >>"$LANE_DIR/guardian.log" 2>&1 &
  GUARDIAN_PID=$!
  disown 2>/dev/null || true
  lane_set "$LANE_DIR" GUARDIAN_PID "$GUARDIAN_PID"
  echo "$GUARDIAN_PID" > "$TMPROOT/lane020.guardianpid"
  sleep 0.3

  exec {ADT_GUARD_FD}>&-
  wait
) &
FIXTURE020=$!
wait "$FIXTURE020" 2>/dev/null

OUR_ESCAPEE020=$(cat "$TMPROOT/lane020.ourescapee")
FOREIGN_ESCAPEE020=$(cat "$TMPROOT/lane020.foreignescapee")
GUARDIAN_PID020=$(cat "$TMPROOT/lane020.guardianpid")

DEADLINE020=$(( $(date +%s) + 12 ))
while [[ $(date +%s) -lt $DEADLINE020 ]]; do
  kill -0 -- "-$OUR_ESCAPEE020" 2>/dev/null || break
  sleep 0.5
done

# Both escapee fixtures scrub TERM_PROGRAM at spawn (`env -u TERM_PROGRAM`
# above — the P4-suite ambient-env lesson), so the sweep rule under test
# is exercised hermetically regardless of this test process's own
# environment (tmux exports TERM_PROGRAM on this box); no skip branch
# needed.
OUR_ALIVE020=$(kill -0 -- "-$OUR_ESCAPEE020" 2>/dev/null && echo yes || echo no)
assert_eq "TC-LGC5-020: escapee carrying THIS lane's tag is swept" "no" "$OUR_ALIVE020"
FOREIGN_ALIVE020=$(kill -0 -- "-$FOREIGN_ESCAPEE020" 2>/dev/null && echo yes || echo no)
assert_eq "TC-LGC5-021: escapee carrying a DIFFERENT (registered but foreign) lane's tag is NOT swept" "yes" "$FOREIGN_ALIVE020"
kill -9 -- "-$OUR_ESCAPEE020" -- "-$FOREIGN_ESCAPEE020" 2>/dev/null || true

# ===========================================================================
echo ""
echo "=== TC-LGC5-030/031: FD hygiene — sole-holder fast EOF vs. inherited-fd deferred EOF ==="
# ===========================================================================
# TC-LGC5-030 — sole-holder branch: nobody else inherits the write fd, so
# closing it must reach EOF almost immediately (<2s, generously bounding
# the ~ms the design's own measurement cites).
LANE030="$TMPROOT/lane030"
mkdir -p "$LANE030"
mkfifo "$LANE030/guard.fifo"
OUT030=$(bash -c '
  exec {FD}<>"'"$LANE030"'/guard.fifo"
  exec 3<"'"$LANE030"'/guard.fifo"
  START=$(date +%s.%N)
  exec {FD}>&-
  read -r _ <&3
  END=$(date +%s.%N)
  echo "ELAPSED=$(echo "$END - $START" | bc 2>/dev/null || echo 0)"
' 2>&1)
ELAPSED030=$(grep -oE 'ELAPSED=[0-9.]+' <<<"$OUT030" | cut -d= -f2)
if [[ -n "$ELAPSED030" ]] && (( $(echo "$ELAPSED030 < 2" | bc 2>/dev/null || echo 0) )); then
  assert_pass "TC-LGC5-030: sole-holder EOF observed in ${ELAPSED030}s (< 2s bound)"
else
  assert_fail "TC-LGC5-030: sole-holder EOF took ${ELAPSED030:-unknown}s — expected < 2s"
fi

# TC-LGC5-031 — inherited-fd branch: a child that inherits (never closes)
# the write fd defers EOF until THAT child exits, even after the original
# opener closes its own copy — proves closing is necessary at every spawn
# site, not merely at the top-level wrapper.
LANE031="$TMPROOT/lane031"
mkdir -p "$LANE031"
mkfifo "$LANE031/guard.fifo"
OUT031=$(bash -c '
  exec {FD}<>"'"$LANE031"'/guard.fifo"
  export FD
  ( sleep 2 ) &   # inherits FD, never closes it
  CHILD=$!
  exec 3<"'"$LANE031"'/guard.fifo"
  exec {FD}>&-    # original opener closes its OWN copy
  START=$(date +%s)
  DEFERRED=no
  if ! read -r -t 1 _ <&3; then DEFERRED=yes; fi
  wait "$CHILD" 2>/dev/null
  END=$(date +%s)
  GOT_EOF=no
  read -r -t 3 _ <&3 || GOT_EOF=yes
  echo "DEFERRED=$DEFERRED GOT_EOF_AFTER_CHILD_EXIT=$GOT_EOF ELAPSED=$((END-START))"
' 2>&1)
assert_contains "TC-LGC5-031: EOF is DEFERRED while the inherited-fd-holding child is still alive (read times out, not EOF)" "DEFERRED=yes" "$OUT031"
assert_contains "TC-LGC5-031b: EOF finally arrives once the inherited-fd-holding child exits" "GOT_EOF_AFTER_CHILD_EXIT=yes" "$OUT031"

# ===========================================================================
echo ""
echo "=== TC-LGC5-040: graceful exit — guardian exits with ZERO kills ==="
# ===========================================================================
NS040="lgc5-040"
export ADT_STATE_ROOT="$(_lane_state_root "$NS040")"
(
  source "$LIB_LANE"
  LANE_ID=$(lane_mint proj040 dev 40)
  LANE_DIR=$(lane_install proj040 "$LANE_ID")
  echo "$LANE_DIR" > "$TMPROOT/lane040.path"
  mkfifo "$LANE_DIR/guard.fifo"
  exec {ADT_GUARD_FD}<>"$LANE_DIR/guard.fifo"
  export ADT_GUARD_FD

  setsid bash -c '[[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-; exec bash "$1" --lane-dir "$2"' \
    _ "$LIB_GUARDIAN" "$LANE_DIR" >>"$LANE_DIR/guardian.log" 2>&1 &
  GUARDIAN_PID=$!
  disown 2>/dev/null || true
  lane_set "$LANE_DIR" GUARDIAN_PID "$GUARDIAN_PID"
  echo "$GUARDIAN_PID" > "$TMPROOT/lane040.guardianpid"
  sleep 0.3

  # The REAL graceful sequence: STATE=cleaning -> handshake -> close -> clean-exit.
  lane_set_state "$LANE_DIR" cleaning
  { printf 'done\n' >&"$ADT_GUARD_FD"; } 2>/dev/null || true
  exec {ADT_GUARD_FD}>&- 2>/dev/null || true
  lane_set_state "$LANE_DIR" clean-exit
) &
FIXTURE040=$!
wait "$FIXTURE040" 2>/dev/null

LANE040=$(cat "$TMPROOT/lane040.path")
GUARDIAN_PID040=$(cat "$TMPROOT/lane040.guardianpid")
DEADLINE040=$(( $(date +%s) + 5 ))
while [[ $(date +%s) -lt $DEADLINE040 ]]; do
  kill -0 "$GUARDIAN_PID040" 2>/dev/null || break
  sleep 0.2
done
GUARDIAN_ALIVE040=$(kill -0 "$GUARDIAN_PID040" 2>/dev/null && echo yes || echo no)
STATE040=$( (source "$LIB_LANE"; lane_get "$LANE040" STATE) 2>/dev/null)
GLOG040=$(cat "$LANE040/guardian.log" 2>/dev/null)

assert_eq "TC-LGC5-040: guardian exits promptly on the graceful handshake" "no" "$GUARDIAN_ALIVE040"
assert_eq "TC-LGC5-040b: STATE stays at the wrapper's own clean-exit — guardian never overwrote it" "clean-exit" "$STATE040"
assert_not_contains "TC-LGC5-040c: guardian log shows NO escalation/kill activity (zero-kill wake)" "TERM->2s->KILL" "$GLOG040"
assert_not_contains "TC-LGC5-040d: guardian log shows no pgid escalation" "escalating" "$GLOG040"
assert_contains "TC-LGC5-040e: guardian log shows the terminal-STATE zero-kill skip line" "zero-kill wake" "$GLOG040"

# ===========================================================================
echo ""
echo "=== TC-LGC5-050/051: lifetime cap fires (accelerated) and its chunk-watchdog is SIGKILL-non-survivable ==="
# ===========================================================================
LANE050="$TMPROOT/lane050"
mkdir -p "$LANE050"
mkfifo "$LANE050/guard.fifo"
exec {FD050}<>"$LANE050/guard.fifo"
START050=$(date +%s)
ADT_GUARDIAN_CAP_SECONDS_OVERRIDE=3 ADT_GUARDIAN_CAP_CHUNK_SECONDS=1 \
  bash "$LIB_GUARDIAN" --lane-dir "$LANE050" >"$LANE050/guardian.log" 2>&1 &
GUARDIAN_PID050=$!
DEADLINE050=$(( $(date +%s) + 10 ))
while [[ $(date +%s) -lt $DEADLINE050 ]]; do
  kill -0 "$GUARDIAN_PID050" 2>/dev/null || break
  sleep 0.3
done
END050=$(date +%s)
ELAPSED050=$((END050 - START050))
exec {FD050}>&- 2>/dev/null || true
assert_contains "TC-LGC5-050: accelerated lifetime cap fires and is logged" "lifetime cap reached" "$(cat "$LANE050/guardian.log")"
if [[ "$ELAPSED050" -le 8 ]]; then
  assert_pass "TC-LGC5-050b: cap fired within the accelerated window (${ELAPSED050}s), not the real hours-scale cap"
else
  assert_fail "TC-LGC5-050b: took ${ELAPSED050}s — accelerated cap override did not take effect"
fi

# TC-LGC5-051 — chunk-watchdog dies with a SIGKILLed guardian (never
# survives up to the full — here, deliberately long — cap).
LANE051="$TMPROOT/lane051"
mkdir -p "$LANE051"
mkfifo "$LANE051/guard.fifo"
exec {FD051}<>"$LANE051/guard.fifo"
ADT_GUARDIAN_CAP_SECONDS_OVERRIDE=100 ADT_GUARDIAN_CAP_CHUNK_SECONDS=1 \
  bash "$LIB_GUARDIAN" --lane-dir "$LANE051" >"$LANE051/guardian.log" 2>&1 &
GUARDIAN_PID051=$!
sleep 0.5
WD_PID051=$(pgrep -P "$GUARDIAN_PID051" 2>/dev/null | head -1)
kill -9 "$GUARDIAN_PID051" 2>/dev/null
sleep 2
GUARDIAN_ALIVE051=$(kill -0 "$GUARDIAN_PID051" 2>/dev/null && echo yes || echo no)
WD_ALIVE051="unknown"
if [[ -n "$WD_PID051" ]]; then
  WD_ALIVE051=$(kill -0 "$WD_PID051" 2>/dev/null && echo yes || echo no)
fi
exec {FD051}>&- 2>/dev/null || true
assert_eq "TC-LGC5-051: SIGKILLed guardian is gone" "no" "$GUARDIAN_ALIVE051"
if [[ "$WD_PID051" =~ ^[0-9]+$ ]]; then
  assert_eq "TC-LGC5-051b: chunk-watchdog dies within ~1 chunk of a SIGKILLed guardian (never survives to the full 100s cap)" "no" "$WD_ALIVE051"
else
  assert_fail "TC-LGC5-051b: could not identify the chunk-watchdog pid to assert against"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC5-060/061: reap.lock race — guardian EOF-reap vs. a concurrent lane_kill call ==="
# ===========================================================================
NS060="lgc5-060"
export ADT_STATE_ROOT="$(_lane_state_root "$NS060")"
OUT060=$(bash -c '
  set -u
  export ADT_STATE_ROOT="'"$ADT_STATE_ROOT"'"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint proj060 dev 60)
  LANE_DIR=$(lane_install proj060 "$LANE_ID")

  # TERM-trapping fixture so the escalation actually reaches the KILL pass
  # (a bare `sleep` always dies on the first TERM, making a double-KILL
  # regression unobservable — same rationale as TC-LGC3-036).
  setsid bash -c "trap \"\" TERM; while :; do sleep 1; done" & PG=$!
  disown 2>/dev/null || true
  sleep 0.2
  lane_record_pgid "$LANE_DIR" "$PG" agent

  COUNTER_FILE="'"$TMPROOT"'/counter060"
  : > "$COUNTER_FILE"
  kill() {
    if [[ "$1" == "-KILL" ]]; then
      echo "kill" >> "'"$TMPROOT"'/counter060"
    fi
    command kill "$@"
  }
  export -f kill

  mkfifo "$LANE_DIR/guard.fifo"
  exec {ADT_GUARD_FD}<>"$LANE_DIR/guard.fifo"
  export ADT_GUARD_FD
  setsid bash -c "[[ -n \"\${ADT_GUARD_FD:-}\" ]] && exec {ADT_GUARD_FD}>&-; exec bash \"\$1\" --lane-dir \"\$2\"" \
    _ "'"$LIB_GUARDIAN"'" "$LANE_DIR" >>"$LANE_DIR/guardian.log" 2>&1 &
  GUARDIAN_PID=$!
  disown 2>/dev/null || true
  lane_set "$LANE_DIR" GUARDIAN_PID "$GUARDIAN_PID"
  sleep 0.3

  # Trigger the guardians EOF-reap AND a concurrent lane_kill call at
  # (as close to) the same moment.
  exec {ADT_GUARD_FD}>&-
  lane_kill "$LANE_DIR" 3 &
  KPID=$!
  wait "$KPID" 2>/dev/null
  sleep 3
  echo "KILL_CALLS=$(wc -l < "$COUNTER_FILE")"
  kill -9 -- "-$PG" 2>/dev/null || true
' 2>&1)
assert_eq "TC-LGC5-060: guardian EOF-reap racing a concurrent lane_kill call issues exactly ONE SIGKILL against the shared pgid (reap.lock serializes; no double-KILL)" "KILL_CALLS=1" "$(grep -o 'KILL_CALLS=[0-9]*' <<<"$OUT060")"

# TC-LGC5-061 — do_reap's own internal non-reentrant-flock avoidance:
# proves do_reap does NOT call lane_kill (which would re-flock the SAME
# lock file do_reap already holds and self-deadlock for lane_kill's own
# 10s bound). Grep-pin: the escalation inside do_reap calls
# `_kill_group_escalate` directly, never `lane_kill`.
DO_REAP_BODY=$(awk '/^do_reap\(\) \{$/,/^}$/' "$LIB_GUARDIAN")
# Strip comment lines first — do_reap's own doc comments explain, in prose,
# WHY it avoids lane_kill (mentioning the name several times); the check
# below must look only at CODE lines for an actual call.
DO_REAP_CODE=$(grep -v '^\s*#' <<<"$DO_REAP_BODY")
if grep -q '\blane_kill\b' <<<"$DO_REAP_CODE"; then
  assert_fail "TC-LGC5-061: do_reap calls lane_kill — this would self-deadlock against the SAME reap.lock fd do_reap already holds (verified empirically: flock on a second fd against an already-self-held lock file blocks, not a no-op)"
else
  assert_pass "TC-LGC5-061: do_reap does NOT call lane_kill (avoids the non-reentrant-flock self-deadlock); escalates via _kill_group_escalate directly"
fi
assert_contains "TC-LGC5-061b: do_reap's escalation body does call the shared _kill_group_escalate primitive" "_kill_group_escalate" "$DO_REAP_BODY"

# ===========================================================================
echo ""
echo "=== TC-LGC5-070: do_reap tolerates a vanished lane dir (ENOENT) as already-finished ==="
# ===========================================================================
NS070="lgc5-070"
export ADT_STATE_ROOT="$(_lane_state_root "$NS070")"
OUT070=$(bash -c '
  set -u
  export ADT_STATE_ROOT="'"$ADT_STATE_ROOT"'"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint proj070 dev 70)
  LANE_DIR=$(lane_install proj070 "$LANE_ID")
  mkfifo "$LANE_DIR/guard.fifo"
  exec {ADT_GUARD_FD}<>"$LANE_DIR/guard.fifo"
  export ADT_GUARD_FD
  setsid bash -c "[[ -n \"\${ADT_GUARD_FD:-}\" ]] && exec {ADT_GUARD_FD}>&-; exec bash \"\$1\" --lane-dir \"\$2\"" \
    _ "'"$LIB_GUARDIAN"'" "$LANE_DIR" >/tmp/lgc5-070-guardian.log 2>&1 &
  GUARDIAN_PID=$!
  disown 2>/dev/null || true
  sleep 0.3
  # rm -rf the ENTIRE lane dir (simulating GC rule 1.4 having already
  # collected it) BEFORE the guardian ever wakes.
  rm -rf "$LANE_DIR"
  exec {ADT_GUARD_FD}>&-
  sleep 2
  echo "GUARDIAN_ALIVE=$(kill -0 "$GUARDIAN_PID" 2>/dev/null && echo yes || echo no)"
' 2>&1)
assert_contains "TC-LGC5-070: guardian against a vanished lane dir exits cleanly (ENOENT tolerance) rather than erroring/hanging" "GUARDIAN_ALIVE=no" "$OUT070"
assert_contains "TC-LGC5-070b: guardian log names the vanished-dir tolerance" "lane dir vanished" "$(cat /tmp/lgc5-070-guardian.log 2>/dev/null)"
rm -f /tmp/lgc5-070-guardian.log

# ===========================================================================
echo ""
echo "=== TC-LGC5-080/081/082: wrapper install-order grep-pins ==="
# ===========================================================================
for wf in "autonomous-dev.sh:$DEV_WRAPPER" "autonomous-review.sh:$REVIEW_WRAPPER"; do
  name="${wf%%:*}"; file="${wf#*:}"
  MKFIFO_LINE=$(grep -n 'mkfifo "\${ADT_LANE_DIR}/guard.fifo"' "$file" | head -1 | cut -d: -f1)
  OPENFD_LINE=$(grep -n 'exec {ADT_GUARD_FD}<>"\${ADT_LANE_DIR}/guard.fifo"' "$file" | head -1 | cut -d: -f1)
  SPAWN_LINE=$(grep -n 'lib-guardian.sh' "$file" | head -1 | cut -d: -f1)
  if [[ -n "$MKFIFO_LINE" && -n "$OPENFD_LINE" && "$MKFIFO_LINE" -lt "$OPENFD_LINE" ]]; then
    assert_pass "TC-LGC5-080 ($name): mkfifo (line $MKFIFO_LINE) precedes the write-fd open (line $OPENFD_LINE)"
  else
    assert_fail "TC-LGC5-080 ($name): mkfifo (line ${MKFIFO_LINE:-MISSING}) does not precede the write-fd open (line ${OPENFD_LINE:-MISSING})"
  fi
  if [[ -n "$OPENFD_LINE" && -n "$SPAWN_LINE" && "$OPENFD_LINE" -lt "$SPAWN_LINE" ]]; then
    assert_pass "TC-LGC5-081 ($name): write-fd open (line $OPENFD_LINE) precedes the guardian spawn (line $SPAWN_LINE) — the load-bearing FIFO-open-ordering contract"
  else
    assert_fail "TC-LGC5-081 ($name): write-fd open (line ${OPENFD_LINE:-MISSING}) does NOT precede the guardian spawn (line ${SPAWN_LINE:-MISSING})"
  fi
  # TC-LGC5-082: the guardian's OWN spawn site closes its inherited copy of
  # ADT_GUARD_FD before exec'ing into lib-guardian.sh (else the guardian
  # becomes a second write-holder of its own watched fifo and can never
  # see EOF — the bug found empirically while smoke-testing this PR).
  SPAWN_CONTEXT=$(sed -n "$((SPAWN_LINE-3)),$((SPAWN_LINE+1))p" "$file" 2>/dev/null)
  assert_contains "TC-LGC5-082 ($name): the guardian's own spawn line closes its inherited ADT_GUARD_FD before exec'ing lib-guardian.sh" 'exec {ADT_GUARD_FD}>&-' "$SPAWN_CONTEXT"
done

# ===========================================================================
echo ""
echo "=== TC-LGC5-090: setsid-absent — wrapper install logs a loud error and does NOT abort ==="
# ===========================================================================
for wf in "autonomous-dev.sh:$DEV_WRAPPER" "autonomous-review.sh:$REVIEW_WRAPPER"; do
  name="${wf%%:*}"; file="${wf#*:}"
  # Extract the guardian-install block (bounded by its own comment markers)
  # and prove: (a) it checks `command -v setsid`, (b) the failure branch
  # does NOT call `exit`, only logs — i.e. degradation, not abort.
  BLOCK=$(awk '/Lane-GC PR-5 \/ INV-118\] Guardian sidecar install/,/^# GitHub authentication$/' "$file")
  assert_contains "TC-LGC5-090 ($name): guardian install checks for setsid" 'command -v setsid' "$BLOCK"
  assert_contains "TC-LGC5-090b ($name): setsid-absent branch mentions util-linux (actionable remediation)" 'util-linux' "$BLOCK"
  SETSID_BRANCH=$(awk '/! command -v setsid/,/elif/' <<<"$BLOCK" | head -n -1)
  if grep -qE '^\s*exit\b' <<<"$SETSID_BRANCH"; then
    assert_fail "TC-LGC5-090c ($name): setsid-absent branch calls exit — should DEGRADE (log + continue), never abort the wrapper run"
  else
    assert_pass "TC-LGC5-090c ($name): setsid-absent branch degrades (no exit) — GC remains the backstop reaper"
  fi
done

# ===========================================================================
echo ""
echo "=== TC-LGC5-100: FD-hygiene grep-pin — every literal spawn site touched by this PR closes ADT_GUARD_FD ==="
# ===========================================================================
# Honest scope (design §10 residual wording, reused verbatim for this PR):
# this grep-pin guards LITERAL spawn sites only — pipeline subshells,
# `bash -c '...'` strings inside OTHER strings, or dynamically constructed
# commands are not (and cannot be) caught here. A missed site degrades EOF
# from "wrapper died" to "subtree died" (still correct, just later) rather
# than a false kill.
declare -A SITES=(
  ["lib-agent.sh:_run_with_timeout agent spawn"]="$LIB_AGENT"
  ["lib-agent.sh:heartbeat loop"]="$LIB_AGENT"
  ["lib-agent.sh:sigterm-trap escalators"]="$LIB_AGENT"
  ["lib-auth.sh:token daemon spawn"]="$LIB_AUTH"
  ["lib-lane.sh:lane_kill escalator"]="$SCRIPTS/lib-lane.sh"
  ["lib-lane.sh:_bounded_call spawn"]="$SCRIPTS/lib-lane.sh"
  ["autonomous-review.sh:smoke probe subshell"]="$REVIEW_WRAPPER"
  ["autonomous-review.sh:fan-out subshell"]="$REVIEW_WRAPPER"
  # review round-1: process substitutions fork children too — the run.log
  # tee in BOTH wrappers, and the command-mode E2E lane, each held the
  # guard fd open past a SIGKILLed wrapper before the close was added.
  ["autonomous-dev.sh:run.log tee process substitution"]="$DEV_WRAPPER"
  ["autonomous-review.sh:run.log tee process substitution"]="$REVIEW_WRAPPER"
  ["lib-review-e2e.sh:command-mode E2E lane"]="$SCRIPTS/lib-review-e2e.sh"
)
for label in "${!SITES[@]}"; do
  file="${SITES[$label]}"
  cnt=$(grep -c 'ADT_GUARD_FD:-.*exec {ADT_GUARD_FD}>&-\|exec {ADT_GUARD_FD}>&-' "$file" 2>/dev/null || echo 0)
  if [[ "$cnt" -gt 0 ]]; then
    assert_pass "TC-LGC5-100 ($label): ${file##*/} carries at least one ADT_GUARD_FD close guard (found $cnt total in file)"
  else
    assert_fail "TC-LGC5-100 ($label): ${file##*/} carries NO ADT_GUARD_FD close guard"
  fi
done
# Precise per-file MINIMUM counts (each named site above is a distinct
# occurrence within its file) — catches a regression that removes ONE site
# while leaving another, which the presence-only check above would miss.
LIB_AGENT_CNT=$(grep -c 'ADT_GUARD_FD:-.*exec {ADT_GUARD_FD}>&-' "$LIB_AGENT")
if [[ "$LIB_AGENT_CNT" -ge 3 ]]; then
  assert_pass "TC-LGC5-101: lib-agent.sh carries >= 3 distinct ADT_GUARD_FD close guards (agent spawn, heartbeat, escalators) — found $LIB_AGENT_CNT"
else
  assert_fail "TC-LGC5-101: lib-agent.sh carries only $LIB_AGENT_CNT ADT_GUARD_FD close guard(s) — expected >= 3"
fi
LIB_LANE_CNT=$(grep -c 'ADT_GUARD_FD:-.*exec {ADT_GUARD_FD}>&-' "$SCRIPTS/lib-lane.sh")
if [[ "$LIB_LANE_CNT" -ge 2 ]]; then
  assert_pass "TC-LGC5-102: lib-lane.sh carries >= 2 distinct ADT_GUARD_FD close guards (lane_kill escalator, _bounded_call) — found $LIB_LANE_CNT"
else
  assert_fail "TC-LGC5-102: lib-lane.sh carries only $LIB_LANE_CNT ADT_GUARD_FD close guard(s) — expected >= 2"
fi
REVIEW_CNT=$(grep -c 'ADT_GUARD_FD:-.*exec {ADT_GUARD_FD}>&-' "$REVIEW_WRAPPER")
if [[ "$REVIEW_CNT" -ge 2 ]]; then
  assert_pass "TC-LGC5-103: autonomous-review.sh carries >= 2 distinct ADT_GUARD_FD close guards (smoke probe, fan-out subshell) — found $REVIEW_CNT"
else
  assert_fail "TC-LGC5-103: autonomous-review.sh carries only $REVIEW_CNT ADT_GUARD_FD close guard(s) — expected >= 2"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC5-110: cleanup() handshake ordering — precedes network work, follows the reap-first block ==="
# ===========================================================================
for wf in "autonomous-dev.sh:$DEV_WRAPPER" "autonomous-review.sh:$REVIEW_WRAPPER"; do
  name="${wf%%:*}"; file="${wf#*:}"
  REAP_LINE=$(grep -n 'lane_reap "\$ADT_LANE_DIR"' "$file" | head -1 | cut -d: -f1)
  HANDSHAKE_LINE=$(grep -n "printf 'done" "$file" | head -1 | cut -d: -f1)
  FIRST_NET_LINE=$(grep -nE '^\s*(_teardown_call )?(itp_post_comment|itp_transition_state|chp_pr_list|drain_agent_pr_create|drain_agent_bot_triggers|get_gh_app_token|emit_verdict_trailer)' "$file" | head -1 | cut -d: -f1)
  if [[ -n "$REAP_LINE" && -n "$HANDSHAKE_LINE" && "$REAP_LINE" -lt "$HANDSHAKE_LINE" ]]; then
    assert_pass "TC-LGC5-110 ($name): reap-first block (line $REAP_LINE) precedes the guardian handshake (line $HANDSHAKE_LINE)"
  else
    assert_fail "TC-LGC5-110 ($name): reap-first block (line ${REAP_LINE:-MISSING}) does not precede the handshake (line ${HANDSHAKE_LINE:-MISSING})"
  fi
  if [[ -n "$HANDSHAKE_LINE" && -n "$FIRST_NET_LINE" && "$HANDSHAKE_LINE" -lt "$FIRST_NET_LINE" ]]; then
    assert_pass "TC-LGC5-110b ($name): guardian handshake (line $HANDSHAKE_LINE) precedes the first network-work call site (line $FIRST_NET_LINE)"
  else
    assert_fail "TC-LGC5-110b ($name): guardian handshake does not precede the first network-work call site"
  fi
done

# ===========================================================================
echo ""
echo "=== TC-LGC5-120: lib-guardian.sh is never symlinked by install-project-hooks.sh (lib-*.sh naming) ==="
# ===========================================================================
INSTALLER="$PROJECT_ROOT/skills/autonomous-common/scripts/install-project-hooks.sh"
if [[ -f "$INSTALLER" ]]; then
  # is_entry_script's own case statement excludes lib-*.sh — confirm the
  # PATTERN still matches our new file's basename (a naming-convention
  # regression guard, not a full re-implementation of the installer's logic).
  BASENAME="lib-guardian.sh"
  case "$BASENAME" in
    lib-*.sh) assert_pass "TC-LGC5-120: lib-guardian.sh matches the lib-*.sh pattern install-project-hooks.sh excludes from symlinking" ;;
    *) assert_fail "TC-LGC5-120: lib-guardian.sh unexpectedly does NOT match lib-*.sh" ;;
  esac
else
  assert_fail "TC-LGC5-120: install-project-hooks.sh not found at expected path"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC5-130: no forbidden phrases / private-repo references ==="
# ===========================================================================
TOUCHED_FILES=("$LIB_GUARDIAN" "$DEV_WRAPPER" "$REVIEW_WRAPPER" "$LIB_AGENT" "$LIB_AUTH" "$SCRIPTS/lib-lane.sh")
PRIVATE_HITS=$(grep -niE 'quant-scorer|vidsyllabus|issuecomment-[0-9]+' "${TOUCHED_FILES[@]}" 2>/dev/null || true)
if [[ -z "$PRIVATE_HITS" ]]; then
  assert_pass "TC-LGC5-130: no private-repo references in any touched file"
else
  assert_fail "TC-LGC5-130: found private-repo references: $PRIVATE_HITS"
fi
# Scoped to lib-guardian.sh ONLY (a brand-new file with no legitimate
# reason to mention it) — autonomous-review.sh legitimately names the real
# `codex review` CLI subcommand throughout its pre-existing content, so a
# whole-file check there would permanently false-positive.
CODEX_PHRASE_HITS=$(grep -ni 'codex review' "$LIB_GUARDIAN" 2>/dev/null || true)
if [[ -z "$CODEX_PHRASE_HITS" ]]; then
  assert_pass "TC-LGC5-130b: no 'codex review' phrase in the new lib-guardian.sh"
else
  assert_fail "TC-LGC5-130b: found 'codex review' phrase in lib-guardian.sh: $CODEX_PHRASE_HITS"
fi

# ===========================================================================
echo ""
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
