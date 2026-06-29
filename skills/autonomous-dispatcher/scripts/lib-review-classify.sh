#!/bin/bash
# lib-review-classify.sh — INV-92 per-finding actionability classification for
# the review wrapper (issue #298).
#
# Background. A review verdict has, until now, been verdict-LEVEL only
# (passed / failed-substantive / failed-non-substantive). It cannot say *who can
# fix a finding*. So a finding the dev agent provably cannot act on — e.g. "edit
# `.github/workflows/ci.yml`" when the agent's GitHub-App token lacks the
# `workflows` scope (the #286 deadlock), or a CODEOWNERS change — is emitted as a
# `failed-substantive` blocking finding and the dispatcher re-dispatches `dev-new`
# on something no dev-resume can satisfy. INV-85 (lib-dispatch.sh) already
# *reactively* bounds that (it detects the dev agent's 403 and escalates,
# bounded N=1 per HEAD); #298 is the *proactive, review-side* complement: skip the
# wasted dev-new round-trip and cover non-actionable findings the dev agent would
# never even signal with that exact 403.
#
# This lib is the deterministic policy surface the review wrapper uses to classify
# each blocking finding:
#   - review_path_is_protected      — does a finding's path match the protected set?
#   - agent_token_has_workflow_scope — does the agent token carry `workflows` scope?
#
# Both are PURE config-var probes — NO GitHub API call, NO sidecar file, NO
# token-daemon edit. The token scope is deterministically in the AGENT_TOKEN_PERMISSIONS
# config var (lib-auth.sh), so a `jq -e 'has("workflows")'` answers it without I/O.
#
# Pure + sourceable (mirrors lib-review-poll.sh / lib-review-artifact.sh) so the
# classification is unit-testable in isolation, without spawning the wrapper.

# REVIEW_PROTECTED_PATHS — the space-separated list of glob patterns whose
# matching paths are NOT dev-agent-actionable (a human/maintainer must edit them,
# or the agent's scoped token cannot). Conf-overridable via autonomous.conf; the
# default covers the two classic cases:
#   - .github/workflows/**  — GitHub Actions workflow files. Editing them requires
#                             the `workflows` token scope, which the agent's scoped
#                             token does NOT carry (AGENT_TOKEN_PERMISSIONS, INV-79).
#   - CODEOWNERS / .github/CODEOWNERS — code-ownership policy a maintainer owns.
# The `:=` default-assignment is conditional: an operator override in
# autonomous.conf (sourced before this lib) is preserved.
: "${REVIEW_PROTECTED_PATHS:=.github/workflows/** CODEOWNERS .github/CODEOWNERS}"

# review_path_is_protected <path>
#
# Returns 0 (true) iff <path> matches any pattern in REVIEW_PROTECTED_PATHS, else
# 1 (false). An empty <path> is never protected (rc 1) — a finding with no `file`
# field cannot be a protected-path finding.
#
# Matching uses bash extglob/globbing semantics so `**` and `*` behave like shell
# patterns (e.g. `.github/workflows/**` matches `.github/workflows/ci.yml` AND a
# nested `.github/workflows/dir/x.yml`). extglob is enabled locally and the prior
# state is restored so sourcing this lib never mutates the caller's shell options.
review_path_is_protected() {
  local _path="$1"
  [ -n "$_path" ] || return 1

  # Save + restore the caller's shell options. We need:
  #   - noglob (set -f) WHILE splitting REVIEW_PROTECTED_PATHS into patterns, so a
  #     pattern like `.github/workflows/**` is NOT pathname-expanded against the
  #     real filesystem (which would silently drop or rewrite the pattern). The
  #     split must be word-split-only.
  #   - extglob ON for the `[[ == ]]` pattern match (harmless for these globs but
  #     future-proofs richer patterns); restored afterwards.
  local _eg_was_on=0 _ng_was_on=0
  shopt -q extglob && _eg_was_on=1
  case "$-" in *f*) _ng_was_on=1 ;; esac
  shopt -s extglob
  set -f

  # Split into an array under noglob (no pathname expansion).
  local _pats=() _pat _matched=1
  # shellcheck disable=SC2206
  _pats=( $REVIEW_PROTECTED_PATHS )

  for _pat in "${_pats[@]}"; do
    [ -n "$_pat" ] || continue
    # In `[[ … == PATTERN ]]` PATTERN matching (NOT pathname expansion), `*`
    # crosses `/`. A trailing `**` is two `*` → still `*`, so
    # `.github/workflows/**` matches both `.github/workflows/ci.yml` and
    # `.github/workflows/sub/x.yml`. BUT it does NOT match the directory itself
    # (`.github/workflows`), which is fine — a finding always names a FILE. Exact
    # literals (CODEOWNERS, .github/CODEOWNERS) match by equality.
    # shellcheck disable=SC2053
    if [[ "$_path" == $_pat ]]; then
      _matched=0
      break
    fi
  done

  # Restore caller options (only flip back what we changed).
  [ "$_ng_was_on" -eq 1 ] || set +f
  [ "$_eg_was_on" -eq 1 ] || shopt -u extglob
  return "$_matched"
}

# agent_token_has_workflow_scope
#
# Returns 0 (true) iff the agent's scoped GitHub-App token carries the `workflows`
# permission — read deterministically from the AGENT_TOKEN_PERMISSIONS config var
# (lib-auth.sh: defaults to {"contents":"write","issues":"write","pull_requests":"read"},
# which has NO `workflows` key). NO API call.
#
# FAIL-OPEN (rc 1) when the var is absent/empty or not valid JSON: we cannot prove
# the token has the scope, so we treat it as lacking it (the conservative answer
# for the caller, which only ESCALATES — marks a finding non-actionable — when the
# scope is absent). A `jq` parse failure or missing `jq` therefore also yields rc 1.
agent_token_has_workflow_scope() {
  [ -n "${AGENT_TOKEN_PERMISSIONS:-}" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # Normalize the rc: `jq -e` exits 0 (true), 1 (false), or 4 (JSON parse error).
  # ANY non-zero — false OR parse error — maps to rc 1 (fail-open: lacks scope).
  jq -e 'has("workflows")' <<<"$AGENT_TOKEN_PERMISSIONS" >/dev/null 2>&1 && return 0
  return 1
}

# review_classify_artifact_dev_actionable <canonical-json>
#
# The aggregate routing signal (§3.4): echoes `true` or `false`.
#
#   true  iff ≥1 blocking finding has effective `actionable_by_dev_agent=true`
#         (the aggregate-OR — if ANY blocking finding the dev agent CAN fix exists,
#         a dev-resume is still worthwhile).
#   false iff there is ≥1 blocking finding AND EVERY blocking finding has effective
#         `actionable_by_dev_agent=false` (no dev-resume can make progress).
#
# "Effective" honors the zero-regression default: an absent `actionable_by_dev_agent`
# on a finding ⇒ `true` (a legacy artifact omitting the field behaves exactly as
# today). With NO blocking findings at all the result is `true` (fail-open — a PASS
# or an empty list never diverts routing). A non-JSON / no-jq input also yields
# `true` (fail-open — never invent a non-actionable signal from a parse failure).
#
# This is computed from the VALIDATED artifact (TOCTOU-safe, mirrors INV-49): a
# buggy agent cannot forge `dev-actionable=true` on a protected-path finding,
# because the wrapper derives the aggregate here from the schema-checked JSON, not
# from an agent-emitted summary token.
review_classify_artifact_dev_actionable() {
  local _json="$1" _out="true"
  command -v jq >/dev/null 2>&1 || { printf 'true\n'; return 0; }
  # any: ≥1 blocking finding whose effective actionable_by_dev_agent is true
  # (absent ⇒ true). none: zero blocking findings. jq prints "true"/"false".
  _out="$(jq -r '
    (.blockingFindings // []) as $bf
    | if ($bf | length) == 0 then true
      else ($bf | any(.actionable_by_dev_agent != false))
      end' <<<"$_json" 2>/dev/null || printf 'true')"
  case "$_out" in
    true|false) printf '%s\n' "$_out" ;;
    *)          printf 'true\n' ;;   # fail-open on any unexpected jq output
  esac
}
