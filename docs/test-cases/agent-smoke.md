# Test Cases: agent-smoke (`lib-agent-smoke.sh` + `run-agent-smoke.sh`)

Issue: #222 — three-state `smoke_agent` lib + PR-gating matrix harness.

ID format: `TC-AGENT-SMOKE-NNN`.

## Unit — `smoke_agent` three-state rc mapping (stub CLIs + fixtures)

| ID | Scenario | Expected |
|---|---|---|
| TC-AGENT-SMOKE-001 | Stub CLI echoes the exact nonce on stdout | rc 0 (PASS); evidence `SMOKE <agent> PASS <e>s reason=nonce-ok` |
| TC-AGENT-SMOKE-002 | Stub CLI prints a truncated/garbled echo of the nonce | rc 1 (FAIL) — exact match required, no partial credit |
| TC-AGENT-SMOKE-003 | Stub `agy` exits empty + the agy quota fixture written to its `--log-file` | rc 2 (UNAVAILABLE); reason names `quota-exhausted` |
| TC-AGENT-SMOKE-004 | Stub `kiro` exits empty + kiro auth fixture on its log | rc 1 (FAIL); reason names `auth-failed` |
| TC-AGENT-SMOKE-005 | Stub `codex` stream-error fixture, no nonce | rc 2 (UNAVAILABLE); reason names `stream-error` |
| TC-AGENT-SMOKE-006 | Stub CLI exits non-zero, no nonce, no recognizable signal | rc 1 (FAIL); reason `no-response` |
| TC-AGENT-SMOKE-007 | Stub CLI sleeps past the smoke timeout (hangs) with no output | rc 1 (FAIL); reason `timeout` (timeout = config/launch breakage) |
| TC-AGENT-SMOKE-008 | Stub `agy` hangs past timeout BUT quota signal already in its log | rc 2 (UNAVAILABLE) — environmental signal wins over the bare timeout |
| TC-AGENT-SMOKE-009 | Nonce is unique per call (two calls → two different nonces) | distinct nonces; no `$RANDOM`-only collision in a tight loop |
| TC-AGENT-SMOKE-010 | `smoke_agent` invoked under `set -euo pipefail` (command-subst + bare) | never aborts; returns a clean 0/1/2 |
| TC-AGENT-SMOKE-011 | Evidence line format is stable: `SMOKE <agent> <STATE> <N>s reason=<...>` | regex-matched; consumed by the INV-46 command-mode evidence parser |
| TC-AGENT-SMOKE-012 | `smoke_agent` goes through `run_agent` (not a parallel invocation path) | source-of-truth: lib calls `run_agent`, sets `AGENT_CMD`/`AGENT_TIMEOUT` |
| TC-AGENT-SMOKE-038 | Session id is a valid UUID (claude `--session-id` requires it); each source branch + fallback | shape, uniqueness, all branches valid |
| TC-AGENT-SMOKE-039 | Stream separation — nonce on stderr (stdout empty) → not PASS; stdout-only check | FAIL/`no-response`; not a false PASS |
| TC-AGENT-SMOKE-045 | Successful-exit gate — nonce on stdout but non-zero exit → not PASS | FAIL; rc 0 + nonce → PASS |
| TC-AGENT-SMOKE-046 | Timeout normalization — suffixed `5s` not double-suffixed `5ss`; bare/unit forms | all → PASS |
| TC-AGENT-SMOKE-047 | **kiro-tty-decoration** — BEL (0x07) + ANSI inside the echoed token; sanitized stdout-only check | raw grep misses, helper recovers; `kiro 0` decorated → PASS; decorated + non-zero exit → still not PASS |

## Unit — harness matrix parser + aggregation

| ID | Scenario | Expected |
|---|---|---|
| TC-AGENT-SMOKE-020 | Well-formed entry `name\|agent\|model\|env` parses into 4 fields | parsed; env-setup eval'd in subshell |
| TC-AGENT-SMOKE-021 | Malformed entry (too few `\|` fields) | rejected loudly (stderr), harness rc 1 — not silently skipped |
| TC-AGENT-SMOKE-022 | Empty matrix (no entries after comment/blank strip) | rc 1 (nothing to smoke is a misconfig, not a pass) |
| TC-AGENT-SMOKE-023 | Comment + blank lines ignored | only data rows parsed |
| TC-AGENT-SMOKE-024 | One entry FAIL, rest PASS | overall rc 1 |
| TC-AGENT-SMOKE-025 | All entries PASS | overall rc 0 |
| TC-AGENT-SMOKE-026 | UNAVAILABLE-only (no FAIL) | overall rc 0 (non-blocking) |
| TC-AGENT-SMOKE-027 | `require:VAR` directive, VAR unset after env-setup | entry SKIP, not FAIL; non-blocking |
| TC-AGENT-SMOKE-028 | `require:VAR` directive, VAR present | entry runs normally |
| TC-AGENT-SMOKE-029 | Mixed: pass + fail + unavailable + skip | `SMOKE-SUMMARY pass=N fail=N unavailable=N skip=N` correct; rc 1 (the fail) |
| TC-AGENT-SMOKE-030 | Summary line present exactly once, last | `SMOKE-SUMMARY pass=... fail=... unavailable=... skip=...` |
| TC-AGENT-SMOKE-031 | Entries run in parallel (wall-clock ≈ slowest, not sum) | total elapsed < sum of per-entry sleeps |

## E2E — harness stub-mode self-test (the CI E2E artifact)

| ID | Scenario | Expected |
|---|---|---|
| TC-AGENT-SMOKE-040 | `SMOKE_STUB=1 bash tests/e2e/run-agent-smoke.sh` against the bundled stub matrix | full harness runs end-to-end with no real CLIs/credentials; prints one `SMOKE ...` per entry + `SMOKE-SUMMARY` |
| TC-AGENT-SMOKE-041 | Stub matrix includes a deliberately-broken (FAIL) entry | overall rc 1; that entry's line shows FAIL |
| TC-AGENT-SMOKE-042 | Stub matrix includes a quota-walled (UNAVAILABLE) entry | recorded UNAVAILABLE, does NOT fail the run on its own |
| TC-AGENT-SMOKE-043 | Stub matrix includes a missing-required-env (SKIP) entry | recorded SKIP, does NOT fail the run |

## Source-of-truth / wiring

| ID | Scenario | Expected |
|---|---|---|
| TC-AGENT-SMOKE-050 | Lib + harness pass `bash -n` | both parse |
| TC-AGENT-SMOKE-051 | Lib sources `lib-agent.sh` + the three drop-reason libs by BASH_SOURCE-relative path (INV-14) | greps confirm |
| TC-AGENT-SMOKE-052 | CI shellcheck job lists `lib-agent-smoke.sh` + `run-agent-smoke.sh` | grep `.github/workflows/ci.yml` |
| TC-AGENT-SMOKE-053 | CI runs the stub-mode self-test | grep `.github/workflows/ci.yml` for `SMOKE_STUB` |
| TC-AGENT-SMOKE-054 | `.gitignore` covers `tests/e2e/e2e.conf` | grep |
| TC-AGENT-SMOKE-055 | `e2e.conf.example` contains no real keys; covers the 5 required CLI shapes | grep for the entry names; assert no obvious secret patterns |
| TC-AGENT-SMOKE-056 | Docs: `docs/pipeline/agent-smoke.md` exists + `INV-63` entry + `autonomous-pipeline.md` reference | grep |

## Acceptance Criteria mapping (verified by the review agent, not marked here)

- `bash tests/e2e/run-agent-smoke.sh` on a box with CLIs → parallel run, one `SMOKE` line per entry + `SMOKE-SUMMARY` → TC-040.
- Broken entry (bogus region) → FAIL + overall rc 1 → TC-041, TC-007.
- Quota-walled agy → UNAVAILABLE, non-blocking → TC-003, TC-042.
- Missing required env → SKIP, non-blocking → TC-027, TC-043.
- All existing unit tests still pass + new tests pass in CI stub mode → full suite.
- ShellCheck on new lib + harness → TC-052.
- Pipeline docs updated same PR → TC-056.
