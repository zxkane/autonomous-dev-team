---
name: autonomous-dispatcher
description: >
  This skill should be used when dispatching autonomous development or review
  tasks from GitHub issues. Covers scanning for new issues with the 'autonomous'
  label, dispatching dev-new/dev-resume/review processes, dependency checking,
  retry counting, stale process detection, and concurrency limiting. Use when
  asked to "run the dispatcher", "scan for pending issues", "dispatch autonomous
  tasks", "check stale agents", or "set up the dispatch cron".
metadata: {"openclaw": {"requires": {"bins": ["gh", "jq"], "env": ["PROJECT_DIR"]}}}
---

# Autonomous Dev Team Dispatcher

Scan GitHub issues and dispatch dev/review tasks locally. One cron tick is one invocation of `dispatcher-tick.sh`. The full state machine, per-step semantics, and invariants live in [`docs/pipeline/`](../../docs/pipeline/) — that's the spec; this file is the agent's invocation contract.

> **Security note**: This dispatcher processes GitHub issue content as input. In public repositories, issue content is untrusted — anyone can create issues. Ensure the `autonomous` label can only be applied by trusted maintainers (use GitHub branch rulesets or organizational policies). The dispatcher only reads labels/comments and spawns local processes via the helper script — it does NOT modify source code or push to branches.

## What to do

When the cron fires (default: every 5 min), run:

```bash
bash "$PROJECT_DIR/scripts/dispatcher-tick.sh"
```

That's it. The script handles all 5 steps of one tick:

1. **Concurrency gate** — abort if `count(in-progress + reviewing) >= MAX_CONCURRENT`.
2. **scan-new** — find `autonomous`-only issues, check dependencies, dispatch dev-new.
3. **scan-pending-review** — find `pending-review` issues, dispatch review.
4. **scan-pending-dev** — find `pending-dev` issues, retry-counter check, dispatch dev-resume (or mark stalled if exhausted).
5. **stale detection** — for `in-progress` / `reviewing` issues, probe wrapper PID, branch on alive/dead and on PR/CI/idle gates.

The logic is in [`scripts/dispatcher-tick.sh`](scripts/dispatcher-tick.sh) and the helpers in [`scripts/lib-dispatch.sh`](scripts/lib-dispatch.sh). For the spec each step is implementing, see [`docs/pipeline/dispatcher-flow.md`](../../docs/pipeline/dispatcher-flow.md).

## GitHub Authentication — App token, not user token

All `gh` calls inside the dispatcher MUST use a GitHub App token, not the default user token. The wrappers (`autonomous-dev.sh`, `autonomous-review.sh`) handle their own auth via `lib-auth.sh`. The dispatcher itself runs in the OpenClaw cron session — generate the App token at the start of each tick using `scripts/gh-app-token.sh`:

```bash
source "${PROJECT_DIR}/scripts/gh-app-token.sh"
GH_TOKEN=$(get_gh_app_token "$DISPATCHER_APP_ID" "$DISPATCHER_APP_PEM" "$REPO_OWNER" "$REPO_NAME") || exit 1
[ -z "$GH_TOKEN" ] && { echo "FATAL: empty App token" >&2; exit 1; }
export GH_TOKEN
```

The token is valid for 1 hour and scoped to the target repo only. `dispatcher-tick.sh` typically completes in well under a minute, so a single token covers the whole tick.

## Local Dispatch Helper

`dispatcher-tick.sh` invokes `scripts/dispatch-local.sh` for each task type. **Do NOT spawn agent processes any other way.** The helper handles `nohup`, input validation (numeric issue numbers, safe session IDs), pre-creating log files at mode 0600 (agent output may contain secrets), and killing stale wrappers before spawning new ones (see [INV-09](../../docs/pipeline/invariants.md#inv-09-just_dispatched-skip-rule), `dispatch-local.sh::kill_stale_wrapper`).

| Type | Command |
|---|---|
| New dev task | `bash "$PROJECT_DIR/scripts/dispatch-local.sh" dev-new ISSUE_NUM` |
| Review task | `bash "$PROJECT_DIR/scripts/dispatch-local.sh" review ISSUE_NUM` |
| Resume dev task | `bash "$PROJECT_DIR/scripts/dispatch-local.sh" dev-resume ISSUE_NUM SESSION_ID` |

## What the dispatcher MUST NOT do

The dispatcher is a label-and-spawn coordinator, not a code-changer:

- MUST NOT commit or push to the target repository.
- MUST NOT modify source files in `$PROJECT_DIR`.
- MUST ONLY read issue labels/comments via the GitHub API, update labels via the GitHub API, and dispatch local processes via `dispatch-local.sh`.

Any code changes happen via the wrapper-spawned dev / review agents.

## Environment Variables

Loaded from `scripts/autonomous.conf` (sourced by `dispatcher-tick.sh` before `lib-dispatch.sh`):

- `REPO`: GitHub repo in `owner/repo` format (e.g., `myorg/myproject`)
- `REPO_OWNER`, `REPO_NAME`: split form of REPO (used for App token scoping)
- `PROJECT_ID`: project identifier for log/PID files (default: `project`)
- `PROJECT_DIR`: absolute path to the project root on the local machine
- `MAX_CONCURRENT`: max parallel tasks (default: `5`)
- `MAX_RETRIES`: max dev retry attempts before marking issue as `stalled` (default: `3`)
- `DISPATCHER_APP_ID`: GitHub App ID for the dispatcher bot
- `DISPATCHER_APP_PEM`: path to the GitHub App private key PEM file

## Cron Configuration (OpenClaw)

```bash
openclaw cron add \
  --name "Autonomous Dispatcher" \
  --cron "*/5 * * * *" \
  --session isolated \
  --message "Run the autonomous-dispatcher skill. Check GitHub issues and dispatch tasks." \
  --announce
```

## Label Definitions

| Label | Color | Description |
|-------|-------|-------------|
| `autonomous` | `#0E8A16` | Issue should be processed by autonomous pipeline |
| `in-progress` | `#FBCA04` | Agent is actively developing |
| `pending-review` | `#1D76DB` | Development complete, awaiting review |
| `reviewing` | `#5319E7` | Agent is actively reviewing |
| `pending-dev` | `#E99695` | Review failed, needs more development |
| `approved` | `#0E8A16` | Review passed. PR merged (or awaiting manual merge if `no-auto-close` present) |
| `no-auto-close` | `#d4c5f9` | Used with `autonomous` — skip auto-merge after review passes, requires manual approval |
| `stalled` | `#B60205` | Issue exceeded max retry attempts; requires manual investigation |

For the full state machine, see [`docs/pipeline/state-machine.md`](../../docs/pipeline/state-machine.md).

## Model Strategy

| Task | Model | Rationale |
|------|-------|-----------|
| Development (`autonomous-dev.sh`) | Opus (default) | Complex coding, architecture decisions |
| Review (`autonomous-review.sh`) | Sonnet (`--model sonnet`) | Checklist verification, avoids Opus quota contention |
