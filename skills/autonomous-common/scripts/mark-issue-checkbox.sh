#!/bin/bash
# mark-issue-checkbox.sh — Mark a checkbox in a GitHub issue body as checked.
#
# Uses `gh` which resolves to gh-with-token-refresh.sh wrapper,
# automatically using the active agent's GitHub App token.
#
# Usage:
#   scripts/mark-issue-checkbox.sh <issue-number> <checkbox-text-substring>
#
# Exit codes:
#   0 — Checkbox marked successfully (or already checked)
#   1 — Error (API failure, invalid input)
#   2 — Checkbox text not found in issue body
#
# Example:
#   scripts/mark-issue-checkbox.sh 128 "Add viewport meta tag"
#   # Finds "- [ ] Add viewport meta tag" and marks it "- [x] Add viewport meta tag"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Load config: check co-located, then dispatcher scripts, then project root scripts/
for _conf_candidate in \
    "${SCRIPT_DIR}/autonomous.conf" \
    "${SCRIPT_DIR}/../../autonomous-dispatcher/scripts/autonomous.conf" \
    "$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd)/scripts/autonomous.conf"; do
  if [[ -f "$_conf_candidate" ]]; then
    source "$_conf_candidate"
    break
  fi
done
REPO="${GITHUB_REPO:-${REPO:-owner/repo}}"

ISSUE_NUMBER="${1:-}"
CHECKBOX_TEXT="${2:-}"

if [[ -z "$ISSUE_NUMBER" || -z "$CHECKBOX_TEXT" ]]; then
  echo "Usage: $0 <issue-number> <checkbox-text-substring>" >&2
  exit 1
fi

if ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: issue number must be a positive integer, got '$ISSUE_NUMBER'" >&2
  exit 1
fi

# Validate CHECKBOX_TEXT: reject control characters, newlines, and excessive length
if [[ ${#CHECKBOX_TEXT} -gt 500 ]]; then
  echo "Error: checkbox text too long (${#CHECKBOX_TEXT} chars, max 500)" >&2
  exit 1
fi
if [[ "$CHECKBOX_TEXT" =~ $'\n' ]] || [[ "$CHECKBOX_TEXT" =~ $'\r' ]]; then
  echo "Error: checkbox text must not contain newlines" >&2
  exit 1
fi

mark_checkbox() {
  # Fetch current issue body
  local body
  body=$(gh api "repos/${REPO}/issues/${ISSUE_NUMBER}" --jq '.body') || {
    echo "Error: Failed to fetch issue #${ISSUE_NUMBER}" >&2
    return 1
  }

  # Validate body is non-empty
  if [[ -z "$body" || "$body" == "null" ]]; then
    echo "Error: Issue #${ISSUE_NUMBER} has no body" >&2
    return 1
  fi

  # Check if the checkbox text exists and is unchecked
  if ! printf '%s\n' "$body" | grep -qF -- "- [ ] ${CHECKBOX_TEXT}"; then
    # Check if already checked
    if printf '%s\n' "$body" | grep -qF -- "- [x] ${CHECKBOX_TEXT}"; then
      echo "Already checked: ${CHECKBOX_TEXT}"
      return 0
    fi
    echo "Error: Checkbox not found: '${CHECKBOX_TEXT}'" >&2
    return 2
  fi

  # Replace first occurrence of "- [ ] <text>" with "- [x] <text>"
  # Use ENVIRON to pass strings into awk without backslash interpretation
  local new_body
  new_body=$(printf '%s\n' "$body" | \
    SEARCH="- [ ] ${CHECKBOX_TEXT}" REPLACE="- [x] ${CHECKBOX_TEXT}" awk '
    BEGIN { search = ENVIRON["SEARCH"]; replace = ENVIRON["REPLACE"] }
    !found && index($0, search) {
      pos = index($0, search)
      $0 = substr($0, 1, pos - 1) replace substr($0, pos + length(search))
      found = 1
    }
    { print }
  ')

  # PATCH the issue body
  gh api "repos/${REPO}/issues/${ISSUE_NUMBER}" \
    --method PATCH \
    --field body="$new_body" \
    --silent || {
    echo "Error: Failed to update issue #${ISSUE_NUMBER}" >&2
    return 1
  }

  echo "Checked: ${CHECKBOX_TEXT}"
}

# Try once, retry on failure (handles concurrent edit conflicts).
# Note: must disable set -e around mark_checkbox to capture its exit code.
set +e
mark_checkbox
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -ne 0 ]]; then
  # Don't retry on "not found" (exit 2) — it won't become found after waiting
  if [[ $EXIT_CODE -eq 2 ]]; then
    exit 2
  fi
  echo "Retrying after 2 seconds..." >&2
  sleep 2
  if ! mark_checkbox; then
    echo "Error: Failed to mark checkbox '${CHECKBOX_TEXT}' on issue #${ISSUE_NUMBER} after retry" >&2
    exit 1
  fi
fi
