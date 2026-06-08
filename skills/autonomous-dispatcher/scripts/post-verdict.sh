#!/bin/bash
# post-verdict.sh — Deterministically post a review agent's verdict comment.
#
# [INV-56] Review agents MUST post their verdict comment through this helper
# rather than a hand-rolled bare `gh issue comment`. Background (issue #202):
# the `agy` review agent exited 0 claiming it posted the verdict, but its own
# multi-line `gh issue comment --body "..."` never landed (it mis-forms/
# mis-escapes the call), so the wrapper's verdict poller (INV-40) found nothing
# and dropped agy `unavailable` on every fleet review. In the SAME run, agy's
# `mark-issue-checkbox.sh` calls (a deterministic helper using the token-refresh
# `gh` proxy) landed fine. So routing the verdict through a helper that takes
# structured args + a body FILE and forms the `gh` call itself makes the post
# reliable.
#
# The helper:
#   - composes the canonical AGENT verdict trailer itself (the two load-bearing
#     `Review Session:` / `Review Agent:` lines, INV-40 / INV-20) — the agent
#     never hand-writes the trailer (this also closes the session-id-rebind
#     hazard). NOTE: this is the AGENT verdict trailer, NOT
#     `lib-review-verdict.sh::emit_verdict_trailer` (the wrapper's
#     machine-readable `<!-- review-verdict: … -->` marker — a different trailer).
#   - guarantees the first-line phrasing the comment poller matches
#     (`Review PASSED` / `Review findings:`, lib-review-poll.sh::_classify_verdict_body);
#   - posts via the token-refresh proxy `gh` (NOT bare gh) so the right identity
#     + real-gh resolution are guaranteed;
#   - fails loudly: non-zero exit if the post fails, echoes the comment URL on
#     success.
#
# Usage:
#   post-verdict.sh <issue-number> <pass|fail> <body-file|-> <agent-name> <session-id>
#
#   <body-file>  Path to a file holding the findings/summary body, or `-` to
#                read the body from stdin. A FILE (not an argv string) is used
#                so a multi-line body with backticks/quotes/$() can't be mangled
#                by the agent's shell quoting (the suspected agy failure mode).
#
# Exit codes:
#   0 — Comment posted; comment URL echoed on stdout.
#   1 — gh post failed, or a config/runtime error.
#   2 — Invalid arguments (bad issue number / verdict / unreadable body / name).
#
# Example:
#   printf '%s' "$findings" > /tmp/verdict.md
#   bash scripts/post-verdict.sh 202 fail /tmp/verdict.md codex "$SESSION_ID"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Load config (REPO): co-located, then dispatcher scripts, then project root
# scripts/ — exactly the lookup order mark-issue-checkbox.sh uses.
for _conf_candidate in \
    "${SCRIPT_DIR}/autonomous.conf" \
    "${SCRIPT_DIR}/../../autonomous-dispatcher/scripts/autonomous.conf" \
    "$(cd "${SCRIPT_DIR}/../../.." 2>/dev/null && pwd)/scripts/autonomous.conf"; do
  if [[ -f "$_conf_candidate" ]]; then
    # shellcheck disable=SC1090
    source "$_conf_candidate"
    break
  fi
done
REPO="${GITHUB_REPO:-${REPO:-owner/repo}}"

ISSUE_NUMBER="${1:-}"
VERDICT_RAW="${2:-}"
BODY_FILE="${3:-}"
AGENT_NAME="${4:-}"
SESSION_ID="${5:-}"

usage() {
  echo "Usage: $0 <issue-number> <pass|fail> <body-file|-> <agent-name> <session-id>" >&2
}

if [[ -z "$ISSUE_NUMBER" || -z "$VERDICT_RAW" || -z "$BODY_FILE" || -z "$AGENT_NAME" || -z "$SESSION_ID" ]]; then
  usage
  exit 2
fi

# --- Validate / normalize args (exit 2 on bad input) ----------------------

if ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Error: issue number must be a positive integer, got '$ISSUE_NUMBER'" >&2
  exit 2
fi

# Verdict is case-insensitive; normalize to lowercase.
VERDICT=$(printf '%s' "$VERDICT_RAW" | tr '[:upper:]' '[:lower:]')
if [[ "$VERDICT" != "pass" && "$VERDICT" != "fail" ]]; then
  echo "Error: verdict must be 'pass' or 'fail', got '$VERDICT_RAW'" >&2
  exit 2
fi

# Agent name + session id are interpolated into the trailer; keep them tame.
if ! [[ "$AGENT_NAME" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
  echo "Error: agent name must be [A-Za-z0-9._-], 1-64 chars, got '$AGENT_NAME'" >&2
  exit 2
fi
if ! [[ "$SESSION_ID" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
  echo "Error: session id must be [A-Za-z0-9._-], 1-64 chars, got '$SESSION_ID'" >&2
  exit 2
fi

# --- Read the body (file or stdin) ----------------------------------------

MAX_BODY_BYTES=65536
read_body() {
  if [[ "$BODY_FILE" == "-" ]]; then
    cat
  else
    if [[ ! -r "$BODY_FILE" ]]; then
      echo "Error: body file not readable: '$BODY_FILE'" >&2
      return 2
    fi
    cat -- "$BODY_FILE"
  fi
}

set +e
BODY_TEXT=$(read_body)
READ_RC=$?
set -e
if [[ $READ_RC -ne 0 ]]; then
  exit 2
fi

if [[ ${#BODY_TEXT} -gt $MAX_BODY_BYTES ]]; then
  echo "Error: body too long (${#BODY_TEXT} bytes, max ${MAX_BODY_BYTES})" >&2
  exit 2
fi

# --- Guarantee the canonical first-line phrasing the poller matches -------
# lib-review-poll.sh::_classify_verdict_body keys on the first line:
#   fail → 'Review findings:' (FAIL-first), pass → 'Review PASSED'.
# If the agent's body already starts with the canonical prefix, leave it; else
# prepend it so the verdict is classifiable regardless of how the agent worded
# its body. Match the first line via a here-string (NOT `printf | head | grep`,
# which races SIGPIPE under `set -o pipefail`); the regex is anchored to the
# start of string and the prefix can't span a newline, so `^` alone suffices.
FIRST_LINE="${BODY_TEXT%%$'\n'*}"
if [[ "$VERDICT" == "pass" ]]; then
  if grep -qiE '^[[:space:]]*Review PASSED' <<<"$FIRST_LINE"; then
    COMPOSED="$BODY_TEXT"
  elif [[ -z "${BODY_TEXT//[[:space:]]/}" ]]; then
    COMPOSED="Review PASSED - All checklist items verified."
  else
    COMPOSED="Review PASSED - ${BODY_TEXT}"
  fi
else # fail
  if grep -qiE '^[[:space:]]*Review findings:' <<<"$FIRST_LINE"; then
    COMPOSED="$BODY_TEXT"
  else
    COMPOSED="Review findings:
${BODY_TEXT}"
  fi
fi

# --- Append the load-bearing AGENT verdict trailer (INV-40 / INV-20) ------
# Each line on its own line; the session id is backtick-wrapped to match the
# `Review Session: \`<id>\`` phrasing the prompt + INV-20 expect.
COMPOSED="${COMPOSED}

Review Session: \`${SESSION_ID}\`
Review Agent: ${AGENT_NAME}"

# --- Post via the token-refresh proxy `gh` (NOT bare gh) ------------------
# The proxy lives next to this helper in the dispatcher scripts/ dir (a `gh`
# symlink → gh-with-token-refresh.sh). Invoking it by absolute path forces
# resolution through the wrapper (correct bot identity + real-gh discovery),
# the same guarantee the SKILL.md "bash scripts/gh …" rule provides.
GH="${SCRIPT_DIR}/gh"
if [[ ! -x "$GH" ]]; then
  # Fall back to PATH `gh` if the co-located proxy is absent (e.g. running the
  # helper from an unusual layout). The wrapper is still preferred.
  GH="gh"
fi

set +e
URL=$("$GH" issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$COMPOSED" 2>&1)
POST_RC=$?
set -e

if [[ $POST_RC -ne 0 ]]; then
  echo "Error: failed to post verdict comment on issue #${ISSUE_NUMBER} (gh rc=${POST_RC})" >&2
  echo "$URL" >&2
  exit 1
fi

echo "$URL"
