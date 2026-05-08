---
name: autonomous-dispatcher
description: >
  This skill should be used when dispatching autonomous development or review
  tasks from GitHub issues. Covers scanning for new issues with the 'autonomous'
  label, dispatching dev-new/dev-resume/review processes, dependency checking,
  retry counting, stale process detection, and concurrency limiting. Use when
  asked to "run the dispatcher", "scan for pending issues", "dispatch autonomous
  tasks", "check stale agents", or "set up the dispatch cron".
metadata: {"openclaw": {"requires": {"bins": ["gh", "jq"], "env": ["PROJECT_DIR"]}}}
---

# Autonomous Dev Team Dispatcher

Scan GitHub issues and dispatch dev/review tasks locally.

> **Security Note**: This dispatcher processes GitHub issue content as input. In public repositories, issue content is untrusted — anyone can create issues. Ensure the `autonomous` label can only be applied by trusted maintainers (use GitHub branch rulesets or organizational policies). The dispatcher itself only reads labels/comments and spawns local processes — it does NOT modify source code or push to branches.

## GitHub Authentication — USE APP TOKEN, NOT USER TOKEN

**CRITICAL:** All `gh` CLI calls MUST use a GitHub App token, NOT the default user token.

**Before running any `gh` command**, generate and export the App token using the shared script at `scripts/gh-app-token.sh`:

```bash
# Source the shared token generator
source "${PROJECT_DIR}/scripts/gh-app-token.sh"

# Generate token for the dispatcher's GitHub App
GH_TOKEN=$(get_gh_app_token "$DISPATCHER_APP_ID" "$DISPATCHER_APP_PEM" "$REPO_OWNER" "$REPO_NAME") || {
  echo "FATAL: Failed to generate GitHub App token" >&2
  exit 1
}
if [[ -z "$GH_TOKEN" ]]; then
  echo "FATAL: GitHub App token is empty" >&2
  exit 1
fi
export GH_TOKEN
```

The `DISPATCHER_APP_PEM` env var must point to the App's private key PEM file.
If not set, provide the path explicitly.

This ensures all issue comments, label changes, and API calls appear as the configured GitHub App bot instead of a personal user account. The token is valid for 1 hour and scoped to the target repo only.

**DO NOT skip this step.** If `GH_TOKEN` is not set, `gh` will fall back to the user's personal token, which is incorrect.

## Environment Variables

- `REPO`: GitHub repo in `owner/repo` format (e.g., `myorg/myproject`)
- `PROJECT_DIR`: Absolute path to the project root on the local machine
- `MAX_CONCURRENT`: Max parallel tasks (default: `5`)
- `MAX_RETRIES`: Max dev retry attempts before marking issue as `stalled` (default: `3`)
- `PROJECT_ID`: Project identifier for log/PID files (default: `project`)
- `DISPATCHER_APP_ID`: GitHub App ID for the dispatcher bot
- `DISPATCHER_APP_PEM`: Path to the GitHub App private key PEM file

## Local Dispatch Helper Script

**CRITICAL:** All task dispatches (dev-new, dev-resume, review) MUST use the helper script `scripts/dispatch-local.sh` in the project root's `scripts/` directory. The script handles:
- Background process spawning via `nohup`
- Input validation (numeric issue numbers, safe session IDs)
- Config loading from `scripts/autonomous.conf`

**Usage:**
```bash
# PROJECT_DIR is the absolute path to the project root

# For new dev task:
bash "$PROJECT_DIR/scripts/dispatch-local.sh" dev-new ISSUE_NUM

# For review task:
bash "$PROJECT_DIR/scripts/dispatch-local.sh" review ISSUE_NUM

# For resume dev task:
bash "$PROJECT_DIR/scripts/dispatch-local.sh" dev-resume ISSUE_NUM SESSION_ID
```

**DO NOT construct dispatch commands manually.** Always use the dispatch-local.sh script.

**DO NOT commit or push code to the target repository.** The dispatcher's role is strictly:
1. Read issue labels and comments via GitHub API
2. Update labels and post comments via GitHub API
3. Dispatch local processes using the helper script

All code changes happen via the autonomous-dev/review scripts. The dispatcher MUST NOT modify source files or push to any branch (especially main).

## Dispatch Logic

When triggered (cron every 5 minutes), execute the following steps IN ORDER.

**Important:** Maintain a `JUST_DISPATCHED` array to track issue numbers dispatched in the current cycle. This prevents Step 5 from false-positive stale detection on freshly dispatched processes whose PID files haven't been written yet.

```bash
# Initialize at the start of each dispatch cycle
JUST_DISPATCHED=()
```

### Step 1: Check Concurrency

Count issues with labels `in-progress` OR `reviewing`:
```bash
ACTIVE=$(gh issue list --repo "$REPO" --state open --limit 100 \
  --label "autonomous" --json labels \
  -q '[.[] | select(.labels[].name | IN("in-progress","reviewing"))] | length')
```
If ACTIVE >= MAX_CONCURRENT (default 5), STOP. Log "Concurrency limit reached (ACTIVE/MAX_CONCURRENT)" and exit.

### Step 2: Scan for New Tasks

Find issues with `autonomous` label but NO state labels:
```bash
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
```

For each found issue (respecting concurrency limit):

**1. Check Dependencies** — before dispatching, read the issue body and look for a `## Dependencies` section. Parse issue references (`#N`) from that section. For each referenced issue, check if it is closed:
```bash
# Extract dependency issue numbers from the issue body
DEPS=$(gh issue view ISSUE_NUM --repo "$REPO" --json body -q '.body' \
  | sed -n '/^## Dependencies/,/^## /p' \
  | grep -oP '#\K[0-9]+')

# Check if all dependencies are closed
BLOCKED=false
for DEP in $DEPS; do
  STATE=$(gh issue view "$DEP" --repo "$REPO" --json state -q '.state')
  if [ "$STATE" != "CLOSED" ]; then
    BLOCKED=true
    break
  fi
done

if [ "$BLOCKED" = true ]; then
  # Skip this issue — dependency not yet resolved
  continue
fi
```

If any dependency issue is still open, **skip this issue silently** (do not add labels or comment). It will be picked up in the next dispatch cycle after its dependencies are resolved.

**2.** Add `in-progress` label
**3.** Comment: `Dispatching autonomous development...`
**4.** Dispatch via helper script:
```bash
bash "$PROJECT_DIR/scripts/dispatch-local.sh" dev-new ISSUE_NUM
```
**5.** Track dispatched issue: `JUST_DISPATCHED+=(ISSUE_NUM)`
**6.** Re-check concurrency after each dispatch

### Step 3: Scan for Review Tasks

Find issues with `autonomous` + `pending-review` (no `reviewing`):
```bash
gh issue list --repo "$REPO" --state open --limit 100 \
  --label "autonomous,pending-review" --json number,labels \
  -q '[.[] | select([.labels[].name] | contains(["reviewing"]) | not)]'
```

For each found issue (respecting concurrency limit):
**1.** Remove `pending-review`, add `reviewing`
**2.** Comment: `Dispatching autonomous review...`
**3.** Dispatch via helper script:
```bash
bash "$PROJECT_DIR/scripts/dispatch-local.sh" review ISSUE_NUM
```
**4.** Track dispatched issue: `JUST_DISPATCHED+=(ISSUE_NUM)`

### Step 4: Scan for Pending-Dev (Resume)

Find issues with `autonomous` + `pending-dev`:
```bash
gh issue list --repo "$REPO" --state open --limit 100 \
  --label "autonomous,pending-dev" --json number,labels,comments
```

For each found issue (respecting concurrency limit):

**1. Check retry count** — before dispatching, count BOTH **failed** `Agent Session Report (Dev)` comments (exit code ≠ 0) AND **dispatcher-detected crash** comments. Only count failures that occurred **after the last stalled→unstalled transition** (i.e., after the most recent "Marking as stalled" comment). This ensures that removing the `stalled` label resets the retry counter. Successful dev completions (exit code 0) that were sent back by review do NOT count as retries:
```bash
# Find the timestamp of the last "Marking as stalled" comment (retry counter cutoff).
# If the issue was never stalled, use epoch (1970-01-01T00:00:00Z) to count all comments.
LAST_STALLED_AT=$(gh issue view ISSUE_NUM --repo "$REPO" --json comments \
  -q '[.comments[] | select(.body | test("Marking as stalled"))] | last | .createdAt // "1970-01-01T00:00:00Z"')

# Count failed agent session reports (only after last stalled cutoff)
AGENT_FAILURES=$(gh issue view ISSUE_NUM --repo "$REPO" --json comments \
  -q "[.comments[] | select((.createdAt > \"${LAST_STALLED_AT}\") and (.body | test(\"Agent Session Report \\\\(Dev\\\\)\")) and (.body | test(\"Exit code: 0\") | not))] | length")

# Count dispatcher-detected crashes (only after last stalled cutoff).
# The regex is anchored on explicit Step 5 crash preambles. A dev process that
# exits after producing a PR is forward progress (handed to review as
# "Dev process exited (PR found)") and MUST NOT match this regex — do not add
# a broad `crashed` or `exited` alternative here.
DISPATCHER_CRASHES=$(gh issue view ISSUE_NUM --repo "$REPO" --json comments \
  -q "[.comments[] | select((.createdAt > \"${LAST_STALLED_AT}\") and (.body | test(\"Task appears to have crashed \\\\(no PR found\\\\)|process not found\")))] | length")

RETRY_COUNT=$((AGENT_FAILURES + DISPATCHER_CRASHES))
MAX_RETRIES="${MAX_RETRIES:-3}"

if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
  # Issue has exceeded retry limit — mark as stalled
  gh issue edit ISSUE_NUM --repo "$REPO" \
    --remove-label "pending-dev" \
    --add-label "stalled"
  gh issue comment ISSUE_NUM --repo "$REPO" \
    --body "Issue has exceeded the maximum retry limit ($MAX_RETRIES failed attempts: $AGENT_FAILURES agent failures + $DISPATCHER_CRASHES dispatcher-detected crashes). Marking as stalled. @${REPO_OWNER} please investigate manually."
  continue
fi
```

If combined retry count exceeds `MAX_RETRIES` (default 3), add `stalled` label, remove `pending-dev`, post a comment, and **skip this issue**. When a user removes the `stalled` label to re-dispatch, the retry counter automatically resets because only crashes after the latest "Marking as stalled" comment are counted.

**2.** Extract latest dev session ID from issue comments (search for `Dev Session ID:` — do NOT match `Review Session ID:`):
```bash
SESSION_ID=$(gh issue view ISSUE_NUM --repo "$REPO" --json comments \
  -q '[.comments[].body | capture("Dev Session ID: `(?P<id>[a-zA-Z0-9_-]+)`"; "g") | .id] | last // empty')
```

**3.** Remove `pending-dev`, add `in-progress`
**4.** Comment: `Resuming development (session: SESSION_ID)...`
**5.** Dispatch via helper script:
```bash
bash "$PROJECT_DIR/scripts/dispatch-local.sh" dev-resume ISSUE_NUM SESSION_ID
```
**6.** Track dispatched issue: `JUST_DISPATCHED+=(ISSUE_NUM)`

### Step 5: Stale Detection

Find issues with `in-progress` or `reviewing` that may be stuck.

**Skip freshly dispatched issues:** Before checking any issue, verify it was NOT dispatched in the current cycle. Issues in `JUST_DISPATCHED` must be skipped — their PID files may not exist yet.

```bash
# Skip issues dispatched in this cycle
if [[ " ${JUST_DISPATCHED[*]} " == *" ISSUE_NUM "* ]]; then
  # Skip — just dispatched this cycle, PID file may not exist yet
  continue
fi
```

For each remaining issue, check if the agent process is still alive locally. Use the correct PID file prefix based on the issue's current label:

- `in-progress` issues use PID file: `/tmp/agent-${PROJECT_ID}-issue-ISSUE_NUM.pid`
- `reviewing` issues use PID file: `/tmp/agent-${PROJECT_ID}-review-ISSUE_NUM.pid`

```bash
# For in-progress issues:
PID=$(cat /tmp/agent-${PROJECT_ID}-issue-ISSUE_NUM.pid 2>/dev/null)
kill -0 "$PID" 2>/dev/null && echo ALIVE || echo DEAD

# For reviewing issues:
kill -0 $(cat /tmp/agent-${PROJECT_ID}-review-ISSUE_NUM.pid 2>/dev/null) 2>/dev/null && echo ALIVE || echo DEAD
```

#### Step 5a (NEW): ALIVE + PR ready for review (issue #54)

If ALIVE and issue still has `in-progress`, the agent process is running but its real work may already be done — PR opened, CI green, and no recent activity for several minutes. In that case the wrapper is hung (polling loop, stuck IO) and is blocking the issue from progressing. Send `SIGTERM` and transition to `pending-review`:

```bash
PR_INFO=$(gh pr list --repo "$REPO" --state open --json number,body,updatedAt \
  -q "[.[] | select(.body | test(\"#ISSUE_NUM[^0-9]\") or test(\"#ISSUE_NUM$\"))] | .[0] // empty")

if [ -n "$PR_INFO" ]; then
  PR_NUM=$(jq -r '.number // empty' <<<"$PR_INFO")
  PR_UPDATED_AT=$(jq -r '.updatedAt // empty' <<<"$PR_INFO")

  # Validate jq outputs — schema drift or partial JSON would otherwise let
  # `null` propagate into `gh pr checks "null"` (silent 404 loop).
  if ! [[ "$PR_NUM" =~ ^[0-9]+$ ]] || [ -z "$PR_UPDATED_AT" ]; then
    echo "WARN: malformed PR info for issue ISSUE_NUM (PR_NUM='$PR_NUM', PR_UPDATED_AT='$PR_UPDATED_AT'); leaving as-is" >&2
  else
    # CI green = at least one check, all SUCCESS. Empty / pending / failed / skipped → not green.
    # Capture stderr so a transport error (token expiry, rate limit) is diagnosable
    # rather than silently equivalent to "no checks".
    # Use mktemp (not a fixed /tmp path) — concurrent dispatcher instances would
    # otherwise collide on the same file (CWE-377: insecure temporary file).
    CI_STATES_ERR=""
    CI_ERR_FILE=$(mktemp)
    CI_STATES=$(gh pr checks "$PR_NUM" --repo "$REPO" --json state -q '[.[].state]' 2>"$CI_ERR_FILE") \
      || { CI_STATES_ERR=$(cat "$CI_ERR_FILE"); CI_STATES='[]'; }
    rm -f "$CI_ERR_FILE"
    if [ -n "$CI_STATES_ERR" ]; then
      echo "WARN: gh pr checks failed for PR #${PR_NUM}: ${CI_STATES_ERR}" >&2
    fi
    CI_GREEN=$(jq -e 'length > 0 and all(. == "SUCCESS")' <<<"$CI_STATES" >/dev/null 2>&1 && echo 1 || echo 0)

    if [ "$CI_GREEN" = "1" ]; then
      # Idle = seconds since the PR was last updated.
      # `date -d` is GNU-only; macOS/BSD uses `date -j -f`. Fall back across
      # the two so the dispatcher works on both. On parse failure, fail-CLOSED:
      # leave the PR alone instead of treating it as 1.7e9-seconds idle (which
      # would unconditionally fire SIGTERM).
      PR_UPDATED_EPOCH=$(date -u -d "$PR_UPDATED_AT" +%s 2>/dev/null \
        || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$PR_UPDATED_AT" +%s 2>/dev/null \
        || echo "")
      if [ -z "$PR_UPDATED_EPOCH" ]; then
        echo "WARN: cannot parse PR.updatedAt='${PR_UPDATED_AT}' for issue ISSUE_NUM; leaving as-is" >&2
      else
        NOW_EPOCH=$(date -u +%s)
        IDLE_SECONDS=$(( NOW_EPOCH - PR_UPDATED_EPOCH ))

        if [ "$IDLE_SECONDS" -gt 300 ]; then
          # Re-verify the PID is still alive AND still ours. Between the
          # earlier kill -0 check and this point, the wrapper could have
          # exited and the PID could have been reassigned to an unrelated
          # process. If recheck fails, treat as DEAD and fall through to
          # the existing DEAD-with-PR path on the next cron tick.
          if ! kill -0 "$PID" 2>/dev/null; then
            echo "INFO: wrapper PID ${PID} for issue ISSUE_NUM exited between checks; deferring to next cycle" >&2
          else
            # Agent hasn't touched the PR in 5+ minutes and CI is green.
            # SIGTERM the wrapper so its PID file clears, then hand off to review.
            if kill "$PID" 2>/dev/null; then
              KILL_NOTE="Sent SIGTERM to PID ${PID}"
            else
              KILL_NOTE="PID ${PID} already gone"
            fi
            gh issue comment ISSUE_NUM --repo "$REPO" \
              --body "Dev process still alive but PR #${PR_NUM} is ready (all CI checks passed, idle ${IDLE_SECONDS}s). ${KILL_NOTE}. Moving to pending-review."
            gh issue edit ISSUE_NUM --repo "$REPO" \
              --remove-label "in-progress" --add-label "pending-review"
            continue   # done with this issue this cycle
          fi
        fi
        # Else: PR moved within the last 5 min — agent may still be doing cleanup
        #       (closing worktree, posting status, etc). Leave alone for now.
      fi
    fi
    # Else: CI not green (pending or failing) — leave alone, agent is presumably
    #       still working on it.
  fi
fi
# Else: no PR yet — agent is still developing, leave alone.

# Fall through to the existing ALIVE-skip below (no transition).
```

> **Concurrent-shutdown race:** between `kill "$PID"` and `gh issue edit ... pending-review`, the wrapper's own SIGTERM trap may also call `gh issue edit` (its `cleanup()` trap posts a session report and may set labels). Outcomes are bounded — the wrapper trap targets `pending-review` (PR exists, exit 0 path) or `pending-dev` (failure path); in the worst case the labels flip back and forth for one cron tick, but the next cycle stabilizes (Step 3 picks up `pending-review`, Step 4 picks up `pending-dev`). No data loss, just one extra comment per ~1% of transitions.

**Why a 5-minute idle gate (idle > 300s):** without it, the dispatcher might SIGTERM an agent that just pushed its passing CI build and is about to do its own cleanup. 5 min matches the dispatcher cron interval — the next cycle will be the one to act, not the cycle that detected green CI.

**Why SIGTERM, not SIGKILL:** agent shells trap SIGTERM and clean up (close worktree handles, flush logs). Plain `kill` defaults to SIGTERM. We do NOT escalate to SIGKILL here — a SIGTERM-resistant agent is rare and best handled by an operator.

**Guard rails:** the new branch fires only when ALL of these hold — alive PID, **PR exists for the issue** (no PR yet → leave alone), **CI green** (CI not green → leave alone), **idle > 300s** (recent activity → leave alone). Each guard is enforced by the conditional structure above.

#### Step 5b: DEAD branch (existing)

If DEAD and issue still has `in-progress`, **check whether a PR exists before deciding the transition**, and if it does, **compare the PR HEAD SHA against the last reviewed SHA** so a redundant review is skipped when no new commits were pushed:
```bash
# Fetch current PR (number + HEAD SHA + body) in a single call.
PR_INFO=$(gh pr list --repo "$REPO" --state open --json number,body,headRefOid \
  -q "[.[] | select(.body | test(\"#ISSUE_NUM[^0-9]\") or test(\"#ISSUE_NUM$\"))] | .[0] // empty")

if [ -n "$PR_INFO" ]; then
  CURRENT_HEAD=$(jq -r '.headRefOid // empty' <<<"$PR_INFO")

  # Find the most recent "Reviewed HEAD: `<sha>`" trailer the review wrapper
  # posted after the previous verdict comment. Empty means review never ran
  # successfully against the current PR (or trailer post failed).
  LAST_REVIEWED_HEAD=$(gh issue view ISSUE_NUM --repo "$REPO" --json comments \
    -q '[.comments[].body | capture("Reviewed HEAD: `(?<sha>[0-9a-f]{7,40})`"; "g") | .sha] | last // empty')

  if [ -n "$LAST_REVIEWED_HEAD" ] && [ -n "$CURRENT_HEAD" ] && [ "$CURRENT_HEAD" = "$LAST_REVIEWED_HEAD" ]; then
    # No new commits since last review. Re-running review would re-emit the
    # same findings against identical code. Retry dev so it can act on the
    # existing review feedback instead.
    # (Wording avoids "crashed" / "process not found" so the Step 4 retry
    #  counter regex does not match it.)
    # Comment: "Dev process exited (no new commits since last review at `<sha>`). Moving to pending-dev for retry."
    # Remove `in-progress`, add `pending-dev`
  else
    # PR has new commits OR no prior review trailer was found — let the
    # review agent assess the work.
    # Comment: "Dev process exited (PR found). Moving to pending-review for assessment."
    # Remove `in-progress`, add `pending-review`
    # (Wording avoids "crashed" so the Step 4 retry-counter regex does not match it.)
  fi
else
  # No PR — dev agent didn't finish, retry development.
  # Comment: "Task appears to have crashed (no PR found). Moving to pending-dev for retry."
  # Remove `in-progress`, add `pending-dev`
fi
```

> **Note on the empty-trailer fallthrough:** an empty `LAST_REVIEWED_HEAD` (no prior review trailer found) routes to `pending-review`, not `pending-dev`. Two distinct causes can produce an empty value, both routed identically but with different operational meaning:
>
> 1. **Review never ran successfully against this PR yet** — the safe first-review case. `pending-review` correctly hands the PR to the review agent.
> 2. **Trailer post failed** (token expiry, 403, rate limit) — the wrapper logs `WARNING: Failed to post Reviewed HEAD trailer` to its review log. Operationally this means SHA-match detection is broken; if you observe `pending-review` cycling without new commits across multiple dispatch ticks, grep the review log at `/tmp/agent-${PROJECT_ID}-review-*.log` for that warning.
>
> The trailer marker is wrapper-managed: only `autonomous-review.sh` should write `Reviewed HEAD: \`<sha>\``. A maintainer comment containing the literal phrase would be picked up too — acceptable trade-off given the 40-char hex match is unlikely in casual prose.

If DEAD and issue still has `reviewing`:
1. Comment: `Review process appears to have crashed. Moving to pending-dev for retry.`
2. Remove `reviewing`, add `pending-dev`

## Cron Configuration (OpenClaw)

```bash
openclaw cron add \
  --name "Autonomous Dispatcher" \
  --cron "*/5 * * * *" \
  --session isolated \
  --message "Run the autonomous-dispatcher skill. Check GitHub issues and dispatch tasks." \
  --announce
```

## Label Definitions

| Label | Color | Description |
|-------|-------|-------------|
| `autonomous` | `#0E8A16` | Issue should be processed by autonomous pipeline |
| `in-progress` | `#FBCA04` | Agent is actively developing |
| `pending-review` | `#1D76DB` | Development complete, awaiting review |
| `reviewing` | `#5319E7` | Agent is actively reviewing |
| `pending-dev` | `#E99695` | Review failed, needs more development |
| `approved` | `#0E8A16` | Review passed. PR merged (or awaiting manual merge if `no-auto-close` present) |
| `no-auto-close` | `#d4c5f9` | Used with `autonomous` — skip auto-merge after review passes, requires manual approval |
| `stalled` | `#B60205` | Issue exceeded max retry attempts; requires manual investigation |

## Model Strategy

| Task | Model | Rationale |
|------|-------|-----------|
| Development (`autonomous-dev.sh`) | Opus (default) | Complex coding, architecture decisions |
| Review (`autonomous-review.sh`) | Sonnet (`--model sonnet`) | Checklist verification, avoids Opus quota contention |
