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
#   post-verdict.sh <issue-number> <pass|fail> <body-file|-> <agent-name> <session-id> [<model>]
#
#   <body-file>  Path to a file holding the findings/summary body, or `-` to
#                read the body from stdin. A FILE (not an argv string) is used
#                so a multi-line body with backticks/quotes/$() can't be mangled
#                by the agent's shell quoting (the suspected agy failure mode).
#
#   <model>      OPTIONAL 6th arg ([INV-60], issue #208): the per-agent RESOLVED
#                review model the wrapper launched this agent with. When present
#                and non-empty, the `Review Agent:` trailer line becomes
#                `Review Agent: <name> (model: <model>)` so an operator reading
#                the verdict comment can attribute it to the model that produced
#                it — consistent with the [INV-04] `Reviewed HEAD: … model` line.
#                When omitted/empty the trailer is exactly the legacy
#                `Review Agent: <name>` (backward compatible). The `Review Agent:
#                <name>` substring at the START of the line is preserved
#                byte-for-byte either way, so the [INV-40] discriminator
#                (`test("Review Agent: <name>")`, a substring test) and the
#                [INV-20] trailer-presence binding keep matching.
#                Validation is intentionally LOOSE — a model id legitimately
#                contains spaces / parens / dots (e.g. `Gemini 3.5 Flash (High)`,
#                `claude-sonnet-4.6`) — so the strict `[A-Za-z0-9._-]` rule the
#                name/session args use does NOT apply; only a control character
#                (newline or carriage return, which would split the single-line
#                trailer) and an over-long value are rejected.
#
# Exit codes:
#   0 — Comment posted; comment URL echoed on stdout.
#   1 — gh post failed, or a config/runtime error.
#   2 — Invalid arguments (bad issue number / verdict / unreadable body / name /
#       model containing a control character (newline/CR) or over the length cap).
#
# Example:
#   printf '%s' "$findings" > /tmp/verdict.md
#   bash scripts/post-verdict.sh 202 fail /tmp/verdict.md codex "$SESSION_ID" sonnet

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
# Optional 6th arg ([INV-60]): the per-agent resolved review model. Absent/empty
# → legacy two-line trailer. Defaulted to empty so a 5-arg caller is unchanged.
MODEL="${6:-}"

usage() {
  echo "Usage: $0 <issue-number> <pass|fail> <body-file|-> <agent-name> <session-id> [<model>]" >&2
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

# Model ([INV-60]) is also interpolated into the trailer, but a model id can
# legitimately contain spaces / parens / dots (e.g. `Gemini 3.5 Flash (High)`),
# so the strict name/session regex does NOT apply. The only hazards are a
# CONTROL CHARACTER — a newline OR a carriage return (either would split the
# single-line `Review Agent:` trailer and could forge a second trailer line) —
# and an absurd length. Reject any control char (covers \n and \r), then cap
# length; everything else (spaces/parens/dots) passes verbatim. An empty/absent
# model skips this check entirely (the legacy two-line trailer path).
MAX_MODEL_CHARS=128
if [[ -n "$MODEL" ]]; then
  if [[ "$MODEL" =~ [[:cntrl:]] ]]; then
    echo "Error: model must be a single line with no control characters (newline/CR), got a value containing one" >&2
    exit 2
  fi
  if [[ ${#MODEL} -gt $MAX_MODEL_CHARS ]]; then
    echo "Error: model too long (${#MODEL} chars, max ${MAX_MODEL_CHARS})" >&2
    exit 2
  fi
fi

# --- Read the body (file or stdin) ----------------------------------------

# Cap on the agent-supplied body. GitHub's hard comment limit is 65536 bytes;
# we gate the RAW body well under that (the prepended first line + the ~60-char
# trailer the helper adds are negligible overhead). ${#var} counts characters,
# so this is a character cap — the small slack vs. a strict byte cap is
# intentional headroom, not an off-by-one.
MAX_BODY_CHARS=60000
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

if [[ ${#BODY_TEXT} -gt $MAX_BODY_CHARS ]]; then
  echo "Error: body too long (${#BODY_TEXT} chars, max ${MAX_BODY_CHARS})" >&2
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
#
# [INV-60] When a model was supplied, fold it INTO the `Review Agent:` line as a
# parenthetical AFTER the agent name — the `Review Agent: <name>` substring at
# the start of the line stays byte-for-byte intact so the INV-40 discriminator
# (`test("Review Agent: <name>")`) and the INV-20 trailer binding keep matching.
# When no model was supplied, the line is exactly the legacy `Review Agent:
# <name>` (backward compatible).
AGENT_LINE="Review Agent: ${AGENT_NAME}"
if [[ -n "$MODEL" ]]; then
  AGENT_LINE="${AGENT_LINE} (model: ${MODEL})"
fi
COMPOSED="${COMPOSED}

Review Session: \`${SESSION_ID}\`
${AGENT_LINE}"

# --- Post via the token-refresh proxy `gh` (NOT bare gh) ------------------
# The proxy lives next to this helper in the dispatcher scripts/ dir (a `gh`
# symlink → gh-with-token-refresh.sh). Invoking it by absolute path forces
# resolution through the wrapper (correct bot identity + real-gh discovery),
# the same guarantee the SKILL.md "bash scripts/gh …" rule provides.
#
# [INV-56] Absence of the co-located proxy is a LOUD failure — we do NOT fall
# back to bare PATH `gh`. Bare `gh` would resolve to the host operator's
# `gh auth` session, mis-attributing the verdict to the wrong identity — the
# exact path this helper exists to forbid. A missing proxy means a broken
# install (install-project-hooks.sh materializes `gh` alongside this helper);
# failing here surfaces that instead of silently posting under the wrong user.
GH="${SCRIPT_DIR}/gh"
if [[ ! -x "$GH" ]]; then
  echo "Error: token-refresh gh proxy not found/executable at '${GH}'. Refusing to post the verdict via bare PATH gh (it would mis-attribute the comment). Re-run install-project-hooks.sh to restore the scripts/gh symlink (INV-56)." >&2
  exit 1
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
