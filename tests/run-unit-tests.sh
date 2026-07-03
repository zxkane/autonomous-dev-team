#!/bin/bash
# tests/run-unit-tests.sh — parallel unit-suite runner (#373)
#
# Runs every tests/unit/test-*.sh under `bash` with bounded concurrency
# (xargs -P job pool), captures each test's stdout+stderr to its own log
# file, and replays the full log inline on FAIL so CI annotations and
# agents see the failure verbatim, uninterleaved (flock-serialized announce
# step — a worker's PASS/FAIL line + log replay is always printed as one
# atomic block, never spliced with a sibling worker's output).
#
# A small SERIAL_TESTS bucket (below) lists tests that must not run
# concurrently with anything; they run one at a time, after the parallel
# wave, with the same output protocol.
#
# Env overrides:
#   UNIT_TEST_DIR  — test directory (default: tests/unit). Lets this
#                    runner's own meta-test point it at a fixture dir.
#   UNIT_TEST_JOBS — worker count. Non-numeric/zero/negative/unset falls
#                    back to min(8, nproc/2, floor 1); nproc missing -> 4.
#
# Isolation contract for new tests: see tests/unit/README.md.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
UNIT_TEST_DIR="${UNIT_TEST_DIR:-$SCRIPT_DIR/unit}"

# ---------------------------------------------------------------------------
# SERIAL_TESTS — bare filenames (relative to UNIT_TEST_DIR) that must not run
# concurrently with anything else. Run after the parallel wave, one at a
# time. Each entry needs a one-line reason. A listed file that doesn't exist
# on disk is a runner FAIL (stale entry — keeps this list honest).
# ---------------------------------------------------------------------------
SERIAL_TESTS=(
  # (none yet — the #373 isolation audit found no hazard that couldn't be
  # fixed with a namespaced mktemp/PID-scoped path instead. Add an entry
  # here only if a future test genuinely cannot be made host-safe.)
)

# ---------------------------------------------------------------------------
# UNIT_TEST_JOBS validation. Default: min(8, nproc/2, floor 1). If the nproc
# command itself is unavailable, skip the halving and use 4 directly.
# ---------------------------------------------------------------------------
_default_jobs() {
  local n
  if ! n="$(nproc 2>/dev/null)" || ! [[ "$n" =~ ^[0-9]+$ ]] || [[ "$n" -le 0 ]]; then
    echo 4
    return
  fi
  local half=$((n / 2))
  [[ "$half" -lt 1 ]] && half=1
  [[ "$half" -lt 8 ]] && echo "$half" || echo 8
}

if ! [[ "${UNIT_TEST_JOBS:-}" =~ ^[0-9]+$ ]] || [[ "${UNIT_TEST_JOBS:-0}" =~ ^0+$ ]]; then
  JOBS="$(_default_jobs)"
else
  JOBS="$UNIT_TEST_JOBS"
fi

if [[ ! -d "$UNIT_TEST_DIR" ]]; then
  echo "UNIT-SUMMARY total=0 pass=0 fail=1 skipped=0 wall=0s"
  echo "::error::UNIT_TEST_DIR does not exist: $UNIT_TEST_DIR" >&2
  exit 1
fi

RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/run-unit-tests.XXXXXX")"
trap 'rm -rf "$RUN_DIR"' EXIT
: > "$RUN_DIR/.out.lock"

WALL_START=$(date +%s)

# ---------------------------------------------------------------------------
# Run one test file: capture output to its own log; build the human-facing
# announcement (a PASS/FAIL first line, then on FAIL the full log replay) in
# a per-test msg file, then print it under an flock so a worker's whole
# announcement block is never interleaved with a sibling's. The caller tallies
# pass/fail after the wave by reading each msg file's first word back.
# ---------------------------------------------------------------------------
_run_one() {
  local test_path="$1"
  local name
  name="$(basename "$test_path")"
  local log_file="$RUN_DIR/${name}.log"
  local msg_file="$RUN_DIR/${name}.msg"
  local start end elapsed rc

  if [[ ! -r "$test_path" ]]; then
    {
      echo "FAIL $name (0s)"
      echo "--- cannot read test file: $test_path ---"
    } > "$msg_file"
  else
    start=$(date +%s)
    if bash "$test_path" >"$log_file" 2>&1; then
      rc=0
    else
      rc=$?
    fi
    end=$(date +%s)
    elapsed=$((end - start))

    if [[ "$rc" -eq 0 ]]; then
      echo "PASS $name (${elapsed}s)" > "$msg_file"
    else
      {
        echo "FAIL $name (${elapsed}s)"
        cat "$log_file"
      } > "$msg_file"
    fi
  fi

  flock "$RUN_DIR/.out.lock" cat "$msg_file"
}
export -f _run_one
export RUN_DIR

# ---------------------------------------------------------------------------
# Partition: parallel wave = glob minus SERIAL_TESTS. A SERIAL_TESTS entry
# that doesn't exist on disk is a runner FAIL (stale entry).
# ---------------------------------------------------------------------------
declare -A _is_serial=()
for s in "${SERIAL_TESTS[@]:-}"; do
  [[ -n "$s" ]] || continue
  if [[ ! -f "$UNIT_TEST_DIR/$s" ]]; then
    echo "UNIT-SUMMARY total=0 pass=0 fail=1 skipped=0 wall=0s"
    echo "::error::SERIAL_TESTS entry does not exist on disk: $s" >&2
    exit 1
  fi
  _is_serial["$s"]=1
done

parallel_files=()
serial_files=()
for f in "$UNIT_TEST_DIR"/test-*.sh; do
  [[ -e "$f" ]] || continue
  base="$(basename "$f")"
  if [[ -n "${_is_serial[$base]:-}" ]]; then
    serial_files+=("$f")
  else
    parallel_files+=("$f")
  fi
done

if [[ "${#parallel_files[@]}" -gt 0 ]]; then
  printf '%s\n' "${parallel_files[@]}" | \
    xargs -P "$JOBS" -I{} bash -c '_run_one "$@"' _ {}
fi

# Serial bucket runs one at a time, strictly after the parallel wave — the
# xargs call above blocks until every parallel worker has exited.
for f in "${serial_files[@]}"; do
  _run_one "$f"
done

TOTAL=0
PASS_COUNT=0
FAIL_COUNT=0
for f in "${parallel_files[@]}" "${serial_files[@]}"; do
  name="$(basename "$f")"
  first_word="$(head -1 "$RUN_DIR/${name}.msg" 2>/dev/null | cut -d' ' -f1)"
  TOTAL=$((TOTAL + 1))
  if [[ "$first_word" == "PASS" ]]; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

WALL_END=$(date +%s)
WALL=$((WALL_END - WALL_START))

echo "UNIT-SUMMARY total=${TOTAL} pass=${PASS_COUNT} fail=${FAIL_COUNT} skipped=0 wall=${WALL}s"

[[ "$FAIL_COUNT" -eq 0 ]]
