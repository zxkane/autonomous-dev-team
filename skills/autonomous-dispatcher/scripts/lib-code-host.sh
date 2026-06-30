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

# chp_reply_review_comment PR COMMENT_ID BODY — reply to one PR review comment
# ([INV-96], #327). The program's LAST raw `gh api …pulls/<n>/comments -X POST …
# in_reply_to=…` site (reply-to-comments.sh, an autonomous-common util) routes
# through this verb. Forwards "$@" to the leaf via the same one-line shim shape as
# the 11 named lifecycle verbs above. The owner/repo arg split + the COMMENT_ID
# numeric sanitization stay caller-side (reply-to-comments.sh); the GitHub leaf
# uses the global $REPO slug the caller composes (REPO="$OWNER/$REPO"), so the
# endpoint path repos/$REPO/pulls/$PR/comments is byte-identical to today's. NOT
# capability-gated (a core code-host write — every code host with PR review
# comments has a reply endpoint), so it carries no `.caps` key.
chp_reply_review_comment() { chp_${CODE_HOST}_reply_review_comment "$@"; }

# General read primitives (#282 review round 8). These are NOT among the 11 named
# PR-lifecycle verbs above — they are the provider-neutral `gh pr view` / `gh pr
# list` read leaves that the caller layer's INCIDENTAL reads route through so the
# caller layer carries ZERO raw `gh pr` (the [INV-87] final-AC grep). The caller
# keeps its own `--json`/`-q` projection (forwarded via "$@", byte-identical), as
# with every other CHP verb; only the innermost primitive moves behind the seam.
#   chp_pr_view PR  [--json … -q …]     → gh pr view PR  --repo $REPO …
#   chp_pr_list     [--state … --json … -q …] → gh pr list --repo $REPO …
# (chp_pr_list is the generalized issue-keyed/body-mention list the dispatcher's
# pre-#277 existence lookups use — distinct from chp_find_pr_for_issue, which is
# the [INV-86] close-linkage resolver.)
#
# Self-guarding dispatch (#282 review round 9 [P1]): unlike the 11 lifecycle
# verbs (which callers guard via `chp_has_leaf` + a meaningful fallback), the
# incidental-read callers dispatch these UNGUARDED. So if the enabled provider
# omits the leaf (the all-empty degraded fixture; any future non-GitHub provider
# that hasn't yet implemented its read leaf), a blind `chp_${CODE_HOST}_pr_view`
# would `command not found` → abort the wrapper at its FIRST PR read. Instead the
# shim checks the leaf and, when absent, emits a WARN and returns 1 — a clean
# non-zero that every incidental-read call site already degrades on (each is a
# `$(… 2>/dev/null || echo/true)`, `if ! …`, or `… || return 1`), so the wrapper
# fails-soft (empty read) instead of aborting, and the misconfiguration is loud.
# A real backend MUST implement these (they are core, non-capability-gated reads).
chp_pr_view() {
  if ! declare -F "chp_${CODE_HOST}_pr_view" >/dev/null 2>&1; then
    echo "WARN: [INV-87] CODE_HOST='${CODE_HOST}' provider defines no chp_${CODE_HOST}_pr_view leaf — PR read unavailable (a non-GitHub CHP provider MUST implement it)." >&2
    return 1
  fi
  chp_${CODE_HOST}_pr_view "$@"
}
chp_pr_list() {
  if ! declare -F "chp_${CODE_HOST}_pr_list" >/dev/null 2>&1; then
    echo "WARN: [INV-87] CODE_HOST='${CODE_HOST}' provider defines no chp_${CODE_HOST}_pr_list leaf — PR list read unavailable (a non-GitHub CHP provider MUST implement it)." >&2
    return 1
  fi
  chp_${CODE_HOST}_pr_list "$@"
}

# chp_has_leaf <verb> — returns 0 iff the ENABLED provider actually defines the
# leaf `chp_${CODE_HOST}_<verb>` (e.g. `chp_has_leaf close_keyword`).
#
# A caller MUST NOT guard a verb invocation with `declare -F chp_<verb>`: the
# thin shim above is ALWAYS defined once this lib is sourced, so that test is
# always true even on a backend whose provider file omits the leaf — the shim
# then dispatches to an undefined `chp_${CODE_HOST}_<verb>` and aborts the caller
# under `set -e` (#282 review round 4 [P1]: the degraded fake CHP fixture has
# exactly that shape — shim present, leaf absent). Guard on the LEAF instead:
#   chp_has_leaf close_keyword && kw="$(chp_close_keyword "$n")" || kw="<fallback>"
chp_has_leaf() {
  declare -F "chp_${CODE_HOST}_$1" >/dev/null 2>&1
}

# chp_caps <key> — emit the capability map value for <key> from the enabled
# CHP provider's .caps manifest (spec §4). The only CHP shim with a real body in
# #280: it reads the declarative manifest, it does NOT forward to a provider
# function.
chp_caps() {
  _provider_read_cap "${_LIB_CHP_PROVIDERS_DIR}/chp-${CODE_HOST}.caps" "$@"
}
