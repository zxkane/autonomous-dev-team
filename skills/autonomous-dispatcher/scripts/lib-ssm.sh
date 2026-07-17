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
#                                 default 600s, AND is passed as the
#                                 AWS-RunShellScript document's own
#                                 `executionTimeout` parameter (round-3
#                                 review finding #1 — see below for why).
#   REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS — wall-clock cap on the
#                                 dispatcher-side polling loop
#                                 (default 8). Protects the dispatcher
#                                 tick from a stuck InProgress.
#
# Stdout: on Success, prints the remote command's StandardOutputContent
# (stripped of trailing newline); on any other path, stdout is empty.
#
# Poll-timeout handling (agent-progress-snapshot-remote-aws-ssm.sh review
# finding #2, hardened per round-2 finding #1, hardened AGAIN per round-3
# finding #1): REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS (default 8) is far
# shorter than SSM_COMMAND_TIMEOUT_SECONDS (default 30) — the remote
# command can still be executing when this helper's poll loop gives up.
# For a read-only snapshot that's harmless, but the SAME helper also
# drives agent-progress-snapshot-remote-aws-ssm.sh's --compare-and-signal
# mode, whose remote script ends in `kill -TERM`. A caller that treats a
# bare poll-loop timeout as "no signal was sent" (rc=2 -> ABORTED) can be
# wrong: the remote command can still complete — and send the signal —
# AFTER this helper has already returned indeterminate, leaving no
# handoff comment and no label transition even though the wrapper was, in
# fact, killed.
#
# Round-3 finding #1's root cause: `--timeout-seconds` on send-command
# only bounds DELIVERY ("if this time is reached and the command hasn't
# already started running, it won't run" — AWS API reference) — it does
# NOT bound execution time once the command has started. The actual
# execution-time bound is the AWS-RunShellScript document's OWN
# `executionTimeout` parameter, which defaults to 3600 (1 hour) when left
# unset, as it always has been here. So a "still InProgress" command was
# never actually guaranteed to reach a terminal state within
# SSM_COMMAND_TIMEOUT_SECONDS at all — it could legitimately run, and
# reach its `kill -TERM` line, up to an hour later. `_ssm_run_remote_command`
# below now explicitly passes `executionTimeout=$cmd_timeout` so the
# document's real execution bound matches the timeout this helper's own
# polling logic already assumes.
#
# With that bound now real, this helper on timeout (1) best-effort issues
# `aws ssm cancel-command` — for a still-InProgress AWS-RunShellScript
# invocation, SSM Agent attempts to terminate the running script process,
# which stops it BEFORE it reaches a not-yet-executed `kill -TERM` line
# (it cannot retroactively undo a signal already sent, but that residual
# race is unavoidable in any cooperative-cancel design and is no worse
# than doing nothing) — then (2) POLLS get-command-invocation, giving up
# only once
# `cmd_sent_at + cmd_timeout + exec_timeout + REMOTE_POLL_TIMEOUT_RECOVER_SECONDS`
# (default margin 5s) has elapsed — i.e. not before AWS's OWN
# executionTimeout enforcement guarantees the command has been forced to
# a terminal state, plus a small buffer for `cancel-command`'s own
# asynchronicity (it only REQUESTS the stop; SSM Agent needs a moment to
# actually act on it, so a read taken immediately after issuing it can
# still observe a stale InProgress/Pending status even though the command
# is moments from Cancelled/Success/Failed) and for get-command-invocation
# poll granularity. Giving up any earlier than that anchored deadline would
# report ABORTED/indeterminate while the remote command — and, for
# --compare-and-signal, its `kill -TERM` — is STILL, PROVABLY, capable of
# executing. Only after the anchored deadline elapses without observing a
# terminal status does this helper fall back to indeterminate — at which
# point the command is guaranteed (by AWS's own enforcement) to be
# terminal, so "indeterminate" now only ever means "we could not read the
# outcome," never "we gave up while it might still be running."
#
# Round-4 finding #1's root cause: `cmd_timeout` (send-command's
# --timeout-seconds) bounds how long the command may sit `Pending` before
# it starts; `exec_timeout` (the document's `executionTimeout`) only
# starts counting once the command actually starts running. A command
# that sits at the DELIVERY deadline before starting, then runs for the
# full `exec_timeout`, is not guaranteed terminal until
# `cmd_sent_at + cmd_timeout + exec_timeout` — anchoring the recovery
# deadline to `cmd_sent_at + exec_timeout` alone (dropping the delivery
# window) could give up while a command that started late is still able
# to reach its `kill -TERM` line. The deadline below adds BOTH bounds.
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
  # AWS-RunShellScript's `executionTimeout` document parameter allows
  # 1-172800; clamp so an operator-inflated SSM_COMMAND_TIMEOUT_SECONDS
  # (send-command's own --timeout-seconds accepts up to 2592000) can never
  # produce a ParamValidation rejection on this second, document-level use.
  local exec_timeout="$cmd_timeout"
  [[ "$exec_timeout" -gt 172800 ]] && exec_timeout=172800

  # Build commands+executionTimeout JSON safely via jq -n --arg (CWE-78).
  # executionTimeout is set explicitly (round-3 review finding #1): AWS's
  # send-command --timeout-seconds only bounds DELIVERY ("if this time is
  # reached and the command hasn't already started running, it won't
  # run" — it does NOT bound execution time once started); leaving it
  # unset defaults the document's real execution-time bound to 3600s,
  # regardless of $cmd_timeout — see this function's docstring above for
  # why _ssm_poll_timeout_recover needs that bound to actually equal
  # $cmd_timeout for its own deadline math to be sound.
  local commands_json params_json
  commands_json=$(jq -n --arg cmd "$inner_cmd" '[$cmd]') || return 2
  params_json=$(jq -n --argjson commands "$commands_json" --arg et "$exec_timeout" \
    '{commands: $commands, executionTimeout: [$et]}') || return 2

  local send_out command_id
  send_out=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --region "$region" \
    --timeout-seconds "$cmd_timeout" \
    --parameters "$params_json" \
    --output json 2>/dev/null) || {
    echo "[lib-ssm] WARN: send-command failed (instance=$instance_id region=$region)" >&2
    return 2
  }

  command_id=$(printf '%s' "$send_out" | jq -r '.Command.CommandId // empty')
  if [[ -z "$command_id" ]]; then
    echo "[lib-ssm] WARN: send-command returned no CommandId" >&2
    return 2
  fi

  # Poll loop with wall-clock cap. cmd_sent_at anchors BOTH this loop's
  # deadline and (on timeout) the recovery loop's deadline in
  # _ssm_poll_timeout_recover, which needs the ORIGINAL send time PLUS
  # BOTH cmd_timeout (send-command's --timeout-seconds, which bounds how
  # long the command may sit Pending/delayed before it starts) AND
  # exec_timeout (the document's own executionTimeout, which only starts
  # counting once the command actually starts running) — round-4 review
  # finding #1: anchoring to exec_timeout alone would drop the delivery
  # window, so a command that started right at the delivery deadline and
  # then ran for the full exec_timeout would not yet be guaranteed
  # terminal at the old (shorter) deadline.
  local cmd_sent_at t_deadline now status get_out stdout_content
  cmd_sent_at=$(date +%s) || cmd_sent_at=""
  if ! [[ "$cmd_sent_at" =~ ^[0-9]+$ ]]; then
    # A failed/garbage `date +%s` here is not a bare cosmetic bug: under
    # `set -u`, an EMPTY (not unset) cmd_sent_at silently evaluates as 0 in
    # arithmetic rather than erroring, which would collapse BOTH this
    # loop's deadline and (worse) _ssm_poll_timeout_recover's anchored
    # deadline to an epoch in the distant past — the very race this fix
    # exists to close would reopen on the very first poll. Fail loudly
    # instead of proceeding with a corrupted anchor.
    echo "[lib-ssm] ERROR: date +%s failed while anchoring the poll deadline" >&2
    return 2
  fi
  t_deadline=$(( cmd_sent_at + poll_timeout ))
  while :; do
    sleep 0.5
    get_out=$(aws ssm get-command-invocation \
      --instance-id "$instance_id" \
      --region "$region" \
      --command-id "$command_id" \
      --output json 2>/dev/null) || {
      now=$(date +%s)
      [[ "$now" -ge "$t_deadline" ]] && { _ssm_poll_timeout_recover "$instance_id" "$region" "$command_id" "$cmd_sent_at" "$cmd_timeout" "$exec_timeout"; return $?; }
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
        [[ "$now" -ge "$t_deadline" ]] && { _ssm_poll_timeout_recover "$instance_id" "$region" "$command_id" "$cmd_sent_at" "$cmd_timeout" "$exec_timeout"; return $?; }
        continue
        ;;
      *)
        echo "[lib-ssm] WARN: unexpected Status=$status" >&2
        return 2
        ;;
    esac
  done
}

# _ssm_poll_timeout_recover <instance-id> <region> <command_id> <cmd_sent_at> <cmd_timeout> <exec_timeout>
#
# Called ONLY when _ssm_run_remote_command's dispatcher-side poll loop
# (REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS, default 8) has hit its deadline
# while the remote command may still be executing. Best-effort
# `cancel-command` first (stops an AWS-RunShellScript invocation that is
# still InProgress — for --compare-and-signal, this prevents a delayed
# remote script from reaching its not-yet-executed `kill -TERM` line
# after the caller has already been told "indeterminate"; it cannot undo
# a signal already sent, which remains a documented residual), THEN polls
# get-command-invocation, giving up only once
# `<cmd_sent_at> + <cmd_timeout> + <exec_timeout> + REMOTE_POLL_TIMEOUT_RECOVER_SECONDS`
# (default margin 5s) has elapsed (round-4 review finding #1 — hardened
# from round-3's `cmd_sent_at + exec_timeout` anchor, which omitted the
# DELIVERY window: `cmd_timeout` — send-command's own `--timeout-seconds`
# — bounds how long the command may sit Pending/Delayed before it starts
# running at all; `exec_timeout` — the AWS-RunShellScript document's
# `executionTimeout` — only starts counting once the command actually
# starts. A command that sits at the delivery deadline before starting,
# then runs for the full exec_timeout, is not guaranteed terminal until
# `cmd_sent_at + cmd_timeout + exec_timeout` — anchoring to `exec_timeout`
# alone could give up while such a late-starting command is still able to
# reach its `kill -TERM` line). Anchoring to the sum of BOTH bounds means
# AWS's OWN enforcement guarantees a terminal status by that deadline, so
# giving up there (never earlier) can no longer race a command that might
# still be running. `cancel-command` only REQUESTS that SSM Agent stop the
# running script — it does not confirm the stop synchronously, so a read
# taken immediately after issuing it can still observe a stale
# InProgress/Pending status even though the command is moments from
# reaching Cancelled (the stop won), Success, or Failed (the command
# finished first); the small REMOTE_POLL_TIMEOUT_RECOVER_SECONDS margin
# absorbs that plus get-command-invocation poll granularity.
#
# Stdout: on Success, prints StandardOutputContent (stripped of trailing
# newline), same contract as the main poll loop; empty on any other path.
# Returns 0 (Success confirmed) or 2 (still indeterminate after recovery
# — which by construction only happens once the command is guaranteed
# terminal, so it means "could not read the outcome," never "gave up
# while it might still be running").
_ssm_poll_timeout_recover() {
  local instance_id="$1" region="$2" command_id="$3" cmd_sent_at="$4" cmd_timeout="$5" exec_timeout="$6"
  echo "[lib-ssm] WARN: poll-loop timeout — attempting cancel-command + bounded recovery poll" >&2
  # Best-effort only: cancel-command failing (already completed, already
  # cancelled, transport blip) does not change what we do next — the
  # recovery poll below is what actually decides the return value, so a
  # swallowed cancel failure is safe either way.
  aws ssm cancel-command \
    --command-id "$command_id" \
    --instance-ids "$instance_id" \
    --region "$region" >/dev/null 2>&1 || true  # best-effort; outcome decided below regardless

  local recover_margin="${REMOTE_POLL_TIMEOUT_RECOVER_SECONDS:-5}"
  [[ "$recover_margin" =~ ^[0-9]+$ ]] || recover_margin=5
  # cmd_sent_at/cmd_timeout/exec_timeout are the caller's anchors this
  # whole recovery deadline depends on — under `set -u`, an EMPTY (not
  # unset) value silently evaluates as 0 in arithmetic rather than
  # erroring, which would collapse recover_deadline toward cmd_sent_at (or
  # near-zero if all are empty) and reopen exactly the race this fix
  # closes. Validate rather than let bad args silently corrupt the
  # deadline.
  if ! [[ "$cmd_sent_at" =~ ^[0-9]+$ ]] || ! [[ "$cmd_timeout" =~ ^[0-9]+$ ]] || ! [[ "$exec_timeout" =~ ^[0-9]+$ ]]; then
    echo "[lib-ssm] ERROR: _ssm_poll_timeout_recover called with invalid cmd_sent_at/cmd_timeout/exec_timeout ('$cmd_sent_at'/'$cmd_timeout'/'$exec_timeout')" >&2
    return 2
  fi
  local recover_deadline
  recover_deadline=$(( cmd_sent_at + cmd_timeout + exec_timeout + recover_margin ))

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
      echo "[lib-ssm] WARN: post-cancel recovery window elapsed with no terminal status (AWS's own delivery timeout + executionTimeout guarantee the command is terminal by now) — remaining indeterminate" >&2
      return 2
    fi
    sleep 0.5
  done
}
