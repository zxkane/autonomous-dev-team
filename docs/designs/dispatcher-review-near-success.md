# Design: Stop mislabeling long-running review wrappers as "crashed"

Issue: #111

## Problem

`dispatcher-tick.sh` Step 5b review-DEAD branch (lines 452-456) declares a
review wrapper "crashed" purely on a `pid_alive` miss after the cold-start
grace period (default 600s). Real review wrappers routinely run 15-30 min
(E2E + multi-bot rounds + line-by-line review). On a transient `pid_alive`
race, or just after the wrapper has reached the merge-step but before its
trap clears state, the dispatcher posts a misleading "crashed" comment and
flips `reviewing` → `pending-dev` while review is still actively running.

The wrapper's own success path eventually merges the PR, but the issue is
left with stale `pending-dev` label residue and noisy "crashed" comments.

## Two-part fix (delivered together)

### Part A — PR-state cross-check (Step 5b review branch)

Before declaring the review wrapper crashed, check four PR-state signals.
If ANY signal is positive within `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS`
(default 300s), short-circuit the crash path and leave `reviewing` alone:

1. **PR just merged** — `mergedAt` younger than the window.
2. **PR just approved** — most recent APPROVED review event younger than
   the window.
3. **Verdict comment posted** — review-agent identity (or any GitHub user
   matching the review-bot login pattern) posted a comment matching
   `^Review (PASSED|findings)` in the window.
4. **Defensive PID re-check** — `kill -0 <pid>` against the current
   PID-file content. If it now returns 0, the original `pid_alive`
   miss was a race; defer to next tick. (Mirrors Step 5a's re-verify
   pattern at dispatcher-tick.sh:404-407.)

Only when **all four are negative** does the existing crash + label-swap
fire.

### Part B — Wrapper heartbeat

Both wrappers (`autonomous-dev.sh`, `autonomous-review.sh`) install a
shared `install_agent_heartbeat` helper (in `lib-agent.sh`, parity with
`install_agent_sigterm_trap`). The helper spawns a background loop that
`touch`es `AGENT_PID_FILE` every `HEARTBEAT_INTERVAL_SECONDS` (default
120s). The loop exits when the wrapper exits (parent-pid watchdog).

`pid_alive` in `lib-dispatch.sh` becomes a two-tier check:

- `kill -0 <pid>` → ALIVE.
- `kill -0 <pid>` fails → check PID-file mtime. If mtime is within
  `HEARTBEAT_INTERVAL_SECONDS * 3` (default 360s), still treat as ALIVE
  (process may be transitioning groups, exec'ing, or in a transient
  race). Otherwise DEAD.

The two parts complement:
- (A) handles the cleanup-merge-exit tail — wrapper *did* finish, but
  PR-state evidence is the authoritative success signal.
- (B) handles the long mid-review window where no PR-state changes are
  visible yet — heartbeat gives the dispatcher a positive "still working"
  signal.

## INV-24

> Review wrapper DEAD detection requires both `pid_alive` miss AND no
> near-success PR signal AND no recent PID-file heartbeat. A `pid_alive`
> miss alone is NOT sufficient.

Cross-references from `dispatcher-flow.md` Step 5b.

## Risk / non-goals

- **Dev-side wrappers** (`in-progress` / Step 5a) are NOT touched by
  Part A. Step 5a already has its own re-verify pattern + 5-min idle
  gate; the false-alarm class described in #111 is review-specific.
- Heartbeat (Part B) IS installed for both wrappers — costs near zero
  and benefits both.
- `HEARTBEAT_INTERVAL_SECONDS=0` disables heartbeat entirely (regression
  safety).
- `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS=0` disables Part A short-circuits
  (preserves legacy strict behavior for ops that prefer it).

## File-level changes

| File | Change |
|------|--------|
| `skills/autonomous-dispatcher/scripts/lib-agent.sh` | + `install_agent_heartbeat` helper |
| `skills/autonomous-dispatcher/scripts/lib-dispatch.sh` | + `pid_alive` mtime fallback, + `review_near_success` helper |
| `skills/autonomous-dispatcher/scripts/dispatcher-tick.sh` | Step 5b review branch gates on `review_near_success` |
| `skills/autonomous-dispatcher/scripts/autonomous-dev.sh` | call `install_agent_heartbeat` after PID-file write |
| `skills/autonomous-dispatcher/scripts/autonomous-review.sh` | call `install_agent_heartbeat` after PID-file write |
| `scripts/autonomous.conf.example` | document `HEARTBEAT_INTERVAL_SECONDS`, `REVIEW_NEAR_SUCCESS_WINDOW_SECONDS` |
| `docs/pipeline/invariants.md` | add INV-24 |
| `docs/pipeline/dispatcher-flow.md` | reference INV-24 in Step 5b |
| `tests/unit/test-dispatcher-review-near-success.sh` | new |
| `tests/unit/test-wrapper-heartbeat.sh` | new |
