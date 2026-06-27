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
# chp_github_find_pr_for_issue ISSUE FIELDS [extra gh args…] — projected PR fetch.
#
# Spec §3.2 [M1]: return the open PR bound to ISSUE, projected to the
# caller-supplied FIELDS `--json` list. FIELDS is a REQUIRED 2nd positional arg —
# every caller varies it (`number,headRefOid,body`; `number,mergedAt,reviews`;
# `number,reviewDecision,mergeable,state,body`; …). The leaf forwards FIELDS to
# `gh pr list --json $FIELDS` BYTE-IDENTICALLY; the [INV-86] close-linkage /
# branch-name resolution AND the projection live in the caller's `-q` (a 3rd arg
# the caller passes through verbatim). Calling without FIELDS is an error (the
# empty `--json` would abort `gh`), matching the resolve_pr_for_issue contract.
#
# Regression anchors: #148 (omitting `body` from FIELDS silently hides the PR),
# #274. The `gh pr list` argv is the no-behavior-change golden-trace anchor
# (spec §7.2). $REPO is from the caller env.
chp_github_find_pr_for_issue() {
  # `${2:-}` (not `$2`) so the missing-FIELDS guard is reachable under `set -u`
  # rather than aborting on an unbound `$2`.
  local fields="${2:-}"
  [ -n "$fields" ] || { echo "ERROR: chp_github_find_pr_for_issue requires FIELDS (2nd arg) [M1]" >&2; return 2; }
  shift 2
  gh pr list --repo "$REPO" --state open --json "$fields" "$@"
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

# chp_github_pr_list [extra gh args…] — general PR list read leaf (#282 review r8).
#
# The provider-neutral `gh pr list` primitive the caller layer's INCIDENTAL
# body-mention existence lookups use (needs_open_pr_only / cleanup PR_EXISTS /
# metrics / resume PR_NUM in autonomous-dev.sh). DISTINCT from
# chp_find_pr_for_issue (the [INV-86] close-linkage resolver): this is the loose
# `select(.body|test("#N"))` body-mention form these pre-#277 lookups deliberately
# keep. The caller supplies the full tail (`--state open|all --json … -q …`) via
# "$@"; the leaf forwards it byte-identically (no `--state` hardcoded, so a
# `--state all` caller is byte-identical too).
chp_github_pr_list() {
  gh pr list --repo "$REPO" "$@"
}
