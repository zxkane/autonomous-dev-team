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
REPO_NAME=$(printf '%s' "$2" | sed 's/[^a-zA-Z0-9._-]//g')
PR_NUMBER=$(printf '%d' "$3" 2>/dev/null || echo '0')
COMMENT_ID=$(printf '%s' "$4" | sed 's/[^0-9]//g')
MESSAGE="$5"

# Validate inputs
if [ -z "$OWNER" ] || [ -z "$REPO_NAME" ] || [ "$PR_NUMBER" -eq 0 ] || [ -z "$COMMENT_ID" ] || [ -z "$MESSAGE" ]; then
    echo "Error: Invalid arguments provided"
    exit 1
fi

# [INV-87]/[INV-96] Code-Host Provider dispatch. The review-reply POST leaf routes
# through the CHP seam (chp_reply_review_comment → chp_${CODE_HOST}_reply_review_comment,
# #327). This util is invoked STANDALONE and sources NO lib otherwise, so it
# self-sources the seam via readlink -f of THIS script (the [INV-14]/[INV-65]
# skill-tree idiom — NOT $0/dirname, the project-side symlink dir, so the seam
# resolves to the REAL skill tree where lib-code-host.sh + providers/chp-github.sh
# live). The provider lib sits in the autonomous-dispatcher skill tree, a sibling
# of this autonomous-common util. The decide-to-source guard checks the SHIM
# (chp_reply_review_comment): if it is already defined the lib was sourced. The
# fail-loud guard before the POST checks the LEAF instead (see below) — if the lib
# is absent (or a backend omits the leaf) the POST FAILs LOUD ([INV-91]: a raw
# `gh` fallback would silently execute GitHub commands for a non-GitHub backend —
# never silently fall through). The exact precedent is the sibling cross-skill
# util mark-issue-checkbox.sh (#315), which self-sources lib-issue-provider.sh.
if ! declare -F chp_reply_review_comment >/dev/null 2>&1; then
  _rtc_real_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd 2>/dev/null)" || _rtc_real_dir=""
  _rtc_lib="${_rtc_real_dir}/../../autonomous-dispatcher/scripts/lib-code-host.sh"
  if [ -n "$_rtc_real_dir" ] && [ -r "$_rtc_lib" ]; then
    # shellcheck source=../../autonomous-dispatcher/scripts/lib-code-host.sh
    source "$_rtc_lib"
  fi
  unset _rtc_real_dir _rtc_lib
fi

echo "Replying to comment $COMMENT_ID on PR #$PR_NUMBER..."

# The CHP leaf uses the global $REPO `owner/repo` slug (like every CHP leaf), so
# compose it here from the owner + repo-name args — preserving the byte-identical
# endpoint path repos/$OWNER/$REPO_NAME/pulls/$PR_NUMBER/comments.
REPO="$OWNER/$REPO_NAME"

# Guard on BOTH the shim AND the LEAF (`chp_${CODE_HOST}_reply_review_comment`),
# bare expression — NOT just the shim. The thin shim is ALWAYS defined once
# lib-code-host.sh is sourced, so a shim-only guard passes even on a backend whose
# provider file omits the leaf; the shim would then dispatch to an undefined
# `chp_${CODE_HOST}_reply_review_comment` and abort under `set -e` with a
# `command not found` instead of failing loud (#282 round 4 [P1], the `chp_has_leaf`
# contract; the INV-94 sibling guards the same way). The bare `${CODE_HOST}` is
# IDENTICAL to what the shim dispatches; the short-circuit `||` reaches it only once
# the 1st guard proved the shim (and thus the seam-sourced `CODE_HOST` default)
# exists. Leaf/shim absent → fail LOUD (no raw-`gh` fallback), never abort.
if ! declare -F chp_reply_review_comment >/dev/null 2>&1 \
   || ! declare -F "chp_${CODE_HOST:-github}_reply_review_comment" >/dev/null 2>&1; then
    echo "Error: chp_reply_review_comment leaf not available (provider lib not loaded or backend omits the leaf; CODE_HOST=${CODE_HOST:-?}). Cannot reply to comment $COMMENT_ID on PR #$PR_NUMBER." >&2
    exit 1
fi

chp_reply_review_comment "$PR_NUMBER" "$COMMENT_ID" "$MESSAGE" || {
    echo "Error: Failed to post reply"
    exit 1
  }

echo "Reply posted successfully!"
