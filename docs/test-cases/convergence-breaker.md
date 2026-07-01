# Test cases — dispatcher convergence circuit-breaker (issue #297 / INV-97)

Fixture-driven, mirroring the existing `test-handle-completed-session-routing.sh`
and `test-mark-stalled-liveness.sh` harnesses. Run under `env -u PROJECT_DIR` for
CI parity.

- `tests/unit/test-convergence-breaker.sh` — the breaker in
  `handle_completed_session_routing` + the shared `may_stall_now` helper.
- `tests/unit/test-mark-stalled-liveness.sh` — extended with a characterization
  test that `mark_stalled`'s deferral-comment behavior is byte-identical after
  the `may_stall_now` factoring.

| Test ID | Scenario | Expected |
|---|---|---|
| CB-TRIP-001 | 3 frozen-head completed zero-commit rounds, `dev-actionable=true`, identical trailer-hash, no live PID | ONE `reason=non-convergence` report + `<!-- dispatcher-convergence-breaker … -->` marker; `stalled` added, `autonomous`+`pending-dev` removed; NO dev-new dispatch |
| CB-MISS-002 | Latest round's PR head ADVANCED (converging) | Does NOT trip → Branch C dev-new |
| CB-MISS-003 | Only 2 frozen rounds (< `CONVERGENCE_STALL_THRESHOLD`=3) | Does NOT trip → Branch C dev-new |
| CB-PRECEDENCE-004 | `failed-substantive` + `dev-actionable=false` | Branch B′ ([INV-92]) escalates; breaker does NOT run and does NOT count the round |
| CB-LIVE-005 | ≥3 frozen rounds BUT `may_stall_now` reports a live dev PID | Posts NOTHING, marks NOTHING, defers (no orphan report/marker); returns 0 |
| CB-IDEM-006 | Second tick, same `{issue, head, trailer-hash}`, marker already present | Nothing posted, nothing dispatched, NO duplicate `label_swap` |
| CB-IDEM-007 | NEW trailer-hash on the same frozen head | Re-evaluates (different marker → not suppressed) |
| CB-REPORT-008 | Trip report content | Contains PR ref (`#<num>`), frozen head SHA, `reason=non-convergence`, "re-add the `autonomous` label" resume instruction, repeated-failure count, AND the counted rounds' **per-round timestamps** ([P1] round-1 finding 2, not the `(unavailable)` fallback) |
| CB-COUNT-009a | Stale `failed-non-substantive` rounds precede the active `failed-substantive`+`dev-actionable=true` rounds on the same SHA | Count = only the active-case rounds (stale excluded → no early trip) — [P1] round-1 finding 1 |
| CB-COUNT-009b | A prior `dev-actionable=false` round on the same SHA + genuine active `dev-actionable=true` rounds | The false round is excluded but does NOT zero the active rounds (no forever-suppression) — [P1] round-1 finding 1 |
| CB-COUNT-009c | Active canonical does not match the rounds' verdict | Count = 0 |
| CB-SHARED-010 | Source-of-truth | `mark_stalled` and the breaker both call `may_stall_now`; the `pid_alive` liveness block is NOT duplicated |
| CB-DUAL-011 | Trip terminal comment count | Exactly ONE terminal comment (the #297 report); NO `mark_stalled` "@owner retry exhausted" dual-post |
| CB-THRESH-012 | `CONVERGENCE_STALL_THRESHOLD` override honored | With threshold=4, 3 frozen rounds do NOT trip; 4 do |
| MSL-CHAR-011 | `may_stall_now` factoring characterization (in `test-mark-stalled-liveness.sh`) | `mark_stalled` still defers (posts `INV-26-stall-deferral` comment, no stall label) on a live wrapper; still stalls on dead/absent PID — byte-identical to pre-factoring |

## Acceptance criteria coverage

- **AC1** (detect non-convergence + halt): CB-TRIP-001, CB-COUNT-009a/b/c, CB-THRESH-012.
- **AC2** (single structured report with reason + SHA + repeated findings + human checklist): CB-REPORT-008, CB-DUAL-011.
- **AC3** (converging loops unaffected + idempotent): CB-MISS-002, CB-MISS-003, CB-IDEM-006, CB-IDEM-007.
- **AC4** (docs updated: dispatcher-flow + INV-97): enforced by the pipeline-docs-gate + TC-SPEC-GATE-040/041 (heading-adjacent triage tag).
- **#298 precedence**: CB-PRECEDENCE-004.
- **live-PID deferral inherited via shared helper**: CB-LIVE-005, CB-SHARED-010, MSL-CHAR-011.
