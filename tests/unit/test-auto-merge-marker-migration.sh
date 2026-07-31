#!/bin/bash
# test-auto-merge-marker-migration.sh — issue #332 (#296 second-tier).
#
# autonomous-dev.sh builds `AUTO_MERGE_FAILURE_MARKER` before mode selection
# from normalized PR/MR comments and the current full PR HEAD. When present it
# prepends a mandatory rebase block to new, resume, and resume-fallback prompts.
#
# Issue #540 moves that read to the CHP PR surface so GitHub PR comments and
# GitLab MR notes use the same provider-neutral source:
#
#   _dev_pr_comments=$(chp_pr_view "$PR_NUM" "comments")
#   AUTO_MERGE_FAILURE_MARKER=$(jq -r
#     '[.comments[] | select(.body | startswith("Auto-merge failed:"))] | last // empty | .body'
#     <<<"$_dev_pr_comments")
#
# Two strategies, like test-resume-review-comments-filter.sh:
#   (1) extract the live multiline `jq -r '<EXPR>'` selector from the wrapper
#       and run it against synthetic normalized CHP comment fixtures;
#   (2) source-shape grep guards — the raw `gh api` site is gone, the
#       validated `chp_pr_view` + jq form is present once, and the selector is
#       `startswith` (literal, engine-agnostic), not `test()`.
#
# Run: env -u PROJECT_DIR bash tests/unit/test-auto-merge-marker-migration.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEV_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
DISPOSITION_LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-review-disposition.sh"
BASELINE="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/cutover-baseline.json"
CHECK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/check-provider-cutover.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

if [[ ! -f "$DISPOSITION_LIB" ]]; then
  echo -e "${RED}FATAL${NC}: shared recovery-marker contract missing: $DISPOSITION_LIB"
  exit 2
fi
# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-review-disposition.sh
source "$DISPOSITION_LIB"

# Run the selector against the normalized CHP `{comments:[...]}` shape and
# return the selected body (or "" if empty).
run_selector() {
  local fixture_json="$1"
  _review_pr_recovery_comment_from_comments \
    "$fixture_json" 540 "$HEAD_A" any 2>/dev/null
}

# mk_comment "<iso-timestamp>" "<body>" — a single normalized-array element.
mk_comment() {
  local ts="$1" body="$2"
  jq -n --arg ts "$ts" --arg body "$body" \
    '{id: 1, author: "kane-review-agent", authorKind: "bot", body: $body, createdAt: $ts}'
}

assert_body_match() {
  local desc="$1" expected_substring="$2" actual_body="$3"
  if [[ -z "$actual_body" ]]; then
    if [[ "$expected_substring" == "<EMPTY>" ]]; then
      echo -e "  ${GREEN}PASS${NC}: $desc (got empty as expected)"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${NC}: $desc"
      echo "      expected to contain: '$expected_substring'"
      echo "      got: <EMPTY>"
      FAIL=$((FAIL + 1))
    fi
    return
  fi
  if [[ "$actual_body" == *"$expected_substring"* ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected to contain: '$expected_substring'"
    echo "      got: $(echo "$actual_body" | head -c 160)"
    FAIL=$((FAIL + 1))
  fi
}

HEAD_A='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
HEAD_B='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
CURRENT_CONFLICT_MARKER="<!-- auto-merge-conflict: issue=540 head=${HEAD_A} result=conflict-rebase -->"
STALE_CONFLICT_MARKER="<!-- auto-merge-conflict: issue=540 head=${HEAD_B} result=conflict-rebase -->"
CURRENT_FAILURE_MARKER="<!-- auto-merge-failure: issue=540 head=${HEAD_A} -->"
STALE_FAILURE_MARKER="<!-- auto-merge-failure: issue=540 head=${HEAD_B} -->"
MARKER_R1="Auto-merge failed: rebase required (PR is behind base by 3 commits)."$'\n'"${CURRENT_FAILURE_MARKER}"
MARKER_R2="Auto-merge failed: merge conflict in lib-dispatch.sh — please rebase."$'\n'"${CURRENT_CONFLICT_MARKER}"
DISPATCH_CHATTER='<!-- dispatcher-token: abc123 at 2026-06-30T01:00:00Z mode=review -->
Dispatching autonomous review...'

# ===================================================================
echo "=== TC-AMM-001..005: migrated selector reproduces the raw-gh-api select (AC1) ==="

# TC-AMM-001 — single Auto-merge failed: comment present → its body returned.
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' "$MARKER_R1")" '{comments:[$c1]}')
out=$(run_selector "$fixture")
assert_body_match "TC-E2E-REBASE-052 generic INV-33 marker triggers rebase recovery" "rebase required" "$out"

# TC-AMM-002 — multiple Auto-merge failed: comments → NEWEST (last) returned.
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' "$MARKER_R1")" \
  --argjson c2 "$(mk_comment '2026-06-30T02:00:00Z' "$MARKER_R2")" \
  '{comments:[$c1, $c2]}')
out=$(run_selector "$fixture")
assert_body_match "TC-AMM-002 multiple markers → newest (last) returned" "merge conflict in lib-dispatch.sh" "$out"

# TC-AMM-003 — no matching comment (only dispatcher chatter) → empty.
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' "$DISPATCH_CHATTER")" '{comments:[$c1]}')
out=$(run_selector "$fixture")
assert_body_match "TC-AMM-003 no 'Auto-merge failed:' comment → empty" "<EMPTY>" "$out"

# TC-AMM-004 — body CONTAINS but does NOT START WITH the marker (quoted history) →
# NOT matched (startswith anchor — the quoted-history false-positive guard).
QUOTED_HISTORY='Resuming work. Prior status was:

> Auto-merge failed: rebase required (PR is behind base).

Continuing.'
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' "$QUOTED_HISTORY")" '{comments:[$c1]}')
out=$(run_selector "$fixture")
assert_body_match "TC-AMM-004 quoted-history 'Auto-merge failed:' mid-body → NOT matched (startswith anchor)" "<EMPTY>" "$out"

# TC-AMM-005 — older marker, then a newer NON-matching status → marker still returned
# (the non-matching newer comment doesn't shadow the marker; last // empty over
# the SELECTED subset, not over all comments).
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' "$MARKER_R1")" \
  --argjson c2 "$(mk_comment '2026-06-30T02:00:00Z' "$DISPATCH_CHATTER")" \
  '{comments:[$c1, $c2]}')
out=$(run_selector "$fixture")
assert_body_match "TC-AMM-005 newer non-matching status does not shadow the marker" "rebase required" "$out"

# TC-AMM-006 — an old HEAD's conflict marker must not trigger another rebase.
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' \
  "Auto-merge failed: old conflict.${STALE_CONFLICT_MARKER}")" '{comments:[$c1]}')
out=$(run_selector "$fixture")
assert_body_match "TC-AMM-006 stale HEAD-bound marker is ignored" "<EMPTY>" "$out"

# TC-AMM-007 — an old HEAD's generic INV-33 marker is also ignored.
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' \
  "Auto-merge failed: old merge attempt.${STALE_FAILURE_MARKER}")" '{comments:[$c1]}')
out=$(run_selector "$fixture")
assert_body_match "TC-E2E-REBASE-053 stale generic auto-merge marker is ignored" "<EMPTY>" "$out"

# TC-AMM-008 — preserve the pre-#540 generic INV-33 prefix while canonical
# hidden markers use strict current-HEAD matching.
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' \
  "Auto-merge failed: please rebase this branch")" '{comments:[$c1]}')
out=$(run_selector "$fixture")
assert_body_match "TC-E2E-REBASE-053 legacy generic INV-33 prefix remains compatible" \
  "please rebase this branch" "$out"

# TC-AMM-009 — quoted current-HEAD evidence is not a canonical producer body.
QUOTED_CURRENT="Status update:

> Auto-merge failed: retry merge.
> ${CURRENT_FAILURE_MARKER}"
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' \
  "$QUOTED_CURRENT")" '{comments:[$c1]}')
out=$(run_selector "$fixture")
assert_body_match "TC-E2E-REBASE-053 quoted current-HEAD marker is ignored" "<EMPTY>" "$out"

# TC-AMM-010 — abbreviated and wrong-issue generic markers are not current evidence.
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' \
    'Auto-merge failed: abbreviated.<!-- auto-merge-failure: issue=540 head=aaaaaaa -->')" \
  --argjson c2 "$(mk_comment '2026-06-30T02:00:00Z' \
    "Auto-merge failed: wrong issue.<!-- auto-merge-failure: issue=541 head=${HEAD_A} -->")" \
  '{comments:[$c1, $c2]}')
out=$(run_selector "$fixture")
assert_body_match "TC-E2E-REBASE-053 abbreviated and wrong-issue markers are ignored" "<EMPTY>" "$out"

# TC-AMM-011 — an otherwise exact marker with a terminal newline is not the
# exact final line and must not be treated as canonical evidence.
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-30T03:00:00Z' \
  "Auto-merge failed: newline spoof"$'\n'"${CURRENT_FAILURE_MARKER}"$'\n')" \
  '{comments:[$c1]}')
out=$(run_selector "$fixture")
assert_body_match "TC-E2E-REBASE-053 terminal-newline canonical lookalike is ignored" \
  "<EMPTY>" "$out"

# TC-AMM-012 — case-variant marker syntax is still a lookalike and may not fall
# through to marker-free legacy compatibility.
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-30T03:01:00Z' \
  "Auto-merge failed: malformed case"$'\n'"<!-- AUTO-MERGE-FAILURE: issue=540 head=${HEAD_A} -->")" \
  '{comments:[$c1]}')
out=$(run_selector "$fixture")
assert_body_match "TC-E2E-REBASE-053 case-variant marker lookalike is ignored" \
  "<EMPTY>" "$out"

# ===================================================================
echo
echo "=== TC-AMM-PARITY-001..002: no engine divergence — startswith is literal (AC2) ==="

# TC-AMM-PARITY-001 — a body carrying non-ASCII + a test()-style metacharacter is
# matched purely by the literal startswith prefix and returned verbatim. A
# `test()`-based selector would treat `\b`/`(?i)` as regex and could diverge under
# Oniguruma; startswith is literal and engine-agnostic.
META_MARKER="Auto-merge failed: rebase onto 中 \\b(?i) [P1] — literal body, no fold."$'\n'"${CURRENT_FAILURE_MARKER}"
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' "$META_MARKER")" '{comments:[$c1]}')
out=$(run_selector "$fixture")
assert_body_match "TC-AMM-PARITY-001 non-ASCII + metachar body matched literally (startswith, no Oniguruma fold)" "rebase onto 中 \\b(?i) [P1]" "$out"

# TC-AMM-PARITY-002 — the shared parser uses literal startswith/contains
# operations and does not invoke test().
parser_source=$(declare -f _review_pr_recovery_comment_from_comments)
if [[ "$parser_source" == *'startswith("Auto-merge failed:")'* \
      && "$parser_source" != *'test('* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AMM-PARITY-002 shared parser uses literal operations, no test()/regex"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AMM-PARITY-002 shared parser regressed to regex matching"
  FAIL=$((FAIL + 1))
fi

# ===================================================================
echo
echo "=== TC-AMM-SRC-001..003: source-shape — raw gh gone, verb form present, baseline -1 (AC3) ==="

# TC-AMM-SRC-001 — the raw `gh api …/issues/${PR_NUM}/comments` auto-merge-marker
# read is GONE from the wrapper.
if grep -qE 'AUTO_MERGE_FAILURE_MARKER=\$\(gh api "repos/\$\{REPO\}/issues/\$\{PR_NUM\}/comments"' "$DEV_WRAPPER"; then
  echo -e "  ${RED}FAIL${NC}: TC-AMM-SRC-001 raw 'gh api …/issues/\${PR_NUM}/comments' auto-merge-marker read survives — not migrated"
  grep -nE 'AUTO_MERGE_FAILURE_MARKER=\$\(gh api' "$DEV_WRAPPER" | sed 's/^/      /'
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-AMM-SRC-001 raw 'gh api …/issues/\${PR_NUM}/comments' auto-merge-marker read removed"
  PASS=$((PASS + 1))
fi

# TC-AMM-SRC-002 — the provider-neutral read and shared parser call are each
# present exactly once.
_read_count=$(grep -cE '_dev_pr_comments=\$\(chp_pr_view "\$PR_NUM" "comments" 2>/dev/null' "$DEV_WRAPPER")
_select_count=$(grep -cE '_review_pr_recovery_comment_from_comments' "$DEV_WRAPPER")
if [[ "$_read_count" -eq 1 && "$_select_count" -eq 1 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AMM-SRC-002 provider-neutral comment read and shared parser call are each present once"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AMM-SRC-002 read=$_read_count selector=$_select_count (expected 1 each)"
  FAIL=$((FAIL + 1))
fi

if [[ "$parser_source" == *'_review_auto_merge_conflict_marker'* \
      && "$parser_source" == *'_review_auto_merge_failure_marker'* \
      && "$parser_source" == *'ascii_downcase'* \
      && "$parser_source" == *'auto-merge-conflict'* \
      && "$parser_source" == *'auto-merge-failure'* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AMM-SRC-002b shared parser owns both current-HEAD contracts and guarded legacy fallback"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AMM-SRC-002b shared parser contract is incomplete"
  FAIL=$((FAIL + 1))
fi

# TC-AMM-SRC-003 — the baselined raw-gh entry is GONE (baseline -1) and the
# cutover guard ([INV-91]) PASSES.
if grep -Fq 'AUTO_MERGE_FAILURE_MARKER=$(gh api \"repos/${REPO}/issues/${PR_NUM}/comments\"' "$BASELINE"; then
  echo -e "  ${RED}FAIL${NC}: TC-AMM-SRC-003 cutover-baseline.json still carries the auto-merge-marker raw-gh entry (must shrink -1)"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-AMM-SRC-003 cutover-baseline.json no longer carries the auto-merge-marker raw-gh entry (baseline -1)"
  PASS=$((PASS + 1))
fi

if bash "$CHECK" >/dev/null 2>&1; then
  echo -e "  ${GREEN}PASS${NC}: TC-AMM-SRC-003b check-provider-cutover.sh ([INV-91]) PASSES (baseline reconciles with HEAD)"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AMM-SRC-003b check-provider-cutover.sh ([INV-91]) FAILS — baseline/HEAD reconciliation broken"
  bash "$CHECK" 2>&1 | tail -8 | sed 's/^/      /'
  FAIL=$((FAIL + 1))
fi

# Bash syntax check on the modified wrapper.
echo
echo "=== TC-AMM-syntax: wrapper passes bash -n ==="
if bash -n "$DEV_WRAPPER" 2>/dev/null; then
  echo -e "  ${GREEN}PASS${NC}: wrapper passes bash -n"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: wrapper has syntax errors"
  FAIL=$((FAIL + 1))
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
