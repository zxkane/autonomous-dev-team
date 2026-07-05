#!/bin/bash
# lib-provider-prompts.sh — provider-aware agent-prompt fragment helper (#421,
# #414 W-F — the last phase-3 slice).
#
# The two wrappers (autonomous-dev.sh, autonomous-review.sh) and
# lib-review-bots.sh embed 20 pieces of agent-facing prompt PROSE that mention
# `gh` — heredoc text telling the agent which command to run or what to
# expect. That prose is decoupled from the pipeline's actual transport
# ([INV-91] governs the EXECUTABLE call sites; this lib governs what we TELL
# the agent). Pre-#421 the prose was hardcoded GitHub English even when
# CODE_HOST/ISSUE_PROVIDER pointed at GitLab — a gitlab-lane agent was told to
# run `gh pr view ...` against a project where `gh` cannot see the GitLab MR.
#
# provider_prompt_fragment <key> [args...]
#   Renders fragment <key> for the CURRENT backend — CODE_HOST for
#   code-host-facing keys (PR/merge/CI prose), ISSUE_PROVIDER for
#   issue-tracker-facing keys (issue-body/issue-comment prose). Both default
#   to "github" (provider-spec.md §2). Args are interpolated via printf(1)
#   into the per-provider template; the caller passes exactly the args the
#   key's template expects (FRAGMENT_ARGC pins the count so a caller/template
#   mismatch fails LOUD here instead of silently rendering a truncated
#   fragment).
#
# Fragment files (providers/prompts-<provider>.sh) declare TWO parallel
# associative arrays keyed by fragment name:
#   _PP_<PROVIDER>_FRAGMENT[<key>]="printf template, %s placeholders"
#   _PP_<PROVIDER>_ARGC[<key>]=<N>          (N = number of %s in the template)
# An unknown <key> OR unknown provider is a bug (a missing fragment must be
# fixed, not degraded) — this helper fails LOUD, rc=1, message on stderr.
#
# Two backend axes deliberately share ONE helper + ONE key namespace: each
# key documents (in FRAGMENT_AXIS below) whether it renders against CODE_HOST
# or ISSUE_PROVIDER — callers never choose the axis themselves, so a key
# can't accidentally render against the wrong provider var if CODE_HOST and
# ISSUE_PROVIDER diverge (e.g. an asana-tracker + gitlab-host topology).
#
# PRECONDITION: sourced by the two wrappers/lib-review-bots.sh from the REAL
# skill tree (readlink -f of BASH_SOURCE), mirroring lib-code-host.sh /
# lib-issue-provider.sh. `$CODE_HOST` / `$ISSUE_PROVIDER` are in scope from
# the caller's environment (both default to "github" — provider-spec.md §2).

SCRIPT_DIR_PP="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PROVIDERS_DIR_PP="$SCRIPT_DIR_PP/providers"

# FRAGMENT_AXIS[<key>] = "code_host" | "issue_provider" — which env var
# selects the provider for this key. Declared here (not per-provider file) so
# the axis choice is a single source of truth independent of which provider
# fragment files happen to be sourced. One entry per R2-classified (a) site
# (20 sites: 9 autonomous-dev.sh, 10 autonomous-review.sh, 1 lib-review-bots.sh;
# 21 keys — lib-review-bots.sh's repeated "check bot review count" site needs
# both a fenced-code-block rendering and a bare (no-fence, loop-embedded)
# rendering, so it gets two keys sharing one underlying fact).
declare -gA FRAGMENT_AXIS=(
  [dev.read_issue_body]=issue_provider
  [dev.pr_create_write_to_file]=code_host
  [dev.pr_create_wrapper_runs]=code_host
  [dev.fastpath_interrupted]=code_host
  [dev.pr_create_cannot_run]=code_host
  [dev.merge_failed_likely_reason]=code_host
  [dev.pr_create_direct_step]=code_host
  [dev.pr_create_do_not_run_instead]=code_host
  [dev.merge_failed_rebase_parenthetical]=code_host
  [review.check_mergeable]=code_host
  [review.codex_diff_step]=code_host
  [review.check_ci_checks]=code_host
  [review.verdict_no_bare_issue_comment]=issue_provider
  [review.codex_gh_pr_diff_reconstruct]=code_host
  [review.gh_pr_view_checks_parenthetical]=code_host
  [review.codex_do_not_hand_roll]=issue_provider
  [review.requirement_drift_gh_issue_view]=issue_provider
  [review.watch_ci_checks]=code_host
  [review.e2e_fetch_comment]=code_host
  [bots.review_count_check]=code_host
  [bots.review_count_check_bare]=code_host
)

# Loaded-fragment-file guard, per provider — cheap insurance against
# re-sourcing the same fragment file twice in one process (mirrors
# lib-code-host.sh's guard idiom).
declare -gA _PP_LOADED=()

# _pp_load_provider <provider> — source providers/prompts-<provider>.sh once.
# Fails LOUD (rc=1, stderr) if the file is missing — an unknown provider is a
# bug (R1: "Unknown key OR unknown provider → fail LOUD rc≠0").
_pp_load_provider() {
  local provider="$1" file
  [[ -n "${_PP_LOADED[$provider]:-}" ]] && return 0
  file="$PROVIDERS_DIR_PP/prompts-${provider}.sh"
  if [[ ! -f "$file" ]]; then
    echo "provider_prompt_fragment: unknown provider '${provider}' — no fragment file at providers/prompts-${provider}.sh" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$file"
  _PP_LOADED[$provider]=1
}

# provider_prompt_fragment <key> [args...]
provider_prompt_fragment() {
  local key="$1"; shift || true
  local axis="${FRAGMENT_AXIS[$key]:-}"
  if [[ -z "$axis" ]]; then
    echo "provider_prompt_fragment: unknown fragment key '${key}'" >&2
    return 1
  fi
  local provider
  if [[ "$axis" == "code_host" ]]; then
    provider="${CODE_HOST:-github}"
  else
    provider="${ISSUE_PROVIDER:-github}"
  fi
  _pp_load_provider "$provider" || return 1

  local provider_upper="${provider^^}"
  local -n _tpl_map="_PP_${provider_upper}_FRAGMENT"
  local -n _argc_map="_PP_${provider_upper}_ARGC"
  local tpl="${_tpl_map[$key]:-}"
  if [[ -z "$tpl" ]]; then
    echo "provider_prompt_fragment: key '${key}' has no fragment defined for provider '${provider}' (providers/prompts-${provider}.sh)" >&2
    return 1
  fi
  local want_argc="${_argc_map[$key]:-0}"
  local got_argc="$#"
  if [[ "$got_argc" -ne "$want_argc" ]]; then
    echo "provider_prompt_fragment: key '${key}' (provider '${provider}') expects ${want_argc} arg(s), got ${got_argc}" >&2
    return 1
  fi
  # printf -- "${tpl}\n" would treat a template ending in a literal
  # backslash (several github fragments end a markdown line-continuation
  # `\`) as an escape prefix for the trailing \n, printing a literal `\n`
  # instead of a newline. Render the template's OWN %s substitutions first,
  # then append the newline via a separate `%s\n` call so the appended
  # newline is never re-interpreted against the template's last character.
  local rendered
  rendered="$(printf -- "$tpl" "$@")"
  printf '%s\n' "$rendered"
}
