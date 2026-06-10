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
# `turn.completed` event) posted the VERDICT, by EITHER of two signals:
#   (A) an `item.completed` `agent_message` whose TEXT carries a VERDICT TRAILER —
#       one of the verdict phrasings the wrapper's comment poller recognises
#       (`lib-review-poll.sh::_classify_verdict_body`) or the `Review Agent: codex`
#       attribution trailer; OR
#   (B) an `item.completed` `command_execution` whose COMMAND runs the INV-56
#       helper `post-verdict.sh` with a `pass`/`fail` verdict argument (the #214
#       fix — see below).
# rc 1 otherwise — including an empty/missing log, a gather-only last turn (only
# `tool_call`/`reasoning`/non-verdict `command_execution` items), a last turn whose
# only `agent_message`s are PROGRESS NARRATION (no verdict trailer), or a log whose
# final turn has NOT completed yet (a message with no trailing `turn.completed`
# does not count — the turn is still in flight).
#
# #198 / INV-53: this used to converge on ANY `agent_message` in the last turn.
# But codex emits `agent_message` for narration ("Next I'm reading the
# instructions…", "I'll verify the PR…"), not only for the final verdict. A
# gather-heavy turn that narrates then dies before posting the verdict tripped the
# old heuristic as "converged" → no resume → the poller found no verdict comment →
# codex was dropped `unavailable`. Convergence MUST mean "codex posted the
# VERDICT", not "codex emitted any assistant message". So we require the
# verdict-trailer text inside an `agent_message` item.
#
# #214 / INV-56 follow-up — signal (B): since INV-56 the verdict is posted by
# RUNNING `bash scripts/post-verdict.sh <issue> pass|fail <body-file> …`, so on the
# common turn-1 path the verdict signal lands in a `command_execution` event (the
# argv codex ran), NOT in an `agent_message`. Signal (A) alone misses it → the loop
# fired a redundant resume and codex DOUBLE-POSTED the verdict (the second comment
# carrying a doubled trailer). So we ALSO converge on a `command_execution` whose
# COMMAND invokes `post-verdict.sh` with a `pass`/`fail` arg. Signal (A) is kept (a
# CLI that posts a verdict as a plain assistant message still converges — no
# regression of the INV-53 path); a turn converges iff EITHER signal fires.
#
# This is the "did codex's last turn produce the verdict?" signal, NOT a
# GitHub-comment check (that is the wrapper poller's job — see LAYER above): the
# poller stays the AUTHORITATIVE gate. Keying on the SAME phrasings/helper the
# poller and INV-56 use makes the two agree — "the JSONL stream shows the verdict
# being posted" ⇒ "the poller will find the comment". It is fail-safe toward
# RESUMING: an ambiguous turn resumes (bounded), it never false-stops; worst case
# wastes one bounded resume, never silently drops codex.
#
# Why awk: jq is not a hard dependency of this subsystem (mirrors
# lib-agent.sh::_codex_capture_thread). Codex `--json` emits one event per line
# (JSONL; newlines inside an agent_message text are escaped as \n, AND the whole
# command_execution item — type AND command — is on ONE physical line). We do a
# single pass tracking, per turn, whether a verdict signal (A or B) was seen
# (`cur_msg`); `turn.started` resets it at each turn boundary and `turn.completed`
# snapshots it into `last`, then resets it. The final `last` snapshot is the answer.
_codex_log_has_verdict_message() {
  local log_file="${1:-}"
  [[ -n "$log_file" && -f "$log_file" ]] || return 1
  local result
  result=$(awk '
    {
      # An item.completed carrying an agent_message whose TEXT contains a verdict
      # trailer marks the CURRENT turn as having posted the verdict. Three
      # conjuncts on the same JSONL line (codex emits one event per line):
      #   (1) the event is an item.completed;
      #   (2) the item type is agent_message, scoped INSIDE the item object
      #       (`"item":{...,"type":"agent_message"...}`) — NOT a bare type match
      #       anywhere on the line, so a tool_call/command_execution whose OUTPUT
      #       text contains the literal substring (e.g. codex grepping its own
      #       JSONL log) is NOT a false verdict (#189 review finding 2);
      #   (3) the line contains a VERDICT-TRAILER phrase (#198 / INV-53) — the
      #       pass/fail phrasings the wrapper poller matches plus the
      #       `Review Agent: codex` discriminator. Matched case-insensitively on a
      #       lowercased copy of the line. Conjunct (3) is what rejects pure
      #       progress narration: a narration agent_message satisfies (1)+(2) but
      #       carries no verdict trailer, so it does NOT set the flag.
      # Because all three conjuncts must hold ON THE SAME LINE, a verdict PHRASE
      # appearing in a SEPARATE command_execution line within the same turn (codex
      # catting SKILL.md / the prompt) cannot trip the flag — that line fails (2).
      # The bracket window assumes type is a leading flat key of item (the
      # documented codex event shape). If a future codex schema nested an object
      # BEFORE type inside item, this would false-NEGATIVE -- but that only wastes
      # one extra resume (fail-safe), never misses a real verdict.
      # (Comment kept apostrophe-free: this awk body is inside single quotes.)
      if ($0 ~ /"type":"item\.completed"/ && $0 ~ /"item":\{[^{}]*"type":"agent_message"/) {
        line = tolower($0)
        # Verdict trailers: pass-side, fail-side, and the codex attribution
        # discriminator. Mirrors lib-review-poll.sh::_classify_verdict_body
        # (kept in sync) plus `Review Agent: codex`. `review pass` also matches
        # the longer `review passed`; that is intentional (both are pass-side).
        # Plain substring matches (no word boundaries) in a single ERE
        # alternation — same shape as the poller (`grep -qiE`) so the two ALWAYS
        # agree, AND portable to any POSIX awk (gawk `\<`/`\>` are a GNU extension
        # this subsystem must not depend on, mirroring _codex_capture_thread).
        # Order is pass-side, fail-side, then the codex discriminator.
        if (line ~ /review passed|review approved|approved for merge|lgtm|review pass|review failed|review rejected|review findings:|changes requested|review agent: *codex/) {
          cur_msg = 1
        }
      }
      # #214 signal (B): an item.completed command_execution that RUNS the INV-56
      # verdict helper marks the current turn as having posted the verdict. Same
      # item-scope discipline as the agent_message path — three conjuncts on the
      # same JSONL line (codex emits one event per line; the command field is part
      # of the item object, so type AND command are on ONE physical line):
      #   (1) the event is an item.completed;
      #   (2) the item type is command_execution, scoped INSIDE the item object
      #       (`"item":{...,"type":"command_execution"...}`) — NOT a bare match
      #       anywhere on the line, so an agent_message whose TEXT merely narrates
      #       "I will run post-verdict.sh" does NOT count (it fails this conjunct);
      #   (3) the COMMAND invokes post-verdict.sh with the verdict POSITIONAL arg.
      #       Conjunct (3) is matched against `cmd` — the JSON-string value of the
      #       command field for THIS item, isolated escape-awarely (the closing
      #       quote is the first UNESCAPED one; an escaped backslash-quote inside the
      #       command, e.g. a printf-quoted prelude chained with && before
      #       post-verdict.sh, does NOT terminate it) — NOT the whole line, so a
      #       post-verdict.sh string sitting only in a separate `aggregated_output`
      #       (codex catting SKILL.md / the prompt, which document the helper) does
      #       NOT trip it. (Comment kept apostrophe- and single-quote-free: this awk
      #       body is inside single quotes.) The argv shape is
      #       `post-verdict.sh <issue-number> <pass|fail> <body-file> …`, so we
      #       anchor the verdict token to ITS ARGUMENT POSITION: `post-verdict.sh`,
      #       then the issue-number positional (one or more digits), then the
      #       `pass`/`fail` token. Anchoring to the position (rather than ANY
      #       boundaried `pass`/`fail` occurrence) is what keeps it fail-safe toward
      #       RESUMING: a body-file PATH that merely contains a `pass`/`fail` path
      #       segment (e.g. `/tmp/pass-notes.md`, `/var/fail/x.md`) must NOT
      #       false-converge — that path appears AFTER the verdict positional, never
      #       in its slot, so the anchored match rejects it. The token is bounded by
      #       a trailing non-alphanumeric OR end-of-string (so `pass`/`passphrase`
      #       stay distinct) — POSIX awk has no \< / \> word boundaries (a GNU
      #       extension this subsystem avoids, mirroring _codex_capture_thread).
      if ($0 ~ /"type":"item\.completed"/ && $0 ~ /"item":\{[^{}]*"type":"command_execution"/) {
        # Isolate the command field value: drop everything up to `"command":"`,
        # then keep up to the closing `"` of the command string. We only populate
        # `cmd` when the `"command":"` field is present on the line; some
        # command_execution events carry only aggregated_output on a later line, so
        # `cmd` stays empty for those and an aggregated_output substring cannot match
        # the post-verdict shape below.
        cmd = ""
        if ($0 ~ /"command":"/) {
          cmd = $0
          sub(/^.*"command":"/, "", cmd)
          # Truncate at the JSON string TERMINATOR — the first UNESCAPED `"`. A
          # command field can legitimately contain escaped quotes (`\"`) before
          # post-verdict.sh — e.g. a chained
          # `printf '%s' \"verified\" > f && bash scripts/post-verdict.sh 214 pass …`
          # turn. A naive `sub(/".*$/, "", cmd)` cuts at the FIRST `"`, i.e. at the
          # escaped quote, dropping the real helper invocation → the detector
          # false-NEGATIVES and the resume loop fires a duplicate verdict (the very
          # bug #214 fixes; #217 codex review finding). So we neutralize escaped
          # quotes BEFORE truncating: replace every `\"` with a sentinel (ESC, the
          # POSIX octal escape \033 for a control char that never appears in a
          # command), truncate at the first remaining (genuine, unescaped) `"`, then
          # restore.
          # The restore keeps the literal text intact for the substring match below;
          # the match itself does not depend on quote chars, but restoring avoids any
          # surprise from a sentinel landing inside the matched span.
          gsub(/\\"/, "\033", cmd)   # \" (escaped quote) → ESC sentinel
          sub(/".*$/, "", cmd)        # cut at the first UNescaped " (field end)
          gsub(/\033/, "\"", cmd)     # restore the escaped quotes as literal "
        }
        cmdl = tolower(cmd)
        # post-verdict.sh <issue-number> <pass|fail> — the verdict token in ITS
        # POSITIONAL slot (after the issue-number positional). `[^a-z0-9]+`
        # absorbs the whitespace (and any leading `bash`/path noise stays before
        # `post-verdict.sh`); `[0-9]+` is the issue number; the trailing
        # `([^a-z0-9]|$)` makes `pass`/`fail` a standalone token. This rejects a
        # `pass`/`fail`-named body-file path segment, which appears only AFTER the
        # verdict positional (fail-safe toward resuming).
        if (cmdl ~ /post-verdict\.sh[^a-z0-9]+[0-9]+[^a-z0-9]+(pass|fail)([^a-z0-9]|$)/) {
          cur_msg = 1
        }
      }
      # turn.started opens a NEW turn — reset the per-turn flag so a verdict
      # message from a PRIOR turn that was killed before its own turn.completed
      # (the per-turn cap firing mid-stream, rc 124/137) does NOT leak across the
      # boundary and falsely mark THIS turn as having a verdict.
      if ($0 ~ /"type":"turn\.started"/) {
        cur_msg = 0
      }
      # turn.completed closes the current turn: snapshot whether it had a
      # verdict message, then reset for the next turn.
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
# each resume turn. Tells codex to PREFER the context it already loaded and
# produce the verdict NOW, posting it through the INV-56 deterministic helper
# `post-verdict.sh`. $1 = the agent's Review Session UUID (passed as the helper's
# session-id argument).
#
# #198 follow-up: the original prompt was ABSOLUTE — "do NOT re-run git diff and
# do NOT re-read files you already read". But codex compacts its OWN context on a
# long turn, so on resume the diff may no longer be in its working context. The
# absolute bar then left codex unable to substantiate a verdict, and it
# defensively posted a "[BLOCKING] review context unavailable" FAIL instead of a
# real verdict (observed on the codex lane reviewing PR #199 itself). So the
# prompt now PREFERS reuse to avoid gratuitous re-gather on the common path but
# EXPLICITLY allows re-reading the minimum needed when that context is gone, and
# instructs codex to NEVER refuse a verdict for lack of context. This keeps the
# INV-51 goal (don't burn the turn re-gathering everything) while removing the
# strand-on-compaction failure mode.
#
# #214 / INV-56: the prompt previously told codex to post the verdict and to
# HAND-WRITE the `Review Agent: codex` / `Review Session: <uuid>` trailer
# "verbatim". Since INV-56 the verdict is posted via `bash scripts/post-verdict.sh`,
# which composes that trailer itself — so the hand-written lines are redundant and
# produced a DOUBLED trailer whenever a resume turn legitimately posted (the
# hand-written block stacked on the helper's own). The prompt now routes the
# verdict through `post-verdict.sh` ONLY and does NOT instruct codex to hand-write
# the trailer. The session uuid is still supplied — codex passes it as the helper's
# session-id argument (the helper writes the `Review Session:` line from it). This
# matches the main review prompt (see autonomous-review.sh build_review_prompt).
_codex_resume_prompt() {
  local session_uuid="${1:-}"
  cat <<EOF
Continue the review of the PR diff you ALREADY loaded in the previous turn(s).
Prefer the context you already have — do not gratuitously re-run \`git diff\` or
re-read files that are still in your context, since re-doing finished work wastes
the turn. BUT if your context was compacted and the diff or a file you need is no
longer available to you, re-read the minimum you need to reach a substantiated
verdict — do NOT refuse to issue a verdict merely because context is missing.
Produce your review findings NOW and post your verdict comment on the issue.

Post the verdict ONLY by running the deterministic helper:

  bash scripts/post-verdict.sh <issue-number> <pass|fail> <body-file> codex ${session_uuid} '<model>'

- A passing verdict: pass \`pass\` as the verdict and a body that reads
  "Review PASSED - <one-line summary>".
- A failing verdict: pass \`fail\` as the verdict and a body that starts with
  "Review findings:" and lists each blocking finding.

Write the body to a FILE and pass the file path (so a multi-line body with
backticks/quotes cannot be mangled). Do NOT hand-write the
\`Review Agent:\` / \`Review Session:\` trailer and do NOT use a bare
\`gh issue comment\` for the verdict — the helper appends the attribution trailer
itself from the arguments you pass, so writing it yourself would duplicate it.
The <issue-number> and <model> values are in your original review prompt; pass
them exactly. Use your agent name \`codex\` and the session id ${session_uuid}
shown above.

A finding must be about the PR's CODE (correctness, tests, requirements, CI,
security). "I cannot verify because my context is unavailable" is NOT a valid
finding — re-read what you need and decide.

Post the verdict now and then stop.
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
  # — EXCEPT a TRANSIENT STREAM ERROR (INV-59, #209). codex's CLI can exhaust its
  # 5/5 SSE reconnects against a brief upstream 5xx and emit `turn.failed` with a
  # non-zero rc; that is a RECOVERABLE blip, not a genuine launch misconfig. So
  # when the log shows a fresh stream error, do NOT early-return — fall through to
  # the bounded resume loop so the controller issues ANOTHER turn. A brief blip is
  # ridden out (the next turn succeeds → verdict); a SUSTAINED outage still exits
  # gracefully when the loop exhausts CODEX_REVIEW_MAX_RESUMES (it does not
  # converge), and codex is then resolved `unavailable` by the post-window sweep
  # exactly as before — but now with a `stream-error` drop reason surfaced. A
  # genuine non-stream launch failure (rc != 0, no stream-error signal) still
  # early-returns here, unchanged. The stream-error check needs a readable log;
  # if the log is unreadable we cannot tell, so keep the conservative early-return.
  if [[ "$final_rc" -ne 0 && "$final_rc" -ne 124 && "$final_rc" -ne 137 ]]; then
    if ! { [[ -n "$log" && -f "$log" && -r "$log" ]] && _codex_log_has_stream_error "$log"; }; then
      return "$final_rc"
    fi
    echo "[lib-review-codex] codex turn 1 exited rc ${final_rc} with a transient stream error (upstream 5xx; exhausted SSE reconnects); riding it out via the bounded resume loop (INV-59)." >&2
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

# ===========================================================================
# INV-59 (#209): codex transient stream-error drop-reason detector
# ===========================================================================
# WHY this exists
# ---------------
# When a codex review member's model stream dies with an upstream server error,
# codex's CLI retries the SSE stream up to `Reconnecting... 5/5` and then emits
# `{"type":"turn.failed","error":{"message":"stream disconnected before
# completion: ..."}}`. The CLI exits non-zero with no verdict comment, so the
# wrapper's post-window sweep resolves it `unavailable` ([INV-40]) and, before
# #209, the drop-reason assembly enriched the reason only for `agy` — codex got a
# bare, opaque `unavailable` indistinguishable from a launch misconfig.
#
# This is the codex-shaped sibling of lib-review-agy.sh's quota/auth detector
# (INV-58): a CLI-specific review-side classifier that reads codex's OWN JSONL
# event stream (the per-agent log run_agent already writes) and never queries
# GitHub. It is OBSERVABILITY ONLY — it does NOT change the [INV-40] vote (a
# server-side 5xx is an infra condition, not a code rejection; promoting it to a
# deciding FAIL would block merges whenever the provider blips). The retry half
# of INV-59 lives in _run_codex_review_with_resume above (the early-return now
# falls through to the bounded resume loop on a fresh stream error).

# _codex_log_has_stream_error <log_file>
#
# rc 0 iff codex's JSONL log shows a STREAM/SERVER error signal — a `turn.failed`
# event whose `error.message` carries `stream disconnected before completion`
# (the upstream-5xx shape), OR a `Reconnecting... N/5 (stream disconnected ...)`
# reconnect-ladder error line. rc 1 otherwise — including a clean `turn.completed`
# with no verdict (the #198 gather/narration case: NOT a stream error, so this
# never over-claims), a verdict turn, or an empty/missing/unreadable log
# (fail-safe — the wrapper runs under `set -euo pipefail`, so this MUST NOT abort).
#
# Like _codex_log_has_verdict_message, the match keys on the EVENT TYPE scoped to
# the line shape, not a bare substring anywhere on the line: a `turn.failed`
# detection requires `"type":"turn.failed"` (the event itself), so a tool_call
# whose OUTPUT text merely contains the literal substring `turn.failed` (codex
# grepping its own JSONL log) is NOT a false positive. Single-pass awk, no jq
# (mirrors _codex_log_has_verdict_message / _codex_capture_thread).
_codex_log_has_stream_error() {
  local log_file="${1:-}"
  [[ -n "$log_file" && -f "$log_file" && -r "$log_file" ]] || return 1
  local result
  result=$(awk '
    {
      # (1) a turn.failed EVENT carrying the stream-disconnect message. Both
      #     conjuncts must hold on the SAME JSONL line (codex emits one event per
      #     line), so a tool_call OUTPUT line containing the literal substring
      #     "turn.failed" cannot trip it (it would not also be the turn.failed
      #     event type at the line head).
      if ($0 ~ /"type":"turn\.failed"/ && $0 ~ /stream disconnected before completion/) {
        found = 1
      }
      # (2) the Reconnecting... N/5 reconnect ladder (an "error" event the CLI
      #     emits per SSE retry). The "stream disconnected before completion"
      #     phrase is required so an unrelated "Reconnecting..." log line cannot
      #     match.
      if ($0 ~ /"type":"error"/ && $0 ~ /Reconnecting\.\.\./ && $0 ~ /stream disconnected before completion/) {
        found = 1
      }
    }
    END { if (found) print "yes"; else print "no" }' "$log_file" 2>/dev/null)
  [[ "$result" == "yes" ]]
}

# _classify_codex_drop_reason <log_file>
#
# Scrape a codex JSONL log for a stream/server error signal. Echoes ONE token on
# stdout (rc 0 ALWAYS — fail-safe under `set -euo pipefail`, mirrors
# _classify_agy_drop_reason):
#
#   stream-error[:N/5]
#       — the log shows a turn.failed stream error. The ":N/5" suffix is the
#         HIGHEST reconnect-ladder depth seen (`Reconnecting... N/5`) — the
#         operator's "codex retried the stream N times before giving up". Appended
#         only when the ladder is present in the log.
#   "" (empty)
#       — no stream-error signal (the caller keeps the bare `unavailable`). A
#         clean no-verdict turn (#198) or a verdict turn yields empty — NO
#         over-claim.
_classify_codex_drop_reason() {
  local log_file="${1:-}"
  [[ -n "$log_file" && -f "$log_file" && -r "$log_file" ]] || return 0

  _codex_log_has_stream_error "$log_file" || return 0

  # Stream error present. Extract the highest reconnect-ladder depth (the `N` in
  # `Reconnecting... N/5`) when the log shows the ladder. The ERE is anchored on
  # the "Reconnecting... " literal so unrelated digits never match; `/5` is the
  # CLI's fixed reconnect cap.
  #
  # A no-ladder log (e.g. a `turn.failed` stream error with no `Reconnecting...`
  # lines) makes the first grep exit 1; under `set -o pipefail` the whole pipeline
  # then returns non-zero. This is a BARE assignment on its own line (not
  # `local ladder=$(…)`, where the `local` builtin's rc would mask it), so without
  # the trailing `|| true` the failing pipeline aborts the function under `set -e`
  # before it reaches `return 0` — violating this helper's "rc 0 ALWAYS" fail-safe
  # contract. The sole production caller invokes us via command substitution
  # (`autonomous-review.sh` `_codex_reason_token=$(…)`), which happens to suppress
  # errexit for the body, so this is latent there — but a future bare call would
  # crash. `|| true` makes the no-match an empty `ladder`, which the `if` below
  # already handles. (codex review finding on PR #211.)
  local ladder
  ladder=$(grep -oE 'Reconnecting\.\.\. [0-9]+/5' "$log_file" 2>/dev/null \
    | grep -oE '[0-9]+/5' | sort -t/ -k1 -n | tail -1) || true

  if [[ -n "$ladder" ]]; then
    printf 'stream-error:%s\n' "$ladder"
  else
    printf 'stream-error\n'
  fi
  return 0
}

# _codex_drop_reason_phrase <reason-token>
#
# Render a token from _classify_codex_drop_reason into a single human-facing
# clause for the WARN log line + the posted dropped-agent comment. Echoes empty
# for an empty/unknown token (the caller then keeps the bare `unavailable`
# wording). rc 0 always.
#
#   stream-error:5/5
#       → "stream-error (upstream 5xx; exhausted 5/5 SSE reconnects, turn.failed)"
#   stream-error
#       → "stream-error (upstream 5xx; SSE stream disconnected, turn.failed)"
_codex_drop_reason_phrase() {
  local token="${1:-}"
  case "$token" in
    stream-error:*)
      local depth="${token#stream-error:}"
      printf 'stream-error (upstream 5xx; exhausted %s SSE reconnects, turn.failed)\n' "$depth"
      ;;
    stream-error)
      printf 'stream-error (upstream 5xx; SSE stream disconnected, turn.failed)\n'
      ;;
    *)
      # Empty or unknown token → empty phrase.
      ;;
  esac
  return 0
}
