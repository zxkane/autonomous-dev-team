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

  if ! command -v jq &> /dev/null; then
    echo "1"
    return 1
  fi

  echo "$json_input" | jq -r '.tool_response.exitCode // .tool_response.exit_code // "1"'
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
