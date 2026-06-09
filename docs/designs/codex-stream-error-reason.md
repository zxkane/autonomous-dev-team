# Design: codex transient stream-error retry + drop reason (INV-59, #209)

## Problem

When a `codex` review fan-out member's model stream dies with an upstream
server error, the codex CLI exhausts its `5/5` SSE reconnects and emits
`turn.failed`. The review wrapper then drops codex as an **opaque
`unavailable`**:

- `lib-review-aggregate.sh::_classify_noverdict_agent` maps the non-124/137
  launch rc through its `*)` default → `unavailable` (dropped from the vote).
- The `autonomous-review.sh` drop-reason assembly loop only enriches the reason
  for `agy` (INV-58); every other agent — codex included — gets an **empty**
  `_dropped_reasons` entry, so the comment reads `dropped (unavailable)
  agent(s): codex` with no actionable cause.
- `lib-review-codex.sh::_run_codex_review_with_resume` early-returns on a
  non-zero, non-timeout launch rc (`lib-review-codex.sh:265`), so a launch-level
  `turn.failed` stream failure never even enters the bounded resume loop — a
  brief blip is not ridden out.

## Goals (ACs)

1. A codex `turn.failed` from a stream/server error produces a **specific,
   non-empty** drop reason (`codex: stream-error (...)`), not a bare
   `unavailable`, in the dropped-agent log line and the issue comment.
2. The drop-reason assembly enriches reasons for codex (not only agy); a fan-out
   that drops BOTH agy and codex lists a distinct reason for each.
3. A **transient** stream error is handled as retryable: a brief blip does not
   permanently drop codex's vote (the resume loop issues another turn within the
   review window), while a **sustained** outage still degrades gracefully to the
   surviving fleet (bounded resumes exhaust → dropped, with a reason).
4. A clean **no-verdict** turn (the #198 case) is NOT misreported as a stream
   error (no over-claim).
5. Regression tests cover the three scenarios and fail on pre-fix code.

## Approach — mirror INV-58 (agy), in the codex CLI-specific lib

### Half 1: codex drop-reason classifier (observability)

Add to `lib-review-codex.sh` (the existing codex review-side lib):

- `_codex_log_has_stream_error <log_file>` — rc 0 iff the codex JSONL log's last
  completed/failed turn shows a stream/server error signal: a `turn.failed`
  whose `error.message` contains `stream disconnected before completion`, OR the
  `Reconnecting... N/5 (stream disconnected ...)` ladder. Single-pass `awk`, no
  jq (mirrors `_codex_log_has_verdict_message`). **Fail-safe**: missing/empty/
  unreadable log → rc 1.
- `_classify_codex_drop_reason <log_file>` — echoes ONE token (rc 0 always):
  - `stream-error[:N/5]` — `turn.failed` stream error present (the `N/5`
    reconnect-ladder depth appended when the log shows it).
  - `""` (empty) — neither signal → caller keeps bare `unavailable`. A clean
    `turn.completed` with no verdict (the #198 gather/narration case) yields
    EMPTY (no over-claim, AC #4).
- `_codex_drop_reason_phrase <token>` — renders the token into a human clause:
  `stream-error (upstream 5xx; exhausted N/5 SSE reconnects, turn.failed)`.

Wire into `autonomous-review.sh`:

- Capture each codex member's per-agent JSONL log path into a new parallel array
  `AGENT_CODEX_LOGS` during fan-out (the path is the deterministic `$_agent_log`
  the codex invocation already writes / `CODEX_REVIEW_LOG` points at).
- In the `_dropped_reasons` assembly loop, add a `codex` branch next to the agy
  branch: if the dropped agent is codex, classify its log and append the phrase.

This is **observability only** — it does NOT change the INV-40 vote. A
stream-error codex stays DROPPED (`unavailable`), exactly as today. A server-side
5xx is an infra condition, not a code rejection; promoting it to a deciding FAIL
veto would block merges whenever the provider blips (worse than degrading to the
surviving fleet). `_classify_noverdict_agent` / `_aggregate_review_verdicts`
are untouched. (Same posture INV-58 takes for agy quota.)

### Half 2: ride out a transient blip inside the resume loop (retry)

Today the loop early-returns on a non-zero, non-124/137 launch rc
(`lib-review-codex.sh:265`), so a `turn.failed` stream-error never enters the
resume loop. Change: when the launch rc is non-zero/non-timeout BUT the log shows
a **fresh stream error** (`_codex_log_has_stream_error`), do NOT early-return —
fall through into the bounded resume loop so the controller issues another turn.

- A **brief** blip: the next turn succeeds → codex posts a verdict → its vote is
  NOT lost (AC #3 first half).
- A **sustained** outage: each resumed turn hits the same 5xx; the loop exhausts
  `CODEX_REVIEW_MAX_RESUMES` and degrades to `unavailable` with the
  `stream-error` reason surfaced (AC #3 second half).

The existing bounds (max-resume count + `AGENT_REVIEW_TIMEOUT` wall-clock) already
cap "N pointless resumes against a sustained outage", so option (a) in the issue
is satisfied without a new terminal `retryable` state or dispatcher coordination
(simpler, more maintainable — autonomous decision guideline). A genuine
non-stream launch failure (rc 1, no stream-error signal) still early-returns
exactly as before — no regression.

The INV-48 timeout rc-stickiness is unchanged. The final rc remains the last
invocation's rc (or sticky 124/137), so a stream-error-then-still-no-verdict run
still resolves `unavailable` via the post-window sweep.

## New invariant

`INV-59` in `invariants.md`: "codex transient stream-error drops surface a
distinct reason and are ridden out by the resume loop, not opaquely dropped."
`review-agent-flow.md` gains a "codex stream-error drop reason (INV-59)" section.

## Out of scope (per issue)

- codex SSE `stream_max_retries` (the amazon-bedrock provider takes no per-provider
  retry override).
- the upstream 5xx itself.
- drop-reason classifiers for kiro/claude/gemini/opencode.
