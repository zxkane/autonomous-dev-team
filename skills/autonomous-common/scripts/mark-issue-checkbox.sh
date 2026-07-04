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

# [INV-87] Issue-Tracker Provider dispatch. Two leaves route through the seam:
# the body READ (itp_read_task → itp_${ISSUE_PROVIDER}_read_task, #296) AND the
# body-checkbox PATCH (itp_mark_checkbox → itp_${ISSUE_PROVIDER}_mark_checkbox).
# The provider lib lives in the autonomous-dispatcher skill tree; resolve it via
# readlink -f of THIS script (the [INV-14]/[INV-65] skill-tree idiom) — NOT
# SCRIPT_DIR, which is deliberately the project-side symlink dir so the conf-lookup
# above finds the project's autonomous.conf. Guarded on EITHER verb being undefined
# (so the genuinely-absent-lib case still attempts the source even if a caller
# pre-defined only one of them): if the lib is absent both verbs stay undefined and
# the READ/PATCH below FAIL LOUD ([INV-91]: a raw `gh` fallback would silently
# execute GitHub commands for a non-GitHub backend — never silently fall through).
if ! declare -F itp_read_task >/dev/null 2>&1 || ! declare -F itp_mark_checkbox >/dev/null 2>&1; then
  _mic_real_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd 2>/dev/null)" || _mic_real_dir=""
  _mic_lib="${_mic_real_dir}/../../autonomous-dispatcher/scripts/lib-issue-provider.sh"
  if [[ -n "$_mic_real_dir" && -r "$_mic_lib" ]]; then
    # shellcheck source=../../autonomous-dispatcher/scripts/lib-issue-provider.sh
    source "$_mic_lib"
  fi
  unset _mic_real_dir _mic_lib
fi

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
  # Fetch current issue body via the itp_read_task READ leaf (#296, [INV-87];
  # [W1b] #396). ABSTRACT contract: no gh flags or jq programs cross the seam
  # — the leaf returns a normalized object and the caller projects `.body`
  # with plain jq. The returned body STRING is identical to the pre-#396
  # shape-equivalent migration; only the seam's own argv changed. If the
  # provider lib is unavailable itp_read_task stays undefined and this FAILs
  # LOUD here (earlier than the PATCH-cap branch below) — intentionally, NOT a
  # raw `gh` fallback ([INV-91]: a hardcoded GitHub read would execute against
  # GitHub even for a non-GitHub backend; re-adding it would re-introduce the
  # survivor this migration removes). The `|| { … }` handler is unchanged.
  local body
  if ! declare -F itp_read_task >/dev/null 2>&1; then
    echo "Error: itp_read_task not available (provider lib not loaded; ISSUE_PROVIDER=${ISSUE_PROVIDER:-?}). Cannot fetch issue #${ISSUE_NUMBER}." >&2
    return 1
  fi
  body=$(itp_read_task "$ISSUE_NUMBER" body | jq -r '.body') || {
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

  # [INV-87] PATCH the issue body via the body-checkbox write leaf. The
  # `- [ ]`→`- [x]` awk rewrite above + the not-found/already-checked exit codes
  # (0/1/2) stay caller-side; only the PATCH primitive moves behind
  # itp_mark_checkbox, which receives the already-rewritten body.
  #
  # The DOCUMENTED branch point is the `body_checkbox` CAPABILITY (spec §4.1), NOT
  # `declare -F itp_mark_checkbox` — after lib-issue-provider.sh is sourced the
  # `itp_mark_checkbox` SHIM is always defined (it forwards to
  # itp_${ISSUE_PROVIDER}_mark_checkbox), so a `declare -F` check never falls back
  # and a backend without the leaf would crash with `itp_<p>_mark_checkbox: command
  # not found`. We branch on the cap instead:
  #   - body_checkbox=1 (GitHub) → the markdown-checkbox path: itp_mark_checkbox
  #     emits the byte-identical
  #     `gh api repos/$REPO/issues/$N --method PATCH --field body=… --silent`.
  #   - body_checkbox=0 → the documented native-subtask-completion remap, DEFINED
  #     but NOT IMPLEMENTED this PR — fail LOUD-but-clean (no missing-leaf crash) so
  #     the no-behavior-change scope holds and the gap is visible, not silent.
  # When the provider lib is unavailable the itp_mark_checkbox SHIM is undefined; we
  # FAIL LOUD ([INV-91]) rather than fall back to a raw `gh api` PATCH — a hardcoded
  # GitHub call would silently execute against GitHub even when the project is
  # configured for a non-GitHub backend (provider not loaded), the exact silent-
  # wrong-backend bug the cutover guard exists to prevent.
  local _bc_cap=""
  if declare -F itp_caps >/dev/null 2>&1; then
    _bc_cap="$(itp_caps body_checkbox 2>/dev/null || true)"
  fi
  if [[ "$_bc_cap" == "0" ]]; then
    echo "Error: provider '${ISSUE_PROVIDER:-?}' has body_checkbox=0 — native-subtask checkbox completion is not implemented yet (this PR migrates the GitHub markdown-checkbox leaf only). Cannot mark '${CHECKBOX_TEXT}' on issue #${ISSUE_NUMBER}." >&2
    return 1
  fi
  if ! declare -F itp_mark_checkbox >/dev/null 2>&1; then
    echo "Error: itp_mark_checkbox not available (provider lib not loaded; ISSUE_PROVIDER=${ISSUE_PROVIDER:-?}). Cannot mark checkbox on #${ISSUE_NUMBER}." >&2
    return 1
  fi
  itp_mark_checkbox "$ISSUE_NUMBER" "$new_body" || {
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
