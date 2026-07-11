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
# CONTRACT (provider-spec.md §3.2, the authoritative spec — the §3.2 table is
# normative; this header's verb list is a convenience index, not a second
# source of truth):
#   CODE_HOST ∈ { github (default), gitlab }  (spec §2)
#   20 CHP verbs (19 §3.2 table rows — one row names both chp_review_threads
#   and chp_resolve_thread), each forwarding to chp_${CODE_HOST}_<verb> "$@":
#     chp_find_pr_for_issue chp_ci_status chp_mergeable chp_create_pr
#     chp_approve chp_request_changes chp_merge chp_review_threads
#     chp_resolve_thread chp_trigger_bot chp_close_keyword
#     chp_reply_review_comment chp_pr_view chp_pr_list chp_pr_comment
#     chp_list_inline_comments chp_count_reviews_by_login chp_commit_file
#     chp_pr_diffstat chp_caps
#   chp_has_leaf is a caller-side guard helper, NOT a verb (no `.caps` entry,
#   never forwards "$@" to a leaf) — see spec §3.2 "What this section owns".
#
# SCOPE (#280 — historical; the leaf migrations below post-date this file's
# original PR): #280 shipped ONLY the dispatch shims + the .caps reader for
# the original 12-verb set, with NO verb leaf migrated (empty scaffolds in
# providers/chp-github.sh). Every leaf named above has since been migrated by
# its own PR (#282 PR-lifecycle, #282 r8/#329 general read+write primitives,
# #328/#327/#324/#330 focused verbs) — see the §3.2 "Implementation status"
# note in provider-spec.md for the per-verb migration ledger. chp_caps remains
# the only shim whose body is a reader rather than a leaf-forward: it reads
# the declarative .caps manifest ([INV-88]).
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

# Source the enabled CHP provider's leaf-impl file from the skill tree. For
# github this is providers/chp-github.sh, fully leaf-populated since #282/
# #296-second-tier (see the SCOPE note above). Guarded so a missing provider
# file degrades gracefully rather than crashing under set -euo pipefail.
if [[ -f "${_LIB_CHP_PROVIDERS_DIR}/chp-${CODE_HOST}.sh" ]]; then
  # shellcheck source=/dev/null
  source "${_LIB_CHP_PROVIDERS_DIR}/chp-${CODE_HOST}.sh"
fi

# ---------------------------------------------------------------------------
# .caps reader — parsed key=value, NEVER sourced ([INV-88], spec §4).
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
# chp_find_pr_for_issue ISSUE FIELDS-CSV — spec §3.2 [M1], W1c1 (#397).
# ABSTRACT: positional args, returns a NORMALIZED JSON array of open PR
# candidates projected to (FIELDS ∪ {number, closingIssueNumbers, headRefName})
# with body pinned to a string (null → "") and closingIssueNumbers as an array
# of ints. The [INV-86] close-linkage / branch-name resolution stays caller-
# side (lib-pr-linkage.sh) as pure jq over the normalized array. Fail-CLOSED
# on transport error or page-cap hit (§3.5 COMPLETE-set contract).
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

# General read+write primitives (`chp_pr_view`/`chp_pr_list` #282 review round 8;
# `chp_pr_comment` #329, [INV-102]). These are NOT among the 11 named PR-lifecycle verbs above
# — they are the provider-neutral `gh pr view` / `gh pr list` read leaves AND the
# `gh pr comment` write leaf that the caller layer's INCIDENTAL PR reads/writes
# route through so the caller layer carries ZERO raw `gh pr` (the [INV-87] final-AC
# grep). The caller keeps its own `--json`/`-q` projection (reads) or `--body` tail
# + redirect/capture framing (the comment write) — forwarded via "$@",
# byte-identical — as with every other CHP verb; only the innermost primitive moves
# behind the seam.
#   chp_pr_view PR  [--json … -q …]     → gh pr view PR  --repo $REPO …
#   chp_pr_list STATE FIELDS-CSV        → normalized JSON array (§3.2 W1c1, #397)
#   chp_pr_comment PR [--body … | extra args] → gh pr comment PR --repo $REPO …
# (chp_pr_list, since W1c1/#397, is an ABSTRACT positional contract: STATE
# (open|closed|merged|all) + a normalized field-CSV, returning a COMPLETE
# JSON array with body normalized to a string and closingIssueNumbers as an
# int array — no gh flags cross the seam. It is DISTINCT from
# chp_find_pr_for_issue (the [INV-86] close-linkage resolver, which forces a
# union with the resolution keys and takes an issue-narrowing hint).
# chp_pr_comment is the PR-comment write the two HOT review files use for
# auto-merge markers / E2E reports / the [INV-79] brokered report — distinct
# from itp_post_comment, the ISSUE-level marker choke-point: same GitHub
# endpoint, different seam owner for a split-backend topology.)
#
# Self-guarding dispatch (#282 review round 9 [P1]): unlike the 11 lifecycle
# verbs (which callers guard via `chp_has_leaf` + a meaningful fallback), the
# incidental read/write callers dispatch these UNGUARDED. So if the enabled
# provider omits the leaf (the all-empty degraded fixture; any future non-GitHub
# provider that hasn't yet implemented its leaf), a blind `chp_${CODE_HOST}_pr_view`
# would `command not found` → abort the wrapper at its FIRST PR read/write. Instead
# the shim checks the leaf and, when absent, emits a WARN and returns 1 — a clean
# non-zero that every incidental call site already degrades on (each is a
# `$(… 2>/dev/null || echo/true)`, `if ! …`, `… || return 1`, or a comment-write
# `… 2>/dev/null || true`), so the wrapper fails-soft (empty read / unposted
# comment) instead of aborting, and the misconfiguration is loud. A real backend
# MUST implement these (they are core, non-capability-gated PR I/O).
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
chp_pr_comment() {
  if ! declare -F "chp_${CODE_HOST}_pr_comment" >/dev/null 2>&1; then
    echo "WARN: [INV-87] CODE_HOST='${CODE_HOST}' provider defines no chp_${CODE_HOST}_pr_comment leaf — PR comment unavailable (a non-GitHub CHP provider MUST implement it)." >&2
    return 1
  fi
  chp_${CODE_HOST}_pr_comment "$@"
}

# chp_pr_diffstat PR DIMENSIONS-CSV — diff-size read primitive (#452).
#
# DIMENSIONS-CSV ∈ any non-empty subset of {files,lines} (comma-separated,
# e.g. "files", "lines", "files,lines"). Returns a SINGLE normalized JSON
# object carrying ONLY the requested dimension key(s):
#   files → {"changed_files": <int>}
#   lines → {"changed_lines": <int>}
# (both requested → both keys). A dimension is OMITTED (never fabricated as
# 0/null) when the provider could not determine it — the PR-diff-soft-cap
# caller (lib-review-diffcap.sh) treats a missing key as a read failure for
# that dimension only (fail-open: over_reach=false for it, never a fabricated
# warning). rc≠0 on a hard transport/auth failure with NO partial output.
#
# NOT one of the 11 named PR-lifecycle verbs — a general READ primitive
# alongside chp_pr_view/chp_pr_list, added so the PR-diff-soft-cap caller in
# autonomous-review.sh carries ZERO raw `gh pr view --json
# additions,deletions,changedFiles` ([INV-91] cutover guard). Provider cost
# differs, not capability: the GitHub leaf answers BOTH dimensions from ONE
# `gh pr view` call regardless of which is requested (no extra API cost either
# way); the GitLab leaf answers `files` from the already-fetched base MR view
# (`changes_count`) but `lines` requires a SEPARATE GraphQL `diffStatsSummary`
# call — issued ONLY when `lines` is actually in DIMENSIONS-CSV (pay-only-if-
# requested). Self-guarding shim (mirrors chp_pr_view/chp_pr_list): a
# leaf-absent provider degrades to WARN + rc 1 rather than a `set -e` abort.
chp_pr_diffstat() {
  if ! declare -F "chp_${CODE_HOST}_pr_diffstat" >/dev/null 2>&1; then
    echo "WARN: [INV-87] CODE_HOST='${CODE_HOST}' provider defines no chp_${CODE_HOST}_pr_diffstat leaf — PR diff-stat read unavailable (a non-GitHub CHP provider MUST implement it)." >&2
    return 1
  fi
  chp_${CODE_HOST}_pr_diffstat "$@"
}

# chp_list_inline_comments PR [extra gh args…] — PR inline (file-anchored)
# review-comment read (#296 second-tier, #328, [INV-95]). The dev-resume prompt
# builder's PR_REVIEW_COMMENTS read (autonomous-dev.sh) routes through this so the
# caller layer carries ZERO raw `gh api …/pulls/N/comments`. Caller keeps its own
# `--jq` formatter (forwarded via "$@", byte-identical, #281 jq-stays-caller); only
# the innermost `gh api` primitive moves behind the seam. DISTINCT shape from
# chp_review_threads (GraphQL thread tree) / itp_list_comments (issue-level) — the
# inline `.path`/`.line`/`.original_line` fields are CHP-owned (§3.2).
#
# Self-guarding (the #282 convention, mirroring chp_pr_view/chp_pr_list): the
# :1086 caller invokes this UNGUARDED inside a `$(… 2>/dev/null || true)`, so when
# the enabled provider omits the leaf the shim emits a WARN and returns 1 (a clean
# non-zero the `|| true` site degrades to an empty PR_REVIEW_COMMENTS on) rather
# than dispatching to an undefined leaf and aborting under `set -e`. The bare
# `${CODE_HOST}` expansion is IDENTICAL to the leaf dispatch (safe under `set -u` —
# CODE_HOST is defaulted at source time); a `:-github` guard would diverge from the
# bare shim when CODE_HOST is empty (the #323/#324 bare-guard lesson).
chp_list_inline_comments() {
  if ! declare -F "chp_${CODE_HOST}_list_inline_comments" >/dev/null 2>&1; then
    echo "WARN: [INV-95] CODE_HOST='${CODE_HOST}' provider defines no chp_${CODE_HOST}_list_inline_comments leaf — PR inline-comment read unavailable." >&2
    return 1
  fi
  chp_${CODE_HOST}_list_inline_comments "$@"
}

# chp_count_reviews_by_login REPO PR LOGIN — focused verb behind the [INV-79]
# wrapper bot-review hard-gate ([INV-94], #324). Forwards "$@" to the leaf via the
# BARE chp_${CODE_HOST}_ prefix — byte-for-byte the named-verb shim shape — so the
# caller's leaf-guard (declare -F chp_${CODE_HOST}_count_reviews_by_login) is the
# EXACT same expression the shim dispatches (a `:-github` guard against this bare
# shim would diverge when CODE_HOST is unset → the shim calls chp__… → abort under
# set -e). The leaf returns the summed integer; the caller keeps the `^[0-9]+$`
# validation + the `-eq 0` MISSING decision (lib-review-bots.sh::missing_bot_reviews).
chp_count_reviews_by_login() { chp_${CODE_HOST}_count_reviews_by_login "$@"; }

# chp_commit_file REPO BRANCH FILE_PATH CONTENT_BASE64 MESSAGE — whole-op file
# commit (#330, [INV-99]). The standalone upload-screenshot.sh review util's ONE
# code-host op (commit a PNG onto an orphan `screenshots` branch + echo the
# committed SHA) routes through this verb. SELF-GUARDING like chp_pr_view /
# chp_pr_list (NOT the lifecycle-verb chp_has_leaf posture): upload-screenshot.sh
# is standalone and exits non-zero on failure, invoking the verb UNGUARDED, so
# when the enabled provider omits the leaf (the all-empty degraded fixture; any
# non-GitHub backend without a file-commit leaf) the shim emits a WARN and returns
# 1 — a clean non-zero the caller's `chp_commit_file … || fail` already degrades
# on — rather than dispatching to an undefined leaf and command-not-found-aborting
# under set -e. A real backend MUST implement this (a core write leaf, not
# capability-gated). The GitHub leaf is the whole 8-call git-Data-API op; a GitLab
# backend would be one Files API call.
chp_commit_file() {
  if ! declare -F "chp_${CODE_HOST}_commit_file" >/dev/null 2>&1; then
    echo "WARN: [INV-99] CODE_HOST='${CODE_HOST}' provider defines no chp_${CODE_HOST}_commit_file leaf — file commit unavailable." >&2
    return 1
  fi
  chp_${CODE_HOST}_commit_file "$@"
}

# chp_file_url REPO BRANCH FILE_PATH — render the browser blob URL (#419 R11).
#
# Pure string render, NO HTTP — parallels chp_close_keyword's render pattern.
# NEW verb — sibling of chp_commit_file (the write side) that lets the caller
# echo a link to the just-committed file without dispatching a github-only raw
# `/blob/` URL. GitHub renders `https://github.com/${REPO}/blob/…` (byte-identical
# to the pre-#419 upload-screenshot.sh:114 hardcode); GitLab renders
# `https://${GITLAB_HOST}/<decoded-project-path>/-/blob/…` (browser URLs use
# the RAW slash-bearing project path, NOT the URL-encoded GITLAB_PROJECT).
#
# SELF-GUARDING like chp_commit_file / chp_pr_view: upload-screenshot.sh is
# standalone and exits non-zero on failure, invoking the verb UNGUARDED — so a
# leaf-absent enabled provider yields a clean WARN + rc 1 the caller's
# `chp_file_url … || fail` degrades on, rather than dispatching to an undefined
# leaf and command-not-found-aborting under set -e.
chp_file_url() {
  if ! declare -F "chp_${CODE_HOST}_file_url" >/dev/null 2>&1; then
    echo "WARN: [INV-99] CODE_HOST='${CODE_HOST}' provider defines no chp_${CODE_HOST}_file_url leaf — file-URL render unavailable." >&2
    return 1
  fi
  chp_${CODE_HOST}_file_url "$@"
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
