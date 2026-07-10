# Test Cases — create-issue agent-unwritable AC-surface scan (#457)

Static-grep regression tests pinning the documentation/process guidance added to
the `create-issue` skill so future doc rewrites cannot silently relax it. Mirrors
the #273 `test-create-issue-ac-verification-guidance.sh` harness
(`extract_section` / `assert_contains`).

The skill change extends the #273 advisory self-scan with a **second axis**:
pre-merge verifiable, but on a surface the dev/review agents' **scoped token**
cannot write to (PR body/description/title, PR metadata). Such an AC is
guaranteed to end in a `dev-actionable=false` stall regardless of how much
evidence the dev agent produces, because the surface itself is unreachable —
per the two-token split (#234), the dev agent's scoped token can post PR/issue
comments and commit files, but cannot edit PR metadata
(`Resource not accessible by integration`).

## Files under test

| File | Role |
|------|------|
| `skills/create-issue/references/ac-verification.md` | Documents the agent-writable-surface distinction (new §5) |
| `skills/create-issue/SKILL.md` | Step 4 advisory self-scan extended with agent-unwritable-surface phrasing + suggested rewrite |
| `tests/unit/test-create-issue-ac-surface-guidance.sh` (NEW) | This regression suite |

## Test scenarios

### Group A — `SKILL.md` Step 4 self-scan anchors (TC-AC-SURFACE-001..006)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-AC-SURFACE-001 | Step 4 lists the `in (the )?PR (body\|description\|title)` phrasing | pattern text present in Step 4 region |
| TC-AC-SURFACE-002 | Step 4 lists `PR metadata` phrasing | phrase present in Step 4 region |
| TC-AC-SURFACE-003 | Step 4 suggests rewording to "as a PR comment" | phrase present in Step 4 region |
| TC-AC-SURFACE-004 | Step 4 explains WHY (scoped token cannot edit PR metadata) | `scoped token` wording present |
| TC-AC-SURFACE-005 | Step 4 states the warning is advisory, not a hard fail, for this axis too | `advisory` present alongside the new phrasing |
| TC-AC-SURFACE-006 | SKILL.md still links to `references/ac-verification.md` | ref link present |

### Group B — `references/ac-verification.md` agent-writable-surface anchors (TC-AC-SURFACE-007..012)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-AC-SURFACE-007 | New section documents "agent-writable" surfaces | `agent-writable` present |
| TC-AC-SURFACE-008 | PR comment / issue comment / committed file named as agent-writable | all three phrases present |
| TC-AC-SURFACE-009 | PR body/title/labels/milestone named as maintainer-or-wrapper only | all four phrases present |
| TC-AC-SURFACE-010 | Doc references the two-token split (#234) reasoning | `scoped token` present |
| TC-AC-SURFACE-011 | Doc gives the canonical "in PR body" → "as a PR comment" rewrite example | both phrases present |
| TC-AC-SURFACE-012 | SKILL.md Step 4 cross-references this new section | ref doc link present in Step 4 region |

### Group C — scan-scope regression (TC-AC-SURFACE-013)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-AC-SURFACE-013 | Step 4 still scopes the scan to AC checkbox lines only (no widened scope for the new axis) | `AC checkbox lines` still present exactly where the #273 scan defines it |

## Acceptance criteria for this change (pre-merge verifiable)

- [ ] **Surface**: CI job `hermetic-unit` runs `tests/unit/test-*.sh`; the new
  `test-create-issue-ac-surface-guidance.sh` passes (all TC-AC-SURFACE-* green).
  Expected evidence: green `Hermetic / Unit + conformance` check on the PR.
- [ ] **Surface**: the pre-existing `#273` test
  `test-create-issue-ac-verification-guidance.sh` still passes (no harness
  regression from editing the same Step 4 region).
  Expected evidence: same CI check green.
