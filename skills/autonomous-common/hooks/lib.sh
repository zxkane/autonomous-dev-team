#!/bin/bash
# Shared utility functions for hook scripts
# Note: Does not use 'set -e' as this is a library meant to be sourced

# Read the hook's JSON payload from stdin, bounded by a timeout.
# [Lane-GC PR-1, RC6] A bare `input=$(cat)` spins at ~99% CPU reading from an
# EOF'd non-blocking stdin (the proximate driver of the load-241 incident: four
# such hook processes spinning for >10h under a live lane). Bounded via the
# bash builtin `read -t` (not the external `timeout` binary) so the guard is
# unconditional — no feature-detection, no host without it, no degraded
# fallback that could reintroduce the exact spin this closes. `-d ''` reads
# until NUL/EOF so multi-line JSON payloads come through intact.
# Usage: input=$(read_hook_stdin)
read_hook_stdin() {
  local input
  IFS= read -r -t 5 -d '' input
  printf '%s' "$input"
}

# Resolve the current worktree root from worktrees and subdirectories.
# Workflow state is per worktree; only fall back to the common checkout when
# no worktree toplevel can be resolved.
resolve_project_root() {
  local root
  if root=$(git rev-parse --show-toplevel 2>/dev/null); then
    printf '%s\n' "$root"
  elif root=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then
    printf '%s\n' "${root%/.git}"
  else
    pwd
  fi
}

# Parse JSON input and extract a field
# Usage: parse_json_field "field.path" "$json_input"
# Returns: field value or empty string
# Requires: jq (mandatory - no fallback to avoid security issues)
parse_json_field() {
  local field_path="$1"
  local json_input="$2"

  if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed" >&2
    echo ""
    return 1
  fi

  # Validate field path to prevent injection - only allow alphanumeric, dots, underscores, and brackets
  if [[ ! "$field_path" =~ ^[]a-zA-Z0-9._[\"]+$ ]]; then
    echo "Error: Invalid field path" >&2
    echo ""
    return 1
  fi

  # Use jq's getpath with proper variable binding to prevent injection
  echo "$json_input" | jq -r --arg path "$field_path" 'getpath($path | split(".")) // ""'
}

# Parse a required nonempty JSON string field.
# Usage: parse_json_string_field "field.path" "$json_input"
parse_json_string_field() {
  local field_path="$1"
  local json_input="$2"

  if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed" >&2
    return 1
  fi
  if [[ ! "$field_path" =~ ^[]a-zA-Z0-9._[\"]+$ ]]; then
    echo "Error: Invalid field path" >&2
    return 1
  fi

  echo "$json_input" |
    jq -er --arg path "$field_path" '
      getpath($path | split("."))
      | select((type == "string") and (length > 0))
    ' 2>/dev/null
}

# Parse tool input command from hook JSON
# Usage: parse_command "$json_input"
parse_command() {
  parse_json_field "tool_input.command" "$1"
}

# Parse exit code from tool response
# Usage: parse_exit_code "$json_input"
# Requires: jq
parse_exit_code() {
  local json_input="$1"
  local exit_code

  if ! command -v jq &> /dev/null; then
    echo "1"
    return 1
  fi

  exit_code=$(
    printf '%s' "$json_input" |
      jq -r '
        if (.tool_response | type) == "object" then
          .tool_response.exitCode // .tool_response.exit_code // "1"
        elif (.tool_response | type) == "string" then
          (
            .tool_response
            | capture(
                "(?:^|\\n)Process exited with code (?<code>[0-9]+)(?:\\r?\\n|$)"
              )
            | .code
          ) // "1"
        else
          "1"
        end
      ' 2>/dev/null
  ) || exit_code="1"

  printf '%s\n' "$exit_code"
}

# Parse file path from tool input
# Usage: parse_file_path "$json_input"
parse_file_path() {
  parse_json_field "tool_input.file_path" "$1"
}

# Parse edit operations as tab-separated operation/path records.
#
# Claude Write/Edit calls provide one tool_input.file_path. Codex apply_patch
# calls provide the patch in tool_input.command and may touch multiple paths.
# Recognized edit tools fail when their expected path data is malformed;
# unrelated tools remain a successful no-op.
#
# Operations are: add, edit, delete, move.
parse_edit_file_operations() {
  local json_input="$1"
  local tool_name file_path command input_prefix

  if tool_name=$(parse_json_string_field "tool_name" "$json_input"); then
    input_prefix="tool_input"
  elif tool_name=$(parse_json_string_field "agent_action_name" "$json_input"); then
    input_prefix="tool_info"
  else
    echo "Error: hook payload is missing a string tool discriminator" >&2
    return 1
  fi

  case "$tool_name" in
    Write|write_file|WriteFile|pre_write_code)
      if ! file_path=$(parse_json_string_field "${input_prefix}.file_path" "$json_input"); then
        echo "Error: $tool_name hook payload is missing a string ${input_prefix}.file_path" >&2
        return 1
      fi
      if [[ "$file_path" == *$'\t'* || "$file_path" == *$'\n'* ]]; then
        echo "Error: $tool_name hook path contains an unsupported tab or newline" >&2
        return 1
      fi
      printf 'add\t%s\n' "$file_path"
      ;;
    Edit|replace|StrReplaceFile)
      if ! file_path=$(parse_json_string_field "${input_prefix}.file_path" "$json_input"); then
        echo "Error: $tool_name hook payload is missing a string ${input_prefix}.file_path" >&2
        return 1
      fi
      if [[ "$file_path" == *$'\t'* || "$file_path" == *$'\n'* ]]; then
        echo "Error: $tool_name hook path contains an unsupported tab or newline" >&2
        return 1
      fi
      printf 'edit\t%s\n' "$file_path"
      ;;
    fs_write|write|fsWrite)
      if ! file_path=$(parse_json_string_field "${input_prefix}.path" "$json_input"); then
        echo "Error: $tool_name hook payload is missing a string ${input_prefix}.path" >&2
        return 1
      fi
      if ! command=$(parse_json_string_field "${input_prefix}.command" "$json_input"); then
        echo "Error: $tool_name hook payload is missing a string ${input_prefix}.command" >&2
        return 1
      fi
      if [[ "$file_path" == *$'\t'* || "$file_path" == *$'\n'* ]]; then
        echo "Error: $tool_name hook path contains an unsupported tab or newline" >&2
        return 1
      fi
      case "$command" in
        create) printf 'add\t%s\n' "$file_path" ;;
        str_replace|insert|append) printf 'edit\t%s\n' "$file_path" ;;
        *)
          echo "Error: $tool_name hook payload has unsupported command: $command" >&2
          return 1
          ;;
      esac
      ;;
    apply_patch)
      if ! command=$(parse_json_string_field "${input_prefix}.command" "$json_input"); then
        echo "Error: apply_patch hook payload is missing a string ${input_prefix}.command" >&2
        return 1
      fi

      local line operation candidate
      local begun=0 ended=0 found=0 malformed=0
      declare -A seen=()
      local -a operation_records=()
      while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"

        if (( begun == 0 )); then
          if [[ "$line" == "*** Begin Patch" ]]; then
            begun=1
          else
            malformed=1
          fi
          continue
        fi

        if (( ended == 1 )); then
          [[ -z "$line" ]] || malformed=1
          continue
        fi

        if [[ "$line" == "*** End Patch" ]]; then
          ended=1
          continue
        fi
        if [[ "$line" == "*** Begin Patch" ]]; then
          malformed=1
          continue
        fi

        operation=""
        candidate=""
        case "$line" in
          '*** Add File: '*)
            operation="add"
            candidate="${line#'*** Add File: '}"
            ;;
          '*** Update File: '*)
            operation="edit"
            candidate="${line#'*** Update File: '}"
            ;;
          '*** Delete File: '*)
            operation="delete"
            candidate="${line#'*** Delete File: '}"
            ;;
          '*** Move to: '*)
            operation="move"
            candidate="${line#'*** Move to: '}"
            ;;
        esac

        [[ -z "$operation" ]] && continue
        if [[ -z "$candidate" || "$candidate" == *$'\t'* ]]; then
          malformed=1
          continue
        fi

        local record_key="${operation}"$'\034'"${candidate}"
        if [[ ! ${seen["$record_key"]+present} ]]; then
          seen["$record_key"]=1
          operation_records+=("${operation}"$'\t'"${candidate}")
          found=1
        fi
      done <<< "$command"

      if (( begun == 0 || ended == 0 || found == 0 || malformed == 1 )); then
        echo "Error: apply_patch payload is not a complete supported patch" >&2
        return 1
      fi
      printf '%s\n' "${operation_records[@]}"
      ;;
    *)
      return 0
      ;;
  esac
}

# Parse all paths affected by an edit tool, one path per output line.
# This compatibility projection intentionally drops operation semantics.
parse_edit_file_paths() {
  local json_input="$1"
  local records operation file_path

  records=$(parse_edit_file_operations "$json_input") || return 1

  declare -A seen=()
  while IFS=$'\t' read -r operation file_path; do
    [[ -z "$operation" || -z "$file_path" ]] && continue
    if [[ ! ${seen["$file_path"]+present} ]]; then
      seen["$file_path"]=1
      printf '%s\n' "$file_path"
    fi
  done <<< "$records"
}

# Check if command invokes a given git subcommand.
# Usage: is_git_command "commit" "$command"
#
# Matches when `git <operation>` appears as an actual invocation in the
# command line. Ignores occurrences inside quoted strings or as
# substrings of other tokens (e.g. `push-something`, or `git push`
# inside an issue body). Supports global flags before the subcommand
# (`git -c key=val push`, `git --git-dir=/x push`) and command chains
# (`cd /tmp && git push`).
#
# Limitation: the quote-stripping pass does not fully understand escaped
# quotes (`"see \"git push\" docs"`) — the ERE treats `\"` as a region
# boundary, so a missed strip is possible. This is acceptable because the
# intent is defense-in-depth against incidental mentions, not adversarial
# bypass (any workflow author who wants to dodge the hook can use
# `--no-verify`). The strip MUST still terminate on every input — see the
# quoted-substitution note inside the function (#266).
is_git_command() {
  local operation="$1"
  local command="$2"

  # Strip single- and double-quoted regions so mentions inside quoted
  # strings (e.g. `--body "see git push docs"`) cannot match.
  #
  # The match MUST be quoted inside the substitution — `${var/"$x"/ }`, not
  # `${var/$x/ }`. The first operand of `${var/pattern/repl}` is interpreted as
  # a glob pattern, but BASH_REMATCH[0] is literal matched text. An unquoted
  # match containing a glob-significant char (a backslash from an escaped quote
  # `\"`, or `[`, `?`, `*`) would match nothing, leave `stripped` unchanged, and
  # the `while [[ … =~ … ]]` test would re-match the same region forever — a
  # 100%-CPU infinite loop. Quoting forces a literal substitution. See #266.
  local stripped="$command"
  while [[ "$stripped" =~ \"[^\"]*\" ]]; do
    stripped="${stripped/"${BASH_REMATCH[0]}"/ }"
  done
  while [[ "$stripped" =~ \'[^\']*\' ]]; do
    stripped="${stripped/"${BASH_REMATCH[0]}"/ }"
  done

  # Split on shell separators so each segment can be scanned independently.
  local normalised
  normalised=$(printf '%s' "$stripped" | sed -E 's/(\|\||&&|;|\||&)/\n/g')

  local segment
  while IFS= read -r segment; do
    local -a tokens
    read -ra tokens <<<"$segment"
    local i=0 n=${#tokens[@]}
    # Find the `git` token (as a whole token — not a substring).
    while (( i < n )) && [[ "${tokens[i]}" != "git" ]]; do
      ((i++))
    done
    (( i >= n )) && continue
    ((i++))
    # Skip git global flags before the subcommand. Two-token forms
    # (-c key=val, -C path, --git-dir path) consume two slots;
    # attached forms (--git-dir=path) consume one. Bounds are clamped
    # to n so a stray trailing flag cannot skip past the end.
    while (( i < n )); do
      case "${tokens[i]}" in
        -c|-C|--git-dir|--work-tree|--namespace|--super-prefix)
          i=$(( i + 2 > n ? n : i + 2 ))
          ;;
        --*=*|--*)
          ((i++))
          ;;
        *)
          break
          ;;
      esac
    done
    (( i >= n )) && continue
    if [[ "${tokens[i]}" == "$operation" ]]; then
      return 0
    fi
  done <<<"$normalised"
  return 1
}

# Canonicalize an existing directory without changing the caller's cwd.
_canonical_existing_directory() {
  (
    builtin cd -P -- "$1" 2>/dev/null &&
      builtin pwd -P
  )
}

_resolve_git_append_word() {
  _RGCC_TOKEN_TYPES+=("word")
  _RGCC_TOKEN_VALUES+=("$1")
  _RGCC_TOKEN_QUOTES+=("$2")
  _RGCC_TOKEN_ANSI+=("$3")
}

_resolve_git_append_operator() {
  _RGCC_TOKEN_TYPES+=("operator")
  _RGCC_TOKEN_VALUES+=("$1")
  _RGCC_TOKEN_QUOTES+=("unquoted")
  _RGCC_TOKEN_ANSI+=("0")
}

# Tokenize only enough shell syntax to recognize the bounded grammar used by
# resolve_git_command_cwd. Unsafe expansion syntax is recorded, never expanded.
_resolve_git_command_tokenize() {
  local command="$1"
  local state="unquoted"
  local value=""
  local quote_kind=""
  local ansi_syntax=0
  local ansi_segment_truncated=0
  local started=0
  local character next operator decoded digits digit
  local codepoint max_digits offset
  local backslash=$'\\'
  local i length=${#command}

  _RGCC_TOKEN_TYPES=()
  _RGCC_TOKEN_VALUES=()
  _RGCC_TOKEN_QUOTES=()
  _RGCC_TOKEN_ANSI=()
  _RGCC_UNSAFE=0
  _RGCC_MALFORMED=0

  for ((i = 0; i < length; i++)); do
    character="${command:i:1}"

    case "$state" in
      single)
        if [[ "$character" == "'" ]]; then
          state="unquoted"
        else
          value+="$character"
        fi
        ;;
      ansi)
        if [[ "$character" == "'" ]]; then
          state="unquoted"
          ansi_segment_truncated=0
        elif [[ "$character" == "$backslash" ]]; then
          next=""
          if (( i + 1 < length )); then
            next="${command:i+1:1}"
          fi
          case "$next" in
            x|u|U)
              case "$next" in
                x) max_digits=2 ;;
                u) max_digits=4 ;;
                U) max_digits=8 ;;
              esac
              digits=""
              for ((offset = 2; offset < 2 + max_digits; offset++)); do
                digit=""
                if (( i + offset < length )); then
                  digit="${command:i+offset:1}"
                fi
                [[ "$digit" =~ ^[0-9a-fA-F]$ ]] || break
                digits+="$digit"
              done
              if [[ -n "$digits" ]]; then
                codepoint=$((16#$digits))
                if (( codepoint == 0 )); then
                  ansi_segment_truncated=1
                elif (( codepoint <= 127 && ansi_segment_truncated == 0 )); then
                  printf -v decoded '%b' "\\$next$digits"
                  value+="$decoded"
                elif [[ "$next" == "U" ]] &&
                  (( codepoint >= 2147483648 )); then
                  # Bash discards out-of-range \U escapes.
                  :
                elif (( ansi_segment_truncated == 0 )); then
                  value+="?"
                fi
                i=$((i + 1 + ${#digits}))
              else
                (( ansi_segment_truncated == 1 )) || value+="$backslash$next"
                i=$((i + 1))
              fi
              ;;
            [0-7])
              digits="$next"
              for offset in 2 3; do
                digit=""
                if (( i + offset < length )); then
                  digit="${command:i+offset:1}"
                fi
                [[ "$digit" =~ ^[0-7]$ ]] || break
                digits+="$digit"
              done
              codepoint=$(((8#$digits) & 255))
              if (( codepoint == 0 )); then
                ansi_segment_truncated=1
              elif (( codepoint <= 127 && ansi_segment_truncated == 0 )); then
                printf -v decoded '%b' "\\0$digits"
                value+="$decoded"
              elif (( ansi_segment_truncated == 0 )); then
                value+="?"
              fi
              i=$((i + ${#digits}))
              ;;
            c)
              if (( i + 2 < length )) &&
                [[ "${command:i+2:1}" != "'" ]]; then
                digit="${command:i+2:1}"
                case "$digit" in
                  ' '|@|'`')
                    ansi_segment_truncated=1
                    ;;
                  *)
                    (( ansi_segment_truncated == 1 )) || value+="?"
                    ;;
                esac
                i=$((i + 2))
              else
                (( ansi_segment_truncated == 1 )) || value+="$backslash$next"
                i=$((i + 1))
              fi
              ;;
            \\|"'"|'"')
              (( ansi_segment_truncated == 1 )) || value+="$next"
              i=$((i + 1))
              ;;
            '?')
              (( ansi_segment_truncated == 1 )) || value+="?"
              i=$((i + 1))
              ;;
            a) (( ansi_segment_truncated == 1 )) || value+=$'\a'; i=$((i + 1)) ;;
            b) (( ansi_segment_truncated == 1 )) || value+=$'\b'; i=$((i + 1)) ;;
            e|E) (( ansi_segment_truncated == 1 )) || value+=$'\e'; i=$((i + 1)) ;;
            f) (( ansi_segment_truncated == 1 )) || value+=$'\f'; i=$((i + 1)) ;;
            n) (( ansi_segment_truncated == 1 )) || value+=$'\n'; i=$((i + 1)) ;;
            r) (( ansi_segment_truncated == 1 )) || value+=$'\r'; i=$((i + 1)) ;;
            t) (( ansi_segment_truncated == 1 )) || value+=$'\t'; i=$((i + 1)) ;;
            v) (( ansi_segment_truncated == 1 )) || value+=$'\v'; i=$((i + 1)) ;;
            *)
              (( ansi_segment_truncated == 1 )) || value+="$backslash"
              ;;
          esac
        else
          (( ansi_segment_truncated == 1 )) || value+="$character"
        fi
        ;;
      double)
        if [[ "$character" == '"' ]]; then
          state="unquoted"
        elif [[ "$character" == "$backslash" ]]; then
          next=""
          if (( i + 1 < length )); then
            next="${command:i+1:1}"
          fi
          case "$next" in
            '$'|'`'|'"'|\\)
              value+="$next"
              i=$((i + 1))
              ;;
            $'\n')
              i=$((i + 1))
              ;;
            *)
              value+="$backslash"
              ;;
          esac
        else
          case "$character" in
            '$'|'`') _RGCC_UNSAFE=1 ;;
          esac
          value+="$character"
        fi
        ;;
      unquoted)
        case "$character" in
          ' '|$'\t')
            if (( started == 1 )); then
              _resolve_git_append_word "$value" "${quote_kind:-unquoted}" "$ansi_syntax"
              value=""
              quote_kind=""
              ansi_syntax=0
              started=0
            fi
            ;;
          $'\n'|$'\r')
            _RGCC_UNSAFE=1
            if (( started == 1 )); then
              _resolve_git_append_word "$value" "${quote_kind:-unquoted}" "$ansi_syntax"
              value=""
              quote_kind=""
              ansi_syntax=0
              started=0
            fi
            ;;
          "'")
            if (( started == 1 )); then
              quote_kind="mixed"
            else
              quote_kind="single"
            fi
            started=1
            state="single"
            ;;
          '"')
            if (( started == 1 )); then
              quote_kind="mixed"
            else
              quote_kind="double"
            fi
            started=1
            state="double"
            ;;
          '$')
            next=""
            if (( i + 1 < length )); then
              next="${command:i+1:1}"
            fi
            if [[ "$next" == "'" ]]; then
              if (( started == 1 )); then
                quote_kind="mixed"
              else
                quote_kind="ansi"
              fi
              _RGCC_UNSAFE=1
              ansi_syntax=1
              started=1
              state="ansi"
              i=$((i + 1))
            else
              if (( started == 1 )) &&
                [[ "$quote_kind" != "unquoted" && "$quote_kind" != "" ]]; then
                quote_kind="mixed"
              elif (( started == 0 )); then
                quote_kind="unquoted"
              fi
              _RGCC_UNSAFE=1
              started=1
              value+="$character"
            fi
            ;;
          '&'|'|'|';'|'('|')')
            if (( started == 1 )); then
              _resolve_git_append_word "$value" "${quote_kind:-unquoted}" "$ansi_syntax"
              value=""
              quote_kind=""
              ansi_syntax=0
              started=0
            fi

            operator="$character"
            if [[ "$character" == '&' || "$character" == '|' ]]; then
              next=""
              if (( i + 1 < length )); then
                next="${command:i+1:1}"
              fi
              if [[ "$next" == "$character" ]]; then
                operator+="$next"
                i=$((i + 1))
              fi
            fi
            _resolve_git_append_operator "$operator"
            ;;
          *)
            if (( started == 1 )) &&
              [[ "$quote_kind" != "unquoted" && "$quote_kind" != "" ]]; then
              quote_kind="mixed"
            elif (( started == 0 )); then
              quote_kind="unquoted"
            fi
            case "$character" in
              '`'|\\|'<'|'>'|'{'|'}') _RGCC_UNSAFE=1 ;;
            esac
            started=1
            value+="$character"
            ;;
        esac
        ;;
    esac
  done

  if [[ "$state" != "unquoted" ]]; then
    _RGCC_MALFORMED=1
  fi
  if (( started == 1 )); then
    _resolve_git_append_word "$value" "${quote_kind:-unquoted}" "$ansi_syntax"
  fi
}

_resolve_git_tokens_contain_operation() {
  local operation="$1"
  local i j n=${#_RGCC_TOKEN_VALUES[@]}

  for ((i = 0; i < n; i++)); do
    [[ "${_RGCC_TOKEN_TYPES[i]}" == "word" ]] || continue
    [[ "${_RGCC_TOKEN_VALUES[i]}" == "git" ]] || continue

    j=$((i + 1))
    while (( j < n )) && [[ "${_RGCC_TOKEN_TYPES[j]}" == "word" ]]; do
      case "${_RGCC_TOKEN_VALUES[j]}" in
        -c|-C|--git-dir|--work-tree|--namespace|--super-prefix)
          j=$((j + 2))
          ;;
        -*)
          j=$((j + 1))
          ;;
        *)
          break
          ;;
      esac
    done
    if (( j < n )) &&
      [[ "${_RGCC_TOKEN_TYPES[j]}" == "word" ]] &&
      [[ "${_RGCC_TOKEN_VALUES[j]}" == "$operation" ]]; then
      return 0
    fi
  done
  return 1
}

_resolve_git_static_token_value() {
  local index="$1"
  local value="${_RGCC_TOKEN_VALUES[index]}"
  local match

  while [[ "$value" =~ \$\{[^}]*\} ]]; do
    match="${BASH_REMATCH[0]}"
    value="${value/"$match"/}"
  done
  while [[ "$value" =~ \$[a-zA-Z_][a-zA-Z0-9_]* ]]; do
    match="${BASH_REMATCH[0]}"
    value="${value/"$match"/}"
  done
  value="${value//\\/}"
  printf '%s\n' "$value"
}

# Identify operation words obscured only by rejected expansion/escape syntax.
# This is conservative static analysis; it never expands the input.
_resolve_git_unsafe_tokens_contain_operation() {
  local operation="$1"
  local i j git_word operation_word
  local n=${#_RGCC_TOKEN_VALUES[@]}

  for ((i = 0; i < n; i++)); do
    [[ "${_RGCC_TOKEN_TYPES[i]}" == "word" ]] || continue
    git_word=$(_resolve_git_static_token_value "$i")
    if [[ "$git_word" != "git" ]]; then
      if (( i != 0 )) && [[ "${_RGCC_TOKEN_TYPES[i-1]}" != "operator" ]]; then
        continue
      fi
      if [[ -n "$git_word" || "${_RGCC_TOKEN_ANSI[i]}" == "1" ]]; then
        continue
      fi
    fi

    for ((j = i + 1; j < n; j++)); do
      [[ "${_RGCC_TOKEN_TYPES[j]}" == "word" ]] || continue
      operation_word=$(_resolve_git_static_token_value "$j")
      if [[ "$operation_word" == "$operation" ]] ||
        [[ -z "$operation_word" && "${_RGCC_TOKEN_VALUES[j]}" == *'$'* ]]; then
        return 0
      fi
    done
  done
  return 1
}

_resolve_git_tokens_are_words() {
  local start="$1"
  local i n=${#_RGCC_TOKEN_TYPES[@]}

  for ((i = start; i < n; i++)); do
    [[ "${_RGCC_TOKEN_TYPES[i]}" == "word" ]] || return 1
  done
}

_resolve_git_unquoted_word_is() {
  local index="$1"
  local expected="$2"

  [[ "${_RGCC_TOKEN_TYPES[index]:-}" == "word" ]] &&
    [[ "${_RGCC_TOKEN_QUOTES[index]:-}" == "unquoted" ]] &&
    [[ "${_RGCC_TOKEN_VALUES[index]:-}" == "$expected" ]]
}

_resolve_git_logical_absolute_path() {
  local path="$1"
  local part joined
  local -a parts=()
  local -a stack=()

  [[ "$path" == /* ]] || return 1
  IFS='/' read -r -a parts <<<"${path#/}"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|'.')
        ;;
      '..')
        if (( ${#stack[@]} > 0 )); then
          unset 'stack[${#stack[@]}-1]'
        fi
        ;;
      *)
        stack+=("$part")
        ;;
    esac
  done

  if (( ${#stack[@]} == 0 )); then
    printf '/\n'
  else
    joined=$(IFS='/'; printf '%s' "${stack[*]}")
    printf '/%s\n' "$joined"
  fi
}

_resolve_git_literal_path() {
  local index="$1"
  local base_dir="$2"
  local resolution_mode="$3"
  local value="${_RGCC_TOKEN_VALUES[index]:-}"
  local quote_kind="${_RGCC_TOKEN_QUOTES[index]:-}"
  local candidate

  [[ "${_RGCC_TOKEN_TYPES[index]:-}" == "word" ]] || return 1
  [[ -n "$value" ]] || return 1

  case "$quote_kind" in
    unquoted)
      case "$value" in
        \~)
          [[ -n "${HOME:-}" ]] || return 1
          value="$HOME"
          ;;
        \~/*)
          [[ -n "${HOME:-}" ]] || return 1
          value="${HOME}${value:1}"
          ;;
        \~*)
          return 1
          ;;
      esac
      [[ "$value" != *[\*\?\[\]]* ]] || return 1
      ;;
    single|double)
      ;;
    *)
      return 1
      ;;
  esac

  if [[ "$value" == /* ]]; then
    candidate="$value"
  else
    candidate="$base_dir/$value"
  fi
  if [[ "$resolution_mode" == "logical" ]]; then
    candidate=$(_resolve_git_logical_absolute_path "$candidate") || return 1
  fi
  _canonical_existing_directory "$candidate"
}

# Resolve the effective cwd for one bounded git operation without executing the
# command text. Returns 0 with a canonical cwd, 1 for no match, and 2 when a
# matching invocation is unsupported, ambiguous, or unresolvable.
resolve_git_command_cwd() {
  local operation="$1"
  local command="$2"
  local base_dir="$3"
  local canonical_base resolved
  local separator=-1
  local i n

  [[ "$operation" =~ ^[a-zA-Z0-9_-]+$ ]] || return 2
  _resolve_git_command_tokenize "$command"

  if ! _resolve_git_tokens_contain_operation "$operation"; then
    if (( _RGCC_UNSAFE == 1 )) &&
      _resolve_git_unsafe_tokens_contain_operation "$operation"; then
      return 2
    fi
    if (( _RGCC_MALFORMED == 1 )) && is_git_command "$operation" "$command"; then
      return 2
    fi
    return 1
  fi
  if (( _RGCC_UNSAFE == 1 || _RGCC_MALFORMED == 1 )); then
    return 2
  fi

  canonical_base=$(_canonical_existing_directory "$base_dir") || return 2
  n=${#_RGCC_TOKEN_VALUES[@]}

  if (( n >= 2 )) &&
    _resolve_git_unquoted_word_is 0 "git" &&
    _resolve_git_unquoted_word_is 1 "$operation" &&
    _resolve_git_tokens_are_words 2; then
    printf '%s\n' "$canonical_base"
    return 0
  fi

  if (( n >= 4 )) &&
    _resolve_git_unquoted_word_is 0 "git" &&
    _resolve_git_unquoted_word_is 1 "-C" &&
    _resolve_git_unquoted_word_is 3 "$operation" &&
    _resolve_git_tokens_are_words 4; then
    resolved=$(_resolve_git_literal_path 2 "$canonical_base" "physical") || return 2
    printf '%s\n' "$resolved"
    return 0
  fi

  if (( n < 5 )) ||
    ! _resolve_git_unquoted_word_is 0 "cd" ||
    [[ "${_RGCC_TOKEN_TYPES[1]}" != "word" ]] ||
    [[ "${_RGCC_TOKEN_TYPES[2]}" != "operator" ]] ||
    [[ "${_RGCC_TOKEN_VALUES[2]}" != "&&" ]] ||
    ! _resolve_git_unquoted_word_is 3 "git"; then
    return 2
  fi

  if _resolve_git_unquoted_word_is 4 "$operation" &&
    _resolve_git_tokens_are_words 5; then
    [[ "${_RGCC_TOKEN_VALUES[1]}" != -* ]] || return 2
    resolved=$(_resolve_git_literal_path 1 "$canonical_base" "logical") || return 2
    printf '%s\n' "$resolved"
    return 0
  fi

  _resolve_git_unquoted_word_is 4 "add" || return 2
  for ((i = 5; i < n; i++)); do
    if [[ "${_RGCC_TOKEN_TYPES[i]}" == "operator" ]]; then
      separator="$i"
      break
    fi
  done
  if (( separator < 5 )) ||
    [[ "${_RGCC_TOKEN_VALUES[separator]}" != "&&" ]] ||
    (( separator + 2 >= n )) ||
    ! _resolve_git_unquoted_word_is "$((separator + 1))" "git" ||
    ! _resolve_git_unquoted_word_is "$((separator + 2))" "$operation" ||
    ! _resolve_git_tokens_are_words "$((separator + 3))"; then
    return 2
  fi

  [[ "${_RGCC_TOKEN_VALUES[1]}" != -* ]] || return 2
  resolved=$(_resolve_git_literal_path 1 "$canonical_base" "logical") || return 2
  printf '%s\n' "$resolved"
}

# Get the project root directory (delegates to resolve_project_root)
# Usage: get_project_root
get_project_root() {
  resolve_project_root
}

# Resolve state directory (works across IDEs)
# Prefers IDE-specific state dir if it exists, falls back to .agents/state/
resolve_state_dir() {
  local project_root
  project_root=$(resolve_project_root)
  if [[ -z "$project_root" || ! -d "$project_root" ]]; then
    echo "Error: Could not resolve project root directory" >&2
    return 1
  fi
  if [[ -d "$project_root/.claude/state" ]]; then
    echo "$project_root/.claude/state"
  elif [[ -d "$project_root/.kiro/state" ]]; then
    echo "$project_root/.kiro/state"
  else
    if ! mkdir -p "$project_root/.agents/state" 2>/dev/null; then
      echo "Error: Could not create state directory at $project_root/.agents/state" >&2
      return 1
    fi
    echo "$project_root/.agents/state"
  fi
}
