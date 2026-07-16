#!/bin/bash
# lib-review-resolve-author.sh — resolve_pr_author_mention +
# resolve_operator_mention (issue #495).
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
# `resolve_operator_mention` (no args) is the sibling entry point for the 8
# sites that never resolve a PR author at all (the 2 maintainer-only sites +
# the 6 operator-only sites where no PR is guaranteed to exist) — it's the
# SAME validated `HUMAN_ESCALATION_LOGIN`/`REPO_OWNER` fallback chain
# `resolve_pr_author_mention` falls through to, exposed directly so those 8
# sites stop interpolating `${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}` raw and
# skipping the malformed-token validation (#495 review round 4 finding #1).
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
#     `[bot]`, or a personal-PAT bot account). `BOT_LOGIN` is resolved only
#     inside `autonomous-review.sh`'s own process ([INV-…], see that
#     wrapper's `gh api user` call) — it is NEVER set in the dispatcher's own
#     process, so this arm is a no-op on the `lib-dispatch.sh` call path.
#   - exactly equals the operator-configured `DEV_BOT_LOGIN` (when non-empty)
#     — the dispatcher-side counterpart to the `BOT_LOGIN` arm above (#495
#     review finding #1). In `GH_AUTH_MODE=token`, the dev agent's commits/PRs
#     are authored under the SAME shared PAT identity the dispatcher runs
#     under; when that identity is a plain service-account login (no `app/`
#     prefix, no `[bot]` suffix — e.g. `my-org-ci-bot`), neither of the two
#     structural rules above can see it, and `BOT_LOGIN` is unavailable in
#     this process (see above) to catch it either. Rather than resolving an
#     identity dynamically here (which would require a raw `gh api user` /
#     GitLab `/user` call, violating this lib's [INV-87] provider-neutral
#     "chp_pr_view is the only PR-read primitive" contract, and would also
#     collide with the load-bearing "BOT_LOGIN never set in the dispatcher's
#     own process" invariant several `lib-dispatch.sh` verdict-authentication
#     paths depend on — see `_frozen_convergence_rounds_json`), the operator
#     sets `DEV_BOT_LOGIN` once in `autonomous.conf` (documented next to
#     `HUMAN_ESCALATION_LOGIN`). Unset by default — a byte-identical no-op
#     for every deployment that doesn't need it (GitHub App mode's `[bot]`
#     suffix already covers the common case).
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
  [ -n "${DEV_BOT_LOGIN:-}" ] && [ "$login" = "$DEV_BOT_LOGIN" ] && return 0
  return 1
}

# _rpam_malformed_mention_token <value> — true if `value` cannot safely be
# the SOLE content of an `@<value>` mention token (#495 review round 3
# finding #2): embedded whitespace (including newlines — same multi-token/
# multiline risk the malformed-`.author`-shape guard below already covers)
# or an embedded `@` (an operator pasting `@maintainer` verbatim into
# `HUMAN_ESCALATION_LOGIN`, or a value like `alice@evil`, would otherwise
# render `@@maintainer`/`@alice@evil` — a second/malformed mention token,
# not a mangled first one, but still a violation of "exactly one token").
_rpam_malformed_mention_token() {
  case "$1" in
    *[[:space:]]*|*'@'*) return 0 ;;
  esac
  return 1
}

# _rpam_fallback — the layered fallback chain's terminal token (R2): a
# non-empty, well-formed-as-a-mention `HUMAN_ESCALATION_LOGIN` wins;
# otherwise `REPO_OWNER`. Both are read as `${VAR:-}` so a genuinely UNSET
# var can never abort a `set -u` caller; REPO_OWNER's non-emptiness is
# already enforced by every caller's own top-level `: "${REPO_OWNER:?...}"` /
# required-env loop, so this never emits an empty token in production.
#
# A configured `HUMAN_ESCALATION_LOGIN` that fails
# `_rpam_malformed_mention_token` (round 3 finding: printed VERBATIM, it
# could carry whitespace/`@` into the mention and break the exactly-one-
# token contract R2 requires) is treated as absent — falls through to
# `REPO_OWNER` — rather than aborting or emitting the bad value.
_rpam_fallback() {
  local human="${HUMAN_ESCALATION_LOGIN:-}"
  if [ -n "$human" ] && ! _rpam_malformed_mention_token "$human"; then
    printf '@%s' "$human"
    return 0
  fi
  if [ -n "$human" ]; then
    echo "WARN: resolve_pr_author_mention: configured HUMAN_ESCALATION_LOGIN '${human}' is not a valid single-token mention — falling back to REPO_OWNER" >&2
  fi
  printf '@%s' "${REPO_OWNER:-}"
}

# resolve_operator_mention — the validated operator-target mention for sites
# that never call resolve_pr_author_mention: the 2 maintainer-only sites
# (approval-failed, no-auto-close — a PR author can't approve/merge their own
# PR) and the 6 operator-only sites (no PR guaranteed to exist — MAX_RETRIES,
# the non-substantive flip cap, the degraded no-progress tracker notice, the
# liveness bookkeeping-marker warning, the liveness tier-1 notice, and the
# class-level park backstop). All 8 previously interpolated
# `@${HUMAN_ESCALATION_LOGIN:-$REPO_OWNER}` directly, which bypassed
# `_rpam_fallback`'s validation — a `HUMAN_ESCALATION_LOGIN` containing
# whitespace or an embedded `@` would be echoed verbatim into these comment
# bodies too, breaking the same "exactly one `@<token>`" contract R2 already
# guards for the resolver's own fallback path (#495 review round 4 finding
# #1). Same rc-0/single-token contract as `resolve_pr_author_mention`;
# `_rpam_fallback` is the exact same validated chain.
resolve_operator_mention() {
  _rpam_fallback
}

# resolve_pr_author_mention <PR_NUMBER>
#
# ALWAYS exits 0 (never aborts a `set -e` caller — every internal failure path
# routes to `_rpam_fallback` and returns rc 0, never `return 1`). Emits EXACTLY
# ONE non-empty `@<login>` mention token on stdout; diagnostics only to
# stderr.
#
# Success path: `chp_pr_view PR author` resolves a non-null, non-empty,
# single-token STRING, NOT-a-bot author → `@<login>`.
#
# Fallback path (→ `_rpam_fallback`): bot author, null/empty author, a
# non-string `.author` shape (e.g. `{"login":"evil"}` — a malformed
# provider-leaf projection would otherwise be echoed verbatim into the
# mention, producing a multiline/multi-token comment body — #495 review
# round 3 finding), an author string that fails `_rpam_malformed_mention_token`
# (embedded whitespace/newline, or an embedded `@` — e.g. `alice@evil` would
# otherwise render `@alice@evil`, a second/malformed mention token — #495
# review round 5 finding), non-numeric/empty PR arg, `chp_pr_view` failure, or
# malformed (non-JSON-object) output.
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
  login="$(jq -r '.author | if type == "string" then . else "" end' <<<"$raw" 2>/dev/null)"
  if [ -z "$login" ]; then
    echo "WARN: resolve_pr_author_mention: PR #${pr} has no resolvable string author — falling back to the operator target" >&2
    _rpam_fallback
    return 0
  fi
  if _rpam_malformed_mention_token "$login"; then
    echo "WARN: resolve_pr_author_mention: PR #${pr} author '${login}' is not a valid single-token mention — falling back to the operator target" >&2
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
