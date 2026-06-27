#!/bin/bash
# test-autonomous-review-fail-branch-open-guard.sh — issue #196 / INV-54.
#
# The PR-still-open guard must be honored by ALL three PASS-chain exit paths:
#   - block-substantive   (PR CONFLICTING)
#   - block-nonsubstantive (mergeable UNKNOWN past retry budget)
#   - PASS                 (approve/merge)
#
# Before the fix, the open-check lived ONLY in the PASS branch (after the INV-44
# mergeable gate). A PR merged out-of-band that then reached a block branch had
# its already-closed issue flipped to `pending-dev`. The fix hoists a single
# open-check to the top of the `PASSED_VERDICT == true` gate chain.
#
# Two pronged (the wrapper is too heavy to run end-to-end):
#
#   1. Pure decision-logic harness: source lib-review-mergeable.sh and drive the
#      new _pr_open_gate helper over the full input space.
#   2. Source-of-truth greps against autonomous-review.sh: assert the guard is
#      hoisted ahead of the block branches and the redundant PASS-branch
#      duplicate was removed — without executing the wrapper.
#
# Run: bash tests/unit/test-autonomous-review-fail-branch-open-guard.sh

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

# ---------------------------------------------------------------------------
echo "=== TC-OG-CLS: pure decision logic (_pr_open_gate) ==="
# ---------------------------------------------------------------------------
# _pr_open_gate <state> — echoes one of: proceed | skip
[[ -f "$MG_LIB" ]] || {
  echo -e "  ${RED}FAIL${NC}: $MG_LIB not found"
  FAIL=$((FAIL + 1))
}

if [[ -f "$MG_LIB" ]]; then
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-mergeable.sh
  source "$MG_LIB"

  if ! declare -F _pr_open_gate >/dev/null; then
    echo -e "  ${RED}FAIL${NC}: _pr_open_gate is not defined in lib-review-mergeable.sh (implementation step required)"
    FAIL=$((FAIL + 1))
  else
    assert_eq "TC-OG-CLS-01 OPEN → proceed" \
      "proceed" "$(_pr_open_gate OPEN)"
    assert_eq "TC-OG-CLS-02 open (lowercase) → proceed" \
      "proceed" "$(_pr_open_gate open)"
    assert_eq "TC-OG-CLS-03 MERGED → skip" \
      "skip"    "$(_pr_open_gate MERGED)"
    assert_eq "TC-OG-CLS-04 CLOSED → skip" \
      "skip"    "$(_pr_open_gate CLOSED)"
    assert_eq "TC-OG-CLS-05 UNKNOWN (failed gh query sentinel) → skip" \
      "skip"    "$(_pr_open_gate UNKNOWN)"
    assert_eq "TC-OG-CLS-06 empty → skip" \
      "skip"    "$(_pr_open_gate '')"
    assert_eq "TC-OG-CLS-07 garbage → skip" \
      "skip"    "$(_pr_open_gate garbage)"

    # Key property: the ONLY input that proceeds is a case-insensitive OPEN —
    # the exact inverse of the PASS-branch guard's `!= OPEN` test.
    _proceed_count=0
    for _in in OPEN open MERGED CLOSED UNKNOWN '' garbage merged closed; do
      [[ "$(_pr_open_gate "$_in")" == "proceed" ]] && _proceed_count=$((_proceed_count + 1))
    done
    assert_eq "TC-OG-CLS-08 only OPEN/open proceed (every non-OPEN state skips)" \
      "2" "$_proceed_count"
  fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-OG-SRC: wrapper structure (source-of-truth greps) ==="
# ---------------------------------------------------------------------------
assert_src() {
  local desc="$1"; shift
  if "$@"; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    FAIL=$((FAIL + 1))
  fi
}

# TC-OG-SRC-01: wrapper calls _pr_open_gate.
assert_src "TC-OG-SRC-01 wrapper calls _pr_open_gate" \
  grep -qE '_pr_open_gate' "$WRAPPER"

# TC-OG-SRC-02: the open-check `gh pr view ... --json state` is HOISTED ahead of
# the `_classify_mergeable_gate` call (so it gates the block branches, not just
# PASS). Compare line numbers of the first state query vs the gate classifier.
_state_line=$(grep -nE 'chp_pr_view "\$PR_NUMBER" --json state' "$WRAPPER" | head -1 | cut -d: -f1)
_gate_line=$(grep -nE '_classify_mergeable_gate "\$MERGEABLE_STATUS"' "$WRAPPER" | head -1 | cut -d: -f1)
if [[ -n "$_state_line" && -n "$_gate_line" && "$_state_line" -lt "$_gate_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-OG-SRC-02 open-check (line $_state_line) precedes _classify_mergeable_gate (line $_gate_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-OG-SRC-02 open-check must precede the mergeable gate (state_line=${_state_line:-none}, gate_line=${_gate_line:-none})"
  FAIL=$((FAIL + 1))
fi

# TC-OG-SRC-03: the wrapper holds exactly TWO `chp_pr_view ... --json state`
# queries — the hoisted PASS-chain guard (this issue, #196) PLUS the E2E hard-gate
# guard added by the INV-54 extension (#195). Before #195 this count was 1; the
# extension legitimately adds a second, distinct query at the E2E gate. (The
# `gh pr view --json state` leaf moved behind chp_pr_view in #282.)
_state_count=$(grep -cE 'chp_pr_view "\$PR_NUMBER" --json state' "$WRAPPER")
assert_eq "TC-OG-SRC-03 exactly two --json state queries (PASS-chain hoisted + E2E gate, #195)" \
  "2" "$_state_count"
# TC-OG-SRC-03b: the PASS-chain guard stays DRY — exactly ONE query assigns the
# PASS-chain `PR_STATE=` (the redundant PASS-branch duplicate is still gone). The
# `\b` word boundary excludes the E2E gate's `E2E_PR_STATE=` (preceded by `_`,
# which is a word char → no boundary), so this counts only the PASS-chain query.
_passchain_state_count=$(grep -cE '\bPR_STATE=\$\(chp_pr_view "\$PR_NUMBER" --json state' "$WRAPPER")
assert_eq "TC-OG-SRC-03b PASS-chain guard stays DRY (exactly one PR_STATE= query)" \
  "1" "$_passchain_state_count"

# TC-OG-SRC-04: the hoisted open-gate skip path removes `reviewing` and does NOT
# add `pending-dev`. Extract the lines from the state query to its `exit 0` and
# assert: contains `--remove-label "reviewing"`, contains no `add-label
# "pending-dev"`.
_skip_block=$(awk '
  /chp_pr_view "\$PR_NUMBER" --json state/ { capture=1 }
  capture { print }
  capture && /exit 0/ { exit }
' "$WRAPPER")
if grep -qE 'remove-label "reviewing"' <<<"$_skip_block" \
   && ! grep -qE 'add-label "pending-dev"' <<<"$_skip_block"; then
  echo -e "  ${GREEN}PASS${NC}: TC-OG-SRC-04 open-gate skip path removes reviewing, never adds pending-dev"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-OG-SRC-04 open-gate skip path must remove reviewing and not add pending-dev"
  FAIL=$((FAIL + 1))
fi

# TC-OG-SRC-05: the open-gate runs INSIDE the PASSED_VERDICT == true chain and
# BEFORE the MERGEABLE_RETRIES poll loop (so block-substantive / block-
# nonsubstantive are both downstream of it).
_retries_line=$(grep -nE 'MERGEABLE_RETRIES="\$\{MERGEABLE_RETRIES:-3\}"' "$WRAPPER" | head -1 | cut -d: -f1)
if [[ -n "$_state_line" && -n "$_retries_line" && "$_state_line" -lt "$_retries_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-OG-SRC-05 open-check (line $_state_line) precedes the mergeable poll loop (line $_retries_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-OG-SRC-05 open-check must precede the mergeable poll loop (state_line=${_state_line:-none}, retries_line=${_retries_line:-none})"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-OG-SRC-06: wrapper passes bash -n ==="
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
