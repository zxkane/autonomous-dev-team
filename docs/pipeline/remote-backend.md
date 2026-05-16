# Execution-Backend Contract

The dispatcher's `EXECUTION_BACKEND` knob picks which **execution
backend** spawns the wrapper process and queries its liveness. Today
two backends ship: `local` (default) and `remote-aws-ssm`. This doc
defines the contract every backend must satisfy so future
implementations (remote SSH, remote HTTP, additional cloud providers)
can plug in without re-deriving the topology assumptions.

Authoritative spec — see also [`invariants.md`](invariants.md) [INV-30].

## Topology

```
                       GitHub API
                  (label / comment state —
                   the source of truth)
                          ▲
                          │
  ┌───────────────────────┴───────────────────────┐
  │                                               │
  │  Box A — DISPATCHER                           │
  │  ─────────────────                            │
  │  • cron tick driver                           │
  │  • dispatcher-tick.sh                         │
  │  • dispatch() router                          │
  │  • pid_alive() — calls liveness transport     │
  │  • posts dispatch tokens / hygiene comments   │
  │                                               │
  │       │ SPAWN transport (fire-and-forget)     │
  │       ▼                                       │
  │  ─────────────────                            │
  │  Box B — WRAPPER                              │
  │  • autonomous-{dev,review}.sh                 │
  │  • lib-agent.sh — runs claude / codex / …     │
  │  • PID file: ~/.local/state/autonomous-       │
  │    ${PROJECT_ID}/${kind}-${N}.pid             │
  │  • heartbeat sibling: same path %.heartbeat   │
  │  • install_agent_heartbeat refreshes mtime    │
  │       │                                       │
  │       │ LIVENESS transport (synchronous,      │
  │       │ tri-state, called per Step 5 tick)    │
  │       ▼                                       │
  └───────────────────────────────────────────────┘
```

Under `EXECUTION_BACKEND=local`, **Box A == Box B** (same machine, same
filesystem, same PID space). The legacy three-tier `pid_alive` works
because the dispatcher can stat the PID file directly.

Under any non-local backend, **Box A ≠ Box B**. The PID file and
heartbeat sibling live on Box B. The dispatcher MUST consult Box B via
the liveness transport before any local probe. Otherwise it would
always return DEAD on a healthy wrapper — the failure mode reproduced
on a downstream consumer's #182 (2026-05-16, see [INV-30]).

## Backend interface

Every backend implements **two transports** and (re)uses the shared
`lib-ssm.sh`-style helpers when applicable:

### 1. Spawn transport (fire-and-forget)

**File pattern**: `dispatch-${BACKEND}.sh`. Today: `dispatch-remote-aws-ssm.sh`.

**Inputs**: `<type> <issue_num> [session_id]` where `type ∈ {dev-new, dev-resume, review}`.

**Behavior**: deliver a request to Box B that spawns the wrapper there.
Spawning is Box B's responsibility; PID guard / `kill_stale_wrapper` /
heartbeat install all happen locally on Box B (the wrapper's existing
code path is unchanged).

**Exit codes**: `0` on successful delivery; `1` on input/env/transport
failure. Fire-and-forget: the dispatcher does not wait for completion.

### 2. Liveness transport (synchronous, tri-state)

**File pattern**: `liveness-check-${BACKEND}.sh`. Today: `liveness-check-remote-aws-ssm.sh`.

**Inputs**: `<kind> <issue_num>` where `kind ∈ {issue, review}` (matches `_pid_file_for`).

**Stdout contract**: exactly one of `ALIVE` / `DEAD` / empty.

**Exit codes**:
- `0` — definitive verdict (printed `ALIVE` or `DEAD`)
- `1` — input/env validation failure
- `2` — indeterminate: transport fault, timeout, parse error, instance
        offline, or remote shell returned anything other than ALIVE/DEAD.

**Hard rule**: the transport NEVER prints `DEAD` unless the remote
shell explicitly produced `DEAD` on a successful invocation. SSM
transport faults and ambiguous output are exit 2.

**Remote probe equivalence**: the remote shell snippet runs the
equivalent of [INV-29]'s three-tier check on Box B:

1. `kill -0 <pgid>` against the PID file content (PGID = setsid leader, [INV-23]).
2. `pgrep -g <pgid>` finding any descendant — catches the case where the session-leader PID drifts out of `kill -0` reachability under launcher indirection.
3. PID-file mtime within `HEARTBEAT_INTERVAL_SECONDS * 3`.
4. Heartbeat sibling mtime within the same threshold ([INV-29]).

Print `ALIVE` if any tier fires; print `DEAD` only when all four miss.

## `pid_alive` switching contract

`lib-dispatch.sh::pid_alive` MUST consult the liveness transport BEFORE
any local probe under each supported non-local backend. The actual
condition in code today opts in **only the backends with implementations
that have been reviewed and tested**, not every non-local value:

```bash
pid_alive() {
  local kind="$1" issue_num="$2"

  if [ "${EXECUTION_BACKEND:-local}" = "remote-aws-ssm" ] \
     && [ "${REMOTE_LIVENESS_CHECK_DISABLE:-false}" != "true" ]; then
    case "$(_remote_pid_alive_query "$kind" "$issue_num")" in
      ALIVE) return 0 ;;
      DEAD)  return 1 ;;
      *)     return 0 ;;  # indeterminate biases toward ALIVE
    esac
  fi
  # ... legacy three-tier check ...
}
```

Local-backend installations skip the remote path entirely; the legacy
three-tier check runs as before.

**Adding a new non-local backend**: extend the case-statement above to
match the new backend's name, OR refactor the condition into a
case-statement that whitelists every supported backend explicitly. Do
NOT relax the condition to `!= "local"` blindly — a future backend
without its own liveness transport would fall through to the legacy
three-tier check and re-introduce the #182 false-DEAD bug under that
backend. The whitelist is the safer default.

## Failure-mode policy: indeterminate biases toward ALIVE

**Rule**: when the liveness transport returns rc≠0 or stdout is neither
ALIVE nor DEAD, `pid_alive` returns 0 (ALIVE). The caller defers crash
declaration by one tick; the next tick retries. This is the
conservative-bias decision recorded in [INV-30].

**Operator visibility**: a per-process counter `_REMOTE_LIVENESS_DEGRADED_COUNT`
records consecutive indeterminate verdicts. The lib emits a stderr WARN
on the 1st indeterminate tick AND every 10th thereafter (counts 1, 10,
20, 30, …) so operators see the degraded transport without per-tick
log spam.

**Why this trade-off**: two error directions are possible when the
transport can't give a definitive verdict.
- Treat unknown as DEAD → false crash comments + premature stall (the
  bug being fixed). Recovery requires manual `gh issue edit --remove-label stalled`.
- Treat unknown as ALIVE → real crashes get delayed detection by 1+
  ticks until the transport recovers. Recovery is automatic on the
  next successful tick.

The latter is recoverable; the former is not. INV-30 chooses the
recoverable failure mode.

## Configuration knobs

Common to all backends:

| Knob | Default | Purpose |
|---|---|---|
| `EXECUTION_BACKEND` | `local` | `local` \| `remote-aws-ssm` \| `<future>` |
| `REMOTE_LIVENESS_CHECK_DISABLE` | `false` | `true` falls back to legacy local-only `pid_alive` (operator escape hatch for transport-blocked deployments) |
| `REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS` | `8` | Dispatcher-side bound on synchronous polling (`lib-ssm.sh::_ssm_run_remote_command` honors this) |
| `SSM_COMMAND_TIMEOUT_SECONDS` | `10` | SSM-side cap (`aws ssm send-command --timeout-seconds`) so a hung remote shell can't tie up an SSM slot for the default 600s |
| `HEARTBEAT_INTERVAL_SECONDS` | `120` | Wrapper-side heartbeat cadence; threshold = `× 3 = 360s` (consumed remote-side in the liveness snippet) |

`remote-aws-ssm`-specific (mirrors `dispatch-remote-aws-ssm.sh`):

| Knob | Required | Purpose |
|---|---|---|
| `SSM_INSTANCE_ID` | yes | EC2 instance ID hosting the wrapper |
| `SSM_REMOTE_PROJECT_DIR` | yes | Absolute path to the project root on Box B |
| `SSM_REMOTE_PROJECT_ID` | yes | Project id used in the PID-file path |
| `SSM_REGION` | no (`ap-southeast-1`) | AWS region |
| `SSM_REMOTE_USER` | no (`ubuntu`) | sudo target on Box B |
| `SSM_REMOTE_SHELL` | no (`bash`) | login shell on Box B |
| `SSM_REMOTE_PROFILE` | no (none) | optional profile to source before the inner cmd |

## Update-ordering for split-box deployments

Dispatcher-side and wrapper-side skill copies CAN be refreshed
independently because they only share the on-disk PID-file path schema
(`${XDG_RUNTIME_DIR:-$HOME/.local/state}/autonomous-${PROJECT_ID}/${kind}-${N}.pid`),
stable since [INV-29].

- **New dispatcher + old wrapper**: the remote liveness snippet still
  finds the PID file at the expected path; verdict accurate.
- **New wrapper + old dispatcher**: the old `pid_alive` falls through
  to legacy three-tier and (under remote backend) misses as before
  this PR — no regression vs status quo.

This means an operator can ship the dispatcher fix to Box A
independently of refreshing wrapper-side skills on each Box B host,
which matters for OpenClaw-style deployments where the dispatcher's
upgrade channel is separate from the wrapper-host's.

## Cross-references

- [`invariants.md::INV-23`](invariants.md#inv-23-pid_file-points-at-a-process-whose-death-reaps-the-entire-agent-subtree) — PID_FILE / setsid PGID semantics.
- [`invariants.md::INV-26`](invariants.md#inv-26-stall-decision-excludes-dispatcher-induced-terminations-and-defers-on-live-wrappers) — `mark_stalled` defers when `pid_alive` returns ALIVE; inherits remote awareness automatically.
- [`invariants.md::INV-27`](invariants.md#inv-27-dev-wrapper-dead-detection-requires-both-pid_alive-miss-and-no-near-success-in-flight-signal) — dev-side near-success cross-check; runs after the remote `pid_alive` verdict.
- [`invariants.md::INV-28`](invariants.md#inv-28-pgrep-fallback-must-be-scoped-by-project-and-wrapper-type) — `kill_stale_wrapper` scope; runs on Box B unchanged.
- [`invariants.md::INV-29`](invariants.md#inv-29-pid_alive-heartbeat-is-owned-exclusively-by-the-wrapper-not-by-the-pid-file-alone) — heartbeat sibling lifecycle; the remote snippet replicates this check.
- [`invariants.md::INV-30`](invariants.md#inv-30-pid_alive-is-authoritative-under-all-execution-backends) — the rule this contract enforces.
- [`dispatcher-flow.md`](dispatcher-flow.md) — Step 5 / `mark_stalled` flow; both inherit remote awareness through the unified `pid_alive` interface.

## Adding a new backend

1. Define `EXECUTION_BACKEND=<your-name>` and document the required env in this file.
2. Implement `dispatch-<your-name>.sh` (spawn) and `liveness-check-<your-name>.sh` (liveness) following the contracts above.
3. Add a `case` arm to `dispatcher-tick.sh::dispatch` to invoke the spawn transport.
4. Add a `case` arm or refactor the existing condition to invoke your liveness transport from `_remote_pid_alive_query`.
5. Add unit tests mirroring `test-liveness-check-remote-aws-ssm.sh` and `test-pid-alive-remote-aws-ssm.sh`.
6. Update [INV-30]'s rule to mention the new backend.
