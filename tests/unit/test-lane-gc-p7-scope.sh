#!/bin/bash
# test-lane-gc-p7-scope.sh — Unit tests for issue #383 (Lane-GC series
# PR-7, design docs/designs/lane-containment-gc.md §4-C1 `_lane_backend`/
# §4-C7; INV-120).
#
# Covers:
#   - lib-lane.sh: `_lane_backend()` probe (Linux ∧ systemd-run ∧
#     Linger=yes ∧ reachable bus ∧ probe-spawn success), `_lane_unit_name`,
#     `lane_install`'s BACKEND/UNIT recording, `lane_spawn`'s backend
#     dispatch, `lane_kill`'s scope fast path (`_lane_scope_kill`) always
#     followed by the unconditional pgid escalation.
#   - lib-guardian.sh: `do_reap`'s identical scope-fast-path call, ordered
#     before its own pgid escalation.
#   - adt-gc.sh: --doctor's bus-socket check + backend_eligibility= line
#     (spot-checked here; the full --doctor output is already covered by
#     test-lane-gc-p4-gc.sh).
#
# Test-class legend (see docs/test-cases/lane-gc-p7-scope.md for the full
# table): REAL tests run against this box's actual systemd-run/loginctl/
# systemctl and skip when the host does not meet a scenario's prerequisite.
# SHIM tests PATH-prepend a recording/behavior-controlling fixture script;
# they prove SELECTION LOGIC and KILL-PATH ARGV SHAPE only, never real
# cgroup/kernel semantics — see the "Honest scope note" at the bottom of
# this file.
#
# Full scenario list: docs/test-cases/lane-gc-p7-scope.md (TC-LGC7-*).
#
# Run: bash tests/unit/test-lane-gc-p7-scope.sh
# (Run under `bash`, and once under `env -u PROJECT_DIR bash ...` for CI
# parity — ambient PROJECT_DIR contaminates lib-config.sh's conf lookup in
# some sibling suites; this suite sources lib-lane.sh/lib-guardian.sh only,
# neither of which reads PROJECT_DIR, but the convention is kept for
# consistency with the rest of the series.)

set -uo pipefail

PASS=0
FAIL=0
SKIPPED=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB_LANE="$SCRIPTS/lib-lane.sh"
LIB_GUARDIAN="$SCRIPTS/lib-guardian.sh"
ADT_GC="$SCRIPTS/adt-gc.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
assert_pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
assert_fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_skip() { echo -e "  ${YELLOW}SKIP${NC}: $1 (reason: $2)"; SKIPPED=$((SKIPPED + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc (expected [$expected] got [$actual])"; fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then assert_pass "$desc"; else assert_fail "$desc (needle='$needle' not found in: $haystack)"; fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then assert_pass "$desc"; else assert_fail "$desc (needle='$needle' unexpectedly found)"; fi
}

for f in "$LIB_LANE" "$LIB_GUARDIAN" "$ADT_GC"; do
  [[ -f "$f" ]] || { echo -e "${RED}FATAL${NC}: $f not found"; exit 1; }
done

TMPROOT=$(mktemp -d)
# EXIT trap pkills every fixture spawned under TMPROOT by path, then removes
# the tree — matches the house convention (test-lane-gc-p3-kill-paths.sh /
# test-lane-gc-p5-guardian.sh). Also best-effort tears down any REAL scope
# units this suite created (a leaked `adt-tc-lgc7-*.scope` would otherwise
# survive the test process on a systemd-scope-eligible host).
trap '
  pkill -9 -f "$TMPROOT" 2>/dev/null
  if command -v systemctl >/dev/null 2>&1; then
    for u in $(systemctl --user list-units --type=scope --all --no-legend 2>/dev/null | awk "{print \$1}" | grep -E "^adt-tc-lgc7-" 2>/dev/null); do
      systemctl --user kill -s KILL "$u" >/dev/null 2>&1 || true
    done
  fi
  rm -rf "$TMPROOT"
' EXIT

_lane_state_root() { printf '%s/state-%s\n' "$TMPROOT" "$1"; }

# _real_systemd_available — true iff this host genuinely has systemd-run,
# loginctl, and systemctl on PATH (i.e. the REAL-class tests below are
# meaningful here, not merely inert). This series' own dev/CI host has all
# three; a host that doesn't SKIPs the REAL-class tests with an explicit
# reason rather than faking a result (design doc's own "Honest-scope note").
_real_systemd_available() {
  command -v systemd-run >/dev/null 2>&1 && command -v loginctl >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1
}

REAL_SYSTEMD=false
_real_systemd_available && REAL_SYSTEMD=true
REAL_LOGIN_USER="${USER:-$(id -un)}"
REAL_LINGER="unavailable"
if [[ "$REAL_SYSTEMD" == true ]]; then
  REAL_LINGER="$(loginctl show-user "$REAL_LOGIN_USER" -p Linger --value 2>/dev/null || echo unavailable)"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC7-001/002/003/004: REAL backend refusal (host-conditional) ==="
# ===========================================================================
if [[ "$REAL_SYSTEMD" == true ]]; then
  NS001="lgc7-001"
  export ADT_STATE_ROOT="$(_lane_state_root "$NS001")"
  OUT001=$(bash -c '
    set -u
    source "'"$LIB_LANE"'"
    backend=$(_lane_backend 2>"'"$TMPROOT"'/tc001.stderr")
    echo "BACKEND=$backend"
  ')
  BACKEND001="${OUT001#BACKEND=}"
  if [[ "$REAL_LINGER" == "yes" ]]; then
    assert_skip "TC-LGC7-001: real _lane_backend() refusal on Linger=no" "this host's REAL Linger is 'yes' — the refusal-path assumption for this specific test does not hold here; TC-LGC7-014 (SHIM) covers the positive path unconditionally"
    assert_skip "TC-LGC7-002: WARN names the missing prerequisite" "same as above"
  else
    assert_eq "TC-LGC7-001: _lane_backend() on this REAL Linger=no host returns pgid" "pgid" "$BACKEND001"
    assert_contains "TC-LGC7-002: WARN line names linger" "linger" "$(cat "$TMPROOT/tc001.stderr" 2>/dev/null)"
  fi

  OUT003=$(bash -c '
    set -u
    source "'"$LIB_LANE"'"
    LANE_ID=$(lane_mint proj001 dev 1)
    LANE_DIR=$(lane_install proj001 "$LANE_ID")
    lane_get "$LANE_DIR" BACKEND
    echo "---"
    lane_get "$LANE_DIR" UNIT
  ' 2>/dev/null)
  BACKEND003="$(echo "$OUT003" | sed -n '1p')"
  UNIT003="$(echo "$OUT003" | sed -n '3p')"
  if [[ "$REAL_LINGER" == "yes" ]]; then
    assert_skip "TC-LGC7-003: lane_install records BACKEND=pgid on this host" "REAL Linger is 'yes' on this host"
    assert_skip "TC-LGC7-003b: UNIT is the sentinel dash" "same as above"
  else
    assert_eq "TC-LGC7-003: lane_install records BACKEND=pgid, UNIT=- with no override on this real host" "pgid" "$BACKEND003"
    assert_eq "TC-LGC7-003b: UNIT is the sentinel dash" "-" "$UNIT003"
  fi
else
  assert_skip "TC-LGC7-001..004: REAL backend refusal" "systemd-run/loginctl/systemctl not all present on PATH — this suite's REAL-class tests require them; see the design doc's honest-scope note"
fi

# TC-LGC7-004: pgid-backend lane spawn+kill roundtrip works exactly as
# pre-PR-7 regardless of systemd availability (this is the byte-equivalence
# regression pin, run unconditionally since it exercises NO scope code at
# all when BACKEND=pgid).
NS004="lgc7-004"
export ADT_STATE_ROOT="$(_lane_state_root "$NS004")"
(
  set -u
  source "$LIB_LANE"
  LANE_ID=$(lane_mint proj004 dev 4)
  LANE_DIR=$(lane_install proj004 "$LANE_ID")
  # Force pgid explicitly (independent of this host's real linger) so this
  # test is deterministic regardless of environment.
  lane_set "$LANE_DIR" BACKEND pgid
  lane_set "$LANE_DIR" UNIT -
  lane_spawn "$LANE_DIR" agent -- sleep 30 &
  SPAWNER=$!
  sleep 0.5
  PGID=$(awk 'NR==1{print $1}' "$LANE_DIR/pgids")
  echo "$PGID" > "$TMPROOT/tc004.pgid"
  lane_kill "$LANE_DIR" 3
  echo "$?" > "$TMPROOT/tc004.killrc"
  wait "$SPAWNER" 2>/dev/null
) >/dev/null 2>&1
PGID004=$(cat "$TMPROOT/tc004.pgid" 2>/dev/null)
if [[ -n "$PGID004" ]]; then
  kill -0 -- "-$PGID004" 2>/dev/null && ALIVE004=yes || ALIVE004=no
  assert_eq "TC-LGC7-004: pgid-backend lane_spawn+lane_kill roundtrip unaffected by this PR — spawned group is dead after kill" "no" "$ALIVE004"
else
  assert_fail "TC-LGC7-004: fixture did not record a pgid"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC7-010..014: per-prerequisite refusal isolation (SHIM) ==="
# ===========================================================================
SHIM_BIN="$TMPROOT/shimbin"
mkdir -p "$SHIM_BIN"

_write_shim_all_pass() {
  # loginctl: Linger=yes. systemd-run: probe spawn succeeds AND records
  # its argv for the argv-shape tests further down. systemctl: recording
  # stub for the kill-path tests.
  cat > "$SHIM_BIN/loginctl" <<'EOF'
#!/bin/bash
if [[ "$*" == *"Linger"* ]]; then echo "${LOGINCTL_LINGER_OVERRIDE:-yes}"; exit 0; fi
exit 0
EOF
  cat > "$SHIM_BIN/systemd-run" <<'EOF'
#!/bin/bash
echo "$@" >> "${SYSTEMD_RUN_ARGV_LOG:-/dev/null}"
if [[ "${SYSTEMD_RUN_PROBE_FAIL:-0}" == "1" ]]; then exit 1; fi
# For the argv-capture tests we don't need to actually run the payload —
# but for the "positive path is reachable" smoke test, exit 0 immediately.
exit 0
EOF
  cat > "$SHIM_BIN/systemctl" <<'EOF'
#!/bin/bash
echo "$@" >> "${SYSTEMCTL_ARGV_LOG:-/dev/null}"
case "$1" in
  --user)
    case "$2" in
      show) echo "${SYSTEMCTL_SHOW_VALUE:-}" ;;
      kill) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
esac
exit 0
EOF
  chmod +x "$SHIM_BIN"/loginctl "$SHIM_BIN"/systemd-run "$SHIM_BIN"/systemctl
}
_write_shim_all_pass

XDG_SHIM_DIR="$TMPROOT/xdg-shim"
mkdir -p "$XDG_SHIM_DIR"
python3 -c "
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind('$XDG_SHIM_DIR/bus')
" 2>/dev/null || : > "$XDG_SHIM_DIR/bus"  # fallback: plain file fails -S but keeps the dir non-crashing

_lane_backend_shimmed() {
  # $1=PATH-prefix-dir (empty string means "use SHIM_BIN as-is")
  local extra_path="${1:-$SHIM_BIN}"
  PATH="$extra_path:$PATH" XDG_RUNTIME_DIR="$XDG_SHIM_DIR" bash -c '
    source "'"$LIB_LANE"'"
    _lane_backend 2>"'"$TMPROOT"'/tc01x.stderr"
  '
}

# TC-LGC7-010: systemd-run absent from PATH entirely. Prepending a decoy
# dir to the AMBIENT $PATH is not sufficient on this box — `/bin` is a
# symlink to `/usr/bin` (both appear in $PATH under different names), so
# `command -v systemd-run` still resolves the REAL binary later in the
# search. A genuinely curated PATH (symlink every real binary EXCEPT
# systemd-run into one dir, then use ONLY that dir — never `$dir:$PATH`)
# is required to prove absence, not merely shadow it.
CURATED_NO_SYSTEMD_RUN="$TMPROOT/curated-no-systemd-run"
mkdir -p "$CURATED_NO_SYSTEMD_RUN"
for _real_dir in /usr/bin /bin /usr/local/bin; do
  [[ -d "$_real_dir" ]] || continue
  for _real_bin in "$_real_dir"/*; do
    [[ -f "$_real_bin" || -L "$_real_bin" ]] || continue
    _bn="$(basename "$_real_bin")"
    [[ "$_bn" == "systemd-run" ]] && continue
    ln -sf "$_real_bin" "$CURATED_NO_SYSTEMD_RUN/$_bn" 2>/dev/null || true
  done
done
# loginctl/systemctl shims take priority (they're already absent from the
# curated set's copy — re-link them from SHIM_BIN so this test still
# exercises the REST of the probe chain, isolating systemd-run as the sole
# missing prerequisite).
ln -sf "$SHIM_BIN/loginctl" "$CURATED_NO_SYSTEMD_RUN/loginctl"
ln -sf "$SHIM_BIN/systemctl" "$CURATED_NO_SYSTEMD_RUN/systemctl"
OUT010=$(PATH="$CURATED_NO_SYSTEMD_RUN" XDG_RUNTIME_DIR="$XDG_SHIM_DIR" bash -c '
  source "'"$LIB_LANE"'"
  _lane_backend 2>"'"$TMPROOT"'/tc01x.stderr"
')
assert_eq "TC-LGC7-010: systemd-run genuinely absent from a curated PATH -> pgid" "pgid" "$OUT010"
assert_contains "TC-LGC7-010b: WARN names systemd-run" "systemd-run" "$(cat "$TMPROOT/tc01x.stderr" 2>/dev/null)"

# TC-LGC7-011: loginctl reports Linger=no.
OUT011=$(LOGINCTL_LINGER_OVERRIDE=no _lane_backend_shimmed)
assert_eq "TC-LGC7-011: Linger=no via shim -> pgid" "pgid" "$OUT011"
assert_contains "TC-LGC7-011b: WARN names linger" "linger" "$(cat "$TMPROOT/tc01x.stderr" 2>/dev/null)"

# TC-LGC7-012: Linger=yes but no bus socket (point XDG_RUNTIME_DIR at an
# empty dir with no `bus` file at all).
EMPTY_XDG="$TMPROOT/empty-xdg"
mkdir -p "$EMPTY_XDG"
OUT012=$(PATH="$SHIM_BIN:$PATH" XDG_RUNTIME_DIR="$EMPTY_XDG" bash -c '
  source "'"$LIB_LANE"'"
  _lane_backend 2>"'"$TMPROOT"'/tc012.stderr"
')
assert_eq "TC-LGC7-012: Linger=yes, no bus socket -> pgid" "pgid" "$OUT012"
assert_contains "TC-LGC7-012b: WARN names the bus socket" "bus" "$(cat "$TMPROOT/tc012.stderr" 2>/dev/null)"

# TC-LGC7-013: Linger=yes, bus present, probe spawn fails.
OUT013=$(SYSTEMD_RUN_PROBE_FAIL=1 _lane_backend_shimmed)
assert_eq "TC-LGC7-013: probe spawn fails -> pgid" "pgid" "$OUT013"
assert_contains "TC-LGC7-013b: WARN names the probe spawn" "probe" "$(cat "$TMPROOT/tc01x.stderr" 2>/dev/null)"

# TC-LGC7-014: all four prerequisites shimmed to succeed -> positive path
# is reachable via shims (proves the function CAN return systemd-scope,
# not just that it correctly refuses).
OUT014=$(_lane_backend_shimmed)
assert_eq "TC-LGC7-014: all prerequisites shimmed to pass -> systemd-scope" "systemd-scope" "$OUT014"

# ===========================================================================
echo ""
echo "=== TC-LGC7-020/021: unit naming — collision-free + accepted by systemd-run ==="
# ===========================================================================
OUT020=$(bash -c '
  source "'"$LIB_LANE"'"
  id1=$(lane_mint proj020 dev 20)
  id2=$(lane_mint proj020 dev 20)
  u1=$(_lane_unit_name "$id1")
  u2=$(_lane_unit_name "$id2")
  echo "$u1"
  echo "$u2"
')
UNIT020A=$(echo "$OUT020" | sed -n '1p')
UNIT020B=$(echo "$OUT020" | sed -n '2p')
if [[ "$UNIT020A" != "$UNIT020B" ]]; then
  assert_pass "TC-LGC7-020: two lane_mint calls for the same (project,role,issue) produce distinct unit names via rand4 ($UNIT020A vs $UNIT020B)"
else
  assert_fail "TC-LGC7-020: unit names collided ($UNIT020A)"
fi

assert_contains "TC-LGC7-021: unit name shape matches adt-<safe-id>" "adt-" "$UNIT020A"
assert_not_contains "TC-LGC7-021b: unit name has no raw colon (fs-unsafe)" ":" "$UNIT020A"

if [[ "$REAL_SYSTEMD" == true ]]; then
  # [Lane-GC PR-7 review round-1, P3] Real acceptance check uses the ACTUAL
  # lane-derived unit name computed above ($UNIT020A, from a real
  # `lane_mint` -> `_lane_unit_name` call) — a FIXED literal name here would
  # never catch a regression in `_lane_unit_name`'s own output shape.
  # Independent of linger — spawning is allowed regardless of linger; only
  # backend SELECTION is linger-gated.
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    systemd-run --user --scope --collect --quiet --unit "$UNIT020A" -- true 2>/dev/null
  RC021=$?
  assert_eq "TC-LGC7-021c: the REAL lane-derived unit name ($UNIT020A) is accepted by a REAL systemd-run --unit" "0" "$RC021"
else
  assert_skip "TC-LGC7-021c: REAL systemd-run --unit acceptance" "systemd-run not present on PATH"
fi

# [Lane-GC PR-7 review round-1, P2-2/P3] Long/odd PROJECT_ID: a real,
# unsanitized project id was empirically shown (during this fix) to make
# systemd reject the unit outright (`@` rejected; >249 raw chars rejected
# once the `.scope` suffix pushes the total past systemd's 255-byte unit-
# name cap) — `_lane_unit_name` sanitizes disallowed chars to `-` and caps
# total length while preserving the uniqueness-bearing `.epoch.rand4` tail.
LONGPROJ_TC="$(printf 'p%.0s' $(seq 1 300))@weird/chars"
OUT022=$(bash -c '
  source "'"$LIB_LANE"'"
  id=$(lane_mint "'"$LONGPROJ_TC"'" dev 22)
  _lane_unit_name "$id"
')
assert_eq "TC-LGC7-022: a long, bad-char PROJECT_ID produces a unit name <= 249 chars (255-byte systemd cap minus the 6-byte .scope suffix)" "true" "$([[ "${#OUT022}" -le 249 ]] && echo true || echo false)"
if [[ "$REAL_SYSTEMD" == true ]]; then
  XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
    systemd-run --user --scope --collect --quiet --unit "$OUT022" -- true 2>/dev/null
  RC022=$?
  assert_eq "TC-LGC7-022b: the sanitized long/bad-char unit name is accepted by a REAL systemd-run --unit" "0" "$RC022"
else
  # Shape-assert only: systemd's own alphabet per systemd.unit(5) is
  # [A-Za-z0-9:_.-] — assert no OTHER byte class survived sanitization.
  assert_eq "TC-LGC7-022b: shape-only (no systemd-run on PATH) — sanitized unit name contains only systemd's safe alphabet" "true" "$([[ "$OUT022" =~ ^[A-Za-z0-9:_.-]+$ ]] && echo true || echo false)"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC7-023/024/025: registration-failure fallback — payload MUST still run ==="
# (review round-1 P2-2: a rejected/failed systemd-run registration must
# never mean the wrapped command silently never executed)
# ===========================================================================
REGFAIL_BIN="$TMPROOT/registration-failure-bin"
mkdir -p "$REGFAIL_BIN"
cat > "$REGFAIL_BIN/systemd-run" <<'EOF'
#!/bin/bash
echo "Failed to start transient scope: deterministic test failure" >&2
exit 1
EOF
chmod +x "$REGFAIL_BIN/systemd-run"

NS023="lgc7-023"
export ADT_STATE_ROOT="$(_lane_state_root "$NS023")"
MARKER023="$TMPROOT/tc023.marker"
rm -f "$MARKER023"
PATH="$REGFAIL_BIN:$PATH" TEST_SYSTEMD_RUN="$REGFAIL_BIN/systemd-run" TEST_MARKER023="$MARKER023" bash -c '
  hash -p "$TEST_SYSTEMD_RUN" systemd-run
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint proj023 dev 23)
  LANE_DIR=$(lane_install proj023 "$LANE_ID")
  # Force the systemd-run registration itself to fail before payload exec. Using
  # a shim keeps this invariant stable across systemd versions and hosts.
  lane_set "$LANE_DIR" BACKEND systemd-scope
  lane_set "$LANE_DIR" UNIT "adt-tc-lgc7-023"
  lane_spawn "$LANE_DIR" agent -- touch "$TEST_MARKER023"
  echo "SPAWN_RC=$?"
' > "$TMPROOT/tc023.out" 2>"$TMPROOT/tc023.err"
SPAWNRC023="$(grep -o 'SPAWN_RC=.*' "$TMPROOT/tc023.out" | cut -d= -f2)"
if [[ -f "$MARKER023" ]]; then
  assert_pass "TC-LGC7-023: a systemd-run REGISTRATION failure does NOT lose the payload — it still ran via the pgid fallback"
else
  assert_fail "TC-LGC7-023: payload never ran after a registration failure — the exact bug review round-1 P2-2 flagged (marker file absent, lane_spawn stdout: $(cat "$TMPROOT/tc023.out" 2>/dev/null))"
fi
assert_eq "TC-LGC7-023b: lane_spawn's own reported rc is 0 (the fallback payload's own exit code, not a registration-failure sentinel leaking to the caller)" "0" "$SPAWNRC023"
assert_contains "TC-LGC7-023c: a WARN naming the registration failure and the fallback is logged" "falling back to a pgid spawn" "$(cat "$TMPROOT/tc023.err" 2>/dev/null)"

# TC-LGC7-024: the payload runs EXACTLY ONCE on a registration failure —
# never twice (a naive retry-without-discriminating-the-cause could
# double-run a payload that has side effects).
NS024="lgc7-024"
export ADT_STATE_ROOT="$(_lane_state_root "$NS024")"
COUNTFILE024="$TMPROOT/tc024.count"
echo 0 > "$COUNTFILE024"
PATH="$REGFAIL_BIN:$PATH" TEST_SYSTEMD_RUN="$REGFAIL_BIN/systemd-run" TEST_COUNTFILE024="$COUNTFILE024" bash -c '
  hash -p "$TEST_SYSTEMD_RUN" systemd-run
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint proj024 dev 24)
  LANE_DIR=$(lane_install proj024 "$LANE_ID")
  lane_set "$LANE_DIR" BACKEND systemd-scope
  lane_set "$LANE_DIR" UNIT "adt-tc-lgc7-024"
  lane_spawn "$LANE_DIR" agent -- bash -c "n=\$(cat \"\$TEST_COUNTFILE024\"); echo \$((n+1)) > \"\$TEST_COUNTFILE024\""
' >/dev/null 2>&1
assert_eq "TC-LGC7-024: the fallback runs the payload EXACTLY ONCE on a registration failure (never a double-run)" "1" "$(cat "$COUNTFILE024" 2>/dev/null)"

# TC-LGC7-025: a GENUINE payload failure (successful registration, payload
# itself exits non-zero) must NOT trigger the fallback and must NOT
# double-run — the discriminator must never fire on ordinary payload
# failure, only on systemd-run's OWN registration failure.
NS025="lgc7-025"
export ADT_STATE_ROOT="$(_lane_state_root "$NS025")"
if [[ "$REAL_SYSTEMD" == true ]]; then
  COUNTFILE025="$TMPROOT/tc025.count"
  echo 0 > "$COUNTFILE025"
  (
    source "$LIB_LANE"
    LANE_ID=$(lane_mint proj025 dev 25)
    LANE_DIR=$(lane_install proj025 "$LANE_ID")
    lane_set "$LANE_DIR" BACKEND systemd-scope
    lane_set "$LANE_DIR" UNIT "adt-tc-lgc7-025-valid"
    lane_spawn "$LANE_DIR" agent -- bash -c "n=\$(cat '$COUNTFILE025'); echo \$((n+1)) > '$COUNTFILE025'; exit 9"
    echo "SPAWN_RC=$?"
  ) > "$TMPROOT/tc025.out" 2>/dev/null
  SPAWNRC025="$(grep -o 'SPAWN_RC=.*' "$TMPROOT/tc025.out" | cut -d= -f2)"
  assert_eq "TC-LGC7-025: a genuine payload failure (successful registration) runs EXACTLY ONCE, never falls back" "1" "$(cat "$COUNTFILE025" 2>/dev/null)"
  assert_eq "TC-LGC7-025b: the genuine payload's own exit code (9) propagates through lane_spawn unchanged" "9" "$SPAWNRC025"
else
  assert_skip "TC-LGC7-025: genuine-payload-failure discriminator" "systemd-run not present on PATH — cannot exercise a successful registration on this host"
fi

# TC-LGC7-025c (review round-2 [P1]): the adversarial shape the stderr
# prefix alone cannot discriminate — a payload that SUCCESSFULLY registers,
# prints its own line starting with "Failed to ", and exits non-zero. The
# start-marker is the authoritative signal: the payload provably began, so
# lane_spawn must NOT retry it (a retry would double-run a
# possibly-side-effecting command) and must propagate its real rc.
NS025C="lgc7-025c"
export ADT_STATE_ROOT="$(_lane_state_root "$NS025C")"
if [[ "$REAL_SYSTEMD" == true ]]; then
  COUNTFILE025C="$TMPROOT/tc025c.count"
  echo 0 > "$COUNTFILE025C"
  (
    source "$LIB_LANE"
    LANE_ID=$(lane_mint proj025c dev 25)
    LANE_DIR=$(lane_install proj025c "$LANE_ID")
    lane_set "$LANE_DIR" BACKEND systemd-scope
    lane_set "$LANE_DIR" UNIT "adt-tc-lgc7-025c-valid"
    lane_spawn "$LANE_DIR" agent -- bash -c "n=\$(cat '$COUNTFILE025C'); echo \$((n+1)) > '$COUNTFILE025C'; echo 'Failed to reticulate splines' >&2; exit 7"
    echo "SPAWN_RC=$?"
  ) > "$TMPROOT/tc025c.out" 2>/dev/null
  SPAWNRC025C="$(grep -o 'SPAWN_RC=.*' "$TMPROOT/tc025c.out" | cut -d= -f2)"
  assert_eq "TC-LGC7-025c: a payload that prints 'Failed to …' itself and exits non-zero runs EXACTLY ONCE (start-marker beats the stderr prefix)" "1" "$(cat "$COUNTFILE025C" 2>/dev/null)"
  assert_eq "TC-LGC7-025d: its real exit code (7) propagates unchanged" "7" "$SPAWNRC025C"
else
  assert_skip "TC-LGC7-025c: adversarial Failed-to payload" "systemd-run not present on PATH"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC7-026/027: bounded systemd/loginctl calls — a wedged bus must not hang ==="
# (review round-1 P1-2/P2-1: every systemd-run/systemctl/loginctl call this
# PR added must be wall-clock bounded, never able to hang a load-bearing
# path indefinitely)
# ===========================================================================
WEDGE_BIN="$TMPROOT/wedge-bin"
mkdir -p "$WEDGE_BIN"
cat > "$WEDGE_BIN/loginctl" <<'EOF'
#!/bin/bash
sleep 60
EOF
chmod +x "$WEDGE_BIN/loginctl"
START026=$(date +%s)
OUT026=$(PATH="$WEDGE_BIN:$PATH" bash -c '
  source "'"$LIB_LANE"'"
  _lane_backend
' 2>/dev/null)
END026=$(date +%s)
ELAPSED026=$((END026 - START026))
assert_eq "TC-LGC7-026: _lane_backend with a WEDGED (60s-sleeping) loginctl still returns pgid" "pgid" "$OUT026"
if [[ "$ELAPSED026" -le 15 ]]; then
  assert_pass "TC-LGC7-026b: _lane_backend returned within 15s despite the 60s-wedged loginctl (elapsed=${ELAPSED026}s) — the bounded-call fix is real, not cosmetic"
else
  assert_fail "TC-LGC7-026b: _lane_backend took ${ELAPSED026}s against a wedged loginctl — the bound did not fire (regression: review round-1 P2-1)"
fi

WEDGE_BIN2="$TMPROOT/wedge-bin2"
mkdir -p "$WEDGE_BIN2"
cat > "$WEDGE_BIN2/systemctl" <<'EOF'
#!/bin/bash
sleep 60
EOF
chmod +x "$WEDGE_BIN2/systemctl"
NS027="lgc7-027"
export ADT_STATE_ROOT="$(_lane_state_root "$NS027")"
START027=$(date +%s)
OUT027=$(PATH="$WEDGE_BIN2:$PATH" bash -c '
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint proj027 dev 27)
  LANE_DIR=$(lane_install proj027 "$LANE_ID")
  lane_set "$LANE_DIR" BACKEND systemd-scope
  lane_set "$LANE_DIR" UNIT "adt-tc-lgc7-027-wedge"
  _lane_scope_kill "$LANE_DIR" 2
  echo "RC=$?"
' 2>/dev/null)
END027=$(date +%s)
ELAPSED027=$((END027 - START027))
assert_contains "TC-LGC7-027: _lane_scope_kill with a WEDGED (60s-sleeping) systemctl still returns rc 0 (no error propagated)" "RC=0" "$OUT027"
if [[ "$ELAPSED027" -le 30 ]]; then
  assert_pass "TC-LGC7-027b: _lane_scope_kill returned within 30s despite the 60s-wedged systemctl (elapsed=${ELAPSED027}s, bound is 10s TERM + 10s show = ~20s) — lane_kill's reap.lock is never held indefinitely by a wedged bus"
else
  assert_fail "TC-LGC7-027b: _lane_scope_kill took ${ELAPSED027}s against a wedged systemctl — the bound did not fire (regression: review round-1 P1-2)"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC7-030/031/032: scope spawn argv shape (SHIM) ==="
# ===========================================================================
_lane_spawn_shimmed_argv() {
  # Spawns a scope-backend lane via lane_spawn with systemd-run PATH-shimmed
  # to record argv, then echoes the recorded argv log content.
  local extra_env="$1"
  rm -f "$TMPROOT/tc03x.argv"
  PATH="$SHIM_BIN:$PATH" XDG_RUNTIME_DIR="$XDG_SHIM_DIR" env $extra_env \
    SYSTEMD_RUN_ARGV_LOG="$TMPROOT/tc03x.argv" bash -c '
    source "'"$LIB_LANE"'"
    export ADT_STATE_ROOT="'"$(_lane_state_root lgc7-030)"'"
    LANE_ID=$(lane_mint proj030 dev 30)
    LANE_DIR=$(lane_install proj030 "$LANE_ID")
    lane_set "$LANE_DIR" BACKEND systemd-scope
    lane_set "$LANE_DIR" UNIT "adt-tc-lgc7-030"
    lane_spawn "$LANE_DIR" agent -- true
  ' >/dev/null 2>&1
  cat "$TMPROOT/tc03x.argv" 2>/dev/null
}

ARGV030=$(_lane_spawn_shimmed_argv "")
assert_contains "TC-LGC7-030: scope spawn argv contains --scope" "--scope" "$ARGV030"
assert_contains "TC-LGC7-030b: scope spawn argv contains --collect" "--collect" "$ARGV030"
assert_contains "TC-LGC7-030c: scope spawn argv contains --unit adt-tc-lgc7-030" "--unit adt-tc-lgc7-030" "$ARGV030"
assert_contains "TC-LGC7-030d: scope spawn argv contains default TasksMax=512" "TasksMax=512" "$ARGV030"
# Ordering: "-- setsid" must appear together (setsid immediately after --).
if [[ "$ARGV030" == *"-- setsid"* ]]; then
  assert_pass "TC-LGC7-030e: -- is immediately followed by setsid (ordering preserved)"
else
  assert_fail "TC-LGC7-030e: expected '-- setsid' adjacency in argv: $ARGV030"
fi

ARGV031=$(_lane_spawn_shimmed_argv "LANE_MEMORY_MAX=2G")
assert_contains "TC-LGC7-031: LANE_MEMORY_MAX=2G produces -p MemoryMax=2G" "MemoryMax=2G" "$ARGV031"

assert_not_contains "TC-LGC7-032: LANE_MEMORY_MAX unset -> no MemoryMax flag at all" "MemoryMax" "$ARGV030"

# ===========================================================================
echo ""
echo "=== TC-LGC7-033: REAL TasksMax visible in systemctl --user show ==="
# ===========================================================================
if [[ "$REAL_SYSTEMD" == true ]]; then
  NS033="lgc7-033"
  export ADT_STATE_ROOT="$(_lane_state_root "$NS033")"
  (
    source "$LIB_LANE"
    LANE_ID=$(lane_mint proj033 dev 33)
    LANE_DIR=$(lane_install proj033 "$LANE_ID")
    lane_set "$LANE_DIR" BACKEND systemd-scope
    UNIT033="adt-tc-lgc7-033-$$"
    lane_set "$LANE_DIR" UNIT "$UNIT033"
    echo "$UNIT033" > "$TMPROOT/tc033.unit"
    LANE_TASKS_MAX=64 lane_spawn "$LANE_DIR" agent -- sleep 5 &
    SPAWNER=$!
    sleep 1
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" \
      systemctl --user show -p TasksMax --value "${UNIT033}.scope" 2>/dev/null > "$TMPROOT/tc033.tasksmax"
    kill -9 -- "-$(awk 'NR==1{print $1}' "$LANE_DIR/pgids")" 2>/dev/null || true
    wait "$SPAWNER" 2>/dev/null
  ) >/dev/null 2>&1
  TASKSMAX033=$(cat "$TMPROOT/tc033.tasksmax" 2>/dev/null | tr -d '[:space:]')
  assert_eq "TC-LGC7-033: REAL LANE_TASKS_MAX=64 visible via systemctl --user show" "64" "$TASKSMAX033"
else
  assert_skip "TC-LGC7-033: REAL TasksMax visibility" "systemd-run/loginctl/systemctl not all present on PATH"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC7-040/041/042/043/044/045: REAL cgroup reap semantics ==="
# ===========================================================================
if [[ "$REAL_SYSTEMD" == true ]]; then
  NS040="lgc7-040"
  export ADT_STATE_ROOT="$(_lane_state_root "$NS040")"
  UNIT040="adt-tc-lgc7-040-$$"
  (
    source "$LIB_LANE"
    LANE_ID=$(lane_mint proj040 dev 40)
    LANE_DIR=$(lane_install proj040 "$LANE_ID")
    lane_set "$LANE_DIR" BACKEND systemd-scope
    lane_set "$LANE_DIR" UNIT "$UNIT040"
    echo "$LANE_DIR" > "$TMPROOT/tc040.lanedir"
    # Payload: immediately setsid-escapes a grandchild that sleeps — the
    # exact RC3 group-escape scenario this whole PR exists to close.
    lane_spawn "$LANE_DIR" agent -- bash -c 'setsid bash -c "exec sleep 30" & wait' &
    echo "$!" > "$TMPROOT/tc040.spawner"
  ) >/dev/null 2>&1 &
  FIXTURE040=$!
  sleep 1.5

  # TC-LGC7-041 (checked BEFORE the kill, to prove real escape): find the
  # escapee inside the scope's own cgroup.procs and confirm its sid differs
  # from the scope leader's sid (proves pgid/session escape, not merely
  # "some child exists").
  CGDIR040=""
  if command -v systemctl >/dev/null 2>&1; then
    CGREL040="$(XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" systemctl --user show -p ControlGroup --value "${UNIT040}.scope" 2>/dev/null)"
    [[ -n "$CGREL040" ]] && CGDIR040="/sys/fs/cgroup${CGREL040}"
  fi
  ESCAPEE_FOUND=no
  if [[ -n "$CGDIR040" && -f "$CGDIR040/cgroup.procs" ]]; then
    while read -r cp; do
      [[ "$cp" =~ ^[0-9]+$ ]] || continue
      sid="$(ps -o sid= -p "$cp" 2>/dev/null | tr -d ' ')"
      pgid_of_cp="$(ps -o pgid= -p "$cp" 2>/dev/null | tr -d ' ')"
      # The escapee's own sid==pgid==itself (setsid), distinct from any
      # sibling in the same cgroup that ISN'T the escapee.
      if [[ -n "$sid" && "$sid" == "$pgid_of_cp" && "$sid" == "$cp" ]]; then
        ESCAPEE_FOUND=yes
      fi
    done < "$CGDIR040/cgroup.procs"
  fi
  assert_eq "TC-LGC7-041: setsid-escaped grandchild is genuinely listed in the scope's OWN cgroup.procs before any kill (real escape, not merely a live child)" "yes" "$ESCAPEE_FOUND"

  # TC-LGC7-042: cgroup.procs stat-size-vs-content quirk regression pin.
  if [[ -n "$CGDIR040" && -f "$CGDIR040/cgroup.procs" ]]; then
    STATSIZE042="$(stat -c %s "$CGDIR040/cgroup.procs" 2>/dev/null)"
    NONEMPTY_VIA_S=no
    [[ -s "$CGDIR040/cgroup.procs" ]] && NONEMPTY_VIA_S=yes
    if [[ "$STATSIZE042" == "0" && "$NONEMPTY_VIA_S" == "no" && "$ESCAPEE_FOUND" == yes ]]; then
      assert_pass "TC-LGC7-042: cgroup.procs reports stat-size 0 even though a live pid is listed — confirms the [[ -s ]] footgun is real, and _lane_cgroup_empty must read content, not stat"
    else
      assert_skip "TC-LGC7-042: [[ -s ]] footgun timing-dependent reproduction" "stat_size=$STATSIZE042 -s=$NONEMPTY_VIA_S escapee=$ESCAPEE_FOUND (population may have changed between checks)"
    fi
  else
    assert_fail "TC-LGC7-042: could not resolve cgroup dir for $UNIT040"
  fi

  # TC-LGC7-043: bare unit name (no .scope) fails; suffixed form succeeds.
  systemctl --user kill -s TERM "$UNIT040" >/dev/null 2>"$TMPROOT/tc043.bare.err"
  RC043_BARE=$?
  assert_eq "TC-LGC7-043: systemctl --user kill WITHOUT .scope suffix fails to resolve the unit" "1" "$RC043_BARE"

  # Now perform the real lane_kill (exercises _lane_scope_kill end to end,
  # including the CORRECT suffixed kill this pins).
  LANE040=$(cat "$TMPROOT/tc040.lanedir" 2>/dev/null)
  ( source "$LIB_LANE"; lane_kill "$LANE040" 5 ) >/dev/null 2>&1
  sleep 0.5

  ESCAPEE_ALIVE=no
  if [[ -n "$CGDIR040" ]]; then
    [[ -f "$CGDIR040/cgroup.procs" ]] && ESCAPEE_ALIVE=yes  # dir gone entirely = definitely dead
  fi
  assert_eq "TC-LGC7-040: lane_kill's scope fast path reaps the setsid-escaped grandchild via cgroup.kill" "no" "$ESCAPEE_ALIVE"

  wait "$FIXTURE040" 2>/dev/null || true

  # TC-LGC7-044: _lane_scope_kill no-ops on a pgid-backend lane (never
  # calls systemctl at all — tripwire via a shim that fails loudly if hit).
  TRIPWIRE_BIN="$TMPROOT/tripwire-bin"
  mkdir -p "$TRIPWIRE_BIN"
  cat > "$TRIPWIRE_BIN/systemctl" <<'EOF'
#!/bin/bash
echo "TRIPWIRE: systemctl called with: $*" >> "${TRIPWIRE_LOG:?}"
exit 1
EOF
  chmod +x "$TRIPWIRE_BIN/systemctl"
  NS044="lgc7-044"
  export ADT_STATE_ROOT="$(_lane_state_root "$NS044")"
  rm -f "$TMPROOT/tc044.tripwire"
  PATH="$TRIPWIRE_BIN:$PATH" TRIPWIRE_LOG="$TMPROOT/tc044.tripwire" bash -c '
    source "'"$LIB_LANE"'"
    LANE_ID=$(lane_mint proj044 dev 44)
    LANE_DIR=$(lane_install proj044 "$LANE_ID")
    lane_set "$LANE_DIR" BACKEND pgid
    lane_set "$LANE_DIR" UNIT -
    _lane_scope_kill "$LANE_DIR" 1
  ' >/dev/null 2>&1
  if [[ -f "$TMPROOT/tc044.tripwire" ]]; then
    assert_fail "TC-LGC7-044: _lane_scope_kill called systemctl on a pgid-backend lane: $(cat "$TMPROOT/tc044.tripwire")"
  else
    assert_pass "TC-LGC7-044: _lane_scope_kill is a true no-op on a pgid-backend lane (never invokes systemctl)"
  fi

  # TC-LGC7-045: scope-backend lane whose UNIT was never actually created —
  # no-op, no error.
  NS045="lgc7-045"
  export ADT_STATE_ROOT="$(_lane_state_root "$NS045")"
  OUT045=$(bash -c '
    source "'"$LIB_LANE"'"
    LANE_ID=$(lane_mint proj045 dev 45)
    LANE_DIR=$(lane_install proj045 "$LANE_ID")
    lane_set "$LANE_DIR" BACKEND systemd-scope
    lane_set "$LANE_DIR" UNIT "adt-never-created-unit-045"
    _lane_scope_kill "$LANE_DIR" 1
    echo "RC=$?"
  ' 2>&1)
  assert_contains "TC-LGC7-045: _lane_scope_kill on a never-created unit degrades silently (rc 0, no error text)" "RC=0" "$OUT045"
else
  assert_skip "TC-LGC7-040..045: REAL cgroup reap semantics" "systemd-run/loginctl/systemctl not all present on PATH"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC7-050/051/052: kill-path argv + cgroupfs fallback (SHIM) ==="
# ===========================================================================
# Real cgroupfs lives at a fixed kernel-controlled mount point an
# unprivileged test cannot fake in place. `_LANE_CGROUP_ROOT_OVERRIDE`
# (test-only seam on `_lane_cgroup_path`) is set to EMPTY here so the
# `systemctl --user show -p ControlGroup --value` shim can simply echo the
# fixture directory's own FULL path — `_lane_cgroup_path` then joins
# `""` + that full path unchanged, exercising the exact same join logic
# production uses against `/sys/fs/cgroup` + a relative ControlGroup value.
export _LANE_CGROUP_ROOT_OVERRIDE=""

rm -f "$TMPROOT/tc050.argv"
NS050="lgc7-050"
export ADT_STATE_ROOT="$(_lane_state_root "$NS050")"
FAKE_CGDIR="$TMPROOT/fake-cgroup"
mkdir -p "$FAKE_CGDIR"
: > "$FAKE_CGDIR/cgroup.procs"          # empty immediately (fast pass)
: > "$FAKE_CGDIR/cgroup.kill"
cat > "$SHIM_BIN/systemctl" <<EOF
#!/bin/bash
echo "\$@" >> "$TMPROOT/tc050.argv"
case "\$1 \$2" in
  "--user show") echo "$FAKE_CGDIR" ;;
  "--user kill") exit 0 ;;
esac
exit 0
EOF
chmod +x "$SHIM_BIN/systemctl"
PATH="$SHIM_BIN:$PATH" XDG_RUNTIME_DIR="$XDG_SHIM_DIR" _LANE_CGROUP_ROOT_OVERRIDE="" bash -c '
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint proj050 dev 50)
  LANE_DIR=$(lane_install proj050 "$LANE_ID")
  lane_set "$LANE_DIR" BACKEND systemd-scope
  lane_set "$LANE_DIR" UNIT "adt-tc-lgc7-050"
  _lane_scope_kill "$LANE_DIR" 1
' >/dev/null 2>&1
ARGV050=$(cat "$TMPROOT/tc050.argv" 2>/dev/null)
assert_contains "TC-LGC7-050: kill-path issues 'kill -s TERM adt-tc-lgc7-050.scope'" "kill -s TERM adt-tc-lgc7-050.scope" "$ARGV050"
assert_contains "TC-LGC7-050b: kill-path resolves cgroup via 'show -p ControlGroup --value adt-tc-lgc7-050.scope'" "show -p ControlGroup --value adt-tc-lgc7-050.scope" "$ARGV050"

# TC-LGC7-051: cgroup.kill IS written when the fixture cgroup NEVER
# empties within the grace window (proves the escalation to cgroup.kill
# actually fires, not merely that the poll loop runs).
FAKE_CGDIR2="$TMPROOT/fake-cgroup2"
mkdir -p "$FAKE_CGDIR2"
echo "99999" > "$FAKE_CGDIR2/cgroup.procs"   # never empties within grace
: > "$FAKE_CGDIR2/cgroup.kill"
cat > "$SHIM_BIN/systemctl" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "--user show") echo "$FAKE_CGDIR2" ;;
  "--user kill") exit 0 ;;
esac
exit 0
EOF
chmod +x "$SHIM_BIN/systemctl"
PATH="$SHIM_BIN:$PATH" XDG_RUNTIME_DIR="$XDG_SHIM_DIR" _LANE_CGROUP_ROOT_OVERRIDE="" bash -c '
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint proj051 dev 51)
  LANE_DIR=$(lane_install proj051 "$LANE_ID")
  lane_set "$LANE_DIR" BACKEND systemd-scope
  lane_set "$LANE_DIR" UNIT "adt-tc-lgc7-051"
  _lane_scope_kill "$LANE_DIR" 1
' >/dev/null 2>&1
KILLCONTENT051=$(cat "$FAKE_CGDIR2/cgroup.kill" 2>/dev/null | tr -d '[:space:]')
assert_eq "TC-LGC7-051: cgroup.kill written with '1' when the fixture cgroup never empties within grace" "1" "$KILLCONTENT051"

# TC-LGC7-052: no cgroup.kill file present (pre-5.14 simulation) -> falls
# back to per-pid KILL over cgroup.procs, never errors.
FAKE_CGDIR3="$TMPROOT/fake-cgroup3"
mkdir -p "$FAKE_CGDIR3"
echo "1" > "$FAKE_CGDIR3/cgroup.procs"   # pid 1 is always kill-able-attempted but harmless (kill -KILL 1 as non-root fails silently)
cat > "$SHIM_BIN/systemctl" <<EOF
#!/bin/bash
case "\$1 \$2" in
  "--user show") echo "$FAKE_CGDIR3" ;;
  "--user kill") exit 0 ;;
esac
exit 0
EOF
chmod +x "$SHIM_BIN/systemctl"
OUT052=$(PATH="$SHIM_BIN:$PATH" XDG_RUNTIME_DIR="$XDG_SHIM_DIR" _LANE_CGROUP_ROOT_OVERRIDE="" bash -c '
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint proj052 dev 52)
  LANE_DIR=$(lane_install proj052 "$LANE_ID")
  lane_set "$LANE_DIR" BACKEND systemd-scope
  lane_set "$LANE_DIR" UNIT "adt-tc-lgc7-052"
  _lane_scope_kill "$LANE_DIR" 1
  echo "RC=$?"
' 2>&1)
assert_contains "TC-LGC7-052: no cgroup.kill file -> per-pid KILL fallback, no error propagated" "RC=0" "$OUT052"
unset _LANE_CGROUP_ROOT_OVERRIDE
_write_shim_all_pass  # restore the default shim for subsequent tests

# ===========================================================================
echo ""
echo "=== TC-LGC7-060/061: defense in depth — pgid escalation always also runs ==="
# ===========================================================================
NS060="lgc7-060"
export ADT_STATE_ROOT="$(_lane_state_root "$NS060")"
(
  source "$LIB_LANE"
  LANE_ID=$(lane_mint proj060 dev 60)
  LANE_DIR=$(lane_install proj060 "$LANE_ID")
  # Scope backend, but UNIT points nowhere real -> _lane_scope_kill no-ops.
  lane_set "$LANE_DIR" BACKEND systemd-scope
  lane_set "$LANE_DIR" UNIT "adt-never-created-unit-060"
  # A REAL pgid IS recorded independently of the (non-functional) scope backend.
  setsid sleep 30 &
  REALPGID=$!
  lane_record_pgid "$LANE_DIR" "$REALPGID" agent
  echo "$REALPGID" > "$TMPROOT/tc060.pgid"
  lane_kill "$LANE_DIR" 3
) >/dev/null 2>&1
PGID060=$(cat "$TMPROOT/tc060.pgid" 2>/dev/null)
if [[ -n "$PGID060" ]]; then
  kill -0 -- "-$PGID060" 2>/dev/null && ALIVE060=yes || ALIVE060=no
  assert_eq "TC-LGC7-060: pgid escalation still reaps the recorded group even when the scope path no-oped" "no" "$ALIVE060"
else
  assert_fail "TC-LGC7-060: fixture did not record a pgid"
fi

SCOPEKILL_LINE=$(grep -n '_lane_scope_kill "\$lane_dir" "\$grace"' "$LIB_LANE" | head -1 | cut -d: -f1)
PGID_LOOP_LINE=$(grep -n 'while read -r pg _rest; do' "$LIB_LANE" | tail -1 | cut -d: -f1)
if [[ -n "$SCOPEKILL_LINE" && -n "$PGID_LOOP_LINE" && "$SCOPEKILL_LINE" -lt "$PGID_LOOP_LINE" ]]; then
  assert_pass "TC-LGC7-061: source grep-pin — lane_kill's _lane_scope_kill call (line $SCOPEKILL_LINE) precedes the pgid escalation loop (line $PGID_LOOP_LINE)"
else
  assert_fail "TC-LGC7-061: expected _lane_scope_kill (line ${SCOPEKILL_LINE:-MISSING}) before the pgid loop (line ${PGID_LOOP_LINE:-MISSING})"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC7-070/071: guardian do_reap integration ==="
# ===========================================================================
DOREAP_SCOPEKILL_LINE=$(grep -n '_lane_scope_kill "\$LANE_DIR"' "$LIB_GUARDIAN" | head -1 | cut -d: -f1)
DOREAP_PGID_LOOP_LINE=$(grep -n 'while read -r pg _rest; do' "$LIB_GUARDIAN" | head -1 | cut -d: -f1)
if [[ -n "$DOREAP_SCOPEKILL_LINE" && -n "$DOREAP_PGID_LOOP_LINE" && "$DOREAP_SCOPEKILL_LINE" -lt "$DOREAP_PGID_LOOP_LINE" ]]; then
  assert_pass "TC-LGC7-070: source grep-pin — do_reap's _lane_scope_kill call (line $DOREAP_SCOPEKILL_LINE) precedes its pgid escalation loop (line $DOREAP_PGID_LOOP_LINE)"
else
  assert_fail "TC-LGC7-070: expected _lane_scope_kill (line ${DOREAP_SCOPEKILL_LINE:-MISSING}) before do_reap's pgid loop (line ${DOREAP_PGID_LOOP_LINE:-MISSING})"
fi

rm -f "$TMPROOT/tc071.argv"
NS071="lgc7-071"
export ADT_STATE_ROOT="$(_lane_state_root "$NS071")"
cat > "$SHIM_BIN/systemctl" <<EOF
#!/bin/bash
echo "\$@" >> "$TMPROOT/tc071.argv"
exit 0
EOF
chmod +x "$SHIM_BIN/systemctl"
# Mirrors test-lane-gc-p5-guardian.sh's own TC-LGC5-010 fixture shape: the
# write fd must be OPEN when the guardian's own read-side open runs (a
# writer must be present at that moment), THEN closed afterward to produce
# the EOF that wakes it — closing it BEFORE spawning the guardian would
# trip the no-writer watchdog instead of ever reaching do_reap. The
# guardian is `setsid`-detached (a session leader, not this subshell's
# direct child in job-control terms once `disown`ed), so `wait` on its pid
# is unreliable here ("not a child of this shell" — found empirically);
# poll from OUTSIDE the subshell on the guardian's own log file instead,
# same "wait for observable effect" pattern the REAL-class cgroup tests
# above use rather than a bare `wait`.
GUARDIANLOG071="$TMPROOT/tc071.guardianlog"
rm -f "$GUARDIANLOG071"
(
  PATH="$SHIM_BIN:$PATH" XDG_RUNTIME_DIR="$XDG_SHIM_DIR"
  export PATH XDG_RUNTIME_DIR
  source "$LIB_LANE"
  LANE_ID=$(lane_mint proj071 dev 71)
  LANE_DIR=$(lane_install proj071 "$LANE_ID")
  lane_set "$LANE_DIR" BACKEND systemd-scope
  lane_set "$LANE_DIR" UNIT "adt-tc-lgc7-071"
  mkfifo "$LANE_DIR/guard.fifo"
  exec {ADT_GUARD_FD}<>"$LANE_DIR/guard.fifo"
  export ADT_GUARD_FD
  setsid bash -c '[[ -n "${ADT_GUARD_FD:-}" ]] && exec {ADT_GUARD_FD}>&-; exec bash "$1" --lane-dir "$2"' \
    _ "$LIB_GUARDIAN" "$LANE_DIR" >"$GUARDIANLOG071" 2>&1 &
  disown 2>/dev/null || true
  sleep 0.3
  exec {ADT_GUARD_FD}>&-
) >/dev/null 2>&1
DEADLINE071=$(( $(date +%s) + 10 ))
while [[ $(date +%s) -lt $DEADLINE071 ]]; do
  grep -q "reap complete" "$GUARDIANLOG071" 2>/dev/null && break
  sleep 0.2
done
ARGV071=$(cat "$TMPROOT/tc071.argv" 2>/dev/null)
assert_contains "TC-LGC7-071: guardian do_reap issues the same kill -s TERM <unit>.scope call as lane_kill's own path" "kill -s TERM adt-tc-lgc7-071.scope" "$ARGV071"
_write_shim_all_pass

# ===========================================================================
echo ""
echo "=== TC-LGC7-080/081: lane-file recording (both branches) ==="
# ===========================================================================
# [Lane-GC PR-7 review round-1, P1-1] `ADT_LANE_BACKEND_OVERRIDE` may only
# NARROW `_lane_backend`'s result, never WIDEN it — `=systemd-scope` is a
# REQUEST that still must pass every real linger/bus/probe check, never a
# bypass. The real-host refusal assertion is conditional on the explicit-user
# Linger probe; a Linger=yes host skips it. TC-LGC7-011 covers the refusal
# branch deterministically. A scope-backend LANE FILE for downstream
# argv/kill-path tests is obtained via direct `lane_set` post-install (never
# via the override) throughout the rest of this suite.
NS080="lgc7-080"
export ADT_STATE_ROOT="$(_lane_state_root "$NS080")"
OUT080=$(ADT_LANE_BACKEND_OVERRIDE=systemd-scope bash -c '
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint proj080 dev 80)
  LANE_DIR=$(lane_install proj080 "$LANE_ID")
  echo "BACKEND=$(lane_get "$LANE_DIR" BACKEND)"
  echo "UNIT=$(lane_get "$LANE_DIR" UNIT)"
')
BACKEND080=$(echo "$OUT080" | grep -o 'BACKEND=.*' | cut -d= -f2)
UNIT080=$(echo "$OUT080" | grep -o 'UNIT=.*' | cut -d= -f2)
if [[ "$REAL_LINGER" == "yes" ]]; then
  assert_skip "TC-LGC7-080: override-cannot-widen on a Linger=no host" "this host's REAL Linger is 'yes' — the narrowing scenario this test targets does not apply here"
  assert_skip "TC-LGC7-080b: UNIT sentinel on override-refused host" "same as above"
else
  assert_eq "TC-LGC7-080: ADT_LANE_BACKEND_OVERRIDE=systemd-scope on a REAL Linger=no host does NOT widen the result — lane file still records BACKEND=pgid (override can only narrow, never bypass the linger gate)" "pgid" "$BACKEND080"
  assert_eq "TC-LGC7-080b: UNIT=- sentinel (pgid backend, override request refused by the real linger check)" "-" "$UNIT080"
fi

NS080B="lgc7-080b"
export ADT_STATE_ROOT="$(_lane_state_root "$NS080B")"
OUT080B=$(ADT_LANE_BACKEND_OVERRIDE=pgid bash -c '
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint proj080b dev 80)
  LANE_DIR=$(lane_install proj080b "$LANE_ID")
  echo "BACKEND=$(lane_get "$LANE_DIR" BACKEND)"
')
BACKEND080B=$(echo "$OUT080B" | grep -o 'BACKEND=.*' | cut -d= -f2)
assert_eq "TC-LGC7-080c: ADT_LANE_BACKEND_OVERRIDE=pgid unconditionally forces pgid (the only direction the override may widen FROM — pgid is always safe)" "pgid" "$BACKEND080B"

NS081="lgc7-081"
export ADT_STATE_ROOT="$(_lane_state_root "$NS081")"
if [[ "$REAL_SYSTEMD" == true ]]; then
  if [[ "$REAL_LINGER" != "yes" ]]; then
    OUT081=$(bash -c '
      source "'"$LIB_LANE"'"
      LANE_ID=$(lane_mint proj081 dev 81)
      LANE_DIR=$(lane_install proj081 "$LANE_ID")
      echo "BACKEND=$(lane_get "$LANE_DIR" BACKEND)"
      echo "UNIT=$(lane_get "$LANE_DIR" UNIT)"
    ')
    BACKEND081=$(echo "$OUT081" | grep -o 'BACKEND=.*' | cut -d= -f2)
    UNIT081=$(echo "$OUT081" | grep -o 'UNIT=.*' | cut -d= -f2)
    assert_eq "TC-LGC7-081: no override on this Linger=no host -> BACKEND=pgid" "pgid" "$BACKEND081"
    assert_eq "TC-LGC7-081b: UNIT=- sentinel" "-" "$UNIT081"
  else
    assert_skip "TC-LGC7-081: no-override real-host recording" "this host's real Linger is 'yes'"
    assert_skip "TC-LGC7-081b: UNIT=- sentinel" "same as above"
  fi
else
  assert_skip "TC-LGC7-081: no-override real-host recording" "systemd-run/loginctl/systemctl not all present on PATH"
  assert_skip "TC-LGC7-081b: UNIT=- sentinel" "same as above"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC7-090: regression pin — pgid path never invokes systemctl/systemd-run ==="
# ===========================================================================
TRIPWIRE_BIN2="$TMPROOT/tripwire-bin2"
mkdir -p "$TRIPWIRE_BIN2"
cat > "$TRIPWIRE_BIN2/systemctl" <<'EOF'
#!/bin/bash
echo "TRIPWIRE-systemctl: $*" >> "${TRIPWIRE_LOG2:?}"
exit 1
EOF
cat > "$TRIPWIRE_BIN2/systemd-run" <<'EOF'
#!/bin/bash
echo "TRIPWIRE-systemd-run: $*" >> "${TRIPWIRE_LOG2:?}"
exit 1
EOF
chmod +x "$TRIPWIRE_BIN2/systemctl" "$TRIPWIRE_BIN2/systemd-run"
NS090="lgc7-090"
export ADT_STATE_ROOT="$(_lane_state_root "$NS090")"
rm -f "$TMPROOT/tc090.tripwire"
PATH="$TRIPWIRE_BIN2:$PATH" TRIPWIRE_LOG2="$TMPROOT/tc090.tripwire" bash -c '
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint proj090 dev 90)
  LANE_DIR=$(lane_install proj090 "$LANE_ID")
  lane_set "$LANE_DIR" BACKEND pgid
  lane_set "$LANE_DIR" UNIT -
  lane_spawn "$LANE_DIR" agent -- sleep 5 &
  SPAWNER=$!
  sleep 0.3
  lane_kill "$LANE_DIR" 2
  wait "$SPAWNER" 2>/dev/null
' >/dev/null 2>&1
if [[ -f "$TMPROOT/tc090.tripwire" ]]; then
  assert_fail "TC-LGC7-090: a pgid-backend lane_spawn+lane_kill roundtrip invoked systemctl/systemd-run: $(cat "$TMPROOT/tc090.tripwire")"
else
  assert_pass "TC-LGC7-090: pgid-backend lane_spawn+lane_kill NEVER invokes systemctl/systemd-run (byte-equivalent to pre-PR-7 behavior)"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC7-100: mixed fleet — one pgid lane + one degraded scope lane, both reaped ==="
# ===========================================================================
NS100="lgc7-100"
export ADT_STATE_ROOT="$(_lane_state_root "$NS100")"
(
  source "$LIB_LANE"
  LANE_ID_A=$(lane_mint proj100 dev 100)
  LANE_DIR_A=$(lane_install proj100 "$LANE_ID_A")
  lane_set "$LANE_DIR_A" BACKEND pgid
  lane_set "$LANE_DIR_A" UNIT -
  setsid sleep 30 &
  PGID_A=$!
  lane_record_pgid "$LANE_DIR_A" "$PGID_A" agent
  echo "$PGID_A" > "$TMPROOT/tc100.pgidA"

  LANE_ID_B=$(lane_mint proj100 dev 101)
  LANE_DIR_B=$(lane_install proj100 "$LANE_ID_B")
  lane_set "$LANE_DIR_B" BACKEND systemd-scope
  lane_set "$LANE_DIR_B" UNIT "adt-never-created-unit-100b"
  setsid sleep 30 &
  PGID_B=$!
  lane_record_pgid "$LANE_DIR_B" "$PGID_B" agent
  echo "$PGID_B" > "$TMPROOT/tc100.pgidB"

  # Simulate GC rule 1.3's own call shape: lane_kill on each dead lane.
  lane_kill "$LANE_DIR_A" 3
  echo "$?" > "$TMPROOT/tc100.rcA"
  lane_kill "$LANE_DIR_B" 3
  echo "$?" > "$TMPROOT/tc100.rcB"
) >/dev/null 2>&1
PGID_A100=$(cat "$TMPROOT/tc100.pgidA" 2>/dev/null)
PGID_B100=$(cat "$TMPROOT/tc100.pgidB" 2>/dev/null)
RCA100=$(cat "$TMPROOT/tc100.rcA" 2>/dev/null)
RCB100=$(cat "$TMPROOT/tc100.rcB" 2>/dev/null)
kill -0 -- "-$PGID_A100" 2>/dev/null && ALIVE_A100=yes || ALIVE_A100=no
kill -0 -- "-$PGID_B100" 2>/dev/null && ALIVE_B100=yes || ALIVE_B100=no
assert_eq "TC-LGC7-100: mixed fleet — pgid lane reaped with no error" "no" "$ALIVE_A100"
assert_eq "TC-LGC7-100b: mixed fleet — rc from lane_kill(pgid lane) is 0" "0" "$RCA100"
assert_eq "TC-LGC7-100c: mixed fleet — degraded scope lane ALSO reaped (via its own pgid) with no error" "no" "$ALIVE_B100"
assert_eq "TC-LGC7-100d: mixed fleet — rc from lane_kill(degraded scope lane) is 0 (scope no-op did not propagate an error)" "0" "$RCB100"

# ===========================================================================
echo ""
echo "=== adt-gc.sh --doctor spot-check: bus-socket line + backend_eligibility= ==="
# ===========================================================================
NS_DOCTOR="lgc7-doctor"
export ADT_STATE_ROOT="$(_lane_state_root "$NS_DOCTOR")"
DOCTOR_OUT=$(bash "$ADT_GC" --doctor 2>&1)
assert_contains "TC-LGC7-DOCTOR-1: --doctor output includes a backend_eligibility= line" "backend_eligibility=" "$DOCTOR_OUT"
assert_contains "TC-LGC7-DOCTOR-2: --doctor output includes a user-bus-socket line" "bus socket" "$DOCTOR_OUT"

echo ""
echo "======================================================================"
echo "RESULTS: $PASS passed, $FAIL failed, $SKIPPED skipped"
echo "======================================================================"
[[ "$FAIL" -eq 0 ]]
