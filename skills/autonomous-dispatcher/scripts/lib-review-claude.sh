#!/bin/bash
# lib-review-claude.sh - Claude review-lane permission and verdict helpers.

_CLAUDE_REVIEW_ALLOWED_TOOLS=(
  "Bash(bash scripts/write-verdict-artifact.sh:*)"
  "Bash(bash scripts/write-verdict-body.sh:*)"
  "Bash(bash scripts/post-verdict.sh:*)"
)

# _claude_review_permission_extra_args <agent> <mode> <artifact-path> <body-dir>
#
# Emits a shell-escaped argv fragment for the review member's trusted extra-arg
# parser. Empty output means no injection. The caller appends this fragment
# after the operator's AGENT_REVIEW_EXTRA_ARGS[_CLAUDE] value.
_claude_review_permission_extra_args() {
  local agent="$1" mode="$2" artifact_path="$3" body_dir="$4"
  if [[ "${REVIEW_CLAUDE_PERMISSION_INJECTION:-true}" != "true" ]]; then
    : "review-verdict-path-branch: RVP001"
    return 0
  fi
  if [[ "$agent" != "claude" ]]; then
    : "review-verdict-path-branch: RVP002"
    return 0
  fi
  if [[ "$mode" != "auto" ]]; then
    : "review-verdict-path-branch: RVP003"
    return 0
  fi
  local artifact_dir
  artifact_dir="$(dirname "$artifact_path")"
  body_dir="${body_dir%/}"
  if [[ -z "$artifact_path" || -z "$body_dir" \
      || ! -d "$artifact_dir" || ! -d "$body_dir" || "$body_dir" == "/tmp" ]]; then
    : "review-verdict-path-branch: RVP004"
    return 0
  fi
  : "review-verdict-path-branch: RVP005"

  local arg quoted rendered=""
  local -a args=(
    --add-dir "$artifact_dir"
    --add-dir "$body_dir"
    --allowedTools
    "${_CLAUDE_REVIEW_ALLOWED_TOOLS[@]}"
  )
  for arg in "${args[@]}"; do
    printf -v quoted '%q' "$arg"
    rendered+="${rendered:+ }${quoted}"
  done
  printf '%s\n' "$rendered"
}

# _claude_review_apply_permission_injection <agent> <mode> <artifact-path>
#                                           <body-dir> <dev-args-var>
#                                           <review-args-var>
#
# Production fan-out seam: append the generated fragment to both adapter-facing
# extra-arg aliases and emit the mode/safety diagnostics. Tests drive this exact
# function so wrapper orchestration cannot drift from the pure argv assembler.
_claude_review_apply_permission_injection() {
  local agent="$1" mode="$2" artifact_path="$3" body_dir="$4"
  local dev_args_var="$5" review_args_var="$6"
  local -n dev_args_ref="$dev_args_var"
  local -n review_args_ref="$review_args_var"
  local warning permission_args message

  warning="$(_claude_review_plan_warning "$agent" "$mode")"
  if [[ -n "$warning" ]]; then
    if declare -F log >/dev/null 2>&1; then
      log "$warning"
    else
      printf '%s\n' "$warning" >&2
    fi
  fi

  permission_args="$(_claude_review_permission_extra_args \
    "$agent" "$mode" "$artifact_path" "$body_dir")"
  if [[ -n "$permission_args" ]]; then
    dev_args_ref+="${dev_args_ref:+ }${permission_args}"
    review_args_ref+="${review_args_ref:+ }${permission_args}"
    message="Claude review permission injection active for '${agent}': granted the per-run artifact/body directories and deterministic verdict helper sequence."
  elif [[ "$agent" == "claude" && "$mode" == "auto" \
      && "${REVIEW_CLAUDE_PERMISSION_INJECTION:-true}" == "true" ]]; then
    message="WARNING: Claude review permission injection was skipped because its per-run artifact/body directories were unavailable or unsafe; no broad temporary-directory grant was added."
  else
    return 0
  fi

  if declare -F log >/dev/null 2>&1; then
    log "$message"
  else
    printf '%s\n' "$message" >&2
  fi
}

# _claude_review_plan_warning <agent> <mode>
#
# Plan mode cannot execute any verdict-reporting channel. Keep this separate
# from argument generation so a warning can never be captured into argv.
_claude_review_plan_warning() {
  local agent="$1" mode="$2"
  if [[ "$agent" == "claude" && "$mode" == "plan" ]]; then
    : "review-verdict-path-branch: RVP006"
    printf '%s\n' \
      "WARNING: Claude review lane permission mode 'plan' is unsupported: the member cannot execute the required verdict-reporting sequence; no permission injection was applied."
  else
    : "review-verdict-path-branch: RVP007"
  fi
}

# _claude_review_log_path <base-dir> <project> <issue> <agent> <session-id>
#
# Claude always gets a session-bound capture because its final-text fallback
# must never inspect the append-only reusable log from a prior review round.
# Other agents retain the legacy reusable path unless the wrapper independently
# enables a session suffix for token/turn control.
_claude_review_log_path() {
  local base_dir="${1%/}" project="$2" issue="$3" agent="$4" session_id="$5"
  local path="${base_dir}/agent-${project}-review-${issue}-${agent}"
  if [[ "$agent" == "claude" ]]; then
    : "review-verdict-path-branch: RVP008"
    path+="-${session_id}"
  else
    : "review-verdict-path-branch: RVP009"
  fi
  printf '%s.log\n' "$path"
}

# _claude_final_result_text <stream-json-log>
#
# Emits the result string from the last valid result record. Invalid JSON lines,
# error results, and missing/non-string result fields are not candidates.
_claude_final_result_text() {
  local log_file="$1"
  if [[ ! -r "$log_file" ]]; then
    : "review-verdict-path-branch: RVP010"
    return 0
  fi
  command -v jq >/dev/null 2>&1 || return 0
  : "review-verdict-path-branch: RVP011"
  jq -Rrs '
    [
      split("\n")[]
      | fromjson?
      | select(
          type == "object"
          and .type == "result"
          and (.is_error != true)
          and (.result | type == "string")
        )
    ]
    | if length > 0 then .[-1].result else empty end
  ' "$log_file" 2>/dev/null || return 0
}

# _claude_final_text_verdict <result-text>
#
# Returns pass|fail|none. Unlike _classify_verdict_body, this recognizer has a
# no-match state and accepts only canonical grammar anchored at byte zero of the
# first line. Quoted, mid-line, and later-line phrases do not cast a vote.
_claude_final_text_verdict() {
  local text="$1" first_line
  first_line="${text%%$'\n'*}"
  if [[ "$first_line" =~ ^Review\ PASSED($|[[:space:]-]) ]]; then
    : "review-verdict-path-branch: RVP012"
    printf 'pass\n'
  elif [[ "$first_line" =~ ^Review\ findings: ]]; then
    : "review-verdict-path-branch: RVP013"
    printf 'fail\n'
  else
    : "review-verdict-path-branch: RVP014"
    printf 'none\n'
  fi
}

# _claude_final_text_fallback_eligible <agent> <launch-rc> <artifact-source>
#                                      [<current-verdict> [<current-body>]]
_claude_final_text_fallback_eligible() {
  local agent="$1" launch_rc="$2" source="$3"
  local current_verdict="${4:-}" current_body="${5:-}"
  if [[ -n "$current_verdict" || -n "$current_body" ]]; then
    : "review-verdict-path-branch: RVP020"
    return 1
  fi
  if [[ "${REVIEW_FINAL_TEXT_VERDICT_FALLBACK:-true}" != "true" ]]; then
    : "review-verdict-path-branch: RVP015"
    return 1
  fi
  if [[ "$agent" != "claude" ]]; then
    : "review-verdict-path-branch: RVP016"
    return 1
  fi
  if [[ "$launch_rc" != "0" ]]; then
    : "review-verdict-path-branch: RVP017"
    return 1
  fi
  if [[ "$source" == "artifact-malformed" ]]; then
    : "review-verdict-path-branch: RVP018"
    return 1
  fi
  : "review-verdict-path-branch: RVP019"
  return 0
}

# _claude_apply_final_text_fallback <agent-index>
#
# Production post-poll seam. Reads and updates the wrapper's parallel AGENT_*
# arrays for one member, using the wrapper's existing log/post/refetch helpers.
# Keeping the orchestration here lets hermetic tests execute the same branch the
# wrapper calls instead of reproducing it.
_claude_apply_final_text_fallback() {
  local i="$1"
  [[ "${AGENT_NAMES[$i]:-}" == "claude" ]] || return 0
  [[ -z "${AGENT_VERDICTS[$i]:-}" && -z "${AGENT_VERDICT_BODIES[$i]:-}" ]] \
    || return 0

  local source="${AGENT_VERDICT_SOURCES[$i]:-}"
  if [[ "$source" == "artifact-malformed" ]]; then
    log "INV-78: Claude member '${AGENT_NAMES[$i]}' wrote a malformed verdict artifact - refusing the final-text fallback (Clause V1)."
    return 0
  fi

  local session_id="${AGENT_SESSION_IDS[$i]:-}"
  local launch_rc="${AGENT_LAUNCH_RC[$session_id]:-1}"
  if ! _claude_final_text_fallback_eligible \
      "${AGENT_NAMES[$i]}" "$launch_rc" "$source" \
      "${AGENT_VERDICTS[$i]:-}" "${AGENT_VERDICT_BODIES[$i]:-}"; then
    if [[ "${REVIEW_FINAL_TEXT_VERDICT_FALLBACK:-true}" == "true" \
        && "$launch_rc" != "0" ]]; then
      log "INV-143: Claude review exited non-zero (rc ${launch_rc}) - refusing the final-text fallback; terminal timeout/unavailable semantics remain authoritative."
    fi
    return 0
  fi

  local controller_log="${AGENT_CONTROLLER_LOGS[$i]:-}"
  local result verdict
  result="$(_claude_final_result_text "$controller_log")"
  verdict="$(_claude_final_text_verdict "$result")"
  if [[ "$verdict" != "pass" && "$verdict" != "fail" ]]; then
    log "INV-143: Claude review produced no anchored canonical verdict in its current-run final result; leaving unresolved for the terminal sweep."
    return 0
  fi

  local body_file
  if ! body_file=$(mktemp "/tmp/claude-review-fallback-${ISSUE_NUMBER}-XXXXXX.md" 2>/dev/null); then
    log "WARNING: INV-143 could not allocate the Claude final-text fallback body; leaving unresolved."
    return 0
  fi
  printf '%s\n' "$result" > "$body_file"
  _append_run_footer_to_file "$body_file"

  local model refetched
  model="$(_resolve_review_agent_model "claude")"
  model="${model:-sonnet}"
  if bash "${SCRIPT_DIR}/post-verdict.sh" "$ISSUE_NUMBER" "$verdict" "$body_file" \
       claude "$session_id" "$model" >/dev/null 2>&1; then
    refetched="$(_fetch_agent_verdict_body "claude" "$session_id")"
    if [[ -n "$refetched" ]]; then
      AGENT_VERDICT_BODIES[$i]="$refetched"
      AGENT_VERDICTS[$i]="$(_classify_verdict_body "$refetched")"
    else
      AGENT_VERDICT_BODIES[$i]="$(<"$body_file")"
      AGENT_VERDICTS[$i]="$verdict"
    fi
    AGENT_VERDICT_SOURCES[$i]="claude-finaltext-fallback"
    log "INV-143: Claude did not publish an artifact or comment during the poll window; wrapper posted and resolved '${AGENT_VERDICTS[$i]}' from the session-bound final result (verdict-source=claude-finaltext-fallback)."
  else
    log "WARNING: INV-143 Claude final-text fallback post failed (post-verdict.sh non-zero); Claude remains unresolved for the terminal sweep."
  fi
  if ! rm -f "$body_file" 2>/dev/null; then
    log "WARNING: could not remove Claude final-text fallback scratch body: $body_file"
  fi
}
