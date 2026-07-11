# Test Cases: fail-closed wall-clock timeout tool detection (issue #451)

ID format: `TC-TIMEOUTGUARD-NNN`.

Closes the silent-degrade half of [INV-13](../pipeline/invariants.md#inv-13-wall-clock-cap-on-agent-invocations):
`lib-agent.sh` previously logged a one-time WARN and ran every agent
invocation with **no wall-clock bound at all** when neither `timeout` nor
`gtimeout` was on `PATH`. This is now fail-closed by default (with an opt-in
pure-shell watchdog fallback), detected and enforced at `lib-agent.sh` SOURCE
TIME — the one place guaranteed to run on the actual execution host under
every `EXECUTION_BACKEND` (`local` and `remote-aws-ssm`), mirroring the
[INV-38](../pipeline/invariants.md#inv-38-per-side-agent_launcher-precedence)
launcher-mismatch guard shape.

Tests live in:
- `tests/unit/test-agent-timeout-wrapper.sh` — extended with the fail-closed /
  watchdog / shared-detection / source-location cases below.
- `tests/e2e/run-error-envelope-e2e.sh` — extended with the PATH-stubbed E2E
  case.

## Unit — detection + mechanism logging

| ID | Scenario | Expected |
|---|---|---|
| TC-TIMEOUTGUARD-001 | `timeout` present on PATH | `_AGENT_TIMEOUT_CMD` resolves to it; startup log line names `timeout`; unchanged happy-path behavior (existing TC-WH-001/002 cases stay green) |
| TC-TIMEOUTGUARD-002 | `timeout` absent, `gtimeout` present (macOS-style PATH) | `_AGENT_TIMEOUT_CMD` resolves to `gtimeout`; startup log line names `gtimeout` |
| TC-TIMEOUTGUARD-003 | Neither present, `AGENT_TIMEOUT_WATCHDOG_FALLBACK` unset/false (default) | `lib-agent.sh` source ABORTS: `error_surface` called with `ADT_CFG_TIMEOUT_TOOL_MISSING`, actionable remediation naming `brew install coreutils` for macOS; `return 1 2>/dev/null \|\| exit 1`; no agent launch is possible because the source itself failed |
| TC-TIMEOUTGUARD-004 | Neither present, `AGENT_TIMEOUT_WATCHDOG_FALLBACK=true` | Source succeeds; startup log line names `watchdog-fallback`; no `error_surface` call |
| TC-TIMEOUTGUARD-005 | `AGENT_TIMEOUT` (dev, 4h default) and `AGENT_REVIEW_TIMEOUT` (review, 1h default) both consult the SAME `_AGENT_TIMEOUT_CMD` / fail-closed decision resolved once at source time | No divergent behavior between the two call sites; a single source-time detection serves both |

## Unit — fail-closed abort wiring

| ID | Scenario | Expected |
|---|---|---|
| TC-TIMEOUTGUARD-010 | Fail-closed abort calls `error_surface "$(error_peek_issue_arg "$@")" ADT_CFG_TIMEOUT_TOOL_MISSING ...` | Mirrors the INV-38 `ADT_CFG_LAUNCHER_CLI_MISMATCH` call shape exactly (issue-arg peek, same 4-arg + doc-link signature) |
| TC-TIMEOUTGUARD-011 | Fail-closed abort return code | Non-zero; does not burn a retry-count increment beyond the normal wrapper-abort path (same contract as the existing INV-38 guards) |
| TC-TIMEOUTGUARD-012 | Fail-closed abort with a known `--issue N` in `"$@"` | `error_surface` posts an issue comment (not a bare dispatcher-alert) |
| TC-TIMEOUTGUARD-013 | Fail-closed abort with no `--issue` in `"$@"` | `error_surface` degrades to dispatcher-alert (log-only marker `surface:"dispatcher-alert"`), same as every other lib-agent.sh startup guard |

## Unit — watchdog fallback (opt-in)

| ID | Scenario | Expected |
|---|---|---|
| TC-TIMEOUTGUARD-020 | Watchdog enabled, neither binary present, a simulated long-running child under `setsid` | The watchdog's `sleep $AGENT_TIMEOUT && kill -TERM -- -<pgid>` fires against the SAME pgid `_run_with_timeout`'s `setsid` established (not a lone PID) |
| TC-TIMEOUTGUARD-021 | Watchdog kill reaps descendants, not just the direct child | A grandchild process spawned by the simulated run is also gone after the watchdog fires (process-group kill semantics, matching `timeout --kill-after`) |
| TC-TIMEOUTGUARD-022 | Watchdog vs. a command that finishes before the bound | Watchdog's deferred kill never fires (job cancelled / no-op) — no stray delayed SIGTERM against a reused pgid |
| TC-TIMEOUTGUARD-023 | `_timeout_value_to_seconds` direct unit coverage (integer+unit forms, and unparseable forms like `1.5h`/`infinity`) | Correct seconds for `3600`/`30s`/`90m`/`2h`/`1d`; unparseable forms fall back to `14400` (4h) |
| TC-TIMEOUTGUARD-024 | Watchdog opted in with a non-integer `AGENT_TIMEOUT` (e.g. `1.5h`, a value GNU `timeout` accepts but the watchdog's seconds-converter cannot) | A WARN names the unparseable value and the 4h-default coercion — the divergence from the operator's configured duration is observable, not silent; the command still runs and its own exit code still passes through |
| TC-TIMEOUTGUARD-004b | Watchdog opted in but `setsid` is ALSO absent (e.g. bare macOS with neither coreutils nor util-linux) | `lib-agent.sh` source ABORTS fail-closed with `ADT_CFG_TIMEOUT_TOOL_MISSING`, same as TC-TIMEOUTGUARD-003 — without `setsid`, `_AGENT_RUN_PID` is not a PGID, so the watchdog's group-form kill would silently target nothing and leave the run genuinely unbounded despite the opt-in; a WARN-and-proceed here would defeat the opt-in's own purpose, so this combination is treated identically to the plain fail-closed default (PR #469 review round-1 [P1]) |
| TC-TIMEOUTGUARD-025 | Watchdog TERM-expiry against a TERM-obeying leader | `_run_with_timeout`'s reported rc is normalized to `124` (the coreutils-`timeout` TERM contract) — never the raw signal-death status (`143`) `wait` would otherwise report |
| TC-TIMEOUTGUARD-026 | Watchdog KILL-escalation against a TERM-ignoring leader with a still-alive descendant | `_run_with_timeout` does NOT return until the watchdog's own pending grace→KILL step has actually reaped the process group (verified via `kill -0` on the PGID immediately after return, and via a descendant marker file going stale) — no more cancelling the watchdog mid-escalation just because the leader's own `wait` unblocked; reported rc is normalized to `137` (the coreutils-`timeout` KILL contract), not a raw signal-death status (PR #469 review round-2 [P1]) |
| TC-TIMEOUTGUARD-027 | Watchdog KILL-escalation against a TERM-**obeying** leader (dies immediately) whose backgrounded descendant ignores TERM and survives | Same outcome as TC-TIMEOUTGUARD-026 (rc normalized to `137`, `_run_with_timeout` blocks until the group is gone), but exercised via the shape that actually defeats a `disown`ed watchdog job: the leader's own `wait` unblocks almost immediately (right after the TERM), well BEFORE the watchdog's grace-then-KILL step runs — so this case only passes if the reconciliation's `wait "$_watchdog_pid"` genuinely blocks rather than returning instantly. Fails deterministically if the watchdog job is `disown`ed (PR #469 review round-3 [P1]: `wait` on a disowned job returns rc 0 immediately without waiting) |
| TC-TIMEOUTGUARD-028 | Watchdog's 124 marker is written, but the wrapped command finishes NATURALLY in the window before the watchdog's own `kill -TERM` — the watchdog observes the group already gone and rescinds (deletes) the marker | `_run_with_timeout` reports the command's own natural exit code (e.g. `0`), NOT a fabricated `124` — the reconciliation block must treat a marker file that is GONE after `wait "$_watchdog_pid"` as proof of a rescind, not fall back to the stale pre-wait marker value it read before blocking (PR #469 review round-4 [P1]) |

## Unit — source-location static assertion

| ID | Scenario | Expected |
|---|---|---|
| TC-TIMEOUTGUARD-030 | The fail-closed / watchdog decision fires at `lib-agent.sh` LOAD TIME, not inside `run_agent`/`resume_agent`, and NOT in `dispatcher-tick.sh` | Static grep: the `ADT_CFG_TIMEOUT_TOOL_MISSING` abort site lives in `lib-agent.sh` top-level code (outside any function body), mirroring the TC-BINPF-STATIC pattern used for the other `lib-agent.sh` startup guards |
| TC-TIMEOUTGUARD-031 | `dispatcher-tick.sh` does NOT contain the authoritative code | `ADT_CFG_TIMEOUT_TOOL_MISSING` (no `_LOCAL_PREFLIGHT` suffix) never appears in `dispatcher-tick.sh` |

## Unit — remote-aws-ssm topology simulation

| ID | Scenario | Expected |
|---|---|---|
| TC-TIMEOUTGUARD-040 | Local/dispatcher host HAS `timeout`; simulated remote execution host (where `lib-agent.sh` is actually sourced) has NEITHER binary | Sourcing `lib-agent.sh` with a PATH that hides both binaries aborts fail-closed regardless of what the "dispatcher's own" PATH looks like — the check that matters is the one at the sourcing site, proving placement (not host topology) decides the outcome |
| TC-TIMEOUTGUARD-041 | Optional dispatcher-side preflight passes (binary present locally) while the simulated remote lacks it | The dispatcher-side preflight passing is NOT sufficient — `lib-agent.sh` sourced under the remote's PATH still aborts fail-closed |

## Optional dispatcher-side advisory preflight — deferred (out of scope for this PR)

The issue marks the `dispatcher-tick.sh` fast-fail preflight as strictly
**optional** ("MAY add"), explicitly non-authoritative, and explicitly NOT a
substitute for the `lib-agent.sh` check. This PR implements only the
mandatory, authoritative `lib-agent.sh`-side check (TC-TIMEOUTGUARD-001..041,
060, 061) — the minimum viable interpretation that satisfies every MUST/
MANDATORY requirement. No `dispatcher-tick.sh` change ships in this PR, so:

- `ADT_CFG_TIMEOUT_TOOL_MISSING_LOCAL_PREFLIGHT` is NOT introduced.
- There is nothing dispatcher-side to test yet; a future PR MAY add the
  fast-fail preflight (its own distinctly-named code + tests) without
  changing any behavior or test expectation here.

## E2E

| ID | Scenario | Expected |
|---|---|---|
| TC-TIMEOUTGUARD-060 | PATH stubbed to hide `timeout`/`gtimeout` on the host that sources `lib-agent.sh`; real `lib-error.sh` gh-proxy resolution | Wrapper refuses to launch an agent (source itself fails); a real issue-comment-shaped envelope naming `ADT_CFG_TIMEOUT_TOOL_MISSING` is posted through the stub `gh` proxy |
| TC-TIMEOUTGUARD-061 | Simulated `EXECUTION_BACKEND=remote-aws-ssm`: binary present in the E2E harness's own PATH, but `lib-agent.sh` is sourced under a stripped PATH standing in for the remote host | Still fails closed — the local presence never leaks into the sourcing site's decision |

## Acceptance-criteria cross-reference

- No agent run started via `lib-agent.sh` can execute unbounded on a host
  missing both binaries → TC-TIMEOUTGUARD-003/004/004b/060.
- Unchanged behavior when a binary is present → TC-TIMEOUTGUARD-001/002 +
  existing `TC-WH-001/002` in `test-agent-timeout-wrapper.sh`.
- Active mechanism visible in the startup log → TC-TIMEOUTGUARD-001/002/004.
- Authoritative check runs at `lib-agent.sh` load time in both topologies →
  TC-TIMEOUTGUARD-030/031/040/041.
- Dispatcher-side preflight (if implemented) is documented advisory-only →
  TC-TIMEOUTGUARD-050/051/061.
- `docs/pipeline/errors.md` updated with the new code(s) in the same PR (CI
  gate: `test-lib-error-envelope.sh` TC-ERR-ENVELOPE-020 drift guard).
- ShellCheck clean on all changed files.
