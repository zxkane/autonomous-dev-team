#!/bin/bash
# Hermetic launch-protocol tests; real cgroup containment is a separate E2E.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPTS="$ROOT/skills/autonomous-dispatcher/scripts"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
mkdir "$TMP/bin" "$TMP/cgroup"
cat > "$TMP/bin/loginctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$WRS_PROBE_ARGS"
[[ "$1" == show-user && "$2" == "${USER:-$(id -un)}" ]] || exit 1
printf '%s\n' "${WRS_LINGER:-yes}"
SH
cat > "$TMP/bin/systemd-run" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$WRS_SCOPE_ARGS"
unit=''
while [[ $# -gt 0 && "$1" != -- ]]; do
  if [[ "$1" == --unit ]]; then shift; unit="$1"; fi
  shift
done
[[ "${1:-}" == -- ]] && shift
[[ "${1:-}" == true ]] && exit 0
if [[ "${WRS_MODE:-success}" == registration-failure ]]; then
  echo 'Failed to register fixture scope' >&2
  exit 1
fi
if [[ "${WRS_MODE:-}" == registration-wedge ]]; then
  trap '' TERM
  exec sleep 8
fi
mkdir -p "$WRS_CGROUP/$unit"
printf '%s\n' "$$" > "$WRS_CGROUP/$unit/cgroup.procs"
exec "$@"
SH
cat > "$TMP/payload" <<'SH'
#!/bin/bash
printf 'run\n' >> "$WRS_COUNT"
printf '%s\n' "$$" > "$WRS_PAYLOAD_PID"
printf '%s\n' "$@" > "$WRS_ARGV"
cat > "$WRS_STDIN"
printf '%s\n' "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}" "${GH_USER_PAT:-unset}" > "$WRS_ENV"
[[ "${WRS_MODE:-}" == payload-failure ]] && echo 'Failed to register fixture scope' >&2
[[ "${WRS_MODE:-}" == timeout ]] && exec sleep 5
exit 37
SH
chmod +x "$TMP/bin/"* "$TMP/payload"
export PATH="$TMP/bin:$PATH"
export WRS_PROBE_ARGS="$TMP/probe.args" WRS_SCOPE_ARGS="$TMP/scope.args"
export WRS_CGROUP="$TMP/cgroup" WRS_LINGER=yes
export REPO=example-owner/example-repo REPO_OWNER=example-owner REPO_NAME=example-repo
export PROJECT_ID=wrs-fixture PROJECT_DIR="$TMP" GH_AUTH_MODE=token
export ADT_STATE_ROOT="$TMP/state" ADT_LANE_BACKEND_OVERRIDE=systemd-scope
source "$SCRIPTS/lib-lane.sh"
source "$SCRIPTS/lib-auth.sh"
source "$SCRIPTS/lib-agent.sh" >/dev/null 2>&1
# This fake cgroup tests the handshake only, never claims kernel membership.
_lane_cgroup_path() { printf '%s/%s\n' "$WRS_CGROUP" "${1%.scope}"; }
backend=$(_lane_backend 2>/dev/null)
if [[ "$backend" == systemd-scope ]] && grep -q "^show-user ${USER:-$(id -un)} -p Linger --value$" "$WRS_PROBE_ARGS"; then
  ok 'TC-WRS-001 explicit username enables the eligible fixture'
else bad 'TC-WRS-001 explicit username probe'; fi
WRS_LINGER=no
if [[ "$(_lane_backend 2>/dev/null)" == pgid ]]; then ok 'TC-WRS-001 override cannot bypass linger'; else bad 'TC-WRS-001 override bypass'; fi
WRS_LINGER=yes
if env -u USER bash -c 'source "$1"; [[ "$(_lane_backend 2>/dev/null)" == systemd-scope ]]' _ "$SCRIPTS/lib-lane.sh"; then
  ok 'TC-WRS-001 missing USER uses the actual account name'
else bad 'TC-WRS-001 missing USER fallback'; fi
bash "$SCRIPTS/adt-gc.sh" --doctor > "$TMP/doctor.out" 2>&1
if grep -q 'backend_eligibility=systemd-scope' "$TMP/doctor.out"; then ok 'TC-WRS-001 doctor uses the explicit-user probe'; else bad 'TC-WRS-001 doctor'; fi
export AGENT_PID_FILE="$TMP/agent.pid"
AGENT_LAUNCHER_ARGV=(bash -c 'exec "$@"' --)
AGENT_GH_TOKEN_FILE="$TMP/scoped-token"
printf '%s\n' fixture-scoped-token > "$AGENT_GH_TOKEN_FILE"
chmod 600 "$AGENT_GH_TOKEN_FILE"
GH_TOKEN=fixture-broker-token GITHUB_TOKEN=fixture-broker-alias GH_USER_PAT=fixture-user-token
export GH_TOKEN GITHUB_TOKEN GH_USER_PAT
GH_AUTH_MODE=app

run_case() {
  local name="$1" mode="$2" chosen="$3" expected="$4" executions="${5:-1}"
  export WRS_MODE="$mode"
  export WRS_COUNT="$TMP/$name.count" WRS_PAYLOAD_PID="$TMP/$name.pid"
  export WRS_ARGV="$TMP/$name.argv" WRS_STDIN="$TMP/$name.stdin" WRS_ENV="$TMP/$name.env"
  : > "$WRS_SCOPE_ARGS"
  ADT_LANE_DIR="$TMP/lane-$name"
  mkdir "$ADT_LANE_DIR"
  printf 'BACKEND=%s\nUNIT=adt-wrs-%s\nSTATE=live\n' "$chosen" "$name" > "$ADT_LANE_DIR/lane"
  : > "$ADT_LANE_DIR/pgids"
  : > "$ADT_LANE_DIR/reap.lock"
  AGENT_TIMEOUT=5s
  [[ "$mode" == timeout ]] && AGENT_TIMEOUT=1s
  printf 'fixture prompt\nsecond line\n' | _run_with_timeout "$TMP/payload" 'arg with spaces' --literal > "$TMP/$name.out" 2> "$TMP/$name.err"
  local rc=$?
  if [[ "$rc" == "$expected" ]]; then ok "$name exit status $expected"; else bad "$name status $rc expected $expected"; cat "$TMP/$name.err"; fi
  if [[ "$executions" == 0 ]]; then
    if [[ ! -e "$WRS_COUNT" ]]; then ok "$name refused payload execution"; else bad "$name payload ran after refusal"; fi
    return
  fi
  if [[ "$(wc -l < "$WRS_COUNT" 2>/dev/null)" == 1 ]]; then ok "$name payload runs once"; else bad "$name execution count"; fi
  if [[ "$(cat "$WRS_STDIN" 2>/dev/null)" == $'fixture prompt\nsecond line' ]]; then ok "$name prompt stdin"; else bad "$name prompt stdin"; fi
  if [[ "$(cat "$WRS_ARGV" 2>/dev/null)" == $'arg with spaces\n--literal' ]]; then ok "$name launcher argv"; else bad "$name launcher argv"; fi
  if [[ "$(cat "$WRS_ENV" 2>/dev/null)" == $'fixture-scoped-token\nfixture-scoped-token\nunset' ]]; then ok "$name credential scrubbing"; else bad "$name credential scrubbing"; fi
  local leader
  leader=$(cat "$AGENT_PID_FILE" 2>/dev/null)
  if [[ "$leader" =~ ^[0-9]+$ ]] && grep -q "^$leader " "$ADT_LANE_DIR/pgids"; then ok "$name PID publication and PGID registry"; else bad "$name PID/PGID registration"; fi
}
run_case TC-WRS-002 success systemd-scope 37
if [[ -s "$ADT_LANE_DIR/agent-scopes" ]] && grep -q 'systemd-run\|--scope' "$WRS_SCOPE_ARGS"; then ok 'TC-WRS-002 successful scope recorded'; else bad 'TC-WRS-002 scope never enrolled'; fi
run_case TC-WRS-003 registration-failure systemd-scope 37
if [[ ! -s "$ADT_LANE_DIR/agent-scopes" ]]; then ok 'TC-WRS-003 failed scope not recorded as enrolled'; else bad 'TC-WRS-003 false enrollment'; fi
run_case TC-WRS-004 payload-failure systemd-scope 37
if [[ -s "$ADT_LANE_DIR/agent-scopes" ]]; then ok 'TC-WRS-004 payload error retains enrollment'; else bad 'TC-WRS-004 enrollment'; fi
saved_scope_registration=$(declare -f lane_record_agent_scope)
lane_record_agent_scope() { return 1; }
run_case TC-WRS-005 success systemd-scope 37
if [[ ! -s "$ADT_LANE_DIR/agent-scopes" ]]; then ok 'TC-WRS-005 registry failure never acknowledges scope'; else bad 'TC-WRS-005 false enrollment'; fi
eval "$saved_scope_registration"
eval "${saved_scope_registration/lane_record_agent_scope/original_scope_registration}"
lane_record_agent_scope() { lane_set "$1" STATE reaped-by-guardian; return 1; }
run_case TC-WRS-009 registration-failure systemd-scope 1 0
TURN_CONTROL_HARD_ACTIVE=1
TURN_CONTROL_ERROR_RC=93
run_case TC-WRS-010 registration-failure systemd-scope 93 0
TURN_CONTROL_HARD_ACTIVE=0
lane_record_agent_scope() {
  ln -s abort "$4/decision"
  original_scope_registration "$@"
}
run_case TC-WRS-011 success systemd-scope 37
if grep -q 'PGID fallback' "$TMP/TC-WRS-011.err"; then ok 'TC-WRS-011 expired pre-ack bootstrap uses fallback'; else bad 'TC-WRS-011 launch expiry ignored'; fi
eval "$saved_scope_registration"
cleanup_start=$SECONDS
run_case TC-WRS-012 registration-wedge systemd-scope 37
if (( SECONDS - cleanup_start < 8 )); then ok 'TC-WRS-012 failed registration cleanup is bounded'; else bad 'TC-WRS-012 TERM-resistant bootstrap blocked cleanup'; fi
saved_start_reader=$(declare -f proc_start_time)
sleep 30 &
unknown_pid=$!
unknown_start=$(proc_start_time "$unknown_pid")
mkdir "$TMP/unknown-identity"
proc_start_time() { return 1; }
if _lane_agent_launch_abort "$TMP/unknown-identity" '' "$unknown_pid" "$unknown_start"; then
  bad 'TC-WRS-013 unreadable live identity was treated as termination'
else ok 'TC-WRS-013 unreadable live identity refuses wait and replay'; fi
kill -KILL "$unknown_pid"
wait "$unknown_pid" 2>/dev/null || true
eval "$saved_start_reader"
run_case TC-WRS-006 success pgid 37
if [[ ! -s "$WRS_SCOPE_ARGS" ]]; then ok 'TC-WRS-006 portable launch avoids systemd-run'; else bad 'TC-WRS-006 unexpected scope launch'; fi
run_case TC-WRS-007 timeout systemd-scope 124
export WRS_MODE=success
ADT_LANE_DIR="$TMP/lane-parallel"
mkdir "$ADT_LANE_DIR"
printf 'BACKEND=systemd-scope\nUNIT=adt-wrs-parallel\nSTATE=live\n' > "$ADT_LANE_DIR/lane"
: > "$ADT_LANE_DIR/pgids"
: > "$ADT_LANE_DIR/reap.lock"
parallel_run() {
  local name="$1"
  export WRS_COUNT="$TMP/$name.count" WRS_PAYLOAD_PID="$TMP/$name.pid"
  export WRS_ARGV="$TMP/$name.argv" WRS_STDIN="$TMP/$name.stdin" WRS_ENV="$TMP/$name.env"
  AGENT_PID_FILE="$TMP/$name.agent.pid"
  AGENT_TIMEOUT=5s
  _run_with_timeout "$TMP/payload" 'literal $variable' --literal < /dev/null
}
parallel_run parallel-one &
p1=$!
parallel_run parallel-two &
p2=$!
wait "$p1"; r1=$?
wait "$p2"; r2=$?
if [[ "$r1" == 37 && "$r2" == 37 && "$(sort -u "$ADT_LANE_DIR/agent-scopes" | wc -l)" == 2 ]]; then ok 'TC-WRS-008 parallel agents have distinct scopes'; else bad 'TC-WRS-008 parallel scope collision'; fi
if [[ "$(head -1 "$TMP/parallel-one.argv")" == 'literal $variable' ]]; then ok 'TC-WRS-008 dollar arguments are not expanded'; else bad 'TC-WRS-008 dollar expansion'; fi
export WRS_REAP_ARGS="$TMP/reap.args"
cat > "$TMP/bin/systemctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$WRS_REAP_ARGS"
SH
chmod +x "$TMP/bin/systemctl"
_lane_cgroup_empty() { return 0; }
_lane_scope_kill "$ADT_LANE_DIR" 0
while read -r unit; do
  if grep -q -- "kill -s TERM $unit.scope" "$TMP/reap.args"; then ok 'TC-WRS-008 registered scope included in reap'; else bad 'TC-WRS-008 missing scope reap'; fi
done < "$ADT_LANE_DIR/agent-scopes"
echo "WRAPPER-SCOPE-SUMMARY pass=$PASS fail=$FAIL"
[[ "$FAIL" == 0 ]]
