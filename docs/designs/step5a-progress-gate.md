# Design Canvas — Step 5a progress-gated SIGTERM (consumer half)

**Branch**: `feat/issue-485-progress-gated-sigterm`
**Closes**: #485
**Depends on**: #493 (merged, INV-135 — the agent-progress lease sidecars)
**Pipeline-docs touched**: `docs/pipeline/invariants.md` (new INV-136), `docs/pipeline/dispatcher-flow.md` (Step 5a rewrite), `docs/pipeline/remote-backend.md` (new snapshot + compare-and-signal contract), `autonomous.conf.example` (document the 1800s constant as non-configurable here).

---

## Why

`dispatcher-tick.sh` Step 5a currently gates SIGTERM on `now - PR.updatedAt > 300s` alone. That clock does not move while the agent edits/tests/builds locally between pushes. #493 landed a producer-only signal (`issue-<N>.progress.json` / `issue-<N>.run-id`, refreshed on launch and per complete output record) that nothing reads yet. This issue wires that signal into Step 5a's decision so a live, actively-working agent is never killed merely because its PR is old.

## Decision rule (replaces the current one)

```
SHOULD_SIGTERM =
  dev PID is ALIVE
  AND an open PR exists
  AND CI is green and non-empty
  AND pr_idle_age > 300s                  (INV-10, unchanged, strict)
  AND initial snapshot state == STALE      (current run/PID, per #493's lease)
  AND final pre-kill recheck passes        (below)
```

`FRESH` and `UNKNOWN` both mean `SHOULD_SIGTERM = false`. `JUST_DISPATCHED` / cold-start grace run before this, unchanged.

## New pure helper: `dev_progress_snapshot <issue>` (`lib-dispatch.sh`)

Echoes ONE compact JSON object, never throws:

- `{"state":"FRESH","age":N,"pid":N,"run_id":"..."}`
- `{"state":"STALE","age":N,"pid":N,"run_id":"..."}`
- `{"state":"UNKNOWN","reason":"<token>"}` (`reason` matches `[a-z0-9-]+`, diagnostic only)

Threshold is a shell constant, `DEV_PROGRESS_STALE_SECONDS=1800`, not a conf knob (matches the issue spec). `age <= 1800` → FRESH (boundary fresh); `age > 1800` → STALE (strict).

**Local backend**: read `issue-<N>.progress.json` + `issue-<N>.run-id` directly under `pid_dir_for_project()`. Validate: both regular files (no symlink), progress.json mode exactly 0600, well-formed JSON matching schema (`schema_version==1`, numeric non-negative `pid`, numeric `updated_at_epoch` not in the future), lease `pid` equals current `issue-<N>.pid` content, lease `run_id` equals current `issue-<N>.run-id` content. Any violation → UNKNOWN with a distinct reason token. Age = `now - updated_at_epoch` computed on the LOCAL clock (dispatcher and wrapper are the same box under local backend).

**Remote backend (`remote-aws-ssm`)**: a new synchronous transport, `agent-progress-snapshot-remote-aws-ssm.sh`, mirrors `liveness-check-remote-aws-ssm.sh`'s shape — same required/optional env, same `_ssm_build_full_cmd`/`_ssm_run_remote_command` plumbing, same file-resolution (`${XDG_RUNTIME_DIR:-$HOME/.local/state}/autonomous-${SSM_REMOTE_PROJECT_ID}`). The remote shell script performs the ENTIRE validation + age computation ON the execution host (never ships raw file content back for the controller to parse-and-trust, and never computes age from the controller's own clock — the design's explicit constraint) and prints exactly one line: the same compact JSON snapshot contract. Driver stdout that isn't valid single-line JSON matching one of the three shapes, or any SSM/transport failure, → UNKNOWN at the `_remote_pid_alive_query`-style wrapper layer in `lib-dispatch.sh` (never STALE).

## Step 5a control flow (`dispatcher-tick.sh`)

Replace the existing idle-only gate with:

1. Existing PR-exists / CI-green / `pr_idle_age > 300` gates, unchanged (INV-10 stays load-bearing — it is now necessary-but-insufficient, not sufficient).
2. `snapshot=$(dev_progress_snapshot "$issue_num")`; parse `state`. FRESH/UNKNOWN → `continue` (no action, no comment). Only STALE proceeds; capture `pid`/`run_id` from this snapshot.
3. **Final pre-kill recheck**, immediately before signaling:
   - Local: re-read `issue-<N>.pid`, require equal to the pid captured in step 2's snapshot. Re-run `pid_alive`. Re-run `dev_progress_snapshot`, require STALE with the SAME `pid` AND `run_id` as step 2. Any mismatch/FRESH/UNKNOWN → `continue`, no comment, no transition.
   - Remote: ONE additional SSM round-trip that performs recheck+kill atomically on the wrapper host (`agent-progress-snapshot-remote-aws-ssm.sh --compare-and-signal <issue> <expected-pid> <expected-run-id>`) — re-validates pid-file equality + snapshot STALE/pid/run_id match and, only if all hold, sends the wrapper's own `kill -TERM` locally on that host, printing `SIGNALED`/`ABORTED:<reason>`. An SSM failure or a returned `ABORTED:*` → no comment, no transition.
4. On success: post the existing handoff comment (wording below) and `label_swap in-progress → pending-review`, exactly as today.

The local recheck reuses the existing `kill -0 "$pid"` liveness recheck already in the code (kept), simply adding the snapshot re-validation alongside it — this is additive, not a rewrite of the PID recheck.

## Handoff comment wording (unchanged shape, new field)

```
Dev process still alive but PR #<N> is ready (all CI checks passed,
PR inactive <pr-age>s, no agent progress for <progress-age>s).
Sent SIGTERM to PID <pid>. Moving to pending-review.
```

Still not an `Agent Session Report (Dev)` comment, so `count_agent_failures` is unaffected — pinned by a test, not by re-deriving the retry-regex exclusion.

## Non-goals (per issue)

Step 5b; retry-counting redesign; heartbeat-as-progress; `AGENT_TIMEOUT` changes; PID-reuse detection; per-project progress-timeout conf knob; producer-side per-event locking.

## Test strategy

Frozen-clock fixtures under `tests/unit/`, driving the REAL `dev_progress_snapshot` and the REAL Step 5a block extracted from `dispatcher-tick.sh` (same extraction technique as `test-lane-gc-p6-gate.sh`'s `STEP5_BODY` awk range) — never a reimplementation. See `docs/test-cases/step5a-progress-gate.md`.
