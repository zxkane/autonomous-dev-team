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
#
# Defined ABOVE the REVIEW_PROTECTED_PATHS default (INV-134, #488) so the
# capability-aware default below can call it.
agent_token_has_workflow_scope() {
  [ -n "${AGENT_TOKEN_PERMISSIONS:-}" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  # Normalize the rc: `jq -e` exits 0 (true), 1 (false), or 4 (JSON parse error).
  # ANY non-zero — false OR parse error — maps to rc 1 (fail-open: lacks scope).
  jq -e 'has("workflows")' <<<"$AGENT_TOKEN_PERMISSIONS" >/dev/null 2>&1 && return 0
  return 1
}

# _review_protected_paths_default_list — INV-134 (#488) capability-aware DEFAULT.
#
# Echoes the built-in REVIEW_PROTECTED_PATHS default: `.github/workflows/**` is
# OMITTED iff GH_AUTH_MODE == "app" AND agent_token_has_workflow_scope returns 0
# (the minted agent token provably carries the `workflows` permission — a mint
# requesting a permission the App grant lacks FAILS, so a running wrapper with
# `workflows` in AGENT_TOKEN_PERMISSIONS proves both the conf intent and the
# grant; see the INV-92/#298 header note above — NO GitHub API probe, the App's
# grant is not the minted token's permission set). Every other case — token/PAT
# mode, GitLab (no GH_AUTH_MODE concept), scope absent, AGENT_TOKEN_PERMISSIONS
# empty/malformed/no jq — keeps `.github/workflows/**` protected: fail-closed,
# never optimistic. CODEOWNERS / .github/CODEOWNERS are protected in EVERY case
# (a maintainer-owned policy file, unrelated to token scope).
#
# This function is ONLY ever consulted when REVIEW_PROTECTED_PATHS is UNSET (see
# the `${VAR-$(...)}` assignment below, which short-circuits the command
# substitution entirely on any explicit value, including ""), so it never
# rewrites an operator's explicit override in either direction.
_review_protected_paths_default_list() {
  if [ "${GH_AUTH_MODE:-}" = "app" ] && agent_token_has_workflow_scope; then
    printf '%s' "CODEOWNERS .github/CODEOWNERS"
  else
    printf '%s' ".github/workflows/** CODEOWNERS .github/CODEOWNERS"
  fi
}

# REVIEW_PROTECTED_PATHS — the space-separated list of glob patterns whose
# matching paths are NOT dev-agent-actionable (a human/maintainer must edit them,
# or the agent's scoped token cannot). Conf-overridable via autonomous.conf; the
# default covers the two classic cases:
#   - .github/workflows/**  — GitHub Actions workflow files. Editing them requires
#                             the `workflows` token scope, which the agent's scoped
#                             token does NOT carry by default (AGENT_TOKEN_PERMISSIONS,
#                             INV-79) — OMITTED from the default when App mode +
#                             `agent_token_has_workflow_scope` prove otherwise
#                             (INV-134, #488; see _review_protected_paths_default_list).
#   - CODEOWNERS / .github/CODEOWNERS — code-ownership policy a maintainer owns.
#
# `${VAR-default}` (NO colon) — the default is applied ONLY when the var is UNSET.
# An explicit `REVIEW_PROTECTED_PATHS=""` in autonomous.conf is a deliberate
# "no protected paths" (every finding is then dev-actionable, the pre-#298 behavior
# the conf doc promises); the `:=` form previously swallowed that empty override and
# re-applied the default. An operator override to a non-empty list is preserved.
# The `$(...)` default is a command substitution, which bash evaluates ONLY when
# the parameter expansion actually needs it (i.e. only on the unset branch) — so
# an explicit value (including "") never triggers the capability probe at all.
REVIEW_PROTECTED_PATHS="${REVIEW_PROTECTED_PATHS-$(_review_protected_paths_default_list)}"

# review_path_matched_pattern <path>
#
# Echoes the FIRST pattern in REVIEW_PROTECTED_PATHS that <path> matches, and
# returns 0; echoes nothing and returns 1 if no pattern matches (or <path> is
# empty — a finding with no `file` field cannot be a protected-path finding).
# `review_path_is_protected` is a thin boolean wrapper around this (INV-134,
# #488 D4: the stall-notice diagnostics need the MATCHED pattern text, not
# just a yes/no, so the matching logic is factored out once here).
#
# Matching uses bash extglob/globbing semantics so `**` and `*` behave like shell
# patterns (e.g. `.github/workflows/**` matches `.github/workflows/ci.yml` AND a
# nested `.github/workflows/dir/x.yml`). extglob is enabled locally and the prior
# state is restored so sourcing this lib never mutates the caller's shell options.
review_path_matched_pattern() {
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
  local _pats=() _pat _matched="" _rc=1
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
      _matched="$_pat"
      _rc=0
      break
    fi
  done

  # Restore caller options (only flip back what we changed).
  [ "$_ng_was_on" -eq 1 ] || set +f
  [ "$_eg_was_on" -eq 1 ] || shopt -u extglob
  [ "$_rc" -eq 0 ] && printf '%s' "$_matched"
  return "$_rc"
}

# review_path_is_protected <path>
#
# Returns 0 (true) iff <path> matches any pattern in REVIEW_PROTECTED_PATHS, else
# 1 (false). Boolean wrapper around `review_path_matched_pattern` (see above).
review_path_is_protected() {
  review_path_matched_pattern "$1" >/dev/null
}

# (agent_token_has_workflow_scope is defined ABOVE the REVIEW_PROTECTED_PATHS
# default, since the default derivation calls it — see the top of this file.)

# review_protected_paths_prompt_rule
#
# Emits (to stdout) the per-finding protected-path classification rule for the
# review-agent prompt, built from the SAME `$REVIEW_PROTECTED_PATHS` value
# `review_path_is_protected` matches against — one source of truth (issue #301).
# Previously this rule was a hardcoded `.github/workflows/`/`CODEOWNERS` literal
# inside `build_review_prompt`, so an operator override changed the lib matcher but
# NOT what the agent was told.
#
# The output is captured via `$(...)` into the wrapper's `cat <<EOF` prompt heredoc,
# so it is the FINAL literal text (markdown backticks etc. are emitted as-is).
#
# When the protected list is empty (operator set `REVIEW_PROTECTED_PATHS=""` to
# disable protection) the rule advertises that there are NO protected paths, so the
# agent classifies every finding dev-actionable — matching the now-empty lib matcher.
review_protected_paths_prompt_rule() {
  local _pp="${REVIEW_PROTECTED_PATHS-}"
  # Trim to detect a list that is empty or whitespace-only.
  local _trimmed="${_pp#"${_pp%%[![:space:]]*}"}"
  _trimmed="${_trimmed%"${_trimmed##*[![:space:]]}"}"
  if [ -z "$_trimmed" ]; then
    cat <<'NO_PROTECTED'
- Apply this rule:
  - This project defines NO protected paths (the operator set
    `REVIEW_PROTECTED_PATHS=""`), so classify EVERY blocking finding
    `actionable_by_dev_agent: true`, `recommended_next_owner: "dev_agent"`.
NO_PROTECTED
    return 0
  fi
  # Non-empty: advertise the exact protected glob list the lib matcher uses.
  # INV-134 (#488) D2: whether the dev agent's token has the `workflows` scope
  # in THIS configuration is resolved from the SAME capability check D1's
  # default derivation uses — never a hardcoded "it does by default" claim, so
  # the prompt cannot assert a scope gap the running configuration disproves.
  local _wf_has_scope="false"
  [ "${GH_AUTH_MODE:-}" = "app" ] && agent_token_has_workflow_scope && _wf_has_scope="true"
  cat <<PROTECTED
- Apply this rule:
  - If the finding's \`file\` matches a PROTECTED-PATH pattern — the
    space-separated glob list \`${_pp}\` (the same patterns the wrapper matches
    against; \`**\`/\`*\` cross \`/\`):
    set \`actionable_by_dev_agent: false\`, \`requires_human: true\`,
    \`recommended_next_owner: "maintainer"\`. Additionally set
    \`requires_privileged_token: true\` ONLY for a \`.github/workflows/\` edit —
    in THIS configuration the dev agent's token \`workflows\` scope is
    \`${_wf_has_scope}\` (from \`GH_AUTH_MODE\` + \`AGENT_TOKEN_PERMISSIONS\`), so
    set \`requires_privileged_token: true\` iff that value is \`false\`.
  - Otherwise: \`actionable_by_dev_agent: true\`,
    \`recommended_next_owner: "dev_agent"\`.
PROTECTED
}

# review_classify_artifact_dev_actionable <canonical-json>
#
# The aggregate routing signal (§3.4): echoes `true` or `false`.
#
#   true  iff ≥1 blocking finding has EFFECTIVE `actionable_by_dev_agent=true`
#         (the aggregate-OR — if ANY blocking finding the dev agent CAN fix exists,
#         a dev-resume is still worthwhile).
#   false iff there is ≥1 blocking finding AND EVERY blocking finding has effective
#         `actionable_by_dev_agent=false` (no dev-resume can make progress).
#
# EFFECTIVE actionability is the wrapper's AUTHORITATIVE derivation (INV-92,
# invariants.md:4578 — "re-validated by the wrapper from the schema-checked
# artifact … so a buggy agent can't forge `dev-actionable=true` on a protected-path
# finding"). For each blocking finding it is `false` when EITHER:
#   - the finding's `file` matches REVIEW_PROTECTED_PATHS (`review_path_is_protected`
#     — the deterministic policy surface), regardless of what the agent set; OR
#   - the agent explicitly set `actionable_by_dev_agent:false`.
# Otherwise effective actionability is `true` (an absent field on a NON-protected
# path ⇒ true — the zero-regression legacy default). The protected-path check is the
# load-bearing override: it makes a `.github/workflows/**` / CODEOWNERS finding
# non-actionable even when the agent OMITS the flag or (mistakenly/maliciously) sets
# it `true`, closing the forge the dispatcher would otherwise loop on (PR #300 [P1]).
# The override only ever flips protected→false; it NEVER promotes an agent-asserted
# `false` to `true`, so an honest agent that marks a non-protected finding
# non-actionable is still respected.
#
# With NO blocking findings at all the result is `true` (fail-open — a PASS or an
# empty list never diverts routing). A non-JSON / no-jq input also yields `true`
# (fail-open — never invent a non-actionable signal from a parse failure).
review_classify_artifact_dev_actionable() {
  local _json="$1"
  command -v jq >/dev/null 2>&1 || { printf 'true\n'; return 0; }

  # Emit one TAB-separated record per blocking finding:
  #   <field-effective-actionable>\t<file>
  # where <field-effective-actionable> is the agent-supplied field collapsed to the
  # legacy default (absent ⇒ true) — `false` only when the agent EXPLICITLY set
  # false. The protected-path override is applied below in bash (jq cannot run
  # `review_path_is_protected`, which uses the conf-overridable bash glob list).
  # `@tsv` keeps a NUL-free, newline-delimited stream; `// ""` guards a fileless
  # finding. On any jq failure the whole pipeline yields empty → fail-open `true`.
  local _records
  _records="$(jq -r '
    (.blockingFindings // [])[]
    | [ (if .actionable_by_dev_agent == false then "false" else "true" end),
        (.file // "") ]
    | @tsv' <<<"$_json" 2>/dev/null)" || { printf 'true\n'; return 0; }

  # No blocking findings → fail-open true (never diverts routing).
  [ -n "$_records" ] || { printf 'true\n'; return 0; }

  local _field _file _any_actionable=1
  while IFS=$'\t' read -r _field _file; do
    [ -n "$_field" ] || continue
    # AUTHORITATIVE override: a protected path is non-actionable regardless of the
    # agent's self-reported field. Otherwise honor the (legacy-defaulted) field.
    if review_path_is_protected "$_file"; then
      :   # effective actionable = false; contributes nothing to the OR
    elif [ "$_field" = "true" ]; then
      _any_actionable=0
      break   # one effectively-actionable finding is enough for the OR
    fi
  done <<<"$_records"

  if [ "$_any_actionable" -eq 0 ]; then printf 'true\n'; else printf 'false\n'; fi
}

# review_classify_artifact_matched_patterns <canonical-json>
#
# INV-134 (#488) D4: echoes the sorted, unique, newline-separated
# REVIEW_PROTECTED_PATHS pattern(s) matched by ANY blocking finding's `file` in
# the artifact — the evidence the stall-notice diagnostics need to name WHICH
# pattern forced a finding non-actionable (the dispatcher only ever sees the
# aggregate `dev-actionable` bit, never the per-finding path). Echoes nothing
# (empty string) when no blocking finding matches a protected pattern, the
# input is non-JSON, or jq is unavailable — fail-empty, mirroring
# `review_classify_artifact_dev_actionable`'s own fail-open posture (a
# diagnostics gap is never worse than the aggregate signal it annotates).
review_classify_artifact_matched_patterns() {
  local _json="$1"
  command -v jq >/dev/null 2>&1 || return 0

  local _files
  _files="$(jq -r '(.blockingFindings // [])[] | (.file // "")' <<<"$_json" 2>/dev/null)" || return 0
  [ -n "$_files" ] || return 0

  local _file _pat _pats=()
  while IFS= read -r _file; do
    [ -n "$_file" ] || continue
    _pat="$(review_path_matched_pattern "$_file")" || continue
    _pats+=("$_pat")
  done <<<"$_files"

  [ "${#_pats[@]}" -gt 0 ] || return 0
  printf '%s\n' "${_pats[@]}" | sort -u
}
