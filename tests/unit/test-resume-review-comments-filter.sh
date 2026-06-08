#!/bin/bash
# test-resume-review-comments-filter.sh — Regression for issue #113.
#
# autonomous-dev.sh::resume builds a `REVIEW_COMMENTS` shell variable from
# the most recent issue comment matching a jq filter; the prior filter
# `contains("Review findings") or contains("review")` substring-matched
# the literal `review` against every comment body, including dispatcher
# status comments like "Dispatching autonomous review" / "Moving to
# pending-review for retry" / "no new commits since last review at
# <sha>". When such a status comment landed AFTER a real
# review-findings comment, `| last` returned the status — the dev agent
# then resumed with dispatcher chatter as its `## Review Feedback`.
#
# This test extracts the jq selector body and runs it against synthetic
# `comments` fixtures that mirror real dispatcher message shapes.
#
# Run: bash tests/unit/test-resume-review-comments-filter.sh

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEV_WRAPPER="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/autonomous-dev.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Extract the jq filter expression from the wrapper. The wrapper
# constructs REVIEW_COMMENTS via:
#
#   REVIEW_COMMENTS=$(gh issue view ... --json comments -q '<EXPR>')
#
# We pull the EXPR literal and run it against synthetic fixtures. This
# couples the test to the wrapper's chosen filter, which is exactly
# what we want — the test breaks if the filter regresses.
extract_filter() {
  awk '
    /REVIEW_COMMENTS=\$\(gh issue view/ { in_block=1 }
    in_block && /-q / {
      # Capture the single-quoted jq expression on the -q line.
      match($0, /-q '\''([^'\'']+)'\''/, a)
      if (a[1] != "") { print a[1]; exit }
    }
  ' "$DEV_WRAPPER"
}

JQ_FILTER=$(extract_filter)
if [[ -z "$JQ_FILTER" ]]; then
  echo -e "${RED}FATAL${NC}: could not extract REVIEW_COMMENTS jq filter from $DEV_WRAPPER"
  exit 2
fi

echo "Extracted filter: $JQ_FILTER"
echo

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

# Run the filter against a comments JSON array, return the body of the
# selected comment (or "" if empty).
run_filter() {
  local comments_json="$1"
  local result
  # Wrap result through .body if jq returned an object.
  result=$(jq -r "$JQ_FILTER | if type == \"object\" then .body else . end // \"\"" \
    <<<"$comments_json" 2>/dev/null)
  printf '%s' "$result"
}

# Fixture builders — using real dispatcher comment bodies from the wild.
mk_comment() {
  # mk_comment "<iso-timestamp>" "<body-with-quotes-escaped>"
  local ts="$1" body="$2"
  jq -n --arg ts "$ts" --arg body "$body" \
    '{createdAt: $ts, body: $body}'
}

# Real dispatcher comment templates copied from #204 / #37 timelines.
DISPATCH_REVIEW_TOKEN="<!-- dispatcher-token: abc123 at 2026-05-14T01:23:45Z mode=review -->
Dispatching autonomous review..."
# Real dev-wrapper trap message for the "exit 0 + PR present" path —
# contains literal lowercase 'pending-review' which substring-matches
# the buggy 'or contains(\"review\")' clause.
MOVING_PENDING_REVIEW="Dev process exited (PR found). Moving to pending-review for assessment."
DEV_NO_COMMITS="Dev process exited (no new commits since last review at \`abc1234\`). Moving to pending-dev for retry."
REAL_FINDINGS_R1='Review findings:

[BLOCKING] Missing input validation in `submitFeed`.
[BLOCKING] DynamoDB TTL not configured on the new artifacts table.

session: 11111111-1111-1111-1111-111111111111'
REAL_FINDINGS_R2='Review findings:

[BLOCKING] Round 2: regression on the cancel endpoint.

session: 22222222-2222-2222-2222-222222222222'
REAL_PASSED='Review PASSED - All checklist items verified, code quality good.

session: 33333333-3333-3333-3333-333333333333'

# ===================================================================
echo "=== TC-RFB-001..008: REVIEW_COMMENTS filter regression ==="

# TC-RFB-001 — only real review findings present, must pick it
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-05-14T01:00:00Z' "$REAL_FINDINGS_R1")" \
  '{comments: [$c1]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-001 only real findings → picked" "[BLOCKING] Missing input validation" "$out"

# TC-RFB-002 — real findings, then "Moving to pending-review for retry" later
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-05-14T01:00:00Z' "$REAL_FINDINGS_R1")" \
  --argjson c2 "$(mk_comment '2026-05-14T01:30:00Z' "$MOVING_PENDING_REVIEW")" \
  '{comments: [$c1, $c2]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-002 real findings preferred over 'Moving to pending-review' status" "[BLOCKING] Missing input validation" "$out"

# TC-RFB-003 — real findings, then "Dispatching autonomous review..." later
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-05-14T01:00:00Z' "$REAL_FINDINGS_R1")" \
  --argjson c2 "$(mk_comment '2026-05-14T01:30:00Z' "$DISPATCH_REVIEW_TOKEN")" \
  '{comments: [$c1, $c2]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-003 real findings preferred over 'Dispatching autonomous review' status" "[BLOCKING] Missing input validation" "$out"

# TC-RFB-004 — real findings, then "no new commits since last review at <sha>" later
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-05-14T01:00:00Z' "$REAL_FINDINGS_R1")" \
  --argjson c2 "$(mk_comment '2026-05-14T01:30:00Z' "$DEV_NO_COMMITS")" \
  '{comments: [$c1, $c2]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-004 real findings preferred over 'no new commits since last review' status" "[BLOCKING] Missing input validation" "$out"

# TC-RFB-005 — only Review PASSED present, must pick it
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-05-14T01:00:00Z' "$REAL_PASSED")" \
  '{comments: [$c1]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-005 'Review PASSED' picked when no findings exist" "Review PASSED" "$out"

# TC-RFB-006 — no review comment at all (fresh issue, only dispatcher chatter)
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-05-14T00:30:00Z' "Dispatching autonomous development...")" \
  --argjson c2 "$(mk_comment '2026-05-14T00:35:00Z' "Resuming autonomous development...")" \
  '{comments: [$c1, $c2]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-006 no review comment → empty" "<EMPTY>" "$out"

# TC-RFB-007 — multiple real review rounds, last wins
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-05-14T01:00:00Z' "$REAL_FINDINGS_R1")" \
  --argjson c2 "$(mk_comment '2026-05-14T02:00:00Z' "$REAL_FINDINGS_R2")" \
  '{comments: [$c1, $c2]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-007 multiple findings rounds → last wins" "Round 2: regression" "$out"

# TC-RFB-008 — real findings, then a comment that merely MENTIONS "review" mid-sentence
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-05-14T01:00:00Z' "$REAL_FINDINGS_R1")" \
  --argjson c2 "$(mk_comment '2026-05-14T01:30:00Z' "Owner: please re-trigger review on this PR when ready")" \
  '{comments: [$c1, $c2]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-008 mid-sentence 'review' mention does not shadow real findings" "[BLOCKING] Missing input validation" "$out"

# ===================================================================
# Issue #188 (INV-57) — broadened findings recognition. The selector must
# also catch change-request comments that DON'T start with the exact
# `Review findings` prefix but carry a BLOCKING / [P1] token, so a late
# operator/secondary findings comment posted after an approval isn't
# silently dropped. The broadened clause must NOT regress the #113
# dispatcher-chatter exclusion (those bodies carry no BLOCKING/[P1]).
echo
echo "=== TC-RFB-009..011: broadened findings recognition (issue #188) ==="

# Non-prefix findings: a heading like "## Codex review findings" + [P1].
NONPREFIX_FINDINGS='## Codex review findings

[P1] BLOCKING: the new artifacts table has no TTL configured.'
# Bare operator note carrying [P1] BLOCKING, no `findings`/`review` heading.
OPERATOR_NOTE='[P1] BLOCKING: data race in submitFeed — please fix before merge'

# TC-RFB-009 — non-prefix "## Codex review findings" + [P1] is recognized
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-08T08:00:00Z' "$NONPREFIX_FINDINGS")" \
  '{comments: [$c1]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-009 non-prefix '## Codex review findings' + [P1] recognized" "no TTL configured" "$out"

# TC-RFB-010 — bare operator [P1] BLOCKING note is recognized
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-08T08:00:00Z' "$OPERATOR_NOTE")" \
  '{comments: [$c1]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-010 bare '[P1] BLOCKING' operator note recognized" "data race in submitFeed" "$out"

# TC-RFB-011 — broadened clause must NOT pull a plain dispatcher status (no token)
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-06-08T07:00:00Z' "$REAL_FINDINGS_R1")" \
  --argjson c2 "$(mk_comment '2026-06-08T07:30:00Z' "$MOVING_PENDING_REVIEW")" \
  '{comments: [$c1, $c2]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-011 broadened clause does not pull token-free dispatcher status" "[BLOCKING] Missing input validation" "$out"

# TC-RFB-012 — a NON-BLOCKING note must NOT match (the \b boundary on the hyphen
# would make a naive \bBLOCKING\b false-match `NON-BLOCKING`). Here a real
# findings comment is followed by a later "remaining items NON-BLOCKING" note:
# the note must NOT shadow the real findings.
NON_BLOCKING_NOTE='Remaining items are NON-BLOCKING — safe to merge once CI is green.'
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-06-08T07:00:00Z' "$REAL_FINDINGS_R1")" \
  --argjson c2 "$(mk_comment '2026-06-08T07:30:00Z' "$NON_BLOCKING_NOTE")" \
  '{comments: [$c1, $c2]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-012 'NON-BLOCKING' note does not match (look-behind rejects hyphen)" "[BLOCKING] Missing input validation" "$out"

# TC-RFB-013 — a sole NON-BLOCKING note (no real findings) yields empty, NOT a match
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-08T08:00:00Z' "$NON_BLOCKING_NOTE")" \
  '{comments: [$c1]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-013 sole 'NON-BLOCKING' note → empty (not a finding)" "<EMPTY>" "$out"

# ===================================================================
# Issue #188 review round 1 (codex finding 2) — the token fallback must NOT
# classify a `Review PASSED` verdict or a dev status/session comment as a
# finding just because the body contains a BLOCKING / [P1] token in prose.
echo
echo "=== TC-RFB-014..016: token fallback excludes PASS + status comments (issue #188 review) ==="

# A PASS verdict that happens to contain the BLOCKING token.
PASSED_WITH_TOKEN='Review PASSED - No BLOCKING issues remain. LGTM.

session: 44444444-4444-4444-4444-444444444444'
# A dev implementation/status comment mentioning the tokens in prose.
IMPL_STATUS='## ✅ Implementation complete — PR #204

Fixed the short-circuit. Addresses [P1] BLOCKING data-correctness items.'
# An Agent Session Report mentioning the tokens.
SESSION_REPORT='**Agent Session Report (Dev)**

Exit code: 0. Resolved [P1] BLOCKING items per review.'

# TC-RFB-014 — real findings, then a later `Review PASSED - No BLOCKING issues remain`.
# `Review PASSED` is still recognized (PASS prefix clause), so it legitimately wins
# as the latest verdict — but it must be the PASS body, NOT misclassified, and the
# real findings must not be lost when the PASS does NOT post-date them.
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-06-08T07:00:00Z' "$REAL_FINDINGS_R1")" \
  --argjson c2 "$(mk_comment '2026-06-08T08:00:00Z' "$PASSED_WITH_TOKEN")" \
  '{comments: [$c1, $c2]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-014 'Review PASSED - No BLOCKING' is the PASS verdict (latest), not a finding" "No BLOCKING issues remain" "$out"

# TC-RFB-015 — real findings, then a dev impl/status comment with tokens in prose.
# The status comment must NOT shadow the real findings.
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-06-08T07:00:00Z' "$REAL_FINDINGS_R1")" \
  --argjson c2 "$(mk_comment '2026-06-08T07:30:00Z' "$IMPL_STATUS")" \
  '{comments: [$c1, $c2]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-015 dev impl/status comment with tokens does not shadow real findings" "[BLOCKING] Missing input validation" "$out"

# TC-RFB-016 — sole Agent Session Report with tokens → empty (not a finding).
fixture=$(jq -n --argjson c1 "$(mk_comment '2026-06-08T08:00:00Z' "$SESSION_REPORT")" \
  '{comments: [$c1]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-016 sole Agent Session Report with tokens → empty (status, not finding)" "<EMPTY>" "$out"

# ===================================================================
# TC-RFB-017 — drift guard: the non-findings EXCLUSION alternation appears in
# BOTH the `REVIEW_COMMENTS` selector AND `emit_post_approval_findings_block`'s
# findings query. They MUST stay byte-identical — a token added to one list but
# not the other would silently desync the prompt's recognition from the
# override's recognition, reintroducing the issue-#188 finding-2 false-match on
# one path. The single-line-on-`-q` constraint blocks DRY-ing them into a shared
# var, so this test mechanically asserts they match.
echo
echo "=== TC-RFB-017: exclusion alternation is identical across both selectors ==="
# Pull every `^\s*( … )` exclusion alternation literal from the wrapper's -q
# lines. `sort -u` collapses identical occurrences; the count of DISTINCT
# variants must be exactly 1 (both call sites byte-identical), and the raw
# count must be >= 2 (the literal really appears at both sites — guard not
# vacuous). Uses wc/grep only (no `mapfile`) so it is shell-agnostic.
_distinct=$(grep -oE '\^\\\\s\*\([^)]*\)' "$DEV_WRAPPER" | sort -u | wc -l | tr -dc '0-9')
_total=$(grep -cE '\^\\\\s\*\(Review PASSED' "$DEV_WRAPPER")
if [[ "$_distinct" -eq 1 && "$_total" -ge 2 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-RFB-017 exclusion alternation identical at both call sites (distinct=$_distinct, occurrences=$_total)"
  PASS=$((PASS + 1))
elif [[ "$_distinct" -ne 1 ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-RFB-017 exclusion alternation DRIFTED — $_distinct distinct variants (expected 1):"
  grep -oE '\^\\\\s\*\([^)]*\)' "$DEV_WRAPPER" | sort -u | sed 's/^/      /'
  FAIL=$((FAIL + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RFB-017 exclusion alternation found <2 times (occurrences=$_total) — wiring changed?"
  FAIL=$((FAIL + 1))
fi

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
