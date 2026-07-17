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

## TC-LEASE-022: a stale cleanup INTERLEAVED with a fresh init cannot split the two sidecars (round-2 regression)

**Given** `RUN_A`'s stale cleanup has already read `issue-N.run-id` (observing `RUN_A`, matching its own `RUN_ID`) but has not yet unlinked it
**When** `RUN_B`'s init fires for the same issue WHILE that window is open, overwriting both sidecars to `RUN_B`
**Then** `RUN_A`'s cleanup — which resumes only after `RUN_B`'s init fully completes, serialized by a shared `flock` around both functions' read-decide-act section — no longer unlinks the now-`RUN_B` run-id file; `issue-N.run-id` and `issue-N.progress.json` both still name `RUN_B` afterward. Without the lock, `RUN_A`'s cleanup would delete the run-id file unconditionally (its `rm` doesn't re-check content after the read), leaving `run-id` GONE while `progress.json` still names `RUN_B` — a split state that, unlike the TC-LEASE-009 compare-then-unlink residual, never self-heals.

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

## TC-LEASE-020b: gemini framing selection also recognizes the equals-joined form (round-2 regression)

**Given** `AGENT_DEV_EXTRA_ARGS` includes the equals-joined single-token `--output-format=stream-json` (not the two-token form TC-LEASE-020 covers) AND the CLI emits a truncated/malformed final record
**When** gemini's adapter composes the recorder
**Then** it uses JSON framing — proven by the truncated final record NOT refreshing the lease (refresh count is 1 launch event + 1 complete record, never 3). Before the fix, the equals form was invisible to the adapter's scan, so this configuration fell through to line framing and the truncated record would have wrongly refreshed as a plain nonempty line.

## TC-LEASE-021: refresh COUNT (not just presence) through all seven launch paths

**Given** each of the seven dev launch paths (claude, codex, opencode, agy, kiro, gemini, and the unknown-CLI fallback) driven through the real `run_agent` dispatch with a stub CLI binary emitting a known number N of complete records, and a counting wrapper around `_agent_progress_refresh`
**When** the run completes
**Then** the counted refresh total is exactly N+1 (one launch event plus one per record) for every path — proving the recorder is actually wired into claude/codex/opencode/agy/kiro (not just the fallback and gemini, the only two paths a bare "lease file exists" check had exercised) and that it refreshes once per record, not once per command.

## TC-LEASE-023: lock unavailability degrades gracefully under `set -e` (round-2 regression, caught on re-review)

**Given** `lib-agent.sh` sourced under the wrapper's REAL `set -euo pipefail` (not the test harness's deliberately-relaxed `set -uo pipefail`) with `flock` absent from `PATH` (a symlink farm omitting only `flock`, never a real bin dir that would still resolve the system binary)
**When** `_agent_progress_init` then `_agent_progress_cleanup` run
**Then** both complete (rc=0, run-id/lease still written unlocked) instead of the caller aborting — proving the `_agent_progress_lock_acquire _lock_fd || true` guard at both call sites is load-bearing: a bare (unguarded) call trips `set -e` on the helper's documented "return 1 when locking is unavailable" contract and aborts the whole wrapper before the agent is ever launched, the opposite of the "best-effort, degrades to unlocked" promise TC-LEASE-022's fix was supposed to preserve.

## TC-LEASE-032: review-side (zero-`AGENT_PROGRESS_FILE`) fast path is byte-identical under EAGAIN pressure (issue #510)

**Given** the recorder's zero-`AGENT_PROGRESS_FILE` fast path (the review-side invocation shape) driven through a real `O_NONBLOCK` pipe (python3 `fcntl` helper) with a reader that stalls long enough to force genuine `EAGAIN`, then drains slowly
**When** a ~140KB/500-line fixture (final record with no trailing newline) is piped through
**Then** the fast path's output is byte-identical to the fixture (checksum + line count match, including the final no-trailing-newline `{"type":"result"}` record) and no write-error diagnostic reaches stderr — red before the fix (reproducible against a GNU coreutils `cat`, which drops data under this exact pressure), green after.

## TC-LEASE-033: review-side fast path stays byte-identical under normal conditions (no regression)

**Given** the same fixture as TC-LEASE-032, without EAGAIN pressure
**When** piped through the fast path
**Then** output is byte-identical — the non-adversarial happy path this fix must preserve.

## TC-LEASE-034: closed-reader `SIGPIPE` is classified as terminal, not retried as EAGAIN (issue #510 round-1 review regression)

**Given** the fast path's write helper (`_agent_progress_recorder_fastpath_write`) writing to a pipe whose reader has already exited (a genuinely dead reader, not a merely-stalled one)
**When** the write's underlying `printf` is killed outright by an un-ignored `SIGPIPE` (exit 141, empty captured stderr) rather than catching the error in-process and printing "write error: Broken pipe" itself
**Then** the helper still classifies the failure as terminal and drops the record immediately (well under the ~2s retry budget, in particular under 500ms) with a "Broken pipe" diagnostic on stderr — before the fix, a bare exit-code check for 141 fell through every time to the EAGAIN retry branch (the captured `err` was empty, so the `"Broken pipe"` substring match never fired), burning the entire retry budget against a reader that could never drain.

## Acceptance mapping

- R1 → TC-LEASE-001, 004-010, 018, 022, 023
- R2 → TC-LEASE-001, 003, 018
- R3 → TC-LEASE-011, 016, 017, 019, 020, 020b, 021
- R4 → TC-LEASE-011, 012, 013, 014, 015
- Issue #510 (review-side fast path EAGAIN retry) → TC-LEASE-032, 033, 034
