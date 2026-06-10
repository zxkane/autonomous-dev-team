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

# _codex_review_argv <out-array-name> <prompt> <model> — populate the named bash
# ARRAY with the argv that `codex review` is launched with (the part AFTER the
# `codex` binary). Uses a nameref OUT-ARRAY (mirroring lib-agent.sh::_parse_extra_args)
# so the prompt is carried as ONE array element no matter what it contains.
#
#   codex review "<prompt>" [-c model="<model>"] <extra-args>
#
# CRITICAL (#218 review finding 1): the PROMPT built by build_review_prompt is a
# large MULTI-LINE heredoc. An earlier draft emitted the argv one-element-per-line
# (`printf '%s\n' …`) and the caller rebuilt it with `while read -r`, which SPLIT
# the multi-line prompt at every `\n` into many positional args — `codex review`
# would then receive dozens of bogus positionals instead of one prompt and fail
# before reviewing. A nameref out-array keeps every element intact (newlines and
# all) with no serialize/parse round-trip, so the prompt is exactly one argv slot.
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
  local -n _cra_out="$1"
  local prompt="${2:-}" model="${3:-}"
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
  _cra_out=(review "$prompt")
  [[ -n "$model" ]] && _cra_out+=(-c "model=\"${model}\"")
  # Append each extra-arg as its own element (no word-splitting — already
  # tokenized). An empty array appends nothing (bash 4.4+, the box's 5.x shell),
  # matching how run_agent splices its own "${extra_args[@]}" inline.
  _cra_out+=("${extra_args[@]}")
}

# _codex_review_prepare_worktree <pr_branch> <dest_dir> — establish the PR-branch
# CHECKOUT that `codex review` auto-scopes its diff against (#218 review finding 3).
#
# WHY (load-bearing): `codex review` has no `--base`/PR-number flag — it diffs the
# CURRENT working tree's HEAD against its merge-base. The review wrapper runs from
# `PROJECT_DIR`, which the dispatcher keeps synced to `main`. So if `codex review`
# ran from `PROJECT_DIR` it would review `main`'s (empty) diff, NOT the PR's — a
# regression from the deleted INV-55 path, which fetched `gh pr diff <PR_NUMBER>`
# (PR-scoped regardless of cwd). The fix: check the PR branch out into a throwaway
# worktree and run `codex review` from THERE, so its auto-scope resolves to the
# PR's real diff (origin/main…<pr_branch>).
#
# Checks the PR branch out into a throwaway worktree at the AUTHORITATIVE current
# tip, then `git worktree add --detach` at exactly that commit. rc 0 on success (the
# dest_dir is a usable PR-branch checkout AT THE RIGHT COMMIT); rc 1 on any failure
# (no pr_branch, not a git repo, fetch failed when a remote exists, no resolvable
# ref, add failed) — the caller then FAILS CLOSED (no vote), never crashing.
# `--detach` (not a branch checkout) avoids "branch already checked out" collisions
# with the dev worktree / a sibling codex agent.
#
# #218 review finding (stale-ref hazard): `git fetch origin <branch>` updates
# FETCH_HEAD but does NOT necessarily update the remote-tracking ref
# `origin/<branch>` (that requires a configured refspec / a bare `git fetch origin`).
# An earlier draft preferred `origin/<branch>` over FETCH_HEAD and fell through to a
# (possibly leftover) FETCH_HEAD even when the fetch FAILED — so it could check out
# a STALE tip and let `codex review` vote on the wrong diff, defeating the
# fail-closed PR-scoping invariant. The fix:
#   - When the repo HAS an `origin` remote (the production path): the fetch is
#     MANDATORY — a fetch FAILURE is a HARD prepare failure (return 1, → fail closed),
#     never a fall-through to a stale ref. On success, check out exactly the
#     just-fetched commit via FETCH_HEAD (authoritative for "the tip I fetched
#     NOW") — NOT `origin/<branch>`, which the targeted fetch may have left stale.
#   - When there is NO `origin` (a local-only repo, e.g. the unit-test fixture):
#     resolve the branch from a LOCAL ref (no remote to be stale against).
_codex_review_prepare_worktree() {
  local pr_branch="${1:-}" dest_dir="${2:-}"
  [[ -n "$pr_branch" && -n "$dest_dir" ]] || return 1
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1

  local _commit=""
  if git remote get-url origin >/dev/null 2>&1; then
    # Production path: a remote exists, so the PR tip lives on origin. The fetch is
    # MANDATORY — a failure means we cannot trust ANY local ref to be the current
    # PR tip, so fail closed (do NOT fall through to a possibly-stale ref). On
    # success, FETCH_HEAD is exactly the commit we just fetched for THIS branch.
    git fetch --quiet origin "$pr_branch" 2>/dev/null || return 1
    _commit=$(git rev-parse --verify --quiet 'FETCH_HEAD^{commit}' 2>/dev/null) || return 1
  else
    # No remote (local-only repo / test fixture): resolve a LOCAL ref. There is no
    # remote-tracking ref to be stale against, so a local/branch ref is authoritative.
    local _ref
    for _ref in "refs/heads/${pr_branch}" "$pr_branch"; do
      _commit=$(git rev-parse --verify --quiet "${_ref}^{commit}" 2>/dev/null) && break
      _commit=""
    done
  fi
  [[ -n "$_commit" ]] || return 1
  # `--detach` at exactly the resolved commit (not a branch ref) — avoids "branch
  # already checked out" collisions with the dev worktree / a sibling codex agent.
  git worktree add --detach --quiet "$dest_dir" "$_commit" 2>/dev/null || return 1
}

# _codex_review_cleanup_worktree <dest_dir> — remove a worktree created by
# _codex_review_prepare_worktree. Best-effort, rc 0 always (a cleanup failure must
# never abort the wrapper); `--force` because `codex review` may have left
# scratch files in the tree, and a final `git worktree prune` clears the admin ref.
_codex_review_cleanup_worktree() {
  local dest_dir="${1:-}"
  [[ -n "$dest_dir" ]] || return 0
  git worktree remove --force "$dest_dir" 2>/dev/null || rm -rf "$dest_dir" 2>/dev/null || true
  git worktree prune 2>/dev/null || true
  return 0
}

# _run_codex_review <prompt> <model> <stdout-file> [<pr-workdir>]
#
# The review-codex launch + bounded re-run controller. Runs `codex review
# "<prompt>"` once under the shared _run_with_timeout (so PGID/timeout/PID-file
# mechanics match the rest of the fleet), capturing codex's CLEAN review stdout
# to <stdout-file>. `codex review` has no resume, so on a non-zero exit (a
# transient turn.failed / stream blip — #209) it RE-RUNS a fresh review, bounded
# by CODEX_REVIEW_MAX_RERUNS AND the AGENT_REVIEW_TIMEOUT-derived wall-clock
# deadline.
#
# <pr-workdir> (#218 finding 3): the directory `codex review` runs IN — a PR-branch
# checkout (a worktree the caller prepared via _codex_review_prepare_worktree) so
# `codex review`'s auto-scoped diff resolves to the PR, not the wrapper's `main`
# checkout. When non-empty + a directory, the invocation `cd`s there (in a subshell,
# so the wrapper's own cwd is untouched); when empty/missing, it runs from the
# current cwd and logs a loud warning (degraded — the diff may be wrong/empty, but
# the wrapper does not crash).
#
# Return code: the exit code of the LAST `codex review` invocation. A 124
# (coreutils timeout TERM-expiry) or 137 (--kill-after SIGKILL) from ANY run STOPS
# the re-run loop IMMEDIATELY and is returned — the loop is for transient stream
# errors, not the per-run timeout cap, so a wall-clock-capped run never triggers a
# re-run (#218 review finding 4; see the loop comment below). Because a timeout
# terminates the loop, no later run can overwrite the veto rc, so the 124/137 is
# returned without any further re-runs. This is load-bearing for the INV-48
# timeout-veto: the wrapper's post-window sweep maps a no-verdict rc 124/137 to
# `timed-out` (a deciding FAIL that VETOES the merge). The comment poller is the
# authoritative verdict gate after this returns; on non-timeout exhaustion with no
# verdict, codex is resolved `unavailable` (or `timed-out` for a 124/137 return).
#
# The CLEAN stdout (only codex review's output, NOT the wrapper's log noise) is
# written to <stdout-file> so the wrapper's stdout→verdict fallback and the
# stream-error drop-reason scan read codex's actual review text.
_run_codex_review() {
  local prompt="$1" model="$2" stdout_file="$3" pr_workdir="${4:-}"
  local max="${CODEX_REVIEW_MAX_RERUNS:-3}"
  # #218 finding 3: `codex review` must run from a PR-branch checkout so its
  # auto-scoped diff is the PR's, not the wrapper's `main` PROJECT_DIR. The caller
  # passes a prepared worktree dir; if it is missing/not-a-dir we run from cwd and
  # warn LOUDLY (degraded — the verdict may be for the wrong/empty diff, but the
  # wrapper does not crash; the rc-0 gate + comment poller still apply downstream).
  local _cwd_ok=false
  if [[ -n "$pr_workdir" && -d "$pr_workdir" ]]; then
    _cwd_ok=true
  else
    echo "[lib-review-codex] WARNING: no PR-branch worktree for codex review (pr_workdir='${pr_workdir}') — running from the current checkout; the auto-scoped diff may not be the PR's (INV-62/#218)." >&2
  fi
  # Degrade-don't-crash (mirrors _codex_review_deadline_seconds): a NON-NUMERIC
  # operator typo (e.g. CODEX_REVIEW_MAX_RERUNS="three") reaching the
  # `(( reruns >= max ))` arithmetic under `set -euo pipefail` would abort the
  # fan-out subshell with an "unbound variable" error — stranding the issue in
  # `reviewing`. Default any non-(non-negative-integer) value back to 3.
  [[ "$max" =~ ^[0-9]+$ ]] || max=3

  # Build the argv once (prompt + model + extra-args are stable across re-runs).
  # Populate a real array via the nameref builder — NO newline serialize/parse
  # round-trip, so a multi-line prompt stays ONE argv element (#218 finding 1).
  local -a _argv=()
  _codex_review_argv _argv "$prompt" "$model"

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
    # Run `codex review` from the PR-branch worktree (in a SUBSHELL so the `cd`
    # never leaks to the wrapper's cwd) when one was prepared; else from cwd
    # (degraded path, already warned above). The stdout-capture path is absolute
    # (the wrapper builds it under /tmp), so the cd does not misplace it.
    if [[ "$_cwd_ok" == true ]]; then
      ( cd "$pr_workdir" && _run_with_timeout "$AGENT_CMD" "${_argv[@]}" ) > "$stdout_file" 2>&1
    else
      _run_with_timeout "$AGENT_CMD" "${_argv[@]}" > "$stdout_file" 2>&1
    fi
  }

  # The loop tracks the LAST invocation's rc (`last_run_rc`) — that, NOT the return
  # value, drives the continue/break decision: the loop re-runs ONLY while the most
  # recent run failed with a NON-timeout error (a transient stream blip, #209) and
  # stops the instant a run exits 0 OR was wall-clock-capped (124/137). `final_rc`
  # mirrors `last_run_rc` and is the RETURN value — the rc of the run that
  # TERMINATED the loop, which feeds the INV-48 veto when that run was a timeout.
  #
  # #218 review finding 4 — why the loop must key on `last_run_rc`, not the return
  # value: an earlier draft made the return value sticky on 124/137 AND used it as
  # the loop's success break (`[[ $final_rc -eq 0 ]]`). A turn-1 timeout (124, then
  # held sticky) followed by a CLEAN re-run kept that value at 124, so the loop never
  # broke and kept re-running to CODEX_REVIEW_MAX_RERUNS — each clean re-run a FRESH
  # `codex review` that could self-post a verdict, breaking INV-62's "exactly one
  # verdict" (duplicate comments); and AGENT_LAUNCH_RC stayed 124 so the rc-0 stdout
  # fallback was also refused. Breaking the loop on the LAST run's rc fixes it: a
  # timeout terminates the loop immediately, so no later run can ever overwrite the
  # veto rc — the stickiness is now structural (loop exit), not a reconciliation step.
  #
  # A wall-clock-cap kill (124/137) STOPS the loop immediately: the re-run loop
  # exists for TRANSIENT stream errors, not for the per-run timeout cap — re-running
  # a capped run is pointless (the cap will refire) and risks the partial-review /
  # duplicate-verdict hazard above. A timeout is a deciding veto (INV-48), not a
  # blip, so it returns 124/137 with ZERO further re-runs.
  local final_rc=0 last_run_rc=0 reruns=0 deadline budget now
  budget=$(_codex_review_deadline_seconds)
  now=$(_codex_now_seconds)
  deadline=$((now + budget))

  _one_codex_review_run || last_run_rc=$?
  final_rc="$last_run_rc"

  while true; do
    # Stop on a clean run (verdict produced — hand off to the poller + the stdout
    # fallback) OR on a wall-clock-cap kill (a deciding INV-48 veto, not a blip).
    [[ "$last_run_rc" -eq 0 ]] && break
    [[ "$last_run_rc" -eq 124 || "$last_run_rc" -eq 137 ]] && break
    # Bound 1: re-run budget exhausted → fall back (poller resolves unavailable).
    if (( reruns >= max )); then
      [[ "$max" -gt 0 ]] && \
        echo "[lib-review-codex] codex review hit CODEX_REVIEW_MAX_RERUNS=${max} with a non-zero exit (rc ${last_run_rc}); falling back to the wrapper poller." >&2
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
    echo "[lib-review-codex] codex review exited rc ${last_run_rc} (likely a transient stream error / turn.failed); re-running a fresh review (re-run ${reruns}/${max}) — INV-62/#209." >&2
    last_run_rc=0
    _one_codex_review_run || last_run_rc=$?
    final_rc="$last_run_rc"
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
