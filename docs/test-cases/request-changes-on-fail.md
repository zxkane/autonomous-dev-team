# Test Cases — Wrapper owns the GitHub-native review action (INV-52, #193)

Strategy: source-of-truth greps over `autonomous-review.sh` + the agent-facing
docs. The wrapper is too heavy to run end-to-end (spawns agents, makes `gh`
calls), so we pin structural invariants in the source — the same strategy as
`test-autonomous-review-auto-merge-failure.sh` and `…-mergeable-gate.sh`.

The unit test for the **pure helper** (`submit_request_changes`) DOES execute it
against a stubbed `gh`, so the regression has an executable fail-before/pass-after
assertion in addition to the source greps.

## Unit tests — `tests/unit/test-autonomous-review-request-changes.sh`

### Group 1 — helper behavior (executable, with stubbed `gh`)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RC-FN-01 | `submit_request_changes` calls `gh pr review --request-changes` (not `--approve`) | stub records `pr review … --request-changes` |
| TC-RC-FN-02 | helper passes the PR number and `--body` | stub args contain `<pr>` and `--body` |
| TC-RC-FN-03 | `gh` exits non-zero (simulated 403) → helper returns 0 (non-fatal), logs a warning | helper rc == 0; warning emitted |
| TC-RC-FN-04 | helper succeeds → returns 0 | helper rc == 0 |

### Group 2 — wrapper wiring (source-of-truth greps)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RC-SRC-01 | helper `submit_request_changes` is defined | grep finds the definition |
| TC-RC-SRC-02 | the wrapper calls the helper on every substantive FAIL route (≥3) | helper invoked on the agent-findings FAIL, CONFLICTING block, and E2E hard-gate fail routes |
| TC-RC-SRC-03 | the merge-conflict (`block-substantive`) route calls the helper | helper invoked before its `−reviewing +pending-dev` |
| TC-RC-SRC-04 | helper called on EXACTLY the 3 substantive routes — non-substantive routes excluded | count == 3 (no UNKNOWN / e2e-evidence-missing / crash call) |
| TC-RC-SRC-04b | the E2E hard-gate FAIL route (`failed-substantive`, INV-46) calls the helper | helper invoked in the `[BLOCKING] E2E verification failed` branch |
| TC-RC-SRC-04c | the E2E `block-nonsubstantive` (evidence-missing) route does NOT call the helper | no helper call in that branch |
| TC-RC-SRC-05 | the crash-without-verdict path does NOT call the helper | helper gated behind a posted verdict |
| TC-RC-SRC-06 | every helper call is best-effort (`|| log` / `|| true`, never bare under `set -e`) | no un-guarded `submit_request_changes` |
| TC-RC-SRC-07 | PASS branch still submits `--approve` (regression pin) | `gh pr review … --approve` still present exactly on the PASS path |
| TC-RC-SRC-08 | PASS and REQUEST_CHANGES are mutually exclusive | `--approve` and `submit_request_changes` live in different branches of the `PASSED_VERDICT` split |
| TC-RC-SRC-09 | helper body references the findings (links/summarizes) | helper `--body` mentions findings |
| TC-RC-SRC-10 | wrapper passes `bash -n` | no syntax error |

**The three substantive FAIL routes that submit REQUEST_CHANGES** (each a dev-actionable blocking verdict):
1. **Agent-posted findings** — the `Review findings:` FAIL branch (`failed-substantive`).
2. **CONFLICTING mergeable block** — the INV-44 `block-substantive` route.
3. **E2E hard-gate failure** — the INV-46 `E2E_GATE == fail` route (lane rc≠0, runs before the review fan-out). *(Added in response to #197 codex review finding — the broad AC "a blocking FAIL verdict must result in `reviewDecision == CHANGES_REQUESTED`" covers this route too.)*

**Non-substantive routes that must NOT request changes** (transient / transport, not dev-actionable): mergeable-`UNKNOWN` re-queue, E2E-`evidence-missing` re-queue, and the agent-crash-with-no-verdict path.

### Group 3 — agent-side framing (source-of-truth greps over docs)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-RC-DOC-01 | SKILL.md no longer frames the agent's job as "approve + merge" | the bare "approve + merge" license is gone / re-scoped to the wrapper |
| TC-RC-DOC-02 | SKILL.md states the agent must NOT run `gh pr review`/`gh pr merge` | explicit prohibition present |
| TC-RC-DOC-03 | decision-gate.md action-pairing table: agent action is "post comment", not "Submit APPROVE review" | table re-scoped to the wrapper owning the native action |
| TC-RC-DOC-04 | INV-52 exists in invariants.md and is referenced from review-agent-flow.md | both present |

## Acceptance Criteria mapping

- AC "blocking FAIL → `reviewDecision == CHANGES_REQUESTED`" → TC-RC-FN-01, TC-RC-SRC-02/03.
- AC "`--request-changes` is best-effort (non-fatal)" → TC-RC-FN-03, TC-RC-SRC-06.
- AC "subsequent PASS re-approves new HEAD" → TC-RC-SRC-07 (approve retained) + INV-52/flow-doc note (Change B).
- AC "agent never approves/merges" → TC-RC-DOC-01/02/03.
- AC "docs updated in same PR" → TC-RC-DOC-04.

## Regression gate (must stay green)

`test-autonomous-review-auto-merge-failure.sh`, `…-mergeable-gate.sh`,
`…-multi-agent.sh`, `…-verdict-trailer.sh`, `…-prompt.sh` — the new helper adds a
PR-review call on FAIL but changes no label transition, posts no `gh issue close`,
and does not touch the `−autonomous` accounting, so the #145 / INV-44 pins hold.
