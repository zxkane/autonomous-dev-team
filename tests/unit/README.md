# tests/unit/ — isolation contract

Every `test-*.sh` file in this directory can run **concurrently** with any other
file here, via `tests/run-unit-tests.sh` (bounded `xargs -P` worker pool; see that
script's header for `UNIT_TEST_DIR`/`UNIT_TEST_JOBS`). Legacy serial for-loops
(current CI) also still work — the runner is a strict superset of that semantics.

## Rules for new tests

- **Namespaced paths only.** Any file the test creates outside its own directory
  must live under a fresh `mktemp` / `mktemp -d`, or be suffixed with `$$` (the
  test's own PID). Never write to a fixed literal path like `/tmp/foo.txt` — a
  concurrently-running sibling could read, write, or delete the same path.
- **No repo-level shared state.** Don't write to a tracked file in the repo tree,
  bind a fixed port, or otherwise touch anything another test might also touch.
- **`pgrep -f` / `pkill -f` patterns must be scoped to your own fixture.** Anchor
  the match pattern on your test's own `mktemp` path (project dir, PID file path,
  etc.) — never a bare command name or a pattern broad enough to match a sibling
  test's spawned fake/sleep processes.
- **Broad globs are a hazard even without a literal path.** A `for f in
  /tmp/agent-*-issue-1.log` or similar host-wide glob can pick up a sibling's file.
  Prefer a `$$`-scoped or `mktemp`-scoped selector instead of a plain wildcard.

## If a test genuinely cannot be made host-safe

Add it to the `SERIAL_TESTS` array at the top of `tests/run-unit-tests.sh` with a
one-line reason comment. It will run alone, after the parallel wave — never
concurrently with anything else. This should be rare: prefer fixing the test to
use a namespaced path. A `SERIAL_TESTS` entry is the exception, not the default.

See the #373 isolation audit in that issue's PR description for the full sweep of
the existing 167-file suite and the reasoning behind each disposition.
