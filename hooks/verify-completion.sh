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
  cat <<EOF
{
  "systemMessage": "## ⚠️ Warning - GitHub CLI Not Available\\n\\nThe \`gh\` CLI is not installed. Cannot verify CI status automatically.\\n\\nPlease verify manually:\\n1. Check GitHub Actions status in browser\\n2. Ensure all CI checks pass\\n3. Run E2E tests on preview environment\\n\\n**Task completion allowed - but verify manually.**"
}
EOF
  exit 0
fi

# Get PR number for current branch
pr_number=$(gh pr view --json number -q '.number' 2>/dev/null || echo "")

# Get CI status for current branch
ci_status=$(gh run list --branch "$current_branch" --limit 1 --json status,conclusion 2>/dev/null || echo "[]")
status=$(echo "$ci_status" | jq -r '.[0].status // "unknown"')
conclusion=$(echo "$ci_status" | jq -r '.[0].conclusion // "unknown"')

# Helper function to output BLOCKING hook response
# Exit code 2 blocks the action
output_block_response() {
  local message="$1"
  cat <<EOF
{
  "systemMessage": "$message"
}
EOF
  exit 2
}

# Helper function to output warning (non-blocking)
output_warn_response() {
  local message="$1"
  cat <<EOF
{
  "systemMessage": "$message"
}
EOF
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
  echo "$result" | jq -r '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false and .isOutdated == false) | "- \(.path // "general"): \(.comments.nodes[0].author.login) - \(.comments.nodes[0].body | split("\n")[0] | .[0:80])..."] | .[0:5] | join("\\n")'
}

# Case 1: CI is still running - BLOCK
if [[ "$status" == "in_progress" || "$status" == "queued" ]]; then
  output_block_response "## ⛔ BLOCKED - CI Still Running\\n\\nGitHub Actions is still running on branch '$current_branch'.\\n\\n### Required Steps:\\n1. Wait for CI to complete:\\n   \`\`\`bash\\n   gh run watch\\n   \`\`\`\\n2. Once CI passes, run E2E tests\\n3. Mark E2E complete and retry\\n\\n**Cannot complete task while CI is running.**"
fi

# Case 2: CI failed - BLOCK
if [[ "$status" == "completed" && "$conclusion" == "failure" ]]; then
  output_block_response "## ⛔ BLOCKED - CI Failed\\n\\nThe latest GitHub Actions run on branch '$current_branch' failed.\\n\\n### Required Steps:\\n1. Check failure logs:\\n   \`\`\`bash\\n   gh run view --log-failed\\n   \`\`\`\\n2. Fix the issues\\n3. Run code-simplifier and commit\\n4. Run pr-review and push\\n5. Wait for CI to pass\\n6. Run E2E tests\\n\\n**Cannot complete task with failing CI.**"
fi

# Case 3: CI passed - check E2E and review comments
if [[ "$status" == "completed" && "$conclusion" == "success" ]]; then
  # Check for unresolved review comments
  unresolved_count=$(check_unresolved_reviews)

  if [[ "$unresolved_count" -gt 0 ]]; then
    review_details=$(get_unresolved_review_details)
    output_block_response "## ⛔ BLOCKED - Unresolved Review Comments\\n\\nThere are $unresolved_count unresolved review thread(s) on PR #$pr_number.\\n\\n### Unresolved Comments:\\n$review_details\\n\\n### Required Steps:\\n1. Review each comment and address the feedback\\n2. Resolve the conversations on GitHub:\\n   \`\`\`bash\\n   gh pr view $pr_number --web\\n   \`\`\`\\n3. Or mark threads as resolved if addressed\\n4. Retry task completion\\n\\n**Cannot complete task with unresolved review comments.**"
  fi

  # Check if e2e-tests state exists
  if "$STATE_MANAGER" check e2e-tests 2>/dev/null; then
    # All checks passed
    output_warn_response "## ✅ Verification Complete\\n\\n- CI passed ✓\\n- E2E tests verified ✓\\n- All review comments resolved ✓\\n\\nBranch: '$current_branch'\\n\\n**Task completion allowed. Ready for peer review.**"
    exit 0
  else
    # E2E tests not run yet - BLOCK
    output_block_response "## ⛔ BLOCKED - E2E Tests Required\\n\\nCI passed on branch '$current_branch', but E2E tests have not been run.\\n\\n### Required Steps (Step 8):\\n1. Get the PR preview URL:\\n   \`\`\`bash\\n   gh pr view --json url\\n   \`\`\`\\n\\n2. Run E2E tests using Chrome DevTools MCP:\\n   - Navigate to the preview URL\\n   - Test authentication flows (if applicable)\\n   - Test the specific functionality changed\\n   - Verify no console errors\\n   - Capture screenshots if needed\\n\\n3. After E2E verification, mark as complete:\\n   \`\`\`bash\\n   .claude/hooks/state-manager.sh mark e2e-tests\\n   \`\`\`\\n\\n4. Retry task completion\\n\\n**Cannot complete task without E2E verification.**"
  fi
fi

# Case 4: No CI runs found (possibly no push yet) - warn only
if [[ "$status" == "unknown" ]]; then
  output_warn_response "## ⚠️ Warning - No CI Runs Found\\n\\nNo GitHub Actions runs found for branch '$current_branch'.\\n\\nIf you haven't pushed yet, please:\\n1. Run code-simplifier and commit\\n2. Run pr-review and push\\n3. Wait for CI to pass\\n4. Run E2E tests\\n\\nIf this is expected (e.g., research task), you may proceed."
fi

exit 0
