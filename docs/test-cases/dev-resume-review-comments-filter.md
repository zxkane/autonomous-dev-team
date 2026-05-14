# Test Cases — `REVIEW_COMMENTS` filter (resume-mode prompt)

Tracks: issue #113.

## Scenario

`autonomous-dev.sh::resume` constructs a prompt that includes the most
recent review feedback. The pre-fix selector

```bash
[.comments[] | select(.body | contains("Review findings") or contains("review"))] | last // empty
```

substring-matches the literal `review` against every comment body. Many
dispatcher status comments contain that substring (`Dispatching
autonomous review`, `Moving to pending-review for retry`,
`no new commits since last review at <sha>`). When the most recent
matching comment is a dispatcher status, `last` returns it instead of
the actual review-findings body — the resume prompt then carries
dispatcher chatter as `## Review Feedback`. Verified producer of stuck
issues that resume forever without making progress.

## Test Cases

The fix tightens the filter to `startswith("Review findings") or
startswith("Review PASSED")`. These tests pin the new behavior against
fixtures crafted from real-world dispatcher comment bodies.

| ID | Comments fixture (in chronological order) | Expected match |
|----|---|---|
| TC-RFB-001 | One real `Review findings: ... [BLOCKING] ...` comment | the real comment |
| TC-RFB-002 | Real `Review findings` AT T0, then dispatcher `Moving to pending-review for retry` AT T1 | the real comment (dispatcher status SKIPPED) |
| TC-RFB-003 | Real `Review findings` AT T0, then dispatcher `Dispatching autonomous review...` AT T1 | the real comment |
| TC-RFB-004 | Real `Review findings` AT T0, then dispatcher `Dev process exited (no new commits since last review at <sha>)` AT T1 | the real comment |
| TC-RFB-005 | Only `Review PASSED — All checklist items verified` (no findings yet) | the PASSED comment |
| TC-RFB-006 | No matching comment (fresh issue, no review yet) | empty |
| TC-RFB-007 | Multiple real review comments — `Review findings (round 1)` then `Review findings (round 2)` | round 2 (`last` semantics preserved) |
| TC-RFB-008 | Real `Review findings`, then a comment whose body merely **mentions** "review" mid-sentence (e.g. `Owner: please re-trigger review`) | the real comment (mid-sentence "review" no longer matches) |

## Acceptance

- TC-RFB-002, 003, 004, 008 fail against current `main` (substring
  match picks the dispatcher status / mention) and pass after the fix
- TC-RFB-001, 005, 006, 007 pass on both sides of the fix (the new
  filter does not regress these cases)
- Test must use real dispatcher comment bodies copied verbatim from
  the wild
