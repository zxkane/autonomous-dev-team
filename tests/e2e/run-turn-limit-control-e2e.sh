#!/bin/bash
# Hermetic hard-boundary and cancellation E2E for issue #507 / INV-142.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
TURN_LIB="$SCRIPTS/lib-turn-limit.sh"
AGENT_LIB="$SCRIPTS/lib-agent.sh"
ACCOUNTING_LIB="$SCRIPTS/lib-accounting.sh"
TOKEN_LIB="$SCRIPTS/lib-token-budget.sh"
REVIEW_WRAPPER="$SCRIPTS/autonomous-review.sh"
FIXTURE="$PROJECT_ROOT/tests/unit/fixtures/synthetic-turn-adapter.sh"
CLAUDE_FIXTURE="$PROJECT_ROOT/tests/unit/fixtures/claude-turn-stream.jsonl"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected=$2 actual=$3)"; fi
}

if [[ ! -r "$TURN_LIB" ]]; then
  fail "TC-TURNLIMIT-062 turn-control library exists"
  printf 'TURN-LIMIT-E2E-SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
  exit 1
fi

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export REPO_NAME=autonomous-dev-team
export PROJECT_ID=turn-limit-e2e
export PROJECT_DIR="$PROJECT_ROOT"
export GH_AUTH_MODE=token
export RUN_DIR="$WORK/run"
export AUTONOMOUS_ACCOUNTING_DIR="$WORK/accounting"
export TURN_LIMIT_LIB="$TURN_LIB"

# shellcheck source=/dev/null
source "$TURN_LIB"
# shellcheck source=/dev/null
source "$AGENT_LIB" >/dev/null 2>&1
# shellcheck source=/dev/null
source "$ACCOUNTING_LIB"
# shellcheck source=/dev/null
source "$TOKEN_LIB"
set +e

TURN_CONTROL_HARD_ACTIVE=0
_run_with_timeout true >/dev/null 2>&1
inactive_rc=$?
assert_eq "TC-TURNLIMIT-040 inactive launch keeps timeout path" 0 "$inactive_rc"

echo "== TC-TURNLIMIT-101/104/106: hard-watchdog launch boundaries =="
TURN_CONTROL_FILE=""
turn_control_init 507 dev E2E-PGID-READY \
  inv-v1-010101010101010101010101 dev synthetic fixture 99 hard
export TURN_CONTROL_FILE
AGENT_TIMEOUT=1
_AGENT_WATCHDOG_GRACE_SECS=1
_TURN_CONTROL_SETSID_READY_DELAY_SECONDS=0.2
_run_with_timeout /bin/bash -c 'trap "exit 0" TERM; /bin/sleep 5' \
  >"$WORK/pgid-ready.out" 2>"$WORK/pgid-ready.err"
pgid_ready_rc=$?
unset _TURN_CONTROL_SETSID_READY_DELAY_SECONDS
case "$pgid_ready_rc" in
  124|137) pass "TC-TURNLIMIT-101 watchdog starts after the owned PGID is ready" ;;
  *) fail "TC-TURNLIMIT-101 watchdog starts after the owned PGID is ready (expected=124/137 actual=$pgid_ready_rc)" ;;
esac
assert_eq "TC-TURNLIMIT-101 ready invocation persists timeout winner" timeout \
  "$(jq -r .winner "$TURN_CONTROL_FILE")"

for unsupported_timeout in 1.5h infinity; do
  TURN_CONTROL_FILE=""
  turn_control_init 507 dev "E2E-TIMEOUT-${unsupported_timeout//./-}" \
    "inv-v1-$(printf '%024d' "${#unsupported_timeout}")" \
    dev synthetic fixture 99 hard
  export TURN_CONTROL_FILE
  unsupported_sentinel="$WORK/unsupported-${unsupported_timeout//./-}.started"
  AGENT_TIMEOUT="$unsupported_timeout"
  _run_with_timeout /bin/bash -c 'touch "$1"' _ "$unsupported_sentinel" \
    >"$WORK/unsupported-timeout.out" 2>"$WORK/unsupported-timeout.err"
  unsupported_timeout_rc=$?
  assert_eq "TC-TURNLIMIT-104 AGENT_TIMEOUT=$unsupported_timeout refuses" 93 \
    "$unsupported_timeout_rc"
  if [[ -e "$unsupported_sentinel" ]]; then
    fail "TC-TURNLIMIT-104 AGENT_TIMEOUT=$unsupported_timeout starts no process"
  else
    pass "TC-TURNLIMIT-104 AGENT_TIMEOUT=$unsupported_timeout starts no process"
  fi
done

sleep_bin="$WORK/watchdog-sleep-bin"
mkdir -p "$sleep_bin"
cat >"$sleep_bin/sleep" <<'EOF'
#!/bin/sh
if [ "$1" = "30" ]; then
  printf '%s\n' "$$" >"$WATCHDOG_SLEEP_PID_FILE"
fi
exec /bin/sleep "$@"
EOF
chmod +x "$sleep_bin/sleep"
TURN_CONTROL_FILE=""
turn_control_init 507 dev E2E-WATCHDOG-CANCEL \
  inv-v1-060606060606060606060606 dev synthetic fixture 99 hard
export TURN_CONTROL_FILE
watchdog_sleep_pid_file="$WORK/watchdog-sleep.pid"
AGENT_TIMEOUT=5
TURN_CONTROL_POLL_SECONDS=30
PATH="$sleep_bin:$PATH" WATCHDOG_SLEEP_PID_FILE="$watchdog_sleep_pid_file" \
  _run_with_timeout /bin/sleep 0.5 \
  >"$WORK/watchdog-cancel.out" 2>"$WORK/watchdog-cancel.err"
watchdog_cancel_rc=$?
assert_eq "TC-TURNLIMIT-106 natural completion keeps command rc" 0 \
  "$watchdog_cancel_rc"
watchdog_sleep_pid="$(cat "$watchdog_sleep_pid_file" 2>/dev/null || true)"
if [[ "$watchdog_sleep_pid" =~ ^[1-9][0-9]*$ ]] \
    && ! kill -0 "$watchdog_sleep_pid" 2>/dev/null; then
  pass "TC-TURNLIMIT-106 watchdog cancellation reaps its polling sleep"
else
  fail "TC-TURNLIMIT-106 watchdog cancellation reaps its polling sleep"
  [[ "$watchdog_sleep_pid" =~ ^[1-9][0-9]*$ ]] \
    && kill "$watchdog_sleep_pid" 2>/dev/null || true
fi
TURN_CONTROL_POLL_SECONDS=0.1
AGENT_TIMEOUT=5

echo "== TC-TURNLIMIT-102: unsynced stop cannot beat natural completion =="
sync_fault_bin="$WORK/sync-fault-bin"
mkdir -p "$sync_fault_bin"
real_sync="$(command -v sync)"
cat >"$sync_fault_bin/sync" <<'EOF'
#!/bin/bash
if [[ "$1" == "-f" && "$2" == "$TURN_SYNC_FAULT_DIR" \
    && -f "$TURN_SYNC_FAULT_MARKER" ]]; then
  rm -f "$TURN_SYNC_FAULT_MARKER"
  exit 1
fi
exec "$TURN_REAL_SYNC" "$@"
EOF
chmod +x "$sync_fault_bin/sync"
unsynced_stop_cmd="$WORK/unsynced-stop-command.sh"
cat >"$unsynced_stop_cmd" <<'EOF'
#!/bin/bash
source "$TURN_LIMIT_LIB"
trap 'touch "$TURN_UNEXPECTED_SIGNAL"; exit 88' TERM
turn_control_request_stop timeout && exit 99
exit 7
EOF
chmod +x "$unsynced_stop_cmd"
TURN_CONTROL_FILE=""
turn_control_init 507 dev E2E-UNSYNCED-STOP \
  inv-v1-020202020202020202020202 dev synthetic fixture 99 hard
export TURN_CONTROL_FILE
unsynced_stop_fault="$WORK/unsynced-stop.fault"
unsynced_stop_signal="$WORK/unsynced-stop.signal"
touch "$unsynced_stop_fault"
AGENT_TIMEOUT=10
PATH="$sync_fault_bin:$PATH" \
TURN_REAL_SYNC="$real_sync" \
TURN_SYNC_FAULT_DIR="$RUN_DIR/turn-control" \
TURN_SYNC_FAULT_MARKER="$unsynced_stop_fault" \
TURN_UNEXPECTED_SIGNAL="$unsynced_stop_signal" \
  _run_with_timeout "$unsynced_stop_cmd" \
  >"$WORK/unsynced-stop.out" 2>"$WORK/unsynced-stop.err"
unsynced_stop_rc=$?
assert_eq "TC-TURNLIMIT-102 natural command rc remains authoritative" 7 \
  "$unsynced_stop_rc"
assert_eq "TC-TURNLIMIT-102 natural completion is durable" completed \
  "$(jq -r .state "$TURN_CONTROL_FILE")"
assert_eq "TC-TURNLIMIT-102 unconfirmed winner is removed" null \
  "$(jq -r .winner "$TURN_CONTROL_FILE")"
if [[ -e "$unsynced_stop_signal" ]]; then
  fail "TC-TURNLIMIT-102 unconfirmed stop sends no signal"
else
  pass "TC-TURNLIMIT-102 unconfirmed stop sends no signal"
fi

echo "== TC-TURNLIMIT-021: review fast path still observes Claude turns =="
TURN_CONTROL_FILE=""
turn_control_init 507 review E2E-REVIEW-OBSERVE \
  inv-v1-a1a1a1a1a1a1a1a1a1a1a1a1 member-claude \
  claude "$TURN_LIMIT_CLAUDE_MIN_VERSION" 2 warn
unset AGENT_PROGRESS_FILE
review_observed_out="$(
  _agent_progress_recorder json <"$CLAUDE_FIXTURE"
)"
assert_eq "TC-TURNLIMIT-021 review recorder passthrough stays byte-identical" \
  "$(cat "$CLAUDE_FIXTURE")" "$review_observed_out"
assert_eq "TC-TURNLIMIT-021 review recorder observes top-level assistant records" 2 \
  "$(jq -r .observed_count "$TURN_CONTROL_FILE")"
assert_eq "TC-TURNLIMIT-021 review recorder emits one warning at the limit" 1 \
  "$(jq '[.evidence[] | select(.action == "warned")] | length' "$TURN_CONTROL_FILE")"
review_warn_records=("$TURN_CONTROL_FILE")
turn_control_complete_review_records review_warn_records warn
assert_eq "TC-TURNLIMIT-034 warn review invocation records completion" completed \
  "$(jq -r .state "$TURN_CONTROL_FILE")"
TURN_CONTROL_FANOUT_TRIP_FILE=""
export TURN_CONTROL_FANOUT_TRIP_FILE

echo "== TC-TURNLIMIT-081: observer persistence failure policy =="
observe_completed_turn_definition="$(declare -f observe_completed_turn)"
observe_completed_turn() { return 1; }
TURN_CONTROL_OBSERVE_ACTIVE=1
TURN_CONTROL_HARD_ACTIVE=1
_agent_progress_recorder json \
  >"$WORK/hard-observer.out" 2>"$WORK/hard-observer.err" \
  <<'EOF'
{"type":"assistant"}
EOF
hard_observer_rc=$?
observer_adapter_stub="$WORK/claude-observer-stub"
printf '%s\n' \
  '#!/bin/sh' \
  'cat >/dev/null' \
  'printf '\''{"type":"assistant"}\n'\''' \
  >"$observer_adapter_stub"
chmod +x "$observer_adapter_stub"
AGENT_LAUNCHER_ARGV=()
AGENT_CMD="$observer_adapter_stub"
AGENT_DEV_EXTRA_ARGS=""
AGENT_TIMEOUT=5
adapter_invoke_claude dev-new 11111111-1111-4111-8111-111111111111 \
  '{"type":"assistant"}' "" "" \
  >"$WORK/hard-adapter-observer.out" 2>"$WORK/hard-adapter-observer.err"
hard_adapter_observer_rc=$?
TURN_CONTROL_HARD_ACTIVE=0
unset TURN_CONTROL_OBSERVE_WARNED_FAILURE
_agent_progress_recorder json \
  >"$WORK/warn-observer.out" 2>"$WORK/warn-observer.err" \
  <<'EOF'
{"type":"assistant"}
{"type":"assistant"}
EOF
warn_observer_rc=$?
eval "$observe_completed_turn_definition"
assert_eq "TC-TURNLIMIT-081 hard observation persistence fails closed" 1 \
  "$hard_observer_rc"
assert_eq "TC-TURNLIMIT-088 adapter propagates hard observer failure as control rc" \
  93 "$hard_adapter_observer_rc"
assert_eq "TC-TURNLIMIT-081 hard observation failure is loud" 1 \
  "$(grep -c 'ERROR:.*turn observation' "$WORK/hard-observer.err" || true)"
assert_eq "TC-TURNLIMIT-081 warn observation persistence continues" 0 \
  "$warn_observer_rc"
assert_eq "TC-TURNLIMIT-081 warn observation diagnostic is bounded" 1 \
  "$(grep -c 'WARN:.*turn observation' "$WORK/warn-observer.err" || true)"
TURN_CONTROL_OBSERVE_ACTIVE=0

accounting_invocation_id() { return 1; }
turn_accounting_begin 507 E2E-ACCOUNTING dev dev 1 hard >/dev/null 2>&1
turn_identity_fail_rc=$?
accounting_invocation_id() { printf 'inv-v1-e2e-accounting\n'; }
accounting_start() { return 1; }
turn_accounting_begin 507 E2E-ACCOUNTING dev dev 1 hard >/dev/null 2>&1
turn_start_fail_rc=$?
accounting_start() { return 0; }
turn_accounting_begin 507 E2E-ACCOUNTING dev dev 1 hard >/dev/null 2>&1
turn_start_ok_rc=$?
assert_eq "TC-TURNLIMIT-031 turn accounting identity failure refuses" 1 \
  "$turn_identity_fail_rc"
assert_eq "TC-TURNLIMIT-031 hard turn accounting start failure refuses" 1 \
  "$turn_start_fail_rc"
assert_eq "TC-TURNLIMIT-031 hard turn accounting start succeeds" 0 \
  "$turn_start_ok_rc"

echo "== TC-TURNLIMIT-062: exact-N synthetic admission =="
TURN_CONTROL_FILE=""
turn_control_init 507 dev E2E-EXACT inv-v1-aaaaaaaaaaaaaaaaaaaaaaaa dev \
  synthetic fixture 3 hard
export TURN_CONTROL_FILE
export SYNTHETIC_ADMISSION_LOG="$WORK/exact-admissions"
: > "$SYNTHETIC_ADMISSION_LOG"
SYNTHETIC_WAIT_AFTER_DENY=false bash "$FIXTURE" >"$WORK/exact.out"
assert_eq "TC-TURNLIMIT-062 exactly N requests admitted" 3 \
  "$(wc -l < "$SYNTHETIC_ADMISSION_LOG" | tr -d ' ')"
if grep -q '^request=4$' "$SYNTHETIC_ADMISSION_LOG"; then
  fail "TC-TURNLIMIT-062 request N+1 was not admitted"
else
  pass "TC-TURNLIMIT-062 request N+1 was not admitted"
fi
assert_eq "TC-TURNLIMIT-062 exactly N turns completed" 3 \
  "$(jq -r .observed_count "$TURN_CONTROL_FILE")"

echo "== TC-TURNLIMIT-076: observation persistence fails closed =="
TURN_CONTROL_FILE=""
turn_control_init 507 dev E2E-OBSERVE-FAIL \
  inv-v1-acacacacacacacacacacacac dev synthetic fixture 3 hard
export TURN_CONTROL_FILE
observation_admissions="$WORK/observation-failure-admissions"
: >"$observation_admissions"
chmod 500 "$(dirname "$TURN_CONTROL_FILE")"
timeout 3 env SYNTHETIC_ADMISSION_LOG="$observation_admissions" \
  TURN_CONTROL_FILE="$TURN_CONTROL_FILE" TURN_LIMIT_LIB="$TURN_LIMIT_LIB" \
  bash "$FIXTURE" >"$WORK/observation-failure.out" 2>"$WORK/observation-failure.err"
observation_rc=$?
chmod 700 "$(dirname "$TURN_CONTROL_FILE")"
assert_eq "TC-TURNLIMIT-076 observation persistence exits nonzero" 1 \
  "$observation_rc"
assert_eq "TC-TURNLIMIT-076 no request follows the unrecorded completion" 1 \
  "$(wc -l <"$observation_admissions" | tr -d ' ')"

echo "== TC-TURNLIMIT-042/046/064: turn-cap watchdog winner =="
TURN_CONTROL_FILE=""
turn_control_init 507 dev E2E-TURN inv-v1-bbbbbbbbbbbbbbbbbbbbbbbb dev \
  synthetic fixture 1 hard
export TURN_CONTROL_FILE
export SYNTHETIC_ADMISSION_LOG="$WORK/turn-admissions"
: > "$SYNTHETIC_ADMISSION_LOG"
AGENT_TIMEOUT=10
_AGENT_WATCHDOG_GRACE_SECS=1
SYNTHETIC_WAIT_AFTER_DENY=true _run_with_timeout bash "$FIXTURE" >"$WORK/turn.out" 2>"$WORK/turn.err"
turn_rc=$?
assert_eq "TC-TURNLIMIT-042 turn-cap maps to rc 92" 92 "$turn_rc"
assert_eq "TC-TURNLIMIT-064 first durable winner is turn-cap" turn-cap \
  "$(turn_control_winner)"

echo "== TC-TURNLIMIT-082: fast cap closes the terminating boundary =="
TURN_CONTROL_FILE=""
turn_control_init 507 dev E2E-FAST-CAP \
  inv-v1-bcbcbcbcbcbcbcbcbcbcbcbc dev synthetic fixture 99 hard
export TURN_CONTROL_FILE
turn_control_request_stop turn-cap
AGENT_TIMEOUT=10
_run_with_timeout true >/dev/null 2>&1
fast_cap_rc=$?
assert_eq "TC-TURNLIMIT-082 fast cap preserves controlled rc" 92 \
  "$fast_cap_rc"
assert_eq "TC-TURNLIMIT-082 fast cap reaches terminating state" terminating \
  "$(jq -r .state "$TURN_CONTROL_FILE")"
assert_eq "TC-TURNLIMIT-082 fast cap records terminated evidence" 1 \
  "$(jq '[.evidence[] | select(.action == "terminated")] | length' "$TURN_CONTROL_FILE")"

echo "== TC-TURNLIMIT-083: final durable-state read failure is control error =="
TURN_CONTROL_FILE=""
turn_control_init 507 dev E2E-WINNER-READ-FAIL \
  inv-v1-bdbdbdbdbdbdbdbdbdbdbdbd dev synthetic fixture 99 hard
export TURN_CONTROL_FILE
turn_control_winner_definition="$(declare -f turn_control_winner)"
turn_control_winner() { return 1; }
_run_with_timeout true >/dev/null 2>&1
winner_read_fail_rc=$?
eval "$turn_control_winner_definition"
assert_eq "TC-TURNLIMIT-083 unreadable final state maps to control rc" 93 \
  "$winner_read_fail_rc"
assert_eq "TC-TURNLIMIT-083 unreadable final state is not mislabeled complete" \
  running "$(jq -r .state "$TURN_CONTROL_FILE")"

echo "== TC-TURNLIMIT-046: durable winner survives TERM no-op race =="
TURN_CONTROL_FILE=""
turn_control_init 507 dev E2E-TERM-RACE inv-v1-babababababababababababa dev \
  synthetic fixture 99 hard
export TURN_CONTROL_FILE
turn_control_request_stop turn-cap
term_seen="$WORK/term-race-signal"
AGENT_TIMEOUT=10
_AGENT_WATCHDOG_GRACE_SECS=1
_TURN_CONTROL_WATCHDOG_TERM_DELAY_SECONDS=1 \
  _run_with_timeout bash -c '
    trap "printf term >\"$2\"; exit 0" TERM
    until [[ "$(jq -r .state "$1")" == "terminating" ]]; do sleep 0.01; done
  ' _ "$TURN_CONTROL_FILE" "$term_seen" >"$WORK/term-race.out" 2>"$WORK/term-race.err"
term_race_rc=$?
assert_eq "TC-TURNLIMIT-046 persisted turn winner controls rc after natural exit" \
  92 "$term_race_rc"
if [[ ! -e "$term_seen" ]]; then
  pass "TC-TURNLIMIT-046 natural exit makes watchdog TERM a no-op"
else
  fail "TC-TURNLIMIT-046 natural exit makes watchdog TERM a no-op"
fi
assert_eq "TC-TURNLIMIT-046 TERM no-op cannot replace durable winner" turn-cap \
  "$(turn_control_winner)"

echo "== TC-TURNLIMIT-044/063: timeout watchdog winner =="
TURN_CONTROL_FILE=""
turn_control_init 507 dev E2E-TIMEOUT inv-v1-cccccccccccccccccccccccc dev \
  synthetic fixture 99 hard
export TURN_CONTROL_FILE
AGENT_TIMEOUT=1
_AGENT_WATCHDOG_GRACE_SECS=3
_run_with_timeout bash -c 'trap "exit 0" TERM; sleep 30' >"$WORK/timeout.out" 2>"$WORK/timeout.err"
timeout_rc=$?
assert_eq "TC-TURNLIMIT-044 timeout maps to rc 124" 124 "$timeout_rc"
assert_eq "TC-TURNLIMIT-063 first durable winner is timeout" timeout \
  "$(turn_control_winner)"
turn_control_request_stop turn-cap >/dev/null 2>&1
assert_eq "TC-TURNLIMIT-063 late turn request cannot replace timeout" timeout \
  "$(turn_control_winner)"

TURN_CONTROL_FILE=""
turn_control_init 507 dev E2E-TIMEOUT-KILL inv-v1-cdcdcdcdcdcdcdcdcdcdcdcd dev \
  synthetic fixture 99 hard
export TURN_CONTROL_FILE
AGENT_TIMEOUT=1
_AGENT_WATCHDOG_GRACE_SECS=1
_run_with_timeout bash -c 'trap "" TERM; while :; do sleep 1; done' \
  >"$WORK/timeout-kill.out" 2>"$WORK/timeout-kill.err"
timeout_kill_rc=$?
assert_eq "TC-TURNLIMIT-045 timeout-owned KILL maps to rc 137" \
  137 "$timeout_kill_rc"
assert_eq "TC-TURNLIMIT-045 timeout remains winner after KILL escalation" timeout \
  "$(turn_control_winner)"
assert_eq "TC-TURNLIMIT-045 timeout lifecycle is terminal" terminal-transitioned \
  "$(jq -r .state "$TURN_CONTROL_FILE")"

echo "== TC-TURNLIMIT-044/047: leader exit cannot strand descendants =="
TURN_CONTROL_FILE=""
turn_control_init 507 dev E2E-LEADER-EXIT \
  inv-v1-cececececececececececece dev synthetic fixture 99 hard
export TURN_CONTROL_FILE
leader_child="$WORK/leader-child"
AGENT_TIMEOUT=1
_AGENT_WATCHDOG_GRACE_SECS=1
started="$SECONDS"
_run_with_timeout bash -c '
  (trap "" TERM; printf "%s\n" "$BASHPID" >"$1"; while :; do sleep 1; done) &
  exit 0
' _ "$leader_child" >"$WORK/leader-exit.out" 2>"$WORK/leader-exit.err"
leader_exit_rc=$?
elapsed=$((SECONDS - started))
assert_eq "TC-TURNLIMIT-044 surviving descendant preserves timeout rc" 137 \
  "$leader_exit_rc"
if [[ "$elapsed" -ge 2 ]]; then
  pass "TC-TURNLIMIT-047 wrapper waits through descendant KILL escalation"
else
  fail "TC-TURNLIMIT-047 wrapper waits through descendant KILL escalation"
fi
if [[ -s "$leader_child" ]] && ! kill -0 "$(cat "$leader_child")" 2>/dev/null; then
  pass "TC-TURNLIMIT-047 leader-exit descendant is reaped"
else
  fail "TC-TURNLIMIT-047 leader-exit descendant is reaped"
fi
assert_eq "TC-TURNLIMIT-044 leader-exit timeout lifecycle is terminal" \
  terminal-transitioned "$(jq -r .state "$TURN_CONTROL_FILE")"

echo "== TC-TURNLIMIT-087: watchdog rc wins over stale timeout marker =="
TURN_CONTROL_FILE=""
turn_control_init 507 dev E2E-STALE-TIMEOUT-MARKER \
  inv-v1-cdcacdcacdcacdcacdcacdca dev synthetic fixture 99 hard
export TURN_CONTROL_FILE
AGENT_TIMEOUT=1
_AGENT_WATCHDOG_GRACE_SECS=1
mv() {
  if [[ -f "${1:-}" && "$(cat "$1" 2>/dev/null)" == "137" ]]; then
    return 1
  fi
  command mv "$@"
}
_run_with_timeout bash -c 'trap "" TERM; while :; do sleep 1; done' \
  >/dev/null 2>&1
stale_timeout_marker_rc=$?
unset -f mv
assert_eq "TC-TURNLIMIT-087 KILL rc overrides stale 124 marker" 137 \
  "$stale_timeout_marker_rc"

echo "== TC-TURNLIMIT-073: persistence precedes every signal =="
persistence_rc_file="$WORK/persistence-failure.rc"
persistence_record="$RUN_DIR/turn-control/inv-v1-cfcfcfcfcfcfcfcfcfcfcfcf.json"
persistence_signal="$WORK/persistence-failure.signal"
(
  TURN_CONTROL_FILE=""
  turn_control_init 507 dev E2E-PERSISTENCE \
    inv-v1-cfcfcfcfcfcfcfcfcfcfcfcf dev synthetic fixture 99 hard
  export TURN_CONTROL_FILE
  turn_control_request_stop() { return 1; }
  AGENT_TIMEOUT=1
  _AGENT_WATCHDOG_GRACE_SECS=1
  _run_with_timeout bash -c \
    'trap "touch \"$1\"; exit 0" TERM; sleep 2; exit 7' _ "$persistence_signal" \
    >/dev/null 2>&1
  printf '%s\n' "$?" >"$persistence_rc_file"
)
assert_eq "TC-TURNLIMIT-073 failed timeout persistence preserves natural rc" 7 \
  "$(cat "$persistence_rc_file")"
assert_eq "TC-TURNLIMIT-073 natural exit wins when no stop was durable" completed \
  "$(jq -r .state "$persistence_record")"
if [[ ! -e "$persistence_signal" ]]; then
  pass "TC-TURNLIMIT-073 failed stop persistence sends no TERM"
else
  fail "TC-TURNLIMIT-073 failed stop persistence sends no TERM"
fi

terminating_rc_file="$WORK/terminating-failure.rc"
terminating_record="$RUN_DIR/turn-control/inv-v1-cbcacbcacbcacbcacbcacbca.json"
terminating_signal="$WORK/terminating-failure.signal"
(
  TURN_CONTROL_FILE=""
  turn_control_init 507 dev E2E-TERMINATING \
    inv-v1-cbcacbcacbcacbcacbcacbca dev synthetic fixture 99 hard
  export TURN_CONTROL_FILE
  turn_control_request_stop turn-cap
  turn_control_mark_terminating() { return 1; }
  AGENT_TIMEOUT=10
  _AGENT_WATCHDOG_GRACE_SECS=1
  _run_with_timeout bash -c \
    'trap "touch \"$1\"; exit 0" TERM; sleep 1; exit 0' _ "$terminating_signal" \
    >/dev/null 2>&1
  printf '%s\n' "$?" >"$terminating_rc_file"
)
assert_eq "TC-TURNLIMIT-117 final lifecycle persistence failure returns control rc" 93 \
  "$(cat "$terminating_rc_file")"
assert_eq "TC-TURNLIMIT-073 terminating-write fault preserves winner" turn-cap \
  "$(jq -r .winner "$terminating_record")"
assert_eq "TC-TURNLIMIT-073 failed terminating write remains stop-requested" \
  stop-requested "$(jq -r .state "$terminating_record")"
if [[ ! -e "$terminating_signal" ]]; then
  pass "TC-TURNLIMIT-073 failed terminating persistence sends no TERM"
else
  fail "TC-TURNLIMIT-073 failed terminating persistence sends no TERM"
fi

echo "== TC-TURNLIMIT-019: hard control requires setsid before launch =="
no_setsid_path="$WORK/no-setsid-path"
mkdir -p "$no_setsid_path"
TURN_CONTROL_FILE=""
turn_control_init 507 dev E2E-NO-SETSID \
  inv-v1-cacacacacacacacacacacaca dev synthetic fixture 99 hard
export TURN_CONTROL_FILE
no_setsid_sentinel="$WORK/no-setsid-launched"
PATH="$no_setsid_path" _run_with_timeout /bin/bash -c 'touch "$1"' \
  _ "$no_setsid_sentinel" >/dev/null 2>&1
no_setsid_rc=$?
assert_eq "TC-TURNLIMIT-019 missing setsid uses control-plane rc" 93 \
  "$no_setsid_rc"
if [[ ! -e "$no_setsid_sentinel" ]]; then
  pass "TC-TURNLIMIT-019 missing setsid starts no process"
else
  fail "TC-TURNLIMIT-019 missing setsid starts no process"
fi

echo "== TC-TURNLIMIT-079: hard prelaunch control faults use rc 93 =="
malformed_prelaunch_trip="$RUN_DIR/turn-control/malformed-prelaunch-trip.json"
TURN_CONTROL_FILE=""
turn_control_init 507 review E2E-MALFORMED-PRELAUNCH \
  inv-v1-c1c1c1c1c1c1c1c1c1c1c1c1 member-malformed \
  synthetic fixture 99 hard
malformed_prelaunch_trip="$TURN_CONTROL_FANOUT_TRIP_FILE"
export TURN_CONTROL_FILE TURN_CONTROL_FANOUT_TRIP_FILE
printf '%s\n' '{"schema_version":1,"reason":"turn-cap"}' >"$malformed_prelaunch_trip"
malformed_prelaunch_sentinel="$WORK/malformed-prelaunch-launched"
_run_with_timeout bash -c 'touch "$1"' _ "$malformed_prelaunch_sentinel" \
  >/dev/null 2>&1
malformed_prelaunch_rc=$?
assert_eq "TC-TURNLIMIT-079 malformed trip maps to control-plane rc" \
  93 "$malformed_prelaunch_rc"
if [[ ! -e "$malformed_prelaunch_sentinel" ]]; then
  pass "TC-TURNLIMIT-079 malformed trip starts no adapter process"
else
  fail "TC-TURNLIMIT-079 malformed trip starts no adapter process"
fi
rm -f "$malformed_prelaunch_trip" "${malformed_prelaunch_trip}.lock"

locked_prelaunch_trip="$RUN_DIR/turn-control/locked-prelaunch-trip.json"
TURN_CONTROL_FILE=""
turn_control_init 507 review E2E-LOCKED-PRELAUNCH \
  inv-v1-c2c2c2c2c2c2c2c2c2c2c2c2 member-locked \
  synthetic fixture 99 hard
locked_prelaunch_trip="$TURN_CONTROL_FANOUT_TRIP_FILE"
export TURN_CONTROL_FILE TURN_CONTROL_FANOUT_TRIP_FILE
turn_control_lock_definition="$(declare -f _turn_control_lock)"
_turn_control_lock() { return 1; }
locked_prelaunch_sentinel="$WORK/locked-prelaunch-launched"
_run_with_timeout bash -c 'touch "$1"' _ "$locked_prelaunch_sentinel" \
  >/dev/null 2>&1
locked_prelaunch_rc=$?
eval "$turn_control_lock_definition"
assert_eq "TC-TURNLIMIT-079 launch-lock failure maps to control-plane rc" \
  93 "$locked_prelaunch_rc"
if [[ ! -e "$locked_prelaunch_sentinel" ]]; then
  pass "TC-TURNLIMIT-079 launch-lock failure starts no adapter process"
else
  fail "TC-TURNLIMIT-079 launch-lock failure starts no adapter process"
fi

echo "== TC-TURNLIMIT-045/047: TERM then KILL reaps full group =="
TURN_CONTROL_FILE=""
turn_control_init 507 dev E2E-KILL inv-v1-dddddddddddddddddddddddd dev \
  synthetic fixture 1 hard
export TURN_CONTROL_FILE
export SYNTHETIC_ADMISSION_LOG="$WORK/kill-admissions"
export SYNTHETIC_DESCENDANT_LOG="$WORK/descendant-alive"
: > "$SYNTHETIC_ADMISSION_LOG"
AGENT_TIMEOUT=10
_AGENT_WATCHDOG_GRACE_SECS=1
SYNTHETIC_WAIT_AFTER_DENY=true SYNTHETIC_IGNORE_TERM=true \
  SYNTHETIC_SPAWN_DESCENDANT=true \
  _run_with_timeout bash "$FIXTURE" >"$WORK/kill.out" 2>"$WORK/kill.err"
kill_rc=$?
assert_eq "TC-TURNLIMIT-045 non-timeout KILL still maps to controlled rc" 92 "$kill_rc"
sleep 1
if [[ -s "$SYNTHETIC_DESCENDANT_LOG" ]]; then
  last="$(tail -1 "$SYNTHETIC_DESCENDANT_LOG")"
  now="$(date +%s)"
  if (( now - last >= 1 )); then
    pass "TC-TURNLIMIT-047 descendant stopped before watchdog returned"
  else
    fail "TC-TURNLIMIT-047 descendant stopped before watchdog returned"
  fi
else
  fail "TC-TURNLIMIT-047 descendant fixture wrote a liveness marker"
fi

echo "== TC-TURNLIMIT-053..065: review trip cancels active sibling =="
trip="$RUN_DIR/turn-control/fanout-trip.json"
trigger_record="$RUN_DIR/turn-control/inv-v1-eeeeeeeeeeeeeeeeeeeeeeee.json"
sibling_record="$RUN_DIR/turn-control/inv-v1-ffffffffffffffffffffffff.json"
trigger_rc_file="$WORK/trigger.rc"
sibling_rc_file="$WORK/sibling.rc"
sibling_ready_file="$WORK/sibling.ready"

(
  TURN_CONTROL_FILE=""
  TURN_CONTROL_FANOUT_TRIP_FILE="$trip"
  turn_control_init 507 review E2E-FANOUT \
    inv-v1-ffffffffffffffffffffffff sibling synthetic fixture 99 hard
  export TURN_CONTROL_FILE TURN_CONTROL_FANOUT_TRIP_FILE
  AGENT_TIMEOUT=20
  _AGENT_WATCHDOG_GRACE_SECS=1
  _run_with_timeout bash -c \
    'printf "%s\n" "$BASHPID" >"$1"; while :; do sleep 1; done' \
    _ "$sibling_ready_file" >/dev/null 2>&1
  printf '%s\n' "$?" > "$sibling_rc_file"
) &
sibling_controller=$!

for _ready_i in {1..100}; do
  [[ -s "$sibling_ready_file" ]] && break
  sleep 0.05
done
if [[ -s "$sibling_ready_file" ]]; then
  pass "TC-TURNLIMIT-065 sibling PGID is live before trigger trips"
else
  fail "TC-TURNLIMIT-065 sibling PGID is live before trigger trips"
fi
sibling_pgid="$(cat "$sibling_ready_file" 2>/dev/null || true)"
(
  TURN_CONTROL_FILE=""
  TURN_CONTROL_FANOUT_TRIP_FILE="$trip"
  turn_control_init 507 review E2E-FANOUT \
    inv-v1-eeeeeeeeeeeeeeeeeeeeeeee trigger synthetic fixture 1 hard
  export TURN_CONTROL_FILE TURN_CONTROL_FANOUT_TRIP_FILE
  SYNTHETIC_ADMISSION_LOG="$WORK/fanout-trigger-admissions"
  export SYNTHETIC_ADMISSION_LOG
  : > "$SYNTHETIC_ADMISSION_LOG"
  AGENT_TIMEOUT=20
  _AGENT_WATCHDOG_GRACE_SECS=1
  SYNTHETIC_WAIT_AFTER_DENY=true _run_with_timeout bash "$FIXTURE" >/dev/null 2>&1
  printf '%s\n' "$?" > "$trigger_rc_file"
) &
trigger_controller=$!

wait "$trigger_controller"
wait "$sibling_controller"
assert_eq "TC-TURNLIMIT-065 trigger exits controlled" 92 "$(cat "$trigger_rc_file")"
assert_eq "TC-TURNLIMIT-065 sibling exits controlled" 92 "$(cat "$sibling_rc_file")"
assert_eq "TC-TURNLIMIT-065 trigger winner remains turn-cap" turn-cap \
  "$(jq -r .winner "$trigger_record")"
assert_eq "TC-TURNLIMIT-065 sibling winner is fanout-cancel" fanout-cancel \
  "$(jq -r .winner "$sibling_record")"
assert_eq "TC-TURNLIMIT-065 sibling lifecycle is terminal" terminal-transitioned \
  "$(jq -r .state "$sibling_record")"
if [[ "$sibling_pgid" =~ ^[0-9]+$ ]] \
    && ! kill -0 -- "-$sibling_pgid" 2>/dev/null; then
  pass "TC-TURNLIMIT-065 sibling watchdog reaps the original live PGID"
else
  fail "TC-TURNLIMIT-065 sibling watchdog reaps the original live PGID"
fi
if turn_fanout_trip_active "$trip"; then
  pass "TC-TURNLIMIT-054 later launch is suppressed by active trip"
else
  fail "TC-TURNLIMIT-054 later launch is suppressed by active trip"
fi

echo "== TC-TURNLIMIT-074: active trip suppresses final process spawn =="
TURN_CONTROL_FILE=""
TURN_CONTROL_FANOUT_TRIP_FILE="$trip"
turn_control_init 507 review E2E-FANOUT \
  inv-v1-fefefefefefefefefefefefe queued synthetic fixture 99 hard
export TURN_CONTROL_FILE TURN_CONTROL_FANOUT_TRIP_FILE
queued_record="$TURN_CONTROL_FILE"
queued_sentinel="$WORK/queued-member-launched"
AGENT_TIMEOUT=10
_run_with_timeout bash -c 'touch "$1"' _ "$queued_sentinel" >/dev/null 2>&1
queued_rc=$?
assert_eq "TC-TURNLIMIT-074 queued member returns controlled rc" 92 "$queued_rc"
assert_eq "TC-TURNLIMIT-074 queued member records sibling cancellation" \
  fanout-cancel "$(jq -r .winner "$queued_record")"
assert_eq "TC-TURNLIMIT-074 no-spawn cancellation follows full lifecycle" \
  terminal-transitioned "$(jq -r .state "$queued_record")"
assert_eq "TC-TURNLIMIT-074 no-spawn cancellation records terminated evidence" 1 \
  "$(jq '[.evidence[] | select(.action == "terminated")] | length' "$queued_record")"
if [[ ! -e "$queued_sentinel" ]]; then
  pass "TC-TURNLIMIT-074 active trip starts no adapter process"
else
  fail "TC-TURNLIMIT-074 active trip starts no adapter process"
fi

echo "== TC-TURNLIMIT-055/060: rerun suppression and terminal routing =="
codex_record="$RUN_DIR/turn-control/inv-v1-999999999999999999999999.json"
TURN_CONTROL_FILE=""
TURN_CONTROL_FANOUT_TRIP_FILE="$trip"
turn_control_init 507 review E2E-FANOUT \
  inv-v1-999999999999999999999999 codex synthetic fixture 99 hard
export TURN_CONTROL_FILE TURN_CONTROL_FANOUT_TRIP_FILE
codex_runs="$WORK/codex-runs"
: > "$codex_runs"
_run_with_timeout() {
  printf 'run\n' >> "$codex_runs"
  return 1
}
AGENT_CMD=bash
AGENT_REVIEW_EXTRA_ARGS=""
CODEX_REVIEW_MAX_RERUNS=3
_run_codex_review "synthetic review" sonnet "$WORK/codex.out" "$WORK" "$WORK"
codex_rc=$?
assert_eq "TC-TURNLIMIT-055 active trip suppresses codex rerun" 1 \
  "$(wc -l < "$codex_runs" | tr -d ' ')"
assert_eq "TC-TURNLIMIT-055 suppressed codex controller returns rc 92" 92 \
  "$codex_rc"
assert_eq "TC-TURNLIMIT-056 suppressed codex member records fanout-cancel" \
  fanout-cancel "$(jq -r .winner "$codex_record")"

TURN_CONTROL_FILE=""
TURN_CONTROL_FANOUT_TRIP_FILE="$trip"
turn_control_init 507 review E2E-FANOUT \
  inv-v1-949494949494949494949494 codex-sync-fail synthetic fixture 99 hard
export TURN_CONTROL_FILE TURN_CONTROL_FANOUT_TRIP_FILE
codex_sync_fail_record="$TURN_CONTROL_FILE"
: >"$codex_runs"
turn_control_sync_definition="$(declare -f turn_control_sync_fanout_trip)"
turn_control_sync_fanout_trip() { return 1; }
_run_codex_review "synthetic review" sonnet \
  "$WORK/codex-sync-fail.out" "$WORK" "$WORK"
codex_sync_fail_rc=$?
eval "$turn_control_sync_definition"
assert_eq "TC-TURNLIMIT-084 codex sync failure suppresses rerun" 1 \
  "$(wc -l <"$codex_runs" | tr -d ' ')"
assert_eq "TC-TURNLIMIT-084 codex sync failure returns control rc" 93 \
  "$codex_sync_fail_rc"
assert_eq "TC-TURNLIMIT-084 codex sync failure fabricates no winner" null \
  "$(jq -r .winner "$codex_sync_fail_record")"

intent_log="$WORK/terminal-intents"
transition_log="$WORK/terminal-transitions"
wrapper_accounting_log="$WORK/wrapper-accounting"
: > "$intent_log"
: > "$transition_log"
: > "$wrapper_accounting_log"
terminal_intent_write() {
  printf '%s|%s|%s|%s|%s\n' "$@" >> "$intent_log"
}
terminal_intent_cleanup_transition() {
  printf '%s|%s|%s|%s\n' "$@" >> "$transition_log"
}
token_accounting_commit_definition="$(declare -f token_accounting_commit)"
token_accounting_commit() {
  printf '%s|%s|%s\n' "$1" "$2" "${6:-}" >>"$wrapper_accounting_log"
  printf '{"state":"usage-unknown","reason":"%s","commit_failed":false}\n' "${6:-}"
}
log() { printf '%s\n' "$*" >>"$WORK/wrapper.log"; }
review_decision_function="$(
  awk '
    /^_turn_review_post_fanout_decision\(\)/ { capture = 1 }
    capture { print }
    capture && /^}/ { exit }
  ' "$REVIEW_WRAPPER"
)"
[[ -n "$review_decision_function" ]] && eval "$review_decision_function"

echo "== TC-TURNLIMIT-077: real dev-wrapper launch functions =="
dev_functions="$(
  awk '
    /^_resource_dev_launch_begin\(\)/ { capture = 1 }
    capture { print }
    capture && /^}/ {
      closed++
      if (closed == 2) exit
    }
  ' "$SCRIPTS/autonomous-dev.sh"
)"
dev_intent_log="$WORK/dev-intents"
dev_commit_log="$WORK/dev-accounting"
: >"$dev_intent_log"
: >"$dev_commit_log"
if [[ -n "$dev_functions" ]]; then
  eval "$dev_functions"
  token_budget_enabled() { return 1; }
  accounting_invocation_id() {
    printf 'inv-v1-%024x\n' "$4"
  }
  turn_accounting_begin() {
    printf 'inv-v1-%024x\n' "$RESOURCE_DEV_ATTEMPT"
  }
  token_accounting_commit() {
    _dev_commit_reason="${5:-${6:-}}"
    printf '%s|%s|%s\n' "$1" "$2" "$_dev_commit_reason" >>"$dev_commit_log"
    printf '{"state":"usage-unknown","reason":"%s","commit_failed":false}\n' \
      "$_dev_commit_reason"
  }
  terminal_intent_write() {
    printf '%s|%s|%s|%s|%s\n' "$@" >>"$dev_intent_log"
  }
  TURN_DEV_ENABLED=true
  TURN_DEV_LIMIT=1
  TURN_DEV_MODE=hard
  TURN_DEV_ADAPTER_VERSION=fixture
  TURN_DEV_ACCOUNTING_STARTED=false
  TURN_DEV_WINNER=""
  TURN_DEV_ROUTE_FAILED=false
  TURN_DEV_ACCOUNTING_FAILED=false
  TURN_DEV_LAUNCH_REFUSED=false
  TOKEN_BUDGET_LAUNCH_REFUSED=false
  RESOURCE_DEV_ATTEMPT=0
  RESOURCE_DEV_ACTIVE_ID=""
  RESOURCE_DEV_ACTIVE_OFFSET=0
  TOKEN_DEV_INVOCATION_IDS=()
  TOKEN_DEV_RESULTS=()
  ISSUE_NUMBER=507
  RUN_ID=E2E-DEV-WRAPPER
  AGENT_CMD=synthetic
  LOG_FILE="$WORK/dev-wrapper.log"
  : >"$LOG_FILE"

  _resource_dev_launch_begin
  dev_begin_rc=$?
  turn_control_request_stop turn-cap
  _resource_dev_launch_finish
  dev_cap_finish_rc=$?

  _resource_dev_launch_begin
  dev_natural_begin_rc=$?
  _resource_dev_launch_finish
  dev_natural_finish_rc=$?

  _resource_dev_launch_begin
  turn_control_request_stop turn-cap
  dev_intent_definition="$(declare -f terminal_intent_write)"
  terminal_intent_write() { return 1; }
  _resource_dev_launch_finish
  dev_route_fail_rc=$?
  eval "$dev_intent_definition"

  _resource_dev_launch_begin
  turn_control_request_stop turn-cap
  dev_intents_before_accounting_fail="$(wc -l <"$dev_intent_log" | tr -d ' ')"
  dev_commit_definition="$(declare -f token_accounting_commit)"
  token_accounting_commit() {
    printf '{"state":"usage-unknown","reason":"turn-cap","commit_failed":true}\n'
  }
  _resource_dev_launch_finish
  dev_accounting_commit_fail_rc=$?
  eval "$dev_commit_definition"
  dev_intents_after_accounting_fail="$(wc -l <"$dev_intent_log" | tr -d ' ')"

  TURN_DEV_LAUNCH_REFUSED=false
  _resource_dev_launch_begin
  dev_read_failure_record="$TURN_CONTROL_FILE"
  dev_commits_before_read_failure="$(wc -l <"$dev_commit_log" | tr -d ' ')"
  turn_control_winner_definition="$(declare -f turn_control_winner)"
  turn_control_winner() { return 1; }
  _resource_dev_launch_finish 0
  dev_winner_read_fail_rc=$?
  eval "$turn_control_winner_definition"
  dev_commits_after_read_failure="$(wc -l <"$dev_commit_log" | tr -d ' ')"
  dev_read_failure_state="$(jq -r .state "$dev_read_failure_record")"
  dev_read_failure_commit="$(tail -1 "$dev_commit_log")"

  TURN_DEV_LAUNCH_REFUSED=false
  _resource_dev_launch_begin
  dev_rc93_record="$TURN_CONTROL_FILE"
  dev_commits_before_rc93="$(wc -l <"$dev_commit_log" | tr -d ' ')"
  _resource_dev_launch_finish 93
  dev_rc93_finish_rc=$?
  dev_commits_after_rc93="$(wc -l <"$dev_commit_log" | tr -d ' ')"
  dev_rc93_state="$(jq -r .state "$dev_rc93_record")"
  dev_rc93_refused="$TURN_DEV_LAUNCH_REFUSED"
  dev_rc93_commit="$(tail -1 "$dev_commit_log")"

  TURN_DEV_MODE=warn
  TURN_DEV_LAUNCH_REFUSED=false
  _resource_dev_launch_begin
  dev_warn_rc93_record="$TURN_CONTROL_FILE"
  _resource_dev_launch_finish 93
  dev_warn_rc93_finish_rc=$?
  dev_warn_rc93_state="$(jq -r .state "$dev_warn_rc93_record")"
  dev_warn_rc93_refused="$TURN_DEV_LAUNCH_REFUSED"

  TURN_DEV_LAUNCH_REFUSED=false
  _resource_dev_launch_begin
  TURN_DEV_LAUNCH_REFUSED=false
  turn_control_winner_definition="$(declare -f turn_control_winner)"
  turn_control_winner() { return 1; }
  _resource_dev_launch_finish 0
  dev_warn_winner_read_rc=$?
  eval "$turn_control_winner_definition"
  dev_warn_winner_read_refused="$TURN_DEV_LAUNCH_REFUSED"

  TURN_DEV_LAUNCH_REFUSED=false
  _resource_dev_launch_begin
  turn_control_mark_completed_definition="$(declare -f turn_control_mark_completed)"
  turn_control_mark_completed() { return 1; }
  _resource_dev_launch_finish 0
  dev_warn_completion_rc=$?
  eval "$turn_control_mark_completed_definition"
  dev_warn_completion_refused="$TURN_DEV_LAUNCH_REFUSED"
  TURN_DEV_MODE=hard

  turn_accounting_begin() { return 1; }
  _resource_dev_launch_begin
  dev_accounting_fail_rc=$?
  dev_accounting_fail_id="$RESOURCE_DEV_ACTIVE_ID"
  dev_accounting_fail_commit="$(tail -1 "$dev_commit_log")"

  turn_accounting_begin() {
    printf 'inv-v1-dev-wrapper-init-fail\n'
  }
  turn_control_init_definition="$(declare -f turn_control_init)"
  turn_control_init() { return 1; }
  _resource_dev_launch_begin
  dev_init_fail_rc=$?
  eval "$turn_control_init_definition"
else
  dev_begin_rc=1
  dev_cap_finish_rc=1
  dev_natural_begin_rc=1
  dev_natural_finish_rc=1
  dev_route_fail_rc=0
  dev_accounting_commit_fail_rc=0
  dev_intents_before_accounting_fail=0
  dev_intents_after_accounting_fail=1
  dev_winner_read_fail_rc=0
  dev_commits_before_read_failure=0
  dev_commits_after_read_failure=0
  dev_read_failure_state=completed
  dev_read_failure_commit=""
  dev_rc93_finish_rc=0
  dev_commits_before_rc93=0
  dev_commits_after_rc93=0
  dev_rc93_state=completed
  dev_rc93_refused=false
  dev_rc93_commit=""
  dev_warn_rc93_finish_rc=1
  dev_warn_rc93_state=running
  dev_warn_rc93_refused=true
  dev_warn_winner_read_rc=1
  dev_warn_winner_read_refused=true
  dev_warn_completion_rc=1
  dev_warn_completion_refused=true
  dev_accounting_fail_rc=0
  dev_accounting_fail_id=""
  dev_accounting_fail_commit=""
  dev_init_fail_rc=0
fi
assert_eq "TC-TURNLIMIT-077 dev hard launch initializes" 0 "$dev_begin_rc"
assert_eq "TC-TURNLIMIT-077 dev turn-cap finish routes" 0 "$dev_cap_finish_rc"
assert_eq "TC-TURNLIMIT-077 dev natural launch initializes" 0 "$dev_natural_begin_rc"
assert_eq "TC-TURNLIMIT-077 dev natural finish succeeds" 0 "$dev_natural_finish_rc"
assert_eq "TC-TURNLIMIT-077 dev terminal intent failure is loud" 1 "$dev_route_fail_rc"
assert_eq "TC-TURNLIMIT-085 dev accounting failure is loud" 1 \
  "$dev_accounting_commit_fail_rc"
assert_eq "TC-TURNLIMIT-085 dev accounting failure writes no terminal intent" \
  "$dev_intents_before_accounting_fail" "$dev_intents_after_accounting_fail"
assert_eq "TC-TURNLIMIT-088 unreadable winner fails dev finish" 1 \
  "$dev_winner_read_fail_rc"
assert_eq "TC-TURNLIMIT-107 unreadable winner closes strict accounting once" \
  "$((dev_commits_before_read_failure + 1))" "$dev_commits_after_read_failure"
assert_eq "TC-TURNLIMIT-107 unreadable winner records control failure" \
  "507|inv-v1-000000000000000000000005|turn-control-error" "$dev_read_failure_commit"
assert_eq "TC-TURNLIMIT-088 unreadable winner preserves running lifecycle" running \
  "$dev_read_failure_state"
assert_eq "TC-TURNLIMIT-088 rc 93 fails dev finish" 1 "$dev_rc93_finish_rc"
assert_eq "TC-TURNLIMIT-107 rc 93 closes strict accounting once" \
  "$((dev_commits_before_rc93 + 1))" "$dev_commits_after_rc93"
assert_eq "TC-TURNLIMIT-107 rc 93 records control failure" \
  "507|inv-v1-000000000000000000000006|turn-control-error" "$dev_rc93_commit"
assert_eq "TC-TURNLIMIT-088 rc 93 preserves running lifecycle" running \
  "$dev_rc93_state"
assert_eq "TC-TURNLIMIT-088 rc 93 marks launch refusal" true \
  "$dev_rc93_refused"
assert_eq "TC-TURNLIMIT-095 warn-mode CLI rc 93 completes normally" 0 \
  "$dev_warn_rc93_finish_rc"
assert_eq "TC-TURNLIMIT-095 warn-mode CLI rc 93 records natural completion" \
  completed "$dev_warn_rc93_state"
assert_eq "TC-TURNLIMIT-095 warn-mode CLI rc 93 is not a control refusal" false \
  "$dev_warn_rc93_refused"
assert_eq "TC-TURNLIMIT-115 warn winner-read failure remains fail-open" 0 \
  "$dev_warn_winner_read_rc"
assert_eq "TC-TURNLIMIT-115 warn winner-read failure is not a refusal" false \
  "$dev_warn_winner_read_refused"
assert_eq "TC-TURNLIMIT-115 warn completion failure remains fail-open" 0 \
  "$dev_warn_completion_rc"
assert_eq "TC-TURNLIMIT-115 warn completion failure is not a refusal" false \
  "$dev_warn_completion_refused"
assert_eq "TC-TURNLIMIT-077 dev accounting failure refuses launch" 1 \
  "$dev_accounting_fail_rc"
assert_eq "TC-TURNLIMIT-116 failed dev accounting keeps canonical id" \
  "inv-v1-00000000000000000000000a" "$dev_accounting_fail_id"
assert_eq "TC-TURNLIMIT-116 failed dev accounting attempts terminal cleanup" \
  "507|inv-v1-00000000000000000000000a|turn-accounting-init-failed" \
  "$dev_accounting_fail_commit"
assert_eq "TC-TURNLIMIT-077 dev record failure refuses launch" 1 "$dev_init_fail_rc"
assert_eq "TC-TURNLIMIT-077 successful dev cap writes one intent" 1 \
  "$(wc -l <"$dev_intent_log" | tr -d ' ')"

dev_budget_helper="$(
  awk '
    /^_resource_dev_evaluate_budget_if_applicable\(\)/ { capture = 1 }
    capture { print }
    capture && /^}/ { exit }
  ' "$SCRIPTS/autonomous-dev.sh"
)"
dev_budget_eval_calls=0
_token_dev_evaluate_cleanup() {
  dev_budget_eval_calls=$((dev_budget_eval_calls + 1))
}
if [[ -n "$dev_budget_helper" ]]; then
  eval "$dev_budget_helper"
  TURN_DEV_WINNER=timeout
  _resource_dev_evaluate_budget_if_applicable
  dev_timeout_budget_rc=$?
else
  dev_timeout_budget_rc=1
fi
assert_eq "TC-TURNLIMIT-108 timeout winner still evaluates token budgets" 0 \
  "$dev_timeout_budget_rc"
assert_eq "TC-TURNLIMIT-108 timeout winner evaluates token budgets once" 1 \
  "$dev_budget_eval_calls"

# Restore the review-wrapper seams and isolate its assertions from dev calls.
eval "$token_accounting_commit_definition"
token_accounting_commit() {
  printf '%s|%s|%s\n' "$1" "$2" "${6:-}" >>"$wrapper_accounting_log"
  printf '{"state":"usage-unknown","reason":"%s","commit_failed":false}\n' "${6:-}"
}
terminal_intent_write() {
  printf '%s|%s|%s|%s|%s\n' "$@" >>"$intent_log"
}
: >"$intent_log"
: >"$wrapper_accounting_log"

TURN_CONTROL_FILE=""
TURN_CONTROL_FANOUT_TRIP_FILE="$trip"
turn_control_init 507 review E2E-FANOUT \
  inv-v1-989898989898989898989898 queued synthetic fixture 99 hard
turn_control_sync_fanout_trip
queued_record="$TURN_CONTROL_FILE"

AGENT_TURN_RECORDS=("$trigger_record" "$sibling_record" "$queued_record")
AGENT_ACCOUNTING_IDS=(
  inv-v1-eeeeeeeeeeeeeeeeeeeeeeee
  inv-v1-ffffffffffffffffffffffff
  inv-v1-989898989898989898989898
)
AGENT_GENERIC_LOGS=(
  "$WORK/trigger.log"
  "$WORK/sibling.log"
  "$WORK/queued.log"
)
AGENT_ACCOUNTING_RESULTS=()
run_review_trip_route() {
  turn_control_review_post_fanout \
    507 "$trip" AGENT_TURN_RECORDS AGENT_ACCOUNTING_IDS \
    AGENT_GENERIC_LOGS AGENT_ACCOUNTING_RESULTS false false hard
}

terminal_intent_write_definition="$(declare -f terminal_intent_write)"
transition_definition="$(declare -f terminal_intent_cleanup_transition)"
token_accounting_commit_mock_definition="$(declare -f token_accounting_commit)"
token_accounting_commit() {
  printf '{"state":"usage-unknown","reason":"turn-cap","commit_failed":true}\n'
}
run_review_trip_route
wrapper_accounting_fail_rc=$?
eval "$token_accounting_commit_mock_definition"

terminal_intent_write() { return 1; }
run_review_trip_route
wrapper_intent_fail_rc=$?
eval "$terminal_intent_write_definition"

terminal_intent_cleanup_transition() { return 1; }
run_review_trip_route
wrapper_transition_fail_rc=$?
eval "$transition_definition"
: >"$intent_log"
: >"$transition_log"
: >"$wrapper_accounting_log"

run_review_trip_route
wrapper_trip_rc=$?

assert_eq "TC-TURNLIMIT-072 wrapper refuses missing terminal intent" 1 \
  "$wrapper_intent_fail_rc"
assert_eq "TC-TURNLIMIT-085 wrapper refuses failed accounting before intent" 1 \
  "$wrapper_accounting_fail_rc"
assert_eq "TC-TURNLIMIT-072 wrapper refuses failed stalled transition" 1 \
  "$wrapper_transition_fail_rc"
assert_eq "TC-TURNLIMIT-090 post-fan-out orchestration returns terminal result" 10 \
  "$wrapper_trip_rc"
assert_eq "TC-TURNLIMIT-060 only trigger writes a terminal intent" 1 \
  "$(wc -l < "$intent_log" | tr -d ' ')"
assert_eq "TC-TURNLIMIT-060 trigger identity and owner are pinned" \
  "507|inv-v1-eeeeeeeeeeeeeeeeeeeeeeee|inv-v1-eeeeeeeeeeeeeeeeeeeeeeee|turn-cap|review-wrapper" \
  "$(cat "$intent_log")"
assert_eq "TC-TURNLIMIT-060 one review stalled transition is requested" 1 \
  "$(wc -l < "$transition_log" | tr -d ' ')"
assert_eq "TC-TURNLIMIT-060 transition reuses terminal cleanup path" \
  "507|reviewing|reviewing|pending-dev" "$(cat "$transition_log")"
assert_eq "TC-TURNLIMIT-072 wrapper accounts trigger as turn-cap" \
  "507|inv-v1-eeeeeeeeeeeeeeeeeeeeeeee|turn-cap" \
  "$(sed -n '1p' "$wrapper_accounting_log")"
assert_eq "TC-TURNLIMIT-072 wrapper accounts sibling as fanout-cancelled" \
  "507|inv-v1-ffffffffffffffffffffffff|fanout-cancelled" \
  "$(sed -n '2p' "$wrapper_accounting_log")"
assert_eq "TC-TURNLIMIT-072 wrapper accounts queued member as fanout-cancelled" \
  "507|inv-v1-989898989898989898989898|fanout-cancelled" \
  "$(sed -n '3p' "$wrapper_accounting_log")"
assert_eq "TC-TURNLIMIT-072 queued no-spawn sibling reaches terminal state" \
  terminal-transitioned "$(jq -r .state "$queued_record")"
assert_eq "TC-TURNLIMIT-072 wrapper finalizes triggering record" terminal-transitioned \
  "$(jq -r .state "$trigger_record")"

echo "== TC-TURNLIMIT-115: review warn completion failures are observation-only =="
TURN_CONTROL_FILE=""
turn_control_init 507 review E2E-WARN-REVIEW \
  inv-v1-919191919191919191919191 warn-member synthetic fixture 99 warn
warn_review_record="$TURN_CONTROL_FILE"
WARN_REVIEW_RECORDS=("$warn_review_record")
WARN_REVIEW_IDS=("")
WARN_REVIEW_LOGS=("$WORK/warn-review.log")
WARN_REVIEW_RESULTS=()
turn_control_mark_completed_definition="$(declare -f turn_control_mark_completed)"
turn_control_mark_completed() { return 1; }
turn_control_review_post_fanout \
  507 "$WORK/no-warn-trip.json" WARN_REVIEW_RECORDS WARN_REVIEW_IDS \
  WARN_REVIEW_LOGS WARN_REVIEW_RESULTS false false warn
warn_review_completion_rc=$?
eval "$turn_control_mark_completed_definition"
assert_eq "TC-TURNLIMIT-115 review warn completion failure keeps aggregation open" \
  0 "$warn_review_completion_rc"

echo "== TC-TURNLIMIT-113: dispatcher restart recovers turn-cap routing =="
# Earlier facade tests replace accounting_invocation_id; restore the real
# durable-store implementation for this restart simulation.
source "$ACCOUNTING_LIB"
recovery_invocation="$(
  accounting_invocation_id E2E-RECOVERY review member-recovery 1
)"
accounting_start 507 "$recovery_invocation" review E2E-RECOVERY member-recovery 1
TURN_CONTROL_FILE=""
TURN_CONTROL_FANOUT_TRIP_FILE="$RUN_DIR/turn-control/recovery-trip.json"
turn_control_init 507 review E2E-RECOVERY \
  "$recovery_invocation" member-recovery synthetic fixture 1 hard
turn_control_request_stop turn-cap
turn_control_mark_terminating
recovery_record="$TURN_CONTROL_FILE"
recovery_sibling="$(
  accounting_invocation_id E2E-RECOVERY review member-sibling 1
)"
accounting_start 507 "$recovery_sibling" review E2E-RECOVERY member-sibling 1
TURN_CONTROL_FILE=""
turn_control_init 507 review E2E-RECOVERY \
  "$recovery_sibling" member-sibling synthetic fixture 1 hard
turn_control_request_stop fanout-cancel
recovery_sibling_record="$TURN_CONTROL_FILE"
recovery_members="$(jq -nc \
  --arg trigger "$recovery_invocation" --arg trigger_path "$recovery_record" \
  --arg sibling "$recovery_sibling" --arg sibling_path "$recovery_sibling_record" '
  [
    {invocation:$trigger, reason:"turn-cap", record_path:$trigger_path},
    {invocation:$sibling, reason:"fanout-cancelled", record_path:$sibling_path}
  ]')"
TURN_CONTROL_FILE="$recovery_record"
turn_control_recovery_stage 507 review-wrapper "$recovery_members"
recovery_pointer="$AUTONOMOUS_ACCOUNTING_DIR/507/.token-budget-recovery-review-wrapper.json"
: >"$intent_log"
: >"$transition_log"
recovery_live_intent=""
terminal_intent_write() {
  printf '%s|%s|%s|%s|%s\n' "$@" >>"$intent_log"
  recovery_live_intent="$(jq -nc \
    --argjson issue "$1" --arg intent "$2" --arg invocation "$3" \
    --arg reason "$4" --arg owner "$5" \
    '{issue:$issue,intent:$intent,invocation:$invocation,reason:$reason,owner:$owner}')"
}
terminal_intent_read() {
  [[ -z "$recovery_live_intent" ]] || printf '%s\n' "$recovery_live_intent"
}
turn_control_recover_pending_intent 507 review-wrapper
recovery_pending_rc=$?
recovery_transition_rc=1
recovery_complete_rc=1
if [[ "$recovery_pending_rc" == "10" ]]; then
  terminal_intent_cleanup_transition 507 reviewing reviewing pending-dev
  recovery_transition_rc=$?
  turn_control_recovery_complete 507 review-wrapper
  recovery_complete_rc=$?
fi
assert_eq "TC-TURNLIMIT-113 next tick discovers a recoverable turn cap" 10 \
  "$recovery_pending_rc"
assert_eq "TC-TURNLIMIT-113 recovery closes missing usage as turn-cap unknown" \
  "usage-unknown|turn-cap" \
  "$(jq -r '[.state, .reason] | join("|")' \
    "$AUTONOMOUS_ACCOUNTING_DIR/507/${recovery_invocation}.json")"
assert_eq "TC-TURNLIMIT-114 recovery closes cancelled sibling accounting" \
  "usage-unknown|fanout-cancelled" \
  "$(jq -r '[.state, .reason] | join("|")' \
    "$AUTONOMOUS_ACCOUNTING_DIR/507/${recovery_sibling}.json")"
assert_eq "TC-TURNLIMIT-113 recovery writes one pinned terminal intent" 1 \
  "$(wc -l <"$intent_log" | tr -d ' ')"
assert_eq "TC-TURNLIMIT-113 recovery performs one stalled transition" 0 \
  "$recovery_transition_rc"
assert_eq "TC-TURNLIMIT-113 recovery finalizes the invocation lifecycle" 0 \
  "$recovery_complete_rc"
assert_eq "TC-TURNLIMIT-113 recovered invocation is terminal" \
  terminal-transitioned "$(jq -r .state "$recovery_record")"
assert_eq "TC-TURNLIMIT-114 recovered sibling lifecycle is terminal" \
  terminal-transitioned "$(jq -r .state "$recovery_sibling_record")"
if [[ -e "$recovery_pointer" ]]; then
  fail "TC-TURNLIMIT-113 recovery pointer is consumed"
else
  pass "TC-TURNLIMIT-113 recovery pointer is consumed"
fi

if declare -F _turn_review_post_fanout_decision >/dev/null 2>&1; then
  RESULT_PARSED=false
  _turn_review_post_fanout_decision 0
  decision_continue_rc=$?
  decision_continue_parsed="$RESULT_PARSED"

  RESULT_PARSED=false
  _turn_review_post_fanout_decision "$TURN_CONTROL_REVIEW_ROUTED_RC"
  decision_routed_rc=$?
  decision_routed_parsed="$RESULT_PARSED"

  RESULT_PARSED=false
  _turn_review_post_fanout_decision "$TURN_CONTROL_REVIEW_REFUSED_RC"
  decision_refused_rc=$?
  decision_refused_parsed="$RESULT_PARSED"

  RESULT_PARSED=false
  _turn_review_post_fanout_decision "$TURN_CONTROL_ERROR_RC"
  decision_error_rc=$?
  decision_error_parsed="$RESULT_PARSED"
else
  decision_continue_rc=1
  decision_continue_parsed=true
  decision_routed_rc=1
  decision_routed_parsed=false
  decision_refused_rc=0
  decision_refused_parsed=false
  decision_error_rc=0
  decision_error_parsed=false
fi
assert_eq "TC-TURNLIMIT-090 wrapper rc 0 returns continue sentinel" 2 \
  "$decision_continue_rc"
assert_eq "TC-TURNLIMIT-090 wrapper rc 0 leaves aggregation open" false \
  "$decision_continue_parsed"
assert_eq "TC-TURNLIMIT-090 wrapper rc 10 exits successfully" 0 \
  "$decision_routed_rc"
assert_eq "TC-TURNLIMIT-090 wrapper rc 10 closes aggregation" true \
  "$decision_routed_parsed"
assert_eq "TC-TURNLIMIT-090 wrapper rc 11 exits with failure" 1 \
  "$decision_refused_rc"
assert_eq "TC-TURNLIMIT-090 wrapper rc 11 closes aggregation" true \
  "$decision_refused_parsed"
assert_eq "TC-TURNLIMIT-090 wrapper control error exits with failure" 1 \
  "$decision_error_rc"
assert_eq "TC-TURNLIMIT-090 wrapper control error closes aggregation" true \
  "$decision_error_parsed"

review_budget_helper="$(
  awk '
    /^_token_review_evaluate_members_once\(\)/ { capture = 1 }
    capture { print }
    capture && /^}/ { exit }
  ' "$REVIEW_WRAPPER"
)"
review_member_budget_calls=0
token_budget_evaluate_review_members() {
  review_member_budget_calls=$((review_member_budget_calls + 1))
  return 10
}
TOKEN_REVIEW_MEMBER_BUDGET_EVALUATED=false
TOKEN_REVIEW_MEMBER_BUDGET_RC=0
if [[ -n "$review_budget_helper" ]]; then
  eval "$review_budget_helper"
  _token_review_evaluate_members_once
  review_member_budget_first_rc=$?
  _token_review_evaluate_members_once
  review_member_budget_second_rc=$?
else
  review_member_budget_first_rc=1
  review_member_budget_second_rc=1
fi
assert_eq "TC-TURNLIMIT-109 partial refusal evaluates prior member budgets" 10 \
  "$review_member_budget_first_rc"
assert_eq "TC-TURNLIMIT-109 repeated routing preserves the member-budget result" 10 \
  "$review_member_budget_second_rc"
assert_eq "TC-TURNLIMIT-109 member budgets are evaluated once" 1 \
  "$review_member_budget_calls"

timeout_ids=(inv-v1-timeout-accounting)
timeout_logs=("$WORK/timeout-accounting.log")
timeout_states=(timed-out)
timeout_results=()
token_accounting_commit() {
  printf '{"state":"usage-unknown","reason":"member-dropped","commit_failed":true}\n'
}
_turn_control_commit_review_results \
  507 timeout_ids timeout_logs timeout_states timeout_results
timeout_accounting_fail_rc=$?
eval "$token_accounting_commit_mock_definition"
assert_eq "TC-TURNLIMIT-089 hard timeout accounting failure is loud" 1 \
  "$timeout_accounting_fail_rc"

echo "== TC-TURNLIMIT-080: unpublished and concurrent caps route once =="
unpublished_trip="$RUN_DIR/turn-control/unpublished-trip.json"
TURN_CONTROL_FILE=""
TURN_CONTROL_FANOUT_TRIP_FILE="$unpublished_trip"
turn_control_init 507 review E2E-UNPUBLISHED \
  inv-v1-979797979797979797979797 member-unpublished synthetic fixture 1 hard
turn_control_request_stop turn-cap
unpublished_record="$TURN_CONTROL_FILE"
UNPUBLISHED_RECORDS=("$unpublished_record")
UNPUBLISHED_IDS=(inv-v1-979797979797979797979797)
UNPUBLISHED_LOGS=("$WORK/unpublished.log")
UNPUBLISHED_RESULTS=()
: >"$intent_log"
: >"$transition_log"
: >"$wrapper_accounting_log"
turn_control_route_review \
  507 "$unpublished_trip" \
  UNPUBLISHED_RECORDS UNPUBLISHED_IDS UNPUBLISHED_LOGS UNPUBLISHED_RESULTS
unpublished_rc=$?
assert_eq "TC-TURNLIMIT-080 unpublished cap routes successfully" 0 \
  "$unpublished_rc"
assert_eq "TC-TURNLIMIT-080 unpublished cap writes one intent" 1 \
  "$(wc -l <"$intent_log" | tr -d ' ')"
assert_eq "TC-TURNLIMIT-080 unpublished cap performs one stalled transition" 1 \
  "$(wc -l <"$transition_log" | tr -d ' ')"
assert_eq "TC-TURNLIMIT-080 unpublished cap reaches terminal state" \
  terminal-transitioned "$(jq -r .state "$unpublished_record")"

concurrent_trip="$RUN_DIR/turn-control/fanout-trip.json"
rm -f "$concurrent_trip" "${concurrent_trip}.lock"
TURN_CONTROL_FILE=""
turn_control_init 507 review E2E-CONCURRENT-CAPS \
  inv-v1-969696969696969696969696 member-cap-a synthetic fixture 1 hard
turn_control_request_stop turn-cap
_turn_fanout_trip_write
concurrent_cap_a="$TURN_CONTROL_FILE"

TURN_CONTROL_FILE=""
turn_control_init 507 review E2E-CONCURRENT-CAPS \
  inv-v1-959595959595959595959595 member-cap-b synthetic fixture 1 hard
turn_control_request_stop turn-cap
concurrent_cap_b="$TURN_CONTROL_FILE"

CONCURRENT_RECORDS=("$concurrent_cap_a" "$concurrent_cap_b")
CONCURRENT_IDS=(
  inv-v1-969696969696969696969696
  inv-v1-959595959595959595959595
)
CONCURRENT_LOGS=("$WORK/concurrent-a.log" "$WORK/concurrent-b.log")
CONCURRENT_RESULTS=()
: >"$intent_log"
: >"$transition_log"
: >"$wrapper_accounting_log"
turn_control_route_review_fanout \
  507 "$concurrent_trip" CONCURRENT_RECORDS CONCURRENT_IDS \
  CONCURRENT_LOGS CONCURRENT_RESULTS
concurrent_rc=$?
assert_eq "TC-TURNLIMIT-080 concurrent caps route successfully" 0 \
  "$concurrent_rc"
assert_eq "TC-TURNLIMIT-080 concurrent caps write one trigger intent" 1 \
  "$(wc -l <"$intent_log" | tr -d ' ')"
assert_eq "TC-TURNLIMIT-080 concurrent caps perform one stalled transition" 1 \
  "$(wc -l <"$transition_log" | tr -d ' ')"
assert_eq "TC-TURNLIMIT-080 selected cap reaches terminal state" \
  terminal-transitioned "$(jq -r .state "$concurrent_cap_a")"
assert_eq "TC-TURNLIMIT-080 racing cap reaches terminal state" \
  terminal-transitioned "$(jq -r .state "$concurrent_cap_b")"
eval "$token_accounting_commit_definition"

echo "== TC-TURNLIMIT-048..050: usage preservation and fallback reasons =="
usage_log="$WORK/accounting-usage"
: > "$usage_log"
metrics_parse_tokens() {
  printf 'input_tokens=8 output_tokens=5 total_tokens=13\n'
}
accounting_commit_usage() {
  printf '%s|%s|%s|%s|%s\n' "$@" >> "$usage_log"
}
parseable_result="$(token_accounting_commit 507 \
  inv-v1-eeeeeeeeeeeeeeeeeeeeeeee "$WORK/parseable-usage" 0 "" turn-cap)"
assert_eq "TC-TURNLIMIT-048 parseable turn-cap usage commits normally" \
  usage-committed "$(jq -r .state <<<"$parseable_result")"
assert_eq "TC-TURNLIMIT-048 parseable usage preserves total and components" \
  "507|inv-v1-eeeeeeeeeeeeeeeeeeeeeeee|13|8|5" "$(cat "$usage_log")"

unknown_log="$WORK/accounting-unknown"
: > "$unknown_log"
metrics_parse_tokens() { return 1; }
accounting_commit_unknown() {
  printf '%s|%s|%s\n' "$@" >> "$unknown_log"
}
trigger_result="$(token_accounting_commit 507 \
  inv-v1-eeeeeeeeeeeeeeeeeeeeeeee "$WORK/no-usage-trigger" 0 "" turn-cap)"
sibling_result="$(token_accounting_commit 507 \
  inv-v1-ffffffffffffffffffffffff "$WORK/no-usage-sibling" 0 "" fanout-cancelled)"
assert_eq "TC-TURNLIMIT-049 trigger commits turn-cap unknown" turn-cap \
  "$(jq -r .reason <<<"$trigger_result")"
assert_eq "TC-TURNLIMIT-050 sibling commits fanout-cancelled unknown" fanout-cancelled \
  "$(jq -r .reason <<<"$sibling_result")"
assert_eq "TC-TURNLIMIT-049/050 unknown commits occur exactly once each" 2 \
  "$(wc -l < "$unknown_log" | tr -d ' ')"

echo "== TC-TURNLIMIT-105/112: hermetic production review wrapper =="
wrapper_root="$WORK/review-wrapper"
wrapper_scripts="$wrapper_root/scripts"
wrapper_bin="$wrapper_root/bin"
wrapper_providers="$wrapper_root/providers"
wrapper_provider_state="$wrapper_root/provider-state"
wrapper_run_base="$wrapper_root/run-state"
wrapper_accounting="$wrapper_root/accounting"
wrapper_pid_dir="$wrapper_root/pids"
wrapper_lane_state="$wrapper_root/lanes"
mkdir -p "$wrapper_scripts" "$wrapper_bin" "$wrapper_providers" \
  "$wrapper_provider_state" "$wrapper_run_base" "$wrapper_accounting" \
  "$wrapper_pid_dir" "$wrapper_lane_state"
cp -a "$SCRIPTS/." "$wrapper_scripts/"
cp "$SCRIPTS/providers/chp-github.caps" "$wrapper_providers/chp-github.caps"
cp "$SCRIPTS/providers/itp-github.caps" "$wrapper_providers/itp-github.caps"

cat >"$wrapper_providers/chp-github.sh" <<'EOF'
#!/bin/bash

_turn_wrapper_chp_action() {
  printf '%s\n' "$*" >>"$TURN_WRAPPER_PROVIDER_STATE/chp-actions"
}

chp_github_find_pr_for_issue() {
  printf '%s\n' \
    '[{"number":42,"closingIssueNumbers":[507],"headRefName":"feat/issue-507-turn-limit-control"}]'
}

chp_github_pr_view() {
  case "${2:-}" in
    headRefName) printf '%s\n' '{"headRefName":"feat/issue-507-turn-limit-control"}' ;;
    headRefOid) printf '%s\n' '{"headRefOid":"5075075075075075075075075075075075075075"}' ;;
    state) printf '%s\n' '{"state":"OPEN"}' ;;
    *) printf '%s\n' '{}' ;;
  esac
}

chp_github_pr_diffstat() { printf '%s\n' '{}'; }
chp_github_ci_status() { printf '%s\n' green; }
chp_github_ci_rollup() { printf '%s\n' '{"state":"SUCCESS","head":"5075075075075075075075075075075075075075"}'; }
chp_github_mergeable() { printf '%s\n' MERGEABLE; }
chp_github_close_keyword() { printf '%s\n' 'Closes'; }
chp_github_approve() { _turn_wrapper_chp_action approve; }
chp_github_request_changes() { _turn_wrapper_chp_action request-changes; }
chp_github_merge() { _turn_wrapper_chp_action merge; }
chp_github_pr_comment() { _turn_wrapper_chp_action pr-comment; }
chp_github_trigger_bot() { _turn_wrapper_chp_action trigger-bot; }
EOF

cat >"$wrapper_providers/itp-github.sh" <<'EOF'
#!/bin/bash

_turn_wrapper_comments_file() {
  printf '%s/comments.jsonl\n' "$TURN_WRAPPER_PROVIDER_STATE"
}

itp_github_list_comments() {
  local file
  file="$(_turn_wrapper_comments_file)"
  if [[ -s "$file" ]]; then
    jq -s '.' "$file"
  else
    printf '%s\n' '[]'
  fi
}

itp_github_post_comment() {
  local issue="$1" body="$2" file lock fd id
  file="$(_turn_wrapper_comments_file)"
  lock="${file}.lock"
  exec {fd}>>"$lock"
  flock "$fd"
  id=$(( $(wc -l <"$file" 2>/dev/null || printf '0') + 1 ))
  jq -cn \
    --argjson id "$id" \
    --arg body "$body" \
    --arg ts "2026-07-19T00:00:$(printf '%02d' "$id")Z" \
    '{id:$id,author:"turn-wrapper[bot]",authorKind:"self",body:$body,createdAt:$ts}' \
    >>"$file"
  flock -u "$fd"
  exec {fd}>&-
}

itp_github_read_task() {
  case ",${2:-}," in
    *,labels,*) printf '%s\n' "{\"labels\":[\"$(cat "$TURN_WRAPPER_PROVIDER_STATE/label")\"]}" ;;
    *,author,*) printf '%s\n' '{"author":"fixture-owner"}' ;;
    *) printf '%s\n' '{"title":"turn wrapper fixture","body":"","state":"OPEN","labels":["reviewing"]}' ;;
  esac
}

itp_github_transition_state() {
  local issue="$1" remove="$2" add="$3"
  printf '%s|%s|%s\n' "$issue" "$remove" "$add" \
    >>"$TURN_WRAPPER_PROVIDER_STATE/transitions"
  [[ -z "$add" ]] || printf '%s\n' "$add" >"$TURN_WRAPPER_PROVIDER_STATE/label"
}

itp_github_mark_checkbox() { return 0; }
itp_github_edit_comment() { return 0; }
itp_github_provision_states() { return 0; }
itp_github_begin_tick() { return 0; }
itp_github_label_event_ts() { return 0; }
EOF

chmod +x "$wrapper_providers/chp-github.sh" \
  "$wrapper_providers/itp-github.sh"
printf '%s\n' reviewing >"$wrapper_provider_state/label"
: >"$wrapper_provider_state/chp-actions"
: >"$wrapper_provider_state/transitions"

wrapper_probe_calls="$wrapper_root/claude-probe-calls"
cat >"$wrapper_bin/claude-version-probe" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >>"$TURN_WRAPPER_PROBE_CALLS"
printf '%s\n' 'Claude Code 2.1.215'
EOF
chmod +x "$wrapper_bin/claude-version-probe"

write_wrapper_config() {
  local adapter="$1" agents="$2" mode="$3" run_id="$4"
  cat >"$wrapper_scripts/autonomous.conf" <<EOF
PROJECT_ID="turn-limit-wrapper-e2e"
REPO="zxkane/autonomous-dev-team"
REPO_OWNER="zxkane"
REPO_NAME="autonomous-dev-team"
PROJECT_DIR="$PROJECT_ROOT"
AGENT_CMD="$adapter"
AGENT_REVIEW_CMD="$adapter"
AGENT_REVIEW_AGENTS="$agents"
AGENT_REVIEW_MODEL=""
AGENT_REVIEW_EXTRA_ARGS=""
AGENT_TIMEOUT="20"
AGENT_REVIEW_TIMEOUT="20"
AGENT_REVIEW_TURN_LIMIT="1"
TURN_LIMIT_MODE="$mode"
REVIEW_BOTS=""
REVIEW_SMOKE_ENABLED="false"
E2E_MODE="none"
GH_AUTH_MODE="token"
AUTONOMOUS_PROVIDERS_DIR="$wrapper_providers"
AUTONOMOUS_RUN_DIR_BASE="$wrapper_run_base"
AUTONOMOUS_ACCOUNTING_DIR="$wrapper_accounting"
AUTONOMOUS_PID_DIR="$wrapper_pid_dir"
ADT_STATE_ROOT="$wrapper_lane_state"
RUN_ID="$run_id"
HEARTBEAT_INTERVAL_SECONDS="0"
TURN_CONTROL_POLL_SECONDS="0.05"
_AGENT_WATCHDOG_GRACE_SECS="1"
VERDICT_ARTIFACT_OBSERVE_TIMEOUT_SECONDS="30"
TURN_WRAPPER_PROVIDER_STATE="$wrapper_provider_state"
TURN_WRAPPER_PROBE_CALLS="$wrapper_probe_calls"
AGENT_REVIEW_LAUNCHER_CLAUDE="$wrapper_bin/claude-version-probe"
EOF
}

write_wrapper_config claude claude warn turn-wrapper-probe
: >"$wrapper_probe_calls"
timeout 30 env \
  PATH="$wrapper_bin:$PATH" \
  GH_TOKEN=turn-wrapper-fixture-token \
  TURN_WRAPPER_PROBE_CALLS="$wrapper_probe_calls" \
  bash "$wrapper_scripts/autonomous-review.sh" \
    --issue 507 --validate-config-only \
    >"$wrapper_root/probe.out" 2>&1
wrapper_probe_rc=$?
assert_eq "TC-TURNLIMIT-105 real review wrapper accepts per-agent Claude probe" \
  0 "$wrapper_probe_rc"
assert_eq "TC-TURNLIMIT-105 AGENT_REVIEW_LAUNCHER_CLAUDE receives --version" \
  "--version" "$(cat "$wrapper_probe_calls" 2>/dev/null)"

# The production library must reject synthetic. This override is appended only
# to the copied hermetic tree so the real wrapper can exercise its hard path.
cat >>"$wrapper_scripts/lib-turn-limit.sh" <<'EOF'

turn_limit_validate_launches() {
  (( $# >= 3 )) || return 1
  local adapter="$1" side="$2" lane mode
  shift 2
  TURN_LIMIT_ADAPTER_VERSION=""
  turn_limit_validate_config "$side" || return 1
  turn_limit_enabled "$side" || return 0
  mode="$(turn_limit_effective_mode "$side")" || return 1
  [[ "$adapter" == "synthetic" && "$mode" == "hard" ]] || return 1
  for lane in "$@"; do
    [[ "$lane" == "review-member" ]] || return 1
  done
  TURN_LIMIT_ADAPTER_VERSION="fixture"
  return 0
}
EOF

wrapper_launch_state="$wrapper_root/synthetic-launch-count"
wrapper_launch_log="$wrapper_root/synthetic-launches"
wrapper_sibling_ready="$wrapper_root/sibling-ready"
wrapper_uuid_state="$wrapper_root/uuid-count"
wrapper_run_dir="$wrapper_run_base/runs/turn-wrapper-hard"
: >"$wrapper_launch_log"

cat >"$wrapper_bin/synthetic" <<EOF
#!/bin/bash
set -uo pipefail
exec 9>>"$wrapper_launch_state.lock"
flock 9
launch_n=\$(cat "$wrapper_launch_state" 2>/dev/null || printf '0')
launch_n=\$((launch_n + 1))
printf '%s\n' "\$launch_n" >"$wrapper_launch_state"
printf '%s|%s|%s\n' "\$launch_n" "\$TURN_CONTROL_FILE" "\$\$" >>"$wrapper_launch_log"
flock -u 9
exec 9>&-

case "\$launch_n" in
  1)
    printf '%s\n' "\$\$" >"$wrapper_sibling_ready"
    while :; do sleep 1; done
    ;;
  2)
    export SYNTHETIC_ADMISSION_LOG="$wrapper_root/trigger-admissions"
    export SYNTHETIC_WAIT_AFTER_DENY=true
    exec bash "$FIXTURE"
    ;;
  *)
    touch "$wrapper_root/unexpected-later-launch"
    exit 0
    ;;
esac
EOF
chmod +x "$wrapper_bin/synthetic"

cat >"$wrapper_bin/uuidgen" <<EOF
#!/bin/bash
set -uo pipefail
exec 9>>"$wrapper_uuid_state.lock"
flock 9
uuid_n=\$(cat "$wrapper_uuid_state" 2>/dev/null || printf '0')
uuid_n=\$((uuid_n + 1))
printf '%s\n' "\$uuid_n" >"$wrapper_uuid_state"
flock -u 9
exec 9>&-
case "\$uuid_n" in
  1) printf '%s\n' '11111111-1111-4111-8111-111111111111' ;;
  2) printf '%s\n' '22222222-2222-4222-8222-222222222222' ;;
  *)
    for _wait in \$(seq 1 200); do
      [[ -s "$wrapper_run_dir/turn-control/fanout-trip.json" ]] && break
      sleep 0.05
    done
    printf '%s\n' '33333333-3333-4333-8333-333333333333'
    ;;
esac
EOF
chmod +x "$wrapper_bin/uuidgen"

write_wrapper_config synthetic "synthetic synthetic synthetic" hard turn-wrapper-hard
cat >>"$wrapper_scripts/autonomous.conf" <<EOF
TURN_LIMIT_LIB="$wrapper_scripts/lib-turn-limit.sh"
EOF

timeout 45 env \
  PATH="$wrapper_bin:$PATH" \
  GH_TOKEN=turn-wrapper-fixture-token \
  TURN_LIMIT_LIB="$wrapper_scripts/lib-turn-limit.sh" \
  bash "$wrapper_scripts/autonomous-review.sh" --issue 507 \
    >"$wrapper_root/hard.out" 2>&1
wrapper_hard_rc=$?
assert_eq "TC-TURNLIMIT-112 real review wrapper routes the hard trip" \
  0 "$wrapper_hard_rc"
assert_eq "TC-TURNLIMIT-112 only the active sibling and trigger spawn" \
  2 "$(wc -l <"$wrapper_launch_log" | tr -d ' ')"
if [[ -e "$wrapper_root/unexpected-later-launch" ]]; then
  fail "TC-TURNLIMIT-112 later review member launch is suppressed"
else
  pass "TC-TURNLIMIT-112 later review member launch is suppressed"
fi

wrapper_sibling_record="$(sed -n '1s/^[^|]*|\([^|]*\)|.*$/\1/p' "$wrapper_launch_log")"
wrapper_trigger_record="$(sed -n '2s/^[^|]*|\([^|]*\)|.*$/\1/p' "$wrapper_launch_log")"
assert_eq "TC-TURNLIMIT-112 active sibling wins fanout-cancel" fanout-cancel \
  "$(jq -r .winner "$wrapper_sibling_record" 2>/dev/null)"
assert_eq "TC-TURNLIMIT-112 triggering member keeps turn-cap" turn-cap \
  "$(jq -r .winner "$wrapper_trigger_record" 2>/dev/null)"
assert_eq "TC-TURNLIMIT-112 active sibling records cancellation evidence" 1 \
  "$(jq '[.evidence[] | select(.action == "cancelled-sibling")] | length' \
    "$wrapper_sibling_record" 2>/dev/null)"
assert_eq "TC-TURNLIMIT-112 triggering member reaches terminal lifecycle" \
  terminal-transitioned "$(jq -r .state "$wrapper_trigger_record" 2>/dev/null)"

wrapper_sibling_invocation="$(jq -r .invocation_id "$wrapper_sibling_record" 2>/dev/null)"
wrapper_trigger_invocation="$(jq -r .invocation_id "$wrapper_trigger_record" 2>/dev/null)"
assert_eq "TC-TURNLIMIT-112 sibling missing usage is preserved as cancelled" \
  fanout-cancelled \
  "$(jq -r .reason "$wrapper_accounting/507/${wrapper_sibling_invocation}.json" 2>/dev/null)"
assert_eq "TC-TURNLIMIT-112 trigger missing usage is preserved as turn-cap" \
  turn-cap \
  "$(jq -r .reason "$wrapper_accounting/507/${wrapper_trigger_invocation}.json" 2>/dev/null)"

wrapper_sibling_pid="$(cat "$wrapper_sibling_ready" 2>/dev/null || true)"
if [[ "$wrapper_sibling_pid" =~ ^[1-9][0-9]*$ ]] \
    && ! kill -0 "$wrapper_sibling_pid" 2>/dev/null; then
  pass "TC-TURNLIMIT-112 sibling exits through its own watchdog"
else
  fail "TC-TURNLIMIT-112 sibling exits through its own watchdog"
fi
if pgrep -f "$wrapper_bin/synthetic" >/dev/null 2>&1; then
  fail "TC-TURNLIMIT-112 synthetic fan-out leaves no descendants"
else
  pass "TC-TURNLIMIT-112 synthetic fan-out leaves no descendants"
fi

assert_eq "TC-TURNLIMIT-112 one stalled transition is emitted" \
  "507|reviewing|stalled" "$(cat "$wrapper_provider_state/transitions")"
assert_eq "TC-TURNLIMIT-112 one turn-cap intent is written" 1 \
  "$(jq -s '[.[] | select(.body | startswith("<!-- resource-terminal-intent-v1:"))
                  | select(.body | contains(" reason=turn-cap owner=review-wrapper "))] | length' \
    "$wrapper_provider_state/comments.jsonl" 2>/dev/null)"
assert_eq "TC-TURNLIMIT-112 one turn-cap intent is consumed" 1 \
  "$(jq -s '[.[] | select(.body | startswith("<!-- resource-terminal-intent-consume-v1:"))] | length' \
    "$wrapper_provider_state/comments.jsonl" 2>/dev/null)"
if grep -q 'Per-agent verdicts:' "$wrapper_root/hard.out" \
    || grep -Eq '^(approve|merge)$' "$wrapper_provider_state/chp-actions"; then
  fail "TC-TURNLIMIT-112 trip bypasses PASS aggregation, approval, and merge"
else
  pass "TC-TURNLIMIT-112 trip bypasses PASS aggregation, approval, and merge"
fi

echo "== TC-TURNLIMIT-066/067: unsupported launch refusal =="
reset_launch_config() {
  unset AGENT_DEV_TURN_LIMIT AGENT_REVIEW_TURN_LIMIT AGENT_TURN_LIMIT TURN_LIMIT_MODE
}
reset_launch_config
AGENT_DEV_TURN_LIMIT=1
TURN_LIMIT_MODE=hard
sentinel="$WORK/production-launched"
if turn_limit_validate_launch claude dev dev-new >/dev/null 2>&1; then
  touch "$sentinel"
fi
if [[ ! -e "$sentinel" ]]; then
  pass "TC-TURNLIMIT-066 production hard refuses before launch"
else
  fail "TC-TURNLIMIT-066 production hard refuses before launch"
fi

claude() {
  printf '%s\n' "${SYNTHETIC_CLAUDE_VERSION_OUTPUT:-unparseable}"
}
reset_launch_config
AGENT_DEV_TURN_LIMIT=1
TURN_LIMIT_MODE=warn
SYNTHETIC_CLAUDE_VERSION_OUTPUT="2.1.215 (Claude Code)"
export SYNTHETIC_CLAUDE_VERSION_OUTPUT
assert_eq "TC-TURNLIMIT-067 Claude warn probe accepts the pinned version" \
  0 "$(turn_limit_validate_launch claude dev dev-new >/dev/null 2>&1; echo "$?")"
SYNTHETIC_CLAUDE_VERSION_OUTPUT="not-a-version"
export SYNTHETIC_CLAUDE_VERSION_OUTPUT
sentinel="$WORK/claude-warn-launched"
if turn_limit_validate_launch claude dev dev-new >/dev/null 2>&1; then
  touch "$sentinel"
fi
if [[ ! -e "$sentinel" ]]; then
  pass "TC-TURNLIMIT-067 failed Claude warn probe refuses before launch"
else
  fail "TC-TURNLIMIT-067 failed Claude warn probe refuses before launch"
fi

printf 'TURN-LIMIT-E2E-SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
