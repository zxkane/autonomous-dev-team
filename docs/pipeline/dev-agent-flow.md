# Dev-Agent Wrapper Flow

> **Status: scaffold.** This file is filled in by PR-2.

## Purpose

Describes the lifecycle of a single dev-agent invocation: from `dispatch-local.sh` spawning `autonomous-dev.sh`, through prompt construction and agent invocation, through the exit trap that updates issue labels.

## Outline (filled by PR-2)

1. **Spawn** — `dispatch-local.sh` kills any stale wrapper for this issue+type, then `nohup autonomous-dev.sh ...`. Why `kill_stale_wrapper` is at the dispatcher level, not in `acquire_pid_guard`.
2. **PID guard** — `acquire_pid_guard` writes `$$` to `/tmp/agent-${PROJECT_ID}-issue-${ISSUE_NUM}.pid`. Symlink-attack defense.
3. **Auth setup** — `setup_github_auth` (token vs app mode), `gh-token-refresh-daemon` lifecycle.
4. **Mode = new** — uuidgen session-id, build prompt with `<user-issue-content>` injection-defense tags, `run_agent`.
5. **Mode = resume** — fetch review feedback + PR inline comments, build resume prompt, `resume_agent`. Fallback to new-session on resume failure.
6. **Exit trap (`cleanup`)** — the contract:
   - PID file always cleaned up.
   - Skip label update if `AGENT_RAN=false`.
   - On exit 0: verify a PR exists. If yes → `pending-review`. If no → `pending-dev` (#40).
   - On exit ≠ 0: → `pending-dev`.
   - Post Agent Session Report comment with session-id, exit code, mode, log path.
7. **Path resolution** — `readlink -f` vs `BASH_SOURCE`, the symlink-vendor pattern (#58).

## Cross-references

- [`dispatcher-flow.md`](dispatcher-flow.md) — Step 4 dispatches dev-resume.
- [`handoffs.md`](handoffs.md) — wrapper-trap-vs-dispatcher race on label transitions.
- [`invariants.md`](invariants.md) — "crashed"-keyword contract; PID file naming; session report format.
