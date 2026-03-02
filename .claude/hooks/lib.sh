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
    git rev-parse --path-format=absolute --git-common-dir 2>/dev/null | sed 's|/\.git\(/.*\)\{0,1\}$||' || git rev-parse --show-toplevel 2>/dev/null || pwd
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
  if [[ ! "$field_path" =~ ^[a-zA-Z0-9._\[\]\"]+$ ]]; then
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

# Check if command matches a git operation
# Usage: is_git_command "commit" "$command"
is_git_command() {
  local operation="$1"
  local command="$2"
  [[ "$command" =~ git[[:space:]]+${operation} ]]
}

# Get the project root directory (delegates to resolve_project_root)
# Usage: get_project_root
get_project_root() {
  resolve_project_root
}
