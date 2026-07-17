# Design: review-side `cat` fast path drops output records on EAGAIN (#510)

## Problem

`_agent_progress_recorder` (`lib-agent.sh`) is composed into every dev/review
launch pipeline. When `AGENT_PROGRESS_FILE` is unset — always true on the
review side, since only `autonomous-dev.sh` exports it — the function takes a
"fast path" that is a bare `cat`:

```bash
_agent_progress_recorder() {
  local framing="${1:-line}"
  if [[ -z "${AGENT_PROGRESS_FILE:-}" ]]; then
    cat
    return 0
  fi
  ...
}
```

The wrapper's stdout is `exec > >(tee -a run.log) 2>&1` — the write end is a
pipe shared (same open file description) with the CLI child's own stdio, and
the CLI (Node.js, for Claude) sets `O_NONBLOCK` on it. Once the reader
(`tee`) falls behind, `cat`'s own `write(2)` calls can get `EAGAIN`. GNU
coreutils `cat` (confirmed: the `ubuntu-latest` CI runner's `cat`, and this
box's `gnucat` alias, both GNU coreutils 9.7) does not retry `EAGAIN` and
silently drops the unwritten remainder — reproduced locally: a 500-line/
~140KB fixture through `gnucat` under an `O_NONBLOCK` pipe with a stalling
reader landed only 233 of 500 lines, `write error: Resource temporarily
unavailable` on stderr. This is the exact same bug class issue #508 fixed for
the dev-side `printf`, just via a different external-process write path
(`cat`, not a bash builtin).

Some `cat` implementations (e.g. this box's default rust/uutils `cat`,
`0.8.0`) happen to retry and are lossless under the same pressure — but the
project's CI runner and many production hosts run GNU coreutils, so the
review wrapper's `run.log` is not reliably byte-identical to the agent's
actual output there.

## Why fix this now, and why not reuse #508's helper

Issue #508 ("bounded EAGAIN retry in agent-progress recorder") targets the
**dev-side** `printf` write path and, as of this writing, is still an open,
unmerged PR (#509) — `main` has no `_agent_progress_write_retry` helper yet.
#508's own "Mandated fix shape" text explicitly scopes that fix to the dev
write path and requires the review-side `cat` fast path be left unchanged;
review rounds on #509 upheld that scope boundary and rejected expanding it
in-PR. #510 exists precisely to close the review-side gap as its own
scoped, independently mergeable change — it must not depend on or duplicate
#509's still-in-flight helper.

## Fix

Replace the bare `cat` fast path with a small, self-contained bounded-retry
read/write loop, scoped ONLY to the zero-`AGENT_PROGRESS_FILE` branch. The
retry-carrying branch (`AGENT_PROGRESS_FILE` set — the dev side) is
byte-for-byte unchanged; this PR does not touch it, so it stays entirely
`#508`'s scope to fix when that PR lands.

`_agent_progress_recorder_fastpath_write <bytes>`:
- Writes `bytes` to fd 1 in `PIPE_BUF`-sized (4096) slices under `LC_ALL=C`
  (mirrors the slicing rationale from #508's design: bash's `printf` can
  itself perform a genuine partial write before erroring, and a
  `PIPE_BUF`-sized pipe write is POSIX-atomic, so no chunk is ever resent
  after a success).
- On a failed slice, classifies the error: "Broken pipe" (EPIPE, a dead
  reader) drops immediately with a diagnostic; anything else (EAGAIN-shaped)
  retries with a bounded ~2s whole-record budget (`sleep 0.05` between
  attempts), then drops with a diagnostic on exhaustion.
- A missing/broken `awk` or clock reading fails safe (treated as immediate
  exhaustion), not as an unbounded retry loop — same posture #508 adopted
  for the dev-side helper, needed here for the same reason (a spinning
  review wrapper is as bad as a spinning dev wrapper).

The zero-`AGENT_PROGRESS_FILE` branch becomes a `read`/`printf`-via-retry
loop identical in shape to the existing (`AGENT_PROGRESS_FILE` set) branch's
read loop, but calling the new retry-write helper instead of `_agent_
progress_refresh`-adjacent code, and never calling `_agent_progress_refresh`
itself (there is no lease to refresh on this branch — unchanged from
before).

## Scope

**In scope**: the zero-`AGENT_PROGRESS_FILE` fast path in
`_agent_progress_recorder` only.

**Out of scope** (per the issue):
- The dev-side (`AGENT_PROGRESS_FILE` set) write path — untouched, `#508`'s
  scope.
- The `exec > >(tee -a run.log) 2>&1` topology itself.
- Any downstream consumer of the review wrapper's `run.log` (none exist for
  completion detection today — `is_session_completed` only ever reads the
  dev wrapper's log).

## Testing

Extends `tests/unit/test-agent-progress-lease.sh` with the same
`drive_recorder.py` `O_NONBLOCK`-pipe harness shape #508 uses (a python3
`fcntl` helper that stalls the reader long enough to force real `EAGAIN`,
then drains slowly), driving the REAL `_agent_progress_recorder` with
`AGENT_PROGRESS_FILE` unset:

- **TC-LEASE-032**: byte-identical passthrough (checksum + line count),
  including the final no-trailing-newline record, under genuine `EAGAIN`
  pressure on the fast path — red before the fix (fails against the old
  bare `cat`), green after.
- **TC-LEASE-033**: the existing NORMAL-conditions fast-path passthrough
  stays byte-identical (no regression to the non-adversarial happy path).

## Invariants

Updates `docs/pipeline/invariants.md` INV-135 to document that the
zero-`AGENT_PROGRESS_FILE` fast path is now retry-protected against the same
`EAGAIN` hazard as the dev-side write path, closing the gap #508 explicitly
left open for the review side.
