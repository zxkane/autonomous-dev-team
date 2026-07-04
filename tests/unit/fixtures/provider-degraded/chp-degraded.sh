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

# chp_degraded_ci_status PR — mirrors chp_github_ci_status' normalized-token
# contract (#399 W1d). Real provider-neutral body per R4: derive a single
# `green|pending|failed|none` token from a `gh pr checks --json state` payload.
# Structurally identical to the GitHub leaf so the conformance runner has a
# genuine body to assert against on `--chp degraded` runs.
chp_degraded_ci_status() {
  local pr="$1"
  local raw gh_err states token
  gh_err="$(mktemp)"
  raw="$(gh pr checks "$pr" --repo "$REPO" --json state 2>"$gh_err" || true)"
  states="$(printf '%s' "$raw" | jq -er '[.[].state]' 2>/dev/null)" || {
    [ -s "$gh_err" ] && cat "$gh_err" >&2
    rm -f "$gh_err"
    return 1
  }
  rm -f "$gh_err"
  token="$(jq -r '
    if length == 0 then "none"
    elif any(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT") then "failed"
    elif all(. == "SUCCESS") then "green"
    else "pending"
    end
  ' <<<"$states" 2>/dev/null)" || return 1
  printf '%s' "$token"
}

# chp_degraded_mergeable PR — mirrors chp_github_mergeable' pinned-token
# contract (#399 W1d). Absorbs the `-q '.mergeable'` projection into the leaf;
# emits one raw GitHub-compatible token MERGEABLE|CONFLICTING|UNKNOWN.
chp_degraded_mergeable() {
  local pr="$1"
  gh pr view "$pr" --repo "$REPO" --json mergeable -q '.mergeable'
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

# chp_degraded_pr_view PR FIELDS_CSV — mirrors chp_github_pr_view (#398 W1c2)
# incl. the P1-1 (dual closingIssuesReferences shape) + P1-2 (capture-then-
# check fail-CLOSED) codex fixes.
chp_degraded_pr_view() {
  local pr="$1" fields_csv="${2:-}"
  [ -n "$fields_csv" ] || { echo "ERROR: chp_degraded_pr_view requires FIELDS_CSV (2nd arg) [W1c2]" >&2; return 2; }
  # W1c2 online-review r1 mirror: gate FIELDS_CSV against the §3.2.1
  # vocabulary. Same reject list as the github leaf — a fixture that let a
  # gh-native name through would mask the vocabulary contract the runner
  # asserts, defeating the whole point of the fixture.
  local _CHP_DEG_PRV_VOCAB="number,state,title,body,createdAt,updatedAt,mergedAt,headRefName,headRefOid,reviewDecision,mergeable,closingIssueNumbers,comments,reviews"
  local gh_fields="" _obj_body="" first=1 f out_field _seen_map=""
  local IFS_SAVED="$IFS"; IFS=','
  # shellcheck disable=SC2206
  local requested=($fields_csv)
  IFS="$IFS_SAVED"
  for f in "${requested[@]}"; do
    f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"
    [ -z "$f" ] && continue
    case ",${_CHP_DEG_PRV_VOCAB}," in
      *",$f,"*) : ;;
      *) echo "ERROR: chp_degraded_pr_view: field '$f' is not in the §3.2.1 vocabulary" >&2; return 2 ;;
    esac
    case "$f" in
      closingIssueNumbers) out_field="closingIssuesReferences" ;;
      *)                   out_field="$f" ;;
    esac
    if [[ ",${_seen_map}," != *",${out_field},"* ]]; then
      _seen_map="${_seen_map:+${_seen_map},}${out_field}"
      gh_fields+="${gh_fields:+,}${out_field}"
    fi
    local expr
    case "$f" in
      body)                expr='body: (.body // "")' ;;
      comments)            expr='comments: ([ .comments[]? | { id: (.id // null), author: ((.author | if type == "object" then .login else . end) // null), body: (.body // ""), createdAt: (.createdAt // null) } ] | sort_by(.createdAt // "", .id // 0))' ;;
      reviews)             expr='reviews: ([ .reviews[]? | { author: ((.author | if type == "object" then .login else . end) // null), state: (.state // null), submittedAt: (.submittedAt // null) } ] | sort_by(.submittedAt // ""))' ;;
      closingIssueNumbers) expr='closingIssueNumbers: ([ ((.closingIssuesReferences // []) | (if type == "object" then (.nodes // []) else . end))[]? | .number ])' ;;
      *)                   expr="${f}: .${f}" ;;
    esac
    if [[ $first -eq 1 ]]; then first=0; else _obj_body+=", "; fi
    _obj_body+="$expr"
  done
  # Capture-then-check (P1-2 codex fix, mirror of chp_github_pr_view).
  local raw
  raw=$(gh pr view "$pr" --repo "$REPO" --json "$gh_fields") || return 1
  [[ -n "$raw" ]] || return 1
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$raw" || return 1
  jq -c "{ ${_obj_body} }" <<<"$raw"
}

# chp_degraded_list_inline_comments PR — mirrors chp_github_list_inline_comments
# (#398 W1c2): page-walk + slurp/merge/sort/normalize; fail-CLOSED on failure
# (rc≠0 propagation AND rc-0 empty-stdout rejection, P2-3 codex fix; AND
# non-array-page rejection, online-review r2 fix).
chp_degraded_list_inline_comments() {
  local pr="$1"
  local raw
  raw=$(gh api "repos/${REPO}/pulls/${pr}/comments" --paginate 2>/dev/null) || return 1
  [[ -n "$raw" ]] || return 1
  local _pages_ok
  _pages_ok=$(jq -r --slurp 'all(type == "array")' <<<"$raw" 2>/dev/null) || return 1
  [[ "$_pages_ok" == "true" ]] || return 1
  jq -c --slurp '
    (add // []) |
    [ .[]? | {
        id: (.id // null),
        path: (.path // null),
        line: (.line // .original_line),
        author: ((.user | if type == "object" then .login else . end) // null),
        body: (.body // ""),
        createdAt: (.created_at // null)
      } ] |
    sort_by(.createdAt // "", .id // 0)
  ' <<<"$raw"
}
