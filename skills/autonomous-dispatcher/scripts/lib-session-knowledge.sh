#!/usr/bin/env bash
# Optional task knowledge, shared by dev/review and the manual retry entry.

_session_knowledge_helper() {
  printf '%s\n' "${LIB_DIR}/../../autonomous-common/scripts/session-knowledge.sh"
}

_session_knowledge_git() {
  env -u GIT_DIR -u GIT_COMMON_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
    -u GIT_PREFIX -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES git "$@"
}

begin_session_knowledge() {
  local role="$1" session="$2" helper
  [[ "${SESSION_KNOWLEDGE:-auto}" != off ]] || return 0
  helper="$(_session_knowledge_helper)"
  if ! bash "$helper" --repo "$PROJECT_DIR" begin --no-active \
      --task "issue-${ISSUE_NUMBER}" --session "$session" --role "$role" >/dev/null; then
    echo "[session-knowledge] Assessment could not begin; knowledge is pending, not assessed." >&2
    return 0
  fi
  export AUTONOMOUS_KNOWLEDGE_TASK="issue-${ISSUE_NUMBER}"
  export AUTONOMOUS_KNOWLEDGE_SESSION="$session"
  if [[ "$role" == review ]]; then
    export AUTONOMOUS_KNOWLEDGE_HEAD="${PR_HEAD_SHA:-}"
  else
    unset AUTONOMOUS_KNOWLEDGE_HEAD
  fi
}

render_session_knowledge_prompt() {
  local role="$1" session="$2" helper reference helper_q reference_q project_q handoff
  [[ "${SESSION_KNOWLEDGE:-auto}" != off && -n "${ISSUE_NUMBER:-}" && -n "$session" ]] || return 0
  helper="$(_session_knowledge_helper)"
  reference="${helper%/scripts/*}/references/session-knowledge.md"
  printf -v helper_q '%q' "$helper"
  printf -v reference_q '%q' "$reference"
  printf -v project_q '%q' "$PROJECT_DIR"
  handoff='handing off development'
  [[ "$role" != review ]] || handoff='publishing the review verdict'
  cat <<EOF

## Optional durable session knowledge

Before ${handoff}, briefly assess whether durable knowledge needs an update.
Inspect existing candidates with:
  bash ${helper_q} --repo ${project_q} pending --task issue-${ISSUE_NUMBER}
Record only new, verified, durable facts or necessary corrections. Use the nearest
AGENTS.md, docs/troubleshooting/, or docs/lessons-learned/ as the eventual target.
When an update is useful, read ${reference_q} for the JSON schema and correction/discard examples. Record an
assessment from your current worktree before returning or posting the verdict:
  bash ${helper_q} assess --task issue-${ISSUE_NUMBER} --session ${session} --input <json-file>
If no update is needed, use instead:
  bash ${helper_q} assess --task issue-${ISSUE_NUMBER} --session ${session} --none 'reason no durable update is needed'
No minimum number of lessons, transcript export, or documentation edit is required.
Machine details and credential REFERENCES belong in the local array only; never
record a credential value. Reviewers correct/discard stale candidates before the
verdict. The wrapper writes and commits useful public updates AFTER confirmed merge
in a separate docs PR. This assessment does not change review/merge ownership.
EOF
}

# postmerge_session_knowledge ISSUE PR
# The caller keeps the original successful merge/label transition independent.
# No model invocation, issue write, trunk push, or second merge occurs here.
postmerge_session_knowledge() {
  local issue="$1" pr="$2" helper pending meta applied status branch commit digest worktree existing match_count number body
  [[ "${SESSION_KNOWLEDGE:-auto}" != off ]] || return 0
  [[ "$issue" =~ ^[1-9][0-9]*$ && "$pr" =~ ^[1-9][0-9]*$ ]] || return 1
  helper="$(_session_knowledge_helper)"
  pending="$(bash "$helper" --repo "$PROJECT_DIR" pending --task "issue-${issue}")" || return 1
  if ! jq -e '.updates | length > 0' >/dev/null <<<"$pending"; then
    if [[ "$(jq -r '.unassessed // 0' <<<"$pending")" != 0 ]]; then
      echo "[session-knowledge] No recorded public candidates; unfinished assessments remain pending." >&2
    fi
    return 0
  fi
  # A successful merge command can mean queued auto-merge. Require the provider's
  # terminal state AND merge timestamp before touching repository documentation.
  meta="$(chp_pr_view "$pr" "state,mergedAt")" || return 1
  jq -e '.state == "MERGED" and (.mergedAt | type == "string" and length > 0)' >/dev/null <<<"$meta" || return 1
  _session_knowledge_git -C "$PROJECT_DIR" fetch origin "${BASE_BRANCH:-main}" >/dev/null 2>&1 || return 1
  applied="$(bash "$helper" --repo "$PROJECT_DIR" apply --task "issue-${issue}" \
      --base-ref "refs/remotes/origin/${BASE_BRANCH:-main}" --merged-pr "$pr")" || return 1
  status="$(jq -r '.status' <<<"$applied")"
  [[ "$status" == committed ]] || return 0
  branch="$(jq -r '.branch' <<<"$applied")"
  commit="$(jq -r '.commit' <<<"$applied")"
  digest="$(jq -r '.digest' <<<"$applied")"
  worktree="$(jq -r '.worktree' <<<"$applied")"
  # The list seam is exhaustive. Fail closed on an unavailable/non-array read
  # rather than create another PR after a successful-but-unrecorded publication.
  existing="$(chp_pr_list all 'number,headRefName,headRefOid')" || return 1
  jq -e 'type == "array"' >/dev/null <<<"$existing" || return 1
  match_count="$(jq --arg branch "$branch" '[.[] | select(.headRefName == $branch)] | length' <<<"$existing")"
  if [[ "$match_count" == 0 ]]; then
    _session_knowledge_git -C "$worktree" push origin "${commit}:refs/heads/${branch}" >/dev/null 2>&1 || return 1
    body="$(cat <<'EOF'
Retain verified, reusable guidance and lessons from completed development and review sessions.

The update was generated only for new or corrected repository facts after a confirmed merge. Local environment information and credential references remain in ignored local files.

Validation: scoped documentation targets, exact legacy replacements, credential/identifier scan, and git diff --check passed before the isolated documentation commit. Review the resulting guidance and evidence before merging.
EOF
)"
    # Creation stdout is provider-specific and optional. A normalized read is
    # the durable identity, including when creation succeeded before a crash.
    chp_create_pr "$branch" 'docs(knowledge): retain verified session lessons' "$body" >/dev/null || return 1
    existing="$(chp_pr_list all 'number,headRefName,headRefOid')" || return 1
    jq -e 'type == "array"' >/dev/null <<<"$existing" || return 1
    match_count="$(jq --arg branch "$branch" '[.[] | select(.headRefName == $branch)] | length' <<<"$existing")"
  fi
  [[ "$match_count" == 1 ]] || return 1
  jq -e --arg branch "$branch" --arg commit "$commit" \
    '.[] | select(.headRefName == $branch) | .headRefOid == $commit' >/dev/null <<<"$existing" || return 1
  number="$(jq -r --arg branch "$branch" '.[] | select(.headRefName == $branch) | .number' <<<"$existing")"
  bash "$helper" --repo "$PROJECT_DIR" published --task "issue-${issue}" --merged-pr "$pr" --digest "$digest" --pr "$number" >/dev/null
}
