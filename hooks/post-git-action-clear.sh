#!/bin/bash
# Post git action hook - clears state after successful git operations
# Usage: post-git-action-clear.sh <git-action> <state-to-clear>
#   e.g.: post-git-action-clear.sh commit code-simplifier
#   e.g.: post-git-action-clear.sh push pr-review
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib.sh"
STATE_MANAGER="$SCRIPT_DIR/state-manager.sh"

GIT_ACTION="${1:-commit}"
STATE_TO_CLEAR="${2:-code-simplifier}"

# Validate git action parameter - only allow known git operations
if [[ ! "$GIT_ACTION" =~ ^(commit|push|pull|merge|rebase)$ ]]; then
  echo "Error: Invalid git action" >&2
  exit 1
fi

# Validate state parameter - only allow alphanumeric, hyphens, underscores
if [[ ! "$STATE_TO_CLEAR" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Error: Invalid state name" >&2
  exit 1
fi

input=$(cat)
command=$(parse_command "$input")
exit_code=$(parse_exit_code "$input")

# Only process successful git commands of the specified type
if ! is_git_command "$GIT_ACTION" "$command" || [[ "$exit_code" != "0" ]]; then
  exit 0
fi

# Clear the specified state
"$STATE_MANAGER" clear "$STATE_TO_CLEAR" 2>/dev/null || true

exit 0
