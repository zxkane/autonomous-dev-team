# Test Cases: dispatcher-stale-alive-with-pr

Closes #54.

## TC-DSAP-001: SKILL.md describes the new ALIVE-with-PR branch

**Verify** SKILL.md Step 5 contains:
- `gh pr checks` invocation
- `updatedAt` reference for PR idle-time computation
- A SIGTERM (`kill -TERM` or `kill ` without `-9`) call
- A 300-second (5-minute) idle threshold
- Transition to `pending-review` on the new path

## TC-DSAP-002: Comment wording does not match the retry-counter regex

The new "still alive but PR is ready" comment must NOT match the Step 4 regex:
```
Task appears to have crashed \(no PR found\)|process not found
```

**Verify** by running the documented regex against the new comment string.

## TC-DSAP-003: Comment wording is distinct from existing handoff phrases

**Verify** the new comment string differs from both:
- `Dev process exited (PR found)` (existing DEAD-with-PR-and-new-commits)
- `Dev process exited (no new commits since last review at` (PR #53)

so that operators can distinguish the three transition causes from issue history alone.

## TC-DSAP-004: jq CI-green predicate works as documented

**Setup:** synthesize fixtures and run the SKILL.md jq predicate:
```jq
length > 0 and all(. == "SUCCESS")
```

**Cases:**
- Empty array `[]` → false (predicate must reject "no checks at all")
- `["SUCCESS"]` → true
- `["SUCCESS","SUCCESS","SUCCESS"]` → true
- `["SUCCESS","PENDING"]` → false
- `["SUCCESS","FAILURE"]` → false
- `["SKIPPED","SUCCESS"]` → false (conservative — skip not counted as green)

## TC-DSAP-005: Idle-time math works on a known timestamp

**Setup:** given a fixed `PR.updatedAt = 2026-05-08T00:00:00Z` and a current time of `2026-05-08T00:06:00Z`, the documented idle-seconds expression yields ≥ 300.

This locks in that the SKILL.md expression isn't off by 1000× (ms vs s), reading the wrong field, or using the wrong baseline timestamp.

## TC-DSAP-006: ALIVE branch does NOT fire when no PR exists

**Verify** SKILL.md explicitly says: if `PR_INFO` is empty, the ALIVE branch does not transition; the agent is left alone (still doing development work). This is a documentation assertion — if SKILL.md ever loses this guard, the dispatcher would prematurely transition issues with no PR yet.

## TC-DSAP-007: ALIVE branch does NOT fire when CI is not green

**Verify** SKILL.md says: when `CI_GREEN == 0`, the ALIVE branch does not transition. Same documentation-assertion shape as TC-DSAP-006.

## TC-DSAP-008: ALIVE branch does NOT fire when PR was updated within 5 minutes

**Verify** SKILL.md gates the SIGTERM+transition on idle-seconds > 300. This protects the case where the agent just pushed a green CI build and is about to do its own cleanup (close worktree, post final status).

## TC-DSAP-009: SIGTERM is preferred over SIGKILL

**Verify** the SKILL.md kill invocation uses `kill <pid>` or `kill -TERM <pid>`, NOT `kill -9` or `kill -KILL`. SIGTERM allows agent shells to trap and clean up.
