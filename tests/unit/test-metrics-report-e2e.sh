#!/bin/bash
# test-metrics-report-e2e.sh — issue #228 / INV-70 / TC-METRICS-080.
#
# Thin wrapper so the CI `tests/unit/test-*.sh` loop runs the fixture-driven
# three-month E2E (tests/e2e/run-metrics-report.sh) end-to-end. The real work +
# assertions live in the E2E script; this just invokes it and propagates its
# exit code (and asserts the success summary line is present).
#
# Run: bash tests/unit/test-metrics-report-e2e.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
E2E="$PROJECT_ROOT/tests/e2e/run-metrics-report.sh"

out="$(bash "$E2E" 2>&1)"; rc=$?
echo "$out"

if [[ $rc -ne 0 ]]; then
  echo "FAIL: E2E run-metrics-report.sh exited $rc"
  exit 1
fi
if ! grep -q 'METRICS-E2E-SUMMARY pass=10 fail=0' <<<"$out"; then
  echo "FAIL: expected METRICS-E2E-SUMMARY pass=10 fail=0"
  exit 1
fi
echo "PASS: metrics-report E2E (TC-METRICS-080)"
