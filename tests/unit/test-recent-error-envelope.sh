#!/bin/bash
# test-recent-error-envelope.sh — issue #231 / INV-72.
#
# Unit tests for lib-dispatch.sh::recent_error_envelope — the dispatcher Step-5
# stale-handling helper that detects a surfaced `<!-- adt-error-envelope: {json} -->`
# marker on the issue so the DEAD-branch comment links the config error
# (code + remediation) instead of the opaque generic "crashed" text.
#
# The helper:
#   - reads issue comments via gh, picks the NEWEST comment carrying the marker,
#   - rejects it if older than ERROR_ENVELOPE_WINDOW_SECONDS,
#   - extracts the embedded JSON (sed, no PCRE look-behind — gh-RE2-safe) and
#     echoes `<code> — <remediation>`; echoes empty + rc 1 when none/expired.
#
# Run: bash tests/unit/test-recent-error-envelope.sh
set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$PROJECT_ROOT/skills/autonomous-dispatcher/scripts/lib-dispatch.sh"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
ok()  { echo -e "  ${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
bad() { echo -e "  ${RED}FAIL${NC}: $1"; FAIL=$((FAIL + 1)); }

export REPO=zxkane/autonomous-dev-team
export REPO_OWNER=zxkane
export PROJECT_ID=test-ree-$$
export MAX_RETRIES=3
export MAX_CONCURRENT=5

# Comments array fed to the gh stub.
_MOCK_COMMENTS_JSON='[]'
# Age (seconds) that the stubbed _iso_age_seconds returns, so the test is
# clock-independent.
_MOCK_AGE=10

gh() {
  # [#393] itp_list_comments reads REST (gh api --paginate --slurp .../comments).
  # Serve the GraphQL-style fixture converted to REST page shape (type=Bot iff
  # login ends [bot]; id=ordinal), so authorKind derivation works unchanged.
  if [[ "${1:-}" == "api" && "${2:-}" == "--paginate" ]]; then
    jq '(if type == "object" then (.comments // []) else . end) | [ [ .[] | {id: 0, user: {login: (.author.login // ""), type: (if ((.author.login // "") | endswith("[bot]")) then "Bot" else "User" end)}, body: (.body // ""), created_at: (.createdAt // null)} ] | to_entries | map(.value + {id: (.key + 1)}) ]' <<<"${_MOCK_COMMENTS_JSON:-[]}"
    return 0
  fi
  if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
    local jq_query=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-q" || "$1" == "--jq" ]]; then jq_query="$2"; break; fi
      shift
    done
    if [[ -z "$jq_query" ]]; then printf '%s' "$_MOCK_COMMENTS_JSON"
    else printf '%s' "{\"comments\":$_MOCK_COMMENTS_JSON}" | jq -r "$jq_query"; fi
    return 0
  fi
  return 0
}
export -f gh

# shellcheck source=../../skills/autonomous-dispatcher/scripts/lib-dispatch.sh
source "$LIB"
set +e

# Re-define after sourcing (mirror sibling tests' safety belt).
gh() {
  # [#393] itp_list_comments reads REST (gh api --paginate --slurp .../comments).
  # Serve the GraphQL-style fixture converted to REST page shape (type=Bot iff
  # login ends [bot]; id=ordinal), so authorKind derivation works unchanged.
  if [[ "${1:-}" == "api" && "${2:-}" == "--paginate" ]]; then
    jq '(if type == "object" then (.comments // []) else . end) | [ [ .[] | {id: 0, user: {login: (.author.login // ""), type: (if ((.author.login // "") | endswith("[bot]")) then "Bot" else "User" end)}, body: (.body // ""), created_at: (.createdAt // null)} ] | to_entries | map(.value + {id: (.key + 1)}) ]' <<<"${_MOCK_COMMENTS_JSON:-[]}"
    return 0
  fi
  if [[ "${1:-}" == "issue" && "${2:-}" == "view" ]]; then
    local jq_query=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == "-q" || "$1" == "--jq" ]]; then jq_query="$2"; break; fi
      shift
    done
    if [[ -z "$jq_query" ]]; then printf '%s' "$_MOCK_COMMENTS_JSON"
    else printf '%s' "{\"comments\":$_MOCK_COMMENTS_JSON}" | jq -r "$jq_query"; fi
    return 0
  fi
  return 0
}
# Stub the age helper so window logic is deterministic.
_iso_age_seconds() { echo "$_MOCK_AGE"; }

# Build a comment body holding an envelope marker for <code>/<remediation>.
envelope_body() {
  local code="$1" remediation="$2"
  printf '**Configuration error**\n\n- **Code:** `%s`\n- **Remediation:** %s\n\n<!-- adt-error-envelope: {"schema_version":1,"class":"config","code":"%s","problem":"p","cause":"c","remediation":"%s","surface":"issue-comment"} -->' \
    "$code" "$remediation" "$code" "$remediation"
}

# Helper to JSON-encode a comment {body, createdAt}.
comment_json() {
  jq -nc --arg b "$1" --arg t "${2:-2026-06-12T00:00:00Z}" '{body:$b, createdAt:$t}'
}

echo "=== TC-ERR-ENVELOPE recent_error_envelope ==="

# TC-REE-01: no comments → empty + rc 1.
_MOCK_COMMENTS_JSON='[]'
out=$(recent_error_envelope 231); rc=$?
[[ $rc -ne 0 && -z "$out" ]] && ok "01 no comments → rc!=0, empty" || bad "01 expected rc!=0 + empty (rc=$rc out='$out')"

# TC-REE-02: a recent envelope marker → echoes 'code — remediation', rc 0.
BODY=$(envelope_body ADT_CFG_E2E_MODE_INVALID "Set E2E_MODE to none, browser, or command")
_MOCK_COMMENTS_JSON="[$(comment_json "$BODY")]"
_MOCK_AGE=10
out=$(recent_error_envelope 231); rc=$?
[[ $rc -eq 0 ]] && ok "02 recent envelope → rc 0" || bad "02 expected rc 0 (rc=$rc)"
[[ "$out" == "ADT_CFG_E2E_MODE_INVALID — Set E2E_MODE to none, browser, or command" ]] \
  && ok "02 echoes 'code — remediation'" || bad "02 unexpected summary: '$out'"

# TC-REE-03: envelope OLDER than the window → empty + rc 1.
_MOCK_AGE=99999
out=$(recent_error_envelope 231); rc=$?
[[ $rc -ne 0 && -z "$out" ]] && ok "03 expired envelope → rc!=0, empty" || bad "03 expected rc!=0+empty (rc=$rc out='$out')"

# TC-REE-04: window override honored (ERROR_ENVELOPE_WINDOW_SECONDS).
_MOCK_AGE=500
ERROR_ENVELOPE_WINDOW_SECONDS=600 out=$(ERROR_ENVELOPE_WINDOW_SECONDS=600 recent_error_envelope 231); rc=$?
[[ $rc -eq 0 ]] && ok "04 age 500 < window 600 → rc 0" || bad "04 expected rc 0 (rc=$rc)"
out=$(ERROR_ENVELOPE_WINDOW_SECONDS=400 recent_error_envelope 231); rc=$?
[[ $rc -ne 0 ]] && ok "04 age 500 > window 400 → rc!=0" || bad "04 expected rc!=0 (rc=$rc)"
_MOCK_AGE=10

# TC-REE-05: NEWEST marker wins when multiple envelopes exist (`last`).
B1=$(envelope_body ADT_CFG_MISSING_KEY "Set PROJECT_ID")
B2=$(envelope_body ADT_AUTH_APP_CREDS_MISSING "Set the App id + PEM")
_MOCK_COMMENTS_JSON="[$(comment_json "$B1" 2026-06-12T00:00:00Z),$(comment_json "$B2" 2026-06-12T01:00:00Z)]"
out=$(recent_error_envelope 231); rc=$?
[[ "$out" == ADT_AUTH_APP_CREDS_MISSING* ]] && ok "05 newest marker wins" || bad "05 expected newest (got '$out')"

# TC-REE-06: a non-envelope comment is ignored.
_MOCK_COMMENTS_JSON="[$(comment_json 'just a normal status comment' 2026-06-12T02:00:00Z)]"
out=$(recent_error_envelope 231); rc=$?
[[ $rc -ne 0 && -z "$out" ]] && ok "06 non-envelope comment ignored" || bad "06 expected rc!=0+empty (out='$out')"

# TC-REE-07: malformed window (non-numeric) → safe rc 1, no crash.
out=$(ERROR_ENVELOPE_WINDOW_SECONDS=abc recent_error_envelope 231 2>/dev/null); rc=$?
[[ $rc -ne 0 && -z "$out" ]] && ok "07 non-numeric window → rc!=0, empty (safe)" || bad "07 expected rc!=0+empty (rc=$rc out='$out')"

echo ""
echo "============================================"
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
echo "============================================"
[[ "$FAIL" -eq 0 ]]
