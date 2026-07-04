#!/bin/bash
# tests/provider-conformance/fixtures/provider-broken/itp-broken.sh
#
# DELIBERATELY-BROKEN fixture provider (issue #370 AC2 / Testing
# Requirements) — proves run-provider-conformance.sh FAILs loud with exactly
# one FAIL line per violated clause, never a silent pass. Every OTHER
# ASSERTED verb (not targeted by a deliberate violation) behaves correctly so
# the broken run's FAIL count is exactly the number of deliberate violations,
# never more.
#
# Violations (one per Testing-Requirements category):
#   - itp_broken_list_comments  → wrong shape (bare object, not an array)
#   - itp_broken_transition_state → rc 0 even when the stub `gh` fails

# VIOLATION: wrong shape — returns a bare object, not an array.
itp_broken_list_comments() {
  local issue="$1"
  gh issue view "$issue" --repo "$REPO" --json comments -q '{ not: "an array" }'
}

# VIOLATION: rc-0-on-error — swallows the `gh` failure and always returns 0.
itp_broken_transition_state() {
  local issue_num="$1" remove="$2" add="$3"
  gh issue edit "$issue_num" --repo "$REPO" --remove-label "$remove" --add-label "$add" || true
}

# Correct leaves (not targeted — kept correct so only the two violations above surface).
itp_broken_post_comment() {
  local issue_num="$1" body="$2"
  gh issue comment "$issue_num" --repo "$REPO" --body "$body"
}
itp_broken_edit_comment() {
  local _issue="$1" comment_id="$2" body="$3"
  gh api -X PATCH "repos/${REPO_OWNER}/${REPO_NAME}/issues/comments/${comment_id}" -f body="$body"
}
itp_broken_mark_checkbox() {
  local issue_num="$1" new_body="$2"
  gh api "repos/${REPO}/issues/${issue_num}" --method PATCH --field body="$new_body" --silent
}
itp_broken_provision_states() {
  local name="$1" color="$2" description="$3"
  if gh api "repos/${REPO}/labels/${name}" --silent &>/dev/null; then
    echo "  [skip] '$name' already exists"
  else
    gh label create "$name" --repo "$REPO" --color "$color" --description "$description"
    echo "  [created] '$name'"
  fi
}
itp_broken_resolve_dep() {
  local owner_repo="$1" num="$2" out_var="$3"
  local _state
  _state=$(gh issue view "$num" --repo "$owner_repo" --json state -q '.state' 2>/dev/null || true)
  printf -v "$out_var" '%s' "$_state"
}
itp_broken_label_event_ts() {
  local issue="$1" label="$2"
  gh api "repos/${REPO}/issues/${issue}/timeline" \
    --jq "map(select(.event == \"labeled\" and .label.name == \"${label}\")) | (.[0].created_at // empty)" \
    2>/dev/null || true
}
# Correct leaves for the #371 W1a abstract state-read verbs (not targeted by
# a deliberate violation — kept correct so the broken run's FAIL count stays
# exactly the 4 deliberate violations, never more).
_itp_broken_state_read() {
  local state="$1" labels_csv="$2" limit="$3"
  local -a args=(issue list --repo "$REPO" --state "$state" --limit "$limit")
  [[ -n "$labels_csv" ]] && args+=(--label "$labels_csv")
  args+=(--json number,title,labels,comments)
  gh "${args[@]}" | jq --arg bot "${BOT_LOGIN:-}" '
    [ .[] | {
        number: .number,
        title: (.title // ""),
        labels: [ (.labels // [])[].name ],
        comments: [ (.comments // [])[]
          | { id: ( ( (.url // "") | capture("issuecomment-(?<n>[0-9]+)$") | .n | tonumber ) // null ),
              author: (.author.login // null),
              authorKind: ( (.author.login // "") as $a
                            | if ($a != "" and $a == $bot) then "self"
                              elif ($a | endswith("[bot]")) then "bot"
                              else "human" end ),
              body: (.body // ""),
              createdAt: (.createdAt // null) }
          ] | sort_by(.createdAt // "")
      }
    ] | sort_by(.number)
  '
}
itp_broken_list_by_state() {
  local state="$1" labels_csv="$2" limit="$3" fields_csv="$4" fields_json
  fields_json=$(printf '%s' "$fields_csv" | jq -R -s -c 'split(",") | map(select(length > 0))')
  _itp_broken_state_read "$state" "$labels_csv" "$limit" \
    | jq --argjson fields "$fields_json" '[ .[] | . as $o | ($fields | map({(.): $o[.]}) | add // {}) ]'
}
itp_broken_count_by_state() {
  local state="$1" labels_csv="$2" limit="$3" any_of_csv="$4" any_of_json
  any_of_json=$(printf '%s' "$any_of_csv" | jq -R -s -c 'split(",") | map(select(length > 0))')
  _itp_broken_state_read "$state" "$labels_csv" "$limit" | jq --argjson anyof "$any_of_json" '
    [ .[] | select(
        ($anyof | length) == 0
        or ( .labels as $ls | $anyof | any(. as $a | $ls | index($a) != null) )
      )
    ] | length
  '
}
itp_broken_list_forbidden_combos() {
  local state="$1" labels_csv="$2" limit="$3"
  _itp_broken_state_read "$state" "$labels_csv" "$limit" | jq '
    [ .[] | select(
        (.labels | any(. == "approved" or . == "stalled"))
        and
        (.labels | any(. == "in-progress" or . == "reviewing" or . == "pending-review" or . == "pending-dev"))
      ) | {number, labels}
    ]
  '
}

# Correct leaf for the #396 W1b abstract itp_read_task verb (not targeted by
# a deliberate violation — kept correct so the broken run's FAIL count stays
# exactly the deliberate violations, never more). [#396 review r2/r3] Mirrors
# the REST-sourced comments split of the real leaf: `comments` comes from the
# REST page-set (user.type drives authorKind, login verbatim incl [bot]) —
# NOT from `gh issue view --json comments` (GraphQL, which strips the suffix
# and would fail the runner's bot-classification tripwire).
itp_broken_read_task() {
  local issue="$1" fields_csv="$2" fields_json raw comments_json='[]'
  fields_json=$(printf '%s' "$fields_csv" | jq -R -s -c 'split(",") | map(select(length > 0))')
  raw=$(gh issue view "$issue" --repo "$REPO" --json title,body,state,labels) || return 1
  [[ -n "$raw" ]] || return 1
  case ",${fields_csv}," in
    *,comments,*)
      comments_json=$(gh api --paginate --slurp "repos/${REPO}/issues/${issue}/comments" | jq "
        [ .[][]
          | { id: (.id // null),
              author: (.user.login // null),
              authorKind: ( (.user.login // \"\") as \$a
                            | ( \$a | sub(\"\\\\[bot\\\\]\$\"; \"\") ) as \$stripped
                            | if (\$a != \"\" and \"${BOT_LOGIN:-}\" != \"\" and (\$a == \"${BOT_LOGIN:-}\" or \$stripped == \"${BOT_LOGIN:-}\")) then \"self\"
                              elif ((.user.type // \"\") == \"Bot\") then \"bot\"
                              else \"human\" end ),
              body: (.body // \"\"),
              createdAt: (.created_at // null) }
        ] | sort_by(.createdAt // \"\", .id // 0)
      ") || return 1
      [[ -n "$comments_json" ]] || return 1
      ;;
  esac
  jq --argjson fields "$fields_json" --argjson comments "$comments_json" '
        {
          title: (.title // ""),
          body: (.body // ""),
          state: (.state // ""),
          labels: [ (.labels // [])[].name ],
          comments: $comments
        } as $norm
        | ($fields | map({(.): $norm[.]}) | add // {})
      ' <<<"$raw"
}
