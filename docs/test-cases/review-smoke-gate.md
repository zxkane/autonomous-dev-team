# Test Cases: Review wrapper Phase A.5 smoke gate (issue #224, INV-64)

Test IDs: `TC-REVIEW-SMOKE-NNN`.

Two harnesses (the wrapper is too heavy to run end-to-end, mirroring the INV-46
`test-autonomous-review-sequential-e2e.sh` pattern):

1. **Pure-logic** — source `lib-review-smoke.sh` in isolation and drive its
   decision functions (`_classify_smoke_gate`, `_smoke_evidence_reason`,
   `_classify_smoke_state`) directly.
2. **Source-of-truth greps** — assert the wrapper wires Phase A.5 in the right
   place (after the E2E lane, before the fan-out loop), uses explicit-PID `wait`,
   resolves per-agent model/launcher, and the default-off inertness holds.

---

## Gate decision (`_classify_smoke_gate`) — pure truth table

| ID | Input states | Expected gate |
|---|---|---|
| TC-REVIEW-SMOKE-001 | `pass pass` | `pass` |
| TC-REVIEW-SMOKE-002 | `pass unavailable` | `pass` (drop the unavailable, others vote) |
| TC-REVIEW-SMOKE-003 | `unavailable unavailable` | `all-unavailable` |
| TC-REVIEW-SMOKE-004 | `pass fail` | `fail` (any FAIL aborts) |
| TC-REVIEW-SMOKE-005 | `fail unavailable` | `fail` (FAIL dominates UNAVAILABLE) |
| TC-REVIEW-SMOKE-006 | `unavailable fail pass` | `fail` (FAIL dominates regardless of order) |
| TC-REVIEW-SMOKE-007 | single `pass` | `pass` |
| TC-REVIEW-SMOKE-008 | single `unavailable` | `all-unavailable` |
| TC-REVIEW-SMOKE-009 | single `fail` | `fail` |
| TC-REVIEW-SMOKE-010 | empty arg list | `pass` (no members → nothing to gate; defensive) |
| TC-REVIEW-SMOKE-011 | unknown state token (`weird`) | `fail` (defensive — an unrecognized state is gate-worthy, never silently passed) |

**Decision precedence (load-bearing):** FAIL > all-UNAVAILABLE > pass. A single
FAIL anywhere in the list forces `fail`; only when there is no FAIL and *every*
member is UNAVAILABLE does it become `all-unavailable`; otherwise `pass`.

---

## Drop-reason extraction (`_smoke_evidence_reason`)

| ID | Input evidence line | Expected reason |
|---|---|---|
| TC-REVIEW-SMOKE-020 | `SMOKE agy UNAVAILABLE 3s reason=quota-exhausted (Antigravity 429; resets in 2h)` | `quota-exhausted (Antigravity 429; resets in 2h)` |
| TC-REVIEW-SMOKE-021 | `SMOKE codex FAIL 1s reason=config-error:--bad-flag` | `config-error:--bad-flag` |
| TC-REVIEW-SMOKE-022 | `SMOKE kiro FAIL 0s reason=no-response (rc=1; nonce absent from CLI output)` | `no-response (rc=1; nonce absent from CLI output)` |
| TC-REVIEW-SMOKE-023 | a line with no `reason=` tail | empty (no over-claim) |
| TC-REVIEW-SMOKE-024 | empty string | empty |
| TC-REVIEW-SMOKE-025 | multi-line capture (evidence line not last) | reason from the `SMOKE …` line, ignoring trailing noise |

---

## Per-member smoke run (`_classify_smoke_state`) — stubbed `smoke_agent`

The wrapper's parallel loop calls `_classify_smoke_state`, which invokes
`smoke_agent` and records the state + evidence to sidecar files. Stub
`smoke_agent` to assert the rc→state mapping and the evidence capture.

| ID | Stub `smoke_agent` behavior | Expected state in rc-file | Evidence captured |
|---|---|---|---|
| TC-REVIEW-SMOKE-030 | prints PASS line, returns 0 | `pass` | the PASS evidence line |
| TC-REVIEW-SMOKE-031 | prints UNAVAILABLE line, returns 2 | `unavailable` | the UNAVAILABLE line |
| TC-REVIEW-SMOKE-032 | prints FAIL line, returns 1 | `fail` | the FAIL line |
| TC-REVIEW-SMOKE-033 | set -e discipline: a non-zero `smoke_agent` does NOT abort `_classify_smoke_state`; the rc-file is always written | (state per rc) | written |

---

## Wrapper-level source-of-truth + stub-mode

| ID | Assertion |
|---|---|
| TC-REVIEW-SMOKE-040 | wrapper sources `lib-review-smoke.sh` |
| TC-REVIEW-SMOKE-041 | Phase A.5 smoke block appears AFTER the INV-46 `_run_command_e2e_lane` call / E2E gate, and BEFORE the `for _agent in "${REVIEW_AGENTS_LIST` fan-out loop |
| TC-REVIEW-SMOKE-042 | Phase A.5 is gated on `REVIEW_SMOKE_ENABLED` (default-off: the block is entered only when true) |
| TC-REVIEW-SMOKE-043 | the smoke parallel loop waits on **collected PIDs** (`wait "${_smoke_pids[@]}"`), never a bare `wait` (regression pin against the #167-class hang) |
| TC-REVIEW-SMOKE-044 | the smoke resolves each member's model via `_resolve_review_agent_model`, applies the INV-38/INV-42 launcher treatment, AND resolves+applies the per-agent review EXTRA-ARGS (`_resolve_review_agent_extra_args` → both `AGENT_DEV_EXTRA_ARGS` + `AGENT_REVIEW_EXTRA_ARGS`, before `_classify_smoke_state`) — the SAME resolution the fan-out uses (#224 review [P1]: without the extra-args rebind, `smoke_agent`'s `run_agent` reads the stale dev args, not the resolved per-agent review args) |
| TC-REVIEW-SMOKE-045 | FAIL-abort path: posts an issue comment naming the failed agent(s) + the SMOKE evidence, sets `RESULT_PARSED=true`, does NOT add `pending-dev`, emits a verdict trailer, and exits non-zero |
| TC-REVIEW-SMOKE-046 | FAIL-abort does NOT spawn the fan-out (the `for _agent` loop is downstream of the abort `exit`) |
| TC-REVIEW-SMOKE-047 | UNAVAILABLE-drop path: a dropped member is removed from `REVIEW_AGENTS_LIST` before the fan-out and the drop reason carries the `smoke:` prefix |
| TC-REVIEW-SMOKE-048 | all-UNAVAILABLE: the surviving set is empty → the wrapper drives the existing all-unavailable fallback (no empty fan-out spawned) |
| TC-REVIEW-SMOKE-049 | `bash -n` parses the wrapper + lib clean; shellcheck clean |
| TC-REVIEW-SMOKE-050 | default-off regression: with `REVIEW_SMOKE_ENABLED` unset/false, `smoke_agent` is NOT invoked and the fan-out set equals `REVIEW_AGENTS_LIST` unchanged (grep that the smoke block is guarded) |
| TC-REVIEW-SMOKE-051 | the smoke runs strictly before the fan-out clock — assert no `post-verdict`/verdict-comment call inside the smoke block (the smoke must not pollute the INV-40 attribution window) |

---

## E2E (wrapper-level stub)

| ID | Assertion |
|---|---|
| TC-REVIEW-SMOKE-060 | Stub-mode wrapper run (`REVIEW_SMOKE_ENABLED=true`, stub `smoke_agent`/stub `gh`): a mixed fleet with one UNAVAILABLE member completes the fan-out over the survivors; a FAIL member aborts before fan-out with the naming comment and a non-zero rc and the label still `reviewing` |
| TC-REVIEW-SMOKE-061 | Operator verification steps documented (enable on one onboarded project, dispatch a review, confirm SMOKE lines in the wrapper log + correct fan-out set) — see design doc + invariants INV-64 |

---

## Acceptance-criteria coverage

- **Flag off → all existing review wrapper unit tests pass unchanged** → TC-REVIEW-SMOKE-050 + the existing suite running green.
- **Flag on + quota-walled member → review completes with that member dropped (`smoke: quota-exhausted…`), verdict aggregates over the rest** → TC-REVIEW-SMOKE-002/020/047.
- **Flag on + misconfigured member → abort before fan-out, naming comment, issue stays `reviewing`** → TC-REVIEW-SMOKE-004/045/046.
- **ShellCheck passes; CI green** → TC-REVIEW-SMOKE-049.
- **Docs updated (INV-64, review-agent-flow, state-machine reviewed)** → asserted by the doc-presence greps in the test file.
