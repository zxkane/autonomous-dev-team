# Installation Guide (Agent-Driven)

This guide is written for an AI coding agent (Claude Code, Cursor, Codex CLI,
Kiro, etc.) driving the install on the user's behalf. Every command is
copy-pasteable; every step has a verifiable outcome. If you are a human
reader, follow these steps yourself or paste the prompt at the bottom into
your agent.

## Step 1 — Install the skills

Use the `skills` CLI (note the trailing `s` — `skill` without `s` is a
different tool that targets `.codebuddy/skills/`).

```bash
# Install all skills into the current project, targeting Claude Code only.
# -a claude-code: scope the install to Claude Code (omit and the CLI creates
#                 empty placeholder dirs for every other agent it knows about,
#                 polluting the workspace).
# -y           : skip interactive confirmation.
npx skills add zxkane/autonomous-dev-team -a claude-code -y
```

For a single skill from the bundle (rare — most users want all of them):

```bash
npx skills add zxkane/autonomous-dev-team --skill autonomous-dev -a claude-code -y
```

**Verify the install:**

```bash
ls .claude/skills
# Expect: autonomous-common  autonomous-dev  autonomous-dispatcher  autonomous-review  create-issue
```

## Step 2 — Wire the symlinks (Claude Code / Kiro CLI only)

Hook scripts and agent-callable scripts live inside the installed skill dirs
but are referenced from the project root. Create the symlinks so the paths
resolve:

```bash
ln -sf .claude/skills/autonomous-common/hooks   hooks
ln -sf .claude/skills/autonomous-dispatcher/scripts scripts
```

**Verify the symlinks:**

```bash
test -x hooks/state-manager.sh && echo "hooks OK"
test -f scripts/autonomous.conf.example && echo "scripts OK"
```

> **Why symlinks?** `npx skills add` copies each skill directory into
> `.claude/skills/`, but hook commands use `$CLAUDE_PROJECT_DIR/hooks/` (the
> project root). The symlinks bridge this gap. The `scripts/` symlink enables
> agent-callable utility scripts referenced by the skills (e.g.,
> `scripts/gh-as-user.sh`).

If your IDE has no hook support (Cursor, Windsurf, Gemini CLI), skip this
step — the skills still work; you just enforce the workflow manually.

## Step 3 — Enable required Claude Code plugins

Edit `.claude/settings.json` and add these to `enabledPlugins`:

```json
{
  "enabledPlugins": {
    "code-simplifier@claude-plugins-official": true,
    "pr-review-toolkit@claude-plugins-official": true
  }
}
```

The hooks reference subagents from these plugins
(`code-simplifier:code-simplifier`, `pr-review-toolkit:code-reviewer`).
Without them, the `check-code-simplifier.sh` and `check-pr-review.sh` gates
will block commits/pushes.

## Step 4 — Create per-project `autonomous.conf`

```bash
cp scripts/autonomous.conf.example scripts/autonomous.conf
```

The file is a bash script that's `source`d at every dispatcher tick and
wrapper invocation. Fill in these required values:

| Variable | Required | What to set | Notes |
|---|---|---|---|
| `PROJECT_ID` | Yes | Short identifier (e.g. `acme-api`) | Used in PID/log file names. Must be unique per project. |
| `REPO` | Yes | `owner/repo-name` | The repo the pipeline watches. |
| `REPO_OWNER`, `REPO_NAME` | Yes | Split form of `REPO` | Used for App-token scoping (GitHub). |
| `PROJECT_DIR` | Yes | Absolute path to the project root on the dispatcher box | Where the agent runs. |
| `ISSUE_PROVIDER`, `CODE_HOST` | No (default `github`) | `github` or `gitlab` | The two provider seams (issue tracker / code host). See [gitlab-setup.md](gitlab-setup.md) for the GitLab lane. |
| `AGENT_CMD` | No (default `claude`) | `claude`, `codex`, `kiro`, `gemini`, or `opencode` | The CLI used to spawn dev/review agents. See [agent-clis.md](agent-clis.md) for per-CLI notes and resume semantics. |
| `AGENT_DEV_MODEL`, `AGENT_REVIEW_MODEL` | No (default empty / `sonnet`) | Model name passed to the agent CLI | Empty = let the CLI pick. The review model defaults to `sonnet` to keep review costs predictable. |
| `AGENT_REVIEW_AGENTS` | No (default empty) | Space-separated CLI list (e.g. `agy kiro`) | Run **multiple** independent review agents and gate the merge on unanimous agreement. See [agent-clis.md](agent-clis.md#multiple-review-agents). |
| `AGENT_PERMISSION_MODE` | No (default `auto`) | `auto`, `plan`, or `bypassPermissions` | `bypassPermissions` grants the agent unrestricted shell access — only use in a trusted sandbox. |
| `AGENT_TIMEOUT` | No (default `4h`) | coreutils `timeout` units (e.g. `30m`, `2h`, `1d`) | Wall-clock cap on each agent invocation. |
| `GH_AUTH_MODE` | No (default `token`) | `token` or `app` | GitHub lane only. `app` uses GitHub App private keys (see [github-app-setup.md](github-app-setup.md)). |
| `GITLAB_HOST`, `GITLAB_TOKEN`, `GITLAB_PROJECT` | GitLab lane | See [gitlab-setup.md](gitlab-setup.md) | Required when either seam is `gitlab`. |
| `MAX_CONCURRENT` | No (default `5`) | Number | Cap on parallel agent processes. |
| `MAX_RETRIES` | No (default `3`) | Number | Dev-agent retry budget before the issue is marked `stalled`. |
| `REVIEW_BOTS` | No (default `q`) | Space-separated short names | External bot reviewers that MUST run on every PR before approval (GitHub lane; built-in: `q` / `codex` / `claude`). Empty string disables bot enforcement. |
| `E2E_ENABLED` | No (default `false`) | `true` / `false` | Enable Chrome DevTools MCP E2E verification in the review step. |
| `REAL_GH` | No (default empty) | Absolute path to the real `gh` binary | Set when `gh` is outside the minimal POSIX PATH AND the dispatcher runs from a non-interactive shell (cron, systemd, SSM, nohup). |

**Validate the config:**

```bash
bash -n scripts/autonomous.conf            # syntax check
( source scripts/autonomous.conf && \
  echo "REPO=$REPO PROJECT_DIR=$PROJECT_DIR AGENT_CMD=${AGENT_CMD:-claude} REVIEW_BOTS='${REVIEW_BOTS:-q}'" )
```

## Step 5 — Create the pipeline labels

```bash
# Source the config first so $REPO resolves; subshell prevents leaking vars.
( source scripts/autonomous.conf && bash scripts/setup-labels.sh "$REPO" )
```

Creates `autonomous`, `pending-dev`, `in-progress`, `pending-review`,
`reviewing`, `done`, `stalled`, `no-auto-close`, etc. Idempotent — safe to
re-run. On the GitLab lane, label provisioning routes through the provider
seam automatically.

## Step 6 — Smoke-test the wrappers (no actual agent spawn)

```bash
bash -n scripts/autonomous-dev.sh        # spawned per-issue by the dispatcher (dev path)
bash -n scripts/autonomous-review.sh     # spawned per-issue by the dispatcher (review path)
bash -n scripts/dispatcher-tick.sh       # the per-tick entry point
```

All three should print nothing (clean syntax). At runtime, if
`dispatcher-tick.sh` reports `REVIEW_BOTS validation failed`, fix the typo in
`autonomous.conf` and re-run — the precheck aborts the whole tick before any
API call, so no retry counter advances.

## Copy-paste prompt for an AI agent

Paste this into Claude Code, Cursor, Codex CLI, or any agent that can run
shell commands. The agent will execute the steps above end-to-end.

````markdown
Install the autonomous-dev-team skills into this project. The repo is
`zxkane/autonomous-dev-team` on GitHub.

Do these steps in order. After each step, verify the outcome before moving on.

1. Run `npx skills add zxkane/autonomous-dev-team -a claude-code -y` and confirm
   `.claude/skills/autonomous-{common,dev,dispatcher,review}` and
   `.claude/skills/create-issue` exist.

2. Create the two project-root symlinks:
   `ln -sf .claude/skills/autonomous-common/hooks hooks`
   `ln -sf .claude/skills/autonomous-dispatcher/scripts scripts`
   Verify `hooks/state-manager.sh` and `scripts/autonomous.conf.example` are
   reachable.

3. Add `code-simplifier@claude-plugins-official` and
   `pr-review-toolkit@claude-plugins-official` to `enabledPlugins` in
   `.claude/settings.json` (create the file if missing).

4. Copy `scripts/autonomous.conf.example` to `scripts/autonomous.conf`. Then
   ASK ME for the values of: `PROJECT_ID`, `REPO`, `PROJECT_DIR`, `AGENT_CMD`
   (default `claude`), `ISSUE_PROVIDER`/`CODE_HOST` (default `github`;
   `gitlab` needs the GITLAB_* keys — see docs/gitlab-setup.md),
   `REVIEW_BOTS` (default `q`), `GH_AUTH_MODE` (default `token`). Edit the
   file in place; do not commit secrets. After editing, run
   `bash -n scripts/autonomous.conf` and source it to confirm the values
   echo back correctly.

5. Source the config and run `bash scripts/setup-labels.sh "$REPO"` to create
   the pipeline labels. (Without sourcing first, `$REPO` will be empty and
   `setup-labels.sh` will target the wrong repo or fail.)
   ```bash
   ( source scripts/autonomous.conf && bash scripts/setup-labels.sh "$REPO" )
   ```

6. Smoke-test syntax: `bash -n scripts/autonomous-dev.sh
   scripts/autonomous-review.sh scripts/dispatcher-tick.sh`. Report any errors.

7. STOP HERE. Do NOT schedule the dispatcher cron — that's a separate decision
   the user makes based on which orchestration host they use (OpenClaw, plain
   cron + agent CLI, GitHub Actions schedule, etc.). Tell the user what
   options the README's "Run the full pipeline" section lists and let them pick.
````
