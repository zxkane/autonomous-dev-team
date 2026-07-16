#!/bin/bash
# lib-ssm.sh — Shared SSM helpers for remote-aws-ssm execution backend
# (#137 Finding 2.A from plan-eng-review).
#
# Two callers:
#   - dispatch-remote-aws-ssm.sh: fire-and-forget spawn transport
#     (uses _has_shell_metachar only; constructs its own send-command
#     argv because it does NOT poll for completion)
#   - liveness-check-remote-aws-ssm.sh: synchronous liveness probe
#     (uses _ssm_run_remote_command which sends + polls)
#
# Both callers must validate operator-controlled values via
# _has_shell_metachar before substituting them into the inner command.
#
# Source guard: idempotent re-source is safe; helpers are pure functions.
# shellcheck shell=bash

# AWS ssm send-command's hard API minimum for --timeout-seconds. Any lower
# value is rejected transport-side with ParamValidation on EVERY call, not
# flakily (#369). Referenced by both defaulting paths in
# _ssm_run_remote_command below so they can't drift apart.
#
# Plain assignment, NOT `: "${VAR:=30}"` — the default-if-unset form lets
# an inherited/exported _SSM_MIN_COMMAND_TIMEOUT_SECONDS from the caller's
# environment (e.g. a stale `export _SSM_MIN_COMMAND_TIMEOUT_SECONDS=20`
# left over from a prior shell) win over the constant, silently recreating
# #369. A plain assignment always resets it to 30 on every source, so it
# is not overridable from the environment, while staying idempotent-safe
# to re-source (unlike `readonly`, which errors on a second assignment).
_SSM_MIN_COMMAND_TIMEOUT_SECONDS=30

# _has_shell_metachar <value>
#
# Returns 0 if <value> contains any of the metachars that can break out
# of the `sudo -u $USER $SHELL -l -c '<INNER_CMD>'` single-quote wrap on
# the remote side and execute arbitrary code as $SSM_REMOTE_USER:
#   $ ` ; & | ' " < > * ? newline carriage-return
#
# Found via PR-9 review (C1+C2): the prior validator missed `'`, `"`,
# `<`, `>`, `\n`, which reach the remote shell verbatim.
#
# Returns 1 if the value is safe to interpolate.
_has_shell_metachar() {
  local val="$1"
  case "$val" in
    *['$`;&|<>*?'\'\"]*) return 0 ;;
    *)                   ;;
  esac
  case "$val" in
    *$'\n'*|*$'\r'*) return 0 ;;
    *) return 1 ;;
  esac
}

# _ssm_build_full_cmd <user> <shell> <inner_cmd>
#
# Builds the `sudo -u $user $shell -l -c '...'` command string sent over
# SSM, WITHOUT ever placing $inner_cmd's literal text inside the outer
# single-quote wrap (#454). $inner_cmd is base64-encoded and decoded +
# `eval`'d remotely instead of being interpolated verbatim — so a
# heredoc body's own comments/strings (English contractions, embedded
# quotes, backticks, anything) can never break the outer quoting no
# matter what characters they contain. This is the STRUCTURAL fix the
# issue asked for: it protects every future edit to a heredoc body, not
# just today's offending apostrophe.
#
# The base64 alphabet is [A-Za-z0-9+/=] only — it cannot itself contain
# a `'`, so the outer single-quote wrap around the `eval "$(printf ...)"`
# expression stays balanced regardless of $inner_cmd's content. $user and
# $shell are still interpolated directly into the outer wrap (as before);
# callers MUST validate them against `^[a-zA-Z0-9_-]+$` /
# `^(bash|zsh|sh)$` first, same as always.
#
# Exit-code / stdout passthrough: `eval "$(...)"` runs $inner_cmd in the
# CURRENT shell (not a subshell), so `exit N` inside $inner_cmd still
# terminates the -c shell with rc=N, and stdout/stderr are unbuffered
# pass-through — the ALIVE/DEAD/DEFERRED contract (INV-30, INV-119) is
# unchanged.
#
# Fail-closed on encoding failure: if `base64` is missing or the encode
# pipeline fails, prints nothing and returns 1 instead of silently emitting
# a FULL_CMD with an empty payload (`eval "$(printf %s  | base64 -d)"`) that
# parses fine, "succeeds" at the transport layer, and executes nothing on
# the remote host — a false-success that's far harder to diagnose than a
# loud local failure. Callers must check the return code.
#
# Fail-closed on the REMOTE decode too (codex review of #454 follow-up):
# the local encoding check above cannot see whether the remote host has
# `base64` on its PATH. If it doesn't, `base64 -d` there fails but a bare
# `eval "$(...)"` swallows that — the failed command substitution expands
# to an empty string, `eval ""` is a silent no-op, and the remote shell (and
# therefore the whole SSM command) still exits 0. The remote script now
# captures the decode into `_d` and `exit 1`s BEFORE `eval` if that capture
# fails, so a missing remote `base64` produces a loud remote failure
# instead of a false SSM "Success" that executed nothing. `$INNER_CMD`'s
# own `exit N` still propagates normally: `eval "$_d"` is the last command
# run only once decode has already succeeded.
_ssm_build_full_cmd() {
  local user="$1" shell="$2" inner_cmd="$3" b64
  b64=$(printf '%s' "$inner_cmd" | base64 | tr -d '\n') || {
    echo "[lib-ssm] ERROR: base64 encoding of inner_cmd failed" >&2
    return 1
  }
  if [[ -z "$b64" && -n "$inner_cmd" ]]; then
    echo "[lib-ssm] ERROR: base64 encoding of inner_cmd produced empty output" >&2
    return 1
  fi
  printf '%s' "sudo -u ${user} ${shell} -l -c '_d=\$(printf %s ${b64} | base64 -d) || exit 1; eval \"\$_d\"'"
}

# _ssm_run_remote_command <instance-id> <region> <inner-cmd>
#
# Synchronous: send-command + poll get-command-invocation until terminal
# Status, print remote stdout, return tri-state:
#   0 — Status: Success; helper printed StandardOutputContent
#   2 — any other terminal Status, transport fault, timeout, or
#       indeterminate result (per INV-30: indeterminate biases the
#       *caller* toward ALIVE; this helper only conveys "I cannot give
#       you a definitive verdict")
#
# Note: rc=1 is reserved for input/env validation by callers (driver
# scripts); this helper itself never returns 1.
#
# Required env (callers should validate first):
#   none — helper trusts its three positional args.
#
# Optional env (with defaults):
#   SSM_COMMAND_TIMEOUT_SECONDS — SSM-side timeout for the remote
#                                 command (default 30 — AWS ssm
#                                 send-command's documented hard API
#                                 minimum for --timeout-seconds; any
#                                 lower value is rejected transport-side
#                                 with ParamValidation, #369). ALSO
#                                 appears as --timeout-seconds in
#                                 send-command argv so a hung remote
#                                 shell can't tie up an SSM slot for the
#                                 default 600s.
#   REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS — wall-clock cap on the
#                                 dispatcher-side polling loop
#                                 (default 8). Protects the dispatcher
#                                 tick from a stuck InProgress.
#
# Stdout: on Success, prints the remote command's StandardOutputContent
# (stripped of trailing newline); on any other path, stdout is empty.
#
# Poll-timeout handling (agent-progress-snapshot-remote-aws-ssm.sh review
# finding #2, then hardened per round-2 finding #1): REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS
# (default 8) is far shorter than SSM_COMMAND_TIMEOUT_SECONDS (default 30)
# — the remote command can still be executing when this helper's poll loop
# gives up. For a read-only snapshot that's harmless, but the SAME helper
# also drives agent-progress-snapshot-remote-aws-ssm.sh's --compare-and-signal
# mode, whose remote script ends in `kill -TERM`. A caller that treats a
# bare poll-loop timeout as "no signal was sent" (rc=2 -> ABORTED) can be
# wrong: the remote command can still complete — and send the signal —
# AFTER this helper has already returned indeterminate, leaving no
# handoff comment and no label transition even though the wrapper was, in
# fact, killed. On timeout this helper now (1) best-effort issues
# `aws ssm cancel-command` — for a still-InProgress AWS-RunShellScript
# invocation, SSM Agent attempts to terminate the running script process,
# which stops it BEFORE it reaches a not-yet-executed `kill -TERM` line
# (it cannot retroactively undo a signal already sent, but that residual
# race is unavoidable in any cooperative-cancel design and is no worse
# than doing nothing) — then (2) POLLS for up to
# REMOTE_POLL_TIMEOUT_RECOVER_SECONDS (default 5) for the command to reach a
# terminal status, rather than accepting a single immediate re-check.
# `cancel-command` is itself asynchronous: SSM Agent needs a moment to
# actually stop the running script, so one snapshot taken right after
# issuing the cancel can still observe a stale InProgress/Pending status
# even though the command is moments from a terminal state either way
# (Cancelled if the stop won the race, or Success/Failed if the command
# finished first). Giving up on that one read would report
# ABORTED/indeterminate while the remote command — and, for
# --compare-and-signal, its `kill -TERM` — is still executing and could
# still complete moments later with no dispatcher-visible outcome. Only
# after the recovery window itself elapses without observing a terminal
# status does this helper fall back to indeterminate.
_ssm_run_remote_command() {
  local instance_id="$1"
  local region="$2"
  local inner_cmd="$3"

  command -v aws >/dev/null 2>&1 || { echo "[lib-ssm] ERROR: aws CLI not found" >&2; return 2; }
  command -v jq  >/dev/null 2>&1 || { echo "[lib-ssm] ERROR: jq not found" >&2;  return 2; }

  local cmd_timeout="${SSM_COMMAND_TIMEOUT_SECONDS:-$_SSM_MIN_COMMAND_TIMEOUT_SECONDS}"
  local poll_timeout="${REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS:-8}"
  [[ "$cmd_timeout"  =~ ^[0-9]+$ ]] || cmd_timeout="$_SSM_MIN_COMMAND_TIMEOUT_SECONDS"
  [[ "$poll_timeout" =~ ^[0-9]+$ ]] || poll_timeout=8

  # Build commands JSON safely via jq -n --arg (CWE-78).
  local commands_json
  commands_json=$(jq -n --arg cmd "$inner_cmd" '[$cmd]') || return 2

  local send_out command_id
  send_out=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --region "$region" \
    --timeout-seconds "$cmd_timeout" \
    --parameters "{\"commands\": $commands_json}" \
    --output json 2>/dev/null) || {
    echo "[lib-ssm] WARN: send-command failed (instance=$instance_id region=$region)" >&2
    return 2
  }

  command_id=$(printf '%s' "$send_out" | jq -r '.Command.CommandId // empty')
  if [[ -z "$command_id" ]]; then
    echo "[lib-ssm] WARN: send-command returned no CommandId" >&2
    return 2
  fi

  # Poll loop with wall-clock cap.
  local t_deadline now status get_out stdout_content
  t_deadline=$(( $(date +%s) + poll_timeout ))
  while :; do
    sleep 0.5
    get_out=$(aws ssm get-command-invocation \
      --instance-id "$instance_id" \
      --region "$region" \
      --command-id "$command_id" \
      --output json 2>/dev/null) || {
      now=$(date +%s)
      [[ "$now" -ge "$t_deadline" ]] && { _ssm_poll_timeout_recover "$instance_id" "$region" "$command_id"; return $?; }
      continue
    }
    status=$(printf '%s' "$get_out" | jq -r '.Status // empty')
    case "$status" in
      Success)
        stdout_content=$(printf '%s' "$get_out" | jq -r '.StandardOutputContent // empty')
        # Strip trailing newline.
        printf '%s' "${stdout_content%$'\n'}"
        return 0
        ;;
      Failed|Cancelled|TimedOut)
        echo "[lib-ssm] WARN: remote command ended with Status=$status" >&2
        return 2
        ;;
      InProgress|Pending|Delayed)
        now=$(date +%s)
        [[ "$now" -ge "$t_deadline" ]] && { _ssm_poll_timeout_recover "$instance_id" "$region" "$command_id"; return $?; }
        continue
        ;;
      *)
        echo "[lib-ssm] WARN: unexpected Status=$status" >&2
        return 2
        ;;
    esac
  done
}

# _ssm_poll_timeout_recover <instance-id> <region> <command_id>
#
# Called ONLY when _ssm_run_remote_command's dispatcher-side poll loop
# (REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS, default 8) has hit its deadline
# while the remote command may still be executing (SSM_COMMAND_TIMEOUT_SECONDS
# gives it up to 30s). Best-effort `cancel-command` first (stops an
# AWS-RunShellScript invocation that is still InProgress — for
# --compare-and-signal, this prevents a delayed remote script from reaching
# its not-yet-executed `kill -TERM` line after the caller has already been
# told "indeterminate"; it cannot undo a signal already sent, which remains
# a documented residual), THEN polls get-command-invocation for up to
# REMOTE_POLL_TIMEOUT_RECOVER_SECONDS (default 5) for a terminal status,
# rather than accepting one immediate check (round-2 review finding #1):
# `cancel-command` only REQUESTS that SSM Agent stop the running script — it
# does not confirm the stop synchronously, so a read taken immediately after
# issuing it can still observe a stale InProgress/Pending status even though
# the command is moments from reaching Cancelled (the stop won), Success, or
# Failed (the command finished first). A single-shot recheck would report
# indeterminate in exactly that gap, silently downgrading a signal that in
# fact was (or is about to be) sent. Polling this window closes that gap the
# same way the main loop's own poll closes the send-to-completion gap.
#
# Stdout: on Success, prints StandardOutputContent (stripped of trailing
# newline), same contract as the main poll loop; empty on any other path.
# Returns 0 (Success confirmed) or 2 (still indeterminate after recovery).
_ssm_poll_timeout_recover() {
  local instance_id="$1" region="$2" command_id="$3"
  echo "[lib-ssm] WARN: poll-loop timeout — attempting cancel-command + bounded recovery poll" >&2
  # Best-effort only: cancel-command failing (already completed, already
  # cancelled, transport blip) does not change what we do next — the
  # recovery poll below is what actually decides the return value, so a
  # swallowed cancel failure is safe either way.
  aws ssm cancel-command \
    --command-id "$command_id" \
    --instance-ids "$instance_id" \
    --region "$region" >/dev/null 2>&1 || true  # best-effort; outcome decided below regardless

  local recover_timeout="${REMOTE_POLL_TIMEOUT_RECOVER_SECONDS:-5}"
  [[ "$recover_timeout" =~ ^[0-9]+$ ]] || recover_timeout=5
  local recover_deadline
  recover_deadline=$(( $(date +%s) + recover_timeout ))

  local get_out status stdout_content now
  while :; do
    get_out=$(aws ssm get-command-invocation \
      --instance-id "$instance_id" \
      --region "$region" \
      --command-id "$command_id" \
      --output json 2>/dev/null) || get_out=""
    status=$(printf '%s' "$get_out" | jq -r '.Status // empty' 2>/dev/null)
    case "$status" in
      Success)
        stdout_content=$(printf '%s' "$get_out" | jq -r '.StandardOutputContent // empty')
        printf '%s' "${stdout_content%$'\n'}"
        return 0
        ;;
      Failed|Cancelled|TimedOut)
        echo "[lib-ssm] WARN: post-cancel recovery observed terminal Status=$status — remaining indeterminate" >&2
        return 2
        ;;
    esac
    now=$(date +%s)
    if [[ "$now" -ge "$recover_deadline" ]]; then
      echo "[lib-ssm] WARN: post-cancel recovery window elapsed with no terminal status — remaining indeterminate" >&2
      return 2
    fi
    sleep 0.5
  done
}
