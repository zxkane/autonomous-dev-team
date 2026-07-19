#!/bin/bash
# lib-turn-limit.sh - adapter-aware turn control and stop arbitration (INV-142).
#
# Sourcing is side-effect free. Files are created only after an effective
# per-side limit has passed launch validation and turn_control_init is called.
# shellcheck shell=bash

[[ "${TURN_CONTROL_SCHEMA_VERSION:-}" == "1" ]] || TURN_CONTROL_SCHEMA_VERSION=1
[[ "${TURN_CONTROL_STOP_RC:-}" == "92" ]] || TURN_CONTROL_STOP_RC=92
[[ "${TURN_CONTROL_ERROR_RC:-}" == "93" ]] || TURN_CONTROL_ERROR_RC=93
[[ "${TURN_CONTROL_REVIEW_ROUTED_RC:-}" == "10" ]] || TURN_CONTROL_REVIEW_ROUTED_RC=10
[[ "${TURN_CONTROL_REVIEW_REFUSED_RC:-}" == "11" ]] || TURN_CONTROL_REVIEW_REFUSED_RC=11
readonly TURN_CONTROL_SCHEMA_VERSION TURN_CONTROL_STOP_RC TURN_CONTROL_ERROR_RC
readonly TURN_CONTROL_REVIEW_ROUTED_RC TURN_CONTROL_REVIEW_REFUSED_RC
TURN_CONTROL_LOCK_WAIT_SECONDS="${TURN_CONTROL_LOCK_WAIT_SECONDS:-5}"
TURN_CONTROL_POLL_SECONDS="${TURN_CONTROL_POLL_SECONDS:-0.1}"
[[ "${TURN_LIMIT_CLAUDE_MIN_VERSION:-}" == "2.1.215" ]] \
  || TURN_LIMIT_CLAUDE_MIN_VERSION=2.1.215
readonly TURN_LIMIT_CLAUDE_MIN_VERSION
# shellcheck disable=SC2034 # Wrapper-visible output from launch validation.
TURN_LIMIT_ADAPTER_VERSION=""

_turn_limit_error() {
  printf 'turn-limit: %s\n' "$*" >&2
  return 1
}

_turn_limit_var_is_set() {
  [[ -n "${!1+x}" ]]
}

_turn_limit_valid_positive_integer() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

_turn_decimal_less_than() {
  local left="${1:-}" right="${2:-}" LC_ALL=C
  [[ "$left" =~ ^(0|[1-9][0-9]*)$ && "$right" =~ ^(0|[1-9][0-9]*)$ ]] \
    || return 2
  (( ${#left} < ${#right} )) && return 0
  (( ${#left} > ${#right} )) && return 1
  [[ "$left" < "$right" ]]
}

_turn_decimal_increment() {
  local value="${1:-}" result="" digit index carry=1
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
  for ((index = ${#value} - 1; index >= 0; index--)); do
    digit="${value:index:1}"
    if (( carry == 1 )); then
      if [[ "$digit" == "9" ]]; then
        digit=0
      else
        digit=$((10#$digit + 1))
        carry=0
      fi
    fi
    result="${digit}${result}"
  done
  (( carry == 0 )) || result="1${result}"
  printf '%s\n' "$result"
}

_turn_limit_effective_name() {
  local side="${1:-}"
  case "$side" in
    dev)
      if _turn_limit_var_is_set AGENT_DEV_TURN_LIMIT; then
        printf 'AGENT_DEV_TURN_LIMIT\n'
      elif _turn_limit_var_is_set AGENT_TURN_LIMIT; then
        printf 'AGENT_TURN_LIMIT\n'
      fi
      ;;
    review)
      if _turn_limit_var_is_set AGENT_REVIEW_TURN_LIMIT; then
        printf 'AGENT_REVIEW_TURN_LIMIT\n'
      elif _turn_limit_var_is_set AGENT_TURN_LIMIT; then
        printf 'AGENT_TURN_LIMIT\n'
      fi
      ;;
    *)
      _turn_limit_error "unknown side '${side}'; expected dev or review"
      return 2
      ;;
  esac
}

turn_limit_validate_config() {
  local side="${1:-all}" mode name value

  if _turn_limit_var_is_set TURN_LIMIT_MODE; then
    mode="$TURN_LIMIT_MODE"
    case "$mode" in
      warn|hard) ;;
      *)
        _turn_limit_error "TURN_LIMIT_MODE='${mode}' is invalid; expected warn or hard"
        return 1 # turn-control-branch: B001
        ;;
    esac
  fi

  case "$side" in
    dev|review)
      name="$(_turn_limit_effective_name "$side")" || return $?
      if [[ -n "$name" ]]; then
        value="${!name}"
        if ! _turn_limit_valid_positive_integer "$value"; then
          _turn_limit_error "${name}='${value}' is invalid; expected a positive integer matching ^[1-9][0-9]*$"
          return 1 # turn-control-branch: B002
        fi
      fi
      ;;
    all)
      turn_limit_validate_config dev || return 1
      turn_limit_validate_config review || return 1
      ;;
    *)
      _turn_limit_error "unknown validation side '${side}'; expected dev, review, or all"
      return 2
      ;;
  esac
  return 0
}

turn_limit_enabled() {
  local name
  name="$(_turn_limit_effective_name "${1:-}")" || return $?
  [[ -n "$name" ]]
}

turn_limit_effective_limit() {
  local side="${1:-}" name
  turn_limit_validate_config "$side" || return 1
  name="$(_turn_limit_effective_name "$side")" || return $?
  [[ -n "$name" ]] || return 1
  printf '%s\n' "${!name}"
}

turn_limit_effective_mode() {
  local side="${1:-}"
  turn_limit_validate_config "$side" || return 1
  if ! turn_limit_enabled "$side"; then
    printf 'disabled\n' # turn-control-branch: B003
  else
    printf '%s\n' "${TURN_LIMIT_MODE:-warn}" # turn-control-branch: B004
  fi
}

# turn_capability ADAPTER LANE MODE
#
# This pure lookup is the authoritative static matrix. Claude warn capability
# is conditional on the separate execution-host version probe performed by
# turn_limit_validate_launch. Synthetic is exposed for hermetic tests only;
# production launch validation always rejects it.
turn_capability() {
  local adapter="${1:-}" lane="${2:-}" mode="${3:-}"
  case "$lane" in
    dev-new|dev-resume|review-member) ;;
    *) return 1 ;;
  esac
  case "${adapter}:${mode}" in
    claude:warn|synthetic:warn|synthetic:hard) return 0 ;; # turn-control-branch: B005
    *) return 1 ;; # turn-control-branch: B006
  esac
}

turn_claude_version_normalize() {
  local output="${1:-}"
  if [[ "$output" =~ ^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+)([^0-9].*)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}" # turn-control-branch: B007
  else
    return 1 # turn-control-branch: B008
  fi
}

_turn_version_at_least() {
  local actual="${1:-}" minimum="${2:-}"
  local a_major a_minor a_patch m_major m_minor m_patch
  IFS=. read -r a_major a_minor a_patch <<<"$actual"
  IFS=. read -r m_major m_minor m_patch <<<"$minimum"
  [[ "$a_major" =~ ^[0-9]+$ && "$a_minor" =~ ^[0-9]+$ && "$a_patch" =~ ^[0-9]+$ ]] || return 1
  [[ "$m_major" =~ ^[0-9]+$ && "$m_minor" =~ ^[0-9]+$ && "$m_patch" =~ ^[0-9]+$ ]] || return 1
  (( 10#$a_major > 10#$m_major )) && return 0
  (( 10#$a_major < 10#$m_major )) && return 1
  (( 10#$a_minor > 10#$m_minor )) && return 0
  (( 10#$a_minor < 10#$m_minor )) && return 1
  (( 10#$a_patch >= 10#$m_patch ))
}

turn_claude_version_supported() {
  local normalized
  normalized="$(turn_claude_version_normalize "${1:-}")" || return 1
  _turn_version_at_least "$normalized" "$TURN_LIMIT_CLAUDE_MIN_VERSION"
}

turn_claude_version_probe() {
  local output normalized command_label
  local -a command_argv=(claude)
  if declare -p AGENT_LAUNCHER_ARGV >/dev/null 2>&1 \
      && (( ${#AGENT_LAUNCHER_ARGV[@]} > 0 )); then
    command_argv=("${AGENT_LAUNCHER_ARGV[@]}")
  fi
  command_label="${command_argv[*]} --version"
  output="$("${command_argv[@]}" --version 2>&1)" || {
    _turn_limit_error "Claude warn capability probe failed: '${command_label}' exited non-zero"
    return 1 # turn-control-branch: B009
  }
  normalized="$(turn_claude_version_normalize "$output")" || {
    _turn_limit_error "Claude warn capability probe returned unparseable version output: '${output}'"
    return 1
  }
  if ! _turn_version_at_least "$normalized" "$TURN_LIMIT_CLAUDE_MIN_VERSION"; then
    _turn_limit_error "Claude warn capability requires >= ${TURN_LIMIT_CLAUDE_MIN_VERSION}; probe returned '${normalized}'"
    return 1 # turn-control-branch: B010
  fi
  printf '%s\n' "$normalized" # turn-control-branch: B011
}

turn_limit_validate_launches() {
  if (( $# < 3 )); then
    _turn_limit_error "turn_limit_validate_launches expects ADAPTER SIDE LANE..."
    return 1
  fi
  local adapter="$1" side="$2"
  shift 2
  local limit mode version lane
  TURN_LIMIT_ADAPTER_VERSION=""
  turn_limit_validate_config "$side" || return 1
  turn_limit_enabled "$side" || return 0 # turn-control-branch: B012
  limit="$(turn_limit_effective_limit "$side")" || return 1
  mode="$(turn_limit_effective_mode "$side")" || return 1

  if [[ "$adapter" == "synthetic" ]]; then
    _turn_limit_error "adapter='synthetic' is test-only and is not reachable from production dispatch (mode='${mode}', limit='${limit}')"
    return 1 # turn-control-branch: B013
  fi
  for lane in "$@"; do
    if ! turn_capability "$adapter" "$lane" "$mode"; then
      _turn_limit_error "adapter='${adapter}' lane='${lane}' mode='${mode}' is unsupported; refusing turn-controlled launch with limit='${limit}'"
      return 1 # turn-control-branch: B014
    fi
  done
  if [[ "$adapter" == "claude" && "$mode" == "warn" ]]; then
    version="$(turn_claude_version_probe)" || return 1
    # shellcheck disable=SC2034 # Wrapper-visible output from launch validation.
    TURN_LIMIT_ADAPTER_VERSION="$version"
  else
    # shellcheck disable=SC2034 # Wrapper-visible output from launch validation.
    TURN_LIMIT_ADAPTER_VERSION="unknown"
  fi
  return 0
}

turn_limit_validate_launch() {
  turn_limit_validate_launches "${1:-}" "${2:-}" "${3:-}"
}

turn_accounting_identity() {
  if (( $# != 4 )); then
    _turn_limit_error "turn_accounting_identity expects RUN_ID SIDE MEMBER_ID ATTEMPT"
    return 1
  fi
  local invocation_id
  invocation_id="$(accounting_invocation_id "$1" "$2" "$3" "$4")" || {
    _turn_limit_error "accounting_invocation_id failed for turn control; refusing launch"
    return 1
  }
  printf '%s\n' "$invocation_id"
}

turn_accounting_begin() {
  if (( $# < 6 || $# > 7 )); then
    _turn_limit_error "turn_accounting_begin expects ISSUE RUN_ID SIDE MEMBER_ID ATTEMPT MODE [INVOCATION_ID]"
    return 1
  fi
  local issue="$1" run_id="$2" side="$3" member_id="$4" attempt="$5"
  local mode="$6" supplied_id="${7:-}" invocation_id
  case "$mode" in
    warn|hard) ;;
    *)
      _turn_limit_error "turn accounting mode '${mode}' is invalid; expected warn or hard"
      return 1 # turn-control-branch: B077
      ;;
  esac

  invocation_id="$(turn_accounting_identity \
    "$run_id" "$side" "$member_id" "$attempt")" || return 1 # turn-control-branch: B078
  if [[ -n "$supplied_id" && "$supplied_id" != "$invocation_id" ]]; then
    _turn_limit_error "turn accounting identity '${supplied_id}' does not match canonical '${invocation_id}'"
    return 1 # turn-control-branch: B079
  fi

  if [[ "$mode" == "hard" ]] \
      && ! accounting_start "$issue" "$invocation_id" "$side" \
        "$run_id" "$member_id" "$attempt"; then
    _turn_limit_error "accounting_start failed for hard turn control (${invocation_id}); refusing launch"
    return 1 # turn-control-branch: B080
  fi

  printf '%s\n' "$invocation_id" # turn-control-branch: B081
}

turn_accounting_commit_succeeded() {
  jq -e 'type == "object" and .commit_failed == false' \
    <<<"${1:-}" >/dev/null 2>&1
}

_turn_control_valid_token() {
  local value="${1:-}"
  [[ "${#value}" -ge 1 && "${#value}" -le 160 ]] \
    && [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]
}

_turn_control_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

_turn_control_path_is_nonregular() {
  local path="${1:-}"
  [[ -L "$path" ]] || { [[ -e "$path" ]] && [[ ! -f "$path" ]]; }
}

_turn_control_dir() {
  local run_dir="${RUN_DIR:-}" dir
  [[ -n "$run_dir" ]] || {
    _turn_limit_error "RUN_DIR is required for turn control"
    return 1
  }
  dir="${run_dir}/turn-control"
  [[ ! -L "$dir" ]] || {
    _turn_limit_error "refusing symlinked turn-control directory: ${dir}"
    return 1
  }
  mkdir -p "$dir" || return 1
  # A restrictive umask still protects the directory if chmod is unavailable.
  chmod 700 "$dir" 2>/dev/null || true
  printf '%s\n' "$dir"
}

_turn_control_lock() {
  local file="$1"
  local -n _out_fd="$2"
  local lock_file="${file}.lock" opened_fd
  _out_fd=""
  command -v flock >/dev/null 2>&1 || {
    _turn_limit_error "flock is required for turn-control records"
    return 1
  }
  if _turn_control_path_is_nonregular "$lock_file"; then
    _turn_limit_error "refusing non-regular lock path: ${lock_file}"
    return 1
  fi
  exec {opened_fd}>>"$lock_file" || return 1
  if ! flock -w "$TURN_CONTROL_LOCK_WAIT_SECONDS" "$opened_fd" 2>/dev/null; then
    exec {opened_fd}>&-
    _turn_limit_error "timed out waiting for turn-control lock: ${lock_file}"
    return 1
  fi
  _out_fd="$opened_fd"
}

_turn_control_unlock() {
  local -n _fd="$1"
  [[ -n "$_fd" ]] && exec {_fd}>&-
  _fd=""
}

_turn_control_sync_file() {
  local file="$1"
  command -v sync >/dev/null 2>&1 || {
    _turn_limit_error "sync is required for turn-control records"
    return 1
  }
  sync -d "$file" 2>/dev/null || {
    _turn_limit_error "cannot sync turn-control data: ${file}"
    return 1
  }
}

_turn_control_sync_dir() {
  local dir="$1"
  command -v sync >/dev/null 2>&1 || {
    _turn_limit_error "sync is required for turn-control records"
    return 1
  }
  sync -f "$dir" 2>/dev/null || {
    _turn_limit_error "cannot sync turn-control directory: ${dir}"
    return 1
  }
}

_turn_control_confirm_durable() {
  local file="$1" dir
  dir="$(dirname "$file")"
  _turn_control_sync_file "$file" && _turn_control_sync_dir "$dir"
}

_turn_control_write_atomic() {
  local file="$1" json="$2" dir base tmp
  dir="$(dirname "$file")"
  base="$(basename "$file")"
  if _turn_control_path_is_nonregular "$file"; then
    _turn_limit_error "refusing non-regular turn-control target: ${file}"
    return 1
  fi
  tmp="$(mktemp "${dir}/.${base}.tmp.XXXXXX" 2>/dev/null)" || {
    _turn_limit_error "cannot create turn-control temporary file in ${dir}"
    return 1
  }
  if ! (umask 077; printf '%s\n' "$json" >"$tmp"); then
    # Preserve the original write failure if best-effort scratch cleanup also fails.
    rm -f "$tmp" 2>/dev/null || true
    _turn_limit_error "cannot write turn-control temporary file in ${dir}"
    return 1
  fi
  # The file was created under umask 077, so chmod failure does not broaden access.
  chmod 600 "$tmp" 2>/dev/null || true
  if ! _turn_control_sync_file "$tmp"; then
    # Preserve the sync failure if best-effort scratch cleanup also fails.
    rm -f "$tmp" 2>/dev/null || true
    return 1
  fi
  if ! mv -fT "$tmp" "$file" 2>/dev/null; then
    # Preserve the replace failure if best-effort scratch cleanup also fails.
    rm -f "$tmp" 2>/dev/null || true
    _turn_limit_error "cannot replace turn-control target: ${file}"
    return 1
  fi
  _turn_control_sync_dir "$dir"
}

_turn_control_load() {
  local file="${1:-${TURN_CONTROL_FILE:-}}"
  [[ -n "$file" && -f "$file" && ! -L "$file" ]] || return 1
  jq -ce --argjson schema "$TURN_CONTROL_SCHEMA_VERSION" '
    select(type == "object"
    and .schema_version == $schema
    and ((.issue | type) == "number")
    and (.issue >= 1 and .issue == (.issue | floor))
    and (.side == "dev" or .side == "review")
    and ((.run_id | type) == "string" and (.run_id | length) > 0)
    and ((.invocation_id | type) == "string" and (.invocation_id | length) > 0)
    and ((.member | type) == "string" and (.member | length) > 0)
    and ((.adapter | type) == "string" and (.adapter | length) > 0)
    and ((.adapter_version | type) == "string" and (.adapter_version | length) > 0)
    and ((.observed_count | type) == "string")
    and (.observed_count | test("^(0|[1-9][0-9]*)$"))
    and ((.limit | type) == "string")
    and (.limit | test("^[1-9][0-9]*$"))
    and (.mode == "warn" or .mode == "hard")
    and (.state == "running"
      or .state == "stop-requested"
      or .state == "terminating"
      or .state == "completed"
      or .state == "terminal-transitioned")
    and (.winner == null
      or .winner == "timeout"
      or .winner == "turn-cap"
      or .winner == "fanout-cancel")
    and (if .state == "running" or .state == "completed"
      then .winner == null
      else .winner != null
      end)
    and (.evidence | type == "array")
    and (.late | type == "array")
    and ((.created_at | type) == "string" and (.created_at | length) > 0)
    and ((.updated_at | type) == "string" and (.updated_at | length) > 0)
    and all(.evidence[];
      type == "object"
      and ((.issue | type) == "number")
      and (.side == "dev" or .side == "review")
      and ((.run_id | type) == "string" and (.run_id | length) > 0)
      and ((.invocation_id | type) == "string" and (.invocation_id | length) > 0)
      and ((.member | type) == "string" and (.member | length) > 0)
      and ((.adapter | type) == "string" and (.adapter | length) > 0)
      and ((.adapter_version | type) == "string" and (.adapter_version | length) > 0)
      and ((.observed_count | type) == "string"
        and (.observed_count | test("^(0|[1-9][0-9]*)$")))
      and ((.limit | type) == "string"
        and (.limit | test("^[1-9][0-9]*$")))
      and (.mode == "warn" or .mode == "hard")
      and (.action == "warned"
        or .action == "stop-requested"
        or .action == "terminated"
        or .action == "late-ignored"
        or .action == "cancelled-sibling")
      and (.winning_reason == null
        or .winning_reason == "timeout"
        or .winning_reason == "turn-cap"
        or .winning_reason == "fanout-cancel")
      and ((.ts | type) == "string" and (.ts | length) > 0))
    and all(.late[];
      type == "object"
      and (.reason == "timeout"
        or .reason == "turn-cap"
        or .reason == "fanout-cancel")
      and .action == "late-ignored"
      and ((.ts | type) == "string" and (.ts | length) > 0)))
  ' "$file" 2>/dev/null || return 1
}

# _turn_control_project_fields JSON JQ_ARRAY VARIABLE...
#
# Project related fields in one jq pass. Optional values use a non-empty
# sentinel in the caller's projection so Bash's whitespace IFS keeps columns.
_turn_control_project_fields() {
  local json="${1:-}" projection="${2:-}"
  shift 2
  local tsv field_name index=0
  local -a field_values=()
  tsv="$(jq -er "$projection | @tsv" <<<"$json")" || return 1
  IFS=$'\t' read -r -a field_values <<<"$tsv"
  (( ${#field_values[@]} == $# )) || return 1
  for field_name in "$@"; do
    [[ "$field_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    printf -v "$field_name" '%s' "${field_values[$index]}"
    index=$((index + 1))
  done
}

turn_control_init() {
  if (( $# != 9 )); then
    _turn_limit_error "turn_control_init expects ISSUE SIDE RUN_ID INVOCATION MEMBER ADAPTER VERSION LIMIT MODE"
    return 1
  fi
  local issue="$1" side="$2" run_id="$3" invocation="$4" member="$5"
  local adapter="$6" adapter_version="$7" limit="$8" mode="$9"
  local dir file fd="" now json

  [[ "$issue" =~ ^[1-9][0-9]*$ ]] || {
    _turn_limit_error "invalid issue '${issue}'"
    return 1
  }
  case "$side" in dev|review) ;; *) _turn_limit_error "invalid side '${side}'"; return 1 ;; esac
  for value in "$run_id" "$invocation" "$member" "$adapter" "$adapter_version"; do
    _turn_control_valid_token "$value" || {
      _turn_limit_error "unsafe turn-control identity token '${value}'"
      return 1
    }
  done
  _turn_limit_valid_positive_integer "$limit" || {
    _turn_limit_error "invalid turn limit '${limit}'"
    return 1
  }
  case "$mode" in warn|hard) ;; *) _turn_limit_error "invalid turn mode '${mode}'"; return 1 ;; esac

  dir="$(_turn_control_dir)" || return 1
  file="${dir}/${invocation}.json"
  if _turn_control_path_is_nonregular "$file"; then
    _turn_limit_error "refusing non-regular turn-control path: ${file}"
    return 1
  fi
  _turn_control_lock "$file" fd || return 1
  if [[ ! -f "$file" ]]; then
    now="$(_turn_control_now)"
    json="$(jq -nc \
      --argjson schema "$TURN_CONTROL_SCHEMA_VERSION" \
      --argjson issue "$issue" --arg side "$side" --arg run_id "$run_id" \
      --arg invocation_id "$invocation" --arg member "$member" \
      --arg adapter "$adapter" --arg adapter_version "$adapter_version" \
      --arg limit "$limit" --arg mode "$mode" --arg ts "$now" '
        {
          schema_version: $schema,
          issue: $issue,
          side: $side,
          run_id: $run_id,
          invocation_id: $invocation_id,
          member: $member,
          adapter: $adapter,
          adapter_version: $adapter_version,
          observed_count: "0",
          limit: $limit,
          mode: $mode,
          state: "running",
          winner: null,
          evidence: [],
          late: [],
          created_at: $ts,
          updated_at: $ts
        }'
    )" || {
      _turn_control_unlock fd
      return 1
    }
    _turn_control_write_atomic "$file" "$json" || {
      _turn_control_unlock fd
      return 1
    }
    : "turn-control-branch: B015"
  else
    json="$(_turn_control_load "$file")" || {
      _turn_control_unlock fd
      _turn_limit_error "existing turn-control record is malformed: ${file}"
      return 1
    }
    if ! jq -e \
        --argjson issue "$issue" --arg side "$side" --arg run_id "$run_id" \
        --arg invocation_id "$invocation" --arg member "$member" \
        --arg adapter "$adapter" --arg adapter_version "$adapter_version" \
        --arg limit "$limit" --arg mode "$mode" '
          .issue == $issue
          and .side == $side
          and .run_id == $run_id
          and .invocation_id == $invocation_id
          and .member == $member
          and .adapter == $adapter
          and .adapter_version == $adapter_version
          and .limit == $limit
          and .mode == $mode
        ' <<<"$json" >/dev/null; then
      _turn_control_unlock fd
      _turn_limit_error "existing turn-control record identity does not match requested invocation: ${file}"
      return 1
    fi
    _turn_control_confirm_durable "$file" || {
      _turn_control_unlock fd
      return 1
    }
    : "turn-control-branch: B016"
  fi
  _turn_control_unlock fd

  TURN_CONTROL_FILE="$file"
  TURN_CONTROL_OBSERVE_ACTIVE=1
  if [[ "$mode" == "hard" ]]; then
    TURN_CONTROL_HARD_ACTIVE=1
  else
    TURN_CONTROL_HARD_ACTIVE=0
  fi
  if [[ "$side" == "review" ]]; then
    TURN_CONTROL_FANOUT_TRIP_FILE="${dir}/fanout-trip.json"
  else
    TURN_CONTROL_FANOUT_TRIP_FILE=""
  fi
  export TURN_CONTROL_FILE TURN_CONTROL_FANOUT_TRIP_FILE
  export TURN_CONTROL_OBSERVE_ACTIVE TURN_CONTROL_HARD_ACTIVE
}

_turn_control_evidence_jq() {
  cat <<'JQ'
def evidence($action; $reason; $ts):
  {
    issue: .issue,
    side: .side,
    run_id: .run_id,
    invocation_id: .invocation_id,
    member: .member,
    adapter: .adapter,
    adapter_version: .adapter_version,
    observed_count: .observed_count,
    limit: .limit,
    mode: .mode,
    action: $action,
    winning_reason: (if $reason == "" then null else $reason end),
    ts: $ts
  };
JQ
}

observe_completed_turn() {
  local record="${1:-}" file="${TURN_CONTROL_FILE:-}" type fd="" json now filter
  local mode count limit next_count warn=false
  [[ -n "$file" && -f "$file" && "$record" == \{* ]] || return 0
  type="$(jq -r 'if type == "object" then .type // empty else empty end' <<<"$record" 2>/dev/null)" || return 0
  [[ "$type" == "assistant" ]] || return 0 # turn-control-branch: B017

  _turn_control_lock "$file" fd || return 1
  json="$(_turn_control_load "$file")" || {
    _turn_control_unlock fd
    return 1
  }
  _turn_control_project_fields "$json" \
    '[.mode, .observed_count, .limit]' mode count limit || {
    _turn_control_unlock fd
    return 1
  }
  next_count="$(_turn_decimal_increment "$count")" || {
    _turn_control_unlock fd
    return 1
  }
  if [[ "$mode" == "warn" ]] \
      && ! _turn_decimal_less_than "$next_count" "$limit"; then
    warn=true
  fi
  now="$(_turn_control_now)"
  filter="$(_turn_control_evidence_jq)
    .observed_count = \$count
    | .updated_at = \$ts
    | if \$warn
         and (any(.evidence[]; .action == \"warned\") | not)
      then .evidence += [evidence(\"warned\"; \"\"; \$ts)]
      else .
      end"
  json="$(jq -c --arg ts "$now" --arg count "$next_count" \
    --argjson warn "$warn" "$filter" <<<"$json")" || {
    _turn_control_unlock fd
    return 1
  }
  _turn_control_write_atomic "$file" "$json"
  local rc=$?
  _turn_control_unlock fd
  : "turn-control-branch: B018"
  return "$rc"
}

_turn_control_append_action() {
  local action="${1:-}" reason="${2:-}" file="${TURN_CONTROL_FILE:-}"
  local fd="" json now filter
  [[ -n "$file" && -f "$file" ]] || return 1
  _turn_control_lock "$file" fd || return 1
  json="$(_turn_control_load "$file")" || {
    _turn_control_unlock fd
    return 1
  }
  now="$(_turn_control_now)"
  filter="$(_turn_control_evidence_jq)
    if any(.evidence[]; .action == \$action)
    then .
    else .evidence += [evidence(\$action; \$reason; \$ts)] | .updated_at = \$ts
    end"
  json="$(jq -c --arg action "$action" --arg reason "$reason" --arg ts "$now" \
    "$filter" <<<"$json")" || {
    _turn_control_unlock fd
    return 1
  }
  _turn_control_write_atomic "$file" "$json"
  local rc=$?
  _turn_control_unlock fd
  return "$rc"
}

turn_control_request_stop() {
  local reason="${1:-}" file="${TURN_CONTROL_FILE:-}" fd="" json prior_json
  local now state winner filter
  case "$reason" in timeout|turn-cap|fanout-cancel) ;; *)
    _turn_limit_error "invalid controller stop reason '${reason}'"
    return 1
    ;;
  esac
  [[ -n "$file" && -f "$file" ]] || return 1
  _turn_control_lock "$file" fd || return 1
  json="$(_turn_control_load "$file")" || {
    _turn_control_unlock fd
    return 1
  }
  prior_json="$json"
  _turn_control_project_fields "$json" \
    '[.state, (.winner // "-")]' state winner || {
    _turn_control_unlock fd
    return 1
  }
  [[ "$winner" == "-" ]] && winner=""
  now="$(_turn_control_now)"

  if [[ "$state" == "running" && -z "$winner" ]]; then
    : "turn-control-branch: B019"
    filter="$(_turn_control_evidence_jq)
      .state = \"stop-requested\"
      | .winner = \$reason
      | .updated_at = \$ts
      | if any(.evidence[]; .action == \"stop-requested\")
        then .
        else .evidence += [evidence(\"stop-requested\"; \$reason; \$ts)]
        end"
  elif [[ "$winner" == "$reason" ]]; then
    _turn_control_confirm_durable "$file" || {
      _turn_control_unlock fd
      return 1
    }
    _turn_control_unlock fd
    return 0 # turn-control-branch: B020
  else
    : "turn-control-branch: B021"
    filter="$(_turn_control_evidence_jq)
      .late += [{reason: \$reason, action: \"late-ignored\", ts: \$ts}]
      | .updated_at = \$ts
      | if any(.evidence[]; .action == \"late-ignored\")
        then .
        else .evidence += [evidence(\"late-ignored\"; (.winner // \"\"); \$ts)]
        end"
  fi

  json="$(jq -c --arg reason "$reason" --arg ts "$now" "$filter" <<<"$json")" || {
    _turn_control_unlock fd
    return 1
  }
  _turn_control_write_atomic "$file" "$json"
  local rc=$?
  if (( rc != 0 )); then
    # The atomic rename becomes visible before the parent-directory sync that
    # makes it authoritative. Restore the prior record while still holding the
    # invocation lock so post-exit reconciliation cannot promote an
    # unconfirmed stop over natural completion.
    local visible_json=""
    visible_json="$(_turn_control_load "$file" 2>/dev/null || true)"
    if [[ -n "$visible_json" && "$visible_json" == "$json" ]]; then
      _turn_control_write_atomic "$file" "$prior_json" >/dev/null 2>&1 || true # Preserve the original durability failure if rollback also fails.
    fi
  fi
  _turn_control_unlock fd
  return "$rc"
}

turn_control_mark_completed() {
  local file="${TURN_CONTROL_FILE:-}" fd="" json now
  [[ -n "$file" && -f "$file" ]] || return 1
  _turn_control_lock "$file" fd || return 1
  json="$(_turn_control_load "$file")" || {
    _turn_control_unlock fd
    return 1
  }
  case "$(jq -r .state <<<"$json")" in
    running)
      : "turn-control-branch: B022"
      now="$(_turn_control_now)"
      json="$(jq -c --arg ts "$now" '.state = "completed" | .updated_at = $ts' <<<"$json")" || {
        _turn_control_unlock fd
        return 1
      }
      _turn_control_write_atomic "$file" "$json" || {
        _turn_control_unlock fd
        return 1
      }
      ;;
    completed)
      _turn_control_confirm_durable "$file" || {
        _turn_control_unlock fd
        return 1
      }
      ;;
    *)
      : "turn-control-branch: B023"
      ;;
  esac
  _turn_control_unlock fd
}

turn_control_mark_terminating() {
  local file="${TURN_CONTROL_FILE:-}" fd="" json now state reason filter
  [[ -n "$file" && -f "$file" ]] || return 1
  _turn_control_lock "$file" fd || return 1
  json="$(_turn_control_load "$file")" || {
    _turn_control_unlock fd
    return 1
  }
  _turn_control_project_fields "$json" \
    '[.state, (.winner // "-")]' state reason || {
    _turn_control_unlock fd
    return 1
  }
  [[ "$reason" == "-" ]] && reason=""
  case "$state" in
    stop-requested)
      : "turn-control-branch: B024"
      now="$(_turn_control_now)"
      filter="$(_turn_control_evidence_jq)
        .state = \"terminating\"
        | .updated_at = \$ts
        | if any(.evidence[]; .action == \"terminated\")
          then .
          else .evidence += [evidence(\"terminated\"; \$reason; \$ts)]
          end"
      json="$(jq -c --arg ts "$now" --arg reason "$reason" "$filter" <<<"$json")" || {
        _turn_control_unlock fd
        return 1
      }
      _turn_control_write_atomic "$file" "$json" || {
        _turn_control_unlock fd
        return 1
      }
      ;;
    terminating|terminal-transitioned)
      : "turn-control-branch: B025"
      # A prior atomic rename may be visible even though its directory sync
      # failed. Confirm both the file and parent directory before treating an
      # idempotent retry as durable enough to authorize signaling.
      _turn_control_confirm_durable "$file" || {
        _turn_control_unlock fd
        return 1
      }
      ;;
    *)
      _turn_control_unlock fd
      return 1
      ;;
  esac
  _turn_control_unlock fd
}

turn_control_mark_terminal_transitioned() {
  local file="${TURN_CONTROL_FILE:-}" fd="" json now
  [[ -n "$file" && -f "$file" ]] || return 1
  _turn_control_lock "$file" fd || return 1
  json="$(_turn_control_load "$file")" || {
    _turn_control_unlock fd
    return 1
  }
  case "$(jq -r .state <<<"$json")" in
    terminating)
      : "turn-control-branch: B026"
      now="$(_turn_control_now)"
      json="$(jq -c --arg ts "$now" '.state = "terminal-transitioned" | .updated_at = $ts' <<<"$json")" || {
        _turn_control_unlock fd
        return 1
      }
      _turn_control_write_atomic "$file" "$json" || {
        _turn_control_unlock fd
        return 1
      }
      ;;
    terminal-transitioned)
      _turn_control_confirm_durable "$file" || {
        _turn_control_unlock fd
        return 1
      }
      ;;
    *)
      _turn_control_unlock fd
      return 1 # turn-control-branch: B027
      ;;
  esac
  _turn_control_unlock fd
}

turn_control_winner() {
  local json
  json="$(_turn_control_load "${TURN_CONTROL_FILE:-}")" || return 1
  jq -r '.winner // empty' <<<"$json"
}

_turn_fanout_trip_write() {
  # shellcheck disable=SC2034 # fd is populated and closed through nameref helpers.
  local file="${TURN_CONTROL_FANOUT_TRIP_FILE:-}" record fd="" now json
  local issue run_id invocation_id member
  [[ -n "$file" ]] || return 0
  record="$(_turn_control_load "${TURN_CONTROL_FILE:-}")" || return 1
  mkdir -p "$(dirname "$file")" || return 1
  if _turn_control_path_is_nonregular "$file"; then
    _turn_limit_error "refusing non-regular fanout trip path: ${file}"
    return 1
  fi
  _turn_control_lock "$file" fd || return 1
  if [[ ! -f "$file" ]]; then
    now="$(_turn_control_now)"
    _turn_control_project_fields "$record" \
      '[.issue, .run_id, .invocation_id, .member]' \
      issue run_id invocation_id member || {
      _turn_control_unlock fd
      return 1
    }
    json="$(jq -nc \
      --argjson schema "$TURN_CONTROL_SCHEMA_VERSION" \
      --argjson issue "$issue" \
      --arg run_id "$run_id" \
      --arg invocation_id "$invocation_id" \
      --arg member "$member" \
      --arg ts "$now" '{
        schema_version: $schema,
        issue: $issue,
        run_id: $run_id,
        invocation_id: $invocation_id,
        member: $member,
        reason: "turn-cap",
        ts: $ts
      }'
    )" || {
      _turn_control_unlock fd
      return 1
    }
    _turn_control_write_atomic "$file" "$json" || {
      _turn_control_unlock fd
      return 1
    }
  else
    # Concurrent caps may select the already-published trigger, but malformed
    # or unconfirmed records never count as a successful publication.
    if ! turn_fanout_trip_active "$file" \
        || ! _turn_control_confirm_durable "$file"; then
      _turn_control_unlock fd
      return 1
    fi
  fi
  _turn_control_unlock fd
}

turn_control_ensure_fanout_trip() {
  local file="${TURN_CONTROL_FANOUT_TRIP_FILE:-}" record side winner
  [[ -n "$file" ]] || return 0
  record="$(_turn_control_load "${TURN_CONTROL_FILE:-}")" || return 1
  _turn_control_project_fields "$record" \
    '[.side, (.winner // "-")]' side winner || return 1
  [[ "$winner" == "-" ]] && winner=""
  [[ "$side" == "review" && "$winner" == "turn-cap" ]] || return 0
  _turn_fanout_trip_write
}

_turn_fanout_trip_load() {
  local file="${1:-${TURN_CONTROL_FANOUT_TRIP_FILE:-}}"
  [[ -n "$file" && -f "$file" && ! -L "$file" ]] || return 1
  jq -ce --argjson schema "$TURN_CONTROL_SCHEMA_VERSION" '
    select(type == "object"
    and .schema_version == $schema
    and ((.issue | type) == "number")
    and (.issue >= 1 and .issue == (.issue | floor))
    and ((.run_id | type) == "string"
      and (.run_id | test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$")))
    and ((.invocation_id | type) == "string"
      and (.invocation_id | test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$")))
    and ((.member | type) == "string"
      and (.member | test("^[A-Za-z0-9][A-Za-z0-9._:-]{0,159}$")))
    and .reason == "turn-cap"
    and ((.ts | type) == "string" and (.ts | length) > 0))
  ' "$file" 2>/dev/null || return 1
}

turn_fanout_trip_active() {
  local file="${1:-${TURN_CONTROL_FANOUT_TRIP_FILE:-}}" trip trigger_file trigger
  trip="$(_turn_fanout_trip_load "$file")" || return 1
  trigger_file="$(dirname "$file")/$(jq -r .invocation_id <<<"$trip").json"
  trigger="$(_turn_control_load "$trigger_file")" || return 1
  jq -e --argjson trip "$trip" '
    .issue == $trip.issue
    and .run_id == $trip.run_id
    and .invocation_id == $trip.invocation_id
    and .member == $trip.member
    and .winner == "turn-cap"
  ' <<<"$trigger" >/dev/null 2>&1
}

turn_control_sync_fanout_trip() {
  local trip_file="${TURN_CONTROL_FANOUT_TRIP_FILE:-}" record current trigger winner
  turn_fanout_trip_active "$trip_file" || return 1
  record="$(_turn_control_load "${TURN_CONTROL_FILE:-}")" || return 1
  current="$(jq -r .invocation_id <<<"$record")"
  trigger="$(jq -r .invocation_id "$trip_file")" || return 1
  [[ "$current" != "$trigger" ]] || return 0
  turn_control_request_stop fanout-cancel || return 1
  winner="$(turn_control_winner 2>/dev/null)" || return 1
  [[ "$winner" == "fanout-cancel" ]] || return 0
  _turn_control_append_action cancelled-sibling fanout-cancel
}

admit_next_request() {
  local record count limit mode side
  # Hard admission cannot prove the completed count when its durable state is
  # absent or malformed. Deny rather than admitting a potentially violating
  # request; synthetic is currently the only caller of this contract.
  record="$(_turn_control_load "${TURN_CONTROL_FILE:-}")" \
    || return 1 # turn-control-branch: B028
  _turn_control_project_fields "$record" \
    '[.mode, .observed_count, .limit, .side]' \
    mode count limit side || return 1
  [[ "$mode" == "hard" ]] || return 0
  if _turn_decimal_less_than "$count" "$limit"; then
    return 0 # turn-control-branch: B029
  fi
  : "turn-control-branch: B030"
  turn_control_request_stop turn-cap || return 1
  # A lost winner read fails closed before publishing a fan-out trip.
  [[ "$(turn_control_winner 2>/dev/null || true)" == "turn-cap" ]] || return 1
  if [[ "$side" == "review" ]]; then
    local publish_attempt published=false
    for publish_attempt in 1 2; do
      if turn_control_ensure_fanout_trip; then
        published=true
        break
      fi
      sleep "$TURN_CONTROL_POLL_SECONDS"
    done
    [[ "$published" == "true" ]] || return 1
  fi
  return 1
}

turn_control_route_terminal() {
  local issue="${1:-}" owner="${2:-}" record state winner invocation
  record="$(_turn_control_load "${TURN_CONTROL_FILE:-}")" || return 1
  _turn_control_project_fields "$record" \
    '[.state, (.winner // "-"), .invocation_id]' \
    state winner invocation || return 1
  [[ "$winner" == "-" ]] && winner=""
  [[ "$winner" == "turn-cap" ]] || return 0 # turn-control-branch: B031
  case "$state" in
    terminating|terminal-transitioned) ;;
    *)
      _turn_limit_error "turn-cap invocation '${invocation}' cannot route terminally from lifecycle state '${state}'"
      return 1
      ;;
  esac
  if ! declare -F terminal_intent_write >/dev/null 2>&1; then
    _turn_limit_error "terminal_intent_write is required to route a turn-cap winner"
    return 1
  fi
  terminal_intent_write "$issue" "$invocation" "$invocation" turn-cap "$owner"
}

turn_control_recovery_stage() {
  if (( $# < 2 || $# > 3 )); then
    _turn_limit_error "turn_control_recovery_stage expects ISSUE OWNER [ACCOUNTING_RECOVERY_JSON]"
    return 1
  fi
  local issue="$1" owner="$2" accounting_recovery="${3:-}"
  local record invocation winner state
  record="$(_turn_control_load "${TURN_CONTROL_FILE:-}")" || return 1
  _turn_control_project_fields "$record" \
    '[.invocation_id, (.winner // "-"), .state]' \
    invocation winner state || return 1
  [[ "$winner" == "turn-cap" \
      && ( "$state" == "terminating" || "$state" == "terminal-transitioned" ) ]] \
    || return 1
  declare -F token_budget_recovery_pointer_stage >/dev/null 2>&1 || return 1
  token_budget_recovery_pointer_stage \
    "$issue" "$invocation" "$invocation" turn-cap "$owner" \
    "$TURN_CONTROL_FILE" "$accounting_recovery"
}

turn_control_recover_pending_intent() {
  if (( $# != 2 )); then
    _turn_limit_error "turn_control_recover_pending_intent expects ISSUE OWNER"
    return 1
  fi
  local issue="$1" owner="$2" candidates candidate invocation reason live_intent
  declare -F token_budget_recovery_pointer_read >/dev/null 2>&1 || return 1
  candidates="$(token_budget_recovery_pointer_read "$issue" "$owner")" || return 20
  candidate="$(jq -ce '
    [ .[] | select(.reason == "turn-cap") ] | first // null
  ' <<<"$candidates")" || return 20
  [[ "$candidate" != "null" ]] || return 0
  invocation="$(jq -er '.invocation' <<<"$candidate")" || return 20
  reason="$(jq -er '.reason' <<<"$candidate")" || return 20
  terminal_intent_write \
    "$issue" "$invocation" "$invocation" "$reason" "$owner" || return 20
  live_intent="$(terminal_intent_read "$issue")" || return 20
  jq -e \
    --argjson issue "$issue" \
    --arg invocation "$invocation" \
    --arg owner "$owner" '
      .issue == $issue
      and .intent == $invocation
      and .invocation == $invocation
      and .reason == "turn-cap"
      and .owner == $owner
    ' >/dev/null 2>&1 <<<"$live_intent" || return 20
  return 10
}

_turn_control_recovery_complete_local() {
  if (( $# != 2 )); then
    return 1
  fi
  local issue="$1" owner="$2" pointer_file pointer invocation record_path record
  local recovery_invocation recovery_reason recovery_record_path
  local recovery_state recovery_winner
  pointer_file="$(_token_budget_recovery_pointer_path "$issue" "$owner")" || return 1
  [[ -f "$pointer_file" && ! -L "$pointer_file" ]] || return 1
  pointer="$(jq -ce \
    --argjson issue "$issue" --arg owner "$owner" '
      .invocation as $primary
      |
      select(
        .schema_version == 1
        and .issue == $issue
        and .owner == $owner
        and .reason == "turn-cap"
        and (.invocation | test("^inv-v1-[0-9a-f]{24}$"))
        and ((.record_path | type) == "string")
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
          and (.record_path | type) == "string"
          and (.record_path | startswith("/")))
      )
    ' "$pointer_file" 2>/dev/null)" || return 1
  _turn_control_project_fields "$pointer" \
    '[.invocation, .record_path]' invocation record_path || return 1
  [[ -f "$record_path" && ! -L "$record_path" \
      && "${record_path##*/}" == "${invocation}.json" ]] || return 1
  record="$(_turn_control_load "$record_path")" || return 1
  jq -e \
    --argjson issue "$issue" --arg invocation "$invocation" '
      .issue == $issue
      and .invocation_id == $invocation
      and .winner == "turn-cap"
      and (.state == "terminating" or .state == "terminal-transitioned")
    ' >/dev/null 2>&1 <<<"$record" || return 1
  TURN_CONTROL_FILE="$record_path" turn_control_mark_terminal_transitioned \
    || return 1
  while IFS=$'\t' read -r \
      recovery_invocation recovery_reason recovery_record_path; do
    [[ -f "$recovery_record_path" && ! -L "$recovery_record_path" \
        && "${recovery_record_path##*/}" == "${recovery_invocation}.json" ]] \
      || return 1
    record="$(_turn_control_load "$recovery_record_path")" || return 1
    _turn_control_project_fields "$record" \
      '[.state, (.winner // "-")]' recovery_state recovery_winner || return 1
    case "$recovery_reason" in
      turn-cap)
        [[ "$recovery_winner" == "turn-cap" ]] || return 1
        ;;
      fanout-cancelled)
        [[ "$recovery_winner" == "fanout-cancel" ]] || return 1
        ;;
      *)
        continue
        ;;
    esac
    if [[ "$recovery_state" == "stop-requested" ]]; then
      TURN_CONTROL_FILE="$recovery_record_path" \
        turn_control_mark_terminating || return 1
      recovery_state="terminating"
    fi
    if [[ "$recovery_state" == "terminating" ]]; then
      TURN_CONTROL_FILE="$recovery_record_path" \
        turn_control_mark_terminal_transitioned || return 1
    elif [[ "$recovery_state" != "terminal-transitioned" ]]; then
      return 1
    fi
  done < <(jq -r '
    .accounting_recovery[]
    | [.invocation,.reason,.record_path]
    | @tsv
  ' <<<"$pointer")
  TOKEN_BUDGET_FORCE_LOCAL=1 \
    token_budget_recovery_pointer_clear "$issue" "$owner" "$invocation"
}

turn_control_recovery_complete() {
  if (( $# != 2 )); then
    _turn_limit_error "turn_control_recovery_complete expects ISSUE OWNER"
    return 1
  fi
  if [[ "${EXECUTION_BACKEND:-local}" == "remote-aws-ssm" \
      && "${TOKEN_BUDGET_FORCE_LOCAL:-0}" != "1" ]]; then
    token_budget_remote_recovery_pointer \
      turn-recovery-complete "$1" "$2"
    return
  fi
  _turn_control_recovery_complete_local "$1" "$2"
}

turn_control_complete_review_records() {
  if (( $# != 2 )); then
    _turn_limit_error "turn_control_complete_review_records expects RECORDS_ARRAY MODE"
    return 1
  fi
  local -n record_files="$1"
  local mode="$2" record_file
  [[ "$mode" == "warn" || "$mode" == "hard" ]] || return 1
  for record_file in "${record_files[@]}"; do
    [[ -n "$record_file" ]] || continue
    if ! TURN_CONTROL_FILE="$record_file" turn_control_mark_completed; then
      if [[ "$mode" == "hard" ]]; then
        return 1
      fi
      _turn_limit_error "WARN: unable to persist warn-mode review completion; continuing without enforcement"
      :
    fi
  done
}

turn_control_sync_review_trip_records() {
  if (( $# != 2 )); then
    _turn_limit_error "turn_control_sync_review_trip_records expects TRIP_FILE RECORDS_ARRAY"
    return 1
  fi
  local trip_file="$1" record_file record state winner attempt synced
  local TURN_CONTROL_FILE="${TURN_CONTROL_FILE:-}"
  local TURN_CONTROL_FANOUT_TRIP_FILE="${TURN_CONTROL_FANOUT_TRIP_FILE:-}"
  local -n record_files="$2"
  turn_fanout_trip_active "$trip_file" || return 1

  for record_file in "${record_files[@]}"; do
    [[ -n "$record_file" ]] || continue
    record="$(_turn_control_load "$record_file")" || return 1
    _turn_control_project_fields "$record" \
      '[.state, (.winner // "-")]' state winner || return 1
    [[ "$winner" == "-" ]] && winner=""
    [[ "$state" == "running" && -z "$winner" ]] || continue

    TURN_CONTROL_FILE="$record_file"
    TURN_CONTROL_FANOUT_TRIP_FILE="$trip_file"
    synced=false
    for attempt in 1 2; do
      if turn_control_sync_fanout_trip; then
        synced=true
        break
      fi
      sleep "$TURN_CONTROL_POLL_SECONDS"
    done
    if [[ "$synced" != "true" ]]; then
      return 1
    fi
  done
}

_turn_control_route_review_records() {
  local issue="$1" trigger_id="$2"
  # shellcheck disable=SC2034 # results is an output nameref consumed by the caller.
  local -n record_files="$3" accounting_ids="$4" logs="$5" results="$6"
  local index record winner unknown_reason trigger_file=""
  local invocation recovery_reason recovery_records='[]'
  for index in "${!record_files[@]}"; do
    record="$(_turn_control_load "${record_files[$index]:-}")" || return 1
    _turn_control_project_fields "$record" \
      '[.invocation_id, (.winner // "-")]' invocation winner || return 1
    [[ "${accounting_ids[$index]:-}" == "$invocation" ]] || return 1
    case "$winner" in
      turn-cap) recovery_reason="turn-cap" ;;
      fanout-cancel) recovery_reason="fanout-cancelled" ;;
      *) recovery_reason="member-dropped" ;;
    esac
    recovery_records="$(jq -ce \
      --arg invocation "$invocation" \
      --arg reason "$recovery_reason" \
      --arg record_path "${record_files[$index]:-}" \
      '. + [{invocation:$invocation,reason:$reason,record_path:$record_path}]' \
      <<<"$recovery_records")" || return 1
    if [[ "$invocation" == "$trigger_id" ]]; then
      trigger_file="${record_files[$index]:-}"
    fi
  done
  [[ -n "$trigger_file" ]] || return 1
  TURN_CONTROL_FILE="$trigger_file" turn_control_mark_terminating || return 1
  TURN_CONTROL_FILE="$trigger_file" \
    turn_control_recovery_stage "$issue" review-wrapper "$recovery_records" \
    || return 1

  for index in "${!record_files[@]}"; do
    record="$(_turn_control_load "${record_files[$index]:-}")" || return 1
    _turn_control_project_fields "$record" \
      '[(.winner // "-")]' winner || return 1
    [[ "$winner" == "-" ]] && winner=""

    unknown_reason=""
    case "$winner" in
      turn-cap)
        unknown_reason="turn-cap"
        TURN_CONTROL_FILE="${record_files[$index]:-}" \
          turn_control_mark_terminating || return 1
        ;;
      fanout-cancel)
        unknown_reason="fanout-cancelled"
        # A sibling suppressed before controller creation has no watchdog to
        # close its no-process lifecycle. Final routing owns that idempotent
        # completion after all live groups have already converged or been reaped.
        TURN_CONTROL_FILE="${record_files[$index]:-}" \
          turn_control_mark_terminating || return 1
        TURN_CONTROL_FILE="${record_files[$index]:-}" \
          turn_control_mark_terminal_transitioned || return 1
        ;;
    esac
    # shellcheck disable=SC2034 # Write through the caller-provided output nameref.
    if ! results[index]="$(_turn_control_commit_checked \
        "$issue" "${accounting_ids[$index]:-}" \
        "${logs[$index]:-}" "$unknown_reason")"; then
      return 1
    fi
  done

  if ! TURN_CONTROL_FILE="$trigger_file" \
      turn_control_route_terminal "$issue" review-wrapper; then
    : "turn-control-branch: B071"
    return 1
  fi
  if ! terminal_intent_cleanup_transition \
      "$issue" reviewing reviewing pending-dev; then
    : "turn-control-branch: B072"
    return 1
  fi
  if ! turn_control_recovery_complete "$issue" review-wrapper; then
    _turn_limit_error "review turn-cap recovery finalization remains pending"
    return 1
  fi

  # One issue transition covers the selected trigger and any cap that raced
  # before the shared trip became visible. Close every violating lifecycle.
  for index in "${!record_files[@]}"; do
    record="$(_turn_control_load "${record_files[$index]:-}")" || continue
    [[ "$(jq -r '.winner // empty' <<<"$record")" == "turn-cap" ]] || continue
    TURN_CONTROL_FILE="${record_files[$index]:-}" \
      turn_control_mark_terminating >/dev/null 2>&1 || true # Processes have converged; issue routing remains authoritative.
    TURN_CONTROL_FILE="${record_files[$index]:-}" \
      turn_control_mark_terminal_transitioned >/dev/null 2>&1 || true # Issue transition already succeeded; annotation cannot roll it back.
  done
  : "turn-control-branch: B073"
}

turn_control_route_review_fanout() {
  if (( $# != 6 )); then
    _turn_limit_error "turn_control_route_review_fanout expects ISSUE TRIP_FILE RECORDS_ARRAY IDS_ARRAY LOGS_ARRAY RESULTS_ARRAY"
    return 1
  fi
  local issue="$1" trip_file="$2" trip trigger_id
  : "turn-control-branch: B070"
  turn_fanout_trip_active "$trip_file" || return 1
  trip="$(_turn_fanout_trip_load "$trip_file")" || return 1
  _turn_control_project_fields "$trip" '[.invocation_id]' trigger_id || return 1
  _turn_control_route_review_records \
    "$issue" "$trigger_id" "$3" "$4" "$5" "$6"
}

turn_control_route_review_unpublished_cap() {
  if (( $# != 5 )); then
    _turn_limit_error "turn_control_route_review_unpublished_cap expects ISSUE RECORDS_ARRAY IDS_ARRAY LOGS_ARRAY RESULTS_ARRAY"
    return 1
  fi
  local issue="$1" index record winner trigger_id=""
  local -n record_files="$2"
  for index in "${!record_files[@]}"; do
    record="$(_turn_control_load "${record_files[$index]:-}")" || return 1
    _turn_control_project_fields "$record" \
      '[(.winner // "-"), .invocation_id]' winner trigger_id || return 1
    [[ "$winner" == "turn-cap" ]] && break
    trigger_id=""
  done
  [[ -n "$trigger_id" ]] || return 2
  _turn_control_route_review_records \
    "$issue" "$trigger_id" "$2" "$3" "$4" "$5"
}

turn_control_route_review() {
  if (( $# != 6 )); then
    _turn_limit_error "turn_control_route_review expects ISSUE TRIP_FILE RECORDS_ARRAY IDS_ARRAY LOGS_ARRAY RESULTS_ARRAY"
    return 1
  fi
  if turn_fanout_trip_active "$2"; then
    turn_control_route_review_fanout "$@"
  else
    turn_control_route_review_unpublished_cap "$1" "$3" "$4" "$5" "$6"
  fi
}

_turn_control_commit_checked() {
  local issue="$1" invocation_id="$2" log_file="$3" unknown_reason="$4"
  local result
  result="$(token_accounting_commit \
    "$issue" "$invocation_id" "$log_file" 0 "" "$unknown_reason")" || return 1
  turn_accounting_commit_succeeded "$result" || return 1
  printf '%s\n' "$result"
}

_turn_control_commit_review_results() {
  if (( $# != 5 )); then
    _turn_limit_error "_turn_control_commit_review_results expects ISSUE IDS_ARRAY LOGS_ARRAY STATES_ARRAY RESULTS_ARRAY"
    return 1
  fi
  local issue="$1" index unknown_reason
  local -n accounting_ids="$2" logs="$3" states="$4" results="$5"
  for index in "${!accounting_ids[@]}"; do
    unknown_reason=""
    case "${states[$index]:-}" in
      unavailable|timed-out) unknown_reason="member-dropped" ;;
    esac
    if ! results[index]="$(_turn_control_commit_checked \
        "$issue" "${accounting_ids[$index]:-}" \
        "${logs[$index]:-}" "$unknown_reason")"; then
      return 1
    fi
  done
}

# Shared post-fan-out orchestration used by autonomous-review.sh. Return 10
# after terminal cap routing, 11 after a partial-launch refusal is fully
# accounted, 0 when ordinary verdict aggregation may continue, and 1 on any
# durability/control-plane failure.
turn_control_review_post_fanout() {
  if (( $# != 9 )); then
    _turn_limit_error "turn_control_review_post_fanout expects ISSUE TRIP_FILE RECORDS_ARRAY IDS_ARRAY LOGS_ARRAY RESULTS_ARRAY LAUNCH_REFUSED ACCOUNTING_REQUIRED MODE"
    return 1
  fi
  local issue="$1" launch_refused="$7" accounting_required="$8" mode="$9"
  local route_rc=0 index
  local -n record_files="$3" accounting_ids="$4" logs="$5" results="$6"
  [[ "$mode" == "warn" || "$mode" == "hard" ]] || return 1

  if [[ "$mode" == "hard" ]] && turn_fanout_trip_active "$2"; then
    turn_control_sync_review_trip_records "$2" "$3" || return 1
  fi
  turn_control_complete_review_records "$3" "$mode" || return 1
  if [[ "$mode" == "hard" ]]; then
    turn_control_route_review \
      "$issue" "$2" "$3" "$4" "$5" "$6" || route_rc=$?
    case "$route_rc" in
      0) return "$TURN_CONTROL_REVIEW_ROUTED_RC" ;;
      2) ;;
      *) return 1 ;;
    esac
  fi

  if [[ "$launch_refused" == "true" ]]; then
    if [[ "$accounting_required" == "true" ]]; then
      for index in "${!record_files[@]}"; do
        if ! results[index]="$(_turn_control_commit_checked \
            "$issue" "${accounting_ids[$index]:-}" \
            "${logs[$index]:-}" member-dropped)"; then
          return 1
        fi
      done
    fi
    return "$TURN_CONTROL_REVIEW_REFUSED_RC"
  fi
  return 0
}
