# Test Cases — dev-resume post-approval findings (INV-57)

Tracks: issue #188.

## Scenario

On `dev-resume`, the dev agent must NOT treat a standing `reviewDecision == APPROVED`
(+ green CI + mergeable) PR as "nothing outstanding" when a **newer** review-findings /
change-request comment was posted to the issue *after* the approval. Two compounding
gaps are covered:

1. **Approved-PR short-circuit** — approval-timestamp vs findings-timestamp ordering
   must govern the done/not-done decision. A wrapper helper
   `emit_post_approval_findings_block` computes this and injects an explicit
   "do NOT exit — outstanding post-approval findings" override block into the resume
   prompt.
2. **Brittle marker matching** — the `REVIEW_COMMENTS` selector must recognize findings
   beyond the exact `Review findings:` prefix (also a `BLOCKING` / `[P1]` change-request
   comment), without re-introducing the #113 dispatcher-chatter false positives.

## Part A — `REVIEW_COMMENTS` selector (extends test-resume-review-comments-filter.sh)

| ID | Comments fixture (chronological) | Expected match | Side of fix |
|----|---|---|---|
| TC-RFB-001..008 | (existing #113 cases) | unchanged | both |
| TC-RFB-009 | A `## Codex review findings` comment carrying `[P1]`/`BLOCKING` (no `Review findings` prefix) | the findings comment | post-fix only |
| TC-RFB-010 | A bare operator note `[P1] BLOCKING: data race in submitFeed — please fix` | the note | post-fix only |
| TC-RFB-011 | Real `Review findings` AT T0, then a dispatcher status `Moving to pending-review for assessment` AT T1 (no BLOCKING token) | the real findings (broadened clause does NOT pull the status) | both (regression guard) |
| TC-RFB-012 | Real `Review findings` AT T0, then a later `remaining items are NON-BLOCKING` note AT T1 | the real findings (the look-behind `(?<![A-Za-z-])` rejects the hyphenated `NON-BLOCKING`) | post-fix only |
| TC-RFB-013 | A sole `remaining items are NON-BLOCKING` note (no real findings) | empty (not a finding) | post-fix only |
| TC-RFB-014 | Real findings AT T0, then `Review PASSED - No BLOCKING issues remain` AT T1 | the PASS verdict (latest; matched by the PASS prefix clause, not the token clause) | both (PASS prefix) |
| TC-RFB-015 | Real findings AT T0, then a dev `## ✅ Implementation complete` comment with tokens AT T1 | the real findings (status comment excluded from the token clause — **review finding 2**) | post-fix only |
| TC-RFB-016 | A sole `**Agent Session Report**` comment with tokens | empty (status, not a finding) | post-fix only |

## Part B — `emit_post_approval_findings_block` (test-dev-resume-post-approval-findings.sh)

The helper is extracted from `autonomous-dev.sh` via awk and run with a stubbed `gh`
that returns scenario-specific JSON for `gh pr view --json reviews` and
`gh issue view --json comments`.

| ID | Approval submittedAt | Newest findings createdAt / body | Expected |
|----|---|---|---|
| TC-PAF-001 | APPROVED @ 2026-06-08T07:00:00Z | `Review findings: [P1] …` @ 2026-06-08T08:00:00Z | block EMITTED (findings newer than approval) |
| TC-PAF-002 | APPROVED @ 2026-06-08T08:00:00Z | `Review findings: …` @ 2026-06-08T07:00:00Z | block NOT emitted (approval is newest — genuinely done) |
| TC-PAF-003 | APPROVED @ 2026-06-08T07:00:00Z | none | block NOT emitted (no findings at all) |
| TC-PAF-004 | (no approval) | `Review findings: [P1] …` @ T2 | block EMITTED (findings with no approval ⇒ outstanding) |
| TC-PAF-005 | APPROVED @ T1 | `## Codex review findings` + `[P1]` @ T2>T1 (non-prefix) | block EMITTED (broadened recognition) |
| TC-PAF-006 | `gh` errors (non-zero) | — | block NOT emitted (fail-closed); helper returns cleanly, no `set -e` abort |
| TC-PAF-007 | APPROVED @ T1 | `Review PASSED` @ T2>T1 (a PASS, not findings) | block NOT emitted (a PASS is not outstanding work) |
| TC-PAF-008 | APPROVED @ T1 | operator `[P1] BLOCKING: …` note @ T2>T1 | block EMITTED (operator note recognized) |
| TC-PAF-009 | APPROVED @ T1 | `remaining items are NON-BLOCKING` note @ T2>T1 | block NOT emitted (look-behind rejects `NON-BLOCKING`) |
| TC-PAF-010 | approval query (`gh pr view`) FAILS; findings query succeeds with findings | block NOT emitted + returns 0 (**review finding 1**: query failure ≠ "no approval") |
| TC-PAF-011 | APPROVED @ T1 | `Review PASSED - No BLOCKING issues remain` @ T2>T1 | block NOT emitted (**review finding 2**: PASS verdict is not a finding even with the token) |
| TC-PAF-012 | APPROVED @ T1 | `## ✅ Implementation complete …` with `[P1]`/`BLOCKING` in prose @ T2>T1 | block NOT emitted (dev status, not a change-request) |
| TC-PAF-013 | APPROVED @ T1 | `**Agent Session Report**` with tokens @ T2>T1 | block NOT emitted (status, not a finding) |

## Part C — Prompt wiring + doc contract (source-of-truth greps)

| ID | Assertion |
|----|---|
| TC-PAF-W01 | `emit_post_approval_findings_block` is defined in `autonomous-dev.sh` |
| TC-PAF-W02 | The emitted block names "post-approval" findings and tells the agent NOT to exit "nothing outstanding" despite APPROVED/mergeable |
| TC-PAF-W03 | The block helper output is interpolated into the resume prompt builder(s) |
| TC-PAF-W04 | `autonomous-dev.sh` still passes `bash -n` and `shellcheck -S error` |
| TC-PAF-D01 | `autonomous-mode.md` Resume Awareness documents approval-vs-findings timestamp ordering governing the exit decision |
| TC-PAF-D02 | `autonomous-mode.md` documents broadened findings recognition (BLOCKING/`[P1]`, not only the exact `Review findings:` prefix) |
| TC-PAF-D03 | INV-57 exists in `invariants.md` and is referenced from `dev-agent-flow.md` |

## Part D — RE2 engine compatibility (`test-resume-selector-re2-compat.sh`, review round 2)

`gh --jq` runs Go's RE2 engine (no look-behind/look-ahead); the unit tests above stub `gh`
via the system `jq` (Oniguruma, which DOES support look-behind), so a look-behind in the
selector passes the stubbed tests but fails at runtime. Round 2 (kiro) caught a
`(?<![A-Za-z-])BLOCKING` look-behind that RE2 rejected — disabling the override and
aborting the wrapper under `set -e`. These cases guard the engine boundary directly.

| ID | Assertion | Layer |
|----|---|---|
| TC-RE2-01 | The resume `-q` findings selector line(s) are locatable in `autonomous-dev.sh` | static |
| TC-RE2-02 | Neither resume selector contains an RE2-incompatible look-behind/look-ahead (`(?<`, `(?=`, `(?!`) | static (CI-enforced) |
| TC-RE2-03 | The RE2-compatible consuming anchor `(^\|[^A-Za-z-])BLOCKING` IS present (NON-BLOCKING guard intact) | static |
| TC-RE2-04 | Real `gh --jq` (Go RE2) COMPILES the token regex (no `invalid regular expression`) | real-engine (best-effort) |
| TC-RE2-05 | `[P1] BLOCKING` matches under real RE2 | real-engine |
| TC-RE2-06 | `[BLOCKING] …` (bracketed review format) matches under real RE2 | real-engine |
| TC-RE2-07 | `NON-BLOCKING` does NOT match under real RE2 | real-engine |

Real-engine cases (04..07) skip (not fail) when the `gh` binary or a token/network is
unavailable, so a tokenless CI run still enforces the static guard (01..03).

## Acceptance

- TC-RFB-009, 010, 005-by-broadening pass only after the selector is broadened;
  TC-RFB-001..008, 011 stay green on both sides.
- TC-PAF-001, 004, 005 (emit) and TC-PAF-002, 003, 006, 007 (no-emit) all hold after
  the fix; the emit-cases fail before the helper exists.
- Doc and INV cross-reference assertions pass after the doc updates land.
