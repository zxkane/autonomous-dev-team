#!/bin/bash
# Real wrapper + real user-manager containment. No network or credentials.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRIPTS="$ROOT/skills/autonomous-dispatcher/scripts"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [[ "$(loginctl show-user "${USER:-$(id -un)}" -p Linger --value 2>/dev/null)" != yes \
  || ! -S "$XDG_RUNTIME_DIR/bus" ]]; then
  echo 'WRAPPER-SCOPE-E2E unavailable: existing linger-enabled user manager required'
  exit 77
fi
TMP=$(mktemp -d)
REAL_SYSTEMD_RUN=$(command -v systemd-run)
PASS=0 FAIL=0
alive() {
  local state
  state=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  [[ -n "$state" && "$state" != Z* ]]
}
cleanup() {
  local f pid unit
  for f in "$TMP"/*/agent.pid "$TMP"/*/child.pid "$TMP"/*/wrapper.pid; do
    [[ -f "$f" ]] || continue
    pid=$(cat "$f")
    [[ "$pid" =~ ^[0-9]+$ ]] && alive "$pid" && kill -KILL "$pid" 2>/dev/null || true
  done
  for f in "$TMP"/*/state/autonomous-wrs-e2e-*/lanes/*/agent-scopes; do
    [[ -f "$f" ]] || continue
    while read -r unit; do
      [[ "$unit" == adt-wrs-e2e-* ]] || continue
      systemctl --user kill -s KILL "$unit.scope" >/dev/null 2>&1 || true
    done < "$f"
  done
  rm -rf -- "$TMP"
}
trap cleanup EXIT
ok() { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_case() {
  local mode="$1" dir="$TMP/$1" project="wrs-e2e-$1-$$"
  mkdir -p "$dir/bin" "$dir/project/scripts" "$dir/pids" "$dir/state"
  cat > "$dir/bin/gh" <<'GH'
#!/bin/bash
[[ "${1:-}" == --version ]] && { echo 'gh version 2.90.0'; exit 0; }
if [[ "${1:-} ${2:-}" == 'issue view' ]]; then
  echo '{"title":"scope fixture","body":"isolated fixture","state":"OPEN","labels":[{"name":"autonomous"},{"name":"in-progress"}]}'
elif [[ "${1:-}" == api ]]; then echo '[[]]'; fi
exit 0
GH
  cat > "$dir/bin/claude" <<'AGENT'
#!/bin/bash
cat >/dev/null
printf 'run\n' >> "$WRS_E2E_DIR/count"
printf '%s\n' "$$" > "$WRS_E2E_DIR/agent.pid"
if [[ "$WRS_E2E_MODE" == scope ]]; then
  setsid bash -c 'trap "" TERM; exec sleep 120' &
else
  sleep 120 &
fi
printf '%s\n' "$!" > "$WRS_E2E_DIR/child.pid"
wait
AGENT
  if [[ "$mode" == fallback ]]; then
    cat > "$dir/bin/systemd-run" <<'SYSTEMD'
#!/bin/bash
if [[ "$*" == *-agent-* ]]; then
  echo 'Failed to register fixture agent scope' >&2
  exit 1
fi
exec "$WRS_REAL_SYSTEMD_RUN" "$@"
SYSTEMD
  fi
  chmod +x "$dir/bin/"*
  cat > "$dir/project/scripts/autonomous.conf" <<CONF
PROJECT_ID="$project"
REPO="example-owner/scope-fixture"
REPO_OWNER="example-owner"
REPO_NAME="scope-fixture"
PROJECT_DIR="$dir/project"
AGENT_CMD="claude"
AGENT_DEV_MODEL=""
AGENT_TIMEOUT=120s
GH_AUTH_MODE="token"
MAX_RETRIES=1
HEARTBEAT_INTERVAL_SECONDS=0
CONF
  setsid env PATH="$dir/bin:$PATH" REAL_GH="" GH_TOKEN=fixture-not-a-credential \
    ADT_STATE_ROOT="$dir/state" AUTONOMOUS_PID_DIR="$dir/pids" \
    AUTONOMOUS_CONF="$dir/project/scripts/autonomous.conf" \
    WRS_E2E_MODE="$mode" WRS_E2E_DIR="$dir" WRS_REAL_SYSTEMD_RUN="$REAL_SYSTEMD_RUN" \
    bash "$SCRIPTS/autonomous-dev.sh" --issue 990522 --mode new > "$dir/wrapper.log" 2>&1 &
  local wrapper=$! deadline=$((SECONDS + 30))
  printf '%s\n' "$wrapper" > "$dir/wrapper.pid"
  while [[ ! -s "$dir/child.pid" && $SECONDS -lt $deadline ]]; do sleep 0.1; done
  if [[ ! -s "$dir/child.pid" ]]; then
    bad "$mode real wrapper reached fixture agent"
    tail -30 "$dir/wrapper.log"
    return
  fi
  ok "$mode real wrapper reached fixture agent"
  local lane agent child unit="" cg=""
  lane=$(find "$dir/state/autonomous-$project/lanes" -mindepth 1 -maxdepth 1 -type d ! -name '.pending-*' | head -1)
  agent=$(cat "$dir/agent.pid") child=$(cat "$dir/child.pid")
  if [[ "$mode" == scope ]]; then
    unit=$(head -1 "$lane/agent-scopes")
    cg="/sys/fs/cgroup$(systemctl --user show -p ControlGroup --value "$unit.scope")"
    if grep -qx "$agent" "$cg/cgroup.procs" && grep -qx "$child" "$cg/cgroup.procs" \
      && [[ "$(ps -o pgid= -p "$agent" | tr -d ' ')" != "$(ps -o pgid= -p "$child" | tr -d ' ')" ]]; then
      ok 'scope agent and re-setsid escapee are members of the owned cgroup'
    else bad 'scope actual membership/escape evidence'; fi
  else
    if [[ ! -s "$lane/agent-scopes" ]] && grep -q 'PGID fallback' "$dir/wrapper.log"; then
      ok 'fallback registration failed before payload and portable launch was used'
    else bad 'fallback launch evidence'; fi
  fi
  if [[ "$(wc -l < "$dir/count")" == 1 ]]; then ok "$mode payload executed exactly once"; else bad "$mode execution count"; fi
  kill -KILL -- "-$wrapper" 2>/dev/null || true
  wait "$wrapper" 2>/dev/null || true
  deadline=$((SECONDS + 25))
  while [[ $SECONDS -lt $deadline ]]; do
    if ! alive "$agent" && ! alive "$child" && grep -q '^STATE=reaped-by-guardian$' "$lane/lane"; then break; fi
    sleep 0.1
  done
  if ! alive "$agent" && ! alive "$child" && grep -q '^STATE=reaped-by-guardian$' "$lane/lane"; then
    ok "$mode wrapper SIGKILL caused guardian to reap all fixture processes"
  else
    bad "$mode guardian reap"
    tail -20 "$lane/guardian.log"
  fi
  if [[ "$mode" == scope ]]; then
    if [[ ! -e "$cg/cgroup.procs" ]] || [[ -z "$(cat "$cg/cgroup.procs")" ]]; then
      ok 'scope cgroup is empty or collected after guardian reap'
    else bad 'scope cgroup still contains processes'; fi
  fi
}
run_case scope
run_case fallback
echo "WRAPPER-SCOPE-E2E-SUMMARY pass=$PASS fail=$FAIL"
[[ "$FAIL" == 0 ]]
