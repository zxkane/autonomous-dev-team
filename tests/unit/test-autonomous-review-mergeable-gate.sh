#!/bin/bash
# test-autonomous-review-mergeable-gate.sh — issue #176 / INV-44.
#
# Wrapper-enforced mergeable hard gate: a PR that is CONFLICTING (or whose
# mergeable status never settles out of UNKNOWN) can NEVER be aggregated to
# PASS / reach `approved`, regardless of whether the review agent ran its
# Step-0 pre-review rebase prompt step.
#
# Two pronged (the wrapper is too heavy to run end-to-end):
#
#   1. Pure decision-logic harness: source lib-review-mergeable.sh and drive
#      _classify_mergeable_gate over the full input space.
#   2. Source-of-truth greps against autonomous-review.sh: assert the gate is
#      wired in on the PASS path with the right routing, without executing the
#      wrapper.
#
# Run: bash tests/unit/test-autonomous-review-mergeable-gate.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-review.sh"
MG_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-mergeable.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

assert_grep() {
  local desc="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc (pattern: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
echo "=== TC-MG-CLS: pure decision logic (_classify_mergeable_gate) ==="
# ---------------------------------------------------------------------------
# _classify_mergeable_gate <mergeable> — echoes one of:
#   proceed | block-substantive | block-nonsubstantive
[[ -f "$MG_LIB" ]] || {
  echo -e "  ${RED}FAIL${NC}: $MG_LIB not found — implementation step required first"
  FAIL=$((FAIL + 1))
}

if [[ -f "$MG_LIB" ]]; then
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-mergeable.sh
  source "$MG_LIB"

  assert_eq "TC-MG-CLS-01 MERGEABLE → proceed" \
    "proceed"              "$(_classify_mergeable_gate MERGEABLE)"
  assert_eq "TC-MG-CLS-02 CONFLICTING → block-substantive" \
    "block-substantive"    "$(_classify_mergeable_gate CONFLICTING)"
  assert_eq "TC-MG-CLS-03 UNKNOWN → block-nonsubstantive" \
    "block-nonsubstantive" "$(_classify_mergeable_gate UNKNOWN)"
  assert_eq "TC-MG-CLS-04 empty → block-nonsubstantive (failed gh call)" \
    "block-nonsubstantive" "$(_classify_mergeable_gate '')"
  assert_eq "TC-MG-CLS-05 garbage → block-nonsubstantive (never proceed)" \
    "block-nonsubstantive" "$(_classify_mergeable_gate garbage)"
  assert_eq "TC-MG-CLS-06 mergeable (lowercase) → proceed" \
    "proceed"              "$(_classify_mergeable_gate mergeable)"
  assert_eq "TC-MG-CLS-07 conflicting (lowercase) → block-substantive" \
    "block-substantive"    "$(_classify_mergeable_gate conflicting)"

  # Key property: the ONLY input that proceeds is a case-insensitive MERGEABLE.
  _proceed_count=0
  for _in in MERGEABLE mergeable CONFLICTING conflicting UNKNOWN '' garbage CLEAN BEHIND; do
    [[ "$(_classify_mergeable_gate "$_in")" == "proceed" ]] && _proceed_count=$((_proceed_count + 1))
  done
  assert_eq "TC-MG-CLS-08 only MERGEABLE/mergeable proceed (stale-UNKNOWN pass-through closed)" \
    "2" "$_proceed_count"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-MG-SRC: wrapper structure (source-of-truth greps) ==="
# ---------------------------------------------------------------------------
assert_grep "TC-MG-SRC-01 wrapper sources lib-review-mergeable.sh" \
  'source "\$\{SCRIPT_DIR\}/lib-review-mergeable.sh"' "$WRAPPER"
assert_grep "TC-MG-SRC-02 gate queries gh pr view --json mergeable" \
  'gh pr view "\$PR_NUMBER" --repo "\$REPO" --json mergeable' "$WRAPPER"
assert_grep "TC-MG-SRC-03 gate calls _classify_mergeable_gate" \
  '_classify_mergeable_gate' "$WRAPPER"
# The gate must only run when the aggregate PASSed — a fail/all-unavailable
# already routes to pending-dev, so re-checking mergeable there is redundant.
assert_grep "TC-MG-SRC-04 gate guarded by PASSED_VERDICT == true" \
  '\[\[ "\$PASSED_VERDICT" == "true" \]\]' "$WRAPPER"
assert_grep "TC-MG-SRC-05 CONFLICTING path posts a [BLOCKING] Merge conflict finding" \
  '\[BLOCKING\] Merge conflict' "$WRAPPER"
# Reuse the dev-resume rebase hook: autonomous-dev.sh greps PR comments for a
# body starting "Auto-merge failed:" and prepends a rebase pre-step.
assert_grep "TC-MG-SRC-06 CONFLICTING path posts Auto-merge failed: marker on the PR" \
  'Auto-merge failed:' "$WRAPPER"
assert_grep "TC-MG-SRC-07 CONFLICTING path emits failed-substantive trailer" \
  'emit_verdict_trailer .*"failed-substantive"' "$WRAPPER"
assert_grep "TC-MG-SRC-08 UNKNOWN path emits failed-non-substantive mergeable-unknown" \
  'emit_verdict_trailer .*"failed-non-substantive" "mergeable-unknown"' "$WRAPPER"
assert_grep "TC-MG-SRC-09 block paths flip -reviewing +pending-dev" \
  'add-label "pending-dev"' "$WRAPPER"
assert_grep "TC-MG-SRC-10 UNKNOWN retry loop reads MERGEABLE_RETRIES" \
  'MERGEABLE_RETRIES' "$WRAPPER"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-MG-SRC-12: emit_verdict_trailer grew by exactly 2 (gate's two block paths) ==="
# ---------------------------------------------------------------------------
# Pre-gate the wrapper had 6 emit_verdict_trailer call sites (crash trap, no-pr,
# pass, auto-merge-fail, fail-substantive, fail-non-substantive). The INV-44 gate
# adds two (CONFLICTING substantive + UNKNOWN non-substantive); the INV-46 E2E
# gate (#182) adds two more (E2E-fail substantive + E2E-evidence-missing
# non-substantive) → 10. All sit OUTSIDE the per-agent collection loop.
EMIT_COUNT=$(grep -cE '^\s*emit_verdict_trailer ' "$WRAPPER")
assert_eq "TC-MG-SRC-12 emit_verdict_trailer call count is 10 (6 existing + 2 INV-44 gate + 2 INV-46 E2E gate)" \
  "10" "$EMIT_COUNT"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-MG-SRC-11: wrapper passes bash -n ==="
# ---------------------------------------------------------------------------
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: wrapper passes bash -n"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: wrapper has syntax errors"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
