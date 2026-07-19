#!/bin/bash
# Keep issue #507's hermetic E2E on the unit auto-discovery path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="$(bash "$PROJECT_ROOT/tests/e2e/run-turn-limit-control-e2e.sh")"
printf '%s\n' "$OUT"
grep -q 'TURN-LIMIT-E2E-SUMMARY pass=' <<<"$OUT"
grep -q 'fail=0' <<<"$OUT"
