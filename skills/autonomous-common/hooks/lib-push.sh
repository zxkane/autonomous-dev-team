#!/bin/bash
# lib-push.sh — pure parsing helpers for git-push hook scripts.
#
# Used by block-push-to-main.sh (Claude PreToolUse hook, Layer 1 trunk
# protection). The emitted Layer 2 git pre-push hook is self-contained.
#
# Parser functions reuse the sibling lib.sh tokenizer when the caller has not
# already sourced it. URL normalization helpers remain self-contained.
#
# This file is sourced, not executed. No `set -e` (caller controls exit
# semantics).

# ---------------------------------------------------------------------------
# parse_push_target_refspec <command>
#
# Given shell command text, echoes every destination ref-name written by each
# executable `git push`, one per line. Returns 0 when all matched pushes were
# parsed, 1 when no executable push was found, and 2 when a possible executable
# push or one of its destinations could not be determined.
#
# Handles:
#   git push                                → <current_branch>
#   git push origin                         → <current_branch>
#   git push origin feat/foo                → feat/foo
#   git push -u origin feat/foo             → feat/foo
#   git push origin feat/foo:bar            → bar
#   git push origin HEAD:refs/heads/main    → refs/heads/main
#   git push origin :main                   → :main (delete; caller decides)
#   git push origin tag v1                  → refs/tags/v1
#   git push --all origin                   → __ALL__
#   git push --mirror origin                → __MIRROR__
#   git push --tags origin                  → __TAGS__
#
# Bulk markers (__ALL__, __MIRROR__) are returned uppercase-bracketed so
# callers can branch without ambiguity vs. a real ref named "all".
#
# Prepare one structured token stream for both push parsers. The hook sources
# lib.sh first, so its bounded tokenizer is available and large commands are
# scanned only once. If a copied standalone lib-push.sh cannot find lib.sh, its
# minimal split is marked malformed so target parsing fails closed rather than
# treating the first physical line as authoritative.
_push_prepare_command_tokens() {
  local command="$1"
  local token library_dir

  if [[ "${_PUSH_PREPARED_COMMAND+x}" == "x" &&
    "$_PUSH_PREPARED_COMMAND" == "$command" ]]; then
    return 0
  fi

  _PUSH_TOKEN_TYPES=()
  _PUSH_TOKEN_VALUES=()
  _PUSH_TOKEN_QUOTES=()
  _PUSH_TOKEN_ANSI=()
  _PUSH_TOKEN_UNSAFE=()
  _PUSH_TOKEN_MALFORMED=0
  _PUSH_ENCLOSING_PIPELINE_CACHE_START=-1
  _PUSH_ENCLOSING_PIPELINE_CACHE_END=-1
  _PUSH_ENCLOSING_PIPELINE_CACHE_RESULT=1

  if ! declare -F _resolve_git_command_tokenize >/dev/null 2>&1; then
    library_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    if [[ -r "$library_dir/lib.sh" ]]; then
      # shellcheck source=lib.sh
      source "$library_dir/lib.sh"
    fi
  fi

  if declare -F _resolve_git_command_tokenize >/dev/null 2>&1; then
    _resolve_git_command_tokenize "$command" 1
    _PUSH_TOKEN_TYPES=("${_RGCC_TOKEN_TYPES[@]}")
    _PUSH_TOKEN_VALUES=("${_RGCC_TOKEN_VALUES[@]}")
    _PUSH_TOKEN_QUOTES=("${_RGCC_TOKEN_QUOTES[@]}")
    _PUSH_TOKEN_ANSI=("${_RGCC_TOKEN_ANSI[@]}")
    _PUSH_TOKEN_UNSAFE=("${_RGCC_TOKEN_UNQUOTED_UNSAFE[@]}")
    _PUSH_TOKEN_MALFORMED="${_RGCC_MALFORMED:-0}"
  else
    read -ra _PUSH_TOKEN_VALUES <<<"$command"
    _PUSH_TOKEN_MALFORMED=1
    for token in "${_PUSH_TOKEN_VALUES[@]}"; do
      _PUSH_TOKEN_TYPES+=("word")
      _PUSH_TOKEN_QUOTES+=("unquoted")
      _PUSH_TOKEN_ANSI+=("0")
      case "$token" in
        *['$`\\']*) _PUSH_TOKEN_UNSAFE+=("1") ;;
        *) _PUSH_TOKEN_UNSAFE+=("0") ;;
      esac
    done
  fi

  _PUSH_PREPARED_COMMAND="$command"
}

_push_token_static_value() {
  local index="$1"
  local value="${_PUSH_TOKEN_VALUES[index]:-}"
  local quote_kind="${_PUSH_TOKEN_QUOTES[index]:-}"

  [[ "${_PUSH_TOKEN_TYPES[index]:-}" == "word" ]] || return 1
  [[ "${_PUSH_TOKEN_ANSI[index]:-0}" == "0" ]] || return 1
  [[ "${_PUSH_TOKEN_UNSAFE[index]:-0}" == "0" ]] || return 1
  [[ "$quote_kind" != "mixed" ]] || return 1
  [[ "$value" != *'$'* && "$value" != *'`'* &&
    "$value" != *$'\n'* && "$value" != *$'\r'* &&
    "$value" != *$'\t'* ]] || return 1
  _PUSH_STATIC_VALUE="$value"
}

_push_token_unquoted_static_value() {
  [[ "${_PUSH_TOKEN_QUOTES[$1]:-}" == "unquoted" ]] || return 1
  _push_token_static_value "$1"
}

_push_token_is_assignment() {
  local index="$1"
  local value="${_PUSH_TOKEN_VALUES[index]:-}"

  [[ "${_PUSH_TOKEN_TYPES[index]:-}" == "word" ]] || return 1
  [[ "${_PUSH_TOKEN_ANSI[index]:-0}" == "0" ]] || return 1
  [[ "${_PUSH_TOKEN_UNSAFE[index]:-0}" == "0" ]] || return 1
  [[ "$value" != *'$'* && "$value" != *'`'* ]] || return 1
  [[ "$value" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]
}

_push_token_raw_unquoted_is() {
  [[ "${_PUSH_TOKEN_TYPES[$1]:-}" == "word" ]] &&
    [[ "${_PUSH_TOKEN_QUOTES[$1]:-}" == "unquoted" ]] &&
    [[ "${_PUSH_TOKEN_VALUES[$1]:-}" == "$2" ]]
}

_push_token_is_redirection() {
  local index="$1"
  local value="${_PUSH_TOKEN_VALUES[index]:-}"
  local exact_re='^([0-9]+|\{[A-Za-z_][A-Za-z0-9_]*\})?(>>|>\||>|<<-|<<<|<<|<>|<|>&|<&|&>>|&>)$'
  local attached_re='^([0-9]+|\{[A-Za-z_][A-Za-z0-9_]*\})?(>>|>\||>|<<-|<<<|<<|<>|<|>&|<&|&>>|&>).+$'

  [[ "${_PUSH_TOKEN_TYPES[index]:-}" == "word" ]] || return 1
  [[ "${_PUSH_TOKEN_QUOTES[index]:-}" == "unquoted" ]] || return 1
  if [[ "$value" =~ $exact_re ]]; then
    _PUSH_REDIRECTION_CONSUMES_NEXT=1
    return 0
  fi
  if [[ "$value" =~ $attached_re ]]; then
    _PUSH_REDIRECTION_CONSUMES_NEXT=0
    return 0
  fi
  return 1
}

_push_token_has_executable_expansion() {
  local value="${_PUSH_TOKEN_VALUES[$1]:-}"
  local without_arithmetic="${value//\$\(\(/}"
  [[ "$without_arithmetic" == *'$('* || "$value" == *'`'* ||
    "$value" == *'<('* || "$value" == *'>('* ]]
}

_push_skip_redirection() {
  local index="$1" end="$2"

  _push_token_is_redirection "$index" || return 1
  _PUSH_AFTER_REDIRECTION=$((index + 1))
  if (( _PUSH_REDIRECTION_CONSUMES_NEXT == 1 )); then
    (( index + 1 < end )) || return 2
    _push_token_is_redirection "$((index + 1))" && return 2
    _push_token_has_executable_expansion "$((index + 1))" && return 2
    _PUSH_AFTER_REDIRECTION=$((index + 2))
  elif _push_token_has_executable_expansion "$index"; then
    return 2
  fi
  return 0
}

_push_shell_command_name_executes_input() {
  case "$1" in
    sh|*/sh|ash|*/ash|bash|*/bash|csh|*/csh|dash|*/dash|fish|*/fish|\
      hush|*/hush|ksh|*/ksh|mksh|*/mksh|posh|*/posh|tcsh|*/tcsh|\
      yash|*/yash|zsh|*/zsh|\
      eval|source|'.'|python|python[0-9]*|*/python|*/python[0-9]*|\
      node|*/node|ruby|*/ruby|perl|*/perl)
      return 0
      ;;
  esac
  return 1
}

_push_shell_command_name_is_data_only() {
  case "$1" in
    ':'|'['|'[['|cat|comm|cut|diff|echo|false|fmt|fold|gh|grep|egrep|fgrep|\
      head|jq|nl|paste|printf|read|sed|sort|tail|tee|test|tr|true|uniq|wc)
      return 0
      ;;
  esac
  return 1
}

_push_static_command_text_executes_input() {
  local command="$1"
  local n
  local _PUSH_PREPARED_COMMAND=""
  local _PUSH_TOKEN_MALFORMED=0
  local -a _PUSH_TOKEN_TYPES=()
  local -a _PUSH_TOKEN_VALUES=()
  local -a _PUSH_TOKEN_QUOTES=()
  local -a _PUSH_TOKEN_ANSI=()
  local -a _PUSH_TOKEN_UNSAFE=()

  _push_prepare_command_tokens "$command"
  n=${#_PUSH_TOKEN_VALUES[@]}
  (( n > 0 )) || return 1
  _push_command_executes_standard_input 0 "$n"
}

_push_env_split_command_text() {
  local split_text="$1" start="$2" end="$3"
  local i quoted

  _PUSH_ENV_SPLIT_COMMAND="$split_text"
  for ((i = start; i < end; i++)); do
    _push_token_static_value "$i" || return 1
    printf -v quoted '%q' "$_PUSH_STATIC_VALUE"
    _PUSH_ENV_SPLIT_COMMAND+=" $quoted"
  done
}

_push_env_split_option_command() {
  local index="$1" end="$2"
  local option="${_PUSH_TOKEN_VALUES[index]:-}"
  local body prefix split_text start

  [[ "${_PUSH_TOKEN_TYPES[index]:-}" == "word" &&
    "${_PUSH_TOKEN_ANSI[index]:-0}" == "0" &&
    "${_PUSH_TOKEN_UNSAFE[index]:-0}" == "0" &&
    "$option" != *'$'* && "$option" != *'`'* ]] || return 2

  start=$((index + 1))
  case "$option" in
    --split-string=*)
      split_text="${option#*=}"
      ;;
    -S|--split-string)
      (( start < end )) || return 2
      _push_token_static_value "$start" || return 2
      split_text="$_PUSH_STATIC_VALUE"
      ((start++))
      ;;
    -?*)
      [[ "$option" != --* ]] || return 1
      body="${option#-}"
      [[ "$body" == *S* ]] || return 1
      prefix="${body%%S*}"
      [[ "$prefix" != *[!i0v]* ]] || return 1
      split_text="${body#*S}"
      if [[ -z "$split_text" ]]; then
        (( start < end )) || return 2
        _push_token_static_value "$start" || return 2
        split_text="$_PUSH_STATIC_VALUE"
        ((start++))
      fi
      ;;
    *)
      return 1
      ;;
  esac

  _push_env_split_command_text "$split_text" "$start" "$end" || return 2
}

_push_static_command_text_contains_push() {
  if declare -F _shell_static_code_contains_git_operation >/dev/null 2>&1; then
    _shell_static_code_contains_git_operation "push" "$1"
    return
  fi
  _conservative_shell_text_contains_git_operation "push" "$1"
}

_push_simple_command_executes_standard_input() {
  local j="$1" end="$2"
  local value command_name option rc candidate

  while (( j < end )); do
    if _push_skip_redirection "$j" "$end"; then
      j="$_PUSH_AFTER_REDIRECTION"
      continue
    else
      rc=$?
      (( rc != 2 )) || return 0
    fi
    if _push_token_is_assignment "$j"; then
      ((j++))
      continue
    fi
    _push_token_static_value "$j" || return 0
    value="$_PUSH_STATIC_VALUE"
    command_name="${value##*/}"
    case "$command_name" in
      '!'|if|then|elif|else|do|while|until|'{')
        ((j++))
        ;;
      command)
        ((j++))
        while (( j < end )); do
          _push_token_static_value "$j" || return 0
          case "$_PUSH_STATIC_VALUE" in
            -p|--) ((j++)) ;;
            -v|-V) return 1 ;;
            *) break ;;
          esac
        done
        ;;
      exec)
        ((j++))
        while (( j < end )); do
          _push_token_static_value "$j" || return 0
          case "$_PUSH_STATIC_VALUE" in
            -a)
              (( j + 1 < end )) || return 0
              j=$((j + 2))
              ;;
            -c|-l|--) ((j++)) ;;
            *) break ;;
          esac
        done
        ;;
      nohup|time)
        ((j++))
        while (( j < end )); do
          _push_token_static_value "$j" || return 0
          option="$_PUSH_STATIC_VALUE"
          [[ "$option" == -* ]] || break
          case "$option" in
            -o|--output|-f|--format)
              (( j + 1 < end )) || return 0
              j=$((j + 2))
              ;;
            *) ((j++)) ;;
          esac
        done
        ;;
      timeout)
        ((j++))
        while (( j < end )); do
          _push_token_static_value "$j" || return 0
          option="$_PUSH_STATIC_VALUE"
          [[ "$option" == -* ]] || break
          case "$option" in
            -k|-s|--kill-after|--signal)
              (( j + 1 < end )) || return 0
              j=$((j + 2))
              ;;
            *) ((j++)) ;;
          esac
        done
        (( j < end )) || return 0
        ((j++))
        ;;
      stdbuf)
        ((j++))
        while (( j < end )); do
          _push_token_static_value "$j" || return 0
          option="$_PUSH_STATIC_VALUE"
          case "$option" in
            -i|-o|-e|--input|--output|--error)
              (( j + 1 < end )) || return 0
              j=$((j + 2))
              ;;
            -i*|-o*|-e*|--input=*|--output=*|--error=*|--) ((j++)) ;;
            *) break ;;
          esac
        done
        ;;
      env)
        ((j++))
        while (( j < end )); do
          if _push_token_is_assignment "$j"; then
            ((j++))
            continue
          fi
          if _push_env_split_option_command "$j" "$end"; then
            _push_static_command_text_executes_input "$_PUSH_ENV_SPLIT_COMMAND"
            return
          else
            rc=$?
            (( rc != 2 )) || return 0
          fi
          _push_token_static_value "$j" || return 0
          option="$_PUSH_STATIC_VALUE"
          case "$option" in
            -u|-C|-a|-f|--unset|--chdir|--argv0|--file)
              (( j + 1 < end )) || return 0
              j=$((j + 2))
              ;;
            -u?*|-C?*|-a?*|-f?*|--unset=*|--chdir=*|--argv0=*|--file=*|\
              -i|--ignore-environment|\
              -0|--null|-v|--debug|--)
              ((j++))
              ;;
            *) break ;;
          esac
        done
        ;;
      sudo)
        ((j++))
        while (( j < end )); do
          _push_token_static_value "$j" || return 0
          option="$_PUSH_STATIC_VALUE"
          case "$option" in
            -u|-g|-h|-p|-C|-T|-r|-t|--user|--group|--host|--prompt|\
              --chdir|--command-timeout|--role|--type)
              (( j + 1 < end )) || return 0
              j=$((j + 2))
              ;;
            --*=*|-u*|-g*|-h*|-p*|-C*|-T*|-r*|-t*|--) ((j++)) ;;
            -*) ((j++)) ;;
            *) break ;;
          esac
        done
        ;;
      ssh)
        ((j++))
        while (( j < end )); do
          _push_token_static_value "$j" || return 0
          option="$_PUSH_STATIC_VALUE"
          [[ "$option" == -* ]] || break
          case "$option" in
            -B|-b|-c|-D|-E|-e|-F|-I|-i|-J|-L|-l|-m|-O|-o|-p|-Q|-R|-S|-W|-w)
              (( j + 1 < end )) || return 0
              j=$((j + 2))
              ;;
            -*) ((j++)) ;;
          esac
        done
        (( j < end )) || return 0
        ((j++))
        (( j < end )) || return 0
        if (( j + 1 == end )) &&
          _push_token_static_value "$j" &&
          [[ "$_PUSH_STATIC_VALUE" == *[[:space:]]* ]]; then
          _push_static_command_text_executes_input "$_PUSH_STATIC_VALUE"
          return
        fi
        _push_command_executes_standard_input "$j" "$end"
        return
        ;;
      xargs)
        ((j++))
        while (( j < end )); do
          _push_token_static_value "$j" || return 0
          option="$_PUSH_STATIC_VALUE"
          [[ "$option" == -* ]] || break
          case "$option" in
            -a|-E|-I|-L|-n|-P|-s|-d|--arg-file|--eof|--replace|\
              --max-lines|--max-args|--max-procs|--max-chars|--delimiter|\
              --process-slot-var)
              (( j + 1 < end )) || return 0
              j=$((j + 2))
              ;;
            -a*|-E*|-I*|-L*|-n*|-P*|-s*|-d*|--*=*|--) ((j++)) ;;
            -*) ((j++)) ;;
          esac
        done
        (( j < end )) || return 1
        local _PUSH_XARGS_APPENDS_ARGS=1
        _push_command_executes_standard_input "$j" "$end"
        return
        ;;
      awk|gawk|mawk|nawk)
        for ((j = j + 1; j < end; j++)); do
          if _push_token_static_value "$j"; then
            value="$_PUSH_STATIC_VALUE"
          elif [[ "${_PUSH_TOKEN_QUOTES[j]:-}" == "single" &&
            "${_PUSH_TOKEN_ANSI[j]:-0}" == "0" ]]; then
            value="${_PUSH_TOKEN_VALUES[j]:-}"
          else
            return 0
          fi
          [[ "$value" =~ system[[:space:]]*\( ]] && return 0
        done
        return 1
        ;;
      *)
        _push_shell_command_name_executes_input "$command_name" && return 0
        _push_shell_command_name_is_data_only "$command_name" && return 1
        for ((j = j + 1; j < end; j++)); do
          _push_token_static_value "$j" || return 0
          candidate="${_PUSH_STATIC_VALUE##*/}"
          _push_shell_command_name_executes_input "$candidate" && return 0
        done
        return 1
        ;;
    esac
  done
  [[ "${_PUSH_XARGS_APPENDS_ARGS:-0}" == "1" ]] && return 0
  return 1
}

_push_command_executes_standard_input() {
  local start="$1" end="$2"
  local i="$start" simple_end value
  local command_position=1
  local loop_header=0
  local case_depth=0
  local case_pattern=0

  while (( i < end )); do
    if [[ "${_PUSH_TOKEN_TYPES[i]:-}" == "operator" ]]; then
      value="${_PUSH_TOKEN_VALUES[i]:-}"
      if (( case_pattern == 1 )); then
        if [[ "$value" == ")" ]]; then
          case_pattern=0
          command_position=1
        fi
        ((i++))
        continue
      fi
      case "$value" in
        '('|'&&'|'||'|'|'|'|&'|'&')
          command_position=1
          ;;
        ')')
          command_position=0
          ;;
        ';')
          if (( case_depth > 0 && i + 1 < end )) &&
            [[ "${_PUSH_TOKEN_TYPES[i+1]:-}" == "operator" &&
              "${_PUSH_TOKEN_VALUES[i+1]:-}" == ";" ]]; then
            case_pattern=1
            command_position=0
            i=$((i + 2))
            continue
          fi
          command_position=1
          ;;
      esac
      ((i++))
      continue
    fi

    if (( case_pattern == 1 )); then
      if _push_token_static_value "$i" &&
        [[ "$_PUSH_STATIC_VALUE" == "esac" ]]; then
        (( case_depth > 0 )) && ((case_depth--))
        case_pattern=0
      fi
      command_position=0
      ((i++))
      continue
    fi

    if (( loop_header == 1 )); then
      if _push_token_static_value "$i" &&
        [[ "$_PUSH_STATIC_VALUE" == "do" ]]; then
        loop_header=0
        command_position=1
      fi
      ((i++))
      continue
    fi

    (( command_position == 1 )) || {
      ((i++))
      continue
    }
    if _push_token_raw_unquoted_is "$i" "{"; then
      command_position=1
      ((i++))
      continue
    fi
    if _push_token_raw_unquoted_is "$i" "}"; then
      command_position=0
      ((i++))
      continue
    fi
    _push_token_static_value "$i" || return 0
    value="$_PUSH_STATIC_VALUE"
    case "$value" in
      for|select)
        loop_header=1
        command_position=0
        ((i++))
        ;;
      case)
        ((case_depth++))
        case_pattern=1
        command_position=0
        ((i++))
        ;;
      '!'|if|then|elif|else|do|while|until)
        command_position=1
        ((i++))
        ;;
      fi|done|'esac')
        if (( case_depth > 0 )) && [[ "$value" == "esac" ]]; then
          ((case_depth--))
        fi
        command_position=0
        ((i++))
        ;;
      *)
        simple_end=$((i + 1))
        while (( simple_end < end )) &&
          [[ "${_PUSH_TOKEN_TYPES[simple_end]:-}" != "operator" ]]; do
          ((simple_end++))
        done
        _push_simple_command_executes_standard_input \
          "$i" "$simple_end" && return 0
        i="$simple_end"
        command_position=0
        ;;
    esac
  done
  return 1
}

_push_process_substitution_executes_input() {
  local opener_index="$1"
  local paren_index=$((opener_index + 1))
  local body_start=$((opener_index + 2))
  local i depth=1 n=${#_PUSH_TOKEN_VALUES[@]}
  local start end next_pipe

  [[ "${_PUSH_TOKEN_TYPES[opener_index]:-}" == "word" &&
    "${_PUSH_TOKEN_VALUES[opener_index]:-}" == ">" ]] || return 1
  [[ "${_PUSH_TOKEN_TYPES[paren_index]:-}" == "operator" &&
    "${_PUSH_TOKEN_VALUES[paren_index]:-}" == "(" ]] || return 1

  for ((i = body_start; i < n; i++)); do
    [[ "${_PUSH_TOKEN_TYPES[i]:-}" == "operator" ]] || continue
    case "${_PUSH_TOKEN_VALUES[i]:-}" in
      '(') ((depth++)) ;;
      ')')
        ((depth--))
        if (( depth == 0 )); then
          (( body_start < i )) || return 0
          _push_pipeline_stage_bounds "$((body_start - 1))" "$i"
          start="$_PUSH_PIPELINE_STAGE_START"
          end="$_PUSH_PIPELINE_STAGE_END"
          next_pipe="$_PUSH_PIPELINE_NEXT_PIPE"
          (( start < end )) || return 0
          _push_command_executes_standard_input "$start" "$end" && return 0
          if (( next_pipe >= 0 )); then
            _push_pipeline_consumer_executes_input "$next_pipe" "$i"
            return
          fi
          return 1
        fi
        ;;
    esac
  done
  return 0
}

_push_pipeline_has_executing_process_substitution() {
  local pipe_index="$1"
  local n="${2:-${#_PUSH_TOKEN_VALUES[@]}}"
  local i

  for ((i = pipe_index + 1; i + 1 < n; i++)); do
    if _push_process_substitution_executes_input "$i"; then
      return 0
    fi
    if [[ "${_PUSH_TOKEN_TYPES[i]:-}" == "operator" ]]; then
      case "${_PUSH_TOKEN_VALUES[i]:-}" in
        '|'|'|&'|'&&'|'||'|';'|'&') return 1 ;;
      esac
    fi
  done
  return 1
}

_push_pipeline_stage_bounds() {
  local pipe_index="$1"
  local n="${2:-${#_PUSH_TOKEN_VALUES[@]}}"
  local start=$((pipe_index + 1))
  local i
  local value top_end top_index
  local paren_depth=0
  local command_position=1
  local -a compound_ends=()

  _PUSH_PIPELINE_STAGE_START="$start"
  _PUSH_PIPELINE_STAGE_END="$n"
  _PUSH_PIPELINE_NEXT_PIPE=-1

  for ((i = start; i < n; i++)); do
    if [[ "${_PUSH_TOKEN_TYPES[i]:-}" == "operator" ]]; then
      value="${_PUSH_TOKEN_VALUES[i]:-}"
      case "$value" in
        '(')
          ((paren_depth++))
          command_position=1
          continue
          ;;
        ')')
          if (( paren_depth > 0 )); then
            ((paren_depth--))
            continue
          fi
          if (( ${#compound_ends[@]} == 0 )); then
            _PUSH_PIPELINE_STAGE_END="$i"
            return 0
          fi
          ;;
      esac
      (( paren_depth == 0 )) || continue
      if (( ${#compound_ends[@]} == 0 )); then
        case "$value" in
          '|'|'|&')
            _PUSH_PIPELINE_STAGE_END="$i"
            _PUSH_PIPELINE_NEXT_PIPE="$i"
            return 0
            ;;
          '&&'|'||'|';'|'&')
            _PUSH_PIPELINE_STAGE_END="$i"
            return 0
            ;;
        esac
      fi
      command_position=1
      continue
    fi

    (( paren_depth == 0 && command_position == 1 )) || {
      command_position=0
      continue
    }
    if _push_token_raw_unquoted_is "$i" "{"; then
      compound_ends+=("}")
      command_position=1
      continue
    fi
    if _push_token_raw_unquoted_is "$i" "}"; then
      if (( ${#compound_ends[@]} > 0 )); then
        top_index=$((${#compound_ends[@]} - 1))
        top_end="${compound_ends[top_index]}"
        if [[ "$top_end" == "}" ]]; then
          unset 'compound_ends[top_index]'
        fi
      fi
      command_position=0
      continue
    fi
    if _push_token_static_value "$i"; then
      value="$_PUSH_STATIC_VALUE"
      if (( ${#compound_ends[@]} > 0 )); then
        top_index=$((${#compound_ends[@]} - 1))
        top_end="${compound_ends[top_index]}"
        if [[ "$value" == "$top_end" ]]; then
          unset 'compound_ends[top_index]'
          command_position=0
          continue
        fi
      fi
      case "$value" in
        while|until|for|select) compound_ends+=("done") ;;
        if) compound_ends+=("fi") ;;
        case) compound_ends+=("esac") ;;
      esac
    fi
    command_position=0
  done
}

_push_pipeline_consumer_executes_input() {
  local pipe_index="$1"
  local limit="${2:-${#_PUSH_TOKEN_VALUES[@]}}"
  local start end next_pipe

  _PUSH_PIPELINE_SCAN_END="$limit"
  while (( pipe_index >= 0 )); do
    _push_pipeline_stage_bounds "$pipe_index" "$limit"
    start="$_PUSH_PIPELINE_STAGE_START"
    end="$_PUSH_PIPELINE_STAGE_END"
    next_pipe="$_PUSH_PIPELINE_NEXT_PIPE"

    _push_pipeline_has_executing_process_substitution \
      "$pipe_index" "$limit" && return 0
    (( start < end )) || return 0
    _push_command_executes_standard_input "$start" "$end" && return 0
    if (( next_pipe < 0 )); then
      _PUSH_PIPELINE_SCAN_END="$end"
    fi
    pipe_index="$next_pipe"
  done
  return 1
}

_push_enclosing_pipeline_consumer_executes_input() {
  local segment_start="$1"
  local n="${#_PUSH_TOKEN_VALUES[@]}"
  local boundary=-1 start end next_pipe
  local cached_start="${_PUSH_ENCLOSING_PIPELINE_CACHE_START:--1}"
  local cached_end="${_PUSH_ENCLOSING_PIPELINE_CACHE_END:--1}"
  local cached_result="${_PUSH_ENCLOSING_PIPELINE_CACHE_RESULT:-1}"

  if (( cached_start >= 0 &&
    segment_start >= cached_start && segment_start < cached_end )); then
    return "$cached_result"
  fi

  while (( boundary < n )); do
    _push_pipeline_stage_bounds "$boundary" "$n"
    start="$_PUSH_PIPELINE_STAGE_START"
    end="$_PUSH_PIPELINE_STAGE_END"
    next_pipe="$_PUSH_PIPELINE_NEXT_PIPE"
    if (( segment_start >= start && segment_start < end )); then
      _PUSH_ENCLOSING_PIPELINE_CACHE_START="$start"
      _PUSH_ENCLOSING_PIPELINE_CACHE_END="$end"
      _PUSH_ENCLOSING_PIPELINE_CACHE_RESULT=1
      if (( next_pipe >= 0 )) &&
        _push_pipeline_consumer_executes_input "$next_pipe" "$n"; then
        _PUSH_ENCLOSING_PIPELINE_CACHE_RESULT=0
      fi
      return "$_PUSH_ENCLOSING_PIPELINE_CACHE_RESULT"
    fi
    (( end > boundary )) || return 1
    boundary="$end"
  done
  return 1
}

_push_next_token_is_definite_other_operation() {
  local index="$1" end="$2"
  local i candidate rc

  (( index < end )) || return 1
  for ((i = index; i < end; i++)); do
    _push_token_static_value "$i" || continue
    [[ "$_PUSH_STATIC_VALUE" == "push" ]] && return 1
  done

  i="$index"
  while (( i < end )); do
    if _push_skip_redirection "$i" "$end"; then
      i="$_PUSH_AFTER_REDIRECTION"
      continue
    else
      rc=$?
      (( rc != 2 )) || return 1
    fi
    _push_token_static_value "$i" || return 1
    candidate="$_PUSH_STATIC_VALUE"
    case "$candidate" in
      -c|-C|--git-dir|--work-tree|--namespace|--super-prefix)
        (( i + 1 < end )) || return 1
        i=$((i + 2))
        ;;
      --*=*|--*|-*) ((i++)) ;;
      *) break ;;
    esac
  done
  (( i < end )) || return 1
  [[ -n "$candidate" && "$candidate" != "push" ]] || return 1
  return 0
}

_push_data_segment_is_safe() {
  local start="$1" end="$2" terminator="${3:-}"
  local i rc value

  _PUSH_DATA_SEGMENT_DYNAMIC_INPUT=0
  case "$terminator" in
    '|'|'|&')
      if _push_pipeline_consumer_executes_input "$end"; then
        _PUSH_DATA_SEGMENT_DYNAMIC_INPUT=1
        return 1
      fi
      ;;
    '(')
      if (( end > start + 1 )) &&
        _push_process_substitution_executes_input "$((end - 1))"; then
        _PUSH_DATA_SEGMENT_DYNAMIC_INPUT=1
        return 1
      fi
      ;;
    *)
      if _push_enclosing_pipeline_consumer_executes_input "$start"; then
        _PUSH_DATA_SEGMENT_DYNAMIC_INPUT=1
        return 1
      fi
      ;;
  esac

  for ((i = start + 1; i < end; i++)); do
    if _push_skip_redirection "$i" "$end"; then
      i=$((_PUSH_AFTER_REDIRECTION - 1))
      continue
    else
      rc=$?
      (( rc != 2 )) || return 1
    fi
    value="${_PUSH_TOKEN_VALUES[i]:-}"
    if _push_token_has_executable_expansion "$i"; then
      return 1
    fi
    [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || return 1
  done
  return 0
}

_push_data_segment_contains_possible_push() {
  local start="$1" end="$2"
  local i text=""

  for ((i = start + 1; i < end; i++)); do
    text+="${text:+ }${_PUSH_TOKEN_VALUES[i]:-}"
  done
  [[ -n "$text" ]] || return 1
  [[ "${_PUSH_DATA_SEGMENT_DYNAMIC_INPUT:-0}" == "1" ]] || return 1
  if [[ "$text" == *'$'* || "$text" == *'`'* ]]; then
    return 0
  fi
  if declare -F _conservative_shell_text_contains_git_operation \
    >/dev/null 2>&1; then
    _conservative_shell_text_contains_git_operation "push" "$text"
    return
  fi
  text="${text//[\(\)\{\}\[\]]/ }"
  local -a words
  read -ra words <<<"$text"
  for ((i = 0; i + 1 < ${#words[@]}; i++)); do
    if [[ "${words[i]}" == "git" && "${words[i+1]}" == "push" ]]; then
      return 0
    fi
  done
  return 1
}

_push_shell_text_may_contain_executable_push_data() {
  local command="$1"
  local i n pipeline_scanned_until=-1

  _PUSH_EXECUTABLE_DATA_HAS_EXPANSION=0
  _PUSH_EXECUTABLE_DATA_HAS_PIPELINE=0
  _push_prepare_command_tokens "$command"
  n=${#_PUSH_TOKEN_VALUES[@]}
  for ((i = 0; i < n; i++)); do
    if [[ "${_PUSH_TOKEN_TYPES[i]:-}" == "operator" ]]; then
      case "${_PUSH_TOKEN_VALUES[i]:-}" in
        '|'|'|&')
          (( i < pipeline_scanned_until )) && continue
          if _push_pipeline_consumer_executes_input "$i"; then
            _PUSH_EXECUTABLE_DATA_HAS_PIPELINE=1
            return 0
          fi
          pipeline_scanned_until="$_PUSH_PIPELINE_SCAN_END"
          ;;
      esac
      continue
    fi
    if _push_token_has_executable_expansion "$i"; then
      _PUSH_EXECUTABLE_DATA_HAS_EXPANSION=1
    fi
  done
  (( _PUSH_EXECUTABLE_DATA_HAS_EXPANSION == 0 )) || return 0
  return 1
}

_push_git_operation_index() {
  local git_index="$1" end="$2"
  local j=$((git_index + 1)) option rc

  _push_token_static_value "$git_index" || return 1
  [[ "$_PUSH_STATIC_VALUE" == "git" ]] || return 1

  while (( j < end )); do
    if _push_skip_redirection "$j" "$end"; then
      j="$_PUSH_AFTER_REDIRECTION"
      continue
    else
      rc=$?
      (( rc != 2 )) || return 2
    fi
    if ! _push_token_static_value "$j"; then
      if [[ "${_PUSH_TOKEN_VALUES[j]:-}" == "push" ]]; then
        return 2
      fi
      if _push_next_token_is_definite_other_operation "$((j + 1))" "$end"; then
        return 1
      fi
      return 2
    fi
    option="$_PUSH_STATIC_VALUE"
    case "$option" in
      -c|-C|--git-dir|--work-tree|--namespace|--super-prefix)
        (( j + 1 < end )) || return 2
        if ! _push_token_static_value "$((j + 1))"; then
          if _push_next_token_is_definite_other_operation \
            "$((j + 2))" "$end"; then
            return 1
          fi
          return 2
        fi
        j=$((j + 2))
        ;;
      --*=*|--*|-*) ((j++)) ;;
      *) break ;;
    esac
  done

  (( j < end )) || return 1
  _push_token_static_value "$j" || return 2
  [[ "$_PUSH_STATIC_VALUE" == "push" ]] || return 1
  _PUSH_OPERATION_INDEX="$j"
}

_push_segment_contains_possible_push() {
  local start="$1" end="$2"
  local i rc value next

  for ((i = start; i < end; i++)); do
    [[ "${_PUSH_TOKEN_TYPES[i]:-}" == "word" ]] || continue
    if _push_git_operation_index "$i" "$end"; then
      return 0
    else
      rc=$?
      (( rc == 2 )) && return 0
    fi
    value="${_PUSH_TOKEN_VALUES[i]}"
    if [[ "${_PUSH_TOKEN_UNSAFE[i]:-0}" == "1" ||
      "$value" == *'$'* || "$value" == *'`'* ]]; then
      next=$((i + 1))
      if (( next < end )) && _push_token_static_value "$next" &&
        [[ "$_PUSH_STATIC_VALUE" == "push" ]]; then
        return 0
      fi
    fi
  done
  return 1
}

# Locate an executable git command in one control-operator-delimited segment.
# Known shell keywords, assignments, and command wrappers are traversed.
# Unknown prefixes that still contain a possible git push are rc=2 (unknown);
# trusted data-only echo/printf segments are rc=1 (no executable push).
_push_segment_git_start() {
  local start="$1" end="$2" terminator="${3:-}"
  local j="$start" value option rc

  while (( j < end )); do
    if _push_token_raw_unquoted_is "$j" "{"; then
      ((j++))
      continue
    fi
    if _push_token_raw_unquoted_is "$j" "}"; then
      return 1
    fi
    if _push_skip_redirection "$j" "$end"; then
      j="$_PUSH_AFTER_REDIRECTION"
      continue
    else
      rc=$?
      (( rc != 2 )) || return 2
    fi
    if _push_token_is_assignment "$j"; then
      ((j++))
      continue
    fi
    if ! _push_token_static_value "$j"; then
      _push_segment_contains_possible_push "$start" "$end" && return 2
      return 1
    fi
    value="$_PUSH_STATIC_VALUE"
    case "$value" in
      '!'|if|then|elif|else|do|while|until|'{')
        ((j++))
        ;;
      git)
        if _push_git_operation_index "$j" "$end"; then
          _PUSH_GIT_INDEX="$j"
          return 0
        else
          return $?
        fi
        ;;
      echo|printf)
        if [[ "$(type -t "$value" 2>/dev/null)" == "builtin" ]]; then
          if _push_data_segment_is_safe "$j" "$end" "$terminator"; then
            return 1
          fi
          _push_data_segment_contains_possible_push "$j" "$end" && return 2
        fi
        _push_segment_contains_possible_push "$start" "$end" && return 2
        return 1
        ;;
      command)
        ((j++))
        while (( j < end )); do
          _push_token_static_value "$j" || return 2
          case "$_PUSH_STATIC_VALUE" in
            -p|--) ((j++)) ;;
            -v|-V) return 1 ;;
            *) break ;;
          esac
        done
        ;;
      exec)
        ((j++))
        while (( j < end )); do
          _push_token_static_value "$j" || return 2
          case "$_PUSH_STATIC_VALUE" in
            -a)
              (( j + 1 < end )) || return 2
              j=$((j + 2))
              ;;
            -c|-l|--) ((j++)) ;;
            *) break ;;
          esac
        done
        ;;
      nohup|time)
        ((j++))
        while (( j < end )); do
          _push_token_static_value "$j" || return 2
          [[ "$_PUSH_STATIC_VALUE" == -* ]] || break
          case "$_PUSH_STATIC_VALUE" in
            -o|--output|-f|--format)
              (( j + 1 < end )) || return 2
              j=$((j + 2))
              ;;
            *) ((j++)) ;;
          esac
        done
        ;;
      timeout)
        ((j++))
        while (( j < end )); do
          _push_token_static_value "$j" || return 2
          option="$_PUSH_STATIC_VALUE"
          [[ "$option" == -* ]] || break
          case "$option" in
            -k|-s|--kill-after|--signal)
              (( j + 1 < end )) || return 2
              j=$((j + 2))
              ;;
            *) ((j++)) ;;
          esac
        done
        (( j < end )) || return 2
        ((j++))
        ;;
      stdbuf)
        ((j++))
        while (( j < end )); do
          _push_token_static_value "$j" || return 2
          option="$_PUSH_STATIC_VALUE"
          case "$option" in
            -i|-o|-e|--input|--output|--error)
              (( j + 1 < end )) || return 2
              j=$((j + 2))
              ;;
            -i*|-o*|-e*|--input=*|--output=*|--error=*|--) ((j++)) ;;
            *) break ;;
          esac
        done
        ;;
      env)
        ((j++))
        while (( j < end )); do
          if _push_token_is_assignment "$j"; then
            ((j++))
            continue
          fi
          if _push_env_split_option_command "$j" "$end"; then
            _push_static_command_text_contains_push \
              "$_PUSH_ENV_SPLIT_COMMAND" && return 2
            return 1
          else
            rc=$?
            (( rc != 2 )) || return 2
          fi
          _push_token_static_value "$j" || return 2
          option="$_PUSH_STATIC_VALUE"
          case "$option" in
            -u|-C|-a|-f|--unset|--chdir|--argv0|--file)
              (( j + 1 < end )) || return 2
              j=$((j + 2))
              ;;
            -u?*|-C?*|-a?*|-f?*|--unset=*|--chdir=*|--argv0=*|--file=*|\
              -i|--ignore-environment|\
              -0|--null|-v|--debug|--)
              ((j++))
              ;;
            *) break ;;
          esac
        done
        ;;
      sudo)
        ((j++))
        while (( j < end )); do
          _push_token_static_value "$j" || return 2
          option="$_PUSH_STATIC_VALUE"
          case "$option" in
            -u|-g|-h|-p|-C|-T|-r|-t|--user|--group|--host|--prompt|\
              --chdir|--command-timeout|--role|--type)
              (( j + 1 < end )) || return 2
              j=$((j + 2))
              ;;
            --*=*|-u*|-g*|-h*|-p*|-C*|-T*|-r*|-t*|--) ((j++)) ;;
            -*) ((j++)) ;;
            *) break ;;
          esac
        done
        ;;
      *)
        _push_segment_contains_possible_push "$start" "$end" && return 2
        return 1
        ;;
    esac
  done
  return 1
}

_push_token_is_single_shell_word() {
  local index="$1"
  if _push_token_static_value "$index"; then
    return 0
  fi
  [[ "${_PUSH_TOKEN_TYPES[index]:-}" == "word" ]] &&
    { [[ "${_PUSH_TOKEN_QUOTES[index]:-}" == "single" ]] ||
      [[ "${_PUSH_TOKEN_QUOTES[index]:-}" == "double" ]]; }
}

parse_push_target_refspec() {
  local command="$1"
  local current_branch tok decoded r src dst terminator
  local segment_start=0 segment_end i j n rc redirect_rc
  local found_remote saw_all saw_mirror saw_tags_flag
  local matched=0 unknown=0
  local -a refspecs
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  _push_prepare_command_tokens "$command"
  n=${#_PUSH_TOKEN_VALUES[@]}

  for ((segment_end = 0; segment_end <= n; segment_end++)); do
    if (( segment_end < n )) &&
      [[ "${_PUSH_TOKEN_TYPES[segment_end]}" != "operator" ]]; then
      continue
    fi
    if (( segment_start < segment_end )); then
      terminator=""
      (( segment_end < n )) &&
        terminator="${_PUSH_TOKEN_VALUES[segment_end]}"
      if _push_segment_git_start \
        "$segment_start" "$segment_end" "$terminator"; then
        rc=0
      else
        rc=$?
      fi
      if (( rc == 2 )); then
        unknown=1
      elif (( rc == 0 )); then
      i="$_PUSH_GIT_INDEX"
      j=$((_PUSH_OPERATION_INDEX + 1))
      matched=1
      found_remote=0
      saw_all=0
      saw_mirror=0
      saw_tags_flag=0
      refspecs=()

      while (( j < segment_end )); do
        if _push_skip_redirection "$j" "$segment_end"; then
          j="$_PUSH_AFTER_REDIRECTION"
          continue
        else
          redirect_rc=$?
          if (( redirect_rc == 2 )); then
            unknown=1
            break
          fi
        fi
        if ! _push_token_static_value "$j"; then
          if (( found_remote == 0 )); then
            found_remote=1
            _push_token_is_single_shell_word "$j" || unknown=1
          else
            unknown=1
          fi
          ((j++))
          continue
        fi
        tok="$_PUSH_STATIC_VALUE"
        case "$tok" in
          --all|--all=*) saw_all=1 ;;
          --mirror|--mirror=*) saw_mirror=1 ;;
          --tags|--tags=*) saw_tags_flag=1 ;;
          --delete|-d) ;;
          --repo|-o|--push-option|--receive-pack|--exec)
            (( j + 1 < segment_end )) || { unknown=1; break; }
            j=$((j + 2))
            continue
            ;;
          -*)
            ;;
          *)
            if (( found_remote == 0 )); then
              found_remote=1
              if ! _push_token_is_single_shell_word "$j"; then
                unknown=1
              fi
              ((j++))
              continue
            fi
            if ! _push_token_static_value "$j"; then
              unknown=1
              ((j++))
              continue
            fi
            decoded="$_PUSH_STATIC_VALUE"
            if [[ "$decoded" == "tag" ]] && (( j + 1 < segment_end )); then
              if _push_token_static_value "$((j + 1))"; then
                refspecs+=("refs/tags/${_PUSH_STATIC_VALUE}")
              else
                unknown=1
              fi
              ((j++))
            else
              refspecs+=("$decoded")
            fi
            ;;
        esac
        ((j++))
      done

      if (( saw_all == 1 )); then
        printf '%s\n' "__ALL__"
      elif (( saw_mirror == 1 )); then
        printf '%s\n' "__MIRROR__"
      elif (( saw_tags_flag == 1 && ${#refspecs[@]} == 0 )); then
        printf '%s\n' "__TAGS__"
      elif (( ${#refspecs[@]} == 0 )); then
        if [[ -n "$current_branch" && "$current_branch" != "HEAD" ]]; then
          printf '%s\n' "$current_branch"
        else
          unknown=1
        fi
      else
        for r in "${refspecs[@]}"; do
          if [[ "$r" == *:* ]]; then
            dst="${r#*:}"
            src="${r%%:*}"
            [[ -z "$src" ]] && printf ':%s\n' "$dst" || printf '%s\n' "$dst"
          else
            printf '%s\n' "$r"
          fi
        done
      fi
      fi
    fi
    segment_start=$((segment_end + 1))
  done

  (( _PUSH_TOKEN_MALFORMED == 0 )) || unknown=1
  (( unknown == 0 )) || return 2
  (( matched == 1 )) || return 1
  return 0
}

# ---------------------------------------------------------------------------
# is_trunk_ref <ref> [<trunk_name>]
#
# Returns 0 if <ref> targets the trunk branch, 1 otherwise. <trunk_name>
# defaults to "main" if omitted; pass an explicit name (e.g. "master") to
# match repos with a different trunk.
#
# Recognized forms (all return 0):
#   main
#   refs/heads/main
#   refs/heads/main^         (rev-spec suffix; rare but valid in push)
#
# A leading `:` (delete-push) is stripped before matching, so
#   :main, :refs/heads/main  also return 0
#
# The bulk markers __ALL__ / __MIRROR__ return 0 (they target trunk among
# others). __TAGS__ returns 1 (tags-only push, doesn't write the trunk
# branch ref).
is_trunk_ref() {
  local ref="$1"
  local trunk="${2:-main}"

  case "$ref" in
    __ALL__|__MIRROR__) return 0 ;;
    __TAGS__) return 1 ;;
  esac

  # Strip leading `:` (delete form).
  ref="${ref#:}"

  # Bare trunk
  [[ "$ref" == "$trunk" ]] && return 0

  # Fully-qualified
  [[ "$ref" == "refs/heads/$trunk" ]] && return 0

  # Allow rev-spec suffix on either form (e.g. main^, refs/heads/main~3)
  [[ "$ref" == "$trunk"[\^~]* ]] && return 0
  [[ "$ref" == "refs/heads/$trunk"[\^~]* ]] && return 0

  return 1
}

# ---------------------------------------------------------------------------
# parse_push_remote_operand <command>
#
# Echoes the effective repository operand of a git-push command — a `--repo`
# value, or the first positional remote name / literal URL that overrides it —
# and returns 0. Echoes nothing and returns 0 when the push has no repository
# operand (bare `git push`, which targets the current branch's configured
# remote — a resolvable destination, not an unknown).
#
# Returns 1 for anything this helper cannot confidently read, so callers can
# treat "1" as UNKNOWN and fail closed:
#   - no `git push` invocation on the line
#   - MORE THAN ONE `git push` on the line (`git push a x && git push b y`) —
#     a single answer cannot describe two destinations, and the trunk-ref
#     parser reads refspecs from the whole line, so answering for only the
#     first push would let the second one through unexamined
#   - a quoted or expansion-bearing operand — repository scoping requires an
#     unquoted static token; uncertainty leaves the trunk check armed
#
# Trunk protection compares push DESTINATIONS ([INV-148]), so it must ask which
# remote the push writes to, not assume `origin`. Flag/value skipping mirrors
# parse_push_target_refspec's walk so both helpers agree on what counts as a
# positional.
parse_push_remote_operand() {
  local command="$1"
  local operand="" decoded option terminator
  local n segment_start=0 segment_end i j rc pushes=0 found=0 redirect_rc
  _push_prepare_command_tokens "$command"
  n=${#_PUSH_TOKEN_VALUES[@]}

  for ((segment_end = 0; segment_end <= n; segment_end++)); do
    if (( segment_end < n )) &&
      [[ "${_PUSH_TOKEN_TYPES[segment_end]}" != "operator" ]]; then
      continue
    fi
    if (( segment_start < segment_end )); then
      terminator=""
      (( segment_end < n )) &&
        terminator="${_PUSH_TOKEN_VALUES[segment_end]}"
      if _push_segment_git_start \
        "$segment_start" "$segment_end" "$terminator"; then
        rc=0
      else
        rc=$?
      fi
      (( rc != 2 )) || return 1
      if (( rc == 0 )); then
      i="$_PUSH_GIT_INDEX"
      j=$((_PUSH_OPERATION_INDEX + 1))
      ((pushes++))
      (( pushes <= 1 )) || return 1
      while (( j < segment_end )); do
        if _push_skip_redirection "$j" "$segment_end"; then
          j="$_PUSH_AFTER_REDIRECTION"
          continue
        else
          redirect_rc=$?
          (( redirect_rc != 2 )) || return 1
        fi
        _push_token_static_value "$j" || return 1
        option="$_PUSH_STATIC_VALUE"
        case "$option" in
          --repo)
            (( j + 1 < segment_end )) || return 1
            _push_token_unquoted_static_value "$((j + 1))" || return 1
            operand="$_PUSH_STATIC_VALUE"
            found=1
            j=$((j + 2))
            continue
            ;;
          --repo=*)
            _push_token_unquoted_static_value "$j" || return 1
            operand="${_PUSH_STATIC_VALUE#*=}"
            found=1
            ((j++))
            continue
            ;;
          -o|--push-option|--receive-pack|--exec)
            (( j + 1 < segment_end )) || return 1
            j=$((j + 2))
            continue
            ;;
          -*) ;;
          *)
            _push_token_unquoted_static_value "$j" || return 1
            decoded="$_PUSH_STATIC_VALUE"
            operand="$decoded"
            found=1
            break
            ;;
        esac
        ((j++))
      done
      fi
    fi
    segment_start=$((segment_end + 1))
  done

  (( pushes == 1 && _PUSH_TOKEN_MALFORMED == 0 )) || return 1

  if (( found == 1 )); then
    printf '%s\n' "$operand"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# canonical_remote_url <url>
#
# Echoes a comparable form of a git remote URL and returns 0; returns 1 (empty
# output) when nothing comparable remains, so a caller can distinguish
# "canonicalized" from "cannot canonicalize" and fail closed.
#
# Normalized away: scheme, userinfo, port, SSH shorthand's `host:path` colon,
# repeated/leading/trailing slashes in the path, a trailing `.git`, and case.
# Host and path are normalized SEPARATELY, so a `@`, `:`, or `//` inside the
# path can never be mistaken for host syntax.
#
# Purpose is EQUALITY of two URLs naming the same repository, not validation.
# `.wiki` is deliberately never stripped, so `<project>.git` and
# `<project>.wiki.git` stay distinct — that is what makes a wiki's push
# destination recognizably different from its parent project's ([INV-148]).
canonical_remote_url() {
  local url="$1"
  [[ -n "$url" ]] || return 1

  # Strip scheme (https://, git://, ssh://, file://, ...).
  url="${url#*://}"

  # Split host segment from path ONCE, then normalize each independently. Doing
  # this by hand (rather than repeated whole-string edits) is what keeps a `@`,
  # `:`, or `//` inside the PATH from being mistaken for host syntax.
  local host_segment="${url%%/*}" path=""
  [[ "$url" == */* ]] && path="${url#*/}"

  # SSH shorthand `git@host:owner/repo` — the `:` separates host from path, so
  # everything after it belongs to the path. A purely numeric tail is a port,
  # not a path, and is handled by the port strip below.
  # Userinfo (`git@`, `user:token@`) FIRST — it may itself contain a `:`, which
  # must not be mistaken for the SSH host:path separator or a port.
  host_segment="${host_segment##*@}"

  # An IPv6 literal's colons live inside brackets and are not this separator.
  if [[ "$host_segment" == *:* && "$host_segment" != *]* ]]; then
    local after_colon="${host_segment#*:}"
    if [[ "$after_colon" != +([0-9]) ]]; then
      # `host:/path` and `host:path` address the same repository — the slash
      # normalization below removes the difference.
      path="${after_colon}/${path}"
      host_segment="${host_segment%%:*}"
    fi
  fi

  # Port (`host:2222`) — host segment only. An IPv6 literal keeps its brackets,
  # so its inner colons are never confused with a port separator.
  if [[ "$host_segment" == *]:+([0-9]) || ( "$host_segment" != *]* && "$host_segment" == *:+([0-9]) ) ]]; then
    host_segment="${host_segment%:*}"
  fi

  # A trailing dot on a hostname is DNS-equivalent (`github.com.` resolves to
  # `github.com`), so it must not make two spellings compare unequal.
  while [[ "$host_segment" == *. ]]; do host_segment="${host_segment%.}"; done

  # Collapse repeated slashes and strip leading/trailing ones: `//a//b/` and
  # `a/b` address the same repository.
  while [[ "$path" == *//* ]]; do path="${path//\/\//\/}"; done
  while [[ "$path" == /* ]]; do path="${path#/}"; done
  while [[ "$path" == */ ]]; do path="${path%/}"; done

  # Resolve `.` / `..` segments — `a/../a/b` and `a/b` name the same repository
  # on the server. Pure string work; no filesystem is consulted. A `..` that
  # would escape the root is dropped rather than retained, so no traversal
  # remains in the comparison key.
  if [[ "$path" == *.* ]]; then
    local -a _segs=() _out=()
    IFS='/' read -ra _segs <<<"$path"
    local _s
    for _s in "${_segs[@]}"; do
      case "$_s" in
        .|"") ;;
        ..) [[ ${#_out[@]} -gt 0 ]] && unset '_out[-1]' ;;
        *) _out+=("$_s") ;;
      esac
    done
    path=""
    for _s in ${_out[@]+"${_out[@]}"}; do path="${path:+$path/}$_s"; done
  fi

  # Lowercase BEFORE stripping `.git` so `.GIT` is removed too. `.wiki` is never
  # touched — that is what keeps a wiki a distinct destination ([INV-148]).
  url="${host_segment,,}${path:+/${path,,}}"
  url="${url%.git}"
  while [[ "$url" == */ ]]; do url="${url%/}"; done

  [[ -n "$url" ]] || return 1
  printf '%s\n' "$url"
}

# ---------------------------------------------------------------------------
# push_destination_url <repo-dir> <remote-operand>
#
# Echoes the canonical push-destination URL for a push issued from <repo-dir>
# with <remote-operand> (a remote name, a literal URL, or empty for bare
# `git push`), and returns 0. Returns 1 (empty output) when the destination
# cannot be determined — callers MUST treat that as "unknown" and fail closed.
#
# Resolution order mirrors git's own:
#   1. an operand that looks like a URL is the destination verbatim
#   2. a named remote resolves via `git remote get-url --push` (which honors
#      `remote.<name>.pushurl`)
#   3. no operand → `branch.<b>.pushRemote`, else `remote.pushDefault`, else
#      `branch.<b>.remote`, else `origin` — git's documented push precedence,
#      which is NOT the same as its fetch precedence
#
# Only read-only `git -C` probes are used; no command text is ever executed.
push_destination_url() {
  local repo_dir="$1" operand="${2:-}"
  local remote_name="" url=""

  [[ -n "$repo_dir" ]] || return 1

  if [[ -n "$operand" ]]; then
    # A literal URL (scheme form, or SSH shorthand `host:path`) is used as-is.
    if [[ "$operand" == *://* || "$operand" == *@*:* ]]; then
      canonical_remote_url "$operand"
      return
    fi
    remote_name="$operand"
  else
    local branch
    branch=$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=""
    if [[ -n "$branch" ]]; then
      remote_name=$(git -C "$repo_dir" config --get "branch.${branch}.pushRemote" 2>/dev/null) || remote_name=""
    fi
    if [[ -z "$remote_name" ]]; then
      remote_name=$(git -C "$repo_dir" config --get remote.pushDefault 2>/dev/null) || remote_name=""
    fi
    if [[ -z "$remote_name" && -n "$branch" ]]; then
      remote_name=$(git -C "$repo_dir" config --get "branch.${branch}.remote" 2>/dev/null) || remote_name=""
    fi
    [[ -n "$remote_name" ]] || remote_name="origin"
  fi

  # A local path configured as a remote is still a distinct destination; it is
  # normalized like any other URL so comparison stays defined.
  url=$(git -C "$repo_dir" remote get-url --push "$remote_name" 2>/dev/null) || return 1
  [[ -n "$url" ]] || return 1

  canonical_remote_url "$url"
}

# ---------------------------------------------------------------------------
# anchor_owns_destination <anchor-dir> <canonical-destination>
#
# Returns 0 when <canonical-destination> matches ANY remote configured in
# <anchor-dir> (fetch or push URL). Returns 1 ONLY when the anchor was read
# successfully and owns no such remote. Returns 2 when the anchor cannot be
# read at all — not a git repo, no remotes, unreadable `.git` (cross-user
# permissions, a `safe.directory` refusal) — which is UNKNOWN, not "not mine".
# Callers MUST treat 2 as unknown and fail closed: a guard whose protected set
# is unknown must protect everything, or an unreadable anchor becomes a blanket
# opt-out ([INV-148]).
#
# The anchor's *bare-push* destination alone is not a safe definition of "this
# project": `remote.pushDefault` or `branch.<b>.pushRemote` in the project
# checkout would silently redefine which trunk is protected and switch the guard
# off. Checking every remote the project knows about means ordinary local config
# cannot shrink the protected set.
anchor_owns_destination() {
  local anchor_dir="$1" destination="$2"
  local name url canon remotes seen=0

  [[ -n "$anchor_dir" && -n "$destination" ]] || return 2

  remotes=$(git -C "$anchor_dir" remote 2>/dev/null) || return 2

  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    for url in \
      "$(git -C "$anchor_dir" remote get-url --push "$name" 2>/dev/null)" \
      "$(git -C "$anchor_dir" remote get-url "$name" 2>/dev/null)"; do
      [[ -n "$url" ]] || continue
      canon=$(canonical_remote_url "$url") || continue
      seen=1
      [[ "$canon" != "$destination" ]] || return 0
    done
  done <<<"$remotes"

  # Zero readable remote URLs means the protected set is undetermined.
  (( seen == 1 )) || return 2
  return 1
}
