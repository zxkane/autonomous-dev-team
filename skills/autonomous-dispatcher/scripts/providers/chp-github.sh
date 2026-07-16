#!/bin/bash
# providers/chp-github.sh — GitHub Code-Host Provider (CHP) reference impl.
#
# Establishes the provider-prefix convention (#280) and migrates the CHP
# PR-lifecycle leaves (#282). Each CHP verb's GitHub leaf is a function named
# chp_github_<verb>; lib-code-host.sh's `chp_<verb>` shim forwards "$@" to it
# when CODE_HOST=github (the default). The `gh` primitive moves BYTE-IDENTICALLY
# out of the caller layer ([INV-87]); the surrounding INV-coupled logic —
# the [INV-44]/[INV-54] mergeable/open-PR classifiers, the
# `select(.body|test("#N"))` filter, all marker-parsing — stays caller-side
# (provider-neutral), per docs/pipeline/provider-spec.md §3.2 / [M2].
#
# CONVENTION (so a future GitLab CHP slots in mechanically):
#   - Each CHP verb's GitHub leaf is a function named  chp_github_<verb>.
#   - lib-code-host.sh's `chp_<verb>` shim forwards "$@" to it when
#     CODE_HOST=github (the default).
#   - The GitHub `.caps` manifest beside this file (chp-github.caps) declares
#     exactly today's GitHub behavior — the no-behavior-change anchor ([INV-88]).
#
# PRECONDITION: sourced by lib-code-host.sh from the REAL skill tree
# (readlink -f of that lib's BASH_SOURCE). `$REPO` is in scope from the caller's
# environment (lib-dispatch.sh / the wrappers' required env).
#
# 11 CHP verbs migrated here (spec §3.2):
#   chp_github_find_pr_for_issue   chp_github_ci_status
#   chp_github_mergeable           chp_github_create_pr
#   chp_github_approve             chp_github_request_changes
#   chp_github_merge               chp_github_review_threads
#   chp_github_resolve_thread      chp_github_trigger_bot
#   chp_github_close_keyword
# (chp_caps reads the .caps manifest in the dispatcher, not a function here.)
#
# Plus the reviewed-HEAD CI-rollup gate read (#489, [INV-134]):
#   chp_github_ci_rollup — sibling of chp_github_ci_status, not a
#   replacement; see that leaf's own header for the split rationale.

# TRANSPORT-LIB SELF-SOURCE: `gh_version_ok` (the `--slurp` capability check
# some leaves below preflight on) lives in `lib-github-transport.sh` (a
# sibling file in `providers/`, shared with itp-github.sh — mirrors the
# lib-gitlab-transport.sh self-source pattern, #416). Guarded on `declare -F
# gh_version_ok`: a unit test with a test-local stub, or the sibling
# itp-github.sh already sourcing it, must not be clobbered by a re-source.
if ! declare -F gh_version_ok >/dev/null 2>&1; then
  _CHP_GITHUB_SELF="${BASH_SOURCE[0]:-$0}"
  _CHP_GITHUB_DIR="$(cd "$(dirname "$(readlink -f "$_CHP_GITHUB_SELF")")" && pwd)"
  # shellcheck source=lib-github-transport.sh
  [[ -f "${_CHP_GITHUB_DIR}/lib-github-transport.sh" ]] && \
    source "${_CHP_GITHUB_DIR}/lib-github-transport.sh"
fi

# ---------------------------------------------------------------------------
# W1c1 (#397) PR-read leaf machinery, shared by chp_github_find_pr_for_issue
# and chp_github_pr_list.
#
# Design:
#   (a) TRUE page walk with exhaustion detection — `gh api graphql` with
#       cursor pagination (`pullRequests(first:100, after:$cursor)`, reads
#       `pageInfo.{endCursor,hasNextPage}`), NOT `--limit N` (which returns
#       partial rc 0 at N+1 candidates — the pre-#397 truncation hazard #397 R1
#       explicitly forbids).
#   (b) FAIL-CLOSED on cap-hit — reaching CHP_GITHUB_PR_LIST_PAGE_CAP pages
#       before `hasNextPage=false` → rc≠0, no partial output. Callers with
#       `|| return 1` refuse the pushed-no-PR classification.
#   (c) FAIL-CLOSED on empty stdout — if `gh api graphql` returns nothing / a
#       non-array / non-JSON, rc≠0. Guards the codex-flagged fail-open where
#       an empty stdout rc 0 flows through jq into "no candidates".
#   (d) PROJECTION-ONLY normalizer — emit EXACTLY the caller's requested
#       fields (plus the resolver keys for find_pr_for_issue). No fabricated
#       `closingIssueNumbers:[]`/`mergeable:""` on non-requested fields.
#   (e) `comments` is in the shared §3.2.1 vocabulary (populated by the
#       sibling W1c2 chp_pr_view leaf and by itp_list_comments) but is NOT
#       delivered here — the leaf REJECTS it with rc≠0 loudly. `reviews` IS
#       delivered by the GraphQL page walker (see the `_CHP_GITHUB_PR_FIELDS_
#       SUPPORTED` constant below and its explanatory comment).
#
# Field vocabulary supported by these two leaves (SUBSET of §3.2.1): number,
# state, title, body, createdAt, updatedAt, mergedAt, headRefName, headRefOid,
# reviewDecision, mergeable, closingIssueNumbers, reviews. Requesting
# `comments` → rc 2 (single unsupported field).

# _chp_github_pr_fields_supported and _chp_github_pr_fields_unsupported —
# the vocabulary split. Bare-string CSVs to keep grep-anchor semantics simple.
# `reviews` IS delivered by the GraphQL page walker (pullRequests { reviews }
# connection, capped at first 100 per PR — sufficient for every current
# `_pgid_has_recent_success` / near-success signal-2 caller which only reads
# the newest APPROVED submittedAt). `comments` is NOT delivered: it lives on
# the ISSUE (itp_list_comments) and folding it in here would cross the
# ITP/CHP seam — callers that need comments use itp_list_comments; callers
# that need PR REVIEW-thread inline comments use chp_review_threads.
#
# Guarded `readonly` (`declare -p … 2>/dev/null || readonly …`): the wrappers
# self-source `lib-code-host.sh` (which sources this file) more than once
# through the transitive lib graph (`lib-review-e2e.sh`, `lib-auth.sh` all
# self-source the CHP seam via `readlink -f`, so a re-source is normal). A
# bare `readonly ...=` on the second source aborts under `set -e` with
# `readonly variable`; the guard makes the assignment idempotent.
declare -p _CHP_GITHUB_PR_FIELDS_SUPPORTED >/dev/null 2>&1 || \
  readonly _CHP_GITHUB_PR_FIELDS_SUPPORTED="number,state,title,body,createdAt,updatedAt,mergedAt,headRefName,headRefOid,reviewDecision,mergeable,closingIssueNumbers,reviews"
declare -p _CHP_GITHUB_PR_FIELDS_UNSUPPORTED >/dev/null 2>&1 || \
  readonly _CHP_GITHUB_PR_FIELDS_UNSUPPORTED="comments"

# _chp_github_pr_parse_fields <fields-csv> [forced-extra-fields...] — parse
# CSV, dedupe, validate against the supported/unsupported vocabulary. Rejects
# unsupported fields (rc 2, LOUD stderr) and unknown-name fields (rc 2). Sets
# global `_CHP_PARSED_FIELDS` to a comma-separated list of validated
# normalized field names.
_chp_github_pr_parse_fields() {
  local fields="$1"; shift
  _CHP_PARSED_FIELDS=""
  local seen="," f
  local IFS_SAVE=$IFS; IFS=','
  # shellcheck disable=SC2206
  local -a _caller=(${fields})
  IFS="$IFS_SAVE"
  local -a _all=("${_caller[@]}" "$@")
  for f in "${_all[@]}"; do
    [ -n "$f" ] || continue
    # Reject the ONE §3.2.1 vocabulary field these two verbs deliberately
    # don't deliver: `comments` (issue-level; owned by itp_list_comments —
    # crossing the ITP/CHP seam here would double-source that data).
    case ",${_CHP_GITHUB_PR_FIELDS_UNSUPPORTED}," in
      *",$f,"*)
        echo "ERROR: chp_github pr_list/find_pr_for_issue: field '$f' is not delivered by these two verbs (issue-comments live on the ITP seam — use itp_list_comments)" >&2
        return 2 ;;
    esac
    # Reject unknown field names (typo / non-vocabulary).
    case ",${_CHP_GITHUB_PR_FIELDS_SUPPORTED}," in
      *",$f,"*) : ;;
      *) echo "ERROR: chp_github pr_list/find_pr_for_issue: field '$f' is not in the §3.2.1 supported vocabulary ($_CHP_GITHUB_PR_FIELDS_SUPPORTED)" >&2; return 2 ;;
    esac
    case "$seen" in
      *",$f,"*) : ;;
      *) seen="$seen$f,"; _CHP_PARSED_FIELDS="${_CHP_PARSED_FIELDS:+$_CHP_PARSED_FIELDS,}$f" ;;
    esac
  done
  return 0
}

# _chp_github_pr_gh_fields <normalized-csv> — map validated normalized fields
# to the gh-native GraphQL field list. `closingIssueNumbers` maps to
# `closingIssuesReferences`; other names pass through. Emits the gh-native
# GraphQL selection body (space-separated for the query).
_chp_github_pr_gh_fields() {
  local fields="$1" out="" f
  local IFS_SAVE=$IFS; IFS=','
  # shellcheck disable=SC2206
  local -a _fields=(${fields})
  IFS="$IFS_SAVE"
  for f in "${_fields[@]}"; do
    case "$f" in
      closingIssueNumbers) out+=" closingIssuesReferences(first:100){nodes{number}}" ;;
      headRefName)         out+=" headRefName" ;;
      headRefOid)          out+=" headRefOid" ;;
      number)              out+=" number" ;;
      state)               out+=" state" ;;
      title)               out+=" title" ;;
      body)                out+=" body" ;;
      createdAt)           out+=" createdAt" ;;
      updatedAt)           out+=" updatedAt" ;;
      mergedAt)            out+=" mergedAt" ;;
      reviewDecision)      out+=" reviewDecision" ;;
      mergeable)           out+=" mergeable" ;;
      reviews)             out+=" reviews(first:100){nodes{author{login},state,submittedAt}}" ;;
    esac
  done
  # number is always safe to include for internal identification (deduped),
  # but the OUTPUT projection is driven by _CHP_PARSED_FIELDS so we don't
  # fabricate it if the caller didn't ask.
  case " $out " in
    *" number "*) : ;;
    *) out=" number$out" ;;
  esac
  # Also always fetch pageInfo — required for cursor exhaustion detection.
  printf '%s' "$out"
}

# _chp_github_pr_projection_jq <normalized-csv> — build the jq projection
# that emits EXACTLY the requested normalized fields (no fabrication). Uses
# the pattern `if input has KEY then {KEY: fn(...)} else {} end + …` to
# assemble ONLY the caller-requested keys into each output object.
_chp_github_pr_projection_jq() {
  local fields="$1" out="{}"
  local IFS_SAVE=$IFS; IFS=','
  # shellcheck disable=SC2206
  local -a _fields=(${fields})
  IFS="$IFS_SAVE"
  local f
  for f in "${_fields[@]}"; do
    case "$f" in
      number)              out+=' + {number: .number}' ;;
      state)               out+=' + {state: (.state // "")}' ;;
      title)               out+=' + {title: (.title // "")}' ;;
      body)                out+=' + {body: (.body // "")}' ;;
      createdAt)           out+=' + {createdAt: (.createdAt // null)}' ;;
      updatedAt)           out+=' + {updatedAt: (.updatedAt // null)}' ;;
      mergedAt)            out+=' + {mergedAt: (.mergedAt // null)}' ;;
      headRefName)         out+=' + {headRefName: (.headRefName // "")}' ;;
      headRefOid)          out+=' + {headRefOid: (.headRefOid // "")}' ;;
      reviewDecision)      out+=' + {reviewDecision: (.reviewDecision // "")}' ;;
      mergeable)           out+=' + {mergeable: (.mergeable // "")}' ;;
      closingIssueNumbers) out+=' + {closingIssueNumbers: ([ (.closingIssuesReferences.nodes // [])[]?.number ])}' ;;
      reviews)             out+=' + {reviews: ([ (.reviews.nodes // [])[]? | {author: (.author.login // ""), state: (.state // ""), submittedAt: (.submittedAt // null)} ])}' ;;
    esac
  done
  printf '[ .[] | %s ]' "$out"
}

# _chp_github_pr_state_filter <normalized-state> — map open|closed|merged|all
# to GraphQL PullRequestState list (states: [OPEN]/[CLOSED]/[MERGED]/[OPEN,CLOSED,MERGED]).
_chp_github_pr_state_filter() {
  case "$1" in
    open)   printf '[OPEN]' ;;
    closed) printf '[CLOSED]' ;;
    merged) printf '[MERGED]' ;;
    all)    printf '[OPEN,CLOSED,MERGED]' ;;
  esac
}

# _chp_github_pr_page_cap — read-and-clamp the CHP_GITHUB_PR_LIST_PAGE_CAP env
# override. Default 20 pages (100 PRs/page → 2000 PRs, a comfortable upper
# bound). Cap-hit before pagination exhaustion is fail-CLOSED (leaf rc 1).
_chp_github_pr_page_cap() {
  local cap="${CHP_GITHUB_PR_LIST_PAGE_CAP:-20}"
  [[ "$cap" =~ ^[0-9]+$ ]] && (( cap > 0 )) || cap=20
  printf '%s' "$cap"
}

# _chp_github_pr_fetch_all <state-graphql> <gh-fields-selection> — page-walk
# `pullRequests(first:100, states:<state>, after:$cursor)` via `gh api graphql`
# until `pageInfo.hasNextPage == false`. Returns the concatenated node array
# (raw GraphQL PR objects) on stdout, rc 0. Fail-CLOSED on any page fetch
# error, empty stdout, non-JSON, non-array, or cap-hit before exhaustion.
_chp_github_pr_fetch_all() {
  local state_filter="$1" gh_fields="$2"
  local owner="${REPO%%/*}" name="${REPO##*/}"
  local page_cap; page_cap="$(_chp_github_pr_page_cap)"
  local cursor="null" pages=0
  local -a accumulated=()
  local page_json nodes has_next
  local query
  # GraphQL query template: STATES/FIELDS are shell-spliced (both come from
  # our validated allowlists — state from _chp_github_pr_state_filter, fields
  # from _chp_github_pr_gh_fields — neither is user-controlled).
  while (( pages < page_cap )); do
    query="query(\$owner: String!, \$repo: String!, \$cursor: String) {
      repository(owner: \$owner, name: \$repo) {
        pullRequests(first: 100, states: $state_filter, after: \$cursor, orderBy: {field: CREATED_AT, direction: DESC}) {
          pageInfo { endCursor hasNextPage }
          nodes { $gh_fields }
        }
      }
    }"
    if [[ "$cursor" == "null" ]]; then
      page_json="$(gh api graphql -F owner="$owner" -F repo="$name" -f query="$query" 2>/dev/null)" || return 1
    else
      page_json="$(gh api graphql -F owner="$owner" -F repo="$name" -F cursor="$cursor" -f query="$query" 2>/dev/null)" || return 1
    fi
    # Capture-then-check: empty stdout / non-JSON / missing pullRequests →
    # fail-CLOSED (rc≠0, no partial). The pre-#397 leaf silently returned
    # []; the codex-flagged empty-stdout fail-open branch is closed here.
    [[ -n "$page_json" ]] || return 1
    jq -e '.data.repository.pullRequests.nodes | type == "array"' >/dev/null 2>&1 <<<"$page_json" || return 1
    nodes="$(jq -c '.data.repository.pullRequests.nodes' <<<"$page_json")" || return 1
    accumulated+=("$nodes")
    has_next="$(jq -r '.data.repository.pullRequests.pageInfo.hasNextPage' <<<"$page_json" 2>/dev/null)" || return 1
    if [[ "$has_next" != "true" ]]; then
      # Exhaustion. Merge accumulated arrays and emit.
      printf '%s\n' "${accumulated[@]}" | jq -c -s 'add // []'
      return 0
    fi
    cursor="$(jq -r '.data.repository.pullRequests.pageInfo.endCursor' <<<"$page_json" 2>/dev/null)" || return 1
    [[ -n "$cursor" && "$cursor" != "null" ]] || return 1
    pages=$(( pages + 1 ))
  done
  # Cap-hit before exhaustion → fail-CLOSED per §3.5 (spec explicitly
  # forbids returning a partial candidate set).
  echo "ERROR: chp_github pr_list/find_pr_for_issue: page cap ${page_cap} reached before pagination exhaustion — set CHP_GITHUB_PR_LIST_PAGE_CAP higher (each page = 100 PRs)" >&2
  return 1
}

# ---------------------------------------------------------------------------
# chp_github_find_pr_for_issue ISSUE FIELDS-CSV — normalized candidate PR fetch.
#
# Spec §3.2 [M1] (W1c1, #397): return a NORMALIZED JSON ARRAY of open PR
# candidates for close-linkage-resolution by the caller. Each candidate is
# projected to the caller-supplied FIELDS-CSV ∪ the three selection keys
# (`number,closingIssueNumbers,headRefName`). PROJECTION-ONLY — no
# fabricated `closingIssueNumbers:[]`/`mergeable:""` for unrequested fields;
# see `_chp_github_pr_projection_jq` above. Vocabulary is §3.2.1 minus the
# `comments`/`reviews` fields (which the sibling W1c2 chp_pr_view leaf owns
# — `pullRequests(first:100)` cannot deliver them here; requesting them → rc 2
# loudly). `body` is normalized to a string (`null` → `""`, the #148 hazard
# fix); `closingIssueNumbers` is an int-array flattened from GitHub's
# `closingIssuesReferences.nodes[].number`.
#
# No `gh` flags or `jq` programs cross the seam — the caller's [INV-86]
# two-tier resolution (close-linkage beats branch-name, boundary-anchored
# branch match, deterministic PR-number tie-break) lives in `lib-pr-linkage.sh`
# as pure jq over the returned array (mirrors INV-44 classifiers-stay-caller-side).
#
# The ISSUE positional stops being dead: it is a NARROWING HINT the provider
# MAY use to prune the candidate set — but ONLY when no true candidate can be
# excluded. GitHub has no server-side "PR that closes issue N" filter today,
# so the ISSUE arg is documented but IGNORED here; GraphQL returns all open
# PRs (paginated by cursor) and the caller narrows client-side.
#
# COMPLETE-set (§3.5): TRUE cursor page walk via `pullRequests(first:100,
# after:$endCursor)` until `pageInfo.hasNextPage == false`, bounded by
# `CHP_GITHUB_PR_LIST_PAGE_CAP` pages (default 20 → 2000 open PRs). A fixed
# `--limit N` is NOT acceptable — it just moves the silent-truncation
# threshold (the pre-W1c1 hazard #397 R1 explicitly forbids). Cap-hit before
# exhaustion is FAIL-CLOSED: rc≠0 and no partial output.
#
# Fail-closed on `gh` error / empty stdout / non-JSON / non-array — capture-
# then-check gate inside `_chp_github_pr_fetch_all`, so an empty gh stdout rc 0
# (the pre-W1c1 fail-open hazard) → the caller's `|| return 1` refuses the
# classification.
#
# Regression anchors: #148 (null-body PRs no longer hide close-linked
# matches); #277/[INV-86] (close-linkage beats body-mention); silent
# `--limit 30` truncation the pre-#397 leaf inherited from gh's default.
chp_github_find_pr_for_issue() {
  # `${2:-}` (not `$2`) so the missing-FIELDS guard is reachable under `set -u`
  # rather than aborting on an unbound `$2`.
  local _issue="${1:-}" fields="${2:-}"
  [ -n "$fields" ] || { echo "ERROR: chp_github_find_pr_for_issue requires FIELDS-CSV (2nd arg) [M1]" >&2; return 2; }
  # Parse + validate + union the caller's fields with the three [INV-86]
  # resolution keys (number, closingIssueNumbers, headRefName). The parser
  # rejects unsupported vocabulary (comments/reviews → rc 2 loudly) and
  # unknown-name fields — sets `_CHP_PARSED_FIELDS`.
  local _CHP_PARSED_FIELDS
  _chp_github_pr_parse_fields "$fields" number closingIssueNumbers headRefName || return $?
  local gh_fields projection nodes
  gh_fields="$(_chp_github_pr_gh_fields "$_CHP_PARSED_FIELDS")"
  # Real page walk with exhaustion detection (§3.5, W1c1 R1). Fail-CLOSED on
  # empty stdout / non-JSON / non-array / cap-hit-before-exhaustion.
  nodes="$(_chp_github_pr_fetch_all "$(_chp_github_pr_state_filter open)" "$gh_fields")" || return 1
  # PROJECT-ONLY the caller's requested fields (∪ the resolver keys). NO
  # fabrication of unrequested vocabulary members.
  projection="$(_chp_github_pr_projection_jq "$_CHP_PARSED_FIELDS")"
  jq -c "$projection" <<<"$nodes"
}

# chp_github_ci_status PR — normalized CI-status token (#399 W1d, [INV-87]).
#
# Spec §3.2: the leaf owns the FULL `gh pr checks` argv AND the per-check-state
# → single-token projection; the caller's old `--json state -q '[.[].state]'`
# tail + the `length>0 and all(.=="SUCCESS")` gate move HERE. Stdout is exactly
# one of `green|pending|failed|none`, derived by this decision order over the
# per-check state multiset (every `gh pr checks` state token is bucketed):
#
#   (1) zero checks                              → `none`
#   (2) any ∈ {FAILURE,ERROR,CANCELLED,TIMED_OUT} → `failed`
#   (3) any ∈ {PENDING,QUEUED,IN_PROGRESS,EXPECTED,SKIPPED} or any state not
#       otherwise listed                          → `pending`
#   (4) else (all SUCCESS, ≥1)                    → `green`
#
# Rule 2 beats rule 3 (a FAILURE+SKIPPED set is `failed`); SKIPPED deliberately
# lands in `pending` — a `SKIPPED` check is NOT a `SUCCESS`, and the old gate
# was `all(=="SUCCESS")` so a skipped-mix was already not-green.
#
# gh rc-quirk (R2): `gh pr checks` exits non-zero for failing/pending/no-checks
# cases even when the JSON payload is well-formed. The leaf inspects stdout —
# a parseable JSON array present → derive the token from it regardless of gh's
# rc (empty array → `none`); no parseable JSON on stdout (genuine query/
# transport failure) → the leaf itself exits non-zero with stdout empty. The
# caller (`ci_is_green`) treats any leaf rc≠0 as not-green + WARN via its
# existing mktemp/stderr-capture transport-failure path (TC-DSAP-014/015).
chp_github_ci_status() {
  local pr="$1"
  local raw gh_err states token
  # Capture stderr to a scratch file so we can (a) discard it when the payload
  # is parseable JSON (gh's rc-quirk emits noise on stderr even for a valid
  # payload) and (b) forward it to OUR stderr when the payload is not
  # parseable (genuine transport failure — the caller's mktemp/WARN path
  # TC-DSAP-014/015 pins the WARN wording that surfaces the diagnostic).
  gh_err="$(mktemp)"
  raw="$(gh pr checks "$pr" --repo "$REPO" --json state 2>"$gh_err" || true)"
  # Empty stdout is UNCONDITIONALLY a transport failure — jq on empty input
  # returns rc 0 with no output, which would otherwise fall through the rest
  # of the pipeline as empty `states=""` / empty `token=""` and echo "" at
  # rc 0 (the P2-3 fail-open latch the conformance runner's strict
  # fail-closed pin catches). Reject empty raw stdout first.
  if [[ -z "$raw" ]]; then
    [ -s "$gh_err" ] && cat "$gh_err" >&2
    rm -f "$gh_err"
    return 1
  fi
  # Payload-type gate (#398-class review-round finding): a rc-0 JSON OBJECT
  # payload (e.g. `{}` — an error-shaped response some gh backends emit on
  # unexpected failure, or a schema-drift regression on a future gh release)
  # would be silently misread as "no checks configured" — `jq '[.[].state]'`
  # iterates the OBJECT's values (of which `{}` has none) and produces `[]`,
  # which the bucket jq maps to `none`. Reject any payload that is not a
  # JSON ARRAY BEFORE deriving the token: `type == "array"` guards `{}`,
  # `{"message":"Not Found"}`, bare strings, numbers, and null. A well-formed
  # array (including the legitimate zero-checks `[]` that maps to `none`)
  # passes.
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$raw" || {
    [ -s "$gh_err" ] && cat "$gh_err" >&2
    rm -f "$gh_err"
    return 1
  }
  states="$(printf '%s' "$raw" | jq -er '[.[].state]' 2>/dev/null)" || {
    # No parseable JSON on stdout → forward gh's own error and return non-zero.
    [ -s "$gh_err" ] && cat "$gh_err" >&2
    rm -f "$gh_err"
    return 1
  }
  rm -f "$gh_err"
  # Bucket the state multiset per the R1 decision order. jq owns the mapping;
  # no per-token bash iteration.
  token="$(jq -r '
    if length == 0 then "none"
    elif any(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT") then "failed"
    elif all(. == "SUCCESS") then "green"
    else "pending"
    end
  ' <<<"$states" 2>/dev/null)" || return 1
  # Belt-and-suspenders: an empty token would slip past the "" gate under an
  # unforeseen jq quirk. Empty token = fail-closed, rc≠0.
  [[ -n "$token" ]] || return 1
  printf '%s' "$token"
}

# chp_github_ci_rollup PR — reviewed-HEAD CI-rollup gate leaf (issue #489,
# [INV-134]). SIBLING of chp_github_ci_status, NOT a replacement — that
# leaf's SKIPPED→`pending` mapping is deliberately kept for green-
# corroboration use (`_e2e_ci_green_precheck`) and stays byte-unchanged.
# This leaf answers a DIFFERENT question — "does any check block approval?"
# — where SKIPPED/NEUTRAL are non-blocking (a permanently-SKIPPED
# label-gated check must never permanently block approval).
#
# Stdout: one JSON object `{"token":"<green|pending|failed|none>",
# "failed_checks":["<name>",...]}`. rc≠0 on transport/parse failure with
# EMPTY stdout (fail-closed, mirrors chp_github_ci_status's empty-stdout and
# non-array payload guards verbatim) — EXCEPT the one well-known case below.
#
# gh no-checks quirk: on a PR with ZERO checks configured, `gh pr checks`
# prints "no checks reported on the '<branch>' branch" to STDERR, empty
# STDOUT, and exits non-zero — indistinguishable from a transport failure by
# stdout alone. Unlike chp_github_ci_status (whose consumer's SKIPPED→
# `pending` mapping never needs to special-case this), THIS leaf's contract
# requires `none` to reach `proceed` (D3: "a repo with zero checks must not
# block approval") — so a raw empty-stdout→rc≠0 read here would permanently
# route every zero-checks repo through the bounded-wait/give-up path instead.
# Detect gh's specific message on stderr and map it to `none`; anything else
# on an empty-stdout failure stays fail-closed exactly as before.
#
# Decision order over the per-check {name,state} multiset (issue #489 D1):
#   (1) any ∈ {FAILURE,ERROR,CANCELLED,TIMED_OUT} → `failed`
#       (failed_checks lists exactly those checks' names)
#   (2) else any ∈ {PENDING,QUEUED,IN_PROGRESS,EXPECTED} or any state not
#       otherwise listed → `pending` (failed_checks lists those still-
#       unresolved checks' names — D3's wait-cap give-up finding needs them)
#   (3) else zero checks → `none`
#   (4) else → `green` (SUCCESS, SKIPPED, NEUTRAL are all non-blocking; an
#       all-SKIPPED set is `green`, not `none`)
# Rule 1 beats rule 2 (a FAILURE+PENDING set is `failed`).
chp_github_ci_rollup() {
  local pr="$1"
  local raw gh_err token
  gh_err="$(mktemp)"
  # Same capture-then-check discipline as chp_github_ci_status: gh's rc-quirk
  # noise on stderr is discarded on a parseable payload, forwarded on a
  # genuine transport failure. `|| true` here only survives gh's non-zero
  # rc long enough for the empty-stdout check below to classify it.
  raw="$(gh pr checks "$pr" --repo "$REPO" --json name,state 2>"$gh_err" || true)"
  if [[ -z "$raw" ]]; then
    if grep -qi 'no checks reported' "$gh_err" 2>/dev/null; then
      rm -f "$gh_err"
      printf '%s' '{"token":"none","failed_checks":[]}'
      return 0
    fi
    [ -s "$gh_err" ] && cat "$gh_err" >&2
    rm -f "$gh_err"
    return 1
  fi
  # Payload-type gate (mirrors chp_github_ci_status): reject anything that
  # is not a JSON array BEFORE deriving the token.
  jq -e 'type == "array"' >/dev/null 2>&1 <<<"$raw" || {
    [ -s "$gh_err" ] && cat "$gh_err" >&2
    rm -f "$gh_err"
    return 1
  }
  rm -f "$gh_err"
  token="$(jq -c '
    def is_failed: . == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT";
    def is_nonblocking: . == "SUCCESS" or . == "SKIPPED" or . == "NEUTRAL";
    if any(.[]; .state | is_failed) then
      {token: "failed", failed_checks: [.[] | select(.state | is_failed) | .name]}
    elif any(.[]; .state | is_nonblocking | not) then
      {token: "pending", failed_checks: [.[] | select(.state | is_nonblocking | not) | .name]}
    elif length == 0 then
      {token: "none", failed_checks: []}
    else
      {token: "green", failed_checks: []}
    end
  ' <<<"$raw" 2>/dev/null)" || return 1
  [[ -n "$token" ]] || return 1
  printf '%s' "$token"
}

# chp_github_mergeable PR — normalized mergeable token (#399 W1d, [M2]).
#
# Spec §3.2: the leaf owns BOTH the `gh pr view --json mergeable` query AND
# the `-q '.mergeable'` projection the caller previously supplied. Stdout is
# exactly one token from `MERGEABLE|CONFLICTING|UNKNOWN` on success
# (case-insensitively matched — `_classify_mergeable_gate` upper-cases before
# compare); rc≠0 on ANY of: gh query failure, empty stdout, or a token
# outside the pinned set. The token set matches GitHub's RAW `mergeable`
# values verbatim so `lib-review-mergeable.sh`'s classifiers ship
# byte-unchanged.
#
# P2-3 (adversarial-review round): the pre-fix leaf forwarded gh's `-q`
# output blindly. On an empty `.mergeable` field (missing-schema regression /
# `gh --jq` quirk) that produces empty stdout at rc 0, and the caller's
# `|| echo ""` fallback would NOT trigger, so an empty MERGEABLE_STATUS fell
# straight into `_classify_mergeable_gate ""` → `block-nonsubstantive`
# silently — a single-shot degradation with no retry. Now the leaf returns
# rc≠0 on empty/unknown; the caller's `MERGEABLE_STATUS=$(chp_mergeable ... ||
# echo "")` maps that to empty, the UNKNOWN-retry loop retries per its usual
# rules, and after `MERGEABLE_RETRIES` the classifier still routes to
# block-nonsubstantive — the SAME final gate, but reached HONESTLY through
# retry rather than silently on the first attempt.
chp_github_mergeable() {
  local pr="$1"
  local raw
  raw="$(gh pr view "$pr" --repo "$REPO" --json mergeable -q '.mergeable' 2>/dev/null)" || return 1
  # Reject empty / anything outside the pinned set. Case-insensitive check
  # (via upper-case fold) so `mergeable`/`Mergeable`/etc. are accepted; we
  # forward the ORIGINAL casing verbatim so the classifier's byte-compare
  # sees exactly what gh returned.
  case "${raw^^}" in
    MERGEABLE|CONFLICTING|UNKNOWN) printf '%s' "$raw" ;;
    *) return 1 ;;
  esac
}

# chp_github_create_pr HEAD_BRANCH TITLE BODY — open a PR.
#
# Spec §3.2 (W1e / #400): abstract positional contract — the wrapper's PR-create
# broker (`drain_agent_pr_create`, lib-auth.sh) passes THREE POSITIONALS; this
# leaf owns the `--head/--title/--body` flags (they no longer cross the seam).
# The emitted `gh pr create --repo $REPO --head $HEAD --title $TITLE --body $BODY`
# argv is IDENTICAL to what pre-#400 broker composed — the leaf still emits the
# same flags, but they are constructed HERE from positionals, not forwarded from
# the caller. The wrapper cwd is on the base branch, so the explicit `--head` is
# required (#234 [P1]).
#
# rc-only contract: stdout MAY emit the created PR identifier (real `gh pr create`
# emits the URL); the broker discards it (`>/dev/null 2>&1`). Callers MUST NOT
# depend on stdout. Non-zero rc = creation NOT CONFIRMED — a remote can create
# the PR and still fail the response (transport); the broker's pre-create
# existence check (lib-auth.sh:452-455 via chp_pr_list) makes it idempotent.
#
# Positional validation (mirrors the W1a/W1c1 read-verb pattern): HEAD_BRANCH
# and TITLE must be non-empty. Missing/empty → rc 2, loud stderr naming the
# offending arg, NO gh call — a real gh with `--head ""` would emit a
# confusing "must be specified" error at best and create an unintended PR
# at worst; failing fast at the seam is safer.
#
# BODY intentionally MAY be empty: the caller (`drain_agent_pr_create`,
# lib-auth.sh:474/478) derives body from `tail -n +2/+3` of the PR-create
# file the agent writes — a title-only file yields body="" legitimately,
# and `gh pr create --body ""` is a valid GitHub PR creation (empty
# description). Rejecting empty BODY here would turn a legitimate
# title-only brokered create into rc 2 → the broker treats it as failure,
# the issue re-queues, and the PR never opens. Review-lane finding on
# #400 r1 caught this — the empty-body check was overreach.
#
# PAT-mode / app-mode-without-scoping creates the PR via the agent directly
# (prompt-driven `gh pr create`), unchanged.
#
# `--base "${BASE_BRANCH:-main}"` (issue #478, [INV-131]) is added
# UNCONDITIONALLY — explicit-deterministic beats relying on the host repo's
# default-branch setting. The wrapper resolves+exports BASE_BRANCH once at
# startup (lib-config.sh::resolve_base_branch); the `:-main` fallback here
# only covers a direct/test invocation of this leaf outside the wrapper.
# With BASE_BRANCH unset (today's universal case), this emits the SAME argv
# as before plus exactly the `--base main` pair — the byte-identical-default
# guarantee for every OTHER flag.
chp_github_create_pr() {
  local head_branch="${1:-}" title="${2:-}" body="${3:-}"
  [ -n "$head_branch" ] || { echo "ERROR: chp_github_create_pr requires HEAD_BRANCH (1st arg, non-empty)" >&2; return 2; }
  [ -n "$title" ]       || { echo "ERROR: chp_github_create_pr requires TITLE (2nd arg, non-empty)" >&2; return 2; }
  # BODY may be empty by design — do NOT gate.
  gh pr create --repo "$REPO" --head "$head_branch" --title "$title" --body "$body" --base "${BASE_BRANCH:-main}"
}

# chp_github_approve PR BODY — approve a PR.
#
# Spec §3.2 (W1e / #400): abstract positional contract — the review wrapper's
# PASS path passes `<pr> <body>` as TWO POSITIONALS; this leaf owns the
# `--approve --body` flags. The emitted `gh pr review $PR --repo $REPO --approve
# --body $BODY` argv is IDENTICAL to the pre-#400 wrapper-composed line — the
# leaf still emits `--approve --body`, but from a positional input rather than a
# forwarded flag-tail. rc-only contract: gh rc≠0 → leaf rc≠0 (the wrapper drives
# the manual-review notification + reviewing→approved fallback off rc). The
# [INV-52]/[INV-79] wrapper-owns-approve ownership + PASS-gate chain (mergeable,
# no-auto-close, PR-open) STAY caller-side.
#
# Positional validation: PR must be a non-empty numeric identifier
# (`^[0-9]+$`, matching the repo's `chp_count_reviews_by_login`/`itp_read_task`
# guard idiom); BODY must be non-empty. Missing/empty/non-numeric PR → rc 2,
# loud stderr, NO gh call.
chp_github_approve() {
  local pr="${1:-}" body="${2:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { echo "ERROR: chp_github_approve requires PR (1st arg, non-empty numeric): got '${pr}'" >&2; return 2; }
  [ -n "$body" ]           || { echo "ERROR: chp_github_approve requires BODY (2nd arg, non-empty)" >&2; return 2; }
  gh pr review "$pr" --repo "$REPO" --approve --body "$body"
}

# chp_github_request_changes PR BODY — submit REQUEST_CHANGES on a PR.
#
# Spec §3.2: the `gh pr review --request-changes` leaf inside
# submit_request_changes (lib-review-request-changes.sh, [INV-52]). Gated by the
# `rest_request_changes` cap (§4.2): a backend without a REST request-changes
# verb (`rest_request_changes=0`, e.g. GitLab) emulates via a quick-action note
# instead — but the caller's best-effort return-0 + token-refresh glue STAYS in
# submit_request_changes. GitHub forwards `--request-changes --body $BODY`
# byte-identically.
chp_github_request_changes() {
  local pr="$1" body="${2:-}"
  gh pr review "$pr" --repo "$REPO" --request-changes --body "$body"
}

# chp_github_merge PR — merge a PR.
#
# Spec §3.2 (W1e / #400) [M4]: abstract positional contract — the review wrapper
# passes ONE positional; the merge strategy (squash + delete source branch) is
# CONTRACT-FIXED, not a caller option ([INV-52] wrapper-owns-merge; a future
# strategy would be a spec amendment, not a flag pass-through). The leaf owns
# `--squash --delete-branch`; the emitted `gh pr merge $PR --repo $REPO --squash
# --delete-branch` argv is IDENTICAL to the pre-#400 wrapper-composed line.
#
# stdout/stderr: provider diagnostic text — the wrapper captures both under
# `set +e` into `MERGE_OUT` and uses the first 500 chars as the auto-merge-
# failure PR-comment excerpt (#145 rebase-marker path). Diagnostics are
# PRESERVED through the seam (no redirection here).
#
# Positional validation: PR must be a non-empty numeric identifier
# (`^[0-9]+$`). Missing/empty/non-numeric → rc 2, loud stderr, NO gh call —
# `gh pr merge ""` or `gh pr merge abc` would emit a confusing error at best
# and MERGE THE WRONG PR at worst (a numeric parse of `abc` yielding 0 would
# be catastrophic on a repo with PR #0-adjacent numbering); failing fast at
# the seam is the only safe posture on the highest-blast-radius verb.
#
# Cross-seam coupling ([M4]/[INV-33], merge_closes_issue=1 for GitHub): merging a
# PR whose body carries `Closes #N` auto-transitions the issue to its terminal
# state as a SIDE EFFECT, so the wrapper MUST NOT call itp_transition_state (nor
# `gh issue close`) after a GitHub merge. A `merge_closes_issue=0` backend MUST
# transition explicitly post-merge. This is a CALLER-side decision branched on
# `chp_caps merge_closes_issue`; the leaf itself only performs the merge.
chp_github_merge() {
  local pr="${1:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { echo "ERROR: chp_github_merge requires PR (1st arg, non-empty numeric): got '${pr}'" >&2; return 2; }
  gh pr merge "$pr" --repo "$REPO" --squash --delete-branch
}

# chp_github_review_threads PR — COMPLETE review-thread set, M8 shape.
#
# Spec §3.2 [M8] / §3.5: walks BOTH GraphQL pagination levels internally and
# returns the CHP thread shape — DISTINCT from the ITP issue-comment shape
# ([INV-90]):
#   [{thread_id, resolved, comments:[{id, path, line, author, body, createdAt}]}]
# `.path`/`.line` are CHP-owned and never appear in the ITP shape. `$REPO` is
# split into owner/name for the query (the historical resolve-threads.sh CLI
# took owner+repo as separate args; the verb signature is provider-neutral `PR`).
#
# Sole caller: skills/autonomous-common/scripts/resolve-threads.sh (selects
# `.[]|select(.resolved==false).thread_id` for the resolveReviewThread mutation).
#
# Pagination (#401 / #347 W1f). `gh api graphql` is NOT auto-paginated, so
# §3.5's complete-set MUST is implemented in the leaf itself:
#
#   1. Thread level — reviewThreads(first: 100, after: $threadCursor) with
#      pageInfo{hasNextPage,endCursor}; loop while hasNextPage, appending
#      nodes in arrival order.
#   2. Comment level — each thread's comments(first: 100) selects its own
#      pageInfo; a thread whose hasNextPage=true gets a follow-up
#      node(id: $threadId) query walking comments(after: $commentCursor)
#      the same way. Additional nodes append to that thread in arrival order.
#
# Pages merge BEFORE the jq normalization so the output stays byte-compatible
# with the pre-#401 single-page contract when the PR fits in one page.
#
# Bounded walk: PAGE_CAP=50 pages per level (≈5000 threads or 5000 comments in
# one thread) guards a pathological/hostile backend against a wrapper-lane hang.
# Cap-hit is loud rc != 0 — never silent truncation.
#
# Fail-closed [#401 R2]: every `gh api graphql` call is captured and its exit
# checked BEFORE merging. In addition, EACH page's response is validated:
#   (a) `.errors` must be absent/empty — GraphQL can return rc=0 with a
#       populated errors array + partial/null `data`; that is a semantic
#       failure the walk cannot recover from.
#   (b) The required connection paths (thread level:
#       `data.repository.pullRequest.reviewThreads.{nodes,pageInfo,pageInfo.hasNextPage}`;
#       comment level: `data.node.comments.{nodes,pageInfo,pageInfo.hasNextPage}`)
#       must exist non-null with the correct jq types. No `// []` / `// false`
#       defaults on required fields — those exist to paper over exactly this
#       class of failure. A null pullRequest, missing reviewThreads
#       connection, or missing pageInfo → rc != 0 with NO partial stdout.
# Any mid-walk failure discards the accumulator and returns rc != 0 — a
# partial thread set would recreate the silent-truncation bug under a
# different name. Mirrors chp_github_count_reviews_by_login's
# capture-check-sum pattern ([INV-94]).
#
# Positional validation (W1e convention, #400): PR must be a non-empty numeric
# identifier (`^[0-9]+$`). Missing/empty/non-numeric → rc 2, loud stderr, NO
# gh call.
chp_github_review_threads() {
  local pr="${1:-}"
  # Positional validation (W1e convention, #400): PR must be a non-empty numeric
  # identifier (`^[0-9]+$`). Missing/empty/non-numeric → rc 2, loud stderr, NO
  # gh call. `resolve-threads.sh` (sole caller) takes PR from its $3 positional
  # so an empty/non-numeric value is operator misuse, never a legitimate value.
  [[ "$pr" =~ ^[0-9]+$ ]] || { echo "ERROR: chp_github_review_threads requires PR (1st arg, non-empty numeric): got '${pr}'" >&2; return 2; }
  local owner="${REPO%%/*}" name="${REPO##*/}"
  local page_cap=50

  local thread_query='
query($owner: String!, $repo: String!, $prNumber: Int!, $threadCursor: String) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $prNumber) {
      reviewThreads(first: 100, after: $threadCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          comments(first: 100) {
            pageInfo { hasNextPage endCursor }
            nodes {
              databaseId
              path
              line
              originalLine
              author { login }
              body
              createdAt
            }
          }
        }
      }
    }
  }
}'

  # Accumulator of raw thread nodes (JSON per line) — merged in arrival order.
  local acc_threads='[]'
  local thread_cursor='' page_out has_next end_cursor page=0 rc
  while : ; do
    page=$((page + 1))
    if [ "$page" -gt "$page_cap" ]; then
      echo "chp_github_review_threads: page cap ($page_cap) exceeded (thread level, PR #$pr)" >&2
      return 1
    fi
    if [ -z "$thread_cursor" ]; then
      page_out=$(gh api graphql \
        -F owner="$owner" -F repo="$name" -F "prNumber=$pr" \
        -f query="$thread_query")
    else
      page_out=$(gh api graphql \
        -F owner="$owner" -F repo="$name" -F "prNumber=$pr" \
        -F threadCursor="$thread_cursor" \
        -f query="$thread_query")
    fi
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echo "chp_github_review_threads: gh api graphql failed at thread page $page (rc=$rc, PR #$pr)" >&2
      return "$rc"
    fi
    # Fail-closed validation (#401 R2 hardening). GraphQL can return rc=0 with
    # a populated `errors` array + partial/null `data` — treat that as failure
    # (no `// []` / `// false` defaults papering over missing required paths).
    if ! jq -e '.errors == null and (.errors|not or (.errors|length) == 0)' <<<"$page_out" >/dev/null 2>&1; then
      # (.errors|not) guards against `errors: null`; the length==0 arm covers
      # `errors: []`. Together: pass only when NO errors are reported.
      local _err_summary
      _err_summary=$(jq -r '(.errors // []) | map(.message // "unknown") | join("; ")' <<<"$page_out" 2>/dev/null | head -c 200)
      echo "chp_github_review_threads: GraphQL errors on thread page $page (PR #$pr): $_err_summary" >&2
      return 1
    fi
    # Every required response path MUST exist (non-null). No defaults — a null
    # pullRequest, missing reviewThreads connection, or missing pageInfo is a
    # semantic failure the walk cannot recover from.
    if ! jq -e '
      .data                                              != null
      and .data.repository                               != null
      and .data.repository.pullRequest                   != null
      and .data.repository.pullRequest.reviewThreads     != null
      and (.data.repository.pullRequest.reviewThreads.nodes    | type == "array")
      and (.data.repository.pullRequest.reviewThreads.pageInfo | type == "object")
      and (.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage | type == "boolean")
    ' <<<"$page_out" >/dev/null 2>&1; then
      echo "chp_github_review_threads: malformed/incomplete response at thread page $page (PR #$pr; required data.repository.pullRequest.reviewThreads.{nodes,pageInfo} missing/null)" >&2
      return 1
    fi
    # Merge this page's nodes into the accumulator (required path — no default).
    if ! acc_threads=$(jq -c --argjson acc "$acc_threads" \
      '$acc + .data.repository.pullRequest.reviewThreads.nodes' \
      <<<"$page_out"); then
      echo "chp_github_review_threads: jq merge failed at thread page $page (PR #$pr)" >&2
      return 1
    fi
    has_next=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage' <<<"$page_out")
    end_cursor=$(jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // ""' <<<"$page_out")
    if [ "$has_next" != "true" ]; then
      break
    fi
    if [ -z "$end_cursor" ] || [ "$end_cursor" = "null" ]; then
      echo "chp_github_review_threads: hasNextPage=true but endCursor empty (thread level, PR #$pr)" >&2
      return 1
    fi
    thread_cursor="$end_cursor"
  done

  # Comment-level walk for any thread reporting comments.pageInfo.hasNextPage.
  local comment_query='
query($threadId: ID!, $commentCursor: String) {
  node(id: $threadId) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $commentCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          databaseId
          path
          line
          originalLine
          author { login }
          body
          createdAt
        }
      }
    }
  }
}'
  local idx count thread_id start_cursor comment_page comment_out
  count=$(jq 'length' <<<"$acc_threads")
  idx=0
  while [ "$idx" -lt "$count" ]; do
    if [ "$(jq -r ".[$idx].comments.pageInfo.hasNextPage // false" <<<"$acc_threads")" = "true" ]; then
      thread_id=$(jq -r ".[$idx].id" <<<"$acc_threads")
      start_cursor=$(jq -r ".[$idx].comments.pageInfo.endCursor // \"\"" <<<"$acc_threads")
      if [ -z "$start_cursor" ] || [ "$start_cursor" = "null" ]; then
        echo "chp_github_review_threads: comments.hasNextPage=true but endCursor empty (thread $thread_id, PR #$pr)" >&2
        return 1
      fi
      local cur="$start_cursor"
      comment_page=0
      while : ; do
        comment_page=$((comment_page + 1))
        if [ "$comment_page" -gt "$page_cap" ]; then
          echo "chp_github_review_threads: page cap ($page_cap) exceeded (comment level, thread $thread_id, PR #$pr)" >&2
          return 1
        fi
        comment_out=$(gh api graphql \
          -F "threadId=$thread_id" \
          -F commentCursor="$cur" \
          -f query="$comment_query")
        rc=$?
        if [ "$rc" -ne 0 ]; then
          echo "chp_github_review_threads: gh api graphql failed at comment page $comment_page (thread $thread_id, PR #$pr, rc=$rc)" >&2
          return "$rc"
        fi
        # Fail-closed validation (#401 R2 hardening) — no defaults on required
        # comment-page fields. .errors → rc≠0; null node / missing comments
        # connection / missing pageInfo → rc≠0.
        if ! jq -e '.errors == null and (.errors|not or (.errors|length) == 0)' <<<"$comment_out" >/dev/null 2>&1; then
          local _cerr_summary
          _cerr_summary=$(jq -r '(.errors // []) | map(.message // "unknown") | join("; ")' <<<"$comment_out" 2>/dev/null | head -c 200)
          echo "chp_github_review_threads: GraphQL errors on comment page $comment_page (thread $thread_id, PR #$pr): $_cerr_summary" >&2
          return 1
        fi
        if ! jq -e '
          .data                             != null
          and .data.node                    != null
          and .data.node.comments           != null
          and (.data.node.comments.nodes    | type == "array")
          and (.data.node.comments.pageInfo | type == "object")
          and (.data.node.comments.pageInfo.hasNextPage | type == "boolean")
        ' <<<"$comment_out" >/dev/null 2>&1; then
          echo "chp_github_review_threads: malformed/incomplete response at comment page $comment_page (thread $thread_id, PR #$pr; required data.node.comments.{nodes,pageInfo} missing/null)" >&2
          return 1
        fi
        if ! acc_threads=$(jq -c --argjson pageResp "$comment_out" --argjson i "$idx" '
          .[$i].comments.nodes += $pageResp.data.node.comments.nodes
          | .[$i].comments.pageInfo = $pageResp.data.node.comments.pageInfo
        ' <<<"$acc_threads"); then
          echo "chp_github_review_threads: jq merge failed at comment page $comment_page (thread $thread_id, PR #$pr)" >&2
          return 1
        fi
        has_next=$(jq -r '.data.node.comments.pageInfo.hasNextPage' <<<"$comment_out")
        if [ "$has_next" != "true" ]; then
          break
        fi
        cur=$(jq -r '.data.node.comments.pageInfo.endCursor // ""' <<<"$comment_out")
        if [ -z "$cur" ] || [ "$cur" = "null" ]; then
          echo "chp_github_review_threads: comments.hasNextPage=true but endCursor empty (thread $thread_id, PR #$pr, page $comment_page)" >&2
          return 1
        fi
      done
    fi
    idx=$((idx + 1))
  done

  # Normalize the assembled COMPLETE tree once. Shape byte-compatible with
  # today's single-page output (the pre-#401 --jq filter, applied to the
  # merged accumulator).
  jq -c '
    [ .[] | { thread_id: .id,
              resolved: .isResolved,
              comments: [ .comments.nodes[]
                          | { id: .databaseId,
                              path: .path,
                              line: (.line // .originalLine),
                              author: (.author.login // null),
                              body: (.body // ""),
                              createdAt: .createdAt } ] } ]
  ' <<<"$acc_threads"
}

# chp_github_resolve_thread THREAD_ID — resolve one review thread.
#
# Spec §3.2 [M8]: the resolveReviewThread mutation (resolve-threads.sh:73-78).
# Echoes the post-mutation `isResolved` (`true`/`false`) so the caller's
# resolved/failed tally is byte-identical. THREAD_ID is the GraphQL thread node
# id (from chp_github_review_threads' `.thread_id`).
#
# Positional validation (W1e convention, #400): THREAD_ID must be non-empty.
# Missing/empty → rc 2, loud stderr, NO gh call. `resolve-threads.sh` (sole
# caller) already gates on `[ -n "$thread_id" ]` before dispatch, so empty is
# operator/programming misuse, never a legitimate value. `gh api graphql -F
# threadId=""` would 400 at the GraphQL layer (`$threadId: ID!` is non-null),
# but failing fast at the seam is the W1e-convention posture.
chp_github_resolve_thread() {
  local thread_id="${1:-}"
  [ -n "$thread_id" ] || { echo "ERROR: chp_github_resolve_thread requires THREAD_ID (1st arg, non-empty)" >&2; return 2; }
  gh api graphql \
    -F threadId="$thread_id" \
    -f query='
mutation($threadId: ID!) {
  resolveReviewThread(input: {threadId: $threadId}) {
    thread { isResolved }
  }
}' --jq '.data.resolveReviewThread.thread.isResolved'
}

# chp_github_trigger_bot PR TRIGGER — post a review-bot trigger as a real user.
#
# Spec §3.2: the bot-trigger post. Gated by the `review_bots` cap (§4.2): when
# `review_bots=0` (e.g. GitLab, no native slash-command registry) this verb is a
# no-op (the caller relies on the in-process review agent only) — that branch is
# a CALLER-side check on `chp_caps review_bots`. `parse_review_bots` / the
# login mapping (lib-review-bots.sh) STAY caller-side.
#
# GitHub's built-in review bots (q/codex/claude) REJECT GitHub-App-attributed
# comments, so the trigger MUST be posted by a REAL user via gh-as-user.sh (which
# reads GH_USER_PAT from the wrapper shell) — the path the wrapper-side broker
# (drain_agent_bot_triggers, lib-auth.sh) calls this verb to perform.
#
# gh-as-user.sh resolution mirrors the broker's BYTE-IDENTICALLY: the PROJECT-side
# scripts dir first (`_LIB_AUTH_DIR`, else `AUTONOMOUS_CONF_DIR`) — the same place
# the broker resolved it and the same place the agent's `bash scripts/gh-as-user.sh`
# would find it (so the project's own gh-wrapper PATH is honored) — then this
# provider file's own skill-tree dir as a fallback. Echoes nothing; returns the
# `gh-as-user.sh` exit status so the broker's per-line posted/failed tally is
# preserved.
chp_github_trigger_bot() {
  local pr="$1" trigger="$2"
  local _self _skill_dir gh_as_user="" _d
  _self="${BASH_SOURCE[0]:-$0}"
  _skill_dir="$(cd "$(dirname "$(readlink -f "$_self")")/.." && pwd 2>/dev/null)" || _skill_dir=""
  for _d in "${_LIB_AUTH_DIR:-}" "${AUTONOMOUS_CONF_DIR:-}" "$_skill_dir"; do
    [[ -n "$_d" && -f "${_d}/gh-as-user.sh" ]] && { gh_as_user="${_d}/gh-as-user.sh"; break; }
  done
  if [[ -z "$gh_as_user" ]]; then
    echo "WARN: chp_github_trigger_bot: gh-as-user.sh not found — cannot post bot trigger as a real user." >&2
    return 1
  fi
  bash "$gh_as_user" pr comment "$pr" --repo "$REPO" --body "$trigger"
}

# chp_github_close_keyword ISSUE — render the PR-body auto-close keyword.
#
# Spec §3.2 [M4]: GitHub returns the literal `Closes #<ISSUE>` the prompt builder
# interpolates so a merged PR auto-transitions the issue (merge_closes_issue=1).
# A backend with `merge_closes_issue=0` returns empty (the caller transitions
# explicitly post-merge) — that empty-string branch is the CALLER's
# `chp_caps merge_closes_issue` check; the GitHub leaf always renders the keyword.
chp_github_close_keyword() {
  local issue="$1"
  printf 'Closes #%s' "$issue"
}

# chp_github_reply_review_comment PR COMMENT_ID BODY — reply to one PR review
# comment ([INV-96], #327). The program's LAST raw `gh api …pulls/<n>/comments
# -X POST … in_reply_to=…` site (reply-to-comments.sh:41) moves here BYTE-
# IDENTICALLY. The caller (reply-to-comments.sh) composes `REPO="$OWNER/$REPO"`
# before invoking the verb, so the endpoint path `repos/${REPO}/pulls/${pr}/
# comments` is byte-identical to today's `repos/$OWNER/$REPO/pulls/$PR_NUMBER/
# comments`; the owner/repo arg split + the COMMENT_ID `sed 's/[^0-9]//g'`
# sanitization stay caller-side.
#
# No injection pre-encode: `body` is a REST `-f` field (form-encoded, not a jq
# pattern); `in_reply_to` is a REST `-F` field (caller-sanitized numeric); the
# `--jq '{id: .id, url: .html_url}'` is a fixed literal with zero `${var}`
# interpolation (contrast the injection-prone chp_count_reviews_by_login /
# itp_label_event_ts leaves that JSON-encode their arg). Echoes `{id, url}`.
chp_github_reply_review_comment() {
  local pr="$1" comment_id="$2" body="$3"
  gh api "repos/${REPO}/pulls/${pr}/comments" \
    -X POST -f body="$body" -F in_reply_to="$comment_id" \
    --jq '{id: .id, url: .html_url}'
}

# chp_github_pr_view PR FIELDS_CSV — PR read leaf, NORMALIZED shape (#347 W1c2, #398).
#
# Returns a SINGLE normalized JSON object projected to EXACTLY the fields named
# in FIELDS_CSV (per the W1c1 PR-field vocabulary — provider-spec.md §3.2). The
# leaf owns the gh argv and the normalization jq; no gh flags or jq programs
# cross the seam ([INV-87]). rc≠0 fail-closed on not-found / query failure (no
# partial output); the shim's self-guarding posture and each caller's own
# `|| true` / `|| echo UNKNOWN` fail-soft framing stay unchanged.
#
# FIELDS_CSV is a comma-separated list of vocabulary field names. Requested
# fields that are 1:1 in `gh pr view --json` (`number`, `state`, `title`,
# `body`, `createdAt`, `updatedAt`, `mergedAt`, `headRefName`, `headRefOid`,
# `reviewDecision`, `mergeable`) are projected verbatim. `comments` normalizes
# to `[{id, author, body, createdAt}]` ascending by `createdAt`, `reviews` to
# `[{author, state, submittedAt}]` ascending by `submittedAt`, and
# `closingIssueNumbers` folds the raw `closingIssuesReferences` collection to
# an int array (the GitHub-internal shape does not cross the seam). `body`
# is normalized from null → "" per the vocabulary.
#
# `closingIssuesReferences` accepts BOTH shapes gh can produce: the FLAT array
# `[{number}]` that real `gh pr view --json closingIssuesReferences` returns
# (verified against lib-pr-linkage.sh:85 which selects `.closingIssuesReferences[]?
# | .number` — the pre-existing repo-wide idiom), AND the GraphQL cursor shape
# `{nodes:[{number}]}` some raw queries emit. The `(.…nodes // .… // [])` fold
# picks whichever is present; a null / absent field folds to `[]`.
#
# Fail-CLOSED (P1-2, codex pre-review): captures gh stdout, checks BOTH its
# exit status AND that stdout is non-empty AND parses as a JSON object BEFORE
# projecting. An empty rc-0 stdout (transient/permission failure that gh
# silently swallows without emitting an error) becomes rc≠0 with no partial
# output — the caller's `|| true` / `|| echo UNKNOWN` framing degrades to
# empty/UNKNOWN, never treats a silent gh failure as a real answer.
#
# Rationale (spec §3.2): the caller layer's incidental PR reads
# (preview-URL/headRefName/headRefOid/state/comments/reviews projections at
# autonomous-dev.sh / autonomous-review.sh / lib-review-e2e.sh) become plain
# jq over the normalized object; a GitLab leaf can emit the same shape without
# emulating gh field names.
#
# W1c2 online-review r1 fix: FIELDS_CSV is validated against the full §3.2.1
# PR-field vocabulary (14 members) BEFORE the gh argv is built. Unknown /
# GitHub-native names (e.g. the raw `closingIssuesReferences` — the internal
# mapping target of the vocabulary's `closingIssueNumbers`) → rc 2 with a
# loud stderr naming the offending field. This mirrors the W1c1 pair's
# `_CHP_GITHUB_PR_FIELDS_SUPPORTED` gate (chp-github.sh:107); unlike W1c1
# (which rejects `comments`), `chp_pr_view`'s single-PR `gh pr view --json`
# read delivers every vocabulary member natively, so the supported set here
# is the FULL 14-member vocabulary. Guarded `readonly` for the same reason
# as `_CHP_GITHUB_PR_FIELDS_SUPPORTED` — a transitive re-source of
# lib-code-host.sh must not abort on `readonly variable`.
declare -p _CHP_GITHUB_PR_VIEW_FIELDS_SUPPORTED >/dev/null 2>&1 || \
  readonly _CHP_GITHUB_PR_VIEW_FIELDS_SUPPORTED="number,state,title,body,createdAt,updatedAt,mergedAt,headRefName,headRefOid,reviewDecision,mergeable,closingIssueNumbers,comments,reviews"

chp_github_pr_view() {
  local pr="$1" fields_csv="${2:-}"
  [ -n "$fields_csv" ] || { echo "ERROR: chp_github_pr_view requires FIELDS_CSV (2nd arg) [W1c2]" >&2; return 2; }

  # Map requested vocabulary fields to gh raw fields. Most map 1:1; the two
  # non-1:1 fields are closingIssueNumbers (raw: closingIssuesReferences) and
  # body (raw: body, null→"" at the jq level).
  local gh_fields="" out_field first=1
  # Build the raw --json list and the jq object body.
  local IFS_SAVED="$IFS"; IFS=','
  # shellcheck disable=SC2206
  local requested=(${fields_csv})
  IFS="$IFS_SAVED"

  local f _seen_map=""
  local _obj_body=""
  for f in "${requested[@]}"; do
    f="${f#"${f%%[![:space:]]*}"}"; f="${f%"${f##*[![:space:]]}"}"   # trim
    [ -z "$f" ] && continue
    # W1c2 online-review r1 blocking: gate on the §3.2.1 vocabulary BEFORE
    # building gh argv. A GitHub-native field name (e.g. `closingIssuesReferences`,
    # the internal mapping target) or an unknown/typo name must be REJECTED
    # LOUDLY, never passed through — otherwise a caller can silently depend on
    # GitHub-only names a non-GitHub provider cannot deliver. Mirrors the W1c1
    # pair's `_CHP_GITHUB_PR_FIELDS_SUPPORTED` gate at chp-github.sh:107. This
    # verb's supported set is the FULL §3.2.1 vocabulary (14 members —
    # `chp_pr_view`'s single-PR `gh pr view --json` read delivers each natively,
    # unlike the W1c1 list-walk that rejects `comments`).
    case ",${_CHP_GITHUB_PR_VIEW_FIELDS_SUPPORTED}," in
      *",$f,"*) : ;;
      *) echo "ERROR: chp_github_pr_view: field '$f' is not in the §3.2.1 vocabulary ($_CHP_GITHUB_PR_VIEW_FIELDS_SUPPORTED). GitHub-native names (e.g. 'closingIssuesReferences') MUST use the vocabulary name (e.g. 'closingIssueNumbers') so a non-GitHub provider can deliver the same shape." >&2; return 2 ;;
    esac
    case "$f" in
      closingIssueNumbers) out_field="closingIssuesReferences" ;;
      *)                   out_field="$f" ;;
    esac
    # De-dup the raw field list (a caller repeating a vocabulary field, or
    # requesting both `body` twice, must not send two entries to `gh --json`).
    if [[ ",${_seen_map}," != *",${out_field},"* ]]; then
      _seen_map="${_seen_map:+${_seen_map},}${out_field}"
      gh_fields+="${gh_fields:+,}${out_field}"
    fi
    # jq projection for this normalized field.
    local expr
    case "$f" in
      body)
        expr='body: (.body // "")'
        ;;
      comments)
        expr='comments: ([ .comments[]? | { id: (.id // null), author: ((.author | if type == "object" then .login else . end) // null), body: (.body // ""), createdAt: (.createdAt // null) } ] | sort_by(.createdAt // "", .id // 0))'
        ;;
      reviews)
        expr='reviews: ([ .reviews[]? | { author: ((.author | if type == "object" then .login else . end) // null), state: (.state // null), submittedAt: (.submittedAt // null) } ] | sort_by(.submittedAt // ""))'
        ;;
      closingIssueNumbers)
        # Accept BOTH the flat `.closingIssuesReferences[]` gh shape (the pre-
        # existing repo-wide idiom, lib-pr-linkage.sh:85 anchor) AND the
        # `{nodes:[…]}` cursor shape some GraphQL paths emit. `if type ==
        # "object" then .nodes else . end` picks the right form without ever
        # dereferencing `.nodes` on an array (which raises jq's "Cannot index
        # array with string" — P1-1 codex fix). Null/absent → `[]`.
        expr='closingIssueNumbers: ([ ((.closingIssuesReferences // []) | (if type == "object" then (.nodes // []) else . end))[]? | .number ])'
        ;;
      *)
        # 1:1 vocabulary field — emit `name: .name`.
        expr="${f}: .${f}"
        ;;
    esac
    if [[ $first -eq 1 ]]; then first=0; else _obj_body+=", "; fi
    _obj_body+="$expr"
  done
  local norm_program="{ ${_obj_body} }"

  # P1-2 (codex pre-review): capture-then-check. gh's own `--jq` filter is NOT
  # applied here — we bring the raw JSON back into the leaf so we can validate
  # non-empty + valid-object shape BEFORE handing bad input to jq (which would
  # otherwise emit its own error and rc≠0 with no context). A real "no such PR"
  # / permission failure from gh returns rc≠0, which the `|| return 1`
  # propagates. A rc-0 empty stdout (silent gh failure — reproducible via
  # `gh(){ return 0; }`) is caught by the `-n` and the `jq -e … type=="object"`
  # guard: any of the three failure modes yields rc≠0 with empty stdout, so the
  # caller's fail-soft framing degrades correctly.
  local raw
  raw=$(gh pr view "$pr" --repo "$REPO" --json "$gh_fields") || return 1
  [[ -n "$raw" ]] || return 1
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$raw" || return 1
  jq -c "$norm_program" <<<"$raw"
}

# chp_github_pr_list STATE FIELDS-CSV — normalized PR-list read leaf.
#
# Spec §3.2 (W1c1, #397): return a NORMALIZED JSON ARRAY of PRs in STATE,
# PROJECTION-ONLY to the caller-supplied FIELDS-CSV. STATE ∈
# `open|closed|merged|all` (case-insensitive at the seam; the GitHub leaf
# maps to GraphQL `PullRequestState` list). Vocabulary is §3.2.1 minus the
# `comments`/`reviews` fields (owned by the sibling W1c2 chp_pr_view leaf —
# `pullRequests(first:100)` cannot deliver them here; requesting them → rc 2
# loudly). No fabricated fields — see `_chp_github_pr_projection_jq`.
#
# DISTINCT from `chp_find_pr_for_issue`: no issue-narrowing hint, no forced
# union with the resolution keys. The body-mention `#N`-boundary `test()` is
# caller-side (each of the six body-mention sites keeps its own regex over
# the normalized `body` string). Empty match set → `[]` (NEVER null; the #148
# hazard fix — `body:null` sibling PR is normalized to `body:""` here so the
# caller's `.body | test(…)` never aborts).
#
# COMPLETE-set (§3.5): same TRUE cursor page walk as `chp_find_pr_for_issue`
# via `_chp_github_pr_fetch_all` (`pullRequests(first:100, after:$cursor)`
# until `pageInfo.hasNextPage=false`, bounded by
# `CHP_GITHUB_PR_LIST_PAGE_CAP`, default 20 pages / 2000 PRs). Cap-hit before
# exhaustion → rc≠0 no output. Fail-CLOSED on `gh` transport error / empty
# stdout / non-JSON / non-array. Closes the pre-W1c1 silent `--limit 30`
# truncation hazard that could make `needs_open_pr_only` misclassify a
# >30-open-PR repo.
chp_github_pr_list() {
  local state="${1:-}" fields="${2:-}"
  [ -n "$state" ]  || { echo "ERROR: chp_github_pr_list requires STATE (1st arg)" >&2; return 2; }
  [ -n "$fields" ] || { echo "ERROR: chp_github_pr_list requires FIELDS-CSV (2nd arg)" >&2; return 2; }
  local state_lc
  state_lc="$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"
  case "$state_lc" in
    open|closed|merged|all) : ;;
    *) echo "ERROR: chp_github_pr_list STATE must be one of open|closed|merged|all (got '$state')" >&2; return 2 ;;
  esac
  # Parse + validate the caller's fields. Rejects `comments`/`reviews` (rc 2
  # loud — the sibling W1c2 chp_pr_view handles those); no forced resolver-
  # key union (this is the general body-mention list read, not the linkage
  # resolver).
  local _CHP_PARSED_FIELDS
  _chp_github_pr_parse_fields "$fields" || return $?
  local gh_fields projection nodes
  gh_fields="$(_chp_github_pr_gh_fields "$_CHP_PARSED_FIELDS")"
  nodes="$(_chp_github_pr_fetch_all "$(_chp_github_pr_state_filter "$state_lc")" "$gh_fields")" || return 1
  projection="$(_chp_github_pr_projection_jq "$_CHP_PARSED_FIELDS")"
  jq -c "$projection" <<<"$nodes"
}

# chp_github_list_inline_comments PR — PR inline (file-anchored) review-comment
# read leaf, NORMALIZED + COMPLETE (#347 W1c2, #398; supersedes #328).
#
# Returns ONE merged normalized flat array `[{id, path, line, author, body,
# createdAt}]` ascending by `createdAt` (id tie-break). `line` is the leaf-side
# `line // original_line // null` fold — `original_line` no longer crosses the
# seam; the caller renders `.line // "N/A"` over the normalized field. `body`
# is normalized null → "".
#
# COMPLETE via page walk. IMPLEMENTATION TRAP: `gh api --paginate --jq '[…]'`
# emits ONE ARRAY PER PAGE (a stream of concatenated arrays), NOT one merged
# array. So we capture the raw paginated stream (JSON as gh returned it, one
# object array per REST page concatenated) THEN slurp/merge/sort/normalize
# with a single jq pass. fail-CLOSED (rc≠0, no partial output) if any page
# fetch fails.
#
# Rationale (spec §3.2 [INV-95]): the dev-resume prompt builder's
# `PR_REVIEW_COMMENTS` read (autonomous-dev.sh) — the comments the dev agent
# is told to address + reply-to + resolve — becomes plain jq over the
# normalized flat array; the pre-#398 leaf silently truncated at gh's
# REST-default first-page-of-30, so >30 inline comments vanished from the
# dev-resume prompt. The distinct shapes remain: `chp_review_threads` (the
# GraphQL thread tree) / `chp_pr_view` (no `pulls/N/comments` sub-resource) /
# `itp_list_comments` (issue-level normalized). The `.path`/`.line` inline
# fields are CHP-owned and NEVER folded into the ITP issue-comment shape.
chp_github_list_inline_comments() {
  local pr="$1"
  # `gh api --paginate` echoes each page's raw JSON array to stdout in sequence.
  # Its exit status is non-zero if any page fetch fails — captured separately
  # so we can fail-CLOSED (rc≠0, no partial output) rather than let a
  # partial-pagination stream through.
  local raw
  raw=$(gh api "repos/${REPO}/pulls/${pr}/comments" --paginate 2>/dev/null) || return 1
  # P2-3 (codex pre-review) fail-CLOSED on empty stdout: a real
  # zero-comment PR emits the literal JSON `[]` from `gh api`, NOT an empty
  # string. Empty stdout with rc=0 (reproducible via `gh(){ return 0; }`) is a
  # silent gh failure the caller must distinguish from "no inline comments" —
  # otherwise the dev-resume prompt would treat a broken fetch as "nothing to
  # address" and skip the entire review-feedback block. Reject empty raw
  # stdout here so the caller's `|| true` framing degrades to empty
  # PR_REVIEW_COMMENTS, matching the shim's own leaf-absent WARN + rc 1
  # convention.
  [[ -n "$raw" ]] || return 1
  # Non-array page rejection (online-review r2, blocking): validate BEFORE the
  # merge/normalize pass. `gh api --paginate` returning any rc-0 JSON OBJECT
  # (e.g. `{}` on an unexpected shape, or `{"message":"Not Found"}` on a
  # permission failure that gh's error path fell through — reproduced on-box)
  # would previously slip through as `[]` (`add // []` on a non-array `add`
  # picks the alt), fail-open into "no inline comments" in the dev-resume
  # prompt, silently dropping review feedback. Two-stage guard: (1) slurp the
  # concatenated page stream into an array-of-pages and check every page has
  # `type == "array"`; if not, exit with rc 1 and no stdout. (2) Only when
  # every page IS an array, run the real merge+normalize pass. A real
  # zero-comment PR emits `[]` on each page (still passes `type == "array"`),
  # so the empty-response contract is preserved (rc 0 + `[]`).
  local _pages_ok
  _pages_ok=$(jq -r --slurp 'all(type == "array")' <<<"$raw" 2>/dev/null) || return 1
  [[ "$_pages_ok" == "true" ]] || return 1
  jq -c --slurp '
    (add // []) |
    [ .[]? | {
        id: (.id // null),
        path: (.path // null),
        line: (.line // .original_line),
        author: ((.user | if type == "object" then .login else . end) // null),
        body: (.body // ""),
        createdAt: (.created_at // null)
      } ] |
    sort_by(.createdAt // "", .id // 0)
  ' <<<"$raw"
}

# chp_github_count_reviews_by_login REPO PR LOGIN — count a login's PR reviews (#324).
#
# Spec §3.2 [INV-94]: the leaf behind the [INV-79] wrapper bot-review hard-gate
# (lib-review-bots.sh::missing_bot_reviews). Returns the INTEGER count of reviews on
# PR (in REPO) by LOGIN, across ALL pages, or 0 on ANY failure. The `--paginate` +
# `awk '{s+=$1}'` sum is a GitHub-transport artifact (`--jq '|length'` emits one
# length per page) with no provider-neutral meaning — encapsulated here; the
# caller-side `^[0-9]+$` validation + the `-eq 0` MISSING decision STAY caller-side,
# mirroring chp_github_mergeable's leaf-returns-raw / classify-caller-side split.
#
# REPO is an EXPLICIT 1st parameter (NOT global $REPO): the caller threads its own
# `repo=$3`, so the verb mirrors that — a global-$REPO verb would query the wrong
# repo if they ever differ (correctness-by-construction).
#
# Injection-safe: a raw ${login} spliced into the `--jq` string literal is a jq
# injection (a login bearing `"` widens/breaks the selector). LOGIN is JSON-encoded
# via a SEPARATE jq pass; the `--arg` name MUST be non-reserved (jq-1.6 reserves
# `label` etc., NOT `loginarg`), and the reviews-endpoint read tool has no `--arg`,
# so pre-encoding is the only path. For `github-actions[bot]` the encoded literal is
# `"github-actions[bot]"` — count-equivalent to the pre-#324 inline leaf.
#
# Fail-SAFE: the leaf CAPTURES the read output, CHECKS its exit, THEN sums. Piping
# the read straight into `awk` (the pre-#324 inline leaf) swallowed the exit, so a
# partial-pagination stream (page-1 length emitted, page-2 errors) was summed →
# count>0 → false PRESENT → fail-OPEN at the hard-gate. Here a non-zero exit → 0 →
# the caller counts the bot MISSING → blocks the PASS. Every failure path (non-zero
# exit, encode error) → 0.
chp_github_count_reviews_by_login() {
  local repo="$1" pr="$2" login="$3" login_json lengths
  login_json="$(jq -rn --arg loginarg "$login" '$loginarg | @json' 2>/dev/null)" || { echo 0; return 0; }
  lengths="$(gh api "repos/${repo}/pulls/${pr}/reviews" --paginate \
    --jq "[.[] | select(.user.login == ${login_json})] | length" 2>/dev/null)" \
    || { echo 0; return 0; }
  awk '{s+=$1} END {print s+0}' <<<"$lengths"
}

# chp_github_commit_file REPO BRANCH FILE_PATH CONTENT_BASE64 MESSAGE — commit a
# single file onto a branch and echo the committed blob SHA (#330, [INV-99]).
#
# Spec §3.2: the WHOLE-OP CHP write verb behind upload-screenshot.sh. GitHub has
# no single "commit one file to an (orphan) branch" primitive, so the leaf is the
# 8-call git-Data-API implementation of that ONE op (get-ref → blob → tree →
# commit → ref → re-get-ref verify → get-contents → put-contents) — exactly the
# `chp_review_threads`-wraps-a-whole-GraphQL-walk posture. A GitLab backend
# collapses the same op into a single Files API call. The body is the pre-#330
# upload-screenshot.sh lines 76-134 VERBATIM (the no-behavior-change anchor),
# with two deliberate deltas:
#
#   - REPO is the EXPLICIT $1 (NOT a global $REPO): upload-screenshot.sh is a
#     standalone util that resolves its own $REPO from autonomous.conf and never
#     sources the wrapper env, so threading it as an arg keeps a stray ambient
#     $REPO from silently winning (the #324 dropped-repo-arg lesson).
#   - the temp-file cleanup uses a **function-scoped, SELF-DISARMING**
#     `trap '…; trap - RETURN' RETURN` (issue #330 AC2) — NOT the script's
#     `trap … EXIT`. A sourced function's `trap … EXIT` REPLACES the caller's
#     EXIT trap, and the now-local temp vars expand empty when it fires at caller
#     exit (reproduced on-box: caller trap clobbered + `unbound variable` crash).
#     A BARE `trap … RETURN` (no self-disarm) has its OWN hazard: it is NOT
#     cleared when the leaf returns, so it PERSISTS on the trap table and fires
#     AGAIN when the calling `chp_commit_file` shim itself returns — by then the
#     leaf's `local` `$json_tmpfile` is out of scope → `unbound variable` under
#     the caller's `set -u` (reproduced on-box: the shim-dispatch path crashes).
#     The fix keeps the RETURN trap (satisfying AC2's function-scoped-RETURN
#     contract) but has the trap body its OWN LAST ACTION be `trap - RETURN` —
#     clearing itself the moment it fires for THIS invocation, so it never
#     lingers to fire a second time on the shim's own return. Verified on-box:
#     the trap cleans the leaf's temps at every return path (normal AND the
#     early `return 1`s) exactly once, across repeated shim-mediated calls, with
#     the caller's own EXIT trap firing normally afterward.
#
# Caller-side (provider-neutral, stays in upload-screenshot.sh): the local
# file-read + `base64 -w0` encode (CONTENT_BASE64 is the provider-neutral
# currency — GitLab's Files API also takes `encoding=base64`), the BRANCH /
# FILE_PATH / MESSAGE rendering, the `[[ -n "$SHA" ]] || fail`-on-empty-SHA glue,
# and the final `/blob/` URL echo + the `command -v gh`/`jq` presence guards.
#
# No jq injection: the `.ref // empty` / `.sha // empty` are leaf-internal
# CONSTANT jq filters; REPO/BRANCH/FILE_PATH/MESSAGE/CONTENT_BASE64 go into REST
# paths, the `?ref=` query, or the temp-file JSON payload — never a jq pattern.
#
# Echoes the committed blob SHA on success (rc 0); returns non-zero on commit
# failure (so the caller's `chp_commit_file … || fail` triggers).
chp_github_commit_file() {
  local repo="$1" branch="$2" file_path="$3" content_base64="$4" message="$5"

  # Ensure the orphan branch exists
  local branch_exists
  branch_exists=$(gh api "repos/${repo}/git/ref/heads/${branch}" 2>/dev/null | jq -r '.ref // empty' 2>/dev/null || true)

  if [[ -z "$branch_exists" ]]; then
    # Create orphan branch: blob → tree → commit → ref
    local readme_blob tree_sha commit_sha
    readme_blob=$(gh api "repos/${repo}/git/blobs" \
      -f content="Screenshots for PR E2E verification reports.\nThis branch is auto-managed — do not edit manually.\n" \
      -f encoding=utf-8 \
      --jq '.sha' 2>/dev/null) || true

    tree_sha=""
    [[ -n "$readme_blob" ]] && tree_sha=$(gh api "repos/${repo}/git/trees" \
      --jq '.sha' \
      -f "tree[][path]=README.md" \
      -f "tree[][mode]=100644" \
      -f "tree[][type]=blob" \
      -f "tree[][sha]=${readme_blob}" 2>/dev/null) || true

    commit_sha=""
    [[ -n "$tree_sha" ]] && commit_sha=$(gh api "repos/${repo}/git/commits" \
      -f message="chore: initialize screenshots branch" \
      -f "tree=${tree_sha}" \
      --jq '.sha' 2>/dev/null) || true

    [[ -n "$commit_sha" ]] && gh api "repos/${repo}/git/refs" \
      -f "ref=refs/heads/${branch}" \
      -f "sha=${commit_sha}" >/dev/null 2>&1 || true

    # Verify branch was created
    branch_exists=$(gh api "repos/${repo}/git/ref/heads/${branch}" 2>/dev/null | jq -r '.ref // empty' 2>/dev/null || true)
    [[ -n "$branch_exists" ]] || { echo "Error: failed to create orphan branch '${branch}'" >&2; return 1; }
  fi

  # Check if file already exists (need SHA for update)
  local existing_sha
  existing_sha=$(gh api "repos/${repo}/contents/${file_path}?ref=${branch}" 2>/dev/null | jq -r '.sha // empty' 2>/dev/null || true)

  # Build JSON payload via temp file to avoid ARG_MAX limit with large base64 content.
  # The base64 string for screenshots can exceed 128KB, which breaks shell argument passing.
  local json_tmpfile upload_response_file
  json_tmpfile=$(mktemp /tmp/screenshot-upload-XXXXXX.json)
  upload_response_file=$(mktemp /tmp/screenshot-response-XXXXXX.json)
  # Self-disarming function-scoped RETURN trap (#330 AC2 — see the header note):
  # cleans these temps at THIS invocation's return, then immediately clears
  # itself so it does NOT persist to fire again on the chp_commit_file shim's
  # own return (the bare-RETURN hazard reproduced on-box). The caller's EXIT
  # trap is never touched.
  trap 'rm -f "$json_tmpfile" "$upload_response_file"; trap - RETURN' RETURN

  {
    printf '{"message":"%s","content":"' "$message"
    printf '%s' "$content_base64"
    printf '","branch":"%s"' "$branch"
    if [[ -n "$existing_sha" ]]; then
      printf ',"sha":"%s"' "$existing_sha"
    fi
    printf '}'
  } > "$json_tmpfile"

  gh api "repos/${repo}/contents/${file_path}" \
    -X PUT \
    --input "$json_tmpfile" \
    > "$upload_response_file" 2>/dev/null || true

  local upload_sha
  upload_sha=$(jq -r '.content.sha // empty' "$upload_response_file" 2>/dev/null || true)
  # (temp cleanup happens via the self-disarming RETURN trap installed above,
  # at whichever of the two return paths below fires — #330 [INV-99] AC2 fix)

  [[ -n "$upload_sha" ]] || { echo "Error: GitHub API upload failed for ${file_path}" >&2; return 1; }

  printf '%s\n' "$upload_sha"
}

# chp_github_file_url REPO BRANCH FILE_PATH — render the browser blob URL (#419 R11).
#
# Spec §3.2: pure string render, NO HTTP — parallels chp_close_keyword's render
# pattern. Byte-identical to the pre-#419 upload-screenshot.sh:114 hardcode
# `https://github.com/${REPO}/blob/${BRANCH}/${FILE_PATH}`. The REPO positional
# is HONORED (not ignored) — the caller threads its own $REPO (mirrors
# chp_github_commit_file's explicit-$1 convention). No injection surface: pure
# printf, no jq / no HTTP call.
#
# Sibling of chp_gitlab_file_url (see providers/chp-gitlab.sh) — same signature,
# same render pattern, different host + path shape. The shim `chp_file_url` in
# lib-code-host.sh forwards "$@" to chp_${CODE_HOST}_file_url.
chp_github_file_url() {
  local repo="$1" branch="$2" file_path="$3"
  printf 'https://github.com/%s/blob/%s/%s' "$repo" "$branch" "$file_path"
}

# chp_github_pr_comment PR [extra gh args…] — general PR-comment WRITE leaf (#329).
#
# The PR-comment-write sibling of the chp_github_pr_view / chp_github_pr_list read
# primitives above (and shaped exactly like chp_github_approve). It is the
# provider-neutral comment-on-a-PR primitive the two HOT review files
# (autonomous-review.sh, lib-review-e2e.sh) route their auto-merge markers,
# E2E-failure reports, and the [INV-79] brokered E2E report through, so the caller
# layer carries ZERO raw "gh"+" pr comment".
#
# DISTINCT from itp_post_comment (the ISSUE-level machine-marker choke-point that
# posts on the issue): these post on a PR keyed by $PR_NUMBER. On GitHub a PR is an
# issue so the endpoints coincide, but seam ownership differs (issue-tracker vs
# code-host) — a split ISSUE_PROVIDER≠CODE_HOST topology routes them to different
# systems. They stay distinct verbs.
#
# A pure BYTE-IDENTICAL passthrough that adds NO redirects of its own: the 7
# callers use 4 different redirect/capture/gating framings (`… 2>/dev/null || true`,
# `if ! _err=$(… 2>&1 >/dev/null)`, `… 2>/dev/null || rc=$?`, broker
# `… >/dev/null 2>&1`); baking any redirect into the leaf would double or clobber
# them. The caller supplies the `--body <body>` tail (and any future `--body-file`/
# `--edit-last`) via "$@"; the leaf forwards it byte-identically. Bodies are
# pre-composed positional `--body` strings (no jq pattern) — no injection surface.
chp_github_pr_comment() {
  local pr="$1"; shift
  gh pr comment "$pr" --repo "$REPO" "$@"
}

# chp_github_pr_diffstat PR DIMENSIONS-CSV — diff-size read leaf (#452).
#
# GitHub's `gh pr view --json additions,deletions,changedFiles` returns ALL
# THREE fields together in ONE call — zero extra API cost regardless of which
# dimension(s) DIMENSIONS-CSV requests. So the leaf ALWAYS issues exactly one
# `gh pr view` call and PROJECTS ONLY the requested key(s) into the output —
# never fabricates the unrequested dimension. `changed_lines` is
# `additions + deletions` (the issue's definition of "changed lines").
#
# Fail-CLOSED via capture-then-check (mirrors chp_github_pr_view): rc≠0 on gh
# failure / empty stdout / non-object JSON / missing additions|deletions|
# changedFiles keys — no partial output, so the caller's per-dimension
# fail-open (over_reach=false for an unreadable stat) triggers honestly rather
# than computing over_reach against a zero/null this leaf never actually read.
chp_github_pr_diffstat() {
  local pr="${1:-}" dims="${2:-}"
  [[ "$pr" =~ ^[0-9]+$ ]] || { echo "ERROR: chp_github_pr_diffstat requires PR (1st arg, non-empty numeric): got '${pr}'" >&2; return 2; }
  [ -n "$dims" ] || { echo "ERROR: chp_github_pr_diffstat requires DIMENSIONS-CSV (2nd arg, non-empty subset of files,lines)" >&2; return 2; }
  local want_files=0 want_lines=0
  case ",${dims}," in *",files,"*) want_files=1 ;; esac
  case ",${dims}," in *",lines,"*) want_lines=1 ;; esac
  if [[ "$want_files" -eq 0 && "$want_lines" -eq 0 ]]; then
    echo "ERROR: chp_github_pr_diffstat: DIMENSIONS-CSV '${dims}' contains no recognized dimension (files|lines)" >&2
    return 2
  fi
  local raw
  raw=$(gh pr view "$pr" --repo "$REPO" --json additions,deletions,changedFiles 2>/dev/null) || return 1
  [[ -n "$raw" ]] || return 1
  jq -e 'type == "object" and (.additions|type)=="number" and (.deletions|type)=="number" and (.changedFiles|type)=="number"' >/dev/null 2>&1 <<<"$raw" || return 1
  jq -c --argjson wf "$want_files" --argjson wl "$want_lines" '
    (if $wf == 1 then {changed_files: .changedFiles} else {} end)
    + (if $wl == 1 then {changed_lines: (.additions + .deletions)} else {} end)
  ' <<<"$raw"
}
