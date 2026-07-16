#!/bin/bash
# adapters/claude.sh — Claude Code CLI adapter ([INV-75]).
#
# All Claude-specific behavior lives here: argv assembly for the dev-new /
# dev-resume modes. Claude has no "lying mode" (it fails loudly), so it carries
# no drop-reason scraper. Session model: caller pre-mints --session-id <UUID>;
# the SAME id is used for --resume.
#
# PRECONDITION: sourced by lib-agent.sh (or a compat shim) AFTER lib-agent.sh's
# shared primitives are defined — adapter_invoke_claude calls _run_with_timeout
# and reads AGENT_PERMISSION_MODE / AGENT_LAUNCHER_ARGV, all owned by
# lib-agent.sh. Adapters never re-source lib-agent.sh (would recurse).

# adapter_invoke_claude <mode> <session_id> <prompt> <model> <session_name>
#   mode ∈ { dev-new, dev-resume }
#
# Prompt-channel contract ([INV-34]): prompt is fed on stdin, never argv.
#
# [#493 R4] --output-format stream-json --verbose (NOT the old single-shot
# --output-format json): one complete JSON record per line, no partial-
# message chunking, so the shared progress recorder (R2/R3, json framing)
# can refresh the lease once per record. --verbose is required alongside
# stream-json (the CLI rejects stream-json without it). The final
# `{"type":"result",...}` record keeps the SAME shape as the old
# single-shot format's sole output object — byte-preserved at column zero
# in the captured log — so the three existing consumers (is_session_completed,
# session-log-probe-remote-aws-ssm.sh, metrics_parse_tokens) keep parsing the
# last such line unmodified. See docs/pipeline/adapter-spec.md.
adapter_invoke_claude() {
  local mode="$1" session_id="$2" prompt="$3" model="${4:-}" session_name="${5:-}"
  local extra_args=()
  if [[ "$mode" == "dev-resume" ]]; then
    _parse_extra_args AGENT_REVIEW_EXTRA_ARGS extra_args
  else
    _parse_extra_args AGENT_DEV_EXTRA_ARGS extra_args
  fi

  # Flag list is identical across both invocation paths — only the
  # command prefix differs (see below). `-p` is the headless flag;
  # claude reads the prompt from stdin when -p has no value. --name is
  # omitted on resume — the session retains the name set at creation.
  local claude_args
  if [[ "$mode" == "dev-resume" ]]; then
    claude_args=(
      --resume "$session_id"
      --permission-mode "$AGENT_PERMISSION_MODE"
      ${model:+--model "$model"}
      "${extra_args[@]}"
      -p
      --output-format stream-json
      --verbose
    )
  else
    claude_args=(
      --session-id "$session_id"
      ${session_name:+--name "$session_name"}
      --permission-mode "$AGENT_PERMISSION_MODE"
      ${model:+--model "$model"}
      "${extra_args[@]}"
      -p
      --output-format stream-json
      --verbose
    )
  fi
  # Two invocation paths:
  #
  # (A) No AGENT_LAUNCHER → wrapper drives claude directly.
  #     `env -u CLAUDECODE` strips a parent-process env var that
  #     would otherwise make claude refuse to start (it treats
  #     CLAUDECODE-set parents as "already inside a Claude session").
  #     Only relevant when an operator runs the wrapper from inside
  #     an interactive claude — dispatcher's nohup path doesn't have it.
  #
  # (B) AGENT_LAUNCHER set → launcher invokes claude itself.
  #     The launcher (e.g. `cc` shell function) ends with
  #     `$CLAUDE_CMD "$@"`, so we pass ONLY flags as "$@" —
  #     NOT the binary name and NOT `env -u`. CLAUDECODE handling is
  #     delegated to the launcher.
  #
  # [#493 R3] The shared progress recorder is appended as a pass-through
  # pipeline stage AFTER _run_with_timeout (never before — the CLI stage's
  # PIPESTATUS index must not shift). It streams stdout unchanged and
  # refreshes the lease once per complete JSON record. Exit status is read
  # from PIPESTATUS[1] (the CLI stage), never the recorder's own (always 0).
  if [[ ${#AGENT_LAUNCHER_ARGV[@]} -gt 0 ]]; then
    printf '%s' "$prompt" | _run_with_timeout "${claude_args[@]}" | _agent_progress_recorder json
  else
    printf '%s' "$prompt" | _run_with_timeout env -u CLAUDECODE "$AGENT_CMD" "${claude_args[@]}" | _agent_progress_recorder json
  fi
  return "${PIPESTATUS[1]}"
}
