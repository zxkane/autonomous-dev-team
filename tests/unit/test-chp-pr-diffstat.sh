#!/bin/bash
# test-chp-pr-diffstat.sh — INV-124 / issue #452.
#
# Proves the new chp_pr_diffstat CHP verb: the self-guarding shim
# (lib-code-host.sh), the GitHub leaf (chp-github.sh, single gh pr view call
# regardless of DIMENSIONS-CSV), and the GitLab leaf (chp-gitlab.sh,
# changes_count + conditional GraphQL diffStatsSummary via the new
# _gl_graphql transport primitive).
#
# HERMETIC: stubs `gh` (GitHub leaf) / `_gl_api` + `_gl_graphql` (GitLab leaf)
# before sourcing. No network.
#
# Run: env -u PROJECT_DIR bash tests/unit/test-chp-pr-diffstat.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts"
CHP_LIB="$SCRIPTS/lib-code-host.sh"
CHP_GITHUB="$SCRIPTS/providers/chp-github.sh"
CHP_GITLAB="$SCRIPTS/providers/chp-gitlab.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then ok "$desc"
  else bad "$desc"; echo "      expected: |$expected|"; echo "      actual:   |$actual|"; fi
}
assert_rc_nz() {
  local desc="$1" rc="$2"
  if [ "$rc" != "0" ]; then ok "$desc (rc=$rc)"
  else bad "$desc (rc=0, expected non-zero)"; fi
}

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }
[ -f "$CHP_LIB" ]    || { echo "FATAL: lib-code-host.sh missing"; exit 2; }
[ -f "$CHP_GITHUB" ] || { echo "FATAL: chp-github.sh missing"; exit 2; }
[ -f "$CHP_GITLAB" ] || { echo "FATAL: chp-gitlab.sh missing"; exit 2; }

RUNDIR=$(mktemp -d)
trap 'rm -rf "$RUNDIR"' EXIT

# ===========================================================================
echo "=== chp_pr_diffstat shim (lib-code-host.sh) — self-guarding ==="
# ===========================================================================
(
  CODE_HOST=degraded
  export CODE_HOST
  source "$CHP_LIB" 2>/dev/null
  out=$(chp_pr_diffstat 42 files 2>&1); rc=$?
  echo "RC=$rc"
  echo "OUT=$out"
) > "$RUNDIR/shim.out" 2>&1
shim_rc=$(grep '^RC=' "$RUNDIR/shim.out" | cut -d= -f2)
assert_rc_nz "leaf-absent provider degrades to non-zero (no set -e abort)" "$shim_rc"
if grep -q "no chp_degraded_pr_diffstat leaf" "$RUNDIR/shim.out"; then
  ok "WARN names the missing leaf"
else
  bad "WARN does not name the missing leaf"
fi

# ===========================================================================
echo ""
echo "=== chp_github_pr_diffstat — single-call contract (TC-OVERREACH-007) ==="
# ===========================================================================
GH_CALL_LOG="$RUNDIR/gh-calls.log"
: > "$GH_CALL_LOG"
GH_PAYLOAD_FILE="$RUNDIR/gh-payload.json"
GH_FAIL=0

gh() {
  printf '%s\n' "$*" >> "$GH_CALL_LOG"
  if [ "$GH_FAIL" = "1" ]; then return 1; fi
  if [ "${1:-}" = "pr" ] && [ "${2:-}" = "view" ]; then
    cat "$GH_PAYLOAD_FILE"
    return 0
  fi
  return 1
}
export -f gh
jq -n '{additions: 3000, deletions: 500, changedFiles: 45}' > "$GH_PAYLOAD_FILE"

REPO="owner/repo"
export REPO
# shellcheck source=../../skills/autonomous-dispatcher/scripts/providers/chp-github.sh
source "$CHP_GITHUB"

: > "$GH_CALL_LOG"
out_files=$(chp_github_pr_diffstat 42 files 2>/dev/null)
assert_eq "files-only request: exactly ONE gh call" "1" "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')"
assert_eq "files-only request: projects only changed_files" "45" "$(jq -r '.changed_files' <<<"$out_files")"
assert_eq "files-only request: does NOT fabricate changed_lines" "null" "$(jq -r '.changed_lines // "null"' <<<"$out_files")"

: > "$GH_CALL_LOG"
out_lines=$(chp_github_pr_diffstat 42 lines 2>/dev/null)
assert_eq "lines-only request: exactly ONE gh call" "1" "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')"
assert_eq "lines-only request: changed_lines = additions+deletions" "3500" "$(jq -r '.changed_lines' <<<"$out_lines")"
assert_eq "lines-only request: does NOT fabricate changed_files" "null" "$(jq -r '.changed_files // "null"' <<<"$out_lines")"

: > "$GH_CALL_LOG"
out_both=$(chp_github_pr_diffstat 42 files,lines 2>/dev/null)
assert_eq "both-dimensions request: still exactly ONE gh call (zero marginal cost)" "1" "$(wc -l < "$GH_CALL_LOG" | tr -d ' ')"
assert_eq "both-dimensions: changed_files present" "45" "$(jq -r '.changed_files' <<<"$out_both")"
assert_eq "both-dimensions: changed_lines present" "3500" "$(jq -r '.changed_lines' <<<"$out_both")"

# TC-OVERREACH-006: read failure → rc≠0, no partial output.
GH_FAIL=1
out_fail=$(chp_github_pr_diffstat 42 files 2>/dev/null); rc_fail=$?
GH_FAIL=0
assert_rc_nz "gh failure → leaf rc≠0" "$rc_fail"
assert_eq "gh failure → no partial stdout" "" "$out_fail"

# Positional validation.
chp_github_pr_diffstat "" files >/dev/null 2>&1; assert_eq "empty PR → rc 2" "2" "$?"
chp_github_pr_diffstat 42 "" >/dev/null 2>&1; assert_eq "empty DIMENSIONS-CSV → rc 2" "2" "$?"
chp_github_pr_diffstat 42 bogus >/dev/null 2>&1; assert_eq "unrecognized dimension → rc 2" "2" "$?"

# ===========================================================================
echo ""
echo "=== chp_gitlab_pr_diffstat — changes_count + conditional GraphQL (TC-OVERREACH-008..012) ==="
# ===========================================================================
GL_API_CALL_LOG="$RUNDIR/gl-api-calls.log"
GL_GRAPHQL_CALL_LOG="$RUNDIR/gl-graphql-calls.log"
GL_API_PAYLOAD_FILE="$RUNDIR/gl-api-payload.json"
GL_GRAPHQL_PAYLOAD_FILE="$RUNDIR/gl-graphql-payload.json"
GL_API_FAIL=0
GL_GRAPHQL_FAIL=0

_gl_api() {
  printf '%s\n' "$*" >> "$GL_API_CALL_LOG"
  [ "$GL_API_FAIL" = "1" ] && return 1
  cat "$GL_API_PAYLOAD_FILE"
}
_gl_graphql() {
  printf '%s\n' "$1" >> "$GL_GRAPHQL_CALL_LOG"
  [ "$GL_GRAPHQL_FAIL" = "1" ] && return 1
  cat "$GL_GRAPHQL_PAYLOAD_FILE"
}
_gl_urlencode() { jq -rn --arg s "$1" '$s | @uri'; }
export -f _gl_api _gl_graphql _gl_urlencode

GITLAB_PROJECT="group%2Fproject"
GITLAB_HOST="gitlab.com"
export GITLAB_PROJECT GITLAB_HOST
# shellcheck source=../../skills/autonomous-dispatcher/scripts/providers/chp-gitlab.sh
source "$CHP_GITLAB"

# TC-OVERREACH-008: FILES-only via changes_count — no GraphQL call, includes
# the "1000+" capped-string case.
jq -n '{changes_count: "45"}' > "$GL_API_PAYLOAD_FILE"
: > "$GL_API_CALL_LOG"; : > "$GL_GRAPHQL_CALL_LOG"
out_gl_files=$(chp_gitlab_pr_diffstat 42 files 2>/dev/null)
assert_eq "GitLab FILES-only: changed_files from changes_count" "45" "$(jq -r '.changed_files' <<<"$out_gl_files")"
assert_eq "GitLab FILES-only: ZERO GraphQL calls" "0" "$(wc -l < "$GL_GRAPHQL_CALL_LOG" | tr -d ' ')"
assert_eq "GitLab FILES-only: exactly ONE base-MR-view call" "1" "$(wc -l < "$GL_API_CALL_LOG" | tr -d ' ')"

jq -n '{changes_count: "1000+"}' > "$GL_API_PAYLOAD_FILE"
: > "$GL_GRAPHQL_CALL_LOG"
out_gl_capped=$(chp_gitlab_pr_diffstat 42 files 2>/dev/null)
assert_eq "GitLab FILES: '1000+' parsed down to integer 1000" "1000" "$(jq -r '.changed_files' <<<"$out_gl_capped")"
assert_eq "GitLab FILES capped-string case: still ZERO GraphQL calls" "0" "$(wc -l < "$GL_GRAPHQL_CALL_LOG" | tr -d ' ')"

# TC-OVERREACH-009: LINES via GraphQL diffStatsSummary — exactly ONE call.
jq -n '{changes_count: "45"}' > "$GL_API_PAYLOAD_FILE"
jq -n '{project: {mergeRequest: {diffStatsSummary: {additions: 2500, deletions: 1000}}}}' > "$GL_GRAPHQL_PAYLOAD_FILE"
: > "$GL_API_CALL_LOG"; : > "$GL_GRAPHQL_CALL_LOG"
out_gl_lines=$(chp_gitlab_pr_diffstat 42 lines 2>/dev/null)
assert_eq "GitLab LINES: changed_lines = additions+deletions" "3500" "$(jq -r '.changed_lines' <<<"$out_gl_lines")"
assert_eq "GitLab LINES: exactly ONE GraphQL call" "1" "$(wc -l < "$GL_GRAPHQL_CALL_LOG" | tr -d ' ')"

# TC-OVERREACH-010: both dimensions → base MR view + exactly one GraphQL call.
: > "$GL_API_CALL_LOG"; : > "$GL_GRAPHQL_CALL_LOG"
out_gl_both=$(chp_gitlab_pr_diffstat 42 files,lines 2>/dev/null)
assert_eq "GitLab both dims: changed_files present" "45" "$(jq -r '.changed_files' <<<"$out_gl_both")"
assert_eq "GitLab both dims: changed_lines present" "3500" "$(jq -r '.changed_lines' <<<"$out_gl_both")"
assert_eq "GitLab both dims: exactly ONE GraphQL call (never more)" "1" "$(wc -l < "$GL_GRAPHQL_CALL_LOG" | tr -d ' ')"
assert_eq "GitLab both dims: exactly ONE base-MR-view call" "1" "$(wc -l < "$GL_API_CALL_LOG" | tr -d ' ')"

# TC-OVERREACH-011: LINES cap unset → dimensions_needed never includes lines,
# so chp_pr_diffstat is never invoked with it at all — asserted at the
# lib-review-diffcap.sh level (test-lib-review-diffcap.sh), not here; this
# leaf-level test confirms files-only truly issues zero GraphQL calls (008).

# TC-OVERREACH-012: GraphQL failure → FILES dimension unaffected.
GL_GRAPHQL_FAIL=1
: > "$GL_API_CALL_LOG"
out_gl_gqlfail=$(chp_gitlab_pr_diffstat 42 files,lines 2>/dev/null); rc_gqlfail=$?
GL_GRAPHQL_FAIL=0
assert_eq "GraphQL failure: leaf still rc 0 (FILES answered)" "0" "$rc_gqlfail"
assert_eq "GraphQL failure: changed_files still present" "45" "$(jq -r '.changed_files' <<<"$out_gl_gqlfail")"
assert_eq "GraphQL failure: changed_lines OMITTED (not fabricated)" "null" "$(jq -r '.changed_lines // "null"' <<<"$out_gl_gqlfail")"

# Base MR view failure → hard failure, no partial output.
GL_API_FAIL=1
out_gl_apifail=$(chp_gitlab_pr_diffstat 42 files 2>/dev/null); rc_apifail=$?
GL_API_FAIL=0
assert_rc_nz "base MR view failure → leaf rc≠0" "$rc_apifail"
assert_eq "base MR view failure → no partial stdout" "" "$out_gl_apifail"

# Positional validation.
chp_gitlab_pr_diffstat "" files >/dev/null 2>&1; assert_eq "GitLab: empty PR → rc 2" "2" "$?"
chp_gitlab_pr_diffstat 42 "" >/dev/null 2>&1; assert_eq "GitLab: empty DIMENSIONS-CSV → rc 2" "2" "$?"
chp_gitlab_pr_diffstat 42 bogus >/dev/null 2>&1; assert_eq "GitLab: unrecognized dimension → rc 2" "2" "$?"

# ===========================================================================
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
