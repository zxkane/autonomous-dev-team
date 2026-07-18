# Test Cases: Terminal Control (#515)

All cases are hermetic. Comment and label I/O is provided by stubbed `itp_*`
functions, timestamps are deterministic, and no test sleeps or reaches a real
provider.

## Marker Protocol

| ID | Scenario | Expected |
|---|---|---|
| TC-TERMCTRL-001 | Write then read an intent | Exact anchored marker is posted; compact JSON round-trips every field |
| TC-TERMCTRL-002 | Write the same stable intent twice | Second write is rc 0 and posts nothing |
| TC-TERMCTRL-003 | Human posts an exact forged intent | Forgery is ignored and does not suppress the trusted write |
| TC-TERMCTRL-004 | Human posts consume/clear copies | They do not retire a trusted intent |
| TC-TERMCTRL-005 | Malformed or substring marker | It is ignored by the fully anchored parser |
| TC-TERMCTRL-006 | Consume a live intent | Read becomes empty; repeated consume is an idempotent no-op |
| TC-TERMCTRL-007 | Clear a live intent | Read becomes empty; repeated identical clear is an idempotent no-op |
| TC-TERMCTRL-008 | Two live intents | Newest trusted write wins |
| TC-TERMCTRL-009 | Newest intent consumed | Read falls back to the older still-live intent |
| TC-TERMCTRL-010 | Invalid issue/id/reason/owner or missing arg | rc is nonzero, diagnostic is loud, no comment is posted under `set -u` |
| TC-TERMCTRL-011 | Comment read fails or returns malformed JSON | Public operation fails loudly; no write occurs |
| TC-TERMCTRL-012 | Consume/clear names no trusted intent | rc is nonzero and no lifecycle marker is posted |
| TC-TERMCTRL-013 | An intent ID is reused with a new invocation after consume | The old invocation stays consumed while the new generation is live and independently consumable |
| TC-TERMCTRL-014 | An intent ID is reused with a new invocation after clear | The old invocation stays cleared while the new generation is live and independently clearable |
| TC-TERMCTRL-015 | Read/consume/clear receive missing or invalid domain arguments | rc is nonzero under `set -u`; no comment is posted |
| TC-TERMCTRL-016 | Cleanup consume races an operator clear, including inside its read/post window | Any clear for that invocation generation dominates stale consumes regardless of comment order; clear replay remains idempotent |
| TC-TERMCTRL-017 | Terminal-control comment read under GitHub PAT/App or GitLab PAT auth | PAT/GitLab resolve the active user; configured cross-role identities are promoted exactly; GitHub App slugs resolve through App JWTs |
| TC-TERMCTRL-018 | A human or non-promoted bot posts an exact marker copy, including PAT/App slug collisions in either direction | `authorKind=human|bot` is not sufficient core authority; the marker is ignored |
| TC-TERMCTRL-019 | Delayed duplicate, concurrent generation, or lifecycle-before-write race | Lifecycle binds to invocation and requires a preceding matching write; newest live generation wins and stale events cannot retire or resurrect another generation |

## Owner-Aware Transitions

| ID | Scenario | Expected |
|---|---|---|
| TC-TERMCTRL-020 | `pending-dev` owner stalls | One atomic `pending-dev -> stalled` transition |
| TC-TERMCTRL-021 | `pending-review` owner stalls | One atomic `pending-review -> stalled` transition |
| TC-TERMCTRL-022 | `in-progress` owner stalls | One atomic `in-progress -> stalled` transition |
| TC-TERMCTRL-023 | `reviewing` owner stalls | One atomic `reviewing -> stalled` transition |
| TC-TERMCTRL-024 | Issue is already stalled | rc 0, no mutation |
| TC-TERMCTRL-025 | Expected state is absent | rc is nonzero, no mutation |
| TC-TERMCTRL-026 | Expected-state argument is outside the helper domain | rc is nonzero, no label read or mutation |
| TC-TERMCTRL-027 | Label read is unavailable/malformed | rc is nonzero, no mutation |
| TC-TERMCTRL-028 | Atomic transition fails | rc is nonzero and the error is not swallowed |
| TC-TERMCTRL-029 | Issue also has `autonomous` | `autonomous` remains after the transition |
| TC-TERMCTRL-030 | Transition wiring | `mark_stalled` is never invoked |

## Cleanup Override

| ID | Scenario | Expected |
|---|---|---|
| TC-TERMCTRL-040 | Dev cleanup has a live intent | Routes `in-progress -> stalled`, then consumes |
| TC-TERMCTRL-041 | Review cleanup has a live intent | Routes `reviewing -> stalled`, then consumes |
| TC-TERMCTRL-042 | Dev cleanup has no intent, PR exists | Original `in-progress,pending-dev -> pending-review` argv is unchanged |
| TC-TERMCTRL-043 | Dev cleanup has no intent, retry path | Original `in-progress -> pending-dev` argv is unchanged |
| TC-TERMCTRL-044 | Review cleanup has no intent | Original `reviewing -> pending-dev` argv is unchanged |
| TC-TERMCTRL-045 | Intent was already consumed | Cleanup follows the original pending route |
| TC-TERMCTRL-046 | Intent was operator-cleared | Cleanup follows the original pending route |
| TC-TERMCTRL-047 | Authoritative marker read fails | Fails closed: no pending transition |
| TC-TERMCTRL-048 | Wrong owner moved the issue first | No mutation and intent remains live |
| TC-TERMCTRL-049 | Transition lands but consume post fails | Re-entry sees `stalled`, retries consume, and makes no second transition |
| TC-TERMCTRL-050 | Transition itself fails | Consume is not posted; intent remains live for replay |
| TC-TERMCTRL-051 | Cleanup receives bad arguments or its normal transition fails | rc is nonzero and no successful mutation is reported |
| TC-TERMCTRL-052 | Cleanup re-enters after a completed stall and consume | Already-stalled is a no-op; no pending label is resurrected |
| TC-TERMCTRL-053 | A new same-ID invocation is written between cleanup's intent read and consume | Cleanup consumes the exact generation that caused the stall; the newer generation remains live |
| TC-TERMCTRL-054 | Operator clear lands after cleanup stalls but before its consume post | Re-entry recognizes the cleared decision plus `stalled` and makes no pending transition |

## Crash Recovery And Conformance

| ID | Scenario | Expected |
|---|---|---|
| TC-TERMCTRL-060 | Intent process exits before transition | A fresh process reads the durable comment and stalls the issue |
| TC-TERMCTRL-061 | Fresh process completes cleanup | Final labels are exactly `autonomous,stalled`; read is empty after consume |
| TC-TERMCTRL-070 | Wrapper source wiring | Every cleanup-to-pending call is guarded through terminal control |
| TC-TERMCTRL-071 | Existing retry exhaustion | `mark_stalled` body and all production call sites match pre-feature checksums |
| TC-TERMCTRL-072 | Provider neutrality | New library contains no raw `gh`, `glab`, REST, or GraphQL call |
| TC-TERMCTRL-073 | Branch coverage | Source-derived decision-site coverage of the new library is greater than 80 percent |
| TC-TERMCTRL-074 | Executable state-machine coverage | All four owner-aware `-> stalled` movements are declared, code-site mapped, scanned from `lib-terminal-control.sh`, and guarded by its actual already-stalled predicate |
| TC-TERMCTRL-090 | Hermetic E2E | Separate write and cleanup processes converge to consumed + `stalled`, never pending |
