# Test cases — `review_near_success` process-group signal (#132)

Covers the fifth signal added to `lib-dispatch.sh::review_near_success`: walk
the review wrapper's process group (PGID == content of `review-${ISSUE}.pid`)
and treat as ALIVE/skip-crash if any group member's `comm` matches `AGENT_CMD`.

Closes the gap reproduced on a downstream consumer's #209: long-running
review wrapper, `pid_alive` triple miss (kill -0 / PID-file mtime / heartbeat
sibling mtime all stale), and four PR-state signals all trail the still-mid-
flight wrapper.

Located in `tests/unit/test-dispatcher-review-near-success.sh` (extending the
existing 6-case file). Run via:

```bash
bash tests/unit/test-dispatcher-review-near-success.sh
```

## TC-RNS-007 — process-group signal alone short-circuits when all four legacy signals are negative

**Intent**: The whole point of the change. Reproduces the #209 16:00:39Z
window: PR not merged, no APPROVED review, no verdict comment, defensive
`kill -0` misses, but `pgrep -g <pgid>` finds an `AGENT_CMD` child. Must
return 0 (skip crash).

**Setup**:
- `_MOCK_PR_INFO=` empty (no PR data — both signal 1 and 2 negative).
- `_MOCK_VERDICT_AGE=` empty (signal 3 negative).
- `_MOCK_PID=12345`, `_MOCK_KILL0_RC=1` (signal 4 negative — same miss as `pid_alive`).
- `_MOCK_PGREP_AGENT_FOUND=1` (the new signal positive).

**Expected**:
- `review_near_success 99` returns 0.

## TC-RNS-008 — all five signals negative, returns 1 (legitimate crash path)

**Intent**: Pin that the new signal alone can't false-positive when the
wrapper is genuinely dead. The crash + label-swap path must still fire.

**Setup**:
- All four legacy mocks negative (same as TC-RNS-007 above for 1–4).
- `_MOCK_PGREP_AGENT_FOUND=0`.

**Expected**:
- `review_near_success 99` returns 1.

## TC-RNS-009 — legacy positive signal short-circuits before the new signal runs

**Intent**: Regression-pin ordering. The new signal sits at the END of the
function (cheapest legacy signals first); when an earlier signal is
positive, the new code path must never execute. Without this pin a future
refactor could reorder and accidentally make pgrep the dominant cost on
every call.

**Setup**:
- `_MOCK_VERDICT_AGE=10` (signal 3 positive).
- `_MOCK_PGREP_AGENT_FOUND=0` (new signal would be negative if asked).
- The pgrep stub records whether it was called via a `_MOCK_PGREP_CALLED` counter.

**Expected**:
- `review_near_success 99` returns 0 (signal 3 wins).
- `_MOCK_PGREP_CALLED=0` after the call (the new signal was not consulted).

## TC-RNS-010 — `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=0` strict knob still wins over the new signal

**Intent**: Ops escape hatch. Setting the window to 0 must restore legacy
strict behaviour (every `pid_alive` miss declares crashed) — even when the
new process-group signal would have said ALIVE. Without this lock, the
operator's "I want strict, I'll deal with the false positives" override
silently loses to the new signal.

**Setup**:
- `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=0`.
- `_MOCK_PGREP_AGENT_FOUND=1` (would have rescued in TC-RNS-007).

**Expected**:
- `review_near_success 99` returns 1 (the function exits at the early
  numeric guard before any signal runs).

## TC-RNS-011 — empty / unparseable PID skips the new signal silently (defensive guard)

**Intent**: When `review-${ISSUE}.pid` is absent or its content is empty
or non-numeric (race with `kill_stale_wrapper` deletion, or never written
because the wrapper crashed in `acquire_pid_guard`), the new signal must
NOT call `pgrep` with garbage args — it must skip the signal silently and
return based on the four legacy signals alone. Without this guard, a typo
in PID-file content could surface as a misleading shellcheck-/CI-level
error in the dispatcher log.

**Setup**:
- All four legacy mocks negative.
- `_MOCK_PID=""` (PID file empty).
- `_MOCK_PGREP_AGENT_FOUND=1` (the stub would say positive *if* asked).
- `_MOCK_PGREP_CALLED=0` baseline.

**Expected**:
- `review_near_success 99` returns 1 (no signal positive).
- `_MOCK_PGREP_CALLED=0` after the call (the bad-PID branch never reached pgrep).

## Out of scope

- Reproducing the #209 timing race against a real review wrapper. That'd
  60× the test runtime; the mock-driven cases above cover the same
  decision matrix in seconds.
- `AGENT_CMD` matching subtleties (`claude` vs `claude-cli`, comm-truncation
  to 15 chars on Linux). The substring-match design tolerates these by
  construction; a focused matcher unit test would be redundant against
  TC-RNS-007's positive path.
