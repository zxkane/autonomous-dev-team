# Test Cases — Baseline Metrics Collector (issue #228)

ID format: `TC-METRICS-NNN`. Covers `lib-metrics.sh` (emitter + prune) and
`metrics-report.sh` (aggregator). All shell, run under `bash`, no network.

## `lib-metrics.sh` — `metrics_emit`

| ID | Scenario | Expected |
|---|---|---|
| TC-METRICS-001 | `metrics_emit wrapper_start side=dev mode=new` writes one line | file has exactly 1 line; `jq .` parses it; `event=="wrapper_start"`, `side=="dev"`, `schema_version==1`, `ts` matches ISO-8601 |
| TC-METRICS-002 | Value containing double-quotes (`reason='he said "no"'`) | line is valid JSON; round-trips the literal value via `jq -r` |
| TC-METRICS-003 | Value containing a newline | single physical JSON line (newline escaped as `\n`); `jq .` parses; one line in file |
| TC-METRICS-004 | Value containing `$()` / backticks / `;` | stored literally, no shell expansion, valid JSON |
| TC-METRICS-005 | Two sequential emits | file has 2 lines, both valid JSON, append order preserved |
| TC-METRICS-006 | `issue=228` numeric key | emitted as JSON number `228`, not string |
| TC-METRICS-007 | Unwritable metrics dir (chmod 000 / read-only) | `metrics_emit` returns 0, prints nothing to stdout, surrounding `rc` after `metrics_emit … || true` unchanged |
| TC-METRICS-008 | `PROJECT_ID` unset | `metrics_emit` returns 0 (best-effort), does not crash caller |
| TC-METRICS-009 | `AUTONOMOUS_METRICS_DIR` override | writes to that exact dir (test isolation hook works) |
| TC-METRICS-010 | `XDG_STATE_HOME` set, no override | resolves to `${XDG_STATE_HOME}/autonomous-<project>/metrics.jsonl` |

## `lib-metrics.sh` — `metrics_prune`

| ID | Scenario | Expected |
|---|---|---|
| TC-METRICS-020 | File with lines aged 100d, 50d, 1d; prune 90 | only the 100d line removed; 50d + 1d retained; remaining lines still valid JSON |
| TC-METRICS-021 | All lines recent | prune removes nothing; file byte-identical content |
| TC-METRICS-022 | Empty / missing file | prune returns 0, no error |
| TC-METRICS-023 | Line with malformed JSON | prune does not crash; malformed line dropped (cannot date it) without aborting |

## `metrics-report.sh` — aggregation math (fixture-driven)

| ID | Scenario | Expected |
|---|---|---|
| TC-METRICS-040 | Fixture with known per-class incident counts | incidents/month table matches hand-counted values per class |
| TC-METRICS-041 | Incidents spanning a month boundary (Jan 31 + Feb 1) | bucketed into 2 distinct months, not merged |
| TC-METRICS-042 | `token_usage` for 3 merged PRs (1000/2000/3000) | cost-per-merged-PR avg=2000, p50=2000, p90=3000 |
| TC-METRICS-043 | A merged PR with NO token data | excluded from cost stats (denominator = PRs-with-tokens, never counted as 0) |
| TC-METRICS-044 | Per-CLI quota rate: claude 2 quota drops / 10 runs | prints `claude 20%` (0.20) |
| TC-METRICS-045 | Per-CLI quota rate: a CLI with 0 runs | prints `n/a` (no div-by-zero, no crash) |
| TC-METRICS-046 | TTHW labeled→first-PR and labeled→merged on fixture | avg/p50/p90 match hand-computed seconds→duration |
| TC-METRICS-047 | TTHW with a PR never opened (missing endpoint) | that issue excluded from labeled→first-PR stat; others unaffected |
| TC-METRICS-048 | TTHW with a PR opened but never merged | excluded from labeled→merged; included in labeled→first-PR |
| TC-METRICS-049 | `--since` filter | events before the cutoff excluded from every block |
| TC-METRICS-050 | `--project` filter with two projects' files present | only the named project's events counted |
| TC-METRICS-051 | Empty metrics.jsonl | report prints all four blocks with `n/a` / zero, exit 0, no crash |

## Post-review regression (#228 findings 1-4)

| ID | Scenario | Expected |
|---|---|---|
| TC-METRICS-070 | `metrics_parse_tokens` output key names | emits `input_tokens=`/`output_tokens=`/`total_tokens=` (the schema keys), NOT bare `input=`/`output=`/`total=` — finding 1 |
| TC-METRICS-071 | Integration: parser → `metrics_emit token_usage` → `metrics-report.sh` | the spliced `$_tok` produces a `token_usage` with numeric `total_tokens`; the report costs the merged issue ("with token data: 1"), not `n/a` — finding 1 end-to-end |
| TC-METRICS-011 | `metrics_dir` durable fallback: `XDG_STATE_HOME` unset, `XDG_RUNTIME_DIR` set | resolves to `$HOME/.local/state/autonomous-<project>` (durable), never the volatile `XDG_RUNTIME_DIR` — finding 2 |
| TC-METRICS-053 | Per-CLI quota denominator from `review_agent_run` | multi-agent fan-out: codex denominator counts its `review_agent_run` events (not the claude-only `wrapper_end`); rate correct — finding 3 |
| TC-METRICS-054 | TTHW prefers `labeled_at` over `ts` | labeled→first-PR measured from the real label time (`labeled_at`) not the dispatch instant; falls back to `ts` when `labeled_at` absent — finding 4 |

## Regression — observe-only (INV-67)

| ID | Scenario | Expected |
|---|---|---|
| TC-METRICS-060 | Source `lib-metrics.sh` in a `set -e` context, emit to an unwritable dir | the enclosing script continues; its final rc is the value it would have had without the metrics call |
| TC-METRICS-061 | `jq` absent on PATH (simulated) | `metrics_emit` returns 0, writes nothing, no crash |
| TC-METRICS-062 | Grep-assert every wrapper call site is `metrics_emit … || true` | dev + review wrappers never call `metrics_emit` un-guarded |

## E2E — fixture three-month synthesis

| ID | Scenario | Expected |
|---|---|---|
| TC-METRICS-080 | Synthesize 3 months of events (deterministic fixture), run `metrics-report.sh` | the four headline numbers (total incidents, cost-per-merged-PR p50, top quota CLI rate, labeled→merged p50) match the fixture's pre-computed expected values exactly |
