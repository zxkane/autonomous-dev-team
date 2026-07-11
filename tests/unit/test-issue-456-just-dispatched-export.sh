#!/bin/bash
# test-issue-456-just-dispatched-export.sh — regression gate for #456.
#
# `dispatcher-tick.sh` populates `JUST_DISPATCHED` as a bash ARRAY across
# Steps 2-4, then at the top of Step 5 joins it into a scalar string and
# `export`s it under the SAME name so `was_just_dispatched()` in
# lib-dispatch.sh (which reads it in scalar context) can see it across the
# `dispatch()`/subshell boundary. Bash's `existing_array_name="scalar"`
# assigns ONLY index 0 of an existing array — it does not replace the whole
# array — so every original element at index >= 1 survives untouched.
# Since index 0 becomes the full space-joined string, `${JUST_DISPATCHED[*]}`
# then reprints the full string followed by every surviving higher index,
# producing N-1 duplicated trailing entries for an N-element array (e.g.
# `84 85` → `84 85 85`). This is what showed up in production as
# "Tick complete. Dispatched: 84 85 85" after only two issues were dispatched.
#
# Fix: `unset JUST_DISPATCHED` immediately before the scalar `export` so the
# array is fully replaced by the scalar rather than partially overwritten.
#
# This suite drives the REAL segment extracted from dispatcher-tick.sh (not a
# hand copy) so a future edit to the export lines is regression-tested
# against the file itself.
#
# Run: bash tests/unit/test-issue-456-just-dispatched-export.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TICK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/dispatcher-tick.sh"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1));
  else echo -e "  ${RED}FAIL${NC}: $desc"; echo "      expected: [$expected]"; echo "      actual:   [$actual]"; FAIL=$((FAIL + 1)); fi
}

[[ -f "$TICK" ]] || { echo "FATAL: dispatcher-tick.sh not found at $TICK"; exit 2; }
[[ -f "$LIB" ]] || { echo "FATAL: lib-dispatch.sh not found at $LIB"; exit 2; }

# Extract the export segment from the real source via anchor match — drifts
# with the file instead of a stale copy. Grabs every non-comment, non-blank
# line from the anchor comment through the closing `export JUST_DISPATCHED=`
# line (inclusive), so it tracks the fix (an `unset` line inserted between
# the join and the export) without needing to enumerate exact line shapes.
EXPORT_SEGMENT=$(awk '
  /^# Export JUST_DISPATCHED so was_just_dispatched\(\) in lib-dispatch.sh can read\.$/ { grab=1; next }
  grab && /^#/ { next }
  grab && /^$/ { next }
  grab { print }
  grab && /^export JUST_DISPATCHED=/ { exit }
' "$TICK")

if [ -z "$EXPORT_SEGMENT" ] || ! grep -q '^export JUST_DISPATCHED=' <<<"$EXPORT_SEGMENT"; then
  echo "FATAL: could not extract the JUST_DISPATCHED export segment (anchor missing? file drift?)"
  echo "  extracted: [$EXPORT_SEGMENT]"
  exit 2
fi

# Run the extracted segment for a given set of elements inside a fresh bash
# subprocess, populating JUST_DISPATCHED as the real Steps 2-4 do (array
# append), then print the post-export array form.
_run_export_segment() {
  local -a elems=("$@")
  local script="JUST_DISPATCHED=()
"
  local e
  for e in "${elems[@]}"; do
    script+="JUST_DISPATCHED+=(\"$e\")
"
  done
  script+="$EXPORT_SEGMENT
echo \"\${JUST_DISPATCHED[*]:-<none>}\"
"
  bash -c "$script"
}

# ===========================================================================
echo "=== TC-456-001: 2-element array — no duplication after export ([#456] repro) ==="
# ===========================================================================
out=$(_run_export_segment 84 85)
assert_eq "TC-456-001: 2-element post-export join == '84 85' (not '84 85 85')" "84 85" "$out"

# ===========================================================================
echo "=== TC-456-002: 3-element array — no duplication (confirms fix isn't N=2 special-cased) ==="
# ===========================================================================
out=$(_run_export_segment 10 20 30)
assert_eq "TC-456-002: 3-element post-export join == '10 20 30' (not '10 20 30 20 30')" "10 20 30" "$out"

# ===========================================================================
echo "=== TC-456-003: 4-element array — no duplication ==="
# ===========================================================================
out=$(_run_export_segment 1 2 3 4)
assert_eq "TC-456-003: 4-element post-export join == '1 2 3 4'" "1 2 3 4" "$out"

# ===========================================================================
echo "=== TC-456-004: empty array — export segment still produces '<none>' via the caller's :- fallback ==="
# ===========================================================================
out=$(_run_export_segment)
assert_eq "TC-456-004: empty array post-export join == '<none>'" "<none>" "$out"

# ===========================================================================
echo "=== TC-456-005: was_just_dispatched() scalar read still works after the fixed export ([INV-09] unaffected) ==="
# ===========================================================================
# The functional skip-logic (Step 5's dispatch-skip protection) reads
# $JUST_DISPATCHED in scalar context via was_just_dispatched(). That must
# keep working exactly as before — this drives the REAL post-export value
# through the REAL helper, not a hand-built scalar.
out=$(bash -c "
export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-456
export MAX_RETRIES=3
export MAX_CONCURRENT=5
source '$LIB' >/dev/null 2>&1
JUST_DISPATCHED=()
JUST_DISPATCHED+=(\"84\")
JUST_DISPATCHED+=(\"85\")
$EXPORT_SEGMENT
if was_just_dispatched 84 && was_just_dispatched 85 && ! was_just_dispatched 86; then
  echo OK
else
  echo BAD
fi
")
assert_eq "TC-456-005: was_just_dispatched() correctly resolves 84,85 as IN and 86 as NOT_IN post-fix" "OK" "$out"

# ===========================================================================
echo ""
echo "==============================================="
echo -e "Total: $((PASS + FAIL)) tests, ${GREEN}${PASS} pass${NC}, ${RED}${FAIL} fail${NC}"
echo "==============================================="

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
