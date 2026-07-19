# Design Canvas - Turn-Limit Control

Feature: Adapter-aware turn limits and durable stop arbitration
Issue: #507
Date: 2026-07-19
Status: Approved (autonomous mode)

## Scope

This change adds a control plane for per-invocation turn limits without
claiming hard-turn support for any production adapter. Claude stream-json is
observable in `warn` mode after a version probe. All production adapters are
rejected for `hard` mode before launch. A synthetic fixture is the only
hard-capable adapter and is reachable only from hermetic tests.

The browser-E2E lane and agent smoke probes are outside this feature. Existing
INV-43 reapers remain last-resort post-resolution cleanup and do not perform
live turn-cap or sibling cancellation.

## Component Architecture

```text
autonomous.conf
  AGENT_{DEV,REVIEW}_TURN_LIMIT / AGENT_TURN_LIMIT / TURN_LIMIT_MODE
          |
          v
lib-turn-limit.sh
  configuration precedence + syntax validation
  static capability matrix + Claude version probe
  observer/admission contracts
  locked JSON lifecycle + evidence + fan-out trip
          |
          +-----------------------+
          |                       |
          v                       v
dispatcher-tick.sh          execution-host wrappers
syntax only, no gate        capability validation before launch
                                  |
                   +--------------+--------------+
                   |                             |
                   v                             v
             lib-agent.sh                  review fan-out
       complete-record observer       launch/rerun trip checks
       hard watchdog arbitration      per-member watchdog cancel
                   |                             |
                   +--------------+--------------+
                                  |
                                  v
                    INV-140 terminal intent
                    INV-141 accounting commit
```

`lib-turn-limit.sh` is side-effect free when sourced. Public entry points:

- `turn_limit_validate_config SIDE`
- `turn_limit_enabled SIDE`
- `turn_limit_effective_limit SIDE`
- `turn_limit_effective_mode SIDE`
- `turn_capability ADAPTER LANE MODE`
- `turn_limit_validate_launch ADAPTER SIDE LANE`
- `turn_limit_validate_launches ADAPTER SIDE LANE...`
- `turn_accounting_begin ISSUE RUN_ID SIDE MEMBER ATTEMPT MODE [INVOCATION]`
- `turn_accounting_commit_succeeded RESULT_JSON`
- `turn_control_init ISSUE SIDE RUN_ID INVOCATION MEMBER ADAPTER VERSION LIMIT MODE`
- `observe_completed_turn RECORD`
- `admit_next_request`
- `turn_control_request_stop REASON`
- `turn_control_mark_terminating`
- `turn_control_mark_completed`
- `turn_control_mark_terminal_transitioned`
- `turn_control_winner`
- `turn_control_route_terminal ISSUE OWNER`
- `turn_fanout_trip_active [TRIP_FILE]`
- `turn_control_sync_fanout_trip`
- `turn_control_complete_review_records RECORDS_ARRAY`
- `turn_control_route_review_fanout ISSUE TRIP RECORDS IDS LOGS RESULTS`
- `turn_control_route_review_unpublished_cap ISSUE RECORDS IDS LOGS RESULTS`
- `turn_control_route_review ISSUE TRIP RECORDS IDS LOGS RESULTS`
- `turn_control_review_post_fanout ISSUE TRIP RECORDS IDS LOGS RESULTS LAUNCH_REFUSED ACCOUNTING_REQUIRED`

`turn_control_route_review` returns 0 after routing a cap, 2 when no cap winner
exists, and 1 for malformed state or a failed accounting/terminal transition.
`turn_control_review_post_fanout` returns 10 after terminal cap routing, 11
after a fully-accounted partial-launch refusal, 0 when ordinary aggregation may
continue, and 1 on a durability/control-plane failure.

Production launch validation rejects `synthetic` unconditionally. Hermetic
tests call the pure capability/control APIs directly and execute the fixture
adapter; no environment switch can make it production-selectable.

## Configuration Resolution

```text
resolve(dev):
  if AGENT_DEV_TURN_LIMIT is SET:
    validate that exact value, including explicit empty -> refusal
  else if AGENT_TURN_LIMIT is SET:
    validate fallback
  else:
    disabled

resolve(review):
  same, using AGENT_REVIEW_TURN_LIMIT

TURN_LIMIT_MODE:
  validate whenever SET, even if both sides are disabled
  unset + effective limit -> warn
```

Only the effective value for a side is validated. A valid side-specific value
therefore shadows an invalid fallback for that side. The dispatcher validates
both sides before selectors or writes; each wrapper validates its own side.

## Capability Matrix

This table mirrors the authoritative `turn_capability` case statement for all
three controlled lanes (`dev-new`, `dev-resume`, and `review-member`).
`claude/warn` additionally requires `claude --version >= 2.1.215`, the host
version used to capture the committed stream-json fixtures.

<!-- TURN-CAPABILITY-MATRIX-BEGIN -->
| Adapter | Warn | Hard |
|---|---|---|
| claude | version-probed | no |
| codex | no | no |
| kiro | no | no |
| agy | no | no |
| gemini | no | no |
| opencode | no | no |
| generic | no | no |
<!-- TURN-CAPABILITY-MATRIX-END -->

The authoritative lookup also exposes one non-selectable fixture:

<!-- TURN-CAPABILITY-TEST-MATRIX-BEGIN -->
| Adapter | Warn | Hard |
|---|---|---|
| synthetic (test-only, non-selectable) | yes | yes |
<!-- TURN-CAPABILITY-TEST-MATRIX-END -->

Unknown adapters, lanes, and modes are unsupported. The production launch
validator rejects `synthetic` even though the pure matrix exposes its test
capability.

## Data Flow

### Warn observation

```text
Claude stdout JSONL
  -> _agent_progress_recorder sees one complete line
  -> observe_completed_turn parses the top-level type
  -> type == "assistant": locked observed_count += 1
  -> first count >= limit: append one `warned` evidence row
  -> stream continues; no signal and no stop request
```

Tool, progress, system, and result records do not count. In particular, a
result record's `num_turns` is never read for a threshold decision.

### Hard admission and arbitration

```text
synthetic request loop
  -> admit_next_request reads durable completed count
  -> count < N: request admitted
  -> response completes; observer increments count
  -> next admit at count == N:
       persist stop-requested(turn-cap)
       persist fanout-trip when this is a review member
       deny request N+1

_run_with_timeout controlled watchdog
  -> poll invocation record and shared fanout-trip
  -> timeout competes by the same locked first-writer rule
  -> persist winner + terminating + evidence before TERM
  -> TERM owned PGID; KILL after grace if needed
  -> timeout => 124/137
  -> turn-cap or fanout-cancel => 92
```

No observer or parent fan-out loop sends a signal. `_run_with_timeout` is the
only live controlled-PGID signaller.

## Durable Record

Path:

```text
${RUN_DIR}/turn-control/<invocation-id>.json
```

The shared review trip is:

```text
${RUN_DIR}/turn-control/fanout-trip.json
```

Each mutation takes an exclusive flock and installs JSON with an atomic
same-directory rename. Invocation records use schema version 1:

```json
{
  "schema_version": 1,
  "state": "running",
  "winner": null,
  "observed_count": "0",
  "limit": "3",
  "evidence": [],
  "late": []
}
```

The first `running -> stop-requested` mutation wins. Later requests append
`late-ignored` evidence and do not replace `winner`. A natural
`running -> completed` mutation similarly makes later stop requests late.
`stop-requested -> terminating -> terminal-transitioned` is monotonic, and no
caller may skip the `terminating` state. Evidence actions are idempotent by
`(invocation_id, action)`.

Every evidence object includes:

```text
issue, side, run_id, invocation_id, member, adapter, adapter_version,
observed_count, limit, mode, action, winning_reason, ts
```

## Review Fan-Out

1. The triggering member denies request N+1, writes `fanout-trip.json`, and
   requests `turn-cap` for its own invocation.
2. The parent checks the trip before each member launch and immediately before
   creating each member controller. The codex rerun loop checks before each
   internal rerun. Final adapter process creation takes the trip record's flock,
   serializing spawn against trip publication; an already-active trip records
   local sibling cancellation and starts no adapter process.
3. Each active sibling's controlled watchdog observes the trip, requests
   `fanout-cancel` on its own record, and terminates its own PGID.
4. The existing post-resolution INV-43 path performs only residual cleanup.
5. The parent writes one `turn-cap` terminal intent using the triggering
   invocation for both intent and invocation IDs, skips aggregation/approval/
   merge, and calls `terminal_intent_cleanup_transition` once.

## Usage and Terminal Routing

- A parseable final usage total commits through `token_accounting_commit`.
- If no terminal accounting record exists and usage is not parseable, the
  trigger commits unknown reason `turn-cap`; a sibling commits
  `fanout-cancelled`.
- Existing terminal accounting records are not overwritten.
- Only winner `turn-cap` writes an INV-140 intent.
- Winners `timeout` and `fanout-cancel` write no terminal intent.
- The dev cleanup guard and review's explicit cleanup call remain the only
  state-transition paths; `mark_stalled` is never called.

### Crash recovery

Before provider writes, turn-cap routing stages an accounting-store recovery
pointer bound to the wrapper owner, triggering invocation id, and absolute
turn-control record path. Review routing adds every launched member's canonical
accounting id, pinned fallback reason, and turn-record path. Dispatcher Step 5
validates the full set, closes any still-started accounting records, and
reconstructs the intent before ordinary dead-wrapper routing. With
`remote-aws-ssm`, the read and completion operations execute on the execution
host where the accounting and turn-control files live. Recovery clears the
pointer only after the stalled transition and all referenced
turn-cap/fanout-cancel lifecycle writes succeed.

## Disabled-Path Invariant

When a side has no effective limit:

- no turn-control directory or record is created;
- no version probe runs;
- no observer work or fan-out trip read occurs;
- `_run_with_timeout` builds the existing GNU-timeout argv unchanged;
- browser-E2E and smoke behavior is unchanged.

## Failure Modes

- Invalid effective limit or mode: loud stderr naming variable and value;
  wrapper exits before launch and does not mutate labels.
- Unsupported adapter/lane/mode: loud execution-host refusal before launch.
- Claude version below `2.1.215` or unparseable: warn capability refused.
- Missing `setsid` in hard mode: refuse before process launch.
- Runtime stop-request or `terminating` persistence failure: the watchdog
  retries while the process group remains live and sends no signal until
  `terminating` is durable. If the group exits naturally first, the durable
  stop request remains `stop-requested` and owns the controlled result.
- Late stop request: append `late-ignored`; winner and rc remain unchanged.
- Process exits before a winner: persist `completed`; later requests lose.
