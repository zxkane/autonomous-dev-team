# Test Cases: parallel unit-suite runner

**Issue**: #373
**Test file**: `tests/unit/test-run-unit-tests.sh`
**Strategy**: point `tests/run-unit-tests.sh` at a hermetic fixture directory of tiny
synthetic test files (via `UNIT_TEST_DIR`), never at the real 167-file suite. Assert on
the runner's stdout/stderr protocol (`PASS`/`FAIL` lines, log replay, `UNIT-SUMMARY`
line) and exit code.

## Acceptance: every TC below must pass; full unit suite remains green.

| TC ID | Scenario | Expected |
|---|---|---|
| TC-PUR-001 | Fixture dir of N all-passing synthetic tests, default `UNIT_TEST_JOBS` | `UNIT-SUMMARY total=N pass=N fail=0 skipped=0 wall=<secs>s`; exit 0 |
| TC-PUR-002 | Fixture dir with one synthetic test that `exit 1`s (with distinctive stdout+stderr content) | Runner prints `FAIL <test> (<secs>s)` followed by that test's full captured log verbatim (both stdout and stderr lines present, uninterleaved with sibling output); `UNIT-SUMMARY` shows `fail=1`; exit non-zero |
| TC-PUR-003 | All-pass fixture, `UNIT_TEST_JOBS=1` | Runner degenerates to one-at-a-time execution and still passes; `UNIT-SUMMARY total=N pass=N fail=0`; exit 0 |
| TC-PUR-004 | `UNIT_TEST_JOBS` unset / `0` / negative / non-numeric (`"abc"`, `"-3"`, `"0"`, unset) | Runner falls back to `min(8, nproc/2, floor 1)` without error; suite still completes and passes |
| TC-PUR-005 | Concurrency proof: fixture dir of 8 `sleep 0.5` synthetic tests | `UNIT_TEST_JOBS=4` wall time is materially less than `UNIT_TEST_JOBS=1` wall time (< 60% of serial, generous margin) — this is the AC1 objective concurrency evidence |
| TC-PUR-006 | Fixture entry listed in `SERIAL_TESTS` runs after the parallel wave | Using a timestamp-marker fixture (each test appends `name start/end` to a shared log with wall-clock timestamps), assert the serial test's start timestamp is >= every parallel test's end timestamp, and that no parallel test's execution window overlaps the serial test's window |
| TC-PUR-007 | `SERIAL_TESTS` entry that does not exist on disk | Runner FAILs loudly (`UNIT-SUMMARY ... fail=1`, non-zero exit, `::error::` mentioning the stale entry) before running anything — never a silent skip |
| TC-PUR-008 | A test file that is unreadable (e.g. `chmod 000`) or has been deleted between glob and spawn | Reported as `FAIL <test> (0s)` with an explanatory message in the replayed log — never silently dropped from the total |
| TC-PUR-009 | `UNIT_TEST_DIR` overridden to a non-existent path | Runner FAILs loudly with `UNIT-SUMMARY total=0 pass=0 fail=1 ...` and an `::error::` line; exit non-zero |
| TC-PUR-010 | `UNIT_TEST_DIR` overridden to the real `tests/unit` (default), no fixture override | `total` in `UNIT-SUMMARY` equals the count of `tests/unit/test-*.sh` files (AC1) |

## Notes

- The concurrency proof (TC-PUR-005) uses `sleep`-based synthetic tests rather than the
  real suite, per AC1: a shared/loaded dev box makes strict wall-clock comparison of the
  real 167-file suite flaky, so the *objective* proof lives in the hermetic meta-test with
  a generous margin (< 60% of serial time for a `sleep 0.5 × 8` workload against 4
  workers). The real-suite serial-vs-parallel comparison is PR-description-only evidence
  (non-gating), captured via `time bash tests/unit/run-legacy-loop.sh` (conceptually — the
  legacy for-loop) vs `time bash tests/run-unit-tests.sh`.
- TC-PUR-006's SERIAL bucket ordering check needs a fixture test that can be dynamically
  added to `SERIAL_TESTS` — since `SERIAL_TESTS` is a fixed array at the top of
  `tests/run-unit-tests.sh` itself (per R3's pinned interface: "a `SERIAL_TESTS` array at
  the top of the runner"), the meta-test drives this via a **copy of the runner** with an
  injected `SERIAL_TESTS` entry (sourced into a subshell with the array pre-populated, or a
  sed-patched temp copy) rather than trying to override the array via environment — bash
  arrays cannot be exported. See the test file for the exact mechanism.
- No `SERIAL_TESTS` entries exist in the shipped runner today — the #373 isolation audit
  (see PR description) found every candidate hazard fixable via a namespaced
  `mktemp`/PID-scoped path instead of serialization. TC-PUR-006/007 exercise the mechanism
  itself so it's proven correct before it's ever needed.
