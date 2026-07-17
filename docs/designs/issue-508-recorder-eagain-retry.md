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

- **Slicing.** The record is split into fixed 512-byte (`{_POSIX_PIPE_BUF}`, the POSIX
  guaranteed floor) slices under `LC_ALL=C` (byte-exact `${#s}`/`${s:off:len}`, immune to a
  slice boundary landing mid-UTF-8-codepoint). Load-bearing, not cosmetic: bash's `printf`
  can itself perform a genuine partial write before erroring (confirmed via `strace`: an
  `>PIPE_BUF`-sized `printf` argument writes exactly one `write(2)` of up to `PIPE_BUF` bytes
  then fails `EAGAIN` on the remainder, with no way for the caller to learn how many bytes
  actually landed). Chunking to `PIPE_BUF` sidesteps this because a write of `PIPE_BUF` bytes
  or fewer to a pipe is atomic (POSIX): it either fully lands or is fully rejected, so a
  slice that reports success is never re-sent and a slice that fails is retried whole with
  no duplication risk. **512, not 4096 (round-10 review finding [P2])** — Linux's actual
  `PIPE_BUF` is 4096, but POSIX only GUARANTEES `{_POSIX_PIPE_BUF} = 512`; macOS/BSD's
  `PIPE_BUF` genuinely is 512. A 4096-byte slice is only atomic on platforms where the real
  `PIPE_BUF` is >= 4096 — on a platform where it is 512, that slice size can itself receive a
  partial write() below the slice boundary, reopening the exact resend-duplication risk
  chunking exists to prevent, just one level down. 512 is safe everywhere (including Linux,
  where it is merely smaller than strictly necessary, never unsafe) without needing a
  runtime `PIPE_BUF` probe, which bash has no portable built-in way to perform anyway.
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
- **A missing/broken CLOCK fails safe (round-4 review finding), distinct from a missing
  `awk`.** `_agent_progress_write_retry_now_seconds` returns `${EPOCHREALTIME}` when the
  running bash has it (>=5.0), else falls back to `date +%s.%N` / `date +%s`. On a bash
  WITHOUT `EPOCHREALTIME` whose `date` is ALSO missing or broken, both branches produce an
  EMPTY string — not a non-zero exit code, since command substitution of a failed `date`
  still "succeeds" as an empty capture. Feeding that straight into
  `awk -v n="$now0" ...` does NOT fail the way a missing `awk` does: awk's numeric-string
  coercion silently treats the unset variable as `0` in arithmetic context, so `deadline`
  still computes a plausible-looking value (`0 + budget`) and every later exhaustion check
  re-derives `now=0` the same way — `0 >= deadline` never holds, so the retry loop spins on
  `sleep 0.05` forever against a never-draining reader. The round-3 `awk`-exit-code fix does
  NOT catch this, because `awk` itself runs and exits normally here; the bad input never
  reaches a failing exit code. Fixed by validating the clock reading BEFORE it ever reaches
  `awk` (`_agent_progress_write_retry_clock_ok`, a plain-decimal-number regex check) — once
  for the initial `now0` and again on every retry attempt's `now` (a transient `date`
  failure mid-loop must fail closed too, not just the initial read) — dropping the record
  immediately with a diagnostic that names the actual cause ("clock unavailable") instead of
  the generic exhaustion message.
- **The `date +%s.%N` fallback validates its OWN output before trusting it (round-10 review
  finding), distinct from round-4's missing-clock case.** BSD/macOS `date` does not support
  `%N`, but — unlike an unsupported format that fails — it does not error: it exits 0 and
  echoes the literal leftover character (`%` is consumed as the format-spec sigil, leaving
  just `N`) appended after the seconds, e.g. `1700000000.N`. The pre-fix
  `date +%s.%N 2>/dev/null || date +%s` fallback never reaches its `||` branch, because the
  command "succeeded". That `.N`-suffixed string then fails
  `_agent_progress_write_retry_clock_ok`'s numeric-decimal regex — correctly, since it is not
  a number — so every BSD/macOS run misclassified a perfectly healthy clock as "clock
  unavailable" and dropped every record, even though round-4's fix was working exactly as
  designed. Fixed by validating the `%N` output is purely numeric BEFORE accepting it;
  a non-numeric result now falls back to whole-second `date +%s` (portable on every
  POSIX/BSD platform) instead of the unusable literal-`%N` string.
- **No new pipeline stage.** The retry lives entirely inside `_agent_progress_recorder`'s
  existing read loop — an additional stage would itself be a new EAGAIN-vulnerable writer.
  `O_NONBLOCK` is never cleared from bash (no fcntl access). Both call sites' `|| true`
  guards mean bound exhaustion/EPIPE can never abort the read loop under a caller's
  `set -e` — the same rationale as the loop's pre-existing `read -r line || rc=$?` guard for
  the no-trailing-newline EOF case.
- **The zero-`AGENT_PROGRESS_FILE` review-side fast path (bare `cat`) is UNCHANGED**, per
  the issue's own "Mandated fix shape" ("the retry must not change the
  zero-`AGENT_PROGRESS_FILE` fast path (`cat` short-circuit, review side)"). A round-2 dev
  iteration removed this shortcut after CI's TC-LEASE-027 exposed that GNU coreutils `cat`
  has the SAME un-retried-`EAGAIN` data-drop hazard as the pre-fix `printf` (confirmed
  empirically against a real GNU `cat` binary: it drops ~53% of a 500-line fixture under
  the harness's EAGAIN pressure). That fix was reverted after round-6/7 review correctly
  rejected the scope expansion (documenting a deviation is not the same as obtaining an
  owner-approved requirement change) — see "Review-side `cat` EAGAIN hazard" below for why
  reverting is safe and where the hazard is tracked instead.
- **A clock-independent attempt-count ceiling backstops the wall-clock deadline (round-9
  review finding).** The exhaustion check compares two readings of the SAME wall clock
  (`now` against `deadline`). If that clock steps BACKWARD after `deadline` was computed —
  a realistic NTP-correction scenario — every later `now` is a perfectly valid reading
  (passes `_agent_progress_write_retry_clock_ok`) that nonetheless never satisfies
  `now >= deadline`: none of the round-1..4 fixes catch this, because they all guard against
  a MISSING or malformed clock, not a valid one that simply never advances far enough. Fixed
  by adding `max_attempts` — a plain bash integer counter incremented once per retry attempt,
  independent of any clock read — computed once (sized from the same
  `AGENT_PROGRESS_WRITE_RETRY_BUDGET_SECONDS` budget, generously above the attempt count a
  functioning clock would need, so it never fires before the wall-clock deadline under
  normal operation) and checked FIRST on every attempt, before the wall-clock check. The two
  bounds are independent: either one alone terminates the loop, so a fault on one axis
  (clock) is caught by the other (attempt count).

## Review-round follow-ups (this PR)

| Round | Finding | Fix |
|---|---|---|
| 1 (self-review) | The retry loop treated any non-zero `printf` — including a dead reader's `EPIPE` — as retryable `EAGAIN`, burning the full ~2s budget per record against a dead reader instead of failing fast | EPIPE/`Broken pipe` classification (see Decision above); TC-LEASE-028 |
| 2 | The CI shell-idiom ratchet ([INV-130]) flagged a new `\|\| true` with no adjacent justification within its 3-line scan window | Added an inline justification comment at the flagged site; merged the read-loop's two near-duplicate `_agent_progress_write_retry ... \|\| true` call sites (one per `rc` branch) into one call with one comment, since the second site's existing comment sat too far above it to be in-window |
| 2 | The retry counter reset every 4096-byte slice instead of tracking one budget for the whole record | Single deadline computed before the slice loop, shared by every slice's retry check (see Decision above); TC-LEASE-029 exercises a slow-draining reader across a multi-slice record, plus a characterization run of the retired per-slice-reset shape proving the test discriminates fixed from broken |
| 2 | TC-LEASE-024..028 existed only in the shell test, not in `docs/test-cases/agent-progress-lease.md` | Added TC-LEASE-024..029 there in Given/When/Then form, plus the R3 acceptance-mapping update |
| 2 | No design canvas covered the slice/retry/error-classification design | This document |
| 2 | `local LC_ALL=C` does not reach the child `awk` process unless `LC_ALL` was already exported — a comma-decimal locale could corrupt the deadline float comparison | Prefixed `LC_ALL=C` directly on both `awk` invocations |
| 2 (CI, not local) | TC-LEASE-027 failed against GNU coreutils `cat` (the CI runner's `cat`) even though it passed locally against this dev box's non-GNU `cat` — the "zero-`AGENT_PROGRESS_FILE` fast path" bare `cat` had the SAME un-retried-`EAGAIN` data-drop bug as the pre-fix `printf`, just on the review side | Removed the bare-`cat` special case, routing the review-side path through the same `_agent_progress_write_retry`-protected loop as the dev side — **later reverted in round 8** (see rows 5 and 6, 7) as out of #508's scope |
| 3 | A missing/broken `awk` on `PATH` made the exhaustion check's `if awk ...; then` misread "awk itself couldn't execute" as "deadline not yet reached", spinning the retry loop forever instead of failing safe | Capture the `awk` invocation's exit code explicitly and treat anything other than its documented rc 1 ("not yet") as exhaustion; the deadline computation's own `awk` call falls back to `deadline=now` on failure (see Decision above); TC-LEASE-030 |
| 4 | On a bash without `EPOCHREALTIME` whose `date` fallback is also missing/broken, the clock helper returns an empty string; awk coerces that to `0` in arithmetic (not a failing exit code), so `deadline` and every later `now` both compute from `0` and `0 >= deadline` never holds — an unbounded hang the round-3 `awk`-exit-code fix does not catch, since `awk` itself runs successfully here | `_agent_progress_write_retry_clock_ok` validates the clock reading is a plain decimal number BEFORE it reaches `awk`, checked on the initial `now0` and again on every retry attempt's `now`; an unusable reading fails closed immediately with a "clock unavailable" diagnostic; TC-LEASE-031 |
| 5 | The literal issue text says the fix "must not change the zero-`AGENT_PROGRESS_FILE` fast path (`cat` short-circuit, review side)" — round 5 recognized a stricter reading was needed but only documented the round-2 removal as a deliberate deviation instead of reverting it | See "Review-side `cat` EAGAIN hazard" below: reverted the round-2 change; the bare `cat` fast path is restored byte-for-byte as it existed before this PR |
| 6, 7 | Review rejected the round-5 "documented deviation" twice in a row: restore the fast path or obtain an owner-approved requirement change — a design-doc note is neither | Reverted the round-2 fast-path removal outright (this round); filed the underlying `cat`/EAGAIN hazard as #510 instead of fixing it inside #508's scope |
| 9 (this round) | The exhaustion check bounds retries against a wall clock; if that clock steps backward after `deadline` is computed (e.g. an NTP correction), every later `now` reading is valid but never reaches `deadline` — the loop spins on `sleep 0.05` forever, a hang none of rounds 1–4's clock-validity/missing-`awk` fixes catch (they only guard a MISSING/malformed clock, not a valid non-advancing one) | Added `max_attempts`, a clock-independent bash integer ceiling checked before the wall-clock check on every attempt (see Decision above); TC-LEASE-035 |
| 10 | The 4096-byte slice size is only atomic on platforms where the real `PIPE_BUF` is >= 4096; POSIX only guarantees 512, and macOS/BSD's `PIPE_BUF` genuinely is 512 — a hard-coded 4096-byte slice risks a sub-slice partial write on such platforms, reopening the resend-duplication hazard chunking exists to prevent | Slice size lowered to 512 (the POSIX floor, safe on every platform); TC-LEASE-037 verifies via `strace` that the recorder's own writes never exceed 512 bytes |
| 10 | BSD/macOS `date +%s.%N` does not fail on the unsupported `%N` — it exits 0 and emits a non-numeric `.N`-suffixed string, so the `\|\|`-fallback never fires and a perfectly healthy BSD/macOS clock was misclassified as "clock unavailable" by the round-4 validation, dropping every record | `_agent_progress_write_retry_now_seconds` now validates the `%N` reading is purely numeric before accepting it, falling back to whole-second `date +%s` otherwise; TC-LEASE-036 |

## Review-side `cat` EAGAIN hazard (tracked separately, NOT fixed in this PR)

Issue #508's own "Mandated fix shape" section states the retry "must not change the
zero-`AGENT_PROGRESS_FILE` fast path (`cat` short-circuit, review side)". A round-2
iteration removed that shortcut anyway, after CI's TC-LEASE-027 showed GNU coreutils `cat`
drops data under this same `O_NONBLOCK`/EAGAIN pressure — a real bug, verified again here
directly: a real GNU `cat` (9.7) run through this issue's own `drive_recorder.py` harness
against a 500-line/~140KB fixture landed only 233 of 500 lines (sha256 mismatch,
`write error: Resource temporarily unavailable` on stderr), while this dev box's default
`cat` (a Rust/uutils reimplementation) reproduced the input byte-identically under the
identical pressure — confirming the hazard is real but implementation-dependent, not a flaw
in this PR's own retry logic.

Round 5 kept the round-2 removal and only documented it as a "deliberate deviation" rather
than obtaining an actual requirement change. Rounds 6 and 7 correctly rejected that: the
issue's constraint is unambiguous, and a design-doc note asserting a deviation is justified
is not the "owner-approved requirement change" the review asked for. This round reverts the
round-2 removal outright — the fast path is restored to a bare `cat`, byte-for-byte as it
existed before this PR — and stops trying to fix the review-side hazard inside #508's scope.

This is a safe revert, not a regression, because the review-side hazard has a materially
different blast radius than the dev-side one this issue exists to fix:
- `is_session_completed` (`lib-dispatch.sh`) — the function whose false-negative reads
  cascade into `crashed-session-retry` → false `stalled` — only ever parses the **dev**
  wrapper's log (gated on `AGENT_DEV_CMD`/`AGENT_CMD`); it has no review-side counterpart.
  A dropped record in the review wrapper's `run.log` degrades log fidelity for a human
  reading it post-hoc; it does not feed any automated state-machine decision.
- The hazard is therefore real and worth fixing, but it is a different, smaller-severity
  bug than #508, not a component of #508's fix. It is filed as #510 rather than fixed
  here, so #508 can converge on its own literal, unambiguous scope.

TC-LEASE-027 is adjusted accordingly: it now asserts the fast path is byte-identical under
NORMAL (non-adversarial) conditions — proving the code path is untouched by this PR — and
no longer asserts losslessness under the EAGAIN harness, since that property is false for
some `cat` implementations and asserting it would just reintroduce the same CI-observed
failure the round-2 removal was trying (out of scope) to fix.

## Out of scope

Dispatcher-side hardening of the `crashed-session-retry` / INV-85 misclassification chain
(the consumer was fed corrupted input; fixing the producer removes the input class).
Changing the wrapper's `exec > >(tee ...)` topology or Node's stdio flags. The remote-SSM
log probe (reads the same file post-hoc; fixed by the same producer fix). The review-side
`cat` fast path's own EAGAIN/data-drop hazard (discovered during round 2, reverted in
round 8 per the "Review-side `cat` EAGAIN hazard" section above) — tracked as #510, not
fixed here.

## Test plan

See `docs/test-cases/agent-progress-lease.md` TC-LEASE-024..031, 035..037 —
`tests/unit/test-agent-progress-lease.sh`, driving the real recorder through a real
`O_NONBLOCK` pipe via a python3 `fcntl` helper: byte-identical passthrough under transient
EAGAIN pressure, the no-trailing-newline contract under retry, bounded-exhaustion
completing instead of hanging, the zero-`AGENT_PROGRESS_FILE` fast path staying an
unmodified bare `cat` (byte-identical under normal, non-adversarial conditions — not
asserted lossless under EAGAIN pressure, since it provably is not for every `cat`
implementation and that hazard is explicitly out of scope), dead-reader (EPIPE) fast-fail,
the whole-record (not per-slice) retry budget, (TC-LEASE-030) a missing `awk` on `PATH`
failing safe instead of retrying forever against the SAME never-draining-reader harness
TC-LEASE-026 uses, (TC-LEASE-031) a bash with no `EPOCHREALTIME` AND a missing/broken
`date` fallback — no usable clock at all — also failing safe against that same harness,
distinct from TC-LEASE-030 because here `awk` itself runs fine; the bad input (an empty
clock reading coerced to `0`) never produces a failing exit code for the round-3 fix to
catch, (TC-LEASE-035) a clock that steps backward or freezes after `deadline` is computed
also failing safe via the clock-independent `max_attempts` ceiling, (TC-LEASE-036) a
BSD/macOS-shaped `date` stub (exit 0, non-numeric `%N` output) does NOT misclassify a
healthy clock as unavailable — it falls back to `date +%s` and the record survives, and
(TC-LEASE-037) an `strace`-verified assertion (skipped, not failed, if `strace` is
unavailable) that the recorder's own `write(2)` calls to fd 1 never exceed 512 bytes for a
multi-slice record, proving the portable slice size is genuinely enforced rather than
merely happening to be safe on this box's own (4096) `PIPE_BUF`.
