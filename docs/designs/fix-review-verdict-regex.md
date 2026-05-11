# Fix: review wrapper's verdict regex is brittle to agent phrasing drift

**Date:** 2026-05-11
**Issue:** #95
**Status:** Approved

## Problem

`autonomous-review.sh` polls for the agent's verdict comment with this jq
filter (line 474):

```jq
.body | test("Review PASSED|Review findings:"; "i")
```

then branches on (line 498):

```bash
echo "$LATEST_COMMENT" | head -1 | grep -qi "^Review PASSED"
```

Both are brittle. If the agent posts a verdict comment that doesn't begin
with `Review PASSED` (or contain `Review findings:`), the polling returns
empty → the FAILED branch fires → label flips to `pending-dev` → dev
agent resumes, finds no new commits, posts back to `pending-review` →
review re-runs with same prompt → same wording mismatch → `pending-dev`.
The loop runs every cron interval until `MAX_RETRIES` and the issue is
marked `stalled`.

The issue reports a real-world incident where the agent wrote
`**APPROVED FOR MERGE**` instead. In practice agents (especially
non-Claude models) drift across `Review APPROVED`, `Approved`, `LGTM`,
`Review PASS`, etc. The current regex matches none of these and the
script falls through silently.

The session-id binding on line 474 (`Review Session.*${SESSION_ID}`) is
still required for security — without it a stray third-party comment
could spoof a verdict. We keep that.

## Fix

Two parts.

### Part 1 — broaden the verdict regex (the bug)

Recognize the common pass/fail phrasings while keeping the session-id
binding:

- **Pass**: `Review PASSED`, `Review APPROVED`, `APPROVED FOR MERGE`,
  `LGTM`, `Review PASS`. Case-insensitive. Match anywhere in the
  comment body, not just at the start, because some agents lead with
  a heading line then put the verdict on line 2. We deliberately do
  NOT include the bare word `Approved` — it matches too liberally
  (e.g. "PR approved by CI" in a quoted CI status snippet).
- **Fail**: `Review findings:`, `Review FAILED`, `Review REJECTED`,
  `Changes requested`. Same case-insensitive, anywhere-in-body match.

Two-step decision after polling:

1. Polling jq filter accepts any of the union (pass-or-fail patterns).
2. Branch logic re-checks the comment against the **pass**-only patterns
   to decide pass vs. fail. If a comment matched only on a fail-pattern
   (or is ambiguous — both patterns appear), fall through to FAILED.

### Part 2 — prompt nudge for canonical phrasing (defense in depth)

Even with a broader regex, prompt the agent more strictly to start the
comment with the canonical `Review PASSED` / `Review findings:` prefix,
and to put it on the FIRST LINE of the comment. This reduces drift in
the first place. Cheap to add; harmless if the agent ignores it because
Part 1 catches the drift.

### What we deliberately do NOT change

- The session-id security filter — keep it as-is.
- `head -1` constraint after broadening — drop it, since some agents
  put the verdict on line 2 after a heading. The session-id filter
  alone provides the authenticity binding; line position doesn't add
  security.
- The cleanup trap or its label transitions — they're correct as-is.
  This bug is purely in the verdict-detection step.
- `autonomous-dev.sh` — separate wrapper, not implicated.

### Files changed

- `skills/autonomous-dispatcher/scripts/autonomous-review.sh` —
  broader regex; prompt clarification.
- `tests/unit/test-autonomous-review-verdict-regex.sh` — new.

## Acceptance

- Agent comment starting with `Review PASSED ... Review Session: <id>`
  → PASSED branch fires (regression baseline).
- Agent comment starting with `**APPROVED FOR MERGE** ... Review
  Session: <id>` → PASSED branch fires (the issue's scenario).
- Agent comment containing `LGTM ... Review Session: <id>` → PASSED.
- Agent comment starting with `Review findings: ... Review Session:
  <id>` → FAILED branch fires.
- Agent comment starting with `Review FAILED ... Review Session: <id>`
  → FAILED.
- Agent comment from a different session ID → polling timeout (no
  spoofing).
