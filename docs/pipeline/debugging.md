# Debugging runbook — the 2am path ([INV-80](invariants.md#inv-80-every-wrapper-run-mints-a-run-id-and-a-durable-per-run-artifact-dir-the-run-id-threads-through-logs-metrics-and-every-wrapper-posted-comment-footer-statussh-answers-pipeline-state-from-the-dispatchers-real-predicates-observe-only--never-changes-wrapper-rc-or-labels))

> You got paged: issue #N is stuck, or a PR has a FAIL comment and you don't know
> why. This is the one-page path from a GitHub comment to the raw evidence, and
> from "stuck" to "what the dispatcher will do next" — without SSH, without
> grepping three evaporating `/tmp` logs.

## TL;DR

1. **Read the comment footer.** Every wrapper-posted verdict / drop / crash /
   session-report comment ends with:

   ```
   ---
   run-id: <project>-<issue>-<dev|review>-<ts> · artifacts: <abs dir>
   ```

2. **Open the artifacts dir.** It survives a reboot (it's under the XDG **state**
   root, not `/tmp`). It contains `meta.json`, `run.log`, and (review side)
   `drops.jsonl`.

3. **Run `status.sh <issue>`** for the live pipeline picture + the next
   dispatcher action — computed from the dispatcher's own predicates.

That's it. The rest of this doc is the detail.

---

## 1. Comment → run-id → directory

Every **terminal/diagnostic** comment a wrapper posts carries an [INV-80](invariants.md#inv-80-every-wrapper-run-mints-a-run-id-and-a-durable-per-run-artifact-dir-the-run-id-threads-through-logs-metrics-and-every-wrapper-posted-comment-footer-statussh-answers-pipeline-state-from-the-dispatchers-real-predicates-observe-only--never-changes-wrapper-rc-or-labels)
footer. The footer's `artifacts:` path is absolute — copy it and `ls` it:

```bash
ls -la /home/<user>/.local/state/autonomous-<project>/runs/<run-id>/
# meta.json   run.log   drops.jsonl (review side)
```

The run-id encodes everything you need to find it by hand if the footer is
missing (older comment, footer suppressed by a lib failure):

```
<project>-<issue>-<dev|review>-<YYYYMMDDThhmmssZ>
└ myproject-200-dev-20260618T145108Z
```

## 2. What's in the run directory

| File | What it tells you |
|------|-------------------|
| `meta.json` | The run's identity + outcome: `run_id`, `side`, `issue`, `started_at`, `ended_at`, `rc`, `duration_s`, `log_pointer` (the legacy `/tmp` log), `host_env` (agent, mode, gh_auth_mode, execution_backend, host — **redacted**, no secrets). |
| `run.log` | A durable copy of THIS run's wrapper stdout/stderr. First line points back to the run-dir + the `/tmp` log. Unlike `/tmp/agent-*.log` it survives a reboot. |
| `drops.jsonl` | (review) one line per dropped/unavailable fan-out agent: `{agent, reason, ts}`. `reason` uses the [failure-class taxonomy](metrics.md) (`agent-unavailable:quota`, `agent-unavailable:auth`, …). |

```bash
RUN=/home/<user>/.local/state/autonomous-<project>/runs/<run-id>
jq . "$RUN/meta.json"            # outcome at a glance: rc + timing
tail -50 "$RUN/run.log"          # the run's own log, durable
jq . "$RUN/drops.jsonl"          # why a review agent dropped (review side)
```

### Why not just the `/tmp` log?

`/tmp/agent-<project>-issue-<N>.log` (and its single `.log.1` rotation,
[INV-69](invariants.md#inv-69-on-re-dispatch-the-prior-runs-agent-log-is-rotated-to-a-single-1-generation-not-truncated))
still works and still gets the live tail — operator muscle memory is preserved.
But `/tmp` is tmpfs on the SSM execution box: **a reboot wipes it**, and an
append-mode log has no correlation key back to the comment that referenced it.
`run.log` is the same content under the durable state root, keyed by run-id.

## 3. `status.sh` — "why is issue N stuck, what's next?"

```bash
cd <project>            # so scripts/autonomous.conf is found
bash scripts/status.sh <issue>
# or, from anywhere, name the project:
bash scripts/status.sh <issue> --project <project-id>
```

It prints (all **read-only** — no labels touched, no comments, no merges):

```
labels:        autonomous in-progress no-auto-close
open PR:       #777  reviewDecision=APPROVED  mergeable=MERGEABLE
lease (dev):   pid=12345    alive=yes
lease (review):pid=<none>   alive=no
retry count:   1 / 3   (count_retries, the Step-4 stall gate input)

── last run-ids (newest first) ──
  <project>-N-review-...  —  rc=0 (success)
  <project>-N-dev-...     —  rc=1 (failure)

── last drop reasons (latest review run) ──
  codex: agent-unavailable:quota  (2026-...)

── next dispatcher tick ──
  Step 5a: leave alone — dev lease ALIVE, no PR yet.
```

**The "next dispatcher tick" line is computed from the dispatcher's REAL predicate
functions** (`pid_alive`, `count_retries`, `fetch_pr_for_issue`,
`dev_near_success`/`review_near_success` — all sourced from `lib-dispatch.sh`), so
it can never drift from what the tick actually does ([INV-80](invariants.md#inv-80-every-wrapper-run-mints-a-run-id-and-a-durable-per-run-artifact-dir-the-run-id-threads-through-logs-metrics-and-every-wrapper-posted-comment-footer-statussh-answers-pipeline-state-from-the-dispatchers-real-predicates-observe-only--never-changes-wrapper-rc-or-labels)
predicate-parity rule).

### The four canonical "stuck" states

| `status.sh` shows | Means | Next tick |
|-------------------|-------|-----------|
| `in-progress`, lease `alive=no`, no near-success | dev wrapper crashed | Step 5b declares the crash → `pending-dev` (retry M/MAX) |
| `in-progress`, lease `alive=yes` | wrapper is working | Step 5a leaves it alone (or SIGTERMs to `pending-review` once PR ready + CI green + idle >300s) |
| `pending-dev`, retry `≥ MAX_RETRIES` | retry budget spent | Step 4 marks `stalled` — operator must intervene |
| `approved` + `no-auto-close` | review passed, merge gated | none — operator merges manually |

## 4. Cross-host note

The dispatcher (Tokyo) and the wrapper-execution box (Singapore) are different
hosts under `EXECUTION_BACKEND=remote-aws-ssm`. `status.sh` reads the run dirs +
PID files on **the box it runs on**. Run it on the execution box (where the run
dirs live) for the artifact/lease lines; the labels + PR lines are GitHub-global
and correct from anywhere. Cross-host aggregation is deliberately out of scope
(SSM topology reads stay manual — see the issue's Out of Scope).

## 5. Correlating in the metrics log

Every `metrics_emit` event ([INV-70](invariants.md#inv-70-metrics-are-observe-only-emit-failures-never-change-wrapper-behavior))
now carries `run_id`, so you can pivot from a run dir to its metrics events:

```bash
jq -c 'select(.run_id == "<run-id>")' \
  /home/<user>/.local/state/autonomous-<project>/metrics.jsonl
```

## See also

- [INV-80](invariants.md#inv-80-every-wrapper-run-mints-a-run-id-and-a-durable-per-run-artifact-dir-the-run-id-threads-through-logs-metrics-and-every-wrapper-posted-comment-footer-statussh-answers-pipeline-state-from-the-dispatchers-real-predicates-observe-only--never-changes-wrapper-rc-or-labels) — the run-id / artifact-dir / status.sh invariant.
- [`metrics.md`](metrics.md) — the metrics event schema (now with `run_id`) + failure-class taxonomy.
- [`dispatcher-flow.md`](dispatcher-flow.md) — the full 5-step tick `status.sh` mirrors for one issue.
- [`errors.md`](errors.md) — the operator error-envelope classes a comment may carry.
