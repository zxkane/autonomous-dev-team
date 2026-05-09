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
list_pending_review() {
  gh issue list --repo "$REPO" --state open --limit 100 \
    --label "autonomous,pending-review" --json number,labels \
    -q '[.[] | select([.labels[].name] | contains(["reviewing"]) | not)]'
}

# Step 4: issues with `autonomous` + `pending-dev`.
# Echoes JSON array of {number, labels, comments}.
list_pending_dev() {
  gh issue list --repo "$REPO" --state open --limit 100 \
    --label "autonomous,pending-dev" --json number,labels,comments
}

# Step 5: issues currently in active state (in-progress OR reviewing) — same
# query as count_active but returning {number, labels} so callers can branch on
# which active label is set.
list_stale_candidates() {
  gh issue list --repo "$REPO" --state open --limit 100 \
    --label "autonomous" --json number,labels \
    -q '[.[] | select(.labels[].name | IN("in-progress","reviewing"))]'
}

# ---------------------------------------------------------------------------
# Step 2: dependency check
# ---------------------------------------------------------------------------

# Returns 0 (resolved) if every issue referenced in the issue body's
# `## Dependencies` section is in state CLOSED. Returns 1 (blocked) on
# the first unresolved dependency. Returns 0 if no dependencies are listed.
#
# NOTE: this preserves the current "state != CLOSED" check, which means
# MERGED PRs are treated as unresolved (#61). PR-4 will fix that.
check_deps_resolved() {
  local issue_num="$1"
  local deps state
  deps=$(gh issue view "$issue_num" --repo "$REPO" --json body -q '.body' \
    | sed -n '/^## Dependencies/,/^## /p' \
    | grep -oP '#\K[0-9]+' || true)

  for dep in $deps; do
    state=$(gh issue view "$dep" --repo "$REPO" --json state -q '.state')
    if [ "$state" != "CLOSED" ]; then
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
#   - Agent Session Report (Dev) comments with non-zero exit code
#   - Dispatcher-detected crash comments matching [INV-06]'s keyword regex
#
# When MAX_RETRIES is hit, mark_stalled() is the appropriate action.
count_retries() {
  local issue_num="$1"
  local last_stalled_at agent_failures dispatcher_crashes
  last_stalled_at=$(gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q '[.comments[] | select(.body | test("Marking as stalled"))] | last | .createdAt // "1970-01-01T00:00:00Z"')

  agent_failures=$(gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q "[.comments[] | select((.createdAt > \"${last_stalled_at}\") and (.body | test(\"Agent Session Report \\\\(Dev\\\\)\")) and (.body | test(\"Exit code: 0\") | not))] | length")

  dispatcher_crashes=$(gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q "[.comments[] | select((.createdAt > \"${last_stalled_at}\") and (.body | test(\"Task appears to have crashed \\\\(no PR found\\\\)|process not found\")))] | length")

  echo $((agent_failures + dispatcher_crashes))
}

# Echoes the agent_failures count separately (used by mark_stalled comment).
count_agent_failures() {
  local issue_num="$1"
  local last_stalled_at
  last_stalled_at=$(gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q '[.comments[] | select(.body | test("Marking as stalled"))] | last | .createdAt // "1970-01-01T00:00:00Z"')
  gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q "[.comments[] | select((.createdAt > \"${last_stalled_at}\") and (.body | test(\"Agent Session Report \\\\(Dev\\\\)\")) and (.body | test(\"Exit code: 0\") | not))] | length"
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
  local agent_failures dispatcher_crashes
  agent_failures=$(count_agent_failures "$issue_num")
  dispatcher_crashes=$(count_dispatcher_crashes "$issue_num")
  gh issue edit "$issue_num" --repo "$REPO" \
    --remove-label "pending-dev" \
    --add-label "stalled"
  gh issue comment "$issue_num" --repo "$REPO" \
    --body "Issue has exceeded the maximum retry limit (${MAX_RETRIES} failed attempts: ${agent_failures} agent failures + ${dispatcher_crashes} dispatcher-detected crashes). Marking as stalled. @${REPO_OWNER} please investigate manually."
}

# ---------------------------------------------------------------------------
# Step 4: session-id extraction
# ---------------------------------------------------------------------------

# Echoes the most recent Dev Session ID for the issue (must NOT match
# Review Session ID — see [INV-03]). Echoes empty string if none found.
extract_dev_session_id() {
  local issue_num="$1"
  gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q '[.comments[].body | capture("Dev Session ID: `(?P<id>[a-zA-Z0-9_-]+)`"; "g") | .id] | last // empty'
}

# ---------------------------------------------------------------------------
# Step 5: stale detection helpers
# ---------------------------------------------------------------------------

# Returns 0 if the wrapper PID for this issue+kind is alive, 1 otherwise.
# `kind` is "issue" (dev wrapper) or "review".
pid_alive() {
  local kind="$1" issue_num="$2"
  local pid_file pid
  pid_file="/tmp/agent-${PROJECT_ID}-${kind}-${issue_num}.pid"
  pid=$(cat "$pid_file" 2>/dev/null || echo "")
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Echoes the current PID for the issue+kind, or empty if none.
get_pid() {
  local kind="$1" issue_num="$2"
  cat "/tmp/agent-${PROJECT_ID}-${kind}-${issue_num}.pid" 2>/dev/null || echo ""
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
# (caller should fail-closed and leave the issue alone). Cross-platform
# date parsing (GNU `date -d` vs BSD `date -j -f`).
pr_idle_seconds() {
  local pr_updated_at="$1"
  local pr_updated_epoch now_epoch
  pr_updated_epoch=$(date -u -d "$pr_updated_at" +%s 2>/dev/null \
    || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$pr_updated_at" +%s 2>/dev/null \
    || echo "")
  if [ -z "$pr_updated_epoch" ]; then
    echo ""
    return
  fi
  now_epoch=$(date -u +%s)
  echo $(( now_epoch - pr_updated_epoch ))
}

# Step 5b: echoes the SHA from the most recent "Reviewed HEAD: \`<sha>\`"
# trailer comment on the issue. Empty if none found (caller routes to
# pending-review per [INV-07]).
last_reviewed_head() {
  local issue_num="$1"
  gh issue view "$issue_num" --repo "$REPO" --json comments \
    -q '[.comments[].body | capture("Reviewed HEAD: `(?<sha>[0-9a-f]{7,40})`"; "g") | .sha] | last // empty'
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
