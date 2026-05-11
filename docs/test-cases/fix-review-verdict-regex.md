# Test Cases: review verdict regex (#95)

Strategy: the verdict-detection block of `autonomous-review.sh` is two
parts:
1. The jq filter that selects the candidate comment from issue comments
   (line 474).
2. The grep that branches PASS vs. FAIL on that comment (line 498).

Test by feeding a synthetic comments JSON through both pieces of logic
extracted into a small harness, exercising the verdict wordings the
issue mentions and adjacent variants.

## Cases

| ID | Comment body | Expected verdict |
|---|---|---|
| TC-RVR-001 | `Review PASSED — All checklist items verified.\nReview Session: \`<sid>\`` | PASS |
| TC-RVR-002 | `**APPROVED FOR MERGE**\nReview Session: \`<sid>\`` | PASS |
| TC-RVR-003 | `LGTM — code quality is good.\nReview Session: \`<sid>\`` | PASS |
| TC-RVR-004 | `Review APPROVED.\nReview Session: \`<sid>\`` | PASS |
| TC-RVR-005 | `## Review Verdict\n\nApproved.\nReview Session: \`<sid>\`` | PASS (verdict on line 2) |
| TC-RVR-006 | `Review findings:\n1. Missing test\nReview Session: \`<sid>\`` | FAIL |
| TC-RVR-007 | `Review FAILED — see below.\nReview Session: \`<sid>\`` | FAIL |
| TC-RVR-008 | `Changes requested.\nReview Session: \`<sid>\`` | FAIL |
| TC-RVR-009 | Comment without the session-id trailer | NO MATCH (security: spoofing protection) |
| TC-RVR-010 | Comment with a different session-id | NO MATCH |
| TC-RVR-011 | `LGTM but Review findings: typo` (ambiguous: both patterns) | FAIL (conservative — prefer FAIL on ambiguity) |

## Out of scope

- The cleanup-trap label transitions — already covered by existing
  tests and not changed by this PR.
- The agent's actual prompt-following behavior — untestable in a unit
  test; covered by the prompt nudge in Part 2.
