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
# chp_broken_close_keyword is deliberately OMITTED: the runner's
# chp_close_keyword assertion never dispatches through a leaf (it evals
# _render_close_keyword directly against a stubbed chp_caps — see
# run-provider-conformance.sh's _run_close_keyword_assert), so a leaf here
# would be dead code.

# Correct leaves for the two W1c1 (#397) asserted verbs: kept correct so only
# the two originally-targeted violations above surface. The github reference
# leaves' normalization jq is portable and provider-neutral; a broken CHP
# doesn't need to break the abstract-contract check specifically. Kept inline
# (not sharing chp-github.sh's helpers) so this fixture stays a self-
# contained CHP file — matching the pattern the other correct broken leaves
# above use.
_chp_broken_pr_normalize_jq='
  [ .[] | {
      number: .number,
      state: (.state // ""),
      title: (.title // ""),
      body: (.body // ""),
      createdAt: (.createdAt // null),
      updatedAt: (.updatedAt // null),
      mergedAt: (.mergedAt // null),
      headRefName: (.headRefName // ""),
      headRefOid: (.headRefOid // ""),
      reviewDecision: (.reviewDecision // ""),
      mergeable: (.mergeable // ""),
      closingIssueNumbers: ([ (.closingIssuesReferences // [])[]?.number ])
    }
  ]'
chp_broken_find_pr_for_issue() {
  local fields="${2:-}"
  [ -n "$fields" ] || return 2
  local raw
  raw="$(gh pr list --repo "$REPO" --state open --limit 100 --json "number,body,closingIssuesReferences,headRefName" 2>/dev/null)" || return 1
  jq -c "$_chp_broken_pr_normalize_jq" <<<"$raw"
}
chp_broken_pr_list() {
  local state="${1:-}"
  [ -n "$state" ] || return 2
  [ -n "${2:-}" ] || return 2
  local state_lc
  state_lc="$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"
  local raw
  raw="$(gh pr list --repo "$REPO" --state "$state_lc" --limit 100 --json "number,body,closingIssuesReferences,createdAt" 2>/dev/null)" || return 1
  jq -c "$_chp_broken_pr_normalize_jq" <<<"$raw"
}
