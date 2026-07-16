# Design Canvas — Agent-Progress Lease (Producer Half)

**Branch**: `feat/issue-493-agent-progress-lease`
**Closes**: #493
**Pipeline-docs touched**: `docs/pipeline/dev-agent-flow.md` (progress production, sidecar ownership, Claude stream-json behavior, cleanup), `docs/pipeline/adapter-spec.md` (recorder contract per adapter), `docs/pipeline/invariants.md` (new INV entry).

---

## Why

`dispatcher-tick.sh` Step 5a decides whether to SIGTERM a live dev wrapper by looking at PR `updatedAt` age. That clock does not move while the agent is editing/testing locally between pushes — observed a false-SIGTERM cycle that consumed `MAX_RETRIES` on a session that was actively working (typecheck/test/build, ~11.5 min, no push). Fixing Step 5a's decision rule is out of scope here (consumer issue #485); this issue only produces the missing signal: a **current-run agent-progress lease** that a later change can read to distinguish "actively working" from "idle."

Byte-unchanged in this PR: `dispatcher-tick.sh` (Step 5a). The lease is additive — nothing reads it yet, so this PR is independently green.

## Contract (R1) — lease files

Under `pid_dir_for_project()` (mode 0700), two wrapper-owned sidecars per issue:

- `issue-${ISSUE_NUMBER}.progress.json`:
  ```json
  {"schema_version":1,"run_id":"<current RUN_ID>","pid":12345,"updated_at_epoch":1784073600}
  ```
- `issue-${ISSUE_NUMBER}.run-id` — exactly `RUN_ID\n`.

Rules:
- Atomic write: tmp file in the same dir + `mv -f`, mode 0600. Refuse to write through a pre-existing symlink at either the tmp or final path (CWE-59, mirrors `acquire_pid_guard` / `_agy_capture_conversation`).
- `pid` is read from the **current content of `issue-N.pid`** at write time, never cached — `acquire_pid_guard` writes the wrapper `$$` first; `_run_with_timeout` republishes the session-leader PGID later. The lease always mirrors whichever is currently on disk.
- `updated_at_epoch` — `date +%s` on the execution host.
- The run-id file + an initial lease are written **before** the first agent output can be observed (right after `acquire_pid_guard`, alongside the PID-file publication), so a prior run can never lend freshness to a new run that hasn't produced anything yet.
- Wrapper cleanup deletes only files whose `run_id` matches its own `RUN_ID` (read-compare-then-unlink).

**Accepted residuals** (fail-safe for the future consumer — its UNKNOWN/defer semantics never kill on these):
1. Compare-then-unlink TOCTOU: cleanup racing a fresh dispatch could transiently delete a newer run's lease; the next output record rewrites it. A reader sees a transient UNKNOWN, never a false-fresh signal.
2. OS PID reuse is NOT detected — `pid` equality is PID-file equality, same residual as today's Step 5a `kill -0` check.
3. A lease refresh racing a reader resolves via atomic rename: the reader sees old-complete or new-complete content, never a partial write.

## Contract (R2) — what counts as progress

A progress event is:
1. the successful launch of the current agent process, immediately after its PID/PGID is published, or
2. one complete, non-empty output record emitted by the current dev CLI after launch — one JSON object for JSON/JSONL-framed adapters, one non-empty line for line-framed adapters.

NOT a progress event: the wrapper/PID heartbeat (`install_agent_heartbeat`), dispatcher polling, transport keepalives, or PR/CI/label/issue changes made by other processes. The recorder is a pass-through filter driven only by the CLI's own stdout — it must never be wired to the heartbeat loop.

## Contract (R3) — shared recorder + wiring

One shared awk-based pass-through filter in `lib-agent.sh`, `_agent_progress_recorder <framing>`, composed into all seven dev launch paths:

| Path | Framing |
|---|---|
| claude | json (one JSON object per line, stream-json) |
| codex | json |
| opencode | json |
| gemini | json when EXTRA_ARGS selects stream-json, else line |
| agy | line |
| kiro | line |
| `lib-agent.sh::run_agent` generic fallback | line |

Requirements: byte-identical stdout pass-through (never buffers/swallows), stderr untouched, exit status is the wrapped CLI's own (124/137/143 included — recorder sits in a pipeline, so callers read `PIPESTATUS[<cli-index>]`, never the filter's own exit), and composes with the existing codex/opencode session-ID capture awk filters (recorder chains before or after them in the same pipeline; each filter still sees the full stream).

## Contract (R4) — Claude stream-json migration

`adapters/claude.sh` dev-new and dev-resume switch `--output-format json` → `--output-format stream-json --verbose` (no partial-message chunking — one complete JSON object per record). The final `{"type":"result",...}` record is byte-preserved at column zero in the captured log — three existing consumers parse the last such line:
- `is_session_completed` (`lib-dispatch.sh`)
- `session-log-probe-remote-aws-ssm.sh`'s remote grep
- `metrics_parse_tokens` (`lib-metrics.sh`)

stream-json's final result object has the same shape as the old single-shot `--output-format json` payload (`type`, `stop_reason`, `terminal_reason`, `usage`), so all three consumers' existing `grep '^{"type":"result"'` / jq parsing keeps working unmodified — verified with fixtures in the test suite (regression-pinned so a future reframing/indentation/prefixing breaks loudly).

## Non-goals (deferred to #485)

Step 5a's decision rule, the progress probe, the SIGTERM rule, remote-SSM probing of the lease, the freshness threshold/conf knob, treating the heartbeat as progress, PID-reuse detection.
