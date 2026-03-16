#!/bin/bash
# upload-screenshot.sh — Upload a screenshot to GitHub for linking in PR comments.
#
# Pushes the image to an orphan `screenshots` branch in the repo,
# then outputs a GitHub blob URL that authenticated users can view in the web UI.
# For private repos, raw.githubusercontent.com URLs return 404 without auth,
# but /blob/ URLs render images natively for any user with repo access.
#
# Usage:
#   scripts/upload-screenshot.sh <png-path> <pr-number> <test-case-id>
#
# Environment:
#   GH_TOKEN  — GitHub token with repo write access (required)
#   REPO      — owner/repo (default: owner/repo, override via autonomous.conf)
#
# Output (stdout):
#   On success: https://github.com/{owner}/{repo}/blob/screenshots/pr-{N}/{TC-ID}.png
#   On failure: UPLOAD_FAILED
#
# Exit codes:
#   0 — Upload succeeded
#   1 — Upload failed (UPLOAD_FAILED printed to stdout)

set -euo pipefail

PNG_PATH="${1:-}"
PR_NUMBER="${2:-}"
TC_ID="${3:-}"

_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Load config: check co-located, then dispatcher scripts, then project root scripts/
for _conf_candidate in \
    "${_SCRIPT_DIR}/autonomous.conf" \
    "${_SCRIPT_DIR}/../../autonomous-dispatcher/scripts/autonomous.conf" \
    "$(cd "${_SCRIPT_DIR}/../../.." 2>/dev/null && pwd)/scripts/autonomous.conf"; do
  if [[ -f "$_conf_candidate" ]]; then
    source "$_conf_candidate"
    break
  fi
done
REPO="${REPO:-owner/repo}"
BRANCH="screenshots"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
fail() {
  echo "Error: $1" >&2
  echo "UPLOAD_FAILED"
  exit 1
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [[ -z "$PNG_PATH" || -z "$PR_NUMBER" || -z "$TC_ID" ]]; then
  echo "Usage: $0 <png-path> <pr-number> <test-case-id>" >&2
  echo "UPLOAD_FAILED"
  exit 1
fi

[[ -f "$PNG_PATH" ]] || fail "File not found: $PNG_PATH"
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || fail "PR number must be a positive integer, got '$PR_NUMBER'"
[[ "$TC_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Test case ID must be alphanumeric with hyphens/underscores, got '$TC_ID'"
[[ -n "${GH_TOKEN:-}" ]] || fail "GH_TOKEN environment variable is required"
command -v gh >/dev/null 2>&1 || fail "gh CLI is required but not found in PATH"
command -v jq >/dev/null 2>&1 || fail "jq is required but not found in PATH"

# ---------------------------------------------------------------------------
# Upload via GitHub API (create/update file on orphan branch)
# ---------------------------------------------------------------------------
FILE_PATH="pr-${PR_NUMBER}/${TC_ID}.png"
CONTENT_BASE64=$(base64 -w0 "$PNG_PATH" 2>/dev/null || base64 -i "$PNG_PATH" 2>/dev/null)
[[ -n "$CONTENT_BASE64" ]] || fail "Failed to base64-encode $PNG_PATH"

# Ensure the orphan branch exists
BRANCH_EXISTS=$(gh api "repos/${REPO}/git/ref/heads/${BRANCH}" 2>/dev/null | jq -r '.ref // empty' 2>/dev/null || true)

if [[ -z "$BRANCH_EXISTS" ]]; then
  # Create orphan branch: blob → tree → commit → ref
  README_BLOB=$(gh api "repos/${REPO}/git/blobs" \
    -f content="Screenshots for PR E2E verification reports.\nThis branch is auto-managed — do not edit manually.\n" \
    -f encoding=utf-8 \
    --jq '.sha' 2>/dev/null) || true

  TREE_SHA=""
  [[ -n "$README_BLOB" ]] && TREE_SHA=$(gh api "repos/${REPO}/git/trees" \
    --jq '.sha' \
    -f "tree[][path]=README.md" \
    -f "tree[][mode]=100644" \
    -f "tree[][type]=blob" \
    -f "tree[][sha]=${README_BLOB}" 2>/dev/null) || true

  COMMIT_SHA=""
  [[ -n "$TREE_SHA" ]] && COMMIT_SHA=$(gh api "repos/${REPO}/git/commits" \
    -f message="chore: initialize screenshots branch" \
    -f "tree=${TREE_SHA}" \
    --jq '.sha' 2>/dev/null) || true

  [[ -n "$COMMIT_SHA" ]] && gh api "repos/${REPO}/git/refs" \
    -f "ref=refs/heads/${BRANCH}" \
    -f "sha=${COMMIT_SHA}" >/dev/null 2>&1 || true

  # Verify branch was created
  BRANCH_EXISTS=$(gh api "repos/${REPO}/git/ref/heads/${BRANCH}" 2>/dev/null | jq -r '.ref // empty' 2>/dev/null || true)
  [[ -n "$BRANCH_EXISTS" ]] || fail "Failed to create orphan branch '${BRANCH}'"
fi

# Check if file already exists (need SHA for update)
EXISTING_SHA=$(gh api "repos/${REPO}/contents/${FILE_PATH}?ref=${BRANCH}" 2>/dev/null | jq -r '.sha // empty' 2>/dev/null || true)

# Build JSON payload via temp file to avoid ARG_MAX limit with large base64 content.
# The base64 string for screenshots can exceed 128KB, which breaks shell argument passing.
JSON_TMPFILE=$(mktemp /tmp/screenshot-upload-XXXXXX.json)
UPLOAD_RESPONSE_FILE=$(mktemp /tmp/screenshot-response-XXXXXX.json)
trap 'rm -f "$JSON_TMPFILE" "$UPLOAD_RESPONSE_FILE"' EXIT

{
  printf '{"message":"screenshot: PR #%s %s","content":"' "$PR_NUMBER" "$TC_ID"
  printf '%s' "$CONTENT_BASE64"
  printf '","branch":"%s"' "$BRANCH"
  if [[ -n "$EXISTING_SHA" ]]; then
    printf ',"sha":"%s"' "$EXISTING_SHA"
  fi
  printf '}'
} > "$JSON_TMPFILE"

gh api "repos/${REPO}/contents/${FILE_PATH}" \
  -X PUT \
  --input "$JSON_TMPFILE" \
  > "$UPLOAD_RESPONSE_FILE" 2>/dev/null || true

UPLOAD_SHA=$(jq -r '.content.sha // empty' "$UPLOAD_RESPONSE_FILE" 2>/dev/null || true)
[[ -n "$UPLOAD_SHA" ]] || fail "GitHub API upload failed for ${FILE_PATH}"

# Output a /blob/ URL — GitHub's web UI renders PNGs natively for authenticated users.
# This works for both private and public repos (viewers must have repo access for private).
# raw.githubusercontent.com URLs require auth tokens that expire, so /blob/ is more reliable.
echo "https://github.com/${REPO}/blob/${BRANCH}/${FILE_PATH}"
exit 0
