# Test Cases — create-issue AC verification-surface guidance (#273)

Static-grep regression tests pinning the documentation/process guidance added to
the `create-issue` skill so future doc rewrites cannot silently relax it. Mirrors
the #120 `test-create-issue-dependencies-guidance.sh` harness
(`extract_section` / `assert_contains`).

The skill change is prevention-at-authoring: separate **pre-merge verifiable** ACs
from **not pre-merge verifiable** ones, name the verification surface, and split a
genuine post-merge/prod-only criterion into a non-blocking, non-autonomous
follow-up — because a blocking AC the autonomous dev/review loop cannot satisfy
pre-merge is a known driver of non-terminating dev↔review cycles.

## Files under test

| File | Role |
|------|------|
| `skills/create-issue/references/ac-verification.md` (NEW) | Authority doc: rubric, reuse-surface, split procedure, warnings, 2 worked examples |
| `skills/create-issue/SKILL.md` | Step 1 prompt, Writing Guidelines bullet, Step 4 advisory self-scan, ref link |
| `skills/create-issue/references/issue-templates.md` | Bug-template AC/Deps parity fix + pre-merge note on both AC sections |
| `tests/unit/test-create-issue-ac-verification-guidance.sh` (NEW) | This regression suite |

## Test scenarios

### Group A — `references/ac-verification.md` anchors (TC-ACV-001..010)

| ID | Scenario | Expected (needle present in ref doc) |
|----|----------|--------------------------------------|
| TC-ACV-001 | Classification rubric present | `pre-merge verifiable` AND `not pre-merge verifiable` |
| TC-ACV-002 | Author must name the surface + evidence | `name the surface` / `expected evidence` |
| TC-ACV-003 | Reuse-existing-preview guidance | `PR-preview` + `same code path` |
| TC-ACV-004 | Split-to-follow-up: create follow-up FIRST | `create the` ... `follow-up` ... `FIRST` |
| TC-ACV-005 | Follow-up must NOT be autonomous | `do NOT add` + `autonomous` |
| TC-ACV-006 | Follow-up referenced under Out of Scope, NEVER Dependencies | `do NOT list it under` + `Dependencies` |
| TC-ACV-007 | Hedged loop-driver warning (issue wording) | `known driver` + `non-terminating` |
| TC-ACV-008 | `no-auto-close` clarification | `no-auto-close` + `fails the review gate` |
| TC-ACV-009 | Worked Example 1 — post-merge replay reframed to PR-preview E2E | `Example 1` |
| TC-ACV-010 | Worked Example 2 — genuine post-merge split into follow-up | `Example 2` |

### Group B — `SKILL.md` anchors (TC-ACV-011..015)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-ACV-011 | Step 1 adds per-AC "is this pre-merge verifiable?" prompt | `pre-merge verifiable` in Step 1 region |
| TC-ACV-012 | Writing Guidelines "AC verification surface" bullet | `verification surface` in Writing Guidelines |
| TC-ACV-013 | Step 4 advisory self-scan, AC-checkbox-lines only | `advisory` + `AC checkbox lines` in Step 4 |
| TC-ACV-014 | Step 4 long-tail phrases listed | `after merge` + `in production` + a long-tail token (`soak`/`rollout`) |
| TC-ACV-015 | SKILL.md links to the ref doc | `references/ac-verification.md` |

### Group C — `issue-templates.md` anchors (TC-ACV-016..020)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-ACV-016 | Bug template now has `## Acceptance Criteria` (parity fix) | `## Acceptance Criteria` appears **twice** in file (count assertion) |
| TC-ACV-017 | Bug template now has `## Dependencies` (parity fix) | `## Dependencies` appears **twice** in file (count assertion) |
| TC-ACV-018 | Feature AC section carries pre-merge note | note present in first AC section |
| TC-ACV-019 | Bug AC section carries pre-merge note | note present in second AC section |
| TC-ACV-020 | Pre-merge note references the surface concept | `verification surface` in the always-present note |
| TC-ACV-021 | Note is a **visible** blockquote in BOTH AC sections (not an HTML comment GitHub hides) | both note lines begin with the `>` blockquote marker |
| TC-ACV-022 | Note never sits inside an HTML comment | awk in-comment scan finds 0 occurrences between `<!--` / `-->` |

## Acceptance criteria for this change (pre-merge verifiable)

- [ ] **Surface**: CI job `hermetic-unit` runs `tests/unit/test-*.sh`; the new
  `test-create-issue-ac-verification-guidance.sh` passes (all TC-ACV-* green).
  Expected evidence: green `Hermetic / Unit + conformance` check on the PR.
- [ ] **Surface**: the pre-existing `#120` test
  `test-create-issue-dependencies-guidance.sh` still passes (no harness regression).
  Expected evidence: same CI check green.
