#!/bin/bash
# test-w1a-state-read-contracts.sh — issue #371 (W1a, #347 phase-2).
#
# LEAF-level coverage for the ABSTRACT itp_list_by_state / itp_count_by_state /
# itp_list_forbidden_combos contract (docs/pipeline/provider-spec.md §3.1):
#
#   AC1 is covered by tests/unit/test-w1a-state-read-parity.sh (decision-level
#       parity for the six lib-dispatch.sh callers) — NOT this file.
#   AC2: zero gh flags / jq programs cross the seam. Primary proof — a
#       seam-trace fixture provider records the argv each verb RECEIVES; the
#       six real callers are run against it and every received argument is
#       asserted to not match `^--` (other than the contract's own positional
#       grammar) and to not contain a jq-program fragment. Secondary guard —
#       the #296-style source grep (no `--json`/`-q`/`--label` token on caller
#       lines outside providers/).
#   AC2 (leaf): the leaf itself returns the normalized shape — `labels` an
#       array of NAME strings, `comments` the [INV-90] array, canonical
#       `number`-ascending sort, `[]` never null on no matches.
#   R2: fail-closed — gh rc≠0 → leaf rc≠0, no partial output.
#   R1 (leaf): the field-projection contract — FIELDS_CSV controls EXACTLY
#       which keys are returned.
#
# Run: bash tests/unit/test-w1a-state-read-contracts.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
LIB_DISPATCH="$SCRIPTS/lib-dispatch.sh"
ITP_GITHUB="$SCRIPTS/providers/itp-github.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      expected: |$expected|"; echo "      actual:   |$actual|"
    FAIL=$((FAIL + 1))
  fi
}
assert_contains() {
  local desc="$1" needle="$2" hay="$3"
  if [[ "$hay" == *"$needle"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"; echo "      needle: |$needle|"; echo "      hay: |${hay:0:300}|"
    FAIL=$((FAIL + 1))
  fi
}
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-w1a-contracts-$$
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# ===========================================================================
# AC2 PRIMARY PROOF — seam-trace: stub the itp_github_* leaves to RECORD the
# argv they receive from the six real callers, then assert no arg looks like
# a gh flag or a jq-program fragment.
# ===========================================================================
echo "=== AC2 seam-trace: no gh flags / jq programs cross the seam ==="

_SEAM_ARGV_FILE="$(mktemp)"
export _SEAM_ARGV_FILE

_seam_record() {
  # Record every positional arg on its own line (verb name prefix so multiple
  # calls in one test run are distinguishable), then emit an empty-but-valid
  # response shape so the CALLER's downstream jq pipe still runs cleanly.
  local verb="$1"; shift
  {
    printf 'VERB:%s\n' "$verb"
    printf 'ARG:%s\n' "$@"
  } >> "$_SEAM_ARGV_FILE"
}

seam_out=$(
  env -u AUTONOMOUS_PROVIDERS_DIR ISSUE_PROVIDER=github bash -c '
    set -uo pipefail
    export REPO="'"$REPO"'" REPO_OWNER="'"$REPO_OWNER"'" PROJECT_ID="'"$PROJECT_ID"'"
    export _SEAM_ARGV_FILE="'"$_SEAM_ARGV_FILE"'"
    source "'"$SCRIPTS"'/lib-issue-provider.sh"
    itp_github_list_by_state()        { { printf "VERB:list_by_state\n"; printf "ARG:%s\n" "$@"; } >> "$_SEAM_ARGV_FILE"; echo "[]"; }
    itp_github_count_by_state()       { { printf "VERB:count_by_state\n"; printf "ARG:%s\n" "$@"; } >> "$_SEAM_ARGV_FILE"; echo "0"; }
    itp_github_list_forbidden_combos(){ { printf "VERB:list_forbidden_combos\n"; printf "ARG:%s\n" "$@"; } >> "$_SEAM_ARGV_FILE"; echo "[]"; }
    source "'"$LIB_DISPATCH"'"
    count_active >/dev/null
    list_new_issues >/dev/null
    list_pending_review >/dev/null
    list_pending_dev >/dev/null
    list_stale_candidates >/dev/null
    list_hygiene_residue >/dev/null
  ' 2>&1
)

if [[ -s "$_SEAM_ARGV_FILE" ]]; then
  ok "seam-trace fixture captured argv from all six callers"
else
  bad "seam-trace fixture captured NOTHING (harness broken): $seam_out"
fi

# Every recorded ARG line must NOT start with `--` (no gh flags) and must NOT
# contain a jq-program fragment (select(, .labels[], | length — the literal
# needles the issue names as the injection markers to catch).
violation_found=0
while IFS= read -r line; do
  case "$line" in
    ARG:--*)
      bad "seam-trace: a received argument starts with '--' (gh flag leaked across the seam): ${line#ARG:}"
      violation_found=1
      ;;
    ARG:*'select('*|ARG:*'.labels[]'*|ARG:*'| length'*)
      bad "seam-trace: a received argument contains a jq-program fragment: ${line#ARG:}"
      violation_found=1
      ;;
  esac
done < "$_SEAM_ARGV_FILE"
[[ "$violation_found" -eq 0 ]] && ok "AC2: zero gh-flag-shaped or jq-program-shaped arguments received by any of the 3 verbs across all 6 callers"

# Sanity: the recorded args ARE the expected abstract positional grammar
# (state, labels-CSV, limit, [fields-CSV|any-of-CSV]) — proves the seam-trace
# harness genuinely captured real calls, not an empty no-op.
recorded="$(cat "$_SEAM_ARGV_FILE")"
assert_contains "seam-trace recorded count_active's abstract args" $'ARG:open\nARG:autonomous\nARG:100\nARG:in-progress,reviewing' "$recorded"
assert_contains "seam-trace recorded list_new_issues's abstract args" $'ARG:open\nARG:autonomous\nARG:100\nARG:number,labels,title' "$recorded"
assert_contains "seam-trace recorded list_hygiene_residue's abstract args (thin pass-through)" $'ARG:open\nARG:autonomous\nARG:100' "$recorded"
rm -f "$_SEAM_ARGV_FILE"

# ===========================================================================
# AC2 SECONDARY GUARD — source grep: no --json/-q/--label token on the
# caller-layer lines for these three verbs, outside providers/.
# ===========================================================================
echo ""
echo "=== AC2 secondary guard: source grep (caller-layer, outside providers/) ==="

caller_lines="$(grep -n 'itp_list_by_state\|itp_count_by_state\|itp_list_forbidden_combos' "$LIB_DISPATCH" | grep -v '^\s*#' | grep -v '^[0-9]*: *#')"
if grep -qE -- '--json|--label| -q ' <<<"$caller_lines"; then
  bad "AC2 secondary: a caller-layer itp_list_by_state/count_by_state/list_forbidden_combos call site still carries a gh flag: $caller_lines"
else
  ok "AC2 secondary: zero --json/--label/-q tokens on the caller-layer call sites in lib-dispatch.sh"
fi

# ===========================================================================
# LEAF SHAPE: normalized labels (name-strings, not {name} objects), comments
# (INV-90 array), number-ascending sort, [] never null.
# ===========================================================================
echo ""
echo "=== LEAF SHAPE: itp_github_list_by_state normalization ==="

_GH_PAYLOAD='[
  {"number":5,"title":"t5","labels":[{"name":"autonomous"},{"name":"in-progress"}],"comments":[]},
  {"number":3,"title":"t3","labels":[{"name":"autonomous"}],"comments":[{"url":"https://x/issues/3#issuecomment-1","author":{"login":"alice"},"body":"hi","createdAt":"2026-01-01T00:00:00Z"}]}
]'
gh() { printf '%s' "$_GH_PAYLOAD"; }
export -f gh
export _GH_PAYLOAD
# shellcheck source=../../skills/autonomous-dispatcher/scripts/providers/itp-github.sh
source "$ITP_GITHUB"
set +e

out="$(itp_github_list_by_state open autonomous 100 "number,title,labels,comments")"
assert_eq "leaf sorts number ascending regardless of gh's own order" \
  "3 5" "$(jq -r '[.[].number] | join(" ")' <<<"$out")"
assert_eq "leaf normalizes labels to a name-string array (not {name} objects)" \
  '["autonomous"]' "$(jq -c '.[0].labels' <<<"$out")"
assert_eq "leaf normalizes comments to the INV-90 array shape" \
  "alice" "$(jq -r '.[0].comments[0].author' <<<"$out")"

_GH_PAYLOAD='[]'
out="$(itp_github_list_by_state open autonomous 100 "number")"
assert_eq "no matches → [] (never null, never empty string)" "[]" "$out"

echo ""
echo "=== LEAF FIELD PROJECTION: FIELDS_CSV controls exactly the returned keys ==="
_GH_PAYLOAD='[{"number":1,"title":"t","labels":[{"name":"autonomous"}],"comments":[]}]'
out="$(itp_github_list_by_state open autonomous 100 "number,labels")"
assert_eq "fields=number,labels → exactly those two keys" "number,labels" "$(jq -r '.[0] | keys_unsorted | join(",")' <<<"$out")"
out="$(itp_github_list_by_state open autonomous 100 "number")"
assert_eq "fields=number → exactly one key" "number" "$(jq -r '.[0] | keys_unsorted | join(",")' <<<"$out")"

echo ""
echo "=== LEAF itp_github_count_by_state: bare integer, any-of semantics ==="
_GH_PAYLOAD='[
  {"number":1,"title":"","labels":[{"name":"in-progress"}],"comments":[]},
  {"number":2,"title":"","labels":[{"name":"reviewing"}],"comments":[]},
  {"number":3,"title":"","labels":[{"name":"pending-review"}],"comments":[]}
]'
out="$(itp_github_count_by_state open autonomous 100 "in-progress,reviewing")"
assert_eq "any-of count: 2 of 3 match in-progress OR reviewing" "2" "$out"
out="$(itp_github_count_by_state open autonomous 100 "")"
assert_eq "empty any-of → count ALL matches" "3" "$out"

echo ""
echo "=== LEAF itp_github_list_forbidden_combos: leaf owns the combo filter ==="
_GH_PAYLOAD='[
  {"number":1,"title":"","labels":[{"name":"approved"},{"name":"in-progress"}],"comments":[]},
  {"number":2,"title":"","labels":[{"name":"autonomous"}],"comments":[]},
  {"number":3,"title":"","labels":[{"name":"stalled"},{"name":"pending-dev"}],"comments":[]},
  {"number":4,"title":"","labels":[{"name":"approved"}],"comments":[]}
]'
out="$(itp_github_list_forbidden_combos open autonomous 100)"
assert_eq "combo filter: only terminal+transitional issues survive (1,3)" \
  "1 3" "$(jq -r '[.[].number] | join(" ")' <<<"$out")"
assert_eq "combo filter output fields are exactly number,labels" \
  "number,labels" "$(jq -r '.[0] | keys_unsorted | join(",")' <<<"$out")"

# ===========================================================================
# R2 FAIL-CLOSED: gh rc≠0 → leaf rc≠0, no partial output.
# ===========================================================================
echo ""
echo "=== R2 fail-closed: gh rc≠0 propagates ==="
gh() { echo "stub-gh: simulated failure" >&2; return 1; }
export -f gh
out="$(itp_github_list_by_state open autonomous 100 "number" 2>/dev/null)"; rc=$?
assert_eq "itp_github_list_by_state: gh failure → non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "itp_github_list_by_state: gh failure → no partial stdout" "" "$out"

out="$(itp_github_count_by_state open autonomous 100 "" 2>/dev/null)"; rc=$?
assert_eq "itp_github_count_by_state: gh failure → non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "itp_github_count_by_state: gh failure → no partial stdout" "" "$out"

out="$(itp_github_list_forbidden_combos open autonomous 100 2>/dev/null)"; rc=$?
assert_eq "itp_github_list_forbidden_combos: gh failure → non-zero rc" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"
assert_eq "itp_github_list_forbidden_combos: gh failure → no partial stdout" "" "$out"

# Malformed JSON from gh (rc 0, garbage body) must also fail rather than
# silently emit a bogus "successful-looking" array.
gh() { printf '{ not json'; return 0; }
export -f gh
out="$(itp_github_list_by_state open autonomous 100 "number" 2>/dev/null)"; rc=$?
assert_eq "malformed gh JSON → non-zero rc (fail-closed)" "1" "$([[ $rc -ne 0 ]] && echo 1 || echo 0)"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
[ "$FAIL" -eq 0 ]
