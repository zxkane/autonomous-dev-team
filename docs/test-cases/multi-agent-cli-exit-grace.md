# Test Cases: a non-zero CLI exit must not drop a review agent while the poll window is open

Issue: #180 (sibling clarification of #172 / INV-43)
Design: [`docs/designs/multi-agent-cli-exit-grace.md`](../designs/multi-agent-cli-exit-grace.md)
Test file: `tests/unit/test-review-cli-exit-grace.sh`

## Background

The per-agent verdict-poll loop in `autonomous-review.sh` runs AFTER the fan-out
`wait`, so every agent CLI has already exited and `AGENT_LAUNCH_RC` is fully
populated before round 1. The pre-#180 code resolved any non-zero-rc agent to
`unavailable` on round 1 — before its verdict comment could propagate — so a
multi-agent command-mode review could structurally degrade to whichever agent's
verdict propagated fastest.

The fix removes the early short-circuit: a no-verdict agent keeps being polled
**regardless of rc** until the (already INV-43-scaled) window elapses. Only the
post-window sweep resolves `unavailable`. The window IS the propagation grace
(#180 Fix 2 — no separate grace timer). A verdict the agent *did* post (PASS or
FAIL) is matched at any round and wins over the rc (INV-40).

The behavioral logic is split into pure, unit-testable helpers in
`lib-review-poll.sh`: `_classify_unresolved_agent` (per-round decision) and
`_run_verdict_poll_loop` (the loop, with `_fetch_agent_verdict_body` as the
single overridable verdict-fetch seam).

## Pure decision — `_classify_unresolved_agent <verdict_body> <rc>`

Echoes one of: `pass` / `fail` (verdict matched) or `keep` (no verdict yet —
keep polling, regardless of rc). It never echoes `unavailable`; window-expiry is
the caller's responsibility.

| ID | verdict_body | rc | Expected | Rationale |
|----|--------------|----|----------|-----------|
| TC-CXG-DEC-01 | `Review PASSED …` | 0 | `pass` | verdict found, rc clean — happy path |
| TC-CXG-DEC-02 | `Review PASSED …` | 1 | `pass` | **#180 core**: verdict wins over non-zero rc |
| TC-CXG-DEC-03 | `Review PASSED …` | 137 | `pass` | even a SIGKILLed CLI's posted PASS counts |
| TC-CXG-DEC-04 | `Review findings: …` | 1 | `fail` | a FAIL the agent posted still counts (INV-40) |
| TC-CXG-DEC-05 | (empty) | 0 | `keep` | clean-but-not-yet — keep polling (unchanged) |
| TC-CXG-DEC-06 | (empty) | 1 | `keep` | **#180 core**: non-zero rc no longer drops; keep polling |
| TC-CXG-DEC-07 | (empty) | 137 | `keep` | SIGKILLed agent with no verdict — still keep polling until window expiry |

## Loop regression — `_run_verdict_poll_loop` (MANDATORY, the proof of the fix)

Drives the actual loop with `_fetch_agent_verdict_body` and `sleep`/`log`
stubbed. There is no real-world field sample of the bug, so this loop-level test
is the only thing that proves the fix does what it claims.

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXG-LOOP-01 | **THE #180 regression**: single agent, `AGENT_LAUNCH_RC` non-zero, stubbed fetch returns the passing verdict only on poll round ≥2 | agent verdict resolved `pass` (NOT `unavailable`); loop runs ≥2 rounds |
| TC-CXG-LOOP-02 | non-zero rc, fetch NEVER returns a verdict, tiny budget | loop leaves the agent unresolved (empty) → caller's sweep makes it `unavailable` (terminal behavior at window-expiry, unchanged) |
| TC-CXG-LOOP-03 | two agents, both non-zero rc, agent A's PASS lands round 1, agent B's PASS lands round 3 | both resolved `pass`; B is NOT dropped for being slower |
| TC-CXG-LOOP-04 | clean rc (0), verdict lands round 1 | resolved `pass` in one round (happy path, byte-for-byte) |
| TC-CXG-LOOP-05 | loop short-circuits the round after every agent is resolved (no extra polling) | round count stops at the resolving round, not the full budget |

## Lib structure greps — `lib-review-poll.sh`

| ID | Assertion |
|----|-----------|
| TC-CXG-LIB-01 | `_classify_unresolved_agent()` defined |
| TC-CXG-LIB-02 | `_classify_verdict_body()` defined (moved here from the wrapper) |
| TC-CXG-LIB-03 | `_run_verdict_poll_loop()` defined |
| TC-CXG-LIB-04 | `_fetch_agent_verdict_body()` defined (the test override seam) |
| TC-CXG-LIB-05 | the grace constant / resolver are GONE (no `_VERDICT_POLL_EXIT_GRACE`) |
| TC-CXG-LIB-06 | `bash -n` parses clean |

## Source-of-truth greps — `autonomous-review.sh`

| ID | Assertion |
|----|-----------|
| TC-CXG-SRC-01 | wrapper sources `lib-review-poll.sh` |
| TC-CXG-SRC-02 | the wrapper calls `_run_verdict_poll_loop` (loop delegated to the lib) |
| TC-CXG-SRC-03 | the immediate `rc -ne 0 → unavailable` short-circuit is GONE (regression: no `AGENT_LAUNCH_RC[$_sid]:-1}" -ne 0` test guarding `AGENT_VERDICTS[$_i]="unavailable"` inside the poll path) |
| TC-CXG-SRC-04 | the per-agent grace array `AGENT_EXIT_GRACE_LEFT` is GONE |
| TC-CXG-SRC-05 | wrapper references INV-43 / #180 in the verdict-poll section |
| TC-CXG-SRC-06 | the post-window sweep still defaults unresolved agents to `unavailable` (terminal behavior preserved) |
| TC-CXG-SRC-07 | the `all-unavailable` crash-vs-no-verdict discriminator (`AGENT_LAUNCH_RC[…] -ne 0` → `AGENT_EXIT=1`) is still present and untouched (#180 says leave it byte-for-byte) |
| TC-CXG-SRC-08 | `bash -n` parses clean |

## Doc-presence

| ID | Assertion |
|----|-----------|
| TC-CXG-DOC-01 | `docs/pipeline/invariants.md` INV-43 documents the no-early-drop sub-rule + references #180 |
| TC-CXG-DOC-02 | `docs/pipeline/review-agent-flow.md` Verdict-polling section documents "rc≠0 does not short-circuit while the window is open" |
| TC-CXG-DOC-03 | design doc present |
| TC-CXG-DOC-04 | this test-case doc present |

## Acceptance mapping (from #180)

- AC "every agent that posts a passing verdict within the window is counted" →
  TC-CXG-DEC-02/03 (verdict wins over rc) + TC-CXG-LOOP-01/03 (loop actually
  counts a late verdict from a non-zero-rc agent).
- AC "a non-zero CLI exit does not, by itself, drop an agent while the poll
  window is still open" → TC-CXG-DEC-06/07 (keep polling) + TC-CXG-SRC-03/04
  (short-circuit + grace array removed) + TC-CXG-LOOP-01.
- Unchanged terminal behavior "non-zero rc AND no verdict by window-expiry →
  unavailable" → TC-CXG-LOOP-02 + TC-CXG-SRC-06.
- `all-unavailable` discriminator untouched → TC-CXG-SRC-07.
- Share-one-E2E-run is deferred — see design "Non-goals". No test here.
