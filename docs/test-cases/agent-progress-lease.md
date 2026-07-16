# Test Cases — Agent-Progress Lease (Producer Half, #493)

Covers R1 (lease file contract), R2 (progress event definition), R3 (shared
recorder + adapter wiring), R4 (Claude stream-json migration). Frozen-clock +
fixture-driven; no real sleeps.

## TC-LEASE-001: launch event creates a valid lease

**Given** a fresh run with `RUN_ID` set and `issue-N.pid` containing the wrapper's `$$`
**When** the launch-progress event fires
**Then** `issue-N.progress.json` exists, mode 0600, and contains `schema_version=1`, the current `RUN_ID`, the current `issue-N.pid` content, and a numeric `updated_at_epoch`.

## TC-LEASE-002: each complete output record refreshes the lease

**Given** a running lease from TC-LEASE-001
**When** the recorder passes a second complete JSON/line record through
**Then** `updated_at_epoch` advances and `run_id`/`pid` are unchanged.

## TC-LEASE-003: heartbeat alone does NOT refresh the lease (regression)

**Given** a lease written at epoch T
**When** `install_agent_heartbeat`'s loop ticks N times with no CLI output
**Then** the lease's `updated_at_epoch` stays at T.

## TC-LEASE-004: lease `pid` mirrors current pid-file content across both publication phases

**Given** `issue-N.pid` initially holds the wrapper `$$` (phase 1)
**When** a lease write happens before `_run_with_timeout` republishes the PGID
**Then** the lease `pid` equals `$$`.
**Given** `issue-N.pid` is then rewritten to the agent PGID (phase 2)
**When** the next lease write happens
**Then** the lease `pid` equals the PGID, not the stale `$$`.

## TC-LEASE-005: atomic write — no partial JSON ever observable

**Given** a lease writer that writes to `issue-N.progress.json.tmp.<pid>` then `mv -f`
**When** a concurrent reader stats the target path throughout the write
**Then** the reader only ever sees the previous complete lease or the new complete lease, never a truncated file.

## TC-LEASE-005b: a CONCURRENT reader observes no torn/partial read

**Given** a writer looping hundreds of refreshes and a reader running concurrently in a background subshell, re-reading and `jq`-parsing the lease as fast as possible for the writer's entire run
**When** the two race
**Then** every read of an existing, non-empty lease file parses as valid JSON — proving the tmp-file+rename write path, not just a post-hoc parse of the FINAL file (which a non-atomic direct overwrite would also pass).

## TC-LEASE-006: symlinked target refused

**Given** `issue-N.progress.json` is a pre-planted symlink
**When** the writer attempts a refresh
**Then** the writer refuses (silent no-op — no write through the symlink, the symlink is left untouched); same for `issue-N.run-id`.

## TC-LEASE-007: 0600 mode asserted

**Given** any successful lease write
**When** stat'd
**Then** mode is exactly 0600 (not 0644/0664/etc).

## TC-LEASE-008: cleanup removes own-run files only

**Given** `issue-N.progress.json` and `issue-N.run-id` both carry `run_id=RUN_A`
**When** the wrapper for `RUN_A` exits and its cleanup runs
**Then** both files are removed.

## TC-LEASE-009: a newer run's files survive an old run's cleanup

**Given** `issue-N.run-id` / `issue-N.progress.json` now carry `run_id=RUN_B` (a newer run started)
**When** a stale/late cleanup for `RUN_A` executes
**Then** neither file is removed (run_id mismatch skips the unlink).

## TC-LEASE-010: prior-run lease cannot satisfy the current run

**Given** `RUN_A`'s lease/run-id files exist with fresh `updated_at_epoch`
**When** `RUN_B` starts for the same issue (new dispatch)
**Then** `RUN_B` writes `issue-N.run-id=RUN_B` and an initial lease for `RUN_B` BEFORE any agent output is observed, so no reader can attribute `RUN_A`'s freshness to `RUN_B`.

## TC-LEASE-011: Claude stream fixture — recorder pass-through is byte-identical

**Given** a realistic multi-record `stream-json --verbose` fixture (several tool-use/tool-result/assistant records plus a final `{"type":"result",...}` record)
**When** piped through the shared recorder
**Then** stdout emitted by the recorder is byte-for-byte identical to the input fixture.

## TC-LEASE-012: `is_session_completed` still classifies correctly against the stream-json fixture

**Given** the TC-LEASE-011 fixture captured as the run's log
**When** `is_session_completed` parses it
**Then** it correctly returns 0 for `end_turn`+`completed` and 1 for `prompt_too_long`/non-terminal stop reasons, exactly as it does against the legacy single-object `--output-format json` log.

## TC-LEASE-013: remote session-log probe parses the same fixture

**Given** the TC-LEASE-011 fixture on the (simulated) execution host
**When** the REAL `session-log-probe-remote-aws-ssm.sh --probe` driver runs end-to-end, with only the `aws` SSM transport stubbed (the stub decodes and executes the driver's own base64-encoded inner shell snippet locally, rather than returning a canned answer)
**Then** line 1 is the final `{"type":"result",...}` record verbatim and line 2 is a valid mtime epoch; a reframed/indented final line (same TC-LEASE-015 mutation) makes the real driver report empty, proving the pin holds through the actual driver code, not a hand-copied grep/stat snippet that could silently diverge from it.

## TC-LEASE-014: `metrics_parse_tokens` final usage totals unchanged

**Given** the TC-LEASE-011 fixture
**When** `metrics_parse_tokens` scans it
**Then** `input_tokens`/`output_tokens`/`total_tokens` match the `usage` block of the final result record (last `usage`-bearing line wins, same as today).

## TC-LEASE-015: regression pin — reframed/indented/prefixed final record breaks the parsers loudly

**Given** a mutated fixture where the final result line is re-indented (pretty-printed), prefixed with extra text before column zero, or wrapped in an outer envelope
**When** `is_session_completed` / the remote probe / `metrics_parse_tokens` run against it
**Then** at least one of them fails to classify/parse correctly, proving the pin is load-bearing (i.e. the test would catch a real regression).

## TC-LEASE-016: exit-status propagation through the recorder — 0/124/137/143

**Given** the recorder composed into a pipeline behind a stub CLI that exits 0, 124, 137, or 143 in turn
**When** the caller reads the wrapped CLI's rc via `PIPESTATUS`
**Then** it observes the CLI's real exit code, never the awk filter's own (always-0) exit.

## TC-LEASE-017: Codex/OpenCode session/thread-ID capture still works with the recorder in the pipeline

**Given** a codex `--json` fixture with a `thread.started` event and an opencode fixture with `sessionID` fields
**When** piped through `_agent_progress_recorder` composed with `_codex_capture_thread` / `_opencode_capture_session`
**Then** the thread_id / sessionID sidecar is still captured correctly AND the lease still refreshes per output record.

## TC-LEASE-018: launch-event lease write happens before first CLI output

**Given** a fresh dev-new dispatch
**When** the agent process is launched (PID/PGID published) but has not yet produced its first output record
**Then** a lease already exists with a fresh `updated_at_epoch` attributable to the launch event alone (R2 case 1).

## TC-LEASE-019: unknown-CLI fallback path also refreshes the lease

**Given** `AGENT_CMD` matches none of the six known adapters (generic fallback branch in `run_agent`)
**When** the fallback CLI emits a non-empty line
**Then** the lease refreshes exactly like a known line-framed adapter.

## TC-LEASE-020: gemini framing selection — stream-json vs line

**Given** `AGENT_DEV_EXTRA_ARGS` includes `--output-format stream-json`
**When** gemini's adapter composes the recorder
**Then** it uses JSON framing.
**Given** `AGENT_DEV_EXTRA_ARGS` omits `stream-json`
**When** gemini's adapter composes the recorder
**Then** it uses line framing.

## TC-LEASE-021: refresh COUNT (not just presence) through all seven launch paths

**Given** each of the seven dev launch paths (claude, codex, opencode, agy, kiro, gemini, and the unknown-CLI fallback) driven through the real `run_agent` dispatch with a stub CLI binary emitting a known number N of complete records, and a counting wrapper around `_agent_progress_refresh`
**When** the run completes
**Then** the counted refresh total is exactly N+1 (one launch event plus one per record) for every path — proving the recorder is actually wired into claude/codex/opencode/agy/kiro (not just the fallback and gemini, the only two paths a bare "lease file exists" check had exercised) and that it refreshes once per record, not once per command.

## Acceptance mapping

- R1 → TC-LEASE-001, 004-010, 018
- R2 → TC-LEASE-001, 003, 018
- R3 → TC-LEASE-011, 016, 017, 019, 020, 021
- R4 → TC-LEASE-011, 012, 013, 014, 015
