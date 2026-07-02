#!/bin/bash
# adapters/agy.sh — Antigravity 2.0 (agy) CLI adapter ([INV-75]).
#
# All agy-specific behavior lives here:
#   - argv assembly (dev-new / dev-resume), with the load-bearing structural
#     flags (-p, --dangerously-skip-permissions, --print-timeout, --log-file);
#   - --model validation against `agy models` (INV-50) — agy accepts ANY string
#     at rc 0 and silently falls back to its default, so we validate wrapper-side;
#   - conversation-UUID capture/recall via the --log-file grep channel (INV-36);
#   - the quota/auth drop-reason detector (INV-58, formerly lib-review-agy.sh).
#
# Session model: agy mints conversation UUIDs internally and exposes them only
# via the CLI log file (no JSON event stream). We direct the log to a per-session
# path with --log-file, grep the UUID into a sidecar, and feed it back via
# --conversation <UUID> on resume.
#
# PRECONDITION: sourced by lib-agent.sh (dispatch + sidecar helpers) and by the
# lib-review-agy.sh compat shim + lib-agent-smoke.sh (drop-reason fns), AFTER
# lib-agent.sh's shared primitives (_run_with_timeout, pid_dir_for_project,
# _parse_extra_args) are defined.

# adapter_invoke_agy <mode> <session_id> <prompt> <model> <session_name>
#   mode ∈ { dev-new, dev-resume }
adapter_invoke_agy() {
  local mode="$1" session_id="$2" prompt="$3" model="${4:-}" session_name="${5:-}"

  # On dev-resume with NO captured conversation UUID (run_agent never ran for this
  # session, or capture failed per INV-36), fall back to a fresh run — the same
  # defensive pattern the codex/opencode adapters use. Done BEFORE any work so the
  # fresh run re-parses AGENT_DEV_EXTRA_ARGS and re-mints, exactly as the
  # pre-refactor resume_agent agy branch did.
  if [[ "$mode" == "dev-resume" ]] && ! _agy_conversation_id "$session_id" >/dev/null 2>&1; then
    echo "[lib-agent] no captured agy conversation_id for session $session_id; starting a new agy session" >&2
    run_agent "$session_id" "$prompt" "$model" "$session_name"
    return $?
  fi

  local extra_args=()
  if [[ "$mode" == "dev-resume" ]]; then
    _parse_extra_args AGENT_REVIEW_EXTRA_ARGS extra_args
  else
    _parse_extra_args AGENT_DEV_EXTRA_ARGS extra_args
  fi

  # Structural flags (NOT operator-tunable, NOT in EXTRA_ARGS):
  #   -p — headless print mode; reads prompt from stdin per INV-34.
  #   --dangerously-skip-permissions — load-bearing in headless mode; without it
  #     agy denies every tool call (same role as kiro's --trust-all-tools / gemini's
  #     --approval-mode yolo, but hardcoded — there is no valid headless agy config
  #     without it).
  #   --print-timeout "$AGENT_TIMEOUT" — agy's internal cap defaults to 5m, far
  #     below AGENT_TIMEOUT (default 4h). Without override every wrapper dies in 5m.
  #   --log-file — only programmatic channel for the conversation UUID; per-session.
  #
  # `--model` (issue #190, [INV-50]): VALIDATED via _agy_build_model_args →
  # _agy_known_model; forwarded only when known, OMITTED with a one-time WARN
  # otherwise (forwarding an unknown id would smuggle a wrong-model verdict into
  # the INV-40 merge gate). This is the one CLI that does NOT forward --model
  # verbatim. On dev-resume we also feed back the captured UUID via --conversation.
  local agy_model_args
  _agy_build_model_args "$model" agy_model_args

  local agy_log
  agy_log=$(_agy_log_file "$session_id") || return 1

  local conv_flag=()
  if [[ "$mode" == "dev-resume" ]]; then
    # Caller (resume_agent) only routes here when the sidecar UUID exists; read it.
    local _agy_cid
    _agy_cid=$(_agy_conversation_id "$session_id") || return 1
    conv_flag=(--conversation "$_agy_cid")
  fi

  printf '%s' "$prompt" \
    | _run_with_timeout "$AGENT_CMD" \
        "${conv_flag[@]}" \
        -p \
        --dangerously-skip-permissions \
        --print-timeout "$AGENT_TIMEOUT" \
        --log-file "$agy_log" \
        "${agy_model_args[@]}" \
        "${extra_args[@]}"
  local rc=$?

  # Self-healing re-capture: on dev-new this captures the freshly-minted UUID; on
  # dev-resume it is a no-op overwrite under normal operation (agy keeps the id),
  # but tracks a future rotated id without code change.
  _agy_capture_conversation "$session_id" "$agy_log"

  return $rc
}

# ---------------------------------------------------------------------------
# Sidecar paths + capture/recall (INV-36) — relocated verbatim from lib-agent.sh.
# ---------------------------------------------------------------------------

# _agy_log_file <session_id> / _agy_conversation_file <session_id>
#
# Sidecar paths under pid_dir_for_project(). Two files: the log is mostly noise
# and is not the canonical UUID store — only the sidecar is.
_agy_log_file() {
  local session_id="$1" pid_dir
  pid_dir=$(pid_dir_for_project) || return 1
  printf '%s/agy-log-%s.log\n' "$pid_dir" "$session_id"
}

_agy_conversation_file() {
  local session_id="$1" pid_dir
  pid_dir=$(pid_dir_for_project) || return 1
  printf '%s/agy-conversation-%s\n' "$pid_dir" "$session_id"
}

# _agy_capture_conversation <session_id> <log_file>
#
# Best-effort capture per [INV-36]: grep the log_file for
#   Print mode: conversation=<UUID>
# and write the UUID to the sidecar. Always returns 0 — capture failure must not
# gate run_agent's exit code (resume falls back to a fresh run when absent).
# CWE-59 defense via [[ -L ]]. UUID shape anchored to canonical RFC-4122 form so
# a future log-format change never writes garbage that survives the read-side.
_agy_capture_conversation() {
  local session_id="$1" log_file="$2" conv_file uuid
  conv_file=$(_agy_conversation_file "$session_id") || return 0
  [[ -f "$log_file" ]] || return 0
  uuid=$(grep -oE 'Print mode: conversation=[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}' "$log_file" \
    | head -1 | sed 's/.*=//')
  [[ -n "$uuid" ]] || return 0
  if [[ -L "$conv_file" ]]; then
    echo "[lib-agent] WARN: $conv_file is a symlink; refusing to write." >&2
    return 0
  fi
  # Trailing return 0: the printf may fail (read-only fs, full disk, etc.);
  # INV-36 promises capture is best-effort, so swallow the rc.
  printf '%s\n' "$uuid" > "$conv_file" || true
  return 0
}

# _agy_conversation_id <session_id>
#
# Read the captured UUID. Missing/malformed sidecar returns rc 1 so resume_agent
# can detect it and fall back to a fresh run_agent. `cat` (not `head -n1`) so
# multi-line content fails the UUID-shape check rather than masking corruption.
_agy_conversation_id() {
  local session_id="$1" conv_file uuid
  conv_file=$(_agy_conversation_file "$session_id") || return 1
  [[ -L "$conv_file" ]] && return 1
  [[ -f "$conv_file" ]] || return 1
  uuid=$(cat "$conv_file" 2>/dev/null)
  [[ "$uuid" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$ ]] || return 1
  printf '%s\n' "$uuid"
}

# ---------------------------------------------------------------------------
# --model validation (INV-50) — relocated verbatim from lib-agent.sh.
# ---------------------------------------------------------------------------

# _agy_known_model <model>
#
# Answer "is <model> a name `agy models` lists?". Enumerates `agy models` ONCE
# per process (cached in the exported global _LIB_AGENT_AGY_MODELS_CACHE) and
# matches FIXED-STRING, WHOLE-LINE (grep -Fxq). Returns:
#   0 — known (forward it)   1 — enumerated but not in list (omit + WARN)
#   2 — enumeration failed (best-effort: forward anyway)
_agy_known_model() {
  local model="$1"
  [[ -n "$model" ]] || return 1
  if [[ -z "${_LIB_AGENT_AGY_MODELS_CACHE:-}" ]]; then
    local listing
    if listing=$("${AGENT_CMD:-agy}" models 2>/dev/null) && [[ -n "$listing" ]]; then
      _LIB_AGENT_AGY_MODELS_CACHE="$listing"
    else
      # \x01-wrapped sentinel: readable in logs yet un-typeable, so no real
      # `agy models` line can ever collide with it (a plaintext sentinel could).
      _LIB_AGENT_AGY_MODELS_CACHE=$'\x01__ENUM_FAILED__\x01'
    fi
    export _LIB_AGENT_AGY_MODELS_CACHE
  fi
  [[ "$_LIB_AGENT_AGY_MODELS_CACHE" == $'\x01__ENUM_FAILED__\x01' ]] && return 2  # can't validate
  # Strip the whole control-char class (notably newline AND carriage return)
  # before the grep -Fxq check: a newline would split into separate fixed-string
  # patterns and an \r could whole-line-match a CRLF listing — both bypass
  # validation. Mirrors the INV-60 [[:cntrl:]] guard in post-verdict.sh so the
  # two model sites agree.
  model="${model//[[:cntrl:]]/}"
  printf '%s\n' "$_LIB_AGENT_AGY_MODELS_CACHE" | grep -Fxq -- "$model"
}

# _agy_build_model_args <model> <out_array_name>
#
# Populate the named array with the agy `--model` argv (or leave it empty),
# applying [INV-50] validation. Resolution:
#   known / enum-failed    → (--model "$model")   # forward / best-effort
#   enumerated-but-unknown → ()  + one-time WARN   # omit; agy uses its default
#   empty/unset model      → ()
_agy_build_model_args() {
  local model="$1" out_name="$2"
  # Strip the whole control-char class (notably newline AND carriage return)
  # up-front so the SAME sanitized value is both validated and forwarded.
  # _agy_known_model also strips for the grep check, but it operates on its own
  # local copy — without this, a value that validates (e.g. a known name with a
  # trailing newline OR \r) would still forward the raw control char as the
  # --model arg. Must use the SAME [[:cntrl:]] class as _agy_known_model (and the
  # INV-60 guard in post-verdict.sh), or a \r would validate yet leak to agy's
  # --model.
  model="${model//[[:cntrl:]]/}"
  eval "$out_name=()"
  [[ -n "$model" ]] || return 0
  _agy_known_model "$model"
  case $? in
    0|2) # Known model or enumeration failed → forward. eval is needed to assign
         # to the dynamically-named caller array; the inner \"\$model\" keeps a
         # multi-word name (e.g. "Gemini 3.5 Flash (High)") as ONE argv element.
      eval "$out_name=(--model \"\$model\")" ;;
    *)   # enumerated, model not in the list → skip + warn once.
      if [[ -z "${_LIB_AGENT_AGY_MODEL_WARNED:-}" ]]; then
        echo "[lib-agent] WARN: '${model}' is not a known agy model (see \`agy models\`); omitting --model so agy uses its configured default. Set an agy-namespace model (e.g. AGENT_REVIEW_MODEL_AGY=\"Gemini 3.5 Flash (High)\") to pin one." >&2
        export _LIB_AGENT_AGY_MODEL_WARNED=1
      fi ;;
  esac
}

# ---------------------------------------------------------------------------
# Drop-reason detector (INV-58) — relocated verbatim from lib-review-agy.sh.
#
# agy hits the quota wall (429 RESOURCE_EXHAUSTED / "Individual quota reached")
# or an auth failure and exits rc 0 with EMPTY stdout, posting no verdict — the
# wrapper would otherwise resolve a bare `unavailable`. The signal lives only in
# agy's OWN --log-file. Observability-only: a quota/auth agy is STILL dropped from
# the INV-40 vote exactly as `unavailable`; this surfaces a distinct reason (+ the
# "Resets in <dur>" window).
# ---------------------------------------------------------------------------

# _classify_agy_drop_reason <log_file>
#
# Echoes ONE token (rc 0 always; fail-safe under set -euo pipefail):
#   quota-exhausted[:Resets in <dur>] — 429 / quota signal (precedence over auth).
#   auth-failed                       — auth/login signal with NO quota signal.
#   "" (empty)                        — neither (caller keeps bare `unavailable`).
# Fixed-substring (grep -F) so a metachar in the log can never break the scan.
_classify_agy_drop_reason() {
  local log_file="${1:-}"
  [[ -n "$log_file" && -f "$log_file" && -r "$log_file" ]] || return 0

  if grep -qF 'RESOURCE_EXHAUSTED' "$log_file" 2>/dev/null \
     || grep -qF 'Individual quota reached' "$log_file" 2>/dev/null; then
    local reset
    reset=$(grep -oE 'Resets in [0-9]+[hms]([0-9]+[hms])*' "$log_file" 2>/dev/null | head -1)
    if [[ -n "$reset" ]]; then
      printf 'quota-exhausted:%s\n' "$reset"
    else
      printf 'quota-exhausted\n'
    fi
    return 0
  fi

  if grep -qF 'not logged into Antigravity' "$log_file" 2>/dev/null \
     || grep -qF 'Failed to get OAuth token' "$log_file" 2>/dev/null; then
    printf 'auth-failed\n'
    return 0
  fi

  return 0
}

# _agy_drop_reason_phrase <reason-token>
#
# Render a token into a single human-facing clause (rc 0 always). Empty for an
# empty/unknown token.
_agy_drop_reason_phrase() {
  local token="${1:-}"
  case "$token" in
    quota-exhausted:*)
      local window="${token#quota-exhausted:}"
      printf 'quota-exhausted (Antigravity 429: daily quota reached; %s)\n' \
        "$(printf '%s' "$window" | sed 's/^Resets in /resets in /')"
      ;;
    quota-exhausted)
      printf 'quota-exhausted (Antigravity 429: daily quota reached)\n'
      ;;
    auth-failed)
      printf 'auth-failed (agy not logged into Antigravity / OAuth token unavailable)\n'
      ;;
    *)
      # Empty or unknown token → empty phrase.
      ;;
  esac
  return 0
}
