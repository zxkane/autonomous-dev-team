# Project Name - Claude Code Development Workflow

## Project Overview

[Describe your project's core functionality and goals here]

---

## Tech Stack

[Fill in based on your actual project]

| Component | Choice | Rationale |
|-----------|--------|----------|
| Frontend | - | - |
| Backend | - | - |
| Database | - | - |
| Testing | - | - |

---

## Development Workflow (TDD + Agent-Assisted)

This project enforces a strict end-to-end development workflow through Claude Code hooks:

### Mandatory Rules (Hook Enforced)

1. **All code changes must be developed in a Git Worktree** — commits outside `.worktrees/` are automatically blocked by `block-commit-outside-worktree.sh`
2. **All changes must go through Pull Requests** — direct pushes to `main` are automatically blocked by `block-push-to-main.sh`
3. **Code review before commit** — code-simplifier must run before committing
4. **PR review before push** — pr-review agent must run before pushing

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Feature/Bug Fix Development Flow                  │
├─────────────────────────────────────────────────────────────────────┤
│  ⛔ Prerequisites: Must be in Git Worktree + on feature branch       │
│                                                                     │
│  Step 1          Step 2          Step 3          Step 4            │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐      │
│  │ Design   │───▶│ Create   │───▶│ Test     │───▶│ Implement│      │
│  │ Canvas   │    │ Worktree │    │ Cases    │    │ Code     │      │
│  │ (Pencil) │    │ (MUST)   │    │ (TDD)    │    │          │      │
│  └──────────┘    └──────────┘    └──────────┘    └──────────┘      │
│       │                                               │             │
│       │                                               ▼             │
│       │         ┌──────────────────────────────────────────────┐   │
│       │         │              Pre-Commit Checks                │   │
│       │         │  1. code-simplifier agent reviews code        │   │
│       │         │  2. Local lint/type check passes              │   │
│       │         └──────────────────────────────────────────────┘   │
│       │                                               │             │
│       │         Step 6          Step 7               │             │
│       │         ┌──────────┐    ┌──────────┐         │             │
│       │    ┌───▶│ PR Review│───▶│ Git Push │◀────────┘             │
│       │    │    │ Agent    │    │          │                       │
│       │    │    └──────────┘    └──────────┘                       │
│       │    │                          │                            │
│       │    │    Step 8               ▼                             │
│       │    │    ┌──────────────────────────────┐                   │
│       │    │    │ Wait for GitHub CI Checks    │                   │
│       │    │    │ - Lint & Type Check          │                   │
│       │    │    │ - Unit Tests                 │                   │
│       │    │    │ - Build                      │                   │
│       │    │    └──────────────────────────────┘                   │
│       │    │                          │                            │
│       │    │                          ▼                             │
│       │    │    Step 9                                             │
│       │    │    ┌──────────────────────────────┐                   │
│       │    │    │ E2E Tests (Chrome DevTools)  │                   │
│       │    │    │ Verify on Preview Environment│                   │
│       │    │    └──────────────────────────────┘                   │
│       │    │                          │                            │
│       │    │    ❌ Failed             ▼ ✅ Passed                  │
│       │    └───────────────────  ┌──────────────┐                  │
│       │                          │ Notify User  │                  │
│       │                          │ Peer Review  │                  │
│       │                          └──────────────┘                  │
│       │                                │                           │
│       │                                ▼                           │
│       │                          ┌──────────────┐                  │
│       │                          │ Step 10:     │                  │
│       │                          │ Cleanup      │                  │
│       │                          │ Worktree     │                  │
│       │                          └──────────────┘                  │
│       └────────────────────────────────────────────────────────▶   │
│                         Return to Step 1 (if changes needed)        │
└─────────────────────────────────────────────────────────────────────┘
```

### Step 1: Design Canvas (Pencil Tool)

**Tool**: Pencil MCP (`.pen` files)

**⚠️ CRITICAL: Always start feature development with a design canvas using Pencil**

- Input: User requirements / PRD / Bug description
- Output: Design canvas document (`docs/designs/<feature>.pen`)

#### Pencil Tool Workflow

1. **Check editor state**:
   ```
   Use get_editor_state() to see current .pen file status
   ```

2. **Open or create design file**:
   ```
   Use open_document("docs/designs/<feature>.pen") or open_document("new")
   ```

3. **Get design guidelines** (optional):
   ```
   Use get_guidelines(topic="landing-page|table|tailwind|code")
   ```

4. **Get style guide** for consistent design:
   ```
   Use get_style_guide_tags() to discover available tags
   Use get_style_guide(tags=["modern", "dashboard"]) for inspiration
   ```

5. **Create design elements**:
   ```
   Use batch_design(operations) to create:
   - UI mockups and wireframes
   - Component hierarchy diagrams
   - Data flow visualizations
   - Architecture diagrams
   ```

6. **Validate design visually**:
   ```
   Use get_screenshot() to verify the design looks correct
   ```

#### Design Canvas Content

- Feature architecture diagram
- Data flow diagram
- UI mockups (if applicable)
- API design (if applicable)
- Component specifications
- Design decisions and rationale

#### Design Approval

Before proceeding to implementation:
1. Present the design canvas to the user
2. Get explicit approval
3. Document any feedback or changes
4. Mark design status as `Approved`

### Step 2: Create Git Worktree (MANDATORY — Hook Enforced)

**⛔ Every change MUST be developed in an isolated git worktree. Never develop directly on the main workspace.**

> This is enforced by `block-commit-outside-worktree.sh` hook. Commits outside worktrees will be **automatically blocked**.
> Direct pushes to main are also blocked by `block-push-to-main.sh` hook.

- Input: Approved design / Task description
- Output: Isolated worktree with clean baseline

#### Why Worktrees?

- **Isolation**: Each feature/fix gets its own directory, preventing accidental cross-contamination
- **Parallel work**: Multiple features can be in progress simultaneously
- **Clean main workspace**: The main checkout stays on `main`, always ready for quick checks or hotfixes
- **Safe rollback**: Discard a worktree without affecting the main workspace

#### Worktree Creation Process

```bash
# 1. Determine branch name based on change type
BRANCH_NAME="feat/my-feature"  # or fix/<name>, refactor/<name>, etc.

# 2. Create worktree with new branch from main
git worktree add .worktrees/$BRANCH_NAME -b $BRANCH_NAME

# 3. Enter the worktree
cd .worktrees/$BRANCH_NAME

# 4. Install dependencies
npm install  # or: bun install, yarn install, pnpm install

# 5. Verify clean baseline
npm run build && npm test
```

#### Directory Convention

| Item | Value |
|------|-------|
| Worktree root | `.worktrees/` (project-local, gitignored) |
| Path pattern | `.worktrees/<branch-name>` |
| Example | `.worktrees/feat/user-authentication` |

#### Safety Checks

Before creating any worktree, verify `.worktrees/` is in `.gitignore`:

```bash
git check-ignore -q .worktrees 2>/dev/null || echo "WARNING: .worktrees not in .gitignore!"
```

#### All Subsequent Steps Run INSIDE the Worktree

After creating the worktree, **all development commands** (test, lint, build, commit, push) are executed from within the worktree directory. The main workspace is not touched until cleanup.

### Step 3: Test Case Design (Test First - Mandatory)

**⚠️ This is a mandatory step that must be completed before writing any implementation code**

- Input: Design canvas + PRD requirements
- Output: Test case document + test skeleton code
- Tasks:
  1. Deeply understand design and requirements, identify all user scenarios and edge cases
  2. Write test case document: `docs/test-cases/<feature>.md`
     - List all test scenarios (happy path, edge cases, error handling)
     - Assign test IDs (e.g., `TC-AUTH-001`)
     - Define expected results and acceptance criteria
  3. Create E2E test skeleton (if applicable)
  4. Create unit test skeleton

**Test Case Document Template**: See `docs/templates/test-case-template.md`

### Step 4: Implementation

- Input: Design canvas + Test cases
- Output: Implementation code
- Tasks:
  1. Implement features following test cases (inside worktree)
  2. Ensure implementation covers all test scenarios
  3. Manually verify basic functionality locally

### Step 5: Unit Test Implementation & Verification

- Input: Implementation code + Test skeleton
- Output: Complete unit tests, all passing
- Tasks:
  1. Implement all unit tests
     - Coverage requirement: >80%
  2. Run unit tests
  3. Fix failing tests
  4. Ensure all tests pass

### Step 6: Code Review (Pre-Commit)

**⚠️ Hook enforced - must complete before commit**

- Input: Feature code + Test code
- Output: code-simplifier review passed
- Tasks:
  1. Run code-simplifier agent:
     ```
     Use Task tool with subagent_type: code-simplifier:code-simplifier
     ```
  2. Address simplification suggestions
  3. Mark as complete:
     ```bash
     hooks/state-manager.sh mark code-simplifier
     ```

### Step 7: PR Review (Pre-Push)

**⚠️ Hook enforced - must complete before push**

- Input: Committed code
- Output: PR review passed
- Tasks:
  1. Run PR review agent:
     ```
     /pr-review-toolkit:review-pr
     ```
  2. Address findings:
     - 🔴 Critical/Severe: Must fix
     - 🟠 High: Must fix
     - 🟡 Medium: Should fix
     - 🟢 Low: Optional
  3. Mark as complete after resolving issues:
     ```bash
     hooks/state-manager.sh mark pr-review
     ```

### Step 8: Wait for CI Checks

**⚠️ Hook enforced - must verify before task completion**

- Input: GitHub PR
- Output: All CI/CD checks pass
- Required Checks:
  - ✅ Lint & Type Check
  - ✅ Unit Tests
  - ✅ Build
- If any check fails → Return to Step 4 to fix

### Step 9: E2E Test Verification

**⚠️ Hook enforced - must execute before task completion**

- Input: CI Checks all passed
- Output: E2E tests passed
- Tasks:
  1. Use Chrome DevTools MCP to test Preview environment
  2. Verify all functionality works correctly
  3. Check for console errors
  4. Mark as complete:
     ```bash
     hooks/state-manager.sh mark e2e-tests
     ```

### Step 10: Cleanup Worktree

After the PR is merged or closed:

```bash
# Return to main workspace
cd $(git rev-parse --show-toplevel)

# Remove the worktree
git worktree remove .worktrees/<branch-name>

# Prune stale worktree references
git worktree prune
```

---

## Acceptance Checklist

Before merging any PR, confirm:

- [ ] Design canvas created/updated (`docs/designs/<feature>.pen`)
- [ ] Git worktree created for development
- [ ] Test case document created (`docs/test-cases/<feature>.md`)
- [ ] Feature code complete and locally verified
- [ ] Unit test coverage >80%
- [ ] All unit tests pass
- [ ] code-simplifier agent review passed
- [ ] pr-review agent review passed
- [ ] **All GitHub PR Checks pass**
- [ ] E2E tests pass (Chrome DevTools)
- [ ] User Peer Review complete
- [ ] Worktree cleaned up after merge

---

## Common Commands

```bash
# Worktree Management
git worktree add .worktrees/<branch> -b <branch>   # Create worktree
git worktree list                                   # List worktrees
git worktree remove .worktrees/<branch>             # Remove worktree
git worktree prune                                  # Prune stale refs

# Development
npm run dev                    # Start local development server
npm run build                  # Build project

# Testing
npm test                       # Run all tests
npm run test:coverage          # Run tests with coverage report
npm run test:e2e               # Run E2E tests

# Code Quality
npm run lint                   # Run linter
npm run lint:fix               # Run linter with auto-fix
npm run typecheck              # TypeScript type check

# Hook State Management
hooks/state-manager.sh list        # View current states
hooks/state-manager.sh mark <action>   # Mark action as complete
hooks/state-manager.sh clear <action>  # Clear state
```

---

## Project Structure

```
project-root/
├── CLAUDE.md                     # Project config and workflow (this file)
├── AGENTS.md                    # Cross-platform skill discovery
├── .claude/
│   ├── settings.json            # Claude Code hooks configuration
│   └── skills -> ../skills      # Symlink for Claude Code discovery
├── .kiro/
│   ├── agents/
│   │   └── default.json         # Kiro CLI agent config (hooks + skill resources)
│   └── skills -> ../skills      # Symlink for Kiro CLI discovery
├── hooks/                       # Workflow enforcement hooks
│   ├── README.md                # Per-IDE setup instructions
│   ├── lib.sh                   # Shared utility functions
│   ├── state-manager.sh         # State manager
│   ├── block-push-to-main.sh
│   ├── block-commit-outside-worktree.sh
│   ├── check-design-canvas.sh
│   ├── check-test-plan.sh
│   ├── check-code-simplifier.sh
│   ├── check-pr-review.sh
│   ├── check-unit-tests.sh
│   ├── post-git-action-clear.sh
│   ├── post-git-push.sh
│   ├── post-file-edit-reminder.sh
│   ├── verify-completion.sh
│   └── warn-skip-verification.sh
├── skills/                      # Cross-platform skills (skills.sh compatible)
│   ├── autonomous-dev/          # TDD development workflow
│   │   ├── SKILL.md
│   │   └── references/
│   │       ├── commit-conventions.md
│   │       └── review-commands.md
│   ├── autonomous-review/       # PR review workflow
│   │   └── SKILL.md
│   └── autonomous-dispatcher/   # Issue dispatcher
│       └── SKILL.md
├── scripts/                     # Pipeline and utility scripts
│   ├── autonomous-dev.sh
│   ├── autonomous-review.sh
│   ├── autonomous.conf.example
│   ├── dispatch-local.sh
│   ├── lib-agent.sh
│   ├── lib-auth.sh
│   ├── gh-app-token.sh
│   ├── gh-token-refresh-daemon.sh
│   ├── gh-with-token-refresh.sh
│   ├── gh-as-user.sh
│   ├── mark-issue-checkbox.sh
│   ├── upload-screenshot.sh
│   ├── reply-to-comments.sh
│   ├── resolve-threads.sh
│   └── setup-labels.sh
├── .worktrees/                  # Git worktrees (gitignored)
├── docs/
│   ├── designs/                 # Design canvas documents (.pen files)
│   ├── test-cases/              # Test case documents
│   ├── autonomous-pipeline.md
│   └── templates/
├── src/                         # Source code
├── tests/                       # Test code
│   ├── unit/
│   └── e2e/
└── .github/
    └── workflows/               # GitHub Actions CI config
```

---

## Implementation Log

### YYYY-MM-DD: Project Initialization
- Create project structure
- Configure Claude Code hooks
- Configure CI/CD pipeline

---

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| - | - | - |

---

## Security Best Practices

[Fill in security considerations based on your project]

---

## Skills Reference

### Autonomous Dev Skill

The `autonomous-dev` skill provides standardized guidance for the complete development workflow.

**Trigger phrases**: "design a feature", "create UI mockup", "create a PR", "create worktree", "address review comments", "resolve review threads", "/q review", "/codex review", "merge PR", "push changes", "check CI status"

**Location**: `skills/autonomous-dev/SKILL.md`

**Key features**:
- Design Canvas workflow using Pencil tool
- **Git worktree creation for isolated development (hook enforced)**
- **PR-only workflow — no direct pushes to main (hook enforced)**
- Branch naming and commit conventions
- PR creation and review process
- Reviewer bot interaction (Amazon Q, Codex)
- CI/CD check monitoring
- Review thread management
- Worktree cleanup after merge

**Utility scripts**:
```bash
# Reply to a specific review comment
scripts/reply-to-comments.sh <owner> <repo> <pr> <comment_id> "<message>"

# Resolve all unresolved review threads
scripts/resolve-threads.sh <owner> <repo> <pr>
```

**Reference documentation**:
- `references/commit-conventions.md` - Branch naming and commit message standards
- `references/review-commands.md` - GitHub CLI and GraphQL commands

---

## Autonomous Dev Team

A fully automated pipeline: GitHub issue → Dev Agent → Review Agent → merged PR. Runs unattended via a dispatcher on a 5-minute cron cycle. Supports multiple coding agent CLIs (Claude Code, Codex, Kiro) with a pluggable abstraction layer.

For the complete pipeline design, label state machine, and concurrency model, see `docs/autonomous-pipeline.md`.

### Dev Agent

Receives a GitHub issue, creates an isolated worktree, implements the feature with tests, and creates a pull request.

- **Worktree isolation**: Each issue gets its own git worktree
- **TDD workflow**: Follows the project's `autonomous-dev` skill
- **Issue checkbox tracking**: Marks `## Requirements` checkboxes as implemented
- **Resume support**: Can resume after review feedback (`--mode resume`)
- **Exit-aware cleanup**: Success → `pending-review`; failure → `pending-dev` for retry
- **Wrapper**: `scripts/autonomous-dev.sh`
- **Skill**: `skills/autonomous-dev/SKILL.md`

### Review Agent

Finds the linked PR, performs code review, optionally runs E2E verification, and either approves+merges or sends back with feedback.

- **PR discovery**: Finds linked PR via body reference, issue comments, or search
- **Merge conflict resolution**: Automatically rebases conflicting PRs
- **Code review checklist**: Verifies design docs, tests, CI, PR conventions
- **Amazon Q integration**: Triggers and monitors Amazon Q Developer review
- **E2E verification**: Optional Chrome DevTools MCP testing with screenshot evidence (enabled by `E2E_ENABLED=true`)
- **Acceptance criteria tracking**: Marks `## Acceptance Criteria` checkboxes as verified
- **Crash recovery**: Trap handler moves issue back to `pending-dev` on agent crash
- **Auto-merge**: Squash-merges and closes the issue on pass
- **Wrapper**: `scripts/autonomous-review.sh`
- **Skill**: `skills/autonomous-review/SKILL.md`

### Dispatcher

Scans GitHub for actionable issues and spawns the appropriate agent process.

- **Issue scanning**: `autonomous`, `pending-dev`, `pending-review` labels
- **Dependency checking**: Skips issues with open dependencies in `## Dependencies` section
- **Retry limiting**: Marks issues as `stalled` after `MAX_RETRIES` (default 3) failed attempts
- **Concurrency control**: `MAX_CONCURRENT` limit via PID file checks
- **Stale detection**: Recovers from zombie agent processes (disambiguates dev vs review PID files)
- **Local dispatch**: `nohup` spawn with post-spawn health check
- **Skill**: `skills/autonomous-dispatcher/SKILL.md`

### Configuration

```bash
cp scripts/autonomous.conf.example scripts/autonomous.conf
```

Key settings: `REPO`, `PROJECT_DIR`, `AGENT_CMD` (claude/codex/kiro), `GH_AUTH_MODE` (token/app), `MAX_CONCURRENT`, `MAX_RETRIES`, E2E options. See comments in the example file.

### Key Scripts

| Script | Purpose |
|--------|---------|
| `scripts/lib-agent.sh` | Agent CLI abstraction (`run_agent`, `resume_agent`) |
| `scripts/lib-auth.sh` | GitHub auth abstraction (PAT or GitHub App mode) |
| `scripts/gh-app-token.sh` | GitHub App JWT generation + installation token exchange |
| `scripts/gh-token-refresh-daemon.sh` | Background daemon — refreshes tokens every 45 min |
| `scripts/gh-with-token-refresh.sh` | `gh` CLI wrapper that reads latest token before each call |
| `scripts/mark-issue-checkbox.sh` | Mark issue body checkboxes as complete |
| `scripts/upload-screenshot.sh` | Upload E2E screenshots to GitHub |
| `scripts/setup-labels.sh` | Create all GitHub labels required by the autonomous pipeline |

### GitHub App Setup

For multi-agent authentication with separate bot identities, see `docs/github-app-setup.md`.
