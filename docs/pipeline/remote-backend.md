# Execution-Backend Contract

The dispatcher's `EXECUTION_BACKEND` knob picks which **execution
backend** spawns the wrapper process and queries its liveness. Today
two backends ship: `local` (default) and `remote-aws-ssm`. This doc
defines the contract every backend must satisfy so future
implementations (remote SSH, remote HTTP, additional cloud providers)
can plug in without re-deriving the topology assumptions.

Authoritative spec — see also [`invariants.md`](invariants.md) [INV-30] (liveness) and [INV-101] (terminal-state detection).

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

Every backend implements **three transports** and (re)uses the shared
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

### 3. Terminal-state probe transport (synchronous, probe + truncate)

**File pattern**: `session-log-probe-${BACKEND}.sh`. Today: `session-log-probe-remote-aws-ssm.sh`.

**Inputs**: `<--probe|--truncate> <issue_num>`.

**Behavior**: read (or reset) the dev wrapper's per-issue log — the SAME
log the local `is_session_completed` path reads at
`/tmp/agent-${PROJECT_ID}-issue-${N}.log` — but ON Box B, keyed by
`SSM_REMOTE_PROJECT_ID` (which may differ from the dispatcher's own
`PROJECT_ID`; see [Configuration knobs](#configuration-knobs) below).

**`--probe` stdout contract**:
- line 1: the last `{"type":"result",...}` line from the remote log, or
  empty if the log is absent/unreadable/has no such line.
- line 2 (only present when line 1 is non-empty): the remote log's mtime
  as a Unix epoch — the controller can't `stat` a path on Box B, so the
  epoch is fetched over the same transport and converted to ISO-8601
  caller-side (`_epoch_to_iso`).

**`--truncate` stdout**: empty. Success is exit 0.

**Exit codes**:
- `0` — definitive result. For `--probe`, this INCLUDES "nothing found"
  (log absent, no result line yet) — that is a normal, non-error state,
  not a transport failure.
- `1` — input/env validation failure.
- `2` — indeterminate: transport fault, timeout, or parse error.

**Hard rule (asymmetric with the liveness transport)**: on `--probe`
indeterminate (`rc=2`), the CALLER (`is_session_completed`, via
`_remote_session_log_probe`) treats it identically to "nothing found" —
returns "not completed." This is the OPPOSITE bias direction from the
liveness transport's indeterminate→ALIVE rule (see [Failure-mode
policy](#failure-mode-policy-indeterminate-biases-toward-alive) below):
deferring a crash declaration is the safe default for liveness, but
fabricating a completed/terminal-state verdict from missing data is
NEVER safe here — it could misroute a still-live or freshly-crashed
session through the wrong branch of the INV-35/INV-85/INV-92 verdict
table. On `--truncate` indeterminate, the caller (`_reset_session_log`)
treats it as a truncate FAILURE — same fail-closed skip-dispatch
behavior as a local write error.

**Why a truncate mode, not just probe**: once a remote session becomes
detectable as `completed`/`prompt_too_long`, the two existing
recovery-truncate call sites become reachable for remote projects for
the first time. A bare controller-local `: > <path>` at either site
would create/truncate the WRONG file (Box B's real log keeps its stale
result line), and the next tick's probe would re-detect the same stale
line — turning a park into an infinite `dev-new` loop. `--truncate`
resets the log on Box B, the same host `--probe` read it from.

### 4. Agent-progress snapshot + compare-and-signal transport ([INV-137], #485)

**File pattern**: `agent-progress-snapshot-${BACKEND}.sh`. Today: `agent-progress-snapshot-remote-aws-ssm.sh`.

**Behavior**: Step 5a's SIGTERM decision needs the SAME current-run
agent-progress lease ([INV-135]'s `issue-<N>.progress.json` /
`issue-<N>.run-id`) the local backend reads directly — but under
`remote-aws-ssm` those sidecars live on Box B, and the freshness
computation must happen there too: the controller must NEVER compute
remote age from its OWN clock (a clock-skew or transport-latency
artifact would then leak into the FRESH/STALE decision). This transport
has TWO modes, both running the identical snapshot-classification logic
entirely on Box B:

**`--snapshot <issue_num>` stdout contract** (exactly one line):
- `{"state":"FRESH","age":N,"pid":N,"run_id":"..."}` or `{"state":"STALE","age":N,"pid":N,"run_id":"..."}`
- `{"state":"UNKNOWN","reason":"<token>"}` — `reason` is diagnostic-only.

**`--compare-and-signal <issue_num> <expected_pid> <expected_run_id>` stdout contract** (exactly one line):
- `SIGNALED` — the remote shell re-ran the snapshot classification, confirmed it STILL reports `STALE` with the SAME `pid`/`run_id` the caller expects, AND sent `kill -TERM` to that pid — all inside ONE remote invocation, so there is no gap between the recheck and the signal for a race to land in.
- `ABORTED:<reason>` — the recheck found a mismatch (not stale / pid changed / run_id changed / the kill itself failed); no signal was sent.

**Exit codes** (both modes):
- `0` — definitive result printed (including a printed UNKNOWN/ABORTED — that is NOT a transport error).
- `1` — input/env validation failure.
- `2` — indeterminate: SSM transport fault, timeout, or a remote reply that isn't valid single-line JSON matching one of the known shapes.

**Hard rule**: on `--snapshot` indeterminate (`rc=2`), the caller
(`_remote_dev_progress_snapshot_query`, `lib-dispatch.sh`) treats it
identically to `UNKNOWN` — NEVER fabricates STALE from a transport
fault, mirroring the terminal-state probe's fail-closed direction (never
the liveness transport's ALIVE-biasing direction: fabricating progress
that didn't happen is exactly the false-SIGTERM bug this feature
closes). On `--compare-and-signal` indeterminate, the caller
(`_remote_dev_progress_compare_and_signal`) treats it identically to
`ABORTED:remote-transport-failure` — never assumes the signal was sent.

**Why the recheck and the signal are ONE remote call, not two**: a
separate "recheck" SSM round-trip followed by a separate "kill" SSM
round-trip would reopen exactly the race the final pre-kill recheck
exists to close — the wrapper could legitimately resume progress in the
gap between the two round-trips, and the second call would kill it
anyway. Folding both into a single remote shell invocation closes that
window entirely.

**Poll-timeout recovery, not a bare timeout-as-no-op (shared `lib-ssm.sh::_ssm_run_remote_command`)**:
`REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS` (default 8) is shorter than
`SSM_COMMAND_TIMEOUT_SECONDS` (default 30) — the dispatcher-side poll
loop can hit its deadline while the remote command is still executing.
For a read-only `--snapshot` that only costs a wasted tick, but a
bare "poll timed out ⇒ rc=2" would be UNSAFE for `--compare-and-signal`:
the remote script can still reach its `kill -TERM` line and succeed
*after* the caller has already been told "indeterminate," leaving the
wrapper actually killed with no handoff comment and no label
transition. On poll-loop timeout the helper now (1) best-effort issues
`aws ssm cancel-command` for the in-flight command — for a still-running
`AWS-RunShellScript` invocation this stops the remote script before an
unreached `kill -TERM` line executes (it cannot retroactively undo a
signal already sent; that residual race is accepted, same fail-safe
posture as [INV-137]'s other documented residuals) — then (2) POLLS
`get-command-invocation`, giving up only once
`cmd_sent_at + cmd_timeout + exec_timeout + REMOTE_POLL_TIMEOUT_RECOVER_SECONDS`
(margin default 5) has elapsed, rather than accepting one immediate
check or an independent short window.

**Round-3 review finding #1's root cause and fix**: `--timeout-seconds` on
`send-command` only bounds *delivery* — the AWS API reference's own
wording is "if this time is reached and the command hasn't already
started running, it won't run" — it does **not** bound execution time
once the command has started. The actual execution-time bound is the
`AWS-RunShellScript` document's own `executionTimeout` parameter, which
defaults to 3600s (1 hour) when left unset, as it always was here before
this fix. That means a prior revision's independent short recovery window
(a fixed `REMOTE_POLL_TIMEOUT_RECOVER_SECONDS` after the cancel, with no
relationship to how long the command could actually still run) had no
real backstop: a "still InProgress" command was never actually guaranteed
to reach a terminal state within that window — it could legitimately run,
and reach its `kill -TERM` line, up to an hour later, with the dispatcher
having already reported ABORTED. The fix is two parts: (a)
`_ssm_run_remote_command` now explicitly passes
`executionTimeout=$cmd_timeout` (clamped to the document's own 1–172800
valid range) in `--parameters`, so the document's real execution bound
matches `SSM_COMMAND_TIMEOUT_SECONDS`; (b) `_ssm_poll_timeout_recover`'s
deadline is anchored to `cmd_sent_at + exec_timeout + margin` instead of
an independent short window, so giving up can no longer happen before
AWS's own enforcement guarantees the command is terminal. `cancel-command`
only REQUESTS the stop; it does not confirm it synchronously, so a single
check taken right after issuing it can still observe a stale
`InProgress`/`Pending` status even though the command is moments from a
terminal state either way (`Cancelled` if the stop won the race, or
`Success`/`Failed` if the command finished first) — the `margin` (default
5s) absorbs that plus poll granularity. Only after the anchored deadline
elapses with no terminal status observed does the helper return `rc=2` —
which the caller (`_remote_dev_progress_compare_and_signal`) still,
correctly, treats identically to `ABORTED:remote-transport-failure`; by
construction that `rc=2` now only ever means "could not read the
outcome," never "gave up while the command might still be running."

**Round-4 review finding #1's root cause and fix**: round-3's recovery
deadline (`cmd_sent_at + exec_timeout + margin`) omitted `cmd_timeout` —
send-command's own `--timeout-seconds`, which bounds only DELIVERY: how
long the command may sit `Pending`/`Delayed` before it starts running at
all. `exec_timeout` (the document's `executionTimeout`) only starts
counting once the command actually starts. A command that sits at the
delivery deadline before starting, then runs for the full `exec_timeout`,
is not guaranteed terminal until `cmd_sent_at + cmd_timeout +
exec_timeout` — the round-3 anchor could still give up while such a
late-starting command was capable of reaching its `kill -TERM` line. The
fix adds `cmd_timeout` into the deadline sum: `_ssm_poll_timeout_recover`
now takes `cmd_timeout` as an explicit parameter (alongside `cmd_sent_at`
and `exec_timeout`) and anchors to
`cmd_sent_at + cmd_timeout + exec_timeout + margin`, so giving up can no
longer happen before BOTH of AWS's own enforcement windows (delivery,
then execution) guarantee the command is terminal.

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

## `is_session_completed` switching contract ([INV-101], #356)

`lib-dispatch.sh::is_session_completed` MUST consult the terminal-state
probe transport BEFORE reading any local file path, under the same
backend whitelist as `pid_alive` above:

```bash
is_session_completed() {
  local issue_num="$1" reason_var="${2:-}" end_ts_var="${3:-}"
  # ... dev-side CLI gate unchanged ([INV-37]) ...

  local last_line log_file _end_epoch=""
  if [ "${EXECUTION_BACKEND:-local}" = "remote-aws-ssm" ]; then
    local _probe_out
    _probe_out=$(_remote_session_log_probe "$issue_num")
    last_line=$(printf '%s\n' "$_probe_out" | sed -n '1p')
    _end_epoch=$(printf '%s\n' "$_probe_out" | sed -n '2p')
  else
    log_file="/tmp/agent-${PROJECT_ID}-issue-${issue_num}.log"
    [ -r "$log_file" ] || return 1
    last_line=$(grep '^{"type":"result"' "$log_file" 2>/dev/null | tail -1)
  fi
  [ -n "$last_line" ] || return 1
  # ... jq parse of stop_reason/terminal_reason is backend-neutral ...
}
```

`_reset_session_log` (the truncate-side counterpart, consumed by both
recovery-truncate call sites) follows the identical branch shape,
routing to `session-log-probe-${BACKEND}.sh --truncate` under the
remote backend and a bare local truncate otherwise.

Local-backend installations skip the remote path entirely; the local
branch is byte-for-byte the pre-#356 implementation.

**Adding a new non-local backend**: implement
`session-log-probe-<your-name>.sh` per the [terminal-state probe
transport](#3-terminal-state-probe-transport-synchronous-probe-truncate)
contract above, then extend the `EXECUTION_BACKEND` equality check
inside BOTH `_remote_session_log_probe` and `_reset_session_log`
(`lib-dispatch.sh`) to also match the new backend's name — today each is
a single `if [ "${EXECUTION_BACKEND:-local}" = "remote-aws-ssm" ]`, not
a `case`; a second backend name means widening that one `if` (or an
`||` of both names) at BOTH call sites, since they don't share a
dispatch table. Same whitelist-not-blanket rule as `pid_alive`: relaxing
either condition to `!= "local"` would fall through to a local file read
that always misses under the new backend, silently disabling [INV-98] /
[INV-12] PTL recovery for it (the exact #356 bug, on a different
backend).

## `dev_progress_snapshot` switching contract ([INV-137], #485)

`dispatcher-tick.sh`'s Step 5a MUST consult the remote agent-progress
transport under `EXECUTION_BACKEND=remote-aws-ssm`, mirroring the shape
of the two switching contracts above:

```bash
# Initial snapshot (Step 5a's STALE/FRESH/UNKNOWN gate):
if [ "${EXECUTION_BACKEND:-local}" = "remote-aws-ssm" ]; then
  snapshot=$(_remote_dev_progress_snapshot_query "$issue_num")
else
  snapshot=$(dev_progress_snapshot "$issue_num")
fi

# Final pre-kill recheck + signal (only reached when the initial snapshot is STALE):
if [ "${EXECUTION_BACKEND:-local}" = "remote-aws-ssm" ]; then
  cas_result=$(_remote_dev_progress_compare_and_signal "$issue_num" "$snap_pid" "$snap_run_id")
  # SIGNALED -> proceed to comment+transition; anything else -> abort.
else
  # local: kill -0 recheck, get_pid equality, dev_progress_snapshot recheck, then kill "$pid"
fi
```

Local-backend installations never call the remote functions; the local
`dev_progress_snapshot` reads [INV-135]'s sidecars directly and the
final recheck reuses the pre-existing local `kill -0`/`get_pid` calls
unchanged.

**Adding a new non-local backend**: implement
`agent-progress-snapshot-<your-name>.sh` per the [transport
contract](#4-agent-progress-snapshot--compare-and-signal-transport-inv-137-485)
above (both `--snapshot` and `--compare-and-signal` modes), then extend
the `EXECUTION_BACKEND` equality checks in `dispatcher-tick.sh`'s Step
5a block to also match the new backend's name. Same whitelist-not-blanket
rule as the other two contracts: relaxing either check to `!= "local"`
would fall through to a local read that always misses under the new
backend, silently disabling the progress gate for it (UNKNOWN on every
tick, which is fail-safe but defeats the point of the feature — Step 5a
would never SIGTERM a genuinely stale wrapper on that backend).

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

### Asymmetric bias for the terminal-state probe ([INV-101], #356)

The terminal-state probe transport's indeterminate case biases the
OPPOSITE direction from liveness: `is_session_completed` treats an
empty/error `--probe` result as "not completed" (fail-closed to the
existing residual `stale-verdict:` park or resume-attempt), never as a
fabricated `completed`/`prompt_too_long` verdict. Same reasoning
structure, different safe default:

- Treat indeterminate as "completed" → could misroute a still-live or
  freshly-crashed session through the INV-35 verdict table (e.g. an
  unwarranted `dev-new` against a session that hasn't actually
  finished, or an operator handoff for a session still making
  progress). Not recoverable without operator inspection.
- Treat indeterminate as "not completed" (the chosen default) → at
  worst, the existing residual park / resume-attempt behavior continues
  one more tick until the transport recovers. Recovery is automatic.

`_reset_session_log`'s `--truncate` indeterminate case is simpler:
treat it as a truncate failure, same fail-closed skip-dispatch
behavior the local write-error path already has. No new bias decision
needed there — a failed truncate was already a "stay in current label,
retry next tick" outcome before #356.

## Configuration knobs

Common to all backends:

| Knob | Default | Purpose |
|---|---|---|
| `EXECUTION_BACKEND` | `local` | `local` \| `remote-aws-ssm` \| `<future>` |
| `REMOTE_LIVENESS_CHECK_DISABLE` | `false` | `true` falls back to legacy local-only `pid_alive` (operator escape hatch for transport-blocked deployments) |
| `REMOTE_LIVENESS_CHECK_TIMEOUT_SECONDS` | `8` | Dispatcher-side bound on synchronous polling (`lib-ssm.sh::_ssm_run_remote_command` honors this) |
| `SSM_COMMAND_TIMEOUT_SECONDS` | `30` | SSM-side cap (`aws ssm send-command --timeout-seconds`) so a hung remote shell can't tie up an SSM slot for the default 600s. 30 is AWS's hard API minimum for this flag (#369). ALSO passed as the `AWS-RunShellScript` document's own `executionTimeout` parameter (clamped to its 1–172800 valid range) — round-3 review finding #1: `--timeout-seconds` alone only bounds delivery, not execution time, so without this the document's real execution bound silently defaulted to 3600s regardless of this knob |
| `REMOTE_POLL_TIMEOUT_RECOVER_SECONDS` | `5` | Margin added on top of `cmd_sent_at + --timeout-seconds + executionTimeout` (both the delivery and execution bounds, round-4 review finding #1) for `lib-ssm.sh::_ssm_poll_timeout_recover`'s post-cancel recovery poll (see [Poll-timeout recovery](#4-agent-progress-snapshot--compare-and-signal-transport-inv-137-485) above) — absorbs `cancel-command`'s own asynchronicity, not an independent timeout of its own |
| `HEARTBEAT_INTERVAL_SECONDS` | `120` | Wrapper-side heartbeat cadence; threshold = `× 3 = 360s` (consumed remote-side in the liveness snippet) |
| `DEV_PROGRESS_STALE_SECONDS` | `1800` | Agent-progress freshness threshold ([INV-137]) — a fixed literal constant on BOTH backends (plain assignment, not `${VAR:-1800}`); not an environment/`autonomous.conf` knob at all, so a deployment cannot classify the same lease differently by backend (round-3 review finding #2) |

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
independently because they only share two on-disk path schemas, both
stable across this doc's history:

- the PID-file schema (`${XDG_RUNTIME_DIR:-$HOME/.local/state}/autonomous-${PROJECT_ID}/${kind}-${N}.pid`), stable since [INV-29];
- the per-issue log schema (`/tmp/agent-${PROJECT_ID}-issue-${N}.log`), stable since before [INV-101] — #356 only changed WHERE the read happens, not the path.

- **New dispatcher + old wrapper**: the remote liveness/probe snippets
  still find the PID file / log at the expected paths; verdicts accurate.
- **New wrapper + old dispatcher**: the old `pid_alive` /
  `is_session_completed` fall through to their legacy local-only checks
  and (under remote backend) miss as before their respective fixes —
  no regression vs status quo.

This means an operator can ship a dispatcher-side fix to Box A
independently of refreshing wrapper-side skills on each Box B host,
which matters for OpenClaw-style deployments where the dispatcher's
upgrade channel is separate from the wrapper-host's.

## Cross-references

- [`invariants.md::INV-23`](invariants.md#inv-23-pid_file-points-at-a-process-whose-death-reaps-the-entire-agent-subtree) — PID_FILE / setsid PGID semantics.
- [`invariants.md::INV-26`](invariants.md#inv-26-stall-decision-excludes-dispatcher-induced-terminations-and-defers-on-live-wrappers) — `mark_stalled` defers when `pid_alive` returns ALIVE; inherits remote awareness automatically.
- [`invariants.md::INV-27`](invariants.md#inv-27-dev-wrapper-dead-detection-requires-both-pid_alive-miss-and-no-near-success-in-flight-signal) — dev-side near-success cross-check; runs after the remote `pid_alive` verdict.
- [`invariants.md::INV-28`](invariants.md#inv-28-pgrep-fallback-must-be-scoped-by-project-and-wrapper-type) — `kill_stale_wrapper` scope; runs on Box B unchanged.
- [`invariants.md::INV-29`](invariants.md#inv-29-pid_alive-heartbeat-is-owned-exclusively-by-the-wrapper-not-by-the-pid-file-alone) — heartbeat sibling lifecycle; the remote snippet replicates this check.
- [`invariants.md::INV-30`](invariants.md#inv-30-pid_alive-is-authoritative-under-all-execution-backends) — the liveness rule this contract enforces; [INV-101] mirrors its shape for terminal-state detection.
- [`invariants.md::INV-98`](invariants.md#inv-98-the-step-4a5-same-head-pr-exists-park-is-not-terminal--a-completed-session-delegates-to-the-inv-35-router-only-the-residual-cases-park) — the delegation [INV-101] makes reachable under remote backend.
- [`invariants.md::INV-101`](invariants.md#inv-101-is_session_completed-is-authoritative-under-all-execution-backends--terminal-state-detection-consults-a-backend-specific-log-probe-mirroring-inv-30s-pid_alive-shape) — the terminal-state rule this contract's [3rd transport](#3-terminal-state-probe-transport-synchronous-probe-truncate) enforces.
- [`invariants.md::INV-135`](invariants.md#inv-135-the-agent-progress-lease-is-a-producer-only-signal-refreshed-on-launch-and-per-complete-output-record-never-by-the-heartbeat) — the lease sidecars the [4th transport](#4-agent-progress-snapshot--compare-and-signal-transport-inv-137-485) reads.
- [`invariants.md::INV-137`](invariants.md#inv-137-step-5a-gates-sigterm-on-a-current-run-agent-progress-lease-not-pr-updatedat-age-alone) — the Step 5a decision rule the [4th transport](#4-agent-progress-snapshot--compare-and-signal-transport-inv-137-485) and its switching contract enforce.
- [`dispatcher-flow.md`](dispatcher-flow.md) — Step 4a.5 / Step 4b.5 / Step 5 flows; all inherit remote awareness through the unified `pid_alive` / `is_session_completed` / `dev_progress_snapshot` interfaces.

## Adding a new backend

1. Define `EXECUTION_BACKEND=<your-name>` and document the required env in this file.
2. Implement `dispatch-<your-name>.sh` (spawn), `liveness-check-<your-name>.sh` (liveness), `session-log-probe-<your-name>.sh` (terminal-state probe + truncate), and `agent-progress-snapshot-<your-name>.sh` (agent-progress snapshot + compare-and-signal) following the contracts above.
3. Add a `case` arm to `dispatcher-tick.sh::dispatch` to invoke the spawn transport.
4. Add a `case` arm or refactor the existing condition to invoke your liveness transport from `_remote_pid_alive_query`.
5. Add a `case` arm or refactor the existing condition to invoke your terminal-state probe transport from BOTH `_remote_session_log_probe` and `_reset_session_log`.
6. Add a `case` arm or refactor the existing condition to invoke your agent-progress transport from `_remote_dev_progress_snapshot_query` and `_remote_dev_progress_compare_and_signal`, and extend the equivalent checks in `dispatcher-tick.sh`'s Step 5a block.
7. Add unit tests mirroring `test-liveness-check-remote-aws-ssm.sh` / `test-pid-alive-remote-aws-ssm.sh` (liveness), `test-session-log-probe-remote-aws-ssm.sh` / `test-is-session-completed-remote.sh` (terminal-state), and `test-step5a-progress-gate.sh` (agent-progress snapshot + compare-and-signal).
8. Update [INV-30]'s, [INV-101]'s, and [INV-137]'s rules to mention the new backend.
