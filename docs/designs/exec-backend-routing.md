# Design Canvas — Pluggable Execution Backend (PR-9)

**Branch**: `feat/exec-backend-routing`
**Closes**: #62 (axis 2 — final axis after PR-8 covered axes 1+3).
**Pipeline-docs touched**: `docs/pipeline/dispatcher-flow.md` (routing layer + remote-DEAD-branch caveat).

---

## Deployment topology

```
┌──────────────────────────────────────────────────────────────────────────┐
│  dispatcher box (one machine, one cron)                                  │
│                                                                          │
│  $HOME/.autonomous/dispatcher.conf  declares all projects:               │
│    - some are LOCAL  (autonomous.conf path on disk here)                 │
│    - some are REMOTE (inline metadata + SSM_INSTANCE_ID)                 │
│                                                                          │
│  cron tick → dispatcher-multi-tick.sh                                    │
│    │                                                                     │
│    ├─→ tick(local-project)   sources autonomous.conf, calls              │
│    │                          dispatch-local.sh on this box              │
│    │                                                                     │
│    ├─→ tick(remote-project)  loads inline metadata, calls                │
│    │                          dispatch-remote-aws-ssm.sh ───────┐        │
│    │                                                            │        │
│    └─→ tick(another-remote)  loads inline metadata, calls       │        │
│                               dispatch-remote-aws-ssm.sh ──┐    │        │
└────────────────────────────────────────────────────────────┼────┼────────┘
                                                             │    │
              aws ssm send-command (fire-and-forget per task)│    │
                                                             ▼    ▼
                                              ┌──────────────────────┐
                                              │ remote dev box       │
                                              │ (per-project EC2)    │
                                              │                      │
                                              │ has its own copy of  │
                                              │ PROJECT_DIR/scripts/ │
                                              │   autonomous.conf    │
                                              │                      │
                                              │ runs dispatch-       │
                                              │   local.sh + the     │
                                              │   wrapper + the      │
                                              │   agent CLI          │
                                              └──────────────────────┘
```

Critical fact: **the dispatcher box does NOT have any per-project `autonomous.conf` for remote projects.** It only knows what `dispatcher.conf` tells it (REPO, SSM_INSTANCE_ID, etc). The remote dev box has its own `autonomous.conf` that's used by the wrapper after SSM kicks off `dispatch-local.sh`.

This is why PR-8's "every project has an autonomous.conf path" pattern doesn't fit — that pattern assumes co-location of dispatcher and project source. Real deployment is mixed.

## What dispatcher needs to know per project

The dispatcher's per-project tick uses `lib-dispatch.sh` to:

- list issues with the right labels (`gh issue list --repo "$REPO"`)
- fetch PR state (`gh pr list --repo "$REPO"`)
- update labels (`gh issue edit --repo "$REPO"`)
- comment on issues (`gh issue comment --repo "$REPO"`)
- check process liveness (PID file at known path, `kill -0`)
- spawn dev/review wrappers (via the dispatch backend)

The variables `lib-dispatch.sh` reads via `: "${VAR:?...}"`:

- `REPO`, `REPO_OWNER`, `PROJECT_ID`
- `MAX_RETRIES` (default 3), `MAX_CONCURRENT` (default 5)

Plus the GitHub App auth (read by the cron prompt before sourcing lib-dispatch):

- `DISPATCHER_APP_ID`, `DISPATCHER_APP_PEM` (when GH_AUTH_MODE=app)

Everything else (`PROJECT_DIR`, `AGENT_CMD`, `AGENT_TIMEOUT`, etc.) is consumed by the wrapper, which reads its OWN local `autonomous.conf` after SSM puts it on the right box.

## Schema: dispatcher.conf

Two flavors of project entry coexist in the same `PROJECTS` array:

```bash
# dispatcher.conf

# Mix and match:
PROJECTS=()

# === LOCAL project: traditional path (PR-8 backwards compat) ===
# Format: a string ending in "autonomous.conf" — multi-tick treats as a
# file path and sources it. The autonomous.conf provides REPO etc.
PROJECTS+=( "/data/git/myrepo-local/scripts/autonomous.conf" )

# === REMOTE project: inline metadata block ===
# Format: a multi-line string of bash assignments. Multi-tick detects the
# newline + bash-statement shape and eval's it inside a subshell.
# REPO and PROJECT_ID are required; everything else has defaults.
PROJECTS+=( '
PROJECT_ID=projB
REPO=myorg/projB                 # REPO_OWNER + REPO_NAME auto-derived
EXECUTION_BACKEND=remote-aws-ssm
SSM_INSTANCE_ID=i-0abc1234567890def
SSM_REGION=ap-southeast-1
SSM_REMOTE_USER=ubuntu
SSM_REMOTE_SHELL=bash
SSM_REMOTE_PROFILE=
SSM_REMOTE_PROJECT_DIR=/data/git/projB
SSM_REMOTE_PROJECT_ID=projB
DISPATCHER_APP_ID=3013418
DISPATCHER_APP_PEM=/data/auth/projB.pem
GH_AUTH_MODE=app
' )

PROJECTS+=( '
PROJECT_ID=projC
REPO=myorg/projC                 # REPO_OWNER + REPO_NAME auto-derived
EXECUTION_BACKEND=remote-aws-ssm
SSM_INSTANCE_ID=i-0def4567890abc123
SSM_REMOTE_PROJECT_DIR=/data/git/projC
SSM_REMOTE_PROJECT_ID=projC
DISPATCHER_APP_ID=3013418
DISPATCHER_APP_PEM=/data/auth/projC.pem
' )
```

### Why a multi-line string and not a sub-array

Bash arrays don't nest. A multi-line string is the closest readable approximation. The conf file remains a single bash file (no separate sidecar conf files to track) — operators add a new project by appending one block.

### Detection rule

`dispatcher-multi-tick.sh` decides per element:

- contains a `/` and exists as a regular file → **local**: `source "$entry"`
- otherwise → **remote**: treat as inline bash, validate, then `eval` inside the per-project subshell

### REPO_OWNER / REPO_NAME auto-derivation

`lib-dispatch.sh` requires `REPO`, `REPO_OWNER`, and `REPO_NAME` separately (App-token scoping reads owner+name independently). In the local-project case, the operator's own `autonomous.conf` declares all three (matches PR-8 / `autonomous.conf.example`).

In the remote-project inline-metadata case, the operator only writes `REPO=owner/name` — the multi-tick wrapper auto-derives the missing two before invoking `dispatcher-tick.sh`:

```bash
: "${REPO_OWNER:=${REPO%%/*}}"
: "${REPO_NAME:=${REPO##*/}}"
```

This trims one common copy-paste error (rename in only one of three places). Local entries keep the historical "write all three" pattern unchanged for backwards compat.

## Routing in dispatcher-tick.sh

After `load_autonomous_conf` returns (or after the multi-tick wrapper has sourced/eval'd the project's metadata into the subshell env), `dispatcher-tick.sh` defines a thin `dispatch()` helper:

```bash
dispatch() {
  case "${EXECUTION_BACKEND:-local}" in
    local)
      bash "$PROJECT_DIR/scripts/dispatch-local.sh" "$@"
      ;;
    remote-aws-ssm)
      bash "$SCRIPT_DIR/dispatch-remote-aws-ssm.sh" "$@"
      ;;
    *)
      log "  ERROR: unknown EXECUTION_BACKEND='$EXECUTION_BACKEND' — skipping"
      return 1
      ;;
  esac
}
```

Steps 2/3/4 each replace their inline `bash "$PROJECT_DIR/scripts/dispatch-local.sh" ...` with `dispatch ...`. **`dispatch-local.sh` location and behavior unchanged** — backwards compat.

## dispatcher-multi-tick.sh changes

Two changes to the existing PR-8 multi-tick wrapper:

1. **Iteration shape**: each `PROJECTS[i]` is now either a path or an inline bash block. The loop body decides per element:

   ```bash
   for entry in "${PROJECTS[@]}"; do
     if [[ "$entry" == *"/"* && -f "$entry" ]]; then
       # local project: PR-8 behavior, set AUTONOMOUS_CONF env override
       ( AUTONOMOUS_CONF="$entry" bash "$SCRIPT_DIR/dispatcher-tick.sh" )
     else
       # remote project: validate and eval inline metadata in subshell
       _dispatch_remote_project "$entry"
     fi
   done
   ```

2. **Inline-block validator**: before `eval`, check the block contains only `KEY=VALUE` lines (allow comments, allow blank lines). Reject anything that looks like a command. This isn't sandbox-grade — `dispatcher.conf` is already trusted by PR-8's trust gate — but it catches accidental injection of shell commands by an operator who copy-pasted poorly.

3. **Required-field check**: after eval, assert `REPO` and `PROJECT_ID` are set; warn-and-skip otherwise (don't blow up the whole loop for one bad entry).

The trust gate from PR-8 (refuses g+w / o+w `dispatcher.conf` parent dir) extends naturally — the same source of truth. No new trust check needed.

## dispatch-remote-aws-ssm.sh

Derived from the user's existing private implementation. Generalizations for upstream:

| Original | Upstream | Why |
|---|---|---|
| `PROJECT_DIR="${DISPATCH_PROJECT_DIR:-/data/git/VidSyllabus}"` | required (no default) | Don't bake private repo path |
| `PROJECT_ID="${DISPATCH_PROJECT_ID:-vidsyllabus}"` | required (no default) | Same |
| `sudo -u ubuntu zsh -li -c '<cmd>'` | `sudo -u ${SSM_REMOTE_USER:-ubuntu} ${SSM_REMOTE_SHELL:-bash} -l -c '<cmd>'` | Per-project shell choice |
| `source /home/ubuntu/.bash_aliases; <cmd>` | If `SSM_REMOTE_PROFILE` non-empty: prepend `source $SSM_REMOTE_PROFILE; ` | Optional |

The `dispatch-remote-aws-ssm.sh` reads its inputs from the env exported by the dispatcher tick:

- `SSM_REMOTE_PROJECT_DIR` — absolute path on the remote box where the project lives
- `SSM_REMOTE_PROJECT_ID` — project id used in the remote PID/log path
- `SSM_INSTANCE_ID` — EC2 instance ID
- `SSM_REGION` — default `ap-southeast-1`
- `SSM_REMOTE_USER` (default `ubuntu`)
- `SSM_REMOTE_SHELL` (default `bash`)
- `SSM_REMOTE_PROFILE` (default empty, no profile load)

It builds the remote command:

```bash
INNER_CMD="${SSM_REMOTE_PROFILE:+source $SSM_REMOTE_PROFILE;} \
  PROJECT_DIR=$SSM_REMOTE_PROJECT_DIR PROJECT_ID=$SSM_REMOTE_PROJECT_ID \
  bash $SSM_REMOTE_PROJECT_DIR/scripts/dispatch-local.sh dev-new $ISSUE_NUM"

FULL_CMD="sudo -u $SSM_REMOTE_USER $SSM_REMOTE_SHELL -l -c '$INNER_CMD'"

# JSON-safe via jq --arg (no shell-injection regression)
COMMANDS_JSON=$(jq -n --arg cmd "$FULL_CMD" '[$cmd]')

aws ssm send-command \
  --instance-ids "$SSM_INSTANCE_ID" \
  --document-name "AWS-RunShellScript" \
  --region "${SSM_REGION:-ap-southeast-1}" \
  --parameters "{\"commands\": $COMMANDS_JSON}"
```

`set -euo pipefail` + dependency check (`aws`, `jq`) + input validation (issue/session/project ids) preserved verbatim from the seed.

## PID file: dispatcher-side `kill -0` is always false (remote case)

Hard architectural fact: `lib-dispatch.sh::pid_alive` does `kill -0 $(cat $PID_FILE)` against `${XDG_RUNTIME_DIR}/autonomous-${PROJECT_ID}/issue-N.pid` (PR-7 path). For a remote project, the PID file is on the remote dev box, not on the dispatcher box. The dispatcher's `kill -0` always fails → the dispatcher always sees DEAD.

Effects on Step 5 (stale detection):

- **Step 5a (ALIVE + PR ready, idle 5min, CI green) is unreachable** for remote projects — the dispatcher never sees ALIVE. Remote projects lose the proactive "SIGTERM when PR-ready" optimization. Review delay grows from "next tick after CI passes" to "next tick after the wrapper exits naturally." In practice this is ~the same — by the time CI passes the wrapper is mostly done — but the difference is observable for long auxiliary work.
- **Step 5b DEAD-branch is the *only* path** for remote tasks. Each tick treats all active remote issues as DEAD. Step 5b reads PR state and decides:
  - DEAD + new commits since last review → `pending-review` (correct)
  - DEAD + no new commits → `pending-dev` (correct)
  - DEAD + no PR → `pending-dev` (correct)
- **Wrapper-side wall-clock timeout (PR-6, default 4h) bounds the worst case**.

This is acceptable. Adding a real remote-alive check (per-tick `aws ssm send-command kill -0 $PID`) would 2-3x the SSM call volume and add latency; not worth doing speculatively.

The DEAD-branch correctness depends only on labeled-state-plus-PR-state ([INV-04], [INV-06], [INV-07]) — none of those need an accurate `pid_alive`.

## Backwards compat

- `dispatcher-tick.sh` standalone (no multi-tick wrapper, no `EXECUTION_BACKEND`) → identical to today's behavior. Existing single-machine deployments need zero changes.
- PR-8's local-project entry shape (path string ending in `autonomous.conf`) keeps working in `dispatcher-multi-tick.sh`.
- `dispatch-local.sh` byte-identical.

## Tests

`tests/unit/test-dispatch-remote-aws-ssm.sh`:

1. Required env validation: `SSM_INSTANCE_ID` / `SSM_REMOTE_PROJECT_DIR` / `SSM_REMOTE_PROJECT_ID` missing → rc=1 with diagnostic.
2. Input validation: bad issue / session / project ids → rc=1.
3. `SSM_REMOTE_PROFILE` empty → no `source` prefix; non-empty → prefix added.
4. Constructed `INNER_CMD` shape verified by stubbing `aws` and capturing argv.
5. Stubbed `aws` returns failure → script propagates rc=1.
6. Source-of-truth grep: `jq -n --arg cmd` (not literal interpolation) — guards shell-injection.
7. `SSM_REMOTE_USER` / `SSM_REMOTE_SHELL` defaults work; overrides honored.

`tests/unit/test-dispatcher-tick-router.sh`:

1. `EXECUTION_BACKEND=local` (or unset) → calls `dispatch-local.sh`.
2. `EXECUTION_BACKEND=remote-aws-ssm` → calls `dispatch-remote-aws-ssm.sh`.
3. `EXECUTION_BACKEND=bogus` → log diagnostic + return 1 (no spawn).
4. Source-of-truth: tick script defines `dispatch()` and step bodies use it (not direct `bash dispatch-local.sh`).

`tests/unit/test-multi-tick-inline-projects.sh`:

1. PROJECTS array with mix of file path + inline block: each handled correctly.
2. Inline block missing REPO → warn-and-skip; sibling projects still tick.
3. Inline block contains a non-assignment line (`rm -rf /`) → rejected before eval.
4. Inline block correctly populates `EXECUTION_BACKEND` etc. for the subshell.

## What's explicitly out of scope

- Per-tick remote `kill -0` over SSM. Add later only if DEAD-branch turns out to mishandle something in production.
- Other remote backends (`remote-k8s`, `remote-gha-runner`). The router pattern accepts them with no schema changes.
- Renaming `dispatch-local.sh` or moving things — keep the existing layout for zero migration burden.
- Cross-project shared concurrency cap. Per-project remains the model.

## Files touched

New:
- `skills/autonomous-dispatcher/scripts/dispatch-remote-aws-ssm.sh`
- `tests/unit/test-dispatch-remote-aws-ssm.sh`
- `tests/unit/test-dispatcher-tick-router.sh`
- `tests/unit/test-multi-tick-inline-projects.sh`
- `docs/designs/exec-backend-routing.md` (this file)
- `docs/test-cases/exec-backend-routing.md`

Modified:
- `skills/autonomous-dispatcher/scripts/dispatcher-tick.sh` (3 callsites → `dispatch` helper)
- `skills/autonomous-dispatcher/scripts/dispatcher-multi-tick.sh` (inline-block detection + eval path)
- `skills/autonomous-dispatcher/scripts/dispatcher.conf.example` (mixed local + remote example)
- `skills/autonomous-dispatcher/SKILL.md` (backend selection + remote topology note)
- `docs/pipeline/dispatcher-flow.md` (routing layer + DEAD-branch caveat for remote)
