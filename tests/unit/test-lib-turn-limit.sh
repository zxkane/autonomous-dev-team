#!/bin/bash
# Unit tests for issue #507 / INV-142 turn-limit control.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-turn-limit.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
SPEC="$PROJECT_ROOT/docs/pipeline/adapter-spec.md"
DESIGN="$PROJECT_ROOT/docs/designs/turn-limit-control.md"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail "$desc (expected='$expected' actual='$actual')"
  fi
}
assert_contains() {
  local desc="$1" needle="$2" actual="$3"
  if [[ "$actual" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc (missing='$needle')"
  fi
}
assert_rc() { assert_eq "$1" "$2" "$3"; }
run_rc() {
  "$@" >"$WORK/out" 2>"$WORK/err"
  printf '%s' "$?"
}

if [[ ! -r "$LIB" ]]; then
  fail "TC-TURNLIMIT-010 lib-turn-limit.sh exists"
  printf 'TURN-LIMIT-UNIT-SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
  exit 1
fi

# shellcheck source=/dev/null
source "$LIB"
set +e

reset_config() {
  unset AGENT_DEV_TURN_LIMIT AGENT_REVIEW_TURN_LIMIT AGENT_TURN_LIMIT
  unset TURN_LIMIT_MODE
}

echo "== TC-TURNLIMIT-001..010: configuration =="
reset_config
assert_rc "TC-TURNLIMIT-009 unset dev validates" 0 \
  "$(run_rc turn_limit_validate_config dev)"
assert_rc "TC-TURNLIMIT-009 unset dev is disabled" 1 \
  "$(run_rc turn_limit_enabled dev)"
assert_eq "TC-TURNLIMIT-009 disabled mode token" disabled \
  "$(turn_limit_effective_mode dev)"

AGENT_TURN_LIMIT=7
assert_eq "TC-TURNLIMIT-003 dev uses fallback" 7 \
  "$(turn_limit_effective_limit dev)"
assert_eq "TC-TURNLIMIT-003 review uses fallback" 7 \
  "$(turn_limit_effective_limit review)"
assert_eq "TC-TURNLIMIT-007 mode defaults to warn" warn \
  "$(turn_limit_effective_mode dev)"

AGENT_DEV_TURN_LIMIT=3
AGENT_REVIEW_TURN_LIMIT=5
assert_eq "TC-TURNLIMIT-001 dev side-specific wins" 3 \
  "$(turn_limit_effective_limit dev)"
assert_eq "TC-TURNLIMIT-002 review side-specific wins" 5 \
  "$(turn_limit_effective_limit review)"

AGENT_DEV_TURN_LIMIT=
assert_rc "TC-TURNLIMIT-004 explicit-empty dev refuses" 1 \
  "$(run_rc turn_limit_validate_config dev)"
assert_contains "TC-TURNLIMIT-004 diagnostic names dev variable" \
  "AGENT_DEV_TURN_LIMIT=''" "$(cat "$WORK/err")"

for bad in 0 -1 +1 01 1.5 abc ' 1'; do
  reset_config
  AGENT_REVIEW_TURN_LIMIT="$bad"
  assert_rc "TC-TURNLIMIT-005 bad review '$bad' refuses" 1 \
    "$(run_rc turn_limit_validate_config review)"
  assert_contains "TC-TURNLIMIT-005 diagnostic names value '$bad'" \
    "AGENT_REVIEW_TURN_LIMIT='$bad'" "$(cat "$WORK/err")"
done

reset_config
AGENT_TURN_LIMIT=bad
AGENT_DEV_TURN_LIMIT=4
assert_rc "TC-TURNLIMIT-006 invalid fallback shadowed for dev" 0 \
  "$(run_rc turn_limit_validate_config dev)"
assert_rc "TC-TURNLIMIT-006 invalid fallback remains effective for review" 1 \
  "$(run_rc turn_limit_validate_config review)"

reset_config
TURN_LIMIT_MODE=stop
assert_rc "TC-TURNLIMIT-008 invalid mode refuses while disabled" 1 \
  "$(run_rc turn_limit_validate_config dev)"
assert_contains "TC-TURNLIMIT-008 diagnostic names mode value" \
  "TURN_LIMIT_MODE='stop'" "$(cat "$WORK/err")"

SOURCE_ROOT="$WORK/source-side-effect"
source_out="$(
  RUN_DIR="$SOURCE_ROOT/run" AUTONOMOUS_ACCOUNTING_DIR="$SOURCE_ROOT/accounting" \
    bash -c 'source "$1"' _ "$LIB" 2>&1
)"
assert_eq "TC-TURNLIMIT-010 source emits no output" "" "$source_out"
if [[ ! -e "$SOURCE_ROOT" ]]; then
  pass "TC-TURNLIMIT-010 source performs no filesystem I/O"
else
  fail "TC-TURNLIMIT-010 source performs no filesystem I/O"
fi

echo "== TC-TURNLIMIT-011..020: capability and version probe =="
production=(claude codex kiro agy gemini opencode generic)
lanes=(dev-new dev-resume review-member)
for adapter in "${production[@]}"; do
  for lane in "${lanes[@]}"; do
    for mode in warn hard; do
      expected=1
      [[ "$adapter" == claude && "$mode" == warn ]] && expected=0
      assert_rc "TC-TURNLIMIT-011 $adapter/$lane/$mode matrix" "$expected" \
        "$(run_rc turn_capability "$adapter" "$lane" "$mode")"
    done
  done
done
for lane in "${lanes[@]}"; do
  assert_rc "TC-TURNLIMIT-012 synthetic/$lane/warn" 0 \
    "$(run_rc turn_capability synthetic "$lane" warn)"
  assert_rc "TC-TURNLIMIT-012 synthetic/$lane/hard" 0 \
    "$(run_rc turn_capability synthetic "$lane" hard)"
done
assert_rc "TC-TURNLIMIT-013 unknown adapter unsupported" 1 \
  "$(run_rc turn_capability future dev-new warn)"
assert_rc "TC-TURNLIMIT-013 unknown lane unsupported" 1 \
  "$(run_rc turn_capability claude browser-e2e warn)"
assert_rc "TC-TURNLIMIT-013 unknown mode unsupported" 1 \
  "$(run_rc turn_capability claude dev-new soft)"

assert_eq "TC-TURNLIMIT-015 normalize pinned version" 2.1.215 \
  "$(turn_claude_version_normalize "$(cat "$FIXTURES/claude-version-min.txt")")"
assert_eq "TC-TURNLIMIT-016 normalize newer version" 2.2.0 \
  "$(turn_claude_version_normalize "$(cat "$FIXTURES/claude-version-newer.txt")")"
assert_eq "TC-TURNLIMIT-018 reject unparseable version" "" \
  "$(turn_claude_version_normalize "$(cat "$FIXTURES/claude-version-unparseable.txt")")"
assert_rc "TC-TURNLIMIT-015 pinned version supported" 0 \
  "$(run_rc turn_claude_version_supported "$(cat "$FIXTURES/claude-version-min.txt")")"
assert_rc "TC-TURNLIMIT-016 newer version supported" 0 \
  "$(run_rc turn_claude_version_supported "$(cat "$FIXTURES/claude-version-newer.txt")")"
assert_rc "TC-TURNLIMIT-017 below-minimum refused" 1 \
  "$(run_rc turn_claude_version_supported "$(cat "$FIXTURES/claude-version-below.txt")")"
assert_rc "TC-TURNLIMIT-018 unparseable refused" 1 \
  "$(run_rc turn_claude_version_supported "$(cat "$FIXTURES/claude-version-unparseable.txt")")"

probe_dir="$WORK/probe-bin"
mkdir -p "$probe_dir"
printf '%s\n' '#!/bin/sh' 'exit 7' >"$probe_dir/claude"
chmod +x "$probe_dir/claude"
assert_rc "TC-TURNLIMIT-017 nonzero Claude probe refuses" 1 \
  "$(PATH="$probe_dir:$PATH" run_rc turn_claude_version_probe)"
printf '%s\n' '#!/bin/sh' 'printf "Claude Code 2.1.214\n"' >"$probe_dir/claude"
chmod +x "$probe_dir/claude"
assert_rc "TC-TURNLIMIT-017 below-minimum Claude probe refuses" 1 \
  "$(PATH="$probe_dir:$PATH" run_rc turn_claude_version_probe)"
cat >"$probe_dir/claude" <<'EOF'
#!/bin/sh
printf 'probe\n' >>"$PROBE_CALLS"
printf 'Claude Code 2.1.215\n'
EOF
chmod +x "$probe_dir/claude"

reset_config
AGENT_DEV_TURN_LIMIT=2
TURN_LIMIT_MODE=hard
assert_rc "TC-TURNLIMIT-019 production hard Claude refuses" 1 \
  "$(run_rc turn_limit_validate_launch claude dev dev-new)"
assert_contains "TC-TURNLIMIT-019 refusal names adapter/lane/mode" \
  "claude" "$(cat "$WORK/err")"
assert_rc "TC-TURNLIMIT-020 environment cannot admit synthetic hard" 1 \
  "$(TURN_LIMIT_TEST_SYNTHETIC=1 run_rc turn_limit_validate_launch synthetic dev dev-new)"
assert_rc "TC-TURNLIMIT-020 production validator rejects synthetic" 1 \
  "$(run_rc turn_limit_validate_launch synthetic dev dev-new)"

TURN_LIMIT_MODE=warn
probe_calls="$WORK/probe-calls"
: >"$probe_calls"
assert_rc "TC-TURNLIMIT-019 all dev lanes validate with one version probe" 0 \
  "$(PATH="$probe_dir:$PATH" PROBE_CALLS="$probe_calls" \
    run_rc turn_limit_validate_launches claude dev dev-resume dev-new)"
assert_eq "TC-TURNLIMIT-019 wrapper-level validation probes adapter once" 1 \
  "$(wc -l <"$probe_calls" | tr -d ' ')"

launcher_probe_calls="$WORK/launcher-probe-calls"
cat >"$probe_dir/claude-launcher" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$LAUNCHER_PROBE_CALLS"
printf 'Claude Code 2.1.215\n'
EOF
chmod +x "$probe_dir/claude-launcher"
declare -a AGENT_LAUNCHER_ARGV=("$probe_dir/claude-launcher")
: >"$launcher_probe_calls"
assert_rc "TC-TURNLIMIT-105 configured Claude launcher probe succeeds" 0 \
  "$(LAUNCHER_PROBE_CALLS="$launcher_probe_calls" \
    run_rc turn_limit_validate_launches claude dev dev-new)"
assert_eq "TC-TURNLIMIT-105 launcher receives the Claude version flag" \
  "--version" "$(cat "$launcher_probe_calls")"
AGENT_LAUNCHER_ARGV=()

pinned="$(
  env TURN_CONTROL_STOP_RC=124 TURN_CONTROL_ERROR_RC=125 \
    TURN_LIMIT_CLAUDE_MIN_VERSION=0.0.1 \
    bash -c 'source "$1"; printf "%s|%s|%s" "$TURN_CONTROL_STOP_RC" "$TURN_CONTROL_ERROR_RC" "$TURN_LIMIT_CLAUDE_MIN_VERSION"' \
      _ "$LIB"
)"
assert_eq "TC-TURNLIMIT-019 safety constants ignore environment overrides" \
  "92|93|2.1.215" "$pinned"

reset_config
assert_rc "TC-TURNLIMIT-009 disabled launch performs no capability probe" 0 \
  "$(run_rc turn_limit_validate_launch claude dev dev-new)"

echo "== TC-TURNLIMIT-031: turn accounting facade =="
accounting_calls="$WORK/accounting-calls"
accounting_invocation_id() {
  [[ "${FAIL_ID:-0}" != 1 ]] || return 1
  printf 'inv-%s-%s-%s-%s\n' "$1" "$2" "$3" "$4"
}
accounting_start() {
  printf 'start|%s\n' "$*" >>"$accounting_calls"
  [[ "${FAIL_START:-0}" != 1 ]]
}

: >"$accounting_calls"
turn_warn_id="$(turn_accounting_begin 507 TURN-RUN dev dev 1 warn)"
assert_eq "TC-TURNLIMIT-031 turn facade derives a canonical warn identity" \
  inv-TURN-RUN-dev-dev-1 "$turn_warn_id"
assert_eq "TC-TURNLIMIT-031 warn turn facade does not start strict accounting" \
  "" "$(cat "$accounting_calls")"

: >"$accounting_calls"
turn_hard_id="$(turn_accounting_begin 507 TURN-RUN review MEMBER-A 1 hard)"
assert_eq "TC-TURNLIMIT-031 turn facade derives a canonical hard identity" \
  inv-TURN-RUN-review-MEMBER-A-1 "$turn_hard_id"
assert_contains "TC-TURNLIMIT-031 hard turn facade starts strict accounting" \
  "start|507 $turn_hard_id review TURN-RUN MEMBER-A 1" \
  "$(cat "$accounting_calls")"

: >"$accounting_calls"
turn_existing_id="$(turn_accounting_begin \
  507 TURN-RUN review MEMBER-A 1 hard "$turn_hard_id")"
assert_eq "TC-TURNLIMIT-031 turn facade accepts the matching existing identity" \
  "$turn_hard_id" "$turn_existing_id"
assert_contains "TC-TURNLIMIT-031 matching hard identity confirms accounting start" \
  "start|507 $turn_hard_id review TURN-RUN MEMBER-A 1" \
  "$(cat "$accounting_calls")"
assert_rc "TC-TURNLIMIT-031 turn facade rejects a mismatched existing identity" 1 \
  "$(run_rc turn_accounting_begin 507 TURN-RUN review MEMBER-A 1 hard inv-wrong)"
assert_rc "TC-TURNLIMIT-031 turn facade rejects an invalid mode" 1 \
  "$(run_rc turn_accounting_begin 507 TURN-RUN dev dev 1 stop)"
FAIL_ID=1
assert_rc "TC-TURNLIMIT-031 turn facade rejects identity derivation failure" 1 \
  "$(run_rc turn_accounting_begin 507 TURN-RUN dev dev 1 hard)"
FAIL_ID=0
FAIL_START=1
assert_rc "TC-TURNLIMIT-031 hard turn facade rejects accounting start failure" 1 \
  "$(run_rc turn_accounting_begin 507 TURN-RUN dev dev 1 hard)"
FAIL_START=0

echo "== TC-TURNLIMIT-021..039: observation and durable lifecycle =="
export RUN_DIR="$WORK/run"
TURN_CONTROL_FILE=""
turn_control_init 507 dev RUN-507 inv-v1-111111111111111111111111 dev \
  claude 2.1.215 2 warn
record_file="$TURN_CONTROL_FILE"
assert_eq "TC-TURNLIMIT-031 record path uses invocation id" \
  "$RUN_DIR/turn-control/inv-v1-111111111111111111111111.json" "$record_file"
assert_eq "TC-TURNLIMIT-031 initial state running" running \
  "$(jq -r .state "$record_file")"
assert_eq "TC-TURNLIMIT-031 initial schema version" 1 \
  "$(jq -r .schema_version "$record_file")"
assert_rc "TC-TURNLIMIT-031 exact identity can reopen its record" 0 \
  "$(run_rc turn_control_init 507 dev RUN-507 \
    inv-v1-111111111111111111111111 dev claude 2.1.215 2 warn)"
assert_rc "TC-TURNLIMIT-031 mismatched identity cannot reopen a record" 1 \
  "$(run_rc turn_control_init 507 dev RUN-507 \
    inv-v1-111111111111111111111111 dev claude 2.1.215 3 warn)"
assert_contains "TC-TURNLIMIT-031 identity mismatch is loud" \
  "identity does not match" "$(cat "$WORK/err")"
assert_eq "TC-TURNLIMIT-031 rejected reopen leaves the record unchanged" 2 \
  "$(jq -r .limit "$record_file")"

init_retry_file="$RUN_DIR/turn-control/inv-v1-121212121212121212121212.json"
sync_dir_definition="$(declare -f _turn_control_sync_dir)"
sync_dir_calls=0
_turn_control_sync_dir() {
  sync_dir_calls=$((sync_dir_calls + 1))
  if (( sync_dir_calls == 1 )); then
    return 1
  fi
  command sync -f "$1" 2>/dev/null
}
turn_control_init 507 dev RUN-507 \
  inv-v1-121212121212121212121212 dev claude 2.1.215 2 warn
init_first_rc=$?
turn_control_init 507 dev RUN-507 \
  inv-v1-121212121212121212121212 dev claude 2.1.215 2 warn
init_retry_rc=$?
eval "$sync_dir_definition"
assert_rc "TC-TURNLIMIT-100 failed initialization directory sync refuses" 1 \
  "$init_first_rc"
assert_eq "TC-TURNLIMIT-100 renamed initialization record remains visible" running \
  "$(jq -r .state "$init_retry_file")"
assert_rc "TC-TURNLIMIT-100 matching initialization retry succeeds" 0 \
  "$init_retry_rc"
assert_eq "TC-TURNLIMIT-100 reopen re-confirms initialization durability" 2 \
  "$sync_dir_calls"
TURN_CONTROL_FILE="$record_file"

invalid_record="$RUN_DIR/turn-control/invalid-envelope.json"
jq '.observed_count = -1' "$record_file" >"$invalid_record"
assert_rc "TC-TURNLIMIT-031 negative observed count is malformed" 1 \
  "$(run_rc _turn_control_load "$invalid_record")"
jq '.state = "future-state"' "$record_file" >"$invalid_record"
assert_rc "TC-TURNLIMIT-031 unknown lifecycle state is malformed" 1 \
  "$(run_rc _turn_control_load "$invalid_record")"
jq '.winner = "future-reason"' "$record_file" >"$invalid_record"
assert_rc "TC-TURNLIMIT-031 unknown winner reason is malformed" 1 \
  "$(run_rc _turn_control_load "$invalid_record")"
blocked_target="$RUN_DIR/turn-control/nonregular-target"
mkdir "$blocked_target"
assert_rc "TC-TURNLIMIT-031 atomic writer refuses non-regular target" 1 \
  "$(run_rc _turn_control_write_atomic "$blocked_target" '{}')"
if [[ -d "$blocked_target" ]]; then
  pass "TC-TURNLIMIT-031 non-regular target remains untouched"
else
  fail "TC-TURNLIMIT-031 non-regular target remains untouched"
fi

while IFS= read -r line; do
  observe_completed_turn "$line"
done < "$FIXTURES/claude-turn-stream.jsonl"
assert_eq "TC-TURNLIMIT-021..024 only assistant records count" 2 \
  "$(jq -r .observed_count "$record_file")"
assert_eq "TC-TURNLIMIT-026 warn action written once" 1 \
  "$(jq '[.evidence[] | select(.action == "warned")] | length' "$record_file")"
observe_completed_turn '{"type":"assistant","message":{"content":[]}}'
assert_eq "TC-TURNLIMIT-027 later assistants do not duplicate warned" 1 \
  "$(jq '[.evidence[] | select(.action == "warned")] | length' "$record_file")"
observe_completed_turn '{"type":"result","num_turns":1000}'
assert_eq "TC-TURNLIMIT-024 result num_turns ignored" 3 \
  "$(jq -r .observed_count "$record_file")"
observe_completed_turn '{"type":"assistant"'
assert_eq "TC-TURNLIMIT-025 malformed record ignored" 3 \
  "$(jq -r .observed_count "$record_file")"

required='["issue","side","run_id","invocation_id","member","adapter","adapter_version","observed_count","limit","mode","action","winning_reason","ts"]'
if jq -e --argjson required "$required" '
    all(.evidence[]; ($required - keys | length) == 0)
  ' "$record_file" >/dev/null; then
  pass "TC-TURNLIMIT-038 warning evidence has every required field"
else
  fail "TC-TURNLIMIT-038 warning evidence has every required field"
fi

init_hard() {
  local id="$1" side="${2:-dev}" member="${3:-dev}"
  TURN_CONTROL_FILE=""
  TURN_CONTROL_FANOUT_TRIP_FILE=""
  turn_control_init 507 "$side" RUN-507 "$id" "$member" synthetic fixture 2 hard
}

init_hard inv-v1-222222222222222222222222
observe_completed_turn '{"type":"assistant"}'
assert_rc "TC-TURNLIMIT-028 under limit admits next request" 0 \
  "$(run_rc admit_next_request)"
observe_completed_turn '{"type":"assistant"}'
assert_rc "TC-TURNLIMIT-029 equality denies N+1" 1 \
  "$(run_rc admit_next_request)"
assert_eq "TC-TURNLIMIT-029 denial winner is turn-cap" turn-cap \
  "$(turn_control_winner)"

init_hard inv-v1-232323232323232323232323
turn_control_request_stop turn-cap
sync_dir_definition="$(declare -f _turn_control_sync_dir)"
sync_dir_calls=0
_turn_control_sync_dir() {
  sync_dir_calls=$((sync_dir_calls + 1))
  if (( sync_dir_calls == 1 )); then
    return 1
  fi
  command sync -f "$1" 2>/dev/null
}
turn_control_mark_terminating
terminating_first_rc=$?
turn_control_mark_terminating
terminating_retry_rc=$?
eval "$sync_dir_definition"
assert_rc "TC-TURNLIMIT-086 failed directory sync rejects first transition" 1 \
  "$terminating_first_rc"
assert_eq "TC-TURNLIMIT-086 renamed state is visible after failed sync" terminating \
  "$(jq -r .state "$TURN_CONTROL_FILE")"
assert_rc "TC-TURNLIMIT-086 idempotent retry confirms durability" 0 \
  "$terminating_retry_rc"
assert_eq "TC-TURNLIMIT-086 retry re-syncs the visible state" 2 \
  "$sync_dir_calls"

init_hard inv-v1-242424242424242424242424
sync_dir_definition="$(declare -f _turn_control_sync_dir)"
sync_dir_calls=0
_turn_control_sync_dir() {
  sync_dir_calls=$((sync_dir_calls + 1))
  (( sync_dir_calls > 1 )) || return 1
  command sync -f "$1" 2>/dev/null
}
turn_control_request_stop turn-cap
duplicate_stop_first_rc=$?
duplicate_stop_state_after_failure="$(jq -r .state "$TURN_CONTROL_FILE")"
duplicate_stop_winner_after_failure="$(jq -r '.winner // empty' "$TURN_CONTROL_FILE")"
turn_control_request_stop turn-cap
duplicate_stop_retry_rc=$?
turn_control_request_stop turn-cap
duplicate_stop_confirm_rc=$?
eval "$sync_dir_definition"
assert_rc "TC-TURNLIMIT-103 failed stop directory sync rejects first request" 1 \
  "$duplicate_stop_first_rc"
assert_eq "TC-TURNLIMIT-102 failed stop rename restores running state" running \
  "$duplicate_stop_state_after_failure"
assert_eq "TC-TURNLIMIT-102 failed stop rename restores the empty winner" "" \
  "$duplicate_stop_winner_after_failure"
assert_rc "TC-TURNLIMIT-102 stop request retries from restored state" 0 \
  "$duplicate_stop_retry_rc"
assert_rc "TC-TURNLIMIT-103 duplicate stop request re-confirms durability" 0 \
  "$duplicate_stop_confirm_rc"
assert_eq "TC-TURNLIMIT-103 duplicate stop retry re-syncs visible state" 4 \
  "$sync_dir_calls"

init_hard inv-v1-252525252525252525252525
sync_dir_definition="$(declare -f _turn_control_sync_dir)"
sync_dir_calls=0
_turn_control_sync_dir() {
  sync_dir_calls=$((sync_dir_calls + 1))
  (( sync_dir_calls > 1 )) || return 1
  command sync -f "$1" 2>/dev/null
}
turn_control_mark_completed
duplicate_completed_first_rc=$?
turn_control_mark_completed
duplicate_completed_retry_rc=$?
eval "$sync_dir_definition"
assert_rc "TC-TURNLIMIT-103 failed completion directory sync rejects first transition" 1 \
  "$duplicate_completed_first_rc"
assert_rc "TC-TURNLIMIT-103 duplicate completion re-confirms durability" 0 \
  "$duplicate_completed_retry_rc"
assert_eq "TC-TURNLIMIT-103 duplicate completion retry re-syncs visible state" 2 \
  "$sync_dir_calls"

init_hard inv-v1-262626262626262626262626
turn_control_request_stop turn-cap
turn_control_mark_terminating
sync_dir_definition="$(declare -f _turn_control_sync_dir)"
sync_dir_calls=0
_turn_control_sync_dir() {
  sync_dir_calls=$((sync_dir_calls + 1))
  (( sync_dir_calls > 1 )) || return 1
  command sync -f "$1" 2>/dev/null
}
turn_control_mark_terminal_transitioned
duplicate_terminal_first_rc=$?
turn_control_mark_terminal_transitioned
duplicate_terminal_retry_rc=$?
eval "$sync_dir_definition"
assert_rc "TC-TURNLIMIT-103 failed terminal directory sync rejects first transition" 1 \
  "$duplicate_terminal_first_rc"
assert_rc "TC-TURNLIMIT-103 duplicate terminal transition re-confirms durability" 0 \
  "$duplicate_terminal_retry_rc"
assert_eq "TC-TURNLIMIT-103 duplicate terminal retry re-syncs visible state" 2 \
  "$sync_dir_calls"

hard_record="$TURN_CONTROL_FILE"
printf '%s\n' '{"malformed":true}' >"$invalid_record"
TURN_CONTROL_FILE="$invalid_record"
assert_rc "TC-TURNLIMIT-075 unreadable hard state denies admission" 1 \
  "$(run_rc admit_next_request)"
TURN_CONTROL_FILE="$hard_record"

large_limit=9223372036854775808
TURN_CONTROL_FILE=""
turn_control_init 507 dev RUN-507 inv-v1-343434343434343434343434 dev \
  synthetic fixture "$large_limit" hard
assert_eq "TC-TURNLIMIT-078 large valid limit remains exact in durable state" \
  "$large_limit" "$(jq -r .limit "$TURN_CONTROL_FILE")"
assert_rc "TC-TURNLIMIT-078 large valid limit admits request one" 0 \
  "$(run_rc admit_next_request)"
observe_completed_turn '{"type":"assistant"}'
assert_eq "TC-TURNLIMIT-078 decimal observation increments without overflow" 1 \
  "$(jq -r .observed_count "$TURN_CONTROL_FILE")"
assert_rc "TC-TURNLIMIT-078 large valid limit still admits after one turn" 0 \
  "$(run_rc admit_next_request)"

init_hard inv-v1-333333333333333333333333
turn_control_request_stop turn-cap
turn_control_request_stop timeout
assert_eq "TC-TURNLIMIT-032 turn-cap wins first race order" turn-cap \
  "$(turn_control_winner)"
assert_eq "TC-TURNLIMIT-032 timeout is late" timeout \
  "$(jq -r '.late[-1].reason' "$TURN_CONTROL_FILE")"

init_hard inv-v1-444444444444444444444444
turn_control_request_stop timeout
turn_control_request_stop turn-cap
assert_eq "TC-TURNLIMIT-033 timeout wins second race order" timeout \
  "$(turn_control_winner)"
assert_eq "TC-TURNLIMIT-033 turn-cap is late" turn-cap \
  "$(jq -r '.late[-1].reason' "$TURN_CONTROL_FILE")"
assert_rc "TC-TURNLIMIT-052 timeout winner writes no turn-cap intent" 0 \
  "$(run_rc turn_control_route_terminal 507 dev-wrapper)"

init_hard inv-v1-999999999999999999999998
race_record="$TURN_CONTROL_FILE"
(TURN_CONTROL_FILE="$race_record"; turn_control_request_stop turn-cap) &
race_a=$!
(TURN_CONTROL_FILE="$race_record"; turn_control_request_stop timeout) &
race_b=$!
wait "$race_a"
wait "$race_b"
race_winner="$(jq -r .winner "$race_record")"
case "$race_winner" in
  turn-cap|timeout) pass "TC-TURNLIMIT-039 concurrent race persists a valid winner" ;;
  *) fail "TC-TURNLIMIT-039 concurrent race persists a valid winner" ;;
esac
assert_eq "TC-TURNLIMIT-039 concurrent race has one winning action" 1 \
  "$(jq '[.evidence[] | select(.action == "stop-requested")] | length' "$race_record")"
assert_eq "TC-TURNLIMIT-039 concurrent race records the loser as late" 1 \
  "$(jq '.late | length' "$race_record")"
assert_eq "TC-TURNLIMIT-039 late reason differs from the winner" false \
  "$(jq '.late[0].reason == .winner' "$race_record")"

init_hard inv-v1-555555555555555555555555
turn_control_mark_completed
turn_control_request_stop turn-cap
assert_eq "TC-TURNLIMIT-034 natural completion remains terminal" completed \
  "$(jq -r .state "$TURN_CONTROL_FILE")"
assert_eq "TC-TURNLIMIT-034 late request has no winner" null \
  "$(jq -r .winner "$TURN_CONTROL_FILE")"

init_hard inv-v1-666666666666666666666666
turn_control_request_stop turn-cap
turn_control_request_stop turn-cap
assert_eq "TC-TURNLIMIT-035 duplicate action is idempotent" 1 \
  "$(jq '[.evidence[] | select(.action == "stop-requested")] | length' "$TURN_CONTROL_FILE")"
assert_rc "TC-TURNLIMIT-034 completion after a stop request is a no-op" 0 \
  "$(run_rc turn_control_mark_completed)"
assert_eq "TC-TURNLIMIT-034 completion cannot replace a stop request" stop-requested \
  "$(jq -r .state "$TURN_CONTROL_FILE")"
assert_rc "TC-TURNLIMIT-037 terminal transition cannot skip terminating" 1 \
  "$(run_rc turn_control_mark_terminal_transitioned)"
assert_eq "TC-TURNLIMIT-037 rejected lifecycle skip remains stop-requested" \
  stop-requested "$(jq -r .state "$TURN_CONTROL_FILE")"
turn_control_mark_terminating
assert_eq "TC-TURNLIMIT-036 terminating state persisted" terminating \
  "$(jq -r .state "$TURN_CONTROL_FILE")"
assert_eq "TC-TURNLIMIT-036 terminated evidence persisted" 1 \
  "$(jq '[.evidence[] | select(.action == "terminated")] | length' "$TURN_CONTROL_FILE")"
turn_control_mark_terminal_transitioned
assert_eq "TC-TURNLIMIT-037 terminal transition persisted" terminal-transitioned \
  "$(jq -r .state "$TURN_CONTROL_FILE")"
assert_rc "TC-TURNLIMIT-037 terminal invocation cannot re-enter terminating" 0 \
  "$(run_rc turn_control_mark_terminating)"

init_hard inv-v1-696969696969696969696969
turn_control_request_stop turn-cap
terminal_intent_log="$WORK/terminal-intent-calls"
: >"$terminal_intent_log"
terminal_intent_write() {
  printf '%s\n' "$*" >>"$terminal_intent_log"
}
assert_rc "TC-TURNLIMIT-098 stop-requested cap cannot route terminally" 1 \
  "$(run_rc turn_control_route_terminal 507 dev-wrapper)"
assert_eq "TC-TURNLIMIT-098 incomplete lifecycle writes no terminal intent" 0 \
  "$(wc -l <"$terminal_intent_log" | tr -d ' ')"
turn_control_mark_terminating
assert_rc "TC-TURNLIMIT-098 terminating cap can route terminally" 0 \
  "$(run_rc turn_control_route_terminal 507 dev-wrapper)"
assert_eq "TC-TURNLIMIT-098 durable terminating lifecycle writes one intent" 1 \
  "$(wc -l <"$terminal_intent_log" | tr -d ' ')"

init_hard inv-v1-777777777777777777777777 review member-a
observe_completed_turn '{"type":"assistant"}'
observe_completed_turn '{"type":"assistant"}'
admit_next_request >/dev/null 2>&1
assert_rc "TC-TURNLIMIT-053 fanout trip is active" 0 \
  "$(run_rc turn_fanout_trip_active)"
assert_eq "TC-TURNLIMIT-053 trip names trigger invocation" \
  inv-v1-777777777777777777777777 \
  "$(jq -r .invocation_id "$TURN_CONTROL_FANOUT_TRIP_FILE")"

trigger_file="$TURN_CONTROL_FILE"
trip_file="$TURN_CONTROL_FANOUT_TRIP_FILE"

TURN_CONTROL_FILE=""
TURN_CONTROL_FANOUT_TRIP_FILE=""
turn_control_init 507 review RUN-507 inv-v1-767676767676767676767676 \
  member-retry synthetic fixture 1 hard
publication_retry_trip="$RUN_DIR/turn-control/publication-retry-trip.json"
TURN_CONTROL_FANOUT_TRIP_FILE="$publication_retry_trip"
observe_completed_turn '{"type":"assistant"}'
trip_write_definition="$(declare -f _turn_fanout_trip_write)"
trip_write_original_definition="${trip_write_definition/_turn_fanout_trip_write/_turn_fanout_trip_write_original}"
eval "$trip_write_original_definition"
trip_write_calls=0
_turn_fanout_trip_write() {
  trip_write_calls=$((trip_write_calls + 1))
  (( trip_write_calls > 1 )) || return 1
  _turn_fanout_trip_write_original
}
admit_next_request >/dev/null 2>&1
publication_retry_rc=$?
eval "$trip_write_definition"
unset -f _turn_fanout_trip_write_original
assert_rc "TC-TURNLIMIT-092 admission denies after transient trip publication failure" \
  1 "$publication_retry_rc"
assert_eq "TC-TURNLIMIT-092 admission retries trip publication" 2 \
  "$trip_write_calls"
assert_rc "TC-TURNLIMIT-092 retried publication activates fanout cancellation" \
  0 "$(run_rc turn_fanout_trip_active "$publication_retry_trip")"

init_hard inv-v1-767676767676767676767677 review member-durable
turn_control_request_stop turn-cap
durability_retry_trip="$RUN_DIR/turn-control/durability-retry-trip.json"
TURN_CONTROL_FANOUT_TRIP_FILE="$durability_retry_trip"
sync_dir_definition="$(declare -f _turn_control_sync_dir)"
sync_dir_calls=0
_turn_control_sync_dir() {
  sync_dir_calls=$((sync_dir_calls + 1))
  if (( sync_dir_calls == 1 )); then
    return 1
  fi
  command sync -f "$1" 2>/dev/null
}
_turn_fanout_trip_write
trip_first_write_rc=$?
_turn_fanout_trip_write
trip_retry_write_rc=$?
eval "$sync_dir_definition"
assert_rc "TC-TURNLIMIT-093 failed trip directory sync rejects first publication" \
  1 "$trip_first_write_rc"
assert_rc "TC-TURNLIMIT-093 existing trip retry confirms durability" \
  0 "$trip_retry_write_rc"
assert_eq "TC-TURNLIMIT-093 trip retry re-syncs the visible record" 2 \
  "$sync_dir_calls"

init_hard inv-v1-777777777777777777777778 review member-timeout
unconfirmed_trip="$RUN_DIR/turn-control/unconfirmed-trip.json"
TURN_CONTROL_FANOUT_TRIP_FILE="$unconfirmed_trip"
_turn_fanout_trip_write
assert_rc "TC-TURNLIMIT-053 trip is inactive before trigger winner persists" 1 \
  "$(run_rc turn_fanout_trip_active "$unconfirmed_trip")"
turn_control_request_stop timeout
assert_rc "TC-TURNLIMIT-053 timeout-owned trip never activates cancellation" 1 \
  "$(run_rc turn_fanout_trip_active "$unconfirmed_trip")"

init_hard inv-v1-777777777777777777777779 review member-malformed
malformed_trip="$RUN_DIR/turn-control/malformed-trip.json"
TURN_CONTROL_FANOUT_TRIP_FILE="$malformed_trip"
printf '%s\n' '{"schema_version":1,"reason":"turn-cap"}' >"$malformed_trip"
assert_rc "TC-TURNLIMIT-079 malformed existing trip rejects publication" 1 \
  "$(run_rc _turn_fanout_trip_write)"
assert_eq "TC-TURNLIMIT-079 rejected publication preserves malformed trip" \
  '{"schema_version":1,"reason":"turn-cap"}' "$(cat "$malformed_trip")"

init_hard inv-v1-787878787878787878787878 review member-queued-retry
queued_retry_record="$TURN_CONTROL_FILE"
TURN_CONTROL_FANOUT_TRIP_FILE="$trip_file"
RETRY_RECORDS=("$trigger_file" "$queued_retry_record")
turn_sync_definition="$(declare -f turn_control_sync_fanout_trip)"
turn_sync_original_definition="${turn_sync_definition/turn_control_sync_fanout_trip/turn_control_sync_fanout_trip_original}"
eval "$turn_sync_original_definition"
queued_sync_calls=0
turn_control_sync_fanout_trip() {
  if [[ "$TURN_CONTROL_FILE" == "$queued_retry_record" ]]; then
    queued_sync_calls=$((queued_sync_calls + 1))
    (( queued_sync_calls > 1 )) || return 1
  fi
  turn_control_sync_fanout_trip_original
}
turn_control_sync_review_trip_records "$trip_file" RETRY_RECORDS
queued_retry_rc=$?
eval "$turn_sync_definition"
unset -f turn_control_sync_fanout_trip_original
assert_rc "TC-TURNLIMIT-094 post-fanout retries queued sibling cancellation" \
  0 "$queued_retry_rc"
assert_eq "TC-TURNLIMIT-094 queued sibling cancellation retries once" 2 \
  "$queued_sync_calls"
assert_eq "TC-TURNLIMIT-094 queued sibling is durably cancelled" fanout-cancel \
  "$(jq -r .winner "$queued_retry_record")"

init_hard inv-v1-797979797979797979797979 review member-context-restore
context_restore_record="$TURN_CONTROL_FILE"
context_restore_malformed="$RUN_DIR/turn-control/context-restore-malformed.json"
printf '%s\n' '{"malformed":true}' >"$context_restore_malformed"
CONTEXT_RESTORE_RECORDS=("$context_restore_record" "$context_restore_malformed")
TURN_CONTROL_FILE="$trigger_file"
TURN_CONTROL_FANOUT_TRIP_FILE="$trip_file"
turn_control_sync_review_trip_records "$trip_file" CONTEXT_RESTORE_RECORDS
context_restore_rc=$?
assert_rc "TC-TURNLIMIT-099 later-record synchronization failure is loud" 1 \
  "$context_restore_rc"
assert_eq "TC-TURNLIMIT-099 synchronization restores invocation context" \
  "$trigger_file" "$TURN_CONTROL_FILE"
assert_eq "TC-TURNLIMIT-099 synchronization restores trip context" \
  "$trip_file" "$TURN_CONTROL_FANOUT_TRIP_FILE"

init_hard inv-v1-888888888888888888888888 review member-b
TURN_CONTROL_FANOUT_TRIP_FILE="$trip_file"
turn_control_sync_fanout_trip
assert_eq "TC-TURNLIMIT-056 sibling consumes fanout cancel" fanout-cancel \
  "$(turn_control_winner)"
assert_eq "TC-TURNLIMIT-056 sibling cancellation evidence" 1 \
  "$(jq '[.evidence[] | select(.action == "cancelled-sibling")] | length' "$TURN_CONTROL_FILE")"

init_hard inv-v1-898989898989898989898989 review member-read-fail
TURN_CONTROL_FANOUT_TRIP_FILE="$trip_file"
winner_definition="$(declare -f turn_control_winner)"
turn_control_winner() { return 1; }
turn_control_sync_fanout_trip
sync_read_fail_rc=$?
eval "$winner_definition"
assert_rc "TC-TURNLIMIT-097 sibling winner read failure fails closed" 1 \
  "$sync_read_fail_rc"
assert_eq "TC-TURNLIMIT-097 stop request remains durably arbitrated" fanout-cancel \
  "$(turn_control_winner)"
assert_eq "TC-TURNLIMIT-097 unreadable winner fabricates no cancellation evidence" 0 \
  "$(jq '[.evidence[] | select(.action == "cancelled-sibling")] | length' "$TURN_CONTROL_FILE")"
assert_rc "TC-TURNLIMIT-097 retry persists cancellation evidence" 0 \
  "$(run_rc turn_control_sync_fanout_trip)"
assert_eq "TC-TURNLIMIT-097 retry records one cancellation action" 1 \
  "$(jq '[.evidence[] | select(.action == "cancelled-sibling")] | length' "$TURN_CONTROL_FILE")"

init_hard inv-v1-888888888888888888888889 review member-timeout
turn_control_request_stop timeout
TURN_CONTROL_FANOUT_TRIP_FILE="$trip_file"
turn_control_sync_fanout_trip
assert_eq "TC-TURNLIMIT-056 prior timeout winner is not rewritten" timeout \
  "$(turn_control_winner)"
assert_eq "TC-TURNLIMIT-056 non-cancel winner gets no cancelled-sibling action" 0 \
  "$(jq '[.evidence[] | select(.action == "cancelled-sibling")] | length' "$TURN_CONTROL_FILE")"

TURN_CONTROL_FILE="$trigger_file"
TURN_CONTROL_FANOUT_TRIP_FILE="$trip_file"
turn_control_sync_fanout_trip
assert_eq "TC-TURNLIMIT-057 trigger remains turn-cap" turn-cap \
  "$(turn_control_winner)"

if jq -e --argjson required "$required" '
    all(.evidence[]; ($required - keys | length) == 0)
  ' "$trigger_file" >/dev/null; then
  pass "TC-TURNLIMIT-038 stop evidence has every required field"
else
  fail "TC-TURNLIMIT-038 stop evidence has every required field"
fi

echo "== TC-TURNLIMIT-014/111: docs/runtime parity =="
capability_doc_rows() {
  local doc="$1"
  sed -n '/TURN-CAPABILITY-MATRIX-BEGIN/,/TURN-CAPABILITY-MATRIX-END/p' "$doc" \
    | awk -F'|' '
        /^\| (claude|codex|kiro|agy|gemini|opencode|generic) \|/ {
          gsub(/^ +| +$/, "", $2); gsub(/^ +| +$/, "", $3); gsub(/^ +| +$/, "", $4)
          print $2 "|" $3 "|" $4
        }'
}

expected_rows="$(
  for adapter in "${production[@]}"; do
    warn=no
    hard=no
    if turn_capability "$adapter" dev-new warn; then
      warn=yes
      [[ "$adapter" == "claude" ]] && warn=version-probed
    fi
    turn_capability "$adapter" dev-new hard && hard=yes
    printf '%s|%s|%s\n' "$adapter" "$warn" "$hard"
  done
)"
for doc in "$SPEC" "$DESIGN"; do
  if [[ -f "$doc" ]] && grep -q 'TURN-CAPABILITY-MATRIX-BEGIN' "$doc"; then
    assert_eq "TC-TURNLIMIT-111 $(basename "$doc") mirrors production matrix" \
      "$expected_rows" "$(capability_doc_rows "$doc")"
  else
    fail "TC-TURNLIMIT-111 $(basename "$doc") has machine-readable capability matrix"
  fi
done

for adapter in "${production[@]}"; do
  doc_row="$(awk -F'|' -v adapter="$adapter" '$1 == adapter { print; exit }' <<<"$expected_rows")"
  IFS='|' read -r _adapter doc_warn doc_hard <<<"$doc_row"
  for lane in "${lanes[@]}"; do
    runtime_warn=no
    runtime_hard=no
    if turn_capability "$adapter" "$lane" warn; then
      runtime_warn=yes
      [[ "$adapter" == "claude" ]] && runtime_warn=version-probed
    fi
    turn_capability "$adapter" "$lane" hard && runtime_hard=yes
    assert_eq "TC-TURNLIMIT-111 $adapter/$lane tuple matches published row" \
      "${doc_warn}|${doc_hard}" "${runtime_warn}|${runtime_hard}"
  done
done

for doc in "$SPEC" "$DESIGN"; do
  synthetic_doc_row="$(
    sed -n '/TURN-CAPABILITY-TEST-MATRIX-BEGIN/,/TURN-CAPABILITY-TEST-MATRIX-END/p' "$doc" \
      | awk -F'|' '
          /^\| synthetic \(test-only, non-selectable\) \|/ {
            gsub(/^ +| +$/, "", $3); gsub(/^ +| +$/, "", $4)
            print "synthetic|" $3 "|" $4
          }'
  )"
  assert_eq "TC-TURNLIMIT-091 $(basename "$doc") mirrors test-only synthetic matrix" \
    "synthetic|yes|yes" "$synthetic_doc_row"
done

echo "== TC-TURNLIMIT-071: controller branch inventory =="
if [[ "${TURN_LIMIT_COVERAGE_CHILD:-0}" != "1" ]]; then
  coverage_trace="$WORK/coverage.trace"
  coverage_out="$WORK/coverage.out"
  exec 9>"$coverage_trace"
  (
    BASH_XTRACEFD=9
    PS4='+${BASH_SOURCE}:${LINENO}:'
    export BASH_XTRACEFD PS4
    env -u TURN_CONTROL_FILE -u TURN_CONTROL_FANOUT_TRIP_FILE \
      -u TURN_CONTROL_HARD_ACTIVE -u TURN_CONTROL_OBSERVE_ACTIVE \
      TURN_LIMIT_COVERAGE_CHILD=1 bash -x "$0"
    bash -x "$SCRIPT_DIR/test-turn-limit-wiring.sh"
    TOKEN_BUDGET_COVERAGE_CHILD=1 bash -x "$SCRIPT_DIR/test-lib-token-budget.sh"
    bash -x "$SCRIPT_DIR/test-lib-review-codex.sh"
    env -u TURN_CONTROL_FILE -u TURN_CONTROL_FANOUT_TRIP_FILE \
      -u TURN_CONTROL_HARD_ACTIVE -u TURN_CONTROL_OBSERVE_ACTIVE \
      bash -x "$PROJECT_ROOT/tests/e2e/run-turn-limit-control-e2e.sh"
  ) >"$coverage_out" 2>&1
  coverage_rc=$?
  exec 9>&-
  assert_rc "TC-TURNLIMIT-071 traced test child succeeds" 0 "$coverage_rc"
  if [[ "$coverage_rc" -ne 0 ]]; then
    tail -40 "$coverage_out"
  fi

  coverage_inventory="$FIXTURES/turn-control-branch-inventory.tsv"
  coverage_sources=(
    "$LIB"
    "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-agent.sh"
    "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
    "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
    "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/adapters/codex.sh"
    "$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-token-budget.sh"
  )
  coverage_total=0
  coverage_covered=0
  coverage_bad=0
  declare -A coverage_ids=()
  while IFS='|' read -r branch_id status test_id scope description; do
    [[ -n "$branch_id" && "${branch_id:0:1}" != "#" ]] || continue
    coverage_total=$((coverage_total + 1))
    if [[ -n "${coverage_ids[$branch_id]:-}" ]]; then
      printf 'duplicate turn-control branch id: %s\n' "$branch_id"
      coverage_bad=$((coverage_bad + 1))
    fi
    coverage_ids[$branch_id]=1

    source_hits="$(
      grep -nFH "turn-control-branch: $branch_id" "${coverage_sources[@]}" || true
    )"
    source_hit_count="$(wc -l <<<"$source_hits" | tr -d ' ')"
    if [[ "$source_hit_count" != "1" ]]; then
      printf 'branch %s has %s source markers: %s\n' \
        "$branch_id" "$source_hit_count" "$description"
      coverage_bad=$((coverage_bad + 1))
      continue
    fi
    source_file="${source_hits%%:*}"
    source_tail="${source_hits#*:}"
    source_line="${source_tail%%:*}"
    branch_executed=0
    if grep -Fq "${source_file}:${source_line}:" "$coverage_trace" \
        || grep -Eq ":: ['\"]turn-control-branch: ${branch_id}['\"]$" "$coverage_trace"; then
      branch_executed=1
    fi

    case "$status" in
      covered)
        coverage_covered=$((coverage_covered + 1))
        if [[ "$test_id" == "-" ]] || ! grep -RqsF --include='*.sh' "$test_id" \
            "$PROJECT_ROOT/tests/unit" "$PROJECT_ROOT/tests/e2e"; then
          printf 'covered branch %s references missing test id %s: %s\n' \
            "$branch_id" "$test_id" "$description"
          coverage_bad=$((coverage_bad + 1))
        fi
        if [[ "$branch_executed" -ne 1 ]]; then
          printf 'covered branch %s did not execute (%s): %s\n' \
            "$branch_id" "$scope" "$description"
          coverage_bad=$((coverage_bad + 1))
        fi
        ;;
      uncovered)
        if [[ "$test_id" != "-" ]]; then
          printf 'uncovered branch %s must use test id -: %s\n' \
            "$branch_id" "$description"
          coverage_bad=$((coverage_bad + 1))
        fi
        if [[ "$branch_executed" -eq 1 ]]; then
          printf 'uncovered branch %s executed and must be promoted: %s\n' \
            "$branch_id" "$description"
          coverage_bad=$((coverage_bad + 1))
        fi
        ;;
      scheduler-dependent)
        # This branch is one side of a parent/watchdog scheduling race with
        # identical externally asserted behavior. Do not require either trace
        # outcome and do not count it as executed coverage.
        if [[ "$test_id" == "-" ]] || ! grep -RqsF --include='*.sh' "$test_id" \
            "$PROJECT_ROOT/tests/unit" "$PROJECT_ROOT/tests/e2e"; then
          printf 'scheduler-dependent branch %s references missing test id %s: %s\n' \
            "$branch_id" "$test_id" "$description"
          coverage_bad=$((coverage_bad + 1))
        fi
        ;;
      *)
        printf 'invalid branch status %s for %s\n' "$status" "$branch_id"
        coverage_bad=$((coverage_bad + 1))
        ;;
    esac
  done <"$coverage_inventory"

  source_marker_ids="$(
    grep -hoE 'turn-control-branch: B[0-9]+' "${coverage_sources[@]}" \
      | awk '{print $2}' | sort -u
  )"
  source_marker_total="$(wc -l <<<"$source_marker_ids" | tr -d ' ')"
  while IFS= read -r source_id; do
    [[ -n "$source_id" ]] || continue
    if [[ -z "${coverage_ids[$source_id]:-}" ]]; then
      printf 'source marker %s is missing from the branch inventory\n' "$source_id"
      coverage_bad=$((coverage_bad + 1))
    fi
  done <<<"$source_marker_ids"

  coverage_percent="$(awk -v covered="$coverage_covered" -v total="$coverage_total" \
    'BEGIN { printf "%.1f", covered * 100 / total }')"
  assert_eq "TC-TURNLIMIT-071 source-anchored inventory has no errors" \
    0 "$coverage_bad"
  assert_eq "TC-TURNLIMIT-071 inventory accounts for every source marker" \
    "$source_marker_total" "$coverage_total"
  if [[ "$coverage_total" -gt 0 \
        && "$coverage_covered" -gt $((coverage_total * 80 / 100)) ]]; then
    pass "TC-TURNLIMIT-071 semantic branch coverage ${coverage_covered}/${coverage_total} (${coverage_percent}%) > 80%"
  else
    fail "TC-TURNLIMIT-071 semantic branch coverage ${coverage_covered}/${coverage_total} (${coverage_percent}%) is not > 80%"
  fi

  decision_sites="$WORK/turn-limit-decision-sites"
  awk '
    BEGIN { in_single_quote = 0; previous_continued = 0 }
    {
      raw = $0
      continued = previous_continued
      previous_continued = (raw ~ /\\[[:space:]]*$/)
      lead = raw
      sub(/^[[:space:]]*/, "", lead)
      if (!in_single_quote && lead ~ /^#/) next
      if (!in_single_quote) sub(/[[:space:]]+#.*/, "", raw)

      quoted = raw
      quote_count = gsub(/\047/, "", quoted)
      if (in_single_quote) {
        if (quote_count % 2 == 1) in_single_quote = 0
        next
      }
      if (continued) {
        if (quote_count % 2 == 1) in_single_quote = 1
        next
      }

      code = raw
      sub(/\047.*/, "", code)
      trimmed = code
      sub(/^[[:space:]]*/, "", trimmed)
      if (trimmed ~ /^(if|elif|for|while)[[:space:]]/ ||
          (trimmed !~ /^(if|elif)[[:space:]]/ &&
           trimmed ~ /[[:space:]](\|\||&&)[[:space:]]/)) {
        print NR
      }
      if (quote_count % 2 == 1) in_single_quote = 1
    }
  ' "$LIB" >"$decision_sites"
  decision_total="$(wc -l <"$decision_sites" | tr -d ' ')"
  decision_covered=0
  while IFS= read -r decision_line; do
    [[ -n "$decision_line" ]] || continue
    if grep -Fq "${LIB}:${decision_line}:" "$coverage_trace"; then
      decision_covered=$((decision_covered + 1))
    fi
  done <"$decision_sites"
  decision_percent="$(awk -v covered="$decision_covered" -v total="$decision_total" \
    'BEGIN { printf "%.1f", covered * 100 / total }')"
  if [[ "$decision_total" -gt 0 \
        && "$decision_covered" -gt $((decision_total * 80 / 100)) ]]; then
    pass "TC-TURNLIMIT-071 source-derived decision coverage ${decision_covered}/${decision_total} (${decision_percent}%) > 80%"
  else
    fail "TC-TURNLIMIT-071 source-derived decision coverage ${decision_covered}/${decision_total} (${decision_percent}%) is not > 80%"
  fi
fi

printf 'TURN-LIMIT-UNIT-SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
