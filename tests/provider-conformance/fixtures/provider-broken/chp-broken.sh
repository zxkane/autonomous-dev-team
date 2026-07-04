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

# Correct leaves for the two W1c1 (#397) asserted verbs — projection-only
# per P1-1: emit EXACTLY the caller-requested vocabulary keys, plus (for
# find_pr_for_issue) the three [INV-86] resolver keys unconditionally.
# The github reference leaf's cursor-page walker is portable; the broken
# fixture uses the same shape. Kept inline (not sharing chp-github.sh's
# helpers) so this fixture stays a self-contained CHP file — the P2-2
# projection-only assertion in the runner is what catches over-projection.
_chp_broken_build_projection() {
  local fields="$1" forced="$2"
  local out="{}"
  local IFS_SAVE=$IFS; IFS=','
  # shellcheck disable=SC2206
  local -a all=(${fields} ${forced})
  IFS="$IFS_SAVE"
  local f seen=","
  for f in "${all[@]}"; do
    [ -n "$f" ] || continue
    case "$seen" in *",$f,"*) continue ;; esac
    seen="$seen$f,"
    case "$f" in
      number)              out+=' + {number: .number}' ;;
      body)                out+=' + {body: (.body // "")}' ;;
      headRefName)         out+=' + {headRefName: (.headRefName // "")}' ;;
      headRefOid)          out+=' + {headRefOid: (.headRefOid // "")}' ;;
      closingIssueNumbers) out+=' + {closingIssueNumbers: ([ (.closingIssuesReferences.nodes // [])[]?.number ])}' ;;
      state)               out+=' + {state: (.state // "")}' ;;
      title)               out+=' + {title: (.title // "")}' ;;
      createdAt)           out+=' + {createdAt: (.createdAt // null)}' ;;
      updatedAt)           out+=' + {updatedAt: (.updatedAt // null)}' ;;
      mergedAt)            out+=' + {mergedAt: (.mergedAt // null)}' ;;
      reviewDecision)      out+=' + {reviewDecision: (.reviewDecision // "")}' ;;
      mergeable)           out+=' + {mergeable: (.mergeable // "")}' ;;
    esac
  done
  printf '[ .data.repository.pullRequests.nodes[]? | %s ]' "$out"
}
chp_broken_find_pr_for_issue() {
  local fields="${2:-}"
  [ -n "$fields" ] || return 2
  local raw
  raw="$(gh api graphql -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -f query='{pullRequests}' 2>/dev/null)" || return 1
  [[ -n "$raw" ]] || return 1
  jq -c "$(_chp_broken_build_projection "$fields" "number,closingIssueNumbers,headRefName")" <<<"$raw"
}
chp_broken_pr_list() {
  local state="${1:-}" fields="${2:-}"
  [ -n "$state" ] || return 2
  [ -n "$fields" ] || return 2
  local raw
  raw="$(gh api graphql -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -f query='{pullRequests}' 2>/dev/null)" || return 1
  [[ -n "$raw" ]] || return 1
  jq -c "$(_chp_broken_build_projection "$fields" "number")" <<<"$raw"
}
