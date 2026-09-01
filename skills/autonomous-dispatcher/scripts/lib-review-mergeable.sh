#!/bin/bash
# lib-review-mergeable.sh — INV-44 wrapper-enforced mergeable hard gate
# (issue #176).
#
# A PR that is CONFLICTING with its base branch can still receive a PASS verdict
# from the review agent — the mergeable check lives only in the agent's Step-0
# prompt, which the agent is trusted (but not forced) to run. This library owns
# the pure mergeability classifiers plus the provider-neutral preflight,
# post-fan-out HEAD validation, and canonical durable routing actions. A
# CONFLICTING PR can never reach `approved` regardless of whether the agent ran
# Step 0.
#
# The provider I/O remains behind `chp_*` / `itp_*` seams. The wrapper selects
# when each phase runs; this library keeps polling, pin validation, and required
# writes shared so preflight and INV-44 cannot drift.

# _classify_mergeable_gate <mergeable>
#
# Maps a GitHub PR `mergeable` field value to one of three gate actions:
#
#   proceed              — the PR is mergeable; the wrapper's existing PASS
#                          branch (approve + merge) runs unchanged.
#   block-substantive    — the PR CONFLICTs with base; a real, dev-actionable
#                          finding. The wrapper posts a [BLOCKING] merge-conflict
#                          finding + an `Auto-merge failed:` marker (reusing the
#                          dev-resume rebase hook) and routes to pending-dev.
#   block-nonsubstantive — mergeable is UNKNOWN (GitHub still computing), empty
#                          (the `gh` query failed), or any unrecognized token.
#                          The wrapper re-queues (routes to pending-dev with a
#                          non-substantive trailer) rather than auto-approving.
#
# Conservative by construction: the ONLY input that yields `proceed` is a
# case-insensitive `MERGEABLE`. Every other value blocks — this is what closes
# the stale-UNKNOWN pass-through (a status GitHub hasn't resolved can never be
# silently treated as mergeable). Returns 0 always; the decision is on stdout.
_classify_mergeable_gate() {
  # Uppercase for a case-insensitive compare against GitHub's documented enum
  # values (MERGEABLE / CONFLICTING / UNKNOWN).
  local mergeable="${1:-}"
  local upper="${mergeable^^}"

  case "$upper" in
    MERGEABLE)
      printf 'proceed\n'
      ;;
    CONFLICTING)
      printf 'block-substantive\n'
      ;;
    *)
      # UNKNOWN, empty, or anything unexpected → never proceed.
      printf 'block-nonsubstantive\n'
      ;;
  esac
}

# _pr_open_gate <state> (INV-54, issue #196)
#
# Maps a GitHub PR `state` field value to a gate decision used at the TOP of the
# `PASSED_VERDICT == true` chain — BEFORE the mergeable hard gate and the PASS
# approve/merge branch:
#
#   proceed — the PR is OPEN; run the mergeable gate + PASS branch as before.
#   skip    — the PR is no longer open (merged/closed out-of-band, or its state
#             could not be determined). The wrapper cleans `-reviewing` and exits
#             WITHOUT adding `pending-dev`, so an already-merged/closed issue is
#             never flipped back into the dev queue.
#
# This is the exact inverse of the existing PASS-branch guard's `!= OPEN` test,
# hoisted so it covers ALL three PASS-chain exits (block-substantive,
# block-nonsubstantive, PASS) with a single check. Before this gate, the
# open-check lived only in the PASS branch, so a PR merged out-of-band that then
# took an INV-44 block branch flipped its closed issue to `pending-dev` (the
# #191 self-merge incident; carved out of #193).
#
# Conservative by construction: the ONLY input that yields `proceed` is a
# case-insensitive `OPEN`. UNKNOWN (the wrapper's failed-`gh`-query sentinel),
# empty, CLOSED, MERGED, and any unexpected token all → `skip`, matching the
# PASS-branch guard which treated a failed query as non-OPEN. Returns 0 always;
# the decision is on stdout.
_pr_open_gate() {
  local state="${1:-}"
  if [[ "${state^^}" == "OPEN" ]]; then
    printf 'proceed\n'
  else
    printf 'skip\n'
  fi
}

# INV-147 dependencies are loaded lazily so this library remains independently
# sourceable in focused tests.
_lrm_self="${BASH_SOURCE[0]:-$0}"
_lrm_dir="$(cd "$(dirname "$(readlink -f "$_lrm_self")")" && pwd 2>/dev/null)" \
  || _lrm_dir=""
if ! declare -F chp_pr_view >/dev/null 2>&1; then
  if [[ -n "$_lrm_dir" && -r "${_lrm_dir}/lib-code-host.sh" ]]; then
    # shellcheck source=lib-code-host.sh
    source "${_lrm_dir}/lib-code-host.sh"
  fi
fi
if ! declare -F itp_list_comments >/dev/null 2>&1; then
  if [[ -n "$_lrm_dir" && -r "${_lrm_dir}/lib-issue-provider.sh" ]]; then
    # shellcheck source=lib-issue-provider.sh
    source "${_lrm_dir}/lib-issue-provider.sh"
  fi
fi
if ! declare -F _review_disposition_marker >/dev/null 2>&1; then
  if [[ -n "$_lrm_dir" && -r "${_lrm_dir}/lib-review-disposition.sh" ]]; then
    # shellcheck source=lib-review-disposition.sh
    source "${_lrm_dir}/lib-review-disposition.sh"
  fi
fi
if ! declare -F emit_verdict_trailer_required >/dev/null 2>&1; then
  if [[ -n "$_lrm_dir" && -r "${_lrm_dir}/lib-review-verdict.sh" ]]; then
    # shellcheck source=lib-review-verdict.sh
    source "${_lrm_dir}/lib-review-verdict.sh"
  fi
fi
if ! declare -F _review_round_marker >/dev/null 2>&1; then
  if [[ -n "$_lrm_dir" && -r "${_lrm_dir}/lib-review-round.sh" ]]; then
    # shellcheck source=lib-review-round.sh
    source "${_lrm_dir}/lib-review-round.sh"
  fi
fi
unset _lrm_self _lrm_dir

_review_optional_run_footer() {
  if declare -F run_footer >/dev/null 2>&1; then
    run_footer
  fi
}

_review_poll_mergeable() {
  local pr="$1" out_var="$2" read_failure_var="${3:-}"
  local retries="${MERGEABLE_RETRIES:-3}" delay="${MERGEABLE_RETRY_DELAY_SECONDS:-10}"
  local attempt _rpm_status="" _rpm_rc=0 _rpm_had_read_failure=0
  [[ "$retries" =~ ^[1-9][0-9]*$ ]] || retries=3
  [[ "$delay" =~ ^[0-9]+$ ]] || delay=10

  for ((attempt = 1; attempt <= retries; attempt++)); do
    # A provider read failure is classified like an empty UNKNOWN response.
    _rpm_rc=0
    _rpm_status=$(chp_mergeable "$pr" 2>/dev/null) || _rpm_rc=$?
    if [[ "$_rpm_rc" -ne 0 ]]; then
      _rpm_had_read_failure=1
      _rpm_status=""
    fi
    [[ "$(_classify_mergeable_gate "$_rpm_status")" != "block-nonsubstantive" ]] \
      && break
    if [[ "$attempt" -lt "$retries" ]]; then
      if declare -F log >/dev/null 2>&1; then
        log "PR #${pr} mergeable status is '${_rpm_status:-<empty>}' (attempt ${attempt}/${retries}); waiting for the provider to settle..."
      fi
      [[ "$delay" == "0" ]] || sleep "$delay"
    fi
  done
  printf -v "$out_var" '%s' "$_rpm_status"
  if [[ -n "$read_failure_var" ]]; then
    printf -v "$read_failure_var" '%s' "$_rpm_had_read_failure"
  fi
}

_review_pr_snapshot() {
  local pr="$1" state_var="$2" head_var="$3" branch_var="$4"
  local snapshot _rps_state _rps_head _rps_branch
  snapshot=$(chp_pr_view "$pr" "state,headRefOid,headRefName" 2>/dev/null) \
    || return 1
  jq -e '
    type == "object"
    and (.state | type == "string")
    and (.headRefOid | type == "string")
    and (.headRefName | type == "string")
  ' >/dev/null 2>&1 <<<"$snapshot" || return 1

  _rps_state=$(jq -r '.state' <<<"$snapshot")
  _rps_head=$(jq -r '.headRefOid' <<<"$snapshot")
  _rps_branch=$(jq -r '.headRefName' <<<"$snapshot")
  case "${_rps_state^^}" in
    OPEN|CLOSED|MERGED)
      _rps_state="${_rps_state^^}"
      ;;
    *)
      # An empty or provider-unknown state is not evidence that the PR closed.
      # Fail the snapshot so callers take the non-substantive read-failure path.
      return 1
      ;;
  esac
  printf -v "$state_var" '%s' "$_rps_state"
  printf -v "$head_var" '%s' "$_rps_head"
  printf -v "$branch_var" '%s' "$_rps_branch"
}

review_validate_pinned_pr() {
  local pr="$1" expected_head="$2"
  local state_var="$3" head_var="$4" branch_var="$5" action_var="$6"
  local _rvp_state="" _rvp_head="" _rvp_branch=""
  local _rvp_expected="" _rvp_current=""

  printf -v "$state_var" '%s' ""
  printf -v "$head_var" '%s' ""
  printf -v "$branch_var" '%s' ""
  printf -v "$action_var" '%s' "read-failed"

  if ! _review_pr_snapshot "$pr" _rvp_state _rvp_head _rvp_branch; then
    return 0
  fi
  printf -v "$state_var" '%s' "$_rvp_state"
  printf -v "$head_var" '%s' "$_rvp_head"
  printf -v "$branch_var" '%s' "$_rvp_branch"

  if [[ "$(_pr_open_gate "$_rvp_state")" == "skip" ]]; then
    printf -v "$action_var" '%s' "closed"
    return 0
  fi

  _rvp_expected="$(_review_normalize_full_head "$expected_head")" || return 0
  _rvp_current="$(_review_normalize_full_head "$_rvp_head")" || return 0
  printf -v "$head_var" '%s' "$_rvp_current"
  if [[ "$_rvp_current" != "$_rvp_expected" ]]; then
    printf -v "$action_var" '%s' "head-changed"
    return 0
  fi
  printf -v "$action_var" '%s' "proceed"
}

# review_refresh_mergeability
#   PR EXPECTED_HEAD HEAD_OUT STATUS_OUT ACTION_OUT
#
# Revalidates mutable mergeability against provider snapshots of the same open
# HEAD. It uses the same bounded settling poll as review preflight, but preserves
# whether any provider read failed. A terminal UNKNOWN requires every attempted
# read to succeed; a poll containing only UNKNOWN/read-failure outcomes remains
# operationally unreadable rather than fabricating fresh terminal evidence.
#
# ACTION_OUT uses the review preflight action vocabulary: proceed,
# conflict-rebase, mergeable-unknown, closed, head-changed, or read-failed.
review_refresh_mergeability() {
  local pr="$1" expected_head="$2"
  local head_var="$3" status_var="$4" action_var="$5"
  local state="" head="" branch="" action=""
  local status="" had_read_failure=0

  printf -v "$head_var" '%s' ""
  printf -v "$status_var" '%s' ""
  printf -v "$action_var" '%s' "read-failed"

  review_validate_pinned_pr "$pr" "$expected_head" \
    state head branch action
  printf -v "$head_var" '%s' "$head"
  if [[ "$action" != "proceed" ]]; then
    printf -v "$action_var" '%s' "$action"
    return 0
  fi

  _review_poll_mergeable "$pr" status had_read_failure

  review_validate_pinned_pr "$pr" "$head" \
    state head branch action
  printf -v "$head_var" '%s' "$head"
  printf -v "$status_var" '%s' "$status"
  if [[ "$action" != "proceed" ]]; then
    printf -v "$action_var" '%s' "$action"
    return 0
  fi
  case "$(_classify_mergeable_gate "$status")" in
    proceed) printf -v "$action_var" '%s' "proceed" ;;
    block-substantive)
      printf -v "$action_var" '%s' "conflict-rebase"
      ;;
    *)
      if [[ "$had_read_failure" == "0" ]]; then
        printf -v "$action_var" '%s' "mergeable-unknown"
      fi
      ;;
  esac
}

# review_mergeability_preflight PR STATE_OUT HEAD_OUT BRANCH_OUT STATUS_OUT ACTION_OUT
#
# ACTION_OUT is one of proceed, conflict-rebase, mergeable-unknown, closed,
# head-changed, or read-failed. Terminal actions are returned only after a
# second state+HEAD snapshot proves the decision still belongs to one open HEAD.
review_mergeability_preflight() {
  local pr="$1" state_var="$2" head_var="$3" branch_var="$4"
  local status_var="$5" action_var="$6"
  local initial_state="" initial_head="" initial_branch=""
  local final_state="" final_head="" final_branch="" final_action=""
  local status="" action="" normalized_initial=""

  printf -v "$state_var" '%s' ""
  printf -v "$head_var" '%s' ""
  printf -v "$branch_var" '%s' ""
  printf -v "$status_var" '%s' ""
  printf -v "$action_var" '%s' "read-failed"

  if ! _review_pr_snapshot "$pr" initial_state initial_head initial_branch; then
    return 0
  fi
  printf -v "$state_var" '%s' "$initial_state"
  printf -v "$branch_var" '%s' "$initial_branch"

  if [[ "$(_pr_open_gate "$initial_state")" == "skip" ]]; then
    printf -v "$action_var" '%s' "closed"
    return 0
  fi
  normalized_initial="$(_review_normalize_full_head "$initial_head")" || return 0
  printf -v "$head_var" '%s' "$normalized_initial"

  _review_poll_mergeable "$pr" status

  review_validate_pinned_pr "$pr" "$normalized_initial" \
    final_state final_head final_branch final_action
  [[ -n "$final_state" ]] && printf -v "$state_var" '%s' "$final_state"
  printf -v "$status_var" '%s' "$status"
  [[ -n "$final_branch" ]] && printf -v "$branch_var" '%s' "$final_branch"

  if [[ "$final_action" != "proceed" ]]; then
    printf -v "$action_var" '%s' "$final_action"
    return 0
  fi

  case "$(_classify_mergeable_gate "$status")" in
    proceed) action="proceed" ;;
    block-substantive) action="conflict-rebase" ;;
    *) action="mergeable-unknown" ;;
  esac
  printf -v "$action_var" '%s' "$action"
}

_review_issue_comment_exists() {
  local issue="$1" body="$2" comments
  comments=$(ITP_REQUIRE_SELF_AUTHOR=1 itp_list_comments "$issue" 2>/dev/null) \
    || return 2
  jq -e --arg body "$body" \
    'any(.[]; .authorKind == "self" and .body == $body)' \
    >/dev/null 2>&1 <<<"$comments"
}

_review_ensure_issue_comment() {
  local issue="$1" body="$2" exists_rc=0
  _review_issue_comment_exists "$issue" "$body" || exists_rc=$?
  [[ "$exists_rc" -eq 0 ]] && return 0
  [[ "$exists_rc" -eq 1 ]] || return 1
  itp_post_comment "$issue" "$body" >/dev/null 2>&1
}

_review_ensure_disposition() {
  local issue="$1" head="$2" result="$3"
  local marker comments candidates
  marker="$(_review_disposition_marker "$issue" "$head" "$result")" || return 1
  comments=$(ITP_REQUIRE_SELF_AUTHOR=1 \
    itp_list_comments "$issue" 2>/dev/null) || return 1
  candidates="$(_review_routing_candidates_from_comments "$comments" "$issue")" \
    || return 1
  if jq -e --arg head "$head" --arg result "$result" '
      any(.[];
        .kind == "disposition"
        and .head == $head
        and .result == $result
      )
    ' >/dev/null 2>&1 <<<"$candidates"; then
    return 0
  fi
  itp_post_comment "$issue" "$marker" >/dev/null 2>&1
}

_review_issue_marker_exists() {
  local issue="$1" marker="$2" comments
  comments=$(ITP_REQUIRE_SELF_AUTHOR=1 itp_list_comments "$issue" 2>/dev/null) \
    || return 2
  jq -e --arg marker "$marker" '
    any(.[]
      | select(.authorKind == "self")
      | select(.body | type == "string");
      .body | contains($marker)
    )
  ' >/dev/null 2>&1 <<<"$comments"
}

_review_ensure_issue_marker_comment() {
  local issue="$1" marker="$2" body="$3" exists_rc=0
  _review_issue_marker_exists "$issue" "$marker" || exists_rc=$?
  [[ "$exists_rc" -eq 0 ]] && return 0
  [[ "$exists_rc" -eq 1 ]] || return 1
  itp_post_comment "$issue" "$body" >/dev/null 2>&1
}

_review_reviewed_head_exists() {
  local issue="$1" head="$2" comments candidates
  comments=$(ITP_REQUIRE_SELF_AUTHOR=1 itp_list_comments "$issue" 2>/dev/null) \
    || return 2
  head="$(_review_normalize_full_head "$head")" || return 2
  candidates="$(_review_routing_candidates_from_comments "$comments" "$issue")" \
    || return 2
  jq -e --arg head "$head" '
    any(.[]; .kind == "reviewed-head" and .head == $head)
  ' >/dev/null 2>&1 <<<"$candidates"
}

_review_ensure_reviewed_head() {
  local issue="$1" head="$2" exists_rc=0
  _review_reviewed_head_exists "$issue" "$head" || exists_rc=$?
  [[ "$exists_rc" -eq 0 ]] && return 0
  [[ "$exists_rc" -eq 1 ]] || return 1
  itp_post_comment "$issue" \
    "Reviewed HEAD: \`${head}\` (issue #${issue}, phase \`post-fanout-conflict\`)" \
    >/dev/null 2>&1
}

_review_ensure_pr_conflict_marker() {
  local pr="$1" issue="$2" head="$3" body="$4" comments existing
  comments=$(chp_pr_view "$pr" "comments" 2>/dev/null) || return 1
  existing="$(_review_pr_recovery_comment_from_comments \
    "$comments" "$issue" "$head" conflict)" || return 1
  [[ -z "$existing" ]] || return 0
  chp_pr_comment "$pr" --body "$body" >/dev/null 2>&1
}

_review_required_verdict_exists() {
  local issue="$1" head="$2" result="$3" phase="$4" trailer="$5"
  local comments timeline anchor routing_boundary
  comments=$(ITP_REQUIRE_SELF_AUTHOR=1 itp_list_comments "$issue" 2>/dev/null) \
    || return 2
  timeline="$(_review_strict_self_comment_timeline "$comments")" || return 2
  if [[ "$phase" == "pre-fanout" ]]; then
    anchor="$(_review_disposition_marker "$issue" "$head" "$result")" || return 2
  else
    anchor="Reviewed HEAD: \`${head}\`"
  fi
  routing_boundary="$(_review_routing_evidence_boundary_from_comments \
    "$comments" "$issue")" || return 2

  jq -e \
    --arg anchor "$anchor" \
    --arg trailer "$trailer" \
    --arg phase "$phase" \
    --arg head "$head" \
    --argjson routing_boundary "$routing_boundary" '
    [to_entries[] | select(.value.body | type == "string")] as $all
    | ([$all[]
        | select(
            if $phase == "pre-fanout"
            then .value.body == $anchor
            else (.value.body | startswith($anchor))
            end
          )
        | .key] | last // -1) as $anchor_i
    | ([$all[]
        | select(
            .value.body
            | contains("no-progress-substantive-attempt:" + $head)
          )
        | .key] | last // -1) as $attempt_i
    | ([$anchor_i, $attempt_i, $routing_boundary] | max) as $boundary_i
    | ([$all[]
        | select(.key > $boundary_i)
        | select(.value.body | type == "string")
        | select(
            (.value.body | startswith("<!-- review-verdict: "))
            and (.value.body | endswith(" -->"))
          )
        | .key] | last // -1) as $verdict_i
    | $anchor_i >= 0
      and $verdict_i > $boundary_i
      and $all[$verdict_i].value.body == $trailer
  ' >/dev/null 2>&1 <<<"$timeline"
}

_review_ensure_required_verdict() {
  local issue="$1" head="$2" result="$3" phase="$4"
  local verdict="$5" cause="${6:-}" dev_actionable="${7:-true}" trailer exists_rc=0
  trailer="$(_render_review_verdict_trailer \
    "$verdict" "$cause" "$dev_actionable" "$head")" \
    || return 1
  _review_required_verdict_exists "$issue" "$head" "$result" "$phase" "$trailer" \
    || exists_rc=$?
  [[ "$exists_rc" -eq 0 ]] && return 0
  [[ "$exists_rc" -eq 1 ]] || return 1
  emit_verdict_trailer_required \
    "$issue" "${REPO:-}" "$verdict" "$cause" "$dev_actionable" "$head"
}

# Required same-HEAD evidence and transition for a non-conflict pre-fan-out E2E
# failure. Return codes mirror the conflict route: 20 required write failed,
# 21 transition failed. Native request-changes remains wrapper-owned and
# best-effort; it does not own durable routing.
_review_route_e2e_failure() {
  local issue="$1" head="$2" dev_actionable="$3"
  head="$(_review_normalize_full_head "$head")" || return 20
  [[ "$dev_actionable" == "true" || "$dev_actionable" == "false" ]] || return 20
  _review_ensure_disposition "$issue" "$head" "e2e-failed" || return 20
  _review_ensure_required_verdict \
    "$issue" "$head" "e2e-failed" "pre-fanout" \
    "failed-substantive" "" "$dev_actionable" || return 20
  itp_transition_state "$issue" "reviewing" "pending-dev" >/dev/null 2>&1 \
    || return 21
}

# Return codes: 0 routed, 20 required write failed, 21 transition failed.
_review_route_conflict() {
  local issue="$1" pr="$2" head="$3" branch="$4" base="$5" phase="$6"
  local conflict_marker finding_marker finding_body pr_body
  head="$(_review_normalize_full_head "$head")" || return 20
  [[ "$phase" == "pre-fanout" || "$phase" == "post-fanout" ]] || return 20

  conflict_marker="$(_review_auto_merge_conflict_marker "$issue" "$head")" \
    || return 20
  finding_marker="<!-- merge-conflict-finding: issue=${issue} head=${head} result=conflict-rebase -->"
  finding_body="Review findings:

Findings->Decision Gate: 1 blocking finding(s) -- FAIL.

1. **[BLOCKING] Merge conflict with ${base}** — PR #${pr} (\`${branch:-the PR branch}\`) is \`CONFLICTING\` with the base branch and cannot be merged. The wrapper mergeability gate (a merge-conflict gate — not a CI-status gate; see INV-134 for the CI-rollup counterpart) requires a rebase before the next review or merge attempt.
   - Dev agent must run \`git fetch origin ${base}\`, \`git rebase origin/${base}\`, resolve safely, and \`git push --force-with-lease origin ${branch:-<PR_BRANCH>}\`.
${finding_marker}$(_review_optional_run_footer)"
  if [[ "$phase" == "post-fanout" ]]; then
    # INV-04 remains the post-fan-out routing anchor. The ordinary fan-out post
    # is best-effort, so repair it here before a conflict can reach pending-dev.
    _review_ensure_reviewed_head "$issue" "$head" || return 20
  fi

  _review_ensure_issue_marker_comment \
    "$issue" "$finding_marker" "$finding_body" || return 20

  if [[ "$phase" == "pre-fanout" ]]; then
    _review_ensure_disposition "$issue" "$head" "conflict-rebase" || return 20
  fi

  pr_body="Auto-merge failed: PR is CONFLICTING with ${base}. Re-dispatching dev agent to rebase onto ${base}; this marker is bound to HEAD ${head}.$(_review_optional_run_footer)

${conflict_marker}"
  _review_ensure_pr_conflict_marker \
    "$pr" "$issue" "$head" "$pr_body" || return 20
  _review_ensure_required_verdict \
    "$issue" "$head" "conflict-rebase" "$phase" "failed-substantive" "" \
    || return 20

  if declare -F submit_request_changes >/dev/null 2>&1; then
    # Native review state is best-effort; durable issue/PR evidence owns routing.
    submit_request_changes "$pr" \
      "Merge conflict with ${base}: PR \`${branch:-the PR branch}\` is CONFLICTING. Rebase onto ${base} before re-review." \
      >/dev/null 2>&1 || true
  fi
  itp_transition_state "$issue" "reviewing" "pending-dev" >/dev/null 2>&1 \
    || return 21
}

# Return codes mirror _review_route_conflict.
_review_route_mergeable_unknown() {
  local issue="$1" head="$2" hold_body
  head="$(_review_normalize_full_head "$head")" || return 20
  hold_body="Review held: mergeability remained UNKNOWN after the bounded preflight on HEAD \`${head}\`; E2E and review fan-out were skipped and the existing non-substantive retry cap will re-evaluate it.$(_review_optional_run_footer)"
  # The explanatory hold is best-effort; disposition and verdict are required.
  _review_ensure_issue_comment "$issue" "$hold_body" >/dev/null 2>&1 || true
  _review_ensure_disposition "$issue" "$head" "mergeable-unknown" || return 20
  _review_ensure_required_verdict \
    "$issue" "$head" "mergeable-unknown" "pre-fanout" \
    "failed-non-substantive" "mergeable-unknown" || return 20
  # INV-129 channel 3: reset even if the verdict cutoff later becomes unreadable.
  itp_post_comment "$issue" "$(_review_round_marker "$issue" "$head" 0)" \
    >/dev/null 2>&1 || true
  itp_transition_state "$issue" "reviewing" "pending-dev" >/dev/null 2>&1 \
    || return 21
}

_review_requeue_preflight() {
  local issue="$1" cause="$2" message="$3"
  local head="${4:-${PR_HEAD_SHA:-}}"
  # Retry diagnostics are best-effort; the state transition is authoritative.
  itp_post_comment "$issue" \
    "${message}$(_review_optional_run_footer)" \
    >/dev/null 2>&1 || true
  # A trailer outage must not replace this safe pending-review retry with a crash.
  emit_verdict_trailer "$issue" "${REPO:-}" "failed-non-substantive" "$cause" \
    >/dev/null 2>&1 || true
  # INV-129 channel 3 is independent of the best-effort trailer cutoff.
  itp_post_comment "$issue" "$(_review_round_marker "$issue" "$head" 0)" \
    >/dev/null 2>&1 || true
  itp_transition_state "$issue" "reviewing" "pending-review" >/dev/null 2>&1
}
