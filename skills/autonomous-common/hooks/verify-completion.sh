#!/bin/bash
# Stop hook - BLOCKS task completion until:
# 1. CI passes
# 2. E2E tests are run
# 3. All PR review comments are resolved
# Uses state-manager to track E2E test completion
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_MANAGER="$SCRIPT_DIR/state-manager.sh"

# Consume stdin (required by hook interface)
cat > /dev/null

# Get current branch
current_branch=$(git branch --show-current 2>/dev/null || echo "")
if [[ -z "$current_branch" ]]; then
  exit 0
fi

# Skip verification on main branch (no PR workflow)
if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
  exit 0
fi

# Check if jq is available (required for parsing)
if ! command -v jq &> /dev/null; then
  exit 0
fi

# Check if gh CLI is available
if ! command -v gh &> /dev/null; then
  exit 0
fi

# Get PR number for current branch
pr_number=$(gh pr view --json number -q '.number' 2>/dev/null || echo "")

# Get CI status for current branch
ci_status=$(gh run list --branch "$current_branch" --limit 1 --json status,conclusion 2>/dev/null || echo "[]")
status=$(echo "$ci_status" | jq -r '.[0].status // "unknown"')
conclusion=$(echo "$ci_status" | jq -r '.[0].conclusion // "unknown"')

# Helper function to output BLOCKING hook response
# Stop hooks: block message goes to stderr, exit code 2
output_block_response() {
  local message="$1"
  echo "$message" >&2
  exit 2
}

# Function to check unresolved review threads
check_unresolved_reviews() {
  if [[ -z "$pr_number" ]]; then
    echo "0"
    return
  fi

  # Get repository info
  local repo_info
  repo_info=$(gh repo view --json owner,name -q '"\(.owner.login)/\(.name)"' 2>/dev/null || echo "")
  if [[ -z "$repo_info" ]]; then
    echo "0"
    return
  fi

  local owner="${repo_info%%/*}"
  local repo="${repo_info##*/}"

  # Query unresolved review threads using GraphQL
  local query='query($owner: String!, $repo: String!, $pr_number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $pr_number) { reviewThreads(first: 100) { nodes { isResolved isOutdated comments(first: 1) { nodes { author { login } } } } } } } }'

  local result
  result=$(gh api graphql -f query="$query" -f owner="$owner" -f repo="$repo" -F pr_number="$pr_number" 2>/dev/null || echo '{"data":null}')

  if [[ $(echo "$result" | jq -r '.data') == "null" ]]; then
    echo "0"
    return
  fi

  # Count unresolved, non-outdated threads
  echo "$result" | jq '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false and .isOutdated == false)] | length'
}

# Function to get review thread details
get_unresolved_review_details() {
  if [[ -z "$pr_number" ]]; then
    return
  fi

  local repo_info
  repo_info=$(gh repo view --json owner,name -q '"\(.owner.login)/\(.name)"' 2>/dev/null || echo "")
  if [[ -z "$repo_info" ]]; then
    return
  fi

  local owner="${repo_info%%/*}"
  local repo="${repo_info##*/}"

  local query='query($owner: String!, $repo: String!, $pr_number: Int!) { repository(owner: $owner, name: $repo) { pullRequest(number: $pr_number) { reviewThreads(first: 100) { nodes { isResolved isOutdated path comments(first: 1) { nodes { author { login } body } } } } } } }'

  local result
  result=$(gh api graphql -f query="$query" -f owner="$owner" -f repo="$repo" -F pr_number="$pr_number" 2>/dev/null || echo '{"data":null}')

  if [[ $(echo "$result" | jq -r '.data') == "null" ]]; then
    return
  fi

  # Get details of unresolved threads (first 5)
  echo "$result" | jq -r '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false and .isOutdated == false) | "- \(.path // "general"): \(.comments.nodes[0].author.login) - \(.comments.nodes[0].body | split("\n")[0] | .[0:80])..."] | .[0:5] | join("\n")'
}

# Case 1: CI is still running - BLOCK
if [[ "$status" == "in_progress" || "$status" == "queued" ]]; then
  output_block_response "## ⛔ BLOCKED - CI Still Running

GitHub Actions is still running on branch '$current_branch'.

### Required Steps:
1. Wait for CI to complete: \`gh run watch\`
2. Once CI passes, run E2E tests
3. Mark E2E complete and retry

**Cannot complete task while CI is running.**"
fi

# Case 2: CI failed - BLOCK
if [[ "$status" == "completed" && "$conclusion" == "failure" ]]; then
  output_block_response "## ⛔ BLOCKED - CI Failed

The latest GitHub Actions run on branch '$current_branch' failed.

### Required Steps:
1. Check failure logs: \`gh run view --log-failed\`
2. Fix the issues
3. Push and wait for CI to pass

**Cannot complete task with failing CI.**"
fi

# Case 3: CI passed - check E2E and review comments
if [[ "$status" == "completed" && "$conclusion" == "success" ]]; then
  # Check for unresolved review comments
  unresolved_count=$(check_unresolved_reviews)

  if [[ "$unresolved_count" -gt 0 ]]; then
    review_details=$(get_unresolved_review_details)
    output_block_response "## ⛔ BLOCKED - Unresolved Review Comments

There are $unresolved_count unresolved review thread(s) on PR #$pr_number.

### Unresolved Comments:
$review_details

### Required Steps:
1. Review each comment and address the feedback
2. Resolve conversations: \`gh pr view $pr_number --web\`
3. Retry task completion

**Cannot complete task with unresolved review comments.**"
  fi

  # Check E2E: local state OR CI e2e job passed OR no e2e job exists
  e2e_done=false
  e2e_job_exists=false

  # Check local state first (set by state-manager.sh mark e2e-tests)
  if "$STATE_MANAGER" check e2e-tests 2>/dev/null; then
    e2e_done=true
  fi

  # Check CI for E2E job status
  if [[ -n "$pr_number" ]] && ! $e2e_done; then
    e2e_ci=$(gh pr checks "$pr_number" --json name,state 2>/dev/null || echo "[]")
    if echo "$e2e_ci" | jq -e '[.[] | select(.name | test("e2e|E2E"; "i"))] | length > 0' &>/dev/null; then
      e2e_job_exists=true
      if echo "$e2e_ci" | jq -e '[.[] | select(.name | test("e2e|E2E"; "i")) | select(.state == "SUCCESS")] | length > 0' &>/dev/null; then
        e2e_done=true
      fi
    fi
  fi

  if $e2e_done || ! $e2e_job_exists; then
    # All checks passed, or no E2E job in CI (skip requirement).
    # Exit silently — no stdout output to avoid Stop hook re-trigger loop.
    exit 0
  else
    # E2E job exists in CI but hasn't passed
    output_block_response "## ⛔ BLOCKED - E2E Tests Required

CI passed on branch '$current_branch', but E2E tests have not passed.

### Required Steps:
1. Check E2E test status: \`gh pr checks $pr_number\`
2. If E2E failed, check logs and fix
3. Or mark E2E as complete manually: \`hooks/state-manager.sh mark e2e-tests\`

**Cannot complete task without E2E verification.**"
  fi
fi

# Case 4: No CI runs found — exit silently (no stdout to avoid hook loop)
exit 0
