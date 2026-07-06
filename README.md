# Autonomous Dev Team

A fully automated development pipeline that turns issues into merged pull
requests — no human intervention required. It scans for issues labeled
`autonomous`, dispatches a **Dev Agent** to implement the feature with tests
in an isolated worktree, and hands off to a **Review Agent** for code review
with optional E2E verification. The entire cycle runs unattended on a cron
schedule.

- **Code hosts**: GitHub and GitLab (gitlab.com or any standard self-managed
  instance) via pluggable provider seams — see
  [GitLab support](#gitlab-support).
- **Agent CLIs**: Claude Code, Codex CLI, Kiro CLI, opencode, Cursor Agent,
  Antigravity CLI (agy), and most CLIs with a `-p <prompt>` non-interactive
  flag — see [docs/agent-clis.md](docs/agent-clis.md).

## Quick Start

### Option A: Install as portable skills (recommended)

```bash
npx skills add zxkane/autonomous-dev-team
```

| Skill | Description |
|-------|-------------|
| **autonomous-dev** | TDD workflow with git worktree isolation, design canvas, test-first development, code review, and CI verification |
| **autonomous-review** | PR code review with checklist verification, merge conflict resolution, E2E testing, and auto-merge |
| **autonomous-dispatcher** | Issue scanner that dispatches dev and review agents on a cron schedule |
| **autonomous-common** | Shared workflow-enforcement hooks and agent-callable utility scripts |
| **create-issue** | Structured issue creation with templates, autonomous label guidance, and workspace change attachment |

Works with Claude Code, Cursor, Windsurf, Antigravity, Kiro CLI, and
[40+ agents](https://skills.sh). After installing, follow
**[docs/installation.md](docs/installation.md)** for the post-install wiring
(symlinks, plugins, `autonomous.conf`, labels) — it includes a copy-paste
prompt that lets your AI agent drive the whole setup.

### Option B: Use as a template (full pipeline)

1. **Clone and configure**:
   ```bash
   gh repo create my-project --template zxkane/autonomous-dev-team
   cd my-project
   cp scripts/autonomous.conf.example scripts/autonomous.conf
   # Edit autonomous.conf — see docs/installation.md Step 4 for every key.
   ```

2. **Create the pipeline labels**:
   ```bash
   ( source scripts/autonomous.conf && bash scripts/setup-labels.sh "$REPO" )
   ```

3. **Schedule the dispatcher tick.** Anything that can run a shell command on
   a cadence works:

   | Host | When to use | Tick command |
   |------|------------|--------------|
   | [OpenClaw](https://github.com/OpenClaw/OpenClaw) (recommended) | Purpose-built skill runtime | `openclaw run skills/autonomous-dispatcher/SKILL.md` |
   | Plain cron | Zero extra infra | `bash skills/autonomous-dispatcher/scripts/dispatcher-tick.sh` |
   | GitHub Actions schedule / any scheduled runtime | Managed infra | same tick script (or `dispatcher-multi-tick.sh` for multi-project) |

   ```cron
   */5 * * * * cd /path/to/project && bash skills/autonomous-dispatcher/scripts/dispatcher-tick.sh
   ```

   The tick script is host-agnostic — it needs only `jq`, a code-host
   credential, and a reachable `autonomous.conf`. The agent CLI is invoked by
   the **wrapper** the tick spawns, not by the tick itself.

4. **Create an issue** with the `autonomous` label and watch the pipeline
   work — the dispatcher spawns agents, tracks progress via labels, and
   merges the PR when review passes.

## How It Works

```
Issue (autonomous label)
   │
   ▼
Dispatcher (cron tick) ──▶ Dev Agent ──────────▶ Review Agent
   scan + dispatch          worktree + TDD         find PR + review
   concurrency + retry      implement + test       optional E2E verify
                            open PR                approve + merge
```

Issues progress through labels managed automatically by the agents:

```
autonomous → in-progress → pending-review → reviewing → approved (merged)
                                                 │
                                                 └─→ pending-dev (loop back if review fails)
```

With the `no-auto-close` label, the PR is approved but not auto-merged — the
repo owner is notified instead.

Every issue/code-host operation routes through **pluggable provider seams**
(`ISSUE_PROVIDER` / `CODE_HOST`): abstract verbs with per-provider leaves,
proven by a provider-parameterized conformance suite. The normative contract
lives in [docs/pipeline/provider-spec.md](docs/pipeline/provider-spec.md).

| Component | Wrapper / entry | Skill | Details |
|---|---|---|---|
| Dev Agent | `scripts/autonomous-dev.sh` | `skills/autonomous-dev/SKILL.md` | worktree isolation, TDD, checkbox tracking, resume-after-feedback |
| Review Agent | `scripts/autonomous-review.sh` | `skills/autonomous-review/SKILL.md` | PR discovery, conflict rebase, bot reviewers, multi-agent verdicts, E2E, auto-merge |
| Dispatcher | `scripts/dispatcher-tick.sh` | `skills/autonomous-dispatcher/SKILL.md` | issue scanning, concurrency control, stale detection |

Multi-agent review (`AGENT_REVIEW_AGENTS`), external review bots
(`REVIEW_BOTS`), and per-CLI configuration are covered in
[docs/agent-clis.md](docs/agent-clis.md).

## GitLab Support

Both provider seams accept `gitlab`: issues and merge requests on gitlab.com
or any self-managed CE/EE instance whose API speaks standard PAT auth against
`/api/v4`.

```bash
# scripts/autonomous.conf
ISSUE_PROVIDER="gitlab"
CODE_HOST="gitlab"
GITLAB_HOST="gitlab.example.com"          # default gitlab.com
GITLAB_TOKEN="glpat-…"                    # PAT / project / group token, scope `api`
GITLAB_PROJECT="group%2Fsubgroup%2Fproject"   # URL-encoded namespace/name
```

- **Setup guide**: [docs/gitlab-setup.md](docs/gitlab-setup.md) — token
  creation, self-hosted host config, the auth model, and verification steps.
- **Custom auth gateways** (SSO-cookie instances, mTLS, forked transports):
  supported **out-of-tree** via `GITLAB_TRANSPORT_HOOK` — an operator-owned
  file that replaces the single HTTP primitive while the library keeps
  pagination, backoff, and fail-closed semantics. Contract in
  [docs/pipeline/provider-spec.md](docs/pipeline/provider-spec.md) §transport.
- **Capability differences vs GitHub** (declared in
  `providers/chp-gitlab.caps`, callers branch automatically): no external
  review bots (`review_bots=0`), no REST "request changes" object
  (findings post as comments + labels), auto-close fires only on merge to
  the default branch, and agent tokens are convention-contained (GitLab has
  no GitHub-App equivalent — see [docs/security.md](docs/security.md)).

GitHub remains the default: an existing conf with no provider keys set
behaves byte-identically.

## Security

**Designed for private repositories and trusted environments.** The pipeline
executes issue content as agent instructions — in a public repo that is a
prompt-injection surface. Read **[docs/security.md](docs/security.md)** for
the risk model, per-environment recommendations, the mitigation checklist,
and the token posture per code host. Minimum for public repos: restrict who
can apply the `autonomous` label, and use `no-auto-close` so merges stay
manual.

## Interactive Development Workflow

Beyond autonomous mode, the same hooks enforce a TDD workflow for interactive
coding-agent sessions:

```
Design Canvas → Worktree → Test Cases → Implement → Unit Tests
   → code-simplifier → commit → pr-review → push → CI → E2E
```

- Step-by-step workflow: [CLAUDE.md](CLAUDE.md)
- Hook reference + state manager:
  [skills/autonomous-common/hooks/README.md](skills/autonomous-common/hooks/README.md)
- Cross-agent hook support (Kiro, Cursor, …):
  [docs/cross-agent-hooks.md](docs/cross-agent-hooks.md)

## Documentation Index

| Topic | Where |
|---|---|
| Install + configure (agent-driven, step-by-step) | [docs/installation.md](docs/installation.md) |
| Agent CLIs: support matrix, per-CLI flags, multi-agent review | [docs/agent-clis.md](docs/agent-clis.md) |
| GitLab setup (tokens, self-hosted, transport hook) | [docs/gitlab-setup.md](docs/gitlab-setup.md) |
| GitHub App auth (bot identities, two-token split) | [docs/github-app-setup.md](docs/github-app-setup.md) |
| Security model + mitigations | [docs/security.md](docs/security.md) |
| Pipeline overview (architecture, concurrency) | [docs/autonomous-pipeline.md](docs/autonomous-pipeline.md) |
| Pipeline spec (state machine, invariants, flows) | [docs/pipeline/](docs/pipeline/) |
| Provider seams (ITP/CHP verbs, conformance, transport) | [docs/pipeline/provider-spec.md](docs/pipeline/provider-spec.md) |
| Hooks reference + state manager | [skills/autonomous-common/hooks/README.md](skills/autonomous-common/hooks/README.md) |
| CI workflow setup | [docs/github-actions-setup.md](docs/github-actions-setup.md) |
| Interactive TDD workflow | [CLAUDE.md](CLAUDE.md) |

## Reference Project

This template is based on the Claude Code memory and hook system
implementation from [Openhands Infra](https://github.com/zxkane/openhands-infra).

## License

MIT License
