#!/bin/bash
# adapters/codex.sh — Codex (OpenAI Codex CLI) adapter ([INV-75]).
#
# All codex-specific behavior lives here:
#   - DEV-mode argv assembly (dev-new / dev-resume) via `codex exec [--json]`,
#     with the CLI-minted thread_id captured to a sidecar for resume;
#   - the REVIEW lane (`codex review "<prompt>"` from a PR-branch worktree, no
#     resume, `no-worktree` rc-70 fail-closed) and its bounded re-run controller,
#     stdout verdict classifier, prompt-echo malformed guard, and stream-error /
#     clap-rejection drop-reason scrapers (INV-62/INV-59/INV-73, formerly
#     lib-review-codex.sh — moved here VERBATIM below the dev section).
#
# Session model: codex mints its own thread_id per `codex exec` invocation (it
# does NOT accept a caller-provided id). We capture it from `--json` stdout via
# _codex_capture_thread into a sidecar keyed by the dispatcher's session_id, and
# feed it back to `codex exec resume <thread_id>` on resume. `codex review` has
# NO session (Clause M4) — it never resumes.
#
# PROMPT CHANNEL: dev mode feeds the prompt on stdin (`codex exec -`, INV-34).
# The review lane is the ONE Clause A2 carve-out — `codex review` has no
# stdin-prompt mode and takes the (short) gate prompt as its positional [PROMPT].
#
# PRECONDITION: sourced by lib-agent.sh (dev dispatch + capture helpers) and by
# the lib-review-codex.sh compat shim + lib-agent-smoke.sh (review lane +
# drop-reason fns), AFTER lib-agent.sh's shared primitives (_run_with_timeout,
# pid_dir_for_project, _parse_extra_args, preflight_agent_binary) are defined.

# adapter_invoke_codex <mode> <session_id> <prompt> <model> <session_name>
#   mode ∈ { dev-new, dev-resume }  (review goes through _run_codex_review below)
#
# Returns PIPESTATUS[1] — codex's rc (printf at [0] is always 0; the capture awk
# at [2] is well-behaved). Stdin marker `-` reads the prompt from stdin (INV-34);
# `--json` streams JSONL events incl. `thread.started` for thread-id capture.
adapter_invoke_codex() {
  local mode="$1" session_id="$2" prompt="$3" model="${4:-}" session_name="${5:-}"
  local extra_args=()
  if [[ "$mode" == "dev-resume" ]]; then
    _parse_extra_args AGENT_REVIEW_EXTRA_ARGS extra_args
  else
    _parse_extra_args AGENT_DEV_EXTRA_ARGS extra_args
  fi

  if [[ "$mode" == "dev-resume" ]]; then
    # Resume the captured thread; fall back to a fresh session if the sidecar is
    # missing (run_agent crashed before thread.started, or resume w/o a prior run).
    local _codex_tid
    if _codex_tid=$(_codex_thread_id "$session_id"); then
      printf '%s' "$prompt" \
        | _run_with_timeout "$AGENT_CMD" exec resume "$_codex_tid" --json \
          ${model:+--model "$model"} \
          "${extra_args[@]}" \
          - \
        | _codex_capture_thread "$session_id"
      return "${PIPESTATUS[1]}"
    else
      echo "[lib-agent] no captured codex thread_id for session $session_id; starting a new codex session" >&2
      run_agent "$session_id" "$prompt" "$model" "$session_name"
      return $?
    fi
  fi

  # dev-new: fresh `codex exec --json`, capturing the minted thread_id.
  printf '%s' "$prompt" \
    | _run_with_timeout "$AGENT_CMD" exec --json \
      ${model:+--model "$model"} \
      "${extra_args[@]}" \
      - \
    | _codex_capture_thread "$session_id"
  return "${PIPESTATUS[1]}"
}

# ---------------------------------------------------------------------------
# Codex thread-id capture/recall — relocated verbatim from lib-agent.sh.
#
# Codex `exec` mints its own thread (UUID) per invocation and does NOT accept a
# caller-provided ID. To resume correctly we capture the CLI-assigned thread_id
# after run_agent and feed it into `codex exec resume <id>`. Persisted in a
# sidecar under pid_dir_for_project() (mode 0700) keyed by the session_id.
# ---------------------------------------------------------------------------

_codex_thread_file() {
  local session_id="$1"
  local pid_dir
  pid_dir=$(pid_dir_for_project) || return 1
  printf '%s/codex-thread-%s\n' "$pid_dir" "$session_id"
}

# _codex_capture_thread <session_id>
# Pipeline filter: streams stdin → stdout unchanged and, as a side effect, writes
# the first observed thread_id (from the `thread.started` JSONL event) to the
# sidecar. Robust to thread.started not being line 1, a crash before any id, and
# re-runs against the same session_id (overwrite, not append). awk (not jq) — jq
# is not a hard dep; codex `--json` emits one event per line.
_codex_capture_thread() {
  local session_id="$1"
  local thread_file
  thread_file=$(_codex_thread_file "$session_id") || { cat; return 0; }
  awk -v out="$thread_file" '
    BEGIN {
      prefix = "\"thread_id\":\""
    }
    {
      print
      fflush()
      if (!captured && /"type":"thread.started"/) {
        if (match($0, /"thread_id":"[a-f0-9-]+"/)) {
          tid = substr($0, RSTART + length(prefix), RLENGTH - length(prefix) - 1)
          # CWE-59 symlink defense: refuse to clobber an existing symlink.
          cmd = "test -L \"" out "\" && exit 0; printf \"%s\\n\" \"" tid "\" > \"" out "\""
          system(cmd)
          captured = 1
        }
      }
    }'
}

# _codex_thread_id <session_id>
# Read + validate the captured thread_id. Echo id + rc 0 on hit; nothing + rc 1
# on miss / malformed / symlink. The UUID-only regex protects the downstream
# `codex exec resume <id>` invocation.
_codex_thread_id() {
  local session_id="$1"
  local thread_file tid
  thread_file=$(_codex_thread_file "$session_id") || return 1
  [[ -L "$thread_file" ]] && return 1
  [[ -f "$thread_file" ]] || return 1
  tid=$(head -n1 "$thread_file" 2>/dev/null)
  [[ "$tid" =~ ^[a-f0-9-]+$ ]] || return 1
  printf '%s\n' "$tid"
}

# ===========================================================================
# REVIEW LANE (INV-62/INV-59/INV-73) — relocated VERBATIM from lib-review-codex.sh.
# Below this line is the unmodified former lib-review-codex.sh body (its shebang +
# top file-comment removed; the function bodies are byte-for-byte unchanged).
# ===========================================================================
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

# ===========================================================================
# INV-73 (#252): codex review prompt-echo / startup-trace malformed-output guard
# ===========================================================================
# `codex review` sometimes exits rc 0 but writes its OWN prompt + CLI startup
# trace to stdout instead of a review — the startup banner (`OpenAI Codex vX.Y.Z`
# / a `workdir:`+`model:`+`provider:` header) followed by the verbatim review
# prompt (the inlined decision-gate rules, the `gh issue view` comment-history
# dump, the issue body), truncated at the wrapper's char cap, with NO analysis and
# NO verdict. Because the prompt text itself contains the literal `[P1]` (the
# instruction "Prefix EACH blocking finding with `[P1]`" + quoted prior-round
# findings), the bare `_codex_review_classify_stdout` `[P1]` scan matched the echo
# and posted a phantom blocking FAIL — vetoing an otherwise-clean PR on every round
# (a non-self-terminating dev↔review loop). This is a DISTINCT fourth failure mode
# from #209 (non-zero/stream → retry), #246 (timeout 124/137 → UNAVAILABLE), and
# #247 (post-failed): clean exit (rc 0), well-formed-LOOKING but bogus stdout.

# _codex_review_stdout_is_malformed <stdout-file>
#
# rc 0 iff the capture is codex's prompt-echo / startup-trace rather than a real
# review; rc 1 otherwise (a genuine review — with or without `[P1]` — an empty /
# missing / unreadable / short capture, or any text that is plausibly a review).
# rc 1 is the FAIL-SAFE direction: a normal review must NEVER be mis-flagged
# malformed (that would drop a real verdict), so the signals key on the echo/trace
# STRUCTURE, not on a bare keyword that a genuine review could legitimately mention.
# rc 0/1 only — never aborts under `set -euo pipefail` (a bare call is fail-safe).
#
# Signal 0 (checked FIRST, issue #481 review round 2): a genuine `codex review`
# TURN-MARKER capture — `<CLI header> → <user marker> → <echoed prompt> →
# <reasoning/tool-trace turns> → <codex marker(s)> → <final response>` — ALSO
# opens with the exact banner/header structure signal 1 below matches (the
# prompt IS echoed verbatim as the `user` turn's content, by construction of
# `_run_codex_review`'s capture). Without this signal, EVERY such capture —
# including one whose final `codex` turn is a genuine, fully-formed review —
# was misclassified `malformed` by signal 1 before ever reaching signal 0's
# check, making the codex-stdout-fallback route ([INV-132], `AGENT_VERDICT_
# SOURCES[i]=="codex-stdout-fallback"`) permanently unreachable for any real
# review shaped this way — the round-2 review finding this signal closes.
# `_codex_review_strip_prompt_echo` locates the SAME structural boundary
# ([INV-132]'s own turn-marker parser): a validated header, the FIRST `user`
# marker after it, the LAST `codex` marker after THAT. If all three are
# present AND the text strictly after the last `codex` marker is non-empty
# (a real final-response turn exists), this is a completed turn-marker
# review, never malformed — regardless of what its leading region contains.
# A capture with the turn markers but NO text after the last `codex` marker
# (e.g. the trace was captured mid-turn) is NOT covered by this signal and
# falls through to signals 1-3 unchanged.
#
# Three cheap, robust signals below (ANY one is sufficient — defense in depth):
#   1. Banner/header — the codex startup banner is the capture's FIRST non-empty
#      line (`^OpenAI Codex v`), OR a `workdir:`+`model:`+`provider:` triple appears
#      in the CONTIGUOUS LEADING HEADER REGION (the run of lines from the top up to
#      the first blank / ``` fence / `## ` heading / `[P1]` finding line). Keyed on
#      the ACTUAL launch-trace STRUCTURE, NOT on the strings appearing anywhere near
#      the top: a real review writes review TEXT first, so a banner/header it QUOTES
#      in a fenced block sits AFTER review prose (outside the leading region) and is
#      NOT a first non-empty line — so it does not match (2nd-round review finding
#      [P1] / #252: a `head -n 12` scan dropped a genuine `[P1]` review that quoted
#      the banner/header fixture near the top).
#   2. Prompt-echo — the capture reproduces the wrapper's own prompt SCAFFOLDING in
#      the ECHO REGION: ≥2 DISTINCT prompt markers that are UNFENCED and in the
#      LEADING prefix (before any genuine finding). An ECHO reproduces the WHOLE
#      prompt VERBATIM at the TOP as bare structure; a real review writes findings
#      and at most QUOTES prompt text inside ``` fences or AFTER its findings. So the
#      markers are counted only after (a) stripping fenced code blocks and (b)
#      truncating at the first `[P1]`/`[P2]`/`[P3]` finding line — see `_echo_region`.
#      The markers: the `## Step 0:` / `## Step 0.5:` MANDATORY-PRE-REVIEW headings,
#      the `## You are running inside codex review` header, the `## Review Checklist`
#      / `## Acceptance Criteria Verification` / `## Review Process` headings, the
#      `Prefix EACH blocking finding` instruction, or the `You are reviewing PR #…
#      for issue #…` opener. Three review findings ([P1]) drove this from a bare
#      substring to here: 1st (#253) — a single quoted marker dropped a review →
#      require ≥2; 3rd (#252, session fdc9ff60) — ≥2 markers ANYWHERE still dropped a
#      review that QUOTED two prompt headings in a fenced block → restrict to the
#      unfenced leading echo region.
#   3. Truncated-no-verdict — the capture is at/near the char cap AND shows no
#      recognizable verdict / conclusion structure (`Review PASSED`/`Review
#      findings:`/a `Summary:`/`Findings` heading) — cut mid-dump with no conclusion.
_codex_review_stdout_is_malformed() {
  local f="${1:-}"
  [[ -n "$f" && -f "$f" && -r "$f" ]] || return 1

  # Signal 0: a genuine turn-marker capture with real content after the LAST
  # `codex` marker is NEVER malformed — checked before signals 1-3 so a
  # completed turn-marker review's OWN header/echo (which trivially satisfies
  # signal 1/2's structural match) can never misclassify it. Fail-safe: if
  # the strip helper found no header/no markers/no post-marker text, it
  # echoes the ORIGINAL capture unchanged, so the inequality below is false
  # and this signal is silently skipped (falls through to signals 1-3).
  local _turn_stripped
  _turn_stripped=$(_codex_review_strip_prompt_echo "$f") || _turn_stripped=""
  if [[ -n "$_turn_stripped" ]]; then
    local _turn_original
    _turn_original=$(cat -- "$f" 2>/dev/null) || _turn_original=""
    [[ "$_turn_stripped" != "$_turn_original" ]] && return 1
  fi

  # Banner/header signals 1a/1b match ONLY the ACTUAL startup header — the codex
  # launch trace at the very top of the capture — NOT arbitrary lines that merely
  # appear near the top. 2nd-round review finding [P1] (#252, session 5705a2d7): an
  # earlier draft scanned the first 12 lines (`head -n 12`) for the banner / the
  # workdir+model+provider triple, so a GENUINE review whose finding QUOTES the
  # banner/header fixture in a fenced code block near the top (banner lines land
  # within the first 12, but AFTER review prose) was mis-flagged `malformed` before
  # the `[P1]` scan — dropping a real blocking review. The fix keys on STRUCTURE:
  # the real trace's banner is the capture's FIRST non-empty line, and its
  # workdir/model/provider lines form a CONTIGUOUS leading header block; a quoted
  # block is always preceded by review prose (a heading, a `[P1]`/finding line, a
  # fence). So we extract the LEADING HEADER REGION — the run of lines from the top
  # up to (not including) the first blank line, fence, or markdown heading — and
  # match the banner/header ONLY within it.
  #
  # _leading_region: lines [1..) until the first terminator (blank / ``` fence /
  # `## ` heading / a `[P1]`/`[P2]`/`[P3]` finding line). The real launch header is
  # an unbroken run of `key: value` (and `----` separator) lines right at the start,
  # so it survives intact; a review whose first lines are prose terminates the region
  # before any quoted banner block is reached.
  # FINDING-BOUNDARY patterns — a line that BEGINS a genuine review FINDING (so the
  # prompt-echo region ends there). 4th-round review finding [P1] (#252, session
  # 6000c69c): the wrapper's own posted finding format is NUMBERED + BOLD
  # (`1. **[P1] …`), not a bare leading `[P1]`, so a boundary that only matched
  # `^[[:space:]]*\[P[123]\]` let a numbered/bullet/JSON finding's later quoted prompt
  # markers stay in the region → false `malformed`. The three boundary alternations
  # (inlined IDENTICALLY in the _leading_region and _echo_region awks below) recognize
  # the finding forms the wrapper documents/posts and a review emits:
  #   (a) direct / numbered / bulleted / bold: `[P1]`, `1. [P1]`, `1) **[P1]`, `- [P1]`,
  #       `* **[P1]`, `> [P1]` — a `[P1/2/3]` token after ONLY list/number/bold/quote
  #       scaffolding. NOT the prompt's `Prefix EACH blocking finding with [P1]`
  #       instruction (prose before the token, so the `^…\[P[123]\]` anchor misses it —
  #       DET-24), and NOT a `## Step…` heading.
  #   (b) JSON key:   a `"severity"`/`"priority"` key line.
  #   (c) JSON value: a quoted `P1`/`P2`/`P3` value (`"P1"`, `'P1'`).
  # NB: the boundary is inlined as LITERAL awk regexes, NOT passed via `awk -v` — `-v`
  # applies C-style escape processing to the value, which strips the `\[`/`\]`/`\*`
  # backslashes and breaks the literal-bracket `\[P[123]\]` match (observed: every
  # finding line then silently fails to bound the region).
  local _leading_region
  _leading_region=$(awk '
    NR==1 && $0=="" { next }                              # skip a single leading blank
    /^[[:space:]]*$/ { exit }                             # blank line → end of header region
    /^[[:space:]]*```/ { exit }                           # code fence → review body starts
    /^[[:space:]]*#/ { exit }                             # markdown heading → review body
    /^[[:space:]]*([0-9]+[.)][[:space:]]*)?([-*>][[:space:]]*)*(\*\*[[:space:]]*)?\[P[0123]\]/ { exit }  # finding (a) — includes P0 (#449 severity ratchet)
    /"(severity|priority)"[[:space:]]*:/ { exit }         # finding (b) JSON key
    /["'"'"'[:space:]]P[0123]["'"'"']/ { exit }            # finding (c) JSON value
    { print }
  ' "$f" 2>/dev/null) || _leading_region=""

  # Signal 1a: the codex startup banner is the FIRST non-empty line (the launch
  # trace always opens with it). A review that merely quotes `OpenAI Codex v…`
  # later (in a fenced block) never has it as the first non-empty line.
  local _first_nonempty
  _first_nonempty=$(awk 'NF{print; exit}' "$f" 2>/dev/null) || _first_nonempty=""
  if [[ "$_first_nonempty" =~ ^OpenAI\ Codex\ v[0-9] ]]; then
    return 0
  fi
  # Signal 1b: the `workdir:`+`model:`+`provider:` triple appears in the CONTIGUOUS
  # LEADING HEADER REGION (all three, as the launch trace emits them), NOT merely
  # somewhere in the first N lines. A quoted header block inside a review body sits
  # AFTER the prose that terminated the leading region, so it is not in it.
  if [[ -n "$_leading_region" ]] \
     && grep -qiE '^workdir:' <<<"$_leading_region" 2>/dev/null \
     && grep -qiE '^model:' <<<"$_leading_region" 2>/dev/null \
     && grep -qiE '^provider:' <<<"$_leading_region" 2>/dev/null; then
    return 0
  fi
  # Signal 2: the prompt's SCAFFOLDING reproduced — structural prompt artifacts a
  # review never emits. An ECHO reproduces the WHOLE prompt VERBATIM at the TOP, so
  # MANY distinct standalone markers co-occur as bare document structure; a real
  # review writes its findings, and at most QUOTES prompt text (inside ``` fences or
  # after its findings). We require ≥2 distinct markers, but counted ONLY in the
  # ECHO REGION — NOT anywhere in stdout.
  #
  # Three review findings ([P1]) walked this signal from a bare substring to here:
  #   - 1st (#253): a bare single-marker substring match dropped a review quoting ONE
  #     marker → require ≥2 distinct markers.
  #   - 2nd (#253, session 5705a2d7): the banner/header (signal 1) matched quoted
  #     lines → keyed signal 1 to the first-non-empty-line / contiguous-leading region.
  #   - 3rd (#252, session fdc9ff60): ≥2 markers ANYWHERE still false-positived on a
  #     review that QUOTES two prompt headings in a fenced code block (natural when
  #     reviewing THIS PR's detector/fixture/tests) → the markers must be in the
  #     ECHO region: UNFENCED and in the LEADING prompt prefix (before any finding).
  #
  # _echo_region: the capture with (a) fenced code blocks STRIPPED (a review quotes
  # prompt text inside ``` fences — an echo emits it bare, unfenced), and (b)
  # truncated at the FIRST genuine `[P1]`/`[P2]`/`[P3]` finding line (an echo
  # reproduces the prompt BEFORE any finding; a review's findings come first, so its
  # later prompt-quotes fall outside this region). What remains is the unfenced
  # leading prefix — where a real echo's prompt structure lives and a review's quotes
  # do not. The awk toggles `infence` on ``` lines (dropping them and their contents)
  # and exits at the first finding line.
  # The finding boundary here is the SAME set inlined in _leading_region above
  # (direct/numbered/bullet/bold, JSON key, JSON value) — gated on `!infence` so a
  # `[P1]` inside a fenced quote does NOT prematurely end the region (a fenced
  # finding-quote is stripped, not treated as the boundary).
  local _echo_region
  _echo_region=$(awk '
    !infence && /^[[:space:]]*([0-9]+[.)][[:space:]]*)?([-*>][[:space:]]*)*(\*\*[[:space:]]*)?\[P[0123]\]/ { exit }  # finding (a) — includes P0 (#449)
    !infence && /"(severity|priority)"[[:space:]]*:/ { exit }    # finding (b) JSON key
    !infence && /["'"'"'[:space:]]P[0123]["'"'"']/ { exit }       # finding (c) JSON value
    /^[[:space:]]*```/ { infence = !infence; next }       # toggle fence; drop the ``` line itself
    infence { next }                                       # inside a fenced quote → skip
    { print }
  ' "$f" 2>/dev/null) || _echo_region=""

  # Count distinct prompt-scaffolding markers in the echo region only. Each marker is
  # a standalone (line-anchored) artifact build_review_prompt emits; `## Step 0:` and
  # `## Step 0.5:` are DISTINCT sections, counted separately, so the two headings of a
  # real echo alone reach ≥2. A per-marker presence test summed is fail-safe (each
  # `grep -q … && …` is non-fatal on a no-match). An EMPTY echo region (a review whose
  # very first line is a `[P1]` finding, or whose markers are all fenced) yields 0.
  local _echo_markers=0
  if [[ -n "$_echo_region" ]]; then
    grep -qiE '^## Step 0:.*MANDATORY PRE-REVIEW' <<<"$_echo_region" 2>/dev/null && _echo_markers=$((_echo_markers + 1))
    grep -qiE '^## Step 0\.5:.*MANDATORY PRE-REVIEW' <<<"$_echo_region" 2>/dev/null && _echo_markers=$((_echo_markers + 1))
    grep -qiE '^## You are running inside .*codex review' <<<"$_echo_region" 2>/dev/null && _echo_markers=$((_echo_markers + 1))
    grep -qiE '^## (Review Checklist|Review Process)' <<<"$_echo_region" 2>/dev/null && _echo_markers=$((_echo_markers + 1))
    grep -qiE '^## Acceptance Criteria Verification' <<<"$_echo_region" 2>/dev/null && _echo_markers=$((_echo_markers + 1))
    grep -qiE '^Prefix EACH blocking finding' <<<"$_echo_region" 2>/dev/null && _echo_markers=$((_echo_markers + 1))
    grep -qiE '^You are reviewing PR #[0-9]+ for issue #[0-9]+' <<<"$_echo_region" 2>/dev/null && _echo_markers=$((_echo_markers + 1))
  fi
  if [[ "$_echo_markers" -ge 2 ]]; then
    return 0
  fi
  # Signal 3: a large capture at/near the wrapper's char cap with NO recognizable
  # verdict / conclusion structure AND no genuine finding structure — a dump cut
  # mid-text with nothing that looks like a review's conclusion OR a finding.
  # (45000 is below _codex_review_compose_body's 50000 cap; a genuine review this
  # long would carry a Summary/Findings/verdict heading OR at least one real finding.)
  # The size floor guards ONLY this signal: signals 1+2 are unambiguous structural
  # artifacts at any size, but "no verdict structure" is only suspicious in a LARGE
  # dump — a short, plausibly-complete review with no `Summary:` heading is NOT
  # malformed (a review need not carry one). So a tiny capture skips signal 3 and
  # returns NOT malformed (the fail-safe direction — never drop a real verdict).
  #
  # 5th-round review finding [P1] #2 (#252, session 5e569783): keying signal 3 on
  # the verdict-HEADING keywords ALONE marked a genuine LONG review carrying
  # numbered/bold `[P1]` findings (but none of those exact headings) as malformed —
  # dropping a real blocking review before the `[P1]` scan. So signal 3 ALSO requires
  # the ABSENCE of a genuine FINDING BOUNDARY (a real `[P1]`/numbered/bullet/JSON
  # finding — the same boundary set signals 1b/2 use): a long capture WITH finding
  # structure is a real review, not a truncated dump, so it is NOT malformed (it then
  # falls through to the `[P1]` scan and FAILs / PASSes correctly).
  local nchars
  nchars=$(wc -c < "$f" 2>/dev/null | tr -d ' ') || nchars=0
  [[ "$nchars" =~ ^[0-9]+$ ]] || nchars=0
  if [[ "$nchars" -ge 45000 ]] \
     && ! grep -qiE 'Review PASSED|Review findings:|^Summary:|^Findings|no blocking' "$f" 2>/dev/null \
     && ! grep -qE '^[[:space:]]*([0-9]+[.)][[:space:]]*)?([-*>][[:space:]]*)*(\*\*[[:space:]]*)?\[P[0123]\]' "$f" 2>/dev/null \
     && ! grep -qE '"(severity|priority)"[[:space:]]*:|["'"'"'[:space:]]P[0123]["'"'"']' "$f" 2>/dev/null; then
    return 0
  fi
  return 1
}

# _codex_review_classify_stdout <stdout-file>
#
# Echoes ONE token (`pass` | `fail` | `malformed`) classifying a `codex review`
# stdout capture. The `malformed` check (INV-73, #252) runs FIRST — a prompt-echo /
# startup-trace stdout is NOT a real review, so the severity-tag scan must NOT run
# over it (its tags are only quoted instruction text → a phantom FAIL). Then the
# gate logic: ANY severity tag (`[P0]`-`[P3]`, issue #449's severity-aware blocking
# ratchet) anywhere in the SCANNED text → `fail`; otherwise → `pass`. An
# empty / missing / unreadable file → `pass` (no tag ⇒ no finding; the wrapper still
# posts a `Review PASSED` verdict so a comment always lands). rc 0 ALWAYS —
# fail-safe under `set -euo pipefail` (a bare call must not abort the wrapper).
#
# [INV-132] (#481, review round 4): the SCANNED text is the STRUCTURALLY
# STRIPPED final response (`_codex_review_strip_prompt_echo`) whenever the
# capture validates as a genuine turn-marker review — the SAME boundary
# signal 0 (above) uses to admit it past the malformed gate in the first
# place. A genuine turn-marker capture echoes the wrapper's OWN prompt
# verbatim as the `user` turn's content, and that prompt's severity-tagging
# instructions (`_review_severity_prompt_block`) literally quote `[P0]`-`[P3]`
# as backtick-fenced markers (e.g. `` `[P1]` — a clear correctness/reliability
# merge blocker``) — a substring scan of the RAW capture matches those quoted
# instruction tokens exactly like a real finding tag, misclassifying `fail`
# for a review whose actual final response is completely clean (no findings,
# no tags at all). Because that misclassification happens HERE — before the
# pre-aggregation severity filter ever runs — the ratchet can never rescue it:
# `_review_extract_highest_severity` on the (correctly stripped) clean final
# response finds no tag at all and reports `none`, which
# `shouldBlockFinding` ALWAYS blocks (fail-safe), so a clean stdout-fallback
# review would block indefinitely regardless of round. The fix reuses the
# SAME strip helper the malformed gate already validated the structure with:
# if stripping changed the text (a genuine turn-marker capture with real
# content after the last `codex` marker), scan ONLY that stripped final
# response; otherwise (no structure — a legacy free-form capture, or a
# turn-marker capture with no post-marker text, which is already `malformed`
# and never reaches this line) scan the whole capture unchanged — the
# original, byte-identical behavior for every non-turn-marker shape.
#
# Pre-#449 this classified `fail` ONLY on `[P1]` — `[P2]`/`[P3]` were purely
# non-blocking observations with no ratchet. Under the ratchet a `[P2]`/`[P3]`
# finding CAN still block at an early round (see lib-review-severity.sh's
# `shouldBlockFinding`), so this classifier now flags `fail` on ANY tag; the
# round-aware demotion decision happens LATER, in the wrapper's pre-aggregation
# severity filter (lib-review-severity.sh), which re-scans the same text this
# function classified and may demote a `fail` back to `pass` for that round.
#
# Conservative on a tag match (AFTER the malformed gate): a blocking finding wins
# even if the tag appears inside a quoted code block of a REAL review — a false
# FAIL only re-queues the PR to dev, whereas a missed tag would let a blocking
# finding through to merge. So the cheap substring match is the safe direction —
# but ONLY once the capture is confirmed to be a review, not the prompt echoed
# back (#252), and ONLY over the text that is actually the review (not the
# echoed prompt's own instruction text, #481 round 4).
_codex_review_classify_stdout() {
  local f="${1:-}"
  if _codex_review_stdout_is_malformed "$f"; then
    printf 'malformed\n'
    return 0
  fi
  local _scan_text=""
  if [[ -n "$f" && -f "$f" && -r "$f" ]]; then
    local _cls_stripped _cls_original
    _cls_stripped=$(_codex_review_strip_prompt_echo "$f") || _cls_stripped=""
    _cls_original=$(cat -- "$f" 2>/dev/null) || _cls_original=""
    if [[ -n "$_cls_stripped" && "$_cls_stripped" != "$_cls_original" ]]; then
      _scan_text="$_cls_stripped"
    else
      _scan_text="$_cls_original"
    fi
  fi
  if [[ -n "$_scan_text" ]] && grep -qE '\[P[0123]\]' <<<"$_scan_text" 2>/dev/null; then
    printf 'fail\n'
  else
    printf 'pass\n'
  fi
  return 0
}

# ===========================================================================
# Issue #481 (R2, spec revision 2): strip the echoed prompt from a codex
# review stdout capture before scoring it for severity — ONLY on the legacy
# stdout-classify fallback route (AGENT_VERDICT_SOURCES[i]=="codex-stdout-
# fallback" at the autonomous-review.sh call site; every other resolution
# channel scores AGENT_VERDICT_BODIES[i] directly, per R1).
# ===========================================================================
# `_review_extract_highest_severity` (lib-review-severity.sh) is a per-finding
# fail-safe scan: ANY numbered line with no `[P0]`-`[P3]` tag collapses the
# WHOLE scan to `none` (deliberately — issue #449's own fix for a tagged
# low-severity finding masking a genuine untagged one). A `codex review`
# combined stdout/stderr capture, per `_run_codex_review`, has the shape
# `<CLI header> → <user turn marker> → <echoed prompt, dozens of untagged
# numbered checklist lines> → <reasoning/tool trace> → <codex turn marker> →
# <final response>`, so scoring the raw capture always hits the fail-safe on
# the echoed checklist and reports `none` regardless of what the agent
# actually tagged in its final response.
#
# The boundary this helper locates is STRUCTURAL, not a bare substring
# search: (1) a VALIDATED leading CLI header (reusing
# `_codex_review_stdout_is_malformed`'s own header signals — the banner as
# the first non-empty line, or the workdir:+model:+provider: triple in the
# contiguous leading region); (2) the FIRST standalone turn-marker line
# reading exactly `user` (column 0, no other content, outside any fenced
# block) AFTER that header; (3) the LAST standalone turn-marker line reading
# exactly `codex` (same column-0/exact/unfenced discipline) anywhere in the
# file. Only text STRICTLY AFTER that last `codex` marker is returned — the
# final response turn, never a reasoning/tool-trace turn that merely
# precedes it.
#
# This deliberately does NOT search for the LAST `user` line (a review's own
# reviewed-file content or tool-execution output could legitimately contain
# an incidental bare `user`/`codex` word) — only the FIRST `user` marker
# (immediately bounding the header) is ever consulted, and marker candidates
# are restricted to column-0, exact-word, UNFENCED lines so a quoted/fenced
# reviewed-file snippet or an indented tool-output line can never masquerade
# as a genuine turn boundary (mirrors this file's own established
# fenced-block-exclusion discipline from `_echo_region`/`_leading_region`
# above). Both ``` and ~~~ fence styles toggle the same `infence` state, so a
# tilde-fenced reviewed snippet is excluded from marker detection exactly like
# a backtick-fenced one.
#
# ANY missing piece of that structure (no validated header, no `user` marker
# after it, no `codex` marker after THAT) is fail-safe: echoes the ORIGINAL
# content UNCHANGED, never a guessed boundary. Empty/missing/unreadable input
# echoes empty. rc 0 ALWAYS (fail-safe under `set -euo pipefail`).
#
# The returned text also drops the CLI's own trailing `tokens used: <N>`
# footer line (case-insensitive) — a token count is never review findings and
# must never influence severity extraction.

# _codex_review_strip_prompt_echo <stdout-file>
_codex_review_strip_prompt_echo() {
  local f="${1:-}"
  local original=""
  if [[ -n "$f" && -f "$f" && -r "$f" ]]; then
    original=$(cat -- "$f" 2>/dev/null || true)  # fail-safe: a read error yields empty, never a crash
  fi
  [[ -n "$original" ]] || { printf '%s' "$original"; return 0; }

  # Step 1: validate a leading CLI header exists at all — reuses the SAME
  # structural signals _codex_review_stdout_is_malformed established (INV-73):
  # the banner as the capture's first non-empty line, OR the
  # workdir:+model:+provider: triple within the contiguous leading region (the
  # run of lines from the top up to the first blank/fence/heading/turn-marker
  # line). No header at all → fail-safe, return the original unchanged.
  local _first_nonempty _has_header=false
  _first_nonempty=$(awk 'NF{print; exit}' "$f" 2>/dev/null) || _first_nonempty=""
  if [[ "$_first_nonempty" =~ ^OpenAI\ Codex\ v[0-9] ]]; then
    _has_header=true
  else
    local _leading_region
    _leading_region=$(awk '
      NR==1 && $0=="" { next }
      /^[[:space:]]*$/ { exit }
      /^[[:space:]]*```/ { exit }
      /^[[:space:]]*#/ { exit }
      /^(user|codex)[[:space:]]*$/ { exit }
      { print }
    ' "$f" 2>/dev/null) || _leading_region=""
    if [[ -n "$_leading_region" ]] \
       && grep -qiE '^workdir:' <<<"$_leading_region" 2>/dev/null \
       && grep -qiE '^model:' <<<"$_leading_region" 2>/dev/null \
       && grep -qiE '^provider:' <<<"$_leading_region" 2>/dev/null; then
      _has_header=true
    fi
  fi
  if [[ "$_has_header" != true ]]; then
    printf '%s' "$original"
    return 0
  fi

  # Step 2: locate the FIRST standalone `user` turn-marker line — column 0,
  # exact word, nothing else on the line, outside any fenced block. This is
  # the header-owned marker: the header's own key:value/banner lines never
  # match it, so it is genuinely the first one AFTER the header. Never search
  # for the LAST `user` line — reviewed content quoted later could contain
  # one incidentally.
  local _user_line_no
  _user_line_no=$(awk '
    /^[[:space:]]*(```|~~~)/ { infence = !infence; next }
    infence { next }
    !infence && /^user[[:space:]]*$/ { print NR; exit }
  ' "$f" 2>/dev/null) || _user_line_no=""
  if [[ -z "$_user_line_no" ]]; then
    printf '%s' "$original"
    return 0
  fi

  # Step 3: locate the LAST standalone `codex` turn-marker line AFTER the
  # `user` marker — same column-0/exact-word/unfenced discipline, PLUS a
  # blank line immediately before it. Multiple `codex` turns are expected
  # (reasoning, tool calls, final response); the LAST one bounds the final
  # response, which is the only text scored.
  #
  # The blank-line-before requirement (round-3 review finding [P2], PR #484):
  # every genuine turn marker in a real `codex review` capture is emitted as
  # its own paragraph — preceded by a blank line — because the CLI always
  # closes out the PRIOR turn's text before opening a new one. Reviewed
  # content or captured tool output, by contrast, can legitimately contain an
  # UN-FENCED, column-0 `codex` word flowing directly out of the preceding
  # prose line with NO blank line before it (e.g. "Tool output follows:" then
  # "codex" as literal quoted output). Without this check that inline word was
  # mistaken for a later turn marker, discarding every real finding before it.
  # A candidate on line 1 of the file trivially has no line before it, so it
  # is never treated as blank-preceded (a marker can only be real starting
  # from line 2 — line 1 is always inside/before the header region anyway).
  local _codex_line_no
  _codex_line_no=$(awk -v start="$_user_line_no" '
    /^[[:space:]]*(```|~~~)/ { infence = !infence; prev = $0; next }
    infence { prev = $0; next }
    NR > start && !infence && /^codex[[:space:]]*$/ && NR > 1 && prev == "" { last = NR }
    { prev = $0 }
    END { if (last) print last }
  ' "$f" 2>/dev/null) || _codex_line_no=""
  if [[ -z "$_codex_line_no" ]]; then
    printf '%s' "$original"
    return 0
  fi

  # Return everything STRICTLY AFTER the last `codex` marker line, minus the
  # CLI's own trailing `tokens used: <N>` footer (the same line
  # `metrics_parse_tokens` reads, lib-metrics.sh) — a token count is never
  # part of the agent's findings and must not reach the severity scanner.
  # Case-insensitivity is done via `tolower()` (POSIX, mawk-portable) rather
  # than gawk's `IGNORECASE` extension — this subsystem's awk must stay
  # portable to any POSIX awk (mirrors the `_codex_capture_thread` discipline
  # documented in INV-91).
  local _stripped
  _stripped=$(awk -v boundary="$_codex_line_no" '
    NR > boundary && tolower($0) !~ /^[[:space:]]*tokens used:[[:space:]]*[0-9]+[[:space:]]*$/ { print }
  ' "$f" 2>/dev/null) || _stripped=""
  if [[ -z "$_stripped" ]]; then
    printf '%s' "$original"
  else
    printf '%s' "$_stripped"
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
#
# [INV-132] (#481): this composer is UNCHANGED by the severity-extraction fix —
# it still embeds the raw capture (echo included) as the human-facing comment
# body. R2's echo-stripping is scoped to SEVERITY SCORING only (the
# `_sev_text` selection in autonomous-review.sh), not to what gets posted for
# a human reader; the wrapper separately records this agent's verdict SOURCE
# as `codex-stdout-fallback` so the severity loop knows to score the
# stripped RAW CAPTURE (`AGENT_CODEX_LOGS[i]`) instead of this composed body.
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
      printf '%s\n' "codex review reported a blocking [P0]-[P3] finding (see the per-agent log for details)."
    else
      printf '%s\n' "$text"
    fi
  else
    if [[ -z "${text//[[:space:]]/}" ]]; then
      printf '%s\n' "codex review found no blocking findings."
    else
      printf '%s\n' "codex review found no blocking ([P0]-[P3]) findings. Review output:

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

# _run_codex_review <prompt> <model> <stdout-file> [<pr-workdir>] [<fanout-liveness-dir>]
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
# <fanout-liveness-dir> (#406, optional 5th arg): the wrapper's per-run fan-out
# scratch dir (`_FANOUT_DIR`) — the SAME dir that holds this agent's `.rc`/
# `.pgid` sidecars. It is unrelated to <pr-workdir>; it exists ONLY so a RE-RUN
# iteration (never the first run) can tell "has the wrapper already resolved
# verdicts and torn down?" before spawning a fresh `codex review` that nobody
# will ever collect. The wrapper removes this dir right after reading every
# agent's launch-rc sidecar (`rm -rf "$_FANOUT_DIR"`), BEFORE the post-resolution
# reap — so a re-run loop that checks it immediately before each fresh launch
# sees the deletion in time. When empty/unset (every existing 3-4-arg call site,
# including every unit test in tests/unit/test-lib-review-codex.sh), the gate is
# a pure no-op and the loop's behavior is byte-for-byte unchanged — this is
# deliberate: `_run_codex_review` must stay callable standalone (a unit test, a
# future non-wrapper caller) without requiring wrapper-internal plumbing.
#
# Return code: the exit code of the LAST `codex review` invocation. A 124
# (coreutils `timeout`'s OWN TERM-expiry exit code), 137 (128+SIGKILL, the
# --kill-after escalation), or ANY OTHER 128+N signal-death rc (see #406
# below) from ANY run STOPS the re-run loop IMMEDIATELY and is returned — the
# loop is for transient stream errors, not a process-level kill, so a
# wall-clock-capped OR externally-terminated run never triggers a re-run
# (#218 review finding 4; see the loop comment below). Because a terminal rc
# terminates the loop, no later run can overwrite the veto rc, so it is
# returned without any further re-runs. This is load-bearing for the INV-48
# timeout-veto: the wrapper's post-window sweep maps a no-verdict rc 124/137
# to `timed-out` (a deciding FAIL that VETOES the merge). The comment poller
# is the authoritative verdict gate after this returns; on non-timeout
# exhaustion with no verdict, codex is resolved `unavailable` (or `timed-out`
# for a 124/137 return).
#
# #406: rc 143 (SIGTERM, 128+15) is ALSO signal-death, not a transient stream
# blip. The review wrapper's own post-resolution reap (INV-43/INV-84,
# `_reap_fanout_processes` / `_reap_fanout_recorded_descendants`) delivers
# SIGTERM to a still-running codex review whose verdict already resolved via a
# sibling agent or an early artifact land — the in-flight `codex review` then
# exits 143. Pre-fix, 143 fell through to the #209 "transient stream blip" arm
# below and scheduled a FRESH `codex review`, which the wrapper's reap could not
# reach (the fan-out controller subshell that runs THIS loop is not itself in
# any recorded PGID/marker set — see autonomous-review.sh's post-resolution reap
# call site) — an orphaned re-run controller that outlives "Review complete" and
# posts a stale duplicate verdict 10+ minutes later. Generalizing to "any
# rc >= 128 is signal-death" (not just 124/137/143) covers every
# `_run_with_timeout`-delivered kill uniformly: the ONLY sources of a 128+
# exit here are the wrapper's own reap, the operator, or system shutdown —
# re-running against any of them is wrong. `_one_codex_review_run`'s call
# tree is exactly ONE process substitution deep (no pipeline stage before the
# CLI) so `$?` is codex's own signal-death rc, never a SIGPIPE artifact from an
# upstream stage.
#
# The CLEAN stdout (only codex review's output, NOT the wrapper's log noise) is
# written to <stdout-file> so the wrapper's stdout→verdict fallback and the
# stream-error drop-reason scan read codex's actual review text.
_run_codex_review() {
  local prompt="$1" model="$2" stdout_file="$3" pr_workdir="${4:-}" fanout_liveness_dir="${5:-}"
  local max="${CODEX_REVIEW_MAX_RERUNS:-3}"

  # [INV-72] Preflight the codex review binary BEFORE launching it. The codex
  # review lane launches `"$AGENT_CMD" review …` directly via _run_with_timeout
  # below — it does NOT go through run_agent/resume_agent, so it would otherwise
  # bypass their preflight_agent_binary check. Without this, a project whose
  # review CLI is codex but whose `codex` executable is absent / off-PATH would
  # fall through here as a generic rc-127 failure and be dropped as an opaque
  # `unavailable` review agent with NO operator envelope. preflight_agent_binary
  # (lib-agent.sh) resolves the launch binary for the active AGENT_CMD (== codex
  # in this fan-out subshell), surfaces ADT_CFG_AGENT_BINARY_MISSING via
  # error_surface "$ISSUE_NUMBER" on a miss, and returns non-zero. We return that
  # rc as the run's exit (the caller treats a non-zero _run_codex_review as a CLI
  # failure, not a verdict). command -v guards the rare case where this lib is
  # sourced without lib-agent.sh (the review wrapper always sources both).
  if command -v preflight_agent_binary >/dev/null 2>&1; then
    preflight_agent_binary || return $?
  fi
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
  #
  # INV-73 (#252) — a malformed rc-0 capture (codex echoed its prompt / startup
  # trace instead of a review) is ALSO re-run, exactly like a transient: `codex
  # review` is stateless (re-reads the diff each invocation), so a fresh run may
  # produce a real review. It is NOT a non-zero failure (a prompt-echo exits rc 0),
  # so it cannot key off `last_run_rc` — `_run_malformed_rc0` carries it. A clean
  # rc-0 run whose capture is a REAL review (not malformed) still breaks at once;
  # only an rc-0 capture the malformed detector fires on continues into the re-run.
  # If the budget is exhausted while still malformed, the loop breaks with rc 0 and
  # a malformed capture — the wrapper's rc-0 stdout fallback then sees the `malformed`
  # classifier token and leaves codex unresolved (→ `unavailable`, no phantom FAIL).
  local final_rc=0 last_run_rc=0 reruns=0 deadline budget now _run_malformed_rc0=false
  budget=$(_codex_review_deadline_seconds)
  now=$(_codex_now_seconds)
  deadline=$((now + budget))

  # _recompute_malformed_rc0 — set the outer `_run_malformed_rc0` from the LATEST
  # run's `last_run_rc` + capture: true iff the run exited clean (rc 0) but its
  # stdout is a prompt-echo / startup-trace (INV-73 / #252). Recomputed after EVERY
  # `_one_codex_review_run` so the loop's break/continue decision and the bound log
  # wording reflect the current capture; a non-zero run is never malformed-rc0 (the
  # malformed path is the rc-0 channel — non-zero takes the #209 transient path).
  _recompute_malformed_rc0() {
    _run_malformed_rc0=false
    if [[ "$last_run_rc" -eq 0 ]] && _codex_review_stdout_is_malformed "$stdout_file"; then
      _run_malformed_rc0=true
    fi
  }

  _one_codex_review_run || last_run_rc=$?
  final_rc="$last_run_rc"
  _recompute_malformed_rc0

  while true; do
    # Stop on ANY signal-death rc (a deciding INV-48 veto, not a blip). 124 is
    # coreutils `timeout`'s OWN exit code for a TERM-expiry (NOT 128+signal —
    # `timeout` itself exits 124, distinct from the child dying); 137
    # (128+SIGKILL) is the --kill-after escalation; 143 (128+SIGTERM) is the
    # wrapper's own post-resolution reap terminating a still-running codex
    # review whose verdict already resolved (#406) — treating it as terminal,
    # not a #209 transient blip, is what stops the orphaned re-run controller.
    # Generalize the SIGNAL-DEATH half to rc >= 128 (128+N, any signal) rather
    # than enumerating each one: the ONLY sources of a 128+ exit here are the
    # wrapper's own reap, the operator, or system shutdown — re-running
    # against any of them is wrong. 124 is kept as its own explicit disjunct
    # (it is coreutils' cap-expiry code, not a signal-death rc, so it does not
    # fall under the >= 128 generalization).
    [[ "$last_run_rc" -eq 124 || "$last_run_rc" -ge 128 ]] && break
    # Stop on a clean run that produced a REAL review (verdict produced — hand off
    # to the poller + the stdout fallback). A clean run whose capture is a malformed
    # prompt-echo (INV-73 / #252) does NOT break here — it falls through to the
    # bounded re-run below, exactly like a transient non-zero failure.
    [[ "$last_run_rc" -eq 0 && "$_run_malformed_rc0" != true ]] && break
    # #223: a DETERMINISTIC clap argv rejection (an exec-only flag like `-s` left in
    # the per-agent review extra-args → exit 2) STOPS the loop immediately. Unlike a
    # transient stream blip (#209), re-running the IDENTICAL argv can never succeed,
    # so re-running is pure waste AND emits a misleading "transient stream error"
    # line that sends the operator chasing upstream/network issues instead of their
    # conf. The non-zero rc still propagates → the post-window sweep resolves codex
    # `unavailable`, and _classify_codex_drop_reason names the rejected flag as a
    # `config-error:<flag>` drop reason (NOT a deciding FAIL — a conf error is an
    # operator condition, like stream-error/auth-failed, never a code rejection).
    #
    # PR #225 review finding [P1]: gate this ONLY on the clap exit code (rc 2 — clap's
    # standard parse-error exit). The capture scan alone is not a sufficient
    # discriminator: a GENUINE transient failure (e.g. rc 1) whose stdout happens to
    # PRINT / QUOTE `error: unexpected argument '<flag>' found` — codex echoing a
    # reviewed-diff hunk, or a transport blip after partial output — must STILL take
    # the re-run path (#209), not be short-circuited as deterministic config-error.
    # The rc-2 gate + the capture scan together mean: only a real clap parse rejection
    # (rc 2 AND the usage signature) breaks early; every other non-zero rc re-runs.
    if [[ "$last_run_rc" -eq 2 ]]; then
      local _cfg_flag
      _cfg_flag=$(_codex_review_argv_rejection_flag "$stdout_file")
      if [[ -n "$_cfg_flag" ]]; then
        echo "[lib-review-codex] codex review rejected '${_cfg_flag}' (clap parse error, rc ${last_run_rc}) — a DETERMINISTIC config error, NOT a transient stream blip; NOT re-running (identical argv can never succeed). Clear the exec-only flag via AGENT_REVIEW_EXTRA_ARGS_CODEX=\" \". Resolving \`config-error\` — INV-62/#223." >&2
        break
      fi
    fi
    # Bound 1: re-run budget exhausted → fall back (poller resolves unavailable).
    if (( reruns >= max )); then
      if [[ "$_run_malformed_rc0" == true ]]; then
        [[ "$max" -gt 0 ]] && \
          echo "[lib-review-codex] codex review hit CODEX_REVIEW_MAX_RERUNS=${max} still emitting a malformed prompt-echo/startup-trace stdout (rc 0, no verdict); falling back to the wrapper poller (resolves \`unavailable\` — INV-73/#252)." >&2
      else
        [[ "$max" -gt 0 ]] && \
          echo "[lib-review-codex] codex review hit CODEX_REVIEW_MAX_RERUNS=${max} with a non-zero exit (rc ${last_run_rc}); falling back to the wrapper poller." >&2
      fi
      break
    fi
    # Bound 2: wall-clock deadline reached → fall back. Checked AFTER the
    # max-rerun bound so a max=N config does exactly N re-runs when time allows.
    now=$(_codex_now_seconds)
    if (( now >= deadline )); then
      echo "[lib-review-codex] codex review hit the ${budget}s wall-clock deadline (AGENT_REVIEW_TIMEOUT) after ${reruns} re-run(s) with a non-zero/malformed result; falling back to the wrapper poller." >&2
      break
    fi
    # Bound 3 (#406): the wrapper's fan-out liveness dir was removed → verdict
    # resolution + reap already happened, and NOBODY will ever collect a fresh
    # `codex review`'s rc/stdout from here on. Checked immediately before every
    # re-run launch (not just once) because the dir can disappear WHILE this
    # loop is mid-re-run (INV-84 early resolution races the re-run controller).
    # A no-op when the caller passed no liveness dir (standalone/unit calls) —
    # `-n` on an empty string is false, so an unset 5th arg never breaks here.
    if [[ -n "$fanout_liveness_dir" && ! -d "$fanout_liveness_dir" ]]; then
      echo "[lib-review-codex] codex review fan-out dir '${fanout_liveness_dir}' no longer exists — the wrapper already resolved verdicts and reaped; NOT launching a re-run (#406, prevents an orphaned re-run controller)." >&2
      break
    fi

    reruns=$((reruns + 1))
    if [[ "$_run_malformed_rc0" == true ]]; then
      echo "[lib-review-codex] codex review exited rc 0 but emitted a malformed prompt-echo/startup-trace stdout (no verdict); re-running a fresh review (re-run ${reruns}/${max}) — INV-73/#252." >&2
    else
      echo "[lib-review-codex] codex review exited rc ${last_run_rc} (likely a transient stream error / turn.failed); re-running a fresh review (re-run ${reruns}/${max}) — INV-62/#209." >&2
    fi
    last_run_rc=0
    _one_codex_review_run || last_run_rc=$?
    final_rc="$last_run_rc"
    # Recompute the malformed-rc0 flag for THIS re-run so the loop's break/continue
    # decision (and the next bound's log wording) reflects the latest capture.
    _recompute_malformed_rc0
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

# ===========================================================================
# #223: codex review DETERMINISTIC argv-rejection (clap parse error, exit 2)
# ===========================================================================
# `codex review` accepts only -c/--config, --base, --commit, --uncommitted,
# --title, --enable, --disable (verified 0.137.0). A `codex exec`-era flag left in
# the per-agent review extra-args (e.g. `-s danger-full-access` — valid+needed on
# the deleted `codex exec` lane, which defaulted to a read-only sandbox) is spliced
# verbatim into the `codex review` argv by _codex_review_argv and rejected with an
# exit-2 clap parse error. That failure is DETERMINISTIC — re-running the identical
# argv can never succeed — so it must NOT be ridden out as a transient stream blip:
# _run_codex_review consults this detector to STOP re-running on a clap rejection,
# and _classify_codex_drop_reason renders it as a distinct `config-error:<flag>`
# drop reason (naming the rejected flag) rather than a bare opaque `unavailable`.

# _codex_review_argv_rejection_flag <stdout-file>
#
# Echo the flag/option `codex review`'s clap parser rejected, or empty if the
# capture is not a clap argv-rejection. rc 0 ALWAYS (fail-safe under
# `set -euo pipefail`; mirrors the rc-0-always drop-reason helpers — a bare call
# must never abort the wrapper). Recognizes the two clap rejection shapes:
#
#   error: unexpected argument '-s' found         → echoes `-s`
#   error: invalid value 'x' for '--enable <...>'  → echoes `--enable`
#
# The leading `error:` + the clap grammar is the discriminator: a clean review
# that merely MENTIONS "unexpected argument" in prose (no `error:` clap line) does
# NOT match (no false positive). An empty/missing/unreadable file → empty.
#
# Caller-side safety: this is a broad substring match (no line anchor), so a review
# whose body QUOTES the exact clap string `error: unexpected argument '<x>' found`
# (e.g. a finding about CLI ergonomics, or codex echoing a reviewed-diff hunk) WOULD
# match. So both production callers gate on the clap EXIT CODE (rc 2) — NOT just the
# capture text — before trusting this detector (PR #225 finding): _run_codex_review
# only consults it when `last_run_rc -eq 2`, and _classify_codex_drop_reason only
# emits config-error when its <launch-rc> arg is 2 (or omitted, for back-compat). An
# rc-0 clean review never reaches it (the rc-0 break precedes the check), and a
# transient rc-1 that merely quotes the string still re-runs / classifies as the
# transient it is. Keep the rc-2 gate if this helper is reused elsewhere.
_codex_review_argv_rejection_flag() {
  local f="${1:-}"
  [[ -n "$f" && -f "$f" && -r "$f" ]] || return 0
  local flag=""
  # Shape 1: `error: unexpected argument '<flag>' found`. The flag is the first
  # single-quoted token after `unexpected argument`. `|| true` guards the no-match
  # case (grep rc 1 under `set -o pipefail` would otherwise abort before return 0).
  flag=$(grep -oiE "error: unexpected argument '[^']+' found" "$f" 2>/dev/null \
    | head -1 | grep -oE "'[^']+'" | head -1 | tr -d "'") || true
  if [[ -z "$flag" ]]; then
    # Shape 2: `error: invalid value '<val>' for '<option> <...>'`. The option is
    # the quoted token after `for`; strip any ` <METAVAR>` clap appends to it.
    flag=$(grep -oiE "error: invalid value '[^']*' for '[^']+'" "$f" 2>/dev/null \
      | head -1 | grep -oE "for '[^']+'" | head -1 | sed -E "s/^for '//; s/'$//; s/ .*$//") || true
  fi
  printf '%s\n' "$flag"
  return 0
}

# _classify_codex_drop_reason <stdout-file> [<launch-rc>]
#
# Scrape a `codex review` stdout capture for a drop signal. Echoes ONE token on
# stdout (rc 0 ALWAYS — fail-safe under `set -euo pipefail`, mirrors
# _classify_agy_drop_reason / _classify_kiro_drop_reason):
#
#   config-error[:<flag>]   (#223)
#       — a DETERMINISTIC clap argv rejection (an exec-only flag like `-s` left in
#         the per-agent review extra-args; exit 2). The ":<flag>" suffix names the
#         rejected flag. Checked FIRST: a clap parse error fails before any model
#         stream opens, so it never co-occurs with stream-error; ordering it first
#         is defensive (a deterministic rejection is the more actionable signal).
#         GATED on <launch-rc> == 2 (clap's parse-error exit code) — see below.
#   stream-error[:N/M]
#       — the capture shows a stream-disconnect error. The ":N/M" suffix is the
#         HIGHEST reconnect-ladder depth seen (`Reconnecting... N/M`). Appended
#         only when the ladder is present.
#   malformed-output   (INV-73 / #252)
#       — the capture is codex's prompt-echo / startup-trace (the banner + the
#         echoed prompt + the comment-history dump) rather than a review — a clean
#         rc-0 run that produced no verdict. Checked LAST among the codex buckets:
#         config-error (rc 2) and stream-error (5xx disconnect) are MORE specific
#         causes with their own signatures, so a malformed prompt-echo is the
#         residual bucket and never shadows them.
#   "" (empty)
#       — no drop signal (the caller keeps the bare `unavailable`). A clean review
#         or a genuine `[P1]` review yields empty — NO over-claim.
#
# PR #225 review finding [P1]: the optional <launch-rc> arg gates the config-error
# bucket on the clap exit code (rc 2). The capture scan alone is not a sufficient
# discriminator — a GENUINE transient failure (e.g. rc 1) whose capture merely
# QUOTES the clap usage string (codex echoed a reviewed-diff hunk, or a transport
# blip after partial output) must NOT be mislabeled config-error; at a non-2 rc the
# classifier falls through to the stream-error scan (so the real transient cause is
# still named) / empty. When <launch-rc> is OMITTED the gate is skipped — preserving
# the pre-finding behavior for any caller that does not thread the rc; the wrapper's
# drop-loop passes it, so its classification is correctly gated.
_classify_codex_drop_reason() {
  local f="${1:-}" launch_rc="${2:-}"
  [[ -n "$f" && -f "$f" && -r "$f" ]] || return 0

  # #223 + PR #225 finding: a deterministic argv rejection (clap exit 2) is the more
  # actionable signal — name the rejected flag. Checked before the stream-error scan,
  # but ONLY when the rc is the clap parse-error code (rc 2), or when no rc was passed
  # (backward-compat). A non-2 rc (a transient that merely quoted the clap string)
  # skips this branch and falls through to the stream-error scan.
  if [[ -z "$launch_rc" || "$launch_rc" == "2" ]]; then
    local _cfg_flag
    _cfg_flag=$(_codex_review_argv_rejection_flag "$f")
    if [[ -n "$_cfg_flag" ]]; then
      printf 'config-error:%s\n' "$_cfg_flag"
      return 0
    fi
  fi

  if _codex_review_has_stream_error "$f"; then
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
  fi

  # INV-73 (#252): no clap rejection and no stream error — check the residual codex
  # bucket. A clean rc-0 run whose capture is codex's prompt-echo / startup-trace
  # (no verdict) was retried to exhaustion and dropped `unavailable`; name it
  # `malformed-output` so the operator sees WHY (codex echoed its prompt instead of
  # reviewing) rather than a bare opaque `unavailable`. A genuine review (clean or
  # `[P1]`) is NOT malformed → falls through to empty (no over-claim).
  if _codex_review_stdout_is_malformed "$f"; then
    printf 'malformed-output\n'
    return 0
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
#   config-error:-s
#       → "config-error: codex review rejected '-s' (exec-only flag in extra-args;
#          clear it via AGENT_REVIEW_EXTRA_ARGS_CODEX=\" \")"
#   config-error  (no flag)
#       → "config-error: codex review rejected an extra-args flag (exec-only flag
#          in extra-args; …)"
#   stream-error:5/5
#       → "stream-error (upstream 5xx; exhausted 5/5 stream reconnects)"
#   stream-error
#       → "stream-error (upstream 5xx; codex review stream disconnected)"
#   malformed-output   (INV-73 / #252)
#       → "malformed-output (codex review echoed its prompt/startup trace instead
#          of a review — no verdict; retried, still malformed)"
_codex_drop_reason_phrase() {
  local token="${1:-}"
  case "$token" in
    config-error:?*)
      # #223: name the rejected flag + the operator remedy (the INV-41 single-space
      # idiom clears a poison exec-era value out of the codex review extra-args).
      local flag="${token#config-error:}"
      printf "config-error: codex review rejected '%s' (exec-only flag in extra-args; clear it via AGENT_REVIEW_EXTRA_ARGS_CODEX=\" \")\n" "$flag"
      ;;
    config-error|config-error:)
      printf 'config-error: codex review rejected an extra-args flag (exec-only flag in extra-args; clear it via AGENT_REVIEW_EXTRA_ARGS_CODEX=" ")\n'
      ;;
    stream-error:*)
      local depth="${token#stream-error:}"
      printf 'stream-error (upstream 5xx; exhausted %s stream reconnects)\n' "$depth"
      ;;
    stream-error)
      printf 'stream-error (upstream 5xx; codex review stream disconnected)\n'
      ;;
    malformed-output)
      # INV-73 (#252): codex echoed its prompt + startup trace instead of a review.
      printf 'malformed-output (codex review echoed its prompt/startup trace instead of a review — no verdict; retried, still malformed)\n'
      ;;
    *)
      # Empty or unknown token → empty phrase.
      ;;
  esac
  return 0
}
