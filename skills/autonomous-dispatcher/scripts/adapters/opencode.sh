#!/bin/bash
# adapters/opencode.sh — opencode CLI adapter ([INV-75]).
#
# All opencode-specific behavior lives here: argv assembly (dev-new / dev-resume)
# via `opencode run --format json`, with the CLI-minted `ses_<base62>` session id
# captured to a sidecar for resume. opencode has no documented "lying mode" beyond
# session-mint capture failure (spec §7: config) — no drop-reason scraper.
#
# Session model: opencode mints its own session id and emits it on EVERY JSON
# event. We capture the first occurrence (_opencode_capture_session) into a sidecar
# keyed by the dispatcher's session_id and feed it back via
# `opencode run --session <id>` on resume.
#
# PRECONDITION: sourced by lib-agent.sh AFTER its shared primitives
# (_run_with_timeout, pid_dir_for_project, _parse_extra_args) are defined.

# adapter_invoke_opencode <mode> <session_id> <prompt> <model> <session_name>
#   mode ∈ { dev-new, dev-resume }
#
# Returns PIPESTATUS[1] — opencode's rc (printf [0] is always 0; capture awk [2]
# is well-behaved). Stdin marker: `opencode run` reads the prompt from stdin when
# no positional message is given (INV-34).
adapter_invoke_opencode() {
  local mode="$1" session_id="$2" prompt="$3" model="${4:-}" session_name="${5:-}"
  local extra_args=()
  if [[ "$mode" == "dev-resume" ]]; then
    _parse_extra_args AGENT_REVIEW_EXTRA_ARGS extra_args
  else
    _parse_extra_args AGENT_DEV_EXTRA_ARGS extra_args
  fi

  if [[ "$mode" == "dev-resume" ]]; then
    # `opencode run --session <id>` resumes; read the captured id from the sidecar,
    # fall back to a fresh run if missing (run_agent crashed before the first event).
    local _opencode_sid
    if _opencode_sid=$(_opencode_session_id "$session_id"); then
      printf '%s' "$prompt" \
        | _run_with_timeout "$AGENT_CMD" run --format json --session "$_opencode_sid" \
          ${model:+--model "$model"} \
          "${extra_args[@]}" \
        | _opencode_capture_session "$session_id"
      return "${PIPESTATUS[1]}"
    else
      echo "[lib-agent] no captured opencode sessionID for session $session_id; starting a new opencode session" >&2
      run_agent "$session_id" "$prompt" "$model" "$session_name"
      return $?
    fi
  fi

  # dev-new: fresh `opencode run`, --title for a human-readable handle, capture id.
  printf '%s' "$prompt" \
    | _run_with_timeout "$AGENT_CMD" run --format json \
      ${model:+--model "$model"} \
      ${session_name:+--title "$session_name"} \
      "${extra_args[@]}" \
    | _opencode_capture_session "$session_id"
  return "${PIPESTATUS[1]}"
}

# ---------------------------------------------------------------------------
# Opencode session-id capture/recall — relocated verbatim from lib-agent.sh.
#
# opencode `run` mints its own session id (`ses_<base62>`) per invocation and
# accepts `--session <id>` only for resuming. Mirror the codex helpers; the field
# is `sessionID` (camelCase, on EVERY event), so we capture the first occurrence.
# ---------------------------------------------------------------------------

_opencode_session_file() {
  local session_id="$1"
  local pid_dir
  pid_dir=$(pid_dir_for_project) || return 1
  printf '%s/opencode-session-%s\n' "$pid_dir" "$session_id"
}

# _opencode_capture_session <dispatcher_session_id>
# Pass-through awk filter: streams stdin → stdout unchanged and writes the first
# observed sessionID to a sidecar. Same pattern + CWE-59 safety as
# _codex_capture_thread. Format verified against opencode v1.14.46.
_opencode_capture_session() {
  local session_id="$1"
  local sess_file
  sess_file=$(_opencode_session_file "$session_id") || { cat; return 0; }
  awk -v out="$sess_file" '
    BEGIN {
      prefix = "\"sessionID\":\""
    }
    {
      print
      fflush()
      if (!captured) {
        if (match($0, /"sessionID":"ses_[A-Za-z0-9]+"/)) {
          sid = substr($0, RSTART + length(prefix), RLENGTH - length(prefix) - 1)
          cmd = "test -L \"" out "\" && exit 0; printf \"%s\\n\" \"" sid "\" > \"" out "\""
          system(cmd)
          captured = 1
        }
      }
    }'
}

# _opencode_session_id <dispatcher_session_id>
# Read + validate the captured sessionID. Echo + rc 0 on hit, nothing + rc 1 on
# miss/malformed/symlink. The `^ses_[A-Za-z0-9]+$` regex matches the documented
# format and protects the downstream `--session <id>` invocation from injection.
_opencode_session_id() {
  local session_id="$1"
  local sess_file sid
  sess_file=$(_opencode_session_file "$session_id") || return 1
  [[ -L "$sess_file" ]] && return 1
  [[ -f "$sess_file" ]] || return 1
  sid=$(head -n1 "$sess_file" 2>/dev/null)
  [[ "$sid" =~ ^ses_[A-Za-z0-9]+$ ]] || return 1
  printf '%s\n' "$sid"
}
