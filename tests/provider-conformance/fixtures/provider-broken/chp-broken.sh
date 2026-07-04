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
# Correct chp_pr_view leaf mirroring the GitHub implementation (#398 W1c2) —
# kept correct so it PASSes and only the two violations above surface as FAILs.
chp_broken_pr_view() {
  local pr="$1" fields_csv="${2:-}"
  [ -n "$fields_csv" ] || { echo "ERROR: chp_broken_pr_view requires FIELDS_CSV (2nd arg) [W1c2]" >&2; return 2; }
  # W1c2 online-review r1 mirror: same vocabulary gate as chp_github_pr_view.
  local _CHP_BRK_PRV_VOCAB="number,state,title,body,createdAt,updatedAt,mergedAt,headRefName,headRefOid,reviewDecision,mergeable,closingIssueNumbers,comments,reviews"
  local gh_fields="" _obj_body="" first=1 f out_field _seen_map=""
  local IFS_SAVED="$IFS"; IFS=','
  # shellcheck disable=SC2206
  local requested=($fields_csv)
  IFS="$IFS_SAVED"
  for f in "${requested[@]}"; do
    f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"
    [ -z "$f" ] && continue
    case ",${_CHP_BRK_PRV_VOCAB}," in
      *",$f,"*) : ;;
      *) echo "ERROR: chp_broken_pr_view: field '$f' is not in the §3.2.1 vocabulary" >&2; return 2 ;;
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
  # Capture-then-check (P1-2 mirror of chp_github_pr_view).
  local raw
  raw=$(gh pr view "$pr" --repo "$REPO" --json "$gh_fields") || return 1
  [[ -n "$raw" ]] || return 1
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$raw" || return 1
  jq -c "{ ${_obj_body} }" <<<"$raw"
}
# Correct chp_list_inline_comments leaf (#398 W1c2) — page-walk + normalize +
# empty-stdout fail-CLOSED (P2-3 codex fix) + non-array-page fail-CLOSED
# (online-review r2 fix).
chp_broken_list_inline_comments() {
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
# Correct chp_broken_ci_status / chp_broken_mergeable (#399 W1d) — kept correct
# so only this fixture's pre-existing violations (chp_broken_review_threads,
# chp_broken_resolve_thread) surface as FAILs; the new W1d asserted verbs must
# not spuriously extend the count. Include the P2-3 fail-closed guards (empty
# stdout / unknown mergeable token → rc!=0) mirroring the github leaf.
chp_broken_ci_status() {
  local pr="$1"
  local raw gh_err states token
  gh_err="$(mktemp)"
  raw="$(gh pr checks "$pr" --repo "$REPO" --json state 2>"$gh_err" || true)"
  if [[ -z "$raw" ]]; then
    [ -s "$gh_err" ] && cat "$gh_err" >&2
    rm -f "$gh_err"
    return 1
  fi
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$raw" || {
    [ -s "$gh_err" ] && cat "$gh_err" >&2
    rm -f "$gh_err"
    return 1
  }
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
  [[ -n "$token" ]] || return 1
  printf '%s' "$token"
}
chp_broken_mergeable() {
  local pr="$1"
  local raw
  raw="$(gh pr view "$pr" --repo "$REPO" --json mergeable -q '.mergeable' 2>/dev/null)" || return 1
  case "${raw^^}" in
    MERGEABLE|CONFLICTING|UNKNOWN) printf '%s' "$raw" ;;
    *) return 1 ;;
  esac
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
