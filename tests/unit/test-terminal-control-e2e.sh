#!/bin/bash
# Unit-suite entry point for the hermetic terminal-control E2E.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
E2E="$PROJECT_ROOT/tests/e2e/run-terminal-control-e2e.sh"

bash "$E2E"
rc=$?
if [[ "$rc" -eq 0 ]]; then
  exit 0
fi
echo "FAIL: terminal-control E2E exited $rc" >&2
exit "$rc"
