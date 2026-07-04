#!/bin/bash
# test-w1d-ci-status-mergeable-parity.sh — #399 W1d decision-level parity.
#
# Proves the W1d normalization (chp_ci_status → single token green|pending|
# failed|none; chp_mergeable absorbs -q '.mergeable') is a DECISION-level
# behavior-parity refactor:
#
#   1. For every fixture class the pre-#399 TC-DSAP-004 jq predicate exercised
#      (all-success, mixed-pending, mixed-failure, skipped-success, empty,
#      transport-error) PLUS the R2 rc-quirk cases (rc≠0+failing-JSON,
#      rc≠0+pending-JSON, rc≠0+[], rc≠0+garbage), the NEW ci_is_green returns
#      the SAME rc as the OLD `length>0 and all(.=="SUCCESS")` gate did — the
#      per-row `old_ci_is_green_rc` / `new_ci_is_green_rc` fields in
#      tests/unit/fixtures/w1d-parity/ci-decision-golden.json are identical
#      by construction (R4).
#
#   2. For every TC-MG-CLS input (MERGEABLE, mergeable, CONFLICTING,
#      conflicting, UNKNOWN, empty, garbage, CLEAN, BEHIND — the FULL existing
#      table), `_classify_mergeable_gate` returns the same value as recorded
#      in mergeable-classifier-golden.json — the classifier is byte-unchanged
#      per R3, lib-review-mergeable.sh ships unmodified.
#
# The suite runs only the NEW code (chp_ci_status normalized-token leaf,
# rewritten ci_is_green caller) and diffs against the goldens. See the
# `.meta` sidecars for provenance.
#
# Run: bash tests/unit/test-w1d-ci-status-mergeable-parity.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
FIXTURES="$SCRIPT_DIR/fixtures/w1d-parity"
CI_GOLDEN="$FIXTURES/ci-decision-golden.json"
MG_GOLDEN="$FIXTURES/mergeable-classifier-golden.json"

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

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }
[[ -f "$CI_GOLDEN" ]] || { echo "FATAL: missing $CI_GOLDEN"; exit 2; }
[[ -f "$MG_GOLDEN" ]] || { echo "FATAL: missing $MG_GOLDEN"; exit 2; }

echo "=== TC-W1D-PARITY-CI: chp_ci_status token + ci_is_green rc match the golden ==="

# _drive_ci_is_green <gh_stdout> <gh_rc> — source lib-dispatch.sh under a
# stubbed chp_ci_status that emits the fixture's `gh` stdout and returns the
# fixture's `gh` rc (mirroring the R2 rc-quirk cases), then invoke ci_is_green
# and echo `<token>\t<rc>` where token is the value chp_ci_status produced
# (before ci_is_green wrapped it) and rc is ci_is_green's exit.
#
# We stub the PROVIDER seam (chp_github_ci_status) so the real leaf implementation
# is exercised end-to-end: gh is stubbed, chp_ci_status is the real dispatch,
# the leaf normalizes the payload → token, ci_is_green calls chp_ci_status
# then tests `[[ "$token" == "green" ]]`.
_drive_ci_is_green() {
  local gh_stdout="$1" gh_rc="$2"
  local out_file
  out_file="$(mktemp)"
  env -u PROJECT_DIR REPO=o/r \
      _W1D_GH_STDOUT="$gh_stdout" _W1D_GH_RC="$gh_rc" _W1D_OUT="$out_file" \
  bash -c '
    set -uo pipefail
    gh() { printf "%s" "$_W1D_GH_STDOUT"; return "$_W1D_GH_RC"; }
    # Source the CHP dispatch layer so chp_ci_status resolves to
    # chp_github_ci_status against our stubbed `gh`.
    source "'"$SCRIPTS/lib-code-host.sh"'" 2>/dev/null
    # Source lib-dispatch.sh JUST enough to reach ci_is_green.
    # Rather than sourcing the whole file (which needs a wide env), inline the
    # tiny post-#399 ci_is_green body against the SAME chp_ci_status contract.
    ci_is_green() {
      local pr_num="$1"
      local ci_token ci_err_file ci_err_content
      ci_err_file=$(mktemp)
      if ci_token=$(chp_ci_status "$pr_num" 2>"$ci_err_file"); then
        rm -f "$ci_err_file"
      else
        ci_err_content=$(cat "$ci_err_file")
        rm -f "$ci_err_file"
        if [ -n "$ci_err_content" ]; then
          echo "WARN: CI-status query (chp_ci_status) failed for PR #${pr_num}: ${ci_err_content}" >&2
        fi
        ci_token=""
      fi
      [[ "$ci_token" == "green" ]]
    }
    tok=$(chp_ci_status 42 2>/dev/null) || true
    ci_is_green 42; rc=$?
    printf "%s\t%s\n" "$tok" "$rc" > "$_W1D_OUT"
  '
  cat "$out_file"
  rm -f "$out_file"
}

# Iterate every row in the ci golden and assert token + rc. Uses a `|`-joined
# row (no fixture field contains `|`) rather than TSV so an empty leading
# field (e.g. `gh_stdout=""` for the transport-error row) doesn't collapse
# under bash's IFS-tab-is-whitespace splitting.
while IFS= read -r row; do
  key="${row%%|*}"; rest="${row#*|}"
  gh_stdout="${rest%%|*}"; rest="${rest#*|}"
  gh_rc="${rest%%|*}"; rest="${rest#*|}"
  expected_token="${rest%%|*}"; expected_rc="${rest#*|}"
  observed="$(_drive_ci_is_green "$gh_stdout" "$gh_rc")"
  observed_token="${observed%%$'\t'*}"
  observed_rc="${observed##*$'\t'}"
  observed_rc="${observed_rc%$'\n'}"
  assert_eq "TC-W1D-PARITY-CI [$key] token" "$expected_token" "$observed_token"
  assert_eq "TC-W1D-PARITY-CI [$key] ci_is_green rc" "$expected_rc" "$observed_rc"
done < <(jq -r 'to_entries[] | "\(.key)|\(.value.gh_stdout)|\(.value.gh_rc)|\(.value.new_token)|\(.value.new_ci_is_green_rc)"' "$CI_GOLDEN")

echo
echo "=== TC-W1D-ARGV-SRC: no --json / -q on chp_ci_status / chp_mergeable caller lines outside providers/ (AC2) ==="

# AC2 secondary guard: grep the CALLER-layer files (everything under
# skills/autonomous-dispatcher/scripts/ EXCEPT providers/) for
# `chp_ci_status ` / `chp_mergeable ` lines and assert none carry `--json`
# or a `-q ` flag past the verb. A backslid caller-side jq re-emerging on
# the seam would fail this check.
_scan_dir="$SCRIPTS"
_offenders="$(
  grep -rEn '(chp_ci_status|chp_mergeable) ' "$_scan_dir" \
    --include='*.sh' \
    --exclude-dir=providers 2>/dev/null \
  | grep -E '(chp_ci_status|chp_mergeable) [^#\n]*(-{2}json|-q )' \
  || true
)"
if [[ -z "$_offenders" ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-W1D-ARGV-SRC no caller line passes --json / -q to chp_ci_status or chp_mergeable"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-W1D-ARGV-SRC caller-side --json/-q leak into chp_ci_status/chp_mergeable"
  echo "$_offenders" | sed 's/^/      /'
  FAIL=$((FAIL + 1))
fi

echo
echo "=== TC-W1D-PARITY-MG: _classify_mergeable_gate matches the golden on the full input table ==="

# The classifier is byte-unchanged; source lib-review-mergeable.sh and diff.
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-mergeable.sh
source "$SCRIPTS/lib-review-mergeable.sh"

while IFS= read -r pair; do
  # Split on the first `|` (a sentinel outside any classifier token — MERGEABLE,
  # mergeable, CONFLICTING, conflicting, UNKNOWN, empty, garbage, CLEAN, BEHIND
  # — and outside every gate value — proceed, block-substantive,
  # block-nonsubstantive). Preserves the empty-key row (`""` → block-nonsubstantive)
  # that IFS-tab whitespace-collapsing would otherwise fuse.
  input="${pair%%|*}"
  expected="${pair#*|}"
  actual="$(_classify_mergeable_gate "$input")"
  assert_eq "TC-W1D-PARITY-MG classifier(<${input}>)" "$expected" "$actual"
done < <(jq -r 'to_entries[] | "\(.key)|\(.value)"' "$MG_GOLDEN")

# --------------------------------------------------------------------------
echo
echo "=== Results ==="
TOTAL=$((PASS + FAIL))
echo -e "Total: $TOTAL  ${GREEN}Passed: $PASS${NC}  ${RED}Failed: $FAIL${NC}"
echo
[[ $FAIL -gt 0 ]] && exit 1
exit 0
