#!/bin/bash
# lib-review-codex.sh — codex-specific review path: auto-resume the codex thread
# until it posts a verdict (INV-51, issue #189).
#
# WHY this exists
# ---------------
# `codex exec` runs exactly ONE agentic turn. On a large review diff codex
# non-deterministically spends that whole turn on context-gathering (`git diff`,
# file reads — 55k–120k input tokens) and then emits `turn.completed` with no
# findings and NO verdict comment. The wrapper's comment poller sees no verdict
# within its window and marks codex `unavailable` ([INV-40]); the fleet silently
# degrades to the remaining agent(s), losing codex's independent second opinion
# exactly when the diff is large enough to need it.
#
# Waiting longer does NOT help — codex's turn already ENDED (`turn.completed`).
# The fix is to issue ANOTHER turn: resume the SAME thread
# (`codex exec resume <thread_id>`, via lib-agent.sh's resume_agent codex branch)
# with an explicit "continue and post the verdict" prompt, repeated while turns
# end gather-only, bounded by a max-resume count AND a wall-clock deadline.
#
# LAYER (load-bearing, per the issue's engineering review)
# --------------------------------------------------------
# This loop lives HERE — a codex-specific review-side lib — NOT in the generic
# run_agent/resume_agent in lib-agent.sh. Putting verdict/GitHub knowledge into
# run_agent would violate lib-agent.sh's CLI-agnostic layering. The loop watches
# codex's own JSONL EVENT STREAM (the per-agent log that run_agent already
# writes) and never queries the GitHub comments API mid-loop. The wrapper's
# existing issue-comment verdict poller (lib-review-poll.sh) remains the
# AUTHORITATIVE verdict gate AFTER this function returns: the JSONL loop only
# gets codex to FINISH its turn; the comment poller confirms the verdict landed.
#
# SCOPE: only the codex review path calls this. claude/agy/kiro/gemini/opencode
# take the single-invocation run_agent path unchanged — those CLIs complete
# multi-step in one invocation.

# Max resume turns before giving up and falling back to today's behavior (no
# verdict → `unavailable` via the wrapper's post-window sweep). Operator-tunable
# via CODEX_REVIEW_MAX_RESUMES in autonomous.conf; 0 disables the loop entirely
# (regression-safety knob — codex then behaves exactly as pre-#189).
: "${CODEX_REVIEW_MAX_RESUMES:=3}"

# _codex_now_seconds — current wall-clock in epoch seconds. Wrapped in a function
# (not an inline `date +%s`) so the resume-loop controller's deadline math is
# unit-testable with a deterministic stub. Uses bash's EPOCHSECONDS when present
# (bash ≥ 5.0, the box's shell) and falls back to `date +%s`.
_codex_now_seconds() {
  printf '%s\n' "${EPOCHSECONDS:-$(date +%s)}"
}

# _codex_review_deadline_seconds — the resume loop's total wall-clock budget in
# seconds, parsed from AGENT_REVIEW_TIMEOUT (the review wall-clock cap, INV-48;
# coreutils-`timeout` units s/m/h/d). This is a SECOND guard on top of the
# per-turn _run_with_timeout cap: it bounds N turns × per-turn-cap so the resume
# loop cannot blow far past the review window. An empty / unset / unparseable
# value degrades to the 1h default (3600s) — NEVER unbounded (a 0 or garbage
# value must not silently un-cap the loop).
_codex_review_deadline_seconds() {
  local v="${AGENT_REVIEW_TIMEOUT:-1h}"
  if [[ "$v" =~ ^([1-9][0-9]*)([smhd]?)$ ]]; then
    local num="${BASH_REMATCH[1]}"
    local unit="${BASH_REMATCH[2]}"
    case "$unit" in
      ""|s) printf '%s\n' "$num" ;;
      m)    printf '%s\n' "$((num * 60))" ;;
      h)    printf '%s\n' "$((num * 3600))" ;;
      d)    printf '%s\n' "$((num * 86400))" ;;
    esac
  else
    printf '%s\n' 3600   # 1h default; never unbounded
  fi
}

# _codex_log_has_verdict_message <log_file>
#
# rc 0 iff codex's LAST COMPLETED turn (the segment ending at the final
# `turn.completed` event) contained an `item.completed` whose item type is
# `agent_message`. rc 1 otherwise — including an empty/missing log, a log whose
# last turn is gather-only (only `tool_call`/`reasoning` items), or a log whose
# final turn has NOT completed yet (an agent_message with no trailing
# `turn.completed` does not count — the turn is still in flight).
#
# This is the "did codex's last turn converge on output?" signal, NOT a
# GitHub-comment check (that is the wrapper poller's job — see LAYER above). An
# `agent_message` is codex's final assistant message for a turn; once codex emits
# one, it has produced its findings and further resumes are wasteful. The poller
# then confirms whether the verdict comment actually landed.
#
# Why awk: jq is not a hard dependency of this subsystem (mirrors
# lib-agent.sh::_codex_capture_thread). Codex `--json` emits one event per line.
# We do a single pass tracking, per turn, whether an agent_message item was seen
# (`cur_msg`); `turn.started` resets it at each turn boundary and `turn.completed`
# snapshots it into `last`, then resets it. The final `last` snapshot is the
# answer.
_codex_log_has_verdict_message() {
  local log_file="${1:-}"
  [[ -n "$log_file" && -f "$log_file" ]] || return 1
  local result
  result=$(awk '
    {
      # An item.completed carrying an agent_message marks the CURRENT turn as
      # having produced an assistant message. Match both event type and the
      # item type on the same JSONL line (codex emits one event per line).
      # The narrowed item-scoped match (vs a bare type match anywhere on the
      # line) requires the agent_message type to live INSIDE the item object, so
      # a tool_call whose OUTPUT text contains the literal substring (e.g. codex
      # grepping its own JSONL log) is NOT a false verdict (#189 review finding
      # 2). The bracket window assumes type is a leading flat key of item (the
      # documented codex event shape). If a future codex schema nested an object
      # BEFORE type inside item, this would false-NEGATIVE -- but that only
      # wastes one extra resume (fail-safe), never misses a real verdict.
      # (Comment kept apostrophe-free: this awk body is inside single quotes.)
      if ($0 ~ /"type":"item\.completed"/ && $0 ~ /"item":\{[^{}]*"type":"agent_message"/) {
        cur_msg = 1
      }
      # turn.started opens a NEW turn — reset the per-turn flag so an
      # agent_message from a PRIOR turn that was killed before its own
      # turn.completed (the per-turn cap firing mid-stream, rc 124/137) does NOT
      # leak across the boundary and falsely mark THIS turn as having a verdict.
      if ($0 ~ /"type":"turn\.started"/) {
        cur_msg = 0
      }
      # turn.completed closes the current turn: snapshot whether it had a
      # message, then reset for the next turn.
      if ($0 ~ /"type":"turn\.completed"/) {
        last = cur_msg
        cur_msg = 0
        saw_completed = 1
      }
    }
    END {
      # Only a COMPLETED turn counts. If no turn completed, the answer is "no".
      if (saw_completed && last) { print "yes" } else { print "no" }
    }' "$log_file" 2>/dev/null)
  [[ "$result" == "yes" ]]
}

# _codex_resume_prompt — the explicit continue-and-emit-verdict prompt fed to
# each resume turn. Tells codex to stop re-gathering and produce the verdict NOW,
# carrying the same discriminator/session lines the wrapper's verdict poller
# binds on (INV-40 / INV-20). $1 = the agent's Review Session UUID.
_codex_resume_prompt() {
  local session_uuid="${1:-}"
  cat <<EOF
Continue the review of the PR diff you ALREADY loaded in the previous turn(s).
Do NOT re-run \`git diff\` and do NOT re-read files you already read — that work
is done and re-doing it wastes the turn. Produce your review findings NOW and
post your verdict comment on the issue:

- A passing verdict: a comment whose body contains "Review PASSED".
- A failing verdict: a comment whose body starts with "Review findings:" and
  lists each blocking finding.

Your verdict comment MUST include these two lines verbatim so the wrapper can
attribute it:
  Review Agent: codex
  Review Session: ${session_uuid}

Post the comment now and then stop.
EOF
}

# _run_codex_review_with_resume <session_id> <prompt> <model> <session_name>
#
# The bounded resume-loop controller. Runs codex once via run_agent (its codex
# branch captures the thread_id to a sidecar keyed by <session_id>), then resumes
# the SAME thread while turns end gather-only — up to CODEX_REVIEW_MAX_RESUMES
# turns AND within the AGENT_REVIEW_TIMEOUT-derived wall-clock deadline.
#
# Return code: normally the exit code of the LAST agent invocation, EXCEPT a
# 124 (coreutils timeout TERM-expiry) or 137 (--kill-after SIGKILL) from ANY
# turn is STICKY — once a turn was killed by the per-turn wall-clock cap, that
# rc is preserved even if a later resume turn exits 0. This is load-bearing for
# the INV-48 timeout-veto: the wrapper's post-window sweep maps a no-verdict
# rc 124/137 to `timed-out` (a deciding FAIL that VETOES the merge); if the loop
# reset rc to 0 on a subsequent clean-but-still-no-verdict turn, the agent would
# be silently dropped as `unavailable` instead of vetoing — defeating the cap
# (#189 review finding 1). The wrapper's comment poller is the authoritative
# verdict gate after this returns; on bound exhaustion with no verdict message,
# codex is resolved `unavailable` (or `timed-out` if the sticky rc is 124/137)
# exactly as before #189.
#
# CODEX_REVIEW_LOG must point at the per-agent JSONL log (the fan-out subshell
# sets it to $_agent_log, the same file run_agent's stdout is redirected to).
# We read it to detect gather-only turns. If unset, the loop degrades to a
# single run_agent (no resume) — fail-safe, never worse than today.
_run_codex_review_with_resume() {
  local session_id="$1" prompt="$2" model="$3" session_name="$4"
  local log="${CODEX_REVIEW_LOG:-}"
  local max="${CODEX_REVIEW_MAX_RESUMES:-3}"
  # Degrade-don't-crash (mirrors _codex_review_deadline_seconds and
  # lib-agent.sh::_is_positive_timeout_value): the wrapper runs under
  # `set -euo pipefail`, so a NON-NUMERIC operator typo (e.g.
  # CODEX_REVIEW_MAX_RESUMES="three") reaching the `(( resumes >= max ))`
  # arithmetic below would abort the fan-out subshell with an "unbound variable"
  # error — stranding the issue in `reviewing` with no verdict. Default any
  # non-(non-negative-integer) value back to 3 so a typo can never crash the
  # review wrapper.
  [[ "$max" =~ ^[0-9]+$ ]] || max=3

  # Turn 1: a fresh codex session. run_agent's codex branch captures the
  # thread_id into the sidecar; resume_agent reads it back below.
  local final_rc=0
  run_agent "$session_id" "$prompt" "$model" "$session_name" || final_rc=$?

  # Return early on a non-timeout launch failure (rc is non-zero and not 124/137)
  if [[ "$final_rc" -ne 0 && "$final_rc" -ne 124 && "$final_rc" -ne 137 ]]; then
    return "$final_rc"
  fi

  # Without a readable log we cannot detect gather-only turns — degrade to the
  # single-run behavior (never worse than pre-#189).
  [[ -n "$log" && -f "$log" && -r "$log" ]] || return "$final_rc"

  # Only resume when the thread sidecar exists (if the helper is available).
  # If we have no captured thread_id, we cannot resume the same conversation.
  if declare -f _codex_thread_id >/dev/null; then
    _codex_thread_id "$session_id" >/dev/null || return "$final_rc"
  fi

  local deadline budget now resumes=0
  budget=$(_codex_review_deadline_seconds)
  now=$(_codex_now_seconds)
  deadline=$((now + budget))

  while true; do
    # codex converged (its last completed turn produced an assistant message) →
    # hand off to the wrapper's comment poller.
    if _codex_log_has_verdict_message "$log"; then
      break
    fi
    # Bound 1: resume budget exhausted → fall back to `unavailable`.
    if (( resumes >= max )); then
      [[ "$max" -gt 0 ]] && \
        echo "[lib-review-codex] codex review hit CODEX_REVIEW_MAX_RESUMES=${max} with no verdict turn; falling back to the wrapper poller (likely unavailable)." >&2
      break
    fi
    # Bound 2: wall-clock deadline reached → fall back. Checked AFTER the
    # max-resume bound so a max=N config does exactly N resumes when time allows.
    now=$(_codex_now_seconds)
    if (( now >= deadline )); then
      echo "[lib-review-codex] codex review hit the ${budget}s wall-clock deadline (AGENT_REVIEW_TIMEOUT) after ${resumes} resume(s) with no verdict turn; falling back to the wrapper poller." >&2
      break
    fi

    resumes=$((resumes + 1))
    echo "[lib-review-codex] codex turn was gather-only (no verdict message); resuming thread (resume ${resumes}/${max})." >&2
    local turn_rc=0
    resume_agent "$session_id" "$(_codex_resume_prompt "$session_id")" "$model" "$session_name" || turn_rc=$?

    # Sticky timeout rc: once ANY turn was killed by the per-turn wall-clock cap
    # (124 = coreutils timeout TERM, 137 = --kill-after SIGKILL), preserve that rc
    # even if a later resume exits cleanly — the INV-48 veto must not be reset by a
    # subsequent clean-but-still-no-verdict turn (#189 review finding 1). The ONLY
    # case where we KEEP the existing rc is: final_rc is already a sticky timeout
    # AND this turn is not a timeout. Otherwise propagate this turn's rc (which may
    # itself be a fresh 124/137 that STARTS the stickiness).
    local final_is_sticky_timeout=false turn_is_timeout=false
    [[ "$final_rc" -eq 124 || "$final_rc" -eq 137 ]] && final_is_sticky_timeout=true
    [[ "$turn_rc"  -eq 124 || "$turn_rc"  -eq 137 ]] && turn_is_timeout=true
    if [[ "$turn_is_timeout" == true || "$final_is_sticky_timeout" == false ]]; then
      final_rc="$turn_rc"
    fi
  done

  return "$final_rc"
}
