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
# comment fixtures that mirror real dispatcher message shapes.
#
# Issue #296 B6: the read migrated from raw `gh issue view --json comments -q '…'`
# to `itp_list_comments "$ISSUE" | jq -r '…'`. Two consequences this test now
# encodes: (1) the selector iterates the NORMALIZED [INV-90] array `.[]`, so the
# fixtures are fed as the flat array (the `{comments:[…]}` fixtures are unwrapped
# to `.comments` before the selector runs — mirroring itp_list_comments' output);
# (2) the jq runs under the SYSTEM jq's Oniguruma engine (the same jq this test
# invokes), and the `\b`/`\s`/`(?i)` constructs were rewritten to explicit ASCII
# forms so selection is identical to the old Go-RE2 behavior. The new
# engine-divergence fixtures (TC-DIV-*) and the same-second-tie fixture
# (TC-RFB-TIE) prove that.
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

# Extract the jq filter expression from the wrapper. Post-#296-B6 the wrapper
# constructs REVIEW_COMMENTS via:
#
#   REVIEW_COMMENTS=$(itp_list_comments "$ISSUE_NUMBER" 2>/dev/null | jq -r '<EXPR>')
#
# We pull the EXPR literal (the text inside `jq -r '…'`) and run it against
# synthetic fixtures. This couples the test to the wrapper's chosen filter, which
# is exactly what we want — the test breaks if the filter regresses.
extract_filter() {
  awk '
    /REVIEW_COMMENTS=\$\(itp_list_comments/ {
      # The whole `itp_list_comments … | jq -r '\''<EXPR>'\''` is on ONE line now.
      # Capture the single-quoted jq expression following `jq -r `.
      match($0, /jq -r '\''([^'\'']+)'\''/, a)
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

# ── Non-vacuity / unique-live-site guard (issue #296 B6, false-green hazard) ──
# The extracted selector MUST be non-empty (asserted above) AND match the live
# migrated REVIEW_COMMENTS assignment EXACTLY ONCE — so the test is provably
# exercising the real wrapper selector, not a stale or duplicated pattern. Use a
# fixed-string grep of the full `itp_list_comments … | jq -r '<EXPR>'` line.
_live_line="REVIEW_COMMENTS=\$(itp_list_comments \"\$ISSUE_NUMBER\" 2>/dev/null | jq -r '${JQ_FILTER}')"
_live_count=$(grep -Fc -- "$_live_line" "$DEV_WRAPPER")
if [[ "$_live_count" -eq 1 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-RFB-LIVE extracted selector matches the live migrated REVIEW_COMMENTS assignment exactly once"
  PASS=$((PASS + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RFB-LIVE extracted selector matched the live assignment $_live_count times (expected 1)"
  FAIL=$((FAIL + 1))
fi

# ── Static guard: the OLD raw `gh issue view … --json comments -q` sites are GONE.
# Both resume comment-reads must route through itp_list_comments now.
if grep -qE 'gh issue view "\$(ISSUE_NUMBER|issue_num)" --repo "\$REPO" --json comments' "$DEV_WRAPPER"; then
  echo -e "  ${RED}FAIL${NC}: TC-RFB-NOGH a raw 'gh issue view … --json comments' resume read survives — not migrated"
  grep -nE 'gh issue view "\$(ISSUE_NUMBER|issue_num)" --repo "\$REPO" --json comments' "$DEV_WRAPPER" | sed 's/^/      /'
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${NC}: TC-RFB-NOGH no raw 'gh issue view … --json comments' resume read remains (both behind itp_list_comments)"
  PASS=$((PASS + 1))
fi
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

# Run the filter against a fixture, return the body of the selected comment
# (or "" if empty). The migrated selector iterates the NORMALIZED [INV-90] array
# `.[]` (itp_list_comments' output), so the `{comments:[…]}` fixtures are
# unwrapped to `.comments` first; an already-flat array fixture passes through
# unchanged (`if type=="object" then .comments else . end`). This mirrors exactly
# what the wrapper feeds the selector: `itp_list_comments … | jq -r '<selector>'`.
run_filter() {
  local fixture_json="$1"
  local result
  # Unwrap {comments:[…]} → [...] (the normalized array), then apply the live
  # selector; wrap the selected element through .body if it is an object.
  result=$(jq -r "(if type == \"object\" then .comments else . end) | ($JQ_FILTER) | if type == \"object\" then .body else . end // \"\"" \
    <<<"$fixture_json" 2>/dev/null)
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
assert_body_match "TC-RFB-012 'NON-BLOCKING' note does not match (consuming anchor rejects hyphen)" "[BLOCKING] Missing input validation" "$out"

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
# Pull every `^[ \t\r\n\f]*(?i: … )` exclusion alternation literal from the
# wrapper (post-#296-B6 the leading `^\s*` was rewritten to explicit ASCII
# whitespace + a scoped `(?i:…)` so it selects identically under the system jq's
# Oniguruma engine). `sort -u` collapses identical occurrences; the count of
# DISTINCT variants must be exactly 1 (both call sites byte-identical), and the
# raw count must be >= 2 (the literal really appears at both sites — guard not
# vacuous). Uses wc/grep only (no `mapfile`) so it is shell-agnostic.
_EXCL_RE='\^\[ \\\\t\\\\r\\\\n\\\\f\]\*\(\?i:[^)]*\)'
_distinct=$(grep -oE "$_EXCL_RE" "$DEV_WRAPPER" | sort -u | wc -l | tr -dc '0-9')
_total=$(grep -cE '\^\[ \\\\t\\\\r\\\\n\\\\f\]\*\(\?i:Review PASSED' "$DEV_WRAPPER")
if [[ "$_distinct" -eq 1 && "$_total" -ge 2 ]]; then
  echo -e "  ${GREEN}PASS${NC}: TC-RFB-017 exclusion alternation identical at both call sites (distinct=$_distinct, occurrences=$_total)"
  PASS=$((PASS + 1))
elif [[ "$_distinct" -ne 1 ]]; then
  echo -e "  ${RED}FAIL${NC}: TC-RFB-017 exclusion alternation DRIFTED — $_distinct distinct variants (expected 1):"
  grep -oE "$_EXCL_RE" "$DEV_WRAPPER" | sort -u | sed 's/^/      /'
  FAIL=$((FAIL + 1))
else
  echo -e "  ${RED}FAIL${NC}: TC-RFB-017 exclusion alternation found <2 times (occurrences=$_total) — wiring changed?"
  FAIL=$((FAIL + 1))
fi

# ===================================================================
# Issue #296 B6 — ENGINE-DIVERGENCE regression fixtures (the migration proof).
# The read moved from gh's Go-RE2 jq to the system jq's Oniguruma engine. RE2 and
# Oniguruma diverge on `\b`/`\s`/`(?i)` for non-ASCII input; the selector was
# rewritten to explicit ASCII forms so it selects IDENTICALLY to the old RE2
# behavior. These fixtures run the ACTUAL migrated selector through the system
# jq (the engine the wrapper now uses) across every divergence class.
echo
echo "=== TC-DIV-*: RE2→Oniguruma engine-divergence fixtures (run via the migrated selector) ==="

NBSP=$'\xc2\xa0'          # U+00A0 NO-BREAK SPACE
KELVIN=$'\xe2\x84\xaa'    # U+212A KELVIN SIGN  (simple-folds to ASCII 'k')
LONGS=$'\xc5\xbf'         # U+017F LATIN SMALL LETTER LONG S (simple-folds to 's')
ACCENT=$'\xc3\xa9'        # U+00E9 é
CJK=$'\xe4\xb8\xad'       # U+4E2D 中

# A BLOCKING token immediately followed by a non-ASCII char: RE2's ASCII `\b`
# treats the char as a non-word boundary → the token matches. The rewritten
# explicit boundary `($|[^A-Za-z0-9_])` must replicate (the byte is not in the
# ASCII class) → SELECTED. A global `(?i)` would have leaked into the boundary
# class and EXCLUDED the simple-fold chars (K/ſ), so these are the load-bearing
# cases the round-3 scoped rewrite fixed.
fixture=$(jq -n --arg b "[BLOCKING${KELVIN}] missing validation" '{comments: [{createdAt:"2026-06-30T01:00:00Z", body:$b}]}')
out=$(run_filter "$fixture")
assert_body_match "TC-DIV-K  BLOCKING+U+212A KELVIN → SELECTED (ASCII \\b: non-word boundary)" "missing validation" "$out"

fixture=$(jq -n --arg b "[BLOCKING${LONGS}] missing validation" '{comments: [{createdAt:"2026-06-30T01:00:00Z", body:$b}]}')
out=$(run_filter "$fixture")
assert_body_match "TC-DIV-LONGS  BLOCKING+U+017F long-s → SELECTED" "missing validation" "$out"

fixture=$(jq -n --arg b "[BLOCKING${ACCENT}] missing validation" '{comments: [{createdAt:"2026-06-30T01:00:00Z", body:$b}]}')
out=$(run_filter "$fixture")
assert_body_match "TC-DIV-ACCENT  BLOCKING+é → SELECTED" "missing validation" "$out"

fixture=$(jq -n --arg b "[BLOCKING${CJK}] missing validation" '{comments: [{createdAt:"2026-06-30T01:00:00Z", body:$b}]}')
out=$(run_filter "$fixture")
assert_body_match "TC-DIV-CJK  BLOCKING+中 → SELECTED" "missing validation" "$out"

# NBSP-prefixed "Moving to …": RE2's `\s` does NOT include NBSP, so the OLD
# `^\s*Moving` exclusion anchor never matched an NBSP-led line → it was NOT
# excluded-as-status (it would be SELECTED as a finding if it carried a token).
# The rewritten `^[ \t\r\n\f]*` likewise excludes NBSP. Here the NBSP-led line
# carries a BLOCKING token: it must be SELECTED (NOT excluded as dispatcher
# chatter), matching RE2.
fixture=$(jq -n --arg b "${NBSP}Moving to: [BLOCKING] real finding after a stray NBSP" '{comments: [{createdAt:"2026-06-30T01:00:00Z", body:$b}]}')
out=$(run_filter "$fixture")
assert_body_match "TC-DIV-NBSP  NBSP-prefixed 'Moving to' w/ token → SELECTED (NBSP ∉ \\s, not excluded-as-status)" "real finding after a stray NBSP" "$out"

# Case-insensitivity (the scoped (?i:) must still fold the literals).
fixture=$(jq -n --arg b "this is a blocking concern that needs attention" '{comments: [{createdAt:"2026-06-30T01:00:00Z", body:$b}]}')
out=$(run_filter "$fixture")
assert_body_match "TC-DIV-LOWER-B  lowercase 'blocking' → SELECTED" "blocking concern" "$out"

fixture=$(jq -n --arg b "see [p1] lowercase priority marker" '{comments: [{createdAt:"2026-06-30T01:00:00Z", body:$b}]}')
out=$(run_filter "$fixture")
assert_body_match "TC-DIV-LOWER-P  lowercase '[p1]' → SELECTED" "lowercase priority marker" "$out"

# NON-BLOCKING (left consuming anchor rejects the hyphen) and BLOCKINGS (right
# consuming boundary rejects the trailing letter) must NOT match. A sole such
# comment yields empty.
fixture=$(jq -n --arg b "remaining items are NON-BLOCKING, safe to merge" '{comments: [{createdAt:"2026-06-30T01:00:00Z", body:$b}]}')
out=$(run_filter "$fixture")
assert_body_match "TC-DIV-NONBLK  'NON-BLOCKING' → NOT selected (left anchor rejects hyphen)" "<EMPTY>" "$out"

fixture=$(jq -n --arg b "the BLOCKINGS were resolved last sprint" '{comments: [{createdAt:"2026-06-30T01:00:00Z", body:$b}]}')
out=$(run_filter "$fixture")
assert_body_match "TC-DIV-PLURAL  'BLOCKINGS' → NOT selected (right boundary rejects trailing letter)" "<EMPTY>" "$out"

# ===================================================================
# TC-RFB-TIE — same-second tie. Two matching findings with BYTE-IDENTICAL
# whole-second createdAt, inserted A then B. `:1051`'s `| last` over
# itp_list_comments' ascending, STABLE `sort_by(.createdAt)` ([INV-90] MUST)
# must pick B (the later-INSERTED) — the guarantee gh's raw `.comments[]` gave.
# (The fixture is already in ascending/insertion order, as itp_list_comments
# would return it.)
echo
echo "=== TC-RFB-TIE: same-second createdAt tie → later-inserted wins (stable sort) ==="
fixture=$(jq -n \
  --argjson c1 "$(mk_comment '2026-06-30T08:00:00Z' "Review findings:

[BLOCKING] FIRST same-second finding.")" \
  --argjson c2 "$(mk_comment '2026-06-30T08:00:00Z' "Review findings:

[BLOCKING] SECOND same-second finding (later-inserted).")" \
  '{comments: [$c1, $c2]}')
out=$(run_filter "$fixture")
assert_body_match "TC-RFB-TIE same-second tie → later-INSERTED finding wins (| last over stable sort)" "SECOND same-second finding" "$out"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
exit 0
