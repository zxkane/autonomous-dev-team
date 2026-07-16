#!/bin/bash
# test-agent-progress-lease.sh — Unit tests for the current-run agent-progress
# lease (issue #493, producer half of the Step 5a false-SIGTERM fix).
#
# Covers docs/test-cases/agent-progress-lease.md TC-LEASE-001..020:
#   - R1: lease file contract (_agent_progress_refresh / _agent_progress_init /
#     _agent_progress_cleanup) — atomic write, mode 0600, symlink refusal, pid
#     mirrors the CURRENT pid-file content, own-run-only cleanup, prior-run
#     freshness cannot leak to a new run.
#   - R2: what counts as a progress event (launch + each complete output
#     record; heartbeat alone must NOT refresh the lease).
#   - R3: the shared pass-through recorder (_agent_progress_recorder) —
#     byte-identical passthrough, exit-status propagation, composes with the
#     existing codex/opencode capture filters, unknown-CLI fallback wiring,
#     gemini's conditional json/line framing.
#   - R4: the Claude stream-json migration does not break the three existing
#     consumers of the final `{"type":"result",...}` log line.
#
# TC-LEASE-024..027 (issue #508): the recorder's shared-nonblocking-pipe
# EAGAIN hazard — the wrapper's `exec > >(tee -a run.log)` stdout is the SAME
# open file description the Claude CLI (Node.js) inherits as its stderr, and
# Node's O_NONBLOCK flag on that shared pipe can make the recorder's own
# printf fail transiently. Driven through a REAL O_NONBLOCK pipe via a
# python3 fcntl helper with a stalling/never-draining reader (skipped if
# python3 is unavailable): byte-identical passthrough (checksum + line count
# + the no-trailing-newline final line) under real EAGAIN pressure, zero
# write-error diagnostics for the transient case, bounded-retry exhaustion
# completing instead of hanging with exactly one diagnostic, and the
# zero-AGENT_PROGRESS_FILE fast path staying a byte-identical bare `cat`
# under the same pressure.
#
# Strategy: source lib-agent.sh (+ lib-dispatch.sh / lib-metrics.sh where
# needed) in sandboxed subshells with stub CLIs on PATH, mirroring
# test-lib-agent-codex.sh / test-lib-agent-agy.sh. No real sleeps — a fake
# `date` stub or explicit epoch arithmetic stands in for a frozen clock where
# ordering matters (except TC-LEASE-024..027's pipe-pressure harness, which
# needs real wall-clock timing to force genuine EAGAIN and to prove the
# bounded-retry loop does not hang).
#
# Run: bash tests/unit/test-agent-progress-lease.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"
LIB_DISPATCH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
LIB_METRICS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-metrics.sh"
PROBE_SCRIPT="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/session-log-probe-remote-aws-ssm.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

ok() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then ok "$desc"; else
    bad "$desc"
    echo "      expected='$expected'"
    echo "      actual=  '$actual'"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then ok "$desc"; else
    bad "$desc"
    echo "      needle='$needle'"
    echo "      haystack[0..300]='${haystack:0:300}'"
  fi
}

assert_returns() {
  local desc="$1" expected_rc="$2"; shift 2
  "$@"
  local actual_rc=$?
  if [[ "$expected_rc" == "$actual_rc" ]]; then ok "$desc"; else
    bad "$desc"
    echo "      expected_rc=$expected_rc actual_rc=$actual_rc"
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT
PID_DIR="$TMPROOT/pid"
mkdir -p "$PID_DIR"
chmod 700 "$PID_DIR"

# ---------------------------------------------------------------------------
echo "=== Source-of-truth: lease helpers are defined ==="
# ---------------------------------------------------------------------------
for fn in _agent_progress_refresh _agent_progress_init _agent_progress_cleanup _agent_progress_recorder; do
  if grep -qE "^${fn}\(\)" "$LIB"; then
    ok "$fn defined in lib-agent.sh"
  else
    bad "$fn missing from lib-agent.sh"
  fi
done

# run_in_sandbox <script> — source lib-agent.sh in a clean subshell with the
# sandbox PID dir + a fixed PROJECT_ID/PROJECT_DIR, then run the passed <script>
# snippet (as a bash -c script) after the source.
run_in_sandbox() {
  local script="$1"
  ( set -uo pipefail
    # -u AUTONOMOUS_CONF_DIR / unset AGENT_PID_FILE: this suite can run
    # dispatched by the live autonomous dispatcher on this self-hosting box,
    # which exports both — without stripping them, load_autonomous_conf
    # would source the OPERATOR's real autonomous.conf (overriding the
    # per-test AGENT_CMD) and a stray AGENT_PID_FILE would leak in. Matches
    # the same isolation test-cli-adapters.sh already applies.
    env -u AUTONOMOUS_CONF_DIR \
    AUTONOMOUS_PID_DIR="$PID_DIR" \
    PROJECT_ID="testproj" \
    PROJECT_DIR="$TMPROOT" \
    AGENT_CMD=claude \
    bash -c '
      unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
      source "'"$LIB"'"
      '"$script"'
    '
  )
}

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LEASE-006 / TC-LEASE-007: refresh writes mode-0600, refuses symlinks ==="
# ---------------------------------------------------------------------------
PROGRESS_FILE="$TMPROOT/issue-1.progress.json"
RUNID_FILE="$TMPROOT/issue-1.run-id"
PIDFILE="$TMPROOT/issue-1.pid"
echo 4242 > "$PIDFILE"

run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export AGENT_PROGRESS_RUNID_FILE="'"$RUNID_FILE"'"
  export RUN_ID="run-A"
  _agent_progress_init
'

if [[ -f "$PROGRESS_FILE" ]]; then ok "TC-LEASE-001 lease file created on init"; else bad "TC-LEASE-001 lease file missing after init"; fi
if [[ -f "$RUNID_FILE" ]]; then ok "TC-LEASE-001 run-id file created on init"; else bad "TC-LEASE-001 run-id file missing after init"; fi
assert_eq "TC-LEASE-001 run-id file content == RUN_ID" "run-A" "$(cat "$RUNID_FILE" 2>/dev/null)"

mode=$(stat -c '%a' "$PROGRESS_FILE" 2>/dev/null || stat -f '%Lp' "$PROGRESS_FILE" 2>/dev/null)
assert_eq "TC-LEASE-007 progress file mode is 0600" "600" "$mode"
mode2=$(stat -c '%a' "$RUNID_FILE" 2>/dev/null || stat -f '%Lp' "$RUNID_FILE" 2>/dev/null)
assert_eq "TC-LEASE-007 run-id file mode is 0600" "600" "$mode2"

if command -v jq >/dev/null 2>&1; then
  schema=$(jq -r '.schema_version' "$PROGRESS_FILE" 2>/dev/null)
  assert_eq "TC-LEASE-001 lease schema_version is 1" "1" "$schema"
  run_id_field=$(jq -r '.run_id' "$PROGRESS_FILE" 2>/dev/null)
  assert_eq "TC-LEASE-001 lease run_id matches RUN_ID" "run-A" "$run_id_field"
  pid_field=$(jq -r '.pid' "$PROGRESS_FILE" 2>/dev/null)
  assert_eq "TC-LEASE-001 lease pid mirrors AGENT_PID_FILE content" "4242" "$pid_field"
  epoch_field=$(jq -r '.updated_at_epoch' "$PROGRESS_FILE" 2>/dev/null)
  [[ "$epoch_field" =~ ^[0-9]+$ ]] && ok "TC-LEASE-001 lease updated_at_epoch is numeric" || bad "TC-LEASE-001 updated_at_epoch not numeric: $epoch_field"
fi

# Symlink refusal (TC-LEASE-006): plant a symlink at the progress path and
# confirm a refresh does not follow/overwrite it.
rm -f "$PROGRESS_FILE"
ln -s /etc/passwd "$PROGRESS_FILE"
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export RUN_ID="run-A"
  _agent_progress_refresh
'
if [[ -L "$PROGRESS_FILE" ]]; then
  ok "TC-LEASE-006 symlinked progress path left untouched (still a symlink)"
else
  bad "TC-LEASE-006 symlinked progress path was replaced"
fi
target=$(readlink "$PROGRESS_FILE" 2>/dev/null)
assert_eq "TC-LEASE-006 symlink target unchanged" "/etc/passwd" "$target"
rm -f "$PROGRESS_FILE"

rm -f "$RUNID_FILE"
ln -s /etc/passwd "$RUNID_FILE"
run_in_sandbox '
  export AGENT_PROGRESS_RUNID_FILE="'"$RUNID_FILE"'"
  export RUN_ID="run-Z"
  _agent_progress_init
'
target2=$(readlink "$RUNID_FILE" 2>/dev/null)
assert_eq "TC-LEASE-006 run-id symlink target unchanged" "/etc/passwd" "$target2"
rm -f "$RUNID_FILE"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LEASE-002 / TC-LEASE-003: refresh advances epoch; heartbeat does NOT ==="
# ---------------------------------------------------------------------------
rm -f "$PROGRESS_FILE" "$RUNID_FILE"
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export AGENT_PROGRESS_RUNID_FILE="'"$RUNID_FILE"'"
  export RUN_ID="run-B"
  _agent_progress_init
'
epoch1=$(jq -r '.updated_at_epoch' "$PROGRESS_FILE" 2>/dev/null)

# Force a later timestamp deterministically via a frozen-clock `date` stub on
# PATH (no real sleep) — the ONLY `date` call in the refresh path is
# `lib-agent.sh`'s own `date +%s` (verified: no other timestamp source feeds
# updated_at_epoch), so shadowing it on PATH for this one sandboxed subshell
# is a safe, deterministic stand-in for "time passed".
FAKE_DATE_BIN="$TMPROOT/fake-date-bin"
mkdir -p "$FAKE_DATE_BIN"
cat > "$FAKE_DATE_BIN/date" <<EOF
#!/bin/bash
if [[ "\$1" == "+%s" ]]; then
  echo "\$(( $epoch1 + 1000 ))"
else
  exec /usr/bin/date "\$@"
fi
EOF
chmod +x "$FAKE_DATE_BIN/date"
(
  PATH="$FAKE_DATE_BIN:$PATH" \
  run_in_sandbox '
    export AGENT_PID_FILE="'"$PIDFILE"'"
    export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
    export RUN_ID="run-B"
    _agent_progress_refresh
  '
)
epoch2=$(jq -r '.updated_at_epoch' "$PROGRESS_FILE" 2>/dev/null)
if [[ "$epoch2" -ge "$epoch1" ]]; then
  ok "TC-LEASE-002 second refresh's epoch is >= the first"
else
  bad "TC-LEASE-002 epoch regressed: $epoch1 -> $epoch2"
fi

# TC-LEASE-003 regression guard: heartbeat's own touch logic never calls
# _agent_progress_refresh — assert the source-of-truth directly (the
# function body of install_agent_heartbeat must not reference it).
heartbeat_body=$(awk '/^install_agent_heartbeat\(\)/,/^}/' "$LIB")
if [[ "$heartbeat_body" != *"_agent_progress_refresh"* ]]; then
  ok "TC-LEASE-003 install_agent_heartbeat never calls _agent_progress_refresh"
else
  bad "TC-LEASE-003 install_agent_heartbeat unexpectedly calls _agent_progress_refresh"
fi

# Behavioral heartbeat regression: no real sleep — the heartbeat loop's OWN
# `sleep "$interval"` call is shadowed with a fake counting no-op (subshells
# spawned via `( ... ) &` inherit the parent shell's function table, so this
# override reaches the backgrounded loop). The driver then busy-waits — a
# bounded, no-sleep spin on the tick counter, capped as a safety valve rather
# than a timing assumption — for >= 2 ticks before asserting, instead of
# waiting a fixed wall-clock duration hoping the real interval fired twice.
rm -f "$PROGRESS_FILE"
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export RUN_ID="run-B"
  _agent_progress_refresh
  epoch_before=$(jq -r ".updated_at_epoch" "'"$PROGRESS_FILE"'")
  TICK_FILE="'"$TMPROOT"'/hb-ticks"
  : > "$TICK_FILE"
  sleep() { echo x >> "$TICK_FILE"; }
  HEARTBEAT_INTERVAL_SECONDS=1 install_agent_heartbeat
  _i=0
  while [[ "$(wc -l < "$TICK_FILE")" -lt 2 && "$_i" -lt 5000000 ]]; do
    _i=$((_i + 1))
  done
  kill "$_AGENT_HEARTBEAT_PID" 2>/dev/null || true
  epoch_after=$(jq -r ".updated_at_epoch" "'"$PROGRESS_FILE"'")
  if [[ "$epoch_before" == "$epoch_after" ]]; then
    echo "UNCHANGED"
  else
    echo "CHANGED:$epoch_before:$epoch_after"
  fi
' > "$TMPROOT/hb-result.txt" 2>/dev/null
hb_result=$(cat "$TMPROOT/hb-result.txt")
assert_eq "TC-LEASE-003 lease epoch unchanged after N heartbeat ticks" "UNCHANGED" "$hb_result"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LEASE-004: lease pid mirrors CURRENT pid-file content across both publication phases ==="
# ---------------------------------------------------------------------------
rm -f "$PROGRESS_FILE"
echo 1111 > "$PIDFILE"
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export RUN_ID="run-C"
  _agent_progress_refresh
'
pid1=$(jq -r '.pid' "$PROGRESS_FILE" 2>/dev/null)
assert_eq "TC-LEASE-004 lease pid == phase-1 (wrapper \$\$ placeholder)" "1111" "$pid1"

echo 2222 > "$PIDFILE"
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export RUN_ID="run-C"
  _agent_progress_refresh
'
pid2=$(jq -r '.pid' "$PROGRESS_FILE" 2>/dev/null)
assert_eq "TC-LEASE-004 lease pid == phase-2 (republished PGID), NOT cached" "2222" "$pid2"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LEASE-005: atomic write — no partial JSON ever observable ==="
# ---------------------------------------------------------------------------
# The writer uses mktemp in the SAME dir + mv -f. Assert no stray .progress.*
# tmp file survives a successful write, and the final file always parses.
rm -f "$PROGRESS_FILE"
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export RUN_ID="run-D"
  for i in 1 2 3 4 5; do _agent_progress_refresh; done
'
stray=$(find "$TMPROOT" -maxdepth 1 -name '.progress.*' 2>/dev/null | wc -l)
assert_eq "TC-LEASE-005 no stray tmp file left behind after repeated refreshes" "0" "$stray"
if command -v jq >/dev/null 2>&1 && jq -e . "$PROGRESS_FILE" >/dev/null 2>&1; then
  ok "TC-LEASE-005 final lease file is valid JSON"
else
  bad "TC-LEASE-005 final lease file failed to parse as JSON"
fi

# TC-LEASE-005b: a CONCURRENT reader — not just a post-hoc parse of the final
# file — proves the no-partial-read contract. A non-atomic direct overwrite
# (e.g. writing straight into AGENT_PROGRESS_FILE instead of tmp+rename) would
# still pass the two assertions above (they only inspect the file AFTER all
# writes finish) but would show a torn/partial read to a reader racing the
# writes. The reader spins for the writer's ENTIRE run (gated on a
# writer-done marker, not a fixed iteration count, so it can't finish early
# and miss most of the race) while re-reading+parsing the lease as fast as
# possible; ANY parse failure on an EXISTING, non-empty file is a torn read.
rm -f "$PROGRESS_FILE"
RACE_READS_LOG="$TMPROOT/race-reads.log"
RACE_DONE_FILE="$TMPROOT/race-writer-done"
: > "$RACE_READS_LOG"
rm -f "$RACE_DONE_FILE"
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export RUN_ID="run-race"
  (
    while [[ ! -f "'"$RACE_DONE_FILE"'" ]]; do
      if [[ -s "'"$PROGRESS_FILE"'" ]]; then
        if content=$(cat "'"$PROGRESS_FILE"'" 2>/dev/null) && [[ -n "$content" ]]; then
          if printf "%s" "$content" | jq -e . >/dev/null 2>&1; then
            echo "OK" >> "'"$RACE_READS_LOG"'"
          else
            echo "TORN:$content" >> "'"$RACE_READS_LOG"'"
          fi
        fi
      fi
    done
  ) &
  reader_pid=$!
  for i in $(seq 1 500); do _agent_progress_refresh; done
  touch "'"$RACE_DONE_FILE"'"
  wait "$reader_pid"
'
race_reads=$(wc -l < "$RACE_READS_LOG" 2>/dev/null || echo 0)
race_torn=$(grep -c '^TORN:' "$RACE_READS_LOG" 2>/dev/null)
[[ -z "$race_torn" ]] && race_torn=0
if [[ "$race_reads" -gt 0 ]]; then
  ok "TC-LEASE-005b concurrent reader observed $race_reads reads during the write race"
else
  bad "TC-LEASE-005b concurrent reader never observed the lease file — race not exercised"
fi
assert_eq "TC-LEASE-005b no torn/partial read observed by the concurrent reader" "0" "$race_torn"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LEASE-008 / TC-LEASE-009 / TC-LEASE-010: cleanup is own-run-only ==="
# ---------------------------------------------------------------------------
rm -f "$PROGRESS_FILE" "$RUNID_FILE"
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export AGENT_PROGRESS_RUNID_FILE="'"$RUNID_FILE"'"
  export RUN_ID="run-E"
  _agent_progress_init
  _agent_progress_cleanup
'
if [[ ! -f "$PROGRESS_FILE" && ! -f "$RUNID_FILE" ]]; then
  ok "TC-LEASE-008 cleanup removes own-run lease + run-id files"
else
  bad "TC-LEASE-008 cleanup left files behind"
fi

# TC-LEASE-009 / TC-LEASE-010: a newer run's files must survive a STALE
# cleanup call for an OLDER run_id (simulates a race where run-A's teardown
# fires after run-B has already started for the same issue).
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export AGENT_PROGRESS_RUNID_FILE="'"$RUNID_FILE"'"
  export RUN_ID="run-A"
  _agent_progress_init
'
run_a_runid=$(cat "$RUNID_FILE")
assert_eq "TC-LEASE-010 run-A initial run-id file is run-A (no prior-run leak)" "run-A" "$run_a_runid"

# run-B starts for the SAME issue (dispatcher re-dispatch), overwriting both
# sidecars before run-A's stale cleanup ever fires.
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export AGENT_PROGRESS_RUNID_FILE="'"$RUNID_FILE"'"
  export RUN_ID="run-B"
  _agent_progress_init
'
assert_eq "TC-LEASE-010 run-B overwrites run-id to run-B before any run-B output" "run-B" "$(cat "$RUNID_FILE")"

# Stale run-A cleanup fires (its own RUN_ID is still "run-A").
run_in_sandbox '
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export AGENT_PROGRESS_RUNID_FILE="'"$RUNID_FILE"'"
  export RUN_ID="run-A"
  _agent_progress_cleanup
'
if [[ -f "$RUNID_FILE" && -f "$PROGRESS_FILE" ]]; then
  ok "TC-LEASE-009 run-B's files survive run-A's stale (compare-then-unlink) cleanup"
else
  bad "TC-LEASE-009 run-B's files were deleted by run-A's stale cleanup"
fi
assert_eq "TC-LEASE-009 run-id file still names run-B after run-A's stale cleanup" "run-B" "$(cat "$RUNID_FILE" 2>/dev/null)"

# TC-LEASE-022: round-2 review finding — genuine INTERLEAVING (not just
# sequential ordering, which TC-LEASE-009/010 above already cover) between a
# stale run-A cleanup and a fresh run-B init. Without the
# _agent_progress_lock_acquire mutex, run-A's cleanup could read the run-id
# file's content (still "run-A") and THEN — before its own `rm` executes —
# let run-B's init overwrite BOTH sidecars; the late `rm` deletes the run-id
# file unconditionally (unlink doesn't re-check content), leaving the
# run-id file GONE while progress.json still names run-B. That split state
# does NOT self-heal (only _agent_progress_init ever rewrites the run-id
# file), unlike the documented compare-then-unlink residual.
#
# Forces the interleaving deterministically with the test-only
# _AGENT_PROGRESS_CLEANUP_TEST_DELAY_SECONDS hook: start run-A's cleanup
# first (it wins the lock and sleeps mid-critical-section), then fire run-B's
# init while the lock is held. If the lock works, run-B's init blocks until
# run-A's cleanup fully releases, so the two sidecars can never end up
# naming different runs.
rm -f "$PROGRESS_FILE" "$RUNID_FILE"
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export AGENT_PROGRESS_RUNID_FILE="'"$RUNID_FILE"'"
  export RUN_ID="run-A"
  _agent_progress_init
'
run_in_sandbox '
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export AGENT_PROGRESS_RUNID_FILE="'"$RUNID_FILE"'"
  export RUN_ID="run-A"
  export _AGENT_PROGRESS_CLEANUP_TEST_DELAY_SECONDS=1
  _agent_progress_cleanup
' &
STALE_CLEANUP_PID=$!
sleep 0.3
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export AGENT_PROGRESS_RUNID_FILE="'"$RUNID_FILE"'"
  export RUN_ID="run-B"
  _agent_progress_init
'
wait "$STALE_CLEANUP_PID"

runid_after="$(cat "$RUNID_FILE" 2>/dev/null || echo MISSING)"
assert_eq "TC-LEASE-022 run-id file names run-B after the interleaved race resolves (not deleted, not split)" "run-B" "$runid_after"
if [[ -f "$PROGRESS_FILE" ]]; then
  ok "TC-LEASE-022 progress.json survives the interleaved race"
else
  bad "TC-LEASE-022 progress.json was deleted by the interleaved race"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LEASE-018: launch event writes a lease before any CLI output (R2 case 1) ==="
# ---------------------------------------------------------------------------
BIN="$TMPROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/timeout" <<'EOF'
#!/bin/bash
shift 3
exec "$@"
EOF
chmod +x "$BIN/timeout"
# A CLI stub that BLOCKS on a control FIFO before producing ANY output — a
# deterministic gate, not a timing guess (a fixed `sleep N` before the CLI's
# first output can flake on a slow CI host if N is too short, or waste time
# if too long). The stub only unblocks once the harness explicitly opens the
# FIFO for writing, so "no output yet" is guaranteed, not merely likely.
GATE_FIFO="$TMPROOT/launch-gate.fifo"
rm -f "$GATE_FIFO"
mkfifo "$GATE_FIFO"
cat > "$BIN/claude" <<EOF
#!/bin/bash
cat >/dev/null
read -r _ < "$GATE_FIFO"
echo '{"type":"result","stop_reason":"end_turn","terminal_reason":"completed"}'
EOF
chmod +x "$BIN/claude"

LAUNCH_PROGRESS="$TMPROOT/launch.progress.json"
LAUNCH_PID="$TMPROOT/launch.pid"
rm -f "$LAUNCH_PROGRESS"
(
  env -u AUTONOMOUS_CONF_DIR \
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=claude \
  AGENT_PERMISSION_MODE=auto \
  AGENT_PID_FILE="$LAUNCH_PID" \
  AGENT_PROGRESS_FILE="$LAUNCH_PROGRESS" \
  RUN_ID="run-launch" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV
    source "'"$LIB"'"
    run_agent "launch-session" "hello" "" "" >/dev/null 2>&1 &
    bgpid=$!
    # Busy-spin (no sleep) for the lease to appear WHILE the CLI stub is
    # still blocked on the gate FIFO (before its first output line) — proves
    # the launch event, not an output-record event, produced it. Bounded
    # iteration count is a safety valve, not a timing assumption.
    _i=0
    while [[ ! -f "'"$LAUNCH_PROGRESS"'" && "$_i" -lt 5000000 ]]; do
      _i=$((_i + 1))
    done
    # Open the gate: let the blocked CLI stub proceed to its output line now
    # that the lease-before-output assertion below has its evidence.
    exec 9>"'"$GATE_FIFO"'"
    printf "go\n" >&9
    exec 9>&-
    wait "$bgpid"
  '
) 2>&1 | tail -5 >/dev/null
if [[ -f "$LAUNCH_PROGRESS" ]]; then
  ok "TC-LEASE-018 lease exists from the launch event alone (before first CLI output)"
else
  bad "TC-LEASE-018 lease was not created by the launch event"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LEASE-011 / TC-LEASE-016: recorder is byte-identical passthrough; exit status propagates ==="
# ---------------------------------------------------------------------------
FIXTURE="$TMPROOT/claude-stream.jsonl"
cat > "$FIXTURE" <<'EOF'
{"type":"system","subtype":"init","session_id":"abc"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","content":"file1\nfile2"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}
{"type":"result","subtype":"success","stop_reason":"end_turn","terminal_reason":"completed","duration_ms":1234,"usage":{"input_tokens":100,"output_tokens":20}}
EOF

RECORDER_PROGRESS="$TMPROOT/recorder.progress.json"
recorded_out=$(
  run_in_sandbox '
    export AGENT_PID_FILE="'"$PIDFILE"'"
    export AGENT_PROGRESS_FILE="'"$RECORDER_PROGRESS"'"
    export RUN_ID="run-rec"
    cat "'"$FIXTURE"'" | _agent_progress_recorder json
  '
)
fixture_content=$(cat "$FIXTURE")
assert_eq "TC-LEASE-011 recorder passthrough is byte-identical to the fixture" "$fixture_content" "$recorded_out"
if [[ -f "$RECORDER_PROGRESS" ]]; then
  ok "TC-LEASE-011 recorder refreshed the lease while streaming records"
else
  bad "TC-LEASE-011 recorder never refreshed the lease"
fi

# TC-LEASE-011b: a final line with NO trailing newline must survive byte-for-
# byte — including under `set -e`, where the loop's own `read` returning
# non-zero at EOF must not abort the pipeline stage before that line's own
# printf runs (the production call sites wrap run_agent/resume_agent in
# `set +e`, but the recorder itself must not rely on the caller's set -e
# posture to avoid dropping the final line).
NO_NEWLINE_PROGRESS="$TMPROOT/no-newline.progress.json"
rm -f "$NO_NEWLINE_PROGRESS"
no_newline_out=$(
  run_in_sandbox '
    set -e
    export AGENT_PID_FILE="'"$PIDFILE"'"
    export AGENT_PROGRESS_FILE="'"$NO_NEWLINE_PROGRESS"'"
    export RUN_ID="run-no-newline"
    printf "line one\nline two, no trailing newline" | _agent_progress_recorder line
  '
)
printf 'line one\nline two, no trailing newline' > "$TMPROOT/expected-no-newline.txt"
expected_no_newline=$(cat "$TMPROOT/expected-no-newline.txt")
assert_eq "TC-LEASE-011b final no-trailing-newline line survives byte-for-byte under set -e" \
  "$expected_no_newline" "$no_newline_out"
if [[ -f "$NO_NEWLINE_PROGRESS" ]]; then
  ok "TC-LEASE-011b lease still refreshed for the no-trailing-newline final record"
else
  bad "TC-LEASE-011b lease was not refreshed for the no-trailing-newline final record"
fi

# TC-LEASE-016: exit status propagation through the recorder for 0/124/137/143.
for code in 0 124 137 143; do
  rc=$(
    run_in_sandbox '
      export AGENT_PROGRESS_FILE="'"$TMPROOT"'/exit-'"$code"'.progress.json"
      export RUN_ID="run-exit"
      ( printf "hello\n"; exit '"$code"' ) | _agent_progress_recorder line >/dev/null
      echo "${PIPESTATUS[0]}"
    '
  )
  assert_eq "TC-LEASE-016 exit code $code propagates through the recorder (PIPESTATUS)" "$code" "$rc"
done

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LEASE-024..027: EAGAIN on the shared nonblocking pipe (issue #508) ==="
# ---------------------------------------------------------------------------
# Root cause: the wrapper's stdout is `exec > >(tee -a run.log)`, the SAME
# open file description the Claude CLI (Node.js) inherits as its stderr.
# Node sets O_NONBLOCK on that shared pipe (the flag lives on the open file
# description, not per-fd), so once Node's own writes fill the pipe buffer
# this recorder's underlying `printf` can get EAGAIN — and bash's printf does
# not retry EAGAIN itself, silently dropping the record. These tests drive
# the REAL recorder through a REAL O_NONBLOCK pipe (via a python3 fcntl
# helper, per the issue's mandated repro shape) with a reader that stalls
# long enough to force genuine EAGAIN, then drains slowly.
_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

HAVE_PY3=0
command -v python3 >/dev/null 2>&1 && HAVE_PY3=1

if [[ "$HAVE_PY3" -eq 1 ]]; then
  PY_DRIVER="$TMPROOT/drive_recorder.py"
  cat > "$PY_DRIVER" <<'PYEOF'
# Drives a child command's stdout through a pipe whose write end is put into
# O_NONBLOCK mode. Phase 1 stalls WITHOUT reading at all for <stall_seconds>
# so the 64KB pipe buffer fills and the child's own writes start hitting
# real EAGAIN (mirrors the issue's "helper has set O_NONBLOCK ... reader
# drains slowly" repro shape). Phase 2 drains slowly in small chunks until
# the child's stdout closes.
#   drive_recorder.py <out_file> <stall_seconds> -- <cmd...>
import os, sys, fcntl, time

args = sys.argv[1:]
sep = args.index('--')
out_path = args[0]
stall_seconds = float(args[1])
cmd = args[sep + 1:]

r, w = os.pipe()
fl = fcntl.fcntl(w, fcntl.F_GETFL)
fcntl.fcntl(w, fcntl.F_SETFL, fl | os.O_NONBLOCK)

pid = os.fork()
if pid == 0:
    os.close(r)
    os.dup2(w, 1)
    os.close(w)
    os.execvp(cmd[0], cmd)
    os._exit(127)

os.close(w)
fl_r = fcntl.fcntl(r, fcntl.F_GETFL)
fcntl.fcntl(r, fcntl.F_SETFL, fl_r | os.O_NONBLOCK)

start = time.time()
with open(out_path, 'wb') as out:
    while time.time() - start < stall_seconds:
        time.sleep(0.01)
    while True:
        try:
            chunk = os.read(r, 128)
        except BlockingIOError:
            time.sleep(0.02)
            continue
        if not chunk:
            break
        out.write(chunk)
        out.flush()
        time.sleep(0.01)

os.close(r)
_, status = os.waitpid(pid, 0)
sys.exit(os.waitstatus_to_exitcode(status))
PYEOF

  # A fixture large enough (>64KB, the typical pipe capacity) to guarantee
  # the stall phase above fills the buffer and forces real EAGAIN — not
  # merely a framing/format fixture like TC-LEASE-011's small one.
  EAGAIN_FIXTURE="$TMPROOT/eagain-fixture.jsonl"
  : > "$EAGAIN_FIXTURE"
  for i in $(seq 1 500); do
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"chunk-%d-%s"}]}}\n' \
      "$i" "$(printf 'x%.0s' $(seq 1 200))" >> "$EAGAIN_FIXTURE"
  done
  # Final record has NO trailing newline — the same no-trailing-newline
  # contract TC-LEASE-011b pins, now under retry pressure.
  printf '{"type":"result","subtype":"success","stop_reason":"end_turn","terminal_reason":"completed","duration_ms":1234,"usage":{"input_tokens":100,"output_tokens":20}}' >> "$EAGAIN_FIXTURE"

  RECORDER_DRIVER="$TMPROOT/run_recorder.sh"
  cat > "$RECORDER_DRIVER" <<'SHEOF'
#!/bin/bash
# This script's own stdout must remain whatever the caller wired it to (the
# pressured pipe from drive_recorder.py) — never redirected to a file here.
set -uo pipefail
LIB="$1" FIXTURE="$2" PROGRESS_FILE="$3" FRAMING="$4" ERR_LOG="$5"
env -u AUTONOMOUS_CONF_DIR \
  AUTONOMOUS_PID_DIR="$(dirname "$PROGRESS_FILE")" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$(dirname "$PROGRESS_FILE")" \
  AGENT_CMD=claude \
  AGENT_PROGRESS_FILE="$PROGRESS_FILE" \
  RUN_ID="run-eagain" \
  bash -c '
    mkdir -p "$AUTONOMOUS_PID_DIR"
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV AGENT_PID_FILE
    source "'"$LIB"'"
    cat "'"$FIXTURE"'" | _agent_progress_recorder "'"$FRAMING"'"
  ' 2>"$ERR_LOG"
SHEOF
  chmod +x "$RECORDER_DRIVER"

  # ---------------------------------------------------------------------
  # TC-LEASE-024: byte-identical passthrough under EAGAIN pressure — record
  # count AND checksum match, including the final no-trailing-newline
  # {"type":"result"} line, and NO write-error reaches stderr.
  # ---------------------------------------------------------------------
  EAGAIN_OUT="$TMPROOT/eagain-out.jsonl"
  EAGAIN_ERR="$TMPROOT/eagain-err.log"
  EAGAIN_PROGRESS_DIR="$TMPROOT/eagain-pd"
  rm -rf "$EAGAIN_PROGRESS_DIR"
  # Stall duration is deliberately well under the recorder's own ~2s
  # per-slice retry budget (40 * 0.05s) — long enough to overflow the 64KB
  # pipe and force genuine EAGAIN, short enough that the reader is
  # guaranteed to start draining before any single slice could exhaust its
  # retry budget and fire the bound-exhaustion diagnostic this test asserts
  # is ABSENT. TC-LEASE-026 (below) is the dedicated exhaustion test and
  # uses a reader that never drains at all.
  python3 "$PY_DRIVER" "$EAGAIN_OUT" 1.0 -- \
    bash "$RECORDER_DRIVER" "$LIB" "$EAGAIN_FIXTURE" "$EAGAIN_PROGRESS_DIR/progress.json" json "$EAGAIN_ERR" \
    >/dev/null 2>&1

  expected_sha=$(_sha "$EAGAIN_FIXTURE")
  actual_sha=$(_sha "$EAGAIN_OUT")
  assert_eq "TC-LEASE-024 recorder output is byte-identical (checksum) under EAGAIN pressure" \
    "$expected_sha" "$actual_sha"

  expected_lines=$(wc -l < "$EAGAIN_FIXTURE")
  actual_lines=$(wc -l < "$EAGAIN_OUT")
  assert_eq "TC-LEASE-024 recorder output line count matches fixture under EAGAIN pressure" \
    "$expected_lines" "$actual_lines"

  if grep -q '"type":"result"' "$EAGAIN_OUT" 2>/dev/null; then
    ok "TC-LEASE-024 final {\"type\":\"result\"} record survives EAGAIN pressure"
  else
    bad "TC-LEASE-024 final {\"type\":\"result\"} record was dropped under EAGAIN pressure"
  fi

  if grep -q "write error" "$EAGAIN_ERR" 2>/dev/null; then
    bad "TC-LEASE-024 no write-error diagnostic reaches stderr under transient EAGAIN (tee always drains)"
  else
    ok "TC-LEASE-024 no write-error diagnostic reaches stderr under transient EAGAIN (tee always drains)"
  fi

  # ---------------------------------------------------------------------
  # TC-LEASE-025: the no-trailing-newline final-line contract still holds
  # under the retry path specifically (not just "some fixture happens to
  # end without a newline" — this isolates that exact byte).
  # ---------------------------------------------------------------------
  last_byte_fixture=$(tail -c 1 "$EAGAIN_FIXTURE" | od -An -tx1 | tr -d ' \n')
  last_byte_out=$(tail -c 1 "$EAGAIN_OUT" | od -An -tx1 | tr -d ' \n')
  assert_eq "TC-LEASE-025 final line's no-trailing-newline byte survives the retry path" \
    "$last_byte_fixture" "$last_byte_out"

  # ---------------------------------------------------------------------
  # TC-LEASE-026: bounded-retry exhaustion — a reader that NEVER drains (the
  # pipe fills once and stays full forever) must not hang the recorder. The
  # wall-clock bound is asserted directly; the single stderr diagnostic is
  # asserted per dropped record (never a loud loop of the same error).
  # ---------------------------------------------------------------------
  STUCK_DRIVER="$TMPROOT/drive_stuck.py"
  cat > "$STUCK_DRIVER" <<'PYEOF'
# Fills the pipe once, then NEVER reads from it again. Polls the child's own
# exit status without WNOHANG's "0 vs still-running" ambiguity (checks the
# returned pid, not the status value) so a bound-respecting recorder is
# correctly distinguished from a genuine hang.
#   drive_stuck.py <timeout_s> -- <cmd...>
import os, sys, time, fcntl

args = sys.argv[1:]
sep = args.index('--')
timeout_s = float(args[0])
cmd = args[sep + 1:]

r, w = os.pipe()
fl = fcntl.fcntl(w, fcntl.F_GETFL)
fcntl.fcntl(w, fcntl.F_SETFL, fl | os.O_NONBLOCK)

pid = os.fork()
if pid == 0:
    os.close(r)
    os.dup2(w, 1)
    os.close(w)
    os.execvp(cmd[0], cmd)
    os._exit(127)

os.close(w)
start = time.time()
while True:
    try:
        got_pid, status = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        got_pid = 0
    if got_pid == pid:
        print(f"EXITED after {time.time()-start:.2f}s status={status}")
        sys.exit(0)
    if time.time() - start > timeout_s:
        print(f"HUNG past {timeout_s}s bound")
        os.kill(pid, 9)
        os.waitpid(pid, 0)
        sys.exit(1)
    time.sleep(0.05)
PYEOF

  # Single-record fixture, but large enough on its own (>64KB) to fill the
  # pipe and force this exact record into the retry-exhaustion path.
  STUCK_FIXTURE="$TMPROOT/stuck-fixture.jsonl"
  python3 -c "print('{\"type\":\"result\",\"pad\":\"' + 'x'*70000 + '\"}', end='')" > "$STUCK_FIXTURE"
  STUCK_ERR="$TMPROOT/stuck-err.log"
  STUCK_PROGRESS_DIR="$TMPROOT/stuck-pd"
  rm -rf "$STUCK_PROGRESS_DIR"

  stuck_out=$(timeout 20 python3 "$STUCK_DRIVER" 10 -- \
    bash "$RECORDER_DRIVER" "$LIB" "$STUCK_FIXTURE" "$STUCK_PROGRESS_DIR/progress.json" json "$STUCK_ERR" 2>&1)
  stuck_driver_rc=$?

  assert_eq "TC-LEASE-026 recorder completes within the wall-clock bound instead of hanging on a never-draining reader" \
    "0" "$stuck_driver_rc"
  assert_contains "TC-LEASE-026 recorder process actually exited (not killed by the test's own timeout)" \
    "EXITED" "$stuck_out"

  # `grep -c` already prints "0" (and exits 1) on zero matches — no `|| echo
  # 0` fallback needed, and adding one would double-print "0\n0" on a
  # genuine zero-match run and mask that failure mode instead of surfacing it.
  diag_count=$(grep -c "dropping output record" "$STUCK_ERR" 2>/dev/null)
  assert_eq "TC-LEASE-026 exactly one best-effort stderr diagnostic for the exhausted record" "1" "$diag_count"

  # ---------------------------------------------------------------------
  # TC-LEASE-027: the zero-AGENT_PROGRESS_FILE fast path (bare `cat`) is
  # unaffected by the retry helper — still byte-identical, still a plain
  # `cat`, even under the same EAGAIN pressure.
  # ---------------------------------------------------------------------
  FASTPATH_OUT="$TMPROOT/fastpath-out.jsonl"
  python3 "$PY_DRIVER" "$FASTPATH_OUT" 1.0 -- bash -c '
    unset AGENT_PROGRESS_FILE
    source "'"$LIB"'"
    cat "'"$EAGAIN_FIXTURE"'" | _agent_progress_recorder json
  ' >/dev/null 2>&1

  fastpath_sha=$(_sha "$FASTPATH_OUT")
  assert_eq "TC-LEASE-027 fast path (AGENT_PROGRESS_FILE unset) stays byte-identical under the same pressure" \
    "$expected_sha" "$fastpath_sha"
else
  echo "  SKIP: TC-LEASE-024..027 require python3 (not found on PATH) — the fcntl-based nonblocking-pipe harness has no shell-only equivalent"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LEASE-017: Codex/OpenCode session/thread-ID capture still works with the recorder in the pipeline ==="
# ---------------------------------------------------------------------------
CODEX_FIXTURE="$TMPROOT/codex-stream.jsonl"
cat > "$CODEX_FIXTURE" <<'EOF'
{"type":"thread.started","thread_id":"019e1234-aaaa-bbbb-cccc-deadbeefcafe"}
{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"ok"}}
{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":2}}
EOF
CODEX_THREAD_SIDECAR="$PID_DIR/codex-thread-lease-codex-session"
CODEX_LEASE_PROGRESS="$TMPROOT/codex-capture.progress.json"
rm -f "$CODEX_THREAD_SIDECAR" "$CODEX_LEASE_PROGRESS"
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$CODEX_LEASE_PROGRESS"'"
  export RUN_ID="run-codex-capture"
  cat "'"$CODEX_FIXTURE"'" | _codex_capture_thread "lease-codex-session" | _agent_progress_recorder json >/dev/null
'
assert_eq "TC-LEASE-017 codex thread_id sidecar still captured with the recorder chained after it" \
  "019e1234-aaaa-bbbb-cccc-deadbeefcafe" "$(cat "$CODEX_THREAD_SIDECAR" 2>/dev/null)"
if [[ -f "$CODEX_LEASE_PROGRESS" ]]; then
  ok "TC-LEASE-017 lease still refreshed with _codex_capture_thread chained before the recorder"
else
  bad "TC-LEASE-017 lease not refreshed when chained after _codex_capture_thread"
fi

OPENCODE_FIXTURE="$TMPROOT/opencode-stream.jsonl"
cat > "$OPENCODE_FIXTURE" <<'EOF'
{"type":"step_start","sessionID":"ses_01deadbeefcafe"}
{"type":"text","sessionID":"ses_01deadbeefcafe","text":"working..."}
EOF
OPENCODE_SESSION_SIDECAR="$PID_DIR/opencode-session-lease-opencode-session"
OPENCODE_LEASE_PROGRESS="$TMPROOT/opencode-capture.progress.json"
rm -f "$OPENCODE_SESSION_SIDECAR" "$OPENCODE_LEASE_PROGRESS"
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$OPENCODE_LEASE_PROGRESS"'"
  export RUN_ID="run-opencode-capture"
  cat "'"$OPENCODE_FIXTURE"'" | _opencode_capture_session "lease-opencode-session" | _agent_progress_recorder json >/dev/null
'
assert_eq "TC-LEASE-017 opencode sessionID sidecar still captured with the recorder chained after it" \
  "ses_01deadbeefcafe" "$(cat "$OPENCODE_SESSION_SIDECAR" 2>/dev/null)"
if [[ -f "$OPENCODE_LEASE_PROGRESS" ]]; then
  ok "TC-LEASE-017 lease still refreshed with _opencode_capture_session chained before the recorder"
else
  bad "TC-LEASE-017 lease not refreshed when chained after _opencode_capture_session"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LEASE-019: unknown-CLI fallback also refreshes the lease ==="
# ---------------------------------------------------------------------------
cat > "$BIN/frobnik" <<'EOF'
#!/bin/bash
cat >/dev/null
echo "some output line"
EOF
chmod +x "$BIN/frobnik"

FALLBACK_PROGRESS="$TMPROOT/fallback.progress.json"
rm -f "$FALLBACK_PROGRESS"
(
  env -u AUTONOMOUS_CONF_DIR \
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=frobnik \
  AGENT_PID_FILE="$TMPROOT/fallback.pid" \
  AGENT_PROGRESS_FILE="$FALLBACK_PROGRESS" \
  RUN_ID="run-fallback" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV
    source "'"$LIB"'"
    run_agent "fallback-session" "hello" "" "" >/dev/null 2>&1
  '
)
if [[ -f "$FALLBACK_PROGRESS" ]]; then
  ok "TC-LEASE-019 unknown-CLI generic fallback refreshes the lease"
else
  bad "TC-LEASE-019 generic fallback never refreshed the lease"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LEASE-020: gemini framing selection (json vs line) ==="
# ---------------------------------------------------------------------------
cat > "$BIN/gemini" <<'EOF'
#!/bin/bash
cat >/dev/null
echo '{"type":"init","sessionId":"g1"}'
echo '{"type":"result"}'
EOF
chmod +x "$BIN/gemini"

GEM_JSON_PROGRESS="$TMPROOT/gem-json.progress.json"
rm -f "$GEM_JSON_PROGRESS"
(
  env -u AUTONOMOUS_CONF_DIR \
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=gemini \
  AGENT_PID_FILE="$TMPROOT/gem.pid" \
  AGENT_PROGRESS_FILE="$GEM_JSON_PROGRESS" \
  RUN_ID="run-gem-json" \
  AGENT_DEV_EXTRA_ARGS="--approval-mode yolo --output-format stream-json" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV
    source "'"$LIB"'"
    run_agent "gem-session" "hello" "" "" >/dev/null 2>&1
  '
)
if [[ -f "$GEM_JSON_PROGRESS" ]]; then
  ok "TC-LEASE-020 gemini with stream-json EXTRA_ARGS refreshes the lease (json framing)"
else
  bad "TC-LEASE-020 gemini json-framing path never refreshed the lease"
fi

GEM_LINE_PROGRESS="$TMPROOT/gem-line.progress.json"
rm -f "$GEM_LINE_PROGRESS"
(
  env -u AUTONOMOUS_CONF_DIR \
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=gemini \
  AGENT_PID_FILE="$TMPROOT/gem2.pid" \
  AGENT_PROGRESS_FILE="$GEM_LINE_PROGRESS" \
  RUN_ID="run-gem-line" \
  AGENT_DEV_EXTRA_ARGS="" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV
    source "'"$LIB"'"
    run_agent "gem-session-2" "hello" "" "" >/dev/null 2>&1
  '
)
if [[ -f "$GEM_LINE_PROGRESS" ]]; then
  ok "TC-LEASE-020 gemini WITHOUT stream-json EXTRA_ARGS still refreshes the lease (line framing)"
else
  bad "TC-LEASE-020 gemini line-framing path never refreshed the lease"
fi

# TC-LEASE-020b: round-2 review finding — the EQUALS-JOINED single-token form
# `--output-format=stream-json` must ALSO select json framing (not just the
# two-token `--output-format stream-json` TC-LEASE-020 above already covers).
# Proven with a truncated/malformed final record: under the correct json
# framing the malformed line must NOT refresh the lease (R2's complete-record
# rule), so the refresh count must be exactly 1 (the launch event) + 1 (the
# one well-formed record) = 2, NOT 3 — if the equals form fell through to
# line framing, the truncated third line would count as a plain nonempty
# line and wrongly refresh, yielding 3.
cat > "$BIN/gemini" <<'EOF'
#!/bin/bash
cat >/dev/null
echo '{"type":"init","sessionId":"g-eq"}'
echo '{unterminated'
EOF
chmod +x "$BIN/gemini"

GEM_EQ_PROGRESS="$TMPROOT/gem-eq.progress.json"
GEM_EQ_REFRESH_COUNT="$TMPROOT/gem-eq.refreshes"
rm -f "$GEM_EQ_PROGRESS" "$GEM_EQ_REFRESH_COUNT"
: > "$GEM_EQ_REFRESH_COUNT"
(
  env -u AUTONOMOUS_CONF_DIR \
  PATH="$BIN:$PATH" \
  AUTONOMOUS_PID_DIR="$PID_DIR" \
  PROJECT_ID="testproj" \
  PROJECT_DIR="$TMPROOT" \
  AGENT_CMD=gemini \
  AGENT_PID_FILE="$TMPROOT/gem-eq.pid" \
  AGENT_PROGRESS_FILE="$GEM_EQ_PROGRESS" \
  RUN_ID="run-gem-eq" \
  AGENT_DEV_EXTRA_ARGS="--approval-mode=yolo --output-format=stream-json" \
  REFRESH_COUNT_FILE="$GEM_EQ_REFRESH_COUNT" \
  bash -c '
    unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV
    source "'"$LIB"'"
    eval "$(declare -f _agent_progress_refresh | sed "1s/_agent_progress_refresh/_agent_progress_refresh_real/")"
    _agent_progress_refresh() {
      echo x >> "$REFRESH_COUNT_FILE"
      _agent_progress_refresh_real
    }
    run_agent "gem-eq-session" "hello" "" "" >/dev/null 2>&1
  '
)
gem_eq_got=$(wc -l < "$GEM_EQ_REFRESH_COUNT" 2>/dev/null || echo 0)
assert_eq "TC-LEASE-020b gemini --output-format=stream-json (equals form) selects json framing: truncated final record does NOT refresh (1 launch + 1 complete record, not 3)" \
  "2" "$gem_eq_got"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LEASE-021: refresh COUNT (not just presence) asserted through all seven launch paths ==="
# ---------------------------------------------------------------------------
# TC-LEASE-011/017/019/020 above only assert "a lease file exists" after
# streaming — that would still pass if the recorder refreshed once per
# COMMAND instead of once per RECORD, or if it were silently omitted from
# claude/codex/opencode/agy/kiro (only the fallback and gemini get a
# real-path exercise above). Drive all seven paths through the REAL
# run_agent dispatch with a stub CLI binary that emits a KNOWN number of
# records, count actual _agent_progress_refresh calls via a counting
# wrapper (renames the real function aside, keeps its own tally, then
# delegates), and assert the count equals the number of records the stub
# emitted for that framing.
#
# agy is deliberately given `agy models` support in its stub (a real
# invocation path — the adapter calls it for [INV-50] validation) even
# though the driver passes no --model, so the stub matches production shape.

# _lease_count_driver <cli_id> <binary_name> <n_records> <stub_body>
#   stub_body: shell snippet (heredoc body) — the stub binary's script,
#   consuming stdin and emitting exactly n_records progress-countable
#   records to stdout.
_lease_count_driver() {
  local cli_id="$1" binary_name="$2" n_records="$3" stub_body="$4"
  local cnt_bin="$TMPROOT/lease-count-bin-$cli_id"
  mkdir -p "$cnt_bin"
  cat > "$cnt_bin/timeout" <<'TOEOF'
#!/bin/bash
shift 3
exec "$@"
TOEOF
  chmod +x "$cnt_bin/timeout"
  printf '%s\n' "$stub_body" > "$cnt_bin/$binary_name"
  chmod +x "$cnt_bin/$binary_name"
  if [[ "$cli_id" == agy ]]; then
    cat > "$cnt_bin/agy" <<AGYMODELSEOF
#!/bin/bash
if [[ "\$1" == "models" ]]; then echo "some-model"; exit 0; fi
$stub_body
AGYMODELSEOF
    chmod +x "$cnt_bin/agy"
  fi

  local cnt_progress="$TMPROOT/lease-count-$cli_id.progress.json"
  local cnt_file="$TMPROOT/lease-count-$cli_id.refreshes"
  rm -f "$cnt_progress" "$cnt_file"
  : > "$cnt_file"

  (
    env -u AUTONOMOUS_CONF_DIR \
    PATH="$cnt_bin:$PATH" \
    AUTONOMOUS_PID_DIR="$PID_DIR" \
    PROJECT_ID="testproj" \
    PROJECT_DIR="$TMPROOT" \
    AGENT_CMD="$cli_id" \
    AGENT_PERMISSION_MODE=auto \
    AGENT_PID_FILE="$TMPROOT/lease-count-$cli_id.pid" \
    AGENT_PROGRESS_FILE="$cnt_progress" \
    RUN_ID="run-count-$cli_id" \
    AGENT_DEV_EXTRA_ARGS="--approval-mode yolo --output-format stream-json" \
    KIRO_AGENT_NAME="autonomous-dev" \
    REFRESH_COUNT_FILE="$cnt_file" \
    bash -c '
      unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV
      source "'"$LIB"'"
      eval "$(declare -f _agent_progress_refresh | sed "1s/_agent_progress_refresh/_agent_progress_refresh_real/")"
      _agent_progress_refresh() {
        echo x >> "$REFRESH_COUNT_FILE"
        _agent_progress_refresh_real
      }
      run_agent "count-session-'"$cli_id"'" "hello" "" "" >/dev/null 2>&1
    '
  )
  local got
  got=$(wc -l < "$cnt_file" 2>/dev/null || echo 0)
  # +1: the launch event (R2 case 1) refreshes once BEFORE any output record
  # is processed — every path's total is n_records + 1, not n_records alone.
  assert_eq "TC-LEASE-021 $cli_id refreshes exactly once per record + 1 launch event ($n_records records)" \
    "$((n_records + 1))" "$got"
}

# claude: json framing, 3 complete records.
_lease_count_driver claude claude 3 '#!/bin/bash
cat >/dev/null
echo "{\"type\":\"system\",\"subtype\":\"init\"}"
echo "{\"type\":\"assistant\",\"message\":{}}"
echo "{\"type\":\"result\",\"stop_reason\":\"end_turn\",\"terminal_reason\":\"completed\"}"'

# codex: json framing, 3 records (thread.started counts too — the capture
# filter composes BEFORE the recorder but does not consume the line).
_lease_count_driver codex codex 3 '#!/bin/bash
cat >/dev/null
echo "{\"type\":\"thread.started\",\"thread_id\":\"019e1234-aaaa-bbbb-cccc-deadbeefcafe\"}"
echo "{\"type\":\"item.completed\",\"item\":{}}"
echo "{\"type\":\"turn.completed\"}"'

# opencode: json framing, 2 records.
_lease_count_driver opencode opencode 2 '#!/bin/bash
cat >/dev/null
echo "{\"type\":\"step_start\",\"sessionID\":\"ses_01deadbeefcafe\"}"
echo "{\"type\":\"step_finish\",\"sessionID\":\"ses_01deadbeefcafe\"}"'

# agy: line framing, 4 non-empty lines.
_lease_count_driver agy agy 4 '#!/bin/bash
cat >/dev/null
echo "line one"
echo "line two"
echo "line three"
echo "line four"'

# kiro: line framing, 2 non-empty lines. Binary alias: adapter execs
# `kiro-cli`, not the adapter id `kiro` — install the stub under that name.
_lease_count_driver kiro kiro-cli 2 '#!/bin/bash
cat >/dev/null
echo "kiro line one"
echo "kiro line two"'

# gemini: json framing (AGENT_DEV_EXTRA_ARGS above selects stream-json), 2
# records.
_lease_count_driver gemini gemini 2 '#!/bin/bash
cat >/dev/null
echo "{\"type\":\"init\",\"sessionId\":\"g1\"}"
echo "{\"type\":\"result\"}"'

# unknown-CLI fallback: line framing, 3 non-empty lines.
_lease_count_driver frobnik frobnik 3 '#!/bin/bash
cat >/dev/null
echo "fallback line one"
echo "fallback line two"
echo "fallback line three"'

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LEASE-012 / TC-LEASE-013 / TC-LEASE-014 / TC-LEASE-015: R4 consumer pins ==="
# ---------------------------------------------------------------------------

# TC-LEASE-012: is_session_completed still classifies the stream-json fixture
# correctly (last {"type":"result",...} line, same jq-based parsing).
if [[ -f "$LIB_DISPATCH" ]]; then
  ISSUE_LOG_DIR=$(mktemp -d)
  export REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane MAX_RETRIES=3 MAX_CONCURRENT=5
  export PROJECT_ID="lease-iscompleted-$$"
  gh() { :; }
  export -f gh
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
  source "$LIB_DISPATCH"
  set +e

  log_file="/tmp/agent-${PROJECT_ID}-issue-9001.log"
  cp "$FIXTURE" "$log_file"
  export AGENT_CMD=claude
  assert_returns "TC-LEASE-012 is_session_completed(end_turn+completed) on stream-json fixture -> true" 0 is_session_completed 9001
  rm -f "$log_file"

  # prompt_too_long variant.
  cat "$FIXTURE" | sed 's/"stop_reason":"end_turn","terminal_reason":"completed"/"stop_reason":"other","terminal_reason":"prompt_too_long"/' > "$log_file"
  assert_returns "TC-LEASE-012 is_session_completed(prompt_too_long) on stream-json fixture -> true" 0 is_session_completed 9001
  rm -f "$log_file"

  # TC-LEASE-015 regression pin: reframe the final result line (pretty-print
  # with leading whitespace, breaking the `grep '^{"type":"result"'` anchor)
  # and confirm is_session_completed correctly FAILS to classify it — proving
  # the pin is load-bearing.
  { head -n 4 "$FIXTURE"; echo '  {"type":"result","subtype":"success","stop_reason":"end_turn","terminal_reason":"completed"}'; } > "$log_file"
  assert_returns "TC-LEASE-015 reframed (indented) final line breaks is_session_completed (proves the pin matters)" 1 is_session_completed 9001
  rm -f "$log_file"

  rm -rf "$ISSUE_LOG_DIR"
else
  bad "TC-LEASE-012 lib-dispatch.sh not found at expected path"
fi

# TC-LEASE-014: metrics_parse_tokens final usage totals unchanged against the
# stream-json fixture (last usage-bearing line wins).
if [[ -f "$LIB_METRICS" ]]; then
  ( set +e
    # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-metrics.sh
    source "$LIB_METRICS" 2>/dev/null
    tok=$(metrics_parse_tokens "$FIXTURE" 2>/dev/null)
    echo "$tok" > "$TMPROOT/tok-result.txt"
  )
  tok_result=$(cat "$TMPROOT/tok-result.txt" 2>/dev/null)
  assert_contains "TC-LEASE-014 metrics_parse_tokens reads input_tokens=100 from stream-json fixture" "input_tokens=100" "$tok_result"
  assert_contains "TC-LEASE-014 metrics_parse_tokens reads output_tokens=20 from stream-json fixture" "output_tokens=20" "$tok_result"
  assert_contains "TC-LEASE-014 metrics_parse_tokens computes total_tokens=120 from stream-json fixture" "total_tokens=120" "$tok_result"
else
  bad "TC-LEASE-014 lib-metrics.sh not found at expected path"
fi

# TC-LEASE-013: the REAL session-log-probe-remote-aws-ssm.sh driver, run
# end-to-end against the stream-json fixture, with ONLY the SSM transport
# (the `aws` binary) stubbed. The stub does not hand back a canned answer —
# it extracts the driver's OWN base64-encoded INNER_CMD from the real
# `--parameters` payload the driver built, decodes it, and executes it
# locally against the fixture placed at the exact path the driver's own
# inner shell snippet computes. So a regression in the driver's real
# grep/stat logic (e.g. a changed anchor, a broken quoting escape) would
# make THIS test fail — unlike a bare re-implementation of the same
# grep/stat snippet, which would stay green even if the driver's actual
# code diverged from it.
if [[ -f "$PROBE_SCRIPT" ]]; then
  REMOTE_PROJECT_ID="leaseprobe$$"
  REMOTE_ISSUE_NUM="9002"
  REMOTE_LOG="/tmp/agent-${REMOTE_PROJECT_ID}-issue-${REMOTE_ISSUE_NUM}.log"
  cp "$FIXTURE" "$REMOTE_LOG"

  PROBE_STUB_BIN="$TMPROOT/probe-stub-bin"
  mkdir -p "$PROBE_STUB_BIN"
  PROBE_REAL_OUTPUT="$TMPROOT/probe-real-output.txt"
  cat > "$PROBE_STUB_BIN/aws" <<'STUBEOF'
#!/bin/bash
case "$*" in
  *send-command*)
    prev=""
    params_json=""
    for arg in "$@"; do
      [[ "$prev" == "--parameters" ]] && params_json="$arg"
      prev="$arg"
    done
    full_cmd=$(printf '%s' "$params_json" | jq -r '.commands[0]')
    b64=$(printf '%s' "$full_cmd" | grep -oE 'printf %s [A-Za-z0-9+/=]+ \| base64 -d' | sed -E 's/^printf %s //; s/ \| base64 -d$//')
    inner_cmd=$(printf '%s' "$b64" | base64 -d)
    # Execute the driver's REAL inner shell snippet locally (no sudo/remote
    # host in this hermetic suite) — its own grep/stat against the fixture
    # placed at the path it computes is what populates PROBE_REAL_OUTPUT.
    bash -c "$inner_cmd" > "$PROBE_REAL_OUTPUT" 2>/dev/null || true
    echo '{"Command":{"CommandId":"stub-probe-1","Status":"Pending"}}'
    ;;
  *get-command-invocation*)
    out=$(cat "$PROBE_REAL_OUTPUT" 2>/dev/null || true)
    jq -n --arg out "$out" '{"Status":"Success","StandardOutputContent":$out,"StandardErrorContent":""}'
    ;;
esac
STUBEOF
  chmod +x "$PROBE_STUB_BIN/aws"

  probe_out=$(
    PATH="$PROBE_STUB_BIN:$PATH" \
    SSM_INSTANCE_ID="i-lease-test" \
    SSM_REMOTE_PROJECT_ID="$REMOTE_PROJECT_ID" \
    SSM_REMOTE_PROJECT_DIR="/tmp" \
    PROBE_REAL_OUTPUT="$PROBE_REAL_OUTPUT" \
    bash "$PROBE_SCRIPT" --probe "$REMOTE_ISSUE_NUM"
  )
  probe_rc=$?
  rm -f "$REMOTE_LOG"

  assert_eq "TC-LEASE-013 real probe driver rc=0 against the stream-json fixture" "0" "$probe_rc"
  probe_line=$(echo "$probe_out" | sed -n '1p')
  probe_epoch=$(echo "$probe_out" | sed -n '2p')
  assert_contains "TC-LEASE-013 real probe driver's line 1 is the final result line from the fixture" '"type":"result"' "$probe_line"
  [[ "$probe_epoch" =~ ^[0-9]+$ ]] && ok "TC-LEASE-013 real probe driver's line 2 (mtime epoch) is numeric" || bad "TC-LEASE-013 mtime epoch not numeric: $probe_epoch"

  # Negative pin (mirrors TC-LEASE-015's is_session_completed pin): a
  # reframed/indented final line must make the REAL driver's own grep anchor
  # miss too — proving this end-to-end exercise, not just is_session_completed,
  # depends on the exact `^{"type":"result"` column-zero contract.
  REFRAMED_LOG="/tmp/agent-${REMOTE_PROJECT_ID}-issue-9003.log"
  { head -n 4 "$FIXTURE"; echo '  {"type":"result","subtype":"success","stop_reason":"end_turn","terminal_reason":"completed"}'; } > "$REFRAMED_LOG"
  PROBE_REAL_OUTPUT_9003="$TMPROOT/probe-real-output-9003.txt"
  reframed_out=$(
    PATH="$PROBE_STUB_BIN:$PATH" \
    SSM_INSTANCE_ID="i-lease-test" \
    SSM_REMOTE_PROJECT_ID="$REMOTE_PROJECT_ID" \
    SSM_REMOTE_PROJECT_DIR="/tmp" \
    PROBE_REAL_OUTPUT="$PROBE_REAL_OUTPUT_9003" \
    bash "$PROBE_SCRIPT" --probe 9003
  )
  rm -f "$REFRAMED_LOG"
  assert_eq "TC-LEASE-013 reframed (indented) final line makes the real probe driver report empty (proves the pin is load-bearing end-to-end)" "" "$reframed_out"
else
  bad "TC-LEASE-013 session-log-probe-remote-aws-ssm.sh not found at expected path"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-LEASE-023: lock unavailability degrades gracefully under set -e (round-2 review finding) ==="
# ---------------------------------------------------------------------------
# The wrapper's real caller (autonomous-dev.sh) sources this file and calls
# _agent_progress_init/_agent_progress_cleanup BARE under `set -euo
# pipefail` — unlike run_in_sandbox above, which deliberately omits `-e` so
# it could exercise lock CORRECTNESS without also masking this exact bug.
# _agent_progress_lock_acquire returns 1 on every "couldn't lock" path (no
# flock binary, symlinked lock path, or a flock -w timeout); a bare call to
# it under real `set -e` aborts the WHOLE caller before the run-id/lease is
# ever written — the opposite of the documented "best-effort, degrades to
# unlocked" contract. Reproduces with a symlink farm that omits `flock`
# (same technique as TC-LGC4-093 in test-lane-gc-p4-gc.sh), never a real bin
# dir that would still resolve the system flock and defeat the fixture.
NOFLOCK_BIN=$(mktemp -d)
for _b in bash cat date mkdir mktemp stat sh dirname readlink pwd printf tr grep sed ps sleep kill cp basename wc chmod mv rm head timeout setsid; do
  _bp="$(command -v "$_b" 2>/dev/null)" || continue
  ln -sf "$_bp" "$NOFLOCK_BIN/$_b"
done

NOFLOCK_RUNID="$TMPROOT/noflock.run-id"
NOFLOCK_PROGRESS="$TMPROOT/noflock.progress.json"
NOFLOCK_PIDFILE="$TMPROOT/noflock.pid"
rm -f "$NOFLOCK_RUNID" "$NOFLOCK_PROGRESS"
echo 4242 > "$NOFLOCK_PIDFILE"

noflock_out=$(
  PATH="$NOFLOCK_BIN" \
  AGENT_PID_FILE="$NOFLOCK_PIDFILE" \
  AGENT_PROGRESS_FILE="$NOFLOCK_PROGRESS" \
  AGENT_PROGRESS_RUNID_FILE="$NOFLOCK_RUNID" \
  RUN_ID="run-noflock" \
  bash -c '
    set -euo pipefail
    source "'"$LIB"'"
    _agent_progress_init
    echo "INIT_SURVIVED"
    _agent_progress_cleanup
    echo "CLEANUP_SURVIVED"
  ' 2>&1
)
noflock_rc=$?
rm -rf "$NOFLOCK_BIN"

assert_eq "TC-LEASE-023 init+cleanup survive set -e with flock unavailable (rc=0, not aborted)" "0" "$noflock_rc"
assert_contains "TC-LEASE-023 _agent_progress_init completes under set -e without flock" "INIT_SURVIVED" "$noflock_out"
assert_contains "TC-LEASE-023 _agent_progress_cleanup completes under set -e without flock" "CLEANUP_SURVIVED" "$noflock_out"

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
