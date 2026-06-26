# Issue Templates

## Feature Template

```markdown
## Summary
<1-2 sentence description of the feature>

## Motivation
<Why this feature is needed, what problem it solves>

## Requirements
- [ ] <Requirement 1>
- [ ] <Requirement 2>
- [ ] <Requirement 3>

## Testing Requirements

> **Mandatory**: The dev agent MUST follow the project's TDD workflow.
> This section specifies the expected test artifacts. All listed items are required for PR approval.

### Test Cases Document
- [ ] Create test case document with all test scenarios (ID format: `TC-<FEATURE>-NNN`)
- <List 2-4 key test scenarios the document must cover>

### Unit Tests
- [ ] Create unit tests for the new functionality
- [ ] Coverage target: >80%
- <List specific units to test: API handlers, utility functions, data transformations, etc.>

### E2E Tests
- [ ] Create E2E tests covering key user flows
- <List 2-4 key user flows the E2E tests must cover, e.g.:>
- [ ] <Happy path: user performs X and sees Y>
- [ ] <Edge case: empty state / error state / unauthorized access>

## Acceptance Criteria

> **Classify each criterion: is it _pre-merge verifiable_?** PRE-MERGE VERIFIABLE =
> evidence obtainable before merge — **name the verification surface** (CI job, PR-preview URL,
> staging command, or local repro) **+ the expected evidence**. NOT pre-merge
> verifiable = needs deploy/prod, real users, time soak, external approval, prod
> telemetry, or credentials the bot lacks. Prefer pre-merge-verifiable criteria. A
> genuinely not-pre-merge criterion belongs in a separate **NON-blocking,
> NON-`autonomous` follow-up** (reference it under `## Out of Scope`, **never**
> `## Dependencies`) — a blocking AC the autonomous loop cannot satisfy pre-merge is
> a known driver of non-terminating dev↔review loops. See `references/ac-verification.md`.

- [ ] <Criterion 1 -- pre-merge verifiable; name the surface + expected evidence>
- [ ] <Criterion 2>

## Dependencies
<!--
  IMPORTANT: List ONLY issues that must be closed/merged before this issue can be started.
  Do NOT list:
    - Issues that this issue unblocks (i.e., issues that depend on THIS one)
    - Parent epics or meta-trackers referenced for context
    - Issues mentioned elsewhere in the body

  The autonomous dispatcher parses this section literally — any list-item ref
  that is still OPEN will cause this issue to be silently skipped until that
  ref is closed/merged. Parsing has two stages:
    1. Only LIST-ITEM lines (lines starting with `-`, `*`, or `1.`) are scanned.
       Prose, blockquotes (`> ...`), and headings between `## Dependencies` and
       the next `## ` are ignored — they will NOT block dispatch.
    2. On each list item, the dispatcher recognizes two ref shapes:
         - `#N`             — same-repo issue/PR (this repo)
         - `owner/repo#N`   — cross-repo issue/PR (resolved against owner/repo)
       Any open ref of either shape blocks this issue.

  Pick exactly ONE of the two shapes below (delete the other):
    - If there are no blocking prerequisites, write exactly: None
    - Otherwise, list each blocker on its own line:
        - #N (must be merged first because <specific reason>)
        - owner/repo#N (cross-repo blocker because <specific reason>)
-->
- None

## Design Considerations
<Architecture notes, API changes, data model impact -- if applicable>

## Out of Scope
<Explicitly list what this issue does NOT cover>
```

## Bug Template

```markdown
## Summary
<1-sentence description of the bug>

## Steps to Reproduce
1. <Step 1>
2. <Step 2>
3. <Step 3>

## Expected Behavior
<What should happen>

## Actual Behavior
<What actually happens>

## Environment
- Stage: <prod / staging / PR preview>
- Browser: <if applicable>
- Relevant logs: <error messages, log links>

## Severity
<Blocking / Degraded / Cosmetic>

## Possible Cause
<If known, suggest root cause or area of code>

## Testing Requirements

> **Mandatory**: The dev agent MUST create tests that prevent regression of this bug.

### Unit Tests
- [ ] Add regression test that fails before the fix and passes after
- [ ] Test must cover the exact reproduction scenario

### E2E Tests (if UI-related)
- [ ] Add or update E2E test to cover the fixed behavior
- [ ] Test the exact reproduction steps above end-to-end

## Acceptance Criteria

> **Classify each criterion: is it _pre-merge verifiable_?** PRE-MERGE VERIFIABLE =
> evidence obtainable before merge — **name the verification surface** (CI job, PR-preview URL,
> staging command, or local repro) **+ the expected evidence**. NOT pre-merge
> verifiable = needs deploy/prod, real users, time soak, external approval, prod
> telemetry, or credentials the bot lacks. Prefer pre-merge-verifiable criteria. A
> genuinely not-pre-merge criterion belongs in a separate **NON-blocking,
> NON-`autonomous` follow-up** (reference it under `## Out of Scope`, **never**
> `## Dependencies`) — a blocking AC the autonomous loop cannot satisfy pre-merge is
> a known driver of non-terminating dev↔review loops. See `references/ac-verification.md`.
>
> NOTE: the bug `## Environment` field above may legitimately say `prod` — that is the
> repro environment, NOT an acceptance criterion; the classification applies to the AC
> checkbox lines below.

- [ ] <Criterion 1 -- pre-merge verifiable; e.g. the regression test fails before
      the fix and passes after, green in the CI `unit` job (name the surface)>
- [ ] <Criterion 2>

## Dependencies
<!--
  List ONLY issues that must be closed/merged before this bug fix can be started.
  The autonomous dispatcher parses this section literally — any OPEN list-item ref
  (`#N` same-repo or `owner/repo#N` cross-repo) silently blocks dispatch until it
  closes/merges. Prose and blockquotes are ignored. If there are no blockers, write
  exactly: None.
-->
- None

## Out of Scope
<!-- The non-blocking home for any genuinely post-merge/prod-only verification the
     `## Acceptance Criteria` note told you to split out. Reference the follow-up
     issue here (prose) — NEVER under `## Dependencies` (that would hard-block the
     fix). Also list anything this bug fix deliberately does NOT cover. -->
<Explicitly list what this fix does NOT cover, incl. any post-deploy follow-up issue (non-blocking)>
```
