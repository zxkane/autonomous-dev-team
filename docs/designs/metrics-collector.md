# Design Canvas — Baseline Metrics Collector (issue #228)

## Goal

Add an **observe-only** metrics lane to the autonomous pipeline so the stability
redesign's stop-rule, obsolescence checkpoint, and per-CLI value-accounting read
from measured numbers instead of anecdotes.

Two new files (both source from the skill tree via `LIB_DIR`, INV-65 — no
per-project symlink wave needed):

| File | Kind | Role |
|---|---|---|
| `skills/autonomous-dispatcher/scripts/lib-metrics.sh` | sourced lib | `metrics_emit`, `metrics_dir`, `metrics_prune` — append-only JSONL writer + retention |
| `skills/autonomous-dispatcher/scripts/metrics-report.sh` | executable | aggregator: incidents/month, cost-per-merged-PR, quota-failure rate, TTHW |

## Non-goals (Out of Scope per the issue)

- No dashboards / visualization / alerting.
- **Zero** dispatch/verdict behavior change. Emission is best-effort (`|| true`)
  and a metrics write failure MUST never affect wrapper exit code or labels.

## Storage

`metrics.jsonl` lives in the **same per-project state dir** as the PID/heartbeat
files, so an operator finds everything for a project in one place. Path
resolution (in `metrics_dir`):

1. `${AUTONOMOUS_METRICS_DIR}` — test/override hook (mirrors `AUTONOMOUS_PID_DIR`).
2. `${XDG_STATE_HOME}/autonomous-${PROJECT_ID}` — honors the issue's stated
   `XDG_STATE_HOME` convention when set.
3. `${HOME}/.local/state/autonomous-${PROJECT_ID}` — the **durable** fallback
   (the issue's `${XDG_STATE_HOME:-$HOME/.local/state}` contract). It resolves
   directly, NOT via `pid_dir_for_project`: that helper prefers the volatile
   `${XDG_RUNTIME_DIR}` tmpfs (wiped on logout/reboot), which would silently lose
   the retention/reporting log on the production SSM box where `XDG_RUNTIME_DIR`
   is set (#228 review finding 2). Metrics need durability; PID files don't.

File: `${metrics_dir}/metrics.jsonl`. Append-only, one JSON object per line.
O_APPEND (`>>`) gives atomic line appends for the small records we write; no lock
needed (one writer per wrapper run).

## Event schema

Every line is a flat JSON object built **exclusively** with `jq -nc` (never
hand-rolled `echo`), so values containing quotes / newlines / `$()` are safe.

Common envelope (every event):

```json
{
  "schema_version": 1,
  "ts": "2026-06-12T15:30:00Z",   // ISO-8601 UTC, emit time
  "event": "<event-type>",         // see table
  "project": "<PROJECT_ID>",
  "issue": 228                      // integer when known, omitted otherwise
}
```

`schema_version` lets later redesign phases extend the schema without breaking
this aggregator (the aggregator ignores unknown event types and unknown fields).

### Event types

| event | emitted by | extra fields |
|---|---|---|
| `wrapper_start` | dev + review wrappers, at first stable point | `side` (dev\|review), `mode` (new\|resume), `agent` (CLI) |
| `wrapper_end` | dev + review cleanup trap | `side`, `rc`, `duration_s`, `agent` |
| `verdict` | review wrapper, after aggregation | `verdict` (pass\|fail\|all-unavailable), `pr` |
| `agent_drop` | review wrapper, per dropped/unavailable agent | `agent_name`, `reason` (failure-class), `pr` |
| `token_usage` | dev wrapper (+ review where available) | `agent`, `input_tokens`, `output_tokens`, `total_tokens` (omit absent fields) |
| `dispatch_stale` | dispatcher, on stale/DEAD declaration | `kind` (in-progress\|reviewing), `failure_class` (false-stall\|infra), `retry_count` |
| `dispatch_retry` | dispatcher, on retry increment / mark_stalled | `retry_count`, `stalled` (bool) |
| `merge` | review wrapper auto-merge path | `pr`, `result` (success\|failure), `failure_class` (infra when failed) |

TTHW is computed by the aggregator from GitHub timestamps (issue `labeled`
event → first PR `createdAt` → PR `mergedAt`), NOT from emitted events — the
events give us per-run incident/cost/quota data, and TTHW is a cross-cut the
report derives by reading the events' `issue` numbers and correlating with
`gh` (best-effort; degrades to "events only" when `gh` unavailable).

## Failure-class taxonomy (one enum, documented in metrics.md)

Aligned with the redesign's factory classification:

```
verdict-absent        — review reached window-expiry with no parseable verdict
verdict-malformed     — a verdict comment was posted but didn't classify
agent-unavailable     — a fan-out agent dropped; sub-reason in :quota|:auth|:config|:transient
false-stall           — dispatcher declared DEAD but a near-success signal existed (INV-24)
label-race            — concurrent label mutation (two ticks raced)
infra                 — merge failure, gh/network/SSM transport, write failure surfaced to report
```

The `agent_drop.reason` field carries one of these (with the `agent-unavailable`
sub-reason mapped from the existing per-CLI drop tokens: agy `quota-exhausted`
→ `agent-unavailable:quota`, `auth-failed` → `agent-unavailable:auth`, codex
`config-error` → `agent-unavailable:config`, generic `unavailable`/`timed-out`
→ `agent-unavailable:transient`).

## Aggregator (`metrics-report.sh`)

```
metrics-report.sh [--since <YYYY-MM-DD>] [--project <id>] [--prune-days N] [--dir <path>]
```

Reads every `metrics.jsonl` for the selected project(s), filters by `--since`,
and prints four headline blocks:

1. **Incidents/month by class** — count of `agent_drop` + `merge`(failure) +
   `dispatch_stale` + `verdict`(all-unavailable) events bucketed by calendar
   month (`ts[:7]`) and failure class.
2. **Cost-per-merged-PR** — sum `token_usage.total_tokens` between a
   `wrapper_start` and the merged `verdict`/`merge` for each merged PR; report
   avg / p50 / p90 over PRs that have token data (absent → excluded, never 0).
3. **Quota-failure rate per CLI** — `agent_drop`(agent-unavailable:quota) count
   ÷ total `wrapper_end`(review) runs for that CLI; zero-run CLI → "n/a" (no
   div-by-zero).
4. **TTHW** — labeled→first-PR and labeled→merged, avg / p50 / p90; missing
   endpoint (PR never opened / never merged) → excluded from that statistic.

Math is pure shell + `jq` + `awk` percentile (no float div-by-zero: guarded).

`--prune-days` (default 90) drops lines older than N days from each
`metrics.jsonl` in place (atomic temp-file rewrite). Retention is built into the
collector per the issue.

## INV-70 (new)

**Metrics emission is observe-only: silent-to-pipeline, loud-to-report.** A
`metrics_emit` failure (unwritable dir, jq missing, disk full) MUST NOT change
any wrapper/dispatcher exit code, label transition, or verdict. Every call site
is `metrics_emit … || true` and `metrics_emit` itself swallows all internal
errors and returns 0. The aggregator, by contrast, surfaces gaps loudly (prints
`n/a`, counts of missing data) so a broken emitter is visible at report time.

## Test strategy (TDD — TC-METRICS-NNN)

- Unit: `metrics_emit` JSON validity incl. embedded quotes/newlines; unwritable
  dir → rc 0 and no throw; prune keeps recent / drops old; aggregator math on a
  fixture (known counts → known rates); month-boundary bucketing; TTHW with
  missing endpoints; per-CLI quota rate with a zero-run CLI.
- Regression: a wrapper-style harness that sources `lib-metrics.sh`, points the
  metrics dir at a read-only path, and asserts the surrounding rc is unchanged.
- E2E: synthesize 3 months of events into a fixture `metrics.jsonl`, run
  `metrics-report.sh`, assert the four headline numbers exactly.

## Instrumentation points (verified file:line on origin/main @ 7df8dcc)

| Point | File:line | Anchor |
|---|---|---|
| dev start | `autonomous-dev.sh` ~123 | after `LOG_FILE=`, capture `METRICS_START_TS` |
| dev end | `autonomous-dev.sh:401` `cleanup()` | emit `wrapper_end` with `exit_code` + duration; token parse from `$LOG_FILE` |
| dev agent rc | `autonomous-dev.sh:602/746/832` | `AGENT_EXIT` |
| review start | `autonomous-review.sh:605` `WRAPPER_START_TS` | reuse as start ts |
| review end | `autonomous-review.sh:448` `cleanup()` | emit `wrapper_end` |
| verdict | `autonomous-review.sh:1902` `AGGREGATE=` | emit `verdict` + per-agent `agent_drop` |
| merge | `autonomous-review.sh:2319` `MERGE_RC=` | emit `merge` success/failure |
| dispatch stale/retry | `dispatcher-tick.sh:259/262`, `lib-dispatch.sh:456 mark_stalled` | emit `dispatch_stale` / `dispatch_retry` |
```

