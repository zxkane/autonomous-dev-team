#!/bin/bash
# lib-review-codex.sh — codex-specific review path: run the purpose-built
# `codex review "<prompt>"` subcommand (INV-62, issue #218).
#
# WHY this exists / what it replaces
# ----------------------------------
# Pre-#218 the codex REVIEW member ran through the generic `codex exec --json`
# branch (lib-agent.sh). `codex exec` runs exactly ONE agentic turn, so on a
# large review diff codex non-deterministically spent the whole turn on
# context-gathering (`git diff`, file reads) and ended with no verdict. Three
# pieces of accidental complexity were layered on to work around that single-turn
# budget (all DELETED by #218 — no code path references them any more):
#   1. a bounded `codex exec resume` controller (the pre-#218 resume loop);
#   2. a JSONL event-stream verdict parser that mirrored the comment poller's
#      classifier (drift-prone);
#   3. the INV-55 inline-diff prompt block in autonomous-review.sh (fetch the diff
#      in shell, embed it between nonce'd DIFF_START/DIFF_END markers).
# That machinery (the resume controller, the JSONL verdict-message parser, and the
# inline-diff prompt block) was the root cause of a recurring bug class: #198
# (resume loop ineffective), #209 (turn.failed not retried → opaque `unavailable`),
# #212 (resume dropped per-agent extra-args). All three existed ONLY because review
# was shoehorned onto single-turn `codex exec`.
#
# `codex review` is the purpose-built subcommand for this job: it is natively
# multi-step (re-reads the diff and iterates without a one-turn budget),
# auto-scopes the diff to the PR's merge target (so no `--base` is needed — and
# `[PROMPT]` is mutually exclusive with `--base` anyway), and never strands
# mid-review. Moving the codex REVIEW path to `codex review "<prompt>"` removes
# the machinery and the bug class together.
#
# Verified codex CLI constraints (0.137.0 — do NOT rediscover, see #218):
#   - `codex review "<prompt>"` (no `--base`) is accepted and auto-scopes the diff
#     to the PR's default base (merge target) — the exact review range.
#   - `[PROMPT]` is mutually exclusive with `--base`/`--commit` — so we keep the
#     prompt (it carries the decision-gate rules) and pass NO `--base`.
#   - `codex review` has NO resume (no session/thread/`--json` flag); its output
#     is human-readable text, not a JSONL event stream. So "resume" is a plain
#     re-run of the same command (a fresh review each time), and the old JSONL
#     verdict parser does NOT apply.
#   - `codex review` REJECTS `-m`; pass the model via `-c 'model="..."'`.
#
# LAYER (load-bearing, unchanged contract from INV-51)
# ----------------------------------------------------
# This lib is a codex-specific review-side lib — NOT the generic
# run_agent/resume_agent in lib-agent.sh. The codex DEV path stays on
# `codex exec` (byte-for-byte unchanged); review/GitHub knowledge never leaks
# into the CLI-agnostic plumbing. The wrapper's issue-comment verdict poller
# (lib-review-poll.sh) remains the AUTHORITATIVE verdict gate; this lib only runs
# codex review and parses its stdout as a FALLBACK verdict source.
#
# SCOPE: only the codex review path calls these. claude/agy/kiro/gemini/opencode
# take the single-invocation run_agent path unchanged.

# Max RE-RUNS (a re-run is a fresh `codex review` — there is no thread state) on a
# non-zero / transient-stream exit before giving up and falling back to today's
# behavior (no verdict → `unavailable` via the wrapper's post-window sweep).
# Operator-tunable via CODEX_REVIEW_MAX_RERUNS in autonomous.conf; 0 disables the
# re-run entirely (a single `codex review` invocation, regression-safety knob).
: "${CODEX_REVIEW_MAX_RERUNS:=3}"

# _codex_now_seconds — current wall-clock in epoch seconds. Wrapped in a function
# (not an inline `date +%s`) so the re-run controller's deadline math is
# unit-testable with a deterministic stub. Uses bash's EPOCHSECONDS when present
# (bash ≥ 5.0, the box's shell) and falls back to `date +%s`.
_codex_now_seconds() {
  printf '%s\n' "${EPOCHSECONDS:-$(date +%s)}"
}

# _codex_review_deadline_seconds — the re-run loop's total wall-clock budget in
# seconds, parsed from AGENT_REVIEW_TIMEOUT (the review wall-clock cap, INV-48;
# coreutils-`timeout` units s/m/h/d). This is a SECOND guard on top of the
# per-run _run_with_timeout cap: it bounds N runs × per-run-cap so the re-run loop
# cannot blow far past the review window. An empty / unset / unparseable value
# degrades to the 1h default (3600s) — NEVER unbounded (a 0 or garbage value must
# not silently un-cap the loop).
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

# _codex_review_classify_stdout <stdout-file>
#
# Echoes ONE token (`pass` | `fail`) classifying a `codex review` stdout capture.
# Gate logic the manual `/codex review` skill uses: ANY `[P1]` (a codex
# priority-1 / blocking finding marker) anywhere in the output → `fail`; otherwise
# → `pass`. An empty / missing / unreadable file → `pass` (no `[P1]` ⇒ no blocking
# finding; the wrapper still posts a `Review PASSED` verdict so a comment always
# lands). rc 0 ALWAYS — fail-safe under `set -euo pipefail` (a bare call must not
# abort the wrapper).
#
# Conservative on `[P1]`: a blocking finding wins even if the `[P1]` appears
# inside a quoted code block — a false FAIL only re-queues the PR to dev, whereas
# a missed `[P1]` would let a blocking finding through to merge. So the cheap
# substring match is the safe direction.
_codex_review_classify_stdout() {
  local f="${1:-}"
  if [[ -n "$f" && -f "$f" && -r "$f" ]] && grep -qF '[P1]' "$f" 2>/dev/null; then
    printf 'fail\n'
  else
    printf 'pass\n'
  fi
  return 0
}

# _codex_review_compose_body <verdict> <stdout-file>
#
# Composes the human body the wrapper hands to post-verdict.sh when codex did NOT
# self-post a verdict. The helper does NOT prepend the `Review PASSED` /
# `Review findings:` canonical prefix — post-verdict.sh adds that from its
# pass/fail arg. We supply the summary/findings TEXT and let post-verdict.sh
# guarantee the poller-matchable first line + the attribution trailer.
#
# The body is capped well under post-verdict.sh's 60000-char body limit so a
# pathologically long codex review never trips its `body too long` rejection
# (which would drop the fallback post). rc 0 ALWAYS.
#
#   pass → a one-line passing summary noting codex review ran (no blocking findings).
#   fail → the captured codex review findings text (so the dev agent sees them).
_codex_review_compose_body() {
  local verdict="${1:-pass}" f="${2:-}"
  local cap=50000 text=""
  if [[ -n "$f" && -f "$f" && -r "$f" ]]; then
    text=$(cat -- "$f" 2>/dev/null || true)
  fi
  # Truncate to the cap (character count); append a marker so a reader knows it
  # was cut. ${#text} is a character count — the small slack vs a byte cap is
  # intentional headroom under post-verdict.sh's 60000 limit.
  if [[ ${#text} -gt $cap ]]; then
    text="${text:0:$cap}

[codex review output truncated at ${cap} chars by the wrapper]"
  fi

  if [[ "$verdict" == "fail" ]]; then
    if [[ -z "${text//[[:space:]]/}" ]]; then
      printf '%s\n' "codex review reported a blocking [P1] finding (see the per-agent log for details)."
    else
      printf '%s\n' "$text"
    fi
  else
    if [[ -z "${text//[[:space:]]/}" ]]; then
      printf '%s\n' "codex review found no blocking findings."
    else
      printf '%s\n' "codex review found no blocking ([P1]) findings. Review output:

${text}"
    fi
  fi
  return 0
}

# _codex_review_argv <prompt> <model> — emit, ONE PER LINE, the argv that
# `codex review` is launched with (the part AFTER the `codex` binary). Factored
# out so the exact invocation shape is unit-testable without spawning codex.
#
#   codex review "<prompt>" [-c model="<model>"] <extra-args>
#
# - The PROMPT is the positional `[PROMPT]` (carries the decision-gate rules).
# - The MODEL is passed via `-c 'model="..."'` because `codex review` REJECTS
#   `-m` (verified #218). Omitted when empty.
# - extra-args come from AGENT_DEV_EXTRA_ARGS (the var run_agent's turn-1 path
#   tokenizes; the wrapper aliases the resolved per-agent review extra-args onto
#   it, #212). No resume happens, so AGENT_REVIEW_EXTRA_ARGS is not separately
#   consulted here.
# - NO `--base` ([PROMPT] is mutually exclusive with it; auto-scope is the
#   intended path), NO `-m`, NO `--json`.
_codex_review_argv() {
  local prompt="${1:-}" model="${2:-}"
  local -a extra_args=()
  # Tokenize operator extra-args the same way the agent primitives do. Prefer the
  # shared helper when available (lib-agent.sh::_parse_extra_args), else a plain
  # word-split fallback so this lib is usable in isolation (tests).
  if declare -f _parse_extra_args >/dev/null 2>&1; then
    _parse_extra_args AGENT_DEV_EXTRA_ARGS extra_args
  else
    # shellcheck disable=SC2206
    [[ -n "${AGENT_DEV_EXTRA_ARGS:-}" ]] && extra_args=(${AGENT_DEV_EXTRA_ARGS})
  fi
  printf '%s\n' review "$prompt"
  if [[ -n "$model" ]]; then
    printf '%s\n' -c "model=\"${model}\""
  fi
  local a
  for a in "${extra_args[@]}"; do
    printf '%s\n' "$a"
  done
}

# _run_codex_review <prompt> <model> <stdout-file>
#
# The review-codex launch + bounded re-run controller. Runs `codex review
# "<prompt>"` once under the shared _run_with_timeout (so PGID/timeout/PID-file
# mechanics match the rest of the fleet), capturing codex's CLEAN review stdout
# to <stdout-file>. `codex review` has no resume, so on a non-zero exit (a
# transient turn.failed / stream blip — #209) it RE-RUNS a fresh review, bounded
# by CODEX_REVIEW_MAX_RERUNS AND the AGENT_REVIEW_TIMEOUT-derived wall-clock
# deadline.
#
# Return code: the exit code of the LAST `codex review` invocation, EXCEPT a 124
# (coreutils timeout TERM-expiry) or 137 (--kill-after SIGKILL) from ANY run is
# STICKY — once a run was killed by the per-run wall-clock cap, that rc is
# preserved even if a later re-run exits 0. This is load-bearing for the INV-48
# timeout-veto: the wrapper's post-window sweep maps a no-verdict rc 124/137 to
# `timed-out` (a deciding FAIL that VETOES the merge). The comment poller is the
# authoritative verdict gate after this returns; on exhaustion with no verdict,
# codex is resolved `unavailable` (or `timed-out` for a sticky 124/137).
#
# The CLEAN stdout (only codex review's output, NOT the wrapper's log noise) is
# written to <stdout-file> so the wrapper's stdout→verdict fallback and the
# stream-error drop-reason scan read codex's actual review text.
_run_codex_review() {
  local prompt="$1" model="$2" stdout_file="$3"
  local max="${CODEX_REVIEW_MAX_RERUNS:-3}"
  # Degrade-don't-crash (mirrors _codex_review_deadline_seconds): a NON-NUMERIC
  # operator typo (e.g. CODEX_REVIEW_MAX_RERUNS="three") reaching the
  # `(( reruns >= max ))` arithmetic under `set -euo pipefail` would abort the
  # fan-out subshell with an "unbound variable" error — stranding the issue in
  # `reviewing`. Default any non-(non-negative-integer) value back to 3.
  [[ "$max" =~ ^[0-9]+$ ]] || max=3

  # Build the argv once (prompt + model + extra-args are stable across re-runs).
  local -a _argv=()
  local _line
  while IFS= read -r _line; do _argv+=("$_line"); done < <(_codex_review_argv "$prompt" "$model")

  # _one_codex_review_run — a single `codex review` invocation under the shared
  # timeout. Writes codex's clean stdout to $stdout_file (overwrite, not append —
  # each fresh review supersedes the prior attempt's stdout for classification).
  # Returns codex's exit code. The agent binary is "$AGENT_CMD" (== "codex" in
  # this subshell, the same binary the dev branch invokes), driven through
  # _run_with_timeout so the launcher / setsid / PGID-sidecar / per-run cap all
  # match run_agent. stderr is folded into the capture (`2>&1`, NOT `2>>file`) so a
  # stream-error message the CLI prints to stderr is visible to the drop-reason
  # scan: `2>&1` makes stderr share stdout's single open file description (and
  # offset), so the two streams interleave append-style; `> file 2>>file` would
  # open TWO independent descriptions with independent offsets, and stdout (no
  # O_APPEND) could overwrite stderr bytes appended at EOF — clobbering exactly the
  # stream-error line the scan needs.
  _one_codex_review_run() {
    : > "$stdout_file" 2>/dev/null || true
    _run_with_timeout "$AGENT_CMD" "${_argv[@]}" > "$stdout_file" 2>&1
  }

  local final_rc=0 reruns=0 deadline budget now
  budget=$(_codex_review_deadline_seconds)
  now=$(_codex_now_seconds)
  deadline=$((now + budget))

  _one_codex_review_run || final_rc=$?

  while true; do
    # A clean exit (rc 0) → done; hand off to the wrapper's comment poller +
    # the stdout fallback.
    [[ "$final_rc" -eq 0 ]] && break
    # Bound 1: re-run budget exhausted → fall back (poller resolves unavailable,
    # or timed-out if the sticky rc is 124/137).
    if (( reruns >= max )); then
      [[ "$max" -gt 0 ]] && \
        echo "[lib-review-codex] codex review hit CODEX_REVIEW_MAX_RERUNS=${max} with a non-zero exit (rc ${final_rc}); falling back to the wrapper poller." >&2
      break
    fi
    # Bound 2: wall-clock deadline reached → fall back. Checked AFTER the
    # max-rerun bound so a max=N config does exactly N re-runs when time allows.
    now=$(_codex_now_seconds)
    if (( now >= deadline )); then
      echo "[lib-review-codex] codex review hit the ${budget}s wall-clock deadline (AGENT_REVIEW_TIMEOUT) after ${reruns} re-run(s) with a non-zero exit; falling back to the wrapper poller." >&2
      break
    fi

    reruns=$((reruns + 1))
    echo "[lib-review-codex] codex review exited rc ${final_rc} (likely a transient stream error / turn.failed); re-running a fresh review (re-run ${reruns}/${max}) — INV-62/#209." >&2
    local run_rc=0
    _one_codex_review_run || run_rc=$?

    # Sticky timeout rc: once ANY run was killed by the per-run wall-clock cap
    # (124 = coreutils timeout TERM, 137 = --kill-after SIGKILL), preserve that rc
    # even if a later re-run exits cleanly — the INV-48 veto must not be reset by a
    # subsequent clean-but-still-no-verdict run. KEEP the existing rc only when:
    # final_rc is already a sticky timeout AND this run is not a timeout.
    local final_is_sticky_timeout=false run_is_timeout=false
    [[ "$final_rc" -eq 124 || "$final_rc" -eq 137 ]] && final_is_sticky_timeout=true
    [[ "$run_rc"  -eq 124 || "$run_rc"  -eq 137 ]] && run_is_timeout=true
    if [[ "$run_is_timeout" == true || "$final_is_sticky_timeout" == false ]]; then
      final_rc="$run_rc"
    fi
  done

  return "$final_rc"
}

# ===========================================================================
# INV-62 (#218 / re-scoped from INV-59 #209): codex stream-error drop reason
# ===========================================================================
# `codex review` is human-readable TEXT, not a JSONL event stream — so the old
# JSONL `turn.failed` detector does not apply. When a sustained upstream 5xx
# kills codex review, the CLI prints a stream-disconnect / reconnect message to
# stdout/stderr (captured into the same <stdout-file> _run_codex_review writes)
# and exits non-zero with no verdict. The wrapper resolves it `unavailable`; this
# detector scrapes the stdout capture so the dropped-agent line names a SPECIFIC
# `stream-error` reason rather than a bare opaque `unavailable`. OBSERVABILITY
# ONLY — it does NOT change the INV-40 vote (a server-side 5xx is an infra
# condition, not a code rejection). The retry half of #209 lives in
# _run_codex_review above (a non-zero exit is re-run, bounded).
#
# The function NAMES (_classify_codex_drop_reason / _codex_drop_reason_phrase) and
# their rc-0-always contract are preserved so the wrapper's drop-reason loop is
# unchanged — only the SOURCE they scan changed from the JSONL log to the
# review-stdout capture.

# _codex_review_has_stream_error <stdout-file>
#
# rc 0 iff codex review's stdout/stderr capture shows a STREAM/SERVER error
# signal — the `stream disconnected before completion` phrase (the upstream-5xx
# shape) OR a `Reconnecting... N/M` reconnect-ladder line. rc 1 otherwise —
# including a clean review with findings, an empty/missing/unreadable file
# (fail-safe — the wrapper runs under `set -euo pipefail`, so this MUST NOT
# abort), or a `[P1]`-bearing genuine review.
_codex_review_has_stream_error() {
  local f="${1:-}"
  [[ -n "$f" && -f "$f" && -r "$f" ]] || return 1
  grep -qiE 'stream disconnected before completion|Reconnecting\.\.\. [0-9]+/[0-9]+' "$f" 2>/dev/null
}

# _classify_codex_drop_reason <stdout-file>
#
# Scrape a `codex review` stdout capture for a stream/server error signal. Echoes
# ONE token on stdout (rc 0 ALWAYS — fail-safe under `set -euo pipefail`, mirrors
# _classify_agy_drop_reason / _classify_kiro_drop_reason):
#
#   stream-error[:N/M]
#       — the capture shows a stream-disconnect error. The ":N/M" suffix is the
#         HIGHEST reconnect-ladder depth seen (`Reconnecting... N/M`). Appended
#         only when the ladder is present.
#   "" (empty)
#       — no stream-error signal (the caller keeps the bare `unavailable`). A
#         clean review or a genuine `[P1]` review yields empty — NO over-claim.
_classify_codex_drop_reason() {
  local f="${1:-}"
  [[ -n "$f" && -f "$f" && -r "$f" ]] || return 0

  _codex_review_has_stream_error "$f" || return 0

  # Stream error present. Extract the highest reconnect-ladder depth (the `N` in
  # `Reconnecting... N/M`) when the capture shows the ladder. A no-ladder capture
  # makes the first grep exit 1; under `set -o pipefail` the pipeline returns
  # non-zero, so `|| true` guards the bare assignment from aborting the function
  # before its `return 0` (the rc-0-always contract).
  local ladder
  ladder=$(grep -oiE 'Reconnecting\.\.\. [0-9]+/[0-9]+' "$f" 2>/dev/null \
    | grep -oE '[0-9]+/[0-9]+' | sort -t/ -k1 -n | tail -1) || true

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
#       → "stream-error (upstream 5xx; exhausted 5/5 stream reconnects)"
#   stream-error
#       → "stream-error (upstream 5xx; codex review stream disconnected)"
_codex_drop_reason_phrase() {
  local token="${1:-}"
  case "$token" in
    stream-error:*)
      local depth="${token#stream-error:}"
      printf 'stream-error (upstream 5xx; exhausted %s stream reconnects)\n' "$depth"
      ;;
    stream-error)
      printf 'stream-error (upstream 5xx; codex review stream disconnected)\n'
      ;;
    *)
      # Empty or unknown token → empty phrase.
      ;;
  esac
  return 0
}
