#!/bin/bash
# Real containment is conditional on an existing user manager; never alter
# linger or pretend that unavailable kernel coverage passed.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
out=$(bash "$ROOT/tests/e2e/run-agent-wrapper-scope-e2e.sh")
rc=$?
printf '%s\n' "$out"
if [[ "$rc" == 77 ]]; then
  echo 'SKIP: real scope containment unavailable on this host'
  exit 0
fi
[[ "$rc" == 0 ]] && grep -q 'WRAPPER-SCOPE-E2E-SUMMARY pass=9 fail=0' <<< "$out"
