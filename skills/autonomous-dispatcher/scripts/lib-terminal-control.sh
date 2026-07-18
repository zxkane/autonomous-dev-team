#!/bin/bash
# lib-terminal-control.sh - durable resource terminal intents (INV-140).
#
# Issue comments are authoritative. Callers must source lib-issue-provider.sh
# first so all reads and writes stay behind the provider-neutral ITP seam.

_terminal_control_error() {
  printf 'terminal-control: %s\n' "$*" >&2
  return 1
}

_terminal_control_valid_issue() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

_terminal_control_valid_token() {
  local value="${1:-}"
  [[ "${#value}" -ge 1 && "${#value}" -le 128 ]] \
    && [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]
}

_terminal_control_comments() {
  local issue="${1:-}" comments
  if ! comments="$(ITP_REQUIRE_SELF_AUTHOR=1 itp_list_comments "$issue")"; then
    _terminal_control_error "failed to list comments for issue $issue"
    return 1 # terminal-control-branch: B001
  fi
  if ! jq -e '
      type == "array"
      and all(.[];
        type == "object"
        and (.authorKind == "self" or .authorKind == "bot" or .authorKind == "human")
        and (.body | type) == "string"
        and (.createdAt | type) == "string"
        and .id != null
      )
    ' >/dev/null 2>&1 <<<"$comments"; then
    _terminal_control_error "invalid comment envelope for issue $issue"
    return 1 # terminal-control-branch: B002
  fi
  printf '%s\n' "$comments" # terminal-control-branch: B003
}

_terminal_control_events() {
  local comments="$1"
  jq -c '
    def write_marker:
      (.value.body
       | capture("^<!-- resource-terminal-intent-v1: issue=(?<issue>[1-9][0-9]*) intent=(?<intent>[A-Za-z0-9][A-Za-z0-9._:-]{0,127}) invocation=(?<invocation>[A-Za-z0-9][A-Za-z0-9._:-]{0,127}) reason=(?<reason>token-cap|turn-cap|usage-unknown) owner=(?<owner>dispatcher|dev-wrapper|review-wrapper) -->$"))?
      | select(. != null)
      | {
          kind: "write",
          issue: .issue,
          intent: .intent,
          invocation: .invocation,
          reason: .reason,
          owner: .owner
        };
    def consume_marker:
      (.value.body
       | capture("^<!-- resource-terminal-intent-consume-v1: issue=(?<issue>[1-9][0-9]*) intent=(?<intent>[A-Za-z0-9][A-Za-z0-9._:-]{0,127}) invocation=(?<invocation>[A-Za-z0-9][A-Za-z0-9._:-]{0,127}) -->$"))?
      | select(. != null)
      | {kind: "consume", issue: .issue, intent: .intent, invocation: .invocation};
    def clear_marker:
      (.value.body
       | capture("^<!-- resource-terminal-intent-clear-v1: issue=(?<issue>[1-9][0-9]*) intent=(?<intent>[A-Za-z0-9][A-Za-z0-9._:-]{0,127}) invocation=(?<invocation>[A-Za-z0-9][A-Za-z0-9._:-]{0,127}) reason=(?<reason>[A-Za-z0-9][A-Za-z0-9._:-]{0,127}) -->$"))?
      | select(. != null)
      | {kind: "clear", issue: .issue, intent: .intent, invocation: .invocation, reason: .reason};

    [ to_entries[]
      | select(.value.authorKind == "self")
      | . as $row
      | ((write_marker) // (consume_marker) // (clear_marker))
      | . + {
          seq: $row.key,
          createdAt: $row.value.createdAt,
          commentId: $row.value.id,
          body: $row.value.body
        }
    ]
  ' <<<"$comments"
}

_terminal_control_marker_exists() {
  local events="$1" marker="$2"
  jq -e --arg marker "$marker" 'any(.[]; .body == $marker)' \
    >/dev/null 2>&1 <<<"$events"
}

_terminal_control_has_intent_write() {
  local events="$1" issue="$2" intent="$3"
  jq -e --arg issue "$issue" --arg intent "$intent" '
    any(.[];
      .kind == "write"
      and .issue == $issue
      and .intent == $intent
    )
  ' >/dev/null 2>&1 <<<"$events"
}

_terminal_control_has_generation_write() {
  local events="$1" issue="$2" intent="$3" invocation="$4"
  jq -e --arg issue "$issue" --arg intent "$intent" --arg invocation "$invocation" '
    any(.[];
      .kind == "write"
      and .issue == $issue
      and .intent == $intent
      and .invocation == $invocation
    )
  ' >/dev/null 2>&1 <<<"$events"
}

_terminal_control_target_write() {
  local events="$1" issue="$2" intent="$3"
  jq -c --arg issue "$issue" --arg intent "$intent" '
    . as $events
    | [ $events[]
      | select(
          .kind == "write"
          and .issue == $issue
          and .intent == $intent
        )
    ] as $writes
    | [ $writes[]
        | . as $write
        | select(
            ([ $writes[]
               | select(
                   .intent == $write.intent
                   and .invocation == $write.invocation
                 )
             ] | first) as $first_write
            | any($events[];
                (.kind == "consume" or .kind == "clear")
                and .issue == $issue
                and .intent == $write.intent
                and .invocation == $write.invocation
                and .seq > $first_write.seq
              ) | not
          )
      ] as $live_writes
    | (($live_writes | last) // ($writes | last))
  ' <<<"$events"
}

_terminal_control_latest_lifecycle() {
  local events="$1" issue="$2" intent="$3" invocation="$4"
  jq -c --arg issue "$issue" --arg intent "$intent" --arg invocation "$invocation" '
    ([ .[]
       | select(
           .kind == "write"
           and .issue == $issue
           and .intent == $intent
           and .invocation == $invocation
         )
     ] | first) as $first_write
    | if $first_write == null then empty
      else
        [ .[]
          | select(
              (.kind == "consume" or .kind == "clear")
              and .issue == $issue
              and .intent == $intent
              and .invocation == $invocation
              and .seq > $first_write.seq
            )
        ] | last
      end
  ' <<<"$events"
}

_terminal_control_lifecycle_is_current() {
  local events="$1" issue="$2" intent="$3" invocation="$4" marker="$5" lifecycle
  lifecycle="$(_terminal_control_latest_lifecycle \
    "$events" "$issue" "$intent" "$invocation")" \
    || return 1
  [[ -n "$lifecycle" ]] || return 1
  jq -e --arg marker "$marker" '.body == $marker' \
    >/dev/null 2>&1 <<<"$lifecycle"
}

_terminal_control_intent_is_cleared() {
  local events="$1" issue="$2" intent="$3" invocation="$4"
  jq -e --arg issue "$issue" --arg intent "$intent" --arg invocation "$invocation" '
    ([ .[]
       | select(
           .kind == "write"
           and .issue == $issue
           and .intent == $intent
           and .invocation == $invocation
         )
     ] | first) as $first_write
    | $first_write != null
      and any(.[];
        .kind == "clear"
        and .issue == $issue
        and .intent == $intent
        and .invocation == $invocation
        and .seq > $first_write.seq
      )
  ' >/dev/null 2>&1 <<<"$events"
}

_terminal_control_clear_marker_exists() {
  local events="$1" issue="$2" intent="$3" invocation="$4" marker="$5"
  jq -e --arg issue "$issue" --arg intent "$intent" \
    --arg invocation "$invocation" --arg marker "$marker" '
    ([ .[]
       | select(
           .kind == "write"
           and .issue == $issue
           and .intent == $intent
           and .invocation == $invocation
         )
     ] | first) as $first_write
    | $first_write != null
      and any(.[];
        .kind == "clear"
        and .issue == $issue
        and .intent == $intent
        and .invocation == $invocation
        and .seq > $first_write.seq
        and .body == $marker
      )
  ' >/dev/null 2>&1 <<<"$events"
}

_terminal_control_newest_retired_intent() {
  local events="$1" issue="$2"
  jq -r --arg issue "$issue" '
    ([ .[] | select(.kind == "write" and .issue == $issue) ] | last) as $write
    | if $write == null then empty
      else
        ([ .[]
           | select(
               .kind == "write"
               and .issue == $issue
               and .intent == $write.intent
               and .invocation == $write.invocation
             )
         ] | first) as $first_write
        | [ .[]
            | select(
                (.kind == "consume" or .kind == "clear")
                and .issue == $issue
                and .intent == $write.intent
                and .invocation == $write.invocation
                and .seq > $first_write.seq
              )
          ]
        | if length > 0 then $write.intent else empty end
      end
  ' <<<"$events"
}

terminal_intent_write() {
  if [[ "$#" -ne 5 ]]; then
    _terminal_control_error "usage: terminal_intent_write ISSUE INTENT_ID INVOCATION_ID REASON OWNER"
    return 1 # terminal-control-branch: B004
  fi
  local issue="$1" intent="$2" invocation="$3" reason="$4" owner="$5"
  _terminal_control_valid_issue "$issue" \
    || { _terminal_control_error "invalid issue: $issue"; return 1; } # terminal-control-branch: B005
  _terminal_control_valid_token "$intent" \
    || { _terminal_control_error "invalid intent id"; return 1; } # terminal-control-branch: B006
  _terminal_control_valid_token "$invocation" \
    || { _terminal_control_error "invalid invocation id"; return 1; } # terminal-control-branch: B007
  case "$reason" in
    token-cap|turn-cap|usage-unknown) : ;; # terminal-control-branch: B008
    *) _terminal_control_error "invalid terminal-intent reason: $reason"; return 1 ;; # terminal-control-branch: B009
  esac
  case "$owner" in
    dispatcher|dev-wrapper|review-wrapper) : ;; # terminal-control-branch: B010
    *) _terminal_control_error "invalid terminal-intent owner: $owner"; return 1 ;; # terminal-control-branch: B011
  esac

  local marker comments events
  printf -v marker '<!-- resource-terminal-intent-v1: issue=%s intent=%s invocation=%s reason=%s owner=%s -->' \
    "$issue" "$intent" "$invocation" "$reason" "$owner"
  comments="$(_terminal_control_comments "$issue")" || return 1
  events="$(_terminal_control_events "$comments")" \
    || { _terminal_control_error "failed to parse terminal intents for issue $issue"; return 1; }
  if _terminal_control_marker_exists "$events" "$marker"; then
    return 0 # terminal-control-branch: B012
  fi
  if ! itp_post_comment "$issue" "$marker"; then
    _terminal_control_error "failed to persist terminal intent $intent for issue $issue"
    return 1 # terminal-control-branch: B013
  fi
  return 0 # terminal-control-branch: B014
}

terminal_intent_read() {
  if [[ "$#" -ne 1 ]]; then
    _terminal_control_error "usage: terminal_intent_read ISSUE"
    return 1 # terminal-control-branch: B015
  fi
  local issue="$1" comments events result
  _TERMINAL_INTENT_READ_EVENTS=
  _TERMINAL_INTENT_READ_RESULT=
  _terminal_control_valid_issue "$issue" \
    || { _terminal_control_error "invalid issue: $issue"; return 1; } # terminal-control-branch: B016
  comments="$(_terminal_control_comments "$issue")" || return 1

  events="$(_terminal_control_events "$comments")" || {
    _terminal_control_error "failed to parse terminal intents for issue $issue"
    return 1
  }
  if ! result="$(jq -c --arg issue "$issue" '
    [ .[] | select(.kind == "write" and .issue == $issue) ] as $writes
    | [ .[]
        | select(
            (.kind == "consume" or .kind == "clear")
            and .issue == $issue
          )
      ] as $terminal
    | [ $writes[]
        | . as $write
        | select(
            ([ $writes[]
               | select(
                   .intent == $write.intent
                   and .invocation == $write.invocation
                 )
             ] | first) as $first_write
            | any($terminal[];
                .intent == $write.intent
                and .invocation == $write.invocation
                and .seq > $first_write.seq
              ) | not
          )
      ]
    | last
    | if . == null then empty
      else {
        issue: (.issue | tonumber),
        intent,
        invocation,
        reason,
        owner,
        createdAt,
        commentId
      }
      end
  ' <<<"$events")"; then
    _terminal_control_error "failed to parse terminal intents for issue $issue"
    return 1 # terminal-control-branch: B017
  fi
  _TERMINAL_INTENT_READ_EVENTS="$events"
  _TERMINAL_INTENT_READ_RESULT="$result"
  [[ -z "$result" ]] || printf '%s\n' "$result"
  return 0 # terminal-control-branch: B018
}

_terminal_control_consume_generation() {
  local events="$1" issue="$2" intent="$3" invocation="$4" marker
  if ! _terminal_control_has_generation_write \
    "$events" "$issue" "$intent" "$invocation"; then
    _terminal_control_error \
      "no trusted terminal intent $intent generation $invocation exists for issue $issue"
    return 1
  fi
  printf -v marker '<!-- resource-terminal-intent-consume-v1: issue=%s intent=%s invocation=%s -->' \
    "$issue" "$intent" "$invocation"
  if _terminal_control_intent_is_cleared "$events" "$issue" "$intent" "$invocation"; then
    return 0 # terminal-control-branch: B063
  fi
  if _terminal_control_lifecycle_is_current \
    "$events" "$issue" "$intent" "$invocation" "$marker"; then
    return 0 # terminal-control-branch: B023
  fi
  if ! itp_post_comment "$issue" "$marker"; then
    _terminal_control_error "failed to consume terminal intent $intent for issue $issue"
    return 1 # terminal-control-branch: B024
  fi
  return 0 # terminal-control-branch: B025
}

terminal_intent_consume() {
  if [[ "$#" -ne 2 ]]; then
    _terminal_control_error "usage: terminal_intent_consume ISSUE INTENT_ID"
    return 1 # terminal-control-branch: B019
  fi
  local issue="$1" intent="$2" invocation comments events write
  _terminal_control_valid_issue "$issue" \
    || { _terminal_control_error "invalid issue: $issue"; return 1; } # terminal-control-branch: B020
  _terminal_control_valid_token "$intent" \
    || { _terminal_control_error "invalid intent id"; return 1; } # terminal-control-branch: B021
  comments="$(_terminal_control_comments "$issue")" || return 1
  events="$(_terminal_control_events "$comments")" \
    || { _terminal_control_error "failed to parse terminal intents for issue $issue"; return 1; }
  if ! _terminal_control_has_intent_write "$events" "$issue" "$intent"; then
    _terminal_control_error "no trusted terminal intent $intent exists for issue $issue"
    return 1 # terminal-control-branch: B022
  fi
  write="$(_terminal_control_target_write "$events" "$issue" "$intent")" || return 1
  invocation="$(jq -er '.invocation' <<<"$write")" || return 1
  _terminal_control_consume_generation "$events" "$issue" "$intent" "$invocation"
}

terminal_intent_clear() {
  if [[ "$#" -ne 3 ]]; then
    _terminal_control_error "usage: terminal_intent_clear ISSUE INTENT_ID REASON"
    return 1 # terminal-control-branch: B026
  fi
  local issue="$1" intent="$2" reason="$3" invocation marker comments events write
  _terminal_control_valid_issue "$issue" \
    || { _terminal_control_error "invalid issue: $issue"; return 1; } # terminal-control-branch: B027
  _terminal_control_valid_token "$intent" \
    || { _terminal_control_error "invalid intent id"; return 1; } # terminal-control-branch: B028
  _terminal_control_valid_token "$reason" \
    || { _terminal_control_error "invalid clear reason"; return 1; } # terminal-control-branch: B029
  comments="$(_terminal_control_comments "$issue")" || return 1
  events="$(_terminal_control_events "$comments")" \
    || { _terminal_control_error "failed to parse terminal intents for issue $issue"; return 1; }
  if ! _terminal_control_has_intent_write "$events" "$issue" "$intent"; then
    _terminal_control_error "no trusted terminal intent $intent exists for issue $issue"
    return 1 # terminal-control-branch: B030
  fi
  write="$(_terminal_control_target_write "$events" "$issue" "$intent")" || return 1
  invocation="$(jq -er '.invocation' <<<"$write")" || return 1
  printf -v marker '<!-- resource-terminal-intent-clear-v1: issue=%s intent=%s invocation=%s reason=%s -->' \
    "$issue" "$intent" "$invocation" "$reason"
  if _terminal_control_clear_marker_exists \
    "$events" "$issue" "$intent" "$invocation" "$marker"; then
    return 0 # terminal-control-branch: B031
  fi
  if ! itp_post_comment "$issue" "$marker"; then
    _terminal_control_error "failed to clear terminal intent $intent for issue $issue"
    return 1 # terminal-control-branch: B032
  fi
  return 0 # terminal-control-branch: B033
}

_terminal_control_labels() {
  local issue="$1" intent="$2" labels_json
  if ! labels_json="$(itp_read_task "$issue" labels)"; then
    _terminal_control_error "failed to read labels for issue $issue (intent $intent)"
    return 1 # terminal-control-branch: B034
  fi
  if ! jq -ce '
      if type == "object"
         and (.labels | type) == "array"
         and all(.labels[]; type == "string")
      then .labels
      else error("invalid labels")
      end
    ' <<<"$labels_json" 2>/dev/null; then
    _terminal_control_error "invalid label envelope for issue $issue (intent $intent)"
    return 1 # terminal-control-branch: B035
  fi
}

_terminal_control_transition_pending_dev() {
  itp_transition_state "$1" "pending-dev" "stalled"
}

_terminal_control_transition_pending_review() {
  itp_transition_state "$1" "pending-review" "stalled"
}

_terminal_control_transition_in_progress() {
  itp_transition_state "$1" "in-progress" "stalled"
}

_terminal_control_transition_reviewing() {
  itp_transition_state "$1" "reviewing" "stalled"
}

_terminal_control_stall_from() {
  local issue="$1" expected="$2" intent="$3" labels transition_fn
  labels="$(_terminal_control_labels "$issue" "$intent")" || return 1
  if jq -e 'index("stalled") != null' >/dev/null <<<"$labels"; then
    return 0 # terminal-control-branch: B036
  fi
  if ! jq -e --arg expected "$expected" 'index($expected) != null' >/dev/null <<<"$labels"; then
    _terminal_control_error "issue $issue is not owned by expected state $expected (intent $intent)"
    return 1 # terminal-control-branch: B037
  fi
  case "$expected" in
    pending-dev) transition_fn=_terminal_control_transition_pending_dev ;; # terminal-control-branch: B064
    pending-review) transition_fn=_terminal_control_transition_pending_review ;; # terminal-control-branch: B065
    in-progress) transition_fn=_terminal_control_transition_in_progress ;; # terminal-control-branch: B066
    reviewing) transition_fn=_terminal_control_transition_reviewing ;; # terminal-control-branch: B067
  esac
  if ! "$transition_fn" "$issue"; then
    _terminal_control_error "failed to transition issue $issue from $expected to stalled (intent $intent)"
    return 1 # terminal-control-branch: B038
  fi
  return 0 # terminal-control-branch: B039
}

stall_from_pending() {
  if [[ "$#" -ne 3 ]]; then
    _terminal_control_error "usage: stall_from_pending ISSUE EXPECTED_STATE INTENT_ID"
    return 1 # terminal-control-branch: B040
  fi
  local issue="$1" expected="$2" intent="$3"
  _terminal_control_valid_issue "$issue" \
    || { _terminal_control_error "invalid issue: $issue"; return 1; } # terminal-control-branch: B041
  _terminal_control_valid_token "$intent" \
    || { _terminal_control_error "invalid intent id"; return 1; } # terminal-control-branch: B042
  case "$expected" in
    pending-dev|pending-review) : ;; # terminal-control-branch: B043
    *) _terminal_control_error "invalid pending owner state: $expected"; return 1 ;; # terminal-control-branch: B044
  esac
  _terminal_control_stall_from "$issue" "$expected" "$intent"
}

stall_from_active() {
  if [[ "$#" -ne 3 ]]; then
    _terminal_control_error "usage: stall_from_active ISSUE EXPECTED_STATE INTENT_ID"
    return 1 # terminal-control-branch: B045
  fi
  local issue="$1" expected="$2" intent="$3"
  _terminal_control_valid_issue "$issue" \
    || { _terminal_control_error "invalid issue: $issue"; return 1; } # terminal-control-branch: B046
  _terminal_control_valid_token "$intent" \
    || { _terminal_control_error "invalid intent id"; return 1; } # terminal-control-branch: B047
  case "$expected" in
    in-progress|reviewing) : ;; # terminal-control-branch: B048
    *) _terminal_control_error "invalid active owner state: $expected"; return 1 ;; # terminal-control-branch: B049
  esac
  _terminal_control_stall_from "$issue" "$expected" "$intent"
}

# terminal_intent_cleanup_transition ISSUE EXPECTED_ACTIVE NORMAL_REMOVE TARGET
#
# Internal wrapper guard. A readable empty intent set delegates the exact
# pre-INV-140 transition argv. A live intent transitions to stalled first and
# only then consumes, making both crash windows replay-safe.
terminal_intent_cleanup_transition() {
  if [[ "$#" -ne 4 ]]; then
    _terminal_control_error "usage: terminal_intent_cleanup_transition ISSUE EXPECTED_ACTIVE NORMAL_REMOVE TARGET"
    return 1 # terminal-control-branch: B050
  fi
  local issue="$1" expected="$2" normal_remove="$3" target="$4"
  case "$target" in
    pending-dev|pending-review) : ;; # terminal-control-branch: B051
    *) _terminal_control_error "invalid cleanup target: $target"; return 1 ;; # terminal-control-branch: B052
  esac

  local intent_json intent invocation retired_intent labels comments events
  terminal_intent_read "$issue" >/dev/null || return 1 # terminal-control-branch: B053
  intent_json="${_TERMINAL_INTENT_READ_RESULT:-}"
  if [[ -z "$intent_json" ]]; then
    retired_intent="$(
      _terminal_control_newest_retired_intent \
        "${_TERMINAL_INTENT_READ_EVENTS:-[]}" "$issue"
    )" || return 1
    if [[ -n "$retired_intent" ]]; then
      : # terminal-control-branch: B061
      labels="$(_terminal_control_labels "$issue" "$retired_intent")" || return 1
      if jq -e 'index("stalled") != null' >/dev/null <<<"$labels"; then
        return 0 # terminal-control-branch: B062
      fi
    fi
    if ! itp_transition_state "$issue" "$normal_remove" "$target"; then
      _terminal_control_error "failed normal cleanup transition for issue $issue to $target"
      return 1 # terminal-control-branch: B054
    fi
    return 0 # terminal-control-branch: B055
  fi
  : # terminal-control-branch: B056
  intent="$(jq -er '.intent | select(type == "string" and length > 0)' <<<"$intent_json")" \
    || { _terminal_control_error "terminal intent read returned no intent id for issue $issue"; return 1; } # terminal-control-branch: B057
  invocation="$(jq -er '.invocation | select(type == "string" and length > 0)' <<<"$intent_json")" \
    || { _terminal_control_error "terminal intent read returned no invocation id for issue $issue"; return 1; }
  stall_from_active "$issue" "$expected" "$intent" || return 1 # terminal-control-branch: B058
  comments="$(_terminal_control_comments "$issue")" || return 1
  events="$(_terminal_control_events "$comments")" \
    || { _terminal_control_error "failed to parse terminal intents for issue $issue"; return 1; }
  _terminal_control_consume_generation \
    "$events" "$issue" "$intent" "$invocation" || return 1 # terminal-control-branch: B059
  return 0 # terminal-control-branch: B060
}
