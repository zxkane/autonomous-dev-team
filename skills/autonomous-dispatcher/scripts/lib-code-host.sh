#!/bin/bash
# lib-code-host.sh — Code-Host Provider (CHP) dispatch skeleton (#280).
#
# Thin verb-dispatch layer for the code-host seam, mirroring lib-agent.sh's
# adapter_invoke_<cli> precedent ([INV-75], adapter-spec.md). Each CHP verb
# (spec §3.2) is a one-line shim that forwards "$@" to its provider function
# chp_${CODE_HOST}_<verb>. The mergeable classifiers ([INV-44]/[INV-54]), the
# select(.body|test("#N")) filter ([M1]), and every other INV-coupled decision
# stay in the provider-neutral caller layer — only the leaf I/O moves behind a
# verb ([INV-87]).
#
# CONTRACT (provider-spec.md §3.2, the authoritative spec):
#   CODE_HOST ∈ { github (default), gitlab }  (spec §2)
#   12 CHP verbs, each forwarding to chp_${CODE_HOST}_<verb> "$@":
#     chp_find_pr_for_issue chp_ci_status chp_mergeable chp_create_pr
#     chp_approve chp_request_changes chp_merge chp_review_threads
#     chp_resolve_thread chp_trigger_bot chp_close_keyword chp_caps
#
# SCOPE (#280): this file ships ONLY the dispatch shims + the .caps reader. NO
# verb leaf is migrated — the chp_github_<verb> bodies are EMPTY scaffolds in
# providers/chp-github.sh (leaf migration is the downstream chp-pr-lifecycle
# issue). chp_caps is the sole shim with a real body in this PR: it reads the
# declarative .caps manifest ([INV-88]).
#
# [INV-14]/[INV-65] resolution: providers/chp-${_p}.sh + the .caps manifests are
# sourced/read from the REAL skill tree via readlink -f of THIS file's own
# BASH_SOURCE — the same idiom lib-agent.sh:56-60 uses to source its adapters.
# So a consumer needs NO project-side symlink and NO install-project-hooks.sh
# re-run (Step 1 only, per the lib-vs-entry rule; spec §6/§8).

_LIB_CHP_SELF="${BASH_SOURCE[0]:-$0}"
_LIB_CHP_REAL_DIR="$(cd "$(dirname "$(readlink -f "$_LIB_CHP_SELF")")" && pwd)"
# Provider-file search dir. Defaults to the skill-tree `providers/` resolved via
# readlink -f (the production path). Overridable via AUTONOMOUS_PROVIDERS_DIR so
# a NON-github backend selected through the PUBLIC seam (`CODE_HOST=<name>`)
# resolves its `providers/chp-<name>.{sh,caps}` from an alternate dir — this is
# the hook the named degraded fake fixture provider uses to exercise the caps=0
# branches through `chp_caps`, not by reading the `.caps` file directly (#280
# review [P1]). Empty/unset → the skill-tree default. Shared override key with
# lib-issue-provider.sh (a topology may swap both seams to the same fixture dir).
_LIB_CHP_PROVIDERS_DIR="${AUTONOMOUS_PROVIDERS_DIR:-${_LIB_CHP_REAL_DIR}/providers}"

# Seam config: default to the GitHub reference backend (spec §2).
CODE_HOST="${CODE_HOST:-github}"

# Source the enabled CHP provider's leaf-impl file from the skill tree (EMPTY
# scaffold in #280). Guarded so a missing provider file degrades gracefully
# rather than crashing under set -euo pipefail.
if [[ -f "${_LIB_CHP_PROVIDERS_DIR}/chp-${CODE_HOST}.sh" ]]; then
  # shellcheck source=/dev/null
  source "${_LIB_CHP_PROVIDERS_DIR}/chp-${CODE_HOST}.sh"
fi

# ---------------------------------------------------------------------------
# .caps reader — parsed key=value, NEVER sourced ([INV-88], spec §4 / §10 Q1).
# Shared with lib-issue-provider.sh; guarded so sourcing both libs (in either
# order) does not redefine it, while keeping each lib independently sourceable.
# ---------------------------------------------------------------------------
if ! declare -F _provider_read_cap >/dev/null 2>&1; then
  # _provider_read_cap <caps-file> <key> → prints the value, rc 0;
  #   unknown key / missing file → no output, rc 1.
  # Strips `#` comments (inline + full-line) and blank lines; matches the FIRST
  # `key=value` whose key equals <key>.
  _provider_read_cap() {
    local file="$1" key="$2" line k v
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"                              # strip comment
      line="${line#"${line%%[![:space:]]*}"}"         # ltrim
      line="${line%"${line##*[![:space:]]}"}"         # rtrim
      [[ -z "$line" ]] && continue                    # skip blank
      [[ "$line" != *=* ]] && continue                # skip non-kv
      k="${line%%=*}"
      v="${line#*=}"
      k="${k%"${k##*[![:space:]]}"}"                  # rtrim key
      v="${v#"${v%%[![:space:]]*}"}"                  # ltrim value
      if [[ "$k" == "$key" ]]; then printf '%s\n' "$v"; return 0; fi
    done < "$file"
    return 1
  }
fi

# ---------------------------------------------------------------------------
# CHP verb shims (spec §3.2). Each forwards "$@" to chp_${CODE_HOST}_<verb> —
# byte-for-byte the lib-agent.sh:597 adapter_invoke_"$AGENT_CMD" … "$@" shape.
# ---------------------------------------------------------------------------
chp_find_pr_for_issue() { chp_${CODE_HOST}_find_pr_for_issue "$@"; }
chp_ci_status()         { chp_${CODE_HOST}_ci_status "$@"; }
chp_mergeable()         { chp_${CODE_HOST}_mergeable "$@"; }
chp_create_pr()         { chp_${CODE_HOST}_create_pr "$@"; }
chp_approve()           { chp_${CODE_HOST}_approve "$@"; }
chp_request_changes()   { chp_${CODE_HOST}_request_changes "$@"; }
chp_merge()             { chp_${CODE_HOST}_merge "$@"; }
chp_review_threads()    { chp_${CODE_HOST}_review_threads "$@"; }
chp_resolve_thread()    { chp_${CODE_HOST}_resolve_thread "$@"; }
chp_trigger_bot()       { chp_${CODE_HOST}_trigger_bot "$@"; }
chp_close_keyword()     { chp_${CODE_HOST}_close_keyword "$@"; }

# chp_caps <key> — emit the capability map value for <key> from the enabled
# CHP provider's .caps manifest (spec §4). The only CHP shim with a real body in
# #280: it reads the declarative manifest, it does NOT forward to a provider
# function.
chp_caps() {
  _provider_read_cap "${_LIB_CHP_PROVIDERS_DIR}/chp-${CODE_HOST}.caps" "$@"
}
