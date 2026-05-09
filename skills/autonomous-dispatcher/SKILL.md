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

When the cron fires (default: every 5 min), run **one** of:

**Single-project deployment** (one repo per dispatcher):

```bash
bash "$PROJECT_DIR/scripts/dispatcher-tick.sh"
```

**Multi-project deployment** (one cron, many repos — closes #62):

```bash
DISPATCHER_CONF="$HOME/.autonomous/dispatcher.conf" \
  bash "$PROJECT_DIR/scripts/dispatcher-multi-tick.sh"
```

The multi-tick wrapper iterates `PROJECTS=()` from `dispatcher.conf` and runs one `dispatcher-tick.sh` per project. Per-project failures are logged to stderr but do not stall other projects. See `scripts/dispatcher.conf.example` for the schema.

Each `PROJECTS[]` entry is one of two shapes:

- **Local project** (file path): a path to a per-project `autonomous.conf` on this dispatcher box. The dispatcher and the project source live on the same machine. The wrapper sources the conf via the `AUTONOMOUS_CONF` priority-1 path (PR-4 / [INV-14]).
- **Remote project** (inline metadata block): used when the project source lives on a remote dev box reached via AWS SSM. The dispatcher box does NOT have the project's `autonomous.conf` — everything the dispatcher needs to scan issues + dispatch is declared inline in `dispatcher.conf`. `EXECUTION_BACKEND=remote-aws-ssm` and `SSM_INSTANCE_ID` route the actual `dispatch-local.sh` invocation to the remote box via `aws ssm send-command`. (#62)

Either form runs the same 5-step tick:

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

## Dispatch Helpers

`dispatcher-tick.sh` calls a `dispatch()` helper for each task type, which routes to the configured execution backend. **Do NOT spawn agent processes any other way.** Each backend handles `nohup`, input validation, log-file mode 0600, and stale-wrapper kill ([INV-09](../../docs/pipeline/invariants.md#inv-09-just_dispatched-skip-rule)).

Backends today:

| `EXECUTION_BACKEND` | Driver | When to use |
|---|---|---|
| `local` (default, also when unset) | `scripts/dispatch-local.sh` | Wrapper runs on the same box as the dispatcher. |
| `remote-aws-ssm` | `scripts/dispatch-remote-aws-ssm.sh` | Wrapper runs on a remote dev EC2 reached via AWS Systems Manager. The dispatcher sends `aws ssm send-command` to invoke `dispatch-local.sh` on the remote box. |

Per-task command shapes (passed through both backends identically):

| Type | Command |
|---|---|
| New dev task | `dispatch dev-new ISSUE_NUM` |
| Review task | `dispatch review ISSUE_NUM` |
| Resume dev task | `dispatch dev-resume ISSUE_NUM SESSION_ID` |

## What the dispatcher MUST NOT do

The dispatcher is a label-and-spawn coordinator, not a code-changer:

- MUST NOT commit or push to the target repository.
- MUST NOT modify source files in `$PROJECT_DIR`.
- MUST ONLY read issue labels/comments via the GitHub API, update labels via the GitHub API, and dispatch wrapper processes via the configured backend (`dispatch-local.sh` or `dispatch-remote-aws-ssm.sh`).

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
