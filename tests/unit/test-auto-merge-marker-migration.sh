#!/bin/bash
# test-auto-merge-marker-migration.sh — issue #332 (#296 second-tier).
#
# autonomous-dev.sh::resume builds `AUTO_MERGE_FAILURE_MARKER` from the PR's
# issue-level comments to detect the review wrapper's auto-merge-failure marker
# (#145 / [INV-33]) and, when present, prepend a mandatory rebase block to the
# resume prompt.
#
# This issue migrates that read from a raw `gh api .../issues/${PR_NUM}/comments`
# call to the SHIPPED `itp_list_comments` verb — no new verb, shape-equivalent
# (#315 precedent):
#
#   AUTO_MERGE_FAILURE_MARKER=$(itp_list_comments "$PR_NUM" 2>/dev/null \
#     | jq -r '[.[] | select(.body | startswith("Auto-merge failed:"))] | last // empty | .body' 2>/dev/null || true)
#
# Two strategies, like test-resume-review-comments-filter.sh:
#   (1) extract the live `jq -r '<EXPR>'` selector from the wrapper and run it
#       against synthetic NORMALIZED [INV-90] array fixtures — proves the migrated
#       selector reproduces the raw-`gh-api` select for every golden case;
#   (2) source-shape grep guards — the raw `gh api` site is gone, the
#       `itp_list_comments | jq` form is present exactly once, and the selector is
#       `startswith` (literal, engine-agnostic), not `test()`.
#
# Run: env -u PROJECT_DIR bash tests/unit/test-auto-merge-marker-migration.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEV_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"
BASELINE="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/providers/cutover-baseline.json"
CHECK="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/check-provider-cutover.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Extract the jq selector following the migrated AUTO_MERGE_FAILURE_MARKER
# assignment. Post-#332 the wrapper constructs it via:
#
#   AUTO_MERGE_FAILURE_MARKER=$(itp_list_comments "$PR_NUM" 2>/dev/null \
#     | jq -r '<EXPR>' 2>/dev/null || true)
#
# The `itp_list_comments … | jq -r '<EXPR>'` spans a leading line ending in a
# backslash continuation and a continuation line carrying the `jq -r '…'`. We pull
# the single-quoted jq expression following `jq -r ` anywhere in the wrapper that
# is the auto-merge-marker selector (anchored on the `Auto-merge failed:` literal).
extract_selector() {
  awk '
    /jq -r .*startswith\("Auto-merge failed:"\)/ {
      match($0, /jq -r '\''([^'\'']+)'\''/, a)
      if (a[1] != "") { print a[1]; exit }
    }
  ' "$DEV_WRAPPER"
}

JQ_SELECTOR=$(extract_selector)
if [[ -z "$JQ_SELECTOR" ]]; then
  echo -e "${RED}FATAL${NC}: could not extract AUTO_MERGE_FAILURE_MARKER jq selector from $DEV_WRAPPER"
  echo "  (the migrated 'itp_list_comments … | jq -r '\''…startswith(\"Auto-merge failed:\")…'\''' form is absent)"
  exit 2
fi

echo "Extracted selector: $JQ_SELECTOR"
echo

# Run the migrated selector against a NORMALIZED [INV-90] array fixture (already a
# flat array, ascending by createdAt — exactly what itp_list_comments emits) and
# return the selected body (or "" if empty).
run_selector() {
  local fixture_json="$1"
  jq -r "($JQ_SELECTOR)" <<<"$fixture_json" 2>/dev/null
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

MARKER_R1='Auto-merge failed: rebase required (PR is behind base by 3 commits).'
MARKER_R2='Auto-merge failed: merge conflict in lib-dispatch.sh — please rebase.'
DISPATCH_CHATTER='<!-- dispatcher-token: abc123 at 2026-06-30T01:00:00Z mode=review -->
Dispatching autonomous review...'

# ===================================================================
echo "=== TC-AMM-001..005: migrated selector reproduces the raw-gh-api select (AC1) ==="

# TC-AMM-001 — single Auto-merge failed: comment present → its body returned.
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' "$MARKER_R1")" '[$c1]')
out=$(run_selector "$fixture")
assert_body_match "TC-AMM-001 single 'Auto-merge failed:' comment → body returned" "rebase required" "$out"

# TC-AMM-002 — multiple Auto-merge failed: comments → NEWEST (last) returned.
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' "$MARKER_R1")" \
  --argjson c2 "$(mk_comment '2026-06-30T02:00:00Z' "$MARKER_R2")" \
  '[$c1, $c2]')
out=$(run_selector "$fixture")
assert_body_match "TC-AMM-002 multiple markers → newest (last) returned" "merge conflict in lib-dispatch.sh" "$out"

# TC-AMM-003 — no matching comment (only dispatcher chatter) → empty.
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' "$DISPATCH_CHATTER")" '[$c1]')
out=$(run_selector "$fixture")
assert_body_match "TC-AMM-003 no 'Auto-merge failed:' comment → empty" "<EMPTY>" "$out"

# TC-AMM-004 — body CONTAINS but does NOT START WITH the marker (quoted history) →
# NOT matched (startswith anchor — the quoted-history false-positive guard).
QUOTED_HISTORY='Resuming work. Prior status was:

> Auto-merge failed: rebase required (PR is behind base).

Continuing.'
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' "$QUOTED_HISTORY")" '[$c1]')
out=$(run_selector "$fixture")
assert_body_match "TC-AMM-004 quoted-history 'Auto-merge failed:' mid-body → NOT matched (startswith anchor)" "<EMPTY>" "$out"

# TC-AMM-005 — older marker, then a newer NON-matching status → marker still returned
# (the non-matching newer comment doesn't shadow the marker; last // empty over
# the SELECTED subset, not over all comments).
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' "$MARKER_R1")" \
  --argjson c2 "$(mk_comment '2026-06-30T02:00:00Z' "$DISPATCH_CHATTER")" \
  '[$c1, $c2]')
out=$(run_selector "$fixture")
assert_body_match "TC-AMM-005 newer non-matching status does not shadow the marker" "rebase required" "$out"

# ===================================================================
echo
echo "=== TC-AMM-PARITY-001..002: no engine divergence — startswith is literal (AC2) ==="

# TC-AMM-PARITY-001 — a body carrying non-ASCII + a test()-style metacharacter is
# matched purely by the literal startswith prefix and returned verbatim. A
# `test()`-based selector would treat `\b`/`(?i)` as regex and could diverge under
# Oniguruma; startswith is literal and engine-agnostic.
META_MARKER='Auto-merge failed: rebase onto 中 \b(?i) [P1] — literal body, no fold'
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-30T01:00:00Z' "$META_MARKER")" '[$c1]')
out=$(run_selector "$fixture")
assert_body_match "TC-AMM-PARITY-001 non-ASCII + metachar body matched literally (startswith, no Oniguruma fold)" "rebase onto 中 \\b(?i) [P1]" "$out"

# TC-AMM-PARITY-002 — the live selector uses startswith and does NOT invoke test().
if [[ "$JQ_SELECTOR" == *'startswith("Auto-merge failed:")'* && "$JQ_SELECTOR" != *'test('* ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AMM-PARITY-002 selector is startswith (literal), no test()/regex — no engine divergence"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AMM-PARITY-002 selector regressed (must be startswith, never test()): $JQ_SELECTOR"
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

# TC-AMM-SRC-002 — the migrated itp_list_comments form is present EXACTLY ONCE
# (live-site non-vacuity; couples the test to the real wrapper assignment).
_live_count=$(grep -cE 'AUTO_MERGE_FAILURE_MARKER=\$\(itp_list_comments "\$PR_NUM" 2>/dev/null' "$DEV_WRAPPER")
if [[ "$_live_count" -eq 1 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-AMM-SRC-002 migrated 'itp_list_comments \"\$PR_NUM\"' marker assignment present exactly once"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-AMM-SRC-002 migrated marker assignment found $_live_count times (expected 1)"
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
