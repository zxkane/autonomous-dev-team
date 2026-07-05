#!/bin/bash
# test-provider-prompts-site-removal.sh — issue #421 R2/R4/AC4 (TC-P36-020..050).
#
# Verifies the (a) prompt-prose sites are GONE from autonomous-dev.sh /
# autonomous-review.sh / lib-review-bots.sh (replaced by
# `$(provider_prompt_fragment …)` calls) while the (b) executable residue
# sites SURVIVE byte-identical; the cutover-baseline.json shrink is EXACTLY
# the R2-classified (a) set; the full guard is green; and a synthetic new
# raw-gh injection still trips Check 1 (the guard is not weakened by this
# migration).
#
# Run: bash tests/unit/test-provider-prompts-site-removal.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
DEV_SH="$SCRIPTS/autonomous-dev.sh"
REVIEW_SH="$SCRIPTS/autonomous-review.sh"
BOTS_SH="$SCRIPTS/lib-review-bots.sh"
CHECK="$SCRIPTS/check-provider-cutover.sh"
BASELINE="$SCRIPTS/providers/cutover-baseline.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

# Same RE2-safe consuming-boundary detector check-provider-cutover.sh's
# gh_lines_in uses, applied here to count non-comment raw-gh lines per file.
count_raw_gh() {
  grep -aE '(^|[^A-Za-z_-])gh ' "$1" 2>/dev/null | awk '
    { s = $0; sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s)
      if (substr(s, 1, 1) == "#") next
      c++ }
    END { print c+0 }'
}

# ---------------------------------------------------------------------------
echo "=== TC-P36-020: autonomous-dev.sh raw-gh count == 1 (only the command -v gh probe, (b)) ==="
# ---------------------------------------------------------------------------
n=$(count_raw_gh "$DEV_SH")
if [[ "$n" -eq 1 ]] && grep -qF 'command -v gh &>/dev/null' "$DEV_SH"; then
  ok "TC-P36-020 autonomous-dev.sh raw-gh count is 1 (the command -v gh presence probe)"
else
  bad "TC-P36-020 expected exactly 1 (command -v gh probe), got $n"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-021: autonomous-review.sh raw-gh count == 4 (gh api user fallback + 2 WARNs + INV-33 close, (b)) ==="
# ---------------------------------------------------------------------------
n=$(count_raw_gh "$REVIEW_SH")
if [[ "$n" -eq 4 ]] \
   && grep -qF '_bot_login_raw=$(gh api user' "$REVIEW_SH" \
   && grep -qF 'gh issue close "$ISSUE_NUMBER" --repo "$REPO" --reason completed' "$REVIEW_SH"; then
  ok "TC-P36-021 autonomous-review.sh raw-gh count is 4 (bot-login fallback + WARNs + INV-33 close)"
else
  bad "TC-P36-021 expected exactly 4 executable survivors, got $n"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-022: lib-review-bots.sh raw-gh count == 0 (the sole (a) site fully fragment-rendered) ==="
# ---------------------------------------------------------------------------
n=$(count_raw_gh "$BOTS_SH")
if [[ "$n" -eq 0 ]] && grep -qF 'provider_prompt_fragment bots.review_count_check' "$BOTS_SH"; then
  ok "TC-P36-022 lib-review-bots.sh raw-gh count is 0 (fully migrated to provider_prompt_fragment)"
else
  bad "TC-P36-022 expected 0 raw-gh lines, got $n"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-023: lib-provider-prompts.sh loads before lib-review-bots.sh in every wrapper ==="
# ---------------------------------------------------------------------------
# Anchor on an ACTUAL `source "..."` statement (leading whitespace only),
# never a comment line that merely MENTIONS the filename (e.g. "[#421]
# provider_prompt_fragment — sourced BEFORE lib-review-bots.sh...").
SOURCE_STMT_RE='^[[:space:]]*source[[:space:]]+"\$\{LIB_DIR\}/%s"'
find_source_line() {
  grep -nE "$(printf "$SOURCE_STMT_RE" "$2")" "$1" | head -1 | cut -d: -f1
}
dev_order_ok=0
pp_line=$(find_source_line "$DEV_SH" 'lib-provider-prompts\.sh')
bots_line=$(find_source_line "$DEV_SH" 'lib-review-bots\.sh')
if [[ -n "$pp_line" ]] && [[ -n "$bots_line" ]] && [[ "$pp_line" -lt "$bots_line" ]]; then
  dev_order_ok=1
fi
review_order_ok=0
pp_line=$(find_source_line "$REVIEW_SH" 'lib-provider-prompts\.sh')
bots_line=$(find_source_line "$REVIEW_SH" 'lib-review-bots\.sh')
if [[ -n "$pp_line" ]] && [[ -n "$bots_line" ]] && [[ "$pp_line" -lt "$bots_line" ]]; then
  review_order_ok=1
fi
if [[ "$dev_order_ok" -eq 1 ]] && [[ "$review_order_ok" -eq 1 ]]; then
  ok "TC-P36-023 lib-provider-prompts.sh sourced BEFORE lib-review-bots.sh in both wrappers"
else
  bad "TC-P36-023 source order wrong (dev_ok=$dev_order_ok review_ok=$review_order_ok)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-030/031: cutover-baseline.json shrank to EXACTLY 13, per-file breakdown matches ==="
# ---------------------------------------------------------------------------
total=$(jq -r '.surviving_sites | length' "$BASELINE")
la=$(jq -r '[.surviving_sites[] | select(.file=="lib-auth.sh")] | length' "$BASELINE")
cpc=$(jq -r '[.surviving_sites[] | select(.file=="check-provider-cutover.sh")] | length' "$BASELINE")
ad=$(jq -r '[.surviving_sites[] | select(.file=="autonomous-dev.sh")] | length' "$BASELINE")
ar=$(jq -r '[.surviving_sites[] | select(.file=="autonomous-review.sh")] | length' "$BASELINE")
lrb=$(jq -r '[.surviving_sites[] | select(.file=="lib-review-bots.sh")] | length' "$BASELINE")
if [[ "$total" -eq 13 ]] && [[ "$la" -eq 5 ]] && [[ "$cpc" -eq 3 ]] && [[ "$ad" -eq 1 ]] && [[ "$ar" -eq 4 ]] && [[ "$lrb" -eq 0 ]]; then
  ok "TC-P36-030/031 baseline shrank to 13 (lib-auth=5, check-provider-cutover=3, autonomous-dev=1, autonomous-review=4, lib-review-bots=0)"
else
  bad "TC-P36-030/031 baseline breakdown mismatch: total=$total lib-auth=$la check-provider-cutover=$cpc autonomous-dev=$ad autonomous-review=$ar lib-review-bots=$lrb"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-032/050: check-provider-cutover.sh PASSes against the migrated tree ==="
# ---------------------------------------------------------------------------
out=$(bash "$CHECK" 2>&1); rc=$?
if [[ $rc -eq 0 ]] && [[ "$out" == *"cutover-guard: PASS"* ]]; then
  ok "TC-P36-032/050 cutover-guard: PASS against the migrated tree"
else
  bad "TC-P36-032/050 cutover-guard did not pass (rc=$rc):"
  echo "$out" | tail -20
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-034: a synthetic NEW raw-gh injection still trips Check 1 (guard not weakened) ==="
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp -r "$SCRIPTS" "$WORK/scripts"
# Inject a brand-new, never-baselined raw-gh line into a copy of autonomous-dev.sh.
printf '\n# synthetic injection for TC-P36-034\nSYNTH_TC_P36_034=$(gh issue view 999999 --json body)\n' >> "$WORK/scripts/autonomous-dev.sh"
out=$(bash "$WORK/scripts/check-provider-cutover.sh" --scripts-dir "$WORK/scripts" --baseline "$WORK/scripts/providers/cutover-baseline.json" 2>&1); rc=$?
if [[ $rc -ne 0 ]] && [[ "$out" == *"NEW/unbaselined raw-gh"* ]] && [[ "$out" == *"autonomous-dev.sh"* ]]; then
  ok "TC-P36-034 synthetic new raw-gh FAILs Check 1 loud, naming autonomous-dev.sh"
else
  bad "TC-P36-034 synthetic injection did NOT trip Check 1 (rc=$rc):"
  echo "$out" | tail -10
fi
rm -rf "$WORK"
trap - EXIT

# ---------------------------------------------------------------------------
echo ""
echo "=== TC-P36-040/041: Check 5/6 PASS with providers/prompts-gitlab.sh's example curl lines present ==="
# ---------------------------------------------------------------------------
out=$(bash "$CHECK" 2>&1)
if echo "$out" | grep -q "no raw \`glab\` token found outside providers/" \
   && echo "$out" | grep -q "no '/api/v4' curl (same-line or split-across-lines) found outside providers/lib-gitlab-transport.sh"; then
  ok "TC-P36-040/041 Check 5 and Check 6 both clean (providers/prompts-gitlab.sh excluded from Check 6)"
else
  bad "TC-P36-040/041 Check 5/6 output did not show clean — providers/prompts-gitlab.sh's curl examples may be tripping Check 6"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
