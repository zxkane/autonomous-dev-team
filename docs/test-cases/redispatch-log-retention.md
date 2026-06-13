# Test cases — re-dispatch log retention (issue #245)

Covers the rotation behavior added to `dispatch-local.sh` and the preservation of the deliberate
INV-12 / INV-35 recovery-truncates.

Unit test: `tests/unit/test-dispatch-local-log-retention.sh` (auto-discovered by the CI
`Run all unit tests` glob `tests/unit/test-*.sh`).

| ID | Scenario | Steps | Expected |
|----|----------|-------|----------|
| TC-LOGRET-1 | **Regression (review arm)** — prior run's log survives re-dispatch | Seed `…-review-N.log` with a sentinel, invoke `dispatch-local.sh review N` a second time. | Sentinel is recoverable in `…-review-N.log.1`; the fresh `…-review-N.log` does **not** contain the sentinel (it is a clean new-run file). MUST fail before the fix (sentinel destroyed), pass after. |
| TC-LOGRET-2 | **Regression (dev arm)** — same for `dev-new` | Seed `…-issue-N.log` with a sentinel, invoke `dispatch-local.sh dev-new N` a second time. | Sentinel recoverable in `…-issue-N.log.1`. |
| TC-LOGRET-3 | **Perm — fresh current log is 0600** | After a dispatch, stat the freshly-prepared `…-N.log`. | mode is `600`. |
| TC-LOGRET-4 | **Perm — rotated `.log.1` is 0600** | After a re-dispatch that rotated, stat `…-N.log.1`. | mode is `600` (the rotated generation must never be world-readable). |
| TC-LOGRET-5 | **First dispatch (no prior log)** — no spurious `.log.1` | Invoke `dispatch-local.sh` for an issue with no existing log. | Fresh `…-N.log` exists at `0600`; no `…-N.log.1` is created (nothing to rotate). |
| TC-LOGRET-6 | **Disk bound — single generation** | Dispatch three times, seeding a distinguishable sentinel before each. | Only `…-N.log` and `…-N.log.1` exist; no `…-N.log.2`. The `.log.1` holds the immediately-preceding run's sentinel, not the oldest. |
| TC-LOGRET-7 | **INV-12 / INV-35 recovery-truncate preserved** | Static guard: assert `lib-dispatch.sh` still contains the INV-35 `: > "$_log_file"` and `dispatcher-tick.sh` still contains the INV-12 `: > "$_ptl_log"`. | Both deliberate recovery-truncate lines survive (guard against an over-broad fix that disables intentional recovery). |
| TC-LOGRET-8 | **CWE-59 — chmod does not follow a symlinked log** | Make `…-N.log` a symlink to a `0644` victim file, dispatch. | The victim's mode stays `644` (the rotation's `chmod` skips the symlinked `.log.1`, not following it to the target); the fresh `…-N.log` is a new `0600` regular file. Mirrors the symlink-refusal posture of `kill_stale_wrapper`'s PID-file handling. |

## Notes

- The test exercises `dispatch-local.sh` end-to-end (real script, stub wrapper) following the
  established `tests/unit/test-dispatch-local-empty-session.sh` sandbox pattern: a temp project dir
  with `autonomous.conf`, a stub `autonomous-dev.sh` / `autonomous-review.sh` that sleeps briefly so
  the post-spawn `kill -0` check passes, and per-file symlinks of the dispatcher lib chain.
- `LOG_PREFIX` is `/tmp/agent-${PROJECT_ID}`; the test uses a unique `PROJECT_ID` so it never
  collides with a live wrapper's `/tmp/agent-*.log` on the shared dev box.
- E2E: not run. The unit test already drives `dispatch-local.sh` end-to-end against a stub wrapper
  and asserts the crashed-run evidence survives a re-dispatch — a shell-level end-to-end of the
  exact forensic-loss scenario from the issue. A full pipeline E2E adds no coverage for a
  dispatcher-internal log-prep change.
