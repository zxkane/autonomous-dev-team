#!/bin/bash
# test-lib-review-diffcap.sh — INV-124 / issue #452.
#
# Unit tests for the pure PR-diff-size (over-reach) decision surface in
# lib-review-diffcap.sh:
#   _diff_cap_normalize, review_diff_soft_cap_dimensions_needed,
#   review_diff_over_reach, review_diff_soft_cap_prompt_note.
#
# Run: bash tests/unit/test-lib-review-diffcap.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-diffcap.sh"

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

[[ -f "$LIB" ]] || { echo "ERROR: $LIB not found" >&2; exit 1; }

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-diffcap.sh
source "$LIB"

# ---------------------------------------------------------------------------
echo "=== TC-OVERREACH-001/002: _diff_cap_normalize ==="
# ---------------------------------------------------------------------------
assert_eq "unset → empty" "" "$(_diff_cap_normalize)"
assert_eq "empty string → empty" "" "$(_diff_cap_normalize "")"
assert_eq "0 → empty (disabled, not zero-cap)" "" "$(_diff_cap_normalize "0")"
assert_eq "negative → empty" "" "$(_diff_cap_normalize "-5")"
assert_eq "non-numeric → empty" "" "$(_diff_cap_normalize "abc")"
assert_eq "whitespace-only → empty" "" "$(_diff_cap_normalize "   ")"
assert_eq "valid positive int → echoed" "40" "$(_diff_cap_normalize "40")"
assert_eq "valid positive int with surrounding whitespace → trimmed" "40" "$(_diff_cap_normalize " 40 ")"
assert_eq "large valid int → echoed" "3000" "$(_diff_cap_normalize "3000")"
# rc is always 0 (disabled is not an error).
_diff_cap_normalize "bogus" >/dev/null
assert_eq "rc is always 0 (disabled is not an error)" "0" "$?"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-OVERREACH-001: review_diff_soft_cap_dimensions_needed ==="
# ---------------------------------------------------------------------------
assert_eq "both unset → empty (feature disabled)" "" "$(review_diff_soft_cap_dimensions_needed "" "")"
assert_eq "files only → 'files'" "files" "$(review_diff_soft_cap_dimensions_needed "40" "")"
assert_eq "lines only → 'lines'" "lines" "$(review_diff_soft_cap_dimensions_needed "" "3000")"
assert_eq "both set → 'files,lines'" "files,lines" "$(review_diff_soft_cap_dimensions_needed "40" "3000")"

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-OVERREACH-003/004/005/006/013: review_diff_over_reach ==="
# ---------------------------------------------------------------------------
# TC-OVERREACH-003: FILES exceeded (GitHub-shaped inputs).
assert_eq "files cap set+exceeded, lines unset → true" "true" \
  "$(review_diff_over_reach "45" "" "40" "")"
# TC-OVERREACH-004: LINES exceeded.
assert_eq "lines cap set+exceeded, files unset → true" "true" \
  "$(review_diff_over_reach "" "3500" "" "3000")"
# TC-OVERREACH-005: boundary — exactly at cap, NOT triggered (strict >).
assert_eq "files exactly at cap → false (strict >, not >=)" "false" \
  "$(review_diff_over_reach "40" "" "40" "")"
assert_eq "lines exactly at cap → false (strict >, not >=)" "false" \
  "$(review_diff_over_reach "" "3000" "" "3000")"
# TC-OVERREACH-006: unreadable stat never fabricates true.
assert_eq "files cap set but changed_files unreadable (empty) → false" "false" \
  "$(review_diff_over_reach "" "" "40" "")"
assert_eq "lines cap set but changed_lines unreadable (empty) → false" "false" \
  "$(review_diff_over_reach "" "" "" "3000")"
assert_eq "both caps set, both stats unreadable → false" "false" \
  "$(review_diff_over_reach "" "" "40" "3000")"
# TC-OVERREACH-013: full OR-logic matrix across dimensions.
assert_eq "neither exceeded → false" "false" \
  "$(review_diff_over_reach "10" "100" "40" "3000")"
assert_eq "files exceeded, lines not → true" "true" \
  "$(review_diff_over_reach "50" "100" "40" "3000")"
assert_eq "lines exceeded, files not → true" "true" \
  "$(review_diff_over_reach "10" "4000" "40" "3000")"
assert_eq "both exceeded → true" "true" \
  "$(review_diff_over_reach "50" "4000" "40" "3000")"
# Both caps unset → always false regardless of stats.
assert_eq "both caps unset → false regardless of stats" "false" \
  "$(review_diff_over_reach "9999" "9999" "" "")"

# Non-numeric changed_files/changed_lines (a malformed/corrupted provider-seam
# response) must degrade to "unreadable" — NOT crash the caller. Run under
# `set -euo pipefail` in a subshell to reproduce the wrapper's real shell
# options: pre-fix, `[[ "abc" -gt "40" ]]` throws "unbound variable" and the
# subshell aborts before ever reaching `echo rc=$?`.
NONNUM_OUT=$(bash -c "set -euo pipefail; source '$LIB'; review_diff_over_reach 'abc' '' '40' ''; echo; echo RC=\$?" 2>&1)
case "$NONNUM_OUT" in
  *"RC=0"*)
    case "$NONNUM_OUT" in
      false*) echo -e "  ${GREEN}PASS${NC}: non-numeric changed_files degrades to false under set -e (no crash)"; PASS=$((PASS+1));;
      *) echo -e "  ${RED}FAIL${NC}: non-numeric changed_files did not echo false"; echo "      got: $NONNUM_OUT"; FAIL=$((FAIL+1));;
    esac
    ;;
  *)
    echo -e "  ${RED}FAIL${NC}: non-numeric changed_files CRASHED the caller under set -e"; echo "      got: $NONNUM_OUT"; FAIL=$((FAIL+1));;
esac

NONNUM_LINES_OUT=$(bash -c "set -euo pipefail; source '$LIB'; review_diff_over_reach '' 'abc' '' '3000'; echo; echo RC=\$?" 2>&1)
case "$NONNUM_LINES_OUT" in
  *"RC=0"*)
    case "$NONNUM_LINES_OUT" in
      false*) echo -e "  ${GREEN}PASS${NC}: non-numeric changed_lines degrades to false under set -e (no crash)"; PASS=$((PASS+1));;
      *) echo -e "  ${RED}FAIL${NC}: non-numeric changed_lines did not echo false"; echo "      got: $NONNUM_LINES_OUT"; FAIL=$((FAIL+1));;
    esac
    ;;
  *)
    echo -e "  ${RED}FAIL${NC}: non-numeric changed_lines CRASHED the caller under set -e"; echo "      got: $NONNUM_LINES_OUT"; FAIL=$((FAIL+1));;
esac

# A decimal value (a plausible malformed-jq-output shape) must also degrade,
# not throw a bash arithmetic-syntax error.
DECIMAL_OUT=$(bash -c "set -euo pipefail; source '$LIB'; review_diff_over_reach '45.5' '' '40' ''; echo; echo RC=\$?" 2>&1)
case "$DECIMAL_OUT" in
  *"RC=0"*)
    case "$DECIMAL_OUT" in
      false*) echo -e "  ${GREEN}PASS${NC}: decimal changed_files degrades to false under set -e (no crash)"; PASS=$((PASS+1));;
      *) echo -e "  ${RED}FAIL${NC}: decimal changed_files did not echo false"; echo "      got: $DECIMAL_OUT"; FAIL=$((FAIL+1));;
    esac
    ;;
  *)
    echo -e "  ${RED}FAIL${NC}: decimal changed_files CRASHED the caller under set -e"; echo "      got: $DECIMAL_OUT"; FAIL=$((FAIL+1));;
esac

# review_diff_soft_cap_prompt_note must degrade the same way — a non-numeric
# stat must not crash the note renderer when over_reach happens to be "true"
# (e.g. because the OTHER dimension legitimately exceeded its cap).
NOTE_NONNUM_OUT=$(bash -c "set -euo pipefail; source '$LIB'; review_diff_soft_cap_prompt_note 'true' 'abc' '4000' '40' '3000' >/dev/null; echo RC=\$?" 2>&1)
case "$NOTE_NONNUM_OUT" in
  "RC=0") echo -e "  ${GREEN}PASS${NC}: review_diff_soft_cap_prompt_note does not crash on a non-numeric changed_files under set -e"; PASS=$((PASS+1));;
  *) echo -e "  ${RED}FAIL${NC}: review_diff_soft_cap_prompt_note CRASHED on a non-numeric changed_files"; echo "      got: $NOTE_NONNUM_OUT"; FAIL=$((FAIL+1));;
esac

# ---------------------------------------------------------------------------
echo ""
echo "=== review_diff_soft_cap_prompt_note ==="
# ---------------------------------------------------------------------------
# over_reach=false → empty output (both-unset / under-cap byte-identical case).
assert_eq "over_reach=false → empty note" "" \
  "$(review_diff_soft_cap_prompt_note "false" "10" "100" "40" "3000")"
assert_eq "over_reach empty (unset) → empty note" "" \
  "$(review_diff_soft_cap_prompt_note "" "" "" "" "")"

# over_reach=true, files exceeded → note names the files stat + cap.
NOTE_FILES=$(review_diff_soft_cap_prompt_note "true" "45" "" "40" "")
case "$NOTE_FILES" in
  *"Changed files: 45"*"cap: 40"*)
    echo -e "  ${GREEN}PASS${NC}: files-exceeded note names the files stat and cap"; PASS=$((PASS+1));;
  *)
    echo -e "  ${RED}FAIL${NC}: files-exceeded note missing files stat/cap"; echo "      got: $NOTE_FILES"; FAIL=$((FAIL+1));;
esac
case "$NOTE_FILES" in
  *"advisory"*"NOT a verdict"*|*"NOT a verdict"*"advisory"*)
    echo -e "  ${GREEN}PASS${NC}: note states explicitly it is advisory, not a verdict"; PASS=$((PASS+1));;
  *)
    echo -e "  ${RED}FAIL${NC}: note missing the advisory/not-a-verdict statement"; echo "      got: $NOTE_FILES"; FAIL=$((FAIL+1));;
esac

# over_reach=true, lines exceeded → note names the lines stat + cap.
NOTE_LINES=$(review_diff_soft_cap_prompt_note "true" "" "3500" "" "3000")
case "$NOTE_LINES" in
  *"Changed lines: 3500"*"cap: 3000"*)
    echo -e "  ${GREEN}PASS${NC}: lines-exceeded note names the lines stat and cap"; PASS=$((PASS+1));;
  *)
    echo -e "  ${RED}FAIL${NC}: lines-exceeded note missing lines stat/cap"; echo "      got: $NOTE_LINES"; FAIL=$((FAIL+1));;
esac

# Both exceeded → note names BOTH dimensions.
NOTE_BOTH=$(review_diff_soft_cap_prompt_note "true" "45" "3500" "40" "3000")
case "$NOTE_BOTH" in
  *"Changed files: 45"*)
    echo -e "  ${GREEN}PASS${NC}: both-exceeded note names files"; PASS=$((PASS+1));;
  *)
    echo -e "  ${RED}FAIL${NC}: both-exceeded note missing files"; FAIL=$((FAIL+1));;
esac
case "$NOTE_BOTH" in
  *"Changed lines: 3500"*)
    echo -e "  ${GREEN}PASS${NC}: both-exceeded note names lines"; PASS=$((PASS+1));;
  *)
    echo -e "  ${RED}FAIL${NC}: both-exceeded note missing lines"; FAIL=$((FAIL+1));;
esac

# over_reach=true but files NOT actually exceeded (only lines is; over_reach
# is a caller-supplied aggregate) → note must not claim files exceeded when
# the files stat doesn't support it.
NOTE_LINES_ONLY=$(review_diff_soft_cap_prompt_note "true" "10" "3500" "40" "3000")
case "$NOTE_LINES_ONLY" in
  *"Changed files:"*)
    echo -e "  ${RED}FAIL${NC}: note should not claim files exceeded when files stat is under cap"; FAIL=$((FAIL+1));;
  *)
    echo -e "  ${GREEN}PASS${NC}: note correctly omits files when only lines is exceeded"; PASS=$((PASS+1));;
esac

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
