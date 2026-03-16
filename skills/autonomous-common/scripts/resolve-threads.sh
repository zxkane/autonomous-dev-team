#!/bin/bash
# Resolve all unresolved review threads on a GitHub PR
#
# Usage: ./resolve-threads.sh <owner> <repo> <pr_number>
#
# Example:
#   ./resolve-threads.sh zxkane openhands-infra 5

set -e

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <owner> <repo> <pr_number>"
    echo ""
    echo "Arguments:"
    echo "  owner       - Repository owner (e.g., zxkane)"
    echo "  repo        - Repository name (e.g., openhands-infra)"
    echo "  pr_number   - Pull request number (e.g., 5)"
    echo ""
    echo "Example:"
    echo "  $0 zxkane openhands-infra 5"
    exit 1
fi

# Sanitize inputs to prevent command injection
OWNER=$(printf '%s' "$1" | sed 's/[^a-zA-Z0-9._-]//g')
REPO=$(printf '%s' "$2" | sed 's/[^a-zA-Z0-9._-]//g')
PR_NUMBER=$(printf '%d' "$3" 2>/dev/null || echo '0')

# Validate inputs
if [ -z "$OWNER" ] || [ -z "$REPO" ] || [ "$PR_NUMBER" -eq 0 ]; then
    echo "Error: Invalid arguments provided"
    exit 1
fi

echo "Fetching unresolved review threads for PR #$PR_NUMBER..."

# Get unresolved thread IDs using parameterized GraphQL variables
THREAD_IDS=$(gh api graphql \
  -F owner="$OWNER" \
  -F repo="$REPO" \
  -F prNumber="$PR_NUMBER" \
  -f query='
query($owner: String!, $repo: String!, $prNumber: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $prNumber) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
        }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | .id')

if [ -z "$THREAD_IDS" ]; then
    echo "No unresolved threads found!"
    exit 0
fi

# Count threads
THREAD_COUNT=$(echo "$THREAD_IDS" | wc -l | tr -d ' ')
echo "Found $THREAD_COUNT unresolved thread(s)"

# Resolve each thread and track results
RESOLVED=0
FAILED=0

# Use here-string to avoid subshell (pipe creates subshell where variable updates are lost)
while read thread_id; do
    if [ -n "$thread_id" ]; then
        echo -n "Resolving thread $thread_id... "
        result=$(gh api graphql \
          -F threadId="$thread_id" \
          -f query='
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread { isResolved }
  }
}' --jq '.data.resolveReviewThread.thread.isResolved' 2>/dev/null)

        if [ "$result" = "true" ]; then
            echo "OK"
            RESOLVED=$((RESOLVED + 1))
        else
            echo "FAILED"
            FAILED=$((FAILED + 1))
        fi
    fi
done <<< "$THREAD_IDS"

echo ""
echo "Summary: $RESOLVED resolved, $FAILED failed"
