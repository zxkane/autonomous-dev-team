# Test cases — dispatcher convergence circuit-breaker (issue #297 / INV-103)

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
| CB-TRIP-001 | 3 frozen-head completed zero-commit rounds, `dev-actionable=true`, identical trailer-hash, no live PID | ONE `reason=non-convergence` report + `<!-- dispatcher-convergence-breaker … -->` marker; `pending-dev` removed, `stalled` added (`autonomous` RETAINED); NO dev-new dispatch |
| CB-MISS-002 | Latest round's PR head ADVANCED (converging) | Does NOT trip → Branch C dev-new |
| CB-MISS-003 | Only 2 frozen rounds (< `CONVERGENCE_STALL_THRESHOLD`=3) | Does NOT trip → Branch C dev-new |
| CB-PRECEDENCE-004 | `failed-substantive` + `dev-actionable=false` | Branch B′ ([INV-92]) escalates; breaker does NOT run and does NOT count the round |
| CB-LIVE-005 | ≥3 frozen rounds BUT `may_stall_now` reports a live dev PID | Posts NOTHING, marks NOTHING, defers (no orphan report/marker); returns 0 |
| CB-IDEM-006 | Second tick, same `{issue, head, trailer-hash, session}`, marker already present | Nothing posted, nothing dispatched, NO duplicate `label_swap` |
| CB-IDEM-007 | NEW trailer-hash on the same frozen head, SAME session | Re-evaluates (different marker → not suppressed) |
| CB-IDEM-015 | A STALE marker from a PRIOR, already-resolved session (SAME head+trailer, DIFFERENT session) is present; a NEW session recurs | Re-evaluates and TRIPS — the stale marker does NOT suppress a fresh re-arm trip (round-12 [BLOCKING], fixes "one-shot only") |
| CB-IDEM-016 | A HUMAN comment QUOTES the exact marker for THIS session | The quote is REJECTED (unauthenticated); the halt still fires — round-12 [BLOCKING] |
| CB-IDEM-017 | Same as CB-IDEM-016, but `BOT_LOGIN` is empty (fallback topology) | The quote is still rejected via `authorKind != "human"` |
| CB-IDEM-018 | A GENUINE (machine-authored) same-session marker is present | Still suppresses (regression guard — the fix must not over-reject true idempotency) |
| CB-REPORT-008 | Trip report content | Contains PR ref (`#<num>`), frozen head SHA, `reason=non-convergence`, "REMOVE the `stalled` label" resume instruction (`autonomous` retained — round-10 owner correction), repeated-failure count, AND the counted rounds' **per-round timestamps** ([P1] round-1 finding 2, not the `(unavailable)` fallback) |
| CB-ATOMIC-013 | Successful trip | `label_swap` (the transition) is called STRICTLY BEFORE `itp_post_comment` (the marker/report) — round-10 [P1] finding 1 |
| CB-ATOMIC-014 | `label_swap` FAILS (transient transport error) under `set -euo pipefail` | Aborts BEFORE the marker/report is posted; no orphan marker; label state unchanged; next tick retries — round-10 [P1] finding 1 |
| CB-COUNT-009a | Stale `failed-non-substantive` rounds precede the active `failed-substantive`+`dev-actionable=true` rounds on the same SHA | Count = only the active-case rounds (stale excluded → no early trip) — [P1] round-1 finding 1 |
| CB-COUNT-009b | A prior `dev-actionable=false` round on the same SHA + genuine active `dev-actionable=true` rounds | The false round is excluded but does NOT zero the active rounds (no forever-suppression) — [P1] round-1 finding 1 |
| CB-COUNT-009c | Active canonical does not match the rounds' verdict | Count = 0 |
| CB-COUNT-009h | The ONLY genuine preceding verdict is non-matching, but a HUMAN comment between it and the round QUOTES a matching trailer | The quote is REJECTED (unauthenticated); the genuine non-matching verdict is used; round excluded (0) — round-11 [P1] BLOCKING |
| CB-COUNT-009i | Same shape, but the impersonating comment is from a DIFFERENT bot (author != BOT_LOGIN) | Rejected regardless of authorKind matching "not human" — round-11 [P1] BLOCKING |
| CB-COUNT-009j | Genuine matching trailer present, PLUS an unrelated human quote | Genuine trailer still counted (regression guard: the fix does not over-reject) |
| CB-COUNT-009k | BOT_LOGIN empty (token-mode fallback) + a human quote (prose before the trailer) of a matching trailer | Quote still rejected via the structural anchor (round-13 [BLOCKING] corrected the mechanism from `authorKind != "human"`) |
| CB-COUNT-009l | Real `GH_AUTH_MODE=token` topology: `BOT_LOGIN` empty AND the genuine verdict trailer's `authorKind` is `human` (shared PAT identity) | Genuine frozen rounds are STILL counted (3) — round-13 [BLOCKING], proves the dead-breaker regression is fixed |
| CB-COUNT-009m | Same token-mode topology, end-to-end | The breaker actually TRIPS (`label_swap pending-dev → stalled` + report) — round-13 [BLOCKING] |
| CB-COUNT-009n | Same token-mode topology, but the human quote has PROSE before the trailer | Still rejected (0) — regression guard: round-11's anti-spoofing protection still holds under round-13's fix |
| CB-COUNT-009o | BOT_LOGIN empty + a forged comment pastes the genuine trailer text and appends MORE content AFTER it | Still rejected (0) — round-14 [Critical]: the bare `startswith` round-13 first shipped would have accepted this; the end-anchored (`^...$`) match closes it |
| CB-SHARED-010 | Source-of-truth | `mark_stalled` and the breaker both call `may_stall_now`; the `pid_alive` liveness block is NOT duplicated |
| CB-DUAL-011 | Trip terminal comment count | Exactly ONE terminal comment (the #297 report); NO `mark_stalled` "@owner retry exhausted" dual-post |
| CB-THRESH-012 | `CONVERGENCE_STALL_THRESHOLD` override honored | With threshold=4, 3 frozen rounds do NOT trip; 4 do |
| MSL-CHAR-011 | `may_stall_now` factoring characterization (in `test-mark-stalled-liveness.sh`) | `mark_stalled` still defers (posts `INV-26-stall-deferral` comment, no stall label) on a live wrapper; still stalls on dead/absent PID — byte-identical to pre-factoring |

## Acceptance criteria coverage

- **AC1** (detect non-convergence + halt): CB-TRIP-001, CB-COUNT-009a/b/c/h/i/j/k/l/m/n/o, CB-THRESH-012.
- **AC2** (single structured report with reason + SHA + repeated findings + human checklist): CB-REPORT-008, CB-DUAL-011.
- **AC3** (converging loops unaffected + idempotent): CB-MISS-002, CB-MISS-003, CB-IDEM-006, CB-IDEM-007, CB-IDEM-015/016/017/018.
- **AC4** (docs updated: dispatcher-flow + INV-103): enforced by the pipeline-docs-gate + TC-SPEC-GATE-040/041 (heading-adjacent triage tag).
- **#298 precedence**: CB-PRECEDENCE-004.
- **live-PID deferral inherited via shared helper**: CB-LIVE-005, CB-SHARED-010, MSL-CHAR-011.
- **marker/transition atomicity** (round-10 [P1] finding 1): CB-ATOMIC-013, CB-ATOMIC-014.
