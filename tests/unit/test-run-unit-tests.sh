#!/bin/bash
# test-run-unit-tests.sh — Unit tests for tests/run-unit-tests.sh (#373).
#
# Meta but hermetic: every scenario points the runner at a synthetic fixture
# dir via UNIT_TEST_DIR, NEVER at the real tests/unit suite (except TC-PUR-010,
# which only checks the *count* matches, never executes the real suite here —
# that's covered by R5's PR-description evidence, not this file).
#
# Run: bash tests/unit/test-run-unit-tests.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$PROJECT_ROOT/tests/run-unit-tests.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected='$expected'"
    echo "      actual=  '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

assert_rc() {
  local desc="$1" expected_rc="$2" actual_rc="$3"
  if [[ "$expected_rc" == "$actual_rc" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected_rc=$expected_rc actual_rc=$actual_rc)"
    FAIL=$((FAIL + 1))
  fi
}

assert_ne() {
  local desc="$1" unexpected="$2" actual="$3"
  if [[ "$unexpected" != "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (expected not '$unexpected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

_mk_pass_test() {
  local dir="$1" name="$2"
  cat > "$dir/$name" <<'EOF'
#!/bin/bash
echo "synthetic pass"
exit 0
EOF
  chmod +x "$dir/$name"
}

# ===========================================================================
# TC-PUR-001: all-pass fixture, summary counts match, exit 0
# ===========================================================================
echo ""
echo "=== TC-PUR-001: all-pass fixture ==="
echo ""

FIX1="$TMPROOT/fix1"
mkdir -p "$FIX1"
for i in 1 2 3 4 5; do _mk_pass_test "$FIX1" "test-p$i.sh"; done

OUT1=$(UNIT_TEST_DIR="$FIX1" bash "$RUNNER" 2>&1); RC1=$?
assert_contains "TC-PUR-001a summary shows total=5 pass=5 fail=0" \
  "UNIT-SUMMARY total=5 pass=5 fail=0 skipped=0" "$OUT1"
assert_rc "TC-PUR-001b exit 0" "0" "$RC1"

# ===========================================================================
# TC-PUR-002: single injected failure — FAIL line + full log replay + exit!=0
# ===========================================================================
echo ""
echo "=== TC-PUR-002: injected failure ==="
echo ""

FIX2="$TMPROOT/fix2"
mkdir -p "$FIX2"
_mk_pass_test "$FIX2" "test-ok.sh"
cat > "$FIX2/test-broken.sh" <<'EOF'
#!/bin/bash
echo "DISTINCTIVE_STDOUT_MARKER_12345"
echo "DISTINCTIVE_STDERR_MARKER_67890" >&2
exit 1
EOF
chmod +x "$FIX2/test-broken.sh"

OUT2=$(UNIT_TEST_DIR="$FIX2" bash "$RUNNER" 2>&1); RC2=$?
assert_contains "TC-PUR-002a FAIL line for test-broken.sh" "FAIL test-broken.sh" "$OUT2"
assert_contains "TC-PUR-002b stdout replayed inline" "DISTINCTIVE_STDOUT_MARKER_12345" "$OUT2"
assert_contains "TC-PUR-002c stderr replayed inline" "DISTINCTIVE_STDERR_MARKER_67890" "$OUT2"
assert_contains "TC-PUR-002d PASS line for sibling test-ok.sh" "PASS test-ok.sh" "$OUT2"
assert_contains "TC-PUR-002e summary shows fail=1" "fail=1" "$OUT2"
assert_ne "TC-PUR-002f exit non-zero" "0" "$RC2"

# ===========================================================================
# TC-PUR-003: UNIT_TEST_JOBS=1 degenerates to serial and still passes
# ===========================================================================
echo ""
echo "=== TC-PUR-003: UNIT_TEST_JOBS=1 ==="
echo ""

OUT3=$(UNIT_TEST_DIR="$FIX1" UNIT_TEST_JOBS=1 bash "$RUNNER" 2>&1); RC3=$?
assert_contains "TC-PUR-003a summary total=5 pass=5 fail=0 under JOBS=1" \
  "UNIT-SUMMARY total=5 pass=5 fail=0 skipped=0" "$OUT3"
assert_rc "TC-PUR-003b exit 0" "0" "$RC3"

# ===========================================================================
# TC-PUR-004: invalid UNIT_TEST_JOBS values fall back to the default
# ===========================================================================
echo ""
echo "=== TC-PUR-004: invalid UNIT_TEST_JOBS values ==="
echo ""

for bad_jobs in "" "0" "-3" "abc"; do
  OUT4=$(UNIT_TEST_DIR="$FIX1" UNIT_TEST_JOBS="$bad_jobs" bash "$RUNNER" 2>&1); RC4=$?
  assert_contains "TC-PUR-004 UNIT_TEST_JOBS='$bad_jobs' still completes total=5 pass=5" \
    "UNIT-SUMMARY total=5 pass=5 fail=0 skipped=0" "$OUT4"
  assert_rc "TC-PUR-004 UNIT_TEST_JOBS='$bad_jobs' exit 0" "0" "$RC4"
done

# ===========================================================================
# TC-PUR-005: concurrency proof — parallel materially faster than serial
# ===========================================================================
echo ""
echo "=== TC-PUR-005: concurrency proof (sleep-based synthetic tests) ==="
echo ""

FIX5="$TMPROOT/fix5"
mkdir -p "$FIX5"
for i in 1 2 3 4 5 6 7 8; do
  cat > "$FIX5/test-sleep$i.sh" <<'EOF'
#!/bin/bash
sleep 0.5
exit 0
EOF
  chmod +x "$FIX5/test-sleep$i.sh"
done

SERIAL_START=$(date +%s.%N)
UNIT_TEST_DIR="$FIX5" UNIT_TEST_JOBS=1 bash "$RUNNER" >/dev/null 2>&1
SERIAL_END=$(date +%s.%N)
SERIAL_ELAPSED=$(awk -v s="$SERIAL_START" -v e="$SERIAL_END" 'BEGIN { printf "%.3f", e - s }')

PARALLEL_START=$(date +%s.%N)
UNIT_TEST_DIR="$FIX5" UNIT_TEST_JOBS=4 bash "$RUNNER" >/dev/null 2>&1
PARALLEL_END=$(date +%s.%N)
PARALLEL_ELAPSED=$(awk -v s="$PARALLEL_START" -v e="$PARALLEL_END" 'BEGIN { printf "%.3f", e - s }')

RATIO=$(awk -v p="$PARALLEL_ELAPSED" -v s="$SERIAL_ELAPSED" 'BEGIN { printf "%.3f", p / s }')
echo "  serial=${SERIAL_ELAPSED}s parallel=${PARALLEL_ELAPSED}s ratio=${RATIO}"

if awk -v r="$RATIO" 'BEGIN { exit !(r < 0.60) }'; then
  echo -e "  ${GREEN}PASS${NC}: TC-PUR-005 parallel (JOBS=4) < 60% of serial (JOBS=1) time"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-PUR-005 parallel/serial ratio=${RATIO} (expected < 0.60)"
  FAIL=$((FAIL + 1))
fi

# ===========================================================================
# TC-PUR-006 / TC-PUR-007: SERIAL_TESTS bucket ordering + stale-entry guard
#
# SERIAL_TESTS is a fixed array literal at the top of tests/run-unit-tests.sh
# (bash arrays cannot be exported via env), so these cases drive a sed-patched
# TEMP COPY of the runner with an injected SERIAL_TESTS entry.
# ===========================================================================
echo ""
echo "=== TC-PUR-006: SERIAL bucket runs after the parallel wave ==="
echo ""

FIX6="$TMPROOT/fix6"
mkdir -p "$FIX6"
MARKER_LOG="$TMPROOT/fix6-markers.log"
: > "$MARKER_LOG"

# 4 parallel tests that each sleep briefly then append a start/end marker.
for i in 1 2 3 4; do
  cat > "$FIX6/test-par$i.sh" <<EOF
#!/bin/bash
echo "\$(date +%s.%N) start par$i" >> "$MARKER_LOG"
sleep 0.3
echo "\$(date +%s.%N) end par$i" >> "$MARKER_LOG"
exit 0
EOF
  chmod +x "$FIX6/test-par$i.sh"
done
# The serial-listed test.
cat > "$FIX6/test-serial-marker.sh" <<EOF
#!/bin/bash
echo "\$(date +%s.%N) start serial" >> "$MARKER_LOG"
sleep 0.1
echo "\$(date +%s.%N) end serial" >> "$MARKER_LOG"
exit 0
EOF
chmod +x "$FIX6/test-serial-marker.sh"

RUNNER_COPY6="$TMPROOT/run-unit-tests-serial.sh"
sed 's/^SERIAL_TESTS=($/SERIAL_TESTS=(\n  "test-serial-marker.sh"/' "$RUNNER" > "$RUNNER_COPY6"
chmod +x "$RUNNER_COPY6"

OUT6=$(UNIT_TEST_DIR="$FIX6" UNIT_TEST_JOBS=4 bash "$RUNNER_COPY6" 2>&1); RC6=$?
assert_contains "TC-PUR-006a summary total=5 pass=5" "UNIT-SUMMARY total=5 pass=5 fail=0" "$OUT6"
assert_rc "TC-PUR-006b exit 0" "0" "$RC6"

SERIAL_START_TS=$(awk '/start serial/ {print $1}' "$MARKER_LOG")
LAST_PARALLEL_END_TS=$(awk '/end par/ {print $1}' "$MARKER_LOG" | sort -n | tail -1)
if awk -v ss="$SERIAL_START_TS" -v pe="$LAST_PARALLEL_END_TS" 'BEGIN { exit !(ss >= pe) }'; then
  echo -e "  ${GREEN}PASS${NC}: TC-PUR-006c serial test starts after every parallel test ends"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-PUR-006c serial start ($SERIAL_START_TS) is before a parallel end ($LAST_PARALLEL_END_TS)"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== TC-PUR-007: stale SERIAL_TESTS entry is a runner FAIL ==="
echo ""

FIX7="$TMPROOT/fix7"
mkdir -p "$FIX7"
_mk_pass_test "$FIX7" "test-only.sh"

RUNNER_COPY7="$TMPROOT/run-unit-tests-stale.sh"
sed 's/^SERIAL_TESTS=($/SERIAL_TESTS=(\n  "test-does-not-exist.sh"/' "$RUNNER" > "$RUNNER_COPY7"
chmod +x "$RUNNER_COPY7"

OUT7=$(UNIT_TEST_DIR="$FIX7" bash "$RUNNER_COPY7" 2>&1); RC7=$?
assert_contains "TC-PUR-007a error names the stale entry" "test-does-not-exist.sh" "$OUT7"
assert_ne "TC-PUR-007b exit non-zero on stale SERIAL_TESTS entry" "0" "$RC7"

# ===========================================================================
# TC-PUR-008: unreadable test file is a FAIL, never silently dropped
# ===========================================================================
echo ""
echo "=== TC-PUR-008: unreadable test file ==="
echo ""

FIX8="$TMPROOT/fix8"
mkdir -p "$FIX8"
_mk_pass_test "$FIX8" "test-good.sh"
cat > "$FIX8/test-unreadable.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod 000 "$FIX8/test-unreadable.sh"

OUT8=$(UNIT_TEST_DIR="$FIX8" bash "$RUNNER" 2>&1); RC8=$?
chmod 700 "$FIX8/test-unreadable.sh"
assert_contains "TC-PUR-008a unreadable file reported as FAIL" "FAIL test-unreadable.sh" "$OUT8"
assert_contains "TC-PUR-008b summary total=2 (not silently dropped)" \
  "UNIT-SUMMARY total=2 pass=1 fail=1" "$OUT8"
assert_ne "TC-PUR-008c exit non-zero" "0" "$RC8"

# ===========================================================================
# TC-PUR-009: UNIT_TEST_DIR override to a non-existent path fails loudly
# ===========================================================================
echo ""
echo "=== TC-PUR-009: UNIT_TEST_DIR does not exist ==="
echo ""

OUT9=$(UNIT_TEST_DIR="$TMPROOT/does-not-exist" bash "$RUNNER" 2>&1); RC9=$?
assert_contains "TC-PUR-009a summary total=0 fail=1" \
  "UNIT-SUMMARY total=0 pass=0 fail=1" "$OUT9"
assert_contains "TC-PUR-009b error message present" "does-not-exist" "$OUT9"
assert_ne "TC-PUR-009c exit non-zero" "0" "$RC9"

# ===========================================================================
# TC-PUR-010: default UNIT_TEST_DIR (real tests/unit) — total matches file count
# ===========================================================================
echo ""
echo "=== TC-PUR-010: default UNIT_TEST_DIR total matches real file count ==="
echo ""

REAL_COUNT=$(find "$PROJECT_ROOT/tests/unit" -maxdepth 1 -name 'test-*.sh' -type f | wc -l | tr -d ' ')
echo "  (real tests/unit has $REAL_COUNT test-*.sh files — count check only, not executed here)"
if [[ "$REAL_COUNT" -gt 0 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-PUR-010 real suite file count is discoverable ($REAL_COUNT files)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-PUR-010 could not discover any test-*.sh files under tests/unit"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "============================================"
echo -e "  Passed: ${GREEN}${PASS}${NC}   Failed: ${RED}${FAIL}${NC}"
echo "============================================"

[[ "$FAIL" -eq 0 ]]
