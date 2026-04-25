#!/bin/bash
# State manager utility for tracking development workflow actions
# Manages state for: design-canvas, test-plan, code-simplifier, pr-review, unit-tests, e2e-tests
set -e

# Source shared lib for resolve_project_root
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
STATE_DIR="$(resolve_state_dir)"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Commands
ACTION="${1:-}"
OPERATION="${2:-}"

usage() {
  cat <<EOF
Usage: $0 <command> [action] [files...]

Commands:
  mark <action> [files...]   - Mark an action as completed (optionally for specific files)
  check <action>             - Check if action was completed (exit 0=yes, 1=no)
  clear <action>             - Clear state for an action
  clear-all                  - Clear all state files
  list                       - List current states

Actions:
  design-canvas              - Design canvas created/updated
  test-plan                  - Test plan created
  code-simplifier            - Code simplification review completed
  pr-review                  - PR code review completed
  unit-tests                 - Unit tests run and passed
  e2e-tests                  - E2E tests run and passed
EOF
}

# Validate action name (alphanumeric, hyphens, underscores only)
# Prevents path traversal attacks
validate_action_name() {
  local action="$1"
  if [[ ! "$action" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Invalid action name. Use only alphanumeric, hyphens, and underscores." >&2
    return 1
  fi
  return 0
}

get_state_file() {
  local action="$1"
  validate_action_name "$action" || exit 1
  echo "$STATE_DIR/${action}.json"
}

get_git_head() {
  git rev-parse HEAD 2>/dev/null || echo "unknown"
}

get_staged_files() {
  git diff --cached --name-only 2>/dev/null || echo ""
}

get_current_branch() {
  git branch --show-current 2>/dev/null || echo "unknown"
}

mark_action() {
  local action="$1"
  shift
  local files=("$@")
  local state_file
  state_file=$(get_state_file "$action")
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local git_head
  git_head=$(get_git_head)
  local branch
  branch=$(get_current_branch)

  # If no files provided, use staged files for commit-related actions
  if [[ ${#files[@]} -eq 0 ]]; then
    mapfile -t files < <(get_staged_files)
  fi

  # Create JSON (with or without jq)
  if command -v jq &> /dev/null; then
    local files_json
    files_json=$(printf '%s\n' "${files[@]}" | jq -R . | jq -s .)
    cat > "$state_file" <<EOF
{
  "action": "$action",
  "timestamp": "$timestamp",
  "files": $files_json,
  "git_head": "$git_head",
  "branch": "$branch"
}
EOF
  else
    # Fallback without jq - use sed for safer JSON escaping
    local files_str=""
    for f in "${files[@]}"; do
      # Use sed for escaping to avoid command injection via bash string substitution
      local escaped_f
      escaped_f=$(printf '%s' "$f" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr -d '\n')
      if [[ -n "$files_str" ]]; then
        files_str="$files_str, \"$escaped_f\""
      else
        files_str="\"$escaped_f\""
      fi
    done
    cat > "$state_file" <<EOF
{
  "action": "$action",
  "timestamp": "$timestamp",
  "files": [$files_str],
  "git_head": "$git_head",
  "branch": "$branch"
}
EOF
  fi

  echo "Marked '$action' as completed at $timestamp"
}

check_action() {
  local action="$1"
  local state_file
  state_file=$(get_state_file "$action")

  # Check if state file exists
  if [[ ! -f "$state_file" ]]; then
    exit 1
  fi

  # Check timestamp (30 min max age)
  if command -v jq &> /dev/null; then
    local timestamp
    # Handle race condition: file may be deleted between existence check and read
    timestamp=$(jq -r '.timestamp // ""' "$state_file" 2>/dev/null) || {
      rm -f "$state_file" 2>/dev/null
      exit 1
    }
    if [[ -z "$timestamp" ]]; then
      rm -f "$state_file" 2>/dev/null
      exit 1
    fi
    local state_time
    state_time=$(date -d "$timestamp" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null || echo "0")
    local current_time
    current_time=$(date +%s)
    local age=$((current_time - state_time))

    # State expires after 30 minutes (1800 seconds)
    if [[ $age -gt 1800 ]]; then
      rm -f "$state_file" 2>/dev/null
      exit 1
    fi

    # Commit-SHA binding for pr-review: the mark must reference the
    # current HEAD. Any new commit invalidates the mark, forcing a
    # fresh review. Without this, `mark pr-review` becomes a 30-minute
    # rubber stamp covering any number of subsequent commits (issue #48).
    if [[ "$action" == "pr-review" ]]; then
      local stored_head current_head
      stored_head=$(jq -r '.git_head // ""' "$state_file" 2>/dev/null)
      current_head=$(get_git_head)
      if [[ -z "$stored_head" || "$stored_head" == "unknown" \
            || "$current_head" == "unknown" \
            || "$stored_head" != "$current_head" ]]; then
        rm -f "$state_file" 2>/dev/null
        exit 1
      fi
    fi
  fi

  exit 0
}

clear_action() {
  local action="$1"
  local state_file
  state_file=$(get_state_file "$action")

  if [[ -f "$state_file" ]]; then
    rm -f "$state_file"
    echo "Cleared state for '$action'"
  else
    echo "No state found for '$action'"
  fi
}

clear_all() {
  rm -f "$STATE_DIR"/*.json 2>/dev/null || true
  echo "Cleared all state files"
}

list_states() {
  if [[ ! -d "$STATE_DIR" ]] || [[ -z "$(ls -A "$STATE_DIR" 2>/dev/null)" ]]; then
    echo "No states recorded"
    return
  fi

  echo "Current states:"
  for state_file in "$STATE_DIR"/*.json; do
    [[ -f "$state_file" ]] || continue
    local action
    action=$(basename "$state_file" .json)
    if command -v jq &> /dev/null; then
      local timestamp
      timestamp=$(jq -r '.timestamp' "$state_file")
      local branch
      branch=$(jq -r '.branch // "unknown"' "$state_file")
      echo "  $action (at $timestamp on $branch)"
    else
      echo "  $action"
    fi
  done
}

# Main command dispatch
case "$ACTION" in
  mark)
    if [[ -z "$OPERATION" ]]; then
      echo "Error: Action name required"
      usage
      exit 1
    fi
    shift 2
    mark_action "$OPERATION" "$@"
    ;;
  check)
    if [[ -z "$OPERATION" ]]; then
      echo "Error: Action name required"
      exit 1
    fi
    check_action "$OPERATION"
    ;;
  clear)
    if [[ -z "$OPERATION" ]]; then
      echo "Error: Action name required"
      exit 1
    fi
    clear_action "$OPERATION"
    ;;
  clear-all)
    clear_all
    ;;
  list)
    list_states
    ;;
  *)
    usage
    exit 1
    ;;
esac
