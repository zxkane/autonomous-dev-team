# Turn-Limit Control Test Cases

Issue: #507
Test ID format: `TC-TURNLIMIT-NNN`

## Configuration and Capability

| ID | Scenario | Expected |
|---|---|---|
| TC-TURNLIMIT-001 | Dev side-specific limit is set and fallback differs | Dev uses `AGENT_DEV_TURN_LIMIT` |
| TC-TURNLIMIT-002 | Review side-specific limit is set and fallback differs | Review uses `AGENT_REVIEW_TURN_LIMIT` |
| TC-TURNLIMIT-003 | Side-specific variable is unset and fallback is valid | Side uses `AGENT_TURN_LIMIT` |
| TC-TURNLIMIT-004 | Side-specific variable is set to empty while fallback is valid | Validation refuses and names the side-specific variable/value |
| TC-TURNLIMIT-005 | Effective limit is zero, signed, fractional, padded, or nonnumeric | Validation refuses; only `^[1-9][0-9]*$` passes |
| TC-TURNLIMIT-006 | Invalid fallback is shadowed by a valid side-specific value | That side validates because only its effective value is checked |
| TC-TURNLIMIT-007 | `TURN_LIMIT_MODE` is unset with an effective limit | Effective mode is `warn` |
| TC-TURNLIMIT-008 | `TURN_LIMIT_MODE` is invalid while both sides are disabled | Validation refuses |
| TC-TURNLIMIT-009 | No effective limit exists | Feature reports disabled and creates no files |
| TC-TURNLIMIT-010 | Source `lib-turn-limit.sh` | No output, process, directory, or file side effect |
| TC-TURNLIMIT-011 | Production adapter x controlled lane x mode full matrix | Only Claude warn is statically supported; every production hard tuple is unsupported |
| TC-TURNLIMIT-012 | Synthetic adapter x controlled lane x mode | Pure lookup supports warn and hard |
| TC-TURNLIMIT-013 | Unknown adapter, lane, or mode | Capability lookup returns unsupported |
| TC-TURNLIMIT-014 | Adapter-spec capability table is parsed | It is identical to the authoritative shell matrix |
| TC-TURNLIMIT-015 | Claude output contains `2.1.215 (Claude Code)` | Normalizes and passes the pinned minimum |
| TC-TURNLIMIT-016 | Claude version is above the minimum | Probe passes |
| TC-TURNLIMIT-017 | Claude version is below the minimum | Probe refuses |
| TC-TURNLIMIT-018 | Claude version output has no leading semantic version | Probe refuses |
| TC-TURNLIMIT-019 | Production wrapper validates any adapter in hard mode | Refuses before an adapter process starts |
| TC-TURNLIMIT-020 | Production wrapper is pointed at `synthetic` | Refuses the test-only adapter before launch |

## Observation and Admission

| ID | Scenario | Expected |
|---|---|---|
| TC-TURNLIMIT-021 | Complete top-level Claude `assistant` record with text | Count increments once |
| TC-TURNLIMIT-022 | Complete top-level Claude `assistant` record with tool use | Count increments once |
| TC-TURNLIMIT-023 | Tool/progress/system/user records | Count does not change |
| TC-TURNLIMIT-024 | Result record has a large `num_turns` | Count does not change |
| TC-TURNLIMIT-025 | Malformed or partial JSON record | Count does not change |
| TC-TURNLIMIT-026 | Warn count reaches the limit | One `warned` evidence object is appended and execution continues |
| TC-TURNLIMIT-027 | More assistant records arrive after warning | No duplicate `warned` action is appended |
| TC-TURNLIMIT-028 | Synthetic completed count is below N | `admit_next_request` admits |
| TC-TURNLIMIT-029 | Synthetic completed count equals N | Admission denies, persists `turn-cap`, and request N+1 is not started |
| TC-TURNLIMIT-030 | Observer is inspected statically and dynamically | It never invokes `kill`, `pkill`, or a process-group signaller |

## Durable Arbitration

| ID | Scenario | Expected |
|---|---|---|
| TC-TURNLIMIT-031 | Initialize or reopen a controlled invocation | Versioned `running` JSON is atomically installed; reopening requires the exact immutable identity envelope |
| TC-TURNLIMIT-032 | Turn-cap request wins before timeout | Winner remains `turn-cap`; timeout is `late-ignored` |
| TC-TURNLIMIT-033 | Timeout request wins before turn-cap | Winner remains `timeout`; turn-cap is `late-ignored` |
| TC-TURNLIMIT-034 | Process records natural completion before a stop request | State remains `completed`; request is `late-ignored` |
| TC-TURNLIMIT-035 | Duplicate winning request is submitted | Winner is unchanged and evidence remains idempotent |
| TC-TURNLIMIT-036 | Winner enters termination | `terminating` and `terminated` evidence are durable before TERM |
| TC-TURNLIMIT-037 | Terminal transition completes | Lifecycle ends at `terminal-transitioned` |
| TC-TURNLIMIT-038 | Every evidence action path is exercised | Every required schema field is present |
| TC-TURNLIMIT-039 | Concurrent requests race under flock | Exactly one winner is persisted |

## Watchdog and Routing

| ID | Scenario | Expected |
|---|---|---|
| TC-TURNLIMIT-040 | Turn control is disabled | Existing GNU `timeout --kill-after=30s --signal=TERM` argv is unchanged |
| TC-TURNLIMIT-041 | Warn observation is active | GNU timeout path remains selected and warning never signals |
| TC-TURNLIMIT-042 | Hard synthetic turn-cap wins | Watchdog returns rc 92, not 124/137 |
| TC-TURNLIMIT-043 | Hard synthetic fanout-cancel wins | Watchdog returns rc 92 and writes no terminal intent |
| TC-TURNLIMIT-044 | Hard synthetic timeout wins and TERM succeeds | Watchdog returns 124 |
| TC-TURNLIMIT-045 | Hard synthetic timeout wins and TERM is ignored | Watchdog escalates to KILL and returns 137 |
| TC-TURNLIMIT-046 | Turn-cap and timeout race in both orders, including exit before TERM lands | First durable reason controls evidence, rc, and routing even when TERM becomes a no-op |
| TC-TURNLIMIT-047 | TERM-resistant synthetic descendant shares the PGID | TERM then KILL removes the full group |
| TC-TURNLIMIT-048 | Turn-cap winner has parseable final usage | Existing total is committed normally |
| TC-TURNLIMIT-049 | Turn-cap winner lacks parseable usage | Unknown reason is `turn-cap`, exactly once |
| TC-TURNLIMIT-050 | Cancelled sibling lacks parseable usage | Unknown reason is `fanout-cancelled`, exactly once |
| TC-TURNLIMIT-051 | Turn-cap winner routes terminally | INV-140 intent uses triggering invocation for both IDs and owner for the wrapper |
| TC-TURNLIMIT-052 | Timeout winner routes | INV-48 124/137 behavior remains; no turn-cap intent |

## Review Fan-Out

| ID | Scenario | Expected |
|---|---|---|
| TC-TURNLIMIT-053 | Synthetic review member trips hard cap | Shared trip names a trigger whose durable winner is `turn-cap`; a timeout-owned candidate never activates |
| TC-TURNLIMIT-054 | Parent is about to launch a later member after a trip | Launch is suppressed |
| TC-TURNLIMIT-055 | Codex controller is about to rerun after a trip | Rerun is suppressed |
| TC-TURNLIMIT-056 | Active sibling watchdog sees another member's trip | It persists `fanout-cancel`, terminates its own PGID, and records `cancelled-sibling` only when cancellation wins |
| TC-TURNLIMIT-057 | Trigger watchdog sees its own trip | Its winner remains `turn-cap`, never rewritten to sibling cancellation |
| TC-TURNLIMIT-058 | Fan-out resolves after a hard trip | Existing INV-43 reapers run only as residual cleanup |
| TC-TURNLIMIT-059 | Parent handles a trip or partial member initialization failure | PASS aggregation, approval, and merge are skipped |
| TC-TURNLIMIT-060 | Parent routes terminally | Exactly one stalled transition occurs through `terminal_intent_cleanup_transition` |
| TC-TURNLIMIT-061 | Mixed parseable/unparseable sibling usage | Totals are preserved; only missing totals become the pinned unknown reasons |

## Hermetic End-to-End and Documentation

| ID | Scenario | Expected |
|---|---|---|
| TC-TURNLIMIT-062 | Synthetic adapter runs with N=3 | Exactly three completed turns; admission log has no request 4 |
| TC-TURNLIMIT-063 | Timeout-first synthetic race | Winner timeout; rc 124/137; no turn-cap terminal intent |
| TC-TURNLIMIT-064 | Turn-first synthetic race | Winner turn-cap; rc 92; one turn-cap terminal intent |
| TC-TURNLIMIT-065 | Synthetic fan-out has one trigger and active siblings | Siblings exit through their own watchdogs and no descendants remain |
| TC-TURNLIMIT-066 | Unsupported production hard configuration with launch sentinel | Wrapper exits nonzero and sentinel is absent |
| TC-TURNLIMIT-067 | Claude warn with failed version probe and launch sentinel | Wrapper exits nonzero and sentinel is absent |
| TC-TURNLIMIT-068 | Synthetic reachability scan | No production adapter source/dispatch case, example config, or operator-selectable adapter list includes it |
| TC-TURNLIMIT-069 | INV-142 and flow/containment/state docs are scanned | Capability, contracts, arbitration, sole-signaller, reason mapping, and turn-cap stalled cause are present |
| TC-TURNLIMIT-070 | Shell syntax, ShellCheck, spec drift, and full hermetic suite | All changed shell and documentation gates pass |
| TC-TURNLIMIT-071 | Focused suites trace the 81-outcome capability/controller branch inventory | Every source marker has exactly one inventory row, every covered row executes, uncovered outcomes remain explicit, and covered outcomes exceed 80% |
| TC-TURNLIMIT-072 | Synthetic fan-out plus the extracted review-wrapper decision block run hermetically | Siblings converge through their watchdogs before residual reaping; the wrapper decision suppresses aggregation and merge; one stalled transition lands |
| TC-TURNLIMIT-073 | A hard controller cannot persist its stop request or `terminating` transition | It retries while the group is live and sends no signal without the required durable transition |
| TC-TURNLIMIT-074 | A review trip races a queued member launch | The launch is serialized with the trip record; an active trip records sibling cancellation and starts no adapter process |
| TC-TURNLIMIT-075 | Hard admission cannot read a valid invocation record | Admission fails closed and no request is started |
| TC-TURNLIMIT-076 | The synthetic adapter cannot persist a completed-turn observation | It exits nonzero after the completed request and never admits the following request |
| TC-TURNLIMIT-077 | Real dev-wrapper turn launch functions run against hermetic accounting and intent seams | Initialization, natural completion, turn-cap routing, and accounting/record refusal paths preserve their pinned outcomes |
| TC-TURNLIMIT-078 | A valid turn limit exceeds signed 64-bit range | The exact decimal persists and hard admission does not overflow or deny request one |
| TC-TURNLIMIT-079 | A hard review launch encounters a malformed trip or cannot acquire the launch-boundary lock | No adapter process starts and the controller returns the dedicated rc 93 |
| TC-TURNLIMIT-080 | Trip publication fails or two members durably win `turn-cap` concurrently | The parent recovers a trigger from invocation records, writes one intent and stalled transition, skips merge, and terminalizes every cap record |
| TC-TURNLIMIT-081 | Turn evidence cannot persist through the shared stream recorder | Hard mode fails closed; warn mode logs once and continues |
| TC-TURNLIMIT-082 | A durable stop winner races a fast process-group exit | Reconciliation advances the record to `terminating` without signaling and preserves the winner rc |
| TC-TURNLIMIT-083 | Hard reconciliation cannot read durable winner state | It returns rc 93 and never records natural completion |
| TC-TURNLIMIT-084 | Codex sees a trip before rerun but cannot persist sibling cancellation | It starts no rerun and returns rc 93 without fabricating a winner |
| TC-TURNLIMIT-085 | Controlled termination cannot commit final usage or unknown accounting | No terminal intent is consumed and wrapper routing fails closed for retry |
| TC-TURNLIMIT-086 | A `terminating` rename succeeds but its parent-directory sync fails | An idempotent retry re-syncs the visible state before the watchdog may signal |
| TC-TURNLIMIT-087 | Timeout KILL escalation cannot replace a stale rc 124 marker with rc 137 | The watchdog's authoritative rc 137 wins reconciliation |
| TC-TURNLIMIT-088 | A hard recorder failure reaches an adapter pipeline or dev wrapper as rc 93 | The pipeline fails closed, dev preserves the running record, and resume fallback/accounting do not run |
| TC-TURNLIMIT-089 | A hard review timeout cannot durably commit usage | Post-fan-out control returns failure before aggregation, approval, or merge |
| TC-TURNLIMIT-090 | The real review wrapper delegates post-fan-out turn orchestration | The shared orchestration returns a terminal result that the wrapper maps to an immediate exit before aggregation |
| TC-TURNLIMIT-091 | Published capability parity includes the synthetic fixture | Production rows and a clearly non-selectable synthetic row together mirror every authoritative adapter/mode result |
| TC-TURNLIMIT-092 | Initial review trip publication fails transiently before becoming durable | Admission remains denied and retries publication so active siblings can consume cancellation |
| TC-TURNLIMIT-093 | A trip rename succeeds but its parent-directory sync fails | An existing-record retry re-syncs the trip file and directory before accepting it as authoritative |
| TC-TURNLIMIT-094 | A queued review sibling's first trip synchronization fails | Post-fan-out control retries cancellation before natural completion or terminal routing |
| TC-TURNLIMIT-095 | A Claude warn invocation genuinely exits with rc 93 | Wrappers treat it as an adapter result; rc 93 is control-plane-only in hard mode |
| TC-TURNLIMIT-096 | Turn-record initialization fails after strict accounting starts | Wrapper cleanup checks and idempotently retries the terminal accounting commit |
| TC-TURNLIMIT-097 | Sibling cancellation persists but its winner cannot be read | Synchronization fails closed; a retry records `cancelled-sibling` evidence exactly once |
| TC-TURNLIMIT-098 | A turn-cap record is still `stop-requested` | Terminal intent routing refuses until `terminating` is durable |
| TC-TURNLIMIT-099 | Review-trip synchronization fails after changing invocation context | Caller-visible turn-control globals remain unchanged on every return path |
| TC-TURNLIMIT-100 | Invocation initialization rename succeeds but directory sync fails | A matching reopen re-syncs the visible record before accepting it |
| TC-TURNLIMIT-101 | A hard-controlled command starts while `setsid` has not yet published its PGID | The watchdog waits for an in-group readiness handshake before polling or signalling |
| TC-TURNLIMIT-102 | A stop-request rename is visible but its directory sync fails as the command exits naturally | The unconfirmed stop cannot override the natural command result |
| TC-TURNLIMIT-103 | Duplicate stop, completed, or terminal-transition requests follow a prior visible rename | Every idempotent retry re-confirms file and directory durability |
| TC-TURNLIMIT-104 | Hard control receives a GNU-timeout duration the shell watchdog cannot represent exactly | Launch is refused before the command starts; no four-hour substitution is allowed |
| TC-TURNLIMIT-105 | Claude warn capability is configured behind a side/per-agent launcher | The version probe executes the effective launcher with `--version`, matching the eventual Claude invocation path |
| TC-TURNLIMIT-106 | A naturally completed hard invocation cancels a watchdog while it is polling | Cancellation reaps the watchdog's active sleep child and leaves no delayed poll process |
| TC-TURNLIMIT-107 | Dev hard control returns rc 93 or cannot read its winner after strict accounting started | The wrapper commits `usage-unknown` exactly once before refusing cleanup routing |
| TC-TURNLIMIT-108 | A hard dev invocation ends with a timeout winner while token budgeting is enabled | Token-budget evaluation still runs; timeout affects INV-48 semantics only |
| TC-TURNLIMIT-109 | Review fan-out partially launches, then turn initialization refuses another member while token budgeting is enabled | Completed member usage and token-budget member evaluation run before the retryable refusal exits |
| TC-TURNLIMIT-110 | Wrappers inherit stale internal turn-control variables or a dev invocation follows review state | Startup clears internal activation, and `turn_control_init` derives the canonical side-specific trip path |
| TC-TURNLIMIT-111 | Runtime capability differs by any adapter/lane/mode tuple, or either published matrix drifts | Both the design document and adapter specification must match every authoritative tuple |
| TC-TURNLIMIT-112 | One synthetic review member trips through the hermetic production-wrapper sandbox | The real `autonomous-review.sh` launch/join/post-fan-out path cancels siblings, suppresses later work, and exits before aggregation |
| TC-TURNLIMIT-113 | Turn-cap accounting or intent routing fails after the agent process has converged | Durable invocation state remains redispatch-recoverable and a retry completes accounting, intent routing, and the single stalled transition |
| TC-TURNLIMIT-114 | Review recovery is staged for a trigger and cancelled sibling before accounting commits | Redispatch closes every started member with its pinned reason and terminalizes each controlled lifecycle before clearing recovery |
| TC-TURNLIMIT-115 | Warn-mode winner or completion state cannot be read or persisted | Observation remains fail-open: dev cleanup and review aggregation continue without a turn-control refusal |
| TC-TURNLIMIT-116 | Hard turn-accounting initialization fails after deriving or starting its canonical invocation | The wrapper retains the canonical ID and attempts terminal accounting cleanup instead of leaking an anonymous `started` record |
| TC-TURNLIMIT-117 | Final timeout or cancellation lifecycle persistence fails after process convergence | The controller returns rc 93 rather than reporting a successfully finalized 124/137/92 outcome |
| TC-TURNLIMIT-118 | Step 5 reads an empty `[]` turn-control recovery pointer | Recovery returns `0`, performs no intent write, and falls through to ordinary stale detection |
| TC-TURNLIMIT-119 | Step 5 reads a non-empty recovery pointer with no `reason=turn-cap` entry | Recovery returns `0`, performs no intent write, and falls through to ordinary stale detection |
| TC-TURNLIMIT-120 | Step 5 reads a genuine `reason=turn-cap` recovery candidate | Recovery writes and verifies the pinned terminal intent, then returns `10` |
| TC-TURNLIMIT-121 | Step 5 reads a corrupt recovery pointer | Recovery returns `20` and performs no terminal intent write |
| TC-TURNLIMIT-122 | The real dispatcher Step 5 turn-cap block runs with an empty pointer | It emits no `turn-cap pending-intent read/write unavailable` log and reaches ordinary stale detection |
| TC-TURNLIMIT-123 | Pipeline documentation is scanned for the pending-intent return contract | INV-145 exists and the dispatcher flow, handoffs, and state machine all reference it |
