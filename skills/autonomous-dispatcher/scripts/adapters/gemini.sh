#!/bin/bash
# adapters/gemini.sh — Gemini CLI adapter ([INV-75]).
#
# Session model: caller pre-mints --session-id <UUID>; the SAME id round-trips
# via the stream-json `init` event and is reused for --resume (claude-style
# replay, no sidecar). Empirically verified against gemini CLI 0.42.0 (#134).
#
# The load-bearing `--approval-mode yolo --output-format stream-json` flags are
# operator-tunable via AGENT_DEV_EXTRA_ARGS / AGENT_REVIEW_EXTRA_ARGS (NOT
# hardcoded here) — see autonomous.conf.example "gemini block". Without them
# gemini silently fabricates success (#102/#134). Lying mode is absorbed by the
# env precondition (spec §7), so gemini carries no drop-reason scraper.
#
# PRECONDITION: sourced by lib-agent.sh AFTER its shared primitives.

# adapter_invoke_gemini <mode> <session_id> <prompt> <model> <session_name>
#   mode ∈ { dev-new, dev-resume }
adapter_invoke_gemini() {
  local mode="$1" session_id="$2" prompt="$3" model="${4:-}" session_name="${5:-}"
  local extra_args=()
  if [[ "$mode" == "dev-resume" ]]; then
    _parse_extra_args AGENT_REVIEW_EXTRA_ARGS extra_args
  else
    _parse_extra_args AGENT_DEV_EXTRA_ARGS extra_args
  fi

  # Gemini CLI: headless invocation per https://geminicli.com/docs/cli/headless/.
  # `-p` with no value reads the prompt from stdin.
  #
  # dev-new uses `--session-id <UUID>` (round-trips); dev-resume uses
  # `--resume <UUID>` to replay the conversation history. If the original run
  # never happened (operator-initiated resume on a fresh issue), gemini still
  # starts cleanly — safer than kiro's fresh-run fallback.
  local sid_flag
  if [[ "$mode" == "dev-resume" ]]; then
    sid_flag=(--resume "$session_id")
  else
    sid_flag=(--session-id "$session_id")
  fi

  # [#493 R3] Framing selection: the operator-tunable extra_args (see file
  # header) may or may not select `stream-json` output. When it does, gemini
  # emits one JSON object per line — same json framing as claude/codex/
  # opencode. When it doesn't (or the operator hasn't set the load-bearing
  # flags at all, the #102/#134 misconfiguration case), gemini's output is
  # plain text lines — line framing, same as agy/kiro/the generic fallback.
  # Scanned on the resolved extra_args array, not the raw env var, so this
  # tracks whatever actually reaches the CLI's argv. Matches BOTH argv forms
  # a shell-arg CLI can accept: the two-token form (`--output-format
  # stream-json`, caught by the bare "stream-json" element) and the
  # equals-joined single-token form (`--output-format=stream-json`) — round-2
  # review finding: the equals form was previously invisible to this scan, so
  # a truncated JSONL record from an equals-configured gemini would refresh
  # the lease as a plain "nonempty line" instead of being held to the
  # complete-record json framing rule.
  local _framing="line"
  local _a
  for _a in "${extra_args[@]}"; do
    if [[ "$_a" == "stream-json" || "$_a" == "--output-format=stream-json" ]]; then
      _framing="json"
      break
    fi
  done

  printf '%s' "$prompt" | _run_with_timeout "$AGENT_CMD" \
    "${sid_flag[@]}" \
    ${model:+--model "$model"} \
    "${extra_args[@]}" \
    -p \
    | _agent_progress_recorder "$_framing"
  return "${PIPESTATUS[1]}"
}
