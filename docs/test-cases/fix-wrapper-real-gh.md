# Test Cases: gh-with-token-refresh REAL_GH override + cleanup startup-failure (#92)

## Part 1 — `gh-with-token-refresh.sh` REAL_GH override

Strategy: drive the script under `env -i` (mimicking a non-interactive
spawn). Stub the "real" gh as a recording shell script so we can assert
which path was used.

| ID | Setup | Expected |
|---|---|---|
| TC-RG-001 | `REAL_GH=/abs/path/to/stub-gh`, stub-gh exists & executable, PATH=/usr/bin:/bin (no gh) | wrapper execs the stub, prints stub's output, rc=0; system PATH never consulted |
| TC-RG-002 | `REAL_GH=/abs/missing/gh` (path not executable), stub-gh on PATH | wrapper falls through to PATH lookup, execs stub-on-PATH |
| TC-RG-003 | `REAL_GH=/abs/missing/gh`, no gh anywhere | wrapper exits 1, error message includes original "Cannot find real gh" AND new "Set REAL_GH" hint |
| TC-RG-004 | `REAL_GH` empty, gh present on PATH | unchanged behavior — finds via PATH |
| TC-RG-005 | `REAL_GH` empty, no gh on PATH (the original repro) | wrapper exits 1, error includes "Set REAL_GH" hint |
| TC-RG-006 | `REAL_GH=/abs/path/to/stub-gh`, `GH_TOKEN_FILE` set with a token | wrapper passes through, stub gh sees `GH_TOKEN=<file contents>` in its env |

## Part 2 — `autonomous-dev.sh` cleanup-on-startup-failure

Strategy: run `autonomous-dev.sh` in a sandbox where:
- `lib-agent.sh` and `lib-auth.sh` are stubbed so setup_github_auth is a
  no-op and we can control AGENT_RAN.
- `gh` on PATH is a recording stub.
- Force a failure between auth setup and agent invocation by
  intercepting the first `gh issue view` call (return non-zero).

| ID | Setup | Expected |
|---|---|---|
| TC-CL-001 | Wrapper aborts at `gh issue view "$ISSUE_NUMBER"` with rc=1 (e.g. real-gh-not-found bubbles up) | cleanup posts `gh issue comment` containing "Agent Session Report (Dev)" + "Exit code: 1" + "Mode: startup-failure"; cleanup transitions label from in-progress to pending-dev |
| TC-CL-002 | Wrapper aborts before ISSUE_NUMBER is parsed (e.g. `--issue` missing) | cleanup does NOT attempt to post a comment (no ISSUE_NUMBER → nowhere to post) — preserves existing silent behavior |
| TC-CL-003 | Normal happy path (AGENT_RAN=true, exit 0) | cleanup posts the existing "Exit code: 0" comment, NOT the startup-failure variant |

Out of scope:
- The dispatcher's retry-counter integration: covered by existing
  `test-retry-counter-reset.sh` against the now-correctly-labeled
  comments.
- `autonomous-review.sh` symmetric fix.
