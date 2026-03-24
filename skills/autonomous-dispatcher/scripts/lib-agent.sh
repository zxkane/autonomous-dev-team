#!/bin/bash
# lib-agent.sh — Agent CLI abstraction layer.
# Supports: claude (default), codex, kiro, and generic fallback.
# Source this file in autonomous-dev.sh and autonomous-review.sh.

# Load project config if available
_LIB_AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_LIB_AGENT_DIR}/autonomous.conf" ]]; then
  source "${_LIB_AGENT_DIR}/autonomous.conf"
fi

# Ensure PROJECT_DIR is an absolute path to the repo root.
# autonomous.conf may use a relative BASH_SOURCE trick that can resolve
# incorrectly when sourced indirectly. Fall back to _LIB_AGENT_DIR/../../..
PROJECT_DIR="${PROJECT_DIR:-$(cd "${_LIB_AGENT_DIR}/../../.." && pwd)}"

# Agent configuration (overridable via env or autonomous.conf)
AGENT_CMD="${AGENT_CMD:-claude}"
AGENT_DEV_MODEL="${AGENT_DEV_MODEL:-}"
AGENT_REVIEW_MODEL="${AGENT_REVIEW_MODEL:-sonnet}"
AGENT_PERMISSION_MODE="${AGENT_PERMISSION_MODE:-auto}"
KIRO_AGENT_NAME="${KIRO_AGENT_NAME:-autonomous-dev}"

# Acquire PID guard: prevent duplicate instances for the same issue.
# Checks for symlink attacks, running processes, then writes current PID.
# Args: $1=pid_file, $2=label (e.g. "autonomous-dev"), $3=issue_number
acquire_pid_guard() {
  local pid_file="$1" label="$2" issue_num="$3"
  [[ -L "$pid_file" ]] && { echo "Error: PID file is a symlink — possible attack" >&2; exit 1; }
  if [[ -f "$pid_file" ]]; then
    local existing_pid
    existing_pid=$(cat "$pid_file" 2>/dev/null)
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "[$label] Another instance for issue #${issue_num} is already running (PID $existing_pid). Exiting." >&2
      exit 0
    fi
  fi
  echo $$ > "$pid_file"
}

# Run agent with a new session.
# Args: $1=session_id, $2=prompt, $3=model (optional), $4=session_name (optional)
run_agent() {
  local session_id="$1"
  local prompt="$2"
  local model="${3:-}"
  local session_name="${4:-}"

  case "$AGENT_CMD" in
    claude)
      # Unset CLAUDECODE to allow launching from within an existing session
      env -u CLAUDECODE "$AGENT_CMD" --session-id "$session_id" \
        ${session_name:+--name "$session_name"} \
        --permission-mode "$AGENT_PERMISSION_MODE" \
        ${model:+--model "$model"} \
        -p "$prompt" \
        --output-format json
      ;;
    codex)
      "$AGENT_CMD" \
        ${model:+--model "$model"} \
        -p "$prompt"
      ;;
    kiro)
      # Kiro CLI does not support named sessions (session_id is ignored).
      # Each invocation starts a new conversation in the current directory.
      # --agent ensures the workspace agent (with TDD hooks) is used.
      # Tool trust is handled by allowedTools in .kiro/agents/default.json.
      kiro-cli chat \
        --agent "$KIRO_AGENT_NAME" \
        --no-interactive \
        ${model:+--model "$model"} \
        "$prompt"
      ;;
    *)
      "$AGENT_CMD" -p "$prompt"
      ;;
  esac
}

# Resume an existing agent session.
# Args: $1=session_id, $2=prompt, $3=model (optional), $4=session_name (optional)
# Note: --name may not update the display name on resume (session was already
# named at creation). It is still passed through for kiro/fallback paths that
# start a new session instead of resuming.
resume_agent() {
  local session_id="$1"
  local prompt="$2"
  local model="${3:-}"
  local session_name="${4:-}"

  case "$AGENT_CMD" in
    claude)
      # Unset CLAUDECODE to allow launching from within an existing session
      # --name is omitted: the session retains the name set at creation.
      env -u CLAUDECODE "$AGENT_CMD" --resume "$session_id" \
        --permission-mode "$AGENT_PERMISSION_MODE" \
        ${model:+--model "$model"} \
        -p "$prompt" \
        --output-format json
      ;;
    kiro)
      # Kiro CLI --resume cannot inject new review feedback effectively —
      # the resumed context sees "all done" and exits immediately.
      # Fall back to a new session so the full prompt (with review findings)
      # is treated as fresh instructions.
      run_agent "$session_id" "$prompt" "$model" "$session_name"
      ;;
    *)
      # Agents without resume support start a new session
      run_agent "$session_id" "$prompt" "$model" "$session_name"
      ;;
  esac
}
