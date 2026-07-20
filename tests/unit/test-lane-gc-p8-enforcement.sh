#!/bin/bash
# Lane-GC P8 (#384): kill-by-default plus one-flag box-wide rollback.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ADT_GC="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/adt-gc.sh"
INSTALL_GC_TIMER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/install-gc-timer.sh"
LIB_LANE="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-lane.sh"
LIB_DISPATCH="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
LIVENESS_DRIVER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/liveness-check-remote-aws-ssm.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail "$desc (expected='$expected', actual='$actual')"
  fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc (needle='$needle' not found in: $haystack)"
  fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    fail "$desc (needle='$needle' unexpectedly found in: $haystack)"
  fi
}

for required in "$ADT_GC" "$INSTALL_GC_TIMER" "$LIB_LANE" "$LIB_DISPATCH" "$LIVENESS_DRIVER"; do
  [[ -f "$required" ]] || { echo "FATAL: missing $required" >&2; exit 1; }
done

TMPROOT="$(mktemp -d)"
declare -a SPAWNED_GROUPS=()
trap '
  for _pg in "${SPAWNED_GROUPS[@]:-}"; do
    [[ -n "$_pg" ]] && kill -KILL -- "-$_pg" 2>/dev/null || true
    [[ -n "$_pg" ]] && kill -KILL "$_pg" 2>/dev/null || true
  done
  rm -rf "$TMPROOT"
' EXIT

echo "=== Lane-GC P8 mode selection ==="

ST1="$TMPROOT/default"
mkdir -p "$ST1"
OUT1="$(env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST1" bash "$ADT_GC" --doctor 2>&1)"
assert_contains "TC-LGC8-001: unset flag defaults to kill" \
  "mode_default=kill (source=built-in, ADT_GC_ENFORCE=<unset>)" "$OUT1"
OUT1B="$(_LANE_UNAME_OVERRIDE=Darwin env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST1" bash "$ADT_GC" --doctor 2>&1)"
assert_contains "TC-LGC8-001b: unvalidated Darwin remains dry-run by default" \
  "mode_default=dry-run (source=built-in-platform-guard, ADT_GC_ENFORCE=<unset>)" "$OUT1B"
OUT1C="$(_LANE_UNAME_OVERRIDE=Darwin ADT_GC_ENFORCE=1 ADT_STATE_ROOT="$ST1" bash "$ADT_GC" --doctor 2>&1)"
assert_contains "TC-LGC8-001c: Darwin can be explicitly enabled after separate validation" \
  "mode_default=kill (source=environment, ADT_GC_ENFORCE=1)" "$OUT1C"
UNAME_FAIL_BIN="$TMPROOT/uname-fail-bin"
mkdir -p "$UNAME_FAIL_BIN"
cat > "$UNAME_FAIL_BIN/uname" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$UNAME_FAIL_BIN/uname"
OUT1D="$(PATH="$UNAME_FAIL_BIN:$PATH" env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST1" bash "$ADT_GC" --doctor 2>&1)"
assert_contains "TC-LGC8-001d: uname failure is unknown and cannot enable kill-by-default" \
  "mode_default=dry-run (source=built-in-platform-guard, ADT_GC_ENFORCE=<unset>)" "$OUT1D"

ST2="$TMPROOT/env-one"
mkdir -p "$ST2"
OUT2="$(ADT_STATE_ROOT="$ST2" ADT_GC_ENFORCE=1 bash "$ADT_GC" --doctor 2>&1)"
assert_contains "TC-LGC8-002: ADT_GC_ENFORCE=1 remains kill" \
  "mode_default=kill (source=environment, ADT_GC_ENFORCE=1)" "$OUT2"

ST3="$TMPROOT/env-zero"
mkdir -p "$ST3"
OUT3="$(ADT_STATE_ROOT="$ST3" ADT_GC_ENFORCE=0 bash "$ADT_GC" --doctor 2>&1)"
assert_contains "TC-LGC8-003: ADT_GC_ENFORCE=0 is immediate rollback" \
  "mode_default=dry-run (source=environment, ADT_GC_ENFORCE=0)" "$OUT3"

ST4="$TMPROOT/config-zero"
mkdir -p "$ST4"
printf 'ADT_GC_ENFORCE=0\n' > "$ST4/adt-gc.conf"
OUT4="$(env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST4" bash "$ADT_GC" --doctor 2>&1)"
assert_contains "TC-LGC8-004: box-wide config persists rollback" \
  "mode_default=dry-run (source=$ST4/adt-gc.conf, ADT_GC_ENFORCE=0)" "$OUT4"

ST5="$TMPROOT/config-one"
mkdir -p "$ST5"
printf 'ADT_GC_ENFORCE=1\n' > "$ST5/adt-gc.conf"
OUT5="$(env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST5" bash "$ADT_GC" --doctor 2>&1)"
assert_contains "TC-LGC8-005a: box-wide config only accepts the rollback assignment" \
  "mode_default=dry-run (source=invalid-config, ADT_GC_ENFORCE=<malformed>)" "$OUT5"
assert_contains "TC-LGC8-005b: invalid box-wide config warns" \
  "WARN: invalid config $ST5/adt-gc.conf" "$OUT5"

OUT6="$(ADT_STATE_ROOT="$ST4" ADT_GC_ENFORCE=1 bash "$ADT_GC" --doctor 2>&1)"
assert_contains "TC-LGC8-006: box-wide rollback veto overrides an enabling environment" \
  "mode_default=dry-run (source=$ST4/adt-gc.conf, ADT_GC_ENFORCE=0)" "$OUT6"

OUT7A="$(ADT_STATE_ROOT="$ST2" ADT_GC_ENFORCE=maybe bash "$ADT_GC" --doctor --dry-run 2>&1)"
assert_contains "TC-LGC8-007a: explicit --dry-run wins" \
  "mode_default=dry-run (source=argument, ADT_GC_ENFORCE=<ignored>)" "$OUT7A"
assert_not_contains "TC-LGC8-007b: explicit mode does not warn about ignored environment" \
  "WARN:" "$OUT7A"
OUT7B="$(env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST5" bash "$ADT_GC" --doctor --kill 2>&1)"
assert_contains "TC-LGC8-007c: explicit --kill wins" \
  "mode_default=kill (source=argument, ADT_GC_ENFORCE=<ignored>)" "$OUT7B"
assert_not_contains "TC-LGC8-007d: explicit mode does not warn about ignored config" \
  "WARN: invalid config" "$OUT7B"

ST8="$TMPROOT/config-invalid"
mkdir -p "$ST8"
printf 'ADT_GC_ENFORCE=maybe\n' > "$ST8/adt-gc.conf"
OUT8A="$(env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST8" bash "$ADT_GC" --doctor 2>&1)"
assert_contains "TC-LGC8-008a: invalid config fails toward dry-run" \
  "mode_default=dry-run (source=invalid-config, ADT_GC_ENFORCE=<malformed>)" "$OUT8A"
assert_contains "TC-LGC8-008b: invalid config warns" \
  "WARN: invalid config $ST8/adt-gc.conf" "$OUT8A"
OUT8B="$(ADT_STATE_ROOT="$ST1" ADT_GC_ENFORCE=maybe bash "$ADT_GC" --doctor 2>&1)"
assert_contains "TC-LGC8-008c: invalid environment fails toward dry-run" \
  "mode_default=dry-run (source=invalid-environment, ADT_GC_ENFORCE=maybe)" "$OUT8B"

ST8C="$TMPROOT/config-missing-assignment"
mkdir -p "$ST8C"
printf '# rollback intentionally documented here\n\n' > "$ST8C/adt-gc.conf"
OUT8C="$(env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST8C" bash "$ADT_GC" --doctor 2>&1)"
assert_contains "TC-LGC8-008d: config without the assignment fails toward dry-run" \
  "mode_default=dry-run (source=invalid-config, ADT_GC_ENFORCE=<malformed>)" "$OUT8C"

ST8D="$TMPROOT/config-not-sourced"
mkdir -p "$ST8D"
MARKER8D="$ST8D/must-not-exist"
printf 'ADT_GC_ENFORCE=0\ntouch %s\n' "$MARKER8D" > "$ST8D/adt-gc.conf"
OUT8D="$(env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST8D" bash "$ADT_GC" --doctor 2>&1)"
if [[ ! -e "$MARKER8D" ]]; then
  pass "TC-LGC8-008e: box-wide config is parsed as data, never sourced"
else
  fail "TC-LGC8-008e: box-wide config executed shell content"
fi
assert_contains "TC-LGC8-008f: extra config content fails toward dry-run" \
  "mode_default=dry-run (source=invalid-config, ADT_GC_ENFORCE=<malformed>)" "$OUT8D"

ST8E="$TMPROOT/config-duplicate"
mkdir -p "$ST8E"
printf 'ADT_GC_ENFORCE=0\nADT_GC_ENFORCE=0\n' > "$ST8E/adt-gc.conf"
OUT8E="$(env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST8E" bash "$ADT_GC" --doctor 2>&1)"
assert_contains "TC-LGC8-008g: duplicate rollback assignments fail toward dry-run" \
  "mode_default=dry-run (source=invalid-config, ADT_GC_ENFORCE=<malformed>)" "$OUT8E"

ST8F="$TMPROOT/config-dangling-symlink"
mkdir -p "$ST8F"
ln -s "$ST8F/missing-target" "$ST8F/adt-gc.conf"
OUT8F="$(env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST8F" bash "$ADT_GC" --doctor 2>&1)"
assert_contains "TC-LGC8-008h: dangling rollback symlink fails toward dry-run" \
  "mode_default=dry-run (source=invalid-config, ADT_GC_ENFORCE=<unreadable>)" "$OUT8F"
assert_contains "TC-LGC8-008i: dangling rollback symlink warns instead of restoring kill" \
  "WARN: invalid config $ST8F/adt-gc.conf" "$OUT8F"

echo "=== Lane-GC P8 behavioral proof ==="

make_old_pending() {
  local state_root="$1"
  local pending="$state_root/autonomous-p8/lanes/.pending-old"
  mkdir -p "$pending"
  touch -d '2 days ago' "$pending"
  printf '%s\n' "$pending"
}

ST9="$TMPROOT/default-behavior"
PENDING9="$(make_old_pending "$ST9")"
OUT9="$(env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST9" bash "$ADT_GC" --quick 2>&1)"
if [[ ! -d "$PENDING9" ]]; then
  pass "TC-LGC8-009a: default mode removes an eligible pending directory"
else
  fail "TC-LGC8-009a: default mode left eligible pending directory in place"
fi
assert_contains "TC-LGC8-009b: default mode records a real kill" "killed=1" "$OUT9"

ST9C="$TMPROOT/darwin-default-behavior"
PENDING9C="$(make_old_pending "$ST9C")"
OUT9C="$(_LANE_UNAME_OVERRIDE=Darwin env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST9C" bash "$ADT_GC" --quick 2>&1)"
if [[ -d "$PENDING9C" ]]; then
  pass "TC-LGC8-009c: Darwin platform guard preserves an eligible pending directory"
else
  fail "TC-LGC8-009c: unvalidated Darwin default removed an eligible pending directory"
fi
assert_contains "TC-LGC8-009d: Darwin platform guard reports classification only" \
  "would_kill=1 killed=0" "$OUT9C"

ST10="$TMPROOT/rollback-behavior"
mkdir -p "$ST10"
printf 'ADT_GC_ENFORCE=0\n' > "$ST10/adt-gc.conf"
PENDING10="$(make_old_pending "$ST10")"
OUT10="$(env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST10" bash "$ADT_GC" --quick 2>&1)"
if [[ -d "$PENDING10" ]]; then
  pass "TC-LGC8-010a: rollback config preserves an eligible pending directory"
else
  fail "TC-LGC8-010a: rollback config unexpectedly removed pending directory"
fi
assert_contains "TC-LGC8-010b: rollback reports would-kill" "would_kill=1" "$OUT10"
assert_contains "TC-LGC8-010c: rollback reports zero kills" "killed=0" "$OUT10"

echo "=== Lane-GC P8 timer root persistence ==="

TIMER_BIN="$TMPROOT/timer-bin"
CRON_STORE="$TMPROOT/crontab"
LINUX_TIMER_HOME="$TMPROOT/linux-timer-home"
mkdir -p "$TIMER_BIN" "$LINUX_TIMER_HOME"
cat > "$TIMER_BIN/crontab" <<'EOF'
#!/bin/bash
store="${CRONTAB_STUB_STORE:?}"
if [[ "$1" == "-l" ]]; then
  [[ -f "$store" ]] && cat "$store"
  exit 0
fi
if [[ "$1" == "-" ]]; then
  cat > "$store"
  exit 0
fi
exit 1
EOF
chmod +x "$TIMER_BIN/crontab"
CUSTOM_ROOT="$TMPROOT/custom state root"
PATH="$TIMER_BIN:$PATH" CRONTAB_STUB_STORE="$CRON_STORE" \
  HOME="$LINUX_TIMER_HOME" ADT_STATE_ROOT="$CUSTOM_ROOT" _LANE_UNAME_OVERRIDE=Linux \
  bash "$INSTALL_GC_TIMER" >/dev/null 2>&1
CRON_LINE="$(cat "$CRON_STORE" 2>/dev/null)"
assert_contains "TC-LGC8-011a: Linux timer exports the installed custom state root" \
  "ADT_STATE_ROOT='$CUSTOM_ROOT'" "$CRON_LINE"
if [[ -d "$CUSTOM_ROOT" ]]; then
  pass "TC-LGC8-011b: Linux installer creates a fresh custom state root before cron redirects into it"
else
  fail "TC-LGC8-011b: Linux installer left the custom state root absent"
fi
ROOT_POINTER="$LINUX_TIMER_HOME/.local/state/adt-state-root"
assert_eq "TC-LGC8-011ba: timer installer persists the host-wide canonical state root" \
  "$CUSTOM_ROOT" "$(cat "$ROOT_POINTER" 2>/dev/null)"
RESOLVED_ROOT="$(env -u ADT_STATE_ROOT HOME="$LINUX_TIMER_HOME" bash -c '
  source "$1"
  printf "%s\n" "$ADT_STATE_ROOT"
' _ "$LIB_LANE")"
assert_eq "TC-LGC8-011bb: an unset opportunistic caller resolves the installed custom root" \
  "$CUSTOM_ROOT" "$RESOLVED_ROOT"

env -u ADT_STATE_ROOT PATH="$TIMER_BIN:$PATH" CRONTAB_STUB_STORE="$CRON_STORE" \
  HOME="$LINUX_TIMER_HOME" _LANE_UNAME_OVERRIDE=Linux \
  bash "$INSTALL_GC_TIMER" >/dev/null 2>&1
assert_eq "TC-LGC8-011bc: installer re-run without an explicit root preserves the host pointer" \
  "$CUSTOM_ROOT" "$(cat "$ROOT_POINTER" 2>/dev/null)"
assert_contains "TC-LGC8-011bd: installer re-run without an explicit root preserves the scheduled root" \
  "ADT_STATE_ROOT='$CUSTOM_ROOT'" "$(cat "$CRON_STORE" 2>/dev/null)"

NO_READLINK_F_BIN="$TMPROOT/no-readlink-f-bin"
REAL_READLINK="$(command -v readlink)"
mkdir -p "$NO_READLINK_F_BIN"
cat > "$NO_READLINK_F_BIN/readlink" <<'EOF'
#!/bin/bash
[[ "${1:-}" == "-f" ]] && exit 1
exec "${REAL_READLINK:?}" "$@"
EOF
chmod +x "$NO_READLINK_F_BIN/readlink"
NO_READLINK_F_LANE="$(env -u ADT_STATE_ROOT HOME="$LINUX_TIMER_HOME" \
  REAL_READLINK="$REAL_READLINK" PATH="$NO_READLINK_F_BIN:$PATH" \
  bash -c 'source "$1"; printf "%s\n" "$ADT_STATE_ROOT"' _ "$LIB_LANE")"
assert_eq "TC-LGC8-011be: lib-lane resolves its sibling state-root library without GNU readlink -f" \
  "$CUSTOM_ROOT" "$NO_READLINK_F_LANE"

SYMLINK_POINTER_HOME="$TMPROOT/symlink-pointer-home"
SYMLINK_POINTER_TARGET="$TMPROOT/symlink-pointer-target"
mkdir -p "$SYMLINK_POINTER_HOME/.local/state"
printf '%s\n' "$TMPROOT/must-not-be-selected" > "$SYMLINK_POINTER_TARGET"
ln -s "$SYMLINK_POINTER_TARGET" "$SYMLINK_POINTER_HOME/.local/state/adt-state-root"
SYMLINK_POINTER_OUT="$(env -u ADT_STATE_ROOT HOME="$SYMLINK_POINTER_HOME" \
  bash -c 'source "$1"; printf "ROOT=%s\n" "$ADT_STATE_ROOT"' _ "$LIB_LANE" 2>&1)"
assert_contains "TC-LGC8-011bf: a symlinked host pointer warns and fails closed" \
  "WARN: invalid host state-root pointer" "$SYMLINK_POINTER_OUT"
assert_contains "TC-LGC8-011bg: a symlinked host pointer falls back instead of following its target" \
  "ROOT=$SYMLINK_POINTER_HOME/.local/state" "$SYMLINK_POINTER_OUT"

LAUNCH_BIN="$TMPROOT/launch-bin"
LAUNCH_LOG="$TMPROOT/launchctl.log"
FAKE_HOME="$TMPROOT/fake-home"
MAC_CUSTOM_ROOT="$TMPROOT/custom mac state root"
mkdir -p "$LAUNCH_BIN" "$FAKE_HOME"
cat > "$LAUNCH_BIN/launchctl" <<EOF
#!/bin/bash
echo "\$*" >> "$LAUNCH_LOG"
exit 0
EOF
chmod +x "$LAUNCH_BIN/launchctl"
PATH="$LAUNCH_BIN:$PATH" HOME="$FAKE_HOME" ADT_STATE_ROOT="$MAC_CUSTOM_ROOT" \
  _LANE_UNAME_OVERRIDE=Darwin bash "$INSTALL_GC_TIMER" >/dev/null 2>&1
PLIST="$FAKE_HOME/Library/LaunchAgents/com.adt.lane-gc.plist"
PLIST_CONTENT="$(cat "$PLIST" 2>/dev/null)"
assert_contains "TC-LGC8-011c: launchd plist declares an environment dictionary" \
  "<key>EnvironmentVariables</key>" "$PLIST_CONTENT"
assert_contains "TC-LGC8-011d: launchd passes ADT_STATE_ROOT to GC" \
  "<key>ADT_STATE_ROOT</key>" "$PLIST_CONTENT"
assert_contains "TC-LGC8-011e: launchd persists the installed custom state root" \
  "<string>$MAC_CUSTOM_ROOT</string>" "$PLIST_CONTENT"
if [[ -d "$MAC_CUSTOM_ROOT" ]]; then
  pass "TC-LGC8-011f: macOS installer creates a fresh custom state root before launchd opens its log"
else
  fail "TC-LGC8-011f: macOS installer left the custom state root absent"
fi

RELATIVE_OUT="$(cd "$TMPROOT" && \
  PATH="$TIMER_BIN:$PATH" CRONTAB_STUB_STORE="$TMPROOT/relative-crontab" \
  HOME="$LINUX_TIMER_HOME" ADT_STATE_ROOT="relative-state" _LANE_UNAME_OVERRIDE=Linux \
  bash "$INSTALL_GC_TIMER" 2>&1; printf 'RC=%s\n' "$?")"
assert_contains "TC-LGC8-011g: timer rejects a relative ADT_STATE_ROOT" \
  "ADT_STATE_ROOT must be absolute" "$RELATIVE_OUT"
assert_contains "TC-LGC8-011h: relative ADT_STATE_ROOT rejection exits non-zero" \
  "RC=1" "$RELATIVE_OUT"

FAIL_CRON_HOME="$TMPROOT/fail-cron-home"
FAIL_CRON_ROOT="$TMPROOT/fail-cron-root"
FAIL_CRON_STORE="$TMPROOT/fail-cron-store"
FAIL_CRON_BIN="$TMPROOT/fail-cron-bin"
mkdir -p "$FAIL_CRON_HOME/.local/state" "$FAIL_CRON_BIN"
printf '%s\n' "$TMPROOT/previous-root" > "$FAIL_CRON_HOME/.local/state/adt-state-root"
cat > "$FAIL_CRON_BIN/crontab" <<'EOF'
#!/bin/bash
if [[ "$1" == "-l" ]]; then
  printf '%s\n' '17 * * * * operator-job'
  exit 0
fi
if [[ "$1" == "-" ]]; then
  cat > "${CRONTAB_STUB_STORE:?}"
  exit 42
fi
exit 1
EOF
chmod +x "$FAIL_CRON_BIN/crontab"
FAIL_CRON_OUT="$(PATH="$FAIL_CRON_BIN:$PATH" CRONTAB_STUB_STORE="$FAIL_CRON_STORE" \
  HOME="$FAIL_CRON_HOME" ADT_STATE_ROOT="$FAIL_CRON_ROOT" _LANE_UNAME_OVERRIDE=Linux \
  bash "$INSTALL_GC_TIMER" 2>&1; printf 'RC=%s\n' "$?")"
assert_contains "TC-LGC8-011i: a failed crontab update returns non-zero" "RC=1" "$FAIL_CRON_OUT"
assert_eq "TC-LGC8-011j: a failed crontab update leaves the prior root pointer intact" \
  "$TMPROOT/previous-root" "$(cat "$FAIL_CRON_HOME/.local/state/adt-state-root")"

FAIL_POINTER_HOME="$TMPROOT/fail-pointer-home"
FAIL_POINTER_ROOT="$TMPROOT/fail-pointer-root"
FAIL_POINTER_STORE="$TMPROOT/fail-pointer-store"
FAIL_POINTER_BIN="$TMPROOT/fail-pointer-bin"
mkdir -p "$FAIL_POINTER_HOME" "$FAIL_POINTER_BIN"
printf '%s\n' '23 * * * * previous-operator-job' > "$FAIL_POINTER_STORE"
cat > "$FAIL_POINTER_BIN/crontab" <<'EOF'
#!/bin/bash
store="${CRONTAB_STUB_STORE:?}"
if [[ "$1" == "-l" ]]; then
  cat "$store"
  exit 0
fi
if [[ "$1" == "-" ]]; then
  cat > "$store"
  exit 0
fi
exit 1
EOF
cat > "$FAIL_POINTER_BIN/mktemp" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$FAIL_POINTER_BIN/crontab" "$FAIL_POINTER_BIN/mktemp"
FAIL_POINTER_OUT="$(PATH="$FAIL_POINTER_BIN:$PATH" CRONTAB_STUB_STORE="$FAIL_POINTER_STORE" \
  HOME="$FAIL_POINTER_HOME" ADT_STATE_ROOT="$FAIL_POINTER_ROOT" _LANE_UNAME_OVERRIDE=Linux \
  bash "$INSTALL_GC_TIMER" 2>&1; printf 'RC=%s\n' "$?")"
assert_contains "TC-LGC8-011k: pointer persistence failure returns non-zero" "RC=1" "$FAIL_POINTER_OUT"
assert_eq "TC-LGC8-011l: pointer persistence failure restores the prior crontab" \
  "23 * * * * previous-operator-job" "$(cat "$FAIL_POINTER_STORE")"

LOCAL_DEFER_PATH="$(env -u ADT_STATE_ROOT HOME="$LINUX_TIMER_HOME" \
  REPO=owner/repo REPO_OWNER=owner PROJECT_ID=p8root bash -c '
    source "$1"
    _local_defer_marker_path issue 118
  ' _ "$LIB_DISPATCH")"
assert_eq "TC-LGC8-011m: local dispatcher defer-marker reader resolves the host root pointer" \
  "$CUSTOM_ROOT/autonomous-p8root/lanes/.defer-issue-118" "$LOCAL_DEFER_PATH"

REMOTE_PROJECT_ID="p8remote"
REMOTE_LANE_DIR="$CUSTOM_ROOT/autonomous-$REMOTE_PROJECT_ID/lanes"
mkdir -p "$REMOTE_LANE_DIR"
touch "$REMOTE_LANE_DIR/.attempt-issue-118" "$REMOTE_LANE_DIR/.defer-issue-118"
REMOTE_STUB_BIN="$TMPROOT/remote-root-bin"
REMOTE_RESULT="$TMPROOT/remote-root-result"
mkdir -p "$REMOTE_STUB_BIN"
cat > "$REMOTE_STUB_BIN/aws" <<'EOF'
#!/bin/bash
case "$*" in
  *send-command*)
    prev=""
    params_json=""
    for arg in "$@"; do
      [[ "$prev" == "--parameters" ]] && params_json="$arg"
      prev="$arg"
    done
    full_cmd="$(printf '%s' "$params_json" | jq -r '.commands[0]')"
    b64="$(printf '%s' "$full_cmd" | grep -oE 'printf %s [A-Za-z0-9+/=]+ \| base64 -d' | sed -E 's/^printf %s //; s/ \| base64 -d$//')"
    inner_cmd="$(printf '%s' "$b64" | base64 -d)"
    env -u ADT_STATE_ROOT HOME="${REMOTE_TEST_HOME:?}" bash -c "$inner_cmd" > "${REMOTE_TEST_RESULT:?}" 2>/dev/null || true
    echo '{"Command":{"CommandId":"stub-root-1","Status":"Pending"}}'
    ;;
  *get-command-invocation*)
    out="$(cat "${REMOTE_TEST_RESULT:?}" 2>/dev/null || true)"
    jq -n --arg out "$out" '{"Status":"Success","StandardOutputContent":$out,"StandardErrorContent":""}'
    ;;
esac
EOF
chmod +x "$REMOTE_STUB_BIN/aws"
REMOTE_DEFER_OUT="$(PATH="$REMOTE_STUB_BIN:$PATH" REMOTE_TEST_HOME="$LINUX_TIMER_HOME" \
  REMOTE_TEST_RESULT="$REMOTE_RESULT" SSM_INSTANCE_ID=i-p8-root \
  SSM_REMOTE_PROJECT_ID="$REMOTE_PROJECT_ID" SSM_REMOTE_PROJECT_DIR=/tmp \
  bash "$LIVENESS_DRIVER" issue 118)"
assert_contains "TC-LGC8-011n: remote liveness defer-marker reader resolves the host root pointer" \
  "DEFERRED" "$REMOTE_DEFER_OUT"

MAC_FAIL_HOME="$TMPROOT/mac-fail-home"
MAC_FAIL_BIN="$TMPROOT/mac-fail-bin"
MAC_FAIL_LOG="$TMPROOT/mac-fail-launchctl.log"
MAC_FAIL_ROOT="$TMPROOT/mac-fail-root"
MAC_OLD_ROOT="$TMPROOT/mac-old-root"
MAC_OLD_PLIST="old-plist-sentinel"
mkdir -p "$MAC_FAIL_HOME/.local/state" "$MAC_FAIL_HOME/Library/LaunchAgents" "$MAC_FAIL_BIN"
printf '%s\n' "$MAC_OLD_ROOT" > "$MAC_FAIL_HOME/.local/state/adt-state-root"
printf '%s\n' "$MAC_OLD_PLIST" > "$MAC_FAIL_HOME/Library/LaunchAgents/com.adt.lane-gc.plist"
cat > "$MAC_FAIL_BIN/launchctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "${LAUNCHCTL_STUB_LOG:?}"
[[ "$1" == "bootstrap" ]] && exit 42
exit 0
EOF
chmod +x "$MAC_FAIL_BIN/launchctl"
MAC_FAIL_OUT="$(PATH="$MAC_FAIL_BIN:$PATH" HOME="$MAC_FAIL_HOME" ADT_STATE_ROOT="$MAC_FAIL_ROOT" \
  LAUNCHCTL_STUB_LOG="$MAC_FAIL_LOG" _LANE_UNAME_OVERRIDE=Darwin \
  bash "$INSTALL_GC_TIMER" 2>&1; printf 'RC=%s\n' "$?")"
assert_contains "TC-LGC8-011o: failed launchd bootstrap returns non-zero" "RC=1" "$MAC_FAIL_OUT"
assert_eq "TC-LGC8-011oa: failed launchd bootstrap restores the prior root pointer" \
  "$MAC_OLD_ROOT" "$(cat "$MAC_FAIL_HOME/.local/state/adt-state-root")"
assert_eq "TC-LGC8-011p: failed launchd bootstrap restores the prior plist" \
  "$MAC_OLD_PLIST" "$(cat "$MAC_FAIL_HOME/Library/LaunchAgents/com.adt.lane-gc.plist")"

echo "=== Lane-GC P8 delayed-reap process identity ==="

make_dead_lane() {
  local state_root="$1" project="$2" issue="$3"
  ADT_STATE_ROOT="$state_root" ADT_LANE_BACKEND_OVERRIDE=pgid bash -c '
    source "$1"
    lane_id="$(lane_mint "$2" dev "$3")"
    lane_dir="$(lane_install "$2" "$lane_id")"
    lane_set "$lane_dir" WRAPPER_PID 999999
    lane_set "$lane_dir" CREATED_EPOCH "$(( $(date +%s) - 900 ))"
    printf "%s\n" "$lane_dir"
  ' _ "$LIB_LANE" "$project" "$issue"
}

ST12="$TMPROOT/identity-match"
LANE12="$(make_dead_lane "$ST12" p8identity 12)"
setsid sleep 30 &
PG12=$!
SPAWNED_GROUPS+=("$PG12")
ADT_STATE_ROOT="$ST12" bash -c '
  source "$1"
  lane_record_pgid "$2" "$3" agent
' _ "$LIB_LANE" "$LANE12" "$PG12"
PGID_FIELDS12="$(awk 'NR==1 { print NF }' "$LANE12/pgids")"
assert_eq "TC-LGC8-012a: new PGID records include a process identity field" "4" "$PGID_FIELDS12"
IDENTITY12="$(awk 'NR==1 { print $4 }' "$LANE12/pgids")"
if [[ "$IDENTITY12" =~ ^v2-linux:[0-9a-fA-F-]{36}:[0-9]+$ ]]; then
  pass "TC-LGC8-012aa: Linux identity binds start ticks to the current boot ID"
else
  fail "TC-LGC8-012aa: Linux identity is not boot-bound: $IDENTITY12"
fi
BOOT_STATUS12="$(ADT_STATE_ROOT="$ST12" bash -c '
  source "$1"
  proc_boot_id() { printf "00000000-0000-0000-0000-000000000000\n"; }
  proc_identity_status "$2" "$3"
  printf "RC=%s\n" "$?"
' _ "$LIB_LANE" "$PG12" "$IDENTITY12")"
assert_contains "TC-LGC8-012ab: a different boot ID invalidates the same PID/start ticks" \
  "RC=1" "$BOOT_STATUS12"
STDERR_DIR12="$TMPROOT/pgid-record-stderr"
mkdir -p "$STDERR_DIR12"
: > "$STDERR_DIR12/pgids"
: > "$STDERR_DIR12/pgids.lock"
STDERR12="$(ADT_STATE_ROOT="$ST12" bash -c '
  source "$1"
  lane_record_pgid "$2" "$$" test
  echo stderr-preserved >&2
' _ "$LIB_LANE" "$STDERR_DIR12" 2>&1 >/dev/null)"
assert_contains "TC-LGC8-012b: PGID lock open does not permanently suppress caller stderr" \
  "stderr-preserved" "$STDERR12"
OUT12="$(env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST12" bash "$ADT_GC" --quick 2>&1)"
sleep 0.2
if kill -0 -- "-$PG12" 2>/dev/null; then
  fail "TC-LGC8-012c: identity-matched PGID survived strict GC"
else
  pass "TC-LGC8-012c: identity-matched PGID is reaped by strict GC"
fi
assert_contains "TC-LGC8-012d: identity-matched reap is counted" "killed=1" "$OUT12"

ST13="$TMPROOT/identity-mismatch"
LANE13="$(make_dead_lane "$ST13" p8identity 13)"
setsid sleep 30 &
PG13=$!
SPAWNED_GROUPS+=("$PG13")
ADT_STATE_ROOT="$ST13" bash -c '
  source "$1"
  lane_record_pgid "$2" "$3" agent
' _ "$LIB_LANE" "$LANE13" "$PG13"
awk '{$4="v1-linux:1"; print}' "$LANE13/pgids" > "$LANE13/pgids.tmp"
mv "$LANE13/pgids.tmp" "$LANE13/pgids"
OUT13="$(env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST13" bash "$ADT_GC" --quick 2>&1)"
if kill -0 -- "-$PG13" 2>/dev/null; then
  pass "TC-LGC8-013a: recycled PGID identity is never signaled"
else
  fail "TC-LGC8-013a: recycled PGID identity was killed"
fi
assert_contains "TC-LGC8-013b: recycled PGID refusal is logged" \
  "reason=pgid-identity-unverifiable" "$(cat "$ST13/adt-gc.log" 2>/dev/null)"
assert_not_contains "TC-LGC8-013c: refused lane is not marked gc-reaped" \
  "STATE=gc-reaped" "$(cat "$LANE13/lane" 2>/dev/null)"
ADT_STATE_ROOT="$ST13" bash -c '
  source "$1"
  lane_pgid_identities_verified "$2"
' _ "$LIB_LANE" "$LANE13"
RC13D=$?
assert_eq "TC-LGC8-013d: direct identity preflight does not depend on a caller-local lane_dir" \
  "3" "$RC13D"

ST14="$TMPROOT/identity-legacy"
LANE14="$(make_dead_lane "$ST14" p8identity 14)"
setsid sleep 30 &
PG14=$!
SPAWNED_GROUPS+=("$PG14")
printf '%s agent %s\n' "$PG14" "$(date +%s)" > "$LANE14/pgids"
env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST14" bash "$ADT_GC" --quick >/dev/null 2>&1
if kill -0 -- "-$PG14" 2>/dev/null; then
  pass "TC-LGC8-014a: legacy identity-less PGID fails toward leak"
else
  fail "TC-LGC8-014a: legacy identity-less PGID was killed"
fi
assert_contains "TC-LGC8-014b: legacy PGID refusal is logged" \
  "reason=pgid-identity-unverifiable" "$(cat "$ST14/adt-gc.log" 2>/dev/null)"
START14="$(ADT_STATE_ROOT="$ST14" bash -c 'source "$1"; proc_start_time "$2"' _ "$LIB_LANE" "$PG14")"
printf '%s agent %s v1-linux:%s\n' "$PG14" "$(date +%s)" "$START14" > "$LANE14/pgids"
V1_RC14="$(ADT_STATE_ROOT="$ST14" bash -c '
  source "$1"
  lane_pgid_identities_verified "$2"
  printf "RC=%s\n" "$?"
' _ "$LIB_LANE" "$LANE14")"
assert_contains "TC-LGC8-014c: pre-boot-ID v1 identity cannot authorize delayed signaling" \
  "RC=3" "$V1_RC14"

make_terminal_lane_with_guardian() {
  local state_root="$1" project="$2" issue="$3" guardian_pid="$4" identity="$5"
  ADT_STATE_ROOT="$state_root" ADT_LANE_BACKEND_OVERRIDE=pgid bash -c '
    source "$1"
    lane_id="$(lane_mint "$2" dev "$3")"
    lane_dir="$(lane_install "$2" "$lane_id")"
    lane_set "$lane_dir" WRAPPER_PID 999999
    lane_set "$lane_dir" GUARDIAN_IDENTITY "$5"
    lane_set "$lane_dir" GUARDIAN_PID "$4"
    lane_set "$lane_dir" STATE clean-exit
    touch -d "@$(( $(date +%s) - 90000 ))" "$lane_dir/lane"
    printf "%s\n" "$lane_dir"
  ' _ "$LIB_LANE" "$project" "$issue" "$guardian_pid" "$identity"
}

setsid sleep 30 &
GUARD15=$!
SPAWNED_GROUPS+=("$GUARD15")
ST15="$TMPROOT/guardian-mismatch"
GUARD_ID15="$(ADT_STATE_ROOT="$ST15" bash -c 'source "$1"; proc_identity "$2"' _ "$LIB_LANE" "$GUARD15")"
LANE15="$(make_terminal_lane_with_guardian "$ST15" p8guardian 15 "$GUARD15" "${GUARD_ID15%:*}:0")"
env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST15" bash "$ADT_GC" --quick >/dev/null 2>&1
if kill -0 "$GUARD15" 2>/dev/null; then
  pass "TC-LGC8-015a: recycled guardian PID is never signaled"
else
  fail "TC-LGC8-015a: recycled guardian PID was killed"
fi
if [[ ! -d "$LANE15" ]]; then
  pass "TC-LGC8-015b: proven-recycled guardian does not pin stale terminal metadata"
else
  fail "TC-LGC8-015b: proven-recycled guardian left the stale lane directory"
fi

setsid sleep 30 &
GUARD16=$!
SPAWNED_GROUPS+=("$GUARD16")
ST16="$TMPROOT/guardian-legacy"
LANE16="$(make_terminal_lane_with_guardian "$ST16" p8guardian 16 "$GUARD16" "-")"
env -u ADT_GC_ENFORCE ADT_STATE_ROOT="$ST16" bash "$ADT_GC" --quick >/dev/null 2>&1
if kill -0 "$GUARD16" 2>/dev/null; then
  pass "TC-LGC8-016a: legacy identity-less guardian is never signaled"
else
  fail "TC-LGC8-016a: legacy identity-less guardian was killed"
fi
if [[ -d "$LANE16" ]]; then
  pass "TC-LGC8-016b: unverifiable live guardian preserves its lane metadata"
else
  fail "TC-LGC8-016b: unverifiable live guardian lane was removed"
fi

setsid sleep 30 &
PID17=$!
SPAWNED_GROUPS+=("$PID17")
OUT17="$(_LANE_UNAME_OVERRIDE=Darwin bash -c '
  source "$1"
  identity="$(proc_identity "$2")" || exit 10
  printf "IDENTITY=%s\n" "$identity"
  proc_identity_status "$2" "$identity"
  printf "MATCH_RC=%s\n" "$?"
  bad_identity="${identity%:*}:0000000000000000000000000000000000000000000000000000000000000000"
  proc_identity_status "$2" "$bad_identity"
  printf "MISMATCH_RC=%s\n" "$?"
  proc_identity_status "$2" "v1-bsd:malformed"
  printf "MALFORMED_RC=%s\n" "$?"
' _ "$LIB_LANE" "$PID17")"
IDENTITY17="$(printf '%s\n' "$OUT17" | sed -n 's/^IDENTITY=//p')"
if [[ "$IDENTITY17" =~ ^v1-bsd:[0-9]+:[0-9a-fA-F]{64}$ ]]; then
  pass "TC-LGC8-017a: BSD identity is compact and whitespace-free"
else
  fail "TC-LGC8-017a: malformed BSD identity '$IDENTITY17'"
fi
assert_contains "TC-LGC8-017b: exact BSD identity matches" "MATCH_RC=0" "$OUT17"
assert_contains "TC-LGC8-017c: changed BSD fingerprint proves mismatch" "MISMATCH_RC=1" "$OUT17"
assert_contains "TC-LGC8-017d: malformed BSD identity is unverifiable" "MALFORMED_RC=2" "$OUT17"
OUT17E="$(_LANE_UNAME_OVERRIDE=Darwin bash -c '
  source "$1"
  identity="$(proc_identity "$2")" || exit 10
  proc_identity_authorizes_signal "$2" "$identity"
  printf "AUTH_RC=%s\n" "$?"
' _ "$LIB_LANE" "$PID17" 2>&1)"
AUTH_RC17E="$(printf '%s\n' "$OUT17E" | sed -n 's/^AUTH_RC=//p')"
assert_eq "TC-LGC8-017e: diagnostic BSD identity cannot authorize delayed signaling" \
  "1" "$AUTH_RC17E"

echo "=== Lane-GC P8 signal-time identity races ==="

ST18="$TMPROOT/strict-whole-lane"
LANE18="$(make_dead_lane "$ST18" p8identity 18)"
setsid sleep 30 &
PG18A=$!
setsid sleep 30 &
PG18B=$!
SPAWNED_GROUPS+=("$PG18A" "$PG18B")
ADT_STATE_ROOT="$ST18" bash -c '
  source "$1"
  lane_record_pgid "$2" "$3" agent-a
  lane_record_pgid "$2" "$4" agent-b
' _ "$LIB_LANE" "$LANE18" "$PG18A" "$PG18B"
COUNT18="$TMPROOT/strict-whole-lane.count"
printf '0\n' > "$COUNT18"
OUT18="$(ADT_STATE_ROOT="$ST18" TEST_COUNT18="$COUNT18" bash -c '
  source "$1"
  proc_identity_authorizes_signal() {
    local n
    n="$(( $(cat "$TEST_COUNT18") + 1 ))"
    printf "%s\n" "$n" > "$TEST_COUNT18"
    [[ "$n" -eq 4 ]] && return 1
    proc_identity_is_durable "$2" && proc_identity_status "$1" "$2"
  }
  lane_kill "$2" 1 require-identity
  printf "RC=%s\n" "$?"
' _ "$LIB_LANE" "$LANE18")"
assert_contains "TC-LGC8-018a: second-pass identity refusal returns the strict refusal status" \
  "RC=3" "$OUT18"
if kill -0 -- "-$PG18A" 2>/dev/null && kill -0 -- "-$PG18B" 2>/dev/null; then
  pass "TC-LGC8-018b: second-pass refusal sends no partial signal to any group in the lane"
else
  fail "TC-LGC8-018b: strict refusal partially signaled the lane"
fi

ST18C="$TMPROOT/strict-scope-refusal"
LANE18C="$(make_dead_lane "$ST18C" p8identity 18c)"
setsid sleep 30 &
PG18C=$!
SPAWNED_GROUPS+=("$PG18C")
ADT_STATE_ROOT="$ST18C" bash -c '
  source "$1"
  lane_record_pgid "$2" "$3" agent
  lane_set "$2" BACKEND systemd-scope
  lane_set "$2" UNIT adt-p8-scope-refusal
' _ "$LIB_LANE" "$LANE18C" "$PG18C"
SCOPE_MARKER18C="$TMPROOT/strict-scope-systemctl.marker"
SCOPE_BIN18C="$TMPROOT/strict-scope-bin"
mkdir -p "$SCOPE_BIN18C"
cat > "$SCOPE_BIN18C/systemctl" <<EOF
#!/bin/bash
touch "$SCOPE_MARKER18C"
exit 0
EOF
chmod +x "$SCOPE_BIN18C/systemctl"
OUT18C="$(PATH="$SCOPE_BIN18C:$PATH" ADT_STATE_ROOT="$ST18C" bash -c '
  source "$1"
  lane_kill "$2" 1 require-identity
  printf "RC=%s\n" "$?"
' _ "$LIB_LANE" "$LANE18C")"
assert_contains "TC-LGC8-018c: strict delayed GC refuses systemd-scope until full-wrapper enrollment lands" \
  "RC=3" "$OUT18C"
if kill -0 -- "-$PG18C" 2>/dev/null && [[ ! -e "$SCOPE_MARKER18C" ]]; then
  pass "TC-LGC8-018d: strict scope refusal sends no scope or group signal"
else
  fail "TC-LGC8-018d: strict scope refusal signaled a live target"
fi

for backend_case in missing unknown; do
  state_root="$TMPROOT/strict-backend-$backend_case"
  lane_dir="$(make_dead_lane "$state_root" p8identity "18-$backend_case")"
  setsid sleep 30 &
  pg=$!
  SPAWNED_GROUPS+=("$pg")
  ADT_STATE_ROOT="$state_root" bash -c '
    source "$1"
    lane_record_pgid "$2" "$3" agent
    if [[ "$4" == "missing" ]]; then
      sed -i "/^BACKEND=/d" "$2/lane"
    else
      lane_set "$2" BACKEND unknown-backend
    fi
  ' _ "$LIB_LANE" "$lane_dir" "$pg" "$backend_case"
  out="$(ADT_STATE_ROOT="$state_root" bash -c '
    source "$1"
    lane_kill "$2" 0 require-identity
    printf "RC=%s\n" "$?"
  ' _ "$LIB_LANE" "$lane_dir")"
  assert_contains "TC-LGC8-018h-$backend_case: strict reap accepts only exact BACKEND=pgid" \
    "RC=3" "$out"
  if kill -0 -- "-$pg" 2>/dev/null; then
    pass "TC-LGC8-018i-$backend_case: non-pgid backend refusal sends no signal"
  else
    fail "TC-LGC8-018i-$backend_case: non-pgid backend was signaled"
  fi
done

ST18J="$TMPROOT/invalid-policy"
LANE18J="$(make_dead_lane "$ST18J" p8identity 18j)"
setsid sleep 30 &
PG18J=$!
SPAWNED_GROUPS+=("$PG18J")
ADT_STATE_ROOT="$ST18J" bash -c '
  source "$1"
  lane_record_pgid "$2" "$3" agent
' _ "$LIB_LANE" "$LANE18J" "$PG18J"
OUT18J="$(ADT_STATE_ROOT="$ST18J" bash -c '
  source "$1"
  lane_kill "$2" 0 require-identty
  printf "RC=%s\n" "$?"
' _ "$LIB_LANE" "$LANE18J")"
assert_contains "TC-LGC8-018j: unknown lane_kill identity policy is rejected" "RC=2" "$OUT18J"
if kill -0 -- "-$PG18J" 2>/dev/null; then
  pass "TC-LGC8-018k: invalid identity policy sends no signal"
else
  fail "TC-LGC8-018k: invalid identity policy fell through to best-effort signaling"
fi

ST18E="$TMPROOT/strict-reap-lock"
LANE18E="$(make_dead_lane "$ST18E" p8identity 18e)"
setsid sleep 30 &
PG18E=$!
SPAWNED_GROUPS+=("$PG18E")
ADT_STATE_ROOT="$ST18E" bash -c '
  source "$1"
  lane_record_pgid "$2" "$3" agent
' _ "$LIB_LANE" "$LANE18E" "$PG18E"
rm -f "$LANE18E/reap.lock"
OUT18E="$(ADT_STATE_ROOT="$ST18E" bash -c '
  source "$1"
  lane_kill "$2" 1 require-identity
  printf "RC=%s\n" "$?"
' _ "$LIB_LANE" "$LANE18E")"
assert_contains "TC-LGC8-018e: strict reap without reap.lock returns refusal" "RC=3" "$OUT18E"
if kill -0 -- "-$PG18E" 2>/dev/null; then
  pass "TC-LGC8-018f: missing strict reap.lock sends no signal"
else
  fail "TC-LGC8-018f: strict reap signaled without owning reap.lock"
fi

setsid sleep 30 &
PG18G=$!
SPAWNED_GROUPS+=("$PG18G")
BEFORE18G="$(wc -l < "$LANE18/pgids" | tr -d ' ')"
ADT_STATE_ROOT="$ST18" bash -c '
  source "$1"
  lane_record_pgid "$2" "$3" late-agent
' _ "$LIB_LANE" "$LANE18" "$PG18G"
AFTER18G="$(wc -l < "$LANE18/pgids" | tr -d ' ')"
if [[ -f "$LANE18/pgids.closed" && "$BEFORE18G" == "$AFTER18G" ]]; then
  pass "TC-LGC8-018g: strict snapshot closes PGID registration under pgids.lock"
else
  fail "TC-LGC8-018g: a late PGID append escaped the strict snapshot"
fi

ST18L="$TMPROOT/strict-term-signal-time"
LANE18L="$(make_dead_lane "$ST18L" p8identity 18l)"
TERM18LA="$TMPROOT/strict-term-a.marker"
TERM18LB="$TMPROOT/strict-term-b.marker"
setsid bash -c 'trap "touch \"$1\"" TERM; while :; do sleep 1; done' _ "$TERM18LA" &
PG18LA=$!
setsid bash -c 'trap "touch \"$1\"" TERM; while :; do sleep 1; done' _ "$TERM18LB" &
PG18LB=$!
SPAWNED_GROUPS+=("$PG18LA" "$PG18LB")
ADT_STATE_ROOT="$ST18L" bash -c '
  source "$1"
  lane_record_pgid "$2" "$3" agent-a
  lane_record_pgid "$2" "$4" agent-b
' _ "$LIB_LANE" "$LANE18L" "$PG18LA" "$PG18LB"
COUNT18L="$TMPROOT/strict-term-signal-time.count"
printf '0\n' > "$COUNT18L"
OUT18L="$(ADT_STATE_ROOT="$ST18L" TEST_COUNT18L="$COUNT18L" bash -c '
  source "$1"
  eval "$(declare -f proc_identity_authorizes_signal | sed "1s/proc_identity_authorizes_signal/_orig_proc_identity_authorizes_signal/")"
  proc_identity_authorizes_signal() {
    local n
    n="$(( $(cat "$TEST_COUNT18L") + 1 ))"
    printf "%s\n" "$n" > "$TEST_COUNT18L"
    [[ "$n" -eq 6 ]] && return 1
    _orig_proc_identity_authorizes_signal "$@"
  }
  lane_kill "$2" 1 require-identity
  printf "RC=%s\n" "$?"
' _ "$LIB_LANE" "$LANE18L")"
sleep 0.2
assert_contains "TC-LGC8-018l: TERM signal-time identity refusal returns strict status" "RC=3" "$OUT18L"
if [[ -f "$TERM18LA" && ! -f "$TERM18LB" ]]; then
  pass "TC-LGC8-018m: TERM signal-time refusal stops before the changed and remaining groups"
else
  fail "TC-LGC8-018m: TERM signal-time refusal did not stop the remaining signals"
fi

ST18N="$TMPROOT/strict-kill-signal-time"
LANE18N="$(make_dead_lane "$ST18N" p8identity 18n)"
TERM18NA="$TMPROOT/strict-kill-a-term.marker"
TERM18NB="$TMPROOT/strict-kill-b-term.marker"
setsid bash -c 'trap "touch \"$1\"" TERM; while :; do sleep 1; done' _ "$TERM18NA" &
PG18NA=$!
setsid bash -c 'trap "touch \"$1\"" TERM; while :; do sleep 1; done' _ "$TERM18NB" &
PG18NB=$!
SPAWNED_GROUPS+=("$PG18NA" "$PG18NB")
ADT_STATE_ROOT="$ST18N" bash -c '
  source "$1"
  lane_record_pgid "$2" "$3" agent-a
  lane_record_pgid "$2" "$4" agent-b
' _ "$LIB_LANE" "$LANE18N" "$PG18NA" "$PG18NB"
COUNT18N="$TMPROOT/strict-kill-signal-time.count"
printf '0\n' > "$COUNT18N"
OUT18N="$(ADT_STATE_ROOT="$ST18N" TEST_COUNT18N="$COUNT18N" bash -c '
  source "$1"
  eval "$(declare -f proc_identity_authorizes_signal | sed "1s/proc_identity_authorizes_signal/_orig_proc_identity_authorizes_signal/")"
  proc_identity_authorizes_signal() {
    local n
    n="$(( $(cat "$TEST_COUNT18N") + 1 ))"
    printf "%s\n" "$n" > "$TEST_COUNT18N"
    [[ "$n" -eq 10 ]] && return 1
    _orig_proc_identity_authorizes_signal "$@"
  }
  lane_kill "$2" 1 require-identity
  printf "RC=%s\n" "$?"
' _ "$LIB_LANE" "$LANE18N")"
sleep 0.2
assert_contains "TC-LGC8-018n: KILL signal-time identity refusal returns strict status" "RC=3" "$OUT18N"
if ! kill -0 -- "-$PG18NA" 2>/dev/null && kill -0 -- "-$PG18NB" 2>/dev/null; then
  pass "TC-LGC8-018o: KILL signal-time refusal stops before the changed and remaining groups"
else
  fail "TC-LGC8-018o: KILL signal-time refusal did not stop the remaining signals"
fi

MARKER19="$TMPROOT/guardian-term.marker"
setsid bash -c 'trap "touch \"$1\"" TERM; while :; do sleep 1; done' _ "$MARKER19" &
PID19=$!
SPAWNED_GROUPS+=("$PID19")
sleep 0.2
IDENTITY19="$(ADT_STATE_ROOT="$TMPROOT/helper-identity" bash -c 'source "$1"; proc_identity "$2"' _ "$LIB_LANE" "$PID19")"
COUNT19="$TMPROOT/guardian-signal.count"
printf '0\n' > "$COUNT19"
OUT19="$(ADT_STATE_ROOT="$TMPROOT/helper-identity" TEST_COUNT19="$COUNT19" bash -c '
  source "$1"
  eval "$(declare -f proc_identity_status | sed "1s/proc_identity_status/_orig_proc_identity_status/")"
  proc_identity_status() {
    local n
    n="$(( $(cat "$TEST_COUNT19") + 1 ))"
    printf "%s\n" "$n" > "$TEST_COUNT19"
    [[ "$n" -ge 2 ]] && return 1
    _orig_proc_identity_status "$@"
  }
  _kill_pid_escalate_if_identity "$2" "$3" 1
  printf "RC=%s\n" "$?"
' _ "$LIB_LANE" "$PID19" "$IDENTITY19" 2>&1)"
assert_contains "TC-LGC8-019a: identity change before KILL returns strict refusal" "RC=3" "$OUT19"
if [[ -f "$MARKER19" ]] && kill -0 "$PID19" 2>/dev/null; then
  pass "TC-LGC8-019b: TERM was delivered but identity refusal prevented KILL"
else
  fail "TC-LGC8-019b: identity-aware PID escalation did not preserve the changed process"
fi

echo "=== Lane-GC P8 Pass 2/3 signal identity ==="

MARKER20="$TMPROOT/pass23-term.marker"
setsid bash -c 'trap "touch \"$1\"" TERM; while :; do sleep 1; done' _ "$MARKER20" &
PID20=$!
SPAWNED_GROUPS+=("$PID20")
sleep 0.2
PID_ID20="$(ADT_STATE_ROOT="$TMPROOT/pass23-identity" bash -c 'source "$1"; proc_identity "$2"' _ "$LIB_LANE" "$PID20")"
PG_ID20="$PID_ID20"
KC20="$(sed -n '/^_gc_kill_candidate() {$/,/^}/p' "$ADT_GC")"
COUNT20="$TMPROOT/pass23-signal.count"
printf '0\n' > "$COUNT20"
OUT20="$(ADT_STATE_ROOT="$TMPROOT/pass23-identity" TEST_COUNT20="$COUNT20" bash -c '
  source "$1"
  eval "$2"
  eval "$(declare -f proc_identity_status | sed "1s/proc_identity_status/_orig_proc_identity_status/")"
  proc_identity_status() {
    local n
    n="$(( $(cat "$TEST_COUNT20") + 1 ))"
    printf "%s\n" "$n" > "$TEST_COUNT20"
    [[ "$n" -ge 3 ]] && return 1
    _orig_proc_identity_status "$@"
  }
  _gc_safe_kill_pgid() { return 0; }
  _gc_kill_candidate "$3" "$3" "$4" "$5" 1
  printf "RC=%s\n" "$?"
' _ "$LIB_LANE" "$KC20" "$PID20" "$PID_ID20" "$PG_ID20" 2>&1)"
assert_contains "TC-LGC8-020a: Pass 2/3 identity change before KILL returns refusal" "RC=3" "$OUT20"
if [[ -f "$MARKER20" ]] && kill -0 "$PID20" 2>/dev/null; then
  pass "TC-LGC8-020b: Pass 2/3 TERM landed but identity refusal prevented KILL"
else
  fail "TC-LGC8-020b: Pass 2/3 identity race killed the changed process"
fi

echo "=== Lane-GC P8 scope authorization and identity binding ==="

ST21="$TMPROOT/scope-pass23"
LANE21="$(make_dead_lane "$ST21" p8scope 21)"
LANE_ID21="$(ADT_STATE_ROOT="$ST21" bash -c 'source "$1"; lane_get "$2" LANE_ID' _ "$LIB_LANE" "$LANE21")"
ADT_STATE_ROOT="$ST21" bash -c '
  source "$1"
  lane_set "$2" BACKEND systemd-scope
  lane_set "$2" CHROME_PROFILE_HINT /tmp/p8-scope-profile
  lane_set "$2" WORKTREE /tmp/p8-scope-worktree
' _ "$LIB_LANE" "$LANE21"

PASS2_SRC="$(sed -n '/^_gc_pass2() {$/,/^}/p' "$ADT_GC")"
PASS2_MARKER="$TMPROOT/scope-pass2-kill"
OUT21="$(ADT_STATE_ROOT="$ST21" TEST_LANE21="$LANE21" TEST_LANE_ID21="$LANE_ID21" \
  TEST_MARKER21="$PASS2_MARKER" bash -c '
  source "$1"
  eval "$2"
  _gc_same_uid_pids() { printf "4242\n"; }
  proc_identity() { printf "v2-linux:00000000-0000-0000-0000-000000000000:42\n"; }
  proc_identity_is_durable() { return 0; }
  proc_identity_authorizes_signal() { return 0; }
  _gc_env_unknowable() { return 1; }
  _gc_has_term_program() { return 1; }
  env_lookup() { [[ "$2" == "ADT_LANE_ID" ]] && printf "%s\n" "$TEST_LANE_ID21"; }
  _gc_lane_dir_for_id() { printf "%s\n" "$TEST_LANE21"; }
  lane_probe() { printf "dead\n"; }
  proc_pgid() { printf "4242\n"; }
  _gc_common_kill_guards() { return 0; }
  _gc_kill_candidate() { touch "$TEST_MARKER21"; }
  _gc_log() { printf "%s\n" "$*"; }
  GC_MODE=kill
  SKIPS=0
  KILLED=0
  WOULD_KILL=0
  WOULD_KILL_LEGACY=0
  UNKNOWN_CLASS=0
  _gc_pass2
' _ "$LIB_LANE" "$PASS2_SRC" 2>&1)"
if [[ ! -e "$PASS2_MARKER" ]]; then
  pass "TC-LGC8-021a: Pass 2 refuses a tagged dead scope lane"
else
  fail "TC-LGC8-021a: Pass 2 authorized a scope-lane candidate"
fi
assert_contains "TC-LGC8-021b: Pass 2 scope refusal is observable" \
  "reason=registry-backend-not-pgid" "$OUT21"

for pass3_function in _gc_pass3_chrome_lane_scoped _gc_pass3_e2e_servers; do
  PASS3_SRC="$(sed -n "/^${pass3_function}() {$/,/^}/p" "$ADT_GC")"
  PASS3_MARKER="$TMPROOT/${pass3_function}.candidate-scan"
  OUT21P3="$(ADT_STATE_ROOT="$ST21" TEST_LANE21="$LANE21" TEST_MARKER21="$PASS3_MARKER" \
    bash -c '
    source "$1"
    eval "$2"
    _gc_all_lane_dirs() { printf "%s\n" "$TEST_LANE21"; }
    lane_probe() { printf "dead\n"; }
    _gc_same_uid_pids() { touch "$TEST_MARKER21"; printf "4242\n"; }
    _gc_log() { printf "%s\n" "$*"; }
    GC_MODE=kill
    SKIPS=0
    KILLED=0
    WOULD_KILL=0
    "$3"
  ' _ "$LIB_LANE" "$PASS3_SRC" "$pass3_function" 2>&1)"
  if [[ ! -e "$PASS3_MARKER" ]]; then
    pass "TC-LGC8-021-${pass3_function}: lane-scoped Pass 3 refuses scope before candidate enumeration"
  else
    fail "TC-LGC8-021-${pass3_function}: lane-scoped Pass 3 enumerated candidates for a scope lane"
  fi
  assert_contains "TC-LGC8-021-log-${pass3_function}: lane-scoped Pass 3 logs backend refusal" \
    "reason=registry-backend-not-pgid" "$OUT21P3"
done

PASS3_PROVENANCE_SRC="$(sed -n '/^_gc_pass3_candidate_backend_verified() {$/,/^}/p' "$ADT_GC")"
for pass3_function in _gc_pass3_chrome_heuristic _gc_pass3_wedged_gh; do
  PASS3_SRC="$(sed -n "/^${pass3_function}() {$/,/^}/p" "$ADT_GC")"
  PASS3_MARKER="$TMPROOT/${pass3_function}.kill"
  OUT21P3="$(ADT_STATE_ROOT="$ST21" TEST_LANE21="$LANE21" TEST_LANE_ID21="$LANE_ID21" \
    TEST_MARKER21="$PASS3_MARKER" TEST_PASS3_FUNCTION="$pass3_function" bash -c '
    source "$1"
    eval "$2"
    eval "$3"
    _gc_same_uid_pids() { printf "4242\n"; }
    proc_identity() { printf "v2-linux:00000000-0000-0000-0000-000000000000:42\n"; }
    proc_identity_is_durable() { return 0; }
    proc_identity_authorizes_signal() { return 0; }
    proc_argv() {
      if [[ "$TEST_PASS3_FUNCTION" == "_gc_pass3_chrome_heuristic" ]]; then
        printf "chrome --user-data-dir=/tmp/puppeteer_dev_chrome_profile-p8\n"
      else
        printf "gh pr checks --watch\n"
      fi
    }
    proc_ppid() { printf "1\n"; }
    proc_pgid() { printf "4242\n"; }
    _gc_safe_kill_pgid() { return 0; }
    _gc_common_kill_guards() { return 0; }
    _gc_chrome_profile_has_live_sharer() { return 1; }
    _gc_chrome_has_live_mcp_parent() { return 1; }
    _gc_env_unknowable() { return 1; }
    env_lookup() {
      case "$2" in
        ADT_LANE_ID) printf "%s\n" "$TEST_LANE_ID21" ;;
        GH_TOKEN_FILE) printf "/tmp/agent-auth-p8/token\n" ;;
      esac
    }
    _gc_lane_dir_for_id() { printf "%s\n" "$TEST_LANE21"; }
    _gc_kill_candidate() { touch "$TEST_MARKER21"; }
    _gc_log() { printf "%s\n" "$*"; }
    GC_MODE=kill
    SKIPS=0
    KILLED=0
    WOULD_KILL=0
    "$4"
  ' _ "$LIB_LANE" "$PASS3_PROVENANCE_SRC" "$PASS3_SRC" "$pass3_function" 2>&1)"
  if [[ ! -e "$PASS3_MARKER" ]]; then
    pass "TC-LGC8-021-${pass3_function}-tagged: Pass 3 refuses a candidate tagged to a scope lane"
  else
    fail "TC-LGC8-021-${pass3_function}-tagged: Pass 3 killed a candidate tagged to a scope lane"
  fi
  assert_contains "TC-LGC8-021-log-${pass3_function}-tagged: tagged scope refusal is observable" \
    "reason=registry-backend-not-pgid" "$OUT21P3"
done

assert_identity_capture_precedes() {
  local function_name="$1" classifier_pattern="$2" desc="$3"
  local body identity_line classifier_line
  body="$(sed -n "/^${function_name}() {$/,/^}/p" "$ADT_GC")"
  identity_line="$(printf '%s\n' "$body" | grep -n -m1 'pid_identity=.*proc_identity' | cut -d: -f1)"
  classifier_line="$(printf '%s\n' "$body" | grep -n -m1 -E "$classifier_pattern" | cut -d: -f1)"
  if [[ -n "$identity_line" && -n "$classifier_line" && "$identity_line" -lt "$classifier_line" ]]; then
    pass "$desc"
  else
    fail "$desc (identity_line=${identity_line:-missing}, classifier_line=${classifier_line:-missing})"
  fi
}

assert_identity_capture_precedes "_gc_pass2" \
  '_gc_env_unknowable|env_lookup' \
  "TC-LGC8-022a: Pass 2 binds PID identity before env classification"
assert_identity_capture_precedes "_gc_pass3_chrome_lane_scoped" \
  'argv=.*proc_argv' \
  "TC-LGC8-022b: Pass 3.1 binds PID identity before argv classification"
assert_identity_capture_precedes "_gc_pass3_chrome_heuristic" \
  'argv=.*proc_argv' \
  "TC-LGC8-022c: Pass 3.2 binds PID identity before argv classification"
assert_identity_capture_precedes "_gc_pass3_wedged_gh" \
  'argv=.*proc_argv' \
  "TC-LGC8-022d: Pass 3.3 binds PID identity before argv classification"
assert_identity_capture_precedes "_gc_pass3_e2e_servers" \
  'cwd=.*readlink' \
  "TC-LGC8-022e: Pass 3.4 binds PID identity before cwd classification"

if grep -Eq '_GC_CANDIDATE_(PID|PG)_IDENTITY' "$ADT_GC"; then
  fail "TC-LGC8-022f: candidate authorization still depends on mutable identity globals"
else
  pass "TC-LGC8-022f: candidate identities flow through explicit function parameters"
fi

echo ""
echo "Lane-GC P8 tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
