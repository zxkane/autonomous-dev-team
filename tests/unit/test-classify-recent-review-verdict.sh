#!/bin/bash
# test-classify-recent-review-verdict.sh — INV-35 / issue #149.
#
# Unit tests for lib-dispatch.sh::classify_recent_review_verdict.
#
# The helper reads issue comments via gh, picks the newest comment that:
#   (a) is authored by BOT_LOGIN (or matches the session-id-binding fallback
#       when BOT_LOGIN is empty per the gh-api-user-403 pattern), AND
#   (b) was created strictly after <session_end_iso>, AND
#   (c) carries an HTML-comment trailer of form `<!-- review-verdict: ... -->`.
# It returns one of: none / passed / failed-substantive / failed-non-substantive.
# A surviving comment that has no trailer is conservatively treated as
# failed-substantive (back-compat with pre-INV-35 verdict comments).
#
# Test IDs map to docs/test-cases/inv35-review-aware-resume.md § A.
#
# Run: bash tests/unit/test-classify-recent-review-verdict.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-classify-$$
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# _MOCK_COMMENTS_JSON — JSON array fed to the mocked `gh issue view ... --json comments -q .comments`
# Each test case sets this; the gh stub echoes it back.
_MOCK_COMMENTS_JSON='[]'

gh() {
  local cmd="${1:-}"
  local sub="${2:-}"
  if [[ "$cmd" == "issue" && "$sub" == "view" ]]; then
    # Find the -q (jq) arg and apply it to _MOCK_COMMENTS_JSON.
    local jq_query=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-q" || "$1" == "--jq" ]]; then
        jq_query="$2"
        break
      fi
      shift
    done
    if [[ -z "$jq_query" ]]; then
      printf '%s' "$_MOCK_COMMENTS_JSON"
    else
      # Wrap the comments array as { comments: [...] } since the lib helper
      # uses `--json comments` and queries paths under `.comments[]`.
      printf '%s' "{\"comments\":$_MOCK_COMMENTS_JSON}" | jq -r "$jq_query"
    fi
    return 0
  fi
  return 0
}
export -f gh

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

# Re-define gh after sourcing lib (lib-dispatch.sh doesn't override gh, but
# safety belt mirrors test-dispatcher-step4-stale-verdict.sh pattern).
gh() {
  local cmd="${1:-}"
  local sub="${2:-}"
  if [[ "$cmd" == "issue" && "$sub" == "view" ]]; then
    local jq_query=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-q" || "$1" == "--jq" ]]; then
        jq_query="$2"
        break
      fi
      shift
    done
    if [[ -z "$jq_query" ]]; then
      printf '%s' "$_MOCK_COMMENTS_JSON"
    else
      printf '%s' "{\"comments\":$_MOCK_COMMENTS_JSON}" | jq -r "$jq_query"
    fi
    return 0
  fi
  return 0
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "  ${GREEN}PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${NC}: $desc"
    echo "      expected=[$expected]"
    echo "      actual=  [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

# Helper: build a JSON comment object.
mkc() {
  local login="$1" created_at="$2" body="$3"
  jq -n --arg l "$login" --arg c "$created_at" --arg b "$body" \
    '{author:{login:$l}, createdAt:$c, body:$b}'
}

# ---------------------------------------------------------------------------
echo "=== classify_recent_review_verdict (INV-35) ==="
# ---------------------------------------------------------------------------

BOT="kane-coding-agent[bot]"
SESSION_END="2026-05-21T03:18:00Z"
export BOT_LOGIN="$BOT"

# TC-INV35-CL-001: No comments after session-end → none
_MOCK_COMMENTS_JSON=$(jq -n --argjson c1 "$(mkc "$BOT" "2026-05-21T02:00:00Z" "Review FAILED")" \
  --argjson c2 "$(mkc "$BOT" "2026-05-21T01:00:00Z" "Other comment")" \
  '[$c1,$c2]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-001 verdict (no post-session comments)" "none" "$v"
assert_eq "TC-INV35-CL-001 cause" "" "$c"

# TC-INV35-CL-002: Newest comment carries failed-non-substantive trailer
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:29:00Z" $'<!-- review-verdict: failed-non-substantive cause=bot-timeout -->\nReview FAILED — q-bot timed out')" \
  --argjson c2 "$(mkc "$BOT" "2026-05-21T04:00:00Z" "earlier bot comment")" \
  --argjson c3 "$(mkc "$BOT" "2026-05-21T03:30:00Z" "even earlier bot comment")" \
  '[$c1,$c2,$c3]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-002 verdict" "failed-non-substantive" "$v"
assert_eq "TC-INV35-CL-002 cause" "bot-timeout" "$c"

# TC-INV35-CL-003: Newest by createdAt (gh returns out of order)
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson old "$(mkc "$BOT" "2026-05-21T04:00:00Z" "<!-- review-verdict: passed -->")" \
  --argjson newer "$(mkc "$BOT" "2026-05-21T05:00:00Z" "<!-- review-verdict: failed-substantive -->")" \
  '[$old,$newer]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-003 newest wins" "failed-substantive" "$v"

# TC-INV35-CL-004: Missing trailer falls back to failed-substantive
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" "Review FAILED — found 3 issues with the implementation.")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-004 fallback verdict" "failed-substantive" "$v"
assert_eq "TC-INV35-CL-004 fallback cause" "" "$c"

# TC-INV35-CL-005: Newest comment from non-bot author → ignored, older bot wins
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson human "$(mkc "operator-user" "2026-05-21T06:00:00Z" "Manual comment")" \
  --argjson bot "$(mkc "$BOT" "2026-05-21T05:00:00Z" "<!-- review-verdict: passed -->")" \
  '[$human,$bot]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-005 filter applied before pick" "passed" "$v"

# TC-INV35-CL-006: BOT_LOGIN empty → session-id binding fallback
SESSION_UUID="11111111-2222-3333-4444-555555555555"
export BOT_LOGIN=""
export FALLBACK_SESSION_ID="$SESSION_UUID"
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "anyone" "2026-05-21T05:10:00Z" $'Review FAILED\nReview Session: '"$SESSION_UUID"$'\n<!-- review-verdict: failed-non-substantive cause=ci-transport -->')" \
  --argjson c2 "$(mkc "anyone" "2026-05-21T04:00:00Z" "unrelated")" \
  '[$c1,$c2]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-006 fallback verdict" "failed-non-substantive" "$v"
assert_eq "TC-INV35-CL-006 fallback cause" "ci-transport" "$c"
unset FALLBACK_SESSION_ID
export BOT_LOGIN="$BOT"

# TC-INV35-CL-007: Multiple trailers in body → first match wins (pinned per design §7)
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" $'<!-- review-verdict: passed -->\nQuoted from earlier review.\n<!-- review-verdict: failed-substantive -->\nActual current verdict')" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-007 first match wins" "passed" "$v"

# TC-INV35-CL-008: Unknown cause token still routes to failed-non-substantive
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" "<!-- review-verdict: failed-non-substantive cause=newly-invented-token -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV35-CL-008 verdict" "failed-non-substantive" "$v"
assert_eq "TC-INV35-CL-008 cause forward-compat" "newly-invented-token" "$c"

# Edge: comment with createdAt exactly at session_end_iso → excluded (strict >)
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "$SESSION_END" "<!-- review-verdict: passed -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "edge: createdAt == session_end → excluded" "none" "$v"

# Edge: bot comment with empty body → none. Empty body carries no signal at
# all — neither a verdict nor a "we tried to review" trailer — so the helper
# returns "none" and the caller falls back to the INV-12-completed branch.
# This is conservative: a verdict comment in the wild always carries body
# text, so an empty body means the gh response was malformed or the comment
# was deleted.
_MOCK_COMMENTS_JSON=$(jq -n --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" "")" '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "edge: empty bot comment body → none (no signal)" "none" "$v"

# Edge: passed trailer with extra whitespace
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" "<!-- review-verdict:   passed   -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "edge: whitespace-tolerant trailer parse" "passed" "$v"

# ---------------------------------------------------------------------------
echo ""
echo "=== INV-92 (#298): optional dev-actionable 5th out-param ==="
# ---------------------------------------------------------------------------

# TC-INV92-CL-001: failed-substantive + dev-actionable=false → out-var false.
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" "<!-- review-verdict: failed-substantive dev-actionable=false -->")" \
  '[$c1]')
v=""; c=""; da=""
classify_recent_review_verdict 100 "$SESSION_END" v c da
assert_eq "TC-INV92-CL-001 verdict" "failed-substantive" "$v"
assert_eq "TC-INV92-CL-001 dev-actionable parsed false" "false" "$da"

# TC-INV92-CL-002: failed-substantive WITHOUT the token → out-var defaults true.
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" "<!-- review-verdict: failed-substantive -->")" \
  '[$c1]')
v=""; c=""; da="SENTINEL"
classify_recent_review_verdict 100 "$SESSION_END" v c da
assert_eq "TC-INV92-CL-002 verdict" "failed-substantive" "$v"
assert_eq "TC-INV92-CL-002 absent token ⇒ default true" "true" "$da"

# TC-INV92-CL-003: explicit dev-actionable=true → out-var true.
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" "<!-- review-verdict: failed-substantive dev-actionable=true -->")" \
  '[$c1]')
v=""; c=""; da=""
classify_recent_review_verdict 100 "$SESSION_END" v c da
assert_eq "TC-INV92-CL-003 explicit true → true" "true" "$da"

# TC-INV92-CL-004: the token is IGNORED on a non-substantive verdict (it only
# rides failed-substantive) — out-var stays the default true.
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" "<!-- review-verdict: failed-non-substantive cause=bot-timeout -->")" \
  '[$c1]')
v=""; c=""; da="SENTINEL"
classify_recent_review_verdict 100 "$SESSION_END" v c da
assert_eq "TC-INV92-CL-004 non-substantive verdict still parsed" "failed-non-substantive" "$v"
assert_eq "TC-INV92-CL-004 cause still parsed" "bot-timeout" "$c"
assert_eq "TC-INV92-CL-004 dev-actionable default true (token only on substantive)" "true" "$da"

# TC-INV92-CL-005: passed verdict + dev-actionable absent → true (and verdict passed).
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" "<!-- review-verdict: passed -->")" \
  '[$c1]')
v=""; c=""; da=""
classify_recent_review_verdict 100 "$SESSION_END" v c da
assert_eq "TC-INV92-CL-005 passed verdict" "passed" "$v"
assert_eq "TC-INV92-CL-005 dev-actionable default true" "true" "$da"

# TC-INV92-CL-006: the LEGACY 4-arg call (no 5th out-param) MUST still work under
# `set -u` — the guarded `printf -v "$_da_var"` is a no-op on an empty name. Run
# under set -e/-u to mirror the dispatcher (it is set +e here for the harness, so
# re-enable transiently to prove no unbound-variable crash).
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "$BOT" "2026-05-21T05:30:00Z" "<!-- review-verdict: failed-substantive dev-actionable=false -->")" \
  '[$c1]')
v=""; c=""
( set -eu
  classify_recent_review_verdict 100 "$SESSION_END" v c
) ; _legacy_rc=$?
assert_eq "TC-INV92-CL-006 4-arg legacy call does not crash under set -eu" "0" "$_legacy_rc"
# And it still classifies the verdict correctly (token simply ignored, no 5th arg).
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-INV92-CL-006 4-arg legacy verdict still correct" "failed-substantive" "$v"

# ---------------------------------------------------------------------------
echo ""
echo "=== #389: no-actor-signal structural anchor ==="
# ---------------------------------------------------------------------------
# In the dispatcher's own process BOT_LOGIN is NEVER set (resolved only inside
# autonomous-review.sh's separate process) and FALLBACK_SESSION_ID is never
# assigned anywhere in the codebase — so pre-fix the no-signal branch refused
# to classify and every completed-session pending-dev issue parked at INV-12
# even with a genuine bare verdict trailer present (fleet-wide 2026-07-03).
# The fix mirrors the convergence breaker's round-13/round-14 structural
# anchor: a genuine emit_verdict_trailer comment's ENTIRE body is the trailer
# line, so an anchored whole-body match authenticates authorship-independently.

export BOT_LOGIN=""
unset FALLBACK_SESSION_ID 2>/dev/null || true

# TC-389-001: bare whole-body trailer, no actor signal → classified.
# (Pre-fix: returns none → INV-12 park. This is the fleet-wide regression.)
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "kane-review-agent[bot]" "2026-05-21T05:30:00Z" "<!-- review-verdict: failed-substantive -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-389-001 bare trailer classified with no actor signal" "failed-substantive" "$v"

# TC-389-002: bare trailer with cause token → failed-non-substantive + cause.
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "kane-review-agent[bot]" "2026-05-21T05:30:00Z" "<!-- review-verdict: failed-non-substantive cause=bot-timeout -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-389-002 verdict" "failed-non-substantive" "$v"
assert_eq "TC-389-002 cause" "bot-timeout" "$c"

# TC-389-003: trailer embedded in prose is NOT authenticated (anchored match;
# round-14 forgery posture: any leading content fails the anchor).
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "operator-user" "2026-05-21T05:30:00Z" "Just quoting for context: <!-- review-verdict: passed -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-389-003 prose-embedded trailer rejected" "none" "$v"

# TC-389-004: trailing prose after the trailer also fails the anchor.
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "operator-user" "2026-05-21T05:30:00Z" $'<!-- review-verdict: passed -->\nextra text after')" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-389-004 trailing-prose trailer rejected" "none" "$v"

# TC-389-005: prose comment with no trailer at all, no actor signal → none.
# The legacy no-trailer→failed-substantive fallback stays gated to
# actor-authenticated comments; without a signal a prose comment is not a
# verdict candidate at all (INV-12 park preserved for verdict-less sessions).
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "operator-user" "2026-05-21T05:30:00Z" "Review FAILED — found 3 issues.")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-389-005 prose-only comment not classified without actor signal" "none" "$v"

# TC-389-006: newest anchored trailer wins (createdAt ordering preserved).
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson old "$(mkc "kane-review-agent[bot]" "2026-05-21T04:00:00Z" "<!-- review-verdict: passed -->")" \
  --argjson newer "$(mkc "kane-review-agent[bot]" "2026-05-21T05:00:00Z" "<!-- review-verdict: failed-substantive -->")" \
  '[$old,$newer]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-389-006 newest anchored trailer wins" "failed-substantive" "$v"

# TC-389-007: whole-body trailer BEFORE session end → none (time gate holds).
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "kane-review-agent[bot]" "2026-05-21T02:00:00Z" "<!-- review-verdict: failed-substantive -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-389-007 pre-session-end trailer ignored" "none" "$v"

# TC-389-008: dev-actionable token parsed through the anchored path.
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "kane-review-agent[bot]" "2026-05-21T05:30:00Z" "<!-- review-verdict: failed-substantive dev-actionable=false -->")" \
  '[$c1]')
v=""; c=""; da=""
classify_recent_review_verdict 100 "$SESSION_END" v c da
assert_eq "TC-389-008 verdict via anchor" "failed-substantive" "$v"
assert_eq "TC-389-008 dev-actionable=false honored" "false" "$da"

# TC-389-009: trailing whitespace/newline after the trailer is tolerated
# (mirrors the breaker's anchored pattern `-->[[:space:]]*$`).
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "kane-review-agent[bot]" "2026-05-21T05:30:00Z" $'<!-- review-verdict: failed-substantive -->\n')" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-389-009 trailing newline tolerated" "failed-substantive" "$v"

# TC-389-010: TWO trailers concatenated on one line are rejected (the second
# trailer trips the `[[:space:]]*$` tail). Pins the mechanism against a future
# loosening that would silently authenticate multi-trailer forgeries.
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "operator-user" "2026-05-21T05:30:00Z" "<!-- review-verdict: passed --><!-- review-verdict: failed-substantive -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-389-010 concatenated double trailer rejected" "none" "$v"

# TC-389-011: unknown VERDICT token in an otherwise-bare trailer → none. The
# no-signal grammar whitelists the three verdicts, so an anchored-but-unknown
# body never becomes a candidate — the legacy `case *)`→failed-substantive arm
# is unreachable under this branch (a forger cannot invent verdict vocabulary).
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "operator-user" "2026-05-21T05:30:00Z" "<!-- review-verdict: garbage-verdict-token -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-389-011 unknown verdict token rejected" "none" "$v"

# TC-389-012: unknown KEY token after a valid verdict → none (exact grammar:
# only cause=/dev-actionable= may follow; mirrors the downstream trailer grep
# so the legacy no-trailer fallback is unreachable under this branch too).
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "operator-user" "2026-05-21T05:30:00Z" "<!-- review-verdict: passed unknown=xxx -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-389-012 unknown key token rejected" "none" "$v"

# TC-389-013 (residual pin, token mode): a HUMAN author's byte-for-byte bare
# trailer IS accepted when GH_AUTH_MODE != app. This is the documented,
# accepted residual (round-13: token-mode genuine verdicts normalize to
# authorKind=human, so an author gate would reject every genuine verdict).
# Pinned so a future tightening changes this consciously, not silently.
export GH_AUTH_MODE="token"
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "some-random-human" "2026-05-21T05:30:00Z" "<!-- review-verdict: failed-substantive -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-389-013 token mode: human bare trailer accepted (documented residual)" "failed-substantive" "$v"

# TC-389-014 (app-mode gate): the SAME human bare trailer is rejected under
# GH_AUTH_MODE=app — the genuine wrapper posts under an App identity
# (`…[bot]` ⇒ authorKind=bot), so human authors are excluded from the
# no-signal candidate set entirely.
export GH_AUTH_MODE="app"
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "some-random-human" "2026-05-21T05:30:00Z" "<!-- review-verdict: failed-substantive -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-389-014 app mode: human bare trailer rejected" "none" "$v"

# TC-389-015 (app-mode fleet fix preserved): a [bot] author's bare trailer
# still classifies under the app-mode gate — the fleet-park regression stays
# fixed with the stronger authentication in place.
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "kane-review-agent[bot]" "2026-05-21T05:30:00Z" "<!-- review-verdict: failed-non-substantive cause=bot-timeout -->")" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-389-015 app mode: bot bare trailer classified" "failed-non-substantive" "$v"
assert_eq "TC-389-015 cause" "bot-timeout" "$c"
unset GH_AUTH_MODE

# TC-389-016: newline INSIDE the trailer → none. Oniguruma [[:space:]]
# matches \n, so a `[[:space:]]`-based inner grammar would accept this body
# while the line-oriented downstream grep extracts no trailer → legacy
# failed-substantive fallback — the exact unreachability hole the grammar
# claims to close (codex review, PR #390). Inner whitespace is [ \t] only.
_MOCK_COMMENTS_JSON=$(jq -n \
  --argjson c1 "$(mkc "operator-user" "2026-05-21T05:30:00Z" $'<!-- review-verdict:\npassed -->')" \
  '[$c1]')
v=""; c=""
classify_recent_review_verdict 100 "$SESSION_END" v c
assert_eq "TC-389-016 embedded-newline trailer rejected (no legacy fallback)" "none" "$v"

export BOT_LOGIN="$BOT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  PASS: $PASS"
echo "  FAIL: $FAIL"
[[ $FAIL -eq 0 ]] || exit 1
