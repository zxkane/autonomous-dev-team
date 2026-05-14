#!/bin/bash
# lib-dispatch.sh — composable helpers for the autonomous-dispatcher tick.
#
# All gh / jq / regex logic that used to live in autonomous-dispatcher/SKILL.md
# is consolidated here as small, testable functions. Sourced by
# dispatcher-tick.sh and the per-step scan-*.sh / detect-stale.sh scripts.
#
# Behavior contract (PR-3 preserves all of these byte-for-byte):
#   - Comment phrasings (INV-06 "crashed/process not found" keyword contract)
#   - Label transition order (INV-08 atomic per-edit)
#   - Retry-counter cutoff rule (INV-05)
#   - JUST_DISPATCHED skip rule (INV-09)
#   - Strict > 300s idle gate (INV-10)
#   - SHA trailer format (INV-04)
#   - Session-id format (INV-03 — Dev not Review)
#
# See docs/pipeline/ for the spec.

set -euo pipefail

# Required env: REPO, REPO_OWNER, PROJECT_ID, MAX_RETRIES (default 3),
#               MAX_CONCURRENT (default 5).
: "${REPO:?REPO must be set in autonomous.conf}"
: "${REPO_OWNER:?REPO_OWNER must be set in autonomous.conf}"
: "${PROJECT_ID:?PROJECT_ID must be set in autonomous.conf}"
MAX_RETRIES="${MAX_RETRIES:-3}"
MAX_CONCURRENT="${MAX_CONCURRENT:-5}"

# ---------------------------------------------------------------------------
# Concurrency
# ---------------------------------------------------------------------------

# Count issues currently in active state (in-progress or reviewing).
# Echoes a non-negative integer.
count_active() {
  gh issue list --repo "$REPO" --state open --limit 100 \
    --label "autonomous" --json labels \
    -q '[.[] | select(.labels[].name | IN("in-progress","reviewing"))] | length'
}

# ---------------------------------------------------------------------------
# Issue queries (one per step)
# ---------------------------------------------------------------------------

# Step 2: issues with `autonomous` label and NO state label.
# Echoes JSON array of {number, labels, title}.
list_new_issues() {
  gh issue list --repo "$REPO" --state open --limit 100 \
    --label "autonomous" --json number,labels,title \
    -q '[.[] | select(
      [.labels[].name] | (
        contains(["in-progress"]) or
        contains(["pending-review"]) or
        contains(["reviewing"]) or
        contains(["pending-dev"]) or
        contains(["stalled"]) or
        contains(["approved"])
      ) | not
    )]'
}

# Step 3: issues with `autonomous` + `pending-review` AND NOT `reviewing`.
# Echoes JSON array of {number, labels}.
#
# Terminal-state subtraction (`approved`, `stalled`) is defense-in-depth on
# top of Step 0 hygiene ([INV-25], PR #117). Step 0 strips `pending-review`
# from terminal issues at the top of every tick; if it fails for any reason
# (rate-limit, API outage, future regression), this inline filter still
# keeps the selector from picking the residue and spawning a review against
# an already-approved or stalled issue. Issue #115 (Bug C re-scoped post-
# investigation: original "dev wrapper flips back" hypothesis was wrong;
# the actual third producer was this missing filter).
list_pending_review() {
  gh issue list --repo "$REPO" --state open --limit 100 \
    --label "autonomous,pending-review" --json number,labels \
    -q '[.[] | select(
      ([.labels[].name] | contains(["reviewing"]) | not) and
      ([.labels[].name] | contains(["approved"]) | not) and
      ([.labels[].name] | contains(["stalled"]) | not)
    )]'
}

# Step 4: issues with `autonomous` + `pending-dev`.
# Echoes JSON array of {number, labels, comments}.
#
# Terminal-state subtraction same as list_pending_review above. Issue
# #115 (Bug C). Without this, an `approved + pending-dev` residue would
# trigger Step 4's `pending-dev → in-progress` swap and spawn dev-resume
# against an approved issue — the actual mechanism behind the wedge that
# motivated this issue.
list_pending_dev() {
  gh issue list --repo "$REPO" --state open --limit 100 \
    --label "autonomous,pending-dev" --json number,labels,comments \
    -q '[.[] | select(
      ([.labels[].name] | contains(["approved"]) | not) and
      ([.labels[].name] | contains(["stalled"]) | not)
    )]'
}

# Step 5: issues currently in active state (in-progress OR reviewing) — same
# query as count_active but returning {number, labels} so callers can branch on
# which active label is set.
#
# `approved` is subtracted: an issue in the `approved` terminal state that
# still carries a transitional label (residue from a wrapper crash between
# two label edits, or from the [INV-15] SIGTERM race) must NOT be treated
# as stale. Issue #115 Bug A: without this exclusion, Step 5 swaps the
# active label to `pending-dev`, which re-arms Step 4 on the next tick —
# infinite loop burning tokens on a terminally-decided issue.
list_stale_candidates() {
  gh issue list --repo "$REPO" --state open --limit 100 \
    --label "autonomous" --json number,labels \
    -q '[.[] | select(
      (.labels[].name | IN("in-progress","reviewing")) and
      ([.labels[].name] | contains(["approved"]) | not)
    )]'
}

# ---------------------------------------------------------------------------
# Step 0: label hygiene helpers ([INV-25], issue #115 Bug B)
# ---------------------------------------------------------------------------

# Terminal-label predicate. Pure function over a labels JSON
# (`[{"name":"foo"},{"name":"bar"},...]`). Returns 0 if the label set
# contains `approved` or `stalled` (i.e. the issue is in a sticky terminal
# state); 1 otherwise. Future selectors can use this to subtract terminals
# without each rewriting the contains([...]) algebra.
#
# The four existing list_* selectors already inline their own approved
# subtraction; deliberately not refactored to keep this PR low-risk.
_has_terminal_label() {
  local labels_json="$1"
  jq -e '[.[].name] | (contains(["approved"]) or contains(["stalled"]))' \
    <<<"$labels_json" >/dev/null
}

# List autonomous issues whose label set is in violation of the
# state-machine "Forbidden transitions" rules:
#   - approved + (in-progress | reviewing | pending-review | pending-dev)
#   - stalled  + (in-progress | reviewing | pending-review | pending-dev)
# Returns a JSON array of {number, labels:[{name}]}. Empty array when no
# residue exists (the steady state).
list_hygiene_residue() {
  gh issue list --repo "$REPO" --state open --limit 100 \
    --label "autonomous" --json number,labels \
    -q '[.[] | select(
      ([.labels[].name] | (contains(["approved"]) or contains(["stalled"])))
      and
      ([.labels[].name] | (
        contains(["in-progress"]) or
        contains(["reviewing"]) or
        contains(["pending-review"]) or
        contains(["pending-dev"])
      ))
    )]'
}

# Strip transitional labels from an issue that also carries a terminal
# label. Single bundled `gh issue edit` so the strip is atomic per
# issue. Echoes the space-separated list of labels stripped (so the
# caller can feed it to hygiene_post_audit_comment), or empty when the
# issue is already clean.
hygiene_strip_residual_labels() {
  local issue_num="$1"
  local labels_json="$2"

  # Build the list of transitional labels actually present.
  local stripped
  stripped=$(jq -r '
    [.[].name] as $names
    | ["in-progress","reviewing","pending-review","pending-dev"]
    | map(select(. as $t | $names | index($t)))
    | join(" ")
  ' <<<"$labels_json")

  if [[ -z "$stripped" ]]; then
    return 0
  fi

  # Bail if the issue isn't in a terminal state — defensive: caller
  # should have prefiltered with list_hygiene_residue, but a stray
  # invocation against a plain transitional issue (TC-HYG-006) must NOT
  # strip anything.
  if ! _has_terminal_label "$labels_json"; then
    return 0
  fi

  local args=(issue edit "$issue_num" --repo "$REPO")
  for t in $stripped; do
    args+=(--remove-label "$t")
  done
  gh "${args[@]}" 2>/dev/null || true
  echo "$stripped"
}

# Post a one-shot audit comment on an issue when residual labels were
# stripped. Idempotency is keyed on `<sorted-stripped-labels>` so the
# same issue+residue-set never gets two comments. Different residue sets
# on the same issue (rare — implies a second drift) do post a fresh
# comment.
#
# `terminal_label` is the sticky label (`approved` / `stalled`) used in
# the comment body; `stripped_labels` is the space-separated list from
# hygiene_strip_residual_labels.
hygiene_post_audit_comment() {
  local issue_num="$1"
  local terminal_label="$2"
  local stripped_labels="$3"

  if [[ -z "$stripped_labels" ]]; then
    return 0
  fi

  # Sort for stable marker. The trailing `;` is a delimiter that makes the
  # contains()-based probe equality-safe: without it, a marker for the
  # wider residue set (`...:in-progress,reviewing`) would substring-match
  # a probe for a narrower set (`...:in-progress`), suppressing
  # legitimate audit comments when residue regresses from a wider to a
  # narrower set on the same issue. Labels are kebab-case lowercase so
  # `;` cannot collide.
  local sorted
  sorted=$(echo "$stripped_labels" | tr ' ' '\n' | sort | tr '\n' ',' | sed 's/,$//')
  local marker="INV-25-hygiene:${sorted};"

  local existing
  existing=$(gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q "[.comments[].body | select(contains(\"${marker}\"))] | length" \
    2>/dev/null || echo 0)

  if [[ "$existing" != "0" ]]; then
    return 0
  fi

  local pretty
  pretty=$(echo "$stripped_labels" | tr ' ' '\n' | awk 'NF{printf "%s`%s`", (NR>1?", ":""), $1}')
  gh issue comment "$issue_num" --repo "$REPO" \
    --body "Label hygiene: stripped ${pretty} from \`${terminal_label}\` issue (INV-25). <!-- ${marker} -->" \
    2>/dev/null || true
}

# Step 0 entry point. Iterates list_hygiene_residue and applies
# hygiene_strip_residual_labels + hygiene_post_audit_comment. Always
# safe to call — no-op when no residue exists.
run_hygiene_pass() {
  local residue
  residue=$(list_hygiene_residue)
  local count
  count=$(jq 'length' <<<"$residue")
  if [[ "$count" -eq 0 ]]; then
    return 0
  fi

  local i
  for i in $(seq 0 $((count - 1))); do
    local issue_num labels_json terminal stripped
    issue_num=$(jq -r ".[$i].number" <<<"$residue")
    labels_json=$(jq -c ".[$i].labels" <<<"$residue")

    # Determine which terminal label drove the residue (approved wins
    # when both are present — caller can audit further from the comment).
    if jq -e '[.[].name] | contains(["approved"])' <<<"$labels_json" >/dev/null; then
      terminal="approved"
    else
      terminal="stalled"
    fi

    stripped=$(hygiene_strip_residual_labels "$issue_num" "$labels_json")
    if [[ -n "$stripped" ]]; then
      hygiene_post_audit_comment "$issue_num" "$terminal" "$stripped"
    fi
  done
}

# ---------------------------------------------------------------------------
# Step 2: dependency check
# ---------------------------------------------------------------------------

# Returns 0 (resolved) if every issue referenced in the issue body's
# `## Dependencies` section is in a resolved state (CLOSED or MERGED).
# Returns 1 (blocked) on the first unresolved dependency. Returns 0 if no
# dependencies are listed.
#
# Closes #61 (MERGED PRs report `state: "MERGED"`, not `"CLOSED"`) and
# #73 (replace GNU-only `grep -oP '#\K[0-9]+'` with portable extraction).
# Both fixes are in the same function and ship together.
check_deps_resolved() {
  local issue_num="$1"
  local deps state
  # Portable dep-number extraction: grep -oE matches `#NNN`, sed strips
  # the leading `#`. Equivalent to the GNU-only `grep -oP '#\K[0-9]+'`
  # but works on macOS / BSD grep too.
  deps=$(gh issue view "$issue_num" --repo "$REPO" --json body -q '.body' \
    | sed -n '/^## Dependencies/,/^## /p' \
    | grep -oE '#[0-9]+' \
    | sed 's/^#//' || true)

  for dep in $deps; do
    state=$(gh issue view "$dep" --repo "$REPO" --json state -q '.state')
    # Both CLOSED (issues, closed PRs) and MERGED (merged PRs) count as
    # resolved. `gh issue view` on a merged PR returns state "MERGED".
    if [ "$state" != "CLOSED" ] && [ "$state" != "MERGED" ]; then
      return 1
    fi
  done
  return 0
}

# ---------------------------------------------------------------------------
# Step 4: retry counter
# ---------------------------------------------------------------------------

# Echoes the count of failure events on the issue, using the stalled-cutoff
# rule [INV-05]: only count failures after the most recent
# "Marking as stalled" comment. Two event sources are counted:
#   - Agent Session Report (Dev) comments with non-zero exit code (always)
#   - Dispatcher-detected crash comments matching [INV-06]'s keyword regex,
#     BUT only when the agent has confirmed startup at some point in the
#     current retry cycle (a "Dev Session ID:" comment exists post-cutoff).
#     Without that gate, dispatcher false positives from the cold-start
#     window (Bug 1 in #99) consume MAX_RETRIES even though the agent
#     never actually failed. See [INV-18].
#
# When MAX_RETRIES is hit, mark_stalled() is the appropriate action.
count_retries() {
  local issue_num="$1"
  local agent_failures dispatcher_crashes
  agent_failures=$(count_agent_failures "$issue_num")
  dispatcher_crashes=$(count_dispatcher_crashes "$issue_num")

  # Bug 5 (#99): only count dispatcher-detected crashes when the agent has
  # confirmed startup at some point in this retry cycle. Pre-confirmation
  # crashes are dispatcher-side false positives (cold-start window, missing
  # exec bit, broken auth handoff) and must NOT consume MAX_RETRIES.
  if _agent_started_since_stall "$issue_num"; then
    echo $((agent_failures + dispatcher_crashes))
  else
    echo "$agent_failures"
  fi
}

# Echoes the count of dispatcher-detected false positives (no session ID
# observed in this retry cycle). Reported alongside the canonical counters
# in mark_stalled() so operators can see Bug 1 cold-start crashes are
# being suppressed instead of silently absorbed.
count_dispatcher_false_positives() {
  local issue_num="$1"
  if _agent_started_since_stall "$issue_num"; then
    echo 0
  else
    count_dispatcher_crashes "$issue_num"
  fi
}

# Returns 0 if at least one "Dev Session ID: <id>" comment appears after the
# most recent "Marking as stalled" cutoff AND that comment did NOT come from
# a startup-failure path (i.e., the agent really did start, not just
# wrapper-side post-mortem with a forwarded session id). [INV-19] gate for
# Bug 5.
#
# Why exclude `Mode: startup-failure`: autonomous-dev.sh's startup-failure
# trap (when AGENT_RAN=false, e.g. gh-with-token-refresh couldn't find a
# real gh — #92) still emits a session report containing the SESSION_ID
# that was passed to --session for dev-resume mode. Counting that as
# "agent confirmed startup" would arm dispatcher-crash counting on a
# wrapper that never actually invoked the agent.
_agent_started_since_stall() {
  local issue_num="$1"
  local last_stalled_at session_seen
  last_stalled_at=$(gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q '[.comments[] | select(.body | test("Marking as stalled"))] | last | .createdAt // "1970-01-01T00:00:00Z"')
  session_seen=$(gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q "[.comments[] | select((.createdAt > \"${last_stalled_at}\") and (.body | test(\"Dev Session ID: .[a-zA-Z0-9_-]+\")) and (.body | test(\"Mode: startup-failure\") | not))] | length")
  [ "${session_seen:-0}" -gt 0 ]
}

# Echoes the agent_failures count separately (used by mark_stalled comment).
count_agent_failures() {
  local issue_num="$1"
  local last_stalled_at
  last_stalled_at=$(gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q '[.comments[] | select(.body | test("Marking as stalled"))] | last | .createdAt // "1970-01-01T00:00:00Z"')
  # Exit code exclusions:
  #   0   → success (pre-existing exclusion).
  #   143 → SIGTERM. Almost always caused by `dispatch-local.sh::kill_stale_wrapper`
  #         when the dispatcher decides to kick a stale wrapper to spawn a fresh
  #         one. Counting the dispatcher's own kill as an "agent failure"
  #         consumed retry budget the agent never spent (see #121 Fix A).
  #   137 → SIGKILL. The escalation path when SIGTERM is ignored, again driven
  #         by kill_stale_wrapper. Same reasoning as 143.
  # Genuine hangs are still bounded by `lib-agent.sh::_run_with_timeout`'s
  # exit code 124 (kept counting) and any non-listed non-zero exit (real
  # agent crashes). The regex anchors on word boundaries (`Exit code:
  # 143\b`-equivalent via `\\b`) so 144 / 1430 / etc. don't false-match.
  gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q "[.comments[] | select(
         (.createdAt > \"${last_stalled_at}\")
         and (.body | test(\"Agent Session Report \\\\(Dev\\\\)\"))
         and (.body | test(\"Exit code: 0\\\\b\") | not)
         and (.body | test(\"Exit code: 143\\\\b\") | not)
         and (.body | test(\"Exit code: 137\\\\b\") | not)
       )] | length"
}

count_dispatcher_crashes() {
  local issue_num="$1"
  local last_stalled_at
  last_stalled_at=$(gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q '[.comments[] | select(.body | test("Marking as stalled"))] | last | .createdAt // "1970-01-01T00:00:00Z"')
  gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q "[.comments[] | select((.createdAt > \"${last_stalled_at}\") and (.body | test(\"Task appears to have crashed \\\\(no PR found\\\\)|process not found\")))] | length"
}

# Mark issue as stalled (retry exhausted). Posts the canonical "Marking as
# stalled" comment that the next stalled-cutoff calculation will key off.
mark_stalled() {
  local issue_num="$1"

  # Liveness defer (#121 Fix C): if a dev wrapper is still alive on this
  # issue, the retry counter is almost certainly wrong (the wrapper is
  # making real progress; the dispatcher's "crash" detection or its own
  # kill_stale_wrapper SIGTERMs are scoring a healthy wrapper). Posting
  # `+stalled` here would lie about a working wrapper — and worse, the
  # wrapper trap will then write `pending-review` onto a stalled issue,
  # producing the `approved + stalled` co-existence wedge documented in
  # #121's reproduction (podcast-curation#204 / 2026-05-14).
  #
  # Defense: defer the decision when `pid_alive` reports ALIVE. Post a
  # one-shot deferral comment (idempotency-keyed on the agent's current
  # session id pulled from the wrapper PID file path, so re-ticks against
  # the same alive wrapper don't fill the timeline).
  if pid_alive issue "$issue_num"; then
    local pid current_session_marker
    pid=$(get_pid issue "$issue_num")
    current_session_marker="INV-26-stall-deferral:pid=${pid}"
    if gh issue view "$issue_num" --repo "$REPO" --json comments \
        -q "[.comments[].body | select(contains(\"${current_session_marker}\"))] | length" \
        2>/dev/null | grep -q '^0$'; then
      gh issue comment "$issue_num" --repo "$REPO" \
        --body "Stall decision deferred: dev wrapper PID ${pid} is still alive — counter says ${MAX_RETRIES} but a wrapper is making progress. Re-evaluating next tick. (\`${current_session_marker}\`)"
    fi
    return 0
  fi

  local agent_failures dispatcher_crashes false_positives
  agent_failures=$(count_agent_failures "$issue_num")
  dispatcher_crashes=$(count_dispatcher_crashes "$issue_num")
  false_positives=$(count_dispatcher_false_positives "$issue_num")
  gh issue edit "$issue_num" --repo "$REPO" \
    --remove-label "pending-dev" \
    --add-label "stalled"
  # Operator visibility: counted vs. suppressed dispatcher events ([INV-18]).
  # Suppressed events are dispatcher-detected crashes that occurred before the
  # agent confirmed startup (no Dev Session ID written) — these are
  # dispatcher-side false positives and do NOT consume MAX_RETRIES.
  local counted_dispatcher_crashes=$(( dispatcher_crashes - false_positives ))
  gh issue comment "$issue_num" --repo "$REPO" \
    --body "Issue has exceeded the maximum retry limit (${MAX_RETRIES} failed attempts: ${agent_failures} agent failures + ${counted_dispatcher_crashes} dispatcher-detected crashes; ${false_positives} dispatcher false positives suppressed per #99). Marking as stalled. @${REPO_OWNER} please investigate manually."
}

# ---------------------------------------------------------------------------
# Step 4: session-id extraction
# ---------------------------------------------------------------------------

# Echoes the most recent Dev Session ID for the issue (must NOT match
# Review Session ID — see [INV-03]). Echoes empty string if none found.
#
# Closes #70: jq 1.6+ uses Oniguruma which expects `(?<id>...)` — Python
# style `(?P<id>...)` errors with "Regex failure: undefined group option"
# and the `// empty` fallback does NOT catch it (jq exits non-zero before
# `//` is evaluated). See [INV-16].
extract_dev_session_id() {
  local issue_num="$1"
  gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q '[.comments[].body | capture("Dev Session ID: `(?<id>[a-zA-Z0-9_-]+)`"; "g") | .id] | last // empty'
}

# is_session_completed — return 0 if the agent's last log object indicates a
# session state that resume cannot recover from. Two cases qualify:
#
#   1. end_turn|completed         — normal exit, agent has nothing left to do.
#                                   Resuming would attach to a closed SSE
#                                   stream and hang (#59, INV-12).
#   2. *|prompt_too_long          — JSONL transcript exceeded the model's
#                                   input window. claude -p has no auto-
#                                   compaction, so resuming re-feeds the
#                                   whole transcript and crashes again. The
#                                   only recovery is a fresh session with a
#                                   smaller seed prompt.
#
# Used by Step 4 to skip resume against a session that cannot make progress.
# The caller distinguishes (1) vs (2) via the optional capture-mode arg
# (`is_session_completed N reason_var`) — case (1) is left for the operator
# to decide; case (2) flips the label back to pending-dev so the next tick
# auto-retries with a fresh session.
#
# Returns 1 (false) for: AGENT_CMD != claude, missing/unreadable log, no JSON
# object found, malformed JSON, or any non-terminal stop reason (api_error,
# stop_sequence, etc.).
# Conservative: a false negative just means we still try to resume (existing
# behavior); a false positive (claiming terminal when it isn't) would
# mistakenly skip a legitimate retry.
#
# Per-CLI scope (AGENT_CMD-gated by design — see follow-up TODO):
#   claude   — fully covered. JSON shape `{"type":"result", stop_reason,
#              terminal_reason}` is documented + tested.
#   codex    — NOT covered. codex `exec --json` emits a different event
#              schema (thread.started / task.completed / error). Resume is
#              server-side, so the prompt_too_long failure mode may not even
#              manifest the same way. Falls through to false → dispatcher
#              attempts resume; relies on AGENT_TIMEOUT (INV-13) as the
#              safety net for hangs. PTL recovery for codex is tracked as a
#              follow-up — needs a real codex JSONL fixture to write the
#              gate against, not guessed.
#   kiro     — by design. Kiro has no session model (every invocation is a
#              fresh conversation, see lib-agent.sh kiro branch), so PTL
#              cannot occur and "completed" has no meaning. Returning false
#              here lets the dispatcher run the next dev-resume which the
#              wrapper transparently turns into dev-new.
#   opencode — NOT covered, same reasoning as codex. Server-side sessions
#              and unknown PTL event shape; needs a real fixture.
#
# Until coverage is extended, non-claude PTL crashes will surface via the
# normal stale-detection path (Step 5b) instead of this gate. That's a
# correct degradation — slower recovery (one full tick cycle) but no risk
# of false-positive auto-recovery on a CLI whose JSON we haven't observed.
is_session_completed() {
  local issue_num="$1"
  local reason_var="${2:-}"
  [ "${AGENT_CMD:-claude}" = "claude" ] || return 1

  local log_file="/tmp/agent-${PROJECT_ID}-issue-${issue_num}.log"
  [ -r "$log_file" ] || return 1

  # Claude --output-format json emits one full JSON object per line, including
  # a final `{"type":"result", ...}` with stop_reason and terminal_reason on
  # clean exit. We must NOT regex-truncate this object — it contains nested
  # objects (`usage`) and the model's `result` string (which routinely
  # contains `}` inside markdown / code blocks). Instead grab the whole last
  # `result` line and let jq parse it.
  #
  # Multiple result objects are possible (resume cycles): the LAST line wins.
  local last_line
  last_line=$(grep '^{"type":"result"' "$log_file" 2>/dev/null | tail -1)
  [ -n "$last_line" ] || return 1

  local fields
  fields=$(jq -er '"\(.stop_reason // "")|\(.terminal_reason // "")"' <<<"$last_line" 2>/dev/null) || return 1

  local terminal_reason="${fields##*|}"

  if [ "$fields" = "end_turn|completed" ] || [ "$terminal_reason" = "prompt_too_long" ]; then
    [ -n "$reason_var" ] && printf -v "$reason_var" '%s' "$terminal_reason"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Dispatch-token marker (Bugs 1 + 2 in #99 — [INV-17])
# ---------------------------------------------------------------------------
#
# At dispatch time the dispatcher writes a structured marker to the issue:
#
#   <!-- dispatcher-token: <uuid> at <iso8601> mode=<dev-new|dev-resume|review> -->
#   Dispatching autonomous development...
#
# The HTML comment is machine-parseable; the human-readable line preserves
# the existing wording for backward compat. Two roles:
#
#   1. Cold-start grace period (Bug 1). Step 5 reads the latest token's age
#      via latest_dispatch_token_age_seconds and skips stale detection if
#      `age < DISPATCH_GRACE_PERIOD_SECONDS`. Defaults to 10 min — empirical
#      wrapper startup is 1–7 sec, this leaves ~90× headroom for slow MCP
#      negotiation or remote SSM dispatch without trapping genuinely-dead
#      wrappers indefinitely.
#
#   2. Dispatcher-controlled dispatch identity (Bug 2). The dispatcher no
#      longer relies on the agent's session-id-comment to know "did we just
#      dispatch this?" — which used to fail when the agent crashed before
#      its EXIT trap.

# Echoes seconds since the most recent dispatch-token comment on the issue.
# Empty if no token comment exists, or if the timestamp is unparseable.
latest_dispatch_token_age_seconds() {
  local issue_num="$1"
  local latest_iso
  latest_iso=$(gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q '[.comments[].body | capture("<!-- dispatcher-token: [a-zA-Z0-9_-]+ at (?<ts>[0-9TZ:-]+) mode=[a-z-]+ -->"; "g") | .ts] | last // empty')
  [ -n "$latest_iso" ] || { echo ""; return; }
  _iso_age_seconds "$latest_iso"
}

# Echoes seconds between now and an ISO-8601 UTC timestamp. Empty on parse
# failure. Cross-platform (GNU `date -d` vs BSD `date -j -f`). Shared by
# pr_idle_seconds and latest_dispatch_token_age_seconds.
_iso_age_seconds() {
  local iso="$1"
  local epoch now_epoch
  epoch=$(date -u -d "$iso" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null \
    || echo "")
  [ -n "$epoch" ] || { echo ""; return; }
  now_epoch=$(date -u +%s)
  echo $(( now_epoch - epoch ))
}

# Returns 0 if the issue's latest dispatch token is younger than
# DISPATCH_GRACE_PERIOD_SECONDS. Returns 1 otherwise (also when no token
# exists — backward-compat fallthrough). Strict `<`: at-or-past the
# threshold is OUT of grace.
#
# DISPATCH_GRACE_PERIOD_SECONDS=0 disables the grace window entirely.
is_within_grace_period() {
  local issue_num="$1"
  local grace="${DISPATCH_GRACE_PERIOD_SECONDS:-600}"
  [ "$grace" -gt 0 ] || return 1
  local age
  age=$(latest_dispatch_token_age_seconds "$issue_num")
  [ -n "$age" ] || return 1
  [ "$age" -lt "$grace" ]
}

# Post a dispatcher-controlled dispatch-token marker as an issue comment.
# Args: <issue_num> <mode>   where mode ∈ dev-new|dev-resume|review.
# Body retains the existing human-readable phrasing, prefixed with the
# machine-parseable HTML comment.
post_dispatch_token() {
  local issue_num="$1" mode="$2"
  local token now human
  if command -v uuidgen >/dev/null 2>&1; then
    token=$(uuidgen | tr 'A-Z' 'a-z' | tr -d '-' | cut -c1-12)
  else
    # Fallback: 12 hex chars from /dev/urandom.
    token=$(od -An -N6 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' || echo "$$$(date +%s%N)")
  fi
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  case "$mode" in
    dev-new)     human="Dispatching autonomous development..." ;;
    dev-resume)  human="Resuming autonomous development..." ;;
    review)      human="Dispatching autonomous review..." ;;
    *)           human="Dispatching ${mode}..." ;;
  esac
  gh issue comment "$issue_num" --repo "$REPO" \
    --body "<!-- dispatcher-token: ${token} at ${now} mode=${mode} -->
${human}"
}

# ---------------------------------------------------------------------------
# Step 5: stale detection helpers
# ---------------------------------------------------------------------------

# Resolve the PID file path for this issue+kind. Centralized so pid_alive
# and get_pid stay in lockstep with the wrapper-side path scheme.
# Echoes the path (or empty string if pid_dir_for_project fails — the
# callers already treat "no PID file" as "DEAD" so a soft failure here is
# safe and matches the prior /tmp behavior on filesystem errors).
_pid_file_for() {
  local kind="$1" issue_num="$2" dir
  dir=$(pid_dir_for_project 2>/dev/null) || return 0
  echo "${dir}/${kind}-${issue_num}.pid"
}

# Returns 0 if the wrapper PID for this issue+kind is alive, 1 otherwise.
# `kind` is "issue" (dev wrapper) or "review".
#
# Two-tier check (#111 Part B):
#   1. `kill -0 <pid>` succeeds → ALIVE.
#   2. `kill -0 <pid>` fails → check PID-file mtime. If it was touched
#      within HEARTBEAT_INTERVAL_SECONDS * 3 (default 360s), still treat
#      as ALIVE — the wrapper may be transitioning groups, exec'ing, or
#      racing with us. The wrapper's install_agent_heartbeat helper
#      (lib-agent.sh) keeps the mtime fresh while it's running, so a
#      stale mtime is strong evidence the process is genuinely dead.
#
# HEARTBEAT_INTERVAL_SECONDS=0 disables the mtime fallback entirely
# (legacy strict behavior).
pid_alive() {
  local kind="$1" issue_num="$2"
  local pid_file pid
  pid_file=$(_pid_file_for "$kind" "$issue_num")
  [ -n "$pid_file" ] || return 1
  pid=$(cat "$pid_file" 2>/dev/null || echo "")
  [ -n "$pid" ] || return 1
  if kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  local hb_interval="${HEARTBEAT_INTERVAL_SECONDS:-120}"
  # Defensive numeric guard: a typo here would silently flip ALIVE → DEAD,
  # the exact failure mode #111 fixes. Treat non-numeric / negative as
  # "fallback disabled" (legacy strict).
  [[ "$hb_interval" =~ ^[0-9]+$ ]] || return 1
  [ "$hb_interval" -gt 0 ] || return 1
  [ -f "$pid_file" ] || return 1
  local now mtime threshold
  now=$(date -u +%s)
  mtime=$(stat -c %Y "$pid_file" 2>/dev/null || stat -f %m "$pid_file" 2>/dev/null || echo "")
  [ -n "$mtime" ] || return 1
  threshold=$(( hb_interval * 3 ))
  [ $(( now - mtime )) -lt "$threshold" ]
}

# Echoes the current PID for the issue+kind, or empty if none.
get_pid() {
  local kind="$1" issue_num="$2"
  local pid_file
  pid_file=$(_pid_file_for "$kind" "$issue_num")
  [ -n "$pid_file" ] && cat "$pid_file" 2>/dev/null || echo ""
}

# Step 5a/5b: fetch PR info for the issue. Echoes the JSON object (single
# line) with the requested fields, or empty string if no PR found.
# `fields` is a comma-separated list passed to `--json` (e.g.
# "number,body,updatedAt" or "number,body,headRefOid").
fetch_pr_for_issue() {
  local issue_num="$1" fields="$2"
  gh pr list --repo "$REPO" --state open --json "$fields" \
    -q "[.[] | select(.body | test(\"#${issue_num}[^0-9]\") or test(\"#${issue_num}$\"))] | .[0] // empty"
}

# Step 5a: returns 0 if every CI check is SUCCESS (and at least one exists).
# Returns 1 on any other state (pending, failing, empty, transport error).
# Captures stderr to a mktemp file so transport errors can be diagnosed
# without coupling concurrent dispatcher instances to a shared /tmp path
# (CWE-377 mitigation).
ci_is_green() {
  local pr_num="$1"
  local ci_states ci_err_file ci_err_content
  ci_err_file=$(mktemp)
  if ci_states=$(gh pr checks "$pr_num" --repo "$REPO" --json state -q '[.[].state]' 2>"$ci_err_file"); then
    rm -f "$ci_err_file"
  else
    ci_err_content=$(cat "$ci_err_file")
    rm -f "$ci_err_file"
    if [ -n "$ci_err_content" ]; then
      echo "WARN: gh pr checks failed for PR #${pr_num}: ${ci_err_content}" >&2
    fi
    ci_states='[]'
  fi
  jq -e 'length > 0 and all(. == "SUCCESS")' <<<"$ci_states" >/dev/null 2>&1
}

# Step 5a: echoes seconds since PR.updatedAt. Empty on parse failure
# (caller should fail-closed and leave the issue alone).
pr_idle_seconds() {
  _iso_age_seconds "$1"
}

# Step 5b: echoes the SHA from the most recent "Reviewed HEAD: \`<sha>\`"
# trailer comment on the issue. Empty if none found (caller routes to
# pending-review per [INV-07]).
last_reviewed_head() {
  local issue_num="$1"
  gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q '[.comments[].body | capture("Reviewed HEAD: `(?<sha>[0-9a-f]{7,40})`"; "g") | .sha] | last // empty'
}

# Step 5b: echoes seconds since the most recent review-agent verdict
# comment on the issue. The verdict comment is matched on a leading
# "Review PASSED" or "Review findings" — same prefix the wrapper writes
# in autonomous-review.sh. Empty on parse failure / no match (caller
# treats as "no recent verdict").
latest_review_verdict_age_seconds() {
  local issue_num="$1"
  local latest_iso
  latest_iso=$(gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q '[.comments[] | select(.body | test("^Review (PASSED|findings)"))] | last | .createdAt // empty')
  [ -n "$latest_iso" ] || { echo ""; return; }
  _iso_age_seconds "$latest_iso"
}

# Step 5b: review_near_success <issue_num>
#
# Returns 0 (skip the "crashed" path) if ANY of these PR-state signals are
# positive within REVIEW_NEAR_SUCCESS_WINDOW_SECONDS (default 300s):
#
#   1. PR.mergedAt within window — wrapper finished merging.
#   2. Most recent APPROVED review event within window — wrapper reached
#      approve step.
#   3. Most recent "Review PASSED|findings" comment within window —
#      wrapper completed verdict.
#   4. Defensive `kill -0 <pid>` against the current PID-file content
#      now succeeds — the original pid_alive miss raced with the
#      wrapper's normal scheduling.
#
# REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=0 disables the short-circuit (legacy
# strict behavior — every pid_alive miss declares crashed).
#
# Returns 1 if all four signals are negative — caller proceeds with the
# existing crashed-comment + label-swap.
review_near_success() {
  local issue_num="$1"
  local window="${REVIEW_NEAR_SUCCESS_WINDOW_SECONDS:-300}"
  # Defensive numeric guard: non-numeric / negative falls back to legacy
  # strict (every pid_alive miss declares crashed) instead of silently
  # short-circuiting on a malformed config.
  [[ "$window" =~ ^[0-9]+$ ]] || return 1
  [ "$window" -gt 0 ] || return 1

  # Signals 1 + 2: PR.mergedAt and reviews[].
  local pr_info merged_at approved_at age
  pr_info=$(fetch_pr_for_issue "$issue_num" "number,mergedAt,reviews")
  if [ -n "$pr_info" ]; then
    merged_at=$(jq -r '.mergedAt // empty' <<<"$pr_info" 2>/dev/null)
    if [ -n "$merged_at" ] && [ "$merged_at" != "null" ]; then
      age=$(_iso_age_seconds "$merged_at")
      if [ -n "$age" ] && [ "$age" -lt "$window" ]; then
        return 0
      fi
    fi

    approved_at=$(jq -r '[.reviews[]? | select(.state == "APPROVED") | .submittedAt] | sort | last // empty' <<<"$pr_info" 2>/dev/null)
    if [ -n "$approved_at" ] && [ "$approved_at" != "null" ]; then
      age=$(_iso_age_seconds "$approved_at")
      if [ -n "$age" ] && [ "$age" -lt "$window" ]; then
        return 0
      fi
    fi
  fi

  # Signal 3: review-agent verdict comment.
  local verdict_age
  verdict_age=$(latest_review_verdict_age_seconds "$issue_num")
  if [ -n "$verdict_age" ] && [ "$verdict_age" -lt "$window" ]; then
    return 0
  fi

  # Signal 4: defensive PID re-check.
  local pid
  pid=$(get_pid review "$issue_num")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  return 1
}

# Step 4a.5: PR-exists short-circuit on the pending-dev scan. Mirrors
# Step 5b's `last_reviewed_head` check so a stale FAILED verdict against
# an unchanged PR HEAD doesn't drive an infinite re-review loop (#106).
#
# Returns:
#   0 — handled (caller should `continue` to next issue)
#   1 — no PR for this issue (caller falls through to session/dispatch logic)
#
# Side effects (only when returning 0):
#   - Same HEAD already reviewed → idempotent stale-verdict notice;
#     label stays pending-dev.
#   - HEAD differs OR no prior review → flips pending-dev → pending-review
#     and posts the Bug 3 transition comment.
handle_pending_dev_pr_exists() {
  local issue_num="$1"
  local pr_info pr_num current_head pr_ref last_head notice_marker
  pr_info=$(fetch_pr_for_issue "$issue_num" "number,headRefOid")
  if [ -z "$pr_info" ]; then
    return 1
  fi

  pr_num=$(jq -r '.number // empty' <<<"$pr_info")
  current_head=$(jq -r '.headRefOid // empty' <<<"$pr_info")
  pr_ref="${pr_num:+#${pr_num}}"
  pr_ref="${pr_ref:-(number unknown)}"
  last_head=$(last_reviewed_head "$issue_num")

  if [ -n "$last_head" ] && [ -n "$current_head" ] && [ "$current_head" = "$last_head" ]; then
    # Same HEAD already reviewed — verdict was FAILED (otherwise the issue
    # wouldn't be in pending-dev). Don't redo review; surface the stale
    # verdict and keep pending-dev so the dev agent can act on feedback.
    #
    # Idempotency check uses `grep -q '^0$'` (fail-closed): a transient
    # `gh issue view` error yields empty output, grep returns 1, and we
    # skip the post — preventing duplicate notices on rate-limit / auth
    # refresh blips. Mirrors the existing INV-12-completed marker pattern
    # in dispatcher-tick.sh:267-269.
    notice_marker="stale-verdict:${current_head}"
    if gh issue view "$issue_num" --repo "$REPO" --json comments \
        -q "[.comments[].body | select(contains(\"${notice_marker}\"))] | length" \
        2>/dev/null | grep -q '^0$'; then
      gh issue comment "$issue_num" --repo "$REPO" \
        --body "PR ${pr_ref} HEAD \`${current_head}\` already reviewed with FAILED verdict; awaiting new commits before re-review. (\`${notice_marker}\`)"
    fi
    return 0
  fi

  # New HEAD or first review — keep existing Bug 3 (#99) behavior.
  gh issue comment "$issue_num" --repo "$REPO" \
    --body "PR ${pr_ref} exists for this issue; transitioning to pending-review instead of retrying dev (#99 Bug 3)."
  label_swap "$issue_num" "pending-dev" "pending-review"
  return 0
}

# ---------------------------------------------------------------------------
# Label transitions (atomic per-edit, see [INV-08])
# ---------------------------------------------------------------------------

# Atomic single-call swap. Both label args may be empty strings.
label_swap() {
  local issue_num="$1" remove="$2" add="$3"
  local args=()
  [ -n "$remove" ] && args+=(--remove-label "$remove")
  [ -n "$add" ] && args+=(--add-label "$add")
  gh issue edit "$issue_num" --repo "$REPO" "${args[@]}"
}

# ---------------------------------------------------------------------------
# JUST_DISPATCHED skip helper
# ---------------------------------------------------------------------------

# Returns 0 (was dispatched this tick) if the issue is in JUST_DISPATCHED.
# Caller passes the array as a space-separated string in env JUST_DISPATCHED.
was_just_dispatched() {
  local issue_num="$1"
  case " ${JUST_DISPATCHED:-} " in
    *" ${issue_num} "*) return 0 ;;
    *) return 1 ;;
  esac
}
