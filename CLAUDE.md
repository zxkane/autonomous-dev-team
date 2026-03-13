# Project Name - Development Workflow

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

This project enforces a strict TDD development workflow through agent hooks. The workflow applies to all supported coding agents (Claude Code, Kiro CLI, Cursor, Windsurf, Gemini CLI, etc.).

### Mandatory Rules (Hook Enforced)

1. **All code changes must be developed in a Git Worktree** — commits outside `.worktrees/` are automatically blocked
2. **All changes must go through Pull Requests** — direct pushes to `main` are automatically blocked
3. **Rebase before push** — pushes are blocked if the branch is behind `origin/main`
4. **Code review before commit** — code-simplifier must run before committing (Claude Code only)
5. **PR review before push** — pr-review agent must run before pushing (Claude Code only)

> Hooks are supported in Claude Code and Kiro CLI. For agents without hook support (Cursor, Windsurf, Gemini CLI), follow each step manually — the discipline is the same.

### Workflow Summary

```
Design → Worktree → Tests → Implement → Verify → Review → PR → CI → E2E → Merge
```

The complete step-by-step workflow is defined in the **autonomous-dev** skill. Use it:

```bash
# Install skills into your agent
npx skills add zxkane/autonomous-dev-team
```

Or read directly: `skills/autonomous-dev/SKILL.md`

### Workflow Steps (Quick Reference)

| Step | Action | Enforced By |
|------|--------|-------------|
| 1 | Design Canvas (Pencil MCP or markdown) | `check-design-canvas.sh` |
| 2 | Create Git Worktree | `block-commit-outside-worktree.sh` |
| 3 | Write Test Cases (TDD) | `check-test-plan.sh` |
| 4 | Implement Changes | — |
| 5 | Local Verification (build + test) | `check-unit-tests.sh` |
| 6 | Code Simplification Review | `check-code-simplifier.sh` |
| 7 | Commit and Create PR | — |
| 8 | PR Review Agent | `check-pr-review.sh` |
| 9 | Rebase and Push | `check-rebase-before-push.sh` |
| 10 | Wait for CI Checks | `verify-completion.sh` |
| 11 | Address Reviewer Bot Findings | — |
| 12 | E2E Tests | `verify-completion.sh` |
| 13 | Cleanup Worktree | — |

---

## Acceptance Checklist

Before merging any PR, confirm:

- [ ] Design canvas created/updated (`docs/designs/<feature>.pen` or `.md`)
- [ ] Git worktree created for development
- [ ] Test case document created (`docs/test-cases/<feature>.md`)
- [ ] Feature code complete and locally verified
- [ ] Unit test coverage >80%
- [ ] All unit tests pass
- [ ] code-simplifier agent review passed
- [ ] pr-review agent review passed
- [ ] **All GitHub PR Checks pass**
- [ ] E2E tests pass
- [ ] Peer review complete
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
│   │   └── default.json         # Kiro CLI agent config (hooks + tools)
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
│   ├── check-rebase-before-push.sh
│   ├── warn-skip-verification.sh
│   ├── post-git-action-clear.sh
│   ├── post-git-push.sh
│   ├── post-file-edit-reminder.sh
│   └── verify-completion.sh
├── skills/                      # Cross-platform skills (skills.sh compatible)
│   ├── autonomous-dev/          # TDD development workflow
│   │   ├── SKILL.md
│   │   └── references/
│   │       ├── commit-conventions.md
│   │       ├── review-commands.md
│   │       ├── review-threads.md
│   │       └── autonomous-mode.md
│   ├── autonomous-review/       # PR review workflow
│   │   ├── SKILL.md
│   │   └── references/
│   │       ├── merge-conflict-resolution.md
│   │       ├── e2e-verification.md
│   │       └── decision-gate.md
│   ├── autonomous-dispatcher/   # Issue dispatcher
│   │   └── SKILL.md
│   └── create-issue/            # GitHub issue creation
│       ├── SKILL.md
│       └── references/
│           ├── issue-templates.md
│           └── workspace-changes.md
├── scripts/                     # Pipeline and utility scripts
│   ├── autonomous-dev.sh
│   ├── autonomous-review.sh
│   ├── autonomous.conf.example
│   ├── dispatch-local.sh
│   ├── setup-labels.sh
│   ├── lib-agent.sh
│   ├── lib-auth.sh
│   ├── gh-app-token.sh
│   ├── gh-token-refresh-daemon.sh
│   ├── gh-with-token-refresh.sh
│   ├── gh-as-user.sh
│   ├── mark-issue-checkbox.sh
│   ├── upload-screenshot.sh
│   ├── reply-to-comments.sh
│   └── resolve-threads.sh
├── .worktrees/                  # Git worktrees (gitignored)
├── docs/
│   ├── designs/                 # Design canvas documents
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

## Skills Reference

This project provides four portable skills, installable into 40+ coding agents:

```bash
npx skills add zxkane/autonomous-dev-team
```

| Skill | Location | Description |
|-------|----------|-------------|
| **autonomous-dev** | `skills/autonomous-dev/SKILL.md` | TDD workflow with worktree isolation, design canvas, test-first development, code review, and CI verification |
| **autonomous-review** | `skills/autonomous-review/SKILL.md` | PR code review with checklist, merge conflict resolution, E2E testing, and auto-merge |
| **autonomous-dispatcher** | `skills/autonomous-dispatcher/SKILL.md` | GitHub issue scanner that dispatches dev/review agents on a cron schedule |
| **create-issue** | `skills/create-issue/SKILL.md` | Structured GitHub issue creation with templates and autonomous label guidance |

---

## Autonomous Pipeline

A fully automated pipeline: GitHub issue → Dev Agent → Review Agent → merged PR. Runs unattended via a dispatcher on a cron cycle. Supports multiple coding agent CLIs (Claude Code, Codex, Kiro) with a pluggable abstraction layer.

For the complete pipeline design, label state machine, and concurrency model, see `docs/autonomous-pipeline.md`.

### Configuration

```bash
cp scripts/autonomous.conf.example scripts/autonomous.conf
```

Key settings: `REPO`, `PROJECT_DIR`, `AGENT_CMD` (claude/codex/kiro), `GH_AUTH_MODE` (token/app), `MAX_CONCURRENT`, `MAX_RETRIES`, E2E options. See comments in the example file.

### Key Scripts

| Script | Purpose |
|--------|---------|
| `scripts/autonomous-dev.sh` | Dev agent wrapper |
| `scripts/autonomous-review.sh` | Review agent wrapper |
| `scripts/dispatch-local.sh` | Local dispatch script |
| `scripts/lib-agent.sh` | Agent CLI abstraction (`run_agent`, `resume_agent`) |
| `scripts/lib-auth.sh` | GitHub auth abstraction (PAT or GitHub App mode) |
| `scripts/setup-labels.sh` | Create GitHub labels required by the pipeline |
| `scripts/mark-issue-checkbox.sh` | Mark issue body checkboxes as complete |
| `scripts/reply-to-comments.sh` | Reply to PR review comments |
| `scripts/resolve-threads.sh` | Batch resolve review threads |

### GitHub App Setup

For multi-agent authentication with separate bot identities, see `docs/github-app-setup.md`.

---

## Implementation Log

### YYYY-MM-DD: Project Initialization
- Create project structure
- Configure agent hooks
- Configure CI/CD pipeline

---

## Risks & Mitigation

| Risk | Impact | Mitigation |
|------|--------|------------|
| - | - | - |

---

## Security Best Practices

[Fill in security considerations based on your project]
