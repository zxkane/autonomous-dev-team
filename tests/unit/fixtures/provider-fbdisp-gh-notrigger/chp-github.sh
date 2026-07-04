#!/bin/bash
# tests/unit/fixtures/provider-fbdisp-gh-notrigger/chp-github.sh
#
# A GitHub-named CHP provider fixture that DEFINES chp_github_pr_list (so the
# bot-trigger broker's PR-number read resolves) but DELIBERATELY OMITS
# chp_github_trigger_bot — for #346 TC-FBDISP-004. Selected through the PUBLIC seam
# with CODE_HOST=github (the default) + AUTONOMOUS_PROVIDERS_DIR=<this dir>, so
# `chp_has_leaf trigger_bot` is FALSE while `${CODE_HOST:-github} == "github"` is
# TRUE → the raw `else` `gh-as-user.sh pr comment …` fallback branch is the one
# exercised (proving it fires byte-identically on the github topology when the
# trigger_bot leaf is somehow absent — the lib-load-degraded github case).
#
# Under W1c1 (#397) `chp_pr_list` is an ABSTRACT positional contract:
# `chp_pr_list STATE FIELDS-CSV → normalized JSON array`. This fixture's
# `chp_github_pr_list` mirrors the shape by driving the same `gh api graphql`
# cursor page walk the real leaf uses (single-page in this test since the
# stub returns `hasNextPage=false`), then applying a minimal projection.
# The test's on-PATH `gh` stub emits the GraphQL envelope, so the caller-
# side selector resolves pr_number without a real network hit.
chp_github_pr_list() {
  local state="${1:-}" fields="${2:-}"
  [ -n "$state" ]  || { echo "ERROR: chp_pr_list requires STATE" >&2; return 2; }
  [ -n "$fields" ] || { echo "ERROR: chp_pr_list requires FIELDS-CSV" >&2; return 2; }
  local state_lc; state_lc="$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"
  local state_filter
  case "$state_lc" in
    open)   state_filter='[OPEN]' ;;
    closed) state_filter='[CLOSED]' ;;
    merged) state_filter='[MERGED]' ;;
    all)    state_filter='[OPEN,CLOSED,MERGED]' ;;
    *) return 2 ;;
  esac
  local owner="${REPO%%/*}" name="${REPO##*/}"
  local query="query(\$owner: String!, \$repo: String!, \$cursor: String) {
    repository(owner: \$owner, name: \$repo) {
      pullRequests(first: 100, states: $state_filter, after: \$cursor, orderBy: {field: CREATED_AT, direction: DESC}) {
        pageInfo { endCursor hasNextPage }
        nodes { number body }
      }
    }
  }"
  local raw
  raw="$(gh api graphql -F owner="$owner" -F repo="$name" -f query="$query" 2>/dev/null)" || return 1
  [[ -n "$raw" ]] || return 1
  jq -c '[ .data.repository.pullRequests.nodes[]? | {number: .number, body: (.body // "")} ]' <<<"$raw"
}
