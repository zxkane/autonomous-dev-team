# Pipeline Metrics — event log + baseline aggregator (INV-67)

The metrics lane is the stability redesign's **measurement substrate**. It writes
an append-only JSONL event log (`lib-metrics.sh`) and reads it back into the four
baseline numbers the stop-rule and checkpoints consume (`metrics-report.sh`).

It is **observe-only** — see [INV-67](invariants.md#inv-67-metrics-emission-is-observe-only--silent-to-pipeline-loud-to-report). A metrics
failure can never change a wrapper/dispatcher exit code, label transition,
verdict, or merge decision. Nothing in the pipeline control flow ever reads a
metrics value back.

## Storage

| | |
|---|---|
| **File** | `<metrics_dir>/metrics.jsonl` |
| **Format** | one JSON object per line (JSONL), append-only (`>>` / O_APPEND) |
| **Writer** | `lib-metrics.sh::metrics_emit` (one writer per wrapper run; no lock) |
| **`metrics_dir`** | `${AUTONOMOUS_METRICS_DIR}` → `${XDG_STATE_HOME}/autonomous-<project>` → `${HOME}/.local/state/autonomous-<project>`. The fallback resolves **directly** to `$HOME/.local/state` (the issue's `${XDG_STATE_HOME:-$HOME/.local/state}` contract) and deliberately does NOT defer to `pid_dir_for_project`, which prefers the volatile `${XDG_RUNTIME_DIR}` tmpfs — metrics need **durable** retention, PID files don't, so they resolve differently. |
| **Construction** | `jq -nc` only — never hand-rolled `echo` (values with quotes/newlines/`$()` stay valid JSON) |
| **Retention** | `metrics_prune [days]` (default 90) drops lines older than N days; built into `metrics-report.sh --prune-days` |

## Event envelope

Every line carries this common envelope plus event-specific fields:

```json
{ "schema_version": 1, "ts": "2026-06-13T12:00:00Z", "event": "<type>", "project": "<PROJECT_ID>", "issue": 228 }
```

- `schema_version` — currently `1`. Bumped only on an **incompatible** field change;
  additive fields do not bump it (the aggregator ignores unknown event types and
  unknown fields). This lets later redesign phases extend the schema freely.
- `ts` — ISO-8601 UTC, emit time.
- `issue` — integer when known; omitted otherwise. Numeric keys (`issue`, `pr`,
  `rc`, `duration_s`, `input_tokens`, `output_tokens`, `total_tokens`,
  `retry_count`) are emitted as JSON numbers; all other values are strings.

## Event types

| `event` | Producer (file) | Fields (beyond envelope) | Meaning |
|---|---|---|---|
| `wrapper_start` | dev + review wrappers | `side` (dev\|review), `mode` (dev only: new\|resume), `agent` | a wrapper began its run |
| `wrapper_end` | dev + review cleanup trap | `side`, `rc`, `duration_s`, `agent` | a wrapper finished (FINAL rc, post SIGTERM-rewrite); duration in seconds |
| `token_usage` | dev wrapper (cleanup) | `side`, `issue`, `agent`, `input_tokens`?, `output_tokens`?, `total_tokens`? | tokens the CLI reported (claude JSON `usage` / codex `tokens used`); absent fields omitted. Keyed by `issue` (the dev wrapper knows the issue, not the PR number) — `issue` is the join key for cost-per-merged-PR |
| `pr_opened` | dev wrapper (cleanup, PR present) | `side` | a PR exists for the issue — TTHW first-PR endpoint (earliest per issue wins) |
| `verdict` | review wrapper (post-aggregation) | `side`, `verdict` (pass\|fail\|all-unavailable), `pr` | the aggregated INV-40 review verdict |
| `review_agent_run` | review wrapper (per fan-out member) | `side`, `agent_name`, `state` (pass\|fail\|unavailable\|timed-out), `pr` | one fan-out member ran — the **per-CLI denominator** for quota-failure rate. Emitted for EVERY member, so multi-agent fan-out (`AGENT_REVIEW_AGENTS`) counts non-default CLIs that `wrapper_end side=review` (default `AGENT_CMD` only) would miss |
| `agent_drop` | review wrapper (per dropped member) | `side`, `agent_name`, `reason` (failure-class), `pr` | one fan-out agent dropped/timed-out, with its mapped failure class |
| `merge` | review wrapper (auto-merge) | `result` (success\|failure), `failure_class` (failure only: `infra`), `pr` | auto-merge outcome — TTHW merged endpoint on success |
| `issue_labeled` | dispatcher (Step 2 dev-new) | `labeled_at`? (ISO-8601, the real `autonomous`-label time from the GitHub timeline) | issue first picked up — TTHW "labeled" endpoint (first dispatch only). The event `ts` is the dispatch instant (can lag the label by ticks); the aggregator prefers `labeled_at` when present so queued wait is counted |
| `dispatch_stale` | dispatcher (Step 5b DEAD) | `kind` (in-progress\|reviewing), `failure_class` (`false-stall`) | dispatcher declared a wrapper DEAD after the near-success cross-check cleared |
| `dispatch_retry` | dispatcher (Step 4 mark_stalled) | `retry_count`, `stalled` (bool) | retry counter hit MAX_RETRIES → issue marked stalled |

## Failure-class taxonomy

One enum, aligned with the redesign's factory classification. The `reason` field
of `agent_drop` and the `failure_class` field of `merge` / `dispatch_stale` carry
one of these:

| Class | When |
|---|---|
| `verdict-absent` | review reached window-expiry with no parseable verdict (aggregator: an `all-unavailable` verdict) |
| `verdict-malformed` | a verdict comment was posted but did not classify (reserved; future emitters) |
| `agent-unavailable:quota` | a fan-out agent dropped on a quota wall (agy 429, etc.) |
| `agent-unavailable:auth` | a fan-out agent dropped on an auth/login failure (agy/kiro) |
| `agent-unavailable:config` | a fan-out agent dropped on a config/argv error (codex clap rc 2) |
| `agent-unavailable:transient` | a fan-out agent dropped on a transient cause (stream-error, timed-out, signal-free) |
| `false-stall` | dispatcher declared DEAD though the wrapper may have been progressing (INV-24 cross-check is the guard against this; a declaration that survives it is recorded here) |
| `label-race` | concurrent label mutation (reserved; future emitters) |
| `infra` | merge failure, transport/network/SSM failure, or a write failure surfaced at report time |

The mapping from each CLI's native drop token to the `agent-unavailable:*` class
is `lib-metrics.sh::metrics_map_drop_reason`: `quota-exhausted`→`:quota`,
`auth-failed`→`:auth`, `config-error`→`:config`, everything else
(`stream-error`, empty, `timed-out`)→`:transient`.

## Report — `metrics-report.sh`

```
metrics-report.sh [--since <YYYY-MM-DD>] [--project <id>] [--prune-days N] [--dir <path>] [--file <path>]
```

Input resolution: `--file` → `--dir`/metrics.jsonl → `--project` via `metrics_dir`
→ `$PROJECT_ID` via `metrics_dir`. Filters: `--since` (drops earlier events),
`--project` (matches the `project` field). `--prune-days` prunes the file before
aggregating (default: no prune — a read-only report never mutates data unless asked).

Prints four blocks (the redesign's baseline numbers):

1. **Incidents per month, by failure class** — every `agent_drop`, failed `merge`,
   `dispatch_stale`, and `all-unavailable` `verdict`, bucketed by calendar month
   (`ts[:7]`) × class, plus a total.
2. **Cost-per-merged-PR** — for each successfully-merged issue (one merged PR per
   issue via `Closes #N`), the sum of its `token_usage.total_tokens`, **joined on
   `issue`** (the only key both `merge` and `token_usage` carry — the dev wrapper
   that emits token_usage knows the issue, not the PR number). Reported as avg /
   p50 / p90 over issues **with** numeric token data. Issues without token data are
   **excluded** (never counted as 0) and the "merged PRs: N; with token data: M"
   line surfaces the gap.
3. **Quota-failure rate per CLI** — `agent_drop(agent-unavailable:quota)` count ÷
   **`review_agent_run` runs per `agent_name`** (NOT `wrapper_end side=review`,
   which carries only the wrapper's default `AGENT_CMD` and so under-counts
   non-default fan-out CLIs). Falls back to `wrapper_end side=review` only for
   pre-`review_agent_run` logs. A CLI with zero runs prints `n/a` (no division by
   zero).
4. **TTHW** — labeled→first-PR and labeled→merged, avg / p50 / p90 (nearest-rank
   percentile). Derived per issue from `issue_labeled` (earliest, using
   `labeled_at` when present else `ts`), `pr_opened` (earliest), `merge`(success)
   (earliest). An issue missing an endpoint (PR never opened / never merged) is
   excluded from the affected statistic only.

The report is the **loud** half of INV-67: gaps are `n/a` / explicit counts, never
a silent zero — so a broken emitter shows up at report time.

## Extending the schema

Add a new event type or field, bump `METRICS_SCHEMA_VERSION` only if the change is
incompatible, and teach `metrics-report.sh` to consume it. The aggregator already
ignores event types it doesn't recognize, so a new emitter is backward-safe: old
reports skip the new events; new reports read them.
