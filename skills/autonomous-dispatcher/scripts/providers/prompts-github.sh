#!/bin/bash
# providers/prompts-github.sh — GitHub agent-prompt fragments (#421, #414 W-F).
#
# Byte-identical to the pre-#421 hardcoded prose (golden-pinned by
# tests/unit/test-provider-prompts-github-golden.sh) — this migration is a
# RENAME, not a rewrite. Sourced by lib-provider-prompts.sh's
# provider_prompt_fragment(); never sourced directly by a wrapper.
#
# Each _PP_GITHUB_FRAGMENT entry is a printf(1) format string — `%s` is a
# positional placeholder, a literal `%` would need escaping to `%%` (none of
# these fragments contain a literal `%`). _PP_GITHUB_ARGC pins the expected
# arg count per key so a caller passing the wrong number of args fails LOUD
# in provider_prompt_fragment rather than silently mis-rendering.

declare -gA _PP_GITHUB_FRAGMENT=(
  [dev.read_issue_body]='1. Read the issue body to understand the full requirements: `gh issue view %s --repo %s --json body -q '"'"'.body'"'"'`'
  [dev.pr_create_write_to_file]='`gh pr create` — instead WRITE the PR to `$(printenv AGENT_PR_CREATE_FILE)`'
  [dev.pr_create_wrapper_runs]='The WRAPPER will run `gh pr create --head <your-branch>` for you after you finish.'
  [dev.fastpath_interrupted]='ahead of the base branch, but was interrupted before `gh pr create` completed.'
  [dev.pr_create_cannot_run]='approve or merge PRs, and it cannot run `gh pr create`). To open the PR, do NOT'
  [dev.merge_failed_likely_reason]='means the review verdict was PASS but `gh pr merge` failed (likely a merge'
  [dev.pr_create_direct_step]='Go STRAIGHT to the open-PR step: run `gh pr create` with a generated'
  [dev.pr_create_do_not_run_instead]='run `gh pr create`. Instead, AFTER you have pushed your feature branch with'
  [dev.merge_failed_rebase_parenthetical]='verdict was PASS but `gh pr merge` failed). Rebase the PR branch onto'
  [review.check_mergeable]='1. Check: `gh pr view %s --repo %s --json mergeable -q '"'"'.mergeable'"'"'`'
  [review.codex_diff_step]='Review the PR diff `codex review` already scoped for you (its merge-target diff) — do NOT re-run `git diff`/`gh pr diff` to reconstruct it (INV-62)'
  [review.check_ci_checks]='5. Check that CI checks are passing: gh pr checks %s'
  [review.verdict_no_bare_issue_comment]='Do **NOT** use a bare `gh issue comment` for the verdict — a hand-rolled'
  [review.codex_gh_pr_diff_reconstruct]='`gh pr diff` to reconstruct the review range; review the diff codex gave you.'
  [review.gh_pr_view_checks_parenthetical]='`gh pr view` / `gh pr checks`):'
  [review.codex_do_not_hand_roll]='below — do NOT hand-roll a bare `gh issue comment` for the verdict): a FAIL when'
  [review.requirement_drift_gh_issue_view]='**Before reading the PR diff**, read ALL comments on issue #%s to detect requirement changes posted after implementation:

```bash
gh issue view %s --repo %s --json comments \
  -q '"'"'.comments[] | "\(.author.login) [\(.createdAt)]: \(.body[0:500])"'"'"'
```'
  [review.watch_ci_checks]='gh pr checks %s --watch --interval 30'
  [review.e2e_fetch_comment]='```bash
   gh pr view %s --repo %s --json comments \
     -q '"'"'[.comments[].body | select(test("e2e-evidence: complete"))] | last'"'"'
   ```'
  [bots.review_count_check]='```bash
   COUNT=$(gh api repos/%s/pulls/%s/reviews \
     --jq '"'"'[.[] | select(.user.login == "%s")] | length'"'"')
   ```'
  [bots.review_count_check_bare]='COUNT=$(gh api repos/%s/pulls/%s/reviews \
       --jq '"'"'[.[] | select(.user.login == "%s")] | length'"'"')'
)

declare -gA _PP_GITHUB_ARGC=(
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
