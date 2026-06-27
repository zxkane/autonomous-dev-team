#!/bin/bash
# lib-review-request-changes.sh — INV-52 (#193).
#
# The review WRAPPER owns the GitHub-native PR review action: `--approve` on a
# PASS (after the INV-44 mergeable + no-auto-close gates) and `--request-changes`
# on a substantive FAIL. The review AGENT posts verdict comments ONLY and MUST
# never run `gh pr review` / `gh pr merge` itself.
#
# This file holds the FAIL-side helper, `submit_request_changes`, so it is
# unit-testable in isolation (the wrapper itself is too heavy to source — it has
# top-level side effects). Mirrors the lib-review-mergeable.sh layering.
#
# The helper is BEST-EFFORT: a permission (403) or transient failure must NOT
# abort the review wrapper under `set -e` and strand the issue in `reviewing`.
# It always returns 0; a failed submission is logged, and the caller proceeds to
# flip the issue to `pending-dev` exactly as before. This mirrors the existing
# non-fatal discipline of the PASS-side approval-failure fallback.
#
# Contract: callers MUST invoke this on the SUBSTANTIVE FAIL routes only —
# i.e. when the review reached a dev-actionable blocking verdict (the agent
# posted `Review findings:`, or the wrapper's INV-44 gate found a real merge
# CONFLICT). It MUST NOT be called for non-substantive routes (mergeable UNKNOWN
# re-queue, or an agent crash with no verdict): a standing CHANGES_REQUESTED on
# a transient/no-verdict run would falsely accuse the dev and linger on the PR.
#
# Depends on the caller environment providing: `gh` on PATH (the token-refresh
# wrapper), `REPO`, and a `log` function. `refresh_token_env` is optional — when
# defined (it is, in the wrapper) it is called first so a token that expired
# during the review is refreshed before the submit, matching the approve path.
#
# [INV-87] (#282) The innermost `gh pr review --request-changes` leaf is the CHP
# `chp_request_changes` verb (provider-spec.md §3.2; gated by the
# `rest_request_changes` cap §4.2 — a backend without a REST request-changes verb
# emulates via a quick-action note). The best-effort return-0 + token-refresh glue
# below STAYS caller-side. Sourced from the REAL skill tree via readlink -f (the
# lib-dispatch.sh idiom) so a unit test that sources only this lib still gets the
# verb. Guarded + idempotent.
if ! declare -F chp_request_changes >/dev/null 2>&1; then
  _lrc_self="${BASH_SOURCE[0]:-$0}"
  _lrc_dir="$(cd "$(dirname "$(readlink -f "$_lrc_self")")" && pwd 2>/dev/null)" || _lrc_dir=""
  if [ -n "$_lrc_dir" ] && [ -r "${_lrc_dir}/lib-code-host.sh" ]; then
    # shellcheck source=lib-code-host.sh
    source "${_lrc_dir}/lib-code-host.sh"
  fi
  unset _lrc_self _lrc_dir
fi

# submit_request_changes <pr_number> <body>
#
# Submits a GitHub PR review with REQUEST_CHANGES so the PR's `reviewDecision`
# becomes CHANGES_REQUESTED — making the blocking state authoritative for humans,
# branch protection, the dispatcher, and the dev-resume agent. Best-effort:
# always returns 0.
submit_request_changes() {
  local _pr="$1"
  local _body="$2"

  # Refresh a possibly-expired App token first (parallel to the approve path).
  # Optional: only if the caller defined it. A refresh failure is non-fatal —
  # we still attempt the submit with the current token.
  if declare -F refresh_token_env >/dev/null 2>&1; then
    refresh_token_env || log "WARNING: token refresh failed before REQUEST_CHANGES — attempting with current token..."
  fi

  # [INV-87]/[M2] capability gate (§4.2 `rest_request_changes`). GitHub
  # (rest_request_changes=1) submits the native REST review via chp_request_changes;
  # a backend without a REST request-changes verb (rest_request_changes=0, e.g.
  # GitLab) has no equivalent — emulate via a quick-action note / unresolved-
  # discussion convention (its own provider impl). The cap reader degrades to "1"
  # (today's GitHub behavior) when chp_caps is unavailable, so the no-cap legacy
  # path is unchanged. The best-effort return-0 + token-refresh glue stays here.
  local _rest_rc=1
  if declare -F chp_caps >/dev/null 2>&1; then
    _rest_rc="$(chp_caps rest_request_changes 2>/dev/null || echo 1)"
  fi
  if [[ "$_rest_rc" != "1" ]]; then
    log "WARNING: code host has no REST request-changes verb (rest_request_changes=${_rest_rc}); skipping the native review submit for PR #${_pr} (the FAIL route's findings comment + label flip still apply). A request-changes-less backend emulates via its own quick-action convention."
    return 0
  fi

  log "Submitting REQUEST_CHANGES review for PR #${_pr} (INV-52: wrapper owns the GitHub-native review action)..."
  # [INV-87] the `gh pr review --request-changes` leaf moves behind chp_request_changes.
  if chp_request_changes "$_pr" "$_body" 2>&1; then
    log "PR #${_pr} reviewDecision set to CHANGES_REQUESTED (blocking findings are now authoritative)."
  else
    # Non-fatal: a 403 / permission / transient failure must NOT abort the
    # FAIL route. The issue still flips to pending-dev and the findings comment
    # already carries the dev-actionable detail; only the PR's native
    # reviewDecision is missed. Mirrors the dev-resume side's `|| log` discipline.
    log "WARNING: Failed to submit REQUEST_CHANGES for PR #${_pr} (permission/transient?) — non-fatal; the FAIL route continues. reviewDecision may stay non-blocking until the next review."
  fi
  return 0
}
