#!/bin/bash
# test-lane-gc-p5-guardian-e2e.sh — issue #381 / INV-118 / TC-LGC5-E2E-01.
#
# Thin wrapper so the CI `tests/unit/test-*.sh` loop runs the real-wrapper
# guardian E2E (tests/e2e/run-lane-gc-p5-guardian-e2e.sh) end-to-end. The
# real work + assertions live in the E2E script; this invokes it, propagates
# its exit code, and asserts the success summary line.
#
# Run: bash tests/unit/test-lane-gc-p5-guardian-e2e.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
E2E="$PROJECT_ROOT/tests/e2e/run-lane-gc-p5-guardian-e2e.sh"

out="$(bash "$E2E" 2>&1)"; rc=$?
echo "$out"

if [[ $rc -ne 0 ]]; then
  echo "FAIL: E2E run-lane-gc-p5-guardian-e2e.sh exited $rc"
  exit 1
fi
if ! grep -qE 'LANE-GC-P5-GUARDIAN-E2E-SUMMARY pass=[1-9][0-9]* fail=0' <<<"$out"; then
  echo "FAIL: expected LANE-GC-P5-GUARDIAN-E2E-SUMMARY pass=<n> fail=0"
  exit 1
fi
echo "PASS: lane-gc-p5 guardian E2E (TC-LGC5-E2E-01)"
