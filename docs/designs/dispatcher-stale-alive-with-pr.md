# Dispatcher: handle ALIVE process + ready-for-review PR

Closes #54.

## Problem

`Step 5: Stale Detection` only acts on DEAD processes. When a dev agent finishes its work (PR opened, CI green) but the wrapper process does not exit cleanly — for example because the underlying agent CLI is hung in a polling loop or waiting on a tool result — the issue stays in `in-progress` forever:

- ALIVE branch: skip silently
- DEAD branch: existing PR/no-PR handling

Downstream issues that depend on this one also never dispatch, because dispatch gates on the dependency being CLOSED. Production cron has been observed stalling whole dependency chains this way.

## Goal

When the dev wrapper is ALIVE but its real work is done (PR up, CI green, no recent activity), the dispatcher must:

1. Send `SIGTERM` to the wrapper so the PID file clears,
2. Transition the issue from `in-progress` to `pending-review` so the review agent picks it up.

## Design

### Where the new branch fits

Step 5 currently runs `kill -0 $(cat $PID_FILE) && echo ALIVE || echo DEAD` and only branches on DEAD. Add a new branch **before** the ALIVE-skip:

```
For each in-progress issue (not in JUST_DISPATCHED):
  PID_ALIVE=$(kill -0 ... && echo 1 || echo 0)
  if PID_ALIVE == 1:
    PR_INFO=$(gh pr list ... | first match)
    if PR_INFO is non-empty:
      CI_GREEN=$(every check SUCCESS, at least one check)
      if CI_GREEN:
        IDLE_SECONDS = now - PR.updatedAt
        if IDLE_SECONDS > 300:
          SIGTERM the wrapper PID
          comment "Dev process still alive but PR ready (CI green, idle Xs). Moving to pending-review."
          remove `in-progress`, add `pending-review`
          continue
    # Otherwise: leave alone (no PR yet, or CI not green, or PR recently updated — agent may still be pushing)
    continue
  # PID_ALIVE == 0: existing DEAD path (unchanged)
```

### Why the 5-minute idle gate

Without an idle gate, we'd kill an agent that *just* pushed a passing CI check and is about to do its own cleanup (close worktree, post status comment, etc). The risk of premature kill — leaking a half-written comment, or worse, a half-pushed branch — outweighs the cost of waiting one more dispatcher cycle (5 min by default).

`PR.updatedAt` is the timestamp of the most recent PR-state mutation (commit pushed, comment, label change). It's the right signal: as long as the agent is actively driving the PR, this stays fresh; once the agent goes quiet, it ages.

5 minutes also matches the dispatcher cron interval — so the next cycle will be the one to act, not the cycle that detects the green-CI state.

### Why kill at all (vs. just transitioning the label)

If we only transition the label, the wrapper stays alive holding `/tmp/agent-${PROJECT_ID}-issue-${ISSUE_NUM}.pid`. Two follow-on problems:

1. The `acquire_pid_guard` in `lib-agent.sh` will refuse to start a new dev session for the same issue (e.g. if review sends it back to `pending-dev`), because the existing PID is still alive. The user's #55 bug is exactly this surface: zombie wrappers blocking re-dispatch.
2. Resource leak. Production has been seen with multiple such zombies per issue.

`SIGTERM` is the right signal — agent shells trap it and clean up. We do NOT escalate to `SIGKILL` here; a stuck-on-SIGTERM wrapper is rare enough and a separate failure mode best handled by an operator.

### Why "all checks SUCCESS + non-empty"

Three failure shapes ruled out by the non-empty check:

- A PR with **no checks configured at all** ([] on `gh pr checks`): could happen on a brand-new repo or a misconfigured branch. Treating empty as green means we'd transition immediately on PR-open, defeating the purpose of waiting for CI.
- **Required checks not yet started** (everything `QUEUED` / `PENDING`): empty SUCCESS-only filter would pass `all SUCCESS` vacuously on the empty-after-filter set. Need both "every check is SUCCESS" AND "the check list is non-empty".
- **Skipped checks** (`SKIPPED`, `NEUTRAL`): conservatively NOT counted as success. If a repo has a routinely-skipped check, the agent's normal workflow will exit cleanly when CI finishes; we only need this stale path for the hung-agent case, where being conservative is fine.

Concretely:

```bash
CI_STATES=$(gh pr checks "$PR_NUM" --repo "$REPO" --json state -q '[.[].state]')
CI_GREEN=$(jq -e 'length > 0 and all(. == "SUCCESS")' <<<"$CI_STATES" >/dev/null && echo 1 || echo 0)
```

### Idempotence under repeated cron ticks

If the dispatcher transitions an issue to `pending-review` but the wrapper survives the SIGTERM (rare, but possible if the agent is in uninterruptible IO), the next dispatcher tick will:

- Find the issue in `pending-review` (label already moved), so this Step 5 in-progress branch doesn't re-fire.
- Step 3 (review dispatch) will pick it up with no new transition needed.

If by then the agent has *also* moved the issue back to `in-progress` somehow (it shouldn't — it's mid-shutdown), the same branch will SIGTERM again. That's safe.

### Operator-visibility

Comment posted on transition:

```
Dev process still alive but PR #<N> is ready (all CI checks passed, idle 312s).
Sent SIGTERM to PID <pid>. Moving to pending-review.
```

The "still alive" wording deliberately differs from both DEAD-with-PR ("Dev process exited (PR found)") and the new "no new commits" wording from #53 — three distinct operator signals. None of them match the Step 4 retry-counter regex (`Task appears to have crashed \(no PR found\)|process not found`).

## Out of Scope

- The companion problem of zombie wrappers blocking *re-dispatch* (issue #55) is a separate fix. This PR handles only the ALIVE+ready-PR transition. After this lands, PIDs from such zombies will be cleared by SIGTERM, which incidentally helps #55 in the most common shape.
- A `SIGKILL` escalation after SIGTERM grace period — out of scope. If we observe SIGTERM-resistant agents in production, we'll add a follow-up.
- Detecting "agent is in a tight loop with no PR-side activity" (e.g. spinning on internal state). The PR-updatedAt heuristic works for the common shape; pathological loops are out of scope.
- Reviewing-state ALIVE handling (review agent stuck). Same shape, but the review agent does its own labels (PASS/find) so the failure mode is different. Out of scope here.
