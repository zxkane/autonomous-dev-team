#!/bin/bash
# test-w1a-state-read-parity.sh — issue #371 (W1a, #347 phase-2), R5.
#
# DECISION-level (not byte-level) behavior-parity suite for the six
# lib-dispatch.sh callers of the ABSTRACT itp_list_by_state / itp_count_by_state
# / itp_list_forbidden_combos contract:
#
#   count_active, list_new_issues, list_pending_review, list_pending_dev,
#   list_stale_candidates, list_hygiene_residue
#
# #371 converts these three ITP verbs from a byte-identical gh-argv passthrough
# to an abstract, provider-neutral contract — a DELIBERATE shape change (the
# normalized `labels` field is now an array of NAME strings, not `{name}`
# objects), so verbatim output equality with the pre-#371 code is impossible
# by construction. Instead this suite proves DECISION-level parity: for each
# caller, the CURRENT (post-#371) code selects the exact same issue-number SET
# (order-insensitive) / count that the OLD (pre-#371, byte-identical-passthrough)
# code selected, against four fixture classes (R5):
#
#   normal    — one issue matching the caller's selector.
#   empty     — zero issues.
#   overlimit — 120 issues (exercises the caller's own jq logic over a large
#               set; the leaf's server-side --limit application is a separate,
#               leaf-level concern covered by test-w1a-state-read-contracts.sh).
#   residue   — a terminal-label ([INV-25] approved/stalled) residue issue
#               alongside a clean one.
#
# GOLDEN FIXTURE PROVENANCE (R5): tests/unit/fixtures/w1a-parity/decision-golden.json
# was captured ONCE by running the PRE-#371 callers (byte-identical passthrough)
# against these same fixtures, on the first TDD commit of the #371 branch,
# before the abstract-contract rewrite landed. See the sidecar
# decision-golden.json.meta for the exact capture procedure. This test compares
# the CURRENT code's output against that committed golden — it does NOT
# recompute the OLD behavior, so a regression in either the leaf OR the six
# callers shows up as a mismatch against the frozen golden.
#
# Run: bash tests/unit/test-w1a-state-read-parity.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"
GOLDEN="$SCRIPT_DIR/fixtures/w1a-parity/decision-golden.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

[[ -f "$GOLDEN" ]] || { echo "FATAL: golden fixture not found at $GOLDEN"; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-w1a-parity-$$
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# Fixture builders — mirror the exact shapes the golden fixture was captured
# against (RAW gh `issue list` object shape: labels as `{name}` objects).
mklabels() {
  local out="[" first=1
  for n in "$@"; do
    if [[ $first -eq 1 ]]; then first=0; else out+=","; fi
    out+="{\"name\":\"$n\"}"
  done
  out+="]"
  printf '%s' "$out"
}
mkissue() {
  local num="$1"; shift
  printf '{"number":%s,"title":"issue-%s","labels":%s,"comments":[]}' "$num" "$num" "$(mklabels "$@")"
}

# Stub `gh` — the leaf (itp_github_list_by_state et al.) issues ONE `gh issue
# list ... --json ...` call with NO `-q`; this stub ignores the requested
# --state/--label/--limit filters (the fixture is pre-filtered by the test)
# and echoes the canned array verbatim, letting the REAL leaf's own jq
# normalization + sort run on it.
_MOCK_ISSUE_LIST=""
gh() { printf '%s' "${_MOCK_ISSUE_LIST:-[]}"; }
export -f gh

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

assert_numbers_eq() {
  local desc="$1" golden_key="$2" actual_json="$3"
  local expected actual
  expected="$(jq -c --arg k "$golden_key" '.[$k]' "$GOLDEN")"
  actual="$(jq -c '[.[].number] | sort' <<<"$actual_json" 2>/dev/null)"
  if [[ "$expected" == "$actual" ]]; then
    ok "$desc (numbers=$actual)"
  else
    bad "$desc — expected $expected, got $actual"
  fi
}

assert_int_eq() {
  local desc="$1" golden_key="$2" actual="$3"
  local expected
  expected="$(jq -r --arg k "$golden_key" '.[$k]' "$GOLDEN")"
  if [[ "$expected" == "$actual" ]]; then
    ok "$desc (count=$actual)"
  else
    bad "$desc — expected $expected, got $actual"
  fi
}

big_fixture() {
  local out="[" first=1 i
  for i in $(seq 1 120); do
    if [[ $first -eq 1 ]]; then first=0; else out+=","; fi
    out+="$(mkissue "$i" autonomous)"
  done
  out+="]"
  printf '%s' "$out"
}

# ===========================================================================
echo "=== TC-W1A-PARITY: fixture class 1 (normal) ==="
# ===========================================================================
_MOCK_ISSUE_LIST="[$(mkissue 1 autonomous)]"
assert_numbers_eq "TC-W1A-PARITY-001 list_new_issues.normal" "list_new_issues.normal" "$(list_new_issues)"

_MOCK_ISSUE_LIST="[$(mkissue 2 autonomous pending-review)]"
assert_numbers_eq "TC-W1A-PARITY-002 list_pending_review.normal" "list_pending_review.normal" "$(list_pending_review)"

_MOCK_ISSUE_LIST="[$(mkissue 3 autonomous pending-dev)]"
assert_numbers_eq "TC-W1A-PARITY-003 list_pending_dev.normal" "list_pending_dev.normal" "$(list_pending_dev)"

_MOCK_ISSUE_LIST="[$(mkissue 4 autonomous in-progress),$(mkissue 5 autonomous reviewing)]"
assert_numbers_eq "TC-W1A-PARITY-004 list_stale_candidates.normal" "list_stale_candidates.normal" "$(list_stale_candidates)"

_MOCK_ISSUE_LIST="[$(mkissue 6 autonomous approved in-progress)]"
assert_numbers_eq "TC-W1A-PARITY-005 list_hygiene_residue.normal" "list_hygiene_residue.normal" "$(list_hygiene_residue)"

_MOCK_ISSUE_LIST="[$(mkissue 7 autonomous in-progress),$(mkissue 8 autonomous reviewing)]"
assert_int_eq "TC-W1A-PARITY-006 count_active.normal" "count_active.normal" "$(count_active)"

# ===========================================================================
echo ""
echo "=== TC-W1A-PARITY: fixture class 2 (empty) ==="
# ===========================================================================
_MOCK_ISSUE_LIST="[]"
assert_numbers_eq "TC-W1A-PARITY-010 list_new_issues.empty" "list_new_issues.empty" "$(list_new_issues)"
assert_numbers_eq "TC-W1A-PARITY-011 list_pending_review.empty" "list_pending_review.empty" "$(list_pending_review)"
assert_numbers_eq "TC-W1A-PARITY-012 list_pending_dev.empty" "list_pending_dev.empty" "$(list_pending_dev)"
assert_numbers_eq "TC-W1A-PARITY-013 list_stale_candidates.empty" "list_stale_candidates.empty" "$(list_stale_candidates)"
assert_numbers_eq "TC-W1A-PARITY-014 list_hygiene_residue.empty" "list_hygiene_residue.empty" "$(list_hygiene_residue)"
assert_int_eq "TC-W1A-PARITY-015 count_active.empty" "count_active.empty" "$(count_active)"

# ===========================================================================
echo ""
echo "=== TC-W1A-PARITY: fixture class 3 (>limit, 120 issues) ==="
# ===========================================================================
_MOCK_ISSUE_LIST="$(big_fixture)"
assert_numbers_eq "TC-W1A-PARITY-020 list_new_issues.overlimit" "list_new_issues.overlimit" "$(list_new_issues)"
assert_int_eq "TC-W1A-PARITY-021 count_active.overlimit" "count_active.overlimit" "$(count_active)"

# ===========================================================================
echo ""
echo "=== TC-W1A-PARITY: fixture class 4 (terminal-label residue present) ==="
# ===========================================================================
_MOCK_ISSUE_LIST="[$(mkissue 10 autonomous pending-review approved),$(mkissue 11 autonomous pending-review)]"
assert_numbers_eq "TC-W1A-PARITY-030 list_pending_review.residue" "list_pending_review.residue" "$(list_pending_review)"

_MOCK_ISSUE_LIST="[$(mkissue 12 autonomous pending-dev stalled),$(mkissue 13 autonomous pending-dev)]"
assert_numbers_eq "TC-W1A-PARITY-031 list_pending_dev.residue" "list_pending_dev.residue" "$(list_pending_dev)"

_MOCK_ISSUE_LIST="[$(mkissue 14 autonomous in-progress approved),$(mkissue 15 autonomous in-progress)]"
assert_numbers_eq "TC-W1A-PARITY-032 list_stale_candidates.residue" "list_stale_candidates.residue" "$(list_stale_candidates)"

_MOCK_ISSUE_LIST="[$(mkissue 16 autonomous approved in-progress),$(mkissue 17 autonomous stalled pending-dev),$(mkissue 18 autonomous in-progress)]"
assert_numbers_eq "TC-W1A-PARITY-033 list_hygiene_residue.residue" "list_hygiene_residue.residue" "$(list_hygiene_residue)"

_MOCK_ISSUE_LIST="[$(mkissue 19 autonomous in-progress approved),$(mkissue 20 autonomous reviewing)]"
assert_int_eq "TC-W1A-PARITY-034 count_active.residue" "count_active.residue" "$(count_active)"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
