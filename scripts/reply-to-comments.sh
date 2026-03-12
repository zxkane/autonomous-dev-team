#!/bin/bash
# Reply to a specific review comment on a GitHub PR
#
# Usage: ./reply-to-comments.sh <owner> <repo> <pr_number> <comment_id> "<message>"
#
# Example:
#   ./reply-to-comments.sh zxkane openhands-infra 5 2734892022 "Addressed in commit abc123 - Fixed the security issue"

set -e

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <owner> <repo> <pr_number> <comment_id> <message>"
    echo ""
    echo "Arguments:"
    echo "  owner       - Repository owner (e.g., zxkane)"
    echo "  repo        - Repository name (e.g., openhands-infra)"
    echo "  pr_number   - Pull request number (e.g., 5)"
    echo "  comment_id  - Comment ID to reply to (e.g., 2734892022)"
    echo "  message     - Reply message (quote if contains spaces)"
    echo ""
    echo "Example:"
    echo "  $0 zxkane openhands-infra 5 2734892022 \"Addressed in commit abc123\""
    exit 1
fi

# Sanitize inputs to prevent command injection
OWNER=$(printf '%s' "$1" | sed 's/[^a-zA-Z0-9._-]//g')
REPO=$(printf '%s' "$2" | sed 's/[^a-zA-Z0-9._-]//g')
PR_NUMBER=$(printf '%d' "$3" 2>/dev/null || echo '0')
COMMENT_ID=$(printf '%s' "$4" | sed 's/[^0-9]//g')
MESSAGE="$5"

# Validate inputs
if [ -z "$OWNER" ] || [ -z "$REPO" ] || [ "$PR_NUMBER" -eq 0 ] || [ -z "$COMMENT_ID" ] || [ -z "$MESSAGE" ]; then
    echo "Error: Invalid arguments provided"
    exit 1
fi

echo "Replying to comment $COMMENT_ID on PR #$PR_NUMBER..."

gh api "repos/$OWNER/$REPO/pulls/$PR_NUMBER/comments" \
  -X POST \
  -f body="$MESSAGE" \
  -F in_reply_to="$COMMENT_ID" \
  --jq '{id: .id, url: .html_url}' || {
    echo "Error: Failed to post reply"
    exit 1
  }

echo "Reply posted successfully!"
