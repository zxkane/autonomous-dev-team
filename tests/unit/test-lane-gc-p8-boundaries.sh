#!/bin/bash
# Real-process ownership regressions for the #384 enforcement acceptance gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="$ROOT/skills/autonomous-dispatcher/scripts"
TMPROOT="$(mktemp -d)"
export ADT_STATE_ROOT="$TMPROOT/state"
export XDG_RUNTIME_DIR="$TMPROOT/runtime"
mkdir -p "$ADT_STATE_ROOT/autonomous-boundary/lanes/dead" "$XDG_RUNTIME_DIR"
LANE="$ADT_STATE_ROOT/autonomous-boundary/lanes/dead"
FIXTURE_PID=""
PASS=0
FAIL=0
stop_fixture() {
  if [[ -n "$FIXTURE_PID" ]]; then
    kill -TERM -- "-$FIXTURE_PID" 2>/dev/null || true
    wait "$FIXTURE_PID" 2>/dev/null || true
    FIXTURE_PID=""
  fi
}
trap 'stop_fixture; chmod 700 "$TMPROOT/denied-parent" 2>/dev/null || true; rm -rf "$TMPROOT"' EXIT

# Load only function declarations; never run the collector's main entry point.
source "$SCRIPTS/lib-lane.sh"
eval "$(awk '/^[a-zA-Z_][a-zA-Z0-9_]*\(\) \{$/ { fn=1 } fn { print } /^}$/ { fn=0 }' "$SCRIPTS/adt-gc.sh")"
GC_MODE=dry-run
_GC_OWN_PGID="$(proc_pgid "$$")"
WOULD_KILL_LEGACY=0
SKIPS=0
KILLED=0
_gc_same_uid_pids() { printf '%s\n' "$FIXTURE_PID"; }
_gc_log() { :; }

cat > "$TMPROOT/fixture.py" <<'PY'
import os
import pathlib
import sys
import time
os.chdir(sys.argv[1])
pathlib.Path(sys.argv[2]).touch()
time.sleep(120)
PY

start_fixture() {
  stop_fixture
  rm -f "$TMPROOT/ready"
  env -u TERM_PROGRAM -u ADT_LANE_ID -u ADT_LANE_DIR -u CC_USER \
    -u AUTONOMOUS_CONF_LOADED setsid python3 "$TMPROOT/fixture.py" \
    "$TMPROOT/cwd" "$TMPROOT/ready" "$@" &
  FIXTURE_PID=$!
  local tick
  for ((tick=0; tick<100; tick++)); do
    [[ -f "$TMPROOT/ready" ]] && return 0
    sleep 0.02
  done
  echo 'Fixture did not become ready' >&2
  return 1
}

write_lane() {
  cat > "$LANE/lane" <<EOF
LANE_ID=boundary:dev:1:1:abcd
PROJECT_ID=boundary
WRAPPER_PID=99999999
WRAPPER_START=0
BACKEND=pgid
STATE=failed
WORKTREE=$1
CHROME_PROFILE_HINT=$2
CREATED_EPOCH=1
EOF
  : > "$LANE/pgids"
}

check_rule() {
  local name="$1" expected="$2" rule="$3"
  WOULD_KILL=0
  "$rule"
  if [[ "$WOULD_KILL" == "$expected" ]] && kill -0 "$FIXTURE_PID" 2>/dev/null \
      && [[ "$WOULD_KILL_LEGACY" == 0 && "$KILLED" == 0 ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (would_kill=$WOULD_KILL expected=$expected)"
    FAIL=$((FAIL + 1))
  fi
}

# A process cwd can outlive its directory; use real rmdir and /proc reads.
mkdir -p "$TMPROOT/cwd"
start_fixture
write_lane "$TMPROOT/cw" -
check_rule 'B01 sibling prefix is unrelated' 0 _gc_pass3_e2e_servers
write_lane "$TMPROOT/cwd" -
check_rule 'B03 existing worktree is protected' 0 _gc_pass3_e2e_servers
rmdir "$TMPROOT/cwd"
check_rule 'B02 deleted exact worktree is residue' 1 _gc_pass3_e2e_servers
# Simulate unavailable inode evidence while retaining real identity/guards.
stat() {
  [[ "${*: -1}" == "/proc/${FIXTURE_PID}/cwd" ]] && return 1
  command stat "$@"
}
check_rule 'B09 unreadable cwd inode fails toward leak' 0 _gc_pass3_e2e_servers
unset -f stat
stop_fixture

mkdir -p "$TMPROOT/space tree/child" "$TMPROOT/cwd"
# The launch seam expects cwd; a symlink preserves the actual spaced /proc path.
rmdir "$TMPROOT/cwd"
ln -s "$TMPROOT/space tree/child" "$TMPROOT/cwd"
start_fixture
rmdir "$TMPROOT/space tree/child" "$TMPROOT/space tree"
write_lane "$TMPROOT/space tree" -
check_rule 'B02 deleted descendant with spaces is residue' 1 _gc_pass3_e2e_servers
write_lane "$TMPROOT/space" -
check_rule 'B01 spaced sibling prefix is unrelated' 0 _gc_pass3_e2e_servers
stop_fixture
rm "$TMPROOT/cwd"
mkdir -p "$TMPROOT/cwd"

for suffix in $'\n' ' (deleted)'; do
  rmdir "$TMPROOT/cwd"
  mkdir "$TMPROOT/worktree${suffix}"
  ln -s "$TMPROOT/worktree${suffix}" "$TMPROOT/cwd"
  start_fixture
  write_lane "$TMPROOT/worktree" -
  check_rule 'B01 literal newline/deleted-suffix sibling is unrelated' 0 _gc_pass3_e2e_servers
  stop_fixture
  rm "$TMPROOT/cwd"
  rmdir "$TMPROOT/worktree${suffix}"
  mkdir "$TMPROOT/cwd"
done

for suffix in '' ' (deleted)'; do
  rmdir "$TMPROOT/cwd"
  mkdir -p "$TMPROOT/denied-parent/worktree${suffix}"
  ln -s "$TMPROOT/denied-parent/worktree${suffix}" "$TMPROOT/cwd"
  start_fixture
  write_lane "$TMPROOT/denied-parent/worktree" -
  chmod 000 "$TMPROOT/denied-parent"
  check_rule 'B09 permission-denied existing cwd is protected' 0 _gc_pass3_e2e_servers
  chmod 700 "$TMPROOT/denied-parent"
  stop_fixture
  rm "$TMPROOT/cwd"
  rmdir "$TMPROOT/denied-parent/worktree${suffix}" "$TMPROOT/denied-parent"
  mkdir "$TMPROOT/cwd"
done
PROFILE="$TMPROOT/profile with spaces;literal"
write_lane - "$PROFILE"
profile_case() {
  local name="$1" expected="$2"
  shift 2
  start_fixture "$@"
  check_rule "$name" "$expected" _gc_pass3_chrome_lane_scoped
}
profile_case 'B04 joined exact profile' 1 "--user-data-dir=$PROFILE"
profile_case 'B07 separate value does not select a Chromium profile' 0 --user-data-dir "$PROFILE"
profile_case 'B05 joined sibling profile' 0 "--user-data-dir=${PROFILE}-other"
profile_case 'B05 separate sibling profile' 0 --user-data-dir "${PROFILE}-other"
profile_case 'B05 bare profile argument' 0 "$PROFILE"
profile_case 'B05 unrelated option value' 0 "--description=$PROFILE"
profile_case 'B05 embedded option text' 0 "description --user-data-dir=$PROFILE"
profile_case 'B07 newline-injected option' 0 $'description\n'"--user-data-dir=$PROFILE"
profile_case 'B07 trailing newline in profile' 0 "--user-data-dir=$PROFILE"$'\n'
profile_case 'B07 option after terminator' 0 -- "--user-data-dir=$PROFILE"
profile_case 'B07 duplicate conflicting switches' 0 "--user-data-dir=$PROFILE" --user-data-dir /tmp/other-profile
profile_case 'B07 duplicate identical switches' 0 "--user-data-dir=$PROFILE" "--user-data-dir=$PROFILE"
profile_case 'B07 single-hyphen override' 0 "--user-data-dir=$PROFILE" -user-data-dir=/tmp/other-profile
profile_case 'B07 whitespace-prefixed override' 0 "--user-data-dir=$PROFILE" ' --user-data-dir=/tmp/other-profile'
profile_case 'B07 whitespace-suffixed profile' 0 "--user-data-dir=$PROFILE "
profile_case 'B07 normalized terminator cannot hide positional profile' 0 ' -- ' "--user-data-dir=$PROFILE"
profile_case 'B04 canonical profile before terminator' 1 "--user-data-dir=$PROFILE" -- --user-data-dir=/tmp/other-profile
profile_case 'B07 empty joined value' 0 --user-data-dir=
profile_case 'B07 empty separate value' 0 --user-data-dir ''
profile_case 'B07 missing value' 0 --user-data-dir
profile_case 'B07 relative value' 0 --user-data-dir=relative-profile

# An exec racing the read (or a malformed source) must not hide a partial
# override after an otherwise valid profile. This exercises the pure parser.
if { printf 'chrome\0--user-data-dir=%s\0' "$PROFILE"; printf '%s' '--user-data-dir=/tmp/other-profile'; } \
    | _gc_chrome_profile_from_argv >/dev/null; then
  echo 'FAIL: B07 unterminated overriding argument was accepted'
  FAIL=$((FAIL + 1))
else
  echo 'PASS: B07 unterminated overriding argument is refused'
  PASS=$((PASS + 1))
fi

echo "Pass 3 boundary tests: $PASS passed, $FAIL failed"
[[ "$FAIL" == 0 ]]
