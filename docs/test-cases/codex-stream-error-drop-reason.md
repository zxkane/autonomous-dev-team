# Test cases: codex transient stream-error retry + drop reason (INV-59, issue #209)

Unit tests in `tests/unit/test-lib-review-codex.sh` (extends the INV-51/53/55
suite) plus source-of-truth assertions against `autonomous-review.sh`.

The codex member of a multi-agent review fleet was dropped as an opaque
`unavailable` when its model stream died with an upstream 5xx (codex exhausts
`5/5` SSE reconnects, emits `turn.failed`). Two gaps: (1) no codex drop-reason
classifier — the comment carried no actionable cause; (2) a launch-level
`turn.failed` early-returned from the resume loop, so a brief blip was not ridden
out. INV-59 mirrors INV-58's agy approach in the codex CLI-specific lib.

## TC-CODEX-DROP-DET: `_codex_log_has_stream_error`

| ID | Input (codex `--json` JSONL log) | Expected rc |
|----|----------------------------------|-------------|
| TC-CODEX-DROP-DET-01 | `Reconnecting... 5/5 …` ladder ending in `turn.failed` (stream disconnected) | rc 0 (stream error) |
| TC-CODEX-DROP-DET-02 | clean `turn.completed`, no verdict (#198 gather/narration case) | rc 1 (no stream error — no over-claim) |
| TC-CODEX-DROP-DET-03 | a `turn.completed` PASS-verdict turn | rc 1 (no stream error) |
| TC-CODEX-DROP-DET-04 | a `turn.failed` with `error.message` containing `stream disconnected before completion` (no ladder) | rc 0 |
| TC-CODEX-DROP-DET-05 | empty file / missing path / empty arg | rc 1 (fail-safe, no crash) |
| TC-CODEX-DROP-DET-06 | a tool-output line that merely contains the literal substring `turn.failed` (codex grepping its own log) | rc 1 (not a false positive — type must be the event type) |
| TC-CODEX-DROP-DET-07 | committed fixture (sanitized real codex stream-error log) | rc 0 |

## TC-CODEX-DROP-CLS: `_classify_codex_drop_reason`

| ID | Input | Expected stdout |
|----|-------|-----------------|
| TC-CODEX-DROP-CLS-01 | `Reconnecting... 5/5` ladder + `turn.failed` | `stream-error:5/5` |
| TC-CODEX-DROP-CLS-02 | `turn.failed` stream error, no reconnect ladder visible | `stream-error` |
| TC-CODEX-DROP-CLS-03 | clean no-verdict turn (#198) | `` (empty — caller keeps bare `unavailable`) |
| TC-CODEX-DROP-CLS-04 | verdict turn | `` (empty) |
| TC-CODEX-DROP-CLS-05 | empty / missing / empty-arg log | `` (empty, no crash) |
| TC-CODEX-DROP-CLS-06 | runs cleanly under `set -euo pipefail` (command-subst call, ladder log) | rc 0 |
| TC-CODEX-DROP-CLS-07 | committed stream-error fixture | `stream-error:5/5` |
| TC-CODEX-DROP-CLS-08 | **bare** call under `set -euo pipefail` with a `turn.failed` no-ladder log (the ladder-extraction pipeline's grep-no-match rc 1 must not abort the body before `return 0`) | `stream-error` + reaches `return 0` (no errexit abort) |

## TC-CODEX-DROP-PHR: `_codex_drop_reason_phrase`

| ID | Input token | Expected (substring) |
|----|-------------|----------------------|
| TC-CODEX-DROP-PHR-01 | `stream-error:5/5` | contains `stream-error`, `5/5`, `reconnect` |
| TC-CODEX-DROP-PHR-02 | `stream-error` (no ladder depth) | contains `stream-error`, no `5/5` |
| TC-CODEX-DROP-PHR-03 | `` (empty) | empty |

## TC-CODEX-DROP-RETRY: resume loop rides out a transient stream error

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CODEX-DROP-RETRY-01 | turn-1 rc non-zero (non-124/137) WITH a fresh stream-error signal in the log, then a clean verdict on resume | enters the resume loop, ≥1 resume fires, converges (does NOT early-return) |
| TC-CODEX-DROP-RETRY-02 | turn-1 rc non-zero (non-124/137) WITHOUT a stream-error signal (genuine launch failure) | early-returns immediately, 0 resumes (unchanged behavior) |
| TC-CODEX-DROP-RETRY-03 | sustained: every turn has a stream-error, max=2 | exactly 2 resumes then degrade (bounded — graceful), no infinite retry |

## TC-CODEX-DROP-LOOP: drop-reason augmentation loop (behavioral)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CODEX-DROP-LOOP-01 | codex dropped on a stream-error log | reason names `codex: stream-error` |
| TC-CODEX-DROP-LOOP-02 | codex dropped on a generic/no-signal log | empty reason (bare `unavailable` preserved) |
| TC-CODEX-DROP-LOOP-03 | BOTH agy (quota) AND codex (stream-error) dropped in the SAME fan-out | reasons list a distinct clause for EACH (the AC #2 regression guard) |
| TC-CODEX-DROP-LOOP-04 | a non-codex/non-agy unavailable agent (kiro) | adds no reason |

## TC-CODEX-DROP-SRC: source-of-truth wiring (`autonomous-review.sh`)

| ID | Assertion |
|----|-----------|
| TC-CODEX-DROP-SRC-01 | wrapper captures the per-agent codex log path into `AGENT_CODEX_LOGS` for codex members |
| TC-CODEX-DROP-SRC-02 | wrapper calls `_classify_codex_drop_reason` when an `unavailable` agent is `codex` |
| TC-CODEX-DROP-SRC-03 | the dropped-agent reason assembly interpolates the codex reason phrase (`_codex_drop_reason_phrase`) — not only the agy branch |
| TC-CODEX-DROP-SRC-04 | `bash -n` parses `lib-review-codex.sh` AND `autonomous-review.sh` |

## TC-CODEX-DROP-REG: regression

| ID | Assertion |
|----|-----------|
| TC-CODEX-DROP-REG-01 | a stream-error codex drop is NOT reported with the identical opaque `unavailable` string a launch failure produces (distinct reason) |
| TC-CODEX-DROP-REG-02 | a clean no-verdict turn (#198) is NOT misreported as a stream error (classifier returns empty) |
| TC-CODEX-DROP-REG-03 | INV-40 aggregation truth table unchanged — a stream-error codex is still DROPPED (`unavailable`), not a deciding FAIL; `test-autonomous-review-multi-agent` / `test-review-agent-timeout` stay green |
