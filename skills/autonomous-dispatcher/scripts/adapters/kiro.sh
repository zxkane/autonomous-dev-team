#!/bin/bash
# adapters/kiro.sh — Kiro CLI adapter ([INV-75]).
#
# All kiro-specific behavior lives here: argv assembly (dev-new; dev-resume
# falls back to a fresh session — kiro has no usable resume) and the
# auth/login-failure drop-reason detector (INV-61, formerly lib-review-kiro.sh).
#
# Session model: NONE. Every invocation is a fresh conversation in the current
# directory; session_id is ignored. resume_agent falls back to run_agent.
#
# The load-bearing `--trust-all-tools` flag is operator-tunable via
# AGENT_DEV_EXTRA_ARGS / AGENT_REVIEW_EXTRA_ARGS (NOT hardcoded) — without it
# stock kiro denies every tool in --no-interactive and fabricates success at
# exit 0 (#102 R5). See autonomous.conf.example "kiro block".
#
# Binary name: `kiro-cli` (not `kiro`); the adapter id is `kiro`.
#
# PRECONDITION: sourced by lib-agent.sh (dispatch) and by the lib-review-kiro.sh
# compat shim + lib-agent-smoke.sh (drop-reason fns), AFTER lib-agent.sh's
# shared primitives are defined.

# adapter_binary_kiro — the executable run_agent/resume_agent actually exec for
# kiro is `kiro-cli`, not `kiro` (the adapter id). The preflight + launch path
# read this convention (lib-agent.sh::_agent_launch_binary) so the one binary
# alias lives in the adapter, not in an orchestration-core case branch ([INV-75]).
adapter_binary_kiro() { printf 'kiro-cli\n'; }

# adapter_invoke_kiro <mode> <session_id> <prompt> <model> <session_name>
#   mode ∈ { dev-new, dev-resume }  (dev-resume is identical to dev-new — kiro
#   has no resume; the caller's resume_agent already routes here.)
adapter_invoke_kiro() {
  local prompt="$3" model="${4:-}"
  # Kiro has NO usable resume: dev-resume is a fresh conversation, identical to
  # dev-new. The pre-refactor resume_agent kiro branch fell back to run_agent,
  # which reads AGENT_DEV_EXTRA_ARGS — so BOTH modes read AGENT_DEV_EXTRA_ARGS
  # (NOT the review var) to preserve that documented fall-through (TC-KIR-003).
  local extra_args=()
  _parse_extra_args AGENT_DEV_EXTRA_ARGS extra_args

  # Stdin marker: `kiro chat --no-interactive` with no positional message reads
  # the prompt from stdin. --agent ensures the workspace agent (with TDD hooks)
  # is used.
  local kiro_args=(
    chat
    --agent "$KIRO_AGENT_NAME"
    --no-interactive
    ${model:+--model "$model"}
    "${extra_args[@]}"
  )
  # [#493 R3] line framing (no JSON event stream). Recorder appended AFTER
  # _run_with_timeout; PIPESTATUS[1] (printf is [0]) holds kiro's own rc.
  printf '%s' "$prompt" | _run_with_timeout kiro-cli "${kiro_args[@]}" | _agent_progress_recorder line
  local -a pipeline_statuses=("${PIPESTATUS[@]}")
  _agent_pipeline_result pipeline_statuses 1
  return $?
}

# ---------------------------------------------------------------------------
# Drop-reason detector (INV-61) — relocated verbatim from lib-review-kiro.sh.
#
# When the `kiro` member of a review fan-out has an EXPIRED OAuth/login token on
# the execution host, the CLI tries to open a browser for device-flow re-auth;
# in a headless shell that fails, kiro exits at LAUNCH with no verdict, and the
# wrapper would otherwise resolve a bare `unavailable`. The signal lives in
# kiro's GENERIC per-agent log (NOT a separate --log-file like agy):
#
#   Failed to open browser for authentication.
#   Please try again with: kiro-cli login --use-device-flow
#   error: Failed to open URL
#
# This is observability-only: an auth-failed kiro is STILL dropped from the
# INV-40 vote exactly as `unavailable`; the classification just surfaces a
# distinct, actionable reason (an expired token is infra, not a code rejection).
# ---------------------------------------------------------------------------

# _classify_kiro_drop_reason <log_file>
#
# Scrape a kiro per-agent log for an auth/login failure signal. Echoes ONE token
# (rc 0 ALWAYS — fail-safe under set -euo pipefail):
#   auth-failed — ANY of the fixed substrings below is present.
#   "" (empty)  — no auth signal (caller keeps bare `unavailable`).
# Fixed-substring (grep -F) so a metachar in the log can never break the scan.
_classify_kiro_drop_reason() {
  local log_file="${1:-}"
  [[ -n "$log_file" && -f "$log_file" && -r "$log_file" ]] || return 0

  if grep -q -F \
       -e 'Failed to open browser for authentication' \
       -e 'kiro-cli login' \
       -e '--use-device-flow' \
       -e 'Failed to open URL' \
       "$log_file" 2>/dev/null; then
    printf 'auth-failed\n'
    return 0
  fi

  return 0
}

# _kiro_drop_reason_phrase <reason-token>
#
# Render a token into a single human-facing clause (rc 0 always). Empty for an
# empty/unknown token.
_kiro_drop_reason_phrase() {
  local token="${1:-}"
  case "$token" in
    auth-failed)
      printf 'auth-failed (browser/device-flow login required on the execution host: kiro-cli login --use-device-flow)\n'
      ;;
    *)
      # Empty or unknown token → empty phrase.
      ;;
  esac
  return 0
}
