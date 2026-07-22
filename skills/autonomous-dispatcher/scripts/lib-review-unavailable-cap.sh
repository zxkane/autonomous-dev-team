#!/bin/bash
# lib-review-unavailable-cap.sh - INV-144 all-unavailable review breaker.
#
# This is a sibling of INV-127, not an extension of it. INV-127 counts decided
# substantive failures with a live P0/P1 finding. This breaker counts
# consecutive review rounds in which every fan-out member was unavailable and
# no agent produced a deciding verdict.
#
# Marker grammar:
#   <!-- dispatcher-review-unavailable-breaker: issue=<N> head=<sha> round=<n> -->

_review_unavailable_marker() {
  local issue="$1" head="${2:-unknown}" round="$3"
  [[ -n "$head" ]] || head="unknown"
  printf '<!-- dispatcher-review-unavailable-breaker: issue=%s head=%s round=%s -->' \
    "$issue" "$head" "$round"
}

_review_unavailable_reset_marker() {
  _review_unavailable_marker "$1" "${2:-}" 0
}

# Append one classified INV-64 smoke reason to the evidence carried into an
# eventual all-unavailable trip report. Both full and partial smoke-drop paths
# use this formatter so the terminal route sees one stable channel.
_review_unavailable_add_smoke_reason() {
  local agent="$1" reason="${2:-}"
  [[ -n "$reason" ]] || return 0
  _smoke_reasons+="${agent}: smoke: ${reason}; "
}

_review_unavailable_uint_le() {
  local value="$1" maximum="$2"
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  [[ "${#value}" -lt "${#maximum}" ]] && return 0
  [[ "${#value}" -eq "${#maximum}" && "$value" < "$maximum" || "$value" == "$maximum" ]]
}

_review_unavailable_parse_count() {
  local marker_text="$1" parsed
  local pattern="dispatcher-review-unavailable-breaker: issue=[0-9]+ head=.* round=([0-9]+)"
  if [[ "$marker_text" =~ $pattern ]]; then
    parsed="${BASH_REMATCH[1]}"
    if _review_unavailable_uint_le "$parsed" 9223372036854775807; then
      printf '%s\n' "$parsed"
    else
      printf '0\n'
    fi
  else
    printf '0\n'
  fi
}

_review_unavailable_next_count() {
  local marker_text="$1" stored
  stored=$(_review_unavailable_parse_count "$marker_text")
  if [[ "$stored" == "9223372036854775807" ]]; then
    printf '%s\n' "$stored"
  else
    printf '%s\n' "$((stored + 1))"
  fi
}

# REVIEW_UNAVAILABLE_CAP=0 explicitly disables this breaker. Positive values,
# including 1, are valid up to Bash's signed arithmetic ceiling. Malformed or
# unrepresentable values fall back to the default of 3.
_review_unavailable_threshold() {
  local raw="${REVIEW_UNAVAILABLE_CAP:-3}"
  if ! _review_unavailable_uint_le "$raw" 9223372036854775807; then
    echo "WARNING: REVIEW_UNAVAILABLE_CAP='${raw}' invalid (must be a non-negative signed 64-bit integer) - falling back to default 3" >&2
    printf '3\n'
    return 0
  fi
  printf '%s\n' "$raw"
}

# Return the latest self-authored standalone marker for the active issue after
# both durable re-arm cutoffs: the latest self-authored trip report and the
# latest stalled-label removal. The removal cutoff survives failure of every
# post-transition comment write. A round=0 reset marker participates in the
# ordinary latest-marker scan and therefore makes the next unavailable round
# start at 1 without waiting for the label-event read.
_review_unavailable_prior_marker() {
  local comments_json="$1" issue="$2" stalled_removed_at="${3:-}"
  jq -r --arg issue "$issue" --arg stalled_removed_at "$stalled_removed_at" '
    ([.[] | select(.authorKind == "self") | select(.body | type == "string")]) as $rows
    | (([$rows[]
        | select(.body | startswith("## Review-unavailable-cap circuit-breaker tripped - halting repeated re-dispatch (`reason=review-unavailable-cap`, INV-144)\n"))
       ] | sort_by(.createdAt // "", .id // 0) | last)
       // {createdAt:"1970-01-01T00:00:00Z",id:0}) as $trip_cutoff
    | (if $stalled_removed_at == ""
       then {createdAt:"1970-01-01T00:00:00Z",id:0}
       else {createdAt:$stalled_removed_at,id:9223372036854775807}
       end) as $removal_cutoff
    | ([$trip_cutoff, $removal_cutoff]
       | sort_by(.createdAt // "", .id // 0) | last) as $rearm_cutoff
    | ([$rows[]
        | select(
            ((.createdAt // "") > ($rearm_cutoff.createdAt // ""))
            or (
              ((.createdAt // "") == ($rearm_cutoff.createdAt // ""))
              and ((.id // 0) > ($rearm_cutoff.id // 0))
            )
          )
        | select(.body | type == "string")
        | select(.body | test(
            "^<!--[[:space:]]*dispatcher-review-unavailable-breaker:[[:space:]]*issue="
            + $issue
            + " head=[^ ]+ round=[0-9]+[[:space:]]*-->[[:space:]]*$"
          ))]
       | sort_by(.createdAt // "", .id // 0) | last | .body // "")
  ' <<<"$comments_json" 2>/dev/null || printf ''
}

# Post the independent durable reset for a decided pass/fail aggregate. Resets
# remain active while REVIEW_UNAVAILABLE_CAP=0 so a decided round that occurs
# during a disabled interval cannot leave a stale streak for later re-enabling.
_review_unavailable_reset_if_decided() {
  local aggregate="$1" issue="$2" head="${3:-}"
  [[ "$aggregate" == "pass" || "$aggregate" == "fail" ]] || return 0
  # Best-effort independent reset channel; a comment outage must not rewrite
  # the already-decided aggregate's routing.
  itp_post_comment "$issue" "$(_review_unavailable_reset_marker "$issue" "$head")" \
    2>/dev/null || true
}

# _review_unavailable_breaker_handle <issue> <head> <pr> <drop-reasons> <smoke-reasons>
#
# Sets REVIEW_UNAVAILABLE_BREAKER_ACTION to continue, stalled,
# already-stalled, or state-unreadable. On a trip, the state transition is
# intentionally the first write. RESULT_PARSED is set immediately after it
# lands and before the best-effort report post.
_review_unavailable_breaker_handle() {
  local issue="$1" head="${2:-}" pr="${3:-}" drop_reasons="${4:-}" smoke_reasons="${5:-}"
  local threshold task_json already_stalled comments_json stalled_removed_at
  local prior_marker next_count marker
  local drop_text smoke_text mention

  REVIEW_UNAVAILABLE_BREAKER_ACTION="continue"
  threshold=$(_review_unavailable_threshold)

  # Fail closed when sibling ownership cannot be read. Provider transitions
  # are unconditional label edits, so continuing could add pending-dev to an
  # already-stalled issue or post a duplicate trip report.
  if ! task_json=$(itp_read_task "$issue" labels 2>/dev/null) \
    || ! already_stalled=$(jq -r '
      if type == "object"
         and (.labels | type) == "array"
         and all(.labels[]; type == "string")
      then
        (.labels | any(. == "stalled"))
      else
        error("invalid label envelope")
      end
    ' <<<"$task_json" 2>/dev/null) \
    || [[ "$already_stalled" != "true" && "$already_stalled" != "false" ]]; then
    log "WARNING: INV-144 could not read issue #${issue} labels; suppressing unavailable-cap and pending-dev writes for this run."
    RESULT_PARSED=true
    REVIEW_UNAVAILABLE_BREAKER_ACTION="state-unreadable"
    return 0
  fi
  if [[ "$already_stalled" == "true" ]]; then
    log "INV-144: issue #${issue} is already stalled by a sibling breaker; skipping unavailable-cap writes and the ordinary pending-dev route."
    RESULT_PARSED=true
    REVIEW_UNAVAILABLE_BREAKER_ACTION="already-stalled"
    return 0
  fi

  # Disabling the counter does not disable the sibling-stall guard. A live
  # wrapper must never overwrite another breaker's terminal state.
  [[ "$threshold" -gt 0 ]] || return 0

  # A comment-read failure starts a fresh streak instead of inheriting an
  # unverified count and prematurely stalling.
  comments_json=$(ITP_REQUIRE_SELF_AUTHOR=1 itp_list_comments "$issue" 2>/dev/null || echo "[]")
  # The latest explicit stalled-label removal is an independent re-arm cutoff.
  # It remains observable even when every threshold/reset/report comment after
  # the prior stalled transition failed to post.
  stalled_removed_at=$(itp_label_event_ts "$issue" "stalled" "latest-removed" 2>/dev/null || true)
  prior_marker=$(_review_unavailable_prior_marker \
    "$comments_json" "$issue" "$stalled_removed_at")
  next_count=$(_review_unavailable_next_count "$prior_marker")
  marker=$(_review_unavailable_marker "$issue" "$head" "$next_count")

  if [[ "$next_count" -lt "$threshold" ]]; then
    # Marker persistence is best-effort; a post outage retains the established
    # pending-dev route and cannot manufacture a threshold trip.
    itp_post_comment "$issue" "$marker" 2>/dev/null || true
    log "INV-144: unavailable review round ${next_count}/${threshold} recorded; retaining the existing pending-dev retry route."
    return 0
  fi

  log "INV-144 review-unavailable-cap breaker TRIPPED: round=${next_count} threshold=${threshold}; transitioning to stalled."
  itp_transition_state "$issue" "reviewing" "stalled"
  RESULT_PARSED=true
  REVIEW_UNAVAILABLE_BREAKER_ACTION="stalled"

  # Persist the threshold round, then independently re-arm the next operator-
  # initiated streak. The reset marker remains effective if the structured
  # report post fails; a successful report is a second, independent cutoff.
  itp_post_comment "$issue" "$marker" 2>/dev/null || true
  itp_post_comment "$issue" "$(_review_unavailable_reset_marker "$issue" "$head")" \
    2>/dev/null || true

  drop_text="${drop_reasons%; }"
  [[ -n "$drop_text" ]] || drop_text="no reason token recorded"
  smoke_text="${smoke_reasons%; }"
  [[ -n "$smoke_text" ]] || smoke_text="none recorded"
  mention=$(resolve_escalation_mention "$issue" "$pr")

  # The stalled transition is authoritative; a report outage must not re-open
  # the ordinary pending-dev route.
  itp_post_comment "$issue" "$(cat <<REPORT
## Review-unavailable-cap circuit-breaker tripped - halting repeated re-dispatch (\`reason=review-unavailable-cap\`, INV-144)

This review reached **${next_count}** consecutive \`all-unavailable\` rounds
(threshold ${threshold}). No fan-out member produced a deciding verdict, so
re-dispatch is halted for operator investigation.

**Dispatcher actions taken**
- Transitioned the issue from \`reviewing\` to \`stalled\`.
- Retained \`autonomous\`; removing \`stalled\` explicitly re-arms a fresh streak.
- Suppressed the ordinary \`pending-dev\` transition for this round.

**Evidence**
- PR: #${pr:-<none>}
- Current PR head: \`${head:-<unknown>}\`
- Consecutive all-unavailable rounds: **${next_count}**
- Fan-out drop reasons: ${drop_text}
- Pre-fan-out smoke reasons: ${smoke_text}

**Human action needed** - inspect the review-agent launch, capacity, and verdict
delivery paths, restore at least one deciding reviewer, then remove \`stalled\`.
${mention}
REPORT
)" 2>/dev/null || true # Report failure cannot re-open the pending-dev route.
}

# Run the production terminal decision and leave the result in
# REVIEW_UNAVAILABLE_BREAKER_ACTION. Call this as a bare command: putting the
# state-changing handler in an if-condition would suppress errexit inside it and
# could mask a failed reviewing -> stalled transition.
_review_unavailable_terminal_route() {
  _review_unavailable_breaker_handle "$@"
  if [[ "$REVIEW_UNAVAILABLE_BREAKER_ACTION" != "continue" ]]; then
    log "Review complete (${REVIEW_UNAVAILABLE_BREAKER_ACTION}, INV-144)."
  fi
}
