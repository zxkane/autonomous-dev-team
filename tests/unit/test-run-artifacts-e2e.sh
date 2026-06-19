#!/bin/bash
# test-run-artifacts-e2e.sh — issue #235 / INV-81 / TC-RUN-ARTIFACTS-080..085.
#
# Thin wrapper so the CI `tests/unit/test-*.sh` loop runs the run-artifacts +
# status.sh E2E (tests/e2e/run-run-artifacts-e2e.sh) end-to-end. The real work +
# assertions live in the E2E script; this invokes it, propagates its exit code,
# and asserts the success summary line (pass>0, fail=0).
#
# Run: bash tests/unit/test-run-artifacts-e2e.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
E2E="$PROJECT_ROOT/tests/e2e/run-run-artifacts-e2e.sh"

out="$(bash "$E2E" 2>&1)"; rc=$?
echo "$out"

if [[ $rc -ne 0 ]]; then
  echo "FAIL: E2E run-run-artifacts-e2e.sh exited $rc"
  exit 1
fi
if ! grep -qE 'RUN-ARTIFACTS-E2E-SUMMARY pass=[1-9][0-9]* fail=0' <<<"$out"; then
  echo "FAIL: expected RUN-ARTIFACTS-E2E-SUMMARY pass=<n> fail=0"
  exit 1
fi
echo "PASS: run-artifacts + status.sh E2E (TC-RUN-ARTIFACTS-080..085)"
