#!/bin/bash
# Keep the token-budget E2E fixture on the hermetic-unit auto-discovery path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="$(bash "$PROJECT_ROOT/tests/e2e/run-token-budget-gates-e2e.sh")"
printf '%s\n' "$OUT"
grep -q 'TOKEN-BUDGET-E2E-SUMMARY pass=' <<<"$OUT"
grep -q 'fail=0' <<<"$OUT"
