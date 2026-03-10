#!/bin/bash
# lib-agent.sh — Agent CLI abstraction layer.
# Supports: claude (default), codex, kiro, and generic fallback.
# Source this file in autonomous-dev.sh and autonomous-review.sh.

# Load project config if available
_LIB_AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_LIB_AGENT_DIR}/autonomous.conf" ]]; then
  source "${_LIB_AGENT_DIR}/autonomous.conf"
fi

# Agent configuration (overridable via env or autonomous.conf)
AGENT_CMD="${AGENT_CMD:-claude}"
AGENT_DEV_MODEL="${AGENT_DEV_MODEL:-}"
AGENT_REVIEW_MODEL="${AGENT_REVIEW_MODEL:-sonnet}"
AGENT_PERMISSION_MODE="${AGENT_PERMISSION_MODE:-bypassPermissions}"

# Run agent with a new session.
# Args: $1=session_id, $2=prompt, $3=model (optional)
run_agent() {
  local session_id="$1"
  local prompt="$2"
  local model="${3:-}"

  case "$AGENT_CMD" in
    claude)
      "$AGENT_CMD" --session-id "$session_id" \
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
    *)
      "$AGENT_CMD" -p "$prompt"
      ;;
  esac
}

# Resume an existing agent session.
# Args: $1=session_id, $2=prompt, $3=model (optional)
resume_agent() {
  local session_id="$1"
  local prompt="$2"
  local model="${3:-}"

  case "$AGENT_CMD" in
    claude)
      "$AGENT_CMD" --resume "$session_id" \
        --permission-mode "$AGENT_PERMISSION_MODE" \
        ${model:+--model "$model"} \
        -p "$prompt" \
        --output-format json
      ;;
    *)
      # Agents without resume support start a new session
      run_agent "$session_id" "$prompt" "$model"
      ;;
  esac
}
