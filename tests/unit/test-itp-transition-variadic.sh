#!/bin/bash
# test-itp-transition-variadic.sh — issue #331: extend itp_transition_state
# (CSV multi-remove / multi-add) and migrate the last four raw `gh issue edit`
# label-flip survivors behind it.
#
# Proves:
#   1. The CSV-extended leaf itp_github_transition_state is BYTE-IDENTICAL for
#      single-label callers (the 17 existing 3-positional callers are unaffected)
#      and correctly emits multi-flag for a comma-separated REMOVE/ADD (the
#      "comma = member separator" contract; empty members dropped; empty side
#      omits the flag).  [AC1]
#   2. All four migrated sites route through the verb AND preserve their
#      caller-side fail-safe framing (dev:835 `|| log`, review:3466
#      `2>/dev/null || true`, the hygiene_strip CSV-from-$stripped + early-return,
#      review:3552 stderr-capture `if ! _err=$(… 2>&1 >/dev/null)`).  [AC2, P1]
#   3. hygiene_strip stays atomic (one verb call) and ZERO verb calls when the
#      issue is already clean (the [[ -z "$stripped" ]] early-return fires first). [P3]
#   4. The spec-gate C.3 anchors were re-anchored to the migrated forms — the map
#      no longer lists the raw `gh issue edit` literals; check-spec-drift.sh C.3
#      passes against the real tree (RED-without-the-reanchor).  [AC3, P1]
#   5. Source-shape: zero raw `gh issue edit` at the four sites; the cutover
#      baseline shrank by the 4 signatures; check-provider-cutover.sh green. [AC4]
#
# Run: bash tests/unit/test-itp-transition-variadic.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
ITP_LIB="$SCRIPTS/lib-issue-provider.sh"
LIB_DISPATCH="$SCRIPTS/lib-dispatch.sh"
DEV="$SCRIPTS/autonomous-dev.sh"
REVIEW="$SCRIPTS/autonomous-review.sh"
CODESITE_MAP="$PROJECT_ROOT/docs/pipeline/spec-codesite-map.json"
BASELINE="$SCRIPTS/providers/cutover-baseline.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected: |$expected|"
    echo "      actual:   |$actual|"
    FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      needle: |$needle|"; echo "      hay:    |$hay|"
    FAIL=$((FAIL + 1))
  fi
}
assert_not_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" != *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      unexpected needle: |$needle|"
    FAIL=$((FAIL + 1))
  fi
}

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export REPO_NAME=autonomous-dev-team
export PROJECT_ID=test-itp-transition-variadic-$$
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# ===========================================================================
# 1. LEAF GOLDEN-TRACE — CSV semantics (AC1).
# ===========================================================================
# A recording `gh` stub: writes full argv (one arg per line) to $_GH_ARGV_FILE.
# itp_github_transition_state makes exactly ONE `gh issue edit`, so paste-joining
# the file yields the complete argv of that single call.
_GH_ARGV_FILE="$(mktemp)"
gh() { printf '%s\n' "$@" > "$_GH_ARGV_FILE"; return 0; }
export -f gh
export _GH_ARGV_FILE

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-issue-provider.sh
source "$ITP_LIB"
set +e

recorded_argv() { paste -sd' ' "$_GH_ARGV_FILE"; }

echo "=== LEAF GOLDEN-TRACE: itp_github_transition_state CSV semantics ==="

itp_github_transition_state 42 reviewing approved >/dev/null
assert_eq "TC-ITV-001 backward-compat single-label byte-identical" \
  "issue edit 42 --repo $REPO --remove-label reviewing --add-label approved" "$(recorded_argv)"

itp_github_transition_state 42 "in-progress,pending-dev" "pending-review" >/dev/null
assert_eq "TC-ITV-002 CSV multi-remove + single add" \
  "issue edit 42 --repo $REPO --remove-label in-progress --remove-label pending-dev --add-label pending-review" \
  "$(recorded_argv)"

itp_github_transition_state 42 "reviewing,autonomous" "" >/dev/null
assert_eq "TC-ITV-003 CSV multi-remove, empty add omits --add-label" \
  "issue edit 42 --repo $REPO --remove-label reviewing --remove-label autonomous" "$(recorded_argv)"

itp_github_transition_state 42 "in-progress,,pending-dev" "" >/dev/null
assert_eq "TC-ITV-004 empty CSV members dropped" \
  "issue edit 42 --repo $REPO --remove-label in-progress --remove-label pending-dev" "$(recorded_argv)"

itp_github_transition_state 42 "" "a,b" >/dev/null
assert_eq "TC-ITV-005 empty REMOVE omits --remove-label, CSV add" \
  "issue edit 42 --repo $REPO --add-label a --add-label b" "$(recorded_argv)"

itp_github_transition_state 42 "" "" >/dev/null
assert_eq "TC-ITV-006 empty both → bare edit (no flags)" \
  "issue edit 42 --repo $REPO" "$(recorded_argv)"

itp_github_transition_state 42 "x,y" "" >/dev/null
assert_eq "TC-ITV-007 comma is the member separator (documented precondition)" \
  "issue edit 42 --repo $REPO --remove-label x --remove-label y" "$(recorded_argv)"

# Shim routing / backward-compat at the public verb.
itp_transition_state 42 reviewing approved >/dev/null
assert_eq "TC-ITV-010 shim itp_transition_state routes single-label byte-identically" \
  "issue edit 42 --repo $REPO --remove-label reviewing --add-label approved" "$(recorded_argv)"

itp_transition_state 42 "pending-dev" "pending-review" >/dev/null
assert_eq "TC-ITV-011 label_swap-style single-label delegation unaffected" \
  "issue edit 42 --repo $REPO --remove-label pending-dev --add-label pending-review" "$(recorded_argv)"

rm -f "$_GH_ARGV_FILE"
unset -f gh

# ===========================================================================
# 2. hygiene_strip behavioral — atomic + early-return (P3).
# ===========================================================================
# Re-source lib-dispatch.sh under a FILE-backed gh stub. hygiene_strip's return
# value is captured via `out=$(…)` — a command-substitution SUBSHELL — so an
# in-memory _GH_CALLS array would NOT survive back to the parent. The stub appends
# each call to $_HYG_GH_LOG (a file), which DOES persist across the subshell, so we
# read both the return value AND the captured argv. The migrated hygiene_strip
# (CSV-from-$stripped → itp_transition_state → itp_github_transition_state →
# gh issue edit) must emit argv byte-identical to the pre-migration multi-remove form.
echo "=== hygiene_strip_residual_labels: atomic CSV + early-return (P3) ==="
_HYG_GH_LOG="$(mktemp)"
export _HYG_GH_LOG
gh() { printf '%s\n' "$*" >> "$_HYG_GH_LOG"; return 0; }
export -f gh
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB_DISPATCH" >/dev/null 2>&1
set +e

# TC-ITV-031: terminal (approved) + two transitional → one atomic verb call
# labels_json is the [W1a, #371] normalized array of NAME strings (not the raw
# gh `[{"name":...}]` object shape) — the shape hygiene_strip_residual_labels
# now consumes since list_hygiene_residue routes through itp_list_forbidden_combos.
: > "$_HYG_GH_LOG"
labels='["approved","in-progress","pending-dev"]'
out=$(hygiene_strip_residual_labels 200 "$labels")
edit_calls=$(grep -E '^issue edit' "$_HYG_GH_LOG" || true)
edit_count=$(grep -cE '^issue edit' "$_HYG_GH_LOG" || true)
assert_eq "TC-ITV-031 one atomic edit call for N residual labels" "1" "$edit_count"
assert_contains "TC-ITV-031 both residual labels removed in the one edit (in-progress)" "remove-label in-progress" "$edit_calls"
assert_contains "TC-ITV-031 both residual labels removed in the one edit (pending-dev)" "remove-label pending-dev" "$edit_calls"
assert_not_contains "TC-ITV-031 hygiene strip emits no --add-label (remove-only)" "add-label" "$edit_calls"
assert_eq "TC-ITV-031 echoes the space-separated stripped list unchanged" "in-progress pending-dev" "$out"

# TC-ITV-030 (≡ TC-HYG-006): already-clean (no transitional) → ZERO verb calls
: > "$_HYG_GH_LOG"
out=$(hygiene_strip_residual_labels 201 '["approved"]')
edit_count=$(grep -cE '^issue edit' "$_HYG_GH_LOG" || true)
assert_eq "TC-ITV-030 already-clean issue → ZERO edit calls (early-return)" "0" "$edit_count"
assert_eq "TC-ITV-030 already-clean issue → empty stripped return" "" "$out"

# TC-ITV-032: transitional-only (no terminal) → defensive early-return, ZERO calls
: > "$_HYG_GH_LOG"
out=$(hygiene_strip_residual_labels 202 '["in-progress"]')
edit_count=$(grep -cE '^issue edit' "$_HYG_GH_LOG" || true)
assert_eq "TC-ITV-032 non-terminal issue → ZERO edit calls (_has_terminal_label miss)" "0" "$edit_count"

rm -f "$_HYG_GH_LOG"
unset -f gh

# ===========================================================================
# 3. PER-SITE SOURCE-SHAPE — migrated form + fail-safe framing preserved (AC2, P1).
# ===========================================================================
echo "=== PER-SITE: migrated verb call + caller-side fail-safe framing (P1) ==="

# A1 dev:835 — the PR-found success block.
dev_block=$(awk '/PR found: move to pending-review for the review agent/{f=1} f{print} /Failed to update issue labels/{if(f)exit}' "$DEV")
assert_contains "TC-ITV-020 A1 dev migrated to itp_transition_state CSV multi-remove" \
  'itp_transition_state "$ISSUE_NUMBER" "in-progress,pending-dev" "pending-review"' "$dev_block"
assert_contains "TC-ITV-020 A1 preserves the || log fail-safe framing" \
  '|| log "WARNING: Failed to update issue labels"' "$dev_block"
assert_not_contains "TC-ITV-020 A1 no raw gh issue edit survives in the block" \
  'gh issue edit' "$dev_block"

# A2 review:3466 — post-merge approved-flip (INV-33).
rev_a2=$(awk '/never close the issue directly/{f=1} f{print} /merge_closes_issue capability gate/{if(f)exit}' "$REVIEW")
assert_contains "TC-ITV-021 A2 review migrated to itp_transition_state CSV multi-remove" \
  'itp_transition_state "$ISSUE_NUMBER" "reviewing,autonomous" "approved"' "$rev_a2"
assert_contains "TC-ITV-021 A2 preserves the 2>/dev/null || true fail-safe framing" \
  '2>/dev/null || true' "$rev_a2"
assert_not_contains "TC-ITV-021 A2 no raw gh issue edit survives in the block" \
  'gh issue edit' "$rev_a2"

# A3 lib-dispatch hygiene_strip — CSV from the real scalar $stripped, no add.
hyg_fn=$(awk '/^hygiene_strip_residual_labels\(\) \{/{f=1} f{print} /^\}/{if(f)exit}' "$LIB_DISPATCH")
assert_contains "TC-ITV-022 A3 hygiene_strip routes through itp_transition_state" \
  'itp_transition_state "$issue_num"' "$hyg_fn"
assert_contains "TC-ITV-022 A3 builds the CSV from the real \$stripped scalar (tr ' ' ',')" \
  "tr ' ' ','" "$hyg_fn"
assert_contains "TC-ITV-022 A3 keeps the _has_terminal_label prefilter" \
  '_has_terminal_label' "$hyg_fn"
assert_contains "TC-ITV-022 A3 keeps the empty-\$stripped early-return" \
  '[[ -z "$stripped" ]]' "$hyg_fn"
assert_contains "TC-ITV-022 A3 keeps the echo \$stripped return" \
  'echo "$stripped"' "$hyg_fn"
assert_not_contains "TC-ITV-022 A3 no raw gh issue-edit args[] survives in the fn" \
  'gh "${args[@]}"' "$hyg_fn"

# B review:3552 — auto-merge-fail re-queue (single-remove, stderr-capture preserved).
rev_b=$(awk '/a failed label transition is diagnosable/{f=1} f{print} /flipped to pending-dev for rebase re-dispatch/{if(f)exit}' "$REVIEW")
assert_contains "TC-ITV-023 B migrated to itp_transition_state (single-remove) inside stderr-capture" \
  'if ! _edit_err=$(itp_transition_state "$ISSUE_NUMBER" "reviewing" "pending-dev" 2>&1 >/dev/null); then' "$rev_b"
assert_not_contains "TC-ITV-023 B no raw gh issue edit survives in the block" \
  'gh issue edit' "$rev_b"

# ===========================================================================
# 4. SOURCE-SHAPE — zero raw gh issue edit at the 4 sites; baseline shrank by 4 (AC4).
# ===========================================================================
echo "=== SOURCE-SHAPE: zero raw gh issue edit at the 4 migrated sites + baseline −4 (AC4) ==="

# All four raw `gh issue edit` survivors are gone from the caller layer.
n_dev=$(grep -c 'gh issue edit' "$DEV" || true)
assert_eq "TC-ITV-050 autonomous-dev.sh has ZERO raw 'gh issue edit'" "0" "$n_dev"
n_rev=$(grep -c 'gh issue edit' "$REVIEW" || true)
assert_eq "TC-ITV-050 autonomous-review.sh has ZERO raw 'gh issue edit'" "0" "$n_rev"
# lib-dispatch.sh's only `gh issue edit`-producing site was the hygiene args[] builder.
n_hyg=$(grep -c 'gh "${args\[@\]}"' "$LIB_DISPATCH" || true)
assert_eq "TC-ITV-050 lib-dispatch.sh hygiene gh \"\${args[@]}\" builder removed" "0" "$n_hyg"

# Baseline: the 4 (file, content) signatures are GONE.
absent_dev=$(jq -r '[.surviving_sites[] | select(.file=="autonomous-dev.sh" and (.content|test("gh issue edit")))] | length' "$BASELINE")
assert_eq "TC-ITV-051 baseline: autonomous-dev.sh gh-issue-edit signature removed" "0" "$absent_dev"
absent_rev=$(jq -r '[.surviving_sites[] | select(.file=="autonomous-review.sh" and (.content|test("gh issue edit")))] | length' "$BASELINE")
assert_eq "TC-ITV-051 baseline: autonomous-review.sh gh-issue-edit signatures removed (both)" "0" "$absent_rev"
absent_hyg=$(jq -r '[.surviving_sites[] | select(.file=="lib-dispatch.sh" and (.content|test("gh \"\\$\\{args")))] | length' "$BASELINE")
assert_eq "TC-ITV-051 baseline: lib-dispatch.sh hygiene gh \"\${args[@]}\" signature removed" "0" "$absent_hyg"

# ===========================================================================
# 5. SPEC-GATE C.3 RE-ANCHOR (AC3, P1) — the 3 anchors point at the migrated
#    forms, NOT the raw `gh issue edit` literals (RED-without-the-reanchor).
# ===========================================================================
echo "=== SPEC-GATE C.3: the 3 code_sites re-anchored away from the raw gh literals (AC3, P1) ==="

a_dev=$(jq -r '.code_sites["dev-trap-success-pr"].anchor' "$CODESITE_MAP")
assert_not_contains "TC-ITV-041 dev-trap-success-pr no longer anchors on the raw --add-label literal" \
  '--add-label "pending-review"' "$a_dev"
a_merged=$(jq -r '.code_sites["review-pass-merged"].anchor' "$CODESITE_MAP")
assert_not_contains "TC-ITV-041 review-pass-merged no longer anchors on the raw --remove-label literal" \
  '--remove-label "autonomous"' "$a_merged"
a_nopr=$(jq -r '.code_sites["review-no-pr"].anchor' "$CODESITE_MAP")
assert_not_contains "TC-ITV-041 review-no-pr no longer anchors on the raw --remove-label literal" \
  '--remove-label "reviewing"' "$a_nopr"

# Each re-anchored literal must actually grep in its cited file (else C.3 fails live).
for pair in \
  "dev-trap-success-pr:$DEV" \
  "review-pass-merged:$REVIEW" \
  "review-no-pr:$REVIEW"; do
  tid="${pair%%:*}"; f="${pair##*:}"
  anc=$(jq -r --arg t "$tid" '.code_sites[$t].anchor' "$CODESITE_MAP")
  if grep -Fq -- "$anc" "$f"; then
    echo -e "  ${GREEN}PASS${NC}: TC-ITV-040 re-anchor '$tid' → '$anc' greps in $(basename "$f")"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: TC-ITV-040 re-anchor '$tid' → '$anc' NOT found in $(basename "$f")"; FAIL=$((FAIL + 1))
  fi
done

# ===========================================================================
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
