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
      [[ "$now" -ge "$t_deadline" ]] && return 2
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
        [[ "$now" -ge "$t_deadline" ]] && {
          echo "[lib-ssm] WARN: poll-loop timeout (status=$status)" >&2
          return 2
        }
        continue
        ;;
      *)
        echo "[lib-ssm] WARN: unexpected Status=$status" >&2
        return 2
        ;;
    esac
  done
}
