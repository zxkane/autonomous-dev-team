# Claude Code Development Workflow Template

A development workflow template for Claude Code that enforces end-to-end development processes through a hook system, ensuring AI agents follow TDD (Test-Driven Development) and code review best practices for feature development and bug fixes.

## Features

- **Worktree Enforcement**: Blocks commits outside git worktrees (hook enforced)
- **PR-Only Workflow**: Blocks direct pushes to main branch (hook enforced)
- **Design First**: Enforces design canvas creation before implementation
- **Test-Driven Development (TDD)**: Enforces test case creation before writing code
- **Code Simplification**: Blocks commits until code-simplifier agent review is complete
- **Code Review**: Blocks pushes until pr-review agent review is complete
- **CI Verification**: Blocks task completion until CI passes
- **E2E Testing**: Enforces E2E test execution on Preview environment

## Project Structure

```
.
├── CLAUDE.md                     # Project config and workflow documentation
├── .claude/
│   ├── settings.json            # Claude Code hooks configuration
│   ├── hooks/                   # Hook scripts
│   │   ├── lib.sh               # Shared utility functions
│   │   ├── state-manager.sh     # Workflow state management
│   │   ├── block-push-to-main.sh        # Blocks direct push to main
│   │   ├── block-commit-outside-worktree.sh  # Blocks commits outside worktrees
│   │   ├── check-design-canvas.sh   # Design canvas check
│   │   ├── check-test-plan.sh       # Test plan check
│   │   ├── check-code-simplifier.sh # Code simplification check
│   │   ├── check-pr-review.sh       # PR review check
│   │   ├── check-unit-tests.sh      # Unit tests check
│   │   ├── warn-skip-verification.sh # --no-verify warning
│   │   ├── post-file-edit-reminder.sh # Post-edit reminder
│   │   ├── post-git-action-clear.sh # Git action state cleanup
│   │   ├── post-git-push.sh         # Post-push verification reminder
│   │   └── verify-completion.sh     # Task completion verification
│   └── skills/                  # Claude Code skills
│       └── github-workflow/     # GitHub development workflow skill
│           ├── SKILL.md         # Main skill definition (13-step workflow)
│           ├── references/      # Reference documentation
│           │   ├── commit-conventions.md  # Branch naming & commit standards
│           │   └── review-commands.md     # GitHub CLI & GraphQL commands
│           └── scripts/         # Utility scripts
│               ├── reply-to-comments.sh   # Reply to PR review comments
│               └── resolve-threads.sh     # Batch resolve review threads
├── docs/
│   ├── designs/                 # Design canvas documents
│   ├── test-cases/              # Test case documents
│   └── templates/               # Document templates
│       ├── design-canvas-template.md
│       └── test-case-template.md
└── .github/                     # (CI workflow needs manual setup)
```

## Usage

### 1. Create a New Project from Template

```bash
# Using GitHub CLI
gh repo create my-project --template zxkane/claude-code-workflow

# Or manually clone
git clone https://github.com/zxkane/claude-code-workflow.git my-project
cd my-project
rm -rf .git
git init
```

### 2. Customize Configuration

1. **Update CLAUDE.md**: Modify project overview, tech stack, etc.
2. **Adjust hook scripts**: Modify file matching patterns based on project needs
3. **Configure CI**: Adjust GitHub Actions workflow based on project requirements

### 3. Start Development

When using Claude Code for development, hooks will automatically enforce the workflow.

## Using Skills to Follow the Workflow

The `github-workflow` skill provides Claude Code with comprehensive guidance to follow the development workflow. Skills are automatically triggered by natural language prompts or can be invoked via slash commands.

### Trigger Phrases (Natural Language)

Claude Code will automatically activate the `github-workflow` skill when you use these phrases:

| Category | Example Prompts |
|----------|----------------|
| **Design** | "design a feature", "create UI mockup", "create design canvas" |
| **PR Management** | "create a PR", "push changes", "merge PR" |
| **Code Review** | "address review comments", "resolve review threads", "handle reviewer findings" |
| **Bot Reviews** | "/q review", "/codex review", "respond to Amazon Q", "respond to Codex" |
| **CI/CD** | "check CI status", "wait for checks to pass" |

### How It Works

1. **Skill Detection**: When you mention workflow-related tasks, Claude Code automatically loads the `github-workflow` skill
2. **Step-by-Step Guidance**: The skill provides the 13-step workflow with detailed instructions
3. **Tool Integration**: Uses Pencil MCP for design, GitHub MCP/CLI for PR management, Chrome DevTools for E2E testing
4. **Hook Enforcement**: Pre/Post hooks validate each step is completed before proceeding

## Development Workflow

```
Step 0: MANDATORY PREREQUISITES (Hook Enforced)
    - Must be in a git worktree (.worktrees/<branch>)
    - Must be on a feature branch (not main)
    ↓
Step 1: Design Canvas (Pencil)
    ↓
Step 2: Create Git Worktree (MANDATORY)
    ↓
Step 3: Test Cases (TDD)
    ↓
Step 4: Implementation
    ↓
Step 5: Unit Tests Pass
    ↓
Step 6: code-simplifier review → commit
    ↓
Step 7: pr-review review → push
    ↓
Step 8: Wait for CI to pass
    ↓
Step 9: E2E Tests (Chrome DevTools)
    ↓
✅ Task Complete → Peer Review
```

## Hook Reference

### Enforcement Hooks (Blocking)

| Hook | Trigger | Behavior |
|------|---------|----------|
| block-push-to-main | git push on main | **Blocks** direct pushes to main branch |
| block-commit-outside-worktree | git commit outside worktree | **Blocks** commits in main workspace |
| check-code-simplifier | git commit | **Blocks** unreviewed commits |
| check-pr-review | git push | **Blocks** unreviewed pushes |

### Reminder Hooks (Non-Blocking)

| Hook | Trigger | Behavior |
|------|---------|----------|
| check-design-canvas | git commit | Reminds to create design docs |
| check-test-plan | Write/Edit new file | Reminds to create test plan |
| check-unit-tests | git commit | Reminds to run unit tests |
| warn-skip-verification | git --no-verify | Warns about skipping verification |

### PostToolUse Hooks

| Hook | Trigger | Behavior |
|------|---------|----------|
| post-git-action-clear | git commit/push success | Clears completed states |
| post-git-push | git push success | Reminds CI and E2E verification |
| post-file-edit-reminder | Write/Edit source code | Reminds to run tests |

### Stop Hook

| Hook | Trigger | Behavior |
|------|---------|----------|
| verify-completion | Task end | **Blocks** tasks without verification |

## MCP Tool Integration

The workflow integrates with several MCP (Model Context Protocol) tools:

| Tool | Purpose | Workflow Step |
|------|---------|---------------|
| **Pencil MCP** | Design canvas creation (`.pen` files) | Step 1: Design |
| **GitHub MCP** | PR creation, review management | Steps 7-11: PR & Review |
| **Chrome DevTools MCP** | E2E testing on preview environments | Step 12: E2E Tests |

## State Management

Use `state-manager.sh` to manage workflow states:

```bash
# View current states
.claude/hooks/state-manager.sh list

# Mark action as complete
.claude/hooks/state-manager.sh mark design-canvas
.claude/hooks/state-manager.sh mark test-plan
.claude/hooks/state-manager.sh mark code-simplifier
.claude/hooks/state-manager.sh mark pr-review
.claude/hooks/state-manager.sh mark unit-tests
.claude/hooks/state-manager.sh mark e2e-tests

# Clear state
.claude/hooks/state-manager.sh clear <action>
.claude/hooks/state-manager.sh clear-all
```

## Required Claude Code Plugins

Ensure these official Claude Code plugins are enabled:

- `code-simplifier@claude-plugins-official` - Code simplification review
- `pr-review-toolkit@claude-plugins-official` - Comprehensive PR review

### Optional MCP Servers

For full workflow support, configure these MCP servers:

| Server | Purpose | Configuration |
|--------|---------|---------------|
| Pencil | Design canvas creation | See Pencil MCP documentation |
| GitHub | PR and review management | `gh auth login` for CLI access |
| Chrome DevTools | E2E testing | Chrome with remote debugging enabled |

## GitHub Actions

CI workflow needs to be added manually (see `docs/github-actions-setup.md`).

Default CI includes:
- Lint & Type Check
- Unit Tests (with coverage)
- Build

Optional:
- E2E Tests (Playwright)
- Deploy Preview

> **Note**: Due to GitHub token permission restrictions, CI workflow files need to be added manually.
> See `docs/github-actions-setup.md` for complete configuration instructions.

## Reference Project

This template is based on the Claude Code memory and hook system implementation from [Openhands Infra](https://github.com/zxkane/openhands-infra).

## License

MIT License
