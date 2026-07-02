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

# [INV-95] Code-Host Provider dispatch. The whole 8-call git-Data-API commit op
# (commit a PNG onto the orphan `screenshots` branch + echo the SHA) routes
# through the CHP verb chp_commit_file (GitHub leaf chp_github_commit_file). The
# provider lib lives in the autonomous-dispatcher skill tree; resolve it via
# readlink -f of THIS script (the [INV-14]/[INV-65] skill-tree idiom) — NOT
# _SCRIPT_DIR, which is deliberately the project-side symlink dir so the
# conf-lookup above finds the project's autonomous.conf. Guarded on the verb being
# undefined: if the lib is absent the verb stays undefined and the chp_commit_file
# call below FAILS LOUD ([INV-91]: a raw `gh` fallback would silently execute
# GitHub git-Data-API commands for a non-GitHub backend — never silently fall
# through). lib-code-host.sh sources providers/chp-github.sh from its own
# skill-tree readlink -f dir, so the leaf is reachable regardless of project-side
# symlink topology (Step-1 `npx skills update -g` suffices, no installer re-run).
if ! declare -F chp_commit_file >/dev/null 2>&1; then
  _us_real_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd 2>/dev/null)" || _us_real_dir=""
  _us_lib="${_us_real_dir}/../../autonomous-dispatcher/scripts/lib-code-host.sh"
  if [[ -n "$_us_real_dir" && -r "$_us_lib" ]]; then
    # shellcheck source=../../autonomous-dispatcher/scripts/lib-code-host.sh
    source "$_us_lib"
  fi
  unset _us_real_dir _us_lib
fi

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
# Upload via the CHP whole-op verb (commit the PNG on the orphan branch)
# ---------------------------------------------------------------------------
# FILE_PATH / the commit MESSAGE are caller-rendered (provider-neutral params).
# CONTENT_BASE64 is the provider-neutral currency — GitLab's Files API also takes
# encoding=base64. The whole 8-call git-Data-API GitHub op (get-ref → … →
# put-contents, incl. the orphan-branch create-vs-update branching + the ARG_MAX
# temp-file JSON build) lives behind chp_commit_file's GitHub leaf; the
# fail-on-empty-SHA glue stays here. REPO is threaded EXPLICITLY (the leaf takes
# it as $1, not a global — the #324 dropped-repo-arg lesson).
FILE_PATH="pr-${PR_NUMBER}/${TC_ID}.png"
COMMIT_MESSAGE="screenshot: PR #${PR_NUMBER} ${TC_ID}"
CONTENT_BASE64=$(base64 -w0 "$PNG_PATH" 2>/dev/null || base64 -i "$PNG_PATH" 2>/dev/null)
[[ -n "$CONTENT_BASE64" ]] || fail "Failed to base64-encode $PNG_PATH"

UPLOAD_SHA=$(chp_commit_file "$REPO" "$BRANCH" "$FILE_PATH" "$CONTENT_BASE64" "$COMMIT_MESSAGE") \
  || fail "GitHub API upload failed for ${FILE_PATH}"
[[ -n "$UPLOAD_SHA" ]] || fail "GitHub API upload failed for ${FILE_PATH}"

# Output a /blob/ URL — GitHub's web UI renders PNGs natively for authenticated users.
# This works for both private and public repos (viewers must have repo access for private).
# raw.githubusercontent.com URLs require auth tokens that expire, so /blob/ is more reliable.
echo "https://github.com/${REPO}/blob/${BRANCH}/${FILE_PATH}"
exit 0
