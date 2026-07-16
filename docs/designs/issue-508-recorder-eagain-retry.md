# Design: bounded EAGAIN retry in the agent-progress recorder's write path (issue #508)

## Problem

The `_agent_progress_recorder` pass-through (INV-135, #493/#496) writes each agent output
record to the wrapper's stdout with bash `printf`. That stdout is `exec > >(tee -a
run.log)` — the SAME open file description the Claude CLI (Node.js) inherits as its own
stderr. Node sets `O_NONBLOCK` on its pipe stdio, and that flag lives on the shared open
file description, not per-fd, so once Node's own writes fill the pipe buffer the recorder's
`printf` can itself get `EAGAIN`. Bash's `printf` builtin does not retry `EAGAIN`; a failed
`printf` silently drops that output record from both `run.log` and the `/tmp/agent-*.log`
pointer the dispatcher reads. When the dropped record is (or precedes the loss of) the
final `{"type":"result",...}` line, `is_session_completed` cannot confirm completion,
cascading into a false `crashed-session-retry` for a session that actually completed
cleanly — observed live twice in the first 8 hours the recorder was on main.

## Decision

`_agent_progress_write_retry <bytes>` (`lib-agent.sh`) replaces both bare `printf` call
sites in the recorder's read loop with a bounded-retry write:

- **Slicing.** The record is split into fixed 4096-byte (`PIPE_BUF`) slices under
  `LC_ALL=C` (byte-exact `${#s}`/`${s:off:len}`, immune to a slice boundary landing
  mid-UTF-8-codepoint). Load-bearing, not cosmetic: bash's `printf` can itself perform a
  genuine partial write before erroring (confirmed via `strace`: an `>PIPE_BUF`-sized
  `printf` argument writes exactly one `write(2)` of up to 4096 bytes then fails `EAGAIN` on
  the remainder, with no way for the caller to learn how many bytes actually landed).
  Chunking to `PIPE_BUF` sidesteps this because a write of `PIPE_BUF` bytes or fewer to a
  pipe is atomic (POSIX): it either fully lands or is fully rejected, so a slice that
  reports success is never re-sent and a slice that fails is retried whole with no
  duplication risk.
- **EPIPE vs EAGAIN classification.** A genuinely dead reader raises `EPIPE`, not `EAGAIN`
  — but bash's `printf` builtin does not die to `SIGPIPE` the way a raw `write(2)` caller
  might expect; it catches the failure internally and returns non-zero with `write error:
  Broken pipe` on its own stderr, the exact same shape (non-zero return, no process death)
  as `EAGAIN`'s `Resource temporarily unavailable`. The helper captures `printf`'s stderr
  via a saved fd-dup (so a successful write's stdout still reaches the real destination) and
  classifies `Broken pipe` as terminal: drop immediately, don't retry. Only
  unrecognized/EAGAIN-shaped failures retry.
- **Whole-record retry budget (round-2 review finding [P2]).** The retry deadline is
  computed ONCE, before the slice loop starts, from
  `AGENT_PROGRESS_WRITE_RETRY_BUDGET_SECONDS` (default ~2s) — not reset per slice. Every
  slice's retry loop checks elapsed time against that SAME deadline, so total retry time
  across the whole record stays bounded to ~2s regardless of slice count. The first shipped
  round reset `attempts=0` inside the slice loop, letting each 4096-byte slice of a large
  record claim its own fresh ~2s allowance — an N-slice record could then retry for up to
  N×2s, defeating the issue's "bounded total" requirement. `${EPOCHREALTIME:-}` (bash ≥5.0,
  this box's shell) is used for the per-attempt clock read, falling back to `date +%s.%N`.
- **Bound exhaustion.** If the deadline is exceeded, the record is dropped with ONE
  best-effort stderr diagnostic (itself `|| true` — the diagnostic write shares the same
  pipe and may fail too).
- **A missing/broken `awk` fails safe (round-3 review finding), not open-ended.** Both the
  deadline computation and the per-attempt exhaustion check shell out to `awk` for
  floating-point time arithmetic bash itself cannot do. The exhaustion check's `awk`
  program only ever exits 0 (`n >= d`, deadline reached) or 1 (`n < d`, not yet) by
  construction — but if `awk` itself cannot execute at all (missing/corrupt `PATH`), the
  shell instead observes some OTHER exit code (127, "command not found"). A bare
  `if awk ...; then` cannot tell that apart from the program's own "not yet" — both take
  the `if`'s false branch — so a check that fails to even run read as "keep retrying",
  spinning on `sleep 0.05` forever against a never-draining reader: exactly the unbounded
  hang this issue exists to eliminate, just triggered by an absent tool instead of a stuck
  pipe. Fixed by capturing the `awk` invocation's own exit code and treating anything other
  than the program's documented "not yet" (rc 1) as exhaustion — including the deadline
  computation's `awk` call, guarded by falling back to `deadline=now` (immediately
  exhausted) if that invocation's rc is non-zero or it produced empty output.
- **No new pipeline stage.** The retry lives entirely inside `_agent_progress_recorder`'s
  existing read loop — an additional stage would itself be a new EAGAIN-vulnerable writer.
  `O_NONBLOCK` is never cleared from bash (no fcntl access). Both call sites' `|| true`
  guards mean bound exhaustion/EPIPE can never abort the read loop under a caller's
  `set -e` — the same rationale as the loop's pre-existing `read -r line || rc=$?` guard for
  the no-trailing-newline EOF case.
- **The zero-`AGENT_PROGRESS_FILE` review-side path goes through the same retry-protected
  loop, not a bare `cat` (round-2 review finding, caught only by CI).** The first shipped
  shape special-cased a plain `cat` when `AGENT_PROGRESS_FILE` was unset, reasoning the
  review side never refreshes a lease so a no-op passthrough was equivalent — true for the
  lease, false for the write: `autonomous-review.sh` composes the identical
  `exec > >(tee -a run.log) 2>&1` topology, so the review-side CLI has the SAME shared
  nonblocking-pipe hazard. GNU coreutils `cat` (the CI runner's `cat`) does not retry
  `EAGAIN` either and silently drops data past the pipe buffer boundary — TC-LEASE-027
  failed in CI while passing locally, because the dev box's `cat` happened to be a
  different (non-GNU) implementation that behaves differently under the same pressure. The
  shortcut was removed; `_agent_progress_refresh`'s own unset-`AGENT_PROGRESS_FILE` guard
  already makes the lease side a safe no-op there, so this costs nothing on the review side.

## Review-round follow-ups (this PR)

| Round | Finding | Fix |
|---|---|---|
| 1 (self-review) | The retry loop treated any non-zero `printf` — including a dead reader's `EPIPE` — as retryable `EAGAIN`, burning the full ~2s budget per record against a dead reader instead of failing fast | EPIPE/`Broken pipe` classification (see Decision above); TC-LEASE-028 |
| 2 | The CI shell-idiom ratchet ([INV-130]) flagged a new `\|\| true` with no adjacent justification within its 3-line scan window | Added an inline justification comment at the flagged site; merged the read-loop's two near-duplicate `_agent_progress_write_retry ... \|\| true` call sites (one per `rc` branch) into one call with one comment, since the second site's existing comment sat too far above it to be in-window |
| 2 | The retry counter reset every 4096-byte slice instead of tracking one budget for the whole record | Single deadline computed before the slice loop, shared by every slice's retry check (see Decision above); TC-LEASE-029 exercises a slow-draining reader across a multi-slice record, plus a characterization run of the retired per-slice-reset shape proving the test discriminates fixed from broken |
| 2 | TC-LEASE-024..028 existed only in the shell test, not in `docs/test-cases/agent-progress-lease.md` | Added TC-LEASE-024..029 there in Given/When/Then form, plus the R3 acceptance-mapping update |
| 2 | No design canvas covered the slice/retry/error-classification design | This document |
| 2 | `local LC_ALL=C` does not reach the child `awk` process unless `LC_ALL` was already exported — a comma-decimal locale could corrupt the deadline float comparison | Prefixed `LC_ALL=C` directly on both `awk` invocations |
| 2 (CI, not local) | TC-LEASE-027 failed against GNU coreutils `cat` (the CI runner's `cat`) even though it passed locally against this dev box's non-GNU `cat` — the "zero-`AGENT_PROGRESS_FILE` fast path" bare `cat` had the SAME un-retried-`EAGAIN` data-drop bug as the pre-fix `printf`, just on the review side | Removed the bare-`cat` special case; the review-side path now runs through the same `_agent_progress_write_retry`-protected loop as the dev side |
| 3 | A missing/broken `awk` on `PATH` made the exhaustion check's `if awk ...; then` misread "awk itself couldn't execute" as "deadline not yet reached", spinning the retry loop forever instead of failing safe | Capture the `awk` invocation's exit code explicitly and treat anything other than its documented rc 1 ("not yet") as exhaustion; the deadline computation's own `awk` call falls back to `deadline=now` on failure (see Decision above); TC-LEASE-030 |

## Out of scope

Dispatcher-side hardening of the `crashed-session-retry` / INV-85 misclassification chain
(the consumer was fed corrupted input; fixing the producer removes the input class).
Changing the wrapper's `exec > >(tee ...)` topology or Node's stdio flags. The remote-SSM
log probe (reads the same file post-hoc; fixed by the same producer fix).

## Test plan

See `docs/test-cases/agent-progress-lease.md` TC-LEASE-024..030 —
`tests/unit/test-agent-progress-lease.sh`, driving the real recorder through a real
`O_NONBLOCK` pipe via a python3 `fcntl` helper: byte-identical passthrough under transient
EAGAIN pressure, the no-trailing-newline contract under retry, bounded-exhaustion
completing instead of hanging, the zero-`AGENT_PROGRESS_FILE` review-side path now
protected the same way as the dev side, dead-reader (EPIPE) fast-fail, the whole-record
(not per-slice) retry budget, and (TC-LEASE-030) a missing `awk` on `PATH` failing safe
instead of retrying forever against the SAME never-draining-reader harness TC-LEASE-026
uses.
