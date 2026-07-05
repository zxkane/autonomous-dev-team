#!/bin/bash
# providers/prompts-gitlab.sh — GitLab agent-prompt fragments (#421, #414 W-F).
#
# API-neutral by default (issue #421 Motivation): #414 pillar 2 established
# the in-tree GitLab transport as curl-only (no `glab` dependency — a CLI
# carries its own auth/config state). What we TELL the agent to run is a
# SEPARATE decision from the transport, so these fragments default to
# API-neutral phrasing ("the wrapper opens the merge request for you" /
# "check that CI is passing") instead of naming a concrete CLI. Where a
# command is load-bearing (the agent genuinely needs to run something), the
# fragment gives a `curl .../api/v4/...` example labeled "reference, not a
# requirement" — never a bare `gh`/`glab` invocation. Every fragment here is
# grep-pinned zero-bare-`gh`/`glab` by
# tests/unit/test-provider-prompts-gitlab-render.sh (R5; K=0 `glab` tokens by
# default — introducing one is a deliberate, reviewed exception, not a
# default).
#
# Sourced by lib-provider-prompts.sh's provider_prompt_fragment(); never
# sourced directly by a wrapper. SAME key set + SAME arg count/order as
# providers/prompts-github.sh (a call site passes one fixed positional-arg
# list regardless of which provider ends up rendering it) — a template here
# may simply ignore an arg it doesn't need (e.g. GitLab's project id comes
# from $GITLAB_PROJECT, not a positional), but the COUNT must still match.
#
# Review-round fixes (#421): every fragment that reads GitLab notes
# (`review.requirement_drift_gh_issue_view`, `review.e2e_fetch_comment`)
# ACTUALLY paginates via the `x-next-page` response header (a curl `-D`
# header dump + a page-number loop) instead of describing pagination without
# performing it — GitLab's notes endpoints cap at 100 items/page, so a
# single-page read on an active PR silently drops newer comments/evidence.
# `review.check_mergeable` normalizes `detailed_merge_status` into the SAME
# MERGEABLE/CONFLICTING/UNKNOWN vocabulary `chp_gitlab_mergeable` returns
# (see its bucket table, providers/chp-gitlab.sh) — the review prompt's
# Step 0 branches on those exact three tokens. `review.watch_ci_checks`
# renders an executable poll loop (it is spliced into a bash heredoc after a
# real rebase command; plain English there is a syntax error the agent would
# hit verbatim). `bots.review_count_check{,_bare}` count via
# `/merge_requests/:iid/approvals.approved_by` — the SAME endpoint
# `chp_gitlab_count_reviews_by_login` uses — not `/notes`, since GitLab has
# no review-comment object and a bot that approves without leaving a note
# would otherwise read as MISSING forever.

declare -gA _PP_GITLAB_FRAGMENT=(
  [dev.read_issue_body]='1. Read the issue body to understand the full requirements (issue #%s in %s).'
  [dev.pr_create_write_to_file]='the wrapper opens the merge request for you — instead WRITE the MR to `$(printenv AGENT_PR_CREATE_FILE)`'
  [dev.pr_create_wrapper_runs]='The WRAPPER will open the merge request (`--head <your-branch>`) for you after you finish.'
  [dev.fastpath_interrupted]='ahead of the base branch, but was interrupted before the merge request was opened.'
  [dev.pr_create_cannot_run]='approve or merge merge requests, and it cannot open one directly). To open the MR, do NOT'
  [dev.merge_failed_likely_reason]='means the review verdict was PASS but merging failed (likely a merge'
  [dev.pr_create_direct_step]='Go STRAIGHT to the open-MR step: open the merge request with a generated'
  [dev.pr_create_do_not_run_instead]='open the merge request yourself. Instead, AFTER you have pushed your feature branch with'
  [dev.merge_failed_rebase_parenthetical]='verdict was PASS but merging failed). Rebase the MR branch onto'
  [review.check_mergeable]='1. Check the merge request'"'"'s detailed merge status and normalize it to MERGEABLE/CONFLICTING/UNKNOWN (reference, not a requirement — any equivalent read is fine):
   ```bash
   DMS=$(curl -sS -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "https://${GITLAB_HOST}/api/v4/projects/${GITLAB_PROJECT}/merge_requests/%s" | jq -r .detailed_merge_status)
   case "$DMS" in
     mergeable) STATUS=MERGEABLE ;;
     conflict|need_rebase|commits_status|broken_status) STATUS=CONFLICTING ;;
     *) STATUS=UNKNOWN ;;  # checking/unchecked/preparing/policy-blocks/unrecognized — see chp_gitlab_mergeable'"'"'s bucket table
   esac
   ```%.0s'
  [review.codex_diff_step]='Review the PR diff `codex review` already scoped for you (its merge-target diff) — do NOT re-fetch it yourself to reconstruct it (INV-62)'
  [review.check_ci_checks]='5. Check that CI is passing for merge request !%s.'
  [review.verdict_no_bare_issue_comment]='Do **NOT** hand-roll a raw comment post for the verdict — a hand-rolled'
  [review.codex_gh_pr_diff_reconstruct]='the review range yourself; review the diff codex gave you.'
  [review.gh_pr_view_checks_parenthetical]='the merge request view / CI checks):'
  [review.codex_do_not_hand_roll]='below — do NOT hand-roll a raw comment post for the verdict): a FAIL when'
  [review.requirement_drift_gh_issue_view]='**Before reading the PR diff**, read ALL comments on issue #%s to detect requirement changes posted after implementation (reference — any equivalent read is fine; paginates via x-next-page so late comments are never missed):

```bash
NOTES="[]"; PAGE=1; PAGE_CAP=50  # fail-closed bound, mirrors _gl_api'"'"'s GL_TRANSPORT_PAGE_CAP
while [ "$PAGE" -le "$PAGE_CAP" ]; do
  HDRS=$(mktemp)
  RESP=$(curl -sS -D "$HDRS" -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "https://${GITLAB_HOST}/api/v4/projects/${GITLAB_PROJECT}/issues/%s/notes?per_page=100&sort=asc&order_by=created_at&page=${PAGE}")
  NOTES=$(jq -cn --argjson a "$NOTES" --argjson b "$RESP" '"'"'$a + $b'"'"')
  NEXT=$(grep -i '"'"'^x-next-page:'"'"' "$HDRS" | tr -d '"'"'\\r'"'"' | cut -d: -f2 | tr -d '"'"' '"'"')
  rm -f "$HDRS"
  [ -n "$NEXT" ] || break
  PAGE="$NEXT"
done
echo "$NOTES" | jq -r '"'"'.[] | "\(.author.username) [\(.created_at)]: \(.body[0:500])"'"'"'
```%.0s'
  [review.watch_ci_checks]='MR_IID=%s
   # Poll CI status for merge request !${MR_IID} (reference — any equivalent read is fine).
   # NOTE `none` (no pipeline attached) is NOT terminal right after a force-push
   # rebase: GitLab attaches the replacement pipeline with a delay. Keep polling
   # through `none` for a grace window (10 min) before treating it as
   # genuinely-no-CI; real statuses terminate as usual.
   NONE_GRACE=20   # 20 polls x 30s = 10 min
   while :; do
     STATUS=$(curl -sS -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "https://${GITLAB_HOST}/api/v4/projects/${GITLAB_PROJECT}/merge_requests/${MR_IID}" | jq -r '"'"'.head_pipeline.status // "none"'"'"')
     case "$STATUS" in
       success|failed|canceled|skipped) break ;;  # skipped IS terminal on GitLab — see chp_gitlab_ci_status'"'"'s bucket table
       none) NONE_GRACE=$((NONE_GRACE - 1)); [ "$NONE_GRACE" -le 0 ] && break; sleep 30 ;;
       *) sleep 30 ;;
     esac
   done
   echo "CI finished with status: $STATUS"'
  [review.e2e_fetch_comment]='```bash
   MR_IID=%s
   NOTES="[]"; PAGE=1; PAGE_CAP=50  # fail-closed bound, mirrors _gl_api'"'"'s GL_TRANSPORT_PAGE_CAP
   while [ "$PAGE" -le "$PAGE_CAP" ]; do
     HDRS=$(mktemp)
     RESP=$(curl -sS -D "$HDRS" -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "https://${GITLAB_HOST}/api/v4/projects/${GITLAB_PROJECT}/merge_requests/${MR_IID}/notes?per_page=100&sort=asc&order_by=created_at&page=${PAGE}")
     NOTES=$(jq -cn --argjson a "$NOTES" --argjson b "$RESP" '"'"'$a + $b'"'"')
     NEXT=$(grep -i '"'"'^x-next-page:'"'"' "$HDRS" | tr -d '"'"'\\r'"'"' | cut -d: -f2 | tr -d '"'"' '"'"')
     rm -f "$HDRS"
     [ -n "$NEXT" ] || break
     PAGE="$NEXT"
   done
   echo "$NOTES" | jq -r '"'"'[.[].body | select(test("e2e-evidence: complete"))] | last'"'"'
   ```%.0s'
  [bots.review_count_check]='```bash
   COUNT=$(curl -sS -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "https://${GITLAB_HOST}/api/v4/projects/${GITLAB_PROJECT}/merge_requests/%.0s%s/approvals" | jq '"'"'[.approved_by[]? | select(.user.username == "%s")] | length'"'"')
   # single-page bounded (GitLab approvals are not paginated)
   ```'
  [bots.review_count_check_bare]='COUNT=$(curl -sS -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "https://${GITLAB_HOST}/api/v4/projects/${GITLAB_PROJECT}/merge_requests/%.0s%s/approvals" \
       | jq '"'"'[.approved_by[]? | select(.user.username == "%s")] | length'"'"')
   # single-page bounded (GitLab approvals are not paginated)'
)

declare -gA _PP_GITLAB_ARGC=(
  [dev.read_issue_body]=2
  [dev.pr_create_write_to_file]=0
  [dev.pr_create_wrapper_runs]=0
  [dev.fastpath_interrupted]=0
  [dev.pr_create_cannot_run]=0
  [dev.merge_failed_likely_reason]=0
  [dev.pr_create_direct_step]=0
  [dev.pr_create_do_not_run_instead]=0
  [dev.merge_failed_rebase_parenthetical]=0
  [review.check_mergeable]=2
  [review.codex_diff_step]=0
  [review.check_ci_checks]=1
  [review.verdict_no_bare_issue_comment]=0
  [review.codex_gh_pr_diff_reconstruct]=0
  [review.gh_pr_view_checks_parenthetical]=0
  [review.codex_do_not_hand_roll]=0
  [review.requirement_drift_gh_issue_view]=3
  [review.watch_ci_checks]=1
  [review.e2e_fetch_comment]=2
  [bots.review_count_check]=3
  [bots.review_count_check_bare]=3
)
