# Test Cases: dispatcher-skip-redundant-review

## TC-DSRR-001: Review wrapper records reviewed HEAD SHA

**Setup:** static analysis of `skills/autonomous-dispatcher/scripts/autonomous-review.sh`

**Verify:**
- Script captures `PR_HEAD_SHA` via `gh pr view ... --json headRefOid -q .headRefOid`.
- Script posts a trailer comment containing the literal string `Reviewed HEAD:` followed by a backtick-wrapped SHA on both the PASSED and findings branches.
- Trailer is posted from the wrapper, not produced by the agent prompt.

## TC-DSRR-002: Trailer post failure does not abort review

**Verify:** the trailer post call is wrapped with `|| true` (or equivalent) so a network/permission failure doesn't break the existing PASS/merge or send-back flow.

## TC-DSRR-003: Dispatcher SKILL.md describes SHA comparison

**Setup:** static analysis of `skills/autonomous-dispatcher/SKILL.md` Step 5.

**Verify:**
- Step 5 dead-with-PR branch reads the current PR `headRefOid`.
- It extracts `Reviewed HEAD:` from issue comments using a regex that captures a 7+ hex SHA.
- It branches on the comparison:
  - SHA matches → comment that avoids the words "crashed" and "process not found", and adds `pending-dev`.
  - SHA differs or empty → existing `pending-review` flow with the existing wording.

## TC-DSRR-004: New comment wording does not match retry-counter regex

**Setup:** unit test that pulls the new "no new commits since last review" wording and checks it against the regex from Step 4:

```
Task appears to have crashed \(no PR found\)|process not found
```

**Verify:** the new comment string fails the regex (so the retry counter is not incremented for this transition).

## TC-DSRR-005: Existing "Dev process exited (PR found)" wording also fails the regex

**Setup:** regression check — make sure the existing PR-found handoff wording still does not match the retry regex (PR #50 precedent).

## TC-DSRR-006: Dispatcher Step 5 keeps `pending-review` when no review trailer is found

**Verify:** SKILL.md explicitly states that empty `LAST_REVIEWED_HEAD` falls through to `pending-review` (no first-review starvation).

## TC-DSRR-007: Trailer marker is grep-able with the documented regex

**Setup:** synthesize a trailer comment body matching what the wrapper posts. Run the SKILL.md jq capture against it and assert it returns the expected SHA.

```
Reviewed HEAD: `abcdef1234567890abcdef1234567890abcdef12` (issue #115, session `f95638fe-...`)
```

Expected jq output: `abcdef1234567890abcdef1234567890abcdef12`.
