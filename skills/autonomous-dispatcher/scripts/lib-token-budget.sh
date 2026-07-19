#!/bin/bash
# lib-token-budget.sh - token-budget policy and orchestration (INV-141).
#
# Sourcing this file is side-effect free. Numeric usage enters the strict
# accounting store only through metrics_parse_tokens output.
# shellcheck shell=bash

_token_budget_error() {
  printf 'token-budget: %s\n' "$*" >&2
  return 1
}

_token_budget_var_is_set() {
  [[ -n "${!1+x}" ]]
}

_token_budget_valid_positive_integer() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

token_budget_validate_config() {
  local name value
  for name in AGENT_TOKEN_BUDGET ISSUE_TOKEN_BUDGET; do
    if _token_budget_var_is_set "$name"; then
      value="${!name}"
      if ! _token_budget_valid_positive_integer "$value"; then
        _token_budget_error "${name}='${value}' is invalid; expected a positive integer matching ^[1-9][0-9]*$"
        return 1
      fi
    fi
  done

  if _token_budget_var_is_set TOKEN_BUDGET_MODE; then
    case "${TOKEN_BUDGET_MODE}" in
      warn|hard) ;;
      *)
        _token_budget_error "TOKEN_BUDGET_MODE='${TOKEN_BUDGET_MODE}' is invalid; expected warn or hard"
        return 1
        ;;
    esac
  fi
  return 0
}

token_budget_enabled() {
  _token_budget_var_is_set AGENT_TOKEN_BUDGET \
    || _token_budget_var_is_set ISSUE_TOKEN_BUDGET
}

token_budget_effective_mode() {
  token_budget_validate_config || return 1
  if ! token_budget_enabled; then
    printf 'disabled\n'
  else
    printf '%s\n' "${TOKEN_BUDGET_MODE:-warn}"
  fi
}

_token_budget_decimal_greater() {
  local measured="$1" limit="$2"
  local LC_ALL=C
  while [[ "$measured" == 0* && ${#measured} -gt 1 ]]; do
    measured="${measured#0}"
  done
  if [[ ${#measured} -ne ${#limit} ]]; then
    [[ ${#measured} -gt ${#limit} ]]
  else
    [[ "$measured" > "$limit" ]]
  fi
}

token_budget_completed_exceeded() {
  local measured="${1:-}" limit="${2:-}"
  [[ "$measured" =~ ^[0-9]+$ ]] && _token_budget_valid_positive_integer "$limit" \
    || { _token_budget_error "completed comparison requires non-negative measured and positive limit"; return 2; }
  _token_budget_decimal_greater "$measured" "$limit"
}

token_budget_admission_reached() {
  local measured="${1:-}" limit="${2:-}"
  [[ "$measured" =~ ^[0-9]+$ ]] && _token_budget_valid_positive_integer "$limit" \
    || { _token_budget_error "admission comparison requires non-negative measured and positive limit"; return 2; }
  [[ "$measured" == "$limit" ]] || _token_budget_decimal_greater "$measured" "$limit"
}

token_budget_adapter_accountable() {
  case "${1:-}" in
    claude|codex) return 0 ;;
    *) return 1 ;;
  esac
}

token_budget_dispatch_adapters_accountable() {
  local dispatch_mode="${1:-}" adapter
  local -a adapters=()
  case "$dispatch_mode" in
    dev-new|dev-resume)
      adapters=("${AGENT_DEV_CMD:-${AGENT_CMD:-claude}}")
      ;;
    review)
      if [[ -n "${AGENT_REVIEW_AGENTS:-}" ]]; then
        read -r -a adapters <<<"$AGENT_REVIEW_AGENTS"
      fi
      if [[ ${#adapters[@]} -eq 0 ]]; then
        adapters=("${AGENT_REVIEW_CMD:-${AGENT_CMD:-claude}}")
      fi
      ;;
    *)
      _token_budget_error "unknown dispatch mode '${dispatch_mode}' for adapter preflight"
      return 1
      ;;
  esac

  for adapter in "${adapters[@]}"; do
    if ! token_budget_adapter_accountable "$adapter"; then
      _token_budget_error "adapter '${adapter}' has no metrics_parse_tokens usage format; hard mode refuses ${dispatch_mode} dispatch"
      return 1
    fi
  done
  return 0
}

token_budget_log_offset() {
  local log="${1:-}" offset=0
  if [[ -f "$log" ]]; then
    offset="$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')" || offset=0
    [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
  fi
  printf '%s\n' "$offset"
}

token_accounting_begin() {
  if (( $# != 6 )); then
    _token_budget_error "token_accounting_begin expects ISSUE RUN_ID SIDE MEMBER_ID ATTEMPT ADAPTER"
    return 1
  fi
  local issue="$1" run_id="$2" side="$3" member_id="$4" attempt="$5" adapter="$6"
  local mode invocation_id

  token_budget_validate_config || return 1
  token_budget_enabled || return 0
  mode="$(token_budget_effective_mode)" || return 1

  if ! token_budget_adapter_accountable "$adapter"; then
    if [[ "$mode" == "hard" ]]; then
      _token_budget_error "adapter '${adapter}' has no metrics_parse_tokens usage format; hard mode refuses launch"
      return 1
    fi
    _token_budget_error "adapter '${adapter}' has no metrics_parse_tokens usage format; warn mode will record usage-unavailable evidence"
  fi

  if ! invocation_id="$(accounting_invocation_id "$run_id" "$side" "$member_id" "$attempt")" \
      || [[ -z "$invocation_id" ]]; then
    if [[ "$mode" == "hard" ]]; then
      _token_budget_error "accounting_invocation_id failed; hard mode refuses launch"
      return 1
    fi
    _token_budget_error "accounting_invocation_id failed; warn mode proceeds without an invocation record"
    return 0
  fi

  if ! accounting_start "$issue" "$invocation_id" "$side" "$run_id" "$member_id" "$attempt"; then
    if [[ "$mode" == "hard" ]]; then
      _token_budget_error "accounting_start failed for ${invocation_id}; hard mode refuses launch"
      return 1
    fi
    _token_budget_error "accounting_start failed for ${invocation_id}; warn mode proceeds degraded"
  fi

  printf '%s\n' "$invocation_id"
}

_token_budget_commit_result() {
  local invocation_id="$1" state="$2" total="$3" input="$4" output="$5"
  local reason="$6" commit_failed="$7"
  jq -nc \
    --arg invocation_id "$invocation_id" \
    --arg state "$state" \
    --arg total "$total" \
    --arg input "$input" \
    --arg output "$output" \
    --arg reason "$reason" \
    --argjson commit_failed "$commit_failed" '
      {
        invocation_id: $invocation_id,
        state: $state,
        total_tokens: (if $total == "" then null else ($total | tonumber) end),
        input_tokens: (if $input == "" then null else ($input | tonumber) end),
        output_tokens: (if $output == "" then null else ($output | tonumber) end),
        reason: (if $reason == "" then null else $reason end),
        commit_failed: $commit_failed
      }'
}

token_accounting_commit() {
  if (( $# < 4 || $# > 6 )); then
    _token_budget_error "token_accounting_commit expects ISSUE INVOCATION_ID LOG OFFSET [UNKNOWN_REASON] [FALLBACK_UNKNOWN_REASON]"
    return 1
  fi
  local issue="$1" invocation_id="$2" log="$3" offset="$4"
  local unknown_reason="${5:-}" parsed="" field total="" input="" output=""
  local fallback_unknown_reason="${6:-}"
  local commit_failed=false

  if [[ -z "$invocation_id" ]]; then
    _token_budget_error "cannot commit usage without an invocation id"
    _token_budget_commit_result "" usage-unknown "" "" "" accounting-start-failed true
    return 0
  fi

  if [[ -z "$unknown_reason" ]]; then
    parsed="$(metrics_parse_tokens "$log" "$offset")" || parsed=""
    for field in $parsed; do
      case "$field" in
        total_tokens=*) total="${field#*=}" ;;
        input_tokens=*) input="${field#*=}" ;;
        output_tokens=*) output="${field#*=}" ;;
      esac
    done
    [[ "$total" =~ ^[0-9]+$ ]] || total=""
    [[ "$input" =~ ^[0-9]+$ ]] || input=""
    [[ "$output" =~ ^[0-9]+$ ]] || output=""
    if [[ -z "$total" ]]; then
      unknown_reason="${fallback_unknown_reason:-no-usage-in-log}"
    fi
  fi

  if [[ -n "$unknown_reason" ]]; then
    if ! accounting_commit_unknown "$issue" "$invocation_id" "$unknown_reason"; then
      _token_budget_error "accounting commit unknown failed for ${invocation_id}"
      commit_failed=true
    fi
    _token_budget_commit_result "$invocation_id" usage-unknown "" "" "" \
      "$unknown_reason" "$commit_failed"
    return 0
  fi

  if ! accounting_commit_usage "$issue" "$invocation_id" "$total" \
      "${input:--}" "${output:--}"; then
    _token_budget_error "accounting commit usage failed for ${invocation_id}"
    _token_budget_commit_result "$invocation_id" usage-unknown "$total" "$input" "$output" \
      commit-failed true
    return 0
  fi

  _token_budget_commit_result "$invocation_id" usage-committed "$total" "$input" "$output" "" false
}

_token_budget_unavailable_json() {
  printf '%s\n' \
    '{"status":"unavailable","total_tokens":0,"source_digest":"","open_invocations":[],"unknown_invocations":[]}'
}

_token_budget_projection_normalize() {
  local projection="${1:-}" status
  if ! status="$(jq -er --argjson max_tokens "${ACCOUNTING_MAX_EXACT_TOKENS:-9007199254740991}" '
      select(
        type == "object"
        and (.status | type) == "string"
        and (.total_tokens | type) == "number"
        and .total_tokens >= 0
        and .total_tokens <= $max_tokens
        and (.total_tokens | floor) == .total_tokens
        and (.source_digest | type) == "string"
        and (.open_invocations | type) == "array"
        and (.unknown_invocations | type) == "array"
      )
      | .status
    ' <<<"$projection" 2>/dev/null)"; then
    _token_budget_unavailable_json
    return 0
  fi
  case "$status" in
    complete|usage-unknown|corrupt)
      printf '%s\n' "$projection"
      ;;
    incomplete|unavailable)
      _token_budget_unavailable_json
      ;;
    *)
      _token_budget_unavailable_json
      ;;
  esac
}

token_budget_open_run_id() {
  if (( $# != 2 )); then
    _token_budget_error "token_budget_open_run_id expects ISSUE INVOCATION_ID"
    return 1
  fi
  local issue="$1" invocation_id="$2" base record parsed state
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$invocation_id" =~ ^inv-v1-[0-9a-f]{24}$ ]] || return 1
  base="$(accounting_dir)" || return 1
  record="${base}/${issue}/${invocation_id}.json"
  parsed="$(_accounting_read_valid_record "$record" "$issue")" || return 1
  state="$(jq -r '.state' <<<"$parsed")"
  case "$state" in
    started) jq -r '.run_id' <<<"$parsed" ;;
    usage-committed|usage-unknown) return 3 ;;
    *) return 1 ;;
  esac
}

token_budget_remote_projection() {
  local issue="${1:-}" self dir
  self="${BASH_SOURCE[0]:-$0}"
  dir="$(cd "$(dirname "$(readlink -f "$self")")" && pwd 2>/dev/null)" || return 2
  bash "${dir}/token-budget-projection-remote-aws-ssm.sh" "$issue"
}

token_issue_projection() {
  if (( $# < 1 || $# > 2 )); then
    _token_budget_error "token_issue_projection expects ISSUE [CURRENT_RUN_ID]"
    _token_budget_unavailable_json
    return 0
  fi
  local issue="$1" current_run_id="${2:-}" discovery final open_id open_run_id read_rc

  if [[ "${EXECUTION_BACKEND:-local}" == "remote-aws-ssm" \
        && -z "$current_run_id" \
        && "${TOKEN_BUDGET_FORCE_LOCAL:-0}" != "1" ]]; then
    if ! final="$(token_budget_remote_projection "$issue")"; then
      _token_budget_error "remote projection transport failed for issue ${issue}"
      _token_budget_unavailable_json
      return 0
    fi
    _token_budget_projection_normalize "$final"
    return 0
  fi

  if ! accounting_reconcile "$issue"; then
    _token_budget_error "accounting_reconcile failed for issue ${issue}"
    _token_budget_unavailable_json
    return 0
  fi

  if ! discovery="$(accounting_admission_query "$issue")"; then
    _token_budget_error "accounting discovery query failed for issue ${issue}"
    _token_budget_unavailable_json
    return 0
  fi
  if ! jq -e '
      type == "object"
      and (.open_invocations | type) == "array"
      and all(.open_invocations[]; type == "string")
    ' >/dev/null 2>&1 <<<"$discovery"; then
    _token_budget_error "accounting discovery query returned malformed JSON for issue ${issue}"
    _token_budget_unavailable_json
    return 0
  fi

  while IFS= read -r open_id; do
    [[ -n "$open_id" ]] || continue
    open_run_id=""
    if open_run_id="$(token_budget_open_run_id "$issue" "$open_id")"; then
      :
    else
      read_rc=$?
      if [[ "$read_rc" -eq 3 ]]; then
        continue
      fi
      _token_budget_error "cannot read open invocation ${open_id} for issue ${issue}"
      _token_budget_unavailable_json
      return 0
    fi
    if [[ -z "$current_run_id" || "$open_run_id" != "$current_run_id" ]]; then
      if ! accounting_commit_unknown "$issue" "$open_id" orphaned-by-crash; then
        _token_budget_error "orphan sweep failed for ${open_id}; a raced live commit will surface as a conflict"
        _token_budget_unavailable_json
        return 0
      fi
    fi
  done < <(jq -r '.open_invocations[]' <<<"$discovery")

  if jq -e '.open_invocations | length > 0' >/dev/null 2>&1 <<<"$discovery"; then
    if ! final="$(accounting_admission_query "$issue")"; then
      _token_budget_error "final accounting query failed for issue ${issue}"
      _token_budget_unavailable_json
      return 0
    fi
  else
    final="$discovery"
  fi

  _token_budget_projection_normalize "$final"
}

token_budget_issue_intent() {
  local projection="${1:-}" digest status reason
  digest="$(jq -er '.source_digest | select(type == "string" and length > 0)' \
    <<<"$projection" 2>/dev/null)" || return 1
  status="$(jq -er '.status' <<<"$projection" 2>/dev/null)" || return 1
  case "$status" in
    complete) reason=token-cap ;;
    usage-unknown|corrupt) reason=usage-unknown ;;
    *) return 1 ;;
  esac
  printf 'token-cap-issue-%s\t%s\t%s\n' "${digest:0:12}" "$digest" "$reason"
}

token_budget_warning_marker() {
  if (( $# != 5 )); then
    _token_budget_error "token_budget_warning_marker expects ISSUE SCOPE SIDE LIMIT MEASURED"
    return 1
  fi
  printf '<!-- token-budget-warn-v1: issue=%s scope=%s side=%s limit=%s measured=%s -->\n' \
    "$1" "$2" "$3" "$4" "$5"
}

token_budget_pending_intent_marker() {
  if (( $# != 5 )); then
    _token_budget_error "token_budget_pending_intent_marker expects ISSUE INTENT INVOCATION REASON OWNER"
    return 1
  fi
  printf '<!-- token-budget-intent-pending-v1: issue=%s intent=%s invocation=%s reason=%s owner=%s -->\n' \
    "$1" "$2" "$3" "$4" "$5"
}

token_budget_resolved_intent_marker() {
  if (( $# != 3 )); then
    _token_budget_error "token_budget_resolved_intent_marker expects ISSUE INTENT INVOCATION"
    return 1
  fi
  printf '<!-- token-budget-intent-resolved-v1: issue=%s intent=%s invocation=%s -->\n' \
    "$1" "$2" "$3"
}

token_budget_launch_refusal_marker() {
  if (( $# != 3 )); then
    _token_budget_error "token_budget_launch_refusal_marker expects ISSUE SIDE RUN_ID"
    return 1
  fi
  printf '<!-- token-budget-launch-refused-v1: issue=%s side=%s run=%s -->\n' \
    "$1" "$2" "$3"
}

token_budget_launch_refusal_can_retry() {
  if (( $# != 1 )) || [[ ! "$1" =~ ^[0-9]+$ ]]; then
    return 2
  fi
  [[ "$1" -eq 0 ]]
}

_token_budget_recovery_pointer_path() {
  if (( $# != 2 )); then
    return 1
  fi
  local issue="$1" owner="$2" base
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$owner" == "dev-wrapper" || "$owner" == "review-wrapper" ]] || return 1
  base="$(accounting_dir)" || return 1
  printf '%s/%s/.token-budget-recovery-%s.json\n' "$base" "$issue" "$owner"
}

token_budget_recovery_pointer_stage() {
  if (( $# < 5 || $# > 7 )); then
    _token_budget_error "token_budget_recovery_pointer_stage expects ISSUE INTENT INVOCATION REASON OWNER [RECORD_PATH] [ACCOUNTING_RECOVERY_JSON]"
    return 1
  fi
  local issue="$1" intent="$2" invocation="$3" reason="$4" owner="$5"
  local record_path="${6:-}" accounting_recovery="${7:-}"
  local dir file record recovery_invocation recovery_reason recovery_path
  local _lock_fd="" rc=0
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] \
    || { _token_budget_error "invalid issue '${issue}' for recovery pointer"; return 1; }
  [[ "$intent" == "$invocation" && "$invocation" =~ ^inv-v1-[0-9a-f]{24}$ ]] \
    || { _token_budget_error "invalid invocation identity for recovery pointer"; return 1; }
  [[ "$reason" == "token-cap" || "$reason" == "usage-unknown" \
      || "$reason" == "turn-cap" ]] \
    || { _token_budget_error "invalid recovery pointer reason '${reason}'"; return 1; }
  [[ "$owner" == "dev-wrapper" || "$owner" == "review-wrapper" ]] \
    || { _token_budget_error "invalid recovery pointer owner '${owner}'"; return 1; }
  if [[ "$reason" == "turn-cap" ]]; then
    [[ "$record_path" == /* && -f "$record_path" && ! -L "$record_path" \
        && "${record_path##*/}" == "${invocation}.json" ]] \
      || { _token_budget_error "invalid turn-control recovery record path"; return 1; }
    if [[ -z "$accounting_recovery" ]]; then
      accounting_recovery="$(jq -nc \
        --arg invocation "$invocation" --arg record_path "$record_path" \
        '[{invocation:$invocation,reason:"turn-cap",record_path:$record_path}]')" \
        || return 1
    fi
    accounting_recovery="$(jq -ce --arg trigger "$invocation" '
      select(
        type == "array"
        and length > 0
        and ([.[].invocation] | unique | length) == length
        and all(.[];
          type == "object"
          and (.invocation | type) == "string"
          and (.invocation | test("^inv-v1-[0-9a-f]{24}$"))
          and (.reason | type) == "string"
          and (.reason | test("^[A-Za-z0-9][A-Za-z0-9._:-]*$"))
          and (.record_path | type) == "string"
          and (.record_path | startswith("/")))
        and any(.[]; .invocation == $trigger and .reason == "turn-cap")
      )
    ' <<<"$accounting_recovery" 2>/dev/null)" || {
      _token_budget_error "invalid turn-control accounting recovery set"
      return 1
    }
    while IFS=$'\t' read -r recovery_invocation recovery_reason recovery_path; do
      [[ -f "$recovery_path" && ! -L "$recovery_path" \
          && "${recovery_path##*/}" == "${recovery_invocation}.json" ]] || {
        _token_budget_error "invalid recovery record path for ${recovery_invocation}"
        return 1
      }
    done < <(jq -r '.[] | [.invocation,.reason,.record_path] | @tsv' \
      <<<"$accounting_recovery")
  else
    if [[ -n "$record_path" || -n "$accounting_recovery" ]]; then
      _token_budget_error "turn-control recovery fields are valid only for turn-cap recovery"
      return 1
    fi
    accounting_recovery="null"
  fi
  dir="$(_accounting_issue_dir "$issue")" \
    || { _token_budget_error "cannot resolve accounting issue directory for recovery pointer"; return 1; }
  file="${dir}/.token-budget-recovery-${owner}.json"
  record="$(jq -nc \
    --argjson issue "$issue" \
    --arg intent "$intent" \
    --arg invocation "$invocation" \
    --arg reason "$reason" \
    --arg owner "$owner" \
    --arg record_path "$record_path" \
    --argjson accounting_recovery "$accounting_recovery" '
      {
        schema_version: 1,
        issue: $issue,
        intent: $intent,
        invocation: $invocation,
        reason: $reason,
        owner: $owner,
        record_path: (if $record_path == "" then null else $record_path end),
        accounting_recovery: $accounting_recovery
      }
    ')" || return 1
  if ! _accounting_lock "$issue" _lock_fd; then
    _token_budget_error "cannot lock accounting recovery pointer for ${intent}"
    return 1
  fi
  if ! _accounting_write_atomic "$dir" "$file" "$record"; then
    _token_budget_error "cannot persist accounting recovery pointer for ${intent}"
    rc=1
  fi
  _accounting_unlock _lock_fd
  return "$rc"
}

_token_budget_recovery_pointer_read_local() {
  if (( $# != 2 )); then
    _token_budget_error "_token_budget_recovery_pointer_read_local expects ISSUE OWNER"
    return 1
  fi
  local issue="$1" owner="$2" side file pointer_file raw pointer invocation
  local reason record state recovery_json recovery_invocation recovery_reason
  case "$owner" in
    dev-wrapper) side=dev ;;
    review-wrapper) side=review ;;
    *) _token_budget_error "invalid recovery pointer owner '${owner}'"; return 1 ;;
  esac
  pointer_file="$(_token_budget_recovery_pointer_path "$issue" "$owner")" \
    || { _token_budget_error "cannot resolve accounting recovery pointer"; return 1; }
  if [[ ! -e "$pointer_file" && ! -L "$pointer_file" ]]; then
    printf '[]\n'
    return 0
  fi
  if [[ ! -f "$pointer_file" || -L "$pointer_file" ]] \
      || ! raw="$(cat "$pointer_file" 2>/dev/null)"; then
    _token_budget_error "accounting recovery pointer is unavailable for issue ${issue}"
    return 1
  fi
  pointer="$(jq -ce \
    --argjson issue "$issue" \
    --arg owner "$owner" '
      .invocation as $primary
      |
      select(
        type == "object"
        and .schema_version == 1
        and .issue == $issue
        and .owner == $owner
        and (.intent | type) == "string"
        and .intent == .invocation
        and (.invocation | test("^inv-v1-[0-9a-f]{24}$"))
        and (.reason == "token-cap"
          or .reason == "usage-unknown"
          or .reason == "turn-cap")
        and (if .reason == "turn-cap"
          then ((.record_path | type) == "string"
            and (.record_path | startswith("/"))
            and (.accounting_recovery | type) == "array"
            and (.accounting_recovery | length) > 0
            and ([.accounting_recovery[].invocation] | unique | length)
              == (.accounting_recovery | length)
            and any(.accounting_recovery[];
              .invocation == $primary and .reason == "turn-cap")
            and all(.accounting_recovery[];
              type == "object"
              and (.invocation | type) == "string"
              and (.invocation | test("^inv-v1-[0-9a-f]{24}$"))
              and (.reason | type) == "string"
              and (.reason | test("^[A-Za-z0-9][A-Za-z0-9._:-]*$"))
              and (.record_path | type) == "string"
              and (.record_path | startswith("/"))))
          else .record_path == null and .accounting_recovery == null
          end)
      )
    ' <<<"$raw" 2>/dev/null)" || {
    _token_budget_error "accounting recovery pointer is malformed for issue ${issue}"
    return 1
  }
  IFS=$'\t' read -r invocation reason <<<"$(jq -r \
    '[.invocation, .reason] | @tsv' <<<"$pointer")"
  if [[ "$reason" == "turn-cap" ]]; then
    recovery_json="$(jq -c '.accounting_recovery' <<<"$pointer")" || return 1
  else
    recovery_json="$(jq -nc \
      --arg invocation "$invocation" --arg reason "$reason" \
      '[{invocation:$invocation,reason:$reason}]')" || return 1
  fi
  while IFS=$'\t' read -r recovery_invocation recovery_reason; do
    file="${pointer_file%/*}/${recovery_invocation}.json"
    record="$(_accounting_read_valid_record "$file" "$issue")" || {
      _token_budget_error "accounting recovery record ${recovery_invocation} is unavailable"
      return 1
    }
    state="$(jq -r --arg side "$side" '
      if .side == $side then .state else "wrong-side" end
    ' <<<"$record")"
    if [[ "$reason" == "turn-cap" && "$state" == "started" ]]; then
      accounting_commit_unknown \
        "$issue" "$recovery_invocation" "$recovery_reason" || {
        _token_budget_error "turn-cap recovery could not close accounting for ${recovery_invocation}"
        return 1
      }
      record="$(_accounting_read_valid_record "$file" "$issue")" || {
        _token_budget_error "turn-cap recovery record ${recovery_invocation} is unavailable after commit"
        return 1
      }
      state="$(jq -r --arg side "$side" '
        if .side == $side then .state else "wrong-side" end
      ' <<<"$record")"
    fi
    if [[ "$reason" == "turn-cap" ]]; then
      [[ "$state" == "usage-committed" || "$state" == "usage-unknown" ]] || {
        _token_budget_error "accounting recovery pointer conflicts with ${recovery_invocation}"
        return 1
      }
    else
      case "${reason}:${state}" in
        token-cap:usage-committed|usage-unknown:usage-unknown|usage-unknown:started) ;;
        *)
          _token_budget_error "accounting recovery pointer conflicts with ${recovery_invocation}"
          return 1
          ;;
      esac
    fi
  done < <(jq -r '.[] | [.invocation,.reason] | @tsv' <<<"$recovery_json")
  jq -nc \
    --arg intent "$invocation" \
    --arg invocation "$invocation" \
    --arg reason "$reason" \
    --arg record_path "$(jq -r '.record_path // empty' <<<"$pointer")" \
    '[{
      intent:$intent,
      invocation:$invocation,
      reason:$reason,
      record_path:(if $record_path == "" then null else $record_path end)
    }]'
}

token_budget_remote_recovery_pointer() {
  if (( $# < 3 || $# > 4 )); then
    return 2
  fi
  local action="$1" issue="$2" owner="$3" invocation="${4:-}" self dir flag
  self="${BASH_SOURCE[0]:-$0}"
  dir="$(cd "$(dirname "$(readlink -f "$self")")" && pwd 2>/dev/null)" || return 2
  if [[ "$action" == "turn-recovery-complete" ]]; then
    flag="--turn-recovery-complete"
  else
    flag="--recovery-${action}"
  fi
  bash "${dir}/token-budget-projection-remote-aws-ssm.sh" \
    "$flag" "$issue" "$owner" "$invocation"
}

token_budget_recovery_pointer_read() {
  if (( $# != 2 )); then
    _token_budget_error "token_budget_recovery_pointer_read expects ISSUE OWNER"
    return 1
  fi
  if [[ "${EXECUTION_BACKEND:-local}" == "remote-aws-ssm" \
        && "${TOKEN_BUDGET_FORCE_LOCAL:-0}" != "1" ]]; then
    token_budget_remote_recovery_pointer read "$1" "$2"
    return
  fi
  _token_budget_recovery_pointer_read_local "$1" "$2"
}

_token_budget_recovery_pointer_clear_local() {
  if (( $# != 3 )); then
    return 1
  fi
  local issue="$1" owner="$2" invocation="$3" file pointer dir
  local _lock_fd="" rc=0
  file="$(_token_budget_recovery_pointer_path "$issue" "$owner")" || return 1
  dir="${file%/*}"
  _accounting_lock "$issue" _lock_fd || return 1
  if [[ ! -e "$file" && ! -L "$file" ]]; then
    rc=0
  elif [[ ! -f "$file" || -L "$file" ]]; then
    rc=1
  elif ! pointer="$(jq -ce --arg invocation "$invocation" '
      select(.invocation == $invocation)
    ' "$file" 2>/dev/null)" || [[ -z "$pointer" ]]; then
    rc=1
  elif ! rm -f "$file" 2>/dev/null || ! _accounting_sync_dir "$dir"; then
    rc=1
  fi
  _accounting_unlock _lock_fd
  return "$rc"
}

token_budget_recovery_pointer_clear() {
  if (( $# != 3 )); then
    _token_budget_error "token_budget_recovery_pointer_clear expects ISSUE OWNER INVOCATION"
    return 1
  fi
  if [[ "${EXECUTION_BACKEND:-local}" == "remote-aws-ssm" \
        && "${TOKEN_BUDGET_FORCE_LOCAL:-0}" != "1" ]]; then
    token_budget_remote_recovery_pointer clear "$1" "$2" "$3"
    return
  fi
  _token_budget_recovery_pointer_clear_local "$1" "$2" "$3"
}

_token_budget_comment_marker_exists() {
  local comments="$1" marker="$2"
  jq -e --arg marker "$marker" \
    'any(.[]; .authorKind == "self" and .body == $marker)' \
    >/dev/null 2>&1 <<<"$comments"
}

_token_budget_post_marker_once() {
  local issue="$1" marker="$2" comments
  if comments="$(ITP_REQUIRE_SELF_AUTHOR=1 itp_list_comments "$issue" 2>/dev/null)" \
      && jq -e 'type == "array"' >/dev/null 2>&1 <<<"$comments" \
      && _token_budget_comment_marker_exists "$comments" "$marker"; then
    return 0
  fi
  itp_post_comment "$issue" "$marker"
}

token_budget_post_launch_refusal() {
  if (( $# != 3 )); then
    _token_budget_error "token_budget_post_launch_refusal expects ISSUE SIDE RUN_ID"
    return 1
  fi
  local issue="$1" side="$2" run_id="$3" marker
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$side" == "dev" || "$side" == "review" ]] || return 1
  [[ "$run_id" =~ ^[A-Za-z0-9._:-]+$ ]] || return 1
  marker="$(token_budget_launch_refusal_marker "$issue" "$side" "$run_id")" \
    || return 1
  _token_budget_post_marker_once "$issue" "$marker"
}

token_budget_latest_dispatch_cutoff() {
  if (( $# != 2 )); then
    _token_budget_error "token_budget_latest_dispatch_cutoff expects ISSUE MODE"
    return 2
  fi
  local issue="$1" mode="$2" comments cutoff
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "$mode" == "dev-new" || "$mode" == "dev-resume" || "$mode" == "review" ]] \
    || return 2
  if ! comments="$(ITP_REQUIRE_SELF_AUTHOR=1 itp_list_comments "$issue")" \
      || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$comments"; then
    _token_budget_error "cannot read dispatch markers for issue ${issue}"
    return 2
  fi
  if ! cutoff="$(jq -er \
    --arg mode "$mode" \
    --argjson max_id 9007199254740991 '
    [
      .[]
      | (.body? // "") as $body
      | select(.authorKind == "self" and ($body | type == "string"))
      | select($body | test(
          "^<!-- dispatcher-token: [^\\n]+ mode=" + $mode + "( run=[^\\n]+)? -->\\n"
        ))
    ] as $dispatches
    | select(
        ($dispatches | length) > 0
        and all(
          $dispatches[];
          (.id? | type) == "number"
          and .id >= 0
          and .id <= $max_id
          and (.id | floor) == .id
        )
      )
    | ($dispatches | max_by(.id)) as $latest
    | select(
        ($latest.createdAt? | type) == "string"
        and ($latest.createdAt | length) > 0
      )
    | [$latest.createdAt, ($latest.id | tostring)]
    | @tsv
  ' <<<"$comments")"; then
    _token_budget_error "cannot derive a trusted ${mode} dispatch cutoff for issue ${issue}"
    return 2
  fi
  printf '%s\n' "$cutoff"
}

token_budget_recent_launch_refusal() {
  if (( $# != 2 )); then
    _token_budget_error "token_budget_recent_launch_refusal expects ISSUE SIDE"
    return 2
  fi
  local issue="$1" side="$2" comments
  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || return 2
  [[ "$side" == "dev" || "$side" == "review" ]] || return 2
  if ! comments="$(ITP_REQUIRE_SELF_AUTHOR=1 itp_list_comments "$issue")" \
      || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$comments"; then
    _token_budget_error "cannot read launch-refusal markers for issue ${issue}"
    return 2
  fi
  jq -e --arg issue "$issue" --arg side "$side" '
    (if $side == "dev" then "dev-(new|resume)" else "review" end) as $mode
    | . as $comments
    | reduce range(0; $comments | length) as $i (
        {dispatch: -1, refusals: []};
        $comments[$i] as $row
        | ($row.body? // "") as $body
        | if $row.authorKind == "self"
             and ($body | type == "string")
             and ($body | test(
               "^<!-- dispatcher-token: [^\\n]+ mode=" + $mode + "( run=[^\\n]+)? -->\\n"
             ))
          then .dispatch = $i
          else . end
        | (
            $body
            | (capture("^<!-- token-budget-launch-refused-v1: issue=(?<issue>[1-9][0-9]*) side=(?<side>dev|review) run=(?<run>[A-Za-z0-9._:-]+) -->$")? // null)
          ) as $marker
        | if $row.authorKind == "self"
             and $marker != null
             and $marker.issue == $issue
             and $marker.side == $side
          then .refusals += [$i]
          else . end
      )
    | select(.dispatch >= 0)
    | (.dispatch as $dispatch | [.refusals[] | select(. > $dispatch)] | length > 0)
  ' >/dev/null 2>&1 <<<"$comments"
}

token_budget_write_invocation_intent() {
  if (( $# != 5 )); then
    _token_budget_error "token_budget_write_invocation_intent expects ISSUE INTENT INVOCATION REASON OWNER"
    return 1
  fi
  local issue="$1" intent="$2" invocation="$3" reason="$4" owner="$5"
  local pending resolved pending_ok=false pointer_ok=false
  pending="$(token_budget_pending_intent_marker \
    "$issue" "$intent" "$invocation" "$reason" "$owner")" || return 1
  resolved="$(token_budget_resolved_intent_marker \
    "$issue" "$intent" "$invocation")" || return 1

  if [[ "${TOKEN_BUDGET_SKIP_POINTER_STAGE:-0}" != "1" ]]; then
    if token_budget_recovery_pointer_stage \
        "$issue" "$intent" "$invocation" "$reason" "$owner"; then
      pointer_ok=true
    else
      _token_budget_error "cannot persist local terminal-intent recovery pointer for ${intent}"
    fi
  fi
  if _token_budget_post_marker_once "$issue" "$pending"; then
    pending_ok=true
  else
    _token_budget_error "cannot persist pending terminal-intent recovery marker for ${intent}"
  fi

  if ! terminal_intent_write "$issue" "$intent" "$invocation" "$reason" "$owner"; then
    if [[ "$pointer_ok" != "true" && "$pending_ok" != "true" ]] \
        && ! _token_budget_post_marker_once "$issue" "$pending"; then
      _token_budget_error "terminal intent ${intent} and both recovery records failed to persist"
    fi
    return 1
  fi

  if [[ "$pointer_ok" == "true" ]] \
      && ! _token_budget_recovery_pointer_clear_local "$issue" "$owner" "$invocation"; then
    _token_budget_error "terminal intent ${intent} is durable but its local recovery pointer could not be cleared"
  fi
  if [[ "$pending_ok" == "true" ]] \
      && ! _token_budget_post_marker_once "$issue" "$resolved"; then
    _token_budget_error "terminal intent ${intent} is durable but its recovery marker could not be resolved"
  fi
  return 0
}

token_budget_recover_pending_intent() {
  if (( $# != 2 )); then
    _token_budget_error "token_budget_recover_pending_intent expects ISSUE OWNER"
    return 1
  fi
  local issue="$1" owner="$2" mode comments marker_state candidate candidate_source
  local violations intent invocation reason resolved live_intent
  token_budget_enabled || return 0
  mode="$(token_budget_effective_mode)" || return 20
  [[ "$mode" == "hard" ]] || return 0

  if ! comments="$(ITP_REQUIRE_SELF_AUTHOR=1 itp_list_comments "$issue")" \
      || ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$comments"; then
    _token_budget_error "cannot read pending terminal-intent recovery markers for issue ${issue}"
    return 20
  fi
  marker_state="$(jq -c --arg issue "$issue" --arg owner "$owner" '
    {
      pending: [
        .[]
        | select(.authorKind == "self")
        | (
            .body
            | capture("^<!-- token-budget-intent-pending-v1: issue=(?<issue>[1-9][0-9]*) intent=(?<intent>[A-Za-z0-9._:-]+) invocation=(?<invocation>[A-Za-z0-9._:-]+) reason=(?<reason>token-cap|usage-unknown) owner=(?<owner>dev-wrapper|review-wrapper) -->$")?
          )
        | select(. != null and .issue == $issue and .owner == $owner)
      ],
      resolved: [
        .[]
        | select(.authorKind == "self")
        | (
            .body
            | capture("^<!-- token-budget-intent-resolved-v1: issue=(?<issue>[1-9][0-9]*) intent=(?<intent>[A-Za-z0-9._:-]+) invocation=(?<invocation>[A-Za-z0-9._:-]+) -->$")?
          )
        | select(. != null and .issue == $issue)
      ]
    }
  ' <<<"$comments" 2>/dev/null)" || {
    _token_budget_error "cannot parse pending terminal-intent recovery markers for issue ${issue}"
    return 20
  }
  candidate="$(jq -c '
    .resolved as $resolved
    | [
        .pending[]
        | . as $candidate
        | select(
            any($resolved[];
              .intent == $candidate.intent
              and .invocation == $candidate.invocation
            ) | not
          )
      ]
    | last // null
  ' <<<"$marker_state")" || return 20
  candidate_source=marker
  if [[ "$candidate" == "null" ]]; then
    if ! violations="$(token_budget_recovery_pointer_read "$issue" "$owner")"; then
      _token_budget_error "cannot read terminal-intent recovery pointer for issue ${issue}"
      return 20
    fi
    candidate="$(jq -c --argjson violations "$violations" '
      .resolved as $resolved
      | [
          $violations[]
          | . as $candidate
          | select(
              any($resolved[];
                .intent == $candidate.intent
                and .invocation == $candidate.invocation
              ) | not
            )
        ]
      | first // null
    ' <<<"$marker_state")" || return 20
    candidate_source=accounting
  fi
  [[ "$candidate" != "null" ]] || return 0
  IFS=$'\t' read -r intent invocation reason <<<"$(jq -r \
    '[.intent, .invocation, .reason] | @tsv' <<<"$candidate")"

  if [[ "$candidate_source" == "accounting" ]]; then
    if ! TOKEN_BUDGET_SKIP_POINTER_STAGE=1 token_budget_write_invocation_intent \
        "$issue" "$intent" "$invocation" "$reason" "$owner"; then
      _token_budget_error "accounting-derived terminal intent ${intent} is still unavailable; preserving active ownership"
      return 20
    fi
  elif ! terminal_intent_write "$issue" "$intent" "$invocation" "$reason" "$owner"; then
    _token_budget_error "pending terminal intent ${intent} is still unavailable; preserving active ownership"
    return 20
  fi
  if ! live_intent="$(terminal_intent_read "$issue")"; then
    _token_budget_error "cannot confirm recovered terminal intent ${intent}; preserving active ownership"
    return 20
  fi
  if [[ -n "$live_intent" ]] && ! jq -e '
      type == "object"
      and (.issue | type) == "number"
      and (.intent | type) == "string"
      and (.invocation | type) == "string"
      and (.reason | type) == "string"
      and (.owner | type) == "string"
    ' >/dev/null 2>&1 <<<"$live_intent"; then
    _token_budget_error "recovered terminal-intent read returned malformed state for issue ${issue}"
    return 20
  fi
  if ! token_budget_recovery_pointer_clear "$issue" "$owner" "$invocation"; then
    _token_budget_error "recovered terminal intent ${intent}, but its local pointer could not be cleared"
  fi
  resolved="$(token_budget_resolved_intent_marker "$issue" "$intent" "$invocation")" \
    || return 20
  _token_budget_post_marker_once "$issue" "$resolved" \
    || _token_budget_error "recovered terminal intent ${intent}, but its pending marker remains unresolved"
  if [[ -n "$live_intent" ]] && jq -e \
      --arg issue "$issue" \
      --arg intent "$intent" \
      --arg invocation "$invocation" \
      --arg reason "$reason" \
      --arg owner "$owner" '
        (.issue | tostring) == $issue
        and .intent == $intent
        and .invocation == $invocation
        and .reason == $reason
        and .owner == $owner
      ' >/dev/null 2>&1 <<<"$live_intent"; then
    return 10
  fi
  return 0
}

_token_budget_warning_exists() {
  local comments="$1" issue="$2" scope="$3" limit="$4"
  jq -e --arg issue "$issue" --arg scope "$scope" --arg limit "$limit" '
    any(.[];
      . as $row
      | (
          $row.body
          | capture("<!-- token-budget-warn-v1: issue=(?<issue>[1-9][0-9]*) scope=(?<scope>invocation|issue) side=(?<side>dev|review|dispatch) limit=(?<limit>[1-9][0-9]*) measured=(?<measured>[A-Za-z0-9._:-]+) -->")?
        ) as $marker
      | $row.authorKind == "self"
        and $marker != null
        and $marker.issue == $issue
        and $marker.scope == $scope
        and $marker.limit == $limit
    )
  ' >/dev/null 2>&1 <<<"$comments"
}

token_budget_warn() {
  if (( $# < 5 || $# > 6 )); then
    _token_budget_error "token_budget_warn expects ISSUE SCOPE SIDE LIMIT MEASURED [EVIDENCE]"
    return 1
  fi
  local issue="$1" scope="$2" side="$3" limit="$4" measured="$5"
  local evidence="${6:-}" marker comments body
  marker="$(token_budget_warning_marker "$issue" "$scope" "$side" "$limit" "$measured")" \
    || return 1
  if ! comments="$(ITP_REQUIRE_SELF_AUTHOR=1 itp_list_comments "$issue")"; then
    _token_budget_error "cannot list warning breadcrumbs for issue ${issue}"
    return 1
  fi
  if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$comments"; then
    _token_budget_error "warning breadcrumb comment envelope is malformed for issue ${issue}"
    return 1
  fi
  if _token_budget_warning_exists "$comments" "$issue" "$scope" "$limit"; then
    return 0
  fi

  body="Token budget warning (mode=warn): ${scope} usage for issue #${issue} measured ${measured} against limit ${limit}. Hard mode would have blocked the next phase or routed the issue to stalled."
  if [[ -n "$evidence" ]]; then
    body+=" Evidence: ${evidence}."
  fi
  body+=$'\n'
  body+="$marker"
  if ! itp_post_comment "$issue" "$body"; then
    _token_budget_error "failed to post warning breadcrumb for issue ${issue}"
    return 1
  fi
  return 0
}

_token_budget_stop_report() {
  local issue="$1" intent="$2" status="$3" measured="$4" limit="$5"
  local comments marker body
  printf -v marker '<!-- token-budget-stop-v1: issue=%s intent=%s -->' "$issue" "$intent"
  if comments="$(ITP_REQUIRE_SELF_AUTHOR=1 itp_list_comments "$issue" 2>/dev/null)" \
      && jq -e --arg marker "$marker" \
        'any(.[]; .authorKind == "self" and ((.body? // "") | contains($marker)))' \
        >/dev/null 2>&1 <<<"$comments"; then
    return 0
  fi
  body="${marker}
Token budget enforcement stopped autonomous dispatch for issue #${issue} (reason=token-budget, status=${status}, measured=${measured}, limit=${limit}). To re-arm: acknowledge unknown records with accounting_ack_unknown when applicable, raise or unset ISSUE_TOKEN_BUDGET, remove stalled, and re-add the prior pending state."
  itp_post_comment "$issue" "$body"
}

token_budget_pending_failure_class_from_labels() {
  if (( $# != 2 )); then
    _token_budget_error "token_budget_pending_failure_class_from_labels expects LABELS_JSON EXPECTED_STATE"
    return 1
  fi
  local labels="$1" expected="$2"
  jq -ce '
    if type == "array" and all(.[]; type == "string") then .
    else error("invalid labels")
    end
  ' <<<"$labels" >/dev/null 2>&1 || return 1
  if jq -e 'index("stalled") != null' <<<"$labels" >/dev/null 2>&1; then
    printf '%s\n' converged
  elif jq -e --arg expected "$expected" 'index($expected) != null' \
      <<<"$labels" >/dev/null 2>&1; then
    printf '%s\n' transition-failed
  else
    printf '%s\n' wrong-owner
  fi
}

_token_budget_pending_failure_class() {
  if (( $# != 2 )); then
    _token_budget_error "_token_budget_pending_failure_class expects ISSUE EXPECTED_STATE"
    return 1
  fi
  local issue="$1" expected="$2" task labels
  task="$(itp_read_task "$issue")" || return 1
  labels="$(jq -ce '
    if type == "object"
       and (.labels | type) == "array"
       and all(.labels[]; type == "string")
    then .labels
    else error("invalid task labels")
    end
  ' <<<"$task" 2>/dev/null)" || return 1
  token_budget_pending_failure_class_from_labels "$labels" "$expected"
}

token_admission_gate() {
  if (( $# != 3 )); then
    _token_budget_error "token_admission_gate expects ISSUE PENDING_STATE MODE"
    return 1
  fi
  local issue="$1" pending_state="$2" dispatch_mode="$3"
  local mode projection status measured intent_fields intent invocation reason
  local transition_failure_class

  token_budget_validate_config || return 1
  mode="$(token_budget_effective_mode)" || return 1
  if token_budget_enabled && [[ "$mode" == "hard" ]]; then
    token_budget_dispatch_adapters_accountable "$dispatch_mode" || return 1
  fi
  if ! _token_budget_var_is_set ISSUE_TOKEN_BUDGET; then
    return 0
  fi
  projection="$(token_issue_projection "$issue")"
  status="$(jq -r '.status // "unavailable"' <<<"$projection" 2>/dev/null)"
  measured="$(jq -r '.total_tokens // 0' <<<"$projection" 2>/dev/null)"

  if [[ "$mode" == "warn" ]]; then
    case "$status" in
      complete)
        if token_budget_admission_reached "$measured" "$ISSUE_TOKEN_BUDGET"; then
          token_budget_warn "$issue" issue dispatch "$ISSUE_TOKEN_BUDGET" "$measured" \
            "pre-dispatch equality or overshoot would block in hard mode" || true # Warning delivery never blocks dispatch.
        fi
        ;;
      usage-unknown|corrupt)
        token_budget_warn "$issue" issue dispatch "$ISSUE_TOKEN_BUDGET" "$status" \
          "accounting status is fail-closed in hard mode" || true # Warning delivery never blocks dispatch.
        ;;
      unavailable)
        _token_budget_error "projection unavailable for issue ${issue}; warn mode preserves dispatch"
        ;;
    esac
    return 0
  fi

  if [[ "$status" == "unavailable" ]]; then
    _token_budget_error "projection unavailable for issue ${issue}; blocking this dispatch without stalling"
    release_dispatch_marker "$issue" "$dispatch_mode"
    return 10
  fi
  if [[ "$status" == "complete" ]] \
      && ! token_budget_admission_reached "$measured" "$ISSUE_TOKEN_BUDGET"; then
    return 0
  fi
  case "$status" in
    complete|usage-unknown|corrupt) ;;
    *)
      _token_budget_error "unexpected projection status '${status}' for issue ${issue}"
      release_dispatch_marker "$issue" "$dispatch_mode"
      return 10
      ;;
  esac

  intent_fields="$(token_budget_issue_intent "$projection")" || {
    _token_budget_error "cannot derive issue intent for issue ${issue}"
    release_dispatch_marker "$issue" "$dispatch_mode"
    return 10
  }
  IFS=$'\t' read -r intent invocation reason <<<"$intent_fields"
  if ! terminal_intent_write "$issue" "$intent" "$invocation" "$reason" dispatcher; then
    _token_budget_error "cannot persist terminal intent ${intent} for issue ${issue}"
    release_dispatch_marker "$issue" "$dispatch_mode"
    return 10
  fi

  if [[ -n "$pending_state" ]]; then
    if ! stall_from_pending "$issue" "$pending_state" "$intent"; then
      transition_failure_class="$(_token_budget_pending_failure_class \
        "$issue" "$pending_state")" || transition_failure_class=unavailable
      case "$transition_failure_class" in
        converged)
          _token_budget_error "pending-state terminal transition for issue ${issue} converged despite a non-zero result"
          ;;
        wrong-owner)
          _token_budget_error "pending-state terminal transition found the wrong owner for issue ${issue}"
          if ! terminal_intent_clear "$issue" "$intent" wrong-owner-abort; then
            _token_budget_error "cannot clear terminal intent ${intent} after wrong-owner abort; retaining dispatch marker"
            retain_dispatch_marker "$issue" "$dispatch_mode"
            return 10
          fi
          release_dispatch_marker "$issue" "$dispatch_mode"
          return 10
          ;;
        transition-failed|unavailable)
          _token_budget_error "pending-state terminal transition failed for issue ${issue}; retaining intent and dispatch marker"
          retain_dispatch_marker "$issue" "$dispatch_mode"
          return 10
          ;;
      esac
    fi
  elif ! itp_transition_state "$issue" "" stalled; then
    _token_budget_error "dev-new terminal transition failed for issue ${issue}; retaining intent and dispatch marker"
    retain_dispatch_marker "$issue" "$dispatch_mode"
    return 10
  fi

  if ! _token_budget_stop_report "$issue" "$intent" "$status" "$measured" \
      "$ISSUE_TOKEN_BUDGET"; then
    _token_budget_error "failed to post stop report for issue ${issue}; retaining intent and dispatch marker"
    retain_dispatch_marker "$issue" "$dispatch_mode"
    return 10
  fi
  if ! terminal_intent_consume "$issue" "$intent"; then
    _token_budget_error "cannot consume terminal intent ${intent} after stalled transition; retaining dispatch marker"
    retain_dispatch_marker "$issue" "$dispatch_mode"
    return 10
  fi
  release_dispatch_marker "$issue" "$dispatch_mode"
  return 10
}

token_budget_evaluate_invocation() {
  if (( $# != 4 )); then
    _token_budget_error "token_budget_evaluate_invocation expects ISSUE SIDE INVOCATION_ID RESULT_JSON"
    return 1
  fi
  local issue="$1" side="$2" invocation_id="$3" result="$4"
  local mode state total measured reason owner limit
  token_budget_enabled || return 0
  mode="$(token_budget_effective_mode)" || return 1
  state="$(jq -r '.state // "usage-unknown"' <<<"$result" 2>/dev/null)"
  total="$(jq -r '.total_tokens // empty' <<<"$result" 2>/dev/null)"

  if [[ "$state" == "usage-committed" && "$total" =~ ^[0-9]+$ ]]; then
    _token_budget_var_is_set AGENT_TOKEN_BUDGET || return 0
    token_budget_completed_exceeded "$total" "$AGENT_TOKEN_BUDGET" || return 0
    limit="$AGENT_TOKEN_BUDGET"
    measured="$total"
    reason=token-cap
  else
    limit="${AGENT_TOKEN_BUDGET:-${ISSUE_TOKEN_BUDGET:-}}"
    measured=unavailable
    reason=usage-unknown
  fi

  if [[ "$mode" == "warn" ]]; then
    token_budget_warn "$issue" invocation "$side" "$limit" "$measured" \
      "invocation ${invocation_id} state=${state}" || true # Warning delivery never changes wrapper routing.
    return 0
  fi

  case "$side" in
    dev) owner=dev-wrapper ;;
    review) owner=review-wrapper ;;
    *) return 1 ;;
  esac
  token_budget_write_invocation_intent \
    "$issue" "$invocation_id" "$invocation_id" "$reason" "$owner" \
    || return 21
  return 10
}

token_budget_evaluate_issue() {
  if (( $# < 3 || $# > 4 )); then
    _token_budget_error "token_budget_evaluate_issue expects ISSUE SIDE CURRENT_RUN_ID [PERSIST_INTENT]"
    return 1
  fi
  local issue="$1" side="$2" current_run_id="$3"
  local persist_intent="${4:-true}"
  local mode projection status total fields intent invocation reason owner measured compare_rc
  _token_budget_var_is_set ISSUE_TOKEN_BUDGET || return 0
  mode="$(token_budget_effective_mode)" || return 1
  projection="$(token_issue_projection "$issue" "$current_run_id")"
  status="$(jq -r '.status // "unavailable"' <<<"$projection" 2>/dev/null)"
  total="$(jq -r '.total_tokens // 0' <<<"$projection" 2>/dev/null)"

  if [[ "$status" == "unavailable" ]]; then
    _token_budget_error "issue projection unavailable for issue ${issue}"
    [[ "$mode" == "warn" ]] && return 0
    return 20
  fi
  if [[ "$status" == "complete" ]]; then
    compare_rc=0
    token_budget_completed_exceeded "$total" "$ISSUE_TOKEN_BUDGET" || compare_rc=$?
    if [[ "$compare_rc" -eq 1 ]]; then
      return 0
    elif [[ "$compare_rc" -ne 0 ]]; then
      _token_budget_error "invalid completed issue projection for issue ${issue}"
      return 20
    fi
    measured="$total"
  elif [[ "$status" == "usage-unknown" || "$status" == "corrupt" ]]; then
    measured="$status"
  else
    _token_budget_error "unexpected issue projection status '${status}'"
    return 20
  fi

  if [[ "$mode" == "warn" ]]; then
    token_budget_warn "$issue" issue "$side" "$ISSUE_TOKEN_BUDGET" "$measured" \
      "completed issue projection status=${status}" || true # Warning delivery never changes wrapper routing.
    return 0
  fi

  [[ "$persist_intent" == "true" ]] || return 10
  fields="$(token_budget_issue_intent "$projection")" || return 21
  IFS=$'\t' read -r intent invocation reason <<<"$fields"
  case "$side" in
    dev) owner=dev-wrapper ;;
    review) owner=review-wrapper ;;
    *) return 1 ;;
  esac
  terminal_intent_write "$issue" "$intent" "$invocation" "$reason" "$owner" \
    || return 21
  return 10
}

token_budget_evaluate_review_members() {
  if (( $# != 3 )); then
    _token_budget_error "token_budget_evaluate_review_members expects ISSUE IDS_ARRAY RESULTS_ARRAY"
    return 1
  fi
  local issue="$1"
  local -n ids_ref="$2" results_ref="$3"
  local i gate_rc

  for i in "${!ids_ref[@]}"; do
    [[ -n "${results_ref[$i]:-}" ]] || continue
    gate_rc=0
    token_budget_evaluate_invocation "$issue" review "${ids_ref[$i]:-}" \
      "${results_ref[$i]}" || gate_rc=$?
    if [[ "$gate_rc" -eq 10 ]]; then
      return 10
    fi
    if [[ "$gate_rc" -eq 21 ]]; then
      _token_budget_error "review invocation intent persistence failed for ${ids_ref[$i]:-unknown}"
      return 21
    elif [[ "$gate_rc" -ne 0 ]]; then
      _token_budget_error "review invocation evaluation failed for ${ids_ref[$i]:-unknown}"
      return 1
    fi
  done
  return 0
}

token_budget_evaluate_dev_run() {
  if (( $# != 4 )); then
    _token_budget_error "token_budget_evaluate_dev_run expects ISSUE RUN_ID IDS_ARRAY RESULTS_ARRAY"
    return 1
  fi
  local issue="$1" run_id="$2"
  local -n ids_ref="$3" results_ref="$4"
  local i rc=0 gate_rc persist_issue_intent=true

  for i in "${!ids_ref[@]}"; do
    [[ -n "${ids_ref[$i]:-}" && -n "${results_ref[$i]:-}" ]] || continue
    gate_rc=0
    token_budget_evaluate_invocation "$issue" dev "${ids_ref[$i]}" "${results_ref[$i]}" \
      || gate_rc=$?
    if [[ "$gate_rc" -eq 10 ]]; then
      rc=10
      persist_issue_intent=false
      break
    elif [[ "$gate_rc" -eq 21 ]]; then
      rc=21
      persist_issue_intent=false
      break
    elif [[ "$gate_rc" -ne 0 ]]; then
      rc=21
      _token_budget_error "dev invocation evaluation failed for ${ids_ref[$i]}"
      break
    fi
  done

  gate_rc=0
  token_budget_evaluate_issue "$issue" dev "$run_id" "$persist_issue_intent" || gate_rc=$?
  if [[ "$gate_rc" -eq 10 && "$rc" -ne 21 ]]; then
    rc=10
  elif [[ "$gate_rc" -eq 20 ]]; then
    _token_budget_error "dev issue projection unavailable; normal cleanup routing is preserved"
  elif [[ "$gate_rc" -eq 21 && "$rc" -ne 10 ]]; then
    _token_budget_error "dev issue intent persistence failed; refusing normal cleanup routing"
    rc=21
  elif [[ "$gate_rc" -ne 0 && "$rc" -ne 10 ]]; then
    rc=21
  fi
  return "$rc"
}
