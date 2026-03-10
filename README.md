# Autonomous Dev Team

A fully automated development pipeline that turns GitHub issues into merged pull requests — no human intervention required. Powered by [**OpenClaw**](https://github.com/OpenClaw/OpenClaw) as the orchestration layer, it scans for issues labeled `autonomous`, dispatches a **Dev Agent** to implement the feature with tests in an isolated worktree, and hands off to a **Review Agent** for code review with optional E2E verification. The entire cycle runs unattended on a cron schedule.

Supports multiple coding agent CLIs — Claude Code, Codex CLI, and Kiro CLI — with a pluggable agent abstraction layer.

## How It Works

```
                        ┌──────────────────────────────────────────────────────────┐
                        │                    OpenClaw Orchestration                 │
                        │                                                          │
GitHub Issue            │   Dispatcher            Dev Agent         Review Agent   │
(autonomous label)      │   (cron 5min)           (implements)     (verifies)     │
       │                │        │                     │                │          │
       ▼                │        ▼                     ▼                ▼          │
  ┌──────────┐          │  ┌───────────┐     ┌──────────────┐  ┌──────────────┐   │
  │ GitHub   │─────────▶│  │ Scan      │────▶│ Worktree     │─▶│ Find PR      │   │
  │ Issues   │          │  │ issues    │     │ + Implement  │  │ + Review     │   │
  │          │◀─────────│──│ Dispatch  │     │ + Test       │  │ + E2E verify │   │
  │ Labels:  │          │  │ agents    │     │ + Create PR  │  │ + Approve    │   │
  │ auto     │          │  │           │     │              │  │ + Merge      │   │
  └──────────┘          │  └───────────┘     └──────────────┘  └──────────────┘   │
                        │                                                          │
                        └──────────────────────────────────────────────────────────┘
```

### Label State Machine

Issues progress through labels managed automatically by the agents:

```
autonomous → in-progress → pending-review → reviewing → approved (merged)
                                                 │
                                                 └─→ pending-dev (loop back if review fails)
```

When the `no-auto-close` label is present, the PR is approved but not auto-merged — the repo owner is notified instead.

## Agents

### Dev Agent

The dev agent receives a GitHub issue, creates an isolated worktree, implements the feature, writes tests, and creates a pull request.

| Capability | Description |
|-----------|-------------|
| **Worktree isolation** | Each issue gets its own git worktree — no cross-contamination |
| **TDD workflow** | Follows the project's github-workflow skill for test-first development |
| **Issue checkbox tracking** | Marks `## Requirements` checkboxes as items are implemented |
| **Resume support** | Can resume a previous session after review feedback (`--mode resume`) |
| **Exit-aware cleanup** | On success → `pending-review`; on failure → `pending-dev` for retry |

**Wrapper**: `scripts/autonomous-dev.sh`
**Skill**: `.claude/skills/autonomous-dev/SKILL.md`

### Review Agent

The review agent finds the PR linked to an issue, performs code review, optionally runs E2E verification via Chrome DevTools MCP, and either approves+merges or sends back with specific feedback.

| Capability | Description |
|-----------|-------------|
| **PR discovery** | Finds the linked PR via body reference, issue comments, or search |
| **Merge conflict resolution** | Automatically rebases if the PR conflicts with main |
| **Code review checklist** | Verifies design docs, tests, CI status, and PR conventions |
| **Amazon Q integration** | Triggers and monitors Amazon Q Developer review |
| **E2E verification** | Optional Chrome DevTools MCP testing with screenshot evidence |
| **Acceptance criteria tracking** | Marks `## Acceptance Criteria` checkboxes as verified |
| **Auto-merge** | Squash-merges and closes the issue on review pass |

**Wrapper**: `scripts/autonomous-review.sh`
**Skill**: `.claude/skills/autonomous-review/SKILL.md`

### Dispatcher ([OpenClaw](https://github.com/OpenClaw/OpenClaw))

The dispatcher is an [OpenClaw](https://github.com/OpenClaw/OpenClaw) skill that orchestrates the entire pipeline. OpenClaw runs it on a cron schedule, scanning GitHub for actionable issues and spawning the appropriate agent. The dispatcher skill defines the orchestration logic; OpenClaw provides the execution runtime.

| Capability | Description |
|-----------|-------------|
| **Issue scanning** | Finds issues with `autonomous`, `pending-dev`, or `pending-review` labels |
| **Concurrency control** | Enforces `MAX_CONCURRENT` limit via PID file checks |
| **Stale detection** | Detects and recovers from zombie agent processes |
| **Local dispatch** | Spawns agents via `nohup` with post-spawn health check |

**OpenClaw Skill**: `openclaw/skills/autonomous-dispatcher/SKILL.md`
**Dispatch script**: `openclaw/skills/autonomous-dispatcher/dispatch-local.sh`

### Supported Agent CLIs

| Agent CLI | Command | New Session | Resume | Status |
|-----------|---------|-------------|--------|--------|
| Claude Code | `claude` | `--session-id` | `--resume` | Full support |
| Codex CLI | `codex` | `-p` | (falls back to new) | Basic support |
| Kiro CLI | `kiro` | `-p` | (falls back to new) | Planned |

Configure via `AGENT_CMD` in `scripts/autonomous.conf`.

## Quick Start

1. **Clone and configure**:
   ```bash
   gh repo create my-project --template zxkane/claude-code-workflow
   cd my-project
   cp scripts/autonomous.conf.example scripts/autonomous.conf
   # Edit autonomous.conf — set REPO, PROJECT_DIR, agent CLI, etc.
   ```

2. **Install [OpenClaw](https://github.com/OpenClaw/OpenClaw)** and set up the dispatcher cron:
   ```bash
   # Install OpenClaw (the orchestration engine)
   # See https://github.com/OpenClaw/OpenClaw for installation

   # Schedule the dispatcher to run every 5 minutes
   */5 * * * * cd /path/to/project && openclaw run openclaw/skills/autonomous-dispatcher/SKILL.md
   ```

3. **Create an issue** with the `autonomous` label and watch the pipeline work — OpenClaw dispatches agents, tracks progress via labels, and merges the PR when review passes.

### GitHub App Authentication (Optional)

For production use with separate bot identities per agent, set up GitHub Apps. See `docs/github-app-setup.md` for the full guide.

## Development Workflow (Hook System)

Beyond autonomous mode, this template also provides a **hook-enforced development workflow** for interactive Claude Code sessions:

```
Step 0: Prerequisites (Hook Enforced)
    - Must be in a git worktree
    - Must be on a feature branch (not main)
    ↓
Step 1: Design Canvas (Pencil) → Step 2: Create Worktree
    ↓
Step 3: Test Cases (TDD) → Step 4: Implementation
    ↓
Step 5: Unit Tests Pass → Step 6: code-simplifier review → commit
    ↓
Step 7: pr-review agent → push → Step 8: Wait for CI
    ↓
Step 9: E2E Tests (Chrome DevTools) → ✅ Peer Review
```

See `CLAUDE.md` for detailed step-by-step instructions.

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
│       ├── github-workflow/     # GitHub development workflow skill
│       │   ├── SKILL.md         # Main skill definition (13-step workflow)
│       │   ├── references/      # Reference documentation
│       │   │   ├── commit-conventions.md  # Branch naming & commit standards
│       │   │   └── review-commands.md     # GitHub CLI & GraphQL commands
│       │   └── scripts/         # Utility scripts
│       │       ├── reply-to-comments.sh   # Reply to PR review comments
│       │       └── resolve-threads.sh     # Batch resolve review threads
│       ├── autonomous-dev/      # Autonomous development skill
│       │   └── SKILL.md         # Dev agent instructions
│       └── autonomous-review/   # Autonomous review skill
│           └── SKILL.md         # Review agent instructions
├── scripts/                     # Autonomous pipeline scripts
│   ├── autonomous.conf.example  # Configuration template
│   ├── autonomous-dev.sh        # Dev agent wrapper
│   ├── autonomous-review.sh     # Review agent wrapper
│   ├── lib-agent.sh             # Agent abstraction (Claude/Codex/Kiro)
│   ├── lib-auth.sh              # GitHub auth abstraction
│   ├── gh-app-token.sh          # GitHub App token generation
│   ├── gh-as-user.sh            # Run gh CLI as a GitHub App user
│   ├── gh-token-refresh-daemon.sh   # Background token refresh
│   ├── gh-with-token-refresh.sh     # gh CLI with auto-refresh
│   ├── mark-issue-checkbox.sh   # Mark issue checkboxes
│   └── upload-screenshot.sh     # Upload screenshots to issues
├── openclaw/
│   └── skills/
│       └── autonomous-dispatcher/   # OpenClaw dispatcher skill
│           ├── SKILL.md             # Dispatcher instructions
│           └── dispatch-local.sh    # Local dispatch script
├── docs/
│   ├── autonomous-pipeline.md   # Pipeline overview documentation
│   ├── github-app-setup.md      # GitHub App configuration guide
│   ├── github-actions-setup.md  # CI workflow setup guide
│   ├── designs/                 # Design canvas documents
│   ├── test-cases/              # Test case documents
│   └── templates/               # Document templates
│       ├── design-canvas-template.md
│       └── test-case-template.md
└── .github/                     # (CI workflow needs manual setup)
```

## Documentation

- **Pipeline overview**: `docs/autonomous-pipeline.md`
- **GitHub App setup**: `docs/github-app-setup.md`
- **E2E config template**: `docs/templates/e2e-config-template.md`
- **Dispatcher skill**: `openclaw/skills/autonomous-dispatcher/SKILL.md`
- **CI setup**: `docs/github-actions-setup.md`

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
