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
