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
#                Use the EXACT literal path the wrapper rendered into your
#                prompt — never a hand-constructed path, and never a copy of
#                this doc-comment's template with unexpanded `${...}` tokens
#                (that would recreate a shared literal path across every
#                agent that copies it verbatim).
#
#   [INV-100] (#355) READ-SIDE ENFORCEMENT: when the wrapper has exported
#   VERDICT_BODY_FILE into this agent's environment, <body-file> MUST resolve
#   (realpath) to the SAME file, or the post is refused (exit 2, nothing
#   posted) — this is what makes a RESUMED agent session holding an OLD prompt
#   (pre-#354/#355, a bare or session-id-keyed path) fail LOUD instead of
#   silently posting a foreign/stale body. Any `/tmp/verdict*.md` path that
#   does NOT equal VERDICT_BODY_FILE is rejected outright, even before the
#   realpath comparison, so a legacy literal in an old prompt can't slip
#   through by accident. An EMPTY (0-byte or whitespace-only) body file is
#   also rejected — a wrapper-pre-created-but-never-written file must not post
#   (mirrors the INV-73 "malformed → never a phantom verdict" rule). When
#   VERDICT_BODY_FILE is UNSET (human/ad-hoc use, or a caller that predates
#   #355), none of this runs — behavior is unchanged from before #355.
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
#       model containing a control character (newline/CR) or over the length cap /
#       [INV-100] body-file does not match VERDICT_BODY_FILE / a legacy
#       /tmp/verdict*.md path while VERDICT_BODY_FILE is set / an empty body
#       file while VERDICT_BODY_FILE is set).
#
# Example (illustrative only — in a real run, use the EXACT path the wrapper
# rendered into your prompt, not this template):
#   printf '%s' "$findings" > "$VERDICT_BODY_FILE"
#   bash scripts/post-verdict.sh 202 fail "$VERDICT_BODY_FILE" codex "$SESSION_ID" sonnet

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

# [INV-69] Source lib-config.sh for pid_dir_for_project() — the deterministic dir
# under which a failed-post breadcrumb is written (the wrapper reconstructs the
# same path from the agent's session id). Co-located in the dispatcher scripts/
# dir (a sibling of this helper). Best-effort: if it's absent, the breadcrumb is
# simply skipped — it is a diagnostic, never load-bearing for the exit code.
if [[ -f "${SCRIPT_DIR}/lib-config.sh" ]]; then
  # shellcheck source=lib-config.sh
  source "${SCRIPT_DIR}/lib-config.sh"
fi

# [INV-87]/[INV-89] Issue-Tracker Provider dispatch. The fallback verdict comment
# this helper posts is an issue-level MACHINE MARKER (the INV-78 comment fallback
# the review wrapper scrapes when the typed artifact is absent; it carries the
# `Review PASSED` / `Review findings:` + `Review Session:` / `Review Agent:`
# trailer) and therefore MUST post through itp_post_comment on the declared
# marker_channel ([`provider-spec.md`] INV-77/INV-78 reconciliation). Resolve the
# provider lib from the REAL skill tree via readlink -f of THIS script (the
# [INV-14]/[INV-65] idiom) — NOT SCRIPT_DIR, which is the project-side symlink dir
# (libs are not symlinked there). Guarded + idempotent; if the lib is absent the
# verb stays undefined and the post site below falls back to the proxy `$GH`
# directly (keeps the helper self-contained).
if ! declare -F itp_post_comment >/dev/null 2>&1; then
  _pv_real_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")")" && pwd 2>/dev/null)" || _pv_real_dir=""
  if [[ -n "$_pv_real_dir" && -r "${_pv_real_dir}/lib-issue-provider.sh" ]]; then
    # shellcheck source=lib-issue-provider.sh
    source "${_pv_real_dir}/lib-issue-provider.sh"
  fi
  unset _pv_real_dir
fi

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

# --- [INV-100] (#355) READ-SIDE path enforcement ---------------------------
# When the wrapper exported VERDICT_BODY_FILE into this agent's environment,
# the caller-supplied BODY_FILE MUST be that exact file. This is what closes
# the "resumed agent still holds an old prompt" hole: a wrapper-side render
# fix (D1) only changes prompts rendered AFTER the fix ships — a session
# resumed from before #354/#355 still has the OLD literal path in its context
# and would otherwise write there with a fresh mtime, indistinguishable from a
# genuine post. Enforcing the match HERE, at the one chokepoint every verdict
# post routes through, closes it regardless of what the agent's prompt history
# says. Skipped entirely (byte-for-byte legacy behavior) when the caller/
# environment does not set VERDICT_BODY_FILE — human/ad-hoc use, or any
# pre-#355 caller.
if [[ -n "${VERDICT_BODY_FILE:-}" ]]; then
  # Reject stdin (`-`) outright — VERDICT_BODY_FILE names a concrete file, so a
  # caller passing `-` cannot be complying with the rendered path.
  if [[ "$BODY_FILE" == "-" ]]; then
    echo "Error: [INV-100] VERDICT_BODY_FILE is set (${VERDICT_BODY_FILE}) but body-file arg is '-' (stdin) — use the rendered file path, not stdin." >&2
    exit 2
  fi
  # Reject any OTHER /tmp/verdict*.md literal outright, before the realpath
  # comparison — a legacy bare or session-id-keyed form (pre-#354/#355) is
  # rejected on sight even if it happens to resolve to a live file.
  if [[ "$BODY_FILE" == /tmp/verdict*.md && "$BODY_FILE" != "$VERDICT_BODY_FILE" ]]; then
    echo "Error: [INV-100] legacy verdict-body path '${BODY_FILE}' rejected — VERDICT_BODY_FILE is set to '${VERDICT_BODY_FILE}'. Your prompt is stale; use the path the CURRENT prompt rendered." >&2
    exit 2
  fi
  # realpath-compare (resolves symlinks/relative components); a body-file that
  # does not exist yet cannot realpath-resolve, which correctly fails closed
  # (rather than passing on an as-yet-nonexistent path that merely LOOKS equal).
  _pv_real_body="$(realpath -- "$BODY_FILE" 2>/dev/null || true)"
  _pv_real_expected="$(realpath -- "$VERDICT_BODY_FILE" 2>/dev/null || printf '%s' "$VERDICT_BODY_FILE")"
  if [[ -z "$_pv_real_body" || "$_pv_real_body" != "$_pv_real_expected" ]]; then
    echo "Error: [INV-100] body-file '${BODY_FILE}' does not match the wrapper-rendered VERDICT_BODY_FILE '${VERDICT_BODY_FILE}' — refusing to post a mismatched path." >&2
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

# [INV-100] (#355): under the enforced path (VERDICT_BODY_FILE set), an EMPTY
# (0-byte or whitespace-only) body is refused rather than posted. A file that
# is empty means the wrapper pre-created the lane's verdict.md (or the agent
# never wrote it) — posting it would be indistinguishable from a real empty
# PASS/FAIL body. Mirrors the INV-73 "malformed → never a phantom verdict"
# rule: the caller must not post nothing. Exit 2 → the wrapper's poller finds
# no comment and resolves this agent `unavailable`, same as never reviewing.
# Gated on VERDICT_BODY_FILE so the unset-var (legacy) path is byte-for-byte
# unchanged — an empty body via ad-hoc/human use still posts today's default
# PASS/FAIL prefix-only body, exactly as before #355.
if [[ -n "${VERDICT_BODY_FILE:-}" ]] && [[ -z "${BODY_TEXT//[[:space:]]/}" ]]; then
  echo "Error: [INV-100] body file '${BODY_FILE}' is empty/whitespace-only — refusing to post (treated as unavailable, not a phantom verdict)." >&2
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
  echo "Error: token-refresh CLI proxy not found/executable at '${GH}'. Refusing to post the verdict via a bare PATH CLI call (it would mis-attribute the comment). Re-run install-project-hooks.sh to restore the token-refresh proxy symlink (scripts/gh, INV-56)." >&2
  exit 1
fi

# [INV-89]/[INV-56] Post through the ITP marker choke-point itp_post_comment so a
# non-GitHub / marker_channel=text provider routes the INV-78 fallback verdict
# comment correctly. itp_post_comment → itp_github_post_comment emits bare
# `gh issue comment "$ISSUE" --repo "$REPO" --body "$BODY"` — IDENTICAL argv to the
# direct `$GH …` call below, AND identical comment URL on stdout. To preserve the
# [INV-56] identity guarantee (the verdict MUST post via the token-refresh proxy,
# never the host's bare `gh auth` session), prepend the proxy's dir to PATH for the
# call so the verb's bare `gh` resolves to `${SCRIPT_DIR}/gh` (the proxy). When the
# provider lib is unavailable (verb undefined) fall back to the proxy `$GH`
# directly — self-contained, same argv.
set +e
if declare -F itp_post_comment >/dev/null 2>&1; then
  URL=$(PATH="${SCRIPT_DIR}:${PATH}" itp_post_comment "$ISSUE_NUMBER" "$COMPOSED" 2>&1)
else
  URL=$("$GH" issue comment "$ISSUE_NUMBER" --repo "$REPO" --body "$COMPOSED" 2>&1)
fi
POST_RC=$?
set -e

if [[ $POST_RC -ne 0 ]]; then
  echo "Error: failed to post verdict comment on issue #${ISSUE_NUMBER} (cli rc=${POST_RC})" >&2
  echo "$URL" >&2
  # [INV-69] Drop a session-keyed breadcrumb so the review wrapper can surface a
  # distinct `post-failed` drop reason (vs. the bare opaque `unavailable` a
  # never-reviewed agent produces). The wrapper reconstructs this exact path from
  # the agent's own session id. BEST-EFFORT: any failure to write it (lib-config
  # absent, pid dir unresolvable / unwritable) is swallowed — the breadcrumb is a
  # diagnostic and MUST NOT change this helper's exit code, which stays 1 on the
  # underlying post failure. Written only here (on a failed post); a successful
  # post leaves no breadcrumb.
  if declare -F pid_dir_for_project >/dev/null 2>&1; then
    _bc_dir=$(pid_dir_for_project 2>/dev/null || true)
    if [[ -n "${_bc_dir:-}" && -d "$_bc_dir" ]]; then
      _bc="${_bc_dir}/verdict-postfail-${SESSION_ID}"
      # The actual confidentiality guarantee is the parent pid dir (0700,
      # owner-only — enforced by lib-config.sh::pid_dir_for_project). Belt-and-
      # suspenders, we ALSO make the breadcrumb itself 0600: a `umask 077` in the
      # subshell means the create (`: > "$_bc"`) lands at 0600 with NO window in
      # which it is group/world-readable, and a final `chmod 600` self-heals if the
      # file pre-existed at a looser mode. The whole block runs in a
      # `( set +e … ) || true` subshell so a write race / permission issue can never
      # abort the helper under `set -e` — the breadcrumb is best-effort and MUST NOT
      # change the exit code (stays 1 below).
      ( set +e
        umask 077
        : > "$_bc" 2>/dev/null
        {
          printf 'issue=%s\n' "$ISSUE_NUMBER"
          printf 'agent=%s\n' "$AGENT_NAME"
          printf 'session=%s\n' "$SESSION_ID"
          printf 'gh_rc=%s\n' "$POST_RC"
        } >> "$_bc" 2>/dev/null
        chmod 600 "$_bc" 2>/dev/null
      ) || true
    fi
  fi
  exit 1
fi

# [INV-69 / INV-78] Successful post — CLEAR any stale post-failed breadcrumb for
# this session. The breadcrumb is a "the LAST post attempt failed" signal, and a
# review CLI may call this helper more than once per session (a first attempt
# fails → breadcrumb written; a retry succeeds → comment lands). Without this
# removal the stale breadcrumb would persist and the wrapper's INV-78
# breadcrumb-gated artifact re-post would DOUBLE-POST (it would believe the
# agent's comment never landed). Best-effort: a removal failure never changes the
# success exit code. Reconstructs the SAME path the failure branch writes.
# Guard on PROJECT_ID first: pid_dir_for_project's leading `${PROJECT_ID:?…}`
# HARD-EXITS the shell when PROJECT_ID is unset (a `:?` abort that `|| true`
# inside the `$(…)` does NOT recover — it fires before the `||`). With no
# PROJECT_ID there is no per-project pid dir and so no breadcrumb to clear, so
# skipping is correct AND keeps a successful post returning 0 (the bug a missing
# guard caused: a clean post exited 1 whenever PROJECT_ID was unset). Run the
# removal in a `( … ) || true` subshell as belt-and-suspenders so any residual
# abort can never change this helper's success exit code.
if [[ -n "${PROJECT_ID:-}" ]] && declare -F pid_dir_for_project >/dev/null 2>&1; then
  ( set +e
    _bc_dir=$(pid_dir_for_project 2>/dev/null || true)
    [[ -n "${_bc_dir:-}" ]] && rm -f "${_bc_dir}/verdict-postfail-${SESSION_ID}" 2>/dev/null
  ) || true
fi

echo "$URL"
