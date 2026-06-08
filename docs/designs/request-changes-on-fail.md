# Design — Wrapper owns the GitHub-native PR review/merge action (INV-52, #193)

## Problem

Two halves of one invariant, surfaced by the live incident on PR #191 / issue #190:

1. **FAIL half (original #193 scope).** When `autonomous-review.sh` reaches a
   blocking **FAIL** verdict it posts only a `Review findings:` comment on the
   **issue** and does NOT submit a GitHub PR review with `REQUEST_CHANGES`. The
   PR's native `reviewDecision` therefore stays non-blocking
   (`APPROVED`/`REVIEW_REQUIRED`) for every consumer — humans browsing the PR,
   branch protection, the dispatcher, the dev-resume agent. A PR with known
   P1 defects looks mergeable to anyone not parsing the issue comment thread.
   This is the root cause behind #188.

2. **PASS half (incident scope).** The review **agent** ran `gh pr review
   --approve` on PR #191 itself ~18 min BEFORE the wrapper's gates ran, so the
   **INV-44 mergeable hard gate** and the **`no-auto-close` skip-merge** were
   bypassed: an `UNKNOWN`-mergeable PR on a `no-auto-close` issue got merged.
   The driver: `SKILL.md` told the agent its job is "approve + merge" while the
   wrapper assumed only the wrapper approves/merges. The agent followed the prompt.

## Invariant (INV-52)

**The review WRAPPER owns the GitHub-native PR review/merge action — both
`--approve` (PASS, after the INV-44 mergeable + `no-auto-close` gates) and
`--request-changes` (substantive FAIL). The review AGENT posts verdict comments
only; it MUST never run `gh pr review --approve`, `gh pr review --request-changes`,
or `gh pr merge`.**

## Change Set

### A. Wrapper FAIL → REQUEST_CHANGES (the durable-state half)

Add a small best-effort helper `submit_request_changes <pr> <body>` next to the
existing `--approve` call, and call it on the **substantive** FAIL routes so
`reviewDecision == CHANGES_REQUESTED`:

| FAIL route | Submit REQUEST_CHANGES? | Why |
|---|---|---|
| Agent posted blocking findings (`failed-substantive`, main FAIL branch) | **YES** | dev-actionable blocking findings — assert the blocking state on the PR |
| Merge conflict (`block-substantive`, INV-44) | **YES** | a `CONFLICTING` PR is a real blocking finding the dev must rebase |
| E2E hard-gate failure (`E2E_GATE == fail`, INV-46, runs before fan-out) | **YES** | a failed E2E is a dev-actionable blocking FAIL — added in response to the #197 codex review finding; the AC ("a blocking FAIL verdict must result in `reviewDecision == CHANGES_REQUESTED`") is route-agnostic |
| Mergeable UNKNOWN (`block-nonsubstantive`, INV-44) | **NO** | transient GitHub-side hold, re-queued for re-review — not a code defect; a standing CHANGES_REQUESTED would falsely accuse the dev |
| E2E evidence missing (`block-nonsubstantive` cause `e2e-evidence-missing`, INV-46) | **NO** | transient comment-propagation hold, re-queued — not a code defect |
| Agent crash, no verdict (`failed-non-substantive other`) | **NO** | transport/mid-stream crash, not a finding — REQUEST_CHANGES would be misleading |

> The substantive set is defined by "the verdict is a real, dev-actionable
> blocking FAIL", NOT by which gate produced it — so any future gate that emits
> `failed-substantive` should also request changes.

Discipline (matches the dev-resume side and the existing approve fallback):

- **Best-effort under `set -e`**: the call is `submit_request_changes … || log …`.
  A 403 / transient failure MUST NOT abort the wrapper and strand the issue in
  `reviewing`. The FAIL route still flips the label to `pending-dev` regardless.
- The review body summarizes / links the `Review findings:` issue comment so a
  human reading the PR's Files-changed tab sees why it's blocked.
- Mutual exclusion: PASS submits `--approve`; substantive FAIL submits
  `--request-changes`. They are never both submitted in one run (separate
  branches of the `if [[ "$PASSED_VERDICT" == "true" ]]` split).

### B. Next-PASS supersedes a standing CHANGES_REQUESTED

The PASS path already submits `gh pr review --approve` against the new HEAD
(`:1545`). A fresh APPROVE from the same reviewer supersedes the prior
`CHANGES_REQUESTED` (and `dismiss-stale-reviews-on-push` branch protection, if
configured, dismisses it on the dev's force-push). No code change needed beyond
documenting it — the approve already targets the new HEAD. No permanently-stuck
`CHANGES_REQUESTED`.

### C. Agent-side framing fix (the incident half)

Replace "approve + merge" framing with "post your verdict; the wrapper
approves/merges after its gates" in:

- `skills/autonomous-review/SKILL.md` — overview (`:28`), When-to-Use (`:34`),
  decision summary (`:256`), multi-agent section (`:267`). Add an explicit
  "Who submits the GitHub-native action" rule: the agent NEVER runs `gh pr
  review --approve` / `gh pr review --request-changes` / `gh pr merge`.
- `skills/autonomous-review/references/decision-gate.md` — the PASS/FAIL
  decision criteria (`:58`, `:73`) and the action-pairing table (`:102-108`):
  the agent's "action" is posting the verdict **comment**, NOT a GitHub review.

The wrapper-injected prompt's Decision section (`autonomous-review.sh:773-814`)
is already correct (it says "Post a comment … Then exit" — no approve/merge), so
it needs only a one-line reinforcement that the wrapper owns the native action.

### D. Optional mechanical backstop (NOT implemented)

The issue lists "consider tool-deny `gh pr merge`/`gh pr review --approve`" as
optional. The review agent runs headless under `--dangerously-skip-permissions`
(lib-agent.sh), so a per-tool deny-list is not reliably enforceable there. The
robust enforcement is the prompt rule (C) backed by the wrapper owning the action
(A/B). Recorded as a rejected alternative in INV-52 so it is not re-attempted.

## Files Touched

- `skills/autonomous-dispatcher/scripts/autonomous-review.sh` — `submit_request_changes` helper + calls on the two substantive FAIL routes.
- `skills/autonomous-review/SKILL.md` — framing fix + wrapper-owns-action rule.
- `skills/autonomous-review/references/decision-gate.md` — action-pairing fix.
- `docs/pipeline/invariants.md` — new INV-52.
- `docs/pipeline/review-agent-flow.md` — REQUEST_CHANGES in the FAIL paths + PASS-supersedes note.
- `docs/pipeline/state-machine.md` — note that `reviewing → pending-dev` (substantive) also sets `reviewDecision=CHANGES_REQUESTED`.
- `tests/unit/test-autonomous-review-request-changes.sh` — new regression test.
- `docs/test-cases/request-changes-on-fail.md` — test plan.

## Invariant numbering

INV-51 was taken by #194 (codex review resume loop, merged to main). Highest
committed is INV-51 → this PR is **INV-52** (per the owner's numbering heads-up
on the issue).
```
