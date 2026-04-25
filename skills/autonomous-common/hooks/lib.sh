#!/bin/bash
# Shared utility functions for hook scripts
# Note: Does not use 'set -e' as this is a library meant to be sourced

# Resolve main project root (works from worktrees and subdirectories).
# Git worktrees have their own .git file pointing to the main repo's .git/worktrees/<name>.
# --git-common-dir returns the main repo's .git directory in both cases.
resolve_project_root() {
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    echo "$CLAUDE_PROJECT_DIR"
  else
    git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git$||' || git rev-parse --show-toplevel 2>/dev/null || pwd
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
# Limitation: the quote-stripping pass does not understand escaped
# quotes (`"see \"git push\" docs"`). This is acceptable because the
# intent is defense-in-depth against incidental mentions, not
# adversarial bypass (any workflow author who wants to dodge the hook
# can use `--no-verify`).
is_git_command() {
  local operation="$1"
  local command="$2"

  # Strip single- and double-quoted regions so mentions inside quoted
  # strings (e.g. `--body "see git push docs"`) cannot match.
  local stripped="$command"
  while [[ "$stripped" =~ \"[^\"]*\" ]]; do
    stripped="${stripped/${BASH_REMATCH[0]}/ }"
  done
  while [[ "$stripped" =~ \'[^\']*\' ]]; do
    stripped="${stripped/${BASH_REMATCH[0]}/ }"
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
