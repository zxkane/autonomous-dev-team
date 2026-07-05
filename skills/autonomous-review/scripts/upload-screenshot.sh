#!/bin/bash
# upload-screenshot.sh — Upload a screenshot to the code-host for linking in PR comments.
#
# Pushes the image to an orphan `screenshots` branch in the repo, then outputs
# a blob URL that authenticated users can view in the web UI. For private
# repos, raw content URLs return 404 without auth, but /blob/ (github) or
# /-/blob/ (gitlab) URLs render images natively for any user with repo access.
#
# The whole write op + URL render route through the provider-neutral CHP
# verbs `chp_commit_file` and `chp_file_url` (#419 P1-1 P3-4). CODE_HOST
# selects the leaf:
#   - github (default): the 8-call git-Data-API dance + github.com/…/blob/…
#   - gitlab:            the Files API + ${GITLAB_HOST}/…/-/blob/…
#
# Usage:
#   scripts/upload-screenshot.sh <png-path> <pr-number> <test-case-id>
#
# Environment (per lane):
#   github lane:
#     GH_TOKEN  — GitHub token with repo write access (required)
#     REPO      — owner/repo (default: owner/repo, override via autonomous.conf)
#   gitlab lane (CODE_HOST=gitlab):
#     GITLAB_TOKEN  — GitLab PAT/deploy-token with repo write access
#                     (required unless GITLAB_TRANSPORT_HOOK is armed)
#     GITLAB_TRANSPORT_HOOK — operator-owned transport hook path (alternative
#                             to GITLAB_TOKEN; owns its own auth)
#     GITLAB_PROJECT — url-encoded project path (e.g. group%2Fproject),
#                      override via autonomous.conf
#     REPO      — repo positional threaded into chp_commit_file / chp_file_url
#
# Output (stdout):
#   On success: <blob URL — github or gitlab shape per CODE_HOST>
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

# [#419 P1-1] Environment preflight runs FIRST (before the file/PR/TC-ID
# checks) so mis-configured lanes fail loud without leaking a file-not-found
# error on top of a missing-token error. Per-lane branching:
#   - github lane (CODE_HOST=github, the default): require GH_TOKEN + gh (the
#     `command -v gh` staying is allowlisted in the cutover guard — the point
#     is the EARLY EXIT must not fire on a gitlab lane).
#   - gitlab lane (CODE_HOST=gitlab): require GITLAB_TOKEN OR
#     GITLAB_TRANSPORT_HOOK (the operator-owned hook path). `gh` is NOT
#     required — the GitLab leaves route through _gl_api → curl.
#   - any other value: fatal (mistyped CODE_HOST is safer to reject loud than
#     to silently take the github preflight path).
# jq is required on BOTH lanes (transport uses it for @uri encoding + shape gates).
command -v jq >/dev/null 2>&1 || fail "jq is required but not found in PATH"
case "${CODE_HOST:-github}" in
  github)
    [[ -n "${GH_TOKEN:-}" ]] || fail "GH_TOKEN environment variable is required on the github lane"
    command -v gh >/dev/null 2>&1 || fail "gh CLI is required on the github lane but not found in PATH"
    ;;
  gitlab)
    if [[ -z "${GITLAB_TOKEN:-}" && -z "${GITLAB_TRANSPORT_HOOK:-}" ]]; then
      fail "GITLAB_TOKEN or GITLAB_TRANSPORT_HOOK is required on the gitlab lane (see docs/gitlab-setup.md)"
    fi
    ;;
  *)
    fail "unsupported CODE_HOST='${CODE_HOST}' (expected 'github' or 'gitlab')"
    ;;
esac

[[ -f "$PNG_PATH" ]] || fail "File not found: $PNG_PATH"
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] || fail "PR number must be a positive integer, got '$PR_NUMBER'"
[[ "$TC_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || fail "Test case ID must be alphanumeric with hyphens/underscores, got '$TC_ID'"

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
  || fail "code-host commit-file upload failed for ${FILE_PATH}"
[[ -n "$UPLOAD_SHA" ]] || fail "code-host commit-file upload failed for ${FILE_PATH}"

# Output a browser blob URL via the CHP `chp_file_url` verb (#419 R11). The
# GitHub leaf renders `https://github.com/${REPO}/blob/${BRANCH}/${FILE_PATH}`
# byte-identically to the pre-#419 hardcode; the GitLab leaf renders the
# GitLab-native `/-/blob/` shape with the RAW (percent-decoded) project path.
# Web UIs render PNGs natively for authenticated users; viewers must have repo
# access for private repos. Explicit REPO/BRANCH/FILE_PATH positionals — the
# leaf honors REPO (not a global). Self-guarding shim: a leaf-absent backend
# emits WARN + rc 1 which `|| fail` degrades cleanly.
chp_file_url "$REPO" "$BRANCH" "$FILE_PATH" || fail "chp_file_url unavailable — file uploaded (SHA=${UPLOAD_SHA}) but URL render failed"
exit 0
