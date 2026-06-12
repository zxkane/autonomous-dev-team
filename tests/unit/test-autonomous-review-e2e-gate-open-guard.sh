#!/bin/bash
# test-autonomous-review-e2e-gate-open-guard.sh — issue #195 / INV-54 extension.
#
# The INV-54 PR-still-open guard (#196) covers the three PASSED_VERDICT==true
# exits (mergeable block-substantive, mergeable block-nonsubstantive, PASS) via a
# single hoisted `_pr_open_gate` check. But the INV-46 E2E hard gate runs much
# EARLIER — before the review fan-out, before any verdict — and its two block
# branches:
#
#   - fail                  (lane .rc != 0 — substantive E2E failure)
#   - block-nonsubstantive  (lane clean but no SHA-matching evidence — transient)
#
# unconditionally `−reviewing +pending-dev` then `exit 0` with NO PR-state check.
# A PR merged out-of-band (concurrent review / manual merge / #191 self-merge)
# while the E2E lane runs then flips its already-closed issue to `pending-dev`.
#
# Fix: a single open-check at the TOP of the E2E gate's block routing — after
# `_classify_e2e_gate`, before the `fail`/`block-nonsubstantive` cascade —
# reusing the same `_pr_open_gate` helper. On not-open: remove `reviewing` only,
# exit 0, never `+pending-dev`.
#
# Two-pronged (the wrapper is too heavy to run end-to-end):
#   1. Pure decision-logic: re-pin `_pr_open_gate` over the merged-mid-E2E states.
#   2. Source-of-truth greps against autonomous-review.sh: assert the E2E-gate
#      open-check is wired in before both block branches, removes `reviewing`
#      without `pending-dev`, and leaves the OPEN path byte-for-byte unchanged.
#
# Run: bash tests/unit/test-autonomous-review-e2e-gate-open-guard.sh

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

# ---------------------------------------------------------------------------
echo "=== TC-EOG-CLS: pure decision logic (reused _pr_open_gate) ==="
# ---------------------------------------------------------------------------
[[ -f "$MG_LIB" ]] || {
  echo -e "  ${RED}FAIL${NC}: $MG_LIB not found"
  FAIL=$((FAIL + 1))
}

if [[ -f "$MG_LIB" ]]; then
  # shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-mergeable.sh
  source "$MG_LIB"
  if ! declare -F _pr_open_gate >/dev/null; then
    echo -e "  ${RED}FAIL${NC}: _pr_open_gate is not defined in lib-review-mergeable.sh"
    FAIL=$((FAIL + 1))
  else
    assert_eq "TC-EOG-CLS-01 OPEN → proceed"  "proceed" "$(_pr_open_gate OPEN)"
    assert_eq "TC-EOG-CLS-02 MERGED → skip"   "skip"    "$(_pr_open_gate MERGED)"
    assert_eq "TC-EOG-CLS-03 CLOSED → skip"   "skip"    "$(_pr_open_gate CLOSED)"
    assert_eq "TC-EOG-CLS-04 UNKNOWN → skip"  "skip"    "$(_pr_open_gate UNKNOWN)"
    assert_eq "TC-EOG-CLS-05 empty → skip"    "skip"    "$(_pr_open_gate '')"
  fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EOG-SRC: wrapper structure (source-of-truth greps) ==="
# ---------------------------------------------------------------------------

# Line numbers used throughout.
_e2e_state_line=$(grep -nE 'E2E_PR_STATE=\$\(gh pr view "\$PR_NUMBER" --repo "\$REPO" --json state' "$WRAPPER" | head -1 | cut -d: -f1)
_e2e_gate_cascade_line=$(grep -nE 'if \[\[ "\$E2E_GATE" == "fail" \]\]; then' "$WRAPPER" | head -1 | cut -d: -f1)
_classify_e2e_line=$(grep -nE 'E2E_GATE=\$\(_classify_e2e_gate' "$WRAPPER" | head -1 | cut -d: -f1)

# TC-EOG-SRC-01: the E2E gate queries PR state into E2E_PR_STATE and feeds
# _pr_open_gate.
assert_src "TC-EOG-SRC-01 E2E gate queries PR state (E2E_PR_STATE) and feeds _pr_open_gate" \
  bash -c 'grep -qE "E2E_PR_STATE=\\\$\(gh pr view .* --json state" "$1" && grep -qE "_pr_open_gate \"\\\$E2E_PR_STATE\"" "$1"' _ "$WRAPPER"

# TC-EOG-SRC-02: the E2E-gate open-check precedes the fail/block cascade.
if [[ -n "$_e2e_state_line" && -n "$_e2e_gate_cascade_line" && "$_e2e_state_line" -lt "$_e2e_gate_cascade_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-EOG-SRC-02 E2E open-check (line $_e2e_state_line) precedes the fail/block cascade (line $_e2e_gate_cascade_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EOG-SRC-02 E2E open-check must precede the cascade (state_line=${_e2e_state_line:-none}, cascade_line=${_e2e_gate_cascade_line:-none})"
  FAIL=$((FAIL + 1))
fi

# TC-EOG-SRC-03: the E2E-gate open-check is downstream of _classify_e2e_gate
# (acts on the classified gate, after the lane has run).
if [[ -n "$_classify_e2e_line" && -n "$_e2e_state_line" && "$_classify_e2e_line" -lt "$_e2e_state_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-EOG-SRC-03 E2E open-check (line $_e2e_state_line) is downstream of _classify_e2e_gate (line $_classify_e2e_line)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EOG-SRC-03 E2E open-check must follow _classify_e2e_gate (classify_line=${_classify_e2e_line:-none}, state_line=${_e2e_state_line:-none})"
  FAIL=$((FAIL + 1))
fi

# TC-EOG-SRC-04: the E2E-gate skip path removes `reviewing` and does NOT add
# `pending-dev`. Extract the block from the E2E_PR_STATE query down to its
# `exit 0` and assert the label semantics.
_e2e_skip_block=$(awk '
  /E2E_PR_STATE=\$\(gh pr view "\$PR_NUMBER" --repo "\$REPO" --json state/ { capture=1 }
  capture { print }
  capture && /exit 0/ { exit }
' "$WRAPPER")
if grep -qE 'remove-label "reviewing"' <<<"$_e2e_skip_block" \
   && ! grep -qE 'add-label "pending-dev"' <<<"$_e2e_skip_block"; then
  echo -e "  ${GREEN}PASS${NC}: TC-EOG-SRC-04 E2E open-gate skip path removes reviewing, never adds pending-dev"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EOG-SRC-04 E2E open-gate skip path must remove reviewing and not add pending-dev"
  FAIL=$((FAIL + 1))
fi

# TC-EOG-SRC-05: exactly TWO `gh pr view ... --json state` queries now exist —
# the INV-54 hoisted PASS-chain guard + this new E2E-gate guard. Catches both an
# accidentally-missing guard (count<2) and a stray duplicate (count>2).
_state_count=$(grep -cE 'gh pr view "\$PR_NUMBER" --repo "\$REPO" --json state' "$WRAPPER")
assert_eq "TC-EOG-SRC-05 exactly two --json state queries (INV-54 hoisted + E2E gate)" \
  "2" "$_state_count"

# TC-EOG-SRC-06: the E2E open-check guards the block exits ONLY — it is wedged
# between `_classify_e2e_gate` and the fail/block cascade, so the gate's
# `pass`/`inactive` outcomes (which fall through to the fan-out before the
# cascade is even reached) are unaffected. Pinning classify < state < cascade
# proves the guard cannot intercept the pass/inactive fall-through path.
if [[ -n "$_classify_e2e_line" && -n "$_e2e_state_line" && -n "$_e2e_gate_cascade_line" \
      && "$_classify_e2e_line" -lt "$_e2e_state_line" \
      && "$_e2e_state_line" -lt "$_e2e_gate_cascade_line" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-EOG-SRC-06 E2E open-check is wedged between _classify_e2e_gate ($_classify_e2e_line) and the cascade ($_e2e_gate_cascade_line) — guards block exits only"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EOG-SRC-06 E2E open-check must sit between classify ($_classify_e2e_line) and the cascade ($_e2e_gate_cascade_line); state=${_e2e_state_line:-none}"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EOG-REG: OPEN-path regression pins (byte-for-byte unchanged) ==="
# ---------------------------------------------------------------------------

# TC-EOG-REG-01: both E2E block branches still write −reviewing +pending-dev.
# Count the `--remove-label "reviewing" --add-label "pending-dev"` form that the
# E2E branches use (single-line form).
_e2e_pendingdev_count=$(grep -cE 'remove-label "reviewing" --add-label "pending-dev"' "$WRAPPER")
if [[ "$_e2e_pendingdev_count" -ge 2 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-EOG-REG-01 both E2E block branches still write −reviewing +pending-dev (count=$_e2e_pendingdev_count ≥ 2)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EOG-REG-01 expected ≥2 single-line −reviewing +pending-dev (E2E branches), got $_e2e_pendingdev_count"
  FAIL=$((FAIL + 1))
fi

# TC-EOG-REG-02: the E2E `fail` branch still requests changes + emits
# failed-substantive (INV-52 / INV-46 behavior preserved).
_e2e_fail_block=$(awk '
  /if \[\[ "\$E2E_GATE" == "fail" \]\]; then/ { capture=1 }
  capture { print }
  capture && /elif \[\[ "\$E2E_GATE" == "block-nonsubstantive" \]\]; then/ { exit }
' "$WRAPPER")
if grep -qE 'submit_request_changes' <<<"$_e2e_fail_block" \
   && grep -qE 'emit_verdict_trailer .* "failed-substantive"' <<<"$_e2e_fail_block"; then
  echo -e "  ${GREEN}PASS${NC}: TC-EOG-REG-02 E2E fail branch still requests changes + failed-substantive trailer"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EOG-REG-02 E2E fail branch must keep submit_request_changes + failed-substantive trailer"
  FAIL=$((FAIL + 1))
fi

# TC-EOG-REG-03: the E2E `block-nonsubstantive` branch still emits
# failed-non-substantive cause e2e-evidence-missing and does NOT request changes.
_e2e_block_block=$(awk '
  /elif \[\[ "\$E2E_GATE" == "block-nonsubstantive" \]\]; then/ { capture=1 }
  capture { print }
  capture && /gate == pass → fall through to Phase B/ { exit }
' "$WRAPPER")
if grep -qE 'emit_verdict_trailer .* "failed-non-substantive" "e2e-evidence-missing"' <<<"$_e2e_block_block" \
   && ! grep -qE 'submit_request_changes' <<<"$_e2e_block_block"; then
  echo -e "  ${GREEN}PASS${NC}: TC-EOG-REG-03 E2E block-nonsubstantive keeps e2e-evidence-missing trailer + no request-changes"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EOG-REG-03 E2E block-nonsubstantive branch behavior changed"
  FAIL=$((FAIL + 1))
fi

# TC-EOG-REG-04: emit_verdict_trailer call count (the open-guard adds no new
# trailer). INV-46 pinned this at 10; INV-64 (#224) added the one Phase-A.5
# smoke-FAIL abort site → 11. The open-guard itself must not change it.
_trailer_count=$(grep -cE 'emit_verdict_trailer ' "$WRAPPER")
assert_eq "TC-EOG-REG-04 emit_verdict_trailer call count is 11 (10 + INV-64 smoke abort; open-guard adds none)" \
  "11" "$_trailer_count"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-EOG-SRC-07: wrapper passes bash -n ==="
# ---------------------------------------------------------------------------
if bash -n "$WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: TC-EOG-SRC-07 wrapper passes bash -n"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-EOG-SRC-07 wrapper has syntax errors"
  FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
