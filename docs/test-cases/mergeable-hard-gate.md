# Test Cases: Wrapper-enforced mergeable hard gate (issue #176, INV-44)

Test file: `tests/unit/test-autonomous-review-mergeable-gate.sh`

Two pronged, mirroring the existing review-wrapper tests
(`test-autonomous-review-multi-agent.sh`):

1. **Pure decision-logic harness** — source `lib-review-mergeable.sh` and drive
   `_classify_mergeable_gate` over the full input space.
2. **Source-of-truth greps** against `autonomous-review.sh` — assert the gate is
   wired in on the PASS path with the right routing, without executing the
   (too-heavy) wrapper end-to-end.

## 1. Pure decision logic — `_classify_mergeable_gate <mergeable>`

| TC ID            | Input         | Expected echo          | Rationale |
|------------------|---------------|------------------------|-----------|
| TC-MG-CLS-01     | `MERGEABLE`   | `proceed`              | Happy path: approve/merge unchanged. |
| TC-MG-CLS-02     | `CONFLICTING` | `block-substantive`    | Real conflict; dev must rebase. |
| TC-MG-CLS-03     | `UNKNOWN`     | `block-nonsubstantive` | GitHub still computing; re-queue, never auto-approve. |
| TC-MG-CLS-04     | `` (empty)    | `block-nonsubstantive` | Failed `gh` call → conservative block. |
| TC-MG-CLS-05     | `garbage`     | `block-nonsubstantive` | Unknown token → conservative block (never `proceed`). |
| TC-MG-CLS-06     | `mergeable` (lowercase) | `proceed`    | Case-insensitive accept of the documented states. |
| TC-MG-CLS-07     | `conflicting` (lowercase) | `block-substantive` | Case-insensitive. |

**Key property (closes the stale-UNKNOWN pass-through):** the ONLY input that
yields `proceed` is a case-insensitive `MERGEABLE`. Everything else blocks.

## 2. Source-of-truth greps — `autonomous-review.sh`

| TC ID            | Assertion |
|------------------|-----------|
| TC-MG-SRC-01     | Wrapper sources `lib-review-mergeable.sh`. |
| TC-MG-SRC-02     | Gate queries `gh pr view ... --json mergeable` on the PASS path. |
| TC-MG-SRC-03     | Gate calls `_classify_mergeable_gate`. |
| TC-MG-SRC-04     | Gate is guarded by `PASSED_VERDICT` == true (only runs when aggregate PASSed). |
| TC-MG-SRC-05     | CONFLICTING path posts a `[BLOCKING] Merge conflict` finding. |
| TC-MG-SRC-06     | CONFLICTING path posts an `Auto-merge failed:` marker on the PR (reuses dev-resume rebase hook). |
| TC-MG-SRC-07     | CONFLICTING path emits `failed-substantive` trailer. |
| TC-MG-SRC-08     | UNKNOWN path emits `failed-non-substantive` with cause `mergeable-unknown`. |
| TC-MG-SRC-09     | Both block paths flip `−reviewing +pending-dev`. |
| TC-MG-SRC-10     | UNKNOWN retry loop reads `MERGEABLE_RETRIES`. |
| TC-MG-SRC-11     | Wrapper passes `bash -n`. |
| TC-MG-SRC-12     | `emit_verdict_trailer` count grew by exactly 2 (the gate's two block paths) — no other call site disturbed. |

## 3. Behavioural scenarios (covered by greps above; documented for the AC)

| Scenario | Issue AC | Covered by |
|----------|----------|------------|
| `mergeable=CONFLICTING` + ALL agents PASS → aggregate forced FAIL, routed `pending-dev`, conflict finding posted | AC-1, AC-2 | TC-MG-CLS-02 + TC-MG-SRC-04/05/06/07/09 |
| `mergeable=MERGEABLE` + unanimous PASS → approved (no behaviour change) | AC-4 | TC-MG-CLS-01 + TC-MG-SRC-04 (gate evaluates `proceed`, falls through) |
| `mergeable=UNKNOWN` past retry budget → does NOT auto-approve (re-queue) | AC-3 | TC-MG-CLS-03/04/05 + TC-MG-SRC-08/10 |
| Clean-rebase regression (force-push then proceed) preserved | Testing req #4 | Step 0 prompt path is unchanged; the gate only adds a post-aggregation check and never touches the agent's pre-review rebase. Asserted indirectly: existing `test-autonomous-review-prompt.sh` Step-0 assertions stay green + happy-path TC-MG-CLS-01. |

## Regression guards (existing tests must stay green)

- `test-autonomous-review-multi-agent.sh` — aggregation + fan-out unchanged.
- `test-autonomous-review-auto-merge-failure.sh` — `Auto-merge failed:` marker
  prefix is reused by the gate; the no-`gh issue close` and pending-dev pins
  must still hold (the gate posts the marker on the PR, edits labels, never
  closes the issue).
- `test-autonomous-review-prompt.sh` — Step-0 mergeable prompt text retained.
- `test-autonomous-review-verdict-trailer.sh` — trailer schema unchanged; new
  `mergeable-unknown` cause is within the existing `[a-z0-9-]+` whitelist.
