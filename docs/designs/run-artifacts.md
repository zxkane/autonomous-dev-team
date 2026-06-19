# Design — Per-run artifact directory + run-id threading + `status.sh` inspector (#235)

> Funded scope T2 (debuggability). Goal: turn the 2am "spelunk three evaporating
> `/tmp/agent-*.log` files" story into "read the FAIL comment → follow its
> `run-id` footer → open one durable directory → run `status.sh <issue>`".

## Problem

Today a wrapper run leaves:

- An append-mode `/tmp/agent-<project>-issue-<N>.log` (single `.log.1` rotation, INV-69)
  that **evaporates on reboot** (`/tmp` is tmpfs on the SSM box).
- A GitHub comment (verdict / drop-reason / session report) with **no correlation
  key** back to the run that produced it.
- No one-command way to answer "why is issue N stuck, and what will the next
  dispatcher tick do?" — the operator hand-reconstructs it from labels + `ps` +
  PID files + reading dispatcher source.

## Solution overview

Three coordinated pieces, all additive (no wrapper *behavior* change beyond
logging/teeing — AC3):

1. **`lib-run-artifacts.sh`** — a new, self-contained lib (jq + coreutils only)
   that mints a run-id, provisions a durable per-run directory, renders the
   comment footer, and prunes old run dirs. Observe-only: every function is
   best-effort and **never** changes the wrapper's rc or label transitions
   (same contract as `lib-metrics.sh`, INV-70).
2. **Wrapper threading** — `autonomous-dev.sh` + `autonomous-review.sh` mint
   `RUN_ID` at start, init the run dir, tee their log into it, embed the footer
   in every posted comment, and pass `run_id=` into every `metrics_emit`.
3. **`scripts/status.sh <issue> [--project <id>]`** — an operator inspector that
   **sources the real dispatcher predicate functions** (`lib-dispatch.sh`) so its
   answer can never drift from dispatcher behavior.

## Run-id scheme

```
<project>-<issue>-<dev|review>-<ts>
```

- `<project>` = `PROJECT_ID`
- `<issue>`   = the `--issue N` arg
- `<side>`    = `dev` | `review`
- `<ts>`      = `date -u +%Y%m%dT%H%M%SZ` (UTC, second resolution)

Example: `myproject-200-dev-20260618T145108Z`.

`mint_run_id <side> <issue>` echoes it; the wrapper exports it as `RUN_ID` so
sourced libs/adapters inherit it. A `RUN_ID` already present in the environment
is honored (lets the dispatcher or a test pin a deterministic value).

### Uniqueness under concurrent issues

Two concurrent issues never collide (`<issue>` differs). Two dev+review sides of
the same issue never collide (`<side>` differs). The only collision window is the
**same side of the same issue dispatched twice within one UTC second** — vanishingly
rare for wrapper spawns (the dispatcher serializes dev-new/dev-resume per issue,
and a re-dispatch is minutes apart). To make it *impossible* anyway,
`run_artifacts_init` appends a short disambiguator (`-2`, `-3`, …) when the target
dir already exists, so the directory is always unique even if `mint_run_id`
returned a duplicate string. The exported `RUN_ID` is updated to the disambiguated
value.

## Coordination with #233 (verdict artifacts) — NO duplication

#233 already writes `…/autonomous-<project>/runs/<review-session-uuid>/verdict-<agent>.json`,
where `<review-session-uuid>` is the per-agent minted **Review Session UUID**
(INV-20) — one dir *per agent run*, not per wrapper run.

This feature uses the **same `runs/` parent** but a **wrapper-scoped run-id**:

```
${XDG_STATE_HOME:-$HOME/.local/state}/autonomous-<project>/runs/
├── <project>-<issue>-dev-<ts>/           ← THIS feature (wrapper run dir)
│   ├── meta.json                          start/end markers, rc, timing, env summary
│   ├── run.log                            tee of THIS run's wrapper stdout
│   └── drops.jsonl                        drop-reason classifications (review side)
├── <project>-<issue>-review-<ts>/         ← THIS feature
│   └── …
└── 01c9c077-febc-…/                       ← #233 per-AGENT verdict UUID dir (sibling)
    └── verdict-codex.json
```

The two namespaces are **structurally distinguishable**: wrapper run-ids always
match `<project>-<issue>-(dev|review)-<ts>`; #233 UUIDs are bare RFC-4122 UUIDs.
`status.sh` and the prune both key on the wrapper-run-id glob
(`*-${issue}-dev-*` / `*-${issue}-review-*`), so they never touch #233's
per-agent dirs. We do **not** re-implement #233's verdict path — `status.sh`
*reads* #233 verdict artifacts where present but the layout owner stays #233.

> If a future change wants the per-agent verdict dirs nested *inside* the wrapper
> run dir, that is a #233 follow-up; this PR keeps them as siblings to avoid
> touching the read-once/first-land-freeze machinery.

## Per-run directory contents

`run_artifacts_init <side> <issue>` (called once at wrapper start):

| File | Written by | Contents |
|------|------------|----------|
| `meta.json` | init + finalize | `{run_id, project, issue, side, mode, agent, started_at, ended_at, rc, duration_s, log_pointer, host_env}` — start fields at init, end fields at finalize |
| `run.log` | tee | THIS run's wrapper stdout/stderr (the run-scoped copy of `/tmp/agent-*.log`) |
| `drops.jsonl` | review wrapper (best-effort) | one JSON line per dropped/unavailable agent: `{agent, reason, ts}` |

`host_env` is a **redacted** summary — `agent`, `mode`, `GH_AUTH_MODE`,
`EXECUTION_BACKEND`, hostname — never tokens/PEM/secrets.

`run_artifacts_finalize <run_dir> <rc>` (called from the cleanup trap) rewrites
`meta.json` with `ended_at`, `rc`, `duration_s`.

## Log teeing + `/tmp` pointer (operator muscle memory preserved)

- `/tmp/agent-*.log` keeps working exactly as today (append-mode, INV-69 rotation).
- The wrapper writes a **first-line pointer** into the run dir's `run.log`
  (`run-dir: <abs path>` + `tmp-log: <abs path>`) and, best-effort, prepends a
  one-line pointer comment to the `/tmp` log so an operator who opens the `/tmp`
  log is told where the durable copy is. The `/tmp` log is reused across
  retries/resumes, so each init **strips the prior breadcrumb and prepends the
  current run's** — the active run always owns the top-of-file pointer (#235 r18).
  The rewrite is in place (`cat >`, not `mv`) so the `/tmp` log inode survives and
  dispatch-local.sh's open append fd is not orphaned; init runs before any agent
  output so there is no concurrent writer to tear.
- New wrapper stdout **tees** into `run.log` (the existing `/tmp` redirect in
  `dispatch-local.sh` is unchanged; the tee is added wrapper-side so a direct
  `bash autonomous-dev.sh` invocation also gets a run.log).

## Comment footer

Every wrapper-posted comment (session report, startup-failure, no-PR retry,
review verdict, drop-reason, error envelope) gains a trailing footer:

```
---
run-id: <project>-<issue>-dev-<ts> · artifacts: <abs run dir>
```

Rendered by `run_footer` (a pure string function — testable in isolation). When
`RUN_ID`/run dir are unset (lib failed to init), `run_footer` echoes nothing so a
comment is never broken by a footer failure (observe-only).

## Retention / prune

`run_prune [days] [issue]` — drop run dirs whose `meta.json.started_at` (or dir
mtime fallback) is older than N days (default 30, `RUN_RETENTION_DAYS`). Built
into `run_artifacts_init` (best-effort, once per wrapper start, like
`metrics_prune`). **Never prunes the active run dir** (the one just minted) — the
active run-id is excluded by exact name match before the age sweep.

## `status.sh <issue> [--project <id>]`

Sources `lib-config.sh` (`load_autonomous_conf`) then `lib-dispatch.sh`, then
calls the **real predicate functions** — no reimplementation:

| Line | Source of truth |
|------|-----------------|
| Labels | `gh issue view --json labels` |
| Open PR + reviewDecision | `fetch_pr_for_issue` (lib-dispatch) + `gh pr view` |
| Lease/PID liveness | `get_pid` + `pid_alive` (lib-dispatch) |
| Retry count | `count_retries` (lib-dispatch) |
| Last 3 run-ids + outcomes | scan `runs/*-<issue>-*/meta.json` (this feature) |
| Last drop reasons | scan `runs/*-<issue>-review-*/drops.jsonl` |
| Next dispatcher action | derived from the SAME predicates the tick uses (labels + `pid_alive` + `dev_near_success`/`review_near_success` + `count_retries` vs `MAX_RETRIES`) |

**Predicate parity is grep-asserted** (test): `status.sh` must `source`
`lib-dispatch.sh` and call `pid_alive`/`count_retries`/`fetch_pr_for_issue`
rather than duplicate their logic. Drift here would be a *new* false-signal
source — worse than no tool (issue Design Considerations).

### Four canonical states `status.sh` must answer

1. **idle** — no in-progress/reviewing label, no live PID → "next tick: dev-new if pending-dev".
2. **in-progress with live lease** — `pid_alive` true → "next tick: leave alone (wrapper alive)".
3. **stalled with dead PID** — label in-progress, `pid_alive` false, no near-success → "next tick: Step 5b crash declaration → pending-dev (retry M/MAX)".
4. **approved-awaiting-merge** — PR approved + `no-auto-close` → "next tick: none; operator merges manually".

## Observe-only / safety invariants (INV-81)

- All `lib-run-artifacts.sh` functions are best-effort; a failure (unwritable
  dir, missing jq) is a silent no-op and **never** changes wrapper rc or labels.
- Footer rendering degrades to empty on any missing input — a comment is never
  lost to a footer bug.
- Prune never deletes the active run dir, and never touches #233 per-agent UUID dirs.
- `status.sh` is **read-only** — it issues no label edits, no comments, no merges.

## Testing strategy

- Unit: `tests/unit/test-lib-run-artifacts.sh` (TC-RUN-ARTIFACTS-001..) — minting,
  uniqueness/disambiguation, init/finalize meta.json, footer rendering, prune
  age-boundary + never-active.
- Unit: `tests/unit/test-status.sh` (TC-RUN-ARTIFACTS-040..) — four canonical
  states against a stub `gh` + stub PID dir; predicate-parity grep-assert.
- E2E: `tests/e2e/run-run-artifacts-e2e.sh` — stub dev+review cycle populates run
  dirs; `status.sh` output snapshot-asserted; reboot simulation (`/tmp` cleared)
  → artifacts still present under the XDG state root.
