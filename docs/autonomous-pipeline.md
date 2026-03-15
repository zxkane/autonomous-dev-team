# Autonomous Dev Team Pipeline

## Overview

The Autonomous Dev Team pipeline automates the full software development lifecycle for GitHub issues. When an issue is labeled with `autonomous`, the pipeline automatically:

1. **Dispatches** a development agent to implement the requirements
2. **Reviews** the resulting PR with a separate review agent
3. **Merges** the PR if all checks pass, or **sends back** for fixes if not

The pipeline runs without human intervention, using AI coding agents (Claude Code, Codex, Kiro) to write code, tests, and documentation. Human oversight is maintained through GitHub issue tracking, PR reviews, and the `no-auto-close` label for manual approval gates.

## Architecture

```
                    ┌──────────────────────────────┐
                    │      GitHub Issues            │
                    │   (autonomous label)          │
                    └──────────────┬───────────────┘
                                   │
                          ┌────────▼────────┐
                          │    OpenClaw      │
                          │   Dispatcher     │
                          │  (cron 5min)     │
                          └──┬─────────┬────┘
                             │         │
                   ┌─────────▼──┐  ┌───▼──────────┐
                   │  Dev Agent  │  │ Review Agent  │
                   │  (Opus)     │  │ (Sonnet)      │
                   │             │  │               │
                   │ - Design    │  │ - Code review │
                   │ - Implement │  │ - CI verify   │
                   │ - Test      │  │ - E2E tests   │
                   │ - Create PR │  │ - Approve/Fail│
                   └──────┬──────┘  └───────┬──────┘
                          │                 │
                          ▼                 ▼
                    ┌──────────────────────────────┐
                    │      GitHub PRs               │
                    │   (auto-merge or manual)      │
                    └──────────────────────────────┘
```

### Component Responsibilities

| Component | Runtime | Responsibility |
|-----------|---------|----------------|
| OpenClaw Dispatcher | Cron (every 5 min) | Scans issues, manages labels, dispatches dev/review agents |
| Dev Agent | Coding agent session | Implements requirements, writes tests, creates PR |
| Review Agent | Coding agent session | Reviews PR, runs E2E tests, approves or requests changes |

> **Note:** Scripts are bundled inside skill directories for portability.
> The project-root `scripts/` directory is a symlink to
> `skills/autonomous-dispatcher/scripts/`. Shared scripts are symlinked
> from `skills/autonomous-common/scripts/`.

## Prerequisites

- **OpenClaw** — Agent orchestration platform (or use `dispatch-local.sh` for local dispatch)
- **Coding agent CLI** — One of: `claude` (Claude Code), `codex`, or `kiro`
- **GitHub CLI** (`gh`) — Authenticated with appropriate permissions
- **jq** — JSON processor for parsing GitHub API responses
- **Git** — With worktree support

## Quick Start

### 1. Clone the repository

```bash
git clone https://github.com/<owner>/<repo>.git
cd <repo>
```

### 2. Copy configuration template

```bash
cp scripts/autonomous.conf.example scripts/autonomous.conf
```

### 3. Fill in configuration

Edit `scripts/autonomous.conf` with your project values:

```bash
# Required
PROJECT_ID="my-project"
REPO="owner/repo-name"
REPO_OWNER="owner"
REPO_NAME="repo-name"
PROJECT_DIR="/path/to/project"

# Authentication (choose one mode)
GH_AUTH_MODE="token"  # or "app" for GitHub App tokens

# Optional: E2E verification
E2E_ENABLED="false"
```

See the [Configuration Reference](#configuration-reference) section for all available options.

### 4. Set up dispatch

**Option A: OpenClaw cron (recommended)**

```bash
openclaw cron add \
  --name "Autonomous Dispatcher" \
  --cron "*/5 * * * *" \
  --session isolated \
  --message "Run the autonomous-dispatcher skill. Check GitHub issues and dispatch tasks." \
  --announce
```

**Option B: Local dispatch script**

```bash
# Run the dispatcher manually
bash scripts/dispatch-local.sh
```

### 5. Create an issue with the `autonomous` label

Create a GitHub issue with the `autonomous` label. The issue body should include:

```markdown
## Requirements
- [ ] Requirement 1
- [ ] Requirement 2

## Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2
```

The pipeline will pick it up within 5 minutes.

## Configuration Reference

All configuration is stored in `scripts/autonomous.conf`. Values can also be set via environment variables.

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `PROJECT_ID` | Unique project identifier (used in log/PID filenames) | — | Yes |
| `REPO` | GitHub repository in `owner/repo` format | — | Yes |
| `REPO_OWNER` | Repository owner (org or user) | — | Yes |
| `REPO_NAME` | Repository name | — | Yes |
| `PROJECT_DIR` | Absolute path to the project root | — | Yes |
| `AGENT_CMD` | Coding agent CLI command | `claude` | No |
| `AGENT_DEV_MODEL` | Model for development tasks | _(agent default)_ | No |
| `AGENT_REVIEW_MODEL` | Model for review tasks | `sonnet` | No |
| `AGENT_PERMISSION_MODE` | Agent permission mode | `bypassPermissions` | No |
| `GH_AUTH_MODE` | GitHub auth mode: `token` or `app` | `token` | No |
| `DEV_AGENT_APP_ID` | GitHub App ID for dev agent (app mode only) | — | If app mode |
| `DEV_AGENT_APP_PEM` | Path to dev agent App private key PEM | — | If app mode |
| `REVIEW_AGENT_APP_ID` | GitHub App ID for review agent (app mode only) | — | If app mode |
| `REVIEW_AGENT_APP_PEM` | Path to review agent App private key PEM | — | If app mode |
| `DISPATCHER_APP_ID` | GitHub App ID for dispatcher (app mode only) | — | If app mode |
| `DISPATCHER_APP_PEM` | Path to dispatcher App private key PEM | — | If app mode |
| `MAX_CONCURRENT` | Maximum concurrent agent tasks | `5` | No |
| `DEV_SKILL_CMD` | Skill command for dev agent prompt | `/autonomous-dev` | No |
| `E2E_ENABLED` | Enable E2E verification in review | `false` | No |
| `E2E_PREVIEW_URL_PATTERN` | Preview URL template (`{N}` = PR number) | — | If E2E enabled |
| `E2E_TEST_USER_EMAIL` | Test user email for E2E login | — | If E2E enabled |
| `E2E_TEST_USER_PASSWORD` | Test user password for E2E login | — | If E2E enabled |
| `E2E_SCREENSHOT_UPLOAD` | Enable screenshot upload to GitHub | `false` | No |

## State Machine

Issues move through a defined set of states, tracked by GitHub labels:

```
                                    ┌──────────────────┐
                                    │   autonomous     │
  Issue created ──────────────────► │   (no state)     │
  with label                        └────────┬─────────┘
                                             │
                                    Dispatcher picks up
                                             │
                                    ┌────────▼─────────┐
                              ┌────►│  in-progress      │◄────┐
                              │     └────────┬─────────┘     │
                              │              │               │
                              │     Dev agent completes      │
                              │              │               │
                              │     ┌────────▼─────────┐     │
                              │     │  pending-review   │     │
                              │     └────────┬─────────┘     │
                              │              │               │
                              │     Dispatcher picks up      │
                              │              │               │
                              │     ┌────────▼─────────┐     │
                              │     │  reviewing        │     │
                              │     └───┬──────────┬───┘     │
                              │         │          │         │
                              │    PASS │          │ FAIL    │
                              │         │          │         │
                              │         ▼          ▼         │
                              │   ┌──────────┐ ┌──────────┐ │
                              │   │ approved  │ │pending-dev│─┘
                              │   └──────────┘ └──────────┘
                              │         │
                              └─────────┘
                              (crash recovery)
```

### Label Definitions

| Label | Color | Description |
|-------|-------|-------------|
| `autonomous` | `#0E8A16` | Issue should be processed by the autonomous pipeline |
| `in-progress` | `#FBCA04` | Dev agent is actively working |
| `pending-review` | `#1D76DB` | Development complete, awaiting review dispatch |
| `reviewing` | `#5319E7` | Review agent is actively reviewing |
| `pending-dev` | `#E99695` | Review failed, needs more development |
| `approved` | `#0E8A16` | Review passed, PR merged (or awaiting manual merge) |
| `no-auto-close` | `#d4c5f9` | Skip auto-merge after review passes; requires manual approval |

## Agent Model Strategy

| Task | Model | Rationale |
|------|-------|-----------|
| Development | Opus (default) | Complex coding, architecture decisions, multi-file changes |
| Review | Sonnet | Checklist verification, diff analysis; avoids Opus quota contention |

The dev agent uses the default model (typically Opus) for maximum coding capability. The review agent uses Sonnet to avoid competing for Opus quota while still providing thorough review analysis.

Configure via `AGENT_DEV_MODEL` and `AGENT_REVIEW_MODEL` in `autonomous.conf`.

## Concurrency Control

- **MAX_CONCURRENT** (default: 5) limits total active tasks (dev + review combined)
- Each issue gets an independent git worktree and agent session
- The dispatcher checks concurrency before dispatching new tasks
- PID files at `/tmp/cc-${PROJECT_ID}-{issue|review}-<number>.pid` track active processes

## Crash Recovery

The pipeline is designed to recover from agent crashes automatically:

| Scenario | Detection | Recovery |
|----------|-----------|----------|
| Dev agent crashes | PID file exists but process is dead | Dispatcher moves issue to `pending-review` for assessment |
| Review agent crashes | PID file exists but process is dead | Dispatcher moves issue to `pending-dev` for retry |
| Dev agent timeout | No activity for extended period | Same as crash — stale detection in dispatcher |
| Resume after crash | Issue has `pending-dev` label + session ID in comments | Dispatcher dispatches `dev-resume` with previous session ID |
| Partial implementation | Requirement checkboxes partially checked | Dev agent reads issue body on resume, skips completed items |

### Stale Detection

The dispatcher checks for stale processes by:
1. Reading the PID file: `/tmp/cc-${PROJECT_ID}-issue-<N>.pid`
2. Sending `kill -0 <pid>` to check if the process is alive
3. If dead, transitioning the issue to the appropriate recovery state

## Log File Locations

| Log File | Content |
|----------|---------|
| `/tmp/cc-${PROJECT_ID}-issue-<N>.log` | Dev agent session output |
| `/tmp/cc-${PROJECT_ID}-review-<N>.log` | Review agent session output |

PID files follow the same pattern with `.pid` extension.

## Supported Agents

| Agent | Command | Dev Support | Review Support | Resume Support |
|-------|---------|-------------|----------------|----------------|
| Claude Code | `claude` | Full | Full | Yes (session resume) |
| Codex | `codex` | Basic | Basic | No (new session on resume) |
| Kiro | `kiro` | Basic | Basic | No (new session on resume) |

Set `AGENT_CMD` in `autonomous.conf` to switch agents. Claude Code is recommended for full pipeline support including session resume.

## Key Files

| File | Description |
|------|-------------|
| `scripts/autonomous-dev.sh` | Dev agent wrapper (handles label transitions) |
| `scripts/autonomous-review.sh` | Review agent wrapper (handles approve/merge/fail) |
| `scripts/autonomous.conf.example` | Configuration template |
| `scripts/lib-agent.sh` | Agent CLI abstraction (claude/codex/kiro) |
| `scripts/lib-auth.sh` | GitHub authentication abstraction (token/app) |
| `scripts/gh-app-token.sh` | GitHub App JWT token generator |
| `scripts/gh-token-refresh-daemon.sh` | Background token refresh for long-running sessions |
| `scripts/gh-with-token-refresh.sh` | `gh` wrapper that reads refreshed tokens |
| `scripts/gh-as-user.sh` | Run `gh` commands as a real user (for bot workarounds) |
| `scripts/mark-issue-checkbox.sh` | Mark issue checkboxes (used by both agents) |
| `scripts/upload-screenshot.sh` | Upload E2E screenshots to GitHub |
| `skills/autonomous-dev/SKILL.md` | Dev agent skill definition |
| `skills/autonomous-review/SKILL.md` | Review agent skill definition |
| `skills/autonomous-dispatcher/SKILL.md` | Dispatcher skill definition |
| `scripts/dispatch-local.sh` | Local dispatch helper |
