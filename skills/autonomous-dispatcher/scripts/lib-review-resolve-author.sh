#!/bin/bash
# lib-review-resolve-author.sh — resolve_pr_author_mention (issue #495).
#
# Human-in-the-loop escalation comments ("marking stalled", "please
# investigate") unconditionally @-mentioned `${REPO_OWNER}`. On GitLab,
# `REPO_OWNER` is the project's *group* namespace — mentioning it notifies
# EVERY member of the group on every stall. The right target for a PR-scoped
# escalation is a responsible human for THAT PR; the group blast is the
# fallback, not the default.
#
# Naive "mention the PR author" is WORSE than the group blast on this
# pipeline: an autonomous PR's author is normally the dev-agent BOT itself
# (`app/...` on GitHub, a `*_bot_*` service account on GitLab) — mentioning it
# notifies nobody. So this resolver is bot-detection-FIRST: it only emits the
# real PR author when that author is demonstrably a human, and otherwise falls
# back through `HUMAN_ESCALATION_LOGIN` to `REPO_OWNER`.
#
# Lives in its own lib (mirrors lib-pr-linkage.sh / lib-review-request-
# changes.sh layering) so BOTH the dispatcher (`lib-dispatch.sh`) AND the
# review wrapper (`autonomous-review.sh`, which does NOT source the heavy
# lib-dispatch.sh) can resolve the SAME mention target identically.
#
# [INV-87] `chp_pr_view` (lib-code-host.sh) is the ONLY PR-read primitive this
# lib calls — no raw `gh`/`_gl_api` here, provider-neutral by construction.
# Sourced from the REAL skill tree via readlink -f (the lib-pr-linkage.sh
# idiom) so a standalone unit test that sources only this lib still gets the
# verb. Idempotent (the shim guards its own redefinition).
if ! declare -F chp_pr_view >/dev/null 2>&1; then
  _lram_self="${BASH_SOURCE[0]:-$0}"
  _lram_dir="$(cd "$(dirname "$(readlink -f "$_lram_self")")" && pwd 2>/dev/null)" || _lram_dir=""
  if [ -n "$_lram_dir" ] && [ -r "${_lram_dir}/lib-code-host.sh" ]; then
    # shellcheck source=lib-code-host.sh
    source "${_lram_dir}/lib-code-host.sh"
  fi
  unset _lram_self _lram_dir
fi

# _rpam_is_bot_login <login> — mandatory bot-detection rule (R2).
#
# A login is a bot iff it matches ONE of:
#   - GitHub App slug prefix:  ^app/
#   - GitHub App display suffix: [bot]$  (e.g. `my-claw[bot]`)
#   - GitLab Project/Group Access Token convention:
#     ^(project|group)_[0-9]+_bot(_[a-z0-9]+)?$
#   - exactly equals the wrapper's own `BOT_LOGIN` (when non-empty) — catches
#     any identity this SAME wrapper authenticates as, regardless of naming
#     convention (e.g. a custom GitHub App display name that doesn't end in
#     `[bot]`, or a personal-PAT bot account).
#
# Deliberately NOT a broad `*bot*` substring match — a human login containing
# "bot" (e.g. `robert`, `abbot`) must never be misclassified.
_rpam_is_bot_login() {
  local login="$1"
  case "$login" in
    app/*) return 0 ;;
    *'[bot]') return 0 ;;
  esac
  [[ "$login" =~ ^(project|group)_[0-9]+_bot(_[a-z0-9]+)?$ ]] && return 0
  [ -n "${BOT_LOGIN:-}" ] && [ "$login" = "$BOT_LOGIN" ] && return 0
  return 1
}

# _rpam_fallback — the layered fallback chain's terminal token (R2): non-empty
# `HUMAN_ESCALATION_LOGIN` wins; otherwise `REPO_OWNER`. Both are read as
# `${VAR:-}` so a genuinely UNSET var can never abort a `set -u` caller;
# REPO_OWNER's non-emptiness is already enforced by every caller's own
# top-level `: "${REPO_OWNER:?...}"` / required-env loop, so this never emits
# an empty token in production.
_rpam_fallback() {
  if [ -n "${HUMAN_ESCALATION_LOGIN:-}" ]; then
    printf '@%s' "$HUMAN_ESCALATION_LOGIN"
  else
    printf '@%s' "${REPO_OWNER:-}"
  fi
}

# resolve_pr_author_mention <PR_NUMBER>
#
# ALWAYS exits 0 (never aborts a `set -e` caller — every internal failure path
# routes to `_rpam_fallback` and returns rc 0, never `return 1`). Emits EXACTLY
# ONE non-empty `@<login>` mention token on stdout; diagnostics only to
# stderr.
#
# Success path: `chp_pr_view PR author` resolves a non-null, non-empty,
# NOT-a-bot author → `@<login>`.
#
# Fallback path (→ `_rpam_fallback`): bot author, null/empty author,
# non-numeric/empty PR arg, `chp_pr_view` failure, or malformed
# (non-JSON-object) output.
resolve_pr_author_mention() {
  local pr="${1:-}"
  if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
    echo "WARN: resolve_pr_author_mention: PR arg non-numeric/empty ('${pr}') — falling back to the operator target" >&2
    _rpam_fallback
    return 0
  fi

  local raw
  if ! raw="$(chp_pr_view "$pr" "author" 2>/dev/null)"; then
    echo "WARN: resolve_pr_author_mention: chp_pr_view failed for PR #${pr} — falling back to the operator target" >&2
    _rpam_fallback
    return 0
  fi
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$raw"; then
    echo "WARN: resolve_pr_author_mention: malformed chp_pr_view output for PR #${pr} — falling back to the operator target" >&2
    _rpam_fallback
    return 0
  fi

  local login
  login="$(jq -r '.author // empty' <<<"$raw" 2>/dev/null)"
  if [ -z "$login" ]; then
    echo "WARN: resolve_pr_author_mention: PR #${pr} has no resolvable author — falling back to the operator target" >&2
    _rpam_fallback
    return 0
  fi

  if _rpam_is_bot_login "$login"; then
    echo "INFO: resolve_pr_author_mention: PR #${pr} author '${login}' classified as a bot — falling back to the operator target" >&2
    _rpam_fallback
    return 0
  fi

  printf '@%s' "$login"
  return 0
}
