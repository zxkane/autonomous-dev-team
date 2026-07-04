#!/bin/bash
# tests/unit/fixtures/provider-degraded/chp-degraded.sh
#
# NAMED degraded fake CHP provider (#280, provider-spec.md §8 fake-provider;
# design-spec §7.4 third bullet). The capability-branch test
# (test-provider-dispatch.sh TC-030) selects this provider through the PUBLIC
# seam — CODE_HOST=degraded + AUTONOMOUS_PROVIDERS_DIR=<this dir> — and reads
# chp-degraded.caps via chp_caps (the real provider-selection path), NOT by
# reading the .caps file directly.
#
# Fleshed out from an empty scaffold (issue #370, R4): the leaves below give
# the degraded fixture a REAL provider-neutral body for every
# cap-map.conf row whose governing cap is `-` (always-asserted), so
# tests/provider-conformance/run-provider-conformance.sh has something
# genuine to assert against instead of universal `command not found`. Each
# mirrors its GitHub counterpart's `gh api`/`gh api graphql` shape
# structurally.
#
# `chp_degraded_close_keyword` is DELIBERATELY ABSENT — do not add it. The
# runner's chp_close_keyword conformance check is scoped to the CALLER-SIDE
# `_render_close_keyword` render contract (autonomous-dev.sh), never to
# `chp_has_leaf close_keyword`/leaf dispatch (see
# docs/designs/provider-conformance-runner.md's "deliberate NON-leaf
# exception" callout). tests/unit/test-chp-pr-lifecycle.sh's
# TC-CHP-LEAF-GUARD depends on THIS FIXTURE staying leaf-less for
# close_keyword — it pins the exact leaf-absent + merge_closes_issue=0 +
# native_issue_pr_link=0 degraded state to prove the caller-side fallback
# renders the non-closing `Related to #N` backref. Adding a leaf here would
# flip `chp_has_leaf close_keyword` from absent to present and break that
# test.

# chp_degraded_review_threads PR — mirrors chp_github_review_threads' M8 shape.
chp_degraded_review_threads() {
  local pr="$1"
  local owner="${REPO%%/*}" name="${REPO##*/}"
  gh api graphql \
    -F owner="$owner" \
    -F repo="$name" \
    -F prNumber="$pr" \
    -f query='
query($owner: String!, $repo: String!, $prNumber: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $prNumber) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 100) {
            nodes {
              databaseId
              path
              line
              originalLine
              author { login }
              body
              createdAt
            }
          }
        }
      }
    }
  }
}' --jq '
    [ .data.repository.pullRequest.reviewThreads.nodes[]
      | { thread_id: .id,
          resolved: .isResolved,
          comments: [ .comments.nodes[]
                      | { id: .databaseId,
                          path: .path,
                          line: (.line // .originalLine),
                          author: (.author.login // null),
                          body: (.body // ""),
                          createdAt: .createdAt } ] } ]'
}

# chp_degraded_resolve_thread THREAD_ID — mirrors chp_github_resolve_thread.
chp_degraded_resolve_thread() {
  local thread_id="$1"
  gh api graphql \
    -F threadId="$thread_id" \
    -f query='
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread { isResolved }
  }
}' --jq '.data.resolveReviewThread.thread.isResolved'
}

# chp_degraded_reply_review_comment PR COMMENT_ID BODY — mirrors
# chp_github_reply_review_comment.
chp_degraded_reply_review_comment() {
  local pr="$1" comment_id="$2" body="$3"
  gh api "repos/${REPO}/pulls/${pr}/comments" \
    -X POST -f body="$body" -F in_reply_to="$comment_id" \
    --jq '{id: .id, url: .html_url}'
}

# chp_degraded_find_pr_for_issue / chp_degraded_pr_list — mirror
# chp_github_*'s W1c1 (#397) abstract contract with projection-only
# (P1-1/P2-2): emit EXACTLY the caller-requested vocabulary keys, plus
# (for find_pr_for_issue) the three [INV-86] resolver keys unconditionally.
# The runner's P2-2 projection-only assertion would flag over-projection
# — this fixture is CORRECT for its non-cap-gated verbs.
_chp_degraded_build_projection() {
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
chp_degraded_find_pr_for_issue() {
  local fields="${2:-}"
  [ -n "$fields" ] || return 2
  local raw
  raw="$(gh api graphql -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -f query='{pullRequests}' 2>/dev/null)" || return 1
  [[ -n "$raw" ]] || return 1
  jq -c "$(_chp_degraded_build_projection "$fields" "number,closingIssueNumbers,headRefName")" <<<"$raw"
}
chp_degraded_pr_list() {
  local state="${1:-}" fields="${2:-}"
  [ -n "$state" ] || return 2
  [ -n "$fields" ] || return 2
  local raw
  raw="$(gh api graphql -F owner="${REPO%%/*}" -F repo="${REPO##*/}" -f query='{pullRequests}' 2>/dev/null)" || return 1
  [[ -n "$raw" ]] || return 1
  jq -c "$(_chp_degraded_build_projection "$fields" "number")" <<<"$raw"
}
