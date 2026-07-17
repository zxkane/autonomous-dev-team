#!/bin/bash
# test-resource-accounting-e2e.sh — issue #505 / INV-139.
#
# Thin wrapper so the CI `tests/unit/test-*.sh` loop runs the fixture-driven
# E2E (tests/e2e/run-resource-accounting-e2e.sh). The real work + assertions
# live in the E2E script; this just invokes it and pins the exit code +
# success summary line.
#
# Run: bash tests/unit/test-resource-accounting-e2e.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
E2E="$PROJECT_ROOT/tests/e2e/run-resource-accounting-e2e.sh"

out="$(bash "$E2E" 2>&1)"; rc=$?
echo "$out"

if [[ $rc -ne 0 ]]; then
  echo "FAIL: E2E run-resource-accounting-e2e.sh exited $rc"
  exit 1
fi
if ! grep -q 'RESOURCE-ACCOUNTING-E2E-SUMMARY pass=' <<<"$out"; then
  echo "FAIL: expected RESOURCE-ACCOUNTING-E2E-SUMMARY pass= line"
  exit 1
fi
echo "PASS: resource-accounting E2E (TC-RESOURCEACCOUNT-090/091)"
