# Test Cases: codex review deterministic argv rejection → `config-error` (INV-62, #223)

**Issue**: #223
**Invariant**: [INV-62](../pipeline/invariants.md#inv-62-the-codex-review-lane-runs-the-codex-review-subcommand-auto-scoped-prompt-carried-gate-with-a-stdout-verdict-fallback) (sub-rules 2 + 5 extended — no new INV number)
**Test file**: `tests/unit/test-lib-review-codex.sh`
**Fixture**: `tests/unit/fixtures/codex-review-stdout-config-error.txt`

## Background

`codex review` accepts only `-c/--config`, `--base`, `--commit`,
`--uncommitted`, `--title`, `--enable`, `--disable` (verified 0.137.0). A pre-#218
`codex exec`-era sandbox flag left in `AGENT_REVIEW_EXTRA_ARGS_CODEX` (e.g.
`-s danger-full-access`) is spliced verbatim into the argv and rejected with an
**exit-2 clap parse error** (`error: unexpected argument '-s' found`). Before this
fix the INV-62 re-run controller misread the deterministic rejection as a
transient stream blip, re-ran the identical argv to `CODEX_REVIEW_MAX_RERUNS`
exhaustion, and dropped codex as a bare `unavailable` with no reason naming the
flag.

The fix recognizes the clap signature on the FIRST run (skip remaining re-runs)
and surfaces a `config-error:<flag>` drop reason. The argv stays a faithful
passthrough — the rejection is caught at runtime, not pre-filtered.

## Acceptance: every TC below must pass; the full unit suite stays green.

### Unit — deterministic-rejection detector (`_codex_review_argv_rejection_flag`)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-CFG-DET-01 | capture with `error: unexpected argument '-s' found` + `Usage: codex review` | echoes `-s` |
| TC-CXRS-CFG-DET-02 | capture with `error: invalid value 'x' for '--enable <CHECK>'` | echoes `--enable` |
| TC-CXRS-CFG-DET-03 | a clean review that merely says "no unexpected argument issues" in prose (no leading `error:`) | echoes empty (no false match) |
| TC-CXRS-CFG-DET-04 | a stream-error capture (`stream disconnected …`) | echoes empty (not a clap rejection) |
| TC-CXRS-CFG-DET-05 | empty / missing / empty-arg file | echoes empty, rc 0 (fail-safe) |
| TC-CXRS-CFG-DET-06 | bare call under `set -euo pipefail`, no-match capture | no errexit abort, empty echoed |

### Unit — re-run controller skips re-runs on a deterministic rejection (`_run_codex_review`)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-CFG-RUN-01 | run 1 exits rc 2 with a clap `unexpected argument '-s'` capture, `CODEX_REVIEW_MAX_RERUNS=3` | **1 run, NO re-runs**, returns rc 2 (deterministic — re-running can never succeed) |
| TC-CXRS-CFG-RUN-02 | regression: run 1 exits rc 1 with a **stream-error** capture, then a clean re-run | 2 runs (transient ridden out, #209 unchanged), rc 0 |
| TC-CXRS-CFG-RUN-03 | run 1 exits rc 2 with a clap capture even when `CODEX_REVIEW_MAX_RERUNS=0` | 1 run, rc 2 (no change vs the disabled-rerun path) |

### Unit — `config-error` drop reason (`_classify_codex_drop_reason` + `_codex_drop_reason_phrase`)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-CFG-DROP-01 | clap `unexpected argument '-s'` capture | token `config-error:-s` |
| TC-CXRS-CFG-DROP-02 | `invalid value … for '--enable'` capture | token `config-error:--enable` |
| TC-CXRS-CFG-DROP-03 | a stream-error capture (no clap signature) | token `stream-error:5/5` (config-error does NOT shadow stream-error) |
| TC-CXRS-CFG-DROP-04 | a clean / `[P1]` review | empty token (no over-claim) |
| TC-CXRS-CFG-PHR-01 | `_codex_drop_reason_phrase "config-error:-s"` | a clause naming `-s` and "exec-only flag in extra-args" |
| TC-CXRS-CFG-PHR-02 | `_codex_drop_reason_phrase "config-error:"` (no flag) | a generic config-error clause, no spurious flag |
| TC-CXRS-CFG-DROP-05 | fixture-backed: `codex-review-stdout-config-error.txt` | token `config-error:-s` |

### Unit — revised argv-passthrough fixture (was TC-CXRS-LAUNCH-06)

| ID | Scenario | Expected |
|----|----------|----------|
| TC-CXRS-LAUNCH-06 | `AGENT_DEV_EXTRA_ARGS="-s danger-full-access"` → `_codex_review_argv` | `-s` and `danger-full-access` still appear as DISTINCT argv elements (faithful passthrough — the fix catches the rejection at RUNTIME, it does NOT pre-filter the argv); a comment cross-references that `codex review` rejects `-s` and the runtime path now surfaces `config-error` |

## Regression direction

- **Before the fix**: TC-CXRS-CFG-RUN-01 records 4 runs (1 + 3 re-runs) and
  `_classify_codex_drop_reason` returns empty for the clap capture → the test
  fails. TC-CXRS-CFG-DROP-01 returns empty → fails.
- **After the fix**: TC-CXRS-CFG-RUN-01 records 1 run; the clap capture
  classifies `config-error:-s`. TC-CXRS-CFG-RUN-02 still records 2 runs for a
  genuine transient (no #209 regression).

## Out of scope (confirmed no change)

- `_codex_review_argv` is NOT changed to filter exec-only flags (the issue's
  optional second fix; rejected as too magical — see the design doc).
- `_classify_noverdict_agent` / `_aggregate_review_verdicts` — a `config-error`
  codex stays a dropped `unavailable`, never a deciding FAIL (observability only,
  exactly like `stream-error` / `auth-failed`).
- The codex **dev** path (`codex exec`) — untouched.
