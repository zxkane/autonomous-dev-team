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

When triggered (cron every 5 minutes), execute the following steps IN ORDER:

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
**5.** Re-check concurrency after each dispatch

### Step 3: Scan for Review Tasks

Find issues with `autonomous` + `pending-review` (no `reviewing`):
```bash
gh issue list --repo "$REPO" --state open --limit 100 \
  --label "autonomous,pending-review" --json number,labels \
  -q '[.[] | select([.labels[].name] | contains(["reviewing"]) | not)]'
```

For each found issue (respecting concurrency limit):
1. Remove `pending-review`, add `reviewing`
2. Comment: `Dispatching autonomous review...`
3. Dispatch via helper script:
```bash
bash "$PROJECT_DIR/scripts/dispatch-local.sh" review ISSUE_NUM
```

### Step 4: Scan for Pending-Dev (Resume)

Find issues with `autonomous` + `pending-dev`:
```bash
gh issue list --repo "$REPO" --state open --limit 100 \
  --label "autonomous,pending-dev" --json number,labels,comments
```

For each found issue (respecting concurrency limit):

**1. Check retry count** — before dispatching, count the number of **failed** `Agent Session Report (Dev)` comments (exit code ≠ 0) on the issue. Successful dev completions (exit code 0) that were sent back by review do NOT count as retries:
```bash
RETRY_COUNT=$(gh issue view ISSUE_NUM --repo "$REPO" --json comments \
  -q '[.comments[] | select((.body | test("Agent Session Report \\(Dev\\)")) and (.body | test("Exit code: 0") | not))] | length')

MAX_RETRIES="${MAX_RETRIES:-3}"

if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
  # Issue has exceeded retry limit — mark as stalled
  gh issue edit ISSUE_NUM --repo "$REPO" \
    --remove-label "pending-dev" \
    --add-label "stalled"
  gh issue comment ISSUE_NUM --repo "$REPO" \
    --body "Issue has exceeded the maximum retry limit ($MAX_RETRIES failed attempts). Marking as stalled. @${REPO_OWNER} please investigate manually."
  continue
fi
```

If failed retry count exceeds `MAX_RETRIES` (default 3), add `stalled` label, remove `pending-dev`, post a comment, and **skip this issue**.

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

### Step 5: Stale Detection

Find issues with `in-progress` or `reviewing` that may be stuck.

For each such issue, check if the agent process is still alive locally. Use the correct PID file prefix based on the issue's current label:

- `in-progress` issues use PID file: `/tmp/agent-${PROJECT_ID}-issue-ISSUE_NUM.pid`
- `reviewing` issues use PID file: `/tmp/agent-${PROJECT_ID}-review-ISSUE_NUM.pid`

```bash
# For in-progress issues:
kill -0 $(cat /tmp/agent-${PROJECT_ID}-issue-ISSUE_NUM.pid 2>/dev/null) 2>/dev/null && echo ALIVE || echo DEAD

# For reviewing issues:
kill -0 $(cat /tmp/agent-${PROJECT_ID}-review-ISSUE_NUM.pid 2>/dev/null) 2>/dev/null && echo ALIVE || echo DEAD
```

If DEAD and issue still has `in-progress`:
1. Comment: `Task appears to have crashed. Moving to pending-review for assessment.`
2. Remove `in-progress`, add `pending-review`

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
