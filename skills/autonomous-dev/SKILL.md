---
name: autonomous-dev
description: >
  TDD development workflow with git worktree isolation. Covers design canvas,
  test-first development, code review, CI verification, and E2E testing.
  Supports interactive and fully autonomous modes for GitHub issue implementation.
---

# TDD Development Workflow

A complete development workflow enforcing test-driven development, git worktree isolation, code review, CI verification, and E2E testing. Works in two modes: interactive (default) for human-guided sessions, and autonomous for fully unattended GitHub issue implementation.

> **NON-NEGOTIABLE RULES -- Every step marked MANDATORY is required. You MUST NOT skip, defer, or ask the user whether to run these steps. Execute them automatically as part of the workflow. This includes: creating PRs, waiting for CI, running E2E tests, and addressing reviewer findings.**

---

## Mode Detection

### Interactive Mode (default)

Used when a developer is present. The workflow:
- Asks the user for design approval before proceeding to implementation
- Presents design canvases and waits for feedback
- Pauses at key decision points for user input
- Reports final status and lets the user decide when to merge

### Autonomous Mode

Triggered when running inside the `scripts/autonomous-dev.sh` wrapper. The workflow:
- Makes all decisions autonomously (see "Decision Making Guidelines" below)
- Posts progress comments to the GitHub issue instead of asking questions
- Creates design docs but skips interactive approval
- Stops after verification -- does not merge (the review agent handles that)
- Marks requirement checkboxes in the issue body as work progresses

---

## Cross-Platform Notes

### Hooks Support

| IDE/CLI | Hooks Support | Setup |
|---------|--------------|-------|
| Claude Code | Full | `hooks/README.md` |
| Kiro CLI | Full | `hooks/README.md` |
| Cursor | None | Follow steps manually |
| Windsurf | None | Follow steps manually |
| Gemini CLI | None | Follow steps manually |

### Tool Name Mapping

This skill uses generic language. Map to your IDE's tools:
- "Execute in your terminal" = Bash tool (Claude Code), terminal (Cursor), shell (Gemini CLI), etc.
- "Read the file" = Read tool, file viewer, or `cat`
- "Create or edit the file" = Write/Edit tool, editor, or manual editing
- "Use a subagent" = Task/Agent tool (Claude Code), or follow the steps manually if unsupported
- "Load the skill" = Skill tool (Claude Code), or read the referenced SKILL.md directly

### Workflow Enforcement (Optional Hooks)

If your IDE/CLI supports hooks (Claude Code, Kiro CLI), install them from `hooks/` for hard enforcement. See `hooks/README.md` for setup.

Without hooks, follow each step manually -- the discipline is the same.

---

## Development Workflow Overview

Follow this workflow for all feature development and bug fixes:

```
Step 1:  DESIGN CANVAS (Pencil MCP, if available)
Step 2:  CREATE GIT WORKTREE (MANDATORY)
Step 3:  WRITE TEST CASES (TDD)
Step 4:  IMPLEMENT CHANGES
Step 5:  LOCAL VERIFICATION
Step 6:  CODE SIMPLIFICATION
Step 7:  COMMIT AND CREATE PR          -- MANDATORY
Step 8:  PR REVIEW AGENT               -- MANDATORY
Step 9:  WAIT FOR ALL CI CHECKS        -- MANDATORY
Step 10: ADDRESS REVIEWER BOT FINDINGS -- MANDATORY
Step 11: ITERATE UNTIL NO FINDINGS
Step 12: E2E TESTS & READY FOR MERGE   -- MANDATORY
Step 13: CLEANUP WORKTREE
```

---

## Step 1: Design Canvas

**Available if your IDE has Pencil MCP.** If Pencil MCP is not available, create a design document (`docs/designs/<feature>.md`) manually instead.

### When to Create a Design Canvas

- New UI components or pages
- Feature implementations with user-facing changes
- Architecture decisions that benefit from visualization
- Complex data flows or state management

### Pencil MCP Workflow

1. **Check editor state**: call `get_editor_state()` to see if a `.pen` file is open.
2. **Open or create design file**: call `open_document("docs/designs/<feature>.pen")` or `open_document("new")`.
3. **Get design guidelines** (if needed): call `get_guidelines(topic="landing-page|table|tailwind|code")`.
4. **Get style guide** for consistent design: call `get_style_guide_tags()` then `get_style_guide(tags=[...])`.
5. **Create design elements**: call `batch_design(operations)` to create UI mockups, component hierarchy diagrams, data flow visualizations, and architecture diagrams.
6. **Validate design visually**: call `get_screenshot()` to verify the design looks correct.
7. **Document design decisions**: add text annotations explaining choices, component specifications, and interaction patterns.

### Design Canvas Template Structure

```
Feature: <Feature Name>
Date: YYYY-MM-DD
Status: Draft | In Review | Approved

- UI Mockup / Wireframe
- Component Architecture (component tree, props/state flow)
- Data Flow Diagram (API calls, state management)
- Design Notes (key decisions, accessibility, responsive behavior)
```

### Design Approval

- **Interactive mode**: Present the design canvas to the user, get explicit approval, document feedback, update status to "Approved."
- **Autonomous mode**: Create the design doc and proceed immediately -- no approval gate.

---

## Step 2: Create Git Worktree (MANDATORY)

**Every change MUST be developed in an isolated git worktree. Never develop directly on the main workspace.**

> Enforced by `block-commit-outside-worktree.sh` hook (if hooks are installed). Commits outside worktrees are automatically blocked. Direct pushes to main are blocked by `block-push-to-main.sh`.

### Why Worktrees?

- **Isolation**: Each feature/fix gets its own directory, preventing cross-contamination
- **Parallel work**: Multiple features can be in progress simultaneously
- **Clean main workspace**: The main checkout stays on `main`, ready for quick checks
- **Safe rollback**: Discard a worktree without affecting the main workspace

### Worktree Creation Process

Execute in your terminal:

```bash
# 1. Determine branch name based on change type
#    feat/<name>, fix/<name>, refactor/<name>, etc.
BRANCH_NAME="feat/my-feature"

# 2. Create worktree with new branch from main
git worktree add .worktrees/$BRANCH_NAME -b $BRANCH_NAME

# 3. Enter the worktree
cd .worktrees/$BRANCH_NAME

# 4. Install dependencies (use your project's package manager)
npm install  # or: bun install, yarn install, pnpm install

# 5. Verify clean baseline
npm run build && npm test
```

### Directory Convention

| Item | Value |
|------|-------|
| Worktree root | `.worktrees/` (project-local, gitignored) |
| Path pattern | `.worktrees/<branch-name>` |
| Example | `.worktrees/feat/user-authentication` |

### Safety Checks

Before creating any worktree, verify `.worktrees/` is in `.gitignore`:

```bash
git check-ignore -q .worktrees 2>/dev/null || echo "WARNING: .worktrees not in .gitignore!"
```

### All Subsequent Steps Run INSIDE the Worktree

After creating the worktree, **all development commands** (test, lint, build, commit, push) are executed from within the worktree directory. The main workspace is not touched until cleanup.

---

## Step 3: Write Test Cases (TDD)

Before writing any implementation code:

1. Read the design canvas and requirements
2. Identify all user scenarios, edge cases, and error handling paths
3. Create or edit the test case document: `docs/test-cases/<feature>.md`
   - List all test scenarios (happy path, edge cases, error handling)
   - Assign test IDs (e.g., `TC-AUTH-001`)
   - Define expected results and acceptance criteria
4. Create unit test skeletons
5. Create E2E test cases if applicable

---

## Step 4: Implement Changes

- Write code following the test cases (inside the worktree)
- Write new unit tests for new functionality
- Update existing tests if behavior changed
- Ensure implementation covers all test scenarios

---

## Step 5: Local Verification

Execute in your terminal:

```bash
npm run build
npm run test
```

Fix any failures before proceeding. Deploy and verify locally if applicable.

---

## Step 6: Code Simplification

1. Use a subagent if your IDE supports them (e.g., `code-simplifier:code-simplifier`), otherwise review the code manually for unnecessary complexity.
2. Address simplification suggestions.
3. Mark complete (if hooks are installed):
   ```bash
   hooks/state-manager.sh mark code-simplifier
   ```

---

## Step 7: Commit and Create PR (MANDATORY)

### Commit

Execute in your terminal:

```bash
git add <files>
git commit -m "type(scope): description"
git push -u origin <branch-name>
```

### Create PR

```bash
gh pr create --title "type(scope): description" --body "$(cat <<'EOF'
## Summary
<1-3 bullet points describing the change>

## Design
- [ ] Design canvas created (`docs/designs/<feature>.pen`)
- [ ] Design approved

## Test Plan
- [ ] Test cases documented (`docs/test-cases/<feature>.md`)
- [ ] Build passes (`npm run build`)
- [ ] Unit tests pass (`npm run test`)
- [ ] CI checks pass
- [ ] Code simplification review passed
- [ ] PR review agent review passed
- [ ] Reviewer bot findings addressed (no new findings)
- [ ] E2E tests pass

## Checklist
- [ ] New unit tests written for new functionality
- [ ] E2E test cases updated if needed
- [ ] Documentation updated if needed
EOF
)"
```

### Update PR Checklist

After completing each step, update the PR description:

```bash
gh pr view {pr_number} --json body --jq '.body' > /tmp/pr_body.md
# Edit the checklist (mark items as [x])
gh pr edit {pr_number} --body "$(cat /tmp/pr_body.md)"
```

---

## Step 8: PR Review Agent (MANDATORY)

1. Use a subagent if your IDE supports them (e.g., `/pr-review-toolkit:review-pr`), otherwise perform a self-review against the PR diff.
2. Address findings by severity:
   - Critical/Severe: Must fix
   - High: Must fix
   - Medium: Should fix
   - Low: Optional
3. Mark complete (if hooks are installed):
   ```bash
   hooks/state-manager.sh mark pr-review
   ```

---

## Step 9: Wait for All CI Checks (MANDATORY -- DO NOT SKIP)

Execute in your terminal:

```bash
# Watch all checks until completion
gh pr checks {pr_number} --watch --interval 30
```

ALL checks must pass: Lint, Unit Tests, Build, Deploy Preview, E2E Tests.

If ANY check fails: analyze logs, fix, push, re-watch. DO NOT proceed until every check shows "pass."

### Checks to Monitor

| Check | Description | Action if Failed |
|-------|-------------|------------------|
| CI / build-and-test | Build + unit tests | Fix code or update snapshots |
| Security Scan | SAST, npm audit | Fix security issues |
| Amazon Q Developer | Security review | Address findings, retrigger with `/q review` |
| Codex | AI code review | Address findings, retrigger with `/codex review` |
| Other review bots | Various checks | Address findings, retrigger per bot docs |

---

## Step 10: Address Reviewer Bot Findings (MANDATORY)

Multiple review bots can provide automated code review findings on PRs:

| Bot | Trigger Command | Bot Username |
|-----|-----------------|------------|
| Amazon Q Developer | `/q review` | `amazon-q-developer[bot]` |
| Codex | `/codex review` | `codex[bot]` |
| Other bots | See bot documentation | Varies |

### Handling Bot Review Findings

1. **Review all comments** -- read each finding carefully
2. **Determine action**:
   - Valid issue: fix the code and push
   - False positive: reply explaining the design decision
3. **Reply to each thread** -- use direct reply, not a general PR comment
4. **Resolve each thread** -- mark conversation as resolved
5. **Retrigger review** -- comment with the appropriate trigger (e.g., `/q review`, `/codex review`)

### Retrigger Bot Reviews

```bash
# Amazon Q Developer
gh pr comment {pr_number} --body "/q review"

# Codex
gh pr comment {pr_number} --body "/codex review"
```

Wait 60-90 seconds for the review to complete, then check for new comments.

---

## Step 11: Iterate Until No Findings

**Repeat until review bots find no more issues:**

1. Address findings (fix code or explain design)
2. Reply to each comment thread
3. Resolve all threads
4. Trigger review command (`/q review`, `/codex review`, etc.)
5. Wait 60-90 seconds
6. Check for new findings
7. **If new findings: repeat from step 1**
8. **Only proceed when no new positive findings appear**

---

## Step 12: E2E Tests & Ready for Merge (MANDATORY -- DO NOT SKIP)

1. Run E2E tests against the deployed preview environment (all tests must pass; skipped agent-dependent tests are acceptable)
2. Mark complete (if hooks are installed):
   ```bash
   hooks/state-manager.sh mark e2e-tests
   ```
3. Update PR checklist to show all items complete
4. **STOP HERE**: report status to the user (interactive mode) or post a summary comment on the issue (autonomous mode)
5. User or review agent decides when to merge

---

## Step 13: Cleanup Worktree

After the PR is merged or closed, execute in your terminal:

```bash
# Return to main workspace
cd $(git rev-parse --show-toplevel)

# Remove the worktree
git worktree remove .worktrees/<branch-name>

# Prune stale worktree references
git worktree prune
```

---

## Review Thread Management

### Critical Rules

- **Reply DIRECTLY to each comment thread** -- NOT a single general PR comment
- **Resolve each conversation after replying**
- **Wrong approach**: `gh pr comment {pr} --body "Fixed all issues"` (does not close threads)

### Reply to Review Comments

```bash
# Get comment IDs
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  --jq '.[] | {id: .id, path: .path, body: .body[:50]}'

# Reply to specific comment
gh api repos/{owner}/{repo}/pulls/{pr}/comments \
  -X POST \
  -f body="Addressed in commit abc123 - <description of fix>" \
  -F in_reply_to=<comment_id>
```

### Resolve Review Threads

```bash
# Get unresolved thread IDs
gh api graphql -f query='
query {
  repository(owner: "{owner}", name: "{repo}") {
    pullRequest(number: {pr}) {
      reviewThreads(first: 50) {
        nodes {
          id
          isResolved
          comments(first: 1) {
            nodes { body }
          }
        }
      }
    }
  }
}' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false) | .id'

# Resolve a thread
gh api graphql -f query='
mutation {
  resolveReviewThread(input: {threadId: "<thread_id>"}) {
    thread { isResolved }
  }
}'
```

### Batch Resolve All Threads

```bash
scripts/resolve-threads.sh {owner} {repo} {pr_number}
```

---

## Common Response Patterns

### For Valid Issues

```
Addressed in commit {hash} - {description of fix}
```

### For False Positives

```
This is by design because {explanation}. The {feature} requires {justification}.
```

### For Documentation Concerns

```
The referenced file {filename} exists in the repository at {path}. This is a reference document, not executable code.
```

---

## Quick Reference

| Task | Command |
|------|---------|
| Create worktree | `git worktree add .worktrees/<branch> -b <branch>` |
| List worktrees | `git worktree list` |
| Remove worktree | `git worktree remove .worktrees/<branch>` |
| Prune worktrees | `git worktree prune` |
| Create design | Pencil MCP tools (if available) |
| Create PR | `gh pr create --title "..." --body "..."` |
| Watch checks | `gh pr checks {pr} --watch` |
| Get comments | `gh api repos/{o}/{r}/pulls/{pr}/comments` |
| Reply to comment | `gh api ... -X POST -F in_reply_to=<id>` |
| Resolve thread | GraphQL `resolveReviewThread` mutation |
| Trigger Q review | `gh pr comment {pr} --body "/q review"` |
| Trigger Codex review | `gh pr comment {pr} --body "/codex review"` |
| Reply to comment (script) | `scripts/reply-to-comments.sh {owner} {repo} {pr} {comment_id} "{message}"` |
| Resolve all threads (script) | `scripts/resolve-threads.sh {owner} {repo} {pr}` |
| Mark hook state | `hooks/state-manager.sh mark <action>` |
| List hook states | `hooks/state-manager.sh list` |

---

## Autonomous Mode Specifics

The following sections apply only when running in autonomous mode (inside `scripts/autonomous-dev.sh`).

### Decision Making Guidelines

When you need to make a decision that would normally require user input:

| Situation | Decision |
|-----------|----------|
| Architecture choice between options | Pick the simpler, more maintainable option |
| UI/UX design decisions | Follow existing patterns in the codebase |
| Scope ambiguity | Implement the minimum viable interpretation |
| Test coverage questions | Write tests for happy path + main error cases |
| Performance vs simplicity | Choose simplicity unless performance is the issue's focus |

### Resume Awareness

On resume (or new session for a previously started issue), perform these checks before writing code:

1. **Read the issue body**: `gh issue view <ISSUE_NUMBER> --json body -q '.body'`
2. **Parse the `## Requirements` section** for checkbox states
3. Items marked `- [x]` are already implemented -- **skip them**
4. Items marked `- [ ]` are remaining work -- implement these
5. **Read review feedback from issue comments** -- look for "Review findings:" comments
6. **Read PR inline review comments** -- these contain file-specific feedback from the review agent:
   ```bash
   # Find the PR linked to this issue
   PR_NUM=$(gh pr list --repo <REPO> --state open --json number,body \
     -q '[.[] | select(.body | test("#<ISSUE_NUMBER>"))] | .[0].number // empty')

   # Fetch inline review comments
   gh api repos/<REPO>/pulls/$PR_NUM/comments \
     --jq '.[] | "\(.path):\(.line // .original_line) — \(.body)"'
   ```
7. **Address ALL feedback** from both issue comments and PR inline comments
8. **Reply to and resolve** each PR review thread after fixing:
   ```bash
   scripts/reply-to-comments.sh <owner> <repo> <pr> <comment_id> "Fixed in <commit>"
   scripts/resolve-threads.sh <owner> <repo> <pr>
   ```
9. Verify the existing code in the worktree matches the checked items (quick sanity check)

This prevents duplicate work and ensures review feedback is fully addressed on resume.

### Marking Requirements Progress

After implementing each requirement item from the issue, mark the corresponding checkbox in the issue body. This provides real-time visibility and enables resume on crash.

```bash
bash scripts/mark-issue-checkbox.sh <ISSUE_NUMBER> "<checkbox text>"
```

Where `<checkbox text>` is a substring matching the requirement line in the issue body. Use enough text to uniquely identify the checkbox.

**When to mark:**
- Mark each requirement **immediately after implementing it** (not in a batch at the end)
- If a requirement spans multiple sub-items, mark the sub-items individually
- If implementation covers a group of related items, mark them together after the group is done

**Do NOT mark:**
- Acceptance Criteria items (those are for the review agent)
- Items you have not implemented yet

### Applying Pre-existing Changes

Before starting development, check the issue body for a `## Pre-existing Changes` section. This section contains workspace changes that the issue creator prepared beforehand (e.g., regression tests, prototype code).

**Detection**: After creating the worktree and before writing any code, scan the issue body for:
1. A `## Pre-existing Changes` heading
2. Either a **branch reference** (`issue-context/<issue-number>`) or an **inline diff** block

**Applying from branch reference** (if `**Branch**: \`issue-context/<number>\`` is present):

```bash
# Option 1: Cherry-pick (preserves commit metadata)
git cherry-pick issue-context/<number>

# Option 2: Apply as patch (if cherry-pick conflicts)
git diff main...issue-context/<number> | git apply
git add -A
git commit -m "apply: pre-existing workspace changes from issue #<number>"
```

**Applying from inline diff** (if a diff code block is inside `<details>`):

```bash
git apply /tmp/pre-existing-changes.patch
rm /tmp/pre-existing-changes.patch
git add -A
git commit -m "apply: pre-existing workspace changes from issue #<number>"
```

**Error handling**: If cherry-pick or apply fails due to conflicts, log a warning in the issue comment and proceed with normal development. If the branch does not exist, skip silently.

### Bot Review Integration

After creating a PR, trigger and handle any configured bot reviewers (e.g., Amazon Q Developer, Codex).

Some bot reviewers ignore comments posted by GitHub App bot accounts. If your project uses `scripts/gh-as-user.sh`, use it to trigger bot reviews so the comment is attributed to a real user:

```bash
bash scripts/gh-as-user.sh pr comment {pr_number} --body "/q review"
```

> Do NOT use the default `gh` wrapper (`gh-with-token-refresh.sh`) for bot review triggers -- it authenticates as a bot, which some reviewers ignore. All other `gh` operations should continue using the default `gh` wrapper.

**Wait for bot review** (poll every 30 seconds, timeout 3 minutes):

```bash
for i in $(seq 1 6); do
  REVIEWS=$(gh api repos/{owner}/{repo}/pulls/{pr_number}/reviews \
    --jq '[.[] | select(.user.login == "<bot-login>")] | length')
  if [ "$REVIEWS" -gt 0 ]; then
    echo "Bot review found"
    break
  fi
  sleep 30
done
```

If bot review does not appear within 3 minutes, proceed without it -- the review agent will re-trigger bot review during its verification step.

### Local E2E Verification (Before Push)

Before pushing changes that modify E2E tests or UI components, verify the changes are sound:

1. **If E2E tests were modified**, run a quick local check:
   ```bash
   # Verify TypeScript compilation (if using TypeScript)
   bunx tsc --noEmit --project tsconfig.json

   # Verify test helper imports are correct
   grep -l "takeScreenshot" e2e/*.spec.ts
   ```

2. **Screenshot generation will be verified in CI** -- ensure your Playwright config includes a JSON reporter and screenshot helpers save to a known directory.

3. **Local dev server** for local E2E testing:
   ```bash
   # Option A: Let Playwright start the dev server automatically
   bunx playwright test

   # Option B: Start dev server manually first
   PLAYWRIGHT_BASE_URL=http://localhost:3000 bunx playwright test
   ```

### Error Recovery

- If a tool/API fails, retry once with a brief pause
- If CI fails, analyze logs, fix, and push again (max 3 attempts)
- If you cannot resolve an issue after 3 attempts, post a detailed error comment on the issue and exit
- The wrapper script will transition the issue to `pending-review` regardless of exit code

---

## References

For detailed commands and conventions, consult:
- **`references/commit-conventions.md`** -- Branch naming and commit message conventions
- **`references/review-commands.md`** -- Complete `gh` CLI and GraphQL command reference
