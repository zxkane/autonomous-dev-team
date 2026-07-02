# Merge Conflict Resolution — Pre-Review Step

Before starting the review, check whether the PR branch has merge conflicts with main. If it does, rebase the branch so the PR is mergeable.

> **This pre-review rebase is best-effort prompt guidance — the wrapper enforces the same rule mechanically.** Even if you skip this step, the review wrapper re-checks `mergeable` after aggregating verdicts and before approving: a `CONFLICTING` PR can never reach `approved` ([INV-44](../../../docs/pipeline/invariants.md)). Running this step proactively still helps — a clean rebase here gets the PR merged this round instead of bouncing back to dev — but a missed step is no longer a way for a conflicting PR to slip through.

## Procedure

1. **Check mergeable status**:
   ```bash
   MERGEABLE=$(gh pr view <PR_NUMBER> --repo <REPO> --json mergeable -q '.mergeable')
   ```

2. **If MERGEABLE is "MERGEABLE"** — skip to the Review Process.

3. **If MERGEABLE is "CONFLICTING"** — rebase the PR branch onto main:
   ```bash
   # Fetch latest main and the PR branch
   git fetch origin main <PR_BRANCH>

   # [INV-100] (#355): idempotent pre-clean — a crashed prior lane (same
   # project, same agent, same PR) can leave this exact dir behind; remove it
   # BEFORE `git worktree add` so a retry never wedges on a stale worktree.
   git worktree remove --force /tmp/rebase-<PROJECT_ID>-<AGENT_NAME>-pr-<PR_NUMBER> 2>/dev/null || rm -rf /tmp/rebase-<PROJECT_ID>-<AGENT_NAME>-pr-<PR_NUMBER>

   # Create a temporary worktree for the rebase — keyed by PROJECT_ID + this
   # agent's name + the PR number, so a cross-project collision AND a
   # multi-agent fan-out collision (AGENT_REVIEW_AGENTS running N agents
   # against the SAME PR, each independently doing Step 0) are both ruled out.
   git worktree add /tmp/rebase-<PROJECT_ID>-<AGENT_NAME>-pr-<PR_NUMBER> <PR_BRANCH>
   cd /tmp/rebase-<PROJECT_ID>-<AGENT_NAME>-pr-<PR_NUMBER>

   # Rebase onto main
   git rebase origin/main
   ```

4. **If rebase succeeds** (no conflicts):
   ```bash
   # Force push the rebased branch
   git push --force-with-lease origin <PR_BRANCH>

   # Clean up temporary worktree
   cd -
   git worktree remove /tmp/rebase-<PROJECT_ID>-<AGENT_NAME>-pr-<PR_NUMBER>

   # Wait for CI to restart on the new HEAD (checks reset after force push)
   # Poll until checks appear and complete
   sleep 10
   gh pr checks <PR_NUMBER> --watch --interval 30
   ```
   Then proceed to the Review Process.

5. **If rebase fails** (merge conflicts that cannot be auto-resolved):
   ```bash
   # Capture conflicting files before aborting
   CONFLICT_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || echo "unknown")

   # Abort the rebase
   git rebase --abort

   # Clean up temporary worktree
   cd -
   git worktree remove /tmp/rebase-<PROJECT_ID>-<AGENT_NAME>-pr-<PR_NUMBER> --force
   ```
   **FAIL the review immediately** with:
   ```
   Review findings:

   Findings->Decision Gate: 1 blocking finding(s) -- FAIL.

   1. **[BLOCKING] Merge conflict with main** - The PR branch `<PR_BRANCH>` has conflicts
      with `main` that the review agent could not auto-resolve.
      - Conflicting files: <list from CONFLICT_FILES>
      - Dev agent must resolve these conflicts before re-review:
        1. `git fetch origin main`
        2. `git rebase origin/main`
        3. Resolve conflicts in the listed files
        4. `git rebase --continue`
        5. `git push --force-with-lease origin <PR_BRANCH>`
   ```
   Post this on the issue and exit. The wrapper script will transition the issue to `pending-dev`.

6. **If MERGEABLE is "UNKNOWN"** — GitHub may still be computing. Wait and retry:
   ```bash
   sleep 10
   MERGEABLE=$(gh pr view <PR_NUMBER> --repo <REPO> --json mergeable -q '.mergeable')
   ```
   If still UNKNOWN after 3 retries, **do NOT treat it as MERGEABLE and proceed to approve.** An UNKNOWN that GitHub hasn't resolved may be hiding a real conflict; treating it as mergeable is the stale-`UNKNOWN` pass-through that [INV-44](../../../docs/pipeline/invariants.md) closes. Instead, leave the review un-finalized — post a brief note that mergeability is still being computed and let the next review tick re-check it. (The wrapper enforces the same rule: a persistently-UNKNOWN PR is routed back as a non-substantive re-queue, never auto-approved.)

## Important Notes

- Force pushing to a feature branch is safe — only the pipeline agents touch these branches.
- Use `--force-with-lease` (not `--force`) to avoid overwriting unexpected changes.
- After force push, all CI checks will restart automatically. Wait for them to pass before proceeding with the review.
