#!/bin/bash
# test-cross-repo-dep-e2e-wrapper.sh — runs the #269 cross-repo dependency
# scoped-token E2E driver (tests/e2e/run-cross-repo-dep-e2e.sh) from inside the
# unit suite so CI exercises it WITHOUT a `.github/workflows/` change.
#
# Why a unit wrapper instead of a dedicated CI step: the autonomous dev wrapper's
# scoped GitHub App token lacks the `workflows` permission ([INV-79]), so a PR
# branch cannot add a CI step that edits ci.yml. The CI `Run all unit tests` job
# already iterates `tests/unit/test-*.sh`, so a thin wrapper here gets the E2E
# into the hermetic tier through the existing loop. Hermetic — no network/creds.
#
# Run: bash tests/unit/test-cross-repo-dep-e2e-wrapper.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
E2E="$PROJECT_ROOT/tests/e2e/run-cross-repo-dep-e2e.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
PASS=0; FAIL=0

[[ -f "$E2E" ]] || { echo -e "${RED}FATAL${NC}: $E2E missing"; exit 1; }

out=$(bash "$E2E" 2>&1)
rc=$?
echo "$out"

if [[ "$rc" -eq 0 ]] && printf '%s' "$out" | grep -q 'CROSS-REPO-DEP-E2E-SUMMARY pass=[1-9][0-9]* fail=0'; then
  echo -e "  ${GREEN}PASS${NC}: cross-repo-dep E2E driver green (SUMMARY pass>0 fail=0, rc 0)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: cross-repo-dep E2E driver failed (rc=$rc) or SUMMARY not all-pass"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
