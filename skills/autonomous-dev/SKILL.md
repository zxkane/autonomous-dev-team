---
name: autonomous-dev
description: >
  Use to develop a feature or bug fix end-to-end through a TDD git-worktree
  workflow — interactively (developer-led) or unattended (autonomous-mode,
  driven by the dispatcher). Triggers on phrases like "implement issue #N",
  "fix this bug", "add a feature", "create a worktree", "write test cases",
  "push and open a PR", "check CI", "address review comments", "resolve
  review threads", "/q review", "/codex review", "implement this autonomously",
  or any partial step in the design → worktree → tests → implement → verify →
  review → PR → CI → E2E lifecycle. Interactive mode asks for decisions;
  autonomous mode makes decisions per autonomous-mode.md and posts progress
  comments to the GitHub issue.
hooks:
  PreToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/block-push-to-main.sh"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/block-commit-outside-worktree.sh"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/check-design-canvas.sh"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/check-code-simplifier.sh"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/check-pr-review.sh"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/check-unit-tests.sh"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/warn-skip-verification.sh"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/check-rebase-before-push.sh"
          timeout: 10
    - matcher: "Write"
      hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/check-test-plan.sh"
          timeout: 5
    - matcher: "Edit"
      hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/check-test-plan.sh"
          timeout: 5
  PostToolUse:
    - matcher: "Bash"
      hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/post-git-action-clear.sh commit code-simplifier"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/post-git-action-clear.sh commit design-canvas"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/post-git-action-clear.sh push pr-review"
          timeout: 5
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/post-git-push.sh"
          timeout: 30
  Stop:
    - hooks:
        - type: command
          command: "\"$CLAUDE_PROJECT_DIR\"/hooks/verify-completion.sh"
          timeout: 10
---

# TDD Development Workflow

A complete development workflow enforcing test-driven development, git worktree isolation, code review, CI verification, and E2E testing. Works in two modes: interactive (default) for human-guided sessions, and autonomous for fully unattended GitHub issue implementation.

> **NON-NEGOTIABLE RULES — every step marked MANDATORY is required.** Do not skip, defer, or ask the user whether to run these steps. Execute them automatically as part of the workflow. This covers creating PRs, waiting for CI, running E2E tests, and addressing reviewer findings.

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

This skill works across IDEs that support skills.sh. Map generic verbs in this doc to your IDE's tools (Claude Code's Bash → terminal in Cursor, etc.). Hook-based enforcement is available on Claude Code, Codex CLI, and Kiro CLI; on clients without installed hooks, follow each step manually — the discipline is the same.

For the full IDE table + verb-to-tool map, see [`references/cross-platform.md`](references/cross-platform.md).

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
Step 11: ITERATE UNTIL NO BLOCKING FINDINGS
Step 12: E2E TESTS & READY FOR MERGE   -- MANDATORY
Step 13: CLEANUP WORKTREE
```

---

## Step 1: Design Canvas

Create a design canvas for new UI work, user-facing features, architecture decisions, and complex data flows. Skip for trivial fixes or refactors that don't change behavior.

- IDEs with Pencil MCP: create `docs/designs/<feature>.pen`.
- IDEs without Pencil MCP: create `docs/designs/<feature>.md`.

For the full Pencil MCP call sequence, the markdown canvas template, and the per-mode (interactive vs autonomous) approval gate, see [`references/design-canvas.md`](references/design-canvas.md).

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

Run feasible checks locally **before the first push and after blocking fixes**.
Read the repository's test commands and CI configuration. Start with focused
regression tests, then run relevant lint, typecheck, build, and integration checks.
Run the broader suite when shared behavior changes or repository policy requires
it. CI confirms the candidate; it must not be the first attempt at a check that
can run locally. For documentation-only changes, use relevant documentation and
workflow checks rather than unrelated application builds.

Record commands, exit status, tested revision/tree, and coverage in the PR test
plan. If credentials, services, or tools prevent a local check, record the exact
limitation and leave that check pending for CI. Never report an unrun check as
passed. Reuse successful evidence only for unchanged inputs and environment;
after a fix, rerun affected checks and expand only if the impact requires it.

Example for a Node project (use the project's actual commands):

```bash
timeout 1800 bash -lc 'npm run build && npm run test' > /tmp/verify.log 2>&1; rc=$?; [ $rc -ne 0 ] && tail -100 /tmp/verify.log; exit $rc
```

Fix local failures before proceeding. Run local feature/E2E checks when feasible;
perform deployments only when the project requires and authorizes them.

### How to run long verification

Run your project's build/test suite as **one synchronous command with a generous timeout** — never background it and poll across turns:

1. **Run the top-level suite command synchronously with an explicit generous timeout.** One blocking call (or a few sequential blocking calls, e.g. build then test) that returns the full result within the turn. Capture output and replay only the tail on failure:
   ```bash
   timeout 1800 bash -lc '<your project's build & test command>' > /tmp/verify.log 2>&1; rc=$?; [ $rc -ne 0 ] && tail -100 /tmp/verify.log; exit $rc
   ```
2. **Never background the top-level suite** (no `&`, no background task mode — whatever the host CLI calls it, e.g. `run_in_background`) and then poll its log across agent turns. Each poll is a full model round-trip; collective polling cost can exceed the suite's own runtime by orders of magnitude.
3. If the tool's max timeout genuinely cannot cover the suite, split by directory/prefix into a few sequential synchronous calls — still no polling.
4. Prefer a project-provided parallel runner when one exists.

**Scope**: the ban is on backgrounding the TOP-LEVEL verification command. Tests/scripts that internally spawn child processes or local servers are unaffected, as are genuinely event-driven waits (CI checks in Step 9, bot reviews in Steps 10-11).

---

## Step 6: Code Simplification

1. Run an independent simplification pass using the strongest native option:
   - **Codex CLI**: ask Codex to spawn a native reviewer subagent focused on unnecessary complexity, duplication, and repository conventions. Keep the subagent advisory; the main session applies any changes.
   - **Claude Code**: use `code-simplifier:code-simplifier` when the plugin is installed.
   - **Other clients**: use an available review subagent or perform the same review manually.
2. Triage suggestions under the blocking policy below. Naming, style, and optional
   refactoring are advisory; apply them only when useful within the current scope.
   Do not start another review cycle solely to eliminate advisory notes.
3. The same independent reviewer may cover simplification and Step 8's correctness
   review in one pass. Record both results; a second full-diff pass on identical
   code is unnecessary. After edits, review the fixes and affected contracts.
4. Mark complete (if hooks are installed):
   ```bash
   hooks/state-manager.sh mark code-simplifier
   ```

---

## Step 7: Commit and Create PR (MANDATORY)

Complete Step 8's independent review before the first push. Batch related blocking
fixes, finish local verification, and push the verified candidate once. A review
performed on the final uncommitted tree remains valid for its unchanged commit.

### Commit

Execute in your terminal:

```bash
git add <files>
git commit -m "type(scope): description"
git push -u origin <branch-name>
```

### Create PR

> **GitHub lane (`CODE_HOST=github`)** — the example below uses the GitHub CLI. On the GitLab lane, the wrapper opens the merge request via the `chp_create_pr` provider seam; agents don't hand-roll the platform API call. Substitute `glab mr create --title … --description …` if you must invoke the CLI directly.

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
- [ ] Blocking bot findings resolved; advisory findings recorded
- [ ] E2E tests pass

## Checklist
- [ ] New unit tests written for new functionality
- [ ] E2E test cases updated if needed
- [ ] Documentation updated if needed
EOF
)"
```

### Update PR Checklist

After completing each step, update the PR/MR description. Fetch the current body, mark items as `[x]`, and write it back.

```bash
# GitHub lane (CODE_HOST=github):
gh pr view {pr_number} --json body --jq '.body' > /tmp/pr_body.md
# Edit the checklist (mark items as [x])
gh pr edit {pr_number} --body "$(cat /tmp/pr_body.md)"

# GitLab lane (CODE_HOST=gitlab):
glab mr view {mr_number} -F json | jq -r .description > /tmp/pr_body.md
# Edit the checklist (mark items as [x])
glab mr update {mr_number} --description "$(cat /tmp/pr_body.md)"
```

---

## Step 8: PR Review Agent (MANDATORY)

Perform this review before Step 7's first push. If Step 6 already included an
independent correctness review of the same tree, reuse that result. Later passes
verify fixes and affected behavior; repeat the full diff only when changes or new
evidence warrant it.

1. Run an independent dev-side review:
   - **Codex CLI**: use a native reviewer subagent, or run `codex review --uncommitted` before the first commit and `codex review --base <base-branch>` for the committed branch diff.
   - **Claude Code**: use `/pr-review-toolkit:review-pr` when the plugin is installed.
   - **Other clients**: use an available review agent or review the complete diff manually.
2. Apply the project's `REVIEW_BLOCKING_SEVERITY` from `autonomous.conf` or the
   wrapper's delivery policy. Default `P1` requires fixing P0/P1 from round one.
   `P2` and `P3` select fixed stricter floors; `adaptive` preserves the legacy
   P3/P2/P1 floor at rounds 1-2/3-4/5+. Invalid values use strict P3 with a warning.
   Classify untagged correctness findings before deferring them. P0/P1, mandatory
   acceptance criteria, security controls, failed required checks, and merge gates
   always block. Severity reflects demonstrated impact, not cleanup preferences.
   Record lower-severity findings as advisory notes without requiring a code edit.
3. Mark complete (if hooks are installed):
   ```bash
   hooks/state-manager.sh mark pr-review
   ```

---

## Step 9: Wait for All CI Checks (MANDATORY -- DO NOT SKIP)

Execute in your terminal. On the GitHub lane use the GitHub CLI; on the GitLab lane use `glab` (or the pipeline's `chp_ci_status` seam, which normalizes both hosts to `green`/`pending`/`failed`/`none`).

```bash
# GitHub lane (CODE_HOST=github):
gh pr checks {pr_number} --watch --interval 30

# GitLab lane (CODE_HOST=gitlab):
glab ci status {mr_number}   # add `--live` on newer glab for continuous updates
```

ALL checks must pass: Lint, Unit Tests, Build, Deploy Preview, E2E Tests.

While CI runs, inspect existing review feedback and update verification evidence
when these activities are independent. Use the provider's watch command rather
than repeatedly issuing status reads. Avoid empty commits or pushes just to
retrigger reviews; retrigger only a failed job when supported and appropriate.

If ANY check fails: analyze logs, fix, push, re-watch. DO NOT proceed until every check shows "pass."

### Checks to Monitor

| Check | Description | Action if Failed |
|-------|-------------|------------------|
| CI / build-and-test | Build + unit tests | Fix code or update snapshots |
| Security Scan | SAST, npm audit | Fix security issues |
| Configured `REVIEW_BOTS` | Per-project bot reviewers (`q`, `codex`, `claude`, custom) | Address findings, retrigger via `gh-as-user.sh` |
| Other review bots | Various checks | Address findings, retrigger per bot docs |

---

## Step 10: Address Reviewer Bot Findings (MANDATORY when `REVIEW_BOTS` is non-empty)

If the project's `autonomous.conf` declares `REVIEW_BOTS` (space-separated short names like `q codex claude`), triage each configured bot's findings using Step 8's blocking policy. Fix blocking issues; reply once to false positives or advisory findings with the reason and severity. Resolve a deferred advisory thread only after recording its disposition and when repository policy permits. Do not describe deferred findings as fixed. Retrigger only after relevant code changes or a missing required review.

If `REVIEW_BOTS=""` (or the variable is unset), this step is **skipped entirely** — the project doesn't enforce any external bot review.

Built-in bot triggers:

| Short name | Trigger phrase | Bot login (filter `user.login`) |
|---|---|---|
| `q` | `/q review` | `amazon-q-developer[bot]` |
| `codex` | `/codex review` | `codex[bot]` |
| `claude` | `@claude review` | `claude[bot]` |

> **Use `scripts/gh-as-user.sh` to retrigger bot reviews.** All three built-in bots reject trigger comments posted by GitHub App bot accounts; the wrapper posts as a real user.

For the full retrigger commands, reply patterns, and thread resolution semantics, see [`references/review-threads.md`](references/review-threads.md).

---

## Step 11: Iterate Until No Blocking Findings

**Repeat only while blocking findings remain:**

1. Confirm findings are still present; group duplicates and batch related fixes.
2. Run affected local tests and review the changed behavior before pushing.
3. Reply to each actionable thread and resolve after its disposition is recorded.
4. Retrigger affected configured reviewers once for the new candidate, when needed.
5. Wait for review completion using available status signals and bounded polling.
6. Triage new findings by the same threshold. Keep advisory notes visible, but do
   not edit code or restart review solely because new non-blocking notes appear.
7. Proceed when no blocking findings remain and required checks are satisfied.

---

## Step 12: E2E Tests & Ready for Merge (MANDATORY -- DO NOT SKIP)

1. Run required E2E tests against the deployed preview environment. In autonomous
   mode, when the review wrapper owns configured E2E, hand off after local feature
   verification and required CI; the wrapper runs final E2E once and fan-out
   reviewers consume its evidence. Reuse existing E2E evidence only when the HEAD,
   target environment, and required scenario coverage match. Keep unrun final E2E
   pending rather than marking it complete.
2. Only after E2E has actually passed on the current candidate, mark complete
   (if hooks are installed). Leave this state unset while wrapper-owned E2E is pending:
   ```bash
   hooks/state-manager.sh mark e2e-tests
   ```
3. Update PR checklist to reflect completed checks and any pending wrapper-owned E2E
4. **STOP HERE**: report status to the user (interactive mode) or post a summary comment on the issue (autonomous mode). In autonomous mode, post via the project-vendored wrapper so the comment is attributed to the configured identity (bot in app mode, host user in token mode):
   ```bash
   # GitHub lane (CODE_HOST=github):
   bash scripts/gh issue comment <ISSUE_NUMBER> --body "<summary>"
   ```
   Do **not** call bare `gh issue comment` — the agent's Bash tool does not reliably resolve `gh` through the wrapper-injected PATH, so a bare call falls through to the system `gh` and posts under the host operator's identity. See [`references/autonomous-mode.md`](references/autonomous-mode.md#posting-issuepr-comments) for the full rule.

   > **GitLab lane (`CODE_HOST=gitlab`)** — the same principle applies: the wrapper/`itp_post_comment` provider seam posts the comment under the configured identity. Agents don't hand-roll `glab issue note` or the REST API; the seam handles auth and identity.
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

## References

For detailed commands and conventions, consult:
- **`references/commit-conventions.md`** -- Branch naming and commit message conventions
- **`references/review-commands.md`** -- Complete `gh` CLI and GraphQL command reference
- **`references/review-threads.md`** -- Review thread management, response patterns, and quick reference commands
- **`references/autonomous-mode.md`** -- Decision making, resume awareness, requirement tracking, pre-existing changes, bot review integration, and error recovery (autonomous mode only)
