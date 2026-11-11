#!/bin/bash
# TC-LGC4-053..060: the external watchdog bounds the regression harness itself.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec timeout --kill-after=2 60 python3 -B "$SCRIPT_DIR/test_cpu_burner_fixture.py"
