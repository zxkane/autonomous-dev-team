#!/bin/bash
# tests/provider-conformance/fixtures/provider-broken/chp-broken.sh
#
# DELIBERATELY-BROKEN fixture provider (issue #370 AC2 / Testing
# Requirements). See itp-broken.sh's header for the shared rationale.
#
# Violations:
#   - chp_broken_review_threads → non-array output (bare object)
#   - chp_broken_resolve_thread → MISSING entirely (missing-verb-function)

# VIOLATION: non-array output — returns a bare object, not an array.
chp_broken_review_threads() {
  local pr="$1"
  local owner="${REPO%%/*}" name="${REPO##*/}"
  gh api graphql -F owner="$owner" -F repo="$name" -F prNumber="$pr" -f query='query{x}' \
    --jq '{ not: "an array" }'
}

# VIOLATION (missing-verb-function): chp_broken_resolve_thread intentionally
# NOT defined. The dispatch shim `chp_resolve_thread() { chp_${CODE_HOST}_resolve_thread "$@"; }`
# calls `chp_broken_resolve_thread`, which does not exist — `command not found`.

# Correct leaves (not targeted — kept correct so only the two violations above surface).
chp_broken_request_changes() {
  local pr="$1" body="${2:-}"
  gh pr review "$pr" --repo "$REPO" --request-changes --body "$body"
}
chp_broken_reply_review_comment() {
  local pr="$1" comment_id="$2" body="$3"
  gh api "repos/${REPO}/pulls/${pr}/comments" -X POST -f body="$body" -F in_reply_to="$comment_id" \
    --jq '{id: .id, url: .html_url}'
}
chp_broken_close_keyword() {
  local issue="$1"
  printf 'Closes #%s' "$issue"
}
