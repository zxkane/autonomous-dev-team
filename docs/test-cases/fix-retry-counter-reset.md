# Test Cases: Fix retry counter reset (#41)

## TC-RCR-001: SKILL.md has stalled cutoff logic

**Steps:** Verify SKILL.md Step 4 references "Marking as stalled" for cutoff
**Expected:** Content check passes

## TC-RCR-002: SKILL.md filters crashes by timestamp

**Steps:** Verify SKILL.md uses createdAt comparison to filter comments
**Expected:** Content check passes

## TC-RCR-003: Backward compatible when no stalled history

**Steps:** Verify the logic handles the case where no stalled comment exists
**Expected:** Content check passes (fallback to count all)
