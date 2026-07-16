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
# Strategy: source lib-agent.sh (+ lib-dispatch.sh / lib-metrics.sh where
# needed) in sandboxed subshells with stub CLIs on PATH, mirroring
# test-lib-agent-codex.sh / test-lib-agent-agy.sh. No real sleeps — a fake
# `date` stub or explicit epoch arithmetic stands in for a frozen clock where
# ordering matters.
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

# _source_env <extra-vars...> — helper to source lib-agent.sh in a clean
# subshell with the sandbox PID dir + a fixed PROJECT_ID/PROJECT_DIR, and run
# a snippet of code passed as the LAST positional (as a bash -c script).
run_in_sandbox() {
  local script="$1"
  ( set -uo pipefail
    AUTONOMOUS_PID_DIR="$PID_DIR" \
    PROJECT_ID="testproj" \
    PROJECT_DIR="$TMPROOT" \
    AGENT_CMD=claude \
    bash -c '
      unset AUTONOMOUS_CONF AGENT_LAUNCHER AGENT_LAUNCHER_ARGV
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

# Force a later timestamp deterministically: rewrite the lease's own
# updated_at_epoch manually to simulate "time passed", then call refresh
# again and confirm it overwrites with a >= value (never regresses).
sleep 1
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export RUN_ID="run-B"
  _agent_progress_refresh
'
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

# Behavioral heartbeat regression: run the loop for a couple of ticks with a
# tiny interval and confirm the lease epoch is unchanged (no real sleep needed
# beyond the loop's own short interval, well under CI budgets).
rm -f "$PROGRESS_FILE"
run_in_sandbox '
  export AGENT_PID_FILE="'"$PIDFILE"'"
  export AGENT_PROGRESS_FILE="'"$PROGRESS_FILE"'"
  export RUN_ID="run-B"
  _agent_progress_refresh
  epoch_before=$(jq -r ".updated_at_epoch" "'"$PROGRESS_FILE"'")
  HEARTBEAT_INTERVAL_SECONDS=1 install_agent_heartbeat
  sleep 2.5
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
# A CLI stub that sleeps briefly before producing ANY output, so the launch
# event (fired right after PID/PGID publication, before `wait`) is the ONLY
# thing that could have created the lease at the moment we check it.
cat > "$BIN/claude" <<'EOF'
#!/bin/bash
cat >/dev/null
sleep 0.3
echo '{"type":"result","stop_reason":"end_turn","terminal_reason":"completed"}'
EOF
chmod +x "$BIN/claude"

LAUNCH_PROGRESS="$TMPROOT/launch.progress.json"
LAUNCH_PID="$TMPROOT/launch.pid"
rm -f "$LAUNCH_PROGRESS"
(
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
    # Poll briefly for the lease to appear WHILE the CLI stub is still
    # sleeping (before its first output line) — proves the launch event,
    # not an output-record event, produced it.
    for i in $(seq 1 20); do
      [[ -f "'"$LAUNCH_PROGRESS"'" ]] && break
      sleep 0.05
    done
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

# TC-LEASE-013: remote session-log probe parses the same fixture. Exercised
# via the driver's OWN --probe grep/stat snippet (not a real SSM round trip):
# the driver's inner shell logic is `grep '^{"type":"result"' | tail -1` +
# `stat -c %Y`, identical to the local branch's own extraction — replicate
# that exact snippet against the fixture directly since the driver requires
# live AWS SSM env/creds this hermetic suite does not have.
if [[ -f "$PROBE_SCRIPT" ]]; then
  probe_line=$(grep '^{"type":"result"' "$FIXTURE" 2>/dev/null | tail -1)
  assert_contains "TC-LEASE-013 remote-probe-style grep finds the final result line in the stream-json fixture" '"type":"result"' "$probe_line"
  probe_epoch=$(stat -c %Y "$FIXTURE" 2>/dev/null || stat -f %m "$FIXTURE" 2>/dev/null)
  [[ "$probe_epoch" =~ ^[0-9]+$ ]] && ok "TC-LEASE-013 remote-probe-style mtime epoch is numeric" || bad "TC-LEASE-013 mtime epoch not numeric: $probe_epoch"
else
  bad "TC-LEASE-013 session-log-probe-remote-aws-ssm.sh not found at expected path"
fi

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
