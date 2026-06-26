---
name: create-issue
description: >
  Use when the user asks to create a GitHub issue, file a bug, request a feature,
  open a tracking issue, or break a feature into multiple sub-issues. Guides
  interactive issue drafting with structured templates, workspace-change
  attachment, dependency linking, and the optional `autonomous` label for the
  automated dev pipeline.
---

# Create GitHub Issue

Create well-structured GitHub issues from user descriptions through interactive clarification.

## Repository Detection

Detect the repository from the current git remote:

```bash
REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
# Splits into OWNER and REPO_NAME
```

If detection fails, ask the user for the target repository.

## Process

### Step 1: Understand the Request

When the user describes a feature or bug, gather context through clarifying questions. Do NOT create the issue immediately.

**For features, clarify:**
- What is the user-facing goal? (not implementation details)
- What are the acceptance criteria? (how to verify it works)
- **For each acceptance criterion, is it _pre-merge verifiable_?** Can its evidence
  be obtained before the PR merges, from a surface the autonomous dev/review agents
  can reach — a CI job, a PR-preview URL, a staging command, a local repro? Prefer
  pre-merge-verifiable ACs and have the author **name the surface + expected
  evidence**. If a criterion is *not* pre-merge verifiable (needs deploy/prod, real
  users, a time soak, an external approval, prod telemetry, or credentials the bot
  lacks), first check whether an existing PR-preview/staging path already covers the
  same code path with the same input; if it genuinely cannot be verified pre-merge,
  split it into a separate **non-blocking, non-`autonomous` follow-up** (see
  **`references/ac-verification.md`**). A blocking AC the loop cannot satisfy
  pre-merge is a known driver of non-terminating dev↔review loops.
- Are there UI/UX implications?
- What existing functionality does this relate to?
- Priority and scope constraints

**For bugs, clarify:**
- Steps to reproduce
- Expected vs actual behavior
- Environment (prod, staging, PR preview)
- Severity (blocking, degraded, cosmetic)
- Any error messages or logs
- **How will the fix be verified — and is that verification _pre-merge verifiable_?**
  A bug's acceptance criterion is most often "a regression test fails before the fix
  and passes after" (pre-merge verifiable — name the surface: the CI `unit`/E2E job).
  Beware framing it as a *post-merge/prod replay* ("verify by replaying the failing
  batch through the deployed pipeline"): if an existing PR-preview/staging path
  already exercises the same code path with the same input, point the criterion at
  that surface instead. If the fix genuinely can only be confirmed post-deploy, split
  that confirmation into a separate **non-blocking, non-`autonomous` follow-up** (see
  **`references/ac-verification.md`**). This applies to bug fixes too — a blocking AC
  the loop cannot satisfy pre-merge is a known driver of non-terminating dev↔review
  loops regardless of issue type. (Note: the bug `## Environment` field may legitimately
  be `prod` — that's the *repro* environment, not an acceptance criterion.)

Ask 2-3 focused questions per round. Stop when there is enough information to write a clear issue.

> The per-AC **pre-merge-verifiable** classification above applies to **both** issue
> types — features *and* bugs. Do not collect a bug report with a blocking prod-only
> acceptance criterion any more than you would for a feature.

### Step 2: Draft the Issue

Use the appropriate template based on issue type. For full template content, consult **`references/issue-templates.md`**.

Both templates include these required sections:
- **Summary** / **Motivation** (feature) or **Steps to Reproduce** (bug)
- **Requirements** with checkboxes (feature) or **Expected/Actual Behavior** (bug)
- **Testing Requirements** (mandatory TDD section: test cases doc, unit tests, E2E tests)
- **Acceptance Criteria** with checkboxes
- **Dependencies** section for issue ordering

### Step 3: Detect & Attach Workspace Changes

After drafting the issue, check the workspace for local changes that may provide useful context for the autonomous dev agent. For the complete detection, attachment, and cleanup procedure, consult **`references/workspace-changes.md`**.

Summary:
1. Run `git status --short` — skip if no changes
2. Summarize changes and ask user for confirmation
3. Choose strategy based on diff size: inline (< 500 lines), branch push (>= 500 lines), or file list fallback
4. Add a `## Pre-existing Changes` section to the issue body
5. Optionally clean up local changes after attachment

### Step 4: Confirm with User

Present the draft issue to the user with:
1. Proposed title (concise, descriptive)
2. Full issue body (including Pre-existing Changes section if applicable)
3. Proposed labels
4. Whether to add `autonomous` label

Use AskUserQuestion to confirm:
- "Does this issue look correct? Should I create it?"
- Ask about autonomous label: whether AI should handle this automatically

**Advisory pre-merge-verifiability self-scan** (you are the linter — no runtime
script): self-scan the draft's **AC checkbox lines only** (the `- [ ]` lines under
`## Acceptance Criteria`, NOT other fields — this avoids false positives on the bug
template's `## Environment` field, whose `Stage:` value may legitimately be `prod`)
for phrasing that signals a not-pre-merge AC:
`post-merge`, `after merge`, `in production`, **and the long tail** — `live users`,
`soak`, `rollout`, `approver`, `prod telemetry`, `manual smoke`. If a **blocking** AC
matches and there is no paired follow-up split, **warn the author (advisory, not
blocking)** and offer to split it per **`references/ac-verification.md`** §3 (create
a non-blocking, non-`autonomous` follow-up; reference it under `## Out of Scope`,
never under `## Dependencies`). Do not hard-fail the draft on a match.

### Step 5: Create the Issue

Use GitHub MCP tools or `gh` CLI to create the issue with:
- `title`: The confirmed title
- `body`: The confirmed body
- `labels`: Appropriate labels (see Label Guide below)

Report the created issue URL to the user.

**If branch push was deferred (large diff strategy):**

After the issue is created and the issue number is known:
1. Execute the branch push commands from Step 3 using the actual issue number
2. Update the issue body to include the branch reference section

## Label Guide

| Label | When to Apply |
|-------|-------------|
| `bug` | Bug reports |
| `enhancement` | Feature requests |
| `autonomous` | User confirms AI should handle dev/test/review/merge automatically |
| `no-auto-close` | Used with `autonomous` -- AI handles dev/test/review but stops before merge, requiring manual approval |
| `documentation` | Documentation-only changes |
| `good first issue` | Simple, well-scoped tasks |

## Autonomous Label Decision

After drafting the issue, explicitly ask the user whether to add the `autonomous` label.

Provide guidance on when `autonomous` is appropriate:
- **Good fit**: Well-defined scope, clear acceptance criteria, follows existing patterns, no ambiguous design decisions
- **Poor fit**: Requires significant architecture decisions, needs user input during development, involves sensitive infrastructure changes, exploratory/research tasks

Frame the question as:
> "Should this issue be handled by the autonomous development pipeline? The AI will automatically develop, test, review, and merge the changes. This works best for well-defined tasks with clear acceptance criteria."

**If the user selects `autonomous`, also ask about `no-auto-close`:**

> "Should this issue also have the `no-auto-close` label? With this label, the AI will handle development, testing, and review, but will **stop before merging** -- you'll be notified to make the final merge decision. This is recommended for sensitive infrastructure changes, features needing product sign-off, or experimental work."

**Label interaction summary:**
- `autonomous` alone = AI handles dev/test/review **and** auto-merges on pass
- `autonomous` + `no-auto-close` = AI handles dev/test/review but **stops before merge**, notifying the owner for manual approval

## Writing Guidelines

- **Title**: Start with verb, be specific. "Add pagination to plans list page" not "Plans page improvement"
- **Body**: Write for an AI developer who has access to the full codebase but no verbal context from this conversation
- **Acceptance criteria**: Must be objectively verifiable, not subjective
- **AC verification surface**: For each acceptance criterion, classify it as **pre-merge verifiable** (evidence obtainable before merge — name the surface: CI job, PR-preview URL, staging command, or local repro — plus the expected evidence) vs **not pre-merge verifiable** (needs deploy/prod, real users, time soak, external approval, prod telemetry, or credentials the bot lacks). Prefer the former, and always **name the surface + expected evidence** rather than asserting the outcome alone. A genuinely not-pre-merge criterion belongs in a separate **non-blocking, non-`autonomous` follow-up** (reference it under `## Out of Scope`, never `## Dependencies`) — leaving it as a blocking AC is a known driver of non-terminating dev↔review loops. Full rubric, reuse-existing-preview guidance, the split procedure, and worked examples: **`references/ac-verification.md`**.
- **Scope**: Prefer smaller, focused issues over large multi-part ones
- **References**: Link to related issues, PRD sections, or code paths when relevant
- **Dependencies**: The `## Dependencies` section must contain **only** issues that must be closed/merged before this issue can be started. Do NOT include: parent epics referenced for context, issues this one unblocks, or any `#NNN` reference that isn't a true blocker. The autonomous dispatcher parses this section literally — any open list-item ref causes this issue to be silently skipped until it closes/merges. Parsing scope: **list-item lines only** (lines starting with `-`, `*`, or `1.`); prose and blockquotes between `## Dependencies` and the next `## ` are ignored. On a list item, both `#N` (same-repo) and `owner/repo#N` (cross-repo) are recognized. If there are no blockers, write exactly `None`. Create issues in dependency order so earlier issue numbers are known when writing later ones.
- **Testing Requirements**: ALWAYS include the "Testing Requirements" section. The dev agent follows the project's TDD workflow but has been observed to skip E2E tests or test-case docs when the issue doesn't explicitly call them out. Be specific about:
  - Key scenarios each test type must cover (2-4 bullet points)
  - For bugs: the regression test must fail before the fix and pass after

## Multi-Issue Creation

When breaking a large feature into multiple issues:

1. **Create issues in dependency order** — issues with no dependencies first, then issues that depend on them. This ensures issue numbers are known when writing dependency references.
2. **Populate the `## Dependencies` section** in each issue body with `#N` (same-repo) or `owner/repo#N` (cross-repo) list-item links to **directly blocking** issues only. Do not reference parent epics, context issues, or issues this one unblocks — the dispatcher treats every list-item ref in that section as a hard blocker. Refs in prose or blockquotes are ignored.
3. **Use a consistent naming scheme** — prefix titles with the project/feature name for easy filtering (e.g., "MyProject: Add DynamoDB infrastructure").
4. **Cross-reference the plan** — if an implementation plan exists, link each issue to the relevant plan tasks/chunks.
5. **The dispatcher skips blocked issues** — issues with open dependencies in the `## Dependencies` section are ignored by the autonomous dispatcher until all dependencies are resolved (closed/merged).

---

## References

For detailed content, consult:
- **`references/issue-templates.md`** -- Full feature and bug issue templates with all required sections
- **`references/ac-verification.md`** -- Pre-merge-vs-not-pre-merge AC classification rubric, reuse-existing-preview guidance, the split-to-non-blocking-follow-up procedure, the `no-auto-close` clarification, and two worked examples (loop prevention)
- **`references/workspace-changes.md`** -- Complete workspace change detection, attachment strategies, and cleanup procedure
