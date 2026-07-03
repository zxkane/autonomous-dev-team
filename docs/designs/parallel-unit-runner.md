# Design — Parallel unit-suite runner (#373)

## Problem

`tests/unit/test-*.sh` (167 files) runs today as a serial `for` loop in both CI
(`hermetic-unit`, ~5-6 min) and the autonomous dev/review wrappers' local
verification step (far worse under load — observed the better part of an hour
on this shared dev box during the #361 dev session). Individual files run in
0.2-3s; the cost is serialization, not the tests. Each test is already
hermetic (its own `mktemp` `TMPROOT`), so the suite is embarrassingly parallel
in principle — the only reason it isn't in practice is that nobody had swept
it for cross-test shared-mutable-state hazards.

## Goals

- A bounded-concurrency runner (`tests/run-unit-tests.sh`) that is a strict
  superset of the existing for-loop's semantics (same `bash <file>` invocation
  per test), so CI's eventual one-line switch is mechanical.
- No new dependency — `xargs -P` job pool, not GNU parallel.
- Same output contract CI/agents already parse: a summary line, PASS/FAIL per
  test, and full log replay on FAIL (uninterleaved, so a failure is legible
  without cross-referencing worker IDs).
- A documented escape hatch (`SERIAL_TESTS`) for any test that genuinely can't
  be made host-safe, so parallelism doesn't require perfection.

## Non-goals

- Parallelizing *inside* a test file — only across files.
- Touching `.github/workflows/ci.yml` — protected path (INV-92); the CI flip
  to the new runner is a follow-up operator action after merge.
- Speeding up individual slow tests.

## Approach

### Runner shape

`tests/run-unit-tests.sh`:

1. Resolve `UNIT_TEST_DIR` (default `tests/unit`) and `UNIT_TEST_JOBS`
   (default `min(8, nproc/2, floor 1)`, falls back to `4` if `nproc` is
   unavailable; any non-numeric/zero/negative override is rejected back to
   the default).
2. Partition `test-*.sh` into a parallel wave (everything) minus a `SERIAL_TESTS`
   bucket (bare filenames, hardcoded at the top of the script with a one-line
   reason each). A `SERIAL_TESTS` entry that doesn't exist on disk is a runner
   FAIL — keeps the list from silently drifting from reality.
3. Run the parallel wave through `xargs -P "$JOBS"`, one subshell per test.
   Each worker captures its own stdout+stderr to a per-test log file under a
   `mktemp -d` run directory, then prints its PASS/FAIL announcement (plus, on
   FAIL, the full log) under an `flock` on a shared lock file — this is what
   keeps concurrent workers' output from interleaving mid-line.
4. Run `SERIAL_TESTS` one at a time, strictly after the parallel wave (the
   `xargs` call blocks until every parallel worker exits, so ordering is
   free — no extra barrier needed).
5. Tally PASS/FAIL from each test's `.msg` file and print
   `UNIT-SUMMARY total=N pass=N fail=N skipped=0 wall=<secs>s`; exit non-zero
   iff `fail>0`. An unreadable/missing test file is a FAIL, never silently
   dropped from the total.

### Isolation audit (the load-bearing part)

Parallelism is only correct if no two tests can observe or mutate the same
resource. Swept all 167 existing files by reading each `/tmp`-string and
`pgrep -f`/`pkill -f` hit in context (not just grepping — a literal path in a
comment or a rejected-argument string is a false positive; a broad glob like
`/tmp/agent-*-issue-1.log` is a real hazard even with no fixed literal).
Genuine hits get one of two dispositions:

- **mktemp-fix (preferred)**: move the shared literal under the test's own
  `mktemp`/PID-scoped (`$$`) path. This was sufficient for every real hazard
  found — see the audit table in the PR description for the full list.
- **SERIAL_TESTS**: only if a test truly cannot be made host-safe (e.g. it
  binds a fixed port or asserts against genuinely global machine state). Not
  needed for the current suite — the array ships empty.

The full per-file audit table (file, line, shared resource, behavior,
decision, reason) lives in the PR description rather than duplicated here, so
it stays next to the diff it's justifying.

### Why `xargs -P` over a hand-rolled bash job pool

Bounded concurrency, worker reuse across the file list, and portable exit-code
handling all come for free from `xargs -P N -I{}`, with no new dependency (GNU
parallel would be a new package to install in CI and locally). The 3-line
per-worker wrapper (`_run_one`, exported via `export -f`) is enough to add
per-test log capture and the `flock`-serialized announce step on top.

### Testing strategy

The runner's own correctness (concurrency bound, PASS/FAIL protocol, log
replay, SERIAL ordering, stale-entry detection) is covered by a hermetic
meta-test (`tests/unit/test-run-unit-tests.sh`) that points the runner at
synthetic fixture directories via `UNIT_TEST_DIR` — never at the real 167-file
suite, so the meta-test itself stays fast and side-effect-free. See
`docs/test-cases/parallel-unit-runner.md` for the full `TC-PUR-NNN` list.

The real suite's parallel-safety is proven separately: 3 consecutive clean
`UNIT_TEST_JOBS=8` runs of the full suite (R5 flakiness gate), evidence pasted
into the PR description.

## Risks

| Risk | Mitigation |
|---|---|
| A future new test adds a fixed-path hazard, silently reintroducing flakiness | `tests/unit/README.md` documents the isolation contract (namespaced paths only, no fixed `/tmp` names, no repo-level shared state, scope `pgrep -f`/`pkill -f` patterns) so new tests are written host-safe from the start |
| Audit missed a hazard (false negative) | R5's 3-consecutive-clean-run gate is the empirical backstop — a real cross-test collision would show up as intermittent failure under `UNIT_TEST_JOBS>1` |
| `SERIAL_TESTS` grows unbounded over time, eroding the parallelism win | Each entry requires a reason comment and a stale-entry check (FAIL if the file is gone), keeping the list visible and honest rather than a silent drain |
