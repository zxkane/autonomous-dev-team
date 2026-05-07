# Dispatcher: skip redundant review when PR HEAD unchanged since last review

## Problem

When `Step 5: Stale Detection` finds an `in-progress` issue whose dev process is dead and a PR exists, the dispatcher unconditionally moves the issue to `pending-review`. If the PR HEAD SHA has not advanced since the last `Review findings` comment, this re-runs the review agent on identical code and produces the same findings — wasted compute and wasted review-agent quota. The dev agent never gets another chance to act on the prior findings.

Observed on issue #115 in the consumer repo: dev exited without pushing new commits, dispatcher routed back to review, review re-emitted the same blocking finding (bench gate not completed), loop repeated.

## Goal

Branch the dead-with-PR transition on whether the PR HEAD has advanced since the last review:

- **HEAD advanced** (or no review comment exists yet) → `pending-review` (current behavior).
- **HEAD unchanged** → `pending-dev` so the dev agent retries against the existing review feedback.

## Design

### 1. Review agent records the reviewed HEAD SHA

`autonomous-review.sh` already captures `PR_BRANCH` near line 203. Add `PR_HEAD_SHA=$(gh pr view ... --json headRefOid -q .headRefOid)` alongside it.

After the agent posts its `Review findings:` / `Review PASSED` comment and the wrapper finishes parsing the verdict, post a short trailer comment from the wrapper itself:

```
Reviewed HEAD: `<sha>` (issue #N, session `<session-id>`)
```

The trailer is posted in **both** branches (PASSED and findings) so any future tooling can rely on the marker. The session ID is included to make the trailer searchable per-review without leaking the verdict text.

Why a separate comment instead of asking the agent to embed it: the agent's prompt is already long; relying on the agent to include a precise SHA is brittle (it would have to call `gh pr view` itself). The wrapper has the SHA in hand and can post the trailer reliably.

If the trailer fails to post (network/permission error), the dispatcher falls back to the existing behavior (no SHA found → assume new code, route to review). This is safe degradation.

### 2. Dispatcher Step 5 compares SHAs

Update `skills/autonomous-dispatcher/SKILL.md` Step 5 dead-with-PR branch:

```bash
PR_INFO=$(gh pr list --repo "$REPO" --state open --json number,body,headRefOid \
  -q "[.[] | select(.body | test(\"#${ISSUE_NUM}[^0-9]\") or test(\"#${ISSUE_NUM}$\"))] | .[0]")
PR_EXISTS=$(jq -e 'length > 0' <<<"$PR_INFO" >/dev/null 2>&1 && echo 1 || echo 0)

if [ "$PR_EXISTS" = "1" ]; then
  CURRENT_HEAD=$(jq -r '.headRefOid // empty' <<<"$PR_INFO")
  LAST_REVIEWED_HEAD=$(gh issue view "$ISSUE_NUM" --repo "$REPO" --json comments \
    -q '[.comments[].body | capture("Reviewed HEAD: `(?P<sha>[0-9a-f]{7,40})`"; "g") | .sha] | last // empty')

  if [[ -n "$LAST_REVIEWED_HEAD" && -n "$CURRENT_HEAD" && "$CURRENT_HEAD" == "$LAST_REVIEWED_HEAD" ]]; then
    # No new commits since last review — retry dev so it can act on existing findings.
    # (Wording avoids "crashed" so retry-counter regex from Step 4 does not match.)
    gh issue comment "$ISSUE_NUM" --repo "$REPO" \
      --body "Dev process exited (no new commits since last review at \`${CURRENT_HEAD:0:7}\`). Moving to pending-dev for retry."
    gh issue edit "$ISSUE_NUM" --repo "$REPO" \
      --remove-label "in-progress" --add-label "pending-dev"
  else
    # New commits OR no prior review trailer — let the review agent assess.
    gh issue comment "$ISSUE_NUM" --repo "$REPO" \
      --body "Dev process exited (PR found). Moving to pending-review for assessment."
    gh issue edit "$ISSUE_NUM" --repo "$REPO" \
      --remove-label "in-progress" --add-label "pending-review"
  fi
fi
```

### 3. Retry-counter interaction

The new `pending-dev` route comment ("Dev process exited (no new commits since last review at `<sha>`)") MUST NOT match the existing crash regex in Step 4:

```
"Task appears to have crashed \\(no PR found\\)|process not found"
```

The chosen wording avoids "crashed" and "process not found", so this finding does not increment the retry counter on its own. The dev agent's eventual `Agent Session Report` (with non-zero exit) will still count if it fails. This matches the precedent set by PR #50 (`fix(dispatcher): exclude "PR found" handoff from retry counter`).

### 4. Edge cases

- **No prior review yet**: `LAST_REVIEWED_HEAD` is empty → falls through to `pending-review`. Correct: review hasn't seen the PR yet.
- **Review trailer post failed**: `LAST_REVIEWED_HEAD` is empty → `pending-review`. Same fallback as above; review will run again, but no worse than today's behavior.
- **SHA prefix vs full**: GitHub `headRefOid` returns the full 40-char SHA, and the wrapper writes the full SHA into the trailer. Exact `==` is sufficient; no prefix-match safety net needed because there is no legacy non-full-SHA trailer format to support.
- **Dev pushed and then crashed**: `CURRENT_HEAD` differs from `LAST_REVIEWED_HEAD` → `pending-review`. Correct: new code needs review.
- **Multiple PRs on same issue** (rare): the existing `gh pr list` query already takes the first match. No change.

## Out of Scope

- Changing the cleanup-trap behavior in `autonomous-dev.sh` (which sets `pending-review` after agent exits with code 0 and PR exists). The cleanup-trap path is the *successful* dev exit; new commits are guaranteed there because the agent reached its terminal step. The bug only happens on Step 5's stale-detection path, which fires when dev exited *without* the cleanup trap running (true crash, OOM, kill, etc.).
- Tracking review-passed-on-SHA for caching merge decisions. The current scope is just the dead-with-PR transition.
- Embedding the SHA inside the agent's `Review findings:` body (would require prompt changes and is more brittle).
