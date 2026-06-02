#!/bin/bash
# lib-review-poll.sh — INV-43 command-mode-aware verdict-poll budget for the
# review wrapper (issue #172).
#
# The multi-agent review fan-out (INV-40, #166) waits for every agent subshell
# to finish (the `wait "${_fanout_pids[@]}"` join is unbounded by AGENT_TIMEOUT),
# then polls issue comments for each agent's verdict. That poll loop ran a FIXED
# 6 attempts × 5 s = 30 s window. With E2E_MODE=command and a raised
# E2E_COMMAND_TIMEOUT_SECONDS (e.g. 2700 for a container build + verify), a
# review agent that FAITHFULLY runs the full command-mode E2E posts its verdict
# only after tens of minutes; a 30 s poll tail (comment-propagation lag, a
# BOT_LOGIN-empty fallback re-query, or a verdict flushed just before the CLI
# exits) could miss it and resolve that agent `unavailable` — dropping the
# diligent agent from the unanimous-PASS vote while a faster, less-thorough
# sibling becomes the sole decider.
#
# This lib makes the poll budget scale with the E2E it dispatched: when
# E2E_MODE=command the wrapper is willing to wait at least as long as the E2E
# timeout it asked the agent to run. For every other mode the budget is the
# legacy 6 (30 s), so non-command projects are byte-for-byte unchanged.
#
# Extracted here so it can be unit-tested in isolation (mirrors
# lib-review-aggregate.sh / lib-review-resolve.sh), without spawning the wrapper.

# _verdict_poll_floor_attempts — the legacy floor (6 attempts = 30 s). Kept as a
# named constant so the back-compat contract is explicit and greppable.
_VERDICT_POLL_FLOOR_ATTEMPTS=6
# Poll cadence in seconds — must match the `sleep` inside the wrapper's poll
# loop. Used to convert a seconds-budget into an attempt count.
_VERDICT_POLL_INTERVAL_SECONDS=5

# _resolve_verdict_poll_attempts
#
# Echoes the number of 5 s poll attempts the verdict loop should run.
#
#   - E2E_MODE != command  → the legacy floor (6 → 30 s). Byte-for-byte legacy.
#   - E2E_MODE == command  → max(floor, ceil(E2E_COMMAND_TIMEOUT_SECONDS / 5))
#                            so the wrapper waits at least as long as the E2E it
#                            dispatched. A non-numeric / zero / unset timeout
#                            falls back to the floor (defensive — never below 6,
#                            never crash the wrapper on a malformed value).
#
# Reads E2E_MODE and E2E_COMMAND_TIMEOUT_SECONDS from the environment (both are
# set by autonomous.conf). Pure: no side effects, no I/O.
#
# Note: the wrapper's poll loop short-circuits as soon as every agent has either
# a verdict comment OR a known non-zero launch rc (an exited CLI won't post a
# verdict). So the extended budget only EXTENDS the wait for an agent that is
# launched-clean-but-verdict-not-yet — exactly the diligent agent this fixes.
# The happy path (all verdicts already posted) still settles in one round.
_resolve_verdict_poll_attempts() {
  local mode="${E2E_MODE:-none}"
  local floor="${_VERDICT_POLL_FLOOR_ATTEMPTS:-6}"
  local interval="${_VERDICT_POLL_INTERVAL_SECONDS:-5}"

  if [[ "$mode" != "command" ]]; then
    printf '%s\n' "$floor"
    return 0
  fi

  # Command-mode default mirrors the wrapper's own `:-3600` for the E2E timeout.
  local timeout="${E2E_COMMAND_TIMEOUT_SECONDS:-3600}"
  # Defensive: non-numeric or zero → legacy floor (no crash, no below-floor).
  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [[ "$timeout" -le 0 ]]; then
    printf '%s\n' "$floor"
    return 0
  fi

  # ceil(timeout / interval): integer division rounding up.
  local attempts=$(( (timeout + interval - 1) / interval ))
  # Never below the legacy floor.
  if [[ "$attempts" -lt "$floor" ]]; then
    attempts="$floor"
  fi
  printf '%s\n' "$attempts"
}

# _reap_fanout_processes <pgid...> — INV-43 (#172): group-kill any still-running
# fan-out agent process group so a dropped / undecided review agent's CLI does
# not outlive its review round (the orphaned-process side effect #172 reports).
#
# What it kills — the AGENT'S PGID, NOT the fan-out subshell PID. The review
# wrapper backgrounds each agent in a plain `( … ) &` subshell; with NO job
# control (`set -m` is never enabled), that subshell does NOT get its own
# process group — it stays in the wrapper's group, so its PID is NOT a
# process-group leader (the same reason `kill -- -$$` is a no-op; see INV-23).
# The real session/group leader is the `setsid`-spawned agent, whose PID == PGID
# is captured in `lib-agent.sh::_run_with_timeout`'s `_AGENT_RUN_PID` and written
# to a PRIVATE per-agent PGID sidecar (the subshell points AGENT_PID_FILE at that
# sidecar — NOT the shared review-N.pid, which would thrash the dispatcher's
# liveness model per INV-40). The wrapper drains those sidecars into its
# `_AGENT_PGIDS` array and passes them here.
#
# Each arg is one PGID. Group-kills with the negative-PID form
# `kill -TERM -- -<pgid>`, then escalates to KILL after a short grace. NO-OP for
# agents that already exited (the common case — the fan-out `wait` returned
# before this runs) and for empty / non-numeric args. Idempotent.
#
# Uses `log` if the caller defined it (the wrapper does); otherwise prints to
# stderr so the function is self-contained for unit tests.
_reap_fanout_processes() {
  local _pgid _signaled=0
  local _emit
  if declare -F log >/dev/null 2>&1; then _emit=log; else _emit=_reap_log_stderr; fi

  for _pgid in "$@"; do
    [[ "$_pgid" =~ ^[0-9]+$ ]] && [[ "$_pgid" -gt 0 ]] || continue
    # Group-kill: negative PID targets the whole process group. A miss (group
    # already gone) is expected and silenced.
    if kill -0 -- "-$_pgid" 2>/dev/null; then
      "$_emit" "INV-43: reaping lingering fan-out agent process group (pgid=$_pgid)"
      kill -TERM -- "-$_pgid" 2>/dev/null || true
      _signaled=1
    fi
  done
  # Brief grace, then KILL anything that ignored TERM. Skipped entirely if no
  # group was alive to TERM (we already know that from the loop above — no
  # second probe walk needed).
  if [[ "$_signaled" -eq 1 ]]; then
    sleep 2
    for _pgid in "$@"; do
      [[ "$_pgid" =~ ^[0-9]+$ ]] && [[ "$_pgid" -gt 0 ]] || continue
      if kill -0 -- "-$_pgid" 2>/dev/null; then
        "$_emit" "INV-43: escalating to KILL for fan-out agent process group (pgid=$_pgid)"
        kill -KILL -- "-$_pgid" 2>/dev/null || true
      fi
    done
  fi
}

# Fallback logger used by _reap_fanout_processes when the caller (the wrapper)
# has not defined `log`. Keeps the lib self-contained for unit tests.
_reap_log_stderr() { printf '%s\n' "$*" >&2; }
