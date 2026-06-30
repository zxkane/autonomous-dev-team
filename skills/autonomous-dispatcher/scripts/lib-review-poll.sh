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
# Poll cadence in seconds. Single source of truth for the loop cadence: it is
# both the divisor that converts a seconds-budget into an attempt count
# (_resolve_verdict_poll_attempts) and the `sleep` interval inside the loop
# (_run_verdict_poll_loop), so the two can never silently diverge.
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
# Note: the wrapper's poll loop short-circuits as soon as every agent has a
# verdict comment. A non-zero launch rc no longer short-circuits an agent to
# `unavailable` (issue #180) — the verdict comment can land seconds after the
# CLI exits (propagation lag, or a verdict flushed right before the shell exits
# non-zero), so the loop keeps polling a no-verdict agent regardless of rc until
# this budget is exhausted. The extended budget therefore IS the propagation
# grace. The happy path (all verdicts already posted) still settles in one round.
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

# _classify_unresolved_agent <verdict_body> <rc>
#
# The per-round, per-agent decision for the verdict-poll loop (issue #180). It
# is the SINGLE decision point so the wrapper loop stays a thin driver and the
# logic is unit-testable in isolation. Echoes exactly one of:
#
#   pass | fail  — a verdict comment was matched for this agent; it is
#                  classified FAIL-first (see _classify_verdict_body). A verdict
#                  the agent DID post WINS over its launch rc (INV-40: "the
#                  matched verdict comment takes precedence over the launch rc").
#                  This is the #180 fix: a passing verdict from a non-zero-rc
#                  agent is counted, not dropped.
#   keep         — no verdict yet; keep polling. This is returned regardless of
#                  the launch rc. Pre-#180, a non-zero rc short-circuited the
#                  agent straight to `unavailable` on poll round 1, before its
#                  verdict comment had a chance to propagate to the comments API
#                  (the verify command can exit non-zero on a soft path, or the
#                  CLI can exit non-zero just AFTER posting `Review PASSED`, or
#                  the comment is still propagating). The #180 fix removes that
#                  short-circuit: a no-verdict agent keeps being polled — whether
#                  rc is zero or non-zero — for the full INV-43-scaled budget.
#                  The window IS the propagation grace (issue #180 Fix 2: no
#                  separate post-exit grace timer). An agent that still has no
#                  verdict when the window expires is resolved `unavailable` by
#                  the wrapper's post-window sweep — NOT here.
#
# Args:
#   $1 verdict_body — the matched verdict comment body, or empty if none yet.
#   $2 rc           — the agent's CLI launch exit code (AGENT_LAUNCH_RC).
#                     Accepted for symmetry / documentation; it no longer changes
#                     the decision (that is precisely the #180 fix).
#
# Pure: no side effects, no I/O.
_classify_unresolved_agent() {
  local body="$1"

  # A matched verdict always wins — including over a non-zero launch rc.
  if [[ -n "$body" ]]; then
    _classify_verdict_body "$body"
    return 0
  fi

  # No verdict yet → keep polling, regardless of rc (#180). The wrapper's
  # post-window sweep resolves `unavailable` only once the (INV-43-scaled)
  # budget is exhausted with still no verdict.
  printf 'keep\n'
}

# _classify_verdict_body <body> — echoes pass | fail (FAIL-first, #95).
# Conservative: a body containing both pass and fail phrasing classifies FAIL.
# Co-located with the poll helpers so the single verdict-classification rule is
# unit-testable and shared by both the loop's verdict-found path and
# _classify_unresolved_agent. (Moved here from autonomous-review.sh in #180.)
_classify_verdict_body() {
  local body="$1"
  if echo "$body" | grep -qiE 'Review (FAILED|REJECTED)|Review findings:|Changes requested'; then
    echo "fail"
  elif echo "$body" | grep -qiE 'Review PASSED|Review APPROVED|APPROVED FOR MERGE|LGTM|Review PASS'; then
    echo "pass"
  else
    echo "fail"
  fi
}

# _fetch_agent_verdict_body <agent_name> <session_id> — query the issue comments
# for THIS agent's verdict comment and echo the matched body (empty if none yet).
#
# Encapsulates the single comment-scan + `select` so the verdict-poll loop can be
# driven in unit tests by overriding this one function (the test injects a
# round-dependent body without a live GitHub). The authenticity binding (INV-20)
# + per-agent discriminator (INV-40) is built here:
#   - actor: author == BOT_LOGIN (when set), else the BOT_LOGIN-empty fallback
#     narrows on this agent's own `Review Session.*<session-id>` UUID;
#   - time window: createdAt >= WRAPPER_START_TS;
#   - per-agent discriminator: the `Review Agent: <name>` line (INV-40);
#   - verdict keyword: _VERDICT_RE.
# `sort_by(.createdAt // "", .id // 0) | last` so a re-posted verdict wins (a
# same-second tie breaks on the monotone REST comment id). Reads ISSUE_NUMBER / BOT_LOGIN /
# WRAPPER_START_TS / _VERDICT_RE from the environment (set by the wrapper); the
# repo is no longer read here — `itp_list_comments` owns the host-side `--repo`.
#
# [INV-91]/[INV-90] (#321): the comment read routes through `itp_list_comments`
# (the normalized array `[{id, author, authorKind, body, createdAt}]`, sorted
# ascending by `createdAt`), NOT a raw `gh issue view --json comments -q`. This
# moved the `select` from gh's embedded engine (gojq → Go RE2, ASCII-only case
# folding) to system jq (Oniguruma, Unicode folding) — a real regex-engine
# boundary, so four behavior-preservation fixes restore RE2 parity + fail-CLOSED:
#   1. `.comments[]`→`.[]` and `.author.login`→`.author` (the verb unwraps the
#      envelope and exposes `author` verbatim, INV-85). Exact-eq is engine-irrelevant.
#   2. verdict match `test(_VERDICT_RE;"i")` → `ascii_downcase | test("<lc>")` with
#      NO "i" flag. Oniguruma "i" does Unicode simple case-folding — it would widen
#      the literal ASCII keywords to also match U+212A (K) / U+017F (ſ), a
#      false-positive widening at the authenticity gate that RE2's ASCII fold never
#      made. ascii_downcase (ASCII-only) on BOTH sides restores parity. The
#      shell-side lowercase MUST be `LC_ALL=C tr` (NOT bash `${,,}`): _VERDICT_RE
#      carries an uppercase I ("Review FAILED"); bash `,,` under a Turkish locale
#      folds I→dotless ı ≠ the data-side `failed`, silently dropping the most common
#      verdict. The three case-SENSITIVE predicates (Review Session / Review
#      Session.*<sid> / Review Agent: <name>) stay UNCHANGED — no boundary/class/
#      "i" flag, so RE2 ≡ Oniguruma (a case-sensitive test() does NOT Unicode-fold).
#   3. `// empty` on the verdict jq: `[…]|last|.body` over a no-match selection
#      yields jq `null`, which `jq -r` prints as the literal string "null"; the old
#      `gh -q` path emitted EMPTY. The caller treats any non-empty body as "verdict
#      present" (`[[ -n "$body" ]]`), so a literal "null" would mis-resolve a
#      no-verdict poll. `// empty` restores the empty-on-no-match contract.
#   4. `[[ -z "$_vre_lc" ]] && return 0` before building the jq: an empty pattern
#      makes `test("")` match EVERY body (fail-OPEN); an unset/empty _VERDICT_RE
#      fails CLOSED (empty body) instead.
# The self-source of the ITP seam is LAZY (in-function), NOT top-level: the review
# wrapper sources this lib BEFORE lib-issue-provider.sh, so a top-level guard would
# change production source order. In-function it covers both entry paths (the poll
# loop + the observe-loop comment branch) and is needed only for standalone unit
# sourcing — production already has the seam by the time the poll runs.
_fetch_agent_verdict_body() {
  local _agent="$1" _sid="$2"
  if ! declare -F itp_list_comments >/dev/null 2>&1; then
    local _frp_self _frp_dir
    _frp_self="${BASH_SOURCE[0]:-$0}"
    _frp_dir="$(cd "$(dirname "$(readlink -f "$_frp_self")")" && pwd 2>/dev/null)" || _frp_dir=""
    if [ -n "$_frp_dir" ] && [ -r "${_frp_dir}/lib-issue-provider.sh" ]; then
      # shellcheck source=lib-issue-provider.sh
      source "${_frp_dir}/lib-issue-provider.sh"
    fi
  fi
  # Fix 4 — empty/unset _VERDICT_RE fails CLOSED (test("") would match every body).
  local _vre_lc
  _vre_lc="$(printf '%s' "${_VERDICT_RE:-}" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  [[ -z "$_vre_lc" ]] && return 0
  local _auth_predicate _agent_predicate _verdict_jq
  if [[ -n "${BOT_LOGIN:-}" ]]; then
    _auth_predicate="(.author == \"${BOT_LOGIN}\") and (.createdAt >= \"${WRAPPER_START_TS}\") and (.body | test(\"Review Session\"))"
  else
    _auth_predicate="(.createdAt >= \"${WRAPPER_START_TS}\") and (.body | test(\"Review Session.*${_sid}\"))"
  fi
  _agent_predicate="(.body | test(\"Review Agent: ${_agent}\"))"
  # Fix 2 (ascii_downcase, no "i"), Fix 3 (// empty), plus the same-second .id
  # tiebreak (re-sorting an already-ascending array is idempotent — INV-90 untouched).
  _verdict_jq="([ .[] | select(${_auth_predicate} and ${_agent_predicate} and (.body | ascii_downcase | test(\"${_vre_lc}\"))) ] | sort_by(.createdAt // \"\", .id // 0) | last | .body) // empty"
  itp_list_comments "$ISSUE_NUMBER" 2>/dev/null | jq -r "$_verdict_jq" 2>/dev/null || true
}

# _run_verdict_poll_loop — the per-agent verdict-poll loop (INV-40 / INV-43 /
# issue #180). Extracted from autonomous-review.sh so the loop itself — not just
# its per-round decision — is unit-testable (the #180 regression test stubs
# _fetch_agent_verdict_body to return a passing verdict only on round ≥2 and
# asserts a non-zero-rc agent is still counted `pass`, not dropped).
#
# Polls up to _VERDICT_POLL_ATTEMPTS rounds (× 5 s; INV-43 scales this with the
# command-mode E2E timeout). Each round, for every still-unresolved agent it
# fetches the verdict body and feeds (body, rc) to _classify_unresolved_agent:
#   - pass | fail → record the verdict (a verdict the agent posted WINS over its
#                   launch rc — INV-40);
#   - keep        → no verdict yet; keep polling REGARDLESS of rc (#180: a
#                   non-zero CLI exit no longer short-circuits the agent to
#                   `unavailable` while the window is open).
# The loop stops early once every agent has a verdict. Any agent still without a
# verdict when the budget is exhausted is left unresolved here and resolved
# `unavailable` by the caller's post-window sweep — the window IS the
# propagation grace (#180 Fix 2). Reads/writes the wrapper's globals:
#   in:  AGENT_NAMES, AGENT_SESSION_IDS, AGENT_LAUNCH_RC, _VERDICT_POLL_ATTEMPTS
#   out: AGENT_VERDICTS, AGENT_VERDICT_BODIES (parallel-indexed to AGENT_NAMES)
# Uses `sleep`, `log`, `_fetch_agent_verdict_body`, `_classify_unresolved_agent`
# (all overridable by tests).
_run_verdict_poll_loop() {
  local _poll_attempt _i _agent _sid _body _decision _all_resolved
  for _poll_attempt in $(seq 1 "${_VERDICT_POLL_ATTEMPTS}"); do
    sleep "${_VERDICT_POLL_INTERVAL_SECONDS:-5}"
    _all_resolved=1
    for _i in "${!AGENT_NAMES[@]}"; do
      # Already resolved (verdict found on a prior round, OR seeded from a valid
      # verdict artifact INV-78) — skip re-query. The artifact-first resolution
      # (#233) sets AGENT_VERDICTS[i] before this loop runs, so a `valid` artifact
      # gives artifact>comment precedence for free and the all-artifact path
      # breaks round 1 with ZERO comment-list API calls.
      [[ -n "${AGENT_VERDICTS[$_i]}" ]] && continue

      # INV-78 (#233): an agent whose artifact was MALFORMED is deliberately NOT
      # resolved by its comment — the loud envelope + the terminal `unavailable`/
      # `timed-out` sweep is the contract (Clause V1: a malformed artifact means
      # the agent's machine output is untrustworthy; we never let its comment
      # override it). Skip polling it so it stays unresolved for the terminal
      # sweep. Guarded so a caller that never declared the array (unit tests of
      # the legacy comment-only flow) is unaffected.
      if declare -p AGENT_VERDICT_SOURCES >/dev/null 2>&1 \
         && [[ "${AGENT_VERDICT_SOURCES[$_i]:-}" == "artifact-malformed" ]]; then
        continue
      fi

      _agent="${AGENT_NAMES[$_i]}"
      _sid="${AGENT_SESSION_IDS[$_i]}"
      _body=$(_fetch_agent_verdict_body "$_agent" "$_sid")

      # Single per-round decision (#180): a matched verdict wins over the launch
      # rc; otherwise keep polling regardless of rc (no early non-zero-rc drop).
      _decision=$(_classify_unresolved_agent "$_body" "${AGENT_LAUNCH_RC[$_sid]:-1}")
      case "$_decision" in
        pass|fail)
          AGENT_VERDICT_BODIES[$_i]="$_body"
          AGENT_VERDICTS[$_i]="$_decision"
          ;;
        keep)
          _all_resolved=0
          ;;
      esac
    done
    [[ "$_all_resolved" -eq 1 ]] && break
    log "Waiting for review verdict comment(s) to appear (attempt ${_poll_attempt}/${_VERDICT_POLL_ATTEMPTS})..."
  done
}

# _observe_agent_resolved <index> — INV-84 (#271): has fan-out slot <index>
# resolved its FIRST verdict? rc 0 iff yes.
#
# The fan-out observe loop's early-exit (INV-78 [P1] #2) was gated on
# `_all_artifacts_landed` — a path-existence check over EVERY slot's artifact
# FILE. But a comment-only agent (one that posts its verdict as a GitHub comment
# and never writes the artifact file) never satisfies that check, so on a MIXED
# panel the early-exit was permanently dead and a single lingering agent PID
# pinned the loop to its 6h ceiling. This helper resolves a slot the SAME way the
# post-loop resolution does — artifact first, comment fallback:
#
#   • artifact branch — the slot's first-land FROZEN snapshot
#     (AGENT_ARTIFACT_SNAPSHOTS[index], a `<path>.landed` file `_freeze_pass`
#     copies the moment the artifact lands) exists AND classifies `valid`
#     (`_classify_verdict_artifact` with this slot's identity, the SAME check the
#     post-loop resolution applies). Checked FIRST so an all-VALID-artifact panel
#     makes ZERO comment-list API calls — the INV-78 zero-comment-poll AC holds.
#
#     The snapshot is CLASSIFIED (not merely stat'd), and the branch resolves the
#     slot on three states:
#       - `valid`     → resolved (rc 0).
#       - `malformed` → NOT resolved, and we DO NOT consult the comment either —
#                       return rc 1 immediately (see the malformed rule below).
#       - `absent`*   → fall through to the comment branch (the rename hasn't
#                       landed; treat like a no-artifact agent).
#     (*A snapshot that exists but classifies neither valid nor malformed is the
#     classifier-unavailable test path; see the `declare -F` guard.)
#
#     MALFORMED ⇒ NOT resolved, comment NOT consulted (#271 review [P1] ×2): a
#     malformed artifact is "treated absent FOR THE VOTE" (INV-78 Clause V1), and an
#     absent verdict is exactly what must keep the loop waiting on the PID —
#     otherwise the early exit would reap a malformed-AND-still-running agent BEFORE
#     its rc sidecar lands, silently converting an INV-48 `timed-out` (rc 124/137)
#     deciding-FAIL veto into a dropped `unavailable` vote and letting a passing
#     sibling approve the PR. Crucially we do NOT fall through to the comment branch
#     for a malformed snapshot: the POST-LOOP resolution refuses to let a malformed
#     agent's comment override its artifact (Clause V1 — a malformed artifact means
#     the agent's machine output is untrustworthy), so the observe gate MUST match
#     that — else a malformed agent that ALSO posted a comment would resolve via the
#     comment here, get reaped early, then be dropped `unavailable` at the terminal
#     sweep (which keys on the durable `artifact-malformed` source), re-opening the
#     exact dropped-veto bug through the comment door. (A malformed agent that has
#     ALREADY exited is reaped via break-path (a) "all PIDs exited", where its rc
#     sidecar IS present — so the `valid`-only gate changes only the still-running
#     case, which is precisely the one that must wait.)
#
#   • comment branch — only when NO artifact snapshot is present (state `absent`):
#     the slot's verdict COMMENT is observable via `_fetch_agent_verdict_body` (the
#     SAME fetch + INV-20/INV-40 authenticity binding `_run_verdict_poll_loop`
#     uses). A non-empty body means the agent posted its verdict; the verdict wins
#     over the launch rc (INV-40), so the slot is resolved regardless of its PID.
#
# Reads AGENT_NAMES / AGENT_SESSION_IDS / AGENT_ARTIFACT_SNAPSHOTS. Uses
# `_classify_verdict_artifact` (lib-review-artifact.sh) + `_fetch_agent_verdict_body`
# (both overridable by tests). No `set -e` hazard: both are inside `$(...)` and the
# helper never runs a bare failing command.
_observe_agent_resolved() {
  local _idx="$1"
  # Artifact first-land snapshot, classified for VALIDITY (not mere existence).
  # AGENT_ARTIFACT_SNAPSHOTS may be unset in a degraded run — the `:-` keeps safe.
  local _snap="${AGENT_ARTIFACT_SNAPSHOTS[$_idx]:-}"
  if [[ -n "$_snap" && -f "$_snap" ]]; then
    local _st
    _st=$(_classify_verdict_artifact "$_snap" "${AGENT_SESSION_IDS[$_idx]}" "${AGENT_NAMES[$_idx]}")
    _st="${_st%%$'\n'*}"
    if [[ "$_st" == "valid" ]]; then
      return 0                       # valid artifact → resolved
    elif [[ "$_st" == "malformed" ]]; then
      return 1                       # malformed → NOT resolved, comment NOT consulted (Clause V1; see header)
    elif ! declare -F _classify_verdict_artifact >/dev/null 2>&1; then
      # Classifier unavailable (a harness that did not source lib-review-artifact.sh):
      # preserve the legacy snapshot-present-means-resolved behavior for that case.
      return 0
    fi
    # else `absent` (the rename hasn't landed despite the file appearing, or an
    # unmappable state) → fall through to the comment branch.
  fi
  # Comment fallback — observe THIS slot's verdict comment (no artifact snapshot).
  local _body
  _body=$(_fetch_agent_verdict_body "${AGENT_NAMES[$_idx]}" "${AGENT_SESSION_IDS[$_idx]}")
  [[ -n "$_body" ]] && return 0
  return 1
}

# _all_first_verdicts_resolved — INV-84 (#271): rc 0 iff EVERY fan-out slot has a
# resolved first verdict (per `_observe_agent_resolved`). This is the mixed-panel-
# aware early-exit signal that REPLACES the artifact-file-only
# `_all_artifacts_landed` gate in the observe loop.
#
# INV-48 timeout-veto is preserved by construction: a slot we early-exit past is
# one that is ALREADY resolved with a VALID verdict (its verdict wins over its rc —
# INV-40), and any slot that is NOT resolved (no valid artifact, no comment —
# INCLUDING a malformed-artifact agent, #271 review [P1]) makes this return
# non-zero, so the loop keeps waiting on PIDs until that agent's CLI exits with its
# real 124/137 cap (the `timed-out` veto). An all-VALID-artifact panel still
# early-exits on the same round with zero comment polls (a valid snapshot resolves
# its slot before the comment branch); a panel with a malformed-AND-still-running
# artifact agent now correctly WAITS on that agent's PID instead of reaping it
# before its rc lands.
#
# Empty fleet (no slots) → rc 1: we cannot claim "all resolved" with zero slots
# (mirrors `_all_artifacts_landed`'s no-args guard). Reads AGENT_NAMES.
_all_first_verdicts_resolved() {
  [[ "${#AGENT_NAMES[@]}" -gt 0 ]] || return 1
  local _i
  for _i in "${!AGENT_NAMES[@]}"; do
    _observe_agent_resolved "$_i" || return 1
  done
  return 0
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
