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

# ---------------------------------------------------------------------------
# _chp_github_pr_normalize_jq — the jq filter both W1c1 (#397) PR-read leaves
# apply to gh's raw `pr list --json …` output. Kept as a bare-string constant
# (not a function) so it splices directly into the jq argv; the leaves then
# handle their own field-projection / gh call. Vocabulary is spec §3.2.1.
_CHP_GITHUB_PR_NORMALIZE_JQ='
  [ .[] | {
      number: .number,
      state: (.state // ""),
      title: (.title // ""),
      body: (.body // ""),
      createdAt: (.createdAt // null),
      updatedAt: (.updatedAt // null),
      mergedAt: (.mergedAt // null),
      headRefName: (.headRefName // ""),
      headRefOid: (.headRefOid // ""),
      reviewDecision: (.reviewDecision // ""),
      mergeable: (.mergeable // ""),
      closingIssueNumbers: ([ (.closingIssuesReferences // [])[]?.number ])
    }
  ]'

# _chp_github_pr_page_limit — the bounded page-walk `--limit` value both W1c1
# leaves pass to gh. `gh pr list --limit N` with N > 100 already page-walks
# under the hood (undocumented but load-bearing for W1a's list_by_state
# leaves), so we ask for `--limit (100 * cap)` and rely on gh's internal
# walker. Cap defaults to 20 pages → 2000 open PRs — comfortable upper bound
# on any real dispatcher workload. Fail-CLOSED on `gh` transport error
# (caller's `|| return 1`).
_chp_github_pr_page_limit() {
  local page_cap="${CHP_GITHUB_PR_LIST_PAGE_CAP:-20}"
  [[ "$page_cap" =~ ^[0-9]+$ ]] && (( page_cap > 0 )) || page_cap=20
  printf '%s' "$(( page_cap * 100 ))"
}

# _chp_github_pr_gh_fields <normalized-csv> [extra-normalized-fields...] —
# translate the caller's normalized-vocabulary FIELDS-CSV into the equivalent
# gh-native --json field list, deduped and unioned with any extra names the
# caller adds (e.g. the resolution keys for `chp_find_pr_for_issue`). Empty
# tokens are skipped. `closingIssueNumbers` maps back to gh's
# `closingIssuesReferences`; every other name is passed through.
_chp_github_pr_gh_fields() {
  local fields="$1"; shift
  local -A _gh_from_normalized=(
    [closingIssueNumbers]=closingIssuesReferences
  )
  local out="" seen="," f gh_f
  local IFS_SAVE=$IFS; IFS=','
  # shellcheck disable=SC2206
  local -a _caller_fields=(${fields})
  IFS="$IFS_SAVE"
  local -a _all=("${_caller_fields[@]}" "$@")
  for f in "${_all[@]}"; do
    [ -n "$f" ] || continue
    gh_f="${_gh_from_normalized[$f]:-$f}"
    case "$seen" in
      *",$gh_f,"*) : ;;
      *) seen="$seen$gh_f,"; out="${out:+$out,}$gh_f" ;;
    esac
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# chp_github_find_pr_for_issue ISSUE FIELDS-CSV — normalized candidate PR fetch.
#
# Spec §3.2 [M1] (W1c1, #397): return a NORMALIZED JSON ARRAY of open PR
# candidates for close-linkage-resolution by the caller. The array is projected
# to the caller-supplied FIELDS-CSV UNION the three selection keys
# (`number,closingIssueNumbers,headRefName`); `closingIssueNumbers` is a
# normalized array of ints (from GitHub's `closingIssuesReferences[].number`),
# `body` is normalized to a string (`null` → `""`, the #148 hazard fix), and
# `state` is one of `OPEN|CLOSED|MERGED`. No `gh` flags or `jq` programs cross
# the seam — the caller's [INV-86] two-tier resolution (close-linkage beats
# branch-name, boundary-anchored branch match, deterministic PR-number tie-
# break) lives in `lib-pr-linkage.sh` as pure jq over the returned array
# (mirrors INV-44 classifiers-stay-caller-side).
#
# The ISSUE positional stops being dead: it is a NARROWING HINT the provider
# MAY use to prune the candidate set — but ONLY when no true candidate can be
# excluded. GitHub has no server-side "PR that closes issue N" filter today,
# so the ISSUE arg is documented but IGNORED here; GraphQL/`gh` returns all
# open PRs and the caller narrows client-side.
#
# COMPLETE-set (§3.5): the leaf walks pagination to exhaustion, bounded at
# `CHP_GITHUB_PR_LIST_PAGE_CAP` pages (default 20; each page 100 PRs, so cap
# holds 2000 open PRs — a comfortable upper bound on any real dispatcher
# workload). Cap-hit is FAIL-CLOSED: rc != 0 and no partial array, so the
# caller's `|| return 1` posture rejects rather than silently drops a
# candidate. A fixed `--limit N` is NOT acceptable — it just moves the silent
# truncation threshold; the whole point of #397 is closing that hazard.
#
# Fail-closed on `gh` error: transport / auth / API failure → non-zero rc,
# no partial output (the `needs_open_pr_only` site uses `|| return 1` to
# refuse the pushed-no-PR classification on a failed read).
#
# Regression anchors: #148 (null-body PRs no longer hide close-linked matches);
# #277/[INV-86] (close-linkage beats body-mention); silent `--limit 30`
# truncation the pre-#397 leaf inherited from gh's default.
chp_github_find_pr_for_issue() {
  # `${2:-}` (not `$2`) so the missing-FIELDS guard is reachable under `set -u`
  # rather than aborting on an unbound `$2`.
  local _issue="${1:-}" fields="${2:-}"
  [ -n "$fields" ] || { echo "ERROR: chp_github_find_pr_for_issue requires FIELDS-CSV (2nd arg) [M1]" >&2; return 2; }
  # Union the caller's normalized fields with the three [INV-86] resolution
  # keys (number, closingIssueNumbers, headRefName). The helper maps
  # `closingIssueNumbers` back to gh's `closingIssuesReferences` name.
  local gh_fields
  gh_fields="$(_chp_github_pr_gh_fields "$fields" number closingIssueNumbers headRefName)"
  local raw
  raw="$(gh pr list --repo "$REPO" --state open --limit "$(_chp_github_pr_page_limit)" --json "$gh_fields" 2>/dev/null)" || return 1
  jq -c "$_CHP_GITHUB_PR_NORMALIZE_JQ" <<<"$raw"
}

# chp_github_ci_status PR [extra gh args…] — CI check-state leaf.
#
# Spec §3.2: the `gh pr checks` status query for `ci_is_green`. The caller
# supplies the `--json state -q '[.[].state]'` tail; the leaf forwards it
# byte-identically. The jq `length>0 and all(.=="SUCCESS")` gate that turns the
# state array into green/pending/failed/none STAYS caller-side in `ci_is_green`.
chp_github_ci_status() {
  local pr="$1"; shift
  gh pr checks "$pr" --repo "$REPO" "$@"
}

# chp_github_mergeable PR [extra gh args…] — raw backend mergeable token.
#
# Spec §3.2 [M2]: wraps ONLY the `gh pr view … --json mergeable` leaf
# (autonomous-review.sh's mergeable poll). Returns the RAW backend `mergeable`
# token (MERGEABLE / CONFLICTING / UNKNOWN / "" ). The [INV-44]/[INV-54]
# classifiers (`_classify_mergeable_gate`, `_pr_open_gate`,
# lib-review-mergeable.sh) STAY caller-side and consume this raw token —
# lib-review-mergeable.sh is byte-for-byte unchanged.
chp_github_mergeable() {
  local pr="$1"; shift
  gh pr view "$pr" --repo "$REPO" --json mergeable "$@"
}

# chp_github_create_pr [gh pr create args…] — open a PR.
#
# Spec §3.2: the `gh pr create` leaf. The wrapper's PR-create broker
# (drain_agent_pr_create, lib-auth.sh) passes the resolved
# `--head $branch --title $title --body $body` tail; this leaf prepends
# `--repo $REPO` and forwards the rest byte-identically (the explicit `--head`
# from the broker is preserved — the wrapper cwd is on the base branch, #234).
#
# The wrapper-side broker `drain_agent_pr_create` (lib-auth.sh) calls this verb to
# perform the create — a LEAF-ONLY swap of its inner `gh pr create` for the verb
# (byte-identical argv; no INV-79 token/scoping change). PAT-mode /
# app-mode-without-scoping creates the PR via the agent directly (prompt-driven
# `gh pr create`), unchanged.
chp_github_create_pr() {
  gh pr create --repo "$REPO" "$@"
}

# chp_github_approve PR [extra gh args…] — approve a PR.
#
# Spec §3.2: the `gh pr review --approve` leaf (autonomous-review.sh PASS path,
# [INV-52]/[INV-79] wrapper-owns-approve). The caller passes the `--approve
# --body …` tail; the leaf forwards it byte-identically. The PASS-gate chain
# (mergeable, no-auto-close, PR-open) STAYS caller-side.
chp_github_approve() {
  local pr="$1"; shift
  gh pr review "$pr" --repo "$REPO" "$@"
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

# chp_github_merge PR [extra gh args…] — merge a PR.
#
# Spec §3.2 [M4]: the `gh pr merge` leaf (autonomous-review.sh, [INV-52]/[INV-79]
# wrapper-owns-merge). The caller passes the `--squash --delete-branch` tail; the
# leaf forwards it byte-identically.
#
# Cross-seam coupling ([M4]/[INV-33], merge_closes_issue=1 for GitHub): merging a
# PR whose body carries `Closes #N` auto-transitions the issue to its terminal
# state as a SIDE EFFECT, so the wrapper MUST NOT call itp_transition_state (nor
# `gh issue close`) after a GitHub merge. A `merge_closes_issue=0` backend MUST
# transition explicitly post-merge. This is a CALLER-side decision branched on
# `chp_caps merge_closes_issue`; the leaf itself only performs the merge.
chp_github_merge() {
  local pr="$1"; shift
  gh pr merge "$pr" --repo "$REPO" "$@"
}

# chp_github_review_threads PR — unresolved review threads, M8 thread shape.
#
# Spec §3.2 [M8]: the reviewThreads GraphQL list (resolve-threads.sh). Emits the
# CHP thread shape, DISTINCT from the ITP issue-comment shape (itp_list_comments):
#   [{thread_id, resolved, comments:[{id, path, line, author, body, createdAt}]}]
# The inline `.path`/`.line` fields are CHP-owned and NEVER appear in the ITP
# shape. `$REPO` is split into owner/name for the GraphQL query (the historical
# resolve-threads.sh CLI took owner+repo as separate args; here we derive both
# from $REPO so the verb signature is provider-neutral `PR`).
#
# Today's resolve-threads.sh selects only UNRESOLVED thread ids
# (`select(.isResolved==false).id`); this verb returns the FULL thread set with
# the per-thread `resolved` flag + inline comments, so the caller can select
# unresolved (`.[]|select(.resolved==false).thread_id`) byte-identically while
# also having the richer shape the spec mandates. §3.5: the GraphQL `first:100`
# walk mirrors today's behavior (resolve-threads.sh:46) and returns the set.
chp_github_review_threads() {
  local pr="$1"
  local owner="${REPO%%/*}" name="${REPO##*/}"
  gh api graphql \
    -F owner="$owner" \
    -F repo="$name" \
    -F prNumber="$pr" \
    -f query='
query($owner: String!, $repo: String!, $prNumber: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $prNumber) {
      reviewThreads(first: 100) {
        nodes {
          id
          isResolved
          comments(first: 100) {
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
}' --jq '
    [ .data.repository.pullRequest.reviewThreads.nodes[]
      | { thread_id: .id,
          resolved: .isResolved,
          comments: [ .comments.nodes[]
                      | { id: .databaseId,
                          path: .path,
                          line: (.line // .originalLine),
                          author: (.author.login // null),
                          body: (.body // ""),
                          createdAt: .createdAt } ] } ]'
}

# chp_github_resolve_thread THREAD_ID — resolve one review thread.
#
# Spec §3.2 [M8]: the resolveReviewThread mutation (resolve-threads.sh:73-78).
# Echoes the post-mutation `isResolved` (`true`/`false`) so the caller's
# resolved/failed tally is byte-identical. THREAD_ID is the GraphQL thread node
# id (from chp_github_review_threads' `.thread_id`).
chp_github_resolve_thread() {
  local thread_id="$1"
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

# chp_github_pr_view PR [extra gh args…] — general PR read leaf (#282 review r8).
#
# The provider-neutral `gh pr view` primitive the caller layer's INCIDENTAL
# PR-number-keyed reads route through (preview-URL/headRefName/headRefOid/state/
# comments/reviews projections at autonomous-dev.sh / autonomous-review.sh) so the
# caller carries ZERO raw `gh pr view`. The caller supplies its own
# `--json <fields> -q <filter>` via "$@"; the leaf forwards it byte-identically.
chp_github_pr_view() {
  local pr="$1"; shift
  gh pr view "$pr" --repo "$REPO" "$@"
}

# chp_github_pr_list STATE FIELDS-CSV — normalized PR-list read leaf.
#
# Spec §3.2 (W1c1, #397): return a NORMALIZED JSON ARRAY of PRs in STATE,
# projected to the caller-supplied FIELDS-CSV. STATE ∈ `open|closed|merged|all`
# (case-insensitive at the seam; the GitHub leaf lowercases for `gh --state`).
# The FIELDS-CSV is projected using the SAME normalized vocabulary as
# `chp_find_pr_for_issue` — body is a string (`null` → `""`), state is
# `OPEN|CLOSED|MERGED`, createdAt/updatedAt/mergedAt are ISO-8601 or null,
# and `closingIssueNumbers` is an array of ints (from
# `closingIssuesReferences[].number`). No `gh` flags or `jq` programs cross
# the seam.
#
# DISTINCT from `chp_find_pr_for_issue`: no issue-narrowing hint, no forced
# union with the resolution keys. The body-mention `#N`-boundary `test()` is
# caller-side (each of the six body-mention sites keeps its own regex over
# the normalized `body` string). Empty match set → `[]` (NEVER null; the #148
# hazard fix).
#
# COMPLETE-set (§3.5): same bounded page-walk as `chp_find_pr_for_issue`
# (`CHP_GITHUB_PR_LIST_PAGE_CAP`, default 20 pages / 2000 PRs), fail-CLOSED
# on cap-hit or `gh` transport error. This closes the silent `--limit 30`
# truncation that could make `needs_open_pr_only` misclassify a >30-open-PR
# repo (a real hazard for the linkage read; the six body-mention sites here
# are decision-consistent, but a `pr_num` result flipped from #102 to "" by
# truncation is a live regression).
chp_github_pr_list() {
  local state="${1:-}" fields="${2:-}"
  [ -n "$state" ]  || { echo "ERROR: chp_github_pr_list requires STATE (1st arg)" >&2; return 2; }
  [ -n "$fields" ] || { echo "ERROR: chp_github_pr_list requires FIELDS-CSV (2nd arg)" >&2; return 2; }
  # Lowercase state for `gh --state` (accepts open/closed/merged/all).
  local state_lc
  state_lc="$(printf '%s' "$state" | tr '[:upper:]' '[:lower:]')"
  case "$state_lc" in
    open|closed|merged|all) : ;;
    *) echo "ERROR: chp_github_pr_list STATE must be one of open|closed|merged|all (got '$state')" >&2; return 2 ;;
  esac
  # Union caller's normalized fields with `number` (every body-mention site
  # projects it) but NOT the [INV-86] resolution keys — this verb is the
  # general body-mention list read, not the linkage resolver.
  local gh_fields
  gh_fields="$(_chp_github_pr_gh_fields "$fields" number)"
  local raw
  raw="$(gh pr list --repo "$REPO" --state "$state_lc" --limit "$(_chp_github_pr_page_limit)" --json "$gh_fields" 2>/dev/null)" || return 1
  jq -c "$_CHP_GITHUB_PR_NORMALIZE_JQ" <<<"$raw"
}

# chp_github_list_inline_comments PR [extra gh args…] — PR inline (file-anchored)
# review-comment read leaf (#296 second-tier, #328). Mirrors chp_github_pr_view.
#
# Spec §3.2 [INV-95]: the flat REST `pulls/N/comments` inline-comment read the
# dev-resume prompt builder uses (autonomous-dev.sh's PR_REVIEW_COMMENTS — the
# comments the dev agent is told to address + reply-to + resolve). DISTINCT shape
# from chp_review_threads (GraphQL thread tree), chp_pr_view (no pulls/N/comments
# sub-resource), and itp_list_comments (issue-level normalized): the inline
# `.path`/`.line`/`.original_line` fields are CHP-owned and NEVER folded into the
# ITP issue-comment shape (§3.2). The caller supplies its own `--jq` formatter via
# "$@" (the `- **path:line** — body` prompt rendering stays caller-side, #281
# jq-stays-caller); the leaf forwards it byte-identically and does no formatting
# (focused-raw). No `--paginate` today (kept byte-identical; a page-walk is a
# separate change). $REPO is from the caller env.
chp_github_list_inline_comments() {
  local pr="$1"; shift
  gh api "repos/${REPO}/pulls/${pr}/comments" "$@"
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
