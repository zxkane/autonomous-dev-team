#!/bin/bash
# test-lane-gc-p6-gate.sh — Unit tests for issue #382 (Lane-GC series PR-6,
# design docs/designs/lane-containment-gc.md §4-C6; INV-119).
#
# Covers:
#   - dispatch-local.sh's back-pressure admission gate: four independent
#     signals (load/core, MemAvailable, swap%, global live-lane count),
#     each fired independently via test-only override seams; the
#     pre-refusal `adt-gc.sh --quick` reclaim attempt (PATH-shim stub);
#     the "re-check once" semantics (pressure clears after --quick);
#     the defer marker; the registry-count vs PID-file-fallback branches
#     of `lib-lane.sh::lane_global_live_count`; the grep-pin proving the
#     gate's own code never signals a process; marker cleanup on the next
#     successful dispatch.
#   - lib-dispatch.sh's rc=75 attribution: `is_dispatch_deferred_rc`,
#     `handle_dispatch_deferred`'s marker-release + label-revert.
#   - The remote DEFERRED chain: `liveness-check-remote-aws-ssm.sh`'s
#     DEFERRED verdict (mock-SSM), `_remote_pid_alive_query`'s parse,
#     `pid_alive`'s side-channel, and `dispatcher-tick.sh` Step 5b's
#     DEFERRED fast-return (extracted + driven in isolation).
#
# Full scenario list: docs/test-cases/lane-gc-p6-gate.md (TC-LGC6-*).
#
# Run: bash tests/unit/test-lane-gc-p6-gate.sh
# (Run under `bash`, and once under `env -u PROJECT_DIR bash ...` for CI
# parity — ambient PROJECT_DIR contaminates lib-config.sh's conf lookup in
# some sibling suites.)

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB_LANE="$SCRIPTS/lib-lane.sh"
LIB_DISPATCH="$SCRIPTS/lib-dispatch.sh"
DISPATCH_LOCAL="$SCRIPTS/dispatch-local.sh"
TICK="$SCRIPTS/dispatcher-tick.sh"
LIVENESS_DRIVER="$SCRIPTS/liveness-check-remote-aws-ssm.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert_pass() { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
assert_fail() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then assert_pass "$desc"; else assert_fail "$desc (expected [$expected] got [$actual])"; fi
}
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then assert_pass "$desc"; else assert_fail "$desc (needle='$needle' not found in: ${haystack:0:300})"; fi
}
assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then assert_pass "$desc"; else assert_fail "$desc (needle='$needle' unexpectedly found)"; fi
}

for f in "$LIB_LANE" "$LIB_DISPATCH" "$DISPATCH_LOCAL" "$TICK" "$LIVENESS_DRIVER"; do
  [[ -f "$f" ]] || { echo -e "${RED}FATAL${NC}: $f not found"; exit 1; }
done

TMPROOT=$(mktemp -d)
# EXIT trap pkills every fixture spawned under TMPROOT by path, then removes
# the tree — house convention (test-lane-gc-p3-kill-paths.sh /
# test-lane-gc-p5-guardian.sh).
trap 'pkill -9 -f "$TMPROOT" 2>/dev/null; rm -rf "$TMPROOT"' EXIT

# ===========================================================================
# Fixture project scaffold — mirrors test-dispatch-local-log-retention.sh's
# sandbox: a project dir with symlinked dispatch-local.sh + libs, a conf,
# and stub dev/review wrappers.
# ===========================================================================
_mk_fixture_project() {
  local proj="$1"
  mkdir -p "$proj/scripts"
  cat > "$proj/scripts/autonomous-dev.sh" <<'STUB'
#!/bin/bash
sleep 5
STUB
  chmod +x "$proj/scripts/autonomous-dev.sh"
  cp "$proj/scripts/autonomous-dev.sh" "$proj/scripts/autonomous-review.sh"
  cat > "$proj/scripts/autonomous.conf" <<CONF
PROJECT_ID="gatetest"
REPO="test/test"
REPO_OWNER="test"
REPO_NAME="test"
PROJECT_DIR="$proj"
AGENT_CMD="claude"
GH_AUTH_MODE="token"
CONF
  local lf
  for lf in dispatch-local.sh lib-config.sh lib-lane.sh; do
    ln -sf "$SCRIPTS/$lf" "$proj/scripts/$lf"
  done
}

# _run_dispatch <proj> <type> <issue> — invoke dispatch-local.sh, capturing
# stdout+stderr and rc. Caller sets env overrides before calling.
_run_dispatch() {
  local proj="$1" type="$2" issue="$3"
  ( cd "$proj" && bash scripts/dispatch-local.sh "$type" "$issue" ) 2>&1
}

# ===========================================================================
echo ""
echo "=== TC-LGC6-001/002/004: load, mem-floor, lane-cap each fire INDEPENDENTLY -> exit 75 + marker + logged reason ==="
# ===========================================================================
# Each case sets ONE signal to a distressed value and the other three to a
# healthy baseline, so a pass proves that ONE signal alone is sufficient to
# fire the gate — not merely that "some combination" fires it. The swap
# signal is NOT part of this loop as of [#441] — it is no longer strictly
# independent (see the dedicated TC-LGC6-003/003b/003c/003d block below).
_run_signal_case() {
  local sig="$1" issue="$2" load="$3" mem="$4" swap="$5" lanes="$6"
  local proj="$TMPROOT/proj-sig-$sig"
  _mk_fixture_project "$proj"
  local state="$TMPROOT/state-sig-$sig"
  ADT_STATE_ROOT="$state" \
  _GATE_LOAD1_PER_CORE_OVERRIDE="$load" \
  _GATE_MEM_AVAILABLE_MB_OVERRIDE="$mem" \
  _GATE_SWAP_PCT_OVERRIDE="$swap" \
  _GATE_LIVE_LANE_COUNT_OVERRIDE="$lanes" \
  bash -c "cd '$proj' && bash scripts/dispatch-local.sh dev-new $issue" 2>&1
  echo "__RC__:$?"
}

for spec in \
  "load:9001:99:999999:0:0:load1_per_core" \
  "mem:9002:0.1:1:0:0:mem_available_mb" \
  "lanecap:9004:0.1:999999:0:999:live_lane_count" \
; do
  IFS=: read -r sig issue load mem swap lanes reason_substr <<<"$spec"
  RAW=$(_run_signal_case "$sig" "$issue" "$load" "$mem" "$swap" "$lanes")
  RC=$(grep -o '__RC__:[0-9]*' <<<"$RAW" | cut -d: -f2)
  OUT=$(sed '$d' <<<"$RAW")
  assert_eq "TC-LGC6-00x ($sig): exit 75" "75" "$RC"
  assert_contains "TC-LGC6-00x ($sig): logged reason names the signal" "$reason_substr" "$OUT"
  MARKER="$TMPROOT/state-sig-$sig/autonomous-gatetest/lanes/.defer-issue-${issue}"
  if [[ -f "$MARKER" ]]; then
    assert_pass "TC-LGC6-00x ($sig): defer marker touched"
    assert_contains "TC-LGC6-00x ($sig): marker content names the reason" "$reason_substr" "$(cat "$MARKER")"
  else
    assert_fail "TC-LGC6-00x ($sig): defer marker NOT touched at $MARKER"
  fi
done

# ===========================================================================
echo ""
echo "=== TC-LGC6-003/003b/003c/003d: swap signal rescued by memory headroom ([#441], amends INV-119) ==="
# ===========================================================================
# GATE_MIN_MEM_MB default 2048, GATE_SWAP_REQUIRES_MEM_MULTIPLE default 3 ->
# rescue floor (swap_mem_gate_mb) = 6144.
_run_swap_case() {
  local case_id="$1" issue="$2" swap="$3" mem="$4"
  local proj="$TMPROOT/proj-swap-$case_id"
  _mk_fixture_project "$proj"
  local state="$TMPROOT/state-swap-$case_id"
  # mem is always set explicitly (never left to fall through to the real
  # box_health reading, which would leak the test-runner box's own actual
  # MemAvailable). "unavailable" is simulated with a non-numeric override
  # value ("unavailable") — _gate_override returns it verbatim (env override
  # always wins), and the gate's own `[[ "$memavail" =~ ^[0-9]+$ ]]` check
  # then correctly treats it as unknown, exactly as an absent box_health
  # field would be treated.
  ADT_STATE_ROOT="$state" \
  _GATE_LOAD1_PER_CORE_OVERRIDE="0.1" \
  _GATE_MEM_AVAILABLE_MB_OVERRIDE="$mem" \
  _GATE_SWAP_PCT_OVERRIDE="$swap" \
  _GATE_LIVE_LANE_COUNT_OVERRIDE="0" \
  bash -c "cd '$proj' && bash scripts/dispatch-local.sh dev-new $issue" 2>&1
  echo "__RC__:$?"
}

# TC-LGC6-003: high swap (99) + abundant memory (999999) -> dispatch now
# PROCEEDS (pre-#441 behavior: exit 75). This is the reported false-positive
# case (large-RAM host, stale swap accumulation, healthy MemAvailable).
RAW003=$(_run_swap_case "003" 9010 "99" "999999")
RC003=$(grep -o '__RC__:[0-9]*' <<<"$RAW003" | cut -d: -f2)
OUT003=$(sed '$d' <<<"$RAW003")
assert_eq "TC-LGC6-003: high swap + abundant memory -> rc=0 (memory-headroom rescue, [#441])" "0" "$RC003"
assert_contains "TC-LGC6-003: dispatch actually proceeded to spawn" "Dispatched dev-new for issue #9010" "$OUT003"
if [[ -f "$TMPROOT/state-swap-003/autonomous-gatetest/lanes/.defer-issue-9010" ]]; then
  assert_fail "TC-LGC6-003: no defer marker should exist when the swap signal is rescued by memory headroom"
else
  assert_pass "TC-LGC6-003: no defer marker when the swap signal is rescued by memory headroom"
fi

# TC-LGC6-003b: high swap (91) + mid-band memory (5000 — below the default
# rescue floor 6144, above the hard floor 2048) -> still DEFERS. Proves the
# early-warning band survives: memory headroom shrinking toward the hard
# floor while swap is also saturated is still informative.
RAW003b=$(_run_swap_case "003b" 9011 "91" "5000")
RC003b=$(grep -o '__RC__:[0-9]*' <<<"$RAW003b" | cut -d: -f2)
OUT003b=$(sed '$d' <<<"$RAW003b")
assert_eq "TC-LGC6-003b: high swap + mid-band memory (below rescue floor) -> rc=75 (early-warning band preserved)" "75" "$RC003b"
assert_contains "TC-LGC6-003b: logged reason names both swap_pct and the rescue floor" "swap_mem_gate_mb" "$OUT003b"

# TC-LGC6-003c: swap within limit (89) + the SAME mid-band memory (5000) ->
# dispatch PROCEEDS. Proves the new memory check inside the swap branch only
# engages when swap itself is already over GATE_SWAP_PCT — no new
# false-positive introduced on the memory axis alone (that's still owned
# entirely by the pre-existing, unchanged GATE_MIN_MEM_MB branch).
RAW003c=$(_run_swap_case "003c" 9012 "89" "5000")
RC003c=$(grep -o '__RC__:[0-9]*' <<<"$RAW003c" | cut -d: -f2)
OUT003c=$(sed '$d' <<<"$RAW003c")
assert_eq "TC-LGC6-003c: swap within limit + mid-band memory -> rc=0 (swap branch doesn't engage when swap itself is healthy)" "0" "$RC003c"
assert_contains "TC-LGC6-003c: dispatch actually proceeded to spawn" "Dispatched dev-new for issue #9012" "$OUT003c"

# TC-LGC6-003d: high swap (91) + memory signal non-numeric/unavailable ->
# still DEFERS. Proves the fail-toward-pre-#441-behavior default when the
# rescue evidence itself is unknown (absence of evidence is not evidence of
# headroom). "unavailable" is a non-numeric override value — the env
# override always wins over the real box_health reading (see
# _run_swap_case's own comment), so this is deterministic regardless of the
# test-runner box's actual MemAvailable.
RAW003d=$(_run_swap_case "003d" 9013 "91" "unavailable")
RC003d=$(grep -o '__RC__:[0-9]*' <<<"$RAW003d" | cut -d: -f2)
OUT003d=$(sed '$d' <<<"$RAW003d")
assert_eq "TC-LGC6-003d: high swap + non-numeric memory signal -> rc=75 (fails toward pre-#441 behavior)" "75" "$RC003d"
assert_contains "TC-LGC6-003d: logged reason records the unresolved mem_available_mb value" "mem_available_mb=unavailable" "$OUT003d"

# TC-LGC6-003e: a malformed GATE_SWAP_REQUIRES_MEM_MULTIPLE (operator typo in
# autonomous.conf) must fall back to the documented default (3), never crash
# the gate's arithmetic under `set -euo pipefail` (an unbound-variable error
# there would abort _gate_check_signals before it reaches the lane-cap check,
# and the caller's `reason="$(_gate_check_signals)"` would silently swallow
# it into an EMPTY reason string rather than surfacing a diagnostic).
PROJ003e="$TMPROOT/proj-swap-003e"
_mk_fixture_project "$PROJ003e"
STATE003e="$TMPROOT/state-swap-003e"
OUT003e=$(
  ADT_STATE_ROOT="$STATE003e" \
  GATE_SWAP_REQUIRES_MEM_MULTIPLE="not-a-number" \
  _GATE_LOAD1_PER_CORE_OVERRIDE="0.1" \
  _GATE_MEM_AVAILABLE_MB_OVERRIDE="999999" \
  _GATE_SWAP_PCT_OVERRIDE="99" \
  _GATE_LIVE_LANE_COUNT_OVERRIDE="0" \
  bash -c "cd '$PROJ003e' && bash scripts/dispatch-local.sh dev-new 9014" 2>&1
)
RC003e=$?
assert_eq "TC-LGC6-003e: malformed GATE_SWAP_REQUIRES_MEM_MULTIPLE falls back to default -> rc=0 (no crash, rescue still applies)" "0" "$RC003e"
assert_contains "TC-LGC6-003e: dispatch actually proceeded to spawn (proves the gate evaluated all signals, not just crashed silently)" "Dispatched dev-new for issue #9014" "$OUT003e"

# TC-LGC6-003f: high swap (91) + genuinely low memory (1000 — below the hard
# floor 2048, i.e. the true OOM-adjacent case from issue #441's second
# Testing Requirement) -> still DEFERS, exactly as before #441. At this
# memory level the pre-existing, unchanged mem-floor check (checked BEFORE
# the swap branch in the fixed load/mem/swap/lanecap order) fires first and
# short-circuits — the swap branch's own internal rescue check is never even
# reached. This is the "belt and suspenders" case the design doc's behavior
# table calls out explicitly: genuine pressure is still caught, just by the
# pre-existing signal rather than the new swap-branch predicate.
RAW003f=$(_run_swap_case "003f" 9015 "91" "1000")
RC003f=$(grep -o '__RC__:[0-9]*' <<<"$RAW003f" | cut -d: -f2)
OUT003f=$(sed '$d' <<<"$RAW003f")
assert_eq "TC-LGC6-003f: high swap + genuinely low memory (below hard floor) -> rc=75 (genuine-pressure case still defers)" "75" "$RC003f"
assert_contains "TC-LGC6-003f: logged reason names the mem-floor signal (fires before the swap branch is reached)" "mem_available_mb=1000 < GATE_MIN_MEM_MB=2048" "$OUT003f"

# ===========================================================================
echo ""
echo "=== TC-LGC6-010: healthy box (all four signals cleared) -> dispatch proceeds to spawn ==="
# ===========================================================================
PROJ010="$TMPROOT/proj010"
_mk_fixture_project "$PROJ010"
STATE010="$TMPROOT/state010"
OUT010=$(
  ADT_STATE_ROOT="$STATE010" \
  _GATE_LOAD1_PER_CORE_OVERRIDE="0.1" \
  _GATE_MEM_AVAILABLE_MB_OVERRIDE="999999" \
  _GATE_SWAP_PCT_OVERRIDE="0" \
  _GATE_LIVE_LANE_COUNT_OVERRIDE="0" \
  bash -c "cd '$PROJ010' && bash scripts/dispatch-local.sh dev-new 9002" 2>&1
)
RC010=$?
assert_eq "TC-LGC6-010: healthy box -> rc=0 (spawn attempt reached)" "0" "$RC010"
assert_contains "TC-LGC6-010: dispatched message printed (spawn actually attempted)" "Dispatched dev-new for issue #9002" "$OUT010"
if [[ -f "$STATE010/autonomous-gatetest/lanes/.defer-issue-9002" ]]; then
  assert_fail "TC-LGC6-010: no defer marker should exist on a healthy dispatch"
else
  assert_pass "TC-LGC6-010: no defer marker on a healthy dispatch"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC6-020: pre-refusal --quick is ATTEMPTED (PATH-shim adt-gc.sh records invocation) ==="
# ===========================================================================
PROJ020="$TMPROOT/proj020"
_mk_fixture_project "$PROJ020"
STATE020="$TMPROOT/state020"
FAKE_GC020="$TMPROOT/fake-gc-020.sh"
INVOKE_RECORD020="$TMPROOT/gc-invoked-020"
cat > "$FAKE_GC020" <<EOF
#!/bin/bash
echo "\$*" >> "$INVOKE_RECORD020"
exit 0
EOF
chmod +x "$FAKE_GC020"
: > "$INVOKE_RECORD020"
OUT020=$(
  ADT_STATE_ROOT="$STATE020" \
  _ADT_GC_ENTRY_OVERRIDE="$FAKE_GC020" \
  _GATE_LOAD1_PER_CORE_OVERRIDE="99" \
  _GATE_MEM_AVAILABLE_MB_OVERRIDE="999999" \
  _GATE_SWAP_PCT_OVERRIDE="0" \
  _GATE_LIVE_LANE_COUNT_OVERRIDE="0" \
  bash -c "cd '$PROJ020' && bash scripts/dispatch-local.sh dev-new 9003" 2>&1
)
RC020=$?
assert_eq "TC-LGC6-020: refusal path still exits 75 (fake GC does not clear the override)" "75" "$RC020"
INVOKE_LINES020=$(wc -l < "$INVOKE_RECORD020" | tr -d ' ')
# The opportunistic top-of-file call ALSO invokes ADT_GC_ENTRY once, so a
# healthy gate-firing dispatch invokes it exactly TWICE: once opportunistic,
# once from the gate's own refusal-path reclaim attempt.
assert_eq "TC-LGC6-020: fake adt-gc.sh invoked exactly twice (opportunistic + gate reclaim attempt)" "2" "$INVOKE_LINES020"
assert_contains "TC-LGC6-020: at least one invocation passed --quick" "--quick" "$(cat "$INVOKE_RECORD020")"

# ===========================================================================
echo ""
echo "=== TC-LGC6-030: re-check-once semantics — pressure clears after --quick -> dispatch proceeds ==="
# ===========================================================================
PROJ030="$TMPROOT/proj030"
_mk_fixture_project "$PROJ030"
STATE030="$TMPROOT/state030"
LOAD_FILE030="$TMPROOT/load-override-030"
echo "99" > "$LOAD_FILE030"
# The fake GC clears the pressure ONLY on its SECOND invocation — the FIRST
# invocation is the unconditional top-of-script opportunistic call, which
# must NOT be what proves "re-check once" (that would test nothing: the
# gate's own first check would already see healthy pressure and the
# refusal path would never even run). Only the gate's OWN reclaim call
# (inside its refusal path) is allowed to be the one that clears it.
GC_CALL_COUNT030="$TMPROOT/gc-call-count-030"
: > "$GC_CALL_COUNT030"
FAKE_GC030="$TMPROOT/fake-gc-030.sh"
cat > "$FAKE_GC030" <<EOF
#!/bin/bash
echo x >> "$GC_CALL_COUNT030"
n=\$(wc -l < "$GC_CALL_COUNT030")
if [[ "\$1" == "--quick" && "\$n" -ge 2 ]]; then
  echo "0.1" > "$LOAD_FILE030"
fi
exit 0
EOF
chmod +x "$FAKE_GC030"
OUT030=$(
  ADT_STATE_ROOT="$STATE030" \
  _ADT_GC_ENTRY_OVERRIDE="$FAKE_GC030" \
  _GATE_LOAD1_PER_CORE_OVERRIDE_FILE="$LOAD_FILE030" \
  _GATE_MEM_AVAILABLE_MB_OVERRIDE="999999" \
  _GATE_SWAP_PCT_OVERRIDE="0" \
  _GATE_LIVE_LANE_COUNT_OVERRIDE="0" \
  bash -c "cd '$PROJ030' && bash scripts/dispatch-local.sh dev-new 9004" 2>&1
)
RC030=$?
assert_eq "TC-LGC6-030: dispatch proceeds (rc=0) after --quick clears the injected pressure" "0" "$RC030"
assert_contains "TC-LGC6-030: 'dispatch proceeding' logged after the reclaim attempt" "dispatch proceeding" "$OUT030"
assert_contains "TC-LGC6-030: spawn actually attempted" "Dispatched dev-new for issue #9004" "$OUT030"
if [[ -f "$STATE030/autonomous-gatetest/lanes/.defer-issue-9004" ]]; then
  assert_fail "TC-LGC6-030: no defer marker should be left after a successful re-check-once recovery"
else
  assert_pass "TC-LGC6-030: no defer marker left after re-check-once recovery"
fi

# Counter-test: WITHOUT a fake GC that clears the pressure, the SAME
# scenario defers (proves TC-LGC6-030 isn't vacuously passing).
PROJ031="$TMPROOT/proj031"
_mk_fixture_project "$PROJ031"
STATE031="$TMPROOT/state031"
LOAD_FILE031="$TMPROOT/load-override-031"
echo "99" > "$LOAD_FILE031"
FAKE_GC031="$TMPROOT/fake-gc-031.sh"
cat > "$FAKE_GC031" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$FAKE_GC031"
OUT031=$(
  ADT_STATE_ROOT="$STATE031" \
  _ADT_GC_ENTRY_OVERRIDE="$FAKE_GC031" \
  _GATE_LOAD1_PER_CORE_OVERRIDE_FILE="$LOAD_FILE031" \
  _GATE_MEM_AVAILABLE_MB_OVERRIDE="999999" \
  _GATE_SWAP_PCT_OVERRIDE="0" \
  _GATE_LIVE_LANE_COUNT_OVERRIDE="0" \
  bash -c "cd '$PROJ031' && bash scripts/dispatch-local.sh dev-new 9005" 2>&1
)
RC031=$?
assert_eq "TC-LGC6-031: counter-test — pressure NOT cleared -> exit 75 (proves 030 isn't vacuous)" "75" "$RC031"

# ===========================================================================
echo ""
echo "=== TC-LGC6-040/041: lane_global_live_count — registry-count and PID-file-fallback branches ==="
# ===========================================================================
NS040="lgc6-040"
STATE040="$TMPROOT/state-$NS040"
OUT040=$(bash -c '
  export ADT_STATE_ROOT="'"$STATE040"'"
  source "'"$LIB_LANE"'"
  LANE_ID=$(lane_mint proj040 dev 100)
  LANE_DIR=$(lane_install proj040 "$LANE_ID")
  lane_global_live_count
')
assert_eq "TC-LGC6-040: registry-count branch counts one freshly-installed (self-referential, live) lane" "1" "$OUT040"

STATE041="$TMPROOT/state-lgc6-041"
mkdir -p "$STATE041/autonomous-proj041a" "$STATE041/autonomous-proj041b"
sleep 30 & PID041A=$!
sleep 30 & PID041B=$!
disown 2>/dev/null || true
echo "$PID041A" > "$STATE041/autonomous-proj041a/issue-1.pid"
echo "$PID041B" > "$STATE041/autonomous-proj041b/review-2.pid"
echo "999999999" > "$STATE041/autonomous-proj041b/issue-3.pid"  # dead pid, must not count
OUT041=$(bash -c '
  export ADT_STATE_ROOT="'"$STATE041"'"
  source "'"$LIB_LANE"'"
  lane_global_live_count
')
assert_eq "TC-LGC6-041: PID-file-fallback branch counts live PID files across projects, skips a dead one, when NO lanes/ dir exists anywhere" "2" "$OUT041"
kill -9 "$PID041A" "$PID041B" 2>/dev/null || true

# Fresh-host edge case (design's explicit AC): a project whose lanes/ dir
# exists but is EMPTY must NOT trip the fallback — it correctly contributes
# 0 via the registry path.
STATE042="$TMPROOT/state-lgc6-042"
mkdir -p "$STATE042/autonomous-proj042/lanes"
OUT042=$(bash -c '
  export ADT_STATE_ROOT="'"$STATE042"'"
  source "'"$LIB_LANE"'"
  lane_global_live_count
')
assert_eq "TC-LGC6-042: an EXISTING but EMPTY lanes/ dir uses the registry path (0), not the PID-file fallback" "0" "$OUT042"

# ===========================================================================
echo ""
echo "=== TC-LGC6-050: rc=75 attribution — no retry-budget decrement, no label change ==="
# ===========================================================================
# is_dispatch_deferred_rc: pure predicate, direct call.
export REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane PROJECT_ID=test-lgc6-050 MAX_RETRIES=3 MAX_CONCURRENT=5
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB_DISPATCH"
set +e

if is_dispatch_deferred_rc 75; then assert_pass "TC-LGC6-050: is_dispatch_deferred_rc(75) is true"; else assert_fail "TC-LGC6-050: is_dispatch_deferred_rc(75) should be true"; fi
if is_dispatch_deferred_rc 1; then assert_fail "TC-LGC6-050b: is_dispatch_deferred_rc(1) should be false"; else assert_pass "TC-LGC6-050b: is_dispatch_deferred_rc(1) is false"; fi
if is_dispatch_deferred_rc 0; then assert_fail "TC-LGC6-050c: is_dispatch_deferred_rc(0) should be false"; else assert_pass "TC-LGC6-050c: is_dispatch_deferred_rc(0) is false"; fi

# handle_dispatch_deferred: stub release_dispatch_marker + label_swap to
# observe both are called with the expected args, and that NEITHER
# count_retries/mark_stalled nor itp_post_comment fire.
_RELEASE_CALLS=()
_LABEL_SWAP_CALLS=()
_POST_COMMENT_CALLS=0
_COUNT_RETRIES_CALLS=0
release_dispatch_marker() { _RELEASE_CALLS+=("$1:$2"); }
label_swap() { _LABEL_SWAP_CALLS+=("$1:$2:$3"); }
itp_post_comment() { _POST_COMMENT_CALLS=$((_POST_COMMENT_CALLS + 1)); }
count_retries() { _COUNT_RETRIES_CALLS=$((_COUNT_RETRIES_CALLS + 1)); echo 0; }

handle_dispatch_deferred 4242 "dev-new" "in-progress" ""
assert_eq "TC-LGC6-050d: handle_dispatch_deferred releases the dispatch marker for (issue,mode)" "4242:dev-new" "${_RELEASE_CALLS[0]:-}"
assert_eq "TC-LGC6-050e: handle_dispatch_deferred reverts the label (args reversed from caller's swap)" "4242:in-progress:" "${_LABEL_SWAP_CALLS[0]:-}"
assert_eq "TC-LGC6-050f: handle_dispatch_deferred never posts a comment" "0" "$_POST_COMMENT_CALLS"
assert_eq "TC-LGC6-050g: handle_dispatch_deferred never calls count_retries (no retry-budget decrement)" "0" "$_COUNT_RETRIES_CALLS"

# ===========================================================================
echo ""
echo "=== TC-LGC6-060: grep/trace test — no kill/pkill/signal reachable from the gate's own code ==="
# ===========================================================================
GATE_BLOCK=$(awk '/^_run_adt_gc_quick\(\) \{$/,/^_admission_gate$/' "$DISPATCH_LOCAL")
# Positive extraction-control: a sed/awk range extraction that silently
# matches ZERO lines (e.g. after a future rename of either boundary marker)
# would make every downstream assertion over $GATE_BLOCK vacuously pass —
# assert on a KNOWN-present marker inside the range first, so a broken
# extraction fails LOUD here instead of green everywhere else.
if grep -q '_admission_gate() {' <<<"$GATE_BLOCK" && [[ "$(wc -l <<<"$GATE_BLOCK")" -gt 50 ]]; then
  assert_pass "TC-LGC6-060 (extraction control): GATE_BLOCK extraction captured the expected function body (non-trivial line count, contains _admission_gate's own definition)"
else
  assert_fail "TC-LGC6-060 (extraction control): GATE_BLOCK extraction is empty/truncated — the awk range markers no longer match dispatch-local.sh's structure; every assertion below this point is UNRELIABLE until fixed"
fi
# [review P2-1] Scoped to the ADMISSION-DECISION code only (never a claim
# about adt-gc.sh's own, separately-INV-117-governed, reclaim-step side
# effects — under ADT_GC_ENFORCE=1 that SEPARATE component can kill
# registry-dead-lane residue, authorized by ITS OWN decision table, not
# by this gate; see the honest-contract-scope comment in dispatch-local.sh
# itself). This grep-pin proves the gate's OWN code never issues a kill/
# pkill/signal to reach its defer-vs-proceed verdict.
GATE_CODE=$(grep -v '^\s*#' <<<"$GATE_BLOCK")
if grep -qE '\bkill\b|\bpkill\b|SIGTERM|SIGKILL' <<<"$GATE_CODE"; then
  assert_fail "TC-LGC6-060: gate's OWN admission-decision code contains a kill/pkill/signal reference (should be pure admission control)"
else
  assert_pass "TC-LGC6-060: gate's OWN admission-decision code (excluding comments) contains no kill/pkill/signal reference"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC6-070: marker cleanup on next successful dispatch (design §5) ==="
# ===========================================================================
PROJ070="$TMPROOT/proj070"
_mk_fixture_project "$PROJ070"
STATE070="$TMPROOT/state070"
MARKER070="$STATE070/autonomous-gatetest/lanes/.defer-issue-9006"
mkdir -p "$(dirname "$MARKER070")"
echo "stale reason from a prior deferred tick" > "$MARKER070"
OUT070=$(
  ADT_STATE_ROOT="$STATE070" \
  _GATE_LOAD1_PER_CORE_OVERRIDE="0.1" \
  _GATE_MEM_AVAILABLE_MB_OVERRIDE="999999" \
  _GATE_SWAP_PCT_OVERRIDE="0" \
  _GATE_LIVE_LANE_COUNT_OVERRIDE="0" \
  bash -c "cd '$PROJ070' && bash scripts/dispatch-local.sh dev-new 9006" 2>&1
)
RC070=$?
assert_eq "TC-LGC6-070: healthy dispatch after a stale marker still succeeds" "0" "$RC070"
if [[ -f "$MARKER070" ]]; then
  assert_fail "TC-LGC6-070: stale defer marker should be removed after a successful dispatch"
else
  assert_pass "TC-LGC6-070: stale defer marker removed after a successful dispatch"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC6-071: dispatch-local.sh writes the .attempt-<kind>-<N> token UNCONDITIONALLY (review P1-1) ==="
# ===========================================================================
# The attempt marker must exist after BOTH a deferred dispatch (rc=75) and a
# healthy one (rc=0) — it is written at the very TOP of the script, before
# the gate even runs, which is exactly what lets the remote liveness
# snippet compare a defer marker's freshness against it regardless of
# which outcome this particular attempt had.
PROJ071="$TMPROOT/proj071"
_mk_fixture_project "$PROJ071"
STATE071="$TMPROOT/state071"
ATTEMPT071="$STATE071/autonomous-gatetest/lanes/.attempt-issue-9007"

# Deferred attempt.
BEFORE071=$(date -u +%s)
ADT_STATE_ROOT="$STATE071" _GATE_LOAD1_PER_CORE_OVERRIDE="99" \
  bash -c "cd '$PROJ071' && bash scripts/dispatch-local.sh dev-new 9007" >/dev/null 2>&1
if [[ -f "$ATTEMPT071" ]]; then
  ATTEMPT_M071=$(stat -c %Y "$ATTEMPT071" 2>/dev/null || stat -f %m "$ATTEMPT071" 2>/dev/null)
  if [[ "$ATTEMPT_M071" -ge "$BEFORE071" ]]; then
    assert_pass "TC-LGC6-071: attempt marker written on a DEFERRED (rc=75) dispatch, with a fresh mtime"
  else
    assert_fail "TC-LGC6-071: attempt marker exists but mtime is stale (${ATTEMPT_M071} < ${BEFORE071})"
  fi
else
  assert_fail "TC-LGC6-071: attempt marker NOT written on a deferred dispatch"
fi

# Healthy attempt for the SAME (kind, issue) — must refresh (not merely
# leave) the attempt marker.
sleep 1
BEFORE071B=$(date -u +%s)
ADT_STATE_ROOT="$STATE071" _GATE_LOAD1_PER_CORE_OVERRIDE="0.1" \
  _GATE_MEM_AVAILABLE_MB_OVERRIDE="999999" _GATE_SWAP_PCT_OVERRIDE="0" _GATE_LIVE_LANE_COUNT_OVERRIDE="0" \
  bash -c "cd '$PROJ071' && bash scripts/dispatch-local.sh dev-new 9007" >/dev/null 2>&1
if [[ -f "$ATTEMPT071" ]]; then
  ATTEMPT_M071B=$(stat -c %Y "$ATTEMPT071" 2>/dev/null || stat -f %m "$ATTEMPT071" 2>/dev/null)
  if [[ "$ATTEMPT_M071B" -ge "$BEFORE071B" ]]; then
    assert_pass "TC-LGC6-071b: attempt marker also written (refreshed) on a healthy (rc=0) dispatch"
  else
    assert_fail "TC-LGC6-071b: attempt marker mtime not refreshed on the second (healthy) attempt"
  fi
else
  assert_fail "TC-LGC6-071b: attempt marker missing after the healthy dispatch"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC6-080: mock-SSM DEFERRED — liveness-check-remote-aws-ssm.sh emits the 4th verdict ==="
# ===========================================================================
STUB_BIN080="$TMPROOT/bin080"
mkdir -p "$STUB_BIN080"
# NOTE: the `\n` inside the heredoc below is a LITERAL two-character
# backslash-n sequence (single-quoted heredoc — no shell expansion), which
# is the JSON-escaped-newline form jq expects inside a JSON STRING value —
# mirrors test-liveness-check-remote-aws-ssm.sh's own stub exactly. Using
# `printf`'s `\n` (an ACTUAL newline byte embedded raw inside the JSON
# string) would produce invalid JSON and was the root cause of this test's
# first-draft failure (`jq: parse error: Invalid string: control
# characters... must be escaped`).
cat > "$STUB_BIN080/aws" <<'EOF'
#!/bin/bash
case "$*" in
  *send-command*) echo '{"Command":{"CommandId":"stub-1","Status":"Pending"}}' ;;
  *get-command-invocation*)
    echo '{"Status":"Success","StandardOutputContent":"DEFERRED\n45\n","StandardErrorContent":""}'
    ;;
esac
EOF
chmod +x "$STUB_BIN080/aws"
OUT080=$(
  PATH="$STUB_BIN080:$PATH" \
  SSM_INSTANCE_ID="i-test" SSM_REMOTE_PROJECT_ID="testproj" SSM_REMOTE_PROJECT_DIR="/data/git/test" \
  bash "$LIVENESS_DRIVER" issue 99
)
RC080=$?
assert_eq "TC-LGC6-080: mock-SSM DEFERRED -> driver rc=0" "0" "$RC080"
assert_eq "TC-LGC6-080b: driver stdout is exactly 'DEFERRED\\n45'" "$(printf 'DEFERRED\n45')" "$OUT080"

# Counter-test: an unparseable age line on the DEFERRED path is indeterminate
# (rc=2), never a fabricated DEFERRED verdict with garbage age.
STUB_BIN081="$TMPROOT/bin081"
mkdir -p "$STUB_BIN081"
cat > "$STUB_BIN081/aws" <<'EOF'
#!/bin/bash
case "$*" in
  *send-command*) echo '{"Command":{"CommandId":"stub-1","Status":"Pending"}}' ;;
  *get-command-invocation*)
    echo '{"Status":"Success","StandardOutputContent":"DEFERRED\nnot-a-number\n","StandardErrorContent":""}'
    ;;
esac
EOF
chmod +x "$STUB_BIN081/aws"
OUT081=$(
  PATH="$STUB_BIN081:$PATH" \
  SSM_INSTANCE_ID="i-test" SSM_REMOTE_PROJECT_ID="testproj" SSM_REMOTE_PROJECT_DIR="/data/git/test" \
  bash "$LIVENESS_DRIVER" issue 99 2>/dev/null
)
RC081=$?
assert_eq "TC-LGC6-081: DEFERRED with an unparseable age -> rc=2 (indeterminate), not a fabricated verdict" "2" "$RC081"
assert_eq "TC-LGC6-081b: stdout empty on the malformed-age path" "" "$OUT081"

# TC-LGC6-082 (review P2-2): trailing garbage after the age line must ALSO
# degrade to indeterminate — anchored exactly like ALIVE/DEAD's own
# exact-match case, never merely "line 1 and line 2 happen to look right."
STUB_BIN082="$TMPROOT/bin082"
mkdir -p "$STUB_BIN082"
cat > "$STUB_BIN082/aws" <<'EOF'
#!/bin/bash
case "$*" in
  *send-command*) echo '{"Command":{"CommandId":"stub-1","Status":"Pending"}}' ;;
  *get-command-invocation*)
    echo '{"Status":"Success","StandardOutputContent":"DEFERRED\n45\nEXTRA GARBAGE LINE\n","StandardErrorContent":""}'
    ;;
esac
EOF
chmod +x "$STUB_BIN082/aws"
OUT082=$(
  PATH="$STUB_BIN082:$PATH" \
  SSM_INSTANCE_ID="i-test" SSM_REMOTE_PROJECT_ID="testproj" SSM_REMOTE_PROJECT_DIR="/data/git/test" \
  bash "$LIVENESS_DRIVER" issue 99 2>/dev/null
)
RC082=$?
assert_eq "TC-LGC6-082: DEFERRED with trailing garbage after the age line -> rc=2 (indeterminate), never a fabricated verdict" "2" "$RC082"
assert_eq "TC-LGC6-082b: stdout empty on the trailing-garbage path" "" "$OUT082"

# ===========================================================================
echo ""
echo "=== TC-LGC6-083..087: real snippet marker-comparison logic (review P1-1/P3-2) ==="
# ===========================================================================
# Extracts the ACTUAL DEFERRED-decision block from liveness-check-remote-
# aws-ssm.sh's own INNER_CMD heredoc (not a re-implementation — the exact
# lines the remote snippet runs) and drives it against REAL fixture marker
# files with REAL mtimes, proving the freshness-vs-attempt-marker
# comparison and the max-age secondary bound behave exactly as designed —
# this is also the natural home for P1-1's token-comparison coverage the
# mock-string-injection tests above cannot exercise (they inject a canned
# STRING as if the remote host already decided; these tests prove the
# remote host's OWN decision logic against real files).
_extract_snippet_defer_block() {
  awk '
    /^if \[ -f "\\\$DEFER_MARKER" \] && \[ ! -L "\\\$DEFER_MARKER" \]; then$/ { f = 1 }
    f { print; if (/^fi$/) exit }
  ' "$LIVENESS_DRIVER" | sed 's/\\\$/$/g'
}
SNIPPET_DEFER_BLOCK=$(_extract_snippet_defer_block)
if [[ -z "$SNIPPET_DEFER_BLOCK" ]] || ! grep -q 'NOT_SUPERSEDED' <<<"$SNIPPET_DEFER_BLOCK"; then
  assert_fail "TC-LGC6-083 (extraction control): could not extract the real DEFERRED-decision block from the INNER_CMD heredoc — liveness-check-remote-aws-ssm.sh structure drifted"
else
  assert_pass "TC-LGC6-083 (extraction control): extracted the real snippet's own DEFERRED-decision block (contains NOT_SUPERSEDED)"
fi

_drive_snippet_defer_block() {
  local state_root="$1"
  SSM_REMOTE_PROJECT_ID=testproj ADT_STATE_ROOT="$state_root" bash -c "
    KIND=issue N=99 HBI=120 DEFER_MAX_AGE=900
    LANE_DIR=\"\${ADT_STATE_ROOT:-\$HOME/.local/state}/autonomous-\${SSM_REMOTE_PROJECT_ID}/lanes\"
    DEFER_MARKER=\"\${LANE_DIR}/.defer-\${KIND}-\${N}\"
    ATTEMPT_MARKER=\"\${LANE_DIR}/.attempt-\${KIND}-\${N}\"
    $SNIPPET_DEFER_BLOCK
    echo DEAD
  "
}

# TC-LGC6-084: fresh defer (same mtime as the attempt marker — the common
# same-run case) -> DEFERRED.
STATE084="$TMPROOT/state084"; LANE_DIR084="$STATE084/autonomous-testproj/lanes"
mkdir -p "$LANE_DIR084"
NOW084=$(date -u +%s)
touch -d "@${NOW084}" "$LANE_DIR084/.attempt-issue-99" "$LANE_DIR084/.defer-issue-99"
OUT084=$(_drive_snippet_defer_block "$STATE084")
assert_contains "TC-LGC6-084: fresh defer (same-run mtime, not superseded) -> DEFERRED" "DEFERRED" "$OUT084"

# TC-LGC6-085: superseded (a LATER dispatch attempt happened after this
# defer marker was written) -> falls through to DEAD, never shadows.
STATE085="$TMPROOT/state085"; LANE_DIR085="$STATE085/autonomous-testproj/lanes"
mkdir -p "$LANE_DIR085"
NOW085=$(date -u +%s)
touch -d "@$((NOW085 - 100))" "$LANE_DIR085/.defer-issue-99"
touch -d "@${NOW085}" "$LANE_DIR085/.attempt-issue-99"
OUT085=$(_drive_snippet_defer_block "$STATE085")
assert_eq "TC-LGC6-085: superseded defer (older than the latest attempt) falls through to DEAD, never shadows" "DEAD" "$OUT085"

# TC-LGC6-086: no attempt marker at all (pre-upgrade host) — falls back to
# the bounded age window; within it -> DEFERRED.
STATE086="$TMPROOT/state086"; LANE_DIR086="$STATE086/autonomous-testproj/lanes"
mkdir -p "$LANE_DIR086"
NOW086=$(date -u +%s)
touch -d "@$((NOW086 - 100))" "$LANE_DIR086/.defer-issue-99"
OUT086=$(_drive_snippet_defer_block "$STATE086")
assert_contains "TC-LGC6-086: no attempt marker, defer within the age ceiling -> DEFERRED (documented fallback)" "DEFERRED" "$OUT086"

# TC-LGC6-087: not superseded (no later attempt) but the defer is OLDER
# than the max-age ceiling -> DEAD. Proves the age ceiling is a genuine
# SECOND bound, not merely a fallback for a missing attempt marker — this
# is what eventually un-sticks an issue that would otherwise defer
# indefinitely once the box has been under pressure even once (nothing
# re-dispatches an already-active issue to refresh the attempt marker).
STATE087="$TMPROOT/state087"; LANE_DIR087="$STATE087/autonomous-testproj/lanes"
mkdir -p "$LANE_DIR087"
NOW087=$(date -u +%s)
touch -d "@$((NOW087 - 1000))" "$LANE_DIR087/.attempt-issue-99" "$LANE_DIR087/.defer-issue-99"
OUT087=$(_drive_snippet_defer_block "$STATE087")
assert_eq "TC-LGC6-087: not-superseded but past the age ceiling -> DEAD (age ceiling is a real second bound)" "DEAD" "$OUT087"

# ===========================================================================
echo ""
echo "=== TC-LGC6-090: _remote_pid_alive_query parses DEFERRED into 'DEFERRED:<age>' ==="
# ===========================================================================
FAKE_DRIVER090="$TMPROOT/fake-driver-090.sh"
cat > "$FAKE_DRIVER090" <<'EOF'
#!/bin/bash
printf 'DEFERRED\n45\n'
exit 0
EOF
chmod +x "$FAKE_DRIVER090"
OUT090=$(bash -c '
  export REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane PROJECT_ID=lgc6-090 MAX_RETRIES=3 MAX_CONCURRENT=5
  source "'"$LIB_DISPATCH"'"
  export _LIVENESS_CHECK_DRIVER_OVERRIDE="'"$FAKE_DRIVER090"'"
  _remote_pid_alive_query issue 99
')
assert_eq "TC-LGC6-090: _remote_pid_alive_query returns DEFERRED:45" "DEFERRED:45" "$OUT090"

# ===========================================================================
echo ""
echo "=== TC-LGC6-100: pid_alive side channel — DEFERRED verdict sets PID_ALIVE_LAST_VERDICT/_AGE, returns 1 ==="
# ===========================================================================
FAKE_DRIVER100="$TMPROOT/fake-driver-100.sh"
cat > "$FAKE_DRIVER100" <<'EOF'
#!/bin/bash
printf 'DEFERRED\n45\n'
exit 0
EOF
chmod +x "$FAKE_DRIVER100"
OUT100=$(bash -c '
  export REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane PROJECT_ID=lgc6-100 MAX_RETRIES=3 MAX_CONCURRENT=5
  source "'"$LIB_DISPATCH"'"
  set +e
  export _LIVENESS_CHECK_DRIVER_OVERRIDE="'"$FAKE_DRIVER100"'"
  EXECUTION_BACKEND=remote-aws-ssm pid_alive issue 99
  echo "RC=$?"
  echo "VERDICT=$PID_ALIVE_LAST_VERDICT"
  echo "AGE=$PID_ALIVE_LAST_DEFERRED_AGE"
')
assert_contains "TC-LGC6-100: pid_alive returns 1 (not-alive) for DEFERRED" "RC=1" "$OUT100"
assert_contains "TC-LGC6-100b: PID_ALIVE_LAST_VERDICT=DEFERRED" "VERDICT=DEFERRED" "$OUT100"
assert_contains "TC-LGC6-100c: PID_ALIVE_LAST_DEFERRED_AGE=45" "AGE=45" "$OUT100"

# Reset test: a SUBSEQUENT ALIVE call must clear the side channel (no stale
# DEFERRED leaking into an unrelated issue's probe this same tick).
FAKE_DRIVER101="$TMPROOT/fake-driver-101.sh"
cat > "$FAKE_DRIVER101" <<'EOF'
#!/bin/bash
echo ALIVE
exit 0
EOF
chmod +x "$FAKE_DRIVER101"
OUT101=$(bash -c '
  export REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane PROJECT_ID=lgc6-101 MAX_RETRIES=3 MAX_CONCURRENT=5
  source "'"$LIB_DISPATCH"'"
  set +e
  export _LIVENESS_CHECK_DRIVER_OVERRIDE="'"$FAKE_DRIVER100"'"
  EXECUTION_BACKEND=remote-aws-ssm pid_alive issue 99 >/dev/null
  export _LIVENESS_CHECK_DRIVER_OVERRIDE="'"$FAKE_DRIVER101"'"
  EXECUTION_BACKEND=remote-aws-ssm pid_alive issue 100 >/dev/null
  echo "VERDICT_AFTER_ALIVE=[$PID_ALIVE_LAST_VERDICT]"
')
assert_contains "TC-LGC6-101: side channel resets to empty on a subsequent (non-DEFERRED) probe" "VERDICT_AFTER_ALIVE=[]" "$OUT101"

# ===========================================================================
echo ""
echo "=== TC-LGC6-110: Step 5b DEFERRED fast-return — extracted loop body posts nothing, flips nothing ==="
# ===========================================================================
# Extract the Step 5 for-loop body (the DEAD/else branch specifically) and
# drive it in an isolated harness with every dependent function stubbed —
# mirrors the house pattern (test-lane-gc-p5-guardian.sh's do_reap
# extraction; test-dispatcher-step5b-dev-no-pr-heartbeat.sh's structural
# pin) but goes one step further: BEHAVIORALLY drives the extracted block.
STEP5_BODY=$(awk '/^for i in \$\(seq 0 \$\(\(cand_count - 1\)\)\); do$/{f=1} f{print} f && /^done$/{exit}' "$TICK")
# Positive extraction-control: assert on a KNOWN-present marker (the
# DEFERRED fast-return comment this PR adds, which must be INSIDE the
# extracted range) rather than merely "non-empty" — a future refactor that
# renames the loop's opening `for` line would otherwise make the awk range
# match some UNRELATED, still-non-empty span of the file and every
# downstream assertion would silently test the wrong code.
if [[ -n "$STEP5_BODY" ]] && grep -q 'Lane-GC PR-6 / INV-119\] DEFERRED fast-return' <<<"$STEP5_BODY"; then
  assert_pass "TC-LGC6-110 (extraction control): extracted the Step 5 loop body and it contains the expected DEFERRED fast-return marker"
else
  assert_fail "TC-LGC6-110 (extraction control): Step 5 loop body extraction is empty OR does not contain the DEFERRED fast-return marker — the awk range no longer matches dispatcher-tick.sh's structure; every assertion below this point is UNRELIABLE until fixed"
fi

HARNESS110="$TMPROOT/harness-110.sh"
{
  echo '#!/bin/bash'
  echo 'set -u'
  echo 'PASS_MARK=0'
  echo 'POSTED=0'
  echo 'LABEL_SWAPS=0'
  echo 'log() { :; }'
  echo 'was_just_dispatched() { return 1; }'
  echo 'is_within_grace_period() { return 1; }'
  echo 'itp_post_comment() { POSTED=$((POSTED + 1)); }'
  echo 'label_swap() { LABEL_SWAPS=$((LABEL_SWAPS + 1)); }'
  echo 'pid_alive() { PID_ALIVE_LAST_VERDICT="DEFERRED"; PID_ALIVE_LAST_DEFERRED_AGE="45"; return 1; }'
  echo 'get_pid() { echo ""; }'
  echo 'fetch_pr_for_issue() { echo ""; }'
  echo 'ci_is_green() { return 1; }'
  echo 'pr_idle_seconds() { echo ""; }'
  echo 'dev_near_success() { return 1; }'
  echo 'review_near_success() { return 1; }'
  echo 'recent_error_envelope() { echo ""; }'
  echo 'last_reviewed_head() { echo ""; }'
  echo '_local_defer_marker_verdict() { echo NONE; }'
  echo 'token_budget_recover_pending_intent() { return 0; }'
  echo 'token_budget_recent_launch_refusal() { return 1; }'
  echo 'token_budget_enabled() { return 1; }'
  echo 'token_budget_effective_mode() { echo disabled; }'
  echo 'token_budget_latest_dispatch_cutoff() { return 1; }'
  echo 'terminal_intent_cleanup_transition() { LABEL_SWAPS=$((LABEL_SWAPS + 1)); }'
  echo 'declare -F metrics_emit >/dev/null 2>&1 || metrics_emit() { :; }'
  echo 'candidates='"'"'[{"number":9999,"labels":["autonomous","in-progress"]}]'"'"''
  echo 'cand_count=1'
  echo "$STEP5_BODY"
  echo 'echo "POSTED=$POSTED"'
  echo 'echo "LABEL_SWAPS=$LABEL_SWAPS"'
} > "$HARNESS110"
OUT110=$(bash "$HARNESS110" 2>&1)
assert_contains "TC-LGC6-110b: Step 5b DEFERRED fast-return posts NO comment" "POSTED=0" "$OUT110"
assert_contains "TC-LGC6-110c: Step 5b DEFERRED fast-return flips NO label" "LABEL_SWAPS=0" "$OUT110"

# Counter-test: the SAME harness with pid_alive returning a plain DEAD
# (side channel empty) DOES post + flip — proves the fast-return is
# actually gated on the DEFERRED verdict, not merely dead code.
HARNESS111="$TMPROOT/harness-111.sh"
sed 's/PID_ALIVE_LAST_VERDICT="DEFERRED"; PID_ALIVE_LAST_DEFERRED_AGE="45";/PID_ALIVE_LAST_VERDICT=""; PID_ALIVE_LAST_DEFERRED_AGE="";/' "$HARNESS110" > "$HARNESS111"
OUT111=$(bash "$HARNESS111" 2>&1)
assert_contains "TC-LGC6-111: counter-test — a plain DEAD (non-DEFERRED) verdict DOES post the crash comment" "POSTED=1" "$OUT111"
assert_contains "TC-LGC6-111b: counter-test — a plain DEAD (non-DEFERRED) verdict DOES flip the label" "LABEL_SWAPS=1" "$OUT111"

# ===========================================================================
echo ""
echo "=== TC-LGC6-130: per-tick-call-site rc matrix (review P1-2) — rc=1 aborts (pre-P6 behavior), rc=75 defers, rc=0 confirms ==="
# ===========================================================================
# Each of the 4 dispatcher-tick.sh call sites (Step 2 dev-new, Step 3
# review, Step 4 PTL dev-new, Step 4 dev-resume) is extracted from its own
# `_dispatch_rc=0` line through its own `dispatch_marker_confirm_launched`
# call (inclusive) and driven inside a single-iteration `for` loop (so the
# extracted block's own `continue` statements are valid) with every
# dependent function stubbed. Three scenarios per site:
#   rc=1 (a genuine dispatch failure): pre-P6 this call site was a bare,
#     uncaptured `dispatch ...` under `set -euo pipefail` — any non-zero
#     return aborted the WHOLE TICK immediately. This PR's fix re-raises
#     via `exit "$_dispatch_rc"` to restore that exact abort — assert the
#     harness itself exits non-zero AND dispatch_marker_confirm_launched
#     was never reached.
#   rc=75 (the gate's defer sentinel): handle_dispatch_deferred fires,
#     confirm_launched is NOT reached, the harness exits 0 (via `continue`
#     falling out the bottom of the single-iteration loop).
#   rc=0 (success): confirm_launched IS reached, harness exits 0.
_extract_tick_site() {
  local start_line="$1"
  awk -v start="$start_line" '
    NR == start { f = 1 }
    f { print }
    f && /^[[:space:]]+dispatch_marker_confirm_launched / { exit }
  ' "$TICK"
}

_run_tick_site_harness() {
  local site_body="$1" dispatch_call="$2" rc="$3"
  local harness="$TMPROOT/tick-site-harness-$$-$RANDOM.sh"
  {
    echo '#!/bin/bash'
    echo 'set -euo pipefail'
    echo 'CONFIRM_CALLS=0'
    echo 'label_swap() { :; }'
    echo 'post_dispatch_token() { :; }'
    echo "log() { :; }"
    echo "dispatch() { return $rc; }"
    echo 'is_dispatch_deferred_rc() { [ "${1:-}" -eq 75 ] 2>/dev/null; }'
    echo 'handle_dispatch_deferred() { :; }'
    echo 'dispatch_marker_confirm_launched() { CONFIRM_CALLS=$((CONFIRM_CALLS + 1)); }'
    echo 'issue_num=9999'
    echo 'session_id="sid-9999"'
    echo 'for _tc130_i in 1; do'
    printf '%s\n' "$site_body"
    echo 'done'
    echo 'echo "CONFIRM_CALLS=$CONFIRM_CALLS"'
  } > "$harness"
  bash "$harness"
  local hrc=$?
  rm -f "$harness"
  return "$hrc"
}

mapfile -t _tick_site_lines < <(
  awk '/^[[:space:]]+_dispatch_rc=0$/ { print NR }' "$TICK"
)
if [[ "${#_tick_site_lines[@]}" -ne 4 ]]; then
  assert_fail "TC-LGC6-130 extraction setup: expected four _dispatch_rc=0 sites, found ${#_tick_site_lines[@]}"
fi
declare -A TICK_SITES=(
  ["step2-dev-new"]="${_tick_site_lines[0]:-0}"
  ["step3-review"]="${_tick_site_lines[1]:-0}"
  ["step4-ptl-dev-new"]="${_tick_site_lines[2]:-0}"
  ["step4-dev-resume"]="${_tick_site_lines[3]:-0}"
)
for site_label in step2-dev-new step3-review step4-ptl-dev-new step4-dev-resume; do
  start_line="${TICK_SITES[$site_label]}"
  SITE_BODY=$(_extract_tick_site "$start_line")
  if [[ -z "$SITE_BODY" ]] || ! grep -q 'dispatch_marker_confirm_launched' <<<"$SITE_BODY"; then
    assert_fail "TC-LGC6-130 ($site_label, extraction control): extraction from line $start_line is empty or missing the confirm-launched call — dispatcher-tick.sh structure drifted"
    continue
  fi
  assert_pass "TC-LGC6-130 ($site_label, extraction control): extracted a non-empty block containing dispatch_marker_confirm_launched"

  # rc=1: genuine failure — must abort (non-zero exit), confirm NOT reached.
  OUT_RC1=$(_run_tick_site_harness "$SITE_BODY" "" 1 2>&1); RC_RC1=$?
  if [[ "$RC_RC1" -ne 0 ]]; then
    assert_pass "TC-LGC6-130 ($site_label): rc=1 aborts the harness (pre-P6 abort-the-tick behavior restored)"
  else
    assert_fail "TC-LGC6-130 ($site_label): rc=1 did NOT abort the harness (exit=$RC_RC1) — non-75 failures must re-raise, not be swallowed"
  fi
  if grep -q 'CONFIRM_CALLS=0' <<<"$OUT_RC1" || ! grep -q 'CONFIRM_CALLS=' <<<"$OUT_RC1"; then
    assert_pass "TC-LGC6-130 ($site_label): rc=1 never reaches dispatch_marker_confirm_launched"
  else
    assert_fail "TC-LGC6-130 ($site_label): rc=1 unexpectedly reached dispatch_marker_confirm_launched: $OUT_RC1"
  fi

  # rc=75: defer — handle_dispatch_deferred fires via `continue`, confirm
  # NOT reached, harness exits 0 (falls out the bottom of the loop).
  OUT_RC75=$(_run_tick_site_harness "$SITE_BODY" "" 75 2>&1); RC_RC75=$?
  assert_eq "TC-LGC6-130 ($site_label): rc=75 harness exits 0 (defer path, no abort)" "0" "$RC_RC75"
  assert_contains "TC-LGC6-130 ($site_label): rc=75 never reaches dispatch_marker_confirm_launched" "CONFIRM_CALLS=0" "$OUT_RC75"

  # rc=0: success — confirm IS reached exactly once.
  OUT_RC0=$(_run_tick_site_harness "$SITE_BODY" "" 0 2>&1); RC_RC0=$?
  assert_eq "TC-LGC6-130 ($site_label): rc=0 harness exits 0" "0" "$RC_RC0"
  assert_contains "TC-LGC6-130 ($site_label): rc=0 reaches dispatch_marker_confirm_launched exactly once" "CONFIRM_CALLS=1" "$OUT_RC0"
done

# ===========================================================================
echo ""
echo "=== TC-LGC6-140/141/142: [#444, A2] gate-side label revert, per TYPE — stub gh records argv ==="
# ===========================================================================
# The gate runs as a SEPARATE bash process (dispatch-local.sh), so the only
# observable seam is the `gh` binary on PATH — matching the pattern this
# fixture already uses for adt-gc.sh. Asserts: exit is still 75, the
# recorded gh argv contains exactly one `issue edit <N> --remove-label
# <active> --add-label <target>` per the mapping, and the defer marker is
# still written. Must fail against pre-#444 dispatch-local.sh (zero gh
# invocations) and pass after.
_run_gate_revert_case() {
  local case_id="$1" type="$2" issue="$3"
  local proj="$TMPROOT/proj-revert-$case_id"
  _mk_fixture_project "$proj"
  local state="$TMPROOT/state-revert-$case_id"
  local bin="$TMPROOT/bin-revert-$case_id"
  local record="$TMPROOT/gh-argv-$case_id"
  mkdir -p "$bin"
  : > "$record"
  cat > "$bin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$record"
exit 0
EOF
  chmod +x "$bin/gh"
  PATH="$bin:$PATH" \
  ADT_STATE_ROOT="$state" \
  _GATE_LOAD1_PER_CORE_OVERRIDE="99" \
  bash -c "cd '$proj' && bash scripts/dispatch-local.sh '$type' '$issue'" 2>&1
  echo "__RC__:$?"
  echo "__RECORD__:$(cat "$record" 2>/dev/null)"
  echo "__MARKER__:$state/autonomous-gatetest/lanes/.defer-$([ "$type" = "review" ] && echo review || echo issue)-${issue}"
}

for spec in \
  "140:dev-new:9020:in-progress:pending-dev" \
  "141:dev-resume:9021:in-progress:pending-dev" \
  "142:review:9022:reviewing:pending-review" \
; do
  IFS=: read -r cid type issue from to <<<"$spec"
  RAW=$(_run_gate_revert_case "$cid" "$type" "$issue")
  RC=$(grep -o '__RC__:[0-9]*' <<<"$RAW" | cut -d: -f2)
  RECORD_LINE=$(grep '^__RECORD__:' <<<"$RAW" | sed 's/^__RECORD__://')
  MARKER_PATH=$(grep '^__MARKER__:' <<<"$RAW" | sed 's/^__MARKER__://')
  assert_eq "TC-LGC6-$cid ($type): exit still 75 after gate-side revert" "75" "$RC"
  EXPECTED_ARGV="issue edit ${issue} --repo test/test --remove-label ${from} --add-label ${to}"
  assert_eq "TC-LGC6-$cid ($type): exactly one gh invocation, correct remove/add pair" "$EXPECTED_ARGV" "$RECORD_LINE"
  if [[ -f "$MARKER_PATH" ]]; then
    assert_pass "TC-LGC6-$cid ($type): defer marker still written"
  else
    assert_fail "TC-LGC6-$cid ($type): defer marker NOT written at $MARKER_PATH"
  fi
done

# ===========================================================================
echo ""
echo "=== TC-LGC6-143: [#444, A2] fail-open — gh exits non-zero, gate still exits 75, marker written, WARN logged, no abort ==="
# ===========================================================================
PROJ143="$TMPROOT/proj-revert-143"
_mk_fixture_project "$PROJ143"
STATE143="$TMPROOT/state-revert-143"
BIN143="$TMPROOT/bin-revert-143"
mkdir -p "$BIN143"
cat > "$BIN143/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$BIN143/gh"
OUT143=$(
  PATH="$BIN143:$PATH" \
  ADT_STATE_ROOT="$STATE143" \
  _GATE_LOAD1_PER_CORE_OVERRIDE="99" \
  bash -c "cd '$PROJ143' && bash scripts/dispatch-local.sh dev-new 9023" 2>&1
)
RC143=$?
assert_eq "TC-LGC6-143: fail-open — exit still 75 when gh fails" "75" "$RC143"
assert_contains "TC-LGC6-143: one WARN naming the failed revert" "WARN: defer label-revert failed for issue 9023" "$OUT143"
if [[ -f "$STATE143/autonomous-gatetest/lanes/.defer-issue-9023" ]]; then
  assert_pass "TC-LGC6-143: defer marker still written despite the revert failure"
else
  assert_fail "TC-LGC6-143: defer marker NOT written"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC6-143b: [#444, A2] fail-open — REPO unset triggers an unbound-variable set -u abort INSIDE the revert, gate still exits 75 ==="
# ===========================================================================
# Regression for a real bug in an earlier draft of _gate_revert_label: a
# bare `itp_transition_state ... 2>/dev/null || true` does NOT survive
# itp_github_transition_state's `gh issue edit ... --repo "$REPO"`
# expanding an UNSET $REPO under this script's own `set -euo pipefail` —
# that trips a fatal unbound-variable exit that unwinds the WHOLE dispatch-
# local.sh process before the `|| true` ever gets a chance to catch it
# (`2>/dev/null || true` on a direct call only catches an ordinary nonzero
# RETURN, not `set -e` terminating the process). The fix wraps the revert
# body in a subshell `( ... ) 2>/dev/null` — a fatal exit inside the
# subshell only ends THAT subshell, and its exit status reaches the `if`
# as an ordinary nonzero return. This fixture deliberately OMITS REPO from
# autonomous.conf (unlike _mk_fixture_project's normal conf) to reproduce
# the exact unbound-variable trigger.
PROJ143B="$TMPROOT/proj-revert-143b"
mkdir -p "$PROJ143B/scripts"
cat > "$PROJ143B/scripts/autonomous-dev.sh" <<'STUB'
#!/bin/bash
sleep 5
STUB
chmod +x "$PROJ143B/scripts/autonomous-dev.sh"
cp "$PROJ143B/scripts/autonomous-dev.sh" "$PROJ143B/scripts/autonomous-review.sh"
cat > "$PROJ143B/scripts/autonomous.conf" <<CONF
PROJECT_ID="gatetest143b"
PROJECT_DIR="$PROJ143B"
AGENT_CMD="claude"
GH_AUTH_MODE="token"
CONF
for lf in dispatch-local.sh lib-config.sh lib-lane.sh; do
  ln -sf "$SCRIPTS/$lf" "$PROJ143B/scripts/$lf"
done
STATE143B="$TMPROOT/state-revert-143b"
BIN143B="$TMPROOT/bin-revert-143b"
mkdir -p "$BIN143B"
cat > "$BIN143B/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$BIN143B/gh"
# `env -u` strips REPO/REPO_OWNER/REPO_NAME explicitly — an EARLIER test
# block in this same file (TC-LGC6-050) `export`s REPO into this shared
# test-runner shell, which would otherwise leak into the child `bash -c`
# below and silently defeat the very scenario this test exists to
# reproduce (REPO genuinely absent from the fixture's own autonomous.conf).
OUT143B=$(
  env -u REPO -u REPO_OWNER -u REPO_NAME \
  PATH="$BIN143B:$PATH" \
  ADT_STATE_ROOT="$STATE143B" \
  _GATE_LOAD1_PER_CORE_OVERRIDE="99" \
  bash -c "cd '$PROJ143B' && bash scripts/dispatch-local.sh dev-new 9024" 2>&1
)
RC143B=$?
assert_eq "TC-LGC6-143b: unset REPO -> exit still 75 (not 1 from an unbound-variable abort)" "75" "$RC143B"
assert_contains "TC-LGC6-143b: one WARN naming the failed revert" "WARN: defer label-revert failed for issue 9024" "$OUT143B"
if [[ -f "$STATE143B/autonomous-gatetest143b/lanes/.defer-issue-9024" ]]; then
  assert_pass "TC-LGC6-143b: defer marker still written despite the unset-REPO abort inside the revert"
else
  assert_fail "TC-LGC6-143b: defer marker NOT written"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC6-144: [#444, A2+dispatcher] idempotence — a second revert via handle_dispatch_deferred also succeeds ==="
# ===========================================================================
# After the gate's own revert lands (in-progress -> pending-dev), a SEPARATE
# tick observing the same rc=75 synchronously (the local backend's normal
# path) calls handle_dispatch_deferred, which issues its OWN label_swap
# (pending-dev -> "" per its reverse-of-caller-swap contract in this test,
# matching TC-LGC6-050's existing convention) against the SAME stub gh —
# `gh issue edit --remove-label` of an absent label / `--add-label` of a
# present one are no-ops at the real API, so the stub (always exit 0) must
# not error and handle_dispatch_deferred's own contract (marker release +
# label revert, no comment, no retry) must hold unchanged.
export REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane PROJECT_ID=test-lgc6-144 MAX_RETRIES=3 MAX_CONCURRENT=5
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB_DISPATCH"
set +e
_RELEASE_CALLS_144=()
_LABEL_SWAP_CALLS_144=()
_POST_COMMENT_CALLS_144=0
_COUNT_RETRIES_CALLS_144=0
release_dispatch_marker() { _RELEASE_CALLS_144+=("$1:$2"); }
label_swap() { _LABEL_SWAP_CALLS_144+=("$1:$2:$3"); return 0; }
itp_post_comment() { _POST_COMMENT_CALLS_144=$((_POST_COMMENT_CALLS_144 + 1)); }
count_retries() { _COUNT_RETRIES_CALLS_144=$((_COUNT_RETRIES_CALLS_144 + 1)); echo 0; }
handle_dispatch_deferred 9020 "dev-new" "in-progress" ""
RC144=$?
assert_eq "TC-LGC6-144: handle_dispatch_deferred (the second, dispatcher-side revert) exits 0" "0" "$RC144"
assert_eq "TC-LGC6-144b: still releases the dispatch marker" "9020:dev-new" "${_RELEASE_CALLS_144[0]:-}"
assert_eq "TC-LGC6-144c: still issues its own label_swap unchanged (idempotent second revert)" "9020:in-progress:" "${_LABEL_SWAP_CALLS_144[0]:-}"
assert_eq "TC-LGC6-144d: never posts a comment" "0" "$_POST_COMMENT_CALLS_144"
assert_eq "TC-LGC6-144e: never decrements retry budget" "0" "$_COUNT_RETRIES_CALLS_144"

# ===========================================================================
echo ""
echo "=== TC-LGC6-150/151: [#444, B1 edit 1] local-backend expired vs fresh defer marker ==="
# ===========================================================================
# Drives _local_defer_marker_verdict directly (lib-dispatch.sh) against real
# fixture marker files with real mtimes — same style as TC-LGC6-083..087's
# real-snippet-comparison approach, but for the LOCAL-backend helper this
# issue adds (the remote snippet's comparison logic is untouched).
export REPO=zxkane/autonomous-dev-team REPO_OWNER=zxkane PROJECT_ID=lgc6-150 MAX_RETRIES=3 MAX_CONCURRENT=5
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB_DISPATCH"
set +e

STATE150="$TMPROOT/state150"; LANE_DIR150="$STATE150/autonomous-lgc6-150/lanes"
mkdir -p "$LANE_DIR150"
NOW150=$(date -u +%s)
touch -d "@${NOW150}" "$LANE_DIR150/.attempt-issue-150" "$LANE_DIR150/.defer-issue-150"
VERDICT150=$(ADT_STATE_ROOT="$STATE150" PROJECT_ID=lgc6-150 _local_defer_marker_verdict issue 150)
assert_eq "TC-LGC6-150: fresh local defer marker (age 0) -> FRESH" "FRESH" "$VERDICT150"

STATE151="$TMPROOT/state151"; LANE_DIR151="$STATE151/autonomous-lgc6-150/lanes"
mkdir -p "$LANE_DIR151"
NOW151=$(date -u +%s)
touch -d "@$((NOW151 - 1000))" "$LANE_DIR151/.attempt-issue-151" "$LANE_DIR151/.defer-issue-151"
VERDICT151=$(ADT_STATE_ROOT="$STATE151" PROJECT_ID=lgc6-150 _local_defer_marker_verdict issue 151)
assert_eq "TC-LGC6-151: not-superseded but past DEFER_MARKER_MAX_AGE_SECONDS (default 900) -> EXPIRED" "EXPIRED" "$VERDICT151"

STATE152="$TMPROOT/state152"; LANE_DIR152="$STATE152/autonomous-lgc6-150/lanes"
mkdir -p "$LANE_DIR152"
NOW152=$(date -u +%s)
touch -d "@$((NOW152 - 100))" "$LANE_DIR152/.defer-issue-152"
touch -d "@${NOW152}" "$LANE_DIR152/.attempt-issue-152"
VERDICT152=$(ADT_STATE_ROOT="$STATE152" PROJECT_ID=lgc6-150 _local_defer_marker_verdict issue 152)
assert_eq "TC-LGC6-152: superseded by a later attempt marker -> NONE (falls through to crash-declare)" "NONE" "$VERDICT152"

STATE153="$TMPROOT/state153"; LANE_DIR153="$STATE153/autonomous-lgc6-150/lanes"
mkdir -p "$LANE_DIR153"
VERDICT153=$(ADT_STATE_ROOT="$STATE153" PROJECT_ID=lgc6-150 _local_defer_marker_verdict issue 153)
assert_eq "TC-LGC6-153: no marker at all -> NONE" "NONE" "$VERDICT153"

# TC-LGC6-153b (CWE-59): a SYMLINKED defer marker must never be followed —
# same posture as kill_stale_wrapper's PID-file symlink refusal elsewhere in
# this codebase.
STATE153B="$TMPROOT/state153b"; LANE_DIR153B="$STATE153B/autonomous-lgc6-150/lanes"
mkdir -p "$LANE_DIR153B"
echo "not a real marker" > "$TMPROOT/symlink-target-153b"
ln -s "$TMPROOT/symlink-target-153b" "$LANE_DIR153B/.defer-issue-153"
VERDICT153B=$(ADT_STATE_ROOT="$STATE153B" PROJECT_ID=lgc6-150 _local_defer_marker_verdict issue 153)
assert_eq "TC-LGC6-153b: symlinked defer marker -> NONE (never followed, CWE-59)" "NONE" "$VERDICT153B"

# TC-LGC6-153c: a defer marker with a FUTURE mtime (clock skew) must never be
# misclassified as FRESH — a negative age fails the "age -ge 0" guard and
# falls to EXPIRED, never a crash and never a false fast-return.
STATE153C="$TMPROOT/state153c"; LANE_DIR153C="$STATE153C/autonomous-lgc6-150/lanes"
mkdir -p "$LANE_DIR153C"
NOW153C=$(date -u +%s)
touch -d "@$((NOW153C + 1000))" "$LANE_DIR153C/.defer-issue-153"
VERDICT153C=$(ADT_STATE_ROOT="$STATE153C" PROJECT_ID=lgc6-150 _local_defer_marker_verdict issue 153)
assert_eq "TC-LGC6-153c: future-mtime defer marker (clock skew) -> EXPIRED (never misclassified as FRESH)" "EXPIRED" "$VERDICT153C"

# TC-LGC6-153d/e: [review P1, #444] _revert_defer_strand's own return code —
# driven directly (not through the Step 5 loop harness) against a
# succeeding vs. a failing `label_swap`, proving the function itself
# propagates the outcome rather than swallowing it with a bare `|| true`.
label_swap() { return 0; }
_revert_defer_strand 9153 issue
assert_eq "TC-LGC6-153d: _revert_defer_strand returns 0 when label_swap succeeds" "0" "$?"

label_swap() { return 1; }
_revert_defer_strand 9153 issue >/dev/null 2>&1
assert_eq "TC-LGC6-153e: _revert_defer_strand returns non-zero when label_swap FAILS (the exact P1 regression: a prior draft always returned 0 here)" "1" "$?"

# End-to-end through dispatcher-tick.sh's Step 5 loop body — reuses the
# SAME $STEP5_BODY extraction TC-LGC6-110 already captured above (identical
# awk range, same file — no need for a second extraction) — EXPIRED reverts
# with no comment/retry, marker removed; FRESH fast-returns untouched.
if ! grep -q 'B1 edit 1' <<<"$STEP5_BODY"; then
  assert_fail "TC-LGC6-154 (extraction control): the shared Step 5 loop body extraction is missing the B1 edit 1 marker — dispatcher-tick.sh structure drifted"
else
  assert_pass "TC-LGC6-154 (extraction control): the shared Step 5 loop body extraction contains the B1 edit 1 marker"
fi

# _run_step5_loop_harness <env_setup_lines> <pid_alive_stub_line> — shared
# builder for both the local-backend (TC-LGC6-155/156/157) and remote-backend
# (TC-LGC6-160/161) Step 5 loop-body drives: identical collaborator-stub set
# and identical source-then-override ordering (source lib-dispatch.sh FIRST —
# that's where the B1 helpers the extracted body calls, e.g.
# _local_defer_marker_verdict/_revert_defer_strand, come from — THEN override
# collaborators, since override order must be AFTER the source or the real
# label_swap/itp_post_comment/count_retries/pid_alive definitions win instead
# of these stubs). Only the env setup (ADT_STATE_ROOT/EXECUTION_BACKEND for
# local vs. none for remote) and the pid_alive stub itself vary between the
# two call sites.
_run_step5_loop_harness() {
  local env_setup_lines="$1" pid_alive_stub_line="$2" label_swap_stub="${3:-}"
  local harness="$TMPROOT/harness-step5-$$-$RANDOM.sh"
  {
    echo '#!/bin/bash'
    echo 'set -u'
    printf '%s\n' "$env_setup_lines"
    # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
    echo "source '$LIB_DISPATCH'"
    echo 'POSTED=0'
    echo 'LABEL_SWAPS=0'
    echo 'RETRY_CALLS=0'
    echo 'log() { :; }'
    echo 'was_just_dispatched() { return 1; }'
    echo 'is_within_grace_period() { return 1; }'
    echo 'itp_post_comment() { POSTED=$((POSTED + 1)); }'
    # [review P1, #444] default stub always succeeds; a per-test override
    # (3rd arg) lets a caller simulate a FAILED revert (unreachable code
    # host) to prove _revert_defer_strand's failure propagates instead of
    # being swallowed.
    if [[ -n "$label_swap_stub" ]]; then
      printf '%s\n' "$label_swap_stub"
    else
      echo 'label_swap() { LABEL_SWAPS=$((LABEL_SWAPS + 1)); }'
    fi
    echo 'count_retries() { RETRY_CALLS=$((RETRY_CALLS + 1)); echo 0; }'
    printf '%s\n' "$pid_alive_stub_line"
    echo 'get_pid() { echo ""; }'
    echo 'fetch_pr_for_issue() { echo ""; }'
    echo 'ci_is_green() { return 1; }'
    echo 'pr_idle_seconds() { echo ""; }'
    echo 'dev_near_success() { return 1; }'
    echo 'review_near_success() { return 1; }'
    echo 'recent_error_envelope() { echo ""; }'
    echo 'last_reviewed_head() { echo ""; }'
    echo 'token_budget_recover_pending_intent() { return 0; }'
    echo 'terminal_intent_cleanup_transition() { LABEL_SWAPS=$((LABEL_SWAPS + 1)); }'
    echo 'declare -F metrics_emit >/dev/null 2>&1 || metrics_emit() { :; }'
    echo 'candidates='"'"'[{"number":9999,"labels":["autonomous","in-progress"]}]'"'"''
    echo 'cand_count=1'
    echo "$STEP5_BODY"
    echo 'echo "POSTED=$POSTED"'
    echo 'echo "LABEL_SWAPS=$LABEL_SWAPS"'
    echo 'echo "RETRY_CALLS=$RETRY_CALLS"'
  } > "$harness"
  bash "$harness" 2>&1
  rm -f "$harness"
}

_run_step5_b1_harness() {
  local state_root="$1" label_swap_stub="${2:-}"
  _run_step5_loop_harness \
    "ADT_STATE_ROOT='$state_root'
PROJECT_ID=lgc6-150
EXECUTION_BACKEND=local" \
    'pid_alive() { PID_ALIVE_LAST_VERDICT=""; PID_ALIVE_LAST_DEFERRED_AGE=""; return 1; }' \
    "$label_swap_stub"
}

# TC-LGC6-155: EXPIRED marker -> revert (LABEL_SWAPS=1), no comment, no
# retry decrement, marker removed.
STATE155="$TMPROOT/state155"; LANE_DIR155="$STATE155/autonomous-lgc6-150/lanes"
mkdir -p "$LANE_DIR155"
NOW155=$(date -u +%s)
touch -d "@$((NOW155 - 1000))" "$LANE_DIR155/.attempt-issue-9999" "$LANE_DIR155/.defer-issue-9999"
OUT155=$(_run_step5_b1_harness "$STATE155")
assert_contains "TC-LGC6-155: EXPIRED local defer -> reverts the label exactly once" "LABEL_SWAPS=1" "$OUT155"
assert_contains "TC-LGC6-155b: EXPIRED local defer -> posts NO comment" "POSTED=0" "$OUT155"
assert_contains "TC-LGC6-155c: EXPIRED local defer -> NO retry-budget decrement" "RETRY_CALLS=0" "$OUT155"
if [[ -f "$LANE_DIR155/.defer-issue-9999" ]]; then
  assert_fail "TC-LGC6-155d: stale marker should be removed after the EXPIRED revert"
else
  assert_pass "TC-LGC6-155d: stale marker removed after the EXPIRED revert"
fi

# TC-LGC6-156: FRESH marker -> fast-return (no label change, no comment).
STATE156="$TMPROOT/state156"; LANE_DIR156="$STATE156/autonomous-lgc6-150/lanes"
mkdir -p "$LANE_DIR156"
NOW156=$(date -u +%s)
touch -d "@${NOW156}" "$LANE_DIR156/.attempt-issue-9999" "$LANE_DIR156/.defer-issue-9999"
OUT156=$(_run_step5_b1_harness "$STATE156")
assert_contains "TC-LGC6-156: FRESH local defer -> NO label change" "LABEL_SWAPS=0" "$OUT156"
assert_contains "TC-LGC6-156b: FRESH local defer -> posts NO comment" "POSTED=0" "$OUT156"
if [[ -f "$LANE_DIR156/.defer-issue-9999" ]]; then
  assert_pass "TC-LGC6-156c: FRESH marker is left in place (not removed)"
else
  assert_fail "TC-LGC6-156c: FRESH marker should NOT be removed"
fi

# Counter-test: no marker at all -> falls through to the pre-existing no-PR
# crash-declare logic (proves 155/156 aren't gating on something vacuous).
STATE157="$TMPROOT/state157"
OUT157=$(_run_step5_b1_harness "$STATE157")
assert_contains "TC-LGC6-157: counter-test — no marker at all falls through to crash-declare (posts + flips)" "POSTED=1" "$OUT157"
assert_contains "TC-LGC6-157b: counter-test — no marker at all falls through to crash-declare (flips label)" "LABEL_SWAPS=1" "$OUT157"

# ===========================================================================
echo ""
echo "=== TC-LGC6-158/159: [#444, B1, review P1] EXPIRED local defer — FAILED revert must NOT consume the marker ==="
# ===========================================================================
# Regression for the review's blocking P1: a prior draft's _revert_defer_strand
# swallowed label_swap's failure (bare `|| true`), so this caller removed the
# defer marker unconditionally — even when the revert itself did not happen.
# Once the code host became reachable again, a LATER tick would then find NO
# marker at all and misclassify the still-stranded label as a genuine crash
# (false crash comment + retry burn), for what was always just a defer.
STATE158="$TMPROOT/state158"; LANE_DIR158="$STATE158/autonomous-lgc6-150/lanes"
mkdir -p "$LANE_DIR158"
NOW158=$(date -u +%s)
touch -d "@$((NOW158 - 1000))" "$LANE_DIR158/.attempt-issue-9999" "$LANE_DIR158/.defer-issue-9999"
OUT158=$(_run_step5_b1_harness "$STATE158" 'label_swap() { LABEL_SWAPS=$((LABEL_SWAPS + 1)); return 1; }')
assert_contains "TC-LGC6-158: EXPIRED local defer + FAILED revert -> attempts the revert (LABEL_SWAPS still incremented by the attempt)" "LABEL_SWAPS=1" "$OUT158"
assert_contains "TC-LGC6-158b: EXPIRED local defer + FAILED revert -> still posts NO crash comment" "POSTED=0" "$OUT158"
assert_contains "TC-LGC6-158c: EXPIRED local defer + FAILED revert -> still NO retry-budget decrement" "RETRY_CALLS=0" "$OUT158"
if [[ -f "$LANE_DIR158/.defer-issue-9999" ]]; then
  assert_pass "TC-LGC6-158d: marker is KEPT (not consumed) after a FAILED revert — a later tick can retry once the code host is reachable"
else
  assert_fail "TC-LGC6-158d: marker was removed despite the revert FAILING — this is the exact P1 regression (stranded label with no defer signal left)"
fi

# Counter-test proving 158 isn't vacuous: the SAME EXPIRED marker with a
# SUCCEEDING revert still removes the marker (TC-LGC6-155's own assertion,
# re-affirmed here alongside 158 for direct side-by-side contrast).
STATE159="$TMPROOT/state159"; LANE_DIR159="$STATE159/autonomous-lgc6-150/lanes"
mkdir -p "$LANE_DIR159"
NOW159=$(date -u +%s)
touch -d "@$((NOW159 - 1000))" "$LANE_DIR159/.attempt-issue-9999" "$LANE_DIR159/.defer-issue-9999"
OUT159=$(_run_step5_b1_harness "$STATE159")
if [[ -f "$LANE_DIR159/.defer-issue-9999" ]]; then
  assert_fail "TC-LGC6-159: counter-test — marker should be removed after a SUCCEEDING revert (proves 158 is gating on the revert outcome, not something else)"
else
  assert_pass "TC-LGC6-159: counter-test — marker removed after a SUCCEEDING revert (proves 158d is gating on the revert outcome)"
fi

# ===========================================================================
echo ""
echo "=== TC-LGC6-160/161: [#444, B1 edit 2] remote DEFERRED fast-return gains an age bound ==="
# ===========================================================================
# Same shared Step 5 loop-body harness as TC-LGC6-155/156/157, but this time
# pid_alive sets the REMOTE side channel (PID_ALIVE_LAST_VERDICT=DEFERRED)
# with an age at/above vs. below DEFER_MARKER_MAX_AGE_SECONDS.
_run_step5_b1_remote_harness() {
  local age="$1" label_swap_stub="${2:-}"
  _run_step5_loop_harness \
    "PROJECT_ID=lgc6-160" \
    "pid_alive() { PID_ALIVE_LAST_VERDICT=DEFERRED; PID_ALIVE_LAST_DEFERRED_AGE=$age; return 1; }" \
    "$label_swap_stub"
}

# TC-LGC6-160: age >= 900 (default threshold) -> revert-not-crash (label
# swap fires exactly once, no comment, no retry decrement).
OUT160=$(_run_step5_b1_remote_harness 900)
assert_contains "TC-LGC6-160: remote DEFERRED age>=threshold -> reverts the label exactly once" "LABEL_SWAPS=1" "$OUT160"
assert_contains "TC-LGC6-160b: remote DEFERRED age>=threshold -> posts NO comment" "POSTED=0" "$OUT160"
assert_contains "TC-LGC6-160c: remote DEFERRED age>=threshold -> NO retry-budget decrement" "RETRY_CALLS=0" "$OUT160"

# TC-LGC6-161: age < threshold -> today's fast-return (no label change, no comment).
OUT161=$(_run_step5_b1_remote_harness 45)
assert_contains "TC-LGC6-161: remote DEFERRED age<threshold -> NO label change (today's fast-return)" "LABEL_SWAPS=0" "$OUT161"
assert_contains "TC-LGC6-161b: remote DEFERRED age<threshold -> posts NO comment" "POSTED=0" "$OUT161"

# TC-LGC6-162: [#444, B1 edit 2, review P1] age >= threshold + FAILED revert —
# same failure-propagation regression as TC-LGC6-158, remote side. This path
# has no marker to (mis)consume (the remote side channel is transient, reset
# every `pid_alive` call, [INV-119]'s own point 3) — so the observable
# contract is narrower than the local side's TC-LGC6-158d: a failed revert
# must still never post a crash comment or decrement retry budget (the event
# is still a defer, not a crash); `_revert_defer_strand`'s own rc is now
# checked rather than swallowed (see the `if ! _revert_defer_strand` guard in
# dispatcher-tick.sh), which is what this test pins.
OUT162=$(_run_step5_b1_remote_harness 900 'label_swap() { LABEL_SWAPS=$((LABEL_SWAPS + 1)); return 1; }')
assert_contains "TC-LGC6-162: remote DEFERRED age>=threshold + FAILED revert -> attempts the revert" "LABEL_SWAPS=1" "$OUT162"
assert_contains "TC-LGC6-162b: remote DEFERRED age>=threshold + FAILED revert -> still posts NO crash comment" "POSTED=0" "$OUT162"
assert_contains "TC-LGC6-162c: remote DEFERRED age>=threshold + FAILED revert -> still NO retry-budget decrement" "RETRY_CALLS=0" "$OUT162"

# ===========================================================================
echo ""
echo "=== TC-LGC6-120: no forbidden phrases / private-repo references in touched files ==="
# ===========================================================================
TOUCHED_FILES=("$LIB_LANE" "$LIB_DISPATCH" "$DISPATCH_LOCAL" "$TICK" "$LIVENESS_DRIVER")
PRIVATE_HITS=$(grep -niE 'quant-scorer|vidsyllabus|issuecomment-[0-9]+' "${TOUCHED_FILES[@]}" 2>/dev/null || true)
if [[ -z "$PRIVATE_HITS" ]]; then
  assert_pass "TC-LGC6-120: no private-repo references in any touched file"
else
  assert_fail "TC-LGC6-120: found private-repo references: $PRIVATE_HITS"
fi
# Scoped to this PR's OWN new gate block only — dispatch-local.sh already
# carries a legitimate pre-existing "codex review round-N" citation
# (Lane-GC PR-3's kill_stale_wrapper walk) elsewhere in the file that a
# whole-file check would false-positive on.
CODEX_PHRASE_HITS=$(grep -ni 'codex review' <<<"$GATE_BLOCK" 2>/dev/null || true)
if [[ -z "$CODEX_PHRASE_HITS" ]]; then
  assert_pass "TC-LGC6-120b: no 'codex review' phrase in the new gate code block"
else
  assert_fail "TC-LGC6-120b: found 'codex review' phrase in the new gate code: $CODEX_PHRASE_HITS"
fi

# ===========================================================================
echo ""
echo "=== Results ==="
echo "PASS: $PASS  FAIL: $FAIL"
[[ "$FAIL" -eq 0 ]]
