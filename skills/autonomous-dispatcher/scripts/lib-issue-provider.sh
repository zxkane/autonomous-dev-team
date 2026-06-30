#!/bin/bash
# lib-issue-provider.sh — Issue-Tracker Provider (ITP) dispatch skeleton (#280).
#
# Thin verb-dispatch layer for the issue-tracker seam, mirroring lib-agent.sh's
# adapter_invoke_<cli> precedent ([INV-75], adapter-spec.md). Each ITP verb
# (spec §3.1) is a one-line shim that forwards "$@" to its provider function
# itp_${ISSUE_PROVIDER}_<verb>. The marker-parsing / retry-counting /
# verdict-routing / INV-coupled logic stays in the provider-neutral caller layer
# — only the leaf I/O moves behind a verb ([INV-87]).
#
# CONTRACT (provider-spec.md §3.1, the authoritative spec):
#   ISSUE_PROVIDER ∈ { github (default), gitlab, asana }  (spec §2)
#   14 ITP verbs, each forwarding to itp_${ISSUE_PROVIDER}_<verb> "$@":
#     itp_list_by_state itp_count_by_state itp_list_forbidden_combos
#     itp_transition_state itp_read_task itp_post_comment itp_edit_comment
#     itp_list_comments itp_resolve_dep itp_mark_checkbox itp_provision_states
#     itp_begin_tick itp_label_event_ts itp_caps
#
# SCOPE (#280): this file ships ONLY the dispatch shims + the .caps reader. NO
# verb leaf is migrated — the itp_github_<verb> bodies are EMPTY scaffolds in
# providers/itp-github.sh (leaf migration is the downstream itp-reads /
# itp-writes / itp-deps-begin-tick issues). itp_caps is the sole shim with a
# real body in this PR: it reads the declarative .caps manifest ([INV-88]).
#
# [INV-14]/[INV-65] resolution: providers/itp-${_p}.sh + the .caps manifests are
# sourced/read from the REAL skill tree via readlink -f of THIS file's own
# BASH_SOURCE — the same idiom lib-agent.sh:56-60 uses to source its adapters.
# So a consumer needs NO project-side symlink and NO install-project-hooks.sh
# re-run: `npx skills update -g` lands this lib + providers/ in the skill tree
# and the readlink -f resolution finds them (Step 1 only, per the lib-vs-entry
# rule; spec §6/§8).

_LIB_ITP_SELF="${BASH_SOURCE[0]:-$0}"
_LIB_ITP_REAL_DIR="$(cd "$(dirname "$(readlink -f "$_LIB_ITP_SELF")")" && pwd)"
# Provider-file search dir. Defaults to the skill-tree `providers/` resolved via
# readlink -f (the production path). Overridable via AUTONOMOUS_PROVIDERS_DIR so
# a NON-github backend selected through the PUBLIC seam (`ISSUE_PROVIDER=<name>`)
# resolves its `providers/itp-<name>.{sh,caps}` from an alternate dir — this is
# the hook the named degraded fake fixture provider uses to exercise the caps=0
# branches through `itp_caps`, not by reading the `.caps` file directly (#280
# review [P1]; it is the reusable provider-selection harness downstream
# caps-branch issues build on). Empty/unset → the skill-tree default.
_LIB_ITP_PROVIDERS_DIR="${AUTONOMOUS_PROVIDERS_DIR:-${_LIB_ITP_REAL_DIR}/providers}"

# Seam config: default to the GitHub reference backend (spec §2). Callers never
# read provider-scoped config directly (spec §3.4).
ISSUE_PROVIDER="${ISSUE_PROVIDER:-github}"

# Source the enabled ITP provider's leaf-impl file from the skill tree. The
# file is an EMPTY scaffold in #280 (no verb bodies yet) — sourcing it is a
# no-op now but is the hook the downstream leaf-migration issues populate.
# Guarded so a missing provider file (e.g. an as-yet-unwritten gitlab/asana
# backend) degrades to "no leaf functions defined" rather than crashing the
# dispatcher under set -euo pipefail.
if [[ -f "${_LIB_ITP_PROVIDERS_DIR}/itp-${ISSUE_PROVIDER}.sh" ]]; then
  # shellcheck source=/dev/null
  source "${_LIB_ITP_PROVIDERS_DIR}/itp-${ISSUE_PROVIDER}.sh"
fi

# ---------------------------------------------------------------------------
# .caps reader — parsed key=value, NEVER sourced ([INV-88], spec §4 / §10 Q1).
# A declarative manifest is readable under `set -euo pipefail` without the
# unguarded-source crash mode this codebase suffers from. Shared by both seams;
# guarded so sourcing both libs does not redefine it.
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
# ITP verb shims (spec §3.1). Each forwards "$@" to itp_${ISSUE_PROVIDER}_<verb>
# — byte-for-byte the lib-agent.sh:597 adapter_invoke_"$AGENT_CMD" … "$@" shape.
# ---------------------------------------------------------------------------
itp_list_by_state()        { itp_${ISSUE_PROVIDER}_list_by_state "$@"; }
itp_count_by_state()       { itp_${ISSUE_PROVIDER}_count_by_state "$@"; }
itp_list_forbidden_combos(){ itp_${ISSUE_PROVIDER}_list_forbidden_combos "$@"; }
itp_transition_state()     { itp_${ISSUE_PROVIDER}_transition_state "$@"; }
itp_read_task()            { itp_${ISSUE_PROVIDER}_read_task "$@"; }
itp_post_comment()         { itp_${ISSUE_PROVIDER}_post_comment "$@"; }
itp_edit_comment()         { itp_${ISSUE_PROVIDER}_edit_comment "$@"; }
itp_list_comments()        { itp_${ISSUE_PROVIDER}_list_comments "$@"; }
itp_resolve_dep()          { itp_${ISSUE_PROVIDER}_resolve_dep "$@"; }
itp_mark_checkbox()        { itp_${ISSUE_PROVIDER}_mark_checkbox "$@"; }
itp_provision_states()     { itp_${ISSUE_PROVIDER}_provision_states "$@"; }
itp_begin_tick()           { itp_${ISSUE_PROVIDER}_begin_tick "$@"; }
itp_label_event_ts()       { itp_${ISSUE_PROVIDER}_label_event_ts "$@"; }

# itp_caps <key> — emit the capability map value for <key> from the enabled
# ITP provider's .caps manifest (spec §4). The only ITP shim with a real body
# in #280: it reads the declarative manifest, it does NOT forward to a provider
# function. The .caps file sits beside its provider .sh in the skill tree.
itp_caps() {
  _provider_read_cap "${_LIB_ITP_PROVIDERS_DIR}/itp-${ISSUE_PROVIDER}.caps" "$@"
}
