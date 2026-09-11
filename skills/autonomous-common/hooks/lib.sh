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

# Remove shell regions that are definitively non-executable while preserving
# executable text and line boundaries. The scanner handles simple shell words,
# comments, and identifier-delimited heredocs. Once it sees syntax whose word
# boundaries require a fuller parser (expansions, arithmetic, process
# substitution, extended tests, or attached parentheses), it preserves the
# remaining input unchanged so callers retain their fail-closed behavior.
_strip_shell_non_executable_regions() {
  local cat_is_external=0
  local gh_is_external=0
  # Only external binaries have fixed stdin behavior. A shell function named
  # cat or gh could evaluate the heredoc body and must remain fail-closed.
  if [[ "$(type -t cat 2>/dev/null)" == "file" ]]; then
    cat_is_external=1
  fi
  if [[ "$(type -t gh 2>/dev/null)" == "file" ]]; then
    gh_is_external=1
  fi

  printf '%s' "$1" | awk \
    -v cat_is_external="$cat_is_external" \
    -v gh_is_external="$gh_is_external" '
    BEGIN {
      state = "unquoted"
      word_start = 1
      pending_count = 0
      pending_ambiguous = 0
      active_count = 0
      active_index = 1
      logical_control_seen = 0
      command_seen = 0
      ambiguous = 0
      single_quote = sprintf("%c", 39)
    }

    function clear_pending(   idx) {
      for (idx = 1; idx <= pending_count; idx++) {
        delete pending_tags[idx]
        delete pending_strip_tabs[idx]
        delete pending_expands[idx]
      }
      pending_count = 0
      pending_ambiguous = 0
    }

    function activate_pending() {
      active_count = pending_count
      active_index = 1
      pending_ambiguous = 0
    }

    function record_heredoc(line, position,
                            strip_tabs, expands, idx, first, quote, start, tag,
                            boundary) {
      idx = position + 2
      strip_tabs = 0
      expands = 1
      if (substr(line, idx, 1) == "-") {
        strip_tabs = 1
        idx++
      }
      while (substr(line, idx, 1) == " " ||
             substr(line, idx, 1) == "\t") {
        idx++
      }

      first = substr(line, idx, 1)
      if (first == "\\") {
        expands = 0
        idx++
      } else if (first == single_quote || first == "\"") {
        expands = 0
        quote = first
        idx++
      }

      start = idx
      while (substr(line, idx, 1) ~ /[A-Za-z0-9_]/) {
        idx++
      }
      tag = substr(line, start, idx - start)
      if (quote != "") {
        if (substr(line, idx, 1) != quote) {
          return 0
        }
        idx++
      }

      boundary = substr(line, idx, 1)
      if (tag !~ /^[A-Za-z_][A-Za-z0-9_]*$/ ||
          (boundary != "" && boundary !~ /[ \t;&|()<>]/)) {
        return 0
      }

      pending_count++
      pending_tags[pending_count] = tag
      pending_strip_tabs[pending_count] = strip_tabs
      pending_expands[pending_count] = expands
      return 1
    }

    function has_executable_heredoc_expansion(line,   idx, character,
                                              following) {
      for (idx = 1; idx <= length(line); idx++) {
        character = substr(line, idx, 1)
        following = substr(line, idx + 1, 1)
        if (character == "\\" &&
            (following == "\\" || following == "$" ||
             following == "`")) {
          idx++
        } else if (character == "`" ||
                   (character == "$" && following == "(")) {
          return 1
        }
      }
      return 0
    }

    function is_trusted_heredoc_consumer(line) {
      if (cat_is_external && line ~ /^[ \t]*cat([ \t<>]|$)/) {
        return 1
      }
      if (gh_is_external &&
          line ~ /^[ \t]*gh[ \t]+pr[ \t]+(create|comment|edit)([ \t]|$)/ &&
          line ~ /--body-file([ \t]+|=)-([ \t<]|$)/) {
        return 1
      }
      return 0
    }

    ambiguous {
      print
      next
    }

    active_count > 0 {
      if (pending_expands[active_index] &&
          has_executable_heredoc_expansion($0)) {
        ambiguous = 1
        print
        next
      }
      candidate = $0
      if (pending_strip_tabs[active_index]) {
        sub(/^\t+/, "", candidate)
      }
      print ""
      if (candidate == pending_tags[active_index]) {
        delete pending_tags[active_index]
        delete pending_strip_tabs[active_index]
        delete pending_expands[active_index]
        active_index++
        if (active_index > active_count) {
          active_count = 0
          active_index = 1
          pending_count = 0
        }
      }
      state = "unquoted"
      word_start = 1
      next
    }

    {
      line = $0
      cleaned = ""
      line_continued = 0

      for (i = 1; i <= length(line); i++) {
        character = substr(line, i, 1)
        following = substr(line, i + 1, 1)
        previous = i > 1 ? substr(line, i - 1, 1) : ""
        after = substr(line, i + 2, 1)

        if (state == "single") {
          cleaned = cleaned character
          if (character == single_quote) {
            state = "unquoted"
          }
          continue
        }

        if (state == "double") {
          cleaned = cleaned character
          if (character == "\\") {
            if (following != "") {
              cleaned = cleaned following
              i++
            }
          } else if (character == "`" ||
                     (character == "$" && following == "(")) {
            ambiguous = 1
            cleaned = cleaned substr(line, i + 1)
            state = "unquoted"
            break
          } else if (character == "\"") {
            state = "unquoted"
          }
          continue
        }

        if (character == "\\") {
          cleaned = cleaned character
          if (following != "") {
            cleaned = cleaned following
            i++
          } else {
            line_continued = 1
          }
          word_start = 0
        } else if (character == single_quote) {
          cleaned = cleaned character
          state = "single"
          word_start = 0
        } else if (character == "\"") {
          cleaned = cleaned character
          state = "double"
          word_start = 0
        } else if (character == "#" && word_start) {
          break
        } else if ((character == "$" &&
                    (following == "(" || following == "{" ||
                     following == "[")) ||
                   character == "`" ||
                   ((character == "<" || character == ">") &&
                    following == "(") ||
                   (character == "[" && following == "[") ||
                   (character == "(" &&
                    (following == "(" || !word_start))) {
          ambiguous = 1
          cleaned = cleaned substr(line, i)
          break
        } else {
          cleaned = cleaned character
          if (character == "<" && following == "<" &&
              previous != "<" && after != "<") {
            if (!record_heredoc(line, i)) {
              pending_ambiguous = 1
            } else if (command_seen ||
                       !is_trusted_heredoc_consumer(line) ||
                       logical_control_seen) {
              pending_ambiguous = 1
            }
          }

          if (character == "|" || character == ";" ||
              (character == "&" && previous != "<" && previous != ">" &&
               following != ">")) {
            logical_control_seen = 1
            if (pending_count > 0) {
              pending_ambiguous = 1
            }
          }

          if (character == "|" &&
              (following == "|" || following == "&")) {
            cleaned = cleaned following
            i++
          } else if (character == "&" && following == "&") {
            cleaned = cleaned following
            i++
          }

          if (character == ")") {
            word_start = 0
          } else if (character == " " || character == "\t" ||
                     index(";&|(<>" , character) > 0) {
            word_start = 1
          } else {
            word_start = 0
          }
        }
      }

      if (ambiguous) {
        print cleaned
        next
      }

      if (cleaned !~ /^[ \t]*$/) {
        command_seen = 1
      }

      if (state == "unquoted" && !line_continued) {
        if (pending_count > 0 && !pending_ambiguous) {
          activate_pending()
        } else {
          clear_pending()
        }
        word_start = 1
        logical_control_seen = 0
      } else if (state == "unquoted") {
        if (pending_count > 0) {
          pending_ambiguous = 1
        }
        word_start = 0
      }
      print cleaned
    }

    END {
      if (ambiguous) {
        exit 2
      }
    }
  '
}

# Match git invocations in command text whose non-executable regions have
# already been removed or deliberately exposed for fail-closed scanning.
_git_command_tokens_contain_operation() {
  local operation="$1"
  local command="$2"
  local normalised

  normalised=$(printf '%s' "$command" | sed -E 's/(\|\||&&|;|\||&)/\n/g')

  local segment
  while IFS= read -r segment; do
    local -a tokens
    read -ra tokens <<<"$segment"
    local i=0 n=${#tokens[@]}
    while (( i < n )) && [[ "${tokens[i]}" != "git" ]]; do
      ((i++))
    done
    (( i >= n )) && continue
    ((i++))
    while (( i < n )); do
      case "${tokens[i]}" in
        -c|-C|--git-dir|--work-tree|--namespace|--super-prefix)
          i=$(( i + 2 > n ? n : i + 2 ))
          ;;
        --*=*|--*|-*)
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

_shell_text_outside_simple_quotes_contains_git_operation() {
  local operation="$1"
  local stripped="$2"

  # Quote BASH_REMATCH[0] in the substitution. It is literal matched text, but
  # an unquoted replacement pattern containing `\`, `[`, `?`, or `*` could
  # leave the string unchanged and make these loops spin forever. See #266.
  while [[ "$stripped" =~ \"[^\"]*\" ]]; do
    stripped="${stripped/"${BASH_REMATCH[0]}"/ }"
  done
  while [[ "$stripped" =~ \'[^\']*\' ]]; do
    stripped="${stripped/"${BASH_REMATCH[0]}"/ }"
  done
  stripped=$(
    printf '%s' "$stripped" |
      sed -E 's/(^|[[:space:];|&(])#.*/\1/'
  )
  _git_command_tokens_contain_operation "$operation" "$stripped"
}

_shell_code_is_dynamic() {
  local code="$1"
  [[ "$code" == *'$'* || "$code" == *'`'* ||
    "$code" == *'<('* || "$code" == *'>('* ]]
}

_shell_static_code_contains_git_operation() {
  local operation="$1"
  local code="$2"

  _resolve_git_command_tokenize "$code"
  _resolve_git_tokens_contain_operation "$operation"
}

# Inspect literal code passed to eval or a shell -c invocation. Dynamic text is
# never evaluated; retain it for a conservative literal operation scan instead
# of treating every expansion as a git operation.
_shell_code_executor_contains_git_operation() {
  local operation="$1"
  local command="$2"
  local conservative_result="${3:--1}"
  local i j n executor code option saw_c skip_candidate
  local _SHELL_DATA_BUILTINS_TRUSTED=0
  local -a token_types token_values

  if (( conservative_result < 0 )); then
    if _conservative_shell_text_contains_git_operation \
      "$operation" "$command"; then
      conservative_result=0
    else
      conservative_result=1
    fi
  fi

  _resolve_git_command_tokenize "$command"
  token_types=("${_RGCC_TOKEN_TYPES[@]}")
  token_values=("${_RGCC_TOKEN_VALUES[@]}")
  n=${#token_values[@]}

  for ((i = 0; i < n; i++)); do
    [[ "${token_types[i]}" == "word" ]] || continue
    if (( i > 0 )) && [[ "${token_types[i-1]}" != "operator" ]]; then
      continue
    fi

    j=$i
    while (( j < n )) && [[ "${token_types[j]}" == "word" ]] &&
      [[ "${token_values[j]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
      ((j++))
    done

    skip_candidate=0
    while (( j < n )) && [[ "${token_types[j]}" == "word" ]]; do
      case "${token_values[j]}" in
        '!'|then|do|else|elif|'{')
          ((j++))
          ;;
        exec)
          ((j++))
          while (( j < n )) && [[ "${token_types[j]}" == "word" ]]; do
            option="${token_values[j]}"
            if _shell_code_is_dynamic "$option"; then
              if (( conservative_result == 0 )); then
                return 0
              fi
              skip_candidate=1
              break
            fi
            case "$option" in
              --)
                ((j++))
                break
                ;;
              -a)
                (( j + 1 < n )) &&
                  [[ "${token_types[j+1]}" == "word" ]] || return 0
                j=$((j + 2))
                ;;
              -c|-l)
                ((j++))
                ;;
              -*)
                return 0
                ;;
              *)
                break
                ;;
            esac
          done
          ;;
        command)
          ((j++))
          while (( j < n )) && [[ "${token_types[j]}" == "word" ]]; do
            option="${token_values[j]}"
            if _shell_code_is_dynamic "$option"; then
              if (( conservative_result == 0 )); then
                return 0
              fi
              skip_candidate=1
              break
            fi
            case "$option" in
              --)
                ((j++))
                break
                ;;
              -p)
                ((j++))
                ;;
              -v|-V)
                skip_candidate=1
                break
                ;;
              -*)
                return 0
                ;;
              *)
                break
                ;;
            esac
          done
          ;;
        builtin)
          ((j++))
          if (( j < n )) && [[ "${token_values[j]}" == "--" ]]; then
            ((j++))
          elif (( j < n )) && [[ "${token_values[j]}" == "-p" ]]; then
            skip_candidate=1
          fi
          ;;
        env)
          ((j++))
          while (( j < n )) && [[ "${token_types[j]}" == "word" ]]; do
            option="${token_values[j]}"
            if _shell_code_is_dynamic "$option"; then
              if (( conservative_result == 0 )); then
                return 0
              fi
              skip_candidate=1
              break
            fi
            if [[ "$option" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
              ((j++))
              continue
            fi
            case "$option" in
              --|-)
                ((j++))
                break
                ;;
              -u|-C|-S|--unset|--chdir|--split-string)
                (( j + 1 < n )) &&
                  [[ "${token_types[j+1]}" == "word" ]] || return 0
                j=$((j + 2))
                ;;
              --unset=*|--chdir=*|--split-string=*|-i|--ignore-environment|\
                -0|--null|-v|--debug)
                ((j++))
                ;;
              -*)
                return 0
                ;;
              *)
                break
                ;;
            esac
          done
          ;;
        *)
          break
          ;;
      esac
    done
    (( skip_candidate == 0 )) || continue

    (( j < n )) && [[ "${token_types[j]}" == "word" ]] || continue
    executor="${token_values[j]}"
    if _shell_code_is_dynamic "$executor"; then
      if (( conservative_result == 0 )); then
        return 0
      fi
      continue
    fi
    executor="${executor//\\/}"
    executor="${executor##*/}"

    if [[ "$executor" == "eval" ]]; then
      code=""
      for ((j = j + 1; j < n; j++)); do
        [[ "${token_types[j]}" == "word" ]] || break
        code+="${code:+ }${token_values[j]}"
      done
      [[ -n "$code" ]] || continue
      if _shell_code_contains_git_operation "$operation" "$code"; then
        return 0
      fi
      if _shell_code_is_dynamic "$code" &&
        (( conservative_result == 0 )); then
        return 0
      fi
      continue
    fi

    case "$executor" in
      sh|bash|dash|ksh|zsh) ;;
      *) continue ;;
    esac

    saw_c=0
    for ((j = j + 1; j < n; j++)); do
      [[ "${token_types[j]}" == "word" ]] || break
      option="${token_values[j]}"
      if _shell_code_is_dynamic "$option"; then
        if (( conservative_result == 0 )); then
          return 0
        fi
        skip_candidate=1
        break
      fi
      if { [[ "$option" != -* ]] && [[ "$option" != +* ]]; } ||
        [[ "$option" == "--" ]]; then
        break
      fi
      case "$option" in
        -O|+O|-o|+o|--rcfile|--init-file)
          if (( j + 1 < n )) && [[ "${token_types[j+1]}" == "word" ]] &&
            [[ "${token_values[j+1]}" != -* ]]; then
            ((j++))
          fi
          continue
          ;;
        --rcfile=*|--init-file=*)
          continue
          ;;
        --noprofile|--norc|--posix|--restricted|--verbose|--version|--help|\
          --login|--debugger|--dump-po-strings|--dump-strings)
          continue
          ;;
        --*)
          return 0
          ;;
        +*)
          return 0
          ;;
      esac
      if [[ "$option" =~ ^-[^-]*c ]]; then
        saw_c=1
        ((j++))
        break
      fi
    done
    (( skip_candidate == 0 )) || continue
    (( saw_c == 1 && j < n )) &&
      [[ "${token_types[j]}" == "word" ]] || continue

    code="${token_values[j]}"
    if _shell_code_contains_git_operation "$operation" "$code"; then
      return 0
    fi
    if _shell_code_is_dynamic "$code" &&
      (( conservative_result == 0 )); then
      return 0
    fi
  done
  return 1
}

_shell_code_is_trusted_data_builtin() {
  local code="$1"
  local i

  [[ "${_SHELL_DATA_BUILTINS_TRUSTED:-0}" == "1" ]] || return 1
  _resolve_git_command_tokenize "$code"
  (( _RGCC_UNSAFE == 0 && _RGCC_MALFORMED == 0 )) ||
    return 1
  (( ${#_RGCC_TOKEN_VALUES[@]} > 0 )) || return 1
  for ((i = 0; i < ${#_RGCC_TOKEN_TYPES[@]}; i++)); do
    [[ "${_RGCC_TOKEN_TYPES[i]}" == "word" ]] || return 1
  done
  case "${_RGCC_TOKEN_VALUES[0]}" in
    echo)
      [[ "$(type -t echo 2>/dev/null)" == "builtin" ]]
      ;;
    printf)
      if (( ${#_RGCC_TOKEN_VALUES[@]} > 1 )) &&
        [[ "${_RGCC_TOKEN_VALUES[1]}" == -v* ]]; then
        return 1
      fi
      [[ "$(type -t printf 2>/dev/null)" == "builtin" ]]
      ;;
    *) return 1 ;;
  esac
}

_shell_code_contains_git_operation() {
  local operation="$1"
  local code="$2"
  local preprocessed="${3:-0}"
  local conservative_result
  local stripped_code strip_rc

  if (( preprocessed == 0 )); then
    if stripped_code=$(_strip_shell_non_executable_regions "$code"); then
      code="$stripped_code"
    else
      strip_rc=$?
      if (( strip_rc == 2 )); then
        code="$stripped_code"
      fi
    fi
  fi
  _shell_code_is_trusted_data_builtin "$code" && return 1
  _shell_static_code_contains_git_operation "$operation" "$code" && return 0
  if _conservative_shell_text_contains_git_operation "$operation" "$code"; then
    conservative_result=0
  else
    conservative_result=1
  fi
  if _shell_code_executor_contains_git_operation \
    "$operation" "$code" "$conservative_result"; then
    return 0
  fi
  if (( conservative_result == 0 )); then
    _shell_code_is_trusted_data_builtin "$code" && return 1
    return 0
  fi
  return 1
}

_conservative_shell_text_contains_git_operation() {
  local operation="$1"
  local command="$2"
  local backtick='`'

  command="${command//\"/ }"
  command="${command//\'/ }"
  command="${command//$backtick/ }"
  command="${command//\(/ }"
  command="${command//\)/ }"
  command="${command//\{/ }"
  command="${command//\}/ }"
  command="${command//\[/ }"
  command="${command//\]/ }"
  _git_command_tokens_contain_operation "$operation" "$command"
}

_large_static_shell_text_contains_git_operation() {
  local operation="$1"
  local command="$2"
  local target_ref="${3:-}"

  printf '%s' "$command" | awk \
    -v operation="$operation" -v target_ref="$target_ref" '
    BEGIN {
      state = "unquoted"
      value = ""
      started = 0
      count = 0
      single_quote = sprintf("%c", 39)
      backtick = sprintf("%c", 96)
    }

    function emit_word() {
      if (started) {
        count++
        types[count] = "word"
        values[count] = value
      }
      value = ""
      started = 0
    }

    function emit_operator() {
      emit_word()
      count++
      types[count] = "operator"
      values[count] = ";"
    }

    function targets_ref(ref, separator, destination) {
      destination = ref
      separator = index(ref, ":")
      if (separator > 0) {
        destination = substr(ref, separator + 1)
      }
      return destination == target_ref ||
             destination == "refs/heads/" target_ref
    }

    {
      line = $0
      for (i = 1; i <= length(line); i++) {
        character = substr(line, i, 1)
        following = substr(line, i + 1, 1)
        if (state == "single") {
          if (character == single_quote) {
            state = "unquoted"
          } else {
            value = value character
          }
          continue
        }
        if (state == "double") {
          if (character == "\"") {
            state = "unquoted"
          } else if (character == "\\") {
            if (following != "") {
              value = value following
              i++
            } else {
              value = value character
            }
          } else {
            value = value character
          }
          continue
        }

        if (character == single_quote) {
          state = "single"
          started = 1
        } else if (character == "\"") {
          state = "double"
          started = 1
        } else if (character == "\\") {
          started = 1
          if (following != "") {
            value = value following
            i++
          } else {
            value = value character
          }
        } else if (character == " " || character == "\t") {
          emit_word()
        } else if (character == "&" || character == "|" ||
                   character == ";" || character == "(" ||
                   character == ")" || character == backtick) {
          emit_operator()
        } else {
          started = 1
          value = value character
        }
      }
      if (state == "unquoted") {
        emit_operator()
      } else {
        value = value "\n"
      }
    }

    END {
      emit_word()
      command_position = 1
      for (i = 1; i <= count; i++) {
        if (types[i] == "operator") {
          command_position = 1
          continue
        }
        if (!command_position) {
          continue
        }
        if (values[i] == "!" || values[i] == "if" ||
            values[i] == "then" || values[i] == "elif" ||
            values[i] == "else" || values[i] == "do" ||
            values[i] == "while" || values[i] == "until" ||
            values[i] == "{" || values[i] == "}") {
          continue
        }
        if (values[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
          continue
        }
        if (values[i] != "git") {
          command_position = 0
          continue
        }
        j = i + 1
        while (j <= count && types[j] == "word") {
          if (values[j] == "-c" || values[j] == "-C" ||
              values[j] == "--git-dir" || values[j] == "--work-tree" ||
              values[j] == "--namespace" ||
              values[j] == "--super-prefix") {
            j += 2
          } else if (values[j] ~ /^-/) {
            j++
          } else {
            break
          }
        }
        if (j <= count && types[j] == "word" &&
            values[j] == operation) {
          if (target_ref == "") {
            exit 0
          }
          found_remote = 0
          for (j = j + 1; j <= count && types[j] == "word"; j++) {
            option = values[j]
            if (option == "--all" || option == "--mirror") {
              exit 0
            }
            if (option == "--repo") {
              j++
              found_remote = 1
              continue
            }
            if (option ~ /^--repo=/) {
              found_remote = 1
              continue
            }
            if (option == "-o" || option == "--push-option" ||
                option == "--receive-pack" || option == "--exec") {
              j++
              continue
            }
            if (option ~ /^-/) {
              continue
            }
            if (!found_remote) {
              found_remote = 1
              continue
            }
            if (targets_ref(option)) {
              exit 0
            }
          }
        }
        command_position = 0
      }
      exit 1
    }
  '
}

# Large ambiguous command strings must not enter the quadratic character and
# token fallback paths unless a static or dynamic git-operation candidate
# remains. The external pre-scan is linear and understands shell quote
# concatenation; a positive result is intentionally fail-closed.
_large_ambiguous_shell_text_contains_git_operation() {
  local operation="$1"
  local command="$2"

  if _large_static_shell_text_contains_git_operation \
    "$operation" "$command"; then
    return 0
  fi

  # ANSI shell strings can encode either candidate word, so retain the full
  # tokenizer for them. Other dynamic-git forms retain the operation word, and
  # dynamic-operation forms retain the git word.
  case "$command" in
    *"\$'"*|*git*|*"$operation"*) ;;
    *) return 1 ;;
  esac

  _resolve_git_command_tokenize "$command" 1
  if _resolve_git_tokens_contain_operation "$operation"; then
    return 0
  fi
  if (( _RGCC_UNSAFE == 1 )) &&
    _resolve_git_unsafe_tokens_contain_operation "$operation"; then
    return 0
  fi
  _conservative_shell_text_contains_git_operation "$operation" "$command"
}

# Emit the byte spans of executable shell substitutions without copying their
# bodies through a delimiter-based protocol. Each B record is:
#   B <start> <length> <top-level> <opener-width> <closing-position>
# A leading S record reports 0 for balanced input or 2 for malformed input;
# balanced input then emits at most 4096 B records. LC_ALL=C keeps awk and Bash
# byte offsets aligned.
_large_shell_substitution_spans() {
  local command="$1"

  LC_ALL=C printf '%s' "$command" | LC_ALL=C awk '
    BEGIN {
      level = 0
      type[0] = "root"
      state[0] = "unquoted"
      context_start[0] = 0
      group_depth[0] = 0
      position = 0
      malformed = 0
      single_quote = sprintf("%c", 39)
      backtick = sprintf("%c", 96)
    }

    function open_context(kind, body_start, width) {
      level++
      type[level] = kind
      state[level] = "unquoted"
      context_start[level] = body_start
      group_depth[level] = 0
      opener_width[level] = width
      pending_tag[level] = ""
      active_tag[level] = ""
      strip_tabs[level] = 0
    }

    function close_context(closing_position,   body_length, top) {
      body_length = closing_position - context_start[level]
      top = level == 1 ? 1 : 0
      if (record_count >= 4096) {
        malformed = 1
      } else {
        record_count++
        record_start[record_count] = context_start[level]
        record_length[record_count] = body_length
        record_top[record_count] = top
        record_width[record_count] = opener_width[level]
        record_close[record_count] = closing_position
      }
      delete type[level]
      delete state[level]
      delete context_start[level]
      delete group_depth[level]
      delete opener_width[level]
      delete pending_tag[level]
      delete active_tag[level]
      delete strip_tabs[level]
      level--
    }

    function record_heredoc(line, opener_index,   cursor, first, quote, start, tag,
                            boundary, tabs) {
      cursor = opener_index + 2
      tabs = 0
      if (substr(line, cursor, 1) == "-") {
        tabs = 1
        cursor++
      }
      while (substr(line, cursor, 1) == " " ||
             substr(line, cursor, 1) == "\t") {
        cursor++
      }
      first = substr(line, cursor, 1)
      quote = ""
      if (first == "\\") {
        cursor++
      } else if (first == single_quote || first == "\"") {
        quote = first
        cursor++
      }
      start = cursor
      while (substr(line, cursor, 1) ~ /[A-Za-z0-9_]/) {
        cursor++
      }
      tag = substr(line, start, cursor - start)
      if (quote != "") {
        if (substr(line, cursor, 1) != quote) {
          return 0
        }
        cursor++
      }
      boundary = substr(line, cursor, 1)
      if (tag !~ /^[A-Za-z_][A-Za-z0-9_]*$/ ||
          (boundary != "" && boundary !~ /[ \t;&|()<>]/)) {
        return 0
      }
      if (pending_tag[level] != "") {
        malformed = 1
        return 0
      }
      pending_tag[level] = tag
      pending_strip_tabs[level] = tabs
      heredoc_end = cursor - 1
      return 1
    }

    {
      line = $0
      candidate = line
      if (active_tag[level] != "") {
        if (strip_tabs[level]) {
          sub(/^\t+/, "", candidate)
        }
        if (candidate == active_tag[level]) {
          active_tag[level] = ""
          strip_tabs[level] = 0
        }
        position += length(line) + 1
        next
      }

      for (i = 1; i <= length(line); i++) {
        character = substr(line, i, 1)
        following = substr(line, i + 1, 1)
        previous = i > 1 ? substr(line, i - 1, 1) : "\n"
        after = substr(line, i + 2, 1)
        absolute = position + i - 1

        if (type[level] == "backtick") {
          if (character == "\\") {
            i++
          } else if (character == backtick) {
            close_context(absolute)
          }
          continue
        }

        if (state[level] == "comment") {
          continue
        }
        if (state[level] == "single") {
          if (character == single_quote) {
            state[level] = "unquoted"
          }
          continue
        }
        if (state[level] == "double") {
          if (character == "\\") {
            i++
          } else if (character == "\"") {
            state[level] = "unquoted"
          } else if (character == "$" && following == "(") {
            open_context("paren", absolute + 2, 2)
            i++
          } else if (character == backtick) {
            open_context("backtick", absolute + 1, 1)
          }
          continue
        }

        if (character == "\\") {
          i++
        } else if (character == single_quote) {
          state[level] = "single"
        } else if (character == "\"") {
          state[level] = "double"
        } else if (character == "#" &&
                   (absolute == context_start[level] ||
                    previous == " " || previous == "\t" ||
                    previous == "\n" || previous == ";" ||
                    previous == "|" || previous == "&" ||
                    previous == "(")) {
          state[level] = "comment"
        } else if (character == backtick) {
          open_context("backtick", absolute + 1, 1)
        } else if (following == "(" &&
                   (character == "$" || character == "<" ||
                    character == ">")) {
          open_context("paren", absolute + 2, 2)
          i++
        } else if (level > 0 &&
                   character == "<" && following == "<" &&
                   previous != "<" && after != "<") {
          if (!record_heredoc(line, i)) {
            malformed = 1
          } else {
            i = heredoc_end
          }
        } else if (level > 0 && character == "(") {
          group_depth[level]++
        } else if (level > 0 && character == ")") {
          if (group_depth[level] > 0) {
            group_depth[level]--
          } else {
            close_context(absolute)
          }
        }
      }

      if (state[level] == "comment") {
        state[level] = "unquoted"
      }
      if (pending_tag[level] != "") {
        active_tag[level] = pending_tag[level]
        strip_tabs[level] = pending_strip_tabs[level]
        pending_tag[level] = ""
        pending_strip_tabs[level] = 0
      }
      position += length(line) + 1
    }

    END {
      if (level != 0 || state[0] == "single" || state[0] == "double" ||
          active_tag[0] != "" || pending_tag[0] != "") {
        malformed = 1
      }
      print "S\t" (malformed ? 2 : 0)
      for (record_index = 1; record_index <= record_count; record_index++) {
        print "B\t" record_start[record_index] \
          "\t" record_length[record_index] \
          "\t" record_top[record_index] \
          "\t" record_width[record_index] \
          "\t" record_close[record_index]
      }
    }
  '
}

# Strip top-level comments after substitutions have been projected out. This
# intentionally does not re-run heredoc recognition: the caller's first pass
# already masked supported heredoc bodies, including their terminator lines.
_strip_shell_comments() {
  printf '%s' "$1" | awk '
    BEGIN {
      state = "unquoted"
      word_start = 1
      single_quote = sprintf("%c", 39)
    }

    {
      cleaned = ""
      for (i = 1; i <= length($0); i++) {
        character = substr($0, i, 1)
        following = substr($0, i + 1, 1)
        if (state == "single") {
          cleaned = cleaned character
          if (character == single_quote) {
            state = "unquoted"
          }
          continue
        }
        if (state == "double") {
          cleaned = cleaned character
          if (character == "\\") {
            if (following != "") {
              cleaned = cleaned following
              i++
            }
          } else if (character == "\"") {
            state = "unquoted"
          }
          continue
        }
        if (character == "\\") {
          cleaned = cleaned character
          if (following != "") {
            cleaned = cleaned following
            i++
          }
          word_start = 0
        } else if (character == single_quote) {
          cleaned = cleaned character
          state = "single"
          word_start = 0
        } else if (character == "\"") {
          cleaned = cleaned character
          state = "double"
          word_start = 0
        } else if (character == "#" && word_start) {
          break
        } else {
          cleaned = cleaned character
          if (character == " " || character == "\t" ||
              index(";&|(<>" , character) > 0) {
            word_start = 1
          } else {
            word_start = 0
          }
        }
      }
      print cleaned
      if (state == "unquoted") {
        word_start = 1
      }
    }
  '
}

# Substitution-bearing command strings use the linear span extractor above,
# then reuse the normal semantic body analyzer. This avoids treating a readable
# top-level feature push as evidence that an unrelated substitution pushes to
# trunk.
_shell_substitutions_contain_git_operation() {
  local operation="$1"
  local command="$2"
  local LC_ALL=C
  local kind start body_length top_level opener_width closing_position
  local body prefix suffix data_builtins_trusted malformed=2
  local projection="" projection_cursor=0 opener_start
  local substitution_marker='${_ADT_SHELL_SUBSTITUTION}'
  local _SHELL_DATA_BUILTINS_TRUSTED=0
  local _SHELL_SUBSTITUTION_ANALYSIS_LIMIT=64
  local _SHELL_SUBSTITUTION_ANALYSIS_COUNT=0
  local _SHELL_SUBSTITUTION_ANALYSIS_BYTE_LIMIT=8192
  local _SHELL_SUBSTITUTION_ANALYSIS_BYTES=0
  local -a _SHELL_SUBSTITUTION_CACHE_BODIES=()
  local -a _SHELL_SUBSTITUTION_CACHE_TRUST=()
  local -a _SHELL_SUBSTITUTION_CACHE_RESULTS=()

  while IFS=$'\t' read -r kind start body_length top_level opener_width \
    closing_position; do
    if [[ "$kind" == "S" ]]; then
      malformed="$start"
      (( malformed == 0 )) || return 0
      continue
    fi
    [[ "$kind" == "B" ]] || continue
    body="${command:start:body_length}"
    data_builtins_trusted=0
    if (( top_level == 1 )); then
      opener_start=$((start - opener_width))
      projection+=\
"${command:projection_cursor:opener_start-projection_cursor}${substitution_marker}"
      projection_cursor=$((closing_position + 1))
      prefix="${command:0:start-opener_width}"
      suffix="${command:closing_position+1}"
      if _shell_substitution_data_output_is_safe "$prefix" &&
        _shell_substitution_data_suffix_is_safe "$suffix"; then
        data_builtins_trusted=1
      fi
    fi
    if _shell_substitution_body_contains_git_operation \
      "$operation" "$body" "$data_builtins_trusted"; then
      return 0
    fi
  done < <(_large_shell_substitution_spans "$command")

  (( malformed == 0 )) || return 0
  projection+="${command:projection_cursor}"
  _SHELL_SUBSTITUTION_REMAINDER=$(_strip_shell_comments "$projection")
  return 1
}

_shell_substitution_data_output_is_safe() {
  local prefix="$1"
  local trimmed
  # shellcheck disable=SC2016 # Literal expansion openers are parser markers.
  local parameter_expansion='${' arithmetic_expansion='$[' arithmetic_command='$(('

  [[ "$prefix" != *$'\n'* && "$prefix" != *';'* &&
    "$prefix" != *'&'* && "$prefix" != *'|'* &&
    "$prefix" != *'<'* && "$prefix" != *'>'* &&
    "$prefix" != *"$parameter_expansion"* &&
    "$prefix" != *"$arithmetic_expansion"* &&
    "$prefix" != *"$arithmetic_command"* ]] || return 1
  trimmed="${prefix#"${prefix%%[![:space:]]*}"}"
  if [[ "$trimmed" == "echo" || "$trimmed" == echo[[:space:]]* ]]; then
    [[ "$(type -t echo 2>/dev/null)" == "builtin" ]]
    return
  fi
  if [[ "$trimmed" =~ ^gh[[:space:]]+pr[[:space:]]+(create|comment|edit)([[:space:]].*)?[[:space:]]+--body(=|[[:space:]]+)[\"\']?$ ]]; then
    [[ "$(type -t gh 2>/dev/null)" == "file" ]]
    return
  fi
  return 1
}

_shell_substitution_data_suffix_is_safe() {
  local suffix="$1"
  [[ "$suffix" != *$'\n'* && "$suffix" != *';'* &&
    "$suffix" != *'&'* && "$suffix" != *'|'* &&
    "$suffix" != *'<'* && "$suffix" != *'>'* ]]
}

_shell_substitution_body_contains_git_operation() {
  local operation="$1"
  local body="$2"
  local data_builtins_trusted="$3"
  local analysis_body="$body"
  local stripped_body strip_rc=0
  local i result

  for ((i = 0; i < ${#_SHELL_SUBSTITUTION_CACHE_BODIES[@]}; i++)); do
    if [[ "${_SHELL_SUBSTITUTION_CACHE_BODIES[i]}" == "$body" &&
      "${_SHELL_SUBSTITUTION_CACHE_TRUST[i]}" == "$data_builtins_trusted" ]]; then
      return "${_SHELL_SUBSTITUTION_CACHE_RESULTS[i]}"
    fi
  done

  if stripped_body=$(_strip_shell_non_executable_regions "$body"); then
    analysis_body="$stripped_body"
  else
    strip_rc=$?
    if (( strip_rc == 2 )); then
      analysis_body="$stripped_body"
    fi
  fi

  local _SHELL_DATA_BUILTINS_TRUSTED="$data_builtins_trusted"
  if _shell_code_is_trusted_data_builtin "$analysis_body"; then
    result=1
  else
    # Bound both the number and cumulative size of nested parses per top-level
    # scan. Excess work is unknown and therefore fails closed; repeated bodies
    # reuse the cached result without consuming either budget. Proven static
    # data builtins in a proven data context bypass this semantic-parse budget.
    if (( _SHELL_SUBSTITUTION_ANALYSIS_COUNT >=
        _SHELL_SUBSTITUTION_ANALYSIS_LIMIT ||
      ${#analysis_body} > _SHELL_SUBSTITUTION_ANALYSIS_BYTE_LIMIT -
        _SHELL_SUBSTITUTION_ANALYSIS_BYTES )); then
      return 0
    fi
    _SHELL_SUBSTITUTION_ANALYSIS_COUNT=\
$((_SHELL_SUBSTITUTION_ANALYSIS_COUNT + 1))
    _SHELL_SUBSTITUTION_ANALYSIS_BYTES=\
$((_SHELL_SUBSTITUTION_ANALYSIS_BYTES + ${#analysis_body}))

    if _shell_code_contains_git_operation "$operation" "$analysis_body" 1; then
      result=0
    else
      result=1
    fi
  fi

  i=${#_SHELL_SUBSTITUTION_CACHE_BODIES[@]}
  _SHELL_SUBSTITUTION_CACHE_BODIES[i]="$body"
  _SHELL_SUBSTITUTION_CACHE_TRUST[i]="$data_builtins_trusted"
  _SHELL_SUBSTITUTION_CACHE_RESULTS[i]="$result"
  return "$result"
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
  local stripped_command
  local strip_rc=0

  if stripped_command=$(_strip_shell_non_executable_regions "$command"); then
    command="$stripped_command"
  else
    strip_rc=$?
  fi

  if [[ "$strip_rc" -eq 2 ]]; then
    if _shell_text_outside_simple_quotes_contains_git_operation \
      "$operation" "$stripped_command"; then
      return 0
    fi
    if (( ${#command} >= 4096 )); then
      if _large_ambiguous_shell_text_contains_git_operation \
        "$operation" "$stripped_command"; then
        return 0
      fi
      _shell_substitutions_contain_git_operation \
        "$operation" "$stripped_command"
      return
    fi
    if _shell_substitutions_contain_git_operation \
      "$operation" "$stripped_command"; then
      return 0
    fi
    _resolve_git_command_tokenize "$_SHELL_SUBSTITUTION_REMAINDER" 1
    if (( _RGCC_UNSAFE == 1 )) &&
      _resolve_git_unsafe_tokens_contain_operation "$operation"; then
      return 0
    fi
    command="$_SHELL_SUBSTITUTION_REMAINDER"
  fi

  # Strip simple quoted regions so prose such as "see git push docs" cannot
  # match an executable operation.
  _shell_text_outside_simple_quotes_contains_git_operation \
    "$operation" "$command"
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
  _RGCC_TOKEN_UNQUOTED_UNSAFE+=("$4")
}

_resolve_git_append_operator() {
  _RGCC_TOKEN_TYPES+=("operator")
  _RGCC_TOKEN_VALUES+=("$1")
  _RGCC_TOKEN_QUOTES+=("unquoted")
  _RGCC_TOKEN_ANSI+=("0")
  _RGCC_TOKEN_UNQUOTED_UNSAFE+=("0")
}

# Tokenize only enough shell syntax to recognize the bounded grammar used by
# resolve_git_command_cwd. Unsafe expansion syntax is recorded, never expanded.
_resolve_git_command_tokenize() {
  local command="$1"
  local already_preprocessed="${2:-0}"
  local LC_ALL=C
  local stripped_command
  local state="unquoted"
  local value=""
  local quote_kind=""
  local ansi_syntax=0
  local ansi_segment_truncated=0
  local unquoted_unsafe=0
  local started=0
  local character next operator decoded digits digit
  local codepoint max_digits offset
  local backslash=$'\\'
  local i length

  if [[ "$already_preprocessed" != "1" ]]; then
    if stripped_command=$(_strip_shell_non_executable_regions "$command"); then
      command="$stripped_command"
    fi
  fi
  length=${#command}

  _RGCC_TOKEN_TYPES=()
  _RGCC_TOKEN_VALUES=()
  _RGCC_TOKEN_QUOTES=()
  _RGCC_TOKEN_ANSI=()
  _RGCC_TOKEN_UNQUOTED_UNSAFE=()
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
              _resolve_git_append_word "$value" "${quote_kind:-unquoted}" \
                "$ansi_syntax" "$unquoted_unsafe"
              value=""
              quote_kind=""
              ansi_syntax=0
              unquoted_unsafe=0
              started=0
            fi
            ;;
          $'\n'|$'\r')
            _RGCC_UNSAFE=1
            if (( started == 1 )); then
              _resolve_git_append_word "$value" "${quote_kind:-unquoted}" \
                "$ansi_syntax" "$unquoted_unsafe"
              value=""
              quote_kind=""
              ansi_syntax=0
              unquoted_unsafe=0
              started=0
            fi
            _resolve_git_append_operator ";"
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
          \\)
            next=""
            if (( i + 1 < length )); then
              next="${command:i+1:1}"
            fi
            if [[ "$next" == $'\n' ]]; then
              i=$((i + 1))
            elif [[ "$next" == $'\r' ]] &&
              (( i + 2 < length )) &&
              [[ "${command:i+2:1}" == $'\n' ]]; then
              i=$((i + 2))
            else
              if (( started == 1 )) &&
                [[ "$quote_kind" != "unquoted" && "$quote_kind" != "" ]]; then
                quote_kind="mixed"
              elif (( started == 0 )); then
                quote_kind="unquoted"
              fi
              _RGCC_UNSAFE=1
              unquoted_unsafe=1
              started=1
              value+="$character"
            fi
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
              unquoted_unsafe=1
              started=1
              value+="$character"
            fi
            ;;
          '&'|'|'|';'|'('|')')
            next=""
            if (( i + 1 < length )); then
              next="${command:i+1:1}"
            fi
            if [[ "$character" == '&' && "$started" == "1" &&
              ( "$value" == *'>' || "$value" == *'<' ) ]]; then
              value+="$character"
              continue
            fi
            if [[ "$character" == '&' && "$started" == "0" &&
              "$next" == '>' ]]; then
              quote_kind="unquoted"
              _RGCC_UNSAFE=1
              unquoted_unsafe=1
              started=1
              value="&>"
              i=$((i + 1))
              continue
            fi
            if (( started == 1 )); then
              _resolve_git_append_word "$value" "${quote_kind:-unquoted}" \
                "$ansi_syntax" "$unquoted_unsafe"
              value=""
              quote_kind=""
              ansi_syntax=0
              unquoted_unsafe=0
              started=0
            fi

            operator="$character"
            if [[ "$character" == '&' || "$character" == '|' ]]; then
              if [[ "$next" == "$character" ||
                ( "$character" == '|' && "$next" == '&' ) ]]; then
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
              '`'|'<'|'>'|'{'|'}')
                _RGCC_UNSAFE=1
                unquoted_unsafe=1
                ;;
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
    _resolve_git_append_word "$value" "${quote_kind:-unquoted}" \
      "$ansi_syntax" "$unquoted_unsafe"
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
  _RGCC_STATIC_TOKEN_VALUE="$value"
}

_resolve_git_flag_token_has_unsafe_expansion() {
  local value="$1"
  local match
  # shellcheck disable=SC2016
  local command_sub='$(' arithmetic='$[' backtick='`' braced='${' positional='$@'

  if [[ "$value" == *"$command_sub"* ||
    "$value" == *"$arithmetic"* ||
    "$value" == *"$backtick"* ||
    "$value" == *"$positional"* ]]; then
    return 0
  fi
  while [[ "$value" =~ (\$\{[a-zA-Z_][a-zA-Z0-9_]*\}) ]]; do
    match="${BASH_REMATCH[1]}"
    value="${value/"$match"/}"
  done
  [[ "$value" == *"$braced"* ]]
}

_resolve_git_next_token_is_definite_other_operation() {
  local index="$1"
  local operation="$2"
  local value candidate
  local i n=${#_RGCC_TOKEN_TYPES[@]}

  [[ "${_RGCC_TOKEN_TYPES[index]:-}" == "word" ]] || return 1
  [[ "${_RGCC_TOKEN_ANSI[index]:-0}" != "1" ]] || return 1
  [[ "${_RGCC_TOKEN_UNQUOTED_UNSAFE[index]:-0}" != "1" ]] || return 1
  _resolve_git_static_token_value "$index"
  value="$_RGCC_STATIC_TOKEN_VALUE"
  [[ -n "$value" && "$value" != -* && "$value" != "$operation" ]] || return 1

  for ((i = index + 1; i < n; i++)); do
    [[ "${_RGCC_TOKEN_TYPES[i]}" == "word" ]] || break
    _resolve_git_static_token_value "$i"
    candidate="$_RGCC_STATIC_TOKEN_VALUE"
    [[ "$candidate" == "$operation" ]] && return 1
  done
  return 0
}

# Identify operation words obscured only by rejected expansion/escape syntax.
# A quoted variable token consumed by a git global flag is not an operation.
# This is conservative static analysis; it never expands the input.
_resolve_git_unsafe_tokens_contain_operation() {
  local operation="$1"
  local i j git_word operation_word option_word token_word
  local dynamic_git_word
  local n=${#_RGCC_TOKEN_VALUES[@]}

  for ((i = 0; i < n; i++)); do
    [[ "${_RGCC_TOKEN_TYPES[i]}" == "word" ]] || continue
    dynamic_git_word=0
    _resolve_git_static_token_value "$i"
    git_word="$_RGCC_STATIC_TOKEN_VALUE"
    if [[ "$git_word" != "git" ]]; then
      if (( i != 0 )) && [[ "${_RGCC_TOKEN_TYPES[i-1]}" != "operator" ]]; then
        continue
      fi
      if [[ -n "$git_word" || "${_RGCC_TOKEN_ANSI[i]}" == "1" ]]; then
        continue
      fi
      if [[ "${_RGCC_TOKEN_VALUES[i]}" != *'$'* &&
        "${_RGCC_TOKEN_VALUES[i]}" != *'`'* &&
        "${_RGCC_TOKEN_UNQUOTED_UNSAFE[i]}" != "1" ]]; then
        continue
      fi
      dynamic_git_word=1
    fi

    j=$((i + 1))
    while (( j < n )) && [[ "${_RGCC_TOKEN_TYPES[j]}" == "word" ]]; do
      token_word="${_RGCC_TOKEN_VALUES[j]}"
      _resolve_git_static_token_value "$j"
      option_word="$_RGCC_STATIC_TOKEN_VALUE"
      case "$option_word" in
        -c|-C|--git-dir|--work-tree|--namespace|--super-prefix)
          [[ "$token_word" != *'$'* && "$token_word" != *'`'* ]] || return 0
          [[ "${_RGCC_TOKEN_ANSI[j]}" != "1" ]] || return 0
          [[ "${_RGCC_TOKEN_UNQUOTED_UNSAFE[j]}" != "1" ]] || return 0
          (( j + 1 < n )) &&
            [[ "${_RGCC_TOKEN_TYPES[j+1]}" == "word" ]] || return 0
          if [[ "${_RGCC_TOKEN_UNQUOTED_UNSAFE[j+1]}" == "1" ]]; then
            if _resolve_git_next_token_is_definite_other_operation \
              "$((j + 2))" "$operation"; then
              j=$((j + 2))
              continue
            fi
            return 0
          fi
          if _resolve_git_flag_token_has_unsafe_expansion \
            "${_RGCC_TOKEN_VALUES[j+1]}"; then
            return 0
          fi
          j=$((j + 2))
          ;;
        --git-dir=*|--work-tree=*|--namespace=*|--super-prefix=*)
          [[ "${_RGCC_TOKEN_ANSI[j]}" != "1" ]] || return 0
          if [[ "${_RGCC_TOKEN_UNQUOTED_UNSAFE[j]}" == "1" ]]; then
            if _resolve_git_next_token_is_definite_other_operation \
              "$((j + 1))" "$operation"; then
              ((j++))
              continue
            fi
            return 0
          fi
          if _resolve_git_flag_token_has_unsafe_expansion "$token_word"; then
            return 0
          fi
          if [[ "$token_word" == *'$'* || "$token_word" == *'`'* ]]; then
            case "$token_word" in
              --git-dir=*|--work-tree=*|--namespace=*|--super-prefix=*)
                ;;
              *)
                return 0
                ;;
            esac
          fi
          j=$((j + 1))
          ;;
        -*)
          [[ "$token_word" != *'$'* && "$token_word" != *'`'* ]] || return 0
          [[ "${_RGCC_TOKEN_ANSI[j]}" != "1" ]] || return 0
          [[ "${_RGCC_TOKEN_UNQUOTED_UNSAFE[j]}" != "1" ]] || return 0
          j=$((j + 1))
          ;;
        *)
          break
          ;;
      esac
    done
    (( j < n )) && [[ "${_RGCC_TOKEN_TYPES[j]}" == "word" ]] || continue
    _resolve_git_static_token_value "$j"
    operation_word="$_RGCC_STATIC_TOKEN_VALUE"
    if [[ "$operation_word" == "$operation" ]]; then
      return 0
    fi
    if (( dynamic_git_word == 0 )) &&
      { [[ "${_RGCC_TOKEN_VALUES[j]}" == *'$'* ]] ||
        [[ "${_RGCC_TOKEN_VALUES[j]}" == *'`'* ]] ||
        [[ "${_RGCC_TOKEN_UNQUOTED_UNSAFE[j]}" == "1" ]]; }; then
      return 0
    fi
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
  local canonical_base resolved stripped_command
  local strip_rc=0
  local command_preprocessed=0
  local separator=-1
  local i n

  [[ "$operation" =~ ^[a-zA-Z0-9_-]+$ ]] || return 2
  if stripped_command=$(_strip_shell_non_executable_regions "$command"); then
    command="$stripped_command"
    command_preprocessed=1
  else
    strip_rc=$?
  fi
  if [[ "$strip_rc" -eq 2 ]]; then
    if _shell_text_outside_simple_quotes_contains_git_operation \
      "$operation" "$stripped_command"; then
      return 2
    fi
    if (( ${#command} >= 4096 )); then
      if _large_ambiguous_shell_text_contains_git_operation \
        "$operation" "$stripped_command"; then
        return 2
      fi
      if _shell_substitutions_contain_git_operation \
        "$operation" "$stripped_command"; then
        return 2
      fi
      return 1
    fi
    if _shell_substitutions_contain_git_operation \
      "$operation" "$stripped_command"; then
      return 2
    fi
    _resolve_git_command_tokenize "$_SHELL_SUBSTITUTION_REMAINDER" 1
    if (( _RGCC_UNSAFE == 1 )) &&
      _resolve_git_unsafe_tokens_contain_operation "$operation"; then
      return 2
    fi
    command="$_SHELL_SUBSTITUTION_REMAINDER"
    command_preprocessed=1
  fi
  _resolve_git_command_tokenize "$command" "$command_preprocessed"

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
