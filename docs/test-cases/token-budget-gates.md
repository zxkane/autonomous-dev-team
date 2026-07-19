# Test Cases: Token Budget Gates

All executable cases are hermetic. Accounting storage uses temporary
directories; provider, marker, label, dispatch, and SSM operations are stubbed.

## Configuration And Pure Decisions

| ID | Scenario | Expected |
|---|---|---|
| TC-TOKENBUDGET-001 | Both budgets and mode unset | Feature is disabled; no store or provider seam is called |
| TC-TOKENBUDGET-002 | One or both budgets are positive integers | Configuration is valid; unset mode resolves to `warn` |
| TC-TOKENBUDGET-003 | Mode is explicitly `warn` or `hard` | Configured mode is preserved |
| TC-TOKENBUDGET-004 | Budget is `0`, negative, non-integer, or non-canonical | Nonzero refusal names the variable and exact value |
| TC-TOKENBUDGET-005 | Mode is set outside `warn|hard` | Nonzero refusal names `TOKEN_BUDGET_MODE` and its value |
| TC-TOKENBUDGET-006 | Completed usage is under, equal to, and over a limit | Only over is a violation (`>`) |
| TC-TOKENBUDGET-007 | Admission usage is under, equal to, and over a limit | Equal and over block (`>=`) |
| TC-TOKENBUDGET-008 | Adapter is claude/codex vs kiro/agy/gemini/opencode/unknown | Only the first pair is accountable; every other or future adapter is unavailable |
| TC-TOKENBUDGET-009 | Library is sourced with hostile/unwritable paths | Source performs no I/O and emits no output |

## Strict Invocation Accounting

| ID | Scenario | Expected |
|---|---|---|
| TC-TOKENBUDGET-010 | Dev first launch | Identity is `(RUN_ID,dev,dev,1)` and commit uses its fresh log offset |
| TC-TOKENBUDGET-011 | Dev resume fallback launches a second agent | Identity uses attempt 2 and a newly captured offset |
| TC-TOKENBUDGET-012 | Two same-named review members share a run ID | Distinct session UUIDs produce distinct invocation IDs and totals |
| TC-TOKENBUDGET-013 | Codex performs bounded internal reruns | One invocation is started and final parser record is committed once |
| TC-TOKENBUDGET-014 | Parser returns total/input/output | `accounting_commit_usage` receives total and available components |
| TC-TOKENBUDGET-015 | Parser returns total only | Missing components are committed as `-` |
| TC-TOKENBUDGET-016 | Parser returns no usage | Invocation commits unknown with `no-usage-in-log` |
| TC-TOKENBUDGET-017 | Review member is unavailable or timed out | Invocation commits unknown with `member-dropped` |
| TC-TOKENBUDGET-018 | Commit fails | Failure is loud; warn proceeds and hard records a usage-unknown violation |
| TC-TOKENBUDGET-019 | `accounting_start` fails | Warn launches degraded; hard refuses launch with no label mutation |
| TC-TOKENBUDGET-020 | Hard mode uses any adapter outside claude/codex | Launch is refused before accounting or agent execution |
| TC-TOKENBUDGET-021 | Warn mode uses any adapter outside claude/codex | Launch runs and warning evidence reports usage unavailable |

## Projection And Cumulative Usage

| ID | Scenario | Expected |
|---|---|---|
| TC-TOKENBUDGET-030 | Reconcile and query succeed with complete usage | Projection returns exact cumulative total and digest |
| TC-TOKENBUDGET-031 | Prior-run open invocation remains after reconcile | It commits unknown as `orphaned-by-crash` |
| TC-TOKENBUDGET-032 | Current-run open invocation remains | It is untouched and residual incomplete maps to unavailable |
| TC-TOKENBUDGET-033 | Dispatcher projection sees any open invocation | With no current run, every open is swept |
| TC-TOKENBUDGET-034 | Reconcile, sweep, or query fails | Projection maps the result to unavailable |
| TC-TOKENBUDGET-035 | Final query is usage-unknown or corrupt | Status and source digest remain fail-closed evidence |
| TC-TOKENBUDGET-036 | Raced live invocation was swept | Its later conflicting commit is loud and follows commit-failure policy |
| TC-TOKENBUDGET-037 | Usage spans dev retry and review members | Totals aggregate exactly once across stages |
| TC-TOKENBUDGET-038 | Remote SSM projection succeeds | Query runs on execution host and returns its normalized JSON |
| TC-TOKENBUDGET-039 | Remote SSM transport fails | Result is unavailable; controller-local accounting is never queried |

## Warning Mode

| ID | Scenario | Expected |
|---|---|---|
| TC-TOKENBUDGET-040 | Invocation exceeds configured limit | One invocation breadcrumb is posted; routing is unchanged |
| TC-TOKENBUDGET-041 | Issue reaches dispatcher equality | One issue breadcrumb is posted; dispatch proceeds |
| TC-TOKENBUDGET-042 | Measured value grows on a later tick | Parsed `(issue,scope,limit)` key suppresses a duplicate |
| TC-TOKENBUDGET-043 | Another side observes the same key | Different side does not re-post |
| TC-TOKENBUDGET-044 | Configured limit changes | New key re-arms one warning |
| TC-TOKENBUDGET-045 | Usage is missing or adapter unavailable | Breadcrumb includes explicit unavailable evidence |
| TC-TOKENBUDGET-046 | Dispatcher or wrapper process restarts | Durable marker parsing still suppresses duplicates |

## Hard Routing

| ID | Scenario | Expected |
|---|---|---|
| TC-TOKENBUDGET-050 | Dev invocation is equal vs over its limit | Equality routes normally; over writes invocation intent before cleanup |
| TC-TOKENBUDGET-051 | Dev cumulative total is over | Digest-derived issue intent causes INV-140 cleanup to stall |
| TC-TOKENBUDGET-052 | Review member is over or unknown | Verdict remains posted; member intent plus explicit cleanup stalls, no crash verdict |
| TC-TOKENBUDGET-053 | Review cumulative total is over or fail-closed | Issue intent plus explicit cleanup stalls before approval |
| TC-TOKENBUDGET-054 | Review projection is unavailable | No approve/merge or intent; `reviewing -> pending-review`, result parsed |
| TC-TOKENBUDGET-055 | Dispatcher total is below vs equal | Below launches; equality blocks the next launch |
| TC-TOKENBUDGET-056 | Dispatcher sees usage-unknown or corrupt | Stable digest intent uses reason `usage-unknown` and stalls |
| TC-TOKENBUDGET-057 | Pending-state stall has wrong owner | Intent is cleared, marker is released, and no label is changed |
| TC-TOKENBUDGET-058 | Dev-new admission has no pending label | Atomic add of `stalled` preserves `autonomous` |
| TC-TOKENBUDGET-059 | Dispatcher projection is unavailable | Marker is released, no stall occurs, and next tick may retry |
| TC-TOKENBUDGET-060 | Terminal transition is in progress | Dispatch marker is not released until transition completes |
| TC-TOKENBUDGET-061 | Same unchanged store is retried | Digest-derived intent and report are idempotent across restart |
| TC-TOKENBUDGET-062 | Wrapper cleanup re-enters after intent | Final state remains stalled with no pending-label resurrection |
| TC-TOKENBUDGET-063 | Dispatcher Step 5 sees a live hard intent while reconciling an active issue | Terminal-aware recovery converges to stalled and consumes after transition; pending is never resurrected |
| TC-TOKENBUDGET-064 | Review unavailable-hold transition failed before wrapper exit | Step 5 recognizes the durable `token-budget-unavailable` trailer and restores `pending-review`, never `pending-dev` |
| TC-TOKENBUDGET-065 | A later review fan-out member is refused after an earlier member exceeds its invocation budget | The launched member is evaluated first, its verdict remains published, and its terminal intent routes the issue to `stalled` |
| TC-TOKENBUDGET-066 | A review accounting-start refusal or unavailable hold cannot persist its trailer or transition | While hard-mode budgeting remains active, Step 5 retries `reviewing -> pending-review`; it never falls through to development |
| TC-TOKENBUDGET-067 | Budgets are unset after a wrapper persisted a live terminal intent | Step 5 still uses INV-140 recovery and converges to `stalled`; unsetting configuration cannot resurrect a pending state |
| TC-TOKENBUDGET-068 | `stall_from_pending` fails because of a label-read or transition error rather than wrong ownership | The terminal intent and dispatch marker remain live; only a confirmed wrong-owner result clears and releases them |
| TC-TOKENBUDGET-069 | A dev attempt commits a hard violation and the following in-wrapper retry is refused at `accounting_start` | The durable violation takes precedence and cleanup immediately routes through INV-140 to `stalled` |
| TC-TOKENBUDGET-078 | A review wrapper crashes with warn-mode budgets configured and no budget retry trailer or intent | Step 5 preserves legacy routing to `pending-dev`; the hard-only fallback cannot create an unbounded review loop |
| TC-TOKENBUDGET-079 | A hard invocation violation is committed but its terminal-intent write fails before wrapper exit | Before provider writes, the wrapper stores an invocation-keyed recovery pointer beside the strict INV-139 record; if the trusted pending comment also fails, that pointer preserves the actual hard decision without reclassifying historical records after a mode/limit change. Step 5 reads and clears the pointer on the execution host (including remote SSM), retries, and converges to `stalled` before any new invocation for both dev and review owners. Marker comments require exact self-authored whole bodies, embedded or human markers are ignored, resolved markers do not replay, a retired generation after a lost resolved post does not re-route terminal, and disabled budgets perform no marker or accounting I/O |
| TC-TOKENBUDGET-080 | A nested completed-session or same-HEAD dispatch route rejects configuration | The nonzero gate result propagates through every router to the top-level tick with no label mutation |
| TC-TOKENBUDGET-081 | Recovery pointer, pending marker, and terminal-intent persistence all fail for a hard invocation violation, optionally followed by an in-wrapper launch refusal | While a hard per-invocation budget remains configured, Step 5 preserves the active owner instead of entering ordinary dev/review crash routing; the later refusal cannot post a retry marker that masks the undurable terminal decision, and disabling the gate explicitly re-arms legacy recovery |
| TC-TOKENBUDGET-082 | A newer recovery-pointer generation is staged while an older generation is being cleared | Stage and compare-delete clear share the mandatory accounting issue lock, so clearing generation A cannot delete generation B locally or through remote execution-host clear |
| TC-TOKENBUDGET-083 | A historical review retry trailer predates the latest trusted self-authored review dispatch token, while a current trailer may share its timestamp second | Step 5 compares `(createdAt,id)`: it ignores the stale trailer, accepts a same-second higher-ID trailer, and preserves the correct review ownership; null/non-string comment fields cannot become a cutoff or crash marker parsing |
| TC-TOKENBUDGET-084 | A token-budget review path exits `failed-non-substantive` because every launch was refused, a later launch was refused, or cumulative usage is unavailable | Immediately after its verdict trailer attempt, each path posts the INV-129 `round=0` reset marker as an independent reset channel, including when the trailer post fails |
| TC-TOKENBUDGET-085 | Run-artifact initialization degrades while budgets remain enabled, leaving `RUN_ID` unset under `set -u` | Dev cleanup and the review pre-approval gate pass an empty current-run ID without aborting; all six token-budget wrapper call sites use nounset-safe fallback expansion |

## Wiring And E2E

| ID | Scenario | Expected |
|---|---|---|
| TC-TOKENBUDGET-070 | Dispatcher source inventory | All seven post-marker/pre-mutation sites call the shared gate with pinned state/mode |
| TC-TOKENBUDGET-071 | Dev wrapper fixture crosses invocation cap | Warn continues; hard stalls before another phase |
| TC-TOKENBUDGET-072 | Dev and review usage reaches issue cap exactly | Next dispatcher admission blocks at equality |
| TC-TOKENBUDGET-073 | Review fan-out fixture | Member UUID totals are not collapsed by shared run ID |
| TC-TOKENBUDGET-074 | Wrapper crashes with an open record | Next projection sweeps it and cleanup converges to stalled |
| TC-TOKENBUDGET-075 | Dispatcher restarts after terminal decision | No duplicate warning/report and no second dispatch |
| TC-TOKENBUDGET-076 | New library branch inventory | Source-derived semantic branch coverage exceeds 80 percent |
| TC-TOKENBUDGET-077 | Shell and spec drift checks | Changed shell passes syntax/ShellCheck and all stalled causes are declared |
