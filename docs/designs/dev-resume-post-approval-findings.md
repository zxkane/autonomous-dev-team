# Design — dev-resume must not short-circuit on a standing APPROVAL when newer review findings exist

Tracks: issue #188. Invariant: **INV-57**.

## Problem

On `dev-resume`, the dev agent declares "nothing outstanding" and exits when the
linked PR is already `reviewDecision == APPROVED` + CI-green + mergeable — even
when a **newer** `Review findings:` comment with BLOCKING items was posted to the
issue *after* the approval. Late-arriving review findings are silently skipped.

Two compounding gaps:

1. **Approved-PR short-circuit.** The resume treats `reviewDecision == APPROVED`
   + green CI + mergeable as terminal and exits before weighing a findings comment
   posted *after* the approval timestamp.
2. **Brittle marker matching.** The wrapper's `REVIEW_COMMENTS` selector keys off the
   exact prefixes `Review findings` / `Review PASSED`. A findings comment that does
   not start with that literal (e.g. `## Codex review findings`, or a bare
   `[P1] BLOCKING …` operator note) is invisible to the resume prompt.

The "nothing outstanding" decision is **agent reasoning** governed by the
`autonomous-mode.md` "Resume Awareness" doc; the marker matching is **wrapper code**
in `autonomous-dev.sh`. The fix touches both.

## Where the logic lives

| Layer | File | Role |
|---|---|---|
| Wrapper (resume prompt builder) | `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` | Selects review feedback + injects prompt blocks |
| Agent reasoning contract | `skills/autonomous-dev/references/autonomous-mode.md` § Resume Awareness | Governs the done/not-done exit decision |
| Spec | `docs/pipeline/dev-agent-flow.md` § "Mode = resume", `docs/pipeline/invariants.md` (new INV-57) | Authoritative |

`autonomous-dev.sh` sources only `lib-agent.sh` + `lib-auth.sh` (NOT `lib-dispatch.sh`),
so the new helper is **inline** in `autonomous-dev.sh`. Adding it inline (an existing,
already-symlinked file) avoids the new-lib-file footgun that would require an
`install-project-hooks.sh` re-run on every onboarded project.

## Approach

### 1. Broaden the `REVIEW_COMMENTS` selector (gap 2)

Current:

```jq
[.comments[] | select(.body | startswith("Review findings") or startswith("Review PASSED"))] | last // empty
```

New — keep the two anchored prefixes (so the #113 dispatcher-chatter regression stays
fixed) AND add a fallback for change-request comments that carry a BLOCKING / `[P1]`
token without the exact prefix:

```jq
[.comments[]
  | select(
      (.body | startswith("Review findings"))
      or (.body | startswith("Review PASSED"))
      or (.body | test("(?i)\\b(BLOCKING|\\[P1\\])\\b") and (.body | test("(?i)review|finding|change")))
    )
] | last // empty
```

The added clause matches a comment containing a BLOCKING/`[P1]` token — broad enough
to catch `## Codex review findings` and `[P1] BLOCKING: …` operator notes. To keep it
from over-matching (issue #188 review finding 2), the token clause carries two guards:
a negative look-behind `(?<![A-Za-z-])BLOCKING\b` rejects `NON-BLOCKING`, and a
first-line exclusion list rejects PASS/APPROVED verdicts, `## ✅` status headings,
`**Agent Session Report`, the `Multi-agent review:`/`Reviewed HEAD:`/`<!-- … -->`
review-wrapper markers, and `Dispatching`/`Resuming`/`Moving to` dispatcher chatter.
The existing #113 dispatcher-chatter exclusion is preserved (those bodies carry no
token anyway, and are now also on the exclusion list).

### 2. Post-approval findings override block (gap 1)

New inline helper `emit_post_approval_findings_block <issue_num> <pr_num>`:

1. Fetch the latest APPROVED review `submittedAt`:
   `gh pr view <pr> --json reviews -q '[.reviews[]? | select(.state=="APPROVED") | .submittedAt] | sort | last // empty'`.
2. Fetch the newest *findings/change-request* issue comment and its `createdAt`
   (same prefix-or-narrowed-token recognition as the selector).
3. **Fire the override** (emit the block) iff a findings comment exists AND
   (no approval exists OR findings `createdAt` > approval `submittedAt`).
4. The block tells the agent: there are **outstanding post-approval review findings**;
   the standing `APPROVED` / mergeable / green-CI state is **stale** and MUST NOT be
   treated as "nothing outstanding"; read the findings, address the BLOCKING items,
   and re-push. Do NOT exit early.

**Fail-closed for the override** (hardened per issue #188 review finding 1): each `gh`
query's exit status is checked **separately** (`if ! var=$(gh …)`) so a query *failure*
is never confused with a successful *empty* result. If the **approval** query fails
(transient/permission/API), the helper returns 0 and emits nothing — it is NOT read as
"no approval" (which would emit). Only an empty result from a query that *succeeded*
counts as "no approval". The existing `REVIEW_COMMENTS` still surfaces the feedback; we
never *fabricate* work. The override is an additive safety signal layered on top of the
always-present feedback.

### 3. Doc change (gap 1, agent contract)

`autonomous-mode.md` § Resume Awareness:
- Step 5 broadened: recognize `Review findings:` **and** any change-request comment
  carrying a `BLOCKING` / `[P1]` token; explicitly note the exact-prefix is no longer
  the sole contract.
- New explicit rule: **a standing `reviewDecision == APPROVED` (or green CI / mergeable
  PR) does NOT by itself mean "nothing outstanding."** If the newest review-findings /
  change-request comment is newer than the latest approval, the resume MUST address it.
  Approval-timestamp vs findings-timestamp ordering governs the done/not-done decision.

## Test strategy (TDD)

Extend `tests/unit/test-resume-review-comments-filter.sh` (selector regression — new
broadened-marker cases TC-RFB-009..011, existing TC-RFB-001..008 stay green) and add
`tests/unit/test-dev-resume-post-approval-findings.sh` driving
`emit_post_approval_findings_block` against mocked `gh` to assert:

- APPROVED@T1 + findings@T2>T1 → block emitted (outstanding work).
- APPROVED@T1, no newer findings → block NOT emitted (no false rework).
- Findings carrying `[P1]`/`BLOCKING` without the exact prefix → recognized.
- `gh` error → block NOT emitted (fail-closed), wrapper does not abort under `set -e`.

Plus a doc-contract assertion (autonomous-mode.md mentions timestamp ordering + the
broadened recognition; INV-57 exists and is referenced from dev-agent-flow.md).

## Out of scope

- Dismissing the stale GitHub approval automatically (the issue lists it as "Optional").
  Left out to keep blast radius minimal — the override block + broadened recognition
  already satisfy the acceptance criteria. The review wrapper already owns `reviewDecision`
  (INV-52); a post-approval operator findings comment is the human-in-the-loop path.
