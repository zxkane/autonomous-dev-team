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
# Parsing rules (see INV-11 in docs/pipeline/invariants.md):
#   - Only list-item lines (`-`, `*`, or `1.` markers) inside the
#     `## Dependencies` section are scanned. Prose, blockquotes, and
#     headings are ignored — this is what stops false positives where a
#     `#NNN` mentioned in passing got greedy-extracted (#157).
#   - Two ref shapes are recognized, longest first per line:
#       * `owner/repo#N` → resolved against the named repo
#       * `#N`           → resolved against $REPO (same-repo)
#   - Both shapes require a left boundary (start-of-line or whitespace) so
#     URL fragments (`https://github.com/.../issues/123`) and inline
#     punctuation aren't misparsed.
#
# Closes #61 (MERGED PRs report `state: "MERGED"`, not `"CLOSED"`),
# #73 (replace GNU-only `grep -oP '#\K[0-9]+'` with portable extraction),
# and #157 (cross-repo refs + list-only scope).
check_deps_resolved() {
  local issue_num="$1"
  local body section line state dep_repo dep_num matched
  body=$(gh issue view "$issue_num" --repo "$REPO" --json body -q '.body')
  section=$(printf '%s\n' "$body" | sed -n '/^## Dependencies/,/^## /p')

  # Stage 1: restrict to list-item lines. `grep -E` exits non-zero when
  # nothing matches; the trailing `|| true` keeps the pipeline alive so
  # the while loop simply runs zero times and we fall through to rc=0.
  while IFS= read -r line; do
    # Stage 2a: cross-repo `owner/repo#N`. Matched longest-first so that
    # `owner/repo#42` doesn't survive to be re-parsed as bare `#42`. The
    # left boundary `(^|[[:space:]\(])` rules out URL fragments and inline
    # punctuation while still allowing parenthesized refs like
    # `- (owner/repo#42)`.
    while [[ "$line" =~ (^|[[:space:]\(])([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#([0-9]+) ]]; do
      matched="${BASH_REMATCH[0]}"
      dep_repo="${BASH_REMATCH[2]}"
      dep_num="${BASH_REMATCH[3]}"
      state=$(gh issue view "$dep_num" --repo "$dep_repo" --json state -q '.state' 2>/dev/null || true)
      # Empty state means the lookup failed (404, network error, private
      # repo). [INV-39]: fail-safe blocks dispatch, but the failure must
      # be observable — otherwise we silently recreate the #157 bug class.
      if [ -z "$state" ]; then
        echo "[check_deps_resolved] WARNING: lookup failed for ${dep_repo}#${dep_num} (issue ${issue_num}); blocking" >&2
        return 1
      fi
      if [ "$state" != "CLOSED" ] && [ "$state" != "MERGED" ]; then
        return 1
      fi
      line="${line/"$matched"/ }"
    done
    # Stage 2b: bare `#N` on the residue. Same-repo lookup against $REPO.
    while [[ "$line" =~ (^|[[:space:]\(])#([0-9]+) ]]; do
      matched="${BASH_REMATCH[0]}"
      dep_num="${BASH_REMATCH[2]}"
      state=$(gh issue view "$dep_num" --repo "$REPO" --json state -q '.state' 2>/dev/null || true)
      if [ -z "$state" ]; then
        echo "[check_deps_resolved] WARNING: lookup failed for ${REPO}#${dep_num} (issue ${issue_num}); blocking" >&2
        return 1
      fi
      if [ "$state" != "CLOSED" ] && [ "$state" != "MERGED" ]; then
        return 1
      fi
      line="${line/"$matched"/ }"
    done
  done < <(printf '%s\n' "$section" | grep -E '^[[:space:]]*([-*]|[0-9]+\.)[[:space:]]' || true)

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
  local end_ts_var="${3:-}"
  # Gate on dev-side CLI per [INV-37] — this function parses the dev
  # wrapper's log, so the dispatcher-side $AGENT_CMD (project default)
  # is the wrong value to check under split-CLI deployments
  # (e.g. AGENT_CMD=claude AGENT_DEV_CMD=codex).
  local _dev_cmd="${AGENT_DEV_CMD:-${AGENT_CMD:-claude}}"
  [ "$_dev_cmd" = "claude" ] || return 1

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
    if [ -n "$end_ts_var" ]; then
      # INV-35: derive session-end ISO-8601 timestamp from the log file's
      # mtime. The wrapper writes the final "Agent exited" log line at
      # session end so mtime is a reliable proxy across any agent CLI; the
      # claude result-JSON itself does not carry a date. Empty on date(1)
      # failure — the caller treats empty as "no time filter", which is
      # safe (we surface ALL bot comments rather than miss a recent one).
      local _mtime_iso
      _mtime_iso=$(date -u -r "$log_file" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
      printf -v "$end_ts_var" '%s' "$_mtime_iso"
    fi
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# INV-35: review-verdict classification for completed dev sessions.
# ---------------------------------------------------------------------------
#
# classify_recent_review_verdict <issue_num> <session_end_iso> <verdict_var> <cause_var>
#
# Reads issue comments, finds the newest comment that:
#   (a) was authored by ${BOT_LOGIN} (or matches the session-id-binding
#       fallback when BOT_LOGIN is empty per the gh-api-user-403 pattern),
#   (b) was created strictly after <session_end_iso>,
#   (c) has body containing a `<!-- review-verdict: ... -->` HTML-comment
#       trailer — OR is a generic verdict comment without a trailer (legacy).
#
# Out-vars receive:
#   verdict_var ∈ { none, passed, failed-substantive, failed-non-substantive }
#   cause_var   — non-empty only when verdict is failed-non-substantive.
#
# Always returns 0. See docs/designs/inv35-review-aware-resume.md § 5.
classify_recent_review_verdict() {
  local issue_num="$1"
  local session_end="$2"
  local verdict_var="$3"
  local cause_var="$4"

  printf -v "$verdict_var" '%s' "none"
  printf -v "$cause_var"   '%s' ""

  # Build the actor predicate. When BOT_LOGIN is empty (the gh-api-user-403
  # fallback), drop actor-binding and rely on FALLBACK_SESSION_ID embedded
  # in the comment body (the same "Review Session: <sid>" trailer the
  # review wrapper already emits per autonomous-review.sh:588-590).
  local actor_predicate
  if [ -n "${BOT_LOGIN:-}" ]; then
    actor_predicate=".author.login == \"${BOT_LOGIN}\""
  elif [ -n "${FALLBACK_SESSION_ID:-}" ]; then
    actor_predicate="(.body | test(\"Review Session.*${FALLBACK_SESSION_ID}\"))"
  else
    # Without an actor signal AND without a session-id fallback, refuse to
    # classify — surface no verdict so the caller falls back to the safe
    # INV-12-completed branch (operator handoff). This is conservative:
    # emitting a verdict without authenticity binding could route on a
    # comment posted by an unrelated user.
    return 0
  fi

  # Pull the newest qualifying comment body. Strict `>` on createdAt
  # excludes a comment timestamped exactly at session end (rare, but the
  # design pins this for determinism).
  local newest_body
  newest_body=$(gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q "[.comments[] | select(${actor_predicate} and (.createdAt > \"${session_end}\"))] | sort_by(.createdAt) | last | .body // empty" \
    2>/dev/null)

  [ -n "$newest_body" ] || return 0

  # Match the trailer — first occurrence wins (TC-INV35-CL-007 pins this
  # to "first" rather than "last" so a quoted prior verdict can't override
  # the actual current verdict in pathological cases).
  local trailer_line
  trailer_line=$(printf '%s' "$newest_body" | grep -oE '<!--[[:space:]]*review-verdict:[[:space:]]*[a-z-]+([[:space:]]+cause=[a-zA-Z0-9_-]+)?[[:space:]]*-->' | head -1)

  if [ -z "$trailer_line" ]; then
    # Legacy: bot-authored comment with no trailer is conservatively
    # treated as failed-substantive so a pre-INV-35 in-flight verdict
    # routes to the safe fresh-dev branch (rather than silently no-op
    # like 'passed' would). See design §4 backwards-compat note.
    printf -v "$verdict_var" '%s' "failed-substantive"
    return 0
  fi

  # Parse trailer fields.
  # Avoid generic local names (v, c) — they would shadow the caller-supplied
  # var names that printf -v resolves through, e.g. caller passes "v" as the
  # out-var name and `local v` would mask it.
  local _parsed_verdict _parsed_cause
  _parsed_verdict=$(printf '%s' "$trailer_line" | sed -nE 's/<!--[[:space:]]*review-verdict:[[:space:]]*([a-z-]+).*-->/\1/p')
  _parsed_cause=$(printf '%s' "$trailer_line" | sed -nE 's/.*cause=([a-zA-Z0-9_-]+).*/\1/p')

  case "$_parsed_verdict" in
    passed|failed-substantive|failed-non-substantive)
      printf -v "$verdict_var" '%s' "$_parsed_verdict"
      [ "$_parsed_verdict" = "failed-non-substantive" ] && printf -v "$cause_var" '%s' "$_parsed_cause"
      ;;
    *)
      # Unknown verdict token — treat as missing-trailer (failed-substantive).
      printf -v "$verdict_var" '%s' "failed-substantive"
      ;;
  esac
  return 0
}

# Echo the count of review-aware-flip markers scoped to a given dev session.
# Used by Step 4b.5.1 to enforce REVIEW_RETRY_LIMIT on a per-session basis
# (a fresh dev_new resets the counter, by design).
count_review_aware_flips() {
  local issue_num="$1"
  local session_id="$2"
  [ -n "$session_id" ] || { printf '%s' "0"; return 0; }
  gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q "[.comments[].body | select(contains(\"<!-- review-aware-flip:non-substantive\")) | select(contains(\"session=${session_id}\"))] | length" \
    2>/dev/null || printf '%s' "0"
}

# ---------------------------------------------------------------------------
# INV-35 Step 4b.5.1: review-aware routing for `completed` sessions.
# ---------------------------------------------------------------------------
#
# handle_completed_session_routing <issue_num> <session_id> <session_end_iso>
#
# Returns 0 always (caller `continue`s after this branch).
#
# Routes a `pending-dev` issue whose prior dev session reached
# `end_turn|completed` per the verdict-classification table in
# docs/designs/inv35-review-aware-resume.md § 3:
#
#   verdict=none                          → INV-12-completed marker (idempotent)
#   verdict=passed                        → no-op + WARN log (race window)
#   verdict=failed-substantive            → INV-35-fresh-dev + truncate +
#                                           label_swap → in-progress + dev-new
#   verdict=failed-non-substantive,
#     under cap                           → label_swap → pending-review +
#                                           review-aware-flip marker
#   verdict=failed-non-substantive,
#     at/over cap (REVIEW_RETRY_LIMIT)    → mark_stalled + operator @-mention
handle_completed_session_routing() {
  local issue_num="$1"
  local session_id="$2"
  local session_end_iso="$3"

  local _verdict="" _cause=""
  classify_recent_review_verdict "$issue_num" "$session_end_iso" _verdict _cause

  case "$_verdict" in
    none)
      # Original INV-12 operator handoff — preserved for back-compat.
      log "  issue #${issue_num} session ${session_id} already completed (no post-session verdict) — operator handoff"
      local _notice_marker="INV-12-completed:${session_id}"
      if gh issue view "$issue_num" --repo "$REPO" --json comments \
          -q "[.comments[].body | select(contains(\"${_notice_marker}\"))] | length" \
          2>/dev/null | grep -q '^0$'; then
        gh issue comment "$issue_num" --repo "$REPO" \
          --body "Session \`${session_id}\` already ended (stop_reason=end_turn, terminal_reason=completed). Resume would hang on idle SSE — skipping. Manually transition to \`pending-review\` if a PR exists, or close the issue if work is done. (\`${_notice_marker}\`)"
      fi
      return 0
      ;;

    passed)
      # Race: review wrapper posted `passed` and was about to flip to
      # `approved`/`reviewing`-cleanup, but the issue is currently still
      # `pending-dev` (operator manually flipped, or a label-edit raced).
      # Don't post — Step 0 hygiene reconciles next tick.
      log "  WARN: issue #${issue_num} pending-dev with passed verdict (race) — no-op, Step 0 will reconcile"
      return 0
      ;;

    failed-non-substantive)
      local _flip_count
      _flip_count=$(count_review_aware_flips "$issue_num" "$session_id")
      _flip_count="${_flip_count:-0}"
      local _limit="${REVIEW_RETRY_LIMIT:-2}"
      # cap=0 → unbounded (operator opt-in to bounce-forever).
      if [ "$_limit" -gt 0 ] && [ "$_flip_count" -ge "$_limit" ]; then
        log "  issue #${issue_num} non-substantive review failure (cause=${_cause}) reached REVIEW_RETRY_LIMIT=${_limit} — stalling"
        gh issue comment "$issue_num" --repo "$REPO" \
          --body "Persistent review-failure-non-substantive on session \`${session_id}\` (cause=\`${_cause}\`, flips=${_flip_count}/${_limit}). Marking stalled. @${REPO_OWNER} please investigate the upstream review dependency (bot/CI/transport)."
        mark_stalled "$issue_num"
        return 0
      fi
      log "  issue #${issue_num} non-substantive review failure (cause=${_cause}, flip ${_flip_count}/${_limit}) — flipping to pending-review"
      gh issue comment "$issue_num" --repo "$REPO" \
        --body "$(printf '%s\n%s' \
          "<!-- review-aware-flip:non-substantive cause=${_cause} session=${session_id} -->" \
          "Re-routing to review (last review failed for non-substantive reason: ${_cause}).")"
      label_swap "$issue_num" "pending-dev" "pending-review"
      return 0
      ;;

    failed-substantive)
      log "  issue #${issue_num} substantive review failure on completed session ${session_id} — minting fresh dev session"
      local _fresh_marker="INV-35-fresh-dev:${session_id}"
      if gh issue view "$issue_num" --repo "$REPO" --json comments \
          -q "[.comments[].body | select(contains(\"${_fresh_marker}\"))] | length" \
          2>/dev/null | grep -q '^0$'; then
        gh issue comment "$issue_num" --repo "$REPO" \
          --body "Review failed substantively on completed session \`${session_id}\`. A completed session cannot be resumed; minting a fresh dev session via the INV-12 PTL recovery pattern. (\`${_fresh_marker}\`)"
      fi
      # Truncate per-issue log so the next tick sees an empty log and
      # doesn't re-trigger this completed-detection branch. Fail-closed
      # (mirrors the INV-12 PTL guard at dispatcher-tick.sh:298-303): if
      # truncate fails, the next tick would re-read the same stale log
      # line, the idempotency marker would suppress a fresh notice, and
      # we'd silently dispatch dev-new every tick forever.
      local _log_file="/tmp/agent-${PROJECT_ID}-issue-${issue_num}.log"
      if ! : > "$_log_file" 2>/dev/null; then
        log "  ERROR: failed to truncate ${_log_file} (perm/disk?). Skipping INV-35 dev-new dispatch to avoid re-detection loop."
        gh issue comment "$issue_num" --repo "$REPO" \
          --body "Could not reset agent log at \`${_log_file}\` for fresh INV-35 dispatch (permission or disk error). Operator: please clear the log file and retry. Skipping dispatch to prevent a silent retry loop." 2>/dev/null || true
        return 0
      fi
      label_swap "$issue_num" "pending-dev" "in-progress"
      post_dispatch_token "$issue_num" "dev-new"
      dispatch dev-new "$issue_num"
      return 0
      ;;

    *)
      # Defensive — classifier should never return anything else, but if
      # it does, fall through to the original INV-12-completed operator
      # handoff (safest).
      log "  WARN: classify_recent_review_verdict returned unknown verdict '${_verdict}' for issue #${issue_num} — falling back to operator handoff"
      local _notice_marker_default="INV-12-completed:${session_id}"
      if gh issue view "$issue_num" --repo "$REPO" --json comments \
          -q "[.comments[].body | select(contains(\"${_notice_marker_default}\"))] | length" \
          2>/dev/null | grep -q '^0$'; then
        gh issue comment "$issue_num" --repo "$REPO" \
          --body "Session \`${session_id}\` completed; verdict classifier returned unexpected value. Operator handoff. (\`${_notice_marker_default}\`)"
      fi
      return 0
      ;;
  esac
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
# Three-tier check (#111 Part B + INV-29, closes #129):
#   1. `kill -0 <pid>` succeeds → ALIVE.
#   2. PID file mtime is fresh (within HEARTBEAT_INTERVAL_SECONDS * 3,
#      default 360s) → ALIVE. Back-compat path for pre-INV-29 wrappers
#      that only touch the PID file.
#   3. Sibling `<base>.heartbeat` file mtime is fresh → ALIVE.
#   Otherwise → DEAD.
#
# Why two files (INV-29): the heartbeat sibling's lifecycle is owned
# exclusively by the wrapper — created and cleaned up by the wrapper's
# cleanup trap, NOT by the dispatcher. The dispatcher's
# `kill_stale_wrapper` may legitimately delete the PID file (after
# killing its holder); without the sibling, a spurious PID-file
# deletion against a still-alive wrapper would strand `pid_alive` and
# false-flag the agent as DEAD on subsequent ticks (the failure mode in
# #129). The sibling survives such deletions, so the wrapper's
# still-running heartbeat keeps the mtime fresh and the probe stays
# accurate. The PID file content (holding the agent-tree session leader
# PID) is not used here beyond tier 1 — its mtime is a back-compat
# heartbeat carrier only.
#
# _remote_pid_alive_query <kind> <issue_num>
#
# Synchronous SSM query into the wrapper box's PID file + heartbeat
# state. Used by `pid_alive` under `EXECUTION_BACKEND=remote-aws-ssm`
# ([INV-30]). Prints exactly one of `ALIVE` / `DEAD` / empty on stdout
# (the tri-state contract from `liveness-check-remote-aws-ssm.sh`).
#
# Resolves the driver path via parameter expansion (no `dirname`) so
# PATH-scrubbed callers still work. Test override:
# `_LIVENESS_CHECK_DRIVER_OVERRIDE` lets tests substitute a stub
# driver without modifying PATH.
#
# IMPORTANT: this helper MUST NOT increment any per-process counter
# itself, because callers consume its stdout via `$(...)` command
# substitution which forks a subshell. Counter mutations inside that
# subshell die with it. The counter + WARN cadence are owned by
# `pid_alive` directly (see TC-RPA-008/009 regression).
_remote_pid_alive_query() {
  local kind="$1" issue_num="$2"
  local driver
  if [ -n "${_LIVENESS_CHECK_DRIVER_OVERRIDE:-}" ]; then
    driver="$_LIVENESS_CHECK_DRIVER_OVERRIDE"
  else
    local _src="${BASH_SOURCE[0]:-$0}"
    driver="${_src%/*}/liveness-check-remote-aws-ssm.sh"
  fi

  local out rc
  out=$(bash "$driver" "$kind" "$issue_num" 2>/dev/null)
  rc=$?

  case "$rc:$out" in
    0:ALIVE) printf 'ALIVE' ;;
    0:DEAD)  printf 'DEAD'  ;;
    *)       printf ''      ;;
  esac
  return 0
}

# HEARTBEAT_INTERVAL_SECONDS=0 disables both mtime tiers entirely
# (legacy strict behavior).
#
# Under EXECUTION_BACKEND=remote-aws-ssm (#137, [INV-30]): the
# dispatcher's box doesn't host the wrapper's filesystem, so all three
# legacy tiers always miss. A remote-backend short-circuit consults
# `liveness-check-remote-aws-ssm.sh` (which reaches the wrapper box via
# SSM) and returns its tri-state verdict. Indeterminate verdicts
# (transport fault, timeout, parse error) bias toward ALIVE — the
# whole point of [INV-30] is that the dispatcher must never declare
# crashed because it lacks information.
#
# `_REMOTE_LIVENESS_DEGRADED_COUNT` (per-process counter) records
# consecutive indeterminate verdicts; `_remote_pid_alive_query` emits
# a WARN to stderr on the 1st and every 10th indeterminate tick so
# operators see the degraded state without per-tick log spam.
_REMOTE_LIVENESS_DEGRADED_COUNT="${_REMOTE_LIVENESS_DEGRADED_COUNT:-0}"

pid_alive() {
  local kind="$1" issue_num="$2"
  local pid_file pid hb_file

  # Remote-backend short-circuit ([INV-30]). Runs first because under
  # remote-aws-ssm the legacy three-tier below would all miss; running
  # them anyway just wastes filesystem stat calls.
  if [ "${EXECUTION_BACKEND:-local}" = "remote-aws-ssm" ] \
     && [ "${REMOTE_LIVENESS_CHECK_DISABLE:-false}" != "true" ]; then
    local _verdict
    _verdict=$(_remote_pid_alive_query "$kind" "$issue_num")
    case "$_verdict" in
      ALIVE) return 0 ;;
      DEAD)  return 1 ;;
      *)
        # Indeterminate (driver rc≠0 or stdout neither ALIVE nor
        # DEAD). User-chosen policy ([INV-30]): bias toward ALIVE so
        # a flaky transport never produces a false crash declaration.
        # The legacy three-tier below would all miss under remote
        # backend (filesystem on the wrong box), so falling through
        # would always declare DEAD — exactly the failure mode this
        # invariant closes. Treat indeterminate as ALIVE here so the
        # caller defers crash declaration by one tick.
        #
        # Source-of-truth: TC-RPA-010 grep-asserts this `*) return 0`
        # exact form. A reflexive cleanup PR that flips it to
        # `return 1` re-introduces the #182 false-stall bug.
        #
        # Counter + WARN cadence MUST live here, NOT inside
        # `_remote_pid_alive_query`, because that function's stdout
        # is captured via `$(...)` (a subshell) — counter mutations
        # there would die with the subshell. (TC-RPA-008/009)
        _REMOTE_LIVENESS_DEGRADED_COUNT=$((_REMOTE_LIVENESS_DEGRADED_COUNT + 1))
        # Emit WARN on the 1st indeterminate tick AND every 10th
        # thereafter (counts 1, 10, 20, 30, ...). Frequent enough to
        # surface a degraded transport quickly; sparse enough to not
        # spam logs once the operator is aware. (TC-RPA-009)
        if [ "$_REMOTE_LIVENESS_DEGRADED_COUNT" -eq 1 ] \
           || [ $((_REMOTE_LIVENESS_DEGRADED_COUNT % 10)) -eq 0 ]; then
          echo "[lib-dispatch] WARN: remote liveness check indeterminate" \
               "(kind=$kind issue=$issue_num" \
               "count=$_REMOTE_LIVENESS_DEGRADED_COUNT); biasing toward ALIVE per [INV-30]" >&2
        fi
        return 0
        ;;
    esac
  fi

  pid_file=$(_pid_file_for "$kind" "$issue_num")
  [ -n "$pid_file" ] || return 1
  hb_file="${pid_file%.pid}.heartbeat"
  pid=$(cat "$pid_file" 2>/dev/null || echo "")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  local hb_interval="${HEARTBEAT_INTERVAL_SECONDS:-120}"
  # Defensive numeric guard: a typo here would silently flip ALIVE → DEAD,
  # the exact failure mode #111 fixes. Treat non-numeric / negative as
  # "fallback disabled" (legacy strict).
  [[ "$hb_interval" =~ ^[0-9]+$ ]] || return 1
  [ "$hb_interval" -gt 0 ] || return 1

  local now threshold mtime
  now=$(date -u +%s)
  threshold=$(( hb_interval * 3 ))

  # Tier 2: PID-file mtime (back-compat with pre-INV-29 wrappers that
  # only touch the PID file). Symlink-defended (CWE-59).
  if [ -f "$pid_file" ] && [ ! -L "$pid_file" ]; then
    mtime=$(stat -c %Y "$pid_file" 2>/dev/null || stat -f %m "$pid_file" 2>/dev/null || echo "")
    if [ -n "$mtime" ] && [ $(( now - mtime )) -lt "$threshold" ]; then
      return 0
    fi
  fi

  # Tier 3: heartbeat sibling mtime (INV-29). Owned exclusively by the
  # wrapper — survives spurious PID-file deletion. Same symlink defence.
  if [ -f "$hb_file" ] && [ ! -L "$hb_file" ]; then
    mtime=$(stat -c %Y "$hb_file" 2>/dev/null || stat -f %m "$hb_file" 2>/dev/null || echo "")
    if [ -n "$mtime" ] && [ $(( now - mtime )) -lt "$threshold" ]; then
      return 0
    fi
  fi

  return 1
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
  # `.body` is null when a PR has an empty description. Guard before
  # `test()` — `null | test(...)` aborts the jq filter, drops to stderr, and
  # silently hides any matching PR (issue #148).
  gh pr list --repo "$REPO" --state open --json "$fields" \
    -q "[.[] | select(.body != null and ((.body | test(\"#${issue_num}[^0-9]\")) or (.body | test(\"#${issue_num}$\"))))] | .[0] // empty"
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

# Step 5b: echoes seconds since the most recent "Agent Session Report
# (Dev) ... Exit code: 0" comment on the issue. Empty on parse failure
# / no match (caller treats as "no recent success").
latest_dev_success_age_seconds() {
  local issue_num="$1"
  local latest_iso
  latest_iso=$(gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q '[.comments[] | select((.body | test("Agent Session Report \\(Dev\\)")) and (.body | test("Exit code: 0\\b")))] | last | .createdAt // empty')
  [ -n "$latest_iso" ] || { echo ""; return; }
  _iso_age_seconds "$latest_iso"
}

# Step 5b: echoes seconds since the most recent "Dev Session ID:"
# comment on the issue. Empty on no match (caller treats as
# "no recent startup confirmation"). The dev wrapper writes this
# comment as part of its startup handshake ([INV-21]); a recent one
# means the agent confirmed startup within the window — a `pid_alive`
# miss in that window is overwhelmingly likely a transient probe race.
latest_dev_session_id_age_seconds() {
  local issue_num="$1"
  local latest_iso
  latest_iso=$(gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q '[.comments[] | select(.body | test("Dev Session ID:"))] | last | .createdAt // empty')
  [ -n "$latest_iso" ] || { echo ""; return; }
  _iso_age_seconds "$latest_iso"
}

# Step 5b: dev_near_success <issue_num>
#
# Dev-side analog of `review_near_success` (see [INV-24]). Returns 0
# (skip the "Task appears to have crashed (no PR found)" path) if ANY
# of these signals are positive within DEV_NEAR_SUCCESS_WINDOW_SECONDS
# (default 300s):
#
#   1. Most recent `Agent Session Report (Dev) ... Exit code: 0`
#      comment within window — agent already finished successfully (no
#      PR yet, but operator may not have reviewed; PR detection failure
#      on the dispatcher side is NOT an agent failure).
#   2. Most recent `Dev Session ID:` comment within window — agent
#      confirmed startup recently; the `pid_alive` miss is a transient
#      probe race against a healthy wrapper.
#   3. Defensive `kill -0 <pid>` against the current PID-file content
#      now succeeds — the original `pid_alive` miss raced with normal
#      wrapper scheduling.
#   4. Process-group walk (#137; parity with [INV-24] signal 5):
#      `_pgid_has_agent_process <pgid>` finds an AGENT_CMD descendant
#      under the wrapper's PGID. Catches the gap reproduced on a
#      downstream consumer's #182 (long-running TDD agent SIGTERMed
#      before it could emit a `Dev Session ID:` comment): signals 1+2
#      are timestamp-based and miss when the agent never produced an
#      artifact, signal 3 misses when the session-leader PID drifts out
#      of `kill -0` reachability under launcher indirection, but the
#      PGID walk catches a live agent subtree.
#
# DEV_NEAR_SUCCESS_WINDOW_SECONDS=0 disables the short-circuit (legacy
# strict — every pid_alive miss declares crashed). Non-numeric /
# negative falls back to legacy strict (parity with [INV-24]).
#
# Returns 1 if all four signals are negative — caller proceeds with
# the existing "Task appears to have crashed" comment + label swap.
#
# This invariant is [INV-27]; see also [INV-24] (review-side analog),
# [INV-26] (downstream gate that defers `mark_stalled` when the
# wrapper is alive), and [INV-30] (remote-aws-ssm `pid_alive`
# authoritative override that reaches the wrapper box directly).
dev_near_success() {
  local issue_num="$1"
  local window="${DEV_NEAR_SUCCESS_WINDOW_SECONDS:-300}"
  [[ "$window" =~ ^[0-9]+$ ]] || return 1
  [ "$window" -gt 0 ] || return 1

  # Signal 1: recent successful Session Report.
  local success_age
  success_age=$(latest_dev_success_age_seconds "$issue_num")
  if [ -n "$success_age" ] && [ "$success_age" -lt "$window" ]; then
    return 0
  fi

  # Signal 2: recent Dev Session ID confirmation.
  local startup_age
  startup_age=$(latest_dev_session_id_age_seconds "$issue_num")
  if [ -n "$startup_age" ] && [ "$startup_age" -lt "$window" ]; then
    return 0
  fi

  # Signal 3: defensive PID re-check.
  local pid
  pid=$(get_pid issue "$issue_num")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  # Signal 4: process-group walk (#137 parity with [INV-24] signal 5).
  # Skipped silently when PID is empty / unparseable (mirrors the
  # caller-site contract used by review_near_success in this same file).
  # Pass dev-side CLI per [INV-37] so a project running
  # AGENT_DEV_CMD=codex still finds the codex process even when the
  # dispatcher's $AGENT_CMD is the project default (e.g. claude).
  if [ -n "$pid" ] && _pgid_has_agent_process "$pid" "${AGENT_DEV_CMD:-${AGENT_CMD:-claude}}"; then
    return 0
  fi

  return 1
}

# _pgid_has_agent_process <pgid> [agent_cmd_override]
#
# Process-group walk shared between dev_near_success (signal 4, #137)
# and review_near_success (signal 5, #132). Walks the wrapper's process
# group (PGID == content of `<kind>-${ISSUE}.pid`; setsid in
# lib-agent.sh::_run_with_timeout makes the session-leader PID equal to
# the PGID) and returns 0 if any group member's `comm` matches the
# expected agent CLI name.
#
# 2nd arg [INV-37, agy review Finding 2 from PR #156]: optional
# per-side CLI override. Empty / missing falls back to $AGENT_CMD for
# back-compat with existing call sites and tests. Required when the
# project uses split per-side CLIs (e.g. AGENT_DEV_CMD=claude,
# AGENT_REVIEW_CMD=agy): the dispatcher tick's $AGENT_CMD is the
# project default, but each wrapper runs with its side's override —
# matching against the dispatcher-side $AGENT_CMD would false-negative
# the live wrapper. Callers MUST pass the correct per-side value
# (dev_near_success → AGENT_DEV_CMD, review_near_success →
# AGENT_REVIEW_CMD).
#
# Returns 1 silently in three cases — never fail-closed:
#   - PGID is not a positive integer (empty / unparseable PID file)
#   - `pgrep` or `ps` not on PATH (mismatched host)
#   - No member of the group has a comm matching the resolved CLI name
#
# Substring match (`*${agent_cmd}*`) is intentionally tolerant: Linux
# truncates `comm` to 15 chars (so `claude-cli-with-extras` shows up as
# `claude-cli-with`), and CLI values are typically 5–10 chars.
# Over-match is safe here — this signal only runs after pid_alive missed
# AND the cheaper signals already failed, so a false positive defers a
# crash declaration by one tick at most, while a false negative
# reproduces the #209 / #182 false-crash patterns that drove the
# addition of this signal on each side.
#
# (Was originally named `_review_pgid_has_agent_process` in #132; renamed
# in #137 once the dev side gained a parity signal. No backwards-compat
# shim — the only out-of-lib consumer was the existing test mock at
# tests/unit/test-dispatcher-review-near-success.sh, updated in the
# same PR.)
_pgid_has_agent_process() {
  local pgid="$1"
  local agent_cmd="${2:-${AGENT_CMD:-claude}}"
  [[ "$pgid" =~ ^[0-9]+$ ]] || return 1
  [ "$pgid" -gt 0 ] || return 1
  command -v pgrep >/dev/null 2>&1 || return 1
  command -v ps >/dev/null 2>&1 || return 1

  local pid comm
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    [ -n "$comm" ] || continue
    if [[ "$comm" == *"$agent_cmd"* ]]; then
      return 0
    fi
  done < <(pgrep -g "$pgid" 2>/dev/null)

  return 1
}

# Step 5b: review_near_success <issue_num>
#
# Returns 0 (skip the "crashed" path) if ANY of these signals are
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
#   5. Process-group walk (#132): the review wrapper's PGID still has
#      at least one descendant whose comm matches AGENT_CMD. Catches
#      the "long-running review wrapper, pre-verdict window" case where
#      signals 1–4 all trail the still-mid-flight wrapper. Reproduced
#      on a downstream consumer's #209 (2026-05-15 UTC).
#
# Signal ordering is cost-driven, cheapest first: 1+2 share one
# fetch_pr_for_issue call, 3 is one gh-api call, 4 is a single kill -0,
# 5 hits the kernel proc table. Earlier signals short-circuit before
# later ones run; TC-RNS-009 pins this ordering so a future refactor
# can't silently reorder and double the per-tick cost.
#
# REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=0 disables the entire short-circuit
# (legacy strict behavior — every pid_alive miss declares crashed). The
# strict knob fires at the early numeric guard, before any signal runs;
# TC-RNS-010 pins that the new signal cannot override the strict knob.
#
# Returns 1 if all five signals are negative — caller proceeds with the
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

  # Signal 5: process-group walk (#132; renamed to shared helper in #137).
  # Skipped silently when PID is empty / unparseable (TC-RNS-011) — the
  # helper's own integer guard would catch it, but checking here keeps
  # the caller's contract explicit and avoids ever spawning the helper
  # subshell on bad input.
  # Pass review-side CLI per [INV-37] so a project running
  # AGENT_REVIEW_CMD=agy still finds the agy process even when the
  # dispatcher's $AGENT_CMD is the project default (e.g. claude).
  if [ -n "$pid" ] && _pgid_has_agent_process "$pid" "${AGENT_REVIEW_CMD:-${AGENT_CMD:-claude}}"; then
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
